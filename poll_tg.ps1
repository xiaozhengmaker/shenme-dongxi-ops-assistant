param([int]$Minutes = 8, [int]$EverySec = 8)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cdp = Join-Path $here "cdp_call.ps1"
if (-not (Test-Path $cdp)) { "missing cdp script: $cdp"; exit 2 }
$js = @"
(async()=>{try{
 const am = window.rootScope && window.rootScope.managers && window.rootScope.managers.apiManager;
 if(!am) return 'no-am';
 await Promise.race([
   am.invokeApi("help.getConfig", {}),
   new Promise((_,rej)=>setTimeout(()=>rej(new Error('timeout')),8000))
 ]);
 return 'OK';
}catch(e){ return 'ERR:' + String(e && e.message || e); }})()
"@
$deadline = (Get-Date).AddMinutes($Minutes)
$i = 0
while ((Get-Date) -lt $deadline) {
  $i++
  $p = @{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress
  $out = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram.org" 2>$null
  $s = [string]($out -join " ")
  if ($s -match "OK") { "[$i] RECOVERED " + (Get-Date).ToString("HH:mm:ss"); exit 0 }
  "[$i] " + (Get-Date).ToString("HH:mm:ss") + " " + ($s -replace "\s+"," ").Trim()
  Start-Sleep -Seconds $EverySec
}
"GAVE-UP $i"
exit 1