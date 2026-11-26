// preload_background.test.js — 用真实 background.js 预载函数跑行为测试（假 chrome，无网络/无凭据）
// 关键验收：预载不碰运行入口；探测不确定时 rows 必须能让侧栏判「待确认」（probe=error / settled=false）。
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.resolve(__dirname, "..", "src", "background.js"), "utf8");
const A = src.indexOf("const PRELOAD_URLS = {");
const B = src.indexOf("chrome.runtime.onMessage.addListener(");
if (A < 0 || B <= A) { console.error("SLICE MISS A=" + A + " B=" + B); process.exit(1); }
const slice = src.slice(A, B);
// waitTab 定义在文件后部：单独切片进沙箱，保证测的是真实实现
const W = src.indexOf("async function waitTab(");
const WEND = src.indexOf("\n}", W);
if (W < 0 || WEND < 0) { console.error("SLICE MISS waitTab"); process.exit(1); }
const waitSrc = src.slice(W, WEND + 2);
// urlHost / hostMatches 定义在切片之前：也单独切进沙箱
function sliceFn(name) {
  const a = src.indexOf("function " + name + "(");
  if (a < 0) { console.error("SLICE MISS " + name); process.exit(1); }
  let depth = 0;
  for (let i = src.indexOf("{", a); i < src.length; i++) {
    const ch = src[i];
    if (ch === "{") depth++;
    else if (ch === "}") { depth--; if (depth === 0) return src.slice(a, i + 1); }
  }
  console.error("SLICE MISS end " + name); process.exit(1);
}
const hostSrc = sliceFn("urlHost") + "\n" + sliceFn("hostMatches");

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + (extra === undefined ? "" : "  -> " + JSON.stringify(extra))); }
}

function makeEnv(cfg) {
  const calls = { create: [], update: [], query: 0, exec: 0, reload: [] };
  const state = { tabs: cfg.tabs || [] };
  const chrome = {
    tabs: {
      async query() { calls.query++; return state.tabs.slice(); },
      async create(o) {
        calls.create.push(o);
        const t = { id: 900 + calls.create.length, url: o.url, status: "complete" };
        state.tabs.push(t);
        return t;
      },
      async get(id) {
        const t = state.tabs.find((x) => x.id === id);
        if (!t) { const e = new Error("No tab with id: " + id); throw e; }
        if (cfg.tabGone) throw new Error("No tab with id: " + id);
        return t;
      },
      async update(id, o) { calls.update.push({ id, o }); return { id }; },
      async reload(id) { calls.reload.push(id); }
    },
    scripting: {
      async executeScript() {
        calls.exec++;
        if (cfg.tabGone) throw new Error("No tab with id");
        if (cfg.raw !== undefined) return cfg.raw;
        if (cfg.probe) return cfg.probe();
        return [{ result: cfg.logged !== false }];
      }
    }
  };
  const ctx = {
    console, chrome, Math, Date, JSON, String, Array, Object, Promise, URL,
    setTimeout, clearTimeout,
    sleep: async () => {},
    waitTabImpl: null
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(hostSrc, ctx, { filename: "background.host.slice.js" });
  vm.runInContext(waitSrc, ctx, { filename: "background.waitTab.slice.js" });
  vm.runInContext(slice, ctx, { filename: "background.preload.slice.js" });
  return { ctx, calls, state };
}

async function main() {
  ok("预载函数已从真实源码切片", typeof vm.runInContext !== "undefined");

  // 1) 正常：勾选 Telegram（含缩写/重复/预留平台）→ 只预载 telegram，开新标签并判定已登录
  {
    const { ctx, calls } = makeEnv({ tabs: [{ id: 1, url: "https://mail.example.com/", status: "complete" }], logged: true });
    const r = await ctx.handlePreload(["tg", "Telegram", "instagram"], { recheck: false });
    ok("未知/预留平台被过滤", r.results.length === 1 && r.results[0].key === "telegram", r.results.map((x) => x.key));
    ok("缺标签则新开（后台不抢焦点）", calls.create.length === 1 && calls.create[0].active === false, calls.create);
    const row = r.results[0];
    ok("行内含 settled", row.settled === true, row);
    ok("行内含 opened", row.opened === true, row);
    ok("探针成功 → logged=true / probe=ok", row.logged === true && row.probe === "ok", row);
    ok("预载不发送 start", !calls.create.some((c) => String(c.url || "").includes("hub")), calls.create);
  }

  // 2) 探针一直失败：rows 必须是 probe=error + logged=null（侧栏据此显示待确认）
  {
    const { ctx } = makeEnv({ tabs: [{ id: 2, url: "https://web.telegram.org/k/", status: "complete" }],
      probe: () => { throw new Error("Cannot access contents of the page"); } });
    const r = await ctx.handlePreload(["telegram"], {});
    const row = r.results[0];
    ok("探针失败 3 次后放弃", row.attempts === 3, row.attempts);
    ok("探针失败 → probe=error", row.probe === "error", row);
    ok("探针失败 → logged=null（不能当作未登录）", row.logged === null, row);
    ok("探针失败 → 带错误原因", /Cannot access/.test(String(row.error)), row.error);
  }

  // 3) 标签被关掉：settled=false + error 行，侧栏必须显示待确认
  {
    const { ctx } = makeEnv({ tabs: [{ id: 3, url: "https://www.facebook.com/", status: "loading" }], tabGone: true });
    const r = await ctx.handlePreload(["fb"], {});
    const row = r.results[0];
    ok("标签消失 → settled=false", row.settled === false, row);
    ok("标签消失 → 仍返回结果行（不抛错）", row.key === "facebook", row);
    ok("标签消失 → probe=error/logged=null", row.probe === "error" && row.logged === null, row);
    ok("标签消失 → 重试 3 次后放弃", row.attempts === 3, row.attempts);
  }

  // 4) 重新检测：已有标签 → 不新开，只激活并重探
  {
    const { ctx, calls } = makeEnv({ tabs: [{ id: 4, url: "https://steamcommunity.com/groups", status: "complete" }] });
    const r = await ctx.handlePreload(["steam"], { recheck: true });
    ok("已有标签不新开", calls.create.length === 0, calls.create);
    ok("重新检测会激活标签", calls.update.length === 1 && calls.update[0].o.active === true, calls.update);
    ok("已有标签 opened=false", r.results[0].opened === false, r.results[0]);
  }

  // 5) 全部未知平台：返回空结果而不是抛错（侧栏会提示不支持）
  {
    const { ctx } = makeEnv({ tabs: [] });
    const r = await ctx.handlePreload(["weibo", "Instagram"], {});
    ok("全未知 → ok 且空结果", r.ok === true && r.results.length === 0, r);
  }

  // 6) 每平台顺序互不干扰：结果 key 顺序与输入归一顺序一致
  {
    const { ctx } = makeEnv({ tabs: [] });
    const r = await ctx.handlePreload(["steam", "telegram", "discord"], {});
    ok("结果顺序 = 输入归一顺序", JSON.stringify(r.results.map((x) => x.key)) === JSON.stringify(["steam", "telegram", "discord"]), r.results.map((x) => x.key));
    ok("三个平台各开一个标签", r.results.every((x) => x.opened === true), r.results);
  }

  // 7) executeScript 执行成功但没返回值（空数组 / undefined）：不能折成 false
  {
    const { ctx } = makeEnv({ tabs: [{ id: 7, url: "https://web.telegram.org/k/", status: "complete" }], raw: [] });
    const r = await ctx.handlePreload(["telegram"], {});
    const row = r.results[0];
    ok("空 executeScript 结果 → logged=null", row.logged === null, row);
    ok("空 executeScript 结果 → probe=ok（执行成功，只是缺证据）", row.probe === "ok", row);
  }
  {
    const { ctx } = makeEnv({ tabs: [{ id: 8, url: "https://web.telegram.org/k/", status: "complete" }], raw: [{ result: undefined }] });
    const r = await ctx.handlePreload(["telegram"], {});
    ok("result=undefined → logged=null", r.results[0].logged === null, r.results[0]);
  }
  {
    const { ctx } = makeEnv({ tabs: [{ id: 9, url: "https://web.telegram.org/k/", status: "complete" }], raw: [{ result: "yes" }] });
    const r = await ctx.handlePreload(["telegram"], {});
    ok("非 true/false 的返回值 → logged=null（不靠真值判断）", r.results[0].logged === null, r.results[0]);
  }

  // 8) URL 归属：只认解析后的同名 host / 官方子域，不做子串匹配
  {
    const { ctx, calls } = makeEnv({ tabs: [{ id: 11, url: "https://evil-telegram.org/k/", status: "complete" }], logged: true });
    const r = await ctx.handlePreload(["telegram"], {});
    ok("子串伪装 host 不被复用（evil-telegram.org）", calls.create.length === 1 && r.results[0].opened === true, { create: calls.create, row: r.results[0] });
  }
  {
    const { ctx, calls } = makeEnv({ tabs: [{ id: 12, url: "https://m.facebook.com/", status: "complete" }], logged: true });
    const r = await ctx.handlePreload(["fb"], {});
    ok("官方子域被复用（m.facebook.com）", calls.create.length === 0 && r.results[0].opened === false, { create: calls.create, row: r.results[0] });
  }
  {
    const { ctx, calls } = makeEnv({ tabs: [{ id: 13, url: "https://facebook.com.evil.io/", status: "complete" }], logged: true });
    const r = await ctx.handlePreload(["fb"], {});
    ok("后缀伪装 host 不被复用（facebook.com.evil.io）", calls.create.length === 1 && r.results[0].opened === true, { create: calls.create, row: r.results[0] });
  }

  console.log("\npreload_background: " + (fail ? "FAIL pass=" + pass + " fail=" + fail : "all PASS (" + pass + ")"));
  process.exit(fail ? 1 : 0);
}
main().catch((e) => { console.error("UNCAUGHT " + (e && e.stack || e)); process.exit(1); });
