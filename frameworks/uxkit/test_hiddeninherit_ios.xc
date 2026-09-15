// test_hiddeninherit_ios.xc — hiding a container hides its NATIVE children, on iOS.
//
// The fourth copy of test_hiddeninherit.xc (AppKit, GTK, Win32 were already
// gated).  This one could not be written when the fix went in: the self-hosted
// compiler could not build ios-sim at all, so the iOS driver carried the change
// with a comment saying it was unverified and naming this file as the way to
// close it.  iOS builds again, so here it is.
//
// The bug: a native control is its own platform view, positioned absolutely, so
// it does not vanish merely because an ancestor did.  The app-drawn walk skips a
// hidden subtree, so custom drawing disappeared correctly while native controls
// stayed on screen — the two halves of one tree disagreeing about what "hidden"
// means.  It needs a CONTAINER holding NATIVE controls, hidden AFTER realize,
// which is exactly what a tab view does and what an editor's form swap does on
// every click.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 code);

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

void testBody(void)
    {
    gFails = (i32)0;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_ios_quit((i32)1);
        return;
        }
    UXIosDriver* d = (UXIosDriver* ?)gDriver;

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"inherit", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)480), content);

    // Two panes, each holding a NATIVE button — the shape a tab view makes, and
    // the shape an editor's form swap makes.
    UXView* paneA = new UXView();
    UXView* paneB = new UXView();
    content.addSubview(paneA, UXGeom.make((i16)0, (i16)0, (i16)320, (i16)480));
    content.addSubview(paneB, UXGeom.make((i16)0, (i16)0, (i16)320, (i16)480));
    UXButton* a = new UXButton();
    a.setTitle((u8*)"A");
    UXButton* b = new UXButton();
    b.setTitle((u8*)"B");
    paneA.addSubview(a, UXGeom.make((i16)10, (i16)10, (i16)80, (i16)32));
    paneB.addSubview(b, UXGeom.make((i16)10, (i16)10, (i16)80, (i16)32));
    win.tree.finalise();
    win.displayAll(); // realize: both buttons exist as real UIButtons

    check("A starts visible", d.effectiveHidden(win.tree.structHandle, (i32)a.index), (i32)0);
    check("B starts visible", d.effectiveHidden(win.tree.structHandle, (i32)b.index), (i32)0);

    // THE BUG: hiding the PANE left its native button on screen, because the
    // button's own hidden flag was still clear and that was the only thing asked.
    paneB.setHidden(true);
    check("hiding a pane hides its native child",
          d.effectiveHidden(win.tree.structHandle, (i32)b.index), (i32)1);
    check("and leaves the other pane's child alone",
          d.effectiveHidden(win.tree.structHandle, (i32)a.index), (i32)0);
    check("the child's OWN flag is untouched — inheritance, not mutation",
          win.tree.hiddenOf(b.index) ? (i32)1 : (i32)0, (i32)0);

    // The swap this exists to support.
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
        Stdio.printf("PASS: hidden is inherited by native descendants on iOS\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXIosDriver(); // the ONE iOS-aware line (plus the shell)
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run(); // UIApplicationMain — never returns
    }
