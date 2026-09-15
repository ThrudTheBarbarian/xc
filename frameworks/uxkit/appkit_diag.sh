#!/bin/sh
# Diagnostic for the INTERMITTENT AppKit activation crash.  Pure-ObjC windows (no xcc, no my toolkit)
# with different activation setups, each run N times; reports how many of the N runs crashed.  The
# key question: does a bare window (v1_plain) crash intermittently too?  If yes -> fundamental (a
# non-bundled foreground app is racy on macOS 15 -> ship an .app bundle).  If v1 is 0/N but a later
# variant crashes -> that feature is the trigger.
#
#   Run in your Terminal:  sh frameworks/uxkit/appkit_diag.sh
set -e
N=${N:-25}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

emit() {
  cat > "$work/$1.m" <<M
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
static BOOL isFlipped(id s, SEL c){ return YES; }
int main(void){ @autoreleasepool {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  $2
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    [NSApp terminate:nil]; });
  [NSApp run];
} return 0; }
M
  cc "$work/$1.m" -framework Cocoa -o "$work/$1" 2>/dev/null
}

WIN='NSWindow* w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,300,200) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO]; [w setReleasedWhenClosed:NO]; [w setTitle:@"diag"]; [w center]; [w makeKeyAndOrderFront:nil];'
VIEW='Class vc=objc_allocateClassPair([NSView class],"UXDrawView",0); class_addMethod(vc,sel_registerName("isFlipped"),(IMP)isFlipped,"B@:"); objc_registerClassPair(vc); [w setContentView:[[vc alloc] initWithFrame:NSMakeRect(0,0,300,200)]];'

emit v1_plain          "$WIN"
emit v2_activate       "$WIN [NSApp activateIgnoringOtherApps:YES];"
emit v3_activate_view  "$WIN $VIEW [NSApp activateIgnoringOtherApps:YES];"
emit v5_newactivate    "$WIN [NSApp activate];"

echo "running each variant $N times..."
for v in v1_plain v2_activate v3_activate_view v5_newactivate; do
  crashes=0
  i=0; while [ "$i" -lt "$N" ]; do
    "$work/$v" >/dev/null 2>&1 || crashes=$((crashes+1))
    i=$((i+1))
  done
  echo "$v: $crashes/$N crashed"
done
