// spiceweb.xc — a plugin that provides Spice and requires Fence: the host
// calls it through Spice, and it calls the host back through Fence. sum()
// takes a buffer, and writes its first byte, which the caller sees after.
protocol Fence :version(2.1)
    {
    static i32 emit(u8* p, u32 n);
    static void note(i32 v);
    }
protocol Spice :version(1.0)
    {
    static i32 run(i32 x);
    static u32 sum(u8* p, u32 n);
    }
class SpiceTool : Object <Spice>
    {
    static i32 run(i32 x)
        {
        i32 r = Fence.emit("spice", (u32)5);
        Fence.note(r + x);
        return r + x;
        }
    static u32 sum(u8* p, u32 n)
        {
        u32 t = (u32)0;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            t = t + (u32)p[i];
        if (n > (u32)0)
            p[0] = (u8)99;
        return t;
        }
    }
