# asserts.ps1 -- tiny assertion helpers for offline tests (PS 5.1 compatible)
$script:PassCount = 0
$script:FailCount = 0
$script:FailedNames = New-Object System.Collections.ArrayList

function Check([bool]$Condition, [string]$Name) {
  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS " + $Name)
  } else {
    $script:FailCount++
    [void]$script:FailedNames.Add($Name)
    Write-Host ("FAIL " + $Name)
  }
}

function CheckEqual($Expected, $Actual, [string]$Name) {
  $ok = ([string]$Expected -eq [string]$Actual)
  if (-not $ok) { Write-Host ("     expected=[" + $Expected + "] actual=[" + $Actual + "]") }
  Check $ok $Name
}

function Finish-Tests {
  Write-Host ("RESULT pass=" + $script:PassCount + " fail=" + $script:FailCount)
  if ($script:FailCount -gt 0) {
    Write-Host ("FAILED: " + ($script:FailedNames -join "; "))
    exit 1
  }
  exit 0
}
