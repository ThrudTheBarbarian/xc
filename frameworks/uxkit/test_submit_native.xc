// test_submit_native.xc — the AppKit HALF of the submit seam: a field's own end-of-editing.
//
// test_appkit_field drives the NEUTRAL key path: the driver dequeues a posted key event before
// AppKit can route it to the field, so the toolkit's keyDown is what sees that Return.  A real
// user's Return never takes that path.  The NSTextField is first responder, AppKit ends editing
// with a MOVEMENT, and the driver's delegate turns that into fieldDidSubmit -- but only for a
// Return.  A Tab, a click into the next field, and the window closing all end editing too, and a
// panel that submitted for every one of them would fire its command line every time the user
// tabbed away.  That negative is the point of this gate, so it is checked first.
//
// The notification below is the one the text system posts; posting it is how a headless gate
// reaches a delegate path that otherwise needs a click somewhere else.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

void ux_ak_test_end_editing(i32 handle, i32 node, i32 movement);

#define MOVEMENT_RETURN 16 // NSTextMovementReturn
#define MOVEMENT_TAB 17    // NSTextMovementTab

i32 gFails;
i32 gSubmits;

void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

void onSubmitted(UXTextField* f)
    {
    gSubmits = gSubmits + (i32)1;
    }

    void
    main(void)
    {
    gFails = (i32)0;
    gSubmits = (i32)0;
    ux_ak_set_capture((i32)1); // native controls realized, no window shown
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"submit", UXGeom.make((i16)0, (i16)0, (i16)240, (i16)80), content);
    UXTextField* f = new UXTextField();
    f.setText((u8*)"go");
    f.setOnSubmit(&onSubmitted);
    content.addSubview(f, UXGeom.make((i16)10, (i16)10, (i16)140, (i16)22));
    win.tree.finalise();
    win.displayAll(); // realizeTree: the real NSTextField, registered under its node

    i32 h = win.handle;
    i32 n = (i32)f.index;
    check("nothing submitted yet", gSubmits, (i32)0);
    ux_ak_test_end_editing(h, n, (i32)MOVEMENT_TAB);
    check("a Tab away does NOT submit", gSubmits, (i32)0);
    ux_ak_test_end_editing(h, n, (i32)MOVEMENT_RETURN);
    check("a Return submits", gSubmits, (i32)1);
    ux_ak_test_end_editing(h, n, (i32)MOVEMENT_RETURN);
    check("and again", gSubmits, (i32)2);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: Return ends editing into a submit, and nothing else does\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
