# -*- coding: utf-8 -*-
"""本地数据库工具（SQLite）— 社么东西 / 社群运营助手

用法:
  python db_tool.py init                     建库 + 建表 + 建索引（幂等）
  python db_tool.py import <csv> [<csv>...]  把 users.csv / steam_users.csv 导进库（幂等 upsert）
  python db_tool.py stats                    输出 {rows, groups, platforms, size_mb, path}
  python db_tool.py bulk <平台> <群ID> <群名> <ids文件>  批量导入一页/一批 user_id（幂等）
  python db_tool.py vacuum                   压缩数据库文件
"""
import csv
import io
import json
import os
import sqlite3
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE, "data", "groupops.db")

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
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con


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
            con.executemany(INSERT_SQL, rows)
            con.commit()
            n = len(rows)
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
    with io.open(ids_file, "r", encoding="utf-8") as fh:
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
    elif cmd == "vacuum":
        cmd_vacuum()
    else:
        print("unknown command: " + cmd)
        sys.exit(1)


if __name__ == "__main__":
    main()
