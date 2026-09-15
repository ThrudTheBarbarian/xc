#!/bin/bash
# i64/u64 across every live target, at -O0 and -O3.
#
# All three fixtures live in tests/fixtures/ now, so the corpus and all 21
# self-host differentials cover them. They stay wired in here too, because this
# runner is the only thing that RUNS them on m68k, arm9 and xt6502 — the
# differentials compare assembly text and never execute it.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -d "$BIN" ] || BIN=bin/linux
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SRC=tests/fixtures/int64_arith.xc
WANT=tests/fixtures/int64_arith.expected.out
fail=0

for O in 0 1 2 3; do
    if ! "$BIN/xcc" -O$O -A arm64 -H . -o "$TMP/a" "$SRC" >"$TMP/log" 2>&1; then
        echo "  FAIL arm64 -O$O: compile"; sed 's/^/    /' "$TMP/log"; fail=1; continue
    fi
    if diff -q <("$TMP/a") "$WANT" >/dev/null 2>&1; then echo "  PASS arm64 -O$O"
    else echo "  FAIL arm64 -O$O"; diff <("$TMP/a") "$WANT" | sed 's/^/    /'; fail=1; fi
done

# x86_64 runs on the Linux box; win64 under wine. Both are skipped, loudly,
# when the host is unavailable — a skip is not a pass.
if "$BIN/xcc" -A x86_64 -H . -o "$TMP/x" "$SRC" >"$TMP/log" 2>&1; then
    if [ -n "${XTC_LINUX_HOST:-}" ] && scp -q "$TMP/x" "$XTC_LINUX_HOST:/tmp/xtc-i64" 2>/dev/null &&
       ssh "$XTC_LINUX_HOST" 'chmod +x /tmp/xtc-i64 && /tmp/xtc-i64' > "$TMP/xout" 2>/dev/null; then
        if diff -q "$TMP/xout" "$WANT" >/dev/null; then echo "  PASS x86_64"
        else echo "  FAIL x86_64"; diff "$TMP/xout" "$WANT" | sed 's/^/    /'; fail=1; fi
    else echo "  SKIP x86_64 (XTC_LINUX_HOST unset or unreachable — NOT a pass)"; fi
else echo "  FAIL x86_64: compile"; sed 's/^/    /' "$TMP/log"; fail=1; fi

if "$BIN/xcc" -A win64 -H . -o "$TMP/w.exe" "$SRC" >"$TMP/log" 2>&1; then
    if [ -x /opt/homebrew/bin/wine ]; then
        if diff -q <(/opt/homebrew/bin/wine "$TMP/w.exe" 2>/dev/null) "$WANT" >/dev/null; then echo "  PASS win64"
        else echo "  FAIL win64"; fail=1; fi
    else echo "  SKIP win64 (no wine — NOT a pass)"; fi
else echo "  FAIL win64: compile"; sed 's/^/    /' "$TMP/log"; fail=1; fi

# The full operation set — add/sub/mul/div/mod and all three shifts, signed and
# unsigned — on every target that implements 64-bit arithmetic. xt6502 included:
# its runtime does this in software, and the answers must match arm64 exactly.
# Two fixtures, both in tests/fixtures/ so the corpus and the 21 differentials
# also see them. int64_ops covers the ARITHMETIC; int64_cmp covers moving and
# testing a 64-bit value — comparisons, a loop-carried phi, signed widening —
# which is a different set of bugs on every target.
#
# Every target runs BOTH. The arm9 line filter is per-fixture because that
# harness has to pick the program's output out of a shell transcript.
FIXTURES="ops cmp arith dphi"
ops_SRC=tests/fixtures/int64_ops.xc
ops_WANT=tests/fixtures/int64_ops.expected.out
ops_RE='^(shl|shr|add|sub|mul|div|mod|sar|ndiv|nmod) '
cmp_SRC=tests/fixtures/int64_cmp.xc
cmp_WANT=tests/fixtures/int64_cmp.expected.out
cmp_RE='^(s_|u_|sext|dig)'
arith_SRC=tests/fixtures/int64_arith.xc
arith_WANT=tests/fixtures/int64_arith.expected.out
arith_RE='^(2\^40|10\^12|sub|div|mod|and|neg|cmp)'
# Not an i64 fixture, but this is the only harness that RUNS anything on all six
# targets, and a double phi is the same eight-bytes-in-a-slot shape that i64
# turned up — same bug, same two back ends.
dphi_SRC=tests/fixtures/double_phi.xc
dphi_WANT=tests/fixtures/double_phi.expected.out
dphi_RE='^(tern_|loop_|nest_|dptr|darr|uptr|uarr|vararg)'

for F in $FIXTURES; do
  eval "SRC=\$${F}_SRC; WANT=\$${F}_WANT; RE=\$${F}_RE"

  for O in 0 3; do
    if "$BIN/xcc" -O$O -A arm64 -H . -o "$TMP/p" "$SRC" >"$TMP/log" 2>&1; then
        if diff -q <("$TMP/p") "$WANT" >/dev/null; then echo "  PASS $F arm64 -O$O"
        else echo "  FAIL $F arm64 -O$O"; diff <("$TMP/p") "$WANT" | sed 's/^/    /'; fail=1; fi
    else echo "  FAIL $F arm64 -O$O: compile"; sed 's/^/    /' "$TMP/log"; fail=1; fi
  done

  for O in 0 3; do
    if "$BIN/xcc" -O$O -A 6502 -H . -o "$TMP/p.xex" "$SRC" >"$TMP/log" 2>&1; then
        # xts puts the trace on stderr and the program's output on stdout.
        if diff -q <("$BIN/xcc-sim-6502" -m xt -d "$TMP/p.xex" 2>/dev/null) "$WANT" >/dev/null; then
            echo "  PASS $F xt6502 -O$O"
        else
            echo "  FAIL $F xt6502 -O$O"
            diff <("$BIN/xcc-sim-6502" -m xt -d "$TMP/p.xex" 2>/dev/null) "$WANT" | sed 's/^/    /'; fail=1
        fi
    else echo "  FAIL $F xt6502 -O$O: compile"; sed 's/^/    /' "$TMP/log"; fail=1; fi
  done

  # m68k — xst is in this repo, so this needs nothing external.
  for O in 0 3; do
    if "$BIN/xcc" -O$O -A m68k -H . -o "$TMP/p.prg" "$SRC" >"$TMP/log" 2>&1; then
        if diff -q <("$BIN/xcc-sim-68k" "$TMP/p.prg" 2>/dev/null) "$WANT" >/dev/null; then
            echo "  PASS $F m68k -O$O"
        else
            echo "  FAIL $F m68k -O$O"
            diff <("$BIN/xcc-sim-68k" "$TMP/p.prg" 2>/dev/null) "$WANT" | sed 's/^/    /'; fail=1
        fi
    else echo "  FAIL $F m68k -O$O: compile"; sed 's/^/    /' "$TMP/log"; fail=1; fi
  done

  # arm9 — needs the XTOS loader kernel (`make hosttest` in the loader, and
  # XTC_ARM9_SYSROOT in build.env). It must be freertos-hosttest.elf, NOT
  # freertos.elf, which hangs.
  # Absent → SKIP, loudly: an unrunnable target is not a passing one.
  A9SYS=${XTC_ARM9_SYSROOT:-}
  A9KERNEL="$A9SYS/freertos-hosttest.elf"
  if [ -f "$A9KERNEL" ] && command -v qemu-system-arm >/dev/null; then
    for O in 0 3; do
        if "$BIN/xcc" -O$O -A arm9 -L "$A9SYS" -H . -o "$TMP/p.so" "$SRC" >"$TMP/log" 2>&1; then
            printf 'runhost %s\nexit\n' "$TMP/p.so" | \
              timeout 180 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
                -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
                -kernel "$A9KERNEL" > "$TMP/qemu.out" 2>/dev/null
            # The program's output is embedded in the shell transcript, and the
            # FIRST line shares a line with the `xtos$ ` prompt — so strip the
            # prompt before matching rather than anchoring at ^, which silently
            # dropped the first line and reported the rest as a diff.
            sed -e 's/^xtos\$ //' "$TMP/qemu.out" | grep -aE "$RE" > "$TMP/a9.out" || true
            # Liveness is "did any line arrive", NOT "is one of them right": the
            # old gate keyed off a correct answer, so a wrong result and a
            # program that never ran reported identically.
            if [ ! -s "$TMP/a9.out" ]; then
                echo "  FAIL $F arm9 -O$O: no output from the loader"; fail=1
            elif diff -q "$TMP/a9.out" "$WANT" >/dev/null 2>&1; then
                echo "  PASS $F arm9 -O$O"
            else
                echo "  FAIL $F arm9 -O$O"
                diff "$TMP/a9.out" "$WANT" | sed 's/^/    /'; fail=1
            fi
        else echo "  FAIL $F arm9 -O$O: compile"; sed 's/^/    /' "$TMP/log"; fail=1; fi
    done
  else
    echo "  SKIP arm9 (no $A9KERNEL or qemu — NOT a pass)"
  fi
done

[ $fail = 0 ] && echo "int64: all pass" || echo "int64: FAILURES"
exit $fail
