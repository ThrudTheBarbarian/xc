//xtc-na: xt6502 — this many class defs overflow the 6502 layout's .code_regions
// ^ applies to arm64, m68k, AND arm9 (no per-region code budget); only xt6502 is
//   genuinely out of scope. Was wrongly `target=arm64`, which also excluded —
//   and so hid an arm9 literal-pool failure on this large function.
// ^ xt6502 overflows the layout's .code_regions on this many class
//   definitions (Point + Big + BumpedPoint + Widget + Animal +
//   Gadget + ...) — incidental to the IR coverage this fixture
//   exercises (T1-T16: clone intrinsic, user-clone override,
//   small + large class return-by-value, auto-init). arm64 has
//   no per-region budget; the IR-path tests run cleanly there.
// stack_class.xc — regression coverage for stack-allocated class
// instances (Phase 1 Part B of doc/heap.md).
//
// Declaring a class without `new` allocates the instance's ivars in
// ZP (or a data-section spill slot for large classes) and treats the
// variable itself as the storage — no heap touch, no HP movement.
// Method calls set the self pointer to the immediate address of the
// slot, so the method body sees the stack-resident ivars via its
// normal (__self),Y access pattern. Field access compiles to direct
// addressing at `slot_base + field_offset`.
//
// The main thing this fixture verifies is that loop-reuse works:
// declaring `Point p;` inside a loop body should reuse the same ZP
// slot every iteration, with zero heap pressure and no leak. That's
// the primary motivation for the whole feature — the old behaviour
// was that `Point p = new Point();` inside a loop allocated a fresh
// heap chunk every iteration and never freed anything.

#import "Stdio.xc"

class Point
{
    u8 x;
    u8 y;

    void set(u8 nx, u8 ny) { x = nx; y = ny; }
    u8 sum(void)          { return x + y; }

    Point translate(u8 dx, u8 dy)
    {
        Point r;
        r.x = x + dx;
        r.y = y + dy;
        return r;
    }
}

// Class with a user-defined clone() — the auto-recognised
// byte-copy intrinsic must step aside and let this method run.
// Large class (> 8 bytes of ivars): exercises the __retbuf
// lowering path for class return-by-value. Has a user-defined
// clone() that bumps every field by +1 and an addAll() method
// that adds a caller-supplied delta to every field. Both return
// Big by value, so lowerLargeStructReturns prepends a hidden
// __retbuf parameter and the call sites push &dst as the first
// argument.
class Big
{
    u8 a; u8 b; u8 c; u8 d; u8 e;
    u8 f; u8 g; u8 h; u8 i;       // 9 bytes, one over the small path

    void set(u8 v)
    {
        a = v;     b = v + 1; c = v + 2;
        d = v + 3; e = v + 4; f = v + 5;
        g = v + 6; h = v + 7; i = v + 8;
    }

    Big clone(void)
    {
        Big r;
        r.a = a + 1; r.b = b + 1; r.c = c + 1;
        r.d = d + 1; r.e = e + 1; r.f = f + 1;
        r.g = g + 1; r.h = h + 1; r.i = i + 1;
        return r;
    }

    Big addAll(u8 v)
    {
        Big r;
        r.a = a + v; r.b = b + v; r.c = c + v;
        r.d = d + v; r.e = e + v; r.f = f + v;
        r.g = g + v; r.h = h + v; r.i = i + v;
        return r;
    }
}

class BumpedPoint
{
    u8 x;
    u8 y;

    void set(u8 nx, u8 ny) { x = nx; y = ny; }

    BumpedPoint clone(void)
    {
        BumpedPoint r;
        r.x = x + 100;
        r.y = y + 100;
        return r;
    }
}

// Class with an auto-init method. The compiler should emit a call
// to `init()` automatically after zero-filling a stack-allocated
// instance declared without arguments.
class Widget
{
    u8  kind;
    u16 count;

    void init(void)
    {
        kind = 42;
        count = 1000;
    }

    u16 total(void) { return count + kind; }
}

// Class with an overloaded init: parameterless, one arg, two args.
// Parameterised construction `Gadget g(args);` should pick the
// matching overload via sema's normal method-resolution rules,
// driven by the desugared `Gadget g; g.init(args);` the parser
// emits. Each overload must land via the mangled name
// (`_cls_Gadget_init__v` / `__u16` / `__u16_u16`) so the auto-init
// call from emitLocalVarDecl also needs to resolve the mangled
// form — a plain `_cls_Gadget_init` label doesn't exist when the
// init is overloaded.
class Gadget
{
    u16 a;
    u16 b;

    void init(void)           { a = 99; b = 88; }
    void init(u16 va)         { a = va; b = 0;  }
    void init(u16 va, u16 vb) { a = va; b = vb; }
}

u8 r0;
u8 r1;
u8 r2;
u8 r3;
u8 r4;

u8 e0;
u8 e1;
u8 e2;
u8 e3;
u8 e4;

u8 testCount;
u8 failCount;
u8 fails[16];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 || r4 != e4) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    // ── T1: basic stack instance + method call ────────────────
    // Declare `Point p;`, call set(10, 20), verify both fields
    // and the sum() method's return value.
    { Point p;
      p.set(10, 20);
      r0 = p.x;
      r1 = p.y;
      r2 = p.sum();
      r3 = 0; r4 = 0;
      e0 = 10; e1 = 20; e2 = 30; e3 = 0; e4 = 0; record(); }

    // ── T2: direct field writes (no method) ───────────────────
    // Bypass the setter and write the ivars directly. Verifies
    // that emitMemberAccess's assignment path handles bare-class
    // base expressions.
    { Point p;
      p.x = 5;
      p.y = 7;
      r0 = p.x;
      r1 = p.y;
      r2 = 0; r3 = 0; r4 = 0;
      e0 = 5; e1 = 7; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── T3: auto-init via parameterless init() ────────────────
    // Widget has an `init(void)` method — declaring `Widget w;`
    // should zero-fill, then call init(), leaving kind=42 and
    // count=1000. Verify both fields and the total() method.
    { Widget w;
      r0 = w.kind;            // expected 42
      r1 = w.count & $FF;     // 1000 = $03E8 → lo byte $E8
      r2 = (w.count >> 8) & $FF;  // hi byte $03
      u16 tot = w.total();    // 1000 + 42 = 1042 = $0412
      r3 = tot & $FF;
      r4 = (tot >> 8) & $FF;
      e0 = 42; e1 = $E8; e2 = $03; e3 = $12; e4 = $04; record(); }

    // ── T4: loop reuse — 10 iterations of stack instance ──────
    // The primary motivation. Each iteration declares a fresh
    // `Point p;`. The ZP allocator assigns the slot once at
    // compile time and every iteration reuses it — no heap
    // pressure, no HP movement, no leak. Sum (0+1+…+9)*3 = 135
    // via `p.set(i*3, 0); total += p.x;` as a check that the
    // slot is being written and read correctly each iteration.
    { u8 i;
      u16 total = 0;
      for (i = 0; i < 10; i = i + 1) {
          Point p;
          p.set(i * 3, 0);
          total = total + p.x;
      }
      r0 = total & $FF;       // 135 = $87
      r1 = (total >> 8) & $FF;// 0
      r2 = 0; r3 = 0; r4 = 0;
      e0 = 135; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── T5: nested scope doesn't leak state ───────────────────
    // Declaring the same-named `Point p;` in two sibling scope
    // blocks should give each block its own allocation (not
    // share). Verifies the re-declare-releases-slot path that
    // already exists in emitLocalVarDecl.
    { { Point p;
        p.set(1, 2); } }     // inner block: p dies here
    { Point p;
      p.set(100, 200);
      r0 = p.x;
      r1 = p.y;
      r2 = 0; r3 = 0; r4 = 0;
      e0 = 100; e1 = 200; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── T6: parameterless auto-init via overload (Gadget) ────
    // `Gadget g0;` should auto-call the parameterless init()
    // overload. The compiler has to pick the mangled form
    // (`init__v`) to reach the actual method body.
    { Gadget g0;
      r0 = g0.a & $FF; r1 = (g0.a >> 8) & $FF;
      r2 = g0.b & $FF; r3 = (g0.b >> 8) & $FF;
      r4 = 0;
      e0 = 99; e1 = 0; e2 = 88; e3 = 0; e4 = 0; record(); }

    // ── T7: parameterised construction, single-arg init ──────
    // `Gadget g(42);` desugars to `Gadget g; g.init(42);` with
    // constructorArgs set so auto-init is suppressed. Sema
    // picks the `init(u16)` overload. Result: a = 42, b = 0.
    { Gadget g(42);
      r0 = g.a & $FF; r1 = (g.a >> 8) & $FF;
      r2 = g.b & $FF; r3 = (g.b >> 8) & $FF;
      r4 = 0;
      e0 = 42; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── T8: parameterised construction, two-arg init ─────────
    // Same pattern with the two-arg overload. Tests that
    // overload resolution correctly distinguishes arg counts.
    { Gadget g(1000, 2000);
      r0 = g.a & $FF; r1 = (g.a >> 8) & $FF;
      r2 = g.b & $FF; r3 = (g.b >> 8) & $FF;
      r4 = 0;
      e0 = 1000 & $FF; e1 = (1000 >> 8) & $FF;
      e2 = 2000 & $FF; e3 = (2000 >> 8) & $FF;
      e4 = 0; record(); }

    // ── T9: stack-to-stack clone() ───────────────────────────
    // `Point b = a.clone();` byte-copies a's bytes into b's
    // slot. Mutating b afterwards should not affect a. Verifies
    // the auto-recognised clone() intrinsic on a stack receiver.
    { Point a;
      a.set(10, 20);
      Point b = a.clone();
      b.x = 99;
      r0 = a.x;  r1 = a.y;   // a stays 10, 20
      r2 = b.x;  r3 = b.y;   // b is now 99, 20
      r4 = 0;
      e0 = 10; e1 = 20; e2 = 99; e3 = 20; e4 = 0; record(); }

    // ── T10: heap-to-stack clone() ───────────────────────────
    // Source is `Point@ h = new Point();`, destination is a
    // fresh stack instance. Verifies the indirect-load path
    // in the clone byte-copy emitter.
    { Point* h = new Point();
      h.set(55, 77);
      Point c = h.clone();
      c.y = 200;
      r0 = h.x;  r1 = h.y;   // heap stays 55, 77
      r2 = c.x;  r3 = c.y;   // stack copy is now 55, 200
      r4 = 0;
      e0 = 55; e1 = 77; e2 = 55; e3 = 200; e4 = 0; record(); }

    // ── T11: copy-assignment form of clone() ─────────────────
    // `dst = src.clone();` after both are already declared.
    // Uses the emitAssignExpr intercept, not the decl-time
    // path. Verifies that the LHS slot is overwritten cleanly
    // and the two instances stay independent afterwards.
    { Point src;
      src.set(11, 22);
      Point dst;            // dst starts zero-filled
      dst = src.clone();    // copy-assign
      src.x = 99;           // mutate src after the clone
      r0 = dst.x;           // dst should still be 11
      r1 = dst.y;           // dst should still be 22
      r2 = src.x;           // src is now 99
      r3 = src.y;           // src.y unchanged
      r4 = 0;
      e0 = 11; e1 = 22; e2 = 99; e3 = 22; e4 = 0; record(); }

    // ── T12: user-defined clone() overrides intrinsic ────────
    // BumpedPoint defines its own clone() that adds 100 to each
    // field. The compiler should call that method instead of
    // doing a byte-copy. Both the decl-init and copy-assign
    // paths must respect the override.
    { BumpedPoint a;
      a.set(3, 4);
      BumpedPoint b = a.clone();   // decl-init, user clone runs
      r0 = a.x;  r1 = a.y;          // a stays 3, 4
      r2 = b.x;  r3 = b.y;          // b should be 103, 104
      r4 = 0;
      e0 = 3; e1 = 4; e2 = 103; e3 = 104; e4 = 0; record(); }

    // ── T13: user-defined clone() via copy-assign ────────────
    { BumpedPoint a;
      a.set(5, 6);
      BumpedPoint b;
      b = a.clone();               // copy-assign, user clone runs
      r0 = b.x;  r1 = b.y;          // 105, 106
      r2 = 0;  r3 = 0;  r4 = 0;
      e0 = 105; e1 = 106; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── T14: method returning class value (non-clone) ────────
    // `Point shifted = origin.translate(dx, dy);` — arbitrary
    // method with a class-value return type. Goes through the
    // small-class register path ($B0..$B0+N-1).
    { Point origin;
      origin.set(10, 20);
      Point shifted = origin.translate(5, 7);
      r0 = origin.x;  r1 = origin.y;  // origin unchanged
      r2 = shifted.x; r3 = shifted.y; // 15, 27
      r4 = 0;
      e0 = 10; e1 = 20; e2 = 15; e3 = 27; e4 = 0; record(); }

    // ── T15: large-class return-by-value (decl-init) ─────────
    // Big is 9 bytes, one past the small-class register path, so
    // `Big dst = src.clone();` routes through lowerLargeStructReturns
    // and the caller pushes &dst as a hidden __retbuf arg before
    // the call. Big.clone() adds 1 to every field; we sample the
    // first and last fields to verify the full 9-byte copy landed.
    { Big src;
      src.set(10);               // a..i = 10..18
      Big dst = src.clone();     // a..i = 11..19
      r0 = src.a;  r1 = src.i;   // src unchanged (10, 18)
      r2 = dst.a;  r3 = dst.i;   // dst bumped      (11, 19)
      r4 = 0;
      e0 = 10; e1 = 18; e2 = 11; e3 = 19; e4 = 0; record(); }

    // ── T16: large-class return-by-value (copy-assign) ──────
    // Same retbuf path through `dst = src.addAll(50);`, a
    // non-clone method with a class-value return.
    { Big src;
      src.set(1);                // a..i = 1..9
      Big dst;                   // zero-filled
      dst = src.addAll(50);      // a..i = 51..59
      r0 = src.a;  r1 = src.i;   // src unchanged (1, 9)
      r2 = dst.a;  r3 = dst.i;   // dst shifted   (51, 59)
      r4 = 0;
      e0 = 1; e1 = 9; e2 = 51; e3 = 59; e4 = 0; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
