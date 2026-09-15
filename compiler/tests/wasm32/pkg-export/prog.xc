// §6 guard: #package + extern generalisation (wasm-target.md).
//
//   extern + body/initialiser  = exported definition (wasm export, DFE root)
//   extern + bodyless          = import; `#package js` binds the namespace
//
// Run via run.sh — check.js supplies the `js` package through
// globalThis.xccImports and asserts the exports from the JS side.
#import "Stdio.xc"

extern i32 addTwo(i32 a, i32 b)
    {
    return a + b;
    }

// Never called from xtc — must survive DFE purely as an export root.
extern i32 secretAdd(i32 a, i32 b)
    {
    return a + b + 100;
    }

extern i32 counter = 42;

// task #31: an extern definition overloaded by an internal function still
// exports under its SPELLED name (the mangled spelling is not a name any JS
// caller wrote). The internal overload keeps its mangled symbol.
i32 twice(i32 a, i32 b)
    {
    return (a + b) * 2;
    }
extern i32 twice(i32 v)
    {
    return v * 2;
    }

#package js
extern void jsPing(i32 v);

void main()
    {
    jsPing(7);
    Stdio.printf("%d\n", (u16)addTwo(20, 3));
    Stdio.printf("%d\n", (u16)twice(10, 1)); // internal overload: 22
    Stdio.printf("%d\n", (u16)twice(11));    // via the exported one: 22
    }
