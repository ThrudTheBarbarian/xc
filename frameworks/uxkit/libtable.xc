// libtable.xc — the datasource protocol ACROSS the .so boundary.
//
// libdemo proved a client can subclass an Xtg class that lives in libUXKit.so and have the
// LIBRARY call its drawRect override back. This proves the harder direction:
//
//   * the PROTOCOL (UXTableDataSource) is declared inside the library;
//   * the class that adopts it is compiled in the CLIENT, and the library has never seen it;
//   * the library calls back into the client for every row and every cell;
//   * and UXTableDelegate's method is OPTIONAL — so the library reaches it through a `callback`
//     bound pointer whose receiver it only learns at run time, across the boundary.
//
// Nothing here #imports an Xtg source file. It links the library.
#import <Stdio.xc>
#import <GEM>
#import <UXKit>
#import "UXBoot.xc" // test scaffolding only (spawns gemd under qemu)
#import "UXAbi.xc"  // the ABI stamp libUXKit.so must match (generated)

#define NROWS 12

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

u8* gNames[NROWS];

// A CLIENT class adopting a protocol that is declared inside the library.
class Data : Object<UXTableDataSource, UXTableDelegate>
    {
    i32 asked; // how many times the LIBRARY called back into us
    i32 changes;
    i32 lastRow;
    void init(void)
        {
        asked = (i32)0;
        changes = (i32)0;
        lastRow = (i32)-1;
        }

    i32 numberOfRows(UXTableView* t)
        {
        return (i32)NROWS;
        }

    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        asked = asked + (i32)1;
        return gNames[row];
        }

    // OPTIONAL — the library must find it through &delegate.tableSelectionDidChange
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        changes = changes + (i32)1;
        lastRow = row;
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXTableView* table;
    Data* data;
    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        gFails = (i32)0;
        for (i32 i = (i32)0; i < (i32)NROWS; i++)
            {
            gNames[i] = "row";
            }

        data = new Data();
        table = new UXTableView(); // a class that lives in the .so
        win = new UXWindow();
        a.addWindow(win);
        win.open("libtable", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)100), table);

        table.setRowHeight((i16)16);
        table.addColumn("Name", (i16)90);
        table.addColumn("Kind", (i16)60);
        table.setDataSource(data); // a CLIENT object, through a library protocol
        table.setDelegate(data);

        table.reloadData();

        check("the library asked us how many rows", table.rowCount(), (i32)NROWS);
        Stdio.printf("the library called back into our datasource %d times (%d rows x %d cols)\n",
                     (i16)data.asked, (i16)NROWS, (i16)2);
        check("...once per cell", data.asked, (i32)NROWS * (i32)2);

        // Selection routes library -> client, through the OPTIONAL delegate method.
        table.selectRow((i32)3);
        check("the optional delegate method fired", data.changes, (i32)1);
        check("...with the right row", data.lastRow, (i32)3);

        // And the library's own machinery still works from out here.
        win.setContentSize((i16)150, table.contentHeight());
        win.tree.finalise();
        win.displayAll();
        a.pump((i32)200);
        check("selection survived the repaint", table.selection(), (i32)3);

        if (gFails == (i32)0)
            {
            Stdio.printf("PASS: a protocol declared in libUXKit.so, adopted by a class the library\n");
            Stdio.printf("      has never seen, called back across the .so boundary — including\n");
            Stdio.printf("      an OPTIONAL method reached through a bound-method pointer.\n");
            }
        else
            {
            Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    // THE VERSION GATE. Calling this references UXKit_abi_<major>_<minor>, so if libUXKit.so has
    // had an ABI break since we were compiled, the LOADER rejects us by name before main()
    // runs — instead of PC=0 in a stale vtable. The argument is the minimum PATCH we need,
    // and a newer patch is fine.
    if (!ux_require((i32)0))
        {
        Stdio.printf("libtable: libUXKit.so is too old\n");
        return;
        }

    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver(new UXGemDriver()); // GEM backend (lib client cannot name the gDriver global)
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
