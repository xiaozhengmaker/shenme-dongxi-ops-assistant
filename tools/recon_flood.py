# -*- coding: utf-8 -*-
import io, json, re, datetime as dt
rows = []
rid = "run-20261118171936"
with io.open(r"D:\DeepSeek\运营\data\tg_rejects.jsonl", encoding="utf-8") as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        o["_line"] = i
        rows.append(o)
mine = [o for o in rows if o.get("run_id") == rid]
miss = [o for o in mine if "resolve_failed" in (o.get("reasons") or [])]
res = [o for o in mine if "resolve_failed" not in (o.get("reasons") or [])]
print("rows(run)=", len(mine), "resolved=", len(res), "miss=", len(miss))

def kind(e):
    e = (e or "").strip()
    if not e:
        return "unknown_error"
    m = re.search(r"FLOOD_WAIT_(\d+)", e)
    if m:
        return "FLOOD_WAIT"
    m = re.search(r"CODE#\d+\s+(\w+)", e)
    return m.group(1) if m else e[:60]

from collections import Counter, OrderedDict
c = Counter(kind(o.get("err")) for o in miss)
print("--- 主因分布 ---")
for k, v in c.most_common():
    print("  %-18s %d" % (k, v))
print("  合计 =", sum(c.values()))

us = [o.get("u") for o in miss]
print("miss 行数=", len(us), " 去重用户名=", len(set(us)))

# 首个 420
first = None
for idx, o in enumerate(miss, 1):
    m = re.search(r"FLOOD_WAIT_(\d+)", (o.get("err") or ""))
    if m:
        first = (idx, o, int(m.group(1)))
        break
print("首个 420: 第 %d 次失败记录, u=%s, wait=%ds, at=%s" % (first[0], first[1].get("u"), first[2], first[1].get("at")))

def parse_at(s):
    return dt.datetime.fromisoformat(s)

t0 = parse_at(first[1].get("at"))
deadline = t0 + dt.timedelta(seconds=first[2])
after = [o for o in miss[first[0]:] if parse_at(o.get("at")) < deadline]
print("deadline =", deadline.isoformat())
print("首个 420 之后、冷却期内仍发出的解析请求数 =", len(after))
wall = [o for o in miss[first[0]:]]
print("首个 420 之后总请求数 =", len(wall))
print("冷却期内时间跨度 =", (max([parse_at(o.get('at')) for o in after]) - t0).total_seconds() if after else 0, "秒")

tries = Counter(o.get("err") for o in miss)
fl = [o for o in miss if "FLOOD_WAIT" in (o.get("err") or "")]
if fl:
    waits = [int(re.search(r"FLOOD_WAIT_(\d+)", o["err"]).group(1)) for o in fl]
    print("FLOOD 最小/最大 wait =", min(waits), "/", max(waits), " 中位=", sorted(waits)[len(waits)//2])