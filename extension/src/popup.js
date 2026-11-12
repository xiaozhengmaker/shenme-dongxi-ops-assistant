const $ = (id) => document.getElementById(id);

async function refresh() {
  const s = await chrome.storage.local.get(["running", "stats", "lastLog"]);
  const running = !!s.running;
  const stats = s.stats || { joined: 0, failed: 0, skipped: 0 };
  $("state").textContent = running ? "运行中" : "未运行";
  $("state").style.color = running ? "#128a3f" : "#8a919b";
  $("joined").textContent = stats.joined;
  $("bad").textContent = stats.skipped + " / " + stats.failed;
  $("log").textContent = s.lastLog || "";
  $("start").disabled = running;
  $("stop").disabled = !running;
}

$("start").onclick = () => chrome.runtime.sendMessage({ type: "start" }, refresh);
$("stop").onclick = () => chrome.runtime.sendMessage({ type: "stop" }, refresh);
$("opts").onclick = () => chrome.runtime.openOptionsPage();
setInterval(refresh, 1500);
refresh();
