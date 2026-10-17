// protocol_static_host.xc — a protocol with static members (bundles-and-plugins.md
// §3) in the HOST: a class conforms and defines them, so Fence.emit(...) is a
// call to it, Fence.table() lists their addresses for a plugin, and
// :version(2.1) is Fence.versionMajor() / versionMinor().
#import "Stdio.xc"
protocol Fence :version(2.1)
    {
    static i32 emit(u8* p, u32 n);
    static void note(i32 v);
    }
class Host : Object <Fence>
    {
    static i32 emit(u8* p, u32 n) { Stdio.printf("host emit %s %u\n", p, n); return (i32)n * (i32)2; }
    static void note(i32 v) { Stdio.printf("host note %d\n", v); }
    }
i32 main(void)
{
    i32 r = Fence.emit("abc", (u32)3);
    Fence.note(r);
    Stdio.printf("version %u.%u\n", Fence.versionMajor(), Fence.versionMinor());
    pointer t = Fence.table();
    Stdio.printf("table %s\n", t != (pointer)0 ? "made" : "none");
    return 0;
}
