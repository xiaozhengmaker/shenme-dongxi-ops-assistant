$ErrorActionPreference = "Stop"
$cdp = "D:\DeepSeek\运营\cdp_call.ps1"

function Eval($match, $expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 5
  $r = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match $match
  try { return (($r | ConvertFrom-Json).result.value | ConvertFrom-Json) } catch { return $null }
}
function Nav($match, $url) {
  & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $url } | ConvertTo-Json -Compress) -Match $match | Out-Null
  Start-Sleep -Seconds 4
}

$queries = @("cs2", "csgo", "counter strike", "skin", "cs trade", "skins cs2", "case")
$groups = [ordered]@{}
foreach ($q in $queries) {
  Nav "linkado\.app" ("https://linkado.app/busca?q=" + [uri]::EscapeDataString($q))
  $arr = Eval "linkado\.app" 'JSON.stringify(Array.from(document.querySelectorAll("a[href^=\"/grupo/\"]")).map(a=>({t:(a.innerText||"").replace(/\n/g," ").trim().slice(0,44),h:a.getAttribute("href")})))'
  if ($arr) { foreach ($g in $arr) { if (-not $groups.Contains($g.h)) { $groups[$g.h] = $g.t } } }
  "search " + $q + " -> " + (@($arr).Count) + " (total " + $groups.Count + ")"
}
"=== candidates: " + $groups.Count

$rows = @()
foreach ($h in $groups.Keys) {
  Nav "linkado\.app" ("https://linkado.app" + $h)
  $d = Eval "linkado\.app" 'JSON.stringify((function(){const l=Array.from(document.querySelectorAll("a")).map(a=>a.href).filter(h=>/chat\.whatsapp\.com/.test(h));return {link:l[0]||null};})())'
  if (-not $d -or -not $d.link) { continue }
  $code = ($d.link -split "/")[-1]
  Nav "web\.whatsapp\.com" ("https://web.whatsapp.com/accept?code=" + $code)
  Start-Sleep -Seconds 3
  $w = Eval "web\.whatsapp\.com" 'JSON.stringify((function(){const t=(document.body.innerText||"").replace(/\n/g," | ");const dlg=document.querySelector("[role=\"dialog\"]");const btns=Array.from(new Set(Array.from(document.querySelectorAll("button, [role=\"button\"]")).map(x=>(x.innerText||"").trim()).filter(Boolean)));return {dialog:dlg?(dlg.innerText||"").replace(/\n/g," | ").slice(0,140):null, btns:btns.slice(0,8), head:t.slice(0,120)};})())'
  $all = ""
  if ($w) { $all = (@($w.btns) -join " || ") + " :: " + $w.head }
  $kind = "unknown"
  if ($all -match "Request to join|Solicitar") { $kind = "request" }
  elseif ($all -match "Join group|Entrar no grupo") { $kind = "join" }
  elseif ($all -match "Couldn't join|n.o foi poss") { $kind = "dead" }
  elseif ($all -match "Invite|inv.lido|expired") { $kind = "invalid" }
  $rows += [pscustomobject]@{ kind = $kind; title = $groups[$h]; code = $code }
  "  [" + $kind + "] " + $groups[$h] + "  " + $code
}

"=== summary"
$rows | Group-Object kind | ForEach-Object { "  " + $_.Name + ": " + $_.Count }
$rows | Where-Object { $_.kind -eq "join" } | ForEach-Object { "JOINABLE: " + $_.title + "  code=" + $_.code }
