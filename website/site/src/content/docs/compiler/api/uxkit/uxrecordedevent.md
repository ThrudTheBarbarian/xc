---
title: UXRecordedEvent
description: "One captured event and when it happened, relative to the start of recording. A deep copy, so replay does not depend on a reused buffer."
---

`UXRecordedEvent` is one entry in a
[`UXEventRecorder`](/compiler/api/uxkit/uxeventrecorder/)'s tape.

```c
#use <UXKit>            // or #import "UXEventRecorder.xc"
```

## Overview

```c
class UXRecordedEvent : Object {
    UXEvent* event;     // a COPY of what arrived
    i32      timeMs;    // milliseconds since recording began
}
```

## It is a copy, and that is not an optimisation detail

The event is **deep-copied** on capture. Drivers routinely reuse one
[`UXEvent`](/compiler/api/uxkit/uxevent/) object for every event they announce,
filling in the fields and dispatching, to avoid an allocation per mouse-move.

A recorder that stored the pointer would end up with a thousand references to
one object holding whatever arrived last. Copying makes the tape a faithful
record.

The tape is also independent of the driver afterwards. A recording made under
AppKit can be replayed without AppKit, which a backend-neutral repro needs.

## Time is relative, and supplied

```c
i32 timeMs
```

Milliseconds since [`start`](/compiler/api/uxkit/uxeventrecorder/) was called,
not an absolute clock reading.

Because time is relative, a recording means the same thing whenever it is
replayed. Because it is **supplied by the caller** rather than read, the recorder
holds no clock, and a test can record with synthetic time and get a deterministic
tape.

Together these make a recorded bug a repro: the same events, at the same
offsets, every run.

## Replay speed is the caller's

The timestamps are recorded, and replay feeds the events to a sink **in order**.
It does not sleep between them.

Replaying at original speed, as fast as possible, or one event at a time are all
the caller's choice, made by how it uses `timeMs`. A test wants instant replay, a
demo wants real time, and a debugging session wants a step button.

## Fields

### event

```c
UXEvent* event
```

The copy, held strongly. Safe to keep, inspect and replay more than once;
nothing consumes it.

### timeMs

```c
i32 timeMs
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXEventRecorder`](/compiler/api/uxkit/uxeventrecorder/): capture and replay
- [`UXEvent`](/compiler/api/uxkit/uxevent/): what is being copied, and why it
  is reused
