$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "asserts.ps1")

$lib = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\pipeline_status.ps1"
if (Test-Path $lib) { . $lib }

$hasPath = [bool](Get-Command Get-PipelineStatusPath -ErrorAction SilentlyContinue)
$hasRead = [bool](Get-Command Read-PipelineStatus -ErrorAction SilentlyContinue)
$hasSave = [bool](Get-Command Save-PipelineStatus -ErrorAction SilentlyContinue)
$hasNew = [bool](Get-Command New-PipelineStatus -ErrorAction SilentlyContinue)
$hasView = [bool](Get-Command Get-PipelineStatusView -ErrorAction SilentlyContinue)

Check $hasPath "pipeline: Get-PipelineStatusPath exists"
Check $hasRead "pipeline: Read-PipelineStatus exists"
Check $hasSave "pipeline: Save-PipelineStatus exists"
Check $hasNew "pipeline: New-PipelineStatus exists"
Check $hasView "pipeline: Get-PipelineStatusView exists"

$tmpDir = Join-Path $env:TEMP ("gops-pipe-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$tmp = Join-Path $tmpDir "pipeline_status.json"
$env:GOPS_PIPELINE_STATUS_FILE = $tmp
try {
  if ($hasView) {
    $missing = Get-PipelineStatusView -BaseDir $tmpDir
    CheckEqual "unknown" $missing.state "pipeline: missing => unknown"
    CheckEqual "no_pipeline_evidence" $missing.reason "pipeline: missing reason"
  }

  if ($hasNew -and $hasSave -and $hasRead -and $hasView) {
    $t0 = [datetime]::Parse("2026-11-19T10:00:00+08:00", [System.Globalization.CultureInfo]::InvariantCulture)
    $p = New-PipelineStatus -RunId "run-test" -Platforms @("Reddit", "Steam") -Now $t0
    CheckEqual "running" $p.state "pipeline: new state"
    CheckEqual 2 $p.total "pipeline: total platforms"
    CheckEqual 0 $p.completed "pipeline: completed starts at 0"
    CheckEqual "Reddit" $p.current_platform "pipeline: first platform"
    CheckEqual "Steam" $p.next_platform "pipeline: next platform"

    $p.current_platform = "members"
    $p.next_platform = "steam"
    $p.completed = 1
    Save-PipelineStatus -Path $tmp -Status $p
    Check (Test-Path $tmp) "pipeline: saved file exists"
    Check (-not (Test-Path ($tmp + ".tmp"))) "pipeline: temp file removed"

    $r = Read-PipelineStatus -Path $tmp
    Check ($null -ne $r) "pipeline: read returns object"
    CheckEqual "members" $r.current_platform "pipeline: current persisted"
    CheckEqual 1 $r.completed "pipeline: completed persisted"

    $view = Get-PipelineStatusView -BaseDir $tmpDir
    CheckEqual "running" $view.state "pipeline: view returns saved state"
  }

  if ($hasView) {
    [System.IO.File]::WriteAllText($tmp, "{bad json", (New-Object System.Text.UTF8Encoding($false)))
    $bad = Get-PipelineStatusView -BaseDir $tmpDir
    CheckEqual "unknown" $bad.state "pipeline: invalid => unknown"
    CheckEqual "pipeline_status_invalid" $bad.reason "pipeline: invalid reason"
  }
} finally {
  Remove-Item Env:GOPS_PIPELINE_STATUS_FILE -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Finish-Tests
