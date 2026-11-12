param(
  [string]$GroupMatch = "Linhares",
  [string]$AcceptCode = "",
  [string]$OutDir = "D:\DeepSeek\运营\data",
  [int]$WaitSec = 4,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$cdp = "D:\DeepSeek\运营\cdp_call.ps1"
$match = "web\.whatsapp\.com"
$stamp = (Get-Date).ToString("yyyy/MM/dd")

function Eval([string]$js) {
  $p = @{ expression = $js; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
  $r = & $cdp -Method "Runtime.evaluate" -ParamsJson $p -Match $match
  if (-not $r) { return $null }
  return ($r | ConvertFrom-Json).result.value
}

function PressEnter {
  foreach ($t in "keyDown","keyUp") {
    $p = @{ type = $t; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 } | ConvertTo-Json -Compress
    & $cdp -Method "Input.dispatchKeyEvent" -ParamsJson $p -Match $match | Out-Null
  }
}

if ($AcceptCode -ne "") {
  $nav = @{ url = "https://web.whatsapp.com/accept?code=$AcceptCode" } | ConvertTo-Json -Compress
  & $cdp -Method "Page.navigate" -ParamsJson $nav -Match $match | Out-Null
  Start-Sleep -Seconds 8
  $probe = Eval 'JSON.stringify((function(){const d=document.querySelector("div[role=\"dialog\"]");const t=d?(d.innerText||""):"";const bs=d?Array.from(d.querySelectorAll("div[role=\"button\"],button")).map(b=>(b.innerText||"").trim()).filter(Boolean):[];return {hasDialog:!!d,head:t.slice(0,200),buttons:bs};})())'
  Write-Host "JOIN PROBE: $probe"
  if ($probe -notmatch '"buttons":\[[^\]]*Join group') {
    if ($probe -match 'approve|Request to join') { Write-Host "SKIP: 需要管理员审批，未申请" } else { Write-Host "SKIP: 没有 Join group 按钮" }
    exit 0
  }
  $click = Eval 'JSON.stringify((function(){const d=document.querySelector("div[role=\"dialog\"]");if(!d)return{ok:false};const b=Array.from(d.querySelectorAll("div[role=\"button\"],button")).find(x=>/^Join group$/i.test((x.innerText||"").trim()));if(!b)return{ok:false};b.focus();b.click();return{ok:true};})())'
  Write-Host "JOIN CLICK: $click"
  Start-Sleep -Seconds 6
}

$reSrc = ConvertTo-Json $GroupMatch -Compress
$focusJs = 'JSON.stringify((function(reSrc){const re=new RegExp(reSrc,"i");const rows=Array.from(document.querySelectorAll("#pane-side div[role=\"row\"]"));const row=rows.find(r=>re.test(r.innerText||""));if(!row)return{ok:false,why:"row-not-found",rows:rows.length};const cell=row.querySelector("div[role=\"gridcell\"]")||row.querySelector("div[tabindex]")||row;cell.focus();return{ok:true,text:(row.innerText||"").replace(/\n/g," | ").slice(0,60)};})(' + $reSrc + '))'
$focus = Eval $focusJs
Write-Host "FOCUS: $focus"
if ($focus -notmatch '"ok":true') {
  Write-Host "ERR: 左侧列表没有匹配的群（先用 /accept?code= 进群，或改 -GroupMatch）"
  exit 2
}

PressEnter
Start-Sleep -Seconds $WaitSec

$headerJs = 'JSON.stringify((function(){const main=document.querySelector("#main");if(!main)return{ok:false,why:"no-main"};const h=main.querySelector("header");const raw=h?(h.innerText||""):"";const lines=raw.split("\n").map(s=>s.trim()).filter(Boolean);const title=lines[0]||"";const listLine=lines.slice(1).join(" ");const parts=listLine.split(/,\s*/).map(s=>s.trim()).filter(Boolean);const phoneRe=/^\+?[\d][\d\s\-().]{6,}$/;const phones=[],names=[];for(const p of parts){if(phoneRe.test(p))phones.push(p);else names.push(p);}return{ok:true,title:title,total:parts.length,phoneCount:phones.length,nameCount:names.length,phones:phones,names:names};})())'
$res = Eval $headerJs
Write-Host "HEADER: $res"
if ($res -notmatch '"ok":true') { exit 3 }

$o = $res | ConvertFrom-Json
$title = $o.title
Write-Host ("RESULT: group={0} phones={1} names={2} total={3}" -f $title, $o.phoneCount, $o.nameCount, $o.total)

if ($DryRun) { Write-Host "DRY RUN: 不写文件"; exit 0 }

$csv = Join-Path $OutDir "wa_users.csv"
$jsonl = Join-Path $OutDir "wa_users.jsonl"
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $csv)) {
  [System.IO.File]::WriteAllText($csv, "平台,群名,号码,昵称,角色,采集日,来源`r`n", $utf8bom)
}

$sb = New-Object System.Text.StringBuilder
$js = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($ph in $o.phones) {
  $norm = ($ph -replace '[^\d+]','')
  if ($seen.ContainsKey($norm)) { continue }
  $seen[$norm] = 1
  $null = $sb.AppendLine("WhatsApp,$title,$ph,,成员,$stamp,群成员页")
  [void]$js.Add((@{ platform="WhatsApp"; group=$title; phone=$ph; nick=""; role="成员"; date=$stamp; src="群成员页" } | ConvertTo-Json -Compress))
}
foreach ($nm in $o.names) {
  $clean = ($nm -replace '^~+\s*','').Trim()
  if ($clean -eq "You" -or $clean -eq "") { continue }
  $null = $sb.AppendLine("WhatsApp,$title,,$clean,成员,$stamp,群成员页")
  [void]$js.Add((@{ platform="WhatsApp"; group=$title; phone=""; nick=$clean; role="成员"; date=$stamp; src="群成员页" } | ConvertTo-Json -Compress))
}
[System.IO.File]::AppendAllText($csv, $sb.ToString(), $utf8)
if ($js.Count -gt 0) { [System.IO.File]::AppendAllText($jsonl, (($js -join "`r`n") + "`r`n"), $utf8) }
Write-Host "WROTE: $csv rows=$($js.Count)"
