// test_breadcrumb.xc — UXBreadcrumb layout + hit-test (pure geometry, no window needed).
#import <Stdio.xc>
#import "UXBreadcrumb.xc"

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
i32 vis(UXBreadcrumb* b, i32 i)
    {
    return b.segAt(i).visible ? (i32)1 : (i32)0;
    }
i32 visibleCount(UXBreadcrumb* b)
    {
    i32 n = (i32)0;
    for (i32 i = (i32)0; i < b.count(); i = i + (i32)1)
        {
        if (b.segAt(i).visible)
            {
            n = n + (i32)1;
            }
        }
    return n;
    }

void main(void)
    {
    gFails = (i32)0;
    // charWidth=7, segPad=6, sepWidth=14 (defaults).  naturalWidth = 12 + 7*len.

    // ---- everything fits ---------------------------------------------------
    UXBreadcrumb* b = new UXBreadcrumb();
    b.addSegment((u8*)"Home", (i32)1);    // len 4 -> w 40
    b.addSegment((u8*)"Docs", (i32)2);    // len 4 -> w 40
    b.addSegment((u8*)"Reports", (i32)3); // len 7 -> w 61
    b.layout((i16)300);
    check("count", b.count(), (i32)3);
    check("no elision when it fits", b.showEllipsis ? (i32)1 : (i32)0, (i32)0);
    check("seg0 x", (i32)b.segAt((i32)0).x, (i32)0);
    check("seg0 w", (i32)b.segAt((i32)0).w, (i32)40);
    check("seg1 x (40+14)", (i32)b.segAt((i32)1).x, (i32)54);
    check("seg2 x (54+40+14)", (i32)b.segAt((i32)2).x, (i32)108);
    check("seg2 w", (i32)b.segAt((i32)2).w, (i32)61);

    // hit-test
    check("hit inside Home", b.segmentAtLocalX((i16)20), (i32)0);
    check("hit inside Docs", b.segmentAtLocalX((i16)60), (i32)1);
    check("hit inside Reports", b.segmentAtLocalX((i16)110), (i32)2);
    check("hit in the gap between segments", b.segmentAtLocalX((i16)45), (i32)-1);
    check("hit past the end", b.segmentAtLocalX((i16)500), (i32)-1);

    // ---- elision: 6 one-char segments, narrow width ------------------------
    UXBreadcrumb* e = new UXBreadcrumb();
    e.addSegment((u8*)"A", (i32)0);
    e.addSegment((u8*)"B", (i32)1);
    e.addSegment((u8*)"C", (i32)2);
    e.addSegment((u8*)"D", (i32)3);
    e.addSegment((u8*)"E", (i32)4);
    e.addSegment((u8*)"F", (i32)5);
    // each w = 12+7 = 19; total 19*6 + 14*5 = 184 -> doesn't fit in 140
    e.layout((i16)140);
    check("elided", e.showEllipsis ? (i32)1 : (i32)0, (i32)1);
    check("first stays visible", vis(e, (i32)0), (i32)1);
    check("a middle segment is hidden (B)", vis(e, (i32)1), (i32)0);
    check("a middle segment is hidden (D)", vis(e, (i32)3), (i32)0);
    check("last stays visible", vis(e, (i32)5), (i32)1);
    check("second-last visible (E)", vis(e, (i32)4), (i32)1);
    check("three visible: first + two trailing", visibleCount(e), (i32)3);
    check("first at x=0", (i32)e.segAt((i32)0).x, (i32)0);
    // ellipsisX = firstW(19) + sep(14) = 33
    check("ellipsis position", (i32)e.ellipsisX, (i32)33);
    // trailing placed after ellipsis: x = 33 + ellW(27) + sep(14) = 74
    check("E placed after ellipsis", (i32)e.segAt((i32)4).x, (i32)74);
    check("F after E (74+19+14)", (i32)e.segAt((i32)5).x, (i32)107);

    // hit-test across the elided layout
    check("hit first (A)", e.segmentAtLocalX((i16)5), (i32)0);
    check("hit in the ellipsis gap -> nothing", e.segmentAtLocalX((i16)45), (i32)-1);
    check("hit E", e.segmentAtLocalX((i16)80), (i32)4);
    check("hit F", e.segmentAtLocalX((i16)110), (i32)5);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXBreadcrumb — fitting layout, middle elision, and hit-testing.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
