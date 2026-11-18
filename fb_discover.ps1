# fb_discover.ps1 -- 从 Facebook「发现小组」页抓取未加入的推荐群，写入候选池
param(
  [int]$MinMembers = 300,
  [int]$MaxTake = 40,
  [int]$Scrolls = 6,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $baseDir "lib\log.ps1")
Set-LogFile (Join-Path $baseDir "logs\fb_discover.log")
$cdp = Join-Path $baseDir "cdp_call.ps1"

function Ev([string]$m) {
  try { Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ msg = $m } | ConvertTo-Json -Compress))) -ContentType "application/json; charset=utf-8" -TimeoutSec 8 | Out-Null } catch {}
}

$nav = @{ url = "https://www.facebook.com/groups/discover/" } | ConvertTo-Json -Compress
& $cdp -Method "Page.navigate" -ParamsJson $nav -Match "facebook" -TimeoutSec 40 | Out-Null
Start-Sleep -Seconds 7

$js = @'
(async () => {
  for (let i = 0; i < __SCROLLS__; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 1400));
  }
  const seen = {}; const join = [];
  for (const a of document.querySelectorAll('a[href*="/groups/"]')) {
    const m = (a.getAttribute("href") || "").match(/\/groups\/([A-Za-z0-9._-]+)/);
    if (!m || seen[m[1]]) continue;
    seen[m[1]] = 1;
    let el = a, card = null;
    for (let i = 0; i < 10; i++) {
      el = el.parentElement; if (!el) break;
      const t = el.innerText || "";
      if (t.length > 20 && /(位成员|成员|members)/i.test(t) && t.length < 700) { card = el; break; }
    }
    if (!card) continue;
    // 按钮不在卡片文本块里：需要往上再找几层才能看到「加入小组 / 已加入 / 访问」
    let box = card, cls = "other";
    for (let k = 0; k < 6; k++) {
      const t = box.innerText || "";
      if (/(加入小组|Join group)/i.test(t)) { cls = "join"; break; }
      if (/(已加入|Joined|访问|Visit group)/i.test(t)) { cls = "joined"; break; }
      if (!box.parentElement) break;
      box = box.parentElement;
    }
    if (cls !== "join") continue;
    const txt = card.innerText || "";
    let name = (txt.split("\n")[0] || "").trim();
    const mV = txt.match(/([\d.,]+)\s*(万|亿|K|M)?\s*位?成员/);
    let n = 0;
    if (mV) {
      n = parseFloat(String(mV[1]).replace(/,/g, ""));
      const u = mV[2];
      if (u === "万") n *= 10000; else if (u === "亿") n *= 1e8;
      else if (u && u.toUpperCase() === "K") n *= 1000; else if (u && u.toUpperCase() === "M") n *= 1e6;
    }
    join.push({ id: m[1], title: name, n: Math.round(n) });
  }
  return JSON.stringify({ items: join, url: location.href });
})()
'@.Replace("__SCROLLS__", [string]$Scrolls)

$p = @{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress
$raw = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "facebook" -TimeoutSec 90
$line = @($raw) | Where-Object { ([string]$_).Trim().StartsWith("{") } | Select-Object -Last 1
if (-not $line) { Write-Log ("CDP 无返回: " + [string]$raw); exit 4 }
$outer = [string]$line | ConvertFrom-Json
$inner = [string]$outer.result.value
if (-not $inner) { Write-Log "空响应"; exit 5 }
$res = $inner | ConvertFrom-Json
$items = @($res.items)
Write-Log ("发现页未加入候选 " + $items.Count + " 个")

# 与飞书已有群 + 池内已有群去重
$knownTitles = @{}
try {
  . (Join-Path $baseDir "lib\feishu.ps1")
  foreach ($r in Get-FsRecords) {
    if ([string]$r.fields.'平台' -ne "Facebook") { continue }
    $tt = ([string]$r.fields.'群名').Trim().ToLower()
    if ($tt) { $knownTitles[$tt] = 1 }
  }
} catch { Write-Log ("读取飞书失败，跳过去重：" + $_.Exception.Message) }

$poolPath = Join-Path $baseDir "data\pool_facebook.json"
$pool = @()
if (Test-Path $poolPath) { try { $pool = @((Get-Content $poolPath -Raw -Encoding UTF8 | ConvertFrom-Json).items) } catch {} }
$existId = @{}
foreach ($i in $pool) { if ($i.id) { $existId[[string]$i.id] = 1 } }

# 必须有 CS 语义（我们的目标就是 CS2/CSGO 社群）
$rxRel = '(?i)(cs2|cs:go|csgo|counter[\s\-]?strike|cs\s?1\.6|cs1\.6)'
# 明显无关的杂群：本地社区 / 交友 / 带货 / 宝可梦 / 其它游戏
$rxDrop = '(?i)(pokemon|dota|dating|los angeles|coachella|bangladesh|star sender|earning|hotkey|keybind|keyboard|sensitiv|trainer|coach|cheat|hack|airdrop|news|sport|football|movie|music|standoff|casino|poker|rifa|meme)'

$keep = @()
foreach ($it in $items) {
  $t = ([string]$it.title).Trim()
  if (-not $t) { continue }
  if ($t -notmatch $rxRel) { continue }
  if ($t -match $rxDrop) { continue }
  if ($knownTitles.ContainsKey($t.ToLower())) { continue }
  if ($existId.ContainsKey([string]$it.id)) { continue }
  if ([int]$it.n -lt $MinMembers) { continue }
  $keep += [pscustomobject]@{ id = [string]$it.id; title = $t; n = [int]$it.n }
}
$keep = @($keep | Sort-Object n -Descending | Select-Object -First $MaxTake)
Write-Log ("过滤后 " + $keep.Count + " 个（门槛 " + $MinMembers + " 人，已有 " + $knownTitles.Count + " 个 FB 群）")

if ($DryRun) { $keep | Format-Table -AutoSize | Out-String | Write-Host; exit 0 }

$now = (Get-Date).ToUniversalTime()
$exp = $now.AddDays(14).ToString("o")
$add = 0
foreach ($c in $keep) {
  $pool += [pscustomobject]@{ id = $c.id; title = $c.title; n = $c.n; u = ""; h = ""; src = "discover"; addedAt = $now.ToString("o"); expiresAt = $exp }
  $add++
}
$obj = @{ savedAt = (Get-Date).ToString("s"); platform = "Facebook"; count = $pool.Count; items = $pool }
[System.IO.File]::WriteAllText($poolPath, ($obj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Log ("入池 " + $add + "，池深 " + $pool.Count)
Ev ("fb discover done: new=" + $add + " pool=" + $pool.Count)
"DONE new=$add pool=$($pool.Count)"
