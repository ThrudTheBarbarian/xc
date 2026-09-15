#!/bin/bash
# a9-run.sh — build with the ported toolchain and RUN it on the A9.
# =================================================================
#
# The end of the chain: every fixture in tests/asm-arm32 built by
# selfhost/ alone and run under the XTOS loader on qemu, its output compared
# with what the fixture says it should print.
#
#   bash selfhost/tools/a9-run.sh
#
# A missing qemu or loader kernel is reported, not skipped silently — a sweep
# that passes because it ran nothing is the worst kind.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -u
cd "$(dirname "$0")/../.." || exit 1
SYSROOT=${XTC_ARM9_SYSROOT:-}
KERNEL=$SYSROOT/freertos-hosttest.elf
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

command -v qemu-system-arm >/dev/null || { echo "!!! qemu-system-arm absent — nothing was run"; exit 1; }
[ -f "$KERNEL" ] || { echo "!!! loader kernel absent ($KERNEL) — nothing was run"; exit 1; }

pass=0; fail=0
for src in tests/asm-arm32/*.xc; do
    [ -e "$src" ] || continue
    name=$(basename "$src" .xc)
    expected="tests/asm-arm32/$name.expected.out"
    [ -f "$expected" ] || continue
    if ! bash selfhost/tools/a9-pure.sh "$src" "$W/$name.so" >"$W/build.log" 2>&1; then
        echo "  $name: build failed"; fail=$((fail+1)); continue
    fi
    cp "$W/$name.so" "/tmp/$name.so"
    printf 'runhost /tmp/%s.so\nexit\n' "$name" > "$W/drive"
    timeout 300 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
        -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
        -kernel "$KERNEL" < "$W/drive" > "$W/out" 2>&1
    # The program's own output is what sits between the shell prompts.
    sed -n 's/^xtos\$ //p' "$W/out" | grep -v '^$' | grep -v '^bye$' > "$W/prog"
    if diff -q "$expected" "$W/prog" >/dev/null 2>&1; then pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "  $name: output differs"
        diff "$expected" "$W/prog" | head -4
    fi
done
echo "--- a9-run: pass=$pass fail=$fail ---"
