---
title: Files
description: "Whole-file reads and writes on the host: text or bytes in one call, appends, directories and existence checks. A complete method reference."
---

`Files` reads and writes whole files in one call.

```c
#import "Files.xc"
```

## Overview

```c
String* src = Files.readText(String.withCString("prog.xc"));
if (src == 0) { /* missing or unreadable */ }
```

A file that cannot be read is **`0`**, and an empty file is an empty string, so
"missing" and "empty" stay different answers. A write is `true` only when every
byte was written.

The class is `Files`, not `File`: macOS filesystems ignore case, so a
`File.xc` would be the same file as [`FILE.xc`](/compiler/api/file/), the
console streams.

[`AsyncFiles`](/compiler/api/asyncfiles/) runs the same operations on a
background thread.

:::note[Availability]
**arm64**, **x86_64**, **win64**, **arm9** and **wasm32** (through its
loader). **xt6502** has no filesystem.
:::

## Methods

### readText

```c
static String* readText(String* path)
```

The whole file as a string, or `0` when it cannot be read.

### readData

```c
static Data* readData(String* path)
```

The whole file as bytes, or `0` when it cannot be read.

### writeText

```c
static bool writeText(String* path, String* text)
```

Replaces the file with `text`, creating it if needed.

### writeData

```c
static bool writeData(String* path, Data* data)
```

Replaces the file with `data`, creating it if needed.

### appendText

```c
static bool appendText(String* path, String* text)
```

Adds `text` to the end of the file, creating it if needed.

### setExecutable

```c
static bool setExecutable(String* path)
```

Marks the file executable (mode 0755).

### createDirectory

```c
static bool createDirectory(String* path)
```

Creates a directory. One that already exists counts as success.

### exists

```c
static bool exists(String* path)
```

Whether the path exists. On macOS this ignores case, as the filesystem does.

### existsExact

```c
static bool existsExact(String* path)
```

Whether the path exists with exactly this spelling, case included. Use it
when resolving a name a person typed, so `Sort.xc` does not quietly open
`sort.xc`.

### size

```c
static i32 size(String* path)
```

The file's size in bytes, or -1 when it cannot be opened.
