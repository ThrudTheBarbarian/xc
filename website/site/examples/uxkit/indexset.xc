// indexset.xc — UXIndexSet stores RANGES, not integers.
//
// A table's multi-selection is the motivating case: rows 3,4,5 and 9,10 are two
// ranges, not five integers, so a contiguous block of a million rows costs one.
#import <Stdio.xc>
#import "UXIndexSet.xc"

void dump(u8* what, UXIndexSet* s) {
    Stdio.printf("%s count=%d ranges=%d  [", what, s.count(), s.rangeCount());
    for (u16 i = 0; i < (u16)s.rangeCount(); i = i + 1) {
        UXRange* r = s.rangeAt(i);
        Stdio.printf(" %d..%d", r.loc, r.end() - 1);
    }
    Stdio.printf(" ]\n");
}

void main(void) {
    UXIndexSet* s = new UXIndexSet();

    // Three separate adds that happen to be adjacent COALESCE into one range.
    s.addIndex(3); s.addIndex(4); s.addIndex(5);
    dump((u8*)"3,4,5 added:  ", s);

    // A disjoint block stays separate — there is a gap at 6..8.
    s.addRange(9, 2);
    dump((u8*)"+ range 9,2:  ", s);

    // Adding the gap merges everything into ONE range.
    s.addRange(6, 3);
    dump((u8*)"+ range 6,3:  ", s);

    // Removing from the middle SPLITS a range in two.
    s.removeRange(5, 2);
    dump((u8*)"- range 5,2:  ", s);

    Stdio.printf("contains 4:   %s\n", s.containsIndex(4) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("contains 5:   %s\n", s.containsIndex(5) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("first=%d last=%d\n", s.firstIndex(), s.lastIndex());

    // Walking every index, gaps skipped, without asking about the ones between.
    Stdio.printf("iterate:      ");
    i32 i = s.firstIndex();
    while (i >= 0) { Stdio.printf("%d ", i); i = s.indexGreaterThan(i); }
    Stdio.printf("\n");
}
