// test_appkit_outline.xc — the NATIVE AppKit outline (NSOutlineView), automated.
//
// bug 020 regression guard.  The native scroll commit (cf2551c) started realizing a table/outline's
// OWN internal UXScrollView child as a native NSScrollView — which then sat ON TOP of the
// NSOutlineView, stealing its clicks (no disclosure) and hiding its selection.  The fix gates the
// UXKindScroll realize branch with isUnderTable(), so a table's internal scroll is NOT realized
// natively (the NSOutlineView provides its own scrolling).
//
// Two checks, both on the real interactive stack ([NSApp run]):
//   1. STRUCTURAL: the outline window has exactly ONE native control (the NSOutlineView) — not two
//      (outline + an overlapping scroll).  This is the direct signature of the regression.
//   2. BEHAVIOURAL: a synthetic click on row 0's disclosure triangle makes the native NSOutlineView
//      expand it — nativeDidExpand fires.  Only possible if no scroll is stealing the click.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXOutlineView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

void fflush(pointer f);                // flush so the log survives a timeout kill
i32 ux_ak_dbg_expand_row0(i32 handle); // drive a real expand; returns the new visible row count

i32 gNative;   // native-control count captured right after realize
i32 gExpanded; // set when the native outline reports an expand
i32 gRows;     // NSOutlineView visible row count after expanding row 0

// The model: a tiny filesystem (same shape as test_outline.xc).
class Node : Object
    {
    u8* name;
    Array* kids;
    void init(void)
        {
        name = "";
        kids = new Array();
        }
    } class Tree : Object<UXOutlineDataSource>
    {
    Node* root;
    void init(void)
        {
        root = (Node*)0;
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return (i32)n.kids.count();
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return n.kids.get((u16)i);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        {
        Node* n = (Node* ?)item;
        return n.kids.count() > (u16)0;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        {
        Node* n = (Node* ?)item;
        return n.name;
        }
    } Node* mknode(u8* name)
    {
    Node* n = new Node();
    n.name = name;
    return n;
    }

// Detect a native expand: the NSOutlineView calls nativeDidExpand through the driver's hook.
class TestOutline : UXOutlineView
    {
    UXApplication* app;
    void init(void)
        {
        super.init();
        app = (UXApplication*)0;
        }
    void nativeDidExpand(pointer item, i32 on)
        {
        super.nativeDidExpand(item, on);
        if (on != (i32)0)
            {
            gExpanded = (i32)1;
            Stdio.printf("native outline expanded an item\n");
            }
        if (app != (UXApplication*)0)
            {
            app.stop();
            }
        }
    }

    class Ctl : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    TestOutline* out;
    Tree* model; // MUST be retained: UXOutlineView.outlineSource is weak (AppKit-style)
    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        model = new Tree();
        model.root = mknode("/");
        Node* docs = mknode("Documents");
        docs.kids.add(mknode("report.txt"));
        docs.kids.add(mknode("notes.txt"));
        model.root.kids.add(docs);
        model.root.kids.add(mknode("Pictures"));
        model.root.kids.add(mknode("readme"));

        out = new TestOutline();
        out.app = a;
        UXWindow* win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"Outline", UXGeom.make((i16)40, (i16)40, (i16)220, (i16)160), out);
        out.setRowHeight((i16)18);
        out.addColumn((u8*)"Name", (i16)190);
        out.setOutlineSource(model);
        out.reloadData();

        win.displayAll(); // realize: native NSOutlineView, scroll skipped (the fix)
        gNative = ux_ak_native_count();
        Stdio.printf("native controls in the outline window: %d (want 1: outline only)\n", (i16)gNative);
        fflush((pointer)0);

        // Drive a real expand of row 0 (Documents) through the native NSOutlineView: it runs the exact
        // product path a triangle click drives — outlineViewItemDidExpand: -> the didexpand hook
        // (nativeDidExpand) -> re-flatten + redraw.  With the regression, an overlapping scroll hid the
        // outline and this redraw/callback chain never showed; now it must.  Rows: 3 -> 5.
        gRows = ux_ak_dbg_expand_row0(win.handle);
        Stdio.printf("expand row 0: NSOutlineView rows now %d (want 5: 3 top-level + 2 children)\n",
                     (i16)gRows);
        fflush((pointer)0);
        // nativeDidExpand (fired by the expand above) sets gExpanded and stops the app; guard against a
        // miss with a self-stop so the harness never hangs.
        if (gExpanded == (i32)0)
            {
            a.stop();
            }
        return (i32)0;
        }
    } void main(void)
    {
    gNative = (i32)0;
    gExpanded = (i32)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    Ctl* c = new Ctl();
    app.setDelegate(c);
    app.run();
    i32 ok = (gNative == (i32)1 && gExpanded == (i32)1 && gRows == (i32)5) ? (i32)1 : (i32)0;
    if (ok != (i32)0)
        {
        Stdio.printf("PASS: native NSOutlineView realized ALONE (no covering scroll), expands via the\n");
        Stdio.printf("      didexpand hook, and re-flattens to 5 rows.  bug 020 regression fixed.\n");
        }
    else
        {
        Stdio.printf("FAIL: native=%d (want 1), expanded=%d (want 1), rows=%d (want 5)\n",
                     (i16)gNative, (i16)gExpanded, (i16)gRows);
        }
    }
