// ks_a9.xc — the kitchen-sink on the GEM backend (arm9), under qemu.  make a9.
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "ks_app.xc"
void main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    KitchenSink* ks = new KitchenSink();
    UXApplication* app = new UXApplication();
    app.setDelegate(ks);
    app.run();
    }
