'use strict';

const fs = require('fs');
const path = require('path');
const { AppError, cleanText, sha256, canonicalUrl, sourceDomain, nowIso, uniqueStrings } = require('./util');
const { safeFetchText, USER_AGENT } = require('./safe_http');
const { isAllowedByRobots } = require('./robots');

const DEFAULT_BUDGET = { maxRequests: 8, maxResults: 20, timeoutMs: 20000 };
const DEFAULT_COOLDOWN_MIN = 15;
const CHANNELS = [
  { id: 'hackernews', label: 'Hacker News 评论（论坛）', kind: 'forum' },
  { id: 'stackexchange', label: 'Stack Exchange（问答/垂直）', kind: 'qa' },
  { id: 'rss', label: '公开 RSS/Atom（创作者/垂直）', kind: 'feed' },
];
const MAX_TERM_LENGTH = 80;

function readSearchConfig(env = process.env) {
  const raw = String(env.LEADS_WATER_SEARCH || 'live').toLowerCase();
  const mode = ['off', 'live'].includes(raw) ? raw : 'live';
  const feeds = String(env.LEADS_WATER_RSS_FEEDS || '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => /^https?:\/\//i.test(s));
  const num = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : d);
  return {
    mode,
    feeds,
    allowBenchmark: String(env.LEADS_WATER_SEARCH_ALLOW_BENCHMARK || '') === '1',
    budget: {
      maxRequests: num(env.LEADS_WATER_SEARCH_MAX_REQUESTS, DEFAULT_BUDGET.maxRequests),
      maxResults: num(env.LEADS_WATER_SEARCH_MAX_RESULTS, DEFAULT_BUDGET.maxResults),
      timeoutMs: num(env.LEADS_WATER_SEARCH_TIMEOUT_MS, DEFAULT_BUDGET.timeoutMs),
    },
    cooldownMinutes: num(env.LEADS_WATER_SEARCH_COOLDOWN_MIN, DEFAULT_COOLDOWN_MIN),
  };
}

function statePath(dataDir) {
  return path.join(dataDir, 'search_state.json');
}

function readState(file) {
  try {
    const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
    return obj && typeof obj === 'object' ? obj : {};
  } catch {
    return {};
  }
}

function writeState(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

function activeCooldown(state, channel, now) {
  const c = state[channel];
  if (!c || !c.until) return null;
  const until = new Date(c.until);
  if (Number.isNaN(until.getTime()) || until <= now) return null;
  return { until: c.until, reason: c.reason || 'cooldown', set_at: c.set_at || null };
}

function setCooldown(file, channel, minutes, reason, now) {
  const state = readState(file);
  const until = new Date(now.getTime() + minutes * 60000).toISOString();
  state[channel] = { until, reason, set_at: now.toISOString() };
  writeState(file, state);
  return { until, reason };
}

function decodeEntities(s) {
  return String(s || '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}

function stripHtml(s) {
  return decodeEntities(String(s || '').replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function sentenceWith(text, term) {
  const body = cleanText(text);
  const t = cleanText(term).toLowerCase();
  if (!body || !t) return '';
  const lower = body.toLowerCase();
  let i = lower.indexOf(t);
  if (i < 0) {
    const tokens = t.split(/[^\p{L}\p{N}]+/u).filter((x) => x.length >= 4 || /[\u4e00-\u9fff]/.test(x));
    for (const token of tokens) {
      i = lower.indexOf(token);
      if (i >= 0) break;
    }
  }
  if (i < 0) return '';
  const start = Math.max(0, body.lastIndexOf('。', i) + 1, body.lastIndexOf('.', i) + 1, body.lastIndexOf('！', i) + 1, body.lastIndexOf('？', i) + 1, body.lastIndexOf('\n', i) + 1);
  const ends = [body.indexOf('。', i), body.indexOf('.', i), body.indexOf('！', i), body.indexOf('？', i), body.indexOf('\n', i)].filter((x) => x >= 0);
  const end = ends.length ? Math.min(...ends) + 1 : Math.min(body.length, i + 220);
  const q = body.slice(start, Math.min(end, start + 320)).trim();
  return q.length >= 12 ? q : body.slice(Math.max(0, i - 80), Math.min(body.length, i + 180)).trim();
}

function normalizeTermRows(keywords) {
  const rows = [];
  for (const k of Array.isArray(keywords) ? keywords : []) {
    if (typeof k === 'string') {
      const term = cleanText(k).slice(0, MAX_TERM_LENGTH);
      if (term) rows.push({ term, intent: '', audience: '', audience_id: '' });
    } else if (k && typeof k === 'object') {
      const term = cleanText(k.term || k.keyword).slice(0, MAX_TERM_LENGTH);
      if (term) rows.push({ term, intent: cleanText(k.intent), audience: cleanText(k.audience), audience_id: cleanText(k.audience_id) });
    }
  }
  const seen = new Set();
  return rows.filter((r) => {
    const key = r.term.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).slice(0, 8);
}

async function fetchText(fetchImpl, url, opts) {
  const out = await fetchImpl(url, { timeoutMs: opts.timeoutMs, signal: opts.signal, headers: { 'user-agent': USER_AGENT } });
  if (typeof out === 'string') return out;
  if (out && typeof out === 'object') {
    if (out.status && (out.status < 200 || out.status >= 300)) {
      const e = new Error(out.message || `HTTP ${out.status}`);
      e.status = out.status;
      throw e;
    }
    return String(out.body || out.text || '');
  }
  return String(out || '');
}

function parseRss(xml) {
  const items = [];
  const re = /<(item|entry)\b[^>]*>([\s\S]*?)<\/\1>/gi;
  let m;
  while ((m = re.exec(String(xml || '')))) {
    const block = m[2];
    const get = (tag) => {
      const r = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'i').exec(block);
      return r ? decodeEntities(r[1].replace(/^<!\[CDATA\[|\]\]>$/g, '').trim()) : '';
    };
    let link = get('link');
    if (!link) {
      let fallback = '';
      for (const hm of block.matchAll(/<link\b([^>]*)\/?>/gi)) {
        const href = /href=["']([^"']+)["']/i.exec(hm[1]);
        if (!href) continue;
        if (!fallback) fallback = href[1];
        const rel = /rel=["']([^"']+)["']/i.exec(hm[1]);
        if (!rel || rel[1].toLowerCase() === 'alternate') {
          link = decodeEntities(href[1]);
          break;
        }
      }
      if (!link && fallback) link = decodeEntities(fallback);
    }
    const title = stripHtml(get('title'));
    const body = get('content:encoded') || get('content') || get('description') || get('summary');
    const published = get('pubDate') || get('published') || get('updated') || '';
    if (link && title) items.push({ title, url: link, text: stripHtml(body), published_at: published });
  }
  return items;
}

function adapterFor(channel, config, fetchImpl) {
  if (channel === 'hackernews') {
    return {
      build: (term) => `https://hn.algolia.com/api/v1/search?query=${encodeURIComponent(term)}&tags=comment&hitsPerPage=5`,
      parse: (text) => {
        const j = JSON.parse(text);
        return (j.hits || []).map((h) => ({
          title: h.story_title ? `Re: ${h.story_title}` : (h.title || ''),
          url: h.url || (h.objectID ? `https://news.ycombinator.com/item?id=${h.objectID}` : ''),
          text: stripHtml(h.comment_text || ''),
          published_at: h.created_at || '',
          channel: 'hackernews',
          provider: 'hn_algolia',
          original: Boolean(h.comment_text),
        }));
      },
    };
  }
  if (channel === 'stackexchange') {
    return {
      build: (term) => `https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q=${encodeURIComponent(term)}&site=stackoverflow&pagesize=5&filter=withbody`,
      parse: (text) => {
        const j = JSON.parse(text);
        return (j.items || []).map((it) => ({
          title: decodeEntities(it.title || ''),
          url: it.link || '',
          text: stripHtml(it.body || ''),
          published_at: it.creation_date ? new Date(it.creation_date * 1000).toISOString() : '',
          channel: 'stackexchange',
          provider: 'stackexchange',
          original: Boolean(it.body),
        }));
      },
    };
  }
  if (channel === 'rss') {
    return {
      feeds: config.feeds,
      parse: (text, feedUrl) => parseRss(text).map((it) => ({
        title: it.title,
        url: it.url,
        text: it.text,
        published_at: it.published_at,
        channel: 'rss',
        provider: sourceDomain(feedUrl),
        original: Boolean(it.text),
      })),
    };
  }
  return null;
}

function createSearchProvider(config = readSearchConfig(process.env), opts = {}) {
  const mode = config.mode || 'live';
  const dataDir = opts.dataDir || path.join(__dirname, '..', 'data');
  const baseFetch = opts.fetchImpl || safeFetchText;
  const fetchImpl = (url, o = {}) => baseFetch(url, { ...o, allowBenchmark: Boolean(config.allowBenchmark) });
  const robotsImpl = opts.robotsImpl || ((url) => isAllowedByRobots(url, { fetchImpl }));
  const now = opts.now || (() => new Date());
  const checkRobots = opts.checkRobots !== false;
  const file = statePath(dataDir);

  async function runOne(channel, term, row, ctx) {
    const adapter = adapterFor(channel, config, fetchImpl);
    if (!adapter) return [];
    const targets = channel === 'rss'
      ? adapter.feeds.map((f) => ({ url: f, key: term, rss: true }))
      : [{ url: adapter.build(term), key: term }];
    const out = [];
    for (const target of targets) {
      if (ctx.budgetUsed >= ctx.maxRequests) { ctx.budgetExhausted = true; break; }
      if (ctx.signal && ctx.signal.aborted) { ctx.cancelled = true; break; }
      if (checkRobots) {
        const r = await robotsImpl(target.url).catch(() => ({ allowed: false, reason: 'robots_unavailable' }));
        if (!r.allowed) {
          ctx.errors.push({ channel, keyword: term, code: 'robots_disallowed', message: `robots 不允许：${r.reason || ''}` });
          return out;
        }
      }
      ctx.budgetUsed += 1;
      ctx.channelRequests[channel] = (ctx.channelRequests[channel] || 0) + 1;
      try {
        const text = await fetchText(fetchImpl, target.url, { timeoutMs: Math.min(ctx.timeoutMs, 10000), signal: ctx.signal });
        const items = channel === 'rss' ? adapter.parse(text, target.url) : adapter.parse(text);
        for (const it of items) {
          if (!it.url) continue;
          const full = cleanText(it.text || '');
          const termLower = term.toLowerCase();
          if (channel === 'rss' && full && !full.toLowerCase().includes(termLower)) continue;
          const quote = full ? sentenceWith(full, term) : '';
          const verified = Boolean(it.original && quote && full.includes(quote));
          out.push({
            keyword: term,
            intent: row.intent || '',
            audience: row.audience || '',
            title: cleanText(it.title).slice(0, 300),
            url: it.url,
            canonical_url: canonicalUrl(it.url),
            source_domain: sourceDomain(it.url),
            channel,
            provider: it.provider || channel,
            published_at: it.published_at || '',
            text: full.slice(0, 8000),
            quote,
            quote_start: quote ? full.indexOf(quote) : null,
            quote_end: quote ? full.indexOf(quote) + quote.length : null,
            verified,
            retrieval: verified ? 'live' : 'none',
            source_type: verified ? 'verified' : 'ai_candidate',
            note: verified ? '经实时检索并在原文中核对引用' : (it.original ? '检索到原文但未找到可核对引用' : '只有标题/检索摘要，未核对原文'),
          });
        }
      } catch (e) {
        ctx.channelErrors[channel] = { code: e.code || 'channel_failed', message: e.message || '渠道失败', status: e.status || 0 };
        ctx.errors.push({ channel, keyword: term, code: e.code || 'channel_failed', message: e.message || '渠道失败' });
        const cooldownWorthy = e.code === 'network_error' || e.code === 'timeout' || (e.code === 'http_error' && (e.status === 429 || e.status >= 500));
        if (cooldownWorthy && (!ctx.signal || !ctx.signal.aborted)) {
          const cd = setCooldown(file, channel, config.cooldownMinutes || DEFAULT_COOLDOWN_MIN, e.code || 'channel_failed', now());
          ctx.cooldowns[channel] = cd;
        }
        return out;
      }
    }
    return out;
  }

  async function search({ keywords, signal } = {}) {
    if (mode === 'off') throw new AppError('search_not_configured', '未配置真实检索 provider', 503);
    const rows = normalizeTermRows(keywords);
    if (!rows.length) throw new AppError('missing_keywords', '请至少选择一个关键词后再搜索', 400);
    const state = readState(file);
    const ctx = {
      budgetUsed: 0,
      maxRequests: (config.budget && config.budget.maxRequests) || DEFAULT_BUDGET.maxRequests,
      maxResults: (config.budget && config.budget.maxResults) || DEFAULT_BUDGET.maxResults,
      timeoutMs: (config.budget && config.budget.timeoutMs) || DEFAULT_BUDGET.timeoutMs,
      signal,
      errors: [],
      channelErrors: {},
      channelRequests: {},
      cooldowns: {},
      cancelled: false,
      budgetExhausted: false,
    };
    const channelStats = {};
    for (const ch of CHANNELS) {
      const cd = activeCooldown(state, ch.id, now());
      channelStats[ch.id] = { id: ch.id, label: ch.label, state: cd ? 'cooldown' : (ch.id === 'rss' && !config.feeds.length ? 'unconfigured' : 'ready'), requests: 0, results: 0, error: null, cooldown: cd };
    }
    const raw = [];
    const started = Date.now();
    for (const row of rows) {
      for (const ch of CHANNELS) {
        const st = channelStats[ch.id];
        if (st.state === 'cooldown' || st.state === 'unconfigured') continue;
        if (ctx.cancelled || (signal && signal.aborted) || ctx.budgetExhausted || Date.now() - started > ctx.timeoutMs) {
          if (Date.now() - started > ctx.timeoutMs) ctx.timedOut = true;
          break;
        }
        const items = await runOne(ch.id, row.term, row, ctx);
        st.requests = ctx.channelRequests[ch.id] || 0;
        st.results += items.length;
        raw.push(...items);
      }
      if (ctx.cancelled || ctx.budgetExhausted) break;
    }
    for (const [id, err] of Object.entries(ctx.channelErrors)) {
      if (channelStats[id]) { channelStats[id].state = ctx.signal && ctx.signal.aborted ? 'cancelled' : 'failed'; channelStats[id].error = err; }
    }
    const seen = new Set();
    const results = [];
    let dup = 0;
    for (const r of raw) {
      const key = `${r.canonical_url || r.url}|${sha256(r.text || r.title).slice(0, 16)}`;
      if (seen.has(key)) { dup += 1; continue; }
      seen.add(key);
      if (results.length >= ctx.maxResults) break;
      results.push(r);
    }
    const verified = results.filter((r) => r.verified);
    return {
      ok: true,
      explicit: true,
      auto_search: false,
      provider: 'live_public_search',
      searched_at: nowIso(),
      keywords: rows.map((r) => r.term),
      results,
      verified_count: verified.length,
      unverified_count: results.length - verified.length,
      duplicate_count: dup,
      channels: Object.values(channelStats),
      errors: ctx.errors,
      budget: { used: ctx.budgetUsed, max_requests: ctx.maxRequests, max_results: ctx.maxResults, timeout_ms: ctx.timeoutMs },
      cancelled: Boolean(ctx.cancelled || (signal && signal.aborted)),
      timed_out: Boolean(ctx.timedOut || (Date.now() - started > ctx.timeoutMs)),
      cooldowns: ctx.cooldowns,
      blind_spots: [
        '只在用户显式选择关键词后检索；未做自动广搜',
        'Hacker News 与 Stack Exchange 为公开 API，覆盖英文技术/商业讨论；中文创作者需配置官方 RSS',
        '标题/摘要不算证据；只有原文逐字引用才标已验证',
        '独立线索按 canonical URL + 原文去重，不代表市场触达',
      ],
    };
  }

  return { search, info: () => ({ mode, channels: CHANNELS.map((c) => c.id), configured: mode !== 'off', feeds: config.feeds.length }) };
}

module.exports = { readSearchConfig, createSearchProvider, parseRss, stripHtml, sentenceWith, normalizeTermRows, statePath };
