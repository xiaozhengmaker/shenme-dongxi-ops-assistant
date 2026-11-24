param([Parameter(Mandatory=$true)][string]$WorkDir,[Parameter(Mandatory=$true)][string[]]$Plan,[string]$RunId="",[ValidateSet("manual","daily")][string]$Entry="manual")
. (Join-Path $PSScriptRoot "..\lib\round_engine.ps1")
(Invoke-RoundRun -WorkDir $WorkDir -Plan $Plan -RunId $RunId -Entry $Entry) | ConvertTo-Json -Depth 8
