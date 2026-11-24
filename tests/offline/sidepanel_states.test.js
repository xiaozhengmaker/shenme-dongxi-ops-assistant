// sidepanel_states.test.js — 侧栏状态契约（静态，读取仓库实际源码）
const fs = require("fs");
const path = require("path");
const root = path.resolve(__dirname, "..", "..");
const js = fs.readFileSync(path.join(root, "extension", "src", "sidepanel.js"), "utf8");
let fails = 0;
function t(ok, name) { if (ok) { console.log("PASS " + name); } else { console.log("FAIL " + name); fails++; } }
t(js.includes("载入中"), "loading placeholder present");
t(js.includes("__spLoaded"), "loaded flag reset per load");
t(js.includes("send_timeout"), "send has timeout guard");
t(/!lr\s*\|\|\s*!lr\.run_id/.test(js), "lastrun hidden when no run_id");
const html = fs.readFileSync(path.join(root, "extension", "src", "sidepanel.html"), "utf8");
t(/lr\.report_text\s*\|\|/.test(js), "lastrun prefers report_text");
t(/Array\.isArray\(lr\.report\)/.test(js), "lastrun falls back to report lines");
t(/white-space:pre-line/.test(html), "lastrun preserves line breaks");
t(/\["btnStart",\s*"btnStop",\s*"btnSkip",\s*"btnEmergency",\s*"btnRecover"\]/.test(js), "status-fail disables start-dependent buttons");
t(js.includes('livePlat").textContent = "—"'), "live-fail clears platform");
t(js.includes('"kJoined"') && js.includes('"kSkipped"') && js.includes('"kFailed"'), "live-fail clears counters");
t(js.includes("扩展未响应"), "status-fail message");
if (fails > 0) { console.log("sidepanel_states: " + fails + " FAILED"); process.exit(1); }
console.log("sidepanel_states: all PASS");