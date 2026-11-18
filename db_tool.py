# -*- coding: utf-8 -*-
"""本地数据库工具（SQLite）— 社么东西 / 社群运营助手

用法:
  python db_tool.py init                     建库 + 建表 + 建索引（幂等）
  python db_tool.py import <csv> [<csv>...]  把 users.csv / steam_users.csv 导进库（幂等 upsert）
  python db_tool.py stats                    输出 {rows, groups, platforms, size_mb, path}
  python db_tool.py bulk <平台> <群ID> <群名> <ids文件>  批量导入一页/一批 user_id（幂等）
  python db_tool.py vacuum                   压缩数据库文件
"""
from contextlib import closing
import csv
import io
import json
import os
import sqlite3
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
def configured_db_path():
    config_path = os.path.join(BASE, "config.json")
    path = os.path.join("data", "groupops.db")
    if os.path.exists(config_path):
        with open(config_path, encoding="utf-8-sig") as stream:
            path = json.load(stream).get("db", {}).get("path") or path
    return path if os.path.isabs(path) else os.path.join(BASE, path)


DB_PATH = configured_db_path()

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  platform      TEXT NOT NULL,
  group_id      TEXT NOT NULL,
  group_name    TEXT,
  user_id       TEXT NOT NULL,
  username      TEXT,
  nickname      TEXT,
  role          TEXT,
  lang          TEXT,
  last_active   TEXT,
  collected_at  TEXT,
  source        TEXT,
  status        TEXT,
  PRIMARY KEY (platform, group_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_users_plat ON users(platform);
CREATE INDEX IF NOT EXISTS idx_users_uid  ON users(user_id);
CREATE INDEX IF NOT EXISTS idx_users_name ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_grp  ON users(group_id);

-- 线索表：一条帖子/一条评论 = 一行
CREATE TABLE IF NOT EXISTS leads (
  url          TEXT PRIMARY KEY,
  platform     TEXT,
  sub          TEXT,
  keyword      TEXT,
  title        TEXT,
  author       TEXT,
  comments     TEXT,
  time_text    TEXT,
  intent_rule  TEXT,
  ai_intent    TEXT,
  ai_is_lead   INTEGER,
  ai_relevance REAL,
  ai_reason    TEXT,
  scanned_at   TEXT,
  scored_at    TEXT
);
CREATE INDEX IF NOT EXISTS idx_leads_lead ON leads(ai_is_lead);
CREATE INDEX IF NOT EXISTS idx_leads_kw   ON leads(keyword);

-- ---------------------------------------------------------------- 实体层（v3）
-- 群实体：只记录「已观察到的」群，原生 ID 全程 TEXT
CREATE TABLE IF NOT EXISTS groups (
  platform         TEXT NOT NULL,
  native_group_id  TEXT NOT NULL,
  group_name       TEXT,
  url              TEXT,
  member_count     INTEGER,
  last_member_count INTEGER,
  daily_posts      INTEGER,
  lang             TEXT,
  status           TEXT,
  first_seen       TEXT,
  last_seen        TEXT,
  PRIMARY KEY (platform, native_group_id)
);

-- 用户实体：跨群去重后的「人」，不跨平台合并
CREATE TABLE IF NOT EXISTS user_entities (
  platform        TEXT NOT NULL,
  native_user_id  TEXT NOT NULL,
  username        TEXT,
  lang            TEXT,
  first_seen      TEXT,
  last_seen       TEXT,
  PRIMARY KEY (platform, native_user_id)
);

-- 成员关系：只记录观察事实
CREATE TABLE IF NOT EXISTS memberships (
  platform         TEXT NOT NULL,
  native_user_id   TEXT NOT NULL,
  native_group_id  TEXT NOT NULL,
  first_seen       TEXT,
  last_seen        TEXT,
  source           TEXT,
  PRIMARY KEY (platform, native_user_id, native_group_id)
);

-- 证据：一条信号可以支持多个实体判断，但不复制原始信号
CREATE TABLE IF NOT EXISTS evidence (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  signal_url  TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  platform    TEXT,
  reason      TEXT,
  created_at  TEXT,
  UNIQUE (signal_url, entity_type, entity_id)
);

-- 评分快照：维度明细/覆盖率/置信度/版本，可回溯重算
CREATE TABLE IF NOT EXISTS entity_scores (
  entity_type    TEXT NOT NULL,
  entity_id      TEXT NOT NULL,
  platform       TEXT NOT NULL DEFAULT '',
  score_version  TEXT NOT NULL,
  profile_version TEXT,
  value_score    REAL,
  confidence     REAL,
  coverage       REAL,
  tier           TEXT,
  known_dims     INTEGER,
  dims_json      TEXT,
  risk_flags     TEXT,
  reason_codes   TEXT,
  evidence_window TEXT,
  scored_at      TEXT,
  PRIMARY KEY (entity_type, entity_id, platform, score_version)
);

-- 动作建议（不是扩展任务，只是业务建议）
CREATE TABLE IF NOT EXISTS recommendations (
  dedupe_key    TEXT PRIMARY KEY,
  action_type   TEXT,
  platform      TEXT,
  entity_id     TEXT,
  score         REAL,
  confidence    REAL,
  coverage      REAL,
  reason_codes  TEXT,
  evidence_ids  TEXT,
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','accepted','ignored','expired','done','failed')),
  created_at    TEXT,
  expires_at    TEXT,
  decided_by    TEXT,
  decided_at    TEXT,
  result_reason TEXT
);

-- 执行记录与结果回流
CREATE TABLE IF NOT EXISTS actions (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  recommendation_key TEXT,
  kind               TEXT,
  status             TEXT,
  started_at         TEXT,
  finished_at        TEXT,
  result             TEXT,
  run_id             TEXT
);

CREATE INDEX IF NOT EXISTS idx_ev_entity ON evidence(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_scores_entity ON entity_scores(entity_type, score_version);
CREATE INDEX IF NOT EXISTS idx_rec_status ON recommendations(status);
CREATE INDEX IF NOT EXISTS idx_members_group ON memberships(platform, native_group_id);
"""

# users.csv 表头 -> 库字段
COLMAP = {
    "平台": "platform",
    "群ID": "group_id",
    "群名": "group_name",
    "用户ID": "user_id",
    "用户名": "username",
    "昵称": "nickname",
    "语言": "lang",
    "角色": "role",
    "最近活跃": "last_active",
    "采集日": "collected_at",
    "来源": "source",
    "状态": "status",
}
# steam_users.csv 表头
STEAM_MAP = {
    "平台": "platform",
    "群ID": "group_id",
    "群名": "group_name",
    "SteamID64": "user_id",
    "角色": "role",
    "采集日": "collected_at",
    "来源": "source",
}


INSERT_SQL = (
    "INSERT INTO users (platform,group_id,group_name,user_id,username,nickname,role,lang,last_active,collected_at,source,status)"
    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
    " ON CONFLICT(platform,group_id,user_id) DO UPDATE SET"
    " group_name=excluded.group_name, username=excluded.username, nickname=excluded.nickname,"
    " role=excluded.role, lang=excluded.lang, last_active=excluded.last_active,"
    " collected_at=excluded.collected_at, source=excluded.source, status=excluded.status"
)

def connect():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    for attempt in range(6):
        con = sqlite3.connect(DB_PATH, timeout=5)
        try:
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("PRAGMA synchronous=NORMAL")
            con.executescript(SCHEMA)
            con.execute("BEGIN IMMEDIATE")
            columns = {row[1] for row in con.execute("PRAGMA table_info(leads)")}
            for name, definition in {
                "status": "TEXT NOT NULL DEFAULT 'new' CHECK(status IN ('new','contacted','replied','ignored'))",
                "note": "TEXT NOT NULL DEFAULT ''",
                "updated_at": "TEXT NOT NULL DEFAULT ''",
            }.items():
                if name not in columns:
                    con.execute("ALTER TABLE leads ADD COLUMN " + name + " " + definition)
            con.commit()
            return con
        except Exception as error:
            con.close()
            if not isinstance(error, sqlite3.OperationalError) or not any(word in str(error).lower() for word in ("locked", "busy")) or attempt == 5:
                raise
            time.sleep(0.05 * 2 ** attempt)


def cmd_init():
    con = connect()
    con.executescript(SCHEMA)
    con.commit()
    con.close()
    print(json.dumps({"ok": True, "path": DB_PATH}, ensure_ascii=True))


def _open_text(path):
    # users.csv / steam_users.csv 都是 UTF-8 with BOM
    return io.open(path, "r", encoding="utf-8-sig", newline="")


def cmd_import(paths):
    con = connect()
    con.executescript(SCHEMA)
    total = 0
    per_file = []
    for path in paths:
        if not os.path.exists(path):
            per_file.append({"file": path, "rows": 0, "skipped": "missing"})
            continue
        n = 0
        skipped = 0
        with _open_text(path) as fh:
            rd = csv.DictReader(fh)
            fields = rd.fieldnames or []
            mapping = COLMAP if ("用户ID" in fields) else STEAM_MAP
            rows = []
            for raw in rd:
                rec = {"platform": "", "group_id": "", "group_name": "", "user_id": "",
                       "username": "", "nickname": "", "role": "", "lang": "",
                       "last_active": "", "collected_at": "", "source": "", "status": ""}
                for k, v in raw.items():
                    if k is None:
                        continue
                    key = (k or "").strip()
                    if key in mapping:
                        rec[mapping[key]] = (v or "").strip()
                if not rec["user_id"] or not rec["group_id"]:
                    skipped += 1
                    continue
                if rec["platform"] == "Steam" and not rec["status"]:
                    rec["status"] = "有效"
                rows.append((rec["platform"], rec["group_id"], rec["group_name"], rec["user_id"],
                             rec["username"], rec["nickname"], rec["role"], rec["lang"],
                             rec["last_active"], rec["collected_at"], rec["source"], rec["status"]))
                if len(rows) >= 1000:
                    con.executemany(INSERT_SQL, rows)
                    n += len(rows)
                    rows.clear()
            if rows:
                con.executemany(INSERT_SQL, rows)
                n += len(rows)
            con.commit()
        total += n
        per_file.append({"file": os.path.basename(path), "rows": n, "skipped": skipped})
    con.close()
    print(json.dumps({"ok": True, "imported": total, "files": per_file}, ensure_ascii=True))


def cmd_stats():
    if not os.path.exists(DB_PATH):
        print(json.dumps({"ok": False, "error": "db_missing", "path": DB_PATH}, ensure_ascii=True))
        return
    con = connect()
    rows = con.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    groups = con.execute("SELECT COUNT(DISTINCT platform || '|' || group_id) FROM users").fetchone()[0]
    platforms = []
    for name, cnt, grp in con.execute(
        "SELECT platform, COUNT(*), COUNT(DISTINCT group_id) FROM users GROUP BY platform ORDER BY COUNT(*) DESC"
    ):
        platforms.append({"name": name, "users": cnt, "groups": grp})
    con.close()
    size_mb = round(os.path.getsize(DB_PATH) / 1048576.0, 2)
    print(json.dumps({"ok": True, "path": DB_PATH, "rows": rows, "groups": groups,
                      "platforms": platforms, "size_mb": size_mb}, ensure_ascii=True))


def cmd_bulk(argv):
    """bulk <platform> <group_id> <group_name> <ids_file>
    ids_file: 每行一个 user_id（或 user_id,username,nickname）。幂等 upsert。"""
    if len(argv) < 4:
        print(json.dumps({"ok": False, "error": "usage: bulk <platform> <group_id> <group_name> <ids_file>"}, ensure_ascii=True))
        return
    platform, gid, gname, ids_file = argv[0], argv[1], argv[2], argv[3]
    if not os.path.exists(ids_file):
        print(json.dumps({"ok": False, "error": "ids_file_missing"}, ensure_ascii=True))
        return
    con = connect()
    con.executescript(SCHEMA)
    today = __import__("datetime").date.today().strftime("%Y/%m/%d")
    rows = []
    n = 0
    with io.open(ids_file, "r", encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split(",")
            uid = parts[0].strip()
            if not uid:
                continue
            uname = parts[1] if len(parts) > 1 else ""
            nick = parts[2] if len(parts) > 2 else ""
            rows.append((platform, gid, gname, uid, uname, nick, "成员", "", "", today, "群成员XML", "有效"))
            n += 1
            if len(rows) >= 5000:
                con.executemany(INSERT_SQL, rows); con.commit(); rows = []
    if rows:
        con.executemany(INSERT_SQL, rows); con.commit()
    total = con.execute("SELECT COUNT(*) FROM users WHERE platform=? AND group_id=?", (platform, gid)).fetchone()[0]
    con.close()
    print(json.dumps({"ok": True, "platform": platform, "group_id": gid, "input": n, "rows_in_group": total}, ensure_ascii=True))


def cmd_vacuum():
    con = connect()
    con.execute("VACUUM")
    con.close()
    print(json.dumps({"ok": True, "path": DB_PATH}, ensure_ascii=True))


def cmd_leads(argv):
    """leads <signals.json> [scored.json]  -- 信号入库，可选覆盖 AI 结果"""
    if not argv:
        print("usage: leads <signals.json> [scored.json]")
        sys.exit(1)
    sig_path = argv[0]
    sco_path = argv[1] if len(argv) > 1 else ""
    signals = {}
    with open(sig_path, "r", encoding="utf-8-sig") as f:
        sig = json.load(f)
    for it in sig.get("items", []):
        u = (it.get("url") or "").strip()
        if not u:
            continue
        signals[u] = it
    scored = {}
    if sco_path and os.path.exists(sco_path):
        with open(sco_path, "r", encoding="utf-8-sig") as f:
            sco = json.load(f)
        for it in sco.get("items", []):
            u = (it.get("url") or "").strip()
            if u:
                scored[u] = it
    conn = connect()
    conn.executescript(SCHEMA)   # 幂等：老库自动补 leads 表
    n = 0
    for u, it in signals.items():
        sc = scored.get(u, {})
        conn.execute(
            "INSERT INTO leads (url,platform,sub,keyword,title,author,comments,time_text,intent_rule,"
            "ai_intent,ai_is_lead,ai_relevance,ai_reason,scanned_at,scored_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            " ON CONFLICT(url) DO UPDATE SET"
            " sub=excluded.sub, keyword=excluded.keyword, title=excluded.title,"
            " author=excluded.author, comments=excluded.comments, time_text=excluded.time_text,"
            " intent_rule=excluded.intent_rule,"
            " ai_intent=COALESCE(excluded.ai_intent, leads.ai_intent),"
            " ai_is_lead=COALESCE(excluded.ai_is_lead, leads.ai_is_lead),"
            " ai_relevance=COALESCE(excluded.ai_relevance, leads.ai_relevance),"
            " ai_reason=COALESCE(excluded.ai_reason, leads.ai_reason),"
            " scanned_at=excluded.scanned_at,"
            " scored_at=COALESCE(excluded.scored_at, leads.scored_at)",
            (
                u, "Reddit", it.get("sub"), it.get("keyword"), it.get("title"),
                it.get("author"), it.get("comments"), it.get("time_text"),
                it.get("intent"),
                sc.get("ai_intent"), 1 if sc.get("ai_is_lead") else (0 if sc else None),
                sc.get("ai_relevance"), sc.get("ai_reason"),
                it.get("scanned_at"), sc.get("scored_at") or (sco.get("scored_at") if sc else None),
            ),
        )
        n += 1
    conn.commit()
    row = conn.execute("SELECT COUNT(*) c, SUM(CASE WHEN ai_is_lead=1 THEN 1 ELSE 0 END) l FROM leads").fetchone()
    conn.close()
    print(json.dumps({"imported": n, "total": row[0], "leads": row[1] or 0}))


def cmd_leads_workflow():
    with closing(connect()) as con, con:
        items = {url: {"status": status, "note": note, "updated_at": updated}
                 for url, status, note, updated in con.execute("SELECT url,status,note,updated_at FROM leads")}
    print(json.dumps({"ok": True, "items": items}, ensure_ascii=True))


def cmd_leads_action(path):
    from datetime import datetime, timezone
    with open(path, encoding="utf-8-sig") as stream:
        action = json.load(stream)
    url, status = action.get("url"), action.get("status")
    if not isinstance(url, str) or not url.strip() or status not in ("new", "contacted", "replied", "ignored") or ("note" in action and not isinstance(action["note"], str)):
        print(json.dumps({"ok": False, "error": "invalid_action"}))
        return
    with closing(connect()) as con, con:
        row = con.execute("SELECT note FROM leads WHERE url=?", (url,)).fetchone()
        if row is None:
            # JSON-backed legacy API may contain signals not yet imported into SQLite.
            signal_path = os.path.join(BASE, "data", "leads_signals.json")
            items = []
            if os.path.exists(signal_path):
                with open(signal_path, encoding="utf-8-sig") as stream:
                    items = json.load(stream).get("items", [])
            item = next((item for item in items if item.get("url") == url), None)
            if item is None:
                print(json.dumps({"ok": False, "error": "lead_not_found"}))
                return
            con.execute("INSERT INTO leads(url,platform,title,author,sub,keyword) VALUES (?,?,?,?,?,?)",
                        (url, "Reddit", item.get("title"), item.get("author"), item.get("sub"), item.get("keyword")))
        note = action.get("note", row[0] if row else "")
        updated = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
        con.execute("UPDATE leads SET status=?,note=?,updated_at=? WHERE url=?", (status, note, updated, url))
    print(json.dumps({"ok": True, "url": url, "status": status, "note": note, "updated_at": updated}, ensure_ascii=True))



# ---------------------------------------------------------------- v3: entities
def _iso_now():
    from datetime import datetime
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def cmd_migrate(argv):
    """migrate [--dry-run] -- 从 users/leads 建实体、成员关系与证据（幂等）"""
    dry = "--dry-run" in argv
    now = _iso_now()
    stats = {}
    with closing(connect()) as con, con:
        con.executescript(SCHEMA)

        groups = list(con.execute(
            "SELECT platform, group_id, MAX(group_name), MAX(lang), COUNT(DISTINCT user_id) "
            "FROM users GROUP BY platform, group_id"))
        users = list(con.execute(
            "SELECT platform, user_id, MAX(username), MAX(lang) FROM users "
            "WHERE user_id <> '' GROUP BY platform, user_id"))
        mem = list(con.execute(
            "SELECT platform, user_id, group_id, MAX(collected_at), MAX(source) FROM users "
            "WHERE user_id <> '' AND group_id <> '' GROUP BY platform, user_id, group_id"))
        leads = list(con.execute(
            "SELECT url, author FROM leads WHERE COALESCE(author,'') <> '' AND LOWER(author) <> '[deleted]'"))

        stats["groups"] = len(groups)
        stats["user_entities"] = len(users)
        stats["memberships"] = len(mem)
        stats["evidence_author"] = len(leads)
        if dry:
            stats["dry_run"] = True
            print(json.dumps(stats, ensure_ascii=True))
            return

        for platform, gid, gname, lang, cnt in groups:
            con.execute(
                "INSERT INTO groups(platform,native_group_id,group_name,member_count,lang,first_seen,last_seen)"
                " VALUES (?,?,?,?,?,?,?)"
                " ON CONFLICT(platform,native_group_id) DO UPDATE SET"
                " group_name=COALESCE(excluded.group_name, groups.group_name),"
                " member_count=excluded.member_count,"
                " lang=COALESCE(excluded.lang, groups.lang), last_seen=excluded.last_seen",
                (platform, gid, gname, cnt, lang, now, now))

        for platform, uid, uname, lang in users:
            con.execute(
                "INSERT INTO user_entities(platform,native_user_id,username,lang,first_seen,last_seen)"
                " VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(platform,native_user_id) DO UPDATE SET"
                " username=COALESCE(excluded.username, user_entities.username),"
                " lang=COALESCE(excluded.lang, user_entities.lang), last_seen=excluded.last_seen",
                (platform, uid, uname, lang, now, now))

        for platform, uid, gid, collected, source in mem:
            con.execute(
                "INSERT INTO memberships(platform,native_user_id,native_group_id,first_seen,last_seen,source)"
                " VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(platform,native_user_id,native_group_id) DO UPDATE SET"
                " last_seen=excluded.last_seen, source=COALESCE(excluded.source, memberships.source)",
                (platform, uid, gid, collected or now, collected or now, source))

        for url, author in leads:
            con.execute(
                "INSERT OR IGNORE INTO evidence(signal_url,entity_type,entity_id,platform,reason,created_at)"
                " VALUES (?,?,?,?,?,?)",
                (url, "user", str(author), "Reddit", "authored_signal", now))

        stats["evidence_total"] = con.execute("SELECT COUNT(*) FROM evidence").fetchone()[0]
    print(json.dumps(stats, ensure_ascii=True))


def _upsert_score(con, etype, eid, platform, res):
    con.execute(
        "INSERT INTO entity_scores(entity_type,entity_id,platform,score_version,profile_version,"
        "value_score,confidence,coverage,tier,known_dims,dims_json,risk_flags,reason_codes,"
        "evidence_window,scored_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        " ON CONFLICT(entity_type,entity_id,platform,score_version) DO UPDATE SET"
        " value_score=excluded.value_score, confidence=excluded.confidence,"
        " coverage=excluded.coverage, tier=excluded.tier, known_dims=excluded.known_dims,"
        " dims_json=excluded.dims_json, risk_flags=excluded.risk_flags,"
        " reason_codes=excluded.reason_codes, scored_at=excluded.scored_at",
        (etype, eid, platform, res["score_version"], res.get("profile_version", ""),
         res["score"], res["confidence"], res["coverage"], res.get("tier"),
         res.get("known_dims", 0), json.dumps(res.get("dims"), ensure_ascii=False),
         json.dumps(res.get("risk_flags") or [], ensure_ascii=False),
         json.dumps(res.get("reason_codes") or [], ensure_ascii=False),
         "", _iso_now()))


def cmd_score(argv):
    """score [--limit N] -- 用户分（直接证据）+ 群分（聚合已算好的用户分）"""
    import score_engine as se

    limit = 0
    if "--limit" in argv:
        try:
            limit = int(argv[argv.index("--limit") + 1])
        except Exception:
            limit = 0
    cfg = se.load_config(os.path.join(BASE, "data", "score_config.json"))

    with closing(connect()) as con, con:
        con.executescript(SCHEMA)

        lead_rows = {}
        for (author, title, rel, intent, ai_intent, comments, time_text, is_lead) in con.execute(
                "SELECT author,title,ai_relevance,intent_rule,ai_intent,comments,time_text,ai_is_lead "
                "FROM leads WHERE COALESCE(author,'') <> ''"):
            key = str(author)
            prev = lead_rows.get(key)
            if prev is None or (rel or 0) > (prev.get("ai_relevance") or 0):
                lead_rows[key] = dict(title=title, ai_relevance=rel, intent_rule=intent,
                                      ai_intent=ai_intent, comments=comments,
                                      time_text=time_text, ai_is_lead=is_lead)

        member_rows = {}
        for platform, uid, role, lang, uname, gid in con.execute(
                "SELECT platform,user_id,role,lang,username,group_id FROM users"):
            member_rows.setdefault((platform, str(uid)), dict(role=role, lang=lang,
                                                              username=uname, group_id=gid))

        scope_all = "--all" in argv
        entities = set(("Reddit", a) for a in lead_rows)
        if scope_all:
            entities |= set(member_rows.keys())
        else:
            per_group = {}
            for (platform, uid), m in member_rows.items():
                lst = per_group.setdefault((platform, m.get("group_id")), [])
                if len(lst) < 200:
                    lst.append((platform, uid))
            for lst in per_group.values():
                entities |= set(lst)
        if limit:
            entities = set(sorted(entities)[:limit])

        user_scores = {}
        n_user = 0
        for platform, uid in entities:
            lead = lead_rows.get(uid) if platform == "Reddit" else None
            m = member_rows.get((platform, uid))
            res = se.score_user(lead=lead, membership=m)
            res["profile_version"] = cfg.get("profile_version", "")
            if res["score"] is None and not res["dims"]:
                continue
            _upsert_score(con, "user", uid, platform, res)
            user_scores[uid] = res
            n_user += 1

        groups = list(con.execute(
            "SELECT platform,native_group_id,group_name,member_count,last_member_count,daily_posts,lang,status "
            "FROM groups"))
        n_group = 0
        for platform, gid, gname, cnt, last_cnt, daily, lang, status in groups:
            rows = list(con.execute(
                "SELECT user_id,role,lang,username,last_active FROM users "
                "WHERE platform=? AND group_id=?", (platform, gid)))
            res = se.score_group(
                dict(group_name=gname, member_count=cnt, last_member_count=last_cnt,
                     daily_posts=daily, lang=lang, status=status),
                rows, user_scores)
            res["profile_version"] = cfg.get("profile_version", "")
            _upsert_score(con, "group", gid, platform, res)
            n_group += 1

        # ---- topic entities: 一个关键词 = 一个话题实体
        topic_rows = {}
        for kw, author, rel, intent, ai_intent, comments, time_text, title in con.execute(
                "SELECT keyword,author,ai_relevance,intent_rule,ai_intent,comments,time_text,title "
                "FROM leads WHERE COALESCE(keyword,'') <> ''"):
            topic_rows.setdefault(str(kw), []).append(dict(
                author=author, ai_relevance=rel, intent_rule=intent, ai_intent=ai_intent,
                comments=comments, time_text=time_text, title=title))
        n_topic = 0
        for kw, rows in topic_rows.items():
            res = se.score_topic(kw, rows)
            if not res:
                continue
            res["profile_version"] = cfg.get("profile_version", "")
            _upsert_score(con, "topic", kw, "Reddit", res)
            n_topic += 1

    print(json.dumps({"ok": True, "users_scored": n_user, "groups_scored": n_group, "topics_scored": n_topic,
                      "score_version": se.SCORE_VERSION}, ensure_ascii=True))


def cmd_recommend(argv):
    """recommend [--limit N] [--dry-run] -- 依据群分生成建议（去重）"""
    import score_engine as se

    limit = 50
    if "--limit" in argv:
        try:
            limit = int(argv[argv.index("--limit") + 1])
        except Exception:
            limit = 50

    with closing(connect()) as con, con:
        con.executescript(SCHEMA)
        scores = {}
        for platform, gid, score, conf, cov, reasons in con.execute(
                "SELECT platform,entity_id,value_score,confidence,coverage,reason_codes "
                "FROM entity_scores WHERE entity_type='group' AND score_version=?", (se.SCORE_VERSION,)):
            scores[(platform, gid)] = dict(score=score, confidence=conf, coverage=cov,
                                           reason_codes=json.loads(reasons or "[]"))

        elig = {}
        for platform, gid, status in con.execute("SELECT platform,native_group_id,COALESCE(status,'') FROM groups"):
            elig[(platform, gid)] = dict(joined=(status == "已加入"), blocked=False, quota_zero=False)

        recs = se.build_recommendations(scores, elig, limit)

        topic_scores = {}
        for eid, dims_json in con.execute(
                "SELECT entity_id, dims_json FROM entity_scores WHERE entity_type='topic' AND score_version=?",
                (se.SCORE_VERSION,)):
            row = con.execute(
                "SELECT value_score,confidence,coverage,risk_flags,reason_codes FROM entity_scores "
                "WHERE entity_type='topic' AND entity_id=? AND score_version=?",
                (eid, se.SCORE_VERSION)).fetchone()
            if row:
                topic_scores[eid] = dict(score=row[0], confidence=row[1], coverage=row[2],
                                         risk_flags=json.loads(row[3] or "[]"),
                                         reason_codes=json.loads(row[4] or "[]"))
        recs += se.build_topic_recommendations(topic_scores, limit)

        created = 0
        for r in recs:
            cur = con.execute("SELECT dedupe_key FROM recommendations WHERE dedupe_key=?", (r["dedupe_key"],)).fetchone()
            if cur:
                continue
            con.execute(
                "INSERT INTO recommendations(dedupe_key,action_type,platform,entity_id,score,"
                "confidence,coverage,reason_codes,status,created_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?)",
                (r["dedupe_key"], r["action_type"], r["platform"], r["entity_id"], r["score"],
                 r["confidence"], r["coverage"], json.dumps(r["reason_codes"], ensure_ascii=False),
                 "pending", _iso_now()))
            created += 1
    print(json.dumps({"ok": True, "candidates": len(recs), "created": created}, ensure_ascii=True))


def cmd_entities(argv):
    """entities [user|group] [--limit N] -- 输出实体与评分（JSON）"""
    etype = "group"
    for a in argv:
        if a in ("user", "group", "topic"):
            etype = a
    limit = 50
    if "--limit" in argv:
        try:
            limit = int(argv[argv.index("--limit") + 1])
        except Exception:
            limit = 50
    with closing(connect()) as con:
        rows = list(con.execute(
            "SELECT entity_id,platform,value_score,confidence,coverage,tier,known_dims,dims_json,"
            "risk_flags,reason_codes,scored_at FROM entity_scores WHERE entity_type=?"
            " ORDER BY (COALESCE(value_score,0) * COALESCE(confidence,0)) DESC LIMIT ?",
            (etype, limit)))
    items = []
    for r in rows:
        items.append(dict(entity_id=r[0], platform=r[1], score=r[2], confidence=r[3],
                          coverage=r[4], tier=r[5], known_dims=r[6],
                          dims=json.loads(r[7] or "{}"), risk=json.loads(r[8] or "[]"),
                          reasons=json.loads(r[9] or "[]"), scored_at=r[10]))
    print(json.dumps({"ok": True, "type": etype, "items": items}, ensure_ascii=True))



def cmd_recommend_list(argv):
    status = "pending"
    limit = 50
    for i, a in enumerate(argv):
        if a == "--status" and i + 1 < len(argv):
            status = argv[i + 1]
        if a == "--limit" and i + 1 < len(argv):
            limit = int(argv[i + 1])
    con = connect()
    try:
        rows = con.execute(
            "SELECT dedupe_key,action_type,platform,entity_id,score,confidence,coverage,"
            "reason_codes,status,created_at FROM recommendations "
            "WHERE (?='all' OR status=?) ORDER BY score*confidence DESC LIMIT ?",
            (status, status, limit)).fetchall()
        items = [{
            "dedupe_key": r[0], "action_type": r[1], "platform": r[2], "entity_id": r[3],
            "score": r[4], "confidence": r[5], "coverage": r[6],
            "reasons": json.loads(r[7] or "[]"), "status": r[8], "created_at": r[9],
        } for r in rows]
        counts = dict(con.execute(
            "SELECT status, COUNT(*) FROM recommendations GROUP BY status").fetchall())
        print(json.dumps({"ok": True, "items": items, "counts": counts,
                          "total": sum(counts.values())}, ensure_ascii=False))
    finally:
        con.close()


def cmd_decide(path):
    """decide <json> -- {"dedupe_key":..,"status":"accepted|ignored","reason":".."}"""
    with open(path, encoding="utf-8-sig") as fh:
        body = json.load(fh)
    key = body.get("dedupe_key")
    status = body.get("status")
    if not isinstance(key, str) or status not in ("accepted", "ignored", "expired"):
        print(json.dumps({"ok": False, "error": "invalid_decision"}))
        return
    with closing(connect()) as con, con:
        cur = con.execute("UPDATE recommendations SET status=?,decided_by=?,decided_at=?,result_reason=?"
                          " WHERE dedupe_key=?", (status, body.get("by", "user"), _iso_now(),
                                                  body.get("reason", ""), key))
        ok = cur.rowcount > 0
    print(json.dumps({"ok": ok, "dedupe_key": key, "status": status}, ensure_ascii=True))

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    cmd = args[0]
    if cmd == "init":
        cmd_init()
    elif cmd == "import":
        cmd_import(args[1:])
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "bulk":
        cmd_bulk(args[1:])
    elif cmd == "leads":
        cmd_leads(args[1:])
    elif cmd == "leads-workflow":
        cmd_leads_workflow()
    elif cmd == "leads-action":
        cmd_leads_action(args[1])
    elif cmd == "migrate":
        cmd_migrate(args[1:])
    elif cmd == "score":
        cmd_score(args[1:])
    elif cmd == "recommend-list":
        cmd_recommend_list(args[1:])
    elif cmd == "recommend":
        cmd_recommend(args[1:])
    elif cmd == "entities":
        cmd_entities(args[1:])
    elif cmd == "decide":
        cmd_decide(args[1])
    elif cmd == "vacuum":
        cmd_vacuum()
    else:
        print("unknown command: " + cmd)
        sys.exit(1)


if __name__ == "__main__":
    main()
