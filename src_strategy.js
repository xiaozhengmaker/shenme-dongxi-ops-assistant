(function(){
  const $ = (s,r)=> (r||document).querySelector(s);
  let STRAT = null, ALERTS = null, EXT = {hits:0, at:""}, CUR = "Telegram", POOL = [];

  function fmt(n){ return n; }
  function esc(s){ return String(s==null?"":s).replace(/[&<>"]/g, c=>({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;" }[c])); }

  async function load(){
    const r = await fetch("/api/strategy");
    const j = await r.json();
    STRAT = j.strategy; ALERTS = j.alerts; EXT = j.extHits || {hits:0, at:""};
    try { const pr = await fetch("/api/pool"); const pj = await pr.json(); POOL = pj.keywords || []; } catch (e) { POOL = []; }
    render();
  }

  function tabs(){
    const box = $("#stratTabs");
    box.innerHTML = Object.keys(STRAT||{}).map(k =>
      `<div class="platTab ${k===CUR?'on':''}" data-k="${k}">${k}</div>`).join("");
    box.querySelectorAll(".platTab").forEach(el=>{
      el.onclick = ()=>{ CUR = el.dataset.k; render(); };
    });
  }

  function kwDel(el) {
  const k = el.getAttribute("data-k");
  const arr = STRAT[CUR].discovery.keywords || [];
  STRAT[CUR].discovery.keywords = arr.filter(function(x){ return x !== k; });
  render();
}
function kwAdd() {
  const inp = document.getElementById("kwNew");
  const v = (inp && inp.value || "").trim();
  if (!v) return;
  const arr = STRAT[CUR].discovery.keywords || [];
  if (arr.indexOf(v) < 0) arr.push(v);
  STRAT[CUR].discovery.keywords = arr;
  render();
}
function kwDelExt(el) {
  const k = el.getAttribute("data-k");
  const arr = STRAT[CUR].discovery.external_keywords || [];
  STRAT[CUR].discovery.external_keywords = arr.filter(function(x){ return x !== k; });
  render();
}
function kwAddExt() {
  const inp = document.getElementById("kwNewExt");
  const v = (inp && inp.value || "").trim();
  if (!v) return;
  const arr = STRAT[CUR].discovery.external_keywords || [];
  if (arr.indexOf(v) < 0) arr.push(v);
  STRAT[CUR].discovery.external_keywords = arr;
  render();
}

function poolAdd() {
  const inp = document.getElementById("poolNew");
  const v = (inp && inp.value || "").trim();
  if (!v) return;
  if (POOL.map(function(x){return x.toLowerCase();}).indexOf(v.toLowerCase()) < 0) POOL.push(v);
  poolSave();
}
function poolTake(el) {
  const k = el.getAttribute("data-k");
  const arr = STRAT[CUR].discovery.keywords || [];
  if (!arr.some(function(x){ return String(x).toLowerCase() === String(k).toLowerCase(); })) arr.push(k);
  STRAT[CUR].discovery.keywords = arr;
  render();
}
function poolDel(el) {
  const k = el.getAttribute("data-k");
  POOL = POOL.filter(function(x){ return x !== k; });
  poolSave();
}
async function poolSave() {
  try {
    await fetch("/api/pool", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ keywords: POOL }) });
  } catch (e) {}
  render();
}


function bindPoolToggle() { if (true) return; /* disabled */
  const cb = document.getElementById("usePool");
  if (!cb) return;
  cb.onchange = function () {
    STRAT[CUR].discovery.usePool = cb.checked;
    save();
  };
}

function render(){
    if (!STRAT) return;
    tabs();
    setTimeout(bindPoolToggle, 0);
    const s = STRAT[CUR];
    if (!s) { $("#stratBody").innerHTML = "<div class='hint'>该平台暂无策略</div>"; return; }
    const f = s.filters, d = s.discovery, p = s.pacing;
    const srcs = (d.sources||[]).slice().sort(function(a,b){ return (a.priority||9)-(b.priority||9); });
    const srcHtml = srcs.map(x=>`
      <div class="srcRow">
        <span class="srcTag">P${x.priority}</span>
        <b style="flex:1">${esc(x.label)}<div style="font-size:11px;color:#A8AEB8;font-weight:400">${esc(x.query_template||"")}</div></b>
        <label style="font-size:12px;color:#646A73"><input type="checkbox" data-src="${x.name}" ${x.enabled?"checked":""}> 启用</label>
        <input type="number" style="width:70px" data-srclim="${x.name}" value="${x.limit}">
      </div>`).join("");

    const extHint = (EXT.hits||0) === 0 ? `
      <div class="warnBox"><b>外部搜索最近一次命中 0 条</b>（${esc(EXT.at||"未运行")}）<br>
      建议：① 在「种子清单」里贴目标链接（当前最可靠）；② 换网络/加代理后重试；③ 关键词换成英文社区名，站外结果更可能带可加入链接。</div>` : `
      <div class="hint">外部搜索最近一次命中 <b>${EXT.hits}</b> 条（${esc(EXT.at||"")}）。</div>`;

    $("#stratBody").innerHTML = `
      <div class="sgrid">
        <div class="scard" style="grid-column:1 / -1">
          <h4>词条仓库<span class="srcTag">只当仓库，不会自动生效 · 点 + 加入当前平台</span></h4>
          <div class="sfld" style="margin-top:8px">仓库共 <b>${POOL.length}</b> 个 · 当前平台 <b>${CUR}</b> 自己维护 <b>${(d.keywords||[]).length}</b> 个</div>
          <div class="kwBox">${POOL.map(function(k){
             var inIt = (d.keywords||[]).some(function(x){ return String(x).toLowerCase() === String(k).toLowerCase(); });
             return '<span class="kwChip' + (inIt ? ' on' : '') + '">' + esc(k) +
               '<b class="kwAdd1" title="' + (inIt ? '已在当前平台' : '加入当前平台') + '" onclick="poolTake(this)" data-k="' + esc(k) + '">' + (inIt ? '✓' : '+') + '</b>' +
               '<b class="kwX" title="从仓库删除" onclick="poolDel(this)" data-k="' + esc(k) + '">×</b></span>';
           }).join("")}</div>
          <div class="kwAdd"><input id="poolNew" type="text" placeholder="新增到仓库（不自动加入平台）" onkeydown="if(event.key==='Enter'){poolAdd();}"><button class="btnSm" onclick="poolAdd()">加入仓库</button></div>
          <div class="hint">每个平台<b>各自一份词条</b>；仓库只是候选库，点 <b>+</b> 才加入当前平台，点 <b>×</b> 只从仓库移除。</div>
        </div>

        <div class="scard">
          <h4>① ${CUR === "Reddit" ? "板块要求" : "群组要求"}<span class="srcTag">${CUR}</span></h4>
          ${CUR === "Reddit"
            ? `<div class="sfld">最小订阅数 <input type="number" id="fMin" value="${f.min_subscribers || 10000}"></div>
               <div class="sfld">近 7 天至少发帖 <input type="number" id="fPosts" value="${f.recent_posts_7d || 3}"></div>`
            : `<div class="sfld">最小成员数 <input type="number" id="fMin" value="${f.min_members}"></div>`}
          <div class="sfld">必须公开群 <select id="fPub"><option value="true" ${f.require_public?'selected':''}>是</option><option value="false" ${!f.require_public?'selected':''}>否</option></select></div>
          <div class="sfld">近 N 天有发言 <input type="number" id="fDays" value="${f.recent_activity_days}"></div>
          <div class="sfld">允许语言 <input type="text" id="fLang" value="${esc((f.languages||[]).join(","))}" placeholder="en,ru 空=不限"></div>
          <div class="sfld">排除词(正则) <input type="text" id="fExcl" value="${esc(f.exclude_regex||"")}"></div>
          <div class="sfld">必含词 <input type="text" id="fMust" value="${esc((f.must_include||[]).join(","))}" placeholder="空=不限"></div>
          <div class="hint">人数不足时会分两轮放宽门槛（1/3 → 50），<b>最低不低于 50</b>。</div>
        </div>

        <div class="scard">
          <h4>② 搜索策略<span class="srcTag">按优先级执行</span></h4>
          ${srcHtml}
          ${extHint}
          <div class="sfld" style="margin-top:10px">站内关键词
            <span style="font-size:12px;color:#8A9099">${(d.keywords||[]).length} 个</span></div>
          <div class="kwBox" id="kwBox">${(d.keywords||[]).map(k=>`<span class="kwChip">${esc(k)}<b class="kwX" title="删除" onclick="kwDel(this)" data-k="${esc(k)}">×</b></span>`).join("")}</div>
          <div class="kwAdd"><input id="kwNew" type="text" placeholder="输入新关键词，回车添加" onkeydown="if(event.key==='Enter'){kwAdd();}"><button class="btnSm" onclick="kwAdd()">添加</button></div>

          <div class="hint">改动保存后<b>下一次运行生效</b>；站内搜索每次只返回少量结果，关键词越准越省配额。</div>
        </div>

        <div class="scard">
          <h4>③ 执行节奏</h4>
          <div class="sfld">加群间隔(秒) <input type="text" id="pGap" value="${p.interval_min}-${p.interval_max}"></div>
          <div class="sfld">搜索间隔(秒) <input type="text" id="pSrc" value="${p.search_delay_min}-${p.search_delay_max}"></div>
          <div class="sfld">连续失败熔断 <input type="number" id="pFail" value="${p.max_consecutive_fail}"></div>
          <div class="sfld">FLOOD_WAIT 额外等待 <input type="number" id="pPad" value="${p.flood_pad_sec}"></div>
          <div class="hint">间隔越大越安全，越小越快触发限流。</div>
        </div>

        <div class="scard">
          <h4>④ 告警<span class="srcTag">运维群</span></h4>
          <div class="sfld">启用告警 <select id="aOn"><option value="true" ${ALERTS.enabled?'selected':''}>开</option><option value="false" ${!ALERTS.enabled?'selected':''}>关</option></select></div>
          <div class="sfld" style="flex-direction:column;align-items:stretch">机器人 webhook
            <input type="text" id="aHook" value="${esc(ALERTS.webhook||"")}" placeholder="留空则用主群" style="width:100%;margin-top:6px">
          </div>
          <div class="sfld">探针间隔(秒) <input type="number" id="aProbe" value="${ALERTS.probe_seconds}"></div>
          <div class="sfld">连续失败阈值 <input type="number" id="aThr" value="${ALERTS.probe_fail_threshold}"></div>
          <div class="hint">触发项：探针失败、配额不足、FLOOD_WAIT、运行完成。</div>
        </div>
      </div>
      <div class="saveBar">
        <button class="btn" id="btnSReset">重新加载</button>
        <button class="btn primary" id="btnSSave">保存策略</button>
      </div>`;

    $("#btnSReset").onclick = load;
    $("#btnSSave").onclick = save;
  }

  async function save(){
    const s = STRAT[CUR];
    const gap = ($("#pGap").value||"45-180").split("-");
    const src = ($("#pSrc").value||"3-8").split("-");
    const patch = {
      filters: {
        min_members: parseInt($("#fMin").value,10)||0,
        require_public: $("#fPub").value === "true",
        recent_activity_days: parseInt($("#fDays").value,10)||7,
        languages: ($("#fLang").value||"").split(",").map(x=>x.trim()).filter(Boolean),
        exclude_regex: $("#fExcl").value||"",
        must_include: ($("#fMust").value||"").split(",").map(x=>x.trim()).filter(Boolean)
      },
      pacing: {
        interval_min: parseInt(gap[0],10)||45,
        interval_max: parseInt(gap[1]||gap[0],10)||180,
        search_delay_min: parseInt(src[0],10)||3,
        search_delay_max: parseInt(src[1]||src[0],10)||8,
        max_consecutive_fail: parseInt($("#pFail").value,10)||3,
        flood_pad_sec: parseInt($("#pPad").value,10)||20
      }
    };
    document.querySelectorAll("[data-src]").forEach(el=>{
      const n = el.dataset.src;
      const row = (s.discovery.sources||[]).find(x=>x.name===n);
      if (row) row.enabled = el.checked;
    });
    s.discovery.sources.forEach(x=>{
      const lim = document.querySelector(`[data-srclim="${x.name}"]`);
      if (lim) x.limit = parseInt(lim.value,10)||x.limit;
    });
    patch.discovery = {
      sources: s.discovery.sources,
      keywords: s.discovery.keywords || [],
      external_keywords: s.discovery.external_keywords || []
    };

    const body = {
      platform: CUR,
      patch: patch,
      alerts: {
        enabled: $("#aOn").value === "true",
        webhook: $("#aHook").value.trim(),
        probe_seconds: parseInt($("#aProbe").value,10)||60,
        probe_fail_threshold: parseInt($("#aThr").value,10)||3
      }
    };
    const r = await fetch("/api/strategy", { method:"POST", headers:{ "Content-Type":"application/json" }, body: JSON.stringify(body) });
    const j = await r.json();
    if (j.ok) { STRAT[CUR] = j.strategy; ALERTS = j.alerts; alert("已保存"); }
    else alert("保存失败");
  }

  $("#btnStrategy").addEventListener("click", ()=>{
    const v = $("#strategyView");
    const on = v.classList.contains("hidden");
    v.classList.toggle("hidden", !on);
    const ov = document.getElementById("overview");
    if (ov) ov.classList.toggle("hidden", on);
    if (on) load();
  });

  window.__stratLoad = load;
  window.poolTake = poolTake;

  window.poolAdd = poolAdd;
  window.poolDel = poolDel;
  window.kwAdd = kwAdd;
  window.kwDel = kwDel;
  window.kwAddExt = kwAddExt;
  window.kwDelExt = kwDelExt;
  window.__stratSave = save;
  window.__stratRender = render;
})();