// hello-ux.xc — a window with a label and a button, on every platform UXKit
// runs on. The source names no platform: the Makefile beside it builds the
// same file for macOS, Linux, Windows, the web, iOS and Android.
#import <Stdio.xc>
#use <UXKit>

class HelloUX : Object <UXApplicationDelegate>
{
    UXLabel* greeting;
    i32      presses;

    void init(void) { presses = 0; greeting = (UXLabel*)0; }

    // Runs when the button is pressed: &self.onPress carries the receiver
    // and the code.
    void onPress(UXControl* sender) {
        presses = presses + 1;
        greeting.setText(presses == 1 ? (u8*)"Hello again!" : (u8*)"Hello, still here!");
        Stdio.printf("pressed %d\n", presses);
    }

    i32 applicationDidStart(UXApplication* app) {
        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Hello UX", UXGeom.make(80, 80, 260, 120), content);

        greeting = new UXLabel();
        greeting.setText((u8*)"Hello UX!");
        content.addSubview(greeting, UXGeom.make(16, 16, 220, 18));

        UXButton* b = new UXButton();
        b.setTitle((u8*)"Press me");
        b.setAction(&self.onPress);
        content.addSubview(b, UXGeom.make(16, 48, 96, 24));

        win.tree.finalise();
        win.displayAll();
        Stdio.printf("Hello UX! on %s\n", UXPlatform.displayName());
        return 0;
    }
}

void main(void) {
    UXApplication* app = new UXApplication();
    app.setDelegate(new HelloUX());
    app.run();
}
