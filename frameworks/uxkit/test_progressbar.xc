// test_progressbar.xc — UXProgressBar fill-width from an UXProgress model.
#import <Stdio.xc>
#import "UXProgressBar.xc"
#import "UXProgress.xc"

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
    UXProgressBar* bar = new UXProgressBar();

    // no model -> empty + indeterminate-safe
    check("no model fill 0", bar.filledWidth((i16)100), (i32)0);
    check("no model is indeterminate", bar.isIndeterminate() ? (i32)1 : (i32)0, (i32)1);

    // a determinate model
    UXProgress* p = UXProgress.make((i32)10);
    bar.setProgress(p);
    check("0% fill 0 of 200", bar.filledWidth((i16)200), (i32)0);
    check("determinate now", bar.isIndeterminate() ? (i32)1 : (i32)0, (i32)0);

    p.setCompleted((i32)5);
    check("50% fills half of 200", bar.filledWidth((i16)200), (i32)100);
    p.setCompleted((i32)3);
    check("30% of 200 = 60", bar.filledWidth((i16)200), (i32)60);
    p.setCompleted((i32)10);
    check("100% fills the whole 200", bar.filledWidth((i16)200), (i32)200);

    // a child roll-up drives the bar too
    UXProgress* parent = UXProgress.make((i32)100);
    UXProgress* child = parent.addChild((i32)200, (i32)50);
    parent.setCompleted((i32)25);
    child.setCompleted((i32)100); // -> parent 50%
    bar.setProgress(parent);
    check("rolled-up 50% fills half of 300", bar.filledWidth((i16)300), (i32)150);

    // indeterminate model
    UXProgress* ind = UXProgress.make((i32)0);
    bar.setProgress(ind);
    check("zero-total model is indeterminate", bar.isIndeterminate() ? (i32)1 : (i32)0, (i32)1);
    check("indeterminate fill is 0", bar.filledWidth((i16)200), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXProgressBar — fill-width from progress, roll-up, indeterminate.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
