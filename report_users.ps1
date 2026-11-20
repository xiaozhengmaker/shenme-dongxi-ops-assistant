param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
. (Join-Path $rootDir "lib\feishu.ps1")

# 单遍流式聚合：避免 $rows += 造成的 O(n^2)（19 万行会跑不完）
$jsonl = Join-Path $rootDir "data\users.jsonl"
$total = 0; $withUser = 0; $mods = 0
$today = (Get-Date).ToString("yyyy/MM/dd")
$todayNew = 0
$byPlat = @{}
$groupSet = New-Object 'System.Collections.Generic.HashSet[string]'

if (Test-Path $jsonl) {
  foreach ($line in [System.IO.File]::ReadLines($jsonl, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $line = $line.TrimStart([char]0xFEFF)
    $r = $null
    try { $r = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $r) { continue }
    $total++
    if ($r.username -and ([string]$r.username).Trim() -ne "") { $withUser++ }
    if (([string]$r.role) -match "管理员|版主|群主") { $mods++ }
    if (([string]$r.collected_at) -eq $today) { $todayNew++ }
    $gk = [string]$r.group_key
    if ($gk) { [void]$groupSet.Add($gk) }
    $p = [string]$r.platform
    if ([string]::IsNullOrWhiteSpace($p)) { $p = "其他" }
    if (-not $byPlat.ContainsKey($p)) { $byPlat[$p] = 0 }
    $byPlat[$p]++
  }
}
$groups = $groupSet.Count
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