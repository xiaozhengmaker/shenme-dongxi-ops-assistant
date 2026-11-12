# run_tg.ps1 -- Telegram 每日加群（全程后台，通过 Web 内部 API，不操作前台）
# 用法： pwsh -File run_tg.ps1            # 按 config 配额加入
#        pwsh -File run_tg.ps1 -DryRun    # 只搜索与筛选，不加群、不写表
#        pwsh -File run_tg.ps1 -Limit 5   # 本次最多加 5 个

param(
  [switch]$DryRun,
  [int]$Limit = 0,
  [string[]]$Queries = @(
    "cs2 trade","cs2 skins","cs2 market","cs2 chat","csgo trade",
    "cs2 community","cs2 russia","кс 2 чат","cs2 giveaway","cs2 faceit"
  )
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib\feishu.ps1")
. (Join-Path $here "lib\tg.ps1")

$cfg = $script:Cfg
$minMembers = 300
if ($cfg.filters.min_members.Telegram) { $minMembers = [int]$cfg.filters.min_members.Telegram }
$quota = 0
if ($cfg.quotas.Telegram) { $quota = [int]$cfg.quotas.Telegram }
if ($Limit -gt 0) { $quota = $Limit }

$today = Get-Date
$dayStart = [DateTimeOffset]::new($today.Year,$today.Month,$today.Day,0,0,0,[TimeSpan]::FromHours(8)).ToUnixTimeMilliseconds()
$due = $dayStart + 3 * 86400000

# 已收录集合（按群ID 去重）
$existing = Get-FsRecords
$seen = @{}
$seenTitles = @{}
$todayNew = 0
foreach ($r in $existing) {
  $gid = $r.fields.'群ID'
  if ($gid) { $seen[[string]$gid] = $true }
  $nm = $r.fields.'群名'
  if ($nm) { $seenTitles[(([string]$nm).Trim()).ToLower()] = $true }
  $lnk = $r.fields.'群链接'
  if ($lnk) {
    $u = ([string]$lnk) -replace '^.*t\.me/',''
    if ($u) { $seen[$u.ToLower()] = $true }
  }
  $j = $r.fields.'加入日期'
  if ($j -and [double]$j -ge $dayStart) { $todayNew++ }
}
$need = $quota - $todayNew
if ($need -lt 0) { $need = 0 }
Write-Output ("今日已加 {0} / 配额 {1}，还需 {2}" -f $todayNew, $quota, $need)
if ($need -eq 0) { return }

$self = Get-TgSelfId
$cands = @{}
foreach ($q in $Queries) {
  try { $res = Search-Tg -Query $q -Limit 30 } catch { Write-Output ("search fail [{0}]: {1}" -f $q, $_.Exception.Message); continue }
  foreach ($c in $res) {
    if ($c.bc) { continue }
    if ([int]$c.n -lt $minMembers) { continue }
    $id = [string]$c.id
    if ($seen.ContainsKey($id)) { continue }
    if ($c.u -and $seen.ContainsKey(([string]$c.u).ToLower())) { continue }
    $t = (([string]$c.title).Trim()).ToLower()
    if ($seenTitles.ContainsKey($t)) { continue }
    if ($c.title -match '(?i)(airdrop|pixelverse|xdao|earn|shop|магазин|news|news\s*chat)') { continue }
    if ($cands.ContainsKey($id)) { continue }
    $cands[$id] = [pscustomobject]@{ id = $id; title = $c.title; u = $c.u; n = [int]$c.n; mg = $c.mg }
  }
  Write-Output ("[{0}] 命中 {1}，累计候选 {2}" -f $q, $res.Count, $cands.Count)
}

$ordered = $cands.Values | Sort-Object -Property n -Descending
Write-Output ("候选合计 {0}，本次计划加入 {1}" -f $ordered.Count, [Math]::Min($need, $ordered.Count))

if ($DryRun) {
  $ordered | Select-Object -First 20 | ForEach-Object { "  {0,-45} @{1,-24} n={2}" -f $_.title, $_.u, $_.n }
  Write-Output "(dry-run)"
  return
}

$joined = New-Object System.Collections.ArrayList
$i = 0
foreach ($c in $ordered) {
  if ($joined.Count -ge $need) { break }
  $i++
  $res = "skip"
  try { $res = Join-Tg -Username $c.u -SelfId $self } catch { $res = "err:" + $_.Exception.Message }
  Write-Output ("[{0}/{1}] {2} => {3}" -f $i, $need, $c.title, $res)
  if ($res -eq "joined" -or $res -eq "already") {
    [void]$joined.Add([pscustomobject]@{ c = $c; state = $(if ($res -eq "joined") { "已加入" } else { "已加入" }) })
  }
  Start-Sleep -Seconds 2
}

if ($joined.Count -eq 0) { Write-Output "没有成功加入任何群"; return }

$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$sets = New-Object System.Collections.ArrayList
foreach ($j in $joined) {
  $c = $j.c
  $f = @{}
  $f.Add("群组唯一键", "TG-" + $c.u)
  if (-not $c.u) { $f["群组唯一键"] = "TG-" + $c.id }
  $f.Add("平台", "Telegram")
  $f.Add("群ID", $c.id)
  $f.Add("群名", $c.title)
  if ($c.u) { $f.Add("群链接", "https://t.me/" + $c.u) }
  $f.Add("成员数", $c.n)
  $f.Add("群类型", "聊天")
  $f.Add("状态", $j.state)
  $f.Add("加入日期", $now)
  $f.Add("潜水到期", $due)
  $f.Add("采集来源", "TG搜索")
  $f.Add("采集日", $now)
  $f.Add("是否收费发帖", "否")
  [void]$sets.Add($f)
}
$created = Add-FsRecords -FieldSets $sets.ToArray()
Write-Output ("写入飞书 {0} 条" -f $created)
