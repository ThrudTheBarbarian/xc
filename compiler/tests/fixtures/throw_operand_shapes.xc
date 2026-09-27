// throw_operand_shapes.xc — `throw` of a call result, a conditional, a
// variable and a method result, on a class whose only init takes arguments.
//
// A static call runs the class's `init` once on its static block first, and
// that call passes `self` alone. For an init that takes arguments the call was
// short: garbage arguments on the native targets, and on wasm32 a module that
// failed to instantiate ("not enough arguments on the stack"), so
// `throw E.with("x")` broke while `throw new E(...)` worked. Only an
// `init(void)` runs there now.

#import "Stdio.xc"
#import "String.xc"
#import "Error.xc"

class E <Error>
{
    String* msg;
    void init(String* m)  { msg = m; }
    String* message(void) { return msg; }
    static E* with(char* s) { return new E(String.withCString(s)); }
    E* again(char* s) { return new E(String.withCString(s)); }
}

i32 fromCall(void) throws
{
    throw E.with("call");
    return (i32)0;
}

i32 fromConditional(bool first) throws
{
    throw first ? E.with("cond-a") : new E(String.withCString("cond-b"));
    return (i32)0;
}

i32 fromVariable(void) throws
{
    E* e = E.with("variable");
    throw e;
    return (i32)0;
}

i32 fromMethod(E* base) throws
{
    throw base.again("method");
    return (i32)0;
}

i32 fromNew(void) throws
{
    throw new E(String.withCString("new"));
    return (i32)0;
}

void report(Object* e)
{
    Stdio.printf("caught %s\n", ((E*)e).message().cString());
}

void main(void)
{
    try { fromCall(); } catch (e) { report(e); }
    try { fromConditional(true); } catch (e) { report(e); }
    try { fromConditional(false); } catch (e) { report(e); }
    try { fromVariable(); } catch (e) { report(e); }
    try { fromMethod(E.with("base")); } catch (e) { report(e); }
    try { fromNew(); } catch (e) { report(e); }
    Stdio.printf("done\n");
}
