// foundation_functional.xc — filter / map / search over an Array, and Numbers
// as text.
//
// A container you can only walk by index is a chore. These are the methods that
// make one pleasant, and every one of them takes a `^` — so the predicate can
// be a plain function OR a bound method that carries its receiver:
//
//     class Filter { i16 threshold;  bool above(Object@ o) { … } }
//     Array@ hits = rows.filtered(&filter.above);
//
// The filter's state lives on the filter, not in a global, and the same Array
// can be filtered two different ways at once. That is exactly the shape of a
// TableView over a filtered datasource, which is what prompted this.
//
//   T1  filtered — with a STATEFUL predicate, reconfigured between runs
//   T2  mapped — including the null-skipping that makes it a filtering transform
//   T3  firstWhere / indexWhere / countWhere / anySatisfy / allSatisfy
//   T4  reversed / reverse / swapAt
//   T5  addAll / withArray / subarray
//   T6  none of it mutates the receiver (except reverse/swapAt, which say so)
//   T7  Number.description() — an Int renders exactly, a Float to 6 places
//       (String.withFloat's default, matching C printf %f and Stdio.printf)
//   T8  String.withI32 / withU32, including negative and multi-digit
//   T9  a null `^` is handled rather than jumped through

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

// A predicate with state — the reason these take a `^` and not a function ptr.
class Threshold
{
    i16 limit;
    void init(void) { limit = (i16)0; }
    bool above(Object* o)
    {
        Number* n = (Number* ?)o;
        return n != 0 && n.asI16() > limit;
    }
}

Object* doubler(Object* o)
{
    Number* n = (Number* ?)o;
    if (n == 0) return (Object*)0;
    return Number.with((i16)(n.asI16() * (i16)2));
}

// Maps evens to themselves and odds to null — mapped() skips the nulls, so this
// transforms and filters in one pass.
Object* evensOnly(Object* o)
{
    Number* n = (Number* ?)o;
    if (n == 0) return (Object*)0;
    if (n.asI16() % (i16)2 != (i16)0) return (Object*)0;
    return o;
}

bool always(Object* o) { return true; }

u16 nth(Array* a, u16 i)
{
    Number* n = (Number* ?)a.get(i);
    if (n == 0) return (u16)$FFFF;
    return (u16)n.asI16();
}

Array* oneToSix(void)
{
    Array* a = new Array();
    for (i16 i = (i16)1; i <= (i16)6; i = i + (i16)1) a.add(Number.with(i));
    return a;
}

void t1_t2(void)
{
    Array* a = oneToSix();                       // 1 2 3 4 5 6
    Threshold* t = new Threshold();

    // ── T1: a stateful predicate, and the SAME `^` reconfigured.
    t.limit = (i16)3;
    Array* big = a.filtered(&t.above);
    Assert.isEqual(big.count(), (u16)3);                 // T1a — 4 5 6
    Assert.isEqual(nth(big, (u16)0), (u16)4);
    Assert.isEqual(nth(big, (u16)2), (u16)6);

    t.limit = (i16)5;                                    // reconfigure the receiver
    Array* bigger = a.filtered(&t.above);
    Assert.isEqual(bigger.count(), (u16)1);              // T1b — just 6
    Assert.isEqual(nth(bigger, (u16)0), (u16)6);

    t.limit = (i16)99;
    Assert.isEqual(a.filtered(&t.above).count(), (u16)0); // T1c — none

    // ── T2: mapped.
    Array* dbl = a.mapped(&doubler);
    Assert.isEqual(dbl.count(), (u16)6);                 // T2a
    Assert.isEqual(nth(dbl, (u16)0), (u16)2);
    Assert.isEqual(nth(dbl, (u16)5), (u16)12);

    // A transform that returns null drops the element.
    Array* evens = a.mapped(&evensOnly);
    Assert.isEqual(evens.count(), (u16)3);               // T2b — 2 4 6
    Assert.isEqual(nth(evens, (u16)0), (u16)2);
    Assert.isEqual(nth(evens, (u16)2), (u16)6);
}

void t3_t9(void)
{
    Array* a = oneToSix();
    Threshold* t = new Threshold();
    t.limit = (i16)3;

    // ── T3: searching.
    Number* first = (Number* ?)a.firstWhere(&t.above);
    Assert.isTrue(first != 0);
    Assert.isEqual(first.asI16(), (i16)4);               // T3a
    Assert.isEqual(a.indexWhere(&t.above), (u16)3);      // T3b — 4 is at index 3
    Assert.isEqual(a.countWhere(&t.above), (u16)3);      // T3c
    Assert.isTrue(a.anySatisfy(&t.above));               // T3d
    Assert.isFalse(a.allSatisfy(&t.above));              // T3e — 1 is not > 3
    Assert.isTrue(a.allSatisfy(&always));                // T3f

    t.limit = (i16)99;
    Assert.isTrue(a.firstWhere(&t.above) == 0);          // T3g — no hit
    Assert.isEqual(a.indexWhere(&t.above), Array.notFound());
    Assert.isFalse(a.anySatisfy(&t.above));

    // ── T9: a null `^` must be handled, not jumped through.
    pred_t^ nothing = (pred_t^)0;
    Assert.isEqual(a.filtered(nothing).count(), (u16)0); // T9a
    Assert.isTrue(a.firstWhere(nothing) == 0);           // T9b
    Assert.isFalse(a.anySatisfy(nothing));               // T9c
}

void t4_t5_t6(void)
{
    Array* a = oneToSix();

    // ── T4: reversed (copy) leaves the receiver alone…
    Array* r = a.reversed();
    Assert.isEqual(nth(r, (u16)0), (u16)6);              // T4a
    Assert.isEqual(nth(r, (u16)5), (u16)1);
    Assert.isEqual(nth(a, (u16)0), (u16)1);              // T6a — receiver intact

    // …reverse() does not.
    a.reverse();
    Assert.isEqual(nth(a, (u16)0), (u16)6);              // T4b
    Assert.isEqual(nth(a, (u16)5), (u16)1);
    a.reverse();                                          // back again
    Assert.isEqual(nth(a, (u16)0), (u16)1);

    a.swapAt((u16)0, (u16)5);
    Assert.isEqual(nth(a, (u16)0), (u16)6);              // T4c
    Assert.isEqual(nth(a, (u16)5), (u16)1);
    a.swapAt((u16)0, (u16)5);                            // restore
    a.swapAt((u16)2, (u16)2);                            // self-swap is a no-op
    Assert.isEqual(nth(a, (u16)2), (u16)3);              // T4d
    a.swapAt((u16)0, (u16)99);                           // out of range: ignored
    Assert.isEqual(nth(a, (u16)0), (u16)1);              // T4e

    // ── T5: bulk.
    Array* copy = Array.withArray(a);
    Assert.isEqual(copy.count(), (u16)6);                // T5a
    Assert.isEqual(nth(copy, (u16)3), (u16)4);

    copy.addAll(a);
    Assert.isEqual(copy.count(), (u16)12);               // T5b
    Assert.isEqual(a.count(), (u16)6);                   // T6b — source intact

    Array* mid = a.subarray((u16)1, (u16)3);
    Assert.isEqual(mid.count(), (u16)3);                 // T5c — 2 3 4
    Assert.isEqual(nth(mid, (u16)0), (u16)2);
    Assert.isEqual(nth(mid, (u16)2), (u16)4);

    Assert.isEqual(a.subarray((u16)99, (u16)3).count(), (u16)0);   // T5d — clamped
    Assert.isEqual(a.subarray((u16)4, (u16)99).count(), (u16)2);   // T5e — clamped
}

void t7_t8(void)
{
    // ── T7: Number as text.
    Assert.isTrue(Number.with((i32)0).description().equals(String.withCString("0")));         // T7a
    Assert.isTrue(Number.with((i32)-42).description().equals(String.withCString("-42")));     // T7b
    Assert.isTrue(Number.with((i32)1234567).description().equals(String.withCString("1234567")));
    Assert.isTrue(Number.withFloat(3.25).description().equals(String.withCString("3.250000")));  // T7c
    Assert.isTrue(Number.withFloat(-1.5).description().equals(String.withCString("-1.500000"))); // T7d

    // ── T8: String from numbers.
    Assert.isTrue(String.withI32((i32)0).equals(String.withCString("0")));                    // T8a
    Assert.isTrue(String.withI32((i32)7).equals(String.withCString("7")));
    Assert.isTrue(String.withI32((i32)-1).equals(String.withCString("-1")));                  // T8b
    Assert.isTrue(String.withU32((u32)4294967295).equals(String.withCString("4294967295")));  // T8c — u32 max
    Assert.isTrue(String.withI16((i16)-32768).equals(String.withCString("-32768")));          // T8d — i16 min
    Assert.isTrue(String.withU16((u16)65535).equals(String.withCString("65535")));            // T8e
}

void main(void)
{
    t1_t2();
    t3_t9();
    t4_t5_t6();
    t7_t8();
    Assert.summary();
    return;
}
