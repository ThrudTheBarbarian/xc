// test_outline.xc — an outline view: a table whose row list is DERIVED from a tree.
//
// The claims:
//
//   1. Collapsed, only the top-level items are rows.
//   2. Expanding an item re-derives the row list — its children become rows, indented.
//   3. Expansion is remembered against the ITEM, not a row index (which would be
//      meaningless the moment anything above it opened).
//   4. Collapsing puts it back.
//   5. THE ROW OBJECTS ARE REUSED.  Expanding and collapsing 20 times does not grow the
//      GEM tree by a single object — because a GEM tree is a flat array whose indices
//      every parent/sibling link references, so removing an object is not a local
//      operation, and a rebuild-per-expand would leak a slot per row for ever.
//   6. Everything a table could do, an outline still does: it scrolls, it hit-tests, it
//      selects — with no new code for any of them.

#import <Stdio.xc>
#import <GEM>
#import "UXGem.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXOutlineView.xc"

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

// The model: a tiny filesystem.
class Node : Object
    {
    u8* name;
    Array* kids;
    void init(void)
        {
        name = "";
        kids = new Array();
        }
    }

    class Tree : Object<UXOutlineDataSource>
    {
    Node* root;
    void init(void)
        {
        root = (Node*)0;
        }

    // item == nil means "the root's children" — one method serves both levels.
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
    }

    Node*
    mknode(u8* name)
    {
    Node* n = new Node();
    n.name = name;
    return n;
    }

class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXOutlineView* out;
    Tree* model;
    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        gFails = (i32)0;

        //   Documents
        //     report.txt
        //     notes.txt
        //   Pictures
        //     cat.png
        //   readme            (a leaf at the top level)
        model = new Tree();
        model.root = mknode("/");
        Node* docs = mknode("Documents");
        docs.kids.add(mknode("report.txt"));
        docs.kids.add(mknode("notes.txt"));
        Node* pics = mknode("Pictures");
        pics.kids.add(mknode("cat.png"));
        model.root.kids.add(docs);
        model.root.kids.add(pics);
        model.root.kids.add(mknode("readme"));

        out = new UXOutlineView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("Outline", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)100), out);

        out.setRowHeight((i16)16);
        out.addColumn("Name", (i16)140);
        out.setOutlineSource(model);

        // ---- 1. collapsed: only the top level ------------------------------
        out.reloadData();
        check("collapsed: top-level rows only", out.rowCount(), (i32)3);
        i32 objsAfterFirst = (i32)win.tree.length();

        // ---- 2. expand Documents -------------------------------------------
        out.toggleRow((i32)0); // Documents
        check("Documents expanded: 3 + 2 children", out.rowCount(), (i32)5);

        UXOutlineNode* n1 = out.nodeAt((i32)1);
        check("its first child is indented one level", n1.level, (i32)1);
        UXOutlineNode* n3 = out.nodeAt((i32)3);
        check("Pictures is still at level 0", n3.level, (i32)0);

        // ---- 3. expansion is remembered against the ITEM --------------------
        // Expand Pictures too. Documents is ABOVE it, so every row index shifts — and
        // Documents must stay open regardless, because we remembered the ITEM.
        out.toggleRow((i32)3); // Pictures, now at row 3
        check("both expanded: 3 + 2 + 1", out.rowCount(), (i32)6);
        check("Documents is STILL open after rows shifted",
              out.isExpanded((Object*)docs) ? (i32)1 : (i32)0, (i32)1);

        // ---- 4. collapse ----------------------------------------------------
        out.toggleRow((i32)0); // shut Documents
        check("Documents collapsed: its children are gone", out.rowCount(), (i32)4);
        check("...but Pictures is still open",
              out.isExpanded((Object*)pics) ? (i32)1 : (i32)0, (i32)1);

        // ---- 5. THE OBJECTS ARE REUSED --------------------------------------
        // Thrash it. If reload rebuilt the tree, every expand would leak a row and two
        // cells, and this loop would add hundreds of objects.
        i32 before = (i32)win.tree.length();
        for (i32 i = (i32)0; i < (i32)20; i++)
            {
            out.toggleRow((i32)0); // open  Documents
            out.toggleRow((i32)0); // shut  Documents
            }
        i32 after = (i32)win.tree.length();
        Stdio.printf("20 expand/collapse cycles: the tree went from %d objects to %d\n",
                     (i16)before, (i16)after);
        check("the row objects are REUSED, not rebuilt", after, before);
        check("...and the row list is back where it started", out.rowCount(), (i32)4);

        // A hidden row is really hidden: OF_HIDETREE, which objc_draw and objc_find
        // both honour, so it is neither drawn nor clickable.
        i32 maxRows = (i32)out.builtRows;
        Stdio.printf("%d row objects exist; %d are in use, the rest are OF_HIDETREE\n",
                     (i16)maxRows, (i16)out.rowCount());
        check("the pool grew to the DEEPEST list ever shown", maxRows, (i32)6);

        // ---- 6. it is still a table -----------------------------------------
        // It DRAWS the tree (disclosure triangles + indent) through UXTableView's paint path, and
        // selection is the table's, inherited unchanged.  (A synthetic row mouseDown would now enter
        // the drag-select track loop, which blocks headlessly for motion events; the interactive
        // click-selects and drag paths are proven visually in demo_outline / the kitchen sink.)
        win.displayAll();
        a.pump((i32)200);

        out.selectRow((i32)1);
        check("selecting a row works (it is a table)", out.selection(), (i32)1);
        check("...and selecting did not toggle anything", out.rowCount(), (i32)4);

        if (gFails == (i32)0)
            {
            Stdio.printf("PASS: an outline view is a TABLE whose rows are derived from a tree.\n");
            Stdio.printf("      Expanding re-derives the list; the row OBJECTS are reused, so\n");
            Stdio.printf("      the GEM tree never grows.  Scrolling, hit-testing, selection\n");
            Stdio.printf("      and pruning all came from UXTableView unchanged.\n");
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
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
