const DEFAULT = {
  version: 1,
  hub: "http://127.0.0.1:8787",
  platforms: ["Telegram", "Facebook"],
  quotas: { Telegram: 20, Facebook: 5 },
  filters: {
    min_members: { Telegram: 300, Facebook: 1000 },
    skip_channels: true,
    skip_verification: true,
    exclude_title_regex: "(?i)(airdrop|pixelverse|xdao|earn|shop|магазин|news|bot)"
  },
  pacing: {
    join_gap_sec: [45, 180],
    search_gap_sec: [3, 8],
    stay_on_group_sec: [20, 60],
    max_consecutive_failures: 3,
    join_retry: 2,
    retry_gap_min: 5
  },
  queries: {
    Telegram: ["cs2 trade", "cs2 skins", "cs2 market", "cs2 chat", "csgo trade",
                "cs2 community", "cs2 russia", "кс 2 чат", "cs2 giveaway", "cs2 faceit"],
    Facebook: ["cs2 trade", "csgo trading", "cs2 skins trade"]
  },
  report: { title: "社群日报", platform_order: ["Facebook", "Telegram", "Discord"], card_color: "indigo" }
};

const $ = (id) => document.getElementById(id);

async function load() {
  const s = await chrome.storage.local.get(["config"]);
  const cfg = s.config || DEFAULT;
  $("cfg").value = JSON.stringify(cfg, null, 2);
}

function parse() {
  return JSON.parse($("cfg").value);
}

$("save").onclick = async () => {
  try {
    const cfg = parse();
    await chrome.storage.local.set({ config: cfg });
    $("msg").textContent = "已保存";
    $("msg").className = "";
  } catch (e) {
    $("msg").textContent = "JSON 解析失败：" + e.message;
    $("msg").className = "err";
  }
};

$("export").onclick = () => {
  try {
    const cfg = parse();
    const blob = new Blob([JSON.stringify(cfg, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    chrome.downloads.download({ url, filename: "config.json", saveAs: true });
    $("msg").textContent = "已导出";
    $("msg").className = "";
  } catch (e) {
    $("msg").textContent = "JSON 解析失败：" + e.message;
    $("msg").className = "err";
  }
};

$("reset").onclick = () => {
  $("cfg").value = JSON.stringify(DEFAULT, null, 2);
  $("msg").textContent = "已填入默认值（记得保存）";
  $("msg").className = "";
};

load();
