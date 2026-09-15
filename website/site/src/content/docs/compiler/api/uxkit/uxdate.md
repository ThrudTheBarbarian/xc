---
title: UXDate
description: "A civil date and time as broken-down components, with exact integer calendar arithmetic: correct leap years, weekdays and day differences, with no floating point."
---

`UXDate` holds a date and time as **components** (year, month, day, hour,
minute, second, microsecond) plus the [time
zone](/compiler/api/uxkit/uxtimezone/) those components are expressed in.

```c
#use <UXKit>            // or #import "UXDate.xc"
```

## Overview

```c
UXDate* d = UXDate.makeTime(2026, 9, 14, 16, 45, 7);

d.weekday();                       // 1 = Monday
d.addingDays(1);                   // a new date, Tue 15 Sep
d.addingMonths(5);                 // 2027-02-14
UXDate.make(2026, 1, 1).daysUntil(d);   // 256

UXDateFormatter.withPattern((u8*)"EEEE d MMMM yyyy").format(d);
// Monday 14 September 2026
```

Every derivation returns a **new date**; nothing mutates.

## Integer arithmetic, and why it matters

Conversions go through a **day number** (days since 1970-01-01), computed with
the exact integer civil-calendar algorithm.

No floating point is used, so the results are identical on every backend. A
date library built on seconds stored as a double gives slightly different
answers on a machine with a different FPU, and cannot run on a target with no
FPU. Here, `29 February 2024` is reached by counting.

```c
UXDate.isLeapYear(2024);   // true   — divisible by 4
UXDate.isLeapYear(1900);   // false  — divisible by 100
UXDate.isLeapYear(2000);   // true   — divisible by 400
```

All three rules apply: `28 Feb 2024 + 1 day` is the 29th, and `28 Feb 2025 + 1
day` is 1 March.

## Month arithmetic clamps

```c
UXDate.make(2026, 1, 31).addingMonths(1);    // 2026-02-28, not 2026-03-03
```

Adding a month to the 31st lands on the last day of the shorter month instead
of spilling into the next one. A calendar UI means this by "next month", and
`NSCalendar` makes the same choice.

As a result, month arithmetic is **not reversible**: `+1 month` then
`-1 month` from 31 January gives 28 February then 28 January. Day arithmetic
is reversible, because a day is always a day.

## Zones: components versus instant

A `UXDate`'s components are a **wall-clock reading**, and `zone` says which
clock. [`inZone`](#inzone) re-expresses the same instant on a different clock:

```c
UXDate* here  = UXDate.makeTime(2026, 9, 14, 16, 45, 0);   // UTC
UXDate* there = here.inZone(UXTimeZone.make((u8*)"PST", -480));

// here  = 2026-09-14 16:45
// there = 2026-09-14 08:45
here.isSameInstant(there);      // true
```

The components differ but the moment is the same. When two dates come from
different zones, compare them with [`isSameInstant`](#issameinstant). Comparing
components would wrongly report them as different.

A date made without a zone is **UTC**, not local. A default of local time would
make the same code produce different data on different machines, which makes
timestamps in a shared file useless.
[`currentDateLocal`](#currentdatelocal) gives the host's clock when you want it.

## Reading the clock

```c
UXDate.currentDate();        // now, in UTC
UXDate.currentDateLocal();   // now, in the host's zone
```

Both go through the driver seam, so a backend with no clock still returns a
date instead of failing. For anything you will compare or store, prefer UTC and
convert for display.

:::note[Fixed dates make testable code]
Everything except `currentDate` is pure. Code that takes a `UXDate*` instead of
calling `currentDate` itself can be tested with a date you chose. This is why
the [example](#example) prints the same output on every run.
:::

## Topics

[make](#make) · [makeTime](#maketime) · [makeMicro](#makemicro) · [currentDate](#currentdate) · [currentDateLocal](#currentdatelocal) · [fromEpochSeconds](#fromepochseconds) · [epochSeconds](#epochseconds) · [setZone](#setzone) · [inZone](#inzone) · [isSameInstant](#issameinstant) · [dayNumber](#daynumber) · [fromDayNumber](#fromdaynumber) · [weekday](#weekday) · [addingDays](#addingdays) · [addingWeeks](#addingweeks) · [addingMonths](#addingmonths) · [addingYears](#addingyears) · [addingHours](#addinghours) · [addingMinutes](#addingminutes) · [addingSeconds](#addingseconds) · [addingMicroseconds](#addingmicroseconds) · [daysUntil](#daysuntil) · [daysInMonth](#daysinmonth) · [isLeapYear](#isleapyear)

### make

```c
static UXDate* make(i32 y, i32 mo, i32 d)
```

A date at midnight. Month is **1–12** and day **1–31**. Unlike C's
`struct tm`, neither is zero-based.

### makeTime

```c
static UXDate* makeTime(i32 y, i32 mo, i32 d, i32 h, i32 mi, i32 s)
```

### makeMicro

```c
static UXDate* makeMicro(i32 y, i32 mo, i32 d, i32 h, i32 mi, i32 s, i32 us)
```

Microseconds within the second, `0`–`999999`. They let an event trace order
things that happened in the same second.

### currentDate

```c
static UXDate* currentDate(void)
```

Now, in UTC, read through the driver.

### currentDateLocal

```c
static UXDate* currentDateLocal(void)
```

Now, in the host's zone, with the host's DST rules already applied. See
[`UXTimeZone`](/compiler/api/uxkit/uxtimezone/).

### fromEpochSeconds

```c
static UXDate* fromEpochSeconds(i32 secs, i32 us)
```

From a Unix timestamp.

:::caution[`i32` seconds run out in 2038]
A signed 32-bit second count overflows on 19 January 2038. The component fields
have no such limit (`year` is an `i32`), so dates far outside that range work
as long as you do not route them through epoch seconds.
:::

### epochSeconds

```c
i32 epochSeconds(void)
```

The instant as a Unix timestamp, zone taken into account.

### setZone

```c
void setZone(UXTimeZone* z)
```

Sets which clock the existing components are on. This **reinterprets** the
components and does not convert them. Use [`inZone`](#inzone) to convert.

### inZone

```c
UXDate* inZone(UXTimeZone* tz)
```

The same instant, expressed on another clock. See
[above](#zones-components-versus-instant).

### zoneOffsetMinutes

```c
i32 zoneOffsetMinutes(void)
```

This date's offset from UTC, in minutes. It is `0` when the date has no zone,
the same answer UTC gives, so no null check is needed.

[`epochSeconds`](#epochseconds) subtracts this value to get back to an absolute
instant. Print it alongside a timestamp when the zone matters.
[`UXTimeZone.offsetString`](/compiler/api/uxkit/uxtimezone/#offsetstring) is the
formatted form.

### isSameInstant

```c
bool isSameInstant(UXDate* other)
```

Whether two dates are the same moment, whatever zones they are in.

### dayNumber

```c
i32 dayNumber(void)
```

Days since 1970-01-01. The calendar maths runs on this integer, and it is a
cheap key for grouping by day.

### fromDayNumber

```c
static UXDate* fromDayNumber(i32 z)
```

The inverse of `dayNumber`.

### weekday

```c
i32 weekday(void)
```

`0` = Sunday through `6` = Saturday. The formatter's `E` uses this index.

### addingDays

```c
UXDate* addingDays(i32 n)
```

Exact across month and year boundaries, and reversible. Negative values go back.

### addingWeeks

```c
UXDate* addingWeeks(i32 n)
```

### addingMonths

```c
UXDate* addingMonths(i32 n)
```

Clamps the day to the target month's length. See
[above](#month-arithmetic-clamps).

### addingYears

```c
UXDate* addingYears(i32 n)
```

29 February clamps to the 28th in a non-leap year, for the same reason.

### addingHours

```c
UXDate* addingHours(i32 n)
```

### addingMinutes

```c
UXDate* addingMinutes(i32 n)
```

### addingSeconds

```c
UXDate* addingSeconds(i32 n)
```

Carries into the day, and from there into the month and year.

### addingMicroseconds

```c
UXDate* addingMicroseconds(i32 n)
```

### daysUntil

```c
i32 daysUntil(UXDate* other)
```

Whole days between the two dates, by day number. The result is exact regardless
of the times of day, and negative when `other` is earlier.

### daysInMonth

```c
static i32 daysInMonth(i32 y, i32 mo)
```

Leap years included. A month grid needs this.

### isLeapYear

```c
static bool isLeapYear(i32 y)
```

## Example

```
iso:       2026-09-14
time:      16:45:07
long:      Monday 14 September 2026
weekday index: 1
+1 day:    Tue 2026-09-15
+5 months: 2027-02-14
31 Jan +1m: 2026-02-28
leap: 2024=1 2025=0 1900=0 2000=1
29 Feb 24: Thursday 29 February 2024
28 Feb 25: Saturday 1 March 2025
days 2026-01-01 -> 2026-09-14: 256
utc:       2026-09-14 16:45
in PST:    2026-09-14 08:45
same instant: 1
```

The program is `website/site/examples/uxkit/dates.xc`; the `doc-examples` gate
compiles it, and the output above is what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXDateFormatter`](/compiler/api/uxkit/uxdateformatter/): dates to strings
- [`UXTimeZone`](/compiler/api/uxkit/uxtimezone/): zones, and why they are
  fixed-offset
- [`UXDatePicker`](/compiler/api/uxkit/uxdatepicker/): choosing a date in a
  window
