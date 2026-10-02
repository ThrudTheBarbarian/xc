// test_rkdocument.xc — the document on disk: Save writes the .rsc (with the layouts' UXNB v2 chunk),
// Open reads it back into the editor, and a save that cannot happen says so and changes nothing.
// Through the controller's own saveTo / openPath -- what the File menu's items call once the panel
// has answered with a path.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "RKModel.xc"
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
    if (got)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

bool says(RKMainController* c, u8* want)
    {
    u8* got = c.statusLabel.text();
    i32 i = (i32)0;
    while (got[i] != (u8)0 && want[i] != (u8)0 && got[i] == want[i])
        {
        i = i + (i32)1;
        }
    if (got[i] != want[i])
        {
        Stdio.printf("    status is \"%s\"\n", got);
        return false;
        }
    return true;
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
    RKMainController* c = new RKMainController();
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"doc", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));

    RKResource* r = new RKResource();
    RKTree* main = new RKTree();
    main.name = (u8*)"MAIN";
    main.root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* ok = RKObject.make((i32)RKT_BUTTON, (i32)20, (i32)30, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    main.root.addChild(ok);
    r.addTree(main);
    c.showResource(r, (i32)0);
    win.tree.finalise();
    checkTrue("a new document has no file", c.docPath == (u8*)0);

    // a phone layout, so the chunk is part of what is saved
    c.viewLayout((i32)RKV_PHONE, (i32)RKV_ORIENT_PORTRAIT);
    c.onNewLayout((UXControl*)0);
    r.treeAt((i32)1).root.childAt((i32)0).x = (i32)7;
    checkTrue("the document is dirty", c.dirty);

    u8* path = (u8*)"/tmp/rocks_document_test.rsc";
    checkTrue("Save writes it", c.saveTo(path));
    checkTrue("...says so", says(c, (u8*)"Saved rocks_document_test.rsc"));
    checkTrue("...and it is clean, with its file", !c.dirty && c.docPath != (u8*)0);

    // a save that cannot happen
    c.dirty = true;
    checkTrue("a save into a missing folder fails", !c.saveTo((u8*)"/tmp/no_such_rocks_dir/x.rsc"));
    checkTrue("...says so", says(c, (u8*)"Could not save x.rsc"));
    checkTrue("...and stays dirty, keeping its old file", c.dirty && RKRscWrite.seq(c.docPath, path));

    // a different document, then the saved one opened again
    c.showResource(RKResource.emptyDialog(), (i32)0);
    checkTrue("Open reads it back", c.openPath(path));
    checkTrue("...says so", says(c, (u8*)"Opened rocks_document_test.rsc"));
    check((u8*)"both trees are there", c.doc.treeCount(), (i32)2);
    check((u8*)"MAIN is a form with two layouts", c.doc.formCount() == (i32)1 ? c.doc.formAt((i32)0).variantCount() : (i32)0, (i32)2);
    RKVariant* pv = c.doc.formAt((i32)0).find((i32)RKV_PHONE, (i32)RKV_ORIENT_PORTRAIT);
    checkTrue("the phone layout came back", pv != (RKVariant*)0);
    check((u8*)"...as it was left", pv != (RKVariant*)0 ? pv.tree.root.childAt((i32)0).x : (i32)-1, (i32)7);
    check((u8*)"the canvas shows the first tree", c.shownTree, (i32)0);
    checkTrue("an opened document is clean", !c.dirty);
    c.viewLayout((i32)RKV_PHONE, (i32)RKV_ORIENT_PORTRAIT);
    check((u8*)"and its phone layout is one click away", c.shownTree, (i32)1);

    // not a resource
    UXFileIO.write((u8*)"/tmp/rocks_not_a_resource.txt", UXData.fromString((u8*)"hello"));
    checkTrue("a file that is not a resource is refused", !c.openPath((u8*)"/tmp/rocks_not_a_resource.txt"));
    checkTrue("...saying so", says(c, (u8*)"That is not a GEM resource file"));
    check((u8*)"...and the open document stays", c.doc.treeCount(), (i32)2);
    checkTrue("a missing file is refused too", !c.openPath((u8*)"/tmp/no_such_rocks_file.rsc"));
    remove((u8*)"/tmp/rocks_not_a_resource.txt");
    remove(path);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the document on disk -- save, open, and the failures\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
