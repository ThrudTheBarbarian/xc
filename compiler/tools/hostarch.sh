# hostarch.sh — resolve the host's own native target and binary directory.
#
#   . tools/hostarch.sh        (from the compiler root)
#   . "$ROOT/tools/hostarch.sh"
#
# Sets, without exporting anything the caller did not ask for:
#
#   XC_BIN        the built-binary directory, RELATIVE to the compiler root:
#                 `bin/osx` on macOS, `bin/linux` on Linux. Relative so it
#                 composes both ways — bare `$XC_BIN/xcc` for the scripts that
#                 cd to the root, and `"$ROOT/$XC_BIN/xcc"` for the ones that
#                 keep an absolute root.
#
#   XC_HOST_ARCH  the `-A` target that is NATIVE to this host: `arm64` on Apple
#                 Silicon, `x86_64` on Linux x86-64. This is the value the
#                 harnesses want wherever they compile something and then RUN
#                 it — the host arch is incidental to what they test, and was
#                 hardcoded rather than required.
#
# POSIX sh on purpose: several callers are `#!/bin/sh`, and a sourced file
# cannot use BASH_SOURCE portably. So this deliberately does NOT try to locate
# the compiler root itself — callers already know where they are, because they
# already reach for `support/...` and `tests/fixtures/...` relatively.
#
# WHY THIS EXISTS
# ---------------
# private:docs/Design/ci.md, "33 of the 43 harnesses cannot run on x86_64 as written":
# they compile with `-A arm64` and then execute the result, which on an x86_64
# host is a cross-compile to arm64 Mach-O that cannot be run. The refactor is
# provable BEFORE the Linux box is involved, because on an arm64 Mac every
# value below resolves to exactly the literal it replaced — so a full gate that
# comes back byte-identical is proof the substitution is correct.
#
# What this does NOT do, and must not: turn a deliberately arm64-TARGETED
# harness into a host-targeted one. `-A arm64` means two different things in
# this tree — "the host, so I can run it" and "the arm64 back end, which is
# what I am testing". Only the first kind becomes $XC_HOST_ARCH. The second
# stays `arm64` and stays on the Mac side of the split gate.

case "$(uname -s)" in
    Darwin) XC_BIN=bin/osx   ;;
    *)      XC_BIN=bin/linux ;;
esac

# uname -m spells the same ISA differently per OS: `arm64` on Darwin, `aarch64`
# on Linux. Normalise to the names the -A flag actually accepts (the backend
# set is arm64, android, xt6502, m68k, wasm32, x86_64, win64, arm9).
case "$(uname -m)" in
    arm64|aarch64) XC_HOST_ARCH=arm64  ;;
    x86_64|amd64)  XC_HOST_ARCH=x86_64 ;;
    *)
        echo "hostarch.sh: unsupported host $(uname -s)/$(uname -m) — no native" \
             "-A target for it; set XC_HOST_ARCH yourself if you know better" >&2
        XC_HOST_ARCH=""
        ;;
esac

# An override, so a harness can be pinned without editing it — useful when
# bisecting a host-specific failure, and when a Linux host wants to check the
# arm64 path still BUILDS even though it cannot run it.
if [ -n "${XC_HOST_ARCH_OVERRIDE:-}" ]; then XC_HOST_ARCH="$XC_HOST_ARCH_OVERRIDE"; fi
if [ -n "${XC_BIN_OVERRIDE:-}" ];       then XC_BIN="$XC_BIN_OVERRIDE"; fi

# Return success, explicitly. `[ ... ] && x=y` as the last statement of a sourced
# file leaves the file's status at 1 whenever the test is false, and almost every
# caller here runs under `set -e` — so that alone would kill 89 harnesses. This
# colon is load-bearing; do not drop it.
:
