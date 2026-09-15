// test_gradient.xc — UXGradient: stop ordering + interpolated sampling.
#import <Stdio.xc>
#import "UXGradient.xc"
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
        Stdio.printf("  FAIL %s = %d (want ~%d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // black -> white
    UXGradient* g = UXGradient.twoColor(UXColor.black(), UXColor.white());
    check("two stops", g.stopCount(), (i32)2);
    check("start is black", g.colorAt((i32)0).r, (i32)0);
    check("end is white", g.colorAt((i32)255).r, (i32)255);
    near("mid is grey", g.colorAt((i32)128).r, (i32)128, (i32)2);
    near("quarter", g.colorAt((i32)64).r, (i32)64, (i32)2);

    // clamping outside the range
    check("before first clamps to first", g.colorAt((i32)-50).r, (i32)0);
    check("after last clamps to last", g.colorAt((i32)999).r, (i32)255);

    // three-stop red -> green -> blue, inserted out of order to test sorting
    UXGradient* rgb = new UXGradient();
    rgb.addStop((i32)255, UXColor.blue());
    rgb.addStop((i32)0, UXColor.red());
    rgb.addStop((i32)128, UXColor.green());
    check("three stops", rgb.stopCount(), (i32)3);
    check("stops sorted (first pos 0)", rgb.stopAt((i32)0).pos, (i32)0);
    check("stops sorted (mid pos 128)", rgb.stopAt((i32)1).pos, (i32)128);
    // at 128 exactly -> green
    check("at 128 green r", rgb.colorAt((i32)128).r, (i32)0);
    check("at 128 green g", rgb.colorAt((i32)128).g, (i32)255);
    // between red(0) and green(128) at 64: half red half green
    near("64 blends red->green (r)", rgb.colorAt((i32)64).r, (i32)128, (i32)3);
    near("64 blends red->green (g)", rgb.colorAt((i32)64).g, (i32)128, (i32)3);
    check("64 has no blue", rgb.colorAt((i32)64).b, (i32)0);
    // between green(128) and blue(255) at ~192: half green half blue
    near("192 blends green->blue (g)", rgb.colorAt((i32)192).g, (i32)128, (i32)4);
    near("192 blends green->blue (b)", rgb.colorAt((i32)192).b, (i32)128, (i32)4);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXGradient — stop sorting, interpolation, clamping, multi-stop.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
