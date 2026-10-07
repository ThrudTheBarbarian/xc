---
title: UXRscReader
description: "Read a .rsc file, classic GEM body and rsc chunk, into a UXRscDoc."
---

`UXRscReader` reads a GEM resource into a
[`UXRscDoc`](/compiler/api/uxkit/uxrscdoc/), on every backend. From 0.7
(earlier it was part of Rocks).

```c
#import "UXRscRead.xc"
```

## Overview

```c
UXRscDoc* doc = UXRscReader.read(bytes, len);
```

It reads either byte order, packed or pixel coordinates, and the rsc chunk at
`rsh_rssize` in any version (1, 2 or 3): forms and their layouts, logical ids,
class overrides, top-level objects and connections. Extension sections it does
not interpret are kept so that a save writes them back.

A payload it cannot represent yet is counted, not dropped quietly:
[`wasLossless`](#waslossless) says whether anything was.

## Topics

[read](#read) · [reader](#reader) · [warning](#warning) · [wasLossless](#waslossless)

### read

```c
static UXRscDoc* read(u8* bytes, i32 n)
```

The document, or null when the bytes are not a resource.

### reader

```c
static UXRscReader* reader(u8* bytes, i32 n)
```

The reader after reading, for its warning; the document is its `result`.

### warning

```c
u8* warning(void)
```

What could not be kept, or null.

### wasLossless

```c
bool wasLossless(void)
```

## See also

- [`UXRscWriter`](/compiler/api/uxkit/uxrscwriter/)
