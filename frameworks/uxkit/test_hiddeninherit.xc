// test_hiddeninherit.xc — hiding a container hides its NATIVE children too.
//
// A native control is its own NSView, positioned absolutely, so it does not
// vanish merely because an ancestor did.  The app-drawn walk skips a hidden
// subtree, so custom drawing disappeared correctly and native controls stayed
// on screen — the two halves of the same tree disagreeing about what "hidden"
// means.
//
// It was invisible in the toolkit's own tests because the case needs a
// CONTAINER holding NATIVE controls, hidden AFTER it was realized.  UXTabView
// does exactly that, and an editor swapping one form for another does it on
// every click, which is where it turned up: selecting a second form drew it
// over the first instead of replacing it.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

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
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"inherit", UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300), content);

    // Two panes, each holding a NATIVE button — the shape UXTabView makes and
    // the shape an editor's form swap makes.
    UXView* paneA = new UXView();
    UXView* paneB = new UXView();
    content.addSubview(paneA, UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300));
    content.addSubview(paneB, UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300));
    UXButton* a = new UXButton();
    a.setTitle((u8*)"A");
    UXButton* b = new UXButton();
    b.setTitle((u8*)"B");
    paneA.addSubview(a, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
    paneB.addSubview(b, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
    win.tree.finalise();
    win.displayAll(); // realize: both buttons exist natively

    // Neither pane is hidden yet, so neither button is.
    check("A starts visible", d.effectiveHidden(win.tree.structHandle, (i32)a.index), (i32)0);
    check("B starts visible", d.effectiveHidden(win.tree.structHandle, (i32)b.index), (i32)0);

    // THE BUG: hiding the PANE left its native button on screen, because the
    // button's own hidden flag was still clear and that was the only thing
    // asked.
    paneB.setHidden(true);
    check("hiding a pane hides its native child",
          d.effectiveHidden(win.tree.structHandle, (i32)b.index), (i32)1);
    check("and leaves the other pane's child alone",
          d.effectiveHidden(win.tree.structHandle, (i32)a.index), (i32)0);
    check("the child's OWN flag is untouched — inheritance, not mutation",
          win.tree.hiddenOf(b.index) ? (i32)1 : (i32)0, (i32)0);

    // Swap them, which is the actual gesture being supported.
    paneB.setHidden(false);
    paneA.setHidden(true);
    check("after the swap B shows", d.effectiveHidden(win.tree.structHandle, (i32)b.index), (i32)0);
    check("and A hides", d.effectiveHidden(win.tree.structHandle, (i32)a.index), (i32)1);

    // A directly hidden control stays hidden even when its parent is visible.
    b.setHidden(true);
    check("a control hidden on its own merit stays hidden",
          d.effectiveHidden(win.tree.structHandle, (i32)b.index), (i32)1);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: hidden is inherited by native descendants\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
