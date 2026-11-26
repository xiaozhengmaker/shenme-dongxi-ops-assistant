# lib/kw_stats.ps1 -- 平台关键词淘汰状态机（v2）
# 规则：有效搜索连续 3 个不同轮零结果 -> 休眠 24h；恢复后再次 3 轮 -> 7 天。
# 错误/未知不计入 rounds，也不清零连续零结果；保护/手工淘汰不自动休眠。
# 数据：data/kw_stats.json；BaseDir 必须指向隔离副本，生产目录只读。
# 兼容旧 v1 结构（"Platform|keyword" 五字段），读取时在内存迁移，写入时落 v2。

$script:KwStatsVersion = 2
$script:KwRoundMemory = 24

function Get-KwStatsPath([string]$BaseDir) {
  return [IO.Path]::Combine($BaseDir, "data", "kw_stats.json")
}

function Get-KwTrendDirPath([string]$BaseDir) {
  return [IO.Path]::Combine($BaseDir, "data", "kw_trend")
}

function Get-KwNow($Now) {
  if ($null -eq $Now) { return (Get-Date) }
  return [datetime]$Now
}

function ConvertTo-KwDate($Value) {
  if ($null -eq $Value) { return $null }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  try {
    return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal)
  } catch { return $null }
}

function ConvertTo-KwText([string]$Value, [int]$Max = 128) {
  if ($null -eq $Value) { return "" }
  $s = ([string]$Value).Trim()
  $s = $s -replace "[\r\n\t]+", " "
  if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max) }
  return $s
}

function New-KwEntry([string]$Keyword) {
  return @{
    keyword                = (ConvertTo-KwText $Keyword 96)
    rounds                 = 0
    hits                   = 0
    misses                 = 0
    errors                 = 0
    consecutive_zero_rounds = 0
    sleep_level            = 0
    strikes                = 0
    sleep_until            = $null
    sleep_source           = ""
    manual_pruned          = $false
    protected              = $false
    weight                 = 1.0
    last                   = $null
    last_attempt           = $null
    last_result            = ""
    last_error             = ""
    last_rounds            = @()
    auto_slept_at          = $null
    recovered_at           = $null
    note                   = ""
  }
}

function ConvertTo-KwEntry($RawEntry, [string]$Keyword) {
  $e = New-KwEntry $Keyword
  if ($null -ne $RawEntry) {
    $props = @()
    try { $props = @($RawEntry.PSObject.Properties) } catch { $props = @() }
    foreach ($p in $props) {
      if ($null -eq $p) { continue }
      if ($p.Name -eq "keyword") { continue }
      $e[$p.Name] = $p.Value
    }
  }
  if (-not $e["keyword"]) { $e["keyword"] = (ConvertTo-KwText $Keyword 96) }
  $e["rounds"] = [int]($e["rounds"])
  $e["hits"] = [int]($e["hits"])
  $e["misses"] = [int]($e["misses"])
  $e["errors"] = [int]($e["errors"])
  $e["consecutive_zero_rounds"] = [int]($e["consecutive_zero_rounds"])
  $e["sleep_level"] = [int]($e["sleep_level"])
  $e["strikes"] = [int]($e["strikes"])
  $e["weight"] = [double]($e["weight"])
  if ($e["weight"] -le 0 -or $e["weight"] -gt 2) { $e["weight"] = 1.0 }
  if ($null -eq $e["last_rounds"]) { $e["last_rounds"] = @() } else { $e["last_rounds"] = @($e["last_rounds"]) }
  if ($e["manual_pruned"] -eq $null) { $e["manual_pruned"] = $false } else { $e["manual_pruned"] = [bool]$e["manual_pruned"] }
  if ($e["protected"] -eq $null) { $e["protected"] = $false } else { $e["protected"] = [bool]$e["protected"] }
  foreach ($k in @("last", "last_attempt", "sleep_until", "auto_slept_at", "recovered_at")) {
    if ($e[$k] -eq $null) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$e[$k])) { $e[$k] = $null }
  }
  return $e
}

function Read-KwStats([string]$BaseDir) {
  $state = @{ version = $script:KwStatsVersion; updated = $null; platforms = @{} }
  $path = Get-KwStatsPath $BaseDir
  if (-not (Test-Path -LiteralPath $path)) { return $state }
  $raw = $null
  try { $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $state }
  if ($null -eq $raw) { return $state }
  $names = @()
  try { $names = @($raw.PSObject.Properties.Name) } catch { $names = @() }

  if (($names -contains "version") -and [int]$raw.version -ge 2 -and ($names -contains "platforms") -and $raw.platforms) {
    $state["updated"] = [string]$raw.updated
    foreach ($pp in @($raw.platforms.PSObject.Properties)) {
      if ($null -eq $pp -or $null -eq $pp.Value) { continue }
      $bucket = @{ keywords = @{} }
      $kwNames = @()
      try { $kwNames = @($pp.Value.keywords.PSObject.Properties) } catch { $kwNames = @() }
      foreach ($kp in $kwNames) {
        if ($null -eq $kp) { continue }
        $kw = [string]$kp.Name
        $entry = ConvertTo-KwEntry $kp.Value $kw
        $key = ([string]$entry["keyword"]).Trim().ToLowerInvariant()
        if (-not $key) { continue }
        $bucket["keywords"][$key] = $entry
      }
      $state["platforms"][[string]$pp.Name] = $bucket
    }
    return $state
  }

  # v1: { "Telegram|cs2 trade": { rounds, hits, misses, last, off_until } }
  foreach ($p in @($raw.PSObject.Properties)) {
    if ($null -eq $p) { continue }
    if ($p.Name -eq "version" -or $p.Name -eq "updated" -or $p.Name -eq "platforms") { continue }
    $idx = $p.Name.IndexOf("|")
    if ($idx -lt 1) { continue }
    $plat = $p.Name.Substring(0, $idx).Trim()
    $kw = $p.Name.Substring($idx + 1).Trim()
    if (-not $plat -or -not $kw) { continue }
    if (-not $state["platforms"].ContainsKey($plat)) { $state["platforms"][$plat] = @{ keywords = @{} } }
    $e = New-KwEntry $kw
    if ($null -ne $p.Value) {
      try {
        $e["rounds"] = [int]$p.Value.rounds
        $e["hits"] = [int]$p.Value.hits
        $e["misses"] = [int]$p.Value.misses
        $e["last"] = if ($p.Value.last) { [string]$p.Value.last } else { $null }
        if ($p.Value.off_until) {
          $e["sleep_until"] = [string]$p.Value.off_until
          $e["sleep_source"] = "auto"
          $e["sleep_level"] = 1
          $e["auto_slept_at"] = [string]$p.Value.off_until
        }
      } catch { }
    }
    $e["consecutive_zero_rounds"] = [Math]::Min([int]$e["misses"], 3)
    $key = $kw.ToLowerInvariant()
    $state["platforms"][$plat]["keywords"][$key] = $e
  }
  return $state
}

function Save-KwStats([string]$BaseDir, $State) {
  $path = Get-KwStatsPath $BaseDir
  $dir = [IO.Path]::GetDirectoryName($path)
  if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
  $State["version"] = $script:KwStatsVersion
  $State["updated"] = (Get-Date).ToString("o")
  $json = $State | ConvertTo-Json -Depth 12
  $tmp = $path + ".tmp-" + [guid]::NewGuid().ToString("N")
  try {
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $true
  } catch {
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } } catch { }
    throw
  }
}

function Get-KwPolicy($Config) {
  $p = [ordered]@{
    enabled              = $true
    zero_rounds          = 3
    first_sleep_hours    = 24
    second_sleep_hours   = 168
    ai_enabled           = $true
    ai_window_days       = 14
    ai_max_suggestions   = 5
    ai_max_tokens        = 900
    ai_weekly_budget_cny = 1.0
    ai_price_in_per_m    = 2.0
    ai_price_out_per_m   = 8.0
  }
  $k = $null
  try { if ($Config -and $Config.kw_evolve) { $k = $Config.kw_evolve } } catch { }
  if ($k) {
    foreach ($name in @("zero_rounds", "first_sleep_hours", "second_sleep_hours", "ai_window_days", "ai_max_suggestions", "ai_max_tokens")) {
      try { if ($null -ne $k.$name) { $p[$name] = [int]$k.$name } } catch { }
    }
    foreach ($name in @("ai_weekly_budget_cny", "ai_price_in_per_m", "ai_price_out_per_m")) {
      try { if ($null -ne $k.$name) { $p[$name] = [double]$k.$name } } catch { }
    }
    try { if ($null -ne $k.enabled) { $p["enabled"] = [bool]$k.enabled } } catch { }
    try { if ($null -ne $k.ai_enabled) { $p["ai_enabled"] = [bool]$k.ai_enabled } } catch { }
  }
  if ($p["zero_rounds"] -lt 1) { $p["zero_rounds"] = 3 }
  if ($p["first_sleep_hours"] -lt 1) { $p["first_sleep_hours"] = 24 }
  if ($p["second_sleep_hours"] -lt 1) { $p["second_sleep_hours"] = 168 }
  if ($p["ai_max_suggestions"] -lt 1) { $p["ai_max_suggestions"] = 5 }
  if ($p["ai_max_suggestions"] -gt 5) { $p["ai_max_suggestions"] = 5 }
  if ($p["ai_max_tokens"] -lt 128) { $p["ai_max_tokens"] = 900 }
  if ($p["ai_max_tokens"] -gt 4000) { $p["ai_max_tokens"] = 4000 }
  if ($p["ai_window_days"] -lt 1) { $p["ai_window_days"] = 14 }
  if ($p["ai_window_days"] -gt 90) { $p["ai_window_days"] = 90 }
  if ($p["ai_weekly_budget_cny"] -lt 0) { $p["ai_weekly_budget_cny"] = 0 }
  return [pscustomobject]$p
}

function Get-KwAiSettings($Config) {
  $ai = $null
  try { if ($Config -and $Config.ai) { $ai = $Config.ai } } catch { }
  $key = ""
  $base = "https://api.deepseek.com"
  $model = "deepseek-chat"
  $timeout = 90
  if ($ai) {
    $key = [string]$ai.api_key
    if (-not $key) {
      $envName = [string]$ai.api_key_env
      if ($envName) { try { $key = [string](Get-Item ("env:" + $envName) -ErrorAction Stop).Value } catch { $key = "" } }
    }
    if ($ai.base_url) { $base = [string]$ai.base_url }
    if ($ai.model) { $model = [string]$ai.model }
    if ($ai.timeout_sec) { $timeout = [int]$ai.timeout_sec }
  }
  $masked = ""
  if ($key) {
    if ($key.Length -le 6) { $masked = "****" } else { $masked = $key.Substring(0, 4) + "****" + $key.Substring($key.Length - 2) }
  }
  return [pscustomobject]@{
    has_key  = [bool]$key
    api_key  = $key
    masked   = $masked
    base_url = $base.TrimEnd("/")
    model    = $model
    timeout  = $timeout
  }
}

function Get-KwPlatformBucket($State, [string]$Platform, [bool]$Create = $false) {
  if ($null -eq $State) { return $null }
  if ($null -eq $State["platforms"]) { $State["platforms"] = @{} }
  $platforms = $State["platforms"]
  if (-not $platforms.ContainsKey($Platform)) {
    if (-not $Create) { return $null }
    $platforms[$Platform] = @{ keywords = @{} }
  }
  $bucket = $platforms[$Platform]
  if ($null -eq $bucket) {
    if (-not $Create) { return $null }
    $bucket = @{ keywords = @{} }
    $platforms[$Platform] = $bucket
  }
  if ($null -eq $bucket["keywords"]) { $bucket["keywords"] = @{} }
  return $bucket
}

function Get-KwEntry($State, [string]$Platform, [string]$Keyword, [bool]$Create = $false) {
  $kw = ConvertTo-KwText $Keyword 96
  if (-not $kw) { return $null }
  $bucket = Get-KwPlatformBucket $State $Platform $Create
  if ($null -eq $bucket) { return $null }
  $key = $kw.ToLowerInvariant()
  if (-not $bucket["keywords"].ContainsKey($key)) {
    if (-not $Create) { return $null }
    $bucket["keywords"][$key] = New-KwEntry $kw
  }
  return $bucket["keywords"][$key]
}

function Get-KwEffectiveState($Entry, $Now = $null) {
  if ($null -eq $Entry) { return "missing" }
  if ([bool]$Entry["protected"]) { return "protected" }
  if ([bool]$Entry["manual_pruned"]) { return "manual" }
  $until = ConvertTo-KwDate $Entry["sleep_until"]
  if ($until -and $until -gt (Get-KwNow $Now)) { return "sleep" }
  return "active"
}

function Get-KwSleepRemainingHours($Entry, $Now = $null) {
  if ($null -eq $Entry) { return 0 }
  $until = ConvertTo-KwDate $Entry["sleep_until"]
  if (-not $until) { return 0 }
  $sec = ($until - (Get-KwNow $Now)).TotalSeconds
  if ($sec -le 0) { return 0 }
  return [Math]::Round($sec / 3600.0, 2)
}

function Test-KwStatOff($Entry, $Now = $null) {
  if ($null -eq $Entry) { return $false }
  return ((Get-KwEffectiveState $Entry $Now) -eq "sleep")
}

function Test-KwStatKnownGood([string]$BaseDir, [string]$Platform, [string]$Keyword) {
  $state = Read-KwStats $BaseDir
  $e = Get-KwEntry $state $Platform $Keyword $false
  if ($null -eq $e) { return $false }
  return ([int]$e["hits"] -gt 0)
}

function Get-KwRanked([string]$BaseDir, [string]$Platform, $Keywords, $Now = $null) {
  $state = Read-KwStats $BaseDir
  $seen = @{}
  $scored = @()
  foreach ($k in @($Keywords)) {
    $kw = ConvertTo-KwText ([string]$k) 96
    if (-not $kw) { continue }
    $key = $kw.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = 1
    $e = Get-KwEntry $state $Platform $kw $false
    if ($null -ne $e) {
      $effective = Get-KwEffectiveState $e $Now
      if ($effective -eq "sleep" -or $effective -eq "manual") { continue }
      $rounds = [int]$e["rounds"]
      $hits = [int]$e["hits"]
      $weight = [double]$e["weight"]
      if ($weight -le 0) { $weight = 0.1 }
      $score = (($hits + 0.5) / ($rounds + 1.0)) * $weight
    } else {
      $rounds = 0
      $score = 0.5
    }
    $scored += [pscustomobject]@{ keyword = $kw; score = [double]$score; rounds = $rounds }
  }
  $out = @()
  foreach ($row in @($scored | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.rounds }; Ascending = $true }, @{ Expression = { $_.keyword }; Ascending = $true })) {
    $out += [string]$row.keyword
  }
  return @($out)
}

function Get-KwEntryView($Platform, $Entry, $Now = $null) {
  $effective = Get-KwEffectiveState $Entry $Now
  $until = ConvertTo-KwDate $Entry["sleep_until"]
  return [pscustomobject]@{
    platform       = $Platform
    keyword        = [string]$Entry["keyword"]
    state          = $effective
    rounds         = [int]$Entry["rounds"]
    hits           = [int]$Entry["hits"]
    misses         = [int]$Entry["misses"]
    errors         = [int]$Entry["errors"]
    zero_streak    = [int]$Entry["consecutive_zero_rounds"]
    sleep_level    = [int]$Entry["sleep_level"]
    sleep_until    = if ($until) { $until.ToString("o") } else { $null }
    sleep_remaining_hours = Get-KwSleepRemainingHours $Entry $Now
    protected      = [bool]$Entry["protected"]
    manual         = [bool]$Entry["manual_pruned"]
    weight         = [double]$Entry["weight"]
    last           = [string]$Entry["last"]
    last_result    = [string]$Entry["last_result"]
    last_error     = [string]$Entry["last_error"]
  }
}

function Get-KwStatus([string]$BaseDir, [string]$Platform = "", $Now = $null) {
  $state = Read-KwStats $BaseDir
  $rows = @()
  $summary = @{ active = 0; sleep = 0; manual = 0; protected = 0; total = 0 }
  foreach ($pp in @($state["platforms"].GetEnumerator())) {
    $plat = [string]$pp.Key
    if ($Platform -and $plat -ine $Platform) { continue }
    foreach ($kp in @($pp.Value["keywords"].GetEnumerator())) {
      $entry = $kp.Value
      $view = Get-KwEntryView $plat $entry $Now
      $rows += $view
      $summary["total"] = [int]$summary["total"] + 1
      if ($summary.ContainsKey($view.state)) { $summary[$view.state] = [int]$summary[$view.state] + 1 }
    }
  }
  $order = @{ sleep = 0; manual = 1; protected = 2; active = 3 }
  $rows = @($rows | Sort-Object -Property @{ Expression = { $_.platform }; Ascending = $true }, @{ Expression = { $order[$_.state] }; Ascending = $true }, @{ Expression = { $_.keyword }; Ascending = $true })
  return [pscustomobject]@{
    ok           = $true
    generated_at = (Get-KwNow $Now).ToString("o")
    platform     = $Platform
    summary      = $summary
    keywords     = $rows
  }
}

function Set-KwKeywordState([string]$BaseDir, [string]$Platform, [string]$Keyword, [string]$Action, [int]$Hours = 0, $Now = $null, [string]$Note = "") {
  $actionName = ([string]$Action).Trim().ToLowerInvariant()
  $allowed = @("protect", "unprotect", "prune", "recover", "reset", "sleep")
  if ($allowed -notcontains $actionName) {
    return [pscustomobject]@{ ok = $false; error = "bad_action"; allowed = $allowed }
  }
  if (-not $Platform -or -not $Keyword) {
    return [pscustomobject]@{ ok = $false; error = "platform_and_keyword_required" }
  }
  if ($actionName -eq "sleep" -and ($Hours -lt 1 -or $Hours -gt 8760)) {
    return [pscustomobject]@{ ok = $false; error = "bad_hours" }
  }
  $now = Get-KwNow $Now
  $state = Read-KwStats $BaseDir
  $entry = Get-KwEntry $state $Platform $Keyword $true
  if ($null -eq $entry) { return [pscustomobject]@{ ok = $false; error = "bad_keyword" } }
  $entry["last_attempt"] = $now.ToString("o")
  if ($Note) { $entry["note"] = (ConvertTo-KwText $Note 160) }
  switch ($actionName) {
    "protect" {
      $entry["protected"] = $true
      $entry["manual_pruned"] = $false
      $entry["sleep_until"] = $null
      $entry["sleep_source"] = ""
      $entry["sleep_level"] = 0
      $entry["consecutive_zero_rounds"] = 0
    }
    "unprotect" {
      $entry["protected"] = $false
    }
    "prune" {
      $entry["manual_pruned"] = $true
      $entry["protected"] = $false
      $entry["sleep_until"] = $null
      $entry["sleep_source"] = "manual"
      $entry["sleep_level"] = 0
      $entry["consecutive_zero_rounds"] = 0
    }
    "recover" {
      $entry["manual_pruned"] = $false
      $entry["protected"] = $false
      $entry["sleep_until"] = $null
      $entry["sleep_source"] = ""
      $entry["sleep_level"] = 0
      $entry["consecutive_zero_rounds"] = 0
      $entry["weight"] = 1.0
      $entry["recovered_at"] = $now.ToString("o")
    }
    "reset" {
      $entry["manual_pruned"] = $false
      $entry["protected"] = $false
      $entry["sleep_until"] = $null
      $entry["sleep_source"] = ""
      $entry["sleep_level"] = 0
      $entry["consecutive_zero_rounds"] = 0
      $entry["weight"] = 1.0
      $entry["rounds"] = 0
      $entry["hits"] = 0
      $entry["misses"] = 0
      $entry["errors"] = 0
      $entry["strikes"] = 0
      $entry["last_rounds"] = @()
      $entry["recovered_at"] = $now.ToString("o")
    }
    "sleep" {
      $entry["manual_pruned"] = $false
      $entry["protected"] = $false
      $entry["sleep_until"] = $now.AddHours($Hours).ToString("o")
      $entry["sleep_source"] = "manual"
      $entry["sleep_level"] = 0
      $entry["consecutive_zero_rounds"] = 0
    }
  }
  $entry["last_result"] = "manual:" + $actionName
  $entry["last"] = $now.ToString("o")
  Save-KwStats $BaseDir $state | Out-Null
  return [pscustomobject]@{ ok = $true; action = $actionName; entry = (Get-KwEntryView $Platform $entry $now) }
}

function Register-KwRoundResult([string]$BaseDir, [string]$Platform, [string]$Keyword, $Raw, $Added, [bool]$Failed = $false, [string]$RoundId = "", [string]$Error = "", $Now = $null, $Config = $null) {
  $now = Get-KwNow $Now
  $round = ConvertTo-KwText $RoundId 96
  if (-not $round) { $round = "legacy-" + $now.ToString("yyyyMMddHHmmssfff") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8) }
  $state = Read-KwStats $BaseDir
  $entry = Get-KwEntry $state $Platform $Keyword $true
  if ($null -eq $entry) { return [pscustomobject]@{ ok = $false; error = "bad_keyword"; duplicate = $false; counted = $false; slept = $false } }
  $seenRounds = @($entry["last_rounds"])
  if ($seenRounds -contains $round) {
    return [pscustomobject]@{ ok = $true; duplicate = $true; counted = $false; slept = $false; state = (Get-KwEffectiveState $entry $now); keyword = $entry["keyword"]; platform = $Platform; reason = "same_round" }
  }

  $isUnknown = $false
  if ($null -eq $Raw) { $isUnknown = $true }
  if (-not $isUnknown -and [string]::IsNullOrWhiteSpace([string]$Raw)) { $isUnknown = $true }
  $rawInt = 0
  if (-not $isUnknown) {
    try { $rawInt = [int]$Raw } catch { $isUnknown = $true }
  }
  if ($rawInt -lt 0) { $isUnknown = $true }

  if ($Failed -or $isUnknown) {
    $entry["errors"] = [int]$entry["errors"] + 1
    $entry["last_attempt"] = $now.ToString("o")
    $entry["last_result"] = "error"
    $entry["last_error"] = (ConvertTo-KwText ($(if ($Error) { $Error } else { "unknown" })) 200)
    Save-KwStats $BaseDir $state | Out-Null
    return [pscustomobject]@{ ok = $true; duplicate = $false; counted = $false; slept = $false; reason = "error_not_counted"; state = (Get-KwEffectiveState $entry $now); keyword = $entry["keyword"]; platform = $Platform; errors = [int]$entry["errors"] }
  }

  $entry["rounds"] = [int]$entry["rounds"] + 1
  $entry["last_attempt"] = $now.ToString("o")
  $entry["last"] = $now.ToString("o")
  $entry["last_error"] = ""
  $memory = @($round) + @($seenRounds | Where-Object { $_ })
  if ($memory.Count -gt $script:KwRoundMemory) { $memory = @($memory | Select-Object -First $script:KwRoundMemory) }
  $entry["last_rounds"] = $memory

  $slept = $false
  if ($rawInt -gt 0) {
    $entry["hits"] = [int]$entry["hits"] + 1
    $entry["consecutive_zero_rounds"] = 0
    $entry["last_result"] = "hit"
    if ([string]$entry["sleep_source"] -eq "auto") {
      $entry["sleep_until"] = $null
      $entry["sleep_source"] = ""
      $entry["sleep_level"] = 0
    }
  } else {
    $entry["misses"] = [int]$entry["misses"] + 1
    $entry["consecutive_zero_rounds"] = [int]$entry["consecutive_zero_rounds"] + 1
    $entry["last_result"] = "zero"
    $protected = [bool]$entry["protected"]
    $manual = [bool]$entry["manual_pruned"]
    $policy = Get-KwPolicy $Config
    if ([bool]$policy.enabled -and -not $protected -and -not $manual) {
      $need = [int]$policy.zero_rounds
      if ([int]$entry["consecutive_zero_rounds"] -ge $need) {
        $level = [int]$entry["sleep_level"]
        if ($level -le 0) { $hours = [int]$policy.first_sleep_hours; $level = 1 } else { $hours = [int]$policy.second_sleep_hours; $level = 2 }
        $entry["sleep_until"] = $now.AddHours($hours).ToString("o")
        $entry["sleep_source"] = "auto"
        $entry["sleep_level"] = $level
        $entry["strikes"] = [int]$entry["strikes"] + 1
        $entry["consecutive_zero_rounds"] = 0
        $entry["auto_slept_at"] = $now.ToString("o")
        $slept = $true
      }
    }
  }
  Save-KwStats $BaseDir $state | Out-Null
  return [pscustomobject]@{
    ok        = $true
    duplicate = $false
    counted   = $true
    slept     = $slept
    reason    = $(if ($slept) { "auto_sleep" } elseif ($rawInt -gt 0) { "hit" } else { "zero" })
    state     = (Get-KwEffectiveState $entry $now)
    keyword   = $entry["keyword"]
    platform  = $Platform
    rounds    = [int]$entry["rounds"]
    hits      = [int]$entry["hits"]
    misses    = [int]$entry["misses"]
    zero_streak = [int]$entry["consecutive_zero_rounds"]
  }
}

function Register-KwResult([string]$BaseDir, [string]$Platform, [string]$Keyword, $Raw, $Added, [bool]$Failed = $false, [string]$RoundId = "", [string]$Error = "", $Now = $null, $Config = $null) {
  return Register-KwRoundResult -BaseDir $BaseDir -Platform $Platform -Keyword $Keyword -Raw $Raw -Added $Added -Failed $Failed -RoundId $RoundId -Error $Error -Now $Now -Config $Config
}
