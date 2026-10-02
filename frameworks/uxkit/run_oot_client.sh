#!/bin/sh
# run_oot_client.sh -- an OUT-OF-TREE client of the deployed UXKit (`oot-client`): a program in a
# directory that is not this tree, `#use <UXKit>` and nothing else, built against the library in
# /opt/xcc/3p/uxkit as an external project would build it.  The in-tree gates #import the sources,
# so only this one sees the library's interface the way a client does -- which is how bug 038 (a
# library's structs did not import) went unnoticed from 0.5 to 0.65.
#
# The client uses UXKit the way an app does: struct returns and parameters (UXGeom.make, setFrame),
# an enum (UXEventKind), and a UXView subclass overriding drawRect across the library boundary.
# A compiler without the 038 fix SKIPS -- decided by building the bug's own tiny repro first, not by
# matching an error message; with the fix, any failure FAILS.
# arm9 only: that is the architecture the library is deployed for (make libUXKit.so ARCH=arm9).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
_root=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
gemlib=${GEMLIB:-${LOADER:+$LOADER/build-xtg}}
# The third-party tree the compiler searches: XCC_3P, else the installed home's sibling 3p/, else the
# standard /opt/xcc/3p (an in-tree compiler, compiler/bin/osx/xcc-xc, searches that one).
home=$(cd "$(dirname "$(command -v "$xcc")")/.." 2>/dev/null && pwd)
tp=${XCC_3P:-$home/../3p}
[ -d "$tp/uxkit" ] || tp=/opt/xcc/3p
lib="$tp/uxkit/arm9/libUXKit.so"
[ -e "$lib" ] || { echo "== oot-client: skipped (no deployed $lib; make libUXKit.so ARCH=arm9) =="; exit 0; }
[ -d "$gemlib" ] || { echo "== oot-client: skipped (no GEMLIB) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Does this compiler import a library's structs at all (bug 038)?  The repro: a struct in a library
# interface, and a client of the library that never names it.
mkdir -p "$work/probe"
cat > "$work/probe/MinLib.xc" <<'XC'
struct MRect
    {
    i16 x;
    i16 y;
    }
class MBox : Object
    {
    MRect r;
    void poke(void)
        {
        }
    }
XC
printf '#use <MinLib>\nvoid main(void)\n    {\n    MBox* b = new MBox();\n    b.poke();\n    }\n' > "$work/probe/client.xc"
if ! (cd "$work/probe" && "$xcc" -A arm9 --emit-lib MinLib.xc -o libMinLib.so && "$xcc" -A arm9 -L . client.xc -o client.so) >/dev/null 2>&1; then
  echo "== oot-client: skipped (this compiler predates the bug-038 fix: a library's structs do not import) =="
  exit 0
fi
cat > "$work/app.xc" <<'XC'
#use <UXKit>
class Swatch : UXView
    {
    i32 painted;
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        g.fillRectRGB(self.bounds(), (i32)200, (i32)40, (i32)40);
        }
    }
void main(void)
    {
    Swatch* s = new Swatch();
    UXRect r = UXGeom.make((i16)4, (i16)8, (i16)120, (i16)60);
    s.setFrame(r);
    UXRect back = s.frame();
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventWheel;
    i32 ok = (i32)back.w == (i32)120 && e.kind == (u8)UXEventWheel ? (i32)1 : (i32)0;
    }
XC
echo "== oot-client: building a client outside the tree against $lib =="
if out=$(cd "$work" && "$xcc" -A arm9 app.xc -L "$gemlib" -o app.so 2>&1); then
  if strings "$work/app.so" | grep -q '^libUXKit.so$'; then
    echo "== oot-client: OK -- built against the deployed library (DT_NEEDED libUXKit.so) =="
    exit 0
  fi
  echo "$out"; echo "== oot-client: FAILED (built, but not linked to libUXKit.so) =="; exit 1
fi
printf '%s\n' "$out"
echo "== oot-client: FAILED =="
exit 1
