// demo_scroll.xc — a file-list window that SCROLLS.  The UXKit scroll model is window-level: the table is
// laid out at its full height (all rows), the window is opened SHORTER than that, and setContentSize
// tells gemd the real extent.  The AES then draws the themed vertical bar, narrows the work area, runs
// the thumb/arrows/wheel, and clamps the offset — Xtg draws none of it (see test_scroll / UXTableView).
//
// Drives itself: it writes an injection script (wheel the table down a few notches) so the host_gemd
// `script` harness can dump a framebuffer WHILE scrolled, proving the bar moved and lower rows show.
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

#define DS_ROWS 30
#define DS_ROWH 18
#define DS_HDRH 18

u8* dsName[DS_ROWS];
u8* dsSize[DS_ROWS];
u8* dsKind[DS_ROWS];

u8* i2s(i32 n)
    {
    return UXStr.fromInt(n);
    }
u8* cat(u8* a, u8* b)
    {
    return UXStr.append(a, b);
    }

class DsKit : Object<UXApplicationDelegate, UXTableDataSource>
    {
    UXApplication* app;
    UXWindow* win;
    UXTableView* table;

    i32 numberOfRows(UXTableView* t)
        {
        return (i32)DS_ROWS;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row < (i32)0 || row >= (i32)DS_ROWS)
            {
            return (u8*)"";
            }
        if (col == (i32)0)
            {
            return dsName[row];
            }
        if (col == (i32)1)
            {
            return dsSize[row];
            }
        return dsKind[row];
        }

    void fillData(void)
        {
        for (i32 r = (i32)0; r < (i32)DS_ROWS; r++)
            {
            dsName[r] = cat((u8*)"file_", cat(i2s(r), (u8*)".txt"));
            dsSize[r] = cat(i2s((r + (i32)1) * (i32)3), (u8*)" KB");
            dsKind[r] = (r & (i32)1) == (i32)0 ? (u8*)"Text" : (u8*)"Data";
            }
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        self.fillData();

        UXView* doc = new UXView();
        win = new UXWindow();
        // Open the window SHORTER than the content: 8 rows of a 30-row table are visible -> overflow.
        win.open((u8*)"Files", UXGeom.make((i16)80, (i16)60, (i16)320, (i16)230), doc);
        a.addWindow(win);

        i16 contentH = (i16)((i32)DS_HDRH + (i32)DS_ROWS * (i32)DS_ROWH); // the table's full extent
        table = new UXTableView();
        // Keep the total column width UNDER the work width (a vertical bar takes ~12px) so ONLY the
        // vertical bar appears — a content wider than the work area would add a horizontal bar too.
        doc.addSubview(table, UXGeom.make((i16)0, (i16)0, (i16)284, contentH));
        table.setRowHeight((i16)DS_ROWH);
        table.addColumn((u8*)"Name", (i16)150);
        table.addColumn((u8*)"Size", (i16)60);
        table.addColumn((u8*)"Kind", (i16)74);
        table.setDataSource(self);
        table.reloadData();

        win.tree.finalise();
        // Tell the AES the real content height -> it draws the vertical bar + narrows the work area.
        // Width matches the columns, which fit the work area, so no horizontal bar.
        win.setContentSize((i16)284, contentH);
        win.displayAll();
        a.pump((i32)150); // let gemd answer with the narrowed work area

        // Injection script: put the pointer over the table, then wheel DOWN a few notches so the dump
        // captures a scrolled list (thumb off the top, lower rows visible).
        i32 h = win.handle;
        pointer sf = fopen((u8*)"/tmp/hostgem_script.txt", (u8*)"w");
        if (sf != (pointer)0)
            {
            fputs(cat(cat((u8*)"WHEEL ", i2s(h)), (u8*)" 60 60 -4\n"), sf); // -ve = wheel DOWN the list
            fputs((u8*)"DELAY 400\n", sf);
            fclose(sf);
            }
        Stdio.printf("demo_scroll up — content %ldpx in a ~150px work area\n", (i32)contentH);
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
    DsKit* kit = new DsKit();
    UXApplication* app = new UXApplication();
    app.setDelegate(kit);
    app.run();
    Stdio.printf("demo_scroll exited\n");
    }
