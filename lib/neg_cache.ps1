# 负面缓存：无效/需审批/找不到的群 24 小时内不再重试
# 目的：把「解析失败、@xxx 不存在、需要审批」的群从重复尝试里剔掉，省掉无谓请求。
# 文件：data\neg_cache.json
#   结构：{ "Telegram|u=xxx": { reason:"not_found", until:"2026-11-24T17:00:00+08:00", hits:2 } }

function Get-NegCachePath([string]$BaseDir) {
    return (Join-Path $BaseDir "data\neg_cache.json")
}

function Read-NegCache([string]$BaseDir) {
    $map = @{}
    $p = Get-NegCachePath $BaseDir
    if (-not (Test-Path $p)) { return $map }
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if (-not $raw) { return $map }
        $o = $raw | ConvertFrom-Json
        $now = Get-Date
        foreach ($prop in $o.PSObject.Properties) {
            $e = $prop.Value
            $u = ""
            try { $u = [string]$e.until } catch { }
            $alive = $true
            if ($u) { try { $alive = ([datetime]$u -gt $now) } catch { $alive = $true } }
            if ($alive) { $map[$prop.Name] = $e }
        }
    } catch { }
    return $map
}

function Save-NegCache([string]$BaseDir, $Map) {
    $p = Get-NegCachePath $BaseDir
    $dir = Split-Path -Parent $p
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    try { ($Map | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $p -Encoding UTF8 } catch { }
}

function Get-NegKey([string]$Platform, [string]$User) {
    if (-not $User) { return "" }
    return ($Platform + "|u=" + $User.Trim().ToLowerInvariant())
}

# 记录一次失败：not_found 24h；approval 7 天
function Set-NegEntry([string]$BaseDir, [string]$Platform, [string]$User, [string]$Reason) {
    $k = Get-NegKey $Platform $User
    if (-not $k) { return }
    $hours = 24
    if ($Reason -eq "approval" -or $Reason -eq "request_sent") { $hours = 168 }
    $map = Read-NegCache $BaseDir
    $e = $map[$k]
    $hits = 1
    if ($e) { try { $hits = [int]$e.hits + 1 } catch { $hits = 1 } }
    $map[$k] = [pscustomobject]@{
        reason = [string]$Reason
        until  = (Get-Date).AddHours($hours).ToString("o")
        hits   = $hits
        at     = (Get-Date).ToString("o")
    }
    Save-NegCache $BaseDir $map
}

function Test-NegCached([string]$BaseDir, [string]$Platform, [string]$User) {
    $k = Get-NegKey $Platform $User
    if (-not $k) { return $false }
    $map = Read-NegCache $BaseDir
    return $map.ContainsKey($k)
}
