// test_viewremove.xc — removing a view detaches it from BOTH the tree and the
// parent's subview list.
//
// addSubview does two things — attach to the tree, and append to `subviews` —
// and removeFromSuperview used to undo only the first.  The parent then held a
// strong reference to a view that was no longer in the tree, so it leaked, and
// every walk over `subviews` (drawing, the autoresize pass) visited a view
// whose tree slot had gone.  Nothing failed loudly; it just quietly got worse
// the more an app rebuilt its content.
//
// Found while writing an editor that swaps one form for another on a canvas,
// which is exactly the workload that does this repeatedly.
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
void checkTrue(u8* what, bool got)
    {
    if (got)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
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
    win.open((u8*)"remove", UXGeom.make((i16)0, (i16)0, (i16)300, (i16)200), content);

    UXButton* a = new UXButton();
    a.setTitle((u8*)"A");
    UXButton* b = new UXButton();
    b.setTitle((u8*)"B");
    UXButton* c = new UXButton();
    c.setTitle((u8*)"C");
    content.addSubview(a, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
    content.addSubview(b, UXGeom.make((i16)10, (i16)40, (i16)60, (i16)20));
    content.addSubview(c, UXGeom.make((i16)10, (i16)70, (i16)60, (i16)20));
    check("three subviews", (i32)content.subviews.count(), (i32)3);

    // THE BUG: this used to leave the count at 3.
    b.removeFromSuperview();
    check("removing one drops the subview count", (i32)content.subviews.count(), (i32)2);
    checkTrue("and clears its superview", b.superview == (UXView*)0);

    // The RIGHT one went, and the survivors kept their order.
    checkTrue("the first survivor is still A", (UXView* ?)content.subviews.get((u16)0) == (UXView*)a);
    checkTrue("the second is now C",           (UXView* ?)content.subviews.get((u16)1) == (UXView*)c);

    // Removing something already detached must be a no-op, not a corruption:
    // an editor tearing down a form will hit this.
    b.removeFromSuperview();
    check("removing twice changes nothing", (i32)content.subviews.count(), (i32)2);

    // removeAllSubviews empties in one call, without the index-shifting trap
    // of removing children by position while the positions move.
    content.removeAllSubviews();
    check("removeAllSubviews empties the list", (i32)content.subviews.count(), (i32)0);
    checkTrue("and detaches each child", a.superview == (UXView*)0 && c.superview == (UXView*)0);

    // The view is reusable afterwards — this is the swap an editor performs.
    UXButton* e = new UXButton();
    e.setTitle((u8*)"E");
    content.addSubview(e, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
    check("the emptied view accepts new children", (i32)content.subviews.count(), (i32)1);

    // And on an already-empty view it is simply harmless.
    UXView* empty = new UXView();
    content.addSubview(empty, UXGeom.make((i16)100, (i16)10, (i16)40, (i16)40));
    empty.removeAllSubviews();
    check("removeAllSubviews on an empty view is a no-op", (i32)empty.subviews.count(), (i32)0);

    // THE SYMPTOM THAT FOUND THIS.  A removed node keeps its slot in the
    // shadow array, and realizeTree walks every slot — so a removed view was
    // re-realized, and structAbsFrame on a parentless node returns its LOCAL
    // coordinates, putting it at the WINDOW'S TOP-LEFT on top of everything.
    // Rebuilding a panel (an inspector re-rendering per selection) did it on
    // every click.
    UXView* host = new UXView();
    content.addSubview(host, UXGeom.make((i16)200, (i16)150, (i16)180, (i16)100));
    UXButton* gone = new UXButton();
    gone.setTitle((u8*)"gone");
    host.addSubview(gone, UXGeom.make((i16)8, (i16)8, (i16)60, (i16)20));
    win.tree.finalise();
    win.displayAll();
    check("while attached it is visible",
          d.effectiveHidden(win.tree.structHandle, (i32)gone.index), (i32)0);
    i32 goneIdx = (i32)gone.index;
    host.removeAllSubviews();
    check("once removed it is DETACHED",
          d.isDetached(win.tree.structHandle, goneIdx), (i32)1);
    check("and therefore not shown, wherever realize walks",
          d.effectiveHidden(win.tree.structHandle, goneIdx), (i32)1);
    win.displayAll(); // a realize pass must not resurrect it
    check("still not shown after a re-realize",
          d.effectiveHidden(win.tree.structHandle, goneIdx), (i32)1);
    check("the host itself is unaffected",
          d.effectiveHidden(win.tree.structHandle, (i32)host.index), (i32)0);

    win.close();
    check("no native objects leaked", gDriver.liveNativeCount(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: removal detaches from the tree AND the subview list\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
