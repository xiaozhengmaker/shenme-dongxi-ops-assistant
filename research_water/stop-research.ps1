param(
  [int]$Port = 8810
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root 'run\server.pid'
if (-not (Test-Path $pidFile)) { Write-Host 'not running (no pid file)'; exit 0 }
$procId = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
$listening = netstat -ano | Select-String -Pattern (':{0}\s' -f $Port) | Select-String -Pattern ('\s{0}\s*$' -f $procId)
if (-not $listening) {
  $still = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $still) {
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "not running (stale pid $procId)"
    exit 0
  }
  Write-Host "refusing: pid $procId exists but is not listening on port $Port; no process stopped."
  exit 1
}
Stop-Process -Id $procId -Force
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 250
  if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { break }
}
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
Write-Host "stopped: pid=$procId port=$Port"
