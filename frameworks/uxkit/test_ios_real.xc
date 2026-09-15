// test_ios_real.xc — the REAL neutral UXKit layer running native on iOS
// (UXIosDriver): the fifth backend's bring-up gate, sibling of
// test_appkit_real.xc — with the iOS twist the settled run-loop model
// demands: UIKit owns the main thread, so main() is one call deep and the
// test body runs from didFinishLaunching (the spike's Option B shape).
//
// Two proofs, deliberately stronger than the mac gate:
//   - the CUSTOM view paints through drawRect -> UXIosGraphics -> CGContext,
//     verified by bitmap readback (ux_ios_render / ux_ios_pixel);
//   - the button is a REAL native UIButton (realizeTree overlay), fired
//     through UIKit's own target-action machinery (ux_ios_post_click ->
//     sendActionsForControlEvents), landing in the neutral action via the
//     fire-by-peer path.  No synthetic hit-test for the native half.
// Plus the §10 memgate: close -> liveNativeCount 0.  And formFactorClass
// answers phone/tablet — the first backend that does not say desktop.
//
//   Build+run:  sh run_ios_real.sh   (simulator; clang stopgap link until 028)
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// The rig surface (libUXIos.m), not part of the driver.
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_render(i32 handle);
extern i32 ux_ios_pixel(i32 x, i32 y);
extern void ux_ios_post_click(i32 handle, i32 x, i32 y);
extern void ux_ios_quit(i32 rc);

i32 gCanvasDrew;
i32 gViewClicked;
i32 gButtonFired;

class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8); // themed-grey box (pen 8)
        g.drawText((u8*)"UXKit on iOS", (i16)14, (i16)46, (i32)1, (i32)0);
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
        Stdio.printf("button-fired (native target-action)\n");
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

// The test body — the applicationDidStart moment, on the main thread, UIKit live.
void testBody(void)
    {
    gCanvasDrew = (i32)0;
    gViewClicked = (i32)0;
    gButtonFired = (i32)0;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_ios_quit((i32)1);
        return;
        }
    i32 ff = gDriver.formFactorClass();
    Stdio.printf("boot ok screen=%dx%d formFactor=%d\n", (i16)sw, (i16)sh, (i16)ff);

    UXWindow* win = new UXWindow();
    Canvas* canvas = new Canvas();
    Controller* ctl = new Controller();
    UXButton* button = new UXButton();
    button.setTitle((u8*)"OK");
    button.setAction(&ctl.onButton);
    win.open((u8*)"UXKit on iOS", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)140), canvas);
    canvas.addSubview(button, UXGeom.make((i16)8, (i16)90, (i16)80, (i16)32));
    win.displayAll(); // realizeTree overlays the REAL UIButton

    ux_ios_render((i32)1);                        // one synchronous hierarchy render
    i32 pCanvas = ux_ios_pixel((i32)30, (i32)20); // inside the canvas box (10..60, 10..40)
    Stdio.printf("window=%d pixel canvas(30,20)=%d\n", (i16)gDriver.liveNativeCount(), pCanvas);

    // The canvas click through the neutral path; the button through UIKit itself.
    UXEvent* ev = new UXEvent();
    ev.kind = (u8)UXEventMouseDown;
    ev.x = (i16)30;
    ev.y = (i16)20;
    win.dispatchMouse(ev);
    ux_ios_post_click((i32)1, (i32)48, (i32)106); // centre of the native button

    win.close();
    i32 after = gDriver.liveNativeCount();
    Stdio.printf("native-after-close=%d\n", (i16)after);

    bool pass = gCanvasDrew >= (i32)1 && isGrey(pCanvas) && gViewClicked >= (i32)1 && gButtonFired == (i32)1 && after == (i32)0 && (ff == (i32)UX_FORM_PHONE || ff == (i32)UX_FORM_TABLET);
    Stdio.printf(pass ? "PASS: the neutral UXKit layer runs native on iOS (paint+pixels+native action+memgate)\n"
                      : "FAIL: 1\n");
    ux_ios_quit(pass ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXIosDriver(); // the ONE iOS-aware line (plus the shell below)
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run(); // UIApplicationMain — never returns
    }
