// tables.xc — a table and an outline, both driven by DATA SOURCES.
//
// The view never holds your data. It asks: how many rows, and what goes in this
// cell — so the model stays yours and the table stays a view of it.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXGeometry.xc"

// ---- the model: yours, and the toolkit never copies it --------------------
class Track : Object {
    u8* name; u8* artist; i32 mins;
    void init(void) { name=(u8*)""; artist=(u8*)""; mins=0; }
    static Track* make(u8* n, u8* a, i32 m) {
        Track* t = new Track(); t.name=n; t.artist=a; t.mins=m; return t;
    }
}

// A node for the outline: anything can be an item, it is just an Object*.
class Node : Object {
    u8* label;
    Array<Node>* kids;
    void init(void) { label=(u8*)""; kids=new Array(); }
    static Node* make(u8* l) { Node* n = new Node(); n.label=l; return n; }
}

class Controller : Object <UXApplicationDelegate, UXTableDataSource,
                           UXTableDelegate, UXOutlineDataSource>
{
    Array<Track>* tracks;
    Node*         root;
    UXLabel*      status;
    u8            buf[16];

    void init(void) { tracks = new Array(); }

    // ---- UXTableDataSource: two methods, and that is the whole contract ----
    i32 numberOfRows(UXTableView* t) { return (i32)tracks.count(); }

    u8* valueForCell(UXTableView* t, i32 row, i32 col) {
        Track* tr = (Track* ?)tracks.get((u16)row);
        if (col == 0) { return tr.name; }
        if (col == 1) { return tr.artist; }
        // Column 2 is a number, and a cell returns TEXT — so format it here.
        i32 v = tr.mins; i32 i = 0;
        if (v >= 10) { buf[i] = (u8)(48 + v / 10); i = i + 1; }
        buf[i] = (u8)(48 + v % 10); i = i + 1;
        buf[i] = (u8)0;
        return &buf[0];
    }

    // ---- UXTableDelegate: optional, so the table works without it ---------
    void tableSelectionDidChange(UXTableView* t, i32 row) {
        if (row < 0) { status.setText((u8*)"nothing selected"); return; }
        status.setText(((Track* ?)tracks.get((u16)row)).name);
    }

    // ---- UXOutlineDataSource: a TREE, addressed by item not by index ------
    i32 numberOfChildren(UXOutlineView* o, Object* item) {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return (i32)n.kids.count();
    }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i) {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return (Object*)((Node* ?)n.kids.get((u16)i));
    }
    bool isExpandable(UXOutlineView* o, Object* item) {
        Node* n = item == (Object*)0 ? root : (Node* ?)item;
        return n.kids.count() > 0;
    }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col) {
        return item == (Object*)0 ? (u8*)"" : ((Node* ?)item).label;
    }

    i32 applicationDidStart(UXApplication* app) {
        tracks.add(Track.make((u8*)"Verdant",  (u8*)"Aeon",   4));
        tracks.add(Track.make((u8*)"Sable",    (u8*)"Aeon",   7));
        tracks.add(Track.make((u8*)"Cinder",   (u8*)"Mirrer", 12));

        root = Node.make((u8*)"root");
        Node* music = Node.make((u8*)"Music");
        music.kids.add(Node.make((u8*)"Aeon"));
        music.kids.add(Node.make((u8*)"Mirrer"));
        root.kids.add(music);
        root.kids.add(Node.make((u8*)"Playlists"));

        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Tables", UXGeom.make(60, 60, 420, 300), content);

        UXTableView* table = new UXTableView();
        table.addColumn((u8*)"Title",  160);
        table.addColumn((u8*)"Artist", 110);
        table.addColumn((u8*)"Min",     40);
        table.setDataSource((UXTableDataSource*)self);
        table.setDelegate((UXTableDelegate*)self);
        table.setAllowsMultipleSelection(true);
        content.addSubview(table, UXGeom.make(10, 10, 320, 120));

        UXOutlineView* tree = new UXOutlineView();
        tree.setOutlineSource((UXOutlineDataSource*)self);
        content.addSubview(tree, UXGeom.make(10, 140, 200, 110));

        status = new UXLabel();
        status.setText((u8*)"nothing selected");
        content.addSubview(status, UXGeom.make(10, 260, 380, 18));

        win.tree.finalise();
        win.displayAll();

        // Change the model, then tell the view — the table re-asks.
        tracks.add(Track.make((u8*)"Ochre", (u8*)"Mirrer", 5));
        table.reloadData();
        Stdio.printf("rows after reload: %d\n", table.nativeRowCount());
        return 0;
    }
}

void main(void) {
    gDriver = new UXAppKitDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Controller());
    app.run();
}
