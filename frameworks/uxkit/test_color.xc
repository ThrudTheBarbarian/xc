// test_color.xc — UXColor: RGB/HSB/hex conversions and blends (integer, backend-identical).
#import <Stdio.xc>
#import "UXColor.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
void near(u8* what, i32 got, i32 want, i32 tol)
    {
    i32 d = got - want;
    if (d < (i32)0)
        {
        d = -d;
        }
    if (d <= tol)
        {
        Stdio.printf("  ok   %s = %d (~%d)\n", what, (i16)got, (i16)want);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want ~%d +-%d)\n", what, (i16)got, (i16)want, (i16)tol);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // hex round-trip
    UXColor* c = UXColor.fromHex((u32)$007AFF);
    check("hex r", c.r, (i32)0);
    check("hex g", c.g, (i32)122);
    check("hex b", c.b, (i32)255);
    check("toHex round-trips", (i32)c.toHex(), (i32)$7AFF);

    // clamping
    UXColor* over = UXColor.rgb((i32)300, (i32)-5, (i32)128);
    check("clamp high", over.r, (i32)255);
    check("clamp low", over.g, (i32)0);

    // HSB of primaries
    i32 h;
    i32 s;
    i32 v;
    UXColor.red().toHSB(&h, &s, &v);
    check("red hue 0", h, (i32)0);
    check("red sat 255", s, (i32)255);
    check("red bri 255", v, (i32)255);
    UXColor.green().toHSB(&h, &s, &v);
    check("green hue 120", h, (i32)120);
    UXColor.blue().toHSB(&h, &s, &v);
    check("blue hue 240", h, (i32)240);
    UXColor.white().toHSB(&h, &s, &v);
    check("white sat 0", s, (i32)0);
    check("white bri 255", v, (i32)255);

    // HSB -> RGB primaries
    UXColor* pureRed = UXColor.hsb((i32)0, (i32)255, (i32)255);
    check("hsb red r", pureRed.r, (i32)255);
    check("hsb red g", pureRed.g, (i32)0);
    UXColor* cyan = UXColor.hsb((i32)180, (i32)255, (i32)255);
    check("hsb cyan r", cyan.r, (i32)0);
    near("hsb cyan g", cyan.g, (i32)255, (i32)2);
    near("hsb cyan b", cyan.b, (i32)255, (i32)2);

    // RGB -> HSB -> RGB round trip (integer, so allow a small tolerance)
    UXColor* orig = UXColor.rgb((i32)200, (i32)100, (i32)50);
    orig.toHSB(&h, &s, &v);
    UXColor* back = UXColor.hsb(h, s, v);
    near("roundtrip r", back.r, (i32)200, (i32)4);
    near("roundtrip g", back.g, (i32)100, (i32)4);
    near("roundtrip b", back.b, (i32)50, (i32)4);

    // blends
    UXColor* mid = UXColor.black().blend(UXColor.white(), (i32)128);
    near("black+white midpoint ~128", mid.r, (i32)128, (i32)2);
    UXColor* lit = UXColor.rgb((i32)100, (i32)100, (i32)100).lightened((i32)255);
    check("fully lightened is white", lit.r, (i32)255);
    UXColor* drk = UXColor.rgb((i32)100, (i32)100, (i32)100).darkened((i32)255);
    check("fully darkened is black", drk.r, (i32)0);

    // luminance / readability
    check("white is not dark", UXColor.white().isDark() ? (i32)1 : (i32)0, (i32)0);
    check("black is dark", UXColor.black().isDark() ? (i32)1 : (i32)0, (i32)1);
    check("blue is dark", UXColor.blue().isDark() ? (i32)1 : (i32)0, (i32)1);
    check("yellow is not dark", UXColor.yellow().isDark() ? (i32)1 : (i32)0, (i32)0);

    // equality + alpha
    check("equal colours", UXColor.red().isEqualTo(UXColor.rgb((i32)255, (i32)0, (i32)0)) ? (i32)1 : (i32)0, (i32)1);
    check("alpha differs -> not equal", UXColor.red().isEqualTo(UXColor.red().withAlpha((i32)128)) ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXColor — hex, HSB<->RGB, blend, lighten/darken, luminance, equality.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
