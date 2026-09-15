#!/bin/bash
# run.sh — the cross-module (.so) bound-method test.
#
# NOT part of `make corpus`: it needs the XTOS loader tree and rebuilds the
# hosttest kernel (the loader resolves DT_NEEDED from the romfs, so the library
# has to be baked in). Run it by hand after touching bound methods, weak refs,
# the object header, or the .xtc.iface serializer.
#
# It is the ONLY test that exercises a `^` crossing a module boundary, and every
# bug it covers was invisible to the single-module corpus:
#
#   1. A widened `^` stored by the LIBRARY: the IR guard compares the code word
#      against __bm_tramp_<sig>, but each module has its OWN copy and the loader
#      binds a defined symbol locally (no interposition). The compare failed, the
#      library took the app's FUNCTION POINTER for an object, and wrote the weak
#      chain head into .text.  -> DATA-ABORT (DFAR held an ARM branch encoding).
#   2. `$imported_constants` leaked into the library's public interface, so ANY
#      client importing an xtc library failed to compile.
#   3. `^` types didn't round-trip through .xtc.iface — the imported parameter
#      decoded as VOID, so the caller emitted no trampoline and the `^` crossed
#      with a ZERO code word.  -> PREFETCH-ABORT at PC=0.
#   4. The weak lazy-link gate asked "does MY module use weak?". A library can
#      register a weak ref to an APP object; the app, using no weak refs itself,
#      freed it without zeroing the library's slot.  -> silent dangle.
# Uses a PRIVATE loader build dir (build-xtc). The loader Makefile provides this
# so two builds of the same tree can run at once without racing: sharing one
# build dir means a `make` relinking libc.so while another packs it into a romfs embeds
# a TORN FILE, and every artefact on disk looks fine afterwards because the loser of the
# race rebuilt it. (That is what cost the dropbear/svr_opts night.)
#
# It still RELINKS the hosttest kernel in that private dir, so do not run it concurrently
# with `make corpus` in THIS checkout — for the seconds the .elf is missing, every arm9
# fixture in a running sweep fails with "kernel/libc absent", which reads exactly like a
# 200-fixture compiler catastrophe and is nothing of the kind.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
cd "$(dirname "$0")/../.."
SR="${XTC_ARM9_SYSROOT:-}"
LOADER="$(dirname "$SR")"
XTC=bin/osx/xcc
[ -f "$SR/freertos-hosttest.elf" ] || { echo "SKIP: no loader build at $SR (make -C $LOADER hosttest BUILD=$(basename "$SR"))"; exit 0; }

# Run one .so on the loader and return exactly the program's stdout.
run_prog() {
  printf 'runhost %s\nexit\n' "$1" \
    | timeout 120 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
        -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
        -kernel "$SR/freertos-hosttest.elf" 2>/dev/null \
    | sed -e 's/^xtos\$ *//' \
    | sed -e '/XTOS shell/d' -e '/^bye$/d' -e '/^$/d'
}

TMP=$(mktemp -d)
$XTC -A arm9 --emit-lib -L "$SR" -o "$TMP/libbmlib.so" tests/crossmod/bmlib.xc -q
$XTC -A arm9          -L "$SR" -L "$TMP" -o "$TMP/client.so" tests/crossmod/client.xc -q

# The loader finds DT_NEEDED libs in the romfs (/Library/), so the lib must be
# baked into the kernel.
cp "$TMP/libbmlib.so" "$LOADER/romfs-overlay/Library/"
make -C "$LOADER" hosttest BUILD="$(basename "$SR")" >/dev/null 2>&1

# NB: no `echo __XB__` markers. A private romfs has no /bin/echo (the shared build/
# only had one because other targets had populated it), and the markers then silently
# produced NO output at all — which looked exactly like the program failing.
# The program's output runs from the prompt after `runhost` to the `bye` on exit.
GOT=$(run_prog "$TMP/client.so")

rm -f "$LOADER/romfs-overlay/Library/libbmlib.so"
if [ "$GOT" = "$(cat tests/crossmod/expected.out)" ]; then
  echo "PASS  cross-module bound methods"
else
  echo "FAIL  cross-module bound methods"; echo "--- want:"; cat tests/crossmod/expected.out; echo "--- got:"; echo "$GOT"; rm -f "$LOADER/romfs-overlay/Library/libblib.so" "$LOADER/romfs-overlay/Library/libclib.so"; exit 1
fi

# ── Two INDEPENDENT libraries, and a class conforming to a protocol from each ──
# The case a flat program-global vtable slot cannot express: both number their
# protocols from the same base, because neither can know the other exists.
$XTC -A arm9 --emit-lib -L "$SR" -o "$TMP/libblib.so" tests/crossmod/blib.xc -q
$XTC -A arm9 --emit-lib -L "$SR" -o "$TMP/libclib.so" tests/crossmod/clib.xc -q
$XTC -A arm9 -L "$SR" -L "$TMP" -o "$TMP/twolibs.so" tests/crossmod/twolibs.xc -q
cp "$TMP/libblib.so" "$TMP/libclib.so" "$LOADER/romfs-overlay/Library/"
make -C "$LOADER" hosttest BUILD="$(basename "$SR")" >/dev/null 2>&1

GOT2=$(run_prog "$TMP/twolibs.so")

rm -f "$LOADER/romfs-overlay/Library/libblib.so" "$LOADER/romfs-overlay/Library/libclib.so"
if [ "$GOT2" = "$(cat tests/crossmod/twolibs.expected.out)" ]; then
  echo "PASS  two independent libraries (protocol itable)"
else
  echo "FAIL  two independent libraries (protocol itable)"; echo "--- want:"; cat tests/crossmod/twolibs.expected.out; echo "--- got:"; echo "$GOT2"; exit 1
fi

# ── #9 conformance downcast across a .so: the library downcasts a CLIENT class it
# never saw to an imported protocol (the nib-loader shape). The id comes from the
# protocol name, so a client Widget<Pingable> is recognised; a non-vtable Plain is
# safely rejected (not crashed).
$XTC -A arm9 --emit-lib -L "$SR" -o "$TMP/libdclib.so" tests/crossmod/dclib.xc -q
$XTC -A arm9 -L "$SR" -L "$TMP" -o "$TMP/dcclient.so" tests/crossmod/dcclient.xc -q
cp "$TMP/libdclib.so" "$LOADER/romfs-overlay/Library/"
make -C "$LOADER" hosttest BUILD="$(basename "$SR")" >/dev/null 2>&1

GOT3=$(run_prog "$TMP/dcclient.so")

rm -f "$LOADER/romfs-overlay/Library/libdclib.so"
if [ "$GOT3" = "$(cat tests/crossmod/dc.expected.out)" ]; then
  echo "PASS  conformance downcast (Object@ -> protocol) across a .so"
else
  echo "FAIL  conformance downcast (Object@ -> protocol) across a .so"; echo "--- want:"; cat tests/crossmod/dc.expected.out; echo "--- got:"; echo "$GOT3"; exit 1
fi
