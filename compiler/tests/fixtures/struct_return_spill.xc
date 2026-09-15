// Regression for large-struct return into a ZP-spilled destination.
//
// Before, `Big r = makeBig(1);` and `r = makeBig(1);` both diagnosed
// with "large-struct return destination must be a ZP-resident local"
// whenever main()'s locals pushed `r` out of ZP into the data-section
// `_spill_r` block. emitAssignExpr / emitTupleAssign's large-struct
// branches only checked _globalAddresses; add a _spillLabels fallback
// that passes the spill label to emitLargeStructCall:destSpillLabel:.
//
// Standard target only — the banked target has a separate pre-existing
// large-struct assignment limitation (see struct_return_expr_large.xc
// for the same reason).

#import "Stdio.xc"

struct Big {
    u16 a; u16 b; u16 c;
    u16 d; u16 e; u16 f;
}

Big makeBig(u16 seed)
{
    Big b;
    b.a = seed;
    b.b = seed + 1;
    b.c = seed + 2;
    b.d = seed + 3;
    b.e = seed + 4;
    b.f = seed + 5;
    return b;
}

void main(void)
{
    // Pressure ZP with enough u16 locals that `r` lands in the spill
    // region. The exact number needed depends on the ZP allocator's
    // available range — 30 u16s = 60 bytes is well over the ~120 bytes
    // of user-visible ZP ($88-$FF minus runtime reservations), so on
    // top of the other locals below `r` is pushed out.
    u16 w1 = 1; u16 w2 = 2; u16 w3 = 3; u16 w4 = 4; u16 w5 = 5;
    u16 w6 = 6; u16 w7 = 7; u16 w8 = 8; u16 w9 = 9; u16 wA = 10;
    u16 wB = 11; u16 wC = 12; u16 wD = 13; u16 wE = 14; u16 wF = 15;
    u16 wG = 16; u16 wH = 17; u16 wI = 18; u16 wJ = 19; u16 wK = 20;
    u16 wL = 21; u16 wM = 22; u16 wN = 23; u16 wO = 24; u16 wP = 25;
    u16 wQ = 26; u16 wR = 27; u16 wS = 28; u16 wT = 29; u16 wU = 30;

    // T1: var-decl form — `Big r = makeBig(1);` with r spilled.
    Big r = makeBig(1);
    if (r.a == 1 && r.b == 2 && r.c == 3 &&
        r.d == 4 && r.e == 5 && r.f == 6) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL %u %u %u %u %u %u\n",
                     r.a, r.b, r.c, r.d, r.e, r.f);
    }

    // T2: reassignment form — `r = makeBig(10);` into same spilled r.
    r = makeBig(10);
    if (r.a == 10 && r.b == 11 && r.c == 12 &&
        r.d == 13 && r.e == 14 && r.f == 15) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL %u %u %u %u %u %u\n",
                     r.a, r.b, r.c, r.d, r.e, r.f);
    }

    // Sanity: make sure the prefix locals weren't clobbered by the
    // spill path stomping on $88-$FF.
    if (w1 == 1 && wU == 30) { Stdio.printf("T3 PASS\n"); }
    else                     { Stdio.printf("T3 FAIL w1=%u wU=%u\n", w1, wU); }
}
