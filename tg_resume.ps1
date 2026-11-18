# tg_resume.ps1
# 恢复轮：只处理固定清单（retry_due + deferred_unsent），不吃快照前 N 条。
# 纪律：预算先落盘再发请求；420 触发项计费一次；三类互斥对账。
param(
  [int]$Budget = 50,
  [string]$Replay = "",
  [switch]$DryRun,
  [switch]$ResetState,
  [switch]$IgnoreCooldown,
  [int]$WaitSec = 20,
  [int]$MinMembers = 300
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
. (Join-Path $baseDir "lib\log.ps1")
. (Join-Path $baseDir "lib\flood.ps1")
if (Test-Path (Join-Path $baseDir "lib\stop.ps1")) { . (Join-Path $baseDir "lib\stop.ps1") }

Set-LogFile (Join-Path $baseDir "logs\tg_resume.log")
$dataDir = Join-Path $baseDir "data"
$cfgPath = Join-Path $baseDir "config.json"
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$recoveryOn = $true
try { if ($null -ne $cfg.resume.enabled) { $recoveryOn = [bool]$cfg.resume.enabled } } catch { }
if (-not $recoveryOn -and -not $Replay) { Write-Log "config.resume.enabled=false，退出"; exit 0 }

$floodPath = Join-Path $dataDir "flood_state.json"
$statePath = Join-Path $dataDir "tg_recovery_state.json"
$reportPath = Join-Path $dataDir ("tg_recovery_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")

function Read-Json([string]$p) {
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Save-Json([string]$p, $o) {
  $json = $o | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- 固定清单：retry_due + deferred_unsent（按目标身份去重） ----------
$flood = Read-Json $floodPath
if ($flood -and $flood.telegram) { $flood = $flood.telegram }
$origRun = ""
$retryDue = @()
$pending = @()
if ($flood) {
  $origRun = [string]$flood.original_run
  if (-not $origRun) { $origRun = [string]$flood.run_id }
  if ($flood.retry_due) { $retryDue = @([string]$flood.retry_due) }
  if ($flood.pending) { $pending = @($flood.pending | ForEach-Object { [string]$_ }) }
}

$st = Read-Json $statePath
if ($st) {
  if (-not $origRun) { $origRun = [string]$st.original_run }
  if (-not $retryDue.Count -and $st.targets) {
    $retryDue = @($st.targets | Where-Object { $_.status -eq "retry_due" } | ForEach-Object { [string]$_.u })
  }
  if (-not $pending.Count -and $st.targets) {
    $pending = @($st.targets | Where-Object { $_.status -eq "pending" } | ForEach-Object { [string]$_.u })
  }
}

$targets = @(@($retryDue) + @($pending) | Where-Object { $_ } | Select-Object -Unique)
if (-not $origRun) {
  $snapForRun = Get-ChildItem (Join-Path $dataDir "tg_links_snapshot_*.json") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($snapForRun) { try { $origRun = [string]((Get-Content $snapForRun.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).run_id) } catch { } }
}
if (-not $targets.Count -and $Replay) { $targets = @(); for ($i = 0; $i -lt 51; $i++) { $targets += ("replay" + $i) } }

$resumeRun = "resume-" + (Get-Date -Format "yyyyMMddHHmmss")
Write-Log ("[resume] original_run=" + $origRun + " targets=" + $targets.Count + " resume_run=" + $resumeRun + " budget=" + $Budget)

# ---------- 身份基线（开跑前冻结） ----------
$aliasPath = Join-Path $dataDir "tg_alias_shadow.jsonl"
$baselineIds = @{}
$baselineHandles = @{}
if (Test-Path $aliasPath) {
  foreach ($ln in Get-Content $aliasPath -Encoding UTF8) {
    if (-not $ln.Trim()) { continue }
    try {
      $o = $ln | ConvertFrom-Json
      if ($o.peer_id) { $baselineIds[[string]$o.peer_id] = 1 }
      if ($o.handle_norm) { $baselineHandles[([string]$o.handle_norm).ToLower()] = 1 }
    } catch { }
  }
}
$knownPath = Join-Path $dataDir "tg_known.json"
$knownHandles = @{}
if (Test-Path $knownPath) {
  try {
    $k = Get-Content $knownPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in @($k.PSObject.Properties)) { if ($p.Name) { $knownHandles[([string]$p.Name).ToLower()] = 1 } }
  } catch { }
}
$poolPath = Join-Path $dataDir "pool_telegram.json"
$poolKeys = @{}
if (Test-Path $poolPath) {
  try {
    $pl = Get-Content $poolPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($it in @($pl.items)) {
      if ($it.u) { $poolKeys[([string]$it.u).ToLower()] = 1 }
      if ($it.id) { $poolKeys[[string]$it.id] = 1 }
    }
  } catch { }
}

$rxTopic = '(?i)(cs2|cs:go|csgo|counter[\s\-]?strike|cs\s?1\.6|cs1\.6)'
$rxExcl = ""
try { $rxExcl = [string]$cfg.strategy.Telegram.filters.exclude_regex } catch { }

# ---------- 状态（先落盘再发请求） ----------
if (-not $st -or -not $st.targets -or $ResetState) {
  $st = [pscustomobject]@{
    original_run = $origRun
    resume_run   = $resumeRun
    budget       = $Budget
    sent         = 0
    sent_total   = 0
    targets      = @($targets | ForEach-Object { [pscustomobject]@{ u = $_; status = "pending"; verdict = ""; n = 0; peer_id = ""; err = ""; at = "" } })
  }
}
if ($ResetState) {
  $st.sent = 0
  foreach ($t in $st.targets) { $t.status = "pending"; $t.verdict = ""; $t.n = 0; $t.peer_id = ""; $t.err = "" }
}
$have = @{}
foreach ($t in $st.targets) { $have[[string]$t.u] = 1 }
foreach ($u in $targets) {
  if (-not $have.ContainsKey([string]$u)) {
    $st.targets = @($st.targets) + @([pscustomobject]@{ u = $u; status = "pending"; verdict = ""; n = 0; peer_id = ""; err = ""; at = "" })
  }
}
Save-Json $statePath $st

function Get-Target([string]$u) {
  foreach ($t in $st.targets) { if ($t.u -eq $u) { return $t } }
  return $null
}

# ---------- 单目标解析（真实平台） ----------
function Resolve-One([string]$u) {
  $js = @"
(async () => {
  const U = "__U__";
  try {
    const sc = (typeof rootScope !== "undefined") ? rootScope : window.rootScope;
    const api = (m, p) => sc.managers.apiManager.invokeApi(m, p);
    const c = await api("contacts.resolveUsername", { username: U });
    const ch = (c.chats || [])[0];
    if (!ch) { window.__dshRes = JSON.stringify({ ok: 1, u: U, miss: 1 }); return; }
    let n = 0;
    try {
      const f = await api("channels.getFullChannel", { channel: { _: "inputChannel", channel_id: ch.id, access_hash: ch.access_hash } });
      n = (f.full_chat && f.full_chat.participants_count) || 0;
    } catch (e1) {
      try { const f2 = await api("messages.getFullChat", { chat_id: ch.id }); n = (f2.full_chat && f2.full_chat.participants_count) || 0; } catch (e2) { }
    }
    window.__dshRes = JSON.stringify({ ok: 1, u: U, id: String(ch.id), type: ch._, handle: ch.username || "", n: n, jr: !!ch.join_request });
  } catch (e) {
    window.__dshRes = JSON.stringify({ ok: 0, u: U, err: String((e && e.message) || e) });
  }
})()
"@
  $js = $js.Replace("__U__", $u)
  $cdp = Join-Path $baseDir "cdp_call.ps1"
  $p = @{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 4
  $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram" -TimeoutSec 60 2>&1
  $txt = ($raw | Out-String)
  $m = [regex]::Match($txt, '(?s)__dshRes[^}]*\}|"value":"(.*?)"\s*\}')
  try {
    $outer = $txt | ConvertFrom-Json
    $s = [string]$outer.result.value
    if ($s) { return ($s | ConvertFrom-Json) }
  } catch { }
  return [pscustomobject]@{ ok = 0; u = $u; err = "no_reply" }
}

# ---------- 回放（离线，不发请求） ----------
function Invoke-Replay([string]$mode) {
  $sent = 0
  foreach ($t in $st.targets) {
    if ($sent -ge $st.budget) { break }
    if ($t.status -ne "pending") { continue }
    $sent++
    $st.sent = $sent
    $st.sent_total = [int]$st.sent_total + 1
    if ($mode -eq "first_420" -and $sent -eq 1) {
      $t.status = "retry_due"; $t.verdict = "rate_limited"; $t.err = "FLOOD_WAIT_67649"
      Save-Json $statePath $st
      break
    }
    $t.status = "done"; $t.verdict = "dup"; $t.n = 500; $t.peer_id = ("900" + $sent)
    Save-Json $statePath $st
  }
  return $sent
}

# ---------- 主循环 ----------
# 预算按「本轮」计；累计另记 sent_total。到期把 retry_due 转回 pending。
if (-not $st.PSObject.Properties["sent_total"]) { $st | Add-Member -NotePropertyName sent_total -NotePropertyValue 0 }
$sent = 0
$blockedNow = $false
try { $blockedNow = Test-FloodBlocked "telegram" } catch { }
if ($IgnoreCooldown) { $blockedNow = $false }
if (-not $blockedNow) {
  foreach ($t in $st.targets) { if ($t.status -eq "retry_due") { $t.status = "pending"; Write-Log ("[resume] retry_due 到期转入待处理: " + $t.u) } }
  Save-Json $statePath $st
}
if ($Replay) {
  $sent = Invoke-Replay $Replay
  Write-Log ("[resume][replay:" + $Replay + "] sent=" + $sent)
} else {
  if (Test-FloodBlocked "telegram") {
    $dl = Get-FloodDeadline "telegram"
    Write-Log ("[resume] 冷却中，retry_not_before=" + $dl + "，本轮 0 请求")
  } else {
    foreach ($u in $targets) {
      if ($sent -ge $Budget) { Write-Log "[resume] 预算用尽"; break }
      if (Test-Path (Join-Path $baseDir "lib\stop.ps1")) { try { if (Test-GOpsStop $baseDir) { Write-Log "[resume] stop.flag"; break } } catch { } }
      if (Test-FloodBlocked "telegram") { Write-Log "[resume] 冷却中，停止"; break }
      $t = Get-Target $u
      if (-not $t -or $t.status -ne "pending") { continue }

      # 预算预留：先落盘再发
      $t.status = "sending"; $t.at = (Get-Date).ToString("o")
      $sent++
      $st.sent = $sent
      $st.sent_total = [int]$st.sent_total + 1
      Save-Json $statePath $st

      $r = Resolve-One $u
      if (-not $r -or -not $r.ok) {
        $err = [string]($r.err)
        if ($err -match "FLOOD_WAIT_(\d+)") {
          $w = [int]$Matches[1]
          $rest = @($targets | Where-Object { $_ -ne $u })
          $t.status = "retry_due"; $t.verdict = "rate_limited"; $t.err = $err
          Save-Json $statePath $st
          Set-FloodBlocked "telegram" $w $u $rest | Out-Null
          Write-Log ("[resume] 420 at " + $u + " wait=" + $w + "s，其余结转")
          break
        }
        if ($err -match "USERNAME_INVALID|USERNAME_NOT_OCCUPIED|CHANNEL_PRIVATE") {
          $t.status = "terminated"; $t.verdict = "gone"; $t.err = $err
        } else {
          $t.status = "send_unknown"; $t.err = $err
        }
        Save-Json $statePath $st
        continue
      }
      if ($r.miss) { $t.status = "terminated"; $t.verdict = "miss"; Save-Json $statePath $st; continue }

      $t.peer_id = [string]$r.id
      $t.n = [int]$r.n
      $low = $u.ToLower()
      $isDup = $knownHandles.ContainsKey($low) -or $poolKeys.ContainsKey($low) -or ($r.id -and $poolKeys.ContainsKey([string]$r.id)) -or $baselineHandles.ContainsKey($low) -or ($r.id -and $baselineIds.ContainsKey([string]$r.id))
      $topicOk = [regex]::IsMatch([string]$r.handle + " " + $u, $rxTopic)
      $excl = $false
      if ($rxExcl) { try { $excl = [regex]::IsMatch($u, $rxExcl) } catch { } }
      $verdict = "usable"
      if ($isDup) { $verdict = "dup" }
      elseif (-not $topicOk) { $verdict = "topic" }
      elseif ($excl) { $verdict = "excluded" }
      elseif ([int]$r.n -lt $MinMembers) { $verdict = "small" }
      elseif ($r.jr) { $verdict = "join_request" }
      $t.verdict = $verdict
      $t.status = "done"
      Save-Json $statePath $st
    }
  }
}

# ---------- 对账 ----------
$done = @($st.targets | Where-Object { $_.status -eq "done" }).Count
$terminated = @($st.targets | Where-Object { $_.status -eq "terminated" }).Count
$pendingN = @($st.targets | Where-Object { $_.status -eq "pending" }).Count
$sendUnknown = @($st.targets | Where-Object { $_.status -eq "send_unknown" }).Count
$retryN = @($st.targets | Where-Object { $_.status -eq "retry_due" }).Count

$resolvedThisRun = @($st.targets | Where-Object { $_.status -eq "done" }).Count
$firstSeen = @($st.targets | Where-Object { $_.status -eq "done" -and $_.peer_id -and -not $baselineIds.ContainsKey([string]$_.peer_id) }).Count
$newUsable = @($st.targets | Where-Object { $_.status -eq "done" -and $_.verdict -eq "usable" }).Count

$report = [ordered]@{
  original_run       = $origRun
  resume_run         = $resumeRun
  mode               = $(if ($Replay) { "replay:" + $Replay } else { "live" })
  budget             = $st.budget
  targets            = @($st.targets).Count
  sent               = [int]$st.sent
  sent_total         = [int]$st.sent_total
  done               = $done
  terminated         = $terminated
  pending            = $pendingN
  retry_due          = $retryN
  send_unknown       = $sendUnknown
  resolved_this_run  = $resolvedThisRun
  first_seen         = $firstSeen
  new_usable_300     = $newUsable
  reconcile_ok       = (($done + $terminated + $pendingN + $retryN + $sendUnknown) -eq @($st.targets).Count)
  at                 = (Get-Date).ToString("o")
}
Save-Json $reportPath $report
Write-Log ("[resume] report " + ($report | ConvertTo-Json -Compress))
try {
  $body = @{ msg = ("tg resume sent=" + $report.sent + " done=" + $done + " pending=" + $report.pending + " usable=" + $newUsable) } | ConvertTo-Json -Compress
  Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -TimeoutSec 10 | Out-Null
} catch { }
$report | ConvertTo-Json -Compress
