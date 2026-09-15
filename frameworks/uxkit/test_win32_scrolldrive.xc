// test_win32_scrolldrive.xc — scrolling a NATIVE scroll container from code.
//
// scrollsNatively() is true on Win32/AppKit: the native container owns the offset, and UXScrollView
// used to answer that by returning early from scrollTo — which meant the toolkit could not scroll a
// view at all there.  Reveal-a-row, restore-a-saved-position and replay-a-recorded-scroll were all
// silently no-ops on two of the three backends.  The seam is nativeScrollTo/nativeScrollPx.
//
// The assertions are against the REAL CONTROL (GetScrollPos on the UXScroll32 child), not the model —
// a model-only check passes just as well when nothing reaches the window, which is exactly the trap
// the recorder tests fell into once already.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXScrollView.xc"
#import "UXTableView.xc"

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
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

// What the CONTROL says, straight from Win32 — the number the user's eyes are looking at.
UXWin32Driver* gDrv;
UXWindow* gWin;
UXScrollView* gSv;
// A table with more rows than fit — the case where "scroll to a row from code" actually matters.
class BigTable : Object<UXTableDataSource>
    {
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)200;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        return (u8*)"row";
        }
    } UXTableView* gTable;
BigTable* gSrc; // GLOBAL: UXTableView holds its data source weakly, so a temporary would be
                // freed the instant setDataSource returned and reloadData would read it back.

i32 nativePos(void)
    {
    pointer c = GetDlgItem(gDrv.windowNative(gWin.handle), (i32)W32_CTRL_ID_BASE + (i32)gSv.index);
    if (c == (pointer)0)
        {
        return (i32)-1;
        }
    return GetScrollPos(c, (i32)SB_VERT);
    }

void main(void)
    {
    gFails = (i32)0;
    gDrv = new UXWin32Driver();
    gDriver = gDrv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    gWin = new UXWindow();
    UXView* content = new UXView();
    gWin.open((u8*)"ScrollDrive", UXGeom.make((i16)40, (i16)40, (i16)320, (i16)240), content);
    gSv = new UXScrollView();
    content.addSubview(gSv, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)180));
    gSv.setLineHeight((i16)20);
    gSv.setDocumentHeight((i32)1200); // far taller than the viewport
    gWin.tree.finalise();
    gWin.displayAll(); // realizeTree makes the native container

    checkTrue("this backend scrolls natively", gDriver.scrollsNatively());
    checkTrue("the native container exists", nativePos() >= (i32)0);
    check("starts at the top", nativePos(), (i32)0);

    // The point of the whole exercise: a scroll from CODE moves the real control.
    gSv.scrollTo((i16)120);
    check("scrollTo moved the native container", nativePos(), (i32)120);
    check("...and scrollPx reports it", gSv.scrollPx(), (i32)120);

    // Reading back goes to the CONTROL, not to a remembered number: poke the control directly and
    // the toolkit must agree with it.
    pointer c = GetDlgItem(gDrv.windowNative(gWin.handle), (i32)W32_CTRL_ID_BASE + (i32)gSv.index);
    SetScrollPos(c, (i32)SB_VERT, (i32)60, (i32)1);
    check("scrollPx follows the control, not the model", gSv.scrollPx(), (i32)60);

    // Clamping is the container's, and it must not be possible to scroll into blank space.
    gSv.scrollTo((i16)30000);
    i32 atEnd = nativePos();
    checkTrue("a huge scroll clamps to the end", atEnd > (i32)0 && atEnd < (i32)1200);
    check("...and the toolkit agrees", gSv.scrollPx(), atEnd);
    gSv.scrollTo((i16)0);
    check("back to the top", nativePos(), (i32)0);

    // scrollByLines/scrollPage go through the same path, so they must move it too.
    gSv.scrollByLines((i32)3);
    check("scrollByLines moved it", nativePos(), (i32)60);
    gSv.scrollPage((i32)1);
    checkTrue("scrollPage moved it further", nativePos() > (i32)60);

    // ---- a TABLE's internal scroll ------------------------------------------------------------
    // A table gets no UXScroll32 of its own: the native ListView scrolls itself, so the same seam has
    // to reach a different control (LVM_SCROLL / LVM_GETTOPINDEX).  Without this, "scroll a table to
    // a row" — the common case — stayed broken even once plain scroll views worked.
    gTable = new UXTableView();
    content.addSubview(gTable, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)120));
    gTable.setRowHeight((i16)18);
    gTable.addColumn((u8*)"Name", (i16)200);
    gSrc = new BigTable();
    gTable.setDataSource(gSrc);
    gTable.reloadData();
    gWin.tree.finalise();
    gWin.displayAll();

    UXScrollView* tsv = gTable.scroll;
    checkTrue("the table has a scroll view", tsv != (UXScrollView*)0);
    if (tsv != (UXScrollView*)0)
        {
        check("table starts at the top", tsv.scrollPx(), (i32)0);
        tsv.scrollTo((i16)180);
        i32 got = tsv.scrollPx();
        checkTrue("scrolling the table moved the native list", got > (i32)0);
        // Row-quantised: a list scrolls in whole rows, so the answer is the nearest row boundary at
        // or below the request — not the exact pixel.  Assert that relationship, not a magic number.
        checkTrue("...to a row boundary at or below the request", got <= (i32)180);
        tsv.scrollTo((i16)0);
        check("table back to the top", tsv.scrollPx(), (i32)0);
        }

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the toolkit drives the native scroll container\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
