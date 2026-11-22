# join_result.ps1 -- Steam 加入结果判定（纯函数，供 steam_join.ps1 与离线测试复用）
# 规则（2026-11-22 修正，针对「本来已是成员却被记成 not_joined」）：
#   1) BEFORE 已是成员（Leave Group / 成员声明）-> already_member，绝不再提交
#   2) AFTER 出现 Leave Group / 成员声明 / already a member -> joined
#   3) AFTER 是 Steam 错误页（重复加入被打回）-> already_member_or_unknown，不能记 not_joined
#   4) AFTER 出现待审批 -> pending
#   5) 其余 -> not_joined；AFTER 缺失 -> unknown

function Get-SteamJoinOutcome {
  param($Before = $null, $After = $null, [string]$AfterText = "")
  if ($Before -and ([bool]$Before.leaveBtn -or [bool]$Before.isMember)) { return "already_member" }
  if ($null -eq $After) { return "unknown" }
  if ([bool]$After.leaveBtn -or [bool]$After.isMember) { return "joined" }
  if ($AfterText -match '(?i)already a member|you are a member|您已是该组成员|您已經是該組成員') { return "joined" }
  if ([bool]$After.errPage -or $AfterText -match '(?i)Steam Community :: Error') { return "already_member_or_unknown" }
  if ([bool]$After.pending) { return "pending" }
  return "not_joined"
}