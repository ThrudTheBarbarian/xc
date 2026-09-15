---
title: UXNotification
description: "What a notification callback receives: the name, who posted it, and two integers of payload."
---

`UXNotification` is what an observer's callback receives when a notification is
delivered. It has four fields and no behaviour.

```c
#use <UXKit>            // or #import "UXNotificationCenter.xc"
```

## Overview

```c
class UXNotification {
    u8*     name;       // the notification that was posted
    Object* object;     // who posted it; 0 if anonymous
    i32     a;          // payload
    i32     b;
}
```

```c
void onResize(UXNotification* note) {
    i32 width  = note.a;
    i32 height = note.b;
    UXWindow* win = (UXWindow* ?)note.object;
}
```

## Two integers, not a dictionary

`a` and `b` carry a **small generic payload**. This covers most notifications
(a resize is width and height, a selection is an index and a count) without
allocating a userInfo dictionary for every post.

When two integers are not enough, make `object` **the thing being announced**
and let the observer ask it:

```c
nc.post((u8*)"doc.changed", (Object*)document);
// observer: ((Document* ?)note.object).title()
```

The notification stays transient and the data stays where it already lives,
instead of being copied into the post.

## `object` is a strong reference

The observer registration holds its observer **weakly** to avoid a retain
cycle. The notification's `object` is strong, as `NSNotification`'s is.

This is safe because a notification is **transient**: created, delivered and
discarded within one post. It cannot form a cycle, and nothing needs to stay
alive beyond the call.

:::caution[It must not be weak]
A weak `object` would register and unregister a weak reference on the sender for
**every post**, which churns the sender's weak list. That list accumulates and
eventually corrupts, and the symptom is a crash inside the runtime's weak
bookkeeping, far from the post that caused it.
:::

## Reading `object` safely

`object` is `0` for an anonymous post, so a cast needs a check unless you know
every poster of that name:

```c
void onChanged(UXNotification* note) {
    Document* d = (Document* ?)note.object;
    if (d == (Document*)0) { return; }      // anonymous, or not a Document
    …
}
```

The checked cast also returns null on a type mismatch, which matters when a name
is posted by more than one kind of sender.

## Fields

### name

```c
u8* name
```

The notification that was posted. Check it when one callback serves
several registrations. A method per notification is usually clearer.

### object

```c
Object* object
```

The poster, or `0`. The centre also filters on it: an observer registered
against a specific object hears only posts whose `object` is that one. See
[`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/#filtering-by-sender).

### a / b

```c
i32 a;
i32 b;
```

The payload, with a meaning defined by the notification. Document what yours
carry: they are untyped, so the name is the only contract.

## See also

- [`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/): posting,
  observing, and the lifetime model
- [`UXNotificationObs`](/compiler/api/uxkit/uxnotificationobs/): one
  registration
- [`UXEvent`](/compiler/api/uxkit/uxevent/): the other type that arrives with
  `a`/`b` payloads, for input rather than announcements
