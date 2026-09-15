// test_scroll.xc — the scrollbar is CHROME, and we write none of it.
//
// The AES owns the vertical bar: it draws it themed, runs the thumb drag, the arrow
// step, the track page and the mouse wheel, SHRINKS the work area when the bar
// appears, and clamps the offset.  A client's entire share of "scrolling" is:
//
//     1. say how big the content is        (wind_content_size)
//     2. draw translated by -scroll_y      (one subtraction, in UXWindow.layoutFor)
//     3. ...there is no 3.
//
// Step 3 is the interesting one.  The AES's own header tells an app to "add scroll_y
// back into any click Y it hit-tests" — and Xtg never does, because it does not have
// to.  We scroll by moving the tree's ROOT, and objc_find walks that same tree, so the
// objects genuinely ARE where the click says they are.  This test proves that: it
// scrolls, then hit-tests a screen point, and gets back the row actually visible there.
//
// If any of this needed a scrollbar drawn in xtc, it would be a bug in Xtg.

#import <Stdio.xc>
#import <GEM>
#import "UXGem.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"

#define ROWS 20
#define ROW_H 20
#define CONTENT_H (ROWS * ROW_H) // 400px of content...

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

// A row, and the document that holds them: plain G_BOXes, so GEM paints them and we
// write no drawing code at all.
class Row : UXView
    {
    UXKind kind(void)
        {
        return UXKindBox;
        }
    } class Doc : UXView
    {
    UXKind kind(void)
        {
        return UXKindBox;
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        gFails = (i32)0;

        Doc* doc = new Doc();
        win = new UXWindow();
        a.addWindow(win);
        win.open("Scroll", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)100), doc);

        // ROWS rows, each ROW_H tall, stacked — content far taller than the window.
        for (u16 i = (u16)0; i < (u16)ROWS; i++)
            {
            Row* r = new Row();
            doc.addSubview(r, UXGeom.make((i16)0, (i16)((i32)i * (i32)ROW_H),
                                          (i16)150, (i16)ROW_H));
            }
        win.tree.finalise();

        // ---- 1. tell the AES how big we really are --------------------------
        // MEASURE the bar, do not assume it: the work area must get NARROWER when the
        // content overflows, because the AES puts the scrollbar in the border and takes
        // the width out of our work area.
        i32 bx = (i32)0;
        i32 by = (i32)0;
        i32 bw = (i32)0;
        i32 bh = (i32)0;
        wind_get(win.handle, (i32)WF_WORKXYWH, &bx, &by, &bw, &bh);

        win.setContentSize((i16)150, (i16)CONTENT_H);
        win.displayAll(); // the AES lays out, sees the overflow, draws a bar

        // ...and the bar costs us work area — but that answer is gemd's, and it arrives as
        // MSG_SIZED.  Read WF_WORKXYWH without pumping and you read your OWN last request
        // back, not gemd's answer.  This is the same shape as a clamped rect (§11).
        a.pump((i32)200);

        i32 wx = (i32)0;
        i32 wy = (i32)0;
        i32 ww = (i32)0;
        i32 wh = (i32)0;
        wind_get(win.handle, (i32)WF_WORKXYWH, &wx, &wy, &ww, &wh);
        Stdio.printf("work area was %dx%d, now %dx%d  (%dpx of content)\n",
                     (i16)bw, (i16)bh, (i16)ww, (i16)wh, (i16)CONTENT_H);
        if (ww < bw)
            {
            Stdio.printf("  ok   the AES took %dpx of work area for the bar\n", (i16)(bw - ww));
            }
        else
            {
            Stdio.printf("  FAIL no bar: the work area did not narrow\n");
            gFails = gFails + (i32)1;
            }
        check("scrollY at rest", (i32)win.scrollY(), (i32)0);

        // ---- 2. scroll -------------------------------------------------------
        // A REQUEST.  The AES clamps it; the truth is what scrollY() says afterwards.
        win.scrollTo((i16)0, (i16)100);
        win.displayAll();
        check("scrollY after scrollTo(100)", (i32)win.scrollY(), (i32)100);

        // Row 5 lives at content y=100..119.  Scrolled by 100, it must now sit exactly
        // at the TOP of the work area.  (Index 6: 0 is the root, so row N is N+1.)
        UXRect r5 = win.tree.absoluteFrame((u16)6);
        Stdio.printf("row 5 (content y=100) is now at absolute y=%d\n", (i16)r5.y);
        check("row 5 sits at the top of the work area", (i32)r5.y, wy);

        // ---- 3. THE POINT: hit-testing scrolled with it, with no arithmetic ---
        // Click the top of the work area.  Before the scroll that was row 0; now it must
        // be row 5 — and Xtg added NOTHING back into the click to make that true.
        i32 hit = win.tree.hitTest((i16)(wx + (i32)10), (i16)(wy + (i32)2));
        Stdio.printf("click at the top of the work area -> object %d\n", (i16)hit);
        check("the click lands on row 5, not row 0", hit, (i32)6);

        // ---- 4. the AES clamps, we do not ------------------------------------
        i32 maxScroll = (i32)CONTENT_H - wh;
        win.scrollTo((i16)0, (i16)9999);
        Stdio.printf("asked for 9999; content - work = %d\n", (i16)maxScroll);
        check("clamped to content-work", (i32)win.scrollY(), maxScroll);

        win.scrollTo((i16)0, (i16)-50);
        check("clamped at 0", (i32)win.scrollY(), (i32)0);

        if (gFails == (i32)0)
            {
            Stdio.printf("PASS: the window scrolls, the clicks follow it, the AES clamps it,\n");
            Stdio.printf("      and Xtg contains NO SCROLLBAR CODE — the bar is gemd's chrome.\n");
            }
        else
            {
            Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
