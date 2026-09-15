// showcase_gem.xc — the GEM contact sheet: one window, every widget (native
// AES objects and the Aristo theme art), composited by a headless host gemd
// whose serve mode dumps the whole desktop framebuffer; capture.sh crops the
// sheet's content area out of the desktop.  The client just opens the sheet
// and runs — gemd owns the clock and the dump.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "showcase_widgets.xc"

class SheetApp : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    i32 applicationDidStart(UXApplication* a)
        {
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"sheet", UXGeom.make(80, 80, 440, 300), content);
        buildSheet(content);
        win.tree.finalise();
        win.displayAll();
        Stdio.printf("sheet: window up\n");
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    SheetApp* s = new SheetApp();
    UXApplication* app = new UXApplication();
    app.setDelegate(s);
    app.run(); // serviced until gemd's serve window ends
    }
