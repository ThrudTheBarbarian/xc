// designable_outlet_protocol.xc — an outlet typed by a protocol: the generated
// setOutlet assigns through a checked cast, `(P* ?)value`, so an object whose
// class does not conform is refused (setOutlet returns false and the outlet
// stays null), and one that conforms is bound.
#import "Stdio.xc"

typedef void UXAct(Object* sender);

class UXControl : Object
{
    UXAct^ action;
    void init(void) { }
    void setAction(UXAct^ a) { action = a; }
}

class UXRsc : Object
{
    static void registerObjectFactory(pointer fn) { }
}

protocol UXDesignable {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, UXControl* control);
}

protocol RowSource
{
    i32 rows(void);
}

class Rows : Object<RowSource>
{
    i32 rows(void) { return 4; }
}

class Table : Object
{
    weak : outlet RowSource* source;
    void init(void) { }
}

void main(void)
{
    Table* t = new Table();
    Rows* r = new Rows();
    Object* other = new Object();
    bool bad = t.setOutlet((u8*)"source", other);
    Stdio.printf("non-conforming: %s, outlet %s\n", bad ? "bound" : "refused", t.source == (RowSource*)0 ? "null" : "set");
    bool ok = t.setOutlet((u8*)"source", r);
    Stdio.printf("conforming: %s, rows %d\n", ok ? "bound" : "refused", t.source.rows());
}
