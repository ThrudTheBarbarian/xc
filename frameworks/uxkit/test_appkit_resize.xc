// test_appkit_resize.xc — the neutral resize path, exercised headless under guard malloc.
//
// It cannot reproduce AppKit's own live-resize LAYOUT (that needs a real drag), but it drives the
// toolkit's half — UXEventResize -> windowContentGeometry -> post notification -> displayAll ->
// realizeTree (repositioning a native control) -> ak_fit_document — several times over.  Run under
// guard malloc, a heap overflow anywhere on that path faults here instead of later.
//
//   Build+run:  cc -fobjc-arc -c libUXAppKit.m -o /tmp/l.o &&
//               xtc -A arm64 -I . test_appkit_resize.xc -Xlinker /tmp/l.o -framework Cocoa -o /tmp/t && /tmp/t
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXNotificationCenter.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

i32 gResizes;
class Watch : Object
    {
    void init(void)
        {
        }
    void onResize(UXNotification* n)
        {
        gResizes = gResizes + (i32)1;
        }
    }

    class Del : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXButton* btn;
    Watch* watch;

    i32 applicationDidStart(UXApplication* app)
        {
        gResizes = (i32)0;
        UXView* content = new UXView();
        win = new UXWindow();
        win.open((u8*)"R", UXGeom.make((i16)40, (i16)40, (i16)300, (i16)200), content);
        app.addWindow(win);

        btn = new UXButton();
        btn.setTitle((u8*)"B");
        content.addSubview(btn, UXGeom.make((i16)20, (i16)20, (i16)80, (i16)28));
        win.setContentSize((i16)300, (i16)1200); // tall -> a scrolling window (exercises the fit path)

        watch = new Watch();
        UXNotificationCenter.shared().addObserver((Object*)watch, &watch.onResize,
                                                  UXWindowDidResizeNotification, (Object*)0);
        win.displayAll();

        // Simulate a drag: grow, then shrink twice (the shrink is what crashed interactively).
        ux_ak_post_resize(win.handle, (i32)400, (i32)300);
        ux_ak_post_resize(win.handle, (i32)250, (i32)150);
        ux_ak_post_resize(win.handle, (i32)180, (i32)120);
        ux_ak_post_quit();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gDriver = new UXAppKitDriver();
    Del* del = new Del();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    app.run();
    Stdio.printf("resize notifications heard: %d\n", (i16)gResizes);
    Stdio.printf(gResizes >= (i32)3
                     ? "PASS: the neutral resize path runs clean headless (post / geometry / notify / reflow)\n"
                     : "FAIL: expected >= 3 resize notifications, got %d\n",
                 (i16)gResizes);
    }
