#!/bin/bash
# env-registry.sh — every environment variable the compiler reads is listed in
# `xcc -h` (#337). The names are read off the self-hosted sources (each
# Platform.env / optGetenv / _xt_getenv / ppEnvSet of a literal), so a new
# variable must be added to the help's registry or this fails. System
# variables (PATH, TEMP, USERPROFILE) and other tools' own (xcmon, xcd) are
# not the compiler's settings.
#
#   bash tests/driver/env-registry.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
help=$("$XC" -h 2>&1)
names=$(grep -rhoE '(Platform\.env\(String\.withCString\(|optGetenv\(|_xt_getenv\(|ppEnvSet\()"[A-Z0-9_]+"' \
            selfhost --include='*.xc' --exclude=xcmon.xc --exclude=xcd.xc 2>/dev/null \
        | grep -oE '"[A-Z0-9_]+"' | tr -d '"' | sort -u)
for n in $names; do
    case "$n" in PATH|TEMP|USERPROFILE) continue ;; esac
    printf '%s\n' "$help" | grep -qE "^  $n( |$)" || { echo "FAIL env-registry: $n is read but not listed in xcc -h"; fail=1; }
done
[ $fail = 0 ] && echo "env-registry: ok ($(printf '%s\n' $names | wc -l | tr -d ' ') names)"
exit $fail
