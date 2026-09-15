// richtext.xc — per-character attributes, coalesced into runs on demand.
//
// Storage is one attribute record per character, which keeps set and query
// trivial; the RUNS a drawing pass wants are derived, not maintained.
#import <Stdio.xc>
#import "UXAttributedString.xc"

void showRuns(UXAttributedString* a) {
    Array<UXAttrRun>* rs = a.runs();
    Stdio.printf("  %d run(s):", a.runCount());
    for (u16 i = 0; i < rs.count(); i = i + 1) {
        UXAttrRun* r = (UXAttrRun* ?)rs.get(i);
        Stdio.printf(" [%d..%d%s%s]", r.loc, r.end() - 1,
                     r.attr.bold ? (u8*)" B" : (u8*)"",
                     r.attr.italic ? (u8*)" I" : (u8*)"");
    }
    Stdio.printf("\n");
}

void main(void) {
    UXAttributedString* a = UXAttributedString.make((u8*)"hello brave world");
    Stdio.printf("plain:\n"); showRuns(a);

    // "brave" is characters 6..10.
    a.setBold(true, 6, 5);
    Stdio.printf("bold 6..10:\n"); showRuns(a);

    // An overlapping italic SPLITS the runs where the styles differ.
    a.setItalic(true, 9, 4);
    Stdio.printf("+ italic 9..12:\n"); showRuns(a);

    // Setting a style back to match its neighbours COALESCES again — runs are
    // derived, so nothing has to be merged by hand.
    a.setBold(false, 6, 5);
    a.setItalic(false, 9, 4);
    Stdio.printf("all cleared:\n"); showRuns(a);

    // Querying is per character, always.
    a.setBold(true, 0, 5);
    Stdio.printf("char 0 bold: %s   char 6 bold: %s\n",
                 a.attributesAt(0).bold ? (u8*)"yes" : (u8*)"no",
                 a.attributesAt(6).bold ? (u8*)"yes" : (u8*)"no");

    // Ranges are clamped, so an over-long span is harmless.
    a.setItalic(true, 12, 999);
    Stdio.printf("after an over-long range: length still %d\n", a.length());
    showRuns(a);
}
