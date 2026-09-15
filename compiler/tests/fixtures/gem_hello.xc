//xtc-na: arm64,xt6502,m68k,x86_64,win64 — the G* (GEM) application framework is arm9-only
// gem_hello.xc — smallest GApplication: a delegate adopting GApplicationProtocol
// announces it started, then the Milestone-1 event loop drains and exits. Proves
// the Cocoa-style main() → GApplication → delegate handoff end-to-end on the
// arm9 loader.
#import "Stdio.xc"
#import "Array.xc"
#import "GApplication.xc"

class GAppDelegate <GApplicationProtocol> {
    i32 applicationDidStart(Array* args) {
        Stdio.printf("hello_gem: applicationDidStart, %d args\n", args.count());
        return (i32)0;
    }
}

void main(void) {
    GApplication* app = new GApplication();
    app.setDelegate(new GAppDelegate());
    Array* args = new Array();
    i32 rc = app.run(args);
    Stdio.printf("hello_gem: run returned %d\n", (i16)rc);
}
