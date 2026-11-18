# -*- coding: utf-8 -*-
import sqlite3, json, io
con = sqlite3.connect(r"D:\DeepSeek\运营\data\groupops.db")
rows = [str(r[0]) for r in con.execute("SELECT native_group_id FROM groups WHERE platform='Telegram'")]
num = sum(1 for r in rows if r.isdigit())
h = sum(1 for r in rows if r.startswith("@"))
out = {"total": len(rows), "numeric": num, "handle_only": h}
io.open(r"D:\DeepSeek\运营\data\tg_db_identity_split.json", "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False))
print(json.dumps(out, ensure_ascii=True))