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
#import "UXShapePath.xc"
#import "UXPainter.xc"
#import "UXEvent.xc"

// The rig surface (libUXAndroid.c), not part of the driver.
extern void ux_and_render(i32 handle);
extern i32 ux_and_pixel(i32 x, i32 y);

// The two rows the dash gate compares (see Canvas.drawRect): same call, same run, same phase.
#define DASH_YA 66
#define DASH_YB 78
// A third row, for the other half of the client's question: a run SHORTER than the stroke's width
// ([2,2] at width 6) — a dash still, on every backend whose dasher is a real stroker.
#define DASH_YC 72
// And a row for the ASCENT: cap-height glyphs and no descender, so the last inked row is the baseline
// the metric names (see main).  Clear of the button's frame (which ends at y=122), so the scan finds
// glyphs and nothing else.
#define METRIC_Y 130
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
        // TWO subpaths and a dash run in ONE stroke call, at a known phase, so Skia's DashPathEffect
        // can be asked the same question the AppKit and cairo dashers were: does the phase restart at
        // the move?  An 85-px subpath with a 16-px run puts 85 % 16 = 5 px between the two rules.
        i32 pat[2];
        pat[0] = (i32)8;
        pat[1] = (i32)8;
        UXShapePath* dash = new UXShapePath();
        dash.moveTo((i16)10, (i16)DASH_YA);
        dash.lineTo((i16)95, (i16)DASH_YA);
        dash.moveTo((i16)10, (i16)DASH_YB);
        dash.lineTo((i16)95, (i16)DASH_YB);
        dash.setDash(&pat[0], (i32)2, (i32)0);
        UXPainter.strokePath(g, dash, (i16)6, UXPainter.rgb((i32)0, (i32)0, (i32)0));

        i32 fine[2];
        fine[0] = (i32)2;
        fine[1] = (i32)2;
        UXShapePath* shortDash = new UXShapePath();
        shortDash.moveTo((i16)10, (i16)DASH_YC);
        shortDash.lineTo((i16)95, (i16)DASH_YC);
        shortDash.setDash(&fine[0], (i32)2, (i32)0);
        UXPainter.strokePath(g, shortDash, (i16)6, UXPainter.rgb((i32)0, (i32)0, (i32)0));

        g.drawTextFontRGBA((u8*)"HHHH", (i16)10, (i16)METRIC_Y, (u8*)"", (i32)24,
                           (i32)UXWEIGHT_NORMAL, false, (i32)0, (i32)0, (i32)0, (i32)255);
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

// Is this pixel part of the black dash?  Sampled mid-line and mid-run, so it is a decision and not an
// antialiased edge.
bool
inkPx(i32 px)
    {
    i32 r = (px >> (i32)16) & (i32)255;
    i32 g = (px >> (i32)8) & (i32)255;
    i32 b = px & (i32)255;
    return (r * (i32)30 + g * (i32)59 + b * (i32)11) / (i32)100 < (i32)128;
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
    win.open((u8*)"UXKit on Android", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)175), canvas);
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

    // THE DASH.  Same stroke call, same run, same phase, two subpaths — so the second row must repeat
    // the first pixel for pixel if the phase restarts at the move, and cannot if Skia carries it on.
    bool dashOn = inkPx(ux_and_pixel((i32)14, (i32)DASH_YA));
    bool dashOff = inkPx(ux_and_pixel((i32)22, (i32)DASH_YA));
    i32 d = (i32)0;
    for (i32 x = (i32)10; x <= (i32)95; x = x + (i32)1)
        {
        if (inkPx(ux_and_pixel(x, (i32)DASH_YA)) != inkPx(ux_and_pixel(x, (i32)DASH_YB)))
            {
            d = d + (i32)1;
            }
        }
    Stdio.printf("dash a(14)=%d a(22)=%d  rows differ at %d px\n",
                 (i16)(dashOn ? (i32)1 : (i32)0), (i16)(dashOff ? (i32)1 : (i32)0), (i16)d);
    // The short run: [2,2] at width 6 must still alternate — a 4-px period over 30 px is about 15
    // flips, so ten is a floor a solid line (0) or a one-off artefact cannot reach.
    i32 flips = (i32)0;
    i32 last = -(i32)1;
    for (i32 x = (i32)10; x <= (i32)40; x = x + (i32)1)
        {
        i32 cur = inkPx(ux_and_pixel(x, (i32)DASH_YC)) ? (i32)1 : (i32)0;
        if (last >= (i32)0 && cur != last)
            {
            flips = flips + (i32)1;
            }
        last = cur;
        }
    Stdio.printf("short run [2,2] at width 6: %d flips over 30 px\n", (i16)flips);
    bool dashOk = dashOn && !dashOff && d == (i32)0 && flips >= (i32)10;

    // THE TEXT METRICS: the measure at a numeric weight, and the face's ascent — the number a caller
    // with a canvas BASELINE converts into this seam's top-of-line y with.  Both go through this
    // backend's own font stack, so this is that backend answering, not a shared table.
    i32 mw400 = gDriver.textWidthWeight((u8*)"Hamburgefonstiv", (u8*)"", (i32)24, (i32)UXWEIGHT_NORMAL, false);
    i32 mw600 = gDriver.textWidthWeight((u8*)"Hamburgefonstiv", (u8*)"", (i32)24, (i32)UXWEIGHT_SEMIBOLD, false);
    i32 asc = gDriver.textAscent((u8*)"", (i32)24, (i32)UXWEIGHT_NORMAL, false);
    Stdio.printf("metrics width400=%d width600=%d ascent=%d\n", (i16)mw400, (i16)mw600, (i16)asc);
    // ...and the ascent is checked against pixels, not asserted: the METRIC_Y row is cap-height glyphs
    // with no descender, so the last inked row is the baseline the metric names.  This is what a caller
    // converting a canvas baseline into this seam's top-of-line y has to be able to trust.
    i32 firstInk = -(i32)1;
    i32 lastInk = -(i32)1;
    for (i32 y = METRIC_Y - (i32)4; y <= METRIC_Y + (i32)40; y = y + (i32)1)
        {
        for (i32 x = (i32)10; x <= (i32)80; x = x + (i32)1)
            {
            if (inkPx(ux_and_pixel(x, y)))
                {
                if (firstInk < (i32)0)
                    {
                    firstInk = y;
                    }
                lastInk = y;
                }
            }
        }
    Stdio.printf("ascent row ink y=%d..%d, baseline from the metric=%d\n",
                 (i16)firstInk, (i16)lastInk, (i16)(METRIC_Y + asc));
    bool metricsOk = mw400 > (i32)0 && mw600 >= mw400 && asc > (i32)8 && asc < (i32)40
                     && firstInk >= METRIC_Y && lastInk >= METRIC_Y + asc - (i32)2
                     && lastInk <= METRIC_Y + asc - (i32)1;

    bool pass = gCanvasDrew >= (i32)1 && isGrey(pCanvas) && gViewClicked >= (i32)1 && gButtonFired == (i32)1 && after == (i32)0 && gCheckFired == (i32)1 && checkAdopted && (ff == (i32)UX_FORM_PHONE || ff == (i32)UX_FORM_TABLET) && dashOk && metricsOk;
    Stdio.printf(pass ? "PASS: the neutral UXKit layer runs native on Android (paint+pixels+native action+memgate+dash+metrics)\n"
                      : "FAIL: 1\n");
    ux_and_quit(pass ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver(); // the ONE Android-aware line (plus the shell below)
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run(); // posts to the UI thread — never returns
    }
