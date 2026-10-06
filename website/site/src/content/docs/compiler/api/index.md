---
title: Standard library
description: Classes shipped with the xcc compiler for I/O, math, timing, heap introspection, interrupts, assertions and sorting.
---

The xcc standard library is a set of `.xc` classes that ship with the compiler. Each class can be imported by name with `#import`. Most methods are `static`, so most calls look like `Stdio.print("hi\n")` or `Math.rand()` with no instance needed.

## Where the files live

```
support/
  generic/lib/        ← portable classes: work on every target
    Foundation.xc       ← umbrella: Object + Number + String + Data + Array + Map + Set
                          + Bag + Range + BinaryHeap + Cache + Null
    Object.xc           ← the runtime's root class
    Number.xc  String.xc  Data.xc  Array.xc  Map.xc  Set.xc  CharacterSet.xc
    Bag.xc  Range.xc  BinaryHeap.xc  Cache.xc  Null.xc
    JSON.xc             ← JSON text to Foundation objects and back
    CSV.xc              ← comma-separated values to rows and back
    Expression.xc       ← arithmetic expressions evaluated against variables
    NumberFormatter.xc  ← numbers to display text and back
    NotificationCenter.xc ← a publish/subscribe bus
    UndoManager.xc      ← undo and redo
    Progress.xc         ← how far work has got
    StateMachine.xc     ← named states driven by events
    SearchIndex.xc      ← a small full-text index
    Comparable.xc  Hashable.xc  Enumerable.xc  Copying.xc  Codable.xc  Error.xc   ← protocols
    Coder.xc            ← keyed archiving to JSON, with gzip
    Thread.xc  Mutex.xc  Cond.xc  Sem.xc  Atomic.xc  ThreadLocal.xc  Pool.xc
    Assert.xc  Sort.xc
    Platform.xc         ← auto-included prelude
    Settings.xc  Bundle.xc   ← persistent settings, and a program's own files
    Http.xc  HttpTls.xc      ← HTTP/1.1 client and url.fetch transport; https
    AsyncFiles.xc       ← Files operations on a background thread, in order
    RunLoop.xc          ← hand work to one thread, and timers
  arm64/lib/          ← macOS / Linux on 64-bit ARM
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Files.xc  Process.xc
    Gfx*.xc  GfxFactory.xc  Platform.xc
  x86_64/lib/         ← Linux (musl)
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Platform.xc
  win64/lib/          ← Windows; the rest comes from x86_64/ and generic/
    Platform.xc
  arm9/lib/           ← AArch32 / XTOS, plus the GEM app framework
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Files.xc  Process.xc  Runtime.xc
    GApplication.xc  GEvent.xc  XTGem.xc  Gfx*.xc  Platform.xc
  xt6502/lib/         ← the banked 6502
    Stdio.xc  Math.xc  Time.xc  Heap.xc  System.xc  Vbi.xc  FILE.xc  Memory.xc
    Array.xc  Map.xc  Set.xc  String.xc  Data.xc  Number.xc   ← 6502 Foundation build
    Bag.xc                                                   ← 6502 Bag (u16 indexes)
    Enumerable.xc  Hashable.xc                                ← 6502-width protocols
    Gfx*.xc  GfxFactory.xc  mapData.xc  symbols.xc  Platform.xc
  xt6502/asm/         ← 6502 assembly runtime (mul/div, heap, float) — not .xc classes
  xt6502/layouts/     ← .lnk memory maps
  <target>/runtime/   ← the small C host runtime linked into native builds
```

In an **installed** toolchain this tree is `lib/xc/` under the install root
(`xc\` on Windows); see [Install](/compiler/usage/install/). The paths above
show a source checkout. Both layouts resolve.

The compiler's `#import` machinery searches the active target's directory first, then `generic/lib/`, so a class with the same name in both wins on the active platform. This is how `Stdio.xc` gets per-platform implementations, and how Foundation ships two builds behind one API: a 32-bit one in `generic/lib/` and a 6502-tuned one in `xt6502/lib/`. Files with no integer width in them (`Object`, `Comparable`, `Error`, `Assert`, `Sort`, the `Foundation` umbrella) exist once and are shared by both. The width-bearing ones (the containers, plus `Hashable` and `Enumerable`) are duplicated. Every target except xt6502 uses the `generic/lib/` Foundation directly. The **threading** classes (`Thread`, `Mutex`, `Cond`, `Sem`, `Atomic`, `ThreadLocal`, `Pool`) also live in `generic/lib/`, but are a hard `#error` on xt6502 and m68k rather than a stub; see [Threading](/compiler/language/threading/). `Coder` and `Codable` are a hard `#error` on xt6502 only.

`Platform.xc` is different from the rest: the compiler emits an implicit `#import "Platform.xc"` before every compilation. It is where a target's system bindings live, so the user's source stays platform-agnostic. Every shipped copy is currently an empty placeholder.

:::caution[Not everything in `generic/lib/` is portable]
Everything in `generic/lib/` works on every target. `Memory.xc` is not portable (its bodies are inline **6502** assembly), so it lives in `xt6502/lib/`. There is no placeholder on other targets: importing it there is a missing-class error naming the file, rather than a class that compiles and does nothing.
:::

## How `static` makes calling concise

Most library methods are `static`. You can call them three ways:

```c
#import <Stdio.xc>

void main(void) {
    Stdio.print("explicit\n");      // class.method()
}
```

```c
#import <Stdio.xc>

use Stdio;                          // language-level promotion

void main(void) {
    print("bare-call\n");           // resolves to Stdio.print
}
```

```c
#use Stdio                          // preprocessor sugar:
                                    // #import + use in one line

void main(void) {
    print("shortest form\n");
}
```

Bare-call promotion (`use Stdio;` and the `#use` shorthand) is documented under [Classes → Bare-call promotion](/compiler/language/classes/#bare-call-promotion-use-classname) and [Preprocessor → `#use`](/compiler/language/preprocessor/#importing-and-promoting-a-class-use). These pages use the explicit `Klass.method(...)` form because it is unambiguous. In your own code, use whichever form you prefer.

## What's documented here

The reference is grouped the same way as the sidebar. Each class page is a
complete method reference: an overview, the protocols the class conforms to,
and every method grouped by task with a jump-list at the top.

**[Foundation](/compiler/api/foundation/)**: the object library, one page per class.

| Class | Role |
|-------|------|
| [`Object`](/compiler/api/object/) | the runtime's root class — `equals`, `hash`, `description` |
| [`Number`](/compiler/api/number/) | a boxed scalar (any int width, `float`, `double`) for containers |
| [`String`](/compiler/api/string/) | heap-owned UTF-8 string, byte- and character-indexed |
| [`Data`](/compiler/api/data/) | a growable byte buffer, plus the String ⇄ bytes encoding bridge |
| [`Array`](/compiler/api/array/) | an ordered, growable list with map / filter / reduce and sort |
| [`Map`](/compiler/api/map/) | an insertion-ordered hash map |
| [`Set`](/compiler/api/set/) | a hash set with union / intersection / difference |
| [`Bag`](/compiler/api/bag/) | a counted set (from the release after 0.71) |
| [`Range`](/compiler/api/range/) | a half-open index range (from the release after 0.71) |
| [`BinaryHeap`](/compiler/api/binaryheap/) | a priority queue (from the release after 0.71) |
| [`Cache`](/compiler/api/cache/) | a bounded LRU cache (from the release after 0.71) |
| [`Null`](/compiler/api/null/) | the shared "nothing here" object (from the release after 0.71) |
| [`JSON`](/compiler/api/json/) | JSON text to Foundation objects and back (from the release after 0.71) |
| [`Expression`](/compiler/api/expression/) | arithmetic expressions evaluated against variables (from the release after 0.71) |
| [`NumberFormatter`](/compiler/api/numberformatter/) | numbers to display text and back (from the release after 0.71) |
| [`NotificationCenter`](/compiler/api/notificationcenter/) | a publish/subscribe bus (from the release after 0.71) |
| [`UndoManager`](/compiler/api/undomanager/) | undo and redo (from the release after 0.71) |
| [`Progress`](/compiler/api/progress/) | how far work has got (from the release after 0.71) |
| [`StateMachine`](/compiler/api/statemachine/) | named states driven by events (from the release after 0.71) |
| [`SearchIndex`](/compiler/api/searchindex/) | a small full-text index (from the release after 0.71) |
| [`CSV`](/compiler/api/csv/) | comma-separated values to rows and back (from the release after 0.71) |
| [`Coder`](/compiler/api/coder/) | keyed archiving of an object graph to JSON, optionally gzipped |

**Protocols**: [`Comparable`](/compiler/api/comparable/), [`Hashable`](/compiler/api/hashable/), [`Enumerable`](/compiler/api/enumerable/), [`Copying`](/compiler/api/copying/), [`Codable`](/compiler/api/codable/) and [`Error`](/compiler/api/error/), the small interfaces the classes conform to.

**System utilities** (cross-platform):

| Class | Role |
|-------|------|
| [`Stdio`](/compiler/api/stdio/) | formatted output (`printf`), screen/cursor helpers |
| [`Math`](/compiler/api/math/) | random numbers, `sqrt`, trig, log/exp/pow, constants |
| [`Sort`](/compiler/api/sort/) | in-place quicksort with a user-supplied comparator |
| [`Memory`](/compiler/api/memory/) | bulk `memset` / `memclr` / `memcpy` / `memmove` (xt6502) |
| [`Assert`](/compiler/api/assert/) | test-fixture assertions; no-ops under `-DNDEBUG` / `-DRELEASE` |
| [`Settings`](/compiler/api/settings/) | a persistent key/value store: in memory always, in a text file where there is a filesystem |
| [`Bundle`](/compiler/api/bundle/) | where a program's own files live, and the resources inside |
| [`Http`](/compiler/api/http/) | HTTP/1.1 requests, blocking or on their own thread, and the transport behind `url.fetch`; https through the optional TLS library |
| [`Files`](/compiler/api/files/) | whole-file reads and writes, appends, directories and existence checks |
| [`AsyncFiles`](/compiler/api/asyncfiles/) | the `Files` operations off the calling thread, run in order, with a completion block |
| [`RunLoop`](/compiler/api/runloop/) | a queue of blocks run on one thread, posted to from any thread, and timers |

**[6502 (8-bit)](/compiler/api/6502/)**: the utilities the 8-bit target provides in place of an OS: [`Time`](/compiler/api/time/), [`Heap`](/compiler/api/heap/), [`Vbi`](/compiler/api/vbi/), [`System`](/compiler/api/system/). On the native targets these are thin wrappers over the host. On the 6502 they are target-specific implementations.


Also documented: the 6502's graphics classes ([`Gfx`](/compiler/api/gfx/), [`GfxFactory`](/compiler/api/gfxfactory/)), [`FILE`](/compiler/api/file/) (a `stdio`-shaped file layer), [`CharacterSet`](/compiler/api/characterset/), [`string-xt6502`](/compiler/api/string-xt6502/), and the [`symbols`](/compiler/api/symbols/) / [`mapData`](/compiler/api/mapdata/) helpers.

:::note[Not every class exists on every target]
A class present only under `xt6502/lib/` is a compile error on the native backends: `#import <System.xc>` does not resolve at all under `-A arm64`. A class present in both may still expose a narrower API on one of them. The per-class pages state where the two diverge.
:::

## A note on overload resolution by return type

xcc supports overloading by **return type** for zero-arg static methods, and the standard library uses this for `Math.rand()` and the math constants. `auto x = Math.rand();` is ambiguous, because the compiler needs to know which type you want:

```c
u8     a = Math.rand();      // resolves to the u8 overload
u16    b = Math.rand();      // resolves to the u16 overload
float  c = Math.rand();      // resolves to the float overload
double d = Math.rand();      // resolves to the double overload
```

The same applies to `Math.PI()`, `Math.E()` and the other constants: each has a `float`-returning and a `double`-returning overload, picked by the receiving variable's type.
