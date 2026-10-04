// test_appkit_turn_fallback.xc — the AppKit turn keeps coming when the display link stops (the
// appkit-turnfallback gate).  A turn of every frame is paced by the window's display link, which
// stops while the display sleeps or the window is covered; the turn is the app's whole clock (its
// network polling, its logic), so the driver's backup timer takes over.  The link is paused here as a
// sleeping display pauses it, and the turns are counted.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
i32 ux_ak_turn_paced_by_display(void);
void ux_ak_test_pause_turn_link(i32 on);

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
i32 gT0;
void tick(void)
    {
    gN = gN + (i32)1;
    if (gN == (i32)40)
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
        w.open((u8*)"fallback", UXGeom.make((i16)80, (i16)80, (i16)320, (i16)200), new UXView());
        a.addWindow(w);
        a.everyTurn(&tick, (i32)16);
        ck((u8*)"a turn of every frame is paced by the display link", ux_ak_turn_paced_by_display() == (i32)1);
        ux_ak_test_pause_turn_link((i32)1); // as a sleeping display stops it
        gT0 = gDriver.nowMs();
        return (i32)0;
        }
    }
void main(void)
    {
    gFails = (i32)0;
    gN = (i32)0;
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)new UXAppKitDriver());
    app.setDelegate(new Delegate());
    app.run();
    i32 took = gDriver.nowMs() - gT0;
    Stdio.printf("  (%d turns with the link paused, in %d ms)\n", gN, took);
    ck((u8*)"with the display link stopped, the turn keeps coming", gN >= (i32)40);
    ck((u8*)"...at about its own rate (40 turns of 16 ms in under 3 s)", took < (i32)3000);
    Stdio.printf(gFails == (i32)0 ? "PASS: the AppKit turn carries on when the display link stops\n" : "FAIL: %d\n", gFails);
    }
