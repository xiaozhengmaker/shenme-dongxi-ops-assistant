# 关键词淘汰 + AI 热点建议：离线测试总入口
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\offline\run_kw_tests.ps1
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tests = @(
  "kw_stats.Tests.ps1",
  "kw_trend.Tests.ps1",
  "kw_hot.Tests.ps1",
  "kw_api.Tests.ps1",
  "kw_cli.Tests.ps1"
)
$failed = @()
foreach ($name in $tests) {
  $path = Join-Path $here $name
  Write-Host ""
  Write-Host ("===== " + $name + " =====")
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Host ("MISSING " + $path)
    $failed += $name
    continue
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
  if ($LASTEXITCODE -ne 0) { $failed += $name }
}
Write-Host ""
if ($failed.Count -gt 0) {
  Write-Host ("FAILED: " + ($failed -join ", "))
  exit 1
}
Write-Host "ALL KW TESTS PASS"
exit 0
