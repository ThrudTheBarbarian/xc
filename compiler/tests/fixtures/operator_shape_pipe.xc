// A pipe, `|>`, made to bind more loosely than `|` with :precedence(below |),
// so `s |> t | u` passes `t | u` along. With no :precedence it would bind as
// `|` does and group from the left.
#import <Stdio.xc>

class Stage
    {
    i32 k;
    static Stage* of(i32 x) { Stage* s = new Stage(); s.k = x; return s; }
    Stage* both(Stage* o) :operator(self | o) { return Stage.of(k * 10 + o.k); }
    Stage* feed(Stage* o) :operator(self |> o) :precedence(below |) { return Stage.of(k * 1000 + o.k); }
    }

i32 main(void)
    {
    Stage* s = Stage.of(1);
    Stage* t = Stage.of(2);
    Stage* u = Stage.of(3);
    Stdio.printf("pipe %d\n", (s |> t | u).k);
    Stdio.printf("chain %d\n", (s |> t |> u).k);
    return 0;
    }
