---
title: UXTableDelegate
description: "One optional method: the table's selection settled. A table with no delegate is fully functional."
---

`UXTableDelegate` is how a [`UXTableView`](/compiler/api/uxkit/uxtableview/)
tells you the selection changed. It has one optional method.

```c
#use <UXKit>            // or #import "UXTableView.xc"
```

## Overview

```c
protocol UXTableDelegate {
    optional void tableSelectionDidChange(UXTableView* t, i32 row);
}
```

Because the method is `optional`, **a table with no delegate is fully
functional**. It draws, scrolls and selects. Add a delegate when you need to
know what was selected.

```c
void tableSelectionDidChange(UXTableView* t, i32 row) {
    if (row < 0) { status.setText((u8*)"nothing selected"); return; }
    status.setText(((Track* ?)tracks.get((u16)row)).name);
}
```

## Topics

[tableSelectionDidChange](#tableselectiondidchange)

### tableSelectionDidChange

```c
optional void tableSelectionDidChange(UXTableView* t, i32 row)
```

The selection came to rest at `row`.

**`row < 0` means nothing is selected.** The table sends this when the user
clicks away and after a reload drops the previous selection, so handle it as a
normal state.

The table is passed in, so one delegate can serve several tables.

### Multiple selection is not this method

With `setAllowsMultipleSelection(true)` the delegate still reports a single
**anchor** row, because a delegate callback carries one row. The full selection
arrives as a [`UXIndexSet`](/compiler/api/uxkit/uxindexset/) on the
[`UXEventSelected`](/compiler/api/uxkit/uxevent/) event.

There are two reasons for the split:

- An anchor alone **replays as one row** however many were chosen, so a
  recording of a multi-select would be wrong.
- On a backend whose table is a native list, the click never reaches the
  toolkit. It arrives as `WM_NOTIFY`/`LVN_ITEMCHANGED`, so the event is the only
  record of what happened.

Use this method for "the user picked a row". Read the event's index set when you
need the whole selection.

## See also

- [Tables, outlines and data sources](/compiler/api/uxkit/guide-tables/): the
  working program
- [`UXTableDataSource`](/compiler/api/uxkit/uxtabledatasource/): the required
  half
- [`UXIndexSet`](/compiler/api/uxkit/uxindexset/): what a multi-selection is
- [`UXEvent`](/compiler/api/uxkit/uxevent/): `UXEventSelected`, and why it is
  an outcome rather than input
