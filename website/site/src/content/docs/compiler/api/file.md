---
title: FILE
description: "A stdio-shaped stream layer: an abstract FILE base with concrete console streams, plus the familiar f* helpers (fputc, fgets, fread, fseek and others). A complete method reference."
---

`FILE` is an abstract **stream** base class. It defines the operations every
stream supports (read, write, seek, close, and the end-of-stream / error flags)
and leaves the bytes to concrete subclasses: the console streams
`ConsoleOut` / `ConsoleIn`, and any stream you subclass yourself. On top of it,
the `Stream` class provides `static`, C-`stdio`-shaped helpers
([`fputc`](#fputc), [`fgets`](#fgets), [`fread`](#fread), [`fseek`](#fseek) and
the rest), so code written against the classic `f*` functions ports unchanged.

```c
#import "FILE.xc"
```

## Overview

The file defines two classes, and you use both:

- **`FILE`**: the stream itself. You hold a `FILE*` and call the instance
  methods on it, and the concrete subclass behind the pointer decides what the
  bytes mean. The base implementations return [`EOF`](#the-eof-sentinel), so a
  subclass that does not override a method fails visibly.
- **`Stream`**: a `static` helper class with the stdio-shaped functions. You
  call them on the class (`Stream.fputc(c, f)`, `Stream.stdout()`). Each one
  forwards to the matching `FILE` method, so the two layers always agree.

The two standard streams are lazily constructed singletons:
[`Stream.stdout()`](#stdout) returns a console stream that writes to the host
console, and [`Stream.stdin()`](#stdin) returns the input stream. Both come back
typed as `FILE*`, so they pass anywhere a stream is expected.

### The EOF sentinel

Every single-byte read ([`readChar`](#readchar), [`fgetc`](#fgetc),
[`getchar`](#getchar)) and the byte primitives return `i16`, and signal
end-of-stream (or an error) by returning **`EOF`**, which is `(i16)$FFFF`
(`-1`). Test for it as `< (i16)0`. A successful byte read returns the byte value
in the low 8 bits (0–255), which is never negative, so the sign bit
distinguishes data from the sentinel.

### Seek whence values

[`seek`](#seek) / [`fseek`](#fseek) take a `whence` that mirrors `<stdio.h>`:

| Constant   | Value | Meaning                          |
|------------|-------|----------------------------------|
| `SEEK_SET` | `0`   | offset from the start of the stream |
| `SEEK_CUR` | `1`   | offset from the current position |
| `SEEK_END` | `2`   | offset from the end of the stream |

:::note[Availability]
`FILE` is a cross-platform file layer: it ships for **arm9**, **arm64**,
**x86_64**, **wasm32**, **xt6502** and **m68k**. The public API and class shapes
are identical on every target, and the front end resolves dispatch the same way
everywhere. Only the *backend* of the console streams differs: each platform
routes its console I/O through its own console primitive. Code written against
the API below is portable across all of them.
:::

## Topics

**Streams** · [init](#init) · [read](#read) · [write](#write) · [seek](#seek) · [close](#close) · [eof](#eof) · [error](#error) · [clearerr](#clearerr) · [readChar](#readchar) · [writeChar](#writechar)

**Stdio helpers** · [stdout](#stdout) · [stdin](#stdin) · [fputc](#fputc) · [fgetc](#fgetc) · [getchar](#getchar) · [fputs](#fputs) · [fgets](#fgets) · [gets](#gets) · [fread](#fread) · [fwrite](#fwrite) · [fseek](#fseek) · [ftell](#ftell) · [feof](#feof) · [ferror](#ferror) · [fflush](#fflush) · [fclose](#fclose)

---

## Streams

The instance API on a `FILE*`. Subclasses override the ones they can honour; the
base versions return [`EOF`](#the-eof-sentinel) (or do nothing, for the `void`
methods) so an un-overridden operation is obvious.

### init
```c
void init(void)
```
The default initializer: clears the position and flag state to zero. Called for
you by `new`; you rarely invoke it directly. A subclass override should chain
`super.init()` first.

### read
```c
i16 read(u8* buf, u16 count)
```
Reads up to `count` bytes into `buf`, returning the number of bytes read, or [`EOF`](#the-eof-sentinel) at end of stream / on error. The base
implementation returns `EOF`.

### write
```c
i16 write(u8* buf, u16 count)
```
Writes `count` bytes from `buf`, returning the number written (or
[`EOF`](#the-eof-sentinel)). The base implementation returns `EOF`; a console
stream writes each byte to the host console and advances its position.

### seek
```c
i16 seek(i16 offset, u8 whence)
```
Repositions the stream to `offset` relative to `whence` (see
[Seek whence values](#seek-whence-values)). Returns `EOF` on a stream that does
not support seeking (the base default).

### close
```c
void close(void)
```
Releases any resources the stream holds. A no-op on the base class.

### eof
```c
bool eof(void)
```
`true` once a read has hit end-of-stream (the internal `F_EOF` flag). Cleared by
[`clearerr`](#clearerr).

### error
```c
bool error(void)
```
`true` if an I/O error has been recorded on the stream (the `F_ERR` flag).
Cleared by [`clearerr`](#clearerr).

### clearerr
```c
void clearerr(void)
```
Resets both the end-of-stream and error flags, so the stream can be used again
after a transient condition.

### readChar
```c
i16 readChar(void)
```
Reads and returns one byte in the low 8 bits, or [`EOF`](#the-eof-sentinel) at
end of stream. The single-byte primitive that [`fgetc`](#fgetc) /
[`getchar`](#getchar) build on; concrete input streams override it.

### writeChar
```c
i16 writeChar(u8 c)
```
Writes one byte and returns it (or [`EOF`](#the-eof-sentinel) on error). The
primitive behind [`fputc`](#fputc) / [`fputs`](#fputs); concrete output streams
override it.

[↑ Topics](#topics)

## Stdio helpers

`static` functions on the `Stream` class, shaped like the C `stdio` `f*`
family. Each forwards to the corresponding [`FILE`](#streams) method on the
stream you pass (or on the standard stream, for the argument-less ones), so
each behaves the same as the underlying method.

### stdout
```c
static FILE* stdout(void)
```
The standard output stream, a lazily created singleton that writes to the host
console. Typed as `FILE*`.

### stdin
```c
static FILE* stdin(void)
```
The standard input stream (lazily created). Typed as `FILE*`. On targets with no
wired-up interactive input its reads report a clean [`EOF`](#the-eof-sentinel).

### fputc
```c
static i16 fputc(u8 c, FILE* f)
```
Writes one byte to `f` via [`writeChar`](#writechar). Returns the byte, or
[`EOF`](#the-eof-sentinel) on error.

### fgetc
```c
static i16 fgetc(FILE* f)
```
Reads one byte from `f` via [`readChar`](#readchar). Returns the byte (0–255) or
[`EOF`](#the-eof-sentinel).

### getchar
```c
static i16 getchar(void)
```
Reads one byte from [`stdin()`](#stdin). Shorthand for `Stream.fgetc(Stream.stdin())`.

### fputs
```c
static i16 fputs(string s, FILE* f)
```
Writes the NUL-terminated string `s` to `f`, byte by byte. Returns `0` on
success, or [`EOF`](#the-eof-sentinel) as soon as a byte fails to write. Does not
add a trailing newline.

### fgets
```c
static u8* fgets(u8* buf, u16 size, FILE* f)
```
Reads a line into `buf`, stopping after at most `size - 1` bytes, at end of line,
or at [`EOF`](#the-eof-sentinel). The result is always NUL-terminated. The line
terminator (LF `$0A`, or the `$9B` end-of-line byte) is stored when encountered.
Returns `buf`, or a null pointer if nothing could be read (`size == 0`, or `EOF`
before the first byte).

### gets
```c
static u8* gets(u8* buf, u16 size)
```
[`fgets`](#fgets) from [`stdin()`](#stdin). Unlike C's unbounded `gets`, this one
takes a `size` and is overrun-safe.

### fread
```c
static i16 fread(u8* buf, u16 count, FILE* f)
```
Reads up to `count` bytes from `f` into `buf` via [`read`](#read); returns the
count read (or [`EOF`](#the-eof-sentinel)).

### fwrite
```c
static i16 fwrite(u8* buf, u16 count, FILE* f)
```
Writes `count` bytes from `buf` to `f` via [`write`](#write); returns the count
written (or [`EOF`](#the-eof-sentinel)).

### fseek
```c
static i16 fseek(FILE* f, i16 offset, u8 whence)
```
Repositions `f` via [`seek`](#seek) (see [Seek whence values](#seek-whence-values)).

### ftell
```c
static i16 ftell(FILE* f)
```
Returns the stream's current byte position.

### feof
```c
static bool feof(FILE* f)
```
`true` if `f` is at end-of-stream ([`eof`](#eof)).

### ferror
```c
static bool ferror(FILE* f)
```
`true` if `f` has recorded an error ([`error`](#error)).

### fflush
```c
static void fflush(FILE* f)
```
Flushes any buffered output on `f`. The console streams write immediately, so
this is a no-op for them; it is provided for API compatibility.

### fclose
```c
static void fclose(FILE* f)
```
Closes `f` via [`close`](#close).

[↑ Topics](#topics)

## See also

- [Stdio](/compiler/api/stdio/): the `printf` / `puts` formatted-output layer
  and the shared format contract.
- [String](/compiler/api/string/): the heap-owned string type, for building the
  text you write to a stream.
