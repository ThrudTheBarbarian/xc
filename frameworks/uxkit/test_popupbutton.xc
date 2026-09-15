// test_popupbutton.xc — UXPopUpButton item model + selection by index/tag/title.
#import <Stdio.xc>
#import "UXPopUpButton.xc"

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
    UXPopUpButton* p = new UXPopUpButton();
    check("empty count", p.count(), (i32)0);
    check("empty selection -1", p.selectedIndex(), (i32)-1);

    p.addItem((u8*)"Small", (i32)10);
    check("first add selects it", p.selectedIndex(), (i32)0);
    p.addItem((u8*)"Medium", (i32)20);
    p.addItem((u8*)"Large", (i32)30);
    check("three items", p.count(), (i32)3);
    check("still first selected", p.selectedIndex(), (i32)0);
    eq("selected title", p.selectedTitle(), (u8*)"Small");
    check("selected tag", p.selectedTag(), (i32)10);

    // select by index
    p.selectItem((i32)2);
    eq("selected Large", p.selectedTitle(), (u8*)"Large");
    check("Large tag", p.selectedTag(), (i32)30);

    // select by tag
    p.selectByTag((i32)20);
    eq("by tag -> Medium", p.selectedTitle(), (u8*)"Medium");
    check("Medium index", p.selectedIndex(), (i32)1);

    // select by title
    p.selectByTitle((u8*)"Small");
    check("by title -> Small index 0", p.selectedIndex(), (i32)0);

    // out-of-range / unknown are ignored
    p.selectItem((i32)99);
    check("bad index ignored", p.selectedIndex(), (i32)0);
    p.selectByTag((i32)999);
    check("unknown tag ignored", p.selectedIndex(), (i32)0);
    p.selectByTitle((u8*)"Nope");
    check("unknown title ignored", p.selectedIndex(), (i32)0);

    // removeAll resets
    p.removeAllItems();
    check("cleared count", p.count(), (i32)0);
    check("cleared selection -1", p.selectedIndex(), (i32)-1);
    eq("cleared title empty", p.selectedTitle(), (u8*)"");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXPopUpButton — items, default select, by index/tag/title, ignore-bad, clear.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
