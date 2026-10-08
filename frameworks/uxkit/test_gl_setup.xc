// test_gl_setup.xc — a GL view is usable from the moment its context is made (the gl-setup gates):
// at setup, in applicationDidStart, before the run loop has turned once, drawableSize is the view's
// pixels, and frames drawn and presented there (as a headless run draws them) are in its snapshot.
// On GTK that needs the driver to let GTK lay the area out first, which no app should have to ask
// for (under Xvfb there is no window manager to do it).  One source for every backend with GL.
#import <Stdio.xc>
#import "UXPlatform.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXImage.xc"
#import "UXGL.xc"

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
class Setup : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* w = new UXWindow();
        UXView* root = new UXView();
        UXGLView* map = new UXGLView();
        w.open((u8*)"setup", UXGeom.make((i16)0, (i16)0, (i16)640, (i16)400), root);
        root.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)640, (i16)400));
        app.addWindow(w);
        w.displayAll();
        ck((u8*)"makeGL at setup", map.makeGL());
        i32 pw = (i32)0;
        i32 ph = (i32)0;
        bool sized = map.drawableSize(&pw, &ph);
        Stdio.printf("  (%s: drawable at setup %d x %d)\n", UXPlatform.name(), pw, ph);
        ck((u8*)"...and its drawable has the view's size at once", sized && pw >= (i32)640 && ph >= (i32)400 && pw * (i32)400 == ph * (i32)640);
        // frames drawn before the run loop turns, as a headless run draws them
        for (i32 f = (i32)0; f < (i32)5; f = f + (i32)1)
            {
            glClearColor(0.5, 0.2, 0.1, 1.0);
            glClear((u32)$4000);
            map.presentGL();
            }
        UXImage* shot = map.snapshot();
        u32 mid = shot != (UXImage*)0 ? shot.px[(shot.h / (i32)2) * shot.w + shot.w / (i32)2] : (u32)0;
        ck((u8*)"frames presented at setup are in the GL view's snapshot", shot != (UXImage*)0 &&
           ((mid >> (u32)16) & (u32)255) > (u32)115 && ((mid >> (u32)16) & (u32)255) < (u32)140 && (mid & (u32)255) < (u32)40);
        app.stop();
        return (i32)0;
        }
    }
void main(void)
    {
    gFails = (i32)0;
    UXApplication* app = new UXApplication();
    app.setHeadless(true);
    app.setDelegate(new Setup());
    app.run();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: a GL view is usable at setup on %s -- its size, and frames presented before the loop turns\n", UXPlatform.name());
        }
    else
        {
        Stdio.printf("FAIL: %d on %s\n", gFails, UXPlatform.name());
        }
    }
