# -*- coding: utf-8 -*-
import io, csv, collections

CSV = r"D:\DeepSeek\运营\data\users.csv"
rows = list(csv.DictReader(io.open(CSV, encoding="utf-8-sig")))
print("rows =", len(rows))
print("fields =", list(rows[0].keys()))

def blank(v):
    return v is None or str(v).strip() == ""

problems = collections.Counter()
by_plat = collections.Counter()
by_lang = collections.Counter()
ids = {}
dups = 0
weird_id = []
for r in rows:
    p = (r.get("平台") or "").strip()
    by_plat[p] += 1
    by_lang[(r.get("语言") or "-").strip() or "-"] += 1
    for f in ("平台", "群ID", "群名", "用户ID"):
        if blank(r.get(f)):
            problems[f + " 为空"] += 1
    key = (p, r.get("群ID"), r.get("用户ID"))
    if key in ids:
        dups += 1
    else:
        ids[key] = 1
    uid = (r.get("用户ID") or "").strip()
    if uid and not uid.isdigit():
        weird_id.append((p, uid))
    if uid and uid.isdigit() and len(uid) < 5:
        problems["用户ID 过短"] += 1

print("duplicate keys =", dups)
print("platform:", dict(by_plat))
print("lang top:", by_lang.most_common(8))
print("blank fields:", dict(problems))
print("non-numeric user ids =", len(weird_id), weird_id[:5])

# 每平台样本 3 条
seen = collections.Counter()
print("\n--- 抽样 ---")
for r in rows:
    p = r.get("平台")
    if seen[p] < 2:
        seen[p] += 1
        print(p, "|", r.get("群名", "")[:28], "|", r.get("用户ID"), "|", r.get("用户名") or "-", "|",
              r.get("语言") or "-", "|", r.get("角色") or "-", "|", r.get("采集日"))
