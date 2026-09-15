// test_animation.xc — UXAnimation: interpolation + easing curves over synthetic time.
#import <Stdio.xc>
#import "UXAnimation.xc"

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

    // linear 0->100 over [1000,1200]
    UXAnimation* lin = UXAnimation.make((i32)0, (i32)100, (i32)1000, (i32)200, (i32)UX_EASE_LINEAR);
    check("before start = from", lin.valueAt((i32)900), (i32)0);
    check("at start = from", lin.valueAt((i32)1000), (i32)0);
    check("at end = to", lin.valueAt((i32)1200), (i32)100);
    check("after end = to", lin.valueAt((i32)1500), (i32)100);
    near("midpoint linear", lin.valueAt((i32)1100), (i32)50, (i32)1);
    near("quarter linear", lin.valueAt((i32)1050), (i32)25, (i32)1);
    check("finished after end", lin.isFinished((i32)1200) ? (i32)1 : (i32)0, (i32)1);
    check("not finished mid", lin.isFinished((i32)1100) ? (i32)1 : (i32)0, (i32)0);

    // ease-in is slower than linear at the midpoint (curve below the diagonal)
    UXAnimation* ein = UXAnimation.make((i32)0, (i32)100, (i32)0, (i32)100, (i32)UX_EASE_IN);
    i32 mid = ein.valueAt((i32)50);
    check("ease-in midpoint below linear (50)", mid < (i32)50 ? (i32)1 : (i32)0, (i32)1);
    check("ease-in endpoints exact (start)", ein.valueAt((i32)0), (i32)0);
    check("ease-in endpoints exact (end)", ein.valueAt((i32)100), (i32)100);

    // ease-out is faster than linear at the midpoint (curve above the diagonal)
    UXAnimation* eout = UXAnimation.make((i32)0, (i32)100, (i32)0, (i32)100, (i32)UX_EASE_OUT);
    check("ease-out midpoint above linear", eout.valueAt((i32)50) > (i32)50 ? (i32)1 : (i32)0, (i32)1);

    // ease-in-out is symmetric: midpoint ~= 50
    UXAnimation* eio = UXAnimation.make((i32)0, (i32)100, (i32)0, (i32)100, (i32)UX_EASE_IN_OUT);
    near("ease-in-out midpoint ~50", eio.valueAt((i32)50), (i32)50, (i32)2);
    check("ease-in-out start", eio.valueAt((i32)0), (i32)0);
    check("ease-in-out end", eio.valueAt((i32)100), (i32)100);

    // the easing curve on raw t: ease(255) == 255, ease(0) == 0 for every mode
    check("ease-in ends at 255", UXAnimation.ease((i32)UX_EASE_IN, (i32)255), (i32)255);
    check("ease-out ends at 255", UXAnimation.ease((i32)UX_EASE_OUT, (i32)255), (i32)255);
    check("ease-in-out ends at 255", UXAnimation.ease((i32)UX_EASE_IN_OUT, (i32)255), (i32)255);
    check("ease-in starts at 0", UXAnimation.ease((i32)UX_EASE_IN, (i32)0), (i32)0);

    // interpolate down (to < from) works too
    UXAnimation* down = UXAnimation.make((i32)200, (i32)100, (i32)0, (i32)100, (i32)UX_EASE_LINEAR);
    near("descending midpoint", down.valueAt((i32)50), (i32)150, (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXAnimation — interpolation, clamping, easing curves, descending.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
