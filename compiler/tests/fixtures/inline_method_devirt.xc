// inline:method() + transitive self-dispatch devirtualisation.
//
// Stage 4 of the inline:-on-methods feature. When a base-class
// method is inlined onto a subclass receiver, inner self-calls
// inside the inlined body must resolve against the subclass —
// not against the base class the body was authored in. Without
// this the graphics-library use case (a `Gfx` master class with
// `Gfx.line()` calling `inline:self.plot()`, overridden in
// `Gfx8`) falls back to virtual dispatch on the inner plot,
// defeating the inline.
//
// The devirt is driven by inlineSelfClassStack: emitInlineMethodCall
// pushes the receiver's class before emitting the body, and
// emitMethodCallExpr consults the stack when the receiver is `self`,
// preferring the stack's class over the AST's static type.
//
// Test design:
//   - Gfx.plot adds 1000 to sum (the wrong answer).
//   - Gfx8.plot adds the actual value to sum (the right answer).
//   - Gfx.runPlot calls inline:plot(v).
//   - main() calls inline:g.runPlot(v) where g is Gfx8.
// If devirt works, sum tracks the value, not 1000-per-call.

#import "Stdio.xc"
#import "Assert.xc"

class Gfx
{
    u16 sum;

    void init(void)
    {
        sum = 0;
        return;
    }

    void plot(u16 v)
    {
        sum = sum + 1000;
        return;
    }

    void runPlot(u16 v)
    {
        inline:plot(v);
        return;
    }
}

class Gfx8 : Gfx
{
    void plot(u16 v)
    {
        sum = sum + v;
        return;
    }
}

void main(void)
{
    Assert.reset();

    Gfx8* g = new Gfx8();

    inline:g.runPlot(5);
    Assert.isEqual(g.sum, 5);

    inline:g.runPlot(7);
    Assert.isEqual(g.sum, 12);

    inline:g.runPlot(100);
    Assert.isEqual(g.sum, 112);

    Assert.summary();
    return;
}
