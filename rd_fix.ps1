$ErrorActionPreference = "Stop"
$rootDir = "D:\DeepSeek\运营"
. "$rootDir\lib\feishu.ps1"
$rootDir = "D:\DeepSeek\运营"
$cfg = [System.IO.File]::ReadAllText("$rootDir\config.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$tok = Get-FsToken
$app = $cfg.feishu.base_app_token
$tbl = $cfg.feishu.table_id

# 1) read all records
$all = New-Object System.Collections.ArrayList
$pt = $null
do {
  $u = "https://open.feishu.cn/open-apis/bitable/v1/apps/$app/tables/$tbl/records?page_size=500"
  if ($pt) { $u += "&page_token=$pt" }
  $r = Invoke-RestMethod -Uri $u -Headers @{ Authorization = "Bearer $tok" }
  foreach ($i in $r.data.items) { [void]$all.Add($i) }
  $pt = $r.data.page_token
} while ($r.data.has_more)
Write-Host ("records=" + $all.Count)

# 2) backfill 平台/群类型/采集来源 from key prefix
$updates = New-Object System.Collections.ArrayList
foreach ($rec in $all) {
  $key = [string]$rec.fields.'群组唯一键'
  $plat = $null; $gt = $null; $src = $null
  if ($key -like "FB-*") { $plat = "Facebook"; $gt = "公开群"; $src = "FB搜索" }
  elseif ($key -like "TG-*") { $plat = "Telegram"; $gt = "聊天"; $src = "TG搜索" }
  elseif ($key -like "RD-*") { $plat = "Reddit"; $gt = "板块"; $src = "Reddit搜索" }
  elseif ($key -like "DC-*") { $plat = "Discord"; $gt = "服务器"; $src = "Discord API" }
  else { continue }
  if ($key -eq "FB-CSGO-TradingWorldwide") { $gt = "非公开群" }
  $f = @{}
  if (-not $rec.fields.'平台') { $f['平台'] = $plat }
  if (-not $rec.fields.'群类型') { $f['群类型'] = $gt }
  if (-not $rec.fields.'采集来源') { $f['采集来源'] = $src }
  if ($f.Count -gt 0) {
    [void]$updates.Add(@{ record_id = $rec.record_id; fields = $f })
  }
}
Write-Host ("to backfill=" + $updates.Count)
for ($i = 0; $i -lt $updates.Count; $i += 100) {
  $end = [Math]::Min($i + 99, $updates.Count - 1)
  $batch = @($updates[$i..$end])
  $payload = @{ records = $batch } | ConvertTo-Json -Depth 8 -Compress
  $res = Invoke-RestMethod -Uri "https://open.feishu.cn/open-apis/bitable/v1/apps/$app/tables/$tbl/records/batch_update" -Method Post -Headers @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
  Write-Host ("batch " + $i + " code=" + $res.code)
}

# 3) insert the 10 Reddit rows
$todayMs = [DateTimeOffset]::new((Get-Date).Date).ToUnixTimeMilliseconds()
$expireMs = $todayMs + 3 * 86400000
$rows = @() ; $skipRows = @(
  @{ n = "cs2"; s = 286981; p = 0 }, @{ n = "counterstrike"; s = 206678; p = 2 },
  @{ n = "counterstrike2"; s = 86268; p = 2 }, @{ n = "Csgohacks"; s = 38974; p = 3 },
  @{ n = "LearnCSGO"; s = 61097; p = 2 }, @{ n = "VACsucks"; s = 38492; p = 0 },
  @{ n = "GlobalOffensiveTrade"; s = 247372; p = 2 }, @{ n = "RecruitCS"; s = 57449; p = 2 },
  @{ n = "RevenantMain"; s = 13449; p = 3 }, @{ n = "GameTrade"; s = 52092; p = 2 }
)
$sets = New-Object System.Collections.ArrayList
foreach ($row in $rows) {
  [void]$sets.Add(@{
    "群组唯一键" = "RD-" + $row.n
    "平台" = "Reddit"
    "群ID" = "r/" + $row.n
    "群名" = "r/" + $row.n
    "群链接" = "https://www.reddit.com/r/" + $row.n + "/"
    "成员数" = $row.s
    "语言" = "英语"
    "群类型" = "板块"
    "状态" = "已加入"
    "加入日期" = $todayMs
    "潜水到期" = $expireMs
    "日发帖量" = $row.p
    "采集来源" = "Reddit搜索"
    "采集日" = $todayMs
    "是否收费发帖" = "未知"
    "备注" = "Reddit 首轮订阅"
  })
}
$added = 0
Write-Host ("reddit added=" + $added)
