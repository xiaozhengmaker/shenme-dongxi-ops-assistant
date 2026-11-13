param(
  [int]$MaxVerify = 20,
  [switch]$Force,
  [int]$WaitSec = 30,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = "D:\DeepSeek\运营" }
. (Join-Path $baseDir "lib\wa.ps1") -BaseDir $baseDir

$cdp = Join-Path $baseDir "cdp_call.ps1"
$logDir = Join-Path $baseDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "wa_verify.log"

function Say([string]$m) {
  $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] [wa_verify] " + $m
  Write-Host $line
  [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Ev([string]$m) {
  try { Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -ContentType "application/json" -Body (@{ msg = $m } | ConvertTo-Json -Compress) -TimeoutSec 5 | Out-Null } catch {}
}
function Eval([string]$js) {
  $raw = ""
  try { $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson (@{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress) -Match "web.whatsapp" } catch { return $null }
  try {
    $o = $raw | ConvertFrom-Json
    if ($o -and $o.result -and $o.result.value) { return ($o.result.value | ConvertFrom-Json) }
  } catch {}
  return $null
}

$cfg = Get-WaConfig
$state = Get-WaState
$mode = "search_only"; $maxJoin = 0; $allowApproval = $true
if ($cfg) {
  if ($cfg.PSObject.Properties.Name -contains "mode") { $mode = [string]$cfg.mode }
  if ($cfg.PSObject.Properties.Name -contains "max_join") { $maxJoin = [int]$cfg.max_join }
  if ($cfg.PSObject.Properties.Name -contains "allow_approval_request") { $allowApproval = [bool]$cfg.allowApproval_request }
}
$items = @($state.items)
$todo = @($items | Where-Object { $Force -or ([string]$_.status) -eq "待验证" })
if ($MaxVerify -gt 0 -and $todo.Count -gt $MaxVerify) { $todo = $todo[0..($MaxVerify - 1)] }
Say ("start mode=" + $mode + " max_join=" + $maxJoin + " todo=" + $todo.Count)
Ev ("wa verify start (todo=" + $todo.Count + ", mode=" + $mode + ")")

$probe = @'
(function(){
  var ds=document.querySelectorAll('div[role=dialog]');
  var d=ds.length?ds[ds.length-1]:null;
  var btns=[]; if(d){Array.prototype.forEach.call(d.querySelectorAll('button,div[role=button],a'),function(b){var t=(b.innerText||'').trim();if(t)btns.push(t);});}
  var main=document.querySelector('#main header');
  var body=document.body?document.body.innerText:'';
  return JSON.stringify({ndlg:ds.length, dlg:d?d.innerText.slice(0,1500):'', btns:btns.slice(0,15), hdr:main?main.innerText.slice(0,200):'', body:body.slice(0,2000)});
})()
'@

$joinedThisRun = 0
foreach ($it in $todo) {
  $code = [string]$it.code
  $acc = "https://web.whatsapp.com/accept?code=" + $code
  try { & $cdp -Method "Page.bringToFront" -ParamsJson '{}' -Match "web.whatsapp" | Out-Null } catch {}
  try { & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $acc } | ConvertTo-Json -Compress) -Match "web.whatsapp" | Out-Null } catch {}

  $payload = $null
  $tries = [int]([Math]::Ceiling($WaitSec / 3))
  for ($i = 0; $i -lt $tries; $i++) {
    Start-Sleep -Seconds 3
    $pl = Eval $probe
    if (-not $pl) { continue }
    $bt = (@($pl.btns) -join "|")
    $tooltip = ([string]$pl.dlg -match "(?i)(view recent calls|start a new one|use the search bar)") -and (@($pl.btns).Count -lt 2)
    $isInvite = ($bt -match "(?i)(join group|request to join|view group|open chat)") -or (@($pl.btns).Count -ge 2 -and -not $tooltip)
    if ($isInvite) { $payload = $pl; break }
    $payload = $pl
  }

  $status = "访问失败"; $name = ""; $desc = ""; $joinState = "未加入"
  if ($payload) {
    $bt = (@($payload.btns) -join "|")
    $dlg = [string]$payload.dlg
    $body = [string]$payload.body
    if ($bt -match "(?i)join group") { $status = "可加入" }
    elseif ($bt -match "(?i)request to join|admin must approve") { $status = "需审批" }
    elseif ($bt -match "(?i)(view group|open chat)") { $status = "已在群内"; $joinState = "已在群内" }
    elseif ($dlg -match "(?i)(couldn.t join|invalid|expired|no longer)") { $status = "已失效" }
    elseif ($body -match "(?i)(don.t close this window|downloading)") { $status = "同步中" }
    elseif ($body -match "(?i)(scan.*qr|link with phone)") { $status = "需登录" }
    elseif ([string]$payload.hdr) { $status = "已在群内"; $joinState = "已在群内" }
    elseif ([string]$payload.dlg -match "(?i)(view recent calls|start a new one)") { $status = "待确认"; $name = "" }
    else { $status = "待确认" }

    if ($dlg) {
      $lines = @($dlg -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_.Length -gt 2 })
      $lines = @($lines | Where-Object { $_ -notmatch "(?i)(view recent calls|start a new one|use the search bar)" })
      $cs2 = $lines | Where-Object { $_ -match "(?i)(cs2|cs:?go|counter|skin|trade)" } | Select-Object -First 1
      if ($cs2) { $name = $cs2 } elseif ($lines.Count -gt 0) { $name = $lines[0] }
      if ($lines.Count -gt 1 -and $lines[1] -ne $name) { $desc = $lines[1] }
    }
    if (-not $name -and $payload.hdr) { $name = ([string]$payload.hdr -split "`n")[0].Trim() }
  }

  $rel = Get-WaRelevance $name $desc
  $purpose = Get-WaPurpose $name $desc
  $lr = Get-WaLangRegion $name $desc

  if ($mode -eq "search_join" -and $maxJoin -gt 0 -and $joinedThisRun -lt $maxJoin -and $rel -eq "high" -and -not $DryRun) {
    if ($status -eq "可加入") {
      $r = Eval "(function(){var ds=document.querySelectorAll('div[role=dialog]');var d=ds[ds.length-1];if(!d)return 'no-dialog';var b=Array.prototype.find.call(d.querySelectorAll('button'),function(x){return /join group/i.test(x.innerText||'')});if(!b)return 'no-btn';b.click();return 'clicked';})()"
      Start-Sleep -Seconds 6
      if ([string]$r -eq "clicked") { $joinState = "已加入"; $joinedThisRun++; Ev ("wa join ok: " + $code) }
    } elseif ($status -eq "需审批" -and $allowApproval) {
      $r = Eval "(function(){var ds=document.querySelectorAll('div[role=dialog]');var d=ds[ds.length-1];if(!d)return 'no-dialog';var b=Array.prototype.find.call(d.querySelectorAll('button'),function(x){return /request to join/i.test(x.innerText||'')});if(!b)return 'no-btn';b.click();return 'clicked';})()"
      Start-Sleep -Seconds 4
      if ([string]$r -eq "clicked") { $joinState = "已提交待审批"; $joinedThisRun++; Ev ("wa approval requested: " + $code) }
    }
  } elseif ($status -eq "需审批") { $joinState = "待审批(未提交)" }

  for ($k = 0; $k -lt $items.Count; $k++) {
    if ([string]$items[$k].code -eq $code) {
      $items[$k].name = $name
      $items[$k].region = $lr.region
      $items[$k].lang = $lr.lang
      $items[$k].purpose = $purpose
      $items[$k].relevance = $rel
      $items[$k].status = $status
      $items[$k].join = $joinState
      $items[$k].checkedAt = (Get-Date).ToString("s")
      break
    }
  }
  Say ($code + " -> " + $status + " rel=" + $rel + " name=" + $name)
}

$state.items = $items
Save-WaState $state
Say ("DONE joined=" + $joinedThisRun)
Ev ("wa verify done: joined=" + $joinedThisRun)
