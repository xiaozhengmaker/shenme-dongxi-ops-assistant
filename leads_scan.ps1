# leads_scan.ps1 -- P0: 从 Reddit 旧版页面抓「信号」（不接 AI）
param(
  [string[]]$Keywords = @(),
  [string[]]$Subs = @(),
  [int]$PerQuery = 0,
  [int]$WaitSec = 7,
  [switch]$SkipNavigate,
  [switch]$ShowAllIntent,
  [string]$PromoRegex = "",
  [string]$RequireRegex = '(?i)(cs2|csgo|counter[\s-]?strike|skin|knife|knives|glove|case|unbox|trade|float|price|inventory|market)',
  [string]$DropRegex = '(?i)(hotkey|keybind|key bind|keyboard|config|sensitiv|fps|ping|lag|cheat|hack|ban|vac|girls|malaysia)'
)
$ErrorActionPreference = "Stop"
$baseDir = "D:\DeepSeek\运营"
. (Join-Path $baseDir "lib\log.ps1")
Set-LogFile (Join-Path $baseDir "logs\leads_scan.log")
$cdp = Join-Path $baseDir "cdp_call.ps1"
$outFile = Join-Path $baseDir "data\leads_signals.json"

# --- 平台检索包：一律来自业务画像，脚本内不写死 ---
. (Join-Path $baseDir "lib\profile.ps1")
$cfg = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$pack = $null
$prof = Get-GOpsProfile $cfg
if ($prof -and $prof.platforms -and $prof.platforms.Reddit) { $pack = $prof.platforms.Reddit }
if ($pack) {
  if (-not $Keywords -or $Keywords.Count -eq 0) { $Keywords = @($pack.queries) }
  if (-not $Subs -or $Subs.Count -eq 0) { $Subs = @($pack.subs) }
  if ($PerQuery -le 0) { $PerQuery = [int]$pack.per_query }
  if ($pack.require) { $RequireRegex = [string]$pack.require }
  if ($pack.drop) { $DropRegex = [string]$pack.drop }
  if ($pack.promo) { $PromoRegex = [string]$pack.promo }
  if ($WaitSec -le 0) { $WaitSec = [int]$pack.wait_sec }
} else {
  Say "WARN 没有业务画像（config.profile），先跑 POST /api/profile/generate"
}

function Say([string]$m) { Write-Log ("[leads] " + $m) }

$intentMap = @()
if ($pack -and $pack.intent_regex) {
  foreach ($pp in $pack.intent_regex.PSObject.Properties) {
    $intentMap += [pscustomobject]@{ id = $pp.Name; rx = [string]$pp.Value }
  }
}

function Get-IntentTag([string]$title) {
  $hit = @()
  foreach ($im in $intentMap) {
    if ($title -match $im.rx) { $hit += $im.id }
  }
  if ((@($intentMap | ForEach-Object { $_.id }) -contains "team_recruit") -eq $false) { }
  return ($hit -join ",")
}

$rows = @()
$queries = 0
$fails = 0
$script:Dropped = 0
$script:Promo = 0

$js = @'
(() => {
  const out = [];
  const nodes = Array.from(document.querySelectorAll('.search-result-link, .search-result'));
  for (const r of nodes) {
    const a = r.querySelector('a.search-title, a.title');
    if (!a) continue;
    const g = (sel) => { const e = r.querySelector(sel); return e ? (e.textContent || '').trim() : ''; };
    out.push({
      title: (a.textContent || '').trim(),
      url: a.href,
      author: g('a.author'),
      sub: g('.search-subreddit-link'),
      timeText: g('time'),
      comments: g('.search-comments')
    });
  }
  return JSON.stringify({ rows: out, bodyLen: (document.body ? document.body.innerText.length : 0) });
})()
'@

$multi = (@($Subs) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "+"
foreach ($kw in $Keywords) {
  foreach ($sub in @($multi)) {
    $q = [uri]::EscapeDataString('"' + $kw + '"')
    $tw = "month"; if ($pack -and $pack.window) { $tw = [string]$pack.window }
  $url = "https://old.reddit.com/r/$multi/search?q=$q&restrict_sr=on&sort=new&t=$tw&limit=$PerQuery"
    if (-not $SkipNavigate) {
      $np = @{ url = $url } | ConvertTo-Json -Compress
      & $cdp -Method "Page.navigate" -ParamsJson $np -Match "old.reddit.com" | Out-Null
      Start-Sleep -Seconds $WaitSec
    }
    $p = @{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress
    $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "old.reddit.com"
    $queries++
    $inner = $null
    try {
      $outer = $raw | ConvertFrom-Json
      $inner = $outer.result.value | ConvertFrom-Json
    } catch { }
    if ($raw -match "is a private community|is now closed") {
      Say ("SKIP " + $sub + " / " + $kw + " (private)")
      continue
    }
    if (-not $inner -or $inner.bodyLen -lt 500) {
      $fails++
      Say ("FAIL " + $sub + " / " + $kw)
      continue
    }
    $n = 0
    foreach ($r in @($inner.rows)) {
      if (-not $r.url) { continue }
      $tt = [string]$r.title
      if ($Dropped -eq $null) { $Dropped = 0 }
      if ($tt -notmatch $RequireRegex -or $tt -match $DropRegex) { $script:Dropped++; continue }
      if ($PromoRegex -and $tt -match $PromoRegex) { $script:Promo++; continue }
      $intentTag = Get-IntentTag $tt
      if (-not $intentTag -and -not $ShowAllIntent) { $script:Dropped++; continue }
      $rows += [pscustomobject]@{
        platform  = "Reddit"
        sub       = [string]$r.sub
        keyword   = $kw
        title     = [string]$r.title
        url       = [string]$r.url
        author    = [string]$r.author
        time_text = [string]$r.timeText
        comments  = [string]$r.comments
        intent    = $intentTag
        scanned_at = (Get-Date).ToString("s")
      }
      $n++
    }
    Say ("OK   " + $sub + " / " + $kw + " -> " + $n)
  }
}

# 去重：同 URL 只留一条；标记刷屏（同作者同标题出现 >2 次）
$uniq = @{}
$authorTitle = @{}
foreach ($r in $rows) {
  if (-not $uniq.ContainsKey($r.url)) { $uniq[$r.url] = $r }
  $k = ($r.author + "|" + $r.title)
  if (-not $authorTitle.ContainsKey($k)) { $authorTitle[$k] = 0 }
  $authorTitle[$k] = $authorTitle[$k] + 1
}
$list = @()
foreach ($r in $uniq.Values) {
  $k = ($r.author + "|" + $r.title)
  $spam = ($authorTitle[$k] -gt 2)
  $store = ($r.title -match '^\s*\[(store|h|w)\]')
  $r | Add-Member -NotePropertyName spam -NotePropertyValue $spam -Force
  $r | Add-Member -NotePropertyName store -NotePropertyValue $store -Force
  $list += $r
}

$payload = [pscustomobject]@{
  scanned_at = (Get-Date).ToString("s")
  queries    = $queries
  fails      = $fails
  raw        = $rows.Count
  dropped    = $script:Dropped
  promo_hidden = $script:Promo
  unique     = $list.Count
  items      = $list
}
$json = $payload | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))

Say ("DONE queries=" + $queries + " fails=" + $fails + " raw=" + $rows.Count + " dropped=" + $script:Dropped + " unique=" + $list.Count)
Say ("WROTE " + $outFile)
$list | Group-Object keyword | Sort-Object Count -Descending | ForEach-Object { Say ("  " + $_.Name + ": " + $_.Count) }
