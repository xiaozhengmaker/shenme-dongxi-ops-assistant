$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "asserts.ps1")

$lib = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\platform_run.ps1"
if (Test-Path $lib) { . $lib }
$hasRun = [bool](Get-Command Invoke-PlatformSequence -ErrorAction SilentlyContinue)
Check $hasRun "run: Invoke-PlatformSequence exists"

if ($hasRun) {
  # 1) normal two-platform run
  $script:starts = New-Object System.Collections.ArrayList
  $script:waits = New-Object System.Collections.ArrayList
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $true } } `
    -Wait { param($p) [void]$script:waits.Add($p); $true } `
    -IsStopped { $false } -Say { param($m) }
  CheckEqual "completed" $r.status "run: two platforms completed"
  CheckEqual "Reddit,Telegram" ($script:starts -join ",") "run: both platforms started"
  CheckEqual 0 @($r.failed).Count "run: no failures"

  # 2) cooldown on first platform: skip it, continue next
  $script:starts.Clear()
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) if ($p -eq "Reddit") { @{ ok = $false; error = "cooldown" } } else { [void]$script:starts.Add($p); @{ ok = $true } } } `
    -Wait { param($p) $true } -IsStopped { $false } -Say { param($m) }
  CheckEqual "completed" $r.status "run: cooldown does not abort round"
  CheckEqual "Telegram" ($script:starts -join ",") "run: cooldown skipped then next platform started"
  CheckEqual "Reddit" (@($r.skipped) -join ",") "run: cooldown platform recorded skipped"

  # 3) stop before any start
  $script:starts.Clear()
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $true } } `
    -Wait { param($p) $true } -IsStopped { $true } -Say { param($m) }
  CheckEqual "stopped" $r.status "run: stop flag before start stops round"
  CheckEqual 0 $script:starts.Count "run: stop flag sends no start"

  # 4) stop after first platform: second must not start
  $script:starts.Clear()
  $script:checks = 0
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $true } } `
    -Wait { param($p) $true } `
    -IsStopped { $script:checks++; ($script:checks -gt 1) } -Say { param($m) }
  CheckEqual "stopped" $r.status "run: stop after first stops round"
  CheckEqual "Reddit" ($script:starts -join ",") "run: second platform not started after stop"

  # 5) global failure on first platform: abort immediately
  $script:starts.Clear()
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $false; error = "hub_unreachable" } } `
    -Wait { param($p) $true } -IsStopped { $false } -Say { param($m) }
  CheckEqual "global_failure" $r.status "run: hub failure is global"
  CheckEqual "Reddit" ($script:starts -join ",") "run: global failure does not start next platform"
  CheckEqual "hub_unreachable" $r.error "run: global failure preserves reason"

  # 6) stopped error from hub: clean stop, no next platform
  $script:starts.Clear()
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $false; error = "stopped" } } `
    -Wait { param($p) $true } -IsStopped { $false } -Say { param($m) }
  CheckEqual "stopped" $r.status "run: hub stopped response stops round"
  CheckEqual "Reddit" ($script:starts -join ",") "run: hub stopped does not start next platform"

  # 7) timeout is a platform failure; continue next
  $script:starts.Clear()
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $true } } `
    -Wait { param($p) ($p -eq "Telegram") } -IsStopped { $false } -Say { param($m) }
  CheckEqual "completed" $r.status "run: timeout does not abort round"
  CheckEqual "Reddit" (@($r.failed) -join ",") "run: timeout recorded platform failure"
  CheckEqual "Reddit,Telegram" ($script:starts -join ",") "run: timeout continues next platform"

  # 8) wait throws: global failure
  $script:starts.Clear()
  $r = Invoke-PlatformSequence -Platforms @("Reddit","Telegram") `
    -Start { param($p) [void]$script:starts.Add($p); @{ ok = $true } } `
    -Wait { param($p) throw "hub down" } -IsStopped { $false } -Say { param($m) }
  CheckEqual "global_failure" $r.status "run: wait exception is global"
  CheckEqual "Reddit" ($script:starts -join ",") "run: wait exception does not start next platform"
}

Finish-Tests
