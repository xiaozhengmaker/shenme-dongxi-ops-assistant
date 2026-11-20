param(
  [int]$Port = 8810
)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root 'run\server.pid'
if (Test-Path $pidFile) {
  $procId = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  Write-Host "pid=$procId running=$([bool]$p)"
} else {
  Write-Host 'pid=(none)'
}
try {
  $health = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/api/health") -TimeoutSec 3
  $health | ConvertTo-Json -Depth 5
  exit 0
} catch {
  Write-Host "health failed: $($_.Exception.Message)"
  exit 1
}
