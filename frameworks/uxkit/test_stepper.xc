// test_stepper.xc — UXStepper value logic: increment/decrement, clamp, wrap, step.
#import <Stdio.xc>
#import "UXStepper.xc"

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
    UXStepper* s = new UXStepper();
    s.setRange((i32)0, (i32)5);
    s.setValue((i32)0);

    s.increment();
    check("inc to 1", s.intValue(), (i32)1);
    s.increment();
    s.increment();
    check("inc to 3", s.intValue(), (i32)3);
    s.decrement();
    check("dec to 2", s.intValue(), (i32)2);

    // clamp at max (no wrap)
    s.setValue((i32)5);
    s.increment();
    check("clamps at max", s.intValue(), (i32)5);
    s.setValue((i32)0);
    s.decrement();
    check("clamps at min", s.intValue(), (i32)0);

    // wrap
    s.setWraps(true);
    s.setValue((i32)5);
    s.increment();
    check("wraps max->min", s.intValue(), (i32)0);
    s.decrement();
    check("wraps min->max", s.intValue(), (i32)5);

    // step size
    UXStepper* t = new UXStepper();
    t.setRange((i32)0, (i32)100);
    t.setStep((i32)10);
    t.setValue((i32)0);
    t.increment();
    check("step 10", t.intValue(), (i32)10);
    t.increment();
    t.increment();
    check("step to 30", t.intValue(), (i32)30);
    t.setValue((i32)95);
    t.increment();
    check("step clamps at max (no wrap)", t.intValue(), (i32)100);

    // setValue clamps
    t.setValue((i32)500);
    check("setValue over-max clamps", t.intValue(), (i32)100);
    t.setValue((i32)-5);
    check("setValue under-min clamps", t.intValue(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXStepper — increment/decrement, clamp, wrap, step size.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
