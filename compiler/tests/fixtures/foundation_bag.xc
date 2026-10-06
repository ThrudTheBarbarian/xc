// foundation_bag.xc — Bag, Foundation's counted set: identity counting for
// plain objects, value counting for strings, insertion order across removals,
// totals, and more distinct members than a u16 index could reach.
#import "Foundation.xc"

class Tok : Object
    {
    i32 id;
    void init(void)
        {
        id = (i32)0;
        }
    }

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        Stdio.printf("  ok   %s = %d\n", what, got);
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

i32 main(void)
    {
    gFails = (i32)0;
    Bag* bag = new Bag();
    Tok* a = new Tok();
    Tok* b = new Tok();
    Tok* c = new Tok();
    a.id = (i32)1;
    b.id = (i32)2;
    c.id = (i32)3;

    check("empty total", bag.totalCount(), (i32)0);
    check("empty unique", bag.uniqueCount(), (i32)0);
    bag.add(a);
    bag.add(a);
    bag.add(a);
    bag.add(b);
    check("a three", bag.countFor(a), (i32)3);
    check("b one", bag.countFor(b), (i32)1);
    check("c none", bag.countFor(c), (i32)0);
    check("contains a", bag.contains(a) ? (i32)1 : (i32)0, (i32)1);
    check("not c", bag.contains(c) ? (i32)1 : (i32)0, (i32)0);
    check("total 4", bag.totalCount(), (i32)4);
    check("unique 2", bag.uniqueCount(), (i32)2);
    bag.addTimes(c, (i32)5);
    bag.addTimes(c, (i32)0);
    check("c five", bag.countFor(c), (i32)5);
    check("total 9", bag.totalCount(), (i32)9);

    // order: a, b, c — and removing b keeps a before c
    check("member 0 is a", ((Tok*)bag.memberAt((i32)0)).id, (i32)1);
    check("member 2 is c", ((Tok*)bag.memberAt((i32)2)).id, (i32)3);
    check("count at 2", bag.countAt((i32)2), (i32)5);
    bag.remove(b);
    check("b gone", bag.contains(b) ? (i32)1 : (i32)0, (i32)0);
    check("unique 2 again", bag.uniqueCount(), (i32)2);
    check("member 1 is c", ((Tok*)bag.memberAt((i32)1)).id, (i32)3);
    check("past the end", bag.memberAt((i32)2) == (Object*)0 ? (i32)1 : (i32)0, (i32)1);
    bag.remove(a);
    check("a two", bag.countFor(a), (i32)2);
    bag.removeAllOf(c);
    check("c all gone", bag.countFor(c), (i32)0);
    check("total 2", bag.totalCount(), (i32)2);
    bag.add(b);
    check("b back, last", ((Tok*)bag.memberAt((i32)1)).id, (i32)2);

    // two distinct Tok objects with the same id are two members (identity)
    Tok* a2 = new Tok();
    a2.id = (i32)1;
    bag.add(a2);
    check("identity: a2 separate", bag.countFor(a2), (i32)1);
    check("identity: a still two", bag.countFor(a), (i32)2);

    // strings count by value
    Bag* words = new Bag();
    words.add(String.withCString("the"));
    words.add(String.withCString("cat"));
    words.add(String.withCString("the"));
    check("'the' twice", words.countFor(String.withCString("the")), (i32)2);
    check("'cat' once", words.countFor(String.withCString("cat")), (i32)1);
    check("two words", words.uniqueCount(), (i32)2);

    // for-in walks the distinct members
    i32 n = (i32)0;
    for (Object* w in words)
        n = n + words.countFor(w);
    check("for-in sums to total", n, words.totalCount());

    bag.removeAll();
    check("emptied total", bag.totalCount(), (i32)0);
    check("emptied unique", bag.uniqueCount(), (i32)0);

    // Many distinct members: past what a u16 index reaches on the 32-bit
    // machines; on the 6502, whose Foundation indexes with u16 and whose heap
    // is a few banks, a few hundred.
#if ARCH_6502
    u32 big = (u32)300;
#else
    u32 big = (u32)70000;
#endif
    Bag* many = new Bag();
    for (u32 i = (u32)0; i < big; i = i + (u32)1)
        many.addTimes(Number.withU32(i), (i32)2);
    check("many distinct", many.uniqueCount() == (i32)big ? (i32)1 : (i32)0, (i32)1);
    check("twice as many in all", many.totalCount() == (i32)(big * (u32)2) ? (i32)1 : (i32)0, (i32)1);
    check("the last one counted", many.countFor(Number.withU32(big - (u32)1)), (i32)2);

    if (gFails == (i32)0)
        Stdio.printf("PASS\n");
    return gFails;
    }
