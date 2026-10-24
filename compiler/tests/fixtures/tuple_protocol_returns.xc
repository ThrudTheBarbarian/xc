// `(a, b) = p.m()` through a PROTOCOL receiver: the call is typed with the
// requirement's values, as a class receiver's is. The reference left the
// targets unbound ("undefined identifier 'a'") and the port refused the
// requirement's type ("unsupported: type i32,i64").
#import "Stdio.xc"

protocol Pair
    {
    i32, i64 both(void);
    u8, bool small(u8 x);
    }

class Impl : Object <Pair>
    {
    i32 base;
    i32, i64 both(void) { return base, 5000000000; }
    u8, bool small(u8 x) { return x + (u8)1, x > (u8)9; }
    }

class Other : Object <Pair>
    {
    i32, i64 both(void) { return -1, -2; }
    u8, bool small(u8 x) { return x, true; }
    }

void show(Pair* p)
    {
    (i32 a, i64 b) = p.both();
    (u8 c, bool big) = p.small((u8)41);
    Stdio.printf("%d %ld %u %d\n", a, b, c, big ? 1 : 0);
    }

i32 main(void)
    {
    Impl* i = new Impl();
    i.base = 7;
    show((Pair*)i);
    show((Pair*)new Other());
    return 0;
    }
