// A class conforms to a protocol through a method it inherits from a parent
// that does not conform. The interface publishes the protocol slot on the
// parent's method label in both compilers, and when two subclasses conform
// to different protocols through the same method, the one whose class name
// sorts last decides it (Zed's Rated here).
#import <Stdio.xc>

protocol Valued { i32 value(void); }
protocol Rated  { i32 value(void); }

class Base
    {
    i32 n;
    i32 value(void) { return n; }
    }

class Zed : Base <Rated> { }
class Alpha : Base <Valued> { }
class Own : Base <Valued> { i32 value(void) { return n * 10; } }

i32 main(void)
    {
    Zed* z = new Zed();
    z.n = 3;
    Alpha* a = new Alpha();
    a.n = 4;
    Own* o = new Own();
    o.n = 5;
    Valued* v = (Valued*)a;
    Rated* r = (Rated*)z;
    Valued* w = (Valued*)o;
    Stdio.printf("%d %d %d %d\n", r.value(), v.value(), w.value(), ((Base*)o).value());
    return 0;
    }
