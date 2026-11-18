# WhatsApp 第三轮续：A7 复核与试加（2026-11-18）

- run_id: `wa-round3-a7-join-202611181936`
- 目标：`A7 Skins - C/V SKINS CS2 #1`（邀请指纹 `E2hUAwnmo1Z3t1Pq7tAvrv`）
- 结论：**复核通过 → 试加 1 次 → `joined_confirmed=1`**

## 1. 复核（加入前）

| 项 | 结果 |
|---|---|
| 名称是否与候选一致 | ✅ `A7 Skins - C/V SKINS CS2 #1` 未变 |
| 界面动作 | `Join group`（非 `Request to join`） |
| 审批要求 | 无需审批 |
| 关联社区提示 | `You will be added to the community "A7 Skins #1" and its announcement group` |

## 2. 试加（1 次）

- 点击 `Join group` 1 次 → 弹窗关闭（`dialogLeft=true`）
- 回读证据：
  - 聊天列表出现：`A7 Skins #1 — Welcome to the community!`
  - 群内正文：`You joined this group` / `All community members can use this chat to talk with each other`
- `joined_confirmed = 1`；`counted_as_new_group = 1`

## 3. 群级信息

| 项 | 值 | 来源 |
|---|---|---|
| 群名 | A7 Skins - C/V SKINS CS2 #1 | 群头 |
| 用途 | 饰品买卖 / 升级（从群欢迎语与官网取证） | 群简介 + 官网 |
| 创建 | 2025-03-10 | 邀请弹窗 |
| 可见成员数 | 未渲染 | 聊天视图未显示；信息面板未暴露计数 |
| 关联社区 | `A7 Skins #1` + 其 announcement group | 邀请弹窗提示 |

按口径：**社区与公告群另记，不计入新增群数**；本轮未把成员号码写入 SQLite/飞书。

## 4. 其余两个候选

| 候选 | 处理 |
|---|---|
| RB SKINS `ELqCjojwLgTC0j5gXvJHgX` | 保留为第二候选，未加入；用途标「商家报价/销售群」，等 A7 试点后再定 |
| MarkSkins `DW43Krd3RUPBV0Z3kzkITv` | **旧邀请补全**：出处 `https://markskins.com.br/redes`、审批 `Request to join`、用途 `内容通知`；跳过加入 |

## 5. 库存口径

- **42 = 累计唯一邀请指纹数**
  - 其中本轮 **2 条新增候选**（A7、RB）
  - **1 条旧记录补全**（MarkSkins）
- 本轮之前加入数 0 → 现在 **1**（A7）

## 6. 边界

- 全程无 `Request to join` 点击、无批量申请
- 操作前重读身份与按钮；名称变化/需审批/状态不明即停的守卫本次未被触发
