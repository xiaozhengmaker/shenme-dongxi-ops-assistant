'use strict';

const { AppError } = require('./util');

class ProviderError extends AppError {
  constructor(code, message, status = 502, details) {
    super(code, message, status, details);
    this.name = 'ProviderError';
  }
}

function readProviderConfig(env = process.env) {
  const mode = String(env.LEADS_WATER_PROVIDER || 'deepseek').toLowerCase();
  if (mode === 'fixture') {
    return { mode, name: 'fixture', configured: true, label: '离线 fixture（演示/测试，非真实模型）' };
  }
  if (mode !== 'deepseek' && mode !== 'openai-compatible') {
    return { mode, name: mode, configured: false, label: '未知 provider', reason: 'provider_unknown' };
  }
  const keyEnv = String(env.LEADS_WATER_API_KEY_ENV || 'LEADS_WATER_API_KEY').trim();
  const key = String(env.LEADS_WATER_API_KEY || env[keyEnv] || '').trim();
  const baseUrl = String(env.LEADS_WATER_BASE_URL || 'https://api.deepseek.com').replace(/\/+$/, '');
  const model = String(env.LEADS_WATER_MODEL || 'deepseek-chat').trim();
  return {
    mode: 'openai-compatible',
    name: 'openai-compatible',
    configured: Boolean(key),
    baseUrl,
    model,
    keyEnv,
    key,
    hasKey: Boolean(key),
    label: 'OpenAI-compatible（服务端密钥）',
    reason: key ? null : 'provider_not_configured',
  };
}

function createProvider(config = readProviderConfig(), deps = {}) {
  const fetchImpl = deps.fetchImpl || globalThis.fetch;
  if (config.mode === 'fixture') return fixtureProvider(config);
  if (config.name === 'openai-compatible') {
    return openAiCompatibleProvider(config, fetchImpl);
  }
  return {
    info() {
      return { name: config.name, configured: false, label: config.label, reason: config.reason || 'provider_unknown', mocked: false };
    },
    async generateCalibration() {
      throw new ProviderError('provider_unknown', 'provider 配置未知', 503);
    },
    async answerQuestion() {
      throw new ProviderError('provider_unknown', 'provider 配置未知', 503);
    },
    async draftResearch() {
      throw new ProviderError('provider_unknown', 'provider 配置未知', 503);
    },
  };
}

function fixtureProvider(config) {
  return {
    info() {
      return { name: 'fixture', configured: true, model: 'fixture-v1', label: config.label, mocked: true };
    },
    async generateCalibration(profile) {
      const items = buildFixtureItems(profile);
      return { items, provider: 'fixture', model: 'fixture-v1', usage: null };
    },
    async answerQuestion({ question, context }) {
      return buildFixtureAnswer(question, context);
    },
    async draftResearch({ question, background }) {
      return buildFixtureResearchDraft(question, background);
    },
  };
}

function shortQuestion(question) {
  const text = String(question || '').replace(/\s+/g, ' ').trim();
  return text.length > 80 ? `${text.slice(0, 80)}…` : text;
}

function buildFixtureAnswer(question, context) {
  const q = shortQuestion(question);
  const evidence = Array.isArray(context && context.evidence) ? context.evidence : [];
  const profile = context && context.profile;
  const evidenceFindings = evidence.slice(0, 2).map((item) => ({
    statement: `关于「${q}」，《${item.title}》中的可核对原文提到：${String(item.quote || '').slice(0, 180)}`,
    citation_ids: [item.id],
  }));
  const audience = profile && profile.audiences && profile.audiences.length
    ? profile.audiences.map((a) => a.label).slice(0, 3).join('、')
    : '目标用户';
  const assumptions = [
    {
      text: `我把「${q}」理解为需要可执行判断的问题，而不是要求泛泛介绍；这是从问题本身作出的假设。`,
      basis: '问题文本，未做外部检索',
    },
  ];
  if (profile) {
    assumptions.push({
      text: `你选择了已确认档案「${profile.name}」；我只使用该档案的证据，不跨档案合并，也不改动其人群标准。`,
      basis: '用户选择的档案与锁定状态',
    });
  } else {
    assumptions.push({
      text: '没有选择研究档案，因此没有复用任何已有证据；下面的判断仅基于问题文本和明示推断。',
      basis: '未选择档案',
    });
  }
  const inferences = evidence.length
    ? [{
        statement: `如果这些证据的代表性成立，那么「${q}」更可能取决于${audience}在具体场景中的取舍，而不是一个单一的全市场结论。`,
        basis: '对所选证据的归纳，属于推断',
      }]
    : [{
        statement: `在缺少可核对证据时，不能直接断定「${q}」的答案；更稳妥的是先验证${audience}是否真的遇到该问题、以及他们现在如何解决。`,
        basis: '无证据条件下的推理，不是事实结论',
      }];
  const unknowns = [
    `「${q}」涉及的目标人群规模、地域分布和支付意愿仍然未知。`,
    '现有材料是否覆盖了反例、沉默用户或替代方案，尚未验证。',
  ];
  if (!evidence.length) unknowns.unshift('没有与问题直接相关、可核对且已确认的证据。');
  const conditional = evidence.length
    ? `条件判断：如果上述 ${evidence.length} 条证据与「${q}」的目标场景一致，那么可以先按“存在明确问题、但价值大小未定”推进；如果证据来自不同人群或渠道，则应先补齐反例再下结论。`
    : `条件判断：目前不能确认「${q}」的答案。若目标人群中确实存在高频、可观察且愿意付出成本的问题，则值得继续验证；若问题只是低频抱怨或没有现有替代成本，则优先级应降低。`;
  const validation = [
    `找 3-5 位${audience}做半结构访谈，追问最近一次遇到「${q}」的具体行为、替代方案和付出成本。`,
    '用一个小样本对照：有该问题与没有该问题的人，是否在行为或付费意愿上出现可重复差异。',
    '主动收集反例与沉默用户，记录哪些证据会推翻当前判断。',
  ];
  return {
    assumptions,
    evidence_findings: evidenceFindings,
    inferences,
    unknowns,
    conditional_judgment: conditional,
    validation,
    follow_up: {
      question: `你说的「${q}」更关心使用者价值，还是付费者的采购/续费决策？`,
      why: '这会改变应该优先验证的人群、证据类型和成功标准；如果你不区分，我会把两者都保留为不确定。',
    },
    limitations: [
      'fixture 演示答案：使用合成档案与规则生成，不是真实模型输出，也不是真实研究结论。',
    ],
  };
}

function buildFixtureResearchDraft(question, background) {
  const q = shortQuestion(question);
  const hay = `${question || ''} ${background || ''}`.toLowerCase();
  const b2b = /(应付|发票|财务|审计|invoice|payable|accounting|ap\s|procurement)/i.test(hay);
  const game = /(皮肤|饰品|游戏|交易|steam|skin)/i.test(hay);
  const topic = b2b ? 'b2b' : game ? 'game' : 'generic';
  const words = String(question || '')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(/\s+/)
    .map((x) => x.trim())
    .filter((x) => x.length >= 2)
    .slice(0, 6);
  const audienceBase = topic === 'b2b'
    ? [
        {
          label: '应付账款/财务运营负责人',
          type: 'primary',
          overlap: false,
          inclusion: ['日常处理发票、付款或关账流程', '对异常队列或对账效率负责'],
          exclusion: ['只做战略规划、不接触日常流程'],
          evidence_strength: 'low',
          rationale: '问题直接指向财务流程的执行者，先验证其真实痛点。',
        },
        {
          label: 'CFO / 财务控制负责人',
          type: 'primary',
          overlap: false,
          inclusion: ['对合规、现金流出或审计结果负责', '能影响采购或续费'],
          exclusion: ['不参与财务工具决策'],
          evidence_strength: 'low',
          rationale: '付费与风险控制通常由这一角色共同决定。',
        },
        {
          label: '外部审计 / 内控顾问',
          type: 'opinion',
          overlap: true,
          inclusion: ['定期审阅客户财务流程与凭证'],
          exclusion: ['只提供一次性税务申报'],
          evidence_strength: 'low',
          rationale: '意见用户可能放大或否定流程价值，但不等同于采购者。',
        },
      ]
    : topic === 'game'
      ? [
          {
            label: '中高频皮肤交易者',
            type: 'primary',
            overlap: false,
            inclusion: ['近期真实买卖或交换过游戏皮肤', '会为价格/流动性/安全性改变行为'],
            exclusion: ['只偶尔观看内容、没有交易行为'],
            evidence_strength: 'low',
            rationale: '先验证有真实交易行为的人，而不是泛游戏玩家。',
          },
          {
            label: '小型皮肤交易商',
            type: 'primary',
            overlap: true,
            inclusion: ['以差价或周转为生', '同时是使用者与付费者'],
            exclusion: ['只做一次性自用购买'],
            evidence_strength: 'low',
            rationale: '小交易商可能同时体现使用价值与付费意愿。',
          },
          {
            label: '社区意见领袖 / 内容创作者',
            type: 'opinion',
            overlap: true,
            inclusion: ['持续影响交易社区的选择与信任'],
            exclusion: ['没有稳定受众或交易相关性'],
            evidence_strength: 'low',
            rationale: '意见用户影响信任，但不能替代真实付费证据。',
          },
        ]
      : [
          {
            label: '直接使用者',
            type: 'primary',
            overlap: false,
            inclusion: ['近期真实使用过同类产品/替代方案', '能描述具体场景与取舍'],
            exclusion: ['只表达泛泛兴趣、没有实际行为'],
            evidence_strength: 'low',
            rationale: '先找有真实行为的人，避免把围观者当成需求。',
          },
          {
            label: '付费决策者',
            type: 'primary',
            overlap: true,
            inclusion: ['能批准预算或影响续费', '关心成本、风险或结果'],
            exclusion: ['没有采购或续费影响力'],
            evidence_strength: 'low',
            rationale: '使用者与付费者可能重叠，但仍需分别验证价值标准。',
          },
          {
            label: '意见影响者',
            type: 'opinion',
            overlap: true,
            inclusion: ['在目标渠道中持续影响选择'],
            exclusion: ['没有稳定受众或专业相关性'],
            evidence_strength: 'low',
            rationale: '意见用户可解释信任来源，但不能冒充付费证据。',
          },
        ];
  const channels = topic === 'b2b'
    ? ['财务/应付从业者社区', '垂直媒体与厂商案例页', '审计/内控专业文章']
    : topic === 'game'
      ? ['皮肤交易社区', '交易市场讨论区', '创作者评测/复盘']
      : ['目标用户社区', '垂直网站/评测', '创作者内容'];
  const keywords = Array.from(new Set([
    ...words,
    topic === 'b2b' ? 'invoice exception queue' : topic === 'game' ? 'skin liquidity' : 'user problem',
    topic === 'b2b' ? 'close cycle' : topic === 'game' ? 'trade safety' : 'willingness to pay',
    topic === 'b2b' ? 'AP automation' : topic === 'game' ? 'price check' : 'alternative solution',
  ])).slice(0, 12);
  const gap = String(background || '').trim()
    ? null
    : {
        question: '这项研究主要面向哪个具体业务、地区或使用场景？',
        why: '这会改变人群优先级、渠道和关键词；可以先不回答，按当前假设继续。',
      };
  return {
    business: {
      name: q || '未命名研究',
      description: `围绕「${q}」的探索性研究草稿；具体业务背景尚未完全确认。`,
      problem: q,
      decision_purpose: '判断应该优先研究谁、用什么证据验证，以及下一步最小验证动作。',
      value_user: ['更快完成关键任务', '减少不确定性或返工'],
      value_payer: ['降低可观察成本或风险', '提升可验证的结果'],
    },
    audiences: audienceBase,
    criteria: {
      inclusion: ['近期有真实行为或决策权', '能提供具体场景、替代方案与取舍'],
      exclusion: ['只有泛泛兴趣或无法核对的二手转述', '与目标业务/地区明显无关'],
    },
    channels,
    keywords,
    evidence_strength: {
      level: 'low',
      rationale: '目前只有问题与草稿，没有可核对证据；人群与渠道均为假设。',
      gaps: ['缺少独立来源', '缺少反例与沉默用户', '地域/语言未验证'],
    },
    assumptions: [
      { text: `问题「${q}」被当作需要可执行判断的研究问题。`, basis: '用户输入' },
      { text: '当前人群按“直接使用者 / 付费者 / 意见影响者”拆分，允许重叠。', basis: '通用研究假设，可修改' },
    ],
    limitations: [
      'fixture 演示：由合成规则生成，不是真实模型，也不是真实研究结论。',
      '没有执行自动搜索，也没有读取任何线上来源。',
      '线索为空，不能据此推断市场规模、需求强度或实际触达。',
    ],
    context_gap: gap,
    coverage: { blind_spots: ['尚无证据', '地域/语言未知', '渠道覆盖未验证'] },
  };
}

function buildFixtureItems(profile) {
  const guidance = profile.guidance || {};
  const audiences = Array.isArray(guidance.audiences) ? guidance.audiences : [];
  const explicitScenarios = Array.isArray(guidance.scenarios) ? guidance.scenarios : [];
  const globalTerms = Array.isArray(guidance.seed_terms) ? guidance.seed_terms : [];
  const items = [];
  const push = (audience, scenario, problem, terms) => {
    items.push({
      id: `cal-${items.length + 1}`,
      audience_id: audience.id,
      audience_label: audience.label,
      scenario: scenario,
      problem_hypothesis: problem,
      seed_terms: Array.isArray(terms) ? terms.slice(0, 8) : [],
      rationale: 'fixture provider 基于档案字段生成的校准假设；需用户逐条确认，不作为证据。',
      status: 'proposed',
    });
  };

  if (explicitScenarios.length) {
    for (const scenario of explicitScenarios) {
      const audience = audiences.find((a) => a.id === scenario.audience_id) || audiences[0];
      if (!audience) continue;
      push(
        audience,
        scenario.scenario || '未命名场景',
        scenario.problem || `在「${scenario.scenario || '该场景'}」中，${audience.label}可能出现可观察的问题或需求。`,
        scenario.seed_terms || globalTerms
      );
    }
  }

  if (!items.length) {
    for (const audience of audiences) {
      push(
        audience,
        `${audience.label}寻找解决方案的场景`,
        `${audience.label}在遇到${guidance.problem || '该问题'}时，可能寻找${guidance.name || '该产品'}。`,
        globalTerms
      );
      push(
        audience,
        `${audience.label}最常遇到的阻碍`,
        `${audience.label}可能反复抱怨流程、成本或信息不透明；需要证据验证。`,
        globalTerms
      );
    }
  }

  if (!items.length) {
    throw new ProviderError('provider_bad_output', '校准没有生成可用条目', 502);
  }
  return items;
}

function openAiCompatibleProvider(config, fetchImpl) {
  return {
    info() {
      return {
        name: 'openai-compatible',
        configured: Boolean(config.hasKey),
        model: config.model,
        baseUrl: config.baseUrl,
        label: config.label,
        reason: config.reason || null,
        mocked: false,
      };
    },
    async generateCalibration(profile) {
      if (!config.hasKey) {
        throw new ProviderError(
          'provider_not_configured',
          `未配置服务端密钥（环境变量 ${config.keyEnv || 'LEADS_WATER_API_KEY'}）。不会生成假结果。`,
          503
        );
      }
      const system = [
        '你是跨业务用户研究校准助手。',
        '只输出 JSON，不要解释。',
        '基于产品描述生成 4-10 个小样本校准条目，每个条目包含：',
        'audience_id（必须来自提供的人群 id）、scenario（具体可观察场景）、',
        'problem_hypothesis（问题/需要/矛盾假设）、seed_terms（3-8 个精准检索种子词）、rationale（推断依据）。',
        '这些是待用户确认的假设，不是证据。不要编造引用。',
        '用户提供的校准样本（samples）只用于理解取舍理由；它们不是正式证据，不能据此声称市场事实。',
      ].join('\n');
      const samples = Array.isArray(profile.calibration_samples) ? profile.calibration_samples : [];
      const user = JSON.stringify({
        guidance: profile.guidance,
        audiences: profile.guidance.audiences,
        samples,
        output_schema: {
          items: [
            {
              audience_id: 'string',
              scenario: 'string',
              problem_hypothesis: 'string',
              seed_terms: ['string'],
              rationale: 'string',
            },
          ],
        },
      });
      const text = await callChat(config, fetchImpl, system, user);
      const parsed = parseJsonObject(text);
      const rawItems = Array.isArray(parsed.items) ? parsed.items : [];
      const audiences = profile.guidance.audiences || [];
      const items = [];
      for (const raw of rawItems.slice(0, 10)) {
        const audience =
          audiences.find((a) => a.id === raw.audience_id) ||
          audiences.find((a) => String(a.label) === String(raw.audience_id)) ||
          audiences.find((a) => String(a.label) === String(raw.audience_label));
        if (!audience) continue;
        const scenario = String(raw.scenario || '').trim();
        const problem = String(raw.problem_hypothesis || raw.problem || '').trim();
        if (!scenario || !problem) continue;
        items.push({
          id: `cal-${items.length + 1}`,
          audience_id: audience.id,
          audience_label: audience.label,
          scenario: scenario.slice(0, 300),
          problem_hypothesis: problem.slice(0, 1200),
          seed_terms: (Array.isArray(raw.seed_terms) ? raw.seed_terms : []).map((x) => String(x).trim()).filter(Boolean).slice(0, 8),
          rationale: String(raw.rationale || '').slice(0, 800),
          status: 'proposed',
        });
      }
      if (!items.length) throw new ProviderError('provider_bad_output', '模型没有返回可用的校准条目', 502);
      return { items, provider: 'openai-compatible', model: config.model, usage: parsed.usage || null };
    },
    async answerQuestion({ question, context }) {
      if (!config.hasKey) {
        throw new ProviderError(
          'provider_not_configured',
          `未配置服务端密钥（环境变量 ${config.keyEnv || 'LEADS_WATER_API_KEY'}）。不会生成假结果。`,
          503
        );
      }
      const system = [
        '你是跨业务用户研究问答助手。你必须只输出 JSON，不要输出 Markdown 或解释。',
        '先直接回答用户的问题，再明确区分：evidence_findings（只能引用给定 citation_id 的可核对证据）、inferences（推断）、unknowns（未知）、assumptions（你自动做出的假设）。',
        '没有证据时 evidence_findings 必须为空，不得编造来源、URL、数字或“我搜索到”。',
        '不要使用通用咨询模板；每个结论都要回应问题中的具体决策。最多提出一个真正会改变判断的 follow_up。',
        '答案要用用户问题的语言；引用必须逐字来自 context.evidence 的 quote，不得改写后冒充原文。',
        '输出字段：assumptions[{text,basis}], evidence_findings[{statement,citation_ids}], inferences[{statement,basis}], unknowns[string], conditional_judgment(string), validation[string], follow_up{question,why}|null, limitations[string]。',
        '不要让答案看起来像自动广搜结果；本次没有自动搜索。',
      ].join('\n');
      const user = JSON.stringify({
        question,
        context,
        output_schema: {
          assumptions: [{ text: 'string', basis: 'string' }],
          evidence_findings: [{ statement: 'string', citation_ids: ['citation_id'] }],
          inferences: [{ statement: 'string', basis: 'string' }],
          unknowns: ['string'],
          conditional_judgment: 'string',
          validation: ['string'],
          follow_up: { question: 'string', why: 'string' },
          limitations: ['string'],
        },
      });
      const text = await callChat(config, fetchImpl, system, user);
      return parseJsonObject(text);
    },
    async draftResearch({ question, background }) {
      if (!config.hasKey) {
        throw new ProviderError(
          'provider_not_configured',
          `未配置服务端密钥（环境变量 ${config.keyEnv || 'LEADS_WATER_API_KEY'}）。不会生成假结果。`,
          503
        );
      }
      const system = [
        '你是跨业务用户研究设计助手。只输出 JSON，不要解释。',
        '用户只给了一个研究问题，业务背景可选。请自动草拟：业务档案摘要、主要人群（primary）、意见人群（opinion）及是否可重叠、每类人群的入选/排除标准、证据强弱假设、渠道与精准关键词。',
        '真实研究不得自动锁定；你只是草稿，等待用户确认或修改“研究谁”。',
        '不要声称已搜索、已抓取或已有证据；leads 不在这里生成。',
        '最多提出一个真正会改变研究设计的 context_gap；若背景足够可为 null。',
        '输出 JSON 字段：business{name,description,problem,decision_purpose,value_user[],value_payer[]}；audiences[{label,type:"primary"|"opinion",overlap,inclusion[],exclusion[],evidence_strength:"low"|"medium"|"high",rationale}]；criteria{inclusion[],exclusion[]}；channels[]；keywords[]；evidence_strength{level,rationale,gaps[]}；assumptions[{text,basis}]；limitations[]；context_gap{question,why}|null。',
      ].join('\n');
      const user = JSON.stringify({
        question,
        background: background || '',
        output_schema: {
          business: { name: 'string', description: 'string', problem: 'string', decision_purpose: 'string', value_user: ['string'], value_payer: ['string'] },
          audiences: [{ label: 'string', type: 'primary|opinion', overlap: true, inclusion: ['string'], exclusion: ['string'], evidence_strength: 'low|medium|high', rationale: 'string' }],
          criteria: { inclusion: ['string'], exclusion: ['string'] },
          channels: ['string'],
          keywords: ['string'],
          evidence_strength: { level: 'low|medium|high', rationale: 'string', gaps: ['string'] },
          assumptions: [{ text: 'string', basis: 'string' }],
          limitations: ['string'],
          context_gap: { question: 'string', why: 'string' },
        },
      });
      const text = await callChat(config, fetchImpl, system, user);
      return parseJsonObject(text);
    },
  };
}

async function callChat(config, fetchImpl, system, user) {
  if (typeof fetchImpl !== 'function') throw new ProviderError('provider_unavailable', '运行时缺少 fetch', 503);
  const url = `${config.baseUrl}/chat/completions`;
  const body = JSON.stringify({
    model: config.model,
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: user },
    ],
    temperature: 0.2,
    stream: false,
    response_format: { type: 'json_object' },
  });
  let lastError = '';
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 60000);
    try {
      const response = await fetchImpl(url, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${config.key}`,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body,
        signal: controller.signal,
      });
      const text = await response.text();
      if (!response.ok) {
        lastError = `HTTP ${response.status}: ${text.slice(0, 300)}`;
        if (response.status === 401 || response.status === 403) break;
        if (response.status >= 500 && attempt === 0) continue;
        break;
      }
      const payload = JSON.parse(text);
      const content = payload && payload.choices && payload.choices[0] && payload.choices[0].message && payload.choices[0].message.content;
      if (!content) throw new ProviderError('provider_bad_output', '模型返回为空', 502);
      return String(content);
    } catch (err) {
      if (err instanceof ProviderError) throw err;
      lastError = err && err.message ? err.message : String(err);
      if (attempt === 0) continue;
    } finally {
      clearTimeout(timer);
    }
  }
  throw new ProviderError('provider_failed', `模型调用失败：${lastError || '未知错误'}`, 502);
}

function parseJsonObject(text) {
  const trimmed = String(text || '').trim();
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1] : trimmed;
  const start = candidate.indexOf('{');
  const end = candidate.lastIndexOf('}');
  if (start < 0 || end <= start) throw new ProviderError('provider_bad_output', '模型未返回 JSON 对象', 502);
  try {
    return JSON.parse(candidate.slice(start, end + 1));
  } catch {
    throw new ProviderError('provider_bad_output', '模型 JSON 无法解析', 502);
  }
}

module.exports = { ProviderError, readProviderConfig, createProvider, fixtureProvider, buildFixtureItems, openAiCompatibleProvider };
