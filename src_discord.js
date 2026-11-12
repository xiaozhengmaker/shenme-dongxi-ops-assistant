(function () {
  var ALL = [];

  function esc(s) {
    return String(s == null ? "" : s).replace(/[<>&"]/g, function (c) {
      return { "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c];
    });
  }

  function render() {
    var q = (document.getElementById("q").value || "").trim().toLowerCase();
    var rows = ALL.filter(function (x) {
      if (!q) return true;
      return [x.kw, x.code, x.title, x.ctx, x.src].join(" ").toLowerCase().indexOf(q) >= 0;
    });

    var tb = document.getElementById("tbody");
    tb.innerHTML = rows.map(function (x) {
      return "<tr>" +
        '<td class="src">' + esc(x.ts) + "</td>" +
        '<td><span class="kw">' + esc(x.kw) + "</span></td>" +
        '<td class="code"><a href="' + esc(x.url) + '" target="_blank" rel="noreferrer">' + esc(x.code) + "</a></td>" +
        "<td><div>" + esc(x.title || "—") + '</div><div class="ctx">' + esc(x.ctx || "") + "</div></td>" +
        '<td class="src">' + esc(x.src) + "</td>" +
        "</tr>";
    }).join("");

    document.getElementById("empty").style.display = rows.length ? "none" : "block";
    document.getElementById("tb").style.display = rows.length ? "table" : "none";
    document.getElementById("kTotal").textContent = ALL.length;
    var codes = {};
    var kws = {};
    ALL.forEach(function (x) {
      if (x.code) codes[String(x.code).toLowerCase()] = 1;
      if (x.kw) kws[x.kw] = 1;
    });
    document.getElementById("kCodes").textContent = Object.keys(codes).length;
    document.getElementById("kKw").textContent = Object.keys(kws).length;
  }

  function loadCover() {
    fetch("/api/summary").then(function (r) { return r.json(); }).then(function (s) {
      var arr = s.platforms || [];
      var hit = null;
      arr.forEach(function (x) { if (String(x.name || "").toLowerCase() === "discord") hit = x; });
      var el = document.getElementById("kCover");
      el.textContent = hit ? (hit.groups + " 群 · " + fmtNum(hit.members)) : "\u2014";
    }).catch(function () { document.getElementById("kCover").textContent = "\u2014"; });
  }

  function fmtNum(n) {
    n = Number(n) || 0;
    if (n >= 10000) return (n / 10000).toFixed(1) + "w";
    if (n >= 1000) return (n / 1000).toFixed(1) + "k";
    return String(n);
  }

  function load() {
    fetch("/api/discord_links").then(function (r) { return r.json(); }).then(function (d) {
      ALL = (d.items || []);
      render();
    }).catch(function () { ALL = []; render(); });
  }

  document.getElementById("q").addEventListener("input", render);
  document.getElementById("btnReload").addEventListener("click", function () { load(); loadCover(); });
  load();
  loadCover();
  setInterval(load, 30000);
})();
