---
title: UXTransition
description: "One declared edge of a state machine: from this state, on this event, go to that one."
---

`UXTransition` is one edge in a
[`UXStateMachine`](/compiler/api/uxkit/uxstatemachine/).

```c
#use <UXKit>            // or #import "UXStateMachine.xc"
```

## Overview

```c
class UXTransition : Object {
    u8* fromState;
    u8* event;
    u8* toState;
}
```

```c
m.addTransition((u8*)"welcome", (u8*)"next", (u8*)"details");
```

A transition is three strings. The flow is the set of transitions.

## The edges *are* the rules

A machine holds only transitions, so **what is not declared cannot happen**. An
event with no matching transition from the current state is refused, and this is
not an error. A rule such as "you cannot go forward from the last page" is the
absence of an edge, with no check elsewhere.

For this reason
[`canFire`](/compiler/api/uxkit/uxstatemachine/#canfire) is enough to drive a
button's enabled state, and adding a step to a wizard is an `addTransition`
call with no edits to the screens.

## Everything is a string, and nothing is registered

States and events are names you invent. There is no enumeration and no
declaration step, so:

- a **typo is a state that never matches**. There is no compile error or runtime
  error; the edge never fires.
- the same name in two places is the same state, so a flow can be assembled from
  separate pieces

Keeping the names in one place, such as a header of literals, gives most of the
benefit of an enum without the machine knowing about it.

## Reading one back

```c
UXTransition* t = m.transitionFor((u8*)"next");
if (t != (UXTransition*)0) { label.setText(t.toState); }
```

[`transitionFor`](/compiler/api/uxkit/uxstatemachine/#transitionfor) returns
the edge that an event *would* take. A Next button can use it to show where it
leads as well as whether it is enabled.

A flow can also inspect itself this way: a diagram of a wizard is a walk over
its transitions.

:::note[Not the same as history]
`toState` says where an edge goes. It does **not** say where
[`back`](/compiler/api/uxkit/uxstatemachine/#back) will take you: back walks the
*history* of states actually visited and does not reverse an edge.

In a flow that branches and rejoins, reversing the declared edge would lead down
the wrong arm. The machine answers the two questions separately.
:::

## Fields

### fromState

```c
u8* fromState
```

### event

```c
u8* event
```

### toState

```c
u8* toState
```

All three are **kept, not copied**. Pass literals, or strings that outlive the
machine.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXStateMachine`](/compiler/api/uxkit/uxstatemachine/): the machine these
  describe
- [`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/): a
  stack of views, where this is a graph of states
