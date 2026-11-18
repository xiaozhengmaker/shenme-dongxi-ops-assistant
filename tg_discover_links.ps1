# tg_discover_links.ps1 -- 从已加入的 TG 群里挖 t.me 链接 / @username，解析后写入候选池

# v2：双阶段分批 + 断点续跑（避免单次 JS 超过 CDP 超时）

param(

  [int]$MaxGroups = 120,

  [int]$PerGroup = 100,

  [int]$ResolveCap = 90,

  [int]$MinMembers = 150,

  [int]$BatchGroups = 15,

  [int]$BatchResolve = 20,
  [int]$CompareMin = 150,
  [switch]$NoRejects,

  [int]$TimeBudgetSec = 240,

  [switch]$Reset,

  [switch]$DryRun

)

$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $baseDir "lib\log.ps1")

if (Test-Path (Join-Path $baseDir "lib\stop.ps1")) { . (Join-Path $baseDir "lib\stop.ps1") }

Set-LogFile (Join-Path $baseDir "logs\tg_links.log")

$cdp = Join-Path $baseDir "cdp_call.ps1"

$statePath = Join-Path $baseDir "data\tg_links_state.json"

$started = Get-Date



function Ev([string]$m) {

  try { Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ msg = $m } | ConvertTo-Json -Compress))) -ContentType "application/json; charset=utf-8" -TimeoutSec 8 | Out-Null } catch {}

}

function BudgetLeft { return ($TimeBudgetSec - ((Get-Date) - $started).TotalSeconds) }

function Stopped { try { return (Test-GOpsStop ) } catch { return $false } }



# 在页面里跑一段 JS，返回解析后的对象；失败返回 $null

function Invoke-TgJs([string]$expr, [int]$timeoutSec) {

  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress

  $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram" -TimeoutSec $timeoutSec

  $line = @($raw) | Where-Object { ([string]$_).Trim().StartsWith("{") } | Select-Object -Last 1

  if (-not $line) { Write-Log ("CDP 无有效返回: " + [string]$raw); return $null }

  try {

    $outer = [string]$line | ConvertFrom-Json

    $inner = [string]$outer.result.value

    if (-not $inner) { return $null }

    return ($inner | ConvertFrom-Json)

  } catch { Write-Log ("解析失败: " + $_.Exception.Message); return $null }

}



# 断点

$st = $null

if ((Test-Path $statePath) -and (-not $Reset)) {

  try { $st = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $st = $null }

}

if (-not $st) {

  $st = [pscustomobject]@{ phase = "harvest"; dialogsN = 0; groupIdx = 0; links = @{}; resolved = @(); startedAt = (Get-Date).ToString("s") }

}

# links 统一成 Hashtable：PSCustomObject 上给不存在的属性赋值会静默失败（曾导致只统计到第一批）
$linksHash = @{}
if ($st.links) {
  foreach ($lp in $st.links.PSObject.Properties) {
    if ($lp.Name -and $lp.Name -notin @("Keys", "Values", "Count")) { $iv = 0; if ([int]::TryParse([string]$lp.Value, [ref]$iv)) { $linksHash[$lp.Name] = $iv } else { $linksHash[$lp.Name] = 0 } }
  }
}
$st | Add-Member -NotePropertyName links -NotePropertyValue $linksHash -Force

if (-not $st.resolved) { $st | Add-Member -NotePropertyName resolved -NotePropertyValue @() -Force }



function Save-State {

  [System.IO.File]::WriteAllText($statePath, ($st | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

}



Write-Log ("=== 开始 phase=" + $st.phase + " groupIdx=" + $st.groupIdx + " 已解析=" + @($st.resolved).Count + " ===")

Ev ("tg links start phase=" + $st.phase + " idx=" + $st.groupIdx)



if (Stopped) { Write-Log "检测到 stop.flag，退出"; exit 0 }



# ---------- 阶段一：把会话列表放进页面全局，供后续按序号切片 ----------

if ($st.dialogsN -le 0) {

  $jsDialogs = @'

(async () => {

  const api = (m, p) => rootScope.managers.apiManager.invokeApi(m, p);

  const dl = await api("messages.getDialogs", { limit: __MAXG__, offset_date: 0, offset_id: 0, offset_peer: { _: "inputPeerEmpty" }, hash: 0 });

  const chats = (dl.chats || []).filter(c => c._ === "channel" || c._ === "chat");

  window.__goD = chats.slice(0, __MAXG__);

  return JSON.stringify({ n: window.__goD.length });

})()

'@.Replace("__MAXG__", [string]$MaxGroups)

  $r = Invoke-TgJs $jsDialogs 60

  if (-not $r) { Write-Log "读取会话列表失败"; exit 4 }

  $st.dialogsN = [int]$r.n

  $st.groupIdx = 0

  Save-State

  Write-Log ("会话列表 " + $st.dialogsN + " 个")

}

if ($st.dialogsN -le 0) { Write-Log "没有可扫描的会话"; exit 0 }



# ---------- 阶段二：分批读历史，累加链接 ----------

$jsHarvest = @'

(async () => {

  const api = (m, p) => rootScope.managers.apiManager.invokeApi(m, p);

  const src = (window.__goD || []).slice(__FROM__, __TO__);

  const re1 = /(?:t(?:elegram)?\.me\/)(?:joinchat\/)?([A-Za-z0-9_+\-]{4,})/g;

  const re2 = /(?:^|[^A-Za-z0-9_])@([A-Za-z][A-Za-z0-9_]{4,31})/g;

  const out = { msgs: 0, links: {}, done: 0, groups: 0 };

  for (const c of src) {

    try {

      const peer = (c._ === "chat") ? { _: "inputPeerChat", chat_id: c.id }

        : { _: "inputPeerChannel", channel_id: c.id, access_hash: c.access_hash };

      const h = await api("messages.getHistory", { peer: peer, offset_id: 0, offset_date: 0, add_offset: 0, limit: __PER__, max_id: 0, min_id: 0, hash: 0 });

      const msgs = (h.messages || []);

      out.msgs += msgs.length;

      for (const m of msgs) {

        const txt = (m.message || "") + " " + ((m.entities || []).map(e => e.url || "").join(" "));

        let mm;

        while ((mm = re1.exec(txt)) !== null) { const u = mm[1].toLowerCase(); out.links[u] = (out.links[u] || 0) + 1; }

        while ((mm = re2.exec(txt)) !== null) { const u = mm[1].toLowerCase(); out.links[u] = (out.links[u] || 0) + 1; }

      }

      out.done++;

    } catch (e) { out.done++; }

  }

  out.groups = src.length;

  return JSON.stringify(out);

})()

'@



while ($st.phase -eq "harvest" -and $st.groupIdx -lt $st.dialogsN) {

  if (Stopped) { Write-Log "stop.flag，保存断点退出"; Save-State; exit 0 }

  if ((BudgetLeft) -lt 40) { Write-Log ("时间预算不足，保存断点退出（groupIdx=" + $st.groupIdx + "）"); Save-State; Ev "tg links budget pause"; exit 0 }

  $from = [int]$st.groupIdx

  $to = [Math]::Min($from + $BatchGroups, [int]$st.dialogsN)

  $js = $jsHarvest.Replace("__FROM__", [string]$from).Replace("__TO__", [string]$to).Replace("__PER__", [string]$PerGroup)

  $r = Invoke-TgJs $js ([Math]::Min(180, [Math]::Max(60, [int](BudgetLeft))))

  if (-not $r) { Write-Log "本批读取失败，保存断点退出"; Save-State; exit 4 }

  # 合并链接计数

  foreach ($k in @($r.links.PSObject.Properties)) {
    $kn = [string]$k.Name
    if (-not $kn) { continue }
    if ($st.links.ContainsKey($kn)) { $st.links[$kn] = [int]$st.links[$kn] + [int]$k.Value } else { $st.links[$kn] = [int]$k.Value }
  }

  $st.groupIdx = $to

  Save-State

  Write-Log ("批 " + $from + "-" + $to + " msgs=" + $r.msgs + " 唯一链接累计=" + $st.links.Count + " 用时=" + [int]((Get-Date) - $started).TotalSeconds + "s")

  Ev ("tg harvest " + $to + "/" + $st.dialogsN)

}

if ($st.phase -eq "harvest") { $st.phase = "resolve"; Save-State; Write-Log ("历史扫描完成，唯一链接 " + $st.links.Count) }



# ---------- 阶段三：分批解析用户名 ----------

$jsResolve = @'

(async () => {

  const api = (m, p) => rootScope.managers.apiManager.invokeApi(m, p);

  const names = __NAMES__;

  const out = { items: [] };

  for (const u of names) {

    try {

      const c = await api("contacts.resolveUsername", { username: u });

      const ch = (c.chats || [])[0];

      if (!ch) { out.items.push({ u: u, miss: 1 }); continue; }

      let n = 0, jr = false;

      try {

        if (ch._ === "channel") {

          const f = await api("channels.getFullChannel", { channel: { _: "inputChannel", channel_id: ch.id, access_hash: ch.access_hash } });

          n = (f.full_chat && f.full_chat.participants_count) || 0;

          jr = !!(f.full_chat && f.full_chat.join_request);

        } else if (ch._ === "chat") {

          const f = await api("messages.getFullChat", { chat_id: ch.id });

          n = (f.full_chat && f.full_chat.participants_count) || 0;

        }

      } catch (e) {}

      out.items.push({ u: u, t: ch.title || "", n: n, bc: !!ch.broadcast, jr: jr, id: String(ch.id), h: String(ch.access_hash || ""), k: (ch._ === "channel" ? "channel" : "chat") });

    } catch (e) { out.items.push({ u: u, miss: 1, err: String((e && (e.error_message || e.message)) || e || "").slice(0, 160) }); }

  }

  return JSON.stringify(out);

})()

'@



if (-not $DryRun) {
  $snapId = "run-" + (([string]$st.startedAt) -replace "[^0-9]", "")
  $snapDir = Join-Path $baseDir "data"
  $snapFile = Join-Path $snapDir ("tg_links_snapshot_" + $snapId + ".json")
  $snapObj = @{
    run_id = $snapId
    taken_at = (Get-Date).ToString("s")
    count = @($st.links.Keys).Count
    links = @($st.links.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { @{ u = [string]$_.Key; hits = [int]$_.Value } })
  }
  [System.IO.File]::WriteAllText($snapFile, ($snapObj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  Write-Log ("快照落盘 " + $snapObj.count + " 条 -> " + $snapFile) "INFO"
}

$resolvedNames = @{}

foreach ($r in @($st.resolved)) { if ($r.u) { $resolvedNames[([string]$r.u).ToLower()] = 1 } }

$todo = @($st.links.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key } | Where-Object { -not $resolvedNames.ContainsKey([string]$_) } | Select-Object -First ([Math]::Max(0, $ResolveCap - $resolvedNames.Count)))



$ri = 0

while ($st.phase -eq "resolve" -and $ri -lt $todo.Count) {

  if (Stopped) { Write-Log "stop.flag，保存断点退出"; Save-State; exit 0 }

  if ((BudgetLeft) -lt 30) { Write-Log "时间预算不足，保存断点退出（resolve）"; Save-State; Ev "tg links budget pause"; exit 0 }

  $batch = @($todo[$ri..([Math]::Min($ri + $BatchResolve - 1, $todo.Count - 1))])

  $namesJson = ConvertTo-Json -InputObject $batch -Compress

  $js = $jsResolve.Replace("__NAMES__", $namesJson)

  $r = Invoke-TgJs $js ([Math]::Min(180, [Math]::Max(45, [int](BudgetLeft))))

  if (-not $r) { Write-Log "本批解析失败，保存断点退出"; Save-State; exit 5 }

  $st.resolved = @($st.resolved) + @($r.items)

  $ri += $batch.Count

  Save-State

  Write-Log ("解析批 " + $ri + "/" + $todo.Count + " 累计=" + @($st.resolved).Count)

  Ev ("tg resolve " + $ri + "/" + $todo.Count)

}



# ---------- 阶段四：过滤 + 写候选池 ----------

$known = @{}

$jsonPath = Join-Path $baseDir "data\tg_known.json"

if (Test-Path $jsonPath) {

  try {

    $arr = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($u in @($arr)) { $k = ([string]$u).TrimStart("@").ToLower(); if ($k) { $known[$k] = 1 } }

  } catch {}

}



# ---------- 阶段四：双门槛测量 + rejects 落盘 ----------
$runId = "run-" + (([string]$st.startedAt) -replace "[^0-9]", "")
if (-not $runId -or $runId.Length -lt 10) { $runId = "run-" + (Get-Date -Format "yyyyMMddHHmmss") }

$rxTopic = '(?i)(cs2|cs:go|csgo|counter[\s\-]?strike|cs\s?1\.6|cs1\.6)'
$rxBad = ''
$rejectsOn = $true
try {
  $cfgm = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($cfgm.strategy.Telegram.filters.exclude_regex) { $rxBad = [string]$cfgm.strategy.Telegram.filters.exclude_regex }
  if ($cfgm.rejects -and ($cfgm.rejects.enabled -eq $false)) { $rejectsOn = $false }
} catch { }
if ($NoRejects) { $rejectsOn = $false }

# 已有库存（本轮开始前的池 + 已知名单）
$poolKeys = @{}
$poolPath0 = Join-Path $baseDir "data\pool_telegram.json"
if (Test-Path $poolPath0) {
  try {
    foreach ($it in @((Get-Content $poolPath0 -Raw -Encoding UTF8 | ConvertFrom-Json).items)) {
      if ($it.u) { $poolKeys[([string]$it.u).ToLower()] = 1 }
      if ($it.id) { $poolKeys[[string]$it.id] = 1 }
    }
  } catch { }
}

$measureDir = Join-Path $baseDir "data\tg_measure"
if (-not (Test-Path $measureDir)) { New-Item -ItemType Directory -Path $measureDir -Force | Out-Null }

$cand300 = @(); $cand150 = @(); $diff = @(); $rejects = @()
$stCount = [ordered]@{ resolved = 0; miss = 0; dup = 0; topic_fail = 0; bad = 0; bc = 0; join_req = 0; n_lt_150 = 0; unknown_n = 0 }

foreach ($r in @($st.resolved)) {
  if ($r.miss) {
    $stCount.miss++
    if ($rejectsOn) {
      $uMiss = ([string]$r.u).ToLower()
      $rejects += [pscustomobject]@{
        run_id = $runId; u = $uMiss; id = ""; n = 0; t = ""; h = ""; k = ""
        bc = $false; jr = $false; topic_ok = $false; hits = [int]$st.links[$uMiss]
        err = [string]$r.err
        reasons = @("resolve_failed"); effective_min = $MinMembers; compare_min = $CompareMin
        at = (Get-Date).ToString("s")
      }
    }
    continue
  }
  $u = ([string]$r.u).ToLower()
  if (-not $u) { $stCount.miss++; continue }
  $stCount.resolved++

  $n = [int]$r.n
  $t0 = [string]$r.t
  $reasons = @()
  $dupKey = $known.ContainsKey($u) -or $poolKeys.ContainsKey($u) -or ($r.id -and $poolKeys.ContainsKey([string]$r.id))
  if ($dupKey) { $reasons += "dup"; $stCount.dup++ }
  $topicOk = ($t0 + " " + $u) -match $rxTopic
  if (-not $topicOk) { $reasons += "topic"; $stCount.topic_fail++ }
  if ($rxBad -and (($t0 + " " + $u) -match $rxBad)) { $reasons += "excluded"; $stCount.bad++ }
  if ($r.bc) { $reasons += "broadcast"; $stCount.bc++ }
  if ($r.jr) { $reasons += "join_request"; $stCount.join_req++ }
  if ($n -le 0) { $reasons += "n_unknown"; $stCount.unknown_n++ }
  elseif ($n -lt $CompareMin) { $reasons += "n_lt_compare"; $stCount.n_lt_150++ }

  $obj = [pscustomobject]@{
    run_id = $runId; u = $u; id = [string]$r.id; n = $n; t = $t0
    h = [string]$r.h; k = [string]$r.k; bc = [bool]$r.bc; jr = [bool]$r.jr
    topic_ok = [bool]$topicOk; hits = [int]$st.links[$u]
    reasons = @($reasons); effective_min = $MinMembers; compare_min = $CompareMin
    at = (Get-Date).ToString("s")
  }

  $baseOk = $topicOk -and (-not $dupKey) -and (-not $r.bc) -and (-not $r.jr) -and (-not ($rxBad -and (($t0 + " " + $u) -match $rxBad)))
  if ($baseOk -and $n -ge $MinMembers) {
    $cand300 += $obj; $cand150 += $obj
    if ($n -lt 300) { $diff += $obj }
  } elseif ($baseOk -and $n -ge $CompareMin -and $n -lt $MinMembers) {
    $diff += $obj          # 降门槛才会被放行
    $cand150 += $obj
  }
  if (-not $rejectsOn -and $reasons.Count -eq 0) { }

  if ($reasons.Count -gt 0 -or -not $baseOk) {
    if ($rejectsOn) { $rejects += $obj }
  }
}

# 差集再算一次（严格：150<=n<300 且其余条件全过）
$diff = @($cand150 | Where-Object { $_.n -ge 150 -and $_.n -lt 300 } | Sort-Object n -Descending)

$measure = [pscustomobject]@{
  run_id = $runId; profile_version = ""; min_members = $MinMembers; compare_min = $CompareMin
  resolved = $stCount.resolved; miss = $stCount.miss
  dup = $stCount.dup; topic_fail = $stCount.topic_fail; excluded = $stCount.bad
  broadcast = $stCount.bc; join_request = $stCount.join_req
  n_lt_compare = $stCount.n_lt_150; n_unknown = $stCount.unknown_n
  new_usable_300 = @($cand300).Count
  new_usable_150 = @($cand150).Count
  diff_count = @($diff).Count
  pool_before = $poolKeys.Count
  taken_at = (Get-Date).ToString("s")
}
try {
  $cfgm2 = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($cfgm2.profile -and $cfgm2.profile.version) { $measure.profile_version = [string]$cfgm2.profile.version }
} catch { }

$mPath = Join-Path $measureDir ($runId + ".json")
[System.IO.File]::WriteAllText($mPath, ($measure | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

if ($rejectsOn -and $rejects.Count -gt 0) {
  $rp = Join-Path $baseDir "data\tg_rejects.jsonl"
  $sb = New-Object System.Text.StringBuilder
  foreach ($x in $rejects) { [void]$sb.AppendLine(($x | ConvertTo-Json -Compress -Depth 5)) }
  [System.IO.File]::AppendAllText($rp, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  Write-Log ("rejects 落盘 " + $rejects.Count + " 条 → data\tg_rejects.jsonl")
}

Write-Log ("MEASURE " + $runId + " resolved=" + $measure.resolved + " miss=" + $measure.miss + " dup=" + $measure.dup + " topic_fail=" + $measure.topic_fail + " bc=" + $measure.broadcast + " n<150=" + $measure.n_lt_compare + " usable300=" + $measure.new_usable_300 + " usable150=" + $measure.new_usable_150 + " diff=" + $measure.diff_count)
Ev ("tg measure usable300=" + $measure.new_usable_300 + " usable150=" + $measure.new_usable_150 + " diff=" + $measure.diff_count)

$new = @($cand300 | ForEach-Object {
  [pscustomobject]@{ u = $_.u; n = $_.n; t = $_.t; h = $_.h; k = $_.k; id = $_.id; hits = $_.hits }
})
$new = @($new | Sort-Object n -Descending)

Write-Log ("过滤后新候选 " + $new.Count + "（解析总数 " + @($st.resolved).Count + "，已知 " + $known.Count + "，门槛 " + $MinMembers + "，对比档 " + $CompareMin + "）")



if ($DryRun) { $new | Format-Table -AutoSize | Out-String | Write-Host; exit 0 }



$path = Join-Path $baseDir "data\tg_links_candidates.json"

[System.IO.File]::WriteAllText($path, ($new | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))



$poolPath = Join-Path $baseDir "data\pool_telegram.json"

$items = @()

if (Test-Path $poolPath) { try { $items = @((Get-Content $poolPath -Raw -Encoding UTF8 | ConvertFrom-Json).items) } catch {} }

$exist = @{}

foreach ($i in $items) { if ($i.u) { $exist[([string]$i.u).ToLower()] = 1 } }

$now = (Get-Date).ToUniversalTime()

$exp = $now.AddDays(14).ToString("o")

$add = 0

foreach ($c in $new) {

  if ($exist.ContainsKey($c.u)) { continue }

  $items += [pscustomobject]@{ u = $c.u; n = $c.n; t = $c.t; h = $c.h; k = $c.k; src = "links"; addedAt = $now.ToString("o"); expiresAt = $exp }

  $exist[$c.u] = 1

  $add++

}

$obj = @{ savedAt = (Get-Date).ToString("s"); platform = "Telegram"; count = $items.Count; items = $items }

[System.IO.File]::WriteAllText($poolPath, ($obj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))



Remove-Item $statePath -Force -ErrorAction SilentlyContinue

Write-Log ("入池新增 " + $add + "，池深 " + $items.Count + "，总耗时 " + [int]((Get-Date) - $started).TotalSeconds + "s")

Ev ("tg links done: new=" + $new.Count + " pool=" + $items.Count)

"DONE new=$($new.Count) pool=$($items.Count) elapsed=$([int]((Get-Date) - $started).TotalSeconds)s"

