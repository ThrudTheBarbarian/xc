# Makefile — one program, six platforms.
#
#   make              builds every platform into build/<platform>/
#   make mac          builds one (mac, linux, windows, web, ios, android)
#   make run-mac      builds it and runs it (run-web, run-ios, run-android …)
#   make clean        removes build/
#
# Every knob is a variable, so it can be set on the command line:
#
#   make OPT=-O0 FLAGS=-g mac        a debuggable macOS build
#   make XCC=/opt/xcc/0.74/bin/xcc   a particular compiler
#   make IOS=ios ios                 the iOS device rather than the simulator

# ── The knobs ──────────────────────────────────────────────────────────────
# The compiler: xcc on the PATH, or a full path to one.
XCC   ?= xcc
# Optimisation: -O0 (the fastest build) to -O3 (the fastest code).
OPT   ?= -O3
# Anything else: -g for debug information, -static, -q, -Wanalyze …
FLAGS ?=
# ios-sim (the simulator) or ios (a device, which needs signing).
IOS   ?= ios-sim

# The program. The outputs are build/<platform>/hello, hello.exe, hello.wasm …
NAME  := hello
SRC   := hello.xc
BUILD := build

# ── The targets ────────────────────────────────────────────────────────────
# One rule per platform. `-A` picks the target; everything else is the same
# command, so the platforms differ only in their file names.
.PHONY: all mac linux windows web ios android clean help \
        run-mac run-linux run-windows run-web run-ios run-android

all: mac linux windows web ios android

mac:     $(BUILD)/mac/$(NAME)
linux:   $(BUILD)/linux/$(NAME)
windows: $(BUILD)/windows/$(NAME).exe
web:     $(BUILD)/web/$(NAME).wasm
ios:     $(BUILD)/ios/$(NAME)
android: $(BUILD)/android/$(NAME).apk

# macOS, Apple silicon: a Mach-O executable.
$(BUILD)/mac/$(NAME): $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A arm64 $(OPT) $(FLAGS) -o $@ $<

# Linux x86_64: an ELF executable linked against glibc. FLAGS=-static gives a
# self-contained musl binary that runs on any Linux.
$(BUILD)/linux/$(NAME): $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A x86_64 $(OPT) $(FLAGS) -o $@ $<

# Windows x64: a console .exe.
$(BUILD)/windows/$(NAME).exe: $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A win64 $(OPT) $(FLAGS) -o $@ $<

# The web: hello.wasm, with hello.js (a runner for node and the browser) and
# hello.html (a page that loads it) written beside it. The page is written
# once and left alone by later builds, so it can be edited.
$(BUILD)/web/$(NAME).wasm: $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A wasm32 $(OPT) $(FLAGS) -o $@ $<

# iOS: a Mach-O executable for the simulator (IOS=ios-sim) or a device
# (IOS=ios). A device build must be signed before it runs: see xcc-sign.
$(BUILD)/ios/$(NAME): $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A $(IOS) $(OPT) $(FLAGS) -o $@ $<

# Android: a signed .apk whose activity runs main and sends its output to
# logcat under the tag "xcapp". (Without --emit-apk, -A android gives an ELF
# executable for `adb shell`.)
$(BUILD)/android/$(NAME).apk: $(SRC)
	@mkdir -p $(@D)
	$(XCC) -A android --emit-apk $(OPT) $(FLAGS) -o $@ $<

# ── Running ────────────────────────────────────────────────────────────────
run-mac: mac
	$(BUILD)/mac/$(NAME)

# On a Linux machine. From a Mac, copy build/linux/hello there first.
run-linux: linux
	$(BUILD)/linux/$(NAME)

# On Windows, or anywhere Wine is installed.
run-windows: windows
	wine $(BUILD)/windows/$(NAME).exe

# node runs hello.js; a browser opens hello.html.
run-web: web
	node $(BUILD)/web/$(NAME).js

# A booted iPhone simulator (Xcode: xcrun simctl boot "iPhone 16").
run-ios: ios
	xcrun simctl spawn booted $(BUILD)/ios/$(NAME)

# A device or emulator visible to adb. The package is org.compile_xc.<name>.
run-android: android
	adb install -r $(BUILD)/android/$(NAME).apk
	adb logcat -c
	adb shell am start -n org.compile_xc.$(NAME)/android.app.NativeActivity
	sleep 2
	adb logcat -d -s xcapp

clean:
	rm -rf $(BUILD)

help:
	@echo "targets: all mac linux windows web ios android, run-<platform>, clean"
	@echo "knobs:   XCC=$(XCC) OPT=$(OPT) FLAGS=$(FLAGS) IOS=$(IOS)"
