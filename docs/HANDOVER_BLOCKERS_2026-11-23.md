# 交接：卡点与未解决事项（2026-11-23）

> 目的：给 Codex 一份可执行的现状与验收清单。
> 代码位置：运行时 `D:\DeepSeek\运营`，仓库 `D:\DeepSeek\shenmedongxi`（`main`，最新 `c91e56e`）。
> 数据快照：飞书表 **323 群 / 28,570,224 人**；样本 `users.csv` 381,138 行；本地库 `groupops.db` 890,100 行 / 148 群 / 324.74 MB。

---

## 一、为什么一直在「反复修」（根因，不是抱怨，是结构问题）

| # | 根因 | 具体表现 |
|---|---|---|
| 1 | **单文件巨石**：`hub.ps1` 已 22.6 万字节、6.1 万行（一半是空行），无模块边界、无单元测试 | 任何改动都是「外科手术」，只能靠锚点正则替换 + `Parser::ParseFile` 兜底；改一处常连带另一处 |
| 2 | **外部页面状态持续漂移**：FB/TG/WA 都是 SPA，会自行导航、后台标签页被节流、渲染未完成 | 探针出现**假红/假绿**（FB `ERR: recv timeout`、TG `bodyLen=0`），每次都像新 bug，其实是同一类 |
| 3 | **先补症状再定位**：多个补丁在没量清根因前就上了 | 引入 4 个我自己造成的回归（见下表「自造回归」），每一个都要再修一次 |
| 4 | **缺少真实环境的自动回归**：离线测试只覆盖纯函数，DOM/登录态/限流都靠人工验 | 回归只能在下一次真实运行时暴露，表现为「又坏了」 |

### 已发生的自造回归（都已修，但说明风险）

| 回归 | 症状 | 根因 |
|---|---|---|
| `Sync-StaleRunState` 无条件复位 | 点「开始运行」6 秒后自己变回 idle | 只比对磁盘 `pipeline_status.json`，没比对「本轮开始时间」 |
| `Write-RunSummary` 找不到 | 跑完报「无法将 Write-RunSummary 项识别为 cmdlet」 | `lib\run_summary.ps1` 只在 `/api/lastrun` handler 内 dot-source |
| `hub.ps1` 行数翻倍 | 文件从 11 万涨到 22 万字节 | PS 的 `.Split("`r`n")` 按**字符**切分，写回时每轮加空行 |
| 新 lib 无 BOM | `ParserError: 缺少终止符` / 112 个 parse 错误 | PS 5.1 按 ANSI 读 UTF-8 中文注释 |

**结论**：要真正止血，必须（a）拆分 `hub.ps1`，（b）把「健康探测」做成带自愈的组件，（c）把 DOM 相关验收放进可重复的离线夹具。这不是再加两个 if 能解决的。

---

## 二、当前卡点（P0 = 挡住产出）

### P0-1 FB 加群仍未打通（最大缺口）

- **现象**：`pageFBJoinDirect` 一律返回 `not_found / no_target_header`；FB 每天配额 10 群，实际加入 0。
- **根因（已定位）**：
  1. 群页链接用**数字 ID**（`facebook.com/groups/445326196498552`），hub 传的是 slug（`chomuabanvncs2csgo`）→ 函数第 70 行 `tbForeign` 判为「异群」直接 `return null`。
  2. 表头「加入小组」按钮**不在标题块祖先内**（在兄弟动作行，第 8 层），而 `headerFor` 只向上找 6 层，且第 44 行 `break` 早于第 46 行 `first = el`。
- **证据**：`docs` 内克隆验收脚本 `tools/smoke_fb_firstjoin.ps1`，返回 `{"ok":true,"v":"not_found","e":"no_target_header"}`、`clicks=0`。
- **验收标准**：用同一公开目标（`chomuabanvncs2csgo`）在隔离克隆里得到 `clicks=1`、`recs` 中点击元素 `headerScoped=true`、邻卡 0 点击；真实运行时 `joined` 计数 +1 且飞书新增一行。

### P0-2 `joined` 计数已改口径但**缺正样本验证**

- **现状**：已改为「浏览器真实加入即记 `added`」（不再取决于飞书是新建还是更新），代码在 `Write-JoinRecord`。
- **缺口**：最近三轮 `joined` 都是 0（队列空/被中止），**没有一次真实加入来证明计数正确**。
- **验收标准**：跑一轮真实加入 ≥1 群，`/api/live.joined ≥ 1`、`run_summary.counts.joined ≥ 1`、飞书对应行 `状态=已加入`。

### P0-3 自检红灯会静默挡掉整轮，且**不留总结**

- **现象**：`18:51` 那轮因 `check.ps1` 红灯中止，`pipeline_status.last_error=check_failed`，但 `data\run_summary.json` **仍是 17:22 的旧记录** → 看板显示的是上一轮信息。
- **根因**：`run_all.ps1` 在 `check.ps1` 失败时直接 `exit`，没走 `Write-RunSummary`。
- **验收标准**：自检失败也要写 summary（`code=check_failed`），看板「上次运行」立刻反映；红灯项文本要出现在 summary.reason 里。

### P0-4 健康探测假红灯（今天已手工救两次）

- **现象**：`[!!] FB login 未登录 / 无标签页：ERR: recv timeout`；`[!!] TG session dead/no-root`。
- **根因**：CDP 探测 5 秒超时 + 后台标签页节流 + 页面渲染未完成；不是真掉登录。
- **已做**：`sample_telegram.ps1` 有 `Repair-TgPage`（空响应自动 reload 一次）。
- **验收标准**：`check.ps1` 对这两个平台自带一次「reload + 重探」，仍失败才判红；连续 3 次红灯才告警。

---

## 三、次要卡点（P1）

| # | 问题 | 位置 | 验收标准 |
|---|---|---|---|
| P1-1 | 长尾词仍会拖慢搜索（已做命中率排序 + 24h 停用，但**未跑过一轮验证**） | `lib\kw_stats.ps1` / `hub.ps1` 搜索段 | 一轮跑完后 `data\kw_stats.json` 有每词 rounds/hits；连续 3 次 0 的词出现在 `off_until` |
| P1-2 | 8 连 0 保护仍会在「已知好词连续 0」时中止（设计如此，但阈值未经校准） | `hub.ps1` `zeroStreak` | 校准依据：正常搜索的 0 命中率基线；建议改为「按 source 分别计数」 |
| P1-3 | Steam 429 限流导致 28 群采不完 | `sample_steam.ps1` / `config.memberSample.steam=5` | 连续 3 轮 429 后自动降速（页间隔翻倍），而不是直接 `rate_limited` 退出 |
| P1-4 | `hub.ps1` 双倍空行（22.6 万字节，一半空行） | `hub.ps1` | 规范化（用 `.Split("`n")` + `TrimEnd("`r")`），并把 30 个函数拆到 `lib\` 子模块 |
| P1-5 | `hub.out.log` GBK 乱码 + `Write ... 指定的网络名不再可用` 噪声 | `hub.ps1` 写响应处 | 写响应包 `try/catch` 静默；日志统一 UTF-8 |
| P1-6 | 仓库 `scripts\lint.ps1` 的 Python 段仍 `SKIP`（本机已找到内置 python 3.12.14） | `scripts\lint.ps1` | 复用 `lib\db.ps1` 的 `Get-DbPython` 探测顺序 |
| P1-7 | `phase` 会残留 `pipeline`（18:51 中止后 `/health` 显示 `phase=pipeline` 而 `running=false`） | `Sync-StaleRunState` | 中止路径也要把 phase 归位 |

---

## 四、背景信息（Codex 需要知道的边界）

| 平台 | 能力边界 | 备注 |
|---|---|---|
| Telegram | 可全量搜群 + MTProto `channels.joinChannel` 加入 + 成员采样 | 会吃 `FLOOD_WAIT`（见过 67,649 秒）；标签页易挂死 |
| Facebook | 可搜公开群、可读「新加入+管理员」 | **成员全量不存在**；加群按钮定位未通（P0-1） |
| Steam | `memberslistxml` 全量成员 | 429 按出口 IP 限流 |
| Discord | 只读覆盖（78 服 / 343.9 万），token 拿不到 | 不做成员读取（已定论） |
| Reddit | `old.reddit` multireddit 搜索 + `api/subscribe` | `search.json` 403 |
| WhatsApp | 只能种子邀请码；无群搜索 | RB、A7 已加入；无更多候选 |

---

## 五、建议给 Codex 的开工顺序

1. **P0-3 + P0-4**（1 天）：让「一轮为什么失败」永远可见、假红灯能自愈 —— 这是所有后续调试的前提。
2. **P0-1**（2 天）：FB 加群打通，含离线夹具（数字 ID / slug / 动作行 8 层 三个用例）。
3. **P0-2**（0.5 天）：跑一轮真实加入，验证 joined 计数与飞书写入一致。
4. **P1-1 + P1-2**（1 天）：跑一轮并把 `kw_stats.json` 数据回填，校准 8 连 0 阈值。
5. **P1-4**（1.5 天）：`hub.ps1` 拆分 + 空行规范化（改动大，放最后，避免与上面冲突）。

---

## 六、常用验收命令

```powershell
# 自检（9 项）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\DeepSeek\运营\check.ps1

# 语法
$e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile("D:\DeepSeek\运营\hub.ps1",[ref]$null,[ref]$e); $e.Count

# 仓库 lint + 离线测试
powershell -File D:\DeepSeek\shenmedongxi\scripts\lint.ps1
powershell -File D:\DeepSeek\shenmedongxi\tests\offline\run_offline.ps1

# 状态与事件
curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/api/live
type D:\DeepSeek\运营\data\run_summary.json
```
