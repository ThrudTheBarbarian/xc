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
//     wasm32  a browser  the web     (the worker run loop; run_rocks_web.sh)
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
//
// RK_HOSTGEM (-D RK_HOSTGEM) builds the GEM branch on the Mac instead of AppKit: that is
// hostgem's GEM, the real desktop and AES running natively on the host (frameworks/uxkit/hostgem),
// which is how Rocks is run on GEM without the board (run_rocks_gem.sh).  Nested for the same reason.
//
// RK_IOS and RK_ANDROID are the mobile builds.  To the compiler both are plain arm64 (an ios-sim or
// android build defines nothing of its own), so they are flags like RK_HOSTGEM, set by
// run_rocks_ios.sh and run_rocks_android.sh, and nested ahead of the arm64 = AppKit branch.  On
// both the platform owns the loop: app.run() hands over to it and the delegate starts from there.
#ifdef RK_HOSTGEM
#import "UXGemDriver.xc"
#else
#ifdef RK_IOS
#import "UXIosDriver.xc"
#else
#ifdef RK_ANDROID
#import "UXAndroidDriver.xc"
#else
#ifdef ARCH_arm64
#import "UXAppKitDriver.xc"
#endif
#ifdef ARCH_arm9
#import "UXGemDriver.xc"
#endif
#ifdef ARCH_wasm32
#import "UXWebDriver.xc"
#endif
#endif
#endif
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
#ifdef RK_HOSTGEM
        UXGemDriver* hg = new UXGemDriver();
        gDriver = hg;
        i32 hw = (i32)0;
        i32 hh = (i32)0;
        return hg.boot(&hw, &hh);
#else
#ifdef RK_IOS
        gDriver = new UXIosDriver(); // app.run() boots it and enters UIApplicationMain
        return true;
#else
#ifdef RK_ANDROID
        gDriver = new UXAndroidDriver(); // app.run() boots it and hands over to the UI thread
        return true;
#else
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
#ifdef ARCH_wasm32
        // the browser: the app runs in the loader's worker, drawing on its OffscreenCanvas
        UXWebDriver* bd = new UXWebDriver();
        gDriver = bd;
        i32 bw = (i32)0;
        i32 bh = (i32)0;
        return bd.boot(&bw, &bh);
#endif
#endif
#endif
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

    // Whether the main window is the whole screen: a phone's or a tablet's app has one window,
    // which fills the display, where a desktop's opens at a size of its own.
    static bool fillsScreen(void)
        {
#ifdef RK_IOS
        return true;
#endif
#ifdef RK_ANDROID
        return true;
#endif
        return false;
        }

    // What to call this build, for the window title and the about box.
    static u8* platformName(void)
        {
#ifdef RK_HOSTGEM
        return (u8*)"GEM";
#else
#ifdef RK_IOS
        return (u8*)"iOS";
#else
#ifdef RK_ANDROID
        return (u8*)"Android";
#else
#ifdef ARCH_arm64
        return (u8*)"macOS";
#endif
#ifdef ARCH_arm9
        return (u8*)"GEM";
#endif
#ifdef ARCH_wasm32
        return (u8*)"the web";
#endif
#endif
#endif
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
