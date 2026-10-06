// demo_appkit_liveresize.xc — AppKit keeps the app alive through a live resize.
//
// A window with native controls (a button anchored to the bottom-right, a label that stretches) and a
// scroll view.  The shim's probe runs a REAL live resize -- an animated one, which AppKit treats as
// live (inLiveResize at every step) -- and then runs the loop in NSEventTrackingRunLoopMode, as a drag
// does between steps.  Checked: the toolkit heard the resize DURING the live resize, the final size
// landed and the anchored button followed it, and the app's turn kept firing in the tracking mode
// (it used to stop for the whole drag).  run_appkit_liveresize.sh also runs it under guard malloc.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"

extern void ux_ak_test_live_resize(i32 handle, i32 w, i32 h, i32 ms);
extern i32 ux_ak_test_live_done(void);
extern i32 ux_ak_in_live_resize(i32 handle);
extern i32 ux_ak_control_frame(i32 handle, i32 node, i32* x, i32* y, i32* w, i32* h);
extern i32 ux_ak_gl_surface_size(pointer peer, i32* out2);
extern i32 ux_ak_gl_backing(pointer peer, i32* out4);

// A GL view that stretches with the window, as the client's map does: its drawable must follow, and
// so must the size the toolkit reports for it, or the app draws the old territory into a bigger frame.
class MapView : UXGLView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)40, (i32)90, (i32)160);
        }
    }
MapView* gMap;

i32 gFails;
void ck(bool ok, u8* what)
    {
    Stdio.printf("  %s %s\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what);
    if (!ok)
        {
        gFails = gFails + (i32)1;
        }
    }

i32 gTicks;
i32 gPhase;      // 0 waiting, 1 probe running, 2 checked
i32 gTickAtStart;
i32 gLiveResizes;
i32 gLastW;
i32 gLastH;
UXApplication* gApp;
UXWindow* gWin;
UXButton* gBtn;

void liveTick(void)
    {
    gTicks = gTicks + (i32)1;
    if (gMap != (MapView*)0 && gMap.ownsGL())
        {
        gMap.presentGL(); // a frame a turn, as the client's renderer does
        }
    if (gPhase == (i32)0 && gTicks == (i32)5)
        {
        gPhase = (i32)1;
        gTickAtStart = gTicks;
        ux_ak_test_live_resize(gWin.handle, (i32)420, (i32)300, (i32)300);
        return;
        }
    if (gPhase == (i32)1 && ux_ak_test_live_done() != (i32)0)
        {
        gPhase = (i32)2;
        i32 during = gTicks - gTickAtStart;
        Stdio.printf("  live-resize steps heard: %d, turns through the drag: %d, last size %dx%d\n",
                     gLiveResizes, during, gLastW, gLastH);
        ck(gLiveResizes >= (i32)2, "the toolkit heard the resize DURING the live resize");
        ck(gLastW == (i32)420 && gLastH == (i32)300, "the final content size reached the app");
        ck(during >= (i32)5, "the app's turn kept firing in the tracking run-loop mode");
        i32 bx = (i32)0;
        i32 by = (i32)0;
        i32 bw = (i32)0;
        i32 bh = (i32)0;
        ux_ak_control_frame(gWin.handle, (i32)gBtn.index, &bx, &by, &bw, &bh);
        // The native frame is AppKit's, measured from the BOTTOM-left: anchored right and bottom, the
        // button keeps its 20 px right margin and its 12 px bottom margin (200 - 160 - 28).
        Stdio.printf("  the button is at %d,%d (from the bottom-left)\n", bx, by);
        ck(bx == (i32)420 - (i32)100 && by == (i32)12, "the anchored button followed the window");
        // The map: anchored on all sides at 200,40 -> 280 x 100 grows by the window's 120 x 100.
        i32 bk[4];
        i32 sz[2];
        ux_ak_gl_backing((pointer)gMap, &bk[(i32)0]);
        i32 got = ux_ak_gl_surface_size((pointer)gMap, &sz[(i32)0]);
        UXRect mf = gMap.frame();
        Stdio.printf("  map: native %dx%d pt (%dx%d px), drawable %dx%d, toolkit frame %dx%d\n",
                     bk[(i32)0], bk[(i32)1], bk[(i32)2], bk[(i32)3], sz[(i32)0], sz[(i32)1], (i32)mf.w, (i32)mf.h);
        ck(bk[(i32)0] == (i32)200 && bk[(i32)1] == (i32)200, "the map's view grew with the window (80x100 -> 200x200)");
        ck(got == (i32)0 || (sz[(i32)0] == bk[(i32)2] && sz[(i32)1] == bk[(i32)3]), "its drawable followed it");
        ck((i32)mf.w == bk[(i32)0] && (i32)mf.h == bk[(i32)1], "and the toolkit's frame says the same, so the app draws more territory, not a stretched map");
        gApp.stop();
        }
    }

class Del : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        gApp = a;
        UXView* content = new UXView();
        gWin = new UXWindow();
        gWin.open((u8*)"Live resize", UXGeom.make((i16)120, (i16)120, (i16)300, (i16)200), content);
        a.addWindow(gWin);
        UXLabel* label = new UXLabel();
        label.setText((u8*)"A label that stretches with the window");
        content.addSubview(label, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)20));
        label.setAutoresizeMask((i32)UX_ANCHOR_LEFT | (i32)UX_FLEX_WIDTH);
        UXScrollView* sv = new UXScrollView();
        content.addSubview(sv, UXGeom.make((i16)10, (i16)40, (i16)180, (i16)100));
        sv.setDocumentHeight((i32)600);
        sv.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        gMap = new MapView();
        content.addSubview(gMap, UXGeom.make((i16)200, (i16)40, (i16)80, (i16)100));
        gMap.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        gBtn = new UXButton();
        gBtn.setTitle((u8*)"OK");
        content.addSubview(gBtn, UXGeom.make((i16)200, (i16)160, (i16)80, (i16)28));
        gBtn.setAutoresizeMask((i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM);
        gWin.displayAll();
        gMap.makeGL();
        a.everyTurn(&liveTick, (i32)0);
        return (i32)0;
        }
    void windowDidResize(UXApplication* app, UXWindow* win, i32 width, i32 height)
        {
        if (ux_ak_in_live_resize(win.handle) != (i32)0)
            {
            gLiveResizes = gLiveResizes + (i32)1;
            }
        gLastW = width;
        gLastH = height;
        }
    }

void main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(new Del());
    app.run();
    Stdio.printf(gPhase == (i32)2 && gFails == (i32)0 ? "PASS: AppKit live resize -- the app hears it, follows it and keeps its turn\n"
                                                      : "FAIL: %d (phase %d)\n", gFails, gPhase);
    }
