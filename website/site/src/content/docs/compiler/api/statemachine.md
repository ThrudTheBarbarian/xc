---
title: StateMachine
description: "A finite state machine of named states and events: declared once, driven by events, with Back."
---

`StateMachine` is a finite state machine of named states and events: a wizard's
steps, a drawing tool's modes, a connection's life. Transitions are declared
once ("in this state, this event leads to that state") and the machine is
driven by events. **From 0.72.**

```c
#import "StateMachine.xc"  // not in the Foundation umbrella: import it by name
```

## Overview

```c
StateMachine* m = StateMachine.withInitial(String.withCString("idle"));
m.addTransition(String.withCString("idle"), String.withCString("start"), String.withCString("running"));
m.addTransition(String.withCString("running"), String.withCString("stop"), String.withCString("idle"));
m.fire(String.withCString("start"));   // true: now "running"
m.fire(String.withCString("start"));   // false: "running" has no "start"
m.back();                              // true: "idle" again
```

States and events are `String`s compared by value. Declaring the same state and
event again replaces the target. [`fire`](#fire) moves only when the current
state has a transition for the event; [`back`](#back) returns to the state
before the last move, for a wizard's Back button.

:::note[Availability]
Every heap-capable target, the 6502 included (there [`depth`](#depth) is a
`u16`).
:::

## Topics

**Creating** · [withInitial](#withinitial) · [addTransition](#addtransition) · [setDidChange](#setdidchange)

**The state** · [state](#state) · [isIn](#isin) · [setState](#setstate)

**Driving** · [fire](#fire) · [canFire](#canfire) · [targetOf](#targetof) · [events](#events) · [back](#back) · [depth](#depth)

---

## Creating

### withInitial
```c
static StateMachine* withInitial(String* state)
```
A machine in `state`, with no transitions yet.

### addTransition
```c
void addTransition(String* from, String* event, String* to)
```
In `from`, `event` leads to `to`.

### setDidChange
```c
void setDidChange(callback method void(String* from, String* event, String* to))
```
Calls `method` (a bound method, `&watcher.moved`) after each [`fire`](#fire)
that moves, with the state left, the event and the state entered. Null stops the
calls. [`back`](#back) and [`setState`](#setstate) do not call it.

[↑ Topics](#topics)

## The state

### state
```c
String* state(void)
```

### isIn
```c
bool isIn(String* state)
```

### setState
```c
void setState(String* state)
```
Puts the machine in `state` without a transition and forgets the history: a
start or a reset.

[↑ Topics](#topics)

## Driving

### fire
```c
bool fire(String* event)
```
Moves if the current state has a transition for `event`, and reports whether it
did.

### canFire
```c
bool canFire(String* event)
```

### targetOf
```c
String* targetOf(String* event)
```
Where `event` leads from the current state, or null.

### events
```c
Array* events(void)
```
The events the current state has transitions for, in the order they were
declared: what a UI enables.

### back
```c
bool back(void)
```
Returns to the state before the last move; false when there is none.

### depth
```c
u32 depth(void)        // u16 on the 6502
```
How many moves [`back`](#back) can undo.

[↑ Topics](#topics)
