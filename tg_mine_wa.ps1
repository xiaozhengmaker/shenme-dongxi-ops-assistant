param([int]$Batch = 5, [int]$MaxChats = 160)
$ErrorActionPreference = "Stop"
$root = "D:\DeepSeek\运营"
$cdp = Join-Path $root "cdp_call.ps1"
function Eval([string]$js) {
  $p = @{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
  $r = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram"
  if (-not $r) { return $null }
  return ($r | ConvertFrom-Json).result.value
}
$init = @"
(async () => {
  const api = window.rootScope.managers.apiManager;
  window.__waMine = { list: [], i: 0, found: [] };
  let peer = {_: 'inputPeerEmpty'}; let off = 0;
  while (window.__waMine.list.length < $MaxChats && off < 6) {
    const d = await api.invokeApi('messages.getDialogs', {limit: 100, offset_peer: peer, offset_id: 0, offset_date: 0, hash: 0});
    const cs = (d.chats || []).filter(c => c._ === 'channel' && c.access_hash);
    for (const c of cs) window.__waMine.list.push({id: c.id, ah: c.access_hash, t: c.title || ''});
    if (!cs.length) break;
    const last = cs[cs.length - 1];
    peer = {_: 'inputPeerChannel', channel_id: last.id, access_hash: last.access_hash};
    off++;
  }
  return JSON.stringify({n: window.__waMine.list.length});
})()
"@
$info = (Eval $init) | ConvertFrom-Json
Write-Host ("CHATS=" + $info.n)
$total = [int]$info.n
while ($true) {
  $step = @"
(async () => {
  const api = window.rootScope.managers.apiManager;
  const m = window.__waMine;
  const end = Math.min(m.i + $Batch, m.list.length);
  let hits = 0;
  for (let k = m.i; k < end; k++) {
    const c = m.list[k];
    try {
      const h = await api.invokeApi('messages.getHistory', {peer: {_: 'inputPeerChannel', channel_id: c.id, access_hash: c.ah}, offset_id: 0, offset_date: 0, add_offset: 0, limit: 100, max_id: 0, min_id: 0, hash: 0});
      const rows = (h.messages || []);
      for (const msg of rows) {
        const s = (msg.message || '') + ' ' + (msg.entities || []).map(e => e.url || '').join(' ');
        const re = /chat\.whatsapp\.com\/([A-Za-z0-9]{10,})/g; let x;
        while ((x = re.exec(s)) !== null) { m.found.push({g: c.t, code: x[1]}); hits++; }
      }
    } catch (e) { }
  }
  m.i = end;
  return JSON.stringify({i: m.i, n: m.list.length, hits: hits, found: m.found.length});
})()
"@
  $r = Eval $step
  if (-not $r) { Write-Host "STEP FAILED"; break }
  $o = $r | ConvertFrom-Json
  Write-Host ("  " + $o.i + "/" + $o.n + " found=" + $o.found)
  if ([int]$o.i -ge $total) { break }
  Start-Sleep -Milliseconds 400
}
$fin = @"
(async () => {
  const m = window.__waMine;
  const uniq = [...new Map(m.found.map(x => [x.code, x])).values()];
  return JSON.stringify(uniq);
})()
"@
$all = (Eval $fin) | ConvertFrom-Json
$lines = @()
foreach ($x in $all) { $lines += ($x.code + "  " + $x.g) }
$outFile = Join-Path $root "data\wa_codes_mined.txt"
[System.IO.File]::WriteAllLines($outFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("UNIQUE_CODES=" + $lines.Count + " -> " + $outFile)
