---
title: Install
description: Where the toolchain goes, how xcc finds its own libraries, and how to run several versions side by side.
---

The toolchain installs into one versioned directory and finds everything else
relative to itself. Put `bin/` on your `PATH`. No environment variable, `-H`, or
`-I` for the standard library is needed.

```bash
make            # build
make install    # -> /opt/xcc/<version>
```

When it finishes, `make install` prints the directory to add to `PATH`.

## Layout

On macOS and Linux the root is `/opt/xcc/$(VERSION)`:

```
/opt/xcc/0.62/
├── bin/
│   ├── xcc              the compiler; it runs every stage itself
│   ├── xcc-sign         code signing
│   ├── xcc-as           6502 assembler
│   ├── xcc-sim-6502     6502 simulator
│   └── xcc-sim-68k      68000 simulator
├── lib/                 shared libraries
│   └── xc/              the support tree: standard library, layouts, runtime
│       ├── generic/lib/     architecture-neutral classes
│       ├── arm64/           arm64 libraries + host runtime
│       ├── xt6502/          6502 libraries, layouts, startup, asm runtime
│       └── arm9-sysroot/    (when present) libc.so etc. for -A arm9
└── …
```

`xcc` parses, optimises, generates code, assembles and links in one process; it
starts no other program. `xcc-sign` signs a finished Mach-O outside a build,
`xcc-as` assembles hand-written 6502 source, and `xcc-sim-6502` and
`xcc-sim-68k` run what you built for those targets.

On **Windows** the default root is `C:\Program Files\xcc`. Windows has no
`bin`/`lib` split, so the binaries sit directly in that directory and the
support tree is in `C:\Program Files\xcc\xc`.

### Changing the root

`PREFIX` picks the root, and the three subdirectories follow from it:

```bash
make install PREFIX=$HOME/opt/xcc-dev
make install PREFIX=/usr/local            # BINDIR=/usr/local/bin, XCDIR=/usr/local/lib/xc
```

You can override `BINDIR`, `LIBDIR` and `XCDIR` individually if your packaging
needs a different layout.

## How `xcc` finds its libraries

On startup `xcc` looks for a **support tree** (the directory holding `generic/`,
`arm64/`, `xt6502/` and the other target directories). It probes each of these
roots in turn for `lib/xc`, then `xc`, then `support`:

1. `-H <path>`
2. `$XCC_HOME`, then the older `$XTC_HOME`
3. **the directory holding the `xcc` binary, and its parent**
4. the current directory, then `~/xcc` and `~/xtc`
5. `/opt/xcc/<version>`, `/opt/xcc`, `/usr/local/xcc`, `/usr/local/xtc`, `/opt/xtc`

Step 3 is what lets a plain `xcc -o prog prog.xc` work. An installed
`/opt/xcc/0.62/bin/xcc` goes up one level and finds `/opt/xcc/0.62/lib/xc`; a
Windows `xcc.exe` finds `xc\` without going up. Neither needs a flag or an
environment variable, and two installed versions never see each other's
libraries.

Because the probe accepts `support/` as well as `lib/xc`, you can also run `xcc`
from a source checkout. It finds the repository's `support/` directory the same
way.

If a build fails with *Cannot find include file*, `-V` prints the resolved
support root and every include path, which usually shows which root
was chosen.

## Several versions at once

The version is part of the path, so several versions can be installed together:

```bash
/opt/xcc/0.62/bin/xcc -o prog prog.xc      # explicit
PATH=/opt/xcc/0.61/bin:$PATH xcc -o prog prog.xc
```

Each binary resolves its own libraries relative to itself, so a 0.62 compiler
never picks up an older release's standard library even when both are on `PATH`.

The problem to watch for is a **stale copy earlier in `PATH`**. An old binary in
`~/bin` is a working compiler, but not the one you built, so its output can look
like a compiler bug. `make uninstall-legacy` removes stray `xcc` copies from
`~/bin`, and `tools/check-install.sh` reports which `xcc` a bare invocation
resolves to.

## Cross-compiling

Nothing extra is installed per target. `xcc` contains the code generators for
all seven live targets, and the support tree carries each
target's libraries.

```bash
xcc -A win64  -o prog.exe prog.xc
xcc -A m68k   -o prog.tos prog.xc
xcc -A 6502   -o prog.xex prog.xc
```

The native targets assemble and link in-house, so no system assembler, linker or
SDK is involved.

`-A arm9` is the exception. It links against the XTOS loader's `libc.so` and reads
the C library out of that file's DWARF, so one extra file has to be reachable.

Either download the [arm9 sysroot archive](/compiler/downloads/) (830 KB), unpack it
and pass `-L path/to/xcc-arm9-sysroot-0.62`; or set `XTC_ARM9_SYSROOT` in `build.env`
to a loader build directory, in which case `make install` copies it into
`lib/xc/arm9-sysroot/` and `-A arm9` needs no `-L` at all. `make install` reports
which of the two happened.

## Uninstalling

```bash
make uninstall                  # remove the installed version
make uninstall-legacy           # remove stray xcc copies from ~/bin
```
