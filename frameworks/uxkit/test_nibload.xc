// test_nibload.xc — UXNib, the loader for every backend: a form with two layouts, a custom view
// class, a top-level controller and connections scoped to different layout themes (UXNB v3,
// docs/UXNB-V2.md section 11).
//
// The document is built in the model, written, and read back both by the byte parser (UXNibV2)
// and by the model reader; a second write must be byte-identical.  Then the form is loaded for
// the desktop, the phone, and a tablet (which falls back to the desktop layout), and each load
// must bind exactly the connections in its theme's scope.
//
// The loader is neutral code, but views need a driver to live in a view tree; this runs on the
// AppKit driver in capture mode (native widgets, no window shown).
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXNib.xc"
#import "UXRscWrite.xc"

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

i32 gAwoke;

// A custom view, named by a class override on a G_USERDEF.
class Gauge : UXView
    {
    void init(void)
        {
        super.init();
        }
    }

// The form's controller: a top-level object, as IB's "Object" with a custom class.
class LibController : Object<UXDesignable, UXNibAwaking>
    {
    UXTextField* nameField;
    Gauge* gauge;
    i32 plays;
    i32 stopsDesktop;
    i32 stopsPhone;
    i32 awoke;
    void init(void)
        {
        nameField = (UXTextField*)0;
        gauge = (Gauge*)0;
        }
    void onPlay(UXControl* c)
        {
        plays = plays + (i32)1;
        }
    void onStopDesktop(UXControl* c)
        {
        stopsDesktop = stopsDesktop + (i32)1;
        }
    void onStopPhone(UXControl* c)
        {
        stopsPhone = stopsPhone + (i32)1;
        }
    void awakeFromNib(void)
        {
        awoke = awoke + (i32)1;
        gAwoke = gAwoke + (i32)1;
        }
    bool setOutlet(u8* name, Object* value)
        {
        if (streq(name, (u8*)"nameField"))
            { nameField = (UXTextField* ?)value;
            return nameField != (UXTextField*)0;
            }
        if (streq(name, (u8*)"gauge"))
            { gauge = (Gauge* ?)value;
            return gauge != (Gauge*)0;
            }
        return false;
        }
    bool wireAction(u8* name, UXControl* control)
        {
        if (streq(name, (u8*)"onPlay"))
            {
            control.setAction(&self.onPlay);
            return true;
            }
        if (streq(name, (u8*)"onStopDesktop"))
            {
            control.setAction(&self.onStopDesktop);
            return true;
            }
        if (streq(name, (u8*)"onStopPhone"))
            {
            control.setAction(&self.onStopPhone);
            return true;
            }
        return false;
        }
    }

// File's Owner
class Owner : Object<UXDesignable, UXNibAwaking>
    {
    LibController* controller;
    i32 awoke;
    void init(void)
        {
        controller = (LibController*)0;
        }
    void awakeFromNib(void)
        {
        awoke = awoke + (i32)1;
        }
    bool setOutlet(u8* name, Object* value)
        {
        if (streq(name, (u8*)"controller"))
            { controller = (LibController* ?)value;
            return controller != (LibController*)0;
            }
        return false;
        }
    bool wireAction(u8* name, UXControl* control)
        {
        return false;
        }
    }

Object* nibFactory(u8* name)
    {
    if (streq(name, (u8*)"Gauge"))
        {
        return (Object*)new Gauge();
        }
    if (streq(name, (u8*)"LibController"))
        {
        return (Object*)new LibController();
        }
    return (Object*)0;
    }

UXRscObject* add(UXRscObject* parent, i32 type, i32 x, i32 y, i32 w, i32 h, u8* text)
    {
    UXRscObject* o = UXRscObject.make(type, x, y, w, h);
    if (text != (u8*)0)
        {
        o.text = text;
        if (o.ted != (UXRscTedinfo*)0)
            {
            o.ted.text = text;
            }
        }
    parent.addChild(o);
    return o;
    }

UXRscConnection* conn(UXRscDoc* d, i32 kind, UXRscRef* src, UXRscRef* dst, u8* member, u32 scope)
    {
    UXRscConnection* c = new UXRscConnection();
    c.kind = kind;
    c.src = src;
    c.dst = dst;
    c.member = member;
    c.scope = scope;
    d.connections.add(c);
    return c;
    }

i32 gPlay;
i32 gStop;
i32 gName;
i32 gGauge;
i32 gPhoneTree;
i32 gSlider;

UXRscDoc* sample(void)
    {
    UXRscDoc* d = UXRscDoc.emptyDialog();
    UXRscTree* desk = d.treeAt((i32)0);
    desk.name = (u8*)"TRANSPORT";
    UXRscObject* play = add(desk.root, (i32)UXR_T_BUTTON, (i32)8, (i32)8, (i32)64, (i32)24, (u8*)"Play");
    UXRscObject* stop = add(desk.root, (i32)UXR_T_BUTTON, (i32)80, (i32)8, (i32)64, (i32)24, (u8*)"Stop");
    UXRscObject* name = add(desk.root, (i32)UXR_T_FIELD, (i32)8, (i32)40, (i32)200, (i32)24, (u8*)"Untitled");
    UXRscObject* gauge = add(desk.root, (i32)UXR_T_USERDEF, (i32)8, (i32)72, (i32)200, (i32)48, (u8*)0);
    UXRscObject* volume = add(desk.root, (i32)UXR_T_USERDEF, (i32)8, (i32)130, (i32)200, (i32)24, (u8*)0);
    // the phone layout: seeded from the desktop (which gives every control its logical id), then
    // re-nested -- Play and Stop inside a phone-only container, the name field and gauge dropped
    UXRscTree* phone = d.addVariant(desk, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    gPhoneTree = d.indexOfTree(phone);
    gPlay = play.logicalId;
    gStop = stop.logicalId;
    gName = name.logicalId;
    gGauge = gauge.logicalId;
    gSlider = volume.logicalId;
    UXRscObject* root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)180, (i32)320);
    root.logicalId = desk.root.logicalId;
    UXRscObject* scroll = add(root, (i32)UXR_T_IBOX, (i32)0, (i32)0, (i32)180, (i32)320, (u8*)0);
    UXRscObject* p2 = play.deepCopy();
    p2.x = (i32)8;
    p2.y = (i32)8;
    scroll.addChild(p2);
    UXRscObject* v2 = volume.deepCopy();
    v2.y = (i32)80;
    scroll.addChild(v2);
    UXRscObject* s2 = stop.deepCopy();
    s2.x = (i32)8;
    s2.y = (i32)40;
    scroll.addChild(s2);
    phone.root = root;

    UXRscClassOverride* co = new UXRscClassOverride();
    co.view = UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, gGauge);
    co.cls = (u8*)"Gauge";
    d.classOverrides.add(co);
    // a UXKit control GEM has no type for: a G_USERDEF of class UXSlider, its range in attributes,
    // and the phone varying its value
    d.setClassOf(desk, volume, (u8*)"UXSlider");
    d.setAttrOf(desk, volume, (u8*)"min", (u8*)"0");
    d.setAttrOf(desk, volume, (u8*)"max", (u8*)"10");
    d.setAttrOf(desk, volume, (u8*)"value", (u8*)"3");
    d.setAttrIn((i32)0, gSlider, (i32)UXRscConnection.themeBit((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT), (u8*)"value", (u8*)"7");
    UXRscTopObject* to = new UXRscTopObject();
    to.id = (i32)1;
    to.cls = (u8*)"LibController";
    to.label = (u8*)"Library Controller";
    d.topObjects.add(to);

    UXRscRef* ctl = UXRscRef.make((i32)UXR_REF_TOP, (i32)1, (i32)0);
    u32 desktop = UXRscConnection.themeBit((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE);
    u32 phones = UXRscConnection.themeBit((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT) |
                 UXRscConnection.themeBit((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_LANDSCAPE);
    conn(d, (i32)UXR_CONN_ACTION, UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, gPlay), ctl, (u8*)"onPlay", (u32)0);
    conn(d, (i32)UXR_CONN_ACTION, UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, gStop), ctl, (u8*)"onStopDesktop", desktop);
    conn(d, (i32)UXR_CONN_ACTION, UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, gStop), ctl, (u8*)"onStopPhone", phones);
    conn(d, (i32)UXR_CONN_OUTLET, ctl, UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, gName), (u8*)"nameField", (u32)0);
    conn(d, (i32)UXR_CONN_OUTLET, UXRscRef.make((i32)UXR_REF_OWNER, (i32)0, (i32)0), ctl, (u8*)"controller", (u32)0);
    conn(d, (i32)UXR_CONN_OUTLET, ctl, UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, gGauge), (u8*)"gauge", (u32)0);

    // a tree in no form, loaded as its own single `any` layout
    UXRscTree* about = new UXRscTree();
    about.name = (u8*)"ABOUT";
    about.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)200, (i32)100);
    add(about.root, (i32)UXR_T_STRING, (i32)8, (i32)8, (i32)180, (i32)16, (u8*)"About");
    d.addTree(about);

    // an extension section this build does not interpret, odd-sized, kept verbatim
    UXRscExtSection* x = new UXRscExtSection();
    x.tag = (u32)$58545241; // 'XTRA', a tag no build interprets
    x.body = UXData.fromBytes((u8*)"abc", (i32)3);
    d.extSections.add(x);
    return d;
    }

bool sameBytes(UXData* a, UXData* b)
    {
    if (a.length() != b.length())
        {
        return false;
        }
    u8* p = a.bytes();
    u8* q = b.bytes();
    for (i32 i = (i32)0; i < a.length(); i = i + (i32)1)
        {
        if (p[i] != q[i])
            {
            return false;
            }
        }
    return true;
    }

UXButton* button(UXNibInstance* ni, i32 logical)
    { return (UXButton* ?)ni.viewForLogical(logical);
    }

void main(void)
    {
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* drv = new UXAppKitDriver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!drv.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }
    UXNib.registerObjectFactory((pointer)&nibFactory);
    UXRscDoc* d = sample();
    UXData* bytes = UXRscWriter.write(d);

    Stdio.printf("-- the chunk, through the byte parser\n");
    UXNibV2* nib = UXNibV2.open(bytes.bytes(), (u32)bytes.length());
    checkTrue("chunk opens", nib != (UXNibV2*)0);
    if (nib == (UXNibV2*)0)
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        return;
        }
    check("version", nib.version(), (i32)3);
    check("connections", nib.connCount(), (i32)6);
    check("onStopDesktop's scope is the desktop", (i32)nib.connScope((i32)1), (i32)UXRscConnection.themeBit((i32)UXR_V_DESKTOP, (i32)0));
    checkTrue("onPlay binds in every theme", nib.connInScope((i32)0, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_LANDSCAPE));
    checkTrue("onStopPhone does not bind on the desktop", !nib.connInScope((i32)2, (i32)UXR_V_DESKTOP, (i32)0));
    checkTrue("member names", streq(nib.connMember((i32)2), (u8*)"onStopPhone"));
    check("top objects", nib.topObjectCount(), (i32)1);
    checkTrue("top object class", streq(nib.topObjectName((i32)0), (u8*)"LibController"));
    checkTrue("top object label", streq(nib.topObjectLabel((i32)0), (u8*)"Library Controller"));
    check("class overrides: the gauge and the slider", nib.classOverrideCount(), (i32)2);
    checkTrue("class override name", streq(nib.classOverrideName((i32)0), (u8*)"Gauge"));
    check("extension sections: the names, the attributes and XTRA", nib.extCount(), (i32)3);
    check("the names come first", (i32)nib.extTag((i32)0), (i32)$4E414D45);
    check("then the attributes", (i32)nib.extTag((i32)1), (i32)$41545452);
    check("XTRA is kept", (i32)nib.extTag((i32)2), (i32)$58545241);
    check("at its size", (i32)nib.extSize((i32)2), (i32)3);
    i32 chosen = (i32)0;
    check("the byte parser picks the phone tree for a phone", nib.selectTree((i32)0, (i32)UXR_V_PHONE, &chosen), gPhoneTree);

    Stdio.printf("-- the chunk, through the model reader, and back out\n");
    UXRscDoc* r = UXRscReader.read(bytes.bytes(), bytes.length());
    checkTrue("reads", r != (UXRscDoc*)0);
    check("connections", (i32)r.connections.count(), (i32)6);
    UXRscConnection* c2 = (UXRscConnection* ?)r.connections.get((u32)2);
    check("scope survives", (i32)c2.scope, (i32)((UXRscConnection* ?)d.connections.get((u32)2)).scope);
    check("src logical id survives", c2.src.b, gStop);
    checkTrue("member survives", streq(c2.member, (u8*)"onStopPhone"));
    checkTrue("label survives", streq(((UXRscTopObject* ?)r.topObjects.get((u32)0)).label, (u8*)"Library Controller"));
    check("extension body survives", ((UXRscExtSection* ?)r.extSections.get((u32)0)).body.length(), (i32)3);
    checkTrue("a second write is byte-identical", sameBytes(bytes, UXRscWriter.write(r)));

    Stdio.printf("-- desktop\n");
    Owner* own = new Owner();
    UXNibInstance* ni = UXNib.loadDocAs(r, (i32)0, (i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE, (UXDesignable*)own, (UXView*)0);
    checkTrue("loads", ni != (UXNibInstance*)0);
    check("the desktop layout", ni.klass, (i32)UXR_V_DESKTOP);
    check("bound", ni.bound, (i32)5);
    checkTrue("the attributes survived the save", r.attrs.count() == (u32)4);
    check("out of scope", ni.outOfScope, (i32)1);
    check("skipped", ni.skipped, (i32)0);
    LibController* lc = own.controller;
    checkTrue("owner.controller is the top object", lc != (LibController*)0 && (Object*)lc == ni.topObject((i32)1));
    checkTrue("Play is a button", button(ni, gPlay) != (UXButton*)0);
    checkTrue("the gauge is a Gauge", (Gauge* ?)ni.viewForLogical(gGauge) != (Gauge*)0);
    checkTrue("controller.gauge", lc != (LibController*)0 && (Object*)lc.gauge == (Object*)ni.viewForLogical(gGauge));
    checkTrue("controller.nameField", lc != (LibController*)0 && (Object*)lc.nameField == (Object*)ni.viewForLogical(gName));
    checkTrue("the field holds its text", lc != (LibController*)0 && lc.nameField != (UXTextField*)0 && streq(lc.nameField.text(), (u8*)"Untitled"));
    if (lc != (LibController*)0)
        {
        button(ni, gPlay).fire();
        button(ni, gStop).fire();
        check("Play -> onPlay", lc.plays, (i32)1);
        check("Stop -> onStopDesktop", lc.stopsDesktop, (i32)1);
        check("not onStopPhone", lc.stopsPhone, (i32)0);
        check("controller awoke once", lc.awoke, (i32)1);
        }
    check("File's Owner awoke once", own.awoke, (i32)1);
    check("the root is the form's size", (i32)ni.root.frame().w, (i32)320);
    UXSlider* vol = (UXSlider* ?)ni.viewForLogical(gSlider);
    checkTrue("a G_USERDEF of class UXSlider is a slider", vol != (UXSlider*)0);
    check("with its range and value from the attributes", vol != (UXSlider*)0 ? vol.nativeMax() * (i32)100 + vol.intValue() : (i32)-1, (i32)1003);

    Stdio.printf("-- phone, portrait\n");
    Owner* own2 = new Owner();
    UXNibInstance* np = UXNib.loadDocAs(r, (i32)0, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT, (UXDesignable*)own2, (UXView*)0);
    checkTrue("loads", np != (UXNibInstance*)0);
    check("the phone layout", np.klass, (i32)UXR_V_PHONE);
    check("the phone tree", r.indexOfTree(np.tree), gPhoneTree);
    UXSlider* pvol = (UXSlider* ?)np.viewForLogical(gSlider);
    check("the phone's slider has the value the phone varies", pvol != (UXSlider*)0 ? pvol.intValue() : (i32)-1, (i32)7);
    check("bound", np.bound, (i32)3);
    check("skipped (the dropped field and gauge)", np.skipped, (i32)2);
    check("out of scope", np.outOfScope, (i32)1);
    LibController* pc = own2.controller;
    checkTrue("a fresh controller", pc != (LibController*)0 && pc != lc);
    checkTrue("no name field on the phone", pc != (LibController*)0 && pc.nameField == (UXTextField*)0);
    checkTrue("Play sits in the phone-only container", button(np, gPlay) != (UXButton*)0 && (Object*)button(np, gPlay).superview != (Object*)np.root);
    if (pc != (LibController*)0)
        {
        button(np, gStop).fire();
        check("Stop -> onStopPhone", pc.stopsPhone, (i32)1);
        check("not onStopDesktop", pc.stopsDesktop, (i32)0);
        }

    Stdio.printf("-- tablet (no layout of its own: the desktop's)\n");
    UXNibInstance* nt = UXNib.loadDocAs(r, (i32)0, (i32)UXR_V_TABLET, (i32)UXR_V_ORIENT_LANDSCAPE, (UXDesignable*)new Owner(), (UXView*)0);
    checkTrue("loads", nt != (UXNibInstance*)0);
    check("falls back to the desktop", nt.klass, (i32)UXR_V_DESKTOP);
    check("binds the desktop's connections", nt.bound, (i32)5);

    Stdio.printf("-- a tree in no form\n");
    UXNibInstance* na = UXNib.loadDocAs(r, (i32)2, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT, (UXDesignable*)new Owner(), (UXView*)0);
    checkTrue("loads", na != (UXNibInstance*)0);
    check("as `any`", na.klass, (i32)UXR_V_ANY);
    check("one label and the root", (i32)na.views.count(), (i32)2);
    checkTrue("a variant tree is not loadable by its own index", UXNib.loadDocAs(r, gPhoneTree, (i32)UXR_V_PHONE, (i32)0, (UXDesignable*)new Owner(), (UXView*)0) == (UXNibInstance*)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXNib v3 -- themes, scoped connections, class overrides, top objects, awakeFromNib\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
