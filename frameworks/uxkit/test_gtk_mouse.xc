// test_gtk_mouse.xc — pointer input on GTK4 (the `gtk-mouse` gate).
//
// Until now the GTK backend had NO toolkit-level pointer input: native widgets
// fired their own "clicked" signals, but a press on anything UXKit draws itself
// went nowhere, and trackDragStep was a stub that returned 0.  Every
// toolkit-drawn drag — a split divider, a slider thumb, a scroll drag, an
// editor moving an object on a canvas — therefore did nothing at all on Linux.
//
// It failed by doing NOTHING, which is why it survived: a divider that will not
// move looks like a toolkit without draggable dividers, not like a bug.  So
// this gate asserts the two halves separately and out loud —
//
//   a press reaches the VIEW under it, in the view's own coordinates
//   trackDragStep reports positions while the button is down, and stops at up
//
// The events are posted through the same entry points the real GdkEvents use
// (ux_gtk_post_*), because a headless gate has no pointer; what is being tested
// is everything downstream of the event arriving.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern void ux_gtk_post_press(i32 handle, i32 x, i32 y);
extern void ux_gtk_post_motion(i32 x, i32 y);
extern void ux_gtk_post_release(void);
extern i32 ux_gtk_has_shield(i32 handle);
extern i32 ux_gtk_shield_on_top(i32 handle);
extern i32 ux_gtk_get_check(i32 handle, i32 node);
extern i32 ux_gtk_get_align(i32 handle, i32 node);

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

// A view that only remembers being pressed, and where.
class ProbeView : UXView
    {
    i32 hits;
    i32 lastX;
    i32 lastY;
    void init(void)
        {
        super.init();
        hits = (i32)0;
        lastX = (i32)-1;
        lastY = (i32)-1;
        }
    bool acceptsFirstResponder(void)
        {
        return false;
        }
    void mouseDown(UXEvent* e)
        {
        hits = hits + (i32)1;
        UXRect a = self.absoluteFrame();
        lastX = (i32)e.x - (i32)a.x; // where inside ME the press landed
        lastY = (i32)e.y - (i32)a.y;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no GTK display\n");
        return;
        }

    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    app.addWindow(win);
    win.open((u8*)"mouse", UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300), content);

    ProbeView* a = new ProbeView();
    ProbeView* b = new ProbeView();
    content.addSubview(a, UXGeom.make((i16)10, (i16)10, (i16)100, (i16)60));
    content.addSubview(b, UXGeom.make((i16)200, (i16)100, (i16)100, (i16)60));
    win.tree.finalise();
    win.displayAll();

    // ---- a press reaches the right view -------------------------------------
    ux_gtk_post_press(win.handle, (i32)40, (i32)30);
    check("a press reaches the view under it", a.hits, (i32)1);
    check("in the view's own coordinates, x", a.lastX, (i32)30);
    check("and y", a.lastY, (i32)20);
    check("and not its neighbour", b.hits, (i32)0);

    ux_gtk_post_press(win.handle, (i32)250, (i32)130);
    check("a second press finds the OTHER view", b.hits, (i32)1);
    check("and the first is not pressed again", a.hits, (i32)1);

    // A press on bare content hits neither probe — the hit-test is real, not
    // "whichever view was added last".
    ux_gtk_post_press(win.handle, (i32)380, (i32)280);
    check("a press on empty space hits no probe", a.hits + b.hits, (i32)2);

    // ---- the drag step -------------------------------------------------------
    // trackDragStep is the primitive every toolkit-drawn drag is built on.
    // Returning 0 while the button is DOWN is the old bug: the caller's
    // `while (trackDragStep(...))` never runs its body even once.
    ux_gtk_post_press(win.handle, (i32)40, (i32)30);
    ux_gtk_post_motion((i32)55, (i32)44);
    i32 x = (i32)0;
    i32 y = (i32)0;
    check("with the button down, a step is reported", d.trackDragStep(&x, &y), (i32)1);
    check("and it carries the pointer's x", x, (i32)55);
    check("and its y", y, (i32)44);

    ux_gtk_post_motion((i32)70, (i32)61);
    check("a second step follows", d.trackDragStep(&x, &y), (i32)1);
    check("to the new position", x, (i32)70);

    ux_gtk_post_release();
    check("once the button is up the drag ends", d.trackDragStep(&x, &y), (i32)0);
    // And stays ended: a caller that loops must not be handed a phantom step.
    check("and stays ended", d.trackDragStep(&x, &y), (i32)0);

    // ---- the input shield ----------------------------------------------------
    // A design surface needs a click to SELECT the control under it rather than
    // operate it, and a native GtkButton takes its own presses.  The shield is a
    // bare widget placed last in the GtkFixed, so the pointer reaches it first.
    //
    // What this gate can and cannot prove: that the shield exists and is the
    // widget the pointer lands on, which is what decides the outcome.  It
    // cannot post a press through GTK's real hit-test -- GTK4 removed synthetic
    // event injection -- so the interception itself is proven on AppKit
    // (appkit-shield, which injects a real NSEvent) and asserted structurally
    // here.  Worth revisiting if GTK ever regains event injection.
    UXButton* nb = new UXButton();
    nb.setTitle((u8*)"Live");
    content.addSubview(nb, UXGeom.make((i16)20, (i16)200, (i16)80, (i16)26));
    UXShieldView* sh = new UXShieldView();
    content.addSubview(sh, UXGeom.make((i16)0, (i16)180, (i16)400, (i16)120));
    win.tree.finalise();
    win.displayAll();
    check("the shield is realized as a real widget", ux_gtk_has_shield(win.handle), (i32)1);
    check("and is the topmost child, so the pointer reaches it first",
          ux_gtk_shield_on_top(win.handle), (i32)1);

    // A control realized AFTER the shield goes in above it; the realize pass
    // must put the shield back on top or it works only until the next widget.
    UXButton* later = new UXButton();
    later.setTitle((u8*)"Later");
    content.addSubview(later, UXGeom.make((i16)200, (i16)210, (i16)80, (i16)26));
    win.tree.finalise();
    win.displayAll();
    check("a widget realized later does not bury the shield",
          ux_gtk_shield_on_top(win.handle), (i32)1);

    // ---- a toggle changed AFTER realize still reaches the switch -------------
    // Not about the pointer, but the same failure shape and the same gate is the
    // cheapest place to guard it: GTK's realize pass pushed frame, hidden and
    // enabled to an existing control and skipped the TOGGLE, so a check box
    // built checked looked right and one checked later did not.  Every other
    // backend pushes it every display; GTK was the one that did not.
    //
    // Read back off the GtkCheckButton, not off the peer: "we set the field"
    // and "the switch moved" are different claims.
    UXCheckbox* cb = new UXCheckbox();
    cb.setTitle((u8*)"Tick");
    content.addSubview(cb, UXGeom.make((i16)20, (i16)240, (i16)120, (i16)24));
    win.tree.finalise();
    win.displayAll();
    check("a check box starts off", ux_gtk_get_check(win.handle, (i32)cb.index), (i32)0);
    cb.setChecked(true);
    win.displayAll();
    check("checking it after realize moves the SWITCH",
          ux_gtk_get_check(win.handle, (i32)cb.index), (i32)1);
    cb.setChecked(false);
    win.displayAll();
    check("and unchecking moves it back",
          ux_gtk_get_check(win.handle, (i32)cb.index), (i32)0);

    // ---- text alignment reaches the real widget -----------------------------
    // A column of "Name:" "Size:" labels only lines its colons up if the text is
    // right-aligned in boxes whose right edges agree.  Read back off the
    // GtkLabel, not the peer: "we set the field" is not "the text moved".
    UXLabel* lb = new UXLabel();
    lb.setTitle((u8*)"Name:");
    content.addSubview(lb, UXGeom.make((i16)20, (i16)270, (i16)120, (i16)24));
    win.tree.finalise();
    win.displayAll();
    check("a label starts left-aligned", ux_gtk_get_align(win.handle, (i32)lb.index), (i32)UX_ALIGN_LEFT);
    lb.setAlignment((i32)UX_ALIGN_RIGHT);
    win.displayAll();
    check("right-aligning it moves the TEXT", ux_gtk_get_align(win.handle, (i32)lb.index), (i32)UX_ALIGN_RIGHT);
    lb.setAlignment((i32)UX_ALIGN_CENTER);
    win.displayAll();
    check("and centring is centre, not right", ux_gtk_get_align(win.handle, (i32)lb.index), (i32)UX_ALIGN_CENTER);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: GTK delivers presses to views and tracks a drag\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
