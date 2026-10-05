// RKMainController.xc — the main window's controller, written as a NIB CLIENT.
//
// This class constructs nothing.  It declares what it needs to talk to
// (`outlet`) and what it can be told (`:action`), and something else supplies
// the views: today RKMainBuilder, building them in code; later a nib that
// Rocks itself authored.  That is the whole bootstrap plan — swap the builder
// file, keep this one — and it only works if the controller never reaches out
// and makes a view for itself.
//
// The `outlet` / `:action` decorations auto-conform this class to
// UXDesignable, and the compiler synthesises setOutlet/wireAction from them
// (bug 026).  Both the code builder and the nib loader drive those SAME two
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
#import "UXData.xc"
#import "UXFileIO.xc"
#import "UXOpenPanel.xc"
#import "UXSavePanel.xc"
#import "UXMenu.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
#import "RKUndo.xc"
#import "RKIdentity.xc"
#import "RKLibrary.xc"
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
    RKLibrary* library;
    RKLibraryItem* placing;         // armed by a library pick: the next canvas press places it
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
    UXData* docPathStore;

    void init(void)
        {
        selectedForm = (i32)-1;
        dirty = false;
        viewClass = (i32)UXR_V_DESKTOP;
        viewOrient = (i32)UXR_V_ORIENT_NONE;
        docPath = (u8*)0;
        docPathStore = (UXData*)0;
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
        library = new RKLibrary();
        placing = (RKLibraryItem*)0;
        selKind = (i32)0;
        selTop = (i32)0;
        overlay.placeAt = &self.placeAt;
        deviceBar = (UXSegmentedControl*)0;
        inspectorTabs = (UXSegmentedControl*)0;
        libraryTable = (UXTableView*)0;
        librarySearch = (UXTextField*)0;
        history = new RKUndoStack();
        pressCopy = (UXRscDoc*)0;
        pressSel = (i32)-1;
        dragging = false;
        lastSaid = (UXData*)0;
        formOutline = (UXOutlineView*)0;
        canvas = (UXView*)0;
        inspector = (UXView*)0;
        statusLabel = (UXLabel*)0;
        }

    // ---- actions: what the UI can ask for ----------------------------------
    // Each is wired by NAME, so the builder and a nib reach them identically.
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
        t.root.addChild(o);
        t.reparentByGeometry();
        doc.ensureLogicalId(t, o);
        dirty = true;
        self.rebuildShownPane();
        self.showResource(doc, shownTree);
        self.selectObject(o);
        overlay.setSelection(o);
        self.sayAbout((u8*)"Added a ", it.name);
        return true;
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
        if (identityCtl.classField != (UXTextField*)0)
            {
            self.titleInspector(identityCtl.classField.text(), selKind == (i32)RKON_VIEW && selected != (UXRscObject*)0 ? UXNib.defaultClassFor(selected.type) : (u8*)"Object");
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
        UXData* bytes = UXFileIO.read(path);
        if (bytes == (UXData*)0)
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
        UXData* bytes = UXRscWriter.write(doc);
        if (bytes == (UXData*)0 || !UXFileIO.write(path, bytes))
            {
            self.sayAbout((u8*)"Could not save ", RKMainController.baseName(path));
            return false;
            }
        self.setDocPath(path);
        dirty = false;
        self.sayAbout((u8*)"Saved ", RKMainController.baseName(path));
        return true;
        }
    void setDocPath(u8* path)
        {
        if (path == docPath)
            {
            return;
            }
        UXData* d = UXData.fromString(path);
        d.appendByte((u8)0);
        docPathStore = d;
        docPath = d.bytes();
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
        UXData* d = UXData.fromString(what);
        d.appendBytes(name, UXRscTree.len(name));
        d.appendByte((u8)0);
        lastSaid = d;
        self.say(d.bytes());
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
        UXData* d = UXData.fromString(prefix);
        d.appendBytes(what, UXRscTree.len(what));
        d.appendBytes(how, UXRscTree.len(how));
        d.appendBytes(suffix, UXRscTree.len(suffix));
        d.appendByte((u8)0);
        lastSaid = d;
        self.say(d.bytes());
        }
    UXData* lastSaid; // keeps the status text's bytes alive while the label shows them

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

        while ((i32)panes.count() <= treeIndex)
            {
            UXView* pane = new UXView();
            canvas.addSubview(pane, canvas.bounds());
            RKCanvas* map = new RKCanvas();
            i32 built = map.realize(r.treeAt((i32)panes.count()), pane);
            panes.add(pane);
            maps.add(map);
            }
        for (i32 i = (i32)0; i < (i32)panes.count(); i = i + (i32)1)
            {
            ((UXView* ?)panes.get((u16)i)).setHidden(i != treeIndex);
            }
        canvasMap = (RKCanvas* ?)maps.get((u16)treeIndex);

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
        inspectorCtl.show(o); // a NEW selection re-renders the pane
        sizeCtl.show(o);
        if (o != (UXRscObject*)0 && doc != (UXRscDoc*)0 && shownTree >= (i32)0 && shownTree < doc.treeCount())
            {
            identityCtl.showView(doc, doc.treeAt(shownTree), o);
            self.titleInspector(doc.classOf(doc.treeAt(shownTree), o), UXNib.defaultClassFor(o.type));
            }
        else
            {
            identityCtl.showNothing();
            }
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
        if (selFrame != (RKSelectionFrame*)0)
            {
            UXRect f = selFrame.frame();
            selFrame.removeFromSuperview();
            canvas.addSubview(selFrame, f);
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
        if (doc != (UXRscDoc*)0 && doc.treeAt(shownTree).reparentByGeometry() > (i32)0)
            {
            self.rebuildShownPane();
            dirty = true;
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
        canvas.addSubview(pane, canvas.bounds());
        RKCanvas* map = new RKCanvas();
        map.realize(doc.treeAt(shownTree), pane);
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
        UXView* w = canvasMap.viewFor(o);
        if (w != (UXView*)0)
            {
            w.setFrame(UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
            UXNib.applyState(w, o); // enabled, hidden, checked, selected
            UXNib.applyText(w, o);
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
