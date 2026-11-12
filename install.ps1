param([switch]$SkipTasks, [switch]$SkipDb)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
. (Join-Path $root "lib\paths.ps1")

function Step($n, $t) { Write-Host ("[{0}] {1}" -f $n, $t) -ForegroundColor Cyan }
function Ok($t)   { Write-Host ("    OK  " + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ("    !!  " + $t) -ForegroundColor Yellow }

Step 1 "检查配置文件"
$cfgPath = Join-Path $root "config.json"
if (-not (Test-Path $cfgPath)) {
  Copy-Item (Join-Path $root "config.example.json") $cfgPath
  Warn "已生成 config.json（无凭据）。请填 feishu.app_id / app_secret / base_app_token / table_id 后重跑本脚本。"
  return
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
Ok ("config.json 存在，平台 " + (@($cfg.platforms) -join "/"))
if (-not $cfg.feishu.app_secret -or ([string]$cfg.feishu.app_secret).Length -lt 10) {
  Warn "feishu.app_secret 为空，飞书写入会失败"
}

Step 2 "创建目录"
foreach ($d in @("data", "logs", "dist", "docs")) {
  $p = Join-Path $root $d
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
Ok "data / logs / dist / docs 就绪"

Step 3 "检查 Chrome 与调试 profile"
$chrome = Get-GOpsChrome $cfg
if (Test-Path $chrome) { Ok ("Chrome: " + $chrome) } else { Warn ("找不到 Chrome: " + $chrome) }
$prof = Get-GOpsProfile $cfg -Create
Ok ("调试 profile: " + $prof)
Write-Host ("    提示：首次启动要用 start_chrome.ps1，并在该窗口里登录 TG / FB / RD / Steam / WA")

Step 4 "检查 Python（本地数据库需要）"
$dbLib = Join-Path $root "lib\db.ps1"
if (Test-Path $dbLib) {
  . $dbLib
  try {
    $pyExe = Get-DbPython
    if ($pyExe) { Ok ("python: " + $pyExe) } else { Warn "没找到 python，本地数据库功能不可用（其余功能不受影响）" }
  } catch { Warn ("python 检测失败: " + $_.Exception.Message) }
} else { Warn "lib\db.ps1 缺失" }

Step 5 "初始化本地数据库"
if ($SkipDb) { Warn "已跳过（-SkipDb）" }
elseif (Test-Path $dbLib) {
  try { Initialize-LocalDb; Ok "data\groupops.db 就绪" } catch { Warn ("建库失败: " + $_.Exception.Message) }
}

Step 6 "注册计划任务"
if ($SkipTasks) { Warn "已跳过（-SkipTasks）" }
else {
  $ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
  $tasks = @(
    @{ n = "DSH_SocialOps_Steam";  tr = "$ps `"$root\steam_daily.ps1`" -MaxPages 40 -DelayMs 12000"; s = "09:30" },
    @{ n = "DSH_SocialOps_Daily";  tr = "$ps `"$root\run_daily.ps1`"";  s = "10:00" },
    @{ n = "DSH_SocialOps_Report"; tr = "$ps `"$root\report_all.ps1`""; s = "21:00" },
    @{ n = "DSH_SocialOps_Hub";    tr = "$ps `"$root\run_hub.ps1`"";    s = "" }
  )
  foreach ($t in $tasks) {
    if ($t.s) {
      $null = schtasks.exe /Create /TN $t.n /TR $t.tr /SC DAILY /ST $t.s /F /RL LIMITED 2>&1
    } else {
      $null = schtasks.exe /Create /TN $t.n /TR $t.tr /SC ONLOGON /F /RL LIMITED 2>&1
    }
    if ($LASTEXITCODE -eq 0) { Ok $t.n } else { Warn ($t.n + " 注册失败") }
  }
}

Write-Host ""
Write-Host "== 装好了，接下来 3 步 ==" -ForegroundColor Cyan
Write-Host "  1) powershell -File .\start_chrome.ps1         # 起调试 Chrome，然后登录各平台"
Write-Host "  2) chrome://extensions -> 开发者模式 -> 加载未打包 -> 选 extension 目录"
Write-Host "  3) powershell -File .\check.ps1               # 八项自检，看到「可以开工」即可"
Write-Host "  有问题先跑 .\doctor.ps1 看环境体检"
