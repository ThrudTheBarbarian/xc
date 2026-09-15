// test_appkit_shield.xc — the INPUT SHIELD, against a real click on a real
// native button (the `appkit-shield` gate).
//
// This is the mirror of test_appkit_interactive.xc.  That one asserts a click
// on a button FIRES the button, travelling AppKit -> content view -> dispatch
// -> hit-test -> action.  This one puts a UXShieldView over the same button and
// asserts the click is INTERCEPTED instead: the shield hears it, the button
// does not fire, and the coordinates arrive in the content view's space.
//
// Why it needs a real injected NSEvent rather than a direct call: the whole
// question is what APPKIT does with the press.  There is one native view per
// window and every control is a flat child of it, so a toolkit view "on top" is
// on top only in the shadow tree -- AppKit routes the click to the NSButton
// under the pointer and the toolkit never hears about it.  Calling the
// dispatcher by hand would prove nothing at all, because it would skip the only
// step in question.  That is exactly how this shipped broken: clicking a box or
// bare background worked, so selection looked implemented, while clicking a
// button, a field or a popup did nothing.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

i32 gButtonFired;
i32 gShieldGot;
i32 gShieldX;
i32 gShieldY;

class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)200, (i16)120), (i32)8);
        }
    }

    class Shield : UXShieldView
    {
    UXApplication* app;
    void init(void)
        {
        super.init();
        app = (UXApplication*)0;
        }
    void mouseDown(UXEvent* e)
        {
        gShieldGot = gShieldGot + (i32)1;
        gShieldX = (i32)e.x;
        gShieldY = (i32)e.y;
        if (app != (UXApplication*)0)
            {
            app.stop();
            }
        }
    }

    class Ctl : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    void onQuit(UXControl* c)
        {
        gButtonFired = gButtonFired + (i32)1;
        app.stop();
        }
    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"shield", UXGeom.make((i16)60, (i16)60, (i16)200, (i16)120), canvas);
        app.addWindow(win);

        // A REAL native button, realized by the real backend -- the point of a
        // design surface is that the genuine article is on screen.
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Quit");
        b.setAction(&self.onQuit);
        canvas.addSubview(b, UXGeom.make((i16)20, (i16)40, (i16)80, (i16)26));

        // ...with the shield over it.  Added last, and covering the whole area.
        Shield* s = new Shield();
        s.app = a;
        canvas.addSubview(s, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)120));

        win.displayAll();
        ux_ak_post_click(win.handle, (i32)40, (i32)52); // squarely inside the button
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gButtonFired = (i32)0;
    gShieldGot = (i32)0;
    gShieldX = (i32)-1;
    gShieldY = (i32)-1;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Ctl* c = new Ctl();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    app.run();

    i32 fails = (i32)0;
    if (gShieldGot >= (i32)1)
        {
        Stdio.printf("  ok   the shield got the press\n");
        }
    else
        {
        Stdio.printf("  FAIL the shield never saw the press\n");
        fails = fails + (i32)1;
        }
    // THE WHOLE POINT: a click on a design surface selects, it does not operate.
    if (gButtonFired == (i32)0)
        {
        Stdio.printf("  ok   and the button did NOT fire\n");
        }
    else
        {
        Stdio.printf("  FAIL the button fired anyway (%d)\n", (i16)gButtonFired);
        fails = fails + (i32)1;
        }
    // Content-view coordinates, not shield-local ones: the toolkit hit-tests the
    // whole window, so a point in the shield's own space would be short by the
    // shield's origin and would select the wrong object.
    if (gShieldX == (i32)40 && gShieldY == (i32)52)
        {
        Stdio.printf("  ok   in the content view's coordinates = %d,%d\n", (i16)gShieldX, (i16)gShieldY);
        }
    else
        {
        Stdio.printf("  FAIL coordinates %d,%d (want 40,52)\n", (i16)gShieldX, (i16)gShieldY);
        fails = fails + (i32)1;
        }

    if (fails == (i32)0)
        {
        Stdio.printf("PASS: the shield intercepts a real click on a real native button\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)fails);
        }
    }
