// test_gtk_values.xc — GTK's native controls follow their models (the gtk-values gate).  Once a
// native control exists, the app's changes to its model show in it on the next display: a check
// box, a slider, a stepper, a progress bar and a popup.  GTK emits its change signals for a
// programmatic change too; none of these comes back as the user's, so no action fires.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXStepper.xc"
#import "UXProgressBar.xc"
#import "UXProgress.xc"
#import "UXPopUpButton.xc"
#import "UXGeometry.xc"
extern i32 ux_gtk_test_native_value(i32 handle, i32 node);
void ux_gtk_wait_allocated(i32 handle);

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
i32 gFired;
class Target : Object
    {
    void picked(UXControl* sender)
        {
        gFired = gFired + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;
    UXWindow* win = new UXWindow();
    UXView* root = new UXView();
    win.open((u8*)"values", UXGeom.make((i16)60, (i16)60, (i16)320, (i16)260), root);
    app.addWindow(win);
    Target* t = new Target();
    UXCheckbox* cb = new UXCheckbox();
    cb.setTitle((u8*)"Wrap");
    cb.setAction(&t.picked);
    root.addSubview(cb, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)28));
    UXSlider* sl = new UXSlider();
    sl.setRange((i32)0, (i32)100);
    sl.setValue((i32)20);
    sl.setAction(&t.picked);
    root.addSubview(sl, UXGeom.make((i16)20, (i16)60, (i16)240, (i16)30));
    UXStepper* st = new UXStepper();
    st.setAction(&t.picked);
    root.addSubview(st, UXGeom.make((i16)20, (i16)100, (i16)120, (i16)32));
    UXProgress* prog = new UXProgress();
    prog.setTotal((i32)4);
    prog.setCompleted((i32)1);
    UXProgressBar* pg = new UXProgressBar();
    pg.setProgress(prog);
    root.addSubview(pg, UXGeom.make((i16)20, (i16)145, (i16)240, (i16)20));
    UXPopUpButton* pop = new UXPopUpButton();
    pop.addItem((u8*)"One", (i32)1);
    pop.addItem((u8*)"Two", (i32)2);
    pop.addItem((u8*)"Three", (i32)3);
    pop.selectItem((i32)0);
    pop.setAction(&t.picked);
    root.addSubview(pop, UXGeom.make((i16)20, (i16)180, (i16)200, (i16)32));
    win.displayAll();
    ux_gtk_wait_allocated(win.handle);
    i32 h = win.handle;
    gFired = (i32)0;

    ck((u8*)"the controls start at their models' values", ux_gtk_test_native_value(h, (i32)cb.index) == (i32)0 &&
        ux_gtk_test_native_value(h, (i32)sl.index) == (i32)20 && ux_gtk_test_native_value(h, (i32)pg.index) == (i32)250 &&
        ux_gtk_test_native_value(h, (i32)pop.index) == (i32)0);
    cb.setChecked(true);
    sl.setValue((i32)70);
    st.setValue((i32)4);
    prog.setCompleted((i32)3);
    pop.selectItem((i32)2);
    win.displayAll();
    ck((u8*)"the app checking the box checks the GtkCheckButton", ux_gtk_test_native_value(h, (i32)cb.index) == (i32)1);
    ck((u8*)"the app moving the slider moves the GtkScale", ux_gtk_test_native_value(h, (i32)sl.index) == (i32)70);
    ck((u8*)"the app setting the stepper sets the GtkSpinButton", ux_gtk_test_native_value(h, (i32)st.index) == (i32)4);
    ck((u8*)"progress advancing advances the GtkProgressBar", ux_gtk_test_native_value(h, (i32)pg.index) == (i32)750);
    ck((u8*)"the app selecting an item selects it in the GtkDropDown", ux_gtk_test_native_value(h, (i32)pop.index) == (i32)2);
    ck((u8*)"...and none of those comes back as the user's: no action fired", gFired == (i32)0);
    ck((u8*)"...and the models are as the app left them", cb.isChecked() && sl.nativeValue() == (i32)70 && st.nativeValue() == (i32)4 && pop.nativeSelected() == (i32)2);
    Stdio.printf(gFails == (i32)0 ? "PASS: GTK's native controls follow their models, without firing\n" : "FAIL: %d\n", gFails);
    }
