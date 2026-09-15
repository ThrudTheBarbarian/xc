// bound_method_eq_zero.xc — comparing a `^` compares BOTH of its words.
//
// Bug 031. A `^` is a pair {recv, code}, and `==` is a value comparison of the
// pair — that is what makes `&f == &f` mean "the same action" in
// bound_method_widen.xc (T4). The back ends disagreed about it: arm64 compared
// one word, xt6502 compared two, so the same expression gave different answers
// on different targets. The comparison is now expanded in IR lowering, so there
// is one answer everywhere.
//
// ── `==` and `if (h)` ask DIFFERENT questions, deliberately ─────────────
//
//   if (h)      — is this action still callable? Reads the RECEIVER word, which
//                 auto-zeroing clears when the receiver dies.
//   h == other  — do these two `^`s name the same thing? Compares both words.
//
// So after a receiver dies, `!h` is TRUE (not callable) while `h == 0` is FALSE
// (the code word still holds a real method address, so the pair is not the null
// pair). Both are correct answers to their own question. **Use `if (h)` for
// liveness** — that is the guard the auto-zero machinery exists to make work.
//
//   T1  a live `^` is truthy and is not the null pair
//   T2  after the receiver dies: falsy, and still not the null pair — and every
//       backend agrees, which is the actual bug fix
//   T3  a `^` that was never assigned IS the null pair, and is falsy
//   T4  identity: two `^`s naming one method are equal; different ones are not

#import "Stdio.xc"
#import "Assert.xc"

typedef u16 act_t(void);

class Target
{
    u16  v;
    void init(void) { v = (u16)5; }
    u16  go(void)   { return v; }
    u16  stop(void) { return (u16)0; }
}

class Holder
{
    act_t^ f;
    void   init(void) { }
}

void main(void)
{
    Holder* h = new Holder();

    // T3: never assigned — both words zero.
    Assert.isFalse(h.f ? true : false);          // T3a
    Assert.isTrue(h.f == 0);                     // T3b

    {
        Target* t = new Target();
        h.f = &t.go;
        Assert.isTrue(h.f ? true : false);       // T1a — callable
        Assert.isFalse(h.f == 0);                // T1b — not the null pair

        // T4: identity, while everything is alive.
        act_t^ p = &t.go;
        act_t^ q = &t.go;
        act_t^ r = &t.stop;
        Assert.isTrue(p == q);                   // T4a — same receiver, same method
        Assert.isFalse(p == r);                  // T4b — same receiver, different method
        Assert.isTrue(p != r);                   // T4c
    }                                            // the receiver dies here

    // T2: falsy, because the receiver word was zeroed — but NOT the null pair,
    // because the code word is untouched. Every backend must say exactly this.
    Assert.isFalse(h.f ? true : false);          // T2a
    Assert.isFalse(h.f == 0);                    // T2b
    Assert.isTrue(h.f != 0);                     // T2c

    Assert.summary();
}
