#!/bin/bash
# arm9-quick.sh — fast per-fixture arm9 check (compile -A arm9, run under qemu,
# diff oracle). Usage: arm9-quick.sh <fixture> [<fixture> ...]
# Not a replacement for `make corpus`; a bisection aid.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
cd "$(dirname "$0")/../.." || exit 1
SYS="${XTC_ARM9_SYSROOT:-}"   # a private build dir, so parallel builds do not race
XTC=${XTC:-bin/osx/xcc}      # override to compare against another build (baselining a fix)
# XTC_A9_SELFHOST picks the link path, and BOTH spellings must be explicit:
#   =1  in-house assembler + ELF writer (xcc-ln-arm9)
#   =0  arm-none-eabi-gcc
# unset now means "whatever the driver defaults to", which since #1177 is the
# IN-HOUSE path — so the old `unset == gcc` reading silently compared the
# in-house path against ITSELF and reported the flakiness between two identical
# runs as a toolchain divergence. Default to the explicit gcc leg, since the
# only reason to run this without the variable is to get the oracle.
SELF="--no-self-host"; [ "${XTC_A9_SELFHOST:-0}" = 1 ] && SELF="--self-host"
KERNEL="$SYS/freertos-hosttest.elf"
TMP=$(mktemp -d)
pass=0; fail=0; skip=0
for name in "$@"; do
  src="tests/fixtures/$name.xc"
  [ -f "$src" ] || { echo "SKIP  $name (no fixture)"; skip=$((skip+1)); continue; }
  # directive-driven flags: target restriction / -farc=off
  hdr=$(grep -m1 'xtc-flags:' "$src" || true)
  echo "$hdr" | grep -qE 'target=' && ! echo "$hdr" | grep -qE 'arm9|arm64|both' && { echo "N/A   $name"; skip=$((skip+1)); continue; }
  # `//xtc-na:` is the preferred spelling and the ONLY one the sweep scores on
  # (corpusNASetForSource reads it alone; `target=` is legacy display). Do not
  # tighten the legacy line above into "arm9 and both only": 57 fixtures carry
  # `target=arm64` without excluding arm9, and they run here — heap_length_runtime
  # says so itself, its restriction aims at xt6502's countless array allocator.
  grep -qE '^//[[:space:]]?xtc-na:.*arm9' "$src" && { echo "N/A   $name"; skip=$((skip+1)); continue; }
  arc=""; echo "$hdr" | grep -q 'farc=off' && arc="-farc=off"
  so="$TMP/$name.so"
  if ! $XTC -A arm9 -q $SELF -L "$SYS" $arc "$src" -o "$so" 2>"$TMP/$name.err"; then
    echo "CFAIL $name ($(tail -1 "$TMP/$name.err" | cut -c1-60))"; fail=$((fail+1)); continue
  fi
  exp=""; have_exp=0
  for e in "tests/fixtures/$name.expected.arm9.out" "tests/fixtures/$name.expected.out"; do
    [ -f "$e" ] && { exp=$(sed 's/\r$//' "$e"); have_exp=1; break; }
  done
  # 34 fixtures carry per-backend oracles only — ahl has arm64, atarist and
  # xt6502 oracles but no generic one. Diffing those against an empty string
  # called every one of them a failure; un-oracled is not a result.
  [ "$have_exp" = 1 ] || { echo "NOEXP $name"; skip=$((skip+1)); continue; }
  # Extract between the harness markers, strip the `xtos$ ` prompt echoed on each
  # line, and drop the async `[net] tftpd listening` daemon message (which lands
  # at random times — the main source of arm9-corpus flakiness). Retry once on a
  # mismatch to absorb transient qemu-timeout flakiness (deterministic signal).
  ok=0
  for attempt in 1 2; do
    # No `echo __XB__` markers: `echo` is a romfs PROGRAM, not a shell builtin, and a
    # private loader build has no /bin/echo — the markers silently produce nothing, and
    # every fixture then "fails" while actually having run perfectly.
    out=$(printf 'runhost %s\nexit\n' "$so" | \
      timeout 40 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
      -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
      -kernel "$KERNEL" 2>/dev/null | sed -e '1,/XTOS shell/d' | \
      sed -e ':a' -e 's/^xtos\$ //' -e 'ta' | \
      sed -e '/^bye$/,$d' | grep -v '^\[net\]' | sed 's/\r$//' | sed -e '/^$/d')
    [ "$out" = "$exp" ] && { ok=1; break; }
  done
  if [ "$ok" = 1 ]; then echo "PASS  $name"; pass=$((pass+1))
  else echo "FAIL  $name (got '$(echo "$out"|tr '\n' '|'|cut -c1-40)' want '$(echo "$exp"|tr '\n' '|'|cut -c1-40)')"; fail=$((fail+1)); fi
done
echo "--- pass=$pass fail=$fail skip=$skip ---"
rm -rf "$TMP"
