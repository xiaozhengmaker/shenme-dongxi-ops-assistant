# tg_discover_links.ps1 -- 从已加入的 TG 群里挖 t.me 链接 / @username，解析后写入候选池

# v2：双阶段分批 + 断点续跑（避免单次 JS 超过 CDP 超时）

param(

  [int]$MaxGroups = 120,

  [int]$PerGroup = 100,

  [int]$ResolveCap = 90,

  [int]$MinMembers = 150,

  [int]$BatchGroups = 15,

  [int]$BatchResolve = 20,

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
    if ($lp.Name -and $lp.Name -notin @("Keys", "Values", "Count")) { $linksHash[$lp.Name] = [int]$lp.Value }
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

    } catch (e) { out.items.push({ u: u, miss: 1 }); }

  }

  return JSON.stringify(out);

})()

'@



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



$new = @()

foreach ($r in @($st.resolved)) {

  if ($r.miss) { continue }

  $u = ([string]$r.u).ToLower()

  if (-not $u) { continue }

  if ($known.ContainsKey($u)) { continue }

  if ([int]$r.n -lt $MinMembers) { continue }

  if ($r.bc) { continue }

  $new += [pscustomobject]@{ u = $u; n = [int]$r.n; t = [string]$r.t; h = [string]$r.h; k = [string]$r.k; id = [string]$r.id; hits = [int]$st.links[$u] }

}

$new = @($new | Sort-Object n -Descending)

Write-Log ("过滤后新候选 " + $new.Count + "（解析总数 " + @($st.resolved).Count + "，已知 " + $known.Count + "，门槛 " + $MinMembers + "）")



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

