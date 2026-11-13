// background.js —— 调度循环：向本地 hub 取任务 → 在页面里执行 → 回传结果
const HUB = "http://127.0.0.1:8787";
let timer = null;
let busy = false;

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function getState() {
  const s = await chrome.storage.local.get(["running", "stats", "lastLog"]);
  return { running: !!s.running, stats: s.stats || { joined: 0, failed: 0, skipped: 0 }, lastLog: s.lastLog || "" };
}
async function setState(patch) { await chrome.storage.local.set(patch); }

async function hubFetch(path, opts) {
  const res = await fetch(HUB + path, Object.assign({ cache: "no-store" }, opts || {}));
  return res;
}

async function findTab(platform) {
  const pf = String(platform || "").toLowerCase();
  const key = pf === "facebook" ? "facebook.com"
            : pf === "reddit" ? "reddit.com"
            : "web.telegram.org";
  let tabs = [];
  try { tabs = await chrome.tabs.query({}); } catch (e) { tabs = []; }
  const hit = tabs.filter(x => (x.url || "").includes(key));
  const t = hit.find(x => x.status !== "discarded") || hit[0];
  if (!t) await log("no tab for " + platform + " (tabs=" + tabs.length + ")");
  return t || null;
}

// —— 注入并等待：页面里写 window.__dshRes，这里轮询读回 ——
async function injectAndWait(tabId, func, args, timeoutMs) {
  const limit = timeoutMs || 20000;
  try {
    await chrome.scripting.executeScript({ target: { tabId }, world: "MAIN", func, args: args || [] });
  } catch (e) {
    // 页面在授权变更前就已打开时会报 "manifest must request permission"，重载一次后重试即可
    if (String((e && e.message) || "").indexOf("must request permission") >= 0) {
      await log("tab " + tabId + " 需重载以生效权限，正在重载…");
      try { await chrome.tabs.reload(tabId); } catch (_) {}
      await sleep(4000);
      await chrome.scripting.executeScript({ target: { tabId }, world: "MAIN", func, args: args || [] });
    } else { throw e; }
  }
  const started = Date.now();
  while (Date.now() - started < limit) {
    await sleep(250);
    const [r] = await chrome.scripting.executeScript({
      target: { tabId }, world: "MAIN",
      func: () => (window.__dshRes === undefined ? null : window.__dshRes)
    });
    if (r && r.result) return JSON.parse(r.result);
  }
  throw new Error("page timeout");
}

// —— 具体页面动作 ——
function pageProbe() {
  window.__dshRes = null;
  (async () => {
    const am = rootScope && rootScope.managers && rootScope.managers.apiManager;
    let self = null;
    if (am) {
      const r = await am.invokeApi("users.getFullUser", { id: { _: "inputUserSelf" } });
      self = String(r.users[0].id);
    }
    window.__dshRes = JSON.stringify({ ok: true, v: { loggedIn: !!am, self } });
  })().catch(e => { window.__dshRes = JSON.stringify({ ok: false, e: String(e && e.message || e) }); });
}

function pageSearch(p) {
  window.__dshRes = null;
  (async () => {
    const am = rootScope.managers.apiManager;
    const r = await am.invokeApi("contacts.search", { q: p.q, limit: p.limit || 20 });
    const list = (r.chats || []).map(c => ({
      id: String(c.id), title: c.title || "", u: c.username || "",
      n: c.participants_count || 0, mg: !!c.megagroup, bc: !!c.broadcast
    }));
    window.__dshRes = JSON.stringify({ ok: true, v: list });
  })().catch(e => { window.__dshRes = JSON.stringify({ ok: false, e: String(e && e.message || e) }); });
}

function pageJoin(p) {
  window.__dshRes = null;
  (async () => {
    const am = rootScope.managers.apiManager;
    let chat = null;
    if (p.u) {
      const r = await am.invokeApi("contacts.resolveUsername", { username: p.u });
      chat = (r.chats && r.chats[0]) || null;
    }
    if (!chat) { window.__dshRes = JSON.stringify({ ok: true, v: "not_found" }); return; }
    // 需审批的群一律不申请（Telegram 会在 chat.join_request 上标记）
    if (chat.join_request) { window.__dshRes = JSON.stringify({ ok: true, v: "approval" }); return; }
    try {
      if (chat._ === "channel") {
        await am.invokeApi("channels.joinChannel", {
          channel: { _: "inputChannel", channel_id: chat.id, access_hash: chat.access_hash }
        });
      } else {
        await am.invokeApi("messages.addChatUser", {
          chat_id: { _: "inputChat", chat_id: chat.id, access_hash: chat.access_hash },
          user_id: p.self, fwd_limit: 0
        });
      }
      window.__dshRes = JSON.stringify({ ok: true, v: "joined" });
    } catch (e) {
      const m = String(e && e.message || e);
      let v = "err:" + m;
      if (m.indexOf("USER_ALREADY_PARTICIPANT") >= 0) v = "already";
      else if (m.indexOf("INVITE_REQUEST_SENT") >= 0) v = "request_sent";
      else if (m.indexOf("FLOOD_WAIT") >= 0) v = "flood";
      window.__dshRes = JSON.stringify({ ok: true, v });
    }
  })().catch(e => { window.__dshRes = JSON.stringify({ ok: false, e: String(e && e.message || e) }); });
}

// —— 主循环 ——
async function tick() {
  if (busy) return;
  busy = true;
  try {
    let hubRunning = false;
    try {
      const hres = await hubFetch("/health");
      if (hres.ok) { const h = await hres.json(); hubRunning = !!(h && h.running); }
    } catch (e) {}
    const st = await getState();
    if (!hubRunning) { if (st.running) await setState({ running: false }); return; }
    if (!st.running) { await setState({ running: true, joined: st.joined || 0 }); }

    // 领取任务前先确保会话可用（自愈 + 失败告警），最多每 30 秒探一次
    if (!tick.lastHeal || Date.now() - tick.lastHeal > 30000) {
      tick.lastHeal = Date.now();
      try { await ensureTg(); } catch (e) {}
      try { await ensureFb(); } catch (e) {}
    }

    const res = await hubFetch("/task");
    if (res.status === 204) return;
    if (!res.ok) return;
    const task = await res.json();
    if (!task || !task.action) return;

    const tab = await findTab(task.platform || "telegram");
    if (!tab) {
      await log("no tab for " + (task.platform || "telegram"));
      await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ kind: task.action, id: task.id, ok: false, error: "no_tab" }) });
      return;
    }

    if (task.action === "probe") {
      if (String(task.platform || "").toLowerCase() === "facebook") {
        await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ kind: "probe", id: task.id, ok: true, value: { self: "fb" } }) });
        return;
      }
      await injectAndWait(tab.id, pageProbe, []);
      const r = await readRes(tab.id);
      await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ kind: "probe", id: task.id, ok: !!(r && r.ok), value: r && r.v }) });
      return;
    }

    if (task.action === "search") {
      if (String(task.platform || "").toLowerCase() === "facebook") {
        const url = "https://www.facebook.com/search/groups/?q=" + encodeURIComponent(task.query);
        await chrome.tabs.update(tab.id, { url });
        await waitTab(tab.id, 20000);
        await sleep(3500);
        await injectAndWait(tab.id, pageFBFilter, []).catch(function(){});
        await sleep(1200);
        await injectAndWait(tab.id, pageFBExtract, [{ scroll: 3 }], 45000);
        let r0 = await readRes(tab.id);
        if (!r0 || !r0.ok || !(r0.v && r0.v.length)) {
          await sleep(3000);
          await injectAndWait(tab.id, pageFBExtract, [{ scroll: 2 }], 45000);
        }
      } else {
        await injectAndWait(tab.id, pageSearch, [{ q: task.query, limit: task.limit || 20 }]);
      }
      const r = await readRes(tab.id);
      await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ kind: "search", id: task.id, ok: !!(r && r.ok), value: (r && r.v) || [], error: r && r.e }) });
      return;
    }

    if (task.action === "join") {
      if (String(task.platform || "").toLowerCase() === "facebook") {
        if (task.q) {
          await chrome.tabs.update(tab.id, { url: "https://www.facebook.com/search/groups/?q=" + encodeURIComponent(task.q) });
          await waitTab(tab.id, 20000);
          await sleep(5000);
        }
        await injectAndWait(tab.id, pageFBJoin, [{ id: task.chatId, title: task.title }]);
      } else {
        await injectAndWait(tab.id, pageJoin, [{ u: task.u, id: task.chatId, self: task.self }]);
      }
      const r = await readRes(tab.id);
      const v = (r && r.v) || "err";
      const stats = st.stats;
      if (v === "joined" || v === "already") stats.joined++;
      else if (v === "request_sent") stats.skipped++;
      else stats.failed++;
      await setState({ stats });
      await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ kind: "join", id: task.id, ok: !!r && r.ok, value: v, error: r && r.e,
          target: { id: task.chatId, u: task.u, title: task.title, n: task.n } }) });
      return;
    }
  } catch (e) {
    await log("tick error: " + String(e && e.message || e));
  } finally {
    busy = false;
    scheduleNext(2500);
  }
}

async function readRes(tabId) {
  const [r] = await chrome.scripting.executeScript({
    target: { tabId }, world: "MAIN",
    func: () => window.__dshRes
  });
  if (!r || !r.result) return null;
  try { return JSON.parse(r.result); } catch { return null; }
}

async function log(msg) {
  await setState({ lastLog: new Date().toLocaleTimeString() + " " + msg });
  try {
    await hubFetch("/log", { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ msg, ts: Date.now() }) });
  } catch {}
}

// —— 调度：service worker 会被回收，不能靠 setInterval 长驻；用 alarm 兜底 + setTimeout 接力 ——
let chainTimer = null;
function scheduleNext(ms) {
  if (chainTimer) { clearTimeout(chainTimer); chainTimer = null; }
  chainTimer = setTimeout(() => { tick(); }, ms);
}
function ensureAlarm() {
  try { chrome.alarms.create("tick", { periodInMinutes: 0.5 }); } catch (e) {}
}
function stopLoop() {
  if (chainTimer) { clearTimeout(chainTimer); chainTimer = null; }
  try { chrome.alarms.clear("tick"); } catch (e) {}
}
try {
  chrome.alarms.onAlarm.addListener((a) => { if (a && a.name === "tick") tick(); });
} catch (e) {}

// —— 会话自愈：重载页面 / 重开标签页，仍失败则告警 ——
const HEAL = { tg: 0, fb: 0, tgFail: 0, fbFail: 0 };
const HEAL_GAP = 90 * 1000;

async function ensureTg() {
  const st = await probeTgAlive();
  if (st === "alive") { HEAL.tgFail = 0; return "alive"; }
  if (st === "no-tab") {
    try {
      await chrome.tabs.create({ url: "https://web.telegram.org/k/", active: false });
      await log("自愈：已重新打开 Telegram 标签页，等待登录");
    } catch (e) {}
    return "reopened";
  }
  const now = Date.now();
  if (now - HEAL.tg > HEAL_GAP) {
    HEAL.tg = now;
    const tab = await findTab("Telegram");
    if (tab) { try { await chrome.tabs.reload(tab.id); await log("自愈：重载 Telegram 页面"); } catch (e) {} }
    return "healing";
  }
  HEAL.tgFail++;
  if (HEAL.tgFail === 3) {
    await log("自愈失败：Telegram 重载后仍不可用，已告警");
    hubFetch("/alert", { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ level: "error", platform: "Telegram", message: "会话重载后仍不可用（help.getConfig 超时），请扫码或刷新页面" }) }).catch(function(){});
  }
  return st;
}

async function ensureFb() {
  const st = await probeFbLogin();
  if (st === "login") { HEAL.fbFail = 0; return "login"; }
  if (st === "no-tab") {
    try {
      await chrome.tabs.create({ url: "https://www.facebook.com/", active: false });
      await log("自愈：已重新打开 Facebook 标签页");
    } catch (e) {}
    return "reopened";
  }
  const now = Date.now();
  if (now - HEAL.fb > HEAL_GAP) {
    HEAL.fb = now;
    const tab = await findTab("Facebook");
    if (tab) { try { await chrome.tabs.reload(tab.id); await log("自愈：重载 Facebook 页面"); } catch (e) {} }
    return "healing";
  }
  HEAL.fbFail++;
  if (HEAL.fbFail === 3) {
    await log("自愈失败：Facebook 未登录，已告警");
    hubFetch("/alert", { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ level: "error", platform: "Facebook", message: "检测不到 c_user 登录态，重载后仍未登录" }) }).catch(function(){});
  }
  return st;
}

async function probeTgAlive() {
  const tab = await findTab("Telegram");
  if (!tab) return "no-tab";
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId: tab.id }, world: "MAIN",
      func: async () => {
        if (typeof rootScope === "undefined" || !rootScope.managers) return "no-root";
        try {
          await Promise.race([
            rootScope.managers.apiManager.invokeApi("help.getConfig", {}),
            new Promise((_, rej) => setTimeout(() => rej(new Error("t")), 3000))
          ]);
          return "alive";
        } catch (e) { return "dead"; }
      }
    });
    return (r && r.result) || "unknown";
  } catch (e) { return "blocked"; }
}
async function probeFbLogin() {
  const tab = await findTab("Facebook");
  if (!tab) return "no-tab";
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId: tab.id }, world: "MAIN",
      func: () => (document.cookie || "").indexOf("c_user=") >= 0 ? "login" : "logout"
    });
    return (r && r.result) || "unknown";
  } catch (e) { return "blocked"; }
}
async function probePerm() {
  try {
    return !!(await chrome.permissions.contains({
      origins: ["https://web.telegram.org/*", "https://www.facebook.com/*"]
    }));
  } catch (e) { return false; }
}


const PRELOAD_URLS = {
  telegram: "https://web.telegram.org/k/",
  facebook: "https://www.facebook.com/",
  discord: "https://discord.com/channels/@me",
  whatsapp: "https://web.whatsapp.com/",
  reddit: "https://www.reddit.com/",
  steam: "https://steamcommunity.com/"
};

function probeLoginFn(key) {
  try {
    if (key === "telegram") return !!(window.rootScope || document.querySelector("#column-center"));
    if (key === "facebook") return (document.cookie || "").indexOf("c_user=") >= 0;
    if (key === "discord") {
      if (document.querySelector("input[name='email']") || document.querySelector("[class*='loginForm']")) return false;
      if (document.querySelector("[class*='guilds']")) return true;
      return !!document.querySelector("[class*='sidebar']") && !!document.querySelector("[class*='chat']");
    }
    if (key === "whatsapp") return !!document.querySelector("#pane-side");
    if (key === "reddit") {
      if (document.querySelector("input[type=password]")) return false;
      return !!(document.querySelector("shreddit-app") || document.querySelector("#header") || document.querySelector("faceplate-tracker"));
    }
    if (key === "steam") {
      if (document.querySelector("a.global_action_link[href*='login']")) return false;
      return !!(document.querySelector("#account_pulldown") || document.querySelector(".playerAvatar"));
    }
  } catch (e) {}
  return false;
}

async function handlePreload(platforms, opts) {
  const recheck = !!(opts && opts.recheck);
  const out = [];
  for (const key of (platforms || [])) {
    const url = PRELOAD_URLS[key];
    if (!url) continue;
    const host = url.replace("https://", "").split("/")[0].replace("www.", "");
    let tabs = await chrome.tabs.query({});
    let tab = tabs.find(t => (t.url || "").indexOf(host) >= 0);
    let opened = false;
    if (!tab) {
      tab = await chrome.tabs.create({ url, active: false });
      opened = true;
      await new Promise(r => setTimeout(r, 3500));
    } else if (recheck) {
      try { await chrome.tabs.update(tab.id, { active: true }); } catch (e) {}
      await new Promise(r => setTimeout(r, 1200));
    }
    let logged = null, err = null;
    for (let i = 0; i < 3; i++) {
      try {
        const r = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: probeLoginFn, args: [key] });
        logged = !!(r && r[0] && r[0].result);
        break;
      } catch (e) { err = String(e && e.message || e); await new Promise(r2 => setTimeout(r2, 1500)); }
    }
    out.push({ key, url, opened, logged, error: err });
  }
  return { ok: true, results: out };
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "preload") { handlePreload(msg.platforms, { recheck: !!msg.recheck }).then(sendResponse); return true; }
  if (msg && msg.type === "start") {
    setState({ running: true, stats: { joined: 0, failed: 0, skipped: 0 } }).then(() => {
      hubFetch("/control", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: "start" }) }).catch(() => {});
      ensureAlarm();
      tick();
      sendResponse({ ok: true });
    });
    return true;
  }
  if (msg && msg.type === "stop") {
    setState({ running: false }).then(() => {
      hubFetch("/control", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: "stop" }) }).catch(() => {});
      stopLoop();
      sendResponse({ ok: true });
    });
    return true;
  }
  if (msg && msg.type === "heal") {
      (async () => {
        const tg = await ensureTg(); const fb = await ensureFb();
        sendResponse({ ok: true, tg: tg, fb: fb });
      })();
      return true;
    }
    if (msg && msg.type === "status") {
    (async () => {
      const st = await getState();
      let hub = { ok: false };
      try {
        const r = await hubFetch("/health"); if (r.ok) hub = await r.json();
      } catch (e) {}
      let cfg = null;
      try { const r2 = await hubFetch("/api/config"); if (r2.ok) cfg = await r2.json(); } catch (e) {}
      const probe = { tg: "unknown", fb: "unknown", perm: false };
      try { probe.tg = await probeTgAlive(); } catch (e) {}
      try { probe.fb = await probeFbLogin(); } catch (e) {}
      try { probe.perm = await probePerm(); } catch (e) {}
      sendResponse({ ok: true, st, hub, cfg, probe });
    })();
    return true;
  }
  if (msg && msg.type === "ticknow") { tick().then(() => sendResponse({ ok: true })); return true; }
  return false;
});

function boot() {
  ensureAlarm();
  try { chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }); } catch (e) {}
  tick();
}
chrome.runtime.onStartup.addListener(boot);
chrome.runtime.onInstalled.addListener(boot);
boot();

// ——————————————————— Facebook ———————————————————

async function waitTab(tabId, timeoutMs) {
  const limit = timeoutMs || 15000;
  const started = Date.now();
  while (Date.now() - started < limit) {
    const t = await chrome.tabs.get(tabId);
    if (t && t.status === "complete") return true;
    await sleep(300);
  }
  return false;
}

// 在当前群组搜索页里抓卡片：id / 名称 / 成员数 / 是否公开 / 加入按钮状态
// —— Reddit 适配器（预留，未实现）：接口与 FB/TG 对齐，返回空结果 ——
function pageRedditExtract() {
  window.__dshRes = { ok: true, reserved: true, adapter: "reddit", items: [], note: "reddit adapter reserved" };
}
function pageRedditJoin() {
  window.__dshRes = { ok: false, reserved: true, adapter: "reddit", result: "not_implemented" };
}
async function pageFBExtract(arg) {
  window.__dshRes = undefined;
  const rounds = (arg && arg.scroll) || 0;
  for (let r = 0; r < rounds; r++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(function (res) { setTimeout(res, 1400); });
  }
  const out = []; const seen = {};
  const as = [...document.querySelectorAll('a[href*="/groups/"]')];
  for (const a of as) {
    const h = a.getAttribute("href") || "";
    const m = h.match(/\/groups\/([A-Za-z0-9._-]+)/);
    if (!m) continue;
    const k = m[1];
    if (seen[k]) continue;
    seen[k] = 1;
    let el = a, card = null;
    for (let i = 0; i < 9; i++) {
      el = el.parentElement; if (!el) break;
      const t = el.innerText || "";
      const btns = [...el.querySelectorAll('div[role="button"]')].map(b => (b.innerText || "").trim()).filter(Boolean);
      if (t.length > 20 && btns.length > 0 && btns.length < 8) { card = el; break; }
    }
    if (!card) continue;
    const txt = card.innerText || "";
    const name = (txt.split("\n")[0] || "").trim();
    const mV = txt.match(/([\d.,]+)\s*(万|亿|K|M)?\s*位?成员/);
    let n = 0;
    if (mV) {
      n = parseFloat(String(mV[1]).replace(/,/g, ""));
      const u = mV[2];
      if (u === "万") n *= 10000; else if (u === "亿") n *= 1e8;
      else if (u === "K") n *= 1000; else if (u === "M") n *= 1e6;
    }
    const btns = [...card.querySelectorAll('div[role="button"]')].map(b => (b.innerText || "").trim());
    const joinable = btns.some(t => t === "加入" || t === "Join" || t === "加入小组");
    const joined = btns.some(t => t === "访问" || t === "已加入" || t === "View" || t === "已申请");
    out.push({ id: k, u: "", title: name, n: Math.round(n || 0), bc: joined, joinable, priv: /非公开/.test(txt) });
  }
  window.__dshRes = JSON.stringify({ ok: true, v: out });
}

function pageFBFilter() {
  const res = [];
  const sw = [...document.querySelectorAll('div[role="switch"]')];
  for (const s of sw) {
    let el = s, txt = "";
    for (let i = 0; i < 4 && el; i++) { el = el.parentElement; if (el) txt = el.innerText || txt; }
    if (/公开小组/.test(txt)) {
      const on = (s.getAttribute("aria-checked") || "").toLowerCase() === "true";
      if (!on) s.click();
      res.push({ label: "公开小组", was: on });
      break;
    }
  }
  window.__dshRes = JSON.stringify({ ok: true, v: res });
}

// 点某个群的「加入」，2.6 秒后判断结果
function pageFBJoin(arg) {
  const done = (v, e) => { window.__dshRes = JSON.stringify({ ok: v !== "err", v, e: e || "" }); };
  const want = arg.id;
  const label = b => (b.innerText || "").trim();
  let tries = 0;

  const findCard = () => {
    const as = [...document.querySelectorAll('a[href*="/groups/"]')];
    for (const a of as) {
      const h = a.getAttribute("href") || "";
      if (h.indexOf("/groups/" + want) === -1) continue;
      let el = a, card = null;
      for (let i = 0; i < 9; i++) {
        el = el.parentElement; if (!el) break;
        const tx = el.innerText || "";
        const btns = [...el.querySelectorAll('div[role="button"]')];
        if (tx.length > 20 && btns.length > 0 && btns.length < 8) { card = el; break; }
      }
      if (card) return card;
    }
    return null;
  };

  const step = () => {
    const target = findCard();
    if (!target) {
      tries++;
      if (tries > 7) { done("not_found", "card_not_found"); return; }
      window.scrollBy(0, 700);
      setTimeout(step, 900);
      return;
    }
    const cardText = target.innerText || "";
    if (/非公开/.test(cardText)) { done("approval", "private_group"); return; }
    const btns = [...target.querySelectorAll('div[role="button"]')];
    const joinBtn = btns.find(b => ["加入", "Join", "加入小组"].includes(label(b)));
    if (!joinBtn) {
      const j = btns.find(b => ["访问", "已加入", "View"].includes(label(b)));
      done(j ? "already" : "not_found", j ? "" : "no_join_button");
      return;
    }
    joinBtn.click();
    setTimeout(() => {
      const now = [...target.querySelectorAll('div[role="button"]')].map(label);
      const bodyTxt = document.body.innerText || "";
      if (now.some(t => ["待审核", "已申请", "取消请求", "已发送请求"].includes(t))) { done("request_sent"); return; }
      if (now.some(t => ["访问", "已加入", "View"].includes(t))) { done("joined"); return; }
      if (/回答.*问题|入群问题|填写.*答案|必须回答/.test(bodyTxt)) { done("request_sent", "needs_answers"); return; }
      if (now.some(t => ["加入", "Join"].includes(t))) { done("err", "still_join"); return; }
      done("joined");
    }, 2600);
  };

  step();
}