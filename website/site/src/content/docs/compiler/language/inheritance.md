---
title: Inheritance & protocols
description: Single inheritance, virtual dispatch, casting objects, and protocols.
---

xcc supports **single inheritance** between classes and **multiple-protocol conformance** for interfaces that cross class trees. Inheritance shares implementation down a single line of descent. Protocols share a *calling convention* across unrelated trees.

## Single inheritance

A class names a single parent after its name with `: Parent`:

```c
class Animal {
    u8 legs;
    void init(void)        { legs = 4; }
    void describe(void)    { Stdio.printf("animal\n"); }
}

class Dog : Animal {
    u8 tailWag;
    void describe(void)    { Stdio.printf("dog\n"); }   // override
    void wag(void)         { tailWag = tailWag + 1; }   // new
}
```

The child inherits the parent's ivars and methods. It can add ivars and methods, and override any inherited method by redeclaring it with the same signature.

A class that does not name a parent inherits from the universal `Object` base: `class Foo { ... }` and `class Foo : Object { ... }` are equivalent.

## Construction and destruction

`init` and `dealloc` chain automatically:

- When you write an `init` in a subclass, the compiler inserts a call to the parent's matching `init` at the **top** of the method body. If no parent `init` matches the argument list, the class is rejected at compile time.
- `dealloc` chains in **reverse**: the subclass's body runs first, then the compiler calls the parent's `dealloc` at the end.

Both chains walk up to `Object`. You can write the chaining explicitly with `super.init(...)` / `super.dealloc()`. This suppresses the automatic call, so you can pass different arguments or defer cleanup.

## Virtual dispatch

Overridden methods dispatch through a per-class **vtable**. Every class gets a unique 16-bit **class id**. `new` stamps it into the first word of the allocation, and a call site reads the id and indexes the class's vtable for the method slot. Because the id is 16 bits, a program is not limited to 255 classes, and the RTTI check below depends on the full width.

Methods that are **never overridden** keep a direct `JSR`. The vtable is used only when there is something to resolve.

A `super.method()` call always goes directly to the parent's body and skips the vtable, however many further subclasses exist.

## Casting objects

Class pointers can move **up** the hierarchy (subclass → ancestor) and **down** it (ancestor → subclass), and the two directions follow different rules. This section also covers same-class casts and casts between unrelated trees.

### Upcasts — always implicit

A `Dog*` is accepted anywhere an `Animal*` is expected, because every Dog is an Animal. The compiler emits no runtime check; the cast is a compile-time no-op.

```c
Dog*    d = new Dog();
Animal* a = d;            // implicit upcast — no check, no cast syntax needed
```

Unrelated class pointers do not alias. Within one line of descent the upcast is free, but assigning a `Cat*` to a `Dog*` is a compile-time error because the trees diverge.

### Call arguments

A call argument follows a looser rule than an assignment. It may also be typed as an **ancestor** of the parameter's class, and it converts without a cast. This is how an element read from an untyped collection (`Object*` from `Array.get`) is passed to a function that takes the element's class. No runtime check is made, so the argument must hold an instance of the parameter's class. Use `(Dog*)a` where you want the check.

An argument whose class is **unrelated** to the parameter's class (neither a subclass nor an ancestor of it) is a compile-time error:

```c
void feed(Dog* d) { ... }

Animal* a = new Dog();
feed(a);            // accepted: Animal is an ancestor of Dog
feed(new Cat());    // error: argument 1 of 'feed': 'Cat' is not a subclass of 'Dog'
```

The rule is the same for a free function, a static or instance method, an implicit-`self` call and a call through a protocol. For a protocol parameter, see [Using a protocol as a type](#using-a-protocol-as-a-type). An assignment does not get the looser rule: `Dog* d = a;` still needs the cast.

### Downcasts — runtime-checked

Recovering a `Dog*` from an `Animal*` variable needs a runtime check, because the runtime type is not known statically. xcc uses the existing `(type)` cast syntax. When the source and target are related classes in the downward direction, the compiler inserts a class-id check.

Two cast forms select how a mismatch is handled:

| Cast | Behaviour on mismatch |
|------|------------------------|
| `(Dog*) animal` | **traps** (executes a `BRK`) |
| `(Dog* ?) animal` | **failable** — yields `(Dog*)0` |

```c
Animal* a = new Dog();
Dog* d   = (Dog* ?)a;    // d != 0; dispatch through Dog's vtable
Cat* c   = (Cat* ?)a;    // c == 0; a isn't a Cat
Dog* d2  = (Dog*)a;      // succeeds; no check fires on match
```

The check reads the 16-bit class id that `new` stamped at payload offset 0, and walks up the `__class_parent` table until the target's id matches or the walk reaches `Object`.

Slot 0 has a second use: a class that needs a vtable stores its vtable *pointer* there instead. The two are distinguished by magnitude. A class id is below `0xFFFF` and any real vtable address is above it, which is why the id must be a full 16-bit value.

### Rules at a glance

- **Upcasts and same-class casts** emit no check; they are compile-time no-ops.
- **Downcasts** emit a runtime class-id check, with the trapping or failable behaviour selected by the cast syntax.
- **A null operand** passes through unchanged for both downcast forms.
- **Casts between unrelated class trees** (neither is an ancestor of the other) are rejected at compile time, since the runtime check could never succeed.
- **The `?` marker is class-pointer-only.** `(u16 ?)x` is a compile-time error.

## Protocols

A protocol is a named interface: a list of method signatures with no bodies, no ivars, and no implementation.

```c
protocol Drawable {
    void draw(void);
    u8   width(void);
}
```

Bodies, instance variables, static methods, and nested declarations inside a protocol are rejected at parse time.

### Conforming to a protocol

A class names the protocols it adopts in a `< ... >` clause after the class name (and after the `: Parent` clause, if any):

```c
class Sprite <Drawable> {
    u8 w;
    void init(void)      { w = 16; }
    void draw(void)      { Stdio.printf("sprite\n"); }
    u8   width(void)     { return w; }
}

class Terrain <Drawable> {
    u8 h;
    void draw(void)      { Stdio.printf("terrain\n"); }
    u8   width(void)     { return h; }
}

class Badge : Sprite <Labelled> {       // parent + protocol
    void label(void)     { Stdio.printf("badge\n"); }
}
```

Both clauses are optional. A class with neither inherits from `Object` and adopts no protocols. A class that claims conformance but omits a declared method is rejected at compile time:

```c
class Broken <Drawable> {
    u8 w;
    // missing draw and width
}
// error: Class 'Broken' claims conformance to protocol
//        'Drawable' but doesn't implement 'draw'
```

**Subclasses inherit their parent's conformances.** If `Sprite` adopts `Drawable`, any subclass of `Sprite` is accepted where a `Drawable` is expected, without re-listing `Drawable`.

### Using a protocol as a type

A protocol name in a type position denotes a value that conforms to the protocol. The pointer form (`Drawable*`) is the common one. It holds a pointer to any conforming instance, whatever its concrete class:

```c
void render(Drawable* d) {
    d.draw();
}

void main(void) {
    Sprite*  s = new Sprite();
    Terrain* t = new Terrain();
    render(s);      // calls Sprite.draw
    render(t);      // calls Terrain.draw
}
```

Passing a non-conforming instance is a compile-time error:

```c
class Vehicle { u8 wheels; }

void main(void) {
    Vehicle* v = new Vehicle();
    render(v);      // error: argument 1 of 'render': 'Vehicle' does not conform to protocol 'Drawable'
}
```

A call argument is refused only when it could never conform. The rule is the same for functions and methods:

- A class argument is accepted if the class, or any subclass of it, conforms. `Object*` is always accepted, since a conforming class may come from another module.
- A protocol value passed where a class is declared is accepted if the class, or any subclass of it, conforms to that protocol.
- A value of one protocol passed where another is declared is accepted if some class conforms to both.

As with a class downcast, no runtime check is made. Assignments keep the strict rule: the value must already conform.

### Optional methods

A protocol method marked `optional` need not be implemented. This supports the
**delegate pattern**, where a delegate implements only the callbacks it needs.

```c
protocol WindowDelegate {
    void willClose(void);
    optional void didResize(u16 w, u16 h);   // may be absent
}

class Lazy <WindowDelegate> {
    void willClose(void) { … }               // didResize omitted — legal
}
```

An unimplemented `optional` method leaves a **null slot**, so you test for it with a null test on
a [bound method](/compiler/language/bound-methods/):

```c
callback resized void(i32 w, i32 h) = &delegate.didResize;
if (resized) { resized(w, h); }              // this IS respondsTo
```

Calling an `optional` method directly is a compile error, because it might be absent. Take
`&delegate.method` and test it.

### `final`

Virtuality is inferred from the whole program: a method that nothing overrides keeps its direct
call and needs no marker. `final` is for `--emit-lib`, where the compiler does not see the whole
program. There, every exported instance method is treated as an override root, because overrides
may live in a client. `final` takes a method back out of the vtable.

### Dispatch

Calls through a protocol-typed pointer go through the receiver's vtable, as class inheritance
does: one indirect call, with no runtime string lookup.

A class may adopt any number of protocols, in any order.

On whole-program targets each protocol method gets a slot in the flat vtable. That does not
work on targets that can be linked as **multiple modules** (`arm9`): two libraries built
independently would number their protocols from the same base, and a class conforming to one
protocol from each could satisfy neither. On those targets a protocol method is identified by
its **index within its own protocol**, which every module derives the same way without
coordination, and the receiver carries a small table mapping protocol → implementations.

This is handled for you, and it is what lets a protocol work across a `.so`. See
[Modules & shared libraries](/compiler/language/modules/).

## Worked example

Single inheritance, virtual dispatch, a protocol as a parameter type, and the
optional-method test in one runnable program:

```c
// protocols.xc
#import "Foundation.xc"
#import "Stdio.xc"

protocol Speaker
{
    String* speak(void);
    optional String* whisper(void);
}

class Animal : Object <Speaker>
{
    String* _name;
    void init(void) { _name = String.withCString("animal"); }
    static Animal* named(String* n) { Animal* a = new Animal(); a._name = n; return a; }
    String* name(void) { return _name; }

    // Virtual by default: a subclass's override wins even through a
    // base-class reference.
    String* speak(void) { return String.withCString("..."); }
    String* description(void) { return _name; }
}

class Dog : Animal
{
    // No init() here — the parent's still runs.
    static Dog* named(String* n) { Dog* d = new Dog(); d._name = n; return d; }
    String* speak(void)   { return String.withCString("Woof"); }
    String* whisper(void) { return String.withCString("woof?"); }   // optional, implemented
}

class Cat : Animal
{
    static Cat* named(String* n) { Cat* c = new Cat(); c._name = n; return c; }
    String* speak(void) { return String.withCString("Meow"); }
    // whisper() deliberately NOT implemented.
}


// Taking the PROTOCOL as the parameter type means this works for anything that
// conforms, including classes written later.
void introduce(Speaker* s)
{
    Stdio.printf("  %@ says %s\n", s, s.speak().cString());

    // An unimplemented optional leaves a NULL vtable slot, so binding it with
    // `&` doubles as "does it respond to this?" — no respondsTo call and no
    // runtime lookup. Calling an optional method directly is a compile error,
    // which is what forces the check.
    callback w String*(void) = &s.whisper;
    if (w != 0) Stdio.printf("    ...and whispers %s\n", w().cString());
    else        Stdio.print("    (does not whisper)\n");
}

i32 main(void)
{
    Animal* d = Dog.named(String.withCString("Rex"));
    Animal* c = Cat.named(String.withCString("Tom"));

    // Virtual dispatch: both are Animal* here, but each speaks for itself.
    Stdio.print("through Animal*:\n");
    Stdio.printf("  %@ -> %s\n", d, d.speak().cString());
    Stdio.printf("  %@ -> %s\n", c, c.speak().cString());

    Stdio.print("through Speaker*:\n");
    introduce(d);
    introduce(c);
    return 0;
}
```

```
through Animal*:
  Rex -> Woof
  Tom -> Meow
through Speaker*:
  Rex says Woof
    ...and whispers woof?
  Tom says Meow
    (does not whisper)
```

`Dog` and `Cat` declare no `init` and no conformance to `Speaker`; they inherit both from
`Animal`. `%@` reaches `description()` through the same vtable that the `speak()` calls use.
