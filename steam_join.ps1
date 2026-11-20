param(
  [Parameter(Mandatory=$true)][string]$Group,
  [int]$Port = 9222,
  [string]$Match = "steamcommunity.com",
  [int]$WaitSec = 6,
  [switch]$DryRun,
  [switch]$Offline
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
. (Join-Path $root "lib\join_result.ps1")
. (Join-Path $root "lib\stop.ps1")
. (Join-Path $root "lib\run_control.ps1")
if (Test-WorkerStop $root) { Write-Host "SKIP stop signal"; exit 0 }
$cdp = Join-Path $root "cdp_call.ps1"
$logDir = Join-Path $root "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir "steam_join.log"
$stamp = (Get-Date).ToString("yyyy/MM/dd HH:mm:ss")

function Log([string]$msg) {
  $line = "$stamp [steam_join] $msg"
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding UTF8
}

function Eval([string]$js) {
  $p = @{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress -Depth 6
  $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match $Match
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json).result.value } catch { return $null }
}

$url = "https://steamcommunity.com/groups/$Group/"
Log "NAV $url"
$nav = @{ url = $url } | ConvertTo-Json -Compress
& $cdp -Method "Page.navigate" -ParamsJson $nav -Match $Match | Out-Null
Start-Sleep -Seconds 6

$probe = @'
JSON.stringify({
  title: document.title,
  name: (function(){var e=document.querySelector('.grouppage_header_name');return e?e.innerText.trim():'';})(),
  joinForm: !!document.getElementById('join_group_form'),
  isMember: (document.body.innerText||'').includes('您是该组成员') || (document.body.innerText||'').includes('You are a member'),
  pending: /您的?加入(小组)?请求|加入请求正在等待|request to join[^.]*pending|join request[^.]*pending/i.test(document.body.innerText||''),
  leaveBtn: Array.from(document.querySelectorAll('a,input')).some(function(x){var t=(x.innerText||x.value||'').trim();return t==='Leave Group'||t==='离开组';})
})
'@
$before = Eval $probe
Log "BEFORE $before"

$b = $before | ConvertFrom-Json
if ($b.isMember) { Log "SKIP 已是成员"; exit 0 }
if ($b.pending) { Log "SKIP 已待审批（不再提交）"; exit 0 }
if (-not $b.joinForm) { Log "SKIP 无 join_group_form（可能需要邀请/私密组）"; exit 0 }
if ($DryRun) { Log "DRY RUN 可加入"; exit 0 }
if (Test-WorkerStop $root) { Log "SKIP stop signal before submit"; exit 0 }

Log "JOIN submit join_group_form"
$submit = @'
(function(){var f=document.getElementById('join_group_form'); if(!f) return 'no-form'; f.submit(); return 'submitted';})()
'@
$r = Eval $submit
Log "SUBMIT $r"
Start-Sleep -Seconds $WaitSec

$after = Eval $probe
Log "AFTER $after"
$a = $null
try { if ($after) { $a = $after | ConvertFrom-Json } } catch { }
$outcome = Get-SteamJoinOutcome -Before $b -After $a -AfterText ([string]$after)
Log ("RESULT " + $outcome + " group=$Group")

# 上报到 hub 的运行实况（离线测试 / -Offline 时不发任何请求）
if (-not $Offline) {
  try {
    $evMsg = "steam join " + $Group + " => " + $outcome
    $payload = @{ msg = $evMsg } | ConvertTo-Json -Compress
    Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -ContentType "application/json" -Body $payload -TimeoutSec 5 | Out-Null
  } catch { }
}


$csv = Join-Path $root "data\steam_joins.csv"
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $csv)) {
  [System.IO.File]::WriteAllText($csv, "时间,群ID,群名,结果,来源`r`n", $utf8bom)
}
$name = if ($a) { [string]$a.name } else { "" }
$line = "$stamp,$Group,$name,$outcome,手动风控试加`r`n"
[System.IO.File]::AppendAllText($csv, $line, $utf8)
Log "WROTE $csv"
if ($outcome -eq "not_joined") { exit 3 }
