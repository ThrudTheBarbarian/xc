// struct_wide_field.xc — coverage for wide-field reads AND
// writes on struct locals. The identifier-base emitMemberAccess
// path previously loaded only bytes 0-1 (A, X) for any field
// width, dropping bytes 2+ silently for u32/float/double fields.
// Float field WRITE `h.f = 2.5` used to write the 2-byte address
// of the float literal's data label, not the 5 bytes of the
// value.

#import "Stdio.xc"
#import "Assert.xc"

struct U32Holder {
    u16 a;       // offset 0
    u32 big;     // offset 2 — the width-4 field
    u8  tag;     // offset 6
}

struct TwoU32 {
    u32 lo;
    u32 hi;
}

struct FHolder { u8 tag; float  f; u8 end; }
struct DHolder { u8 tag; double d; u8 end; }

void main(void)
{
    Assert.reset();

    // u32 field read + write
    U32Holder u;
    u.a = $1234;
    u.big = $DEADBEEF;
    u.tag = $AA;
    Assert.isEqual(u.a, $1234);
    Assert.isEqual(u.tag, $AA);
    if (u.big == $DEADBEEF) { Assert.isTrue(true); } else { Assert.isTrue(false); }
    u32 id = u.big;
    if (id == $DEADBEEF) { Assert.isTrue(true); } else { Assert.isTrue(false); }

    TwoU32 t;
    t.lo = $12345678;
    t.hi = $CAFEBABE;
    u32 lo = t.lo;
    u32 hi = t.hi;
    if (lo == $12345678) { Assert.isTrue(true); } else { Assert.isTrue(false); }
    if (hi == $CAFEBABE) { Assert.isTrue(true); } else { Assert.isTrue(false); }

    // Float field write (5 bytes — used to write 2 bytes of a
    // data-label address rather than the float value).
    FHolder h;
    h.tag = $11;
    h.f = 2.5;
    h.end = $22;
    Assert.isEqual(h.tag, $11);
    Assert.isTrue(h.f == 2.5);
    Assert.isEqual(h.end, $22);

    // Integer RHS widened to float (int→fp conversion path).
    h.f = 42;
    Assert.isTrue(h.f == 42.0);

    // Float field read into a float local.
    float fv = h.f;
    Assert.isTrue(fv == 42.0);

    // Double field (8 bytes).
    DHolder dh;
    dh.tag = $33;
    dh.d = 1.25d;
    dh.end = $44;
    Assert.isEqual(dh.tag, $33);
    Assert.isTrue(dh.d == 1.25d);
    Assert.isEqual(dh.end, $44);

    Assert.summary();
    return;
}
