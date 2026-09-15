// heap_bump_spill_large.xc — non-array locals past ZP spill
// correctly.
//
// Before this landing the heap-bump path in emitLocalVarDecl
// allocated a 2-byte ZP pointer for any local > 2 bytes (with
// narrow exemptions for struct-returning-call initialisers,
// floats, and ARC strong-field structs), then decremented HP
// by the local's size. The exemptions papered over cases that
// already failed; every other use of the path was silently
// broken.
//
// The problem: heap-bump only works if the emit sites that
// read and write the local know to dereference the ZP pointer.
// Array subscript already does, via emitSubscriptAddrToZp +
// (ptr),Y. Nothing else does. Struct member access, u32/i32
// byte load/store, and struct-copy all use the ZP pointer's
// address as if it WERE the storage bytes, so:
//
//   • `s.a = v` writes the RHS into the ZP pointer itself —
//     then `s.b` (offset 2) silently steps past $FF into main
//     memory, clobbering whatever lives there.
//   • `u32 x = 0xDEADBEEF` writes EF to the pointer lo byte,
//     BE to the pointer hi byte, AD/DE past the ZP page.
//   • Cross-call read/write happens to be self-consistent
//     (both ends use the same bad addresses) so minimal tests
//     passed by accident until ZP pressure shifted.
//
// Fix: heap-bump fires only for array locals. Everything else
// (struct, u32/i32, float) falls through to the data-section
// spill path where absolute `label+off` addressing is the
// same at every emit site.
//
// This fixture forces a ZP-exhausting preamble (many u16
// globals), then declares a wide struct and a u32 local.
// Both must now spill cleanly.
//
// Flat-heap targets only — identical mechanics under banked.

#import "Stdio.xc"
#import "Assert.xc"

// ZP-pressure globals: push every ZP byte into allocator use
// so the struct/u32 below can't find space in ZP.
u16 g0;  u16 g1;  u16 g2;  u16 g3;  u16 g4;  u16 g5;
u16 g6;  u16 g7;  u16 g8;  u16 g9;  u16 g10; u16 g11;
u16 g12; u16 g13; u16 g14; u16 g15; u16 g16; u16 g17;
u16 g18; u16 g19; u16 g20; u16 g21; u16 g22; u16 g23;
u16 g24; u16 g25; u16 g26; u16 g27; u16 g28; u16 g29;

struct Wide
{
    u16 a; u16 b; u16 c; u16 d;
    u16 e; u16 f; u16 g; u16 h;
    u16 i; u16 j; u16 k; u16 l;
    u16 m; u16 n; u16 o; u16 p;
    u16 q; u16 r; u16 s; u16 t;
    u16 u; u16 v; u16 w; u16 x;
}

Wide pad1;
Wide pad2;

void main(void)
{
    Assert.reset();

    // ── T1-T5: struct field writes + reads past ZP ───────────
    Wide s;
    s.a = 100;
    s.b = 200;
    s.c = 300;
    s.w = 2300;
    s.x = 2400;
    Assert.isEqual(s.a, 100);                         // T1
    Assert.isEqual(s.b, 200);                         // T2
    Assert.isEqual(s.c, 300);                         // T3
    Assert.isEqual(s.w, 2300);                        // T4
    Assert.isEqual(s.x, 2400);                        // T5

    // ── T6-T7: struct-copy alias ─────────────────────────────
    Wide t;
    t = s;
    Assert.isEqual(t.a, 100);                         // T6
    Assert.isEqual(t.x, 2400);                        // T7

    // ── T8-T11: u32 scalar past ZP ───────────────────────────
    // Before the fix, `u32 lval = ...` fell into heap-bump when
    // ZP was under pressure and scribbled across the pointer
    // slot + adjacent main memory. T8-T11 read the four bytes
    // back through the `lval >> shift` extraction path the
    // original regression used.
    u32 lval = $DEADBEEF;
    u16 hi = (lval >> 16) & $FFFF;
    u16 lo = lval & $FFFF;
    Assert.isEqual(lo, $BEEF);                        // T8
    Assert.isEqual(hi, $DEAD);                        // T9
    Assert.isEqual(lo & $FF, $EF);                    // T10
    Assert.isEqual((hi >> 8) & $FF, $DE);             // T11

    Assert.summary();
    return;
}
