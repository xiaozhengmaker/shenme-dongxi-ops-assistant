'use strict';

const {
  AppError,
  nowIso,
  cleanText,
  asArray,
  uniqueStrings,
  sha256,
  randomId,
  canonicalUrl,
  sourceDomain,
  normalizeForCompare,
  jaccard,
} = require('./util');

const ROLES = new Set(['user', 'payer', 'both']);
const SAMPLE_DECISIONS = new Set(['included', 'excluded', 'uncertain']);
const MAX_CALIBRATION_SAMPLES = 8;
const CHANNELS = new Set(['forum', 'vendor', 'creator', 'social', 'other']);
const SIGNAL_TYPES = new Set(['problem', 'need', 'contradiction', 'behavior']);

function validateGuidance(input) {
  const src = input || {};
  const name = cleanText(src.name, 120);
  const description = cleanText(src.description, 3000);
  const problem = cleanText(src.problem, 2000);
  const decisionPurpose = cleanText(src.decision_purpose, 1200);
  const valueUser = asArray(src.value_user);
  const valuePayer = asArray(src.value_payer);
  const searchScope = cleanText(src.search_scope, 1200);
  const existingEvidence = cleanText(src.existing_evidence, 3000);
  const audiencesRaw = Array.isArray(src.audiences) ? src.audiences : [];
  if (!name) throw new AppError('missing_name', '缺少产品/业务名称');
  if (!description) throw new AppError('missing_description', '缺少产品描述（解决什么）');
  if (!problem) throw new AppError('missing_problem', '缺少要研究的问题');
  if (!decisionPurpose) throw new AppError('missing_decision_purpose', '缺少决策目的');
  if (!valueUser.length) throw new AppError('missing_value_user', '缺少使用者可观察价值行为');
  if (!valuePayer.length) throw new AppError('missing_value_payer', '缺少付费者可观察价值行为');
  if (!audiencesRaw.length) throw new AppError('missing_audience', '至少需要一个人群假设');

  const audiences = [];
  for (const raw of audiencesRaw.slice(0, 12)) {
    const label = cleanText(raw && raw.label, 120);
    const role = cleanText(raw && raw.role, 20).toLowerCase();
    const rationale = cleanText(raw && raw.rationale, 1000);
    const status = cleanText(raw && raw.status, 20).toLowerCase() || 'included';
    if (!label) continue;
    if (!ROLES.has(role)) throw new AppError('invalid_role', `人群「${label}」的角色必须是 user/payer/both`);
    if (!['included', 'uncertain', 'excluded'].includes(status)) {
      throw new AppError('invalid_audience_status', `人群「${label}」的纳入结论必须是 included/uncertain/excluded`);
    }
    const id = `aud-${audiences.length + 1}`;
    audiences.push({
      id,
      label,
      role,
      rationale,
      overlap: Boolean(raw && raw.overlap),
      status,
    });
  }
  if (!audiences.length) throw new AppError('missing_audience', '人群假设为空');

  const scenarios = Array.isArray(src.scenarios)
    ? src.scenarios.slice(0, 12).map((s, i) => ({
        audience_id: cleanText(s && s.audience_id, 40) || audiences[0].id,
        scenario: cleanText(s && s.scenario, 300),
        problem: cleanText(s && s.problem, 1000),
        seed_terms: asArray(s && s.seed_terms).slice(0, 8),
      })).filter((s) => s.scenario)
    : [];

  return {
    name,
    description,
    problem,
    decision_purpose: decisionPurpose,
    value_user: valueUser,
    value_payer: valuePayer,
    search_scope: searchScope,
    existing_evidence: existingEvidence,
    audiences,
    regions: asArray(src.regions),
    languages: asArray(src.languages),
    sources: asArray(src.sources),
    user_phrases: asArray(src.user_phrases),
    seed_terms: asArray(src.seed_terms).slice(0, 30),
    scenarios,
  };
}

function createProfile(store, input) {
  const guidance = validateGuidance(input);
  const profile = store.create(guidance);
  profile.guidance = guidance;
  profile.calibration_samples = [];
  return store.save(profile);
}

function addCalibrationSample(store, id, input) {
  const profile = store.get(id);
  if (profile.calibration && profile.calibration.locked) {
    throw new AppError('calibration_locked', '校准已锁定；校准样本只能在锁定前导入', 409);
  }
  if (!['draft', 'calibrated'].includes(profile.status)) {
    throw new AppError('not_editable', '当前状态不允许导入校准样本', 409);
  }
  const samples = Array.isArray(profile.calibration_samples) ? profile.calibration_samples : [];
  if (samples.length >= MAX_CALIBRATION_SAMPLES) {
    throw new AppError('too_many_samples', `校准样本最多 ${MAX_CALIBRATION_SAMPLES} 条，已够做小样本校准`, 409);
  }
  const src = input || {};
  const url = cleanText(src.url, 2000);
  const title = cleanText(src.title, 300);
  const text = cleanText(src.text, 100000);
  const quote = cleanText(src.quote, 2000);
  if (!url) throw new AppError('missing_url', '缺少样本来源 URL');
  if (!title) throw new AppError('missing_title', '缺少样本来源标题');
  if (text.length < 40) throw new AppError('text_too_short', '样本原文至少 40 字，便于核对引用');
  if (!quote) throw new AppError('missing_quote', '缺少可核对引用原文');
  const quoteStart = text.indexOf(quote);
  if (quoteStart < 0) throw new AppError('quote_not_found', '引用原文不在样本正文中，拒绝导入');
  const decision = cleanText(src.decision, 20).toLowerCase();
  if (!SAMPLE_DECISIONS.has(decision)) {
    throw new AppError('invalid_sample_decision', '样本结论必须是 included/excluded/uncertain');
  }
  const reason = cleanText(src.reason, 1200);
  if (!reason) throw new AppError('missing_sample_reason', '请说明为何入选/排除/不确定');
  const audienceId = cleanText(src.audience_id, 40);
  if (!audienceId) throw new AppError('missing_audience', '校准样本必须关联一个人群');
  const audience = (profile.guidance.audiences || []).find((a) => a.id === audienceId);
  if (!audience) throw new AppError('audience_not_found', '人群 ID 不属于该档案');

  const canonical = canonicalUrl(url);
  const contentHash = sha256(normalizeForCompare(text));
  const duplicate = samples.find((x) => x.canonical_url === canonical || x.content_sha256 === contentHash);
  if (duplicate) {
    throw new AppError('duplicate_sample', '该来源或正文已作为校准样本导入', 409, { duplicate_of: duplicate.id });
  }

  const channel = CHANNELS.has(cleanText(src.channel, 20)) ? cleanText(src.channel, 20) : 'other';
  const sample = {
    id: `smp-${samples.length + 1}`,
    url,
    canonical_url: canonical,
    source_domain: sourceDomain(canonical),
    title,
    text,
    quote,
    quote_start: quoteStart,
    quote_end: quoteStart + quote.length,
    decision,
    reason,
    audience_id: audience.id,
    audience_label: audience.label,
    channel,
    region: cleanText(src.region, 80) || '未知',
    language: cleanText(src.language, 80) || '未知',
    content_sha256: contentHash,
    imported_at: nowIso(),
  };
  samples.push(sample);
  profile.calibration_samples = samples;
  store.save(profile);
  return { sample, profile };
}

async function calibrate(store, id, provider) {
  const profile = store.get(id);
  if (profile.status === 'confirmed' || profile.status === 'researching' || profile.status === 'report') {
    throw new AppError('calibration_locked', '校准已确认并锁定；如需修改，请新建档案', 409);
  }
  validateGuidance(profile.guidance);
  let result;
  try {
    result = await provider.generateCalibration(profile);
  } catch (err) {
    if (err instanceof AppError) throw err;
    throw new AppError('provider_failed', `模型调用失败：${err && err.message ? err.message : '未知错误'}`, 502);
  }
  const items = Array.isArray(result.items) ? result.items : [];
  if (!items.length) throw new AppError('provider_bad_output', '校准没有返回条目', 502, { provider: result.provider });
  const seen = new Set();
  profile.calibration = {
    version: profile.calibration && profile.calibration.version ? profile.calibration.version + 1 : 1,
    generated_at: nowIso(),
    locked: false,
    confirmed_at: null,
    provider: result.provider || provider.info().name,
    model: result.model || null,
    items: items.map((raw, index) => {
      let itemId = cleanText(raw.id, 60) || `cal-${index + 1}`;
      while (seen.has(itemId)) itemId = `${itemId}-${index + 1}`;
      seen.add(itemId);
      const audience = (profile.guidance.audiences || []).find((a) => a.id === raw.audience_id) || profile.guidance.audiences[0];
      return {
        id: itemId,
        audience_id: audience.id,
        audience_label: audience.label,
        scenario: cleanText(raw.scenario, 300),
        problem_hypothesis: cleanText(raw.problem_hypothesis, 1200),
        seed_terms: asArray(raw.seed_terms).slice(0, 8),
        rationale: cleanText(raw.rationale, 800),
        status: 'proposed',
        user_text: null,
      };
    }),
  };
  profile.status = 'calibrated';
  return store.save(profile);
}

function updateCalibrationItem(store, id, itemId, input) {
  const profile = store.get(id);
  if (!profile.calibration || profile.calibration.locked || profile.status !== 'calibrated') {
    throw new AppError('calibration_locked', '校准已锁定或不在可编辑状态', 409);
  }
  const item = profile.calibration.items.find((x) => x.id === itemId);
  if (!item) throw new AppError('item_not_found', '校准条目不存在', 404);
  const action = cleanText(input && input.action, 20).toLowerCase();
  if (action === 'retain') {
    item.status = 'retained';
    item.user_text = null;
  } else if (action === 'exclude') {
    item.status = 'excluded';
    item.user_text = null;
  } else if (action === 'modify') {
    const text = cleanText(input && input.text, 1200);
    if (!text) throw new AppError('missing_text', '修改条目需要文本');
    item.status = 'modified';
    item.user_text = text;
    if (Array.isArray(input.seed_terms)) item.seed_terms = asArray(input.seed_terms).slice(0, 8);
  } else {
    throw new AppError('invalid_action', 'action 必须是 retain/modify/exclude');
  }
  return store.save(profile);
}

function confirmCalibration(store, id, input) {
  const profile = store.get(id);
  if (!profile.calibration || profile.status !== 'calibrated') {
    throw new AppError('not_calibrated', '请先生成校准', 409);
  }
  if (profile.calibration.locked) throw new AppError('calibration_locked', '校准已锁定', 409);
  const expected = input && input.version;
  if (expected !== undefined && Number(expected) !== Number(profile.calibration.version)) {
    throw new AppError('version_mismatch', '校准版本已变化，请刷新后重新确认', 409);
  }
  const items = profile.calibration.items;
  const unresolved = items.filter((x) => x.status === 'proposed');
  if (unresolved.length) {
    throw new AppError('items_unresolved', '还有未处理的校准条目；需逐条保留/修改/排除', 409, {
      unresolved: unresolved.map((x) => x.id),
    });
  }
  const kept = items.filter((x) => x.status === 'retained' || x.status === 'modified');
  if (!kept.length) throw new AppError('no_items_kept', '至少保留一条校准条目');
  profile.calibration.locked = true;
  profile.calibration.confirmed_at = nowIso();
  profile.status = 'confirmed';
  return store.save(profile);
}

function importEvidence(store, id, input) {
  const profile = store.get(id);
  if (!profile.calibration || !profile.calibration.locked) {
    throw new AppError('not_confirmed', '未确认并锁定校准前，禁止导入证据/广搜', 409);
  }
  if (!['confirmed', 'researching', 'report'].includes(profile.status)) {
    throw new AppError('not_confirmed', '当前状态不允许导入证据', 409);
  }
  const src = input || {};
  const url = cleanText(src.url, 2000);
  const title = cleanText(src.title, 300);
  const text = cleanText(src.text, 100000);
  const quote = cleanText(src.quote, 2000);
  if (!url) throw new AppError('missing_url', '缺少来源 URL');
  if (!title) throw new AppError('missing_title', '缺少来源标题');
  if (text.length < 40) throw new AppError('text_too_short', '原文至少 40 字，便于核对引用');
  if (!quote) throw new AppError('missing_quote', '缺少可核对引用原文');
  if (text.indexOf(quote) < 0) throw new AppError('quote_not_found', '引用原文不在所给正文中，拒绝导入');

  const canonical = canonicalUrl(url);
  const domain = sourceDomain(canonical);
  const contentHash = sha256(normalizeForCompare(text));
  const duplicate = findDuplicate(profile, canonical, contentHash, text, title);
  if (duplicate) {
    profile.duplicate_log = Array.isArray(profile.duplicate_log) ? profile.duplicate_log : [];
    profile.duplicate_log.push({
      at: nowIso(),
      canonical_url: canonical,
      content_sha256: contentHash,
      duplicate_of: duplicate.id,
      kind: duplicate.kind,
      title,
    });
    if (profile.status === 'confirmed') profile.status = 'researching';
    store.save(profile);
    return {
      accepted: false,
      duplicate: true,
      duplicate_of: duplicate.id,
      kind: duplicate.kind,
      message: '重复来源，未计入独立证据',
      profile,
    };
  }

  const audienceIds = new Set((profile.guidance.audiences || []).map((a) => a.id));
  const scenarioIds = new Set((profile.calibration.items || []).filter((x) => x.status !== 'excluded').map((x) => x.id));
  let audienceId = cleanText(src.audience_id, 40);
  let scenarioId = cleanText(src.scenario_id, 60);
  if (audienceId && !audienceIds.has(audienceId)) throw new AppError('audience_not_found', '人群 ID 不属于该档案');
  if (scenarioId && !scenarioIds.has(scenarioId)) throw new AppError('scenario_not_found', '场景 ID 不属于该档案');
  if (!audienceId) audienceId = 'unassigned';
  if (!scenarioId) scenarioId = 'unassigned';

  const channel = CHANNELS.has(cleanText(src.channel, 20)) ? cleanText(src.channel, 20) : 'other';
  const signalType = SIGNAL_TYPES.has(cleanText(src.signal_type, 20)) ? cleanText(src.signal_type, 20) : 'problem';
  const quoteStart = text.indexOf(quote);
  const evidence = {
    id: randomId('ev'),
    url,
    canonical_url: canonical,
    source_domain: domain,
    title,
    text,
    quote,
    quote_start: quoteStart,
    quote_end: quoteStart + quote.length,
    channel,
    signal_type: signalType,
    summary: cleanText(src.summary, 800) || quote.slice(0, 200),
    audience_id: audienceId,
    scenario_id: scenarioId,
    region: cleanText(src.region, 80) || '未知',
    language: cleanText(src.language, 80) || '未知',
    published_at: cleanText(src.published_at, 60) || null,
    terms: asArray(src.terms).slice(0, 20),
    content_sha256: contentHash,
    imported_at: nowIso(),
    included: true,
  };
  profile.evidence = Array.isArray(profile.evidence) ? profile.evidence : [];
  profile.evidence.push(evidence);
  profile.status = 'researching';
  store.save(profile);
  return { accepted: true, duplicate: false, evidence, profile };
}

function findDuplicate(profile, canonical, contentHash, text, title) {
  const evidence = Array.isArray(profile.evidence) ? profile.evidence : [];
  for (const item of evidence) {
    if (item.canonical_url === canonical) return { id: item.id, kind: 'canonical_url' };
    if (item.content_sha256 === contentHash) return { id: item.id, kind: 'content_hash' };
  }
  const normTitle = normalizeForCompare(title);
  for (const item of evidence) {
    const sameTitle = normTitle && normalizeForCompare(item.title) === normTitle;
    const sim = jaccard(text, item.text);
    if (sim >= 0.9 || (sameTitle && sim >= 0.8)) return { id: item.id, kind: 'near_duplicate' };
  }
  return null;
}

function buildReport(store, id) {
  const profile = store.get(id);
  if (!profile.calibration || !profile.calibration.locked || !['confirmed', 'researching', 'report'].includes(profile.status)) {
    throw new AppError('not_confirmed', '未确认并锁定校准前，禁止生成报告', 409);
  }
  const evidence = (profile.evidence || []).filter((x) => x.included !== false);
  const scenarios = (profile.calibration.items || []).filter((x) => x.status !== 'excluded');
  const coverage = [];
  for (const item of scenarios) {
    const related = evidence.filter((e) => e.scenario_id === item.id);
    const audience = (profile.guidance.audiences || []).find((a) => a.id === item.audience_id);
    coverage.push({
      scenario_id: item.id,
      audience_id: item.audience_id,
      audience_label: item.audience_label,
      audience_status: audience ? audience.status || 'included' : 'included',
      scenario: item.scenario,
      hypothesis: item.user_text || item.problem_hypothesis,
      evidence_count: related.length,
      groups: groupSignals(related),
    });
  }
  const unassigned = evidence.filter((e) => e.scenario_id === 'unassigned');
  const channels = uniqueStrings(evidence.map((e) => e.channel));
  const domains = uniqueStrings(evidence.map((e) => e.source_domain));
  const regions = countBy(evidence.map((e) => e.region || '未知'));
  const languages = countBy(evidence.map((e) => e.language || '未知'));
  const blind = {
    scenarios: coverage.filter((c) => c.evidence_count === 0).map((c) => ({ scenario_id: c.scenario_id, scenario: c.scenario })),
    channels_missing: ['forum', 'vendor', 'creator', 'social', 'other'].filter((c) => !channels.includes(c)),
    unassigned_evidence: unassigned.length,
    unknown_region_evidence: evidence.filter((e) => !e.region || e.region === '未知').length,
    unknown_language_evidence: evidence.filter((e) => !e.language || e.language === '未知').length,
  };
  const duplicatesRejected = Array.isArray(profile.duplicate_log) ? profile.duplicate_log.length : 0;
  const level = watermarkLevel(domains.length, channels.length, evidence.length);
  const report = {
    generated_at: nowIso(),
    profile_id: profile.id,
    business_name: profile.guidance.name,
    method: {
      steps: ['描述', '人群假设', '小样本校准', '用户确认并锁定', '手工证据导入', '证据驱动报告'],
      auto_search: false,
      note: '自动搜索后端待接；当前只支持用户手工导入 URL + 原文。模型生成的校准词不是证据。',
    },
    calibration: {
      version: profile.calibration.version,
      confirmed_at: profile.calibration.confirmed_at,
      provider: profile.calibration.provider,
      model: profile.calibration.model,
      sample_count: Array.isArray(profile.calibration_samples) ? profile.calibration_samples.length : 0,
    },
    coverage,
    unassigned: groupSignals(unassigned),
    term_pool: buildTermPool(profile, evidence),
    watermark: {
      level,
      label: watermarkLabel(level),
      accepted_evidence: evidence.length,
      independent_sources: domains.length,
      source_domains: domains,
      channel_count: channels.length,
      channels,
      duplicates_rejected: duplicatesRejected,
      regions,
      languages,
      blind_spots: blind,
      rule: '只统计已确认档案内、通过引用校验并去重后的手工证据；独立来源按域名去重。不声称市场份额、实际触达或平台整体规模。',
    },
    limitations: [
      '自动搜索未接入；未导入的来源不会出现在报告。',
      '证据由用户提供原文；系统只做引用定位和聚合，不把模型文本当作证据。',
      '地域/语言未知会显式计入盲区，不推断。',
      '样本非概率抽样，不能外推市场份额或实际触达。',
    ],
  };
  profile.report = report;
  profile.status = 'report';
  store.save(profile);
  return report;
}

function groupSignals(evidence) {
  const out = [];
  const types = ['problem', 'need', 'contradiction', 'behavior'];
  for (const type of types) {
    const items = evidence.filter((e) => e.signal_type === type);
    if (!items.length) continue;
    const bySummary = new Map();
    for (const item of items) {
      const key = item.summary.trim().toLowerCase();
      if (!bySummary.has(key)) {
        bySummary.set(key, { summary: item.summary, count: 0, citations: [] });
      }
      const row = bySummary.get(key);
      row.count += 1;
      row.citations.push({
        evidence_id: item.id,
        title: item.title,
        url: item.url,
        quote: item.quote,
        source_domain: item.source_domain,
        region: item.region || '未知',
        language: item.language || '未知',
        published_at: item.published_at,
      });
    }
    for (const row of bySummary.values()) out.push({ signal_type: type, ...row });
  }
  return out;
}

function buildTermPool(profile, evidence) {
  const terms = new Map();
  const add = (term, origin, sourceId, evidenceId) => {
    const clean = cleanText(term, 80);
    if (!clean) return;
    const key = clean.toLowerCase();
    if (!terms.has(key)) {
      terms.set(key, { term: clean, origins: new Set(), evidence_ids: new Set(), sources: new Set(), model_seed: false });
    }
    const row = terms.get(key);
    row.origins.add(origin);
    if (sourceId) row.sources.add(sourceId);
    if (evidenceId) row.evidence_ids.add(evidenceId);
    if (origin === 'model_seed') row.model_seed = true;
  };
  for (const item of profile.calibration.items || []) {
    if (item.status === 'excluded') continue;
    for (const term of item.seed_terms || []) add(term, 'model_seed', item.id, null);
  }
  for (const phrase of profile.guidance.user_phrases || []) add(phrase, 'user_phrase', 'guidance', null);
  for (const item of evidence) {
    for (const term of item.terms || []) add(term, 'evidence', item.source_domain, item.id);
  }
  const out = [];
  for (const row of terms.values()) {
    const text = `${row.term}`.toLowerCase();
    const support = evidence.filter((e) => (e.text || '').toLowerCase().includes(text)).length;
    out.push({
      term: row.term,
      origins: Array.from(row.origins),
      origin_label: Array.from(row.origins).map(originLabel).join(' / '),
      evidence_support: support,
      evidence_ids: Array.from(row.evidence_ids),
      sources: Array.from(row.sources),
      is_model_seed_only: row.origins.size === 1 && row.origins.has('model_seed'),
    });
  }
  out.sort((a, b) => b.evidence_support - a.evidence_support || b.origins.length - a.origins.length);
  return out;
}

function originLabel(origin) {
  return { model_seed: '校准种子', user_phrase: '用户原话', evidence: '证据' }[origin] || origin;
}

function watermarkLevel(sources, channels, evidenceCount) {
  if (!evidenceCount) return 'none';
  if (sources >= 5 && channels >= 3) return 'high';
  if (sources >= 3 && channels >= 2) return 'medium';
  return 'low';
}

function watermarkLabel(level) {
  return { none: '无证据', low: 'L1 稀少', medium: 'L2 初步', high: 'L3 多源' }[level] || level;
}

function countBy(values) {
  const out = {};
  for (const value of values) out[value] = (out[value] || 0) + 1;
  return out;
}

function evidenceView(profile) {
  return (profile.evidence || []).map((e) => ({
    id: e.id,
    title: e.title,
    url: e.url,
    source_domain: e.source_domain,
    channel: e.channel,
    signal_type: e.signal_type,
    summary: e.summary,
    text: e.text,
    quote: e.quote,
    audience_id: e.audience_id,
    scenario_id: e.scenario_id,
    region: e.region,
    language: e.language,
    published_at: e.published_at,
    imported_at: e.imported_at,
  }));
}

function profileView(profile) {
  return {
    id: profile.id,
    status: profile.status,
    created_at: profile.created_at,
    updated_at: profile.updated_at,
    guidance: profile.guidance,
    calibration: profile.calibration,
    calibration_samples: Array.isArray(profile.calibration_samples) ? profile.calibration_samples : [],
    evidence: evidenceView(profile),
    duplicate_log: profile.duplicate_log || [],
    report: profile.report || null,
  };
}

module.exports = {
  validateGuidance,
  createProfile,
  addCalibrationSample,
  calibrate,
  updateCalibrationItem,
  confirmCalibration,
  importEvidence,
  buildReport,
  profileView,
  evidenceView,
  watermarkLevel,
  watermarkLabel,
};
