// tests/offline/sidepanel_start_payload.test.js
// 用真实 sidepanel.js 的 selectedPlatforms / syncPlatHint / runnablePlatforms / sendWithTimeout + 假 DOM / 假 chrome，
// 断言「开始运行」只发可启动平台（Telegram/Facebook），且 0 可启动平台时禁用并拒绝。
// 平台路由契约：Discord/Reddit/WhatsApp/Steam 勾选只用于预载或由计划任务执行，绝不进入 start 载荷。
const fs = require("fs");
const path = require("path");
const SRC = fs.readFileSync(path.join(__dirname, "..", "..", "extension", "src", "sidepanel.js"), "utf8");

function sliceFn(name) {
  let i = SRC.indexOf("function " + name + "(");
  if (i < 0) throw new Error("fn not found: " + name);
  if (i >= 6 && SRC.slice(i - 6, i) === "async ") i -= 6; // 保留 async 前缀
  let d = 0, j = SRC.indexOf("{", i);
  for (let k = j; k < SRC.length; k++) {
    if (SRC[k] === "{") d++;
    else if (SRC[k] === "}") { d--; if (d === 0) return SRC.slice(i, k + 1); }
  }
  throw new Error("unbalanced " + name);
}

let sent = [];
const boxes = [];
function box(name, checked) {
  return { checked, closest: () => ({ getAttribute: () => name }) };
}
const dom = {
  "#platList input[type=checkbox]": boxes,
  "input[type=checkbox]": boxes,
};
let btnStart = { disabled: false, title: "" };
let hint = { textContent: "" };
global.document = {
  querySelectorAll: (sel) => (dom[sel] || []),
  getElementById: (id) => (id === "btnStart" ? btnStart : (id === "platsHint" ? hint : null)),
};
global.window = {};
global.chrome = {
  runtime: {
    id: "test",
    sendMessage: (msg, cb) => { sent.push(JSON.parse(JSON.stringify(msg))); if (cb) cb({ ok: true }); },
    lastError: null,
  },
};
global.setTimeout = (fn) => { try { fn(); } catch (e) {} return 0; };
global.clearTimeout = () => {};

const api = new Function("document", "window", "chrome", "setTimeout", "clearTimeout",
  'const RUN_PLATFORMS = ["Telegram", "Facebook"];\n' +
  sliceFn("ctxAlive") + "\n" + sliceFn("selectedPlatforms") + "\n" + sliceFn("isRunnablePlatform") + "\n" + sliceFn("runnablePlatforms") + "\n" + sliceFn("syncPlatHint") + "\n" + sliceFn("sendWithTimeout") + "\n" + sliceFn("sendOnce") +
  "\nreturn { selectedPlatforms, runnablePlatforms, syncPlatHint, sendWithTimeout };")(global.document, global.window, global.chrome, global.setTimeout, global.clearTimeout);

let pass = 0, fail = 0;
function T(name, fn) { try { fn(); pass++; console.log("PASS  " + name); } catch (e) { fail++; console.log("FAIL  " + name + " :: " + e.message); } }

// S0: 0 selected -> disabled + hint
boxes.length = 0;
T("zero-selected-disables-start", () => {
  const sel = api.selectedPlatforms();
  if (sel.length !== 0) throw new Error("sel=" + JSON.stringify(sel));
  api.syncPlatHint();
  if (btnStart.disabled !== true) throw new Error("btnStart.disabled=" + btnStart.disabled);
  if (!/未选平台/.test(hint.textContent)) throw new Error("hint=" + hint.textContent);
});

// S1: single selected -> payload order/platforms
T("single-selected-payload", () => {
  boxes.length = 0; boxes.push(box("Telegram", true)); sent = [];
  api.syncPlatHint();
  if (btnStart.disabled !== false) throw new Error("still disabled");
  const run = api.runnablePlatforms();
  api.sendWithTimeout("start", 100, { platforms: run, order: run });
  if (sent.length !== 1) throw new Error("sent=" + sent.length);
  const m = sent[0];
  if (m.type !== "start") throw new Error("type=" + m.type);
  if (JSON.stringify(m.platforms) !== '["Telegram"]') throw new Error("platforms=" + JSON.stringify(m.platforms));
  if (JSON.stringify(m.order) !== '["Telegram"]') throw new Error("order=" + JSON.stringify(m.order));
});

// S2: two runnable platforms keep DOM order
T("multi-runnable-order", () => {
  boxes.length = 0; boxes.push(box("Telegram", true), box("Facebook", true), box("Steam", false)); sent = [];
  api.syncPlatHint();
  if (!/可启动：Telegram → Facebook/.test(hint.textContent)) throw new Error("hint=" + hint.textContent);
  if (btnStart.disabled !== false) throw new Error("disabled for runnable selection");
  const run = api.runnablePlatforms();
  api.sendWithTimeout("start", 100, { platforms: run, order: run });
  const m = sent[0];
  if (JSON.stringify(m.order) !== '["Telegram","Facebook"]') throw new Error("order=" + JSON.stringify(m.order));
});

// S3: mixed selection -> only runnable entries in payload, hint names the preload-only subset
T("mixed-selection-filters-runnable", () => {
  boxes.length = 0; boxes.push(box("Telegram", true), box("Steam", true), box("WhatsApp", true), box("Reddit", false)); sent = [];
  api.syncPlatHint();
  if (!/可启动：Telegram/.test(hint.textContent)) throw new Error("hint=" + hint.textContent);
  if (!/仅预载／计划任务：Steam → WhatsApp/.test(hint.textContent)) throw new Error("hint=" + hint.textContent);
  const run = api.runnablePlatforms();
  if (JSON.stringify(run) !== '["Telegram"]') throw new Error("run=" + JSON.stringify(run));
  api.sendWithTimeout("start", 100, { platforms: run, order: run });
  const m = sent[0];
  if (JSON.stringify(m.platforms) !== '["Telegram"]') throw new Error("platforms=" + JSON.stringify(m.platforms));
});

// S4: only preload/scheduled platforms -> start disabled, no platform goes to start
T("preload-only-disables-start", () => {
  boxes.length = 0; boxes.push(box("Steam", true), box("Reddit", true), box("Discord", true)); sent = [];
  api.syncPlatHint();
  if (btnStart.disabled !== true) throw new Error("btnStart.disabled=" + btnStart.disabled);
  if (!/无可启动平台/.test(hint.textContent)) throw new Error("hint=" + hint.textContent);
  const run = api.runnablePlatforms();
  if (run.length !== 0) throw new Error("run=" + JSON.stringify(run));
});

T("no-extra-no-platforms", () => {
  sent = [];
  api.sendWithTimeout("start", 100);
  if (sent[0].platforms !== undefined) throw new Error("unexpected platforms");
});

console.log("RESULT pass=" + pass + " fail=" + fail);
process.exit(fail ? 1 : 0);
