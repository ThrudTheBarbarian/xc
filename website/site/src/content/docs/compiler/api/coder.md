---
title: Coder
description: "Keyed archiving of an object graph to JSON, optionally gzipped: the xc form of NSKeyedArchiver and NSKeyedUnarchiver in one class."
---

`Coder` writes a graph of objects to JSON and reads it back. It is the xc form
of Foundation's `NSKeyedArchiver` and `NSKeyedUnarchiver`, in one class. The
archive can be gzipped.

```c
#import "Coder.xc"
```

## Overview

To archive, pass the root object to [`archive`](#archive) or
[`archiveJSON`](#archivejson). To restore, pass the result to
[`unarchive`](#unarchive) or [`unarchiveJSON`](#unarchivejson):

```c
Data* blob = Coder.archive(root, (u8)6);         // gzip, level 6
try {
    Point* back = (Point* ?)Coder.unarchive(blob);
    ...
} catch (CoderError e) {
    Stdio.printf("%s\n", e.message().cString());
}
```

Your own classes take part through [`Codable`](/compiler/api/codable/): the
coder calls `encodeWithCoder` on each object while it writes, and
`initWithCoder` on each new instance while it reads. Inside those methods, the
`encode…` and `decode…` methods on this page store and fetch values by string
key. Only keyed coding exists.

An object that appears several times in the graph is written once, and every
reference to it points at that one entry. Shared objects stay shared and a
cycle terminates. Identity is the object's address, so two equal strings that
are separate objects stay separate.

:::note[Availability]
Every target except xt6502, where importing `Coder.xc` is a compile error.
Classes are created by name when an archive is read, which needs the
compiler's class-name support (`className` and `newInstanceOfClass` on
[`Object`](/compiler/api/object/)).
:::

## The format

The archive is a JSON object table in the shape `NSKeyedArchiver` uses:

```json
{"$archiver":"Coder","$version":1,
 "$top":{"root":{"$ref":1}},
 "$objects":["$null",
             {"$class":"Point","x":3,"y":4,"next":{"$ref":2}},
             {"$class":"Point","x":5,"y":6,"next":{"$ref":1}}]}
```

Each object is one entry in `$objects`, and `{"$ref":n}` refers to entry `n`.
Entry 0 is always `"$null"`, so `{"$ref":0}` is a null reference. Scalars
encoded with [`encodeI32`](#encodei32) and the others are written inline in
their object's entry.

The library's value types have a native form:

| Type | Written as |
|------|------------|
| `String` | a JSON string |
| `Number` | a JSON number: `42`, `2.5` |
| `Data` | `{"$class":"Data","$base64":"3q2+7w=="}` |
| `Array` | `{"$class":"Array","$items":[2,3,0]}` (indexes into `$objects`) |
| `Set` | `{"$class":"Set","$items":[4,5]}` |
| `Map` | `{"$class":"Map","$keys":[6,7],"$values":[8,0]}` |

A subclass of one of these is archived as that class.

Numbers are exact. Integers keep all 64 bits. A double is written in the
shortest form that reads back as the same value, and reading rounds correctly,
so a double survives the round trip bit for bit. A `Number` holding a float is
always written with a `.` or an exponent (`3.0`, `1.0e+21`) and an integer
never is, so the kind survives too. JSON has no spelling for NaN or the
infinities: inline they are the strings `"NaN"`, `"Infinity"` and
`"-Infinity"`, and a `Number` holding one is
`{"$class":"Number","$double":"NaN"}`.

Strings are written as UTF-8, with `"`, `\` and the control characters escaped.
A `String` whose bytes are not valid UTF-8 is written as
`{"$class":"String","$base64":…}` so it comes back unchanged.

Keys beginning with `$` are reserved for the format. A key of your own that
begins with `$` is written with a second `$` in front and read back as you
wrote it.

## Compression

With a compression level from 1 to 9, [`archive`](#archive) gzips the finished
JSON once, at that level. [`unarchive`](#unarchive) recognises gzip data by its
first two bytes and inflates it first.

The gzip code is part of `Coder`, so no target needs zlib: an RFC 1951 deflate
(LZ77 over hash chains, fixed and dynamic Huffman blocks) and a full inflate,
in the RFC 1952 wrapper with its CRC-32 and length trailer. `gzip -d` reads the
output, and [`gunzip`](#gunzip) reads what `gzip` writes. Both directions are
public as [`gzip`](#gzip) and [`gunzip`](#gunzip) for data that is not an
archive.

## Errors

[`unarchive`](#unarchive), [`unarchiveJSON`](#unarchivejson) and
[`gunzip`](#gunzip) throw a [`CoderError`](#codererror) when the input is not
JSON, is not a `Coder` archive, names a class the program does not have, fails
its CRC or ends early. The message says which.

Inside `initWithCoder` the `decode…` methods do not throw. A missing key reads
as 0, `false` or null, as in Foundation, so a newer class can read an older
archive; [`containsKey`](#containskey) tells the two apart. A value of the
wrong type or out of range for the method is recorded, and
[`unarchive`](#unarchive) throws it once the graph is finished.

## Topics

**Archiving** · [archive](#archive) · [archiveJSON](#archivejson)

**Unarchiving** · [unarchive](#unarchive) · [unarchiveJSON](#unarchivejson)

**Encoding** · [encodeObject](#encodeobject) · [encodeBool](#encodebool) · [encodeI32](#encodei32) · [encodeU32](#encodeu32) · [encodeI64](#encodei64) · [encodeU64](#encodeu64) · [encodeFloat](#encodefloat) · [encodeDouble](#encodedouble)

**Decoding** · [decodeObject](#decodeobject) · [decodeBool](#decodebool) · [decodeI32](#decodei32) · [decodeU32](#decodeu32) · [decodeI64](#decodei64) · [decodeU64](#decodeu64) · [decodeFloat](#decodefloat) · [decodeDouble](#decodedouble) · [containsKey](#containskey)

**gzip** · [gzip](#gzip) · [gunzip](#gunzip) · [crc32](#crc32)

**Errors** · [CoderError](#codererror)

---

## Archiving

### archive
```c
static Data* archive(Object* root, u8 compression)
```
The archive of `root` and everything it refers to. With `compression` 0 the
result is the UTF-8 JSON text; with 1 to 9 it is that text gzipped at that
level (1 fastest, 9 smallest; above 9 counts as 9).

### archiveJSON
```c
static String* archiveJSON(Object* root)
```
The archive as a JSON [`String`](/compiler/api/string/).

## Unarchiving

### unarchive
```c
static Object* unarchive(Data* data) throws
```
The root object of an archive made by [`archive`](#archive), compressed or
not. Downcast the result to the class you expect. Throws a
[`CoderError`](#codererror) for anything it cannot read.

### unarchiveJSON
```c
static Object* unarchiveJSON(String* json) throws
```
The same, from JSON text.

## Encoding

Call these from `encodeWithCoder`. Each writes one value under `key`. Outside
an archive they do nothing.

### encodeObject
```c
void encodeObject(Object* obj, string key)
```
A reference to `obj`, which is archived too the first time it is seen. Null is
allowed.

### encodeBool
```c
void encodeBool(bool v, string key)
```

### encodeI32
```c
void encodeI32(i32 v, string key)
```

### encodeU32
```c
void encodeU32(u32 v, string key)
```

### encodeI64
```c
void encodeI64(i64 v, string key)
```

### encodeU64
```c
void encodeU64(u64 v, string key)
```

### encodeFloat
```c
void encodeFloat(float v, string key)
```
Written in the shortest form that reads back as the same `float`.

### encodeDouble
```c
void encodeDouble(double v, string key)
```
Written in the shortest form that reads back as the same `double`.

## Decoding

Call these from `initWithCoder`. A missing key gives 0, `false` or null. A
value of the wrong type, or one that does not fit the method's type, gives the
same and makes [`unarchive`](#unarchive) throw.

### decodeObject
```c
Object* decodeObject(string key)
```
The object stored under `key`. Downcast it: `(Point* ?)coder.decodeObject("next")`.
Inside a cycle this can be an object whose own `initWithCoder` has not finished.

### decodeBool
```c
bool decodeBool(string key)
```

### decodeI32
```c
i32 decodeI32(string key)
```

### decodeU32
```c
u32 decodeU32(string key)
```

### decodeI64
```c
i64 decodeI64(string key)
```

### decodeU64
```c
u64 decodeU64(string key)
```

### decodeFloat
```c
float decodeFloat(string key)
```

### decodeDouble
```c
double decodeDouble(string key)
```

### containsKey
```c
bool containsKey(string key)
```
Whether the object being decoded has a value under `key`.

## gzip

### gzip
```c
static Data* gzip(Data* data, u8 level)
```
`data` in gzip format, at `level` 1 to 9. Level 0 stores the bytes
uncompressed inside the gzip wrapper.

### gunzip
```c
static Data* gunzip(Data* data) throws
```
The contents of the first member of a gzip stream. Throws a
[`CoderError`](#codererror) for data that is not gzip, is damaged, fails its
CRC or length check, or ends early.

### crc32
```c
static u32 crc32(u8* p, u32 n)
```
The CRC-32 of `n` bytes, as gzip and zip use it.

## CoderError

```c
class CoderError <Error> {
    String* message(void);
}
```
What [`unarchive`](#unarchive), [`unarchiveJSON`](#unarchivejson) and
[`gunzip`](#gunzip) throw. It conforms to [`Error`](/compiler/api/error/);
`message` describes the problem, for example
`Coder: unknown class 'Point'` or `gzip: CRC mismatch`.

[↑ Topics](#topics)
