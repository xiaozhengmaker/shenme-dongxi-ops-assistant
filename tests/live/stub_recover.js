// stub_recover.js — 供 sidepanel_recovery.ps1 注入的最小运行时桩
// 前 N 次 status / live 失败，之后自动恢复；用于验证「同一页面从失败到恢复」。
(function () {
  var failStatus = 6, failLive = 2, nSt = 0, nLv = 0;
  var cfg = { platforms: ["Telegram", "Steam"], quotas: { FB: 10, TG: 30 } };
  function reply() { return { ok: true, hub: { ok: true, phase: "idle", running: false }, st: {}, cfg: cfg }; }
  window.chrome = {
    runtime: {
      id: "test",
      onMessage: { addListener: function () {} },
      sendMessage: function (msg, cb) {
        var ty = (msg && msg.type) || "";
        var val = ty === "status"
          ? (++nSt <= failStatus ? { ok: false, error: "boom" } : reply())
          : (ty === "config" ? { ok: true, cfg: cfg } : { ok: true });
        if (cb) { setTimeout(function () { cb(val); }, 25); return; }
        return new Promise(function (res) { setTimeout(function () { res(val); }, 25); });
      }
    }
  };
  window.fetch = function (u) {
    u = String(u);
    var body = { ok: true };
    if (u.indexOf("/api/live") >= 0) {
      if (++nLv <= failLive) { return Promise.reject(new Error("live_boom")); }
      body = { ok: true, running: false, phase: "idle", events: [], stopFlag: { present: false } };
    } else if (u.indexOf("/api/lastrun") >= 0) { body = { ok: true, lastRun: null }; }
    else if (u.indexOf("/api/summary") >= 0) { body = { groups: 0, members: 0, today: 0, todos: [] }; }
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve(body); } });
  };
})();
