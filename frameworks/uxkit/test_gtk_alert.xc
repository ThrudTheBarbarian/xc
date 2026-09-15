// test_gtk_alert.xc — modal alerts on the GTK backend (the gtk-alert gate).
//
// alertRun is now a real GtkAlertDialog behind a nested GMainLoop.  Headless
// determinism: ux_gtk_alert_auto arms a timeout that CANCELS the async choose
// once the dialog is up, which the shim reports as the LAST button — the
// cancel convention.  That proves the nested loop parks and resumes, and the
// cancel mapping, without a human (the affirmative path needs a click; the
// portrait rig photographs that same dialog).
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

void ux_gtk_alert_auto(i32 ms, i32 shot);

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
    win.open((u8*)"alert host", UXGeom.make(0, 60, 300, 200), content);
    win.displayAll();

    UXAlert* two = new UXAlert();
    two.addLine((u8*)"Discard changes?");
    two.addButton((u8*)"Keep");
    two.addButton((u8*)"Discard");
    ux_gtk_alert_auto((i32)200, (i32)0);
    i32 a = two.runModal();
    Stdio.printf("2-button auto-cancel -> %d (expect 2)\n", a);

    UXAlert* three = new UXAlert();
    three.icon = (i32)3;
    three.addLine((u8*)"Save changes?");
    three.addButton((u8*)"Save");
    three.addButton((u8*)"Discard");
    three.addButton((u8*)"Cancel");
    ux_gtk_alert_auto((i32)200, (i32)0);
    i32 b = three.runModal();
    Stdio.printf("3-button auto-cancel -> %d (expect 3)\n", b);

    if (a == (i32)2 && b == (i32)3)
        {
        Stdio.printf("PASS: the nested-loop alert parks, resumes, and maps cancel\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
