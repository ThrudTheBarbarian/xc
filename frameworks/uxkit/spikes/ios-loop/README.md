# ios-loop — the run-loop spike

**Model under test: Option B + A.** UIKit owns the main thread's run loop;
nothing in UXKit blocks, anywhere.

- **B, the abstract hijack**: xtc `main()` is one call deep.
  `ux_ios_shell_run()` IS `UIApplicationMain` and never returns. This is what
  `UXApplication.run()` does on iOS: app code still writes `run()` once, and the
  neutral `applicationDidStart` moment fires from `didFinishLaunching` via a
  registered callback.
- **A, the subservient pump**: a `CADisplayLink` ticks a registered callback
  every frame, as the §3.2 invalidation-consolidation heartbeat. It is NOT an
  input path.
- **Input**: a real `UIButton` target-action hands over a **logical id**
  (UXNB v2's currency). The controller catches `onPlay` without ever knowing a
  touch or coordinate was involved. Dispatch is a direct main-thread call into
  xtc; no queue, no Atomics, no second thread.
- The two protocol methods that BLOCK elsewhere have native answers here:
  tables own drag (`trackDragStep` = 0, as AppKit), and a synchronous
  `alertRun` nests a CFRunLoop until the `UIAlertController` handler fires
  (the classic sync-modal shape). These belong to the driver, not this spike.

Build (the shell with the platform clang, the binary linked IN-HOUSE by xcc):

    xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator \
        -fobjc-arc -c shell.m -o shell.o
    xcc -A ios-sim -I ../.. spike.xc -Xlinker shell.o \
        -framework UIKit -framework Foundation -framework QuartzCore -o SpikeLoop

Run: `sh run.sh` boots an iPhone sim, installs the bundle, launches with the
console attached, and greps the PASS sentinel (three self-injected taps through
target-action -> logical id -> xtc, with heartbeat ticks observed). A wedge
exits 2 via the shell's 15s watchdog, so silence cannot look like success.

**Findings**
- `xcc -A ios-sim -framework UIKit` links, but spends ~78s resolving the UIKit
  `.tbd` reexport graph (one framework, hello-world). Caching it is an open
  compiler improvement.
- `_putc` (console) is supplied by the shell here; the real iOS driver's rt
  layer owns it (in `support/ios`).
- `rt-macos.s` does not assemble for the sim target (double .build_version,
  duplicate Lloh labels when clang-assembled). This does not affect the in-house
  path; a clang-side fallback link would need a sim rt.

**Result: PASS.**

    spike: applicationDidStart moment, from didFinishLaunching
    spike: action L2 -> onPlay, tap 1 (ticks so far 18)
    spike: action L2 -> onPlay, tap 2 (ticks so far 37)
    spike: action L2 -> onPlay, tap 3 (ticks so far 56)
    PASS: UIKit-owned loop, delegate start, logical-id actions, display-link heartbeat

The Option B + A model works end to end in the simulator: UIKit keeps the main
loop, run()'s inside becomes UIApplicationMain, input arrives as logical-id
target-actions, and the display link supplies the §3.2 heartbeat (~60fps against
300ms tap spacing). No blocking, no second thread, no queue.

**Caveat on the binary that passed:** it was linked with the platform clang. The
in-house `xcc -A ios-sim` link produces correct load commands but attributes
every bind to dylib ordinal 1, which dyld rejects; this blocks in-house iOS
linking beyond libSystem. The rt objects for the clang link came from splitting
the installed `rt-macos.s` at its concatenation seams and stripping the platform
stamps. `run.sh` greps the PASS sentinel either way, so the gate moves to the
in-house link by rebuilding per this README once the ordinal bug is fixed.
