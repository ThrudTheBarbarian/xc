// demo_split.xc — an UXSplitView: two panes with a draggable divider.  A left "sidebar" and a right
// "detail", each a coloured pane with a label.  Writes a drag script that grabs the divider and moves
// it, proving the resize headlessly on GEM.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXSplitView.xc"
#import "UXString.xc"

pointer fopen(u8* path, u8* mode);
i32 fputs(u8* s, pointer f);
i32 fclose(pointer f);

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

        // Each pane's content must FILL its pane exactly (start at the pane's size; FLEX keeps it filled
        // as the divider moves).  A short content view would leave an uncovered strip — harmless on a
        // backend that erases the damage rect, but bare desktop shows through it on GEM.
        Pane* left = new Pane();
        left.tint = (i32)8;
        left.name = (u8*)"Sidebar";
        split.firstPane().addSubview(left, UXGeom.make((i16)0, (i16)0, (i16)110, (i16)220)); // = dividerPos
        left.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        Pane* right = new Pane();
        right.tint = (i32)0;
        right.name = (u8*)"Detail";
        split.secondPane().addSubview(right, UXGeom.make((i16)0, (i16)0, (i16)230, (i16)220)); // = 340 - dividerPos
        right.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);

        win.tree.finalise();
        win.displayAll();

        // Drag the divider (window-local x ~ 113, at the divider's centre) to the right by ~90px.
        pointer sf = fopen((u8*)"/tmp/hostgem_script.txt", (u8*)"w");
        if (sf != (pointer)0)
            {
            fputs(UXStr.append(UXStr.append((u8*)"DRAG ", UXStr.fromInt(win.handle)),
                               (u8*)" 113 110 203 110\n"),
                  sf);
            fputs((u8*)"DELAY 400\n", sf);
            fclose(sf);
            }
        Stdio.printf("demo_split up\n");
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    SpKit* kit = new SpKit();
    UXApplication* app = new UXApplication();
    app.setDelegate(kit);
    app.run();
    Stdio.printf("demo_split exited\n");
    }
