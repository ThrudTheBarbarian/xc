// test_font.xc — UXFont descriptor derivations + description.
#import <Stdio.xc>
#import "UXFont.xc"

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

void main(void)
    {
    gFails = (i32)0;
    UXFont* base = UXFont.make((u8*)"Helvetica", (i16)12);
    check("size", (i32)base.size, (i32)12);
    check("not bold", base.isBold() ? (i32)1 : (i32)0, (i32)0);
    eq("description plain", base.description(), (u8*)"Helvetica 12");

    // immutable derivations don't mutate the original
    UXFont* big = base.withSize((i16)18);
    check("derived size", (i32)big.size, (i32)18);
    check("original size untouched", (i32)base.size, (i32)12);

    UXFont* bi = base.bolded().italicized();
    check("bold", bi.isBold() ? (i32)1 : (i32)0, (i32)1);
    check("italic", bi.isItalic() ? (i32)1 : (i32)0, (i32)1);
    check("original still plain", base.isBold() ? (i32)1 : (i32)0, (i32)0);
    eq("description bold italic", bi.description(), (u8*)"Helvetica 12 Bold Italic");

    // toggling
    check("toggle bold on", base.togglingBold().isBold() ? (i32)1 : (i32)0, (i32)1);
    check("toggle bold twice off", base.togglingBold().togglingBold().isBold() ? (i32)1 : (i32)0, (i32)0);

    // scaling
    check("scaled 150%", (i32)base.scaledBy((i16)150).size, (i32)18);

    // family change + equality
    UXFont* times = base.withFamily((u8*)"Times");
    eq("family swapped", times.description(), (u8*)"Times 12");
    check("equal to identical", base.isEqualTo(UXFont.make((u8*)"Helvetica", (i16)12)) ? (i32)1 : (i32)0, (i32)1);
    check("not equal across family", base.isEqualTo(times) ? (i32)1 : (i32)0, (i32)0);
    check("not equal across trait", base.isEqualTo(base.bolded()) ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXFont — derivations, toggles, scaling, description, equality.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
