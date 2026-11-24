// Operators of a class's own shape from an interface: `2 * a ** b ** c`
// groups as `2 * (a ** (b ** c))` only if the precedence came with the shape,
// and `x**p` on numbers keeps its old meaning.
#import "Stdio.xc"
#import <mod-opshape>
void main(void)
    {
    Pw* a = Pw.of(1);
    Pw* b = Pw.of(2);
    Pw* c = Pw.of(3);
    i32 x = 4;
    i32* p = &x;
    Stdio.printf("%d %d %d\n", (2 * a ** b ** c).v, (a ⊗ b).v, x**p);
    return;
    }
