// test_gtk_real.xc — the REAL neutral UXKit layer running native on GTK4
// (UXGtkDriver): the Linux-desktop backend's bring-up gate, sibling of
// test_ios_real.xc.  Same two proofs: the custom view painting through
// drawRect -> UXCairoGraphics (verified by the offscreen cairo readback),
// and a REAL GtkButton fired through its own "clicked" signal into the
// neutral action via fire-by-peer.  Plus the §10 memgate.  Runs wherever
// gtk_init succeeds (a GdkMacosDisplay here; X11/Wayland on Linux).
//
//   Build+run:  sh run_gtk_real.sh
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// The rig surface (libUXGtk.c), not part of the driver.
extern void ux_gtk_render(i32 handle);
extern i32 ux_gtk_pixel(i32 x, i32 y);
extern void ux_gtk_test_click(i32 handle, i32 node);

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
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8);
        g.drawText((u8*)"UXKit on GTK", (i16)14, (i16)46, (i32)1, (i32)0);
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
        Stdio.printf("button-fired (real clicked signal)\n");
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
    gDriver = new UXGtkDriver(); // the ONE GTK-aware line
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }
    Stdio.printf("boot ok screen=%dx%d formFactor=%d\n", (i16)sw, (i16)sh, (i16)gDriver.formFactorClass());

    UXWindow* win = new UXWindow();
    Canvas* canvas = new Canvas();
    Controller* ctl = new Controller();
    UXButton* button = new UXButton();
    button.setTitle((u8*)"OK");
    button.setAction(&ctl.onButton);
    win.open((u8*)"UXKit on GTK", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)140), canvas);
    canvas.addSubview(button, UXGeom.make((i16)8, (i16)90, (i16)80, (i16)32));
    win.displayAll(); // realizeTree: the REAL GtkButton

    ux_gtk_render((i32)1);
    i32 pCanvas = ux_gtk_pixel((i32)30, (i32)20);
    Stdio.printf("window=%d pixel canvas(30,20)=%d\n", (i16)gDriver.liveNativeCount(), pCanvas);

    UXEvent* ev = new UXEvent();
    ev.kind = (u8)UXEventMouseDown;
    ev.x = (i16)30;
    ev.y = (i16)20;
    win.dispatchMouse(ev);
    ux_gtk_test_click((i32)1, (i32)button.index); // the REAL clicked signal

    win.close();
    i32 after = gDriver.liveNativeCount();
    Stdio.printf("native-after-close=%d\n", (i16)after);

    bool pass = gCanvasDrew >= (i32)1 && isGrey(pCanvas) && gViewClicked >= (i32)1 && gButtonFired == (i32)1 && after == (i32)0;
    Stdio.printf(pass ? "PASS: the neutral UXKit layer runs native on GTK (paint+pixels+native action+memgate)\n"
                      : "FAIL: 1\n");
    }
