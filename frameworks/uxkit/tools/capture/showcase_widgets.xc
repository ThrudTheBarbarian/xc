// showcase_widgets.xc — ONE widget, staged for its portrait (the capture
// pipeline's shared scene builder; tools/capture/capture.sh).  Neutral: the
// same builder poses the widget on every backend, so the docs' appearance
// tabs compare like with like.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXStepper.xc"
#import "UXProgressBar.xc"
#import "UXProgress.xc"
#import "UXSegmentedControl.xc"
#import "UXPopUpButton.xc"
#import "UXGeometry.xc"
#import "UXMetrics.xc"
#import "UXGroupBox.xc"
#import "UXBreadcrumb.xc"
#import "UXComboBox.xc"
#import "UXDatePicker.xc"
#import "UXCollectionView.xc"
#import "UXTableView.xc"
#import "UXNavigationController.xc"
#import "UXOutlineView.xc"
#import "UXScrollView.xc"
#import "UXSplitView.xc"
#import "UXToolbar.xc"
#import "UXTabView.xc"
#import "UXColorPanel.xc"

// The sheet's paper: every cell fills white, so the portraits share one
// ground on every backend (GEM's window content is otherwise black, and
// black-ink labels vanish into it).
class SheetCell : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        }
    }

    // The swatch half of the colour-panel portrait: a view that fills itself with
    // whatever its UXColorPanel currently composes to.  The panel is a MODEL, so
    // this is the smallest honest way to show it — the sliders beside it are real
    // UXSliders on the panel's three components, and the swatch is what color()
    // returns.
    class SWSwatch : UXView
    {
    UXColorPanel* panel;
    void init(void)
        {
        super.init();
        panel = new UXColorPanel();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXColor* c = panel.color();
        UXRect b = self.bounds();
        g.fillRectRGB(b, (i32)0, (i32)0, (i32)0); // 1px frame
        g.fillRectRGB(UXGeom.make((i16)((i32)b.x + (i32)1), (i16)((i32)b.y + (i32)1),
                                  (i16)((i32)b.w - (i32)2), (i16)((i32)b.h - (i32)2)),
                      c.r, c.g, c.b);
        }
    }

    bool
    swEq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

// The standard frame for a kind, vertically centred on the 220x60 stage —
// so every portrait shows the REALM'S OWN standard size (UXMetrics), and
// the sheets regress the standards table on every platform.
UXRect stage(i32 kind, i32 w)
    {
    i32 ff = gDriver.formFactorClass();
    i32 useW = w > (i32)0 ? w : UXMetrics.minWidthFor(kind, ff);
    i32 h = UXMetrics.stdHeightFor(kind, ff);
    return UXGeom.make((i16)(((i32)220 - useW) / (i32)2), (i16)(((i32)60 - h) / (i32)2),
                       (i16)useW, (i16)h);
    }

// Build `name` into `content`, posed for a 220x60 stage.  1 = known widget.
i32 buildWidget(u8* name, UXView* content)
    {
    if (swEq(name, (u8*)"button"))
        {
        // two states: enabled and disabled
        i32 ff = gDriver.formFactorClass();
        i16 bh = (i16)UXMetrics.stdHeightFor((i32)UXKindButton, ff);
        i16 by = (i16)(((i32)60 - (i32)bh) / (i32)2);
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Enabled");
        content.addSubview(b, UXGeom.make(10, by, 95, bh));
        UXButton* b2 = new UXButton();
        b2.setTitle((u8*)"Disabled");
        content.addSubview(b2, UXGeom.make(115, by, 95, bh));
        b2.setEnabled(false);
        }
    else if (swEq(name, (u8*)"checkbox"))
        {
        // two states: checked and unchecked
        i32 ff = gDriver.formFactorClass();
        i16 ch = (i16)UXMetrics.stdHeightFor((i32)UXKindCheckbox, ff);
        i16 cy = (i16)(((i32)60 - (i32)ch) / (i32)2);
        UXCheckbox* c = new UXCheckbox();
        c.setTitle((u8*)"On");
        c.setChecked(true);
        content.addSubview(c, UXGeom.make(15, cy, 95, ch));
        UXCheckbox* c2 = new UXCheckbox();
        c2.setTitle((u8*)"Off");
        content.addSubview(c2, UXGeom.make(120, cy, 95, ch));
        }
    else if (swEq(name, (u8*)"radio"))
        {
        // a REAL group of two: selected and unselected
        i32 ff = gDriver.formFactorClass();
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindRadio, ff);
        i16 ry = (i16)(((i32)60 - (i32)rh) / (i32)2);
        UXRadioGroup* grp = new UXRadioGroup();
        UXRadioButton* r = new UXRadioButton();
        r.setTitle((u8*)"Email");
        UXRadioButton* r2 = new UXRadioButton();
        r2.setTitle((u8*)"SMS");
        grp.add(r);
        grp.add(r2);
        content.addSubview(r, UXGeom.make(15, ry, 95, rh));
        content.addSubview(r2, UXGeom.make(120, ry, 90, rh));
        grp.select(r);
        }
    else if (swEq(name, (u8*)"label"))
        {
        UXLabel* l = new UXLabel();
        l.setTitle((u8*)"A label");
        content.addSubview(l, stage((i32)UXKindLabel, (i32)100));
        }
    else if (swEq(name, (u8*)"field"))
        {
        // two states: text, and secure (the masked dots)
        i32 ff = gDriver.formFactorClass();
        i16 fh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, ff);
        i16 fy = (i16)(((i32)60 - (i32)fh) / (i32)2);
        UXTextField* f = new UXTextField();
        f.setText((u8*)"hello");
        content.addSubview(f, UXGeom.make(10, fy, 95, fh));
        UXTextField* f2 = new UXTextField();
        f2.setSecure(true);
        f2.setText((u8*)"secret");
        content.addSubview(f2, UXGeom.make(115, fy, 95, fh));
        }
    else if (swEq(name, (u8*)"slider"))
        {
        UXSlider* s = new UXSlider();
        s.setRange(0, 100);
        s.setValue(60);
        content.addSubview(s, stage((i32)UXKindSlider, (i32)160));
        }
    else if (swEq(name, (u8*)"stepper"))
        {
        UXStepper* s = new UXStepper();
        s.setRange(0, 10);
        s.setValue(3);
        content.addSubview(s, stage((i32)UXKindStepper, (i32)0));
        }
    else if (swEq(name, (u8*)"progress"))
        {
        UXProgress* p = UXProgress.make(100);
        p.setCompleted(60);
        UXProgressBar* pb = new UXProgressBar();
        pb.setProgress(p);
        content.addSubview(pb, stage((i32)UXKindProgress, (i32)180));
        }
    else if (swEq(name, (u8*)"segmented"))
        {
        UXSegmentedControl* g = new UXSegmentedControl();
        g.addSegment((u8*)"Day", 1);
        g.addSegment((u8*)"Week", 2);
        g.addSegment((u8*)"Month", 3);
        g.selectSegment(1);
        content.addSubview(g, stage((i32)UXKindSegmented, (i32)180));
        }
    else if (swEq(name, (u8*)"popup"))
        {
        UXPopUpButton* p = new UXPopUpButton();
        p.addItem((u8*)"Left", 1);
        p.addItem((u8*)"Centre", 2);
        p.addItem((u8*)"Right", 3);
        content.addSubview(p, stage((i32)UXKindPopup, (i32)120));
        }
    else
        {
        return (i32)0;
        }
    return (i32)1;
    }

// ── the contact sheet ───────────────────────────────────────────────────────
// ALL widgets in one window, on a fixed grid: 2 columns x 5 rows of
// 220x60 cells, in THE ORDER BELOW.  capture.sh derives every crop
// rectangle from exactly this table (cell = index -> col*220, row*60), so
// one screengrab per platform becomes ten portraits.  Change the order or
// the cell size HERE and THERE together or not at all.
u8* gSheetNames[10];
void sheetInit(void)
    {
    gSheetNames[0] = (u8*)"button";
    gSheetNames[1] = (u8*)"checkbox";
    gSheetNames[2] = (u8*)"radio";
    gSheetNames[3] = (u8*)"label";
    gSheetNames[4] = (u8*)"field";
    gSheetNames[5] = (u8*)"slider";
    gSheetNames[6] = (u8*)"stepper";
    gSheetNames[7] = (u8*)"progress";
    gSheetNames[8] = (u8*)"segmented";
    gSheetNames[9] = (u8*)"popup";
    }
void buildSheet(UXView* content)
    {
    sheetInit();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        i32 col = i % (i32)2;
        i32 row = i / (i32)2;
        UXView* cell = (UXView*)new SheetCell();
        content.addSubview(cell, UXGeom.make((i16)(col * (i32)220), (i16)(row * (i32)60), 220, 60));
        buildWidget(gSheetNames[i], cell);
        }
    }

// ── SHEET 2: the container/navigation widgets ───────────────────────────────
// 2 columns x 5 rows of 220x90 cells (they need more room than the controls).
// Same contract as sheet 1: capture.sh derives every crop from THIS grid.

// The table's rows (the source is held WEAKLY — these must be globals).
class SW2Table : Object<UXTableDataSource>
    {
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)3;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (col == (i32)0)
            {
            if (row == (i32)0)
                {
                return (u8*)"notes.txt";
                }
            if (row == (i32)1)
                {
                return (u8*)"sketch.png";
                }
            return (u8*)"todo.md";
            }
        if (row == (i32)0)
            {
            return (u8*)"2 KB";
            }
        if (row == (i32)1)
            {
            return (u8*)"48 KB";
            }
        return (u8*)"1 KB";
        }
    } SW2Table* gSW2Table;

// A tiny two-level tree for the outline.
class SW2Node : Object
    {
    u8* nm;
    Array<SW2Node>* kids;
    void init(void)
        {
        nm = (u8*)"";
        kids = new Array();
        }
    static SW2Node* make(u8* n)
        {
        SW2Node* x = new SW2Node();
        x.nm = n;
        return x;
        }
    } SW2Node* gSW2Root;
class SW2Outline : Object<UXOutlineDataSource>
    {
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        SW2Node* n = item == (Object*)0 ? gSW2Root : (SW2Node* ?)item;
        return n != (SW2Node*)0 ? (i32)n.kids.count() : (i32)0;
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        SW2Node* n = item == (Object*)0 ? gSW2Root : (SW2Node* ?)item;
        return (Object*)n.kids.get((u16)i);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        {
        SW2Node* n = (SW2Node* ?)item;
        return n != (SW2Node*)0 && n.kids.count() > (u16)0;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        {
        SW2Node* n = (SW2Node* ?)item;
        return n != (SW2Node*)0 ? n.nm : (u8*)"";
        }
    } SW2Outline* gSW2Outline;

// The scroll view's document: stripes, so the offset is visible.
class SW2Stripes : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        for (i32 y = (i32)0; y < (i32)b.h; y = y + (i32)24)
            {
            g.fillRect(UXGeom.make((i16)0, (i16)y, b.w, (i16)12), (i32)8);
            }
        }
    }

    i32
    buildWidget2(u8* name, UXView* content)
    {
    if (swEq(name, (u8*)"breadcrumb"))
        {
        UXBreadcrumb* bc = new UXBreadcrumb();
        bc.addSegment((u8*)"Home", 1);
        bc.addSegment((u8*)"Projects", 2);
        bc.addSegment((u8*)"uxkit", 3);
        content.addSubview(bc, UXGeom.make(10, 35, 200, 20));
        }
    else if (swEq(name, (u8*)"combobox"))
        {
        i32 ff = gDriver.formFactorClass();
        i16 fh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, ff);
        UXComboBox* cb = new UXComboBox();
        cb.addItem((u8*)"Helvetica");
        cb.addItem((u8*)"Hobo");
        cb.addItem((u8*)"Times");
        cb.setText((u8*)"Helv");
        content.addSubview(cb, UXGeom.make(35, (i16)(((i32)90 - (i32)fh) / (i32)2), 150, fh));
        }
    else if (swEq(name, (u8*)"datepicker"))
        {
        i32 ff = gDriver.formFactorClass();
        i16 fh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, ff);
        UXDatePicker* dp = new UXDatePicker();
        dp.setDate(UXDate.make((i32)2026, (i32)8, (i32)27));
        content.addSubview(dp, UXGeom.make(45, (i16)(((i32)90 - (i32)fh) / (i32)2), 130, fh));
        }
    else if (swEq(name, (u8*)"groupbox"))
        {
        // realm-aware rows: a device checkbox is a 32pt switch
        i32 ff = gDriver.formFactorClass();
        i16 ch = (i16)UXMetrics.stdHeightFor((i32)UXKindCheckbox, ff);
        UXGroupBox* gb = new UXGroupBox();
        gb.setTitle((u8*)"Options");
        content.addSubview(gb, UXGeom.make(20, 4, 180, 82));
        UXCheckbox* c1 = new UXCheckbox();
        c1.setTitle((u8*)"Wrap lines");
        c1.setChecked(true);
        content.addSubview(c1, UXGeom.make(36, 22, 150, ch));
        UXCheckbox* c2 = new UXCheckbox();
        c2.setTitle((u8*)"Show ruler");
        content.addSubview(c2, UXGeom.make(36, (i16)((i32)24 + (i32)ch + (i32)2), 150, ch));
        }
    else if (swEq(name, (u8*)"collection"))
        {
        UXCollectionView* cv = new UXCollectionView();
        cv.setItemSize((i16)36, (i16)36);
        cv.setSpacing((i16)10, (i16)10);
        cv.setInset((i16)6);
        cv.addItem((Object*)0, (u8*)"a.png");
        cv.addItem((Object*)0, (u8*)"b.png");
        cv.addItem((Object*)0, (u8*)"c.png");
        cv.addItem((Object*)0, (u8*)"d.png");
        cv.selectItem((i32)1);
        content.addSubview(cv, UXGeom.make(10, 2, 200, 86));
        }
    else if (swEq(name, (u8*)"table"))
        {
        UXTableView* tv = new UXTableView();
        tv.addColumn((u8*)"Name", (i16)120);
        tv.addColumn((u8*)"Size", (i16)70);
        tv.setRowHeight((i16)18);
        gSW2Table = new SW2Table();
        tv.setDataSource((UXTableDataSource*)gSW2Table);
        content.addSubview(tv, UXGeom.make(10, 6, 200, 78));
        tv.reloadData();
        tv.selectRow((i32)1);
        }
    else if (swEq(name, (u8*)"outline"))
        {
        gSW2Root = SW2Node.make((u8*)"/");
        SW2Node* proj = SW2Node.make((u8*)"Projects");
        proj.kids.add(SW2Node.make((u8*)"uxkit"));
        gSW2Root.kids.add(proj);
        gSW2Root.kids.add(SW2Node.make((u8*)"Docs"));
        UXOutlineView* ov = new UXOutlineView();
        ov.addColumn((u8*)"Name", (i16)180);
        ov.setRowHeight((i16)18);
        gSW2Outline = new SW2Outline();
        ov.setOutlineSource((UXOutlineDataSource*)gSW2Outline);
        ov.setExpanded((Object*)proj, true);
        content.addSubview(ov, UXGeom.make(10, 5, 200, 80));
        ov.reloadData();
        }
    else if (swEq(name, (u8*)"split"))
        {
        UXSplitView* sp = new UXSplitView();
        sp.setDividerPos((i16)70);
        content.addSubview(sp, UXGeom.make(10, 8, 200, 74));
        UXLabel* l0 = new UXLabel();
        l0.setTitle((u8*)"Sidebar");
        sp.firstPane().addSubview(l0, UXGeom.make(8, 8, 60, 16));
        UXLabel* l1 = new UXLabel();
        l1.setTitle((u8*)"Detail");
        sp.secondPane().addSubview(l1, UXGeom.make(8, 8, 60, 16));
        }
    else if (swEq(name, (u8*)"scroll"))
        {
        UXScrollView* sv = new UXScrollView();
        content.addSubview(sv, UXGeom.make(10, 6, 200, 78));
        SW2Stripes* st = new SW2Stripes();
        sv.document().addSubview(st, UXGeom.make(0, 0, 186, 300));
        sv.setDocumentHeight((i32)300);
        sv.setLineHeight((i16)24);
        sv.scrollTo((i16)60);
        }
    else if (swEq(name, (u8*)"tabview"))
        {
        // the picker + the pane: a tab view COMPOSES a segmented control and
        // content views, so its portrait shows exactly that composition
        UXSegmentedControl* pk = new UXSegmentedControl();
        pk.addSegment((u8*)"General", 0);
        pk.addSegment((u8*)"Advanced", 1);
        pk.selectSegment(0);
        content.addSubview(pk, UXGeom.make(10, 4, 200, 26));
        UXGroupBox* pane = new UXGroupBox();
        pane.setTitle((u8*)"General");
        content.addSubview(pane, UXGeom.make(10, 30, 200, 56));
        UXLabel* pl = new UXLabel();
        pl.setTitle((u8*)"General settings");
        content.addSubview(pl, UXGeom.make(26, 52, 160, 16));
        UXTabView* tv = new UXTabView(); // the model itself, wired as the docs show
        tv.addTab((u8*)"General", (UXView*)pane);
        tv.selectTab((i32)0);
        }
    else if (swEq(name, (u8*)"nav"))
        {
        // the navigation stack, two forms deep: the bar reads back-to-Contacts
        // over the visible Alice form — forward is a push, the chevron pops
        UXNavigationController* nv = new UXNavigationController();
        content.addSubview(nv, UXGeom.make(10, 5, 200, 80));
        UXView* list = new UXView();
        UXView* detail = new UXView();
        nv.push((u8*)"Contacts", list);
        nv.push((u8*)"Alice", detail);
        UXLabel* dl = new UXLabel();
        dl.setTitle((u8*)"alice@example.com");
        detail.addSubview(dl, UXGeom.make(8, 12, 180, 16));
        nv.applyNav();
        }
    else if (swEq(name, (u8*)"toolbar"))
        {
        UXToolbar* tb = new UXToolbar();
        tb.addItem((u8*)"doc.new", (u8*)"New", 1, (i16)44);
        tb.addItem((u8*)"doc.open", (u8*)"Open", 2, (i16)44);
        tb.addSeparator();
        tb.addFlexibleSpace();
        tb.addItem((u8*)"search", (u8*)"Find", 9, (i16)44);
        content.addSubview(tb, UXGeom.make(10, 21, 200, 48)); // tall: icon-above-text
        }
    else if (swEq(name, (u8*)"colorpanel"))
        {
        // UXColorPanel is a MODEL, so the portrait is the model's two ends: the
        // swatch is color(), and the three sliders are its H/S/B components at
        // the values that compose it.  Everything here is a real UXKit widget.
        SWSwatch* sw = new SWSwatch();
        sw.panel.setColor(UXColor.rgb((i32)64, (i32)150, (i32)220));
        content.addSubview(sw, UXGeom.make(12, 16, 58, 58));

        i32 hsb[3];
        hsb[0] = sw.panel.hueValue();
        hsb[1] = sw.panel.saturationValue();
        hsb[2] = sw.panel.brightnessValue();
        i32 maxv[3];
        maxv[0] = (i32)359;
        maxv[1] = (i32)255;
        maxv[2] = (i32)255;
        for (i32 k = (i32)0; k < (i32)3; k = k + (i32)1)
            {
            UXSlider* s = new UXSlider();
            s.setRange((i32)0, maxv[k]);
            s.setValue(hsb[k]);
            content.addSubview(s, UXGeom.make(84, (i16)((i32)18 + k * (i32)22), 122, 16));
            }
        }
    else
        {
        return (i32)0;
        }
    return (i32)1;
    }

// 13 cells in 2 columns = 7 rows, so the sheet window is 440x630.  Every
// showcase_*2.xc opens it at that size; they must agree or a backend crops.
#define SHEET2_N 13
u8* gSheet2Names[SHEET2_N];
void sheet2Init(void)
    {
    gSheet2Names[0] = (u8*)"breadcrumb";
    gSheet2Names[1] = (u8*)"combobox";
    gSheet2Names[2] = (u8*)"datepicker";
    gSheet2Names[3] = (u8*)"groupbox";
    gSheet2Names[4] = (u8*)"collection";
    gSheet2Names[5] = (u8*)"table";
    gSheet2Names[6] = (u8*)"outline";
    gSheet2Names[7] = (u8*)"split";
    gSheet2Names[8] = (u8*)"scroll";
    gSheet2Names[9] = (u8*)"toolbar";
    gSheet2Names[10] = (u8*)"tabview";
    gSheet2Names[11] = (u8*)"nav";
    gSheet2Names[12] = (u8*)"colorpanel";
    }
void buildSheet2(UXView* content)
    {
    sheet2Init();
    for (i32 i = (i32)0; i < (i32)SHEET2_N; i = i + (i32)1)
        {
        i32 col = i % (i32)2;
        i32 row = i / (i32)2;
        UXView* cell = (UXView*)new SheetCell();
        content.addSubview(cell, UXGeom.make((i16)(col * (i32)220), (i16)(row * (i32)90), 220, 90));
        buildWidget2(gSheet2Names[i], cell);
        }
    }
