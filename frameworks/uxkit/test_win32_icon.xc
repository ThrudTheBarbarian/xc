// test_win32_icon.xc — the application icon on Win32 (icon_body.xc): the icon a window shows in the
// taskbar and title bar, fetched back with WM_GETICON and drawn into a memory DC to read its pixels.
// A window opened AFTER the icon is set must get it too.  Build+run: sh run_win32_icon.sh (Wine).
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXImage.xc"
#import "UXString.xc"

typedef i32 W32DrawIconExFn(pointer hdc, i32 x, i32 y, pointer icon, i32 w, i32 h, u32 step, pointer brush, u32 flags);
i32 gIconWin;
// Draw the window's big icon at 64 x 64 over white and read (x,y).  -1 = the window has no icon.
i32 iconPixelOf(i32 handle, i32 x, i32 y)
    {
    pointer icon = SendMessageA(gW32Hwnds[handle], (u32)$007F, (pointer)1, (pointer)0); // WM_GETICON, ICON_BIG
    if (icon == (pointer)0)
        {
        return (i32)-1;
        }
    pointer usr = LoadLibraryA((pointer)"user32.dll");
    W32DrawIconExFn* draw = (W32DrawIconExFn*)GetProcAddress(usr, (u8*)"DrawIconEx");
    pointer screen = GetDC((pointer)0);
    pointer mdc = CreateCompatibleDC(screen);
    pointer bmp = CreateCompatibleBitmap(screen, (i32)64, (i32)64);
    pointer old = SelectObject(mdc, bmp);
    RECT r;
    r.left = (i32)0;
    r.top = (i32)0;
    r.right = (i32)64;
    r.bottom = (i32)64;
    FillRect(mdc, (pointer)&r, GetStockObject((i32)0)); // WHITE_BRUSH
    draw(mdc, (i32)0, (i32)0, icon, (i32)64, (i32)64, (u32)0, (pointer)0, (u32)3); // DI_NORMAL
    u32 c = GetPixel(mdc, x, y); // 0x00BBGGRR
    SelectObject(mdc, old);
    DeleteObject(bmp);
    DeleteDC(mdc);
    ReleaseDC((pointer)0, screen);
    return (i32)(((c & (u32)255) << (u32)16) | (c & (u32)$FF00) | ((c >> (u32)16) & (u32)255));
    }
i32 iconPixel(i32 x, i32 y) { return iconPixelOf(gIconWin, x, y); }
i32 iconW() { return iconPixel((i32)0, (i32)0) >= (i32)0 ? (i32)64 : (i32)0; } // drawn at 64: present = 64
i32 iconH() { return iconW(); }
#define ICON_BACKEND "Win32"
#import "icon_body.xc"

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        win.open((u8*)"Icon", UXGeom.make((i16)40, (i16)40, (i16)200, (i16)120), new UXView());
        app.addWindow(win);
        win.displayAll();
        gIconWin = win.handle;
        i32 fails = iconBody(app);
        // A window opened after the icon was set gets it as well.
        UXWindow* late = new UXWindow();
        late.open((u8*)"Later", UXGeom.make((i16)260, (i16)40, (i16)200, (i16)120), new UXView());
        app.addWindow(late);
        late.displayAll();
        i32 lp = iconPixelOf(late.handle, (i32)10, (i32)10);
        bool lateOk = near3(lp, (i32)30, (i32)200, (i32)60); // the RGBA icon: green top-left
        Stdio.printf("  %s a window opened later has the icon too (%06x)\n", lateOk ? (u8*)"ok  " : (u8*)"FAIL", lp);
        Stdio.printf(fails == (i32)0 && lateOk ? "PASS: Win32 app icon, on every window\n" : "FAIL: the late window\n");
        app.stop();
        return (i32)0;
        }
    }

void main(void)
    {
    gDriver = new UXWin32Driver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Delegate());
    app.run();
    }
