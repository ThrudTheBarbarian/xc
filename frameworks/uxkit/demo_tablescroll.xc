// demo_tablescroll.xc — exercises the IN-TABLE scrollbar (UXTableView's own bar, not the AES window
// bar): a table shorter than its content, so UXTableView draws a scrollbar on its right edge, clips the
// rows, and scrolls them.  It writes an injection script post-window-open (so wind_work_origin is live
// and local->screen is correct) that clicks low on the bar to jump-scroll — proving Stage A headlessly.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXTableView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXString.xc"

pointer fopen(u8* path, u8* mode);
i32 fputs(u8* s, pointer f);
i32 fclose(pointer f);

#define TS_ROWS 20

u8* tsName[TS_ROWS];
u8* i2s(i32 n)
    {
    return UXStr.fromInt(n);
    }
u8* cat(u8* a, u8* b)
    {
    return UXStr.append(a, b);
    }

class TsCanvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8);
        }
    }

    class TsKit : Object<UXApplicationDelegate, UXTableDataSource>
    {
    UXApplication* app;
    UXWindow* win;
    UXTableView* table;

    i32 numberOfRows(UXTableView* t)
        {
        return (i32)TS_ROWS;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row < (i32)0 || row >= (i32)TS_ROWS)
            {
            return (u8*)"";
            }
        if (col == (i32)0)
            {
            return tsName[row];
            }
        if (col == (i32)1)
            {
            return (r_even(row) ? (u8*)"dir" : (u8*)"file");
            }
        return (u8*)"item";
        }
    bool r_even(i32 r)
        {
        return (r & (i32)1) == (i32)0;
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        for (i32 r = (i32)0; r < (i32)TS_ROWS; r++)
            {
            tsName[r] = cat((u8*)"row_", i2s(r));
            }

        TsCanvas* canvas = new TsCanvas();
        win = new UXWindow();
        win.open((u8*)"In-table scroll", UXGeom.make((i16)90, (i16)70, (i16)320, (i16)230), canvas);
        a.addWindow(win);

        // A table whose FRAME (160px) is far shorter than its 20 rows*22 = 440px of content -> the
        // UXTableView draws its own scrollbar and clips the rows.  No setContentSize: the WINDOW does
        // not scroll; the TABLE does.
        table = new UXTableView();
        canvas.addSubview(table, UXGeom.make((i16)10, (i16)10, (i16)300, (i16)170));
        table.setRowHeight((i16)22);
        table.addColumn((u8*)"Name", (i16)170);
        table.addColumn((u8*)"Type", (i16)60);
        table.addColumn((u8*)"Tag", (i16)56);
        table.setDataSource(self);
        table.reloadData();

        win.tree.finalise();
        win.displayAll();

        // Click low on the scrollbar to jump-scroll down.  The bar sits at the table's right edge:
        // table x=10 w=300, sbWidth=14 -> bar at window-local x ~ 10+300-7 = 303; y in the row area
        // (below the 20px header): ~150 is near the bottom of the bar.
        i32 h = win.handle;
        pointer sf = fopen((u8*)"/tmp/hostgem_script.txt", (u8*)"w");
        if (sf != (pointer)0)
            {
            // Wheel DOWN over the table (gemd: -ve notches = down the list) — the window has no AES bar,
            // so gemd forwards the wheel to us and UXTableView scrolls itself.
            fputs(cat(cat((u8*)"WHEEL ", i2s(h)), (u8*)" 150 100 -2\n"), sf);
            fputs((u8*)"DELAY 400\n", sf);
            fclose(sf);
            }
        Stdio.printf("demo_tablescroll up\n");
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
    TsKit* kit = new TsKit();
    UXApplication* app = new UXApplication();
    app.setDelegate(kit);
    app.run();
    Stdio.printf("demo_tablescroll exited\n");
    }
