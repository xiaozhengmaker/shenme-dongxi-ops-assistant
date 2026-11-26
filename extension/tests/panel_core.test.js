// panel_core.test.js — 纯逻辑行为测试（无 DOM / 无 chrome / 无临时业务数据）
// 覆盖：平台名→预载键、去重与预留平台、登录态三态判定（不能把不确定说成确定）、预载摘要。
"use strict";
const path = require("path");
const Core = require(path.resolve(__dirname, "..", "src", "panel_core.js"));

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + (extra === undefined ? "" : "  -> " + JSON.stringify(extra))); }
}
function eq(name, got, want) { ok(name, JSON.stringify(got) === JSON.stringify(want), got); }

// 1. 平台名 / 缩写 → 键
eq("key: 显示名大小写与空格", Core.keyFor(" Telegram "), "telegram");
eq("key: 缩写 tg", Core.keyFor("tg"), "telegram");
eq("key: 缩写 FB", Core.keyFor("FB"), "facebook");
eq("key: 预留下平台无键", Core.keyFor("Instagram"), null);
eq("key: 空值", Core.keyFor(null), null);
eq("key: 未知名", Core.keyFor("weibo"), null);

// 2. 去重保序 + 不支持列表
eq("keys: 去重保序", Core.keysFromNames(["Telegram", "tg", "Steam", "steam", ""]), ["telegram", "steam"]);
eq("keys: 未知被跳过", Core.keysFromNames(["Instagram", "Facebook"]), ["facebook"]);
eq("keys: 空数组", Core.keysFromNames(null), []);
eq("unsupported: 只列无键的", Core.unsupportedNames(["Telegram", "Instagram", "Weibo"]), ["Instagram", "Weibo"]);

// 3. 登录态判定矩阵：确定才给确定结论，其余一律「待确认」
const V = (row) => Core.verdictOf(row);
eq("verdict: logged=true → 已登录", V({ key: "telegram", logged: true, probe: "ok", settled: true }).code, "logged_in");
eq("verdict: 探针成功 + 已加载 + false → 未登录", V({ key: "steam", logged: false, probe: "ok", settled: true }).code, "logged_out");
eq("verdict: 探针报错 → 待确认", V({ key: "reddit", logged: false, probe: "error", error: "No tab" }).code, "unknown");
eq("verdict: 探针报错标签", V({ key: "reddit", probe: "error" }).label, "待确认");
eq("verdict: 页面未加载完 → 待确认", V({ key: "discord", logged: false, probe: "ok", settled: false }).code, "unknown");
eq("verdict: 未加载完优先于 true → 待确认", V({ key: "telegram", logged: true, probe: "ok", settled: false }).code, "unknown");
eq("verdict: 探针报错优先于 true → 待确认", V({ key: "telegram", logged: true, probe: "error" }).code, "unknown");
eq("verdict: probe=ok 但 logged=null → 待确认", V({ key: "facebook", logged: null, probe: "ok", settled: true }).code, "unknown");
eq("verdict: logged=false 但没有 probe 证据 → 待确认", V({ key: "steam", logged: false, settled: true }).code, "unknown");
eq("verdict: 只有 error 字段 → 待确认", V({ key: "whatsapp", error: "tab_unavailable" }).code, "unknown");
eq("verdict: 完全没有结果 → 待确认", V({ key: "telegram" }).code, "unknown");
eq("verdict: null → 待确认", V(null).code, "unknown");
ok("verdict: 只有确定未登录才显示未登录",
  Core.preloadSummary([{ logged: false }, { logged: false, probe: "error" }]).loggedOut === 0,
  Core.preloadSummary([{ logged: false }, { logged: false, probe: "error" }]));

// 4. rowView 展示字段
const rv = Core.rowView({ key: "telegram", logged: true, probe: "ok", settled: true, opened: true, url: "https://web.telegram.org/k/" });
eq("rowView: 名称", rv.name, "Telegram");
eq("rowView: 新开标签文案", rv.openText, "新开标签");
eq("rowView: 已存在文案", Core.rowView({ key: "steam", opened: false }).openText, "已存在");
eq("rowView: 未知键名回退", Core.rowView({ key: "x", error: "e" }).name, "x");

// 5. 摘要
const sum = Core.preloadSummary([
  { key: "telegram", logged: true, probe: "ok", settled: true },
  { key: "steam", logged: false, probe: "ok", settled: true },
  { key: "reddit", probe: "error", error: "boom" },
  { key: "discord" }
]);
eq("summary: 计数", [sum.loggedIn, sum.loggedOut, sum.pending, sum.total], [1, 1, 2, 4]);
eq("summary: 文案", sum.text, "1 已登录 · 2 待确认 · 1 未登录");

// 6. 预载请求载荷
eq("request: 键化 + recheck", Core.preloadRequest(["Telegram", "Steam"], true),
  { type: "preload", platforms: ["telegram", "steam"], recheck: true });
eq("request: recheck 缺省为 false", Core.preloadRequest(["tg"], undefined).recheck, false);
eq("request: 只勾预留平台 → 空 platforms", Core.preloadRequest(["Instagram"], false).platforms, []);

console.log("\npanel_core: " + (fail ? "FAIL pass=" + pass + " fail=" + fail : "all PASS (" + pass + ")"));
process.exit(fail ? 1 : 0);
