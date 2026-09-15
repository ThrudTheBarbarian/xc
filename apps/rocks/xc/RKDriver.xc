// RKDriver.xc — the ONE platform-aware file in Rocks.
//
// UXKit's whole claim is that a client differs per platform in exactly one
// place: the driver it constructs.  This file is that place, so nothing else
// in Rocks ever names a backend and `port Rocks to Windows` is not a porting
// job at all — it is choosing a different branch here.
//
// The imports have to be conditional too, not just the construction: a driver's
// header pulls in its platform's system interfaces (UXWin32.h.xc names
// comdlg32/ole32/comctl32, the GEM one names the AES), and those do not exist
// off that platform.  So the #ifdef wraps the import as well as the `new`.
//
// The mapping is target -> platform, which is how every UXKit gate already
// works:
//     arm64   macOS      AppKit      (the development host)
//     x86_64  Linux      GTK4
//     win64   Windows    Win32
//     arm9    Atari      GEM/AES     (the board; the editor is desktop-first,
//                                     but the toolkit builds there so this does
//                                     too — see UXNB-V2 §7 on xclipo)
//
// WIN64 IS CHECKED FIRST, AND THE BRANCHES NEST.  A win64 build defines BOTH
// ARCH_win64 and ARCH_x86_64 — Windows is x86_64, which is why its include
// search path contains the x86_64 lib dir — so parallel #ifdefs compile the
// GTK driver into the Windows binary and the link fails on ux_gtk_fill, a
// long way from the cause.  Nesting makes the platforms mutually exclusive,
// which is what they actually are.
#ifdef ARCH_arm64
#import "UXAppKitDriver.xc"
#endif
#ifdef ARCH_arm9
#import "UXGemDriver.xc"
#endif
#ifdef ARCH_win64
#import "UXWin32Driver.xc"
#else
#ifdef ARCH_x86_64
#import "UXGtkDriver.xc"
#endif
#endif
#import "UXApplication.xc"

class RKDriver : Object
    {
    // Construct the platform's driver, install it as gDriver, and put it in
    // whatever mode a GUI app needs.  Returns false when there is no display
    // to talk to — a headless CI box, an unset DISPLAY — which callers should
    // treat as a skip rather than a failure.
    static bool start(UXApplication* app)
        {
#ifdef ARCH_arm64
        UXAppKitDriver* d = new UXAppKitDriver();
        gDriver = d;
        d.setInteractive(true); // GUI: [NSApp run] owns the loop
        d.attachApp(app);       // native events into this app
        return true;
#endif
#ifdef ARCH_arm9
        UXGemDriver* gd = new UXGemDriver();
        gDriver = gd;
        i32 gw = (i32)0;
        i32 gh = (i32)0;
        return gd.boot(&gw, &gh);
#endif
#ifdef ARCH_win64
        UXWin32Driver* wd = new UXWin32Driver();
        gDriver = wd;
        i32 ww = (i32)0;
        i32 wh = (i32)0;
        return wd.boot(&ww, &wh);
#else
#ifdef ARCH_x86_64
        UXGtkDriver* xd = new UXGtkDriver();
        gDriver = xd;
        i32 xw = (i32)0;
        i32 xh = (i32)0;
        return xd.boot(&xw, &xh);
#endif
#endif
        }

    // What to call this build, for the window title and the about box.
    static u8* platformName(void)
        {
#ifdef ARCH_arm64
        return (u8*)"macOS";
#endif
#ifdef ARCH_arm9
        return (u8*)"GEM";
#endif
#ifdef ARCH_win64
        return (u8*)"Windows";
#else
#ifdef ARCH_x86_64
        return (u8*)"Linux";
#endif
#endif
        }
    }
