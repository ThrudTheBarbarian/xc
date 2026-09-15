// designable_reflection.xc — uxkit/026, XG-NIB §4.
//
// A class that declares an `outlet` field or an `:action` method auto-conforms
// to the binding protocol, and the compiler fills setOutlet / wireAction in
// from the decorations. This pins that end to end: a nib loader holds only an
// object and a NAME, so every call below goes through the protocol, never
// through Panel.
//
// The protocol, the control and the nib class are declared HERE rather than
// imported, because the compiler discovers those names from what is in scope
// (the framework was XG and is now UXKit, and a compiler that knows only one
// spelling silently stops synthesising the moment the other is imported).
// Declaring them locally is also what keeps this fixture free of the framework.
//
// The negative halves matter as much as the positive ones: an unknown name must
// bind NOTHING and say so, because a stale wire in a nib is the common case
// after a rename, and a silent success there is a null deref much later.
//
//   T1  an outlet binds by name, through the protocol
//   T2  ...to the object that was passed, not to something else
//   T3  an unknown outlet name binds nothing and returns false
//   T4  an action wires by name
//   T5  ...and firing the control reaches the method
//   T6  an unknown action name wires nothing and returns false
//   T7  ...and does not disturb the wire that was already good
//
// The per-module factory's LOAD-TIME self-registration is pinned separately, in
// designable_register.xc: it needs a target that has load-time constructors at
// all, and xt6502 has none — XT6502Backend does not emit moduleInitFunctionNames
// in any form. Asserting it here failed on a target that cannot do it, which
// says nothing about the compiler.
#import "Stdio.xc"
#import "Assert.xc"

typedef void UXAct(Object* sender);

class UXControl : Object
{
    UXAct^ action;
    void init(void) { }
    void setAction(UXAct^ a) { action = a; }
    void fire(Object* s) { if (action) { action(s); } }
}

// The loader side of piece 3: the synthesised `_xtc_nib_register` constructor
// hands the module's factory over at load, with no per-app code.
u16 registered;

class UXNib : Object
{
    static void registerObjectFactory(pointer fn) { registered = registered + (u16)1; }
}

protocol UXDesignable {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, UXControl* control);
}

class Label : Object
{
    u16 tag;
    void init(void) { tag = (u16)0; }
}

u16 fired;

class Panel : Object
{
    outlet Label* title;         // designable members: no conformance written here,
    void init(void) { }          // no setOutlet/wireAction body, no factory entry
    void onOK(Object* sender) :action { fired = fired + (u16)1; }
}

void main(void)
{
    Assert.reset();
    fired = (u16)0;

    Panel* p = new Panel();
    Label* l = new Label();
    l.tag = (u16)7;

    // Everything a nib loader does goes through the protocol and a name.
    UXDesignable* d = (UXDesignable*)p;

    Assert.isTrue(d.setOutlet((u8*)"title", (Object*)l));       // T1
    Assert.isEqual(p.title.tag, (u16)7);                        // T2
    Assert.isFalse(d.setOutlet((u8*)"nope", (Object*)l));       // T3

    UXControl* c = new UXControl();
    Assert.isTrue(d.wireAction((u8*)"onOK", c));                // T4
    c.fire((Object*)p);
    Assert.isEqual(fired, (u16)1);                              // T5
    Assert.isFalse(d.wireAction((u8*)"nope", c));               // T6
    c.fire((Object*)p);
    Assert.isEqual(fired, (u16)2);                              // T7

    Assert.summary();
}
