'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');
const { Store } = require('./lib/store');
const { AppError, nowIso, cleanText } = require('./lib/util');
const { readProviderConfig, createProvider } = require('./lib/provider');
const pipeline = require('./lib/pipeline');
const answer = require('./lib/answer');
const research = require('./lib/research');
const studio = require('./lib/studio');
const search = require('./lib/search');

const PUBLIC_DIR = path.join(__dirname, 'public');
const MAX_BODY = 1024 * 1024;

function createApp(options = {}) {
  const dataDir = path.resolve(options.dataDir || process.env.LEADS_WATER_DATA || path.join(__dirname, 'data'));
  const store = new Store(dataDir);
  const researchStore = new research.ResearchStore(dataDir);
  const providerConfig = options.providerConfig || readProviderConfig(process.env);
  const provider = options.provider || createProvider(providerConfig, { fetchImpl: options.fetchImpl });
  const searchConfig = options.searchConfig || search.readSearchConfig(process.env);
  const searchProvider = options.searchProvider || search.createSearchProvider(searchConfig, { dataDir, fetchImpl: options.searchFetchImpl });

  async function handler(req, res) {
    try {
      const url = new URL(req.url, 'http://127.0.0.1');
      if (url.pathname.startsWith('/api/')) {
        await handleApi(req, res, url);
        return;
      }
      serveStatic(req, res, url.pathname);
    } catch (err) {
      const status = err instanceof AppError ? err.status : 500;
      const code = err instanceof AppError ? err.code : 'internal_error';
      const message = err instanceof AppError ? err.message : '服务内部错误';
      if (!res.headersSent) sendJson(res, status, { ok: false, error: code, message, details: err.details || null });
      else res.end();
    }
  }

  async function handleApi(req, res, url) {
    const parts = url.pathname.split('/').filter(Boolean); // api, ...
    if (req.method === 'GET' && url.pathname === '/api/health') {
      return sendJson(res, 200, {
        ok: true,
        time: nowIso(),
        provider: provider.info(),
        storage: 'json',
        auto_search: false,
        manual_import: true,
        calibration_samples: true,
        max_calibration_samples: 8,
        question_only: true,
        answer: true,
        quick_research: true,
        keyword_studio: true,
        verified_requires_live: true,
        live_search: searchProvider.info(),
      });
    }
    if (req.method === 'GET' && url.pathname === '/api/capabilities') {
      return sendJson(res, 200, {
        ok: true,
        method: ['描述', '人群假设', '小样本校准', '显式确认锁定', '证据导入', '证据驱动报告'],
        auto_search: false,
        manual_import: true,
        search_scope_optional: true,
        existing_evidence_optional: true,
        calibration_samples: true,
        max_calibration_samples: 8,
        question_only: true,
        answer: true,
        quick_research: true,
        keyword_studio: true,
        verified_requires_live: true,
        live_search: true,
        live_search_info: searchProvider.info(),
        note: '一句话理解业务与问题，确认后看关键词工作台；仅在你勾选关键词并点击真实搜索后联网，自动搜索不会自行启动。',
        provider: provider.info(),
      });
    }
    if (req.method === 'GET' && url.pathname === '/api/studio/demo') {
      const workbench = studio.demoWorkbench();
      return sendJson(res, 200, {
        ok: true,
        demo: true,
        understanding: workbench.understanding,
        workbench,
        confirmation: { required: false, audience_signature: workbench.understanding.audience_signature, first_time: false },
      });
    }
    if (req.method === 'POST' && url.pathname === '/api/studio/understand') {
      const body = await readJson(req);
      const result = await studio.understand({
        sentence: body && body.sentence,
        profileId: body && body.profile_id,
        store,
        provider,
        researchLib: research,
      });
      const confirmation = studio.confirmation(result.understanding, body && body.confirmed_signature);
      return sendJson(res, 200, { ok: true, ...result, confirmation });
    }
    if (req.method === 'POST' && url.pathname === '/api/studio/keywords') {
      const body = await readJson(req);
      let understanding = body && body.understanding;
      let matchedProfile = null;
      if (!understanding) {
        const result = await studio.understand({
          sentence: body && body.sentence,
          profileId: body && body.profile_id,
          store,
          provider,
          researchLib: research,
        });
        understanding = result.understanding;
        matchedProfile = result.matched_profile;
      }
      const confirmation = studio.confirmation(understanding, body && body.confirmed_signature);
      if (confirmation.required && !(body && body.user_confirmed === true)) {
        throw new AppError('confirmation_required', '请先确认理解摘要（首次或人群变化时）', 409, {
          understanding,
          confirmation,
        });
      }
      let profile = understanding.profile_id ? store.get(understanding.profile_id) : null;
      const workbench = studio.buildWorkbench({
        sentence: (body && body.sentence) || understanding.sentence,
        understanding,
        profile,
        providerInfo: provider.info(),
        demo: false,
      });
      return sendJson(res, 200, {
        ok: true,
        understanding: workbench.understanding,
        matched_profile: matchedProfile,
        workbench,
        confirmation: { required: false, audience_signature: confirmation.audience_signature, first_time: false },
      });
    }
    if (req.method === 'POST' && url.pathname === '/api/studio/search') {
      const body = await readJson(req);
      const controller = new AbortController();
      let finished = false;
      res.on('close', () => { if (!finished) controller.abort(); });
      try {
        const result = await searchProvider.search({ keywords: body && body.keywords, signal: controller.signal });
        finished = true;
        return sendJson(res, 200, result);
      } catch (err) {
        finished = true;
        throw err;
      }
    }
    if (req.method === 'POST' && url.pathname === '/api/studio/export') {
      const body = await readJson(req);
      const understanding = body && body.understanding;
      if (!understanding) throw new AppError('missing_understanding', '缺少理解摘要', 400);
      let profile = null;
      if (understanding.profile_id) profile = store.get(understanding.profile_id);
      const result = studio.exportKeywords({
        understanding,
        keywords: (body && body.keywords) || [],
        profile,
      });
      return sendJson(res, 200, result);
    }
    if (req.method === 'GET' && url.pathname === '/api/research/profiles') {
      return sendJson(res, 200, { ok: true, items: answer.listResearchProfiles(store) });
    }
    if (req.method === 'POST' && url.pathname === '/api/answer') {
      const body = await readJson(req);
      const result = await answer.answerQuestion({
        store,
        provider,
        question: body && body.question,
        profileId: body && body.profile_id,
      });
      return sendJson(res, 200, { ok: true, ...result });
    }
    if (req.method === 'POST' && url.pathname === '/api/research/draft') {
      const body = await readJson(req);
      const result = await research.draftResearch({
        provider,
        question: body && body.question,
        background: body && body.background,
      });
      return sendJson(res, 200, { ok: true, ...result });
    }
    if (req.method === 'POST' && url.pathname === '/api/research/confirm') {
      const body = await readJson(req);
      const brief = research.saveBrief(researchStore, {
        question: body && body.question,
        background: body && body.background,
        draft: body && body.draft,
        providerInfo: provider.info(),
      });
      return sendJson(res, 201, { ok: true, brief: research.briefView(brief) });
    }
    if (req.method === 'GET' && url.pathname === '/api/research/briefs') {
      return sendJson(res, 200, { ok: true, items: researchStore.list() });
    }
    if (parts[0] === 'api' && parts[1] === 'research' && parts[2] === 'briefs' && parts[3] && req.method === 'GET') {
      const brief = researchStore.get(parts[3]);
      return sendJson(res, 200, { ok: true, brief: research.briefView(brief) });
    }
    if (url.pathname === '/api/profiles') {
      if (req.method === 'GET') return sendJson(res, 200, { ok: true, items: store.list() });
      if (req.method === 'POST') {
        const body = await readJson(req);
        const profile = pipeline.createProfile(store, body);
        return sendJson(res, 201, { ok: true, profile: pipeline.profileView(profile) });
      }
      throw new AppError('method_not_allowed', '方法不允许', 405);
    }

    if (parts[0] === 'api' && parts[1] === 'profiles' && parts[2]) {
      const id = parts[2];
      if (parts.length === 3 && req.method === 'GET') {
        const profile = store.get(id);
        return sendJson(res, 200, { ok: true, profile: pipeline.profileView(profile) });
      }
      if (parts.length === 4 && parts[3] === 'calibration-samples' && req.method === 'POST') {
        const body = await readJson(req);
        const result = pipeline.addCalibrationSample(store, id, body);
        return sendJson(res, 201, {
          ok: true,
          sample: result.sample,
          profile: pipeline.profileView(result.profile),
        });
      }
      if (parts.length === 4 && parts[3] === 'calibrate' && req.method === 'POST') {
        const profile = await pipeline.calibrate(store, id, provider);
        return sendJson(res, 200, { ok: true, profile: pipeline.profileView(profile) });
      }
      if (parts.length === 6 && parts[3] === 'calibration' && parts[4] === 'items' && req.method === 'PATCH') {
        const body = await readJson(req);
        const profile = pipeline.updateCalibrationItem(store, id, parts[5], body);
        return sendJson(res, 200, { ok: true, profile: pipeline.profileView(profile) });
      }
      if (parts.length === 4 && parts[3] === 'confirm' && req.method === 'POST') {
        const body = await readJson(req);
        const profile = pipeline.confirmCalibration(store, id, body);
        return sendJson(res, 200, { ok: true, profile: pipeline.profileView(profile) });
      }
      if (parts.length === 4 && parts[3] === 'evidence' && req.method === 'POST') {
        const body = await readJson(req);
        const result = pipeline.importEvidence(store, id, body);
        return sendJson(res, result.accepted ? 201 : 200, {
          ok: true,
          accepted: result.accepted,
          duplicate: result.duplicate,
          duplicate_of: result.duplicate_of || null,
          kind: result.kind || null,
          message: result.message || null,
          profile: pipeline.profileView(result.profile),
        });
      }
      if (parts.length === 4 && parts[3] === 'report' && req.method === 'POST') {
        const report = pipeline.buildReport(store, id);
        const profile = store.get(id);
        return sendJson(res, 200, { ok: true, report, profile: pipeline.profileView(profile) });
      }
      if (parts.length === 4 && parts[3] === 'report' && req.method === 'GET') {
        const profile = store.get(id);
        if (!profile.report) throw new AppError('report_not_found', '尚未生成报告', 404);
        return sendJson(res, 200, { ok: true, report: profile.report });
      }
      if (parts.length === 3 && req.method === 'PATCH') {
        throw new AppError('guidance_locked', 'v1 不支持修改引导字段；请在创建前确认，或新建档案', 409);
      }
    }
    throw new AppError('not_found', '接口不存在', 404);
  }

  function serveStatic(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD') throw new AppError('method_not_allowed', '方法不允许', 405);
    let rel;
    if (pathname === '/' || pathname === '/index.html') rel = 'index.html';
    else if (pathname === '/app.js') rel = 'app.js';
    else if (pathname === '/style.css') rel = 'style.css';
    else if (pathname === '/favicon.ico') {
      res.statusCode = 204;
      res.end();
      return;
    } else throw new AppError('not_found', '页面不存在', 404);
    const file = path.join(PUBLIC_DIR, rel);
    if (!fs.existsSync(file)) throw new AppError('not_found', '静态文件不存在', 404);
    const type = rel.endsWith('.js')
      ? 'text/javascript; charset=utf-8'
      : rel.endsWith('.css')
        ? 'text/css; charset=utf-8'
        : 'text/html; charset=utf-8';
    res.statusCode = 200;
    res.setHeader('Content-Type', type);
    res.setHeader('Cache-Control', 'no-store');
    if (req.method === 'HEAD') return res.end();
    res.end(fs.readFileSync(file));
  }

  return { handler, store, provider, search: searchProvider, dataDir, providerConfig };
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new AppError('body_too_large', '请求体过大', 413));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve(JSON.parse(text));
      } catch {
        reject(new AppError('invalid_json', '请求体不是合法 JSON'));
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(body);
}

function startServer(options = {}) {
  const app = createApp(options);
  const server = http.createServer(app.handler);
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port !== undefined ? options.port : 0, options.host || '127.0.0.1', () => {
      const address = server.address();
      const host = options.host || '127.0.0.1';
      resolve({
        ...app,
        server,
        host,
        port: address.port,
        url: `http://${host}:${address.port}`,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const argMap = {};
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg.startsWith('--')) {
      const [key, value] = arg.slice(2).split('=');
      argMap[key] = value !== undefined ? value : args[i + 1];
      if (value === undefined) i += 1;
    }
  }
  const port = Number(argMap.port || process.env.LEADS_WATER_PORT || 8799);
  const dataDir = argMap.data || process.env.LEADS_WATER_DATA || path.join(__dirname, 'data');
  const providerMode = argMap.provider || process.env.LEADS_WATER_PROVIDER;
  if (providerMode) process.env.LEADS_WATER_PROVIDER = providerMode;
  const searchMode = argMap.search || process.env.LEADS_WATER_SEARCH;
  if (searchMode) process.env.LEADS_WATER_SEARCH = searchMode;
  const providerConfig = readProviderConfig(process.env);
  startServer({ port, dataDir, providerConfig })
    .then((app) => {
      const info = app.provider.info();
      console.log(`[leads-water] ${app.url}`);
      console.log(`[leads-water] data=${app.dataDir}`);
      console.log(`[leads-water] provider=${info.name} configured=${info.configured}${info.reason ? ' reason=' + info.reason : ''}`);
      console.log(`[leads-water] search=${JSON.stringify(app.search.info())}`);
      if (!info.configured) console.log('[leads-water] 校准不可用：未配置服务端密钥；不会生成假结果。');
    })
    .catch((err) => {
      console.error('[leads-water] 启动失败:', err.message);
      process.exitCode = 1;
    });
}

module.exports = { createApp, startServer };
