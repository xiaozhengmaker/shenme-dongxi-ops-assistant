# join_dedup.Tests.ps1 — 隔离群样本 -> 加入状态 -> 模拟飞书写入 -> 重复去重
# 说明：本测试【不】调用飞书 API、不写任何真实数据；只调用 lib\join_guard.ps1 的
#       纯函数（Get-JoinRecordDisposition / Get-JoinDispatchDecision）+ 本文件内的
#       假 Feishu 表（内存 HashSet），用于验证「同一群重复加入不会重复计数」的口径。
$ErrorActionPreference = "Stop"
$baseDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $baseDir "lib\join_guard.ps1")
$fails = 0
function T([bool]$ok, [string]$name, [string]$detail = "") { if ($ok) { "PASS $name" } else { "FAIL $name  $detail"; $script:fails++ } }

# —— 假飞书表：key = 群组唯一键，value = 状态 ——
$fsTable = @{}
function Sim-FeishuWrite([string]$key, [string]$result) {
  # 模拟 hub.ps1 里 Write-JoinRecord 的口径：新建才算 added，已存在算 existing
  if (-not $fsTable.ContainsKey($key)) {
    if ($result -eq "joined") { $fsTable[$key] = "已加入"; return "added" }
    $fsTable[$key] = "需验证-不申请"
    return "local"
  }
  return "existing"
}

# 样本：一个 Telegram 群
$key = "TG-@iso_demo_group"
T (-not $fsTable.ContainsKey($key)) "样本: 起始不在表内"

# 第一次：真实加入 → added
$st1 = Sim-FeishuWrite $key "joined"
$d1 = Get-JoinRecordDisposition -Status $st1
T ($st1 -eq "added") "第一次写: status=added"
T ([int]$d1.joined -eq 1) "第一次写: joined 计数 +1"
T ($fsTable[$key] -eq "已加入") "第一次写: 表内状态=已加入"

# 第二次：同一群再次 dispatch 成功（例如重复派发/重跑）→ existing，不得重复计数
$st2 = Sim-FeishuWrite $key "joined"
$d2 = Get-JoinRecordDisposition -Status $st2
T ($st2 -eq "existing") "重复加入: status=existing"
T ([int]$d2.joined -eq 0) "重复加入: joined 不累加"
T ($fsTable.Count -eq 1) "重复加入: 表内仍只有 1 条"

# 待审批不属于 joined
$st3 = Sim-FeishuWrite "TG-@iso_pending_group" "request_sent"
$d3 = Get-JoinRecordDisposition -Status $st3
T ([int]$d3.joined -eq 0) "pending: 不计 joined"

# 已加入目标的派发决策：不应再点击
# 白名单场景：已加入目标不应被再次派发（用 allow 字段做断言）
$dd = Get-JoinDispatchDecision -Whitelist @("tg-@iso_demo_group") -TargetKeys @("tg-@iso_demo_group") -Dispatched 1 -MaxAttempts 1
T ($dd.allow -eq $false -and $dd.reason -eq "attempt_cap") "已加入目标: 达到单轮尝试上限后不再派发 (allow=$($dd.allow), reason=$($dd.reason))"
$dd2 = Get-JoinDispatchDecision -Whitelist @("tg-@other_group") -TargetKeys @("tg-@iso_demo_group")
T ($dd2.allow -eq $false -and $dd2.reason -eq "not_whitelisted") "白名单外目标: 不派发 (reason=$($dd2.reason))"

# 汇总
"counts: added(joined)=1 existing=0 pending=0  fs_rows=" + $fsTable.Count
if ($fails -gt 0) { "join_dedup: $fails FAILED"; exit 1 }
"join_dedup: all PASS"