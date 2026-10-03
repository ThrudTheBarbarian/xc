// test_outline_native.xc — UXOutlineView as the mobile platforms' native list: a UITableView on iOS
// (ios-outline), a ListView on Android (android-outline, built with -D TABLE_ANDROID).  Neither has
// a tree of its own, so an outline is the list of its flattened visible rows, each indented by its
// depth, with a chevron (iOS) or an arrow (Android) in front of an item that can open.  Checked: the
// closed tree's rows, the disclosure shown, a USER's tap on it opening the item in the model (on
// Android a REAL tap, the gate's adb input tap), the children indented under it, a row selected by
// tap being that item, and an item the app opens shown open after a reload.
#import <Stdio.xc>
#if TABLE_ANDROID
#import "UXAndroidDriver.xc"
#else
#import "UXIosDriver.xc"
#endif
#import "UXWindow.xc"
#import "UXOutlineView.xc"

i32 gFails;

#if TABLE_ANDROID
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern i32 ux_and_test_table_rows(i32 handle, i32 node);
extern i32 ux_and_test_table_selected(i32 handle, i32 node, i32 row);
extern i32 ux_and_test_table_cell_is(i32 handle, i32 node, i32 row, i32 col, u8* want);
extern void ux_and_test_table_tap(i32 handle, i32 node, i32 row);
extern i32 ux_and_test_table_chevron(i32 handle, i32 node, i32 row);
extern i32 ux_and_test_table_indent(i32 handle, i32 node, i32 row);
extern void ux_and_test_table_arrow_at(i32 handle, i32 node, i32 row, i32* x, i32* y);
i32 tChevron(i32 h, i32 n, i32 r) { return ux_and_test_table_chevron(h, n, r); }
i32 tIndent(i32 h, i32 n, i32 r) { return ux_and_test_table_indent(h, n, r); }
extern i32 ux_and_test_table_shown(i32 handle, i32 node);
extern void ux_and_test_table_row_at(i32 handle, i32 node, i32 row, i32* x, i32* y);
i32 tShown(i32 h, i32 n) { return ux_and_test_table_shown(h, n); }
i32 tRows(i32 h, i32 n) { return ux_and_test_table_rows(h, n); }
i32 tSelected(i32 h, i32 n, i32 r) { return ux_and_test_table_selected(h, n, r); }
i32 tCellIs(i32 h, i32 n, i32 r, i32 c, u8* w) { return ux_and_test_table_cell_is(h, n, r, c, w); }
void tTap(i32 h, i32 n, i32 r) { ux_and_test_table_tap(h, n, r); }
void tWatchdog(void) { ux_and_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_and_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_and_quit(rc); }
#else
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_table_rows(i32 handle, i32 node);
extern i32 ux_ios_test_table_selected(i32 handle, i32 node, i32 row);
extern i32 ux_ios_test_table_cell_is(i32 handle, i32 node, i32 row, i32 col, u8* want);
extern void ux_ios_test_table_tap(i32 handle, i32 node, i32 row);
extern i32 ux_ios_test_table_chevron(i32 handle, i32 node, i32 row);
extern i32 ux_ios_test_table_indent(i32 handle, i32 node, i32 row);
extern void ux_ios_test_table_disclose(i32 handle, i32 node, i32 row);
i32 tChevron(i32 h, i32 n, i32 r) { return ux_ios_test_table_chevron(h, n, r); }
i32 tIndent(i32 h, i32 n, i32 r) { return ux_ios_test_table_indent(h, n, r); }
extern i32 ux_ios_test_table_shown(i32 handle, i32 node);
i32 tShown(i32 h, i32 n) { return ux_ios_test_table_shown(h, n); }
i32 tRows(i32 h, i32 n) { return ux_ios_test_table_rows(h, n); }
i32 tSelected(i32 h, i32 n, i32 r) { return ux_ios_test_table_selected(h, n, r); }
i32 tCellIs(i32 h, i32 n, i32 r, i32 c, u8* w) { return ux_ios_test_table_cell_is(h, n, r, c, w); }
void tTap(i32 h, i32 n, i32 r) { ux_ios_test_table_tap(h, n, r); }
void tWatchdog(void) { ux_ios_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_ios_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_ios_quit(rc); }
#endif
void finish(void)
    {
    tQuit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void verdict(void)
    {
    Stdio.printf(gFails == (i32)0 ? "PASS: UXOutlineView is the platform's native list -- flattened rows, disclosure, a tap opens, indent, selection by item\n" : "FAIL: %d\n", gFails);
    tLater((pointer)&finish, (i32)2500); // up a moment, for a screenshot
    }

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
    }

// all global: the outline holds its source weakly, and the checks run after testBody returns
Tree* gTree;
Node* gProjects;
UXOutlineView* gOut;
UXWindow* gWin;
i32 gH;
i32 gN;

void afterOpen(void)
    {
    gWin.displayAll();
    ck((u8*)"tapping the disclosure opens Projects: four rows", tRows(gH, gN) == (i32)4);
    ck((u8*)"...and the model knows it is open", gOut.isExpanded((Object*)gProjects));
    ck((u8*)"...its chevron now shows it open", tChevron(gH, gN, (i32)0) == (i32)2);
    ck((u8*)"...its children sit indented under it", tIndent(gH, gN, (i32)1) > tIndent(gH, gN, (i32)0)
       && tCellIs(gH, gN, (i32)2, (i32)0, (u8*)"rocks") != (i32)0);
    tTap(gH, gN, (i32)2);
    UXOutlineNode* sel = gOut.nodeAt(gOut.selectedRow);
    ck((u8*)"the row tapped is that item in the model", gOut.selectedRow == (i32)2 && sel != (UXOutlineNode*)0
       && sel.item == (Object*)gProjects.kids.get((u16)1));
    gOut.setExpanded((Object*)gProjects, false);
    gOut.reloadData();
    gWin.displayAll();
    ck((u8*)"closed by the app, the children go", tRows(gH, gN) == (i32)2 && tChevron(gH, gN, (i32)0) == (i32)1);
    gOut.setExpanded((Object*)gProjects, true);
    gOut.reloadData();
    gWin.displayAll();
    ck((u8*)"opened by the app, they come back", tRows(gH, gN) == (i32)4);
    verdict();
    }

void afterLayout(void)
    {
    ck((u8*)"the native list shows the closed tree's two rows", tShown(gH, gN) == (i32)2);
#if TABLE_ANDROID
    i32 x = (i32)0;
    i32 y = (i32)0;
    ux_and_test_table_arrow_at(gH, gN, (i32)0, &x, &y);
    Stdio.printf("TAPAT %d %d\n", x, y);
    tLater((pointer)&afterOpen, (i32)4000);
#else
    ux_ios_test_table_disclose(gH, gN, (i32)0);
    tLater((pointer)&afterOpen, (i32)300);
#endif
    }

void testBody(void)
    {
    gFails = (i32)0;
    tWatchdog();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        tQuit((i32)1);
        return;
        }
    UXView* content = new UXView();
    gWin = new UXWindow();
    gWin.open((u8*)"outline", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(gWin);
    gTree = new Tree();
    Node* root = mknode((u8*)"");
    gProjects = mknode((u8*)"Projects");
    gProjects.kids.add(mknode((u8*)"uxkit"));
    gProjects.kids.add(mknode((u8*)"rocks"));
    root.kids.add(gProjects);
    root.kids.add(mknode((u8*)"Docs"));
    gTree.root = root;
    gOut = new UXOutlineView();
    content.addSubview(gOut, UXGeom.make((i16)0, (i16)20, (i16)sw, (i16)300));
    gOut.addColumn((u8*)"Name", (i16)200);
    gOut.setOutlineSource(gTree);
    gOut.reloadData();
    gWin.tree.finalise();
    gWin.displayAll();
    gH = gWin.handle;
    gN = (i32)gOut.index;
    ck((u8*)"a native list of the closed tree's two rows", tRows(gH, gN) == (i32)2);
    ck((u8*)"...Projects with a closed disclosure, Docs with none", tChevron(gH, gN, (i32)0) == (i32)1 && tChevron(gH, gN, (i32)1) == (i32)0);
    tLater((pointer)&afterLayout, (i32)800);
    }

void main(void)
    {
#if TABLE_ANDROID
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
#else
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
#endif
    }
