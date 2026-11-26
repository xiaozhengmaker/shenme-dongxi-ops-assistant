const $ = (id) => document.getElementById(id);

// 运行入口只在扩展侧栏（side panel）：本弹窗只显示状态，不提供启动/停止，避免第二个入口。
async function refresh() {
  const s = await chrome.storage.local.get(["running", "stats", "lastLog"]);
  const running = !!s.running;
  const stats = s.stats || { joined: 0, failed: 0, skipped: 0 };
  $("state").textContent = running ? "运行中" : "未运行";
  $("state").style.color = running ? "#128a3f" : "#8a919b";
  $("joined").textContent = stats.joined;
  $("bad").textContent = stats.skipped + " / " + stats.failed;
  $("log").textContent = s.lastLog || "";
}

$("opts").onclick = () => chrome.runtime.openOptionsPage();
setInterval(refresh, 1500);
refresh();
