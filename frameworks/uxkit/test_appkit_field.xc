// test_appkit_field.xc — live text editing native on AppKit (sibling of test_win32_field.xc).
//
// A form with a text field, driven entirely through the neutral run loop.  A posted click focuses
// the field (dispatchMouse -> makeFirstResponder); posted key-downs travel driver.nextEvent ->
// UXEventKeyDown -> dispatchKey -> UXTextField.keyDown -> driver.editText, which inserts/Backspaces
// into the app's buffer.  GEM hands this to objc_edit; AppKit (like Win32) has no edit engine for a
// custom-drawn field, so the driver IS the edit engine (the code reused from UXWin32Driver).
//
// The last posted key is Return.  A field that asked to hear about it (setOnSubmit) reports the
// LINE as done and keeps the key out of its buffer -- the point of the hook: a panel asks "what did
// they type" without having to recognise a CR, and the buffer still reads "Ho", with no CR in it.
//
//   Build+run:  sh run_appkit_field.sh   (xtc -A arm64 + the ObjC shim, native; no window shown)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

i32 gSubmitted;

class Delegate : Object<UXApplicationDelegate>
    {
    UXTextField* field;

    void onSubmitted(UXTextField* f)
        {
        gSubmitted = gSubmitted + (i32)1;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        field = new UXTextField();
        field.setOnSubmit(&self.onSubmitted); // hear "the line is done", not a CR character

        win.open((u8*)"Form", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)90), content);
        content.addSubview(field, UXGeom.make((i16)10, (i16)30, (i16)140, (i16)20));
        app.addWindow(win);

        // The OS delivers: a click on the field (focus it), then keystrokes, then quit.  All travel
        // the real NSApplication queue; the neutral loop pumps them.  "Hi", Backspace, "o" -> "Ho".
        ux_ak_post_click(win.handle, (i32)18, (i32)38); // (18,38) is inside the field
        ux_ak_post_key((i32)72);                        // 'H'
        ux_ak_post_key((i32)105);                       // 'i'
        ux_ak_post_key((i32)8);                         // Backspace
        ux_ak_post_key((i32)111);                       // 'o'
        ux_ak_post_key((i32)13);                        // Return -> onSubmit, NOT a character
        ux_ak_post_quit();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gDriver = new UXAppKitDriver();
    Delegate* del = new Delegate();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    app.run();
    u8* txt = del.field.text();
    Stdio.printf("field=%s (expect Ho)\n", txt);
    Stdio.printf("submitted=%d (expect 1)\n", (i32)gSubmitted);
    // The text is Ho, and the Return left no CR behind: the hook consumed the key.
    bool ok = txt[0] == (u8)72 && txt[1] == (u8)111 && txt[2] == (u8)0 && gSubmitted == (i32)1;
    Stdio.printf(ok ? "PASS: live text editing runs native on AppKit\n" : "FAIL\n");
    }
