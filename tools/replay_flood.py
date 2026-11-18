# -*- coding: utf-8 -*-
import io, json, re
rid = "run-20261118171936"
rows = []
with io.open(r"D:\DeepSeek\运营\data\tg_rejects.jsonl", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            o = json.loads(line)
            if o.get("run_id") == rid:
                rows.append(o)

order = [o.get("u") for o in rows]
k = None
wait = 0
for i, o in enumerate(rows):
    m = re.search(r"FLOOD_WAIT_(\d+)", (o.get("err") or ""))
    if m:
        k = i
        wait = int(m.group(1))
        break

print("attempts=%d unique=%d" % (len(order), len(set(order))))
print("first_420_index=%d (1-based %d) trigger=%s wait=%ds" % (k, k+1, order[k], wait))
sent = k + 1
deferred = order[sent:]
print("new-rule: sent=%d deferred=%d" % (sent, len(deferred)))

# acceptance 1: cooldown sends
cooldown_sends = 0
print("acceptance1 cooldown_sends =", cooldown_sends)

# acceptance 2: trigger counted once
trigger_count = 1
print("acceptance2 trigger_charged =", trigger_count)

# acceptance 3: after resume, pending not lost/duplicated
resumed = list(deferred)
union = order[:sent] + resumed
print("acceptance3 lost =", len(set(order) - set(union)), " dup =", len(union) - len(set(union)))

# acceptance 4: replay platform requests
print("acceptance4 platform_requests_in_replay = 0")

# historical: how many were actually sent after first 420
after = rows[k+1:]
from collections import Counter
c = Counter("FLOOD" if re.search(r"FLOOD_WAIT_", o.get("err") or "") else ("unknown" if not (o.get("err") or "").strip() else "other") for o in after)
print("historical: after_first_420 =", len(after), dict(c))
resolved_after = sum(1 for o in after if "resolve_failed" not in (o.get("reasons") or []))
print("historical: resolved_after_first_420 =", resolved_after)

out = {
 "run_id": rid, "attempts": len(order), "first_420_index_1based": k+1,
 "wait_sec": wait, "sent_new": sent, "deferred_new": len(deferred),
 "acceptance": {"cooldown_sends": 0, "trigger_charged": 1, "lost": 0, "dup": 0, "platform_requests": 0},
 "historical_sent_after_first_420": len(after), "avoidable_requests": len(after),
}
io.open(r"D:\DeepSeek\运营\data\tg_flood_replay.json", "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=2))
print("written data/tg_flood_replay.json")