// ks_win32.xc — the kitchen-sink on the Win32 backend, under Wine.  make win32.
#import "UXWin32Driver.xc"
#import "ks_app.xc"
void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    KitchenSink* ks = new KitchenSink();
    UXApplication* app = new UXApplication();
    app.setDelegate(ks);
    app.run();
    }
