// JS side of the §6 guard. Expects prog.js/prog.wasm beside it.
globalThis.xccImports = { js: { jsPing: (v) => console.log("ping " + v) } };
require("./prog.js");

function check() {
  const e = globalThis.xcc.instance.exports;
  const fail = (m) => { console.error("FAIL: " + m); process.exitCode = 1; };
  if (e.addTwo(20, 3) !== 23) fail("addTwo export");
  // task #31: overloaded extern def exports its SPELLED name, and the
  // export is the right overload (the 1-arg one).
  if (typeof e.twice !== "function") fail("twice export missing (mangled?)");
  if (e.twice(21) !== 42) fail("twice dispatches to the wrong overload");
  if (e.secretAdd(1, 2) !== 103) fail("secretAdd export (DFE root)");
  if (!e.counter) return fail("counter global export missing");
  const mem = new DataView(globalThis.xcc.memory.buffer);
  if (mem.getInt32(e.counter.value, true) !== 42) fail("counter value");
  if (process.exitCode !== 1) console.log("PASS");
}
const wait = () => (globalThis.xcc ? check() : setTimeout(wait, 10));
wait();
