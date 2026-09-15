// struct-local — value-typed struct LOCAL accessed purely by member
// read/write (no `&`).
//
// `Point p;` is value-typed, so it needs a real frame slot: an
// aggregate can't live in an SSA scalar. The pre-scan pins it even
// though its address is never taken, so `p.x = …` / `p.y = …` lower
// to FieldAddr + Store against the pinned slot and `p.x + p.y` reads
// them back. 40 + 2 = 42.
struct Point
    {
    u16 x;
    u16 y;
    }

    u16
    sp(void)
    {
    Point p;
    p.x = (u16)40;
    p.y = (u16)2;
    return p.x + p.y; // 42
    }
