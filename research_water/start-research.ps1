param(
  [int]$Port = 8810
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$node = (Get-Command node -ErrorAction Stop).Source
$pidFile = Join-Path $root 'run\server.pid'
$outLog = Join-Path $root 'logs\server.log'
$errLog = Join-Path $root 'logs\server.err.log'
$dataDir = Join-Path $root 'data'

New-Item -ItemType Directory -Force -Path (Join-Path $root 'run'), (Join-Path $root 'logs'), $dataDir | Out-Null

if (Test-Path $pidFile) {
  $oldPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
  $old = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
  if ($old) {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $oldPid }
    if ($conn) { Write-Host "already running: pid=$oldPid http://127.0.0.1:$Port/"; exit 0 }
    Write-Host "pid file exists but is not listening on $Port; refusing to start a second process."; exit 1
  }
  Remove-Item -LiteralPath $pidFile -Force
}

$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
  Get-Content -LiteralPath $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $name = $matches[1]
      $value = $matches[2].Trim()
      if ($value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Substring(1, $value.Length - 2) }
      Set-Item -Path ("Env:" + $name) -Value $value
    }
  }
}

$env:LEADS_WATER_PORT = [string]$Port
$env:LEADS_WATER_DATA = $dataDir
$env:LEADS_WATER_SEARCH = 'live'
# This host's DNS proxy maps public names into 198.18.0.0/15. The flag only permits
# that benchmark range; loopback/RFC1918/link-local/metadata/credentials stay blocked.
$env:LEADS_WATER_SEARCH_ALLOW_BENCHMARK = '1'
if (-not $env:LEADS_WATER_PROVIDER) { $env:LEADS_WATER_PROVIDER = 'deepseek' }
if (-not $env:LEADS_WATER_RSS_FEEDS) { $env:LEADS_WATER_RSS_FEEDS = 'https://sspai.com/feed' }

$serverJs = Join-Path $root 'server.js'
$p = Start-Process -FilePath $node -ArgumentList @($serverJs) -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Set-Content -LiteralPath $pidFile -Value $p.Id -Encoding ASCII
$url = "http://127.0.0.1:$Port"
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    $health = Invoke-RestMethod -Uri ($url + '/api/health') -TimeoutSec 3
    if ($health.ok) { $ready = $true; break }
  } catch { }
}
if (-not $ready) {
  try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  Write-Host "failed to start; see $errLog"
  if (Test-Path $errLog) { Get-Content -LiteralPath $errLog -Tail 20 }
  exit 1
}
Write-Host "started: pid=$($p.Id) $url"
Write-Host "data=$dataDir"
Write-Host "stop with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$root\stop-research.ps1`""
