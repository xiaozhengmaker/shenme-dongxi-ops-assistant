param(
  [string]$HubPath = "",
  [string]$LibDir = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $HubPath) { $HubPath = Join-Path $root "hub.ps1" }
if (-not $LibDir) { $LibDir = Join-Path $root "lib" }
$fails = New-Object System.Collections.ArrayList
function Assert-That([bool]$cond, [string]$name, [string]$detail = "") {
  if ($cond) { Write-Host ("  PASS " + $name) } else { Write-Host ("  FAIL " + $name + " :: " + $detail); $null = $fails.Add($name) }
}
$hubText = [System.IO.File]::ReadAllText($HubPath, [System.Text.Encoding]::UTF8)
$sha16 = (Get-FileHash -LiteralPath $HubPath -Algorithm SHA256).Hash.Substring(0, 16)
$lines = $hubText -split "`r?`n"
$startIdx = -1; $endIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($startIdx -lt 0 -and $lines[$i] -match 'if \(-not \$adv\.advance -and \[string\]\$adv\.code -ne "complete"\)') { $startIdx = $i }
  if ($startIdx -ge 0 -and $endIdx -lt 0 -and $lines[$i] -match 'Add-Event \("本轮结束 · 加入') { $endIdx = $i; break }
}
Write-Host ("[extract] hub sha16=" + $sha16 + " guard L" + ($startIdx + 1) + " end L" + ($endIdx + 1))
if ($startIdx -lt 0 -or $endIdx -le $startIdx) { Write-Host "  FAIL extract-block"; exit 2 }
$block = ($lines[$startIdx..$endIdx] -join "`r`n")
$wrapped = "for (`$__once = 0; `$__once -lt 1; `$__once++) {`r`n" + $block + "`r`n}"

. (Join-Path $LibDir "run_plan_gate.ps1")

function script:Send-Json($ctx, $code, $obj) { $script:calls.json += @{ code = $code; obj = $obj } }
function script:Add-Event([string]$m) { $script:calls.events += $m }
function script:Complete-RunControl { param($BaseDir, $RunId) $script:calls.complete++ }
function script:Update-RunControlPlatform { param($BaseDir, $RunId, $Platform) $script:calls.updatePlatform++ }
function script:Write-HubRunSummary { param($Ok, $Code, $Reason) $script:calls.summary += @{ ok = $Ok; code = $Code; reason = $Reason } }
function script:Write-PlanHeartbeat { param($BaseDir, $RunId, $Platform) $script:calls.heartbeat++ }
function script:Test-GOpsStop($h) { return $script:stopFlag }

$sb = [scriptblock]::Create($wrapped)
function Invoke-Block {
  $script:calls = @{ json = @(); events = @(); complete = 0; updatePlatform = 0; summary = @(); heartbeat = 0 }
  & $sb
}

# ---- Case A: inflight（pending 未确认）→ 不清计划、不判成功、不写 not_executed ----
$script:stopFlag = $false
$here = $root; $ctx = @{}
$adv = @{ advance = $false; code = "unresolved_inflight" }
$state = @{
  plan = @("Telegram", "Steam"); planIndex = 0; planRunId = "test-run-A"; skipApplied = @{}
  phase = "join"; running = $true; current = "探测中"
  joined = 0; existing = 0; local = 0; skipped = 0; failed = 1; filtered = 0
  ledger = @{
    "k1" = [pscustomobject]@{ key = "k1"; dispatched = $true; outcome = "" }
    "k2" = [pscustomobject]@{ key = "k2"; dispatched = $true; outcome = "" }
  }
}
$script:Platform = "Telegram"
Invoke-Block
$null = $sb
$pendA = @($state.ledger.Values | Where-Object { $_.outcome -eq "unconfirmed" }).Count
Assert-That ($state.phase -eq "unresolved_inflight") "inflight: phase=unresolved_inflight" ("phase=" + $state.phase)
Assert-That ($state.running -eq $false) "inflight: running=false"
Assert-That (@($state.plan).Count -eq 2) "inflight: plan kept" ("count=" + @($state.plan).Count)
Assert-That ($state.planRunId -eq "test-run-A") "inflight: run_id kept"
Assert-That ($pendA -eq 2) "inflight: dispatched marked unconfirmed" ("unconfirmed=" + $pendA)
Assert-That (@($state.ledger.Values | Where-Object { $_.outcome -eq "not_executed" }).Count -eq 0) "inflight: no not_executed"
Assert-That ($script:calls.summary.Count -eq 1 -and $script:calls.summary[0].ok -eq $false -and $script:calls.summary[0].code -eq "unresolved_inflight") "inflight: summary ok=false code=unresolved_inflight" (($script:calls.summary | ConvertTo-Json -Compress))
Assert-That ($script:calls.complete -eq 0) "inflight: run_control not completed"

# ---- Case B: 正常收尾（complete，无 pending）→ 清计划、ok=true、未派发记 not_executed ----
$adv = @{ advance = $false; code = "complete" }
$state = @{
  plan = @("Telegram"); planIndex = 0; planRunId = "test-run-B"; skipApplied = @{}
  phase = "join"; running = $true; current = "准备开始"
  joined = 2; existing = 1; local = 0; skipped = 0; failed = 0; filtered = 0
  ledger = @{
    "k1" = [pscustomobject]@{ key = "k1"; dispatched = $true; outcome = "joined" }
    "k2" = [pscustomobject]@{ key = "k2"; dispatched = $false; outcome = "" }
  }
}
Invoke-Block
Assert-That ($state.phase -eq "done") "complete: phase=done"
Assert-That ($state.running -eq $false) "complete: running=false"
Assert-That (@($state.plan).Count -eq 0 -and $state.planRunId -eq "") "complete: plan cleared"
Assert-That ($state.ledger["k2"].outcome -eq "not_executed") "complete: undispatched -> not_executed" ("k2=" + $state.ledger["k2"].outcome)
Assert-That ($script:calls.summary.Count -eq 1 -and $script:calls.summary[0].ok -eq $true -and $script:calls.summary[0].code -eq "complete") "complete: summary ok=true code=complete" (($script:calls.summary | ConvertTo-Json -Compress))
Assert-That ($script:calls.complete -eq 1) "complete: run_control completed once"

if ($fails.Count -gt 0) { Write-Host ("RESULT fail=" + $fails.Count + " :: " + ($fails -join "; ")); exit 1 }
Write-Host "RESULT pass=14 fail=0"
exit 0
