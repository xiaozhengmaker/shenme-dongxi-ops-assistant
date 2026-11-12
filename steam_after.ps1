param([int]$MaxWaitMin = 600, [int]$Pages = 3)
$ErrorActionPreference = "Continue"
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $baseDir "logs\steam_after.log"

function Say([string]$m) {
  $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $m
  [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Ev([string]$m) {
  try {
    $b = @{ msg = ($m -replace '[^\x20-\x7E]', '?') } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/event' -Method Post -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec 5 | Out-Null
  } catch { }
}

Say "watcher start"
$deadline = (Get-Date).AddMinutes($MaxWaitMin)
while ((Get-Date) -lt $deadline) {
  $p = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.CommandLine -match "steam_full\.ps1" }
  if (-not $p) { break }
  Start-Sleep -Seconds 120
}
Say "fetch finished, run discover"
Ev "steam fetch finished, discover start"
try { & (Join-Path $baseDir "steam_discover.ps1") -MaxPages $Pages -MinMembers 1000 } catch { Say ("discover err: " + $_.Exception.Message) }
Say "watcher done"
Ev "steam discover chain done"
