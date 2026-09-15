// struct-ivar — value-typed struct IVAR accessed bare inside a method
// (`at.x` == `self.at.x`).
//
// `Box` holds a `Point at;` ivar. Inside sum(), `at.x = …` / `at.y`
// resolve `at` to FieldAddr(self, ivarSlot) — the address of the
// struct ivar within the instance — then FieldAddr into x/y. 40+2 = 42.
struct Point
    {
    u16 x;
    u16 y;
    }

    class Box
    {
    Point at;

    u16 sum(void)
        {
        at.x = (u16)40;
        at.y = (u16)2;
        return at.x + at.y; // 42
        }
    }

    u16
    si(void)
    {
    Box* b = new Box();
    return b.sum();
    }
