// showcase_alert_ios.xc — the iOS alert portrait: the driver's REAL
// UIAlertController, photographed mid-modal.  ux_ios_alert_auto(ms, 1) arms
// the shim to render the presented card into the readback buffer and then
// dismiss, so runModal returns and the booth dumps the PPM (sim /tmp IS
// host /tmp).
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern i32 ux_ios_dump_ppm(u8* path);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_alert_auto(i32 ms, i32 shot);

void shoot(void)
    {
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_ios_quit((i32)1);
        return;
        }
    UXAlert* alert = new UXAlert();
    alert.icon = (i32)3;
    alert.addLine((u8*)"Save changes to Rocks.doc?");
    alert.addLine((u8*)"Your edits will be lost otherwise.");
    alert.addButton((u8*)"Save");
    alert.addButton((u8*)"Cancel");
    ux_ios_alert_auto((i32)500, (i32)1); // photograph, then dismiss
    alert.runModal();
    if (ux_ios_dump_ppm((u8*)"/tmp/ux-alert-ios.ppm") != (i32)0)
        {
        Stdio.printf("PASS: alert shot\n");
        ux_ios_quit((i32)0);
        }
    else
        {
        Stdio.printf("FAIL: no dump\n");
        ux_ios_quit((i32)1);
        }
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&shoot);
    ux_ios_shell_run();
    }
