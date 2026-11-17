# leads_score.ps1 -- 用 AI 给线索打分（P2），并与规则意图做对比
param(
  [int]$Top = 30,
  [int]$Batch = 10,
  [switch]$DryRun,
  [string]$SignalsFile = "",
  [string]$OutFile = ""
)
$ErrorActionPreference = "Stop"
$baseDir = "D:\DeepSeek\运营"
. (Join-Path $baseDir "lib\log.ps1")
. (Join-Path $baseDir "lib\ai.ps1")
. (Join-Path $baseDir "lib\profile.ps1")
Set-LogFile (Join-Path $baseDir "logs\leads_score.log")
function Say([string]$m) { Write-Log ("[score] " + $m) }

if (-not $SignalsFile) { $SignalsFile = Join-Path $baseDir "data\leads_signals.json" }
if (-not $OutFile) { $OutFile = Join-Path $baseDir "data\leads_scored.json" }

$cfg = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$prof = Get-GOpsProfile $cfg
$sig = Get-Content $SignalsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($sig.items)
Say ("signals=" + $items.Count)

# 取「评论多 + 意图标签多」的前 N 条做对比，避免全量烧钱
$picked = @($items |
  Sort-Object @{ Expression = { [int](([string]$_.comments) -replace "[^0-9]", "") }; Descending = $true } |
  Select-Object -First $Top)
Say ("picked=" + $picked.Count + " (top by comments)")

$sys = "你是 CS2 饰品/开箱行业的线索判别器。只输出 JSON，不要解释。"
$promptTpl = @'
业务背景（来自用户配置）：
{business}

待判帖子（JSON 数组，每项有 id / title / sub / keyword / intent_rule）：
{items}

对每一条判断：它是不是「值得接触的潜在用户线索」。
判定标准（严格）：
- 是个人玩家在表达「想买/想卖/问价/晒货/抱怨价格/求推荐/求组队交易」→ is_lead=true
- 是商家推广、自制游戏/工具/模拟器宣传、视频频道宣传、抽奖活动、服务器招人 → is_lead=false
- 纯讨论游戏玩法/战术/地图/作弊/模组，与饰品交易无关 → is_lead=false

输出 JSON：{"results":[{"id":<int>,"is_lead":true|false,"intent":"price_check|showcase|complain|want_buy|trade_offer|opening_urge|promo|offtopic|other","relevance":0.0-1.0,"reason":"<=20字"}]}
relevance<0.5 的必须 is_lead=false。
'@

$ai = Get-AiConfig $cfg
$business = if ($prof -and $prof.source) { [string]$prof.source } else { "CS2 第三方开箱站，做箱子和皮肤交易" }

if (-not $ai) {
  Say "NO_KEY 未配置 AI（config.ai.api_key / api_key_env 均为空）"
  if ($DryRun) {
    $sample = @($picked | Select-Object -First 3 | ForEach-Object -Begin { $i = 1 } -Process {
      [pscustomobject]@{ id = $i; title = $_.title; sub = $_.sub; keyword = $_.keyword; intent_rule = $_.intent }
    })
    $p = $promptTpl.Replace("{business}", $business).Replace("{items}", ($sample | ConvertTo-Json -Depth 5))
    Say "---- 将要发送的 Prompt 预览（前 3 条）----"
    Write-Host $p
  }
  exit 3
}

$results = @()
$totalUsage = 0
$i = 0
while ($i -lt $picked.Count) {
  $chunk = @($picked[$i..([Math]::Min($i + $Batch - 1, $picked.Count - 1))])
  $payloadItems = @()
  $n = 0
  foreach ($r in $chunk) {
    $n++
    $payloadItems += [pscustomobject]@{
      id          = $n
      title       = $r.title
      sub         = $r.sub
      keyword     = $r.keyword
      intent_rule = $r.intent
    }
  }
  $userMsg = $promptTpl.Replace("{business}", $business).Replace("{items}", ($payloadItems | ConvertTo-Json -Depth 5))
  $res = Invoke-AiChat $ai $sys $userMsg -JsonMode
  if (-not $res.ok) {
    Say ("AI_FAIL " + $res.error)
    break
  }
  try {
    $parsed = $res.text | ConvertFrom-Json
    $rows = @($parsed.results)
  } catch {
    Say ("PARSE_FAIL " + $res.text.Substring(0, [Math]::Min(160, $res.text.Length)))
    break
  }
  for ($k = 0; $k -lt $rows.Count; $k++) {
    $rr = $rows[$k]
    $src = $chunk[$k]
    $results += [pscustomobject]@{
      title       = $src.title
      url         = $src.url
      sub         = $src.sub
      comments    = $src.comments
      intent_rule = $src.intent
      ai_intent   = [string]$rr.intent
      ai_is_lead  = [bool]$rr.is_lead
      ai_relevance = [double]$rr.relevance
      ai_reason   = [string]$rr.reason
    }
  }
  if ($res.usage -and $res.usage.total_tokens) { $totalUsage += [int]$res.usage.total_tokens }
  Say ("batch done " + $chunk.Count + " tokens=" + $totalUsage)
  $i += $Batch
}

if (-not $results.Count) { Say "没有拿到任何 AI 结果"; exit 4 }

$leadCount = @($results | Where-Object { $_.ai_is_lead }).Count
$out = [pscustomobject]@{
  scored_at  = (Get-Date).ToString("s")
  model      = $ai.model
  business   = $business
  total      = $results.Count
  ai_leads   = $leadCount
  tokens     = $totalUsage
  items      = $results
}
[System.IO.File]::WriteAllText($OutFile, ($out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

Say ("DONE scored=" + $results.Count + " ai_leads=" + $leadCount + " tokens=" + $totalUsage)
Write-Host ""
Write-Host ("规则命中 " + $results.Count + " 条，AI 认为真线索 " + $leadCount + " 条")
Write-Host "---- AI 判为线索 ----"
$results | Where-Object { $_.ai_is_lead } | Sort-Object ai_relevance -Descending | Select-Object -First 12 |
  ForEach-Object { Write-Host ("  [" + $_.ai_intent + " " + $_.ai_relevance + "] " + $_.title.Substring(0, [Math]::Min(60, $_.title.Length))) }
Write-Host "---- AI 否掉（规则却命中的）----"
$results | Where-Object { -not $_.ai_is_lead } | Select-Object -First 10 |
  ForEach-Object { Write-Host ("  [" + $_.ai_intent + "] " + $_.title.Substring(0, [Math]::Min(60, $_.title.Length)) + "  <- " + $_.ai_reason) }
