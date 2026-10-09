// RKMainBuilder.xc — THE SEAM.  Builds the main window's view tree in code.
//
// This is the file that gets swapped.  A future RKMainRsc.xc will call
// UXRsc.load on an rsc file Rocks authored, and everything else in the app stays
// exactly as it is — because this builder deliberately does not assign
// outlets or actions by hand.  It drives the same two UXDesignable methods
// the rsc loader drives:
//
//     c.setOutlet("canvas", view)          <- what an rsc file's outlet connection does
//     c.wireAction("onNewForm", control)   <- what an rsc file's action connection does
//
// Written the obvious way — `c.canvas = view;` — the two paths would only
// LOOK alike, and the rsc path would be the first thing to discover it had
// never been exercised.  Going through the protocol means the code path is a
// hand-written rsc, and every wiring name here is one an rsc file will later carry
// as data.
//
// Layout is Interface Builder's: outline | canvas | inspector and library, with
// a toolbar above and a status line at the foot of the outline.  The panes are real UXKit widgets,
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
#import "UXPopUpButton.xc"
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
    // controller does not know is a typo the rsc path would hit too.
    //
    // Interface Builder's arrangement, so a designer who knows it finds things where they expect:
    //
    //   toolbar
    //   outline | canvas                         | Identity Attributes Size Connections
    //           |                                | (the selected thing's pane)
    //           |                                |-------------------------------------
    //   status  | View as: Desktop Tablet Phone  | Library: search, then what can be added
    static bool buildInto(UXView* content, RKMainController* c, i16 w, i16 h)
        {
        bool ok = true;
        i16 gut = (i16)UXMetrics.gutter();
        // icon-above-text bar -- or none, where the toolbar is in the window's own chrome (AppKit)
        i16 tbH = UXWindow.toolbarInChrome() ? (i16)0 : (i16)48;
        i16 stH = (i16)UXMetrics.stdHeightFor((i32)UXKindLabel, (i32)UX_FORM_DESKTOP);
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);

        // ---- the toolbar ---------------------------------------------------
        UXToolbar* tb = new UXToolbar();
        tb.addItem((u8*)"doc.new", (u8*)"New", (i32)RKTB_NEW, (i16)44);
        // A flexible gap separates New (by the title) from Delete (the bin at the far end), so the
        // bin is not the thing sitting next to New.
        tb.addFlexibleSpace();
        tb.addItem((u8*)"trash", (u8*)"Delete", (i32)RKTB_DELETE, (i16)44);
        tb.setItemIcon((i32)RKTB_NEW, (u8*)"new");
        tb.setItemIcon((i32)RKTB_DELETE, (u8*)"delete");
        content.addSubview(tb, UXGeom.make((i16)0, (i16)0, w, tbH));
        // How each part follows the window when it is resized (springs and struts): the toolbar
        // stretches across, the outline keeps its width, the canvas takes what is left, and the
        // inspector column keeps its width on the right.
        tb.setAutoresizeMask((i32)UX_FLEX_WIDTH);

        // ---- outline | (centre | right) --------------------------------------
        i16 bodyY = (i16)((i32)tbH + (tbH > (i16)0 ? (i32)gut : (i32)0));
        i16 bodyH = (i16)((i32)h - (i32)bodyY); // to the window's foot: the status line is in the outline column

        // The side panes' widths: the desktop's where the window has room, a share of it where it
        // has not (a phone held upright), so the canvas always keeps the middle.
        i32 olW = (i32)200;
        i32 inW = (i32)330;
        if ((i32)w < olW + inW + (i32)300)
            {
            olW = (i32)w / (i32)4;
            inW = (i32)w * (i32)3 / (i32)10;
            }
        i32 cvW = (i32)w - olW - inW;

        UXSplitView* outer = new UXSplitView(); // outline | rest
        outer.setDividerPos((i16)olW);
        content.addSubview(outer, UXGeom.make((i16)0, bodyY, w, bodyH));
        outer.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));

        UXOutlineView* outline = new UXOutlineView();
        outline.addColumn((u8*)"", (i16)(olW - (i32)24)); // one column, the pane's width
        outer.firstPane().addSubview(outline, UXGeom.make((i16)0, (i16)0, (i16)olW, (i16)((i32)bodyH - (i32)stH - (i32)8)));
        outline.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));

        UXSplitView* inner = new UXSplitView(); // centre | right
        inner.setDividerPos((i16)cvW);
        outer.secondPane().addSubview(inner,
                                      UXGeom.make((i16)0, (i16)0, (i16)((i32)w - olW), bodyH));
        inner.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        inner.setHoldsLast(true); // the inspector keeps its width; the canvas grows

        // ---- the centre: the canvas, and the device bar under it ----------------
        i16 dbH = (i16)((i32)rh + (i32)8);
        i16 cvH = (i16)((i32)bodyH - (i32)dbH);
        UXView* canvas = new UXView();
        inner.firstPane().addSubview(canvas, UXGeom.make((i16)0, (i16)0, (i16)cvW, cvH));
        canvas.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        UXView* bar = new UXView();
        inner.firstPane().addSubview(bar, UXGeom.make((i16)0, cvH, (i16)cvW, dbH));
        bar.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_ANCHOR_BOTTOM));
        UXLabel* viewAs = new UXLabel();
        viewAs.setTitle((u8*)"View as:");
        bar.addSubview(viewAs, UXGeom.make((i16)8, (i16)4, (i16)60, rh));
        UXSegmentedControl* device = new UXSegmentedControl();
        device.addSegment((u8*)"Desktop", (i32)UXR_V_DESKTOP);
        device.addSegment((u8*)"Tablet", (i32)UXR_V_TABLET);
        device.addSegment((u8*)"Phone", (i32)UXR_V_PHONE);
        device.applyNativeSelection((i32)0);
        bar.addSubview(device, UXGeom.make((i16)68, (i16)4, (i16)196, rh));
        UXButton* rotate = new UXButton();
        rotate.setTitle((u8*)"Rotate");
        bar.addSubview(rotate, UXGeom.make((i16)270, (i16)4, (i16)62, rh));
        UXButton* newLayout = new UXButton();
        newLayout.setTitle((u8*)"New Layout");
        bar.addSubview(newLayout, UXGeom.make((i16)336, (i16)4, (i16)92, rh));
        // the layouts a new connection binds in (decision: all, unless narrowed here)
        UXLabel* cf = new UXLabel();
        cf.setTitle((u8*)"Connect:");
        bar.addSubview(cf, UXGeom.make((i16)436, (i16)4, (i16)66, rh));
        UXPopUpButton* scope = new UXPopUpButton();
        for (i32 p = (i32)RKSC_ALL; p <= (i32)RKSC_THIS; p = p + (i32)1)
            {
            scope.addItem(RKWiring.presetName(p), p);
            }
        scope.selectItem((i32)RKSC_ALL);
        bar.addSubview(scope, UXGeom.make((i16)502, (i16)4, (i16)112, rh));

        // ---- the right: the inspector over the library -------------------------
        // inspector over library, a divider between them to drag, the inspector scrolling when what
        // it shows is taller than its pane
        UXSplitView* column = new UXSplitView();
        column.setVertical(true);
        i16 insH = (i16)((i32)bodyH * (i32)3 / (i32)5);
        column.setDividerPos(insH);
        inner.secondPane().addSubview(column, UXGeom.make((i16)0, (i16)0, (i16)inW, bodyH));
        column.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        UXView* inspector = column.firstPane();
        UXLabel* tv = new UXLabel(); // what is selected: its class
        tv.setTitle((u8*)"—");
        inspector.addSubview(tv, UXGeom.make((i16)8, (i16)4, (i16)((i32)inW - (i32)16), rh));
        tv.setAutoresizeMask((i32)UX_FLEX_WIDTH);
        UXSegmentedControl* tabs = new UXSegmentedControl();
        tabs.addSegment((u8*)"Identity", (i32)0);
        tabs.addSegment((u8*)"Attributes", (i32)1);
        tabs.addSegment((u8*)"Size", (i32)2);
        tabs.addSegment((u8*)"Connections", (i32)3);
        tabs.applyNativeSelection((i32)1);
        i16 tabY = (i16)((i32)rh + (i32)8);
        inspector.addSubview(tabs, UXGeom.make((i16)4, tabY, (i16)((i32)inW - (i32)8), rh));
        i16 paneY = (i16)((i32)tabY + (i32)rh + (i32)6);
        UXScrollView* insScroll = new UXScrollView();
        inspector.addSubview(insScroll, UXGeom.make((i16)0, paneY, (i16)inW, (i16)((i32)insH - (i32)paneY)));
        insScroll.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        c.inspectorScroll = insScroll;
        UXRect paneR = UXGeom.make((i16)0, (i16)0, (i16)((i32)inW - (i32)16), (i16)((i32)insH - (i32)paneY));
        for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
            {
            UXView* p = new UXView();
            insScroll.document().addSubview(p, paneR);
            p.setHidden(i != (i32)1);
            c.tabPanes.add(p);
            }
        // Only the CHROME is built here.  The rows depend on what is selected, so the pane
        // controllers generate them; see RKInspector on why this is where the rsc-client rule bends.
        c.identityCtl.attach((UXView* ?)c.tabPanes.get((u32)0));
        c.inspectorCtl.attach((UXView* ?)c.tabPanes.get((u32)1), tv);
        c.sizeCtl.attach((UXView* ?)c.tabPanes.get((u32)2), (UXLabel*)0);
        c.connectionsCtl.attach((UXView* ?)c.tabPanes.get((u32)3));

        UXView* libPane = column.secondPane();
        i16 libH = (i16)((i32)bodyH - (i32)insH);
        UXLabel* ll = new UXLabel();
        ll.setTitle((u8*)"Library");
        libPane.addSubview(ll, UXGeom.make((i16)8, (i16)6, (i16)80, rh));
        UXTextField* search = new UXTextField();
        search.setPlaceholder((u8*)"Filter");
        libPane.addSubview(search, UXGeom.make((i16)8, (i16)((i32)rh + (i32)10), (i16)((i32)inW - (i32)16), rh));
        search.setAutoresizeMask((i32)UX_FLEX_WIDTH);
        i16 tY = (i16)((i32)2 * (i32)rh + (i32)16);
        UXTableView* lib = new UXTableView();
        lib.addColumn((u8*)"Object", (i16)110);
        lib.addColumn((u8*)"", (i16)((i32)inW - (i32)130));
        lib.setDataSource((UXTableDataSource*)c.library);
        lib.setDragsRows(true); // a row dragged onto the form is placed where it is dropped
        libPane.addSubview(lib, UXGeom.make((i16)4, tY, (i16)((i32)inW - (i32)8), (i16)((i32)libH - (i32)tY - (i32)4)));
        lib.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT)); // the library takes the height
        lib.reloadData(); // a table the toolkit draws (the web, GEM) makes its rows here

        // ---- the status line -----------------------------------------------
        UXLabel* status = new UXLabel();
        status.setTitle((u8*)"Ready");
        outer.firstPane().addSubview(status, UXGeom.make((i16)8, (i16)((i32)bodyH - (i32)stH - (i32)4), (i16)((i32)olW - (i32)12), stH));
        status.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_ANCHOR_BOTTOM));

        // The outline and the library report selection through the table delegate they inherit;
        // that one line is what makes the panes a single editor.
        outline.setDelegate((UXTableDelegate*)c);
        lib.setDelegate((UXTableDelegate*)c);

        // ---- wiring, through the protocol an rsc file would use ------------------
        ok = c.setOutlet((u8*)"formOutline", (Object*)outline) && ok;
        ok = c.setOutlet((u8*)"canvas", (Object*)canvas) && ok;
        c.ensureBackdrop(); // the grid from the start, before there is a form on it
        ok = c.setOutlet((u8*)"inspector", (Object*)inspector) && ok;
        ok = c.setOutlet((u8*)"statusLabel", (Object*)status) && ok;
        ok = c.setOutlet((u8*)"deviceBar", (Object*)device) && ok;
        ok = c.setOutlet((u8*)"inspectorTabs", (Object*)tabs) && ok;
        ok = c.setOutlet((u8*)"libraryTable", (Object*)lib) && ok;
        ok = c.setOutlet((u8*)"librarySearch", (Object*)search) && ok;
        ok = c.setOutlet((u8*)"newScope", (Object*)scope) && ok;
        ok = c.wireAction((u8*)"onNewScope", (UXControl*)scope) && ok;
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
    // main: an rsc file carries its main menu, and when this file is replaced by one
    // that loads an rsc file, the menu should come across with the rest of the
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
        doc.addSeparator();
        doc.addItem((u8*)"Add Class Source or Library...", &c.onAddClasses);

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
