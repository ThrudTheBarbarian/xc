// showcase_web.xc — the web contact sheet: every widget in one window on the
// real canvas backend, one screengrab, ten crops (capture.sh).
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "showcase_widgets.xc"

extern void ux_capture_done(void); // the page: title -> DONE

void main(void)
    {
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"sheet", UXGeom.make(0, 0, 440, 300), content);
    buildSheet(content);
    win.tree.finalise();
    win.displayAll();
    wd.webPresentAll();
    ux_capture_done();
    }
