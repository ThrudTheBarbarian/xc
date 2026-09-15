# Spike 2 — the AppKit / Objective-C bridge (macOS go/no-go)

Spike 2 of the multi-host GUI design. The desktop hosts Win32 (Spike 1) and GTK
are C APIs, but **AppKit is Objective-C**. Driving it means (a) sending messages
via `objc_msgSend`, and (b) receiving callbacks by registering an xtc function as
an ObjC **method (IMP)** at runtime. This is the go/no-go on "native on Mac"; if
it failed, macOS would fall back to a drawn renderer.

**Result: passes.** No compiler change needed.

- `objcshim.m`: the objc-runtime primitives. `objc_msgSend` must be **cast per
  call signature**, so these are the typed wrappers a real xtc AppKit binding
  would *generate*: `xt_msg`/`xt_msg_p` (msgSend variants), `xt_getClass`,
  `xt_sel`, `xt_alloc_class`/`xt_add_method`/`xt_register_class`, and
  `xt_make_window` (the one `NSRect`-struct-by-value call, done in C). Nothing
  AppKit-specific beyond primitives lives here.
- `spike2.xc`: **all the AppKit logic, in xtc**. It brings up `NSApplication`,
  makes an `NSWindow` and `NSButton`, creates a runtime class
  `XtTarget : NSObject`, adds the xtc function `onClick` as its `onClick:`
  method, wires the button's target/action, and calls `performClick`, which
  makes AppKit invoke `onClick` (an ObjC IMP that is an xtc function) with the
  button as sender.

Output (`expected.out`): `app=1 / window=1 / button=1 / addMethod=1 /
onClick fired, sender=1 / done`.

Run: `sh tests/interop/xtg-spike2/run.sh` (macOS only).

## Why it matters

An xtc program can be a first-class Objective-C citizen: send arbitrary messages,
subclass ObjC classes at runtime, and act as a delegate or target, because an
xtc free function is a valid ObjC method IMP (the same C-callback mechanism
proved in `tests/interop/callback-context`). The only ObjC-specific cost is
generating the per-signature `objc_msgSend` wrappers, which is a binding concern,
not a compiler one. All three desktop hosts (Win32, GTK, AppKit) plus the A9 are
reachable behind one GUI API.
