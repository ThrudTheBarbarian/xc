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
// Layout is the classic three-pane editor: outline | canvas | inspector, with
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
    static bool buildInto(UXView* content, RKMainController* c, i16 w, i16 h)
        {
        bool ok = true;
        i16 gut = (i16)UXMetrics.gutter();
        i16 tbH = (i16)48; // icon-above-text bar
        i16 stH = (i16)UXMetrics.stdHeightFor((i32)UXKindLabel, (i32)UX_FORM_DESKTOP);

        // ---- the toolbar ---------------------------------------------------
        UXToolbar* tb = new UXToolbar();
        tb.addItem((u8*)"doc.new", (u8*)"New", 1, (i16)44);
        tb.addItem((u8*)"trash", (u8*)"Delete", 2, (i16)44);
        tb.addSeparator();
        tb.addItem((u8*)"desktop", (u8*)"Desktop", 3, (i16)52);
        tb.addItem((u8*)"tablet", (u8*)"Tablet", 4, (i16)52);
        tb.addItem((u8*)"phone", (u8*)"Phone", 5, (i16)52);
        content.addSubview(tb, UXGeom.make((i16)0, (i16)0, w, tbH));

        // ---- outline | (canvas | inspector) --------------------------------
        i16 bodyY = (i16)((i32)tbH + (i32)gut);
        i16 bodyH = (i16)((i32)h - (i32)bodyY - (i32)stH - (i32)gut);

        UXSplitView* outer = new UXSplitView(); // outline | rest
        outer.setDividerPos((i16)200);
        content.addSubview(outer, UXGeom.make((i16)0, bodyY, w, bodyH));

        UXOutlineView* outline = new UXOutlineView();
        outer.firstPane().addSubview(outline, UXGeom.make((i16)0, (i16)0, (i16)200, bodyH));

        UXSplitView* inner = new UXSplitView(); // canvas | inspector
        inner.setDividerPos((i16)((i32)w - (i32)200 - (i32)260));
        outer.secondPane().addSubview(inner,
                                      UXGeom.make((i16)0, (i16)0, (i16)((i32)w - (i32)200), bodyH));

        UXView* canvas = new UXView();
        UXView* inspector = new UXView();
        inner.firstPane().addSubview(canvas,
                                     UXGeom.make((i16)0, (i16)0, (i16)((i32)w - (i32)200 - (i32)260), bodyH));
        inner.secondPane().addSubview(inspector, UXGeom.make((i16)0, (i16)0, (i16)260, bodyH));

        // ---- the inspector pane ---------------------------------------------
        // Only the CHROME is built here — a heading and the container.  The
        // rows depend on what is selected, so RKInspector generates them; see
        // the note in that file about why this is the one place the
        // nib-client rule bends.
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);
        UXLabel* tl = new UXLabel();
        tl.setTitle((u8*)"Type:");
        inspector.addSubview(tl, UXGeom.make((i16)8, (i16)8, (i16)46, rh));
        UXLabel* tv = new UXLabel();
        tv.setTitle((u8*)"—");
        inspector.addSubview(tv, UXGeom.make((i16)56, (i16)8, (i16)160, rh));

        UXView* propPane = new UXView();
        inspector.addSubview(propPane, UXGeom.make((i16)0, (i16)((i32)rh + (i32)14),
                                                   (i16)260, (i16)((i32)bodyH - (i32)rh - (i32)14)));
        c.inspectorCtl.attach(propPane, tv);

        // ---- the status line -----------------------------------------------
        UXLabel* status = new UXLabel();
        status.setTitle((u8*)"Ready");
        content.addSubview(status,
                           UXGeom.make(gut, (i16)((i32)h - (i32)stH), (i16)((i32)w - (i32)2 * (i32)gut), stH));

        // The outline reports selection through the table delegate it inherits;
        // that one line is what makes the two panes a single editor.
        outline.setDelegate((UXTableDelegate*)c);

        // ---- wiring, through the protocol a nib would use ------------------
        if (!c.setOutlet((u8*)"formOutline", (Object*)outline))
            {
            ok = false;
            }
        if (!c.setOutlet((u8*)"canvas", (Object*)canvas))
            {
            ok = false;
            }
        if (!c.setOutlet((u8*)"inspector", (Object*)inspector))
            {
            ok = false;
            }
        if (!c.setOutlet((u8*)"statusLabel", (Object*)status))
            {
            ok = false;
            }
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

        UXMenu* view = bar.addMenu((u8*)"View");
        UXMenuItem* snap = view.addItem((u8*)"Snap to Guides", &c.onToggleSnap);
        UXMenuItem* guid = view.addItem((u8*)"Show Guides", &c.onToggleGuides);
        snap.checked = c.snapEnabled();
        guid.checked = c.guidesEnabled();

        c.menuBar = bar;
        c.viewMenu = (i32)1;  // ordinals into the bar, not names: setChecked
        c.snapItem = (i32)0;  // addresses items positionally, and these three
        c.guideItem = (i32)1; // numbers are the only place that mapping lives
        app.setMenuBar(bar);
        }
    }
