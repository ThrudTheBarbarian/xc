// test_nib.xc — the nib pipeline end to end, on GEM, exercising the post-#9 loader.
//
// Builds a .rsc WITH an UXNB chunk in-process, loads it through UXNib.loadWiredMem against a
// File's-Owner controller, and checks the whole graph landed — including the two cases #9 unlocks:
//   * a designable VIEW (Gauge, a G_USERDEF adopting UXDesignable) as an ACTION target — the loader
//     downcasts (UXDesignable* ?)view CROSS-MODULE (client class, library protocol);
//   * a top-level object (Helper) as an OUTLET value.
// The UXDesignable bodies + factory here are hand-written stand-ins for what the compiler generates.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXNib.xc"
#import "UXControl.xc"
#import "UXDesignable.xc"
#import "UXBoot.xc"

// --- the RSC engine (libGEM), for building the test .rsc ---
pointer rsc_new(void);
i32 rsc_alloc_objects(pointer r, i32 n);
pointer rsc_objects(pointer r, pointer count);
i32 rsc_add_tree(pointer r, i32 root);
u8* rsc_intern_str(pointer r, u8* s);
i32 rsc_write(pointer r, pointer out, pointer len, pointer err);
void rsc_free(pointer r);
void rsc_nib_add_classov_at(pointer r, i32 sp, i32 a, i32 b, u8* cls);
void rsc_nib_add_topobj(pointer r, u16 id, u8* cls);
void rsc_nib_add_conn_at(pointer r, i32 kind, i32 ss, i32 sa, i32 sb, i32 ds, i32 da, i32 db, u8* member);

bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

i32 gClicked;
i32 gGaugeClicked;

// A custom G_USERDEF view that is ALSO designable (has an action) — exercises the #9
// (UXDesignable* ?)view downcast when it is used as an action target.
class Gauge : UXView<UXDesignable>
    {
    void init(void)
        {
        super.init();
        }
    void onGauge(UXControl* c)
        {
        gGaugeClicked = gGaugeClicked + (i32)1;
        }
    bool setOutlet(u8* name, Object* value)
        {
        return false;
        }
    bool wireAction(u8* name, UXControl* control)
        {
        if (streq(name, (u8*)"onGauge"))
            {
            control.setAction(&self.onGauge);
            return true;
            }
        return false;
        }
    }

    // A non-view top-level object — used as an OUTLET value (previously restricted, now allowed by #9).
    class Helper : Object<UXDesignable>
    {
    void init(void)
        {
        }
    bool setOutlet(u8* name, Object* value)
        {
        return false;
        }
    bool wireAction(u8* name, UXControl* control)
        {
        return false;
        }
    }

    // File's Owner
    class Controller : Object<UXDesignable>
    {
    UXView* gauge;  // outlet -> a view
    Helper* helper; // outlet -> a top-level object (#9)
    void init(void)
        {
        gauge = (UXView*)0;
        helper = (Helper*)0;
        }
    void onClick(UXControl* c)
        {
        gClicked = gClicked + (i32)1;
        }
    // (compiler-generated later)
    bool setOutlet(u8* name, Object* value)
        {
        if (streq(name, (u8*)"gauge"))
            { gauge  = (UXView* ?)value;
            return gauge != (UXView*)0;
            }
        if (streq(name, (u8*)"helper"))
            { helper = (Helper* ?)value;
            return helper != (Helper*)0;
            }
        return false;
        }
    bool wireAction(u8* name, UXControl* control)
        {
        if (streq(name, (u8*)"onClick"))
            {
            control.setAction(&self.onClick);
            return true;
            }
        return false;
        }
    }

    // One factory, Object* (post-#9): covers both the custom view and the top-level object.
    Object* nibFactory(u8* name)
    {
    if (streq(name, (u8*)"Gauge"))
        {
        return (Object*)new Gauge();
        }
    if (streq(name, (u8*)"Helper"))
        {
        return (Object*)new Helper();
        }
    return (Object*)0;
    }

pointer buildRsc(i32* lenOut)
    {
    pointer r = rsc_new();
    rsc_alloc_objects(r, (i32)4);
    i32 cnt = (i32)0;
    OBJECT* o = (OBJECT*)rsc_objects(r, (pointer)&cnt);
    // [0] root G_BOX
    o[0].ob_next = (i16)-1;
    o[0].ob_head = (i16)1;
    o[0].ob_tail = (i16)3;
    o[0].ob_type = (u16)G_BOX;
    o[0].ob_flags = (u16)0;
    o[0].ob_state = (u16)0;
    o[0].ob_spec = (pointer)0;
    o[0].ob_x = (i16)0;
    o[0].ob_y = (i16)0;
    o[0].ob_w = (i16)200;
    o[0].ob_h = (i16)120;
    // [1] G_USERDEF -> Gauge (a designable view)
    o[1].ob_next = (i16)2;
    o[1].ob_head = (i16)-1;
    o[1].ob_tail = (i16)-1;
    o[1].ob_type = (u16)G_USERDEF;
    o[1].ob_flags = (u16)0;
    o[1].ob_state = (u16)0;
    o[1].ob_spec = (pointer)0;
    o[1].ob_x = (i16)10;
    o[1].ob_y = (i16)10;
    o[1].ob_w = (i16)80;
    o[1].ob_h = (i16)40;
    // [2] G_BUTTON "OK"
    o[2].ob_next = (i16)3;
    o[2].ob_head = (i16)-1;
    o[2].ob_tail = (i16)-1;
    o[2].ob_type = (u16)G_BUTTON;
    o[2].ob_flags = (u16)0;
    o[2].ob_state = (u16)0;
    o[2].ob_spec = (pointer)rsc_intern_str(r, (u8*)"OK");
    o[2].ob_x = (i16)10;
    o[2].ob_y = (i16)60;
    o[2].ob_w = (i16)60;
    o[2].ob_h = (i16)20;
    // [3] G_BUTTON "Go"
    o[3].ob_next = (i16)0;
    o[3].ob_head = (i16)-1;
    o[3].ob_tail = (i16)-1;
    o[3].ob_type = (u16)G_BUTTON;
    o[3].ob_flags = (u16)OF_LASTOB;
    o[3].ob_state = (u16)0;
    o[3].ob_spec = (pointer)rsc_intern_str(r, (u8*)"Go");
    o[3].ob_x = (i16)100;
    o[3].ob_y = (i16)60;
    o[3].ob_w = (i16)60;
    o[3].ob_h = (i16)20;
    rsc_add_tree(r, (i32)0);
    rsc_nib_add_classov_at(r, (i32)0, (i32)0, (i32)1, (u8*)"Gauge");
    rsc_nib_add_topobj(r, (u16)1, (u8*)"Helper");
    // OUTLET owner.gauge  = view(0,1) [the Gauge]
    rsc_nib_add_conn_at(r, (i32)0, (i32)2, (i32)0, (i32)0, (i32)0, (i32)0, (i32)1, (u8*)"gauge");
    // OUTLET owner.helper = top Helper(id 1)          [top-level object as a value — #9]
    rsc_nib_add_conn_at(r, (i32)0, (i32)2, (i32)0, (i32)0, (i32)1, (i32)1, (i32)0, (u8*)"helper");
    // ACTION OK button(0,2)  -> owner.onClick
    rsc_nib_add_conn_at(r, (i32)1, (i32)0, (i32)0, (i32)2, (i32)2, (i32)0, (i32)0, (u8*)"onClick");
    // ACTION Go button(0,3)  -> Gauge VIEW(0,1).onGauge  [designable view as target — #9]
    rsc_nib_add_conn_at(r, (i32)1, (i32)0, (i32)0, (i32)3, (i32)0, (i32)0, (i32)1, (u8*)"onGauge");
    pointer bytes = (pointer)0;
    i32 len = (i32)0;
    rsc_write(r, (pointer)&bytes, (pointer)&len, (pointer)0);
    rsc_free(r);
    lenOut[0] = len;
    return bytes;
    }

class Ctl : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        UXNib.registerObjectFactory((pointer)&nibFactory);
        i32 len = (i32)0;
        pointer bytes = buildRsc(&len);
        Stdio.printf("built .rsc: %d bytes\n", len);
        Controller* ctl = new Controller();
        UXViewTree* vt = UXNib.loadWiredMem((u8*)bytes, len, (i32)0, (UXDesignable*)ctl);
        Stdio.printf("loaded vt=%s\n", vt != (UXViewTree*)0 ? "ok" : "NULL");
        Object* v1 = vt != (UXViewTree*)0 ? vt.viewAt((u16)1) : (Object*)0;
        i32 outGauge = (ctl.gauge != (UXView*)0 && (Object*)ctl.gauge == v1) ? (i32)1 : (i32)0;
        i32 outHelper = (ctl.helper != (Helper*)0) ? (i32)1 : (i32)0; // top-level bound as a value
        UXButton* ok = vt != (UXViewTree*)0 ? (UXButton * ?) vt.viewAt((u16)2) : (UXButton*)0;
        UXButton* go = vt != (UXViewTree*)0 ? (UXButton * ?) vt.viewAt((u16)3) : (UXButton*)0;
        // -> owner.onClick
        if (ok != (UXButton*)0)
            {
            ok.fire();
            }
        // -> Gauge(view).onGauge
        if (go != (UXButton*)0)
            {
            go.fire();
            }
        Stdio.printf("outlet-view=%d outlet-toplevel=%d owner-action=%d view-action=%d (expect 1 1 1 1)\n",
                     outGauge, outHelper, gClicked, gGaugeClicked);
        bool pass = vt != (UXViewTree*)0 && outGauge == (i32)1 && outHelper == (i32)1 && gClicked == (i32)1 && gGaugeClicked == (i32)1;
        Stdio.printf(pass ? "PASS: post-#9 nib — view+toplevel outlets bound, owner+view actions fired\n" : "FAIL\n");
        a.stop();
        return (i32)0;
        }
    } void main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Ctl());
    app.run();
    }
