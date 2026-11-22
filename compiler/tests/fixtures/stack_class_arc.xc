//xtc-na: xt6502 — this many classes and cases overflow the layout's .code_regions; stack_class_arc_basic covers it there
// A stack class instance owns what its object ivars hold, as a heap instance
// does: its class's dealloc runs at every exit from its scope (the end of the
// block, each loop iteration, return, break, continue, goto), a copy retains
// what it copies, an assignment retains the new references before the old
// instance comes apart, and a by-value return moves its references to the
// caller. A call's by-value result that nothing adopts comes apart at the end
// of the full expression.
//
// Every Tracker counts itself in `live` from init to dealloc, so a leak shows
// as a count left over and a double release as a count gone negative (or a
// crash), whatever the allocator does with the memory.
#import <Stdio.xc>

i32 live;
i32 serial;

class Tracker
    {
    i32 id;
    void init(void) { live = live + 1; serial = serial + 1; id = serial; }
    void dealloc(void) { live = live - 1; }
    }

class Holder
    {
    Tracker* t;
    i32 n;
    Holder dup(void) { Holder d; d.t = t; d.n = n + 100; return d; }
    }

class Named
    {
    String* name;
    i32 n;
    }

// A user dealloc runs once per instance, before the ivars are released.
class Noisy
    {
    Tracker* t;
    i32 n;
    void dealloc(void) { Stdio.printf("  dealloc %d\n", n); }
    }

class Child : Noisy
    {
    Tracker* u;
    }

struct Pair
    {
    Tracker* a;
    i32 k;
    }

// An instance that holds an owning struct member: the struct's references are
// part of what the instance owns.
class Boxed
    {
    Pair p;
    Tracker* t;
    }

class Linked
    {
    weak:Tracker* w;
    Tracker* t;
    }

Holder mk(i32 k)
    {
    Holder h;
    h.t = new Tracker();
    h.n = k;
    return h;
    }

Holder viaLocal(i32 k)
    {
    Holder b = mk(k);
    return b;
    }

Holder forward(i32 k)
    {
    return mk(k + 1);
    }

Holder copyOut(Holder src)
    {
    Holder c = src;
    c.n = c.n + 1;
    return c;
    }

// A parameter is borrowed, so returning it copies it out.
Holder pass(Holder src)
    {
    return src;
    }

Named mkNamed(i32 k)
    {
    Named v;
    v.name = String.withFormat("item%d", k);
    v.n = k;
    return v;
    }

Noisy mkNoisy(i32 k)
    {
    Noisy v;
    v.t = new Tracker();
    v.n = k;
    return v;
    }

i32 early(i32 k)
    {
    Holder h;
    h.t = new Tracker();
    if (k > 0)
        {
        Holder inner;
        inner.t = new Tracker();
        return k;
        }
    return 0;
    }

i32 viaGoto(i32 k)
    {
    i32 r = 0;
        {
        Holder h;
        h.t = new Tracker();
        if (k > 1)
            goto out;
        r = 1;
        }
out:
    return r + live;
    }

i32 main(void)
    {
    // Scope exit, every loop iteration.
    for (i32 i = 0; i < 1000; i++)
        {
        Holder h;
        h.t = new Tracker();
        h.n = i;
        }
    Stdio.printf("loop live %d\n", live);

    // Copy, then reassign the original: the copy still owns its string.
        {
        Named b = mkNamed(7);
        Named c = b;
        b.name = String.withCString("changed");
        Stdio.printf("copy %s %s\n", b.name.cString(), c.name.cString());
        Holder x = mk(1);
        Holder y = x;
        x.t = new Tracker();
        Stdio.printf("copy shares %d live %d\n", y.t.id == x.t.id ? 1 : 0, live);
        }
    Stdio.printf("copy live %d\n", live);

    // Assignment over an instance, and onto itself.
        {
        Holder a = mk(2);
        Holder c = mk(3);
        c = a;
        Stdio.printf("assign same %d live %d\n", c.t.id == a.t.id ? 1 : 0, live);
        c = c;
        c = mk(4);
        Stdio.printf("assign n %d live %d\n", c.n, live);
        }
    Stdio.printf("assign live %d\n", live);

    // Early return, break, continue and goto out of a scope.
    Stdio.printf("early %d live %d\n", early(5), live);
    Stdio.printf("early %d live %d\n", early(0), live);
    for (i32 i = 0; i < 10; i++)
        {
        Holder h;
        h.t = new Tracker();
        if (i == 3)
            continue;
        if (i == 6)
            break;
        }
    Stdio.printf("break live %d\n", live);
    i32 w = 0;
    while (w < 5)
        {
        w = w + 1;
        Holder h;
        h.t = new Tracker();
        if (w == 2)
            continue;
        }
    Stdio.printf("while live %d\n", live);
    Stdio.printf("goto %d live %d\n", viaGoto(2), live);
    Stdio.printf("goto %d live %d\n", viaGoto(0), live);

    // Return by value moves; a temporary is released after its statement.
    for (i32 i = 0; i < 100; i++)
        {
        Holder a = mk(i);
        Holder b = viaLocal(i);
        Holder c = forward(i);
        }
    Stdio.printf("return live %d\n", live);
    Stdio.printf("temp %d live %d\n", mk(9).n, live);
    Stdio.printf("temp id %d\n", mk(10).t.id > 0 ? 1 : 0);
    i32 z = mk(11).n + mk(12).n;
    Stdio.printf("temps %d live %d\n", z, live);
    if (mk(13).n == 13 && mk(14).n == 14)
        Stdio.printf("cond live %d\n", live);
    Stdio.printf("cond after %d\n", live);
        {
        Holder s = mk(20);
        Holder d = s.dup();
        Holder e = copyOut(s);
        Holder f = pass(s);
        Stdio.printf("dup %d %d %d live %d\n", d.n, e.n, f.n, live);
        }
    Stdio.printf("dup live %d\n", live);

    // A conditional arm's temporaries come apart on the path that made them.
    i32 q = live > 100 ? mk(30).n : mk(31).n;
    Stdio.printf("ternary %d live %d\n", q, live);
        {
        Holder s = mk(32);
        Holder tv = q > 30 ? mk(33) : s;
        Holder tw = q < 30 ? mk(34) : s;
        Stdio.printf("ternary value %d %d live %d\n", tv.n, tw.n, live);
        }
    Stdio.printf("ternary live %d\n", live);

    // A user dealloc runs once for each instance, the subclass's ivars too.
    Stdio.printf("noisy\n");
        {
        Noisy a;
        a.n = 1;
        a.t = new Tracker();
        Noisy b = a;
        b.n = 2;
        Noisy m = mkNoisy(3);
        Stdio.printf("  temp %d\n", mkNoisy(4).n);
        Child k;
        k.n = 5;
        k.u = new Tracker();
        }
    Stdio.printf("noisy live %d\n", live);

    // A struct member's references belong to the instance.
        {
        Boxed b;
        b.p.a = new Tracker();
        b.t = new Tracker();
        Boxed c = b;
        Stdio.printf("boxed same %d live %d\n", c.p.a.id == b.p.a.id ? 1 : 0, live);
        }
    Stdio.printf("boxed live %d\n", live);

    // A weak ivar is not retained, and a copy is linked in its own right.
        {
        Tracker* r = new Tracker();
        Linked a;
        a.w = r;
        Linked b = a;
        Stdio.printf("weak set %d %d\n", a.w != (Tracker*)0 ? 1 : 0, b.w != (Tracker*)0 ? 1 : 0);
        r = (Tracker*)0;
        Stdio.printf("weak gone %d %d\n", a.w == (Tracker*)0 ? 1 : 0, b.w == (Tracker*)0 ? 1 : 0);
        }
    Stdio.printf("end live %d\n", live);
    return 0;
    }
