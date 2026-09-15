// xe_banked_method_mixed.xc — Phase 1c stress test: mix every
// pattern in one fixture. If this passes, the realistic shapes
// of `:banked` heap-class library code (Gfx, Stdio-style) work.
//
// In one fixture: inheritance with virtual override, struct
// field read+write, ARC scope-exit + dealloc counted, banked-
// pointer ivar storing a banked instance, cross-instance method
// dispatch, recursion through the cloaked-bracket, allocation
// and method calls inside the recursion. All methods `:banked`.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

struct Point { u16 x; u16 y; }

class Node
{
    u16 tag;
    Point at;
    void dealloc(void) :banked  { deallocCount = deallocCount + 1; }
}

class Tile : Node
{
    u16 colour;

    void place(u16 x, u16 y, u16 c) :banked
    {
        at.x = x;
        at.y = y;
        colour = c;
    }

    u16 manhattanFromOrigin(void) :banked
    {
        return at.x + at.y;
    }
}

class Stage
{
    u16 placed;
    banked:Tile* first;

    void mount(banked:Tile* t) :banked
    {
        first = t;
        placed = placed + 1;
    }

    u16 firstColour(void) :banked
    {
        return first.colour;
    }

    u16 tally(u16 n) :banked
    {
        if (n == 0) return 0;
        Tile* tmp = new Tile();
        tmp.place(n, n + 1, n);
        u16 sub = tally(n - 1);
        return tmp.manhattanFromOrigin() + sub;
    }
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    Tile* t = new Tile();
    t.place(10, 20, 5);
    Assert.isEqual(t.manhattanFromOrigin(), 30);

    Stage* s = new Stage();
    s.mount(t);
    Assert.isEqual(s.firstColour(), 5);

    u16 sum = s.tally(3);
    Assert.isEqual(sum, 15);              // 7+5+3 = 15

    Assert.summary();
    return;
}
