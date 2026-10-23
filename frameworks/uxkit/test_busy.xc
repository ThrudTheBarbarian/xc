// test_busy.xc — UXApplication.beginBusy / endBusy reach the platform, and nest.
//
// On macOS the driver holds an NSProcessInfo activity while the app is busy (ux_ak_test_busy says
// whether one is open); on Windows the process's power throttling is off (read back with
// GetProcessInformation).  Two begins and one end leave the app busy; the second end ends it.
//
//   -A arm64 (AppKit, headless) or -A win64 (Win32).  Build+run: sh run_busy.sh
#import <Stdio.xc>
#if ARCH_win64
#import "UXWin32Driver.xc"
typedef i32 W32GetProcessInformationFn(pointer process, i32 infoClass, pointer info, u32 size);
#else
#import "UXAppKitDriver.xc"
extern i32 ux_ak_test_busy(void);
#endif
#import "UXApplication.xc"

i32 gBusyFails;
bool gBusySkip; // the platform cannot report its state

// 1 while the platform has the app marked busy
i32 busyNow(void)
    {
#if ARCH_win64
    W32GetProcessInformationFn* get = (W32GetProcessInformationFn*)GetProcAddress(LoadLibraryA("kernel32.dll"),
                                                                                  (u8*)"GetProcessInformation");
    if (get == (W32GetProcessInformationFn*)0)
        {
        return (i32)-1;
        }
    W32PowerThrottling t;
    t.version = (u32)1;
    t.controlMask = (u32)0;
    t.stateMask = (u32)0;
    if (get(GetCurrentProcess(), (i32)4, (pointer)&t, (u32)12) == (i32)0)
        {
        return (i32)-1;
        }
    return (t.controlMask & (u32)1) != (u32)0 && (t.stateMask & (u32)1) == (u32)0 ? (i32)1 : (i32)0;
#else
    return ux_ak_test_busy();
#endif
    }

void expect(u8* what, i32 want)
    {
    i32 got = busyNow();
    if (got == (i32)-1)
        {
        gBusySkip = true;
        return;
        }
    Stdio.printf("  %s %s: busy %d\n", got == want ? "ok  " : "FAIL", what, got);
    if (got != want)
        {
        gBusyFails = gBusyFails + (i32)1;
        }
    }

void main(void)
    {
#if ARCH_win64
    gDriver = new UXWin32Driver();
#else
    UXAppKitDriver* ak = new UXAppKitDriver();
    ak.setHeadless(true);
    gDriver = ak;
#endif
    UXApplication* app = new UXApplication();
    expect((u8*)"at start", (i32)0);
    app.beginBusy((u8*)"Integrating");
    expect((u8*)"after beginBusy", (i32)1);
    app.beginBusy((u8*)"Saving");
    app.endBusy();
    expect((u8*)"after a nested begin and end", (i32)1);
    app.endBusy();
    expect((u8*)"after the last endBusy", (i32)0);
    app.endBusy();
    expect((u8*)"after a spare endBusy", (i32)0);
    if (gBusySkip)
        {
        Stdio.printf("SKIP: this Windows cannot report power throttling\n");
        }
    else if (gBusyFails == (i32)0)
        {
        Stdio.printf("PASS: beginBusy/endBusy reach the platform and nest\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
