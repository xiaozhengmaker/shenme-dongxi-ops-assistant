# run_hub.ps1 —— 计划任务入口：带重定向地拉起 hub，并把自身当作“监护进程”
param([string]$Platform = "Telegram")
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "hub.log"
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] run_hub start platform=$Platform pid=$PID" | Out-File -FilePath $log -Encoding utf8 -Append
$hubOut = Join-Path $logDir "hub.out.log"
$hubErr = Join-Path $logDir "hub.err.log"
$child = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $root "hub.ps1"),"-Platform",$Platform) -WindowStyle Hidden -RedirectStandardOutput $hubOut -RedirectStandardError $hubErr -PassThru
$child.WaitForExit()
$code = $child.ExitCode
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] hub exited code=$code" | Out-File -FilePath $log -Encoding utf8 -Append
exit $code