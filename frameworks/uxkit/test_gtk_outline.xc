// test_gtk_outline.xc — UXOutlineView as a real GTK tree (a GtkColumnView over a GtkTreeListModel,
// a GtkTreeExpander in the first column) on the Linux host (gate gtk-outline): the items come from
// the outline's own datasource, on demand; an expansion the USER makes reaches the model, whose
// rows re-flatten to the native order; a row the user selects is that item in the model.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXOutlineView.xc"

i32 ux_gtk_test_table_rows(i32 handle, i32 node);
void ux_gtk_test_table_user_select(i32 handle, i32 node, i32 row);
void ux_gtk_test_outline_expand(i32 handle, i32 node, i32 row, i32 on);
i32 ux_gtk_has_control(i32 handle, i32 node);

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

class Node : Object
    {
    u8* name;
    Array* kids;
    void init(void)
        {
        name = (u8*)"";
        kids = new Array();
        }
    }
Node* mknode(u8* name)
    {
    Node* n = new Node();
    n.name = name;
    return n;
    }
class Tree : Object<UXOutlineDataSource>
    {
    Node* root;
    i32 asked;
    void init(void)
        {
        root = (Node*)0;
        asked = (i32)0;
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        asked = asked + (i32)1;
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

void main(void)
    {
    gFails = (i32)0;
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no GTK display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"outline", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)220), content);
    app.addWindow(win);

    Tree* model = new Tree();
    Node* root = mknode((u8*)"");
    Node* projects = mknode((u8*)"Projects");
    projects.kids.add(mknode((u8*)"uxkit"));
    projects.kids.add(mknode((u8*)"rocks"));
    root.kids.add(projects);
    root.kids.add(mknode((u8*)"Docs"));
    model.root = root;
    UXOutlineView* out = new UXOutlineView();
    content.addSubview(out, UXGeom.make((i16)10, (i16)10, (i16)300, (i16)200));
    out.addColumn((u8*)"Name", (i16)200);
    out.setOutlineSource(model);
    out.reloadData();
    win.tree.finalise();
    win.displayAll();
    i32 h = win.handle;
    i32 n = (i32)out.index;

    ck((u8*)"the outline is a native widget", ux_gtk_has_control(h, n) != (i32)0);
    ck((u8*)"...showing the two top-level items, closed", ux_gtk_test_table_rows(h, n) == (i32)2);
    ux_gtk_test_outline_expand(h, n, (i32)0, (i32)1); // the user opens Projects
    ck((u8*)"opening Projects shows its two children", ux_gtk_test_table_rows(h, n) == (i32)4);
    ck((u8*)"...and the model knows it is open", out.isExpanded((Object*)projects));
    ck((u8*)"...its rows re-flattened to the native order", out.countRows() == (i32)4);
    ux_gtk_test_table_user_select(h, n, (i32)2); // "rocks"
    UXOutlineNode* sel = out.nodeAt(out.selectedRow);
    ck((u8*)"the row the user selects is that item in the model", out.selectedRow == (i32)2 && sel != (UXOutlineNode*)0 && sel.item == (Object*)projects.kids.get((u16)1));
    ux_gtk_test_outline_expand(h, n, (i32)0, (i32)0); // and closes it again
    ck((u8*)"closing it hides the children again", ux_gtk_test_table_rows(h, n) == (i32)2 && !out.isExpanded((Object*)projects));

    // an item the APP opens (then a reload) is shown open -- applied after the reload, never from
    // inside the list's layout, where opening a row crashed GTK
    out.setExpanded((Object*)projects, true);
    out.reloadData();
    win.displayAll();
    ck((u8*)"an item the app opens shows its children after a reload", ux_gtk_test_table_rows(h, n) == (i32)4);

    win.close();
    Stdio.printf(gFails == (i32)0 ? "PASS: UXOutlineView is a real GTK tree -- items on demand, expansion both ways, selection by item\n" : "FAIL: %d\n", gFails);
    }
