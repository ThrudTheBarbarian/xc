---
title: Assert
description: "Test-fixture assertion helpers that count checks and print FAIL/DONE lines; gated to no-ops by -DNDEBUG / -DRELEASE."
---

`Assert` is a small set of test-assertion helpers. xcc's own test fixtures use
it, and user code can too. Each assertion increments a test counter. A failure
also increments a failure counter and prints `FAIL T<n>`, which the fixture
runner scans for. [`summary`](#summary) prints the `DONE <count>` line at the end
of a run. Every method is **`static`**.

```c
#import <Assert.xc>
```

## Overview

`Assert` lives under `support/generic/lib/`, not an architecture directory, so it
works the same on every target. It imports [`Stdio`](/compiler/api/stdio/) for
its `FAIL` / `DONE` output. Every assertion funnels through
[`isTrue`](#istrue) so the counter bookkeeping and the `FAIL T<n>` print live in
one place.

:::note[Availability]
Compiling with `-DNDEBUG` or `-DRELEASE` turns **every method body into a
no-op**. The class and its signatures still exist, so call sites compile
unchanged and need no `#ifdef`. At `-O2` and above the leaf inliner removes the
empty calls, so asserts cost nothing at runtime in release builds. At `-O0` each
call site still emits a `JSR` to the empty stub. The accessors
[`testCount`](#testcount) and [`failCount`](#failcount) return **0** in release
builds, whatever assertions ran before.
:::

## Topics

**Core** · [isTrue](#istrue) · [isFalse](#isfalse)

**Equality** · [isEqual](#isequal) · [isNotEqual](#isnotequal)

**Pointers** · [isNull](#isnull) · [isNotNull](#isnotnull)

**Range & ordering** · [isInRange](#isinrange) · [isLess](#isless) · [isGreater](#isgreater)

**Summary & reset** · [summary](#summary) · [reset](#reset)

**Accessors** · [testCount](#testcount) · [failCount](#failcount)

**Lifecycle** · [init](#init)

---

## Core

Every other assertion routes through `isTrue`.

### isTrue
```c
static void isTrue(bool ok)
```
Records one test. If `ok` is false, increments the failure counter and prints
`FAIL T<n>` with the 1-based test index.

### isFalse
```c
static void isFalse(bool ok)
```
`isTrue(!ok)`: records a test that passes when `ok` is false.

```c
Assert.isTrue(1 + 1 == 2);
Assert.isFalse(needle == 0);
```

[↑ Topics](#topics)

## Equality

Overloaded across the common scalar widths.

### isEqual
```c
static void isEqual(u16 a, u16 b)
static void isEqual(u32 a, u32 b)
static void isEqual(i16 a, i16 b)
static void isEqual(i32 a, i32 b)
```
Asserts `a == b`.

### isNotEqual
```c
static void isNotEqual(u16 a, u16 b)
static void isNotEqual(u32 a, u32 b)
```
Asserts `a != b`.

```c
Assert.isEqual(counter, (u16)42);
Assert.isEqual(timestamp, (u32)1234567);
Assert.isNotEqual(scoreA, scoreB);
```

[↑ Topics](#topics)

## Pointers

### isNull
```c
static void isNull(pointer p)
```
Asserts `p` is the null pointer.

### isNotNull
```c
static void isNotNull(pointer p)
```
Asserts `p` is non-null.

```c
Foo* f = lookup(name);
Assert.isNotNull(f);
```

[↑ Topics](#topics)

## Range & ordering

### isInRange
```c
static void isInRange(u16 v, u16 lo, u16 hi)
```
Asserts `lo <= v && v <= hi`.

### isLess
```c
static void isLess(u16 a, u16 b)
```
Asserts `a < b`.

### isGreater
```c
static void isGreater(u16 a, u16 b)
```
Asserts `a > b`.

```c
Assert.isInRange(angle, (u16)0, (u16)360);
Assert.isLess(elapsed, (u16)budget);
```

[↑ Topics](#topics)

## Summary & reset

### summary
```c
static void summary(void)
```
Prints `DONE <count>` and, if any assertions failed, a `FAIL <m> tests` line.
Like every method here it is a no-op in release builds.

### reset
```c
static void reset(void)
```
Zeroes both the test and failure counters.

```c
void main(void) {
    Assert.isEqual(1 + 2, (u16)3);
    Assert.isInRange((u16)50, (u16)0, (u16)100);
    Assert.isNotNull("abc");
    Assert.summary();                // DONE 3
}
```

[↑ Topics](#topics)

## Accessors

### testCount
```c
static u16 testCount(void)
```
The number of assertions run so far (returns 0 in release builds).

### failCount
```c
static u16 failCount(void)
```
The number of failed assertions so far (returns 0 in release builds). Use it to
decide on post-test cleanup based on whether anything failed. In a release build,
either base that decision on the build flavour or do not read these accessors.

[↑ Topics](#topics)

## Lifecycle

### init
```c
void init(void)
```
Zeroes the counters. The class is used statically, so you rarely call it: the
counters start at zero, and [`reset`](#reset) clears them during a run.

[↑ Topics](#topics)
