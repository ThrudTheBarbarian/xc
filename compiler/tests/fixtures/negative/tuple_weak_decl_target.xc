// A tuple target cannot be declared weak: a weak slot is linked to its
// referent where it lives, and a target declared in the tuple has nowhere to
// do that (#507). Declare it before the assignment, which links it (#505).
// xtc: error "a tuple target cannot be declared weak ('w'); declare it before the assignment"
class Item { u32 v; void init(void) { v = (u32)7; } }
Item@, u32 make(void) { Item@ it = new Item(); return it, (u32)5; }
i32 main(void)
    {
    (weak:Item@ w, u32 k) = make();
    }
