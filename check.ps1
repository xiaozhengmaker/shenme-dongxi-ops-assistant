param([string]$Platform = "", [switch]$SelfTest)
$ErrorActionPreference = "SilentlyContinue"
$rootDir = $PSScriptRoot
$hubUrl = "http://127.0.0.1:8787"
$ok = $true
$cdp = Join-Path $rootDir "cdp_call.ps1"

# 有界重探：超时 / 空 DOM / null 视为「暂时不可判定」，最多 3 次，其间先 reload 再试
function Get-MainTargetId([string]$pattern) {
  # 只在真正的页面里挑（排除 worker / blob / .js），否则 -Match 会命中 worker 目标
  try {
    $all = Invoke-RestMethod "http://127.0.0.1:9222/json/list" -TimeoutSec 8
    $c = @($all | Where-Object { $_.type -eq "page" -and ([string]$_.url) -like ("*" + $pattern + "*") -and ([string]$_.url) -notmatch "\.js|blob:|\.worker" })
    if ($c.Count -gt 0) { return [string]$c[0].id }
  } catch { }
  return ""
}
function Invoke-CdpEval([string]$expr, [string]$match, [int]$tries = 3, [string]$targetId = "") {
  $pp = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
  $last = ""
  for ($i = 1; $i -le $tries; $i++) {
    if ($targetId) { $v = (& $script:cdp -Method "Runtime.evaluate" -ParamsJson $pp -TargetId $targetId | Out-String).Trim() }
    else { $v = (& $script:cdp -Method "Runtime.evaluate" -ParamsJson $pp -Match $match | Out-String).Trim() }
    $last = $v
    if ($v -and $v -notmatch "recv timeout" -and $v -notmatch '^null$' -and $v -notmatch '"empty"') { return $v }
    if ($i -lt $tries) {
      try {
        if ($targetId) { & $script:cdp -Method "Page.reload" -ParamsJson '{}' -TargetId $targetId | Out-Null }
        else { & $script:cdp -Method "Page.reload" -ParamsJson '{}' -Match $match | Out-Null }
      } catch { }
      Start-Sleep -Milliseconds (600 * $i)
    }
  }
  return $last
}
function CdpNavigate([string]$url, [string]$match, [string]$targetId = "") {
  try {
    $pp = @{ url = $url } | ConvertTo-Json -Compress
    if ($targetId) {
      try { & $script:cdp -Method "Page.bringToFront" -ParamsJson "{}" -TargetId $targetId | Out-Null } catch { }
      & $script:cdp -Method "Page.navigate" -ParamsJson $pp -TargetId $targetId | Out-Null
    } else {
      & $script:cdp -Method "Page.navigate" -ParamsJson $pp -Match $match | Out-Null
    }
    Start-Sleep -Seconds 3
    return $true
  } catch { return $false }
}
function Get-SessionVerdict([string]$raw, [string]$kind) {
  # 返回 ok / lost / dead：lost = 明确的登录失效（登录页/扫码），dead = 页面在但未初始化/无标签
  if (-not $raw) { return "dead" }
  if ($raw -match "recv timeout") { return "dead" }
  if ($kind -eq "tg") {
    if ($raw -match '\\?"login\\?"\s*:\s*true|qr|phone-code|LoginPage') { return "lost" }
    if ($raw -match "alive") { return "ok" }
    return "dead"
  } else {
    if ($raw -match "loginpage") { return "lost" }
    if ($raw -match "login") { return "ok" }
    return "dead"
  }
}
if ($SelfTest) {
  $cases = @(
    @{ kind = "tg"; raw = '{"result":{"type":"string","value":"alive"}}'; want = "ok" },
    @{ kind = "tg"; raw = '{"result":{"type":"string","value":"dead"}}'; want = "dead" },
    @{ kind = "tg"; raw = '{"result":{"type":"string","value":"no-root"}}'; want = "dead" },
    @{ kind = "tg"; raw = '{"result":{"type":"string","value":"{\"login\":true}"}}'; want = "lost" },
    @{ kind = "tg"; raw = 'ERR: recv timeout'; want = "dead" },
    @{ kind = "fb"; raw = '{"result":{"type":"string","value":"login"}}'; want = "ok" },
    @{ kind = "fb"; raw = '{"result":{"type":"string","value":"loginpage"}}'; want = "lost" },
    @{ kind = "fb"; raw = '{"result":{"type":"string","value":"empty"}}'; want = "dead" },
    @{ kind = "fb"; raw = ''; want = "dead" }
  )
  $fail = 0
  foreach ($c in $cases) {
    $got = Get-SessionVerdict $c.raw $c.kind
    $okc = ($got -eq $c.want)
    if (-not $okc) { $fail++ }
    "{0} selftest {1,-3} want={2,-5} got={3}" -f $(if ($okc) { "[OK]" } else { "[!!]" }), $c.kind, $c.want, $got
  }
  ""
  if ($fail -eq 0) { "== SELFTEST PASS (9/9) ==" ; exit 0 } else { "== SELFTEST FAIL (" + $fail + ") ==" ; exit 8 }
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

# 2) TG session（暂时超时/空 DOM → 有界重探；明确登录失效 → 立即报红不再试）
$aliveJs = [System.IO.File]::ReadAllText((Join-Path $rootDir "data\tg_alive.js"), [System.Text.Encoding]::UTF8)
$tgId = Get-MainTargetId "web.telegram.org"
$tg = if ($tgId) { Invoke-CdpEval $aliveJs "web.telegram.org" 3 $tgId } else { "no-tab" }
$tgLostEarly = ($tg -match '\\?"login\\?"\s*:\s*true|qr|phone-code|LoginPage')
$tgTransient = (-not $tg) -or ($tg -match "recv timeout") -or ($tg -match '^null$') -or ($tg -match "no-root") -or (($tg -match '"dead"') -and (-not $tgLostEarly))
if ($tgTransient) {
  # 标签存在但渲染空白：导航回 /k/ 再重探两次
  if ($tgId) { try { & $script:cdp -Method "Page.bringToFront" -ParamsJson "{}" -TargetId $tgId | Out-Null } catch { } }   if (CdpNavigate "https://web.telegram.org/k/" "web.telegram.org" $tgId) { $tg = if ($tgId) { Invoke-CdpEval $aliveJs "web.telegram.org" 3 $tgId } else { $tg } }
}
$tgOk = $tg -match "alive"
$tgLost = ($tg -match '\\?"login\\?"\s*:\s*true|qr|phone-code|LoginPage')
if ($tgLost) {
  Line "TG session" $false ("登录失效（需重新扫码/手机确认），不当成暂时超时重试：" + $tg)
} elseif ($tgOk) {
  Line "TG session" $true "alive"
} else {
  $tgDetail = if ($tg -match "no-root") { "标签在但页面空白（后台节流）：点一下该标签或跑 open_browser.ps1 让页面渲染" } else { "dead / no tab —— 去 web.telegram.org 刷新或重扫码：" + $tg } Line "TG session" $false $tgDetail
}

# 3) FB login（cookie + 页面就绪双判据；空白页先补导航/重探，明确登录页立即报红）
$fbJs = "(() => { try { if ((document.cookie || '').indexOf('c_user=') >= 0) return 'login'; } catch (e) { } var u = String(location.href || ''); if (/\/login|checkpoint|\/recover/.test(u)) return 'loginpage'; var t = (document.body ? (document.body.innerText || '') : ''); if (t.replace(/\s+/g, '').length < 20) return 'empty'; return 'logout'; })()"
$fbId = Get-MainTargetId "facebook.com"
$fb = if ($fbId) { Invoke-CdpEval $fbJs "facebook.com" 3 $fbId } else { "no-tab" }
if ((-not $fb) -or ($fb -match "recv timeout") -or ($fb -match '^null$') -or ($fb -match 'empty')) {
  if (CdpNavigate "https://www.facebook.com/" "facebook.com" $fbId) { $fb = if ($fbId) { Invoke-CdpEval $fbJs "facebook.com" 2 $fbId } else { $fb } }
}
$fbOk = $fb -match "login"
$fbLost = $fb -match "loginpage"
if ($fbLost) {
  Line "FB login" $false ("登录失效（跳到了登录/验证页），不当成暂时超时重试：" + $fb)
} elseif ($fbOk) {
  Line "FB login" $true "c_user 存在"
} else {
  Line "FB login" $false ("未登录 / 页面未就绪（已重探 3 次）：" + $fb)
}

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

# 6) zero-member rows
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