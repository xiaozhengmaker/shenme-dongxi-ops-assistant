'use strict';

const fs = require('fs');
const path = require('path');
const {
  AppError,
  cleanText,
  uniqueStrings,
  nowIso,
  randomId,
  assertPlainId,
  normalizeForCompare,
} = require('./util');

const AUDIENCE_TYPES = new Set(['primary', 'opinion']);
const STRENGTHS = new Set(['low', 'medium', 'high']);

class ResearchStore {
  constructor(dataDir) {
    this.dataDir = path.resolve(dataDir);
    this.dir = path.join(this.dataDir, 'research');
    fs.mkdirSync(this.dir, { recursive: true });
  }

  fileFor(id) {
    assertPlainId(id);
    return path.join(this.dir, `${id}.json`);
  }

  list() {
    const out = [];
    for (const name of fs.readdirSync(this.dir)) {
      if (!name.endsWith('.json')) continue;
      try {
        const brief = JSON.parse(fs.readFileSync(path.join(this.dir, name), 'utf8'));
        out.push({
          id: brief.id,
          question: brief.question,
          created_at: brief.created_at,
          updated_at: brief.updated_at,
          audience_count: Array.isArray(brief.audiences) ? brief.audiences.length : 0,
          keyword_count: Array.isArray(brief.keywords) ? brief.keywords.length : 0,
          evidence_count: 0,
        });
      } catch {
        // A broken brief must not hide the others.
      }
    }
    out.sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
    return out;
  }

  get(id) {
    const file = this.fileFor(id);
    if (!fs.existsSync(file)) throw new AppError('research_not_found', '研究简报不存在', 404);
    try {
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      throw new AppError('research_invalid', '研究简报损坏', 500);
    }
  }

  save(brief) {
    const id = brief.id || `rb-${randomId('r').split('-')[1]}`;
    const now = nowIso();
    const payload = {
      schema_version: 1,
      ...brief,
      id,
      created_at: brief.created_at || now,
      updated_at: now,
    };
    const file = this.fileFor(id);
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', 'utf8');
    fs.renameSync(tmp, file);
    return payload;
  }
}

function asTextList(value, max = 20) {
  if (Array.isArray(value)) return uniqueStrings(value.map((x) => cleanText(x, 400))).slice(0, max);
  if (typeof value === 'string') {
    return uniqueStrings(value.split(/\n|,|，|;/).map((x) => cleanText(x, 400))).slice(0, max);
  }
  return [];
}

function normalizeGap(value) {
  if (!value) return null;
  if (Array.isArray(value)) value = value[0];
  if (typeof value === 'string') {
    const question = cleanText(value, 300);
    return question ? { question, why: '' } : null;
  }
  if (typeof value !== 'object') return null;
  const question = cleanText(value.question || value.text || '', 300);
  if (!question) return null;
  return { question, why: cleanText(value.why || value.basis || '', 600) };
}

function normalizeAudience(raw, index) {
  const label = cleanText(raw && (raw.label || raw.name || raw.audience), 160);
  if (!label) return null;
  const rawType = String((raw && (raw.type || raw.role)) || 'primary').toLowerCase();
  const type = rawType === 'opinion' || rawType === 'influencer' ? 'opinion' : 'primary';
  const strength = String((raw && raw.evidence_strength) || 'low').toLowerCase();
  return {
    id: `ra-${index + 1}`,
    label,
    type: AUDIENCE_TYPES.has(type) ? type : 'primary',
    overlap: Boolean(raw && raw.overlap),
    inclusion: asTextList(raw && (raw.inclusion || raw.inclusion_criteria), 12),
    exclusion: asTextList(raw && (raw.exclusion || raw.exclusion_criteria), 12),
    evidence_strength: STRENGTHS.has(strength) ? strength : 'low',
    rationale: cleanText(raw && (raw.rationale || raw.basis), 800),
  };
}

function normalizeDraft(raw, { question, background, providerInfo }) {
  if (!raw || typeof raw !== 'object') throw new AppError('provider_bad_output', 'provider 未返回可用的研究草稿', 502);
  const businessRaw = raw.business || raw.profile || {};
  const business = {
    name: cleanText(businessRaw.name || shortName(question), 160),
    description: cleanText(businessRaw.description || '', 2000),
    problem: cleanText(businessRaw.problem || question, 2000),
    decision_purpose: cleanText(businessRaw.decision_purpose || '', 1200),
    value_user: asTextList(businessRaw.value_user || businessRaw.user_value, 10),
    value_payer: asTextList(businessRaw.value_payer || businessRaw.payer_value, 10),
  };
  const rawAudiences = Array.isArray(raw.audiences) ? raw.audiences : [];
  const audiences = rawAudiences.map(normalizeAudience).filter(Boolean).slice(0, 8);
  if (!audiences.length) throw new AppError('provider_bad_output', 'provider 没有草拟出可确认的人群', 502);

  const criteriaRaw = raw.criteria || {};
  const criteria = {
    inclusion: asTextList(criteriaRaw.inclusion || criteriaRaw.include, 16),
    exclusion: asTextList(criteriaRaw.exclusion || criteriaRaw.exclude, 16),
  };
  if (!criteria.inclusion.length) {
    criteria.inclusion = uniqueStrings(audiences.flatMap((a) => a.inclusion)).slice(0, 16);
  }
  if (!criteria.exclusion.length) {
    criteria.exclusion = uniqueStrings(audiences.flatMap((a) => a.exclusion)).slice(0, 16);
  }

  const channels = asTextList(raw.channels || raw.channel, 20);
  const keywords = asTextList(raw.keywords || raw.keyword || raw.seed_terms, 24);
  const strengthRaw = raw.evidence_strength;
  const evidenceStrength = typeof strengthRaw === 'object' && strengthRaw
    ? {
        level: STRENGTHS.has(String(strengthRaw.level || '').toLowerCase()) ? String(strengthRaw.level).toLowerCase() : 'low',
        rationale: cleanText(strengthRaw.rationale || strengthRaw.basis || '', 1200),
        gaps: asTextList(strengthRaw.gaps, 12),
      }
    : {
        level: STRENGTHS.has(String(strengthRaw || '').toLowerCase()) ? String(strengthRaw).toLowerCase() : 'low',
        rationale: '',
        gaps: [],
      };

  const assumptions = asTextList(raw.assumptions, 12).map((text) => ({ text, basis: 'provider 草稿，待你确认' }));
  const limitations = asTextList(raw.limitations, 12);
  const gap = normalizeGap(raw.context_gap || raw.follow_up || raw.next_question);
  const mocked = Boolean(providerInfo && providerInfo.mocked);
  const fixedLimits = [
    '本版不进行自动搜索；确认研究谁只生成研究简报，不生成真实线索。',
    '线索为空表示尚未导入可核对证据；不把模型草稿当作证据。',
  ];
  if (mocked) fixedLimits.unshift('fixture 演示草稿：由合成规则生成，不是真实模型，也不是真实研究结论。');
  if (gap && !background) {
    // Keep the single context question visible, but never block confirmation.
    assumptions.push({
      text: `关于「${gap.question}」，当前按“暂不确定，先按上述假设继续”处理。`,
      basis: '用户尚未补充背景；可随时在业务背景中补写后再生成',
    });
  }
  const blindSpots = uniqueStrings([
    '尚无证据：线索为空，不能据此判断市场规模、付费意愿或实际触达。',
    '地域与语言分布未验证。',
    '渠道覆盖只是研究假设，尚未用独立来源验证。',
    ...(evidenceStrength.gaps || []),
    ...(raw.coverage && Array.isArray(raw.coverage.blind_spots) ? raw.coverage.blind_spots : []),
  ]).slice(0, 20);

  return {
    business,
    audiences,
    criteria,
    channels,
    keywords,
    evidence_strength: evidenceStrength,
    assumptions,
    limitations: uniqueStrings([...limitations, ...fixedLimits]).slice(0, 16),
    context_gap: gap,
    coverage: {
      blind_spots: blindSpots,
      channels: channels,
      evidence_count: 0,
    },
    auto_search: false,
    generated_at: nowIso(),
  };
}

function shortName(question) {
  const text = cleanText(question, 160).replace(/\s+/g, ' ');
  return text.length > 48 ? `${text.slice(0, 48)}…` : text || '未命名研究';
}

async function draftResearch({ provider, question, background }) {
  const q = cleanText(question, 3000);
  if (!q) throw new AppError('missing_question', '请先输入研究问题；这是唯一必填项', 400);
  if (!provider || typeof provider.draftResearch !== 'function') {
    throw new AppError('provider_not_configured', 'provider 未提供研究草稿能力', 503);
  }
  let raw;
  try {
    raw = await provider.draftResearch({ question: q, background: cleanText(background, 4000) });
  } catch (err) {
    if (err instanceof AppError) throw err;
    throw new AppError('provider_failed', '研究草稿生成失败，未生成编造结果', 502);
  }
  const draft = normalizeDraft(raw, {
    question: q,
    background: cleanText(background, 4000),
    providerInfo: provider.info(),
  });
  return {
    draft,
    provider: provider.info(),
    auto_search: false,
    note: '草稿只用于确认研究谁；确认后直接显示关键词、渠道与覆盖盲区，不自动搜索，也不自动锁定正式研究。',
  };
}

function sanitizeAudiences(input) {
  const list = (Array.isArray(input) ? input : []).map(normalizeAudience).filter(Boolean).slice(0, 8);
  if (!list.length) throw new AppError('audience_required', '至少保留一个人群，才能确认研究谁', 400);
  return list;
}

function saveBrief(store, { question, background, draft, providerInfo }) {
  const q = cleanText(question, 3000);
  if (!q) throw new AppError('missing_question', '研究问题不能为空', 400);
  if (!draft || typeof draft !== 'object') throw new AppError('draft_required', '缺少研究草稿', 400);
  const provider = providerInfo || {};
  const mocked = Boolean(provider.mocked);
  const audiences = sanitizeAudiences(draft.audiences);
  const business = draft.business || {};
  const criteria = draft.criteria || { inclusion: [], exclusion: [] };
  const channels = asTextList(draft.channels, 20);
  const keywords = asTextList(draft.keywords, 24);
  const limitations = uniqueStrings([
    ...asTextList(draft.limitations, 12),
    '本版未执行自动搜索；线索为空表示没有可核对证据，不代表“没有需求”。',
    '确认研究谁不会锁定正式研究，也不会覆盖已有人群标准或档案。',
  ]);
  if (mocked) limitations.unshift('fixture 演示：以下人群、标准、渠道与关键词为合成草稿，不是真实研究结论。');
  const brief = {
    question: q,
    background: cleanText(background, 4000),
    business: {
      name: cleanText(business.name || shortName(q), 160),
      description: cleanText(business.description || '', 2000),
      problem: cleanText(business.problem || q, 2000),
      decision_purpose: cleanText(business.decision_purpose || '', 1200),
      value_user: asTextList(business.value_user, 10),
      value_payer: asTextList(business.value_payer, 10),
    },
    audiences,
    criteria: {
      inclusion: asTextList(criteria.inclusion, 16),
      exclusion: asTextList(criteria.exclusion, 16),
    },
    channels,
    keywords,
    evidence_strength: draft.evidence_strength || { level: 'low', rationale: '', gaps: [] },
    assumptions: Array.isArray(draft.assumptions) ? draft.assumptions.slice(0, 12) : [],
    limitations,
    coverage: {
      blind_spots: uniqueStrings([
        ...((draft.coverage && Array.isArray(draft.coverage.blind_spots)) ? draft.coverage.blind_spots : []),
        '尚无证据：线索为空，不能据此判断市场规模、付费意愿或实际触达。',
        '地域与语言分布未验证。',
      ]).slice(0, 20),
      channels,
      evidence_count: 0,
    },
    leads: [],
    leads_note: '暂无可用线索：本版不自动搜索；确认研究谁不要求先导入证据。若后续手工导入证据，再另行形成可核对线索。',
    evidence_count: 0,
    auto_search: false,
    calibration_locked: false,
    formal_profile_created: false,
    provider: { name: provider.name || 'unknown', mocked, model: provider.model || null },
    fixture: mocked,
  };
  return store.save(brief);
}

function briefView(brief) {
  return {
    ...brief,
    audience_count: brief.audiences.length,
    keyword_count: brief.keywords.length,
    channel_count: brief.channels.length,
    blind_spot_count: brief.coverage ? brief.coverage.blind_spots.length : 0,
  };
}

module.exports = {
  ResearchStore,
  draftResearch,
  saveBrief,
  briefView,
  normalizeDraft,
};
