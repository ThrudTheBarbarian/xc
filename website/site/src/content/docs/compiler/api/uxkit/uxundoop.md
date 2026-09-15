---
title: UXUndoOp
description: "One recorded inverse: the call that puts things back and the data to put back, with the target held weakly and the data held strongly."
---

`UXUndoOp` is one registered inverse: the call that would undo a single model
change.

```c
#use <UXKit>            // or #import "UXUndoManager.xc"
```

## Overview

```c
class UXUndoOp {
    callback block void(Object* arg);    // what to call
    Object*           arg;               // what to pass it
}
```

[`registerUndo`](/compiler/api/uxkit/uxundomanager/#registerundo) makes one and
puts it in the open [`UXUndoGroup`](/compiler/api/uxkit/uxundogroup/).

```c
undo.registerUndo(&self.setX, box(oldX));     // "to undo, set x back to oldX"
```

## The asymmetry is the design

The two fields are held in different ways:

| | |
| --- | --- |
| `block` | a **callback** — never owns its receiver |
| `arg` | a **strong** reference — the data to restore |

The **target is not retained** because a model that owns its undo manager would
otherwise form a retain cycle: model → manager → group → op → model.
`NSUndoManager` does not retain targets either, for the same reason.

The **argument is retained** because it is the record's content. The old value
must survive until someone presses Undo, possibly long after the object it came
from has changed.

An undo stack keeps *data* alive and does not keep *objects* alive.

## A dead target is a silent skip

```c
callback b void(Object* arg) = op.block;
if (b != …0) { b(op.arg); }              // auto-zeroed when the receiver died
```

A callback auto-zeroes when its receiver is deallocated. An operation whose
model object has gone does nothing, and the rest of the group still runs.

Undoing a change to a document that has since been closed does not crash, and
does not prevent the other changes in that group from being undone.

As a result, an undo can accomplish nothing without reporting it. If your model
objects can die while their undo records live, this is the cause, and it is not
a fault in the stack.

## Why undo and redo need no second machine

An op only ever holds *the inverse*. There is no redo field, because putting
things back is itself a change: when the block runs, the model registers **its**
own inverse, and the manager routes that registration to the other stack.

```c
undo.undo();    // calls setX(oldX); setX registers setX(newX) as the redo
undo.redo();    // calls setX(newX); which registers setX(oldX) again
```

`UXUndoOp` has two fields, and undo/redo is one machine run in opposite
directions. For you this results in a rule, not an API:

:::tip[Register the inverse from inside the setter]
The setter that performs a change must register the undo for it, not the caller.
The same code then produces the undo record and the redo record, and the two
cannot describe different things.

Registering from the caller works for Undo and then fails for Redo without an
error, because the caller does not run during an undo.
:::

## Fields

### block

```c
callback block void(Object* arg)
```

The inverse call. Null is allowed and does nothing.

### arg

```c
Object* arg
```

The data to restore, retained. Null is fine for an inverse that needs no
argument, such as "re-show the panel".

Because it is an `Object*`, a primitive must be boxed. The box is a copy of the
old value taken at registration time, so the record does not track later
changes to its source.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXUndoGroup`](/compiler/api/uxkit/uxundogroup/): the ops that undo together
- [`UXUndoManager`](/compiler/api/uxkit/uxundomanager/): the stacks
- [Bound methods and callbacks](/compiler/language/bound-methods/): why a dead
  target is a silent skip
