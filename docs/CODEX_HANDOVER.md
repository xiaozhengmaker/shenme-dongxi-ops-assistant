# 社么东西 · 社群线索系统 — 技术交接书

> 面向：第一次接触本仓库的工程师 / AI 审查者（Codex）
> 目标：看完能跑起来、能改、不踩已知的雷。

---

## 1. 定位

**本地优先**的海外社媒运营工具：用你自己浏览器的登录态，找 CS2 饰品/开箱相关的人群，
把群、人、线索沉淀到飞书多维表格 + 本地 SQLite，并每天自动跑一轮。

不是 SaaS，不是爬虫集群：**单机 + 你自己的账号 + 你本地 Chrome**。

---

## 2. 运行环境（硬约束）

| 项 | 要求 | 原因 |
|---|---|---|
| 系统 | Windows 10/11 | `schtasks`、路径规则 |
| PowerShell | **5.1**（非 7） | 脚本按 5.1 行为写 |
| Chrome | 独立 profile + `--remote-debugging-port=9222` | 所有网页操作走 CDP |
| Python | 3.x | `db_tool.py`（SQLite/JSON） |
| Node | 仅用于 `node --check`（可选） | 无运行时依赖 |

---

## 3. 架构

```
Chrome 扩展(MV3, sidepanel+background)
        │  HTTP 轮询 (127.0.0.1:8787)
        ▼
     hub.ps1  ── 状态机/配额/飞书读写/静态页/数据库
        │
        ├── 真实网页（web.telegram.org / facebook.com / old.reddit.com / steamcommunity.com）
        ├── 飞书多维表格（群清单 21 列）
        ├── SQLite data/groupops.db（users / leads）
        └── 网页看板（dashboard/users/leads/settings/profile/wa/discord）
```

设计取舍：
- 桥接用 **HTTP 轮询**，不用 WebSocket（MV3 service worker 会休眠，WS 必断）。
- 长任务（抓取/采样）是**独立 powershell 进程**；hub 只派活 + 收事件。
  因此「停止」必须靠 `data/stop.flag` 才能真停。
- 中文只写在文件里；`pwsh -Command` 传中文会变 `??`。

---

## 4. 核心文件职责

| 文件 | 职责 | 雷区 |
|---|---|---|
| `hub.ps1` | 唯一后端（约 2000 行）：38 个端点、状态机、飞书、SQLite、静态页 | 路由必须 `continue`，`return` 会退出监听循环 |
| `extension/src/background.js` | 平台适配器（TG/FB/DC/WA/RD）、注入、登录探针 | 改后需重载扩展 |
| `extension/src/sidepanel.js` | 侧边栏 UI | `CTX_ALIVE` 必须是函数，不能是常量 |
| `run_all.ps1` | 每日编排 | 每步检查 `stop.flag` |
| `steam_full.ps1` | Steam 成员抓取（XML 分页→SQLite） | 429 限流：退避 + 缓存 + 进程锁 |
| `leads_scan.ps1` | Reddit 旧版搜索抓信号 | **不含任何关键词**，全读 `config.profile` |
| `leads_score.ps1` | LLM 线索打分 | UTF-8 解码坑 |
| `leads_daily.ps1` | 扫描→打分→入库 | 认 `stop.flag` |
| `lib/profile.ps1` | 业务描述 → 平台检索包 | 意图正则「原料」在此，不许写死 |
| `lib/ai.ps1` | OpenAI 兼容客户端 | 必须自行 UTF-8 解码 |
| `lib/feishu.ps1` | 飞书 API | `batch_delete` 要纯字符串数组 |
| `db_tool.py` | SQLite CLI：init/import/bulk/leads/stats | 幂等 upsert |
| `check.ps1` | eight 项自检 | 红灯阻止 `run_all` |
| `hub_watch.ps1` | hub 看门狗（5 分钟） | 计划任务 |

---

## 5. 数据模型

### 飞书（群清单，21 列）
`群组唯一键/平台/群ID/群名/群链接/成员数/上次成员数/成员数变化/语言/群类型/状态/加入日期/潜水到期/日发帖量/采集来源/采集日/最后核验/失效原因/是否收费发帖/负责人/备注`

- `群ID` 必须 **Text**（Discord/Steam ID 超 2^53）
- 日期列是 datetime，实际存 **epoch 毫秒**
- 改单选 options 会重造 option id 并**清空既有值**

### SQLite `data/groupops.db`
- `users(platform, group_id, group_name, user_id, username, nickname, role, lang, last_active, collected_at, source, status)`，PK `(platform, group_id, user_id)`
- `leads(url PK, platform, sub, keyword, title, author, comments, time_text, intent_rule, ai_intent, ai_is_lead, ai_relevance, ai_reason, scanned_at, scored_at)`

### JSON 中间态
`data/pool_<平台>.json`、`data/leads_signals.json`、`data/leads_scored.json`、`data/steam_meta.json`、`data/stop.flag`、`data/skip.json`

---

## 6. 接口（按用途）

- 状态/控制：`/health` `/state` `/control`(`start|stop|pipeline|steam|wa`) `/api/live` `/api/event`
- 配置：`/api/config`(含 `ai` 掩码) `/api/strategy` `/api/tasks`
- 数据：`/api/summary` `/api/users` `/api/users/export` `/api/candidates` `/api/leads` `/api/leads/scored` `/api/water` `/api/wa` `/api/db/stats`
- 画像/AI：`/api/profile` `/api/profile/analyze` `/api/profile/generate` `/api/ai/test`
- 页面：`/` `/users` `/leads` `/settings` `/profile` `/wa` `/discord`

---

## 7. 每日时序

```
10:00 DSH_SocialOps_Daily (run_all.ps1)
      ├ check.ps1（红灯 exit 3）
      ├ Telegram / Facebook 拓群、Reddit 订阅
      ├ tg_members_all → tg_fix_counts
      ├ steam_sample_all → steam_to_users → db import
      ├ report_all（飞书卡片）
      └ leads_daily（扫描 → AI 打分 → leads 入库）
21:00 DSH_SocialOps_Report  （兜底日报）
 9:30 DSH_SocialOps_Steam   （Steam：加群→覆盖→成员）
每5分 DSH_SocialOps_HubWatch
登录  DSH_SocialOps_Hub
```

---

## 8. 当前数据快照（2026-11-17）

| 项 | 数值 |
|---|---|
| 飞书群清单 | 226 群 / 13,823,951 人 |
| users | 约 8 万行 / 90+ 群 |
| leads | 93 行（AI 判线索 36） |
| SQLite | 约 125 MB |

平台：Steam 654w / Discord 343.9w / Reddit 219.6w / Facebook 111.3w / Telegram 54.3w。

---

## 9. 已知坑（改代码前必读）

1. 含中文的 `.ps1` 必须 **UTF-8 with BOM**，否则 PS5.1 按 ANSI 读会乱码甚至语法错。
2. `pwsh -Command` 传中文 → `??`；需要传 JSON 用 `UTF8.GetBytes` + `charset=utf-8`。
3. `Invoke-RestMethod` 不按 charset 解码 → 用 `Invoke-WebRequest` + `RawContentStream` + `UTF8.GetString`。
4. `hub.ps1` 路由必须 `continue`。
5. `$root` 会被 `lib/feishu.ps1` 的 `$script:Root` 污染（变量名不分大小写）→ 用 `$baseDir`。
6. `Start-Process` 起 hub 会被父进程/工具回收 → 只能由计划任务起。
7. `Get-NetTCPConnection` 的 OwningProcess 是 4（http.sys）→ 用 `Win32_Process | ? CommandLine -match hub\.ps1`。
8. 扩展改完必须重载；`chrome.runtime.reload()` 在孤儿侧边栏会报错 → 重启 Chrome。
9. 飞书 `batch_delete` 要 `@{records=@("recyyy")}`。
10. Steam XML 429 按出口 IP 计 → 退避 + `steam_meta.json` 缓存 + `data/steam.lock` 互斥。
11. Reddit `search.json` 已 403（匿名/登录都 403）→ 只能解析 `old.reddit.com` 搜索页。
12. `r/csgotrade` 是私密板块 → 生成器排除；扫描命中 private 直接 SKIP。

---

## 10. 技术债（建议优先）

| ID | 问题 | 影响 | 建议 |
|---|---|---|---|
| T1 | `hub.ps1` 约 2000 行单体 | 难测难改 | 拆 `lib/http.ps1` + `lib/state.ps1` |
| T2 | 目录下约 20 个 `_*.ps1` 调试脚本 | 噪音 | 移到 `tools/dev/` 或删除 |
| T3 | 状态只在内存 `$state` | 重启即丢 | 落盘 `data/state.json` |
| T4 | 无自动化测试 | 回归风险 | Pester 覆盖生成器/过滤器/URL 构造 |
| T5 | 平台适配器挤在 `background.js` | 加平台难 | 拆 `platforms/<name>.js` + 注册表 |
| T6 | 线索无跟进状态机 | 线索无人跟进 | `status` + `/api/leads/action` |
| T7 | Reddit 依赖 DOM | 改版即崩 | 选择器版本化 + 失败告警 |
| T8 | 飞书与 SQLite 双写无事务 | 不一致 | 以 SQLite 为准 |
| T9 | 「今日」按自然日 | 跨夜错位 | 改「上次运行至今」或可配 |
| T10 | 日志轮转不统一 | 磁盘 | 统一走 `lib/log.ps1` |

---

## 11. 红线

- 🔴 `config.json` 不入 git（含 secret / webhook / api_key）；仓库只放 `config.example.json`
- 🔴 `.ps1` 落盘必须 UTF-8 BOM
- 🔴 hub 路由用 `continue`
- 🔴 抓取脚本不许写死业务关键词/意图正则（来自 `config.profile`）
- 🔴 外部脚本上报事件用 ASCII
- 🔴 不自动点审批类「Request to join」（除非 `allow_approval_request=true`）
- 🔴 不绕过 `stop.flag`

---

## 12. 验收命令

```powershell
cd D:\DeepSeek\运营
powershell -File check.ps1                  # 末行应为「== 可以开工 ==」
powershell -File scripts\lint.ps1           # 语法/JSON/链接
node --check extension\src\background.js
powershell -File leads_scan.ps1 -PerQuery 20
powershell -File leads_daily.ps1 -SkipScan
Get-Content logs\hub.out.log -Tail 20
```

冒烟：`/health` `/api/summary` `/api/config` `/api/leads` 均 200 且有数据。

---

## 13. 建议先做的 5 件事

1. 拆 `hub.ps1`：先抽 `lib/http.ps1`（请求/响应/路由表）与 `lib/state.ps1`（含落盘），行为不变。
2. 加 Pester：`lib/profile.ps1` 生成器、`leads_scan` 过滤正则、`Get-ProfileUrl`、`Build-JoinQueue`。
3. 线索状态机：`leads.status/note/updated_at` + `POST /api/leads/action` + 页面按钮。
4. 清 T2/T3：删调试脚本、状态落盘。
5. 适配器拆分：`extension/src/platforms/*.js` + `registerPlatform()`。

---

## 14. 附件

- `docs/schema.sql`：SQLite 结构
- `config.example.json`：脱敏配置样例
- `CODEX_PROMPT.md`：给审查者的任务提示词
