// Spicelib.xc — an xc library (--emit-lib) that spicedep.xc's plugin uses:
// not a system library, so it must ship in the bundle (--bundle-lib).
class Helper : Object
    {
    static i32 twice(i32 x) { return x * (i32)2; }
    }
