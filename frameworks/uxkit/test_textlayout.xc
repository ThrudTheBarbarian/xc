// test_textlayout.xc — UXTextLayout greedy word wrap (charWidth=1 so maxChars == width).
#import <Stdio.xc>
#import "UXTextLayout.xc"

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
// compare a line's substring to want
bool lineIs(u8* text, UXRange* ln, u8* want)
    {
    i32 i = (i32)0;
    while (want[i] != (u8)0)
        {
        if (i >= ln.len || text[ln.loc + i] != want[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return i == ln.len;
    }
void lineEq(u8* text, Array<UXRange>* lines, i32 idx, u8* want)
    {
    if (idx < (i32)lines.count() && lineIs(text, (UXRange* ?)lines.get((u16)idx), want))
        {
        Stdio.printf("  ok   line %d = \"%s\"\n", (i16)idx, want);
        }
    else
        {
        Stdio.printf("  FAIL line %d != \"%s\"\n", (i16)idx, want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // "the quick brown fox" wrapped at width 10 (charWidth 1)
    u8* t = (u8*)"the quick brown fox";
    Array* l = UXTextLayout.wrap(t, (i16)10, (i16)1);
    check("two lines at width 10", (i32)l.count(), (i32)2);
    lineEq(t, l, (i32)0, (u8*)"the quick");
    lineEq(t, l, (i32)1, (u8*)"brown fox");

    // wider: everything on one line
    check("one line at width 40", UXTextLayout.lineCount(t, (i16)40, (i16)1), (i32)1);

    // narrow: one word per line-ish
    Array* l2 = UXTextLayout.wrap(t, (i16)5, (i16)1);
    check("narrow wrap lines", (i32)l2.count(), (i32)4); // the / quick / brown / fox
    lineEq(t, l2, (i32)0, (u8*)"the");
    lineEq(t, l2, (i32)1, (u8*)"quick");
    lineEq(t, l2, (i32)3, (u8*)"fox");

    // explicit newlines always break
    u8* nl = (u8*)"a\nbb\nccc";
    Array* l3 = UXTextLayout.wrap(nl, (i16)80, (i16)1);
    check("newlines force three lines", (i32)l3.count(), (i32)3);
    lineEq(nl, l3, (i32)0, (u8*)"a");
    lineEq(nl, l3, (i32)1, (u8*)"bb");
    lineEq(nl, l3, (i32)2, (u8*)"ccc");

    // a word longer than the line hard-breaks
    u8* big = (u8*)"abcdefghij";
    Array* l4 = UXTextLayout.wrap(big, (i16)4, (i16)1);
    check("long word hard-breaks into 3", (i32)l4.count(), (i32)3);
    lineEq(big, l4, (i32)0, (u8*)"abcd");
    lineEq(big, l4, (i32)1, (u8*)"efgh");
    lineEq(big, l4, (i32)2, (u8*)"ij");

    // trailing newline doesn't add an empty phantom line here
    check("'a\\n' is one line", UXTextLayout.lineCount((u8*)"a\n", (i16)80, (i16)1), (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTextLayout — word wrap, narrow wrap, newlines, hard-break long words.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
