// test_progress.xc — UXProgress: direct completion + child roll-up.
#import <Stdio.xc>
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

    // a flat progress: 10 units, 3 done -> 30%
    UXProgress* p = UXProgress.make((i32)10);
    check("starts at 0", p.fractionMille(), (i32)0);
    p.setCompleted((i32)3);
    check("3/10 = 300 mille", p.fractionMille(), (i32)300);
    check("percent 30", p.percent(), (i32)30);
    p.incrementBy((i32)7);
    check("complete = 1000 mille", p.fractionMille(), (i32)1000);
    check("finished", p.isFinished() ? (i32)1 : (i32)0, (i32)1);
    // over-complete is clamped
    p.incrementBy((i32)5);
    check("clamped at total", p.fractionMille(), (i32)1000);

    // hierarchical: total 100; own 50 units + a child sub-task allocated 50 units
    UXProgress* parent = UXProgress.make((i32)100);
    UXProgress* child = parent.addChild((i32)200, (i32)50); // child of size 200 owns 50 parent-units
    check("nothing done yet", parent.fractionMille(), (i32)0);

    parent.setCompleted((i32)25); // own 25/100
    check("own 25 -> 250 mille", parent.fractionMille(), (i32)250);

    child.setCompleted((i32)100); // child half done (100/200)
    // effective = own 25 + child 0.5 * 50 = 25 + 25 = 50 -> 500 mille
    check("own + half child -> 500 mille", parent.fractionMille(), (i32)500);

    child.setCompleted((i32)200); // child fully done
    // effective = 25 + 50 = 75 -> 750 mille
    check("own + full child -> 750 mille", parent.fractionMille(), (i32)750);
    check("child reports finished", child.isFinished() ? (i32)1 : (i32)0, (i32)1);

    parent.setCompleted((i32)50); // finish own units too
    check("all done -> 1000 mille", parent.fractionMille(), (i32)1000);
    check("parent finished", parent.isFinished() ? (i32)1 : (i32)0, (i32)1);

    // nested children (two levels)
    UXProgress* top = UXProgress.make((i32)100);
    UXProgress* mid = top.addChild((i32)100, (i32)100); // the whole top is one child
    UXProgress* leaf = mid.addChild((i32)10, (i32)100); // the whole mid is one leaf
    leaf.setCompleted((i32)5);                          // leaf 50%
    // mid = 50% (all its units are the leaf), top = 50%
    check("two-level roll-up 500 mille", top.fractionMille(), (i32)500);

    // indeterminate
    UXProgress* ind = UXProgress.make((i32)0);
    check("zero total is indeterminate", ind.isIndeterminate() ? (i32)1 : (i32)0, (i32)1);
    check("indeterminate fraction 0", ind.fractionMille(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXProgress — direct completion, clamping, child roll-up, nesting, indeterminate.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
