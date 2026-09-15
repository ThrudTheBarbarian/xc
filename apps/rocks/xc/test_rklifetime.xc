// test_rklifetime.xc — the document outlives the editing of it.
//
// Rocks crashed after about thirty clicks on the canvas: a model object was
// FREED while the resource still held it, and the next walk of the tree read
// scribbled memory.  It survived testing for days because freed memory usually
// still looks like a valid object -- the earlier gates clicked, passed, and
// proved nothing about lifetimes.
//
// So this gate does two things the others do not:
//
//   it runs the EDITOR, not the geometry -- a real window, a real resource, a
//   real overlay, four hundred presses swept across the canvas
//
//   it checks the MODEL after every single press, and checks for scribble
//   (0x55..) as well as null, so a dangling pointer is caught at the first read
//   rather than whenever it happens to fall over
//
// Run it under MallocScribble=1 (the gate script sets it): without that, freed
// memory keeps its old contents for a while and this passes while broken --
// which is exactly how the bug survived.
#import <Stdio.xc>
#import <Files.xc>
#import <String.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "RKModel.xc"
#import "RKRsc.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"

RKResource* gRes;

// Walk without childCount(), and check for scribble as well as null.
bool ok(RKObject* o, i32 depth)
    {
    if ((pointer)o == (pointer)0)
        {
        return true;
        }
    u64 k = (u64)(pointer)o.children;
    if (k == (u64)0 || (k & (u64)$FF) == (u64)$55)
        {
        Stdio.printf("    DEAD at depth %d (children=%x)\n", (i16)depth, (i32)k);
        return false;
        }
    for (i32 i = (i32)0; i < (i32)o.children.count(); i = i + (i32)1)
        {
        if (!ok((RKObject* ?)o.children.get((u16)i), depth + (i32)1))
            {
            return false;
            }
        }
    return true;
    }
void stage(u8* what)
    {
    for (i32 t = (i32)0; t < gRes.treeCount(); t = t + (i32)1)
        {
        if (!ok(gRes.treeAt(t).root, (i32)0))
            {
            Stdio.printf("FAIL: the model was freed by: %s (tree %d)\n", what, (i16)t);
            return;
            }
        }
    Stdio.printf("  ok after: %s\n", what);
    }

void main(void)
    {
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    gInputReplay = true;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    String* sp = String.withCString((u8*)"resources/desktop.rsc");
    if (!Files.exists(sp))
        {
        Stdio.printf("SKIP: no desktop.rsc\n");
        return;
        }
    Data* fd = Files.readData(sp);
    gRes = RKRsc.read(fd.bytes(), (i32)fd.length());
    stage((u8*)"RKRsc.read");

    RKMainController* c = new RKMainController();
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"stage", UXGeom.make((i16)0, (i16)0, (i16)1000, (i16)640), content);
    stage((u8*)"window open");

    RKMainBuilder.buildInto(content, c, (i16)1000, (i16)640);
    stage((u8*)"buildInto");

    // The realize, one tree at a time.
    RKCanvas* map = new RKCanvas();
    UXView* pane = new UXView();
    content.addSubview(pane, UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300));
    map.realize(gRes.treeAt((i32)0), pane);
    stage((u8*)"RKCanvas.realize (tree 0)");

    RKOutline* ol = new RKOutline();
    ol.build(gRes);
    stage((u8*)"RKOutline.build");

    c.showResource(gRes, (i32)0);
    stage((u8*)"showResource");

    win.tree.finalise();
    stage((u8*)"finalise");

    win.displayAll();
    stage((u8*)"displayAll");

    c.selectObject(gRes.treeAt((i32)0).root.childAt((i32)0));
    stage((u8*)"selectObject");

    // Now the clicks, validating after each one so the first bad click is named.
    UXEvent* e = new UXEvent();
    UXRect ov = c.overlay.absoluteFrame();
    for (i32 n = (i32)0; n < (i32)400; n = n + (i32)1)
        {
        i32 x = (n % (i32)20) * (i32)23;
        i32 y = ((n / (i32)20) % (i32)12) * (i32)19;
        e.init();
        e.kind = (u8)UXEventMouseDown;
        e.x = (i16)((i32)ov.x + x);
        e.y = (i16)((i32)ov.y + y);
        c.overlay.mouseDown(e);
        for (i32 t = (i32)0; t < gRes.treeCount(); t = t + (i32)1)
            {
            if (!ok(gRes.treeAt(t).root, (i32)0))
                {
                Stdio.printf("FAIL: a model object was freed after press %d (%d,%d), tree %d --\n", (i16)n, (i16)x, (i16)y, (i16)t);
                Stdio.printf("      the resource still holds it, so editing has outlived the document\n");
                return;
                }
            }
        }
    Stdio.printf("PASS: 400 presses on the canvas, the document intact throughout\n");
    }
