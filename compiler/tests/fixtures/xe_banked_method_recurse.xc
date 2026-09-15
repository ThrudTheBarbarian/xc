// xe_banked_method_recurse.xc — Phase 1c: recursive `:banked`
// method. Each level pushes its own frame + cloaked-bracket
// PORTB-save through the wrapper, and (self),Y access between
// recursive calls must not leak state. fact(5) = 120 verifies
// the call/return path handles nested banked frames.
#import "Stdio.xc"
#import "Assert.xc"

class Box
{
    u16 v;

    u16 fact(u16 n) :banked
    {
        if (n <= 1) return 1;
        v = v + 1;
        return n * fact(n - 1);
    }

    u16 calls(void) :banked  { return v; }
}

void main(void)
{
    Assert.reset();
    Box* b = new Box();
    Assert.isEqual(b.fact(5), 120);
    Assert.isEqual(b.calls(), 4);
    Assert.summary();
    return;
}
