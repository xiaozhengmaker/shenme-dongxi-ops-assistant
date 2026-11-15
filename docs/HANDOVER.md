# 交接说明 · 社么东西（GroupOps）

- **版本日期**：2026-11-15
- **运行机**：Windows 11 / PowerShell 5.1 / Chrome 157（CDP 9222）
- **本版提交**：见文末 `git log`

## 1. 这套东西现在是什么状态

| 项 | 当前值 |
|---|---|
| 飞书群组（已加入） | **221 群 / 1,420 万人** |
| ├ Facebook | 32 群 / 111.3w |
| ├ Telegram | 77 群 / 54.3w |
| ├ Discord（只统计） | 78 服 / 343.9w |
| ├ Reddit（板块订阅） | 27 个 / 291.8w |
| ├ Steam | 18 群 / 654.0w |
| └ WhatsApp | 8 群 / 6.2w |
| 成员样本 | 68,248 行（Steam 为主） |
| 本地 SQLite | 554,407 行 / 107 群 / 约 122 MB |
| 计划任务 | Daily 10:00、Steam 09:30、Report 21:00、Hub 登录时、HubWatch 每 5 分钟 |

## 2. 三分钟跑起来（新机器）

```powershell
cd <项目目录>
powershell -File .\install.ps1              # 建配置/目录/库/计划任务（首次会生成 config.json，需填飞书凭据）
powershell -File .\start_chrome.ps1         # 起调试 Chrome，手动登录 FB / TG / Reddit
schtasks /Run /TN "DSH_SocialOps_Hub"         # 起本地后台（必须用计划任务，别用 Start-Process）
powershell -File .\check.ps1                # 8 项自检，末行「== 可以开工 ==」
```

日常：点看板「开始运行」= 拓群 → 成员采样 → 人数回填 → Steam 抽样 → 入库 → 日报。

## 3. 本版改了什么

1. **hub 全后台运行**：`run_hub.ps1` 的子进程改为 `Start-Process -WindowStyle Hidden`，不再弹终端窗口。
2. **看门狗**：新增 `hub_watch.ps1` + 计划任务 `DSH_SocialOps_HubWatch`（每 5 分钟探 `/health`，挂了自动 `Start-ScheduledTask` 拉起）；`install.ps1` 支持 `minute` 类型并注册它。
3. **预载面板增加「本地后台」一行**：直接探 `127.0.0.1:8787/health`，显示「已连接 / 未启动 + phase」，点「重新检测」会一起重探。
4. 上一版：日报跑完自动发（`-NoReport` 可关）+ 计划任务加固（`StartWhenAvailable`、去电池限制）；81 行缺失「加入日期」回填。

## 4. 目录与关键文件

```
hub.ps1                  本地服务（状态机 / 飞书写入 / DB / 事件流 / 看板 API）
run_hub.ps1              计划任务入口（拉起 hub，全隐藏）
hub_watch.ps1            看门狗（5 分钟探活）
run_all.ps1              一键全流程（默认跑完发日报）
steam_daily.ps1          Steam 每日：发现 → 加群 → 覆盖 → 采样 → 入库
tg_members_all.ps1       TG 全量成员采样      tg_fix_counts.ps1  人数回填
rd_run.ps1               Reddit 订阅 + 采发帖者
wa_discover.ps1 / wa_verify.ps1 / wa_report.ps1   WhatsApp 种子→验证→报表
discord_daily.ps1        Discord 覆盖率快照（成员读取已关闭）
dashboard.html / users.html / wa.html             三个看板
extension/               MV3 插件（sidepanel + background + content_bridge）
lib/feishu.ps1  lib/db.ps1  lib/stop.ps1  lib/paths.ps1
db_tool.py               SQLite init/import/bulk/stats
check.ps1 / doctor.ps1 / install.ps1 / scripts/lint.ps1
```

## 5. 必须知道的坑（都踩过）

1. **hub 只能用计划任务起**：`Start-Process` 起的会被父进程回收；且 `Get-NetTCPConnection 8787` 拿到的是 pid 4（http.sys），要用 `Win32_Process | ? CommandLine -match hub.ps1`。
2. **改 `config.json` 后必须重启 hub**（配置读进内存）。
3. **含中文的 .ps1 必须 UTF-8 带 BOM**，否则 PS 5.1 按 ANSI 读会报语法错。
4. **`pwsh -Command` 传中文会变 `?`**，脚本上报一律 ASCII。
5. **飞书改单选 options 会清空历史值**；改完必须按 `群组唯一键` 回填。datetime 列要 **epoch 毫秒**。
6. **批量删记录** `records` 要纯字符串数组 `@{records=@("reczz...")}`。
7. **WhatsApp 判定**要 `Page.bringToFront`（后台标签页被节流）+ 两层 `ConvertFrom-Json`。
8. **Steam 429** 按出口 IP 限流；靠自适应退避 + 元数据缓存 + 互斥锁。
9. 平台边界：FB 拿不到全量成员；Discord 无 token 只做覆盖；WA 搜索被遮蔽，只能靠种子。

## 6. 已知遗留

- 看板「今日」按自然日，跨零点跑完会显示 +0（建议改成「最近一次运行」）。
- 运行时副本与仓库副本存在漂移（仓库是可迁移版，本地仍硬编码 9222/绝对路径）。
- `stop.flag` 只覆盖 hub + 4 个长任务，短任务（steam_join、rd_run）未接。
- 日报可能重复（run_all 自动发 + 21:00 兜底），用户已同意保留兜底。

## 7. 数据在哪

- 飞书多维表格：群组主表（21 列）—— 唯一权威名单
- `data/groupops.db`：成员样本权威库（55 万行）
- `data/users.csv` / `users.jsonl`：网页视图 / 历史累积
- `data/wa_candidates.json|csv`：WhatsApp 候选池
- `logs/*.log`：每日运行与告警

## 8. 版本记录

- `7e3fafe` 看门狗 + install 注册
- `0526d75` 项目复盘（给外部审查）
- `fe74dbb` 日报跑完自动发 + 任务加固
- `30a8c2a` 侧边栏平台列表修复
- `1b22e84` 全局停止 + 运行中按钮置灰 + 官方 logo
- `eb66fcf` Discord 关闭成员读取 + run_all 参数拆分
