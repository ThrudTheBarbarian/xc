// test_colorpanel.xc — UXColorPanel HSB picking state syncing with UXColor.
#import <Stdio.xc>
#import "UXColorPanel.xc"
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
    UXColorPanel* p = new UXColorPanel();

    // set red -> HSB should be hue 0, sat 255, bri 255
    p.setColor(UXColor.red());
    check("red hue 0", p.hueValue(), (i32)0);
    check("red sat 255", p.saturationValue(), (i32)255);
    check("red bri 255", p.brightnessValue(), (i32)255);

    // recompose -> red
    check("color() r", p.color().r, (i32)255);
    check("color() g", p.color().g, (i32)0);

    // set green colour -> hue 120
    p.setColor(UXColor.green());
    check("green hue 120", p.hueValue(), (i32)120);

    // drive the sliders directly: hue 240 (blue), full sat/bri
    p.setHue((i32)240);
    p.setSaturation((i32)255);
    p.setBrightness((i32)255);
    check("blue from sliders b", p.color().b, (i32)255);
    check("blue from sliders r", p.color().r, (i32)0);

    // hue wraps
    p.setHue((i32)-30);
    check("hue -30 wraps to 330", p.hueValue(), (i32)330);
    p.setHue((i32)400);
    check("hue 400 wraps to 40", p.hueValue(), (i32)40);

    // sat/bri clamp
    p.setSaturation((i32)500);
    check("sat clamps 255", p.saturationValue(), (i32)255);
    p.setBrightness((i32)-10);
    check("bri clamps 0", p.brightnessValue(), (i32)0);
    check("zero brightness is black", p.color().r, (i32)0);

    // alpha preserved through a set/get
    p.setColor(UXColor.rgba((i32)100, (i32)150, (i32)200, (i32)128));
    check("alpha adopted", p.alphaValue(), (i32)128);
    check("color keeps alpha", p.color().a, (i32)128);

    // round-trip a mid colour (integer HSB tolerance)
    p.setColor(UXColor.rgb((i32)200, (i32)100, (i32)50));
    near("round-trip r", p.color().r, (i32)200, (i32)4);
    near("round-trip g", p.color().g, (i32)100, (i32)4);
    near("round-trip b", p.color().b, (i32)50, (i32)4);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXColorPanel — HSB decompose/compose, sliders, hue wrap, clamp, alpha, round-trip.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
