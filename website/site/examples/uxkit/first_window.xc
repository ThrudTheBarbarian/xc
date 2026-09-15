// first_window.xc — the smallest complete UXKit program.
//
// A window, a label, a button, and a method that runs when it is pressed.
// Nothing here names a platform except the one line that picks a driver.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

class Counter : Object <UXApplicationDelegate>
{
    UXLabel* readout;
    i32      presses;

    void init(void) { presses = 0; readout = (UXLabel*)0; }

    // A callback: &self.onPress carries the receiver AND the code.
    void onPress(UXControl* sender) {
        presses = presses + 1;
        readout.setText(presses == 1 ? (u8*)"pressed once"
                                          : (u8*)"pressed again");
        
    }

    i32 applicationDidStart(UXApplication* app) {
        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"First window", UXGeom.make(80, 80, 240, 120), content);

        readout = new UXLabel();
        readout.setText((u8*)"not pressed yet");
        content.addSubview(readout, UXGeom.make(16, 16, 200, 18));

        UXButton* b = new UXButton();
        b.setTitle((u8*)"Press me");
        b.setAction(&self.onPress);
        content.addSubview(b, UXGeom.make(16, 48, 96, 24));

        win.tree.finalise();
        win.displayAll();
        return 0;
    }
}

void main(void) {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    UXApplication* app = new UXApplication();
    Counter* c = new Counter();
    app.setDelegate(c);
    app.run();
}
