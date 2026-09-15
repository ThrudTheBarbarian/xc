// evkit_a9.xt — broader event-injection coverage for the GEM backend (native arm64 on host gemd).
//
// Where ev_a9 proves ONE button click, this drives the interactive surface UXKit's toolkit owns but that
// had never been exercised on GEM before: TABLE row selection, TEXT-FIELD focus + keyboard editing,
// and button actions.  It builds the widgets, reports an injection SCRIPT of their screen positions +
// keystrokes (the harness plays it — see host_gemd `script` mode), and each toolkit callback writes an
// outcome marker to a result file.  Assert the markers and the whole path is proven, headless.
#import <Stdio.xt>
#import "UXGemDriver.xt"
#import "UXBoot.xt"
#import "UXApplication.xt"
#import "UXWindow.xt"
#import "UXView.xt"
#import "UXControl.xt"
#import "UXTableView.xt"
#import "UXMenu.xt"
#import "UXGeometry.xt"
#import "UXGraphics.xt"
#import "UXEvent.xt"
#import "UXString.xt"

pointer fopen(u8 @path, u8 @mode);
i32 fputs(u8 @s, pointer f);
i32 fclose(pointer f);

#define EVK_ROWS 4

u8 @evName[EVK_ROWS];

// Append one line to the outcome-marker file (unbuffered witness — see ev_a9).
void mark(u8 @s)
    {
    pointer f = fopen((u8 @) "/tmp/hostgem_ev_result.txt", (u8 @) "a");
    if (f != (pointer)0)
        {
        fputs(s, f);
        fputs((u8 @) "\n", f);
        fclose(f);
        }
    }

u8 @i2s(i32 n)
    {
    return UXStr.fromInt(n);
    }
u8 @cat(u8 @a, u8 @b)
    {
    return UXStr.append(a, b);
    }
// "CLICK <handle> <cx> <cy>\n" for the centre of a window-local rect.
u8 @clickLine(i32 h, UXRect f)
    {
    i32 cx = (i32)f.x + (i32)f.w / (i32)2;
    i32 cy = (i32)f.y + (i32)f.h / (i32)2;
    return cat(cat(cat(cat(cat(cat((u8 @) "CLICK ", i2s(h)), (u8 @) " "), i2s(cx)), (u8 @) " "), i2s(cy)), (u8 @) "\n");
    }
u8 @keyLine(i32 ascii)
    {
    return cat(cat((u8 @) "KEY ", i2s(ascii)), (u8 @) " 0\n");
    }
// "SCLICK <x> <y>\n" — an absolute-screen click (menus live outside any window's work area).
u8 @sclickLine(i32 x, i32 y)
    {
    return cat(cat(cat(cat((u8 @) "SCLICK ", i2s(x)), (u8 @) " "), i2s(y)), (u8 @) "\n");
    }

class EvCanvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics @g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8);
        }
    }

    class EvKit : Object<UXApplicationDelegate, UXTableDataSource, UXTableDelegate>
    {
    UXApplication @app;
    UXWindow @win;
    UXTextField @field;
    UXTableView @table;
    UXButton @check;
    UXButton @quit;

    // ---- table datasource / delegate ----------------------------------------
    i32 numberOfRows(UXTableView @t)
        {
        return (i32)EVK_ROWS;
        }
    u8 @valueForCell(UXTableView @t, i32 row, i32 col)
        {
        if (row < (i32)0 || row >= (i32)EVK_ROWS)
            {
            return (u8 @) "";
            }
        return evName[row];
        }
    void tableSelectionDidChange(UXTableView @t, i32 row)
        {
        mark(cat((u8 @) "TABLE_ROW ", i2s(row)));               // a row click reached the toolkit's selection
        mark(cat((u8 @) "TABLE_SEL ", i2s(t.selectedCount()))); // how many rows are selected (multi-select)
        }

    // ---- button + menu actions ----------------------------------------------
    void onCheck(UXControl @c)
        {
        mark(cat(cat((u8 @) "FIELD [", field.text()), (u8 @) "]"));
        }
    void onQuit(UXControl @c)
        {
        mark((u8 @) "QUIT");
        app.stop();
        }
    // a dropdown item selection reached its action
    void onPing(UXMenuItem @s)
        {
        mark((u8 @) "MENU_PING");
        }

    i32 applicationDidStart(UXApplication @a)
        {
        app = a;
        evName[0] = (u8 @) "alpha";
        evName[1] = (u8 @) "bravo";
        evName[2] = (u8 @) "charlie";
        evName[3] = (u8 @) "delta";

        EvCanvas @canvas = new EvCanvas();
        win = new UXWindow();
        win.open((u8 @) "UXKit Event Kit", UXGeom.make((i16)120, (i16)90, (i16)400, (i16)300), canvas);
        a.addWindow(win);

        field = new UXTextField();
        canvas.addSubview(field, UXGeom.make((i16)100, (i16)26, (i16)200, (i16)24));

        table = new UXTableView();
        canvas.addSubview(table, UXGeom.make((i16)16, (i16)66, (i16)360, (i16)72));
        table.setRowHeight((i16)18);
        table.addColumn((u8 @) "Name", (i16)356);
        table.setAllowsMultipleSelection(true); // so a ctrl-click extends the selection
        table.setDataSource(self);
        table.setDelegate(self);
        table.reloadData();

        check = new UXButton();
        check.setTitle((u8 @) "Check");
        check.setAction(&self.onCheck);
        canvas.addSubview(check, UXGeom.make((i16)16, (i16)160, (i16)90, (i16)28));
        quit = new UXButton();
        quit.setTitle((u8 @) "Quit");
        quit.setAction(&self.onQuit);
        canvas.addSubview(quit, UXGeom.make((i16)120, (i16)160, (i16)90, (i16)28));

        // A menu bar: File -> Ping.  setMenuBar installs + shows it, so bar.tree is live afterwards.
        UXMenuBar @bar = new UXMenuBar();
        UXMenu @file = bar.addMenu((u8 @) "File");
        file.addItem((u8 @) "Ping", &self.onPing);
        a.setMenuBar(bar);

        win.tree.finalise();
        win.displayAll();

        // Menu geometry: title 0 is OBJECT index 2 in the menu tree; objc_offset gives its SCREEN x
        // (the bar spans the top at y=0).  The strip height is the SERVER's to know (a client's
        // aes_top_reserve is 0), so the harness resolves the dropdown y — we just report the title x.
        i32 tx = (i32)0;
        i32 ty = (i32)0;
        gDriver.treeOffset(bar.tree, (i32)2, &tx, &ty);

        // Report the injection script.  Row 1 (the 2nd row) sits at table-local y = 1*rowHeight.
        i32 h = win.handle;
        UXRect tf = table.absoluteFrame();
        i32 rh = (i32)table.rowHeightValue();
        UXRect row1 = UXGeom.make(tf.x, (i16)((i32)tf.y + rh), tf.w, (i16)rh);
        UXRect row3 = UXGeom.make(tf.x, (i16)((i32)tf.y + rh * (i32)3), tf.w, (i16)rh);
        i32 r3cx = (i32)row3.x + (i32)row3.w / (i32)2;
        i32 r3cy = (i32)row3.y + (i32)row3.h / (i32)2;
        pointer sf = fopen((u8 @) "/tmp/hostgem_script.txt", (u8 @) "w");
        if (sf != (pointer)0)
            {
            fputs(clickLine(h, row1), sf); // select row 1  -> TABLE_SEL 1
            fputs((u8 @) "DELAY 200\n", sf);
            // ctrl-click row 3 (GEM Kbshift 0x04 = ctrl) -> should EXTEND to TABLE_SEL 2 (multi-select)
            fputs(cat(cat(cat(cat(cat((u8 @) "MCLICK ", i2s(h)), cat((u8 @) " ", i2s(r3cx))),
                              (u8 @) " "),
                          i2s(r3cy)),
                      (u8 @) " 4\n"),
                  sf);
            fputs((u8 @) "DELAY 200\n", sf);
            fputs(clickLine(h, field.absoluteFrame()), sf); // focus the field
            fputs((u8 @) "DELAY 200\n", sf);
            fputs(keyLine((i32)72), sf);  // 'H'
            fputs(keyLine((i32)105), sf); // 'i'
            fputs((u8 @) "DELAY 150\n", sf);
            fputs(clickLine(h, check.absoluteFrame()), sf); // Check -> writes FIELD [Hi]
            fputs((u8 @) "DELAY 300\n", sf);
            fputs(cat(cat((u8 @) "MTITLE ", i2s(tx)), (u8 @) "\n"), sf);  // open the File menu
            fputs((u8 @) "DELAY 300\n", sf);                              // let the dropdown open
            fputs(cat(cat((u8 @) "MITEM ", i2s(tx)), (u8 @) " 8\n"), sf); // click item 0 (Ping)
            fputs((u8 @) "DELAY 300\n", sf);
            fputs(clickLine(h, quit.absoluteFrame()), sf); // Quit -> stop
            fclose(sf);
            }
        Stdio.printf("evkit up — script written (title x=%ld)\n", tx);
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
    EvKit @kit = new EvKit();
    UXApplication @app = new UXApplication();
    app.setDelegate(kit);
    app.run();
    Stdio.printf("evkit exited\n");
    }
