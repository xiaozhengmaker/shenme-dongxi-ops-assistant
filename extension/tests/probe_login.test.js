// probe_login.test.js — 用真实 probeLoginFn（从 background.js 切片）跑假 DOM 行为测试。
// 目标：探针只凭「明确账户证据 / 明确登录表单证据」返回 true / false，其余一律 null（待确认）。
// 重点回归：Reddit shreddit-app/#header、Steam .playerAvatar、FB cookie 都不得当作登录证明。
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.resolve(__dirname, "..", "src", "background.js"), "utf8");

function sliceFunction(name) {
  const start = src.indexOf("function " + name + "(");
  if (start < 0) { console.error("SLICE MISS " + name); process.exit(1); }
  let depth = 0;
  for (let i = src.indexOf("{", start); i < src.length; i++) {
    const ch = src[i];
    if (ch === "{") depth++;
    else if (ch === "}") { depth--; if (depth === 0) return src.slice(start, i + 1); }
  }
  console.error("SLICE MISS end " + name); process.exit(1);
}

const probeSrc = sliceFunction("probeLoginFn");
const urlHostSrc = sliceFunction("urlHost");
const hostMatchesSrc = sliceFunction("hostMatches");

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + (extra === undefined ? "" : "  -> " + JSON.stringify(extra))); }
}

// —— 极简假 DOM：支持 #id / .class / tag / [attr] / [attr=v] / [attr*=v] / 逗号 / 后代 ——
function el(tag, opt) {
  opt = opt || {};
  const cls = opt.cls || "";
  const n = {
    tag: String(tag).toLowerCase(), id: opt.id || "",
    classes: cls ? cls.split(/\s+/).filter(Boolean) : [],
    attrs: Object.assign({}, opt.attrs || {}),
    children: [], parent: null
  };
  if (cls) n.attrs.class = cls;
  return n;
}
function nest(parent) {
  for (let i = 1; i < arguments.length; i++) {
    arguments[i].parent = parent;
    parent.children.push(arguments[i]);
  }
  return parent;
}
function parseCompound(s) {
  const out = { tag: "", id: "", classes: [], attrs: [] };
  let i = 0;
  const tm = /^[A-Za-z][\w-]*/.exec(s);
  if (tm) { out.tag = tm[0].toLowerCase(); i = tm[0].length; }
  while (i < s.length) {
    if (s[i] === "#") {
      const m = /^#([\w-]+)/.exec(s.slice(i));
      if (!m) break;
      out.id = m[1]; i += m[0].length;
    } else if (s[i] === ".") {
      const m = /^\.([\w-]+)/.exec(s.slice(i));
      if (!m) break;
      out.classes.push(m[1]); i += m[0].length;
    } else if (s[i] === "[") {
      const m = /^\[([\w-]+)(?:([*^$~|]?=)\s*(["']?)([^\]"']*?)\3)?\]/.exec(s.slice(i));
      if (!m) break;
      out.attrs.push({ name: m[1], op: m[2] || "", val: m[4] === undefined ? "" : m[4] });
      i += m[0].length;
    } else { i++; }
  }
  return out;
}
function matches(n, c) {
  if (c.tag && n.tag !== c.tag) return false;
  if (c.id && n.id !== c.id) return false;
  for (const cl of c.classes) { if (n.classes.indexOf(cl) < 0) return false; }
  for (const a of c.attrs) {
    if (!Object.prototype.hasOwnProperty.call(n.attrs, a.name)) return false;
    const v = String(n.attrs[a.name]);
    if (a.op === "=" && v !== a.val) return false;
    if (a.op === "*=" && v.indexOf(a.val) < 0) return false;
    if (a.op === "^=" && v.indexOf(a.val) !== 0) return false;
    if (a.op === "$=" && !v.endsWith(a.val)) return false;
  }
  return true;
}
// 选择器链拆分：引号内的空格不算分隔符（[aria-label="Your profile"]）
function splitChain(part) {
  const out = [];
  let cur = "", quote = "", depth = 0;
  for (let i = 0; i < part.length; i++) {
    const ch = part[i];
    if (quote) { cur += ch; if (ch === quote) quote = ""; continue; }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === "[" || ch === "(") { depth++; cur += ch; continue; }
    if (ch === "]" || ch === ")") { depth--; cur += ch; continue; }
    if (/\s/.test(ch) && depth === 0) { if (cur) { out.push(cur); cur = ""; } continue; }
    cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}
function querySelectorAll(all, sel) {
  const out = [];
  for (const raw of String(sel).split(",")) {
    const part = raw.trim();
    if (!part) continue;
    const chain = splitChain(part).map(parseCompound);
    if (!chain.length) continue;
    const last = chain[chain.length - 1];
    for (const n of all) {
      if (!matches(n, last)) continue;
      let cur = n.parent, okChain = true;
      for (let k = chain.length - 2; k >= 0; k--) {
        let found = false;
        while (cur) {
          if (matches(cur, chain[k])) { found = true; cur = cur.parent; break; }
          cur = cur.parent;
        }
        if (!found) { okChain = false; break; }
      }
      if (okChain) out.push(n);
    }
  }
  return out;
}
function documentOf(roots) {
  const all = [];
  const walk = (n) => { all.push(n); n.children.forEach(walk); };
  roots.forEach(walk);
  return {
    cookie: "",
    querySelector(sel) { return querySelectorAll(all, sel)[0] || null; }
  };
}

function runProbe(docObj, key) {
  const sandbox = { document: docObj, window: {}, String, Array, Object, URL };
  vm.createContext(sandbox);
  vm.runInContext(probeSrc, sandbox, { filename: "background.probe.slice.js" });
  return vm.runInContext("probeLoginFn(" + JSON.stringify(key) + ")", sandbox);
}

// —— 场景夹具：公开页（只有公开元素）/ 登录表单 / 已登录 ——
const PUBLIC = {
  telegram: () => documentOf([el("div", { id: "column-center" }), el("div", { id: "header" })]),
  facebook: () => {
    const d = documentOf([el("div", { id: "header" }), el("a", { attrs: { href: "/login" } })]);
    d.cookie = "c_user=100012345678"; // HttpOnly 之外也不可见；即便看得见也不能当证据
    return d;
  },
  discord: () => documentOf([el("div", { id: "app-mount" }), el("a", { attrs: { href: "/download" } })]),
  whatsapp: () => documentOf([el("div", { id: "app" }), el("div", { cls: "downloaded" })]),
  reddit: () => documentOf([
    nest(el("shreddit-app"),
      nest(el("div", { id: "header" }), el("faceplate-tracker")),
      el("div", { cls: "shreddit-post" }))
  ]),
  steam: () => documentOf([
    nest(el("div", { id: "header" }), el("img", { cls: "playerAvatar" })),
    el("div", { cls: "profile_header" })
  ])
};
const LOGIN_FORM = {
  telegram: () => documentOf([el("div", { id: "auth-pages" })]),
  facebook: () => documentOf([
    nest(el("form", { id: "login_form" }),
      el("input", { attrs: { name: "pass", type: "password" } }),
      el("input", { attrs: { name: "email" } }))
  ]),
  discord: () => documentOf([el("div", { cls: "authBox_abc123" })]),
  whatsapp: () => documentOf([el("div", { attrs: { "data-testid": "qrcode" } })]),
  reddit: () => documentOf([el("a", { attrs: { href: "/login" } })]),
  steam: () => documentOf([el("a", { cls: "global_action_link", attrs: { href: "https://store.steampowered.com/login/?redir=x" } })])
};
const LOGGED_IN = {
  telegram: () => documentOf([el("div", { cls: "chat-list" })]),
  facebook: () => documentOf([el("div", { attrs: { "aria-label": "Your profile" } })]),
  discord: () => documentOf([el("nav", { attrs: { "data-list-id": "guildsnav" } })]),
  whatsapp: () => documentOf([el("div", { id: "pane-side" })]),
  reddit: () => documentOf([el("button", { id: "expand-user-drawer-button" })]),
  steam: () => documentOf([el("div", { id: "account_pulldown" })])
};

const PLATFORMS = ["telegram", "facebook", "discord", "whatsapp", "reddit", "steam"];

for (const key of PLATFORMS) {
  ok("公开页 → null（" + key + "）", runProbe(PUBLIC[key](), key) === null);
  ok("登录表单 → false（" + key + "）", runProbe(LOGIN_FORM[key](), key) === false);
  ok("已登录证据 → true（" + key + "）", runProbe(LOGGED_IN[key](), key) === true);
}

// 明确点名的回归：这些公开元素过去会被误判成已登录
ok("回归：Reddit shreddit-app/#header 不证明登录", runProbe(PUBLIC.reddit(), "reddit") === null);
ok("回归：Steam .playerAvatar 不证明登录", runProbe(PUBLIC.steam(), "steam") === null);
ok("回归：FB cookie 不证明登录（也不证明未登录）", runProbe(PUBLIC.facebook(), "facebook") === null);

// 账户证据与登录表单同时存在 → 账户优先
{
  const doc = documentOf([
    el("form", { id: "login_form" }),
    el("div", { attrs: { "aria-label": "Your profile" } })
  ]);
  ok("同时有账户与登录表单 → true（账户优先）", runProbe(doc, "facebook") === true);
}
// 空白页 / 未知平台 / 选择器异常 → null
ok("空白页 → null", runProbe(documentOf([el("div")]), "telegram") === null);
ok("未知平台 → null", runProbe(LOGGED_IN.telegram(), "myspace") === null);
ok("空 key → null", runProbe(LOGGED_IN.telegram(), "") === null);
ok("querySelector 抛错 → null（探针不冒泡）", runProbe({ cookie: "", querySelector() { throw new Error("boom"); } }, "steam") === null);

// —— hostname 归属：解析后同名 host 或官方子域，禁止子串 ——
const host = (() => {
  const sandbox = { URL };
  vm.createContext(sandbox);
  vm.runInContext(urlHostSrc + "\n" + hostMatchesSrc, sandbox);
  return sandbox;
})();
const H = (u, want) => host.hostMatches(host.urlHost(u), want);
ok("host: 同名匹配", H("https://web.telegram.org/k/", "web.telegram.org") === true);
ok("host: 官方子域匹配", H("https://a.web.telegram.org/k/", "web.telegram.org") === true);
ok("host: 前缀伪装拒绝（evil-telegram.org）", H("https://evil-telegram.org/k/", "web.telegram.org") === false);
ok("host: 后缀伪装拒绝（telegram.org.evil.io）", H("https://telegram.org.evil.io/", "telegram.org") === false);
ok("host: notfacebook.com 拒绝", H("https://notfacebook.com/", "facebook.com") === false);
ok("host: m.facebook.com 归 facebook.com", H("https://m.facebook.com/", "facebook.com") === true);
ok("host: www.reddit.com 归 reddit.com", H("https://www.reddit.com/", "reddit.com") === true);
ok("host: 空 URL → 不匹配", H("", "facebook.com") === false);
ok("host: 非 URL → 不匹配", H("not a url", "facebook.com") === false);

console.log("\nprobe_login: " + (fail ? "FAIL pass=" + pass + " fail=" + fail : "all PASS (" + pass + ")"));
process.exit(fail ? 1 : 0);
