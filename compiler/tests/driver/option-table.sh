#!/bin/bash
# option-table.sh — two drivers read every command line alike (#337).
#
# The option parser moved from an if-chain to a table. This runs every
# spelling in the table (alone, with its value as the next argument, with a
# value joined to it, and as the last argument with no value), plus the
# spellings where two rows can match, through two builds of the driver with
# XC_DUMP_DRIVER_STATE=1, which prints every parsed option and exits, and
# compares their stdout, stderr and exit status.
#
#   OLD=<xcc before> NEW=<xcc after> bash tests/driver/option-table.sh
#
# Both are self-hosted drivers that know XC_DUMP_DRIVER_STATE.
set -u
: "${OLD:?OLD names the driver before the change}"
: "${NEW:?NEW names the driver after the change}"
cd "$(dirname "$0")/../.." || exit 1
root=$(pwd)
case "$OLD" in /*) ;; *) OLD="$root/$OLD" ;; esac
case "$NEW" in /*) ;; *) NEW="$root/$NEW" ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/option-table.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# The same support root for both, whatever directory each binary is in, and
# none of the environment the parse reads.
export XCC_HOME="$root"
unset XTC_HOME XTC_LDFLAGS XC_PAR_REMOTE XCC_NO_RUNTIME_LIB XCC_3P
export XC_DUMP_DRIVER_STATE=1
printf '%064d\n' 0 > "$work/key.pub"     # 64 hex digits: a key --trust takes

# The table's rows, in its order: kind|spellings|a value the row accepts.
#   E exact, V exact with a value, P prefix, L prefix and longer, C custom
rows='V|-o --output|x.s
V|-A --arch|x86_64
V|-H --xcc-home --xtc-home|.
V|-I --include|inc
V|-D|FOO=1
L|-D|FOO=1
V|-Xlinker -framework|libz.dylib
E|-ll --list-layouts|
L|-l|foo
P|-Wl,|-rpath,/x
V|-L --library-path|libdir
L|-L|libdir
E|-S|
E|--emit-apk|
V|--sign-key|key.pem
E|-fbounds-check|
E|-fbounds-check=light|
L|-std=|c11
P|-ffp-contract=|fast
E|-fno-bounds-check|
P|--migrate=|1.0:1.1
E|-q --quiet|
V|-Flu --fn-loop-unroll|4
E|-h --help|
E|--print-target|
E|--print-3p-dir|
E|-v --version|
V|-m --memory-model|xt
E|-V --verbose|
E|-O|
P|-O|2
E|-Wanalyze|
P|-Wno-|comment
V|--bundle|out.bundle
V|--property --setting|k=v
V|--bundle-name|name
V|--bundle-version|1.0
V|--resources|res
V|--trust|key.pub
E|--no-sign|
V|--sign-bundle|out.bundle
V|--bundle-lib|libx.so
V|--rotate-from|old.key
V|--bundle-key|new.key
V|--publisher|pub
V|--publisher-domain|example.org
E|--emit-runtime|
E|--no-runtime-lib|
E|-fno-xc-args|
E|--emit-lib|
E|-flto|
V|--sign|id.pem
V|--sign-entitlements|ent.plist
E|-c|
E|--emit-iface|
V|-E --preprocessed|pp.xc
E|--emit-ir|
E|--emit-ir-opt|
E|-a --assemble-only --emit-asm-from-ir|
E|-dl --dump-layout|
E|-fdce-trace|
V|-Fli --fn-leaf-inline|10
P|-x-|wasm32,return-call
E|--link-libs|
C|-farc -farc=|x
P|-fauto-cloak=|auto
C|-ss --stack-size -ss= --stack-size=|100
E|--self-host|
E|-fnew-ir --with-ir|
E|-W|
V|-Q --quit-style|loop
E|--xtc-stack|
V|-Fmb --fn-min-banked|8
E|-dp --dump-placement|
E|-du --dump-usage|
E|--c-pair|'

src=dummy.xc
lines=()
while IFS='|' read -r kind names val; do
    for n in $names; do
        lines+=("$n $src")                          # alone: the source is its value
        lines+=("$src $n")                          # last, with no value
        case $kind in
            V)  lines+=("$n $val $src")             # the value separate
                lines+=("$n VAL $src")
                lines+=("$n$val $src")              # joined: not this row's form
                lines+=("$n=$val $src") ;;
            P|L) lines+=("$n$val $src")             # joined
                lines+=("${n}X $src")
                lines+=("$n $val $src") ;;
            E)  lines+=("$n VAL $src")
                lines+=("${n}X $src")
                lines+=("$n=VAL $src") ;;
            C)  case $n in
                    *=) lines+=("$n$val $src") ;;
                    *)  lines+=("$n $val $src") ;;
                esac ;;
        esac
    done
done <<< "$rows"

# Where an exact name and a prefix can both match, and the forms around them.
for e in "-O" "-O0" "-O2" "-O3" "-O4" "-Os" "-Oz" "-o x.s" "-o x.asm" "-o prog" \
         "-ll" "-lfoo" "-l" "-L dir" "-Ldir" "-L" "-D X" "-DX" "-DX=1" "-D" \
         "-I dir" "-Idir" "-Wl,-x" "-Wl,-rpath,/x,lib.o" "-Wl," "-Wno-foo" "-Wno-comment" \
         "-Wanalyze" "-W" "-Wpar-auto" "-Wfoo" "-fgoal=speed" "-fgoal=accuracy" "-fgoal=x" \
         "-fbounds-check" "-fbounds-check=light" "-fbounds-check=x" "-fno-bounds-check" \
         "-fxyz" "-x-wasm32" "-x-arm64,foo" "-x-wasm32,foo" "-std=" "-std=c++17" "-std=C11" \
         "-ffp-contract=x" "-fauto-cloak=x" "-farc" "-farc=1" "-ss" "-ss 0" "-ss=70000" \
         "--stack-size 64" "-Q rts" "-Q x" "-Flu x" "-Fli -1" "-Fmb 70000" \
         "--property novalue" "--property =v" "--trust missing.pub" \
         "-A 68030" "-A x86_64-linux-musl" "-A nosuch" "-m atarist" "-A m68k -m atarist" \
         "-m nosuch" "-Xlinker -framework" "-framework Metal" \
         "-o a -o b" "-S -o x.o" "a.o b.a c.obj" "second.xc" "-" "--" "-g -fpic" \
         "-static" "-dynamic" "--no-self-host" "--self-host" "--no-self-host --self-host"; do
    lines+=("$e $src")
done
lines+=("")                                         # nothing at all

n=0; bad=0
for line in "${lines[@]}"; do
    read -r -a args <<< "$line"
    n=$((n + 1))
    for which in OLD NEW; do
        bin=${!which}
        ( cd "$work" && perl -e 'alarm 30; exec @ARGV' "$bin" ${args[@]+"${args[@]}"} \
            > "$work/$which.out" 2> "$work/$which.err"; echo $? > "$work/$which.rc" )
    done
    for part in out err rc; do
        if ! cmp -s "$work/OLD.$part" "$work/NEW.$part"; then
            bad=$((bad + 1))
            echo "option-table: '$line': $part differs"
            diff "$work/OLD.$part" "$work/NEW.$part" | head -10
            break
        fi
    done
    [ $bad -ge 10 ] && { echo "option-table: stopped after 10 differences"; exit 1; }
done
[ $bad = 0 ] || exit 1
echo "option-table: ok ($n spellings)"
