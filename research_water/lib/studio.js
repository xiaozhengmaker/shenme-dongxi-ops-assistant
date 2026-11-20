'use strict';

const {
  AppError,
  cleanText,
  uniqueStrings,
  sha256,
  canonicalUrl,
} = require('./util');
const { questionTerms } = require('./answer');

const SOURCE_TYPES = {
  verified: '经真实检索且有证据',
  user_phrase: '用户原话',
  ai_candidate: 'AI候选',
};

const INTENT_LABELS = {
  problem: '问题',
  need: '需要',
  contradiction: '矛盾',
  behavior: '行为',
};

const MAX_KEYWORDS = 40;
const MAX_EVIDENCE = 30;

function splitSentence(sentence) {
  const raw = cleanText(sentence, 3000);
  if (!raw) throw new AppError('missing_sentence', '请用一句话写下业务和关键问题', 400);
  const match = raw.match(/^(.{2,80}?)[，,：:；;\n]\s*(.{4,})$/);
  if (match) return { business: cleanText(match[1], 160), question: cleanText(match[2], 3000) };
  return { business: '', question: raw };
}

function audienceSignature(audiences) {
  const normalized = (audiences || [])
    .map((a) => ({
      label: cleanText(a.label, 160),
      type: a.type === 'opinion' ? 'opinion' : 'primary',
    }))
    .filter((a) => a.label)
    .sort((a, b) => `${a.type}|${a.label}`.localeCompare(`${b.type}|${b.label}`));
  return sha256(JSON.stringify(normalized));
}

function normalizeAudiences(audiences) {
  const out = [];
  const seen = new Set();
  for (const raw of audiences || []) {
    const label = cleanText(typeof raw === 'string' ? raw : raw && raw.label, 160);
    if (!label) continue;
    const key = label.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({
      label,
      type: raw && raw.type === 'opinion' ? 'opinion' : 'primary',
      overlap: Boolean(raw && raw.overlap),
      rationale: cleanText(raw && (raw.rationale || raw.basis), 600),
    });
  }
  return out.slice(0, 8);
}

function profileAudiences(profile) {
  return normalizeAudiences((profile.guidance && profile.guidance.audiences) || []);
}

function profileUnderstanding(profile, sentence, sentenceParts) {
  const audiences = profileAudiences(profile);
  const keywords = uniqueStrings([
    ...(profile.guidance.seed_terms || []),
    ...(profile.guidance.user_phrases || []),
    ...((profile.evidence || []).flatMap((e) => e.terms || [])),
  ]).slice(0, MAX_KEYWORDS);
  return {
    sentence,
    business: cleanText((profile.guidance && profile.guidance.name) || sentenceParts.business, 200),
    question: sentenceParts.question || cleanText(profile.guidance.problem, 3000),
    audiences,
    audience_signature: audienceSignature(audiences),
    keywords,
    profile_id: profile.id,
    profile_name: cleanText(profile.guidance.name, 160),
    profile_locked: Boolean(profile.calibration && profile.calibration.locked),
    source: 'existing_profile',
    assumptions: [
      { text: `沿用已选档案「${cleanText(profile.guidance.name, 160)}」的业务背景与人群。`, basis: '用户选择/自动匹配已有档案' },
      { text: '关键词来自该档案的种子词、用户原话与已导入证据词；不会混入其他档案。', basis: '严格档案隔离' },
    ],
    business_confidence: 'high',
  };
}

function draftUnderstanding(sentence, parts, draft, providerInfo) {
  const audiences = normalizeAudiences(draft.audiences || []);
  const keywords = uniqueStrings([
    ...(draft.keywords || []),
    ...(draft.business && draft.business.problem ? [] : []),
  ]).slice(0, MAX_KEYWORDS);
  return {
    sentence,
    business: cleanText(parts.business || (draft.business && draft.business.name), 200),
    question: parts.question || (draft.business && draft.business.problem) || sentence,
    audiences,
    audience_signature: audienceSignature(audiences),
    keywords,
    profile_id: null,
    profile_name: null,
    profile_locked: false,
    source: 'draft',
    provider: providerInfo || null,
    assumptions: Array.isArray(draft.assumptions) ? draft.assumptions : [],
    business_confidence: parts.business ? 'medium' : 'low',
    draft,
  };
}

function findProfileMatches(store, sentence) {
  if (!store || typeof store.list !== 'function') return [];
  const terms = new Set(questionTerms(sentence));
  const matches = [];
  for (const item of store.list()) {
    let profile;
    try {
      profile = store.get(item.id);
    } catch {
      continue;
    }
    if (!profile || !profile.calibration || !profile.calibration.locked) continue;
    const haystack = [
      profile.guidance && profile.guidance.name,
      profile.guidance && profile.guidance.description,
      profile.guidance && profile.guidance.problem,
    ].join(' ');
    let score = 0;
    for (const term of terms) {
      if (term.length >= 2 && haystack.toLowerCase().includes(term)) score += 1;
    }
    if (cleanText(profile.guidance && profile.guidance.name, 160) && sentence.includes(cleanText(profile.guidance.name, 160))) {
      score += 5;
    }
    if (score >= 2) {
      matches.push({
        id: profile.id,
        name: cleanText(profile.guidance && profile.guidance.name, 160),
        score,
        evidence_count: (profile.evidence || []).filter((e) => e.included !== false).length,
      });
    }
  }
  return matches.sort((a, b) => b.score - a.score).slice(0, 5);
}

async function understand({ sentence, profileId, store, provider, researchLib }) {
  const raw = cleanText(sentence, 3000);
  if (!raw) throw new AppError('missing_sentence', '请用一句话写下业务和关键问题', 400);
  const parts = splitSentence(raw);
  let profile = null;
  if (profileId) {
    profile = store.get(cleanText(profileId, 80));
  } else {
    const matches = findProfileMatches(store, raw);
    if (matches.length) profile = store.get(matches[0].id);
  }
  if (profile) {
    return {
      understanding: profileUnderstanding(profile, raw, parts),
      matched_profile: profileId ? null : { id: profile.id, name: profile.guidance.name, auto: true },
    };
  }
  if (!provider || typeof provider.draftResearch !== 'function') {
    throw new AppError('provider_not_configured', '当前 provider 不支持一句话理解；请配置服务端模型，或直接用演示样例', 503);
  }
  if (!researchLib || typeof researchLib.draftResearch !== 'function') {
    throw new AppError('internal_error', '研究草稿模块不可用', 500);
  }
  const result = await researchLib.draftResearch({
    provider,
    question: parts.question,
    background: parts.business,
  });
  return {
    understanding: draftUnderstanding(raw, parts, result.draft, result.provider),
    matched_profile: null,
  };
}

function evidenceSourceType(evidence) {
  if (!evidence) return { type: 'ai_candidate', label: SOURCE_TYPES.ai_candidate, note: '还没有可核对证据' };
  if (evidence.verified === true && evidence.retrieval === 'live') {
    return { type: 'verified', label: SOURCE_TYPES.verified, note: '真实检索返回并附原文' };
  }
  if (evidence.demo === true) {
    return { type: 'ai_candidate', label: SOURCE_TYPES.ai_candidate, note: '演示证据，非真实检索，不能称已验证' };
  }
  if (evidence.origin === 'user_phrase' || evidence.origin === 'user_import' || evidence.url) {
    return { type: 'user_phrase', label: SOURCE_TYPES.user_phrase, note: '用户提供/导入的证据，尚未做外部检索验证' };
  }
  return { type: 'ai_candidate', label: SOURCE_TYPES.ai_candidate, note: '未知来源，不能称已验证' };
}

function evidenceCitation(evidence) {
  const source = evidenceSourceType(evidence);
  return {
    id: evidence.id || null,
    title: cleanText(evidence.title, 300),
    url: cleanText(evidence.url, 2000),
    source_domain: cleanText(evidence.source_domain, 200),
    quote: cleanText(evidence.quote, 2000),
    summary: cleanText(evidence.summary, 800),
    terms: Array.isArray(evidence.terms) ? evidence.terms.slice(0, 20) : [],
    signal_type: evidence.signal_type || 'problem',
    intent: INTENT_LABELS[evidence.signal_type] || '问题',
    audience_id: evidence.audience_id || null,
    audience_label: evidence.audience_label || '未归类人群',
    region: cleanText(evidence.region, 80) || '未知',
    language: cleanText(evidence.language, 80) || '未知',
    published_at: evidence.published_at || null,
    source_type: source.type,
    source_type_label: source.label,
    source_note: source.note,
    demo: Boolean(evidence.demo),
    verified: source.type === 'verified',
  };
}

function evidenceText(evidence) {
  return [
    evidence.title,
    evidence.summary,
    evidence.quote,
    evidence.text,
    (evidence.terms || []).join(' '),
    evidence.audience_label,
  ].join(' ').toLowerCase();
}

function audienceForEvidence(profile, understanding, evidence) {
  if (evidence.audience_label) return cleanText(evidence.audience_label, 160);
  if (profile && evidence.audience_id) {
    const found = (profile.guidance.audiences || []).find((a) => a.id === evidence.audience_id);
    if (found) return cleanText(found.label, 160);
  }
  return understanding.audiences[0] ? understanding.audiences[0].label : '未归类人群';
}

function keywordSeeds(understanding, profile, sentence) {
  const fromProfile = profile
    ? [
        ...(profile.guidance.seed_terms || []),
        ...(profile.guidance.user_phrases || []),
        ...((profile.evidence || []).flatMap((e) => e.terms || [])),
      ]
    : [];
  const fromQuestion = questionTerms(sentence).filter((x) => x.length >= 2 && x.length <= 24).slice(0, 12);
  return uniqueStrings([
    ...(understanding.keywords || []),
    ...fromProfile,
    ...fromQuestion,
  ]).slice(0, MAX_KEYWORDS);
}

function buildWorkbench({ sentence, understanding, profile, providerInfo, demo }) {
  const cleanUnderstanding = {
    ...understanding,
    audiences: normalizeAudiences(understanding.audiences),
    keywords: uniqueStrings(understanding.keywords || []).slice(0, MAX_KEYWORDS),
    audience_signature: audienceSignature(understanding.audiences),
  };
  const rawEvidence = profile && profile.calibration && profile.calibration.locked
    ? (profile.evidence || []).filter((e) => e.included !== false).slice(0, MAX_EVIDENCE)
    : (understanding.demo_evidence || []);
  const seenEvidence = new Set();
  const uniqueEvidence = [];
  let duplicateCount = 0;
  for (const e of rawEvidence) {
    const key = e.url ? canonicalUrl(e.url) : (e.id || `${e.title}|${e.quote}`);
    if (seenEvidence.has(key)) {
      duplicateCount += 1;
      continue;
    }
    seenEvidence.add(key);
    uniqueEvidence.push(e);
  }
  const citations = uniqueEvidence.map((e) => {
    const label = audienceForEvidence(profile, cleanUnderstanding, e);
    return evidenceCitation({ ...e, audience_label: label });
  });
  const evidenceByKeyword = new Map();
  const keywordRows = [];
  for (const term of keywordSeeds(cleanUnderstanding, profile, sentence)) {
    const needle = term.toLowerCase();
    const matched = citations.filter((e) => evidenceText(e).includes(needle));
    const unique = new Map();
    for (const ev of matched) {
      const key = ev.url || ev.id || `${ev.title}|${ev.quote}`;
      if (!unique.has(key)) unique.set(key, ev);
    }
    const leadList = Array.from(unique.values());
    const sourceTypes = uniqueStrings(leadList.map((e) => e.source_type));
    const primaryType = sourceTypes.includes('verified')
      ? 'verified'
      : sourceTypes.includes('user_phrase')
        ? 'user_phrase'
        : 'ai_candidate';
    const source = leadList[0]
      ? (leadList[0].source_domain || '未知来源')
      : (providerInfo && providerInfo.mocked ? 'fixture 演示草稿' : 'AI 草稿');
    const intent = leadList[0] ? leadList[0].intent : '待验证需求';
    const audience = leadList[0] ? leadList[0].audience_label : (cleanUnderstanding.audiences[0] ? cleanUnderstanding.audiences[0].label : '未归类人群');
    const row = {
      term,
      intent,
      audience,
      source_type: primaryType,
      source_type_label: SOURCE_TYPES[primaryType],
      source,
      independent_leads: leadList.length,
      evidence_ids: leadList.map((e) => e.id).filter(Boolean),
      evidence: leadList,
      demo: Boolean(demo || leadList.some((e) => e.demo)),
      note: leadList[0] ? leadList[0].source_note : '还没有可核对证据；这是待搜索/待验证词',
      selected: false,
    };
    evidenceByKeyword.set(term, row);
    keywordRows.push(row);
  }

  const groupsMap = new Map();
  for (const ev of citations) {
    const key = `${ev.intent}|${ev.audience_label}`;
    if (!groupsMap.has(key)) {
      groupsMap.set(key, {
        intent: ev.intent,
        question: cleanUnderstanding.question,
        audience: ev.audience_label,
        strength: 'low',
        strong_count: 0,
        weak_count: 0,
        blind_spots: [],
        leads: [],
        keywords: new Set(),
      });
    }
    const group = groupsMap.get(key);
    const related = keywordRows.filter((k) => k.evidence.some((e) => e.url === ev.url && e.title === ev.title));
    for (const k of related) group.keywords.add(k.term);
    group.leads.push({
      id: ev.id,
      title: ev.title,
      url: ev.url,
      quote: ev.quote,
      source_domain: ev.source_domain,
      source_type: ev.source_type,
      source_type_label: ev.source_type_label,
      demo: ev.demo,
      keywords: related.map((k) => k.term),
      strength: ev.source_type === 'verified' ? 'high' : ev.source_type === 'user_phrase' ? 'medium' : 'low',
    });
    if (ev.source_type === 'verified') group.strong_count += 1;
    else group.weak_count += 1;
  }
  const leadGroups = Array.from(groupsMap.values()).map((g) => {
    const strength = g.strong_count > 0 ? 'high' : g.weak_count > 0 ? 'medium' : 'low';
    return {
      ...g,
      strength,
      keywords: Array.from(g.keywords),
      blind_spots: uniqueStrings([
        '没有外部自动搜索；线索只来自本地/演示证据。',
        '独立来源数与市场触达无关，不能据此推断份额。',
        ...(g.strong_count ? [] : ['当前没有经真实检索验证的证据，结论只能作为待验证假设。']),
      ]),
    };
  });

  const totalLeads = citations.length;
  const independent = new Set(citations.map((e) => e.url || e.id || e.title)).size;
  const zero = totalLeads === 0;
  return {
    sentence,
    understanding: cleanUnderstanding,
    keywords: keywordRows,
    lead_groups: leadGroups,
    citations,
    stats: {
      keyword_count: keywordRows.length,
      lead_count: totalLeads,
      independent_lead_count: independent,
      verified_keyword_count: keywordRows.filter((k) => k.source_type === 'verified').length,
      user_phrase_keyword_count: keywordRows.filter((k) => k.source_type === 'user_phrase').length,
      ai_candidate_keyword_count: keywordRows.filter((k) => k.source_type === 'ai_candidate').length,
      zero_evidence: zero,
      duplicate_count: duplicateCount,
    },
    blind_spots: uniqueStrings([
      ...(zero ? ['尚无可用证据：零线索，不能据此判断需求存在、规模或付费意愿。'] : []),
      ...(duplicateCount ? [`已剔除 ${duplicateCount} 条同源转载/重复 URL，避免重复计数。`] : []),
      '没有执行外部广搜；来源类型不会把 AI 草稿冒充成真实证据。',
      '独立有效线索数按 URL/内容去重，只代表可核对样本，不代表市场触达。',
      ...((understanding.draft && understanding.draft.coverage && understanding.draft.coverage.blind_spots) || []),
    ]),
    source_types: SOURCE_TYPES,
    demo: Boolean(demo),
    auto_search: false,
    generated_at: new Date().toISOString(),
    note: zero
      ? '零条有证据线索。下面仍保留待搜索关键词，便于交接给拓群模块复核；这不是已执行搜索。'
      : '关键词工作台：数字是可核对线索数，不是市场规模；点击关键词可查看证据与 URL。',
  };
}

function confirmation(understanding, confirmedSignature) {
  const signature = audienceSignature(understanding.audiences);
  return {
    required: !confirmedSignature || confirmedSignature !== signature,
    audience_signature: signature,
    first_time: !confirmedSignature,
  };
}

function csvEscape(value) {
  const text = cleanText(value, 4000);
  return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function exportKeywords({ understanding, keywords, profile }) {
  const list = (keywords || []).filter((k) => k && k.term);
  const rows = [
    ['关键词', '意图', '人群', '来源类型', '来源', '独立有效线索数', '问题', '备注'],
    ...list.map((k) => [
      k.term,
      k.intent,
      k.audience,
      k.source_type_label || SOURCE_TYPES[k.source_type] || 'AI候选',
      k.source,
      String(k.independent_leads || 0),
      understanding.question,
      k.demo ? '演示/未验证' : (k.source_type === 'verified' ? '可核对证据' : '待复核'),
    ]),
  ];
  const csv = rows.map((row) => row.map(csvEscape).join(',')).join('\n');
  return {
    ok: true,
    handoff: true,
    executed: false,
    production_connected: false,
    count: list.length,
    filename: 'group-expansion-handoff.csv',
    csv,
    note: '这只是交给原拓群模块复核的关键词清单，不是已执行搜索/加群/采集；不会触发任何任务或读取个人信息。',
    profile_id: profile ? profile.id : (understanding.profile_id || null),
  };
}

function demoUnderstanding() {
  const audiences = [
    { label: '中小跨境卖家（使用者）', type: 'primary', overlap: false, rationale: '演示：负责收款和对账' },
    { label: '财务/运营负责人（付费者）', type: 'primary', overlap: true, rationale: '演示：为支付失败与对账成本付费' },
    { label: '独立站开发者（意见用户）', type: 'opinion', overlap: false, rationale: '演示：影响支付工具选型' },
  ];
  const evidence = [
    {
      id: 'demo-ev-1',
      title: '演示案例：多币种收款到账慢',
      url: 'https://demo.example/case/multi-currency-slow',
      source_domain: 'demo.example',
      quote: '每到月底，多币种收款要三四天才到账，对账只能手工补。',
      summary: '演示：到账时效与对账成本是同一问题。',
      signal_type: 'problem',
      audience_label: '中小跨境卖家（使用者）',
      terms: ['收款到账慢', '多币种', '对账'],
      demo: true,
      verified: false,
      origin: 'demo',
    },
    {
      id: 'demo-ev-2',
      title: '演示案例：手续费不透明',
      url: 'https://demo.example/case/fee-opacity',
      source_domain: 'demo.example',
      quote: '报价里没写跨境费，月底账单才发现多扣了一笔。',
      summary: '演示：费用透明度影响续费意愿。',
      signal_type: 'need',
      audience_label: '财务/运营负责人（付费者）',
      terms: ['手续费不透明', '跨境费', '续费'],
      demo: true,
      verified: false,
      origin: 'demo',
    },
    {
      id: 'demo-ev-3',
      title: '演示案例：拒付和风控拖累',
      url: 'https://demo.example/case/chargeback',
      source_domain: 'demo.example',
      quote: '拒付一多，账号就被风控，客服也解释不清。',
      summary: '演示：拒付处理与风控解释是运营痛点。',
      signal_type: 'contradiction',
      audience_label: '独立站开发者（意见用户）',
      terms: ['拒付', '风控', '客服'],
      demo: true,
      verified: false,
      origin: 'demo',
    },
    {
      id: 'demo-ev-4',
      title: '演示案例：多币种收款到账慢（转载）',
      url: 'https://demo.example/case/multi-currency-slow?utm_source=repost',
      source_domain: 'demo.example',
      quote: '每到月底，多币种收款要三四天才到账，对账只能手工补。',
      summary: '演示重复转载；用于验证去重。',
      signal_type: 'problem',
      audience_label: '中小跨境卖家（使用者）',
      terms: ['收款到账慢', '多币种'],
      demo: true,
      verified: false,
      origin: 'demo',
    },
  ];
  const understanding = {
    sentence: '我们做跨境支付 SaaS，想知道中小卖家最常抱怨的支付问题是什么',
    business: '跨境支付 SaaS（演示）',
    question: '中小跨境卖家最常抱怨的支付问题是什么？',
    audiences,
    audience_signature: audienceSignature(audiences),
    keywords: ['收款到账慢', '手续费不透明', '拒付', '风控', '多币种', '对账', '续费', 'cross-border payments'],
    profile_id: null,
    source: 'demo',
    demo_evidence: evidence,
    assumptions: [
      { text: '演示假设：使用者是中小卖家的运营/财务，付费者是负责人。', basis: '独立 demo 样例' },
      { text: '演示证据为合成文本，只用于展示证据路径，不能当成真实研究结论。', basis: 'fixture 演示' },
    ],
    business_confidence: 'medium',
    draft: {
      coverage: { blind_spots: ['演示未覆盖地域/语言分布。', '演示未接入真实论坛或检索后端。'] },
    },
  };
  return understanding;
}

function demoWorkbench() {
  const understanding = demoUnderstanding();
  return buildWorkbench({
    sentence: understanding.sentence,
    understanding,
    profile: null,
    providerInfo: { mocked: true, name: 'fixture' },
    demo: true,
  });
}

module.exports = {
  SOURCE_TYPES,
  splitSentence,
  audienceSignature,
  normalizeAudiences,
  understand,
  findProfileMatches,
  evidenceSourceType,
  buildWorkbench,
  confirmation,
  exportKeywords,
  demoWorkbench,
};
