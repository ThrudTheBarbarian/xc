---
title: Collections & strings
description: Array, Map, Set and String. Element types go in angle brackets, are checked at compile time and erased at run time.
---

The containers are ordinary xcc classes, shipped with the compiler and written in
the same language as your program. Each takes an **element type** in angle
brackets:

```c
Array<String>* names = new Array();
names.add(String.withCString("ada"));
String* first = names.get((u32)0);       // a String*, with no cast
```

`Array<String>` stores and returns `String*`. The use site needs no cast, and
adding a value of the wrong type is a compile error.

The type argument is **erased at run time**. One `Array` implementation serves
every element type, so an instantiation adds no code. The element type is a
static check, with no template expansion. On the 6502 a separate container per
instantiation would not fit.

## Declaring and constructing

The element type goes on the *declaration*. `new Array()` needs no type argument
because it takes the type from the slot it is assigned into.

```c
Array<String>*        names  = new Array();
Array<Point>*         path   = new Array();
Map<String, Point>*   places = new Map();
Set<String>*          seen   = new Set();
```

`Array` and `Set` take one type argument, the element. `Map` takes **two**, the
key and the value:

```c
Map<String, Point>* places = new Map();
places.set(String.withCString("home"), p);   // key must be a String
Point* home = places.get(String.withCString("home"));   // value, no cast
```

A Map with **one** argument types the *value* and leaves the key unchecked. The
key can be anything that conforms to `Hashable`, as `String` and `Number` do:

```c
Map<Point>* loose = new Map();     // value typed, key not
```

That form is not deprecated. Prefer the two-argument form, which checks the key
as well.

## What the element type buys you

It gives three things. The third catches bugs:

```c
Array<String>* names = new Array();

String* s = names.get((u32)0);        // 1. no cast on the way out
for (String* n in names) { … }        // 2. the loop variable is typed

names.add(Number.withU32((u32)7));    // 3. error: Number is not a subclass of String
```

A subclass is accepted wherever the superclass is expected, so an
`Array<Animal>` accepts a `Dog`, and reading it back gives an `Animal*`. A
protocol also works as the element type: `Array<Comparable>*` holds anything
that conforms.

## Primitive element types

A primitive element is stored **boxed**: a `Number` goes into the container, and
an `i32` comes back out. Conformance is checked against the declared type, so an
`Array<i32>` rejects a `float` at compile time even though both box into the
same `Number`.

Every scalar width works as an element type: `i8` through `u64`, `float` and
`double`. `Number` stores integers in an `i64` slot and floating point in a
`double` slot, so no precision is lost. An `Array<i64>` round-trips 2^40, and an
`Array<double>` round-trips a value that has no exact `float` form.

:::note[On xt6502, 64-bit elements are opt-in]
Widening `Number` adds about 4.5 KB to *any* 6502 program that uses the class,
so on that target the wide storage requires `-DENABLE_64BIT=1`. The other five
targets always have it. Without the flag, `Array<i64>` and `Array<double>` are
a **compile error**, so a value is never silently truncated.
:::

The **collection** decides the unboxing, wherever the read appears. `scores` is
declared to hold `i32`, so `scores.get(i)` is an `i32`. The compiler rewrites it
to `((Number*)scores.get(i)).asI32()` in every position:

```c
Array<i32>* scores = new Array();
scores.add((i32)70);
scores.add((i32)95);

i32 v    = scores.get((u32)0);        // 70   declaration
v        = scores.get((u32)1);        // 95   assignment
i32 sum  = scores.get(i) + (i32)5;    // 75   arithmetic
bool hit = scores.get(i) == (i32)70;  // true comparison
Stdio.printf("%ld\n", scores.get(i)); // 70   vararg
i32 pick = c ? scores.get(i) : (i32)0; // 70  ternary arm
for (i32 x in scores) { … }           // 70, 95
```

## `description` and `%@`

`%@` prints an object by calling its `description()` method through the vtable.
`Object` supplies a default. Override it, and every `%@`, container dump and
debug print uses your version:

```c
class Point : Object
{
    i32 x;
    i32 y;
    String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
}

Stdio.printf("last %@\n", path.last());     // last (3|4)
```

## String

`String` is a **mutable object with value identity**:

- `append` grows the receiver in place and returns nothing. `appending` leaves
  the receiver unchanged and returns a new string.
- `equals` compares *bytes*; `==` compares *addresses*. Two separately
  constructed `"ada"` strings are `equals` but not `==`.

```c
String* greeting = String.withCString("hello");
String* longer   = greeting.appending(String.withCString(", world"));
greeting.appendCString("!");
// greeting is now "hello!", longer is "hello, world"
```

Pass the bytes to `printf`'s `%s` with `.cString()`.

A String is UTF-8, and every method that takes an index names its unit:
`byteLength`, `byteIndexOf` and `substringBytes` count bytes; `charCount`,
`charAt` and `substringChars` count code points. The full method list, the
UTF-8 rules and the encodings are on [String (UTF-8)](/compiler/api/string/).

### Formatting

`String` formats with the same specifiers as `Stdio.printf`, with the same width
rules and the same `%@` dispatch to `description()`. It can create a new string
or append to an existing one:

```c
String* s = String.withFormat("(%ld|%ld)", x, y);   // construct
s.appendFormat(" tint=%d", tint);                   // append
```

Supported: `%@` `%s` `%d` `%i` `%u` `%ld` `%lu` `%x` `%lx` `%c` `%f` `%lf` `%%`,
with optional width and zero-padding (`%04lx`). `%d`/`%u`/`%x` are 16-bit and
the `l` forms 32-bit, as in `Stdio.printf`.

The usual way to write `description()`:

```c
String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
```

Searching returns an unsigned index, so a miss is `String.notFound()`, not a
negative number:

```c
u32 at = longer.byteIndexOf(String.withCString("world"));
if (at != String.notFound()) { … }
```

Numbers convert in both directions, including the 64-bit widths:
`String.withI32`, `withU32`, `withI64`, `withU64`, `withFloat(f, precision)`.

## Worked example

This program compiles and runs on every target:

```c
// collections.xc — Array, Map, Set and String, with element types.
#import "Stdio.xc"
#import "Foundation.xc"

class Point : Object
{
    i32 x;
    i32 y;
    void init(void) { x = (i32)0; y = (i32)0; }
    static Point* at(i32 px, i32 py) { Point* p = new Point(); p.x = px; p.y = py; return p; }

    String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
}

i32 main(void)
{
    // ---- Array ----
    Array<String>* names = new Array();
    names.add(String.withCString("ada"));
    names.add(String.withCString("grace"));
    names.add(String.withCString("edsger"));

    Stdio.printf("count %d, first %s\n",
                 (i16)names.count(), names.get((u32)0).cString());

    Stdio.print("names:");
    for (String* n in names) { Stdio.printf(" %s", n.cString()); }
    Stdio.print("\n");

    // ---- Array of your own class ----
    Array<Point>* path = new Array();
    path.add(Point.at((i32)0, (i32)0));
    path.add(Point.at((i32)3, (i32)4));
    Stdio.printf("last %@\n", path.last());

    // ---- Array of a primitive ----
    // A for-in loop variable is a binding, so this reads values, not boxes.
    Array<i32>* scores = new Array();
    scores.add((i32)70);
    scores.add((i32)95);
    i32 total = (i32)0;
    for (i32 v in scores) { total = total + v; }
    Stdio.printf("total %ld\n", total);

    // ---- Map: the type argument is the VALUE type ----
    Map<Point>* places = new Map();
    places.set(String.withCString("origin"), Point.at((i32)0, (i32)0));
    places.set(String.withCString("corner"), Point.at((i32)9, (i32)9));
    Point* corner = places.get(String.withCString("corner"));
    Stdio.printf("corner %@, map holds %d\n", corner, (i16)places.count());
    Stdio.printf("missing is null: %d\n",
                 (i16)(places.get(String.withCString("nowhere")) == 0 ? 1 : 0));

    // ---- Set: membership by VALUE, not identity ----
    Set<String>* seen = new Set();
    seen.add(String.withCString("x"));
    seen.add(String.withCString("y"));
    seen.add(String.withCString("x"));
    Stdio.printf("set holds %d, contains y: %d\n",
                 (i16)seen.count(),
                 (i16)(seen.contains(String.withCString("y")) ? 1 : 0));

    // ---- String ----
    String* greeting = String.withCString("hello");
    String* longer   = greeting.appending(String.withCString(", world"));
    greeting.appendCString("!");
    Stdio.printf("%s / %s (%d chars) / %s\n",
                 greeting.cString(), longer.cString(),
                 (i16)longer.byteLength(), longer.uppercased().cString());

    Stdio.printf("equal by value: %d, same object: %d\n",
                 (i16)(String.withCString("ada").equals(names.get((u32)0)) ? 1 : 0),
                 (i16)(String.withCString("ada") == names.get((u32)0) ? 1 : 0));

    Stdio.printf("index of world: %d, prefix hello: %d, slice %s\n",
                 (i16)longer.byteIndexOf(String.withCString("world")),
                 (i16)(longer.hasPrefix(String.withCString("hello")) ? 1 : 0),
                 longer.substringBytes((u32)7, (u32)5).cString());

    Stdio.printf("i32 %s, u64 %s\n",
                 String.withI32((i32)-42).cString(),
                 String.withU64((u64)1099511627776).cString());
    return 0;
}
```

```
count 3, first ada
names: ada grace edsger
last (3|4)
total 165
corner (9|9), map holds 2
missing is null: 1
set holds 2, contains y: 1
hello! / hello, world (12 chars) / HELLO, WORLD
equal by value: 1, same object: 0
index of world: 7, prefix hello: 1, slice world
i32 -42, u64 1099511627776
```

## Memory

Containers participate in ARC. Adding an object retains it, removing it releases
it, and a container's `dealloc` releases everything it holds. A `for ... in` loop
variable is **borrowed**: the container owns the element for the duration of the
loop, so no retain happens per iteration.

See [Heap, ARC & weak refs](/compiler/language/memory/) for the ownership rules,
and [Foundation](/compiler/api/foundation/) for the complete method lists.
