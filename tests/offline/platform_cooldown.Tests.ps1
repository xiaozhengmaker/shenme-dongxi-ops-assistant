$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "asserts.ps1")

$lib = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\platform_cooldown.ps1"
if (Test-Path $lib) { . $lib }

$hasGet = [bool](Get-Command Get-PlatformCooldown -ErrorAction SilentlyContinue)
$hasSet = [bool](Get-Command Set-PlatformCooldown -ErrorAction SilentlyContinue)
$hasClear = [bool](Get-Command Clear-PlatformCooldown -ErrorAction SilentlyContinue)
$hasDecision = [bool](Get-Command Get-PlatformStartDecision -ErrorAction SilentlyContinue)

Check $hasGet "cooldown: Get-PlatformCooldown exists"
Check $hasSet "cooldown: Set-PlatformCooldown exists"
Check $hasClear "cooldown: Clear-PlatformCooldown exists"
Check $hasDecision "cooldown: Get-PlatformStartDecision exists"

$tmp = Join-Path $env:TEMP ("gops-cool-" + [guid]::NewGuid().ToString("N") + ".json")
$env:GOPS_PLATFORM_COOLDOWN_FILE = $tmp
try {
  if ($hasSet -and $hasGet) {
    $t0 = [datetime]::Parse("2026-11-19T10:00:00+08:00", [System.Globalization.CultureInfo]::InvariantCulture)
    Set-PlatformCooldown -Path $tmp -Platform "Reddit" -Minutes 30 -Reason "collector_stalled" -Now $t0 | Out-Null
    $active = Get-PlatformCooldown -Path $tmp -Platform "Reddit" -Now $t0.AddMinutes(10)
    Check ($null -ne $active) "cooldown: active at +10m"
    CheckEqual 1200 $active.remaining_sec "cooldown: remaining seconds at +10m"
    CheckEqual "collector_stalled" $active.reason "cooldown: reason persisted"
    $expired = Get-PlatformCooldown -Path $tmp -Platform "Reddit" -Now $t0.AddMinutes(31)
    Check ($null -eq $expired) "cooldown: expired at +31m"

    Set-PlatformCooldown -Path $tmp -Platform "Facebook" -Minutes 5 -Reason "manual" -Now $t0 | Out-Null
    $reddit = Get-PlatformCooldown -Path $tmp -Platform "reddit" -Now $t0.AddMinutes(1)
    Check ($null -ne $reddit) "cooldown: platform lookup is case-insensitive"
    $fb = Get-PlatformCooldown -Path $tmp -Platform "Facebook" -Now $t0.AddMinutes(1)
    Check ($null -ne $fb) "cooldown: other platform preserved"
    if ($hasClear) {
      Clear-PlatformCooldown -Path $tmp -Platform "Reddit"
      $cleared = Get-PlatformCooldown -Path $tmp -Platform "Reddit" -Now $t0.AddMinutes(1)
      Check ($null -eq $cleared) "cooldown: clear removes platform"
    }
  }

  if ($hasDecision) {
    $cd = [pscustomobject]@{ until = [datetime]::Parse("2026-11-19T10:30:00+08:00"); remaining_sec = 1800; reason = "collector_stalled" }
    $now = [datetime]::Parse("2026-11-19T10:00:00+08:00")
    $d = Get-PlatformStartDecision -Platform "Reddit" -StopFlag $true -Cooldown $cd -Now $now
    Check (-not $d.allow) "decision: stop flag blocks"
    CheckEqual "stopped" $d.reason "decision: stop reason"

    $d = Get-PlatformStartDecision -Platform "Reddit" -StopFlag $false -Cooldown $cd -Now $now
    Check (-not $d.allow) "decision: active cooldown blocks"
    CheckEqual "cooldown" $d.reason "decision: cooldown reason"
    CheckEqual 1800 $d.remaining_sec "decision: cooldown remaining"

    $d = Get-PlatformStartDecision -Platform "Reddit" -StopFlag $false -Cooldown $null -Now $now
    Check $d.allow "decision: no stop/no cooldown allows"
    CheckEqual "allowed" $d.reason "decision: allowed reason"
  }
} finally {
  Remove-Item Env:GOPS_PLATFORM_COOLDOWN_FILE -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Finish-Tests
