# Spike 1 (Linux/GTK) — the GTK driver

The GTK counterpart of the Win32 driver spike (`tests/interop/xtg-spike1`), closing
the desktop-host matrix. It shows there is no obstacle to a GTK driver: GTK is a
plain C API, so it behaves like Win32, not like the Objective-C bridge AppKit
needs (`tests/interop/xtg-spike2`).

- `gtkshim.c`: a thin GTK4 wrapper. The test host has the GTK *runtime* but no
  `-dev` headers, so the GTK C ABI is **hand-declared** (no `#include`) and the
  versioned `libgtk-4.so.1` is linked by path. A real xtc GTK binding would
  `#import` these instead.
- `gtk_driver.xc`: the driver, in xtc. It brings up GTK (`gtk_init_check`), makes
  a real `GtkWindow` and `GtkButton`, and connects the button's `clicked` signal.
  The `g_signal_connect` **user_data is the reverse map**: the callback
  `on_clicked(widget, user_data)` recovers the `XGView` front object from
  `user_data` and dispatches through the neutral virtual `clicked()` into the app
  subclass `MyView`'s override.

Output (`expected.out`): `init=1 / window=1 / button=1 / clicked! / done`.

Run: `sh tests/interop/xtg-gtk/run.sh` (builds the wrapper on the Linux host,
links on the Mac, runs under Xvfb). The Linux host is `XTC_X86_HOST` from
`build.env`, falling back to `XTC_LINUX_HOST`. The test is skipped when the host
is unreachable or lacks the GTK4 runtime, Xvfb or `cc`.

## Why the plumbing

The harness does not require GTK4 `-dev` packages or root access on the Linux
host, so there are no headers, no pkg-config, and no unversioned `libgtk-4.so`
symlink for `#import`/`-lgtk-4` to find. The wrapper is therefore built *on the
host* against the versioned `.so` by full path (no headers needed, as GTK's C
ABI is stable), given a proper `-soname` so it resolves via `LD_LIBRARY_PATH` at
runtime, fetched back, and linked into the xtc app on the Mac. GTK needs a
display, so it runs under `xvfb-run`. None of this reflects a language or
compiler limitation: with a normal GTK-dev install it would be a plain
`#import <gtk-4>`.

Result: xtc drives GTK4, connects a GObject signal with a context word, and the
callback dispatches into an xtc override. That proves the driver seam on a third
real host toolkit; Win32, GTK, AppKit and the A9 are all covered.
