param(
  [int]$MaxPages = 40,
  [int]$DelayMs = 6000,
  [string[]]$JoinGroups = @(),
  [int]$DiscoverPages = 2,
  [int]$JoinLimit = 5,
  [switch]$SkipDiscover,
  [switch]$SkipJoin
)
$ErrorActionPreference = "Continue"
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $baseDir "lib\log.ps1")
. (Join-Path $baseDir "lib\db.ps1")

function Ev([string]$m) {
  try {
    $body = @{ msg = ($m -replace '[^\x20-\x7E]', '?') } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/event' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 5 | Out-Null
  } catch { }
}

Ev "steam daily start"

if (-not $SkipDiscover) {
  Ev "step0 discover groups"
  try { & (Join-Path $baseDir "steam_discover.ps1") -MaxPages $DiscoverPages -MinMembers 1000 | Out-Null }
  catch { Ev ("step0 error: " + $_.Exception.Message) }
}
if ($JoinGroups.Count -eq 0) {
  $cf = Join-Path $baseDir "data\steam_candidates.json"
  if (Test-Path $cf) {
    try {
      $c = @(Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { -not $_.joined } | Sort-Object members -Descending | Select-Object -First $JoinLimit)
      $JoinGroups = @($c | ForEach-Object { $_.slug })
    } catch { }
  }
}
if (-not $SkipJoin -and $JoinGroups.Count -gt 0) {
  Ev ("step1 join " + $JoinGroups.Count + " groups")
  foreach ($g in $JoinGroups) {
    if (-not $g) { continue }
    try {
      Ev ("join " + $g)
      & (Join-Path $baseDir "steam_join.ps1") -Group $g | Out-Null
    } catch {
      Ev ("join " + $g + " error")
    }
  }
} else {
  Ev "step1 skipped (no JoinGroups)"
}

Ev "step2 fetch members (xml)"
try {
  & (Join-Path $baseDir "steam_full.ps1") -MaxPages $MaxPages -DelayMs $DelayMs
} catch {
  Ev ("step2 error: " + $_.Exception.Message)
}

Ev "step3 import users csv"
try {
  & (Join-Path $baseDir "steam_to_users.ps1") | Out-Null
  Initialize-LocalDb | Out-Null
  Import-LocalDb | Out-Null
} catch {
  Ev ("step3 error: " + $_.Exception.Message)
}

$st = $null
try { $st = Get-DbStats } catch { }
if ($st) { Ev ("steam daily done rows=" + $st.rows + " groups=" + $st.groups) } else { Ev "steam daily done" }
