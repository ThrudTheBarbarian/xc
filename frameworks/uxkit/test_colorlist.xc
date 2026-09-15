// test_colorlist.xc — UXColorList named colours + default semantic theme.
#import <Stdio.xc>
#import "UXColorList.xc"
#import "UXColor.xc"

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

    // custom list
    UXColorList* list = new UXColorList();
    list.set((u8*)"brand", UXColor.rgb((i32)10, (i32)20, (i32)30));
    check("has brand", list.has((u8*)"brand") ? (i32)1 : (i32)0, (i32)1);
    check("brand r", list.color((u8*)"brand").r, (i32)10);
    check("brand b", list.color((u8*)"brand").b, (i32)30);
    check("missing name absent", list.has((u8*)"nope") ? (i32)1 : (i32)0, (i32)0);
    check("missing returns fallback black", list.color((u8*)"nope").r, (i32)0);
    check("colorOr uses provided fallback", list.colorOr((u8*)"nope", UXColor.white()).r, (i32)255);

    // override in place
    list.set((u8*)"brand", UXColor.rgb((i32)200, (i32)0, (i32)0));
    check("override r", list.color((u8*)"brand").r, (i32)200);
    check("override didn't add a duplicate", list.count(), (i32)1);

    // default theme has the standard semantic colours
    UXColorList* theme = UXColorList.defaultTheme();
    check("theme has windowBackground", theme.has((u8*)"windowBackground") ? (i32)1 : (i32)0, (i32)1);
    check("theme has accent", theme.has((u8*)"accent") ? (i32)1 : (i32)0, (i32)1);
    check("text is black", theme.color((u8*)"text").r, (i32)0);
    check("selectionFill is the pen-250 blue (r)", theme.color((u8*)"selectionFill").r, (i32)179);
    check("selectionFill blue (b)", theme.color((u8*)"selectionFill").b, (i32)255);
    check("controlFace grey", theme.color((u8*)"controlFace").r, (i32)192);

    // default theme is a shared singleton
    check("theme is shared", UXColorList.defaultTheme() == theme ? (i32)1 : (i32)0, (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXColorList — named colours, fallback, override, default semantic theme.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
