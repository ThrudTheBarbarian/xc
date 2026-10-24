// A library that installs RunLoop.main()'s wake hook and drains the loop
// (UXKit's UXApplication.run does both). See wakehook.sh.
#import "RunLoop.xc"
class RLHookLib
    {
    static u32 drain(void) { return RunLoop.main().runPending(); }
    static void hook(void) { RunLoop.main().setWakeHook(block void(void) { }, true); }
    }
