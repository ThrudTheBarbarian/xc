---
title: UXRscWriter
description: "Write a UXRscDoc as a classic .rsc any GEM AES reads, with the nib chunk after it."
---

`UXRscWriter` writes a [`UXRscDoc`](/compiler/api/uxkit/uxrscdoc/). From 0.7
(earlier it was part of Rocks).

```c
#import "UXRscWrite.xc"
```

## Overview

```c
Data* bytes = UXRscWriter.write(doc);
```

The output is a big-endian classic `.rsc`, readable by GEM resource tools. When
the document has layout variants, a nib graph or names, a version 3 nib chunk follows
at `rsh_rssize`, where a classic AES does not look. A document without either
is written as a plain classic file.

Trees and objects can have names (a tree's `name`, an object's `name`). The
classic format has nowhere to keep them, so they go in a `NAME` section of the
chunk, and a document with names always has one.

Reading a file and writing it back gives the same bytes.

## Topics

[write](#write) · [writer](#writer) · [emit](#emit) · [warning](#warning) · [wasLossless](#waslossless) · [seq](#seq)

### write

```c
static Data* write(UXRscDoc* r)
```

### writer

```c
static UXRscWriter* writer(UXRscDoc* r)
```

The writer, for its warning; call `emit` for the bytes.

### emit

```c
Data* emit(UXRscDoc* r)
```

### warning

```c
u8* warning(void)
```

What the file could not carry, or null.

### wasLossless

```c
bool wasLossless(void)
```

### seq

```c
static bool seq(u8* a, u8* b)
```

Whether two C strings are equal.

## See also

- [`UXRscReader`](/compiler/api/uxkit/uxrscreader/)
