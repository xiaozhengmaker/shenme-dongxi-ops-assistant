'use strict';

const crypto = require('crypto');
const path = require('path');

class AppError extends Error {
  constructor(code, message, status = 400, details) {
    super(message || code);
    this.name = 'AppError';
    this.code = code;
    this.status = status;
    this.details = details || null;
  }
}

function nowIso() {
  return new Date().toISOString();
}

function cleanText(value, max = 20000) {
  if (value === null || value === undefined) return '';
  return String(value).replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim().slice(0, max);
}

function asArray(value) {
  if (Array.isArray(value)) return value.map((v) => cleanText(v, 200)).filter(Boolean);
  if (typeof value === 'string') {
    return value.split(/\n|,|，|;/).map((v) => cleanText(v, 200)).filter(Boolean);
  }
  return [];
}

function uniqueStrings(list) {
  const seen = new Set();
  const out = [];
  for (const raw of list || []) {
    const value = cleanText(raw, 200);
    const key = value.toLowerCase();
    if (!value || seen.has(key)) continue;
    seen.add(key);
    out.push(value);
  }
  return out;
}

function sha256(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

function randomId(prefix) {
  return `${prefix}-${crypto.randomBytes(6).toString('hex')}`;
}

function canonicalUrl(raw) {
  const value = cleanText(raw, 2000);
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new AppError('invalid_url', 'URL 无法解析，必须是 http(s) 绝对地址');
  }
  if (!/^https?:$/.test(parsed.protocol)) {
    throw new AppError('invalid_url', 'URL 仅支持 http/https');
  }
  parsed.hash = '';
  const drop = [];
  for (const key of parsed.searchParams.keys()) {
    if (/^(utm_|fbclid$|gclid$|yclid$|mc_cid$|mc_eid$|ref$)/i.test(key)) drop.push(key);
  }
  for (const key of drop) parsed.searchParams.delete(key);
  parsed.searchParams.sort();
  let pathname = parsed.pathname.replace(/\/{2,}/g, '/');
  if (pathname.length > 1) pathname = pathname.replace(/\/$/, '');
  parsed.pathname = pathname;
  const host = parsed.hostname.toLowerCase().replace(/^www\./, '');
  return `${parsed.protocol}//${host}${parsed.port ? ':' + parsed.port : ''}${parsed.pathname}${parsed.search}`;
}

function sourceDomain(canonical) {
  try {
    return new URL(canonical).hostname.toLowerCase().replace(/^www\./, '');
  } catch {
    return '';
  }
}

function normalizeForCompare(text) {
  return cleanText(text, 100000)
    .toLowerCase()
    .replace(/[\u0000-\u001f]/g, ' ')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function tokens(text) {
  const norm = normalizeForCompare(text);
  if (!norm) return new Set();
  return new Set(norm.split(' ').filter((t) => t.length > 1));
}

function jaccard(aText, bText) {
  const a = tokens(aText);
  const b = tokens(bText);
  if (!a.size || !b.size) return 0;
  let inter = 0;
  for (const t of a) if (b.has(t)) inter += 1;
  return inter / (a.size + b.size - inter);
}

function assertPlainId(value) {
  if (typeof value !== 'string' || !/^[a-z0-9][a-z0-9-]{5,47}$/.test(value)) {
    throw new AppError('invalid_id', '档案 ID 非法');
  }
  return value;
}

function safeJoin(base, child) {
  const resolved = path.resolve(base, child);
  const root = path.resolve(base) + path.sep;
  if (resolved !== path.resolve(base) && !resolved.startsWith(root)) {
    throw new AppError('invalid_path', '路径越界');
  }
  return resolved;
}

module.exports = {
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
  assertPlainId,
  safeJoin,
};
