param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
. (Join-Path $rootDir "lib\feishu.ps1")

$rows = @()
$jsonl = Join-Path $rootDir "data\users.jsonl"
if (Test-Path $jsonl) {
  foreach ($line in [System.IO.File]::ReadLines($jsonl, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $line = $line.TrimStart([char]0xFEFF)
    try { $rows += ($line | ConvertFrom-Json) } catch { }
  }
}

$today = (Get-Date).ToString("yyyy/MM/dd")
$total = $rows.Count
$withUser = @($rows | Where-Object { $_.username -and [string]$_.username.Trim() -ne "" }).Count
$mods = @($rows | Where-Object { ([string]$_.role) -match "管理员|版主|群主" }).Count
$groups = @($rows | Where-Object { $_.group_key } | ForEach-Object { [string]$_.group_key } | Sort-Object -Unique).Count
$todayNew = @($rows | Where-Object { ([string]$_.collected_at) -eq $today }).Count

$byPlat = @{}
foreach ($r in $rows) {
  $p = [string]$r.platform
  if ([string]::IsNullOrWhiteSpace($p)) { $p = "其他" }
  if (-not $byPlat.ContainsKey($p)) { $byPlat[$p] = 0 }
  $byPlat[$p]++
}
$platSorted = $byPlat.GetEnumerator() | Sort-Object Value -Descending

$elements = New-Object System.Collections.ArrayList

[void]$elements.Add(@{
  tag = "div"
  fields = @(
    @{ is_short = $true; text = @{ tag = "lark_md"; content = ("**" + (Format-Num $total) + "**" + "`n样本总数 · 今日 **+" + $todayNew + "**") } },
    @{ is_short = $true; text = @{ tag = "lark_md"; content = ("**" + (Format-Num $withUser) + "**`n带用户名") } },
    @{ is_short = $true; text = @{ tag = "lark_md"; content = ("**" + $mods + "**`n管理员/版主") } },
    @{ is_short = $true; text = @{ tag = "lark_md"; content = ("**" + $groups + "**`n覆盖群数") } }
  )
})

[void]$elements.Add(@{ tag = "hr" })
[void]$elements.Add(@{ tag = "div"; text = @{ tag = "lark_md"; content = "**平台构成**" } })

foreach ($e in $platSorted) {
  $pct = 0
  if ($total -gt 0) { $pct = [Math]::Round(($e.Value / $total) * 100, 1) }
  [void]$elements.Add(@{
    tag = "column_set"
    flex_mode = "none"
    columns = @(
      @{ tag = "column"; width = "weighted"; weight = 3; elements = @(@{ tag = "div"; text = @{ tag = "lark_md"; content = ("**" + $e.Key + "**") } }) },
      @{ tag = "column"; width = "weighted"; weight = 2; elements = @(@{ tag = "div"; text = @{ tag = "lark_md"; content = ((Format-Num $e.Value) + "  ·  " + $pct + "%") } }) }
    )
  })
}

[void]$elements.Add(@{
  tag = "note"
  elements = @(@{ tag = "plain_text"; content = ("采集日期 " + $today + " · 共 " + $platSorted.Count + " 个平台") })
})

$card = @{
  config = @{ wide_screen_mode = $true }
  header = @{ template = "indigo"; title = @{ tag = "plain_text"; content = "👥 用户样本" } }
  elements = $elements
}

if ($DryRun) {
  $card | ConvertTo-Json -Depth 20
  ""
  "DryRun: total=$total withUsername=$withUser mods=$mods groups=$groups todayNew=$todayNew platforms=$($platSorted.Count)"
  exit 0
}

$r = Send-Card -Card $card
"webhook => code=" + $r.code + " msg=" + $r.msg
