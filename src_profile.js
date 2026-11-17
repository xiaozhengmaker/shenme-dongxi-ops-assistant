/* 业务方向 · 只读预览 */
(function () {
  var HUB = 'http://127.0.0.1:8787';
  var $ = function (s) { return document.querySelector(s); };
  var el = function (t, c) { var d = document.createElement(t); if (c) d.className = c; return d; };

  var state = { rec: null, cfg: null };

  var TYPE_LABEL = {
    case_opening: '开箱站', trading: '交易平台', community: '综合社区'
  };
  var INTENT_LABEL = {
    case_opening: '开箱玩家', trading: '皮肤交易者', giveaway: '白嫖/赠品党',
    community: '综合游戏社区', esports: '电竞观赛', team_recruit: '战队招募', lfg: '找队友'
  };

  /* ---------- 业务描述分析 ---------- */
  $('#btnAnalyze').addEventListener('click', analyze);
  $('#btnReanalyze').addEventListener('click', analyze);

  function analyze() {
    var text = ($('#biz').value || '').trim();
    if (!text) { $('#analyzeHint').textContent = '先写一句你做什么'; return; }
    fetch(HUB + '/api/profile/analyze', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: text })
    }).then(function (r) { return r.json(); }).then(function (d) {
      state.rec = d;
      renderPreview();
    }).catch(function (e) {
      $('#analyzeHint').textContent = '分析失败：' + e;
    });
  }

  function renderPreview() {
    var r = state.rec;
    $('#preview').style.display = '';

    // 业务类型
    var box = $('#types'); box.innerHTML = '';
    ['case_opening', 'trading', 'community'].forEach(function (k) {
      var b = el('span', 'pill' + (r.business_type === k ? ' on' : ''));
      b.textContent = TYPE_LABEL[k] || k;
      b.onclick = function () { r.business_type = k; renderPreview(); };
      box.appendChild(b);
    });

    renderChips('#regions', r.regions, r, 'regions');
    renderChips('#langs', r.languages, r, 'languages');
    renderChips('#excl', r.exclude, r, 'exclude', true);

    // 意图权重
    var ib = $('#intents'); ib.innerHTML = '';
    Object.keys(r.intents).sort(function (a, b) { return r.intents[b] - r.intents[a]; }).forEach(function (k) {
      ib.appendChild(barRow(INTENT_LABEL[k] || k, r.intents[k], 0, 1, 0.05, function (v) {
        r.intents[k] = v; renderQuotas(); refreshLabels();
      }));
    });

    // 门槛
    var tb = $('#thresholds'); tb.innerHTML = '';
    ['case_opening', 'trading', 'community'].forEach(function (k) {
      if (!(k in r.thresholds)) return;
      var t = r.thresholds[k];
      var row = el('div', 'bar');
      row.style.gridTemplateColumns = '96px 90px 74px 66px 1fr';
      var nm = el('div', 'nm'); nm.textContent = INTENT_LABEL[k];
      var m1 = el('input', 'num'); m1.type = 'number'; m1.value = t.min_members;
      m1.onchange = function () { t.min_members = +m1.value || 0; };
      var m2 = el('input', 'num'); m2.type = 'number'; m2.value = t.recent_days;
      m2.onchange = function () { t.recent_days = +m2.value || 0; };
      var a = el('span', 'muted'); a.textContent = '人 · 近';
      var b = el('span', 'muted'); b.textContent = '天';
      row.appendChild(nm); row.appendChild(m1); row.appendChild(a); row.appendChild(m2); row.appendChild(b);
      tb.appendChild(row);
    });

    renderQuotas();
  }

  function refreshLabels() { /* 权重变化后只重画配额 */ }

  function barRow(name, val, min, max, step, onChange) {
    var row = el('div', 'bar');
    var nm = el('div', 'nm'); nm.textContent = name;
    var track = el('div', 'track');
    var fill = el('div', 'fill');
    fill.style.width = Math.round((val - min) / (max - min) * 100) + '%';
    track.appendChild(fill);
    track.onclick = function (e) {
      var rect = track.getBoundingClientRect();
      var p = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
      var v = Math.round((min + p * (max - min)) / step) * step;
      onChange(+v.toFixed(2));
      fill.style.width = Math.round((v - min) / (max - min) * 100) + '%';
    };
    var inp = el('input', 'num'); inp.type = 'number'; inp.value = val; inp.step = step;
    inp.onchange = function () {
      var v = Math.min(max, Math.max(min, +inp.value || 0));
      inp.value = v; onChange(v);
      fill.style.width = Math.round((v - min) / (max - min) * 100) + '%';
    };
    row.appendChild(nm); row.appendChild(track); row.appendChild(inp);
    return row;
  }

  function renderChips(sel, list, obj, key, allowAdd) {
    var box = $(sel); box.innerHTML = '';
    (list || []).forEach(function (v, i) {
      var c = el('span', 'chip');
      c.appendChild(document.createTextNode(v));
      var x = el('span', 'x'); x.textContent = '×';
      x.onclick = function () { obj[key].splice(i, 1); renderPreview(); };
      c.appendChild(x);
      box.appendChild(c);
    });
    if (allowAdd) {
      var a = el('span', 'chip add'); a.textContent = '＋ 添加';
      a.onclick = function () {
        var v = prompt('添加（逗号分隔）'); if (!v) return;
        obj[key] = obj[key].concat(v.split(/[,，\s]+/).filter(Boolean));
        renderPreview();
      };
      box.appendChild(a);
    }
  }

  function renderQuotas() {
    var r = state.rec, cfg = state.cfg;
    var box = $('#quotas'); box.innerHTML = '';
    if (!cfg || !r) return;
    var order = ['Telegram', 'Facebook', 'Reddit'];
    order.forEach(function (p) {
      var total = (cfg.quotas && cfg.quotas[p]) || 0;
      if (p === 'Reddit') {
        var d0 = el('div', 'qline');
        d0.innerHTML = '<b>' + p + '</b><span class="muted">—</span><span class="muted">只做覆盖率，不参与水位</span>';
        box.appendChild(d0);
        return;
      }
      var q = el('div', 'qline'); q.style.marginTop = '6px';
      var nm = el('div'); nm.innerHTML = '<b>' + p + '</b>';
      var tot = el('input', 'num'); tot.type = 'number'; tot.value = total;
      tot.onchange = function () {
        state.cfg.quotas[p] = +tot.value || 0; renderQuotas();
      };
      var rest = el('div', 'muted');
      q.appendChild(nm); q.appendChild(tot); q.appendChild(rest);
      box.appendChild(q);

      var keys = (p === 'Telegram') ? ['case_opening', 'trading', 'community'] : ['case_opening', 'trading'];
      var wsum = keys.reduce(function (s, k) { return s + (r.intents[k] || 0); }, 0) || 1;
      var alloc = {}, used = 0;
      keys.forEach(function (k) {
        alloc[k] = Math.floor(total * (r.intents[k] || 0) / wsum);
        used += alloc[k];
      });
      var spare = total - used;

      var line = el('div', 'row');
      line.style.paddingLeft = '14px';
      keys.forEach(function (k) {
        var c = el('span', 'chip');
        c.textContent = INTENT_LABEL[k] + ' ' + alloc[k];
        line.appendChild(c);
      });
      var sp = el('span', 'muted');
      sp.textContent = spare > 0 ? ('剩余 ' + spare + '（弹性补到最缺的意图）') : '已分配满';
      line.appendChild(sp);
      box.appendChild(line);
    });
  }

  /* ---------- 水位 ---------- */
  function loadWater() {
    fetch(HUB + '/api/water').then(function (r) { return r.json(); }).then(function (d) {
      $('#waterSub').textContent = d.subtitle || '';
      var box = $('#tanks'); box.innerHTML = '';
      (d.items || []).forEach(function (it) {
        box.appendChild(tank(it));
      });
      renderCoverage(d.coverage || []);
    }).catch(function (e) {
      $('#waterSub').textContent = '读取失败：' + e;
    });
  }

  function tank(it) {
    var w = el('div', 'tank');
    var g = el('div', 'glass');
    var wm = el('div', 'water');
    if (it.type === 'supply') {
      var pct = it.safe ? Math.min(100, Math.round(it.level / it.safe * 100)) : 0;
      wm.style.height = pct + '%';
      if (it.status === 'red') wm.className = 'water bad';
      else if (it.status === 'amber') wm.className = 'water warn';
      var sf = el('div', 'safe');
      sf.style.bottom = '100%';
      sf.style.bottom = (it.safe ? Math.min(100, 100) : 0) + '%';
      // 安全水位线：按 safe 归一化到 0..100，若 safe>level 就画在 level 之上
      g.appendChild(wm);
      var lineTop = 100 - Math.min(100, Math.round(it.level / it.safe * 100));
      sf.style.top = Math.max(0, Math.min(96, 100 - Math.min(100, Math.round(it.safe / it.safe * 100)))) + '%';
      sf.style.top = '0%';
      g.appendChild(sf);
    } else {
      wm.style.height = (it.pct || 0) + '%';
    }
    if (it.type === 'supply' && !it.level) { wm.style.height = '0%'; wm.className = 'water'; }
    w.appendChild(g);
    var nm = el('div', 'nm'); nm.textContent = it.platform;
    var st = el('div', 'st');
    if (it.type === 'supply') {
      st.innerHTML = '<b>' + it.level + ' / ' + it.safe + '</b><br>' +
        (it.level ? (it.days == null ? '数据不足' : ('还能撑 ' + it.days + ' 天')) : '池空 · 待补货') +
        ' <span class="tag ' + (it.status === 'green' ? 'g' : it.status === 'amber' ? 'y' : 'r') + '">' +
        (it.status === 'green' ? '绿' : it.status === 'amber' ? '黄' : '红') + '</span>';
    } else {
      st.innerHTML = (it.label || '') + '<div class="prog"><i style="width:' + (it.pct || 0) + '%"></i></div>';
    }
    w.appendChild(nm); w.appendChild(st);
    return w;
  }

  function renderCoverage(list) {
    var box = $('#cov'); box.innerHTML = '';
    if (!list.length) return;
    var t = el('div', 'muted');
    t.style.marginBottom = '6px';
    t.textContent = '覆盖率（覆盖型平台）';
    box.appendChild(t);
    list.forEach(function (c) {
      var row = el('div', 'row');
      row.innerHTML = '<b style="width:90px">' + c.platform + '</b>' +
        '<span class="muted">' + c.done + ' / ' + c.total + ' ' + (c.unit || '') + '</span>' +
        '<span class="tag ' + (c.status === 'green' ? 'g' : c.status === 'red' ? 'r' : 'y') + '">' +
        (c.note || '') + '</span>';
      box.appendChild(row);
    });
  }

  /* ---------- 初始化 ---------- */
  fetch(HUB + '/api/config').then(function (r) { return r.json(); }).then(function (c) {
    state.cfg = c;
    $('#biz').value = 'CS2 第三方开箱站（SkinVS），做箱子和皮肤交易，目标巴西/俄罗斯/土耳其/东南亚，不要战队招募和找队友';
    loadWater();
  }).catch(function () { loadWater(); });
})();
