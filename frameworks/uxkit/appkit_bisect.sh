#!/bin/sh
# Bisect the intermittent interactive crash WITHOUT auto-quit (which may mask the race).  Each
# variant is a real interactive app run N times via launch-wait-check: start it, wait 0.5s, and if
# it is still alive it survived (kill it); if it already died it crashed.  Variants climb from a
# minimal window up to an EXACT copy of demo_appkit.xc, all measured identically.
#
#   Run in your Terminal:  sh frameworks/uxkit/appkit_bisect.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
N=${N:-25}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

cc -fobjc-arc -fno-objc-msgsend-selector-stubs -c "$here/libUXAppKit.m" -o "$work/shim.o" 2>/dev/null

# $1 = name, $2 = canvas drawRect body, $3 = widgets body (in applicationDidStart)
variant() {
  cat > "$work/$1.xc" <<XT
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
class Canvas : UXView {
    void init(void) { super.init(); }
    void drawRect(UXGraphics@ g, UXRect dirty) { $2 }
    bool acceptsFirstResponder(void) { return true; }
}
class Ctl : Object <UXApplicationDelegate> {
    UXApplication@ app;
    UXTextField@ field;
    void onAlert(UXControl@ c) { }
    void onQuit(UXControl@ c) { app.stop(); }
    void mA(UXMenuItem@ s) { }
    i32 applicationDidStart(UXApplication@ a) {
        app = a;
        UXWindow@ win = new UXWindow();
        Canvas@ canvas = new Canvas();
        win.open((u8@)"UXKit AppKit Demo", UXGeom.make((i16)140,(i16)140,(i16)340,(i16)240), canvas);
        app.addWindow(win);
        $3
        win.displayAll();
        return (i32)0;
    }
}
void main(void) {
    UXAppKitDriver@ d = new UXAppKitDriver(); gDriver = d;
    d.setInteractive(true);
    Ctl@ c = new Ctl();
    UXApplication@ app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    app.run();
}
XT
  "$xcc" -A arm64 -I "$here" "$work/$1.xc" -Xlinker "$work/shim.o" -framework Cocoa -o "$work/$1" -q 2>/dev/null
}

FILL='g.fillRect(UXGeom.make((i16)0,(i16)0,(i16)340,(i16)240), (i32)8);'
TEXT="$FILL"' g.fillRect(UXGeom.make((i16)0,(i16)0,(i16)340,(i16)6),(i32)2); g.drawText((u8@)"UXKit - running native on AppKit",(i16)20,(i16)28,(i32)1,(i32)0); g.drawText((u8@)"click a button, type below, or use the menu",(i16)20,(i16)52,(i32)1,(i32)0);'
B2='UXButton@ b1 = new UXButton(); b1.setTitle((u8@)"Alert"); b1.setAction(&self.onAlert); canvas.addSubview(b1, UXGeom.make((i16)20,(i16)180,(i16)90,(i16)28)); UXButton@ b2 = new UXButton(); b2.setTitle((u8@)"Quit"); b2.setAction(&self.onQuit); canvas.addSubview(b2, UXGeom.make((i16)120,(i16)180,(i16)90,(i16)28));'
FLD='field = new UXTextField(); canvas.addSubview(field, UXGeom.make((i16)20,(i16)120,(i16)300,(i16)24));'
M2='UXMenuBar@ bar = new UXMenuBar(); UXMenu@ dm = bar.addMenu((u8@)"Demo"); dm.addItem((u8@)"About", &self.mA); dm.addSeparator(); dm.addItem((u8@)"Quit", &self.mA); UXMenu@ em = bar.addMenu((u8@)"Edit"); em.addItem((u8@)"Clear Field", &self.mA); app.setMenuBar(bar);'

variant c1_fill      "$FILL" ""
variant c2_text      "$TEXT" ""
variant c3_buttons   "$TEXT" "$B2"
variant c4_field     "$TEXT" "$B2 $FLD"
variant c5_full      "$TEXT" "$B2 $FLD $M2"

# also the REAL demo, built exactly as `make appkit-demo` does
"$xcc" -A arm64 -I "$here" "$here/demo_appkit.xc" -Xlinker "$work/shim.o" -framework Cocoa -o "$work/demo_real" -q 2>/dev/null

run_n() {  # $1 = binary
  crashes=0; i=0
  while [ "$i" -lt "$N" ]; do
    "$1" >/dev/null 2>&1 & pid=$!
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    else wait "$pid" 2>/dev/null; crashes=$((crashes+1)); fi
    i=$((i+1))
  done
  echo "$crashes/$N"
}

echo "running each $N times (launch-wait-check; windows flash for 0.5s each)..."
for v in c1_fill c2_text c3_buttons c4_field c5_full demo_real; do
  echo "$v: $(run_n "$work/$v") crashed"
done
