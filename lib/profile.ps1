# lib/profile.ps1 -- 业务画像 + 平台检索包（查询词 / 意图正则 / 子版）
# 说明：本文件只负责「生成」与「读写」；抓取脚本不得写死任何词或正则。

function Get-GOpsProfile($cfg) {
  if ($cfg -and $cfg.profile) { return $cfg.profile }
  return $null
}

function Get-IntentCatalog([string]$type) {
  # 意图目录：只作为「生成器的原料」，不是抓取时写死的规则
  $base = @(
    @{ id = "price_check"; weight = 0.9; terms = @("worth", "how much", "price check", "pc ", "should i sell", "overpay", "price?") },
    @{ id = "showcase";    weight = 0.8; terms = @("unboxed", "unboxing", "got this", "pulled", "finally got", "drop") },
    @{ id = "complain";    weight = 0.7; terms = @("expensive", "price went", "inflat", "scam", "overpriced", "nerf") },
    @{ id = "want_buy";    weight = 0.85; terms = @("looking for", "wtb", "want to buy", "anyone selling", "need a") }
  )
  if ($type -eq "case_opening") {
    $base += @{ id = "opening_urge"; weight = 0.75; terms = @("open a case", "case opening", "keys", "opened", "lucky") }
  }
  if ($type -eq "trading") {
    $base += @{ id = "trade_offer"; weight = 0.8; terms = @("trade", "trading", "offer", "swap", "float") }
  }
  return $base
}

function Get-QuerySeeds([string]$type, [string[]]$langs) {
  $en = switch ($type) {
    "case_opening" { @("case opening", "unboxed", "keys") }
    "trading"      { @("trade", "float", "tradeup") }
    default        { @("cs2", "trade") }
  }
  $extra = @()
  if ($langs -match "ru") { $extra += @("кс2 кейсы") }
  if ($langs -match "pt") { $extra += @("abrir caixa") }
  if ($langs -match "tr") { $extra += @("kasa açma") }
  return @($en + $extra | Select-Object -Unique)
}

function New-GOpsProfilePack($cfg, [string]$text) {
  $t = [string]$text
  $type = "community"
  if ($t -match "(?i)(开箱|箱子|opening|case|crate|roulette|upgrade)") { $type = "case_opening" }
  elseif ($t -match "(?i)(交易|买卖|trade|market|sell|buy)") { $type = "trading" }

  $regions = @()
  if ($t -match "巴西|BR")     { $regions += "BR" }
  if ($t -match "俄罗斯|俄语|RU") { $regions += "RU" }
  if ($t -match "土耳其|TR")    { $regions += "TR" }
  if ($t -match "东南亚|SEA")   { $regions += "SEA" }
  if (-not $regions) { $regions = @("US", "EU") }

  $langMap = @{ BR = "pt"; RU = "ru"; TR = "tr"; SEA = "en,id"; US = "en"; EU = "en,de,pl" }
  $langs = @()
  foreach ($r in $regions) { if ($langMap[$r]) { $langs += $langMap[$r].Split(",") } }
  $langs = @($langs | Select-Object -Unique)

  $exclude = @()
  if ($t -match "(?i)(不要|排除).{0,10}(战队|招募|tryout)") { $exclude += "team_recruit" }
  if ($t -match "(?i)(找队友|lfg|teammate)") { $exclude += "lfg" }

  $intents = Get-IntentCatalog $type
  $intentRegex = @{}
  foreach ($i in $intents) {
    if ($exclude -contains $i.id) { continue }
    $intentRegex[$i.id] = "(?i)" + (($i.terms | ForEach-Object { [regex]::Escape($_) }) -join "|")
  }

  $seeds = Get-QuerySeeds $type $langs

  $reddit = [pscustomobject]@{
    subs         = @("GlobalOffensiveTrade", "cs2", "GlobalOffensive", "csgotrade")
    queries      = $seeds
    require      = '(?i)(cs2|csgo|counter[\s-]?strike|skin|knife|knives|glove|case|unbox|trade|float|price|inventory|market)'
    drop         = '(?i)(hotkey|keybind|keyboard|sensitiv|npc|map for|trainer|coach|custom map|fps|ping|lag|cheat|hack|ban|vac)'
    intent_regex = $intentRegex
    per_query    = 20
    wait_sec     = 7
  }
  $telegram = [pscustomobject]@{
    queries      = $seeds
    intent_regex = $intentRegex
  }
  $facebook = [pscustomobject]@{
    queries      = $seeds
    intent_regex = $intentRegex
  }

  return [pscustomobject]@{
    version       = 1
    generated_at  = (Get-Date).ToString("s")
    generator     = "rules@v1"
    source        = $t
    business_type = $type
    regions       = $regions
    langs         = $langs
    exclude       = $exclude
    intents       = $intents
    platforms     = [pscustomobject]@{ Reddit = $reddit; Telegram = $telegram; Facebook = $facebook }
  }
}

function Save-GOpsProfile([string]$configPath, $cfg, $profile) {
  $cfg | Add-Member -NotePropertyName profile -NotePropertyValue $profile -Force
  $json = $cfg | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $profile
}
