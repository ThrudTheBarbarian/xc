// inline:method() — basic shapes.
//
// Stage 2 of the inline:-on-methods feature: the parser already
// accepted `inline:` on free function calls (XTCallExprNode); now
// it forwards forceInline onto XTMethodCallExprNode too, and
// emitInlineMethodCall: pastes the resolved method body with self
// bound to the receiver expression's evaluated address.
//
// Covers:
//   T1: inline:obj.method() with no args.
//   T2: inline:obj.method(arg) — argument marshalling.
//   T3: nested inline expansion — `inline:c.doubleBump()` pastes
//       doubleBump's body, which itself contains `inline:bump()`
//       (implicit-self bare call). Exercises the recursion through
//       emitInlineMethodCall: and the transitive self-resolution
//       across nested expansions.

#import "Stdio.xc"
#import "Assert.xc"

class Counter
{
    u16 value;

    void init(void)
    {
        value = 0;
        return;
    }

    void bump(void)
    {
        value = value + 1;
        return;
    }

    void bumpBy(u16 n)
    {
        value = value + n;
        return;
    }

    void doubleBump(void)
    {
        inline:bump();
        inline:bump();
        return;
    }
}

void main(void)
{
    Assert.reset();

    Counter* c = new Counter();
    inline:c.bump();
    Assert.isEqual(c.value, 1);

    inline:c.bumpBy(10);
    Assert.isEqual(c.value, 11);

    inline:c.doubleBump();
    Assert.isEqual(c.value, 13);

    Assert.summary();
    return;
}
