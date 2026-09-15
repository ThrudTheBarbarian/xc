---
title: UXTimeZone
description: "A named fixed offset from UTC, and why it is a fixed offset rather than a tz-database implementation."
---

`UXTimeZone` is a name and an **offset from UTC in minutes**. A
[`UXDate`](/compiler/api/uxkit/uxdate/)'s components are expressed in a zone.

```c
#use <UXKit>            // or #import "UXDate.xc"
```

## Overview

```c
UXTimeZone* utc = UXTimeZone.utc();
UXTimeZone* ist = UXTimeZone.make((u8*)"IST", 330);     // +05:30
UXTimeZone* pst = UXTimeZone.make((u8*)"PST", -480);    // -08:00

utc.offsetString();    // "Z"
ist.offsetString();    // "+05:30"
pst.offsetString();    // "-08:00"
```

Positive is east of Greenwich. The offset is in **minutes**, not hours, because
several real zones are not on the hour: India is +05:30 and Nepal is +05:45.

## Why fixed-offset

A real time zone is a **function of the instant**: a daylight-saving rule that
governments amend and that is historically irregular. Answering that correctly
needs the tz database, which is megabytes in size, revised several times a year,
and full of pre-1970 irregularities.

This class implements the part that can be exact, and leaves out the rest:

- the offset is **what you set**, and does not change with the date
- summer-time variants are **separate entries**: `BST` alongside `GMT`, `EDT`
  alongside `EST`
- [`systemZone`](#systemzone) asks the **host** what offset is in force now.
  In this case the host has already applied the real rules from its own
  database.

Anything more needs a real tz implementation, not a bigger table. A partial DST
model is worse than none: it is wrong twice a year and right the rest of the
time, so its errors go unnoticed.

:::caution[A stored offset does not follow the clocks]
`UXTimeZone.make((u8*)"BST", 60)` is correct in July and wrong in January.

For a date you are *displaying now*, use [`systemZone`](#systemzone) or
[`UXDate.currentDateLocal`](/compiler/api/uxkit/uxdate/#currentdatelocal). For a
date you are *storing*, store UTC so the offset question does not arise. For
this reason [`UXDate`](/compiler/api/uxkit/uxdate/#zones-components-versus-instant)
defaults to UTC rather than local.
:::

## Unknown is null, not UTC

```c
UXTimeZone.named((u8*)"UTC");     // a zone
UXTimeZone.named((u8*)"Mars");    // 0
```

[`named`](#named) returns null for a name that is not in the table, so a caller
can distinguish an unknown zone from UTC. A silent fallback to UTC would turn a
typo into an eight-hour error.

There are **24** built-in zones. Browse them with
[`knownCount`](#knowncount) and [`knownAt`](#knownat), for example to populate a
picker, and use [`make`](#make) for any other zone.

## Topics

[make](#make) · [utc](#utc) · [named](#named) · [systemZone](#systemzone) · [knownCount](#knowncount) · [knownAt](#knownat) · [offsetString](#offsetstring)

### make

```c
static UXTimeZone* make(u8* nm, i32 mins)
```

Any name and offset. The name is **kept, not copied**, so pass a literal or a
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

### utc

```c
static UXTimeZone* utc(void)
```

Offset `0`, name `"UTC"`. The default for a date that was never given a zone.

### named

```c
static UXTimeZone* named(u8* nm)
```

Looks up a built-in zone by name, or returns **null**. Names are compared by
content.

### systemZone

```c
static UXTimeZone* systemZone(void)
```

The offset the host is on **now**, named `"local"`, read through the driver
seam. DST is already accounted for, because the host applied it.

Returns UTC when there is no driver, so settings code that runs before a window
exists still works and gets a safe answer.

The result is a snapshot of the offset when you called. A long-running program
that crosses a DST boundary should call it again instead of caching it.

### knownCount

```c
static i32 knownCount(void)
```

How many built-in zones there are (currently 24).

### knownAt

```c
static UXTimeZone* knownAt(i32 i)
```

The i-th built-in zone, or null when out of range. Use it with
[`knownCount`](#knowncount) to fill a zone picker.

### offsetString

```c
u8* offsetString(void)
```

`"+05:30"`, `"-08:00"`, or `"Z"` for zero, in ISO 8601 form, as a log line or a
serialised timestamp needs. Zero is `Z` rather than `+00:00` because it is the
shorter standard spelling and reads as *no offset* rather than a small one.

## Fields

### name

```c
u8* name
```

### offsetMinutes

```c
i32 offsetMinutes      // add to UTC to get local; negative west of Greenwich
```

## Example

```
offsets: Z +05:30 -08:00
utc:       2026-09-14 16:45
in PST:    2026-09-14 08:45
same instant: 1
named(UTC)=1 named(Mars)=0 known zones=24
```

The program is `website/site/examples/uxkit/dates.xc`. The `doc-examples` gate
compiles it, and the output above is what it prints.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXDate`](/compiler/api/uxkit/uxdate/): components, instants and `inZone`
- [`UXDateFormatter`](/compiler/api/uxkit/uxdateformatter/): does **not**
  convert zones for you
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): `localOffsetMinutes`,
  the seam `systemZone` reads
