# hub.ps1 —— 本地调度中心：给 Chrome 扩展派任务、收结果、写飞书



# 启动： pwsh -File hub.ps1



# 监听： http://127.0.0.1:8787







param([int]$Port = 8787, [int]$QuotaOverride = 0, [string]$Platform = "Telegram")







$here = Split-Path -Parent $MyInvocation.MyCommand.Path



. (Join-Path $here "lib\feishu.ps1")

try {
  $bootLog = Join-Path $here "logs\hub.boot.log"
  Add-Content -Path $bootLog -Encoding UTF8 -Value ("here=" + $here + " | tokLen=" + ([string]$script:Fs.base_app_token).Length + " | tbl=" + ([string]$script:Fs.table_id))
} catch { }




. (Join-Path $here "lib\db.ps1")



. (Join-Path $here "lib\stop.ps1")



. (Join-Path $here "lib\profile.ps1")



. (Join-Path $here "lib\ai.ps1")
. (Join-Path $here "lib\naming.ps1")
. (Join-Path $here "lib\join_guard.ps1")
. (Join-Path $here "lib\platform_cooldown.ps1")
. (Join-Path $here "lib\pipeline_status.ps1")
. (Join-Path $here "lib\run_control.ps1")
. (Join-Path $here "lib\member_sample.ps1")
$script:PlatformCooldownPath = Join-Path $here "data\platform_cooldown.json"
$script:receiptNames = @{}







$cfgPath = Join-Path $here "config.json"



$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
# 单目标验证：可强制 Facebook join 目标白名单（精确 id 或用户名，逗号分隔）。
# 未设置时保持原行为；设置后总派发上限为 1，重复排队也不会超过。
$script:JoinWhitelist = @()
try {
  $rawWl = [string]$env:GOPS_FB_JOIN_WHITELIST
  if ($rawWl) {
    $script:JoinWhitelist = @($rawWl.Split(",") | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  }
} catch { }



if (-not $cfg.outputs) { $cfg | Add-Member -NotePropertyName outputs -NotePropertyValue ([pscustomobject]@{ feishu = $true; sqlite = $false; csv = $false; jsonl = $false }) -Force }



if (-not $cfg.schedule) { $cfg | Add-Member -NotePropertyName schedule -NotePropertyValue ([pscustomobject]@{ enabled = $true; time = "10:00" }) -Force }







$state = @{



  phase      = "idle"      # idle | probe | search | join | done



  running    = $false



  self       = ""



  queries    = New-Object System.Collections.Queue



  candidates = @{}



  queue      = New-Object System.Collections.Queue



  nextAt     = [DateTime]::MinValue



  seq        = 1



  fails      = 0



  joined     = 0



  existing   = 0



  local      = 0



  joinDispatched = 0



  skipped    = 0



  failed     = 0



  pending    = $null        # 已派出未回的任务



  started    = $null



  stale      = 0



  searches   = 0



  zeroStreak = 0



  dryStreak  = 0



  lastAlert  = ""



  lastAlertAt = $null



}







function Get-ActiveRunForControl {
  try {
    $p = Get-PipelineStatusView -BaseDir $here
    if ($p -and [string]$p.state -eq "running" -and $p.run_id) {
      return @{ source = "pipeline"; run_id = [string]$p.run_id; platform = [string]$p.current_platform }
    }
  } catch { }
  if ($state.running) { return @{ source = "hub"; run_id = ""; platform = [string]$Platform } }
  return @{ source = "none"; run_id = ""; platform = "" }
}

$minMembers = 300



$strat = $null



try { if ($cfg.strategy -and $cfg.strategy.$Platform) { $strat = $cfg.strategy.$Platform } } catch {}



if ($strat -and $strat.filters -and $strat.filters.min_members) { $minMembers = [int]$strat.filters.min_members }



elseif ($cfg.filters.min_members.$Platform) { $minMembers = [int]$cfg.filters.min_members.$Platform }



$quota = 20



if ($cfg.quotas.$Platform) { $quota = [int]$cfg.quotas.$Platform }



$srcLabel = if ($Platform -eq "Facebook") { "FB搜索" } else { "TG搜索" }



$grpType  = if ($Platform -eq "Facebook") { "公开群" } else { "聊天" }



$exclude = "(?i)(airdrop|pixelverse|xdao|earn|shop|магазин|news|bot)"



if ($strat -and $strat.filters -and $strat.filters.exclude_regex) { $exclude = [string]$strat.filters.exclude_regex }



elseif ($cfg.filters.exclude_title_regex) { $exclude = [string]$cfg.filters.exclude_title_regex }



$gapMin = 45; $gapMax = 180



if ($strat -and $strat.pacing) {



  if ($strat.pacing.interval_min) { $gapMin = [int]$strat.pacing.interval_min }



  if ($strat.pacing.interval_max) { $gapMax = [int]$strat.pacing.interval_max }



}



$alertCfg = $null



try { $alertCfg = $cfg.alerts } catch {}



if ($cfg.pacing.join_gap_sec) { $gapMin = [int]$cfg.pacing.join_gap_sec[0]; $gapMax = [int]$cfg.pacing.join_gap_sec[1] }



$maxFails = 3



if ($cfg.pacing.max_consecutive_failures) { $maxFails = [int]$cfg.pacing.max_consecutive_failures }







# 已收录：按 群ID / @用户名 / 群名 三键去重



$seen = @{}



$seenTitles = @{}



$todayJoined = 0



$today = Get-Date



$dayStart = [DateTimeOffset]::new($today.Year, $today.Month, $today.Day, 0, 0, 0, [TimeSpan]::FromHours(8)).ToUnixTimeMilliseconds()



try {



  foreach ($r in Get-FsRecords) {



    $gid = $r.fields.'群ID'; if ($gid) { $seen[[string]$gid] = $true }



    $nm = $r.fields.'群名'; if ($nm) { $seenTitles[(([string]$nm).Trim()).ToLower()] = $true }



    $lnk = $r.fields.'群链接'



    if ($lnk) { $u = ([string]$lnk) -replace '^.*t\.me/', ''; if ($u) { $seen[$u.ToLower()] = $true } }



    $j = $r.fields.'加入日期'



    $pl = [string]$r.fields.'平台'



    if ($j -and [double]$j -ge $dayStart -and $pl -eq $Platform) { $todayJoined++ }



  }



} catch { Write-Warning ("读取飞书失败：" + $_.Exception.Message) }







$need = $quota - $todayJoined



if ($need -lt 0) { $need = 0 }



if ($QuotaOverride -gt 0) { $need = $QuotaOverride }







function Get-ResumeLive {
  $ri = @{ mode = "production"; enabled = $true; budget = 0; targets = 0; sent = 0; sent_total = 0; done = 0;
           terminated = 0; pending = 0; retry_due = 0; send_unknown = 0;
           reconcile_ok = $false; last_run = ""; last_at = ""; last_report = "" }
  try {
    $rc = Get-Content (Join-Path $here "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $rc.resume.enabled) { $ri.enabled = [bool]$rc.resume.enabled }
    if ($rc.resume.budget) { $ri.budget = [int]$rc.resume.budget }
    $rp = Join-Path $here "data\tg_recovery_state.json"
    if (Test-Path $rp) {
      $rs = Get-Content $rp -Raw -Encoding UTF8 | ConvertFrom-Json
      $ri.targets = @($rs.targets).Count
      $ri.sent = [int]$rs.sent
      $ri.sent_total = [int]$rs.sent_total
      $ri.done = @($rs.targets | Where-Object { $_.status -eq "done" }).Count
      $ri.terminated = @($rs.targets | Where-Object { $_.status -eq "terminated" }).Count
      $ri.pending = @($rs.targets | Where-Object { $_.status -eq "pending" }).Count
      $ri.retry_due = @($rs.targets | Where-Object { $_.status -eq "retry_due" }).Count
      $ri.send_unknown = @($rs.targets | Where-Object { $_.status -eq "send_unknown" }).Count
      $ri.reconcile_ok = (($ri.done + $ri.terminated + $ri.pending + $ri.retry_due + $ri.send_unknown) -eq $ri.targets)
      $ri.last_run = [string]$rs.resume_run
      $ri.last_at = [string]$rs.at
    }
    $lr = Get-ChildItem (Join-Path $here "data") -Filter "tg_recovery_2*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lr) { $ri.last_report = $lr.Name }
  } catch { }
  return $ri
}

function Now-Unix { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }



function Rand-Int($a, $b) { Get-Random -Minimum $a -Maximum ($b + 1) }



function Next-TaskId { $script:state.seq++; return $script:state.seq }







function Write-LocalArchive {



  param($Fields)



  $ok = $false



  $dir = Join-Path $here "data"



  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }



  $obj = [ordered]@{}



  foreach ($k in $Fields.Keys) { $obj[$k] = $Fields[$k] }



  if ($cfg.outputs.csv) {



    $csv = Join-Path $dir "groups.csv"



    if (Test-Path $csv) { [pscustomobject]$obj | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8 }



    else { [pscustomobject]$obj | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 }



    $ok = $true



  }



  if ($cfg.outputs.jsonl) {



    $jl = Join-Path $dir "groups.jsonl"



    $line = [ordered]@{ ts = (Get-Date).ToString("s"); f = $obj } | ConvertTo-Json -Compress -Depth 6



    Add-Content -Path $jl -Value $line -Encoding UTF8



    $ok = $true



  }



  return $ok



}



function Get-SkipSet([string]$plat) {



  $set = @{}



  try {



    $f = Join-Path $PSScriptRoot "data\skip.json"



    if (Test-Path $f) {



      $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json



      $blk = $j.$plat



      if ($blk) {



        foreach ($p in $blk.PSObject.Properties) {



          $reason = [string]$p.Value.reason



          if ($reason -in @("members_hidden", "needs_approval", "dead")) { $set[$p.Name.ToLower()] = $reason }



        }



      }



    }



  } catch { }



  return $set



}







function Add-SkipEntry([string]$plat, [string]$key, [string]$reason, [string]$title) {



  try {



    $f = Join-Path $PSScriptRoot "data\skip.json"



    $j = @{ note = "auto-maintained"; updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }



    if (Test-Path $f) { $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }



    if (-not $j.ContainsKey($plat)) { $j[$plat] = @{} }



    $j[$plat][$key] = @{ title = $title; reason = $reason; sampled = 0; at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }



    [System.IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))



  } catch { }



}







function Get-Keywords([string]$plat) {



  $out = New-Object System.Collections.ArrayList



  $seen = @{}



  $strat = $null



  try { $strat = $cfg.strategy.$plat } catch { }



  $usePool = $true



  if ($strat -and $strat.discovery -and ($null -ne $strat.discovery.usePool)) { $usePool = [bool]$strat.discovery.usePool }



  if ($usePool -and $cfg.keywordPool) {



    foreach ($k in @($cfg.keywordPool)) { $kk = ([string]$k).Trim(); if ($kk -and -not $seen.ContainsKey($kk.ToLower())) { $seen[$kk.ToLower()] = 1; [void]$out.Add($kk) } }



  }



  $own = @()



  if ($strat -and $strat.discovery -and $strat.discovery.keywords) { $own = @($strat.discovery.keywords) }



  else { $own = @($cfg.queries.$plat) }



  foreach ($k in $own) { $kk = ([string]$k).Trim(); if ($kk -and -not $seen.ContainsKey($kk.ToLower())) { $seen[$kk.ToLower()] = 1; [void]$out.Add($kk) } }



  return $out



}







function Get-PlatformFromText([string]$m) {



  if ($m -match "(?i)steam") { return "Steam" }



  if ($m -match "(?i)telegram|\btg\b") { return "Telegram" }



  if ($m -match "(?i)facebook|\bfb\b") { return "Facebook" }



  if ($m -match "(?i)reddit") { return "Reddit" }



  if ($m -match "(?i)discord|\bdc\b") { return "Discord" }



  if ($m -match "(?i)whatsapp|\bwa\b") { return "WhatsApp" }



  if ($m -match "(?i)instagram|\big\b") { return "Instagram" }



  return ""



}







function Add-Event([string]$m) {



  try {



    if (-not $state.events) { $state.events = New-Object System.Collections.ArrayList }



    [void]$state.events.Add(@{ t = (Get-Date).ToString("HH:mm:ss"); m = $m; p = (Get-PlatformFromText $m) })



    while ($state.events.Count -gt 40) { $state.events.RemoveAt(0) }



    $pk = Get-PlatformFromText $m



    if ($pk) { $state.activePlatform = $pk; $state.activeAt = Get-Date }



  } catch { }



}











function Get-PoolPath($pf) { Join-Path $PSScriptRoot ("data\pool_" + ([string]$pf).ToLower() + ".json") }







function Get-PoolWatermark([string]$pf) {



  switch ([string]$pf) {



    "Telegram" { return 60 }



    "Facebook" { return 30 }



    "Steam"    { return 20 }



    default    { return 10 }



  }



}







function Get-PoolTtlDays { $d = 14; try { if ($cfg.pool -and $cfg.pool.ttl_days) { $d = [int]$cfg.pool.ttl_days } } catch { }; return $d }







function ConvertTo-PoolKey($it) {



  $u = ([string]$it.u).TrimStart("@").ToLower()



  if ($u) { return "u:" + $u }



  if ([string]$it.id) { return "id:" + ([string]$it.id) }



  if ([string]$it.h) { return "h:" + ([string]$it.h) }



  return ""



}







function Read-PoolRaw([string]$pf) {



  $path = Get-PoolPath $pf



  if (-not (Test-Path $path)) { return @{ savedAt = ""; items = @() } }



  try {



    $o = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json



    return @{ savedAt = [string]$o.savedAt; items = @($o.items) }



  } catch { return @{ savedAt = ""; items = @() } }



}







function Get-PoolItems([string]$pf) {



  $raw = Read-PoolRaw $pf



  $now = (Get-Date).ToUniversalTime()



  $ttl = Get-PoolTtlDays



  $out = @{}



  foreach ($it in @($raw.items)) {



    if (-not $it) { continue }



    $k = ConvertTo-PoolKey $it



    if (-not $k) { continue }



    $exp = [string]$it.expiresAt



    if ($exp) {



      try { if ([DateTime]::Parse($exp).ToUniversalTime() -lt $now) { continue } } catch { }



    } else {



      $added = [string]$it.addedAt



      $base = if ($added) { try { [DateTime]::Parse($added).ToUniversalTime() } catch { $now } } else { $now }



      if (($now - $base).TotalDays -gt $ttl) { continue }



    }



    if (-not $out.ContainsKey($k)) { $out[$k] = $it }



  }



  return @($out.Values)



}







function Save-PoolItems([string]$pf, $items, [int]$cap = 600) {



  try {



    $dir = Join-Path $PSScriptRoot "data"



    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }



    $arr = @($items)



    if ($arr.Count -gt $cap) {



      $arr = @($arr | Sort-Object { -(try { [int]$_.n } catch { 0 }) } | Select-Object -First $cap)



    }



    $obj = @{ savedAt = (Get-Date).ToString("s"); platform = [string]$pf; count = $arr.Count; items = $arr }



    [System.IO.File]::WriteAllText((Get-PoolPath $pf), ($obj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))



    return $arr.Count



  } catch { return 0 }



}







function Merge-IntoPool([string]$pf, $newItems, [string]$source) {



  $ttl = Get-PoolTtlDays



  $now = (Get-Date).ToUniversalTime()



  $exp = $now.AddDays($ttl).ToString("o")



  $merged = @{}



  foreach ($it in @(Get-PoolItems $pf)) { $merged[(ConvertTo-PoolKey $it)] = $it }



  $added = 0



  foreach ($it in @($newItems)) {



    if (-not $it) { continue }



    $k = ConvertTo-PoolKey $it



    if (-not $k) { continue }



    if ($merged.ContainsKey($k)) { continue }



    $copy = @{}



    foreach ($p in $it.PSObject.Properties) { $copy[$p.Name] = $p.Value }



    $copy["addedAt"] = $now.ToString("o")



    $copy["expiresAt"] = $exp



    if (-not $copy.ContainsKey("src") -or -not $copy["src"]) { $copy["src"] = $source }



    $merged[$k] = $copy



    $added++



  }



  $n = Save-PoolItems $pf @($merged.Values)



  return @{ added = $added; depth = $n }



}







function Test-PoolItemEligible($item, [string]$pf) {



  # 单一判定口径：TTL 已由 Get-PoolItems 处理；这里再排除跳过名单与业务相关度



  if (-not $item) { return $false }



  $tt = [string]$item.t; if (-not $tt) { $tt = [string]$item.title }



  if ($pf -eq "Telegram") {



    $rxRel = '(?i)(cs2|cs:go|csgo|counter[\s\-]?strike)'



    $rxDrop = '(?i)(hotkey|keybind|keyboard|sensitiv|trainer|coach|custom map|cheat|hack|ban|vac|airdrop|news|sport|football|movie|music|standoff|para1el|ranking|giveaway|rental|casino|poker|новост|анонс|дайджест|подборка)'



    if ($tt) {



      if ($tt -notmatch $rxRel) { return $false }



      if ($tt -match $rxDrop) { return $false }



    }



  }



  $u = ([string]$item.u).Trim().TrimStart("@").ToLower()



  if ($u -and $state.skipSet -and $state.skipSet.ContainsKey("@" + $u)) { return $false }



  return $true



}







function Get-PoolDepth([string]$pf) {



  # 口径：只数「能用」的候选（未过期 + 过相关度闸门 + 不在跳过名单）



  return @(@(Get-PoolItems $pf) | Where-Object { Test-PoolItemEligible $_ $pf }).Count



}







function Get-PoolRawDepth([string]$pf) { return @(Get-PoolItems $pf).Count }







function Load-CandidatePool($pf, $maxAgeHours) {



  # 兼容旧调用：忽略全局 maxAgeHours，统一用逐项 TTL



  return @(Get-PoolItems $pf)



}







function Start-Run {



  $state.phase = "probe"



  $state.running = $true



  $state.self = ""



  $state.candidates = @{}



  $state.ledgerLast = $null



  $state.queue = New-Object System.Collections.Queue



  $state.queries = New-Object System.Collections.Queue



  $state.fails = 0



  $state.relaxed = $false



  $state.minNow = $minMembers



$state.extHits = 0



$state.extAt = ""



  $state.joined = 0; $state.existing = 0; $state.local = 0; $state.skipped = 0; $state.failed = 0



  $state.nextAt = [DateTime]::MinValue



  $state.pending = $null



  $state.started = Get-Date



  $state.events = New-Object System.Collections.ArrayList



  $state.skipSet = Get-SkipSet $Platform



  $state.platKey = if ($Platform -eq "Facebook") { "FB" } else { "TG" }



  $poolAdded = 0



  foreach ($it in @(Load-CandidatePool $Platform 72)) {



    if (-not $it.u) { continue }



    $uk = ("@" + ([string]$it.u).TrimStart("@")).ToLower()



    if ($state.skipSet.ContainsKey($uk)) { continue }



    if ($state.candidates.ContainsKey($uk)) { continue }



    $ttl2 = [string]$it.title



    if (-not $ttl2) { $ttl2 = [string]$it.t }



    $state.candidates[$uk] = @{ id = $uk; u = [string]$it.u; title = $ttl2; n = [int]$it.n; q = [string]$it.q; src = "pool"; h = [string]$it.h; k = [string]$it.k }



    $poolAdded++



  }



  if ($poolAdded -gt 0) { Add-Event ("候选池载入 " + $poolAdded + " 个") }



  $state.current = "准备开始"



  Add-Event ("开始运行 · " + $Platform + " · 目标 " + $need + " 个")







  $qs = @()



  $qset = $cfg.queries.$Platform



  if ($qset) { $qs = @($qset) }



  foreach ($q in $qs) { $state.queries.Enqueue($q) }



  "[hub] start: 需加入 $need 个，关键词 $($qs.Count) 组"



}







function Build-JoinQueue {



  # 优先用持久化池（存量轮转），池空时退回本次搜索结果



  $pooled = @(Get-PoolItems $Platform)



  $list = @()



  if ($pooled.Count -gt 0) {



    $list = $pooled



    Write-Host ("[hub] 队列来源=候选池 存量 " + $pooled.Count + "（可用 " + (Get-PoolDepth $Platform) + "）")



  } else {



    foreach ($k in $state.candidates.Keys) { $list += $state.candidates[$k] }



    Write-Host ("[hub] 队列来源=本轮搜索 候选 " + @($list).Count)



  }



  $list = $list | Sort-Object { -[int]$_.n }



  if (@($list).Count -gt 0) {



    $b0 = @($list).Count



    $list = @($list | Where-Object { Test-PoolItemEligible $_ $Platform })



    if ($b0 -ne @($list).Count) {



      Write-Host ("[hub] 池内过滤 " + $b0 + " -> " + @($list).Count + "（过期/相关度/跳过名单）")



      Add-Event ("池内过滤 " + $b0 + " -> " + @($list).Count)



    }



  }



  # 二重保险：候选池/搜索结果里若含跳过名单内的群，这里再剔一次



  $list = @($list | Where-Object {



    $uk2 = ("@" + ([string]$_.u).TrimStart("@")).ToLower()



    -not ($_.u -and $state.skipSet -and $state.skipSet.ContainsKey($uk2))



  })



  # 既无 username 又无 access_hash 的候选无法可靠加入（老候选池 schema），直接剔除



  # 注意：Facebook 的加入靠 numeric id + 标题匹配，本来就没有 username/access_hash，不能套用这条



  if ($Platform -eq "Telegram") {



    $before = $list.Count



    $list = @($list | Where-Object { ([string]$_.u).Trim() -ne "" -or ([string]$_.h).Trim() -ne "" })



    if ($before -ne $list.Count) { Write-Host ("[hub] 剔除无法加入的候选 " + ($before - $list.Count) + " 个（无 u/h）") }



  } elseif ($Platform -eq "Facebook") {



    $before = $list.Count



    $list = @($list | Where-Object { ([string]$_.id).Trim() -ne "" -or ([string]$_.title).Trim() -ne "" })



    if ($before -ne $list.Count) { Write-Host ("[hub] 剔除无 id/title 的 FB 候选 " + ($before - $list.Count) + " 个") }



  }



  # 统一字段：池里的候选用 t/n/h/k，搜索结果用 title/u/h/k，这里归一化，避免 dispatch 时 title 为空



  $list = @($list | ForEach-Object {



    $ttl3 = [string]$_.title; if (-not $ttl3) { $ttl3 = [string]$_.t }



    @{



      id = [string]$_.id; u = [string]$_.u; title = $ttl3; n = [int]$_.n;



      q = [string]$_.q; h = [string]$_.h; k = [string]$_.k; src = [string]$_.src



    }



  })



  $take = [Math]::Min($need, $list.Count)



  $i = 0



  foreach ($c in $list) {



    if ($i -ge $take) { break }



    $state.queue.Enqueue($c)



    $i++



  }



  $state.phase = "join"



  "[hub] 搜索完成，候选 $($list.Count)，本轮计划加入 $($state.queue.Count)"



}







function Remove-FromPool([string]$pf, $target) {



  try {



    $k = ConvertTo-PoolKey $target



    if (-not $k) { return }



    $items = @(Get-PoolItems $pf)



    $kept = @($items | Where-Object { (ConvertTo-PoolKey $_) -ne $k })



    if ($kept.Count -ne $items.Count) { Save-PoolItems $pf $kept | Out-Null }



  } catch { }



}







function Reset-FsCacheSafe { try { Reset-FsCache } catch { } }







function Write-JoinRecord($target, $result) {



  $now = Now-Unix



  $due = $dayStart + 3 * 86400000



  $f = @{}



  $key = Get-GroupRecordKey -Platform $Platform -Target $target



  $f.Add("群组唯一键", $key)



  $f.Add("平台", $Platform)



  $f.Add("群ID", [string]$target.id)



  $f.Add("群名", [string]$target.title)



  if ($Platform -eq "Facebook") { $f.Add("群链接", "https://www.facebook.com/groups/" + $target.id) }



  elseif ($target.u) { $f.Add("群链接", "https://t.me/" + $target.u) }



  $f.Add("成员数", [int]$target.n)



  $f.Add("群类型", $(if ($Platform -eq "Facebook" -and $target.priv) { "非公开群" } else { $grpType }))



  if ($result -eq "request_sent") {



    $f.Add("状态", "需验证-不申请")



  } else {



    $f.Add("状态", "已加入")



    $f.Add("加入日期", $now)



    $f.Add("潜水到期", $due)



  }



  $f.Add("采集来源", $srcLabel)



  $f.Add("采集日", $now)



  $f.Add("是否收费发帖", "否")



  $cloudState = "disabled"



  if ($cfg.outputs.feishu -ne $false) {



    try {



      $fkey = ""



      $kv = $f["群组唯一键"]



      if ($kv -is [string]) { $fkey = $kv } elseif ($kv -and $kv.text) { $fkey = [string]$kv.text }



      if (-not $script:FsKeyMap) {



        $script:FsKeyMap = @{}



        foreach ($r in (Get-FsRecords)) {



          $rv = $r.fields."群组唯一键"; $rk = ""



          if ($rv -is [string]) { $rk = $rv } elseif ($rv -and $rv.text) { $rk = [string]$rv.text }



          if ($rk) { $script:FsKeyMap[$rk] = $r.record_id }



        }



      }



      if ($fkey -and $script:FsKeyMap.ContainsKey($fkey) -and $script:FsKeyMap[$fkey] -ne "pending") {



        $upd = Update-FsRecords -Updates @(@{ record_id = $script:FsKeyMap[$fkey]; fields = $f })
        $cloudState = $(if ([int]$upd -gt 0) { "existing" } else { "failed" })



      } else {



        $added = Add-FsRecordOnce -Fields $f -Cache $script:FsKeyMap
        $cloudState = $(if ($added) { "added" } else { "failed" })



        # 缓存由 Add-FsRecordOnce 维护（真实 record_id 或 pending）



      }







    }



    catch { $cloudState = "failed"; Write-Warning ("写飞书失败：" + $_.Exception.Message) }



  }



  $wLocal = $false



  try { $wLocal = Write-LocalArchive -Fields $f } catch { Write-Warning ("写本地失败：" + $_.Exception.Message) }



  $status = Get-JoinRecordStatus -CloudState $cloudState -LocalOk ([bool]$wLocal)
  return [pscustomobject]@{ status = $status; cloud = $cloudState; local = [bool]$wLocal }



}







$listener = New-Object System.Net.HttpListener



$listener.Prefixes.Add("http://127.0.0.1:$Port/")



$listener.Start()



$script:UsersCache = $null



$script:UsersStamp = [datetime]::MinValue







function Get-UsersCache {



  $csvPath = Join-Path $PSScriptRoot "data\users.csv"



  if (-not (Test-Path $csvPath)) { return @() }



  $stamp = (Get-Item $csvPath).LastWriteTime



  if ($script:UsersCache -and $stamp -eq $script:UsersStamp) { return $script:UsersCache }



  $rows = @(Import-Csv $csvPath -Encoding UTF8)



  $script:UsersCache = $rows



  $script:UsersStamp = $stamp



  return $rows



}







function Get-ProfileUrl([string]$plat, [string]$uid, [string]$uname) {



  $u = ([string]$uid).Trim()



  $n = ([string]$uname).Trim()



  switch ($plat) {



    "Steam"     { if ($u -match '^\d{17}$') { return "https://steamcommunity.com/profiles/$u" } }



    "Reddit"    { if ($n) { return "https://www.reddit.com/user/$n" } }



    "Telegram"  { if ($n) { return "https://t.me/$n" } }



    "Facebook"  { if ($u -match '^\d+$') { return "https://www.facebook.com/profile.php?id=$u" } }



    "Discord"   { if ($u -match '^\d+$') { return "https://discord.com/users/$u" } }



    "WhatsApp"  { $d = ($u -replace '\D', ''); if ($d) { return "https://wa.me/$d" } }



    "Instagram" { if ($n) { return "https://www.instagram.com/$n" } }



  }



  return ""



}







function Get-UsersPayload([hashtable]$q) {



  $all = Get-UsersCache



  $filtered = $all



  if ($q.platform) { $filtered = @($filtered | Where-Object { $_.'平台' -eq $q.platform }) }



  if ($q.role) { $filtered = @($filtered | Where-Object { $_.'角色' -eq $q.role }) }



  if ($q.group) {



    $g = [string]$q.group



    $filtered = @($filtered | Where-Object { $_.'群ID' -eq $g -or $_.'群名' -eq $g })



  }



  if ($q.uname) { $filtered = @($filtered | Where-Object { $_.'用户名' -and $_.'用户名' -ne "" }) }



  if ($q.q) {



    $kw = ([string]$q.q).ToLower()



    $filtered = @($filtered | Where-Object {



      (([string]$_.'昵称').ToLower().Contains($kw)) -or (([string]$_.'用户名').ToLower().Contains($kw)) -or (([string]$_.'群名').ToLower().Contains($kw))



    })



  }



  $total = $filtered.Count



  $size = 50



  if ($q.size) { try { $size = [Math]::Min(200, [Math]::Max(10, [int]$q.size)) } catch {} }



  $page = 1



  if ($q.page) { try { $page = [Math]::Max(1, [int]$q.page) } catch {} }



  $skip = ($page - 1) * $size



  $items = @()



  if ($skip -lt $total) {



    $slice = @($filtered | Select-Object -Skip $skip -First $size)



    $items = @($slice | ForEach-Object {



      $o = $_



      $pu = Get-ProfileUrl ([string]$o.'平台') ([string]$o.'用户ID') ([string]$o.'用户名')



      # 「语言」字段 99% 为空，按用户决定不在接口里返回（隐藏该列）



    $o = $o | Select-Object -Property * -ExcludeProperty "语言"



    $o | Add-Member -NotePropertyName "profile_url" -NotePropertyValue $pu -Force



      $o



    })



  }







  $byPlatform = @{}



  foreach ($r in $all) {



    $k = [string]$r.'平台'



    if (-not $byPlatform.ContainsKey($k)) { $byPlatform[$k] = @{ groups = @{}; count = 0 } }



    $byPlatform[$k].count++



    $byPlatform[$k].groups[[string]$r.'群ID'] = 1



  }



  $platStats = @()



  foreach ($k in $byPlatform.Keys) { $platStats += @{ name = $k; users = $byPlatform[$k].count; groups = $byPlatform[$k].groups.Count } }








  return @{



    total = $total



    page = $page



    size = $size



    items = $items



    stats = @{



      users = $all.Count



      withUsername = @($all | Where-Object { $_.'用户名' -and $_.'用户名' -ne "" }).Count



      mods = @($all | Where-Object { $_.'角色' -match '管理员|版主' }).Count



      groups = @($all | Select-Object -ExpandProperty '群ID' -Unique).Count



      platforms = $platStats



    }



  }



}



Write-Host ("[hub] listening on http://127.0.0.1:$Port  (需加入 $need 个)")







$cors = @{



  "Access-Control-Allow-Origin"  = "*"



  "Access-Control-Allow-Headers" = "content-type"



  "Access-Control-Allow-Methods" = "GET,POST,OPTIONS"



}







function Send-Alert([string]$pl, [string]$kind, [string]$msg) {



  $line = (Get-Date).ToString("HH:mm:ss") + " [" + $kind + "] " + $pl + " " + $msg



  try {



    $logDir = Join-Path $PSScriptRoot "logs"



    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }



    Add-Content -Path (Join-Path $logDir "alerts.log") -Value $line -Encoding UTF8



  } catch { }



  $script:state.lastAlert = $line



  $hook = ""



  try {



    $nch = $cfg.notify.channels



    if ($nch) {



      if ($nch.ops -and $nch.ops.enabled -and $nch.ops.webhook) { $hook = [string]$nch.ops.webhook }



      elseif ($nch.main -and $nch.main.enabled -and $nch.main.webhook) { $hook = [string]$nch.main.webhook }



    }



  } catch { }



  if (-not $hook) { try { $hook = [string]$cfg.alerts.webhook } catch { } }



  if (-not $hook) { try { $hook = [string]$cfg.feishu.webhook } catch { } }



  try { $pm = $cfg.notify.platforms; if ($pm -and $pl -and $pm.$pl -and -not [bool]$pm.$pl.alerts) { $hook = "" } } catch { }



  $sent = $false



  if ($hook) {



    try {



      $payload = @{ msg_type = "text"; content = @{ text = ("【社么东西】" + $pl + " 告警`n" + $msg) } } | ConvertTo-Json -Depth 6



      Invoke-RestMethod -Uri $hook -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null



      $sent = $true



    } catch { }



  }



  return $sent



}







function Send-Json($ctx, $code, $obj) {



  $ctx.Response.StatusCode = $code



  foreach ($k in $cors.Keys) { $ctx.Response.Headers[$k] = $cors[$k] }



  if ($null -eq $obj) {



    $ctx.Response.ContentLength64 = 0



    $ctx.Response.Close(); return



  }



  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))



  $ctx.Response.ContentType = "application/json; charset=utf-8"



  $ctx.Response.ContentLength64 = $bytes.Length



  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)



  $ctx.Response.Close()



}







function Sync-ScheduleTask {



  $tn = "DSH_SocialOps_Daily"



  if (-not $cfg.schedule -or -not $cfg.schedule.enabled) {



    & schtasks /Delete /TN $tn /F 2>&1 | Out-Null



    return @{ registered = $false; time = "" }



  }



  $time = [string]$cfg.schedule.time



  if ([string]::IsNullOrWhiteSpace($time)) { $time = "10:00" }



  $script = Join-Path $here "run_daily.ps1"



  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'



  & schtasks /Create /TN $tn /TR $tr /SC DAILY /ST $time /F /RL LIMITED 2>&1 | Out-Null



  return @{ registered = ($LASTEXITCODE -eq 0); time = $time }



}



$script:FsCache = $null



$script:FsCacheAt = [datetime]::MinValue



function Get-FsCached([int]$ttlSec = 60) {



  $now = Get-Date



  if ($script:FsCache -and (($now - $script:FsCacheAt).TotalSeconds -lt $ttlSec)) { return $script:FsCache }



  $script:FsCache = @(Get-FsRecords)



  $script:FsCacheAt = $now



  return $script:FsCache



}



function Reset-FsCache { $script:FsCache = $null; $script:FsCacheAt = [datetime]::MinValue }







function Get-Summary {



  $recs = @(Get-FsCached 60)



  $today = (Get-Date).ToString("yyyy/MM/dd")



  $plats = @{}



  $series = @{}



  for ($i = 6; $i -ge 0; $i--) {



    $d = (Get-Date).AddDays(-$i).ToString("yyyy/MM/dd")



    $series[$d] = @{ d = $d; groups = 0; members = 0 }



  }



  $todo = New-Object System.Collections.ArrayList



  $todoSeen = @{}



  $recent = New-Object System.Collections.ArrayList



  $tg = 0; $tm = 0; $td = 0; $tdm = 0



  foreach ($r in $recs) {



    $f = $r.fields



    if (-not $f) { continue }



    $pl = [string]$f.'平台'



    if (-not $pl) { $pl = "未知" }



    $stRow = [string]$f.'状态'



    if ($stRow -eq "已退出" -or $stRow -eq "已失效") { continue }



    $m = 0



    $ms = [string]$f.'成员数'



    if ($ms) { $m = [int](($ms -replace '[^\d]', '')) }



    if (-not $plats.ContainsKey($pl)) { $plats[$pl] = @{ name = $pl; groups = 0; members = 0; todayGroups = 0; todayMembers = 0 } }



    $plats[$pl].groups = $plats[$pl].groups + 1



    $plats[$pl].members = $plats[$pl].members + $m



    $tg = $tg + 1; $tm = $tm + $m



    $raw = $f.'加入日期'



    $jd = ""



    $key = $null



    if ($raw -is [int64] -or $raw -is [int32] -or $raw -is [double]) {



      $jd = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$raw).ToLocalTime().ToString("yyyy/MM/dd")



      $key = $jd



    } elseif ($null -ne $raw) {



      $jd = [string]$raw



      if ($jd -match '(\d{4})[-/](\d{2})[-/](\d{2})') { $key = $Matches[1] + "/" + $Matches[2] + "/" + $Matches[3] }



    }



    if ($null -ne $key) {



      if ($series.ContainsKey($key)) { $series[$key].groups = $series[$key].groups + 1; $series[$key].members = $series[$key].members + $m }



      if ($key -eq $today) { $plats[$pl].todayGroups = $plats[$pl].todayGroups + 1; $plats[$pl].todayMembers = $plats[$pl].todayMembers + $m; $td = $td + 1; $tdm = $tdm + $m }



    }



    $st = [string]$f.'状态'



    if ($st -and $st -ne "已加入") {



  $tn = [string]$f.'群名'



  if (-not $todoSeen.ContainsKey($tn)) { $todoSeen[$tn] = 1; [void]$todo.Add(@{ name = $tn; status = $st; platform = $pl }) }



}



    [void]$recent.Add(@{ name = [string]$f.'群名'; members = $m; platform = $pl; joined = $jd; lang = [string]$f.'语言' })



  }



  $arr = New-Object System.Collections.ArrayList



  foreach ($k in $series.Keys) { [void]$arr.Add($series[$k]) }



  $sorted = @($arr | Sort-Object { $_.d })



  $pf = New-Object System.Collections.ArrayList



  foreach ($k in $plats.Keys) { [void]$pf.Add($plats[$k]) }



  $rev = @($recent.ToArray())




  [array]::Reverse($rev)



  # --- local todos ---
  $localTodos = @()
  try {
    $tlPath = Join-Path $here "data/todos_local.json"
    if (Test-Path $tlPath) {
      $tl = Get-Content $tlPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($x in @($tl)) {
        if (-not $x) { continue }
        $nm2 = [string]$x.title
        if (-not $nm2) { continue }
        $localTodos += @{ name = $nm2; status = [string]$x.status; platform = [string]$x.platform; due_at = [string]$x.due_at; check_at = [string]$x.check_at; note = [string]$x.note }
      }
    }
  } catch { }

  $tg = 0; $tm = [int64]0; $td = 0; $tdm = [int64]0
  foreach ($pt in @($pf)) {
    $tg += [int]$pt.groups; $tm += [int64]$pt.members
    $td += [int]$pt.todayGroups; $tdm += [int64]$pt.todayMembers
  }
  return @{



    totals   = @{ groups = $tg; members = $tm; todayGroups = $td; todayMembers = $tdm }



    platforms = @($pf | Sort-Object -Property members -Descending)



    series   = $sorted




    todos    = @(@($localTodos) + @($todo) | Select-Object -First 8)



    todoCount = @($localTodos).Count + @($todo).Count



    recent   = @($rev | Select-Object -First 60)



    running  = $state.running



    phase    = $state.phase



  }



}



# ---------- 任务配置（tasks.json） ----------



$tasksPath = Join-Path $PSScriptRoot "tasks.json"







function Get-TaskDefaults {



  $d = @{}



  foreach ($pl in @("Facebook","Telegram","Discord","Reddit")) {



    $q = 5



    try { if ($cfg.quotas.$pl) { $q = [int]$cfg.quotas.$pl } } catch {}



    $kw = @()



    try { $kw = @($cfg.queries.$pl) } catch {}



    $mm = 1000



    try { if ($cfg.filters.min_members.$pl) { $mm = [int]$cfg.filters.min_members.$pl } } catch {}



    $tw = @()



    try { $tw = @($cfg.trend_words.$pl | Where-Object { $_ }) } catch {}



    $d[$pl] = @{



      discovery = @{ enabled = ($q -gt 0); quota = $q; min_members = $mm; keywords = $kw; interval = "45-180s"; last_run = ""; last_result = "" }



      audit     = @{ enabled = $false; every_days = 3; last_run = ""; last_result = "" }



      chat      = @{ enabled = $false; window_days = 7; max_messages = 5000; min_len = 15;



                     drop_bots = $true; drop_ads = $true; drop_short = $true; dedupe = $true;



                     clusters = 10; top_clusters = 3; per_cluster = 20;



                     cap_once = 2; cap_month = 50; used_month = 0;



                     last_run = ""; last_result = "" }



      trend     = @{ enabled = ($tw.Count -gt 0); words = $tw; last_run = ""; last_result = "" }



      brief     = @{ enabled = $false; at = "周一 09:30"; last_run = ""; last_result = "" }



    }



  }



  return $d



}







function Get-Tasks {



  $def = Get-TaskDefaults



  if (-not (Test-Path $tasksPath)) { return $def }



  $raw = $null



  try { $raw = [System.IO.File]::ReadAllText($tasksPath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $def }



  foreach ($pl in $def.Keys) {



    $pObj = $raw.PSObject.Properties[$pl]



    if (-not $pObj) { continue }



    foreach ($tid in $def[$pl].Keys) {



      $tObj = $pObj.Value.PSObject.Properties[$tid]



      if (-not $tObj) { continue }



      foreach ($k in @($def[$pl][$tid].Keys)) {



        $v = $tObj.Value.PSObject.Properties[$k]



        if ($v) { $def[$pl][$tid][$k] = $v.Value }



      }



    }



  }



  return $def



}







function Save-Tasks($all) {



  ($all | ConvertTo-Json -Depth 12) | Set-Content -Path $tasksPath -Encoding UTF8



}



while ($listener.IsListening) {



  try {



    $ctx = $listener.GetContext()



    $req = $ctx.Request



    $path = $req.Url.AbsolutePath







    if ($req.HttpMethod -eq "OPTIONS") { Send-Json $ctx 204 $null; continue }







    if ($path -eq "/health") {



      $ashInfo = @{ mode = "off"; mappings = 0; resolved = 0; resolved_with_id = 0; attempts_with_id = 0; attempts = 0; last_run = "" }

      try {

        $cfgAsh = Get-Content (Join-Path $here "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($cfgAsh.alias_shadow -and $cfgAsh.alias_shadow.enabled) { $ashInfo.mode = "shadow" }

        $ashFile = Join-Path $here "data\tg_alias_shadow.jsonl"

        if (Test-Path $ashFile) { $ashInfo.mappings = @(Get-Content $ashFile -Encoding UTF8 | Where-Object { $_.Trim() }).Count }

        $lastM = Get-ChildItem (Join-Path $here "data\tg_measure") -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($lastM) {

          $mj = Get-Content $lastM.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

          $ashInfo.last_run = [string]$mj.run_id

          $ashInfo.attempts_with_id = [int]$mj.resolved

          $ashInfo.resolved = [int]$mj.resolved

          $ashInfo.resolved_with_id = [int]$mj.resolved

          $ashInfo.attempts = [int]$mj.resolved + [int]$mj.miss

        }

      } catch { }



      Send-Json $ctx 200 @{ ok = $true; phase = $state.phase; running = $state.running }



      continue



    }







    if ($path -eq "/api/live") {



      $floodInfo = $null



      $floodFile = Join-Path $here "data\flood_state.json"



      if (Test-Path $floodFile) {



        try {



          $fs = Get-Content $floodFile -Raw -Encoding UTF8 | ConvertFrom-Json



          if ($fs.telegram) {



            $fb = $fs.telegram



            $floodInfo = @{



              retry_not_before = [string]$fb.retry_not_before; wait_sec = [int]$fb.wait_sec



              trigger = [string]$fb.trigger; pending = [int]$fb.pending_count; retry_due = [string]$fb.retry_due



              blocked = $((Get-Date) -lt [datetime]::Parse([string]$fb.retry_not_before, $null, [System.Globalization.DateTimeStyles]::RoundtripKind))



            }



          }



        } catch { $floodInfo = $null }



      }



      $ev = @()



      if ($state.events) { $ev = @($state.events) }



      $activePlat = [string]$state.activePlatform



      $activeAt = ""



      $isAct = $false



      if ($state.activeAt) {



        $activeAt = $state.activeAt.ToString("HH:mm:ss")



        $isAct = (((Get-Date) - $state.activeAt).TotalSeconds -lt 180)



      }



      Send-Json $ctx 200 @{



        running = $state.running; phase = $state.phase; platform = $Platform;



        activePlatform = $activePlat; activeAt = $activeAt; activeLive = $isAct;



        started = $(if ($state.started) { $state.started.ToString("HH:mm:ss") } else { "" });



        joined = $state.joined; existing = $state.existing; local = $state.local; joinDispatched = $state.joinDispatched; skipped = $state.skipped; failed = $state.failed;



        queue = $(if ($state.queue) { $state.queue.Count } else { 0 });



        candidates = $(if ($state.candidates) { $state.candidates.Count } else { 0 });



        current = [string]$state.current;



        task = [string]$state.phase;



        events = $ev;



        flood = $floodInfo;



        alias_shadow = $ashInfo;
        naming = (Get-NamingStats); fs_dbg = ([string]$script:Fs.base_app_token).Length;
        resume = (Get-ResumeLive);
        observedAt = (Get-Date).ToString("o");
        cooldowns = (Get-PlatformCooldownSnapshot -Path $script:PlatformCooldownPath -Now (Get-Date));
        pipeline = (Get-PipelineStatusView -BaseDir $here);
        stopFlag = (Get-GOpsStopInfo -BaseDir $here);
        runControl = (Get-RunControlView -BaseDir $here);




        sent = $(if ($state.searches) { [int]$state.searches } else { 0 })



      }



      continue



    }







    if ($path -eq "/state") {



      Send-Json $ctx 200 @{ phase = $state.phase; running = $state.running; joined = $state.joined; existing = $state.existing; local = $state.local; joinDispatched = $state.joinDispatched;



                            skipped = $state.skipped; failed = $state.failed; queue = $state.queue.Count;



                            queriesLeft = $state.queries.Count; candidates = $state.candidates.Count }



      continue



    }







    if ($path -eq "/api/pool") {



      if ($req.HttpMethod -eq "GET") {



        Send-Json $ctx 200 @{ keywords = @($cfg.keywordPool) }



        continue



      }



      $b = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $kw = @()



      if ($b.keywords) { $kw = @($b.keywords) }



      $cfg | Add-Member -Force -NotePropertyName keywordPool -NotePropertyValue $kw



      [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot "config.json"), ($cfg | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))



      Add-Event ("关键词池已更新 · " + $kw.Count + " 个")



      Send-Json $ctx 200 @{ ok = $true; count = $kw.Count }



      continue



    }







    if ($path -eq "/api/strategy" -and $req.HttpMethod -eq "GET") {



      $ext = $state.extHits



      Send-Json $ctx 200 @{ strategy = $cfg.strategy; alerts = $cfg.alerts; extHits = $ext }



      continue



    }



    if ($path -eq "/api/strategy" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $pl = [string]$body.platform



      if ($pl -and $cfg.strategy.$pl -and $body.patch) {



        foreach ($grp in $body.patch.PSObject.Properties.Name) {



          $val = $body.patch.$grp



          foreach ($k in $val.PSObject.Properties.Name) { $cfg.strategy.$pl.$grp.$k = $val.$k }



        }



      }



      if ($body.alerts) {



        foreach ($k in $body.alerts.PSObject.Properties.Name) { $cfg.alerts.$k = $body.alerts.$k }



      }



      ($cfg | ConvertTo-Json -Depth 12) | Set-Content -Path $cfgPath -Encoding UTF8



      Send-Json $ctx 200 @{ ok = $true; strategy = $(if ($pl) { $cfg.strategy.$pl } else { $cfg.strategy }); alerts = $cfg.alerts }



      continue



    }



    if ($path -eq "/api/event" -and $req.HttpMethod -eq "POST") {



      $raw = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()



      $msg = ""



      try { $msg = [string](($raw | ConvertFrom-Json).msg) } catch { $msg = "" }



      if ($msg) { Add-Event ("[外部] " + $msg) }



      Send-Json $ctx 200 @{ ok = $true; events = $state.events.Count }



      continue



    }







    if ($path -eq "/api/alert" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $lvl = [string]$body.level



      $pl  = [string]$body.platform



      $msg = [string]$body.message



      $line = (Get-Date).ToString("yyyy/MM/dd HH:mm:ss") + " [" + $lvl + "] " + $pl + " · " + $msg



      $logDir = Join-Path $PSScriptRoot "logs"



      if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }



      Add-Content -Path (Join-Path $logDir "alerts.log") -Value $line -Encoding UTF8



      $state.lastAlert = $line



      # 告警渠道：优先运维群，未配置则回落主群



      $hook = ''



      try {



        $nch = $cfg.notify.channels



        if ($nch) {



          $ops = $nch.ops; $main = $nch.main



          if ($ops -and $ops.enabled -and $ops.webhook) { $hook = [string]$ops.webhook }



          elseif ($main -and $main.enabled -and $main.webhook) { $hook = [string]$main.webhook }



        }



      } catch { }



      if (-not $hook) { $hook = $cfg.alerts.webhook }



      if (-not $hook) { $hook = $cfg.feishu.webhook }



      # 平台级开关：该平台 alerts=false 时只记日志不推送



      try { $pm = $cfg.notify.platforms; if ($pm -and $pl -and $pm.$pl -and -not [bool]$pm.$pl.alerts) { $hook = '' } } catch { }



      $sent = $false



      if ($hook) {



        try {



          $payload = @{ msg_type = "text"; content = @{ text = "【社么东西】" + $pl + " 告警`n" + $msg } } | ConvertTo-Json -Depth 6



          Invoke-RestMethod -Uri $hook -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null



          $sent = $true



        } catch { }



      }



      Send-Json $ctx 200 @{ ok = $true; notified = $sent; line = $line }



      continue



    }







    if ($path -eq "/api/extstats" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $state.extHits = [int]$body.hits



      $state.extAt = (Get-Date).ToString("yyyy/MM/dd HH:mm")



      Send-Json $ctx 200 @{ ok = $true }



      continue



    }



    if ($path -eq "/api/config" -and $req.HttpMethod -eq "GET") {



      $dbInfo = @{ enabled = $true; ready = $false; rows = 0; groups = 0; sizeText = ""; path = ""; error = "" }



      try {



        $dbPath = "data/groupops.db"



        try { if ($cfg.db -and $cfg.db.path) { $dbPath = [string]$cfg.db.path } } catch { }



        if (-not [System.IO.Path]::IsPathRooted($dbPath)) { $dbPath = Join-Path $here $dbPath }



        $dbInfo.path = $dbPath



        $dbInfo.enabled = ($null -ne $cfg.db -and $cfg.db.enabled -ne $false)



        $pyExe = Get-DbPython



        $dbInfo.ready = ($null -ne $pyExe) -and (Test-Path ([string]$pyExe))



        $dbInfo.python = [string]$pyExe



        if (Test-Path $dbPath) { $dbInfo.sizeText = ("{0:N1} MB" -f ((Get-Item $dbPath).Length / 1MB)) }



        if ($dbInfo.ready) {



          $st = Get-DbStats



          if ($st) { $dbInfo.rows = [int64]$st.rows; $dbInfo.groups = [int]$st.groups }



        }



      } catch { $dbInfo.error = [string]$_.Exception.Message }



      $aiOut = @{ has_key = $false; provider = ""; base_url = ""; model = ""; max_batch = 10; api_key_masked = "" }



      try {



        if ($cfg.ai) {



          $aiOut.provider = [string]$cfg.ai.provider



          $aiOut.base_url = [string]$cfg.ai.base_url



          $aiOut.model    = [string]$cfg.ai.model



          if ($cfg.ai.max_batch) { $aiOut.max_batch = [int]$cfg.ai.max_batch }



          $k = [string]$cfg.ai.api_key



          if (-not $k -and $cfg.ai.api_key_env) { $k = [string](Get-Item ("env:" + [string]$cfg.ai.api_key_env) -ErrorAction SilentlyContinue).Value }



          if ($k) {



            $aiOut.has_key = $true



            if ($k.Length -le 8) { $aiOut.api_key_masked = "****" } else { $aiOut.api_key_masked = $k.Substring(0, 3) + "…" + $k.Substring($k.Length - 4) }



          }



        }



      } catch { }



      Send-Json $ctx 200 @{ outputs = $cfg.outputs; schedule = $cfg.schedule; quotas = $cfg.quotas; platforms = $cfg.platforms; platformsEnabled = $cfg.platformsEnabled; behaviors = $cfg.behaviors; reserved = $cfg.reserved; notify = $cfg.notify; db = $dbInfo; ai = $aiOut; taskName = "DSH_SocialOps_Daily"; tasks = (Get-Tasks) }



      continue



    }







    if ($path -eq "/api/config" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      if ($body.outputs) {



        foreach ($k in @("feishu","sqlite","csv","jsonl")) {



          if ($body.outputs.PSObject.Properties.Name -contains $k) { $cfg.outputs.$k = [bool]$body.outputs.$k }



        }



      }



      if ($body.db) {



        if (-not $cfg.db) { $cfg | Add-Member -NotePropertyName db -NotePropertyValue ([pscustomobject]@{ enabled = $true; path = "data/groupops.db"; python = ""; auto_import = $true }) -Force }



        if ($body.db.PSObject.Properties.Name -contains "enabled") { $cfg.db.enabled = [bool]$body.db.enabled }



      }



      if ($body.schedule) {



        if ($body.schedule.PSObject.Properties.Name -contains "enabled") { $cfg.schedule.enabled = [bool]$body.schedule.enabled }



        if ($body.schedule.time) { $cfg.schedule.time = [string]$body.schedule.time }



      }



            if ($body.ai) {



        if (-not $cfg.ai) { $cfg | Add-Member -NotePropertyName ai -NotePropertyValue ([pscustomobject]@{}) -Force }



        foreach ($ak in @("provider","base_url","model","api_key","api_key_env")) {



          if ($body.ai.PSObject.Properties.Name -contains $ak) {



            $val = [string]$body.ai.$ak



            if ($ak -eq "api_key" -and ($val -eq "" -or $val -match "^(\*+|•+|x+)$")) { continue }



            if (-not ($cfg.ai.PSObject.Properties.Name -contains $ak)) {



              $cfg.ai | Add-Member -NotePropertyName $ak -NotePropertyValue $val -Force



            } else { $cfg.ai.$ak = $val }



          }



        }



        foreach ($ak2 in @("max_batch","timeout_sec")) {



          if ($body.ai.PSObject.Properties.Name -contains $ak2) {



            if (-not ($cfg.ai.PSObject.Properties.Name -contains $ak2)) {



              $cfg.ai | Add-Member -NotePropertyName $ak2 -NotePropertyValue ([int]$body.ai.$ak2) -Force



            } else { $cfg.ai.$ak2 = [int]$body.ai.$ak2 }



          }



        }



      }



      if ($body.notify) { $cfg | Add-Member -NotePropertyName notify -NotePropertyValue $body.notify -Force }



      if ($body.behaviors) {



        foreach ($bp in $body.behaviors.PSObject.Properties.Name) {



          if (-not $cfg.behaviors.$bp) {



            $cfg.behaviors | Add-Member -NotePropertyName $bp -NotePropertyValue ([pscustomobject]@{ discover = $true; join = $true; members = $true }) -Force



          }



          foreach ($bk in $body.behaviors.$bp.PSObject.Properties.Name) {



            $cfg.behaviors.$bp.$bk = [bool]$body.behaviors.$bp.$bk



          }



        }



      }



      if ($body.quotas) {



        foreach ($k in $body.quotas.PSObject.Properties.Name) { $cfg.quotas.$k = [int]$body.quotas.$k }



      }



      if ($body.platformsEnabled) {



        if (-not $cfg.PSObject.Properties.Name.Contains("platformsEnabled")) {



          $cfg | Add-Member -NotePropertyName platformsEnabled -NotePropertyValue ([pscustomobject]@{}) -Force



        }



        foreach ($k in $body.platformsEnabled.PSObject.Properties.Name) {



          if (-not ($cfg.platformsEnabled.PSObject.Properties.Name -contains $k)) {



            $cfg.platformsEnabled | Add-Member -NotePropertyName $k -NotePropertyValue ([bool]$body.platformsEnabled.$k) -Force



          } else { $cfg.platformsEnabled.$k = [bool]$body.platformsEnabled.$k }



        }



      }



      ($cfg | ConvertTo-Json -Depth 12) | Set-Content -Path $cfgPath -Encoding UTF8



      $task = Sync-ScheduleTask



      Send-Json $ctx 200 @{ ok = $true; outputs = $cfg.outputs; schedule = $cfg.schedule; task = $task }



      continue



    }



    if ($path -like "/src_*.js") {



      $jsf = Join-Path $PSScriptRoot ($path.TrimStart("/"))



      if (Test-Path $jsf) {



        $jb = [System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText($jsf, [System.Text.Encoding]::UTF8))



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "application/javascript; charset=utf-8"



        $ctx.Response.ContentLength64 = $jb.Length



        $ctx.Response.OutputStream.Write($jb, 0, $jb.Length)



        $ctx.Response.Close()



      } else { Send-Json $ctx 404 @{ error = "js missing" } }



      continue



    }



    if ($path -eq "/api/tasks" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $all = Get-Tasks



      $pl = [string]$body.platform



      $tid = [string]$body.task



      if ($all.ContainsKey($pl) -and $all[$pl].ContainsKey($tid) -and $body.patch) {



        foreach ($k in $body.patch.PSObject.Properties.Name) {



          $all[$pl][$tid][$k] = $body.patch.$k



        }



        Save-Tasks $all



      }



      Send-Json $ctx 200 @{ ok = $true; task = $all[$pl][$tid] }



      continue



    }



    if ($path -eq "/api/seed" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $added = 0



      foreach ($it in @($body.items)) {



        if (-not $it) { continue }



        $u = [string]$it.u



        if (-not $u) { continue }



        $u = $u.TrimStart("@")



        $id = "@" + $u



        if ($state.candidates.ContainsKey($id)) { continue }



        $state.candidates[$id] = @{ id = $id; u = $u; title = [string]$it.title; n = [int]$it.n; q = [string]$it.q; src = [string]$it.src }



        $added++



      }



      if ($body.start -and $added -gt 0) {



        $state.phase = "join"



        $state.running = $true



        Build-JoinQueue | Write-Host



      $poolN = Save-CandidatePool $Platform



  try {



    $fresh = @()



    foreach ($k2 in $state.candidates.Keys) { $fresh += $state.candidates[$k2] }



    $mg = Merge-IntoPool $Platform $fresh "search"



    Write-Host ("[hub] 候选入池新增 " + $mg.added + "，池深 " + $mg.depth + "（门槛 " + (Get-PoolWatermark $Platform) + "）")



    if ($mg.depth -lt (Get-PoolWatermark $Platform)) {



      Add-Event ("[池] " + $Platform + " 池深 " + $mg.depth + " 低于门槛 " + (Get-PoolWatermark $Platform) + "，需补水")



    }



  } catch { Write-Warning ("[hub] pool merge: " + $_.Exception.Message) }



      if ($poolN -gt 0) { Add-Event ("已存候选池 " + $poolN + " 个") }



      }



      Send-Json $ctx 200 @{ ok = $true; added = $added; candidates = $state.candidates.Count; phase = $state.phase }



      continue



    }



    if ($path -like "/icons/*") {



      $iconFile = Join-Path $PSScriptRoot ("extension\" + $path.TrimStart("/").Replace("/", "\"))



      if (Test-Path $iconFile) {



        $bytes = [System.IO.File]::ReadAllBytes($iconFile)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "image/png"



        $ctx.Response.ContentLength64 = $bytes.Length



        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)



        $ctx.Response.Close()



      } else { Send-Json $ctx 404 @{ error = "icon missing" } }



      continue



    }







    if ($path -eq "/api/db/stats" -and $req.HttpMethod -eq "GET") {



      Send-Json $ctx 200 (Get-DbStats)



      continue



    }







    if ($path -eq "/api/db/init" -and $req.HttpMethod -eq "POST") {



      $r = Initialize-LocalDb



      Add-Event ("[db] 初始化 " + $(if ($r.ok) { "成功" } else { "失败" }))



      Send-Json $ctx 200 $r



      continue



    }







    if ($path -eq "/api/db/import" -and $req.HttpMethod -eq "POST") {



      $usersCsv = Join-Path $here "data\users.csv"



      $r = Import-LocalDb -CsvPaths @($usersCsv)



      Add-Event ("[db] 导入 users.csv 行数=" + $r.imported)



      Send-Json $ctx 200 $r



      continue



    }







    if ($path -eq "/api/users") {



      $qs = @{}



      if ($req.Url.Query) {



        foreach ($pair in $req.Url.Query.TrimStart("?").Split("&")) {



          if (-not $pair) { continue }



          $kv = $pair.Split("=", 2)



          $k = [uri]::UnescapeDataString($kv[0])



          $v = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { "" }



          $qs[$k] = $v



        }



      }



      Send-Json $ctx 200 (Get-UsersPayload $qs)



      continue



    }







    if ($path -eq "/api/users/backup" -and $req.HttpMethod -eq "GET") {



      $bkDir = Join-Path $PSScriptRoot "data\backup"



      $files = @()



      if (Test-Path $bkDir) {



        $files = @(Get-ChildItem $bkDir -Filter "users_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {



          @{ name = $_.Name; at = $_.LastWriteTime.ToString("s"); kb = [int]($_.Length / 1024) }



        })



      }



      Send-Json $ctx 200 @{ ok = $true; dir = $bkDir; count = $files.Count; files = $files; last = $state.lastBackup }



      continue



    }



    if ($path -eq "/api/users/export") {



      $rows = Get-UsersCache



      $sb = New-Object System.Text.StringBuilder



      [void]$sb.AppendLine('平台,群ID,群名,用户ID,用户名,昵称,角色,采集日,来源')



      foreach ($r in $rows) {



        $nm = ([string]$r.'昵称') -replace '"', '""'



        $gn = ([string]$r.'群名') -replace '"', '""'



        [void]$sb.AppendLine(('"' + $r.'平台' + '","' + $r.'群ID' + '","' + $gn + '","' + $r.'用户ID' + '","' + $r.'用户名' + '","' + $nm + '","' + $r.'角色' + '","' + $r.'采集日' + '","' + $r.'来源' + '"'))



      }



      $bom = [byte[]](0xEF,0xBB,0xBF)



      $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())



      $bytes = New-Object byte[] ($bom.Length + $bodyBytes.Length)



      [Array]::Copy($bom, 0, $bytes, 0, $bom.Length)



      [Array]::Copy($bodyBytes, 0, $bytes, $bom.Length, $bodyBytes.Length)



      try {



        $bkDir = Join-Path $PSScriptRoot "data\backup"



        if (-not (Test-Path $bkDir)) { New-Item -ItemType Directory -Path $bkDir | Out-Null }



        $bk = Join-Path $bkDir ("users_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".csv")



        [System.IO.File]::WriteAllBytes($bk, $bytes)



        $olds = Get-ChildItem $bkDir -Filter "users_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10



        foreach ($o in $olds) { Remove-Item $o.FullName -Force -ErrorAction SilentlyContinue }



        $state.lastBackup = @{ file = $bk; at = (Get-Date).ToString("s"); rows = $rows.Count }



        Write-Host ("[hub] users backup -> " + $bk + " rows=" + $rows.Count)



      } catch { }



      $ctx.Response.StatusCode = 200



      $ctx.Response.ContentType = "text/csv; charset=utf-8"



      $ctx.Response.AddHeader("Content-Disposition", "attachment; filename=users.csv")



      $ctx.Response.ContentLength64 = $bytes.Length



      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)



      $ctx.Response.Close()



      continue



    }







    # ---- Discord 邀请链接（本地采集表） ----



    if ($path -eq "/api/discord_links" -and $req.HttpMethod -eq "GET") {



      $dl = Join-Path $PSScriptRoot "data\discord_links.jsonl"



      $items = @()



      if (Test-Path $dl) {



        foreach ($line in [System.IO.File]::ReadAllLines($dl, [System.Text.Encoding]::UTF8)) {



          if (-not $line.Trim()) { continue }



          try {



            $o = $line | ConvertFrom-Json



            $items += @{ ts = $o.ts; kw = $o.kw; code = $o.code; url = $o.url; src = $o.src; title = $o.title; ctx = $o.ctx }



          } catch {}



        }



      }



      [array]::Reverse($items)



      Send-Json $ctx 200 @{ count = $items.Count; items = @($items | Select-Object -First 500) }



      continue



    }



    if ($path -eq "/discord") {



      $df = Join-Path $PSScriptRoot "discord_links.html"



      if (Test-Path $df) {



        $html = [System.IO.File]::ReadAllText($df, [System.Text.Encoding]::UTF8)



        $hb = [System.Text.Encoding]::UTF8.GetBytes($html)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $hb.Length



        $ctx.Response.OutputStream.Write($hb, 0, $hb.Length)



        $ctx.Response.Close()



      } else {



        Send-Json $ctx 404 @{ error = "discord_links.html missing" }



      }



      continue



    }







    if ($path -eq "/wa") {



      $file = Join-Path $PSScriptRoot "wa.html"



      if (Test-Path $file) {



        $html = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)



        $hb = [System.Text.Encoding]::UTF8.GetBytes($html)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $hb.Length



        $ctx.Response.OutputStream.Write($hb, 0, $hb.Length)



        $ctx.Response.Close()



      } else {



        Send-Json $ctx 404 @{ error = "wa.html missing" }



      }



      continue



    }







    if ($path -eq "/users") {



      $file = Join-Path $PSScriptRoot "users.html"



      if (Test-Path $file) {



        $html = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)



        $hb = [System.Text.Encoding]::UTF8.GetBytes($html)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $hb.Length



        $ctx.Response.OutputStream.Write($hb, 0, $hb.Length)



        $ctx.Response.Close()



      } else {



        Send-Json $ctx 404 @{ error = "users.html missing" }



      }



      continue



    }







    if ($path -eq "/settings") {



      $sf = Join-Path $PSScriptRoot "settings.html"



      if (Test-Path $sf) {



        $sh = [System.IO.File]::ReadAllText($sf, [System.Text.Encoding]::UTF8)



        $sb = [System.Text.Encoding]::UTF8.GetBytes($sh)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $sb.Length



        $ctx.Response.OutputStream.Write($sb, 0, $sb.Length)



        $ctx.Response.Close()



      } else { Send-Json $ctx 404 @{ error = "settings.html missing" } }



      continue



    }







    if ($path -eq "/profile") {



      $pf = Join-Path $PSScriptRoot "profile.html"



      if (Test-Path $pf) {



        $html2 = [System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8)



        $hb2 = [System.Text.Encoding]::UTF8.GetBytes($html2)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $hb2.Length



        $ctx.Response.OutputStream.Write($hb2, 0, $hb2.Length)



        $ctx.Response.Close()



      } else { Send-Json $ctx 404 @{ error = "profile.html missing" } }



      continue



    }







    if ($path -eq "/api/profile/analyze" -and $req.HttpMethod -eq "POST") {



      $bd = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      $txt = [string]$bd.text



      $low = $txt.ToLower()



      $bt = "community"



      if ($low -match "开箱|箱子|opening|case|crate|roulette|upgrade") { $bt = "case_opening" }



      elseif ($low -match "交易|trade|market|sell|buy|买卖") { $bt = "trading" }







      $w = [ordered]@{ case_opening = 0.0; trading = 0.0; giveaway = 0.0; community = 0.0; esports = 0.0; team_recruit = 0.0; lfg = 0.0 }



      if ($bt -eq "case_opening") { $w.case_opening = 1.0; $w.trading = 0.6; $w.giveaway = 0.4; $w.community = 0.3; $w.esports = 0.1 }



      elseif ($bt -eq "trading") { $w.trading = 1.0; $w.case_opening = 0.5; $w.giveaway = 0.3; $w.community = 0.3; $w.esports = 0.1 }



      else { $w.community = 1.0; $w.trading = 0.5; $w.case_opening = 0.4; $w.esports = 0.2 }



      if ($low -match "赠品|giveaway|白嫖|抽奖|sorteio|розыгрыш") { $w.giveaway = [Math]::Max($w.giveaway, 0.6) }



      if ($low -match "电竞|赛事|比赛|esports|tournament") { $w.esports = [Math]::Max($w.esports, 0.3) }







      $excl = @()



      if ($low -match "不要|排除|不做|不需要") {



        if ($low -match "战队|招募|team|recruit") { $excl += "战队招募"; $w.team_recruit = 0.0 }



        if ($low -match "找队友|开黑|lfg|teammate") { $excl += "找队友"; $w.lfg = 0.0 }



      }







      $regions = @()



      if ($low -match "巴西|brazil|br\b") { $regions += "BR" }



      if ($low -match "俄罗斯|russia|ru\b") { $regions += "RU" }



      if ($low -match "土耳其|turkey|tr\b") { $regions += "TR" }



      if ($low -match "东南亚|sea|indonesia|philippines|vietnam|thailand") { $regions += "SEA" }



      if ($low -match "美国|usa|united states") { $regions += "US" }



      if ($low -match "欧洲|europe|eu\b") { $regions += "EU" }



      if ($low -match "印度|india") { $regions += "IN" }



      if ($regions.Count -eq 0) { $regions = @("US", "EU") }







      $langName = @{ BR = "葡语"; RU = "俄语"; TR = "土语"; SEA = "英语+印尼语"; US = "英语"; EU = "英语"; IN = "英语+印地语" }



      $langs = @()



      foreach ($rg in $regions) { if ($langName.ContainsKey($rg)) { $langs += $langName[$rg] } }



      $langs = @($langs | Select-Object -Unique)







      $th = [ordered]@{



        case_opening = @{ min_members = 150; recent_days = 3 }



        trading      = @{ min_members = 300; recent_days = 7 }



        community    = @{ min_members = 1000; recent_days = 7 }



      }







      Send-Json $ctx 200 @{



        business_type = $bt; regions = $regions; languages = $langs; exclude = $excl;



        intents = $w; thresholds = $th; source = $txt



      }



      continue



    }







    if ($path -eq "/leads") {



      $lf = Join-Path $PSScriptRoot "leads.html"



      if (Test-Path $lf) {



        $html3 = [System.IO.File]::ReadAllText($lf, [System.Text.Encoding]::UTF8)



        $hb3 = [System.Text.Encoding]::UTF8.GetBytes($html3)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $hb3.Length



        $ctx.Response.OutputStream.Write($hb3, 0, $hb3.Length)



        $ctx.Response.Close()



      } else { Send-Json $ctx 404 @{ error = "leads.html missing" } }



      continue



    }







    if ($path -eq "/api/ai/test" -and $req.HttpMethod -eq "POST") {



      $aiT = Get-AiConfig $script:Cfg



      if (-not $aiT) { Send-Json $ctx 200 @{ ok = $false; error = "no_key" }; continue }



      $ping = Invoke-AiChat $aiT "只回答一个字：好" "ping" ""



      if ($ping.ok) {



        Send-Json $ctx 200 @{ ok = $true; model = $aiT.model; reply = ([string]$ping.text).Trim(); tokens = $ping.usage.total_tokens }



      } else {



        Send-Json $ctx 200 @{ ok = $false; error = [string]$ping.error }



      }



      continue



    }







    if ($path -eq "/api/profile" -and $req.HttpMethod -eq "GET") {



      $prof = Get-GOpsProfile $script:Cfg



      Send-Json $ctx 200 @{ ok = $true; profile = $prof }



      continue



    }







    if ($path -eq "/api/profile/generate" -and $req.HttpMethod -eq "POST") {



      $bodyP = $null



      try { $bodyP = ((New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json) } catch { }



      $txtP = ""



      if ($bodyP -and $bodyP.text) { $txtP = [string]$bodyP.text }



      if (-not $txtP.Trim()) { Send-Json $ctx 400 @{ error = "text_required" }; continue }



      $profNew = New-GOpsProfilePack $script:Cfg $txtP



      Save-GOpsProfile (Join-Path $PSScriptRoot "config.json") $script:Cfg $profNew | Out-Null



      $script:Cfg = Get-Content (Join-Path $PSScriptRoot "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json



      Add-Event ("[profile] 已生成检索包 " + $profNew.business_type + " / " + (@($profNew.platforms.Reddit.queries).Count) + " 个查询词")



      Send-Json $ctx 200 @{ ok = $true; profile = $profNew }



      continue



    }







    if ($path -eq "/api/leads" -and $req.HttpMethod -eq "GET") {



      $lj = Join-Path $PSScriptRoot "data\leads_signals.json"



      if (Test-Path $lj) {



        $lraw = [System.IO.File]::ReadAllText($lj, [System.Text.Encoding]::UTF8)



        Send-Json $ctx 200 ($lraw | ConvertFrom-Json)



      } else { Send-Json $ctx 200 @{ scanned_at = ""; unique = 0; items = @() } }



      continue



    }







    if ($path -eq "/api/leads/scored" -and $req.HttpMethod -eq "GET") {



      $sj = Join-Path $PSScriptRoot "data\leads_scored.json"



      if (Test-Path $sj) {



        $sraw = [System.IO.File]::ReadAllText($sj, [System.Text.Encoding]::UTF8)



        Send-Json $ctx 200 ($sraw | ConvertFrom-Json)



      } else { Send-Json $ctx 200 @{ total = 0; items = @() } }



      continue



    }







    if ($path -eq "/api/members" -and $req.HttpMethod -eq "GET") {

      try {
        Send-Json $ctx 200 (Get-MemberOverview $here)
      } catch {
        Send-Json $ctx 500 @{ ok = $false; error = "members_report_failed" }
      }

      continue

    }

    if ($path -eq "/api/wa" -and $req.HttpMethod -eq "GET") {



      $waJson = Join-Path $PSScriptRoot "data\wa_candidates.json"



      $items = @(); $queries = 0; $mode = "search_only"; $maxJoin = 0



      if (Test-Path $waJson) {



        try {



          $o = [System.IO.File]::ReadAllText($waJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json



          $items = @($o.items); $queries = @($o.queries).Count



        } catch {}



      }



      try { if ($cfg.wa) { $mode = [string]$cfg.wa.mode; $maxJoin = [int]$cfg.wa.max_join } } catch {}



      $high = 0; $pend = 0; $joined = 0; $appr = 0; $bad = 0



      foreach ($it in $items) {



        $rel = [string]$it.relevance; $st = [string]$it.status; $jn = [string]$it.join



        if ($rel -eq "high") { $high++ }



        if ($st -eq "待验证" -or $st -eq "待确认") { $pend++ }



        if ($jn -eq "已加入" -or $jn -eq "已在群内") { $joined++ }



        if ($jn -like "已提交待审批*") { $appr++ }



        if ($st -eq "已失效" -or $st -eq "访问失败" -or $st -eq "需登录") { $bad++ }



      }



      $sorted = @($items | Sort-Object @{ Expression = { if ([string]$_.relevance -eq "high") { 0 } elseif ([string]$_.relevance -eq "medium") { 1 } elseif ([string]$_.relevance -eq "pending") { 2 } else { 3 } } })



      if ($sorted.Count -gt 300) { $sorted = $sorted[0..299] }



      Send-Json $ctx 200 @{ ok = $true; items = $sorted; stats = @{ total = $items.Count; high = $high; pending = $pend; joined = $joined; approval = $appr; bad = $bad; queries = $queries; mode = $mode; maxJoin = $maxJoin } }



      continue



    }







    if ($path -eq "/api/candidates" -and $req.HttpMethod -eq "GET") {



      $pp = Get-PoolPath $Platform



      if (Test-Path $pp) {



        $o = [System.IO.File]::ReadAllText($pp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json



        Send-Json $ctx 200 @{ ok = $true; platform = $Platform; savedAt = $o.savedAt; count = $o.count; path = $pp }



      } else {



        Send-Json $ctx 200 @{ ok = $true; platform = $Platform; savedAt = $null; count = 0; path = $pp }



      }



      continue



    }



    if ($path -eq "/api/candidates/save" -and $req.HttpMethod -eq "POST") {



      $n = Save-CandidatePool $Platform



      Send-Json $ctx 200 @{ ok = $true; count = $n }



      continue



    }



    if ($path -eq "/api/summary") {



      Send-Json $ctx 200 (Get-Summary)



      continue



    }







    if ($path -eq "/" -or $path -eq "/dashboard") {



      $file = Join-Path $PSScriptRoot "dashboard.html"



      if (Test-Path $file) {



        $html = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)



        $hb = [System.Text.Encoding]::UTF8.GetBytes($html)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $hb.Length



        $ctx.Response.OutputStream.Write($hb, 0, $hb.Length)



        $ctx.Response.Close()



      } else {



        Send-Json $ctx 404 @{ error = "dashboard.html missing" }



      }



      continue



    }



    if ($path -eq "/control" -and $req.HttpMethod -eq "POST") {



      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json



      if ($body.action -eq "members_start" -or $body.action -eq "members_stop") {

        $memberPlatform = [string]$body.platform
        if ($memberPlatform -notin @("Steam", "Telegram")) {
          Send-Json $ctx 400 @{ ok = $false; error = "unknown_platform" }
          continue
        }

        if ($body.action -eq "members_stop") {
          $sr = Request-MemberStop $here $memberPlatform
          if (-not $sr.ok) { Send-Json $ctx 500 @{ ok = $false; error = $sr.error }; continue }
          Add-Event ("[hub] " + $memberPlatform + " 成员采样已请求停止")
          Send-Json $ctx 200 @{ ok = $true; platform = $memberPlatform; stopping = $true }
          continue
        }

        $target = [string]$body.target
        $trial = [bool]$body.trial
        $sr = Start-MemberSampleProcess -BaseDir $here -Platform $memberPlatform -Target $target -Trial:$trial
        if (-not $sr.ok) {
          $code = if ($sr.error -eq "stopped" -or $sr.error -eq "member_running") { 409 } else { 400 }
          Send-Json $ctx $code @{ ok = $false; error = $sr.error; platform = $memberPlatform }
          continue
        }
        Add-Event ("[hub] " + $memberPlatform + " 成员采样已启动 target=" + [string]$sr.target)
        Send-Json $ctx 200 @{ ok = $true; platform = $memberPlatform; target = [string]$sr.target; trial = $trial }
        continue

      }

      if ($body.action -eq "pipeline") {



  # manual stop flag is respected; never clear it on start/pipeline
        if (Test-GOpsStop $here) {
          Send-Json $ctx 409 @{ ok = $false; error = "stopped" }
          continue
        }



        # 一键全流程：交给 run_all.ps1 串行调度（拓群 -> 成员 -> 回填 -> Steam -> Reddit）



        $ra = Join-Path $PSScriptRoot "run_all.ps1"



        if (-not (Test-Path $ra)) {



          Send-Json $ctx 500 @{ ok = $false; error = "run_all_missing" }



          continue



        }



        $argLine = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $ra + "`""))



        Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -WindowStyle Hidden



        $state.phase = "pipeline"



        Add-Event "[hub] 一键流程已启动 run_all.ps1"



        Send-Json $ctx 200 @{ ok = $true; phase = "pipeline" }



        continue



      }



      if ($body.action -eq "steam") {



        # Steam 每日：加群 -> 录入用户数据 -> 导入本地库（全程 /api/event 可见）



        $sd = Join-Path $PSScriptRoot "steam_daily.ps1"



        if (-not (Test-Path $sd)) {



          Send-Json $ctx 500 @{ ok = $false; error = "steam_daily_missing" }



          continue



        }



        $sa = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $sd + "`""))



        if ($body.maxPages) { $sa += @("-MaxPages", [string][int]$body.maxPages) }



        if ($body.delayMs) { $sa += @("-DelayMs", [string][int]$body.delayMs) }



        Start-Process -FilePath "powershell.exe" -ArgumentList $sa -WindowStyle Hidden



        Add-Event "[hub] Steam 每日流程已启动"



        Send-Json $ctx 200 @{ ok = $true; phase = "steam" }



        continue



      }



      if ($body.action -eq "wa") {



        $stage = "search"



        if ($body.PSObject.Properties.Name -contains "stage") { $stage = [string]$body.stage }



        $dis = Join-Path $PSScriptRoot "wa_discover.ps1"



        $ver = Join-Path $PSScriptRoot "wa_verify.ps1"



        if ($stage -eq "search" -or $stage -eq "all") {



          if (-not (Test-Path $dis)) { Send-Json $ctx 500 @{ ok = $false; error = "wa_discover_missing" }; continue }



          $mq = 12



          if ($body.PSObject.Properties.Name -contains "maxQueries") { $mq = [int]$body.maxQueries }



          $da = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $dis + "`""), "-MaxQueries", [string]$mq)



          Start-Process -FilePath "powershell.exe" -ArgumentList $da -WindowStyle Hidden



          Add-Event ("[hub] WhatsApp 搜索已启动 (maxQueries=" + $mq + ")")



        }



        if ($stage -eq "verify" -or $stage -eq "all") {



          if (-not (Test-Path $ver)) { Send-Json $ctx 500 @{ ok = $false; error = "wa_verify_missing" }; continue }



          $mv = 8



          if ($body.PSObject.Properties.Name -contains "maxVerify") { $mv = [int]$body.maxVerify }



          $va = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $ver + "`""), "-MaxVerify", [string]$mv)



          Start-Process -FilePath "powershell.exe" -ArgumentList $va -WindowStyle Hidden



          Add-Event ("[hub] WhatsApp 验证已启动 (maxVerify=" + $mv + ")")



        }



        $state.phase = "wa"



        Send-Json $ctx 200 @{ ok = $true; stage = $stage }



        continue



      }



      if ($body.action -eq "start") {



  # manual stop flag is respected; never clear it on start/pipeline
        if (Test-GOpsStop $here) {
          Send-Json $ctx 409 @{ ok = $false; error = "stopped" }
          continue
        }
        if ($body.platform) {



          $want = [string]$body.platform



          $known = @()



          try { $known = @($cfg.platforms | ForEach-Object { [string]$_ }) } catch { }



          if ($known.Count -eq 0) { try { $known = @($cfg.quotas.PSObject.Properties.Name) } catch { } }



          if ($known -contains $want) {



            $script:Platform = $want



            Add-Event ("[hub] 切到平台 " + $want)



          } else {



            Send-Json $ctx 400 @{ ok = $false; error = "unknown_platform"; platform = $want; known = $known }



            continue



          }



        }



        $en = $true



        if ($cfg.PSObject.Properties.Name.Contains("platformsEnabled") -and $cfg.platformsEnabled) {



          $pn = $cfg.platformsEnabled.PSObject.Properties.Name



          if ($pn -contains $Platform) { $en = [bool]$cfg.platformsEnabled.$Platform }



        }



        if (-not $en) {



          Send-Json $ctx 409 @{ ok = $false; error = "platform_disabled"; platform = $Platform }



          continue



        }



        $cool = Get-PlatformCooldown -Path $script:PlatformCooldownPath -Platform $Platform
        if ($cool) {
          Send-Json $ctx 409 @{ ok = $false; error = "cooldown"; platform = $Platform; until = $cool.until.ToString("o"); remaining_sec = $cool.remaining_sec }
          continue
        }
        Write-Host (Start-Run)



        # poolOnly：跳过关键词搜索，直接用候选池建队列（用于「池里已经有钱，先花掉」）



        if ($body.skipSearch) {



          try {



            $state.queries.Clear()



            Add-Event "[hub] skipSearch：本平台只走候选池"



          } catch {}



        }



        if ($body.poolOnly) {



          try {



            $state.queries.Clear()



            Build-JoinQueue | Out-Null



            $state | Add-Member -NotePropertyName poolOnlyOnce -NotePropertyValue $true -Force



            Add-Event ("[hub] poolOnly：已记录，探针完成后直接进入加入阶段（池深 " + @(Get-PoolItems $Platform).Count + "）")



          } catch { Write-Host ("[hub] poolOnly 失败: " + $_.Exception.Message) }



        }



      }



      elseif ($body.action -eq "joinnow") {



        try {



          $state.queries.Clear()



          if ($body.platform) {



            $want = [string]$body.platform



            $known = @($cfg.platforms | ForEach-Object { [string]$_ })



            if ($known -contains $want) { $script:Platform = $want }



          }



          Build-JoinQueue | Out-Null



          $state.phase = "join"



          $state.running = $true



          $state.nextAt = Get-Date



          Add-Event ("[hub] joinnow：直接进入加入阶段（" + $Platform + "，池深 " + @(Get-PoolItems $Platform).Count + "）")



        } catch { Write-Host ("[hub] joinnow err: " + $_.Exception.Message) }



      }



      elseif ($body.action -eq "round_stop") {
        $active = Get-ActiveRunForControl
        if ($active.source -eq "none") {
          Send-Json $ctx 200 @{ ok = $false; error = "idle" }
          continue
        }
        $reqId = [string]$body.run_id
        if ($active.source -eq "pipeline" -and (-not $reqId -or $reqId -ne $active.run_id)) {
          Send-Json $ctx 409 @{ ok = $false; error = "stale_run"; run_id = $active.run_id }
          continue
        }
        if ($reqId -and $active.run_id -and $reqId -ne $active.run_id) {
          Send-Json $ctx 409 @{ ok = $false; error = "stale_run"; run_id = $active.run_id }
          continue
        }
        if ($active.source -eq "pipeline") {
          $rr = Request-RunStop -BaseDir $here -RunId $active.run_id
          if (-not $rr.ok) {
            Send-Json $ctx 409 @{ ok = $false; error = $rr.reason; run_id = $active.run_id }
            continue
          }
          $state.running = $false
          $state.phase = "idle"
          Send-Json $ctx 200 @{ ok = $true; source = "pipeline"; run_id = $active.run_id; already = [bool]$rr.already }
          continue
        }
        $state.running = $false
        $state.phase = "idle"
        Send-Json $ctx 200 @{ ok = $true; source = "hub"; local_only = $true }
        continue
      }

      elseif ($body.action -eq "skip_platform") {
        $active = Get-ActiveRunForControl
        if ($active.source -eq "none") {
          Send-Json $ctx 200 @{ ok = $false; error = "idle" }
          continue
        }
        $wantPlat = [string]$body.platform
        if (-not $wantPlat) { $wantPlat = [string]$active.platform }
        if ($active.source -eq "pipeline") {
          $reqId = [string]$body.run_id
          if (-not $reqId -or $reqId -ne $active.run_id) {
            Send-Json $ctx 409 @{ ok = $false; error = "stale_run"; run_id = $active.run_id }
            continue
          }
          if ($wantPlat -and $active.platform -and $wantPlat -ne $active.platform) {
            Send-Json $ctx 409 @{ ok = $false; error = "stale_platform"; platform = $active.platform }
            continue
          }
          $sr = Request-PlatformSkip -BaseDir $here -RunId $active.run_id -Platform $wantPlat
          if (-not $sr.ok) {
            Send-Json $ctx 409 @{ ok = $false; error = $sr.reason; platform = $active.platform; run_id = $active.run_id }
            continue
          }
          $state.running = $false
          $state.phase = "idle"
          Send-Json $ctx 200 @{ ok = $true; source = "pipeline"; run_id = $active.run_id; platform = $wantPlat; already = [bool]$sr.already }
          continue
        }
        if ($wantPlat -and $wantPlat -ne [string]$Platform) {
          Send-Json $ctx 409 @{ ok = $false; error = "stale_platform"; platform = [string]$Platform }
          continue
        }
        $state.running = $false
        $state.phase = "idle"
        Send-Json $ctx 200 @{ ok = $true; source = "hub"; local_only = $true; platform = [string]$Platform }
        continue
      }

      elseif ($body.action -eq "clear_stop") {
        $cr = Clear-KnownHubStop -BaseDir $here
        if (-not $cr.ok) {
          Send-Json $ctx 409 @{ ok = $false; error = $cr.reason; detail = [string]$cr.detail }
          continue
        }
        Add-Event "[hub] 已显式解除已知急停标记"
        Send-Json $ctx 200 @{ ok = $true; cleared = $true; backup = [string]$cr.backup; reason = [string]$cr.reason }
        continue
      }

      elseif ($body.action -eq "stop") {
        $state.running = $false
        $state.phase = "idle"
        if (-not $body.cleanup) { try { Set-GOpsStopWithMeta $here ("hub stop " + (Get-Date).ToString("HH:mm:ss")) "hub_stop" ([string]$body.run_id) | Out-Null } catch {} }
        Write-Host "[hub] stopped"
      }



      Send-Json $ctx 200 @{ ok = $true; phase = $state.phase }



      continue



    }







    if ($path -eq "/task" -and $req.HttpMethod -eq "GET") {



      if (-not $state.running) { Send-Json $ctx 204 $null; continue }



      if ((Get-Date) -lt $state.nextAt) { Send-Json $ctx 204 $null; continue }







      if ($state.phase -eq "probe") {



        $id = Next-TaskId



        $state.pending = @{ kind = "probe"; id = $id }



        Send-Json $ctx 200 @{ action = "probe"; platform = $Platform; id = $id }



        continue



      }



      if ($state.phase -eq "search") {



        if ($state.queries.Count -eq 0) {



      if (-not $state.relaxed -and $state.candidates.Count -lt $need) {



        $state.relaxed = $true



        $floor = 30



    try { if ($cfg.filters.min_floor) { $floor = [int]$cfg.filters.min_floor } } catch { }



    $state.minNow = [Math]::Max($floor, [int][Math]::Floor($minMembers / 3))



        foreach ($q in @(Get-Keywords $Platform)) { $state.queries.Enqueue($q) }



        Write-Host ("[hub] 候选不足，放宽到 " + $state.minNow + " 人重跑一轮")



        Send-Json $ctx 204 $null; continue



      }



      if ($state.relaxed -and -not $state.relaxed2 -and $state.candidates.Count -lt $need -and [int]$state.minNow -gt $floor) {



        $state.relaxed2 = $true



        $state.minNow = $floor



        foreach ($q in @(Get-Keywords $Platform)) { $state.queries.Enqueue($q) }



        Write-Host ("[hub] 候选仍不足，门槛降到 50 重跑一轮")



        Add-Event ("候选仍不足，门槛降到 " + 50 + " 重跑一轮")



        Send-Json $ctx 204 $null; continue



      }



      Build-JoinQueue | Write-Host



      $state.current = "搜索完成 · 候选 " + $state.candidates.Count + " · 待加入 " + $state.queue.Count



      Add-Event ("搜索完成 · 候选 " + $state.candidates.Count + " / 待加入 " + $state.queue.Count)



      Send-Json $ctx 204 $null



      continue



    }



        $q = $state.queries.Dequeue()



        $id = Next-TaskId



        $state.pending = @{ kind = "search"; id = $id; query = $q; t0 = (Get-Date) }



        $state.current = "搜索：" + $q



        Send-Json $ctx 200 @{ action = "search"; platform = $Platform; id = $id; query = $q; limit = 30 }



        Start-Sleep -Milliseconds (Rand-Int 3 8 * 100)



        continue



      }



      if ($state.phase -eq "join") {



        $joinTask = $null
        while ($state.queue.Count -gt 0) {
          $peek = $state.queue.Peek()
          $wl = @()
          if ($Platform -eq "Facebook") { $wl = @($script:JoinWhitelist) }
          $dec = Get-JoinDispatchDecision -Whitelist $wl -TargetKeys @([string]$peek.id, [string]$peek.u) -Dispatched ([int]$state.joinDispatched) -MaxAttempts 1
          if (-not $dec.allow) {
            $null = $state.queue.Dequeue()
            $state.skipped++
            $nmSkip = if ([string]$peek.title) { [string]$peek.title } else { [string]$peek.t }
            Add-Event ("[gate] " + $nmSkip + " 跳过：" + $dec.reason)
            continue
          }
          $joinTask = $state.queue.Dequeue()
          if ($wl.Count -gt 0) { $state.joinDispatched++ }
          break
        }
        if (-not $joinTask) {
          $state.phase = "done"; $state.running = $false
          Add-Event ("本轮结束 · 加入 " + $state.joined + " / 已存在 " + $state.existing + " / 本地 " + $state.local + " / 跳过 " + $state.skipped + " / 失败 " + $state.failed)
          Send-Json $ctx 204 $null
          continue
        }



        $c = $joinTask



        $id = Next-TaskId



        $state.pending = @{ kind = "join"; id = $id; cand = $c }



        $rd = 0; try { $rd = [int]$cfg.filters.recent_activity_days } catch { }



        $navUrl = ""
        if ($Platform -eq "Facebook") { $navUrl = "https://www.facebook.com/groups/" + [string]$c.id + "/" }

        Send-Json $ctx 200 @{ action = "join"; platform = $Platform; id = $id; u = $c.u; chatId = $c.id; navUrl = $navUrl;



                              title = $(if ([string]$c.title) { [string]$c.title } else { [string]$c.t }); n = $c.n; self = $state.self; q = $c.q; recentDays = $rd;



                              hash = [string]$c.h; kind = [string]$c.k }



        continue



      }



      Send-Json $ctx 204 $null



      continue



    }







    if ($path -eq "/result" -and $req.HttpMethod -eq "POST") {



      $raw = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()



      $r = $raw | ConvertFrom-Json



      $kind = [string]$r.kind







      if ($kind -eq "probe") {



        if ($r.value) { $state.self = [string]$r.value.self }



        if ($state.poolOnlyOnce) {



          $state | Add-Member -NotePropertyName poolOnlyOnce -NotePropertyValue $false -Force



          $state.phase = "join"



          $state.nextAt = Get-Date



          Build-JoinQueue | Out-Null



          Add-Event "[hub] poolOnly：探针完成，直接进入加入阶段（跳过搜索）"



          Write-Host ("[hub] probe ok -> join (poolOnly) self=" + $state.self)



        } else {



          if ($state.phase -eq "probe") {



            $state.phase = "search"



            Write-Host ("[hub] probe ok self=" + $state.self)



          } else {



            Write-Host ("[hub] probe ok（保持阶段 " + $state.phase + "）")



          }



        }



      }



      elseif ($kind -eq "search") {



        $q = $state.pending.query



        $cnt = 0



        if (-not $state.funnel) { $state | Add-Member -NotePropertyName funnel -NotePropertyValue @{} -Force }



        $fn = $state.funnel



        foreach ($fk in @("unique","eligible","joined","pending","unknown","small","offtopic","dedup","priv","excluded")) {



          if (-not $fn.ContainsKey($fk)) { $fn[$fk] = 0 }



        }



        foreach ($c in @($r.value)) {



          if (-not $c) { continue }



          $fn.unique++



          # bc 语义按平台区分：Facebook 的 bc = 已加入；Telegram 的 bc = 广播频道（两者都不是可加入目标）



          if ($c.bc) { if ($Platform -eq 'Facebook') { $fn.joined++ } else { $fn.excluded++ }; continue }



          if ($c.priv) { $fn.priv++; continue }



          if ($c.req) { $fn.pending++; continue }



          if ([int]$c.n -le 0) { $fn.unknown++; continue }



          if ([int]$c.n -lt $state.minNow) { $fn.small++; continue }



          $id = [string]$c.id



          if ($seen.ContainsKey($id)) { $fn.dedup++; continue }



          if ($c.u -and $seen.ContainsKey(([string]$c.u).ToLower())) { $fn.dedup++; continue }



          $t = ([string]$c.title).Trim().ToLower()



          if ($seenTitles.ContainsKey($t)) { $fn.dedup++; continue }



          if ($c.title -match $exclude) { $fn.offtopic++; continue }



          if ($Platform -eq 'Facebook') {



            $tn = [string]$c.title



            if ($tn -notmatch '(?i)(cs2|csgo|cs:go|counter[\s\-]?strike|skinvs|dmarket|buff163|skinport|csgoroll|csgoempire|skins? (trade|market|sell|buy)|vaka|swap\.gg)') { $fn.offtopic++; continue }



          }



          if ($state.candidates.ContainsKey($id)) { $fn.dedup++; continue }



          $uk = ("@" + ([string]$c.u)).ToLower()



          if ($c.u -and $state.skipSet -and $state.skipSet.ContainsKey($uk)) { $fn.excluded++; continue }



          $state.candidates[$id] = @{ id = $id; u = [string]$c.u; title = [string]$c.title; n = [int]$c.n; q = $q; h = [string]$c.h; k = [string]$c.k }



          Write-Host ("[hub] cand id=" + $id + " u=" + $c.u + " h=" + (("" + $c.h).Length) + " k=" + $c.k)



          $fn.eligible++



          $cnt++



        }



        $rawN = @($r.value).Count



        Write-Host ("[hub] search '$q' raw=$rawN new=$cnt min=$($state.minNow) seen=$($seen.Count)")



function Add-SourceLedger([string]$pf, [string]$query, $fn, [int]$costMs, [string]$reason) {



  try {



    $dir = Join-Path $PSScriptRoot "data"



    if (-not (Test-Path $dir)) { return }



    $row = [ordered]@{



      ts        = (Get-Date).ToString("s")



      platform  = $pf



      source_id = "keyword_search"



      query     = $query



      raw       = [int]$fn.unique



      eligible  = [int]$fn.eligible



      joined    = [int]$fn.joined



      pending   = [int]$fn.pending



      small     = [int]$fn.small



      offtopic  = [int]$fn.offtopic



      dup       = [int]$fn.dedup



      priv      = [int]$fn.priv



      excluded  = [int]$fn.excluded



      cost_ms   = $costMs



      reason    = $reason



    }



    $line = ($row | ConvertTo-Json -Compress)



    Add-Content -Path (Join-Path $dir "source_ledger.jsonl") -Value $line -Encoding UTF8



  } catch { }



}







        Write-Host ("[hub] funnel " + $Platform + " unique=" + $fn.unique + " eligible=" + $fn.eligible + " joined=" + $fn.joined + " pending=" + $fn.pending + " unknown=" + $fn.unknown + " small=" + $fn.small + " offtopic=" + $fn.offtopic + " dedup=" + $fn.dedup + " priv=" + $fn.priv + " excluded=" + $fn.excluded)



        $costMs = 0



        if ($state.pending -and $state.pending.t0) { $costMs = [int]((Get-Date) - $state.pending.t0).TotalMilliseconds }



        # 账本记「本次查询的增量」，不是运行累计（funnel 是累计的）



        $keys = @("unique","eligible","joined","pending","small","offtopic","dedup","priv","excluded")



        if (-not $state.ledgerLast) {



          $state.ledgerLast = @{}



          foreach ($k in $keys) { $state.ledgerLast[$k] = 0 }



        }



        $delta = @{}



        foreach ($k in $keys) {



          $d = [int]$fn[$k] - [int]$state.ledgerLast[$k]



          if ($d -lt 0) { $d = [int]$fn[$k] }



          $delta[$k] = $d



        }



        Add-SourceLedger $Platform $q $delta $costMs "search"



        foreach ($k in $keys) { $state.ledgerLast[$k] = [int]$fn[$k] }



        if ($rawN -gt 0 -and $cnt -eq 0) {



          $s0 = @($r.value)[0]



          Write-Host ("[hub] sample raw: n=" + $s0.n + " t=" + $s0.title + " bc=" + $s0.bc)



        }



        Add-Event ("搜索 " + $q + " → 新增 " + $cnt + " 个候选")



        $state.searches++



        # 链路异常 = 扩展一条都没返回；关键词枯竭 = 有返回但全是已收录/被过滤



        if ($rawN -eq 0) { $state.zeroStreak++ } else { $state.zeroStreak = 0 }



        if ($cnt -eq 0 -and $rawN -gt 0) { $state.dryStreak++ } else { $state.dryStreak = 0 }



        if ($state.dryStreak -ge 12 -and $state.phase -eq "search") {



          $state.queries.Clear()



          Build-JoinQueue | Write-Host



          Add-Event ("关键词已挖尽（连续 " + $state.dryStreak + " 个无新增），候选 " + $state.candidates.Count + " / 待加入 " + $state.queue.Count)



        }



        $limitZero = 8; try { if ($cfg.health -and $cfg.health.zero_streak) { $limitZero = [int]$cfg.health.zero_streak } } catch { }



        if ($state.zeroStreak -ge $limitZero) {



          $state.phase = "done"



          $state.running = $false



          $msg = "采集链路异常：" + $Platform + " 连续 " + $state.zeroStreak + " 个关键词扩展返回 0 条结果（最后：" + $q + "），已中止本轮"



          Write-Host ("[hub] " + $msg)



          Add-Event $msg

          try {
            $coolMin = 30
            if ($cfg.health -and $cfg.health.platform_cooldown_min) { $coolMin = [int]$cfg.health.platform_cooldown_min }
            if ($coolMin -lt 1) { $coolMin = 30 }
            $cool = Set-PlatformCooldown -Path $script:PlatformCooldownPath -Platform $Platform -Minutes $coolMin -Reason "collector_stalled"
            Add-Event ("[hub] " + $Platform + " 冷却至 " + $cool.until.ToString("HH:mm") + "（" + $coolMin + " 分钟），本轮只停该平台")
          } catch { }



          $cd = 30; try { if ($cfg.health -and $cfg.health.alert_cooldown_min) { $cd = [int]$cfg.health.alert_cooldown_min } } catch { }



          $canAlert = $true



          if ($state.lastAlertAt -and ((Get-Date) - [datetime]$state.lastAlertAt).TotalMinutes -lt $cd) { $canAlert = $false }



          if ($canAlert) {



            try { Send-Alert $Platform "collector_stalled" $msg | Out-Null; $state.lastAlertAt = Get-Date } catch { }



          }



        }



      }



      elseif ($kind -eq "join") {



        $v = [string]$r.value



        $tgt = $r.target



        if (-not $tgt -and $state.pending -and $state.pending.cand) { $tgt = $state.pending.cand }



        if ($v -eq "joined" -or $v -eq "already") {



          if ($tgt) {
            try {
              $nmOn = $true; try { if ($null -ne $cfg.naming.enabled) { $nmOn = [bool]$cfg.naming.enabled } } catch { }
              $useRc = $true; try { if ($null -ne $cfg.naming.from_receipt) { $useRc = [bool]$cfg.naming.from_receipt } } catch { }
              if ($nmOn) {
                $nm = Resolve-JoinName $tgt $script:receiptNames $useRc
                if ($nm.name) { $tgt.title = $nm.name }
                if ([string]$tgt.id) { $script:receiptNames[[string]$tgt.id] = [string]$nm.name }
                if ([string]$tgt.u) { $script:receiptNames[[string]$tgt.u] = [string]$nm.name }
              }
            } catch { }
            $joinRec = Write-JoinRecord $tgt $v
            $disp = Get-JoinRecordDisposition -Status ([string]$joinRec.status)
            $state.joined += [int]$disp.joined
            $state.existing += [int]$disp.existing
            $state.local += [int]$disp.local
            $state.failed += [int]$disp.failed
            Add-Event ("记录 " + $tgt.title + " => " + $joinRec.status + " (cloud=" + $joinRec.cloud + ")")
          } else {
            $state.failed++
          }



          $state.fails = 0



        } elseif ($v -eq "stale") {



          $state.skipped++



          $state.fails = 0



          $state.stale++



        } elseif ($v -eq "request_sent" -or $v -eq "not_found" -or $v -eq "approval" -or $v -eq "visited") {



          if ($v -eq "request_sent" -and $tgt) {
            $joinRec = Write-JoinRecord $tgt $v
            Add-Event ("待验证记录 " + $tgt.title + " => " + $joinRec.status + " (cloud=" + $joinRec.cloud + ")")
          }



          $state.skipped++



          $state.fails = 0



        } else {



          $state.failed++



          $state.fails++



        }



        $errDetail = ""; try { $errDetail = [string]$r.error } catch { }; Write-Host ("[hub] join " + $tgt.title + " => " + $v + $(if ($v -eq "err" -or $v -like "err:*") { " [" + $errDetail + "]" } else { "" }))



  if ($v -eq "joined") { Reset-FsCacheSafe }



        $nm = if ($tgt) { $tgt.title } else { "?" }



        Add-Event ($nm + " → " + $v)



        if ($state.fails -ge $maxFails) {



          $state.phase = "done"



          $state.running = $false



          Write-Host "[hub] 连续失败达上限，本轮停止"



        }



        $state.nextAt = (Get-Date).AddSeconds((Rand-Int $gapMin $gapMax))



      }







      Send-Json $ctx 200 @{ ok = $true }



      continue



    }







    if ($path -eq "/log" -and $req.HttpMethod -eq "POST") {



      $raw = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()



      Write-Host ("[ext] " + $raw)



      Send-Json $ctx 200 @{ ok = $true }



      continue



    }







    if ($path -eq "/api/entities" -and $req.HttpMethod -eq "GET") {



      $q = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)



      $type = $(if ($q['type']) { [string]$q['type'] } else { 'group' })



      $lim = [int]$(if ($q['limit']) { $q['limit'] } else { '20' })



      $out = Invoke-DbTool -Args @('entities', $type, '--limit', "$lim")



      Send-Json $ctx 200 ($out | ConvertFrom-Json)



      continue



    }







    if ($path -eq "/api/recommendations" -and $req.HttpMethod -eq "GET") {



      $q = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)



      $st = $(if ($q['status']) { [string]$q['status'] } else { 'pending' })



      $lim = [int]$(if ($q['limit']) { $q['limit'] } else { '50' })



      $out = Invoke-DbTool -Args @('recommend-list', '--status', $st, '--limit', "$lim")



      Send-Json $ctx 200 ($out | ConvertFrom-Json)



      continue



    }







    if ($path -eq "/api/recommendations/decide" -and $req.HttpMethod -eq "POST") {



      $body = $null



      try { $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json } catch { }



      if (-not $body -or -not $body.dedupe_key) { Send-Json $ctx 400 @{ ok = $false; error = 'dedupe_key_required' }; continue }



      $act = [string]$body.action



      $map = @{ accept = 'accepted'; ignore = 'ignored'; expire = 'expired' }



      if (-not $map.ContainsKey($act)) { Send-Json $ctx 400 @{ ok = $false; error = 'action_invalid' }; continue }



      $tmp = Join-Path $here ("data\_decide_" + [guid]::NewGuid().ToString('N') + ".json")



      $payload = @{ dedupe_key = [string]$body.dedupe_key; status = [string]$map[$act]; reason = [string]$body.note } | ConvertTo-Json -Depth 4 -Compress



      [System.IO.File]::WriteAllText($tmp, $payload, (New-Object System.Text.UTF8Encoding($false)))



      try { $out = Invoke-DbTool -Args @('decide', $tmp) } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }



      Send-Json $ctx 200 ($out | ConvertFrom-Json)



      continue



    }







    if ($path -eq "/api/score/run" -and $req.HttpMethod -eq "POST") {



      $sc = Invoke-DbTool -Args @('score')



      $rc = Invoke-DbTool -Args @('recommend', '--limit', '80')



      Send-Json $ctx 200 @{ ok = $true; score = ($sc | ConvertFrom-Json); recommend = ($rc | ConvertFrom-Json) }



      continue



    }







    if ($path -eq "/entities" -and $req.HttpMethod -eq "GET") {



      $ef = Join-Path $here "entities.html"



      if (Test-Path $ef) {



        $bytes = [System.IO.File]::ReadAllBytes($ef)



        $ctx.Response.StatusCode = 200



        $ctx.Response.ContentType = "text/html; charset=utf-8"



        $ctx.Response.ContentLength64 = $bytes.Length



        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)



        $ctx.Response.OutputStream.Close()



      } else { Send-Json $ctx 404 @{ error = "entities.html missing" } }



      continue



    }







    Send-Json $ctx 404 @{ ok = $false }



  } catch {



    Write-Warning ("[hub] " + $_.Exception.Message)



    try { $ctx.Response.Close() } catch {}



  }



}


