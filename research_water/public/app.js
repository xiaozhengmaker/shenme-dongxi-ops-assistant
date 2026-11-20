'use strict';

const state = { profiles: [], profile: null, health: null, researchProfiles: [], answer: null, asking: false, researchDraft: null, researchProvider: null, researchBrief: null, researchBusy: false, studio: { understanding: null, workbench: null, busy: false, selected: new Set(), confirmedFor: null, searchBusy: false, searchAbort: null, searchData: null } };
const $ = (sel) => document.querySelector(sel);

function esc(value) {
  return String(value === null || value === undefined ? '' : value).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function lines(value) {
  return String(value || '').split(/\n/).map((x) => x.trim()).filter(Boolean);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  let data = null;
  try { data = await response.json(); } catch { data = null; }
  if (!response.ok || (data && data.ok === false)) {
    const err = new Error(data && data.message ? data.message : `HTTP ${response.status}`);
    err.code = data && data.error ? data.error : 'http_error';
    err.status = response.status;
    err.details = data && data.details ? data.details : null;
    throw err;
  }
  return data;
}

function notice(kind, text) {
  const el = $('#globalMsg');
  el.className = `msg ${kind || ''}`;
  el.textContent = text;
  el.classList.remove('hidden');
  clearTimeout(notice.timer);
  notice.timer = setTimeout(() => el.classList.add('hidden'), 7000);
}

function statusLabel(status) {
  return {
    draft: '草稿 · 待校准',
    calibrated: '已校准 · 待确认',
    confirmed: '已确认锁定',
    researching: '已锁定 · 证据收集中',
    report: '已出报告',
  }[status] || status;
}

function providerText(p) {
  if (!p) return 'provider 未知';
  if (p.configured) return `${p.name} · ${p.model || '已配置'}`;
  return `${p.name} · 未配置（${p.reason || '无密钥'}）`;
}

async function loadHealth() {
  try {
    state.health = await api('/api/health');
    const p = state.health.provider;
    const badge = $('#providerBadge');
    badge.textContent = providerText(p);
    badge.className = `badge ${p.configured ? '' : 'bad'}`;
    $('#footProvider').textContent = `provider: ${providerText(p)}`;
    updateLiveSearchState();
    if (!p.configured) {
      notice('warn', `校准不可用：${p.reason || 'provider_not_configured'}。请配置服务端密钥；不会生成假结果。`);
    }
  } catch (err) {
    notice('bad', `服务状态读取失败：${err.message}`);
  }
}

async function loadProfiles() {
  try {
    const data = await api('/api/profiles');
    state.profiles = data.items || [];
    renderProfileList();
  } catch (err) {
    notice('bad', `档案列表读取失败：${err.message}`);
  }
}

async function loadResearchProfiles() {
  try {
    const data = await api('/api/research/profiles');
    state.researchProfiles = data.items || [];
    renderAskProfiles();
  } catch (err) {
    notice('bad', `已确认研究档案读取失败：${err.message}`);
  }
}

function renderAskProfiles() {
  const select = $('#askProfile');
  const current = select.value;
  const items = state.researchProfiles || [];
  select.innerHTML = '<option value="">不选择档案 · 不混用任何已有证据</option>' + items.map((p) =>
    `<option value="${esc(p.id)}">${esc(p.name)} · ${Number(p.evidence_count || 0)} 条证据</option>`
  ).join('');
  if (current && items.some((p) => p.id === current)) select.value = current;

  const studioSelect = $('#studioProfile');
  if (studioSelect) {
    const picked = studioSelect.value;
    studioSelect.innerHTML = '<option value="">自动判断 / 新建草稿（不混用其他档案证据）</option>' + items.map((p) =>
      `<option value="${esc(p.id)}">沿用：${esc(p.name)} · ${Number(p.evidence_count || 0)} 条证据</option>`
    ).join('');
    if (picked && items.some((p) => p.id === picked)) studioSelect.value = picked;
  }
}

function answerErrorText(err) {
  if (!err) return '提问失败';
  if (err.code === 'provider_not_configured') {
    return '服务端模型未配置。请在服务端设置 LEADS_WATER_API_KEY（及 BASE_URL/MODEL），或使用 fixture 演示模式；不会生成假结果。';
  }
  if (err.code === 'profile_not_confirmed') {
    return '该研究档案尚未确认并锁定；请先进入高级研究完成确认。问答不会自动锁定或改写固定人群标准。';
  }
  if (err.code === 'profile_not_found') return '选择的研究档案不存在，请刷新后重试。';
  if (err.code === 'provider_failed') return `模型调用失败：${err.message}。没有生成编造答案。`;
  return err.message || '提问失败';
}

function showAskError(err) {
  const box = $('#askMsg');
  box.className = 'msg bad';
  box.textContent = answerErrorText(err);
  box.classList.remove('hidden');
}

function showAskInfo(text) {
  const box = $('#askMsg');
  box.className = 'msg';
  box.textContent = text;
  box.classList.remove('hidden');
}

async function onAsk(event) {
  event.preventDefault();
  if (state.asking) return;
  const question = $('#questionInput').value.trim();
  if (!question) {
    showAskError({ message: '请输入一个关键问题。问题唯一必填。' });
    $('#questionInput').focus();
    return;
  }
  const profileId = $('#askProfile').value;
  state.asking = true;
  $('#btnAsk').disabled = true;
  $('#btnAsk').textContent = '回答中…';
  $('#askMsg').classList.add('hidden');
  try {
    const data = await api('/api/answer', {
      method: 'POST',
      body: JSON.stringify({ question, profile_id: profileId || undefined }),
    });
    state.answer = data;
    renderAnswer(data);
  } catch (err) {
    showAskError(err);
  } finally {
    state.asking = false;
    $('#btnAsk').disabled = false;
    $('#btnAsk').textContent = '提问';
  }
}

function renderAnswer(answer) {
  const view = $('#answerView');
  view.classList.remove('hidden');
  $('#answerContent').classList.remove('hidden');
  const mocked = Boolean(answer.provider && answer.provider.mocked);
  const banner = $('#fixtureBanner');
  banner.classList.toggle('hidden', !mocked);
  $('#answerMeta').textContent = [
    answer.provider ? (mocked ? 'fixture 演示' : answer.provider.name) : 'provider',
    `证据 ${Number(answer.evidence_used || 0)}/${Number(answer.evidence_available || 0)}`,
    answer.profile ? `档案：${answer.profile.name}` : '未选择档案',
  ].join(' · ');
  $('#answerQuestion').textContent = answer.question;

  const assumptions = (answer.assumptions || []).map((a) =>
    `<li>${esc(a.text)}${a.basis ? ` <span class="hint">（依据：${esc(a.basis)}）</span>` : ''}</li>`
  ).join('');
  $('#answerAssumptions').innerHTML = assumptions || '<li class="muted">无明示假设。</li>';

  const citations = new Map((answer.citations || []).map((c) => [c.id, c]));
  const findings = answer.evidence_findings || [];
  $('#answerEvidence').innerHTML = findings.length
    ? findings.map((f) => {
        const refs = (f.citation_ids || []).map((id) => citations.get(id)).filter(Boolean);
        return `<div class="finding"><p>${esc(f.statement)}</p>${refs.map((c) =>
          `<div class="citation"><b>${esc(c.title)}</b><div class="meta">${esc(c.source_domain)} · ${esc(c.channel)} · 地域 ${esc(c.region)} · 语言 ${esc(c.language)}</div>
            <div class="quote">${esc(c.quote)}</div><a href="${esc(c.url)}" target="_blank" rel="noopener noreferrer">查看来源</a></div>`
        ).join('')}</div>`;
      }).join('')
    : '<p class="hint">没有与问题直接相关、可核对且已确认的证据。下面的推断与条件判断不冒充证据。</p>';

  const inferences = (answer.inferences || []).map((x) =>
    `<li>${esc(x.statement)}${x.basis ? ` <span class="hint">（依据：${esc(x.basis)}）</span>` : ''}</li>`
  ).join('');
  $('#answerInferences').innerHTML = inferences || '<li class="muted">无推断。</li>';

  const unknowns = (answer.unknowns || []).map((x) => `<li>${esc(x)}</li>`).join('');
  $('#answerUnknowns').innerHTML = unknowns || '<li class="muted">无明示未知项。</li>';

  $('#answerConditional').textContent = answer.conditional_judgment || '现有信息不足，暂时无法给出确定回答。';
  $('#answerValidation').innerHTML = (answer.validation || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li class="muted">尚未给出验证方向。</li>';

  const follow = answer.follow_up;
  $('#answerFollowUpBlock').classList.toggle('hidden', !follow || !follow.question);
  if (follow && follow.question) {
    $('#answerFollowUp').innerHTML = `${esc(follow.question)}${follow.why ? ` <span class="hint">（${esc(follow.why)}）</span>` : ''}`;
    $('#btnUseFollowUp').onclick = () => {
      $('#questionInput').value = follow.question;
      $('#questionInput').focus();
      $('#askView').scrollIntoView({ behavior: 'smooth', block: 'start' });
    };
  }

  $('#answerLimitations').innerHTML = (answer.limitations || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li class="muted">无明示限制。</li>';
  $('#answerCitations').innerHTML = (answer.citations || []).length
    ? answer.citations.map((c) => `<div class="citation"><b>${esc(c.title)}</b>
        <div class="meta">${esc(c.source_domain)} · ${esc(c.channel)} · 信号 ${esc(c.signal_type)} · 地域 ${esc(c.region)} · 语言 ${esc(c.language)}</div>
        <div class="quote">${esc(c.quote)}</div><a href="${esc(c.url)}" target="_blank" rel="noopener noreferrer">${esc(c.url)}</a></div>`).join('')
    : '<p class="hint">未引用任何已有证据。</p>';
  view.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function researchTypeLabel(type) {
  return { primary: '主要人群', opinion: '意见人群' }[type] || '人群';
}

function splitTokens(value) {
  return Array.from(new Set(String(value || '').split(/[,，\n]/).map((x) => x.trim()).filter(Boolean)));
}

function showResearchMsg(kind, text) {
  const box = $('#researchMsg');
  box.className = `msg ${kind || ''}`;
  box.textContent = text;
  box.classList.remove('hidden');
}

function syncHomeQuestion() {
  const home = $('#questionInput').value.trim();
  const target = $('#researchQuestion');
  if (home && !target.value.trim()) target.value = home;
}

function renderResearchDraft(draft, provider) {
  state.researchDraft = draft;
  state.researchProvider = provider || null;
  $('#researchDraftView').classList.remove('hidden');
  $('#researchBriefView').classList.add('hidden');
  $('#researchMsg').classList.add('hidden');
  const mocked = Boolean(provider && provider.mocked);
  const banner = $('#researchFixtureBanner');
  banner.classList.toggle('hidden', !mocked);
  banner.textContent = 'fixture 演示草稿：合成规则生成，不是真实模型，也不是真实研究结论。';
  const gap = draft.context_gap;
  const gapBox = $('#researchGapBox');
  if (gap && gap.question) {
    gapBox.className = 'msg warn';
    gapBox.innerHTML = `<b>可选补充一项：</b>${esc(gap.question)}${gap.why ? ` <span class="hint">（${esc(gap.why)}）</span>` : ''}
      <button type="button" id="btnGapContinue" class="btn small ghost">按假设继续</button>`;
    gapBox.classList.remove('hidden');
    const btn = $('#btnGapContinue');
    if (btn) btn.onclick = () => onConfirmResearch();
  } else {
    gapBox.classList.add('hidden');
    gapBox.innerHTML = '';
  }
  const b = draft.business || {};
  $('#researchBusiness').innerHTML = `<div><b>${esc(b.name)}</b>
    <p>${esc(b.description)}</p>
    <p><span class="hint">问题：</span>${esc(b.problem)}</p>
    <p><span class="hint">决策目的：</span>${esc(b.decision_purpose)}</p>
    <p><span class="hint">使用者价值：</span>${esc((b.value_user || []).join('；'))}</p>
    <p><span class="hint">付费者价值：</span>${esc((b.value_payer || []).join('；'))}</p></div>`;
  const strength = draft.evidence_strength || {};
  $('#researchStrength').innerHTML = `<div><b>${esc(strength.level || 'low')}</b>
    <p>${esc(strength.rationale || '目前只有问题描述，证据强弱为假设。')}</p>
    ${(strength.gaps || []).length ? `<ul>${strength.gaps.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>` : ''}</div>`;
  $('#researchAudiences').innerHTML = (draft.audiences || []).map((a, i) => `
    <div class="research-aud" data-index="${i}">
      <div class="research-aud-head">
        <input data-field="label" value="${esc(a.label)}" aria-label="人群名称" />
        <select data-field="type" aria-label="人群类型">
          <option value="primary"${a.type === 'primary' ? ' selected' : ''}>主要人群</option>
          <option value="opinion"${a.type === 'opinion' ? ' selected' : ''}>意见人群</option>
        </select>
        <select data-field="evidence_strength" aria-label="证据强弱">
          ${['low', 'medium', 'high'].map((x) => `<option value="${x}"${a.evidence_strength === x ? ' selected' : ''}>证据 ${x}</option>`).join('')}
        </select>
        <label class="inline"><input type="checkbox" data-field="overlap"${a.overlap ? ' checked' : ''} /> 可重叠</label>
      </div>
      <label>入选标准（每行一条）
        <textarea data-field="inclusion" rows="2">${esc((a.inclusion || []).join('\n'))}</textarea>
      </label>
      <label>排除标准（每行一条）
        <textarea data-field="exclusion" rows="2">${esc((a.exclusion || []).join('\n'))}</textarea>
      </label>
      <p class="hint">${esc(a.rationale || '')}</p>
    </div>`).join('');
  const criteria = draft.criteria || {};
  $('#researchInclude').innerHTML = `<textarea id="researchIncludeEdit" rows="3">${esc((criteria.inclusion || []).join('\n'))}</textarea>`;
  $('#researchExclude').innerHTML = `<textarea id="researchExcludeEdit" rows="3">${esc((criteria.exclusion || []).join('\n'))}</textarea>`;
  $('#researchChannels').innerHTML = `<textarea id="researchChannelsEdit" rows="2" placeholder="逗号或换行分隔">${esc((draft.channels || []).join('\n'))}</textarea>`;
  $('#researchKeywords').innerHTML = `<textarea id="researchKeywordsEdit" rows="2" placeholder="逗号或换行分隔">${esc((draft.keywords || []).join('\n'))}</textarea>`;
  const assumptions = (draft.assumptions || []).map((x) => `<li>${esc(x.text)}${x.basis ? ` <span class="hint">（依据：${esc(x.basis)}）</span>` : ''}</li>`).join('');
  const limitations = (draft.limitations || []).map((x) => `<li>${esc(x)}</li>`).join('');
  $('#researchNotes').innerHTML = `<div class="hint">假设</div><ul>${assumptions || '<li>无</li>'}</ul><div class="hint">限制</div><ul>${limitations || '<li>无</li>'}</ul>`;
  $('#researchDraftView').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function collectResearchAudiences() {
  return Array.from(document.querySelectorAll('.research-aud')).map((root) => {
    const get = (name) => root.querySelector(`[data-field="${name}"]`);
    return {
      label: get('label') ? get('label').value.trim() : '',
      type: get('type') ? get('type').value : 'primary',
      overlap: Boolean(get('overlap') && get('overlap').checked),
      inclusion: lines(get('inclusion') ? get('inclusion').value : ''),
      exclusion: lines(get('exclusion') ? get('exclusion').value : ''),
      evidence_strength: get('evidence_strength') ? get('evidence_strength').value : 'low',
      rationale: '',
    };
  }).filter((a) => a.label);
}

async function onDraftResearch(event) {
  if (event) event.preventDefault();
  if (state.researchBusy) return;
  const question = $('#researchQuestion').value.trim();
  if (!question) {
    showResearchMsg('bad', '请先输入研究问题。问题唯一必填。');
    $('#researchQuestion').focus();
    return;
  }
  const background = $('#researchBackground').value.trim();
  state.researchBusy = true;
  $('#btnDraftResearch').disabled = true;
  $('#btnDraftResearch').textContent = '草拟中…';
  $('#researchMsg').classList.add('hidden');
  try {
    const data = await api('/api/research/draft', {
      method: 'POST',
      body: JSON.stringify({ question, background }),
    });
    renderResearchDraft(data.draft, data.provider);
  } catch (err) {
    const code = err.code || '';
    const text = code === 'provider_not_configured'
      ? '服务端未配置真实 provider，无法生成草稿；不会用模板冒充。'
      : `草稿生成失败：${err.message}`;
    showResearchMsg('bad', text);
  } finally {
    state.researchBusy = false;
    $('#btnDraftResearch').disabled = false;
    $('#btnDraftResearch').textContent = '生成研究草稿';
  }
}

async function onConfirmResearch() {
  if (state.researchBusy) return;
  const question = $('#researchQuestion').value.trim();
  if (!question) {
    showResearchMsg('bad', '请先输入研究问题。');
    return;
  }
  if (!state.researchDraft) {
    showResearchMsg('bad', '请先生成研究草稿。');
    return;
  }
  const audiences = collectResearchAudiences();
  if (!audiences.length) {
    showResearchMsg('bad', '至少保留一个人群，研究谁由你最终决定。');
    return;
  }
  const draft = {
    ...state.researchDraft,
    audiences,
    criteria: {
      inclusion: lines($('#researchIncludeEdit') ? $('#researchIncludeEdit').value : ''),
      exclusion: lines($('#researchExcludeEdit') ? $('#researchExcludeEdit').value : ''),
    },
    channels: splitTokens($('#researchChannelsEdit') ? $('#researchChannelsEdit').value : ''),
    keywords: splitTokens($('#researchKeywordsEdit') ? $('#researchKeywordsEdit').value : ''),
  };
  state.researchBusy = true;
  $('#btnConfirmResearch').disabled = true;
  try {
    const data = await api('/api/research/confirm', {
      method: 'POST',
      body: JSON.stringify({
        question,
        background: $('#researchBackground').value.trim(),
        draft,
      }),
    });
    state.researchBrief = data.brief;
    renderResearchBrief(data.brief);
    notice('ok', '研究谁已确认；正式研究未被锁定。');
  } catch (err) {
    showResearchMsg('bad', `确认失败：${err.message}`);
  } finally {
    state.researchBusy = false;
    $('#btnConfirmResearch').disabled = false;
  }
}

function renderResearchBrief(brief) {
  $('#researchDraftView').classList.add('hidden');
  $('#researchBriefView').classList.remove('hidden');
  const mocked = Boolean(brief.fixture || (brief.provider && brief.provider.mocked));
  const banner = $('#researchBriefBanner');
  banner.classList.toggle('hidden', !mocked);
  banner.textContent = 'fixture 演示简报：合成数据，不代表真实市场或用户证据。';
  $('#researchBriefMeta').textContent = `${brief.question} · ${brief.provider ? brief.provider.name : 'provider'} · ${new Date(brief.updated_at).toLocaleString()}`;
  $('#briefLeadCount').textContent = String((brief.leads || []).length);
  $('#briefKeywordCount').textContent = String((brief.keywords || []).length);
  $('#briefChannelCount').textContent = String((brief.channels || []).length);
  $('#briefEvidenceCount').textContent = String(brief.evidence_count || 0);
  $('#researchBriefAudiences').innerHTML = (brief.audiences || []).map((a) => `
    <div class="research-aud readonly">
      <div class="research-aud-head"><b>${esc(a.label)}</b><span class="badge">${esc(researchTypeLabel(a.type))}</span>
        <span class="hint">${a.overlap ? '可重叠' : '不重叠'} · 证据 ${esc(a.evidence_strength)}</span></div>
      <div class="grid2"><div><div class="hint">入选</div><ul>${(a.inclusion || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li>无</li>'}</ul></div>
        <div><div class="hint">排除</div><ul>${(a.exclusion || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li>无</li>'}</ul></div></div>
    </div>`).join('');
  const criteria = brief.criteria || {};
  $('#researchBriefInclude').innerHTML = `<ul>${(criteria.inclusion || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li>无</li>'}</ul>`;
  $('#researchBriefExclude').innerHTML = `<ul>${(criteria.exclusion || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li>无</li>'}</ul>`;
  $('#researchBriefLeads').innerHTML = (brief.leads || []).length
    ? `<ul>${brief.leads.map((x) => `<li>${esc(x.title || x.url || x)}</li>`).join('')}</ul>`
    : `<p class="hint">${esc(brief.leads_note || '本版不自动搜索，因此可用线索为空。这不等于没有需求。')}</p>`;
  $('#researchBriefBlind').innerHTML = `<ul>${((brief.coverage && brief.coverage.blind_spots) || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li>尚无证据</li>'}</ul>`;
  $('#researchBriefKeywords').innerHTML = (brief.keywords || []).map((x) => `<span class="chip">${esc(x)}</span>`).join('') || '<span class="hint">无</span>';
  $('#researchBriefChannels').innerHTML = (brief.channels || []).map((x) => `<span class="chip">${esc(x)}</span>`).join('') || '<span class="hint">无</span>';
  $('#researchBriefLimits').innerHTML = `<ul>${(brief.limitations || []).map((x) => `<li>${esc(x)}</li>`).join('') || '<li>无</li>'}</ul>
    <p class="hint">${esc(brief.leads_note || '')}</p>`;
  $('#researchBriefView').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function renderProfileList() {
  const box = $('#profileList');
  if (!state.profiles.length) {
    box.innerHTML = '<div class="muted pad">还没有档案。</div>';
    return;
  }
  box.innerHTML = state.profiles.map((p) => `
    <div class="profile-item ${state.profile && state.profile.id === p.id ? 'on' : ''}" data-id="${esc(p.id)}">
      <b>${esc(p.name)}</b>
      <small>${esc(statusLabel(p.status))} · ${esc(p.evidence_count || 0)} 条证据</small>
    </div>`).join('');
  box.querySelectorAll('.profile-item').forEach((el) => {
    el.addEventListener('click', () => openProfile(el.dataset.id));
  });
}

async function openProfile(id) {
  try {
    const data = await api(`/api/profiles/${encodeURIComponent(id)}`);
    state.profile = data.profile;
    $('#manualResearch').classList.remove('hidden');
    $('#emptyState').classList.add('hidden');
    $('#createPanel').classList.add('hidden');
    $('#profilePanel').classList.remove('hidden');
    renderProfile();
    renderProfileList();
  } catch (err) {
    notice('bad', `档案读取失败：${err.message}`);
  }
}

function renderProfile() {
  const p = state.profile;
  if (!p) return;
  $('#pStatus').textContent = statusLabel(p.status);
  $('#pName').textContent = p.guidance.name;
  $('#pDesc').textContent = p.guidance.description;
  renderGuidance(p);
  renderCalibration(p);
  renderSamples(p);
  renderEvidenceForm(p);
  renderEvidence(p);
  renderReport(p);
  $('#btnCalibrate').disabled = ['confirmed', 'researching', 'report'].includes(p.status);
  $('#btnConfirm').disabled = p.status !== 'calibrated';
  $('#btnReport').disabled = !['confirmed', 'researching', 'report'].includes(p.status);
  $('#btnCalibrate').textContent = p.calibration ? '重新生成小样本校准' : '生成小样本校准';
}

function renderGuidance(p) {
  const g = p.guidance;
  const audiences = (g.audiences || []).map((a) => `
    <tr><td><b>${esc(a.label)}</b>${a.overlap ? ' <span class="term">可重叠</span>' : ''}</td>
    <td>${esc({ user: '使用者', payer: '付费者', both: '使用者+付费者' }[a.role] || a.role)}</td>
    <td>${esc({ included: '入选', uncertain: '不确定', excluded: '排除' }[a.status] || a.status || '入选')}</td>
    <td>${esc(a.rationale || '—')}</td></tr>`).join('');
  $('#guidanceView').innerHTML = `
    <div class="grid2">
      <div><div class="section-title">产品解决什么</div><div>${esc(g.description)}</div></div>
      <div><div class="section-title">决策目的</div><div>${esc(g.decision_purpose)}</div></div>
    </div>
    <div class="grid2" style="margin-top:12px">
      <div><div class="section-title">使用者可观察价值</div><ul>${(g.value_user || []).map((x) => `<li>${esc(x)}</li>`).join('')}</ul></div>
      <div><div class="section-title">付费者可观察价值</div><ul>${(g.value_payer || []).map((x) => `<li>${esc(x)}</li>`).join('')}</ul></div>
    </div>
    <div class="section-title">人群假设</div>
    <div class="scroll"><table><thead><tr><th>人群</th><th>角色</th><th>纳入结论</th><th>推断依据</th></tr></thead><tbody>${audiences}</tbody></table></div>
    <p class="hint">地域：${esc((g.regions || []).join('、') || '未知')} · 语言：${esc((g.languages || []).join('、') || '未知')} · 来源：${esc((g.sources || []).join('、') || '未指定')}</p>
    <p class="hint">搜索范围（可选）：${esc(g.search_scope || '未限定')} · 已有证据（可选）：${esc(g.existing_evidence || '无')}</p>`;
}

function renderSamples(p) {
  // 相关校准样本：锁定前用于复核取舍；它们是用户提供的样本，不是正式证据。
  const samples = Array.isArray(p.calibration_samples) ? p.calibration_samples : [];
  const form = $('#sampleForm');
  const locked = !!(p.calibration && p.calibration.locked);
  const editable = !locked && ['draft', 'calibrated'].includes(p.status);
  form.classList.toggle('disabled', !editable);
  form.querySelectorAll('input, textarea, select, button').forEach((el) => { el.disabled = !editable; });
  const select = $('#sampleAudience');
  const audiences = (p.guidance.audiences || []).map((a) => `<option value="${esc(a.id)}">${esc(a.label)}</option>`).join('');
  if (select.dataset.options !== audiences) {
    select.innerHTML = audiences;
    select.dataset.options = audiences;
  }
  const box = $('#sampleView');
  if (!samples.length) {
    box.className = 'muted';
    box.textContent = locked ? '校准已锁定；此前没有保存校准样本。' : '尚无校准样本。锁定前可添加少量有出处的样本。';
    return;
  }
  box.className = '';
  const label = { included: '保留', excluded: '排除', uncertain: '不确定' };
  box.innerHTML = `
    <div class="scroll"><table><thead><tr><th>结论</th><th>人群</th><th>来源/引用</th><th>理由</th></tr></thead><tbody>
      ${samples.map((s) => `<tr>
        <td><span class="term">${esc(label[s.decision] || s.decision)}</span></td>
        <td>${esc(s.audience_label)}</td>
        <td><a href="${esc(s.url)}" target="_blank" rel="noreferrer">${esc(s.title)}</a><div class="small">${esc(s.quote)}</div></td>
        <td>${esc(s.reason)}</td>
      </tr>`).join('')}
    </tbody></table></div>
    <p class="hint">${locked ? '校准已锁定，样本只读。' : '可结合这些样本再保留/修改/排除校准条目。'}</p>`;
}

function renderCalibration(p) {
  const box = $('#calibrationView');
  const cal = p.calibration;
  $('#calVersion').textContent = cal ? `v${cal.version}${cal.locked ? ' · 已锁定' : ''}` : '';
  if (!cal) {
    box.className = 'muted';
    box.textContent = '尚未生成校准。先检查四项引导，再生成小样本校准。';
    return;
  }
  box.className = '';
  const locked = cal.locked;
  box.innerHTML = `
    <p class="hint">${esc(cal.provider || '')}${cal.model ? ' · ' + esc(cal.model) : ''} · 生成于 ${esc(cal.generated_at || '')}。逐条保留/修改/排除后，显式确认锁定。</p>
    ${cal.items.map((item) => `
      <div class="cal-item" data-id="${esc(item.id)}">
        <div>
          <b>${esc(item.audience_label)}</b> <span class="term">${esc(item.status)}</span>
          <div class="scenario">${esc(item.scenario)}</div>
          <div>${esc(item.user_text || item.problem_hypothesis)}</div>
          <div class="terms">${(item.seed_terms || []).map((t) => `<span class="term">${esc(t)}</span>`).join('')}</div>
          ${item.rationale ? `<p class="hint">${esc(item.rationale)}</p>` : ''}
        </div>
        <div class="controls">
          <select class="decision" ${locked ? 'disabled' : ''}>
            ${['proposed', 'retained', 'modified', 'excluded'].map((s) => `<option value="${s}" ${item.status === s ? 'selected' : ''}>${s}</option>`).join('')}
          </select>
          <input class="modify" placeholder="修改后文本（modified 必填）" value="${esc(item.user_text || '')}" ${locked ? 'disabled' : ''} />
          <button class="btn small save" ${locked ? 'disabled' : ''}>保存</button>
        </div>
      </div>`).join('')}`;
  box.querySelectorAll('.cal-item').forEach((row) => {
    const itemId = row.dataset.id;
    row.querySelector('.save').addEventListener('click', async () => {
      const action = row.querySelector('.decision').value;
      const text = row.querySelector('.modify').value.trim();
      try {
        const data = await api(`/api/profiles/${encodeURIComponent(p.id)}/calibration/items/${encodeURIComponent(itemId)}`, {
          method: 'PATCH',
          body: JSON.stringify({ action, text }),
        });
        state.profile = data.profile;
        renderProfile();
        notice('ok', '校准条目已更新');
      } catch (err) {
        notice('bad', `保存失败：${err.message}`);
      }
    });
  });
}

function renderEvidenceForm(p) {
  const ready = ['confirmed', 'researching', 'report'].includes(p.status) && p.calibration && p.calibration.locked;
  const form = $('#evidenceForm');
  form.classList.toggle('disabled', !ready);
  $('#evidenceGate').textContent = ready ? '已确认锁定：可手工导入' : '需先确认并锁定校准';
  const aud = $('#evAudience');
  aud.innerHTML = '<option value="">未归类</option>' + (p.guidance.audiences || []).map((a) => `<option value="${esc(a.id)}">${esc(a.label)}</option>`).join('');
  const scen = $('#evScenario');
  const items = p.calibration ? (p.calibration.items || []).filter((x) => x.status !== 'excluded') : [];
  scen.innerHTML = '<option value="">未归类</option>' + items.map((x) => `<option value="${esc(x.id)}">${esc(x.audience_label)} · ${esc(x.scenario)}</option>`).join('');
}

function renderEvidence(p) {
  const box = $('#evidenceView');
  if (!p.evidence || !p.evidence.length) {
    box.className = 'muted';
    box.textContent = '尚无证据。自动搜索待接；请手工导入 URL + 原文 + 可核对引用。';
    return;
  }
  box.className = '';
  box.innerHTML = `<div class="scroll"><table><thead><tr><th>证据</th><th>类型</th><th>场景</th><th>来源</th><th>地域/语言</th></tr></thead><tbody>
    ${p.evidence.map((e) => `<tr>
      <td><a href="${esc(e.url)}" target="_blank" rel="noopener noreferrer">${esc(e.title)}</a><div class="quote">${esc(e.quote)}</div></td>
      <td>${esc(e.signal_type)}</td><td>${esc(e.scenario_id)}</td>
      <td>${esc(e.source_domain)}<div class="small">${esc(e.channel)}</div></td>
      <td>${esc(e.region)} / ${esc(e.language)}</td>
    </tr>`).join('')}</tbody></table></div>
    <p class="hint">重复导入尝试：${(p.duplicate_log || []).length} 次（未计入证据）。</p>`;
}

function renderReport(p) {
  const box = $('#reportView');
  if (!p.report) {
    box.className = 'muted';
    box.textContent = '尚未生成报告。确认锁定并导入证据后可生成。';
    return;
  }
  const r = p.report;
  const w = r.watermark;
  box.className = '';
  box.innerHTML = `
    <div class="kpis">
      <div class="kpi"><div class="k">证据（去重后）</div><div class="v">${w.accepted_evidence}</div><div class="s">独立来源 ${w.independent_sources}</div></div>
      <div class="kpi"><div class="k">渠道覆盖</div><div class="v">${w.channel_count}</div><div class="s">${esc((w.channels || []).join('、') || '—')}</div></div>
      <div class="kpi"><div class="k">重复拒绝</div><div class="v">${w.duplicates_rejected}</div><div class="s">URL/正文/近似转载</div></div>
      <div class="kpi"><div class="k">未知地域</div><div class="v">${w.blind_spots.unknown_region_evidence}</div><div class="s">不推断</div></div>
      <div class="kpi"><div class="k">来源覆盖</div><div class="v">${esc(w.label)}</div><div class="s">不是市场份额</div></div>
    </div>
    <p class="hint">${esc(w.rule)}</p>
    <div class="section-title">人群 × 场景覆盖</div>
    <div class="scroll"><table><thead><tr><th>人群</th><th>场景</th><th>证据</th><th>问题 / 需要 / 矛盾</th></tr></thead><tbody>
      ${r.coverage.map((c) => `<tr><td>${esc(c.audience_label)} <span class="term">${esc({ included: '入选', uncertain: '不确定', excluded: '排除' }[c.audience_status] || c.audience_status || '入选')}</span></td><td>${esc(c.scenario)}<div class="small">${esc(c.hypothesis)}</div></td><td>${c.evidence_count}</td><td>${renderGroups(c.groups)}</td></tr>`).join('')}
    </tbody></table></div>
    ${r.unassigned && r.unassigned.length ? `<div class="section-title">未归类证据</div>${renderGroups(r.unassigned)}` : ''}
    <div class="section-title">精准词池（来源可区分）</div>
    <div class="scroll"><table><thead><tr><th>词</th><th>来源</th><th>证据支持</th></tr></thead><tbody>
      ${r.term_pool.map((t) => `<tr><td>${esc(t.term)}</td><td>${esc(t.origin_label)}${t.is_model_seed_only ? ' <span class="term">仅种子</span>' : ''}</td><td>${t.evidence_support}</td></tr>`).join('')}
    </tbody></table></div>
    <div class="section-title">来源覆盖与盲区</div>
    <p>独立来源：${w.independent_sources}（${esc((w.source_domains || []).join('、') || '—')}）；渠道：${esc((w.channels || []).join('、') || '—')}。</p>
    <p class="blind">零证据场景：${esc((w.blind_spots.scenarios || []).map((x) => x.scenario).join('、') || '无')}。</p>
    <p class="blind">缺失渠道：${esc((w.blind_spots.channels_missing || []).join('、') || '无')}；未归类证据 ${w.blind_spots.unassigned_evidence} 条。</p>
    <p class="hint">地域分布：${esc(JSON.stringify(w.regions))}；语言分布：${esc(JSON.stringify(w.languages))}。</p>
    <div class="section-title">限制</div><ul>${(r.limitations || []).map((x) => `<li>${esc(x)}</li>`).join('')}</ul>
    <p class="hint">报告生成于 ${esc(r.generated_at)}；校准 v${esc(r.calibration.version)}，${esc(r.method.note)}</p>`;
}

function renderGroups(groups) {
  if (!groups || !groups.length) return '<span class="muted">—</span>';
  return groups.map((g) => `
    <div><b>${esc({ problem: '问题', need: '需要', contradiction: '矛盾', behavior: '行为' }[g.signal_type] || g.signal_type)}</b> · ${esc(g.summary)} <span class="term">×${g.count}</span>
      <ul class="citations">${g.citations.map((c) => `<li><a href="${esc(c.url)}" target="_blank" rel="noopener noreferrer">${esc(c.title)}</a> <span class="small">${esc(c.source_domain)} · 地域 ${esc(c.region || '未知')} · 语言 ${esc(c.language || '未知')}</span></li>`).join('')}</ul>
    </div>`).join('');
}

function buildAudienceRow(a = {}) {
  const div = document.createElement('div');
  div.className = 'audience-row';
  div.innerHTML = `
    <label>人群名称<input class="a-label" value="${esc(a.label || '')}" placeholder="例如：应付账款经理" /></label>
    <label>角色<select class="a-role">
      <option value="user" ${a.role === 'user' ? 'selected' : ''}>使用者</option>
      <option value="payer" ${a.role === 'payer' ? 'selected' : ''}>付费者</option>
      <option value="both" ${a.role === 'both' ? 'selected' : ''}>使用者+付费者</option>
    </select></label>
    <label class="overlap"><input type="checkbox" class="a-overlap" ${a.overlap ? 'checked' : ''}/>可重叠</label>
    <label>纳入结论<select class="a-status">
      <option value="included" ${(a.status || 'included') === 'included' ? 'selected' : ''}>入选（候选）</option>
      <option value="uncertain" ${a.status === 'uncertain' ? 'selected' : ''}>不确定</option>
      <option value="excluded" ${a.status === 'excluded' ? 'selected' : ''}>排除</option>
    </select></label>
    <label>推断依据<input class="a-rationale" value="${esc(a.rationale || '')}" placeholder="为什么假设这个人群？" /></label>`;
  return div;
}

function addAudience(a) {
  $('#audienceRows').appendChild(buildAudienceRow(a));
}

function collectAudiences() {
  return Array.from(document.querySelectorAll('.audience-row')).map((row) => ({
    label: row.querySelector('.a-label').value.trim(),
    role: row.querySelector('.a-role').value,
    status: row.querySelector('.a-status').value,
    overlap: row.querySelector('.a-overlap').checked,
    rationale: row.querySelector('.a-rationale').value.trim(),
  })).filter((a) => a.label);
}

async function onCreate(event) {
  event.preventDefault();
  const form = $('#createForm');
  const data = Object.fromEntries(new FormData(form).entries());
  data.audiences = collectAudiences();
  try {
    const created = await api('/api/profiles', { method: 'POST', body: JSON.stringify(data) });
    state.profile = created.profile;
    state.profiles = (await api('/api/profiles')).items;
    state.profile = state.profiles.find((x) => x.id === created.profile.id) || created.profile;
    await openProfile(created.profile.id);
    notice('ok', '档案已创建。下一步生成小样本校准。');
  } catch (err) {
    notice('bad', `创建失败：${err.message}`);
  }
}

async function onCalibrate() {
  if (!state.profile) return;
  try {
    const data = await api(`/api/profiles/${encodeURIComponent(state.profile.id)}/calibrate`, { method: 'POST', body: '{}' });
    state.profile = data.profile;
    renderProfile();
    notice('ok', '校准已生成。请逐条保留/修改/排除，再显式确认锁定。');
  } catch (err) {
    notice('bad', `校准失败：${err.message}`);
  }
}

async function onConfirm() {
  if (!state.profile || !state.profile.calibration) return;
  try {
    const data = await api(`/api/profiles/${encodeURIComponent(state.profile.id)}/confirm`, {
      method: 'POST',
      body: JSON.stringify({ version: state.profile.calibration.version }),
    });
    state.profile = data.profile;
    renderProfile();
    await loadResearchProfiles();
    notice('ok', '校准已确认并锁定版本。现在可以导入证据。');
  } catch (err) {
    notice('bad', `确认失败：${err.message}`);
  }
}

async function onReport() {
  if (!state.profile) return;
  try {
    const data = await api(`/api/profiles/${encodeURIComponent(state.profile.id)}/report`, { method: 'POST', body: '{}' });
    state.profile = data.profile;
    renderProfile();
    notice('ok', '证据驱动报告已生成。');
  } catch (err) {
    notice('bad', `报告失败：${err.message}`);
  }
}

async function onSample(event) {
  event.preventDefault();
  if (!state.profile) return;
  const form = $('#sampleForm');
  const data = Object.fromEntries(new FormData(form).entries());
  try {
    const result = await api(`/api/profiles/${encodeURIComponent(state.profile.id)}/calibration-samples`, {
      method: 'POST',
      body: JSON.stringify(data),
    });
    state.profile = result.profile;
    renderProfile();
    notice('ok', '校准样本已保存。它不是正式证据，只用于复核取舍。');
    form.querySelector('[name="text"]').value = '';
    form.querySelector('[name="quote"]').value = '';
    form.querySelector('[name="reason"]').value = '';
  } catch (err) {
    notice('bad', `样本保存失败：${err.message}`);
  }
}

async function onEvidence(event) {
  event.preventDefault();
  if (!state.profile) return;
  const form = $('#evidenceForm');
  const data = Object.fromEntries(new FormData(form).entries());
  data.terms = String(data.terms || '').split(',').map((x) => x.trim()).filter(Boolean);
  try {
    const result = await api(`/api/profiles/${encodeURIComponent(state.profile.id)}/evidence`, {
      method: 'POST',
      body: JSON.stringify(data),
    });
    state.profile = result.profile;
    renderProfile();
    await loadResearchProfiles();
    const box = $('#evidenceResult');
    box.className = `msg ${result.accepted ? 'ok' : 'warn'}`;
    box.textContent = result.accepted ? '证据已导入并计入覆盖。' : `拒绝：${result.message || '重复来源'}`;
    box.classList.remove('hidden');
    form.querySelector('[name="text"]').value = '';
    form.querySelector('[name="quote"]').value = '';
  } catch (err) {
    const box = $('#evidenceResult');
    box.className = 'msg bad';
    box.textContent = `导入失败：${err.message}`;
    box.classList.remove('hidden');
  }
}

function studioMsg(kind, text) {
  const box = $('#studioMsg');
  box.className = `msg ${kind || ''}`;
  box.textContent = text;
  box.classList.remove('hidden');
}

function studioErrorText(err) {
  if (!err) return '理解失败，请重试。';
  if (err.code === 'missing_sentence') return '请用一句话写下业务和关键问题。';
  if (err.code === 'provider_not_configured') {
    return '服务端模型未配置：请设置 LEADS_WATER_API_KEY 等服务端环境变量，或点击“加载独立演示样例”先看完整路径；不会生成假结果。';
  }
  if (err.code === 'confirmation_required') return '请先确认理解摘要（首次或人群变化时）。';
  if (err.code === 'profile_not_found') return '选择的档案不存在，请刷新后重试。';
  if (err.code === 'provider_failed') return `模型调用失败：${err.message}。没有编造答案。`;
  return err.message || '操作失败';
}

function renderStudioAudiences(audiences) {
  const list = (audiences && audiences.length ? audiences : [{ label: '', type: 'primary' }]);
  $('#studioAudiences').innerHTML = list.map((a, i) => `<div class="studio-aud" data-index="${i}">
    <input type="text" class="studio-aud-label" value="${esc(a.label || '')}" placeholder="人群名称" maxlength="160" />
    <select class="studio-aud-type">
      <option value="primary"${a.type === 'opinion' ? '' : ' selected'}>主要人群</option>
      <option value="opinion"${a.type === 'opinion' ? ' selected' : ''}>意见用户</option>
    </select>
    <label><input type="checkbox" class="studio-aud-overlap"${a.overlap ? ' checked' : ''} /> 与付费者重叠</label>
    <button type="button" class="btn small studio-aud-remove">移除</button>
  </div>`).join('');
}

function collectStudioAudiences() {
  return Array.from(document.querySelectorAll('#studioAudiences .studio-aud')).map((row) => ({
    label: row.querySelector('.studio-aud-label').value.trim(),
    type: row.querySelector('.studio-aud-type').value,
    overlap: row.querySelector('.studio-aud-overlap').checked,
  })).filter((a) => a.label);
}

function renderStudioUnderstanding(understanding, matchedProfile) {
  state.studio.understanding = understanding;
  $('#studioBusiness').value = understanding.business || '';
  $('#studioQuestion').value = understanding.question || '';
  renderStudioAudiences(understanding.audiences || []);
  const assumptions = (understanding.assumptions || []).map((a) =>
    `<div>· ${esc(a.text)}${a.basis ? ` <span class="hint">（${esc(a.basis)}）</span>` : ''}</div>`
  ).join('');
  $('#studioAssumptions').innerHTML = assumptions || '<div class="hint">系统未显式说明额外假设。</div>';
  $('#studioUnderstand').classList.remove('hidden');
  $('#workbenchView').classList.add('hidden');
  if (matchedProfile) studioMsg('', `已自动沿用档案：${matchedProfile.name}。你可以修改理解摘要后再确认。`);
}

async function loadStudioKeywords(understanding, confirmedSignature) {
  const body = {
    sentence: understanding.sentence,
    understanding,
    confirmed_signature: confirmedSignature || undefined,
    user_confirmed: !confirmedSignature,
  };
  const data = await api('/api/studio/keywords', { method: 'POST', body: JSON.stringify(body) });
  state.studio.workbench = data.workbench;
  state.studio.understanding = data.understanding;
  state.studio.confirmedFor = data.understanding.audience_signature;
  sessionStorage.setItem(`studio:${data.understanding.audience_signature}`, '1');
  renderWorkbench(data.workbench);
}

async function onStudioSubmit(event) {
  event.preventDefault();
  if (state.studio.busy) return;
  const sentence = $('#studioSentence').value.trim();
  if (!sentence) {
    studioMsg('bad', '请先输入“业务 + 关键问题”一句话。');
    $('#studioSentence').focus();
    return;
  }
  const profileId = $('#studioProfile').value;
  state.studio.busy = true;
  $('#btnStudio').disabled = true;
  $('#btnStudio').textContent = '理解中…';
  $('#studioMsg').classList.add('hidden');
  try {
    const data = await api('/api/studio/understand', {
      method: 'POST',
      body: JSON.stringify({ sentence, profile_id: profileId || undefined }),
    });
    const understanding = data.understanding;
    const cached = sessionStorage.getItem(`studio:${understanding.audience_signature}`);
    if (!data.confirmation.required || cached === '1') {
      await loadStudioKeywords(understanding, understanding.audience_signature);
    } else {
      renderStudioUnderstanding(understanding, data.matched_profile);
    }
  } catch (err) {
    studioMsg('bad', studioErrorText(err));
  } finally {
    state.studio.busy = false;
    $('#btnStudio').disabled = false;
    $('#btnStudio').textContent = '理解并生成工作台';
  }
}

async function onConfirmStudio() {
  if (!state.studio.understanding) return;
  const previous = state.studio.understanding;
  const understanding = {
    ...previous,
    business: $('#studioBusiness').value.trim(),
    question: $('#studioQuestion').value.trim(),
    audiences: collectStudioAudiences(),
    sentence: previous.sentence,
  };
  if (!understanding.question) {
    studioMsg('bad', '关键问题不能为空。');
    return;
  }
  if (!understanding.audiences.length) {
    studioMsg('bad', '至少保留一个人群，或直接按系统草稿继续。');
    return;
  }
  state.studio.busy = true;
  $('#btnConfirmUnderstanding').disabled = true;
  try {
    await loadStudioKeywords(understanding, null);
    $('#studioUnderstand').classList.add('hidden');
    studioMsg('ok', '已确认理解。工作台只使用本次摘要和所选档案内的证据。');
  } catch (err) {
    studioMsg('bad', studioErrorText(err));
  } finally {
    state.studio.busy = false;
    $('#btnConfirmUnderstanding').disabled = false;
  }
}

function sourceBadge(kw) {
  const type = kw.source_type || 'ai_candidate';
  return `<span class="source-badge ${esc(type)}">${esc(kw.source_type_label || type)}</span>`;
}

function renderWorkbench(wb) {
  $('#studioUnderstand').classList.add('hidden');
  $('#workbenchView').classList.remove('hidden');
  state.studio.searchData = null;
  $('#studioSearchResults').classList.add('hidden');
  $('#studioSearchMsg').textContent = '只在勾选关键词后显式联网检索；不会自动搜索。';
  const banner = $('#studioBanner');
  const demo = Boolean(wb.demo);
  banner.classList.toggle('hidden', !demo);
  banner.textContent = demo
    ? '独立演示样例：所有证据均为合成文本，来源类型是“AI候选”，不是真实检索、也不是真实研究结论。'
    : '来源类型为“经真实检索且有证据”才会显示已验证；没有自动广搜，AI 候选不等于证据。';
  $('#studioKwCount').textContent = String(wb.stats.keyword_count);
  $('#studioLeadCount').textContent = String(wb.stats.independent_lead_count);
  $('#studioVerifiedCount').textContent = String(wb.stats.verified_keyword_count);
  $('#studioUserCount').textContent = String(wb.stats.user_phrase_keyword_count);
  $('#studioAiCount').textContent = String(wb.stats.ai_candidate_keyword_count);
  $('#studioNote').textContent = wb.note || '';

  const selected = state.studio.selected;
  $('#studioKeywordRows').innerHTML = (wb.keywords || []).map((kw) => `<tr class="row-click${selected.has(kw.term) ? ' row-sel' : ''}" data-term="${esc(kw.term)}">
    <td><input type="checkbox" class="kw-check" data-term="${esc(kw.term)}"${selected.has(kw.term) ? ' checked' : ''} /></td>
    <td><button type="button" class="keyword-link" data-term="${esc(kw.term)}">${esc(kw.term)}</button></td>
    <td>${esc(kw.intent)}</td>
    <td>${esc(kw.audience)}</td>
    <td>${sourceBadge(kw)}</td>
    <td>${esc(kw.source)}</td>
    <td>${Number(kw.independent_leads || 0)}</td>
  </tr>`).join('') || '<tr><td colspan="7" class="muted">暂无关键词；可先看演示或换一种说法。</td></tr>';

  $('#studioKeywordRows').querySelectorAll('.keyword-link').forEach((btn) => {
    btn.addEventListener('click', (ev) => {
      ev.stopPropagation();
      showKeywordDetail(btn.dataset.term);
    });
  });
  $('#studioLeadGroups').innerHTML = (wb.lead_groups || []).map((g) => `<article class="studio-group">
    <div class="studio-group-head"><b>${esc(g.intent)} · ${esc(g.audience)}</b><span class="hint">强度 ${esc(g.strength)} · 强 ${Number(g.strong_count)} / 弱 ${Number(g.weak_count)}</span></div>
    <ul>${(g.keywords || []).map((k) => `<li><button type="button" class="keyword-link" data-term="${esc(k)}">${esc(k)}</button></li>`).join('')}</ul>
    ${(g.leads || []).map((lead) => `<div class="lead"><b>${esc(lead.title || '未命名线索')}</b> <span class="source-badge ${esc(lead.source_type)}">${esc(lead.source_type_label)}</span>
      ${lead.url ? `<div><a href="${esc(lead.url)}" target="_blank" rel="noreferrer">${esc(lead.url)}</a></div>` : ''}
      ${lead.quote ? `<div class="quote">“${esc(lead.quote)}”</div>` : ''}
      <small>${esc(lead.source_domain || '')}${lead.demo ? ' · 演示证据' : ''}</small></div>`).join('')}
    <div class="hint">盲区：${esc((g.blind_spots || []).join('；'))}</div>
  </article>`).join('') || '<p class="muted">零条有证据线索；关键词仍保留，供交接复核。这不是已执行搜索。</p>';
  $('#studioLeadGroups').querySelectorAll('.keyword-link').forEach((btn) => {
    btn.addEventListener('click', () => showKeywordDetail(btn.dataset.term));
  });
  $('#studioBlind').innerHTML = (wb.blind_spots || []).map((b) => `<li>${esc(b)}</li>`).join('');
  $('#studioDetail').classList.add('hidden');
  updateExportState();
}

function showKeywordDetail(term) {
  const wb = state.studio.workbench;
  const kw = wb && wb.keywords.find((k) => k.term === term);
  if (!kw) return;
  const rows = $('#studioKeywordRows').querySelectorAll('tr');
  rows.forEach((row) => row.classList.remove('row-flash'));
  const row = $('#studioKeywordRows').querySelector(`tr[data-term="${CSS.escape(term)}"]`);
  if (row) {
    row.classList.add('row-flash');
    row.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
  const related = (wb.keywords || []).filter((k) => k.evidence.some((e) => kw.evidence.some((x) => x.url === e.url && x.title === e.title)));
  const citations = (kw.evidence || []).map((e) => `<div class="studio-cite">
    <b>${esc(e.title || '未命名证据')}</b> ${e.url ? `<a href="${esc(e.url)}" target="_blank" rel="noreferrer">${esc(e.url)}</a>` : ''}
    <div>${sourceBadge(e)} <span class="hint">${esc(e.source_note || '')}</span></div>
    ${e.quote ? `<div class="quote">“${esc(e.quote)}”</div>` : ''}
    <small>${esc(e.source_domain || '')} · ${esc(e.region || '未知')} · ${esc(e.language || '未知')}${e.demo ? ' · 演示证据' : ''}</small>
  </div>`).join('') || '<div class="hint">没有可核对引用；这是待搜索/待验证关键词。</div>';
  const back = related.map((k) => `<button type="button" class="keyword-link" data-back="${esc(k.term)}">${esc(k.term)}</button>`).join(' ');
  $('#studioDetail').className = 'studio-detail';
  $('#studioDetail').innerHTML = `<h4>${esc(kw.term)} · ${esc(kw.intent)} · ${esc(kw.audience)}</h4>
    <div class="hint">${esc(kw.note || '')}</div>${citations}
    ${back ? `<div class="hint">反向回词：${back}</div>` : ''}`;
  $('#studioDetail').querySelectorAll('[data-back]').forEach((btn) => {
    btn.addEventListener('click', () => showKeywordDetail(btn.dataset.back));
  });
}

function updateExportState() {
  const count = state.studio.selected.size;
  const btn = $('#btnExportKeywords');
  btn.textContent = count ? `导出选中关键词（${count}）为拓群交接清单` : '导出选中关键词为拓群交接清单';
  if (count) $('#studioExportMsg').textContent = '';
  updateLiveSearchState();
}

function updateLiveSearchState() {
  const btn = $('#btnLiveSearch');
  const cancel = $('#btnCancelSearch');
  if (!btn) return;
  const cfg = (state.health && state.health.live_search) || {};
  const configured = cfg.configured !== false;
  const count = state.studio.selected.size;
  btn.disabled = Boolean(state.studio.searchBusy) || !configured || count === 0;
  btn.title = !configured
    ? '服务端未启用真实检索（LEADS_WATER_SEARCH=off）'
    : (count === 0 ? '先勾选至少一个关键词' : '仅对勾选关键词显式联网检索');
  cancel.classList.toggle('hidden', !state.studio.searchBusy);
}

async function onLiveSearch() {
  const wb = state.studio.workbench;
  if (!wb || state.studio.searchBusy) return;
  const keywords = (wb.keywords || []).filter((k) => state.studio.selected.has(k.term))
    .map((k) => ({ term: k.term, intent: k.intent, audience: k.audience, audience_id: k.audience_id || '' }));
  if (!keywords.length) {
    $('#studioSearchMsg').textContent = '请先勾选至少一个关键词。';
    return;
  }
  state.studio.searchBusy = true;
  state.studio.searchAbort = new AbortController();
  updateLiveSearchState();
  $('#studioSearchMsg').textContent = `正在对 ${keywords.length} 个词做公开来源检索…`;
  $('#studioSearchResults').classList.add('hidden');
  try {
    const data = await api('/api/studio/search', {
      method: 'POST',
      body: JSON.stringify({ keywords, audience_signature: state.studio.understanding && state.studio.understanding.audience_signature }),
      signal: state.studio.searchAbort.signal,
    });
    state.studio.searchData = data;
    renderSearchResults(data);
  } catch (err) {
    if (err.name === 'AbortError') {
      $('#studioSearchMsg').textContent = '已取消搜索；已返回的部分结果不保留。';
    } else {
      $('#studioSearchMsg').textContent = `搜索失败：${err.message}${err.code ? `（${err.code}）` : ''}`;
    }
  } finally {
    state.studio.searchBusy = false;
    state.studio.searchAbort = null;
    updateLiveSearchState();
  }
}

function renderSearchResults(data) {
  const el = $('#studioSearchResults');
  const errs = data.errors || [];
  const verified = Number(data.verified_count || 0);
  const total = (data.results || []).length;
  $('#studioSearchMsg').textContent = `检索完成：${total} 条线索，其中 ${verified} 条有原文可核对引用；未执行加群/采集，结果只在本次预览。`;
  const channelHtml = (data.channels || []).map((c) => {
    const cls = c.state === 'ok' ? 'ok' : (['failed', 'cooldown'].includes(c.state) ? c.state : '');
    const detail = c.error ? `${c.error.code}: ${c.error.message}` : (c.cooldown ? `冷却至 ${c.cooldown.until}（${c.cooldown.reason}）` : '');
    return `<div class="search-channel ${cls}"><b>${esc(c.label)}</b> <span class="hint">${esc(c.state)} · 请求 ${Number(c.requests)} · 结果 ${Number(c.results)}</span>${detail ? `<div class="hint">${esc(detail)}</div>` : ''}</div>`;
  }).join('');
  const results = data.results || [];
  const groups = {};
  for (const r of results) (groups[r.keyword] = groups[r.keyword] || []).push(r);
  const resultHtml = Object.keys(groups).map((term) => `<section class="search-channel">
    <b>${esc(term)}</b> <span class="hint">${groups[term].filter((r) => r.verified).length} 条可核对证据 / ${groups[term].length} 条线索</span>
    ${groups[term].map((r) => `<div class="search-result">
      <div><a href="${esc(r.url)}" target="_blank" rel="noreferrer">${esc(r.title || r.url)}</a><span class="search-badge ${r.verified ? 'verified' : 'unverified'}">${r.verified ? '已验证原文引用' : '未验证线索'}</span></div>
      <div class="hint">${esc(r.channel)} · ${esc(r.source_domain)}${r.published_at ? ` · ${esc(r.published_at)}` : ''}</div>
      ${r.quote ? `<div class="search-quote">“${esc(r.quote)}”</div>` : ''}
      <div class="hint">${esc(r.note || '')}</div>
    </div>`).join('')}
  </section>`).join('') || '<p class="muted">没有检索到可展示线索；这本身就是覆盖缺口，不要当作“没有需求”。</p>';
  const errorHtml = errs.length ? `<div class="search-channel failed"><b>渠道错误（不是“无结果”）</b>${errs.map((e) => `<div class="hint">${esc(e.channel)} · ${esc(e.keyword || '')} · ${esc(e.code)}: ${esc(e.message)}</div>`).join('')}</div>` : '';
  el.innerHTML = `${channelHtml}${errorHtml}${resultHtml}<div class="hint">${esc((data.blind_spots || []).join('；'))}</div>`;
  el.classList.remove('hidden');
}

async function onExportKeywords() {
  const wb = state.studio.workbench;
  if (!wb) return;
  const keywords = (wb.keywords || []).filter((k) => state.studio.selected.has(k.term));
  if (!keywords.length) {
    $('#studioExportMsg').textContent = '请先勾选至少一个关键词。';
    return;
  }
  try {
    const data = await api('/api/studio/export', {
      method: 'POST',
      body: JSON.stringify({ understanding: state.studio.understanding, keywords }),
    });
    const blob = new Blob([`\ufeff${data.csv}`], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = data.filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
    $('#studioExportMsg').textContent = `已生成交接清单（${data.count} 个词）；未执行任务、未接生产。`;
  } catch (err) {
    $('#studioExportMsg').textContent = `导出失败：${err.message}`;
  }
}

async function onStudioDemo() {
  try {
    const data = await api('/api/studio/demo');
    state.studio.understanding = data.understanding;
    state.studio.workbench = data.workbench;
    state.studio.selected = new Set();
    $('#studioUnderstand').classList.add('hidden');
    renderWorkbench(data.workbench);
    studioMsg('', '已加载独立演示：合成证据，只演示“词→证据→词”和工作台，不当真。');
  } catch (err) {
    studioMsg('bad', `演示加载失败：${err.message}`);
  }
}

function bindStudio() {
  $('#studioForm').addEventListener('submit', onStudioSubmit);
  $('#btnStudioDemo').addEventListener('click', onStudioDemo);
  $('#btnConfirmUnderstanding').addEventListener('click', onConfirmStudio);
  $('#btnAddStudioAudience').addEventListener('click', () => {
    const rows = collectStudioAudiences();
    rows.push({ label: '', type: 'primary', overlap: false });
    renderStudioAudiences(rows);
  });
  $('#studioAudiences').addEventListener('click', (ev) => {
    const btn = ev.target.closest('.studio-aud-remove');
    if (!btn) return;
    const rows = collectStudioAudiences();
    const idx = Number(btn.closest('.studio-aud').dataset.index);
    rows.splice(idx, 1);
    renderStudioAudiences(rows);
  });
  $('#btnExportKeywords').addEventListener('click', onExportKeywords);
  $('#btnLiveSearch').addEventListener('click', onLiveSearch);
  $('#btnCancelSearch').addEventListener('click', () => {
    if (state.studio.searchAbort) state.studio.searchAbort.abort();
  });
  $('#studioKeywordRows').addEventListener('change', (ev) => {
    const box = ev.target.closest('.kw-check');
    if (!box) return;
    const term = box.dataset.term;
    if (box.checked) state.studio.selected.add(term); else state.studio.selected.delete(term);
    const row = box.closest('tr');
    if (row) row.classList.toggle('row-sel', box.checked);
    updateExportState();
  });
  $('#studioKeywordRows').addEventListener('click', (ev) => {
    if (ev.target.closest('input')) return;
    const row = ev.target.closest('tr[data-term]');
    if (row) showKeywordDetail(row.dataset.term);
  });
}

function bind() {
  bindStudio();
  $('#btnNew').addEventListener('click', () => {
    $('#createPanel').classList.remove('hidden');
    $('#emptyState').classList.add('hidden');
    if (!$('#audienceRows').children.length) { addAudience({ role: 'user' }); addAudience({ role: 'payer' }); }
  });
  $('#btnStart').addEventListener('click', () => $('#btnNew').click());
  $('#btnAddAudience').addEventListener('click', () => addAudience({ role: 'both' }));
  $('#createForm').addEventListener('submit', onCreate);
  $('#btnCalibrate').addEventListener('click', onCalibrate);
  $('#btnConfirm').addEventListener('click', onConfirm);
  $('#btnReport').addEventListener('click', onReport);
  $('#sampleForm').addEventListener('submit', onSample);
  $('#evidenceForm').addEventListener('submit', onEvidence);
  $('#askForm').addEventListener('submit', onAsk);
  $('#quickResearchForm').addEventListener('submit', onDraftResearch);
  $('#btnUseHomeQuestion').addEventListener('click', () => {
    const home = $('#questionInput').value.trim();
    if (!home) { showResearchMsg('bad', '首页还没有问题；请先在上方输入。'); return; }
    $('#researchQuestion').value = home;
    $('#researchQuestion').focus();
  });
  $('#btnConfirmResearch').addEventListener('click', onConfirmResearch);
  $('#btnResearchAgain').addEventListener('click', onDraftResearch);
  $('#btnManualResearch').addEventListener('click', () => {
    const el = $('#manualResearch');
    const opening = el.classList.contains('hidden');
    el.classList.toggle('hidden');
    $('#btnManualResearch').textContent = opening ? '收起手动档案' : '手动填写完整研究档案（可选）';
    if (opening && !state.profile) {
      $('#emptyState').classList.remove('hidden');
      $('#createPanel').classList.add('hidden');
    }
  });
  document.querySelectorAll('[data-close="create"]').forEach((b) => b.addEventListener('click', () => $('#createPanel').classList.add('hidden')));
  $('#advancedResearch').addEventListener('toggle', () => {
    const open = $('#advancedResearch').open;
    const layout = document.querySelector('.layout');
    if (layout) layout.classList.toggle('advanced-open', open);
    $('#researchSidebar').classList.toggle('hidden', !open);
    if (open) {
      syncHomeQuestion();
      loadProfiles();
    }
  });
}

async function init() {
  bind();
  addAudience({ role: 'user' });
  addAudience({ role: 'payer' });
  await loadHealth();
  await loadResearchProfiles();
}

init().catch((err) => notice('bad', `初始化失败：${err.message}`));
