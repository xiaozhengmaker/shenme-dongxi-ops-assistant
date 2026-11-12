$script:LogFile = $null
function Set-LogFile([string]$path) {
  # GROUPOPS_ROTATE: 超过 8MB 自动切到 .1，只保留一份历史
  if ($path -and (Test-Path $path)) {
    try {
      if ((Get-Item $path).Length -gt 8MB) {
        $bak = $path + ".1"
        if (Test-Path $bak) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
        Move-Item $path $bak -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }
  $script:LogFile = $path
  $d = Split-Path -Parent $path
  if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
function Write-Log {
  param([string]$msg, [string]$level = "INFO", [string]$tag = "")
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[$ts] [$level]"
  if ($tag) { $line += " [$tag]" }
  $line += " $msg"
  Write-Host $line
  if ($script:LogFile) {
    try { $line | Out-File -FilePath $script:LogFile -Encoding utf8 -Append } catch {}
  }
}