// demo_appkit.xc — the INTERACTIVE AppKit demo: the neutral UXKit toolkit as a real macOS app.
//
// Unlike the headless slice tests, this shows a real window and runs the real NSApplication event
// loop: click the buttons, type in the field, use the menu bar, pop an NSAlert, close the window.
// Nothing here is AppKit-aware except `gDriver = new UXAppKitDriver()` + `setInteractive(true)`.
//
//   Build+run:  make appkit-demo   (or: sh run_appkit_demo.sh) — macOS, shows a window.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// A custom view: paints a backdrop, an accent bar, and a title — through UXGraphics, not AppKit.
class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)340, (i16)240), (i32)8); // grey backdrop
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)340, (i16)6), (i32)2);   // red accent bar
        // the title text is now native UXLabels (added in applicationDidStart), not drawn here
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        Stdio.printf("canvas click %d,%d\n", (i32)e.x, (i32)e.y);
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXTextField* field;

    void popAlert(void)
        {
        UXAlert* a = new UXAlert();
        a.icon = (i32)1;
        a.addLine((u8*)"Hello from UXKit");
        a.addLine((u8*)"This NSAlert was popped by the neutral toolkit.");
        a.addButton((u8*)"Nice");
        a.addButton((u8*)"Meh");
        Stdio.printf("alert button=%d\n", a.runModal());
        }
    void onAlert(UXControl* c)
        {
        self.popAlert();
        }
    void onQuit(UXControl* c)
        {
        Stdio.printf("quit\n");
        app.stop();
        }

    void mAbout(UXMenuItem* s)
        {
        self.popAlert();
        }
    void mQuit(UXMenuItem* s)
        {
        app.stop();
        }
    void mClear(UXMenuItem* s)
        {
        field.setText((u8*)"");
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"UXKit AppKit Demo", UXGeom.make((i16)140, (i16)140, (i16)340, (i16)240), canvas);
        app.addWindow(win);

        UXLabel* title = new UXLabel();
        title.setText((u8*)"UXKit — running native on AppKit");
        canvas.addSubview(title, UXGeom.make((i16)20, (i16)20, (i16)300, (i16)18));
        UXLabel* hint = new UXLabel();
        hint.setText((u8*)"click a button, type below, or use the menu");
        canvas.addSubview(hint, UXGeom.make((i16)20, (i16)46, (i16)300, (i16)16));

        UXButton* alertBtn = new UXButton();
        alertBtn.setTitle((u8*)"Alert");
        alertBtn.setAction(&self.onAlert);
        canvas.addSubview(alertBtn, UXGeom.make((i16)20, (i16)180, (i16)90, (i16)28));
        UXButton* quitBtn = new UXButton();
        quitBtn.setTitle((u8*)"Quit");
        quitBtn.setAction(&self.onQuit);
        canvas.addSubview(quitBtn, UXGeom.make((i16)120, (i16)180, (i16)90, (i16)28));
        field = new UXTextField();
        canvas.addSubview(field, UXGeom.make((i16)20, (i16)120, (i16)300, (i16)24));

        UXMenuBar* bar = new UXMenuBar();
        UXMenu* demo = bar.addMenu((u8*)"Demo");
        demo.addItem((u8*)"About", &self.mAbout);
        demo.addSeparator();
        demo.addItem((u8*)"Quit", &self.mQuit);
        UXMenu* edit = bar.addMenu((u8*)"Edit");
        edit.addItem((u8*)"Clear Field", &self.mClear);
        app.setMenuBar(bar);

        win.displayAll();
        Stdio.printf("demo up — Alert/Quit buttons, a text field, a Demo+Edit menu; close the window to exit\n");
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true); // GUI mode: [NSApp run] owns the loop
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    d.attachApp(app); // forward native events into this app
    app.setDelegate(c);
    app.run();
    Stdio.printf("demo exited\n");
    }
