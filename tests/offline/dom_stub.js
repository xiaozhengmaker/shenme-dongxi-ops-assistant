"use strict";
// 最小 DOM 桩：只覆盖 pageFBJoinDirect 用到的选择器形态（单复合选择器 + 逗号列表）
function matchCompound(el, comp) {
  comp = String(comp || "").trim();
  if (!comp) return false;
  const m = comp.match(/^([a-zA-Z0-9_*-]*)((?:\[[^\]]*\])*)$/);
  if (!m) return false;
  const tag = m[1] || "*";
  if (tag !== "*" && el.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  const attrRe = /\[([@\w-]+)(?:(\*?)=["']?([^\]"']*)["']?)?\]/g;
  let a;
  while ((a = attrRe.exec(m[2]))) {
    const have = el.getAttribute(a[1]);
    if (have === null) return false;
    if (!a[2]) continue;
    if (a[2] === "*" ? String(have).indexOf(a[3]) === -1 : String(have) !== a[3]) return false;
  }
  return true;
}
function matchSelector(el, sel) { return String(sel).split(",").some(c => matchCompound(el, c)); }

class El {
  constructor(tag, attrs) {
    this.tagName = String(tag || "div").toUpperCase();
    this.attrs = Object.assign({}, attrs || {});
    this.children = [];
    this.parentElement = null;
    this.text = "";
    this.clicks = 0;
    El.all.push(this);
  }
  append(c) { c.parentElement = this; this.children.push(c); return c; }
  appendText(t) { this.text += " " + String(t); return this; }
  getAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; }
  setAttribute(n, v) { this.attrs[n] = String(v); }
  get innerText() {
    const parts = [];
    if (this.text.trim()) parts.push(this.text.trim());
    for (const c of this.children) { const t = c.innerText; if (t) parts.push(t); }
    return parts.join(" ");
  }
  querySelectorAll(sel) {
    const out = [];
    const walk = n => { for (const c of n.children) { if (matchSelector(c, sel)) out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  querySelector(sel) { const r = this.querySelectorAll(sel); return r.length ? r[0] : null; }
  click() { this.clicks++; this.clickedAt = Date.now(); if (typeof this.__onClick === "function") { this.__onClick(this); } }
}
El.all = [];

function makeEnv(tree, url) {
  El.all = [];
  const main = tree;
  const doc = {
    querySelector: sel => (matchSelector(main, sel) ? main : main.querySelector(sel)),
    querySelectorAll: sel => { const out = []; if (matchSelector(main, sel)) out.push(main); return out.concat(main.querySelectorAll(sel)); },
    body: main
  };
  const loc = { href: url };
  const win = {};
  let queue = [];
  const setTimeoutFn = (fn) => { queue.push(fn); return 1; };
  const runTimers = (max = 400) => {
    let i = 0;
    while (queue.length && i++ < max && !win.__dshRes) {
      const fn = queue.shift();
      try { fn(); } catch (e) { win.__dshErr = String(e && e.message || e); }
    }
    return i;
  };
  return { doc, loc, win, setTimeoutFn, runTimers };
}
module.exports = { El, makeEnv };