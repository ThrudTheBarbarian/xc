// showcase_fp_gem.xc — the GEM file-chooser portrait: run the toolkit-drawn
// UXFilePanel (GEM has no OS file selector) over a staged directory and stay
// parked in its modal loop while gemd's serve window dumps the framebuffer.
// The panel opens at (140,80) with a 444-wide window — capture.sh crops there.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXOpenPanel.xc"

class FpApp : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    i32 applicationDidStart(UXApplication* a)
        {
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"backdrop", UXGeom.make(80, 80, 440, 300), content);
        win.displayAll();
        Stdio.printf("sheet: window up\n");
        UXOpenPanel.runToolkit((u8*)"Open", (u8*)"/tmp/ux_fp_demo"); // parked while gemd dumps
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
    FpApp* s = new FpApp();
    UXApplication* app = new UXApplication();
    app.setDelegate(s);
    app.run();
    }
