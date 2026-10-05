// test_appkit_menu.xc — menu construction, headless, to isolate the menu path.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXGeometry.xc"

i32 gFired;
i32 gUndo;
i32 gRedo;
bool gKeysOk;
i32 ux_ak_test_menu_press(i32 key, i32 cmd, i32 shift);
class Controller : Object<UXApplicationDelegate>
    {
    void onItem(UXMenuItem* s)
        {
        gFired = gFired + (i32)1;
        }
    void onUndo(UXMenuItem* s)
        {
        gUndo = gUndo + (i32)1;
        }
    void onRedo(UXMenuItem* s)
        {
        gRedo = gRedo + (i32)1;
        }
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        win.open((u8*)"Menus", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)120), content);
        app.addWindow(win);
        Stdio.printf("window ok\n");
        UXMenuBar* bar = new UXMenuBar();
        UXMenu* file = bar.addMenu((u8*)"File");
        file.addItem((u8*)"New", &self.onItem);
        file.addSeparator();
        file.addItem((u8*)"Quit", &self.onItem);
        UXMenu* edit = bar.addMenu((u8*)"Edit");
        edit.addItem((u8*)"Undo", &self.onUndo).setShortcut((u8)'Z', false);
        edit.addItem((u8*)"Redo", &self.onRedo).setShortcut((u8)'Z', true);
        Stdio.printf("menu model built\n");
        app.setMenuBar(bar);
        Stdio.printf("menu installed (menuBuild ran)\n");
        // the native key equivalents: AppKit matches them itself
        i32 a = ux_ak_test_menu_press((i32)'Z', (i32)1, (i32)0);
        i32 b = ux_ak_test_menu_press((i32)'Z', (i32)1, (i32)1);
        i32 c = ux_ak_test_menu_press((i32)'Z', (i32)0, (i32)0);
        Stdio.printf("cmd-Z taken=%d; shift-cmd-Z taken=%d; plain Z taken=%d (expect 1 1 0)\n", a, b, c);
        gKeysOk = a == (i32)1 && b == (i32)1 && c == (i32)0;
        ux_ak_post_quit();
        return (i32)0;
        }
    } void main(void)
    {
    gFired = (i32)0;
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    app.setDriver(new UXAppKitDriver());
    app.setHeadless(true);
    app.setDelegate(c);
    app.run();
    // the picks arrive as menu events, handled by the run loop before it quit
    Stdio.printf("undo=%d redo=%d (expect 1 1)\n", gUndo, gRedo);
    gKeysOk = gKeysOk && gUndo == (i32)1 && gRedo == (i32)1;
    if (gKeysOk)
        {
        Stdio.printf("PASS: menu built headless; its shortcuts are native key equivalents\n");
        }
    else
        {
        Stdio.printf("FAIL: menu shortcuts\n");
        }
    }
