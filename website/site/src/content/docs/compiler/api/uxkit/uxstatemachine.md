---
title: UXStateMachine
description: "States and named transitions, declared once and driven by events: a wizard, a tool palette, or any 'what happens when X in state Y' logic."
---

`UXStateMachine` is a finite state machine: named **states**, and **transitions**
that say which event moves you from one to another.

It suits anything where the effect of an event depends on the current state: a
multi-step wizard with Back and Next, a tool palette of modes, an interaction
flow. It is pure logic with no window, and fully testable.

```c
#use <UXKit>            // or #import "UXStateMachine.xc"
```

## Overview

```c
UXStateMachine* m = new UXStateMachine();
m.setInitial((u8*)"welcome");

m.addTransition((u8*)"welcome", (u8*)"next",   (u8*)"details");
m.addTransition((u8*)"details", (u8*)"next",   (u8*)"confirm");
m.addTransition((u8*)"confirm", (u8*)"finish", (u8*)"done");

m.fire((u8*)"next");        // welcome -> details
m.isIn((u8*)"details");     // true
```

The flow is **declared once** and the UI fires events. A screen does not need to
know what comes next, and adding a step means adding a transition, not editing
three buttons.

### What is not declared cannot happen

```c
m.fire((u8*)"next");        // from "confirm" — returns false, state unchanged
```

An event the current state has no transition for is **refused**. It is neither
an error nor a crash. The machine enforces the rule, so "you cannot go forward
from the last page" needs no `if` in the UI.

The same approach handles the awkward cases. Cancel, reachable from every step
except the last, is three declared transitions and no special case:

```c
m.addTransition((u8*)"welcome", (u8*)"cancel", (u8*)"cancelled");
m.addTransition((u8*)"details", (u8*)"cancel", (u8*)"cancelled");
m.addTransition((u8*)"confirm", (u8*)"cancel", (u8*)"cancelled");
// nothing from "done" — so canFire("cancel") is false once finished
```

## Buttons read `canFire`

```c
nextButton.setEnabled(m.canFire((u8*)"next"));
backButton.setEnabled(m.depth() > 0);
```

Enabled state is derived from the declared flow instead of being tracked
separately, so the two cannot disagree.

## Back walks history, not transitions

```c
bool back(void)
```

`fire` pushes the state it left onto a history stack, and `back` pops it. Back
returns you the way you **came**, which is not always the reverse of a declared
transition. In a flow that branches and rejoins, reversing transitions could send
you down the wrong branch.

`back` returns false at the start; a Back button reads this to disable itself.
`depth()` is the number of steps of history.

:::note[Cancelling does not rewind]
`back` undoes navigation, not effects. A transition into `cancelled` is an
ordinary transition, and `back` from it returns you to the state you cancelled
from. If cancelling should end the flow, make `cancelled` terminal by declaring
no transitions out of it.
:::

## Topics

[setInitial](#setinitial) · [addTransition](#addtransition) · [fire](#fire) · [canFire](#canfire) · [back](#back) · [isIn](#isin) · [depth](#depth) · [transitionFor](#transitionfor)

### setInitial

```c
void setInitial(u8* state)
```

The starting state. Call before firing anything.

### addTransition

```c
void addTransition(u8* fromState, u8* event, u8* toState)
```

Declare one edge. States and events are **strings**, with no registry: a state
is any name you use. A typo creates a state that never matches, not a compile
error, so keep the names in one place.

### fire

```c
bool fire(u8* event)
```

Move, if the current state has a transition for that event. Returns whether it
moved, and pushes history when it does.

### canFire

```c
bool canFire(u8* event)
```

Whether [`fire`](#fire) would move, without moving. A button's enabled state
reads this.

### back

```c
bool back(void)
```

Return to the previous state, popping history. False when there is none.

### isIn

```c
bool isIn(u8* state)
```

Test the current state by name.

### depth

```c
i32 depth(void)
```

How many steps of history are on the stack, which is how far Back can go.

### transitionFor

```c
UXTransition* transitionFor(u8* event)
```

The transition that `event` would take from the current state, or null. Use it
when you need the **destination** as well as whether a move is possible, for
instance to label a Next button with the step it leads to.

## Example

```
start:         state=welcome depth=0
canFire next=1 finish=0
after next:    state=details depth=1
after next:    state=confirm depth=2
fire next from confirm: refused (no such transition)
after back:    state=details depth=1
after back:    state=welcome depth=0
back at the start: refused
finished:      state=done depth=3
isIn done: yes   cancel still possible: no
```

The program is `website/site/examples/uxkit/statemachine.xc`; the
`doc-examples` gate compiles it, and the output above is its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXTransition`](/compiler/api/uxkit/uxtransition/): one declared edge
- [`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/): a
  push/pop stack of *views*, where this is a flow of *states*
- [`UXUndoManager`](/compiler/api/uxkit/uxundomanager/): the other history
  stack in the toolkit, for model changes instead of navigation
