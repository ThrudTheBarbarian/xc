// showcase_alert_android.xc — the Android alert portrait: the driver's REAL
// AlertDialog, photographed mid-modal.  ux_and_alert_auto(ms, 1) arms the
// shim's Handler timer to render the SHOWN dialog's decor into the shot
// bitmap and then cancel it, so runModal returns and the booth dumps the PPM
// into the app's files dir (adb run-as pulls it).
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_alert_auto(i32 ms, i32 shot);
extern i32 ux_and_dump_ppm(u8* name);

void shoot(void)
    {
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_and_quit((i32)1);
        return;
        }
    UXAlert* alert = new UXAlert();
    alert.icon = (i32)3;
    alert.addLine((u8*)"Save changes to Rocks.doc?");
    alert.addLine((u8*)"Your edits will be lost otherwise.");
    alert.addButton((u8*)"Save");
    alert.addButton((u8*)"Cancel");
    ux_and_alert_auto((i32)600, (i32)1); // photograph, then cancel
    alert.runModal();
    if (ux_and_dump_ppm((u8*)"ux-alert.ppm") != (i32)0)
        {
        Stdio.printf("PASS: alert shot\n");
        ux_and_quit((i32)0);
        }
    else
        {
        Stdio.printf("FAIL: no dump\n");
        ux_and_quit((i32)1);
        }
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&shoot);
    ux_and_shell_run();
    }
