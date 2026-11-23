# 关键词命中统计 / 自适应排序
# 目的：把「一直搜不到东西」的词自动降权甚至停用，避免老词把 8 连 0 保护撞出来。
# 数据文件：data\kw_stats.json
#   结构：{ "Telegram|cs2 trade": { rounds:3, hits:2, misses:1, last:"2026-11-23T17:40:00+08:00", off_until:"..." } }

function Get-KwStatsPath([string]$BaseDir) {
    return (Join-Path $BaseDir "data\kw_stats.json")
}

function Read-KwStats([string]$BaseDir) {
    $map = @{}
    $p = Get-KwStatsPath $BaseDir
    if (-not (Test-Path $p)) { return $map }
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if (-not $raw) { return $map }
        $o = $raw | ConvertFrom-Json
        foreach ($prop in $o.PSObject.Properties) {
            $map[$prop.Name] = $prop.Value
        }
    } catch { }
    return $map
}

function Save-KwStats([string]$BaseDir, $Map) {
    $p = Get-KwStatsPath $BaseDir
    $dir = Split-Path -Parent $p
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    try {
        ($Map | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8
    } catch { }
}

function Get-KwStatKey([string]$Platform, [string]$Keyword) {
    return ($Platform + "|" + $Keyword.Trim().ToLowerInvariant())
}

# 记录一次搜索结果：raw=返回条数，added=新增候选数，failed=请求异常
function Register-KwResult([string]$BaseDir, [string]$Platform, [string]$Keyword, [int]$Raw, [int]$Added, [bool]$Failed) {
    if (-not $Keyword) { return }
    $map = Read-KwStats $BaseDir
    $k = Get-KwStatKey $Platform $Keyword
    $e = $map[$k]
    if (-not $e) { $e = [pscustomobject]@{ rounds = 0; hits = 0; misses = 0; last = ""; off_until = "" } }
    $e.rounds = [int]$e.rounds + 1
    if ($Added -gt 0) { $e.hits = [int]$e.hits + 1 }
    elseif ($Raw -eq 0 -and -not $Failed) { $e.misses = [int]$e.misses + 1 }
    $e.last = (Get-Date).ToString("o")
    # 连续 3 次「0 条结果且从未命中」→ 停用 24 小时
    if ([int]$e.hits -eq 0 -and [int]$e.misses -ge 3) {
        $e.off_until = (Get-Date).AddHours(24).ToString("o")
        $e.misses = 0
    }
    $map[$k] = $e
    Save-KwStats $BaseDir $map
}

function Test-KwStatOff($Entry) {
    if (-not $Entry) { return $false }
    $ou = [string]$Entry.off_until
    if (-not $ou) { return $false }
    try { return ([datetime]$ou -gt (Get-Date)) } catch { return $false }
}

# 返回排好序的关键词：命中率高的在前；停用中的词直接剔除；全被剔除时退回原始顺序
function Get-KwRanked([string]$BaseDir, [string]$Platform, $Keywords) {
    $list = @($Keywords | Where-Object { $_ -and ([string]$_).Trim() })
    if ($list.Count -eq 0) { return @() }
    $map = Read-KwStats $BaseDir
    $scored = @()
    $off = 0
    foreach ($kw in $list) {
        $e = $map[(Get-KwStatKey $Platform $kw)]
        if (Test-KwStatOff $e) { $off++; continue }
        $hits = 0; $rounds = 0
        if ($e) { $hits = [int]$e.hits; $rounds = [int]$e.rounds }
        # 拉普拉斯平滑：没跑过的词排中间，稳定命中的词靠前，纯 0 命中的词靠后
        $score = ($hits + 0.5) / ($rounds + 1.0)
        $scored += [pscustomobject]@{ kw = [string]$kw; score = $score; rounds = $rounds }
    }
    if ($scored.Count -eq 0) {
        return @($list)
    }
    $sorted = @($scored | Sort-Object -Property @{ Expression = "score"; Descending = $true }, @{ Expression = "rounds"; Descending = $false } | ForEach-Object { $_.kw })
    return $sorted
}

# 供 hub 判断「这个词以前命中过吗」——只有曾经有产出的词返回 0 才算异常（可能被限流）
function Test-KwStatKnownGood([string]$BaseDir, [string]$Platform, [string]$Keyword) {
    $map = Read-KwStats $BaseDir
    $e = $map[(Get-KwStatKey $Platform $Keyword)]
    if (-not $e) { return $false }
    return ([int]$e.hits -gt 0)
}
