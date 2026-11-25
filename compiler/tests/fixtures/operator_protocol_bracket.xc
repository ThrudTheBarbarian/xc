// A protocol can require a bracket operator: `|m|` on a `Measured*` calls
// the object's `size`, and binds as parentheses do. Between operands `|`
// keeps its built-in meaning.
#import <Stdio.xc>

protocol Measured
    {
    i32 size(void) :operator(|self|);
    }

class Segment <Measured>
    {
    i32 a;
    i32 b;
    static Segment* of(i32 x, i32 y) { Segment* s = new Segment(); s.a = x; s.b = y; return s; }
    i32 size(void) :operator(|self|) { return b > a ? b - a : a - b; }
    }

class Box <Measured>
    {
    i32 w;
    i32 h;
    static Box* of(i32 x, i32 y) { Box* r = new Box(); r.w = x; r.h = y; return r; }
    i32 size(void) :operator(|self|) { return w * h; }
    }

i32 total(Measured* m, Measured* n)
    {
    return |m| + 2 * |n|;
    }

i32 main(void)
    {
    Measured* s = Segment.of(9, 2);
    Measured* b = Box.of(3, 4);
    Stdio.printf("sizes %d %d\n", |s|, |b|);
    Stdio.printf("total %d %d\n", total(s, b), total(b, s));
    i32 k = 8;
    Stdio.printf("or %d\n", |s| | k);
    return 0;
    }
