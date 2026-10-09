// designable_menu_action.xc — UXKit request (Rocks menu editor #9).
//
// A menu item is a model, not a UXControl, so a `:action` method whose sender
// is a UXMenuItem* cannot be bound by wireAction. The synthesis emits a second
// binding, wireMenuAction(name, item), for exactly those methods; a control
// action is not bound by it, and a menu action is not bound by wireAction.
//
// T1 a menu action wires by name through wireMenuAction
// T2 firing the item reaches the method
// T3 a control action is not bound by wireMenuAction
// T4 an unknown name binds nothing
// T5 a menu action is not bound by wireAction (its sender is not a control)
#import "Stdio.xc"
#import "Assert.xc"

u16 fired;

class UXMenuItem : Object
{
    callback void(UXMenuItem* sender) act;
    void init(void) { }
    void setAction(callback void(UXMenuItem* sender) a) { act = a; }
    void fire(UXMenuItem* s) { if (act) { act(s); } }
}

typedef void UXAct(Object* sender);

class UXControl : Object
{
    UXAct^ action;
    void init(void) { }
    void setAction(UXAct^ a) { action = a; }
    void fire(Object* s) { if (action) { action(s); } }
}

protocol UXDesignable {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, UXControl* control);
    bool wireMenuAction(u8* name, UXMenuItem* item);
}

class Panel : Object
{
    void onOK(Object* sender) :action { fired = fired + (u16)1; }
    void onQuit(UXMenuItem* sender) :action { fired = fired + (u16)10; }
}

void main(void)
{
    Assert.reset();
    fired = (u16)0;

    Panel* p = new Panel();
    UXDesignable* d = (UXDesignable*)p;

    UXMenuItem* item = new UXMenuItem();
    Assert.isTrue(d.wireMenuAction((u8*)"onQuit", item));       // T1
    item.fire(item);
    Assert.isEqual(fired, (u16)10);                             // T2
    Assert.isFalse(d.wireMenuAction((u8*)"onOK", item));        // T3
    Assert.isFalse(d.wireMenuAction((u8*)"nope", item));        // T4

    UXControl* c = new UXControl();
    Assert.isFalse(d.wireAction((u8*)"onQuit", c));             // T5
    Assert.isTrue(d.wireAction((u8*)"onOK", c));                // (control action still wires)
    c.fire((Object*)p);
    Assert.isEqual(fired, (u16)11);

    Assert.summary();
}
