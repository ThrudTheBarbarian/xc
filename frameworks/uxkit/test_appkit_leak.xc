// test_appkit_leak.xc — AppKit's headless present path leaks nothing per frame.
//
// A headless window the size of the client's (1280 x 832) repainted 300 times through the toolkit's
// own path (setNeedsDisplay, displayIfNeeded, a turn of the pump), with the process's physical
// footprint taken after a warm-up and at the end.  Each frame used to leave one window-sized bitmap
// alive -- 4.26 MB a frame at this size -- because a headless app drains no autorelease pool.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

extern i32 ux_ak_test_footprint_kb(void);
i32 gFrame;
class Painted : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)(gFrame & (i32)255), (i32)90, (i32)160);
        }
    }
void main(void)
    {
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    gApp = app;
    Painted* v = new Painted();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Leak", UXGeom.make((i16)0, (i16)0, (i16)1280, (i16)832), v);
    app.addWindow(win);
    UXEvent* ev = new UXEvent();
    i32 before = (i32)0;
    for (gFrame = (i32)0; gFrame < (i32)320; gFrame = gFrame + (i32)1)
        {
        if (gFrame == (i32)20)
            {
            before = ux_ak_test_footprint_kb(); // after the warm-up
            }
        v.setNeedsDisplay();
        app.displayIfNeeded();
        gDriver.nextEvent((i32)1, ev);
        }
    i32 after = ux_ak_test_footprint_kb();
    i32 perFrame = (after - before) / (i32)300;
    Stdio.printf("footprint %d KB -> %d KB over 300 frames: %d KB a frame (a 1280x832 frame is 4160 KB)\n", before, after, perFrame);
    Stdio.printf(perFrame < (i32)64 ? "PASS: AppKit's headless present leaks nothing per frame\n" : "FAIL: %d KB a frame\n", perFrame);
    }
