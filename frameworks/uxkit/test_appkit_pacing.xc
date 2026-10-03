// test_appkit_pacing.xc — on macOS the app's turn is paced by the display (the appkit-pacing gate).
// A live window and everyTurn(fn, 0): the turn must be driven by the window's display link, its mean
// interval the screen's refresh, and its spread small -- where the NSTimer it replaced put frames
// 10-19 ms apart on a 60 Hz screen.  everyTurn(fn, 100), a slow tick, keeps the timer.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"

i32 ux_ak_turn_paced_by_display(void);
i32 ux_ak_test_screen_hz(void);

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

i32 gN;
i32 gLast;
i64 gSum;
i64 gSumSq;
i32 gMax;
i32 gMin;
void tick(void)
    {
    i32 now = gDriver.nowUs();
    if (gN > (i32)10) // past the start-up turns
        {
        i32 d = now - gLast;
        gSum = gSum + (i64)d;
        gSumSq = gSumSq + (i64)d * (i64)d;
        gMax = d > gMax ? d : gMax;
        gMin = gMin == (i32)0 || d < gMin ? d : gMin;
        }
    gLast = now;
    gN = gN + (i32)1;
    if (gN == (i32)130)
        {
        gApp.everyTurn((turnHook_t*)0, (i32)0);
        gApp.stop();
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        UXWindow* w = new UXWindow();
        w.open((u8*)"pacing", UXGeom.make((i16)80, (i16)80, (i16)320, (i16)200), new UXView());
        a.addWindow(w);
        a.everyTurn(&tick, (i32)100);
        ck((u8*)"a slow tick (100 ms) keeps the timer", ux_ak_turn_paced_by_display() == (i32)0);
        a.everyTurn(&tick, (i32)0);
        ck((u8*)"a turn every frame is paced by the display link", ux_ak_turn_paced_by_display() == (i32)1);
        return (i32)0;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    gApp = app;
    app.setDelegate(new Delegate());
    app.run();
    i32 n = gN - (i32)11;
    i64 mean = n > (i32)0 ? gSum / (i64)n : (i64)0;
    i64 var = n > (i32)0 ? gSumSq / (i64)n - mean * mean : (i64)0;
    i64 sd = (i64)0;
    while ((sd + (i64)1) * (sd + (i64)1) <= var)
        {
        sd = sd + (i64)1;
        }
    i32 hz = ux_ak_test_screen_hz();
    i64 want = (i64)1000000 / (i64)(hz > (i32)0 ? hz : (i32)60);
    Stdio.printf("  (%d turns: mean %ld us, sd %ld us, min %d, max %d; the screen runs at %d Hz, %ld us a frame)\n",
                 n, mean, sd, gMin, gMax, hz, want);
    ck((u8*)"the turn comes once a frame (mean within 10% of the refresh)", mean > want * (i64)9 / (i64)10 && mean < want * (i64)11 / (i64)10);
    ck((u8*)"...steadily (standard deviation under 2 ms)", sd < (i64)2000);
    Stdio.printf(gFails == (i32)0 ? "PASS: AppKit's turn is paced by the display -- once a frame, steadily\n" : "FAIL: %d\n", gFails);
    }
