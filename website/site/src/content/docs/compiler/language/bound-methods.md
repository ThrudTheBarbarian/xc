---
title: Bound methods & callbacks
description: The callback type — a receiver and a code address travelling together, so a callback needs no context pointer and no cast.
---

> The language also has [blocks](/compiler/language/blocks/):
> function values that capture arbitrary locals, not only one receiver.
> Use a bound method to "call this method on that object", and a block
> when the callback needs more context.


`&obj.method` yields a **bound method**: a two-word value carrying the receiver
and the code address together. You can store it, pass it and call it later, and
the receiver travels with it.

```c
Counter* c = new Counter();
callback h void(i32 value) = &c.accumulate;   // receiver + code, in one value
h((i32)10);                                   // calls c.accumulate(10)
```

This is the only callback mechanism in xcc. There is no `void*` context
argument to pass through, no cast back from `void*` on entry, and no protocol
to declare for a one-method interface.

## Declaring one

A callback declaration carries its own signature:

```c
callback <name> <return>(<parameters>)
```

```c
callback h void(i32 value);                       // a field or a local
i32 reduce(i32* xs, u32 n, i32 seed,
           callback f i32(i32 a, i32 b));         // a parameter
```

The signature is part of the declaration, so two callbacks written with the same
shape are the same type wherever they appear.

Where you need the type alone (a cast, or a comparison against null), leave the
name out:

```c
(callback void(i32 value))0
```

## A plain function widens into the same type

A free function has no receiver, and widens into a callback with a null receiver
word, so one field can accept either:

```c
void logIt(i32 v) { … }

callback h void(i32 value) = &c.accumulate;   // a method on an object
h = &logIt;                                   // a free function — same type
```

This is the target/action pattern: a control declares one `action` field, and the
client supplies either a method on their controller or a bare function. The
control does not need to know which.

## Guarding one

Calling a null callback crashes, so guard it. Both spellings work, and both test
the whole pair:

```c
if (action == 0) { return; }
if (action) { action(arg); }
```

:::caution[A callback **field** starts null; a **local** does not]
A field is zero-initialised, so an unassigned `action` field is null and the
guard above works.

A local is not zero-initialised. An uninitialised local callback holds whatever
was on the stack, and `if (h)` on it reads garbage:

```c
callback h void(i32 v);        // a LOCAL — not null, just undefined
if (h) { h(1); }               // may call into nothing

callback h void(i32 v) = (callback void(i32 v))0;   // this one is null
```

Assign locals where you declare them, as with any other local. The field case
makes it easy to assume otherwise.
:::

## The receiver is part of the value

Two bindings of the same method to different objects are different callbacks,
and compare unequal:

```c
callback hc void(i32 value) = &c.accumulate;
callback hd void(i32 value) = &d.accumulate;
hc((i32)1);                     // updates c
hd((i32)100);                   // updates d
hc == hd                        // false
```

## Optional protocol methods

A protocol method marked `optional` that a class does not implement leaves a
**null vtable slot**. Taking `&delegate.method` therefore yields a null
callback, and the same null test serves as `respondsTo:`:

```c
callback r void(i32 size) = &delegate.windowDidResize;
if (r) { r(newSize); }              // only if the delegate implements it
```

The delegate pattern therefore works without a separate reflection API.
See [Inheritance & protocols](/compiler/language/inheritance/).

## A callback never owns its receiver

The pattern depends on this property, and it is always on.

A stored callback holds its receiver **without retaining it**, and the receiver
word **auto-zeroes** when the referent dies. A view holding an action that points
back at its controller is therefore not a retain cycle. A fired control whose
controller has gone does nothing instead of calling into freed memory, because
the null guard catches it.

```c
class Button : Object
{
    callback action void(i32 value);     // does not keep the target alive
}
```

:::note[`weak:` on a callback is rejected]
Because the behaviour is automatic, writing the qualifier is an error, not a no-op:

```
error: `weak:` is implied on a callback and cannot be written — a stored
callback always auto-zeroes when its receiver dies. Remove the qualifier.
```

There is nothing to declare and no way to opt out.
:::

A callback holding a widened free function has no receiver, so this costs nothing.

## Worked example

```c
// bound-methods.xc — `callback`, the type that carries a receiver with it.
#import "Stdio.xc"
#import "Foundation.xc"

void logIt(i32 v) { Stdio.printf("  free function saw %ld\n", v); }

i32 sumOf(i32 a, i32 b) { return a + b; }
i32 productOf(i32 a, i32 b) { return a * b; }

class Counter : Object
{
    i32 total;
    void init(void) { total = (i32)0; }
    void accumulate(i32 v) { total = total + v; }
    void announce(i32 v) { Stdio.printf("  %s got %ld\n", "counter", v); }
}

class Button : Object
{
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
        if (!action) { Stdio.printf("  %s has no action\n", title.cString()); return; }
        action(arg);
    }
}

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
    callback h void(i32 value) = &c.accumulate;
    h((i32)10);
    h((i32)32);
    Stdio.printf("  total %ld\n", c.total);

    Stdio.print("a free function widens into the same type:\n");
    h = &logIt;
    h((i32)7);

    Stdio.print("stored as a field, fired later:\n");
    Button* ok = Button.named("ok");
    Button* mute = Button.named("mute");
    ok.action = &c.announce;
    ok.click((i32)99);
    mute.click((i32)99);             // never assigned — guarded, not a crash

    Stdio.print("passed as a parameter:\n");
    i32 xs[4];
    xs[0] = (i32)1; xs[1] = (i32)2; xs[2] = (i32)3; xs[3] = (i32)4;
    Stdio.printf("  sum %ld, product %ld\n",
                 reduce(&xs[0], (u32)4, (i32)0, &sumOf),
                 reduce(&xs[0], (u32)4, (i32)1, &productOf));

    Counter* d = new Counter();
    callback hc void(i32 value) = &c.accumulate;
    callback hd void(i32 value) = &d.accumulate;
    hc((i32)1); hd((i32)100);
    Stdio.printf("  c=%ld d=%ld same? %d\n",
                 c.total, d.total, (i16)(hc == hd ? 1 : 0));
    return 0;
}
```

```
bound to an object:
  total 42
a free function widens into the same type:
  free function saw 7
stored as a field, fired later:
  counter got 99
  mute has no action
passed as a parameter:
  sum 10, product 24
  c=43 d=100 same? 0
```

The program is `website/site/examples/compiler/bound-methods.xc`, and the output
above is its output. `./run.sh bound-methods` builds and runs it.

## Across a shared-library boundary

A callback crosses a `.so` boundary intact, because it is a pair of words, not a
symbol reference. Symbol interposition does not cross: the loader has none, so a
callback built in one module and called in another calls the code that module
holds. See [Modules & shared libraries](/compiler/language/modules/).

## Threading

`Thread.spawn(&obj.method)` takes a callback, so a thread body needs no context
argument: the thread's state is the object the method belongs to.
See [Threading](/compiler/language/threading/).
