---
title: Error
description: "Protocol a value must conform to in order to be thrown."
---

`Error` is the protocol a value must conform to before it can be thrown with
`throw`.

```c
class IOError <Error> { ... }
```

## Overview

An error is an ordinary heap object, not a special kind of value. It follows ARC
like any other object, and a caught error is a strong local released at the end
of its `catch` scope. Errors reuse the protocols, RTTI and object model already
in the language rather than adding a separate mechanism.

Conforming requires a single method, so a handler can always describe what it
caught without knowing the concrete type.

## Required methods

### message
```c
String* message(void);
```
Return a human-readable [`String`](/compiler/api/string/) describing the error.
It is the only requirement, so every handler can report a caught error
generically:

```c
try   { i32 n = readCount(p); }
catch (e) { Stdio.printf("failed: %s\n", e.message().cString()); }
```

## Conforming types

`Error` is a contract for **user-defined** error types; the standard library
ships no conformers. A typical conformer stores its own detail and returns it:

```c
class IOError <Error> {
    String* msg;
    void init(String* m)  { msg = m; }
    String* message(void) { return msg; }
}

i32 readCount(String* path) throws {
    File* f = File.open(path);
    if (!f) throw new IOError(String.withCString("cannot open"));
    defer { f.close(); }          // runs on the throw path too
    return f.readInt();
}
```

## Usage

Make any class you intend to `throw` conform to `Error`. A bare `catch (e)`
binds the caught value and can call [`message`](#message) generically. Typed
handlers such as `catch (IOError e)` resolve through the same RTTI downcast that
works across module boundaries, so the protocol needs nothing extra for them.

See also [`Object`](/compiler/api/object/) and the sibling protocols
[`Comparable`](/compiler/api/comparable/), [`Hashable`](/compiler/api/hashable/),
[`Copying`](/compiler/api/copying/) and [`Enumerable`](/compiler/api/enumerable/).
