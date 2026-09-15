---
title: UXUndoManager
description: "Undo and redo are one machine run in opposite directions: register the inverse as the change happens, and redo follows."
---

`UXUndoManager` is a neutral undo/redo stack with the shape of `NSUndoManager`.
The design rests on one idea:

> An undoable change registers, **at the moment it happens**, the call that
> would put things back.

To undo, the manager invokes that call. Putting things back is *itself* a
change, so that call registers **its** inverse, which becomes the redo. Undo and
redo are the same machine run in opposite directions, with no separate redo
bookkeeping.

```c
#use <UXKit>            // or #import "UXUndoManager.xc"
```

## The pattern

```c
class Model : Object {
    i32 x;
    UXUndoManager* undo;

    void setX(Object* arg) {
        i32 want = ((Box* ?)arg).v;
        undo.registerUndo(&self.setX, (Object*)Box.of(x));   // "to undo, put x back"
        undo.setActionName((u8*)"Change X");
        x = want;
    }
}
```

Register **before** you change, because the inverse needs the old value.

This one method supports undo *and* redo. Undoing calls `setX(oldX)`, which
registers `setX(newX)` as the redo. Redoing calls that, which registers the undo
again. You write the inverse once.

```
x=30   canUndo=1 canRedo=0
undo   x=20      canRedo=1
undo   x=10
redo   x=20
```

## Grouping: one user action, several model edits

A single user action often touches the model several times and must undo as one
step:

```c
undo.beginUndoGrouping();
m.setX(Box.of(100));
m.setX(Box.of(200));
undo.endUndoGrouping();

undo.undo();        // back to 20 — the WHOLE group, not just the last edit
```

A single registration outside an explicit group gets a group implicitly, so
simple cases need no extra calls.

While a group is being undone, every re-registration goes into **one new
group** pushed to the other stack. A multi-edit action therefore also redoes in
one step.

## Topics

[registerUndo](#registerundo) · [setActionName](#setactionname) · [undo](#undo) · [redo](#redo) · [canUndo](#canundo--canredo) · [canRedo](#canundo--canredo) · [undoActionName](#undoactionname--redoactionname) · [redoActionName](#undoactionname--redoactionname) · [beginUndoGrouping](#beginundogrouping--endundogrouping) · [endUndoGrouping](#beginundogrouping--endundogrouping) · [removeAllActions](#removeallactions) · [disableUndoRegistration](#disableundoregistration) · [enableUndoRegistration](#disableundoregistration) · [isUndoRegistrationEnabled](#disableundoregistration) · [isUndoing](#isundoing--isredoing) · [isRedoing](#isundoing--isredoing)

### registerUndo

```c
void registerUndo(callback block void(Object* arg), Object* arg)
```

Records the call that reverses the change about to be made. The argument is
passed as an `Object*`, so a value type needs boxing.

The callback never owns its receiver. A model that has been deallocated leaves a
dead entry and is not resurrected.

### setActionName

```c
void setActionName(u8* name)
```

Names the group for a menu item: "Undo Change X".

### undo

```c
void undo(void)
```

Invokes the top undo group. Its re-registrations become the redo.

### redo

```c
void redo(void)
```

The reverse of `undo`: invokes the top redo group, and its re-registrations
become the undo.

### canUndo / canRedo

```c
bool canUndo(void)
bool canRedo(void)
```

Whether each stack is non-empty. A menu item's enabled state reads these.

### undoActionName / redoActionName

```c
u8* undoActionName(void)      // 0 when the stack is empty
u8* redoActionName(void)
```

The name of the group that would run, for the menu title.

### beginUndoGrouping / endUndoGrouping

```c
void beginUndoGrouping(void)
void endUndoGrouping(void)
```

Explicit grouping. See [above](#grouping-one-user-action-several-model-edits).

### removeAllActions

```c
void removeAllActions(void)
```

Clears both stacks. A document calls this when it is saved-as or reverted, where
the old history no longer describes anything reachable.

### disableUndoRegistration

```c
void disableUndoRegistration(void)
void enableUndoRegistration(void)
bool isUndoRegistrationEnabled(void)
```

Suspends recording. The main use is **loading a document**: populating a model
runs the same setters as a user edit, and without this the user could undo back
to an empty document they never created.

```c
undo.removeAllActions();
undo.disableUndoRegistration();
self.loadFrom(file);                 // same setters, no history
undo.enableUndoRegistration();
// canUndo() == 0
```

### isUndoing / isRedoing

```c
bool isUndoing(void)
bool isRedoing(void)
```

Which direction is running, if any. A model can use this to behave differently
while being reversed, for example to suppress a notification or skip a
validation that only applies to user input.

## Example

The full program is `website/site/examples/uxkit/undo.xc`, and the
`doc-examples` gate compiles it. Its output:

```
x=30  canUndo=1 canRedo=0
after undo  x=20  canRedo=1
after undo  x=10
after redo  x=20
grouped to x=200
one undo takes the WHOLE group back to x=20
cleared:    canUndo=0
after a disabled edit x=999 canUndo=0 (nothing registered)
```

The last two lines clear the stacks first: `canUndo == 0` only shows that the
disabled edit registered nothing if the stacks were empty beforehand.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXUndoGroup`](/compiler/api/uxkit/uxundogroup/) and
  [`UXUndoOp`](/compiler/api/uxkit/uxundoop/): what the stacks hold
- [`UXMenuItem`](/compiler/api/uxkit/uxmenuitem/): where the action names and
  enabled states go
- [Bound methods and callbacks](/compiler/language/bound-methods/): what
  `&self.setX` is
