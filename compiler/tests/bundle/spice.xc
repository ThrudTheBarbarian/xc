// spice.xc — the plugin tests/bundle/plugin.sh loads: it requires Fence,
// and calls the host through it.
protocol Fence :version(2.1)
    {
    static i32 emit(u8* p, u32 n);
    static void note(i32 v);
    }
class SpiceTool
    {
    static i32 run(i32 x)
        {
        i32 r = Fence.emit("spice", (u32)5);
        Fence.note(r + x);
        return r + x;
        }
    }
