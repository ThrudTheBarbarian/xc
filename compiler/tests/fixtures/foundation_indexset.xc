// foundation_indexset.xc — IndexSet: merging and splitting ranges, counts,
// membership, neighbours, shifting for inserted and deleted rows, equality.
#import "Foundation.xc"
#import "IndexSet.xc"

void show(u8* what, IndexSet* s)
    {
    // Two short lines: the 6502's screen is 40 columns.
    Stdio.printf("%s:\n  %s n=%u r=%u\n", what, s.description().cString(), s.count(), s.rangeCount());
    }
void flag(u8* what, bool v)
    {
    Stdio.printf("%s %d\n", what, (i32)(v ? 1 : 0));
    }
void num(u8* what, i32 v)
    {
    Stdio.printf("%s %d\n", what, v);
    }
Range* R(i32 loc, i32 len)
    {
    return Range.make(loc, len);
    }

i32 main(void)
    {
    IndexSet* s = new IndexSet();
    s.addRange(R((i32)3, (i32)3));
    s.addIndex((i32)9);
    s.addIndex((i32)10);
    show("3-5, 9, 10", s);
    s.addIndex((i32)6);
    show("add 6 touches", s);
    s.addIndex((i32)8);
    show("add 8 joins", s);
    s.addRange(R((i32)0, (i32)2));
    show("add 0-1", s);
    s.addRange(R((i32)1, (i32)20));
    show("add 1-20 swallows", s);
    s.removeRange(R((i32)5, (i32)3));
    show("remove 5-7 splits", s);
    s.removeIndex((i32)0);
    s.removeIndex((i32)20);
    show("remove ends", s);
    s.removeRange(R((i32)4, (i32)10));
    show("remove 4-13", s);

    IndexSet* t = new IndexSet();
    t.addRange(R((i32)10, (i32)5));
    t.addIndex((i32)20);
    t.addIndex((i32)30);
    flag("contains 12", t.containsIndex((i32)12));
    flag("contains 15", t.containsIndex((i32)15));
    flag("range 10-14", t.containsRange(R((i32)10, (i32)5)));
    flag("range 10-15", t.containsRange(R((i32)10, (i32)6)));
    flag("intersects 15-19", t.intersectsRange(R((i32)15, (i32)5)));
    flag("intersects 14-19", t.intersectsRange(R((i32)14, (i32)6)));
    num("first", t.firstIndex());
    num("last", t.lastIndex());
    num(">14", t.indexGreaterThan((i32)14));
    num(">=20", t.indexGreaterThanOrEqualTo((i32)20));
    num(">30", t.indexGreaterThan((i32)30));
    num("<10", t.indexLessThan((i32)10));
    num("<20", t.indexLessThan((i32)20));
    num("<=12", t.indexLessThanOrEqualTo((i32)12));

    IndexSet* rows = new IndexSet();
    rows.addRange(R((i32)2, (i32)4));
    rows.addIndex((i32)10);
    show("rows", rows);
    IndexSet* ins = rows.copy();
    ins.shiftIndexes((i32)4, (i32)2);
    show("insert 2 rows at 4", ins);
    IndexSet* del = rows.copy();
    del.shiftIndexes((i32)5, (i32)-2);
    show("delete rows 3-4", del);
    IndexSet* del2 = rows.copy();
    del2.shiftIndexes((i32)10, (i32)-4);
    show("delete rows 6-9", del2);

    IndexSet* a = IndexSet.withRange(R((i32)1, (i32)3));
    IndexSet* b = new IndexSet();
    b.addIndex((i32)3);
    b.addIndex((i32)1);
    b.addIndex((i32)2);
    flag("equal", a.equals(b));
    flag("b contains a", b.containsIndexes(a));
    flag("hash same", a.hash() == b.hash());
    a.addIndexes(t);
    show("a plus t", a);
    a.removeIndexes(t);
    show("a minus t", a);
    IndexSet* e = new IndexSet();
    num("empty first", e.firstIndex());
    num("empty last", e.lastIndex());
    flag("empty", e.isEmpty());
    return (i32)0;
    }
