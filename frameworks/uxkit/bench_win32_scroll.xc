// bench_win32_scroll.xc — how long one scroll step takes on Win32, widget by widget.
//
// Each case opens a window with one scrollable widget full of content, then scrolls it from code in
// small steps, painting synchronously after each (RedrawWindow RDW_UPDATENOW | RDW_ALLCHILDREN), so
// a step's time is the scroll plus every repaint it causes -- what the user waits for per wheel
// notch.  Prints the mean and worst step per case.  Run it on real Windows (run_win32_scrollbench.sh):
// Wine's timings say little about GDI.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXScrollView.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXTextView.xc"
#import "UXCollectionView.xc"
#import "UXString.xc"
#import <RunLoop.xc>

i32 RedrawWindow(pointer hwnd, pointer rc, pointer rgn, u32 flags);

#define BENCH_STEPS 120
#define BENCH_STEP 12

UXWin32Driver* gDrv;

class Card : UXView
    {
    i32 n;
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)2, (i16)2, (i16)(b.w - (i16)4), (i16)(b.h - (i16)4)), (n & (i32)1) == (i32)0 ? (i32)0 : (i32)8);
        g.drawText(UXStr.append((u8*)"card ", UXStr.fromInt(n)), (i16)10, (i16)((b.h - (i16)16) / (i16)2), (i32)1, (i32)16);
        }
    }

class Rows : Object<UXTableDataSource>
    {
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)2000;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        return UXStr.append(col == (i32)0 ? (u8*)"row " : (u8*)"value ", UXStr.fromInt(row));
        }
    }

class Node : Object
    {
    i32 n;
    i32 depth;
    }
class Tree : Object<UXOutlineDataSource>
    {
    Array<Node>* nodes; // every node made once, so an item keeps its identity across calls
    void init(void)
        {
        nodes = new Array();
        }
    Node* node(i32 n, i32 depth)
        {
        for (u32 i = (u32)0; i < nodes.count(); i = i + (u32)1)
            {
            Node* x = (Node*)nodes.get(i);
            if (x.n == n && x.depth == depth)
                {
                return x;
                }
            }
        Node* m = new Node();
        m.n = n;
        m.depth = depth;
        nodes.add(m);
        return m;
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        if (item == (Object*)0)
            {
            return (i32)100;
            }
        return ((Node*)item).depth == (i32)0 ? (i32)10 : (i32)0;
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        if (item == (Object*)0)
            {
            return self.node(i, (i32)0);
            }
        return self.node(((Node*)item).n * (i32)100 + i, (i32)1);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        {
        return item == (Object*)0 || ((Node*)item).depth == (i32)0;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        {
        return UXStr.append((u8*)"item ", UXStr.fromInt(((Node*)item).n));
        }
    }

Rows* gRows;
Tree* gTree;

// One step: scroll, then paint everything the scroll invalidated, synchronously.
void step(UXWindow* w, UXScrollView* sv, i32 px)
    {
    sv.scrollTo((i16)px);
    RedrawWindow(gDrv.windowNative(w.handle), (pointer)0, (pointer)0, (u32)$0180); // RDW_UPDATENOW | RDW_ALLCHILDREN
    }

void measure(u8* name, UXWindow* w, UXScrollView* sv)
    {
    w.tree.finalise();
    w.displayAll();
    RedrawWindow(gDrv.windowNative(w.handle), (pointer)0, (pointer)0, (u32)$0180);
    if (sv == (UXScrollView*)0)
        {
        Stdio.printf("%-22s no scroll view\n", name);
        return;
        }
    i64 total = (i64)0;
    i64 worst = (i64)0;
    i32 pos = (i32)0;
    for (i32 i = (i32)0; i < (i32)BENCH_STEPS; i = i + (i32)1)
        {
        pos = pos + (i32)BENCH_STEP;
        i64 t0 = _runloop_now_us();
        step(w, sv, pos);
        i64 dt = _runloop_now_us() - t0;
        total = total + dt;
        if (dt > worst)
            {
            worst = dt;
            }
        }
    Stdio.printf("%-22s mean %6ld us/step   worst %6ld us   (scrolled to %d px)\n", name, total / (i64)BENCH_STEPS, worst, sv.scrollPx());
    w.close();
    }

UXWindow* openWin(u8* title, UXView** content)
    {
    UXWindow* w = new UXWindow();
    UXView* c = new UXView();
    w.open(title, UXGeom.make((i16)40, (i16)40, (i16)640, (i16)480), c);
    *content = c;
    return w;
    }

void main(void)
    {
    gDrv = new UXWin32Driver();
    gDriver = gDrv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXView* c = (UXView*)0;

    // 1. custom-drawn cards in a scroll view
    UXWindow* w = openWin((u8*)"cards", &c);
    UXScrollView* sv = new UXScrollView();
    c.addSubview(sv, UXGeom.make((i16)10, (i16)10, (i16)600, (i16)420));
    sv.setLineHeight((i16)34);
    for (i32 i = (i32)0; i < (i32)400; i = i + (i32)1)
        {
        Card* k = new Card();
        k.n = i;
        sv.document().addSubview(k, UXGeom.make((i16)0, (i16)(i * (i32)34), (i16)580, (i16)34));
        }
    sv.setDocumentHeight((i32)400 * (i32)34);
    measure((u8*)"cards (custom draw)", w, sv);

    // 2. native controls in a scroll view: a form
    w = openWin((u8*)"form", &c);
    sv = new UXScrollView();
    c.addSubview(sv, UXGeom.make((i16)10, (i16)10, (i16)600, (i16)420));
    sv.setLineHeight((i16)30);
    for (i32 i = (i32)0; i < (i32)150; i = i + (i32)1)
        {
        i16 y = (i16)(i * (i32)30);
        UXLabel* l = new UXLabel();
        l.setText(UXStr.append((u8*)"field ", UXStr.fromInt(i)));
        sv.document().addSubview(l, UXGeom.make((i16)4, (i16)(y + (i16)4), (i16)120, (i16)20));
        UXTextField* f = new UXTextField();
        f.setText((u8*)"text");
        sv.document().addSubview(f, UXGeom.make((i16)130, y, (i16)200, (i16)24));
        UXCheckbox* b = new UXCheckbox();
        sv.document().addSubview(b, UXGeom.make((i16)340, (i16)(y + (i16)4), (i16)20, (i16)20));
        UXButton* p = new UXButton();
        p.setTitle((u8*)"Go");
        sv.document().addSubview(p, UXGeom.make((i16)380, y, (i16)80, (i16)26));
        }
    sv.setDocumentHeight((i32)150 * (i32)30);
    measure((u8*)"form (native controls)", w, sv);

    // 3. a table
    w = openWin((u8*)"table", &c);
    UXTableView* t = new UXTableView();
    c.addSubview(t, UXGeom.make((i16)10, (i16)10, (i16)600, (i16)420));
    t.setRowHeight((i16)18);
    t.addColumn((u8*)"Name", (i16)200);
    t.addColumn((u8*)"Value", (i16)200);
    gRows = new Rows();
    t.setDataSource(gRows);
    t.reloadData();
    w.tree.finalise();
    w.displayAll(); // the table's scroll view is the realised one
    measure((u8*)"table (2000 rows)", w, t.scroll);

    // 4. an outline, every group open
    w = openWin((u8*)"outline", &c);
    UXOutlineView* o = new UXOutlineView();
    c.addSubview(o, UXGeom.make((i16)10, (i16)10, (i16)600, (i16)420));
    o.setRowHeight((i16)18);
    o.addColumn((u8*)"Item", (i16)300);
    gTree = new Tree();
    o.setOutlineSource(gTree);
    o.reloadData();
    for (i32 i = (i32)0; i < (i32)100; i = i + (i32)1)
        {
        o.setExpanded(gTree.node(i, (i32)0), true);
        }
    w.tree.finalise();
    w.displayAll();
    measure((u8*)"outline (1100 rows)", w, o.scroll);

    // 5. a long text view in a scroll view
    w = openWin((u8*)"text", &c);
    sv = new UXScrollView();
    c.addSubview(sv, UXGeom.make((i16)10, (i16)10, (i16)600, (i16)420));
    sv.setLineHeight((i16)16);
    UXTextView* tv = new UXTextView();
    String* s = String.withCString("");
    for (i32 i = (i32)0; i < (i32)600; i = i + (i32)1)
        {
        s = s.appending(String.withCString(UXStr.append((u8*)"Line of text in a long document, number ", UXStr.fromInt(i)))).appending(String.withCString("\n"));
        }
    tv.setText(s);
    sv.document().addSubview(tv, UXGeom.make((i16)0, (i16)0, (i16)580, (i16)9600));
    sv.setDocumentHeight((i32)9600);
    measure((u8*)"text view (600 lines)", w, sv);

    // 6. a collection view in a scroll view
    w = openWin((u8*)"collection", &c);
    sv = new UXScrollView();
    c.addSubview(sv, UXGeom.make((i16)10, (i16)10, (i16)600, (i16)420));
    sv.setLineHeight((i16)80);
    UXCollectionView* cv = new UXCollectionView();
    for (i32 i = (i32)0; i < (i32)600; i = i + (i32)1)
        {
        cv.addItem((Object*)0, UXStr.append((u8*)"item ", UXStr.fromInt(i)));
        }
    cv.layout((i16)580);
    sv.document().addSubview(cv, UXGeom.make((i16)0, (i16)0, (i16)580, (i16)cv.contentHeight));
    sv.setDocumentHeight(cv.contentHeight);
    measure((u8*)"collection (600 items)", w, sv);

    Stdio.printf("DONE\n");
    }
