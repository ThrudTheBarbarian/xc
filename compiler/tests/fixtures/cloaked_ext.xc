// cloaked_ext.xc — extended cloaked code regions across the bank
// window. The xe layout declares two [cloaked] regions:
//   id=lib   bank=none   (banking off, library RAM at $4000)
//   id=ext1  bank=2      (numbered hardware bank 2)
//
// `:cloaked(<id>)` pins a decl into the named region. Codegen emits
// the matching PORTB bracket per region — `$32` for bank=none,
// `$22 | depositBits(2) = $2A` for ext1. xta loads each region's
// segment via the right preload-stub flavour: banking-off INITAD
// for lib, bank-N PORTB-on stub for ext1.
//
// Coverage:
//   T1: direct main → :cloaked(ext1) leaf.
//   T2: direct main → :cloaked(ext1) with arg.
//   T3: main → :cloaked(lib) (legacy banking-off region).
//   T4: cross-region cloaked-to-cloaked. main → :cloaked(lib) →
//       :cloaked(ext1) → return → :cloaked(ext1) → return. The
//       _xcall_cloaked trampoline routes caller_ret + caller PORTB
//       through main-RAM static slots so the bank-window switch
//       between regions doesn't unmap the saved state.
//   T5: same-region elision. main → :cloaked(lib) → :cloaked(lib).
//       Caller and callee both have PORTB at $32 already, so the
//       save/set/restore bracket around the JSR is dropped — the
//       call site emits a plain JSR. Inspect the asm output to
//       see the "bracket elided" comment in place of the bracket.
//
// Pass criterion: T1..T5 PASS / DONE 5.

#import "Stdio.xc"

i16 ext_value(void) : cloaked(ext1)
{
    // Leaf in ext1. PORTB bracket on the call site selects bank 2
    // before the JSR; this body executes from bank 2's $4000-$7FFF
    // image of memory.
    return 137;
}

i16 ext_double(i16 v) : cloaked(ext1)
{
    // Verify args land in the $B0..$BF reg window when crossing into
    // ext1, same as the existing :cloaked calling convention.
    return v + v;
}

i16 lib_value(void) : cloaked(lib)
{
    // Sanity: the historical banking-off region still works alongside
    // the new numbered-bank region.
    return 91;
}

i16 lib_helper(i16 v) : cloaked(lib)
{
    // Same-region callee for T5 — both lib_helper and its caller
    // (lib_chain) live in `lib`, so the bracket around the JSR
    // gets elided.
    return v + 5;
}

i16 lib_chain(i16 v) : cloaked(lib)
{
    // Calls lib_helper, which lives in the same region. With the
    // elision pass, codegen emits a plain `JSR _fn_lib_helper`
    // instead of the PORTB save/set/restore bracket around it.
    return lib_helper(v) * 2;
}

i16 lib_combine(i16 base) : cloaked(lib)
{
    // Cross-region cloaked-to-cloaked. Caller is in lib (PORTB=$32,
    // banking off). _xcall_cloaked switches PORTB to $2A around each
    // ext call and restores $32 on return. Saved state lives in
    // main-RAM static slots — both reads work regardless of which
    // bank the $4000-$7FFF window currently shows.
    i16 ev = ext_value();
    i16 ed = ext_double(base);
    return base + ev + ed;
}

void main(void)
{
    u16 fails = 0;

    // T1: direct main → :cloaked(ext1) leaf. Exercises the new
    // PORTB=$2A bracket + the bank-2 INITAD preload stub.
    i16 a = ext_value();
    if (a == 137) Stdio.printf("T1 PASS\n");
    else { Stdio.printf("T1 FAIL got=%d\n", a); fails++; }

    // T2: direct main → :cloaked(ext1) with arg. Verifies the
    // $B0..$BF arg-passing convention survives the bank switch.
    i16 b = ext_double(21);
    if (b == 42) Stdio.printf("T2 PASS\n");
    else { Stdio.printf("T2 FAIL got=%d\n", b); fails++; }

    // T3: main → :cloaked(lib). The legacy banking-off region still
    // works after the multi-region rework.
    i16 c = lib_value();
    if (c == 91) Stdio.printf("T3 PASS\n");
    else { Stdio.printf("T3 FAIL got=%d\n", c); fails++; }

    // T4: cross-region cloaked-to-cloaked. lib_combine() runs in
    // banking-off mode; each ext call switches the bank window to
    // bank 2 and back. Expected: 10 + 137 + 20 = 167.
    i16 d = lib_combine(10);
    if (d == 167) Stdio.printf("T4 PASS\n");
    else { Stdio.printf("T4 FAIL got=%d\n", d); fails++; }

    // T5: same-region cloaked-to-cloaked. lib_chain calls lib_helper
    // — both in lib — so the codegen elides the PORTB bracket around
    // the JSR. Runtime path: 7 → lib_helper(7) = 12 → * 2 = 24.
    i16 e = lib_chain(7);
    if (e == 24) Stdio.printf("T5 PASS\n");
    else { Stdio.printf("T5 FAIL got=%d\n", e); fails++; }

    if (fails == 0) Stdio.printf("DONE 5\n");
    else            Stdio.printf("FAIL %u\n", fails);
}
