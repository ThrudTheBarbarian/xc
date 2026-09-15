---
title: UXTableDataSource
description: "Two methods make a table: how many rows, and what goes in this cell. The view never holds your data."
---

`UXTableDataSource` is what a [`UXTableView`](/compiler/api/uxkit/uxtableview/)
asks for its contents. The contract is two methods.

```c
#use <UXKit>            // or #import "UXTableView.xc"
```

## Overview

```c
protocol UXTableDataSource {
    i32 numberOfRows(UXTableView* t);
    u8* valueForCell(UXTableView* t, i32 row, i32 col);
}
```

The table **never holds your data**. It asks every time it draws. Your model
stays in whatever shape suits it, and the table is a view *of* it, not a second
copy that can drift out of step.

```c
class Library : Object <UXTableDataSource>
{
    Array<Track>* tracks;

    i32 numberOfRows(UXTableView* t) { return (i32)tracks.count(); }

    u8* valueForCell(UXTableView* t, i32 row, i32 col) {
        Track* tr = (Track* ?)tracks.get((u16)row);
        if (col == 0) { return tr.name; }
        if (col == 1) { return tr.artist; }
        return self.formatMinutes(tr.mins);
    }
}
```

## Topics

[numberOfRows](#numberofrows) · [valueForCell](#valueforcell)

### numberOfRows

```c
i32 numberOfRows(UXTableView* t)
```

How many rows there are **now**. The table calls this whenever it needs the
count, so return `tracks.count()` directly. There is nothing to cache or
invalidate.

The table is passed in, so one object can be the data source for several tables
and tell them apart by identity.

### valueForCell

```c
u8* valueForCell(UXTableView* t, i32 row, i32 col)
```

The text for one cell.

**A cell returns text.** If your model holds a number, a date or an enum, it
becomes a string here. Formatting (locale, padding, units) stays in your code,
so a column of minutes looks the way you chose.

**Mind the buffer you return.** Returning a pointer into a scratch buffer is
fine, but the table may ask for several cells before drawing any of them. If a
formatted value has to survive that, store it. Formatting and returning
immediately is safe.

`col` indexes the columns you added with `addColumn`, which carry only a title
and a width. A column does not know what it holds, so reordering columns is a
layout change and nothing in your model moves.

## Changing the data

```c
tracks.add(Track.make((u8*)"Ochre", (u8*)"Mirrer", 5));
table.reloadData();
```

Change the model, then tell the view. `reloadData` makes the table ask again;
there is no snapshot to keep in step.

## See also

- [Tables, outlines and data sources](/compiler/api/uxkit/guide-tables/): the
  whole pattern, with a working program
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): columns, selection, and
  what a native list backend does differently
- [`UXTableDelegate`](/compiler/api/uxkit/uxtabledelegate/): the optional other
  half, for selection
- [`UXOutlineDataSource`](/compiler/api/uxkit/uxoutlinedatasource/): the same
  idea for a tree
