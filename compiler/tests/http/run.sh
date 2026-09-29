#!/bin/bash
# tests/http/run.sh — Http.xc against a local HTTP server.
#
# Starts `python3 -m http.server` on 127.0.0.1:18080 over a scratch directory,
# builds http_get.xc and http_async.xc with each compiler for the host (arm64),
# runs them and compares the output with expected.out. Needs python3; the
# server is stopped however the script ends.
#
#   bash tests/http/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
WORK=$(mktemp -d)
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/www/sub"
printf 'hello from xcc http\n' > "$WORK/www/hello.txt"
printf 'in sub\n' > "$WORK/www/sub/x.txt"
( cd "$WORK/www" && exec python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 ) &
SRV=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null http://127.0.0.1:18080/ && break
    sleep 0.3
done
pass=0; fail=0
for c in bin/osx/xcc bin/osx/xcc-xc; do
    [ -x "$c" ] || continue
    out=""
    for t in http_get http_async; do
        if ! "$c" -H . -A arm64 -o "$WORK/$t" "tests/http/$t.xc" > "$WORK/build.txt" 2>&1; then
            echo "  $(basename $c) $t: build failed"; sed 's/^/    /' "$WORK/build.txt" | head -5
            fail=$((fail+1)); continue 2
        fi
        out="$out$("$WORK/$t")"$'\n'
    done
    if [ "$out" == "$(cat tests/http/expected.out)"$'\n' ]; then pass=$((pass+1))
    else
        fail=$((fail+1)); echo "  $(basename $c): output differs"
        diff <(printf '%s' "$out") tests/http/expected.out | head -10
    fi
done
echo "--- http: pass=$pass fail=$fail ---"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
