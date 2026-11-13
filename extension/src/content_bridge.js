// 看板(127.0.0.1:8787) <-> 扩展 桥（isolated world，勿比较 ev.source）
window.addEventListener("message", function (ev) {
  var d = ev.data;
  if (!d || d.__dshPreload !== true) return;
  try {
    chrome.runtime.sendMessage({ type: "preload", platforms: d.platforms || [], recheck: d.recheck === true, recheck: d.recheck === true }, function (res) {
      window.postMessage({
        __dshPreloadResult: true,
        ok: !!(res && res.ok),
        data: res || null,
        err: chrome.runtime.lastError ? String(chrome.runtime.lastError.message) : null
      }, "*");
    });
  } catch (e) {
    window.postMessage({ __dshPreloadResult: true, ok: false, data: null, err: String(e) }, "*");
  }
});
