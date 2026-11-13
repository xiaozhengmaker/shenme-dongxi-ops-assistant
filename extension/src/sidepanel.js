
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

  const LOGO_SVG = {
    Facebook: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073z"/></svg>',
    Telegram: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg>',
    WhatsApp: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413Z"/></svg>',
    Instagram: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M12 0C8.74 0 8.333.015 7.053.072 5.775.132 4.905.333 4.14.63c-.789.306-1.459.717-2.126 1.384S.935 3.35.63 4.14C.333 4.905.131 5.775.072 7.053.012 8.333 0 8.74 0 12s.015 3.667.072 4.947c.06 1.277.261 2.148.558 2.913.306.788.717 1.459 1.384 2.126.667.666 1.336 1.079 2.126 1.384.766.296 1.636.499 2.913.558C8.333 23.988 8.74 24 12 24s3.667-.015 4.947-.072c1.277-.06 2.148-.262 2.913-.558.788-.306 1.459-.718 2.126-1.384.666-.667 1.079-1.335 1.384-2.126.296-.765.499-1.636.558-2.913.06-1.28.072-1.687.072-4.947s-.015-3.667-.072-4.947c-.06-1.277-.262-2.149-.558-2.913-.306-.789-.718-1.459-1.384-2.126C21.319 1.347 20.651.935 19.86.63c-.765-.297-1.636-.499-2.913-.558C15.667.012 15.26 0 12 0zm0 2.16c3.203 0 3.585.016 4.85.071 1.17.055 1.805.249 2.227.415.562.217.96.477 1.382.896.419.42.679.819.896 1.381.164.422.36 1.057.413 2.227.057 1.266.07 1.646.07 4.85s-.015 3.585-.074 4.85c-.061 1.17-.256 1.805-.421 2.227-.224.562-.479.96-.899 1.382-.419.419-.824.679-1.38.896-.42.164-1.065.36-2.235.413-1.274.057-1.649.07-4.859.07-3.211 0-3.586-.015-4.859-.074-1.171-.061-1.816-.256-2.236-.421-.569-.224-.96-.479-1.379-.899-.421-.419-.69-.824-.9-1.38-.165-.42-.359-1.065-.42-2.235-.045-1.26-.061-1.649-.061-4.844 0-3.196.016-3.586.061-4.861.061-1.17.255-1.814.42-2.234.21-.57.479-.96.9-1.381.419-.419.81-.689 1.379-.898.42-.166 1.051-.361 2.221-.421 1.275-.045 1.65-.06 4.859-.06l.045.03zm0 3.678a6.162 6.162 0 100 12.324 6.162 6.162 0 100-12.324zM12 16c-2.21 0-4-1.79-4-4s1.79-4 4-4 4 1.79 4 4-1.79 4-4 4zm7.846-10.405a1.441 1.441 0 01-2.88 0 1.44 1.44 0 012.88 0z"/></svg>',
    X: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z"/></svg>',
    Discord: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z"/></svg>',
    Reddit: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M12 0C5.373 0 0 5.373 0 12c0 3.314 1.343 6.314 3.515 8.485l-2.286 2.286C.775 23.225 1.097 24 1.738 24H12c6.627 0 12-5.373 12-12S18.627 0 12 0Zm4.388 3.199c1.104 0 1.999.895 1.999 1.999 0 1.105-.895 2-1.999 2-.946 0-1.739-.657-1.947-1.539v.002c-1.147.162-2.032 1.15-2.032 2.341v.007c1.776.067 3.4.567 4.686 1.363.473-.363 1.064-.58 1.707-.58 1.547 0 2.802 1.254 2.802 2.802 0 1.117-.655 2.081-1.601 2.531-.088 3.256-3.637 5.876-7.997 5.876-4.361 0-7.905-2.617-7.998-5.87-.954-.447-1.614-1.415-1.614-2.538 0-1.548 1.255-2.802 2.803-2.802.645 0 1.239.218 1.712.585 1.275-.79 2.881-1.291 4.64-1.365v-.01c0-1.663 1.263-3.034 2.88-3.207.188-.911.993-1.595 1.959-1.595Zm-8.085 8.376c-.784 0-1.459.78-1.506 1.797-.047 1.016.64 1.429 1.426 1.429.786 0 1.371-.369 1.418-1.385.047-1.017-.553-1.841-1.338-1.841Zm7.406 0c-.786 0-1.385.824-1.338 1.841.047 1.017.634 1.385 1.418 1.385.785 0 1.473-.413 1.426-1.429-.046-1.017-.721-1.797-1.506-1.797Zm-3.703 4.013c-.974 0-1.907.048-2.77.135-.147.015-.241.168-.183.305.483 1.154 1.622 1.964 2.953 1.964 1.33 0 2.47-.81 2.953-1.964.057-.137-.037-.29-.184-.305-.863-.087-1.795-.135-2.769-.135Z"/></svg>',
    Steam: '<svg viewBox="0 0 24 24" width="10" height="10" fill="currentColor"><path d="M11.979 0C5.678 0 .511 4.86.022 11.037l6.432 2.658c.545-.371 1.203-.59 1.912-.59.063 0 .125.004.188.006l2.861-4.142V8.91c0-2.495 2.028-4.524 4.524-4.524 2.494 0 4.524 2.031 4.524 4.527s-2.03 4.525-4.524 4.525h-.105l-4.076 2.911c0 .052.004.105.004.159 0 1.875-1.515 3.396-3.39 3.396-1.635 0-3.016-1.173-3.331-2.727L.436 15.27C1.862 20.307 6.486 24 11.979 24c6.627 0 11.999-5.373 11.999-12S18.605 0 11.979 0zM7.54 18.21l-1.473-.61c.262.543.714.999 1.314 1.25 1.297.539 2.793-.076 3.332-1.375.263-.63.264-1.319.005-1.949s-.75-1.121-1.377-1.383c-.624-.26-1.29-.249-1.878-.03l1.523.63c.956.4 1.409 1.5 1.009 2.455-.397.957-1.497 1.41-2.454 1.012H7.54zm11.415-9.303c0-1.662-1.353-3.015-3.015-3.015-1.665 0-3.015 1.353-3.015 3.015 0 1.665 1.35 3.015 3.015 3.015 1.663 0 3.015-1.35 3.015-3.015zm-5.273-.005c0-1.252 1.013-2.266 2.265-2.266 1.249 0 2.266 1.014 2.266 2.266 0 1.251-1.017 2.265-2.266 2.265-1.253 0-2.265-1.014-2.265-2.265z"/></svg>'
  };
  function logoOf(p) { return LOGO_SVG[p] || ""; }

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
    return '<label class="plat" data-name="' + p + '"><input type="checkbox" data-p="' + p + '"' + (on ? ' checked' : '') + '><i class="ico ' + ico + '">' + logoOf(p) + '</i>' + p + tag + '</label>';
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
