function Invoke-RoundRun {
  param(
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [Parameter(Mandatory=$true)][string[]]$Plan,
    [string]$RunId = "",
    [ValidateSet("manual","daily")][string]$Entry = "manual",
    [hashtable]$Runners = @{},
    [int]$AckTimeoutSec = 2,
    [int]$AckPollMs = 100
  )
  $ErrorActionPreference = "Stop"
  if ((Split-Path $WorkDir -Leaf) -eq "data") { $d = $WorkDir } else { $d = Join-Path $WorkDir "data" }
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  if (-not $RunId) { $RunId = "iso-" + (Get-Date -Format "yyyyMMdd-HHmmss") }
  $planList = @($Plan | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
  $startedAt = (Get-Date); $st = @{ run_id=$RunId; entry=$Entry; started_at=$startedAt.ToString("s"); state="running"; platform=""; plan=@($planList); plan_index=0; order=@(); ledger=@{}; updated_at=(Get-Date).ToString("s") }
  function SaveSt { param($St) $St.updated_at = (Get-Date).ToString("s"); ($St | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $d "run_control.json") -Encoding UTF8 }
  SaveSt $st
  for ($i = 0; $i -lt $planList.Count; $i++) {
    $p = $planList[$i]
    if (Test-Path (Join-Path $d "ctl_emergency")) { $st.state = "emergency_stopped"; break }
    if (Test-Path (Join-Path $d "ctl_stop")) { $st.state = "stopped"; break }
    if (Test-Path (Join-Path $d "ctl_skip")) {
      $sk = (Get-Content (Join-Path $d "ctl_skip") -Raw).Trim()
      if ($sk -eq $p) {
        Remove-Item (Join-Path $d "ctl_skip") -Force
        $st.order += @{ platform=$p; result="skip_operator"; pending=0 }
        SaveSt $st
        continue
      }
    }
    if (-not $Runners.ContainsKey($p)) { $st.state = "platform_failure"; break }
    $res = & $Runners[$p] $p $d
    if ($null -eq $res) { $res = @{ result="platform_failure" } }
    foreach ($it in @($res.items)) {
      if ($null -eq $it) { continue }
      $k = [string]$it.key; if (-not $k) { continue }
      $st.ledger[$k] = @{ key=$k; name=[string]$it.name; platform=$p; dispatched=[bool]$it.dispatched; outcome=[string]$it.outcome; updated_at=(Get-Date).ToString("s") }
    }
    if ($res.inflight) {
      $ackFile = Join-Path $d ("ack_" + $p)
      $deadline = (Get-Date).AddSeconds($AckTimeoutSec)
      while (-not (Test-Path $ackFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds $AckPollMs }
      if (Test-Path $ackFile) {
        $mapFile = Join-Path $d ("resolve_" + $p + ".json")
        if (Test-Path $mapFile) {
          $map = Get-Content $mapFile -Raw | ConvertFrom-Json
          foreach ($k in $st.ledger.Keys) {
            $o = $map.$k
                if ($o -and [string]$st.ledger[$k].platform -eq $p) { $st.ledger[$k].outcome = [string]$o; $st.ledger[$k].updated_at = (Get-Date).ToString("s") }
          }
        }
      }
    }
    $pend = 0
    foreach ($k in $st.ledger.Keys) {
      $e = $st.ledger[$k]
      if (-not $e -or [string]$e.platform -ne $p) { continue }
      if ([string]$e.outcome -eq "unconfirmed") { $pend++; continue }
      if ($e.dispatched -and -not $e.outcome) { $e.outcome = "unconfirmed"; $pend++ }
    }
    $st.platform = $p; $st.plan_index = $i
    $st.order += @{ platform=$p; result=[string]$res.result; pending=$pend }
    SaveSt $st
    if ($res.shared) { $st.state = "global_failure"; break }
    if ($pend -gt 0) { $st.order[-1].result = "platform_partial"; $st.order[-1].pending = $pend }
    if ($res.result -eq "stop_round") { $st.state = "stopped"; break }
    if ($res.result -eq "emergency") { $st.state = "emergency_stopped"; break }
    if ($i -lt ($planList.Count - 1)) { continue }
    $st.state = "complete"
  }
  if ($st.state -eq "running") { $st.state = "complete" }
  $c = @{ joined=0; existing=0; failed=0; pending=0; skipped=0; other=0 }
  foreach ($k in $st.ledger.Keys) {
    $o = [string]$st.ledger[$k].outcome
    if ($o -eq "joined") { $c.joined++ } elseif ($o -eq "existing") { $c.existing++ } elseif ($o -eq "failed") { $c.failed++ }
    elseif ($o -eq "unconfirmed") { $c.pending++ } elseif ($o -eq "skipped" -or $o -eq "not_executed") { $c.skipped++ } elseif ($o) { $c.other++ }
  }
  $st.summary = $c
  SaveSt $st
  $endedAt = (Get-Date)
        if ($c.pending -gt 0 -and $st.state -eq "complete") { $st.state = "partial_complete" }
        $brief = @("运行 " + $st.started_at + " – " + $endedAt.ToString("s") + " · 入口 " + $Entry, "计划：" + (@($st.plan) -join " → "))
        foreach ($o in @($st.order)) { $brief += ("- " + $o.platform + "：" + [string]$o.result + "（未确认 " + [int]$o.pending + "）") }
        foreach ($p in @($st.plan)) { if (-not (@($st.order) | Where-Object { $_.platform -eq $p })) { $brief += ("- " + $p + "：未运行（前序中止或未开始）") } }
        $brief += ("结论：" + $(if ($st.state -eq "complete") { "全部平台完成" } elseif ($st.state -eq "partial_complete") { "部分完成：有 " + $c.pending + " 个未确认" } else { "中止：" + $st.state }))
        $sum = @{ run_id=$RunId; entry=$Entry; started_at=$st.started_at; ended_at=$endedAt.ToString("s"); duration_min=[int][Math]::Round(($endedAt - $startedAt).TotalMinutes); ok=($st.state -eq "complete"); code=$st.state; reason=(@($st.order | ForEach-Object { $_.result }) -join ","); platforms=@($st.plan); summary=$c; order=$st.order; report=@($brief); report_text=($brief -join "`n") }
  ($sum | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $d "run_summary.json") -Encoding UTF8
  return $st
}
