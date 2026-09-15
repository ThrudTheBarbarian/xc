// test_slider.xc — UXSlider value<->position mapping (pure, no window).
#import <Stdio.xc>
#import "UXSlider.xc"

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
    UXSlider* s = new UXSlider();
    s.setRange((i32)0, (i32)100);
    s.knobW = (i16)10;

    // value -> knob position within a 110px track (span = 110-10 = 100)
    s.setValue((i32)0);
    check("value 0 -> knob at 0", s.knobX((i16)110), (i32)0);
    s.setValue((i32)100);
    check("value 100 -> knob at span (100)", s.knobX((i16)110), (i32)100);
    s.setValue((i32)50);
    check("value 50 -> knob at 50", s.knobX((i16)110), (i32)50);
    s.setValue((i32)25);
    check("value 25 -> knob at 25", s.knobX((i16)110), (i32)25);

    // clamping
    s.setValue((i32)500);
    check("over-max clamps", s.intValue(), (i32)100);
    s.setValue((i32)-20);
    check("under-min clamps", s.intValue(), (i32)0);

    // position -> value (knob centred under pointer; knobW/2 = 5)
    check("click at 5 -> value 0", s.valueForX((i16)5, (i16)110), (i32)0);
    check("click at 105 -> value 100", s.valueForX((i16)105, (i16)110), (i32)100);
    near("click at 55 -> value ~50", s.valueForX((i16)55, (i16)110), (i32)50, (i32)1);
    check("click far left clamps to 0", s.valueForX((i16)-10, (i16)110), (i32)0);
    check("click far right clamps to max", s.valueForX((i16)999, (i16)110), (i32)100);

    // a non-zero minimum
    UXSlider* t = new UXSlider();
    t.setRange((i32)10, (i32)20);
    t.knobW = (i16)0;
    t.setValue((i32)15);
    check("mid of 10..20 -> knob 50%", t.knobX((i16)100), (i32)50);
    check("value at x=50 in 10..20", t.valueForX((i16)50, (i16)100), (i32)15);

    // round-trip value -> x -> value
    s.setRange((i32)0, (i32)200);
    s.knobW = (i16)8;
    s.setValue((i32)137);
    i32 x = s.knobX((i16)208); // span 200
    near("round-trip 137", s.valueForX((i16)(x + (i16)4), (i16)208), (i32)137, (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXSlider — value<->position, clamping, non-zero range, round-trip.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
