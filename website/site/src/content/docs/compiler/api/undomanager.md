---
title: UndoManager
description: "Undo and redo: each change registers the call that puts it back, grouped into named user actions."
---

`UndoManager` records how to undo changes and replays them (`NSUndoManager` in
shape). **From the release after 0.71.**

```c
#import "UndoManager.xc"   // not in the Foundation umbrella: import it by name
```

## Overview

Undo rests on one idea: an undoable change registers, as it happens, the call
that would put things back. Undoing makes that call, and because putting things
back is itself a change, that call registers its own inverse, which becomes the
redo. Undo and redo are one machine run in opposite directions.

```c
class Model : Object
    {
    Number* x;
    UndoManager* undo;
    void setX(Object* v)
        {
        undo.registerUndo(&self.setX, x);   // "to undo, set x back to the old x"
        x = (Number*)v;
        }
    }

model.setX(Number.withI32((i32)5));
undo.setActionName(String.withCString("Change X"));
undo.undo();     // calls setX(old); setX registers setX(5) as the redo
undo.redo();     // calls setX(5); setX registers setX(old) as the undo again
```

**Groups.** Registrations are collected into groups, so several changes undo as
one user action. A registration outside any group is a group of its own;
[`beginUndoGrouping`](#beginundogrouping--endundogrouping) and
[`endUndoGrouping`](#beginundogrouping--endundogrouping), which nest, make
larger ones. A group's calls are undone newest first. While a group is undone,
everything it registers lands in one new group on the redo stack, so a whole
action redoes in one step. A new change made outside undo and redo clears the
redo stack.

**Lifetime.** A registered call does not keep its target alive (a model that
owns its undo manager would otherwise be a cycle), and a call whose target has
gone is skipped. The argument is kept: it is the data to restore.

:::note[Availability]
Every heap-capable target except xt6502.
:::

## Topics

**Registering** · [registerUndo](#registerundo) · [setActionName](#setactionname)

**Grouping** · [beginUndoGrouping / endUndoGrouping](#beginundogrouping--endundogrouping) · [groupingLevel](#groupinglevel)

**Undoing and redoing** · [undo / redo](#undo--redo) · [canUndo / canRedo](#canundo--canredo) · [undoActionName / redoActionName](#undoactionname--redoactionname) · [isUndoing / isRedoing](#isundoing--isredoing)

**Housekeeping** · [levelsOfUndo](#levelsofundo) · [removeAllActions](#removeallactions) · [disableUndoRegistration / enableUndoRegistration](#disableundoregistration--enableundoregistration)

---

## Registering

### registerUndo
```c
void registerUndo(callback block void(Object* arg), Object* arg)
```
Records "to undo, call `block(arg)`", where `block` is a method bound to the
object to change (`&model.setX`). Outside an open group it is a group of its
own. Nothing is recorded while registration is disabled.

### setActionName
```c
void setActionName(String* name)
```
Names the action, for an "Undo *name*" menu item. Inside an open group it names
that group; otherwise it names the group just recorded, so the usual
`model.setX(v); undo.setActionName(…)` names the change it follows. Undoing
and redoing keep the name.

[↑ Topics](#topics)

## Grouping

### beginUndoGrouping / endUndoGrouping
```c
void beginUndoGrouping(void)
void endUndoGrouping(void)
```
Open and close a group. Groups nest; the outermost one goes on its stack when it
closes, if anything was registered in it.

### groupingLevel
```c
u32 groupingLevel(void)
```
How deep the open groups are nested; 0 when none is open.

[↑ Topics](#topics)

## Undoing and redoing

### undo / redo
```c
void undo(void)
void redo(void)
```
Undo the newest group, or redo the newest undone one; nothing when there is none.
A group still open is closed first.

### canUndo / canRedo
```c
bool canUndo(void)
bool canRedo(void)
```

### undoActionName / redoActionName
```c
String* undoActionName(void)
String* redoActionName(void)
```
The name of the group that [`undo`](#undo--redo) or [`redo`](#undo--redo) would
run, or null.

### isUndoing / isRedoing
```c
bool isUndoing(void)
bool isRedoing(void)
```
Whether a call is being made by `undo` or `redo`: a setter may ask, to do less
work on the way back.

[↑ Topics](#topics)

## Housekeeping

### levelsOfUndo
```c
u32 levelsOfUndo;
```
The most groups kept on each stack; the oldest go first. 0, the default, keeps
all.

### removeAllActions
```c
void removeAllActions(void)
```
Forgets every undo and redo, and any open group.

### disableUndoRegistration / enableUndoRegistration
```c
void disableUndoRegistration(void)
void enableUndoRegistration(void)
bool isUndoRegistrationEnabled(void)
```
Stop and resume recording, as while a document loads. The calls nest:
registration resumes after as many enables as disables.

[↑ Topics](#topics)
