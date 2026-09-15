---
title: UXNotificationObs
description: "One registration in the notification centre, and the record that implements the weak-observer lifetime rule."
---

`UXNotificationObs` is one registration inside a
[`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/). You do not
construct one; `addObserver` makes it. The centre's lifetime guarantees are
implemented here.

```c
#use <UXKit>            // or #import "UXNotificationCenter.xc"
```

## Overview

```c
class UXNotificationObs {
    weak: Object*  observer;      // identity, for removeObserver
    callback method void(UXNotification* note);
    u8*            name;          // 0 = match ANY name
    weak: Object*  object;        // 0 = match ANY sender
}
```

It has four fields, and three of them avoid **owning** anything.

## Why both references are weak

`observer` is weak because the centre must not keep a subscriber alive:
`window → centre → observer → window` would be a retain cycle around every
window in the program.

`object`, the sender being filtered on, is weak for the same reason: an
observer watching one document should not keep that document in memory.

`method` is a [callback](/compiler/language/bound-methods/), which never
owns its receiver.

A registration therefore holds **nothing** alive. When an observer dies its
callback reads false, dispatch skips the entry, and the next sweep prunes it.
For this reason
[`removeObserver`](/compiler/api/uxkit/uxnotificationcenter/#removeobserver) is
hygiene rather than a crash guard.

## The two wildcards

Both `name` and `object` treat `0` as **match anything**:

| field | `0` means |
| --- | --- |
| `name` | every notification, whatever it is called |
| `object` | every sender |

`object == 0` is the common case: "tell me about `doc.changed` from anyone".

`name == 0` is rarer. A registration with no name hears **everything**, which
suits a logger or a debugging trace. The
[`addObserver`](/compiler/api/uxkit/uxnotificationcenter/#addobserver) signature
takes a name, so pass `0` explicitly:

```c
nc.addObserver((Object*)tracer, &tracer.onAny, (u8*)0, (Object*)0);
```

Both wildcards at once means "every notification from every sender". It is cheap
to write and expensive to leave in, since it fires on every post in the process.

## Names are compared by content

The centre compares notification names **byte by byte**, not by pointer. Two
copies of the same string match, so a name read from a file, built at
run time, or defined in a different compilation unit still works.

With interned pointers instead, `"doc.changed"` from two places would fail to
match without any error.

## Fields

### observer

```c
weak: Object* observer
```

Identity only. `removeObserver` matches on it; the centre never calls it
directly.

### method

```c
callback method void(UXNotification* note)
```

What gets called. It carries its receiver, so the `observer` field is not used
for dispatch.

### name

```c
u8* name        // 0 = any
```

### object

```c
weak: Object* object    // 0 = any sender
```

## See also

- [`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/): the bus
  that holds these
- [`UXNotification`](/compiler/api/uxkit/uxnotification/): what the callback
  receives
- [Heap, ARC and weak refs](/compiler/language/memory/): what `weak:` does
