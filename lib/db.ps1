# 本地数据库（SQLite）通用封装
# 约定：所有 DB 操作走 db_tool.py，PowerShell 只负责调用与返回 JSON

$script:DbRoot = Split-Path $PSScriptRoot -Parent
$script:DbTool = Join-Path $script:DbRoot "db_tool.py"

function Get-DbPython {
  # 1) config.json 里的 db.python
  try {
    $cfgPath = Join-Path $script:DbRoot "config.json"
    if (Test-Path $cfgPath) {
      $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($cfg.db -and $cfg.db.python -and (Test-Path $cfg.db.python)) { return [string]$cfg.db.python }
    }
  } catch { }
  # 2) DSH 自带 python
  $bundled = "C:\Users\11857\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
  if (Test-Path $bundled) { return $bundled }
  # 3) PATH 上的 python
  return "python"
}

function Invoke-DbTool {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  $py = Get-DbPython
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    $out = & $py $script:DbTool @Args 2>&1 | Out-String
    [System.IO.File]::WriteAllText($tmp, $out, (New-Object System.Text.UTF8Encoding($false)))
    $txt = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8).Trim()
    return $txt
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Get-DbStats {
  $raw = Invoke-DbTool -Args @("stats")
  try { return ($raw | ConvertFrom-Json) } catch { return @{ ok = $false; error = "bad_output"; raw = $raw } }
}

function Initialize-LocalDb {
  $raw = Invoke-DbTool -Args @("init")
  try { return ($raw | ConvertFrom-Json) } catch { return @{ ok = $false; error = "bad_output"; raw = $raw } }
}

function Import-LocalDb {
  param([string[]]$CsvPaths)
  if (-not $CsvPaths -or $CsvPaths.Count -eq 0) {
    $CsvPaths = @((Join-Path $script:DbRoot "data\users.csv"))
  }
  $args2 = @("import") + $CsvPaths
  $raw = Invoke-DbTool -Args $args2
  try { return ($raw | ConvertFrom-Json) } catch { return @{ ok = $false; error = "bad_output"; raw = $raw } }
}
