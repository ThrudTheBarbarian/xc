// olmain.xc — links olstr.o (-c, #654). The program makes no Stdio call and
// no String method call of its own beyond those below: a String the object
// built is dispatched on here through Object*, and the object checks the hash
// the program read against its own and prints the String.
String* greeting(void);
void report(String* s, u32 progHash, i32 progEquals);

// Its own override of hash and description gives each a slot of its own.
class Tag : Object
    {
    u32 hash(void) { return 7; }
    String* description(void) { return String.withCString("tag"); }
    }

Object* pick(i32 k, Object* a, Object* b)
    {
    if (k == 1)
        return a;
    return b;
    }

i32 main(i32 argc, u8** argv)
    {
    String* g = greeting();
    Object* o = pick(argc, (Object*)g, (Object*)new Tag());
    String* h = String.withCString("hello, object");
    report(g, o.hash(), o.equals((Object*)h) ? 1 : 0);
    return 0;
    }
