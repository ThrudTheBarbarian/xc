---
title: "Guide: Hello UX, a window on every platform (tutorial)"
description: "Step by step: one UXKit program with a window, a label and a button, built for macOS, Linux, Windows, the web, iOS and Android by a Makefile that also packs what each platform needs beside it."
---

This tutorial does what [One program, six platforms](/tutorials/cross-build-make/)
does, with a window instead of a line of text: one UXKit program, one
Makefile, six platforms. It adds the one thing a graphical program needs that
a console program does not: the toolkit's library for its platform, shipped
beside it. It takes about fifteen minutes, and the files are in the
repository under `compiler/examples/tutorials/hello-ux/`.

You need xcc 0.74 or later, `make`, and UXKit installed in the third-party
tree, `/opt/xcc/3p/uxkit/`, from the
[UXKit library archive](/compiler/downloads/#uxkit-library). The macOS,
Windows, Linux and web programs run with 0.74; the iOS and Android programs
build with 0.74 and run from 0.75, which fixes how their libraries are
stamped and named ([Changelog](/compiler/downloads/changelog/)).

## 1. Write the program

Make a folder, `hello-ux`, and put the program in it. It names no platform:
`#use <UXKit>` brings in the toolkit, and a new `UXApplication` installs the
driver for whatever the program is built for.

```c
// hello-ux/hello-ux.xc
#import <Stdio.xc>
#use <UXKit>

class HelloUX : Object <UXApplicationDelegate>
{
    UXLabel* greeting;
    i32      presses;

    void init(void) { presses = 0; greeting = (UXLabel*)0; }

    // Runs when the button is pressed: &self.onPress carries the receiver
    // and the code.
    void onPress(UXControl* sender) {
        presses = presses + 1;
        greeting.setText(presses == 1 ? (u8*)"Hello again!" : (u8*)"Hello, still here!");
        Stdio.printf("pressed %d\n", presses);
    }

    i32 applicationDidStart(UXApplication* app) {
        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Hello UX", UXGeom.make(80, 80, 260, 120), content);

        greeting = new UXLabel();
        greeting.setText((u8*)"Hello UX!");
        content.addSubview(greeting, UXGeom.make(16, 16, 220, 18));

        UXButton* b = new UXButton();
        b.setTitle((u8*)"Press me");
        b.setAction(&self.onPress);
        content.addSubview(b, UXGeom.make(16, 48, 96, 24));

        win.tree.finalise();
        win.displayAll();
        Stdio.printf("Hello UX! on %s\n", UXPlatform.displayName());
        return 0;
    }
}

void main(void) {
    UXApplication* app = new UXApplication();
    app.setDelegate(new HelloUX());
    app.run();
}
```

What each part is for is on
[Your first window](/compiler/api/uxkit/guide-first-window/); this program is
that one with a greeting.

## 2. Write the Makefile

The Hello world Makefile built one file per platform. This one builds the
program and then copies what its platform needs into the same folder, so
`build/<platform>/` is the thing to ship. One new knob, `UXKIT`, says where
the installed libraries are.

```make
# Makefile — a UXKit window on six platforms.
#
#   make              builds every platform into build/<platform>/
#   make mac          builds one (mac, linux, windows, web, ios, android)
#   make run-mac      builds it and runs it (run-web, run-ios, run-android …)
#   make clean        removes build/
#
# The same knobs as the Hello world Makefile, plus UXKIT: where the installed
# UXKit libraries are. A graphical program ships with UXKit's library for its
# platform beside it, so each rule here builds the program AND copies what it
# needs into build/<platform>/, which is then the folder to ship.

# ── The knobs ──────────────────────────────────────────────────────────────
# The compiler: xcc on the PATH, or a full path to one.
XCC   ?= xcc
# Optimisation: -O0 (the fastest build) to -O3 (the fastest code).
OPT   ?= -O3
# Anything else: -g for debug information, -q, -Wanalyze …
FLAGS ?=
# ios-sim (the simulator) or ios (a device, which needs signing).
IOS   ?= ios-sim
# The installed UXKit: the third-party tree beside the versioned install.
UXKIT ?= /opt/xcc/3p/uxkit

# The program. The outputs are build/<platform>/helloux, helloux.exe … (no
# hyphen: the name is also the Android package and the iOS bundle name).
NAME  := helloux
SRC   := hello-ux.xc
BUILD := build

# ── The targets ────────────────────────────────────────────────────────────
.PHONY: all mac linux windows web ios android clean help \
        run-mac run-linux run-windows run-web run-ios run-android

all: mac linux windows web ios android

mac:     $(BUILD)/mac/$(NAME)
linux:   $(BUILD)/linux/$(NAME)
windows: $(BUILD)/windows/$(NAME).exe
web:     $(BUILD)/web/$(NAME).wasm
ios:     $(BUILD)/ios/$(NAME).app/$(NAME)
android: $(BUILD)/android/$(NAME).apk

# macOS: the program finds libUXKit.dylib in the installed tree, so nothing
# is copied. To ship it, copy the dylib beside the program.
$(BUILD)/mac/$(NAME): $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A arm64 $(OPT) $(FLAGS) -o $@ $<

# Linux: libUXKit.so and libUXGtk.so go beside the program; the machine that
# runs it needs GTK 4.
$(BUILD)/linux/$(NAME): $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A x86_64 $(OPT) $(FLAGS) -o $@ $<
	cp $(UXKIT)/x86_64/libUXKit.so $(UXKIT)/x86_64/libUXGtk.so $(@D)/

# Windows: libUXKit.dll goes beside the .exe.
$(BUILD)/windows/$(NAME).exe: $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A win64 $(OPT) $(FLAGS) -o $@ $<
	cp $(UXKIT)/win64/libUXKit.dll $(@D)/

# The web: the program's .wasm and .js, UXKit's module and its two page
# scripts, and a page that loads them (index.html, from this folder).
$(BUILD)/web/$(NAME).wasm: $(SRC) index.html
	@mkdir -p $(@D)
	$(XCC) -A wasm32 $(OPT) $(FLAGS) -o $@ $<
	cp $(UXKIT)/wasm32/libUXKit.wasm $(UXKIT)/wasm32/libUXKit.json \
	   $(UXKIT)/wasm32/ux_web_page.js $(UXKIT)/wasm32/ux_web_browser.js \
	   index.html serve.py $(@D)/
	rm -f $(@D)/$(NAME).html    # xcc's console page; index.html is the app's

# iOS: an app bundle, which is a folder: the program, an Info.plist and
# libUXKit.dylib. Needs xcc 0.75 for the simulator library's platform stamp.
$(BUILD)/ios/$(NAME).app/$(NAME): $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A $(IOS) $(OPT) $(FLAGS) -o $@ $<
	cp $(UXKIT)/$(IOS)/libUXKit.dylib $(@D)/
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleIdentifier</key><string>org.compile-xc.$(NAME)</string>' \
	  '  <key>CFBundleExecutable</key><string>$(NAME)</string>' \
	  '  <key>CFBundleName</key><string>$(NAME)</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>1.0</string>' \
	  '  <key>CFBundleVersion</key><string>1</string>' \
	  '  <key>UILaunchScreen</key><dict/>' \
	  '</dict></plist>' > $(@D)/Info.plist

# Android: the APK carries UXKit's two libraries and its Java shim; the shim
# is the activity the system starts, and it loads the program. Needs xcc 0.75
# for the library names the APK records.
$(BUILD)/android/$(NAME).apk: $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A android --emit-apk $(OPT) $(FLAGS) \
	    --with-lib $(UXKIT)/android/libUXAndroid.so --with-lib $(UXKIT)/android/libUXKit.so \
	    --with-dex $(UXKIT)/android/classes.dex --lib-name UXAndroid --needed libUXAndroid.so \
	    -o $@ $<

# ── Running ────────────────────────────────────────────────────────────────
run-mac: mac
	$(BUILD)/mac/$(NAME)

# On a Linux machine with GTK 4, with the whole build/linux folder copied there.
run-linux: linux
	cd $(BUILD)/linux && ./$(NAME)

# On Windows, with the whole build/windows folder copied there (or under Wine).
run-windows: windows
	cd $(BUILD)/windows && wine $(NAME).exe

# A browser needs the page served with cross-origin isolation (the worker
# shares memory with the page); serve.py does that. Then open the URL.
run-web: web
	cd $(BUILD)/web && python3 serve.py 8000

# A booted iPhone simulator.
run-ios: ios
	xcrun simctl install booted $(BUILD)/ios/$(NAME).app
	xcrun simctl launch --console booted org.compile-xc.$(NAME)

# A device or emulator visible to adb; the program's output goes to logcat.
run-android: android
	adb install -r $(BUILD)/android/$(NAME).apk
	adb logcat -c
	adb shell am start -n org.compile_xc.$(NAME)/android.app.NativeActivity
	sleep 3
	adb logcat -d -s xcapp uxkit

clean:
	rm -rf $(BUILD)

help:
	@echo "targets: all mac linux windows web ios android, run-<platform>, clean"
	@echo "knobs:   XCC=$(XCC) OPT=$(OPT) FLAGS=$(FLAGS) IOS=$(IOS) UXKIT=$(UXKIT)"
```

The web build also wants two small files in the folder, which the rule
copies in. `index.html` is the page: a canvas, one line of configuration,
and the two scripts.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Hello UX</title>
<style>
  body   { margin: 0; background: #202020; }
  canvas { display: block; margin: 2rem auto; background: #fff; }
</style>
</head>
<body>
<canvas id="ux-canvas" width="480" height="320"></canvas>
<script>
  // The run loop lives in a worker (ux_web_browser.js), which shares memory
  // with the page; that is why the page must be served with cross-origin
  // isolation (serve.py sends the two headers). The canvas is the window.
  globalThis.xccConfig = { runLoop: 'worker', workerScript: 'ux_web_browser.js', canvas: '#ux-canvas' };
</script>
<script src="ux_web_page.js"></script>
<script src="helloux.js"></script>
</body>
</html>
```

`serve.py` is a file server that adds the two headers a page with a shared
memory worker needs; without them the browser shows an empty canvas.

```python
#!/usr/bin/env python3
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
print(f"serving on http://localhost:{port}/")
http.server.ThreadingHTTPServer(("", port), Handler).serve_forever()
```

## 3. Build everything

```sh
cd hello-ux
make
```

Each platform's folder is then complete:

| Target | `build/<platform>/` holds | Ship |
| --- | --- | --- |
| `mac` | `helloux` | the program; copy `libUXKit.dylib` beside it for another Mac |
| `linux` | `helloux`, `libUXKit.so`, `libUXGtk.so` | the folder; the machine needs GTK 4 |
| `windows` | `helloux.exe`, `libUXKit.dll` | the folder |
| `web` | `helloux.wasm`, `helloux.js`, `libUXKit.wasm`, `libUXKit.json`, `ux_web_page.js`, `ux_web_browser.js`, `index.html`, `serve.py` | the folder, on any server that sends the two headers |
| `ios` | `helloux.app/` with the program, `Info.plist` and `libUXKit.dylib` | the bundle |
| `android` | `helloux.apk` | the APK |

## 4. Run each one

| Command | Where | What you see |
| --- | --- | --- |
| `make run-mac` | this Mac | the window, and `Hello UX! on macOS` in the terminal |
| `make run-web` | this machine, then open `http://localhost:8000/` | the window on the page's canvas; the printf lines in the browser console |
| `make run-linux` | a Linux machine with GTK 4 | the window |
| `make run-windows` | a Windows machine, or Wine | the window |
| `make run-ios` | a Mac with a booted iPhone simulator (0.75) | the window in the simulator; the printf lines in the terminal |
| `make run-android` | a device or emulator visible to `adb` (0.75) | the window; the printf lines in logcat |

Press the button: the label changes and `pressed 1` is printed, on every
platform, from the same source.

## 5. The same thing from Windows

The [Windows tutorial](/tutorials/cross-build-windows/)'s `build.ps1` builds
this program too: change `$Name` to `helloux` and `$Src` to `hello-ux.xc`,
and after each build copy the platform's companions from the table above into
`build\<platform>\`, with `Copy-Item`, the way the Makefile's `cp` lines do.
On the PC itself, `build\windows\helloux.exe` with `libUXKit.dll` beside it
is the program.

## 6. Where to go next

- Lay the window out in [Rocks](/rocks/) instead of in code:
  [A music player in Rocks](/rocks/tutorial/) builds a window there and loads
  it in an app.
- The toolkit's classes are under [UXKit](/compiler/api/uxkit/); the
  [driver model](/compiler/api/uxkit/guide-drivers/) is how one source
  becomes a native app on each platform.
