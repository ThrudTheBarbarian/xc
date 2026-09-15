---
title: UXLogMonitor
description: "One log watch: a compiled pattern and the callback to fire when a message matches it."
---

`UXLogMonitor` is one registration on a [`UXLog`](/compiler/api/uxkit/uxlog/):
a pattern to watch for and a callback to call.

```c
#use <UXKit>            // or #import "UXLog.xc"
```

## Overview

```c
class UXLogMonitor : Object {
    UXRegex*             pattern;
    callback cb void(u8* msg);
}
```

[`addMonitor`](/compiler/api/uxkit/uxlog/#addmonitor) makes one; you do not
construct it.

## Two fields, and both are about not owning

A **callback** never owns its receiver. A monitor therefore cannot keep its
observer alive, and a log watcher registered by a window does not keep that
window in memory.

When the observer is freed, the callback reads false, the monitor is skipped,
and nothing crashes. [`removeMonitor`](/compiler/api/uxkit/uxlog/#removemonitor)
is therefore not needed as a crash guard or as teardown. Call it to stop
watching while the observer is still alive.

The **pattern** is a shared
[`UXRegex`](/compiler/api/uxkit/uxregex/), compiled once when the monitor was
added. Each message costs a match, not a compile, however many messages go
past. One pattern object can serve several monitors.

## The match is a search

The monitor calls `pattern.test(msg)`, so the pattern has to occur
**somewhere** in the message; it does not have to describe all of it. A
monitor for `"timeout"` fires on `"read timeout after 30s"`.

[`UXValidator`](/compiler/api/uxkit/uxvalidator/#a-regex-rule-matches-the-whole-value)'s
regex rule works the other way: it uses `matches` and must describe the entire
field. Both use the same engine. A log pattern anchored with `^…$` will almost
never fire.

## A null pattern never fires

```c
UXRegex* pattern     // null is skipped, not treated as "match everything"
```

If [`compile`](/compiler/api/uxkit/uxregex/#compile) was given an invalid
pattern, the monitor is inert rather than firing on every line. A broken
pattern that produced a flood would be worse than one that produces nothing.
If a monitor never fires, check
[`isValid`](/compiler/api/uxkit/uxregex/#isvalid).

`compile` never returns a null regex object, so a null `pattern` here means
null was passed on purpose.

## Removal is by callback

[`removeMonitor`](/compiler/api/uxkit/uxlog/#removemonitor) matches on the
**callback**, not the pattern. If the same callback is registered twice with
different patterns, you cannot choose which to remove; the first match goes.

For a watcher that needs several patterns under individual control, give each
pattern its own method.

## Fields

### pattern

```c
UXRegex* pattern
```

Held strongly, and shareable between monitors.

### cb

```c
callback cb void(u8* msg)
```

Receives the message that matched. The message is the logger's `u8*`, valid for
the duration of the call. Copy it with
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup) to keep it.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXLog`](/compiler/api/uxkit/uxlog/): the logger these attach to
- [`UXRegex`](/compiler/api/uxkit/uxregex/): the patterns
- [`UXNotificationObs`](/compiler/api/uxkit/uxnotificationobs/): the same
  weak-observer shape for notifications
