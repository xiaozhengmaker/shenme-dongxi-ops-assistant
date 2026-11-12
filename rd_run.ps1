param(
  [int]$MaxSubs = 10,
  [int]$MaxKeywords = 0,
  [int]$MinSubs = 10000,
  [int]$MinPosts7d = 1,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
. "$baseDir\lib\feishu.ps1"
$baseDir = $PSScriptRoot

$cfg = [System.IO.File]::ReadAllText("$baseDir\config.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$todayMs = [DateTimeOffset]::new((Get-Date).Date).ToUnixTimeMilliseconds()
$expireMs = $todayMs + 3 * 86400000

function Invoke-Cdp($method, $params, $match = "reddit.com") {
  $json = $params | ConvertTo-Json -Compress -Depth 6
  $raw = (& "$baseDir\cdp_call.ps1" -Method $method -ParamsJson $json -Match $match) -join "`n"
  if ($raw -and $raw.TrimStart().StartsWith("{")) {
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
  }
  return $raw
}
function EvalJs($file) {
  $js = [System.IO.File]::ReadAllText("$baseDir\data\$file", [System.Text.Encoding]::UTF8)
  $r = Invoke-Cdp "Runtime.evaluate" @{ expression = $js; returnByValue = $true; awaitPromise = $true }
  if ($r -and $r.result -and $r.result.value) { return $r.result.value }
  return $null
}
function GoUrl($url, $wait = 6) {
  Invoke-Cdp "Page.navigate" @{ url = $url } | Out-Null
  Start-Sleep -Seconds $wait
}

$kw = @($cfg.strategy.Reddit.discovery.keywords)
if ($MaxKeywords -gt 0) { $kw = $kw[0..([Math]::Min($MaxKeywords, $kw.Count) - 1)] }
Write-Host ("keywords=" + $kw.Count + " target=" + $MaxSubs)

$seen = @{}
$picked = New-Object System.Collections.ArrayList

foreach ($k in $kw) {
  if ($picked.Count -ge $MaxSubs) { break }
  $q = [uri]::EscapeDataString($k)
  GoUrl "https://www.reddit.com/search/?q=$q&type=sr" 6
  $raw = EvalJs "rd_search.js"
  if (-not $raw) { continue }
  $names = @(($raw | ConvertFrom-Json).names)
  $added = 0
  foreach ($n in $names) {
    if ($picked.Count -ge $MaxSubs) { break }
    $key = $n.ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $expr = "(async()=>{try{const r=await fetch('https://www.reddit.com/r/$n/about.json?raw_json=1',{credentials:'include'});const j=await r.json();const d=j.data||{};return JSON.stringify({s:d.subscribers,n:d.display_name,q:(d.public_description||'').replace(/\s+/g,' ').slice(0,50),o:d.over18,sub:!!d.user_is_subscriber});}catch(e){return JSON.stringify({err:e.message});}})()"
    $ab = Invoke-Cdp "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
    if (-not $ab -or -not $ab.result.value) { continue }
    $info = $ab.result.value | ConvertFrom-Json
    if ($info.err) { continue }
    if ($info.o -eq $true) { Write-Host ("  skip18 " + $n); continue }
    if ([int]$info.s -lt $MinSubs) { continue }
    if ($info.sub) { Write-Host ("  already " + $n); continue }
    [void]$picked.Add([pscustomobject]@{ name = $n; subs = [int]$info.s; desc = $info.q })
    $added++
    Write-Host ("  PICK " + $n + " subs=" + $info.s)
  }
  Write-Host ("[" + $k + "] names=" + $names.Count + " pickedNow=" + $added)
}

Write-Host ("picked=" + $picked.Count)
if ($picked.Count -eq 0) { exit 0 }
if ($DryRun) { exit 0 }

$records = New-Object System.Collections.ArrayList
$userRows = New-Object System.Collections.ArrayList

foreach ($p in $picked) {
  # 1) 采集该板块热帖（作者 + 近 7 天帖数）
  GoUrl "https://www.reddit.com/r/$($p.name)/" 6
  foreach ($i in 1..2) {
    Invoke-Cdp "Runtime.evaluate" @{ expression = "window.scrollBy(0, 2200); 'ok'"; returnByValue = $true } | Out-Null
    Start-Sleep -Seconds 2
  }
  $subRaw = EvalJs "rd_sub2.js"
  $sub = $null
  if ($subRaw) { try { $sub = $subRaw | ConvertFrom-Json } catch { } }
  $posts7d = if ($sub) { [int]$sub.posts7d } else { 0 }
  $authors = if ($sub) { @($sub.authors) } else { @() }

  # 2) 订阅
  $expr2 = "(async()=>{try{const me=await (await fetch('https://www.reddit.com/api/me.json?raw_json=1',{credentials:'include'})).json();const uh=me.data.modhash;const b=new URLSearchParams({uh:uh,action:'sub',sr_name:'$($p.name)',api_type:'json',skip_initial_defaults:'true'});const r=await fetch('https://www.reddit.com/api/subscribe',{method:'POST',credentials:'include',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:b.toString()});await new Promise(s=>setTimeout(s,800));const ab=await (await fetch('https://www.reddit.com/r/$($p.name)/about.json?raw_json=1',{credentials:'include'})).json();return JSON.stringify({status:r.status,sub:!!ab.data.user_is_subscriber});}catch(e){return JSON.stringify({err:e.message});}})()"
  $sb = Invoke-Cdp "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true; awaitPromise = $true }
  $joined = $false
  if ($sb -and $sb.result.value) { $j = $sb.result.value | ConvertFrom-Json; $joined = [bool]$j.sub }
  Write-Host ("  " + $p.name + " joined=" + $joined + " posts7d=" + $posts7d + " authors=" + $authors.Count)

  if ($posts7d -lt $MinPosts7d) { Write-Host ("  close " + $p.name + " (posts too few)") }

  [void]$records.Add(@{
      "群组唯一键" = "RD-" + $p.name
      "平台" = "Reddit"
      "群ID" = "r/" + $p.name
      "群名" = "r/" + $p.name
      "群链接" = "https://www.reddit.com/r/" + $p.name + "/"
      "成员数" = $p.subs
      "语言" = "英语"
      "群类型" = "板块"
      "状态" = $(if ($joined) { "已加入" } else { "待加" })
      "加入日期" = $todayMs
      "潜水到期" = $expireMs
      "日发帖量" = $posts7d
      "采集来源" = "Reddit搜索"
      "采集日" = $todayMs
      "是否收费发帖" = "未知"
      "备注" = ("近7天" + $posts7d + "帖；" + $p.desc)
  })
  foreach ($a in $authors) {
    [void]$userRows.Add([pscustomobject]@{
      平台 = "Reddit"; 群ID = "r/" + $p.name; 群名 = "r/" + $p.name;
      用户ID = $a; 用户名 = $a; 昵称 = ""; 语言 = "英语";
      角色 = "发帖者"; 最近活跃 = ""; 采集日 = $todayMs; 来源 = "板块热帖"; 状态 = "正常"
    })
  }
  Start-Sleep -Seconds (Get-Random -Minimum 8 -Maximum 18)
}

if ($records.Count -gt 0) {
  Add-FsRecords -FieldSets $records.ToArray() | Out-Null
  Write-Host ("feishu added=" + $records.Count)
}
if ($userRows.Count -gt 0) {
  $csv = "$baseDir\data\users.csv"
  $userRows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Append
  $jsonl = "$baseDir\data\users.jsonl"
  foreach ($u in $userRows) { ($u | ConvertTo-Json -Compress) | Add-Content -Path $jsonl -Encoding UTF8 }
  Write-Host ("users added=" + $userRows.Count)
}
