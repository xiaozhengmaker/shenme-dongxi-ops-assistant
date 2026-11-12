param(
  [string]$LinksFile = "D:\DeepSeek\运营\data\wa_links.csv",
  [int]$Max = 40,
  [int]$WaitSec = 12,
  [int]$SpacingMinMs = 4000,
  [int]$SpacingMaxMs = 9000,
  [string]$OutCsv = "D:\DeepSeek\运营\data\wa_screen.csv",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = "D:\DeepSeek\运营"
$cdp  = Join-Path $root "cdp_call.ps1"
. (Join-Path $root "lib\log.ps1")
Set-LogFile (Join-Path $root "logs\wa_screen.log")

function Log($m) { Write-Log -msg $m -level "INFO" -tag "wa_screen" }

if (-not (Test-Path $LinksFile)) { Log "missing links file: $LinksFile"; exit 2 }

$rows = @()
$lines = [System.IO.File]::ReadAllLines($LinksFile, [System.Text.Encoding]::UTF8)
$kwRe = "(?i)(cs2|csgo|cs 2|counter|strike|skin|trade|trocas|rifa)"
for ($i = 1; $i -lt $lines.Count; $i++) {
  $ln = $lines[$i].Trim()
  if ($ln -eq "") { continue }
  $parts = $ln.Split(",")
  if ($parts.Count -lt 2) { continue }
  $code = $parts[0].Trim()
  $title = $parts[1].Trim()
  $kw = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
  if ($code -notmatch "^[A-Za-z0-9]{15,}$") { continue }
  if (($title + " " + $kw) -notmatch $kwRe) { continue }
  $rows += [pscustomobject]@{ code = $code; url = ("https://web.whatsapp.com/accept?code=" + $code); title = $title; kw = $kw }
}

$seen = @{}
$uniq = @()
foreach ($r in $rows) { if (-not $seen.ContainsKey($r.code)) { $seen[$r.code] = 1; $uniq += $r } }
$uniq = @($uniq | Select-Object -First $Max)
Log ("candidates=" + $uniq.Count + " from " + $LinksFile)

$probe = @'
(() => {
  const out = { url: location.href, title: document.title };
  const dlg = document.querySelector('div[role=dialog]');
  out.hasDialog = !!dlg;
  out.text = dlg ? (dlg.innerText || "").replace(/\s+/g, " ").slice(0, 300) : ((document.body && document.body.innerText) || "").replace(/\s+/g, " ").slice(0, 200);
  out.body = ((document.body && document.body.innerText) || "").replace(/\s+/g, " ").slice(0, 500);
  let btns = Array.from(document.querySelectorAll('div[role=dialog] div[role=button], div[role=dialog] button'));
  if (!btns.length) { btns = Array.from(document.querySelectorAll('div[role=button], button')); }
  out.buttons = btns.map(b => (b.innerText || "").trim()).filter(t => t && t.length < 40);
  return JSON.stringify(out);
})()
'@

function Invoke-Cdp($method, $paramsJson, $match) {
  $raw = & $cdp -Method $method -ParamsJson $paramsJson -Match $match 2>&1
  return ($raw | Out-String).Trim()
}

$results = @()
$i = 0
foreach ($c in $uniq) {
  $i++
  $accept = "https://web.whatsapp.com/accept?code=" + $c.code
  Log ("[$i/" + $uniq.Count + "] open " + $c.code)
  if ($DryRun) { continue }

  # --- keep WA tab in foreground (background tabs get throttled) ---
  Invoke-Cdp "Page.bringToFront" "{}" "web.whatsapp" | Out-Null

  # ready-gate disabled (it forces a fresh WA reload -> sync overlay again)
  $nav = @{ url = $accept } | ConvertTo-Json -Compress
  Invoke-Cdp "Page.navigate" $nav "web.whatsapp" | Out-Null
  Start-Sleep -Seconds $WaitSec

  $p = @{ expression = $probe; returnByValue = $true } | ConvertTo-Json -Compress
  $raw = ""
  for ($try = 1; $try -le 8; $try++) {
    Invoke-Cdp "Page.bringToFront" "{}" "web.whatsapp" | Out-Null
    $raw = Invoke-Cdp "Runtime.evaluate" $p "web.whatsapp"
    if ($raw -match '"hasDialog":true') { break }
    if ($raw -notmatch [regex]::Escape($c.code)) {
      Invoke-Cdp "Page.navigate" $nav "web.whatsapp" | Out-Null
      Start-Sleep -Seconds 5
      continue
    }
    if ($raw -match '"loading"|downloading') { Start-Sleep -Seconds 4; continue }
    Start-Sleep -Seconds 4
  }
  Log ("PROBE-RAW " + $raw)
  $verdict = "unknown"; $name = ""; $members = ""
  # 两层解析：CDP 外层 {result:{value:"<json>"}} -> 内层 payload
  $json = $null
  try {
    $outer = $raw | ConvertFrom-Json
    $inner = $outer.result.value
    if ($inner) { $json = $inner | ConvertFrom-Json }
  } catch { $json = $null }
  if (-not $json -or ([string]$json.text).Length -lt 15) {
    Start-Sleep -Seconds 4
    $raw2 = Invoke-Cdp "Runtime.evaluate" $p "web.whatsapp"
    try {
      $outer2 = $raw2 | ConvertFrom-Json
      if ($outer2.result.value) { $json = $outer2.result.value | ConvertFrom-Json }
    } catch { }
  }
  if ($json) {
    $bt = @($json.buttons) -join "|"
    $hay = ($bt + " | " + [string]$json.text + " | " + [string]$json.body)
    if ($hay -match "(?i)(request to join|an admin must approve|approve your request)") { $verdict = "approval" }
    elseif ($hay -match "(?i)join group") { $verdict = "joinable" }
    elseif ($hay -match "(?i)(couldn.t join|invalid|expired|no longer)") { $verdict = "dead" }
    elseif ($hay -match "(?i)(downloading|don.t close this window)") {
      $verdict = "loading"
      for ($k = 1; $k -le 3; $k++) {
        Start-Sleep -Seconds 5
        Invoke-Cdp "Page.bringToFront" "{}" "web.whatsapp" | Out-Null
        $raw3 = Invoke-Cdp "Runtime.evaluate" $p "web.whatsapp"
        $j3 = $null
        try { $o3 = $raw3 | ConvertFrom-Json; if ($o3.result.value) { $j3 = $o3.result.value | ConvertFrom-Json } } catch { }
        if (-not $j3) { continue }
        $hay3 = (@($j3.buttons) -join "|") + " | " + [string]$j3.text + " | " + [string]$j3.body
        if ($hay3 -match "(?i)(request to join|an admin must approve|approve your request)") { $verdict = "approval"; $hay = $hay3; break }
        if ($hay3 -match "(?i)join group") { $verdict = "joinable"; $hay = $hay3; break }
        if ($hay3 -match "(?i)(couldn.t join|invalid|expired|no longer)") { $verdict = "dead"; $hay = $hay3; break }
      }
    }
    elseif (-not $json.hasDialog) { $verdict = "no-dialog" }
    $t = [string]$json.text
    if ($t -match "^(.{3,60}?)\s") { $name = $Matches[1] }
    if ($t -match "\+(\d{1,6})") { $members = "+" + $Matches[1] }
  } else {
    $verdict = "probe-fail"
  }

  Log ("  -> " + $verdict + " name=" + $name + " " + $members)
  $results += [pscustomobject]@{ ts = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); code = $c.code; verdict = $verdict; name = $name; members = $members; url = $accept }
  $sleep = Get-Random -Minimum $SpacingMinMs -Maximum $SpacingMaxMs
  Start-Sleep -Milliseconds $sleep
}

if (-not $DryRun -and $results.Count -gt 0) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("发现时间,邀请码,判定,群名,规模,链接")
  foreach ($r in $results) { [void]$sb.AppendLine(($r.ts,$r.code,$r.verdict,$r.name,$r.members,$r.url) -join ",") }
  [System.IO.File]::WriteAllText($OutCsv, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
  Log ("WROTE " + $OutCsv + " rows=" + $results.Count)
}

$sum = $results | Group-Object verdict | ForEach-Object { "$($_.Name)=$($_.Count)" }
Log ("SUMMARY " + ($sum -join " "))
$joinable = @($results | Where-Object { $_.verdict -eq "joinable" })
Log ("joinable=" + $joinable.Count)
