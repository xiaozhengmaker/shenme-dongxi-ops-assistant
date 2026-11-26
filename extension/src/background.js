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

// —— 页面归属判断：解析 hostname，只认同名 host 或官方子域，不做子串匹配 ——
// 反例（必须判否）：evil-telegram.org、telegram.org.evil.io、notfacebook.com
function urlHost(u) {
  try { return new URL(String(u || "")).hostname.toLowerCase(); } catch (e) { return ""; }
}
function hostMatches(hostname, want) {
  const h = String(hostname || "").toLowerCase();
  const w = String(want || "").toLowerCase();
  return !!h && !!w && (h === w || h.endsWith("." + w));
}

// 平台 → 页面 host。这里没有的平台就没有页面执行器，findTab 返回 null，绝不回落到 Telegram。
const TAB_HOSTS = {
  telegram: "web.telegram.org",
  facebook: "facebook.com",
  reddit: "reddit.com"
};
// background 只有 Telegram / Facebook 的页面执行器（probe/search/join 注入的是这两个平台的专用页面代码）。
// Reddit / WhatsApp / Steam / Discord 有各自入口（run_daily 的专用 runner），不能被当成普通 hub 任务注进别的标签页。
const TASK_EXECUTORS = { telegram: "tg", facebook: "fb" };
function executorOf(platform) {
  return TASK_EXECUTORS[String(platform || "").toLowerCase()] || null;
}

async function findTab(platform) {
  const pf = String(platform || "").toLowerCase();
  const want = TAB_HOSTS[pf];
  if (!want) { await log("no tab mapping for " + (platform || "") + " (no page executor)"); return null; }
  let tabs = [];
  try { tabs = await chrome.tabs.query({}); } catch (e) { tabs = []; }
  const hit = tabs.filter(x => hostMatches(urlHost(x && x.url), want));
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

    // 平台守卫：没有页面执行器的平台一律显式回 platform_unsupported。
    // 绝不 findTab 回落 Telegram——那会把 Reddit/WhatsApp/Steam 的任务静默跑成 TG。
    const pf = String(task.platform || "").toLowerCase();
    const ex = executorOf(pf);
    if (!ex) {
      await log("拒绝非本扩展平台任务：" + (task.platform || "?") + " " + String(task.action));
      await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ kind: task.action, id: task.id, ok: false, error: "platform_unsupported", platform: pf }) });
      return;
    }

    const tab = await findTab(pf);
    if (!tab) {
      await log("no tab for " + pf);
      await hubFetch("/result", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ kind: task.action, id: task.id, ok: false, error: "no_tab" }) });
      return;
    }

    if (task.action === "probe") {
      if (ex === "fb") {
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
      if (ex === "fb") {
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
      if (ex === "fb") {
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

// 平台显示名 / 缩写 / 大小写归一；未知和预留平台（如 Instagram）直接跳过。
const PRELOAD_ALIAS = {
  telegram: "telegram", tg: "telegram",
  facebook: "facebook", fb: "facebook",
  discord: "discord", dc: "discord",
  whatsapp: "whatsapp", wa: "whatsapp",
  reddit: "reddit", rd: "reddit",
  steam: "steam"
};
function normalizePreloadKeys(platforms) {
  const seen = {}, out = [];
  for (const raw of (platforms || [])) {
    const k = PRELOAD_ALIAS[String(raw == null ? "" : raw).trim().toLowerCase()];
    if (!k || seen[k] || !PRELOAD_URLS[k]) continue;
    seen[k] = 1;
    out.push(k);
  }
  return out;
}

// 登录态探针：只在页面里运行，返回严格三态 true / false / null。
//   true  = 有明确「已登录账户」证据（账户菜单、私聊列表等只有登录后才出现的元素）
//   false = 有明确「登录/注册表单」证据，且没有账户证据
//   null  = 没有证据（公开页、页面还没渲染、cookie 不可见等都算没有证据）→ 侧栏显示「待确认」
// 注意：不能凭公开元素（Reddit shreddit-app/#header、Steam .playerAvatar、FB cookie）下结论；
// FB 的 c_user 是 HttpOnly，document.cookie 里本来就看不到，所以不再读 cookie。
function probeLoginFn(key) {
  try {
    const doc = document;
    const hit = (list) => {
      for (let i = 0; i < list.length; i++) {
        try { if (doc && doc.querySelector(list[i])) return true; } catch (e) {}
      }
      return false;
    };
    const rules = {
      telegram: {
        in: [".chat-list", ".chatlist", "#column-center .chatlist-chat", "#column-center .chatlist-parts"],
        out: ["#auth-pages", ".auth-pages", ".auth-pages-wrapper", "#login-form", ".login-form"]
      },
      facebook: {
        in: ['[aria-label="Your profile"]', "[aria-label='你的个人主页']", '[aria-label="Account menu"]'],
        out: ["#login_form", "form[data-testid='royal_login_form']", "input[name='pass']"]
      },
      discord: {
        in: ["[class*='guilds']", "[data-list-id='guildsnav']", "[class*='chatContent']"],
        out: ["[class*='authBox']", "[class*='loginForm']", "[class*='authLogin']"]
      },
      whatsapp: {
        in: ["#pane-side", "[data-testid='chat-list']"],
        out: ["[data-testid='qrcode']", "#qrcode", ".landing-title"]
      },
      reddit: {
        in: ["#expand-user-drawer-button", '[aria-label="Open profile menu"]', '[aria-label="Open user profile menu"]'],
        out: ["a[href='/login']", "a[href='/register']", "shreddit-login", "input[name='password']"]
      },
      steam: {
        in: ["#account_pulldown", "#header .user_avatar"],
        out: ["a.global_action_link[href*='login']", "a.global_action_link[href*='join']"]
      }
    };
    const rule = rules[String(key || "").toLowerCase()];
    if (!rule) return null;
    if (hit(rule.in)) return true;   // 账户证据优先（登录页一般不会同时出现账户菜单）
    if (hit(rule.out)) return false; // 明确的登录/注册表单
    return null;                     // 缺证据：不能断「未登录」
  } catch (e) {
    return null;
  }
}

// 预载 = 只开网页 + 探登录态，绝不启动运行。
// 每个平台返回：{ key, url, opened, settled, logged, probe, attempts, error }
// settled=false 表示页面没在限定时间内加载完 → 侧栏必须显示「待确认」，不能当作未登录。
async function handlePreload(platforms, opts) {
  const recheck = !!(opts && opts.recheck);
  const keys = normalizePreloadKeys(platforms);
  const out = [];
  for (const key of keys) {
    const url = PRELOAD_URLS[key];
    const want = urlHost(url).replace(/^www\./, "");
    let tabs = [];
    try { tabs = await chrome.tabs.query({}); } catch (e) { tabs = []; }
    let tab = (tabs || []).find(t => hostMatches(urlHost(t && t.url), want));
    let opened = false;
    if (!tab) {
      try { tab = await chrome.tabs.create({ url, active: false }); opened = true; }
      catch (e) { tab = null; }
    } else if (recheck) {
      try { await chrome.tabs.update(tab.id, { active: true }); } catch (e) {}
    }
    let settled = false;
    if (tab && tab.id != null) settled = await waitTab(tab.id, opened || recheck ? 15000 : 6000);
    let logged = null, probe = "error", err = null, attempts = 0;
    if (tab && tab.id != null) {
      for (let i = 0; i < 3; i++) {
        attempts++;
        try {
          const r = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: probeLoginFn, args: [key] });
          const first = Array.isArray(r) ? r[0] : null;
          const v = first ? first.result : undefined;
          // 三态：只有明确 true/false 才采信；空结果/无证据/异常值 → null（侧栏待确认）
          logged = (v === true || v === false) ? v : null;
          probe = "ok"; err = null;
          break;
        } catch (e) {
          probe = "error"; logged = null; err = String((e && e.message) || e);
          if (i < 2) await sleep(1200);
        }
      }
    } else {
      err = "tab_unavailable";
    }
    out.push({ key, url, opened, settled, logged, probe, attempts, error: err });
  }
  return { ok: true, results: out };
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "preload") { handlePreload(msg.platforms, { recheck: !!msg.recheck }).then(sendResponse); return true; }
  if (msg && msg.type === "start") {
    // 二道守卫：即使调用方漏过滤，也不把无页面执行器的平台发给 hub。
    const requested = Array.isArray(msg.platforms) ? msg.platforms : null;
    const requestedOrder = Array.isArray(msg.order) ? msg.order : requested;
    const runnable = requested ? requested.filter(function (p) { return !!executorOf(p); }) : null;
    const runnableOrder = requestedOrder ? requestedOrder.filter(function (p) { return !!executorOf(p); }) : runnable;
    if (requested && !runnable.length) {
      sendResponse({ ok: false, error: "no_runnable_platforms", detail: "可启动平台只有 Facebook / Telegram；其余平台请预载或由 run_daily 专用 runner 执行" });
      return;
    }
    (async () => {
      try {
        const r = await hubControl("start", { source: "ui", platforms: runnable, order: runnableOrder });
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
    let t = null;
    try { t = await chrome.tabs.get(tabId); } catch (e) { return false; } // 标签被关掉：视为未加载完成
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
function pageFBJoinDirect(p) {
  const want = String((p && (p.id || p.gid || p.group)) || "").trim();
  const title = String((p && p.title) || "").trim();
  const res = { ok: true, v: "unknown", e: "" };
  const setRes = (v, e) => { res.v = v; res.e = e || ""; try { window.__dshRes = JSON.stringify(res); } catch (x) { } };
  const norm = (s) => String(s == null ? "" : s).replace(/\s+/g, " ").trim();
  const attr = (el, n) => { try { if (el && typeof el.getAttribute === "function") { const v = el.getAttribute(n); if (v != null) return v; } } catch (x) { } try { return (el && el.attrs && el.attrs[n]) || ""; } catch (x) { return ""; } };
  const txt = (el) => norm(el && (el.innerText != null ? el.innerText : el.textContent));
  const JOIN = /^(加入小组|加入群组|加入|join group|join)$/i;
  const REQ = /^(请求加入|申请加入|request to join|ask to join)$/i;
  const CANCEL = /^(取消请求|取消加入申请|cancel request|cancel join request)$/i;
  const JOINED = /^(已加入|已加入小组|joined|joined group)$/i;
  const PEND = /(加入请求待审核|请求待审核|请求已发送|已提交申请|等待管理员审核|request sent|request pending|join request pending|membership pending)/i;
  const MEMBER = /(已加入|你已加入|加入成功|you're a member|you are a member|you joined|joined this group)/i;
  const REC = /(推荐小组|推荐群组|related groups|suggested groups|groups for you|people also)/i;
  const segOf = (u) => { const m = String(u || "").match(/\/groups\/([^\/?#]+)/i); return m ? decodeURIComponent(m[1]) : ""; };
  const segsIn = (root) => {
    const out = [];
    try {
      const as = root.querySelectorAll ? root.querySelectorAll("a[href]") : [];
      for (let i = 0; i < as.length; i++) { const s = segOf(attr(as[i], "href")); if (s) out.push(s); }
    } catch (x) { }
    return out;
  };
  const inArticle = (el) => { let x = el; for (let i = 0; i < 14 && x; i++) { if (String(attr(x, "role")).toLowerCase() === "article") return true; x = x.parentElement; } return false; };
  const clickers = (root) => {
    const sel = 'div[role="button"],a[role="button"],span[role="button"],button';
    const out = [];
    try { const ns = root.querySelectorAll ? root.querySelectorAll(sel) : []; for (let i = 0; i < ns.length; i++) out.push(ns[i]); } catch (x) { }
    return out;
  };

  function step(tries) {
    const main = document.querySelector ? document.querySelector('div[role="main"]') : null;
    if (!main) { if (tries < 5) { setTimeout(() => step(tries + 1), 700); return; } setRes("not_found", "no_main"); return; }
    const heads = [];
    try {
      const hs = main.querySelectorAll('h1,h2,h3,[role="heading"]');
      const want2 = title.toLowerCase();
      for (let i = 0; i < hs.length; i++) {
        const t = txt(hs[i]).toLowerCase();
        if (t && (t === want2 || t.indexOf(want2) !== -1)) heads.push(hs[i]);
      }
    } catch (x) { }
    if (heads.length === 0) { if (tries < 5) { setTimeout(() => step(tries + 1), 700); return; } setRes("not_found", "no_target_header"); return; }
    if (heads.length > 1) { setRes("not_found", "ambiguous_title"); return; }

    const mainText = txt(main);
    const acts = clickers(main).filter((b) => !inArticle(b));
    const joins = acts.filter((b) => JOIN.test(txt(b)));
    const reqs = acts.filter((b) => REQ.test(txt(b)));
    const cancels = acts.filter((b) => CANCEL.test(txt(b)));
    const joinedBtns = acts.filter((b) => JOINED.test(txt(b)));

    if (cancels.length > 0 && joins.length === 0) { setRes("request_sent", "cancel_button_present"); return; }
    if (PEND.test(mainText) && joins.length === 0) { setRes("request_sent", "pending_banner"); return; }
    if (joinedBtns.length > 0 && joins.length === 0 && reqs.length === 0) { setRes("already", "joined_button"); return; }
    if (MEMBER.test(mainText) && joins.length === 0 && reqs.length === 0) { setRes("already", "member_text"); return; }
    if (joins.length === 0 && reqs.length === 0) {
      if (REC.test(mainText)) { setRes("not_found", "only_recommended_actions"); return; }
      if (tries < 5) { setTimeout(() => step(tries + 1), 700); return; }
      setRes("not_found", "no_join_action");
      return;
    }
    if (joins.length > 1) { setRes("not_found", "ambiguous_join_buttons"); return; }
    if (reqs.length > 1) { setRes("not_found", "ambiguous_request_buttons"); return; }

    const segsAll = [...new Set(segsIn(main))];
    const cur = segOf((location && location.href) || "");
    const isNum = (s) => /^\d{6,}$/.test(String(s || ""));
    const nums = segsAll.filter(isNum);
    const alias = nums.length === 1 ? nums[0] : "";
    const eq = (a, b) => a && b && String(a).toLowerCase() === String(b).toLowerCase();
    const urlOk = eq(cur, want) || (alias && isNum(cur) && eq(cur, alias));
    const segOk = segsAll.some((s) => eq(s, want)) || (alias && isNum(want) && eq(alias, want)) || (alias && !isNum(want)) || (alias && isNum(cur) && eq(alias, cur)) || segsAll.length === 0;
    if (!urlOk && !segOk) { setRes("not_found", "target_id_mismatch"); return; }

    const btn = joins.length === 1 ? joins[0] : reqs[0];
    const isReq = joins.length === 0;
    try { btn.click(); } catch (x) { setRes("unknown", "click_failed"); return; }

    let n = 0;
    function verify() {
      const t = txt(main);
      if (MEMBER.test(t)) { setRes("joined", "after_click_member"); return; }
      if (PEND.test(t)) { setRes(isReq ? "request_sent" : "joined", isReq ? "after_click_pending" : "after_click_pending_text"); return; }
      if (n < 4) { n++; setTimeout(verify, 500); return; }
      setRes("unknown", "clicked_no_evidence");
    }
    setTimeout(verify, 500);
  }

  try { step(0); } catch (e) { setRes("unknown", "exception:" + (e && e.message ? e.message : e)); }
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