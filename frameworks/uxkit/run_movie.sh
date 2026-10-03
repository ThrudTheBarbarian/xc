#!/bin/sh
# run_movie.sh -- the `movie` gate: UXMovie's WebM, checked against real decoders.  ffmpeg must read
# it as VP8 at the right size, frame count and duration, decode it without a complaint, and give the
# last frame back byte for byte as the encoder reconstructed it.  The file must be the same on every
# arch built here (win64 under Wine, wasm32 under node).  Headless Chrome must play it: its size and
# duration, every frame shown in order as it plays, and pixels of the last frame close to the source.  Skips without ffmpeg; the Chrome,
# Wine and node legs skip without theirs.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || { echo "== movie: skipped (no ffmpeg) =="; exit 0; }
work=$(mktemp -d)
SRV=
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null || true; rm -rf "$work" 2>/dev/null || true' EXIT
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=1; }

echo "== movie: building test_movie (with its files) =="
"$xcc" -I "$here" -D MOVIE_FILES -o "$work/test_movie" "$here/test_movie.xc" -q
(cd "$work" && ./test_movie) > "$work/out.txt"
grep '^PASS' "$work/out.txt" >/dev/null && ok "test_movie passes" || { cat "$work/out.txt"; bad "test_movie"; }
sum=$(grep -o 'checksum [0-9]*' "$work/out.txt")

echo "== movie: ffmpeg =="
p=$(ffprobe -v error -count_frames -show_entries stream=codec_name,width,height,nb_read_frames:format=duration -of default=nw=1 "$work/test_movie.webm" | tr '\n' ' ')
echo "  ($p)"
case "$p" in *"codec_name=vp8 width=203 height=117 nb_read_frames=5 duration=0.440000"*) ok "ffprobe: VP8, 203x117, 5 frames, 0.44 s" ;; *) bad "ffprobe reads it as: $p" ;; esac
errs=$(ffmpeg -v warning -i "$work/test_movie.webm" -f null - 2>&1 || true)
[ -z "$errs" ] && ok "ffmpeg decodes it without a warning" || bad "ffmpeg: $errs"
ffmpeg -v error -i "$work/test_movie.webm" -vf "select=eq(n\,4)" -fps_mode passthrough -frames:v 1 -f rawvideo -pix_fmt yuv420p -y "$work/dec.yuv"
cmp -s "$work/dec.yuv" "$work/test_movie_last.yuv" && ok "the last frame decodes byte for byte as the encoder reconstructed it" || bad "the decoded last frame differs from the reconstruction"

if command -v wine >/dev/null 2>&1; then
  "$xcc" -A win64 -I "$here" -o "$work/tm.exe" "$here/test_movie.xc" -q
  w=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" timeout 60 wine tm.exe 2>/dev/null | grep -ao 'checksum [0-9]*' || true)
  [ "$w" = "$sum" ] && ok "win64 writes the same file ($sum)" || bad "win64 writes a different file ($w, not $sum)"
fi
if command -v node >/dev/null 2>&1; then
  "$xcc" -A wasm32 -I "$here" -o "$work/tmw" "$here/test_movie.xc" -q
  n=$(node "$work/tmw.js" | grep -o 'checksum [0-9]*' || true)
  [ "$n" = "$sum" ] && ok "wasm32 writes the same file ($sum)" || bad "wasm32 writes a different file ($n, not $sum)"
fi

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  echo "== movie: headless Chrome plays it =="
  cp "$here/tools/movie_play.html" "$work/"
  port=8966
  pkill -f "coi_server.py $port" 2>/dev/null || true
  ( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
  SRV=$!
  sleep 1
  ( "$CHROME" --headless=new --autoplay-policy=no-user-gesture-required --user-data-dir="$work/chrome" "http://localhost:$port/movie_play.html" >/dev/null 2>&1 & )
  for i in $(seq 1 30); do [ -f "$work/result.txt" ] && break; sleep 1; done
  r=$(cat "$work/result.txt" 2>/dev/null || echo "no result from the page")
  echo "$r" | sed 's/^/  (/; s/$/)/'
  echo "$r" | grep -q '^size 203x117$' && echo "$r" | grep -q '^duration 0.440$' && ok "Chrome reads it: 203x117, 0.44 s" || bad "Chrome's reading of the file"
  echo "$r" | grep -q '^frames shown 0,1,2,3,4$' && ok "...and plays it: frames 0 to 4, in order, each shown" || bad "Chrome did not show each frame in order"
  # the last frame's source at these points: the box (200,40,40), the panel (236,236,240), the backdrop
  near() { echo "$r" | awk -v at="$1" -v R="$2" -v G="$3" -v B="$4" 'BEGIN { r = 1 } $1=="pixel" && $2==at { d=($3-R)^2+($4-G)^2+($5-B)^2; r = (d < 300 ? 0 : 1) } END { exit r }'; }
  near 100,50 200 40 40 && near 30,100 236 236 240 && near 180,6 226 13 96 && ok "Chrome shows the last frame's colours where they are" || bad "the colours Chrome shows"
fi
[ $fails = 0 ] || { echo "== movie: FAILED =="; exit 1; }
echo "== movie: OK =="
