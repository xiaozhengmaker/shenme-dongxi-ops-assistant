# -*- coding: utf-8 -*-
"""旁路别名对历史群记录的覆盖率（只读，不改任何数据）。"""
import sqlite3, json, io, argparse

def norm(h):
    return str(h or "").strip().lstrip("@").lower()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=r"D:\DeepSeek\运营\data\groupops.db")
    ap.add_argument("--alias", default=r"D:\DeepSeek\运营\data\tg_alias_shadow.jsonl")
    ap.add_argument("--out", default=r"D:\DeepSeek\运营\data\tg_alias_coverage.json")
    a = ap.parse_args()

    alias = {}
    for ln in io.open(a.alias, "r", encoding="utf-8"):
        ln = ln.strip()
        if not ln:
            continue
        o = json.loads(ln)
        if o.get("platform") != "telegram":
            continue
        h = norm(o.get("handle_norm"))
        if not h:
            continue
        pid = str(o.get("peer_id") or "")
        alias.setdefault(h, set()).add(pid)

    con = sqlite3.connect(a.db)
    rows = [str(r[0]) for r in con.execute("SELECT native_group_id FROM groups WHERE platform='Telegram'")]
    numeric = [r for r in rows if r.isdigit()]
    handle = [r for r in rows if not r.isdigit()]

    covered, conflict, covered_pairs = [], [], []
    for g in handle:
        h = norm(g)
        if h in alias:
            covered.append(g)
            pids = alias[h]
            covered_pairs.append({"handle": h, "peer_ids": sorted(pids)})
            if len(pids) > 1:
                conflict.append(h)

    res = {
        "historical_groups": len(rows),
        "historical_numeric": len(numeric),
        "historical_handle_only": len(handle),
        "numeric_ratio": round(len(numeric) / len(rows), 4) if rows else 0,
        "alias_handles": len(alias),
        "covered_handle_groups": len(covered),
        "coverage_of_handle_groups": round(len(covered) / len(handle), 4) if handle else 0,
        "coverage_of_all_groups": round(len(covered) / len(rows), 4) if rows else 0,
        "alias_conflicts": len(conflict),
        "conflict_handles": conflict,
        "covered": covered_pairs,
    }
    io.open(a.out, "w", encoding="utf-8").write(json.dumps(res, ensure_ascii=False, indent=2))
    print(json.dumps({k: v for k, v in res.items() if k != "covered"}, ensure_ascii=False))

if __name__ == "__main__":
    main()