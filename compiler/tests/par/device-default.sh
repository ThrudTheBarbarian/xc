#!/bin/bash
# device-default.sh — a block's :device(…) default (owner 2026-10-31)
#
# `par name :device(cpu|gpu|gpus|all|auto) { … }` is the developer's DEFAULT
# device. The order, highest first: XC_PAR, the user's setting (par.<name>),
# the program's Par.device, the block's :device, auto. Checked with answers
# that hold on any machine: tests/fixtures/par_device_default.xc (a
# :device(cpu) block runs on the CPU; Par.device(…, "cpu") outranks
# :device(gpu)) built by both compilers for the host, which must write the same assembly;
# the user's `par.usr = cpu` outranks a block's :device(gpu); and auto does
# not measure a block with a :device default (no measuring in its report).
#
#   bash tests/par/device-default.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_device_default.xc
fail=0
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 || { echo "FAIL device-default: $(basename "$c") does not compile it: $(head -c 200 "$W/e")"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL device-default: the two compilers' assembly differs"; fail=1; }; }
"$XC" -q -O2 -o "$W/p" "$F" > "$W/e" 2>&1 || { echo "FAIL device-default: no build: $(head -c 200 "$W/e")"; exit 1; }
mkdir -p "$W/st0"
XCC_SETTINGS_DIR="$W/st0" "$W/p" > "$W/out" 2>&1
cmp -s "$W/out" tests/fixtures/par_device_default.expected.out || { echo "FAIL device-default: the fixture prints: $(head -c 200 "$W/out")"; fail=1; }
cat > "$W/usr.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 65536
u32 out[N];
i32 main(void)
    {
    par usr :device(gpu)
        {
        for (u32 i in 0..(u32)N)
            out[i] = i * (u32)3;
        }
    Array* on = Par.ranOn("usr");
    Stdio.printf("%s %u\n", on.count() > (u32)0 ? ((String*)on.get((u32)0)).cString() : "-", out[(u32)(N - 1)]);
    for (u32 rep = (u32)0; rep < (u32)6; rep = rep + (u32)1)
        {
        par quiet :device(cpu)
            {
            for (u32 i in 0..(u32)N)
                out[i] = out[i] + (u32)1;
            }
        }
    return (i32)0;
    }
XC
"$XC" -q -O2 -o "$W/usr" "$W/usr.xc" > "$W/e" 2>&1 || { echo "FAIL device-default: the user-setting program does not build: $(head -c 200 "$W/e")"; exit 1; }
mkdir -p "$W/st"
printf 'par.usr = cpu\n' > "$W/st/usr.conf"
got=$(XCC_SETTINGS_DIR="$W/st" "$W/usr" 2>&1 | head -1)
[ "$got" = "cpu 196605" ] || { echo "FAIL device-default: par.usr = cpu over :device(gpu) gave '$got'"; fail=1; }
# auto does not measure a block with a default: no measuring lines for it.
mkdir -p "$W/st2"
XCC_SETTINGS_DIR="$W/st2" XC_PAR_REPORT=1 "$W/usr" > "$W/rep" 2>&1
if grep -i 'quiet' "$W/rep" | grep -qiE 'measur|us on (the )?(gpu|cpu|all)'; then
    echo "FAIL device-default: auto measured a block with a :device default:"; grep -i quiet "$W/rep" | head -3; fail=1
fi
[ $fail = 0 ] && echo "device-default: ok"
exit $fail
