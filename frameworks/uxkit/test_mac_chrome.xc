// test_mac_chrome.xc — window chrome on AppKit: subtitle and the modified dot.
//
// UXWindow has had setSubtitle/setModified since the GEM backend (the AES draws them in the title
// bar), and the AppKit driver implemented all four chrome calls as empty bodies — so an app that
// marked a document dirty got a dot on GEM and nothing on macOS.  NSWindow has both: `subtitle`
// (macOS 11+) and `documentEdited`.  Asserted by reading the WINDOW back, not by the call returning.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"

i32 gFails;
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
    UXAppKitDriver* drv = new UXAppKitDriver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXWindow* win = new UXWindow();
    UXView* content = new UXView();
    win.open((u8*)"Chrome", UXGeom.make((i16)40, (i16)40, (i16)320, (i16)200), content);

    checkTrue("a fresh window is not modified", ux_ak_window_modified(win.handle) == (i32)0);
    win.setModified(true);
    checkTrue("setModified marks the NSWindow edited", ux_ak_window_modified(win.handle) == (i32)1);
    win.setModified(false);
    checkTrue("...and clears it again", ux_ak_window_modified(win.handle) == (i32)0);

    // The subtitle is macOS 11+; where it exists it must round-trip, and where it does not the call
    // must be harmless rather than a crash — so this asserts "either it took, or the OS has none".
    u8 got[128];
    win.setSubtitle((u8*)"3 items");
    i32 have = ux_ak_window_subtitle(win.handle, &got[(i32)0], (i32)128);
    if (have != (i32)0)
        {
        checkTrue("the subtitle reached the NSWindow",
                  got[(i32)0] == (u8)'3' && got[(i32)1] == (u8)' ');
        }
    else
        {
        Stdio.printf("  ok   subtitle unsupported on this macOS — call was harmless\n");
        }

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: AppKit window chrome\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
