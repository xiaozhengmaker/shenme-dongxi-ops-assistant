$ErrorActionPreference = "SilentlyContinue"
$root = $PSScriptRoot
. (Join-Path $root "lib\paths.ps1")
$cfg = Get-GOpsConfig $root

function Line([string]$k, [string]$v, $ok) {
  if ($ok -eq $true) { $mark = "[OK]  " } elseif ($ok -eq $false) { $mark = "[!!]  " } else { $mark = "[--]  " }
  Write-Host ("{0}{1,-16} {2}" -f $mark, $k, $v)
}

function TaskField([string]$name, [string]$pattern) {
  $q = & schtasks.exe /Query /TN $name /FO LIST 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  $ln = @($q | Where-Object { $_ -match $pattern }) | Select-Object -First 1
  if (-not $ln) { return "" }
  return ($ln -replace '^[^:]*:\s*', '').Trim()
}

Write-Host "== 环境体检 ==" -ForegroundColor Cyan
Line "项目目录" $root $true
Line "PowerShell" $PSVersionTable.PSVersion.ToString() $true

$cfgPath = Join-Path $root "config.json"
Line "config.json" $(if (Test-Path $cfgPath) { "存在" } else { "缺失，先跑 install.ps1" }) (Test-Path $cfgPath)

$chrome = Get-GOpsChrome $cfg
Line "Chrome" $chrome (Test-Path $chrome)
$prof = Get-GOpsProfile $cfg
Line "调试 profile" $prof (Test-Path $prof)

$port = Get-GOpsPort $cfg
$tabs = $null
try { $tabs = (Invoke-WebRequest ("http://127.0.0.1:{0}/json/list" -f $port) -UseBasicParsing -TimeoutSec 4).Content | ConvertFrom-Json } catch { }
if ($tabs) { Line ("CDP :" + $port) ("在线，标签页 " + @($tabs).Count) $true }
else { Line ("CDP :" + $port) "连不上，先跑 start_chrome.ps1" $false }

if ($tabs) {
  $ext = @($tabs | Where-Object { $_.url -match "chrome-extension://" })
  if ($ext.Count -gt 0) { Line "扩展" ("已加载，页面 " + $ext.Count + " 个") $true }
  else { Line "扩展" "没看到扩展页面（未加载或没开侧边栏）" $false }
}

$hub = $null
try { $hub = Invoke-RestMethod "http://127.0.0.1:8787/health" -TimeoutSec 4 } catch { }
if ($hub) { Line "hub :8787" ("在线，phase=" + $hub.phase) $true }
else { Line "hub :8787" "没起，跑 run_hub.ps1" $false }

$db = Join-Path $root "data\groupops.db"
if (Test-Path $db) { Line "本地数据库" (([math]::Round((Get-Item $db).Length / 1MB, 1)).ToString() + " MB") $true }
else { Line "本地数据库" "未建，跑 db_init.ps1" $false }

$logDir = Join-Path $root "logs"
$logs = @(Get-ChildItem $logDir -File)
if ($logs.Count -gt 0) {
  $sz = [math]::Round((($logs | Measure-Object Length -Sum).Sum / 1MB), 1)
  Line "日志" ($logs.Count.ToString() + " 个文件 / " + $sz + " MB") $true
} else { Line "日志" "还没有日志" $null }

Write-Host ""
Write-Host "计划任务" -ForegroundColor Cyan
foreach ($tn in @("DSH_SocialOps_Steam", "DSH_SocialOps_Daily", "DSH_SocialOps_Report", "DSH_SocialOps_Hub")) {
  $st = TaskField $tn "^(Status|状态)"
  if ($null -eq $st) { Write-Host ("  [!!]  " + $tn + "  未注册"); continue }
  $nx = TaskField $tn "^(Next Run Time|下次运行时间)"
  if (-not $nx) { $nx = "-" }
  Write-Host ("  [OK]  {0}  status={1}   next={2}" -f $tn, $st, $nx)
}
