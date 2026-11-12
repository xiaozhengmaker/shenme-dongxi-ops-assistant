param([string[]]$Codes)
$ErrorActionPreference = "Stop"
$cdp = "D:\DeepSeek\运营\cdp_call.ps1"
$root = "D:\DeepSeek\运营"
function Eval([string]$js) {
  $p = @{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress
  $r = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "web.whatsapp"
  if (-not $r) { return "" }
  return ($r | ConvertFrom-Json).result.value
}
foreach ($c in ($Codes -split ",")) {
  Write-Host "=== $c ==="
  & $cdp -Method "Page.bringToFront" -ParamsJson "{}" -Match "web.whatsapp" | Out-Null
  $nav = @{ url = "https://web.whatsapp.com/accept?code=$c" } | ConvertTo-Json -Compress
  & $cdp -Method "Page.navigate" -ParamsJson $nav -Match "web.whatsapp" | Out-Null
  $found = ""
  for ($i=1; $i -le 9; $i++) {
    Start-Sleep -Seconds 6
    $t = Eval "JSON.stringify({b:Array.from(document.querySelectorAll('div[role=dialog] button')).map(x=>x.innerText.trim()).filter(Boolean)})"
    Write-Host ("  [" + (6*$i) + "s] " + $t)
    if ($t -match 'Join group') { $found = "joinable"; break }
    if ($t -match 'Request to join|approve') { $found = "approval"; break }
  }
  if ($found -ne "joinable") { Write-Host "  SKIP $found"; continue }
  Eval "(()=>{const d=document.querySelector('div[role=dialog]');if(!d)return '0';const b=Array.from(d.querySelectorAll('button')).find(x=>/join group/i.test(x.innerText||''));if(!b)return '0';b.click();return '1';})()" | Out-Null
  Start-Sleep -Seconds 9
  $h = Eval "JSON.stringify({head:((document.querySelector('#main header')||{}).innerText||'').slice(0,60)})"
  Write-Host ("  JOINED " + $h)
  $name = ($h | ConvertFrom-Json).head
  Write-Host ("  GROUP=" + $name)
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\wa_members.ps1" -GroupMatch $name.Trim() -WaitSec 6 2>&1 | Select-String "RESULT|WROTE" | ForEach-Object { "  " + $_.Line }
  Start-Sleep -Seconds 20
}
