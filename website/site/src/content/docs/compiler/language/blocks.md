---
title: Blocks
description: "Function values with captures (xtc 0.4): declare them like variables, call them like functions, capture by value, and use `block:` for copy-in/write-back when a callback must return results."
---

A block is a function value that captures variables from its enclosing
scope. Declare one like a variable and call it like a function:

```c
block add u32(u16 x, u16 y) = { return (u32)x + (u32)y; }
u32 five = add(2, 3);
```

The declaration follows the same rule as every other declaration in the
language: **the name is the second token**, as in `u32 y = …`.
`block` is the kind, `add` is the name, and the signature
`u32(u16 x, u16 y)` qualifies the declaration, as a function's parameter
list qualifies its name.

## The forms

```c
// Declaration with a body.
block add u32(u16 x, u16 y) = { return (u32)x + (u32)y; }

// Declaration only; assign later. Parameter NAMES are part of the
// declared signature…
block op u32(u16 x, u16 y);
op = add;

// …which is what lets a bare body re-bind it with nothing repeated:
op = { return (u32)x * (u32)y; };

// Inline literal in argument position.
each(block u32(u32 v) { return v * (u32)2; }, (u32)5);

// A block as a parameter — the name rides inside the type, like any
// block declaration.
u32 each(block cb u32(u32), u32 n) { … cb(i) … }

// A block as a return type, a block in `auto`, a null block:
block cb u32(u32) makeAdder(u32 base) { … }
auto add5 = makeAdder((u32)5);
block maybe u32(u32);
maybe = (block u32(u32))0;
if (maybe) { … }                     // test before calling
```

A **named literal** may call itself, which gives recursion without a forward
declaration:

```c
auto fact = block f u32(u32 n) {
    if (n <= (u32)1) { return (u32)1; }
    return n * f(n - (u32)1);
};
```

## Captures are by-value snapshots

A literal captures the locals and parameters its body names, **by
value, at the moment the literal runs**:

```c
u32 base = (u32)100;
block plus u32(u32 n) = { return base + n; }
base = (u32)999;                     // too late
plus(7);                             // 107 — the snapshot holds 100
```

A captured class pointer copies the *reference*: the object is shared
and retained, but the binding is not. Two rules apply to captures:

- **Locals and parameters only.** A block cannot capture `self` or an
  ivar directly. Copy it into a local first (`auto me = self;`), which
  makes the capture visible.
- **No `auto` captures.** A capture needs the declared type at the
  point of capture, so give the variable an explicit type.

## `block:` — write-back captures

A plain capture is a snapshot, so mutating it inside the block changes only the
block's own copy. When a callback must pass a result back to the caller, qualify
the variable with `block:`:

```c
block:u32 total = (u32)0;
each(block u32(u32 v) { total = total + v; return v; }, (u32)5);
// total == 10 right here — no cell, no box
```

The semantics are **copy-in / copy-out** (Ada's value-result, and in
practice what Swift's `inout` does). The block takes a private copy at
creation and writes it back **at every invocation exit**, including an
exit by `throw`. Between calls, the variable holds the latest
written-back value. While the block runs, neither side sees the other's
partial state. The variable remains an ordinary local; `block:` only
permits the capture.

Write-back targets the enclosing stack frame, so a block with
`block:` captures **must not outlive that frame**. The compiler rejects
returning one or storing one into an ivar, global, field or element.
`block:` captures inside a *nested* literal are also rejected. Pass
such a block *down*, to `each`, a sort, or any callee that calls it and
returns. The compiler cannot see a callee that stores its argument for
later (a thread spawn, a registry); results that must survive the frame
belong in an object. `block:` is limited to scalars and pointers.

## What a block is underneath

A block is a heap object: the captures are its fields, ARC owns it, and
calling it is a method call. Everything about objects applies: blocks
pass and return like any reference, `if (blk)` is a null test, storing
a (non-`block:`) block in an ivar keeps it alive, and a block that
captures the only reference to an object keeps that object alive too.
Blocks work on every target, including xt6502, under `-falloc=heap`.

Other limits, beyond the capture rules above: `&obj.method` does not
convert to a block. An inline literal cannot be invoked in the same
expression (`(block …{…})(5)`); bind it to a name first. A block-typed
*ivar* can be called with the `cb(…)` sugar only when it is declared
before the method that calls it; `self.cb.invoke(…)` always works.

## Worked example

`examples/compiler/blocks.xc`, compiled and run by the docs harness:

```c
// blocks.xc — blocks: function values with captures (xtc 0.4).
#import "Stdio.xc"
#import "Foundation.xc"

// A block as a parameter: `each` drives it, the caller supplies it.
u32 each(block cb u32(u32), u32 n)
{
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < n; i++) { acc = acc + cb(i); }
    return acc;
}

// A block as a return value: the captures live in the block, so they
// outlive this frame — ARC owns the block like any other object.
block cb u32(u32) makeAdder(u32 base)
{
    block a u32(u32 n) = { return base + n; }
    return a;
}

i32 main(void)
{
    // Declaration with a body; the call reads like any function call.
    block add u32(u16 x, u16 y) = { return (u32)x + (u32)y; }
    Stdio.printf("add(2,3)      = %ld\n", add(2, 3));

    // Captures are BY-VALUE snapshots, taken when the literal runs.
    u32 base = (u32)100;
    block plus u32(u32 n) = { return base + n; }
    base = (u32)999;                       // too late: plus still sees 100
    Stdio.printf("plus(7)       = %ld\n", plus(7));

    // Re-assignment; a bare body inherits the DECLARED signature.
    block op u32(u16 x, u16 y);
    op = add;
    Stdio.printf("op=add        = %ld\n", op(10, 20));
    op = { return (u32)x * (u32)y; };
    Stdio.printf("op={x*y}      = %ld\n", op(6, 7));

    // Inline literal in argument position; auto infers block types.
    Stdio.printf("each(2n)      = %ld\n", each(block u32(u32 v) { return v * (u32)2; }, (u32)5));
    auto add5 = makeAdder((u32)5);
    Stdio.printf("add5(10)      = %ld\n", add5((u32)10));

    // A NAMED literal can call itself — recursion without a declaration.
    auto fact = block f u32(u32 n) { if (n <= (u32)1) { return (u32)1; } return n * f(n - (u32)1); };
    Stdio.printf("fact(5)       = %ld\n", fact((u32)5));

    // `block:` — write-back captures: copy in at creation, copy out at
    // every invocation exit. The loop below never sees the variable; it
    // still holds the total the moment `each` returns.
    block:u32 total = (u32)0;
    u32 r = each(block u32(u32 v) { total = total + v; return v; }, (u32)5);
    Stdio.printf("total,r       = %ld %ld\n", total, r);

    // Null is a first-class block value; test before calling.
    block maybe u32(u32);
    maybe = (block u32(u32))0;
    if (maybe) { Stdio.printf("unreachable\n"); }
    else       { Stdio.printf("null block    = ok\n"); }
    return 0;
}
```

```
add(2,3)      = 5
plus(7)       = 107
op=add        = 30
op={x*y}      = 42
each(2n)      = 20
add5(10)      = 15
fact(5)       = 120
total,r       = 10 10
null block    = ok
```
