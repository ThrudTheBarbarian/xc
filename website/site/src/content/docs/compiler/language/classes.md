---
title: Classes
description: Class declaration, instance and stack allocation, methods, init/dealloc, properties, static methods.
---

A class is a struct with state and behaviour: instance variables (ivars), methods, optional static methods, an `init` constructor, and a `dealloc` destructor. By convention each class lives in its own file named `<classname>.xc`, so `#import "Foo.xc"` resolves it. The compiler does **not** enforce this: a single file may hold several classes, and the filename need not match the class name.

```c
class Gfx {
    u8 red;
    u8 green;
    u8 blue;

    void hLine(u16 x, u8 y, u8 len) {
        // …
    }
}
```

## Two ways to allocate

Choose the form that fits the lifetime. The syntax tells the compiler everything it needs.

Below, the **enclosing scope** of a declaration is the `{ }` block that contains it, usually a function body, a loop body, or a branch of an `if` or `switch`. When the closing brace executes, the variable goes out of scope: its storage is no longer live, and under default ARC any heap reference it held is released.

### Stack instance

```c
MyClass mine;          // zero-filled, init() runs, storage reclaimed at scope exit
```

A bare `MyClass mine;` allocates the instance in the enclosing scope's local
storage. It is zero-filled on entry to the scope, the parameterless `init()`
(if present) runs automatically, and the bytes are reused when the scope
closes. It does **not touch the heap**, so it is safe to declare inside a loop
body; the same storage serves every iteration.

Where local storage lives depends on the target. It matters only when you are
counting bytes:

| Target | A stack instance lives in |
|---|---|
| `arm64`, `x86_64`, `win64`, `arm9`, `m68k` | the function's stack frame, like any other local |
| `xt6502` | the SP-relative frame, with small hot ivars promoted into zero page where they fit |

The semantics are the same on every target. The practical difference is scale:
on xt6502 a large stack instance competes for a scarce resource, so a class
with many ivars often belongs on the heap. On the register machines a stack
frame is cheap.

### Heap instance

```c
MyClass* mine = new MyClass();
```

This allocates on the heap and returns a pointer to a block whose **reference count is 1**, in every `-farc` mode. The mode decides who balances the reference:

- **Under default ARC** (`-farc=on`, the default): the variable holding the pointer owns the reference. When its scope exits, the compiler emits a `release`. If that release drops the refcount to zero, the block's `dealloc()` runs and the bytes return to the free list. You write `new MyClass()` and the lifecycle is handled for you.
- **Under `-farc=off`**: the compiler emits **no automatic releases**. The variable still receives the `+1` from `new`, and you must call `release ptr;` (or its alias `delete ptr;`) before the last reference disappears, or the block leaks.

In both modes, use this form when the instance must outlive the scope that created it. The full lifecycle is on [Heap, ARC & weak refs](/compiler/language/memory/).

### Parameterised construction

Both forms accept an argument list, which is dispatched to a matching `init(...)` on the class. A class may declare several `init` overloads with different parameter types; the compiler picks the one whose signature matches the call.

```c
class Sprite {
    u16 x;
    u16 y;
    u8  tint;

    void init(void)                       { x = 0;   y = 0;   tint = 0; }
    void init(u16 px, u16 py)             { x = px;  y = py;  tint = 0; }
    void init(u16 px, u16 py, u8 t)       { x = px;  y = py;  tint = t; }
}

void main(void) {
    Sprite  origin;                       // stack, init()        → (0, 0, tint 0)
    Sprite  ship(160, 96);                // stack, init(160, 96) → (160, 96, tint 0)
    Sprite* boss = new Sprite(80, 40, 7); // heap,  init(80, 40, 7)
}
```

The matching overload must exist: `Sprite ship(160, 96);` against a `Sprite` that only declares `init(void)` is a compile-time error. See [Functions → Function overloading](/compiler/language/functions/#function-overloading) for the general resolution rules.

## Methods

Methods are declared inside the class body. The receiver `self` is implicit:

```c
class Counter {
    u16 n;

    void init(void)    { n = 0; }
    void tick(void)    { n = n + 1; }
    u16  value(void)   { return n; }
}

void main(void) {
    Counter c;
    c.tick();
    c.tick();
    Stdio.printInt(c.value());      // 2
}
```

The method receiver is a pointer behind the scenes, whether the instance is on the stack or the heap, so dot-syntax calls (`c.tick()`) read the same for both.

## Constructors: `init`

Any method named `init` whose signature matches the construction arguments is the constructor. xcc supports multiple `init` overloads through the same parameter-type overloading as ordinary functions:

```c
class Sprite {
    u16 x; u16 y;

    void init(void)              { x = 0;  y = 0;  }
    void init(u16 px, u16 py)    { x = px; y = py; }
}
```

`Sprite a;` calls `init()`; `Sprite b(160, 96);` calls `init(160, 96)`.

xcc has **no operator overloading**, only method overloading.

## Destructor: `dealloc`

`dealloc(void)` runs when a heap-allocated class instance's refcount reaches zero, before the bytes return to the free list. Every class gets an auto-generated empty `dealloc` stub. Override it only when the instance owns external state (open files, mapped I/O, caches the ARC walker does not see).

```c
class Buffer {
    u8* bytes;
    u16 len;

    void init(u16 n) {
        bytes = new u8[n];
        len   = n;
    }

    void dealloc(void) {
        // bytes is a strong class-pointer ivar — the aggregate
        // walker releases it automatically. Override dealloc only
        // for things the compiler can't see (hardware, logging,
        // cache invalidation, …).
    }
}
```

`dealloc` runs **once**, when the last owning reference is dropped. For arrays of class instances (`new T[N]`), `dealloc` runs once per element before the whole block is freed.

With inheritance, the `init` chain runs parent-first and the `dealloc` chain runs subclass-first. Both walk up to the universal `Object` base. See [Inheritance & protocols → Construction and destruction](/compiler/language/inheritance/#construction-and-destruction).

## Static methods

A `static` method is a class-scoped function. It is callable without an instance and has no access to instance variables.

```c
class Math {
    static u16 lerp(u16 a, u16 b, u8 t) {
        return a + (((b - a) * t) >> 8);
    }
}

u16 mid = Math.lerp(0, 100, 128);
```

Use static methods for operations that belong to a class but need no per-instance state. They give you a namespace without dispatch overhead.

### Bare-call promotion: `use ClassName`

`use ClassName;` is a top-level directive that adds a class's static methods to the bare-identifier call lookup for the rest of the file. After `use Stdio;`, you can call `printf("hi\n")` instead of `Stdio.printf("hi\n")`.

```c
#import <Stdio.xc>
#import <Math.xc>

use Stdio;
use Math;

void main(void) {
    printf("answer = %u\n", 42);    // resolves to Stdio.printf
    u8 r = rand((u8)100);           // resolves to Math.rand
}
```

Resolution is the same as for a normal `Klass.method(...)` call: overload scoring, varargs handling, the static-init guard, and the implicit `__sdata_<class>` self-pointer. The receiver comes from the `use` directive instead of the call site.

**Composition.** Multiple `use` directives combine: `use Stdio;` and `use Math;` together let you write `printf(...)` and `rand(...)` bare. If two `use`'d classes both have a static method with the same name and an overload would match the call, sema reports the call as ambiguous. Write the explicit `Klass.method(...)` form to disambiguate.

**Scope.** A `use` directive affects only **bare identifiers**. Fields, local variables, free functions, and explicit `Klass.method(...)` calls keep their normal lookup. The directive applies to the **textual file** and does not propagate across `#import`, so a class's source can `use` whatever it likes without affecting the files that import it.

**Pair with `#use` for one-line setup.** The preprocessor has a one-token shorthand that combines the import and the promotion:

```c
#use Stdio          // == #import "Stdio.xc" + use Stdio;

void main(void) {
    printf("hello\n");
}
```

See [Preprocessor → `#use`](/compiler/language/preprocessor/#importing-and-promoting-a-class-use) for the angle-bracket and quote forms.

## Properties

Dot-syntax member access becomes a method call **when a method by that name exists**:

- **Read**: `obj.name` becomes `obj.name()` when the class has a zero-arg method `name`.
- **Write**: `obj.name = value` becomes `obj.setName(value)` when the class has a one-arg method `setName` whose parameter accepts `value`'s type. Camel-casing applies: `foo` ↔ `setFoo`, `lineWidth` ↔ `setLineWidth`.

Each side is resolved independently. You can provide a getter, a setter, or both; a side without an accessor uses direct ivar access. With neither, the access is a plain ivar read or write.

```c
class Box {
    u8 _w;                          // backing ivar (underscored by convention)

    void init(void)    { _w = 0; }
    u8   w(void)       { return _w; }
    void setW(u8 v)    { if (v > 100) v = 100; _w = v; }   // clamp
}

void main(void) {
    Box* b = new Box();
    b.w = 150;          // calls setW(150); _w becomes 100
    u8 v = b.w;         // calls w(); returns 100
}
```

The rewritten call behaves like a direct method call: virtual dispatch (for accessors overridden in subclasses), banked-heap bank switching, and ARC parameter retain / release all apply. A setter may take a different parameter type from the backing ivar; the compiler checks the right-hand side against the setter's parameter type.

### One sharp edge: don't call `self.name` inside the accessor

`self.w` inside the getter `w()` recurses forever. **Read the bare ivar instead** (`_w` in the example). Giving the ivar a different name from the accessor, such as with a leading underscore, avoids the problem.

### Compound assignment through setters

`b.w += 1` becomes `b.w = b.w + 1`, so the read uses the getter and the write uses the setter. The base expression (`b`) is evaluated **twice**. This is harmless for identifiers and `self`, but matters if the base has a side effect such as a function call.

## Bound methods (`callback`)

`&obj.method` yields a **bound method**: a `{receiver, code}` pair you can store in a field,
pass as an argument, and call later. It is the callback type.

```c
class Button {
    callback action u16(void);                        // a control that STORES an action
    void setAction(callback a u16(void)) { action = a; }
    u16  fire(void) { if (action) { return action(); } return (u16)0; }
}

Controller* c = new Controller();
Button* b = new Button();

b.setAction(&c.save);        // a bound METHOD — the receiver rides along
b.setAction(&freeFn);        // a plain FUNCTION — widened into the same type
b.setAction(&Ctl.onClick);   // a STATIC method — no receiver, widens the same way
```

All three fill the same field. A plain function has no `self`, so widening wraps it and the
call site does not need to know which kind it holds. This is the target/action pattern.

### A callback never owns its receiver

Retaining the receiver would refcount a `.text` address for a widened function, and would
create a retain cycle for a bound method: a control that owns its target, which owns the control.

A **stored** callback therefore always auto-zeroes. When the receiver dies, the callback becomes
null and `if (action)` is false. This uses the same machinery as
[`weak:`](/compiler/language/memory/#weak-references), applied automatically. Writing
`weak:` on a callback is an error, because there is nothing to opt into. There is no
`unowned` form either, because a callback cannot check a dead receiver for you.

### Identity

A callback compares as a pair, so two callbacks naming the same action are equal. This is how
`removeAction(&f)` finds what `addAction(&f)` stored.

## What's next

- [Inheritance & protocols](/compiler/language/inheritance/): single inheritance, virtual dispatch, downcasts, protocols.
- [Heap, ARC & weak refs](/compiler/language/memory/): lifecycle of heap-allocated class instances.

## Worked example

A class, a convenience constructor, static state, `description()` and ARC-driven `dealloc`:

```c
// classes.xc — declaring a class, allocating one, and letting ARC free it.
#import "Foundation.xc"
#import "Stdio.xc"

class Point : Object
{
    // Instance variables. One `static` copy per CLASS is also allowed.
    i16 _x, _y;
    static u16 _made;          // how many Points have ever been built

    // init() runs on `new`. A subclass's init chains to its parent
    // automatically — you do not call super.init() by hand.
    void init(void)
    {
        _x = (i16)0;
        _y = (i16)0;
        _made = _made + (u16)1;
    }

    // A static method is called on the class, not on an instance. This is
    // the usual way to write a convenience constructor.
    static Point* at(i16 x, i16 y)
    {
        Point* p = new Point();
        p._x = x;
        p._y = y;
        return p;
    }

    // Ordinary methods. `self` is implicit.
    i16 x(void) { return _x; }
    i16 y(void) { return _y; }

    void translate(i16 dx, i16 dy) { _x = _x + dx; _y = _y + dy; }

    // Overriding description() gives every printf("%@") a useful form.
    String* description(void)
    {
        String* s = String.withCString("(");
        s.append(String.withI32((i32)_x));
        s.appendCString(", ");
        s.append(String.withI32((i32)_y));
        s.appendCString(")");
        return s;
    }

    static u16 made(void) { return _made; }

    // dealloc runs when the last reference goes. Like init, it chains up
    // the hierarchy on its own.
    void dealloc(void) { Stdio.printf("  dealloc %@\n", self); }
}

i32 main(void)
{
    // `new` allocates on the heap; ARC releases it when the last reference
    // goes out of scope. There is no free() to forget.
    Point* a = Point.at((i16)3, (i16)4);
    Stdio.printf("a        = %@\n", a);

    a.translate((i16)-1, (i16)2);
    Stdio.printf("moved    = %@  x=%d y=%d\n", a, a.x(), a.y());

    // Static state is shared by every instance.
    Point* b = Point.at((i16)10, (i16)20);
    Stdio.printf("b        = %@\n", b);
    Stdio.printf("made     = %d\n", Point.made());

    // Both are released here, at the end of the enclosing scope — watch the
    // dealloc lines appear after this one.
    Stdio.print("end of main\n");
    return 0;
}
```

```
a        = (3, 4)
moved    = (2, 6)  x=2 y=6
b        = (10, 20)
made     = 2
end of main
  dealloc (10, 20)
  dealloc (2, 6)
```

Both objects are released at the end of `main`, so the two `dealloc` lines come after `end of main`. Nothing calls `free`.
