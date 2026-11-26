// run_all.js — 侧栏/后台重构 + 预载的全部离线测试（无网络、无业务、无凭据、无临时业务数据）
// 用法：node extension/tests/run_all.js
"use strict";
const { spawnSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const ROOT = path.resolve(__dirname, "..", "..");
const suite = [
  ["extension/tests/panel_core.test.js", "侧栏纯逻辑"],
  ["extension/tests/preload_behavior.test.js", "预载行为（真实源码切片）"],
  ["extension/tests/preload_background.test.js", "预载后台行为（假 chrome / hostname 归属 / 空结果）"],
  ["extension/tests/probe_login.test.js", "登录探针三态（真实 probeLoginFn + 假 DOM，六平台）"],
  ["extension/tests/static_contract.test.js", "静态契约（单一入口/临时选平台/待确认/看板无入口/hub 未动）"],
  ["extension/tests/platform_routing.test.js", "平台路由（真实 background.js + 假 chrome/标签页：无执行器平台绝不注入 TG）"],
  ["tests/offline/sidepanel_start_payload.test.js", "回归：启动载荷"],
  ["tests/offline/ui_start_payload.test.js", "回归：单入口按钮文案与载荷"],
  ["tests/offline/sidepanel_states.test.js", "回归：侧栏状态渲染"]
];

let failed = 0;
for (const [rel, name] of suite) {
  const file = path.join(ROOT, rel);
  if (!fs.existsSync(file)) { console.log("MISSING " + rel); failed++; continue; }
  console.log("\n=== " + name + "  (" + rel + ") ===");
  const r = spawnSync(process.execPath, [file], { cwd: ROOT, stdio: "inherit" });
  if (r.status !== 0) { failed++; console.log("<<< FAILED: " + rel + " exit=" + r.status); }
}
console.log("\n" + (failed ? "SUITE FAILED: " + failed + " 个测试文件失败" : "SUITE PASSED: " + suite.length + " 个测试文件全部通过"));
process.exit(failed ? 1 : 0);
