param([string]$Platform = "")
$ErrorActionPreference = "SilentlyContinue"
$rootDir = $PSScriptRoot
$hubUrl = "http://127.0.0.1:8787"
$ok = $true

function CdpVal([string]$expr, [string]$match) {
  $pp = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
  for ($i = 1; $i -le 2; $i++) {
    $v = (& (Join-Path $script:rootDir "cdp_call.ps1") -Method "Runtime.evaluate" -ParamsJson $pp -Match $match | Out-String).Trim()
    if ($v -and $v -notmatch "recv timeout") { return $v }
    Start-Sleep -Milliseconds 800
  }
  return $v
}
function Line([string]$label, [bool]$good, [string]$detail) {
  $mark = if ($good) { "[OK]" } else { "[!!]" }
  if (-not $good) { $script:ok = $false }
  "{0} {1,-14} {2}" -f $mark, $label, $detail
}

# 1) hub
$hub = $null
$hubErr = ""
for ($i = 1; $i -le 3; $i++) { try { $hub = Invoke-RestMethod "$hubUrl/health" -TimeoutSec 8; break } catch { $hubErr = $_.Exception.Message; Start-Sleep -Milliseconds 700 } }
Line "hub" ([bool]$hub) ($(if ($hub) { "phase=" + $hub.phase + " running=" + $hub.running } else { "无响应: " + $hubErr + " | 试 Start-ScheduledTask -TaskName DSH_SocialOps_Hub" }))

# 2) TG session
$aliveJs = [System.IO.File]::ReadAllText((Join-Path $rootDir "data\tg_alive.js"), [System.Text.Encoding]::UTF8)
$p = @{ expression = $aliveJs; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
$tg = CdpVal $aliveJs "web.telegram.org"
$tgOk = $tg -match "alive"
Line "TG session" $tgOk ($(if ($tgOk) { "alive" } else { "dead / no tab —— 去 web.telegram.org 刷新或重扫码：" + $tg }))

# 3) FB login
$fbJs = "(() => (document.cookie || '').indexOf('c_user=') >= 0 ? 'login' : 'logout')()"
$p2 = @{ expression = $fbJs; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
$fb = CdpVal $fbJs "facebook.com"
$fbOk = $fb -match "login"
Line "FB login" $fbOk ($(if ($fbOk) { "c_user 存在" } else { "未登录 / 无标签页：" + $fb }))

# 4) data delta
$jsonl = Join-Path $rootDir "data\users.jsonl"
$rows = 0
if (Test-Path $jsonl) { $rows = (Get-Content $jsonl -Encoding UTF8 | Measure-Object -Line).Lines }
$today = (Get-Date).ToString("yyyy/MM/dd")
$todayRows = 0
if (Test-Path $jsonl) {
  $todayRows = (Get-Content $jsonl -Encoding UTF8 | Select-String -SimpleMatch $today | Measure-Object).Count
}
Line "user samples" ($rows -gt 0) ("total=" + $rows + " today=" + $todayRows)

# 5) summary
if ($hub) {
  $s = Invoke-RestMethod "$hubUrl/api/summary" -TimeoutSec 20
  Line "table" ($s.totals.groups -gt 0) ("groups=" + $s.totals.groups + " members=" + $s.totals.members + " today+=" + $s.totals.todayGroups)
  $todo = @($s.todos)
  Line "todos" ($true) ("open=" + $todo.Count)
}

# 6) zero-member rows (数据巡检：已加入但人数为 0 一定是解析/回填问题)
$zeroList = @()
try {
  . (Join-Path $rootDir "lib\feishu.ps1")
  $vrecs = Get-FsRecords
  foreach ($r in $vrecs) {
    $st = [string]$r.fields."状态"
    if ($st -eq "已退出" -or $st -eq "已失效") { continue }
    $mv = $r.fields."成员数"
    $mn = 0
    if ($mv -ne $null) { [void][double]::TryParse((([string]$mv) -replace "[^0-9]", ""), [ref]$mn) }
    if ($mn -le 0) {
      $nm = [string]$r.fields."群名"
      if (-not $nm) { $nm = [string]$r.fields."群组唯一键" }
      $zeroList += ($nm + "(" + [string]$r.fields."平台" + ")")
    }
  }
} catch { $zeroList = @("巡检异常: " + $_.Exception.Message) }
Line "zero members" ($zeroList.Count -eq 0) ($(if ($zeroList.Count -eq 0) { "已加入记录的成员数均 > 0" } else { $zeroList.Count.ToString() + " 条人数为 0：" + (($zeroList | Select-Object -First 5) -join " / ") + " —— 跑 tg_fix_counts.ps1 或查解析层" }))

# 8) local db
. (Join-Path $rootDir "lib\db.ps1")
$dbStat = Get-DbStats
if ($dbStat.ok) {
  Line "local db" $true ("rows=" + $dbStat.rows + " groups=" + $dbStat.groups + " size=" + $dbStat.size_mb + "MB -> " + $dbStat.path)
} else {
  Line "local db" $false ("未初始化（点看板「初始化数据库」或跑 db_init.ps1）: " + $dbStat.path)
}

# 7) recent errors
$logDir = Join-Path $rootDir "logs"
$errs = @()
$cut = (Get-Date).AddMinutes(-10)
Get-ChildItem $logDir -Filter *.log -ErrorAction SilentlyContinue | ForEach-Object {
  $lines = Get-Content $_.FullName -Encoding UTF8 -Tail 400
  foreach ($ln in $lines) {
    if ($ln -notmatch "\[ERROR\]") { continue }
    if ($ln -match "^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]") {
      try { if ([datetime]::ParseExact($Matches[1], "yyyy-MM-dd HH:mm:ss", $null) -lt $cut) { continue } } catch {}
    }
    $errs += "$($_.Name): $ln"
  }
}
Line "log errors" ($errs.Count -eq 0) ($(if ($errs.Count -eq 0) { "近 10 分钟无 ERROR" } else { $errs.Count.ToString() + " 条，见 logs\*.log" }))

""
if ($ok) { "== 可以开工 ==" } else { "== 有红灯，先处理上面 [!!] 的行 ==" }
if (-not $ok) { exit 7 }