# 统一读取本机相关配置（Chrome 路径 / 调试 profile / CDP 端口）。
# 设计目标：换电脑时只改 config.json 或什么都不用改（自动探测 + 安全默认值）。
function Get-GOpsConfig {
  param([string]$Root)
  if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
  foreach ($n in @("config.json", "config.example.json")) {
    $p = Join-Path $Root $n
    if (Test-Path $p) {
      try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
  }
  return $null
}

function Get-GOpsChrome {
  param($Cfg)
  if ($Cfg -and $Cfg.paths -and $Cfg.paths.chrome -and (Test-Path $Cfg.paths.chrome)) { return $Cfg.paths.chrome }
  $c = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
  )
  foreach ($x in $c) { if ($x -and (Test-Path $x)) { return $x } }
  return $c[0]
}

function Get-GOpsProfile {
  param($Cfg, [switch]$Create)
  $p = $null
  if ($Cfg -and $Cfg.paths -and $Cfg.paths.chrome_debug_profile) { $p = $Cfg.paths.chrome_debug_profile }
  if (-not $p) { $p = Join-Path $env:LOCALAPPDATA "GroupOps\chrome-profile" }
  if ($Create -and -not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  return $p
}

function Get-GOpsPort {
  param($Cfg)
  if ($Cfg -and $Cfg.paths -and $Cfg.paths.cdp_port) { return [int]$Cfg.paths.cdp_port }
  return 9222
}
