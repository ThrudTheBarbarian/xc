// `a += b` on a protocol value that requires `+` and not `+=` is
// `a = a + b`: the protocol's `+` is called, its result is assigned to `a`,
// and the old value is released.
#import <Stdio.xc>

protocol Accum
    {
    Accum* plus(Accum* o) :operator(self + o);
    i32 value(void);
    }

class Count <Accum>
    {
    i32 n;
    static Count* of(i32 v) { Count* c = new Count(); c.n = v; return c; }
    Accum* plus(Accum* o) :operator(self + o) { return Count.of(n + o.value()); }
    i32 value(void) { return n; }
    }

class Tally <Accum>
    {
    i32 n;
    static Tally* of(i32 v) { Tally* t = new Tally(); t.n = v; return t; }
    Accum* plus(Accum* o) :operator(self + o) { return Tally.of(n + 2 * o.value()); }
    i32 value(void) { return n; }
    }

Accum* addAll(Accum* start, Accum* step, i32 times)
    {
    Accum* acc = start;
    for (i32 i = 0; i < times; i++)
        acc += step;
    return acc;
    }

i32 main(void)
    {
    Accum* c = Count.of(1);
    Accum* t = Tally.of(1);
    c += t;
    t += c;
    Stdio.printf("count %d tally %d\n", c.value(), t.value());
    Stdio.printf("addAll %d %d\n", addAll(Count.of(0), Count.of(5), 4).value(),
                 addAll(Tally.of(0), Count.of(5), 4).value());
    return 0;
    }
