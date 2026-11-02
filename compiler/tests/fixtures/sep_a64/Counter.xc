// Counter.xc — one module of tests/driver/arm64-linux-objects.sh: a class
// and a function another module calls across the object boundary.
#import "Foundation.xc"

class Counter
    {
    u32 n;
    void add(u32 k) { n = n + k; }
    u32 value(void) { return n; }
    }

u32 counterTwice(u32 x) { return x * (u32)2; }
