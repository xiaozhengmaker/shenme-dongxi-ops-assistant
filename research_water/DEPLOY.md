# 线索与水位 · 运营本地研究模块

这是从 `work/leads_water` 生成的部署副本，独立运行在 `127.0.0.1:8810`，不读取运营项目的 `config.json`、不写入 `data/` 之外的运营数据、不启用账号采集。

## 启动 / 停止 / 状态

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-research.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\status-research.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\stop-research.ps1
```

- 数据目录：本目录 `data/`（首次为空，不复制任何候选/演示数据）。
- 日志：`logs/server.log`、`logs/server.err.log`。
- 进程：只停 `run/server.pid` 且仍占用 8810 的 node 进程；不按进程名杀其他 node。
- 真实检索：启动脚本显式 `LEADS_WATER_SEARCH=live`，并因本机 DNS 把公网解析到 198.18/15 而启用 `LEADS_WATER_SEARCH_ALLOW_BENCHMARK=1`；该开关仍拒绝回环/RFC1918/link-local/元数据/带凭证 URL。不需要联网时用 `/api/health` 确认，不做自动抓取。默认 RSS 创作者源为 `https://sspai.com/feed`，可用 `LEADS_WATER_RSS_FEEDS` 覆盖为逗号分隔的公开 RSS/Atom 列表。

## 模型（可选）

默认不配置模型，页面会明确显示 `provider_not_configured`，不会编造 AI 结论；真实检索仍可用。已有授权的服务端密钥可复制 `.env.example` 为 `.env` 并填写，**不要**把密钥写到 `public/`、日志或浏览器请求。至少真实检索不依赖模型。

## 看板入口（部署时由主机执行）

1. 备份 `D:\DeepSeek\运营\dashboard.html` 到 `_backup\dashboard-<timestamp>.html`。
2. 在该文件顶部 `业务方向 · 水位` 链接旁加入：
   `<a class="btn" href="http://127.0.0.1:8810/" target="_blank" rel="noopener">线索与水位 · 研究</a>`
3. 只改这一处入口；不改 hub 的运行逻辑、不重启、不停止运营任务。

## 验收

- `GET /api/health` 返回 `ok=true`，`live_search.mode=live`，provider 为 `provider_not_configured`（未放 .env）。
- 打开页面，确认没有演示档案；搜索只接受用户勾选的关键词，并且结果带真实 URL/quote。
- 若 8810 无法启动：保留日志，先回滚 dashboard 备份，不删除原运营目录。

## 回滚

- 停止本模块：运行 `stop-research.ps1`。
- 恢复看板：把 `_backup\dashboard-<timestamp>.html` 复制回 `dashboard.html`。
- 本模块目录可整体删除；不删除运营原有 `data/`、`config.json`、计划任务。
