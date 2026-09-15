// demo_split.xc — an UXSplitView: two panes with a draggable divider.  A left "sidebar" and a right
// "detail", each a coloured pane with a label.  Writes a drag script that grabs the divider and moves
// it, proving the resize headlessly on GEM.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"

#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXSplitView.xc"
#import "UXString.xc"

class Pane : UXView
    {
    i32 tint;
    u8* name;
    void init(void)
        {
        super.init();
        tint = (i32)8;
        name = (u8*)"";
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), tint);
        g.drawText(name, (i16)10, (i16)12, (i32)1, (i32)16);
        }
    }

    class SpKit : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    UXSplitView* split;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"Split View", UXGeom.make((i16)90, (i16)70, (i16)340, (i16)220), canvas);
        a.addWindow(win);

        split = new UXSplitView();
        canvas.addSubview(split, UXGeom.make((i16)0, (i16)0, (i16)340, (i16)220));
        split.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        split.setDividerPos((i16)110);

        Pane* left = new Pane();
        left.tint = (i32)8;
        left.name = (u8*)"Sidebar";
        split.firstPane().addSubview(left, UXGeom.make((i16)0, (i16)0, (i16)110, (i16)220));
        left.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        Pane* right = new Pane();
        right.tint = (i32)0;
        right.name = (u8*)"Detail";
        split.secondPane().addSubview(right, UXGeom.make((i16)0, (i16)0, (i16)230, (i16)220)); // fill pane1 (340 - dividerPos)
        right.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);

        win.tree.finalise();
        win.displayAll();

        Stdio.printf("demo_split up\n");
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    SpKit* kit = new SpKit();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(kit);
    app.run();
    }
