// bidi.js <url> <seconds> <port>: Firefox over WebDriver BiDi; print #o.
const [url, secs, port] = process.argv.slice(2);
(async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/session`);
  let id = 0; const pending = new Map();
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, [res, rej]); ws.send(JSON.stringify({ id: i, method, params })); });
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { const [res, rej] = pending.get(d.id); pending.delete(d.id); d.type === "error" ? rej(new Error(d.error + ": " + d.message)) : res(d.result); } };
  await new Promise((r) => ws.onopen = r);
  await send("session.new", { capabilities: {} });
  const tree = await send("browsingContext.getTree", {});
  const ctx = tree.contexts[0].context;
  await send("browsingContext.navigate", { context: ctx, url, wait: "complete" });
  await new Promise((r) => setTimeout(r, Number(secs) * 1000));
  const r = await send("script.evaluate", { expression: "document.getElementById('o').textContent", target: { context: ctx }, awaitPromise: false });
  console.log(r.result.value);
  process.exit(0);
})().catch((e) => { console.log("BIDI ERROR " + e.message); process.exit(1); });
