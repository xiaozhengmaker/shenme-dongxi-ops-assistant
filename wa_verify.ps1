param(
  [int]$MaxVerify = 20,
  [switch]$Force,
  [int]$WaitSec = 30,
  [switch]$DryRun,
  [switch]$OneShot,
  [string]$TargetCode = "",
  [string]$Publisher = "",
  [string]$PublisherWhitelist = "",
  [switch]$AllowJoin,
  [int]$MaxActions = 2
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
. (Join-Path $baseDir "lib\wa.ps1") -BaseDir $baseDir
. (Join-Path $baseDir "lib\stop.ps1")
. (Join-Path $baseDir "lib\wa_verify_guard.ps1")
. (Join-Path $baseDir "lib\wa_click_verify.ps1")
. (Join-Path $baseDir "lib\wa_attempt.ps1")

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
  if ($env:GOPS_OFFLINE -eq "1") { return }
  try { Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -ContentType "application/json" -Body (@{ msg = $m } | ConvertTo-Json -Compress) -TimeoutSec 5 | Out-Null } catch {}
}
function Save-WaItems {
  Set-WaField $state "items" $items
  Save-WaState $state
}
function Begin-WaAttempt($Item, [string]$PublisherArg, [string]$Code, [string]$Name) {
  $pub = ([string]$PublisherArg).Trim()
  if (-not $pub) { $pub = Get-WaPublisherLabel $Item }
  $att = New-WaAttempt -Publisher $pub -Code $Code -TargetName $Name
  Set-WaField $Item "publisher" $pub
  Set-WaField $Item "attempt_id" $att.attempt_id
  Set-WaField $Item "invite_fingerprint" $att.invite_fingerprint
  Set-WaField $Item "attempt_at" $att.attempt_at
  Set-WaField $Item "attempt_state" "prepared"
  Save-WaItems
  return $att
}
function End-WaAttempt($Item, [string]$State, [string]$Note) {
  Set-WaField $Item "attempt_state" $State
  Set-WaField $Item "attempt_checked_at" ((Get-Date).ToString("o"))
  if ($Note) { Set-WaField $Item "attempt_note" $Note }
  Save-WaItems
}
$script:LastEvalError = ""
function Eval([string]$js) {
  $script:LastEvalError = ""
  $raw = ""
  try { $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson (@{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress) -Match "web.whatsapp" } catch {
    $script:LastEvalError = "exception"
    return $null
  }
  if ($LASTEXITCODE -ne 0) { $script:LastEvalError = "exit_" + $LASTEXITCODE; return $null }
  $text = [string]$raw
  if ([string]::IsNullOrWhiteSpace($text)) { $script:LastEvalError = "empty"; return $null }
  if ($text.TrimStart().StartsWith("ERR:")) { $script:LastEvalError = "cdp_error"; return $null }
  try {
    $o = $text | ConvertFrom-Json
    if ($o -and $o.result -and $o.result.value) {
      $v = $o.result.value
      if (($v -is [string]) -and -not ($v.TrimStart().StartsWith("{") -or $v.TrimStart().StartsWith("["))) { return $v }
      return ($v | ConvertFrom-Json)
    }
  } catch { $script:LastEvalError = "parse"; return $null }
  $script:LastEvalError = "no_value"
  return $null
}

$cfg = Get-WaConfig
$state = Get-WaState
$mode = "search_only"; $maxJoin = 0; $allowApproval = $true
if ($cfg) {
  if ($cfg.PSObject.Properties.Name -contains "mode") { $mode = [string]$cfg.mode }
  if ($cfg.PSObject.Properties.Name -contains "max_join") { $maxJoin = [int]$cfg.max_join }
  if ($cfg.PSObject.Properties.Name -contains "allow_approval_request") { $allowApproval = [bool]$cfg.allow_approval_request }
}
$items = @($state.items | ForEach-Object { Initialize-WaItem $_ })
$blockedJoins = @("unknown", "待审批(需复核)", "待审批(未提交)", "已加入", "已处理")
$oneShot = [bool]$OneShot
$oneShotFailed = $false
$oneShotStop = $false
if ($oneShot) {
  if ($MaxActions -lt 1 -or $MaxActions -gt 2) {
    Say ("one-shot refused: MaxActions must be 1..2 (got " + $MaxActions + ")")
    exit 2
  }
  if (Test-GOpsStop $baseDir) {
    Say "one-shot refused: stop.flag present"
    exit 4
  }
  $plan = Get-WaOneShotPlan -TargetCode $TargetCode -Publisher $Publisher -Whitelist $PublisherWhitelist -Items $items
  if (-not $plan.ok) {
    Say ("one-shot refused: " + $plan.reason)
    exit 2
  }
  $todo = @($plan.item)
  $MaxVerify = 1
  $allowApproval = $false
  if ($AllowJoin) { $mode = "search_join"; $maxJoin = 1 } else { $mode = "search_only"; $maxJoin = 0 }
  Say ("one-shot code=" + ([string]$plan.item.code) + " allow_join=" + [string]([bool]$AllowJoin) + " max_actions=" + $MaxActions)
} else {
  $todo = @($items | Where-Object {
    $st = [string](Get-WaField $_ "status" "")
    $jn = [string](Get-WaField $_ "join" "")
    $as = [string](Get-WaField $_ "attempt_state" "")
    ($Force -or $st -eq "待验证") -and -not ($blockedJoins -contains $jn) -and -not (@("prepared","clicked","uncertain") -contains $as)
  })
}
if (-not $oneShot -and $MaxVerify -gt 0 -and $todo.Count -gt $MaxVerify) { $todo = $todo[0..($MaxVerify - 1)] }
Say ("start mode=" + $mode + " max_join=" + $maxJoin + " todo=" + $todo.Count)
Ev ("wa verify start (todo=" + $todo.Count + ", mode=" + $mode + ")")

$probe = @'
(function(){
  var ds=document.querySelectorAll('div[role=dialog]');
  var d=ds.length?ds[ds.length-1]:null;
  var btns=[]; if(d){Array.prototype.forEach.call(d.querySelectorAll('button,div[role=button],a'),function(b){var t=(b.innerText||'').trim();if(t)btns.push(t);});}
  var main=document.querySelector('#main header');
  var body=document.body?document.body.innerText:'';
  return JSON.stringify({ndlg:ds.length, dlg:d?d.innerText.slice(0,1500):'', btns:btns.slice(0,15), hdr:main?main.innerText.slice(0,200):'', body:body.slice(0,2000), url:location.href, loggedIn:!!document.querySelector('#pane-side')});
})()
'@

$joinedThisRun = 0
$totalActions = 0
$targetActions = @{}
foreach ($it in $todo) {
  if ($oneShot -and (Test-GOpsStop $baseDir)) { $oneShotStop = $true; break }
  $code = [string](Get-WaField $it "code" "")
  $acc = "https://web.whatsapp.com/accept?code=" + $code
  try { & $cdp -Method "Page.bringToFront" -ParamsJson '{}' -Match "web.whatsapp" | Out-Null } catch {}
  try { & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $acc } | ConvertTo-Json -Compress) -Match "web.whatsapp" | Out-Null } catch {}

  $payload = $null
  $probeError = $false
  $loginUnknown = $false
  $tries = [int]([Math]::Ceiling($WaitSec / 3))
  for ($i = 0; $i -lt $tries; $i++) {
    Start-Sleep -Seconds 3
    $pl = Eval $probe
    if (-not $pl) {
      if ($script:LastEvalError) { $probeError = $true }
      continue
    }
    $hasLogged = ($pl.PSObject.Properties.Name -contains "loggedIn")
    if (-not $hasLogged -or -not [bool]$pl.loggedIn) {
      $loginUnknown = $true
      $payload = $pl
      break
    }
    $bt = (@($pl.btns) -join "|")
    $tooltip = ([string]$pl.dlg -match "(?i)(view recent calls|start a new one|use the search bar)") -and (@($pl.btns).Count -lt 2)
    $isInvite = ($bt -match "(?i)(join group|request to join|view group|open chat)") -or (@($pl.btns).Count -ge 2 -and -not $tooltip)
    if ($isInvite) { $payload = $pl; break }
    $payload = $pl
  }

  $status = "访问失败"; $name = ""; $desc = ""; $joinState = "未加入"
  $probeUnknown = $false
  if (-not $payload) {
    $status = "待确认"; $joinState = "unknown"; $probeUnknown = $true
    Say ("probe unresolved: " + $script:LastEvalError)
  } elseif ($loginUnknown) {
    $status = "需登录"; $joinState = "unknown"
    Say "login state unconfirmed; refusing to act"
  } else {
    $bt = (@($payload.btns) -join "|")
    $dlg = [string]$payload.dlg
    $body = [string]$payload.body
    if ($bt -match "(?i)join group") { $status = "可加入" }
    elseif ($bt -match "(?i)request to join|admin must approve") { $status = "需审批" }
    elseif ($bt -match "(?i)(view group|open chat)") { $status = "已在群内"; $joinState = "已在群内" }
    elseif ($dlg -match "(?i)(couldn.t join|invalid|expired|no longer)") { $status = "已失效" }
    elseif ($body -match "(?i)(don.t close this window|downloading)") { $status = "同步中" }
    elseif ($body -match "(?i)(scan.*qr|link with phone|log in to whatsapp|use whatsapp on your phone)") { $status = "需登录"; $joinState = "unknown"; $loginUnknown = $true }
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

  if ($oneShot -and ($probeUnknown -or $loginUnknown -or $status -eq "访问失败" -or $status -eq "待确认")) {
    $oneShotFailed = $true
    $joinState = "unknown"
    Say ("one-shot fail-closed: status=" + $status + " err=" + $script:LastEvalError)
  } elseif ($oneShot) {
    $stopNow = Test-GOpsStop $baseDir
    $prior = 0
    if ($targetActions.ContainsKey($code)) { $prior = [int]$targetActions[$code] }
    $decision = Get-WaActionDecision -Status $status -AllowJoin ([bool]$AllowJoin) -AllowApproval $false -Stop $stopNow -Failed $oneShotFailed -TargetActions $prior -TotalActions $totalActions -MaxActions $MaxActions
    if ($decision -eq "stop") { $oneShotStop = $true; break }
    elseif ($decision -eq "failed_stop") { break }
    elseif ($decision -eq "duplicate_target") { $joinState = "已处理"; Say ("one-shot skip: " + $code + " already acted") }
    elseif ($decision -eq "action_cap") { $joinState = "未动作"; Say ("one-shot stop: total action cap " + $MaxActions + " reached"); break }
    elseif ($decision -eq "approval_not_allowed") { $joinState = "待审批(未提交)" }
    elseif ($decision -eq "join") {
      if (Test-GOpsStop $baseDir) { $oneShotStop = $true; break }
      $att = Begin-WaAttempt $it $Publisher $code $name
      Say ("one-shot attempt " + $att.attempt_id.Substring(0, 8) + " prepared for " + $code)
      $r = Eval "(function(){var ds=document.querySelectorAll('div[role=dialog]');var d=ds[ds.length-1];if(!d)return 'no-dialog';var b=Array.prototype.find.call(d.querySelectorAll('button'),function(x){return /join group/i.test(x.innerText||'')});if(!b)return 'no-btn';b.click();return 'clicked';})()"
      Start-Sleep -Seconds 6
      $after = Eval $probe
      $post = Get-WaPostClickOutcome -Kind "join" -Before $payload -After $after -TargetCode $code -TargetName $name
      if ([string]$r -eq "clicked") {
        $totalActions++
        $targetActions[$code] = $prior + 1
        if ($post.state -eq "joined" -and $post.joined) {
          $status = "已在群内"; $joinState = "已加入"
          $joinedThisRun++
          End-WaAttempt $it "confirmed" "post-click member"
          Ev ("wa one-shot join verified: " + $code)
        } elseif ($post.state -eq "pending") {
          $status = "需审批"; $joinState = "待审批(需复核)"
          End-WaAttempt $it "pending" "post-click pending approval"
          $oneShotFailed = $true
          Say ("one-shot join not confirmed: pending approval, not joined")
        } else {
          $status = "待确认"; $joinState = "unknown"
          End-WaAttempt $it "uncertain" ("post-click " + [string]$post.reason)
          $oneShotFailed = $true
          Say ("one-shot join unknown: " + [string]$post.reason)
        }
      } else {
        $oneShotFailed = $true
        $status = "待确认"; $joinState = "unknown"
        End-WaAttempt $it "uncertain" ("click " + [string]$r)
        Say ("one-shot join click failed: " + [string]$r)
      }
    }
  } elseif ($mode -eq "search_join" -and $maxJoin -gt 0 -and $joinedThisRun -lt $maxJoin -and $rel -eq "high" -and -not $DryRun) {
    if ($status -eq "可加入") {
      $att = Begin-WaAttempt $it "" $code $name
      Say ("attempt " + $att.attempt_id.Substring(0, 8) + " prepared for " + $code)
      $r = Eval "(function(){var ds=document.querySelectorAll('div[role=dialog]');var d=ds[ds.length-1];if(!d)return 'no-dialog';var b=Array.prototype.find.call(d.querySelectorAll('button'),function(x){return /join group/i.test(x.innerText||'')});if(!b)return 'no-btn';b.click();return 'clicked';})()"
      Start-Sleep -Seconds 6
      $after = Eval $probe
      $post = Get-WaPostClickOutcome -Kind "join" -Before $payload -After $after -TargetCode $code -TargetName $name
      if ([string]$r -eq "clicked" -and $post.state -eq "joined" -and $post.joined) {
        $status = "已在群内"; $joinState = "已加入"; $joinedThisRun++; End-WaAttempt $it "confirmed" "post-click member"; Ev ("wa join verified: " + $code)
      } elseif ([string]$r -eq "clicked" -and $post.state -eq "pending") {
        $status = "需审批"; $joinState = "待审批(需复核)"; End-WaAttempt $it "pending" "post-click pending approval"; Ev ("wa join pending, not joined: " + $code)
      } else {
        $status = "待确认"; $joinState = "unknown"; End-WaAttempt $it "uncertain" ("post-click " + [string]$post.reason); Say ("wa join unknown: " + [string]$post.reason)
      }
    } elseif ($status -eq "需审批" -and $allowApproval) {
      $att = Begin-WaAttempt $it "" $code $name
      Say ("attempt " + $att.attempt_id.Substring(0, 8) + " prepared for " + $code + " approval")
      $r = Eval "(function(){var ds=document.querySelectorAll('div[role=dialog]');var d=ds[ds.length-1];if(!d)return 'no-dialog';var b=Array.prototype.find.call(d.querySelectorAll('button'),function(x){return /request to join/i.test(x.innerText||'')});if(!b)return 'no-btn';b.click();return 'clicked';})()"
      Start-Sleep -Seconds 4
      $after = Eval $probe
      $post = Get-WaPostClickOutcome -Kind "approval" -Before $payload -After $after -TargetCode $code -TargetName $name
      if ([string]$r -eq "clicked" -and $post.state -eq "pending") {
        $status = "需审批"; $joinState = "已提交待审批"; End-WaAttempt $it "pending" "post-click pending approval"; Ev ("wa approval pending: " + $code)
      } else {
        $status = "待确认"; $joinState = "unknown"; End-WaAttempt $it "uncertain" ("post-click " + [string]$post.reason); Say ("wa approval unknown: " + [string]$post.reason)
      }
    }
  } elseif ($status -eq "需审批") { $joinState = "待审批(未提交)" }

  for ($k = 0; $k -lt $items.Count; $k++) {
    if ([string](Get-WaField $items[$k] "code" "") -eq $code) {
      Set-WaField $items[$k] "name" $name
      Set-WaField $items[$k] "region" $lr.region
      Set-WaField $items[$k] "lang" $lr.lang
      Set-WaField $items[$k] "purpose" $purpose
      Set-WaField $items[$k] "relevance" $rel
      Set-WaField $items[$k] "status" $status
      Set-WaField $items[$k] "join" $joinState
      Set-WaField $items[$k] "checkedAt" ((Get-Date).ToString("s"))
      break
    }
  }
  Say ($code + " -> " + $status + " rel=" + $rel + " name=" + $name)
}

Set-WaField $state "items" $items
Save-WaState $state
if ($oneShotStop) { Say "one-shot STOP: stop.flag present"; exit 4 }
if ($oneShotFailed) { Say "one-shot FAILED: action failed, not retried"; exit 5 }
Say ("DONE joined=" + $joinedThisRun)
Ev ("wa verify done: joined=" + $joinedThisRun)
