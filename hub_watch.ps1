# hub_watch.ps1 —— 每 5 分钟探活一次；hub 不在就按计划任务拉起
$ErrorActionPreference = "Continue"
$baseDir = $PSScriptRoot
$log = Join-Path $baseDir "logs\hub_watch.log"
function Say($m) {
  $line = "[" + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "] " + $m
  [System.IO.File]::AppendAllText($log, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
$alive = $false
try { Invoke-RestMethod "http://127.0.0.1:8787/health" -TimeoutSec 5 | Out-Null; $alive = $true } catch { }
if ($alive) { exit 0 }
if (-not (Test-Path (Join-Path $baseDir "logs"))) { New-Item -ItemType Directory -Path (Join-Path $baseDir "logs") -Force | Out-Null }
Say "hub down -> start task"
try { Start-ScheduledTask -TaskName "DSH_SocialOps_Hub" } catch { Say ("start failed: " + $_.Exception.Message) }
Start-Sleep -Seconds 8
$ok = $false
try { Invoke-RestMethod "http://127.0.0.1:8787/health" -TimeoutSec 8 | Out-Null; $ok = $true } catch { }
Say ("after start: " + $(if ($ok) { "OK" } else { "STILL DOWN" }))
if (-not $ok) { exit 3 }