# feishu.ps1 -- 飞书多维表格读写 + 群机器人播报
# 所有凭据与目标表都来自 config.json，不硬编码。

param(
  [string]$ConfigPath = ""
)

if (-not $ConfigPath) {
  $here = Split-Path -Parent $PSScriptRoot
  $ConfigPath = Join-Path $here "config.json"
}

$script:Cfg  = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Fs   = $script:Cfg.feishu
$script:Root = "https://open.feishu.cn/open-apis"
$script:Tok  = $null
$script:TokExp = [datetime]::MinValue

function Get-FsToken {
  if ($script:Tok -and (Get-Date) -lt $script:TokExp) { return $script:Tok }
  $body = @{ app_id = $script:Fs.app_id; app_secret = $script:Fs.app_secret } | ConvertTo-Json
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $r = Invoke-RestMethod -Uri "$script:Root/auth/v3/tenant_access_token/internal" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
  if ($r.code -ne 0) { throw "token failed: $($r.code) $($r.msg)" }
  $script:Tok = $r.tenant_access_token
  $script:TokExp = (Get-Date).AddSeconds([int]$r.expire - 120)
  return $script:Tok
}

function Invoke-Fs {
  param(
    [string]$Method,
    [string]$Path,
    $Payload = $null
  )
  $token = Get-FsToken
  $headers = @{ Authorization = "Bearer $token" }
  $uri = "$script:Root$Path"
  try {
    if ($Payload -eq $null) {
      return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
    }
    $json = $Payload
    if ($Payload -isnot [string]) { $json = $Payload | ConvertTo-Json -Depth 12 }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bytes
  } catch {
    $stream = $_.Exception.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream)
    throw ("FS API " + $Method + " " + $Path + " -> " + $reader.ReadToEnd())
  }
}

function Get-TableBase {
  param([string]$TableId)
  if (-not $TableId) { $TableId = $script:Fs.table_id }
  return "/bitable/v1/apps/" + $script:Fs.base_app_token + "/tables/" + $TableId
}

function Get-FsRecords {
  param([string]$TableId)
  $path = (Get-TableBase $TableId) + "/records?page_size=500"
  $all = @()
  $token = ""
  while ($true) {
    $u = $path
    if ($token) { $u = $path + "&page_token=" + $token }
    $res = Invoke-Fs -Method Get -Path $u
    $all += $res.data.items
    if (-not $res.data.has_more) { break }
    $token = $res.data.page_token
  }
  return $all
}

function Get-FsFields {
  param([string]$TableId)
  $res = Invoke-Fs -Method Get -Path ((Get-TableBase $TableId) + "/fields?page_size=100")
  return $res.data.items
}

function Add-FsRecords {
  param([array]$FieldSets, [string]$TableId)
  $created = 0
  $total = $FieldSets.Count
  $start = 0
  while ($start -lt $total) {
    $end = [Math]::Min($start + 499, $total - 1)
    $recs = New-Object System.Collections.ArrayList
    for ($i = $start; $i -le $end; $i++) {
      $item = @{}
      $item.Add("fields", $FieldSets[$i])
      [void]$recs.Add($item)
    }
    $payload = @{}
    $payload.Add("records", $recs.ToArray())
    $res = Invoke-Fs -Method Post -Path ((Get-TableBase $TableId) + "/records/batch_create") -Payload $payload
    if ($res.code -ne 0) { throw "batch_create failed: $($res.code) $($res.msg)" }
    $created += $res.data.records.Count
    $start += 500
  }
  return $created
}

function Update-FsRecords {
  param([array]$Updates, [string]$TableId)
  $payload = @{}
  $payload.Add("records", $Updates)
  $res = Invoke-Fs -Method Post -Path ((Get-TableBase $TableId) + "/records/batch_update") -Payload $payload
  if ($res.code -ne 0) { throw "batch_update failed: $($res.code) $($res.msg)" }
  return $res.data.records.Count
}

function Remove-FsRecords {
  param([array]$RecordIds, [string]$TableId)
  $payload = @{}
  $payload.Add("records", $RecordIds)
  $res = Invoke-Fs -Method Post -Path ((Get-TableBase $TableId) + "/records/batch_delete") -Payload $payload
  if ($res.code -ne 0) { throw "batch_delete failed: $($res.code) $($res.msg)" }
  return $RecordIds.Count
}

function Format-Num {
  param([double]$Value)
  $dec = [int]$script:Cfg.report.decimals
  $wan = [double]$script:Cfg.report.wan_threshold
  $k = [double]$script:Cfg.report.k_threshold
  if ($Value -ge $wan) {
    $v = $Value / 10000
    return $v.ToString("N" + $dec) + "w"
  }
  if ($Value -ge $k) {
    $v = $Value / 1000
    return $v.ToString("N" + $dec) + "k"
  }
  return $Value.ToString("N0")
}

function Send-Card {
  param($Card)
  $body = @{}
  $body.Add("msg_type", "interactive")
  $body.Add("card", $Card)
  $json = $body | ConvertTo-Json -Depth 20
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Uri $script:Fs.webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
}

function Send-Text {
  param([string]$Text)
  $body = @{}
  $body.Add("msg_type", "text")
  $content = @{}
  $content.Add("text", $Text)
  $body.Add("content", $content)
  $json = $body | ConvertTo-Json -Depth 6
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Uri $script:Fs.webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
}
