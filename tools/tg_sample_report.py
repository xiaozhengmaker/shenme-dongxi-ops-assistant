# -*- coding: utf-8 -*-
import io, re, json, urllib.request, collections

LOG = r"D:\DeepSeek\运营\logs\tg_members.log"
HOOK = "https://open.feishu.cn/open-apis/bot/v2/hook/bdb42028-231b-42ff-8b94-810cc965a6f9"

# 解析：start key / peer(name,total) / finish collected / skip hidden
cur = None
groups = {}
order = []
hidden = set()
for line in io.open(LOG, encoding="utf-8", errors="replace"):
    m = re.search(r"\[sampler\] start key=@(\S+)", line)
    if m:
        cur = m.group(1)
        if cur not in groups:
            groups[cur] = {"key": cur, "name": "", "total": 0, "collected": 0, "hidden": False}
            order.append(cur)
        continue
    m = re.search(r"\[sampler\] peer=(.+?) kind=\w+ total=(\d+)", line)
    if m and cur:
        groups[cur]["name"] = m.group(1).strip()
        groups[cur]["total"] = int(m.group(2))
        continue
    m = re.search(r"\[sampler\] finish key=@(\S+) collected=(\d+)", line)
    if m:
        k = m.group(1)
        if k in groups:
            groups[k]["collected"] = max(groups[k]["collected"], int(m.group(2)))
        continue
    m = re.search(r"\[skip\] 跳过 (\S+)（members_hidden", line)
    if m:
        hidden.add(m.group(1))

rows = [groups[k] for k in order]
for r in rows:
    if r["key"] in hidden:
        r["hidden"] = True

sample_ok = [r for r in rows if r["collected"] > 0]
zero = [r for r in rows if r["collected"] == 0]
hidden_rows = [r for r in rows if r["hidden"]]
total_users = sum(r["collected"] for r in rows)

top = sorted(sample_ok, key=lambda r: -r["collected"])[:10]

def fmt(n):
    return f"{n:,}"

# 本地明细
out = io.open(r"D:\DeepSeek\运营\data\tg_sample_report.csv", "w", encoding="utf-8-sig", newline="")
out.write("群用户名,群名,总人数,采到人数,状态\n")
for r in sorted(rows, key=lambda x: -x["collected"]):
    st = "隐藏成员" if r["hidden"] else ("有产出" if r["collected"] > 0 else "名单不可见")
    out.write(f'{r["key"]},"{r["name"]}",{r["total"]},{r["collected"]},{st}\n')
out.close()

lines = []
lines.append(f"**群数** {len(rows)}")
lines.append(f"**采到人的群** {len(sample_ok)}  ·  **零产出** {len(zero)}（其中隐藏成员 {len(hidden_rows)}）")
lines.append(f"**本轮采集** {fmt(total_users)} 人")
lines.append("")
lines.append("**Top 10 群**")
for r in top:
    nm = r["name"][:22] or r["key"]
    lines.append(f'· {nm} — 采 {fmt(r["collected"])} / 共 {fmt(r["total"])}')

body = {
    "msg_type": "interactive",
    "card": {
        "config": {"wide_screen_mode": True},
        "header": {"template": "indigo", "title": {"tag": "plain_text", "content": "Telegram 成员采样报告"}},
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(lines)}},
            {"tag": "note", "elements": [{"tag": "plain_text", "content": "明细见 data/tg_sample_report.csv"}]},
        ],
    },
}
req = urllib.request.Request(
    HOOK,
    data=json.dumps(body).encode("utf-8"),
    headers={"Content-Type": "application/json; charset=utf-8"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    print("webhook =>", resp.read().decode("utf-8"))

print("rows=", len(rows), "sample_ok=", len(sample_ok), "zero=", len(zero), "hidden=", len(hidden_rows), "users=", total_users)
