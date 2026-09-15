// test_tabview.xc — UXTabView model: tabs, selection, content identity (no window needed).
#import <Stdio.xc>
#import "UXTabView.xc"
#import "UXView.xc"

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
    UXTabView* tv = new UXTabView();
    UXView* general = new UXView();
    UXView* advanced = new UXView();
    UXView* about = new UXView();
    tv.addTab((u8*)"General", general);
    tv.addTab((u8*)"Advanced", advanced);
    tv.addTab((u8*)"About", about);

    check("three tabs", tv.count(), (i32)3);
    check("first selected by default", tv.selectedIndex(), (i32)0);
    eq("selected label", tv.selectedLabel(), (u8*)"General");
    check("selected content is general", tv.selectedContent() == general ? (i32)1 : (i32)0, (i32)1);
    check("tab 0 visible", tv.isTabVisible((i32)0) ? (i32)1 : (i32)0, (i32)1);
    check("tab 1 not visible", tv.isTabVisible((i32)1) ? (i32)1 : (i32)0, (i32)0);

    tv.selectTab((i32)1);
    check("selected 1", tv.selectedIndex(), (i32)1);
    eq("selected label advanced", tv.selectedLabel(), (u8*)"Advanced");
    check("selected content is advanced", tv.selectedContent() == advanced ? (i32)1 : (i32)0, (i32)1);
    check("tab 0 now hidden", tv.isTabVisible((i32)0) ? (i32)1 : (i32)0, (i32)0);
    check("tab 1 now visible", tv.isTabVisible((i32)1) ? (i32)1 : (i32)0, (i32)1);

    // out-of-range select is ignored
    tv.selectTab((i32)99);
    check("out-of-range ignored (still 1)", tv.selectedIndex(), (i32)1);
    tv.selectTab((i32)-1);
    check("negative ignored (still 1)", tv.selectedIndex(), (i32)1);

    tv.selectTab((i32)2);
    eq("selected label about", tv.selectedLabel(), (u8*)"About");
    check("content is about", tv.selectedContent() == about ? (i32)1 : (i32)0, (i32)1);
    eq("labelAt(0)", tv.labelAt((i32)0), (u8*)"General");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTabView — tabs, selection, labels, content identity, bounds.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
