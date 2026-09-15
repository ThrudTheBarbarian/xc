// test_appkit_scrolldrive.xc — scrolling a native NSScrollView from code.
//
// The AppKit half of the same gap test_win32_scrolldrive covers: scrollsNatively() is true here, so
// UXScrollView used to return early from scrollTo and the toolkit could not scroll a view at all —
// reveal-a-row, restore-a-position and replay-a-recorded-scroll were silent no-ops.  The seam is
// nativeScrollTo/nativeScrollPx over the NSScrollView's clip view.
//
// Interactive ([NSApp run]) because a native NSScrollView only exists in interactive mode — headless
// draws straight into the view with no scroller to drive.  Assertions read the CLIP VIEW back, so a
// call that returned without moving anything cannot pass.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

void fflush(pointer f);

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    fflush((pointer)0);
    }
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    fflush((pointer)0);
    }

class Ctl : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        a.addWindow(win);
        win.open((u8*)"ScrollDrive", UXGeom.make((i16)40, (i16)40, (i16)320, (i16)240), content);
        UXScrollView* sv = new UXScrollView();
        content.addSubview(sv, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)180));
        sv.setLineHeight((i16)20);
        sv.setDocumentHeight((i32)1200); // far taller than the viewport
        win.displayAll();                // realize: a real NSScrollView

        checkTrue("this backend scrolls natively", gDriver.scrollsNatively());
        check("starts at the top", sv.scrollPx(), (i32)0);

        sv.scrollTo((i16)120);
        check("scrollTo moved the clip view", sv.scrollPx(), (i32)120);

        // Clamping is the scroll view's: it must not be possible to scroll past the document.
        sv.scrollTo((i16)30000);
        i32 atEnd = sv.scrollPx();
        checkTrue("a huge scroll clamps to the end", atEnd > (i32)0 && atEnd < (i32)1200);
        sv.scrollTo((i16)0);
        check("back to the top", sv.scrollPx(), (i32)0);

        sv.scrollByLines((i32)3);
        check("scrollByLines moved it", sv.scrollPx(), (i32)60);

        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    Ctl* c = new Ctl();
    app.setDelegate(c);
    app.run();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the toolkit drives the native NSScrollView\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
