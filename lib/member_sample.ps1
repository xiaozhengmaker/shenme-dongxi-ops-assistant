# member_sample.ps1 -- shared, testable member-sampling state and orchestration.
# No browser/CDP/network calls live here; platform wrappers inject FetchPage/StorePage.
# One target per run. Resume is by the target's persisted cursor, not by a page cap.

function Get-MemberSlug([string]$Platform) {
  $p = ([string]$Platform).Trim().ToLowerInvariant()
  if ($p -eq "steam") { return "steam" }
  if ($p -eq "telegram" -or $p -eq "tg") { return "telegram" }
  return ""
}

function Get-MemberLabel([string]$Platform) {
  $s = Get-MemberSlug $Platform
  if ($s -eq "steam") { return "Steam" }
  if ($s -eq "telegram") { return "Telegram" }
  return ""
}

function Get-MemberDir([string]$BaseDir) {
  $d = Join-Path $BaseDir "data\members"
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

function Get-MemberStatePath([string]$BaseDir, [string]$Platform) {
  return (Join-Path (Get-MemberDir $BaseDir) ((Get-MemberSlug $Platform) + ".json"))
}
function Get-MemberLockPath([string]$BaseDir, [string]$Platform) {
  return (Join-Path (Get-MemberDir $BaseDir) ((Get-MemberSlug $Platform) + ".lock"))
}
function Get-MemberStopPath([string]$BaseDir, [string]$Platform) {
  return (Join-Path (Get-MemberDir $BaseDir) ((Get-MemberSlug $Platform) + ".stop"))
}
function Get-MemberLogPath([string]$BaseDir, [string]$Platform) {
  return (Join-Path (Get-MemberDir $BaseDir) ((Get-MemberSlug $Platform) + ".log"))
}

function Read-MemberState([string]$BaseDir, [string]$Platform) {
  $p = Get-MemberStatePath $BaseDir $Platform
  $def = [pscustomobject]@{
    version = 1
    platform = (Get-MemberLabel $Platform)
    updated_at = ""
    run = $null
    targets = [pscustomobject]@{}
    last = $null
  }
  if (-not (Test-Path $p)) { return $def }
  try {
    $o = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $o) { return $def }
    if (-not $o.targets) { $o | Add-Member -NotePropertyName targets -NotePropertyValue ([pscustomobject]@{}) -Force }
    return $o
  } catch { return $def }
}

function Write-MemberState([string]$BaseDir, [string]$Platform, $State) {
  $p = Get-MemberStatePath $BaseDir $Platform
  $dir = Split-Path -Parent $p
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $State.updated_at = (Get-Date).ToString("o")
  $json = $State | ConvertTo-Json -Depth 10
  $tmp = $p + ".tmp." + [guid]::NewGuid().ToString("N")
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $p -Force
}

function Get-MemberStateEntry($State, [string]$Key) {
  if (-not $State.targets) { return $null }
  $prop = $State.targets.PSObject.Properties[$Key]
  if ($prop) { return $prop.Value }
  return $null
}

function Set-MemberStateEntry($State, [string]$Key, $Entry) {
  $State.targets | Add-Member -NotePropertyName $Key -NotePropertyValue $Entry -Force
}

function New-MemberEntry([string]$Key, [string]$Name) {
  return [pscustomobject]@{
    key = $Key
    name = $Name
    status = "pending"
    next = 0
    total = 0
    collected = 0
    duplicates = 0
    pages = 0
    last_success = ""
    last_error = ""
    stop_reason = ""
    cooldown_until = ""
    updated_at = ""
  }
}

function Add-MemberLog([string]$BaseDir, [string]$Platform, [string]$Message) {
  try {
    $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] " + $Message + [Environment]::NewLine
    [System.IO.File]::AppendAllText((Get-MemberLogPath $BaseDir $Platform), $line, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Get-MemberRateWaitSec([string]$Text) {
  if (-not $Text) { return 0 }
  $m = [regex]::Match([string]$Text, "FLOOD_WAIT_(\d+)", "IgnoreCase")
  if ($m.Success) { return [int]$m.Groups[1].Value }
  $m = [regex]::Match([string]$Text, "retry[- ]after[: ]+(\d+)", "IgnoreCase")
  if ($m.Success) { return [int]$m.Groups[1].Value }
  if ($Text -match "\b429\b") { return 300 }
  return 0
}

function Get-MemberCatalog([string]$BaseDir, [string]$Platform) {
  $slug = Get-MemberSlug $Platform
  $map = [ordered]@{}
  if ($slug -eq "steam") {
    $joins = Join-Path $BaseDir "data\steam_joins.csv"
    if (Test-Path $joins) {
      try {
        foreach ($r in (Import-Csv -LiteralPath $joins -Encoding UTF8)) {
          $key = [string]$r.'群ID'
          if (-not $key) { continue }
          $name = [string]$r.'群名'
          if (-not $map.Contains($key)) { $map[$key] = [pscustomobject]@{ key = $key; name = $(if ($name) { $name } else { $key }); total = 0 } }
        }
      } catch { }
    }
    $meta = Join-Path $BaseDir "data\steam_meta.json"
    if (Test-Path $meta) {
      try {
        $o = [System.IO.File]::ReadAllText($meta, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) {
          $key = [string]$p.Name
          if (-not $key) { continue }
          $total = 0
          try { $total = [int]$p.Value.total * 1000 } catch { }
          if (-not $map.Contains($key)) { $map[$key] = [pscustomobject]@{ key = $key; name = $key; total = $total } }
          else { try { $map[$key].total = $total } catch { } }
        }
      } catch { }
    }
  } elseif ($slug -eq "telegram") {
    $cursor = Join-Path $BaseDir "data\cursor_tg.json"
    if (Test-Path $cursor) {
      try {
        $o = [System.IO.File]::ReadAllText($cursor, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) {
          $key = [string]$p.Name
          if (-not $key -or $key -eq "key") { continue }
          if ($key -notmatch '^@[A-Za-z0-9_]{3,64}$') { continue }
          if ($p.Value -isnot [pscustomobject]) { continue }
          if (-not $map.Contains($key)) { $map[$key] = [pscustomobject]@{ key = $key; name = $key; total = 0 } }
        }
      } catch { }
    }
  }
  return @($map.Values)
}

function Resolve-MemberTarget([string]$Platform, [string]$Target) {
  $t = ([string]$Target).Trim()
  if (-not $t) { return "" }
  if ((Get-MemberSlug $Platform) -eq "telegram" -and $t.StartsWith("@")) { return $t.ToLowerInvariant() }
  return $t
}

function Select-MemberTargets($State, [object[]]$Catalog, [string]$Platform, [string]$Target, [switch]$Trial) {
  $want = Resolve-MemberTarget $Platform $Target
  $all = @()
  foreach ($g in @($Catalog)) {
    if (-not $g) { continue }
    $key = [string]$g.key
    if (-not $key) { continue }
    $entry = Get-MemberStateEntry $State $key
    $status = if ($entry) { [string]$entry.status } else { "pending" }
    $next = if ($entry) { [int]$entry.next } else { 0 }
    $collected = if ($entry) { [int]$entry.collected } else { 0 }
    $total = if ($entry -and [int]$entry.total -gt 0) { [int]$entry.total } elseif ([int]$g.total -gt 0) { [int]$g.total } else { 0 }
    $all += [pscustomobject]@{
      key = $key; name = $(if ($g.name) { [string]$g.name } else { $key }); status = $status
      next = $next; collected = $collected; total = $total
    }
  }
  if ($want) {
    $hit = @($all | Where-Object { $_.key -eq $want })
    if (-not $hit.Count) { $hit = @([pscustomobject]@{ key = $want; name = $want; status = "pending"; next = 0; collected = 0; total = 0 }) }
    return @($hit | Select-Object -First 1)
  }
  $cand = @($all | Where-Object {
    $_.status -ne "done" -and $_.status -ne "permission_denied"
  })
  if (-not $cand.Count) { return @() }
  $ranked = @($cand | Sort-Object @{ Expression = {
    if ($_.status -eq "interrupted") { 0 }
    elseif ($_.status -eq "failed") { 1 }
    elseif ($_.next -eq 0) { 2 }
    else { 3 }
  } }, @{ Expression = { $_.key } })
  return @($ranked | Select-Object -First 1)
}

function Get-MemberCooldownUntil($Entry) {
  if (-not $Entry) { return [datetime]::MinValue }
  $raw = [string]$Entry.cooldown_until
  if (-not $raw) { return [datetime]::MinValue }
  try { return [datetime]::Parse($raw) } catch { return [datetime]::MinValue }
}

function Test-MemberStopRequested([string]$BaseDir, [string]$Platform) {
  if (Test-Path (Join-Path $BaseDir "data\stop.flag")) { return $true }
  return (Test-Path (Get-MemberStopPath $BaseDir $Platform))
}

function Get-MemberLockInfo([string]$BaseDir, [string]$Platform) {
  $p = Get-MemberLockPath $BaseDir $Platform
  if (-not (Test-Path $p)) { return $null }
  try {
    $o = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    return $o
  } catch { return [pscustomobject]@{ pid = 0; run_id = ""; stale = $true } }
}

function Test-MemberLockActive([string]$BaseDir, [string]$Platform) {
  $o = Get-MemberLockInfo $BaseDir $Platform
  if (-not $o) { return $false }
  $procId = 0
  try { $procId = [int]$o.pid } catch { }
  if ($procId -le 0) { return $false }
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  return [bool]$p
}

function Set-MemberLock([string]$BaseDir, [string]$Platform, [string]$RunId) {
  $p = Get-MemberLockPath $BaseDir $Platform
  if (Test-Path $p) {
    if (Test-MemberLockActive $BaseDir $Platform) { return @{ ok = $false; error = "busy"; path = $p } }
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  }
  try {
    $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $obj = @{ pid = $PID; run_id = $RunId; started_at = (Get-Date).ToString("o") } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($obj)
    $fs.Write($bytes, 0, $bytes.Length)
    $fs.Dispose()
    return @{ ok = $true; path = $p }
  } catch {
    return @{ ok = $false; error = "busy"; path = $p }
  }
}

function Clear-MemberLock([string]$BaseDir, [string]$Platform, [string]$RunId) {
  $o = Get-MemberLockInfo $BaseDir $Platform
  if (-not $o) { return }
  if ($RunId -and [string]$o.run_id -ne $RunId) { return }
  Remove-Item -LiteralPath (Get-MemberLockPath $BaseDir $Platform) -Force -ErrorAction SilentlyContinue
}

function Get-MemberSummary([string]$BaseDir, [string]$Platform) {
  $state = Read-MemberState $BaseDir $Platform
  $last = $state.last
  $running = Test-MemberLockActive $BaseDir $Platform
  $status = if ($running) { "running" } elseif ($last) { if ([string]$last.status -eq "running") { "interrupted" } else { [string]$last.status } } else { "idle" }
  $target = ""
  $targetName = ""
  $coverage = 0
  $new = 0; $duplicates = 0
  if ($last) {
    $target = [string]$last.target
    $targetName = [string]$last.target_name
    $new = [int]$last.new
    $duplicates = [int]$last.duplicates
    try { $coverage = [int]$last.coverage } catch { }
  }
  return [pscustomobject]@{
    platform = (Get-MemberLabel $Platform)
    running = $running
    status = $status
    target = $target
    target_name = $targetName
    coverage = $coverage
    new = $new
    duplicates = $duplicates
    last_success = $(if ($last) { [string]$last.last_success } else { "" })
    stop_reason = $(if ($last) { [string]$last.stop_reason } else { "" })
    cooldown_until = $(if ($last) { [string]$last.cooldown_until } else { "" })
    updated_at = $(if ($last) { [string]$last.updated_at } else { "" })
  }
}

function Get-MemberOverview([string]$BaseDir) {
  $plats = @()
  foreach ($pf in @("Steam", "Telegram")) {
    $state = Read-MemberState $BaseDir $pf
    $cat = Get-MemberCatalog $BaseDir $pf
    $opts = @()
    foreach ($g in @($cat)) {
      $e = Get-MemberStateEntry $state ([string]$g.key)
      $status = if ($e) { [string]$e.status } else { "pending" }
      $collected = if ($e) { [int]$e.collected } else { 0 }
      $total = if ($e -and [int]$e.total -gt 0) { [int]$e.total } elseif ([int]$g.total -gt 0) { [int]$g.total } else { 0 }
      $cov = if ($total -gt 0) { [math]::Min(100, [math]::Round(($collected * 100.0) / $total, 1)) } else { 0 }
      $opts += [pscustomobject]@{ key = [string]$g.key; name = [string]$g.name; status = $status; next = $(if ($e) { [int]$e.next } else { 0 }); collected = $collected; total = $total; coverage = $cov }
    }
    $plats += [pscustomobject]@{
      platform = (Get-MemberLabel $pf)
      state = (Get-MemberSummary $BaseDir $pf)
      options = @($opts | Sort-Object @{ Expression = { if ($_.status -eq "interrupted") { 0 } elseif ($_.status -eq "pending") { 1 } elseif ($_.status -eq "done") { 3 } else { 2 } } }, @{ Expression = { $_.key } })
    }
  }
  return [pscustomobject]@{ ok = $true; checked_at = (Get-Date).ToString("o"); platforms = @($plats) }
}

function Start-MemberSampleProcess([string]$BaseDir, [string]$Platform, [string]$Target, [switch]$Trial) {
  $slug = Get-MemberSlug $Platform
  if (-not $slug) { return @{ ok = $false; error = "bad_platform" } }
  if (Test-Path (Join-Path $BaseDir "data\stop.flag")) { return @{ ok = $false; error = "stopped" } }
  if (Test-MemberLockActive $BaseDir $slug) { return @{ ok = $false; error = "member_running" } }
  $t = Resolve-MemberTarget $slug $Target
  if ($t -and $t -notmatch '^@?[A-Za-z0-9_.-]{1,64}$') { return @{ ok = $false; error = "bad_target" } }
  $state = Read-MemberState $BaseDir $slug
  $catalog = Get-MemberCatalog $BaseDir $Platform
  $sel = @(Select-MemberTargets -State $state -Catalog $catalog -Platform $slug -Target $t -Trial:$Trial)
  if ($sel.Count -gt 0) {
    $pick = $sel[0]
    $entry = Get-MemberStateEntry $state ([string]$pick.key)
    $coolUntil = Get-MemberCooldownUntil $entry
    if ($coolUntil -gt (Get-Date)) {
      return @{ ok = $false; error = "cooldown"; target = [string]$pick.key; cooldown_until = $coolUntil.ToString("o") }
    }
  }
  $script = if ($slug -eq "steam") { Join-Path $BaseDir "sample_steam.ps1" } else { Join-Path $BaseDir "sample_telegram.ps1" }
  if (-not (Test-Path $script)) { return @{ ok = $false; error = "sampler_missing" } }
  $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $script + "`""))
  if ($t) { $argList += @("-Target", ("`"" + $t + "`"")) }
  if ($Trial) { $argList += "-Trial" }
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden | Out-Null
    return @{ ok = $true; platform = (Get-MemberLabel $slug); target = $t }
  } catch {
    return @{ ok = $false; error = "spawn_failed"; detail = $_.Exception.Message }
  }
}

function Request-MemberStop([string]$BaseDir, [string]$Platform) {
  $slug = Get-MemberSlug $Platform
  if (-not $slug) { return @{ ok = $false; error = "bad_platform" } }
  $p = Get-MemberStopPath $BaseDir $slug
  try {
    [System.IO.File]::WriteAllText($p, (Get-Date).ToString("o"), (New-Object System.Text.UTF8Encoding($false)))
    return @{ ok = $true }
  } catch { return @{ ok = $false; error = "stop_write_failed" } }
}

function Clear-MemberStop([string]$BaseDir, [string]$Platform) {
  $p = Get-MemberStopPath $BaseDir $Platform
  if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

function Invoke-MemberSampleRun {
  param(
    [string]$BaseDir,
    [string]$Platform,
    [string]$Target = "",
    [int]$MaxRuntimeMin = 30,
    [switch]$Trial,
    [object[]]$Catalog = $null,
    [scriptblock]$FetchPage = $null,
    [scriptblock]$StorePage = $null,
    [scriptblock]$Delay = $null,
    [scriptblock]$StopCheck = $null,
    [scriptblock]$Log = $null
  )
  $slug = Get-MemberSlug $Platform
  if (-not $slug) { return @{ ok = $false; status = "failed"; error = "bad_platform" } }
  if (-not $FetchPage -or -not $StorePage) { return @{ ok = $false; status = "failed"; error = "missing_dependency" } }
  if ($MaxRuntimeMin -lt 1) { $MaxRuntimeMin = 30 }
  $state = Read-MemberState $BaseDir $slug
  if ($null -eq $Catalog) { $Catalog = Get-MemberCatalog $BaseDir $platform }
  $sel = @(Select-MemberTargets -State $state -Catalog $Catalog -Platform $slug -Target $Target -Trial:$Trial)
  if (-not $sel.Count) {
    $state.last = [pscustomobject]@{ status = "no_target"; target = ""; target_name = ""; stop_reason = "no_target"; updated_at = (Get-Date).ToString("o"); coverage = 0; new = 0; duplicates = 0; last_success = "" }
    Write-MemberState $BaseDir $slug $state
    return @{ ok = $false; status = "no_target"; error = "no_target" }
  }
  $pick = $sel[0]
  $entry = Get-MemberStateEntry $state ([string]$pick.key)
  if (-not $entry) { $entry = New-MemberEntry ([string]$pick.key) ([string]$pick.name); Set-MemberStateEntry $state ([string]$pick.key) $entry }
  if ($entry.status -eq "done") {
    return @{ ok = $true; status = "done"; target = [string]$pick.key; error = ""; summary = (Get-MemberSummary $BaseDir $slug) }
  }
  $coolUntil = Get-MemberCooldownUntil $entry
  if ($coolUntil -gt (Get-Date)) {
    return @{ ok = $false; status = "cooldown"; target = [string]$pick.key; error = "cooldown"; cooldown_until = $coolUntil.ToString("o"); summary = (Get-MemberSummary $BaseDir $slug) }
  }
  if ($entry.cooldown_until) { $entry.cooldown_until = "" }
  $runId = "member-" + (Get-Date -Format "yyyyMMddHHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)
  $lock = Set-MemberLock $BaseDir $slug $runId
  if (-not $lock.ok) { return @{ ok = $false; status = "busy"; error = "busy" } }
  $started = Get-Date
  $status = "interrupted"
  $reason = "interrupted"
  $totalNew = 0; $totalDup = 0
  try {
    $state.run = [pscustomobject]@{ id = $runId; platform = (Get-MemberLabel $slug); target = [string]$pick.key; trial = [bool]$Trial; status = "running"; started_at = $started.ToString("o"); updated_at = "" }
    $entry.status = "running"
    $entry.stop_reason = ""
    $entry.updated_at = $started.ToString("o")
    Write-MemberState $BaseDir $slug $state
    $stop = if ($StopCheck) { $StopCheck } else { { param($b, $p) Test-MemberStopRequested $b $p } }
    $cursor = [int]$entry.next
    while ($true) {
      if (& $stop $BaseDir $slug) { $status = "stopped"; $reason = "stop_requested"; break }
      if (((Get-Date) - $started).TotalMinutes -ge $MaxRuntimeMin) { $status = "interrupted"; $reason = "time_limit"; break }
      $page = & $FetchPage $entry $cursor
      if (-not $page) { $status = "failed"; $reason = "empty_page"; break }
      if ($page.permissionDenied) { $status = "permission_denied"; $reason = $(if ($page.error) { [string]$page.error } else { "permission_denied" }); break }
      $wait = 0
      try { $wait = [int]$page.rateWaitSec } catch { }
      if ($wait -gt 0) {
        $status = "rate_limited"; $reason = "rate_limited"
        $entry.cooldown_until = (Get-Date).AddSeconds($wait).ToString("o")
        break
      }
      if ($page.error) { $status = "failed"; $reason = [string]$page.error; break }
      $items = @($page.items)
      if ($page.total) { try { $entry.total = [int]$page.total } catch { } }
      if ($page.groupName) { $entry.name = [string]$page.groupName }
      if ($items.Count -gt 0) {
        $stored = & $StorePage $entry $items
        $add = 0; $dup = 0
        if ($stored) { try { $add = [int]$stored.added } catch { }; try { $dup = [int]$stored.duplicates } catch { } }
        $entry.collected = [int]$entry.collected + $add
        $entry.duplicates = [int]$entry.duplicates + $dup
        $totalNew += $add; $totalDup += $dup
      }
      $entry.pages = [int]$entry.pages + 1
      $next = 0
      try { $next = [int]$page.next } catch { }
      if ($next -le $cursor -and -not $page.done) { $status = "failed"; $reason = "cursor_stalled"; break }
      $entry.next = $next
      $entry.last_success = (Get-Date).ToString("o")
      $entry.updated_at = $entry.last_success
      $entry.status = "running"
      Write-MemberState $BaseDir $slug $state
      if ($Log) { & $Log ("page=" + [string]$entry.pages + " next=" + [string]$entry.next + " added=" + [string]$totalNew + " duplicates=" + [string]$totalDup) }
      if ($page.done -or $items.Count -eq 0) { $status = "done"; $reason = "end_of_list"; break }
      $cursor = $next
      if ($Delay) { & $Delay }
    }
  } catch {
    $status = "failed"; $reason = "exception"
    try { $entry.last_error = [string]$_.Exception.Message } catch { }
  } finally {
    $entry.status = $status
    $entry.stop_reason = $reason
    $entry.updated_at = (Get-Date).ToString("o")
    $cov = 0
    try { if ([int]$entry.total -gt 0) { $cov = [math]::Min(100, [math]::Round(([int]$entry.collected * 100.0) / [int]$entry.total, 1)) } } catch { }
    $state.last = [pscustomobject]@{
      status = $status; target = [string]$pick.key; target_name = [string]$entry.name
      coverage = $cov; new = $totalNew; duplicates = $totalDup
      last_success = [string]$entry.last_success; stop_reason = $reason
      updated_at = (Get-Date).ToString("o")
    }
    $state.run.status = $status
    $state.run.updated_at = $state.last.updated_at
    Save-MemberStateSafe $BaseDir $slug $state
    Clear-MemberLock $BaseDir $slug $runId
  }
  $code = if ($status -eq "done") { 0 } elseif ($status -eq "stopped") { 3 } elseif ($status -eq "rate_limited") { 4 } else { 5 }
  return @{ ok = ($status -eq "done"); status = $status; target = [string]$pick.key; error = $(if ($status -eq "done") { "" } else { $reason }); code = $code; summary = (Get-MemberSummary $BaseDir $slug) }
}

function Save-MemberStateSafe([string]$BaseDir, [string]$Platform, $State) {
  try { Write-MemberState $BaseDir $Platform $State } catch { }
}
