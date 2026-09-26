// struct_param_live_across_call.xc — bug 292. A by-value struct parameter is
// read through the address of its fields. At -O3 that address is formed once,
// before a call, and read again after it. On xt6502 the parameter lives in the
// zero-page pool every function shares, and the caller saved only the values
// whose own uses ran past the call, so a callee with a local of its own in
// the pool overwrote it. Gfx8.lineTo(Point) left the pen where it was.

#import "Stdio.xc"

struct Pt { i16 x; i16 y; };

i16 sink;

i16 diff(Pt q)
{
    return q.x - q.y;
}

// Its own struct local takes the first bytes of the pool.
i16 viaLocal(i16 a, i16 b)
{
    Pt o;
    o.x = a + 500;
    o.y = b + 700;
    return diff(o);
}

i16 afterCall(Pt p)
{
    sink = viaLocal(p.y, p.x);
    return p.x * 10 + p.y;
}

class Pen
{
    Pt at;

    void step(i16 x, i16 y)
    {
        Pt o;
        o.x = x + 1000;
        o.y = y + 2000;
        sink = diff(o);
        return;
    }

    // The same shape through a dispatched call, as Gfx8.lineTo(Point) has.
    void stepTo(Pt p)
    {
        step(p.x, p.y);
        at.x = p.x;
        at.y = p.y;
        return;
    }
}

class LoudPen : Pen
{
    void step(i16 x, i16 y)
    {
        Pt o;
        o.x = x + 3000;
        o.y = y + 4000;
        sink = diff(o);
        return;
    }
}

void main(void)
{
    Pt n;
    n.x = 16;
    n.y = 2;
    Stdio.printf("afterCall %d sink %d\n", afterCall(n), sink);

    Pen* pen = new LoudPen();
    Pt t;
    t.x = 40;
    t.y = 24;
    pen.stepTo(t);
    Stdio.printf("pen %d %d sink %d\n", pen.at.x, pen.at.y, sink);
}
