// test_metrics_audit.xc — does each backend draw every stock control where its frame says?
//
// Each control kind is placed at its UXMetrics desktop height and 12 px taller, 120 wide, over a
// magenta backdrop; the window is snapshotted and the box of non-backdrop pixels around each frame
// is checked against the layout contract:
//
//   inside   the control draws within its frame (1 px of shadow allowed)
//   centred  the space above it equals the space below (+/- 1 px), so a control that keeps its own
//            height sits in the middle of its row, and one that fills the frame passes too
//   top      a label's text starts at the top of its frame (ink within 5 px of it) at any height
//
// Then the controls make way for the larger views (text, scroll, tab, split, group box, combo box,
// date picker, table, outline, collection), each in a 130 x 90 frame, checked for drawing inside it
// and, for a view with an edge, for filling it:
//
//   fills    the view's ink reaches each side of its frame (within 1 px), so views placed side by
//            side by springs and struts meet as their frames do
//
// Each check prints "ok" or "FAIL" with a key, <kind>@<height> <rule>.  The verdict is the runner's
// (run_metrics_audit.sh): it compares the FAIL keys with the backend's known failures in
// expected_metrics_audit.txt, so the gate catches a regression and reports a fix.
// Built with -D SNAP_<BACKEND>, as test_snapshot.xc.
#import <Stdio.xc>
#import <Progress.xc>
#if SNAP_APPKIT
#import "UXAppKitDriver.xc"
#endif
#if SNAP_WIN32
#import "UXWin32Driver.xc"
#endif
#if SNAP_GTK
#import "UXGtkDriver.xc"
void ux_gtk_wait_allocated(i32 handle);
#endif
#if SNAP_WEB
#import "UXWebDriver.xc"
#endif
#if SNAP_GEM
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#endif
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXStepper.xc"
#import "UXProgressBar.xc"
#import "UXSegmentedControl.xc"
#import "UXPopUpButton.xc"
#import "UXTextView.xc"
#import "UXScrollView.xc"
#import "UXTabView.xc"
#import "UXSplitView.xc"
#import "UXGroupBox.xc"
#import "UXComboBox.xc"
#import "UXDatePicker.xc"
#import "UXOutlineView.xc"
#import "UXCollectionView.xc"
#import "UXTableView.xc"
#import "UXMetrics.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXFileIO.xc"
#import "UXPngEncode.xc"

u8* getenv(u8* name);

class Backdrop : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), 255, 0, 255);
        }
    }

i32 NKINDS = 10;
i32 COLW = 120;
i32 PITCHX = 150;
i32 PITCHY = 64;
i32 LEFT = 20;
i32 TOP = 20;
i32 GROW = 12; // the second column of a pair: the standard height plus this
i32 ROWS = 5;  // kinds 0-4 in the first pair of columns, 5-9 in the second: the window fits 640x480

UXWindow* gWin;
UXView* gBack;
i32 gFails;

u8* kindName(i32 k)
    {
    if (k == 0) { return (u8*)"button"; }
    if (k == 1) { return (u8*)"field"; }
    if (k == 2) { return (u8*)"label"; }
    if (k == 3) { return (u8*)"checkbox"; }
    if (k == 4) { return (u8*)"radio"; }
    if (k == 5) { return (u8*)"popup"; }
    if (k == 6) { return (u8*)"slider"; }
    if (k == 7) { return (u8*)"stepper"; }
    if (k == 8) { return (u8*)"progress"; }
    return (u8*)"segmented";
    }

// the UXKind whose standard height row k uses
i32 kindOf(i32 k)
    {
    if (k == 0) { return (i32)UXKindButton; }
    if (k == 1) { return (i32)UXKindField; }
    if (k == 2) { return (i32)UXKindLabel; }
    if (k == 3) { return (i32)UXKindCheckbox; }
    if (k == 4) { return (i32)UXKindRadio; }
    if (k == 5) { return (i32)UXKindPopup; }
    if (k == 6) { return (i32)UXKindSlider; }
    if (k == 7) { return (i32)UXKindStepper; }
    if (k == 8) { return (i32)UXKindProgress; }
    return (i32)UXKindSegmented;
    }

// the frame of kind k in column c (0: the standard height, 1: GROW taller)
i32 frameX(i32 k, i32 c)
    {
    return LEFT + ((k / ROWS) * 2 + c) * PITCHX;
    }
i32 frameY(i32 k)
    {
    return TOP + (k % ROWS) * PITCHY;
    }

i32 heightOf(i32 k, i32 col)
    {
    i32 h = UXMetrics.stdHeightFor(kindOf(k), (i32)UX_FORM_DESKTOP);
    return col == 0 ? h : h + GROW;
    }

UXView* makeKind(i32 k)
    {
    if (k == 0)
        {
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Cancel");
        return b;
        }
    if (k == 1)
        {
        UXTextField* f = new UXTextField();
        f.setText((u8*)"Hamburg");
        return f;
        }
    if (k == 2)
        {
        UXLabel* l = new UXLabel();
        l.setText((u8*)"Hamburg");
        return l;
        }
    if (k == 3)
        {
        UXCheckbox* c = new UXCheckbox();
        c.setTitle((u8*)"Check");
        c.setChecked(true);
        return c;
        }
    if (k == 4)
        {
        UXRadioButton* r = new UXRadioButton();
        r.setTitle((u8*)"Radio");
        r.setSelected(true);
        return r;
        }
    if (k == 5)
        {
        UXPopUpButton* p = new UXPopUpButton();
        p.addItem((u8*)"Popup", 1);
        p.addItem((u8*)"Other", 2);
        return p;
        }
    if (k == 6)
        {
        UXSlider* s = new UXSlider();
        s.setRange(0, 100);
        s.setValue(40);
        return s;
        }
    if (k == 7)
        {
        UXStepper* st = new UXStepper();
        st.setRange(0, 10);
        st.setValue(3);
        return st;
        }
    if (k == 8)
        {
        UXProgressBar* pb = new UXProgressBar();
        Progress* pr = new Progress();
        pr.setTotalUnitCount((i64)100);
        pr.setCompletedUnitCount((i64)50);
        pb.setProgress(pr);
        return pb;
        }
    UXSegmentedControl* sc = new UXSegmentedControl();
    sc.addSegment((u8*)"One", 1);
    sc.addSegment((u8*)"Two", 2);
    sc.selectSegment(0); // a selected segment draws as the control does in use
    return sc;
    }

void build(i32 x, i32 y)
    {
    UXView* back = new Backdrop();
    gBack = back;
    gWin = new UXWindow();
    gWin.open((u8*)"metrics audit", UXGeom.make((i16)x, (i16)y, (i16)(LEFT + 4 * PITCHX), (i16)(TOP + ROWS * PITCHY)), back);
    if (gApp != (UXApplication*)0)
        {
        gApp.addWindow(gWin);
        }
    for (i32 k = 0; k < NKINDS; k = k + 1)
        {
        for (i32 c = 0; c < 2; c = c + 1)
            {
            back.addSubview(makeKind(k), UXGeom.make((i16)frameX(k, c), (i16)frameY(k), (i16)COLW, (i16)heightOf(k, c)));
            }
        }
    gWin.displayAll();
#if SNAP_GTK
    ux_gtk_wait_allocated(gWin.handle); // the frame clock: a headless gate has no window manager
#endif
    gWin.displayAll();
    }

bool isBackdrop(u32 v)
    {
    i32 dr = (i32)((v >> (u32)16) & (u32)255) - 255;
    i32 dg = (i32)((v >> (u32)8) & (u32)255);
    i32 db = (i32)(v & (u32)255) - 255;
    return dr * dr + dg * dg + db * db < 150;
    }

// the box of non-backdrop pixels in (fx, fy, fw, fh) grown by m, relative to the frame's origin;
// out[2] (the width) is 0 when nothing is drawn there
void inkBox(UXImage* im, i32 fx, i32 fy, i32 fw, i32 fh, i32 m, i32* out)
    {
    i32 x0 = 100000;
    i32 y0 = 100000;
    i32 x1 = -100000;
    i32 y1 = -100000;
    for (i32 y = fy - m; y < fy + fh + m; y = y + 1)
        {
        for (i32 x = fx - m; x < fx + fw + m; x = x + 1)
            {
            if (x >= 0 && y >= 0 && x < im.w && y < im.h && !isBackdrop(im.px[y * im.w + x]))
                {
                x0 = x < x0 ? x : x0;
                y0 = y < y0 ? y : y0;
                x1 = x > x1 ? x : x1;
                y1 = y > y1 ? y : y1;
                }
            }
        }
    out[0] = x0 - fx;
    out[1] = y0 - fy;
    out[2] = x1 < x0 ? 0 : x1 - x0 + 1;
    out[3] = y1 < y0 ? 0 : y1 - y0 + 1;
    }

void ck(bool good, u8* kind, i32 h, u8* rule, i32* b)
    {
    Stdio.printf("  %s %s@%d %s (ink %d,%d %dx%d)\n", good ? (u8*)"ok  " : (u8*)"FAIL", kind, h, rule, b[0], b[1], b[2], b[3]);
    if (!good)
        {
        gFails = gFails + 1;
        }
    }

void audit(void)
    {
    UXImage* all = gWin.snapshot((UXRect*)0);
    if (all == (UXImage*)0)
        {
        Stdio.printf("FAIL: the window did not snapshot\n");
        return;
        }
#if !SNAP_WEB
    // UX_AUDIT_PNG=<file>: the snapshot, for a person to look at
    u8* save = getenv((u8*)"UX_AUDIT_PNG");
    if (save != (u8*)0)
        {
        UXFileIO.write(save, UXPngEncode.encode(all));
        }
#endif
    i32 b[4];
    for (i32 k = 0; k < NKINDS; k = k + 1)
        {
        for (i32 c = 0; c < 2; c = c + 1)
            {
            i32 h = heightOf(k, c);
            inkBox(all, frameX(k, c), frameY(k), COLW, h, 10, &b[0]);
            bool drawn = b[2] > 0;
            bool inside = drawn && b[0] >= -1 && b[1] >= -1 && b[0] + b[2] <= COLW + 1 && b[1] + b[3] <= h + 1;
            i32 below = h - b[1] - b[3];
            ck(inside, kindName(k), h, (u8*)"inside", &b[0]);
            if (k == 2)
                {
                ck(drawn && b[1] <= 5, kindName(k), h, (u8*)"top", &b[0]);
                }
            else
                {
                ck(drawn && b[1] - below <= 1 && below - b[1] <= 1, kindName(k), h, (u8*)"centred", &b[0]);
                }
            }
        }
    }

// ---- the larger views -----------------------------------------------------------------------
i32 NVIEWS = 10;
i32 VIEWW = 130; // four across stay within the controls' columns (the web window's edge is beyond)
i32 VIEWH = 90;

class Rows : Object<UXTableDataSource>
    {
    void init(void)
        {
        }
    i32 numberOfRows(UXTableView* t)
        {
        return 3;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        return (u8*)"Row";
        }
    }

class Tree : Object<UXOutlineDataSource>
    {
    Array* kids;
    void init(void)
        {
        kids = new Array();
        for (i32 i = 0; i < 3; i = i + 1)
            {
            kids.add(new Object());
            }
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        return item == (Object*)0 ? 3 : 0;
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        return (Object*)kids.get((u32)i);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        {
        return false;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        {
        return (u8*)"Item";
        }
    }

Rows* gRows;   // a table holds its source weakly: these keep them
Tree* gTree;

u8* viewName(i32 k)
    {
    if (k == 0) { return (u8*)"textview"; }
    if (k == 1) { return (u8*)"scrollview"; }
    if (k == 2) { return (u8*)"tabview"; }
    if (k == 3) { return (u8*)"splitview"; }
    if (k == 4) { return (u8*)"groupbox"; }
    if (k == 5) { return (u8*)"combobox"; }
    if (k == 6) { return (u8*)"datepicker"; }
    if (k == 7) { return (u8*)"table"; }
    if (k == 8) { return (u8*)"outline"; }
    return (u8*)"collection";
    }
// a combo box and a date picker are one row tall, like a popup; the rest take the whole cell
i32 viewHeight(i32 k)
    {
    if (k == 5 || k == 6)
        {
        return UXMetrics.stdHeightFor((i32)UXKindPopup, (i32)UX_FORM_DESKTOP);
        }
    return VIEWH;
    }
// whether view k has an edge that should reach its frame: a text view, a group box, a table and an
// outline do; a scroll view, a tab view's pane, a split view's panes and a collection view are
// clear, as their content (here none) draws itself
bool viewFills(i32 k)
    {
    return k == 0 || k == 4 || k == 7 || k == 8;
    }
i32 viewX(i32 k)
    {
    return LEFT + (k % 4) * (VIEWW + 10);
    }
i32 viewY(i32 k)
    {
    return TOP + (k / 4) * (VIEWH + 10);
    }

UXView* makeView(i32 k)
    {
    if (k == 0)
        {
        UXTextView* tv = new UXTextView();
        tv.setText(String.withCString((u8*)"Hamburg"));
        return tv;
        }
    if (k == 1)
        {
        UXScrollView* sv = new UXScrollView();
        sv.setDocumentHeight(300);
        return sv;
        }
    if (k == 2)
        {
        UXTabView* tb = new UXTabView();
        tb.addTab((u8*)"One", new UXView());
        tb.addTab((u8*)"Two", new UXView());
        return tb;
        }
    if (k == 3)
        {
        UXSplitView* sp = new UXSplitView();
        sp.setDividerPos((i16)60);
        return sp;
        }
    if (k == 4)
        {
        UXGroupBox* gb = new UXGroupBox();
        gb.setTitle((u8*)"Group");
        return gb;
        }
    if (k == 5)
        {
        UXComboBox* cb = new UXComboBox();
        cb.addItem((u8*)"Hamburg");
        cb.setText((u8*)"Hamburg");
        return cb;
        }
    if (k == 6)
        {
        UXDatePicker* dp = new UXDatePicker();
        dp.setDate(UXDate.make(2026, 10, 20));
        return dp;
        }
    if (k == 7)
        {
        UXTableView* t = new UXTableView();
        t.addColumn((u8*)"Name", (i16)120);
        gRows = new Rows();
        t.setDataSource(gRows);
        return t;
        }
    if (k == 8)
        {
        UXOutlineView* o = new UXOutlineView();
        o.addColumn((u8*)"Name", (i16)120);
        gTree = new Tree();
        o.setOutlineSource(gTree);
        return o;
        }
    UXCollectionView* cv = new UXCollectionView();
    cv.setItemSize((i16)40, (i16)30);
    cv.addItem((Object*)cv, (u8*)"A");
    cv.addItem((Object*)cv, (u8*)"B");
    return cv;
    }

void buildViews(void)
    {
    while (gBack.subviews.count() > 0)
        {
        ((UXView* ?)gBack.subviews.get((u16)0)).removeFromSuperview();
        }
    for (i32 k = 0; k < NVIEWS; k = k + 1)
        {
        UXView* v = makeView(k);
        gBack.addSubview(v, UXGeom.make((i16)viewX(k), (i16)viewY(k), (i16)VIEWW, (i16)viewHeight(k)));
        if (k == 7 || k == 8)
            {
            ((UXTableView* ?)v).reloadData(); // the rows, once it is in the window
            }
        }
    gWin.displayAll();
#if SNAP_GTK
    ux_gtk_wait_allocated(gWin.handle);
#endif
    gWin.displayAll();
    }

void auditViews(void)
    {
    UXImage* all = gWin.snapshot((UXRect*)0);
    if (all == (UXImage*)0)
        {
        Stdio.printf("FAIL: the window did not snapshot\n");
        return;
        }
#if !SNAP_WEB
    u8* save = getenv((u8*)"UX_AUDIT_VIEWS_PNG");
    if (save != (u8*)0)
        {
        UXFileIO.write(save, UXPngEncode.encode(all));
        }
#endif
    i32 b[4];
    for (i32 k = 0; k < NVIEWS; k = k + 1)
        {
        i32 h = viewHeight(k);
        inkBox(all, viewX(k), viewY(k), VIEWW, h, 4, &b[0]);
        bool drawn = b[2] > 0;
        // a clear view may draw nothing at all (GTK's scroller shows only under the pointer)
        bool inside = (drawn || !viewFills(k)) && (!drawn || (b[0] >= -1 && b[1] >= -1 && b[0] + b[2] <= VIEWW + 1 && b[1] + b[3] <= h + 1));
        ck(inside, viewName(k), h, (u8*)"inside", &b[0]);
        if (h < VIEWH)
            {
            i32 below = h - b[1] - b[3];
            ck(drawn && b[1] - below <= 1 && below - b[1] <= 1, viewName(k), h, (u8*)"centred", &b[0]);
            }
        else if (viewFills(k))
            {
            ck(drawn && b[0] <= 1 && b[1] <= 1 && b[0] + b[2] >= VIEWW - 1 && b[1] + b[3] >= h - 1,
               viewName(k), h, (u8*)"fills", &b[0]);
            }
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        build(40, 40);
        audit();
        buildViews();
        auditViews();
        // the runner gives the verdict from the FAIL keys
        Stdio.printf("PASS: audit ran, %d checks failed\n", gFails);
        app.stop();
        return 0;
        }
    }

void main(void)
    {
    gFails = 0;
#if SNAP_GEM
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("FAIL: no gemd\n");
        return;
        }
    UXGemDriver* d = new UXGemDriver();
#endif
#if SNAP_APPKIT
    UXAppKitDriver* d = new UXAppKitDriver();
    d.setInteractive(true);
#endif
#if SNAP_WIN32
    UXWin32Driver* d = new UXWin32Driver();
#endif
#if SNAP_GTK
    UXGtkDriver* d = new UXGtkDriver();
#endif
#if SNAP_WEB
    UXWebDriver* d = new UXWebDriver();
#endif
    gDriver = d;
    UXApplication* app = new UXApplication();
#if SNAP_APPKIT
    d.attachApp(app);
#else
    app.setDriver((UXViewDriver*)d);
#endif
    gApp = app;
    app.setDelegate(new Delegate());
    app.run();
    }
