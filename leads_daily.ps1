# leads_daily.ps1 -- 每日线索流水线：扫描 -> AI 打分 -> 入库
param(
  [switch]$SkipScan,
  [switch]$SkipScore,
  [int]$Top = 40,
  [int]$MinNew = 0
)
$ErrorActionPreference = "Stop"
$baseDir = "D:\DeepSeek\运营"
. (Join-Path $baseDir "lib\log.ps1")
. (Join-Path $baseDir "lib\stop.ps1")
. (Join-Path $baseDir "lib\ai.ps1")
Set-LogFile (Join-Path $baseDir "logs\leads_daily.log")
function Say([string]$m) { Write-Log ("[leads_daily] " + $m) }

function Ev([string]$m) {
  try {
    $b = @{ msg = $m } | ConvertTo-Json -Compress
    Invoke-RestMethod "http://127.0.0.1:8787/api/event" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($b)) -ContentType "application/json; charset=utf-8" -TimeoutSec 5 | Out-Null
  } catch { }
}

if (Test-GOpsStop $baseDir) { Say "STOP flag present, exit"; exit 0 }

$py = "C:\Users\11857\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$sigFile = Join-Path $baseDir "data\leads_signals.json"
$scoFile = Join-Path $baseDir "data\leads_scored.json"
$dbPath  = Join-Path $baseDir "data\groupops.db"

$before = 0
if (Test-Path $sigFile) {
  try { $before = [int]((Get-Content $sigFile -Raw -Encoding UTF8 | ConvertFrom-Json).unique) } catch { }
}

if (-not $SkipScan) {
  Say "--- 扫描"
  Ev "leads scan start"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "leads_scan.ps1") | Out-Null
  Ev "leads scan done"
}

$after = 0
if (Test-Path $sigFile) {
  try { $after = [int]((Get-Content $sigFile -Raw -Encoding UTF8 | ConvertFrom-Json).unique) } catch { }
}
Say ("signals: " + $before + " -> " + $after)

if (Test-GOpsStop $baseDir) { Say "STOP flag present, exit"; exit 0 }

$cfg = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$aiReady = Test-AiReady $cfg
Say ("ai_ready=" + $aiReady)

if (-not $SkipScore -and $aiReady -and $after -gt 0) {
  Say ("--- AI 打分 top " + $Top)
  Ev ("leads score start top=" + $Top)
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "leads_score.ps1") -Top $Top | Out-Null
  Ev "leads score done"
} elseif (-not $aiReady) {
  Say "跳过打分（未配置 AI）"
}

if (Test-GOpsStop $baseDir) { Say "STOP flag present, exit"; exit 0 }

Say "--- 入库"
$argsList = @($py, (Join-Path $baseDir "db_tool.py"), "leads", $sigFile)
if (Test-Path $scoFile) { $argsList += $scoFile }
$out = & $argsList[0] $argsList[1..($argsList.Count - 1)] 2>&1
Say ("db: " + ($out -join " "))

$leads = 0
try {
  $s = Get-Content $scoFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $leads = @($s.items | Where-Object { $_.ai_is_lead }).Count
} catch { }
Say ("DONE signals=" + $after + " ai_leads=" + $leads)
Ev ("leads daily done signals=" + $after + " leads=" + $leads)
