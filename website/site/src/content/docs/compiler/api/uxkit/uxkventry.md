---
title: UXKVEntry
description: "One cached setting: a key, which of the three types it is, and the value in whichever field that type uses."
---

`UXKVEntry` is one entry in a
[`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/)'s cache.

```c
#use <UXKit>            // or #import "UXKeyValueStore.xc"
```

## Overview

```c
class UXKVEntry : Object {
    u8* key;
    i32 type;     // UXKV_STRING / UXKV_INT / UXKV_BOOL
    u8* str;      // when type is STRING
    i32 num;      // when type is INT or BOOL
}
```

One class holds three types, and `type` says which field is live. A bool is
stored in `num` rather than in a field of its own, as an integer with a
narrower range.

## It is cache, not storage

The entry is a **copy** of what the persistent store holds, kept so a repeated
read costs nothing. The value itself lives wherever the platform keeps
preferences: the system registry on XTOS, `NSUserDefaults` on macOS, an `.ini`
under `%APPDATA%` on Windows.

For this reason
[`invalidate`](/compiler/api/uxkit/uxkeyvaluestore/#invalidate) exists, and
another process writing the same key mid-run
[is not seen](/compiler/api/uxkit/uxkeyvaluestore/#the-cache-and-what-it-costs).
An entry tells you what this process last knew, not what is on disk now.

## Registered defaults are entries too

A registration and a set value are both entries, so
[`hasKey`](/compiler/api/uxkit/uxkeyvaluestore/#haskey) cannot test only
whether an entry exists. The store tracks the distinction separately, so that
`removeKey` can revert to the registration rather than deleting it.

A `UXKVEntry` means *the store has an answer for this key*, not *the user
chose it*.

## Type is not enforced on read

Reading a key with the wrong accessor returns the field that accessor uses,
whatever `type` says. An `intFor` on a string entry reads `num`, which the
string path never filled in.

The type is normally fixed by the code that registers the default at startup,
so this only goes wrong through the app's own mistake. It matters if you change
a setting's type between versions: the stored value does not migrate, and the
old value is read through the new accessor.

## Fields

### key

```c
u8* key
```

### type

```c
i32 type       // UXKV_STRING, UXKV_INT, UXKV_BOOL
```

### str

```c
u8* str
```

Always a **copy** the store made. Settings come back through a shared scratch
buffer that the next call overwrites, so the entry duplicates the text on the
way in, using [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

### num

```c
i32 num
```

The integer, or `0`/`1` for a bool.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/): the store
- [`UXCacheEntry`](/compiler/api/uxkit/uxcacheentry/): the evicting equivalent,
  with a clock because entries leave
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): `settingGet`/`settingSet`
