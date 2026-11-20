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
  const ac = new AbortController();
  const timer = setTimeout(() => { try { ac.abort(); } catch (e) {} }, 12000);
  try {
    const res = await fetch(HUB + path, Object.assign({ cache: "no-store", signal: ac.signal }, opts || {}));
    return res;
  } finally {
    clearTimeout(timer);
  }
}

async function hubControl(action, extra) {
  const body = Object.assign({ action: action }, extra || {});
  const res = await hubFetch("/control", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  let data = {};
  try { data = await res.json(); } catch (e) {}
  if (!res.ok || (data && data.ok === false)) {
    return { ok: false, error: (data && data.error) || ("http_" + res.status), detail: (data && data.detail) || "" };
  }
  return { ok: true, data: data };
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
      n: c.participants_count || 0, mg: !!c.megagroup, bc: !!c.broadcast,
      h: String(c.access_hash || ""), k: (c._ === "channel" ? "channel" : "chat")
    }));
    window.__dshRes = JSON.stringify({ ok: true, v: list });
  })().catch(e => { window.__dshRes = JSON.stringify({ ok: false, e: String(e && e.message || e) }); });
}

function pageJoin(p) {
  window.__dshRes = null;
  (async () => {
    const am = rootScope.managers.apiManager;
    let chat = null;
    if (p.chatId && p.hash) {
      chat = { _: (p.kind === "chat" ? "chat" : "channel"), id: p.chatId, access_hash: p.hash, join_request: false };
    } else if (p.u) {
      const r = await am.invokeApi("contacts.resolveUsername", { username: p.u });
      chat = (r.chats && r.chats[0]) || null;
    }
    if (!chat) { window.__dshRes = JSON.stringify({ ok: true, v: "not_found" }); return; }
    // 需审批的群一律不申请（Telegram 会在 chat.join_request 上标记）
    if (chat.join_request) { window.__dshRes = JSON.stringify({ ok: true, v: "approval" }); return; }
    // 近 N 天无聊天记录的群视为死群，直接跳过（用户口径：小群粘性更高，但必须活着）
    if (p.recentDays > 0) {
      try {
        const peer = chat._ === "channel"
          ? { _: "inputPeerChannel", channel_id: chat.id, access_hash: chat.access_hash }
          : { _: "inputPeerChat", chat_id: chat.id };
        const h = await am.invokeApi("messages.getHistory", {
          peer: peer, offset_id: 0, offset_date: 0, add_offset: 0, limit: 1, max_id: 0, min_id: 0, hash: 0
        });
        const last = (h.messages && h.messages[0] && h.messages[0].date) || 0;
        const cutoff = Math.floor(Date.now() / 1000) - p.recentDays * 86400;
        if (!last || last < cutoff) {
          window.__dshRes = JSON.stringify({ ok: true, v: "stale", last: last });
          return;
        }
      } catch (e) { }
    }
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
      window.__dshRes = JSON.stringify({ ok: true, v, e: (v.indexOf("err:") === 0 ? m : "") });
    }
  })().catch(e => { window.__dshRes = JSON.stringify({ ok: false, e: String(e && e.message || e) }); });
}

// —— 主循环 ——
async function tick() {
  tick.fails = tick.fails || 0;
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
        const qenc = encodeURIComponent(task.query);
        const url = "https://www.facebook.com/search/groups/?q=" + qenc;
        await chrome.tabs.update(tab.id, { url });
        await waitTab(tab.id, 20000);
        // FB 的搜索结果页是 SPA：仅改 URL 不会重新发查询，必须整页硬刷新
        try { await chrome.tabs.reload(tab.id, { bypassCache: true }); } catch (e) {}
        await waitTab(tab.id, 25000);
        await sleep(1500);
        // 等 URL 真的带上本次关键词（SPA 会先渲染上一个查询的结果，导致「每次 raw 都一样」）
        for (let w = 0; w < 12; w++) {
          await sleep(700);
          let cur = "";
          try { const tb = await chrome.tabs.get(tab.id); cur = decodeURIComponent(tb.url || ""); } catch (e) {}
          if (cur.indexOf(task.query) >= 0) { break; }
        }
        await sleep(2800);
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
          try { await chrome.tabs.update(tab.id, { url: "https://www.facebook.com/search/groups/?q=" + encodeURIComponent(task.q), active: true }); } catch (_) { await chrome.tabs.update(tab.id, { url: "https://www.facebook.com/search/groups/?q=" + encodeURIComponent(task.q) }); }
          try { await chrome.windows.update(tab.windowId, { focused: true }); } catch (_) {}
          await waitTab(tab.id, 20000);
          await sleep(5000);
        } else {
          // 池化直加的候选来自「发现页」，必须先回到发现页再找卡片，否则注定 not_found
          try { await chrome.tabs.update(tab.id, { url: "https://www.facebook.com/groups/discover/", active: true }); } catch (_) { await chrome.tabs.update(tab.id, { url: "https://www.facebook.com/groups/discover/" }); }
          try { await chrome.windows.update(tab.windowId, { focused: true }); } catch (_) {}
          await waitTab(tab.id, 25000);
          await sleep(4500);
        }
        if (task.navUrl) {
          try { await chrome.tabs.update(tab.id, { url: task.navUrl, active: true }); } catch (_) { await chrome.tabs.update(tab.id, { url: task.navUrl }); }
          try { await chrome.windows.update(tab.windowId, { focused: true }); } catch (_) {}
          await waitTab(tab.id, 25000);
          await sleep(3500);
          await injectAndWait(tab.id, pageFBJoinDirect, [{ id: task.chatId, title: task.title }]);
        } else {
          await injectAndWait(tab.id, pageFBJoin, [{ id: task.chatId, title: task.title }]);
        }
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
    (async () => {
      try {
        const r = await hubControl("start", { source: "ui" });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        await setState({ running: true, stats: { joined: 0, failed: 0, skipped: 0 } });
        ensureAlarm();
        tick();
        sendResponse({ ok: true });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "members_start") {
    (async () => {
      try {
        const r = await hubControl("members_start", { platform: msg.platform || "", target: msg.target || "", trial: !!msg.trial });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "members_stop") {
    (async () => {
      try {
        const r = await hubControl("members_stop", { platform: msg.platform || "" });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "stop_run") {
    (async () => {
      try {
        const r = await hubControl("round_stop", { run_id: msg.run_id || "" });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        await setState({ running: false });
        stopLoop();
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "skip_platform") {
    (async () => {
      try {
        const r = await hubControl("skip_platform", { run_id: msg.run_id || "", platform: msg.platform || "" });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        await setState({ running: false });
        stopLoop();
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "emergency_stop") {
    (async () => {
      try {
        const r = await hubControl("stop", { run_id: msg.run_id || "" });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        await setState({ running: false });
        stopLoop();
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "clear_stop") {
    (async () => {
      try {
        const r = await hubControl("clear_stop", { });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
    return true;
  }
  if (msg && msg.type === "stop") {
    // Legacy message -> emergency stop.
    (async () => {
      try {
        const r = await hubControl("stop", { run_id: msg.run_id || "" });
        if (!r.ok) { sendResponse({ ok: false, error: r.error, detail: r.detail }); return; }
        await setState({ running: false });
        stopLoop();
        sendResponse({ ok: true, data: r.data });
      } catch (e) {
        sendResponse({ ok: false, error: "hub_unreachable", detail: String((e && e.message) || e) });
      }
    })();
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
    for (let i = 0; i < 10; i++) {
      el = el.parentElement; if (!el) break;
      const t = el.innerText || "";
      // 不再依赖 role=button（FB 现在把「访问」渲染成 <a>），只要求卡片里带成员数
      if (t.length > 20 && /(位?成员|members)/i.test(t) && t.length < 1200) { card = el; break; }
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
    const bt = card.innerText || "";
    const joinable = /(^|\n)\s*(加入|Join|加入小组)\s*($|\n)/.test(bt);
    const joined = /(^|\n)\s*(访问|已加入|View|已申请|Joined)\s*($|\n)/.test(bt);
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

// 只对「已确认是目标群」的页面主区域操作；目标不明/无目标按钮/已待审批 => 零点击
function pageFBJoinDirect(arg) {
  const done = (v, e) => { window.__dshRes = JSON.stringify({ ok: v !== "err", v, e: e || "" }); };
  const norm = s => String(s || "").replace(/\s+/g, " ").trim();
  const want = norm(arg && arg.id);
  const title = norm(arg && arg.title).toLowerCase();
  const label = b => norm(b.innerText);
  const clickables = root => [...root.querySelectorAll('a, div[role="button"], span[role="button"]')];
  const mainEl = () => document.querySelector('[role="main"]');
  // 精确取 /groups/<segment>；/groups/1234 不能匹配目标 123
  const segOf = href => {
    const s = String(href || "");
    const p = s.replace(/^[a-z][a-z0-9+.-]*:\/\/[^/]+/i, "").split(/[?#]/)[0];
    const m = p.match(/^\/groups\/([^/]+)(?:\/|$)/);
    if (!m) return "";
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  };
  const pendingRe = /(已申请|取消申请|取消请求|Requested|Pending|Request sent|Cancel request)/i;
  const joinedRe = /(已加入|Joined)/i;
  const joinRe = /^(加入小组|加入|Join group|Join)$/i;
  const requestJoinRe = /^(Request to join|申请加入|请求加入)$/i;
  const visitRe = /^(访问|Visit)$/i;
  const recRe = /(推荐小组|推荐|Suggested for you|Suggested|People you may)/i;
  const segsIn = root => [...root.querySelectorAll('a[href*="/groups/"]')]
    .map(a => segOf(a.getAttribute("href") || "")).filter(Boolean);
  // 可核验的目标群头部：标题匹配 + 同一头部范围内出现目标动作行；
  // 成员数所在浅层容器不够，必须向上找到包含动作行的共同祖先；推荐/异群祖先一律排除。
  const inForeignLink = b => {
    let el = b;
    for (let i = 0; i < 4 && el; i++) {
      const href = el.getAttribute && el.getAttribute("href");
      if (href) { const s = segOf(href); if (s && s !== want) return true; }
      el = el.parentElement;
    }
    return false;
  };
  const inRec = b => {
    let el = b;
    for (let i = 0; i < 10 && el; i++) {
      if (el.getAttribute && el.getAttribute("role") === "main") break;
      const tx = norm(el.innerText);
      if (recRe.test(tx) || isArticle(el)) return true;
      el = el.parentElement;
    }
    return false;
  };
  const safeActs = root => clickables(root).filter(b => !inForeignLink(b) && !inRec(b));
  const actionIn = root => {
    const tx = norm(root.innerText);
    if (pendingRe.test(tx) || joinedRe.test(tx) || /Request to join|申请加入/i.test(tx)) return true;
    return safeActs(root).some(b => joinRe.test(label(b)) || visitRe.test(label(b)) || requestJoinRe.test(label(b)) || pendingRe.test(label(b)) || joinedRe.test(label(b)));
  };
  const targetActions = root => safeActs(root).filter(b => {
    const t = label(b);
    return joinRe.test(t) || visitRe.test(t) || requestJoinRe.test(t);
  });
  const isNumSeg = s => /^\d+$/.test(String(s || ""));
  // 标题+成员数块（tb）是目标身份证据；块内允许出现异群链接，但 numeric alias
  // 必须唯一。URL 若为 numeric，只有这里能证明它属于同一个目标。
  const titleInfo = m => {
    if (!title) return null;
    const hs = [...m.querySelectorAll('h1, h2, h3, [role="heading"]')];
    for (const h of hs) {
      const ht = norm(h.innerText).toLowerCase();
      if (!ht) continue;
      if (ht !== title && ht.indexOf(title) === -1) continue;
      let el = h, tb = null;
      for (let i = 0; i < 6 && el && el !== m; i++) {
        const tx = norm(el.innerText);
        if (tx.length > 1500 || recRe.test(tx) || isArticle(el)) break;
        if (/(位成员|members)/i.test(tx)) { tb = el; break; }
        el = el.parentElement;
      }
      if (!tb) {
        // 简化页面可能没有成员数：只接受 h1 的直接父容器，且动作就在其中。
        const hp = h.parentElement;
        if (hp && hp !== m && !recRe.test(norm(hp.innerText)) && !isArticle(hp) && actionIn(hp)) {
          const segs = [...new Set(segsIn(hp))];
          const nums = segs.filter(isNumSeg);
          const al = nums.length === 1 ? nums[0] : "";
          const foreign = segs.some(s => s !== want && s !== al);
          if (!foreign) return { h, tb: hp, alias: al, foreign: false, simple: true };
        }
        continue;
      }
      const segs = [...new Set(segsIn(tb))];
      const nums = segs.filter(isNumSeg);
      const al = nums.length === 1 ? nums[0] : "";
      return { h, tb, alias: al, foreign: segs.some(s => s !== want && s !== al), simple: false };
    }
    return null;
  };
  // 从 title 块向上最多 8 层，取“最小且唯一动作”的头部祖先。
  // 异群/推荐/帖子动作都过滤；有两个候选动作即视为不确定，零点击。
  // pending 只在“强 pending 文案”或“title 块无异群链接时的取消按钮”上成立，
  // 避免把只有取消请求、但标题块混入异群链接的页面误判为目标待审批。
  const pendingStrongRe = /(已申请|取消申请|请求已发送|Request sent|Requested|Pending)/i;
  const headerInfo = (m, ti) => {
    if (!ti) return null;
    let el = ti.tb, visited = null;
    for (let i = 0; i < 8 && el && el !== m; i++) {
      const tx = norm(el.innerText);
      if (tx.length > 2000 || recRe.test(tx) || isArticle(el)) break;
      const hasCancel = safeActs(el).some(b => cancelRe.test(label(b)));
      if (pendingStrongRe.test(tx) || (hasCancel && !ti.foreign)) return { hc: el, kind: "pending", alias: ti.alias };
      if (joinedRe.test(tx)) return { hc: el, kind: "joined", alias: ti.alias };
      const acts = targetActions(el);
      if (acts.length > 1) {
        if (acts.every(b => requestJoinRe.test(label(b)))) return { hc: el, kind: "approval", alias: ti.alias };
        return null;
      }
      if (acts.length === 1) {
        const b = acts[0], lb = label(b);
        if (joinRe.test(lb)) return { hc: el, join: b, alias: ti.alias };
        if (requestJoinRe.test(lb)) return { hc: el, kind: "approval", alias: ti.alias };
        if (visitRe.test(lb) && !visited) visited = { hc: el, kind: "visited", alias: ti.alias };
      }
      el = el.parentElement;
    }
    if (!ti.foreign) return { hc: ti.tb, alias: ti.alias };
    return visited;
  };
  // 只读的 target-pending 识别：真实页面把「你的加入请求待审核」放在头部横幅，
  // 取消请求在标题行之外的兄弟行；标题+成员数块还可能含异群链接。
  // 必须同时满足：唯一匹配标题的 h1 + 目标头部范围内的待审横幅 + 对应取消按钮。
  // 只在目标 header 祖先容器内确认，推荐卡/帖子容器一律拒绝；绝不点击任何按钮。
  const bannerRe = /(你的加入请求待审核|加入请求待审核|Your join request is pending|Join request pending)/i;
  const cancelRe = /^(取消请求|Cancel request|取消申请)$/i;
  const isArticle = el => {
    try {
      if (el.getAttribute && el.getAttribute("role") === "article") return true;
      return el.querySelectorAll && el.querySelectorAll('[role="article"]').length > 0;
    } catch (e) { return true; }
  };
  const pendingCtx = m => {
    if (!title) return null;
    const hs = [...m.querySelectorAll('h1')].filter(h => {
      const ht = norm(h.innerText).toLowerCase();
      return ht && (ht === title || ht.indexOf(title) !== -1);
    });
    if (hs.length !== 1) return null;
    const h = hs[0];
    const cands = [...m.querySelectorAll('div,span')].filter(el => bannerRe.test(el.innerText || ""));
    for (const b of cands) {
      let el = b.parentElement;
      for (let i = 0; i < 10 && el && el !== m; i++) {
        const tx = norm(el.innerText);
        if (tx.length > 1200) break;
        if (recRe.test(tx)) break;
        if (isArticle(el)) break;
        const hasHeading = [...el.querySelectorAll('h1')].indexOf(h) !== -1;
        const hasCancel = clickables(el).some(x => cancelRe.test(label(x)));
        if (hasHeading && hasCancel) return el;
        el = el.parentElement;
      }
    }
    return null;
  };
  let tries = 0;
  const step = () => {
    if (!want) { done("not_found", "target_unknown"); return; }
    const m = mainEl();
    if (!m) {
      tries++;
      if (tries > 8) { done("not_found", "target_main_missing"); return; }
      setTimeout(step, 1000); return;
    }
    const ti = titleInfo(m);
    const cur = segOf(location.href);
    if (cur !== want) {
      const aliasOk = isNumSeg(cur) && ti && ti.alias && cur === ti.alias;
      if (!aliasOk) {
        tries++;
        if (tries > 8) { done("not_found", "target_url_mismatch"); return; }
        setTimeout(step, 1000); return;
      }
    }
    const pc = pendingCtx(m);
    if (pc) { done("request_sent", "pending_no_click"); return; }
    const hi = headerInfo(m, ti);
    if (!hi) {
      tries++;
      if (tries > 6) { done("not_found", cur !== want ? "target_url_mismatch" : "no_target_header"); return; }
      setTimeout(step, 900); return;
    }
    const hc = hi.hc;
    const txt = norm(hc.innerText);
    if (hi.kind === "pending") { done("request_sent", "pending_no_click"); return; }
    if (hi.kind === "joined" || joinedRe.test(txt)) { done("already", "already_member"); return; }
    if (hi.kind === "approval" || /Request to join|申请加入/i.test(txt)) { done("approval", "request_to_join_no_click"); return; }
    if (/非公开|Private group/i.test(txt)) { done("approval", "private_group"); return; }
    const join = hi.join;
    if (!join) {
      if (hi.kind === "visited" || safeActs(hc).some(b => visitRe.test(label(b)))) { done("visited", "member_visit_only"); return; }
      tries++;
      if (tries > 6) { done("not_found", "no_join_on_target_header"); return; }
      setTimeout(step, 900); return;
    }
    try { join.click(); } catch (e) { done("err", "click_failed"); return; }
    let wait = 0;
    const verify = () => {
      wait++;
      const dl = [...document.querySelectorAll('div[role="dialog"]')];
      for (const d of dl) {
        const dt = (d.innerText || "");
        if (/(加入小组|问题|Questions|回答|Submit|提交)/i.test(dt) && dt.length > 10) {
          const c = [...d.querySelectorAll('div[role="button"],a')].find(b => /^(关闭|Close|取消|Cancel)$/i.test(label(b)));
          if (c) { try { c.click(); } catch (e) {} }
          done("approval", "question_dialog");
          return;
        }
      }
      if (pendingCtx(m)) { done("request_sent", "request_sent"); return; }
      const ti2 = titleInfo(m), hi2 = headerInfo(m, ti2);
      const curHi = hi2 || { hc: hc };
      const t2 = norm(curHi.hc.innerText);
      if (hi2 && hi2.kind === "pending") { done("request_sent", "request_sent"); return; }
      if (hi2 && hi2.kind === "approval" || /Request to join|申请加入/i.test(t2)) { done("approval", "request_to_join_no_click"); return; }
      if (hi2 && hi2.kind === "joined" || joinedRe.test(t2)) { done("joined", "joined_by_page"); return; }
      if (hi2 && hi2.kind === "visited" || safeActs(curHi.hc).some(b => visitRe.test(label(b)))) { done("visited", "member_visit_only"); return; }
      if (wait > 10) { done("unknown", "no_state_change"); return; }
      setTimeout(verify, 900);
    };
    setTimeout(verify, 1400);
  };
  step();
}

function pageFBJoin(arg) {
  const done = (v, e) => { window.__dshRes = JSON.stringify({ ok: v !== "err", v, e: e || "" }); };
  const norm = s => String(s || "").replace(/\s+/g, " ").trim();
  const want = norm(arg && arg.id);
  const title = norm(arg && arg.title).toLowerCase();
  const label = b => norm(b.innerText);
  const clickables = root => [...root.querySelectorAll('a, div[role="button"], span[role="button"]')];
  // 精确取 /groups/<segment>；/groups/1111 不能匹配目标 111
  const segOf = href => {
    const s = String(href || "");
    const p = s.replace(/^[a-z][a-z0-9+.-]*:\/\/[^/]+/i, "").split(/[?#]/)[0];
    const m = p.match(/^\/groups\/([^/]+)(?:\/|$)/);
    if (!m) return "";
    try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
  };
  const pendingRe = /(已申请|取消申请|取消请求|Requested|Pending|Request sent|Cancel request)/i;
  const joinedRe = /(已加入|Joined)/i;
  const joinRe = /^(加入小组|加入|Join group|Join)$/i;
  const requestJoinRe = /^(Request to join|申请加入|请求加入)$/i;
  const visitRe = /^(访问|Visit)$/i;
  const recRe = /(推荐小组|推荐|Suggested for you|Suggested|People you may)/i;
  const actionIn = root => {
    const tx = norm(root.innerText);
    if (pendingRe.test(tx) || joinedRe.test(tx) || /Request to join|申请加入/i.test(tx)) return true;
    return clickables(root).some(b => joinRe.test(label(b)) || visitRe.test(label(b)) || requestJoinRe.test(label(b)) || pendingRe.test(label(b)) || joinedRe.test(label(b)));
  };
  let tries = 0;

  // 成员数可能在浅层标题行，取消请求/已加入在兄弟动作行，必须向上找到含动作行的共同祖先。
  const findTargetCard = () => {
    const as = [...document.querySelectorAll('a[href*="/groups/"]')];
    for (const a of as) {
      if (segOf(a.getAttribute("href") || "") !== want) continue;
      let el = a, fallback = null;
      for (let i = 0; i < 12; i++) {
        el = el.parentElement; if (!el) break;
        const tx = norm(el.innerText);
        if (tx.length <= 20 || tx.length >= 800) continue;
        if (!/(位成员|members)/i.test(tx)) continue;
        const segs = [...el.querySelectorAll('a[href*="/groups/"]')]
          .map(x => segOf(x.getAttribute("href") || "")).filter(Boolean);
        const uniq = [...new Set(segs)];
        if (uniq.length !== 1 || uniq[0] !== want) continue;
        if (title && tx.toLowerCase().indexOf(title) === -1) continue;
        if (!fallback) fallback = el;
        if (recRe.test(tx)) break;
        if (actionIn(el)) return el;
      }
      if (fallback) return fallback;
    }
    return null;
  };
  // 旧版仅取首个成员数容器，保留对照，不再调用。
  // 卡片必须：精确群 ID、单一群 ID、成员数、标题可核验（若有标题）
  const findCard = () => {
    const as = [...document.querySelectorAll('a[href*="/groups/"]')];
    for (const a of as) {
      const h = a.getAttribute("href") || "";
      if (segOf(h) !== want) continue;
      let el = a;
      for (let i = 0; i < 10; i++) {
        el = el.parentElement; if (!el) break;
        const tx = norm(el.innerText);
        if (tx.length <= 20 || tx.length >= 800) continue;
        if (!/(位成员|members)/i.test(tx)) continue;
        const segs = [...el.querySelectorAll('a[href*="/groups/"]')]
          .map(x => segOf(x.getAttribute("href") || "")).filter(Boolean);
        const uniq = [...new Set(segs)];
        if (uniq.length !== 1 || uniq[0] !== want) continue;
        if (title && tx.toLowerCase().indexOf(title) === -1) continue;
        return el;
      }
    }
    return null;
  };

  const findJoin = card => clickables(card).find(b => joinRe.test(label(b))) || null;

  let tops = 0;
  const step = () => {
    if (!want) { done("not_found", "target_unknown"); return; }
    const card = findTargetCard();
    if (!card) {
      tries++;
      if (tries === 1) { window.scrollTo(0, 0); setTimeout(step, 700); return; }
      if (tries > 8) {
        if (tops < 1) { tops++; tries = 0; window.scrollTo(0, 0); setTimeout(step, 900); return; }
        done("not_found", "card_not_found:" + want); return;
      }
      window.scrollBy(0, 700);
      setTimeout(step, 900);
      return;
    }
    const txt = norm(card.innerText);
    if (pendingRe.test(txt)) { done("request_sent", "pending_no_click"); return; } if (/非公开|Private group/i.test(txt)) { done("approval", "private_group"); return; }
    if (pendingRe.test(txt)) { done("request_sent", "pending_no_click"); return; }
    if (joinedRe.test(txt)) { done("already", "already_member"); return; }
    // Request to join / 申请加入 是待审批入口，不是可直接点击的加入按钮
    if (/Request to join|申请加入/i.test(txt)) { done("approval", "request_to_join_no_click"); return; }
    const acts = clickables(card);
    if (acts.some(b => requestJoinRe.test(label(b)))) { done("approval", "request_to_join_no_click"); return; }
    const jb = findJoin(card);
    if (!jb) {
      // 不在卡片外层找按钮：外层可能是别的推荐小组
      if (/(访问|Visit)/.test(txt)) { done("visited", "member_visit_only"); return; }
      done("not_found", "no_join_in_target_card");
      return;
    }
    try { jb.click(); } catch (e) { done("err", "click_failed"); return; }
    let wait = 0;
    const verify = () => {
      wait++;
      // 加入后可能弹出「入群问答」：识别到就立刻返回 approval，不提交答案
      const dlgs = [...document.querySelectorAll('div[role="dialog"]')];
      for (const d of dlgs) {
        const dt = (d.innerText || "");
        if (/(加入小组|问题|Questions|回答|Submit|提交)/i.test(dt) && dt.length > 10) {
          const closeBtn = [...d.querySelectorAll('div[role="button"],a')].find(b => /^(关闭|Close|取消|Cancel)$/i.test(label(b)));
          if (closeBtn) { try { closeBtn.click(); } catch (e) {} }
          done("approval", "question_dialog");
          return;
        }
      }
      const now = norm(card.innerText);
      if (/Request to join|申请加入/i.test(now)) { done("approval", "request_to_join_no_click"); return; }
      if (joinedRe.test(now)) { done("joined", "joined_by_page"); return; }
      if (pendingRe.test(now)) { done("request_sent", "request_sent"); return; }
      if (/(访问|Visit)/.test(now)) { done("visited", "member_visit_only"); return; }
      if (wait > 14) { done("unknown", "no_state_change"); return; }
      setTimeout(verify, 1500);
    };
    setTimeout(verify, 1600);
  };

  step();
}