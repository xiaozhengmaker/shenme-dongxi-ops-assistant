$ErrorActionPreference = "Stop"
$cdp = "D:\DeepSeek\运营\cdp_call.ps1"

function Eval($match, $expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 5
  $r = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match $match
  try { return (($r | ConvertFrom-Json).result.value | ConvertFrom-Json) } catch { return $null }
}
function Nav($match, $url, $waitSec = 5) {
  & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $url } | ConvertTo-Json -Compress) -Match $match | Out-Null
  Start-Sleep -Seconds $waitSec
}

$codes = [ordered]@{}
$codes["LZCzB95E9di5LqOhWwSHuk"] = "leftover-tab"

# Linkado: counter strike -> detail -> code
Nav "linkado\.app" ("https://linkado.app/busca?q=" + [uri]::EscapeDataString("counter strike"))
$g = Eval "linkado\.app" 'JSON.stringify(Array.from(document.querySelectorAll("a[href^=\"/grupo/\"]")).map(a=>({t:(a.innerText||"").replace(/\n/g," ").trim().slice(0,40),h:a.getAttribute("href")})))'
if ($g -and @($g).Count -gt 0) {
  $h = @($g)[0].h
  $title = @($g)[0].t
  Nav "linkado\.app" ("https://linkado.app" + $h)
  $d = Eval "linkado\.app" 'JSON.stringify((function(){const l=Array.from(document.querySelectorAll("a")).map(a=>a.href).filter(h=>/chat\.whatsapp\.com/.test(h));return l[0]||null;})())'
  if ($d) { $codes[($d -split "/")[-1]] = "linkado:" + $title }
}

# grupbul: yonlendir -> wait -> read location
Nav "grupbul\.com" "https://grupbul.com/yonlendir/709995/1419990" 3
$loc = Eval "grupbul\.com" 'JSON.stringify({href:location.href})'
Start-Sleep -Seconds 7
$loc2 = Eval "grupbul\.com" 'JSON.stringify({href:location.href})'
"grupbul redirect: " + $loc.href + "  ->  " + $loc2.href
if ($loc2.href -match "chat\.whatsapp\.com/([A-Za-z0-9]+)") { $codes[$Matches[1]] = "grupbul:Counter-Strike 2 Olympos" }

"=== candidates: " + $codes.Count
foreach ($c in $codes.Keys) {
  Nav "web\.whatsapp\.com" ("https://web.whatsapp.com/accept?code=" + $c) 4
  $w = Eval "web\.whatsapp\.com" 'JSON.stringify((function(){const d=document.querySelector("[role=\"dialog\"]");const btns=Array.from(new Set(Array.from(document.querySelectorAll("button, [role=\"button\"]")).map(x=>(x.innerText||"").trim()).filter(Boolean)));return {dlg:d?(d.innerText||"").replace(/\n/g," | ").slice(0,150):null,btns:btns.slice(0,8)};})())'
  $all = ""
  if ($w) { $all = (@($w.btns) -join " || ") + " :: " + $w.dlg }
  $kind = "unknown"
  if ($all -match "Request to join|Solicitar") { $kind = "request" }
  elseif ($all -match "Join group|Entrar no grupo") { $kind = "join" }
  elseif ($all -match "Couldn't join") { $kind = "dead" }
  "[" + $kind + "] " + $codes[$c] + "  code=" + $c
  if ($w -and $w.dlg) { "      " + $w.dlg }
}
