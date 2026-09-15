// test_web_real.xc — the REAL neutral UXKit layer running on the web driver (wasm32).
//
// The sibling of test_appkit_real.xc / test_win32_real.xc, and the design doc's
// `web-real` milestone (§5): the SAME neutral UXWindow + UXView + UXViewTree +
// UXButton, the only backend-aware line being `gDriver = new UXWebDriver()`.
// Paint flows webPresent -> the neutral content callback -> treeDraw ->
// ux_userdraw -> Canvas.drawRect via UXCanvasGraphics; a click routes through
// the SAME tree hit-test GEM and Win32 use; §10 returns to zero.
//
// Headless-deterministic under Node: the ux_web_node.js rig records the draw
// ops, and ux_test_pixel replays the fills — the same proof-by-readback the
// AppKit rig does with a bitmap.
//
//   Build+run:  sh run_web_real.sh
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// The rig's introspection surface (ux_web_node.js), not part of the driver.
extern i32 ux_test_pixel(i32 h, i32 x, i32 y);
extern i32 ux_test_presents(i32 h);

i32 gCanvasDrew;
i32 gViewClicked;
i32 gButtonFired;

// A custom view: exactly what an app subclass looks like.  It knows UXGraphics, not Canvas2D.
class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8); // themed-grey box (pen 8)
        g.drawText((u8*)"UXKit on the web", (i16)14, (i16)46, (i32)1, (i32)0);
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
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd; // the ONE web-aware line
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
    win.open((u8*)"UXKit on the web", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
    canvas.addSubview(button, UXGeom.make((i16)8, (i16)70, (i16)56, (i16)18));
    win.displayAll();   // accumulate the damage…
    wd.webPresentAll(); // …and present it: one consolidated paint (§3.2)
    Stdio.printf("window=%d presents=%d\n", gDriver.liveNativeCount(), ux_test_presents((i32)1));

    // Pixel proofs by replaying the recorded fills (window handle 1): the
    // canvas's grey box, and the button's grey face.
    i32 pCanvas = ux_test_pixel((i32)1, (i32)30, (i32)20); // inside canvas box (10..60, 10..40)
    i32 pButton = ux_test_pixel((i32)1, (i32)30, (i32)78); // inside button box (8..64, 70..88)
    Stdio.printf("pixel canvas(30,20)=%d button(30,78)=%d\n", pCanvas, pButton);

    // Two clicks through the neutral path: (30,20) hits the canvas; (30,78)
    // hits the button, whose mouseDown fires the bound action.
    UXEvent* ev = new UXEvent();
    ev.kind = (u8)UXEventMouseDown;
    ev.x = (i16)30;
    ev.y = (i16)20;
    win.dispatchMouse(ev);
    ev.x = (i16)30;
    ev.y = (i16)78;
    win.dispatchMouse(ev);

    i32 pres = ux_test_presents((i32)1); // read BEFORE close: destroy drops the rig's record
    win.close();
    i32 after = gDriver.liveNativeCount();
    Stdio.printf("native-after-close=%d\n", after);

    bool pass = gCanvasDrew >= (i32)1 && isGrey(pCanvas) && isGrey(pButton) && gViewClicked >= (i32)1 && gButtonFired == (i32)1 && after == (i32)0 && pres >= (i32)1;
    Stdio.printf(pass ? "PASS: the neutral UXKit layer runs on the web driver (paint+pixels+click+action)\n" : "FAIL: 1\n");
    }
