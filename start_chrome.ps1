param([switch]$Restart)
. (Join-Path $PSScriptRoot "lib\paths.ps1")
$cfg = Get-GOpsConfig
$chrome = Get-GOpsChrome $cfg
$profile = Get-GOpsProfile $cfg -Create
$port = Get-GOpsPort $cfg
$flags = @(
  "--remote-debugging-port=$port",
  "--user-data-dir=$profile",
  "--profile-directory=Default",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-session-crashed-bubble",
  "--window-size=1400,900",
  "--disable-background-timer-throttling",
  "--disable-backgrounding-occluded-windows",
  "--disable-renderer-backgrounding",
  "--disable-features=CalculateNativeWinOcclusion"
)
if ($Restart) {
  Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $chrome } | ForEach-Object {
    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
    if ($cl -like "*$profile*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  }
  Start-Sleep -Seconds 3
}
$up = $false
try { Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 3 | Out-Null; $up = $true } catch {}
if (-not $up) {
  Start-Process -FilePath $chrome -ArgumentList $flags
  for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Milliseconds 700
    try { Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 3 | Out-Null; $up = $true; break } catch {}
  }
}
if ($up) { "chrome debug OK on $port (profile=$profile)" } else { "FAILED to start chrome debug"; exit 3 }
foreach ($u in @("https://www.facebook.com/", "https://web.telegram.org/k/")) {
  try {
    $t = Invoke-RestMethod -Method Put "http://127.0.0.1:$port/json/new?$([uri]::EscapeDataString($u))" -TimeoutSec 8
    "opened: $u"
  } catch { "open failed: $u" }
}