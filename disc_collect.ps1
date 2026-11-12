param(
  [string[]]$Keywords,
  [int]$MaxPerKeyword = 60,
  [string]$OutDir = "D:\DeepSeek\运营\data",
  [switch]$DryRun
)

# Discord 邀请链接采集（只读，不加入、不登录）
# 数据源来自 config.json -> strategy.Discord.discovery.{keywords,sources}

# -Keywords 从 -File 传入时是单个逗号串，这里统一拆开
$Keywords = @($Keywords | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
$cfg = [System.IO.File]::ReadAllText((Join-Path $baseDir "config.json"), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$disc = $cfg.strategy.Discord.discovery
if (-not $Keywords -or $Keywords.Count -eq 0) { $Keywords = @($disc.keywords) }
$sources = @($disc.sources | Where-Object { $_.enabled })

if (-not $sources -or $sources.Count -eq 0) { Write-Output "ERR: no enabled sources"; exit 2 }

$ua = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/157.0.0.0 Safari/537.36" }
$csvPath  = Join-Path $OutDir "discord_links.csv"
$jsonPath = Join-Path $OutDir "discord_links.jsonl"
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$seen = @{}
if (Test-Path $jsonPath) {
  foreach ($line in [System.IO.File]::ReadAllLines($jsonPath, [System.Text.Encoding]::UTF8)) {
    if (-not $line.Trim()) { continue }
    try { $o = $line | ConvertFrom-Json; if ($o.code) { $seen[$o.code.ToLower()] = $true } } catch {}
  }
}
if (-not (Test-Path $csvPath)) {
  [System.IO.File]::WriteAllText($csvPath, "发现时间,关键词,邀请码,邀请链接,来源,页面标题`r`n", (New-Object System.Text.UTF8Encoding($true)))
}

$rx = [regex]'(?i)discord(?:app)?\.(?:gg|com/invite)/([A-Za-z0-9\-_]{3,})'
$today = (Get-Date).ToString("yyyy/MM/dd HH:mm:ss")
$added = 0
$scanned = 0

foreach ($kw in $Keywords) {
  foreach ($src in $sources) {
    $url = [string]$src.url_template -replace '\{kw\}', [uri]::EscapeDataString($kw)
    $html = $null
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25 -Headers $ua
      $html = $r.Content
    } catch {
      Write-Output ("WARN fetch failed {0} :: {1}" -f $url, $_.Exception.Message)
      continue
    }
    $scanned++
    $title = ""
    $mt = [regex]::Match($html, '(?is)<title>(.*?)</title>')
    if ($mt.Success) { $title = ($mt.Groups[1].Value -replace '\s+', ' ').Trim() }

    $hit = 0
    foreach ($m in $rx.Matches($html)) {
      if ($hit -ge $MaxPerKeyword) { break }
      $code = $m.Groups[1].Value
      $key = $code.ToLower()
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $hit++
      $added++

      $ctxStart = [Math]::Max(0, $m.Index - 200)
      $ctx = ($html.Substring($ctxStart, [Math]::Min(400, $html.Length - $ctxStart)) -replace '(?s)<[^>]+>', ' ')
      $ctx = ($ctx -replace '\s+', ' ').Trim()
      if ($ctx.Length -gt 160) { $ctx = $ctx.Substring(0, 160) }

      $obj = [ordered]@{
        ts = $today; kw = $kw; code = $code
        url = "https://discord.gg/$code"; src = [string]$src.name
        page = $url; title = $title; ctx = $ctx
      }
      if (-not $DryRun) {
        [System.IO.File]::AppendAllText($jsonPath, (($obj | ConvertTo-Json -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $csvLine = ('"{0}","{1}","{2}","{3}","{4}","{5}"' -f $today, $kw, $code, "https://discord.gg/$code", $src.name, ($title -replace '"',' '))
        [System.IO.File]::AppendAllText($csvPath, ($csvLine + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
      }
    }
    Write-Output ("PAGE {0} kw={1} new={2}" -f $src.name, $kw, $hit)
  }
}

Write-Output ("RESULT: scanned={0} added={1} totalUnique={2}" -f $scanned, $added, $seen.Count)
