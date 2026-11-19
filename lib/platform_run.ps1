# platform_run.ps1 -- platform sequence orchestration used by run_all.ps1.
# Start/Wait are injected scriptblocks so the sequence is testable without a hub.
# A "cooldown" start result only skips that platform; a "stopped" result ends the
# round cleanly; any other start/wait error is a global failure and must abort.

function Invoke-PlatformSequence {
  param(
    [string[]]$Platforms,
    [scriptblock]$Start,
    [scriptblock]$Wait,
    [scriptblock]$IsStopped,
    [scriptblock]$Say
  )

  $started = New-Object System.Collections.ArrayList
  $skipped = New-Object System.Collections.ArrayList
  $failed = New-Object System.Collections.ArrayList

  foreach ($p in @($Platforms)) {
    if ($IsStopped -and (& $IsStopped)) {
      return @{ status = "stopped"; started = @($started); skipped = @($skipped); failed = @($failed); error = "stopped" }
    }

    $startRes = $null
    try {
      $startRes = & $Start $p
    } catch {
      $msg = [string]$_.Exception.Message
      if ($Say) { & $Say ("全局启动失败 " + $p + "：" + $msg) }
      return @{ status = "global_failure"; started = @($started); skipped = @($skipped); failed = @($failed); error = $msg }
    }
    if (-not $startRes) { $startRes = @{ ok = $false; error = "empty_start_result" } }
    $err = [string]$startRes.error
    if (-not $startRes.ok) {
      if ($err -eq "cooldown") {
        [void]$skipped.Add($p)
        if ($Say) { & $Say ("平台 " + $p + " 冷却中，跳过") }
        continue
      }
      if ($err -eq "stopped") {
        if ($Say) { & $Say ("平台 " + $p + " 已停止") }
        return @{ status = "stopped"; started = @($started); skipped = @($skipped); failed = @($failed); error = "stopped" }
      }
      if ($Say) { & $Say ("全局启动失败 " + $p + "：" + $err) }
      return @{ status = "global_failure"; started = @($started); skipped = @($skipped); failed = @($failed); error = $err }
    }

    [void]$started.Add($p)
    $done = $false
    try {
      $done = [bool](& $Wait $p)
    } catch {
      $msg = [string]$_.Exception.Message
      if ($Say) { & $Say ("全局等待失败 " + $p + "：" + $msg) }
      return @{ status = "global_failure"; started = @($started); skipped = @($skipped); failed = @($failed); error = $msg }
    }
    if (-not $done) {
      [void]$failed.Add($p)
      if ($Say) { & $Say ("平台 " + $p + " 超时") }
    }
    if ($IsStopped -and (& $IsStopped)) {
      return @{ status = "stopped"; started = @($started); skipped = @($skipped); failed = @($failed); error = "stopped" }
    }
  }

  return @{ status = "completed"; started = @($started); skipped = @($skipped); failed = @($failed); error = "" }
}
