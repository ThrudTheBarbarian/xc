---
title: UXKeyValueStore
description: "Persistent settings with registered fallbacks and domain layering. NSUserDefaults in shape, writing to wherever the platform keeps preferences."
---

`UXKeyValueStore` is a typed settings store: strings, integers and booleans by
name, **persisted** through the driver's setting seam.

```c
#use <UXKit>            // or #import "UXKeyValueStore.xc"
```

## Overview

```c
UXKeyValueStore* s = UXKeyValueStore.forDomain((u8*)"myapp");

s.registerInt((u8*)"fontSize", 12);       // the fallback
s.intFor((u8*)"fontSize");                // 12 on first launch
s.setInt((u8*)"fontSize", 18);            // now 18, and it survives the process
```

Values go wherever the platform keeps preferences: the **system SQLite registry**
on XTOS (the same database the desktop keeps its own settings in),
`NSUserDefaults` on macOS, an `.ini` under `%APPDATA%` on Windows.

A store made **before a driver is booted**, or on a backend with nowhere to
write, still works in memory. Settings code needs no guard for whether a
platform exists yet, which matters because configuration is usually read
early.

## Registered defaults

```c
s.registerString((u8*)"theme", (u8*)"light");
s.registerInt((u8*)"fontSize", 12);
s.registerBool((u8*)"showGrid", true);
```

A registration is consulted when a key was **never explicitly set**, as with
`registerDefaults`. Register at startup and every read has a sensible answer on
first launch, instead of `0` and `""`.

This has two consequences:

```c
s.hasKey((u8*)"fontSize")       // false — a registered value is not a SET one
s.setInt((u8*)"fontSize", 18);
s.hasKey((u8*)"fontSize")       // true
s.removeKey((u8*)"fontSize");
s.intFor((u8*)"fontSize")       // 12 — back to the registration, not to zero
```

`hasKey` answers "did anyone choose this?", the question a settings panel asks
to show a value as default or customised. `removeKey` means **revert**: the key
falls back to its registration, which is what "Restore Defaults" needs.

## Domains

```c
UXKeyValueStore.standard()                  // shared by every program
UXKeyValueStore.forDomain((u8*)"myapp")     // this app's own
```

A read in a named domain **falls back to the shared value** when the domain has
none:

```
shared editor=rocks   seen from the app domain=rocks
app sets its own:     app=vi   shared still=rocks
```

A machine-wide default is set once, and any app can override it for itself
without coordination. The fallback is applied in this class, not in each
backend, so the rule is the same on every platform.

## The cache, and what it costs

:::caution[Another process writing mid-run is not seen]
The in-memory entries are a **cache** of the persistent store: a key is fetched
once and answered from memory after that.

A second program changing the same key while yours runs is not noticed.
`NSUserDefaults` makes the same trade; the alternative is a database round trip
on every read. `invalidate()` drops the cache if you need to re-read.
:::

## Topics

[standard](#standard) · [forDomain](#fordomain) · [stringFor](#stringfor--intfor--boolfor) · [intFor](#stringfor--intfor--boolfor) · [boolFor](#stringfor--intfor--boolfor) · [setString](#setstring--setint--setbool) · [setInt](#setstring--setint--setbool) · [setBool](#setstring--setint--setbool) · [registerString](#registerstring--registerint--registerbool) · [registerInt](#registerstring--registerint--registerbool) · [registerBool](#registerstring--registerint--registerbool) · [hasKey](#haskey) · [removeKey](#removekey) · [invalidate](#invalidate) · [domainName](#domainname)

### standard

```c
static UXKeyValueStore* standard(void)
```

The shared domain, visible to every program on the machine.

### forDomain

```c
static UXKeyValueStore* forDomain(u8* d)
```

An application's own domain, falling back to [`standard`](#standard).

### stringFor / intFor / boolFor

```c
u8*  stringFor(u8* key)
i32  intFor(u8* key)
bool boolFor(u8* key)
```

Read, resolving through set value → registered default → shared domain.

### setString / setInt / setBool

```c
void setString(u8* key, u8* v)
void setInt(u8* key, i32 v)
void setBool(u8* key, bool v)
```

Write, and persist.

### registerString / registerInt / registerBool

```c
void registerString(u8* key, u8* v)
void registerInt(u8* key, i32 v)
void registerBool(u8* key, bool v)
```

Declare a fallback. Registrations are not persisted. They live in code, so they
are declared again on each launch and can change in a new version without any
migration.

### hasKey

```c
bool hasKey(u8* key)
```

Whether the key was explicitly **set**. False for a registered-only value.

### removeKey

```c
void removeKey(u8* key)
```

Revert to the registered default.

### invalidate

```c
void invalidate(void)
```

Drop the cache, so the next read goes to the persistent store.

### domainName

```c
u8* domainName(void)
```

## Example

```
first launch: fontSize=12 showGrid=1 theme=light
hasKey(fontSize) = no  (registered is not SET)
after set: fontSize=18  hasKey=yes
after remove: fontSize=12 (back to the registered default)
shared editor=rocks  seen from the app domain=rocks
app overrides it: app=vi  shared still=rocks
```

The program is `website/site/examples/uxkit/settings.xc`. The `doc-examples`
gate compiles it, and the listing above is its output. It boots no driver, so
it also demonstrates the in-memory mode.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXKVEntry`](/compiler/api/uxkit/uxkventry/): one stored pair
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): `settingGet`/`settingSet`,
  the seam this persists through
