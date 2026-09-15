#!/bin/sh
# elf-run.sh — proves the self-hosted Linux last stage end to end: a Mac builds a
# runnable Linux binary using only in-house code (XAX86_64Assembler encodes the
# instructions, XTElfWriter writes the ELF). No clang, no ld, no libc, no musl —
# the binaries talk to the kernel through raw syscalls.
#
# Needs an x86-64 Linux host to run the output on; set XTC_LINUX_HOST in
# build.env. Skips cleanly if it is unset or unreachable.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
cd "$(dirname "$0")/../.."

HOST="${XTC_LINUX_HOST:-}"
SMOKE=bin/osx/elf-smoke
[ -x "$SMOKE" ] || { echo "elf-run: build it first: make elf-smoke"; exit 1; }

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
    echo "elf-run: SKIP (no Linux host '$HOST')"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -f "$TMP"/elf-exit42 "$TMP"/elf-hello; rmdir "$TMP" 2>/dev/null' EXIT
fail=0
check() {   # check <name> <expected-status> <expected-stdout>
    printf '  %-28s' "$1"
    if [ "$got_status" = "$2" ] && [ "$got_out" = "$3" ]; then echo "ok"
    else echo "FAIL (status=$got_status out='$got_out')"; fail=1; fi
}

"$SMOKE" "$TMP/elf-exit42"           >/dev/null
"$SMOKE" "$TMP/elf-hello"  --hello   >/dev/null
scp -q "$TMP/elf-exit42" "$TMP/elf-hello" "$HOST:/tmp/" || { echo "elf-run: scp failed"; exit 1; }

got_out=$(ssh "$HOST" 'chmod +x /tmp/elf-exit42; /tmp/elf-exit42' 2>/dev/null) || true
got_status=$(ssh "$HOST" 'chmod +x /tmp/elf-exit42; /tmp/elf-exit42 >/dev/null 2>&1; echo $?')
check "exit status passthrough" 42 ""

got_out=$(ssh "$HOST" 'chmod +x /tmp/elf-hello; /tmp/elf-hello' 2>/dev/null) || true
got_status=$(ssh "$HOST" 'chmod +x /tmp/elf-hello; /tmp/elf-hello >/dev/null 2>&1; echo $?')
check "write(2) + absolute data" 0 "hello from xtc"

ssh "$HOST" 'rm -f /tmp/elf-exit42 /tmp/elf-hello' 2>/dev/null || true
[ $fail = 0 ] && echo "elf-run: all ok" || echo "elf-run: FAILURES"
exit $fail
