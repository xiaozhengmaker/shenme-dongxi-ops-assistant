// 设置面板 + 绑定（由 dashboard.html 引用）
(function(){
  function el(id){ return document.getElementById(id); }
  var CUR = null;
  var BEH = [['discover','发现'],['join','加入'],['members','成员']];

  function rowHtml(p){
    var q = (CUR.quotas || {})[p] || 0;
    var en = ((CUR.platformsEnabled || {})[p]) === true;
    var b = (CUR.behaviors || {})[p] || {};
    var beh = BEH.map(function(x){
      var ck = b[x[0]] ? ' checked' : '';
      return '<label style="font-size:11.5px;margin-right:7px;white-space:nowrap"><input type="checkbox" data-b="'+x[0]+'" data-p="'+p+'"'+ck+'> '+x[1]+'</label>';
    }).join('');
    return '<div style="display:grid;grid-template-columns:86px 44px 66px 1fr;align-items:center;padding:6px 10px;border-top:1px solid #F0F1F3">'
      + '<span style="font-size:12.5px">'+p+'</span>'
      + '<span style="text-align:center"><input type="checkbox" data-en="'+p+'"'+(en?' checked':'')+'></span>'
      + '<span style="text-align:center"><input data-q="'+p+'" value="'+q+'" style="width:52px;padding:3px 6px;border:1px solid #E5E6EB;border-radius:6px;font-size:12.5px"></span>'
      + '<span style="text-align:center">'+beh+'</span>'
      + '</div>';
  }

  var NT = [['daily','日报'],['done','完成摘要'],['alerts','告警']];
  function platList(){ return (CUR && CUR.platforms) || []; }

  function renderNotify(){
    var n = (CUR && CUR.notify) || {};
    var ch = n.channels || {};
    var m = ch.main || {}, o = ch.ops || {};
    el("ntMain").value = m.webhook || "";
    el("ntMainEn").checked = m.enabled !== false;
    el("ntOps").value = o.webhook || "";
    el("ntOpsEn").checked = o.enabled === true;
    var pm = n.platforms || {};
    var box = el("ntRows"); if (!box) return;
    box.innerHTML = platList().map(function(p){
      var v = pm[p] || {};
      var cells = NT.map(function(t){
        return '<span style="text-align:center"><input type="checkbox" data-ntp="'+p+'" data-ntt="'+t[0]+'"'+(v[t[0]]===true?' checked':'')+' /></span>';
      }).join('');
      return '<div style="display:grid;grid-template-columns:88px 1fr 1fr 1fr;align-items:center;padding:5px 10px;border-top:1px solid #F0F1F3;font-size:12.5px">'+
             '<span>'+p+'</span>'+cells+'</div>';
    }).join('');
  }

  function collectNotify(){
    var pm = {};
    platList().forEach(function(p){ pm[p] = { daily:false, done:false, alerts:false }; });
    document.querySelectorAll("[data-ntp]").forEach(function(cb){
      pm[cb.getAttribute("data-ntp")][cb.getAttribute("data-ntt")] = cb.checked;
    });
    return {
      channels: {
        main: { label:"主群", webhook: el("ntMain").value.trim(), enabled: el("ntMainEn").checked },
        ops:  { label:"运维群", webhook: el("ntOps").value.trim(), enabled: el("ntOpsEn").checked }
      },
      platforms: pm,
      fallback_to_main: true
    };
  }

  function renderTable(){
    var box = el('platRows'); if (!box || !CUR) return;
    box.innerHTML = (CUR.platforms || []).map(rowHtml).join('');
  }
  function openSettings(){
    fetch('/api/config', {cache:'no-store'}).then(function(r){ return r.json(); }).then(function(c){
      CUR = c;
      var o = c.outputs || {}, s = c.schedule || {};
      el('oFeishu').checked = o.feishu !== false;
      el('oJsonl').checked = !!o.jsonl;
      el('oCsv').checked = !!o.csv;
      el('sEnabled').checked = s.enabled !== false;
      el('sTime').value = s.time || '10:00';
      renderTable();
    renderNotify();
      el('setMsg').textContent = '';
      el('mask').style.display = 'block';
    });
  }
  function closeSettings(){ el('mask').style.display = 'none'; }
  function saveSettings(){
    var q = {}, en = {}, beh = {};
    (CUR.platforms || []).forEach(function(p){ q[p] = 0; en[p] = false; beh[p] = {discover:false, join:false, members:false}; });
    Array.prototype.forEach.call(document.querySelectorAll('#platRows [data-q]'), function(inp){
      q[inp.getAttribute('data-q')] = parseInt(inp.value, 10) || 0;
    });
    Array.prototype.forEach.call(document.querySelectorAll('#platRows [data-en]'), function(inp){
      en[inp.getAttribute('data-en')] = !!inp.checked;
    });
    Array.prototype.forEach.call(document.querySelectorAll('#platRows [data-b]'), function(inp){
      var p = inp.getAttribute('data-p'), k = inp.getAttribute('data-b');
      if (!beh[p]) beh[p] = {};
      beh[p][k] = !!inp.checked;
    });
    var body = {
      outputs: { feishu: el('oFeishu').checked, jsonl: el('oJsonl').checked, csv: el('oCsv').checked },
      schedule: { enabled: el('sEnabled').checked, time: el('sTime').value },
      quotas: q, platformsEnabled: en, behaviors: beh, notify: collectNotify()
    };
    fetch('/api/config', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) })
      .then(function(r){ return r.json().then(function(d){ return { ok: r.ok, d: d }; }); })
      .then(function(x){
        if (!x.ok) { el('setMsg').textContent = '保存失败'; return; }
        var t = x.d.task || {};
        var msg = '已保存';
        if (t.registered === true) msg += ' · 计划任务已更新为每天 ' + t.time;
        else if (t.registered === false) msg += ' · 已关闭计划任务';
        el('setMsg').textContent = msg;
        if (CUR) { CUR.quotas = q; CUR.platformsEnabled = en; CUR.behaviors = beh; }
        if (typeof load === 'function') { load(); }
      })
      .catch(function(){ el('setMsg').textContent = '保存失败'; });
  }

  var btn = el('btnSettings'); if (btn) btn.addEventListener('click', openSettings);
  ['btnCloseSet','btnCancelSet'].forEach(function(id){ var b = el(id); if (b) b.addEventListener('click', closeSettings); });
  var bs = el('btnSaveSet'); if (bs) bs.addEventListener('click', saveSettings);
})();
