"use strict";
const fs = require("fs");
const path = require("path");
const { El, makeEnv } = require("./dom_stub.js");

const bgPath = path.join(__dirname, "..", "..", "extension", "src", "background.js");
const src = fs.readFileSync(bgPath, "utf8");
const idx = src.indexOf("function pageFBJoinDirect(");
if (idx < 0) { console.log("FAIL cannot find pageFBJoinDirect"); process.exit(1); }
let depth = 0, end = idx;
for (let i = src.indexOf("{", idx); i < src.length; i++) {
  if (src[i] === "{") depth++;
  else if (src[i] === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
}
const fnSrc = src.slice(idx, end);

function build(fnBody) { return new Function("window", "document", "location", "setTimeout", fnSrc + "\n; return pageFBJoinDirect;")(fnBody.win, fnBody.doc, fnBody.loc, fnBody.setTimeoutFn); }
function el(tag, attrs, text) { const e = new El(tag, attrs); if (text) e.appendText(text); return e; }

const results = [];
function check(name, cond, detail) { results.push({ name, ok: !!cond, detail }); console.log((cond ? "[OK]   " : "[FAIL] ") + name + (detail ? "  :: " + detail : "")); }

function run(fn, body, arg) { fn(arg); body.runTimers(400); const raw = body.win.__dshRes || ""; let obj = {}; try { obj = JSON.parse(raw); } catch (e) { } return { raw, obj, err: body.win.__dshErr || "" }; }

// ---------- S1: 数字 ID 页面 + slug 作为 id，可证实时匹配并点击目标按钮 ----------
(function s1() {
  const main = el("div", { role: "main" });
  const header = main.append(el("div", {}));
  header.append(el("h1", {}, "Chợ Mua/Bán VN CS2 - CS:GO"));
  header.append(el("div", {}, "6,127 位成员 · 公开小组"));
  const link = header.append(el("a", { href: "/groups/445326196498552/" }, "Chợ Mua/Bán VN CS2 - CS:GO"));
  const actions = main.append(el("div", {}));
  const join = actions.append(el("div", { role: "button" }, "加入小组"));
  join.__onClick = () => header.appendText("已加入");
  const body = makeEnv(main, "https://www.facebook.com/groups/445326196498552/");
  const fn = build(body);
  const r = run(fn, body, { id: "chomuabanvncs2csgo", title: "Chợ Mua/Bán VN CS2 - CS:GO" });
  check("S1 数字ID+slug 可证实匹配（点击目标按钮 1 次）", join.clicks === 1, "v=" + r.obj.v + " e=" + r.obj.e + " clicks=" + join.clicks);
  check("S1 结果为 joined", r.obj.v === "joined", JSON.stringify(r.obj));
})();

// ---------- S2: 动作行在标题块上方第 8 层 ----------
(function s2() {
  const main = el("div", { role: "main" });
  const outer = main.append(el("div", {}));
  let cur = outer;
  const chain = [];
  for (let i = 0; i < 8; i++) { cur = cur.append(el("div", {})); chain.push(cur); }
  const header = cur.append(el("div", {}));
  header.append(el("h1", {}, "Deep Group Title"));
  header.append(el("div", {}, "1,234 位成员 · 公开小组"));
  header.append(el("a", { href: "/groups/deepgrouptitle/" }, "Deep Group Title"));
  const actions = outer.append(el("div", {}));
  const join = actions.append(el("div", { role: "button" }, "加入小组"));
  join.__onClick = () => header.appendText("已加入");
  const body = makeEnv(main, "https://www.facebook.com/groups/deepgrouptitle/");
  const fn = build(body);
  const r = run(fn, body, { id: "deepgrouptitle", title: "Deep Group Title" });
  check("S2 动作行在第 8 层仍能定位（点击 1 次）", join.clicks === 1, "v=" + r.obj.v + " e=" + r.obj.e + " clicks=" + join.clicks);
})();

// ---------- S3: 两个候选按钮（歧义）→ 零点击 ----------
(function s3() {
  const main = el("div", { role: "main" });
  const header = main.append(el("div", {}));
  header.append(el("h1", {}, "Ambiguous Group"));
  header.append(el("div", {}, "2,000 位成员"));
  header.append(el("a", { href: "/groups/ambiguous/" }, "Ambiguous Group"));
  const a1 = header.append(el("div", { role: "button" }, "加入小组"));
  const a2 = header.append(el("div", { role: "button" }, "加入小组"));
  const body = makeEnv(main, "https://www.facebook.com/groups/ambiguous/");
  const r = run(build(body), body, { id: "ambiguous", title: "Ambiguous Group" });
  check("S3 歧义零点击", a1.clicks === 0 && a2.clicks === 0, "v=" + r.obj.v + " e=" + r.obj.e + " clicks=" + (a1.clicks + a2.clicks));
})();

// ---------- S4: 邻卡（推荐小组）里的加入按钮零点击 ----------
(function s4() {
  const main = el("div", { role: "main" });
  const header = main.append(el("div", {}));
  header.append(el("h1", {}, "Target No Action"));
  header.append(el("div", {}, "500 位成员"));
  header.append(el("a", { href: "/groups/targetnoaction/" }, "Target No Action"));
  const rec = main.append(el("div", {}, "推荐小组"));
  const card = rec.append(el("div", { role: "article" }));
  card.append(el("a", { href: "/groups/other999/" }, "Other 999"));
  const nJoin = card.append(el("div", { role: "button" }, "加入小组"));
  const body = makeEnv(main, "https://www.facebook.com/groups/targetnoaction/");
  const r = run(build(body), body, { id: "targetnoaction", title: "Target No Action" });
  check("S4 邻卡加入按钮零点击", nJoin.clicks === 0, "v=" + r.obj.v + " e=" + r.obj.e + " clicks=" + nJoin.clicks);
})();

// ---------- S5: 待审批横幅 → request_sent 且零点击 ----------
(function s5() {
  const main = el("div", { role: "main" });
  const header = main.append(el("div", {}));
  header.append(el("h1", {}, "Pending Group"));
  header.append(el("div", {}, "800 位成员"));
  header.append(el("a", { href: "/groups/pendinggroup/" }, "Pending Group"));
  header.append(el("div", {}, "你的加入请求待审核"));
  const cancel = header.append(el("div", { role: "button" }, "取消请求"));
  const body = makeEnv(main, "https://www.facebook.com/groups/pendinggroup/");
  const r = run(build(body), body, { id: "pendinggroup", title: "Pending Group" });
  check("S5 pending → request_sent 且零点击", r.obj.v === "request_sent" && cancel.clicks === 0, "v=" + r.obj.v + " e=" + r.obj.e);
})();

// ---------- S6: 已加入 → already 且零点击（重复成功不重复计数由 hub 侧映射保证） ----------
(function s6() {
  const main = el("div", { role: "main" });
  const header = main.append(el("div", {}));
  header.append(el("h1", {}, "Joined Group"));
  header.append(el("div", {}, "900 位成员"));
  header.append(el("a", { href: "/groups/joinedgroup/" }, "Joined Group"));
  const jr = header.append(el("div", { role: "button" }, "已加入"));
  const body = makeEnv(main, "https://www.facebook.com/groups/joinedgroup/");
  const r = run(build(body), body, { id: "joinedgroup", title: "Joined Group" });
  check("S6 已加入 → already 且零点击", r.obj.v === "already" && jr.clicks === 0, "v=" + r.obj.v + " e=" + r.obj.e);
})();

const fail = results.filter(r => !r.ok).length;
console.log("");
console.log("FB FIXTURES: " + (results.length - fail) + "/" + results.length + " passed");
process.exit(fail === 0 ? 0 : 2);