# leads_scan.ps1 -- P0: 从 Reddit 旧版页面抓「信号」（不接 AI）
param(
  [string[]]$Keywords = @("case opening", "keys", "unboxing"),
  [string[]]$Subs = @("GlobalOffensiveTrade", "cs2", "GlobalOffensive", "csgotrade"),
  [int]$PerQuery = 25,
  [int]$WaitSec = 7,
  [switch]$SkipNavigate,
  [string]$RequireRegex = '(?i)(cs2|csgo|counter[\s-]?strike|skin|knife|knives|glove|case|unbox|trade|float|price|inventory|market)',
  [string]$DropRegex = '(?i)(hotkey|keybind|key bind|keyboard|config|sensitiv|fps|ping|lag|cheat|hack|ban|vac|girls|malaysia)'
)
$ErrorActionPreference = "Stop"
$baseDir = "D:\DeepSeek\运营"
. (Join-Path $baseDir "lib\log.ps1")
Set-LogFile (Join-Path $baseDir "logs\leads_scan.log")
$cdp = Join-Path $baseDir "cdp_call.ps1"
$outFile = Join-Path $baseDir "data\leads_signals.json"

function Say([string]$m) { Write-Log ("[leads] " + $m) }

$rows = @()
$queries = 0
$fails = 0
$script:Dropped = 0

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

foreach ($kw in $Keywords) {
  foreach ($sub in $Subs) {
    $q = [uri]::EscapeDataString('"' + $kw + '"')
    $url = "https://old.reddit.com/r/$sub/search?q=$q&restrict_sr=on&sort=new&t=month&limit=$PerQuery"
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
      $rows += [pscustomobject]@{
        platform  = "Reddit"
        sub       = [string]$r.sub
        keyword   = $kw
        title     = [string]$r.title
        url       = [string]$r.url
        author    = [string]$r.author
        time_text = [string]$r.timeText
        comments  = [string]$r.comments
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
  $store = ($r.title -match '^\s*\[(store|h|w|q)\]')
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
  unique     = $list.Count
  items      = $list
}
$json = $payload | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))

Say ("DONE queries=" + $queries + " fails=" + $fails + " raw=" + $rows.Count + " dropped=" + $script:Dropped + " unique=" + $list.Count)
Say ("WROTE " + $outFile)
$list | Group-Object keyword | Sort-Object Count -Descending | ForEach-Object { Say ("  " + $_.Name + ": " + $_.Count) }
