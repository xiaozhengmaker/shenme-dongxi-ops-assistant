# lib\member_run.ps1 -- 成员样本读取的统一入口（与拓群解耦，按平台各自开关/上限/预算）
# config.json:
#   memberSample.telegram = { enabled, maxGroupsPerRound (0=不限), budgetMin, pageDelayMs, maxRuntimeMin }
#   memberSample.steam    = { enabled, maxGroupsPerRound (0=不限), budgetMin, pageDelayMs, maxRuntimeMin }

function Get-MemberSampleCfg {
  param($Cfg, [string]$Platform)
  $d = @{ enabled = $true; maxGroupsPerRound = 0; budgetMin = 60; pageDelayMs = 1200; maxRuntimeMin = 3 }
  if (-not $Cfg -or -not $Cfg.memberSample) { return $d }
  $props = $Cfg.memberSample.PSObject.Properties.Name
  $key = $null
  foreach ($p in $props) { if ($p -ieq $Platform) { $key = $p; break } }
  if (-not $key) { return $d }
  $o = $Cfg.memberSample.$key
  if ($null -eq $o) { return $d }
  if ($o -is [bool]) { $d.enabled = [bool]$o; return $d }
  foreach ($f in @("enabled", "maxGroupsPerRound", "budgetMin", "pageDelayMs", "maxRuntimeMin")) {
    if ($o.PSObject.Properties.Name -contains $f -and $null -ne $o.$f) { $d[$f] = $o.$f }
  }
  $d.enabled = [bool]$d.enabled
  $d.maxGroupsPerRound = [int]$d.maxGroupsPerRound
  $d.budgetMin = [int]$d.budgetMin
  $d.pageDelayMs = [int]$d.pageDelayMs
  $d.maxRuntimeMin = [int]$d.maxRuntimeMin
  return $d
}

function Invoke-MemberSampling {
  param(
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [Parameter(Mandatory = $true)][string]$Platform,
    $Cfg,
    [scriptblock]$Say = { param($m) Write-Host $m },
    [scriptblock]$Stopped = { $false }
  )
  $name = ($Platform.Substring(0, 1).ToUpper() + $Platform.Substring(1).ToLower())
  $c = Get-MemberSampleCfg -Cfg $Cfg -Platform $name
  if (-not $c.enabled) { & $Say ("  " + $name + " 采样：已关闭（config.memberSample." + $name + ".enabled=false）"); return @{ platform = $name; enabled = $false; handled = 0; ok = 0; bad = 0 } }

  . (Join-Path $BaseDir "lib\member_sample.ps1")
  $stateKey = $name.ToLower()
  $catalog = @(Get-MemberCatalog $BaseDir $name)
  $state = Read-MemberState $BaseDir $stateKey
  $pending = New-Object System.Collections.Generic.List[string]
  foreach ($g in $catalog) {
    $k = [string]$g.key
    if (-not $k) { continue }
    $e = Get-MemberStateEntry $state $k
    if ($e -and ($e.status -eq "done" -or $e.status -eq "permission_denied")) { continue }
    $pending.Add($k)
  }
  $capText = $(if ($c.maxGroupsPerRound -le 0) { "不限" } else { [string]$c.maxGroupsPerRound })
  & $Say ("  " + $name + " 采样：待采 " + $pending.Count + " / 目录 " + $catalog.Count + "，本轮上限 " + $capText + "，预算 " + $c.budgetMin + " 分钟")
  if ($pending.Count -eq 0) { return @{ platform = $name; enabled = $true; handled = 0; ok = 0; bad = 0 } }

  $script = Join-Path $BaseDir ("sample_" + $stateKey + ".ps1")
  if (-not (Test-Path $script)) { & $Say ("  " + $name + " 采样：缺少 " + $script); return @{ platform = $name; enabled = $true; handled = 0; ok = 0; bad = 0 } }
  $deadline = (Get-Date).AddMinutes($c.budgetMin)
  $handled = 0; $ok = 0; $bad = 0
  foreach ($k in $pending) {
    if (& $Stopped) { & $Say ("  " + $name + " 采样：收到停止信号"); break }
    if ((Get-Date) -gt $deadline) { & $Say ("  " + $name + " 采样：预算用尽（" + $c.budgetMin + " 分钟）"); break }
    if ($c.maxGroupsPerRound -gt 0 -and $handled -ge $c.maxGroupsPerRound) { & $Say ("  " + $name + " 采样：达到本轮上限 " + $c.maxGroupsPerRound); break }
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Target $k -MaxRuntimeMin $c.maxRuntimeMin -PageDelayMs $c.pageDelayMs 2>&1
    $last = ($o | Where-Object { $_ -match "RESULT:" } | Select-Object -Last 1)
    if (-not $last) { $last = "RESULT: unknown target=$k" }
    if ($last -match "RESULT: done") { $ok++ } else { $bad++ }
    & $Say ("    " + $last)
    $handled++
    Start-Sleep -Milliseconds 700
  }
  & $Say ("  " + $name + " 采样结束：处理 " + $handled + " 群（ok=" + $ok + " bad=" + $bad + "）")
  return @{ platform = $name; enabled = $true; handled = $handled; ok = $ok; bad = $bad }
}