// test_designable.xc — bug 026 ACTIVATED against the real framework: the
// `outlet` / `:action` decorations, compiler-synthesised UXDesignable bodies,
// the per-module factory, and its load-time registration — with the UXKit
// spellings, which is exactly what 026 fixed (the synthesis used to know only
// the XG names and silently produced nothing here).
//
// NOTHING designable in this file is hand-written: no conformance, no
// setOutlet/wireAction bodies, no factory, no registerObjectFactory call.
// If any synthesis half fails to fire, an assertion says so — the "90% built
// and 0% reachable" failure mode this gate exists to keep dead.
//
//   Build+run:  sh run_designable.sh   (host arm64; the suite covers the rest)
#import <Stdio.xc>
#import "UXNib.xc"
#import "UXControl.xc"
#import "UXDesignable.xc"

i32 gFails;
void check(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

i32 gFired;

class Badge : Object
    {
    i32 tag;
    void init(void)
        {
        tag = (i32)0;
        }
    }

    // The designable: decorations only — every body below main is the compiler's.
    class Panel : Object
    {
    outlet Badge* badge;
    void init(void)
        {
        }
    void onOK(Object* sender) : action
        {
        gFired = gFired + (i32)1;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    gFired = (i32)0;

    // T1 — the module's synthesised constructor registered its factory at
    // load (self-hosted arm64 modinit, the other half of what 026's work
    // fixed).  Nothing in this program calls registerObjectFactory.
    check((u8*)"the module factory registered at load", gUXNibNFn == (i32)1);

    // T2/T3 — a Panel made BY NAME through the erased factory.
    Object* o = UXNib.make((u8*)"Panel");
    check((u8*)"make(\"Panel\") answers", o != (Object*)0);
    UXDesignable* d = (UXDesignable* ?)o;
    check((u8*)"...and it conforms (auto-apply)", d != (UXDesignable*)0);
    check((u8*)"an unknown class makes nothing", UXNib.make((u8*)"NoSuch") == (Object*)0);

    // T4-T6 — outlets bind by name through the synthesised body.
    Panel* p = (Panel* ?)o;
    Badge* b = new Badge();
    b.tag = (i32)7;
    check((u8*)"setOutlet binds by name", d.setOutlet((u8*)"badge", (Object*)b));
    check((u8*)"...to the object passed", p != (Panel*)0 && p.badge != (Badge*)0 && p.badge.tag == (i32)7);
    check((u8*)"an unknown outlet binds nothing", !d.setOutlet((u8*)"nope", (Object*)b));

    // T7-T9 — actions wire by name and fire through the REAL UXControl.
    UXControl* c = new UXControl();
    check((u8*)"wireAction wires by name", d.wireAction((u8*)"onOK", c));
    c.fire();
    check((u8*)"...and the fire reaches the method", gFired == (i32)1);
    check((u8*)"an unknown action wires nothing", !d.wireAction((u8*)"nope", c));
    c.fire();
    check((u8*)"...and leaves the good wire alone", gFired == (i32)2);

    Stdio.printf(gFails == (i32)0
                     ? "PASS: the compiler's designable synthesis is live under the UXKit names\n"
                     : "FAIL: %d checks\n",
                 gFails);
    }
