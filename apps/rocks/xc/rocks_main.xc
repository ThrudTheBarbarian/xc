// rocks_main.xc — Rocks, the UXKit interface builder: entry point.
//
// Rocks is written in XC on UXKit so that it is simultaneously the editor FOR
// the toolkit and its most demanding CLIENT.  The payoff is that the canvas
// hosts real UXKit widgets rather than a second, drifting rendering of them —
// what the designer sees is the object that will run — and that Rocks is
// cross-platform for free: the same sources build on every backend UXKit has.
//
// This file is deliberately thin.  It boots a driver, opens a window, and
// hands the content view to a BUILDER (RKMainBuilder) and a CONTROLLER
// (RKMainController).  Replacing the builder with a nib-loading one is the
// bootstrap plan; nothing here changes when that happens.
#import <Stdio.xc>
#import "RKDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"
#import "UXRscRead.xc"
#import "UXFileIO.xc"

#define RK_W 1000
#define RK_H 640

class RocksApp : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    RKMainController* controller;

    i32 applicationDidStart(UXApplication* app)
        {
        controller = new RKMainController();

        UXView* content = new UXView();
        win = new UXWindow();
        app.addWindow(win);
        // a desktop window opens at Rocks' own size; on a tablet the window is the screen
        i16 wx = (i16)80;
        i16 wy = (i16)60;
        i16 ww = (i16)RK_W;
        i16 wh = (i16)RK_H;
        if (RKDriver.fillsScreen() && app.screenWidth() > (i32)0)
            {
            wx = (i16)0;
            wy = (i16)0;
            ww = (i16)app.screenWidth();
            wh = (i16)app.screenH;
            }
        win.open((u8*)"Rocks", UXGeom.make(wx, wy, ww, wh), content);

        // A wiring name the controller does not know is a TYPO, and the nib
        // path would hit it too — so it fails here rather than being silently
        // half-built.
        if (!RKMainBuilder.buildInto(content, controller, ww, wh))
            {
            Stdio.printf("FAIL: a wiring name was rejected — builder and controller disagree\n");
            return (i32)1;
            }

        RKMainBuilder.buildMenu(app, controller);
        app.setFileDropHandler(&controller.onFileDrop); // a library or a source adds its classes

        // Open a resource if one is to hand, so the canvas has something real
        // in it — REAL widgets, built from the model by RKCanvas.  UXFileIO
        // reads on every native target, so this is no longer host-only.
        u8* sample = (u8*)"resources/desktop.rsc"; // a GEM desktop's resources, if run from one
        if (UXFileIO.read(sample) != (UXData*)0 && controller.openPath(sample))
            {
            Stdio.printf("opened %s: %d trees\n", sample, controller.doc.treeCount());
            }

        win.tree.finalise();
        win.displayAll();
        Stdio.printf("PASS: Rocks main window built and wired\n");
        return (i32)0;
        }
    }

    // Nothing here names a platform: RKDriver is the one file that does, so this
    // entry point is identical on macOS, Linux, Windows and GEM.
    void main(void)
    {
    RocksApp* delegate = new RocksApp();
    UXApplication* app = new UXApplication();
    if (!RKDriver.start(app))
        {
        Stdio.printf("SKIP: no display for the %s driver\n", RKDriver.platformName());
        return;
        }
    app.setDelegate(delegate);
    app.run();
    Stdio.printf("rocks exited\n");
    }
