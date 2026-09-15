// foundation_sort.xc — ordering, and Array sorting on top of it.
//
// Nothing in Foundation could be ORDERED before this: Comparable declared only
// `equals`, and Sort.qsort took a raw u16[] with a u16 comparator, so it could
// not touch a container of Object@.
//
// Comparable now also declares
//
//     optional i8 compare(Object@ other);      // <0 / 0 / >0, as NSComparisonResult
//
// and it is OPTIONAL on purpose. Equality is universal; ordering is not — a
// colour can be compared for sameness without any colour being "less than"
// another. A class that omits it simply has no order, and the language says so
// honestly: an unimplemented optional method leaves a null vtable slot, so
// `&obj.compare` comes back null and that IS respondsTo.
//
// So Array.sort() RETURNS FALSE for elements that define no order, rather than
// inventing one. Inventing one would be a lie that surfaces much later, in the
// output, with nothing to trace it back to.
//
//   T1  sort() on Numbers — ascending
//   T2  sortUsing() with an explicit comparator — descending
//   T3  sort() on Strings — lexicographic, and a prefix sorts before its
//       extension ("go" before "gone")
//   T4  sort() returns FALSE, and changes nothing, when elements have no order
//   T5  sorted() / sortedUsing() leave the receiver alone and return a copy
//   T6  isSortedUsing() agrees
//   T7  a bound METHOD as the comparator — `&cfg.byMagnitude` carries its
//       receiver, so a comparator can be configured without a global
//   T8  edge cases: empty and single-element arrays sort trivially
//   T9  Number's cross-kind rule: Int(42) and Float(42.0) compare EQUAL, the
//       same as they do under equals()

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

// A class with no `compare` — conforms to Comparable via equals only, which is
// exactly the case sort() must refuse rather than fudge.
class Unordered <Comparable>
{
    u16 v;
    void init(void) { v = (u16)0; }
    bool equals(Object* other)
    {
        Unordered* o = (Unordered* ?)other;
        if (o == 0) return false;
        return v == o.v;
    }
}

// T7: a comparator that lives on an object, so it can be configured.
class Sorter
{
    bool descending;
    void init(void) { descending = false; }

    i8 byValue(Object* a, Object* b)
    {
        Number* x = (Number* ?)a;
        Number* y = (Number* ?)b;
        if (x == 0 || y == 0) return (i8)0;
        i8 c = x.compare(y);
        if (descending) return (i8)(0 - (i32)c);
        return c;
    }
}

i8 descNum(Object* a, Object* b)
{
    Number* x = (Number* ?)a;
    Number* y = (Number* ?)b;
    if (x == 0 || y == 0) return (i8)0;
    return (i8)(0 - (i32)x.compare(y));
}

i8 ascNum(Object* a, Object* b)
{
    Number* x = (Number* ?)a;
    Number* y = (Number* ?)b;
    if (x == 0 || y == 0) return (i8)0;
    return x.compare(y);
}

u16 nth(Array* a, u16 i)
{
    Number* n = (Number* ?)a.get(i);
    if (n == 0) return (u16)$FFFF;
    return (u16)n.asI16();
}

void t1_t2(void)
{
    // ── T1: natural order.
    Array* a = new Array();
    a.add(Number.with((i16)5)); a.add(Number.with((i16)3));
    a.add(Number.with((i16)9)); a.add(Number.with((i16)1));
    a.add(Number.with((i16)7));

    Assert.isTrue(a.sort());                              // T1a
    Assert.isEqual(nth(a, (u16)0), (u16)1);               // T1b
    Assert.isEqual(nth(a, (u16)1), (u16)3);
    Assert.isEqual(nth(a, (u16)2), (u16)5);
    Assert.isEqual(nth(a, (u16)3), (u16)7);
    Assert.isEqual(nth(a, (u16)4), (u16)9);               // T1c

    // ── T2: explicit comparator.
    a.sortUsing(&descNum);
    Assert.isEqual(nth(a, (u16)0), (u16)9);               // T2a
    Assert.isEqual(nth(a, (u16)4), (u16)1);               // T2b

}

void t3(void)
{
    // ── T3: Strings sort lexicographically, prefix first.
    Array* s = new Array();
    s.add(String.withCString("pear"));
    s.add(String.withCString("apple"));
    s.add(String.withCString("gone"));
    s.add(String.withCString("go"));
    s.add(String.withCString("fig"));
    Assert.isTrue(s.sort());                              // T3a

    String* s0 = (String* ?)s.get((u16)0);
    String* s1 = (String* ?)s.get((u16)1);
    String* s2 = (String* ?)s.get((u16)2);
    String* s3 = (String* ?)s.get((u16)3);
    String* s4 = (String* ?)s.get((u16)4);
    Assert.isTrue(s0.equals(String.withCString("apple"))); // T3b
    Assert.isTrue(s1.equals(String.withCString("fig")));
    Assert.isTrue(s2.equals(String.withCString("go")));    // prefix before…
    Assert.isTrue(s3.equals(String.withCString("gone")));  // …its extension
    Assert.isTrue(s4.equals(String.withCString("pear")));  // T3c

}

void t4(void)
{
    // ── T4: elements with NO order. sort() must refuse, and change nothing.
    Array* u = new Array();
    Unordered* u1 = new Unordered(); u1.v = (u16)3;
    Unordered* u2 = new Unordered(); u2.v = (u16)1;
    u.add(u1);
    u.add(u2);
    Assert.isFalse(u.sort());                             // T4a — refused
    Unordered* still = (Unordered* ?)u.get((u16)0);
    Assert.isTrue(still != 0);
    Assert.isEqual(still.v, (u16)3);                      // T4b — untouched

}

void t5_t6(void)
{
    // ── T5: sorted() returns a copy; the receiver keeps its order.
    Array* b = new Array();
    b.add(Number.with((i16)2)); b.add(Number.with((i16)8)); b.add(Number.with((i16)4));
    Array* bs = b.sorted();
    Assert.isEqual(nth(b,  (u16)0), (u16)2);              // T5a — receiver as it was
    Assert.isEqual(nth(b,  (u16)1), (u16)8);
    Assert.isEqual(nth(bs, (u16)0), (u16)2);              // T5b — copy is sorted
    Assert.isEqual(nth(bs, (u16)1), (u16)4);
    Assert.isEqual(nth(bs, (u16)2), (u16)8);
    Assert.isEqual(bs.count(), (u16)3);                   // T5c

    Array* bd = b.sortedUsing(&descNum);
    Assert.isEqual(nth(bd, (u16)0), (u16)8);              // T5d
    Assert.isEqual(nth(bd, (u16)2), (u16)2);

    // ── T6: isSortedUsing.
    Assert.isTrue(bs.isSortedUsing(&ascNum));             // T6a
    Assert.isFalse(bs.isSortedUsing(&descNum));           // T6b

}

void t7_t8_t9(void)
{
    // ── T7: a BOUND METHOD as the comparator — it carries its receiver, so
    // the sort direction is configuration, not a global.
    Sorter* cfg = new Sorter();
    cfg.descending = true;
    Array* c = new Array();
    c.add(Number.with((i16)5)); c.add(Number.with((i16)1)); c.add(Number.with((i16)3));
    c.sortUsing(&cfg.byValue);
    Assert.isEqual(nth(c, (u16)0), (u16)5);               // T7a — descending
    Assert.isEqual(nth(c, (u16)2), (u16)1);

    cfg.descending = false;
    c.sortUsing(&cfg.byValue);
    Assert.isEqual(nth(c, (u16)0), (u16)1);               // T7b — same ^, other way
    Assert.isEqual(nth(c, (u16)2), (u16)5);

    // ── T8: degenerate sizes.
    Array* e = new Array();
    Assert.isTrue(e.sort());                              // T8a — empty
    e.add(Number.with((i16)1));
    Assert.isTrue(e.sort());                              // T8b — single
    Assert.isEqual(e.count(), (u16)1);

    // ── T9: Number's cross-kind rule matches equals().
    Number* ni = Number.with((i16)42);
    Number* nf = Number.withFloat(42.0);
    Assert.isEqual((i16)ni.compare(nf), (i16)0);          // T9a — equal order
    Assert.isTrue(ni.equals(nf));                         // T9b — and equal value
    Number* big = Number.with((i16)43);
    Assert.isEqual((i16)ni.compare(big), (i16)-1);        // T9c — 42 before 43
    Assert.isEqual((i16)big.compare(ni), (i16)1);         // T9d

}

void main(void)
{
    t1_t2();
    t3();
    t4();
    t5_t6();
    t7_t8_t9();
    Assert.summary();
    return;
}
