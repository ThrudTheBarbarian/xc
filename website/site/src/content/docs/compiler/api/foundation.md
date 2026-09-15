---
title: Foundation
description: "xcc's standard object library: value wrappers, containers, and the Comparable / Hashable / Enumerable / Copying / Error protocols behind them. One API, two implementations."
---

Foundation is xcc's standard object library: the root [`Object`](/compiler/api/object/),
value wrappers ([`Number`](/compiler/api/number/), [`String`](/compiler/api/string/),
[`Data`](/compiler/api/data/)), containers ([`Array`](/compiler/api/array/),
[`Map`](/compiler/api/map/), [`Set`](/compiler/api/set/)), and the protocols they
are built on.

```c
#import "Foundation.xc"        // the umbrella
```

The umbrella pulls in `Object`, `Comparable`, `Hashable`, `Enumerable`, `Copying`, `CharacterSet`,
`Number`, `String`, `Data`, `Array`, `Map` and `Set`. That is everything below except the
[`Error`](/compiler/api/error/) protocol, which you import by name (`#import <Error.xc>`).

All of it needs a real heap (**`-falloc=heap`**), which is the default on the
6502 `xt` layouts and on every native backend.

## Members

| | |
|---|---|
| [`Object`](/compiler/api/object/) | The universal root class — pointer-identity `equals`, an address-derived `hash`, and the `description` hook every class inherits and overrides. |
| [`Number`](/compiler/api/number/) | Wraps any sized integer or float; cross-kind conversion is lazy and cached. The box a typed collection stores a primitive in. |
| [`String`](/compiler/api/string/) | A heap-owned, NUL-terminated **UTF-8** string. Methods name their unit — `byteAt` counts bytes, `charAt` counts code points. |
| [`Data`](/compiler/api/data/) | An owned heap byte block — opaque bytes, no trailing NUL, with growth, slicing, hex, and the String-encoding bridge. |
| [`Array`](/compiler/api/array/) | An ordered, resizable list of `Object*` with sorting and the callback-based functional methods (`filtered`, `mapped`, …). |
| [`Map`](/compiler/api/map/) | A hash map keyed by anything `Hashable` + `Comparable`; iterates in insertion order. |
| [`Set`](/compiler/api/set/) | A hash set with set algebra (`unionWith`, `intersect`, `subtract`, …). |

### Protocols

| | |
|---|---|
| [`Comparable`](/compiler/api/comparable/) | Required `equals`; **optional** `compare` (`<0`/`0`/`>0`). Every value has equality but not every value has an order, so a class may have one without the other. |
| [`Hashable`](/compiler/api/hashable/) | `hash` + `equals`: equal keys must hash equally. Required for a value to be a `Map`/`Set` key. |
| [`Enumerable`](/compiler/api/enumerable/) | `enumLength` + `enumAt` — the two methods `for (x in collection)` dispatches through. The loop variable is borrowed. |
| [`Copying`](/compiler/api/copying/) | `copy` — an independent duplicate. `String` and `Data` conform. |
| [`Error`](/compiler/api/error/) | A single `message()`, so anything [`throw`](/compiler/language/errors/)n can describe itself. **Not** in the umbrella — import by name. |

Every parentless `class X` inherits from the runtime's built-in
[`Object`](/compiler/api/object/) root, so a `Number*`, a `String*`, or any
class of your own fits wherever an `Object*` is expected. No `: Object`
annotation is needed.

## Two implementations, one API

Foundation exists twice. `support/generic/lib/` is the **32-bit build** (arm64,
arm9, m68k, x86_64), with `u32` indices and a `u32` hash, bounded only by
memory. `support/xt6502/lib/` is the **6502 build**, with `u16` indices and a
`u8` hash, because four-byte index arithmetic on every compare is too costly on
an 8-bit CPU.

Portable source compiles against both builds. A narrower caller index widens at
the call boundary, so `for (u16 i = 0; i < a.count(); i++)` behaves the same on
either target. The per-class pages list anything that differs. The most visible
difference is `Array<i64>` / `Array<double>`, which need `-DENABLE_64BIT=1` on
xt6502 (see [Number § availability](/compiler/api/number/)).

## Element types are erased generics

Every container takes an optional **element type** in angle brackets. It is a
compile-time check that is *erased* at run time: one `Array` implementation
serves every element type, so there is no code-size cost per instantiation.

```c
Array<String>* names = new Array();      // new Array() needs no type argument
names.add(String.withCString("ada"));
String* s = names.get((u32)0);           // a String*, no cast

names.add(Number.withU32((u32)7));       // error: Number is not a subclass of String
```

`Map<V>` names the **value** type; keys are anything conforming to `Hashable`.
Each collection takes one type argument; there is no `Map<K,V>` spelling yet. A
primitive element type works and is enforced (`Array<i32>` refuses a `float`),
but the value is stored boxed in a [`Number`](/compiler/api/number/), and
unboxing happens in **assignment context**: `i32 v = a.get(i)`. Untyped
`Array*` / `Map*` / `Set*` remain valid everywhere. See
[Collections & strings](/compiler/language/collections/) for the full
discussion and the `for … in` caveat.

## Ownership

Containers hold a **strong** reference to everything they store, and release it
when the element is removed or the container is deallocated. Sorting and
reversing move pointers only, with no refcount changes. `sorted()`, `filtered()`,
`mapped()`, `subarray()` and the Set algebra all return **new** containers and
leave the originals untouched.

The default [`Object.hash`](/compiler/api/object/#hash) is derived from an
instance's **address**, so hash order is not reproducible for a `Map` or `Set`
keyed by objects of your own classes. For this reason both enumerate in
**insertion order**. Override `equals`/`hash` together to give your class value
semantics, as [`Number`](/compiler/api/number/),
[`String`](/compiler/api/string/) and [`Data`](/compiler/api/data/) do.
