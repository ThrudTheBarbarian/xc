---
title: Array
description: "Resizable, ordered list of Object*: a retaining container with indexed access, search, sort and functional map/filter/reduce methods."
---

`Array` is a heap-owned, resizable **ordered** list of `Object*`. Elements keep
their insertion order, indices are dense, and every stored element is held with
a strong (+1) reference.

```c
#import "Array.xc"           // or the Foundation umbrella
```

## Overview

An `Array` wraps a heap-allocated `pointer[]`, one cell per element, that
grows geometrically (8, then doubling) as you add. It inherits from
[`Object`](/compiler/api/object/) and needs a real heap (`-falloc=heap`, the
default on the `xt` 6502 layout and every native backend).

`Array<T>` is **generic** in name only. The type parameter is a compile-time
check that the compiler erases at runtime. The slots are type-erased `pointer`
cells, so any class works as an element. A parentless `class X` is an implicit
child of the built-in `Object` root, so an `X*` is always an `Object*`.

**Ownership (ARC).** The Array holds a strong reference on every element.
[`add`](#add) / [`insert`](#insert) retain; [`set`](#set) retains the incoming
element and releases the outgoing one; the `remove…` family releases the slot it
vacates; [`dealloc`](#dealloc) releases whatever is left and frees the backing
buffer. A [`copy`](#copy) is **shallow**: the elements are shared, each retained
by both arrays so each array owns its references independently.

**Complexity.** Indexed [`get`](#get)/[`set`](#set) are O(1); [`add`](#add) is
amortised O(1); [`insert`](#insert), [`removeAt`](#removeat) and the range
operations shift the tail and are O(n); [`indexOf`](#indexof) and the predicate
scans are O(n); [`sort`](#sort) is quicksort, O(n log n) average.

**Searching** returns an index and a miss is [`notFound()`](#notfound), never a
negative number. Range operations **clamp** to the valid range rather than
faulting, as [`subarray`](#subarray) does.

:::note[Availability]
This is the **32-bit** Array (`support/generic/lib`) for arm64, arm9, m68k and
x86_64. Indices and counts are `u32`, so the container is bounded by memory
rather than by a 65535 ceiling. The 6502 build (`support/xt6502/lib`) has the
**same API** with narrower types: `u16` indices and counts. A narrower caller
index widens at the call boundary, so `for (u16 i = 0; i < a.count(); i++)`
compiles and behaves the same on both. Heap-capable targets only.
:::

## Conforms to

- [`Enumerable`](/compiler/api/enumerable/): [`enumLength`](#enumlength) / [`enumAt`](#enumat), so an `Array` drives `for (Object* o in a)`.
- [`Copying`](/compiler/api/copying/): [`copy`](#copy) returns an independent (shallow) duplicate.

Every `Array*` is also an [`Object*`](/compiler/api/object/) and fits anywhere one is expected.

## Topics

**Creating** · [withCapacity](#withcapacity) · [with](#with) · [withArray](#witharray) · [init](#init)

**Accessing** · [count](#count) · [length](#length) · [isEmpty](#isempty) · [capacity](#capacity) · [get](#get) · [first](#first) · [last](#last)

**Adding** · [add](#add) · [insert](#insert) · [insertAll](#insertall) · [addAll](#addall) · [adding](#adding) · [set](#set) · [replaceAt](#replaceat)

**Removing** · [removeAt](#removeat) · [removeFirst](#removefirst) · [removeLast](#removelast) · [removeAll](#removeall) · [remove](#remove) · [removeEqual](#removeequal) · [removeRange](#removerange) · [replaceRange](#replacerange) · [setTo](#setto)

**Searching** · [indexOf](#indexof) · [contains](#contains) · [indexOfEqual](#indexofequal) · [containsEqual](#containsequal) · [notFound](#notfound)

**Functional (map / filter / reduce)** · [filtered](#filtered) · [mapped](#mapped) · [forEach](#foreach) · [firstWhere](#firstwhere) · [indexWhere](#indexwhere) · [countWhere](#countwhere) · [anySatisfy](#anysatisfy) · [allSatisfy](#allsatisfy)

**Sorting** · [sortUsing](#sortusing) · [sort](#sort) · [sortedUsing](#sortedusing) · [sorted](#sorted) · [isSortedUsing](#issortedusing)

**Structural** · [subarray](#subarray) · [swapAt](#swapat) · [reverse](#reverse) · [reversed](#reversed) · [isEqualToArray](#isequaltoarray)

**Iterating** · [enumLength](#enumlength) · [enumAt](#enumat)

**Lifecycle** · [copy](#copy) · [dealloc](#dealloc)

---

## Creating

### withCapacity
```c
static Array* withCapacity(u32 cap)
```
Pre-sizes the backing store to `cap` cells, skipping the geometric-resize copies
when the rough total is known up front. `cap == 0` behaves like `new Array()`.

### with
```c
static Array* with(Object* a)
static Array* with(Object* a, Object* b)
static Array* with(Object* a, Object* b, Object* c)
static Array* with(Object* a, Object* b, Object* c, Object* d)
```
Builds a small Array from a fixed list of one to four elements, the equivalent
of `arrayWithObjects:` for common counts (xtc has no nil-terminated vararg
convention). Each element is retained.

### withArray
```c
static Array* withArray(Array* other)
```
A new Array over the elements of `other` (a shallow copy, the same as calling
[`copy`](#copy) on `other`).

### init
```c
void init(void)
```
The default initializer: an empty Array with no allocation. Prefer
`new Array()` or [`withCapacity`](#withcapacity); you rarely call `init`
directly.

[↑ Topics](#topics)

## Accessing

### count
```c
u32 count(void)
```
Number of live elements. O(1).

### length
```c
u32 length(void)
```
Alias for [`count`](#count).

### isEmpty
```c
bool isEmpty(void)
```
`true` when [`count`](#count) is zero.

### capacity
```c
u32 capacity(void)
```
Cells currently allocated in the backing buffer (≥ [`count`](#count)). See
[`withCapacity`](#withcapacity).

### get
```c
Object* get(u32 i)
```
The element at index `i`. O(1). There is no bounds check, so keep `i < count()`.

### first
```c
Object* first(void)
```
The first element, or null when the Array is empty.

### last
```c
Object* last(void)
```
The last element, or null when the Array is empty.

[↑ Topics](#topics)

## Adding

### add
```c
void add(Object* obj)
```
Appends `obj` to the end, growing the buffer if needed. Retains `obj`. Amortised
O(1).

### insert
```c
void insert(u32 i, Object* obj)
```
Inserts `obj` at index `i`, shifting `[i..count-1]` up one. `i == count` is the
same as [`add`](#add); `i > count` is ignored. Retains `obj`. O(n).

### insertAll
```c
void insertAll(u32 at, Array* other)
```
Inserts every element of `other` starting at `at`, order preserved. `at` past
the end clamps to the end. Inserting an Array into itself is handled by
snapshotting first.

### addAll
```c
void addAll(Array* other)
```
Appends every element of `other` in order (each retained). A null argument is a
no-op.

### adding
```c
Array* adding(Object* obj)
```
Returns a **new** Array of the receiver's elements followed by `obj`; the
receiver is untouched (`arrayByAddingObject:`).

### set
```c
void set(u32 i, Object* obj)
```
Replaces the element at `i` with `obj`: retains the incoming element **before**
releasing the outgoing one (so `a.set(i, a.get(i))` is safe). Out of range is a
no-op.

### replaceAt
```c
void replaceAt(u32 i, Object* obj)
```
`replaceObjectAtIndex:`: the same operation as [`set`](#set), under the
Foundation name.

[↑ Topics](#topics)

## Removing

Each removal releases the strong reference on the slot it vacates.

### removeAt
```c
void removeAt(u32 i)
```
Removes the element at `i`, shifting the tail down one. Out of range is a no-op.
O(n).

### removeFirst
```c
void removeFirst(void)
```
Removes the first element (`removeAt(0)`).

### removeLast
```c
void removeLast(void)
```
Removes the last element. No-op on an empty Array. O(1).

### removeAll
```c
void removeAll(void)
```
Releases and drops every element, leaving the Array empty (the buffer is kept).

### remove
```c
bool remove(Object* obj)
```
Removes the first element with this **identity** (`removeObjectIdenticalTo:`).
Returns whether one was found.

### removeEqual
```c
bool removeEqual(Comparable* obj)
```
Removes the first element **equal** to `obj` by value (`removeObject:`, via the
element's [`Comparable`](/compiler/api/comparable/) `equals`). Returns whether
one was found.

### removeRange
```c
void removeRange(u32 at, u32 len)
```
Removes `len` elements starting at `at` in one pass of releases and a single
tail shift. The range **clamps** to what is available.

### replaceRange
```c
void replaceRange(u32 at, u32 len, Array* other)
```
Replaces `len` elements at `at` with all of `other`; the two lengths need not
match. Safe when `other` is the receiver (snapshotted first).

### setTo
```c
void setTo(Array* other)
```
Becomes `other` (`setArray:`): releases the current contents, then adds all of
`other`.

[↑ Topics](#topics)

## Searching

Searches return a `u32` index; a miss is [`notFound()`](#notfound).

### indexOf
```c
u32 indexOf(Object* obj)
```
First index whose element is **identical** to `obj` (pointer identity: two
distinct `Number(42)` instances are different elements here). O(n).

### contains
```c
bool contains(Object* obj)
```
`true` if any element is identical to `obj` (`indexOf(obj) != notFound()`).

### indexOfEqual
```c
u32 indexOfEqual(Comparable* obj)
```
First index whose element is **equal** to `obj` by value, dispatching `equals`
through the [`Comparable`](/compiler/api/comparable/) slot. A null argument
returns [`notFound()`](#notfound).

### containsEqual
```c
bool containsEqual(Comparable* obj)
```
`true` if any element is equal to `obj` by value.

### notFound
```c
static u32 notFound(void)          // 0xFFFFFFFF
```
The sentinel returned by the search methods on a miss. It lies outside the valid
index range. `$FFFF` cannot serve as the sentinel because the container can hold
more than 65535 elements.

[↑ Topics](#topics)

## Functional (map / filter / reduce)

Each takes a `callback` argument, which can be a plain function (widened) **or**
a bound method that carries its receiver. A bound method lets a predicate use
state (`&filter.matches`) without a global. A null callback gives an empty
result or does nothing.

### filtered
```c
Array* filtered(callback keep bool(Object* o))
```
A new Array of the elements the predicate keeps, in order. The receiver is
untouched; survivors are retained by the result.

### mapped
```c
Array* mapped(callback f Object*(Object* o))
```
A new Array of each element passed through `f`. A **null result is skipped**
rather than stored, so `mapped` doubles as a filtering transform.

### forEach
```c
void forEach(callback fn void(Object* o))
```
Calls `fn` once per element, in order.

### firstWhere
```c
Object* firstWhere(callback p bool(Object* o))
```
The first element satisfying `p`, or null. Stops at the first hit.

### indexWhere
```c
u32 indexWhere(callback p bool(Object* o))
```
The index of the first element satisfying `p`, or [`notFound()`](#notfound).

### countWhere
```c
u32 countWhere(callback p bool(Object* o))
```
How many elements satisfy `p`.

### anySatisfy
```c
bool anySatisfy(callback p bool(Object* o))
```
`true` if at least one element satisfies `p` (`indexWhere(p) != notFound()`).

### allSatisfy
```c
bool allSatisfy(callback p bool(Object* o))
```
`true` if every element satisfies `p` (vacuously true for an empty Array). A
null predicate returns `false`.

[↑ Topics](#topics)

## Sorting

The comparator type is `cmp2_t`, `i8 (Object*, Object*)`, following the C /
`NSComparisonResult` convention (`< 0` if the first sorts before the second).
The in-place sorts move only the slot pointers, so no element is retained or
released.

### sortUsing
```c
void sortUsing(callback cmp i8(Object* a, Object* b))
```
Sorts in place with quicksort under comparator `cmp` (a plain function or a
bound method; `&self.byColumn` captures a receiver). A null comparator or fewer
than two elements is a no-op.

### sort
```c
bool sort(void)
```
Sorts in place by the elements' **own** order, the optional
[`Comparable`](/compiler/api/comparable/) `compare` slot. Returns `false` and
leaves the Array untouched when the elements do not implement `compare`. In that
case use [`sortUsing`](#sortusing) with an explicit comparator.

### sortedUsing
```c
Array* sortedUsing(callback cmp i8(Object* a, Object* b))
```
A sorted **copy** under `cmp`; the receiver is left alone. The copy holds its
own strong reference to every element.

### sorted
```c
Array* sorted(void)
```
A sorted copy by the elements' natural [`Comparable`](/compiler/api/comparable/)
order; the receiver is left alone.

### isSortedUsing
```c
bool isSortedUsing(callback cmp i8(Object* a, Object* b))
```
`true` if the Array is already in non-descending order under `cmp`. It is cheap,
and useful in tests and as a guard before a merge.

[↑ Topics](#topics)

## Structural

### subarray
```c
Array* subarray(u32 from, u32 len)
```
A new Array holding the slice of `len` elements starting at `from`. Out of range
**clamps to empty**, as String's slicing does.

### swapAt
```c
void swapAt(u32 i, u32 j)
```
Swaps the elements at `i` and `j` in place. Out-of-range or equal indices are a
no-op.

### reverse
```c
void reverse(void)
```
Reverses the Array in place (only the slot cells move, so no refcount changes).

### reversed
```c
Array* reversed(void)
```
A new Array with the elements in reverse order; the receiver is untouched.

### isEqualToArray
```c
bool isEqualToArray(Array* other)
```
`true` when `other` has the same count and elements equal **pairwise by value**
(identity first, then the element's own [`Comparable`](/compiler/api/comparable/)
equality). This is Foundation's `isEqualToArray:`. Array's inherited
[`Object`](/compiler/api/object/) `equals` still means pointer identity, which
keeps an Array usable as a Map key or Set member.

[↑ Topics](#topics)

## Iterating

The [`Enumerable`](/compiler/api/enumerable/) hooks; you normally use
`for (Object* o in a)` rather than calling these directly.

### enumLength
```c
u32 enumLength(void)
```
Number of elements the `for-in` driver will visit (== [`count`](#count)).

### enumAt
```c
Object* enumAt(u32 i)
```
The `i`-th element for the `for-in` driver (== [`get`](#get)).

[↑ Topics](#topics)

## Lifecycle

### copy
```c
Array* copy(void)
```
A new Array over the same elements. The copy is **shallow**: the elements are
shared, each retained by the new Array so both arrays own their references
independently. This is the [`Copying`](/compiler/api/copying/) method.

### dealloc
```c
void dealloc(void)
```
Releases every element still held, then frees the backing buffer. ARC calls it
when the last reference goes away; you do not call it directly.

[↑ Topics](#topics)

## Worked example

```c
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    Array* a = new Array();
    a.add(Number.with((i32)3));
    a.add(Number.with((i32)1));
    a.add(Number.with((i32)2));

    a.sort();                       // elements' own Comparable order

    for (Object* o in a) {          // Enumerable: for-in
        Number* n = (Number* ?)o;   // safe-checked downcast
        if (n != 0) Stdio.printf("%d ", n.asI16());
    }
    Stdio.printf("\n");
    return 0;
}
```

```
1 2 3
```
