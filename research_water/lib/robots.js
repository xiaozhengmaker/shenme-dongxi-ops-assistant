'use strict';

const { safeFetchText } = require('./safe_http');

const cache = new Map();

function parseRobots(text) {
  const groups = [];
  let current = null;
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) continue;
    const i = line.indexOf(':');
    if (i < 0) continue;
    const key = line.slice(0, i).trim().toLowerCase();
    const value = line.slice(i + 1).trim();
    if (key === 'user-agent') {
      if (!current || current.rules.length) {
        current = { agents: [], rules: [] };
        groups.push(current);
      }
      current.agents.push(value.toLowerCase());
    } else if (key === 'allow' || key === 'disallow') {
      if (!current) {
        current = { agents: ['*'], rules: [] };
        groups.push(current);
      }
      current.rules.push({ allow: key === 'allow', path: value });
    }
  }
  return groups;
}

function pathAllowed(robotsText, pathname) {
  const groups = parseRobots(robotsText).filter((g) => g.agents.includes('*'));
  const rules = groups.flatMap((g) => g.rules).filter((r) => r.path);
  let best = null;
  for (const r of rules) {
    if (pathname.startsWith(r.path)) {
      const score = r.path.length;
      if (!best || score > best.score || (score === best.score && r.allow)) best = { score, allow: r.allow };
    }
  }
  return best ? best.allow : true;
}

async function isAllowedByRobots(rawUrl, opts = {}) {
  const u = new URL(rawUrl);
  const origin = u.origin;
  if (!cache.has(origin)) {
    const p = (async () => {
      try {
        const text = await (opts.fetchImpl || safeFetchText)(`${origin}/robots.txt`, { timeoutMs: 5000 });
        return { text, allowed: true };
      } catch (e) {
        if (e && e.status === 403) return { text: '', allowed: false, reason: 'robots_forbidden' };
        if (e && e.status === 401) return { text: '', allowed: false, reason: 'robots_unauthorized' };
        return { text: '', allowed: true, reason: 'robots_unavailable' };
      }
    })();
    cache.set(origin, p);
  }
  const r = await cache.get(origin);
  if (!r.allowed) return { allowed: false, reason: r.reason };
  return { allowed: pathAllowed(r.text, u.pathname + u.search), reason: 'robots' };
}

function clearRobotsCache() {
  cache.clear();
}

module.exports = { parseRobots, pathAllowed, isAllowedByRobots, clearRobotsCache };
