// Minimal Node host for the ir-codegen-wasm32 fixtures.
// Usage: node runner.js <module.wasm>
// Provides one output primitive — putw(i32) prints the value as a line —
// plus putc, so fixtures need no standard library. Any other import
// throws with its name (the same fail-loud contract as the real loader).
const fs = require("fs");
const bytes = fs.readFileSync(process.argv[2]);
let line = [];
const flush = () => {
  if (line.length) { process.stdout.write(String.fromCharCode(...line)); line = []; }
};
const putc = (c) => { line.push(c & 0xFF); if ((c & 0xFF) === 10) flush(); };
const env = new Proxy({
  putc, _putc: putc,
  putw: (v) => process.stdout.write((v | 0) + "\n"),
}, {
  get(t, name) {
    if (name in t) return t[name];
    return () => { throw new Error("missing env." + String(name)); };
  },
});
WebAssembly.instantiate(bytes, { env }).then(({ instance }) => {
  const rc = instance.exports.main();
  flush();
  process.exitCode = rc | 0;
}).catch((e) => { console.error(e); process.exitCode = 70; });
