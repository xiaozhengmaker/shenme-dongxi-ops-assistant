# report.ps1 -- 从《私域社群表》汇总各平台数据，生成飞书卡片日报并发送
# 用法： pwsh -File report.ps1              # 发到默认 webhook
#        pwsh -File report.ps1 -DryRun      # 只打印不发送
#        pwsh -File report.ps1 -Date 2026-11-06

param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [switch]$DryRun
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib\feishu.ps1")

$cfg = $script:Cfg
$recs = Get-FsRecords

$dayStart = [DateTimeOffset]::Parse($Date + "T00:00:00+08:00").ToUnixTimeMilliseconds()
$dayEnd   = $dayStart + 86400000

function Get-FieldValue($rec, $name) {
  $v = $rec.fields.$name
  if ($v -eq $null) { return $null }
  if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
    # 文本字段可能返回 [{text=..}] 结构
    if ($v.Count -gt 0 -and $v[0].text) { return ($v | ForEach-Object { $_.text }) -join "" }
  }
  return $v
}

$rows = @()
foreach ($r in $recs) {
  $plat = Get-FieldValue $r "平台"
  if (-not $plat) { continue }
  $mem = Get-FieldValue $r "成员数"
  $memNum = 0
  if ($mem) { $memNum = [double]$mem }
  $status = Get-FieldValue $r "状态"
  $joined = Get-FieldValue $r "加入日期"
  $isNew = $false
  if ($joined -and [double]$joined -ge $dayStart -and [double]$joined -lt $dayEnd) { $isNew = $true }
  $rows += [pscustomobject]@{
    Platform = [string]$plat
    Members  = $memNum
    Status   = [string]$status
    IsNew    = $isNew
  }
}

function Test-Daily([string]$p) {
  try {
    if ($cfg.notify -and $cfg.notify.platforms -and $cfg.notify.platforms.$p) {
      return [bool]$cfg.notify.platforms.$p.daily
    }
  } catch { }
  return $true
}

$order = @($cfg.report.platform_order)
$statByPlat = @{}
foreach ($p in $order) {
  if (-not (Test-Daily $p)) { continue }
  $subset = @($rows | Where-Object { $_.Platform -eq $p })
  $alive = @($subset | Where-Object { $_.Status -ne "已失效" -and $_.Status -ne "已退出" })
  $statByPlat[$p] = [pscustomobject]@{
    Count    = $alive.Count
    Members  = ($alive | Measure-Object -Property Members -Sum).Sum
    NewCount = @($alive | Where-Object { $_.IsNew }).Count
    NewMem   = (@($alive | Where-Object { $_.IsNew }) | Measure-Object -Property Members -Sum).Sum
    Dead     = @($subset | Where-Object { $_.Status -eq "已失效" -or $_.Status -eq "已退出" }).Count
  }
}

$totCount = 0; $totMem = 0.0; $totNewC = 0; $totNewM = 0.0; $totDead = 0
foreach ($p in $order) {
  $s = $statByPlat[$p]
  $totCount += $s.Count; $totMem += [double]$s.Members
  $totNewC += $s.NewCount; $totNewM += [double]$s.NewMem
  $totDead += $s.Dead
}

$today = [datetime]::Parse($Date).ToString("MM-dd")
$elements = @()
foreach ($p in $order) {
  $s = $statByPlat[$p]
  if ($s.Count -eq 0 -and $s.NewCount -eq 0) { continue }
  $left = "**$p**`n**" + $s.Count + "** 群 ｜ **" + (Format-Num $s.Members) + "** 人"
  $right = "今日 **+" + $s.NewCount + "** 群 ｜ **+" + (Format-Num $s.NewMem) + "** 人"
  $elements += @{
    tag = "div"
    fields = @(
      @{ is_short = $true; text = @{ tag = "lark_md"; content = $left } },
      @{ is_short = $true; text = @{ tag = "lark_md"; content = $right } }
    )
  }
}

$elements += @{ tag = "hr" }

$totLeft = "**合计**`n**" + $totCount + "** 群 ｜ **" + (Format-Num $totMem) + "** 人"
$totRight = "今日 **+" + $totNewC + "** 群 ｜ **+" + (Format-Num $totNewM) + "** 人"
$elements += @{
  tag = "div"
  fields = @(
    @{ is_short = $true; text = @{ tag = "lark_md"; content = $totLeft } },
    @{ is_short = $true; text = @{ tag = "lark_md"; content = $totRight } }
  )
}

if ($cfg.report.show_invalid_row) {
  $deadText = "失效：**" + $totDead + "** 群"
  if ($totDead -gt 0) {
    $deadMem = (@($rows | Where-Object { $_.Status -eq "已失效" -or $_.Status -eq "已退出" }) | Measure-Object -Property Members -Sum).Sum
    $deadText = "失效：**-" + $totDead + "** 群 ｜ **-" + (Format-Num $deadMem) + "** 人"
  }
  $elements += @{ tag = "note"; elements = @(@{ tag = "plain_text"; content = $deadText }) }
}

$card = @{
  config = @{ wide_screen_mode = $true }
  header = @{ template = $cfg.report.card_color; title = @{ tag = "plain_text"; content = $cfg.report.title + " · " + $today } }
  elements = $elements
}

$preview = @()
foreach ($p in $order) {
  $s = $statByPlat[$p]
  if ($s.Count -eq 0) { continue }
  $preview += ("{0,-9} {1,4} 群 / {2,9} 人   今日 +{3} 群 / +{4} 人" -f $p, $s.Count, (Format-Num $s.Members), $s.NewCount, (Format-Num $s.NewMem))
}
$preview += ("{0,-9} {1,4} 群 / {2,9} 人   今日 +{3} 群 / +{4} 人" -f "合计", $totCount, (Format-Num $totMem), $totNewC, (Format-Num $totNewM))
$preview | ForEach-Object { Write-Output $_ }

if ($DryRun) {
  Write-Output "(dry-run, 未发送)"
} else {
  $r = Send-Card -Card $card
  Write-Output ("webhook => code=" + $r.code + " msg=" + $r.msg)
}
