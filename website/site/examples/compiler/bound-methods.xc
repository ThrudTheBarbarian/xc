// bound-methods.xc — `callback`, the type that carries a receiver with it.
//
// `&obj.method` yields a BOUND METHOD: a two-word value carrying the receiver
// and the code address together. Store it, pass it, call it later — the
// receiver travels with it, so there is no separate "context pointer" argument
// and no cast back from void*.
//
// A plain function WIDENS into the same type, so one field accepts either a
// free function or a method on some object. That is the whole of target/action.
#import "Stdio.xc"
#import "Foundation.xc"

// A callback is declared inline: `callback <name> <return>(<params>)`. The
// signature is part of the declaration — there is no separate typedef.

// A free function. It has no receiver, and widens into the same type regardless.
void logIt(i32 v) { Stdio.printf("  free function saw %ld\n", v); }

i32 sumOf(i32 a, i32 b) { return a + b; }
i32 productOf(i32 a, i32 b) { return a * b; }

class Counter : Object
{
    i32 total;
    void init(void) { total = (i32)0; }
    // An ordinary method. `&c.accumulate` binds `c` to it.
    void accumulate(i32 v) { total = total + v; }
    void announce(i32 v) { Stdio.printf("  %s got %ld\n", "counter", v); }
}

// A control that stores an action and fires it later — the classic use.
class Button : Object
{
    // A stored callback is an ordinary field, and it NEVER owns its receiver:
    // that is what stops a view owning its controller and the controller
    // owning the view. Nothing has to be declared to get it.
    callback action void(i32 value);
    String*  title;
    void init(void) { title = 0; }

    static Button* named(string t)
    {
        Button* b = new Button();
        b.title = String.withCString(t);
        return b;
    }

    void click(i32 arg)
    {
        // A callback field is null until assigned, and calling a null one would
        // crash — so guard it. `if (action)` and `action != 0` are both fine;
        // the comparison tests BOTH words of the pair.
        if (!action) { Stdio.printf("  %s has no action\n", title.cString()); return; }
        action(arg);
    }
}

// A callback as a PARAMETER: the callee doesn't care where the behaviour came
// from.
i32 reduce(i32* xs, u32 n, i32 seed, callback f i32(i32 a, i32 b))
{
    i32 acc = seed;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) { acc = f(acc, xs[i]); }
    return acc;
}

i32 main(void)
{
    Stdio.print("bound to an object:\n");
    Counter* c = new Counter();
    callback h void(i32 value) = &c.accumulate;   // receiver + code, in one value
    h((i32)10);
    h((i32)32);
    Stdio.printf("  total %ld\n", c.total);

    Stdio.print("a free function widens into the same type:\n");
    h = &logIt;                      // no receiver — the pair's receiver is 0
    h((i32)7);

    Stdio.print("stored as a field, fired later:\n");
    Button* ok = Button.named("ok");
    Button* mute = Button.named("mute");
    ok.action = &c.announce;         // target/action, with no protocol involved
    ok.click((i32)99);
    mute.click((i32)99);             // never assigned — guarded, not a crash

    Stdio.print("passed as a parameter:\n");
    i32 xs[4];
    xs[0] = (i32)1; xs[1] = (i32)2; xs[2] = (i32)3; xs[3] = (i32)4;
    Stdio.printf("  sum %ld, product %ld\n",
                 reduce(&xs[0], (u32)4, (i32)0, &sumOf),
                 reduce(&xs[0], (u32)4, (i32)1, &productOf));

    // The receiver is part of the value, so two bindings of the SAME method to
    // different objects are different callbacks.
    Counter* d = new Counter();
    callback hc void(i32 value) = &c.accumulate;
    callback hd void(i32 value) = &d.accumulate;
    hc((i32)1); hd((i32)100);
    Stdio.printf("  c=%ld d=%ld same? %d\n",
                 c.total, d.total, (i16)(hc == hd ? 1 : 0));
    return 0;
}
