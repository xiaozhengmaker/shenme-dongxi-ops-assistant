// tests/offline/ui_start_payload.test.js  (m14916)
// 真实入口：抽取扩展源码里的 requestStart / sendWithTimeout / sendOnce / selectedPlatforms / ctxAlive，
// 用假 DOM（含 .plat 行 + data-name + closest）与假 chrome 执行真实点击路径，断言消息内容。
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const SRC = fs.readFileSync(path.join(ROOT, "extension", "src", "sidepanel.js"), "utf8");
const HTML = fs.readFileSync(path.join(ROOT, "extension", "src", "sidepanel.html"), "utf8");

function sliceFn(src, name) {
  const m = src.match(new RegExp("(?:async\\s+)?function\\s+" + name + "\\s*\\("));
  if (!m) throw new Error("fn not found: " + name);
  let i = src.indexOf("{", m.index + m[0].length), depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") { depth--; if (depth === 0) break; }
  }
  return src.slice(m.index, i + 1);
}

const NAMES = ["ctxAlive", "selectedPlatforms", "isRunnablePlatform", "runnablePlatforms", "sendWithTimeout", "sendOnce", "requestStart"];
const body =
  "const START_TIMEOUT_MS = 5000; var RUN_BUSY = false;\n" +
  'const RUN_PLATFORMS = ["Telegram", "Facebook"];\n' +
  "function showFeedback() {}\nfunction friendlyError(r) { return (r && r.error) || 'err'; }\n" +
  "function setRunBusy(v) { RUN_BUSY = !!v; }\n" +
  "async function refresh() { return true; }\n" +
  NAMES.map((n) => sliceFn(SRC, n)).join("\n") +
  "\n;return { requestStart, sendWithTimeout, selectedPlatforms, runnablePlatforms, get busy() { return RUN_BUSY; } };";

function makeEnv(checked) {
  const sent = [];
  const boxes = ["Facebook", "Telegram", "Discord", "Reddit", "WhatsApp", "Instagram", "Steam"].map((v) => ({
    value: v,
    checked: checked.includes(v),
    closest: (sel) => (sel === ".plat" ? { getAttribute: (k) => (k === "data-name" ? v : null) } : null)
  }));
  const btnStart = { disabled: false, title: "", textContent: "" };
  const document = {
    querySelector: (s) => (s === "#btnStart" ? btnStart : null),
    querySelectorAll: (s) => {
      if (!/input|checkbox|plat/i.test(String(s))) return [];
      return String(s).indexOf(":checked") >= 0 ? boxes.filter((b) => b.checked) : boxes;
    },
    getElementById: (id) => (id === "btnStart" ? btnStart : null)
  };
  const chrome = {
    runtime: {
      id: "test-ext",
      sendMessage: (msg, cb) => { sent.push(msg); if (cb) cb({ ok: true }); return Promise.resolve({ ok: true }); }
    }
  };
  const fn = new Function("window", "document", "chrome", "location", "setTimeout", "console", body);
  const api = fn({ document, chrome }, document, chrome,
    { href: "chrome-extension://x/src/sidepanel.html" },
    (f, ms) => (typeof f === "function" ? (f(), 0) : 0), console);
  return { api, sent, btnStart };
}

let pass = 0, fail = 0;
async function T(name, fn) {
  try { await fn(); pass++; console.log("PASS  " + name); }
  catch (e) { fail++; console.log("FAIL  " + name + " :: " + (e && e.message ? e.message : e)); }
}
function A(c, m) { if (!c) throw new Error(m); }

(async () => {
  await T("button-label-renamed", () => {
    A(HTML.indexOf("运行已选平台") >= 0, "html missing 运行已选平台");
    A(HTML.indexOf(">开始运行<") < 0, "html still has >开始运行<");
  });

  await T("zero-selected-disables-start", async () => {
    const { api, sent } = makeEnv([]);
    A(api.selectedPlatforms().length === 0, "should select none");
    await api.requestStart();
    A(sent.length === 0, "must not send; sent=" + sent.length);
  });

  await T("single-selected-payload", async () => {
    const { api, sent } = makeEnv(["Telegram"]);
    await api.requestStart();
    A(sent.length === 1, "sent=" + sent.length + " payload=" + JSON.stringify(sent));
    const m = sent[0];
    A(m.type === "start", "type=" + m.type);
    A(JSON.stringify(m.platforms) === JSON.stringify(["Telegram"]), "platforms=" + JSON.stringify(m.platforms));
    A(JSON.stringify(m.order) === JSON.stringify(["Telegram"]), "order=" + JSON.stringify(m.order));
  });

  await T("multi-selected-order", async () => {
    // 混合勾选：Steam/Reddit 只预载/由计划任务执行，不得进入 start 载荷（否则会被跑成 Telegram）。
    const { api, sent } = makeEnv(["Telegram", "Steam", "Reddit", "Facebook"]);
    await api.requestStart();
    A(sent.length === 1, "sent=" + sent.length);
    const m = sent[0];
    A(JSON.stringify(m.platforms) === JSON.stringify(["Facebook", "Telegram"]), "runnable dom order expected; got=" + JSON.stringify(m.platforms));
    A(JSON.stringify(m.order) === JSON.stringify(m.platforms), "order must equal platforms");
    A(m.platforms.indexOf("Steam") < 0 && m.platforms.indexOf("Reddit") < 0, "preload-only leaked into start");
  });

  await T("preload-only-never-starts", async () => {
    const { api, sent } = makeEnv(["Discord", "Steam", "WhatsApp"]);
    await api.requestStart();
    A(sent.length === 0, "preload-only selection must not send start; sent=" + JSON.stringify(sent));
    A(api.runnablePlatforms().length === 0, "should have no runnable platform");
  });

  await T("legacy-call-without-platforms", () => {
    const { api, sent } = makeEnv(["Telegram"]);
    api.sendWithTimeout("start", 5000);
    A(sent.length === 1, "sent=" + sent.length);
    const m = sent[0];
    A(m.type === "start", "type=" + m.type);
    A(!("platforms" in m) && !("order" in m), "legacy payload must stay bare");
  });

  console.log("RESULT pass=" + pass + " fail=" + fail);
  process.exit(fail === 0 ? 0 : 1);
})();
