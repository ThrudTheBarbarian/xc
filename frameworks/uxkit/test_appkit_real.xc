// test_appkit_real.xc — the REAL neutral UXKit layer running native on AppKit (UXAppKitDriver).
//
// The sibling of test_win32_real.xc: the SAME neutral UXWindow + UXView + UXViewTree + UXButton, the
// only backend-aware line being `gDriver = new UXAppKitDriver()`.  Paint flows AppKit -> the neutral
// seam -> app code (drawRect: -> the content callback -> treeDraw -> ux_userdraw -> Canvas.drawRect,
// via UXCocoaGraphics/NSGraphicsContext).  A click routes through the SAME tree hit-test the GEM and
// Win32 backends use.  Headless-deterministic: forces one paint (cacheDisplayInRect), reads pixels
// back to prove it landed, injects two clicks, checks §10 returns to zero.
//
//   Build+run:  sh run_appkit.sh   (xtc -A arm64 + the ObjC shim, native; no window shown)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

i32 ux_ak_pixel(i32 handle, i32 x, i32 y); // shim: readback from the last force-painted bitmap

i32 gCanvasDrew;
i32 gViewClicked;
i32 gButtonFired;

// A custom view: exactly what an app subclass looks like.  It knows UXGraphics, not AppKit.
class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8); // themed-grey box (pen 8)
        g.drawText((u8*)"UXKit on AppKit", (i16)14, (i16)46, (i32)1, (i32)0);
        gCanvasDrew = gCanvasDrew + (i32)1;
        Stdio.printf("canvas.drawRect fill=10,10,50,30\n");
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        gViewClicked = gViewClicked + (i32)1;
        Stdio.printf("view-mouseDown=%d,%d\n", (i32)e.x, (i32)e.y);
        }
    }

    // The app's controller: it owns the button's action, a plain bound method.
    class Controller : Object
    {
    void onButton(UXControl* c)
        {
        gButtonFired = gButtonFired + (i32)1;
        Stdio.printf("button-fired\n");
        }
    }

    bool
    isGrey(i32 px)
    {
    i32 r = (px >> (i32)16) & (i32)255;
    i32 g = (px >> (i32)8) & (i32)255;
    i32 b = px & (i32)255;
    return r > (i32)150 && r < (i32)220 && g > (i32)150 && g < (i32)220 && b > (i32)150 && b < (i32)220;
    }

void main(void)
    {
    gCanvasDrew = (i32)0;
    gViewClicked = (i32)0;
    gButtonFired = (i32)0;
    gDriver = new UXAppKitDriver(); // the ONE AppKit-aware line
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("boot failed\n");
        return;
        }
    Stdio.printf("boot ok screen=%dx%d\n", sw, sh);

    UXWindow* win = new UXWindow();
    Canvas* canvas = new Canvas();
    Controller* ctl = new Controller();
    UXButton* button = new UXButton();
    button.setTitle((u8*)"OK");
    button.setAction(&ctl.onButton);
    win.open((u8*)"UXKit on AppKit", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
    canvas.addSubview(button, UXGeom.make((i16)8, (i16)70, (i16)56, (i16)18));
    win.displayAll(); // force the paint now the button is in the tree
    Stdio.printf("window=%d\n", gDriver.liveNativeCount());

    // Pixel proofs (window handle 1): the canvas's grey box, and the button's grey box.
    i32 pCanvas = ux_ak_pixel((i32)1, (i32)30, (i32)20); // inside canvas box (10..60, 10..40)
    i32 pButton = ux_ak_pixel((i32)1, (i32)30, (i32)78); // inside button box (8..64, 70..88)
    Stdio.printf("pixel canvas(30,20)=%d button(30,78)=%d\n", pCanvas, pButton);

    // Two clicks through the neutral path: (30,20) hits the canvas; (30,78) hits the button, whose
    // mouseDown fires the bound action.
    UXEvent* ev = new UXEvent();
    ev.kind = (u8)UXEventMouseDown;
    ev.x = (i16)30;
    ev.y = (i16)20;
    win.dispatchMouse(ev);
    ev.x = (i16)30;
    ev.y = (i16)78;
    win.dispatchMouse(ev);

    win.close();
    i32 after = gDriver.liveNativeCount();
    Stdio.printf("native-after-close=%d\n", after);

    bool pass = gCanvasDrew >= (i32)1 && isGrey(pCanvas) && isGrey(pButton) && gViewClicked >= (i32)1 && gButtonFired == (i32)1 && after == (i32)0;
    Stdio.printf(pass ? "PASS: the neutral UXKit layer runs native on AppKit (paint+pixels+click+action)\n" : "FAIL\n");
    }
