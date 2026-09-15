#!/bin/sh
# Compile-and-run smoke test for the xcc-cg-68k backend + xta68 assembler.
# Compiles each .xc program to a GEMDOS $601A and checks its exit code
# (main()'s return value, via the crt0 Pterm) under sim68k (xst).
#
#   sh tests/68k/compile_run.sh
#
# Programs and their expected exit codes live in the `cases` list below.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
XTC="$ROOT/bin/osx/xcc"
XST="$ROOT/bin/osx/xcc-sim-68k"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# "source-file expected-exit [cpu]"
cases='ret42.xc:42 arith.xc:32 arith.xc:32:68030
       loopsum.xc:15 ifelse.xc:3 while.xc:45 fact.xc:120:68030
       muldiv.xc:196 fact.xc:120 struct_array.xc:54 class_stack.xc:3
       heap_class.xc:42 virtual.xc:36 multiret.xc:103 float_arith.xc:10:68030 float_cmp.xc:3:68030'

fail=0
for c in $cases; do
    src=${c%%:*}; rest=${c#*:}; want=${rest%%:*}; cpu=${rest#*:}
    [ "$cpu" = "$rest" ] && arch=m68k || arch=$cpu
    "$XTC" -mhard-float -A "$arch" "$(dirname "$0")/$src" -o "$TMP/out.prg" >/dev/null 2>&1
    "$XST" "$TMP/out.prg" >/dev/null 2>&1 && got=0 || got=$?
    if [ "$got" = "$want" ]; then
        echo "ok   $src (-A $arch) -> exit $got"
    else
        echo "FAIL $src (-A $arch) -> exit $got, expected $want"; fail=1
    fi
done

# Output cases: "source-file|arch|expected-stdout"
out_cases='putc.xc|m68k|Hi
strloop.xc|m68k|Hello, ST!
print_str.xc|m68k|Hi
print_int.xc|68030|Answer: 42
print_int.xc|m68k|Answer: 42
printf.xc|68030|Value = 42, hex = 00FF!
printf.xc|m68k|Value = 42, hex = 00FF!
sdiv.xc|m68k|q=-14 r=-2
dealloc.xc|m68k|freed'

IFS='
'
for c in $out_cases; do
    src=$(echo "$c" | cut -d'|' -f1); arch=$(echo "$c" | cut -d'|' -f2)
    want=$(echo "$c" | cut -d'|' -f3)
    "$XTC" -mhard-float -A "$arch" "$(dirname "$0")/$src" -o "$TMP/o.prg" >/dev/null 2>&1
    got=$("$XST" -d "$TMP/o.prg" 2>/dev/null | tr -d '\r\n')
    if [ "$got" = "$want" ]; then
        echo "ok   $src (-A $arch) -> \"$got\""
    else
        echo "FAIL $src (-A $arch) -> \"$got\", expected \"$want\""; fail=1
    fi
done
exit $fail
