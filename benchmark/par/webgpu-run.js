// webgpu-run.js <port> <url> <expected-lines> — open <url> in the headless
// Chrome listening for DevTools on <port>, wait in REAL time (virtual time
// stalls WebGPU's callbacks) until the page's <pre id=o> stops growing with at
// least <expected-lines> lines, or 60 s, and print its text.
const [port, url, want] = [process.argv[2], process.argv[3], +(process.argv[4] || 1)];
(async () => {
  const t = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: "PUT" })).json();
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0; const pend = new Map();
  ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } });
  const call = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  let text = "", last = "", still = 0;
  for (let k = 0; k < 240; k++) {
    await new Promise((r) => setTimeout(r, 250));
    const r = await call("Runtime.evaluate", { expression: "document.getElementById('o') ? document.getElementById('o').textContent : ''", returnByValue: true });
    text = (r.result && r.result.result && r.result.result.value) || "";
    const lines = text.split("\n").filter((l) => l && !l.startsWith("LOG ") && !l.startsWith("ERR ")).length;
    still = text === last ? still + 1 : 0;
    last = text;
    if (lines >= want && still >= 6) break;
  }
  process.stdout.write(text);
  await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => {});
  ws.close();
})().catch((e) => { console.error(e); process.exit(1); });
