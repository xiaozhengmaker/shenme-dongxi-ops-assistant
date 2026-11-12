param(
  [Parameter(Mandatory=$true)][string]$Group,
  [int]$Port = 0,
  [string]$Match = "steamcommunity.com",
  [int]$WaitSec = 6,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\paths.ps1")
if ($Port -le 0) { $Port = (Get-GOpsPort (Get-GOpsConfig)) }
$root = "D:\DeepSeek\运营"
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
  leaveBtn: Array.from(document.querySelectorAll('a,input')).some(function(x){var t=(x.innerText||x.value||'').trim();return t==='Leave Group'||t==='离开组';})
})
'@
$before = Eval $probe
Log "BEFORE $before"

$b = $before | ConvertFrom-Json
if ($b.isMember) { Log "SKIP 已是成员"; exit 0 }
if (-not $b.joinForm) { Log "SKIP 无 join_group_form（可能需要邀请/私密组）"; exit 0 }
if ($DryRun) { Log "DRY RUN 可加入"; exit 0 }

Log "JOIN submit join_group_form"
$submit = @'
(function(){var f=document.getElementById('join_group_form'); if(!f) return 'no-form'; f.submit(); return 'submitted';})()
'@
$r = Eval $submit
Log "SUBMIT $r"
Start-Sleep -Seconds $WaitSec

$after = Eval $probe
Log "AFTER $after"
$a = $after | ConvertFrom-Json
$ok = ([bool]$a.leaveBtn -or [bool]$a.isMember)
# Steam 在「已经是成员」时返回错误页，文案含 already a member，这其实代表加入成功
if (-not $ok -and $after -match 'already a member') { $ok = $true }
Log ("RESULT " + $(if ($ok) { "joined" } else { "not_joined" }) + " group=$Group")

# 上报到 hub 的运行实况（ASCII，避免中文被命令行编码吞掉）
try {
  $evMsg = "steam join " + $Group + " => " + $(if ($ok) { "joined" } else { "not_joined" })
  $payload = @{ msg = $evMsg } | ConvertTo-Json -Compress
  Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -ContentType "application/json" -Body $payload -TimeoutSec 5 | Out-Null
} catch { }


$csv = Join-Path $root "data\steam_joins.csv"
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $csv)) {
  [System.IO.File]::WriteAllText($csv, "时间,群ID,群名,结果,来源`r`n", $utf8bom)
}
$line = "$stamp,$Group,$($a.name),$(if($ok){'joined'}else{'not_joined'}),手动风控试加`r`n"
[System.IO.File]::AppendAllText($csv, $line, $utf8)
Log "WROTE $csv"
if (-not $ok) { exit 3 }
