# 社群运营助手（GroupOps）现状与下一步 —— 交给 Codex 的完整简报

> 生成时间：2026-11-18 16:10（Asia/Shanghai）
> 项目根：`D:\DeepSeek\运营`（可迁移副本：`D:\DeepSeek\shenmedongxi`，GitHub `xiaozhengmaker/shenme-dongxi-ops-assistant`）
> 本文只描述**当前真实状态与实测数字**，不含猜测。凡写「未验证」的，就是真的没验证过。

---

## 0. 一句话目标

在**不触发风控**的前提下，每天为 CS2 第三方开箱站（SkinVS）稳定获取**经核验的新群 + 新用户样本 + 可跟进线索**，并把结果落到飞书多维表格与本地 SQLite，全程可在看板/侧边栏观测。

今天的实际产出（11/18）：TG 115 群、FB 36 群、Discord 78、Reddit 33、Steam 27、WhatsApp 7（合计 **296 群**）；用户样本 **90,240 行**；DB **560,757 行 / 123 群**。

---

## 1. 已经跑通的能力（有数字的才算）

| 能力 | 状态 | 实测证据 |
|---|---|---|
| Telegram 站内搜索 + 加群 | ✅ | 今日 `joined=5`（本轮），单群间隔 30–90s，无 FLOOD_WAIT |
| TG 池化（候选池优先） | ✅ | 池 57 条 → 可用 12 条 → 队列来源=候选池 |
| TG 分批挖链 | ✅ | 120 群 → 10,032 条消息 → 654 唯一链接 → 43 候选 → 入池 29 |
| FB `/groups/discover/` 发现 | ✅ | 44 张未加入卡片 → 过滤后 13 → 入池 13 → 成功加入 2（14 万/15 万人群） |
| FB 关键词搜索 | ⚠️ 修好但饱和 | `cs2 trocas raw=13 / cs2 takas raw=10`，但 `new=0`（66% 是已加入） |
| Steam 加群 | ✅ 9/10 | 10 个候选 → 9 个 `joined`（1 个偶发 `not_joined`） |
| Steam 成员全量 | ✅ | 532,198 人 / 20 群（唯一可全量的平台） |
| Reddit 订阅板块 | ✅ | 33 板块已订阅，客观供给约 18 |
| WhatsApp 加群/采集 | ⛔ 停用 | 40 条链接筛选：`joinable=3 / approval=1 / no-dialog=4 / loading=32` |
| AI 扩词（写入 strategy） | ✅ | TG 90 / FB 16 / RD 65 / Steam 54 词 |
| AI 线索打分 | ✅ | 93 signals → top40 打分 → **36 条判为线索**，¥0.005/轮 |
| 离线评分引擎 | ✅ | 110 群 / 3,309 用户 / 5 话题 / 82 条 recommendations（Pester 21 + pytest 14 全绿） |

---

## 2. 数据现状（可直接对账）

### 2.1 飞书多维表格（唯一对外真源）

| 平台 | 群数 | 备注 |
|---|---|---|
| Telegram | 115 | 今日新增主要来自池 |
| Facebook | 36 | 今日 +2（discover 页） |
| Discord | 78 | 只统计，不加群不读成员 |
| Reddit | 33 | 订阅制，非加群 |
| Steam | 27 | 今日 +9 |
| WhatsApp | 7 | 停用中 |
| **合计** | **296** | |

### 2.2 本地池与水位（`/api/water`）

```
Telegram  level=12  raw=57  safe=210  days=0.4  红
Facebook  level=13  raw=13  safe=140  days=1.3  红
WhatsApp  已停用
```

- `level` = **可用**候选（过了相关性 + 跳过名单 + 未过期），`level_raw` = 池内条数
- `safe` = 日配额 × 目标覆盖天数（TG 30×7 / FB 10×14）
- 红色含义：**补给速度 < 消耗速度**

### 2.3 源账本 `data/source_ledger.jsonl`（37 行）

字段：`ts / platform / source_id / query / raw / eligible / joined / pending / small / offtopic / dup / priv / excluded / cost_ms / reason`

两段对照（同一批关键词，池移开纯搜索）：

| | 门槛 100（16 次查询） | 门槛 30（21 次查询） |
|---|---|---|
| raw | 126 | 148 |
| **eligible** | **2** | **9** |
| small | 56（44%） | 52（35%） |
| dup | 56 | 74 |
| 每次 eligible | 0.13 | **0.43** |

### 2.4 本地 SQLite `data/groupops.db`（254.21 MB）

```
users 560,757 行 / 123 群
  Steam     532,198 / 20
  Telegram   28,247 / 58
  Facebook      213 / 16
  Reddit         99 / 29
groups 110 · user_entities 505,005 · memberships 557,251 · evidence 93
entity_scores: 3,309 users / 110 groups / 5 topics
recommendations: 82 pending
```

### 2.5 用户样本 `data/users.csv`

90,240 行；Excel 打开无乱码（UTF-8 BOM）；`语言` 列已从 API 剔除，`最近活跃` 空值统一 `-`。

---

## 3. 关键机制（Codex 改之前必须知道）

1. **源账本优先**：任何「搜索→候选」的改动，必须先看 `source_ledger.jsonl` 里该 query 的 `eligible`，不能凭感觉砍词或加词。
2. **可用口径同源**：`Get-PoolDepth` 与 `Build-JoinQueue` 必须调用同一个 `Test-PoolItemEligible`，否则水位与队列会互相打架（已经踩过）。
3. **两段式门槛**：`strategy.<平台>.filters.min_members`（TG 现 90）+ `filters.min_floor`（30），运行时 `minNow = max(floor, min_members/3)`，两轮放宽都读 `floor`。
4. **活跃闸门**：加入前在扩展内 `messages.getHistory(limit:1)`，`last < now - recent_activity_days(5)` → 返回 `stale`，**不发加群请求**。
5. **入口二选一**：`POST /control {action:"start"}` 走「搜索→加群」；`{action:"joinnow"}` 清空查询直接花池；`{action:"start", poolOnly:true}` 是旧方案（会被探针覆盖 phase，已不推荐）。
6. **队列归一化**：池对象是 `t/n/h/k`，搜索结果对象是 `title/u/h/k`，出队前统一成 `id/u/title/n/q/h/k/src`，否则日志与飞书群名为空。
7. **长任务必须认 `data/stop.flag`**（`lib/stop.ps1` 的 `Test-GOpsStop $baseDir`）。
8. **hub 单线程**：任何同步网络调用（飞书 API）都会堵 `/task`，必须走 60s 缓存 `Get-FsCached`。
9. **hub 只能由计划任务起**（`schtasks /Run /TN DSH_SocialOps_Hub`），从工具里 spawn 会被回收。

---

## 4. 已证伪 / 平台硬边界（不要再提这些方案）

| 假设 | 结论 | 证据 |
|---|---|---|
| FB 可拿全量成员 | ❌ 数据源层面不存在 | 成员页只给「新加入 + 管理员」，1,366 人与 23,289 人的群都一样 |
| FB 群页有「相关群组」可一跳扩展 | ❌ 当前桌面版没有该区块 | `/groups/1816425519337533` 全页无 `相关群组/Related groups`，27 个链接全是本群成员与导航 |
| WhatsApp 可按关键词搜群 | ❌ 无搜索 | 只有 `chat.whatsapp.com/<code>` 或 `web.whatsapp.com/accept?code=` |
| 搜索引擎能挖 WA 邀请码 | ❌ 被遮蔽 | Bing 2,570 条结果链接被 `/ck/a?u=` 包裹且正文显示 `______`；DDG 返回 202 挑战页 |
| Reddit 是「加群」 | ❌ 订阅制 | `/api/subscribe` 订阅板块，不产生群 |
| Steam 可无限速抓成员 | ❌ 429 限流 | 按出口 IP + 时间窗口，突发后第 3 页起 429 |

---

## 5. 待解问题（按证据强度排序）

### P1 · 挖链产量是第一瓶颈
`654 唯一链接 → 43 候选 → 过滤后 12 可用`，漏斗后两段各掉 90% 与 72%。
已知原因：`MinMembers=300` 直接砍掉大量小群；每群只取 120 条消息（只覆盖最近几十小时）；`resolveUsername` 对改名群失败。
**判别方法**：跑一轮 `MinMembers=150`，对比 `eligible/群` 与 `cost_ms`；再看账本里 `reason=small` 的分布。

### P2 · 补给速度 < 消耗速度
TG 水位 0.4 天、FB 1.3 天，都是红。日配额 30/10 是「想加多少」，池子决定「能加多少」。
**判别方法**：连续 3 天记录 `pool_in / pool_out`，算日净增。

### P3 · FB 关键词入口饱和
4 个关键词 → `unique=29 / joined=19 / eligible=0`，66% 是已加入。`/groups/discover/` 一次给 44 张卡，滚动是否还能加载未验证。
**判别方法**：discover 页滚 10/20/30 次，记录卡片增量曲线，判断上限。

### P4 · WhatsApp 断供
没有可信链接池；搜索引擎全遮蔽；目录站（disboard/top.gg）403，linkado 143 群里真 CS2 极少。
**判别方法**：需要新的信号源假设，而不是继续在旧源上加参数。

### P5 · 账本样本不足以做词级决策
37 行、新门槛只有 21 行，单 query 样本 1–3 次，噪声大。
**判别方法**：同一 query 至少 5 次再排序；用 `eligible/次` 与 `cost_ms` 双指标。

### P6 · `stale` 闸门未跑出真实样本
定向塞入 4 年不活跃的 `CS2Market` 仍未派发到（池里 57 条排序后取 1 条落到别的群），`stale=null`。
闸门逻辑本身在页面内单点验证过（`cs2_search_people` 9.9 天 → `stale=true`），但**hub 派发链路没有端到端证据**。

### P7 · FB 加入后的成员价值无法评估
FB 拿不到成员明细，只能靠「帖子作者 + 评论者 + 成员重合」间接判断。当前 `demand_density` 对 FB 恒为 `None`，FB 群最高只能到 C 级。

### P8 · Steam 429 共享冷却未实现
`steam_full.ps1` 有自己的 429 退避，但 `steam_discover.ps1` 与成员抽样各算各的额度，会互相抢。

### P9 · 指标口径容易自我欺骗
`small`（人数不够）与 `dup`（已收录）混在 `eligible=0` 里，看起来像「市场没货」，其实可能是「搜索太窄」。

---

## 6. 希望你（Codex）输出什么

对**每一个**被采纳的问题，按以下格式给：

1. **根因与判别方法**（先用什么数据证明它是这个原因，不能直接假设）
2. **A/B 方案与取舍**（至少两个，写清代价：请求数 / 风控面 / 代码量 / 可回滚性）
3. **落点**：文件 + 函数名（例如 `hub.ps1` 的 `Build-JoinQueue`、`extension/src/background.js` 的 `pageJoin`）
4. **观测指标与验收阈值**（必须能写进 `source_ledger.jsonl` 或 `/api/live`，且可被我在 24h 内验证）
5. **工作量估计**（小时）

并按「**24 小时内能验证 / 一周内 / 需要重构**」三档排序；明确哪些不做、为什么。

### 红线（违反即方案作废）

- 不引入付费 API、代理池、多账号、外部常驻服务
- 不提交任何 `Request to join` 审批申请
- 不写死业务词（CS2 / 开箱 / 任何语言的具体词），必须由业务画像生成
- 不改数据模型而不给迁移 + 回滚（现有用户 90,240 行、DB 560,757 行）
- 新增行为必须 `config.json` 可开关，且能在 `/api/live` 观测
- 不假设 FB 能拿到全量成员 / 相关群组，不假设 WA 能按关键词搜群

---

## 7. 附录

### 7.1 关键文件

| 文件 | 作用 | 关键函数 |
|---|---|---|
| `hub.ps1` | 调度中枢（约 2,000 行） | `Build-JoinQueue` / `Get-PoolDepth` / `Test-PoolItemEligible` / `Add-SourceLedger` / `Get-Summary` / `Get-FsCached` / `Start-Run` |
| `extension/src/background.js` | 平台适配器 | `pageJoin`（含 stale 闸门）/ `pageFBJoin` / `pageFBExtract` / `handlePreload` |
| `tg_discover_links.ps1` | TG 分批挖链 | `dialogs / harvest / resolve / write` 四阶段 |
| `fb_discover.ps1` | FB discover 页发现 | walk-up 卡片识别 + `$rxRel/$rxDrop` |
| `leads_scan.ps1` / `leads_score.ps1` / `leads_daily.ps1` | 线索三件套 | 只读 profile（无写死词） |
| `lib/profile.ps1` | 业务画像 → 检索包 | `New-GOpsProfilePack` / `Get-QuerySeeds` |
| `score_engine.py` | 离线评分 | `score_user/score_group/score_topic` / `tier` / `priority_of` |
| `db_tool.py` | SQLite 迁移与查询 | `migrate / score / recommend / entities / decide` |
| `config.json` | 全部开关 | `filters.min_floor` / `strategy.*.filters` / `pool.watermark` |

### 7.2 指标定义

- **eligible**：过了平台相关性正则 + 跳过名单 + 人数门槛 + 未过期，可进加群队列
- **small**：人数低于 `minNow`
- **dup**：已在飞书表或已加入
- **水位天数** = `level / 日配额`
- **覆盖率质量**：Steam 18/18、Discord 78/78、Reddit 33 板块（客观供给 18）

### 7.3 常用命令

```powershell
# 健康/水位/账本
Invoke-RestMethod http://127.0.0.1:8787/health
Invoke-RestMethod http://127.0.0.1:8787/api/water
Get-Content data\source_ledger.jsonl -Tail 5

# 花掉池里的库存（不搜索）
Invoke-RestMethod http://127.0.0.1:8787/control -Method Post `
  -Body ([Text.Encoding]::UTF8.GetBytes('{"action":"joinnow","platform":"Telegram"}')) `
  -ContentType "application/json; charset=utf-8"

# 挖链（分批、可断点）
powershell -File tg_discover_links.ps1 -MaxGroups 120 -PerGroup 120 -ResolveCap 90 -MinMembers 150

# FB 发现页
powershell -File fb_discover.ps1 -MinMembers 300 -MaxTake 40

# 全量流水线（含日报）
powershell -File run_all.ps1 -Platforms Telegram,Facebook,Reddit
```

### 7.4 当前进行中的验证

- `stale` 闸门端到端（未完成，见 P6）
- 账本积累（37 行，目标 100+ 行后做词级排序）
- Steam 429 冷却窗口（上次触发后未再全量抓取）
