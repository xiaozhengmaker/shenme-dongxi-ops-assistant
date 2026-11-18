# -*- coding: utf-8 -*-
"""26 条判重任候选的离线 mutli-source 归因（只读，不发任何平台请求）。

来源：
  pool       data/pool_telegram.json
  known      data/tg_known.json（DB 导出的已加入 handle 名单）
  db         data/groupops.db groups 表（历史群）
  alias      data/tg_alias_shadow.jsonl（旁路稳定 ID）
  feishu     data/fs_groups_snapshot.json（若有；缺则标 source_unverifiable）
"""
import json, io, sqlite3, os, argparse
from collections import OrderedDict

BASE = r"D:\DeepSeek\运行占位"  # replaced below


def norm(h):
    return str(h or "").strip().lstrip("@").lower()


def load_json(p, default=None):
    if not os.path.exists(p):
        return default
    try:
        return json.loads(io.open(p, "r", encoding="utf-8-sig").read())
    except Exception:
        return default


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=r"D:\DeepSeek\运营")
    ap.add_argument("--run", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    base = a.base
    data = os.path.join(base, "data")

    snaps = [f for f in os.listdir(data) if f.startswith("tg_links_snapshot_")]
    snaps.sort(key=lambda f: os.path.getmtime(os.path.join(data, f)), reverse=True)
    snap_path = os.path.join(data, snaps[0])
    snap = load_json(snap_path, {})
    run_id = a.run or snap.get("run_id", "")
    taken_at = snap.get("taken_at", "")

    rejects = []
    rp = os.path.join(data, "tg_rejects.jsonl")
    if os.path.exists(rp):
        for ln in io.open(rp, "r", encoding="utf-8"):
            ln = ln.strip()
            if not ln:
                continue
            try:
                o = json.loads(ln)
            except Exception:
                continue
            if o.get("run_id") == run_id and "dup" in (o.get("reasons") or []):
                rejects.append(o)

    # 去重：同一 u 只保留最后一次
    uniq = OrderedDict()
    for r in rejects:
        uniq[norm(r.get("u"))] = r
    cands = list(uniq.values())

    pool = load_json(os.path.join(data, "pool_telegram.json"), {"items": []}) or {"items": []}
    pool_by_u, pool_by_id = {}, {}
    for it in pool.get("items") or []:
        if it.get("u"):
            pool_by_u[norm(it["u"])] = it
        if it.get("id"):
            pool_by_id[str(it["id"])] = it

    known = load_json(os.path.join(data, "tg_known.json"), []) or []
    known_set = set(norm(x) for x in known)

    db_rows = {}
    dbp = os.path.join(data, "groupops.db")
    if os.path.exists(dbp):
        con = sqlite3.connect(dbp)
        for gid, gname in con.execute("SELECT native_group_id, group_name FROM groups WHERE platform='Telegram'"):
            db_rows[str(gid)] = gname
        con.close()
    db_ids = set(k for k in db_rows if k.isdigit())
    db_handles = set(norm(k) for k in db_rows if not k.isdigit())

    alias_by_handle, alias_by_pid = {}, {}
    apath = os.path.join(data, "tg_alias_shadow.jsonl")
    if os.path.exists(apath):
        for ln in io.open(apath, "r", encoding="utf-8"):
            ln = ln.strip()
            if not ln:
                continue
            try:
                o = json.loads(ln)
            except Exception:
                continue
            if o.get("handle_norm"):
                alias_by_handle[norm(o["handle_norm"])] = o
            if o.get("peer_id"):
                alias_by_pid[str(o["peer_id"])] = o

    fs_path = os.path.join(data, "fs_groups_snapshot.json")
    fs_snapshot_ok = os.path.exists(fs_path)
    fs_handles, fs_ids = set(), set()
    if fs_snapshot_ok:
        fs = load_json(fs_path, []) or []
        for r in fs:
            if r.get("平台") != "Telegram":
                continue
            k = str(r.get("群ID") or "")
            g = str(r.get("群链接") or "")
            if k.isdigit():
                fs_ids.add(k)
            if k:
                fs_handles.add(norm(k))
            if "/" in g:
                fs_handles.add(norm(g.rstrip("/").split("/")[-1]))

    rows = []
    for r in cands:
        u = norm(r.get("u"))
        pid = str(r.get("id") or "")
        hits = []

        def add(src, key):
            hits.append({"source": src, "match_key": key})

        if u in pool_by_u:
            add("pool", "handle:" + u)
        if pid and pid in pool_by_id:
            add("pool", "id:" + pid)
        if u in known_set:
            add("known", "handle:" + u)
        if pid and pid in db_ids:
            add("db", "id:" + pid)
        if u in db_handles:
            add("db", "handle:" + u)
        if u in alias_by_handle:
            add("alias", "handle:" + u)
        if pid and pid in alias_by_pid:
            add("alias", "id:" + pid)
        if fs_snapshot_ok:
            if u in fs_handles:
                add("feishu", "handle:" + u)
            if pid and pid in fs_ids:
                add("feishu", "id:" + pid)

        sources = []
        for h in hits:
            if h["source"] not in sources:
                sources.append(h["source"])
        if not fs_snapshot_ok and not sources:
            status = "source_unverifiable"
        elif sources:
            status = "matched"
        else:
            status = "unreproducible"

        rows.append({
            "target_id": u,
            "peer_id": pid,
            "title": r.get("t"),
            "n": r.get("n"),
            "hits": r.get("hits"),
            "matched_sources": sources,
            "match_details": hits,
            "status": status,
            "current_mapping": None,
            "historical_identity_verified": False,
            "snapshot_at": taken_at,
        })
        if u in alias_by_handle or (pid and pid in alias_by_pid):
            a0 = alias_by_handle.get(u) or alias_by_pid.get(pid)
            rows[-1]["current_mapping"] = {"peer_id": a0.get("peer_id"), "observed_at": a0.get("observed_at")}

    counts = {}
    for r in rows:
        for s in r["matched_sources"]:
            counts[s] = counts.get(s, 0) + 1
    combos = {}
    for r in rows:
        key = "+".join(sorted(r["matched_sources"])) if r["matched_sources"] else ("source_unverifiable" if r["status"] == "source_unverifiable" else "unreproducible")
        combos[key] = combos.get(key, 0) + 1

    out = {
        "run_id": run_id,
        "snapshot": os.path.basename(snap_path),
        "snapshot_at": taken_at,
        "candidates": len(rows),
        "source_hits": counts,
        "combo_counts": combos,
        "combo_total": sum(combos.values()),
        "feishu_snapshot": bool(fs_snapshot_ok),
        "rows": rows,
    }
    outp = a.out or os.path.join(data, "tg_matched_sources.json")
    io.open(outp, "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=2))
    print(json.dumps({k: out[k] for k in ("run_id", "candidates", "source_hits", "combo_counts", "combo_total", "feishu_snapshot")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
