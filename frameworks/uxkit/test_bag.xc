// test_bag.xc — UXBag: counted-set semantics by object identity.
#import <Stdio.xc>
#import "UXBag.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
class Tok : Object
    {
    i32 id;
    void init(void)
        {
        id = (i32)0;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;
    UXBag* bag = new UXBag();
    Tok* a = new Tok();
    Tok* b = new Tok();
    Tok* c = new Tok();

    check("empty total", bag.totalCount(), (i32)0);
    check("empty unique", bag.uniqueCount(), (i32)0);

    bag.add(a);
    bag.add(a);
    bag.add(a); // a x3
    bag.add(b); // b x1
    check("a counted three", bag.countFor((Object*)a), (i32)3);
    check("b counted one", bag.countFor((Object*)b), (i32)1);
    check("c not present", bag.countFor((Object*)c), (i32)0);
    check("contains a", bag.contains((Object*)a) ? (i32)1 : (i32)0, (i32)1);
    check("does not contain c", bag.contains((Object*)c) ? (i32)1 : (i32)0, (i32)0);
    check("total 4", bag.totalCount(), (i32)4);
    check("unique 2", bag.uniqueCount(), (i32)2);

    bag.addTimes((Object*)c, (i32)5);
    check("c bulk-added", bag.countFor((Object*)c), (i32)5);
    check("total 9", bag.totalCount(), (i32)9);
    check("unique 3", bag.uniqueCount(), (i32)3);

    // remove one occurrence
    bag.remove((Object*)a);
    check("a now two", bag.countFor((Object*)a), (i32)2);
    check("total 8", bag.totalCount(), (i32)8);
    check("a still present", bag.contains((Object*)a) ? (i32)1 : (i32)0, (i32)1);

    // remove the last occurrence -> drops out
    bag.remove((Object*)b);
    check("b gone at zero", bag.contains((Object*)b) ? (i32)1 : (i32)0, (i32)0);
    check("unique back to 2", bag.uniqueCount(), (i32)2);

    // removeAllOf drops the whole tally
    bag.removeAllOf((Object*)c);
    check("c wholly removed", bag.countFor((Object*)c), (i32)0);
    check("total is just a's 2", bag.totalCount(), (i32)2);
    check("unique is 1", bag.uniqueCount(), (i32)1);

    // identity: a different object with the same fields is a different member
    Tok* a2 = new Tok();
    bag.add(a2);
    check("distinct instance is distinct member", bag.uniqueCount(), (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXBag — counts, bulk add, decrement-to-zero, removeAllOf, identity.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
