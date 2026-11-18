import csv, sqlite3, json, collections, os, io, sys

base = r"D:\DeepSeek\运营"
db = os.path.join(base, "data", "groupops.db")
csvp = os.path.join(base, "data", "users.csv")

con = sqlite3.connect(db)
con.row_factory = sqlite3.Row

def db_stats():
    out = {}
    for r in con.execute("SELECT platform, COUNT(*) n, COUNT(DISTINCT group_id) g FROM users GROUP BY platform"):
        out[r["platform"]] = {"rows": r["n"], "groups": r["g"]}
    return out

def csv_stats():
    rows = list(csv.DictReader(io.open(csvp, encoding="utf-8-sig")))
    out = {}
    seen = collections.Counter()
    for r in rows:
        p = (r.get("平台") or "").strip()
        g = (r.get("群ID") or "").strip()
        u = (r.get("用户ID") or "").strip()
        seen[(p, g, u)] += 1
        d = out.setdefault(p, {"rows": 0, "groups": set(), "keys": set()})
        d["rows"] += 1
        d["groups"].add(g)
        d["keys"].add((g, u))
    for p, d in out.items():
        d["groups"] = len(d["groups"])
    dup = sum(v - 1 for v in seen.values() if v > 1)
    return out, len(rows), dup

def db_keys(platform):
    s = set()
    for r in con.execute("SELECT group_id, user_id FROM users WHERE platform=?", (platform,)):
        s.add((str(r["group_id"]), str(r["user_id"])))
    return s

def csv_keys(platform):
    s = set()
    for r in csv.DictReader(io.open(csvp, encoding="utf-8-sig")):
        if (r.get("平台") or "").strip() != platform:
            continue
        s.add(((r.get("群ID") or "").strip(), (r.get("用户ID") or "").strip()))
    return s

d, c, dup = db_stats(), None, 0
c, csv_total, dup = csv_stats()

print("platform | db_rows | csv_rows | db_groups | csv_groups | only_db | only_csv | csv_dup_rows")
for p in sorted(set(list(d.keys()) + list(c.keys()))):
    dd = d.get(p, {"rows": 0, "groups": 0})
    cc = c.get(p, {"rows": 0, "groups": 0})
    only_db = only_csv = "-"
    if p in d and p in c:
        # 只对两边都有的平台算键级差异（数据量大时只算集合大小，不打印明细）
        a, b = db_keys(p), csv_keys(p)
        only_db = len(a - b)
        only_csv = len(b - a)
    print(f"{p} | {dd['rows']} | {cc['rows']} | {dd['groups']} | {cc['groups']} | {only_db} | {only_csv} | -")

print(f"TOTAL | {sum(v['rows'] for v in d.values())} | {csv_total} | "
      f"{sum(v['groups'] for v in d.values())} | {sum(v['groups'] for v in c.values())} | | | {dup}")
print(f"csv duplicate rows = {dup}")
