# hub_control_integration.ps1 -- isolated HTTP-level smoke test for hub control.
# Copies the release to a temp directory, disables Feishu reads, starts hub on a
# dedicated port, and verifies version / ghost repair / stop-run_id validation.
# It never contacts Feishu, Chrome, Telegram, or any production path.
param(
  [string]$SourceDir = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [int]$Port = 18891
)

$ErrorActionPreference = "Stop"
$pass = 0
$fail = 0
function T([string]$name, [scriptblock]$fn) {
  try { & $fn; Write-Host ("PASS  " + $name); $script:pass++ }
  catch { Write-Host ("FAIL  " + $name + " :: " + $_.Exception.Message); $script:fail++ }
}
function A($cond, [string]$msg) { if (-not $cond) { throw $msg } }
if (-not [System.Net.HttpListener]::IsSupported) {
  Write-Host "SKIP  hub HTTP integration: HttpListener is not supported on this host"
  exit 0
}
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

function Http([string]$Method, [string]$Path, $Body = $null) {
  # Use HttpClient (not Invoke-WebRequest): it returns the response for 4xx
  # instead of throwing, so the JSON error body stays available to assertions.
  $handler = New-Object System.Net.Http.HttpClientHandler
  $handler.UseProxy = $false
  $client = New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(15)
  $uri = "http://127.0.0.1:" + $Port + $Path
  $req = $null
  $resp = $null
  try {
    $methodObj = if ($Method -eq "GET") { [System.Net.Http.HttpMethod]::Get } else { [System.Net.Http.HttpMethod]::Post }
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList @($methodObj, $uri)
    if ($null -ne $Body) {
      $json = $Body | ConvertTo-Json -Compress
      $content = New-Object System.Net.Http.StringContent -ArgumentList @($json)
      $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json; charset=utf-8")
      $req.Content = $content
    }
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $parsed = $null
    if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null } }
    return @{ status = [int]$resp.StatusCode; body = $parsed; text = $text }
  } finally {
    if ($resp) { $resp.Dispose() }
    if ($req) { $req.Dispose() }
    $client.Dispose()
  }
}

$temp = Join-Path $env:TEMP ("gops-hub-it-" + [guid]::NewGuid().ToString("N"))
$hubProc = $null
$old = @{
  GOPS_STATE_ROOT = $env:GOPS_STATE_ROOT
  GOPS_RUN_CONTROL_FILE = $env:GOPS_RUN_CONTROL_FILE
  GOPS_STOP_FILE = $env:GOPS_STOP_FILE
  GOPS_TEST_NO_FEISHU = $env:GOPS_TEST_NO_FEISHU
}
try {
  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  foreach ($file in @("hub.ps1","run_all.ps1","run_daily.ps1","config.example.json","lib","extension")) { Copy-Item -LiteralPath (Join-Path $SourceDir $file) -Destination $temp -Recurse }
  Copy-Item -LiteralPath (Join-Path $temp "config.example.json") -Destination (Join-Path $temp "config.json") -Force

  # Keep the smoke test deterministic: each platform gets one marker keyword so
  # the skip test can prove the next platform does not inherit the previous
  # platform's query queue. Only the disposable copy is changed.
  $cfgPath = Join-Path $temp "config.json"
  $cfgObj = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $cfgObj.queries.Facebook = @("fb-only")
  $cfgObj.queries.Telegram = @("tg-only")
  [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))

  # Keep the smoke test offline: startup reads Feishu records. Patch only the
  # disposable copy so the real code under test is untouched.
  $fsPath = Join-Path $temp "lib\feishu.ps1"
  $fs = [System.IO.File]::ReadAllText($fsPath)
  $fs = [regex]::Replace($fs, 'function Get-FsRecords\s*\{', "function Get-FsRecords {`r`n  if (`$env:GOPS_TEST_NO_FEISHU -eq '1') { return @() }")
  [System.IO.File]::WriteAllText($fsPath, $fs, (New-Object System.Text.UTF8Encoding($true)))

  $stateRoot = Join-Path $temp "state"
  New-Item -ItemType Directory -Path (Join-Path $temp "logs"), (Join-Path $temp "data"), $stateRoot -Force | Out-Null
  $env:GOPS_STATE_ROOT = $stateRoot
  $env:GOPS_RUN_CONTROL_FILE = Join-Path $stateRoot "run_control.json"
  $env:GOPS_STOP_FILE = Join-Path $stateRoot "stop.flag"
  $env:GOPS_TEST_NO_FEISHU = "1"

  $outLog = Join-Path $temp "hub.out.log"
  $errLog = Join-Path $temp "hub.err.log"
  $hubProc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $temp "hub.ps1"), "-Port", [string]$Port) -WorkingDirectory $temp -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  $ready = $false
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    try {
      $probe = Http "GET" "/health"
      if ($probe.status -eq 200) { $ready = $true; break }
    } catch { }
    Start-Sleep -Milliseconds 400
  }
  A $ready ("hub did not listen; stderr=" + (Get-Content $errLog -Raw -ErrorAction SilentlyContinue))

  $identity = Http "GET" "/api/version"
  A ($identity.body.pid -eq $hubProc.Id) "isolated port belongs to a different Hub"
  T "version" {
    $r = Http "GET" "/api/version"
    A ($r.status -eq 200) ("status=" + $r.status)
    A ($r.body.hubSha16) "hubSha16 missing"
    A ($r.body.sidepanelSha16) "sidepanelSha16 missing"
  }

  T "stop-cleanup-requires-run-id" {
    $r = Http "POST" "/control" @{ action = "stop"; cleanup = $true }
    A ($r.status -eq 400) ("status=" + $r.status + " body=" + $r.text)
    A ($r.body -and $r.body.error -eq "run_id_required_for_cleanup") ("error=" + $r.body.error + " body=" + $r.text)
  }

  T "ghost-external-owner-dead-repaired-on-health" {
    # Use a PID we just observed exit: a fixed high PID can be reused by a
    # real process on a busy host, which would make the "dead owner" premise
    # flaky. The route under test is still the real /control and /health.
    $deadProc = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\cmd.exe") -ArgumentList @("/c", "exit", "0") -PassThru -WindowStyle Hidden
    $null = $deadProc.WaitForExit(5000)
    if (-not $deadProc.HasExited) { Stop-Process -Id $deadProc.Id -Force -ErrorAction SilentlyContinue }
    $deadPid = [int]$deadProc.Id
    $rid = "run_all-20260101-000000-" + $deadPid
    $rc = @{ run_id = $rid; state = "running"; started_at = (Get-Date).AddMinutes(-20).ToString("o"); updated_at = (Get-Date).AddMinutes(-20).ToString("o"); current_platform = "Telegram"; platforms = @("Telegram"); stop_requested = $false; owner_pid = $deadPid; owner_kind = "run_all" }
    [System.IO.File]::WriteAllText((Join-Path $stateRoot "run_control.json"), ($rc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $p = @{ run_id = $rid; state = "running"; started_at = (Get-Date).AddMinutes(-20).ToString("o"); updated_at = (Get-Date).AddMinutes(-20).ToString("o"); total = 1; completed = 0; current_platform = "Telegram"; next_platform = ""; platforms = @("Telegram"); last_error = "" }
    [System.IO.File]::WriteAllText((Join-Path $stateRoot "pipeline_status.json"), ($p | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $s = Http "POST" "/control" @{ action = "start"; platform = "Telegram"; run_id = $rid }
    A ($s.status -eq 200) ("start status=" + $s.status + " body=" + $s.text)
    $rcStarted = Get-Content (Join-Path $stateRoot "run_control.json") -Raw | ConvertFrom-Json
    A ([string]$rcStarted.run_id -eq $rid) ("started rc run_id=" + $rcStarted.run_id + " expected=" + $rid)
    $h = Http "GET" "/health"
    A ($h.status -eq 200) ("health status=" + $h.status + " body=" + $h.text)
    A (-not [bool]$h.body.running) ("health still running after dead owner; body=" + $h.text)
    $rcAfter = Get-Content (Join-Path $stateRoot "run_control.json") -Raw | ConvertFrom-Json
    A ([string]$rcAfter.state -ne "running") ("rc state=" + $rcAfter.state + " body=" + $h.text)
    $pAfter = Get-Content (Join-Path $stateRoot "pipeline_status.json") -Raw | ConvertFrom-Json
    A ($pAfter.state -eq "failed") ("pipeline state=" + $pAfter.state)
  }

  T "stop-cleanup-stale-run-id" {
    $rid = "hub-20260101-000000-deadbeef"
    $rc = @{ run_id = $rid; state = "running"; started_at = (Get-Date).ToString("o"); updated_at = (Get-Date).ToString("o"); current_platform = "Telegram"; platforms = @("Telegram"); stop_requested = $false; owner_pid = 0; owner_kind = "hub" }
    [System.IO.File]::WriteAllText((Join-Path $stateRoot "run_control.json"), ($rc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $r = Http "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = "hub-other" }
    A ($r.status -eq 409) ("status=" + $r.status + " body=" + $r.text)
    A ($r.body -and $r.body.error -eq "stale_run") ("error=" + $r.body.error + " body=" + $r.text)
    $ok = Http "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $rid }
    A ($ok.status -eq 200) ("cleanup status=" + $ok.status + " body=" + $ok.text)
    $rcAfter = Get-Content (Join-Path $stateRoot "run_control.json") -Raw | ConvertFrom-Json
    A ($rcAfter.state -eq "stopped") ("rc state=" + $rcAfter.state)
  }

  T "manual-start-round-stop-run-id" {
    $s = Http "POST" "/control" @{ action = "start"; platform = "Telegram" }
    A ($s.status -eq 200) ("start status=" + $s.status + " body=" + $s.text)
    $st = Http "GET" "/state"
    $rid = [string]$st.body.run_id
    A ($rid -like "hub-*") ("run_id=" + $rid + " body=" + $st.text)
    $bad = Http "POST" "/control" @{ action = "round_stop"; run_id = "hub-other" }
    A ($bad.status -eq 409) ("wrong stop status=" + $bad.status + " body=" + $bad.text)
    $good = Http "POST" "/control" @{ action = "round_stop"; run_id = $rid }
    A ($good.status -eq 200) ("round_stop status=" + $good.status + " body=" + $good.text)
    $clean = Http "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $rid }
    A ($clean.status -eq 200) ("cleanup status=" + $clean.status + " body=" + $clean.text)
  }

  T "round-stop-finalizes-and-restarts-immediately" {
    $s = Http "POST" "/control" @{ action = "start"; platform = "Telegram" }
    A ($s.status -eq 200) ("start status=" + $s.status + " body=" + $s.text)
    $st = Http "GET" "/state"
    $rid = [string]$st.body.run_id
    A ($rid -like "hub-*") ("run_id=" + $rid + " body=" + $st.text)
    $rs = Http "POST" "/control" @{ action = "round_stop"; run_id = $rid }
    A ($rs.status -eq 200) ("round_stop status=" + $rs.status + " body=" + $rs.text)
    A ([bool]$rs.body.finalized) ("not finalized; body=" + $rs.text)
    A ([string]$rs.body.phase -eq "idle") ("phase=" + $rs.body.phase)
    $after = Http "GET" "/state"
    A (-not [bool]$after.body.running) ("still running; body=" + $after.text)
    A ([string]$after.body.phase -eq "idle") ("phase=" + $after.body.phase)
    $rc = Get-Content (Join-Path $stateRoot "run_control.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    A ([string]$rc.state -eq "stopped") ("rc state=" + $rc.state)
    $sum = Get-Content (Join-Path $stateRoot "run_summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    A ([string]$sum.run_id -eq $rid) ("summary run_id=" + $sum.run_id + " expected=" + $rid)
    A ([string]$sum.code -eq "stopped") ("summary code=" + $sum.code)
    $task = Http "GET" "/task"
    A ($task.status -eq 204) ("task after stop status=" + $task.status)
    $s2 = Http "POST" "/control" @{ action = "start"; platform = "Telegram" }
    A ($s2.status -eq 200) ("restart status=" + $s2.status + " body=" + $s2.text)
    $st2 = Http "GET" "/state"
    $rid2 = [string]$st2.body.run_id
    A ($rid2 -like "hub-*") ("restart run_id=" + $rid2)
    $rs2 = Http "POST" "/control" @{ action = "round_stop"; run_id = $rid2 }
    A ($rs2.status -eq 200) ("cleanup round_stop status=" + $rs2.status + " body=" + $rs2.text)
  }

  T "emergency-stop-rejects-start-until-clear" {
    $s = Http "POST" "/control" @{ action = "start"; platform = "Telegram" }
    A ($s.status -eq 200) ("start status=" + $s.status + " body=" + $s.text)
    $st = Http "GET" "/state"
    $rid = [string]$st.body.run_id
    A ($rid -like "hub-*") ("run_id=" + $rid)
    $e = Http "POST" "/control" @{ action = "stop"; run_id = $rid }
    A ($e.status -eq 200) ("emergency status=" + $e.status + " body=" + $e.text)
    A ([bool]$e.body.finalized) ("not finalized; body=" + $e.text)
    A ([string]$e.body.phase -eq "idle") ("phase=" + $e.body.phase)
    A (Test-Path (Join-Path $stateRoot "stop.flag")) "stop.flag missing"
    $rej = Http "POST" "/control" @{ action = "start"; platform = "Telegram" }
    A ($rej.status -eq 409) ("start after emergency status=" + $rej.status + " body=" + $rej.text)
    A ($rej.body -and $rej.body.error -eq "stopped") ("error=" + $rej.body.error + " body=" + $rej.text)
    $c = Http "POST" "/control" @{ action = "clear_stop" }
    A ($c.status -eq 200) ("clear_stop status=" + $c.status + " body=" + $c.text)
    A (-not (Test-Path (Join-Path $stateRoot "stop.flag"))) "stop.flag still present"
    $s2 = Http "POST" "/control" @{ action = "start"; platform = "Telegram" }
    A ($s2.status -eq 200) ("restart after clear status=" + $s2.status + " body=" + $s2.text)
    $st2 = Http "GET" "/state"
    $rid2 = [string]$st2.body.run_id
    $rs2 = Http "POST" "/control" @{ action = "round_stop"; run_id = $rid2 }
    A ($rs2.status -eq 200) ("cleanup round_stop status=" + $rs2.status + " body=" + $rs2.text)
  }

  T "skip-first-platform-resets-query-cursor" {
    $s = Http "POST" "/control" @{ action = "start"; platforms = @("Facebook", "Telegram") }
    A ($s.status -eq 200) ("start status=" + $s.status + " body=" + $s.text)
    $st = Http "GET" "/state"
    $rid = [string]$st.body.run_id
    A ($rid -like "hub-*") ("run_id=" + $rid)
    $sk = Http "POST" "/control" @{ action = "skip_platform"; run_id = $rid; platform = "Facebook" }
    A ($sk.status -eq 200) ("skip status=" + $sk.status + " body=" + $sk.text)
    $t1 = Http "GET" "/task"
    A ($t1.status -eq 204) ("advance task status=" + $t1.status + " body=" + $t1.text)
    $t2 = Http "GET" "/task"
    A ($t2.status -eq 200) ("next platform task status=" + $t2.status + " body=" + $t2.text)
    A ($t2.body.action -eq "search") ("action=" + $t2.body.action + " body=" + $t2.text)
    A ([string]$t2.body.query -eq "tg-only") ("query=" + $t2.body.query + " body=" + $t2.text)
    $rs = Http "POST" "/control" @{ action = "round_stop"; run_id = $rid }
    A ($rs.status -eq 200) ("round_stop status=" + $rs.status + " body=" + $rs.text)
  }

  T "steam-plus-telegram-is-rejected-as-a-whole" {
    $r = Http "POST" "/control" @{ action = "start"; platforms = @("Steam", "Telegram") }
    A ($r.status -eq 400) ("status=" + $r.status + " body=" + $r.text)
    A ($r.body -and (@("unknown_platform", "platform_no_manual_executor") -contains [string]$r.body.error)) ("error=" + $r.body.error + " body=" + $r.text)
    $st = Http "GET" "/state"
    A (-not [bool]$st.body.running) ("unexpected running; body=" + $st.text)
  }

  T "kw-status-route" {
    $r = Http "GET" "/api/kw/status?platform=Telegram"
    A ($r.status -eq 200) ("status=" + $r.status + " body=" + $r.text)
    A ($r.body -and $r.body.ok) ("body=" + $r.text)
    A ($null -ne $r.body.status) ("status field missing; body=" + $r.text)
  }

  T "start-rejects-any-disabled-platform-in-order" {
    if ($script:hubProc -and -not $script:hubProc.HasExited) {
      Stop-Process -Id $script:hubProc.Id -Force -ErrorAction SilentlyContinue
      $null = $script:hubProc.WaitForExit(5000)
    }
    $cfgText = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
    $cfgNow = $cfgText | ConvertFrom-Json
    $cfgNow | Add-Member -NotePropertyName platformsEnabled -NotePropertyValue ([pscustomobject]@{ Facebook = $true; Telegram = $false; Discord = $true; Reddit = $true }) -Force
    [System.IO.File]::WriteAllText($cfgPath, ($cfgNow | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $script:Port = [int]$script:Port + 1
    $script:hubProc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $temp "hub.ps1"), "-Port", [string]$script:Port) -WorkingDirectory $temp -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $ready2 = $false
    $deadline2 = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline2) {
      try {
        $probe2 = Http "GET" "/health"
        if ($probe2.status -eq 200) { $ready2 = $true; break }
      } catch { }
      Start-Sleep -Milliseconds 400
    }
    A $ready2 ("hub did not restart; stderr=" + (Get-Content $errLog -Raw -ErrorAction SilentlyContinue))
    $r = Http "POST" "/control" @{ action = "start"; platforms = @("Facebook", "Telegram") }
    A ($r.status -eq 409) ("status=" + $r.status + " body=" + $r.text)
    A ($r.body -and $r.body.error -eq "platform_disabled") ("error=" + $r.body.error + " body=" + $r.text)
    A ([string]$r.body.platform -eq "Telegram") ("platform=" + $r.body.platform + " body=" + $r.text)
  }

  Write-Host ("RESULT pass=" + $pass + " fail=" + $fail)
} finally {
  if ($hubProc -and -not $hubProc.HasExited) { Stop-Process -Id $hubProc.Id -Force -ErrorAction SilentlyContinue }
  foreach ($k in @("GOPS_STATE_ROOT", "GOPS_RUN_CONTROL_FILE", "GOPS_STOP_FILE", "GOPS_TEST_NO_FEISHU")) {
    if ($null -eq $old[$k]) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    else { Set-Item ("env:" + $k) $old[$k] }
  }
  if ((Test-Path -LiteralPath $temp) -and [IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $temp).Path) -eq (Resolve-Path -LiteralPath $env:TEMP).Path -and [IO.Path]::GetFileName($temp) -match "^gops-hub-it-[0-9a-f]{32}$") { Remove-Item -LiteralPath $temp -Recurse -Force }
}
if ($fail -gt 0) { exit 1 }
