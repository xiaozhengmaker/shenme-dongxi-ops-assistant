param([string[]]$Groups)
$ErrorActionPreference = "Stop"
$cdp = "D:\DeepSeek\运营\cdp_call.ps1"
function Eval([string]$js) {
  $p = @{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
  $r = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "web.whatsapp"
  if (-not $r) { return "" }
  return ($r | ConvertFrom-Json).result.value
}
& $cdp -Method "Page.bringToFront" -ParamsJson "{}" -Match "web.whatsapp" | Out-Null
foreach ($g in $Groups) {
  Write-Host "=== $g ==="
  $open = @"
(() => {
  const rows = Array.from(document.querySelectorAll('#pane-side div[role=gridcell]'));
  const row = rows.find(r => (r.innerText||'').includes('$g'));
  if (!row) return JSON.stringify({ok:false, why:'row not found'});
  const cell = row.querySelector('[tabindex="0"]') || row;
  cell.focus();
  return JSON.stringify({ok:true, txt:(row.innerText||'').slice(0,40)});
})()
"@
  $r1 = Eval $open
  Write-Host ("  FOCUS " + $r1)
  if ($r1 -notmatch '"ok":true') { continue }
  $keys = @{ type = "keyDown"; windowsVirtualKeyCode = 13; key = "Enter"; code = "Enter" } | ConvertTo-Json -Compress
  $keys2 = @{ type = "keyUp"; windowsVirtualKeyCode = 13; key = "Enter"; code = "Enter" } | ConvertTo-Json -Compress
  & $cdp -Method "Input.dispatchKeyEvent" -ParamsJson $keys -Match "web.whatsapp" | Out-Null
  & $cdp -Method "Input.dispatchKeyEvent" -ParamsJson $keys2 -Match "web.whatsapp" | Out-Null
  Start-Sleep -Seconds 3
  $menu = @"
(() => {
  const h = document.querySelector('#main header');
  if (!h) return JSON.stringify({ok:false, why:'no header'});
  const btn = h.querySelector('div[role=button]') || h;
  btn.click();
  return JSON.stringify({ok:true, title:(h.innerText||'').slice(0,40)});
})()
"@
  $r2 = Eval $menu
  Write-Host ("  HEADER " + $r2)
  Start-Sleep -Seconds 2
  $pick = @"
(() => {
  const items = Array.from(document.querySelectorAll('li, div[role=button], div[role=menuitem]'));
  const it = items.find(x => /exit group|sair do grupo|leave group/i.test((x.innerText||'').trim()));
  if (!it) return JSON.stringify({ok:false, why:'no exit item'});
  it.click();
  return JSON.stringify({ok:true, picked:(it.innerText||'').trim().slice(0,30)});
})()
"@
  $r3 = Eval $pick
  Write-Host ("  PICK " + $r3)
  Start-Sleep -Seconds 2
  $confirm = @"
(() => {
  const d = document.querySelector('div[role=dialog]');
  if (!d) return JSON.stringify({ok:false, why:'no confirm dialog'});
  const b = Array.from(d.querySelectorAll('button')).find(x => /^(exit|sair|leave)/i.test((x.innerText||'').trim()));
  if (!b) return JSON.stringify({ok:false, why:'no confirm btn', btns:Array.from(d.querySelectorAll('button')).map(x=>x.innerText)});
  b.click();
  return JSON.stringify({ok:true, btn:(b.innerText||'').trim()});
})()
"@
  $r4 = Eval $confirm
  Write-Host ("  CONFIRM " + $r4)
  Start-Sleep -Seconds 3
}
Write-Host "DONE"
