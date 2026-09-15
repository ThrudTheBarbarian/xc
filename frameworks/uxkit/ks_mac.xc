// ks_mac.xc — the kitchen-sink on the AppKit backend (native widgets).  make mac.
#import "UXAppKitDriver.xc"
#import "ks_app.xc"
void main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true); // GUI mode: [NSApp run] owns the loop
    KitchenSink* ks = new KitchenSink();
    UXApplication* app = new UXApplication();
    d.attachApp(app); // forward native events into the app
    app.setDelegate(ks);
    app.run();
    Stdio.printf("kitchen sink exited\n");
    }
