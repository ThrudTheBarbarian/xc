// showcase_alert_gem.xc — the GEM alert portrait: pop a real form_alert on the
// headless host gemd and stay blocked in its modal loop while gemd's serve
// window dumps the desktop framebuffer.  form_alert centres itself, so the
// capture leg crops around the desktop centre.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

class AlertApp : Object<UXApplicationDelegate>
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
        UXAlert* alert = new UXAlert();
        alert.icon = (i32)3; // stop — the theme's strongest art
        alert.addLine((u8*)"Save changes to Rocks.doc?");
        alert.addLine((u8*)"Your edits will be lost otherwise.");
        alert.addButton((u8*)"Save");
        alert.addButton((u8*)"Cancel");
        alert.defaultButton = (i32)1;
        alert.runModal(); // parked here while gemd dumps
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
    AlertApp* s = new AlertApp();
    UXApplication* app = new UXApplication();
    app.setDelegate(s);
    app.run();
    }
