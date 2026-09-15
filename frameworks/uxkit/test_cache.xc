// test_cache.xc — UXCache LRU eviction.
#import <Stdio.xc>
#import "UXCache.xc"

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
class Val : Object
    {
    i32 v;
    void init(void)
        {
        v = (i32)0;
        }
    } Val* mk(i32 v)
    {
    Val* x = new Val();
    x.v = v;
    return x;
    }
i32 has(UXCache* c, u8* k)
    {
    return c.contains(k) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;
    UXCache* c = new UXCache();
    c.setCapacity((i32)3);

    c.set((u8*)"a", mk((i32)1));
    c.set((u8*)"b", mk((i32)2));
    c.set((u8*)"c", mk((i32)3));
    check("count 3", c.count(), (i32)3);
    check("get a", ((Val* ?)c.get((u8*)"a")).v, (i32)1);

    // touch 'a' so it is most-recent; then insert 'd' -> LRU is 'b'
    c.get((u8*)"a");
    c.set((u8*)"d", mk((i32)4));
    check("still 3 after eviction", c.count(), (i32)3);
    check("b evicted (LRU)", has(c, (u8*)"b"), (i32)0);
    check("a survived (was touched)", has(c, (u8*)"a"), (i32)1);
    check("c survived", has(c, (u8*)"c"), (i32)1);
    check("d present", has(c, (u8*)"d"), (i32)1);

    // updating an existing key doesn't grow, and refreshes recency
    c.set((u8*)"c", mk((i32)33));
    check("update keeps count 3", c.count(), (i32)3);
    check("updated value", ((Val* ?)c.get((u8*)"c")).v, (i32)33);

    // now insert 'e' -> LRU should be 'a' (a was touched before c-update and d-insert)... let's verify
    // recency order after ops: a(get), d(set), c(set update), c(get) -> oldest is 'a'
    c.set((u8*)"e", mk((i32)5));
    check("a is now the LRU victim", has(c, (u8*)"a"), (i32)0);
    check("e present", has(c, (u8*)"e"), (i32)1);
    check("count still 3", c.count(), (i32)3);

    // miss returns null
    check("missing key null", c.get((u8*)"zzz") == (Object*)0 ? (i32)1 : (i32)0, (i32)1);

    // explicit remove
    c.remove((u8*)"c");
    check("removed c", has(c, (u8*)"c"), (i32)0);
    check("count 2 after remove", c.count(), (i32)2);

    // shrinking capacity evicts down
    c.set((u8*)"x", mk((i32)7));
    check("count 3 again", c.count(), (i32)3);
    c.setCapacity((i32)1);
    check("shrunk to 1", c.count(), (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXCache — LRU eviction, recency on get/set, update-in-place, remove, shrink.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
