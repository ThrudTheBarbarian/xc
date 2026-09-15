// controls.xc — the control set, and the one wiring pattern behind all of it.
//
// Every control reports the same way: a callback carrying receiver and code.
// The handler receives the SENDER, so one method can serve several controls.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXStepper.xc"
#import "UXPopUpButton.xc"
#import "UXSegmentedControl.xc"
#import "UXProgressBar.xc"
#import "UXProgress.xc"
#import "UXGeometry.xc"

class Panel : Object <UXApplicationDelegate>
{
    UXLabel*       readout;
    UXCheckbox*    agree;
    UXRadioGroup*  size;
    UXSlider*      level;
    UXProgressBar* bar;
    UXProgress*    work;

    void init(void) { }

    // One handler, several senders: identity tells them apart.
    void onAny(UXControl* sender) {
        if ((UXControl*)agree == sender) {
            readout.setText(agree.isChecked() ? (u8*)"agreed" : (u8*)"not agreed");
        } else {
            readout.setText((u8*)"changed");
        }
    }

    void onLevel(UXControl* sender) {
        // The BAR shows a MODEL: move the model, the bar follows.
        work.setCompleted(level.value);
        bar.setNeedsDisplay();
    }

    i32 applicationDidStart(UXApplication* app) {
        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Controls", UXGeom.make(60, 60, 300, 260), content);

        readout = new UXLabel();
        readout.setText((u8*)"nothing yet");
        content.addSubview(readout, UXGeom.make(12, 10, 270, 18));

        UXButton* go = new UXButton();
        go.setTitle((u8*)"Go");
        go.setAction(&self.onAny);
        content.addSubview(go, UXGeom.make(12, 36, 70, 24));

        agree = new UXCheckbox();
        agree.setTitle((u8*)"Agree");
        agree.setAction(&self.onAny);
        content.addSubview(agree, UXGeom.make(12, 68, 120, 20));

        // A radio GROUP owns the exclusivity; the buttons just belong to it.
        size = new UXRadioGroup();
        UXRadioButton* small = new UXRadioButton(); small.setTitle((u8*)"Small");
        UXRadioButton* large = new UXRadioButton(); large.setTitle((u8*)"Large");
        content.addSubview(small, UXGeom.make(12, 92, 100, 20));
        content.addSubview(large, UXGeom.make(12, 114, 100, 20));
        size.add(small); size.add(large);
        size.select(small);

        level = new UXSlider();
        level.setRange(0, 100);
        level.setValue(40);
        level.setAction(&self.onLevel);
        content.addSubview(level, UXGeom.make(12, 142, 180, 22));

        work = new UXProgress();
        work.setTotal(100);
        work.setCompleted(40);
        bar = new UXProgressBar();
        bar.setProgress(work);
        content.addSubview(bar, UXGeom.make(12, 172, 180, 16));

        UXPopUpButton* pop = new UXPopUpButton();
        pop.addItem((u8*)"One", 1);
        pop.addItem((u8*)"Two", 2);
        pop.setAction(&self.onAny);
        content.addSubview(pop, UXGeom.make(12, 198, 120, 22));

        win.tree.finalise();
        win.displayAll();
        return 0;
    }
}

void main(void) {
    gDriver = new UXAppKitDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Panel());
    app.run();
}
