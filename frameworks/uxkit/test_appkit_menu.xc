// test_appkit_menu.xc — menu construction, headless, to isolate the menu path.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXGeometry.xc"

i32 gFired;
class Controller : Object<UXApplicationDelegate>
    {
    void onItem(UXMenuItem* s)
        {
        gFired = gFired + (i32)1;
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
        Stdio.printf("menu model built\n");
        app.setMenuBar(bar);
        Stdio.printf("menu installed (menuBuild ran)\n");
        ux_ak_post_quit();
        return (i32)0;
        }
    } void main(void)
    {
    gFired = (i32)0;
    gDriver = new UXAppKitDriver();
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    app.setDelegate(c);
    app.run();
    Stdio.printf("PASS: menu built headless without crashing\n");
    }
