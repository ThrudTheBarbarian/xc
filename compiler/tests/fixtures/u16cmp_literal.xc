// u16cmp_literal.xc — magnitude compares (>, <, >=, <=) where the
// LHS is a literal/cast and the RHS is a u16 variable whose high
// byte matters. Pre-fix the codegen's emitMultiByteCompareBranchToFalse
// helper bailed out when the LHS wasn't an identifier / call / ivar,
// dropping into a single-byte CMP fallback that silently ignored
// the high byte. So `(u16)100 > someU16` and `200 > someU16` both
// reported TRUE whenever the u16 had high byte > 0 — the low-byte
// comparison `$64 > $LO` (or `$C8 > $LO`) succeeded for any LO < the
// literal, while the actual u16 was the larger value.
//
// Covers cast-to-u16, plain u8 literal vs u16 var (zero-extension
// path), all six magnitude / equality ops, and the symmetric form
// (var vs literal — already worked but pinning prevents regression).

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    u16 v100 = 100;
    u16 v200 = 200;
    u16 v300 = 300;
    u16 v500 = 500;

    // T1-T3: (u16)<lit> vs u16 var, magnitude — the bug-triggering form.
    Assert.isFalse((u16)100 > v300);
    Assert.isTrue ((u16)400 > v300);
    Assert.isFalse((u16)300 > v300);

    // T4-T7: plain u8 literal vs u16 var (zero-extension path).
    // These broke pre-fix because the literal's resolvedType is u8
    // — emitExprToA emitted only LDA (no LDX), so X held garbage
    // and the cascade compared random bytes.
    Assert.isFalse(200 > v300);
    Assert.isTrue (250 > v100);
    Assert.isFalse(100 > v200);
    Assert.isTrue (100 < v200);

    // T8-T9: high byte differs — the only place a correct cascade
    // can decide. Pre-fix dropped the high byte and got these wrong.
    Assert.isFalse(100 > v500);
    Assert.isTrue (100 < v500);

    // T10-T12: var vs literal (the symmetric form — RHS is the
    // constant). Already worked pre-fix but pin the behaviour.
    Assert.isTrue (v300 > 200);
    Assert.isFalse(v300 < 200);
    Assert.isFalse(v100 > 200);

    // T13-T14: equality.
    Assert.isTrue ((u16)300 == v300);
    Assert.isFalse((u16)301 == v300);

    // T15-T18: <= and >=.
    Assert.isTrue ((u16)300 >= v300);
    Assert.isFalse((u16)299 >= v300);
    Assert.isTrue ((u16)300 <= v300);
    Assert.isFalse((u16)301 <= v300);

    Stdio.printf("DONE 18\n");
    return;
}
