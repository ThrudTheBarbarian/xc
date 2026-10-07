// RKIdentity.xc — the Identity inspector: what the selected thing IS.
//
// Interface Builder's first inspector tab.  For a control: its class (a WaveformView rather than
// the plain view its GEM type implies), its name, its logical id and the layouts it appears in.
// For one of the document's objects: its class and the name the outline shows.  For File's
// Owner: its class, which is what tells the designer which outlets and actions there are to
// connect.  First Responder has no class of its own.
//
// The pane writes the model itself, through the document's own helpers (setClassOf and the
// rest), and tells the controller before and after so the edit is undoable and the outline and
// canvas catch up.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXMetrics.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "UXRsc.xc"
#import "RKOutline.xc"
#import "RKClasses.xc"
#import "RKVariants.xc"

class RKIdentity : Object
    {
    UXView* pane;
    UXRscDoc* doc;
    i32 kind;          // RKON_* of what is shown; 0 = nothing
    UXRscTree* tree;   // RKON_VIEW: the layout it is in
    UXRscObject* obj;  // RKON_VIEW
    i32 topId;         // RKON_OBJECT
    UXTextField* classField;
    UXTextField* nameField;
    UXLabel* idLabel;
    UXLabel* layoutsLabel;
    UXLabel* classInfo;     // where the class's outlets and actions come from
    RKClassBook* book;      // the controller's: what is known about classes
    UXTextField* outletName; // declaring: a new outlet's name and type, a new action's name
    UXTextField* outletType;
    UXTextField* actionName;
    Array<UXButton>* removers; // a "-" per declared member, in rows order
    Array<RKMember>* removable;
    bool loading;
    // the controller's: before an edit (`key` is the field typed into, so a word is one step), after
    callback willChange void(Object* key);
    callback changed void(void);

    void init(void)
        {
        pane = (UXView*)0;
        doc = (UXRscDoc*)0;
        kind = (i32)0;
        tree = (UXRscTree*)0;
        obj = (UXRscObject*)0;
        topId = (i32)0;
        classField = (UXTextField*)0;
        nameField = (UXTextField*)0;
        idLabel = (UXLabel*)0;
        layoutsLabel = (UXLabel*)0;
        classInfo = (UXLabel*)0;
        book = (RKClassBook*)0;
        outletName = (UXTextField*)0;
        outletType = (UXTextField*)0;
        actionName = (UXTextField*)0;
        removers = new Array();
        removable = new Array();
        loading = false;
        willChange = (callback void(Object * key))0;
        changed = (callback void(void))0;
        }
    void attach(UXView* p)
        {
        pane = p;
        }

    // ---- what is shown ---------------------------------------------------------------------
    void showNothing(void)
        {
        self.begin((i32)0);
        self.end();
        }
    void showView(UXRscDoc* d, UXRscTree* t, UXRscObject* o)
        {
        doc = d;
        tree = t;
        obj = o;
        self.begin((i32)RKON_VIEW);
        if (pane == (UXView*)0)
            {
            self.end();
            return;
            }
        i16 y = (i16)8;
        u8* cls = d.classOf(t, o);
        classField = self.field((u8*)"Class", cls != (u8*)0 ? cls : (u8*)"", UXRsc.defaultClassFor(o.type), &y);
        nameField = self.field((u8*)"Name", o.name != (u8*)0 ? o.name : (u8*)"", (u8*)"none", &y);
        idLabel = self.label((u8*)"Logical id", o.logicalId != (i32)0 ? RKIdentity.num(o.logicalId) : (u8*)"none yet", &y);
        layoutsLabel = self.label((u8*)"Layouts", self.layoutsOf(d, t, o), &y);
        self.classSection(cls, UXRsc.defaultClassFor(o.type), &y);
        self.end();
        }
    void showObject(UXRscDoc* d, i32 id)
        {
        doc = d;
        topId = id;
        self.begin((i32)RKON_OBJECT);
        UXRscTopObject* to = d.topObjectById(id);
        if (pane == (UXView*)0 || to == (UXRscTopObject*)0)
            {
            self.end();
            return;
            }
        i16 y = (i16)8;
        classField = self.field((u8*)"Class", to.cls, (u8*)"Object", &y);
        nameField = self.field((u8*)"Label", to.label, (u8*)"the class", &y);
        self.classSection(to.cls, (u8*)"Object", &y);
        self.end();
        }
    void showOwner(UXRscDoc* d)
        {
        doc = d;
        self.begin((i32)RKON_OWNER);
        if (pane == (UXView*)0)
            {
            self.end();
            return;
            }
        i16 y = (i16)8;
        classField = self.field((u8*)"Class", d.ownerClass, (u8*)"the loading object's", &y);
        self.label((u8*)"", (u8*)"The object that loads this file.", &y);
        self.classSection(d.ownerClass, (u8*)"Object", &y);
        self.end();
        }
    void showFirstResponder(UXRscDoc* d)
        {
        doc = d;
        self.begin((i32)RKON_FIRSTR);
        if (pane == (UXView*)0)
            {
            self.end();
            return;
            }
        i16 y = (i16)8;
        self.label((u8*)"", (u8*)"Whatever has the keyboard focus.", &y);
        self.end();
        }

    // ---- edits -----------------------------------------------------------------------------
    void onEdit(UXTextField* sender) : action
        {
        if (loading || doc == (UXRscDoc*)0)
            {
            return;
            }
        callback w void(Object * key) = willChange;
        if (w)
            {
            w((Object*)sender);
            }
        u8* v = RKIdentity.dup(sender.text());
        if (sender == classField)
            {
            if (kind == (i32)RKON_VIEW)
                {
                doc.setClassOf(tree, obj, v);
                if (idLabel != (UXLabel*)0 && obj.logicalId != (i32)0)
                    {
                    idLabel.setText(RKIdentity.num(obj.logicalId));
                    }
                }
            else if (kind == (i32)RKON_OBJECT)
                {
                UXRscTopObject* to = doc.topObjectById(topId);
                if (to != (UXRscTopObject*)0)
                    {
                    to.cls = v;
                    }
                }
            else if (kind == (i32)RKON_OWNER)
                {
                doc.ownerClass = v;
                }
            }
        else if (sender == nameField)
            {
            if (kind == (i32)RKON_VIEW)
                {
                // a control's name is who it is, so every layout's copy has it
                obj.name = v;
                Array<UXRscObject>* cs = RKVariants.copiesOf(doc, tree, obj);
                for (u32 i = (u32)0; i < cs.count(); i = i + (u32)1)
                    {
                    ((UXRscObject* ?)cs.get(i)).name = v;
                    }
                }
            else if (kind == (i32)RKON_OBJECT)
                {
                UXRscTopObject* to = doc.topObjectById(topId);
                if (to != (UXRscTopObject*)0)
                    {
                    to.label = v;
                    }
                }
            }
        callback c void(void) = changed;
        if (c)
            {
            c();
            }
        }

    // ---- the class: where its outlets and actions come from, and declaring them ----------------
    // `cls` is the class set ("" or 0 for none, when `fallback` is what it is).  A reflected class
    // lists its members; one Rocks cannot see can have them declared here, kept in the document.
    void classSection(u8* cls, u8* fallback, i16* y)
        {
        if (book == (RKClassBook*)0)
            {
            return;
            }
        bool custom = cls != (u8*)0 && cls[0] != (u8)0;
        u8* name = custom ? cls : fallback;
        RKClass* c = book.find(name);
        y[0] = (i16)((i32)y[0] + (i32)6);
        if (c != (RKClass*)0 && c.origin == (i32)RKC_UXKIT)
            {
            classInfo = self.label((u8*)"", custom ? (u8*)"A UXKit class." : (u8*)"No class of its own: give it one above.", y);
            return;
            }
        if (c != (RKClass*)0 && c.origin == (i32)RKC_REFLECTED)
            {
            classInfo = self.label((u8*)"", RKIdentity.joined((u8*)"From ", RKIdentity.baseName(c.source)), y);
            self.memberRows((u8*)"Outlets", book.outletsOf(name), false, y);
            self.memberRows((u8*)"Actions", book.actionsOf(name), false, y);
            return;
            }
        if (!custom)
            {
            return;
            }
        classInfo = self.label((u8*)"", c != (RKClass*)0 ? (u8*)"Declared here: not found in the app's source."
                                                       : (u8*)"Not found in the app's source: declare its outlets and actions here.", y);
        self.memberRows((u8*)"Outlets", c != (RKClass*)0 ? c.outlets : new Array(), true, y);
        outletName = self.smallField((u8*)"name", (i16)8, (i16)110, y[0]);
        outletType = self.smallField((u8*)"UXView*", (i16)122, (i16)100, y[0]);
        self.button((u8*)"Add Outlet", (i16)226, y[0], &self.onAddOutlet);
        y[0] = (i16)((i32)y[0] + (i32)self.rowH() + (i32)6);
        self.memberRows((u8*)"Actions", c != (RKClass*)0 ? c.actions : new Array(), true, y);
        actionName = self.smallField((u8*)"name", (i16)8, (i16)214, y[0]);
        self.button((u8*)"Add Action", (i16)226, y[0], &self.onAddAction);
        y[0] = (i16)((i32)y[0] + (i32)self.rowH() + (i32)6);
        }
    void memberRows(u8* title, Array<RKMember>* ms, bool removable_, i16* y)
        {
        UXLabel* h = new UXLabel();
        h.setTitle(title);
        pane.addSubview(h, UXGeom.make((i16)8, y[0], (i16)120, self.rowH()));
        y[0] = (i16)((i32)y[0] + (i32)self.rowH() + (i32)2);
        if (ms.count() == (u32)0)
            {
            self.label((u8*)"", (u8*)"none", y);
            return;
            }
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            RKMember* m = (RKMember* ?)ms.get(i);
            UXLabel* l = new UXLabel();
            l.setTitle(m.type != (u8*)0 && m.type[0] != (u8)0 ? RKIdentity.joined3(m.name, (u8*)"  ", m.type) : m.name);
            pane.addSubview(l, UXGeom.make((i16)16, y[0], (i16)((i32)self.width() - (i32)60), self.rowH()));
            if (removable_)
                {
                UXButton* b = new UXButton();
                b.setTitle((u8*)"-");
                b.setAction(&self.onRemoveMember);
                pane.addSubview(b, UXGeom.make((i16)((i32)self.width() - (i32)40), y[0], (i16)30, self.rowH()));
                removers.add(b);
                removable.add(m);
                }
            y[0] = (i16)((i32)y[0] + (i32)self.rowH() + (i32)2);
            }
        }
    // The class being declared: the one set, made a declaration if it is not one yet.
    RKClass* declaring(void)
        {
        u8* cls = classField != (UXTextField*)0 ? classField.text() : (u8*)"";
        if (book == (RKClassBook*)0 || cls == (u8*)0 || cls[0] == (u8)0)
            {
            return (RKClass*)0;
            }
        u8* parent = kind == (i32)RKON_VIEW && obj != (UXRscObject*)0 ? UXRsc.defaultClassFor(obj.type) : (u8*)"Object";
        return book.declare(RKIdentity.dup(cls), parent);
        }
    void onAddOutlet(UXControl* sender) : action
        {
        u8* n = outletName != (UXTextField*)0 ? outletName.text() : (u8*)"";
        if (n == (u8*)0 || n[0] == (u8)0)
            {
            return;
            }
        u8* t = outletType != (UXTextField*)0 && outletType.text()[0] != (u8)0 ? outletType.text() : (u8*)"UXView*";
        self.declareMember(true, RKIdentity.dup(n), RKIdentity.dup(t));
        }
    void onAddAction(UXControl* sender) : action
        {
        u8* n = actionName != (UXTextField*)0 ? actionName.text() : (u8*)"";
        if (n == (u8*)0 || n[0] == (u8)0)
            {
            return;
            }
        self.declareMember(false, RKIdentity.dup(n), (u8*)"UXControl*");
        }
    void declareMember(bool outlet, u8* name, u8* type)
        {
        callback w void(Object * key) = willChange;
        if (w)
            {
            w((Object*)0);
            }
        RKClass* c = self.declaring();
        if (c == (RKClass*)0)
            {
            return;
            }
        (outlet ? c.outlets : c.actions).add(RKMember.make(name, type));
        book.saveTo(doc);
        self.afterDeclaring();
        }
    void onRemoveMember(UXControl* sender) : action
        {
        for (u32 i = (u32)0; i < removers.count(); i = i + (u32)1)
            {
            if ((UXControl*)removers.get(i) == sender)
                {
                RKMember* m = (RKMember* ?)removable.get(i);
                callback w void(Object * key) = willChange;
                if (w)
                    {
                    w((Object*)0);
                    }
                RKClass* c = self.declaring();
                if (c != (RKClass*)0)
                    {
                    RKIdentity.removeMember(c.outlets, m);
                    RKIdentity.removeMember(c.actions, m);
                    book.saveTo(doc);
                    }
                self.afterDeclaring();
                return;
                }
            }
        }
    static void removeMember(Array<RKMember>* ms, RKMember* m)
        {
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            if ((RKMember* ?)ms.get(i) == m)
                {
                ms.removeAt(i);
                return;
                }
            }
        }
    // Re-show what was shown, with the new member, and tell the controller.
    void afterDeclaring(void)
        {
        self.reshow();
        callback c void(void) = changed;
        if (c)
            {
            c();
            }
        }
    void reshow(void)
        {
        if (kind == (i32)RKON_VIEW)
            {
            self.showView(doc, tree, obj);
            }
        else if (kind == (i32)RKON_OBJECT)
            {
            self.showObject(doc, topId);
            }
        else if (kind == (i32)RKON_OWNER)
            {
            self.showOwner(doc);
            }
        }
    UXTextField* smallField(u8* hint, i16 x, i16 w, i16 y)
        {
        UXTextField* f = new UXTextField();
        f.setPlaceholder(hint);
        pane.addSubview(f, UXGeom.make(x, y, w, self.rowH()));
        return f;
        }
    void button(u8* title, i16 x, i16 y, callback a void(UXControl* sender))
        {
        UXButton* b = new UXButton();
        b.setTitle(title);
        b.setAction(a);
        pane.addSubview(b, UXGeom.make(x, y, (i16)((i32)self.width() - (i32)x - (i32)8), self.rowH()));
        }
    i16 rowH(void)
        {
        return (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);
        }
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
    static u8* joined(u8* a, u8* b)
        {
        return RKIdentity.joined3(a, (u8*)"", b);
        }
    static u8* joined3(u8* a, u8* b, u8* c)
        {
        Data* d = UXStr.toData(a);
        d.appendBytes(b, UXRscTree.len(b));
        d.appendBytes(c, UXRscTree.len(c));
        d.appendByte((u8)0);
        return UXStr.cstr(d);
        }

    // ---- building the rows -----------------------------------------------------------------
    void begin(i32 k)
        {
        loading = true;
        kind = k;
        classField = (UXTextField*)0;
        nameField = (UXTextField*)0;
        idLabel = (UXLabel*)0;
        layoutsLabel = (UXLabel*)0;
        classInfo = (UXLabel*)0;
        outletName = (UXTextField*)0;
        outletType = (UXTextField*)0;
        actionName = (UXTextField*)0;
        removers = new Array();
        removable = new Array();
        if (pane != (UXView*)0)
            {
            pane.removeAllSubviews();
            }
        }
    void end(void)
        {
        loading = false;
        }
    UXTextField* field(u8* title, u8* value, u8* hint, i16* y)
        {
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindField, (i32)UX_FORM_DESKTOP);
        i16 w = self.width();
        UXLabel* l = new UXLabel();
        l.setTitle(title);
        pane.addSubview(l, UXGeom.make((i16)8, y[0], (i16)80, rh));
        UXTextField* f = new UXTextField();
        f.setText(value != (u8*)0 ? value : (u8*)"");
        f.setPlaceholder(hint);
        f.setOnChange(&self.onEdit);
        pane.addSubview(f, UXGeom.make((i16)88, y[0], (i16)((i32)w - (i32)96), rh));
        y[0] = (i16)((i32)y[0] + (i32)rh + (i32)6);
        return f;
        }
    UXLabel* label(u8* title, u8* value, i16* y)
        {
        i16 rh = (i16)UXMetrics.stdHeightFor((i32)UXKindLabel, (i32)UX_FORM_DESKTOP);
        i16 w = self.width();
        if (title[0] != (u8)0)
            {
            UXLabel* l = new UXLabel();
            l.setTitle(title);
            pane.addSubview(l, UXGeom.make((i16)8, y[0], (i16)80, rh));
            }
        UXLabel* v = new UXLabel();
        v.setTitle(value);
        i16 x = title[0] != (u8)0 ? (i16)88 : (i16)8;
        pane.addSubview(v, UXGeom.make(x, y[0], (i16)((i32)w - (i32)x - (i32)8), rh));
        y[0] = (i16)((i32)y[0] + (i32)rh + (i32)6);
        return v;
        }
    i16 width(void)
        {
        i16 w = pane.bounds().w;
        return w > (i16)0 ? w : (i16)240;
        }

    // The layouts of the control's form that have it ("desktop, phone portrait"), by logical id.
    u8* layoutsOf(UXRscDoc* d, UXRscTree* t, UXRscObject* o)
        {
        UXRscForm* f = d.formOf(t);
        if (f == (UXRscForm*)0)
            {
            return (u8*)"this form's only layout";
            }
        if (o.logicalId == (i32)0)
            {
            return (u8*)"this layout only";
            }
        Data* b = Data.withCapacity((u32)((i32)64));
        for (i32 v = (i32)0; v < f.variantCount(); v = v + (i32)1)
            {
            UXRscVariant* va = f.variantAt(v);
            Array<UXRscObject>* all = va.tree.allObjects();
            bool has = false;
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                if (((UXRscObject* ?)all.get(k)).logicalId == o.logicalId)
                    {
                    has = true;
                    }
                }
            if (!has)
                {
                continue;
                }
            if (b.length() > (i32)0)
                {
                b.appendBytes((u8*)", ", (i32)2);
                }
            u8* nm = RKIdentity.themeName(va.klass, va.orient);
            b.appendBytes(nm, UXRscTree.len(nm));
            }
        b.appendByte((u8)0);
        return UXStr.cstr(b);
        }
    static u8* themeName(i32 klass, i32 orient)
        {
        if (klass == (i32)UXR_V_PHONE)
            {
            return orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (u8*)"phone landscape" : (orient == (i32)UXR_V_ORIENT_PORTRAIT ? (u8*)"phone portrait" : (u8*)"phone");
            }
        if (klass == (i32)UXR_V_TABLET)
            {
            return orient == (i32)UXR_V_ORIENT_LANDSCAPE ? (u8*)"tablet landscape" : (orient == (i32)UXR_V_ORIENT_PORTRAIT ? (u8*)"tablet portrait" : (u8*)"tablet");
            }
        return klass == (i32)UXR_V_ANY ? (u8*)"any" : (u8*)"desktop";
        }
    static u8* num(i32 v)
        {
        u8* b = new u8[(u32)12];
        i32 n = (i32)0;
        u8 t[12];
        if (v == (i32)0)
            {
            b[0] = (u8)'0';
            b[1] = (u8)0;
            return b;
            }
        while (v > (i32)0 && n < (i32)10)
            {
            t[n] = (u8)((i32)'0' + v % (i32)10);
            v = v / (i32)10;
            n = n + (i32)1;
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            b[i] = t[n - (i32)1 - i];
            }
        b[n] = (u8)0;
        return b;
        }
    // A copy: a field's buffer belongs to the driver and is reused.
    static u8* dup(u8* s)
        {
        i32 n = UXRscTree.len(s);
        u8* b = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            b[i] = s[i];
            }
        b[n] = (u8)0;
        return b;
        }
    }
