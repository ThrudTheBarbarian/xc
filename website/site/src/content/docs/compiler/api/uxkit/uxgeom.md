---
title: UXGeom
description: "Rectangles, points and sizes as value types, and the integer operations over them: containment, intersection, union, length. No floats."
---

`UXGeom` is the toolkit's geometry: three value types and the static
operations over them. Every UXKit program uses it, because you place a view
by handing its parent a `UXRect`.

```c
#use <UXKit>            // or #import "UXGeometry.xc"
```

## Overview

```c
struct UXPoint { i16 x; i16 y; }
struct UXSize  { i16 w; i16 h; }
struct UXRect  { i16 x; i16 y; i16 w; i16 h; }
```

These are **structs**: copied on assignment, never retained, never `null`.
A rect you hand to `addSubview` is a copy, so holding on to the rect you
built a view with cannot move the view later. There is no ownership to
track and nothing to free.

**The coordinate system is GEM's.** The origin is top-left, **y grows
downward**, and units are `i16` pixels. The AES stores the same values in
`OBJECT.ob_x/y/w/h`, and any other convention would need a conversion at
every call. If you are used to a toolkit where y grows up, this is the one
thing to re-learn.

The geometry is **integer throughout**, with no floats, so every backend
flattens and caps a curve to identical pixels. A rounded corner on GEM and
on macOS is the same shape.

Number literals bind to the parameter's type, so
`UXGeom.make(10, 10, 100, 60)` needs no casts. Some toolkit sources write
`(i16)10`; the cast is not needed.

## Topics

[make](#make) · [zero](#zero) · [isEmpty](#isempty) · [contains](#contains) · [unite](#unite) · [intersects](#intersects) · [intersection](#intersection) · [union2](#union2) · [isqrt](#isqrt) · [length](#length)

### make

```c
static UXRect make(i16 x, i16 y, i16 w, i16 h)
```

A rectangle from its origin and extent, in the **parent's** coordinates.
This is the most frequently used call in the toolkit.

```c
content.addSubview(button, UXGeom.make(16, 48, 96, 24));
```

### zero

```c
static UXRect zero(void)
```

`0,0 0x0`. Its main use is as the starting value for an accumulating
[`unite`](#unite), because empty is that operation's identity.

### isEmpty

```c
static bool isEmpty(UXRect r)
```

True when either extent is zero **or negative**. Negative counts as empty
so that a rect built from a backwards drag, or an
[`intersection`](#intersection) with no overlap, tests as empty.

### contains

```c
static bool contains(UXRect r, i16 px, i16 py)
```

Hit testing. The test is **half-open**: the left and top edges are inside,
the right and bottom edges are not.

```c
UXRect r = UXGeom.make(10, 10, 100, 60);
UXGeom.contains(r, 10, 10)     // true  — the top-left corner
UXGeom.contains(r, 109, 69)    // true  — the last pixel inside
UXGeom.contains(r, 110, 70)    // false — the right/bottom edges are NOT
```

This rule lets adjacent rects tile without overlapping. Every hit-test in
the toolkit follows it, so a click on the boundary between two views lands
in one of them only.

### unite

```c
static UXRect unite(UXRect a, UXRect b)
```

The smallest rect containing both, **ignoring an empty operand**. That
exception makes empty the identity, so a damage region can start at
[`zero`](#zero) and union into it with no special case for the first rect.

```c
UXRect damage = UXGeom.zero();
damage = UXGeom.unite(damage, panel);    // 10,10 100x60
damage = UXGeom.unite(damage, button);   // 10,10 130x70
```

Without the exception, a zero rect at the origin would pull every union
back to `0,0`, and every repaint would cover the whole window.
[`UXViewTree`](/compiler/api/uxkit/uxviewtree/) accumulates its dirty region
this way.

### intersects

```c
static bool intersects(UXRect a, UXRect b)
```

Whether two rects overlap, without building the overlap. Use this cheaper
test when you only need the answer.

### intersection

```c
static UXRect intersection(UXRect a, UXRect b)
```

The overlapping region, or [`zero`](#zero) when there is none. You can test
the result with [`isEmpty`](#isempty) instead of calling
[`intersects`](#intersects) first.

```c
UXRect panel  = UXGeom.make(10, 10, 100, 60);
UXRect button = UXGeom.make(80, 40, 60, 40);
UXGeom.intersection(panel, button)    // 80,40 30x30
```

### union2

```c
static UXRect union2(UXRect a, UXRect b)
```

:::note[Identical to `unite`]
`union2` has the same body as [`unite`](#unite) and behaves identically.
Prefer `unite`, which the toolkit itself calls; `union2` remains because
existing code refers to it.
:::

### isqrt

```c
static i32 isqrt(i32 v)
```

Integer square root, **floored**, by Newton's method from a power-of-two
seed. `isqrt(50)` is 7.

It lets the toolkit avoid floats. Squared distances answer most questions,
but placing a line cap or an arrowhead a given distance along a stroke needs
a real length.

### length

```c
static i32 length(i32 dx, i32 dy)
```

The hypotenuse of `(dx, dy)`, floored: `length(3, 4)` is 5. It is built on
[`isqrt`](#isqrt), and is the one place the toolkit needs a real distance.

## Example

Geometry is value types and static functions, so this runs headless, with
no window or driver.

```c
#import <Stdio.xc>
#import "UXGeometry.xc"

void show(u8* what, UXRect r) {
    Stdio.printf("%s: %d,%d %dx%d\n", what, r.x, r.y, r.w, r.h);
}

void main(void) {
    UXRect panel  = UXGeom.make(10, 10, 100, 60);
    UXRect button = UXGeom.make(80, 40, 60, 40);

    show((u8*)"panel  ", panel);                               // 10,10 100x60
    show((u8*)"button ", button);                              // 80,40 60x40
    show((u8*)"overlap", UXGeom.intersection(panel, button));  // 80,40 30x30
    show((u8*)"both   ", UXGeom.unite(panel, button));         // 10,10 130x70

    // Empty is the identity, so damage needs no "first rect" case.
    UXRect damage = UXGeom.zero();
    damage = UXGeom.unite(damage, panel);
    damage = UXGeom.unite(damage, button);
    show((u8*)"damage ", damage);                              // 10,10 130x70

    // Half-open containment.
    Stdio.printf("contains(109,69) %s\n", UXGeom.contains(panel, 109, 69) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("contains(110,70) %s\n", UXGeom.contains(panel, 110, 70) ? (u8*)"yes" : (u8*)"no");

    Stdio.printf("length(3,4) %d  isqrt(50) %d\n", UXGeom.length(3, 4), UXGeom.isqrt(50));
}
```

The comments show what it prints. The program is
`website/site/examples/uxkit/geometry.xc`, and the `doc-examples` gate
compiles it.


## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXView`](/compiler/api/uxkit/uxview/): `frame`, `bounds` and
  `absoluteFrame` are all `UXRect`
- [The view tree and layout](/compiler/api/uxkit/guide-view-tree/): which
  coordinate space a rect is in, and when the difference matters
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/): the damage region
  [`unite`](#unite) is designed for
