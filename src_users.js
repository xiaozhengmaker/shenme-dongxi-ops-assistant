let PAGE = 1;
const SIZE = 50;

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
  });
}

function qs() {
  const p = new URLSearchParams();
  p.set("page", PAGE);
  p.set("size", SIZE);
  const q = document.getElementById("q").value.trim();
  if (q) p.set("q", q);
  const pf = document.getElementById("platform").value;
  if (pf) p.set("platform", pf);
  const role = document.getElementById("role").value;
  if (role) p.set("role", role);
  if (document.getElementById("uname").checked) p.set("uname", "1");
  return p.toString();
}

function platPill(p) {
  const map = { Facebook: "fb", Telegram: "tg", Reddit: "rd", Steam: "st", Discord: "dc" };
  const cls = map[p] || "";
  return '<span class="pill ' + cls + '">' + esc(p) + "</span>";
}

function fillPlatforms(plats) {
  const sel = document.getElementById("platform");
  if (!sel || sel.dataset.filled === "1") return;
  const keep = sel.value;
  plats.forEach(function (x) {
    const o = document.createElement("option");
    o.value = x.name; o.textContent = x.name + "（" + x.users.toLocaleString() + "）";
    sel.appendChild(o);
  });
  sel.dataset.filled = "1";
  sel.value = keep;
}

async function load() {
  document.getElementById("rows").innerHTML = '<tr><td colspan="6" class="empty">加载中…</td></tr>';
  let d = null;
  try {
    const r = await fetch("/api/users?" + qs(), { cache: "no-store" });
    d = await r.json();
  } catch (e) {}
  if (!d) {
    document.getElementById("rows").innerHTML = '<tr><td colspan="6" class="empty">读取失败</td></tr>';
    return;
  }
  const s = d.stats || {};
  const plats = (s.platforms || []).slice().sort(function (a, b) { return b.users - a.users; });
  fillPlatforms(plats);
  const top = plats.length ? plats[0].users : 1;
  const platRows = plats.map(function (x) {
    const pct = Math.max(2, Math.round(x.users / top * 100));
    return '<div class="platrow"><span>' + platPill(x.name) + '</span>' +
      '<span class="bar"><i style="width:' + pct + '%"></i></span>' +
      '<span class="num">' + x.users.toLocaleString() + ' 人 / ' + x.groups + ' 群</span></div>';
  }).join("");
  document.getElementById("stats").innerHTML =
    '<div class="stat"><b>' + (s.users || 0).toLocaleString() + '</b><span>样本总数</span></div>' +
    '<div class="stat"><b>' + (s.withUsername || 0).toLocaleString() + '</b><span>带用户名</span></div>' +
    '<div class="stat"><b>' + (s.mods || 0).toLocaleString() + '</b><span>管理员/版主</span></div>' +
    '<div class="stat"><b>' + (s.groups || 0).toLocaleString() + '</b><span>覆盖群数</span></div>' +
    '<div class="platcard"><h3>平台分布（人数 / 群数）</h3>' + platRows + '</div>';

  const rows = d.items || [];
  if (!rows.length) {
    document.getElementById("rows").innerHTML = '<tr><td colspan="6" class="empty">没有匹配的样本</td></tr>';
  } else {
    document.getElementById("rows").innerHTML = rows.map(function (x) {
      const role = x["角色"] === "管理员" ? '<span class="pill mod">管理员</span>' : esc(x["角色"] || "成员");
      const un = x["用户名"] ? "@" + esc(x["用户名"]) : '<span style="color:#c9cdd4">—</span>';
      const rawName = x["昵称"] || (x["用户名"] ? "@" + x["用户名"] : "") || x["用户ID"] || "—";
      const dispName = x["profile_url"]
        ? '<a href="' + esc(x["profile_url"]) + '" target="_blank" rel="noopener noreferrer">' + esc(rawName) + "</a>"
        : esc(rawName);
      return "<tr><td class='name'>" + dispName + "</td><td>" + un + "</td><td>" + platPill(x["平台"]) +
        "</td><td>" + esc(x["群名"]) + "</td><td>" + role + "</td><td>" + esc(x["采集日"]) + "</td></tr>";
    }).join("");
  }
  const pages = Math.max(1, Math.ceil((d.total || 0) / SIZE));
  document.getElementById("pageInfo").textContent = "第 " + PAGE + " / " + pages + " 页 · 共 " + (d.total || 0).toLocaleString() + " 条";
  document.getElementById("prev").disabled = PAGE <= 1;
  document.getElementById("next").disabled = PAGE >= pages;
}

document.getElementById("btnSearch").onclick = function () { PAGE = 1; load(); };
document.getElementById("btnReset").onclick = function () {
  document.getElementById("q").value = "";
  document.getElementById("platform").value = "";
  document.getElementById("role").value = "";
  document.getElementById("uname").checked = false;
  PAGE = 1; load();
};
document.getElementById("q").addEventListener("keydown", function (e) { if (e.key === "Enter") { PAGE = 1; load(); } });
document.getElementById("prev").onclick = function () { if (PAGE > 1) { PAGE--; load(); } };
document.getElementById("next").onclick = function () { PAGE++; load(); };
load();