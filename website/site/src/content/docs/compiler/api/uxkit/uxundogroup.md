---
title: UXUndoGroup
description: "The inverses that undo together as one user action, and the name shown in Undo <name>."
---

`UXUndoGroup` makes several model edits undo as **one** user action.

```c
#use <UXKit>            // or #import "UXUndoManager.xc"
```

## Overview

```c
class UXUndoGroup {
    Array<UXUndoOp>* ops;     // the inverses, newest last
    u8*              name;    // shown in "Undo <name>"; 0 = none
}
```

[`UXUndoManager`](/compiler/api/uxkit/uxundomanager/) makes and stacks these;
you do not construct one. When a group opens and closes decides what a single
press of Undo reverses.

## A group is the unit of undo

The stacks hold groups, not operations. One Undo pops one group and runs every
inverse in it.

"Delete the selection" might change ten objects in the model. It is one group
and one Undo, provided the ten registrations happened inside the group.

## Implicit and explicit grouping

```c
undo.registerUndo(&self.setX, box(oldX));     // implicit: its own group
```

A registration outside any explicit group opens a group, adds itself, and closes
it. One edit gives one Undo with no extra calls.

```c
undo.beginUndoGrouping();
for (each selected object) { … registerUndo … }
undo.setActionName((u8*)"Delete");
undo.endUndoGrouping();                        // one group, one Undo
```

Explicit grouping marks registrations that belong together. Nesting is counted:
begin/end pairs can nest, and only the outermost close pushes the group. A
compound operation can therefore call smaller operations that group internally,
and they do not become separate Undos.

:::note[An empty group is discarded]
A group that collected no registrations is not pushed. Wrapping an operation
that changes nothing does not leave a do-nothing entry on the stack.
:::

## Ops run in reverse

```c
Array<UXUndoOp>* ops      // newest last
```

Undoing walks the array **backwards**. This is required for correctness whenever
edits interact.

If you move an object and then delete it, undoing must recreate the object
*before* restoring its position; otherwise the position is set on something that
does not exist. Recording forwards and replaying backwards handles this
automatically.

## The name comes from the action

```c
u8* name       // 0 when never set
```

The name is what a menu shows as *"Undo Delete"*. It is stamped on the group
when the group closes, or set on the most recent group when
[`setActionName`](/compiler/api/uxkit/uxundomanager/#setactionname) is called
right after a single registration. The second case supports the ordinary idiom:

```c
undo.registerUndo(&self.setX, box(oldX));
undo.setActionName((u8*)"Change X");        // names the edit it follows
```

A null name is valid and means the menu reads plain *"Undo"*. Check for it
before printing it.

The name **travels with the group across the stacks**. Undoing an action named
*"Delete"* puts a group named *"Delete"* on the redo stack, and the menu reads
*"Redo Delete"*. Nothing re-labels it.

## Fields

### ops

```c
Array<UXUndoOp>* ops
```

The inverses, in registration order. Held strongly: a group owns its
operations, and through them the data needed to restore.

### name

```c
u8* name
```

Kept, not copied. Pass a literal, or a string that outlives the undo stack.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXUndoManager`](/compiler/api/uxkit/uxundomanager/): the stacks and the
  machine
- [`UXUndoOp`](/compiler/api/uxkit/uxundoop/): one recorded inverse
