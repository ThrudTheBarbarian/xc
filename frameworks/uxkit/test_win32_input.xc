// test_win32_input.xc — Win32 input as the toolkit hears it: the middle button, the keys with no
// character, a key's release, and the wheel both ways.  Each is posted to the window as the system
// posts it, and travels driver.nextEvent (decode) -> UXApplication.dispatchEvent -> the view.
//
//   Build+run:  sh run_win32_input.sh   (xcc -A win64, run under Wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

class Pad : UXView
    {
    i32 middle;
    i32 middleButtons;
    i32 downKey;
    i32 upKey;
    i32 ups;
    i32 wheelDY;
    i32 wheelDX;
    i32 wheels;
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        }
    void otherMouseDown(UXEvent* e)
        {
        middle = middle + (i32)1;
        middleButtons = (i32)e.buttons;
        }
    void keyDown(UXEvent* e)
        {
        downKey = (i32)e.key;
        }
    void keyUp(UXEvent* e)
        {
        ups = ups + (i32)1;
        upKey = (i32)e.key;
        }
    void scrollWheel(UXEvent* e)
        {
        wheels = wheels + (i32)1;
        wheelDY = wheelDY + e.b;
        wheelDX = wheelDX + e.dx;
        }
    }

Pad* gPad;
class Delegate : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        gPad = new Pad();
        win.open((u8*)"Input", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), gPad);
        app.addWindow(win);
        pointer hwnd = drv.windowNative(win.handle);
        u32 at = ((u32)40 << (u32)16) | (u32)30; // client (30, 40)
        // the wheel's point is in screen coords
        POINT sp;
        sp.x = (i32)30;
        sp.y = (i32)40;
        ClientToScreen(hwnd, (pointer)&sp);
        u32 sat = (((u32)sp.y & (u32)$FFFF) << (u32)16) | ((u32)sp.x & (u32)$FFFF);
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)1, (pointer)at); // the keyboard to the pad
        PostMessageA(hwnd, (u32)$0202, (pointer)0, (pointer)at);           // WM_LBUTTONUP
        PostMessageA(hwnd, (u32)$0207, (pointer)$10, (pointer)at);         // WM_MBUTTONDOWN
        PostMessageA(hwnd, (u32)$0208, (pointer)0, (pointer)at);           // WM_MBUTTONUP
        PostMessageA(hwnd, (u32)WM_KEYDOWN, (pointer)$25, (pointer)0);     // VK_LEFT
        PostMessageA(hwnd, (u32)$0101, (pointer)$25, (pointer)0);          // WM_KEYUP
        PostMessageA(hwnd, (u32)$020A, (pointer)((u32)(i32)-120 << (u32)16), (pointer)sat); // a notch down
        PostMessageA(hwnd, (u32)$020E, (pointer)((u32)120 << (u32)16), (pointer)sat);       // a notch right
        PostQuitMessage((i32)0);
        return (i32)0;
        }
    }
void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Delegate* del = new Delegate();
    del.drv = d;
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    app.run();
    check("the middle button reached otherMouseDown", gPad.middle, (i32)1);
    check("  as the middle button", gPad.middleButtons, (i32)UX_BUTTON_MIDDLE);
    check("the left arrow as the toolkit's code", gPad.downKey, (i32)UX_KEY_LEFT);
    check("its release is a key up", gPad.ups, (i32)1);
    check("  with the same code", gPad.upKey, (i32)UX_KEY_LEFT);
    check("two wheel events", gPad.wheels, (i32)2);
    check("  a notch down is 100 px down", gPad.wheelDY, (i32)100);
    check("  a notch right is 100 px right", gPad.wheelDX, (i32)100);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: Win32 input -- the middle button, keys, key releases, the wheel both ways\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
