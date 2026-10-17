// spicedep.xc — spice.xc's plugin, using an xc library (Spicelib) for its
// arithmetic; tests/bundle/plugin.sh ships the library with --bundle-lib.
#import <Spicelib>
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
        Fence.note(Helper.twice(r + x));
        return Helper.twice(r + x);
        }
    }
