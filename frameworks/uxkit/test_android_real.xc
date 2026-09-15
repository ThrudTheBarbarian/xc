// test_android_real.xc — the REAL neutral UXKit layer running native on
// Android (UXAndroidDriver): the seventh backend's bring-up gate, sibling of
// test_ios_real.xc — same run-loop twist (the platform owns the UI thread, so
// main() is two calls deep and the test body runs from the posted entry, on
// the UI thread), plus Android's own: main() itself runs on the glue's
// detached thread and never comes back from the shell.
//
// Two proofs, the iOS pair:
//   - the CUSTOM view paints through drawRect -> UXAndroidGraphics -> Canvas,
//     verified by bitmap readback (ux_and_render / ux_and_pixel);
//   - the button is a REAL android.widget.Button (realizeTree overlay), fired
//     through the platform's own listener machinery (performClick ->
//     OnClickListener -> the bridge dex -> nativeFire), landing in the
//     neutral action via the fire-by-peer path.
// Plus the §10 memgate: close -> liveNativeCount 0.  And formFactorClass
// answers phone/tablet.  PASS/FAIL arrive on logcat tag `xcapp` (the glue's
// stdout pipe).
//
//   Build+run:  sh run_android_real.sh   (emulator; two-lib APK)
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// The rig surface (libUXAndroid.c), not part of the driver.
extern void ux_and_render(i32 handle);
extern i32 ux_and_pixel(i32 x, i32 y);
extern void ux_and_test_click(i32 handle, i32 node);

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
        g.drawText((u8*)"UXKit on Android", (i16)14, (i16)46, (i32)1, (i32)0);
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

    i32 gCheckFired;
class Controller : Object
    {
    void onButton(UXControl* c)
        {
        gButtonFired = gButtonFired + (i32)1;
        Stdio.printf("button-fired (real OnClickListener)\n");
        }
    void onCheck(UXControl* c)
        {
        gCheckFired = gCheckFired + (i32)1;
        UXCheckbox* cb = (UXCheckbox* ?)c;
        Stdio.printf("check-fired checked=%d (native CheckBox state adopted)\n",
                     cb != (UXCheckbox*)0 && cb.isChecked() ? (i32)1 : (i32)0);
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

// The test body — the posted-entry moment, on the UI thread, the widgets live.
void testBody(void)
    {
    gCanvasDrew = (i32)0;
    gViewClicked = (i32)0;
    gButtonFired = (i32)0;
    gCheckFired = (i32)0;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_and_quit((i32)1);
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
    UXCheckbox* check = new UXCheckbox();
    check.setTitle((u8*)"Enable");
    check.setAction(&ctl.onCheck);
    win.open((u8*)"UXKit on Android", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)140), canvas);
    canvas.addSubview(button, UXGeom.make((i16)8, (i16)90, (i16)80, (i16)32));
    canvas.addSubview(check, UXGeom.make((i16)100, (i16)90, (i16)110, (i16)32));
    win.displayAll(); // realizeTree overlays the REAL Button + CheckBox

    ux_and_render((i32)1);                        // the offscreen Bitmap walk
    i32 pCanvas = ux_and_pixel((i32)30, (i32)20); // inside the canvas box (10..60, 10..40)
    Stdio.printf("window=%d pixel canvas(30,20)=%d\n", (i16)gDriver.liveNativeCount(), pCanvas);

    // The canvas click through the neutral path; the button through the
    // platform itself (performClick -> the bridge dex's OnClickListener).
    UXEvent* ev = new UXEvent();
    ev.kind = (u8)UXEventMouseDown;
    ev.x = (i16)30;
    ev.y = (i16)20;
    win.dispatchMouse(ev);
    ux_and_test_click((i32)1, (i32)button.index);
    // The value path: performClick on the REAL CheckBox toggles it natively,
    // and its new state lands in the peer through nativeValue.
    ux_and_test_click((i32)1, (i32)check.index);
    bool checkAdopted = check.isChecked();

    win.close();
    i32 after = gDriver.liveNativeCount();
    Stdio.printf("native-after-close=%d\n", (i16)after);

    bool pass = gCanvasDrew >= (i32)1 && isGrey(pCanvas) && gViewClicked >= (i32)1 && gButtonFired == (i32)1 && after == (i32)0 && gCheckFired == (i32)1 && checkAdopted && (ff == (i32)UX_FORM_PHONE || ff == (i32)UX_FORM_TABLET);
    Stdio.printf(pass ? "PASS: the neutral UXKit layer runs native on Android (paint+pixels+native action+memgate)\n"
                      : "FAIL: 1\n");
    ux_and_quit(pass ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver(); // the ONE Android-aware line (plus the shell below)
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run(); // posts to the UI thread — never returns
    }
