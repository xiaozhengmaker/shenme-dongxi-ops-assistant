# lib/naming.ps1 - 群名解析（title -> t -> 加入回执），离线、无平台请求
$script:NamingStats = @{ from_title = 0; from_t = 0; from_receipt = 0; missing = 0 }

function Reset-NamingStats {
  $script:NamingStats = @{ from_title = 0; from_t = 0; from_receipt = 0; missing = 0 }
}

function Get-NamingStats {
  return @{
    from_title   = [int]$script:NamingStats.from_title
    from_t       = [int]$script:NamingStats.from_t
    from_receipt = [int]$script:NamingStats.from_receipt
    missing      = [int]$script:NamingStats.missing
  }
}

function Get-ObjField($o, [string]$k) {
  if ($null -eq $o) { return "" }
  try {
    if ($o -is [System.Collections.IDictionary]) {
      if ($o.Contains($k)) { return [string]$o[$k] }
      return ""
    }
    $p = $o.PSObject.Properties[$k]
    if ($p) { return [string]$p.Value }
  } catch { }
  return ""
}

# 解析顺序：title -> t -> 加入回执（同 id/u）-> 空
# 返回 @{ name; src } ; src ∈ title|t|receipt|missing
function Resolve-JoinName($o, $receipts, [bool]$useReceipt = $true) {
  $t = (Get-ObjField $o "title").Trim()
  if ($t) { $script:NamingStats.from_title++; return @{ name = $t; src = "title" } }

  $t2 = (Get-ObjField $o "t").Trim()
  if ($t2) { $script:NamingStats.from_t++; return @{ name = $t2; src = "t" } }

  if ($useReceipt -and $receipts) {
    $id = (Get-ObjField $o "id").Trim()
    $u = (Get-ObjField $o "u").Trim()
    foreach ($k in @($id, $u)) {
      if (-not $k) { continue }
      if ($receipts.ContainsKey($k)) {
        $rn = [string]$receipts[$k]
        if ($rn.Trim()) { $script:NamingStats.from_receipt++; return @{ name = $rn.Trim(); src = "receipt" } }
      }
    }
  }

  $script:NamingStats.missing++
  return @{ name = ""; src = "missing" }
}
