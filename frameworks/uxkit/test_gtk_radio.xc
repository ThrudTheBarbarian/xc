// test_gtk_radio.xc — radio buttons on GTK are native: GtkCheckButtons in a group, which GTK draws
// round.  Checked through GTK's own objects: each radio is a check button in a group (a lone one too,
// through a hidden partner); switching one on the way a click does selects it in the model, clears
// the others (in the model and on screen) and fires its action; a selection made in code reaches the
// screen.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern i32 ux_gtk_test_toggle(i32 handle, i32 node);
extern void ux_gtk_test_activate_toggle(i32 handle, i32 node);
i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
i32 gFired;
class Ctl : Object
    {
    void onPick(UXControl* c) { gFired = gFired + (i32)1; }
    }
void main(void)
    {
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }
    UXApplication* app = new UXApplication();
    gApp = app;
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Radios", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)160), content);
    app.addWindow(win);
    Ctl* c = new Ctl();
    UXRadioGroup* grp = new UXRadioGroup();
    UXRadioButton* r0 = new UXRadioButton();
    UXRadioButton* r1 = new UXRadioButton();
    UXRadioButton* r2 = new UXRadioButton();
    UXRadioButton* lone = new UXRadioButton();
    r0.setTitle((u8*)"Small");
    r1.setTitle((u8*)"Medium");
    r2.setTitle((u8*)"Large");
    lone.setTitle((u8*)"On its own");
    content.addSubview(r0, UXGeom.make((i16)10, (i16)10, (i16)180, (i16)24));
    content.addSubview(r1, UXGeom.make((i16)10, (i16)40, (i16)180, (i16)24));
    content.addSubview(r2, UXGeom.make((i16)10, (i16)70, (i16)180, (i16)24));
    content.addSubview(lone, UXGeom.make((i16)10, (i16)110, (i16)180, (i16)24));
    grp.add(r0);
    grp.add(r1);
    grp.add(r2);
    r0.setAction(&c.onPick);
    r1.setAction(&c.onPick);
    r2.setAction(&c.onPick);
    grp.select(r0);
    win.displayAll();
    i32 h = win.handle;
    ck(ux_gtk_test_toggle(h, (i32)r0.index) == (i32)7, "Small is a native check button in a group, on", ux_gtk_test_toggle(h, (i32)r0.index));
    ck(ux_gtk_test_toggle(h, (i32)r1.index) == (i32)6 && ux_gtk_test_toggle(h, (i32)r2.index) == (i32)6, "Medium and Large are too, off", ux_gtk_test_toggle(h, (i32)r1.index));
    ck((ux_gtk_test_toggle(h, (i32)lone.index) & (i32)6) == (i32)6, "a radio on its own is in a group as well (so it draws round)", ux_gtk_test_toggle(h, (i32)lone.index));
    ux_gtk_test_activate_toggle(h, (i32)r2.index); // as a click does
    ck(r2.isSelected() && !r0.isSelected() && !r1.isSelected(), "switching Large on selects it in the model and clears the others", (i32)0);
    ck(gFired == (i32)1, "and fires its action once", gFired);
    ck(ux_gtk_test_toggle(h, (i32)r0.index) == (i32)6 && ux_gtk_test_toggle(h, (i32)r2.index) == (i32)7, "on screen: Large on, Small off", ux_gtk_test_toggle(h, (i32)r0.index) * (i32)10 + ux_gtk_test_toggle(h, (i32)r2.index));
    grp.select(r1);
    win.displayAll();
    ck(ux_gtk_test_toggle(h, (i32)r1.index) == (i32)7 && ux_gtk_test_toggle(h, (i32)r2.index) == (i32)6, "a selection made in code reaches the screen", ux_gtk_test_toggle(h, (i32)r1.index));
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: GTK radio buttons are native, grouped, and follow the model both ways\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
