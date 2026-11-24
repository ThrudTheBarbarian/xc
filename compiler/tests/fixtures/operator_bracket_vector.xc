// Bracket operators of a class's own shape: `|v|` for the squared length of a
// vector and `‖v‖` for its largest component. A bracket binds as parentheses
// do, so it needs no precedence: `2 * |a| + ‖b‖` is `2 * (|a|) + (‖b‖)`.
// Two bars side by side, `|a| + |b|`, are two operands. In the same unit `|`
// and `||` between operands keep their built-in meaning.
#import <Stdio.xc>

class Vec
    {
    i32 x;
    i32 y;
    static Vec* of(i32 a, i32 b) { Vec* v = new Vec(); v.x = a; v.y = b; return v; }
    i32 length2() :operator(|self|) { return x * x + y * y; }
    i32 norm() :operator(‖self‖)
        {
        i32 ax = x < 0 ? 0 - x : x;
        i32 ay = y < 0 ? 0 - y : y;
        return ax > ay ? ax : ay;
        }
    }

i32 main(void)
    {
    Vec* a = Vec.of(3, 4);
    Vec* b = Vec.of(-7, 2);
    Stdio.printf("length2 %d\n", |a|);
    Stdio.printf("norm %d\n", ‖b‖);
    Stdio.printf("sum %d\n", |a| + |b|);
    Stdio.printf("mixed %d\n", 2 * |a| + ‖b‖ - 1);
    Stdio.printf("call %d\n", a.length2() - |a|);
    i32 m = 12;
    i32 n = 3;
    bool p = false;
    bool q = true;
    Stdio.printf("or %d\n", m | n);
    Stdio.printf("logical %d\n", (p || q) ? 1 : 0);
    Stdio.printf("bars %d\n", |a| | n);
    return 0;
    }
