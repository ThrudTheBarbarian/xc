#import "Stdio.xc"
#import "Assert.xc"
// The framework comes in as a BINARY module: UXNib, UXControl and the protocol
// are the LIBRARY's, so its loader state is the one the app sees. Importing the
// stub as source here would give the app a private second copy of UXNib's
// statics and hide whether the library ever registered at all.
#import <LibPanel>

// A designable class defined in the APP. Neither module knows the other's
// designables; a nib names a class and the loader asks each factory in turn.
class AppLabel : Object
    {
    u16 tag;
    void init(void)
        {
        tag = (u16)0;
        }
    }

    u16 appFired;

class AppPanel : Object
    {
    outlet AppLabel* heading;
    void init(void)
        {
        }
    void onAppTap(Object* sender) : action
        {
        appFired = appFired + (u16)1;
        }
    }

    void
    main(void)
    {
    Assert.reset();
    appFired = (u16)0;
    LibProbe.reset();

    // T1 — BUG 066's guard, and the only expected failure here. Nothing in this
    // program calls registerObjectFactory: the app's constructor runs (the back
    // end's __xtc_run_modinit, called by the crt) and the LIBRARY's does not,
    // because the Mach-O writer emits no __mod_init_func for dyld to run.
    Assert.isEqual(UXNib.factoryCount(), (u16)2); // T1

    // The app's own class, made BY NAME through the erased factory — this is
    // the whole per-module-factory mechanism, on the module whose constructor
    // does run.
    UXDesignable* ap = UXNib.make((u8*)"AppPanel");
    Assert.isTrue(ap != (UXDesignable*)0); // T2

    // The library's designable is constructed directly rather than by name,
    // so that 066 costs this gate exactly ONE assertion instead of hiding the
    // cross-module synthesis behind a null.
    UXDesignable* lp = (UXDesignable*)new LibPanel();
    Assert.isTrue(lp != (UXDesignable*)0); // T3

    // Outlets bind by name in both modules, through the protocol.
    AppLabel* al = new AppLabel();
    al.tag = (u16)9;
    LibLabel* ll = new LibLabel();
    ll.tag = (u16)4;
    Assert.isTrue(ap.setOutlet((u8*)"heading", (Object*)al)); // T4
    Assert.isTrue(lp.setOutlet((u8*)"caption", (Object*)ll)); // T5

    // A name belonging to the OTHER module's class binds nothing.
    Assert.isFalse(lp.setOutlet((u8*)"heading", (Object*)al)); // T6
    Assert.isFalse(ap.setOutlet((u8*)"caption", (Object*)ll)); // T7

    // Actions wire and fire, in both modules.
    UXControl* c1 = new UXControl();
    UXControl* c2 = new UXControl();
    Assert.isTrue(ap.wireAction((u8*)"onAppTap", c1)); // T8
    Assert.isTrue(lp.wireAction((u8*)"onLibTap", c2)); // T9
    c1.fire((Object*)ap);
    c2.fire((Object*)lp);
    Assert.isEqual(appFired, (u16)1);         // T10
    Assert.isEqual(LibProbe.fired(), (u16)1); // T11

    // An unknown class name yields nothing.
    Assert.isTrue(UXNib.make((u8*)"NoSuchPanel") == (UXDesignable*)0); // T12

    Assert.summary();
    }
