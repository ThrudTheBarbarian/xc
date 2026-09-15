// test_toolbar.xc — UXToolbar layout: fixed items, flexible spaces, overflow, hit-test.
#import <Stdio.xc>
#import "UXToolbar.xc"

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
    // defaults: inset=8, spacing=6.

    // ---- flexible space pushes a trailing item to the right ----------------
    UXToolbar* tb = new UXToolbar();
    tb.addItem((u8*)"new", (u8*)"New", (i32)1, (i16)50);
    tb.addItem((u8*)"open", (u8*)"Open", (i32)2, (i16)50);
    tb.addFlexibleSpace();
    tb.addItem((u8*)"info", (u8*)"Info", (i32)3, (i16)50);
    check("count", tb.count(), (i32)4);

    tb.layout((i16)300);
    // fixedTotal = 50+50+50 = 150; gaps = 3*6 = 18; avail = 300-16 = 284; flex = 284-150-18 = 116
    check("new at inset", (i32)tb.itemAt((i32)0).x, (i32)8);
    check("open after new (8+50+6)", (i32)tb.itemAt((i32)1).x, (i32)64);
    // flex item at index2: x = 64+50+6 = 120, w = 116
    check("flex x", (i32)tb.itemAt((i32)2).x, (i32)120);
    check("flex absorbs leftover", (i32)tb.itemAt((i32)2).w, (i32)116);
    // info at index3: x = 120 + 116 + 6 = 242, i.e. pushed right
    check("info pushed right", (i32)tb.itemAt((i32)3).x, (i32)242);
    check("no overflow", tb.overflow(), (i32)0);

    // hit-test (spaces are not hittable)
    check("hit New", tb.itemAtLocalX((i16)20), (i32)0);
    check("hit Open", tb.itemAtLocalX((i16)70), (i32)1);
    check("hit in flex space -> nothing", tb.itemAtLocalX((i16)150), (i32)-1);
    check("hit Info", tb.itemAtLocalX((i16)250), (i32)3);

    // ---- overflow: too many fixed items, no flex ---------------------------
    UXToolbar* ov = new UXToolbar();
    for (i32 i = (i32)0; i < (i32)8; i = i + (i32)1)
        {
        ov.addItem((u8*)"x", (u8*)"Item", (i32)i, (i16)60);
        }
    // 8 items * 60 + 7*6 gaps = 480+42 = 522; in width 250 most overflow
    ov.layout((i16)250);
    check("some items overflowed", ov.overflow() > (i32)0 ? (i32)1 : (i32)0, (i32)1);
    // first item is visible and placed
    check("first item visible", ov.itemAt((i32)0).visible ? (i32)1 : (i32)0, (i32)1);
    // the very last item overflowed (not visible)
    check("last item overflowed", ov.itemAt((i32)7).visible ? (i32)1 : (i32)0, (i32)0);
    // how many fit: within width 250, inset 8 each side -> usable ~234; each item 60+6 -> 3 fit (3*66=198, 4th=264>242)
    i32 visN = (i32)0;
    for (i32 i = (i32)0; i < (i32)8; i = i + (i32)1)
        {
        if (ov.itemAt(i).visible)
            {
            visN = visN + (i32)1;
            }
        }
    check("3 items fit before overflow", visN, (i32)3);
    check("overflow count is 5", ov.overflow(), (i32)5);

    // ---- separators + spaces ----------------------------------------------
    UXToolbar* sp = new UXToolbar();
    sp.addItem((u8*)"a", (u8*)"A", (i32)1, (i16)40);
    sp.addSeparator();
    sp.addItem((u8*)"b", (u8*)"B", (i32)2, (i16)40);
    sp.layout((i16)200);
    check("separator laid out between", (i32)sp.itemAt((i32)1).w, (i32)2);
    check("separator is not hittable as an item", sp.itemAtLocalX((i16)(sp.itemAt((i32)1).x)), (i32)-1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXToolbar — flexible-space distribution, overflow, separators, hit-test.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
