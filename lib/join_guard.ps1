# join_guard.ps1 -- offline-testable helpers for join-record counters and the
# single-target validation gate. Pure functions only; no network, no writes.

function Get-JoinRecordStatus {
  param([string]$CloudState, [bool]$LocalOk)
  switch ([string]$CloudState) {
    "added"    { return "added" }
    "existing" { return "existing" }
    "failed"   { return "failed" }
  }
  if ($CloudState -eq "disabled" -and $LocalOk) { return "local" }
  return "failed"
}

function Get-JoinRecordDisposition {
  param([string]$Status)
  $d = @{ joined = 0; existing = 0; local = 0; failed = 0 }
  switch ([string]$Status) {
    "added"    { $d.joined = 1 }
    "existing" { $d.existing = 1 }
    "local"    { $d.local = 1 }
    default    { $d.failed = 1 }
  }
  return $d
}

function Get-JoinDispatchDecision {
  param(
    [string[]]$Whitelist = @(),
    [string[]]$TargetKeys = @(),
    [int]$Dispatched = 0,
    [int]$MaxAttempts = 1
  )
  $allow = @()
  foreach ($w in @($Whitelist)) {
    if ($null -eq $w) { continue }
    $t = ([string]$w).Trim().ToLowerInvariant()
    if ($t) { $allow += $t }
  }
  if ($allow.Count -eq 0) { return @{ allow = $true; reason = "unrestricted"; matched = "" } }

  $keys = @()
  foreach ($k in @($TargetKeys)) {
    if ($null -eq $k) { continue }
    $t = ([string]$k).Trim().ToLowerInvariant()
    if ($t) { $keys += $t }
  }
  if ($keys.Count -eq 0) { return @{ allow = $false; reason = "target_unknown"; matched = "" } }

  $hit = ""
  foreach ($k in $keys) {
    foreach ($a in $allow) {
      if ($a -eq $k) { $hit = $k; break }
    }
    if ($hit) { break }
  }
  if (-not $hit) { return @{ allow = $false; reason = "not_whitelisted"; matched = "" } }
  if ($Dispatched -ge $MaxAttempts) { return @{ allow = $false; reason = "attempt_cap"; matched = $hit } }
  return @{ allow = $true; reason = "allowed"; matched = $hit }
}
