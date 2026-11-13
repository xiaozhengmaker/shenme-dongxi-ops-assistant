param(
  [int]$MaxQueries = 20,
  [string]$Stage = "all",
  [string]$Engine = "bing",
  [int]$DelayMs = 2500
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = "D:\DeepSeek\运营" }
. (Join-Path $baseDir "lib\wa.ps1") -BaseDir $baseDir

$cdp = Join-Path $baseDir "cdp_call.ps1"
$logDir = Join-Path $baseDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "wa_discover.log"

function Say([string]$m) {
  $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] [wa_discover] " + $m
  Write-Host $line
  [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Ev([string]$m) {
  try { Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -ContentType "application/json" -Body (@{ msg = $m } | ConvertTo-Json -Compress) -TimeoutSec 5 | Out-Null } catch {}
}

# 专用搜索标签页
$tabs = @()
try { $tabs = (Invoke-WebRequest -Uri "http://127.0.0.1:9222/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json } catch {}
$hasTab = @($tabs | Where-Object { $_.type -eq "page" -and ($_.url -match "\.bing\.com" -or $_.url -match "\.google\.com") }).Count -gt 0
if (-not $hasTab) {
  try { Invoke-WebRequest -Uri ("http://127.0.0.1:9222/json/new?" + [uri]::EscapeDataString("https://www." + $Engine + ".com/")) -Method Put -UseBasicParsing -TimeoutSec 10 | Out-Null } catch {}
  Start-Sleep -Seconds 3
  Say ("opened search tab for engine " + $Engine)
}

$cfg = Get-WaConfig
$state = Get-WaState
$known = @{}
foreach ($it in @($state.items)) { if ($it.code) { $known[[string]$it.code] = $true } }
$excl = @{}
if ($cfg -and $cfg.PSObject.Properties.Name -contains "exclude") { foreach ($e in @($cfg.exclude)) { $excl[[string]$e] = $true } }

$games = @("CS2", "CSGO")
$entry = @('site:chat.whatsapp.com "{g}"', '"{g}" "chat.whatsapp.com"', '"{g}" "WhatsApp group link"', '"{g}" "WhatsApp invite"', '"{g}" "WhatsApp community"')
$uses = @("skin trading", "trade", "skins", "LFG", "teammates", "Premier", "FACEIT", "scrims", "team recruitment", "tournament", "community")
$regions = @(@{q="Brasil";l="pt"}, @{q="Argentina";l="es"}, @{q="Mexico";l="es"}, @{q="LATAM";l="es"}, @{q="UK";l="en"}, @{q="Germany";l="de"}, @{q="France";l="fr"}, @{q="Poland";l="pl"}, @{q="Turkey";l="tr"}, @{q="Europe";l="en"}, @{q="USA";l="en"}, @{q="India";l="en"}, @{q="Pakistan";l="en"}, @{q="Indonesia";l="id"}, @{q="Malaysia";l="en"}, @{q="Philippines";l="en"}, @{q="Australia";l="en"}, @{q="Saudi Arabia";l="ar"}, @{q="UAE";l="ar"})
$local = @{ pt = @("grupo", "comunidade"); es = @("grupo", "comunidad"); tr = @("grup", "topluluk"); id = @("grup", "komunitas"); de = @("Gruppe", "Community"); fr = @("groupe", "communauté"); pl = @("grupa", "handel"); ar = @("قروب", "مجموعة") }

# 0) 手工种子：wa_links.txt / data\wa_seeds.txt（一行一条链接，可带 # 备注）
$seedFiles = @((Join-Path $baseDir "wa_links.txt"), (Join-Path $baseDir "data\wa_seeds.txt"))
$seedAdded = 0
foreach ($sf in $seedFiles) {
  if (-not (Test-Path $sf)) { continue }
  foreach ($line in (Get-Content $sf -Encoding UTF8)) {
    $txt = [string]$line
    if (-not $txt -or $txt.TrimStart().StartsWith("#")) { continue }
    foreach ($c in (Find-WaCodesInText $txt)) {
      if ($known.ContainsKey($c) -or $excl.ContainsKey($c)) { continue }
      $known[$c] = $true; $seedAdded++
      $note = ""
      if ($txt -match "#\s*(.+)$") { $note = $Matches[1].Trim() }
      $state.items = @($state.items) + [pscustomobject]@{
        code = $c; name = ""; region = "未知"; lang = "未知"; purpose = "未知"; relevance = "pending"
        status = "待验证"; join = "未加入"; note = $note
        sources = @(@{ q = "seed"; engine = "file"; url = $sf; snippet = $note; at = (Get-Date).ToString("s") })
        checkedAt = ""
      }
    }
  }
}
if ($seedAdded -gt 0) { Say ("seeds imported=" + $seedAdded); Ev ("wa seeds +" + $seedAdded) }

$queries = New-Object System.Collections.ArrayList
if ($Stage -eq "all" -or $Stage -eq "1") {
  foreach ($g in $games) { foreach ($t in $entry) { [void]$queries.Add($t.Replace("{g}", $g)) } }
}
if ($Stage -eq "all" -or $Stage -eq "2") {
  foreach ($u in $uses) { foreach ($g in $games) { [void]$queries.Add('"' + $g + '" "' + $u + '" "WhatsApp"') } }
}
if ($Stage -eq "all" -or $Stage -eq "3") {
  foreach ($r in $regions[0..5]) { [void]$queries.Add('"CS2" "skins" "WhatsApp" "' + $r.q + '"') }
  foreach ($k in $local.Keys) { foreach ($w in $local[$k]) { [void]$queries.Add('"CS2" "' + $w + '" "WhatsApp"') } }
}
if ($Stage -eq "all" -or $Stage -eq "4") {
  [void]$queries.Add('site:reddit.com "CS2" "chat.whatsapp.com"')
  [void]$queries.Add('site:steamcommunity.com "CS2" "WhatsApp"')
  [void]$queries.Add('site:facebook.com "CS2" "WhatsApp"')
  [void]$queries.Add('"CS2" "grupos de WhatsApp"')
  [void]$queries.Add('"CSGO" "WhatsApp group directory"')
}

$done = @{}
foreach ($q in @($state.queries)) { if ($q) { $done[[string]$q] = $true } }

$executed = 0
$newCount = 0
Say ("start queries_total=" + $queries.Count + " known=" + $known.Count)
Ev ("wa discover start (queries=" + $queries.Count + ")")

$js = @'
(function(){
  function dec(u){try{if(u.indexOf('a1')===0)u=u.slice(2);u=u.replace(/-/g,'+').replace(/_/g,'/');while(u.length%4)u+='=';return atob(u);}catch(e){return '';}}
  var out=[];
  document.querySelectorAll('a').forEach(function(a){
    var h=a.href||'';var real=h;
    if(/bing\.com\/ck\/a/.test(h)){var m=/[?&]u=([^&]+)/.exec(h);if(m){var d=dec(decodeURIComponent(m[1]));if(d)real=d;}}
    var mm=/chat\.whatsapp\.com\/(?:invite\/)?([A-Za-z0-9]{8,})/.exec(real);
    if(mm){var box=a.closest('li')||a.parentElement;out.push({c:mm[1],u:real,t:(box?box.innerText:'').replace(/\s+/g,' ').slice(0,200)});}
  });
  var t=document.body?document.body.innerText:'';
  var codes=[];var re=/chat\.whatsapp\.com\s*[›>\/]\s*([A-Za-z0-9]{8,})/g,m2;
  while((m2=re.exec(t))){codes.push(m2[1]);}
  var pages=[];
  document.querySelectorAll('a').forEach(function(a){
    var h=a.href||'';var real=h;
    if(/bing\.com\/ck\/a/.test(h)){var m3=/[?&]u=([^&]+)/.exec(h);if(m3){var d3=dec(decodeURIComponent(m3[1]));if(d3)real=d3;}}
    if(!/^https?:/.test(real))return;
    if(/bing\.com|microsoft|msn\.com|go\.microsoft/.test(real))return;
    if(/chat\.whatsapp\.com/.test(real))return;
    pages.push(real);
  });
  return JSON.stringify({links:out,codes:codes,pages:pages.slice(0,40),head:t.slice(0,200)});
})()
'@

foreach ($q in $queries) {
  if ($executed -ge $MaxQueries) { break }
  if ($done.ContainsKey($q)) { continue }
  $url = "https://www." + $Engine + ".com/search?q=" + [System.Uri]::EscapeDataString($q) + "&count=30"
  try { & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $url } | ConvertTo-Json -Compress) -Match $Engine | Out-Null } catch { Say ("nav error: " + $q); continue }
  Start-Sleep -Milliseconds $DelayMs
  $raw = ""
  try { $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson (@{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress) -Match $Engine } catch { $raw = "" }
  $executed++
  [void]$done.Add($q, $true)

  $payload = $null
  try {
    $outer = $raw | ConvertFrom-Json
    if ($outer -and $outer.result -and $outer.result.value) { $payload = ($outer.result.value | ConvertFrom-Json) }
  } catch { $payload = $null }

  $codes = @{}
  if ($payload) {
    foreach ($l in @($payload.links)) { if ($l.c -and -not $codes.ContainsKey([string]$l.c)) { $codes[[string]$l.c] = [string]$l.t } }
    foreach ($c in @($payload.codes)) { if ($c -and -not $codes.ContainsKey([string]$c)) { $codes[[string]$c] = "" } }
  }
  $added = 0
  foreach ($c in @($codes.Keys)) {
    if ($known.ContainsKey($c)) { continue }
    if ($excl.ContainsKey($c)) { continue }
    $known[$c] = $true
    $added++
    $newCount++
    $it = [pscustomobject]@{
      code = $c; name = ""; region = "未知"; lang = "未知"; purpose = "未知"; relevance = "pending"
      status = "待验证"; join = "未加入"; note = ""
      sources = @(@{ q = $q; engine = $Engine; url = $url; snippet = [string]$codes[$c]; at = (Get-Date).ToString("s") })
      checkedAt = ""
    }
    $state.items = @($state.items) + $it
  }
  Say ("q=" + $q + " -> new=" + $added + " codes=" + $codes.Count)
  if ($added -gt 0) { Ev ("wa discover +" + $added + " (total " + $known.Count + ")") }
}

  # 第二轮：打开搜索结果里的外部页面，从页面正文里挖邀请码
  $pgs = @()
  if ($payload -and $payload.pages) { $pgs = @($payload.pages | Select-Object -Unique | Select-Object -First 4) }
  foreach ($pg in $pgs) {
    try { & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $pg } | ConvertTo-Json -Compress) -Match $Engine | Out-Null } catch { continue }
    Start-Sleep -Milliseconds 2200
    $js2 = "(function(){var t=document.body?document.body.innerText:'';var re=/chat\\.whatsapp\\.com\\/(?:invite\\/)?([A-Za-z0-9]{8,})/g,m,o=[];while((m=re.exec(t))){o.push(m[1]);}return JSON.stringify({codes:o,head:t.slice(0,100)});})()"
    $raw2 = ""
    try { $raw2 = & $cdp -Method "Runtime.evaluate" -ParamsJson (@{ expression = $js2; returnByValue = $true } | ConvertTo-Json -Compress) -Match $Engine } catch { $raw2 = "" }
    $p2 = $null
    try { $o2 = $raw2 | ConvertFrom-Json; if ($o2.result -and $o2.result.value) { $p2 = ($o2.result.value | ConvertFrom-Json) } } catch {}
    if (-not $p2) { continue }
    $add2 = 0
    foreach ($c in @($p2.codes)) {
      if (-not $c) { continue }
      if ($known.ContainsKey([string]$c)) { continue }
      if ($excl.ContainsKey([string]$c)) { continue }
      $known[[string]$c] = $true; $add2++; $newCount++
      $it = [pscustomobject]@{
        code = [string]$c; name = ""; region = "未知"; lang = "未知"; purpose = "未知"; relevance = "pending"
        status = "待验证"; join = "未加入"; note = "来自页面 " + $pg
        sources = @(@{ q = $q; engine = $Engine; url = $pg; snippet = [string]$p2.head; at = (Get-Date).ToString("s") })
        checkedAt = ""
      }
      $state.items = @($state.items) + $it
    }
    if ($add2 -gt 0) { Say ("  page " + $pg + " -> +" + $add2) }
  }

$state.queries = @(@($state.queries) + @($done.Keys)) | Select-Object -Unique
Save-WaState $state
Say ("DONE executed=" + $executed + " new=" + $newCount + " total=" + $known.Count)
Ev ("wa discover done: executed=" + $executed + " new=" + $newCount)
