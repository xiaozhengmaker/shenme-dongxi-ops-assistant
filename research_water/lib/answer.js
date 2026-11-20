'use strict';

const {
  AppError,
  nowIso,
  cleanText,
  normalizeForCompare,
  uniqueStrings,
} = require('./util');

const MAX_EVIDENCE = 8;
const ELIGIBLE_STATUSES = new Set(['confirmed', 'researching', 'report']);

function questionTerms(question) {
  const norm = normalizeForCompare(question);
  const terms = new Set();
  for (const chunk of norm.split(' ')) {
    if (!chunk) continue;
    if (chunk.length > 1) terms.add(chunk.slice(0, 48));
    if (/[\u4e00-\u9fff]/.test(chunk)) {
      const max = Math.min(4, chunk.length);
      for (let size = 2; size <= max; size += 1) {
        for (let i = 0; i + size <= chunk.length; i += 1) terms.add(chunk.slice(i, i + size));
      }
    }
    if (terms.size >= 120) break;
  }
  return Array.from(terms);
}

function rankEvidence(question, evidence) {
  const terms = questionTerms(question);
  if (!terms.length) return [];
  const scored = [];
  for (const item of evidence || []) {
    const title = normalizeForCompare(item.title || '');
    const body = normalizeForCompare([
      item.title,
      item.summary,
      item.quote,
      (item.terms || []).join(' '),
      item.audience_label,
      item.scenario_label,
    ].join(' '));
    let score = 0;
    for (const term of terms) {
      if (!term || term.length < 2) continue;
      if (title.includes(term)) score += 4;
      else if (body.includes(term)) score += term.length >= 3 ? 2 : 1;
    }
    if (score > 0) scored.push({ item, score, at: item.imported_at || '' });
  }
  scored.sort((a, b) => b.score - a.score || String(b.at).localeCompare(String(a.at)));
  return scored.slice(0, MAX_EVIDENCE).map((x) => x.item);
}

function audienceLabel(profile, id) {
  const found = (profile.guidance.audiences || []).find((a) => a.id === id);
  return found ? found.label : '未归类人群';
}

function scenarioLabel(profile, id) {
  const found = (profile.calibration.items || []).find((x) => x.id === id);
  return found ? found.scenario : '未归类场景';
}

function citation(profile, evidence) {
  return {
    id: evidence.id,
    title: cleanText(evidence.title, 300),
    url: cleanText(evidence.url, 2000),
    source_domain: cleanText(evidence.source_domain, 200),
    quote: cleanText(evidence.quote, 2000),
    summary: cleanText(evidence.summary, 800),
    channel: cleanText(evidence.channel, 40),
    signal_type: cleanText(evidence.signal_type, 40),
    audience_label: audienceLabel(profile, evidence.audience_id),
    scenario_label: scenarioLabel(profile, evidence.scenario_id),
    region: cleanText(evidence.region, 80) || '未知',
    language: cleanText(evidence.language, 80) || '未知',
    published_at: evidence.published_at || null,
  };
}

function buildContext(profile, question) {
  if (!profile) return { question, profile: null, evidence: [] };
  const available = (profile.evidence || []).filter((e) => e.included !== false);
  const selected = rankEvidence(question, available);
  const hypotheses = (profile.calibration && profile.calibration.items ? profile.calibration.items : [])
    .filter((x) => x.status === 'retained' || x.status === 'modified')
    .map((x) => ({
      scenario: cleanText(x.scenario, 300),
      hypothesis: cleanText(x.user_text || x.problem_hypothesis, 1200),
      audience_label: cleanText(x.audience_label, 120),
    }));
  return {
    question,
    profile: {
      id: profile.id,
      name: cleanText(profile.guidance.name, 120),
      description: cleanText(profile.guidance.description, 3000),
      problem: cleanText(profile.guidance.problem, 2000),
      decision_purpose: cleanText(profile.guidance.decision_purpose, 1200),
      value_user: profile.guidance.value_user || [],
      value_payer: profile.guidance.value_payer || [],
      audiences: (profile.guidance.audiences || []).map((a) => ({
        label: cleanText(a.label, 120),
        role: a.role,
        status: a.status,
        overlap: Boolean(a.overlap),
        rationale: cleanText(a.rationale, 1000),
      })),
      hypotheses,
      regions: profile.guidance.regions || [],
      languages: profile.guidance.languages || [],
    },
    evidence: selected.map((e) => citation(profile, e)),
    evidence_available: available.length,
    evidence_used: selected.length,
  };
}

function asText(value, max = 2000) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return cleanText(value, max);
  }
  if (typeof value === 'object') {
    return cleanText(value.text || value.statement || value.finding || value.why || '', max);
  }
  return '';
}

function asBasis(value, max = 1000) {
  if (typeof value === 'string') return cleanText(value, max);
  if (value && typeof value === 'object') return cleanText(value.basis || value.reason || '', max);
  return '';
}

function normalizeList(value) {
  if (!Array.isArray(value)) return [];
  return value.map((x) => asText(x, 2000)).filter(Boolean);
}

function normalizeFindings(value, evidenceById, evidenceAvailable) {
  const findings = [];
  const dropped = [];
  if (!Array.isArray(value)) return { findings, dropped };
  for (const raw of value.slice(0, 10)) {
    const statement = asText(raw, 2000);
    if (!statement) continue;
    const ids = Array.isArray(raw && raw.citation_ids)
      ? raw.citation_ids
      : Array.isArray(raw && raw.citations)
        ? raw.citations.map((c) => (typeof c === 'string' ? c : c && c.id))
        : [];
    const valid = uniqueStrings(ids.map((id) => cleanText(id, 80)).filter((id) => evidenceById.has(id)));
    if (valid.length) {
      findings.push({ statement, citation_ids: valid });
    } else {
      dropped.push({
        statement,
        basis: evidenceAvailable
          ? '模型给出的引用无法核对，已降级为推断'
          : '没有可核对证据，已降级为推断',
      });
    }
  }
  return { findings: findings.slice(0, 6), dropped };
}

function normalizeInferences(value, dropped) {
  const out = [];
  if (Array.isArray(value)) {
    for (const raw of value.slice(0, 10)) {
      const statement = asText(raw, 2000);
      if (!statement) continue;
      out.push({ statement, basis: asBasis(raw) || '推断，未经证据直接验证' });
    }
  }
  for (const item of dropped) out.push(item);
  return out.slice(0, 8);
}

function normalizeFollowUp(value) {
  if (!value) return null;
  const raw = Array.isArray(value) ? value[0] : value;
  if (!raw) return null;
  const question = cleanText(typeof raw === 'string' ? raw : raw.question || raw.text, 300);
  if (!question) return null;
  return {
    question,
    why: cleanText(typeof raw === 'object' ? raw.why || raw.basis || '' : '', 600),
  };
}

function normalizeAnswer(raw, context, provider) {
  const info = provider && typeof provider.info === 'function' ? provider.info() : {};
  const mocked = Boolean(info.mocked || info.name === 'fixture');
  const evidence = context.evidence || [];
  const evidenceById = new Set(evidence.map((e) => e.id));
  const findings = normalizeFindings(raw && (raw.evidence_findings || raw.evidence), evidenceById, evidence.length);
  const assumptions = [];
  for (const item of Array.isArray(raw && raw.assumptions) ? raw.assumptions.slice(0, 6) : []) {
    const text = asText(item, 1200);
    if (text) assumptions.push({ text, basis: asBasis(item) });
  }
  const unknowns = uniqueStrings(Array.isArray(raw && raw.unknowns) ? raw.unknowns.map((x) => asText(x, 1200)) : []).slice(0, 8);
  const validation = uniqueStrings(Array.isArray(raw && raw.validation) ? raw.validation.map((x) => asText(x, 1200)) : []).slice(0, 6);
  const limitations = uniqueStrings([
    ...(Array.isArray(raw && raw.limitations) ? raw.limitations.map((x) => asText(x, 1200)) : []),
    '未执行自动广搜，未引入所选档案之外的来源。',
  ]);
  if (!context.profile) limitations.push('未选择研究档案，因此没有复用任何已有证据。');
  else if (!evidence.length) limitations.push('所选档案中没有与问题直接相关且可核对的有效证据。');
  else if (context.evidence_available > evidence.length) {
    limitations.push(`仅使用最相关的 ${evidence.length} 条证据（共 ${context.evidence_available} 条），不代表全部证据。`);
  }
  if (mocked) limitations.push('fixture 演示数据：用于验证界面与流程，不是真实模型结论，也不代表真实证据。');
  return {
    mode: mocked ? 'fixture' : 'provider',
    question: context.question,
    profile: context.profile ? { id: context.profile.id, name: context.profile.name, status: null } : null,
    provider: { ...info, mocked },
    assumptions,
    evidence_findings: findings.findings,
    inferences: normalizeInferences(raw && raw.inferences, findings.dropped),
    unknowns,
    conditional_judgment: asText(raw && raw.conditional_judgment, 3000) || '现有信息不足，暂时无法给出确定回答。',
    validation,
    follow_up: normalizeFollowUp(raw && raw.follow_up),
    limitations: uniqueStrings(limitations),
    citations: evidence,
    evidence_used: evidence.length,
    evidence_available: context.evidence_available || 0,
    auto_search: false,
    generated_at: nowIso(),
  };
}

async function answerQuestion({ store, provider, question, profileId }) {
  const text = cleanText(question, 3000);
  if (!text) throw new AppError('missing_question', '请输入一个关键问题', 400);
  let profile = null;
  if (profileId) {
    profile = store.get(cleanText(profileId, 80));
    if (!profile.calibration || !profile.calibration.locked || !ELIGIBLE_STATUSES.has(profile.status)) {
      throw new AppError('profile_not_confirmed', '该研究档案尚未确认并锁定；固定人群与证据不能自动覆盖', 409);
    }
  }
  if (!provider || typeof provider.answerQuestion !== 'function') {
    throw new AppError('provider_not_configured', '当前 provider 不支持问答；请配置服务端模型或使用 fixture 演示', 503);
  }
  const context = buildContext(profile, text);
  let raw;
  try {
    raw = await provider.answerQuestion({ question: text, context });
  } catch (err) {
    if (err instanceof AppError) throw err;
    throw new AppError('provider_failed', `问答模型调用失败：${err && err.message ? err.message : '未知错误'}`, 502);
  }
  const answer = normalizeAnswer(raw || {}, context, provider);
  if (profile) {
    answer.profile.status = profile.status;
    answer.profile.evidence_available = context.evidence_available || 0;
    answer.profile.evidence_used = context.evidence_used || 0;
  }
  return answer;
}

function listResearchProfiles(store) {
  const out = [];
  for (const item of store.list()) {
    let profile;
    try {
      profile = store.get(item.id);
    } catch {
      continue;
    }
    if (!profile.calibration || !profile.calibration.locked || !ELIGIBLE_STATUSES.has(profile.status)) continue;
    const evidenceCount = (profile.evidence || []).filter((e) => e.included !== false).length;
    if (!evidenceCount) continue;
    out.push({
      id: profile.id,
      name: cleanText(profile.guidance && profile.guidance.name, 120) || profile.id,
      status: profile.status,
      evidence_count: evidenceCount,
      updated_at: profile.updated_at || null,
    });
  }
  return out;
}

module.exports = {
  MAX_EVIDENCE,
  questionTerms,
  rankEvidence,
  buildContext,
  normalizeAnswer,
  answerQuestion,
  listResearchProfiles,
};
