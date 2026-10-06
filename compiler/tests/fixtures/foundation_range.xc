// foundation_range.xc — Range: the half-open contract, overlap edge cases,
// intersection and union, and value equality as a Set member.
#import "Foundation.xc"
#import "Range.xc"

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
i32 b(bool v)
    {
    return v ? (i32)1 : (i32)0;
    }

i32 main(void)
    {
    gFails = (i32)0;
    Range* r = Range.make((i32)3, (i32)4); // [3,7)
    check("end", r.end(), (i32)7);
    check("contains loc", b(r.contains((i32)3)), (i32)1);
    check("not end", b(r.contains((i32)7)), (i32)0);
    check("not before", b(r.contains((i32)2)), (i32)0);
    check("empty", b(Range.make((i32)5, (i32)0).isEmpty()), (i32)1);

    check("touching do not overlap", b(Range.make((i32)0, (i32)3).overlaps(Range.make((i32)3, (i32)2))), (i32)0);
    check("crossing overlap", b(Range.make((i32)0, (i32)4).overlaps(Range.make((i32)3, (i32)2))), (i32)1);
    check("empty inside overlaps nothing", b(Range.make((i32)0, (i32)10).overlaps(Range.make((i32)5, (i32)0))), (i32)0);
    check("null overlaps nothing", b(r.overlaps((Range*)0)), (i32)0);

    Range* i = Range.make((i32)0, (i32)5).intersection(Range.make((i32)3, (i32)5)); // [3,5)
    check("intersection loc", i.loc, (i32)3);
    check("intersection len", i.len, (i32)2);
    check("disjoint intersection empty", b(Range.make((i32)0, (i32)2).intersection(Range.make((i32)5, (i32)2)).isEmpty()), (i32)1);
    Range* u = Range.make((i32)0, (i32)2).unionWith(Range.make((i32)5, (i32)2)); // [0,7)
    check("union loc", u.loc, (i32)0);
    check("union len", u.len, (i32)7);
    check("union with empty", Range.make((i32)4, (i32)2).unionWith(Range.make((i32)0, (i32)0)).loc, (i32)4);

    check("equal by value", b(Range.make((i32)1, (i32)2).equals(Range.make((i32)1, (i32)2))), (i32)1);
    check("unequal len", b(Range.make((i32)1, (i32)2).equals(Range.make((i32)1, (i32)3))), (i32)0);
    Set* s = new Set();
    s.add(Range.make((i32)1, (i32)2));
    s.add(Range.make((i32)1, (i32)2));
    s.add(Range.make((i32)4, (i32)1));
    check("set holds two distinct", (i32)s.count(), (i32)2);
    check("set finds by value", b(s.contains(Range.make((i32)4, (i32)1))), (i32)1);

    if (gFails == (i32)0)
        Stdio.printf("PASS\n");
    return gFails;
    }
