---
title: "Guide: one program, six platforms, from Windows (tutorial)"
description: "Step by step: a PowerShell script that builds a Hello world program for Windows, macOS, Linux, the web, iOS and Android from a Windows PC, with every flag a parameter."
---

This tutorial builds one program for six platforms from a Windows PC. It is
the Windows version of
[One program, six platforms, with Make](/tutorials/cross-build-make/): the same
program and the same build, with a PowerShell script where that tutorial has a
Makefile, because Windows has PowerShell and does not have Make. It takes
about ten minutes. The files are in the repository under
`compiler/examples/tutorials/hello/`.

You need xcc 0.74 or later, unpacked from `xcc-win64-<version>.zip`, and
PowerShell, which every Windows has. Nothing else: xcc carries every target's
runtime and linker, so the PC builds the macOS, Linux, web, iOS and Android
programs without another toolchain. To *run* what you build you need the
platform, which is covered in step 4.

## 1. Write the program

Make a folder, `hello`, and put the program in it:

```c
// hello\hello.xc
#import <Stdio.xc>

i32 main(void)
{
    Stdio.printf("Hello world!\n");
    return 0;
}
```

This is the whole program for every platform.

## 2. Write the build script

Put this beside it as `hello\build.ps1`:

```powershell
# build.ps1 — one program, six platforms, from Windows.
#
#   .\build.ps1                 builds every platform into build\<platform>\
#   .\build.ps1 windows         builds one (mac, linux, windows, web, ios, android)
#   .\build.ps1 windows -Run    builds it and runs it (windows and web run here)
#   .\build.ps1 clean           removes build\
#
# Every knob is a parameter, so it can be set on the command line:
#
#   .\build.ps1 windows -Opt -O0 -Flags -g               a debuggable Windows build
#   .\build.ps1 -Xcc C:\xcc\xcc-win64-0.74\bin\xcc.exe   a particular compiler
#   .\build.ps1 ios -Ios ios                             the iOS device, not the simulator
#
# If PowerShell refuses to run scripts: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

param(
    # The platforms to build: any of mac linux windows web ios android, all, clean.
    [string[]] $Targets = @('all'),
    # The compiler: xcc on the PATH, or a full path to one.
    [string] $Xcc   = 'xcc',
    # Optimisation: -O0 (the fastest build) to -O3 (the fastest code).
    [string] $Opt   = '-O3',
    # Anything else: -g for debug information, -static, -q, -Wanalyze …
    [string] $Flags = '',
    # ios-sim (the simulator) or ios (a device, which needs signing).
    [string] $Ios   = 'ios-sim',
    # Run the program after building it (windows and web run on this machine).
    [switch] $Run
)

$ErrorActionPreference = 'Stop'

# The program. The outputs are build\<platform>\hello, hello.exe, hello.wasm …
$Name  = 'hello'
$Src   = 'hello.xc'
$Build = 'build'

# One entry per platform: the -A target, the output file, and how to run it.
$Platforms = @{
    mac     = @{ Arch = 'arm64';   Out = "$Name";      Run = $null }
    linux   = @{ Arch = 'x86_64';  Out = "$Name";      Run = $null }
    windows = @{ Arch = 'win64';   Out = "$Name.exe";  Run = { & $args[0] } }
    web     = @{ Arch = 'wasm32';  Out = "$Name.wasm"; Run = { node ($args[0] -replace '\.wasm$', '.js') } }
    ios     = @{ Arch = $Ios;      Out = "$Name";      Run = $null }
    android = @{ Arch = 'android'; Out = "$Name.apk";  Run = $null; Extra = '--emit-apk' }
}

function Build-Platform([string] $Platform) {
    $p   = $Platforms[$Platform]
    $dir = Join-Path $Build $Platform
    New-Item -ItemType Directory -Force $dir | Out-Null
    $out = Join-Path $dir $p.Out
    # The same command for every platform: -A picks the target. $Flags may
    # hold several flags ("-g -Wanalyze"), so it is split into words.
    $cmd = @($Xcc, '-A', $p.Arch) + @(@($p.Extra, $Opt) + ($Flags -split ' ') | Where-Object { $_ }) + @('-o', $out, $Src)
    Write-Host ($cmd -join ' ')
    & $cmd[0] $cmd[1..($cmd.Count - 1)]
    if ($LASTEXITCODE -ne 0) { throw "${Platform}: xcc failed" }
    if ($Run) {
        if ($p.Run) { & $p.Run $out }
        else { Write-Host "${Platform}: built $out; run it on that platform (see the Makefile's run-$Platform)" }
    }
}

foreach ($t in $Targets) {
    switch ($t) {
        'all'   { foreach ($k in 'mac', 'linux', 'windows', 'web', 'ios', 'android') { Build-Platform $k } }
        'clean' { if (Test-Path $Build) { Remove-Item -Recurse -Force $Build } }
        default {
            if (-not $Platforms.ContainsKey($t)) { throw "unknown target '$t': mac linux windows web ios android all clean" }
            Build-Platform $t
        }
    }
}
```

It has the same shape as the Makefile:

- **The knobs are parameters.** `-Xcc`, `-Opt`, `-Flags` and `-Ios` have the
  defaults in `param(...)` and take a value on the command line, so
  `.\build.ps1 windows -Opt -O0 -Flags -g` builds a debuggable program
  without editing anything.
- **One table entry per platform, and one command.** `$Platforms` holds each
  platform's `-A` target and output name; `Build-Platform` runs the same xcc
  command for every one of them. Each output has its own directory,
  `build\<platform>\`, so the six builds never overwrite each other and
  `clean` is one line.
- **`-Run` says how each output is run.** Windows and web programs run on the
  PC; for the others the script says where to take the file.

## 3. Build everything

```powershell
cd hello
.\build.ps1 -Xcc C:\xcc\xcc-win64-0.74\bin\xcc.exe
```

```
C:\xcc\xcc-win64-0.74\bin\xcc.exe -A arm64 -O3 -o build\mac\hello hello.xc
C:\xcc\xcc-win64-0.74\bin\xcc.exe -A x86_64 -O3 -o build\linux\hello hello.xc
C:\xcc\xcc-win64-0.74\bin\xcc.exe -A win64 -O3 -o build\windows\hello.exe hello.xc
C:\xcc\xcc-win64-0.74\bin\xcc.exe -A wasm32 -O3 -o build\web\hello.wasm hello.xc
C:\xcc\xcc-win64-0.74\bin\xcc.exe -A ios-sim -O3 -o build\ios\hello hello.xc
C:\xcc\xcc-win64-0.74\bin\xcc.exe -A android --emit-apk -O3 -o build\android\hello.apk hello.xc
```

With xcc's `bin` folder on your `PATH`, `-Xcc` can be left out. If PowerShell
refuses to run the script, allow local scripts once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

What each platform produced:

| Target | Output | What it is |
| --- | --- | --- |
| `windows` | `build\windows\hello.exe` | a console program |
| `mac` | `build\mac\hello` | a Mach-O executable for Apple silicon |
| `linux` | `build\linux\hello` | an ELF executable, linked against glibc |
| `web` | `build\web\hello.wasm`, `hello.js`, `hello.html` | the module, a runner for node and the browser, and a page that loads it |
| `ios` | `build\ios\hello` | a Mach-O executable for the iOS simulator |
| `android` | `build\android\hello.apk` | a signed, installable app |

:::note[Android on Windows, 0.74]
In 0.74 the Android build fails on Windows with "cannot create a signing key":
the key generator reads `/dev/urandom`, which Windows does not have. Fixed in
0.75. Until then build the APK on a Mac or Linux machine, or pass a key made
there with `-Flags "--sign-key C:\path\android-debug.key.raw"`.
:::

## 4. Run each one

| Command | Where | What you see |
| --- | --- | --- |
| `.\build.ps1 windows -Run` | this PC | `Hello world!` |
| `.\build.ps1 web -Run` | this PC, with node installed | `Hello world!`; or open `build\web\hello.html` in a browser |
| `build\mac\hello` | a Mac, after copying the file to it | `Hello world!` |
| `build\linux\hello` | a Linux machine, after copying the file to it | `Hello world!` |
| `xcrun simctl spawn booted hello` | a Mac with a booted iPhone simulator | `Hello world!` |
| `adb install -r hello.apk`, then `adb shell am start -n org.compile_xc.hello/android.app.NativeActivity` | a device or emulator visible to `adb` | `Hello world!` in `adb logcat -s xcapp` |

## 5. Turn the knobs

```powershell
.\build.ps1 windows -Opt -O0 -Flags -g      # a debuggable build for gdb or lldb
.\build.ps1 linux -Flags -static            # a musl binary that runs on any Linux
.\build.ps1 all -Opt -O0                    # the quickest builds while iterating
.\build.ps1 ios -Ios ios                    # the iOS device; sign it with xcc-sign on a Mac
.\build.ps1 clean                           # start again
```

## 6. Where to go next

- A program with several source files: make `$Src` a list and splat it into
  the command (`+ $Src` in place of `, $Src`).
- A graphical program on every platform: [Hello UX](/tutorials/hello-ux/)
  does the same thing with a window, using UXKit.
- Every flag the commands above could take is in the
  [CLI flag reference](/compiler/usage/cli/).
