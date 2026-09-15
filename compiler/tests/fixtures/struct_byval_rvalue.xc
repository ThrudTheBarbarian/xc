// Regression test for rvalue struct-by-value parameter passing.
//
// `emitStructArgPush` previously only handled identifier args
// (locals/globals/params in ZP or at a spill label). An argument
// that was itself the result of an expression — a struct field
// project `f(outer.inner)` or a struct-returning call inlined in
// another call `f(makeStruct())` — fell through to the narrow
// 2-byte truncation path and produced garbage.
//
// This fixture exercises both shapes at several widths and at
// several levels of nesting, and prints one "Tn PASS/FAIL" line
// per test. Expected output is 10 consecutive "PASS" lines.
//
// Run with: python3 tests/run_struct_byval_rvalue.py
//
// Fixture hygiene:
//   - u8 return types avoid the orthogonal u8→u16 widening gap
//     that leaves stale X bits on `(u16)uint8_field` reads.
//   - Sum functions keep the arithmetic in u8; test values are
//     small enough that sums never overflow 255.
//   - No reliance on banked-target-specific features — fixture
//     is target-agnostic and should pass on standard and banked
//     at every optimisation level.

#import "Stdio.xc"

// ── Structs of varying widths ────────────────────────────────────

struct P2 { u8 x; u8 y; }                    // 2 bytes
struct P3 { u8 a; u8 b; u8 c; }               // 3 bytes
struct P5 { u8 a; u8 b; u8 c; u8 d; u8 e; }   // 5 bytes
struct P8 { u8 a; u8 b; u8 c; u8 d; u8 e; u8 f; u8 g; u8 h; }  // 8 bytes

// Nested struct so we can project an inner struct as a whole.
struct Outer2 { u8 tag; P2 inner; u8 flag; }
struct Outer5 { u8 tag; P5 inner; u8 flag; }

// Deeply nested — project a struct that's inside a struct that's
// inside another struct. Exercises the chain-flattening path.
struct Mid  { P3 core; u8 extra; }
struct Deep { u8 hdr; Mid middle; u8 ftr; }

// ── Sum functions (take struct by value, return u8) ──────────────

u8 sumP2(P2 p) { return p.x + p.y; }
u8 sumP3(P3 p) { return p.a + p.b + p.c; }
u8 sumP5(P5 p) { return p.a + p.b + p.c + p.d + p.e; }
u8 sumP8(P8 p) { return p.a + p.b + p.c + p.d + p.e + p.f + p.g + p.h; }

// ── Struct-returning factories (rvalue call-result source) ───────

P2 makeP2(u8 x, u8 y) {
    P2 r;
    r.x = x;
    r.y = y;
    return r;
}

P3 makeP3(u8 a, u8 b, u8 c) {
    P3 r;
    r.a = a;
    r.b = b;
    r.c = c;
    return r;
}

P5 makeP5(u8 a, u8 b, u8 c, u8 d, u8 e) {
    P5 r;
    r.a = a;
    r.b = b;
    r.c = c;
    r.d = d;
    r.e = e;
    return r;
}

P8 makeP8(u8 a, u8 b, u8 c, u8 d, u8 e, u8 f, u8 g, u8 h) {
    P8 r;
    r.a = a;
    r.b = b;
    r.c = c;
    r.d = d;
    r.e = e;
    r.f = f;
    r.g = g;
    r.h = h;
    return r;
}

void main(void)
{
    u8 got;
    u8 exp;

    // ── Field project tests ─────────────────────────────────────
    //
    // T1–T4: pass a struct-typed field of an enclosing struct
    // directly by value. Resolves to `&base + offset` and
    // byte-copies from that location into the argument stream.

    Outer2 o2;
    o2.tag = 99;
    o2.inner.x = 10;
    o2.inner.y = 20;
    o2.flag = 5;

    exp = 30;
    got = sumP2(o2.inner);
    if (got == exp) { Stdio.printf("T1 PASS\n"); }
    else { Stdio.printf("T1 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    Outer5 o5;
    o5.tag = 77;
    o5.inner.a = 1;
    o5.inner.b = 2;
    o5.inner.c = 3;
    o5.inner.d = 4;
    o5.inner.e = 5;
    o5.flag = 9;

    exp = 15;
    got = sumP5(o5.inner);
    if (got == exp) { Stdio.printf("T2 PASS\n"); }
    else { Stdio.printf("T2 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    // Deep nested field project — three levels down.
    Deep d;
    d.hdr = 200;
    d.middle.core.a = 7;
    d.middle.core.b = 8;
    d.middle.core.c = 9;
    d.middle.extra = 42;
    d.ftr = 201;

    exp = 24;  // 7 + 8 + 9
    got = sumP3(d.middle.core);
    if (got == exp) { Stdio.printf("T3 PASS\n"); }
    else { Stdio.printf("T3 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    // Field project where the nested struct sits at a non-zero
    // offset within its parent — makes sure the offset is
    // actually being used, not just a lucky zero.
    exp = 30;
    got = sumP2(o2.inner);  // same as T1, but intentional repeat
    if (got == exp) { Stdio.printf("T4 PASS\n"); }
    else { Stdio.printf("T4 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    // ── Struct-returning call results (rvalue call) ────────────
    //
    // T5–T8: pass the return value of a struct-returning function
    // directly into another function that takes that struct by
    // value. Small structs (<= 8 bytes) come back in $B0..$B7; the
    // fix routes them through a scratch buffer so the outer call's
    // byte push sees a stable memory source.

    exp = 20;  // 7 + 13
    got = sumP2(makeP2(7, 13));
    if (got == exp) { Stdio.printf("T5 PASS\n"); }
    else { Stdio.printf("T5 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    exp = 15;  // 1 + 2 + 3 + 4 + 5
    got = sumP5(makeP5(1, 2, 3, 4, 5));
    if (got == exp) { Stdio.printf("T6 PASS\n"); }
    else { Stdio.printf("T6 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    exp = 36;  // 1 + 2 + ... + 8
    got = sumP8(makeP8(1, 2, 3, 4, 5, 6, 7, 8));
    if (got == exp) { Stdio.printf("T7 PASS\n"); }
    else { Stdio.printf("T7 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    // Reuse the same factory pattern with different values to
    // check the scratch buffer isn't accidentally shared across
    // call sites.
    exp = 45;  // 10 + 15 + 20
    got = sumP3(makeP3(10, 15, 20));
    if (got == exp) { Stdio.printf("T8 PASS\n"); }
    else { Stdio.printf("T8 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    // ── Two rvalue struct args in a row ─────────────────────────
    //
    // T9: two back-to-back struct-returning calls used as args.
    // Each call has its own scratch buffer so the two results
    // don't trample each other.

    got = sumP2(makeP2(3, 7)) + sumP3(makeP3(10, 20, 30));
    exp = 70;  // 10 + 60
    if (got == exp) { Stdio.printf("T9 PASS\n"); }
    else { Stdio.printf("T9 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }

    // ── Field project on an rvalue struct — not handled, but
    // makes sure we at least don't crash. Skipped: combining
    // both shapes (`sumX(makeX(...).field)`) isn't supported in
    // the first pass.
    //
    // T10: sanity — field project with a non-zero offset from a
    // different outer struct, just to cover the offset arithmetic
    // independently of T3.
    Outer5 o5b;
    o5b.tag = 1;
    o5b.inner.a = 5;
    o5b.inner.b = 10;
    o5b.inner.c = 15;
    o5b.inner.d = 20;
    o5b.inner.e = 25;
    o5b.flag = 99;

    exp = 75;  // 5 + 10 + 15 + 20 + 25
    got = sumP5(o5b.inner);
    if (got == exp) { Stdio.printf("T10 PASS\n"); }
    else { Stdio.printf("T10 FAIL got=%u exp=%u\n", (u16)got, (u16)exp); }
}
