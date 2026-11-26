// panel_core.js — 侧栏纯逻辑（平台名↔预载键、登录态判定、预载摘要）
// 浏览器里挂到 window.PanelCore；Node 里 module.exports。无 DOM、无 chrome 依赖，便于独立行为测试。
(function (root, factory) {
  var Core = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = Core;
  if (root) root.PanelCore = Core;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  // 平台显示名 / 缩写 → background 预载键。Instagram 为预留平台，不支持预载。
  var ALIAS = {
    telegram: "telegram", tg: "telegram",
    facebook: "facebook", fb: "facebook",
    discord: "discord", dc: "discord",
    whatsapp: "whatsapp", wa: "whatsapp",
    reddit: "reddit", rd: "reddit",
    steam: "steam"
  };
  var NAME_BY_KEY = {
    telegram: "Telegram", facebook: "Facebook", discord: "Discord",
    whatsapp: "WhatsApp", reddit: "Reddit", steam: "Steam"
  };

  function keyFor(name) {
    if (name == null) return null;
    var s = String(name).trim().toLowerCase();
    return ALIAS[s] || null;
  }

  function keysFromNames(names) {
    var out = [], seen = {};
    (names || []).forEach(function (n) {
      var k = keyFor(n);
      if (!k || seen[k]) return;
      seen[k] = 1;
      out.push(k);
    });
    return out;
  }

  // 勾选了但暂不支持预载的平台名（如预留的 Instagram）
  function unsupportedNames(names) {
    return (names || []).filter(function (n) { return !keyFor(n); });
  }

  // 登录态判定：错误 / 页面未加载完 优先于任何 logged 值（包括 true）——
  // 探针在页面没加载完时可能读到半渲染的 DOM，true 也不可信；只有「执行成功 + 已加载完 +
  // 明确 true/false」才给出 已登录/未登录，其余一律 待确认。
  function verdictOf(row) {
    if (!row) return { code: "unknown", label: "待确认" };
    if (row.settled === false) return { code: "unknown", label: "待确认" };
    if (row.probe === "error" || row.error) return { code: "unknown", label: "待确认" };
    if (row.logged === true && row.probe === "ok") return { code: "logged_in", label: "已登录" };
    if (row.logged === false && row.probe === "ok") return { code: "logged_out", label: "未登录" };
    return { code: "unknown", label: "待确认" };
  }

  function rowView(row) {
    var r = row || {};
    var v = verdictOf(r);
    return {
      key: r.key || "",
      name: r.key ? (NAME_BY_KEY[r.key] || r.key) : "—",
      code: v.code,
      label: v.label,
      opened: !!r.opened,
      openText: r.opened ? "新开标签" : "已存在",
      url: r.url || "",
      error: r.error ? String(r.error) : ""
    };
  }

  function preloadSummary(rows) {
    var n = { logged_in: 0, logged_out: 0, unknown: 0 };
    (rows || []).forEach(function (r) { n[verdictOf(r).code]++; });
    var total = (rows || []).length;
    return {
      loggedIn: n.logged_in,
      loggedOut: n.logged_out,
      pending: n.unknown,
      total: total,
      text: n.logged_in + " 已登录 · " + n.unknown + " 待确认 · " + n.logged_out + " 未登录"
    };
  }

  function preloadRequest(names, recheck) {
    return { type: "preload", platforms: keysFromNames(names), recheck: recheck === true };
  }

  return {
    ALIAS: ALIAS,
    NAME_BY_KEY: NAME_BY_KEY,
    keyFor: keyFor,
    keysFromNames: keysFromNames,
    unsupportedNames: unsupportedNames,
    verdictOf: verdictOf,
    rowView: rowView,
    preloadSummary: preloadSummary,
    preloadRequest: preloadRequest
  };
});
