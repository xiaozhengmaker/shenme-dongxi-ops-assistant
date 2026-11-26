# lib/kw_trend.ps1 -- 每周 AI 热点建议（有日期、有来源的聚合信号 -> 最多 5 条建议 -> 人工应用/按批回滚）
# 依赖 lib/kw_stats.ps1；AI 调用复用 lib/ai.ps1（未加载时自动 dot-source）。
# 安全边界：只向模型发送聚合计数与来源键，不发送用户名/用户 ID/标题/原始帖子；无 key、无信号、超预算都显式返回状态。

$script:KwTrendVersion = 1
$script:KwTrendLibDir = $PSScriptRoot

function Get-KwTrendStatePath([string]$BaseDir) {
  return [IO.Path]::Combine((Get-KwTrendDirPath $BaseDir), "state.json")
}

function Get-KwTrendBatchDir([string]$BaseDir) {
  return [IO.Path]::Combine((Get-KwTrendDirPath $BaseDir), "batches")
}

function New-KwTrendState {
  return @{
    version         = $script:KwTrendVersion
    updated         = $null
    last_attempt_at = $null
    last_success_at = $null
    last_status     = ""
    last_error      = ""
    last_batch_id   = ""
    usage           = @()
  }
}

function Read-KwTrendState([string]$BaseDir) {
  $state = New-KwTrendState
  $path = Get-KwTrendStatePath $BaseDir
  if (-not (Test-Path -LiteralPath $path)) { return $state }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch { return $state }
  if ($null -eq $raw) { return $state }
  foreach ($k in @("last_attempt_at", "last_success_at", "last_status", "last_error", "last_batch_id")) {
    try { if ($null -ne $raw.$k) { $state[$k] = [string]$raw.$k } } catch { }
  }
  $usage = @()
  try { $usage = @($raw.usage) } catch { $usage = @() }
  $state["usage"] = @($usage | Where-Object { $_ })
  return $state
}

function Write-KwTextFilePreserveBom([string]$Path, [string]$Text) {
  $dir = [IO.Path]::GetDirectoryName($Path)
  if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
  $bom = $true
  if (Test-Path -LiteralPath $Path) {
    try {
      $b = [IO.File]::ReadAllBytes($Path)
      $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    } catch { $bom = $true }
  }
  $tmp = $Path + ".tmp-" + [guid]::NewGuid().ToString("N")
  [IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($bom)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Save-KwTrendState([string]$BaseDir, $State) {
  $State["version"] = $script:KwTrendVersion
  $State["updated"] = (Get-Date).ToString("o")
  $json = $State | ConvertTo-Json -Depth 12
  Write-KwTextFilePreserveBom (Get-KwTrendStatePath $BaseDir) $json
}

function Set-KwTrendBlockerStatus([string]$BaseDir, [string]$Status, [string]$Message, $Now = $null, $Sources = $null) {
  try {
    $st = Read-KwTrendState $BaseDir
    $st["last_attempt_at"] = (Get-KwNow $Now).ToString("o")
    $st["last_status"] = [string]$Status
    $st["last_error"] = [string]$Message
    if ($null -ne $Sources) { $st["hot_sources"] = $Sources }
    Save-KwTrendState $BaseDir $st
  } catch { }
}

function Save-KwTrendBatch([string]$BaseDir, $Batch) {
  $dir = Get-KwTrendBatchDir $BaseDir
  if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
  $path = [IO.Path]::Combine($dir, ([string]$Batch.id) + ".json")
  $json = $Batch | ConvertTo-Json -Depth 16
  Write-KwTextFilePreserveBom $path $json
}

function Get-KwTrendBatch([string]$BaseDir, [string]$BatchId) {
  if (-not $BatchId) { return $null }
  if ($BatchId -notmatch '^[A-Za-z0-9\-]{4,64}$') { return $null }
  $path = [IO.Path]::Combine((Get-KwTrendBatchDir $BaseDir), ($BatchId + ".json"))
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-KwTrendBatches([string]$BaseDir, [int]$Limit = 10) {
  $dir = Get-KwTrendBatchDir $BaseDir
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    try {
      $b = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $out += [pscustomobject]@{
        id               = [string]$b.id
        created_at       = [string]$b.created_at
        status           = [string]$b.status
        model            = [string]$b.model
        suggestion_count = @($b.suggestions).Count
        applied_at       = [string]$b.applied_at
        rolled_back_at   = [string]$b.rolled_back_at
      }
    } catch { }
  }
  $out = @($out | Sort-Object -Property @{ Expression = { $_.created_at }; Descending = $true } | Select-Object -First $Limit)
  return @($out)
}

function Get-KwWeekKey($Now = $null) {
  $d = Get-KwNow $Now
  $d = $d.Date
  $offset = (([int]$d.DayOfWeek + 6) % 7)
  return $d.AddDays(-$offset).ToString("yyyy-MM-dd")
}

function Test-KwTrendDue([string]$BaseDir, $Now = $null, [int]$Days = 7) {
  $state = Read-KwTrendState $BaseDir
  $last = ConvertTo-KwDate $state["last_success_at"]
  if (-not $last) { return $true }
  if ($Days -lt 1) { $Days = 7 }
  return (((Get-KwNow $Now) - $last).TotalDays -ge $Days)
}

function Get-KwTrendBudget([string]$BaseDir, $Policy, $Now = $null) {
  $state = Read-KwTrendState $BaseDir
  $now = Get-KwNow $Now
  $cutoff = $now.AddDays(-7)
  $spent = 0.0
  foreach ($u in @($state["usage"])) {
    if ($null -eq $u) { continue }
    $at = ConvertTo-KwDate $u.at
    if (-not $at -or $at -lt $cutoff) { continue }
    try { $spent += [double]$u.cost_cny } catch { }
  }
  $limit = 0.0
  try { $limit = [double]$Policy.ai_weekly_budget_cny } catch { $limit = 0.0 }
  $remaining = [Math]::Round($limit - $spent, 6)
  if ($remaining -lt 0) { $remaining = 0.0 }
  return [pscustomobject]@{
    limit       = [Math]::Round($limit, 6)
    spent       = [Math]::Round($spent, 6)
    remaining   = $remaining
    window_days = 7
    blocked     = ($limit -le 0 -or $remaining -le 0)
  }
}

function Get-KwTrendCost($PromptTokens, $CompletionTokens, $Policy) {
  $inp = 0.0; $outp = 0.0
  try { $inp = [double]$Policy.ai_price_in_per_m } catch { $inp = 2.0 }
  try { $outp = [double]$Policy.ai_price_out_per_m } catch { $outp = 8.0 }
  $cost = (([double]$PromptTokens * $inp) + ([double]$CompletionTokens * $outp)) / 1000000.0
  return [Math]::Round($cost, 6)
}

function Test-KwSafeKeyword([string]$Keyword) {
  $k = ([string]$Keyword).Trim()
  if ($k.Length -lt 2 -or $k.Length -gt 64) { return $false }
  if ($k -match '[\r\n\t\|]') { return $false }
  if ($k -match '[\x00-\x1f]') { return $false }
  if ($k -match '@') { return $false }
  if ($k -match 'https?://|www\.') { return $false }
  if ($k -match '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}') { return $false }
  if ($k -match '\+?\d[\d\s\-]{7,}\d') { return $false }
  return $true
}

function Get-KwKnownPlatforms($Config) {
  if ($null -eq $Config -or $null -eq $Config.strategy) { return @() }
  try { return @($Config.strategy.PSObject.Properties.Name) } catch { return @() }
}

function Get-KwDiscoveryBucket($Config, [string]$Platform, [bool]$Create = $false) {
  if ($null -eq $Config -or $null -eq $Config.strategy) { return $null }
  $strat = $null
  try { $strat = $Config.strategy.$Platform } catch { $strat = $null }
  if ($null -eq $strat) { return $null }
  $disc = $null
  try { $disc = $strat.discovery } catch { $disc = $null }
  if ($null -eq $disc) {
    if (-not $Create) { return $null }
    $strat | Add-Member -NotePropertyName discovery -NotePropertyValue ([pscustomobject]@{}) -Force
    $disc = $strat.discovery
  }
  $kws = $null
  try { $kws = $disc.keywords } catch { $kws = $null }
  if ($null -eq $kws) {
    if (-not $Create) { return $null }
    $disc | Add-Member -NotePropertyName keywords -NotePropertyValue @() -Force
    $kws = $disc.keywords
  }
  return @($kws)
}

function Test-KwKeywordInConfig($Config, [string]$Platform, [string]$Keyword) {
  $k = ([string]$Keyword).Trim().ToLowerInvariant()
  if (-not $k) { return $false }
  $bucket = Get-KwDiscoveryBucket $Config $Platform $false
  if ($null -ne $bucket) {
    foreach ($x in @($bucket)) { if (([string]$x).Trim().ToLowerInvariant() -eq $k) { return $true } }
  }
  try {
    foreach ($x in @($Config.keywordPool)) { if (([string]$x).Trim().ToLowerInvariant() -eq $k) { return $true } }
  } catch { }
  return $false
}

function Get-KwHotSettings($Config) {
  $h = [ordered]@{
    enabled              = $true
    max_items            = 8
    platform             = ""
    entries_file         = "data/kw_hot_sources.json"
    entries_max_age_days = 180
    steam_enabled        = $true
    steam_appid          = 730
    steam_max_age_days   = 30
    steam_timeout_sec    = 8
    steam_url            = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=730&feeds=steam_community_announcements&count=8&format=json"
    entry_list           = @()
  }
  $hs = $null
  try { if ($Config -and $Config.kw_evolve -and $Config.kw_evolve.hot_sources) { $hs = $Config.kw_evolve.hot_sources } } catch { }
  if ($hs) {
    foreach ($n in @("enabled")) { try { if ($null -ne $hs.$n) { $h[$n] = [bool]$hs.$n } } catch { } }
    foreach ($n in @("max_items", "entries_max_age_days", "steam_appid", "steam_max_age_days", "steam_timeout_sec")) {
      try { if ($null -ne $hs.$n) { $h[$n] = [int]$hs.$n } } catch { }
    }
    try { if ($hs.platform) { $h["platform"] = [string]$hs.platform } } catch { }
    try { if ($hs.entries_file) { $h["entries_file"] = [string]$hs.entries_file } } catch { }
    try { if ($null -ne $hs.entries) { $h["entry_list"] = @($hs.entries) } } catch { }
    $st = $null
    try { if ($hs.steam_cs2) { $st = $hs.steam_cs2 } elseif ($hs.steam) { $st = $hs.steam } } catch { }
    if ($st) {
      try { if ($null -ne $st.enabled) { $h["steam_enabled"] = [bool]$st.enabled } } catch { }
      foreach ($n in @("appid", "max_age_days", "timeout_sec")) {
        try { if ($null -ne $st.$n) { $h["steam_" + $n] = [int]$st.$n } } catch { }
      }
      try { if ($st.url) { $h["steam_url"] = [string]$st.url } } catch { }
    }
  }
  if ($h["max_items"] -lt 1) { $h["max_items"] = 8 }
  if ($h["max_items"] -gt 20) { $h["max_items"] = 20 }
  if ($h["entries_max_age_days"] -lt 1) { $h["entries_max_age_days"] = 180 }
  if ($h["steam_appid"] -lt 1) { $h["steam_appid"] = 730 }
  if ($h["steam_max_age_days"] -lt 1) { $h["steam_max_age_days"] = 30 }
  if ($h["steam_timeout_sec"] -lt 2) { $h["steam_timeout_sec"] = 8 }
  if ($h["steam_timeout_sec"] -gt 30) { $h["steam_timeout_sec"] = 30 }
  if (-not $h["steam_url"]) { $h["steam_url"] = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=" + $h["steam_appid"] + "&feeds=steam_community_announcements&count=" + $h["max_items"] + "&format=json" }
  return [pscustomobject]$h
}

function Test-KwCs2Context($Config) {
  $texts = @()
  try { if ($Config.business) { $texts += [string]$Config.business } } catch { }
  try {
    if ($Config.profile) {
      foreach ($n in @("business", "business_type", "industry", "products", "keywords")) {
        try { if ($Config.profile.$n) { $texts += [string]$Config.profile.$n } } catch { }
      }
    }
  } catch { }
  try { foreach ($x in @($Config.keywordPool)) { $texts += [string]$x } } catch { }
  try {
    if ($Config.queries) {
      foreach ($p in @($Config.queries.PSObject.Properties)) { foreach ($x in @($p.Value)) { $texts += [string]$x } }
    }
  } catch { }
  try {
    if ($Config.strategy) {
      foreach ($p in @($Config.strategy.PSObject.Properties)) {
        try {
          if ($p.Value.discovery) { foreach ($x in @($p.Value.discovery.keywords)) { $texts += [string]$x } }
        } catch { }
      }
    }
  } catch { }
  try {
    if ($Config.kw_evolve -and $Config.kw_evolve.hot_sources -and $Config.kw_evolve.hot_sources.cs2) { return $true }
  } catch { }
  $all = ($texts -join " `n ")
  if (-not $all) { return $false }
  return ($all -match '(?i)(^|[^a-z0-9])cs2([^a-z0-9]|$)|counter[\s-]?strike')
}

function Get-KwShortHash([string]$Text) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
  } finally {
    $sha.Dispose()
  }
}

function Test-KwHotText([string]$Text) {
  $t = [string]$Text
  if (-not $t) { return $false }
  $t = [System.Text.RegularExpressions.Regex]::Replace($t, '<[^>]+>', ' ')
  try { $t = [System.Net.WebUtility]::HtmlDecode($t) } catch { }
  $t = ($t -replace '\s+', ' ').Trim()
  if ($t.Length -lt 3 -or $t.Length -gt 180) { return $false }
  if ($t -match '[\x00-\x1f]') { return $false }
  if ($t -match '@') { return $false }
  if ($t -match '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}') { return $false }
  if ($t -match '\+?\d[\d\s\-]{7,}\d') { return $false }
  if ($t -match 'https?://|www\.') { return $false }
  return $true
}

function ConvertTo-KwHotSignal([string]$Platform, [string]$Title, [string]$Url, [string]$PublishedAt, [string]$SourceKind, [string]$SourceId, $Tags = $null) {
  $key = "hot:" + $SourceKind + ":" + (Get-KwShortHash ($Url + "|" + $PublishedAt + "|" + $Title))
  $meta = [pscustomobject]@{
    key         = $key
    source_id   = $SourceId
    ts          = $PublishedAt
    platform    = $Platform
    query       = $Title
    title       = $Title
    url         = $Url
    published_at = $PublishedAt
    kind        = "hot"
    source_kind = $SourceKind
  }
  return [pscustomobject]@{
    kind         = "hot"
    source_kind  = $SourceKind
    platform     = $Platform
    query        = $Title
    title        = $Title
    url          = $Url
    published_at = $PublishedAt
    rounds       = 0
    raw          = 0
    eligible     = 0
    joined       = 0
    source_count = 1
    sources      = @($key)
    source_meta  = @{ $key = $meta }
    first        = $PublishedAt
    last         = $PublishedAt
    tags         = @($Tags)
  }
}

function Get-KwHotEntries([string]$BaseDir, $Settings, $Known, $Now) {
  $items = @()
  $fileEntries = @()
  $path = ""
  try {
    $rel = [string]$Settings.entries_file
    if ($rel -and -not [IO.Path]::IsPathRooted($rel)) {
      $path = [IO.Path]::GetFullPath((Join-Path $BaseDir $rel))
      $root = [IO.Path]::GetFullPath($BaseDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
      if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $path = "" }
    }
  } catch { $path = "" }
  if ($path -and (Test-Path -LiteralPath $path)) {
    try {
      $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
      $fileEntries = @($doc.entries)
    } catch { $fileEntries = @() }
  }
  $cfgEntries = @()
  try { if ($Settings.entry_list) { $cfgEntries = @($Settings.entry_list) } } catch { }
  $all = @($fileEntries) + @($cfgEntries)
  $cutoff = (Get-KwNow $Now).AddDays(-[int]$Settings.entries_max_age_days)
  foreach ($e in $all) {
    if ($null -eq $e) { continue }
    $title = [string]$e.title
    $url = [string]$e.url
    $dateTxt = [string]$e.date
    if (-not (Test-KwHotText $title)) { continue }
    $u = $null
    try { $u = [Uri]$url } catch { $u = $null }
    if ($null -eq $u -or @("http", "https") -notcontains $u.Scheme) { continue }
    $dt = ConvertTo-KwDate $dateTxt
    if (-not $dt -or $dt -lt $cutoff) { continue }
    $plat = [string]$e.platform
    if (-not $plat -or @($Known) -notcontains $plat) { $plat = [string]$Settings.platform }
    if (-not $plat -or @($Known) -notcontains $plat) { $plat = @($Known | Select-Object -First 1) }
    if (-not $plat) { continue }
    $tags = @()
    try { $tags = @($e.tags) } catch { }
    $items += ConvertTo-KwHotSignal $plat $title ([string]$u.AbsoluteUri) ($dt.ToString("o")) "entry" ("entry:" + (Get-KwShortHash $url)) $tags
    if ($items.Count -ge [int]$Settings.max_items) { break }
  }
  return [pscustomobject]@{ status = $(if ($items.Count -gt 0) { "ok" } elseif ($path -and (Test-Path -LiteralPath $path)) { "empty" } else { "missing" }); items = @($items); path = $path }
}

function Get-KwHotSignals([string]$BaseDir, $Config, $Policy, [scriptblock]$Fetcher = $null, $Now = $null) {
  $settings = Get-KwHotSettings $Config
  $result = [ordered]@{
    enabled       = [bool]$settings.enabled
    status        = "disabled"
    cs2           = $false
    steam_status  = "disabled"
    entries_status = "disabled"
    signals       = @()
    warnings      = @()
    max_items     = [int]$settings.max_items
    steam_appid   = [int]$settings.steam_appid
  }
  if (-not $settings.enabled) { return [pscustomobject]$result }
  $cs2 = Test-KwCs2Context $Config
  $result["cs2"] = [bool]$cs2
  if (-not $cs2) { $result["status"] = "not_cs2"; return [pscustomobject]$result }
  $known = @(Get-KwKnownPlatforms $Config)
  if ($known.Count -eq 0) {
    $result["status"] = "no_platform"
    $result["warnings"] = @("配置里没有可用的平台名")
    return [pscustomobject]$result
  }
  $signals = @()
  $entries = Get-KwHotEntries $BaseDir $settings $known $Now
  $result["entries_status"] = [string]$entries.status
  if (@($entries.items).Count -gt 0) { $signals += @($entries.items) }
  if ($settings.steam_enabled) {
    $raw = $null
    try {
      if ($null -ne $Fetcher) {
        $raw = & $Fetcher ([string]$settings.steam_url) $settings
      } else {
        $resp = Invoke-WebRequest -Uri ([string]$settings.steam_url) -UseBasicParsing -TimeoutSec ([int]$settings.steam_timeout_sec) -Headers @{ "User-Agent" = "gops-kw-trend/1.0" }
        $raw = ($resp.Content | ConvertFrom-Json)
      }
      $result["steam_status"] = "ok"
    } catch {
      $result["steam_status"] = "failed"
      $result["warnings"] = @($result["warnings"]) + @("Steam 官方更新读取失败，已降级：" + (ConvertTo-KwText $_.Exception.Message 160))
      $raw = $null
    }
    if ($raw) {
      $news = @()
      try { $news = @($raw.appnews.newsitems) } catch { $news = @() }
      $cutoff = (Get-KwNow $Now).AddDays(-[int]$settings.steam_max_age_days)
      foreach ($n in $news) {
        if ($null -eq $n) { continue }
        $title = [string]$n.title
        if (-not (Test-KwHotText $title)) { continue }
        $u = $null
        try { $u = [Uri]([string]$n.url) } catch { $u = $null }
        if ($null -eq $u -or @("http", "https") -notcontains $u.Scheme) { continue }
        if ($u.Host -notmatch '(^|\.)steampowered\.com$' -and $u.Host -notmatch '(^|\.)steamcommunity\.com$') { continue }
        $unix = 0
        try { $unix = [long]$n.date } catch { $unix = 0 }
        if ($unix -le 0) { continue }
        $dt = [DateTimeOffset]::FromUnixTimeSeconds($unix).ToLocalTime()
        if ($dt -lt $cutoff) { continue }
        $plat = [string]$settings.platform
        if (-not $plat -or @($known) -notcontains $plat) { $plat = @($known | Select-Object -First 1) }
        $sid = "steam:" + [string]$settings.steam_appid + ":" + [string]$n.gid
        $signals += ConvertTo-KwHotSignal $plat $title ([string]$u.AbsoluteUri) ($dt.ToString("o")) "steam" $sid @($n.feedlabel)
        if ($signals.Count -ge ([int]$settings.max_items * 2)) { break }
      }
    }
  }
  $signals = @($signals | Sort-Object -Property @{ Expression = { ConvertTo-KwDate $_.published_at }; Descending = $true } | Select-Object -First ([int]$settings.max_items))
  $result["signals"] = @($signals)
  if ($signals.Count -gt 0) {
    if (@($result["warnings"]).Count -gt 0 -or $result["steam_status"] -eq "failed" -or $result["entries_status"] -in @("missing", "empty")) { $result["status"] = "partial" } else { $result["status"] = "ok" }
  } else {
    if ($result["steam_status"] -eq "failed") { $result["status"] = "unavailable" } else { $result["status"] = "no_entries" }
  }
  return [pscustomobject]$result
}

function Get-KwHotSummary($Hot) {
  if ($null -eq $Hot) { return $null }
  return [pscustomobject]@{
    enabled        = [bool]$Hot.enabled
    status         = [string]$Hot.status
    cs2            = [bool]$Hot.cs2
    steam_status   = [string]$Hot.steam_status
    entries_status = [string]$Hot.entries_status
    max_items      = [int]$Hot.max_items
    steam_appid    = [int]$Hot.steam_appid
    warnings       = @($Hot.warnings)
  }
}

function Get-KwLedgerSignals([string]$BaseDir, [int]$WindowDays = 14, [int]$MaxSignals = 60, $Now = $null) {
  $path = [IO.Path]::Combine($BaseDir, "data", "source_ledger.jsonl")
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  if ($WindowDays -lt 1) { $WindowDays = 14 }
  if ($WindowDays -gt 60) { $WindowDays = 60 }
  $cutoff = (Get-KwNow $Now).AddDays(-$WindowDays)
  $map = @{}
  foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $o = $null
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $o) { continue }
    $ts = ConvertTo-KwDate $o.ts
    if (-not $ts -or $ts -lt $cutoff) { continue }
    $plat = ConvertTo-KwText ([string]$o.platform) 32
    $query = ConvertTo-KwText ([string]$o.query) 96
    $sid = ConvertTo-KwText ([string]$o.source_id) 64
    if (-not $plat -or -not $query -or -not $sid) { continue }
    if (-not (Test-KwSafeKeyword $query)) { continue }
    $key = $plat.ToLowerInvariant() + "|" + $query.ToLowerInvariant()
    if (-not $map.ContainsKey($key)) {
      $map[$key] = @{
        platform = $plat
        query    = $query
        rounds   = 0
        raw      = 0
        eligible = 0
        joined   = 0
        sources  = @{}
        source_meta = @{}
        first    = $ts
        last     = $ts
      }
    }
    $s = $map[$key]
    $s["rounds"] = [int]$s["rounds"] + 1
    foreach ($f in @("raw", "eligible", "joined")) {
      $v = 0
      try { $v = [int]$o.$f } catch { $v = 0 }
      if ($v -lt 0) { $v = 0 }
      $s[$f] = [int]$s[$f] + $v
    }
    $sourceKey = "ledger:" + (Get-KwShortHash ($sid + "|" + $ts.ToString("o") + "|" + $plat + "|" + $query))
    $s["sources"][$sourceKey] = [pscustomobject]@{ key = $sourceKey; source_id = $sid; ts = $ts.ToString("o"); platform = $plat; query = $query }
    $s["source_meta"][$sourceKey] = [pscustomobject]@{ key = $sourceKey; source_id = $sid; ts = $ts.ToString("o"); platform = $plat; query = $query; kind = "ledger" }
    if ($ts -lt $s["first"]) { $s["first"] = $ts }
    if ($ts -gt $s["last"]) { $s["last"] = $ts }
  }
  $list = @()
  foreach ($k in @($map.Keys)) {
    $s = $map[$k]
    $srcKeys = @($s["sources"].Keys | Sort-Object)
    $list += [pscustomobject]@{
      kind         = "ledger"
      platform     = [string]$s["platform"]
      query        = [string]$s["query"]
      rounds       = [int]$s["rounds"]
      raw          = [int]$s["raw"]
      eligible     = [int]$s["eligible"]
      joined       = [int]$s["joined"]
      source_count = $srcKeys.Count
      sources      = @($srcKeys)
      source_meta  = $s["source_meta"]
      first        = ([datetime]$s["first"]).ToString("o")
      last         = ([datetime]$s["last"]).ToString("o")
    }
  }
  $list = @($list | Sort-Object -Property @{ Expression = { $_.joined }; Descending = $true }, @{ Expression = { $_.eligible }; Descending = $true }, @{ Expression = { $_.raw }; Descending = $true }, @{ Expression = { $_.query }; Ascending = $true } | Select-Object -First $MaxSignals)
  return @($list)
}

function Get-KwExistingKeywords([string]$BaseDir, [int]$Max = 40, $Now = $null) {
  $state = Read-KwStats $BaseDir
  $rows = @()
  foreach ($pp in @($state["platforms"].GetEnumerator())) {
    foreach ($kp in @($pp.Value["keywords"].GetEnumerator())) {
      $view = Get-KwEntryView ([string]$pp.Key) $kp.Value $Now
      $rows += [pscustomobject]@{
        platform     = $view.platform
        keyword      = $view.keyword
        state        = $view.state
        rounds       = $view.rounds
        hits         = $view.hits
        misses       = $view.misses
        errors       = $view.errors
        zero_streak  = $view.zero_streak
        weight       = $view.weight
        sleep_hours  = $view.sleep_remaining_hours
      }
    }
  }
  $order = @{ sleep = 0; manual = 1; active = 2; protected = 3 }
  $rows = @($rows | Sort-Object -Property @{ Expression = { $order[$_.state] }; Ascending = $true }, @{ Expression = { $_.misses }; Descending = $true }, @{ Expression = { $_.keyword }; Ascending = $true } | Select-Object -First $Max)
  return @($rows)
}

function Get-KwTrendPrompt($Signals, $Existing, $Policy) {
  $sig = @()
  foreach ($s in @($Signals)) {
    $sig += [ordered]@{
      kind         = [string]$s.kind
      platform     = [string]$s.platform
      query        = [string]$s.query
      title        = [string]$s.title
      url          = [string]$s.url
      published_at = [string]$s.published_at
      rounds       = [int]$s.rounds
      raw          = [int]$s.raw
      eligible     = [int]$s.eligible
      joined       = [int]$s.joined
      source_count = [int]$s.source_count
      sources      = @($s.sources | Select-Object -First 8)
      first        = [string]$s.first
      last         = [string]$s.last
    }
  }
  $ex = @()
  foreach ($e in @($Existing)) {
    $ex += [ordered]@{
      platform  = [string]$e.platform
      keyword   = [string]$e.keyword
      state     = [string]$e.state
      rounds    = [int]$e.rounds
      hits      = [int]$e.hits
      misses    = [int]$e.misses
      weight    = [double]$e.weight
    }
  }
  $sigJson = ($sig | ConvertTo-Json -Depth 6 -Compress)
  $exJson = ($ex | ConvertTo-Json -Depth 6 -Compress)
  $system = @'
你要基于两类信号判断：ledger 是平台搜索的聚合统计，hot 是官方公开更新或后台维护的带日期 URL 条目。
硬性规则：
1. 不发送、不生成、不猜测任何个人账号、姓名、电话、邮箱、用户 ID、用户帖子标题或原文。
2. hot 信号只提供官方公开标题、日期和 URL，不含正文；标题只用于判断版本/赛事/地区文化，不得把标题当作用户帖子，也不要复述或扩写标题。
3. 不得编造来源；每条建议必须引用输入信号里出现过的 source 键（原样复制）。
4. 建议数量最多 5 条；没有足够依据时返回空数组。
5. 动作只能是 add（新增关键词）、revive（恢复休眠/手工淘汰的词）、downweight（降低权重）。
6. 只输出 JSON，不要解释、不要 markdown 代码块。
输出结构：
{"suggestions":[{"action":"add|revive|downweight","platform":"平台名","keyword":"关键词","reason":"一句话理由","source_ids":["来源键"],"confidence":0.0}]}
'@
  $user = @'
近期聚合信号（ledger 是平台搜索聚合；hot 是官方公开更新/后台条目，含 date/url；sources 是可用于核对的来源键）：
{{SIGNALS}}
现有词表现（state=active/sleep/manual/protected；weight 是当前权重）：
{{EXISTING}}
请给出最多 5 条建议。platform 必须使用信号或现有词里出现过的平台名。source_ids 必须来自上面的 sources，不得新造。没有依据就输出 {"suggestions":[]}。每条 reason 不超过 80 字。
'@
  $user = $user.Replace("{{SIGNALS}}", $sigJson).Replace("{{EXISTING}}", $exJson)
  return [pscustomobject]@{ system = $system; user = $user }
}

function ConvertFrom-KwAiSuggestions([string]$Text, $Signals, $Existing, $Config, $Policy, [string]$BaseDir) {
  $clean = [string]$Text
  $clean = $clean -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
  $a = $clean.IndexOf("{"); $b = $clean.LastIndexOf("}")
  if ($a -ge 0 -and $b -gt $a) { $clean = $clean.Substring($a, $b - $a + 1) }
  $obj = $null
  try { $obj = $clean | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; error = "invalid_json"; suggestions = @(); rejected = @() } }
  $raw = @()
  try { $raw = @($obj.suggestions) } catch { $raw = @() }
  if ($raw.Count -eq 0) { return [pscustomobject]@{ ok = $true; suggestions = @(); rejected = @() } }

  $sourceMap = @{}
  foreach ($s in @($Signals)) {
    foreach ($sid in @($s.sources)) {
      $k = [string]$sid
      if ($k -and -not $sourceMap.ContainsKey($k)) {
        $meta = $null
        try { if ($s.source_meta) { $meta = $s.source_meta[$k] } } catch { $meta = $null }
        if ($null -ne $meta) {
          $sourceMap[$k] = $meta
        } else {
          $sourceMap[$k] = [pscustomobject]@{ key = $k; source_id = ([string]$sid).Split("@")[0]; ts = [string]$s.last; platform = [string]$s.platform; query = [string]$s.query; kind = [string]$s.kind }
        }
      }
    }
  }
  $known = @(Get-KwKnownPlatforms $Config)
  $knownByLower = @{}
  foreach ($p in $known) { $knownByLower[([string]$p).ToLowerInvariant()] = [string]$p }
  $stats = Read-KwStats $BaseDir

  $out = @(); $rejected = @()
  foreach ($r in $raw) {
    if ($null -eq $r) { continue }
    $action = ([string]$r.action).Trim().ToLowerInvariant()
    if ($action -eq "add_keyword") { $action = "add" }
    if ($action -eq "reactivate" -or $action -eq "restore") { $action = "revive" }
    if ($action -eq "reduce_weight" -or $action -eq "down_weight") { $action = "downweight" }
    $platform = ([string]$r.platform).Trim()
    $keyword = ([string]$r.keyword).Trim()
    if (-not $keyword) { $keyword = ([string]$r.query).Trim() }
    if (@("add", "revive", "downweight") -notcontains $action) { $rejected += @{ reason = "bad_action"; action = $action }; continue }
    if (-not $keyword -or -not (Test-KwSafeKeyword $keyword)) { $rejected += @{ reason = "unsafe_keyword"; keyword = $keyword }; continue }
    $platKey = $platform.ToLowerInvariant()
    if (-not $knownByLower.ContainsKey($platKey)) { $rejected += @{ reason = "unknown_platform"; platform = $platform }; continue }
    $platform = $knownByLower[$platKey]
    $ids = @()
    try { $ids = @($r.source_ids) } catch { $ids = @() }
    if ($ids.Count -eq 0) { try { $ids = @($r.sources) } catch { $ids = @() } }
    $src = @(); $badIds = 0
    foreach ($id in $ids) {
      $k = [string]$id
      if ($sourceMap.ContainsKey($k)) { $src += $sourceMap[$k] } else { $badIds++ }
    }
    if ($src.Count -eq 0) { $rejected += @{ reason = "no_valid_source"; keyword = $keyword }; continue }
    if ($badIds -gt 0) { $rejected += @{ reason = "some_bad_sources"; keyword = $keyword; bad = $badIds } }
    $reason = ConvertTo-KwText ([string]$r.reason) 240
    $conf = 0.5
    try { $conf = [double]$r.confidence } catch { $conf = 0.5 }
    if ($conf -lt 0) { $conf = 0.0 }
    if ($conf -gt 1) { $conf = 1.0 }
    if ($action -eq "add") {
      if (Test-KwKeywordInConfig $Config $platform $keyword) { $rejected += @{ reason = "already_exists"; platform = $platform; keyword = $keyword }; continue }
    } else {
      $e = Get-KwEntry $stats $platform $keyword $false
      if ($null -eq $e) { $rejected += @{ reason = "not_tracked"; platform = $platform; keyword = $keyword }; continue }
      if ($action -eq "revive") {
        $st = Get-KwEffectiveState $e
        if ($st -eq "active") { $rejected += @{ reason = "already_active"; platform = $platform; keyword = $keyword }; continue }
        if ([bool]$e["protected"]) { $rejected += @{ reason = "protected"; platform = $platform; keyword = $keyword }; continue }
      }
      if ($action -eq "downweight") {
        if ([bool]$e["protected"]) { $rejected += @{ reason = "protected"; platform = $platform; keyword = $keyword }; continue }
        if ([double]$e["weight"] -le 0.1) { $rejected += @{ reason = "already_low"; platform = $platform; keyword = $keyword }; continue }
      }
    }
    $dupKey = $action + "|" + $platform.ToLowerInvariant() + "|" + $keyword.ToLowerInvariant()
    $dup = $false
    foreach ($x in $out) { if (([string]$x["dup_key"]) -eq $dupKey) { $dup = $true; break } }
    if ($dup) { continue }
    $out += [ordered]@{
      action     = $action
      platform   = $platform
      keyword    = $keyword
      reason     = $reason
      confidence = [Math]::Round($conf, 2)
      source_ids = @($src | ForEach-Object { [string]$_.key })
      sources    = @($src | Select-Object -First 6)
      dup_key    = $dupKey
      status     = "pending"
    }
    if ($out.Count -ge [int]$Policy.ai_max_suggestions) { break }
  }
  return [pscustomobject]@{ ok = $true; suggestions = @($out); rejected = @($rejected) }
}

function Get-KwPromptEstimate($System, $User, $Policy) {
  $chars = ([string]$System).Length + ([string]$User).Length
  $inTokens = [int][Math]::Ceiling($chars / 2.5)
  $outTokens = [int]$Policy.ai_max_tokens
  $cost = Get-KwTrendCost $inTokens $outTokens $Policy
  return [pscustomobject]@{ prompt_tokens = $inTokens; completion_tokens = $outTokens; cost_cny = $cost }
}

function Get-KwTrendLockPath([string]$BaseDir) {
  return [IO.Path]::Combine((Get-KwTrendDirPath $BaseDir), ".generate.lock")
}

function Enter-KwTrendLock([string]$BaseDir, $Now = $null, [int]$StaleSeconds = 600) {
  $path = Get-KwTrendLockPath $BaseDir
  $dir = [IO.Path]::GetDirectoryName($path)
  try { if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force } } catch { }
  $attempt = 0
  while ($attempt -lt 2) {
    $attempt++
    try {
      $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((Get-KwNow $Now).ToString("o"))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
      } catch { }
      return [pscustomobject]@{ ok = $true; handle = $fs; path = $path; status = "locked" }
    } catch {
      if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ ok = $false; status = "busy"; message = "无法创建生成锁"; detail = (ConvertTo-KwText $_.Exception.Message 160) }
      }
      $age = 999999
      try { $age = ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalSeconds } catch { }
      if ($age -ge $StaleSeconds) {
        try { Remove-Item -LiteralPath $path -Force; continue } catch { }
      }
      return [pscustomobject]@{ ok = $false; status = "busy"; message = "上一次 AI 生成仍在进行"; locked_seconds = [int]$age }
    }
  }
  return [pscustomobject]@{ ok = $false; status = "busy"; message = "上一次 AI 生成仍在进行" }
}

function Exit-KwTrendLock($Handle) {
  if ($null -eq $Handle) { return }
  try { if ($Handle.handle) { $Handle.handle.Dispose() } } catch { }
  try { if ($Handle.path -and (Test-Path -LiteralPath $Handle.path)) { Remove-Item -LiteralPath $Handle.path -Force } } catch { }
}

function New-KwTrendSuggestions([string]$BaseDir, [string]$ConfigPath, $Config, $Now = $null, [switch]$Force, [scriptblock]$AiInvoker = $null, [switch]$NoWrite, [scriptblock]$SourceFetcher = $null) {
  $now = Get-KwNow $Now
  if ($null -eq $Config) {
    if (-not $ConfigPath) { $ConfigPath = [IO.Path]::Combine($BaseDir, "config.json") }
    if (Test-Path -LiteralPath $ConfigPath) {
      try { $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Config = $null }
    }
  }
  if ($null -eq $Config) { return [pscustomobject]@{ ok = $false; status = "no_config"; message = "config.json 不存在或无法解析" } }
  $policy = Get-KwPolicy $Config
  if (-not $policy.enabled) { return [pscustomobject]@{ ok = $false; status = "disabled"; message = "关键词演化已在 config.kw_evolve.enabled 关闭" } }
  if (-not $Force -and -not (Test-KwTrendDue $BaseDir $now)) {
    $st = Read-KwTrendState $BaseDir
    return [pscustomobject]@{ ok = $true; status = "not_due"; message = "本周已运行过"; last_success_at = $st["last_success_at"] }
  }
  $ai = Get-KwAiSettings $Config
  try { $ai | Add-Member -NotePropertyName max_tokens -NotePropertyValue ([int]$policy.ai_max_tokens) -Force } catch { }
  if (-not $policy.ai_enabled) {
    if (-not $NoWrite) { Set-KwTrendBlockerStatus $BaseDir "ai_disabled" "config.kw_evolve.ai_enabled=false" $now }
    return [pscustomobject]@{ ok = $false; status = "ai_disabled"; message = "config.kw_evolve.ai_enabled=false" }
  }
  if (-not $ai.has_key -and $null -eq $AiInvoker) {
    if (-not $NoWrite) { Set-KwTrendBlockerStatus $BaseDir "no_key" "未配置 AI API Key（config.ai.api_key 或 api_key_env）" $now }
    return [pscustomobject]@{ ok = $false; status = "no_key"; message = "未配置 AI API Key（config.ai.api_key 或 api_key_env）"; masked = $ai.masked }
  }
  $lockHandle = $null
  if (-not $NoWrite) {
    $lockHandle = Enter-KwTrendLock $BaseDir $now 600
    if (-not $lockHandle.ok) { return [pscustomobject]@{ ok = $false; status = "busy"; message = $lockHandle.message } }
  }
  try {
    $hot = Get-KwHotSignals $BaseDir $Config $policy $SourceFetcher $now
    $hotSummary = Get-KwHotSummary $hot
    $signals = @(Get-KwLedgerSignals $BaseDir $policy.ai_window_days 60 $now) + @($hot.signals)
    if ($signals.Count -eq 0) {
      $msg = "近期没有可用信号（source_ledger 与热点源均为空）"
      if ($hot.status -eq "unavailable") { $msg = "近期没有可用信号，且官方热点源读取失败：已降级，不发起模型调用" }
      elseif ($hot.status -eq "not_cs2") { $msg = "近期没有搜索 ledger 信号；业务未明确 CS2，热点源未启用" }
      elseif (@($hot.warnings).Count -gt 0) { $msg = "近期没有可用信号；" + [string](@($hot.warnings)[0]) }
      if (-not $NoWrite) { Set-KwTrendBlockerStatus $BaseDir "no_signals" $msg $now $hotSummary }
      return [pscustomobject]@{ ok = $false; status = "no_signals"; message = $msg; window_days = $policy.ai_window_days; sources = $hotSummary }
    }
    $existing = @(Get-KwExistingKeywords $BaseDir 40 $now)
    $prompt = Get-KwTrendPrompt $signals $existing $policy
    $est = Get-KwPromptEstimate $prompt.system $prompt.user $policy
    $budget = Get-KwTrendBudget $BaseDir $policy $now
    if ($budget.blocked -or ($budget.spent + $est.cost_cny) -gt $budget.limit) {
      if (-not $NoWrite) { Set-KwTrendBlockerStatus $BaseDir "budget_exceeded" "本周 AI 预算不足，未调用" $now $hotSummary }
      return [pscustomobject]@{ ok = $false; status = "budget_exceeded"; message = "本周 AI 预算不足，未调用"; budget = $budget; estimate_cny = $est.cost_cny; signals_count = $signals.Count; sources = $hotSummary }
    }

  $invokeError = ""
  $res = $null
  try {
    if ($null -ne $AiInvoker) {
      $res = & $AiInvoker $ai $prompt.system $prompt.user
    } else {
      if (-not (Get-Command Invoke-AiChat -ErrorAction SilentlyContinue)) {
        . (Join-Path $script:KwTrendLibDir "ai.ps1")
      }
      $aiCfg = [pscustomobject]@{ api_key = $ai.api_key; base_url = $ai.base_url; model = $ai.model; timeout = $ai.timeout; max_tokens = [int]$policy.ai_max_tokens }
      $res = Invoke-AiChat $aiCfg $prompt.system $prompt.user -JsonMode -MaxTokens ([int]$policy.ai_max_tokens)
    }
  } catch { $invokeError = $_.Exception.Message; $res = [pscustomobject]@{ ok = $false; text = ""; error = $invokeError } }

  $usage = @{ prompt_tokens = $est.prompt_tokens; completion_tokens = $est.completion_tokens; cost_cny = $est.cost_cny }
  if ($null -ne $res -and $res.usage) {
    try {
      $pt = [int]$res.usage.prompt_tokens
      $ct = [int]$res.usage.completion_tokens
      if ($pt -gt 0 -or $ct -gt 0) {
        if ($pt -le 0) { $pt = $est.prompt_tokens }
        if ($ct -le 0) { $ct = $est.completion_tokens }
        $usage = @{ prompt_tokens = $pt; completion_tokens = $ct; cost_cny = (Get-KwTrendCost $pt $ct $policy) }
      }
    } catch { }
  }
  if ($null -eq $res -or -not $res.ok) {
    $err = ""
    if ($null -ne $res) { $err = [string]$res.error }
    if (-not $err) { $err = $invokeError }
    $err = ConvertTo-KwText $err 300
    if (-not $NoWrite) {
      $state = Read-KwTrendState $BaseDir
      $state["hot_sources"] = $hotSummary
      $state["last_attempt_at"] = $now.ToString("o")
      $state["last_status"] = "ai_error"
      $state["last_error"] = $err
      $state["usage"] = @($state["usage"]) + @([pscustomobject]@{ at = $now.ToString("o"); prompt_tokens = $usage.prompt_tokens; completion_tokens = $usage.completion_tokens; cost_cny = $usage.cost_cny; status = "ai_error" })
      Save-KwTrendState $BaseDir $state
    }
    return [pscustomobject]@{ ok = $false; status = "ai_error"; message = $err; budget = $budget; estimate_cny = $est.cost_cny; signals_count = $signals.Count; sources = $hotSummary }
  }

  $parsed = ConvertFrom-KwAiSuggestions ([string]$res.text) $signals $existing $Config $policy $BaseDir
  if (-not $parsed.ok) {
    if (-not $NoWrite) {
      $state = Read-KwTrendState $BaseDir
      $state["hot_sources"] = $hotSummary
      $state["last_attempt_at"] = $now.ToString("o")
      $state["last_status"] = "ai_invalid"
      $state["last_error"] = "AI 返回无法解析为 JSON 建议"
      $state["usage"] = @($state["usage"]) + @([pscustomobject]@{ at = $now.ToString("o"); prompt_tokens = $usage.prompt_tokens; completion_tokens = $usage.completion_tokens; cost_cny = $usage.cost_cny; status = "ai_invalid" })
      Save-KwTrendState $BaseDir $state
    }
    return [pscustomobject]@{ ok = $false; status = "ai_invalid"; message = "AI 返回无法解析为 JSON 建议"; budget = $budget; estimate_cny = $est.cost_cny; signals_count = $signals.Count; sources = $hotSummary }
  }

  if ($parsed.suggestions.Count -eq 0) {
    if (-not $NoWrite) {
      $state = Read-KwTrendState $BaseDir
      $state["hot_sources"] = $hotSummary
      $state["last_attempt_at"] = $now.ToString("o")
      $state["last_success_at"] = $now.ToString("o")
      $state["last_status"] = "no_suggestions"
      $state["last_error"] = ""
      $state["usage"] = @($state["usage"]) + @([pscustomobject]@{ at = $now.ToString("o"); prompt_tokens = $usage.prompt_tokens; completion_tokens = $usage.completion_tokens; cost_cny = $usage.cost_cny; status = "no_suggestions" })
      Save-KwTrendState $BaseDir $state
    }
    return [pscustomobject]@{ ok = $true; status = "no_suggestions"; message = "AI 未给出有依据的建议"; suggestions = @(); rejected = $parsed.rejected; budget = $budget; estimate_cny = $est.cost_cny; signals_count = $signals.Count; sources = $hotSummary }
  }

  $batchId = "kwt-" + $now.ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)
  $batch = [ordered]@{
    id             = $batchId
    created_at     = $now.ToString("o")
    week_key       = Get-KwWeekKey $now
    model          = $ai.model
    status         = "suggested"
    signals_count  = $signals.Count
    window_days    = $policy.ai_window_days
    usage          = $usage
    sources_status = $hotSummary
    suggestions    = @($parsed.suggestions)
    rejected       = @($parsed.rejected)
    applied_at     = $null
    rolled_back_at = $null
    results        = @()
  }
  if (-not $NoWrite) {
    Save-KwTrendBatch $BaseDir $batch
    $state = Read-KwTrendState $BaseDir
    $state["last_attempt_at"] = $now.ToString("o")
    $state["last_success_at"] = $now.ToString("o")
    $state["last_status"] = "suggested"
    $state["last_error"] = ""
    $state["last_batch_id"] = $batchId
    $state["usage"] = @($state["usage"]) + @([pscustomobject]@{ at = $now.ToString("o"); prompt_tokens = $usage.prompt_tokens; completion_tokens = $usage.completion_tokens; cost_cny = $usage.cost_cny; status = "suggested" })
    Save-KwTrendState $BaseDir $state
  }
  return [pscustomobject]@{ ok = $true; status = "suggested"; message = "已生成建议，等待人工应用"; batch = $batch; suggestions = @($parsed.suggestions); rejected = @($parsed.rejected); budget = $budget; estimate_cny = $est.cost_cny; signals_count = $signals.Count; sources = $hotSummary }
  } finally {
    if ($null -ne $lockHandle) { Exit-KwTrendLock $lockHandle }
  }
}

function Get-KwTrendView([string]$BaseDir, $Config, [int]$BatchLimit = 8, $Now = $null) {
  $state = Read-KwTrendState $BaseDir
  $policy = Get-KwPolicy $Config
  $ai = Get-KwAiSettings $Config
  $budget = Get-KwTrendBudget $BaseDir $policy $Now
  $lastBatch = $null
  if ($state["last_batch_id"]) { $lastBatch = Get-KwTrendBatch $BaseDir $state["last_batch_id"] }
  return [pscustomobject]@{
    ok             = $true
    generated_at   = (Get-KwNow $Now).ToString("o")
    due            = Test-KwTrendDue $BaseDir $Now
    last_attempt_at = $state["last_attempt_at"]
    last_success_at = $state["last_success_at"]
    last_status    = $state["last_status"]
    last_error     = $state["last_error"]
    last_batch_id  = $state["last_batch_id"]
    sources        = $state["hot_sources"]
    ai             = [pscustomobject]@{ configured = $ai.has_key; masked = $ai.masked; base_url = $ai.base_url; model = $ai.model; enabled = $policy.ai_enabled; window_days = $policy.ai_window_days; max_suggestions = $policy.ai_max_suggestions }
    budget         = $budget
    batches        = @(Get-KwTrendBatches $BaseDir $BatchLimit)
    last_batch     = $lastBatch
  }
}

function Get-KwTrendBatchView([string]$BaseDir, [string]$BatchId) {
  $b = Get-KwTrendBatch $BaseDir $BatchId
  if ($null -eq $b) { return [pscustomobject]@{ ok = $false; error = "batch_not_found" } }
  return [pscustomobject]@{ ok = $true; batch = $b }
}

function Get-KwEntryBefore($Entry) {
  return [ordered]@{
    existed              = ($null -ne $Entry)
    sleep_until          = if ($null -ne $Entry) { [string]$Entry["sleep_until"] } else { $null }
    sleep_level          = if ($null -ne $Entry) { [int]$Entry["sleep_level"] } else { 0 }
    sleep_source         = if ($null -ne $Entry) { [string]$Entry["sleep_source"] } else { "" }
    manual_pruned        = if ($null -ne $Entry) { [bool]$Entry["manual_pruned"] } else { $false }
    protected            = if ($null -ne $Entry) { [bool]$Entry["protected"] } else { $false }
    weight               = if ($null -ne $Entry) { [double]$Entry["weight"] } else { 1.0 }
    consecutive_zero_rounds = if ($null -ne $Entry) { [int]$Entry["consecutive_zero_rounds"] } else { 0 }
    recovered_at         = if ($null -ne $Entry) { [string]$Entry["recovered_at"] } else { $null }
  }
}

function Apply-KwTrendBatch([string]$BaseDir, [string]$ConfigPath, [string]$BatchId, $Now = $null) {
  if (-not $ConfigPath) { $ConfigPath = [IO.Path]::Combine($BaseDir, "config.json") }
  if (-not (Test-Path -LiteralPath $ConfigPath)) { return [pscustomobject]@{ ok = $false; error = "config_not_found" } }
  $batch = Get-KwTrendBatch $BaseDir $BatchId
  if ($null -eq $batch) { return [pscustomobject]@{ ok = $false; error = "batch_not_found" } }
  if ([string]$batch.status -ne "suggested") { return [pscustomobject]@{ ok = $false; error = "batch_not_suggested"; status = [string]$batch.status } }
  $origConfigText = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  $config = $null
  try { $config = $origConfigText | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; error = "config_invalid" } }
  $origStats = Read-KwStats $BaseDir
  $stats = Read-KwStats $BaseDir
  $now = Get-KwNow $Now
  $results = @()
  $configChanged = $false
  $statsChanged = $false
  $applied = 0

  foreach ($s in @($batch.suggestions)) {
    if ($null -eq $s) { continue }
    $action = ([string]$s.action).Trim().ToLowerInvariant()
    $platform = ([string]$s.platform).Trim()
    $keyword = ([string]$s.keyword).Trim()
    $status = "skipped"; $reason = "unsupported"
    if (-not $keyword -or -not (Test-KwSafeKeyword $keyword)) {
      $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "skipped"; reason = "unsafe_keyword" }
      continue
    }
    if ($action -eq "add") {
      $bucket = Get-KwDiscoveryBucket $config $platform $true
      if ($null -eq $bucket) { $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "skipped"; reason = "unsupported_platform" }; continue }
      $exists = $false
      foreach ($x in @($bucket)) { if (([string]$x).Trim().ToLowerInvariant() -eq $keyword.ToLowerInvariant()) { $exists = $true; break } }
      if ($exists) { $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "skipped"; reason = "already_exists" }; continue }
      $new = @($bucket) + @($keyword)
      $config.strategy.$platform.discovery.keywords = $new
      $s | Add-Member -NotePropertyName before -NotePropertyValue ([ordered]@{ present = $false; keyword = $keyword }) -Force
      $s | Add-Member -NotePropertyName after -NotePropertyValue ([ordered]@{ present = $true; keyword = $keyword }) -Force
      $s.status = "applied"
      $configChanged = $true; $applied++
      $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "applied"; reason = "added" }
      continue
    }
    if ($action -eq "revive" -or $action -eq "downweight") {
      $entry = Get-KwEntry $stats $platform $keyword $false
      if ($null -eq $entry) { $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "skipped"; reason = "not_tracked" }; continue }
      if ([bool]$entry["protected"]) { $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "skipped"; reason = "protected" }; continue }
      $before = Get-KwEntryBefore $entry
      if ($action -eq "revive") {
        $entry["manual_pruned"] = $false
        $entry["sleep_until"] = $null
        $entry["sleep_source"] = ""
        $entry["sleep_level"] = 0
        $entry["consecutive_zero_rounds"] = 0
        $entry["weight"] = 1.0
        $entry["recovered_at"] = $now.ToString("o")
        $after = Get-KwEntryBefore $entry
        $s | Add-Member -NotePropertyName before -NotePropertyValue $before -Force
        $s | Add-Member -NotePropertyName after -NotePropertyValue $after -Force
        $s.status = "applied"
        $statsChanged = $true; $applied++
        $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "applied"; reason = "revived" }
      } else {
        $entry["weight"] = 0.5
        $after = Get-KwEntryBefore $entry
        $s | Add-Member -NotePropertyName before -NotePropertyValue $before -Force
        $s | Add-Member -NotePropertyName after -NotePropertyValue $after -Force
        $s.status = "applied"
        $statsChanged = $true; $applied++
        $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "applied"; reason = "downweighted" }
      }
      continue
    }
    $results += [pscustomobject]@{ action = $action; platform = $platform; keyword = $keyword; status = "skipped"; reason = "bad_action" }
  }

  if ($applied -eq 0) {
    $batch.status = "no_changes"
    $batch.results = @($results)
    Save-KwTrendBatch $BaseDir $batch
    return [pscustomobject]@{ ok = $true; status = "no_changes"; batch = $batch; results = @($results) }
  }

  try {
    if ($configChanged) {
      $json = $config | ConvertTo-Json -Depth 16
      Write-KwTextFilePreserveBom $ConfigPath $json
    }
    if ($statsChanged) { Save-KwStats $BaseDir $stats | Out-Null }
  } catch {
    $err = $_.Exception.Message
    try { if ($configChanged) { Write-KwTextFilePreserveBom $ConfigPath $origConfigText } } catch { }
    try { if ($statsChanged) { Save-KwStats $BaseDir $origStats | Out-Null } } catch { }
    return [pscustomobject]@{ ok = $false; error = "save_failed"; detail = (ConvertTo-KwText $err 200) }
  }

  $batch.status = "applied"
  $batch.applied_at = $now.ToString("o")
  $batch.results = @($results)
  Save-KwTrendBatch $BaseDir $batch
  return [pscustomobject]@{ ok = $true; status = "applied"; batch = $batch; results = @($results) }
}

function Test-KwEntryAfter($Entry, $After) {
  if ($null -eq $Entry -or $null -eq $After) { return $false }
  if ([int]$Entry["sleep_level"] -ne [int]$After.sleep_level) { return $false }
  if ([bool]$Entry["manual_pruned"] -ne [bool]$After.manual_pruned) { return $false }
  if ([double]$Entry["weight"] -ne [double]$After.weight) { return $false }
  return $true
}

function Rollback-KwTrendBatch([string]$BaseDir, [string]$ConfigPath, [string]$BatchId, $Now = $null) {
  if (-not $ConfigPath) { $ConfigPath = [IO.Path]::Combine($BaseDir, "config.json") }
  if (-not (Test-Path -LiteralPath $ConfigPath)) { return [pscustomobject]@{ ok = $false; error = "config_not_found" } }
  $batch = Get-KwTrendBatch $BaseDir $BatchId
  if ($null -eq $batch) { return [pscustomobject]@{ ok = $false; error = "batch_not_found" } }
  if ([string]$batch.status -ne "applied") { return [pscustomobject]@{ ok = $false; error = "batch_not_applied"; status = [string]$batch.status } }
  $origConfigText = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  $config = $null
  try { $config = $origConfigText | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; error = "config_invalid" } }
  $origStats = Read-KwStats $BaseDir
  $stats = Read-KwStats $BaseDir
  $now = Get-KwNow $Now
  $results = @()
  $configChanged = $false
  $statsChanged = $false
  $restored = 0

  foreach ($s in @($batch.suggestions)) {
    if ($null -eq $s) { continue }
    if ([string]$s.status -ne "applied") { continue }
    $action = ([string]$s.action).Trim().ToLowerInvariant()
    $platform = ([string]$s.platform).Trim()
    $keyword = ([string]$s.keyword).Trim()
    if ($action -eq "add") {
      $bucket = Get-KwDiscoveryBucket $config $platform $false
      if ($null -eq $bucket) { $results += [pscustomobject]@{ action = $action; keyword = $keyword; status = "conflict"; reason = "platform_missing" }; continue }
      $keep = @(); $found = $false
      foreach ($x in @($bucket)) {
        if (-not $found -and ([string]$x).Trim().ToLowerInvariant() -eq $keyword.ToLowerInvariant()) { $found = $true; continue }
        $keep += $x
      }
      if (-not $found) { $results += [pscustomobject]@{ action = $action; keyword = $keyword; status = "skipped"; reason = "already_absent" }; continue }
      $config.strategy.$platform.discovery.keywords = @($keep)
      $configChanged = $true; $restored++
      $results += [pscustomobject]@{ action = $action; keyword = $keyword; status = "rolled_back"; reason = "removed" }
      continue
    }
    if ($action -eq "revive" -or $action -eq "downweight") {
      $entry = Get-KwEntry $stats $platform $keyword $false
      if ($null -eq $entry) { $results += [pscustomobject]@{ action = $action; keyword = $keyword; status = "conflict"; reason = "missing" }; continue }
      if (-not (Test-KwEntryAfter $entry $s.after)) { $results += [pscustomobject]@{ action = $action; keyword = $keyword; status = "conflict"; reason = "changed_since_apply" }; continue }
      $before = $s.before
      $entry["sleep_until"] = $before.sleep_until
      $entry["sleep_level"] = [int]$before.sleep_level
      $entry["sleep_source"] = [string]$before.sleep_source
      $entry["manual_pruned"] = [bool]$before.manual_pruned
      $entry["protected"] = [bool]$before.protected
      $entry["weight"] = [double]$before.weight
      $entry["consecutive_zero_rounds"] = [int]$before.consecutive_zero_rounds
      $entry["recovered_at"] = $before.recovered_at
      $statsChanged = $true; $restored++
      $results += [pscustomobject]@{ action = $action; keyword = $keyword; status = "rolled_back"; reason = "restored" }
      continue
    }
  }

  if ($restored -eq 0) {
    $batch.status = "no_changes"
    $batch.results = @($results)
    Save-KwTrendBatch $BaseDir $batch
    return [pscustomobject]@{ ok = $true; status = "no_changes"; batch = $batch; results = @($results) }
  }
  try {
    if ($configChanged) {
      $json = $config | ConvertTo-Json -Depth 16
      Write-KwTextFilePreserveBom $ConfigPath $json
    }
    if ($statsChanged) { Save-KwStats $BaseDir $stats | Out-Null }
  } catch {
    $err = $_.Exception.Message
    try { if ($configChanged) { Write-KwTextFilePreserveBom $ConfigPath $origConfigText } } catch { }
    try { if ($statsChanged) { Save-KwStats $BaseDir $origStats | Out-Null } } catch { }
    return [pscustomobject]@{ ok = $false; error = "save_failed"; detail = (ConvertTo-KwText $err 200) }
  }
  $batch.status = "rolled_back"
  $batch.rolled_back_at = $now.ToString("o")
  $batch.results = @($results)
  Save-KwTrendBatch $BaseDir $batch
  return [pscustomobject]@{ ok = $true; status = "rolled_back"; batch = $batch; results = @($results) }
}
