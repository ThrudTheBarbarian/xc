// RKMainBuilder.xc — THE SEAM.  Builds the main window's view tree in code.
//
// This is the file that gets swapped.  A future RKMainNib.xc will call
// UXNib.load on a nib Rocks authored, and everything else in the app stays
// exactly as it is — because this builder deliberately does not assign
// outlets or actions by hand.  It drives the same two UXDesignable methods
// the nib loader drives:
//
//     c.setOutlet("canvas", view)          <- what a nib's outlet connection does
//     c.wireAction("onNewForm", control)   <- what a nib's action connection does
//
// Written the obvious way — `c.canvas = view;` — the two paths would only
// LOOK alike, and the nib path would be the first thing to discover it had
// never been exercised.  Going through the protocol means the code path is a
// hand-written nib, and every wiring name here is one a nib will later carry
// as data.
//
// Layout is Interface Builder's: outline | canvas | inspector and library, with
// a toolbar above and a status line below.  The panes are real UXKit widgets,
// which is the point of writing Rocks in XC: the canvas hosts the same widget
// objects the edited app will run, so WYSIWYG is structural rather than a
// second renderer kept in sync by hand.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSplitView.xc"
#import "UXOutlineView.xc"
#import "UXTableView.xc"
#import "UXScrollView.xc"
#import "UXToolbar.xc"
#import "UXSegmentedControl.xc"
#import "UXMetrics.xc"
#import "UXGeometry.xc"
#import "RKMainController.xc"
#import "RKInspector.xc"
#import "UXMenu.xc"
#import "UXApplication.xc"

class RKMainBuilder : Object
    {
    // One labelled row of the inspector: a label then a field.
    static UXTextField* row(UXView* into, u8* label, i16 x, i16 y, i16 lw, i16 fw, i16 rh)
        {
        UXLabel* l = new UXLabel();
        l.setTitle(label);
        into.addSubview(l, UXGeom.make(x, y, lw, rh));
        UXTextField* f = new UXTextField();
        into.addSubview(f, UXGeom.make((i16)((i32)x + (i32)lw), y, fw, rh));
        return f;
        }

    // Build into `content` and wire `c`.  Returns false if any wiring name was
    // rejected — which is a BUILD error, not a runtime one: a name that the
    // controller does not know is a typo the nib path would hit too.
    //
    // Interface Builder's arrangement, so a designer who knows it finds things where they expect:
    //
    //   toolbar
    //   outline | canvas                         | Identity Attributes Size Connections
    //           |                                | (the selected thing's pane)
    //           |                                |-------------------------------------
    //           | View as: Desktop Tablet Phone  | Library: search, then what can be added
    //   status
    static bool buildInto(UXView* content, RKMainController* c, i16 w, i16 h)
        {
        bool ok = true;
        i16 gut = (i16)UXMetrics.gutter();
        i16 tbH = (i16)48; // icon-above-text bar
        i16 stH = (i16)UXMetrics.stdHeightFor((i32)UXKindLabel, (i32)UX_FORM_DESKTOP);
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);

        // ---- the toolbar ---------------------------------------------------
        UXToolbar* tb = new UXToolbar();
        tb.addItem((u8*)"doc.new", (u8*)"New", (i32)RKTB_NEW, (i16)44);
        tb.addItem((u8*)"trash", (u8*)"Delete", (i32)RKTB_DELETE, (i16)44);
        content.addSubview(tb, UXGeom.make((i16)0, (i16)0, w, tbH));

        // ---- outline | (centre | right) --------------------------------------
        i16 bodyY = (i16)((i32)tbH + (i32)gut);
        i16 bodyH = (i16)((i32)h - (i32)bodyY - (i32)stH - (i32)gut);

        // The side panes' widths: the desktop's where the window has room, a share of it where it
        // has not (a phone held upright), so the canvas always keeps the middle.
        i32 olW = (i32)200;
        i32 inW = (i32)280;
        if ((i32)w < olW + inW + (i32)300)
            {
            olW = (i32)w / (i32)4;
            inW = (i32)w * (i32)3 / (i32)10;
            }
        i32 cvW = (i32)w - olW - inW;

        UXSplitView* outer = new UXSplitView(); // outline | rest
        outer.setDividerPos((i16)olW);
        content.addSubview(outer, UXGeom.make((i16)0, bodyY, w, bodyH));

        UXOutlineView* outline = new UXOutlineView();
        outline.addColumn((u8*)"", (i16)(olW - (i32)24)); // one column, the pane's width
        outer.firstPane().addSubview(outline, UXGeom.make((i16)0, (i16)0, (i16)olW, bodyH));

        UXSplitView* inner = new UXSplitView(); // centre | right
        inner.setDividerPos((i16)cvW);
        outer.secondPane().addSubview(inner,
                                      UXGeom.make((i16)0, (i16)0, (i16)((i32)w - olW), bodyH));

        // ---- the centre: the canvas, and the device bar under it ----------------
        i16 dbH = (i16)((i32)rh + (i32)8);
        i16 cvH = (i16)((i32)bodyH - (i32)dbH);
        UXView* canvas = new UXView();
        inner.firstPane().addSubview(canvas, UXGeom.make((i16)0, (i16)0, (i16)cvW, cvH));
        UXView* bar = new UXView();
        inner.firstPane().addSubview(bar, UXGeom.make((i16)0, cvH, (i16)cvW, dbH));
        UXLabel* viewAs = new UXLabel();
        viewAs.setTitle((u8*)"View as:");
        bar.addSubview(viewAs, UXGeom.make((i16)8, (i16)4, (i16)60, rh));
        UXSegmentedControl* device = new UXSegmentedControl();
        device.addSegment((u8*)"Desktop", (i32)UXR_V_DESKTOP);
        device.addSegment((u8*)"Tablet", (i32)UXR_V_TABLET);
        device.addSegment((u8*)"Phone", (i32)UXR_V_PHONE);
        device.applyNativeSelection((i32)0);
        bar.addSubview(device, UXGeom.make((i16)70, (i16)4, (i16)210, rh));
        UXButton* rotate = new UXButton();
        rotate.setTitle((u8*)"Rotate");
        bar.addSubview(rotate, UXGeom.make((i16)290, (i16)4, (i16)70, rh));
        UXButton* newLayout = new UXButton();
        newLayout.setTitle((u8*)"New Layout");
        bar.addSubview(newLayout, UXGeom.make((i16)366, (i16)4, (i16)100, rh));

        // ---- the right: the inspector over the library -------------------------
        UXView* right = inner.secondPane();
        i16 insH = (i16)((i32)bodyH * (i32)3 / (i32)5);
        UXView* inspector = new UXView();
        right.addSubview(inspector, UXGeom.make((i16)0, (i16)0, (i16)inW, insH));
        UXLabel* tv = new UXLabel(); // what is selected: "button (UXButton)"
        tv.setTitle((u8*)"—");
        inspector.addSubview(tv, UXGeom.make((i16)8, (i16)4, (i16)((i32)inW - (i32)16), rh));
        UXSegmentedControl* tabs = new UXSegmentedControl();
        tabs.addSegment((u8*)"Identity", (i32)0);
        tabs.addSegment((u8*)"Attributes", (i32)1);
        tabs.addSegment((u8*)"Size", (i32)2);
        tabs.addSegment((u8*)"Connections", (i32)3);
        tabs.applyNativeSelection((i32)1);
        i16 tabY = (i16)((i32)rh + (i32)8);
        inspector.addSubview(tabs, UXGeom.make((i16)4, tabY, (i16)((i32)inW - (i32)8), rh));
        i16 paneY = (i16)((i32)tabY + (i32)rh + (i32)6);
        UXRect paneR = UXGeom.make((i16)0, paneY, (i16)inW, (i16)((i32)insH - (i32)paneY));
        for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
            {
            UXView* p = new UXView();
            inspector.addSubview(p, paneR);
            p.setHidden(i != (i32)1);
            c.tabPanes.add(p);
            }
        // Only the CHROME is built here.  The rows depend on what is selected, so the pane
        // controllers generate them; see RKInspector on why this is where the nib-client rule bends.
        c.identityCtl.attach((UXView* ?)c.tabPanes.get((u32)0));
        c.inspectorCtl.attach((UXView* ?)c.tabPanes.get((u32)1), tv);
        c.sizeCtl.attach((UXView* ?)c.tabPanes.get((u32)2), (UXLabel*)0);
        UXLabel* cl = new UXLabel();
        cl.setTitle((u8*)"Outlets and actions: control-drag between objects.");
        ((UXView* ?)c.tabPanes.get((u32)3)).addSubview(cl, UXGeom.make((i16)8, (i16)8, (i16)((i32)inW - (i32)16), rh));

        i16 libY = (i16)((i32)insH + (i32)gut);
        UXLabel* ll = new UXLabel();
        ll.setTitle((u8*)"Library");
        right.addSubview(ll, UXGeom.make((i16)8, libY, (i16)80, rh));
        UXTextField* search = new UXTextField();
        search.setPlaceholder((u8*)"Filter");
        right.addSubview(search, UXGeom.make((i16)8, (i16)((i32)libY + (i32)rh + (i32)4), (i16)((i32)inW - (i32)16), rh));
        i16 tY = (i16)((i32)libY + (i32)2 * (i32)rh + (i32)10);
        UXTableView* lib = new UXTableView();
        lib.addColumn((u8*)"Object", (i16)110);
        lib.addColumn((u8*)"", (i16)((i32)inW - (i32)130));
        lib.setDataSource((UXTableDataSource*)c.library);
        right.addSubview(lib, UXGeom.make((i16)4, tY, (i16)((i32)inW - (i32)8), (i16)((i32)bodyH - (i32)tY - (i32)4)));

        // ---- the status line -----------------------------------------------
        UXLabel* status = new UXLabel();
        status.setTitle((u8*)"Ready");
        content.addSubview(status,
                           UXGeom.make(gut, (i16)((i32)h - (i32)stH), (i16)((i32)w - (i32)2 * (i32)gut), stH));

        // The outline and the library report selection through the table delegate they inherit;
        // that one line is what makes the panes a single editor.
        outline.setDelegate((UXTableDelegate*)c);
        lib.setDelegate((UXTableDelegate*)c);

        // ---- wiring, through the protocol a nib would use ------------------
        ok = c.setOutlet((u8*)"formOutline", (Object*)outline) && ok;
        ok = c.setOutlet((u8*)"canvas", (Object*)canvas) && ok;
        ok = c.setOutlet((u8*)"inspector", (Object*)inspector) && ok;
        ok = c.setOutlet((u8*)"statusLabel", (Object*)status) && ok;
        ok = c.setOutlet((u8*)"deviceBar", (Object*)device) && ok;
        ok = c.setOutlet((u8*)"inspectorTabs", (Object*)tabs) && ok;
        ok = c.setOutlet((u8*)"libraryTable", (Object*)lib) && ok;
        ok = c.setOutlet((u8*)"librarySearch", (Object*)search) && ok;
        ok = c.wireAction((u8*)"onToolbar", (UXControl*)tb) && ok;
        ok = c.wireAction((u8*)"onDeviceBar", (UXControl*)device) && ok;
        ok = c.wireAction((u8*)"onRotate", (UXControl*)rotate) && ok;
        ok = c.wireAction((u8*)"onNewLayout", (UXControl*)newLayout) && ok;
        ok = c.wireAction((u8*)"onInspectorTab", (UXControl*)tabs) && ok;
        search.setOnChange(&c.onLibrarySearch);
        c.toolbar = tb;
        return ok;
        }

    // ---- the menu bar --------------------------------------------------------
    // Menus are part of the interface, so they are built HERE rather than in
    // main: a nib carries its main menu, and when this file is replaced by one
    // that loads a nib, the menu should come across with the rest of the
    // window instead of being left behind in the entry point.
    //
    // Snap and Guides are ticked at construction, before install, because the
    // bar is handed to the platform as data -- flipping the tick afterwards
    // would work on some backends and be a no-op on any that build the bar
    // once and never revisit it.
    static void buildMenu(UXApplication* app, RKMainController* c)
        {
        UXMenuBar* bar = new UXMenuBar();

        UXMenu* file = bar.addMenu((u8*)"Rocks");
        file.addItem((u8*)"About Rocks", (callback void(UXMenuItem * s))0);

        UXMenu* doc = bar.addMenu((u8*)"File");
        doc.addItem((u8*)"Open...", &c.onOpenDocument).setShortcut((u8)'O', false);
        doc.addItem((u8*)"Save", &c.onSaveDocument).setShortcut((u8)'S', false);
        doc.addItem((u8*)"Save As...", &c.onSaveDocumentAs).setShortcut((u8)'S', true);

        UXMenu* edit = bar.addMenu((u8*)"Edit");
        edit.addItem((u8*)"Undo", &c.onUndo).setShortcut((u8)'Z', false);
        edit.addItem((u8*)"Redo", &c.onRedo).setShortcut((u8)'Z', true);
        edit.addSeparator();
        edit.addItem((u8*)"Delete", &c.onDeleteItem);

        UXMenu* view = bar.addMenu((u8*)"View");
        UXMenuItem* snap = view.addItem((u8*)"Snap to Guides", &c.onToggleSnap);
        UXMenuItem* guid = view.addItem((u8*)"Show Guides", &c.onToggleGuides);
        snap.checked = c.snapEnabled();
        guid.checked = c.guidesEnabled();

        c.menuBar = bar;
        c.viewMenu = (i32)3;  // ordinals into the bar, not names: setChecked
        c.snapItem = (i32)0;  // addresses items positionally, and these three
        c.guideItem = (i32)1; // numbers are the only place that mapping lives
        app.setMenuBar(bar);
        }
    }
