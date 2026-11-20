'use strict';

const fs = require('fs');
const path = require('path');
const { AppError, nowIso, randomId, assertPlainId } = require('./util');

class Store {
  constructor(dataDir) {
    this.dataDir = path.resolve(dataDir);
    this.profilesDir = path.join(this.dataDir, 'profiles');
    fs.mkdirSync(this.profilesDir, { recursive: true });
  }

  fileFor(id) {
    assertPlainId(id);
    return path.join(this.profilesDir, `${id}.json`);
  }

  list() {
    const out = [];
    for (const name of fs.readdirSync(this.profilesDir)) {
      if (!name.endsWith('.json')) continue;
      try {
        const profile = JSON.parse(fs.readFileSync(path.join(this.profilesDir, name), 'utf8'));
        out.push(summary(profile));
      } catch {
        // 损坏档案不阻塞其它业务档案；GET 具体档案时再报错。
      }
    }
    out.sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
    return out;
  }

  get(id) {
    const file = this.fileFor(id);
    if (!fs.existsSync(file)) throw new AppError('profile_not_found', '档案不存在', 404);
    let profile;
    try {
      profile = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      throw new AppError('profile_invalid', '档案文件损坏，无法读取', 500);
    }
    if (!profile || profile.id !== id) throw new AppError('profile_invalid', '档案 ID 不一致', 500);
    return profile;
  }

  save(profile) {
    if (!profile || !profile.id) throw new AppError('profile_invalid', '档案缺少 ID', 500);
    const file = this.fileFor(profile.id);
    profile.updated_at = nowIso();
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(profile, null, 2) + '\n', 'utf8');
    fs.renameSync(tmp, file);
    return profile;
  }

  create(input) {
    const id = `${slug(input.name || 'profile')}-${randomId('p').split('-')[1]}`;
    const file = this.fileFor(id);
    if (fs.existsSync(file)) throw new AppError('profile_exists', '档案 ID 冲突，请重试', 409);
    const profile = {
      schema_version: 1,
      id,
      created_at: nowIso(),
      updated_at: nowIso(),
      status: 'draft',
      guidance: null,
      calibration: null,
      evidence: [],
      duplicate_log: [],
      report: null,
    };
    return profile;
  }

  remove(id) {
    const file = this.fileFor(id);
    if (fs.existsSync(file)) fs.unlinkSync(file);
  }
}

function slug(value) {
  const text = String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 18);
  return text || 'profile';
}

function summary(profile) {
  return {
    id: profile.id,
    name: profile.guidance && profile.guidance.name ? profile.guidance.name : profile.id,
    status: profile.status,
    updated_at: profile.updated_at,
    evidence_count: Array.isArray(profile.evidence) ? profile.evidence.length : 0,
    calibration_version: profile.calibration ? profile.calibration.version : null,
  };
}

module.exports = { Store };
