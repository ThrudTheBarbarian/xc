// RKConnect.xc — the two views connections are made and kept in.
//
// RKWireChooser is the list a connection line ends in: dropped on a target, it offers the outlets
// and actions that fit, as Interface Builder's connection panel does, and picking one makes the
// connection.  It is drawn by the toolkit over the canvas, so it is the same on every backend.
//
// RKConnectionsPane is the Connections inspector: everything connected to or from the selection,
// each with the layouts it applies to (a pop-up: all layouts, one form factor, this layout) and a
// button that breaks it, then the selection's class's outlets and actions that are not connected.
#import "Array.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXPopUpButton.xc"
#import "UXTableView.xc"
#import "UXMetrics.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "RKWiring.xc"
#import "RKClasses.xc"
#import "RKOutline.xc"

class RKWireChooser : UXView<UXTableDataSource>
    {
    Array<RKChoice2>* choices;
    RKEnd* src;
    RKEnd* dst;
    UXTableView* table;
    UXLabel* title;
    UXButton* cancel;

    void init(void)
        {
        super.init();
        choices = new Array();
        src = (RKEnd*)0;
        dst = (RKEnd*)0;
        table = (UXTableView*)0;
        title = (UXLabel*)0;
        }
    i32 count(void)
        {
        return (i32)choices.count();
        }
    RKChoice2* choiceAt(i32 i)
        {
        if (i < (i32)0 || i >= (i32)choices.count())
            {
            return (RKChoice2*)0;
            }
        return (RKChoice2* ?)choices.get((u32)i);
        }
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)choices.count();
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        RKChoice2* c = self.choiceAt(row);
        if (c == (RKChoice2*)0)
            {
            return (u8*)"";
            }
        if (col == (i32)0)
            {
            return c.kind == (i32)UXR_CONN_ACTION ? (u8*)"Action" : (u8*)"Outlet";
            }
        return c.member;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)250, (i32)250, (i32)250);
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, b.w, (i16)2), (i32)30, (i32)120, (i32)255);
        g.fillRectRGB(UXGeom.make((i16)0, (i16)((i32)b.h - (i32)1), b.w, (i16)1), (i32)150, (i32)150, (i32)150);
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, (i16)1, b.h), (i32)150, (i32)150, (i32)150);
        g.fillRectRGB(UXGeom.make((i16)((i32)b.w - (i32)1), (i16)0, (i16)1, b.h), (i32)150, (i32)150, (i32)150);
        }
    }

// One connection's row in the Connections tab.
class RKConnRow : Object
    {
    UXRscConnection* conn;
    UXPopUpButton* scope;
    UXButton* breaker;
    }

class RKConnectionsPane : Object
    {
    UXView* pane;
    Array<RKConnRow>* rows;
    UXRscDoc* doc;
    UXRscTree* tree;
    bool loading;
    // the controller's: before an edit, after it
    callback willChange void(void);
    callback changed void(void);

    void init(void)
        {
        pane = (UXView*)0;
        rows = new Array();
        doc = (UXRscDoc*)0;
        tree = (UXRscTree*)0;
        loading = false;
        willChange = (callback void(void))0;
        changed = (callback void(void))0;
        }
    void attach(UXView* p)
        {
        pane = p;
        }

    // Show what is connected to or from `e` (0: nothing selected), in the layout `t`.
    void show(UXRscDoc* d, UXRscTree* t, RKClassBook* book, RKEnd* e)
        {
        loading = true;
        doc = d;
        tree = t;
        rows = new Array();
        if (pane == (UXView*)0)
            {
            loading = false;
            return;
            }
        pane.removeAllSubviews();
        i16 y = (i16)8;
        if (d == (UXRscDoc*)0 || e == (RKEnd*)0)
            {
            self.note((u8*)"Control-drag from a control to an object for an action, or from an object to a control for an outlet.", &y);
            loading = false;
            return;
            }
        Array<UXRscConnection>* cs = RKWiring.connectionsOf(d, t, e);
        u32 here = RKWiring.themeOf(d, t);
        if (cs.count() == (u32)0)
            {
            self.note((u8*)"No connections.", &y);
            }
        for (u32 i = (u32)0; i < cs.count(); i = i + (u32)1)
            {
            UXRscConnection* c = (UXRscConnection* ?)cs.get(i);
            self.connectionRow(d, t, c, e, here, &y);
            }
        // the class's members with nothing connected to them in this layout, on one line
        u8* cls = RKWiring.classOf(d, t, e);
        if (book != (RKClassBook*)0 && cls[0] != (u8)0)
            {
            Data* idle = Data.withCapacity((u32)((i32)64));
            Array<RKMember>* os = book.outletsOf(cls);
            Array<RKMember>* as = book.actionsOf(cls);
            for (u32 i = (u32)0; i < os.count(); i = i + (u32)1)
                {
                RKMember* m = (RKMember* ?)os.get(i);
                if (!RKConnectionsPane.connected(d, t, e, (i32)UXR_CONN_OUTLET, m.name))
                    {
                    RKConnectionsPane.listAdd(idle, m.name);
                    }
                }
            for (u32 i = (u32)0; i < as.count(); i = i + (u32)1)
                {
                RKMember* m = (RKMember* ?)as.get(i);
                if (!RKConnectionsPane.connected(d, t, e, (i32)UXR_CONN_ACTION, m.name))
                    {
                    RKConnectionsPane.listAdd(idle, m.name);
                    }
                }
            if (idle.length() > (i32)0)
                {
                idle.appendByte((u8)0);
                y = (i16)((i32)y + (i32)6);
                self.note(RKConnectionsPane.joined((u8*)"Not connected here: ", idle.bytes()), &y);
                }
            }
        loading = false;
        }
    // Whether a member of `e` has a connection that binds in the layout `t`.
    static bool connected(UXRscDoc* d, UXRscTree* t, RKEnd* e, i32 kind, u8* member)
        {
        for (u32 i = (u32)0; i < d.connections.count(); i = i + (u32)1)
            {
            UXRscConnection* c = (UXRscConnection* ?)d.connections.get(i);
            if (c.kind != kind || !RKClassBook.seq(c.member, member) || !RKWiring.inScopeHere(d, t, c))
                {
                continue;
                }
            UXRscRef* holder = kind == (i32)UXR_CONN_OUTLET ? c.src : c.dst;
            if (RKWiring.names(d, t, holder, e))
                {
                return true;
                }
            }
        return false;
        }
    void connectionRow(UXRscDoc* d, UXRscTree* t, UXRscConnection* c, RKEnd* e, u32 here, i16* y)
        {
        i16 rh = self.rowH();
        i16 w = self.width();
        // "playButton -> Play" from the holder's side, "Play -> onPlay of Player" from the control's
        bool fromHere = RKWiring.names(d, t, c.src, e);
        u8* other = RKConnectionsPane.describe(d, t, fromHere ? c.dst : c.src);
        u8* text = (u8*)0;
        if (c.kind == (i32)UXR_CONN_OUTLET)
            {
            // an outlet: "playButton → play" from its holder, "Player.playButton" from what it holds
            text = fromHere ? RKConnectionsPane.joined3(c.member, (u8*)" → ", other)
                            : RKConnectionsPane.joined3(other, (u8*)".", c.member);
            }
        else
            {
            // an action: "play → onPlay" from either end
            text = fromHere ? RKConnectionsPane.joined3(c.member, (u8*)" → ", other)
                            : RKConnectionsPane.joined3(other, (u8*)" → ", c.member);
            }
        // one line: what it is, the layouts it binds in, and x to break it
        UXLabel* l = new UXLabel();
        l.setTitle(text);
        pane.addSubview(l, UXGeom.make((i16)8, y[0], (i16)((i32)w - (i32)198), rh));
        RKConnRow* r = new RKConnRow();
        r.conn = c;
        UXPopUpButton* pu = new UXPopUpButton();
        for (i32 p = (i32)RKSC_ALL; p <= (i32)RKSC_THIS; p = p + (i32)1)
            {
            pu.addItem(RKWiring.presetName(p), p);
            }
        i32 now = RKWiring.presetOf(c.scope, here);
        if (now == (i32)RKSC_CUSTOM)
            {
            pu.addItem(RKWiring.presetName((i32)RKSC_CUSTOM), (i32)RKSC_CUSTOM);
            }
        pu.selectItem(now);
        pu.setAction(&self.onScope);
        pane.addSubview(pu, UXGeom.make((i16)((i32)w - (i32)190), y[0], (i16)104, rh));
        r.scope = pu;
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Remove"); // breaks the connection
        b.setAction(&self.onBreak);
        pane.addSubview(b, UXGeom.make((i16)((i32)w - (i32)82), y[0], (i16)78, rh));
        r.breaker = b;
        rows.add(r);
        y[0] = (i16)((i32)y[0] + (i32)rh + (i32)4);
        }
    bool unconnected(bool header, u8* what, i16* y)
        {
        if (!header)
            {
            y[0] = (i16)((i32)y[0] + (i32)6);
            self.note((u8*)"Not connected here:", y);
            }
        UXLabel* l = new UXLabel();
        l.setTitle(what);
        pane.addSubview(l, UXGeom.make((i16)16, y[0], (i16)((i32)self.width() - (i32)24), self.rowH()));
        y[0] = (i16)((i32)y[0] + (i32)self.rowH() + (i32)2);
        return true;
        }
    void note(u8* text, i16* y)
        {
        UXLabel* l = new UXLabel();
        l.setTitle(text);
        pane.addSubview(l, UXGeom.make((i16)8, y[0], (i16)((i32)self.width() - (i32)16), self.rowH()));
        y[0] = (i16)((i32)y[0] + (i32)self.rowH() + (i32)4);
        }

    // ---- edits ---------------------------------------------------------------------------------
    void onScope(UXControl* sender) : action
        {
        if (loading)
            {
            return;
            }
        for (u32 i = (u32)0; i < rows.count(); i = i + (u32)1)
            {
            RKConnRow* r = (RKConnRow* ?)rows.get(i);
            if ((UXControl*)r.scope == sender)
                {
                i32 p = r.scope.selectedIndex();
                if (p == (i32)RKSC_CUSTOM)
                    {
                    return;
                    }
                self.warn();
                r.conn.scope = RKWiring.scopeOf(p, RKWiring.themeOf(doc, tree));
                self.announce();
                return;
                }
            }
        }
    void onBreak(UXControl* sender) : action
        {
        for (u32 i = (u32)0; i < rows.count(); i = i + (u32)1)
            {
            RKConnRow* r = (RKConnRow* ?)rows.get(i);
            if ((UXControl*)r.breaker == sender)
                {
                self.warn();
                RKWiring.disconnect(doc, r.conn);
                self.announce();
                return;
                }
            }
        }
    void warn(void)
        {
        callback w void(void) = willChange;
        if (w)
            {
            w();
            }
        }
    void announce(void)
        {
        callback c void(void) = changed;
        if (c)
            {
            c();
            }
        }

    // ---- words -----------------------------------------------------------------------------------
    // A connection end, as the designer reads it: a control's name or text, an object's label.
    static u8* describe(UXRscDoc* d, UXRscTree* t, UXRscRef* r)
        {
        if (r.space == (i32)UXR_REF_OWNER)
            {
            return (u8*)"File's Owner";
            }
        if (r.space == (i32)UXR_REF_FIRSTR)
            {
            return (u8*)"First Responder";
            }
        if (r.space == (i32)UXR_REF_TOP)
            {
            UXRscTopObject* to = d.topObjectById(r.a);
            return to != (UXRscTopObject*)0 ? RKOutline.topLabel(to) : (u8*)"a deleted object";
            }
        if (r.space == (i32)UXR_REF_LOGICAL)
            {
            Array<UXRscObject>* all = t.allObjects();
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                UXRscObject* o = (UXRscObject* ?)all.get(i);
                if (o.logicalId == r.b)
                    {
                    return RKOutline.objectLabel(o);
                    }
                }
            // in another layout of the form only: its name there
            for (i32 k = (i32)0; k < d.treeCount(); k = k + (i32)1)
                {
                UXRscTree* ot = d.treeAt(k);
                if (ot == t || d.formIdOf(ot) != r.a)
                    {
                    continue;
                    }
                Array<UXRscObject>* oall = ot.allObjects();
                for (u32 i = (u32)0; i < oall.count(); i = i + (u32)1)
                    {
                    UXRscObject* o = (UXRscObject* ?)oall.get(i);
                    if (o.logicalId == r.b)
                        {
                        return RKConnectionsPane.joined(RKOutline.objectLabel(o), (u8*)" (another layout's)");
                        }
                    }
                }
            return (u8*)"a deleted control";
            }
        return (u8*)"?";
        }
    i16 rowH(void)
        {
        return (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);
        }
    i16 width(void)
        {
        i16 w = pane.bounds().w;
        return w > (i16)0 ? w : (i16)240;
        }
    static u8* joined(u8* a, u8* b)
        {
        return RKConnectionsPane.joined3(a, (u8*)"", b);
        }
    static void listAdd(Data* d, u8* w)
        {
        if (d.length() > (i32)0)
            {
            d.appendBytes((u8*)", ", (i32)2);
            }
        d.appendBytes(w, UXRscTree.len(w));
        }
    static u8* joined3(u8* a, u8* b, u8* c)
        {
        Data* d = UXStr.toData(a);
        d.appendBytes(b, UXRscTree.len(b));
        d.appendBytes(c, UXRscTree.len(c));
        d.appendByte((u8)0);
        return UXStr.cstr(d);
        }
    }
