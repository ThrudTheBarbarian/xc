#!/bin/sh
# run_socket.sh — the socket gates (socket-mac, socket-win64, socket-linux): test_socket.xc, one
# source, against tools/echo_server.py on the same machine: natively on the Mac, under Wine, and on
# the Linux host (run_gtk_linux.sh; skipped without one).
set -u
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
work=$(mktemp -d)
python3 "$here/tools/echo_server.py" > "$work/port.txt" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$work"' EXIT
for i in $(seq 1 25); do [ -s "$work/port.txt" ] && break; sleep 0.2; done
port=$(cat "$work/port.txt")
fails=0
"$xcc" -A arm64 -I "$here" "$here/test_socket.xc" -o "$work/t" -q 2>/dev/null
out=$(UX_SOCKET_PORT=$port "$work/t" 2>&1); echo "$out" | grep -a 'FAIL\|PASS'
echo "$out" | grep -q '^PASS' && echo "== socket-mac: OK ==" || { echo "== socket-mac: FAILED =="; fails=1; }
if command -v wine >/dev/null 2>&1; then
  "$xcc" -A win64 -I "$here" "$here/test_socket.xc" -o "$work/t.exe" -q 2>/dev/null
  out=$(UX_SOCKET_PORT=$port WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" timeout 60 wine "$work/t.exe" 2>/dev/null)
  echo "$out" | grep -a 'FAIL\|PASS'
  echo "$out" | grep -q '^PASS' && echo "== socket-win64: OK ==" || { echo "== socket-win64: FAILED =="; fails=1; }
fi
out=$(UX_LINUX_FILES="$here/tools/echo_server.py" \
      UX_LINUX_SETUP='(nohup python3 echo_server.py > port.txt 2>/dev/null < /dev/null &) && sleep 1 && export UX_SOCKET_PORT=$(cat port.txt)' \
      sh "$here/run_gtk_linux.sh" test_socket 2>&1)
echo "$out" | grep -a 'FAIL\|PASS\|skipped' | tail -3
if echo "$out" | grep -q 'skipped'; then echo "== socket-linux: skipped =="
elif echo "$out" | grep -q '^PASS'; then echo "== socket-linux: OK =="
else echo "== socket-linux: FAILED =="; fails=1; fi
exit $fails
