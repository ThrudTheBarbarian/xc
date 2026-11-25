// f8lib.xc — a library with the 8-bit floats in its interface: functions
// taking and returning f8, f8:pack(e5m2) and f8:pack(ue8m0), a custom pack
// with its kind, a struct with pack fields, and a class holding one. See
// f8-lib.sh.
#import "Stdio.xc"

struct QPoint
{
    f8 x;
    f8:pack(e5m2) y;
    f8:pack(ue8m0) s;
};

f8 quarter(f32 v)
{
    return (f8)(v / 4);
}

f8:pack(e5m2) wide(f8 w)
{
    return (f8:pack(e5m2))w * 64;
}

f8:pack(e2m5, none) clamp(f32 v)
{
    return (f8:pack(e2m5, none))v;
}

QPoint qpoint(f8 x, f8:pack(e5m2) y, f8:pack(ue8m0) s)
{
    QPoint p;
    p.x = x;
    p.y = y;
    p.s = s;
    return p;
}

class QScale : Object
    {
    f8 factor;
    void init(f8 k) { factor = k; }
    f8 apply(f8 v) { return v * factor; }
    }
