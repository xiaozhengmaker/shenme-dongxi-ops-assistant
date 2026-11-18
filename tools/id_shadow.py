# -*- coding: utf-8 -*-
import io, json, sqlite3, re, datetime as dt
rid = "run-20261118171936"
rows = []
with io.open(r"D:\DeepSeek\运营\data\tg_rejects.jsonl", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            o = json.loads(line)
            if o.get("run_id") == rid:
                rows.append(o)
snap = json.load(io.open(r"D:\DeepSeek\运营\data\tg_links_snapshot_run-20261118171936.json", encoding="utf-8"))
snapk = [x["u"] for x in snap["links"]]
pool = json.load(io.open(r"D:\DeepSeek\运营\data\pool_telegram.json", encoding="utf-8"))["items"]

con = sqlite3.connect(r"D:\DeepSeek\运营\data\groupops.db")
db = [dict(zip(("id","name"), r)) for r in con.execute("SELECT native_group_id, group_name FROM groups WHERE platform='Telegram'")]
db_ids = set(x["id"] for x in db if x["id"].isdigit())
db_handles = set(x["id"].lstrip("@").lower() for x in db if x["id"].startswith("@"))

# A) 41..90 主结果对平
tail = rows[40:]
def cls(o):
    e = (o.get("err") or "").strip()
    if "resolve_failed" not in (o.get("reasons") or []):
        return "resolved"
    if re.search(r"FLOOD_WAIT_", e):
        return "rate_limited"
    if not e:
        return "unknown_error"
    return "other_error"
from collections import Counter
c = Counter(cls(o) for o in tail)
recon = {"resolved": c["resolved"], "rate_limited": c["rate_limited"], "unknown_error": c["unknown_error"], "other_error": c["other_error"], "total": len(tail)}

# B) 稳定 ID 影子统计
comparable = [o for o in rows if (o.get("id") or "").strip()]
missing = [o for o in rows if not (o.get("id") or "").strip()]
id2u, u2id = {}, {}
for o in comparable:
    gid = str(o["id"]); u = (o.get("u") or "").lower()
    id2u.setdefault(gid, set()).add(u)
    u2id.setdefault(u, set()).add(gid)
conf_a = {k: sorted(v) for k, v in id2u.items() if len(v) > 1}
conf_b = {k: sorted(v) for k, v in u2id.items() if len(v) > 1}
# 与 DB 的交叉：同一稳定 id 是否在库里以 @handle 另存
cross = []
for o in comparable:
    gid = str(o["id"]); u = (o.get("u") or "").lower()
    in_id = gid in db_ids
    in_h = u in db_handles
    if in_id and in_h:
        cross.append({"u": u, "id": gid})
dup_rows = [o for o in comparable if "dup" in (o.get("reasons") or [])]
dup_change = [o for o in dup_rows if str(o["id"]) not in db_ids]
shadow = {
    "run_id": rid, "objects": len(rows),
    "comparable": len(comparable), "missing_stable_id": len(missing),
    "stable_id_coverage": round(len(comparable)/len(rows), 3),
    "conflict_same_id_multi_keys": len(conf_a),
    "conflict_same_key_multi_ids": len(conf_b),
    "db_both_forms": len(cross),
    "dup_total_comparable": len(dup_rows),
    "dup_would_change": len(dup_change),
    "dup_would_stay": len(dup_rows) - len(dup_change),
}

# C) 恢复清单：1 retry_due + 50 deferred = 51
recover = ["beseda_fayzik"] + [o.get("u") for o in tail]
recover_set = set(recover)
snap_set = set(snapk)
rc = {
    "recover_targets": len(recover), "unique": len(recover_set),
    "lost_from_snapshot": len(recover_set - snap_set),
    "dup_in_list": len(recover) - len(recover_set),
    "retry_due": "beseda_fayzik", "deferred": len(tail),
}
out = {"reconcile_tail": recon, "shadow": shadow, "recovery": rc}
io.open(r"D:\DeepSeek\运营\data\tg_id_shadow.json", "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=2))
print(json.dumps(out, ensure_ascii=True, indent=2))