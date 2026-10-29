#!/bin/bash
# target-macros.sh — every target predefines its row's ARCH_/OS_/LIBC_/ENV_
# defines, and no other target's, in both compilers (target-table step 3,
# 2026-10-29)
#
# For each target the row's `macros` line (xcc --print-target) is the list
# that must be defined; every other OS_ and LIBC_ name must not be. A source
# that #errors on any miss is compiled to assembly by both drivers.
#
#   bash tests/driver/target-macros.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0; n=0
ALL_OS="OS_macos OS_ios OS_android OS_linux OS_windows OS_xtos OS_web OS_tos OS_xt OS_darwin OS_unix"
ALL_LIBC="LIBC_darwin LIBC_bionic LIBC_glibc LIBC_musl LIBC_msvcrt LIBC_xtos"
printf 'i32 main(i32 argc, u8** argv) { return 0; }\n' > "$W/ret.xc"
for t in arm64-macos arm64-ios arm64-ios-sim arm64-android x86_64-linux x86_64-windows \
         armv7-xtos wasm32-web m68k-tos m68030-tos 6502-xt; do
    want=$("$XC" --print-target -A $t "$W/ret.xc" | sed -n 's/^macros //p')
    { for m in $want; do printf '#if !%s\n#error "%s: %s is not defined"\n#endif\n' "$m" "$t" "$m"; done
      for m in $ALL_OS $ALL_LIBC; do
          case " $want " in *" $m "*) ;; *) printf '#if %s\n#error "%s: %s is defined"\n#endif\n' "$m" "$t" "$m" ;; esac
      done
      cat "$W/ret.xc"; } > "$W/m.xc"
    ext=s; [ $t = 6502-xt ] && ext=xex
    # The reference's arm9 front end needs the device libc another repo
    # carries (flag-parity.sh says the same), so arm9 is the port's alone.
    cs="$REF $XC"; [ $t = armv7-xtos ] && cs="$XC"
    for c in $cs; do
        n=$((n+1))
        "$c" -q -A $t -S -o "$W/m.$ext" "$W/m.xc" > "$W/err" 2>&1 \
            || { echo "FAIL target-macros: $(basename "$c") -A $t: $(grep -m1 error "$W/err")"; fail=1; }
    done
done
[ $fail = 0 ] && echo "target-macros: ok ($n builds)"
exit $fail
