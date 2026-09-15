// test_win32_menu.xc — menus on the Win32 backend.
//
// The neutral menu MODEL is app-level (one UXMenuBar); the Win32 driver realizes it as a
// per-window HMENU on every window.  A menu pick fires WM_COMMAND(id); the driver decodes it
// to a neutral UXEventMenuSelect, and UXApplication routes it to the bound method — exactly the
// GEM path (test_menu.xc), which turns an MN_SELECTED into the same call.  Xtg wrote no menu
// drawing, tracking or hit-testing on either backend.
//
//   Build+run:  sh run_win32_menu.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXGeometry.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    i32 fired; // last item fired (1=New 2=Open 3=Quit 4=Cut), 0 none
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    void onNew(UXMenuItem* s)
        {
        fired = (i32)1;
        Stdio.printf("action: New\n");
        }
    void onOpen(UXMenuItem* s)
        {
        fired = (i32)2;
        Stdio.printf("action: Open\n");
        }
    void onQuit(UXMenuItem* s)
        {
        fired = (i32)3;
        Stdio.printf("action: Quit\n");
        }
    void onCut(UXMenuItem* s)
        {
        fired = (i32)4;
        Stdio.printf("action: Cut\n");
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        win.open((u8*)"Menus", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)120), content);
        app.addWindow(win);

        UXMenuBar* bar = new UXMenuBar();
        UXMenu* file = bar.addMenu((u8*)"File");
        file.addItem((u8*)"New", &self.onNew);
        file.addItem((u8*)"Open", &self.onOpen);
        file.addSeparator();
        file.addItem((u8*)"Quit", &self.onQuit);
        UXMenu* edit = bar.addMenu((u8*)"Edit");
        edit.addItem((u8*)"Cut", &self.onCut);
        app.setMenuBar(bar); // menuBuild + menuShow -> a per-window HMENU
        Stdio.printf("menu installed: %s\n", bar.tree != (pointer)0 ? "yes" : "no");

        // The OS delivers two menu picks, then a quit.  ids encode (title,item)+1:
        // File>Open = (0,1) -> 2 ; Edit>Cut = (1,0) -> 257.  They travel the real queue.
        pointer hwnd = drv.windowNative(win.handle);
        PostMessageA(hwnd, (u32)WM_COMMAND, (pointer)2, (pointer)0);   // File > Open
        PostMessageA(hwnd, (u32)WM_COMMAND, (pointer)257, (pointer)0); // Edit > Cut
        PostQuitMessage((i32)0);
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Controller* c = new Controller();
    c.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(c);
    app.run();
    Stdio.printf("last-fired=%d\n", c.fired); // expect 4 (Cut, the last pick)
    if (c.fired == (i32)4)
        {
        Stdio.printf("PASS: WM_COMMAND -> neutral MenuSelect -> bound method\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
