// showcase_alert_gtk.xc — the Linux alert portrait: the driver's REAL
// GtkAlertDialog, photographed mid-modal.  ux_gtk_alert_auto(ms, 1) arms the
// shim's timeout to render the OPEN dialog window into the shot surface and
// then cancel the choose, so runModal returns and the booth dumps the PPM.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

void ux_gtk_alert_auto(i32 ms, i32 shot);
i32 ux_gtk_dump_ppm(u8* path);

void main(void)
    {
    gDriver = new UXGtkDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no GTK display\n");
        return;
        }

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"backdrop", UXGeom.make(0, 60, 300, 200), content);
    win.displayAll();

    UXAlert* alert = new UXAlert();
    alert.icon = (i32)3;
    alert.addLine((u8*)"Save changes to Rocks.doc?");
    alert.addLine((u8*)"Your edits will be lost otherwise.");
    alert.addButton((u8*)"Save");
    alert.addButton((u8*)"Cancel");
    ux_gtk_alert_auto((i32)500, (i32)1); // photograph, then cancel
    alert.runModal();

    if (ux_gtk_dump_ppm((u8*)"/tmp/ux-alert-gtk.ppm") != (i32)0)
        {
        Stdio.printf("PASS: alert shot\n");
        }
    else
        {
        Stdio.printf("FAIL: no dump\n");
        }
    }
