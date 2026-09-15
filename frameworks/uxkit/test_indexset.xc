// test_indexset.xc — UXIndexSet stores indices as coalesced sorted ranges.
#import <Stdio.xc>
#import "UXIndexSet.xc"

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

void main(void)
    {
    gFails = (i32)0;
    UXIndexSet* s = new UXIndexSet();

    // ---- adjacency coalescing: 3,4,5 then 6 is ONE range -------------------
    s.addIndex((i32)3);
    s.addIndex((i32)4);
    s.addIndex((i32)5);
    check("count 3..5", s.count(), (i32)3);
    check("one range so far", s.rangeCount(), (i32)1);
    s.addIndex((i32)6); // adjacent -> still one range
    check("still one range after adjacent add", s.rangeCount(), (i32)1);
    check("count 3..6", s.count(), (i32)4);

    // ---- a gap makes a second range, filling it coalesces ------------------
    s.addRange((i32)9, (i32)2); // 9,10 — gap at 7,8
    check("two ranges with a gap", s.rangeCount(), (i32)2);
    check("first index", s.firstIndex(), (i32)3);
    check("last index", s.lastIndex(), (i32)10);
    s.addRange((i32)7, (i32)2); // fill 7,8 -> everything 3..10 merges
    check("gap filled -> one range again", s.rangeCount(), (i32)1);
    check("count 3..10", s.count(), (i32)8);

    // ---- membership --------------------------------------------------------
    check("contains 3", s.containsIndex((i32)3) ? (i32)1 : (i32)0, (i32)1);
    check("contains 10", s.containsIndex((i32)10) ? (i32)1 : (i32)0, (i32)1);
    check("not 2", s.containsIndex((i32)2) ? (i32)1 : (i32)0, (i32)0);
    check("not 11", s.containsIndex((i32)11) ? (i32)1 : (i32)0, (i32)0);
    check("containsRange 4..7", s.containsRange((i32)4, (i32)4) ? (i32)1 : (i32)0, (i32)1);

    // ---- removal splits a range -------------------------------------------
    s.removeIndex((i32)6); // 3..10 minus 6 -> [3,3] + [7,4]
    check("removing the middle splits into two", s.rangeCount(), (i32)2);
    check("6 is gone", s.containsIndex((i32)6) ? (i32)1 : (i32)0, (i32)0);
    check("5 still there", s.containsIndex((i32)5) ? (i32)1 : (i32)0, (i32)1);
    check("7 still there", s.containsIndex((i32)7) ? (i32)1 : (i32)0, (i32)1);
    check("count after removing one", s.count(), (i32)7);

    // ---- iteration via indexGreaterThan -----------------------------------
    // Walk every member: 3,4,5,7,8,9,10.
    i32 walk[16];
    i32 wn = (i32)0;
    i32 idx = s.indexGreaterThan((i32)-1);
    while (idx >= (i32)0 && wn < (i32)16)
        {
        walk[wn] = idx;
        wn = wn + (i32)1;
        idx = s.indexGreaterThan(idx);
        }
    check("iterated member count", wn, (i32)7);
    check("first walked", walk[(i32)0], (i32)3);
    check("4th walked skips the hole (=7)", walk[(i32)3], (i32)7);
    check("last walked", walk[wn - (i32)1], (i32)10);
    check("indexLessThan 7 = 5 (over the hole)", s.indexLessThan((i32)7), (i32)5);

    // ---- set ops + equality -----------------------------------------------
    UXIndexSet* a = new UXIndexSet();
    a.addRange((i32)0, (i32)3); // 0,1,2
    UXIndexSet* b = new UXIndexSet();
    b.addRange((i32)0, (i32)3);
    check("equal sets", a.isEqualTo(b) ? (i32)1 : (i32)0, (i32)1);
    b.addIndex((i32)10);
    check("no longer equal", a.isEqualTo(b) ? (i32)1 : (i32)0, (i32)0);
    a.addIndexes(b); // union
    check("union has 0,1,2,10", a.count(), (i32)4);
    check("union range count", a.rangeCount(), (i32)2);
    check("intersects 2..4", a.intersectsRange((i32)2, (i32)3) ? (i32)1 : (i32)0, (i32)1);
    check("no intersect 4..9", a.intersectsRange((i32)4, (i32)5) ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXIndexSet — coalescing, splitting, membership, iteration, set ops.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
