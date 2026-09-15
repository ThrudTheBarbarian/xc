// test_null.xc — UXNull: a shared null sentinel usable as a non-nil placeholder in a collection.
#import <Stdio.xc>
#import "UXNull.xc"

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

class Thing : Object
    {
    i32 v;
    void init(void)
        {
        v = (i32)0;
        }
    }

    void
    main(void)
    {
    gFails = (i32)0;

    // singleton: the same instance every time
    check("null() is a singleton", UXNull.null() == UXNull.null() ? (i32)1 : (i32)0, (i32)1);

    // recognition
    check("isNull on the sentinel", UXNull.isNull((Object*)UXNull.null()) ? (i32)1 : (i32)0, (i32)1);
    check("isNull on a real object is false", UXNull.isNull((Object*)new Thing()) ? (i32)1 : (i32)0, (i32)0);
    check("isNull on nil is false", UXNull.isNull((Object*)0) ? (i32)1 : (i32)0, (i32)0);
    check("isNothing on nil is true", UXNull.isNothing((Object*)0) ? (i32)1 : (i32)0, (i32)1);
    check("isNothing on the sentinel is true", UXNull.isNothing((Object*)UXNull.null()) ? (i32)1 : (i32)0, (i32)1);
    check("isNothing on a real object is false", UXNull.isNothing((Object*)new Thing()) ? (i32)1 : (i32)0, (i32)0);

    // usable as an explicit placeholder in a collection (distinct from an absent slot)
    Array* a = new Array();
    a.add(new Thing());
    a.add(UXNull.null()); // "this row is intentionally empty"
    a.add(new Thing());
    check("array holds three slots", (i32)a.count(), (i32)3);
    check("middle slot is the null sentinel", UXNull.isNull(a.get((u16)1)) ? (i32)1 : (i32)0, (i32)1);
    check("first slot is a real thing", UXNull.isNull(a.get((u16)0)) ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXNull — singleton identity, recognition, and use as a collection placeholder.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
