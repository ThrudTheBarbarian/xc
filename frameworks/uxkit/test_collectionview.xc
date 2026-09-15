// test_collectionview.xc — UXCollectionView grid layout, hit-test, and selection (pure geometry).
#import <Stdio.xc>
#import "UXCollectionView.xc"

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
    // defaults: itemW=itemH=64, hGap=vGap=16, inset=12.  stepX=stepY=80.
    UXCollectionView* cv = new UXCollectionView();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        cv.addItem((Object*)0, (u8*)"icon");
        }
    check("count", cv.count(), (i32)10);

    // width 300: usable = 300-24 = 276; cols = (276+16)/80 = 3
    check("columns at 300", cv.columnsFor((i16)300), (i32)3);
    cv.layout((i16)300);
    // item 0 at (inset,inset) = (12,12)
    check("item0 x", (i32)cv.itemAt((i32)0).x, (i32)12);
    check("item0 y", (i32)cv.itemAt((i32)0).y, (i32)12);
    // item 1 -> col1: x = 12 + 80 = 92
    check("item1 x", (i32)cv.itemAt((i32)1).x, (i32)92);
    // item 3 -> row1 col0: x=12, y = 12+80 = 92
    check("item3 x wraps to col0", (i32)cv.itemAt((i32)3).x, (i32)12);
    check("item3 y is row 1", (i32)cv.itemAt((i32)3).y, (i32)92);
    // 10 items, 3 cols -> 4 rows; contentHeight = 24 + 4*80 - 16 = 328
    check("content height (4 rows)", cv.contentHeight, (i32)328);

    // a narrower width gives fewer columns
    check("columns at 180", cv.columnsFor((i16)180), (i32)2); // (156+16)/80 = 2
    // a very narrow width still gives at least 1
    check("columns floor at 1", cv.columnsFor((i16)40), (i32)1);

    // hit-test (layout at 300, 3 cols)
    cv.layout((i16)300);
    check("hit item0 centre", cv.itemAtPoint((i16)40, (i16)40), (i32)0);
    check("hit item1 centre", cv.itemAtPoint((i16)120, (i16)40), (i32)1);
    check("hit item3 (row1 col0)", cv.itemAtPoint((i16)40, (i16)120), (i32)3);
    check("hit in the gap between items", cv.itemAtPoint((i16)84, (i16)40), (i32)-1); // x=84 is in the 76..92 gap
    check("hit in the inset margin", cv.itemAtPoint((i16)4, (i16)4), (i32)-1);
    check("hit past the last item", cv.itemAtPoint((i16)40, (i16)400), (i32)-1);

    // selection (via UXIndexSet)
    cv.selectItem((i32)2);
    check("one selected", cv.selectionCount(), (i32)1);
    check("item2 selected", cv.isSelected((i32)2) ? (i32)1 : (i32)0, (i32)1);
    cv.addToSelection((i32)5);
    check("two selected", cv.selectionCount(), (i32)2);
    check("first selected is 2", cv.firstSelected(), (i32)2);
    cv.toggleSelection((i32)2);
    check("toggled 2 off", cv.isSelected((i32)2) ? (i32)1 : (i32)0, (i32)0);
    check("now one selected (5)", cv.selectionCount(), (i32)1);
    cv.selectItem((i32)9); // single-select replaces
    check("single-select clears others", cv.selectionCount(), (i32)1);
    check("selected is 9", cv.isSelected((i32)9) ? (i32)1 : (i32)0, (i32)1);
    cv.deselectAll();
    check("cleared", cv.selectionCount(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXCollectionView — grid layout, column fitting, hit-test, UXIndexSet selection.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
