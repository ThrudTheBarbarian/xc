// Prefix operators of a class's own shape: `√x`, from the Unicode block, and
// `~~x`, whose characters also read as two `~`. They bind as the built-in
// prefix operators do. `~~` on an integer keeps its old meaning.
#import <Stdio.xc>

class Sq
    {
    i32 v;
    static Sq* of(i32 x) { Sq* s = new Sq(); s.v = x; return s; }
    Sq* root() :operator(√self)
        {
        i32 r = 0;
        while ((r + 1) * (r + 1) <= v)
            r++;
        return Sq.of(r);
        }
    Sq* flip() :operator(~~self) { return Sq.of(0 - v); }
    Sq* plus(Sq* o) :operator(self + o) { return Sq.of(v + o.v); }
    }

i32 main(void)
    {
    Sq* a = Sq.of(49);
    Sq* b = Sq.of(9);
    Stdio.printf("root %d\n", (√a).v);
    Stdio.printf("sum %d\n", (√a + √b).v);
    Stdio.printf("flip %d\n", (~~a).v);
    i32 n = 6;
    Stdio.printf("old %d\n", ~~n);
    return 0;
    }
