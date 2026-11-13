# hub.ps1 —— 本地调度中心：给 Chrome 扩展派任务、收结果、写飞书
# 启动： pwsh -File hub.ps1
# 监听： http://127.0.0.1:8787

param([int]$Port = 8787, [int]$QuotaOverride = 0, [string]$Platform = "Telegram")

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib\feishu.ps1")
. (Join-Path $here "lib\db.ps1")
. (Join-Path $here "lib\stop.ps1")

$cfgPath = Join-Path $here "config.json"
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
  skipped    = 0
  failed     = 0
  pending    = $null        # 已派出未回的任务
  started    = $null
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

function Save-CandidatePool($pf) {
  try {
    $items = @()
    foreach ($k in $state.candidates.Keys) { $items += $state.candidates[$k] }
    $dir = Join-Path $PSScriptRoot "data"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $obj = @{ savedAt = (Get-Date).ToString("s"); platform = [string]$pf; count = $items.Count; items = $items }
    [System.IO.File]::WriteAllText((Get-PoolPath $pf), ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    return $items.Count
  } catch { return 0 }
}

function Load-CandidatePool($pf, $maxAgeHours) {
  $path = Get-PoolPath $pf
  if (-not (Test-Path $path)) { return @() }
  try {
    $o = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $t0 = [DateTime]::Parse([string]$o.savedAt)
    if (((Get-Date) - $t0).TotalHours -gt $maxAgeHours) { return @() }
    return @($o.items)
  } catch { return @() }
}

function Start-Run {
  $state.phase = "probe"
  $state.running = $true
  $state.self = ""
  $state.candidates = @{}
  $state.queue = New-Object System.Collections.Queue
  $state.queries = New-Object System.Collections.Queue
  $state.fails = 0
  $state.relaxed = $false
  $state.minNow = $minMembers
$state.extHits = 0
$state.extAt = ""
  $state.joined = 0; $state.skipped = 0; $state.failed = 0
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
    $state.candidates[$uk] = @{ id = $uk; u = [string]$it.u; title = [string]$it.title; n = [int]$it.n; q = [string]$it.q; src = "pool" }
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
  $list = @()
  foreach ($k in $state.candidates.Keys) { $list += $state.candidates[$k] }
  $list = $list | Sort-Object { -[int]$_.n }
  # 二重保险：候选池/搜索结果里若含跳过名单内的群，这里再剔一次
  $list = @($list | Where-Object {
    $uk2 = ("@" + ([string]$_.u).TrimStart("@")).ToLower()
    -not ($_.u -and $state.skipSet -and $state.skipSet.ContainsKey($uk2))
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

function Write-JoinRecord($target, $result) {
  $now = Now-Unix
  $due = $dayStart + 3 * 86400000
  $f = @{}
  $key = if ($target.u) { "TG-" + $target.u } else { "TG-" + $target.id }
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
  $wFeishu = $false
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
        Update-FsRecords -Updates @(@{ record_id = $script:FsKeyMap[$fkey]; fields = $f }) | Out-Null
      } else {
        Add-FsRecords -FieldSets @($f) | Out-Null
        if ($fkey) { $script:FsKeyMap[$fkey] = "pending" }
      }
      $wFeishu = $true
    }
    catch { Write-Warning ("写飞书失败：" + $_.Exception.Message) }
  }
  $wLocal = $false
  try { $wLocal = Write-LocalArchive -Fields $f } catch { Write-Warning ("写本地失败：" + $_.Exception.Message) }
  return ($wFeishu -or $wLocal)
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
function Get-Summary {
  $recs = @(Get-FsRecords)
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
  return @{
    totals   = @{ groups = $tg; members = $tm; todayGroups = $td; todayMembers = $tdm }
    platforms = @($pf | Sort-Object -Property members -Descending)
    series   = $sorted
    todos    = @($todo | Select-Object -First 8)
    todoCount = $todo.Count
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
      Send-Json $ctx 200 @{ ok = $true; phase = $state.phase; running = $state.running }
      continue
    }

    if ($path -eq "/api/live") {
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
        joined = $state.joined; skipped = $state.skipped; failed = $state.failed;
        queue = $(if ($state.queue) { $state.queue.Count } else { 0 });
        candidates = $(if ($state.candidates) { $state.candidates.Count } else { 0 });
        current = [string]$state.current;
        task = [string]$state.phase;
        events = $ev
      }
      continue
    }

    if ($path -eq "/state") {
      Send-Json $ctx 200 @{ phase = $state.phase; running = $state.running; joined = $state.joined;
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
      Send-Json $ctx 200 @{ outputs = $cfg.outputs; schedule = $cfg.schedule; quotas = $cfg.quotas; platforms = $cfg.platforms; platformsEnabled = $cfg.platformsEnabled; behaviors = $cfg.behaviors; reserved = $cfg.reserved; notify = $cfg.notify; taskName = "DSH_SocialOps_Daily"; tasks = (Get-Tasks) }
      continue
    }

    if ($path -eq "/api/config" -and $req.HttpMethod -eq "POST") {
      $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
      if ($body.outputs) {
        foreach ($k in @("feishu","sqlite","csv","jsonl")) {
          if ($body.outputs.PSObject.Properties.Name -contains $k) { $cfg.outputs.$k = [bool]$body.outputs.$k }
        }
      }
      if ($body.schedule) {
        if ($body.schedule.PSObject.Properties.Name -contains "enabled") { $cfg.schedule.enabled = [bool]$body.schedule.enabled }
        if ($body.schedule.time) { $cfg.schedule.time = [string]$body.schedule.time }
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
      if ($body.action -eq "pipeline") {
  try { Clear-GOpsStop $baseDir } catch {}
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
  try { Clear-GOpsStop $baseDir } catch {}
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
        Write-Host (Start-Run)
      }
      elseif ($body.action -eq "stop") { $state.running = $false; $state.phase = "idle"; try { Set-GOpsStop $baseDir ("hub stop " + (Get-Date).ToString("HH:mm:ss")) | Out-Null } catch {}; Write-Host "[hub] stopped" }
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
        $state.minNow = [Math]::Max(50, [int][Math]::Floor($minMembers / 3))
        foreach ($q in @(Get-Keywords $Platform)) { $state.queries.Enqueue($q) }
        Write-Host ("[hub] 候选不足，放宽到 " + $state.minNow + " 人重跑一轮")
        Send-Json $ctx 204 $null; continue
      }
      if ($state.relaxed -and -not $state.relaxed2 -and $state.candidates.Count -lt $need -and [int]$state.minNow -gt 50) {
        $state.relaxed2 = $true
        $state.minNow = 50
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
        $state.pending = @{ kind = "search"; id = $id; query = $q }
        $state.current = "搜索：" + $q
        Send-Json $ctx 200 @{ action = "search"; platform = $Platform; id = $id; query = $q; limit = 30 }
        Start-Sleep -Milliseconds (Rand-Int 3 8 * 100)
        continue
      }
      if ($state.phase -eq "join") {
        if ($state.queue.Count -eq 0) { $state.phase = "done"; $state.running = $false; Add-Event ("本轮结束 · 加入 " + $state.joined + " / 跳过 " + $state.skipped + " / 失败 " + $state.failed); Send-Json $ctx 204 $null; continue }
        $c = $state.queue.Dequeue()
        $id = Next-TaskId
        $state.pending = @{ kind = "join"; id = $id }
        Send-Json $ctx 200 @{ action = "join"; platform = $Platform; id = $id; u = $c.u; chatId = $c.id;
                              title = $c.title; n = $c.n; self = $state.self; q = $c.q }
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
        $state.phase = "search"
        Write-Host ("[hub] probe ok self=" + $state.self)
      }
      elseif ($kind -eq "search") {
        $q = $state.pending.query
        $cnt = 0
        foreach ($c in @($r.value)) {
          if (-not $c) { continue }
          if ($c.bc) { continue }
          if ([int]$c.n -lt $state.minNow) { continue }
          $id = [string]$c.id
          if ($seen.ContainsKey($id)) { continue }
          if ($c.u -and $seen.ContainsKey(([string]$c.u).ToLower())) { continue }
          $t = ([string]$c.title).Trim().ToLower()
          if ($seenTitles.ContainsKey($t)) { continue }
          if ($c.title -match $exclude) { continue }
          if ($c.priv) { continue }
          if ($Platform -eq 'Facebook') {
            $tn = [string]$c.title
            if ($tn -notmatch '(?i)(cs2|csgo|cs:go|counter[\s\-]?strike|skinvs|dmarket|buff163|skinport|csgoroll|csgoempire|skins? (trade|market|sell|buy)|vaka|swap\.gg)') { continue }
          }
          if ($state.candidates.ContainsKey($id)) { continue }
          $uk = ("@" + ([string]$c.u)).ToLower()
          if ($c.u -and $state.skipSet -and $state.skipSet.ContainsKey($uk)) { continue }
          $state.candidates[$id] = @{ id = $id; u = [string]$c.u; title = [string]$c.title; n = [int]$c.n; q = $q }
          $cnt++
        }
        Write-Host ("[hub] search '$q' 新增候选 $cnt")
        Add-Event ("搜索 " + $q + " → 新增 " + $cnt + " 个候选")
      }
      elseif ($kind -eq "join") {
        $v = [string]$r.value
        $tgt = $r.target
        if ($v -eq "joined" -or $v -eq "already") {
          if ($tgt) { Write-JoinRecord $tgt $v | Out-Null }
          $state.joined++
          $state.fails = 0
        } elseif ($v -eq "request_sent" -or $v -eq "not_found" -or $v -eq "approval") {
          if ($v -eq "request_sent" -and $tgt) { Write-JoinRecord $tgt $v | Out-Null }
          $state.skipped++
          $state.fails = 0
        } else {
          $state.failed++
          $state.fails++
        }
        Write-Host ("[hub] join " + $tgt.title + " => " + $v)
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

    Send-Json $ctx 404 @{ ok = $false }
  } catch {
    Write-Warning ("[hub] " + $_.Exception.Message)
    try { $ctx.Response.Close() } catch {}
  }
}
