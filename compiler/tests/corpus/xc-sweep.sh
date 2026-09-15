#!/usr/bin/env bash
# xc-sweep.sh — the fixture corpus, run through the SELF-HOSTED (xc) compiler.
# =========================================================================
#
# `make corpus` sweeps the fixtures with the ObjC compiler. That is historical:
# for a long time the ObjC compiler was the only one there was. It is now the
# BOOTSTRAP — the thing we ship is the compiler written in xc, and a corpus that
# only exercises the bootstrap says nothing about what ships.
#
# Bug 071 is the argument in one line: the corpus was 479/479 green while the
# self-hosted arm64 back end folded `1 << 32` into `add xD, xN, #0` and silently
# dropped a bignum borrow. The reference was right, so the sweep was right, and
# the SHIPPING compiler was wrong. Only a differential saw it — and a
# differential only covers files somebody thought to write.
#
# So this is the same corpus, same fixtures, same oracles, driven through
# `selfhost/tools/xcc.xc`. It runs in its own working directory (mktemp), which
# is what lets it run CONCURRENTLY with the legacy sweep rather than after it.
#
# Scope: arm64 (the host). The xc driver wires arm64 and android only — every
# other target is refused BY NAME, so there is nothing to sweep there yet. This
# covers the arm64 half of the legacy sweep, not the xt6502 half.
#
#   bash tests/corpus/xc-sweep.sh [substring-filter]
#
# Env: OPT (default 3 — the production level, as `make corpus` uses),
#      JOBS (default 8), TIMEOUT (default 10s per fixture).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

# Host arch and bin dir, rather than the Mac's spelling of both.
# shellcheck disable=SC1091
. tools/hostarch.sh

# What the SWEPT arm64 scope actually compiles to on this host, and how it runs.
#
#   macOS   -A arm64   is native Mach-O; exec it.
#   Linux   -A arm64   is Mach-O and unrunnable, but -A android is the SAME
#                      arm64 backend emitting aarch64 ELF, and qemu runs it.
#
# So the backend under test is identical either way; only the container and the
# launcher differ. XC_ANDROID_SYSROOT overrides where bionic lives.
if [ "$(uname -s)" = Darwin ]; then
    XC_ARM64_SCOPE=arm64
    XC_ARM64_LAUNCH=""
else
    XC_ARM64_SCOPE=android
    XC_ARM64_LAUNCH="qemu-aarch64 -L ${XC_ANDROID_SYSROOT:-/opt/xc-pools/android-sysroot}"
fi
export XC_ARM64_SCOPE XC_ARM64_LAUNCH

# The DRIVER — the xc compiler itself — is a separate question from the fixtures.
# It has to open the file it was asked to compile, and on x86-64 it cannot:
# support/x86_64/runtime/rtgen-linux.s is generated from rt-freestanding.c, which
# has no file layer at all, so the link fails on `_xt_file_size`. (The hosted
# rt.c defines all eight _xt_file_* primitives; the freestanding runtime the
# x86-64 target actually links does not.)
#
# So on Linux the driver is built for ANDROID and run under qemu: that target
# links libxt.c, which does have the file layer. Slower than a native driver,
# and the honest fix is _xt_file_* in the freestanding x86-64 runtime — but this
# runs the real self-hosted compiler over the real corpus today, which nothing
# else here does.
if [ "$(uname -s)" = Darwin ]; then
    XC_DRIVER_ARCH="$XC_HOST_ARCH"
    XC_DRIVER_LIB="support/$XC_HOST_ARCH/lib"
    XC_DRIVER_LAUNCH=""
else
    XC_DRIVER_ARCH=android
    XC_DRIVER_LIB=support/arm64/lib
    XC_DRIVER_LAUNCH="$XC_ARM64_LAUNCH"
fi
export XC_DRIVER_LAUNCH

# ---- the one-fixture worker (re-entrant: xargs calls us back with --one) ----
# Kept in the same file so there is one copy of the compile/run/diff rules.
if [ "${1:-}" = "--one" ]; then
    f="$2"; b="$(basename "$f" .xc)"
    src="$f"
    # //xtc-link: the IR path is single-file, so a companion is MERGED into one
    # unit — strip the caller's prototypes so they don't collide with the
    # companion's definitions. Mirrors XTCorpusSweep's stripFunctionPrototypes.
    comp="$(grep -hoE '//[ ]*xtc-link:[ ]*[A-Za-z0-9_]+' "$f" | head -1 | grep -oE '[A-Za-z0-9_]+$')"
    if [ -n "$comp" ] && [ -f "tests/fixtures/$comp.xc" ]; then
        src="$XCWORK/src/$b.merged.xc"
        { grep -vE '^[A-Za-z_][A-Za-z0-9_@]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^){}]*\)[[:space:]]*;' "$f"
          echo; cat "tests/fixtures/$comp.xc"; } > "$src"
    fi

    if [ "$XCTARGET" = xt6502 ]; then
        # xt6502 is compiled to a XEX and RUN ON THE SIMULATOR. The program's
        # own output is on stdout; the simulator's tracing goes to stderr, so
        # they must not be merged — doing so makes every fixture look like it
        # printed a bank-register banner.
        if ! $XC_DRIVER_LAUNCH "$XCWORK/xcc-xc" -A xt6502 -H . -I support/xt6502/lib -I support/generic/lib \
                "-O$XCOPT" "$src" -o "$XCWORK/bin/$b.xex" > "$XCWORK/log/$b.build" 2>&1 \
           || [ ! -s "$XCWORK/bin/$b.xex" ]; then
            printf 'COMPILE\t%s\n' "$b" > "$XCWORK/res/$b"; exit 0
        fi
        ( cd "$XCWORK/run" && $XCTIMEOUT "$XCSIM" -m xt -d \
              "$XCWORK/bin/$b.xex" > "$XCWORK/out/$b" 2> "$XCWORK/log/$b.sim" )
        rc=$?
        # The simulator surfaces the 6502 program's OWN exit code — main's
        # return value — as its process status, so a clean run routinely exits
        # non-zero and rc is not the criterion. A genuine crash is an illegal
        # opcode or an instruction-limit blow-out, which the simulator reports
        # on stderr. Same rule the in-process sweep uses; treating rc!=0 as
        # failure marked string_copy_cstring (which returns 111 and prints the
        # right answer) as broken.
        if [ $rc -ne 124 ]; then
            if grep -qE 'illegal opcode|instruction limit' "$XCWORK/log/$b.sim" 2>/dev/null
                then rc=1; else rc=0; fi
        fi
    else
        if ! $XC_DRIVER_LAUNCH "$XCWORK/xcc-xc" -A "$XC_ARM64_SCOPE" -H . -I support/arm64/lib -I support/generic/lib \
                "-O$XCOPT" "$src" -o "$XCWORK/bin/$b" > "$XCWORK/log/$b.build" 2>&1; then
            printf 'COMPILE\t%s\n' "$b" > "$XCWORK/res/$b"; exit 0
        fi
        if [ ! -x "$XCWORK/bin/$b" ]; then
            printf 'COMPILE\t%s\t(no binary emitted)\n' "$b" > "$XCWORK/res/$b"; exit 0
        fi
        # Run from the work dir, not the repo: no fixture touches the
        # filesystem (checked), so cwd is free and a stray write cannot land
        # in the tree.
        ( cd "$XCWORK/run" && $XCTIMEOUT $XC_ARM64_LAUNCH "$XCWORK/bin/$b" > "$XCWORK/out/$b" 2>&1 )
        rc=$?
    fi
    if [ $rc -eq 124 ]; then printf 'TIMEOUT\t%s\n' "$b" > "$XCWORK/res/$b"; exit 0; fi
    if [ $rc -ne 0 ]; then printf 'RUN\t%s\t(exit %s)\n' "$b" "$rc" > "$XCWORK/res/$b"; exit 0; fi
    if diff -q "tests/fixtures/$b.expected.out" "$XCWORK/out/$b" >/dev/null 2>&1; then
        printf 'PASS\t%s\n' "$b" > "$XCWORK/res/$b"
    else
        printf 'OUTPUT\t%s\n' "$b" > "$XCWORK/res/$b"
    fi
    exit 0
fi

# ---- driver ----------------------------------------------------------------
ONLY="${1:-}"
# TARGET=arm64|xt6502. The xc driver wires arm64, android and xt6502; arm64 is
# the host and xt6502 runs on the simulator, so those two are what a corpus
# sweep can actually EXECUTE and diff.
TARGET="${TARGET:-arm64}"
OPT="${OPT:-3}"
JOBS="${JOBS:-8}"
TIMEOUT="${TIMEOUT:-10}"
BOOT="$XC_BIN/xcc"
# The simulator resolves the same way the compiler does. This was hardcoded to
# bin/osx one line below a BOOT that already handled both, so the xt6502 sweep
# would have died on a Linux runner while the arm64 half ran fine.
SIM="$ROOT/$XC_BIN/xcc-sim-6502"
if [ ! -x "$BOOT" ]; then echo "xc-sweep: no bootstrap compiler at $BOOT — run make"; exit 1; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xcsweep.XXXXXX")"
mkdir -p "$WORK/bin" "$WORK/out" "$WORK/log" "$WORK/res" "$WORK/run" "$WORK/src"
# KEEP=1 leaves the work dir (build logs, generated asm, captured stdout) in
# place. The default cleanup deleted the evidence for 73 failures the first time
# this ran, which made the sweep useless for the one thing it is for.
if [ "${KEEP:-0}" = 1 ]; then trap 'echo "kept: $WORK"' EXIT
else trap 'rm -rf "$WORK"' EXIT; fi

# A timeout that is not assumed: coreutils is not on every machine, and a
# missing `timeout` must not silently become "no timeout" (a hung fixture would
# stall the sweep forever and look like a slow build).
if command -v timeout  >/dev/null 2>&1; then XCTIMEOUT="timeout $TIMEOUT"
elif command -v gtimeout >/dev/null 2>&1; then XCTIMEOUT="gtimeout $TIMEOUT"
else XCTIMEOUT=""; echo "xc-sweep: WARNING — no timeout(1); a hung fixture will stall the sweep"; fi

# The driver is a HOST tool: it has to run here, so it is built for this host's
# own arch, not for arm64 because the Mac happens to be arm64.
echo "building the xc driver (selfhost/tools/xcc.xc → $XC_DRIVER_ARCH)…"
# ...paired with the matching standard library. The two are not interchangeable:
# the arm64 Stdio emits bytes through `_putc`, which the x86-64 runtime does not
# define, so a mismatched pair fails at link with "undefined symbol '_putc'" —
# a long way from the include that caused it.
"$BOOT" -O2 -A "$XC_DRIVER_ARCH" -H . -o "$WORK/xcc-xc" selfhost/tools/xcc.xc \
    -I support/generic/lib -I "$XC_DRIVER_LIB" \
    -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm \
    -I selfhost/link -I selfhost/driver > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xcc-xc" ]; then
    echo "--- xc corpus sweep: BROKEN (the xc driver did not build)"
    sed 's/^/    /' "$WORK/build.log" | head -25
    exit 1
fi

# Is this fixture in scope for the xc compiler on arm64? Same directives the
# in-process harness honours. A fixture ruled out here is NOT a pass and is
# counted apart, so the headline can never be inflated by exclusions.
NA=0; NOORACLE=0; UNSUP=0; LIST="$WORK/list"; : > "$LIST"
for f in tests/fixtures/*.xc; do
    b="$(basename "$f" .xc)"
    [ -n "$ONLY" ] && case "$b" in *"$ONLY"*) ;; *) continue;; esac
    [ -f "tests/fixtures/$b.expected.out" ] || { NOORACLE=$((NOORACLE+1)); continue; }
    grep -qiE '//[ ]*xtc-flags:.*\bskip\b'    "$f" && { NA=$((NA+1)); continue; }
    grep -qiE '//[ ]*xtc-flags:.*expect=sema' "$f" && { NA=$((NA+1)); continue; }
    if [ "$TARGET" = xt6502 ]; then
        if grep -hE '//[ ]*xtc-na:' "$f" | head -1 | grep -qE '\b(6502|xt6502|xt)\b'; then
            NA=$((NA+1)); continue
        fi
        if grep -qE '//[ ]*xtc-flags:.*target=' "$f"; then   # X-only → ours iff X=xt6502
            grep -hE '//[ ]*xtc-flags:.*target=' "$f" | head -1 \
                | grep -qE 'target=(xt6502|6502|xt)\b' || { NA=$((NA+1)); continue; }
        fi
    else
        if grep -hE '//[ ]*xtc-na:' "$f" | head -1 | grep -qE '\b(arm64|x86_64|x86-64)\b'; then
            NA=$((NA+1)); continue
        fi
        if grep -qE '//[ ]*xtc-flags:.*target=' "$f"; then   # X-only → ours iff X=arm64
            grep -hE '//[ ]*xtc-flags:.*target=' "$f" | head -1 | grep -qE 'target=arm64' \
                || { NA=$((NA+1)); continue; }
        fi
    fi
    # Driver features the xc driver does not implement yet. Counted UNSUPPORTED,
    # never skipped silently — the gap is the point of the sweep.
    if grep -qE '//[ ]*xtc-flags:.*--migrate' "$f"; then
        UNSUP=$((UNSUP+1)); echo "$b" >> "$WORK/unsup"; continue
    fi
    echo "$f" >> "$LIST"
done

TOTAL=$(wc -l < "$LIST" | tr -d ' ')
echo "xc corpus sweep [$TARGET]: $TOTAL fixtures, -O$OPT, $JOBS jobs, ${TIMEOUT}s timeout"
export XCWORK="$WORK" XCOPT="$OPT" XCTIMEOUT XCTARGET="$TARGET" XCROOT="$ROOT" XCSIM="$SIM"
xargs -P "$JOBS" -n 1 "$0" --one < "$LIST" > /dev/null 2>&1 || true

# ---- report ----------------------------------------------------------------
cat "$WORK"/res/* 2>/dev/null > "$WORK/all" || : > "$WORK/all"
count() { grep -c "^$1	" "$WORK/all" 2>/dev/null | tr -d ' '; }
P=$(count PASS); C=$(count COMPILE); R=$(count RUN); O=$(count OUTPUT); T=$(count TIMEOUT)
REPORTED=$((P+C+R+O+T))

echo
for s in COMPILE OUTPUT RUN TIMEOUT; do
    n=$(count $s); [ "$n" -eq 0 ] && continue
    echo "--- $s ($n):"
    grep "^$s	" "$WORK/all" | cut -f2- | sed 's/^/    /' | head -20
done
[ "${UNSUP:-0}" -gt 0 ] && { echo "--- UNSUPPORTED by the xc driver ($UNSUP):";
    sed 's/^/    /' "$WORK/unsup" 2>/dev/null; }

# A fixture that produced no result file was never compared. Saying so is the
# whole point: silence must not read as success.
if [ "$REPORTED" -ne "$TOTAL" ]; then
    echo "!! $((TOTAL-REPORTED)) fixture(s) produced NO result — counted as failures, not passes"
fi
pct=0; [ "$TOTAL" -gt 0 ] && pct=$(( P * 1000 / TOTAL ))
echo
echo "=== xc corpus sweep [$TARGET]: $P / $TOTAL pass ($((pct/10)).$((pct%10))%), \
$NA n/a, $UNSUP unsupported, $NOORACLE no-oracle ==="
[ "$P" -eq "$TOTAL" ] && exit 0 || exit 1
