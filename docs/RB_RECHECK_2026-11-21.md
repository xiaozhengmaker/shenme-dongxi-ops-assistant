# RB Skins 复核（2026-11-21，只读）

## 结论
**RB Skins Exclusivo #1 已是「已加入」状态**——不需要再做加入动作。

## 证据（只读，无点击）
1. 聊天列表存在行：`RB Skins Exclusivo #1 — Thursday — You joined via an invite link`
2. 打开 `https://web.whatsapp.com/accept?code=ELqC…` 两次：均直接回到 `/`，**无预览弹窗**（已加入的特征）
3. 该群从未出现 `Request to join` / 审批文案；11-19 那次受控窗口的单次点击后即进入成员态

## 归因修正
11-19 19:32–19:34 的隔离窗口（m12922 授权）使用的是 **RB** 的邀请码 `ELqCjojwLgTC0j5gXvJHgX`（不是 A7）。
当时脚本自判 `join unknown: no_evidence`（后置探针 bug），但实际点击已生效；A7 的加入发生在 **11-18 19:37**，是更早的一次独立操作。
因此本项目的 WA 现状是：**A7 已加入（11-18）+ RB 已加入（11-19）**，两者都无需审批。

## 待办
- `wa_verify.ps1:219` 的 `region` 赋值崩溃仍需修（它会导致 one-shot 无法记录最终状态）。
- 成员名单不采、不发消息、不拉人——本轮仍未做。