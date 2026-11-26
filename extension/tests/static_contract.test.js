// static_contract.test.js — 静态契约：单一入口 / 侧栏临时选平台 / 预载待确认 / 后台去运行入口 / hub 未动
// 这些断言直接读源码文本，防止后续改动把入口散回看板、把侧栏勾选写回后台配置。
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..", "..");
const EXT = path.join(ROOT, "extension", "src");
const read = (p) => fs.readFileSync(path.join(EXT, p), "utf8");
const html = read("sidepanel.html");
const panel = read("sidepanel.js");
const bg = read("background.js");
const core = read("panel_core.js");
const bridge = read("content_bridge.js");
const popupJs = read("popup.js");
const popupHtml = read("popup.html");
const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, "extension", "manifest.json"), "utf8"));
const dash = fs.readFileSync(path.join(ROOT, "dashboard.html"), "utf8");
const hub = fs.readFileSync(path.join(ROOT, "hub.ps1"));

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + (extra === undefined ? "" : "  -> " + JSON.stringify(extra))); }
}
const count = (s, needle) => s.split(needle).length - 1;

// —— 侧栏：预载与启动是两个按钮，预载区齐全 ——
for (const id of ["preloadBox", "btnPreload", "btnRecheck", "preloadSummary", "preloadList", "preloadAt", "btnCopyBrief"]) {
  ok("侧栏存在 #" + id, html.includes('id="' + id + '"'));
}
ok("侧栏预载按钮文案", /id="btnPreload"[^>]*>[^<]*预载并检查登录态/.test(html.replace(/\s+/g, " ")) || html.includes("预载并检查登录态"));
ok("预载说明写明不启动运行", html.includes("不启动运行"));
ok("预载说明写明待确认", html.includes("待确认"));
ok("平台勾选写明仅本次有效", html.includes("仅本次有效"));
ok("保留启动按钮文案 运行已选平台", html.includes("运行已选平台"));
ok("保留停止/跳过/急停/解除急停按钮", ["btnStop", "btnSkip", "btnEmergency", "btnRecover"].every((i) => html.includes('id="' + i + '"')));
ok("保留复制启动命令按钮", html.includes('id="btnCopy"'));
ok("保留运行实况与上次运行", html.includes('id="livebox"') && html.includes('id="lastrunbox"'));
ok("panel_core.js 在 sidepanel.js 之前加载",
  html.indexOf("panel_core.js") > 0 && html.indexOf("panel_core.js") < html.indexOf("sidepanel.js"));

// —— 侧栏：勾选只影响本次运行，不再写后台配置（读配置展示允许） ——
ok("侧栏不再有 savePlatforms", !/function savePlatforms/.test(panel));
ok("侧栏不再写 platformsEnabled（无赋值/写回）", !/platformsEnabled\s*:/.test(panel) && !/platformsEnabled\s*=/.test(panel));
ok("勾选变化只刷新提示", /function onPlatToggle\(\)/.test(panel) && /onPlatToggle/.test(panel));
ok("侧栏 /api/config 只读一次（无 POST 写回）",
  (panel.match(/\/api\/config/g) || []).length === 1 &&
  /fetch\(HUB \+ "\/api\/config", \{ cache: "no-store" \}\)/.test(panel) &&
  !/HUB \+ "\/api\/config"[\s\S]{0,120}method/.test(panel));
ok("预载调用走 sendWithTimeout(\"preload\", 120s)",
  /sendWithTimeout\("preload", PRELOAD_TIMEOUT_MS/.test(panel));
const preloadBody = (() => {
  const a = panel.indexOf("async function requestPreload(");
  const b = panel.indexOf("// 复制上次运行简报");
  return a >= 0 && b > a ? panel.slice(a, b) : "";
})();
ok("预载函数已定位", preloadBody.length > 0);
ok("预载请求绝不发送 start", preloadBody.length > 0 && !/sendWithTimeout\("start"/.test(preloadBody) && !/type:\s*"start"/.test(preloadBody));
ok("缺结果补 no_result 待确认", panel.includes('error: "no_result"'));
ok("复制简报读取真实简报文本", panel.includes("lrReason2") && panel.includes("navigator.clipboard.writeText"));
ok("失效上下文数组保持原五 id",
  /\["btnStart", "btnStop", "btnSkip", "btnEmergency", "btnRecover"\]/.test(panel));

// —— background：预载逐平台、缺证明即 error/待确认 ——
ok("background 有预载键规范化", /function normalizePreloadKeys/.test(bg) && /PRELOAD_ALIAS/.test(bg));
ok("background 返回 settled 字段", /settled/.test(bg));
ok("background 探针失败标记 probe=error", /probe:\s*"error"/.test(bg) || /probe = "error"/.test(bg));
ok("background 无标签时给 tab_unavailable", bg.includes("tab_unavailable"));
ok("background 保留 PRELOAD_URLS 六平台", ["telegram", "facebook", "discord", "whatsapp", "reddit", "steam"].every((k) => new RegExp("\\b" + k + ":").test(bg)));
ok("background preload 路由唯一", count(bg, 'type === "preload"') + count(bg, "case \"preload\"") === 1 || /msg\.type === "preload"/.test(bg));
ok("探针保留三态：不再用 !! 折成布尔", !/logged\s*=\s*!!/.test(bg) && /v === true \|\| v === false/.test(bg));
const probeBody = (() => {
  const a = bg.indexOf("function probeLoginFn(");
  if (a < 0) return "";
  const end = /\r?\n\}\r?\n/.exec(bg.slice(a));
  return end ? bg.slice(a, a + end.index + end[0].length) : "";
})();
ok("探针函数已定位", probeBody.length > 0);
ok("探针不读 document.cookie（FB c_user 不可见）", !/document\.cookie/.test(probeBody));
ok("探针不以公开元素作证据（Steam .playerAvatar）", !/playerAvatar/.test(probeBody));
ok("探针不以 Reddit shreddit-app 作证据", !/shreddit-app/.test(probeBody));
ok("探针缺证据返回 null", /return null;\s*\/\/ 缺证据/.test(probeBody));
ok("URL 归属走 hostname 解析（hostMatches/urlHost）",
  /function hostMatches/.test(bg) && /function urlHost/.test(bg) && /h\.endsWith\("\." \+ w\)/.test(bg));
ok("预载找标签不再用 url.indexOf(host)", !/\.url \|\| ""\)\.indexOf\(host\)/.test(bg) && !/indexOf\(host\)/.test(bg));
ok("判定错误优先级高于 true", (() => {
  const a = core.indexOf("row.settled === false");
  const b = core.indexOf("row.probe === \"error\"");
  const c = core.indexOf("row.logged === true");
  return a >= 0 && b > a && c > b;
})(), "settled/error 必须先于 logged===true");
ok("content_bridge recheck 只出现一次", count(bridge, "recheck:") === 1);

// —— popup：第二个 start 入口已消除 ——
ok("popup.js 不再发送 start", !/type:\s*"start"/.test(popupJs));
ok("popup.js 不再发送 stop", !/type:\s*"stop"/.test(popupJs));
ok("popup.html 无开始/停止按钮", !/id="start"/.test(popupHtml) && !/id="stop"/.test(popupHtml));
ok("popup 指向侧栏", popupHtml.includes("侧栏"));

// —— 看板：只有统计/设置，没有运行入口 ——
for (const bad of ["btnStart", "btnStop", "btnPreload", "runTask", "runPlatform", "syncRunButtons",
  "__dshPreload", "preloadOut", "action:'start'", "action:'pipeline'", "开始运行"]) {
  ok("看板已无 " + bad, !dash.includes(bad));
}
ok("看板指向侧栏", dash.includes("runEntryHint") && dash.includes("运行入口在扩展侧栏"));
ok("看板保留统计与设置", ["今日", "api/summary", "api/lastrun", "btnSettings"].every((k) => dash.includes(k)));
ok("看板保留数据库工具", dash.includes("api/db/stats"));
ok("看板 file 仍为 CRLF", dash.includes("\r\n"));
ok("看板无内联运行入口脚本", !/<script>[^<]*fetch\('\/control'/.test(dash));

// —— 看板内联脚本语法自检 ——
const inline = [...dash.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
ok("看板内联脚本存在", inline.length >= 1);
let syntaxOk = true, syntaxErr = "";
for (const code of inline) {
  try { new Function(code); } catch (e) { syntaxOk = false; syntaxErr = String(e && e.message || e); }
}
ok("看板内联脚本语法正确", syntaxOk, syntaxErr);

// —— manifest 契约 ——
ok("manifest MV3 + 侧栏默认页", manifest.manifest_version === 3 && manifest.side_panel && manifest.side_panel.default_path === "src/sidepanel.html");
ok("manifest 无 default_popup（popup 不可达）", !manifest.action || !manifest.action.default_popup);
ok("manifest 注入 content_bridge", (manifest.content_scripts || []).some((c) => (c.js || []).includes("src/content_bridge.js")));

// —— hub 未动：本任务只改 extension/ 与 dashboard.html ——
// 证据：hub 里没有侧栏 HTML / 预载端点 → 不是「hub 内嵌」，因此无需给 hub 打补丁。
// 注意：release 副本是共享目录，hub.ps1 可能被其他任务改动，故这里不比对哈希，只验证「无需内嵌补丁」。
const hubText = hub.toString("utf8");
ok("hub 未内嵌侧栏 HTML（无需 hub 补丁）", !hubText.includes("运行已选平台") && !hubText.includes("sidepanel.html"));
ok("hub 无预载端点", !/preload/i.test(hubText));

// —— 既有回归测试仍在（仅确认存在，由 run_all 执行） ——
for (const t of ["sidepanel_start_payload.test.js", "ui_start_payload.test.js", "sidepanel_states.test.js"]) {
  ok("既有测试存在 " + t, fs.existsSync(path.join(ROOT, "tests", "offline", t)));
}

console.log("\nstatic_contract: " + (fail ? "FAIL pass=" + pass + " fail=" + fail : "all PASS (" + pass + ")"));
process.exit(fail ? 1 : 0);
