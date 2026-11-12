param(
  [ValidateSet("Telegram","Facebook")][string]$Platform = "Telegram",
  [int]$Quota = 0,
  [int]$MaxMinutes = 40,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$hub = "http://127.0.0.1:8787"
$log = { param($m) "[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $m; }

function Get-HubHealth { try { Invoke-RestMethod "$hub/health" -TimeoutSec 10 } catch { $null } }

function Start-HubIfNeeded {
  $h = Get-HubHealth
  if ($h) { return $true }
  Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",(Join-Path $here "hub.ps1"),"-Platform",$Platform) -WindowStyle Hidden
  for ($i=0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 800; $h = Get-HubHealth; if ($h) { return $true } }
  return $false
}

function Get-TgCdp { param($Js)
  $p = @{ expression = $Js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress
  $r = & "$here\cdp_call.ps1" -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram.org" 2>$null
  return ([string]($r -join " "))
}

function Test-TgAlive {
  $js = "(async()=>{try{const am=window.rootScope.managers.apiManager;await Promise.race([am.invokeApi('help.getConfig',{}),new Promise((_,r)=>setTimeout(()=>r(new Error('t')),8000))]);return 'OK';}catch(e){return 'ERR';}})()"
  $s = Get-TgCdp $js
  return ($s -match "OK")
}

function Get-ExternalUsernames {
  param([string]$Keyword)
  $found = @{}
  $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
  $queries = @("$Keyword telegram group", "$Keyword t.me", "site:t.me $Keyword")
  foreach ($q0 in $queries) {
    $q = [uri]::EscapeDataString($q0)
    try {
      $r = Invoke-WebRequest ("https://www.bing.com/search?q=" + $q + "&count=30&setlang=en") -UseBasicParsing -TimeoutSec 8 -Headers @{ "User-Agent"=$ua; "Accept-Language"="en-US,en;q=0.9" }
      $h = [string]$r.Content
      foreach ($m in [regex]::Matches($h, 'u=a1([A-Za-z0-9_\-]+)')) {
        $b = $m.Groups[1].Value.Replace('-','+').Replace('_','/')
        while ($b.Length % 4 -ne 0) { $b += '=' }
        try { $u = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) } catch { continue }
        if ($u -match 't\.me/(?:s/)?([A-Za-z0-9_]{4,32})') { $found[$Matches[1]] = 1 }
      }
    } catch { }
  }
  return $found
}

function Get-SeedUsernames {
  $f = Join-Path $here "seeds.txt"
  $out = @{}
  if (Test-Path $f) {
    foreach ($line in (Get-Content $f -Encoding UTF8)) {
      $t = $line.Trim()
      if (-not $t -or $t.StartsWith("#")) { continue }
      if ($t -match 't\.me/(?:s/)?([A-Za-z0-9_]{4,32})') { $out[$Matches[1]] = 1 }
      elseif ($t -match '^@?([A-Za-z][A-Za-z0-9_]{3,31})$') { $out[$Matches[1]] = 1 }
    }
  }
  return $out
}

& $log "== run.ps1 start platform=$Platform quota=$Quota dry=$DryRun =="
if (-not (Start-HubIfNeeded)) { & $log "hub 启动失败"; exit 2 }
& $log "hub ok"

$cfgQ = (Invoke-RestMethod "$hub/api/config" -TimeoutSec 15).quotas
if ($Quota -le 0) { $Quota = [int]$cfgQ.$Platform }
& $log "目标配额 $Quota"

$seeds = Get-SeedUsernames
& $log ("seeds.txt 提供 " + $seeds.Count + " 个")

$ext = @{}
if ($Platform -eq "Telegram") {
  $kws = @("cs2 trade","cs2 skins","csgo trading")
  foreach ($k in $kws) {
    $r = Get-ExternalUsernames -Keyword $k
    foreach ($u in $r.Keys) { $ext[$u] = 1 }
  }
  & $log ("外部搜索命中 " + $ext.Count + " 个（Bing/DDG 解码）")
}

$uname = @{}
foreach ($u in $seeds.Keys) { $uname[$u] = "seed" }
foreach ($u in $ext.Keys) { if (-not $uname.ContainsKey($u)) { $uname[$u] = "external" } }

if ($Platform -eq "Telegram" -and -not (Test-TgAlive)) { & $log "Telegram Web 未连通，先刷新/登录再跑"; exit 3 }

$items = @()
foreach ($u in $uname.Keys) { $items += [pscustomobject]@{ u = $u; title = $u; n = 0; q = "external"; src = $uname[$u] } }
& $log ("候选合计 " + $items.Count)

if ($items.Count -eq 0) { & $log "没有候选，退出（请在 seeds.txt 补链接）"; exit 4 }
if ($DryRun) { $items | ForEach-Object { "  @" + $_.u + "  [" + $_.src + "]" }; exit 0 }

$body = @{ items = $items; start = $true } | ConvertTo-Json -Depth 5 -Compress
$sd = Invoke-RestMethod "$hub/api/seed" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60
& $log ("已投放 " + $sd.added + " 个，phase=" + $sd.phase)

$deadline = (Get-Date).AddMinutes($MaxMinutes)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 15
  $h = Get-HubHealth
  if (-not $h) { & $log "hub 掉了"; break }
  if ($h.phase -eq "done" -or -not $h.running) { break }
}
$sum = Invoke-RestMethod "$hub/api/summary" -TimeoutSec 40
& $log ("结束：今日 " + $sum.totals.todayGroups + " 群 / " + $sum.totals.todayMembers + " 人；累计 " + $sum.totals.groups + " 群 / " + $sum.totals.members + " 人")