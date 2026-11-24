# ensure_task_settings.ps1 — 幂等：保证计划任务不会因「电池/错过补跑」被拒绝启动
param([string[]]$Tasks = @("DSH_SocialOps_Daily","DSH_SocialOps_Steam","DSH_SocialOps_HubWatch","DSH_SocialOps_Report","DSH_SocialOps_Hub"))
foreach ($n in $Tasks) {
  $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
  if (-not $t) { Write-Host "[skip] $n 不存在"; continue }
  $s = $t.Settings
  $changed = $false
  if ($s.DisallowStartIfOnBatteries) { $s.DisallowStartIfOnBatteries = $false; $changed = $true }
  if ($s.StopIfGoingOnBatteries) { $s.StopIfGoingOnBatteries = $false; $changed = $true }
  if (-not $s.StartWhenAvailable) { $s.StartWhenAvailable = $true; $changed = $true }
  if ($changed) { Set-ScheduledTask -TaskName $n -Settings $s | Out-Null }
  $v = Get-ScheduledTask -TaskName $n
  Write-Host ("[ok] {0} batt={1} stopBatt={2} swa={3} changed={4}" -f $n, $v.Settings.DisallowStartIfOnBatteries, $v.Settings.StopIfGoingOnBatteries, $v.Settings.StartWhenAvailable, $changed)
}