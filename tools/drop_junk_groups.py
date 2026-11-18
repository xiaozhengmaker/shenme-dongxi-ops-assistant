# -*- coding: utf-8 -*-
"""删除 users.csv 里指定的群（默认清理早期误订的无关板块）"""
import csv, io, os, shutil, sys, datetime

base = r"D:\DeepSeek\运营"
p = os.path.join(base, "data", "users.csv")
DROP = {"r/StockMarket", "r/SkincareAddiction", "r/skincareexchange"}
apply = "--apply" in sys.argv

rows = list(csv.reader(io.open(p, encoding="utf-8-sig", newline="")))
header, body = rows[0], rows[1:]
igrp = header.index("群ID")

keep, dropped = [], 0
for r in body:
    g = r[igrp].strip() if len(r) > igrp else ""
    if g in DROP:
        dropped += 1
        continue
    keep.append(r)

print(f"rows={len(body)} kept={len(keep)} dropped={dropped}")
if not apply:
    print("(dry run; add --apply)")
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
print("written", len(keep), "backup", bak)
