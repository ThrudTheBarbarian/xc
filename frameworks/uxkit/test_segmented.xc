// test_segmented.xc — UXSegmentedControl layout, hit-test, single/multi selection.
#import <Stdio.xc>
#import "UXSegmentedControl.xc"

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
i32 sel(UXSegmentedControl* c, i32 i)
    {
    return c.isSelected(i) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;
    UXSegmentedControl* c = new UXSegmentedControl();
    c.addSegment((u8*)"Day", (i32)1);
    c.addSegment((u8*)"Week", (i32)2);
    c.addSegment((u8*)"Month", (i32)3);
    check("three segments", c.count(), (i32)3);

    // equal-width layout within 90 -> each 30
    c.layout((i16)90);
    check("seg0 x", (i32)c.segAt((i32)0).x, (i32)0);
    check("seg0 w", (i32)c.segAt((i32)0).w, (i32)30);
    check("seg1 x", (i32)c.segAt((i32)1).x, (i32)30);
    check("seg2 x", (i32)c.segAt((i32)2).x, (i32)60);

    // remainder goes to the last segment (100 / 3 = 33, last = 34)
    c.layout((i16)100);
    check("seg0 w at 100", (i32)c.segAt((i32)0).w, (i32)33);
    check("last takes remainder", (i32)c.segAt((i32)2).w, (i32)34);

    // hit-test
    c.layout((i16)90);
    check("hit seg0", c.segmentAtLocalX((i16)15), (i32)0);
    check("hit seg1", c.segmentAtLocalX((i16)45), (i32)1);
    check("hit seg2", c.segmentAtLocalX((i16)75), (i32)2);
    check("hit past end", c.segmentAtLocalX((i16)200), (i32)-1);

    // single selection (default): selecting one deselects the rest
    c.selectSegment((i32)1);
    check("seg1 selected", sel(c, (i32)1), (i32)1);
    check("selectedSegment is 1", c.selectedSegment(), (i32)1);
    c.selectSegment((i32)2);
    check("seg2 now selected", sel(c, (i32)2), (i32)1);
    check("seg1 deselected", sel(c, (i32)1), (i32)0);
    check("only one selected", c.selectedSegment(), (i32)2);

    // multi selection: toggling accumulates
    UXSegmentedControl* m = new UXSegmentedControl();
    m.addSegment((u8*)"B", (i32)0);
    m.addSegment((u8*)"I", (i32)1);
    m.addSegment((u8*)"U", (i32)2);
    m.setMultiSelect(true);
    m.selectSegment((i32)0);
    m.selectSegment((i32)2);
    check("multi: 0 selected", sel(m, (i32)0), (i32)1);
    check("multi: 2 selected", sel(m, (i32)2), (i32)1);
    check("multi: 1 not selected", sel(m, (i32)1), (i32)0);
    m.selectSegment((i32)0); // toggle off
    check("multi: 0 toggled off", sel(m, (i32)0), (i32)0);
    check("multi: 2 still on", sel(m, (i32)2), (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXSegmentedControl — equal layout + remainder, hit-test, single + multi selection.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
