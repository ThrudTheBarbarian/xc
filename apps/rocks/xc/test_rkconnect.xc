// test_rkconnect.xc — connections, from the designer to the running app.
//
// A form with a desktop and a phone layout.  The phone has no Stop button; it stops with a Done
// button of its own.  Rocks reads PlayerController's outlets and actions from what the app is
// made of, never a generated side file: from its source (fixture_player.xc, path in RK_SRC), and
// from a library built from it (path in RK_LIB), dropped on the window.  Then, through the editor:
//   - Play -> the controller offers its actions, and onPlay is connected for every layout;
//   - the controller -> Play offers playButton (a UXButton* outlet) and not titleField;
//   - on the desktop, Stop -> onStop for this layout only; on the phone, Done -> onStop likewise;
//   - the Connections tab shows them, changes a scope, breaks one, and undo puts it back.
// Finally the document is written, and UXNib loads it for the desktop and for the phone with the
// real PlayerController: each layout's buttons fire the actions wired for that layout.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "UXRscWrite.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"
#import "fixture_player.xc"

u8* getenv(u8* name);
i32 ux_ak_test_drop_file(i32 handle, u8* path, i32 x, i32 y);
i32 ux_ak_test_hit(i32 handle, i32 x, i32 y);
i32 ux_ak_test_drop_item(i32 handle, u8* text, i32 x, i32 y);
i32 ux_ak_test_row_drag(i32 handle, i32 node, i32 row, u8* buf, i32 n);

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
void checkTrue(u8* what, bool got)
    {
    check(what, got ? (i32)1 : (i32)0, (i32)1);
    }
bool streq(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return a == b;
        }
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
// the control called `name` in the layout on the canvas
UXRscObject* named(RKMainController* c, u8* name)
    {
    Array<UXRscObject>* all = c.doc.treeAt(c.shownTree).allObjects();
    for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
        {
        UXRscObject* o = (UXRscObject* ?)all.get(i);
        if (streq(o.name, name))
            {
            return o;
            }
        }
    return (UXRscObject*)0;
    }
// the chooser's row offering `member`, or -1
i32 rowOf(RKMainController* c, u8* member)
    {
    if (c.chooser == (RKWireChooser*)0)
        {
        return (i32)-1;
        }
    for (i32 i = (i32)0; i < c.chooser.count(); i = i + (i32)1)
        {
        if (streq(c.chooser.choiceAt(i).member, member))
            {
            return i;
            }
        }
    return (i32)-1;
    }
void wire(RKMainController* c, RKEnd* src, RKEnd* dst, u8* member)
    {
    c.offerWire(src, dst, (i32)300, (i32)200);
    c.tableSelectionDidChange(c.chooser != (RKWireChooser*)0 ? c.chooser.table : (UXTableView*)0, rowOf(c, member));
    }
UXRscObject* button(UXRscObject* parent, u8* name, u8* text, i32 x, i32 y)
    {
    UXRscObject* b = UXRscObject.make((i32)UXR_T_BUTTON, x, y, (i32)70, (i32)24);
    b.text = text;
    b.name = name;
    parent.addChild(b);
    return b;
    }
Object* factory(u8* name)
    {
    if (streq(name, (u8*)"PlayerController"))
        {
        return (Object*)new PlayerController();
        }
    return (Object*)0;
    }
class Owner : Object<UXDesignable>
    {
    bool setOutlet(u8* name, Object* value)
        {
        return false;
        }
    bool wireAction(u8* name, UXControl* control)
        {
        return false;
        }
    }
UXButton* buttonIn(UXNibInstance* ni, u8* name)
    {
    for (u32 i = (u32)0; i < ni.objs.count(); i = i + (u32)1)
        {
        if (streq(((UXRscObject* ?)ni.objs.get(i)).name, name))
            {
            return (UXButton* ?)ni.views.get(i);
            }
        }
    return (UXButton*)0;
    }

void main(void)
    {
    gFails = (i32)0;
    u8* srcPath = getenv((u8*)"RK_SRC");
    u8* libPath = getenv((u8*)"RK_LIB");
    if (srcPath == (u8*)0 || libPath == (u8*)0)
        {
        Stdio.printf("FAIL: RK_SRC and RK_LIB are not set (the runner sets them)\n");
        return;
        }
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }
    UXWindow* win = new UXWindow();
    UXView* content = new UXView();
    win.open((u8*)"Rocks", UXGeom.make((i16)0, (i16)0, (i16)1100, (i16)700), content);
    RKMainController* c = new RKMainController();
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)1100, (i16)700));

    // the document: PLAYER with Play and Stop; a phone layout without Stop, with Done
    UXRscDoc* r = new UXRscDoc();
    UXRscTree* desk = new UXRscTree();
    desk.name = (u8*)"PLAYER";
    desk.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)400, (i32)200);
    button(desk.root, (u8*)"play", (u8*)"Play", (i32)20, (i32)20);
    button(desk.root, (u8*)"stop", (u8*)"Stop", (i32)100, (i32)20);
    r.addTree(desk);
    UXRscTree* phone = r.addVariant(desk, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    phone.root.children.removeAt((u32)1); // no Stop on the phone
    button(phone.root, (u8*)"done", (u8*)"Done", (i32)20, (i32)60);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    Stdio.printf("-- the class, from a library dropped on the window\n");
    UXApplication* app = new UXApplication();
    app.setFileDropHandler(&c.onFileDrop);
    app.setItemDropHandler(&c.onItemDrop);
    d.attachApp(app);
    check("the window takes the drop", ux_ak_test_drop_file(win.handle, libPath, (i32)400, (i32)300), (i32)1);
    RKClass* fromLib = c.classBook.find((u8*)"PlayerController");
    checkTrue("the library's interface has the class", fromLib != (RKClass*)0 && fromLib.origin == (i32)RKC_REFLECTED);
    check("its two outlets and two actions", fromLib != (RKClass*)0 ? (i32)fromLib.outlets.count() * (i32)10 + (i32)fromLib.actions.count() : (i32)-1, (i32)22);
    checkTrue("read from the library itself", fromLib != (RKClass*)0 && streq(RKIdentity.baseName(fromLib.source), (u8*)"libplayer.dylib"));

    Stdio.printf("-- the class, from the app's source\n");
    checkTrue("the source parses", c.addClasses(srcPath));
    RKClass* fromSrc = c.classBook.find((u8*)"PlayerController");
    checkTrue("the source's reading replaces the library's", fromSrc != (RKClass*)0 && streq(RKIdentity.baseName(fromSrc.source), (u8*)"fixture_player.xc"));
    checkTrue("its parent", fromSrc != (RKClass*)0 && streq(fromSrc.parent, (u8*)"Object"));
    check("the same outlets and actions", fromSrc != (RKClass*)0 ? (i32)fromSrc.outlets.count() * (i32)10 + (i32)fromSrc.actions.count() : (i32)-1, (i32)22);
    checkTrue("outlet types as written", fromSrc != (RKClass*)0 && streq(((RKMember* ?)fromSrc.outlets.get((u32)0)).type, (u8*)"UXButton*"));
    checkTrue("action senders as written", fromSrc != (RKClass*)0 && streq(((RKMember* ?)fromSrc.actions.get((u32)1)).type, (u8*)"UXControl*"));
    RKClassBook* tree = new RKClassBook();
    i32 files = tree.loadTree(RKMainController.dirOf(srcPath), (i32)1);
    checkTrue("a whole source folder parses, finding it among the rest", files > (i32)10 && tree.find((u8*)"PlayerController") != (RKClass*)0);
    checkTrue("and the editor's own classes, parents and all", tree.isKindOf((u8*)"RKDock", (u8*)"UXView"));

    Stdio.printf("-- the controller\n");
    c.libraryPick(c.library.named((u8*)"Object"));
    c.identityCtl.classField.setText((u8*)"PlayerController");
    c.identityCtl.onEdit(c.identityCtl.classField);
    RKEnd* ctl = RKEnd.placeholder((i32)RKON_OBJECT, (i32)1);
    c.identityCtl.reshow();
    checkTrue("Identity says where the class comes from", c.identityCtl.classInfo != (UXLabel*)0 &&
              streq(c.identityCtl.classInfo.text(), (u8*)"From fixture_player.xc"));
    check("the dock shows it", (i32)c.dock.items.count(), (i32)3);

    Stdio.printf("-- an action, for every layout\n");
    c.offerWire(RKEnd.view(named(c, (u8*)"play")), ctl, (i32)300, (i32)200);
    checkTrue("Play -> the controller offers a list", c.chooser != (RKWireChooser*)0);
    check("its two actions, and no outlets", c.chooser.count(), (i32)2);
    checkTrue("onPlay among them", rowOf(c, (u8*)"onPlay") >= (i32)0);
    win.displayAll();
    UXRect ca = c.chooser.cancel.absoluteFrame();
    check("a click on Cancel reaches Cancel, not the canvas's overlay",
          ux_ak_test_hit(win.handle, (i32)ca.x + (i32)ca.w / (i32)2, (i32)ca.y + (i32)ca.h / (i32)2), (i32)c.chooser.cancel.index);
    UXRect ta = c.chooser.table.absoluteFrame();
    checkTrue("and a click on the list reaches the list",
              ux_ak_test_hit(win.handle, (i32)ta.x + (i32)ta.w / (i32)2, (i32)ta.y + (i32)ta.h - (i32)8) >= (i32)0);
    c.tableSelectionDidChange(c.chooser.table, rowOf(c, (u8*)"onPlay"));
    checkTrue("choosing closes the list", c.chooser == (RKWireChooser*)0);
    win.displayAll();
    UXRect pa = c.canvasMap.viewFor(named(c, (u8*)"play")).absoluteFrame();
    check("then the overlay takes clicks on the canvas again",
          ux_ak_test_hit(win.handle, (i32)pa.x + (i32)pa.w / (i32)2, (i32)pa.y + (i32)pa.h / (i32)2), (i32)-1);
    check("one connection", (i32)c.doc.connections.count(), (i32)1);
    UXRscConnection* k = (UXRscConnection* ?)c.doc.connections.get((u32)0);
    checkTrue("an action named onPlay", k.kind == (i32)UXR_CONN_ACTION && streq(k.member, (u8*)"onPlay"));
    check("for every layout", (i32)k.scope, (i32)0);

    Stdio.printf("-- an outlet: only one that can hold the control is offered\n");
    c.offerWire(ctl, RKEnd.view(named(c, (u8*)"play")), (i32)300, (i32)200);
    checkTrue("playButton is offered", rowOf(c, (u8*)"playButton") >= (i32)0);
    checkTrue("titleField (a UXTextField*) is not", rowOf(c, (u8*)"titleField") < (i32)0);
    checkTrue("and, drawn from the controller, its actions too", rowOf(c, (u8*)"onPlay") >= (i32)0);
    c.tableSelectionDidChange(c.chooser.table, rowOf(c, (u8*)"playButton"));
    check("two connections", (i32)c.doc.connections.count(), (i32)2);

    Stdio.printf("-- an action drawn from its target to the control\n");
    c.offerWire(ctl, RKEnd.view(named(c, (u8*)"play")), (i32)300, (i32)200);
    c.tableSelectionDidChange(c.chooser.table, rowOf(c, (u8*)"onPlay"));
    check("it takes the place of Play's onPlay (one action per control)", (i32)c.doc.connections.count(), (i32)2);
    UXRscConnection* kr = (UXRscConnection* ?)c.doc.connections.get((u32)1);
    checkTrue("stored from the control to the controller", kr.kind == (i32)UXR_CONN_ACTION &&
              kr.src.space == (i32)UXR_REF_LOGICAL && kr.dst.space == (i32)UXR_REF_TOP && streq(kr.member, (u8*)"onPlay"));

    Stdio.printf("-- Stop on the desktop, Done on the phone, each for its own layout\n");
    c.newScope.selectItem((i32)RKSC_THIS);
    c.onNewScope((UXControl*)c.newScope);
    wire(c, RKEnd.view(named(c, (u8*)"stop")), ctl, (u8*)"onStop");
    c.viewLayout((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    check("the phone layout is on the canvas", c.shownTree, (i32)1);
    wire(c, RKEnd.view(named(c, (u8*)"done")), ctl, (u8*)"onStop");
    check("four connections", (i32)c.doc.connections.count(), (i32)4);
    UXRscConnection* ks = (UXRscConnection* ?)c.doc.connections.get((u32)2);
    UXRscConnection* kd = (UXRscConnection* ?)c.doc.connections.get((u32)3);
    check("Stop's is the desktop's", (i32)ks.scope, (i32)UXRscConnection.themeBit((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE));
    check("Done's the phone portrait's", (i32)kd.scope, (i32)UXRscConnection.themeBit((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT));

    Stdio.printf("-- the Connections tab\n");
    c.selectPlaceholder((i32)RKON_OBJECT, (i32)1);
    check("it lists the controller's four connections", (i32)c.connectionsCtl.rows.count(), (i32)4);
    RKConnRow* stopRow = (RKConnRow*)0;
    for (u32 i = (u32)0; i < c.connectionsCtl.rows.count(); i = i + (u32)1)
        {
        RKConnRow* rr = (RKConnRow* ?)c.connectionsCtl.rows.get(i);
        if (rr.conn == ks)
            {
            stopRow = rr;
            }
        }
    checkTrue("Stop's row", stopRow != (RKConnRow*)0);
    check("which reads Desktop", stopRow.scope.selectedIndex(), (i32)RKSC_DESKTOP);
    stopRow.scope.selectItem((i32)RKSC_ALL);
    c.connectionsCtl.onScope((UXControl*)stopRow.scope);
    check("set to all layouts", (i32)ks.scope, (i32)0);
    c.onUndo((UXMenuItem*)0);
    UXRscConnection* ks2 = (UXRscConnection* ?)c.doc.connections.get((u32)2);
    check("undo puts the desktop scope back", (i32)ks2.scope, (i32)UXRscConnection.themeBit((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE));
    c.selectPlaceholder((i32)RKON_OBJECT, (i32)1);
    RKConnRow* first = (RKConnRow* ?)c.connectionsCtl.rows.get((u32)0);
    c.connectionsCtl.onBreak((UXControl*)first.breaker);
    check("Disconnect breaks one", (i32)c.doc.connections.count(), (i32)3);
    c.onUndo((UXMenuItem*)0);
    check("undo mends it", (i32)c.doc.connections.count(), (i32)4);

    Stdio.printf("-- a second outlet connection replaces the first in its layouts\n");
    c.viewLayout((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE);
    c.newScope.selectItem((i32)RKSC_ALL);
    c.onNewScope((UXControl*)c.newScope);
    wire(c, ctl, RKEnd.view(named(c, (u8*)"stop")), (u8*)"playButton");
    check("still four: playButton now holds Stop", (i32)c.doc.connections.count(), (i32)4);
    c.onUndo((UXMenuItem*)0);

    Stdio.printf("-- a library row dragged onto the form\n");
    i32 sliderRow = (i32)-1;
    for (i32 i = (i32)0; i < (i32)c.library.shown.count(); i = i + (i32)1)
        {
        if (streq(c.library.itemAt(i).name, (u8*)"Slider"))
            {
            sliderRow = i;
            }
        }
    u8 carried[64];
    check("the library's row drags out, and the window takes it",
          ux_ak_test_row_drag(win.handle, (i32)c.libraryTable.index, sliderRow, &carried[(i32)0], (i32)64), (i32)1);
    checkTrue("carrying the item's name", streq(&carried[(i32)0], (u8*)"Slider"));
    UXRscTree* dt = c.doc.treeAt(c.shownTree);
    i32 before = dt.root.childCount();
    UXRect oa = c.overlay.absoluteFrame();
    i32 dx = (i32)oa.x + (i32)RK_FORM_X + (i32)200;
    i32 dy = (i32)oa.y + (i32)RK_FORM_Y + (i32)120;
    check("the drop is delivered", ux_ak_test_drop_item(win.handle, &carried[(i32)0], dx, dy), (i32)1);
    check("it adds one control", dt.root.childCount(), before + (i32)1);
    UXRscObject* placed = dt.root.childAt(before);
    RKLibraryItem* sl = c.library.named((u8*)"Slider");
    checkTrue("centred where it was dropped", placed != (UXRscObject*)0 &&
              placed.x == (i32)200 - sl.w / (i32)2 && placed.y == (i32)120 - sl.h / (i32)2);
    i32 nconn = (i32)c.doc.connections.count();
    c.onItemDrop((u8*)"Slider", win.handle, (i32)oa.x - (i32)10, (i32)oa.y + (i32)10);
    check("a drop outside the canvas adds nothing", dt.root.childCount(), before + (i32)1);
    c.placing = (RKLibraryItem*)0;
    c.onUndo((UXMenuItem*)0);
    check("and Undo takes the drop back", c.doc.treeAt(c.shownTree).root.childCount(), before);
    check("leaving the connections", (i32)c.doc.connections.count(), nconn);

    Stdio.printf("-- the app: each layout fires what was wired for it\n");
    UXData* bytes = UXRscWriter.write(c.doc);
    UXRscDoc* saved = UXRscReader.read(bytes.bytes(), bytes.length());
    UXNib.registerObjectFactory((pointer)&factory);
    UXNibInstance* nd = UXNib.loadDocAs(saved, (i32)0, (i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE, (UXDesignable*)new Owner(), (UXView*)0);
    checkTrue("the desktop loads", nd != (UXNibInstance*)0);
    PlayerController* pd = (PlayerController* ?)nd.topObject((i32)1);
    checkTrue("with a PlayerController", pd != (PlayerController*)0);
    checkTrue("its playButton outlet holds Play", pd != (PlayerController*)0 && (Object*)pd.playButton == (Object*)buttonIn(nd, (u8*)"play"));
    gPlays = (i32)0;
    gStops = (i32)0;
    buttonIn(nd, (u8*)"play").fire();
    buttonIn(nd, (u8*)"stop").fire();
    check("Play plays", gPlays, (i32)1);
    check("Stop stops", gStops, (i32)1);
    UXNibInstance* np = UXNib.loadDocAs(saved, (i32)0, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT, (UXDesignable*)new Owner(), (UXView*)0);
    checkTrue("the phone loads", np != (UXNibInstance*)0 && np.klass == (i32)UXR_V_PHONE);
    PlayerController* pp = (PlayerController* ?)np.topObject((i32)1);
    checkTrue("its playButton is the phone's Play", pp != (PlayerController*)0 && (Object*)pp.playButton == (Object*)buttonIn(np, (u8*)"play"));
    buttonIn(np, (u8*)"play").fire();
    buttonIn(np, (u8*)"done").fire();
    check("Play plays on the phone", gPlays, (i32)2);
    check("Done stops", gStops, (i32)2);
    check("the desktop's Stop connection is not bound on the phone", np.outOfScope, (i32)1);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: connections -- drawn per layout in Rocks, bound per layout by UXNib\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
