// sidepanel_actions.test.js -- offline fake-DOM test for the side panel start/stop wiring.
// No browser, no network, no extension APIs.
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.resolve(__dirname, "..", "..");
const jsPath = path.join(root, "extension", "src", "sidepanel.js");
const htmlPath = path.join(root, "extension", "src", "sidepanel.html");
const bgPath = path.join(root, "extension", "src", "background.js");
const js = fs.readFileSync(jsPath, "utf8");
const html = fs.readFileSync(htmlPath, "utf8");
const bg = fs.readFileSync(bgPath, "utf8");

let pass = 0, fail = 0;
const failed = [];
function check(cond, name) {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; failed.push(name); console.log("FAIL " + name); }
}
const tick = () => new Promise(r => setImmediate(r));
async function settle(n) { for (let i = 0; i < (n || 4); i++) { await tick(); } }

function makeEl(id) {
  const e = {
    id: id, textContent: "", innerHTML: "", className: "", title: "",
    disabled: false, checked: false, style: {}, _handlers: {},
    classList: {
      add() {}, remove() {}, toggle() {}, contains() { return false; }
    },
    addEventListener(t, fn) { this._handlers[t] = fn; },
    click() {
      if (this.disabled) return;
      const fn = this._handlers.click;
      if (fn) fn({ preventDefault() {}, stopPropagation() {} });
    },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    getAttribute() { return null; },
    setAttribute() {},
    closest() { return null; },
    appendChild() {},
    remove() {}
  };
  return e;
}

function loadSidepanel() {
  const els = new Map();
  function el(id) { if (!els.has(id)) els.set(id, makeEl(id)); return els.get(id); }
  const plats = ["Facebook","Telegram","Discord","Reddit","WhatsApp","Instagram","Steam"].map(function (n) { return { name: n, checked: true }; });
  const document = {
    getElementById: el,
    querySelector(sel) {
      if (sel && sel[0] === "#") return el(sel.slice(1));
      return null;
    },
    querySelectorAll(sel) {
      if (sel && /checkbox/.test(sel)) {
        return plats.map(function (p) {
          return { checked: p.checked, closest: function () { return { getAttribute: function (a) { return a === "data-name" ? p.name : null; } }; } };
        });
      }
      return [];
    },
    createElement(tag) { return makeEl(tag); },
    body: makeEl("body")
  };

  let startCalls = 0, stopCalls = 0;
  let statusRunning = false;
  let startImpl = async () => ({ ok: true });
  let stopImpl = async () => ({ ok: true });
  const chrome = {
    runtime: {
      id: "offline-test",
      sendMessage: async (msg) => {
        if (!msg) return { ok: false };
        if (msg.type === "status") {
          return { ok: true, st: { running: statusRunning, stats: { joined: 0 }, lastLog: "" }, hub: { ok: true, phase: "idle" }, cfg: null, probe: {} };
        }
        if (msg.type === "start") { startCalls++; return await startImpl(); }
        if (msg.type === "stop" || msg.type === "stop_run") { stopCalls++; return await stopImpl(); }
        return { ok: true };
      }
    },
    tabs: { create() {}, query: async () => [], scripting: { executeScript: async () => [] } }
  };

  const responses = {
    "/api/summary": { totals: { todayGroups: 0 } },
    "/api/config": { platforms: ["Facebook", "Telegram", "Reddit"], platformsEnabled: { Reddit: true }, reserved: [] },
    "/api/live": { running: false, phase: "idle", events: [], pipeline: { state: "unknown", reason: "no_pipeline_evidence" } }
  };
  const fetch = async (url) => {
    const p = String(url).replace("http://127.0.0.1:8787", "").split("?")[0];
    return { ok: true, json: async () => (responses[p] || {}) };
  };
  const timers = [];
  function flushTimers() {
    for (let i = 0; i < 50 && timers.length; i++) {
      const item = timers.shift();
      try { item.fn(); } catch (e) {}
    }
  }
  const context = {
    document, fetch, chrome, console,
    setTimeout: (fn, ms) => { timers.push({ fn: fn, ms: ms || 0 }); return timers.length; },
    setInterval: () => 0, clearTimeout: () => {}, clearInterval: () => {},
    location: { reload() {} },
    Promise
  };
  context.window = context;
  context.window.chrome = chrome;
  vm.createContext(context);
  vm.runInContext(js, context, { filename: jsPath });
  return {
    els: els,
    get: el,
    context,
    flushTimers,
    setStart(fn) { startImpl = fn; },
    setStop(fn) { stopImpl = fn; },
    setRunning(v) { statusRunning = !!v; },
    setLive(obj) { responses["/api/live"] = obj; },
    refreshLive() { return vm.runInContext("refreshLive()", context); },
    counts() { return { start: startCalls, stop: stopCalls }; }
  };
}

(async () => {
  const app = loadSidepanel();
  await settle(6);

  const startEl = app.get("btnStart");
  const stopEl = app.get("btnStop");
  const fb = app.get("feedback");

  check(typeof startEl._handlers.click === "function", "sidepanel: btnStart has a real click handler");
  check(typeof stopEl._handlers.click === "function", "sidepanel: btnStop has a real click handler");
  check(html.indexOf('id="feedback"') >= 0, "sidepanel: HTML contains feedback element");

  // one click -> exactly one start request
  app.setStart(async () => ({ ok: true }));
  startEl.click();
  await settle(6);
  check(app.counts().start === 1, "sidepanel: one click sends exactly one start request");
  check(fb && /\u542f\u52a8/.test(fb.textContent), "sidepanel: accepted start shows feedback");

  // duplicate while in flight -> still one
  let resolveStart;
  app.setStart(() => new Promise(res => { resolveStart = res; }));
  const before = app.counts().start;
  startEl.click();
  startEl.click();
  await settle(3);
  check(app.counts().start === before + 1, "sidepanel: rapid duplicate start click sends only once");
  if (typeof resolveStart === 'function') resolveStart({ ok: true });
  await settle(6);

  // refusal
  app.setStart(async () => ({ ok: false, error: "platform_disabled", detail: "Reddit disabled" }));
  startEl.click();
  await settle(6);
  check(fb && /\u62d2\u7edd|platform_disabled/.test(fb.textContent), "sidepanel: hub refusal is shown to the user");

  // disconnect
  app.setStart(async () => { throw new Error("runtime disconnected"); });
  startEl.click();
  await settle(6);
  check(fb && /\u65ad\u7ebf|\u65e0\u54cd\u5e94/.test(fb.textContent), "sidepanel: disconnected runtime is shown to the user");

  // stop success (the real UI enables this from the running status; make the fixture deterministic)
  app.setRunning(true);
  stopEl.disabled = false;
  await settle(4);
  app.setStop(async () => ({ ok: true }));
  stopEl.click();
  await settle(6);
  check(app.counts().stop === 1, "sidepanel: one stop click sends exactly one stop request");
  check(fb && /\u505c\u6b62/.test(fb.textContent), "sidepanel: stop shows feedback");

  // stop failure
  app.setStop(async () => ({ ok: false, error: "hub_unreachable" }));
  stopEl.click();
  await settle(6);
  check(fb && /\u505c\u6b62\u5931\u8d25|\u540e\u53f0\u65ad\u7ebf|hub_unreachable/.test(fb.textContent), "sidepanel: failed stop is shown to the user");

  // —— trusted status bar: platform phase and whole-pipeline status are separate ——
  app.setLive({
    running: false, phase: "done", platform: "Reddit", events: [],
    pipeline: { state: "unknown", reason: "no_pipeline_evidence" }
  });
  await app.refreshLive();
  await settle(4);
  check(app.get("stPipeline").textContent === "\u672a\u77e5", "status: hub done + no pipeline evidence is unknown, not done");
  check(app.get("stPipeline").textContent !== "\u5df2\u5b8c\u6210", "status: hub done is not reported as whole-pipeline complete");

  app.setLive({
    running: false, phase: "done", platform: "Reddit", events: [],
    pipeline: { state: "running", completed: 1, total: 3, current_platform: "Reddit", next_platform: "Steam", updated_at: new Date().toISOString() }
  });
  await app.refreshLive();
  await settle(4);
  check(app.get("stPipeline").textContent === "\u8fd0\u884c\u4e2d", "status: pipeline running shown");
  check(/1\/3/.test(app.get("stPipeMeta").textContent), "status: pipeline completed/total shown");
  check(/Reddit/.test(app.get("stPipeMeta").textContent), "status: pipeline current platform shown");

  app.setLive({
    running: true, phase: "search", platform: "Reddit", current: "cs2 skins", events: [],
    cooldowns: { Reddit: { until: new Date(Date.now() + 600000).toISOString(), remaining_sec: 600, reason: "collector_stalled" } },
    pipeline: { state: "running", completed: 0, total: 3, current_platform: "Reddit", next_platform: "Steam", updated_at: new Date().toISOString() }
  });
  await app.refreshLive();
  await settle(4);
  check(/Reddit/.test(app.get("stCooldown").textContent), "status: Reddit cooldown platform shown");
  check(/\u91c7\u96c6\u8fde\u7eed\u7a7a\u7ed3\u679c/.test(app.get("stCooldown").textContent), "status: cooldown reason shown");
  check(app.get("stCooldownRow").style.display !== "none", "status: cooldown row visible when active");

  app.context.renderStatusBar({ running: false, phase: "idle", events: [], pipeline: { state: "unknown" } }, Date.now() - 30000);
  check(app.get("stFresh").textContent === "\u9648\u65e7", "status: stale observation marked");
  app.context.renderStatusBar(null, 0);
  check(/\u65ad\u7ebf|\u672a\u8fde\u63a5/.test(app.get("stFresh").textContent + app.get("stPlatform").textContent), "status: disconnect marked");

  // start timeout -> pending confirmation, no auto resend
  app.setRunning(false);
  startEl.disabled = false;
  app.context.START_TIMEOUT_MS = 10;
  let neverResolve;
  app.setStart(() => new Promise(res => { neverResolve = res; }));
  const beforeTimeout = app.counts().start;
  startEl.click();
  app.flushTimers();
  await settle(6);
  check(app.counts().start === beforeTimeout + 1, "start timeout: exactly one request, no resend");
  check(/\u5f85\u786e\u8ba4|\u8d85\u65f6/.test(fb.textContent), "start timeout: feedback says result pending confirmation");
  await settle(6);
  check(app.counts().start === beforeTimeout + 1, "start timeout: still no resend after settling");
  if (neverResolve) neverResolve({ ok: true });

  check(/computeStatus/.test(js), "status: status computation exists");
  check(/stPipeline/.test(js) && /pipeline/.test(js), "status: pipeline evidence rendered separately");
  check(/sendWithTimeout/.test(js) && /timeout_pending/.test(js), "status: start timeout is pending, no resend");
  check(html.indexOf('id="statusbar"') >= 0 && html.indexOf('id="stPipeline"') >= 0, "status: HTML has status bar");
  check(/\.statusbar/.test(fs.readFileSync(path.join(root, "extension", "src", "sidepanel.css"), "utf8")), "status: CSS has status bar styles");

  // background must await the hub and surface errors (static assertions)
  check(/await\s+hubFetch\(\s*["']\/control["']/.test(bg), "background: start/stop awaits hub response");
  check(/hub_unreachable/.test(bg), "background: hub failure error is surfaced");
  check(/sendResponse\(\{\s*ok:\s*false/.test(bg), "background: refusal returned to sidepanel");

  console.log("RESULT pass=" + pass + " fail=" + fail);
  if (fail) { console.log("FAILED: " + failed.join("; ")); process.exit(1); }
})().catch(e => { console.error("ERROR " + (e && e.stack || e)); process.exit(1); });
