# 线索与水位 v1（本地候选，已部署运营研究模块）

> 运营部署：`http://127.0.0.1:8810/`，目录 `D:\DeepSeek\运营\research_water`，独立启停脚本 `start-research.ps1` / `stop-research.ps1`；未配置模型时页面显示 `provider_not_configured`，真实公开检索仍可用。

默认是**一句话关键词工作台**：打开首页，用一句话写“业务 + 关键问题”，系统拆解并推断人群，首次或人群变化时确认理解摘要，然后直接看关键词、意图、人群、来源类型、独立有效线索和盲区；点击关键词看引用/URL，并能反向回词。不需要先建档案、填人群、锁定或导入证据。勾选关键词后可**显式触发真实公开检索**（Hacker News 评论、Stack Exchange、可选 RSS）；只有原文逐字可核对才标 verified。没有证据就保留待搜词并说明零线索；导出只是给原拓群模块复核的 CSV 交接清单，不执行任务、不启动加群/采集。旧问题直达、快速研究与完整四步流程都收在“高级研究”里。零依赖 Node.js 24，本地 JSON 存储，默认只监听 `127.0.0.1`。

## 快速预览

```powershell
cd work\leads_water
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-preview.ps1 -Fixture -Port 8802
```

打开 `http://127.0.0.1:8802/`。`-Fixture` 使用确定性的离线 provider，页面会明确标“fixture 演示、非真实模型”；它不访问外网、不需要密钥。默认 8799 的旧进程可继续运行，新版本用独立端口，不覆盖也不杀死旧进程。

```powershell
# 不使用 -Fixture 时，读取服务端环境变量
$env:LEADS_WATER_PROVIDER = "deepseek"
$env:LEADS_WATER_API_KEY  = "<server-side-key>"
$env:LEADS_WATER_BASE_URL = "https://api.deepseek.com"
$env:LEADS_WATER_MODEL    = "deepseek-chat"
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-preview.ps1
```

密钥只留在服务端进程；浏览器不会收到 key。未配置密钥时，校准接口返回 `provider_not_configured`，不会生成假结果。

## 测试

```powershell
cd work\leads_water
node --test
```

测试使用临时数据目录和本机回环端口，默认不访问真实模型或外部来源（检索用注入 fetch 的确定性 fixture）。当前 **50/50 通过**（6 问题直达、6 快速研究、7 关键词工作台、12 真实检索与安全，含 Atom `<entry>` 解析）；沙箱下 `node --test` 的 runner 子进程可能被拒绝，逐文件执行等价：`Get-ChildItem tests -Filter '*.test.js' | % { node $_.FullName }`。

## 关键词工作台（默认）

- `POST /api/studio/understand`：`{ sentence, profile_id? }`；一句话必填。自动拆业务/问题、匹配已锁定档案或让 provider 草拟理解摘要；返回 `confirmation.required`（首次或人群签名变化）。
- `POST /api/studio/keywords`：`{ understanding, user_confirmed? }`；确认后生成工作台。按 `intent × audience` 聚合线索，关键词带来源类型、来源、独立有效线索数、证据引用。
- `GET /api/studio/demo`：独立合成 demo，全量标“演示证据/AI候选”，可验证有证据路径；不当真。
- `POST /api/studio/export`：只返回 CSV 交接清单，`executed=false, production_connected=false`；不写文件、不触发任务/加群/采集。
- 来源类型：只有 `verified===true && retrieval==='live'` 才标“经真实检索且有证据”；用户导入/原话标“用户原话”，不冒充已验证；其余 AI候选。
- UI：工作台表格可勾选关键词；点击关键词显示 URL/逐字 quote/来源类型/演示标记与反向回词；工作台顶部 KPI、盲区和“未执行自动搜索”说明。

## 显式真实检索（可选）

- `POST /api/studio/search`：`{ keywords: string[] }`，只在用户勾选后调用；最多 8 个词，自动广搜不会自行启动。
- 渠道：Hacker News 评论（公开 Algolia API）、Stack Exchange（公开 API）、可选公开 RSS/Atom。Reddit 当前 403，不接入；Bing 条款禁止复用；Google News 只适合发现，不作为证据。
- 只有原文（评论/问答/RSS 正文）中逐字出现 quote 才 `verified=true`；标题、摘要、搜索结果片段都不算证据。
- 渠道状态区分 `ready` / `failed` / `cooldown` / `unconfigured`；429、5xx、网络错误进入冷却，安全拒绝（本机/私网/元数据/带凭证 URL）不会污染冷却。
- 预算默认 8 请求、20 结果、20 秒；支持取消；结果只是预览，不写正式档案、不执行加群/采集。
- 本机 DNS 若把公网解析到 198.18.0.0/15，需显式 `LEADS_WATER_SEARCH_ALLOW_BENCHMARK=1` 才可检索（仍拒绝 127/10/172.16/192.168/169.254/元数据）；生产默认关闭。其他可调：`LEADS_WATER_SEARCH=live|off`、`LEADS_WATER_RSS_FEEDS`、`LEADS_WATER_SEARCH_MAX_REQUESTS`、`LEADS_WATER_SEARCH_MAX_RESULTS`、`LEADS_WATER_SEARCH_TIMEOUT_MS`、`LEADS_WATER_SEARCH_COOLDOWN_MIN`。

## 问题直达

- `POST /api/answer`：`{ question, profile_id? }`；`question` 唯一必填。
- 不选档案：不复用任何已有证据；只给条件判断、推断、未知与验证方向。
- 选档案：仅限已锁定且已确认的档案；只引用本档案与问题相关的证据，引用可回到原文核对；不修改档案/校准。
- 回答明确分区：证据结论、推断、未知、条件判断、验证方向；最多一个可选追问（不会自动重发）。
- `fixture` 始终标“演示非真实”；真实 provider 缺 key/失败返回明确错误，不生成假结果。
- `GET /api/research/profiles` 只列出可被问答复用的已锁定且有证据档案。

## 快速研究（高级研究默认）

- `POST /api/research/draft`：`{ question, background? }`；问题唯一必填，背景可选；缺关键上下文时最多一个 `context_gap`，可直接按假设继续。
- `POST /api/research/confirm`：保存用户确认/修改后的“研究谁”、标准、渠道、关键词；返回研究简报。确认不会锁定正式研究，不创建正式档案，不覆盖既有档案标准。
- `GET /api/research/briefs` / `GET /api/research/briefs/:id`：读取与正式 profiles 隔离的研究简报。
- 简报直接展示：可用线索（本版不自动搜索，零证据就是零）、关键词、渠道、覆盖盲区、限制。
- `fixture` 草稿与简报都显著标注演示；无自动搜索，不把草稿当证据。
- 旧完整表单收在“手动填写完整研究档案（可选）”，正式档案/校准/证据/报告接口保留。

## 行为边界

- **正式证据仍以手工导入为主**：自动广搜未接入；`/api/capabilities` 返回 `auto_search=false, manual_import=true, live_search=true`。关键词工作台的显式检索只产生预览，不自动写入正式证据；问题直达也不会伪造自动搜索。
- **引导可选字段**：搜索范围（`search_scope`）与已有证据（`existing_evidence`）可留空；前三项引导、产品名/研究问题与至少一个人群仍必填。
- **门禁**：校准未确认锁定时，导入正式证据和生成报告均返回 409；锁前允许导入最多 8 条有出处、可核对引用、带理由与人群的校准样本（`/calibration-samples`）。校准样本不是正式证据。
- **校准锁定**：确认时校验版本；锁定后条目与校准样本均不可新增/修改。
- **引用可核对**：`quote` 必须逐字出现在原文中；否则 `quote_not_found`。
- **去重**：canonical URL、正文 SHA256、标题 + Jaccard 近似转载；重复写入 `duplicate_log`，不计入证据数。
- **水位**：独立来源按域名；渠道覆盖、盲区、重复拒绝、地域/语言未知；不输出市场份额/实际触达。
- **数据**：默认写入本目录 `data/`；可用 `LEADS_WATER_DATA` 或 `--data` 改变。删除该目录即重置本地数据。
- **无鉴权**：只用于本机；不要暴露到公网。

## 目录

- `server.js`：HTTP API + 静态 UI
- `lib/studio.js`：一句话拆解/理解摘要、关键词工作台、来源类型、去重、盲区、交接 CSV
- `lib/search.js`：显式公开检索（HN 评论 / StackExchange / RSS）、预算、冷却、取消、引用校验
- `lib/safe_http.js`：外部 URL/私网/DNS/重定向/大小/超时安全
- `lib/robots.js`：robots.txt 允许/拒绝缓存
- `lib/answer.js`：问题直达、证据筛选/引用、回答归一化
- `lib/research.js`：快速研究草稿/确认、简报隔离
- `lib/pipeline.js`：门禁、校准、证据、报告
- `lib/provider.js`：fixture / OpenAI-compatible 服务端适配（校准 + 问答 + 研究草稿）
- `lib/store.js`：JSON 档案持久化
- `public/`：默认关键词工作台 + 高级研究（问题直达/快速研究/完整四步流程）
- `fixtures/`：CS2 与 B2B 合成档案；demo 工作台独立合成样例
- `tests/`：API、校准样本、问题直达、快速研究、关键词工作台、provider 与回归测试

## 已知未验证

- 真实模型只完成 1 次 `answerQuestion` 小额冒烟（2026-11-20 17:54，3859ms、合法 JSON、0 条无证据引用）；未做多轮/工具调用/并发。部署 8810 仍不读取现有密钥，保持 `provider_not_configured`。
- 真实 HN 评论 + StackExchange 已验证；RSS 已在部署 8810 启用公开 `https://sspai.com/feed`，并用关键词“游戏”验证 1 条中文创作者结果；跨境支付垂直/中文创作者专用源仍未验证；Reddit 403、Bing 条款禁止、Google News 仅发现。
- 真实 Chrome 桌面版已验证关键词工作台 demo、一句话/零证据、选词导出、真实检索 10 条 verified；其他浏览器、移动端和大量关键词性能未验证。
- 真实加群/拓群/采集、多进程并发写入、鉴权、配额和跨主机部署未验证；本机运营研究模块已获批准部署并运行。
