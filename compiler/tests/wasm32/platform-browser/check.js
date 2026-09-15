// Guard for the platform-neutral surface on wasm32 (task #36). Stubs global
// fetch (200+body for /ok, transport reject for /fail) and asserts both
// completions arrive through _xt_browser_dispatch into the app's blocks,
// with the browser console as the logger. Expects app.js/app.wasm beside it.
const lines = [];
const realLog = console.log;
console.log = (s) => lines.push(String(s));
console.error = (s) => lines.push("ERR:" + String(s));
globalThis.fetch = (u) => String(u).endsWith("/ok")
  ? Promise.resolve({ status: 200,
      arrayBuffer: () => Promise.resolve(new TextEncoder().encode("payload").buffer) })
  : Promise.reject(new Error("transport"));
require("./app.js");

const t0 = Date.now();
function check() {
  if (lines.length < 3) {
    if (Date.now() - t0 > 5000) {
      console.log = realLog;
      console.error("FAIL: timeout, got: " + JSON.stringify(lines));
      process.exit(1);
    }
    return setTimeout(check, 10);
  }
  console.log = realLog;
  const want = ["boot", "payload", "fail-ok"];
  if (JSON.stringify(lines) !== JSON.stringify(want)) {
    console.error("FAIL: " + JSON.stringify(lines));
    process.exit(1);
  }
  console.log("PASS");
}
check();
