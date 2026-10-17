// protocol_static_plugin.xc — the same protocol in a PLUGIN: no class provides
// the members, so each call goes through the table Fence.bind() was given (here
// built by hand from another class's static methods, as a host's table() is).
//xtc-na: wasm32 — on the web a plugin is a module of its own and Fence.bind() names a loaded plugin, not a table (tests/bundle/web/run.sh)
#import "Stdio.xc"
protocol Fence :version(2.1)
    {
    static i32 emit(u8* p, u32 n);
    static void note(i32 v);
    }
class Impl
    {
    static i32 emit(u8* p, u32 n) { Stdio.printf("table emit %s %u\n", p, n); return (i32)n + (i32)100; }
    static void note(i32 v) { Stdio.printf("table note %d\n", v); }
    }
i32 main(void)
{
    pointer* t = new pointer[2];
    t[0] = (pointer)&Impl.emit;
    t[1] = (pointer)&Impl.note;
    Fence.bind((pointer)t);
    i32 r = Fence.emit("xyz", (u32)7);
    Fence.note(r);
    Stdio.printf("version %u.%u\n", Fence.versionMajor(), Fence.versionMinor());
    return 0;
}
