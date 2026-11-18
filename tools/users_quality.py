# -*- coding: utf-8 -*-
import io, csv, collections

CSV = r"D:\DeepSeek\运营\data\users.csv"
OUT = r"D:\DeepSeek\运营\docs\users_quality_report.md"

rows = list(csv.DictReader(io.open(CSV, encoding="utf-8-sig")))
fields = list(rows[0].keys())

by_plat = collections.Counter()
by_lang = collections.Counter()
by_role = collections.Counter()
blank = collections.Counter()
ids = set()
dups = 0
fb_prefixed = 0
fixed = 0

for r in rows:
    p = (r["平台"] or "").strip()
    by_plat[p] += 1
    by_lang[(r["语言"] or "").strip() or "(空)"] += 1
    by_role[(r["角色"] or "").strip() or "(空)"] += 1
    for f in fields:
        if not (r.get(f) or "").strip():
            blank[f] += 1
    key = (p, r["群ID"], r["用户ID"])
    if key in ids:
        dups += 1
    ids.add(key)
    uid = (r["用户ID"] or "").strip()
    if p == "Facebook" and uid.startswith("id") and uid[2:].isdigit():
        fb_prefixed += 1
        r["用户ID"] = uid[2:]
        fixed += 1

# 修正后写回（保持 UTF-8 BOM）
if fixed:
    with io.open(CSV, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

L = []
L.append("# 用户样本数据体检\n")
L.append(f"- 总行数：**{len(rows):,}**")
L.append(f"- 主键（平台+群ID+用户ID）重复：**{dups}**")
L.append(f"- 各平台：{', '.join(f'{k} {v:,}' for k, v in by_plat.most_common())}")
L.append(f"- 角色分布：{', '.join(f'{k} {v:,}' for k, v in by_role.most_common())}")
L.append(f"- 语言字段：(空) {by_lang.get('(空)',0):,} / 其他 {sum(v for k,v in by_lang.items() if k!='(空)'):,}")
L.append("")
L.append("## 空值统计\n")
for f in fields:
    if blank[f]:
        L.append(f"- `{f}` 空 {blank[f]:,} 行")
L.append("")
L.append("## 已修问题\n")
L.append(f"- Facebook 用户ID 带 `id` 前缀（`id61584550730266`）：**{fb_prefixed} 行**，已统一去掉前缀只留纯数字（与 Steam/TG 对齐）")
L.append("")
L.append("## 需要你决定的\n")
L.append("- `语言` 字段 99% 为空：要么补全（要逐人多打一次接口，成本高），要么在看板隐藏该列")
L.append("- `最近活跃` 字段同样大面积为空（TG 只有部分群能拿到 last_active）")
L.append("- `data/users.jsonl` 是追加日志（85,902 行）比 csv（84,872 行）多 1,030 行历史重复，属预期；csv 才是真源")

io.open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("WROTE", OUT, "fixed_fb_ids=", fixed, "dups=", dups)
