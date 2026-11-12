<#
  lint.ps1 — 仓库静态检查（CI 与本地共用）
  1) 所有 .ps1 语法可解析（Parser::ParseFile）
  2) 所有 .json 合法
  3) 所有 .py 可编译（找不到 python 则跳过）
  4) Markdown 里的本地图片/链接确实存在

  范围：有 .git 时只查 git 跟踪的文件（与 CI 一致），否则递归扫描并跳过 data/logs/dist/.git。
  退出码：0 全通过；1 有失败项
#>
param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Continue"
$fail = 0
$warn = 0

function Say([string]$text) { Write-Host $text }

function Get-Files([string]$pattern) {
  if (Test-Path (Join-Path $Root ".git")) {
    $tracked = & git -C $Root ls-files -- $pattern 2>$null
    foreach ($rel in $tracked) {
      if (-not $rel) { continue }
      $full = Join-Path $Root ($rel -replace "/", "\")
      if (Test-Path -LiteralPath $full) { Get-Item -LiteralPath $full }
    }
  } else {
    Get-ChildItem -Path $Root -Recurse -Filter (Split-Path $pattern -Leaf) -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch "\\\.git\\" -and $_.FullName -notmatch "\\data\\" -and $_.FullName -notmatch "\\logs\\" -and $_.FullName -notmatch "\\dist\\" }
  }
}

Say "== 1/4 PowerShell 语法 =="
$ps1 = @(Get-Files "*.ps1")
$bad = 0
foreach ($f in $ps1) {
  $errs = $null
  $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) | Out-Null
  if ($errs -and $errs.Count -gt 0) {
    $bad++
    Say ("  FAIL " + $f.Name + " : " + $errs[0].Message)
  }
}
Say ("  " + $ps1.Count + " files, " + $bad + " failed")
if ($bad -gt 0) { $fail++ }

Say "== 2/4 JSON =="
$jsons = @(Get-Files "*.json")
$badJson = 0
foreach ($f in $jsons) {
  try {
    [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json | Out-Null
  } catch {
    $badJson++
    Say ("  FAIL " + $f.Name + " : " + $_.Exception.Message)
  }
}
Say ("  " + $jsons.Count + " files, " + $badJson + " failed")
if ($badJson -gt 0) { $fail++ }

Say "== 3/4 Python =="
$pyCmd = $null
foreach ($cand in @(@("python"), @("py", "-3"))) {
  $exe = Get-Command $cand[0] -ErrorAction SilentlyContinue
  if (-not $exe) { continue }
  $verArgs = @($cand | Select-Object -Skip 1) + @("--version")
  & $exe.Source @verArgs *> $null
  if ($LASTEXITCODE -eq 0) { $pyCmd = @{ exe = $exe.Source; args = @($cand | Select-Object -Skip 1) }; break }
}
$pys = @(Get-Files "*.py")
if (-not $pyCmd) {
  $warn++
  Say ("  SKIP (找不到可用的 python) — " + $pys.Count + " files")
} else {
  $badPy = 0
  foreach ($f in $pys) {
    $args = @($pyCmd.args) + @("-c", "import ast,io,sys;ast.parse(io.open(sys.argv[1],encoding='utf-8').read())", $f.FullName)
    & $pyCmd.exe @args *> $null
    if ($LASTEXITCODE -ne 0) { $badPy++; Say ("  FAIL " + $f.Name) }
  }
  Say ("  " + $pys.Count + " files, " + $badPy + " failed")
  if ($badPy -gt 0) { $fail++ }
}

Say "== 4/4 Markdown 本地链接 =="
$mds = @(Get-Files "*.md")
$missing = 0
foreach ($f in $mds) {
  $text = [System.IO.File]::ReadAllText($f.FullName)
  $found = [regex]::Matches($text, '!?\[[^\]]*\]\(([^)\s]+)\)')
  foreach ($m in $found) {
    $target = $m.Groups[1].Value
    if ($target -match "^(https?:|mailto:|#)") { continue }
    $target = ($target -split "#")[0]
    if (-not $target) { continue }
    $full = Join-Path $f.DirectoryName $target
    if (-not (Test-Path -LiteralPath $full)) {
      $missing++
      Say ("  MISSING " + $f.Name + " -> " + $target)
    }
  }
}
Say ("  " + $mds.Count + " files, " + $missing + " missing links")
if ($missing -gt 0) { $fail++ }

Say ""
if ($fail -gt 0) {
  Say ("RESULT: FAIL (" + $fail + " 项)")
  exit 1
}
Say "RESULT: OK"
exit 0
