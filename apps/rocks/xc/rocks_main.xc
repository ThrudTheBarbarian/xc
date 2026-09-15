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
#import "RKRsc.xc"
// Files.xc exists only on the host archs, so opening a document off disk is
// guarded.  Everything else in Rocks builds everywhere; this is the one place
// that cannot, until there is a platform file seam.
#ifdef ARCH_arm64
#import <Files.xc>
#import <String.xc>
#endif

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
        win.open((u8*)"Rocks", UXGeom.make((i16)80, (i16)60, (i16)RK_W, (i16)RK_H), content);

        // A wiring name the controller does not know is a TYPO, and the nib
        // path would hit it too — so it fails here rather than being silently
        // half-built.
        if (!RKMainBuilder.buildInto(content, controller, (i16)RK_W, (i16)RK_H))
            {
            Stdio.printf("FAIL: a wiring name was rejected — builder and controller disagree\n");
            return (i32)1;
            }

        RKMainBuilder.buildMenu(app, controller);

        // Open a resource if one is to hand, so the canvas has something real
        // in it — REAL widgets, built from the model by RKCanvas.
#ifdef ARCH_arm64
        u8* sample = (u8*)"resources/desktop.rsc"; // a GEM desktop's resources, if run from one
        String* sp = String.withCString(sample);
        if (Files.exists(sp))
            {
            Data* fd = Files.readData(sp);
            if (fd != (Data*)0)
                {
                RKResource* res = RKRsc.read(fd.bytes(), (i32)fd.length());
                if (res != (RKResource*)0)
                    {
                    i32 n = controller.showResource(res, (i32)0);
                    Stdio.printf("opened %s: %d trees, %d widgets on the canvas\n",
                                 sample, res.treeCount(), n);
                    controller.say((u8*)"Opened desktop.rsc");
                    }
                }
            }
#endif

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
