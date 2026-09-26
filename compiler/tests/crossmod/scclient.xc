// scclient.xc — static calls into a class the client knows only through a
// library: Number comes from libSCLib's interface, not from Number.xc.
// The first call is the one that runs Number's static init in the library.
#import <SCLib>
#import "Stdio.xc"

void main(void)
    {
    Stdio.printf("start\n");
    Number* big = Number.with((i64)5000000000);
    Number* small = Number.with((i32)-7);
    Number* d = Number.withDouble(2.5d);
    Stdio.printf("big=%lld\n", big.asI64());
    Stdio.printf("small=%d\n", small.asI32());
    Stdio.printf("d=%d\n", (i32)(d.asDouble() * 2.0d));
    SCLib.hello();
    }
