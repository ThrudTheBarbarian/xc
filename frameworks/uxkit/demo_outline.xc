// demo_outline.xc — a visual outline: a file tree with disclosure triangles, indentation, and the
// table machinery underneath (scroll, selection).  Opens expanded a couple of levels and idles so the
// host framebuffer shows it; a DRAG/CLICK script can then toggle a node to prove expand/collapse.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXOutlineView.xc"

class Node : Object
    {
    u8* name;
    Array* kids;
    void init(void)
        {
        name = "";
        kids = new Array();
        }
    } Node* mknode(u8* name)
    {
    Node* n = new Node();
    n.name = name;
    return n;
    }

class Tree : Object<UXOutlineDataSource>
    {
    Node* root;
    void init(void)
        {
        root = (Node*)0;
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return (i32)n.kids.count();
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return n.kids.get((u16)i);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        { return ((Node* ?)item).kids.count() > (u16)0;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        { return ((Node* ?)item).name;
        }
    }

    class OLCanvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8);
        }
    }

    class OLKit : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    UXOutlineView* out;
    Tree* model;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        //   Documents/ (report.txt, notes.txt, Drafts/ (v1.md, v2.md))
        //   Pictures/  (cat.png, dog.png)
        //   readme.txt
        model = new Tree();
        model.root = mknode("/");
        Node* docs = mknode("Documents");
        docs.kids.add(mknode("report.txt"));
        docs.kids.add(mknode("notes.txt"));
        Node* drafts = mknode("Drafts");
        drafts.kids.add(mknode("v1.md"));
        drafts.kids.add(mknode("v2.md"));
        docs.kids.add(drafts);
        Node* pics = mknode("Pictures");
        pics.kids.add(mknode("cat.png"));
        pics.kids.add(mknode("dog.png"));
        model.root.kids.add(docs);
        model.root.kids.add(pics);
        model.root.kids.add(mknode("readme.txt"));

        OLCanvas* canvas = new OLCanvas();
        win = new UXWindow();
        win.open((u8*)"Files", UXGeom.make((i16)90, (i16)70, (i16)300, (i16)240), canvas);
        a.addWindow(win);

        out = new UXOutlineView();
        canvas.addSubview(out, UXGeom.make((i16)10, (i16)10, (i16)280, (i16)200));
        out.setRowHeight((i16)22);
        out.addColumn((u8*)"Name", (i16)278);
        out.setOutlineSource(model);
        out.reloadData();
        out.toggleRow((i32)0); // open Documents -> [Documents, report, notes, Drafts, Pictures, readme]
        out.toggleRow((i32)3); // open Drafts (nested) -> shows two levels of indentation

        win.tree.finalise();
        win.displayAll();
        Stdio.printf("demo_outline up\n");
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    OLKit* kit = new OLKit();
    UXApplication* app = new UXApplication();
    app.setDelegate(kit);
    app.run();
    Stdio.printf("demo_outline exited\n");
    }
