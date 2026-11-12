
// —— 扩展上下文守卫：扩展被重新加载后，已打开的页面会失去 chrome.* API ——
const CTX_ALIVE = !!(window.chrome && chrome.runtime && chrome.runtime.id);
function showDeadContext() {
  const box = document.getElementById("offline");
  if (box) {
    box.classList.remove("hidden");
    box.innerHTML = "<b>扩展刚更新过，这个页面已失效</b><p>请关闭这个侧边栏再重新打开（或刷新此标签页），按钮才会恢复。</p>";
  }
  ["btnStart", "btnStop", "btnCopy"].forEach(function (id) {
    const el = document.getElementById(id);
    if (el) { el.disabled = true; el.style.opacity = "0.5"; }
  });
  const live = document.getElementById("liveCurrent");
  if (live) live.textContent = "扩展上下文已失效（chrome.runtime 不可用）";
}

const HUB = "http://127.0.0.1:8787";
const $ = (s) => document.querySelector(s);
let CFG = null;
let SUM = null;

async function loadSummary() {
  try {
    const r = await fetch(HUB + "/api/summary", { cache: "no-store" });
    if (r.ok) SUM = await r.json();
  } catch (e) {}
}

async function send(type) {
  if (!CTX_ALIVE) return null;
  for (let i = 0; i < 3; i++) {
    try {
      const r = await chrome.runtime.sendMessage({ type });
      if (r) return r;
    } catch (e) {}
    await new Promise(res => setTimeout(res, 400));
  }
  return null;
}

async function refresh() {
  let r = null;
  try { r = await send("status"); } catch (e) { r = null; }
  if (!r || !r.ok) { $("#hubText").textContent = "扩展未响应"; return; }
  const hub = r.hub || {}, st = r.st || {};
  const alive = !!hub.ok;
  const off = document.getElementById("offline");
  if (off) off.classList.toggle("hidden", alive);
  $("#dot").className = "dot " + (alive ? "on" : "off");
  const _lh = document.getElementById("lHub");
  if (_lh) { _lh.className = "dot " + (alive ? "on" : "off"); _lh.title = alive ? "hub " + (hub.phase || "") : "hub 未启动"; }
  $("#hubText").textContent = alive ? "后台已连接 · 127.0.0.1:8787" : "后台未启动（先运行 hub.ps1）";
  $("#phase").textContent = hub.phase || "idle";
  $("#kJoined").textContent = joined;
  $("#log").textContent = st.lastLog || "—";

  if (r.cfg) {
    CFG = r.cfg;
    const q = CFG.quotas || {};
    let total = 0;
    const parts = [];
    Object.keys(q).forEach(function (k) {
      total += (q[k] || 0);
      if (k === "Discord") { parts.push("DC 只统计"); }
      else if ((q[k] || 0) > 0) { parts.push(k.slice(0, 2).toUpperCase() + " " + q[k]); }
    });
    $("#quota").textContent = "配额 " + parts.join(" · ");
    const today = (SUM && SUM.totals && SUM.totals.todayGroups) || 0;
    $("#progressText").textContent = today + " / " + total + " 今日";
    $("#bar").style.width = (total ? Math.min(100, Math.round(today * 100 / total)) : 0) + "%";
  }
  const pr = r.probe || {};
  function setLight(id, ok, text) {
    const el = document.getElementById(id);
    if (!el) return;
    el.className = "dot " + (ok ? "on" : "off");
    el.title = text || "";
  }
  setLight("lHub", !!hub.ok, hub.ok ? "hub " + (hub.phase || "") : "hub 未启动");
  setLight("lTg", pr.tg === "alive", "tg=" + pr.tg);
  setLight("lFb", pr.fb === "login", "fb=" + pr.fb);
  setLight("lPerm", pr.perm === true, "perm=" + pr.perm);

  const running = !!st.running;
  $("#btnStart").disabled = running;
  $("#btnStop").disabled = !running;
}

// —— 各平台登录灯：找该平台标签页 → 注入探针 → 亮/暗 ——
const PLAT_LIGHTS = {
  telegram: { url: "https://web.telegram.org/*" },
  facebook: { url: "https://*.facebook.com/*" },
  discord: { url: "https://discord.com/*" },
  whatsapp: { url: "https://web.whatsapp.com/*" },
  reddit: { url: "https://www.reddit.com/*" },
  steam: { url: "https://steamcommunity.com/*" }
};

function probeInPage(key) {
  try {
    if (key === "telegram") return !!(window.rootScope || document.querySelector("#column-center"));
    if (key === "facebook") return (document.cookie || "").indexOf("c_user=") >= 0;
    if (key === "discord") return !!document.querySelector('[class*="guilds"]') || !!document.querySelector('[class*="sidebar"]');
    if (key === "whatsapp") return !!document.querySelector("#pane-side");
    if (key === "reddit") return !document.querySelector('input[name="password"]') && !!document.querySelector('shreddit-app, #header, #SHORTCUT_FOCUSABLE_DIV');
    if (key === "steam") return !!document.querySelector("#account_pulldown");
    return false;
  } catch (e) { return false; }
}

let PLAT_BUSY = false;
async function refreshPlatLights() {
  if (PLAT_BUSY || !CTX_ALIVE) return;
  PLAT_BUSY = true;
  try {
    const nodes = document.querySelectorAll('#lights .light[data-pk]');
    for (const node of nodes) {
      const pk = node.getAttribute("data-pk");
      const dot = node.querySelector(".dot");
      const meta = PLAT_LIGHTS[pk];
      if (!dot || !meta) continue;
      let tabs = [];
      try { tabs = await chrome.tabs.query({ url: meta.url }); } catch (e) { tabs = []; }
      if (!tabs.length) {
        dot.className = "dot off";
        node.title = pk + "：没有打开的标签页（先打开该平台网页并登录）";
        continue;
      }
      let ok = false;
      try {
        const res = await chrome.scripting.executeScript({ target: { tabId: tabs[0].id }, func: probeInPage, args: [pk] });
        ok = !!(res && res[0] && res[0].result);
      } catch (e) { ok = false; }
      dot.className = "dot " + (ok ? "on" : "warn");
      node.title = pk + (ok ? "：已登录" : "：标签页在，但未登录或未加载完");
    }
  } finally { PLAT_BUSY = false; }
}

const PLAT_ICO = { Facebook: "fb", Telegram: "tg", Discord: "dc", Reddit: "rd", WhatsApp: "wa", Instagram: "ig", Steam: "st" };

function syncPlatHint() {
  const hint = document.getElementById("platsHint");
  if (!hint) return;
  const on = [];
  document.querySelectorAll('#platList input[type=checkbox]').forEach(function (b) {
    if (b.checked) { const row = b.closest('.plat'); const nm = row ? (row.getAttribute('data-name') || '') : ''; if (nm) on.push(nm); }
  });
  hint.textContent = on.length ? ("已选 " + on.length + " 个") : "";
}

function renderPlats(c) {
  const list = $("#platList");
  if (!list) return;
  const plats = (c && c.platforms) || ["Facebook", "Telegram", "Discord"];
  const reserved = ((c && c.reserved) || []).map(function (x) { return String(x).toLowerCase(); });
  const pe = (c && c.platformsEnabled) || {};
  list.innerHTML = plats.map(function (p) {
    const ico = PLAT_ICO[p] || "ms";
    const isRes = reserved.indexOf(String(p).toLowerCase()) >= 0;
    const tag = isRes ? '<span class="tag">预留</span>' : (p === "Discord" ? '<span class="tag">只统计</span>' : '');
    const on = pe[p] === true;
    return '<label class="plat" data-name="' + p + '"><input type="checkbox" data-p="' + p + '"' + (on ? ' checked' : '') + '><i class="ico ' + ico + '"></i>' + p + tag + '</label>';
  }).join("");
  Array.prototype.forEach.call(list.querySelectorAll("input[data-p]"), function (inp) {
    inp.onchange = savePlatforms;
  });
  syncPlatHint();
}

async function loadPlatforms() {
  try {
    const r = await fetch(HUB + "/api/config", { cache: "no-store" });
    if (!r.ok) return;
    const c = await r.json();
    renderPlats(c);
  } catch (e) {}
}

async function savePlatforms() {
  const list = $("#platList");
  if (!list) return;
  const out = {};
  Array.prototype.forEach.call(list.querySelectorAll("input[data-p]"), function (inp) {
    out[inp.getAttribute("data-p")] = !!inp.checked;
  });
  try {
    await fetch(HUB + "/api/config", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ platformsEnabled: out })
    });
  } catch (e) {}
}

async function refreshLive() {
  let d = null;
  try {
    const r = await fetch(HUB + "/api/live", { cache: "no-store" });
    if (r.ok) d = await r.json();
  } catch (e) {}
  const box = document.getElementById("livebox");
  if (!box) return;
  if (!d) {
    document.getElementById("liveState").className = "live-pill stop";
    document.getElementById("liveState").textContent = "后台离线";
    document.getElementById("liveCurrent").textContent = "—";
    document.getElementById("liveEvents").innerHTML = "";
    return;
  }
  const st = document.getElementById("liveState");
  const running = !!d.running;
  const actNow = !!d.activeLive && !!(d.activePlatform);
  st.textContent = running
    ? (d.phase === "probe" ? "探测中" : d.phase === "search" ? "搜索中" : d.phase === "join" ? "加群中" : "运行中")
    : (actNow ? "运行中" : (d.phase === "done" ? "已结束" : "空闲"));
  st.className = "live-pill" + ((running || actNow) ? " on" : "");
  const pl = document.getElementById("livePlat");
  const actPlat = d.activePlatform || "";
  const actLive = !!d.activeLive;
  if (pl) {
    if (actLive && actPlat) { pl.textContent = actPlat; pl.className = "live-pill on"; }
    else if (running) { pl.textContent = d.platform || "—"; pl.className = "live-pill on"; }
    else if (actPlat) { pl.textContent = actPlat + " · 已停"; pl.className = "live-pill"; }
    else { pl.textContent = d.platform || "—"; pl.className = "live-pill"; }
  }

  if (document.getElementById("kJoined")) {
    document.getElementById("kJoined").textContent = d.joined || 0;
    document.getElementById("kSkipped").textContent = d.skipped || 0;
    document.getElementById("kFailed").textContent = d.failed || 0;
  }
  const cur = document.getElementById("liveCurrent");
  const total = (d.joined || 0) + (d.skipped || 0) + (d.failed || 0) + (d.queue || 0);
  const lastEv = (d.events && d.events.length) ? d.events[d.events.length - 1] : null;
  cur.textContent = d.current || (running ? "准备中…" : (actLive && lastEv ? lastEv.m : "点「开始运行」开始"));

  const done = (d.joined || 0) + (d.skipped || 0) + (d.failed || 0);
  const pct = total > 0 ? Math.min(100, Math.round(done * 100 / total)) : 0;
  document.getElementById("liveBar").style.width = pct + "%";

  const ev = (d.events || []).slice().reverse();
  document.getElementById("liveEvents").innerHTML = ev.length
    ? ev.map(function (x) {
        const cls = /not_found|approval|失败|error|dead/i.test(x.m) ? "bad" : (/joined|ok|结束/.test(x.m) ? "ok" : "");
        return '<li><span class="t">' + x.t + '</span><span class="m ' + cls + '">' + String(x.m).replace(/[<>&]/g, function (c) { return { "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]; }) + "</span></li>";
      }).join("")
    : '<li><span class="m">还没有事件</span></li>';
}

// 「看板 ↗」：必须在扩展上下文里才能开标签页
(function () {
  var b = document.getElementById("btnOpen");
  if (!b) return;
  b.addEventListener("click", function () {
    if (!CTX_ALIVE) { showDeadContext(); return; }
    try { chrome.tabs.create({ url: "http://127.0.0.1:8787/" }); }
    catch (e) { b.textContent = "打开失败"; }
  });
})();

if (!CTX_ALIVE) { showDeadContext(); } else {
loadPlatforms();
loadSummary().then(refresh);
setTimeout(refresh, 800);
setTimeout(refresh, 2400);
setInterval(refresh, 2000);
setInterval(refreshLive, 2000);
setInterval(refreshPlatLights, 10000);
setTimeout(refreshLive, 600);
setInterval(() => { loadSummary().then(refresh); }, 15000);
}
