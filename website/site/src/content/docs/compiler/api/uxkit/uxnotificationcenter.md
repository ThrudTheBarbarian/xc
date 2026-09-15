---
title: UXNotificationCenter
description: "A publish/subscribe bus: one poster, any number of observers that need not know it, and a lifetime model that cannot form a retain cycle."
---

`UXNotificationCenter` is a neutral publish/subscribe bus, shaped like
`NSNotificationCenter`. One object posts a named notification, and any
number of others are called back. The observers need not know the poster
exists.

It is the **decoupled sibling of target/action**: an action goes from one
sender to one known receiver; a notification goes from one sender to N unknown
receivers.

```c
#use <UXKit>            // or #import "UXNotificationCenter.xc"
```

## Overview

```c
UXNotificationCenter* nc = UXNotificationCenter.shared();

nc.addObserver((Object*)self, &self.onChanged, (u8*)"doc.changed", (Object*)0);
nc.postWith((u8*)"doc.changed", (Object*)0, 42, 7);
```

```c
void onChanged(UXNotification* note) {
    Stdio.printf("%s a=%d b=%d\n", note.name, note.a, note.b);
}
```

Posting a name **nobody observes is not an error**; it is not delivered.
A library can post freely without knowing whether anyone is listening.

## Lifetime: why this is not a callback list

A naive observer list keeps its observers alive, which creates a **retain cycle**:
`window → centre → observer → window`. The centre therefore owns
neither half of a registration:

- the observer is held **`weak:`**
- the callback never owns its receiver

A dead observer's callback reads false, so dispatch skips it and the next sweep
prunes the entry.

:::tip[`removeObserver` is hygiene, not a crash guard]
Forgetting it does not crash or leak: the entry is pruned when the
observer dies. Call it when a live object should *stop hearing* something;
it is not mandatory teardown.
:::

### The notification's `object` is strong, deliberately

`UXNotification.object` (the poster) is a **strong** reference, like
`NSNotification`'s. A notification is transient (created, delivered and
discarded within one post), so it cannot form a cycle and nothing needs to
stay alive beyond the call.

It must **not** be weak. A weak register/unregister on the sender for every
post churns the sender's weak list, which accumulates and eventually corrupts.
The symptom is a crash inside the runtime's weak bookkeeping, far from the
post that caused it.

## Filtering by sender

The fourth argument to `addObserver` is the **object to hear from**:

```c
nc.addObserver((Object*)w, &w.onChanged, (u8*)"doc.changed", (Object*)docA);
```

| `object` | meaning |
| --- | --- |
| `0` | **any** sender — every post of that name |
| an object | only posts whose sender is that object |

An observer registered with `0` hears posts from every sender, including ones a
filtered observer ignores. Both kinds coexist on the same name. A
document-per-window app uses this: a global status line listens to all
documents, and each window listens only to its own.

## Topics

[shared](#shared) · [addObserver](#addobserver) · [removeObserver](#removeobserver) · [post](#post) · [postWith](#postwith) · [postNotification](#postnotification)

### shared

```c
static UXNotificationCenter* shared(void)
```

The process-wide centre, made on first use. It has the same lazy-singleton
shape as [`UXNull.null()`](/compiler/api/uxkit/uxnull/) and
[`UXLog.shared()`](/compiler/api/uxkit/uxlog/).

You can also make your own centre for a private bus.

### addObserver

```c
void addObserver(Object* observer, callback method void(UXNotification* note),
                 u8* name, Object* object)
```

Subscribes. `observer` is held weakly and is what
[`removeObserver`](#removeobserver) matches on; `method` is the callback;
`name` is the notification; `object` filters by sender (see
[above](#filtering-by-sender)).

### removeObserver

```c
void removeObserver(Object* observer)
```

Drops every registration for that observer.

### post

```c
void post(u8* name, Object* object)
```

Posts with no payload.

### postWith

```c
void postWith(u8* name, Object* object, i32 a, i32 b)
```

Posts with a **small generic payload**. `a` and `b` are two integers, which
cover most toolkit notifications (a resize carries width and height) without
allocating a userInfo dictionary for every post.

When two integers are not enough, define a notification whose `object` *is* the
thing being announced, and let the observer ask it.

### postNotification

```c
void postNotification(UXNotification* n)
```

Posts a pre-built [`UXNotification`](/compiler/api/uxkit/uxnotification/),
when you are forwarding one or want to construct it yourself.

## Example

```
post 'doc.changed':
  left  heard 'doc.changed' (a=42 b=7)
  right heard 'doc.changed' (a=42 b=7)
post 'doc.saved' (no observers):
post from a DIFFERENT sender:
  left  heard 'doc.changed' (a=1 b=1)
  right heard 'doc.changed' (a=1 b=1)
post from the watched sender:
  left  heard 'doc.changed' (a=2 b=2)
  right heard 'doc.changed' (a=2 b=2)
  watch heard 'doc.changed' (a=2 b=2)
after removeObserver(right):
  left  heard 'doc.changed' (a=9 b=9)
```

`left` and `right` registered with `object == 0`, so they hear every post;
`watch` registered against one sender and hears only that one. The program is
`website/site/examples/uxkit/notify.xc` and the `doc-examples` gate compiles it.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXNotification`](/compiler/api/uxkit/uxnotification/): what a callback
  receives
- [`UXNotificationObs`](/compiler/api/uxkit/uxnotificationobs/): one
  registration
- [`UXControl`](/compiler/api/uxkit/uxcontrol/): target/action, the coupled
  alternative
- [Bound methods and callbacks](/compiler/language/bound-methods/): why a dead
  observer is a silent skip
