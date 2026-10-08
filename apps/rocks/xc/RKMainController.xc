// RKMainController.xc — the main window's controller, written as a RSC CLIENT.
//
// This class constructs nothing.  It declares what it needs to talk to
// (`outlet`) and what it can be told (`:action`), and something else supplies
// the views: today RKMainBuilder, building them in code; later an rsc file that
// Rocks itself authored.  That is the whole bootstrap plan — swap the builder
// file, keep this one — and it only works if the controller never reaches out
// and makes a view for itself.
//
// The `outlet` / `:action` decorations auto-conform this class to
// UXDesignable, and the compiler synthesises setOutlet/wireAction from them
// (bug 026).  Both the code builder and the rsc loader drive those SAME two
// methods, which is what makes the two paths interchangeable rather than
// merely similar.  It also means this file is the worked example of the
// pattern every Rocks user will write.
#import "UXDesignable.xc"
#import "UXControl.xc"
#import "UXOutlineView.xc"
#import "UXView.xc"
#import "UXRscModel.xc"
#import "RKCanvas.xc"
#import "RKOutline.xc"
#import "RKSelection.xc"
#import "RKInspector.xc"
#import "RKDrag.xc"
#import "UXToolbar.xc"
#import "Data.xc"
#import "UXFileIO.xc"
#import "UXOpenPanel.xc"
#import "UXSavePanel.xc"
#import "UXMenu.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
#import "RKUndo.xc"
#import "RKIdentity.xc"
#import "RKLibrary.xc"
#import "RKClasses.xc"
#import "RKWiring.xc"
#import "RKConnect.xc"
#import "RKVariants.xc"
#import "RKBackdrop.xc"
#import "UXSegmentedControl.xc"

// The toolbar's items, by tag (RKMainBuilder makes them; onToolbar dispatches them).
#define RKTB_NEW 1
#define RKTB_DELETE 2
#define RKTB_DESKTOP 3
#define RKTB_TABLET 4
#define RKTB_PHONE 5
#define RKTB_ROTATE 6
#define RKTB_NEWLAYOUT 7
#import "UXMenu.xc"
#import "UXTableView.xc"

class RKMainController : Object<UXTableDelegate>
    {
    // ---- outlets: the views this controller talks to -----------------------
    outlet UXOutlineView* formOutline; // the document's forms and their trees
    outlet UXView* canvas;             // the drawing area (real UXKit widgets)
    outlet UXView* inspector;          // the property pane
    outlet UXLabel* statusLabel;       // one line of feedback, bottom left
    outlet UXSegmentedControl* deviceBar;     // View as: Desktop / Tablet / Phone
    outlet UXSegmentedControl* inspectorTabs; // Identity / Attributes / Size / Connections
    outlet UXTableView* libraryTable;         // what can be added
    outlet UXTextField* librarySearch;        // its filter
    outlet UXPopUpButton* newScope;           // Connect for: the layouts a new connection binds in

    // The document.  The controller owns the MODEL; the canvas outlet shows it.
    UXRscDoc* doc;
    i32 shownTree;
    RKOutline* outlineModel;    // strong: the outline view holds its source weakly
    RKCanvas* canvasMap;        // the map for the tree currently shown
    Array<UXView>* panes;       // one container per tree, built on first view
    Array<RKCanvas>* maps;      // its object -> widget map
    UXRscObject* selected;         // what the designer has picked, or 0
    RKSelectionFrame* selFrame; // the selection art; created once, moved around
    // The input surface that makes the canvas a DESIGN surface rather than a
    // live one.  It sits over every pane, so a click selects a button instead
    // of pressing it.  Created here, added to the canvas when there is one.
    RKEditOverlay* overlay;
    // The menu bar, so a toggle can put its own tick back.  Held weakly: the
    // application owns the bar, and a controller that owned its menus would be
    // a controller that built views.
    weak : UXMenuBar* menuBar;
    // The toolbar, weakly for the same reason (and its action already holds this controller).
    weak : UXToolbar* toolbar;
    i32 viewMenu, snapItem, guideItem; // where the toggles live in that bar
    u8* geomBuf;                       // reused: a drag writes this per step
    // NOTE: `inspector` is the outlet for the PANE (a UXView); this is its
    // controller.  Two different things, so two different names.
    RKInspector* inspectorCtl;      // the Attributes tab
    RKInspector* sizeCtl;           // the Size tab: the same rows' frame share
    RKIdentity* identityCtl;        // the Identity tab
    Array<UXView>* tabPanes;        // the four tabs' panes, in order (the builder fills it)
    UXScrollView* inspectorScroll;  // what they scroll in
    RKLibrary* library;
    RKClassBook* classBook;         // what is known about classes: UXKit's, the app's, declared
    RKConnectionsPane* connectionsCtl; // the Connections tab
    RKWireChooser* chooser;         // the list a connection line ended in, while it is up
    i32 newScopePreset;             // RKSC_*: the scope a new connection gets
    RKVariants* variants;           // which properties each layout varies; the rest are shared
    RKBackdrop* backdrop;           // the grid under the canvas, and the form's panel on it
    RKLibraryItem* placing;         // armed by a library pick: the next canvas press places it
    UXView* preview;                // the control a library drag shows over the form, or 0
    bool wireIn;                    // an outline row's drag is over the canvas
    i32 wireInX;                    // where it began, the start of its line
    i32 wireInY;
    RKLibraryItem* previewItem;     // what it previews
    // What is selected, by outline row kind (RKON_*): a control (`selected`), a placeholder, or one
    // of the document's objects (selTop); 0 = nothing.
    i32 selKind;
    i32 selTop;
    // Undo and redo (RKUndo.xc).  A press copies the document into pressCopy; the copy becomes an
    // undo step only if the press turns into a drag.
    RKUndoStack* history;
    UXRscDoc* pressCopy;
    i32 pressSel;
    bool dragging;

    // ---- state -------------------------------------------------------------
    // Deliberately not a view: the controller owns MODEL state and asks the
    // views to show it, never the reverse.
    i32 selectedForm;
    bool dirty;
    // The layout being viewed: a form factor and, on a device, an orientation (UXNB-V2 sections 1
    // and 10).  Chosen in the toolbar; it says which of a form's layouts the canvas shows, and
    // which one New Layout creates.
    i32 viewClass;
    i32 viewOrient;
    // Where the document lives on disk, or 0 for one never saved.  Owned (docPathStore holds the bytes).
    u8* docPath;
    Data* docPathStore;

    void init(void)
        {
        selectedForm = (i32)-1;
        dirty = false;
        viewClass = (i32)UXR_V_DESKTOP;
        viewOrient = (i32)UXR_V_ORIENT_NONE;
        docPath = (u8*)0;
        docPathStore = (Data*)0;
        doc = (UXRscDoc*)0;
        shownTree = (i32)0;
        outlineModel = new RKOutline();
        canvasMap = new RKCanvas();
        panes = new Array();
        maps = new Array();
        selected = (UXRscObject*)0;
        selFrame = (RKSelectionFrame*)0;
        overlay = new RKEditOverlay();
        overlay.picked = &self.onPick;
        overlay.changed = &self.onDragStep;
        overlay.ended = &self.onDragEnd;
        menuBar = (UXMenuBar*)0;
        toolbar = (UXToolbar*)0;
        viewMenu = (i32)-1;
        snapItem = (i32)0;
        guideItem = (i32)1;
        geomBuf = (u8*)malloc((u32)64);
        inspectorCtl = new RKInspector();
        inspectorCtl.section = (i32)RKIS_ATTRIBUTES;
        inspectorCtl.changed = &self.onInspectorEdit;
        inspectorCtl.willChange = &self.onInspectorWillChange;
        sizeCtl = new RKInspector();
        sizeCtl.section = (i32)RKIS_SIZE;
        sizeCtl.changed = &self.onInspectorEdit;
        sizeCtl.willChange = &self.onInspectorWillChange;
        identityCtl = new RKIdentity();
        identityCtl.willChange = &self.onIdentityWillChange;
        identityCtl.changed = &self.onIdentityEdit;
        tabPanes = new Array();
        inspectorScroll = (UXScrollView*)0;
        library = new RKLibrary();
        classBook = new RKClassBook();
        identityCtl.book = classBook;
        connectionsCtl = new RKConnectionsPane();
        connectionsCtl.willChange = &self.onConnectionWillChange;
        connectionsCtl.changed = &self.onConnectionEdit;
        chooser = (RKWireChooser*)0;
        newScopePreset = (i32)RKSC_ALL;
        variants = new RKVariants();
        backdrop = (RKBackdrop*)0;
        overlay.offX = (i32)RK_FORM_X;
        overlay.offY = (i32)RK_FORM_Y;
        inspectorCtl.varyState = &self.varyStateOf;
        inspectorCtl.varyToggle = &self.onVaryToggle;
        overlay.wireFrom = &self.onWireFromView;
        newScope = (UXPopUpButton*)0;
        placing = (RKLibraryItem*)0;
        preview = (UXView*)0;
        wireIn = false;
        wireInX = (i32)0;
        wireInY = (i32)0;
        previewItem = (RKLibraryItem*)0;
        selKind = (i32)0;
        selTop = (i32)0;
        overlay.placeAt = &self.placeAt;
        overlay.deleteKey = &self.deleteSelection;
        deviceBar = (UXSegmentedControl*)0;
        inspectorTabs = (UXSegmentedControl*)0;
        libraryTable = (UXTableView*)0;
        librarySearch = (UXTextField*)0;
        history = new RKUndoStack();
        pressCopy = (UXRscDoc*)0;
        pressSel = (i32)-1;
        dragging = false;
        lastSaid = (Data*)0;
        formOutline = (UXOutlineView*)0;
        canvas = (UXView*)0;
        inspector = (UXView*)0;
        statusLabel = (UXLabel*)0;
        }

    // ---- actions: what the UI can ask for ----------------------------------
    // Each is wired by NAME, so the builder and an rsc file reach them identically.
    // A new, empty dialog: its own form, shown on the canvas.
    void onNewForm(UXControl* sender) : action
        {
        if (doc == (UXRscDoc*)0)
            {
            doc = new UXRscDoc();
            }
        self.willEdit((u8*)"New Form", (Object*)0);
        UXRscTree* t = new UXRscTree();
        t.setNameJoined((u8*)"FORM", RKIdentity.num(doc.treeCount() + (i32)1));
        t.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)320, (i32)200);
        doc.addTree(t);
        dirty = true;
        self.showResource(doc, doc.indexOfTree(t));
        self.sayAbout((u8*)"New form ", t.name);
        }
    void onDelete(UXControl* sender) : action
        {
        self.deleteSelection();
        }
    void onDeleteItem(UXMenuItem* sender)
        {
        self.deleteSelection();
        }
    // Delete what is selected: a control (and, when no other layout has it, its class and its
    // connections), or one of the document's objects and its connections.
    void deleteSelection(void)
        {
        if (doc == (UXRscDoc*)0)
            {
            return;
            }
        if (selKind == (i32)RKON_OBJECT)
            {
            self.willEdit((u8*)"Delete", (Object*)0);
            doc.removeTopObject(selTop);
            dirty = true;
            self.showResource(doc, shownTree);
            self.say((u8*)"Deleted");
            return;
            }
        UXRscObject* o = selected;
        if (o == (UXRscObject*)0 || shownTree < (i32)0 || shownTree >= doc.treeCount())
            {
            self.say((u8*)"Nothing to delete");
            return;
            }
        UXRscTree* t = doc.treeAt(shownTree);
        UXRscObject* parent = t.parentOf(o);
        if (parent == (UXRscObject*)0)
            {
            self.say((u8*)"A form's own box cannot be deleted");
            return;
            }
        self.willEdit((u8*)"Delete", (Object*)0);
        if (o.logicalId != (i32)0 && !self.inOtherLayout(t, o.logicalId))
            {
            UXRscRef* r = UXRscRef.make((i32)UXR_REF_LOGICAL, doc.formIdOf(t), o.logicalId);
            doc.removeConnectionsTo(r);
            doc.setClassOf(t, o, (u8*)"");
            }
        for (i32 i = (i32)0; i < parent.childCount(); i = i + (i32)1)
            {
            if (parent.childAt(i) == o)
                {
                parent.children.removeAt((u32)i);
                break;
                }
            }
        dirty = true;
        self.rebuildShownPane();
        self.showResource(doc, shownTree);
        self.say((u8*)"Deleted");
        }
    // Whether another layout of `t`'s form has the control with this logical id.
    bool inOtherLayout(UXRscTree* t, i32 id)
        {
        UXRscForm* f = doc.formOf(t);
        if (f == (UXRscForm*)0)
            {
            return false;
            }
        for (i32 v = (i32)0; v < f.variantCount(); v = v + (i32)1)
            {
            UXRscTree* o = f.variantAt(v).tree;
            if (o == t)
                {
                continue;
                }
            Array<UXRscObject>* all = o.allObjects();
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                if (((UXRscObject* ?)all.get(k)).logicalId == id)
                    {
                    return true;
                    }
                }
            }
        return false;
        }

    // ---- the device bar: View as ---------------------------------------------------
    void onDeviceBar(UXControl* sender) : action
        {
        if (deviceBar == (UXSegmentedControl*)0)
            {
            return;
            }
        i32 seg = deviceBar.selectedSegment();
        if (seg == (i32)0)
            {
            self.onDesktop(sender);
            }
        else if (seg == (i32)1)
            {
            self.onTablet(sender);
            }
        else if (seg == (i32)2)
            {
            self.onPhone(sender);
            }
        }
    // The bar shows the form factor being viewed, however it was chosen.
    void reflectDevice(void)
        {
        if (deviceBar == (UXSegmentedControl*)0)
            {
            return;
            }
        i32 seg = viewClass == (i32)UXR_V_PHONE ? (i32)2 : (viewClass == (i32)UXR_V_TABLET ? (i32)1 : (i32)0);
        if (deviceBar.selectedSegment() != seg)
            {
            deviceBar.applyNativeSelection(seg);
            }
        }

    // ---- the inspector's tabs ----------------------------------------------------------
    void onInspectorTab(UXControl* sender) : action
        {
        if (inspectorTabs != (UXSegmentedControl*)0)
            {
            self.showTab(inspectorTabs.selectedSegment());
            }
        }
    void showTab(i32 i)
        {
        for (u32 k = (u32)0; k < tabPanes.count(); k = k + (u32)1)
            {
            ((UXView* ?)tabPanes.get(k)).setHidden((i32)k != i);
            }
        if (inspectorTabs != (UXSegmentedControl*)0 && inspectorTabs.selectedSegment() != i)
            {
            inspectorTabs.applyNativeSelection(i);
            }
        self.fitInspector();
        }
    // The scroller follows the tab shown: as tall as its rows, so a long one scrolls.
    void fitInspector(void)
        {
        if (inspectorScroll == (UXScrollView*)0)
            {
            return;
            }
        i32 t = self.shownTab();
        if (t < (i32)0 || t >= (i32)tabPanes.count())
            {
            return;
            }
        UXView* p = (UXView* ?)tabPanes.get((u32)t);
        i32 bottom = (i32)0;
        UXRect f = UXGeom.zero(); // a struct local lives at function scope, not in the loop
        for (Object* o in p.subviews)
            {
            UXView* v = (UXView* ?)o;
            if (v != (UXView*)0)
                {
                f = v.frame();
                if ((i32)f.y + (i32)f.h > bottom)
                    {
                    bottom = (i32)f.y + (i32)f.h;
                    }
                }
            }
        i32 h = bottom + (i32)8;
        i32 seen = (i32)inspectorScroll.frame().h;
        if (h < seen)
            {
            h = seen;
            }
        UXRect pf = p.frame();
        p.setFrame(UXGeom.make(pf.x, pf.y, pf.w, (i16)h));
        inspectorScroll.setDocumentHeight(h);
        }
    i32 shownTab(void)
        {
        return inspectorTabs != (UXSegmentedControl*)0 ? inspectorTabs.selectedSegment() : (i32)1;
        }

    // ---- the library ----------------------------------------------------------------------
    void onLibrarySearch(UXTextField* sender)
        {
        library.setFilter(RKIdentity.dup(sender.text()));
        if (libraryTable != (UXTableView*)0)
            {
            libraryTable.reloadData();
            }
        }
    // A library pick: Object is added at once; a control arms the canvas.
    void libraryPick(RKLibraryItem* it)
        {
        if (it == (RKLibraryItem*)0 || doc == (UXRscDoc*)0)
            {
            return;
            }
        if (it.type == (i32)RKLIB_OBJECT)
            {
            self.willEdit((u8*)"Add Object", (Object*)0);
            UXRscTopObject* to = doc.addTopObject((u8*)"", (u8*)"");
            dirty = true;
            self.showResource(doc, shownTree);
            self.selectPlaceholder((i32)RKON_OBJECT, to.id);
            self.showTab((i32)0); // the next thing to do is give it a class
            self.say((u8*)"Added an object: give it a class");
            return;
            }
        placing = it;
        self.sayAbout((u8*)"Click in the form to place a ", it.name);
        }
    // The press that places an armed library item: it goes where the press landed, inside the
    // innermost box there, and is selected.
    bool placeAt(i32 cx, i32 cy)
        {
        RKLibraryItem* it = placing;
        if (it == (RKLibraryItem*)0 || doc == (UXRscDoc*)0 || shownTree < (i32)0 || shownTree >= doc.treeCount())
            {
            return false;
            }
        placing = (RKLibraryItem*)0;
        self.willEdit((u8*)"Add", (Object*)0);
        UXRscTree* t = doc.treeAt(shownTree);
        UXRscObject* o = RKMainController.objectFor(it, cx, cy);
        t.root.addChild(o);
        self.markContainers(t);
        t.reparentByGeometry();
        doc.ensureLogicalId(t, o);
        if (it.cls != (u8*)0)
            {
            doc.setClassOf(t, o, it.cls);
            RKMainController.setAttrs(doc, t, o, it.attrs);
            }
        dirty = true;
        self.rebuildShownPane();
        self.showResource(doc, shownTree);
        self.selectObject(o);
        overlay.setSelection(o);
        self.sayAbout((u8*)"Added a ", it.name);
        return true;
        }

    // ---- the backdrop and the form's panel -------------------------------------------------------
    // Where a form's controls are realized on the canvas: from the panel's corner, to the canvas's.
    UXRect formArea(void)
        {
        UXRect b = canvas.bounds();
        return UXGeom.make((i16)RK_FORM_X, (i16)RK_FORM_Y, (i16)((i32)b.w - (i32)RK_FORM_X), (i16)((i32)b.h - (i32)RK_FORM_Y));
        }
    void ensureBackdrop(void)
        {
        if (backdrop != (RKBackdrop*)0 || canvas == (UXView*)0)
            {
            return;
            }
        backdrop = new RKBackdrop();
        canvas.addSubview(backdrop, canvas.bounds()); // first, so everything is drawn on it
        backdrop.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        }
    // The panel shows the form's size, and which layout it is.
    void updatePanel(void)
        {
        UXRscTree* t = self.shownTreeOrNull();
        if (backdrop == (RKBackdrop*)0 || t == (UXRscTree*)0 || t.root == (UXRscObject*)0)
            {
            return;
            }
        UXRscForm* f = doc.formOf(t);
        UXRscVariant* v = f != (UXRscForm*)0 ? f.variantFor(t) : (UXRscVariant*)0;
        u8* what = v != (UXRscVariant*)0 ? RKIdentity.themeName(v.klass, v.orient) : (u8*)"every layout";
        Data* l = UXStr.toData(what);
        l.appendBytes((u8*)" · ", UXRscTree.len((u8*)" · "));
        u8* ws = RKIdentity.num(t.root.w);
        u8* hs = RKIdentity.num(t.root.h);
        l.appendBytes(ws, UXRscTree.len(ws));
        l.appendBytes((u8*)" × ", UXRscTree.len((u8*)" × "));
        l.appendBytes(hs, UXRscTree.len(hs));
        l.appendByte((u8)0);
        backdrop.showForm(t.root.w, t.root.h, UXStr.cstr(l));
        }
    // A device layout's panel starts the size of a typical one of its kind, not the desktop's.
    static void deviceSize(UXRscTree* t, i32 klass, i32 orient)
        {
        if (klass == (i32)UXR_V_PHONE)
            {
            t.root.w = orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (i32)640 : (i32)360;
            t.root.h = orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (i32)360 : (i32)640;
            }
        else if (klass == (i32)UXR_V_TABLET)
            {
            t.root.w = orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (i32)1024 : (i32)768;
            t.root.h = orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (i32)768 : (i32)1024;
            }
        }

    // ---- layouts: shared and varied properties -------------------------------------------------
    i32 varyStateOf(UXRscObject* o, RKProperty* p)
        {
        UXRscTree* t = self.shownTreeOrNull();
        if (t == (UXRscTree*)0 || RKVariants.copiesOf(doc, t, o).count() == (u32)0)
            {
            return (i32)-1; // in this layout only: nothing to share or vary
            }
        return variants.varies(doc, t, o, p.label) ? (i32)1 : (i32)0;
        }
    void onVaryToggle(UXRscObject* o, RKProperty* p)
        {
        UXRscTree* t = self.shownTreeOrNull();
        if (t == (UXRscTree*)0)
            {
            return;
            }
        self.willEdit((u8*)"Vary", (Object*)0);
        if (variants.varies(doc, t, o, p.label))
            {
            variants.unvary(doc, t, o, p);
            self.sayAbout((u8*)"Shared again: ", p.label);
            UXView* w = canvasMap.viewFor(o);
            if (w != (UXView*)0)
                {
                UXRsc.applyState(w, o);
                UXRsc.applyText(w, o);
                }
            }
        else
            {
            variants.vary(doc, t, o, p.label);
            self.sayAbout((u8*)"This layout varies ", p.label);
            }
        dirty = true;
        inspectorCtl.show(o); // the toggle reads the new state
        }
    // The other layouts of `t`'s form have changed under their panes: rebuild those panes, so
    // switching to one shows what it now says.
    void staleOtherLayouts(UXRscTree* t)
        {
        UXRscForm* f = doc.formOf(t);
        if (f == (UXRscForm*)0 || canvas == (UXView*)0)
            {
            return;
            }
        for (i32 v = (i32)0; v < f.variantCount(); v = v + (i32)1)
            {
            i32 ti = doc.indexOfTree(f.variantAt(v).tree);
            if (ti == shownTree || ti >= (i32)panes.count())
                {
                continue;
                }
            ((UXView* ?)panes.get((u32)ti)).setHidden(true);
            UXView* pane = new UXView();
            canvas.addSubview(pane, self.formArea());
            pane.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
            pane.setHidden(true);
            RKCanvas* map = new RKCanvas();
            map.realizeIn(doc, doc.treeAt(ti), (i32)RKWiring.themeOf(doc, doc.treeAt(ti)), pane);
            panes.set((u32)ti, pane);
            maps.set((u32)ti, map);
            }
        self.raiseOverlay();
        }

    // ---- connections ------------------------------------------------------------------------
    // The selection as a connection end, or 0.
    RKEnd* selectedEnd(void)
        {
        if (selKind == (i32)RKON_VIEW && selected != (UXRscObject*)0)
            {
            return RKEnd.view(selected);
            }
        if (selKind == (i32)RKON_OWNER || selKind == (i32)RKON_FIRSTR || selKind == (i32)RKON_OBJECT)
            {
            return RKEnd.placeholder(selKind, selTop);
            }
        return (RKEnd*)0;
        }
    UXRscTree* shownTreeOrNull(void)
        {
        return doc != (UXRscDoc*)0 && shownTree >= (i32)0 && shownTree < doc.treeCount() ? doc.treeAt(shownTree) : (UXRscTree*)0;
        }
    void showConnections(void)
        {
        UXRscTree* t = self.shownTreeOrNull();
        connectionsCtl.show(doc, t, classBook, t != (UXRscTree*)0 ? self.selectedEnd() : (RKEnd*)0);
        self.fitInspector(); // every selection change ends here
        }
    void onConnectionWillChange(void)
        {
        self.willEdit((u8*)"Connection", (Object*)0);
        }
    void onConnectionEdit(void)
        {
        dirty = true;
        self.showConnections();
        }
    void onNewScope(UXControl* sender) : action
        {
        if (newScope != (UXPopUpButton*)0)
            {
            newScopePreset = newScope.selectedIndex();
            }
        }
    void onWireFromView(UXRscObject* o, i32 wx, i32 wy)
        {
        self.trackWire(RKEnd.view(o), wx, wy);
        }
    // Draw a line from `src` while the button is held, then offer what fits where it was let go.
    void trackWire(RKEnd* src, i32 wx, i32 wy)
        {
        if (doc == (UXRscDoc*)0 || canvas == (UXView*)0 || !gDriver.dragTrackingIsModal())
            {
            return;
            }
        i32 x0 = (i32)0;
        i32 y0 = (i32)0;
        self.endCentre(src, &x0, &y0);
        i32 x = wx;
        i32 y = wy;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            RKEnd* over = self.endAtWindow(x, y);
            UXRect hot = UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
            if (over != (RKEnd*)0 && over.isView())
                {
                hot = overlay.onCanvas(overlay.drag.canvasRect(over.obj));
                }
            self.sayOver(over);
            self.drawLine(x0, y0, x, y, hot);
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        self.eraseLine();
        RKEnd* dst = self.endAtWindow(x, y);
        i32 moved = (x - wx) * (x - wx) + (y - wy) * (y - wy);
        if (moved <= (i32)16)
            {
            self.contextMenu(src, x, y); // a right-click let go where it was pressed: its menu
            return;
            }
        if (dst == (RKEnd*)0)
            {
            self.say((u8*)"No connection: let go over a control or an object");
            return;
            }
        self.offerWire(src, dst, x, y);
        }
    // The right-click menu of a control or an object: it is selected first, so what the menu does
    // is done to it.
    void contextMenu(RKEnd* e, i32 wx, i32 wy)
        {
        if (e.isView())
            {
            self.selectObject(e.obj);
            overlay.setSelection(e.obj);
            }
        else
            {
            self.selectPlaceholder(e.kind, e.topId);
            }
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        UXMenu* m = new UXMenu();
        UXMenuItem* del = m.addItem((u8*)"Delete", &self.onDeleteItem);
        del.enabled = self.canDelete();
        m.addSeparator();
        m.addItem((u8*)"Connections", &self.onShowConnections);
        m.popUp(overlay.owner != (UXViewTree*)0 ? overlay.owner.winHandle : (i32)0, wx, wy);
        }
    void onShowConnections(UXMenuItem* sender)
        {
        self.showTab((i32)3);
        }
    // Whether Delete has something to delete: an Object, or a control that is not a form's own box.
    bool canDelete(void)
        {
        if (doc == (UXRscDoc*)0)
            {
            return false;
            }
        if (selKind == (i32)RKON_OBJECT)
            {
            return true;
            }
        if (selected == (UXRscObject*)0 || shownTree < (i32)0 || shownTree >= doc.treeCount())
            {
            return false;
            }
        return doc.treeAt(shownTree).parentOf(selected) != (UXRscObject*)0;
        }
    // The end under a window point: a row of the outline, or a control on the canvas.
    RKEnd* endAtWindow(i32 wx, i32 wy)
        {
        if (formOutline != (UXOutlineView*)0)
            {
            RKEnd* e = RKMainController.endOf((RKOutlineNode* ?)formOutline.itemAtWindowPoint(wx, wy));
            if (e != (RKEnd*)0)
                {
                return e;
                }
            }
        UXRect oa = overlay.absoluteFrame();
        if (wx < (i32)oa.x || wy < (i32)oa.y || wx >= (i32)oa.x + (i32)oa.w || wy >= (i32)oa.y + (i32)oa.h)
            {
            return (RKEnd*)0;
            }
        i32 cx = wx - (i32)oa.x - overlay.offX; // the form's coordinates
        i32 cy = wy - (i32)oa.y - overlay.offY;
        UXRscObject* o = RKDrag.hitTest(overlay.drag.root, cx, cy);
        return o != (UXRscObject*)0 ? RKEnd.view(o) : (RKEnd*)0;
        }
    // Where a line attaches to an end, in window coordinates.
    void endCentre(RKEnd* e, i32* wx, i32* wy)
        {
        if (e.isView())
            {
            UXRect r = overlay.onCanvas(overlay.drag.canvasRect(e.obj));
            UXRect oa = overlay.absoluteFrame();
            wx[0] = (i32)oa.x + (i32)r.x + (i32)r.w / (i32)2;
            wy[0] = (i32)oa.y + (i32)r.y + (i32)r.h / (i32)2;
            return;
            }
        wx[0] = (i32)0; // an outline row: its own drag draws its line (wireHover)
        wy[0] = (i32)0;
        }
    // The end of a connection a row stands for, or 0 (a form's row).
    static RKEnd* endOf(RKOutlineNode* n)
        {
        if (n == (RKOutlineNode*)0 || n.kind == (i32)RKON_FORM)
            {
            return (RKEnd*)0;
            }
        if (n.kind == (i32)RKON_VIEW)
            {
            return n.obj != (UXRscObject*)0 ? RKEnd.view(n.obj) : (RKEnd*)0;
            }
        return RKEnd.placeholder(n.kind, n.topId);
        }
    // While a line is drawn, the status line names what it is over, an outline row above all,
    // since nothing on the canvas shows it.
    void sayOver(RKEnd* e)
        {
        if (e == (RKEnd*)0 || e.isView())
            {
            return;
            }
        if (e.kind == (i32)RKON_OWNER)
            {
            self.say((u8*)"To File's Owner");
            }
        else if (e.kind == (i32)RKON_FIRSTR)
            {
            self.say((u8*)"To First Responder");
            }
        else
            {
            UXRscTopObject* to = doc.topObjectById(e.topId);
            self.sayAbout((u8*)"To ", to != (UXRscTopObject*)0 ? RKOutline.topLabel(to) : (u8*)"an object");
            }
        }
    // Offer what fits a line from `src` to `dst`, at window point (wx, wy).
    void offerWire(RKEnd* src, RKEnd* dst, i32 wx, i32 wy)
        {
        self.closeChooser();
        UXRscTree* t = self.shownTreeOrNull();
        if (t == (UXRscTree*)0)
            {
            return;
            }
        if (src.kind == dst.kind && src.obj == dst.obj && src.topId == dst.topId)
            {
            self.say((u8*)"No connection: a line needs two ends");
            return;
            }
        Array<RKChoice2>* cs = RKWiring.wireChoices(doc, t, classBook, src, dst);
        if (cs.count() == (u32)0)
            {
            self.say((u8*)"Nothing fits: give the object a class with outlets or actions (Identity)");
            return;
            }
        RKWireChooser* ch = new RKWireChooser();
        ch.choices = cs;
        ch.src = src;
        ch.dst = dst;
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);
        // the title, the list (its header, then a row a choice, at least two), Cancel
        i32 rows = (i32)cs.count() > (i32)2 ? (i32)cs.count() : (i32)2;
        i32 listH = (i32)24 + rows * (i32)24;
        i32 h = (i32)rh + (i32)10 + listH + (i32)rh + (i32)14;
        if (h > (i32)300)
            {
            listH = listH - (h - (i32)300);
            h = (i32)300;
            }
        // Beside the drop point, where it covers no control: native controls draw above the
        // toolkit's own views, so a list laid over one would be hidden behind it.
        UXRect ca = canvas.absoluteFrame();
        i32 px = wx - (i32)ca.x;
        i32 py = wy - (i32)ca.y;
        // the free place nearest the drop point, on a 12-point grid
        i32 bx = (i32)-1;
        i32 by = (i32)-1;
        i32 best = (i32)2147483647;
        for (i32 y = (i32)0; y + h <= (i32)ca.h; y = y + (i32)12)
            {
            for (i32 x = (i32)0; x + (i32)220 <= (i32)ca.w; x = x + (i32)12)
                {
                i32 dx = x - (px + (i32)12);
                i32 dy = y - (py + (i32)12);
                i32 dist = dx * dx + dy * dy;
                if (dist < best && !self.coversControl(t, x, y, (i32)220, h))
                    {
                    best = dist;
                    bx = x;
                    by = y;
                    }
                }
            }
        if (bx < (i32)0)
            {
            bx = px + (i32)12 + (i32)220 > (i32)ca.w ? (i32)ca.w - (i32)220 : px + (i32)12;
            by = py + (i32)12 + h > (i32)ca.h ? (i32)ca.h - h : py + (i32)12;
            }
        canvas.addSubview(ch, UXGeom.make((i16)(bx > (i32)0 ? bx : (i32)0), (i16)(by > (i32)0 ? by : (i32)0), (i16)220, (i16)h));
        UXLabel* title = new UXLabel();
        title.setTitle(RKConnectionsPane.joined3(RKConnectionsPane.describe(doc, t, RKWiring.refOf(doc, t, src)), (u8*)" -> ",
                                                 RKConnectionsPane.describe(doc, t, RKWiring.refOf(doc, t, dst))));
        ch.addSubview(title, UXGeom.make((i16)8, (i16)6, (i16)204, rh));
        UXTableView* tb = new UXTableView();
        tb.addColumn((u8*)"", (i16)56);
        tb.addColumn((u8*)"", (i16)140);
        tb.setDataSource((UXTableDataSource*)ch);
        tb.setDelegate((UXTableDelegate*)self);
        ch.addSubview(tb, UXGeom.make((i16)4, (i16)((i32)rh + (i32)10), (i16)212, (i16)listH));
        UXButton* cancel = new UXButton();
        cancel.setTitle((u8*)"Cancel");
        cancel.setAction(&self.onChooserCancel);
        ch.addSubview(cancel, UXGeom.make((i16)140, (i16)(h - (i32)rh - (i32)6), (i16)72, rh));
        ch.table = tb;
        ch.title = title;
        ch.cancel = cancel;
        chooser = ch;
        // the edit overlay takes every press on the canvas: while the list is up it stands aside,
        // so the list's rows and Cancel can be clicked
        overlay.setHidden(true);
        self.say((u8*)"Choose what to connect");
        }
    // A container CLASS: a view that holds designed children though its GEM type does not say so.
    static bool classIsContainer(u8* cls)
        {
        return cls != (u8*)0 && (UXRscDoc.seq(cls, (u8*)"UXScrollView") ||
                                 UXRscDoc.seq(cls, (u8*)"UXSplitView") ||
                                 UXRscDoc.seq(cls, (u8*)"UXTabView"));
        }
    // Tell the model which objects are container classes, so the geometry nesting
    // (UXRscTree.reparentByGeometry) puts a dropped control inside a scroll/split/tab view the way it
    // puts one in a box.
    void markContainers(UXRscTree* t)
        {
        if (doc == (UXRscDoc*)0 || t == (UXRscTree*)0)
            {
            return;
            }
        Array<UXRscObject>* all = t.allObjects();
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            UXRscObject* o = (UXRscObject* ?)all.get(i);
            o.holdsChildren = RKMainController.classIsContainer(doc.classOf(t, o));
            }
        }
    // Whether a canvas rect overlaps any control of the layout `t` (its containers excepted).
    bool coversControl(UXRscTree* t, i32 x, i32 y, i32 w, i32 h)
        {
        Array<UXRscObject>* all = t.allObjects();
        for (u32 i = (u32)1; i < all.count(); i = i + (u32)1)
            {
            UXRscObject* o = (UXRscObject* ?)all.get(i);
            if (o.canHoldChildren())
                {
                continue;
                }
            UXRect r = overlay.onCanvas(overlay.drag.canvasRect(o));
            if (x < (i32)r.x + (i32)r.w && (i32)r.x < x + w && y < (i32)r.y + (i32)r.h && (i32)r.y < y + h)
                {
                return true;
                }
            }
        return false;
        }
    void onChooserCancel(UXControl* sender) : action
        {
        self.closeChooser();
        self.say((u8*)"Not connected");
        }
    void closeChooser(void)
        {
        if (chooser != (RKWireChooser*)0)
            {
            chooser.setHidden(true);
            chooser.removeFromSuperview();
            chooser = (RKWireChooser*)0;
            overlay.setHidden(false);
            }
        }
    // A pick in the chooser: make the connection, in the scope chosen under the canvas.
    void choose(i32 row)
        {
        RKWireChooser* ch = chooser;
        UXRscTree* t = self.shownTreeOrNull();
        if (ch == (RKWireChooser*)0 || t == (UXRscTree*)0)
            {
            return;
            }
        RKChoice2* c = ch.choiceAt(row);
        if (c == (RKChoice2*)0)
            {
            return;
            }
        self.willEdit((u8*)"Connect", (Object*)0);
        u32 scope = RKWiring.scopeOf(newScopePreset, RKWiring.themeOf(doc, t));
        RKWiring.connect(doc, t, ch.src, ch.dst, c, scope);
        self.closeChooser();
        dirty = true;
        self.showConnections();
        self.sayAbout(c.kind == (i32)UXR_CONN_ACTION ? (u8*)"Connected the action " : (u8*)"Connected the outlet ", c.member);
        }

    // "key=value;key=value" into the control's attributes.
    static void setAttrs(UXRscDoc* d, UXRscTree* t, UXRscObject* o, u8* list)
        {
        if (list == (u8*)0)
            {
            return;
            }
        i32 i = (i32)0;
        while (list[i] != (u8)0)
            {
            i32 ks = i;
            while (list[i] != (u8)0 && list[i] != (u8)'=')
                {
                i = i + (i32)1;
                }
            i32 ke = i;
            if (list[i] == (u8)'=')
                {
                i = i + (i32)1;
                }
            i32 vs = i;
            while (list[i] != (u8)0 && list[i] != (u8)';')
                {
                i = i + (i32)1;
                }
            d.setAttrOf(t, o, RKMainController.part(list, ks, ke), RKMainController.part(list, vs, i));
            if (list[i] == (u8)';')
                {
                i = i + (i32)1;
                }
            }
        }
    static u8* part(u8* s, i32 a, i32 b)
        {
        u8* p = new u8[(u32)(b - a + (i32)1)];
        for (i32 k = a; k < b; k = k + (i32)1)
            {
            p[k - a] = s[k];
            }
        p[b - a] = (u8)0;
        return p;
        }

    // ---- the Identity tab ------------------------------------------------------------------
    void onIdentityWillChange(Object* key)
        {
        self.willEdit((u8*)"Typing", key);
        }
    // A class or a name changed: the outline's labels follow (without losing the selection).
    void onIdentityEdit()
        {
        dirty = true;
        self.showConnections();
        if (identityCtl.classField != (UXTextField*)0)
            {
            self.titleInspector(identityCtl.classField.text(), selKind == (i32)RKON_VIEW && selected != (UXRscObject*)0 ? UXRsc.defaultClassFor(selected.type) : (u8*)"Object");
            }
        if (formOutline != (UXOutlineView*)0 && doc != (UXRscDoc*)0)
            {
            outlineModel.build(doc, viewClass, viewOrient);
            formOutline.reloadData();
            }
        }
    // The inspector's heading: the selection's class, as Interface Builder's shows it.
    void titleInspector(u8* cls, u8* fallback)
        {
        if (inspectorCtl.typeLabel != (UXLabel*)0)
            {
            inspectorCtl.typeLabel.setText(cls != (u8*)0 && cls[0] != (u8)0 ? cls : fallback);
            }
        }
    // Select a placeholder or one of the document's objects: nothing on the canvas, the Identity
    // tab shows it.
    void selectPlaceholder(i32 kind, i32 topId)
        {
        history.breakRun();
        selected = (UXRscObject*)0;
        overlay.setSelection((UXRscObject*)0);
        if (selFrame != (RKSelectionFrame*)0)
            {
            selFrame.setHidden(true);
            }
        selKind = kind;
        selTop = topId;
        inspectorCtl.show((UXRscObject*)0);
        sizeCtl.show((UXRscObject*)0);
        if (kind == (i32)RKON_OWNER)
            {
            identityCtl.showOwner(doc);
            self.titleInspector(doc.ownerClass, (u8*)"File's Owner");
            }
        else if (kind == (i32)RKON_FIRSTR)
            {
            identityCtl.showFirstResponder(doc);
            self.titleInspector((u8*)0, (u8*)"First Responder");
            }
        else
            {
            identityCtl.showObject(doc, topId);
            UXRscTopObject* to = doc.topObjectById(topId);
            self.titleInspector(to != (UXRscTopObject*)0 ? to.cls : (u8*)0, (u8*)"Object");
            }
        if (self.shownTab() == (i32)1 || self.shownTab() == (i32)2)
            {
            self.showTab((i32)0); // a placeholder has nothing else to inspect
            }
        self.showConnections();
        }

    void onDesktop(UXControl* sender) : action
        {
        self.viewLayout((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE);
        }
    void onTablet(UXControl* sender) : action
        {
        self.viewLayout((i32)UXR_V_TABLET, viewClass == (i32)UXR_V_DESKTOP ? (i32)UXR_V_ORIENT_PORTRAIT : viewOrient);
        }
    void onPhone(UXControl* sender) : action
        {
        self.viewLayout((i32)UXR_V_PHONE, viewClass == (i32)UXR_V_DESKTOP ? (i32)UXR_V_ORIENT_PORTRAIT : viewOrient);
        }
    // Turn the device: portrait <-> landscape.  The desktop has no orientation.
    void onRotate(UXControl* sender) : action
        {
        if (viewClass == (i32)UXR_V_DESKTOP || viewClass == (i32)UXR_V_ANY)
            {
            self.say((u8*)"The desktop has no orientation");
            return;
            }
        self.viewLayout(viewClass, viewOrient == (i32)UXR_V_ORIENT_LANDSCAPE ? (i32)UXR_V_ORIENT_PORTRAIT : (i32)UXR_V_ORIENT_LANDSCAPE);
        }
    // A layout for the class and orientation being viewed, seeded as a one-time copy of the tree on
    // the canvas -- never a link to it (UXNB-V2 section 7).
    void onNewLayout(UXControl* sender) : action
        {
        if (doc == (UXRscDoc*)0 || shownTree < (i32)0 || shownTree >= doc.treeCount())
            {
            return;
            }
        UXRscTree* from = doc.treeAt(shownTree);
        self.willEdit((u8*)"New Layout", (Object*)0);
        UXRscTree* t = doc.addVariant(from, viewClass, viewOrient);
        if (t == (UXRscTree*)0)
            {
            history.discardLast();
            self.sayLayout((u8*)"There is already a ", (u8*)" layout");
            return;
            }
        dirty = true;
        RKMainController.deviceSize(t, viewClass, viewOrient);
        self.showResource(doc, doc.indexOfTree(t));
        self.sayLayout((u8*)"New ", (u8*)" layout");
        }
    // ---- the document on disk -------------------------------------------------
    // The file menu's three.  The panels are UXKit's (native where the platform has one), the bytes
    // go through UXFileIO (every native target), and what is written is a classic .rsc with, when the
    // document has layout variants, the UXNB v2 chunk after it.
    void onOpenDocument(UXMenuItem* sender)
        {
        u8* path = UXOpenPanel.run((u8*)"Open a resource", (u8*)".");
        if (path == (u8*)0)
            {
            return;
            }
        self.openPath(path);
        free((pointer)path);
        }
    void onSaveDocument(UXMenuItem* sender)
        {
        if (docPath == (u8*)0)
            {
            self.onSaveDocumentAs(sender);
            return;
            }
        self.saveTo(docPath);
        }
    void onSaveDocumentAs(UXMenuItem* sender)
        {
        u8* path = UXSavePanel.run((u8*)"Save the resource", (u8*)".", docPath != (u8*)0 ? RKMainController.baseName(docPath) : (u8*)"untitled.rsc");
        if (path == (u8*)0)
            {
            return;
            }
        self.saveTo(path);
        free((pointer)path);
        }
    // Read `path` and show it.  False (and says why) if it is unreadable or not a resource.
    bool openPath(u8* path)
        {
        Data* bytes = UXFileIO.read(path);
        if (bytes == (Data*)0)
            {
            self.say((u8*)"That file cannot be read");
            return false;
            }
        UXRscDoc* r = UXRscReader.read(bytes.bytes(), bytes.length());
        if (r == (UXRscDoc*)0)
            {
            self.say((u8*)"That is not a GEM resource file");
            return false;
            }
        // A new document: the old one's panes go with it.
        for (i32 i = (i32)0; i < (i32)panes.count(); i = i + (i32)1)
            {
            ((UXView* ?)panes.get((u32)i)).setHidden(true);
            }
        panes = new Array();
        maps = new Array();
        self.setDocPath(path);
        dirty = false;
        history.clear();
        // the app's classes, from its source: every .xc under the document's folder; then the
        // document's own declarations
        classBook = new RKClassBook();
        u8* dir = RKMainController.dirOf(path);
        i32 sources = classBook.loadTree(dir, (i32)4);
        classBook.loadFrom(r);
        identityCtl.book = classBook;
        variants.loadFrom(r);
        viewClass = (i32)UXR_V_DESKTOP;
        viewOrient = (i32)UXR_V_ORIENT_NONE;
        self.showResource(r, (i32)0);
        self.sayAbout((u8*)"Opened ", RKMainController.baseName(path));
        return true;
        }
    // Write the document to `path`; it becomes the document's file.  False (and says so) on failure,
    // with the file on disk untouched (UXFileIO writes atomically).
    bool saveTo(u8* path)
        {
        if (doc == (UXRscDoc*)0)
            {
            return false;
            }
        Data* bytes = UXRscWriter.write(doc);
        if (bytes == (Data*)0 || !UXFileIO.write(path, bytes))
            {
            self.sayAbout((u8*)"Could not save ", RKMainController.baseName(path));
            return false;
            }
        // Saved into another folder (a first save, say): the classes of the app there, as opening
        // the file from that folder would read them.
        u8* dir = RKMainController.dirOf(path);
        bool moved = docPath == (u8*)0 || !RKClassBook.seq(RKMainController.dirOf(docPath), dir);
        self.setDocPath(path);
        dirty = false;
        if (moved && classBook.loadTree(dir, (i32)4) > (i32)0 && identityCtl != (RKIdentity*)0)
            {
            identityCtl.reshow();
            }
        self.sayAbout((u8*)"Saved ", RKMainController.baseName(path));
        return true;
        }
    void setDocPath(u8* path)
        {
        if (path == docPath)
            {
            return;
            }
        Data* d = UXStr.toData(path);
        d.appendByte((u8)0);
        docPathStore = d;
        docPath = d.bytes();
        }
    // Everything before the last path component ("." when there is none).
    static u8* dirOf(u8* path)
        {
        i32 cut = (i32)-1;
        for (i32 i = (i32)0; path[i] != (u8)0; i = i + (i32)1)
            {
            if (path[i] == (u8)'/' || path[i] == (u8)'\\')
                {
                cut = i;
                }
            }
        if (cut < (i32)0)
            {
            return (u8*)".";
            }
        u8* d = new u8[(u32)(cut + (i32)1)];
        for (i32 i = (i32)0; i < cut; i = i + (i32)1)
            {
            d[i] = path[i];
            }
        d[cut] = (u8)0;
        return cut == (i32)0 ? (u8*)"/" : d;
        }
    // File > Add Class Source or Library: an .xc file, or a library whose built-in interface lists
    // its classes (a library dropped on the window comes here too).
    void onAddClasses(UXMenuItem* sender)
        {
        u8* path = UXOpenPanel.run((u8*)"Add a class source (.xc) or a library", (u8*)".");
        if (path == (u8*)0)
            {
            return;
            }
        self.addClasses(RKIdentity.dup(path));
        free((pointer)path);
        }
    // A file dropped on the window: a resource opens; a library or an .xc source adds its classes.
    // What a library item adds, at (cx, cy) on the form.
    static UXRscObject* objectFor(RKLibraryItem* it, i32 cx, i32 cy)
        {
        UXRscObject* o = UXRscObject.make(it.type, cx > (i32)0 ? cx : (i32)0, cy > (i32)0 ? cy : (i32)0, it.w, it.h);
        if (it.text != (u8*)0)
            {
            o.text = it.text;
            if (o.ted != (UXRscTedinfo*)0)
                {
                o.ted.text = it.text;
                }
            }
        if (it.type == (i32)UXR_T_FIELD)
            {
            o.flags = o.flags | (i32)UXR_F_EDITABLE;
            }
        return o;
        }
    // A library row dragged over the window: while it is over the form, the control itself
    // follows the pointer, centred where a drop would put it.  It is a preview only, in no
    // document; the drop places the real one (onItemDrop).
    void onItemHover(u8* item, i32 window, i32 x, i32 y)
        {
        if (outlineModel.draggedRow(item) != (RKOutlineNode*)0)
            {
            self.wireHover(x, y);
            return;
            }
        RKLibraryItem* it = x >= (i32)0 ? library.named(item) : (RKLibraryItem*)0;
        UXView* form = (UXView*)0; // the shown form's pane: its controls are realized straight into it
        if (doc != (UXRscDoc*)0 && shownTree >= (i32)0 && shownTree < (i32)panes.count())
            {
            form = (UXView* ?)panes.get((u32)shownTree);
            }
        bool over = false;
        if (it != (RKLibraryItem*)0 && it.type != (i32)RKLIB_OBJECT && form != (UXView*)0 && overlay != (RKEditOverlay*)0)
            {
            UXRect a = overlay.absoluteFrame();
            over = x >= (i32)a.x && y >= (i32)a.y && x < (i32)a.x + (i32)a.w && y < (i32)a.y + (i32)a.h;
            }
        if (!over || it != previewItem)
            {
            if (preview != (UXView*)0)
                {
                preview.removeFromSuperview();
                preview = (UXView*)0;
                }
            previewItem = (RKLibraryItem*)0;
            }
        if (over)
            {
            i32 cx = (i32)0;
            i32 cy = (i32)0;
            overlay.toCanvas(x, y, &cx, &cy);
            UXRect f = UXGeom.make((i16)(cx - it.w / (i32)2), (i16)(cy - it.h / (i32)2), (i16)it.w, (i16)it.h);
            if (preview == (UXView*)0)
                {
                UXRscObject* o = RKMainController.objectFor(it, (i32)0, (i32)0);
                preview = UXRsc.viewFor(o, it.cls);
                if (preview != (UXView*)0)
                    {
                    form.addSubview(preview, f);
                    UXRsc.applyState(preview, o);
                    previewItem = it;
                    self.raiseOverlay();
                    }
                }
            else
                {
                preview.setFrame(f);
                }
            }
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    // A connection's line, window points, with `hot` (on the canvas) framed: drawn above everything
    // where the backend can, so it crosses the outline and the inspector, and on the canvas where not.
    void drawLine(i32 wx0, i32 wy0, i32 wx1, i32 wy1, UXRect hot)
        {
        UXRect oa = overlay.absoluteFrame();
        UXWindow* w = self.window();
        UXRect wh = hot;
        if ((i32)hot.w > (i32)0)
            {
            wh = UXGeom.make((i16)((i32)hot.x + (i32)oa.x), (i16)((i32)hot.y + (i32)oa.y), hot.w, hot.h);
            }
        if (w != (UXWindow*)0 && w.showLine(wx0, wy0, wx1, wy1, wh))
            {
            return;
            }
        overlay.showLine(wx0 - (i32)oa.x, wy0 - (i32)oa.y, wx1 - (i32)oa.x, wy1 - (i32)oa.y, hot);
        }
    void eraseLine(void)
        {
        UXWindow* w = self.window();
        if (w != (UXWindow*)0)
            {
            w.hideLine();
            }
        overlay.hideLine();
        }
    // The window the editor is in, or 0.
    UXWindow* window(void)
        {
        if (gApp == (UXApplication*)0 || overlay == (RKEditOverlay*)0 || overlay.owner == (UXViewTree*)0)
            {
            return (UXWindow*)0;
            }
        return gApp.windowWithHandle(overlay.owner.winHandle);
        }
    // An outline row dragged out: a line from where its drag began, on the row, to the pointer, with
    // the control under the pointer marked.  (-1, -1): the drag has ended.
    void wireHover(i32 x, i32 y)
        {
        if (overlay == (RKEditOverlay*)0)
            {
            return;
            }
        if (x < (i32)0)
            {
            self.eraseLine();
            wireIn = false;
            }
        else if (!wireIn)
            {
            wireIn = true; // the first report is where the drag began, on its row
            wireInX = x;
            wireInY = y;
            }
        else
            {
            RKEnd* over = self.endAtWindow(x, y);
            UXRect hot = UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
            if (over != (RKEnd*)0 && over.isView())
                {
                hot = overlay.onCanvas(overlay.drag.canvasRect(over.obj));
                }
            self.sayOver(over);
            self.drawLine(wireInX, wireInY, x, y, hot);
            }
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    // A library row dragged onto the form: placed centred where it is dropped.  A drop outside the form, or of an Object, is a pick.
    void onItemDrop(u8* item, i32 window, i32 x, i32 y)
        {
        self.onItemHover(item, window, (i32)-1, (i32)-1); // the preview goes: the real one is placed
        RKEnd* from = RKMainController.endOf(outlineModel.draggedRow(item));
        if (from != (RKEnd*)0)
            {
            // an outline row dragged onto a control, or onto another row: a connection
            RKEnd* to = self.endAtWindow(x, y);
            if (to == (RKEnd*)0)
                {
                self.say((u8*)"No connection: let go over a control or an object");
                return;
                }
            self.offerWire(from, to, x, y);
            return;
            }
        RKLibraryItem* it = library.named(item);
        if (it == (RKLibraryItem*)0)
            {
            return;
            }
        if (it.type == (i32)RKLIB_OBJECT || overlay == (RKEditOverlay*)0)
            {
            self.libraryPick(it);
            return;
            }
        UXRect a = overlay.absoluteFrame();
        if (x < (i32)a.x || y < (i32)a.y || x >= (i32)a.x + (i32)a.w || y >= (i32)a.y + (i32)a.h)
            {
            self.libraryPick(it);
            return;
            }
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        overlay.toCanvas(x, y, &cx, &cy);
        placing = it;
        self.placeAt(cx - it.w / (i32)2, cy - it.h / (i32)2); // centred under the pointer
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    void onFileDrop(u8* path, i32 window, i32 x, i32 y)
        {
        u8* p = RKIdentity.dup(path);
        i32 l = UXRscTree.len(p);
        if (l > (i32)4 && p[l - (i32)4] == (u8)'.' && (p[l - (i32)3] | (u8)32) == (u8)'r' &&
            (p[l - (i32)2] | (u8)32) == (u8)'s' && (p[l - (i32)1] | (u8)32) == (u8)'c')
            {
            self.openPath(p);
            return;
            }
        self.addClasses(p);
        }
    bool addClasses(u8* path)
        {
        i32 n = (i32)-1;
        i32 l = UXRscTree.len(path);
        bool source = l > (i32)3 && path[l - (i32)3] == (u8)'.' && path[l - (i32)2] == (u8)'x' && path[l - (i32)1] == (u8)'c';
        if (source)
            {
            n = classBook.loadSource(path);
            }
        else
            {
            n = classBook.loadLibrary(path);
            }
        if (n < (i32)0)
            {
            self.say(source ? (u8*)"That source cannot be read" : (u8*)"That is not a library with an interface");
            return false;
            }
        self.sayAbout((u8*)"Read classes from ", RKMainController.baseName(path));
        identityCtl.reshow();
        self.showConnections();
        return true;
        }
    // The last path component (it points into `path`).
    static u8* baseName(u8* path)
        {
        i32 cut = (i32)0;
        for (i32 i = (i32)0; path[i] != (u8)0; i = i + (i32)1)
            {
            if (path[i] == (u8)'/' || path[i] == (u8)'\\')
                {
                cut = i + (i32)1;
                }
            }
        return &path[cut];
        }
    void sayAbout(u8* what, u8* name)
        {
        Data* d = UXStr.toData(what);
        d.appendBytes(name, UXRscTree.len(name));
        d.appendByte((u8)0);
        lastSaid = d;
        self.say(UXStr.cstr(d));
        }

    // The toolbar is one control: which item fired is its selection's tag.
    void onToolbar(UXControl* sender) : action
        {
        UXToolbar* tb = (UXToolbar* ?)(Object*)sender;
        if (tb == (UXToolbar*)0 || tb.selection() < (i32)0)
            {
            return;
            }
        i32 tag = tb.nativeItemTag(tb.selection());
        if (tag == (i32)RKTB_NEW)
            {
            self.onNewForm(sender);
            }
        else if (tag == (i32)RKTB_DELETE)
            {
            self.onDelete(sender);
            }
        else if (tag == (i32)RKTB_DESKTOP)
            {
            self.onDesktop(sender);
            }
        else if (tag == (i32)RKTB_TABLET)
            {
            self.onTablet(sender);
            }
        else if (tag == (i32)RKTB_PHONE)
            {
            self.onPhone(sender);
            }
        else if (tag == (i32)RKTB_ROTATE)
            {
            self.onRotate(sender);
            }
        else if (tag == (i32)RKTB_NEWLAYOUT)
            {
            self.onNewLayout(sender);
            }
        }

    // Show the shown form's layout for `klass` at `orient`, if it has one.  If it has none, the
    // canvas stays where it is and says so: "no layout -- create one", never "inheriting desktop"
    // (UXNB-V2 section 1: the fallback chain is a runtime last resort, not a design relationship).
    // An orientation-less device layout serves both orientations, so it is shown for either.
    void viewLayout(i32 klass, i32 orient)
        {
        viewClass = klass;
        viewOrient = orient;
        self.reflectDevice();
        if (doc == (UXRscDoc*)0 || shownTree < (i32)0 || shownTree >= doc.treeCount())
            {
            return;
            }
        UXRscTree* cur = doc.treeAt(shownTree);
        UXRscForm* f = doc.formOf(cur);
        UXRscVariant* v = (UXRscVariant*)0;
        if (f != (UXRscForm*)0)
            {
            v = f.find(klass, orient);
            if (v == (UXRscVariant*)0 && orient != (i32)UXR_V_ORIENT_NONE)
                {
                v = f.find(klass, (i32)UXR_V_ORIENT_NONE);
                }
            }
        else if (klass == (i32)UXR_V_DESKTOP)
            {
            // a form with one layout: that layout is its desktop one
            self.sayLayout((u8*)"", (u8*)" layout");
            return;
            }
        if (v == (UXRscVariant*)0)
            {
            self.sayLayout((u8*)"No ", (u8*)" layout -- New Layout creates one");
            return;
            }
        self.showResource(doc, doc.indexOfTree(v.tree));
        self.sayLayout((u8*)"", (u8*)" layout");
        }
    // "<prefix>phone portrait<suffix>", for the layout being viewed.
    void sayLayout(u8* prefix, u8* suffix)
        {
        u8* what = viewClass == (i32)UXR_V_PHONE ? (u8*)"phone" : (viewClass == (i32)UXR_V_TABLET ? (u8*)"tablet" : (u8*)"desktop");
        u8* how = viewOrient == (i32)UXR_V_ORIENT_PORTRAIT ? (u8*)" portrait" : (viewOrient == (i32)UXR_V_ORIENT_LANDSCAPE ? (u8*)" landscape" : (u8*)"");
        Data* d = UXStr.toData(prefix);
        d.appendBytes(what, UXRscTree.len(what));
        d.appendBytes(how, UXRscTree.len(how));
        d.appendBytes(suffix, UXRscTree.len(suffix));
        d.appendByte((u8)0);
        lastSaid = d;
        self.say(UXStr.cstr(d));
        }
    Data* lastSaid; // keeps the status text's bytes alive while the label shows them

    // Show a resource's tree on the canvas as REAL widgets.  Takes a parsed
    // model rather than a path: file I/O is the platform layer's job, and
    // keeping it out of here is what lets the controller build everywhere.
    //
    // Each tree gets its OWN container inside the canvas, built once and then
    // shown or hidden — the same swap UXTabView makes.  The alternative,
    // tearing the old widgets out, means removing children by index while the
    // indices are shifting underneath, and removeFromSuperview does not even
    // clear the parent's subview array; hiding is both safer and cheaper, and
    // it keeps a tree's selection state alive when the designer flips back.
    i32 showResource(UXRscDoc* r, i32 treeIndex)
        {
        doc = r;
        if (r == (UXRscDoc*)0 || canvas == (UXView*)0)
            {
            return (i32)0;
            }
        if (treeIndex < (i32)0 || treeIndex >= r.treeCount())
            {
            return (i32)0;
            }
        shownTree = treeIndex;

        // A selection points into ONE tree's widgets, so it does not survive
        // a switch — better to drop it than to leave a frame over the wrong
        // form.
        selected = (UXRscObject*)0;
        selKind = (i32)0;
        inspectorCtl.show((UXRscObject*)0);
        sizeCtl.show((UXRscObject*)0);
        identityCtl.showNothing();
        if (selFrame != (RKSelectionFrame*)0)
            {
            selFrame.setHidden(true);
            }

        self.ensureBackdrop();
        while ((i32)panes.count() <= treeIndex)
            {
            UXView* pane = new UXView();
            canvas.addSubview(pane, self.formArea());
            pane.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
            RKCanvas* map = new RKCanvas();
            UXRscTree* rt = r.treeAt((i32)panes.count());
            i32 built = map.realizeIn(r, rt, (i32)RKWiring.themeOf(r, rt), pane);
            panes.add(pane);
            maps.add(map);
            }
        for (i32 i = (i32)0; i < (i32)panes.count(); i = i + (i32)1)
            {
            ((UXView* ?)panes.get((u16)i)).setHidden(i != treeIndex);
            }
        canvasMap = (RKCanvas* ?)maps.get((u16)treeIndex);
        self.updatePanel();

        // The overlay edits ONE form at a time, so it follows the shown tree.
        overlay.setRoot(r.treeAt(treeIndex).root);
        overlay.setSelection((UXRscObject*)0);
        self.raiseOverlay();

        if (formOutline != (UXOutlineView*)0)
            {
            outlineModel.build(r, viewClass, viewOrient);
            formOutline.setOutlineSource(outlineModel);
            formOutline.reloadData();
            }
        return (i32)canvasMap.objs.count();
        }

    // ---- selection ---------------------------------------------------------
    // The outline is a table underneath, so selection arrives as a ROW; the
    // row's item is the RKOutlineNode we put there, which is what makes the
    // two panes one editor rather than two independent views.
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        if (libraryTable != (UXTableView*)0 && t == libraryTable)
            {
            self.libraryPick(library.itemAt(row));
            return;
            }
        if (chooser != (RKWireChooser*)0 && t == chooser.table)
            {
            self.choose(row);
            return;
            }
        if (formOutline == (UXOutlineView*)0)
            {
            return;
            }
        UXOutlineNode* vn = formOutline.nodeAt(row);
        if (vn == (UXOutlineNode*)0)
            {
            return;
            }
        RKOutlineNode* n = (RKOutlineNode* ?)vn.item;
        if (n == (RKOutlineNode*)0)
            {
            return;
            }

        // A FORM row switches the canvas; a VIEW row selects within it; the rest are not on the
        // canvas at all, and the Identity tab shows them.
        if (n.kind == (i32)RKON_FORM)
            {
            i32 count = self.showResource(doc, n.treeIndex);
            self.say(n.label);
            return;
            }
        if (n.kind == (i32)RKON_VIEW)
            {
            self.selectObject(n.obj);
            overlay.setSelection(n.obj);
            self.say(n.label);
            return;
            }
        self.selectPlaceholder(n.kind, n.topId);
        self.say(n.label);
        }

    // Put the overlay over the object's widget.  Frames are parent-relative,
    // so the overlay's position is the widget's absolute frame less the
    // canvas's — the one place in Rocks that needs absolute coordinates.
    void selectObject(UXRscObject* o)
        {
        history.breakRun(); // typing into another object is another step
        selected = o;
        selKind = o != (UXRscObject*)0 ? (i32)RKON_VIEW : (i32)0;
        inspectorCtl.doc = doc;
        inspectorCtl.tree = self.shownTreeOrNull();
        sizeCtl.doc = doc;
        sizeCtl.tree = inspectorCtl.tree;
        inspectorCtl.show(o); // a NEW selection re-renders the pane
        sizeCtl.show(o);
        if (o != (UXRscObject*)0 && doc != (UXRscDoc*)0 && shownTree >= (i32)0 && shownTree < doc.treeCount())
            {
            identityCtl.showView(doc, doc.treeAt(shownTree), o);
            self.titleInspector(doc.classOf(doc.treeAt(shownTree), o), UXRsc.defaultClassFor(o.type));
            }
        else
            {
            identityCtl.showNothing();
            }
        self.showConnections();
        self.placeFrame(o);
        }

    // Position the overlay over an object's widget, without touching the pane.
    void placeFrame(UXRscObject* o)
        {
        if (canvas == (UXView*)0)
            {
            return;
            }
        UXView* w = canvasMap.viewFor(o);
        if (w == (UXView*)0)
            {
            return;
            }
        UXRect wa = w.absoluteFrame();
        UXRect ca = canvas.absoluteFrame();
        if (selFrame != (RKSelectionFrame*)0)
            {
            selFrame.setHidden(false);
            }
        UXRect f = UXGeom.make((i16)((i32)wa.x - (i32)ca.x), (i16)((i32)wa.y - (i32)ca.y),
                               wa.w, wa.h);
        if (selFrame == (RKSelectionFrame*)0)
            {
            selFrame = new RKSelectionFrame();
            // The frame is drawn ABOVE the overlay so its handles show, which
            // means it is also what a press on a handle hits.  Forwarding
            // straight back to the overlay keeps one drag implementation
            // instead of a second one living in the selection art.
            selFrame.press = &overlay.mouseDown;
            canvas.addSubview(selFrame, f);
            }
        else
            {
            selFrame.setFrame(f);
            }
        selFrame.setNeedsDisplay();
        }

    UXRscObject* selectedObject(void)
        {
        return selected;
        }

    // ---- direct manipulation ------------------------------------------------

    // Put the input surface, and then the selection art, back on top.
    //
    // Order is not cosmetic here.  Panes are created lazily — one the first
    // time each form is shown — and both the driver's hit-test and AppKit's
    // pick the LAST matching sibling, so a pane added after the overlay would
    // sit in front of it and the real widgets would start eating clicks again.
    // The selection frame goes above the overlay so its handles are visible,
    // and forwards its own presses back down so grabbing a handle still works.
    void raiseOverlay(void)
        {
        if (canvas == (UXView*)0)
            {
            return;
            }
        overlay.removeFromSuperview();
        canvas.addSubview(overlay, canvas.bounds());
        overlay.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        if (selFrame != (RKSelectionFrame*)0)
            {
            UXRect f = selFrame.frame();
            bool hidden = selFrame.isHidden(); // re-adding a view shows it: keep a hidden frame hidden
            selFrame.removeFromSuperview();
            canvas.addSubview(selFrame, f);
            selFrame.setHidden(hidden);
            }
        }

    // A press landed.  Nothing (bare form background) is a DESELECT, which is
    // what makes clicking away from a control feel right rather than sticky.
    void onPick(UXRscObject* o)
        {
        // the state before a drag, should this press become one
        pressCopy = doc != (UXRscDoc*)0 && o != (UXRscObject*)0 ? doc.deepCopy() : (UXRscDoc*)0;
        pressSel = self.indexInShown(o);
        dragging = false;
        if (o == (UXRscObject*)0 && backdrop != (RKBackdrop*)0 && backdrop.onPanel(overlay.pressX, overlay.pressY) &&
            doc != (UXRscDoc*)0 && shownTree >= (i32)0 && shownTree < doc.treeCount())
            {
            // the panel's background: the form itself, so the Size tab can change how big it is
            if (selFrame != (RKSelectionFrame*)0)
                {
                selFrame.setHidden(true);
                }
            overlay.setSelection((UXRscObject*)0);
            self.selectObject(doc.treeAt(shownTree).root);
            self.say((u8*)"The form: its size is on the Size tab");
            return;
            }
        if (o == (UXRscObject*)0)
            {
            selected = (UXRscObject*)0;
            selKind = (i32)0;
            overlay.setSelection((UXRscObject*)0);
            inspectorCtl.show((UXRscObject*)0);
            sizeCtl.show((UXRscObject*)0);
            identityCtl.showNothing();
            if (selFrame != (RKSelectionFrame*)0)
                {
                selFrame.setHidden(true);
                }
            self.say((u8*)"—");
            return;
            }
        self.selectObject(o);
        overlay.setSelection(o);
        }

    // One step of a live drag.  The widget and the frame move; the INSPECTOR
    // does not, because rebuilding its rows mid-drag would throw away the very
    // fields the designer is about to read.  It catches up on release.
    void onDragStep(UXRscObject* o)
        {
        if (o == (UXRscObject*)0)
            {
            return;
            }
        dirty = true;
        if (!dragging && pressCopy != (UXRscDoc*)0)
            {
            history.push(pressCopy, (u8*)"Move", shownTree, pressSel);
            pressCopy = (UXRscDoc*)0;
            }
        dragging = true;
        UXView* w = canvasMap.viewFor(o);
        if (w != (UXView*)0)
            {
            w.setFrame(UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
            }
        self.placeFrame(o);
        self.say(RKMainController.geomText(geomBuf, o));
        }

    void onDragEnd(UXRscObject* o)
        {
        dragging = false;
        pressCopy = (UXRscDoc*)0;
        if (o == (UXRscObject*)0)
            {
            return;
            }
        // A drop can change what contains what: dropped onto a box it goes in, dragged out it comes
        // out (UXRscTree.reparentByGeometry).  The widgets nest as the model does, so a changed nesting
        // means this form's widgets are rebuilt.
        if (doc != (UXRscDoc*)0)
            {
            UXRscTree* t = doc.treeAt(shownTree);
            self.markContainers(t);
            if (t.reparentByGeometry() > (i32)0)
                {
                self.rebuildShownPane();
                dirty = true;
                }
            }
        sizeCtl.show(o); // the X/Y/W/H fields now read where it landed
        self.placeFrame(o);
        }

    // Realize the shown tree's widgets afresh, in place of its old pane (which is hidden, not
    // removed: see showResource on why panes are never torn out of the canvas).
    void rebuildShownPane(void)
        {
        if (canvas == (UXView*)0 || shownTree < (i32)0 || shownTree >= (i32)panes.count())
            {
            return;
            }
        ((UXView* ?)panes.get((u32)shownTree)).setHidden(true);
        UXView* pane = new UXView();
        canvas.addSubview(pane, self.formArea());
        pane.setAutoresizeMask((i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
        RKCanvas* map = new RKCanvas();
        map.realizeIn(doc, doc.treeAt(shownTree), (i32)RKWiring.themeOf(doc, doc.treeAt(shownTree)), pane);
        panes.set((u32)shownTree, pane);
        maps.set((u32)shownTree, map);
        canvasMap = map;
        self.raiseOverlay();
        }

    // "20, 40   60 x 20" — the running read-out a designer actually watches
    // while dragging.  Written into a buffer the controller owns and reuses:
    // this runs once per pointer step, and a fresh allocation each time would
    // make a drag allocate hundreds of strings for no reason.
    static u8* geomText(u8* b, UXRscObject* o)
        {
        i32 n = (i32)0;
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.x));
        n = RKMainController.put(b, n, (u8*)", ");
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.y));
        n = RKMainController.put(b, n, (u8*)"   ");
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.w));
        n = RKMainController.put(b, n, (u8*)" x ");
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.h));
        b[n] = (u8)0;
        return b;
        }
    static i32 put(u8* b, i32 n, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0 && n < (i32)62)
            {
            b[n] = s[i];
            n = n + (i32)1;
            i = i + (i32)1;
            }
        return n;
        }

    // ---- the toggles --------------------------------------------------------
    // Both start ON, which is the useful default: an editor whose snapping has
    // to be switched on is an editor whose first forms are all one pixel out.
    // They are menu items rather than a preference because the moment you need
    // them off is the moment you are fighting them, and that moment wants one
    // keystroke, not a dialog.
    void onToggleSnap(UXMenuItem* sender)
        {
        overlay.drag.snapOn = !overlay.drag.snapOn;
        self.reflectToggles();
        self.say(overlay.drag.snapOn ? (u8*)"Snap on" : (u8*)"Snap off");
        }
    void onToggleGuides(UXMenuItem* sender)
        {
        overlay.drag.guidesOn = !overlay.drag.guidesOn;
        self.reflectToggles();
        self.say(overlay.drag.guidesOn ? (u8*)"Guides on" : (u8*)"Guides off");
        }
    // The tick in the menu is a VIEW of the state, so it is redrawn from the
    // state rather than flipped alongside it — the two cannot drift apart.
    void reflectToggles(void)
        {
        if (menuBar == (UXMenuBar*)0 || viewMenu < (i32)0)
            {
            return;
            }
        menuBar.setChecked((u16)viewMenu, (u16)snapItem, overlay.drag.snapOn);
        menuBar.setChecked((u16)viewMenu, (u16)guideItem, overlay.drag.guidesOn);
        }
    bool snapEnabled(void)
        {
        return overlay.drag.snapOn;
        }
    bool guidesEnabled(void)
        {
        return overlay.drag.guidesOn;
        }

    // ---- undo ------------------------------------------------------------------
    // Snapshot the document before an edit (RKUndoStack.record; a repeat of `key` is the same step).
    void willEdit(u8* label, Object* key)
        {
        history.record(doc, label, shownTree, self.indexInShown(selected), key);
        }
    void onInspectorWillChange(UXRscObject* o, Object* key)
        {
        self.willEdit(key != (Object*)0 ? (u8*)"Typing" : (u8*)"Change", key);
        }
    // An object's pre-order index in the shown tree, or -1: how a selection outlives a snapshot,
    // whose objects are copies.
    i32 indexInShown(UXRscObject* o)
        {
        if (o == (UXRscObject*)0 || doc == (UXRscDoc*)0 || shownTree < (i32)0 || shownTree >= doc.treeCount())
            {
            return (i32)-1;
            }
        Array<UXRscObject>* all = doc.treeAt(shownTree).allObjects();
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            if ((UXRscObject* ?)all.get(i) == o)
                {
                return (i32)i;
                }
            }
        return (i32)-1;
        }
    void onUndo(UXMenuItem* sender)
        {
        u8* what = history.undoLabel();
        RKUndoStep* s = history.undo(doc, shownTree, self.indexInShown(selected));
        if (s == (RKUndoStep*)0)
            {
            self.say((u8*)"Nothing to undo");
            return;
            }
        self.restore(s);
        self.sayAbout((u8*)"Undo ", what);
        }
    void onRedo(UXMenuItem* sender)
        {
        u8* what = history.redoLabel();
        RKUndoStep* s = history.redo(doc, shownTree, self.indexInShown(selected));
        if (s == (RKUndoStep*)0)
            {
            self.say((u8*)"Nothing to redo");
            return;
            }
        self.restore(s);
        self.sayAbout((u8*)"Redo ", what);
        }
    // Show a step's document, its tree and its selection.  Every pane is rebuilt: the step's objects
    // are not the ones the old widgets were built from.
    void restore(RKUndoStep* s)
        {
        for (i32 i = (i32)0; i < (i32)panes.count(); i = i + (i32)1)
            {
            ((UXView* ?)panes.get((u32)i)).setHidden(true);
            }
        panes = new Array();
        maps = new Array();
        dirty = true;
        i32 t = s.tree;
        if (t < (i32)0 || t >= s.doc.treeCount())
            {
            t = (i32)0;
            }
        classBook.loadFrom(s.doc); // a declaration undone goes with its step
        variants.loadFrom(s.doc);
        self.showResource(s.doc, t);
        if (s.selection >= (i32)0)
            {
            Array<UXRscObject>* all = s.doc.treeAt(t).allObjects();
            if (s.selection < (i32)all.count())
                {
                UXRscObject* o = (UXRscObject* ?)all.get((u32)s.selection);
                self.selectObject(o);
                overlay.setSelection(o);
                }
            }
        }

    // An inspector edit changed the MODEL; the canvas has to catch up.  Only
    // the one widget is touched rather than rebuilding the form: a rebuild
    // would destroy the very widget the designer is typing into, and take the
    // keyboard focus with it.
    void onInspectorEdit(UXRscObject* o)
        {
        if (o == (UXRscObject*)0 || canvas == (UXView*)0)
            {
            return;
            }
        dirty = true;
        UXRscTree* ft = self.shownTreeOrNull();
        if (ft != (UXRscTree*)0 && o == ft.root)
            {
            self.updatePanel(); // the form's own size
            return;
            }
        // a UXKit control's settings: its widget is made again with them
        if (inspectorCtl.lastWasAttr)
            {
            inspectorCtl.lastWasAttr = false;
            self.rebuildShownPane();
            self.placeFrame(o);
            return;
            }
        // what the control says is shared by the form's layouts, unless this one varies it
        RKProperty* p = inspectorCtl.lastProp;
        inspectorCtl.lastProp = (RKProperty*)0;
        UXRscTree* t = self.shownTreeOrNull();
        if (p != (RKProperty*)0 && t != (UXRscTree*)0 && variants.share(doc, t, o, p) > (i32)0)
            {
            self.staleOtherLayouts(t);
            }
        UXView* w = canvasMap.viewFor(o);
        if (w != (UXView*)0)
            {
            w.setFrame(UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
            UXRsc.applyState(w, o); // enabled, hidden, checked, selected
            UXRsc.applyText(w, o);
            w.setNeedsDisplay();
            }
        // Move the frame, but do NOT re-show the inspector: the edit came FROM
        // it, and show() rebuilds every row — destroying the widget being
        // typed into and taking the keyboard focus with it.  Same rule as the
        // canvas, in the other direction.
        self.placeFrame(o);
        }

    // A form factor with NO variant reads "no layout — create one", never
    // "inheriting desktop" (UXNB-V2 §1): the chain is a runtime last resort,
    // not a design relationship, and the editor must not teach otherwise.
    void say(u8* msg)
        {
        if (statusLabel != (UXLabel*)0)
            {
            statusLabel.setText(msg);
            }
        }
    }
