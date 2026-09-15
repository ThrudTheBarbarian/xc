// small_struct_member_return.xc — `return x.field` /
// `return p->field` / `return a.b.c` where the returned
// expression is a small struct (≤ 8 bytes).
//
// Before this landing emitStructExprToB0 handled three
// expression kinds directly (subscript, call, identifier)
// and fell through to `emitExprToA` for anything else.
// For member-access bases the fallback routed into
// emitMemberAccess — which uses the scalar register
// conventions:
//   • width 1 → A
//   • width 2 → A/X
//   • width 4 → A/X/_u32HiReg (u32 convention)
//   • width 5-8 → $B0..$B(N-1) (float/struct convention)
//
// The struct-return caller always reads from $B0..$B(N-1),
// so widths 1-4 silently mismatched. Widths 3-4 struct
// returns through either an identifier base OR a pointer
// base came back with bytes 0-1 in A/X and bytes 2-3 in
// _u32HiReg — which isn't $B2/$B3 on most layouts. Width
// 5-8 through a pointer base fell through the 2-byte A/X
// path and bytes 2..N-1 read as garbage.
//
// Fix: emitStructExprToB0 now handles XTMemberAccessNode
// directly. It walks the chain (field offsets accumulate,
// stops at the first non-struct base), then emits byte-
// wise loads to $B0..$B(width-1) per the caller's
// contract. Identifier leaves go through absolute
// addressing (ZP or spill label). Pointer leaves load the
// pointer into zpTmp and read through `(zpTmp),Y`. Banked
// targets fall through — that's a Phase 4 banked ARC
// concern.
//
// emitMemberAccess's pointer-base path also learns
// widths 5-8 → $B0..$B(N-1) for the general case
// (independent of struct return context) since the
// scalar float-field read through a pointer has the
// same $B0..$B4 contract.

#import "Stdio.xc"
#import "Assert.xc"

// 5-byte leaf struct.
struct Leaf { u8 a; u8 b; u8 c; u8 d; u8 e; }

// 4-byte struct for the width-4 branch.
struct Four { u16 a; u16 b; }

// Nested containers.
struct Mid   { u16 pad; Leaf leaf; u16 tag; }
struct Outer { u16 head; Mid  mid;  }
struct OuterFour { u16 head; Four four; }

// ── Identifier base ───────────────────────────────────────
Leaf getLeafFromOuter(Outer o)
{
    return o.mid.leaf;                                    // width 5, identifier+chain
}

Four getFourFromOuter(OuterFour o)
{
    return o.four;                                        // width 4, identifier+chain
}

// ── Pointer base (flat, non-banked) ───────────────────────
Leaf getLeafPtr(Outer* p)
{
    return p->mid.leaf;                                   // width 5, pointer+chain
}

Four getFourPtr(OuterFour* p)
{
    return p->four;                                       // width 4, pointer+chain
}

void main(void)
{
    Assert.reset();

    // ── Identifier bases ──────────────────────────────────
    Outer o;
    o.mid.leaf.a = 1;
    o.mid.leaf.b = 2;
    o.mid.leaf.c = 3;
    o.mid.leaf.d = 4;
    o.mid.leaf.e = 5;

    Leaf r = getLeafFromOuter(o);
    Assert.isEqual((u16)r.a, 1);                          // T1
    Assert.isEqual((u16)r.b, 2);                          // T2
    Assert.isEqual((u16)r.c, 3);                          // T3
    Assert.isEqual((u16)r.d, 4);                          // T4
    Assert.isEqual((u16)r.e, 5);                          // T5

    OuterFour of;
    of.four.a = 100;
    of.four.b = 200;

    Four f = getFourFromOuter(of);
    Assert.isEqual(f.a, 100);                             // T6
    Assert.isEqual(f.b, 200);                             // T7

    // ── Pointer bases ─────────────────────────────────────
    Outer o2;
    o2.mid.leaf.a = 11;
    o2.mid.leaf.b = 22;
    o2.mid.leaf.c = 33;
    o2.mid.leaf.d = 44;
    o2.mid.leaf.e = 55;

    Leaf pr = getLeafPtr(&o2);
    Assert.isEqual((u16)pr.a, 11);                        // T8
    Assert.isEqual((u16)pr.b, 22);                        // T9
    Assert.isEqual((u16)pr.c, 33);                        // T10
    Assert.isEqual((u16)pr.d, 44);                        // T11
    Assert.isEqual((u16)pr.e, 55);                        // T12

    OuterFour of2;
    of2.four.a = 111;
    of2.four.b = 222;

    Four pf = getFourPtr(&of2);
    Assert.isEqual(pf.a, 111);                            // T13
    Assert.isEqual(pf.b, 222);                            // T14

    Assert.summary();
    return;
}
