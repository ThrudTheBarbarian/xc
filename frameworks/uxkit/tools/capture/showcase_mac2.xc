// showcase_mac2.xc — SHEET 2 (containers + navigation) of the macOS contact sheet: one window, every widget (real
// native NSControls where they exist), ONE cached render and dump;
// capture.sh crops.  The desktop model: headless AppKit, where
// windowInvalidate caches the full view hierarchy — native controls
// included — via cacheDisplayInRect (the rig test_appkit_real proves).
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "showcase_widgets.xc"

extern i32 ux_ak_dump_ppm(u8* path);

void main(void)
    {
    ux_ak_set_capture((i32)1); // native controls, no window shown
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"sheet", UXGeom.make(0, 60, 440, 630), content);
    buildSheet2(content);
    win.tree.finalise();
    win.displayAll();                 // realize + the cached render
    gDriver.windowInvalidate((i32)1); // cacheDisplayInRect -> g_lastRep
    if (ux_ak_dump_ppm((u8*)"/tmp/ux-sheet2-mac.ppm") != (i32)0)
        {
        Stdio.printf("PASS: sheet shot\n");
        }
    else
        {
        Stdio.printf("FAIL: no dump\n");
        }
    }
