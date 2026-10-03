// test_web_color.xc — the web's colour picker is the browser's own <input type=color>, in a REAL
// browser's worker run loop (the web-color gate).  The page's dialog holds the control, seeded with
// the colour; tools/web_color.html plays the user: it checks the seed, sets a colour in the control
// and presses OK, then cancels a second dialog.
#import <Stdio.xc>
#import "UXWebDriver.xc"

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
bool sameBytes(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

void main(void)
    {
    gFails = (i32)0;
    UXWebDriver* d = new UXWebDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    ck((u8*)"in the worker, the web has a native colour picker", d.hasNativeColorPicker());
    i32 r = (i32)0;
    i32 g = (i32)0;
    i32 b = (i32)0;
    i32 ok = d.pickColor((i32)0, (i32)0, (i32)255, &r, &g, &b);
    Stdio.printf("  (colour: %d %d %d)\n", r, g, b);
    ck((u8*)"the colour set in the browser's control is the one returned", ok == (i32)1 && r == (i32)200 && g == (i32)100 && b == (i32)50);
    ck((u8*)"a cancelled colour dialog returns nothing", d.pickColor((i32)1, (i32)2, (i32)3, &r, &g, &b) == (i32)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: the web's colour picker is the browser's <input type=color> -- what the user sets is what the app gets\n" : "FAIL: %d\n", gFails);
    }
