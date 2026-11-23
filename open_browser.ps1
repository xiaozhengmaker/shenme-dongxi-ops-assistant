param([switch]$NoHub)

# 一键打开「社么东西」专用调试 Chrome（9222 + D:\ChromeFeishu\profile）
# 行为：已在运行则复用，只补缺失标签；未运行则带调试参数启动；最后把窗口提到前台。
# 由桌面快捷方式「社么东西 Chrome」调用（powershell -WindowStyle Hidden -File 本文件）。

$ErrorActionPreference = 'Continue'
$chrome  = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$profile = 'D:\ChromeFeishu\profile'
$port    = 9222
$here    = Split-Path -Parent $PSCommandPath

$urls = @(
    'https://www.facebook.com/',
    'https://web.telegram.org/k/',
    'https://web.whatsapp.com/',
    'http://127.0.0.1:8787/'
)

function Test-DebugUp {
    try { Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

if (-not (Test-DebugUp)) {
    $flags = @(
        "--remote-debugging-port=$port",
        "--user-data-dir=$profile",
        '--profile-directory=Default',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-session-crashed-bubble',
        '--window-size=1400,900',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows',
        '--disable-renderer-backgrounding',
        '--disable-features=CalculateNativeWinOcclusion'
    )
    Start-Process -FilePath $chrome -ArgumentList $flags
    for ($i = 1; $i -le 25; $i++) {
        Start-Sleep -Milliseconds 700
        if (Test-DebugUp) { break }
    }
}

if (-not (Test-DebugUp)) { exit 3 }

# hub 不在就顺手拉起（与 HubWatch 同一动作，不阻塞）
if (-not $NoHub) {
    $hubOk = $false
    try { Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 2 | Out-Null; $hubOk = $true } catch { }
    if (-not $hubOk) {
        try { schtasks /Run /TN 'DSH_SocialOps_Hub' | Out-Null } catch { }
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Milliseconds 700
            try { Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 2 | Out-Null; break } catch { }
        }
    }
}

try {
    $tabs = Invoke-RestMethod "http://127.0.0.1:$port/json/list" -TimeoutSec 5
    $open = @($tabs | Where-Object { $_.type -eq 'page' } | ForEach-Object { $_.url })
    foreach ($u in $urls) {
        $key = $u.TrimEnd('/')
        $hit = $open | Where-Object { $_ -like "$key*" } | Select-Object -First 1
        if (-not $hit) {
            try { Invoke-RestMethod -Method Put ("http://127.0.0.1:$port/json/new?" + [uri]::EscapeDataString($u)) -TimeoutSec 8 | Out-Null } catch { }
            Start-Sleep -Milliseconds 400
        }
    }
    $tabs2 = Invoke-RestMethod "http://127.0.0.1:$port/json/list" -TimeoutSec 5
    $first = @($tabs2 | Where-Object { $_.type -eq 'page' -and $_.url -like 'http://127.0.0.1:8787*' })[0]
    if (-not $first) { $first = @($tabs2 | Where-Object { $_.type -eq 'page' })[0] }
    if ($first) {
        $cdp = Join-Path $here 'cdp_call.ps1'
        if (Test-Path $cdp) {
            & $cdp -Method 'Page.bringToFront' -ParamsJson '{}' -TargetId $first.id -TimeoutSec 8 2>$null | Out-Null
        }
    }
} catch { }

exit 0
