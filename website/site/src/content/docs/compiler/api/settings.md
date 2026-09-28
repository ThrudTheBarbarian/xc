---
title: Settings
description: "A persistent key/value store that behaves the same on every target: in memory always, backed by a text file where there is a filesystem. A complete method reference."
---

`Settings` is a small **named set of values** a program reads at startup and
writes back when it changes — the `NSUserDefaults`-shaped hole in the library.
The store itself is memory; persistence is an optional file, so the same source
works on a machine with a filesystem and on one without.

```c
#import "Settings.xc"
```

## Overview

Three constructors, each a superset of the one before:

| | |
|---|---|
| [`Settings.memory()`](#memory) | in memory only. Every target, including those with no filesystem. |
| [`Settings.open(path)`](#open) | memory plus a file: read once here, rewritten whole by [`save`](#save). |
| [`Settings.standard(name)`](#standard) | [`open`](#open) at the conventional per-user path, or [`memory`](#memory) where there is no home. |

Values are read with [`get`](#get) (a `String*`, or null) or the typed
[`getInt`](#getint) / [`getBool`](#getbool), each of which takes a fallback so a
missing key needs no test. Writes go through [`set`](#set) and its typed
siblings; [`remove`](#remove) drops one key.

The store keeps **insertion order**, so [`serialise`](#serialise) writes what was
set, in the order it was set, and saving an unchanged store rewrites the same
bytes.

### The file format

Text, one setting per line:

```
# a comment
alpha = one
beta=two
```

- `#` at the start of a line begins a comment; blank lines are ignored.
- A line with no `=` is not a setting and is dropped.
- Both sides of the `=` are trimmed.
- A value cannot contain a newline; a key cannot contain `=` or `#`.

[`loadText`](#loadtext) reads that format and [`serialise`](#serialise) writes
it. Comments and blank lines are **not** preserved across a load-then-save: the
file is a settings file, not a document.

### Where the standard path is

[`standard`](#standard) resolves the directory in this order, and stops at the
first that applies:

1. `$XCC_SETTINGS_DIR`, when it is set and non-empty;
2. `$HOME/.config/xcc`;
3. nothing — the result is a [`memory`](#memory) store.

The file is then `<dir>/<name>.conf`. A target with no environment to read
answers the same as one with no `$HOME`: a memory store, whose
[`save`](#save) returns `false` rather than pretending.

:::note[Availability]
`Settings` is a `generic/lib/` class and is cross-platform: **arm64**, **arm9**,
**m68k**, **x86_64**, **wasm32** and **win64** all get the file-backed form.
**xt6502** gets the in-memory form only — a 6502 has no filesystem, so
[`save`](#save) and [`reload`](#reload) return `false` there and
`Files` is not even imported. Nothing about the code above changes; only
persistence is unavailable.
:::

## Topics

**Construction** · [memory](#memory) · [open](#open) · [standard](#standard)

**Reading** · [get](#get) · [has](#has) · [getInt](#getint) · [getBool](#getbool) · [count](#count) · [keys](#keys)

**Writing** · [set](#set) · [setInt](#setint) · [setBool](#setbool) · [remove](#remove) · [removeAll](#removeall)

**Persistence** · [path](#path) · [serialise](#serialise) · [loadText](#loadtext) · [save](#save) · [reload](#reload)

---

## Construction

### memory
```c
static Settings* memory(void)
```
A store with no backing file. It works everywhere, and [`save`](#save) reports
`false` because there is nowhere to write.

### open
```c
static Settings* open(String* path)
```
A store backed by `path`. An existing file is read now; a missing one is an
**empty store**, not an error — the first [`save`](#save) creates it. A null or
empty `path` is the same as [`memory`](#memory).

### standard
```c
static Settings* standard(String* name)
```
[`open`](#open) at `<settings dir>/<name>.conf`, where the settings directory is
resolved as described in [Where the standard path is](#where-the-standard-path-is).
Falls back to a memory store when there is no directory to use.

```c
Settings* s = Settings.standard(String.withCString("demo"));
```

[↑ Topics](#topics)

## Reading

### get
```c
String* get(String* key)
String* get(String* key, String* fallback)
```
The value stored under `key`. The one-argument form returns **`0`** when the key
is absent; the two-argument form returns `fallback` instead, so a default needs
no test at the call site.

### has
```c
bool has(String* key)
```
`true` when `key` is present, whatever its value.

### getInt
```c
i32 getInt(String* key, i32 fallback)
```
The value parsed as a decimal integer. Returns `fallback` when the key is absent
or the text is not an integer (a leading `-` or `+` is accepted). The stored text
is not changed by reading it.

### getBool
```c
bool getBool(String* key, bool fallback)
```
The value as a boolean: `true` for `true`, `yes` or `1`, `false` for `false`,
`no` or `0`, and `fallback` for anything else or an absent key.

### count
```c
u32 count(void)
```
How many settings are stored.

### keys
```c
Array* keys(void)
```
A fresh [`Array`](/compiler/api/array/) of the keys, in insertion order.

[↑ Topics](#topics)

## Writing

### set
```c
void set(String* key, String* value)
```
Stores `value` under `key`, replacing any previous value in place — the key
keeps its original position. A null `value` stores the empty string; a null or
empty `key` stores nothing.

### setInt
```c
void setInt(String* key, i32 value)
```
[`set`](#set) with the value written out as a decimal.

### setBool
```c
void setBool(String* key, bool value)
```
[`set`](#set) with the value written as `true` or `false`.

### remove
```c
void remove(String* key)
```
Drops the setting, if it is there.

### removeAll
```c
void removeAll(void)
```
Empties the store. The backing file is untouched until the next
[`save`](#save).

[↑ Topics](#topics)

## Persistence

### path
```c
String* path(void)
```
The backing file, or `0` for a memory-only store.

### serialise
```c
String* serialise(void)
```
The whole store as file text — one `key = value` per line, in insertion order.
This is exactly what [`save`](#save) writes.

### loadText
```c
void loadText(String* text)
```
Replaces the store with what `text` says, in the format described in
[The file format](#the-file-format). `0` empties the store.

### save
```c
bool save(void)
```
Writes the store to the backing file, replacing its contents. `false` when there
is no file to write — a memory-only store, or a target with no filesystem — so a
caller can say the settings did not persist instead of believing they did.

### reload
```c
bool reload(void)
```
Re-reads the backing file. **The file is the truth**: a file that has since gone
leaves the store empty rather than stale. `false` when there is no backing file.

[↑ Topics](#topics)

## See also

- [Bundle](/compiler/api/bundle/): where a program's *files* live, as opposed to
  where its *values* are kept.
- [FILE](/compiler/api/file/): the `stdio`-shaped stream layer — a `FILE*` for
  byte-at-a-time and seekable access.
- [String](/compiler/api/string/): every setting is read and written as one.
