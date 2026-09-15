# Xtg — an AppKit-style UI toolkit for the XT, in xcc, over libGEM.
#
# The build invocation was living only in my shell history, which is not a place a
# build lives.  Two things are needed and neither is obvious:
#
#   -I .          local #import "..." — xcc does NOT search the source file's own
#                 directory by default.
#   -L $(GEMLIB)  a LIBRARY path, not an include path.  `#import <GEM>` resolves
#                 libGEM.so and reads its .dynsym ∩ DWARF, which is what gives us
#                 `theme` at its true size (19502 bytes) and `OBJECT` laid out exactly
#                 as libGEM sees it, rather than by hand.  See spikes/RESULTS.md — a
#                 guessed sizeof(theme) smashed the heap.
#                 (-L is not in `xcc --help`.  It cost me an hour.)
#
# Targets:
#   make            build every demo/test .so for arm9
#   make host       run the HOST tests natively (no GEM, no gemd, no qemu)
#   make run-demo   run demo.so on the XTOS loader (currently blocked)

XCC     ?= xcc
BUILD_ENV := $(wildcard ../../build.env)
build_env = $(if $(BUILD_ENV),$(shell sed -n 's/^$(1)=//p' $(BUILD_ENV)))
LOADER  ?= $(call build_env,LOADER)
GEMLIB  ?= $(or $(call build_env,GEMLIB),$(LOADER)/build-xtg)

ARCH    ?= arm9
XCCFLAGS = -A $(ARCH) -I . -L $(GEMLIB)

# The toolkit's own sources.  Not built standalone yet: xcc has no separate
# compilation, so a program #imports the sources it needs.  When libUXKit.so becomes a
# real --emit-lib artefact, this list is what goes into it.
SRCS = UXVersion.xc UXAbi.xc UXLibc.xc UXGeometry.xc UXResponder.xc UXViewTree.xc UXView.xc UXControl.xc \
       UXViewDriver.xc UXGemDriver.xc UXWindow.xc UXApplication.xc UXEvent.xc UXGraphics.xc UXGemGraphics.xc UXNib.xc \
       UXMenu.xc UXAlert.xc UXString.xc UXGem.xc UXGem.h.xc UXTableView.xc \
       UXOutlineView.xc UXNotificationCenter.xc

PROGS = demo.so nibdemo.so test_spine.so test_window.so test_scroll.so \
        test_dirty.so test_key.so test_menu.so test_alert.so test_clip.so \
        test_scale.so test_chrome.so test_table.so test_outline.so test_leak.so \
        test_memgate.so test_focus.so test_check.so test_radio.so test_controls.so test_state.so test_kitchensink.so test_nib.so test_autoresize.so libdemo.so libtable.so

all: $(PROGS)

# ---- libUXKit.so — the toolkit as a REAL shared library --------------------------
# `xcc --emit-lib` takes a single translation unit ("multi-file inputs not supported
# on the new-IR path yet"), and #import is include-once — so UXKit.xc is an umbrella
# that pulls in the sources, and that umbrella IS the library.  Since bug 021 was
# fixed in the arm9 backend (2026-07-29) that umbrella is the WHOLE backend-neutral
# toolkit, not the subset that fit under a 1024-method-name cap.  Nothing else here
# builds it, so the arm9 leg of run_overnight_tests.sh builds it as a check: it had
# silently stopped compiling once before.
#
# A client then says `#import <UXKit>` and LINKS against it.  That WORKS now: the
# imported-struct miscompile that blocked it (XTC-BUGS §5 — a struct parameter
# lowered to u8 across the .so boundary) was fixed in phase-613/614, and libdemo/
# libtable are the standing proof.  Most programs here still #import the sources
# directly, which remains fine — but the library path is real, not just honest.
# The only verification available while gemd is mid-build and qemu will not boot.
# UXGeom and UXStr are pure logic and need neither, so they run natively.
host: test_host
	./test_host

test_host: test_host.xc UXGeometry.xc UXString.xc UXLibc.xc
	$(XCC) -A arm64 -I . $< -o $@

# ---- VERSIONING ------------------------------------------------------------------
# It lives in UXVersion.xc now: major.minor.patch, with major.minor pasted into the ABI
# SYMBOL NAME so a stale client is refused BY THE LOADER, by name, before main() runs.
# See the header — and note this used to be two GENERATED files plus thirty lines of make,
# because xcc had no `##`. It does now (XCC-BUGS #16), so it is ordinary preprocessor.
version: ; @grep -E '^#define UXK_(MAJOR|MINOR|PATCH)' UXVersion.xc

lib: libUXKit.so

# BUILDING THE LIBRARY DEPLOYS IT.  The loader ships libUXKit.so out of its romfs-overlay,
# so a build that stops at the .so leaves the IMAGE running the previous one — and the
# failure is a link error inside qemu (`xtld_load err: UXButton$$init rc=undefined symbol`)
# that points at the symbol, not at the stale file.  The copy used to live in one `run`
# target in ../xt/Makefile, so every other way of building got the old library.
#
# A library that is built but not deployed is a stale library.  These are one step.
LIBDEST = $(LOADER)/romfs-overlay/Library

# The second deploy target is the THIRD-PARTY TREE: /opt/xcc/3p/uxkit — a SIBLING of the
# versioned install, so it survives compiler upgrades, and the probe searches it
# after -L and before the sysroot default.  With it populated, an out-of-tree
# client is `xcc -A arm9 app.xc` + `#use <UXKit>`: the metadata hit also puts our
# xc/ contract sources (UXAbi.xc, UXVersion.xc) on the client's quoted-import
# path.  VENDOR DISCIPLINE: the library is BUILT as unversioned libUXKit.so —
# SONAME and every client's DT_NEEDED come from the build-time name, so building
# straight to the versioned name would pin clients and defeat the minor-release
# float — then DEPLOYED under the versioned name with the compatibility symlink
# back.  The version in the filename is UXK_MAJOR-UXK_MINOR from UXVersion.xc,
# the same pair the ABI gate freezes into UXKit_abi_<maj>_<min>.
# The home is derived from the xcc actually on PATH; a source-checkout xcc has
# no install to deploy into and the step is skipped — that is not an error.
XCCHOME = $(dir $(shell command -v $(XCC)))..
XCC3P   = $(or $(XCC_3P),$(XCCHOME)/../3p)
UXK_MAJ = $(shell sed -n 's/^\#define UXK_MAJOR[[:space:]]*//p' UXVersion.xc)
UXK_MIN = $(shell sed -n 's/^\#define UXK_MINOR[[:space:]]*//p' UXVersion.xc)

libUXKit.so: UXKit.xc $(SRCS)
	$(XCC) -A $(ARCH) --emit-lib -I . -L $(GEMLIB) UXKit.xc -o $@
	@# The romfs deploy needs the XTOS loader checkout (LOADER in build.env, an
	@# external repository): skipped, not an error, when it is not set;
	@# the 3p deploy below is the toolchain-side truth either way.
	@if [ -d "$(LOADER)" ]; then mkdir -p $(LIBDEST) && cp $@ $(LIBDEST)/ \
	    && echo "  deploy   $@ -> $(LIBDEST)"; fi
	@if [ -d "$(XCCHOME)/lib/xc" ]; then \
	  mkdir -p "$(XCC3P)/uxkit/$(ARCH)" "$(XCC3P)/uxkit/xc"; \
	  cp $@ "$(XCC3P)/uxkit/$(ARCH)/libUXKit-$(UXK_MAJ)-$(UXK_MIN).so"; \
	  ln -sf "libUXKit-$(UXK_MAJ)-$(UXK_MIN).so" "$(XCC3P)/uxkit/$(ARCH)/libUXKit.so"; \
	  cp UXAbi.xc UXVersion.xc "$(XCC3P)/uxkit/xc/"; \
	  echo "  install  $@ -> $(XCC3P)/uxkit/$(ARCH)/libUXKit-$(UXK_MAJ)-$(UXK_MIN).so (+symlink, contracts)"; \
	fi

# libdemo is the ONE program that links Xtg as a real library instead of #importing the
# sources — it subclasses UXView across the .so boundary and lets the LIBRARY call its
# override back.  It needs `-L .` (where libUXKit.so is), which the generic %.so rule below
# does not pass, so it gets its own rule.  It had none: it was being built from my shell
# history, which is exactly what the note at the top of this file complains about.
libtable.so: libtable.xc libUXKit.so
	$(XCC) -A $(ARCH) -I . -L . -L $(GEMLIB) $< -o $@

libdemo.so: libdemo.xc libUXKit.so
	$(XCC) -A $(ARCH) -I . -L . -L $(GEMLIB) $< -o $@

%.so: %.xc $(SRCS)
	$(XCC) $(XCCFLAGS) $< -o $@

run-demo:    demo.so    ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/demo.so
run-nibdemo: nibdemo.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/nibdemo.so
run-spine:   test_spine.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_spine.so
run-window:  test_window.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_window.so

# ---- the KITCHEN SINK — one neutral app (ks_app.xc), shown on every backend --------
# The same KitchenSink delegate on each driver: native widgets on AppKit, GDI on Win32, GEM
# objects on arm9.  It grows as the toolkit does.  make mac / make win32 / make a9 / make gem.
mac:   ; XCC=$(XCC) sh run_mac.sh
# ---- mac-settings — preferences in NSUserDefaults --------------------------------
# Written by one process, read by the next; the test's suites are deleted afterwards.
mac-settings: ; XCC=$(XCC) sh run_mac_settings.sh
# ---- mac-chrome — subtitle + the modified dot on NSWindow ------------------------
mac-chrome: ; XCC=$(XCC) sh run_mac_chrome.sh
# ---- mac-vector — the vector board rendered on AppKit, checked for stroke seams ---
# The antialiasing seam bug shipped once; geometry tests cannot see it, only a real render can.
mac-vector: ; XCC=$(XCC) sh run_mac_vector.sh
# (The old standalone widget demos — make demo / make demo-win32 — are gone: the slider/progress/
# stepper/popup/segmented/toolbar showcase now lives in the kitchen sink, as the Windows > Widgets window.)
win32: ; XCC=$(XCC) sh run_win32_ks.sh
a9:    ks_a9.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/ks_a9.so
# gem: the GEM backend NATIVE on macOS — the a9 kitchen-sink (ks_a9.xc, built -A arm64) in a live SDL
# window driven by a host build of gemd over the POSIX shim.  Needs SDL2 (brew install sdl2).
# `make gem-build` just compiles/links the harness (headless check).  See hostgem/ROADMAP.md.
gem:       ; XCC=$(XCC) $(MAKE) -C hostgem gem
gem-build: ; XCC=$(XCC) $(MAKE) -C hostgem gem-build
# ---- gem-settings — preferences in the XTOS SQLite registry ----------------------
# Written by one process, read by the next, in the same database the desktop keeps deskPrefs in.
gem-settings: ; XCC=$(XCC) $(MAKE) -C hostgem settings

# ---- win64 — the second backend's original seed demo (M1 / Spike 1) --------------
# Recompile the seed Win32 demo from source and launch it under Wine.  See run_win32.sh.
win64: ; XCC=$(XCC) sh run_win32.sh

# The web backend (wasm32): the design doc's §5 milestones, headless under Node.
web-real: ; XCC=$(XCC) sh run_web_real.sh
web-loop: ; XCC=$(XCC) sh run_web_loop.sh
web-memgate: ; XCC=$(XCC) sh run_web_memgate.sh
web-drag: ; XCC=$(XCC) sh run_web_drag.sh
web-alert: ; XCC=$(XCC) sh run_web_alert.sh

# The iOS backend (simulator): native UIKit realization, the settled B+A loop.
ios-real: ; XCC=$(XCC) sh run_ios_real.sh
ios-alert: ; XCC=$(XCC) sh run_ios_alert.sh
ios-loop: ; XCC=$(XCC) sh run_ios_loop.sh

# The GTK backend (Linux desktop; runs on any display gtk_init accepts).
gtk-real: ; XCC=$(XCC) sh run_gtk_real.sh
gtk-loop: ; XCC=$(XCC) sh run_gtk_loop.sh
gtk-alert: ; XCC=$(XCC) sh run_gtk_alert.sh
gtk-settings: ; XCC=$(XCC) sh run_gtk_settings.sh
gtk-linux: ; XCC=$(XCC) sh run_gtk_linux.sh

# The Android backend (device realm; needs the SDK/NDK and an emulator/device).
android-real: ; XCC=$(XCC) sh run_android_real.sh
android-alert: ; XCC=$(XCC) sh run_android_alert.sh
android-loop: ; XCC=$(XCC) sh run_android_loop.sh
android-settings: ; XCC=$(XCC) sh run_android_settings.sh

# The standards table (pure host run, no window).
metrics: ; XCC=$(XCC) sh run_metrics.sh

# Bug 026 activated: outlet/:action synthesis under the UXKit names (host run).
designable: ; XCC=$(XCC) sh run_designable.sh

# ---- win32-real — the M1 payoff: the REAL neutral layer on the Win32 backend ------
# Builds the ACTUAL UXWindow + UXView + UXViewTree on UXWin32Driver (not the seed's mini-
# toolkit) and runs them under Wine: drawRect paints through the neutral seam via GDI, a click
# routes through the same hitTest the GEM backend uses.  Proves the neutral layer RUNS — not
# just compiles — on a second backend.  Skips if wine is absent.
win32-real: ; XCC=$(XCC) sh run_win32_real.sh

# ---- appkit — the THIRD backend: the REAL neutral layer native on macOS -----------
# Builds the ACTUAL UXWindow + UXView + UXViewTree on UXAppKitDriver and runs them native via an
# ObjC shim (libUXAppKit.m): drawRect paints through the neutral seam via NSGraphicsContext, pixels
# are read back to prove it landed, a click routes through the same hitTest the GEM/Win32 backends
# use.  Proves the neutral layer RUNS on a third backend.  macOS-only (skips elsewhere).
appkit: ; XCC=$(XCC) sh run_appkit.sh
viewremove: ; XCC=$(XCC) sh run_viewremove.sh
hiddeninherit: ; XCC=$(XCC) sh run_hiddeninherit.sh
enabletoggle: ; XCC=$(XCC) sh run_enabletoggle.sh
hiddeninherit-gtk: ; XCC=$(XCC) sh run_hiddeninherit_gtk.sh
hiddeninherit-win32: ; XCC=$(XCC) sh run_hiddeninherit_win32.sh

# ---- appkit-loop — the neutral RUN LOOP native on macOS ---------------------------
# Runs the app under UXApplication.run() pumping the REAL NSApplication queue: a posted NSEvent
# travels driver.nextEvent -> dispatchEvent -> the view.  Proves the run loop on the third backend.
appkit-loop: ; XCC=$(XCC) sh run_appkit_loop.sh

# ---- appkit-memgate — the §10 per-backend memory gate for AppKit ------------------
# Opens/closes N windows (each a real form) and asserts the native-object counter returns to
# baseline.  The heap oracle is printed but not asserted (Cocoa cache churn).  macOS-only.
appkit-memgate: ; XCC=$(XCC) sh run_appkit_memgate.sh

# ---- appkit-field — live text editing native on macOS ----------------------------
# A field form driven through the neutral run loop: posted key-downs travel driver.nextEvent ->
# dispatchKey -> UXTextField.keyDown -> driver.editText.  Proves keyboard input on AppKit.
appkit-field: ; XCC=$(XCC) sh run_appkit_field.sh

# ---- appkit-menu — headless smoke test for the NSMenu path -----------------------
appkit-menu: ; XCC=$(XCC) sh run_appkit_menu.sh

# ---- appkit-interactive — automated test of the [NSApp run] dispatch path --------
# The real interactive stack driven by one injected click at a Quit button; passes if the click
# reaches the action and the app quits (no hang).  macOS-only.
appkit-interactive: ; XCC=$(XCC) sh run_appkit_interactive.sh

# ---- appkit-demo — the INTERACTIVE demo: the neutral toolkit as a real macOS app --
# Shows a real window (buttons, a text field, a menu bar, an NSAlert), runs the real NSApplication
# event loop.  Foreground; close the window to exit.  macOS-only.
appkit-demo: ; XCC=$(XCC) sh run_appkit_demo.sh

# ---- appkit-scroll — native scrolling: the neutral toolkit inside a real NSScrollView ----
# A document taller than the window; scroll with the trackpad/wheel/scrollbar.  The app writes no
# scroll code — it reports its content size and NSScrollView owns the offset.  Foreground; macOS-only.
appkit-scroll: ; XCC=$(XCC) sh run_appkit_scroll.sh

# ---- appkit-table — a native NSTableView driven by the neutral UXTableView datasource -----
# A column-headed, alternating-row, scrollable native table; click a row and the app's
# tableSelectionDidChange updates a label.  The same datasource drives the GEM tree.  macOS-only.
appkit-table: ; XCC=$(XCC) sh run_appkit_table.sh

# ---- appkit-scrolldrive — code must be able to scroll a native NSScrollView -----------------
appkit-scrolldrive: ; XCC=$(XCC) sh run_appkit_scrolldrive.sh

# ---- appkit-outline — bug 020 guard: no native scroll on top of the NSOutlineView -----------
appkit-outline: ; XCC=$(XCC) sh run_appkit_outline.sh

# ---- appkit-multisel — the neutral multi-selection model, exercised headless ----------------
appkit-multisel: ; XCC=$(XCC) sh run_appkit_multisel.sh

# ---- appkit-resize — a live-resizable window: the neutral toolkit tracks the native frame ----
# Drag the edge: the custom view reflows to fill, a native button anchors to the corner, and a label
# shows the live size — via the neutral windowDidResize hook.  Foreground; macOS-only.
appkit-resize: ; XCC=$(XCC) sh run_appkit_resize.sh

# ---- notify — the neutral notification centre, exercised natively (no backend) ---------------
notify: ; $(XCC) -A arm64 -I . test_notify.xc -o $(CURDIR)/test_notify && $(CURDIR)/test_notify

# ---- springs — the neutral springs & struts solver, exercised headless on AppKit -------------
# The GEM-side integration is test_autoresize.so (run it under qemu: make run-autoresize).
springs: ; XCC=$(XCC) sh run_appkit_springs.sh
run-autoresize: test_autoresize.so ; $(MAKE) -C $(LOADER) xtcrun XTC_SO=$(CURDIR)/test_autoresize.so

# ---- win32-loop — the neutral RUN LOOP on the Win32 backend -----------------------
# Runs the app under UXApplication.run() (the same loop the GEM app uses) pumping the REAL
# Win32 message queue: a posted click travels driver.nextEvent -> dispatchEvent -> the view,
# and WM_QUIT ends the loop.  Proves the neutral event loop — not just paint/hit-test — runs
# on a second backend.  Skips if wine is absent.
win32-loop: ; XCC=$(XCC) sh run_win32_loop.sh

# ---- win32-field — live text editing on the Win32 backend -------------------------
# A form with a text field: a posted click focuses it, posted WM_CHARs type through the real
# message pump into driver.editText (the driver is the edit engine, as objc_edit is on GEM).
# Proves keyboard input + a live control on a second backend.  Skips if wine is absent.
win32-field: ; XCC=$(XCC) sh run_win32_field.sh

# ---- win32-memgate — the §10 per-backend memory gate for Win32 --------------------
# Opens/closes N forms in a loop; asserts the native-object counter AND the heap baseline both
# return to zero, on the close() and dealloc paths.  Catches a leaked HWND, view tree, node
# array or field editor before more is built on the driver.  Skips if wine is absent.
win32-memgate: ; XCC=$(XCC) sh run_win32_memgate.sh

# ---- win32-menu — menus on the Win32 backend -------------------------------------
# The neutral app-level UXMenuBar becomes a per-window HMENU; a pick fires WM_COMMAND, decoded
# to a neutral MenuSelect and routed to the bound method (the GEM MN_SELECTED path).  Skips if
# wine is absent.
win32-menu: ; XCC=$(XCC) sh run_win32_menu.sh

# ---- win32-focus — keyboard focus traversal + default button on Win32 ------------
# Exercises the neutral tab-ring (UXWindow.moveFocus) and the app-declared default button (§5)
# on Win32 with no backend-specific focus code — Tab/Return climb the responder chain.  Skips if
# wine is absent.
win32-focus: ; XCC=$(XCC) sh run_win32_focus.sh

# ---- win32-check — a checkbox (custom-drawn neutral control) on Win32 -------------
win32-check: ; XCC=$(XCC) sh run_win32_check.sh

# ---- win32-radio — radio buttons (mutual exclusion) on Win32 ----------------------
win32-radio: ; XCC=$(XCC) sh run_win32_radio.sh

# ---- win32-valid — per-character field validation on Win32 -----------------------
win32-valid: ; XCC=$(XCC) sh run_win32_valid.sh

# ---- win32-alert — modal alerts (MessageBox) on Win32 ----------------------------
win32-alert: ; XCC=$(XCC) sh run_win32_alert.sh

# ---- win32-multiwindow — closing a secondary window must not quit the app ---------
# Regression guard: the driver used to PostQuitMessage on every WM_DESTROY, so closing the colour
# picker (Select) terminated the whole program.  Skips if wine is absent.
win32-multiwindow: ; XCC=$(XCC) sh run_win32_multiwindow.sh

# ---- win32-drawline — GDI strokes must be uniform, not heavier on the right ------
# Regression guard: drawLine was faked with a triangle (a wedge), so every rectangle looked heavy-right.
win32-drawline: ; XCC=$(XCC) sh run_win32_drawline.sh

# ---- win32-drawtext — GDI drawText must scale with its size argument -------------
# Regression guard: drawText ignored `size` (fixed system font), so the font-chooser preview never scaled.
win32-drawtext: ; XCC=$(XCC) sh run_win32_drawtext.sh

# ---- win32-drawfont — GDI drawTextFont must honour family + bold/italic ----------
# Regression guard: the styled preview — bold must ink heavier than regular, a mono family differ in width.
win32-drawfont: ; XCC=$(XCC) sh run_win32_drawfont.sh

# ---- win32-date — UXDate.currentDate against a real clock -------------------------
win32-date: ; XCC=$(XCC) sh run_win32_date.sh

# ---- win32-scrolldrive — the toolkit must be able to scroll a native container ---
win32-scrolldrive: ; XCC=$(XCC) sh run_win32_scrolldrive.sh

# ---- win32-settings — preferences that outlive the process -----------------------
# Two runs of one exe: write, then read back in a fresh process.  The store was memory-only.
win32-settings: ; XCC=$(XCC) sh run_win32_settings.sh

# ---- win32-exit — the close box must actually quit the app -----------------------
win32-exit: ; XCC=$(XCC) sh run_win32_exit.sh

# ---- win32-recorder — capture the event stream, replay it into the real widgets ---
win32-recorder: ; XCC=$(XCC) sh run_win32_recorder.sh

# ---- win32-textlayout — line breaking against real glyph metrics -----------------
# The arithmetic wrap is test_textlayout; this is wrapFont, measuring through driver.textWidth.
win32-textlayout: ; XCC=$(XCC) sh run_win32_textlayout.sh

# ---- win32-rules — the rule editor (UXPredicate) filters the table ---------------
# The board, not the engine: rule rows -> a predicate tree -> the filtered row set the table shows.
win32-rules: ; XCC=$(XCC) sh run_win32_rules.sh

# ---- win32-scroll — vertical scrolling on Win32 ----------------------------------
win32-scroll: ; XCC=$(XCC) sh run_win32_scroll.sh

# ---- win32-scrollclick — a click inside a native scroll container reaches the view -
# Regression guard: the UXScroll32 child swallowed clicks, so the font chooser's family list was dead.
win32-scrollclick: ; XCC=$(XCC) sh run_win32_scrollclick.sh

# ---- win32-scrollpaint — an app-driven repaint reaches inside that container -------
# Regression guard: a child HWND doesn't repaint from the parent's InvalidateRect, so code-driven
# changes inside a scroll view (no click) went unpainted.
win32-scrollpaint: ; XCC=$(XCC) sh run_win32_scrollpaint.sh

# ---- win32-enabled — enabled/disabled controls on Win32 --------------------------
win32-enabled: ; XCC=$(XCC) sh run_win32_enabled.sh

# ---- win32-hidden — hidden controls (not drawn, not hit) on Win32 ----------------
win32-hidden: ; XCC=$(XCC) sh run_win32_hidden.sh

# ---- win32-kitchensink — a whole form (all controls + menu) on Win32 -------------
win32-kitchensink: ; XCC=$(XCC) sh run_win32_kitchensink.sh

# ---- win32-toolbar — native ToolbarWindow32 (segmented check-group + toolbar row) on Win32 ----
win32-toolbar: ; XCC=$(XCC) sh run_win32_toolbar.sh

# ---- win32-winroute — multi-window click routing on Win32 --------------------------
win32-winroute: ; XCC=$(XCC) sh run_win32_winroute.sh

# ---- win64-lib — prove the neutral view/widget layer compiles for win64 ----------
# A compile gate over win64_probe.xc: it imports the whole widget stack, so a GEM type or
# <GEM> import leaking back into the neutral layer breaks the win64 build here.  Skips if
# the win64 target is unavailable.  (It does not run — there is no win64 driver yet.)
win64-lib:
	@if $(XCC) -A win64 -I . win64_probe.xc -o /tmp/xg_win64_probe.exe >/dev/null 2>&1; then \
	    echo "== win64-lib: the neutral view layer COMPILES for win64 =="; \
	else \
	    echo "== win64-lib: FAILED — a GEM dependency leaked into the neutral layer =="; \
	    $(XCC) -A win64 -I . win64_probe.xc -o /tmp/xg_win64_probe.exe 2>&1 | grep -viE 'warning: cannot read library metadata' | head; \
	    exit 1; \
	fi

clean: ; rm -f $(PROGS) libUXKit.so test_host

.PHONY: all lib host clean version run-demo run-nibdemo run-spine run-window mac a9 gem gem-build win32 win64 win32-real win32-loop win32-field win32-memgate win32-menu win32-focus win32-check win32-radio win32-valid win32-alert win32-scroll win32-enabled win32-hidden win32-kitchensink win32-toolbar win32-winroute win64-lib
