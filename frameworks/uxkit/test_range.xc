// test_range.xc — UXRange: the half-open contract, and the classes built on it.
//
// UXRange is one type standing where four used to: UXIndexSet's ranges, UXTextLayout's lines,
// UXTextLayout's runs and UXAttributedString's runs.  What is worth testing is the contract those
// four now share — half-open, so end() is NOT a member and touching ranges do not overlap — and that
// the payload classes really are ranges, not lookalikes.
#import <Stdio.xc>
#import "UXRange.xc"
#import "UXTextLayout.xc"
#import "UXAttributedString.xc"

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
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    UXRange* r = UXRange.make((i32)3, (i32)4); // [3, 7)
    check("loc", r.loc, (i32)3);
    check("len", r.len, (i32)4);
    check("end is one past the last", r.end(), (i32)7);
    checkTrue("contains its first index", r.contains((i32)3));
    checkTrue("contains its last index", r.contains((i32)6));
    checkTrue("does NOT contain end()", !r.contains((i32)7)); // the half-open contract
    checkTrue("does not contain what is before it", !r.contains((i32)2));
    checkTrue("a non-empty range is not empty", !r.isEmpty());

    UXRange* empty = UXRange.make((i32)5, (i32)0);
    checkTrue("a zero-length range is empty", empty.isEmpty());
    check("...and starts where it ends", empty.end(), empty.loc);
    checkTrue("...and contains nothing", !empty.contains((i32)5));

    // Touching end-to-end is NOT overlapping — that is the whole point of half-open, and the reason
    // UXIndexSet can coalesce [0,3) with [3,2) into [0,5) without double-counting index 3.
    UXRange* a = UXRange.make((i32)0, (i32)3); // [0, 3)
    UXRange* b = UXRange.make((i32)3, (i32)2); // [3, 5)
    checkTrue("adjacent ranges do not overlap", !a.overlaps(b));
    checkTrue("...symmetrically", !b.overlaps(a));
    check("...and meet exactly", a.end(), b.loc);
    UXRange* c = UXRange.make((i32)2, (i32)2); // [2, 4) — shares index 2
    checkTrue("genuinely overlapping ranges say so", a.overlaps(c));
    checkTrue("...symmetrically", c.overlaps(a));
    checkTrue("an empty range overlaps nothing", !empty.overlaps(UXRange.make((i32)0, (i32)10)));
    checkTrue("overlapping nil is false, not a crash", !a.overlaps((UXRange*)0));

    // The payload classes ARE ranges: they answer the range API, not a copy of it.
    UXTextRun* run = UXTextRun.at((i32)10, (i32)5, (i32)40);
    check("a text run's loc", run.loc, (i32)10);
    check("a text run's end", run.end(), (i32)15);
    check("...and it still carries its position", run.x, (i32)40);
    checkTrue("a text run contains an index inside it", run.contains((i32)14));
    UXRange* asRange = (UXRange*)run; // usable wherever a range is wanted
    check("a run passed as a plain range keeps its end", asRange.end(), (i32)15);

    UXAttrRun* ar = new UXAttrRun();
    ar.loc = (i32)2;
    ar.len = (i32)3;
    check("an attribute run's end", ar.end(), (i32)5);
    checkTrue("...and it contains its own characters", ar.contains((i32)4));

    // And the layout really does hand back ranges, with the same vocabulary.
    Array<UXRange>* lines = UXTextLayout.wrap((u8*)"aaa bbb ccc ddd", (i16)80, (i16)10);
    checkTrue("wrap produced lines", lines.count() > (u16)0);
    UXRange* ln = (UXRange* ?)lines.get((u16)0);
    check("a line is a range starting at 0", ln.loc, (i32)0);
    checkTrue("...with an end past its start", ln.end() > ln.loc);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXRange — half-open, adjacency, and the runs built on it.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
