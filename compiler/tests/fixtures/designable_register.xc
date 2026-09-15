//xtc-na: xt6502,m68k,arm9,wasm32 — no load-time constructors there yet.
//        x86_64 and win64 are IN SCOPE: their crts walk the __xt_ctors table
//        since bug 134 (before it, this fixture carried a legacy
//        `target=arm64` and the corpus never asked).
// designable_register.xc — uxkit/026 piece 3: the per-module factory registers
// ITSELF at load, with no line of per-app code.
//
// Split out of designable_reflection.xc because this is the one assertion that
// is not portable: it needs the target to HAVE load-time constructors. xt6502
// has none — XT6502Backend never emits moduleInitFunctionNames in any form — so
// the registrar simply never runs there, and asserting it on that target
// reported a compiler failure where there was only a missing mechanism.
//
// It is also the regression guard for bug 066: the arm64 Mach-O writer emitted
// NO __mod_init_func section for a long time (the assembler folded it into
// __data), so dyld saw inert words and ran nothing. That failure is silent —
// nothing errors, the constructor just does not happen — which is exactly the
// kind a fixture has to catch, because no diagnostic ever will.
//
//   T1  the factory was registered exactly once, before main ran
//   T2  ...and it is a working factory, not just a pointer that arrived
#import "Stdio.xc"
#import "Assert.xc"

typedef void UXAct(Object* sender);

class UXControl : Object
{
    UXAct^ action;
    void init(void) { }
    void setAction(UXAct^ a) { action = a; }
}

protocol UXDesignable {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, UXControl* control);
}

// The shape the compiler generates for `_xtc_nibNew`.
typedef UXDesignable* UXFactory(u8* name);

u16 registered;

class UXNib : Object
{
    static UXFactory* f0;
    static void registerObjectFactory(pointer fn)
    {
        f0 = (UXFactory*)fn;
        registered = registered + (u16)1;
    }
    static UXDesignable* make(u8* name)
    {
        if (registered == (u16)0) { return (UXDesignable*)0; }
        return f0(name);
    }
}

class Label : Object { u16 tag; void init(void) { tag = (u16)0; } }

class Panel : Object
{
    outlet Label* title;
    void init(void) { }
}

void main(void)
{
    Assert.reset();

    // Nothing here called registerObjectFactory: the synthesised
    // `_xtc_nib_register` is a load-time constructor, so the loader already had
    // this module's factory before main started. Exactly ONCE — running twice is
    // its own bug, and is how the interim crt-side fix for 066 was caught.
    Assert.isEqual(registered, (u16)1);                          // T1

    UXDesignable* p = UXNib.make((u8*)"Panel");
    Assert.isTrue(p != (UXDesignable*)0);                        // T2

    Assert.summary();
}
