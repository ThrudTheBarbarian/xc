// test_metrics.xc — the UXMetrics standards, both realms, no window.
//
// The pure ...For(kind, ff) forms are the whole point: the table is
// checkable on any host without booting a driver.  Locks the adaptable
// contract — desktop rows on the 28 basis, device rows on the 44 touch
// target — and the fixed-intrinsic accommodations (UIStepper's 96-wide,
// the switch-holding checkbox row).
//
//   Build+run:  sh run_metrics.sh
#import <Stdio.xc>
#import "UXMetrics.xc"

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

void main(void)
    {
    gFails = (i32)0;
    i32 dt = (i32)UX_FORM_DESKTOP;
    i32 ph = (i32)UX_FORM_PHONE;
    i32 tb = (i32)UX_FORM_TABLET;

    // the two bases
    check("desktop button row", UXMetrics.stdHeightFor((i32)UXKindButton, dt), (i32)28);
    check("phone button = touch target", UXMetrics.stdHeightFor((i32)UXKindButton, ph), (i32)44);
    check("tablet rides the device basis", UXMetrics.stdHeightFor((i32)UXKindButton, tb), (i32)44);

    // fixed-intrinsic accommodations
    check("device checkbox row holds a switch", UXMetrics.stdHeightFor((i32)UXKindCheckbox, ph), (i32)32);
    check("device stepper width holds UIStepper", UXMetrics.minWidthFor((i32)UXKindStepper, ph), (i32)96);

    // idiom inversions survive
    check("desktop progress is a bar", UXMetrics.stdHeightFor((i32)UXKindProgress, dt), (i32)12);
    check("device progress is a line", UXMetrics.stdHeightFor((i32)UXKindProgress, ph), (i32)8);

    // spacing adapts with the realm
    check("desktop row spacing", UXMetrics.rowSpacingFor(dt), (i32)8);
    check("device row spacing", UXMetrics.rowSpacingFor(ph), (i32)12);

    // every kind answers something sane on both realms
    for (i32 k = (i32)0; k <= (i32)14; k = k + (i32)1)
        {
        if (UXMetrics.stdHeightFor(k, dt) < (i32)8)
            {
            Stdio.printf("  FAIL kind %d desktop < 8\n", (i16)k);
            gFails = gFails + (i32)1;
            }
        if (UXMetrics.stdHeightFor(k, ph) < (i32)8)
            {
            Stdio.printf("  FAIL kind %d phone < 8\n", (i16)k);
            gFails = gFails + (i32)1;
            }
        if (UXMetrics.minWidthFor(k, dt) < (i32)20)
            {
            Stdio.printf("  FAIL kind %d width < 20\n", (i16)k);
            gFails = gFails + (i32)1;
            }
        }

    Stdio.printf(gFails == (i32)0 ? "PASS: the metrics table adapts by form factor\n"
                                  : "FAIL: %d checks\n",
                 gFails);
    }
