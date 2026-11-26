// platform_routing.test.js — 平台路由行为测试（真实 background.js + 假 chrome/假 hub/假标签页）
// 目标：严禁没有页面执行器的平台（Reddit/WhatsApp/Steam/Discord）被注入 Telegram 标签页；
// 无执行器平台的任务必须显式回 platform_unsupported；"start" 消息也必须先过滤再转发 hub。
// 全部离线：不连真实 hub、不启动浏览器、不触发任何业务。
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SRC = fs.readFileSync(path.resolve(__dirname, "..", "src", "background.js"), "utf8");

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + (extra === undefined ? "" : "  -> " + JSON.stringify(extra))); }
}

function jsonRes(obj, status) {
  return { ok: (status || 200) < 400, status: status || 200, json: async () => obj };
}

function makeCtx(opts) {
  const o = opts || {};
  const scenario = { ready: false, tasks: [], results: [], controls: [], calls: [] };
  const store = { running: false, stats: { joined: 0, failed: 0, skipped: 0 }, lastLog: "" };
  const exec = [];
  const sandbox = {
    console, URL, AbortController, JSON, Promise, Date, Math, Number, String, Array, Object, Error,
    setTimeout: (fn, ms) => (ms && ms <= 1000 ? setTimeout(fn, ms) : -1),
    clearTimeout: () => {},
    fetch: async (url, opt) => {
      const p = new URL(String(url)).pathname;
      scenario.calls.push({ path: p, body: opt && opt.body });
      if (p === "/health") return jsonRes({ running: !!scenario.ready });
      if (p === "/task") {
        const t = scenario.tasks.length ? scenario.tasks.shift() : null;
        return t ? jsonRes(t) : jsonRes(null, 204);
      }
      if (p === "/result") { scenario.results.push(JSON.parse(opt.body)); return jsonRes({ ok: true }); }
      if (p === "/control") { scenario.controls.push(JSON.parse(opt.body)); return jsonRes({ ok: true, data: {} }); }
      return jsonRes({ ok: true });
    },
    chrome: {
      runtime: {
        lastError: null,
        onMessage: { addListener: (fn) => { sandbox.__onMessage = fn; } },
        onStartup: { addListener: () => {} },
        onInstalled: { addListener: () => {} },
      },
      alarms: { onAlarm: { addListener: () => {} }, create: () => {}, clear: () => {} },
      sidePanel: { setPanelBehavior: async () => {} },
      storage: {
        local: {
          get: async () => Object.assign({}, store),
          set: async (patch) => { Object.assign(store, patch); },
        },
      },
      tabs: {
        query: async () => (o.tabs || []).slice(),
        get: async (id) => (o.tabs || []).find((t) => t.id === id) || null,
        update: async () => {},
        create: async () => ({ id: 999 }),
        reload: async () => {},
      },
      windows: { update: async () => {} },
      scripting: {
        executeScript: async (req) => {
          exec.push(req);
          return [{ result: JSON.stringify(o.pageRes || { ok: true, v: [] }) }];
        },
      },
    },
  };
  sandbox.__store = store;
  sandbox.__exec = exec;
  sandbox.__scenario = scenario;
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox);
  return sandbox;
}

// boot() 在加载时会自己 tick 一次；先让这次 tick 在 /health 之后安静退出，
// 再清空记录，测试才从确定的空闲态开始。
async function booted(ctx) {
  for (let i = 0; i < 500 && !ctx.__scenario.calls.some((c) => c.path === "/health"); i++) {
    await new Promise((r) => setImmediate(r));
  }
  for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r));
  ctx.__scenario.ready = true;
  ctx.__scenario.calls.length = 0;
  ctx.__scenario.tasks.length = 0;
  ctx.__scenario.results.length = 0;
  ctx.__scenario.controls.length = 0;
  ctx.tick.lastHeal = Date.now();
  return ctx;
}

const TG_TAB = { id: 111, status: "complete", url: "https://web.telegram.org/k/" };
const FB_TAB = { id: 222, status: "complete", url: "https://www.facebook.com/" };
const RD_TAB = { id: 333, status: "complete", url: "https://www.reddit.com/" };

(async () => {
  // 1) findTab：未知平台不能回落到 Telegram
  {
    const ctx = await booted(makeCtx({ tabs: [TG_TAB, FB_TAB, RD_TAB] }));
    ok("findTab telegram -> TG tab", (await ctx.findTab("Telegram")).id === 111);
    ok("findTab facebook -> FB tab", (await ctx.findTab("Facebook")).id === 222);
    ok("findTab reddit -> reddit tab", (await ctx.findTab("Reddit")).id === 333);
    ok("findTab whatsapp -> null (no TG fallback)", (await ctx.findTab("WhatsApp")) === null);
    ok("findTab steam -> null", (await ctx.findTab("Steam")) === null);
    ok("findTab unknown -> null", (await ctx.findTab("Instagram")) === null);
  }

  // 2) 非执行器平台任务：显式 platform_unsupported，绝不注入任何标签页
  for (const platform of ["WhatsApp", "Steam", "Reddit", "Discord", "Instagram"]) {
    const ctx = await booted(makeCtx({ tabs: [TG_TAB] }));
    ctx.__scenario.tasks.push({ action: "search", platform, id: "t-" + platform, query: "q" });
    await ctx.tick();
    const r = ctx.__scenario.results[0];
    ok("unsupported " + platform + " -> result error", !!r && r.error === "platform_unsupported" && r.ok === false, r);
    ok("unsupported " + platform + " -> no executeScript", ctx.__exec.length === 0, ctx.__exec.length);
  }

  // 3) Telegram 搜索：真的用 TG 标签页
  {
    const ctx = await booted(makeCtx({
      tabs: [TG_TAB, { id: 444, status: "complete", url: "https://web.whatsapp.com/" }],
      pageRes: { ok: true, v: [{ id: "1", title: "x" }] },
    }));
    ctx.__scenario.tasks.push({ action: "search", platform: "Telegram", id: "t1", query: "csgo", limit: 20 });
    await ctx.tick();
    const r = ctx.__scenario.results[0];
    ok("telegram search returns value", !!r && r.kind === "search" && r.ok === true && Array.isArray(r.value) && r.value.length === 1, r);
    ok("telegram search injects only TG tab", ctx.__exec.length > 0 && ctx.__exec.every((e) => e.target && e.target.tabId === 111), ctx.__exec.map((e) => e.target));
  }

  // 4) Telegram 缺失但存在 WhatsApp 标签页：不得借用其它标签页
  {
    const ctx = await booted(makeCtx({ tabs: [{ id: 444, status: "complete", url: "https://web.whatsapp.com/" }] }));
    ctx.__scenario.tasks.push({ action: "join", platform: "Telegram", id: "t2", u: "someone" });
    await ctx.tick();
    const r = ctx.__scenario.results[0];
    ok("telegram without TG tab -> no_tab", !!r && r.error === "no_tab" && r.ok === false, r);
    ok("telegram without TG tab -> no injection", ctx.__exec.length === 0, ctx.__exec.length);
  }

  // 5) message "start"：转发前过滤，混合选择只送可执行平台
  {
    const ctx = await booted(makeCtx({ tabs: [TG_TAB] }));
    let resp = null;
    ctx.__onMessage({ type: "start", platforms: ["Telegram", "Steam", "WhatsApp"], order: ["Telegram", "Steam", "WhatsApp"] }, {}, (x) => { resp = x; });
    await new Promise((r) => setImmediate(r));
    ok("start mixed -> filtered platforms", ctx.__scenario.controls.length === 1 && JSON.stringify(ctx.__scenario.controls[0].platforms) === '["Telegram"]', ctx.__scenario.controls);
    ok("start mixed -> filtered order", JSON.stringify(ctx.__scenario.controls[0].order) === '["Telegram"]', ctx.__scenario.controls);
    ok("start mixed -> ok response", !!resp && resp.ok === true, resp);
  }

  // 6) message "start"：全是无执行器平台 -> 本地拒绝，不碰 hub
  {
    const ctx = await booted(makeCtx({ tabs: [TG_TAB] }));
    let resp = null;
    ctx.__onMessage({ type: "start", platforms: ["Steam", "Discord"] }, {}, (x) => { resp = x; });
    await new Promise((r) => setImmediate(r));
    ok("start preload-only -> rejected locally", !!resp && resp.ok === false && resp.error === "no_runnable_platforms", resp);
    ok("start preload-only -> no /control call", ctx.__scenario.controls.length === 0, ctx.__scenario.controls);
  }

  // 7) 既有 TG 加入路径不变
  {
    const ctx = await booted(makeCtx({ tabs: [TG_TAB], pageRes: { ok: true, v: "joined" } }));
    ctx.__scenario.tasks.push({ action: "join", platform: "Telegram", id: "t3", u: "someone", self: "42" });
    await ctx.tick();
    const r = ctx.__scenario.results[0];
    ok("telegram join ok", !!r && r.kind === "join" && r.ok === true && r.value === "joined", r);
    ok("telegram join counted", ctx.__store.stats.joined === 1, ctx.__store.stats);
  }

  console.log("RESULT pass=" + pass + " fail=" + fail);
  process.exit(fail ? 1 : 0);
})();
