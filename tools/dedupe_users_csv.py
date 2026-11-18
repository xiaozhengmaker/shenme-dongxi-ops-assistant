# -*- coding: utf-8 -*-
"""清理 data\\users.csv 的重复行（同 平台+群ID+用户ID 只保留第一条）
用法：
  python tools/dedupe_users_csv.py            # 只统计
  python tools/dedupe_users_csv.py --apply    # 写回（先备份）
"""
import csv, io, os, shutil, sys, collections, datetime

base = r"D:\DeepSeek\运营"
p = os.path.join(base, "data", "users.csv")
apply = "--apply" in sys.argv

rows = list(csv.reader(io.open(p, encoding="utf-8-sig", newline="")))
if not rows:
    print("empty")
    sys.exit(0)
header, body = rows[0], rows[1:]
idx = {name: i for i, name in enumerate(header)}
iplat = idx.get("平台", 0)
igrp = idx.get("群ID", 1)
iuser = idx.get("用户ID", 3)

seen = set()
keep = []
dups = 0
per = collections.Counter()
for r in body:
    if len(r) <= max(iplat, igrp, iuser):
        keep.append(r)
        continue
    k = (r[iplat].strip(), r[igrp].strip(), r[iuser].strip())
    if k in seen:
        dups += 1
        per[k[0]] += 1
        continue
    seen.add(k)
    keep.append(r)

print(f"rows={len(body)} kept={len(keep)} dup_removed={dups}")
for k, v in per.most_common():
    print(f"  {k}: {v}")

if not apply:
    print("(dry run; add --apply to write)")
    sys.exit(0)

ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
bak = os.path.join(base, "data", "backup", f"users_{ts}.csv")
os.makedirs(os.path.dirname(bak), exist_ok=True)
shutil.copy2(p, bak)

tmp = p + ".tmp"
with io.open(tmp, "w", encoding="utf-8-sig", newline="") as f:
    w = csv.writer(f)
    w.writerow(header)
    w.writerows(keep)
os.replace(tmp, p)
print(f"written {len(keep)} rows; backup={bak}")
