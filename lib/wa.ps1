param(
  [string]$BaseDir = (Split-Path -Parent $PSScriptRoot)
)

$script:WaDir = Join-Path $BaseDir "data"
$script:WaJson = Join-Path $script:WaDir "wa_candidates.json"
$script:WaCsv = Join-Path $script:WaDir "wa_candidates.csv"

function Get-WaConfig {
  $p = Join-Path $BaseDir "config.json"
  $cfg = $null
  try { $cfg = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $cfg = $null }
  if (-not $cfg) { return [pscustomobject]@{ mode = "search_only"; max_join = 0; exclude = @() } }
  if ($cfg.PSObject.Properties.Name -contains "wa") { return $cfg.wa }
  return [pscustomobject]@{ mode = "search_only"; max_join = 0; exclude = @() }
}

function Get-WaState {
  if (Test-Path $script:WaJson) {
    try {
      $o = [System.IO.File]::ReadAllText($script:WaJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($o -and $o.PSObject.Properties.Name -contains "items") { return $o }
    } catch {}
  }
  return [pscustomobject]@{ savedAt = ""; queries = @(); items = @() }
}

function Save-WaState($state) {
  if (-not (Test-Path $script:WaDir)) { New-Item -ItemType Directory -Path $script:WaDir -Force | Out-Null }
  $state.savedAt = (Get-Date).ToString("s")
  $json = $state | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($script:WaJson, $json, (New-Object System.Text.UTF8Encoding($false)))
  $rows = @()
  foreach ($it in @($state.items)) {
    $rows += [pscustomobject]@{
      "邀请码"   = $it.code
      "群名"     = $it.name
      "国家"     = $it.region
      "语言"     = $it.lang
      "用途"     = $it.purpose
      "相关度"   = $it.relevance
      "邀请链接" = "https://chat.whatsapp.com/" + $it.code
      "来源页面" = ($it.sources -join " ")
      "验证状态" = $it.status
      "加群状态" = $it.join
      "备注"     = $it.note
      "核验时间" = $it.checkedAt
    }
  }
  if ($rows.Count -gt 0) { $rows | Export-Csv -Path $script:WaCsv -NoTypeInformation -Encoding UTF8 }
}

function Get-WaCodeFromUrl([string]$u) {
  if (-not $u) { return "" }
  $m = [regex]::Match($u, "chat\.whatsapp\.com/(?:invite/)?([A-Za-z0-9]{8,})")
  if ($m.Success) { return $m.Groups[1].Value }
  return ""
}

function Find-WaCodesInText([string]$t) {
  $out = @()
  if (-not $t) { return $out }
  foreach ($m in [regex]::Matches($t, "chat\.whatsapp\.com/(?:invite/)?([A-Za-z0-9]{8,})")) {
    $out += $m.Groups[1].Value
  }
  return $out
}

function Get-WaRelevance([string]$name, [string]$desc) {
  $hay = ("" + $name + " " + $desc)
  $cs = "(?i)(counter[\s\-]?strike|cs2|cs:?go|csgo|cs 2)"
  $skin = "(?i)(skin|skins|knife|glove|case|sticker|trade|trading|market|float|doppler|fade)"
  if ($hay -match $cs -and $hay -match $skin) { return "high" }
  if ($hay -match $cs) { return "high" }
  if ($hay -match $skin -and $hay -match "(?i)(cs|fps|gaming|game)") { return "medium" }
  return "pending"
}

function Get-WaPurpose([string]$name, [string]$desc) {
  $hay = ("" + $name + " " + $desc)
  if ($hay -match "(?i)(trade|trading|market|buy|sell|skin|knife|floats?|cashout|price)") { return "饰品交易" }
  if ($hay -match "(?i)(scrim|5v5|pug|10 ?man|tournament|league|esea|camp|campeonato|torneo)") { return "约战比赛" }
  if ($hay -match "(?i)(recruit|tryout|team|clan|roster|equipo|takım|drużyna|команда)") { return "战队招募" }
  if ($hay -match "(?i)(lfg|teammate|looking for|premier|faceit|matchmaking|wingman|mabar|compañero|jugadores|players)") { return "找队友" }
  if ($hay -match "(?i)(community|comunidad|comunidade|grupo|gruppe|groupe|group|chat|fans|discussion)") { return "综合社区" }
  return "未知"
}

function Get-WaLangRegion([string]$name, [string]$desc) {
  $hay = ("" + $name + " " + $desc)
  $lang = "未知"; $region = "未知"
  if ($hay -match "(?i)(grupo|comunidade|troca|venda|compra|jogadores|campeonato)") { $lang = "pt" }
  elseif ($hay -match "(?i)(comunidad|intercambio|compraventa|compañeros|jugadores|torneo|equipo)") { $lang = "es" }
  elseif ($hay -match "(?i)(grup|topluluk|takas|alım|satım|takım|oyuncu)") { $lang = "tr" }
  elseif ($hay -match "(?i)(gruppe|handel|mitspieler|spielersuche)") { $lang = "de" }
  elseif ($hay -match "(?i)(groupe|communauté|échange|achat|vente|joueurs|recrutement)") { $lang = "fr" }
  elseif ($hay -match "(?i)(grupa|społeczność|handel|skiny|wymiana|gracze)") { $lang = "pl" }
  elseif ($hay -match "([\u0400-\u04FF])") { $lang = "ru" }
  elseif ($hay -match "([\u0600-\u06FF])") { $lang = "ar" }
  elseif ($hay -match "(?i)(cs2|csgo|counter|trade|trading|community|players|team)") { $lang = "en" }
  if ($hay -match "(?i)(brasil|brazil|br\b)") { $region = "BR" }
  elseif ($hay -match "(?i)(argentina)") { $region = "AR" }
  elseif ($hay -match "(?i)(méxico|mexico)") { $region = "MX" }
  elseif ($hay -match "(?i)(latam|latinoam)") { $region = "LATAM" }
  elseif ($hay -match "(?i)(turkey|türkiye|türk)") { $region = "TR" }
  elseif ($hay -match "(?i)(poland|polska)") { $region = "PL" }
  elseif ($hay -match "(?i)(germany|deutschland)") { $region = "DE" }
  elseif ($hay -match "(?i)(france|français)") { $region = "FR" }
  elseif ($hay -match "(?i)(indonesia)") { $region = "ID" }
  elseif ($hay -match "(?i)(philippines)") { $region = "PH" }
  elseif ($hay -match "(?i)(malaysia)") { $region = "MY" }
  elseif ($hay -match "(?i)(singapore)") { $region = "SG" }
  elseif ($hay -match "(?i)(india)") { $region = "IN" }
  elseif ($hay -match "(?i)(pakistan)") { $region = "PK" }
  elseif ($hay -match "(?i)(bangladesh)") { $region = "BD" }
  elseif ($hay -match "(?i)(south africa)") { $region = "ZA" }
  elseif ($hay -match "(?i)(saudi|ksa)") { $region = "SA" }
  elseif ($hay -match "(?i)(uae|emirates)") { $region = "AE" }
  elseif ($hay -match "(?i)(australia|oce)") { $region = "AU" }
  elseif ($hay -match "(?i)(\busa\b|united states|north america|\bna\b)") { $region = "US" }
  elseif ($hay -match "(?i)(\buk\b|united kingdom)") { $region = "UK" }
  elseif ($hay -match "(?i)(\beu\b|europe)") { $region = "EU" }
  elseif ($hay -match "(?i)(\bsea\b|southeast asia)") { $region = "SEA" }
  return @{ lang = $lang; region = $region }
}
