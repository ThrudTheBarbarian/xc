// test_markdown.xc — UXMarkdown inline formatting into an attributed string.
#import <Stdio.xc>
#import "UXMarkdown.xc"
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
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }
i32 boldAt(UXAttributedString* a, i32 i)
    {
    return a.attributesAt(i).bold ? (i32)1 : (i32)0;
    }
i32 italAt(UXAttributedString* a, i32 i)
    {
    return a.attributesAt(i).italic ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;

    // bold: markers stripped, span bold
    UXAttributedString* b = UXMarkdown.parse((u8*)"hello **world**");
    eq("bold text stripped", b.stringValue(), (u8*)"hello world");
    check("length 11", b.length(), (i32)11);
    check("'h' not bold", boldAt(b, (i32)0), (i32)0);
    check("'w' is bold", boldAt(b, (i32)6), (i32)1);
    check("'d' is bold", boldAt(b, (i32)10), (i32)1);
    check("space before world not bold", boldAt(b, (i32)5), (i32)0);

    // italic
    UXAttributedString* it = UXMarkdown.parse((u8*)"*note* here");
    eq("italic stripped", it.stringValue(), (u8*)"note here");
    check("'n' italic", italAt(it, (i32)0), (i32)1);
    check("'e' (idx3) italic", italAt(it, (i32)3), (i32)1);
    check("space after not italic", italAt(it, (i32)4), (i32)0);

    // code span -> grey pen
    UXAttributedString* cd = UXMarkdown.parse((u8*)"run `make` now");
    eq("code stripped", cd.stringValue(), (u8*)"run make now");
    check("code char pen is grey (9)", cd.attributesAt((i32)4).pen, (i32)9); // 'm' in make
    check("normal char pen is ink (1)", cd.attributesAt((i32)0).pen, (i32)1);

    // mixed bold + italic (nested-ish: **bold** then *italic*)
    UXAttributedString* mx = UXMarkdown.parse((u8*)"**A** *B*");
    eq("mixed stripped", mx.stringValue(), (u8*)"A B");
    check("A bold", boldAt(mx, (i32)0), (i32)1);
    check("A not italic", italAt(mx, (i32)0), (i32)0);
    check("B italic", italAt(mx, (i32)2), (i32)1);
    check("B not bold", boldAt(mx, (i32)2), (i32)0);

    // escape: \* is a literal asterisk, not a marker
    UXAttributedString* esc = UXMarkdown.parse((u8*)"a \\* b");
    eq("escaped asterisk literal", esc.stringValue(), (u8*)"a * b");
    check("literal star not italic", italAt(esc, (i32)2), (i32)0);

    // runs: "hello world" with world bold coalesces to 2 runs
    check("bold example has 2 runs", b.runCount(), (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXMarkdown — bold/italic/code stripping + attribution, mixed, escape.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
