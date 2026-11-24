// Bracket operators on a number kept in tenths: `⌊x⌋` and `⌈x⌉` round down and
// up, `|x|` is the absolute value and `‖x‖` rounds to the nearest. `⟨x⟩`, the
// fractional part, is a static method's. Each returns a Num, so brackets
// nest:
//   ||x||           a `||` where an operand starts is two opening bars,
//                   and the `||` after x closes both: |(|x|)|
//   |‖x‖|           ‖x‖ inside |...|
//   ||a| + |b||     |(|a| + |b|)|: the first `|` after a closes |a|, the
//                   `||` after b closes |b| and the outer bar
//   ⌊|x|⌋, |⌊x⌋|    brackets of two kinds
//   |(a | b)|       inside |...| a `|` after an operand closes, so a bitwise
//                   or there is written in parentheses
#import <Stdio.xc>

class Num
    {
    i32 t;
    static Num* of(i32 tenths) { Num* n = new Num(); n.t = tenths; return n; }
    Num* floor() :operator(⌊self⌋)
        {
        i32 w = t / 10;
        if (t < 0 && w * 10 != t)
            w = w - 1;
        return Num.of(w * 10);
        }
    Num* ceil() :operator(⌈self⌉)
        {
        i32 w = t / 10;
        if (t > 0 && w * 10 != t)
            w = w + 1;
        return Num.of(w * 10);
        }
    Num* abs() :operator(|self|) { return Num.of(t < 0 ? 0 - t : t); }
    Num* round() :operator(‖self‖) { return ⌊Num.of(t + 5)⌋; }
    static Num* frac(Num* x) :operator(⟨x⟩) { return Num.of(x.t - (⌊x⌋).t); }
    Num* plus(Num* o) :operator(self + o) { return Num.of(t + o.t); }
    Num* bits(Num* o) :operator(self | o) { return Num.of(t | o.t); }
    }

i32 main(void)
    {
    Num* x = Num.of(-37);
    Num* y = Num.of(24);
    Stdio.printf("floor %d ceil %d\n", (⌊x⌋).t, ⌈x⌉.t);
    Stdio.printf("abs %d round %d\n", |x|.t, ‖y‖.t);
    Stdio.printf("frac %d %d\n", ⟨x⟩.t, ⟨y⟩.t);
    Stdio.printf("twice %d\n", ||x||.t);
    Stdio.printf("nested %d\n", |‖x‖|.t);
    Stdio.printf("inner %d\n", ||x| + |y||.t);
    Stdio.printf("kinds %d %d\n", ⌊|x|⌋.t, |⌊x⌋|.t);
    Stdio.printf("adjacent %d\n", (|x| + |y|).t);
    Stdio.printf("or %d\n", |(x | y)|.t);
    return 0;
    }
