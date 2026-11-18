# -*- coding: utf-8 -*-
"""Alias shadow for Telegram group identity (offline, side-file only).

Modes:
  backfill --run-id ID     build mappings from receipts of one run
  compare  --run-id ID     three-way dup verdict comparison on frozen inventory
  unit                     synthetic alias_conflict case
  stats                    summary of the shadow file
"""
import argparse
import io
import json
import os
import sqlite3
import sys
from collections import Counter

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALIAS = os.path.join(BASE, "data", "tg_alias_shadow.jsonl")
REJECTS = os.path.join(BASE, "data", "tg_rejects.jsonl")
POOL = os.path.join(BASE, "data", "pool_telegram.json")
DB = os.path.join(BASE, "data", "groupops.db")


def load_rejects(run_id):
    rows = []
    with io.open(REJECTS, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if o.get("run_id") == run_id:
                rows.append(o)
    return rows


def load_alias():
    out = []
    if not os.path.exists(ALIAS):
        return out
    with io.open(ALIAS, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def save_alias(records):
    with io.open(ALIAS, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")


def key_of(r):
    return "|".join([r["platform"], r["peer_type"], r["peer_id"], r["handle_norm"]])


def build(rows, run_id, now):
    recs = []
    for o in rows:
        pid = str(o.get("id") or "").strip()
        handle = str(o.get("u") or "").strip().lstrip("@").lower()
        if not pid or not handle:
            continue
        recs.append({
            "platform": "telegram",
            "peer_type": (o.get("k") or "unknown"),
            "peer_id": pid,
            "handle_norm": handle,
            "observed_at": now,
            "run_id": run_id,
        })
    return recs


def cmd_backfill(args):
    rows = [o for o in load_rejects(args.run_id)
            if (o.get("id") or "").strip() and (o.get("u") or "").strip()]
    now = args.now
    incoming = build(rows, args.run_id, now)
    existing = load_alias()
    idx = {key_of(r): r for r in existing}
    added = 0
    touched = 0
    for r in incoming:
        k = key_of(r)
        if k in idx:
            idx[k]["observed_at"] = now
            touched += 1
        else:
            idx[k] = r
            added += 1
    save_alias(list(idx.values()))
    print(json.dumps({
        "run_id": args.run_id,
        "receipts_with_id": len(rows),
        "incoming": len(incoming),
        "added": added,
        "touched": touched,
        "total": len(idx),
    }, ensure_ascii=False))


def known_from_production():
    """Existing-key inventory used by production dup: table usernames + pool handles + numeric ids."""
    handles, ids = set(), set()
    con = sqlite3.connect(DB)
    for (gid,) in con.execute("SELECT native_group_id FROM groups WHERE platform='Telegram'"):
        gid = str(gid)
        if gid.startswith("@"):
            handles.add(gid.lstrip("@").lower())
        elif gid.isdigit():
            ids.add(gid)
    for (gid,) in con.execute("SELECT DISTINCT group_id FROM users WHERE platform='Telegram'"):
        gid = str(gid)
        if gid.startswith("@"):
            handles.add(gid.lstrip("@").lower())
        elif gid.isdigit():
            ids.add(gid)
    if os.path.exists(POOL):
        data = json.load(io.open(POOL, encoding="utf-8"))
        for it in data.get("items", []):
            h = str(it.get("u") or "").strip().lstrip("@").lower()
            pid = str(it.get("id") or "").strip()
            if h:
                handles.add(h)
            if pid.isdigit():
                ids.add(pid)
    return handles, ids


def cmd_compare(args):
    rows = load_rejects(args.run_id)
    resolved = [o for o in rows if "resolve_failed" not in (o.get("reasons") or [])]
    handles, ids = known_from_production()
    alias = load_alias()
    alias_pairs = {(r["peer_id"], r["handle_norm"]) for r in alias}
    alias_by_handle = {}
    for r in alias:
        alias_by_handle.setdefault(r["handle_norm"], set()).add(r["peer_id"])

    res = {"run_id": args.run_id, "resolved": len(resolved),
           "resolved_with_id": sum(1 for o in resolved if (o.get("id") or "").strip()),
           "attempts": len(rows),
           "attempts_with_id": sum(1 for o in rows if (o.get("id") or "").strip())}
    verdicts = {"existing": Counter(), "pure_id": Counter(), "dual": Counter()}
    flips_pure_new = []
    flips_dual = []
    conflicts = []
    for o in resolved:
        h = str(o.get("u") or "").strip().lstrip("@").lower()
        pid = str(o.get("id") or "").strip()
        v_exist = "dup" if (h in handles or (pid and pid in ids)) else "new"
        v_pid = "dup" if (pid and pid in ids) else "new"
        hit_by_alias = bool(pid) and ((pid, h) in alias_pairs or (h in alias_by_handle and pid in alias_by_handle[h]))
        v_dual = "dup" if (v_exist == "dup" or (hit_by_alias and h in handles)) else ("dup" if hit_by_alias and v_exist == "dup" else v_pid)
        if hit_by_alias and h in alias_by_handle and pid not in alias_by_handle[h]:
            conflicts.append({"handle": h, "peer_id": pid, "other_ids": sorted(alias_by_handle[h])})
        verdicts["existing"][v_exist] += 1
        verdicts["pure_id"][v_pid] += 1
        verdicts["dual"][v_dual] += 1
        if v_exist == "dup" and v_pid == "new":
            flips_pure_new.append({"handle": h, "peer_id": pid, "why": "db_has_handle_only"})
        if v_exist != v_dual:
            flips_dual.append({"handle": h, "peer_id": pid, "from": v_exist, "to": v_dual})
    res["verdicts"] = {k: dict(v) for k, v in verdicts.items()}
    res["pure_id_dup_to_new"] = len(flips_pure_new)
    res["dual_changes"] = len(flips_dual)
    res["dual_change_detail"] = flips_dual[:10]
    res["alias_conflicts"] = len(conflicts)
    res["alias_conflict_detail"] = conflicts[:10]
    print(json.dumps(res, ensure_ascii=False, indent=2))


def cmd_unit(args):
    """Synthetic alias_conflict: same handle, two different peer_ids."""
    recs = [
        {"platform": "telegram", "peer_type": "channel", "peer_id": "111", "handle_norm": "cs2deal_chat", "observed_at": "t0", "run_id": "unit"},
        {"platform": "telegram", "peer_type": "channel", "peer_id": "222", "handle_norm": "cs2deal_chat", "observed_at": "t1", "run_id": "unit"},
    ]
    by_handle = {}
    for r in recs:
        by_handle.setdefault(r["handle_norm"], set()).add(r["peer_id"])
    conflict = {h: sorted(v) for h, v in by_handle.items() if len(v) > 1}
    ok = conflict.get("cs2deal_chat") == ["111", "222"]
    print(json.dumps({"unit": "alias_conflict", "ok": ok, "conflict": conflict}, ensure_ascii=False))


def cmd_stats(args):
    recs = load_alias()
    pairs = {(r["peer_id"], r["handle_norm"]) for r in recs}
    ids = {r["peer_id"] for r in recs}
    print(json.dumps({
        "mappings": len(recs),
        "unique_pairs": len(pairs),
        "unique_peer_ids": len(ids),
        "duplicate_rows": len(recs) - len(pairs),
    }, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["backfill", "compare", "unit", "stats"])
    ap.add_argument("--run-id")
    ap.add_argument("--now", default="")
    args = ap.parse_args()
    if args.cmd == "backfill":
        if not args.now:
            import datetime
            args.now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        cmd_backfill(args)
    elif args.cmd == "compare":
        cmd_compare(args)
    elif args.cmd == "unit":
        cmd_unit(args)
    else:
        cmd_stats(args)


if __name__ == "__main__":
    main()
