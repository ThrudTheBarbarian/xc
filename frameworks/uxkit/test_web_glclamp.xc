// test_web_glclamp.xc — the web GL view's canvas, in a real browser (run_web_glclamp.sh, headless
// Chrome).  The page lowers the GPU limit to 64 px; the app makes a 300 x 180 GL view, realizes the
// tree again, then grows the view to 400 x 240, telling the page after each step.  The page checks
// the canvases itself: one per GL view however often the tree is realized, its pixel size clamped to
// the limit with the view's aspect, its CSS size the view's (so the browser stretches the frame), and
// a resize followed.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

extern void ux_test_phase(i32 n); // the page: check the canvases now

class MapView : UXGLView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        }
    }

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
    win.open((u8*)"gl", UXGeom.make(0, 0, 440, 300), content);
    MapView* map = new MapView();
    content.addSubview(map, UXGeom.make((i16)10, (i16)10, (i16)300, (i16)180));
    win.displayAll();
    map.makeGL();
    ux_test_phase((i32)1);
    win.displayAll(); // realized again: still one canvas
    win.displayAll();
    ux_test_phase((i32)2);
    map.setFrame(UXGeom.make((i16)10, (i16)10, (i16)400, (i16)240));
    win.displayAll();
    ux_test_phase((i32)3);
    }
