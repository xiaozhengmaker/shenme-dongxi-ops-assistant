param(
  [string[]]$Text,
  [string]$InFile,
  [string]$From = "manual",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = "D:\DeepSeek\运营"
$poolDir = Join-Path $root "data\pools"
if (-not (Test-Path $poolDir)) { New-Item -ItemType Directory -Path $poolDir -Force | Out-Null }
$cross = Join-Path $root "data\crosslinks.jsonl"

$patterns = @(
  @{ platform = "Telegram";  regex = 't\.me/(?:joinchat/)?([A-Za-z0-9_\-]{4,})' },
  @{ platform = "WhatsApp";  regex = 'chat\.whatsapp\.com/([A-Za-z0-9]{10,})' },
  @{ platform = "Discord";   regex = 'discord(?:app)?\.(?:gg|com/invite)/([A-Za-z0-9\-]{4,})' },
  @{ platform = "Steam";     regex = 'steamcommunity\.com/groups/([A-Za-z0-9_\-\.]{2,})' },
  @{ platform = "Reddit";    regex = 'reddit\.com/(r/[A-Za-z0-9_]{2,})' }
)

$corpus = New-Object System.Collections.ArrayList
if ($InFile -and (Test-Path $InFile)) { foreach ($l in [System.IO.File]::ReadAllLines($InFile, [System.Text.Encoding]::UTF8)) { [void]$corpus.Add($l) } }
foreach ($t in $Text) { if ($t) { [void]$corpus.Add($t) } }
if ($corpus.Count -eq 0) { "ERR: 没有输入文本"; exit 2 }

$stamp = (Get-Date).ToString("yyyy/MM/dd HH:mm:ss")
$found = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($line in $corpus) {
  foreach ($p in $patterns) {
    foreach ($m in [regex]::Matches($line, $p.regex, "IgnoreCase")) {
      $code = $m.Groups[1].Value
      $key = "$($p.platform)|$code".ToLower()
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = 1
      [void]$found.Add([pscustomobject]@{ platform = $p.platform; code = $code; from = $From; ts = $stamp })
    }
  }
}

"FOUND: $($found.Count)"
foreach ($g in ($found | Group-Object platform)) { "  $($g.Name) = $($g.Count)" }
if ($DryRun) { $found | Select-Object -First 20 | Format-Table -AutoSize | Out-String; exit 0 }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$sb = New-Object System.Text.StringBuilder
foreach ($f in $found) {
  $null = $sb.AppendLine((@{ ts = $f.ts; from = $f.from; platform = $f.platform; code = $f.code } | ConvertTo-Json -Compress))
}
[System.IO.File]::AppendAllText($cross, $sb.ToString(), $utf8)

# 汇总进各平台候选池（结构：{savedAt, platform, count, items:[{u,title,n,q,src}]}）
$byPlat = $found | Group-Object platform
foreach ($g in $byPlat) {
  $pf = Join-Path $poolDir ("candidates_" + $g.Name + ".json")
  $obj = $null
  if (Test-Path $pf) {
    try { $obj = [System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $obj = $null }
  }
  if (-not $obj) { $obj = [pscustomobject]@{ savedAt = $stamp; platform = $g.Name; count = 0; items = @() } }
  $items = New-Object System.Collections.ArrayList
  foreach ($it in @($obj.items)) { if ($it) { [void]$items.Add($it) } }
  $have = @{}
  foreach ($it in $items) { $have[([string]$it.u).ToLower()] = 1 }
  $added = 0
  foreach ($f in $g.Group) {
    $u = if ($f.platform -eq "Telegram") { "@" + $f.code } else { $f.code }
    if ($have.ContainsKey($u.ToLower())) { continue }
    $have[$u.ToLower()] = 1
    [void]$items.Add([pscustomobject]@{ u = $u; title = $f.code; n = 0; q = "crosslink"; src = "互推:" + $From })
    $added++
  }
  $out = [pscustomobject]@{ savedAt = $stamp; platform = $g.Name; count = $items.Count; items = $items.ToArray() }
  [System.IO.File]::WriteAllText($pf, ($out | ConvertTo-Json -Depth 6), $utf8)
  "  POOL $($g.Name): +$added -> $($items.Count)"
}
"WROTE: $cross"
