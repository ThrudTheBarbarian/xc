// test_rklibrary.xc — the library's UXKit views: every class the library offers is one the loader
// can make, and each placed from the library is a view of its class on the canvas and in a loaded
// form, with the settings the inspector edits applied.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRsc.xc"
#import "UXRscModel.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"

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
// place the library item `name` at (x, y) on the form; the placed object
UXRscObject* place(RKMainController* c, u8* name, i32 x, i32 y)
    {
    c.libraryPick(c.library.named(name));
    c.placeAt(x, y);
    return c.selected;
    }
void setAttr(RKMainController* c, u8* key, u8* value)
    {
    RKRow* r = c.inspectorCtl.rowNamed(key);
    if (r == (RKRow*)0)
        {
        Stdio.printf("  FAIL no %s row\n", key);
        gFails = gFails + (i32)1;
        return;
        }
    r.field.setText(value);
    c.inspectorCtl.onField(r.field);
    }
UXView* loadedFor(UXRscInstance* ni, UXRscObject* o)
    {
    for (u32 i = (u32)0; i < ni.objs.count(); i = i + (u32)1)
        {
        if ((UXRscObject* ?)ni.objs.get(i) == o)
            {
            return (UXView* ?)ni.views.get(i);
            }
        }
    return (UXView*)0;
    }

void main(void)
    {
    gFails = (i32)0;
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

    Stdio.printf("-- every UXKit class in the library can be made\n");
    for (i32 i = (i32)0; i < c.library.count(); i = i + (i32)1)
        {
        RKLibraryItem* it = (RKLibraryItem* ?)c.library.all.get((u32)i);
        if (it.cls != (u8*)0 && UXRsc.makeUXKit(it.cls) == (Object*)0)
            {
            Stdio.printf("  FAIL the loader cannot make %s\n", it.cls);
            gFails = gFails + (i32)1;
            }
        }

    UXRscDoc* r = new UXRscDoc();
    UXRscTree* t = new UXRscTree();
    t.name = (u8*)"MAIN";
    t.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)500, (i32)400);
    r.addTree(t);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    Stdio.printf("-- placed and set\n");
    UXRscObject* tvo = place(c, (u8*)"Text View", (i32)20, (i32)20);
    checkTrue("a text view is placed", tvo != (UXRscObject*)0);
    setAttr(c, (u8*)"text", (u8*)"Once upon a time");
    setAttr(c, (u8*)"fontSize", (u8*)"18");
    UXRscObject* dpo = place(c, (u8*)"Date Picker", (i32)20, (i32)200);
    setAttr(c, (u8*)"date", (u8*)"2026-10-08");
    UXRscObject* bco = place(c, (u8*)"Breadcrumb", (i32)20, (i32)260);
    setAttr(c, (u8*)"segments", (u8*)"Home|Music|Jazz");
    UXRscObject* tblo = place(c, (u8*)"Table View", (i32)20, (i32)320);
    setAttr(c, (u8*)"columns", (u8*)"Name:120|Size:60");
    UXRscObject* olo = place(c, (u8*)"Outline View", (i32)260, (i32)20);
    setAttr(c, (u8*)"columns", (u8*)"Item:180");
    UXRscObject* cvo = place(c, (u8*)"Collection View", (i32)260, (i32)200);
    setAttr(c, (u8*)"items", (u8*)"One|Two|Three");
    checkTrue("on the canvas, a UXTextView", (UXTextView* ?)(Object*)c.canvasMap.viewFor(tvo) != (UXTextView*)0);
    checkTrue("a UXDatePicker", (UXDatePicker* ?)(Object*)c.canvasMap.viewFor(dpo) != (UXDatePicker*)0);
    checkTrue("a UXBreadcrumb", (UXBreadcrumb* ?)(Object*)c.canvasMap.viewFor(bco) != (UXBreadcrumb*)0);
    UXTableView* tblw = (UXTableView* ?)(Object*)c.canvasMap.viewFor(tblo);
    UXOutlineView* olw = (UXOutlineView* ?)(Object*)c.canvasMap.viewFor(olo);
    UXCollectionView* cvw = (UXCollectionView* ?)(Object*)c.canvasMap.viewFor(cvo);
    checkTrue("a UXTableView", tblw != (UXTableView*)0);
    check("with two columns", tblw != (UXTableView*)0 ? tblw.numberOfColumns() : (i32)0, (i32)2);
    check("and the widths given", tblw != (UXTableView*)0 ? (i32)tblw.columnWidth((i32)1) : (i32)0, (i32)60);
    checkTrue("a UXOutlineView", olw != (UXOutlineView*)0);
    check("with its column", olw != (UXOutlineView*)0 ? olw.numberOfColumns() : (i32)0, (i32)1);
    checkTrue("a UXCollectionView", cvw != (UXCollectionView*)0);
    check("with its three items", cvw != (UXCollectionView*)0 ? cvw.count() : (i32)0, (i32)3);
    checkTrue("a table view is designable", (UXDesignable* ?)(Object*)tblw != (UXDesignable*)0);
    checkTrue("its datasource is an outlet",
              (UXDesignable* ?)(Object*)tblw != (UXDesignable*)0 &&
              ((UXDesignable* ?)(Object*)tblw).setOutlet((u8*)"dataSource", (Object*)c.library));
    checkTrue("a wrong type is refused",
              (UXDesignable* ?)(Object*)tblw != (UXDesignable*)0 &&
              !((UXDesignable* ?)(Object*)tblw).setOutlet((u8*)"dataSource", (Object*)new UXLabel()));

    Stdio.printf("-- saved and loaded\n");
    Data* b = UXRscWriter.write(c.doc);
    UXRscDoc* back = UXRscReader.read(b.bytes(), b.length());
    UXView* host = new UXView();
    content.addSubview(host, UXGeom.make((i16)0, (i16)0, (i16)500, (i16)400));
    UXRscInstance* ni = UXRsc.loadDoc(back, (i32)0, (UXDesignable*)0, host);
    UXRscTree* bt = back.treeAt((i32)0);
    UXTextView* tv = (UXTextView* ?)(Object*)loadedFor(ni, bt.root.childAt((i32)0));
    checkTrue("the text view loads as one", tv != (UXTextView*)0);
    checkTrue("with its text", tv != (UXTextView*)0 && tv.text().equals(String.withCString((u8*)"Once upon a time")));
    UXDatePicker* dp = (UXDatePicker* ?)(Object*)loadedFor(ni, bt.root.childAt((i32)1));
    checkTrue("the date picker loads as one", dp != (UXDatePicker*)0);
    check("on the day it was given", dp != (UXDatePicker*)0 ? dp.day() : (i32)0, (i32)8);
    check("...of the month", dp != (UXDatePicker*)0 ? dp.month() : (i32)0, (i32)10);
    UXBreadcrumb* bc = (UXBreadcrumb* ?)(Object*)loadedFor(ni, bt.root.childAt((i32)2));
    checkTrue("the breadcrumb loads as one", bc != (UXBreadcrumb*)0);
    check("with its three segments", bc != (UXBreadcrumb*)0 ? (i32)bc.segments.count() : (i32)0, (i32)3);
    UXTableView* tbl = (UXTableView* ?)(Object*)loadedFor(ni, bt.root.childAt((i32)3));
    checkTrue("the table view loads as one", tbl != (UXTableView*)0);
    check("with its two columns", tbl != (UXTableView*)0 ? tbl.numberOfColumns() : (i32)0, (i32)2);
    check("and the widths given", tbl != (UXTableView*)0 ? (i32)tbl.columnWidth((i32)0) : (i32)0, (i32)120);
    UXOutlineView* ol = (UXOutlineView* ?)(Object*)loadedFor(ni, bt.root.childAt((i32)4));
    checkTrue("the outline view loads as one", ol != (UXOutlineView*)0);
    check("with its column", ol != (UXOutlineView*)0 ? ol.numberOfColumns() : (i32)0, (i32)1);
    UXCollectionView* cv = (UXCollectionView* ?)(Object*)loadedFor(ni, bt.root.childAt((i32)5));
    checkTrue("the collection view loads as one", cv != (UXCollectionView*)0);
    check("with its three items", cv != (UXCollectionView*)0 ? cv.count() : (i32)0, (i32)3);
    checkTrue("a bad date is no date", UXRsc.dateFrom((u8*)"2026-13-01") == (UXDate*)0 && UXRsc.dateFrom((u8*)"soon") == (UXDate*)0);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the library's UXKit views are placed, set, saved and loaded\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
