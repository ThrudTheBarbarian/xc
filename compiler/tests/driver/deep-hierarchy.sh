#!/bin/bash
# deep-hierarchy.sh — a class 70 levels below the one whose method it
# overrides still overrides it (#334). The walks up a class's ancestors
# stopped after 64 steps, so an override further down than that was not
# found: a call through the root type ran the root's method.
#
#   bash tests/driver/deep-hierarchy.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}; case $XC in /*) ;; *) XC="$(pwd)/$XC";; esac
ROOT=$(pwd)
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
{
    echo '#import "Stdio.xc"'
    echo 'class C0 { i32 v(void) { return 0; } }'
    for i in $(seq 1 69); do echo "class C$i : C$((i-1)) { }"; done
    echo 'class C70 : C69 { i32 v(void) { return 70; } }'
    echo 'i32 main(void) { C0* o = (C0*)new C70(); Stdio.printf("%d\n", o.v()); return 0; }'
} > "$W/deep.xc"
fail=0
for o in O0 O2; do
    if "$XC" -q -$o -H "$ROOT" -o "$W/deep" "$W/deep.xc" > "$W/e" 2>&1; then
        got=$("$W/deep" 2>&1)
        [ "$got" = 70 ] || { echo "FAIL deep-hierarchy -$o: the call through C0 prints '$got', want 70"; fail=1; }
    else
        echo "FAIL deep-hierarchy -$o: does not build: $(head -c 300 "$W/e")"; fail=1
    fi
done
[ $fail = 0 ] && echo "deep-hierarchy: ok"
exit $fail
