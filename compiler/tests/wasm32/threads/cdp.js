// cdp.js <url> <seconds> <debug-port>: load a page in a running headless
// Chrome, wait in real time, print the text of #o.
const [url, secs, port] = process.argv.slice(2);
(async () => {
  const list = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
  const ws = new WebSocket(list.webSocketDebuggerUrl);
  let id = 0; const pending = new Map();
  const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result); pending.delete(d.id); } };
  await new Promise((r) => ws.onopen = r);
  await send("Page.enable");
  await send("Page.navigate", { url });
  await new Promise((r) => setTimeout(r, Number(secs) * 1000));
  const r = await send("Runtime.evaluate", { expression: "document.getElementById('o').textContent" });
  console.log(r.result.value);
  ws.close();
  process.exit(0);
})();
