// addrof-member — pins the &obj.field lowering shape. The local
// struct `pt` is pinned by the pre-scan (it's the underlying name
// of `&pt.y` / `&pt.x`); the addresses are computed as
// AddrOf %pt + FieldAddr index. Subtracting them yields the field
// offset (2 bytes for u16 x → u16 y, layout starts at 0).
struct Point
    {
    u16 x;
    u16 y;
    }

    u16
    offset(void)
    {
    Point pt;
    pt.x = 11;
    pt.y = 22;
    u16* px = &pt.x;
    u16* py = &pt.y;
    return (u16)py - (u16)px;
    }
