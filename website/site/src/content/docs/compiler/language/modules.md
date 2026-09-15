---
title: Modules & shared libraries
description: Building an xcc shared library with --emit-lib, importing it with #import <Lib>, what crosses the interface, and the extern keyword for globals.
---

On every target with a dynamic loader (the native hosts `arm64`, `x86_64`, `win64`, and
**arm9** under XTOS), a program can be split into a **shared library** and its clients. The
library is a real `.dylib` / `.so` / `.dll`. The client is type-checked against the actual
binary, not against a header that might have drifted from it.

```bash
# build the library (native host — add -A arm9 etc. to cross-compile)
xcc --emit-lib -o libXtg.dylib xtg.xc

# build a client against it
xcc -L . -o app app.xc
```

`--emit-lib` also writes a sibling `.xtc.iface` describing the classes, protocols, structs
and enums the library exports, which `#import <Lib>` reads. The 6502 and m68k targets
have no dynamic loader and remain whole-program.

```c
#import <Xtg>          // resolves to libXtg.so on the -L search path

i16 main(void)
{
    XGButton* b = new XGButton();   // a class from the library
    b.setAction(&onClick);          // …taking a bound method from HERE
    return 0;
}
```

## The interface travels with the binary

`--emit-lib` embeds a description of the library's public API in the `.so` itself (an
`.xtc.iface` section), and `#import <Lib>` reads it back. There is no header file to keep in
sync: the types you compile against are the types the library was built with.

## What crosses the boundary

A library can export:

| | |
|---|---|
| **classes** | with inheritance, static methods, and virtual dispatch, including the library calling back into a client subclass |
| **protocols** | with working dispatch across the `.so` (see below) |
| **structs** | by value, in and out of a library method |
| **enums** | both the constants and the type name |
| **free functions**, **typedefs** | |
| **`weak:` fields** | object references; a `callback` field is already non-owning |
| **bound methods** (`callback`) | widened plain functions and bound `&obj.method` alike |
| **C types from another library** | by reference, not by copy (see below) |

### Protocols across a `.so`

A protocol method's dispatch index is its position in the protocol's own declaration, so
every module derives it identically without coordination. The protocol's identity is a
hash of its name, a value and not an address.

Two libraries built independently, neither importing the other, have no way to agree on a
shared slot number, and they do not need one. A class conforming to a protocol from each
dispatches correctly through both.

### C types come by reference

A binding library, one that exposes a C library, has a problem to solve. If `libXtg`
exposes GEM's `OBJECT`, that type belongs to **libGEM**, not to Xtg, so Xtg does not
describe it.

The interface records only where the type lives (`"cImports": ["GEM"]`), and the client
re-imports the same `libGEM.so` through the same DWARF reader, so there is one source of
truth. Copying the layout would let two libraries silently disagree about `OBJECT` after a
header change. A layout disagreement across a `.so` is the worst failure there is, because
nothing type-checks it and nothing reports it.

The client does not need to know: importing `libXtg` pulls in `libGEM`.

## `extern` — globals are module-scoped

A global belongs to the module it was compiled in. To refer to one that lives in another
module, declare it `extern`:

```c
extern u16 gCounter;      // DEFINED in the library; reserve no storage here

i16 main(void)
{
    gCounter = (u16)10;   // the app writes it…
    bump();               // …the library increments it…
    return (i16)gCounter; // …and both see the same variable. 11.
}
```

Without `extern`, a plain declaration defines a second copy in the client, and writes
through it silently never reach the library's copy. An imported library's globals are not
injected without `extern`: referring to one you have not declared `extern` gives
*"Undefined identifier"*.

`extern` globals may not have an initialiser, because the defining module owns it.

## Importing a C library

`#import <Foo>` also works for a plain C `.so`. It has no `.xtc.iface`, so xcc reads its
**DWARF** instead and brings in its functions, its types and its enum constants:

```c
#import <GEM>

if (obj.ob_state == OS_DISABLED) { … }     // OS_DISABLED comes from the .so
```

:::caution[Build the C library with `-fno-eliminate-unused-debug-types`]
gcc's `-feliminate-unused-debug-types` is on by default, and using an enumerator does not
count as using the enum type. A header that declares its constants in an enum whose type is
never named (most of them) loses every constant from its DWARF.

One flag on the C library's build brings them all back, at zero runtime cost (only debug
sections grow, and they are not loaded):

```make
CFLAGS += -g -fno-eliminate-unused-debug-types
```
:::

## Limits

- **6502 and m68k are whole-program.** They have no dynamic loader, so `--emit-lib` does
  not apply there.
- **No limit on exported symbols.** The Mach-O export trie is a real prefix tree, so a
  macOS dylib exports as many symbols as an ELF or PE library does.
- **A library and its dependencies compose**, transitively. Two libraries built without
  knowledge of each other also compose, which is what the protocol design above provides.
