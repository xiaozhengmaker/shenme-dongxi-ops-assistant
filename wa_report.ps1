param(
  [switch]$Markdown,
  [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = "D:\DeepSeek\运营" }
. (Join-Path $baseDir "lib\wa.ps1") -BaseDir $baseDir

$state = Get-WaState
$items = @($state.items)
$by = { param($f) @($items | Group-Object { [string]$_.$f } | Sort-Object Count -Descending) }

$total = $items.Count
$high = @($items | Where-Object { [string]$_.relevance -eq "high" }).Count
$pending = @($items | Where-Object { [string]$_.status -eq "待验证" -or [string]$_.status -eq "待确认" }).Count
$joined = @($items | Where-Object { [string]$_.join -eq "已加入" -or [string]$_.join -eq "已在群内" }).Count
$approval = @($items | Where-Object { [string]$_.join -like "已提交待审批*" }).Count
$bad = @($items | Where-Object { [string]$_.status -in @("已失效", "访问失败", "需登录") }).Count
$irrelevant = @($items | Where-Object { [string]$_.relevance -eq "exclude" }).Count

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("# WhatsApp 群发现报告")
[void]$lines.Add("")
[void]$lines.Add("生成时间：" + (Get-Date).ToString("yyyy-MM-dd HH:mm"))
[void]$lines.Add("")
[void]$lines.Add("## 本轮统计")
[void]$lines.Add("")
[void]$lines.Add("- 已执行查询数：" + @($state.queries).Count)
[void]$lines.Add("- 候选群（去重后）：" + $total)
[void]$lines.Add("- 已验证高相关：" + $high)
[void]$lines.Add("- 待验证线索：" + $pending)
[void]$lines.Add("- 已加入：" + $joined)
[void]$lines.Add("- 待审批：" + $approval)
[void]$lines.Add("- 失效/失败/需登录：" + $bad)
[void]$lines.Add("")
[void]$lines.Add("## 分类明细")
[void]$lines.Add("")
[void]$lines.Add("| 群名 | 国家/地区 | 语言 | 用途 | 邀请链接 | 来源页面 | 验证状态 | 加群状态 | 备注 |")
[void]$lines.Add("|---|---|---|---|---|---|---|---|---|")
$order = @("饰品交易", "找队友", "约战比赛", "战队招募", "综合社区", "未知")
foreach ($p in $order) {
  $sub = @($items | Where-Object { [string]$_.purpose -eq $p })
  if ($sub.Count -eq 0) { continue }
  [void]$lines.Add("| **" + $p + "** (" + $sub.Count + ") | | | | | | | | |")
  foreach ($it in $sub) {
    $src = ""
    if (@($it.sources).Count -gt 0) { $src = [string]$it.sources[0].url }
    [void]$lines.Add("| " + ($it.name -replace '\|', '/') + " | " + $it.region + " | " + $it.lang + " | " + $it.purpose + " | https://chat.whatsapp.com/" + $it.code + " | " + $src + " | " + $it.status + " | " + $it.join + " | " + ($it.note -replace '\|', '/') + " |")
  }
}
[void]$lines.Add("")
[void]$lines.Add("## 下一轮建议")
[void]$lines.Add("")
[void]$lines.Add("- 补充地区：沙特/UAE/南非/孟加拉/东南亚 未覆盖")
[void]$lines.Add('- 补充查询：site:instagram.com "CS2" "chat.whatsapp.com"；"CS2" "grupos de WhatsApp" "Brasil"')
[void]$lines.Add("- 对 status=需审批 的群，确认后再决定是否提交申请")

$text = ($lines -join "`r`n")
if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false))) }
$md = Join-Path $baseDir "data\wa_report.md"
[System.IO.File]::WriteAllText($md, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $text
