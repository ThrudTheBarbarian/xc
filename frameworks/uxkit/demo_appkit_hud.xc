// demo_appkit_hud.xc — the frame-time HUD, sampling the REAL run loop.
//
// A window with the HUD in a corner; the app's own turn hook ticks it (the HUD installs no second
// clock -- there is one frame source, the driver's).  After 240 turns the harness prints what the
// HUD would draw, so the readout is checked and not just seen.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXFrameHud.xc"
#import "demo_autoquit.xc"

u8* getenv(u8* name);
UXFrameHud@ gHud;
UXApplication@ gApp;
i32 gTicks;
i32 gDone;

void hudTick(void)
    {
    if (gDone != (i32)0)
        {
        return;
        }
    gTicks = gTicks + (i32)1;
    if (gHud != (UXFrameHud*)0)
        {
        gHud.tick();
        }
    if (gTicks >= (i32)75)
        {
        gDone = (i32)1;
        Stdio.printf("frames=%ld prev=%ldus min=%ldus max=%ldus fps=%ld\n",
                     gTicks, gHud.framePrev(), gHud.frameMin(), gHud.frameMax(), gHud.frameFps());
        if (gApp != (UXApplication*)0)
            {
            gApp.stop();
            }
        }
    }

class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        gApp = a;
        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"UXKit frame HUD", UXGeom.make((i16)160, (i16)160, (i16)280, (i16)160), canvas);
        gHud = new UXFrameHud();
        gHud.setEnabled(true);
        canvas.addSubview(gHud, UXGeom.make((i16)8, (i16)8, (i16)150, (i16)34));
        win.displayAll();
        app.everyTurn(&hudTick, 0); // the app's turn drives the HUD; no second clock
        return (i32)0;
        }
    }

void main(void)
    {
    gTicks = (i32)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    uxAutoQuit();
    app.run();
    if (gTicks >= (i32)75 && gHud != (UXFrameHud*)0 && gHud.framePrev() > (i32)0 && gHud.frameFps() > (i32)0)
        {
        Stdio.printf("PASS: the frame HUD sampled the live frame clock\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
