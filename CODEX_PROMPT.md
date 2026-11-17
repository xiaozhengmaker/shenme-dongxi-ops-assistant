# 给 Codex 的任务提示词（可直接粘贴）

你是资深 Windows/PowerShell + 前端工程师。下面这套工具**已经能跑**，我要你**审查并改进**它，不是重写。

## 你会拿到

- `dist/groupops_codex_20261117.zip`：全部源码（已剔除 `config.json` / `data/` / `logs/` / `dist/`）
- `docs/CODEX_HANDOVER.md`：架构、文件职责、数据模型、接口、**踩坑清单**、技术债 T1–T10
- `docs/schema.sql`：SQLite 表结构
- `config.example.json`：脱敏配置样例

## 运行环境（不可改变）

- Windows 10/11 + **PowerShell 5.1**（不是 7）
- Chrome + `--remote-debugging-port=9222`，扩展为 MV3
- Python 3 可用；**不要引入 Node 运行时依赖**
- 后端是单文件 `hub.ps1`（HttpListener，127.0.0.1:8787）

## 硬约束（违反会直接跑挂）

1. 含中文的 `.ps1` 必须存成 **UTF-8 with BOM**
2. `hub.ps1` 的路由分支必须 `continue`，不能 `return`
3. **不要**在抓取脚本里写死业务关键词或意图正则 —— 必须来自 `config.profile`
4. `config.json` 不入库；代码里不得硬编码任何 secret
5. 外部进程上报事件用 ASCII（`POST /api/event`）
6. 不破坏 `data/stop.flag` 的全局停止语义
7. 改完自检：`.ps1` 用 `[System.Management.Automation.Language.Parser]::ParseFile`；JS 用 `node --check`

## 产出（按优先级）

**P0 · 拆分与可测（行为不变）**
- 从 `hub.ps1` 抽出 `lib/http.ps1`（请求解析 / JSON 响应 / 路由注册）与 `lib/state.ps1`（状态 + `data/state.json` 落盘）
- 所有端点路径与响应字段**保持不变**
- 用 `check.ps1` 与 `/health /api/summary /api/config /api/leads` 回归

**P1 · 测试**
- Pester 测试（`tests/*.Tests.ps1`），至少覆盖：`lib/profile.ps1` 生成器、`leads_scan` 过滤正则、`Get-ProfileUrl`、`Build-JoinQueue` 剔除逻辑

**P2 · 线索闭环**
- `leads` 表加 `status(new|contacted|replied|ignored)` / `note` / `updated_at`
- 新端点 `POST /api/leads/action {url,status,note}`
- `/leads` 每行加「已联系/已回复/忽略」按钮 + 状态筛选

**P3 · 清理**
- 运行目录里约 20 个 `_*.ps1` 调试脚本：确认无引用后移除或移入 `tools/dev/`
- 日志统一走 `lib/log.ps1`（8MB 轮转）

## 交付格式

1. `CHANGES.md`：逐条列出改了什么、为什么、风险
2. 可直接覆盖的文件（保持相对路径）
3. 「如何验证」：命令 + 预期输出
4. 若交接书与代码不符，单列一节指出

## 不要做

- 不换技术栈（不要把后端改成 Node/Python 服务）
- 不动 `background.js` 的平台业务逻辑（除非修 bug）
- 不引入需要联网安装的依赖
- 不「顺手重构」未被要求的部分

## 背景数字（自检用）

- 飞书群清单 226 群 / 13,823,951 人
- SQLite `users` 约 8 万行；`leads` 93 行（AI 判线索 36）
- 定时：`run_all.ps1` 10:00、`DSH_SocialOps_Report` 21:00、`DSH_SocialOps_Steam` 9:30
