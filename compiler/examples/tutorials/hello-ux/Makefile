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
