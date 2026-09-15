// test_win32_real.xc — the M1 payoff: the REAL neutral UXKit layer, running on Win32.
//
// The seed (test_win32.xc) carried a self-contained mini-toolkit because the neutral classes
// still named GEM types.  That gap is now closed: UXView/UXWindow/UXViewTree name no GEM type,
// the OBJECT[] structure lives in the driver, and UXGraphics is a swappable protocol.  So THIS
// demo imports the ACTUAL UXWindow + UXView + UXViewTree and runs them on UXWin32Driver — the
// same classes an app writes once, now drawing through GDI under Wine.
//
//   Build+run:  sh run_win32_real.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
//
// Paint flows backend -> neutral seam -> app code (WM_PAINT -> ux_window_draw -> treeDraw ->
// ux_userdraw -> Canvas.drawRect, via GDI).  A click routes through the SAME tree.hitTest the
// GEM backend uses -> the driver's shadow-tree hit test -> Canvas.mouseDown.  Nothing here is
// Win32-aware except the one line that picks the backend.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// A custom view: exactly what an app subclass looks like.  It knows UXGraphics, not GDI.
class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8); // a themed-grey box
        g.drawText((u8*)"UXKit on Win32", (i16)14, (i16)16, (i32)1, (i32)0);
        Stdio.printf("fill=10,10,50,30\n");
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        Stdio.printf("view-mouseDown=%d,%d\n", (i32)e.x, (i32)e.y);
        }
    }

    // The app's controller: it owns the button's action, a plain bound method (no selector).
    class Controller : Object
    {
    // target/action, on Win32
    void onButton(UXControl* c)
        {
        Stdio.printf("button-fired\n");
        }
    }

    void
    main(void)
    {
    gDriver = new UXWin32Driver(); // the ONE Win32-aware line
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("boot failed\n");
        return;
        }
    Stdio.printf("register=1\n");

    // The real neutral window + a real neutral view + a real STOCK button — the same source
    // a GEM app writes.  open() forces the first paint, so drawRect and the button both paint.
    UXWindow* win = new UXWindow();
    Canvas* canvas = new Canvas();
    Controller* ctl = new Controller();

    UXButton* button = new UXButton();
    button.setTitle((u8*)"OK");
    button.setAction(&ctl.onButton);
    win.open((u8*)"UXKit", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
    canvas.addSubview(button, UXGeom.make((i16)8, (i16)70, (i16)56, (i16)18));
    win.displayAll(); // repaint now the button is in the tree
    Stdio.printf("window=%d\n", gDriver.liveNativeCount());

    // Two clicks, both routed through the neutral path: dispatchMouse -> tree.hitTest (the
    // driver's shadow-tree hit test) -> the deepest view.  (30,40) is the canvas; (30,76) is
    // the button, whose mouseDown fires the bound action.
    UXEvent* ev = new UXEvent();
    ev.kind = (u8)UXEventMouseDown;
    ev.x = (i16)30;
    ev.y = (i16)40;
    win.dispatchMouse(ev);
    ev.x = (i16)30;
    ev.y = (i16)76;
    win.dispatchMouse(ev);

    win.close();
    Stdio.printf("native-after-close=%d\n", gDriver.liveNativeCount()); // §10: back to zero
    Stdio.printf("done\n");
    }
