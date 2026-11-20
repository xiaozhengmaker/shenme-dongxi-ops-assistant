'use strict';

const dns = require('dns');
const http = require('http');
const https = require('https');
const net = require('net');
const { URL } = require('url');

const MAX_REDIRECTS = 3;
const MAX_BYTES = 512 * 1024;
const DEFAULT_TIMEOUT_MS = 10000;
const USER_AGENT = 'Mozilla/5.0 leads-water-research/1.0';

class SafeHttpError extends Error {
  constructor(code, message, status = 0) {
    super(message || code);
    this.name = 'SafeHttpError';
    this.code = code;
    this.status = status;
  }
}

function ipv4ToInt(ip) {
  const p = ip.split('.').map(Number);
  return (((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3]) >>> 0;
}

function inCidr4(ip, base, bits) {
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return (ipv4ToInt(ip) & mask) === (ipv4ToInt(base) & mask);
}

function isPrivateIp(ip) {
  const kind = net.isIP(ip);
  if (kind === 4) {
    return (
      inCidr4(ip, '0.0.0.0', 8) ||
      inCidr4(ip, '10.0.0.0', 8) ||
      inCidr4(ip, '100.64.0.0', 10) ||
      inCidr4(ip, '127.0.0.0', 8) ||
      inCidr4(ip, '169.254.0.0', 16) ||
      inCidr4(ip, '172.16.0.0', 12) ||
      inCidr4(ip, '192.0.0.0', 24) ||
      inCidr4(ip, '192.0.2.0', 24) ||
      inCidr4(ip, '192.168.0.0', 16) ||
      inCidr4(ip, '198.18.0.0', 15) ||
      inCidr4(ip, '198.51.100.0', 24) ||
      inCidr4(ip, '203.0.113.0', 24) ||
      inCidr4(ip, '224.0.0.0', 4) ||
      inCidr4(ip, '240.0.0.0', 4)
    );
  }
  if (kind === 6) {
    const v = ip.toLowerCase();
    if (v === '::' || v === '::1') return true;
    if (v.startsWith('::ffff:')) {
      const mapped = v.slice('::ffff:'.length);
      if (net.isIP(mapped) === 4) return isPrivateIp(mapped);
    }
    return (
      v.startsWith('fc') ||
      v.startsWith('fd') ||
      v.startsWith('fe8') ||
      v.startsWith('fe9') ||
      v.startsWith('fea') ||
      v.startsWith('feb') ||
      v.startsWith('ff')
    );
  }
  return true;
}

function validatePublicUrl(raw) {
  let u;
  try {
    u = new URL(String(raw));
  } catch {
    throw new SafeHttpError('invalid_url', 'URL 无效');
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    throw new SafeHttpError('invalid_protocol', '只允许 http(s) URL');
  }
  if (u.username || u.password) {
    throw new SafeHttpError('url_credentials_forbidden', 'URL 不得包含凭证');
  }
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (!host || host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host === 'metadata.google.internal') {
    throw new SafeHttpError('private_host', '不允许访问本机或内网主机');
  }
  if (net.isIP(host)) {
    if (isPrivateIp(host)) throw new SafeHttpError('private_ip', '不允许访问内网 IP');
  }
  const port = u.port ? Number(u.port) : (u.protocol === 'https:' ? 443 : 80);
  if (![80, 443].includes(port)) throw new SafeHttpError('port_forbidden', '只允许 80/443 端口');
  return u;
}

async function resolvePublic(hostname, opts = {}) {
  let rows;
  try {
    rows = await dns.promises.lookup(hostname, { all: true, verbatim: true });
  } catch (e) {
    throw new SafeHttpError('dns_failed', 'DNS 解析失败');
  }
  if (!rows || !rows.length) throw new SafeHttpError('dns_failed', 'DNS 无结果');
  for (const r of rows) {
    const benchmark = opts.allowBenchmark && net.isIP(r.address) === 4 && inCidr4(r.address, '198.18.0.0', 15);
    if (isPrivateIp(r.address) && !benchmark) throw new SafeHttpError('private_ip', 'DNS 解析到内网地址');
  }
  return rows[0];
}

function decodeBody(buf, contentType) {
  const m = /charset=([^;]+)/i.exec(contentType || '');
  const enc = (m ? m[1] : 'utf8').trim().toLowerCase();
  try {
    return new TextDecoder(enc).decode(buf);
  } catch {
    return buf.toString('utf8');
  }
}

async function safeFetchText(rawUrl, opts = {}) {
  const timeoutMs = Number(opts.timeoutMs) || DEFAULT_TIMEOUT_MS;
  const signal = opts.signal;
  const maxBytes = Number(opts.maxBytes) || MAX_BYTES;
  let current = validatePublicUrl(rawUrl);
  for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
    if (signal && signal.aborted) throw new SafeHttpError('cancelled', '请求已取消');
    const resolved = await resolvePublic(current.hostname.replace(/^\[|\]$/g, ''), { allowBenchmark: opts.allowBenchmark });
    const text = await new Promise((resolve, reject) => {
      const lib = current.protocol === 'https:' ? https : http;
      const req = lib.request(
        {
          protocol: current.protocol,
          hostname: current.hostname,
          port: current.port || (current.protocol === 'https:' ? 443 : 80),
          path: current.pathname + current.search,
          method: 'GET',
          headers: { 'user-agent': USER_AGENT, accept: 'application/json, application/xml, text/xml, text/html;q=0.9, */*;q=0.5' },
          lookup: (host, o, cb) => {
            if (o && o.all) cb(null, [{ address: resolved.address, family: resolved.family }]);
            else cb(null, resolved.address, resolved.family);
          },
          servername: current.protocol === 'https:' ? current.hostname : undefined,
        },
        (res) => {
          const status = res.statusCode || 0;
          if (status >= 300 && status < 400 && res.headers.location) {
            res.resume();
            resolve({ redirect: res.headers.location, status });
            return;
          }
          let size = 0;
          const chunks = [];
          res.on('data', (c) => {
            size += c.length;
            if (size > maxBytes) {
              req.destroy(new SafeHttpError('response_too_large', '响应过大', status));
              return;
            }
            chunks.push(c);
          });
          res.on('end', () => resolve({ status, body: decodeBody(Buffer.concat(chunks), res.headers['content-type']), contentType: res.headers['content-type'] || '' }));
        }
      );
      const timer = setTimeout(() => req.destroy(new SafeHttpError('timeout', '请求超时')), timeoutMs);
      const onAbort = () => req.destroy(new SafeHttpError('cancelled', '请求已取消'));
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      req.on('error', (e) => {
        clearTimeout(timer);
        if (signal) signal.removeEventListener('abort', onAbort);
        reject(e instanceof SafeHttpError ? e : new SafeHttpError('network_error', e.message || '网络错误'));
      });
      req.on('close', () => {
        clearTimeout(timer);
        if (signal) signal.removeEventListener('abort', onAbort);
      });
      req.end();
    });
    if (text.redirect) {
      const next = new URL(text.redirect, current).toString();
      current = validatePublicUrl(next);
      continue;
    }
    if (text.status < 200 || text.status >= 300) {
      throw new SafeHttpError('http_error', `HTTP ${text.status}`, text.status);
    }
    return text.body;
  }
  throw new SafeHttpError('too_many_redirects', '重定向过多');
}

module.exports = { SafeHttpError, isPrivateIp, validatePublicUrl, resolvePublic, safeFetchText, USER_AGENT };
