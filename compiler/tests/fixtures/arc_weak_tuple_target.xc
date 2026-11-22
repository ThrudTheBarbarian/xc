// arc_weak_tuple_target.xc — a weak local as a tuple target is linked to its
// referent like a plain assignment's: `(w, k) = make()` left the slot off the
// referent's weak chain, so when the referent died the reference compiler's
// `w` still read the dead object, and the port's program crashed (SIGBUS)
// before printing (at -O0 its tuple binding also released the slot's
// never-zeroed payload as if the slot owned it). The slot must hold the object
// while it lives, and read null once the last strong reference goes. A weak
// target DECLARED in the tuple is #507.
#import "Stdio.xc"

u16 gLive;

class Item
{
    u32 v;
    void init(void)    { v = (u32)7; gLive = gLive + (u16)1; }
    void dealloc(void) { gLive = gLive - (u16)1; }
}

Item* gKeep;

Item*, u32 make(void)
{
    Item* it = new Item();
    gKeep = it;
    return it, (u32)5;
}

void main(void)
{
    gLive = (u16)0;
    weak:Item* w;
    u32 k = (u32)0;
    (w, k) = make();
    Stdio.printf("T1 live=%u w=%s k=%u\n", (u32)gLive, w == 0 ? "null" : "set", k);
    gKeep = (Item*)0;
    Stdio.printf("T1 after: live=%u w=%s\n", (u32)gLive, w == 0 ? "null" : "set");
    return;
}
