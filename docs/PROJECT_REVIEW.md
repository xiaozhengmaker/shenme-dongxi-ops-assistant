# 社么东西 · 社群运营助手 —— 完整项目复盘（交付 Codex 审查）

生成时间：2026-11-15　运行环境：Windows 11 / PowerShell 5.1 / Chrome 157（CDP 9222）

## 0. 一句话

本地优先的海外社群运营工具：用**你自己浏览器的登录态**，在 Facebook / Telegram / Reddit / Discord / Steam 上找群、加群、统计覆盖人数、采集成员样本，落库到**飞书多维表格 + 本地 SQLite**，配一个侧边栏插件和三个网页看板。

## 1. 目标与平台边界（实测结论）

- 目标：为 CS2 皮肤交易站（SkinVS）在海外社媒找到垂类人群，沉淀成可运营名单。
- 只做「加群 + 统计 + 采样」，不做批量加好友、不群发、不发入群审批申请。
- 各平台能拿到什么：
  - **Steam**：唯一能拿全量成员（`memberslistxml` 每页 1000 个 SteamID64），但受限流约束。
  - **Telegram**：`channels.getParticipants` 可分页全量；群主可关闭成员可见；广播频道只能拿人数。
  - **Facebook**：成员页**只给「新加入」和「管理员」**，全量在数据源层面不存在（1,366 人与 23,289 人的群都验证过）。
  - **Discord**：只做覆盖率快照（成员数/在线数）；成员读取需 token，已按用户决定永久关闭。
  - **Reddit**：是「板块」不是群，只能订阅 + 采发帖者。
  - **WhatsApp**：没有公开搜索，只能靠种子邀请链接；Bing/DDG 对 `chat.whatsapp.com` 全部遮蔽，实测挖不到码。
  - **Instagram**：网页端反自动化最严，已放弃。

## 2. 架构

```
Chrome (--remote-debugging-port=9222, profile=D:\ChromeFeishu\profile)
  ├─ 扩展 groupops (MV3: sidepanel + background + content_bridge)
  │     └─ 直接操作 web.telegram.org / facebook.com / reddit / steam 页面
  └─ 普通标签页：三个看板 + 各平台站点

hub.ps1 (PowerShell HttpListener, 127.0.0.1:8787)
  ├─ 状态机 phase/running/queue + /api/live 事件流 + data/stop.flag
  ├─ 飞书多维表格读写 (lib/feishu.ps1)
  ├─ 本地 SQLite (db_tool.py + lib/db.ps1)
  └─ 派活 /control {action: start|stop|pipeline|steam|wa}

脚本层（可单独跑，也被 run_all 串起来）
  run_all.ps1 → 拓群 → 成员采样 → 人数回填 → Steam 抽样 → 入库 → 日报
```

## 3. 关键文件

| 文件 | 作用 |
|---|---|
| `hub.ps1` | 本地服务：状态机、飞书/DB 读写、派活、事件流、看板 API |
| `dashboard.html` | 总览看板：平台卡、7 天曲线、待办、最近加入、本地数据库卡 |
| `users.html + src_users.js` | 成员样本页：平台分布、筛选、导出 CSV、主页链接 |
| `wa.html` | WhatsApp 候选池页 |
| `extension/` | MV3 扩展：sidepanel（开始/停止/状态灯/实况）、background（调度/探针）、content_bridge |
| `lib/feishu.ps1` | 飞书多维表格 API 封装（增删改查 + 字段映射 + 分页） |
| `lib/db.ps1 + db_tool.py` | SQLite：init/import/bulk/stats/vacuum，幂等 upsert |
| `lib/paths.ps1` | （仓库版）路径解析：chrome/profile/port 可配置 |
| `lib/stop.ps1` | 全局停止：data/stop.flag |
| `run_all.ps1` | 一键全流程（默认跑完发日报，-NoReport 跳过） |
| `run_daily.ps1 / run.ps1` | 每日任务入口 / 单平台运行器 |
| `steam_full.ps1 / steam_daily.ps1` | Steam 全量抓取 / 每日流程（发现→加群→覆盖→采样→入库） |
| `tg_members_all.ps1 / tg_fix_counts.ps1` | TG 成员全量采样 / 人数回填与修正 |
| `rd_run.ps1` | Reddit：发现板块 → 订阅 → 采发帖者 |
| `wa_discover.ps1 / wa_verify.ps1 / wa_report.ps1` | WhatsApp：种子/搜索 → 验证 → 报表 |
| `discord_daily.ps1` | Discord：覆盖率快照（CS 服），成员读取关闭 |
| `check.ps1 / doctor.ps1 / install.ps1` | 自检（8 项）/ 环境诊断 / 新机器安装 |
| `scripts/lint.ps1 + .github/workflows/lint.yml` | CI：ps1 语法、JSON、Python、Markdown 链接 |

## 4. 数据模型

### 4.1 飞书多维表格（群组主表，21 列）

`群组唯一键, 平台, 群ID, 群名, 群链接, 成员数, 上次成员数, 成员数变化, 语言, 群类型, 状态, 加入日期, 潜水到期, 日发帖量, 采集来源, 采集日, 最后核验, 失效原因, 是否收费发帖, 负责人, 备注`

- 状态值：`已加入 / 待审核 / 已退出 / 已失效 / 待确认`
- 日期列是飞书 datetime，写入必须 **epoch 毫秒**；读出来是 Int64。
- 去重键 `群组唯一键`：`FB-xxx` / `TG-slug` / `DC-<id>` / `RD-<sub>` / `ST-<slug>`。
- 坑：改单选字段 options 会**重造 option id 并清空历史值**（踩过两次），只能「改完立刻按唯一键回填」。

### 4.2 本地 SQLite（`data/groupops.db`）

```sql
users(platform, group_id, group_name, user_id, username, nickname, role, lang, last_active, collected_at, source, status)
PRIMARY KEY (platform, group_id, user_id)
```

- 幂等 upsert（`ON CONFLICT DO UPDATE`），`bulk` 每批 5000。
- 当前：约 **55 万行 / 107 群 / 4 平台 / 122 MB**。
- `data/users.csv` 是网页读的视图；`users.jsonl` 是历史累积；SQLite 是权威库。

### 4.3 当前体量（2026-11-15 01:40 实测）

| 指标 | 数值 |
|---|---|
| 飞书群组（已加入） | 229 群 / 13,830,779 人 |
| ├ Facebook | 32 群 / 1,112,525 人 |
| ├ Discord | 78 群 / 3,439,281 人 |
| ├ Steam | 18 群 / 6,539,529 人 |
| ├ Telegram | 77 群 / 543,188 人 |
| ├ Reddit | 24 群 / 2,196,256 人 |
| 成员样本 | 68,248 行 |
| 本地 DB | 554,407 行 / 107 群 / 122.5 MB |

## 5. 运行方式

```powershell
powershell -File D:\DeepSeek\运营\start_chrome.ps1        # 起 CDP Chrome
schtasks /Run /TN "DSH_SocialOps_Hub"                       # 起 hub（Start-Process 会被回收）
powershell -File D:\DeepSeek\运营\check.ps1                # 8 项自检，末行「可以开工」

powershell -File D:\DeepSeek\运营\run_all.ps1 -Platforms Telegram,Facebook,Reddit
powershell -File D:\DeepSeek\运营\steam_daily.ps1 -MaxPages 40 -DelayMs 12000
```

- 看板：`http://127.0.0.1:8787/`（总览）、`/users`（成员样本）、`/wa`（WhatsApp 候选）。
- 计划任务：`DSH_SocialOps_Daily` 10:00、`DSH_SocialOps_Report` 21:00（兜底）、`DSH_SocialOps_Steam` 09:30、`DSH_SocialOps_Hub` 登录时。
- 全局停止：`data/stop.flag`；hub 收到 `stop` 时写，收到 `start/pipeline` 时清。

## 6. 已修掉的真 bug

| 现象 | 根因 | 修法 |
|---|---|---|
| 脚本报 `Missing '=' operator` / 中文乱码 | PS 5.1 按 ANSI 读无 BOM 的 UTF-8 | 含中文的 .ps1 一律 `UTF8Encoding($true)` 落盘 |
| `$root` 被覆盖成 API 地址 | `lib/feishu.ps1` 的 `$script:Root` 同名（PS 变量不区分大小写） | 改用 `$baseDir` |
| hub 所有接口 502 | 路由里用了 `return`，退出 HttpListener 循环 | 一律 `continue` |
| 改 config.json 不生效 | hub 启动时读进内存 | 重启 hub（按 pid 杀，排除 `$PID`） |
| 扩展注入 `must request permission` | 标签页在权限变更前已打开 | 捕获错误 → reload tab → 重试 |
| FB 加群 `not_found` | 点击时标签页停在别的关键词结果页 | 候选带来源关键词，先导航再点 |
| TG 六个群显示 0 人 | `contacts.resolveUsername` 的 Chat 没有 `participants_count` | 用 `getFullChannel/getFullChat` 的 `full_chat.participants_count` |
| 广播频道采样抛 `CHAT_ADMIN_REQUIRED` | 频道不允许列成员 | 返回 `{hidden:true,total:n}` 不报错 |
| WhatsApp 全判 `no-dialog` | CDP 两层 JSON，只 parse 外层 | `$raw|ConvertFrom-Json` 再 `.result.value|ConvertFrom-Json` |
| WhatsApp 弹窗一直不出现 | 后台标签页被节流，同步遮罩不消失 | `Page.bringToFront` 后再探测 |
| 飞书批量删除失败 | `records` 必须纯字符串数组 | `@{records=@("reczz...")}` |
| run_all 启动平台 400 | `-File` 把 `A,B,C` 当单个字符串 | `$Platforms -split ","` |
| hub 起不来/起来就死 | `Start-Process` 子进程被工具 job 回收 | 用 `schtasks /Run` |
| 8787 的 pid 是 4 | HttpListener 走 http.sys | 用 `Win32_Process` 匹配 `hub.ps1` |
| Python 写 ps1 后静默失败 | 非 raw 字符串里 `\r` 变回车 | 多行字符串或整段替换 |
| `$cfg.platforms` 取不到平台名 | 是 `Object[]` 不是对象 | `@($cfg.platforms | % { [string]$_ })` |
| 侧边栏「本次运行平台」点开是空 | `CTX_ALIVE` 是常量，reload 后恒 false | 改 `ctxAlive()` + 列表无条件渲染 |
| 日报没发 | 任务 21:00 启动失败(0x800710E0)，run_all 默认不发 | 任务加 StartWhenAvailable/去电池限制；run_all 默认发 |
| 81 行没有「加入日期」 | 早期导入路径没写该字段 | 按采集日回填 81 行；hub 新增写 now |

## 7. 已知遗留与风险（重点）

1. **时间口径**：看板「今日」是自然日；跨零点跑完时卡片显示「今日 +0」，易误读。建议改成「最近一次运行」。
2. **日报可能重复**：run_all 默认发 + 21:00 兜底，晚跑会发两次（用户已同意保留兜底）。
3. **Steam 429**：XML 端点按出口 IP 限流；`archiasf` 一群 11,820 页 / 539 万人，全量要分多天。策略：自适应退避 + 元数据缓存 + 互斥锁。
4. **WhatsApp 无发现渠道**：搜索引擎遮蔽，TG 21,000 条消息里 0 个邀请码；只能等用户给种子池。
5. **Discord 成员读取已关闭**（用户决定），只有覆盖率。
6. **Facebook 全量成员不可得**，只能「新加入 + 管理员 + 互动者」三路采样；当前 FB 样本仅 213 人。
7. **运行时与仓库副本漂移 9 个文件**：仓库版是「可迁移版」（`lib/paths.ps1`），本地运行版仍硬编码 9222/绝对路径，合并需回归测试。
8. **`stop.flag` 覆盖不全**：hub 与 4 个长任务检查；`steam_join`、`rd_run` 等短任务未接。
9. **飞书单选 options 陷阱**：任何改选项的脚本都可能清空历史值，需要「改完即回填」的固定流程。
10. **公网仓库历史**：`a892c60`/`4caccde` 仍可按 SHA 访问，内部文件已从 HEAD 移除；用户明确不删库。

## 8. 给 Codex 的审查建议

- 优先看 `hub.ps1`（50 KB：路由 + 状态机 + 飞书写入）与 `run_all.ps1`（编排与门禁）。
- 重点：错误处理是否吞异常（大量 `try {} catch {}`）、幂等性（飞书去重键 + SQLite upsert）、并发（同一时间只允许一个平台）、限流退避是否会无限重试。
- 检查 `lib/feishu.ps1` 的分页与字段类型（datetime 毫秒、单选项 option id）。
- 检查扩展 `background.js` 调度与 `sidepanel.js` 上下文守卫。
- 安全：`config.json` 含飞书 `app_secret` 与 webhook，已在 `.gitignore`；确认日志里没有打印。

## 9. 复现与验收

```powershell
powershell -File D:\DeepSeek\运营\check.ps1                     # 期望末行「== 可以开工 ==」
powershell -File D:\DeepSeek\shenmedongxi\scripts\lint.ps1       # 期望 RESULT: OK
node --check D:\DeepSeek\运营\extension\src\background.js        # exit 0
(Invoke-RestMethod http://127.0.0.1:8787/health)                 # phase/running/ok
(Invoke-RestMethod 'http://127.0.0.1:8787/api/db/stats')         # rows/groups
```
