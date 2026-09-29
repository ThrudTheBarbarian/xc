---
title: AsyncFiles
description: "Files operations run off the calling thread, in order, with a completion block: read, write and append without blocking. A complete method reference."
---

`AsyncFiles` queues the [`Files`](/compiler/api/files/) operations and runs
them on a background thread, so the calling thread does not wait for the
disk.

```c
#import "AsyncFiles.xc"
```

## Overview

Each call returns at once. When the operation has finished, its completion
block is called with the result [`Files`](/compiler/api/files/) would have
returned:

```c
AsyncFiles.writeText(path, text, block void(bool ok) { … });
AsyncFiles.readText(path, block void(String* text) {
    if (text == 0) { /* no such file */ }
    });
```

One worker runs the queue **in order**. A read queued after a write of the
same file reads what was written, and two appends land in the order they were
made.

A completion may be `0` when the caller does not need the result.
[`drain`](#drain) blocks until everything queued so far has run and its
completion has returned. A command-line program calls it before it exits, and
a test calls it before it checks the files.

:::caution[Threads]
Completion blocks run on the worker thread, not the thread that queued the
operation. Anything a block shares with the rest of the program needs a
`Mutex`, and a UI toolkit's objects should only be touched from the toolkit's
own thread. Importing `AsyncFiles.xc` turns on thread-safe reference counting,
as any use of `Thread` does.
:::

:::note[Availability]
`AsyncFiles` needs threads: **arm64** (macOS, iOS, Android), **x86_64**,
**win64** and **arm9**. Importing it on **xt6502**, **m68k** or **wasm32** is a
compile-time error.
:::

## Methods

### readText

```c
static void readText(String* path, block cb void(String*))
```

Reads the file as text; `cb` gets the text, or `0` when the file cannot be
read.

### readData

```c
static void readData(String* path, block cb void(Data*))
```

Reads the file's bytes; `cb` gets them, or `0` when the file cannot be read.

### writeText

```c
static void writeText(String* path, String* text, block cb void(bool))
```

Replaces the file with `text`; `cb` gets whether it worked.

### writeData

```c
static void writeData(String* path, Data* data, block cb void(bool))
```

Replaces the file with `data`; `cb` gets whether it worked.

### appendText

```c
static void appendText(String* path, String* text, block cb void(bool))
```

Adds `text` to the end of the file, creating it if needed; `cb` gets whether
it worked.

### drain

```c
static void drain(void)
```

Blocks until every operation queued before the call has run and its
completion has returned. Do not call it from a completion block: the worker
would wait for itself.
