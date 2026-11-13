param(
  [int]$MaxUsers = 2000,
  [int]$PerGuild = 300,
  [int]$MaxGuilds = 12,
  [int]$DelayMs = 1500,
  [switch]$SkipCounts,
  [switch]$SkipMembers,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = "D:\DeepSeek\运营" }
. (Join-Path $baseDir "lib\feishu.ps1")
. (Join-Path $baseDir "lib\db.ps1")

$cdp = Join-Path $baseDir "cdp_call.ps1"
$dataDir = Join-Path $baseDir "data"
$logDir = Join-Path $baseDir "logs"
foreach ($d in @($dataDir, $logDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$logFile = Join-Path $logDir "discord_daily.log"

function Say([string]$m) {
  $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] [discord_daily] " + $m
  Write-Host $line
  [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Ev([string]$m) {
  try { Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -ContentType "application/json" -Body (@{ msg = $m } | ConvertTo-Json -Compress) -TimeoutSec 5 | Out-Null } catch {}
}
function Cdp([string]$js) {
  $raw = ""
  try { $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson (@{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress) -Match "discord.com" } catch { return $null }
  try {
    $o = $raw | ConvertFrom-Json
    if ($o -and $o.result -and $o.result.value) { return ($o.result.value | ConvertFrom-Json) }
  } catch {}
  return $null
}

# 0) 确保有一个 discord 标签页
$tabs = @()
try { $tabs = (Invoke-WebRequest -Uri "http://127.0.0.1:9222/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json } catch {}
$disc = @($tabs | Where-Object { $_.type -eq "page" -and $_.url -match "discord\.com/(app|channels)" })
if ($disc.Count -eq 0) {
  try { Invoke-WebRequest -Uri ("http://127.0.0.1:9222/json/new?" + [uri]::EscapeDataString("https://discord.com/app")) -Method Put -UseBasicParsing -TimeoutSec 10 | Out-Null } catch {}
  Start-Sleep -Seconds 10
  Say "opened discord tab"
}
try { & $cdp -Method "Page.bringToFront" -ParamsJson '{}' -Match "discord.com" | Out-Null } catch {}

$tkJs = @'
(async()=>{
  const sleep=ms=>new Promise(r=>setTimeout(r,ms));
  function tok(){
    let t=null;
    try{ webpackChunkDiscord_app.push([[Symbol()],{},r=>{ for(const m of Object.values(r.c)){ try{ const e=m&&m.exports; if(!e) continue;
      if(typeof e.getToken==='function') t=e.getToken();
      else if(e.default&&typeof e.default.getToken==='function') t=e.default.getToken();
    }catch(_){} } }]); webpackChunkDiscord_app.pop(); }catch(_){}
    if(!t){ try{ for(const k of Object.keys(localStorage)){ if(!/token/i.test(k)) continue; const v=localStorage.getItem(k)||''; const m=v.match(/"([A-Za-z0-9_\-\.]{20,})"/); if(m){ t=m[1]; break; } } }catch(_){} }
    return t;
  }
  const tk=tok();
  if(!tk) return JSON.stringify({err:'no-token'});
  const H={'Authorization':tk};
  const r=await fetch('/api/v9/users/@me/guilds',{headers:H});
  if(!r.ok) return JSON.stringify({err:'guilds-'+r.status});
  const gs=await r.json();
  const kw=/(cs2|cs\s*go|csgo|cs:go|counter[\s\-]?strike|skin|trade|dmarket|buff\d*|skinport|csgoroll|csgoempire|vaka|swap)/i;
  const cs=(gs||[]).filter(g=>kw.test(g.name||'')).map(g=>({id:g.id,name:g.name}));
  return JSON.stringify({ok:1,guilds:cs});
})()
'@
# token 来源顺序：config.discord.token -> data\discord_token.txt -> 页面内提取
$token = ""
try {
  $cfg0 = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($cfg0.discord -and $cfg0.discord.PSObject.Properties.Name -contains "token") { $token = [string]$cfg0.discord.token }
} catch {}
$tokFile = Join-Path $dataDir "discord_token.txt"
if (-not $token -and (Test-Path $tokFile)) { $token = (Get-Content $tokFile -Raw -Encoding UTF8).Trim() }
if ($token) {
  $head = Cdp ('(async function(){var H={"Authorization":' + ($token | ConvertTo-Json -Compress) + '};var r=await fetch("/api/v9/users/@me/guilds",{headers:H});if(!r.ok)return JSON.stringify({err:"guilds-"+r.status});var gs=await r.json();var kw=/(cs2|csgo|cs:go|counter[\s-]?strike|skin|trade|dmarket|buff|skinport|csgoroll|csgoempire|vaka|swap)/i;return JSON.stringify({ok:1,guilds:(gs||[]).filter(function(g){return kw.test(g.name||"")}).map(function(g){return {id:g.id,name:g.name}})});})()')
} else {
  $head = Cdp $tkJs
}
if (-not $head -or -not $head.ok) {
  Say ("cannot read discord guilds: " + (($head | ConvertTo-Json -Compress) -replace "\s+", " "))
  Ev "discord daily: no token -> coverage snapshot only"
  $cfgDbg = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  $rowsFs = Get-FsRecords
  $covFile2 = Join-Path $dataDir "discord_coverage.csv"
  $covHeader2 = "collect_date,guild_id,guild_name,members,online,checked_at"
  if (-not (Test-Path $covFile2)) { [System.IO.File]::WriteAllText($covFile2, $covHeader2 + "`r`n", (New-Object System.Text.UTF8Encoding($true))) }
  $n2 = 0; $sum2 = 0
  $lines2 = New-Object System.Collections.Generic.List[string]
  foreach ($r in $rowsFs) {
    $f = $r.fields
    $plat = [string]($f."平台" | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.text } })
    if ($plat -ne "Discord") { continue }
    $st = [string]($f."状态" | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.text } })
    if ($st -eq "已退出" -or $st -eq "已失效") { continue }
    $gid = [string]($f."群ID" | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.text } })
    $gnm = [string]($f."群名" | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.text } })
    $mem = 0; try { $mem = [int]$f."成员数" } catch {}
    $n2++; $sum2 += $mem
    $lines2.Add((Get-Date).ToString("yyyy-MM-dd") + ',"' + $gid + '","' + ($gnm -replace '"', "'") + '",' + $mem + ',0,"' + (Get-Date).ToString("s") + '"')
  }
  if ($lines2.Count -gt 0) { [System.IO.File]::AppendAllText($covFile2, ($lines2 -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false))) }
  Say ("coverage-only done: guilds=" + $n2 + " members_sum=" + $sum2)
  Say "member sampling skipped: no discord token (put it in config.json discord.token or data\discord_token.txt)"
  exit 0
}
$guilds = @($head.guilds)
Say ("cs guilds found=" + $guilds.Count)
Ev ("discord daily start (cs=" + $guilds.Count + ")")

$cov = New-Object System.Collections.ArrayList
$rows = New-Object System.Collections.ArrayList
$totalUsers = 0

$guildJs = @'
(async(id,perGuild,delayMs)=>{
  const sleep=ms=>new Promise(r=>setTimeout(r,ms));
  function tok(){ let t=null;
    try{ webpackChunkDiscord_app.push([[Symbol()],{},r=>{ for(const m of Object.values(r.c)){ try{ const e=m&&m.exports; if(!e) continue;
      if(typeof e.getToken==='function') t=e.getToken(); else if(e.default&&typeof e.default.getToken==='function') t=e.default.getToken();
    }catch(_){} } }]); webpackChunkDiscord_app.pop(); }catch(_){}
    if(!t){ try{ for(const k of Object.keys(localStorage)){ if(!/token/i.test(k)) continue; const v=localStorage.getItem(k)||''; const m=v.match(/"([A-Za-z0-9_\-\.]{20,})"/); if(m){ t=m[1]; break; } } }catch(_){} }
    return t; }
  const tk=tok(); if(!tk) return JSON.stringify({err:'no-token'});
  const H={'Authorization':tk};
  const gi=await fetch('/api/v9/guilds/'+id+'?with_counts=true',{headers:H});
  let g={}; try{ g=await gi.json(); }catch(_){}
  const out=[]; let after='0';
  for(let p=0;p<Math.ceil(perGuild/100);p++){
    const r=await fetch('/api/v9/guilds/'+id+'/members?limit=100&after='+after,{headers:H});
    if(!r.ok){ out.push({err:'members-'+r.status}); break; }
    let arr=null; try{ arr=await r.json(); }catch(_){ arr=null; }
    if(!Array.isArray(arr)||!arr.length) break;
    for(const m of arr){ const u=m.user||{}; out.push([u.id||'',u.username||'',u.global_name||'',m.nick||'']); }
    after=(arr[arr.length-1].user||{}).id||'';
    if(!after) break;
    await sleep(delayMs);
  }
  return JSON.stringify({name:g.name||'',count:g.approximate_member_count||0,online:g.approximate_presence_count||0,members:out});
})('<ID>',<PER>,<DELAY>)
'@

$idx = 0
foreach ($g in $guilds) {
  if ($totalUsers -ge $MaxUsers) { break }
  if ($idx -ge $MaxGuilds) { break }
  $idx++
  $js = $guildJs.Replace("<ID>", [string]$g.id).Replace("<PER>", [string]$PerGuild).Replace("<DELAY>", [string]$DelayMs)
  $res = Cdp $js
  if (-not $res) { Say ($g.name + " -> no response"); continue }
  if ($res.err) { Say ($g.name + " -> " + $res.err); Start-Sleep -Seconds 3; continue }

  $cnt = [int]$res.count
  [void]$cov.Add([pscustomobject]@{ id = $g.id; name = $g.name; members = $cnt; online = [int]$res.online; at = (Get-Date).ToString("s") })
  Say ($g.name + " count=" + $cnt + " online=" + [int]$res.online + " read=" + @($res.members).Count)

  if (-not $SkipMembers) {
    foreach ($m in @($res.members)) {
      if ($totalUsers -ge $MaxUsers) { break }
      if (-not $m -or $m -is [string]) { continue }
      if ($m.err) { continue }
      $arr = @($m)
      if ($arr.Count -lt 2) { continue }
      $uid = [string]$arr[0]; if (-not $uid) { continue }
      $uname = [string]$arr[1]
      $gname = [string]$arr[2]
      $nick = if ($arr.Count -ge 4) { [string]$arr[3] } else { "" }
      $disp = if ($nick) { $nick } else { $gname }
      [void]$rows.Add(('Discord,"' + $g.id + '","' + ($g.name -replace '"', "'") + '","' + $uid + '","' + $uname + '","' + ($disp -replace '"', "'") + '","","成员","","' + (Get-Date).ToString("yyyy/MM/dd") + '","Discord API","有效"'))
      $totalUsers++
    }
  }
  Start-Sleep -Milliseconds ([Math]::Max(400, $DelayMs))
}

# 覆盖人数 CSV（每天一份追加）
$covFile = Join-Path $dataDir "discord_coverage.csv"
$covHeader = "collect_date,guild_id,guild_name,members,online,checked_at"
if (-not (Test-Path $covFile)) { [System.IO.File]::WriteAllText($covFile, $covHeader + "`r`n", (New-Object System.Text.UTF8Encoding($true))) }
$lines = New-Object System.Collections.Generic.List[string]
foreach ($c in $cov) {
  $lines.Add((Get-Date).ToString("yyyy-MM-dd") + ',"' + $c.id + '","' + ($c.name -replace '"', "'") + '",' + $c.members + ',' + $c.online + ',"' + $c.at + '"')
}
if ($lines.Count -gt 0) {
  [System.IO.File]::AppendAllText($covFile, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
Say ("coverage rows=" + $cov.Count + " -> " + $covFile)

# 用户样本写库 + users.csv/jsonl
if ($rows.Count -gt 0 -and -not $DryRun) {
  $usersCsv = Join-Path $dataDir "users.csv"
  $header = "平台,群ID,群名,用户ID,用户名,昵称,语言,角色,最近活跃,采集日,来源,状态"
  if (-not (Test-Path $usersCsv)) { [System.IO.File]::WriteAllText($usersCsv, $header + "`r`n", (New-Object System.Text.UTF8Encoding($true))) }
  $tmp = Join-Path $dataDir ("_discord_" + (Get-Date).ToString("HHmmss") + ".csv")
  [System.IO.File]::WriteAllText($tmp, $header + "`r`n" + ($rows -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
  $dbOk = $false
  try { Initialize-LocalDb | Out-Null; Import-LocalDb -Csv $tmp | Out-Null; $dbOk = $true } catch { Say ("db import failed: " + $_.Exception.Message) }
  try { [System.IO.File]::AppendAllText($usersCsv, ($rows -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Say ("users written=" + $rows.Count + " db=" + $dbOk)
  Ev ("discord daily: users +" + $rows.Count)
}

Say ("DONE guilds=" + $cov.Count + " users=" + $rows.Count)
Ev ("discord daily done: guilds=" + $cov.Count + " users=" + $rows.Count)
