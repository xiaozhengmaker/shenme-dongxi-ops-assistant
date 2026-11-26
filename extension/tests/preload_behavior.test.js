// preload_behavior.test.js — 用真实 sidepanel.js 源码跑「预载」行为（假 DOM + 假扩展消息）
// 关键验收：预载只开网页/验登录态，不发 start；缺结果/超时/探针失败一律「待确认」。
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SRC = path.resolve(__dirname, "..", "src");
const panelJs = fs.readFileSync(path.join(SRC, "sidepanel.js"), "utf8");
const coreJs = fs.readFileSync(path.join(SRC, "panel_core.js"), "utf8");

// —— 精确切片：只取预载相关的真实函数（不执行 init / 定时器 / chrome 调用） ——
const A = panelJs.indexOf("function preloadEsc(s) {");
const B = panelJs.indexOf("// 复制上次运行简报");
if (A < 0 || B < 0 || B <= A) { console.error("SLICE MISS: 预载段标记未找到 A=" + A + " B=" + B); process.exit(1); }
const slice = panelJs.slice(A, B);

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + (extra === undefined ? "" : "  -> " + JSON.stringify(extra))); }
}

function makeEl(id) {
  return { id: id, innerHTML: "", textContent: "", className: "", disabled: false, value: "", style: {},
    appendChild() {}, removeChild() {}, select() {}, click() {} };
}
const els = {};
const doc = {
  _els: els,
  getElementById(id) { if (!els[id]) els[id] = makeEl(id); return els[id]; },
  createElement(tag) { return makeEl(tag); },
  body: { appendChild() {}, removeChild() {} },
  execCommand() { return true; }
};

const state = { selected: [], feedback: [], sent: [], reply: null, during: null };
const ctx = {
  console: console,
  Date: Date, Math: Math, JSON: JSON, String: String, Array: Array, Object: Object,
  setTimeout: setTimeout, clearTimeout: clearTimeout,
  document: doc,
  PRELOAD_TIMEOUT_MS: 120000,
  PRELOAD_LAST_AT: 0,
  RUN_BUSY: false,
  selectedPlatforms() { return state.selected.slice(); },
  showFeedback(msg, kind) { state.feedback.push({ msg: String(msg), kind: kind || "" }); },
  friendlyError(r) { return (r && r.error) || "未知错误"; },
  hhmmss() { return "12:00:00"; },
  async sendWithTimeout(type, ms, extra) {
    state.sent.push({ type: type, ms: ms, extra: extra });
    state.during = { disabled: els.btnPreload ? els.btnPreload.disabled : null, text: els.btnPreload ? els.btnPreload.textContent : null };
    if (state.reply instanceof Error) throw state.reply;
    return state.reply;
  }
};
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(coreJs, ctx, { filename: "panel_core.js" });
vm.runInContext(slice, ctx, { filename: "sidepanel.preload.slice.js" });
ok("核心模块已挂到沙箱", typeof ctx.PanelCore === "object" && ctx.PanelCore !== null);
ok("预载函数已从真实源码切片", typeof ctx.requestPreload === "function" && typeof ctx.renderPreloadRows === "function");

function reset() {
  state.selected = []; state.feedback = []; state.sent = []; state.reply = null; state.during = null;
  Object.keys(els).forEach((k) => { els[k].innerHTML = ""; els[k].textContent = ""; els[k].className = ""; els[k].disabled = false; });
}

async function main() {
  // 1) 未勾选：不发送、给 warn 提示
  reset();
  await ctx.requestPreload(false);
  ok("未勾选 → 不发送预载", state.sent.length === 0);
  ok("未勾选 → 提示先勾选", state.feedback.length === 1 && /先勾选/.test(state.feedback[0].msg), state.feedback);
  ok("未勾选 → 提示级别 warn", state.feedback[0].kind === "warn", state.feedback);

  // 2) 只勾预留平台（Instagram）：不发预载，提示暂不支持
  reset();
  state.selected = ["Instagram"];
  await ctx.requestPreload(false);
  ok("仅预留平台 → 不发送", state.sent.length === 0);
  ok("仅预留平台 → 提示暂不支持", /暂不支持预载/.test(state.feedback[0].msg) && /Instagram/.test(state.feedback[0].msg), state.feedback);

  // 3) 勾选 Telegram+Steam：载荷键化、recheck 透传、按钮过程中禁用
  reset();
  state.selected = ["Telegram", "Steam"];
  state.reply = { ok: true, data: { results: [
    { key: "telegram", logged: true, probe: "ok", settled: true, opened: true, url: "https://web.telegram.org/k/" },
    { key: "steam", logged: false, probe: "error", error: "No tab", settled: true, opened: false }
  ] } };
  await ctx.requestPreload(false);
  const s1 = state.sent[0];
  ok("发送一次 preload", state.sent.length === 1 && s1.type === "preload", state.sent);
  ok("载荷键化并保序", JSON.stringify(s1.extra.platforms) === JSON.stringify(["telegram", "steam"]), s1.extra);
  ok("预载不改写为 start", s1.type !== "start");
  ok("recheck 默认 false", s1.extra.recheck === false, s1.extra);
  ok("发送超时用 120s", s1.ms === 120000, s1.ms);
  ok("请求期间按钮禁用且文案预载中", state.during && state.during.disabled === true && /预载中/.test(state.during.text), state.during);
  ok("请求结束按钮恢复", els.btnPreload.disabled === false && /预载并检查登录态/.test(els.btnPreload.textContent), els.btnPreload.textContent);
  ok("已登录行显示 已登录", /telegram/i.test(els.preloadList.innerHTML) && /已登录/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);
  ok("探针报错行显示 待确认（而非未登录）", /steam/i.test(els.preloadList.innerHTML) && /待确认/.test(els.preloadList.innerHTML) && !/未登录/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);
  ok("摘要 1 已登录 · 1 待确认 · 0 未登录", els.preloadSummary.textContent === "1 已登录 · 1 待确认 · 0 未登录", els.preloadSummary.textContent);
  ok("完成提示含摘要", /预载完成/.test(state.feedback[state.feedback.length - 1].msg) && /1 已登录/.test(state.feedback[state.feedback.length - 1].msg), state.feedback);
  ok("上次预载时间已写入", /上次预载 12:00:00/.test(els.preloadAt.textContent), els.preloadAt.textContent);

  // 4) recheck=true 透传
  reset();
  state.selected = ["Telegram"];
  state.reply = { ok: true, data: { results: [{ key: "telegram", logged: true, probe: "ok", settled: true, opened: false }] } };
  await ctx.requestPreload(true);
  ok("recheck 透传为 true", state.sent[0].extra.recheck === true, state.sent[0].extra);
  ok("已存在标签文案", /已存在/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);

  // 5) 结果缺行：请求了但扩展没返回该平台 → 该行必须是「待确认」
  reset();
  state.selected = ["Telegram", "Steam"];
  state.reply = { ok: true, data: { results: [{ key: "telegram", logged: true, probe: "ok", settled: true }] } };
  await ctx.requestPreload(false);
  ok("缺结果行仍渲染", /steam/i.test(els.preloadList.innerHTML), els.preloadList.innerHTML);
  ok("缺结果行显示 待确认", /待确认/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);
  ok("缺结果摘要计待确认", els.preloadSummary.textContent === "1 已登录 · 1 待确认 · 0 未登录", els.preloadSummary.textContent);

  // 6) 超时：全部待确认 + 明确提示未自动重发
  reset();
  state.selected = ["Telegram"];
  state.reply = { ok: false, error: "timeout_pending" };
  await ctx.requestPreload(false);
  ok("超时 → 待确认", /待确认/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);
  ok("超时提示未自动重发", /未自动重发/.test(state.feedback[state.feedback.length - 1].msg), state.feedback);

  // 7) 扩展报错：不崩、不误报登录
  reset();
  state.selected = ["Telegram"];
  state.reply = { ok: false, error: "disconnected" };
  await ctx.requestPreload(false);
  ok("扩展报错 → 渲染待确认", /待确认/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);
  ok("扩展报错 → 提示预载失败", /预载失败/.test(state.feedback[state.feedback.length - 1].msg), state.feedback);

  // 8) 整轮运行中（RUN_BUSY）：预载直接不发送
  reset();
  state.selected = ["Telegram"];
  ctx.RUN_BUSY = true;
  await ctx.requestPreload(false);
  ok("运行中不发送预载", state.sent.length === 0);
  ctx.RUN_BUSY = false;

  // 9) 结果为空数组：提示扩展未响应，行仍待确认
  reset();
  state.selected = ["Telegram"];
  state.reply = { ok: true, data: { results: [] } };
  await ctx.requestPreload(false);
  ok("空结果 → 扩展未响应", /扩展未响应/.test(state.feedback[state.feedback.length - 1].msg), state.feedback);
  ok("空结果 → 待确认", /待确认/.test(els.preloadList.innerHTML), els.preloadList.innerHTML);

  console.log("\npreload_behavior: " + (fail ? "FAIL pass=" + pass + " fail=" + fail : "all PASS (" + pass + ")"));
  process.exit(fail ? 1 : 0);
}
main().catch((e) => { console.error("UNCAUGHT " + (e && e.stack || e)); process.exit(1); });
