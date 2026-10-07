// UXPlatform.xc — the platform's driver, so an application's main() is the same on every backend:
//
//     UXApplication* app = new UXApplication();
//     app.setDriver(UXPlatform.driver());
//     app.setDelegate(new MyDelegate());
//     app.run();
//
// The backend is the target's where the target decides it (win64: Win32, wasm32: the web, arm9:
// GEM, ios-sim / ios: iOS, android: Android).  Otherwise the build names it, with -D UX_GTK or
// -D UX_GEM (host GEM); with neither, an arm64 build is the Mac's AppKit and an x86_64 build is GTK
// (Linux).
// Only the driver the build uses is imported.
#if ARCH_win64
#import "UXWin32Driver.xc"
#define UX_PLATFORM_WIN32 1
#elif ARCH_wasm32
#import "UXWebDriver.xc"
#define UX_PLATFORM_WEB 1
#elif ARCH_arm9
#import "UXGemDriver.xc"
#define UX_PLATFORM_GEM 1
#elif PLATFORM_ios
#import "UXIosDriver.xc"
#define UX_PLATFORM_IOS 1
#elif PLATFORM_android
#import "UXAndroidDriver.xc"
#define UX_PLATFORM_ANDROID 1
#elif UX_GEM
#import "UXGemDriver.xc"
#define UX_PLATFORM_GEM 1
#elif UX_GTK
#import "UXGtkDriver.xc"
#define UX_PLATFORM_GTK 1
#elif ARCH_x86_64
#import "UXGtkDriver.xc"
#define UX_PLATFORM_GTK 1
#else
#import "UXAppKitDriver.xc"
#define UX_PLATFORM_APPKIT 1
#endif

class UXPlatform : Object
    {
    // a new driver for the backend this build links
    static UXViewDriver* driver(void)
        {
#if UX_PLATFORM_WIN32
        return new UXWin32Driver();
#elif UX_PLATFORM_WEB
        return new UXWebDriver();
#elif UX_PLATFORM_GEM
        return new UXGemDriver();
#elif UX_PLATFORM_GTK
        return new UXGtkDriver();
#elif UX_PLATFORM_IOS
        return new UXIosDriver();
#elif UX_PLATFORM_ANDROID
        return new UXAndroidDriver();
#else
        return new UXAppKitDriver();
#endif
        }
    // Whether an application's main window is the whole screen: a phone's or a tablet's app has one
    // window, which fills the display, where a desktop's opens at a size of its own.
    static bool fillsScreen(void)
        {
#if UX_PLATFORM_IOS
        return true;
#elif UX_PLATFORM_ANDROID
        return true;
#else
        return false;
#endif
        }
    // the platform's name, for a title or an about box: "macOS", "Windows", "Linux", ...
    static u8* displayName(void)
        {
#if UX_PLATFORM_WIN32
        return (u8*)"Windows";
#elif UX_PLATFORM_WEB
        return (u8*)"the web";
#elif UX_PLATFORM_GEM
        return (u8*)"GEM";
#elif UX_PLATFORM_GTK
        return (u8*)"Linux";
#elif UX_PLATFORM_IOS
        return (u8*)"iOS";
#elif UX_PLATFORM_ANDROID
        return (u8*)"Android";
#else
        return (u8*)"macOS";
#endif
        }
    // the backend's name, for a log line: "win32", "web", "gem", "gtk", "ios", "android", "appkit"
    static u8* name(void)
        {
#if UX_PLATFORM_WIN32
        return (u8*)"win32";
#elif UX_PLATFORM_WEB
        return (u8*)"web";
#elif UX_PLATFORM_GEM
        return (u8*)"gem";
#elif UX_PLATFORM_GTK
        return (u8*)"gtk";
#elif UX_PLATFORM_IOS
        return (u8*)"ios";
#elif UX_PLATFORM_ANDROID
        return (u8*)"android";
#else
        return (u8*)"appkit";
#endif
        }
    }
