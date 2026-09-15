// showcase_modal_mac.xc — the macOS modal portraits: a real NSAlert (built by
// the same shim code alertRun uses, laid out but never run) and a real
// NSToolbar (a window's theme frame — titlebar + toolbar chrome — cached
// headless).  Both dump as PPMs for capture.sh to convert and crop.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"

extern i32 ux_ak_alert_dump(i32 icon, u8* lines, u8* buttons, u8* path);
extern i32 ux_ak_toolbar_dump(i32 w, i32 h, u8* path);

void main(void)
    {
    ux_ak_set_capture((i32)1); // native art, no window shown
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }
    i32 ok = (i32)1;
    if (ux_ak_alert_dump((i32)3,
                         (u8*)"Save changes to Rocks.doc?|Your edits will be lost otherwise.",
                         (u8*)"Save|Cancel",
                         (u8*)"/tmp/ux-alert-mac.ppm") == (i32)0)
        {
        Stdio.printf("FAIL: alert dump\n");
        ok = (i32)0;
        }
    if (ux_ak_toolbar_dump((i32)440, (i32)120,
                           (u8*)"/tmp/ux-toolbar-mac.ppm") == (i32)0)
        {
        Stdio.printf("FAIL: toolbar dump\n");
        ok = (i32)0;
        }
    if (ok != (i32)0)
        {
        Stdio.printf("PASS: modal shots\n");
        }
    }
