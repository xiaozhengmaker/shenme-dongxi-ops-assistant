# tools/test_naming.ps1 - 4 条离线样例，验证 title -> t -> 回执 -> 空
$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\naming.ps1")

Reset-NamingStats
$receipts = @{}
$receipts["123"] = "Receipt Name A"

$cases = @(
  @{ name = "1_title"; obj = @{ id = "111"; title = "T Title" }; expect = "T Title"; src = "title" },
  @{ name = "2_t_only"; obj = @{ id = "222"; t = "T From t" }; expect = "T From t"; src = "t" },
  @{ name = "3_receipt"; obj = @{ id = "123" }; expect = "Receipt Name A"; src = "receipt" },
  @{ name = "4_mismatch"; obj = @{ id = "999" }; expect = ""; src = "missing" }
)

$fail = 0
foreach ($c in $cases) {
  $r = Resolve-JoinName $c.obj $receipts $true
  $ok = ($r.name -eq $c.expect) -and ($r.src -eq $c.src)
  if (-not $ok) { $fail++ }
  Write-Host ("{0} => name='{1}' src='{2}' expect='{3}/{4}' {5}" -f $c.name, $r.name, $r.src, $c.expect, $c.src, $(if ($ok) { "PASS" } else { "FAIL" }))
}

$st = Get-NamingStats
Write-Host ("stats: from_title={0} from_t={1} from_receipt={2} missing={3}" -f $st.from_title, $st.from_t, $st.from_receipt, $st.missing)
if ($fail -gt 0) { Write-Host ("RESULT: FAIL " + $fail); exit 1 }
Write-Host "RESULT: OK"
