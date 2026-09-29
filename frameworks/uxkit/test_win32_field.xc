// test_win32_field.xc — live text editing on Win32.
//
// A form with a text field, driven entirely through the neutral run loop.  A posted click
// focuses the field (dispatchMouse -> makeFirstResponder -> the field becomes first responder);
// posted WM_CHARs travel driver.nextEvent -> UXEventKeyDown -> dispatchKey -> UXTextField.keyDown
// -> driver.editText, which inserts/Backspaces into the app's buffer.  GEM hands this to
// objc_edit; Win32 has no edit engine for a custom view, so the driver is the edit engine.
//
// Return is delivered BOTH ways a real one can arrive, because on Win32 it is a native EDIT child
// that gets the message and a single-line EDIT throws it away: a WM_CHAR(13) comes in on the
// window's own queue (the neutral path), and a WM_KEYDOWN/VK_RETURN is aimed straight at the EDIT
// (the driver's own branch, which is the only thing that can catch a genuine keystroke).  Both
// must reach onSubmit, and neither may leave a CR in the buffer.
//
//   Build+run:  sh run_win32_field.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

i32 gSubmitted;

class Delegate : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    UXTextField* field;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    void onSubmitted(UXTextField* f)
        {
        gSubmitted = gSubmitted + (i32)1;
        }

    void postChar(pointer hwnd, i32 ch)
        {
        PostMessageA(hwnd, (u32)WM_CHAR, (pointer)ch, (pointer)0);
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView(); // a plain root box
        field = new UXTextField();
        field.setOnSubmit(&self.onSubmitted); // hear "the line is done"

        win.open((u8*)"Form", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)90), content);
        content.addSubview(field, UXGeom.make((i16)10, (i16)30, (i16)140, (i16)20));
        app.addWindow(win);
        app.displayIfNeeded(); // realizeTree creates the native EDIT now, so the test can aim at it

        // The OS delivers: a click on the field (focus it), then keystrokes, then quit.  All
        // travel the real queue; the neutral loop pumps them.  "Hi", Backspace, "o" -> "Ho".
        pointer hwnd = drv.windowNative(win.handle);
        u32 lp = ((u32)38 << (u32)16) | (u32)18; // (x=18,y=38) is inside the field
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp);
        self.postChar(hwnd, (i32)72);  // 'H'
        self.postChar(hwnd, (i32)105); // 'i'
        self.postChar(hwnd, (i32)8);   // Backspace
        self.postChar(hwnd, (i32)111); // 'o'
        // Return, path 1: a WM_CHAR the window's own queue carries (the same synthetic path the
        // characters above take) -- the neutral keyDown sees it and consumes it.
        self.postChar(hwnd, (i32)13);
        // Return, path 2: a genuine keystroke, which the OS hands to the native EDIT child, not
        // the window.  Aimed straight at it, this is the driver branch that a real Return needs.
        // FindWindowExA matches a class name case-insensitively; GetClassNameA does not, and the
        // class is really spelled "Edit" -- which is why the driver's own check folds the case.
        pointer edit = FindWindowExA(hwnd, (pointer)0, (pointer)"EDIT", (pointer)0);
        if (edit != (pointer)0)
            {
            PostMessageA(edit, (u32)WM_KEYDOWN, (pointer)VK_RETURN, (pointer)0);
            }
        PostQuitMessage((i32)0);
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Delegate* del = new Delegate();
    del.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    app.run();
    Stdio.printf("field=%s\n", del.field.text()); // expect "Ho" -- a CR must not be in it
    Stdio.printf("submitted=%d (expect 2)\n", (i32)gSubmitted);
    Stdio.printf("done\n");
    }
