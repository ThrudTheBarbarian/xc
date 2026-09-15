---
title: UXOutlineDataSource
description: "Four methods make a tree. It addresses by item rather than row, because a row's meaning changes when something above it expands."
---

`UXOutlineDataSource` is what a
[`UXOutlineView`](/compiler/api/uxkit/uxoutlineview/) asks for its contents.
It has four methods. Unlike a table's data source, it addresses by
**item**, not by row.

```c
#use <UXKit>            // or #import "UXOutlineView.xc"
```

## Overview

```c
protocol UXOutlineDataSource {
    i32     numberOfChildren(UXOutlineView* o, Object* item);
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i);
    bool    isExpandable(UXOutlineView* o, Object* item);
    u8*     valueForItem(UXOutlineView* o, Object* item, i32 col);
}
```

### Why item and not row

A tree cannot address anything by row index, because a row's meaning changes
when something above it expands: row 4 is a different node before and after
opening row 2. The outline hands you back the item itself.

**An item is any `Object*` you like.** The outline never inspects it; it only
gives it back. Your existing model nodes work unchanged. There is no wrapper
type to build and keep in sync, and no identifier to map.

### `item == 0` is the root

This convention keeps every method to two lines:

```c
i32 numberOfChildren(UXOutlineView* o, Object* item) {
    Node* n = item == (Object*)0 ? root : (Node* ?)item;
    return (i32)n.kids.count();
}
```

The outline asks about the root first, then walks down through whatever you
return. There is no separate call for the root, because `0` means the root.

## Topics

[numberOfChildren](#numberofchildren) · [childOfItem](#childofitem) · [isExpandable](#isexpandable) · [valueForItem](#valueforitem)

### numberOfChildren

```c
i32 numberOfChildren(UXOutlineView* o, Object* item)
```

How many children `item` has, or the root's children when `item` is `0`.

### childOfItem

```c
Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
```

The i'th child, in display order. Sort a level here; the outline does not
sort.

### isExpandable

```c
bool isExpandable(UXOutlineView* o, Object* item)
```

Whether this item can be opened.

**This is separate from [`numberOfChildren`](#numberofchildren).** A
node can be expandable *before* its children are known, so a lazily loaded
tree can show a disclosure triangle without fetching anything first.
A directory that has not been read yet answers `true` here and does its work in
`numberOfChildren` when the user opens it.

For an eagerly loaded model the implementation is
`n.kids.count() > 0`.

### valueForItem

```c
u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
```

The text for one item in one column. Like a table's cell, this returns
**text**, so formatting belongs here.

`item` is never `0` for a real row, so a null check is only needed if your
model can contain one.

## See also

- [Tables, outlines and data sources](/compiler/api/uxkit/guide-tables/): a
  working outline alongside a table
- [`UXOutlineView`](/compiler/api/uxkit/uxoutlineview/): expansion state and
  indentation
- [`UXOutlineNode`](/compiler/api/uxkit/uxoutlinenode/): the outline's own
  per-row bookkeeping
- [`UXTableDataSource`](/compiler/api/uxkit/uxtabledatasource/): the flat
  equivalent
