---
title: "Guide: one program, six platforms, with Make (tutorial)"
description: "Step by step: a Makefile that builds a Hello world program for macOS, Linux, Windows, the web, iOS and Android from one machine, with every flag a variable."
---

This tutorial builds one program for six platforms from a Mac or a Linux
machine, with a Makefile short enough to read in a minute. It takes about ten
minutes. The same program and Makefile are in the repository under
`compiler/examples/tutorials/hello/`.

You need xcc 0.74 or later on your `PATH` (or know where it is) and `make`.
Nothing else: xcc carries every target's runtime and linker, so a Mac builds
the Linux, Windows, web, iOS and Android programs without another toolchain.
To *run* what you build you need the platform, which is covered in step 4.

The Windows version of this tutorial, with a PowerShell script in place of
the Makefile, is [One program, six platforms, from Windows](/tutorials/cross-build-windows/).

## 1. Write the program

Make a folder, `hello`, and put the program in it:

```c
// hello/hello.xc
#import <Stdio.xc>

i32 main(void)
{
    Stdio.printf("Hello world!\n");
    return 0;
}
```

This is the whole program for every platform. On a desktop it prints to the
terminal; in a browser the page shows it; on iOS the simulator's console shows
it; on Android it goes to logcat.

## 2. Write the Makefile

Put this beside it as `hello/Makefile`. The tabs at the start of the command
lines matter to Make.

```make
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
```

Three things carry the weight:

- **The knobs are `?=` variables.** `XCC ?= xcc` means "xcc, unless the
  command line or the environment says otherwise", so `make XCC=/opt/xcc/0.74/bin/xcc`
  picks a compiler and `make OPT=-O0 FLAGS=-g mac` builds a debuggable program
  without editing anything. Put a comment above each knob, not after it: Make
  keeps the spaces before a trailing comment as part of the value.
- **One rule per platform, and the rules are the same command.** Only `-A`
  changes. Each output has its own directory, `build/<platform>/`, so six
  builds of `hello` never overwrite each other and `make clean` is one line.
- **`run-<platform>` targets say how each output is run.** They are
  documentation that executes: the way to run the program on each platform is
  in the file, next to the way to build it.

## 3. Build everything

```sh
cd hello
make
```

```
xcc -A arm64 -O3  -o build/mac/hello hello.xc
xcc -A x86_64 -O3  -o build/linux/hello hello.xc
xcc -A win64 -O3  -o build/windows/hello.exe hello.xc
xcc -A wasm32 -O3  -o build/web/hello.wasm hello.xc
xcc -A ios-sim -O3  -o build/ios/hello hello.xc
xcc -A android --emit-apk -O3  -o build/android/hello.apk hello.xc
```

Six programs, a few seconds. `make mac` builds one; a second `make` does
nothing, because every output is newer than `hello.xc`.

What each platform produced:

| Target | Output | What it is |
| --- | --- | --- |
| `mac` | `build/mac/hello` | a Mach-O executable for Apple silicon |
| `linux` | `build/linux/hello` | an ELF executable, linked against glibc |
| `windows` | `build/windows/hello.exe` | a console program |
| `web` | `build/web/hello.wasm`, `hello.js`, `hello.html` | the module, a runner for node and the browser, and a page that loads it |
| `ios` | `build/ios/hello` | a Mach-O executable for the iOS simulator |
| `android` | `build/android/hello.apk` | a signed, installable app |

## 4. Run each one

| Command | Where | What you see |
| --- | --- | --- |
| `make run-mac` | this Mac | `Hello world!` |
| `make run-web` | anywhere with node | `Hello world!`; or open `build/web/hello.html` in a browser |
| `make run-linux` | a Linux machine, after copying `build/linux/hello` to it | `Hello world!` |
| `make run-windows` | a Windows machine, or Wine | `Hello world!` |
| `make run-ios` | a Mac with a booted iPhone simulator | `Hello world!` in the terminal: the simulator runs the program directly |
| `make run-android` | a device or emulator visible to `adb` | `Hello world!` in logcat, under the tag `xcapp` |

The first Android build also prints `generating a debug signing key (once)`:
xcc makes a key under `~/.xcc/` and signs every APK with it from then on.

## 5. Turn the knobs

```sh
make OPT=-O0 FLAGS=-g mac           # a debuggable build: lldb shows lines and variables
make FLAGS=-static linux            # a musl binary that runs on any Linux, no glibc needed
make OPT=-O0 all                    # the quickest builds while iterating
make IOS=ios ios                    # the iOS device; sign it with xcc-sign before installing
make XCC=/opt/xcc/0.74/bin/xcc web  # a particular installed compiler
```

A knob set on the command line applies to that run only. To make one the
default for a project, change the `?=` line in the Makefile, or set it in the
environment (`export OPT=-O3`).

## 6. Where to go next

- A program with several source files: list them in `SRC` and change `$<`
  to `$^` in the rules, so every file is passed to xcc. Each rule's dependency
  list is what makes `make` rebuild only when a source changes.
- A graphical program on every platform: [Hello UX](/tutorials/hello-ux/)
  does the same thing with a window, using UXKit.
- Every flag the commands above could take is in the
  [CLI flag reference](/compiler/usage/cli/); `-g` and the debuggers are on
  the [Debugging](/compiler/usage/debugging/) page.
