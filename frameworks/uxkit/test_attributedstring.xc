// test_attributedstring.xc — UXAttributedString: per-range attributes + run coalescing.
#import <Stdio.xc>
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

void main(void)
    {
    gFails = (i32)0;
    UXAttributedString* s = UXAttributedString.make((u8*)"Hello World"); // len 11
    check("length", s.length(), (i32)11);
    check("starts as one run", s.runCount(), (i32)1);
    check("default not bold", s.attributesAt((i32)0).bold ? (i32)1 : (i32)0, (i32)0);
    check("default pen 1", s.attributesAt((i32)0).pen, (i32)1);

    // bold "Hello" (0..5)
    s.setBold(true, (i32)0, (i32)5);
    check("H is bold", s.attributesAt((i32)0).bold ? (i32)1 : (i32)0, (i32)1);
    check("o (idx4) is bold", s.attributesAt((i32)4).bold ? (i32)1 : (i32)0, (i32)1);
    check("space (idx5) not bold", s.attributesAt((i32)5).bold ? (i32)1 : (i32)0, (i32)0);
    // runs now: [0..5 bold] [5..11 plain] = 2
    check("two runs after bolding a prefix", s.runCount(), (i32)2);

    // colour "World" (6..11)
    s.setColor((i32)2, (i32)6, (i32)5);
    check("W is pen 2", s.attributesAt((i32)6).pen, (i32)2);
    check("space still pen 1", s.attributesAt((i32)5).pen, (i32)1);
    // runs: [0..5 bold] [5..6 plain space] [6..11 pen2] = 3
    check("three runs", s.runCount(), (i32)3);

    // overlapping: italicize "lo Wo" (3..8) crosses the bold/space/colour boundaries
    s.setItalic(true, (i32)3, (i32)5);
    check("idx3 bold+italic", (s.attributesAt((i32)3).bold && s.attributesAt((i32)3).italic) ? (i32)1 : (i32)0, (i32)1);
    check("idx7 italic+pen2", (s.attributesAt((i32)7).italic && s.attributesAt((i32)7).pen == (i32)2) ? (i32)1 : (i32)0, (i32)1);
    check("idx9 not italic", s.attributesAt((i32)9).italic ? (i32)1 : (i32)0, (i32)0);

    // verify the runs partition the whole string with no gaps
    Array<UXAttrRun>* rs = s.runs();
    i32 covered = (i32)0;
    for (u16 i = (u16)0; i < rs.count(); i = i + (u16)1)
        { covered = covered + ((UXAttrRun* ?)rs.get(i)).len;
        }
    check("runs cover every character", covered, (i32)11);
    // first run starts at 0
    check("first run starts at 0", (i32)((UXAttrRun* ?)rs.get((u16)0)).loc, (i32)0);

    // out-of-range set is clamped, not a crash
    s.setBold(true, (i32)8, (i32)999);
    check("clamped set kept length", s.length(), (i32)11);
    check("last char bolded via clamp", s.attributesAt((i32)10).bold ? (i32)1 : (i32)0, (i32)1);

    // a uniform restyle collapses back to one run
    UXAttributedString* u = UXAttributedString.make((u8*)"abcdef");
    u.setSize((i16)18, (i32)0, (i32)6);
    check("uniform attribute is one run", u.runCount(), (i32)1);
    check("size applied", (i32)u.attributesAt((i32)3).size, (i32)18);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXAttributedString — per-range attributes, run coalescing, overlap, clamping.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
