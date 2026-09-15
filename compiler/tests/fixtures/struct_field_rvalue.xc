// Regression for `f(makeX().field)` / `u16 a = makeX().field;` —
// field projection on a struct-returning call's rvalue result.
//
// Before: emitMemberAccess had no case for a call-shaped base.
// The fallback recursed `emitExprToA:node.base` which reached
// emitCallExpr with `_inStructReturnIntercept` clear and raised
// the "call to X returns a struct — only `StructType v = X(...)`
// supported" diagnostic. Same dead-end for `u16 a = makeX().field;`
// because emitLocalVarDecl routes the initialiser through the
// generic expression path.
//
// Fix: in emitMemberAccess, when node.base is a struct-returning
// call, allocate a fresh `_rvstruct_tmp_N` data-section scratch
// label (mirroring the struct-arg path in emitStructArgPushCall),
// run the call with `_inStructReturnIntercept = YES` so the
// struct bytes land in the scratch (via __retbuf for large
// returns or a byte copy from \$B0.. for small ones), then read
// `fieldWidth` bytes from `tmpLabel + offset` into the standard
// A / X / _u32HiReg register-result convention.
//
// Along the way this fixture also pinned down a pre-existing
// struct-field-assignment stale-X bug: `p.x = 100` where p.x is
// u16 emitted `LDA #\$64 / STA addr / STX addr+1` without
// widening, so the high byte of the field came from whatever X
// happened to hold. Fixed by routing the direct / spill struct-
// field assignment paths through emitWideStoreExtensionForRHS
// before the STA/STX, and by extending the ZP store path to
// write all 4 bytes for u32 fields (copying _u32HiReg/+1 into
// addr+2/+3).

#import "Stdio.xc"

struct Point { u16 x; u16 y; }
struct Big { u32 a; u16 b; u8 c; }

Point makePoint(void)
{
    Point p;
    p.x = 100;
    p.y = 200;
    return p;
}

Big makeBig(void)
{
    Big r;
    r.a = 100000;
    r.b = 300;
    r.c = 7;
    return r;
}

void main(void)
{
    // Local-from-call.field: u16 / u8 / u32 projections.
    u16 x = makePoint().x;
    if (x == 100) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL x=%u\n", x); }

    u16 y = makePoint().y;
    if (y == 200) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL y=%u\n", y); }

    u32 a = makeBig().a;
    if (a == 100000) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL a=%lu\n", a); }

    u16 b = makeBig().b;
    if (b == 300) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL b=%u\n", b); }

    u8 c = makeBig().c;
    if (c == 7) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL c=%u\n", c); }

    // Direct-as-printf-arg: the field is packed straight into
    // the printf vararg buffer from the spilled rvstruct temp.
    Stdio.printf("T6 x=%u\n", makePoint().x);
    Stdio.printf("T7 b=%u\n", makeBig().b);
}
