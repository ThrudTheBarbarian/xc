// test_web_alert.xc — §3's SECOND blocking primitive, live: alertRun across
// the ring (`web-alert`).  The neutral UXAlert builds the request; the driver
// posts it and BLOCKS in the worker; the harness (playing the page's role)
// receives the strings, answers button 2, and pushes the type-7 reply into
// the ring.  The assertion wants the round trip, not the fallback: the
// answer must be 2 — the plain rig's synchronous default would say 1.
//
//   Build+run:  sh run_web_alert.sh
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXAlert.xc"
#import "UXGeometry.xc"

i32 gAnswer;

class Controller : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        UXView* content = new UXView();
        UXWindow* win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"web alert", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200), content);
        win.tree.finalise();
        win.displayAll();

        UXAlert* alert = new UXAlert();
        alert.icon = (i32)2;
        alert.addLine((u8*)"Close without saving?");
        alert.addButton((u8*)"Save");
        alert.addButton((u8*)"Discard");
        alert.addButton((u8*)"Cancel");
        Stdio.printf("alert: posting, worker blocks\n");
        gAnswer = alert.runModal(); // MODAL: blocks on the ring
        Stdio.printf("alert: answered %d\n", gAnswer);
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gAnswer = (i32)0;
    UXApplication* app = new UXApplication();
    app.setDriver(new UXWebDriver());
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    Stdio.printf(gAnswer == (i32)2
                     ? "PASS: alertRun blocked on the ring and the page's answer came back\n"
                     : "FAIL: 1\n");
    }
