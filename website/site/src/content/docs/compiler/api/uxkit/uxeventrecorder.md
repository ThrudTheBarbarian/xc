---
title: UXEventRecorder
description: "Capture a stream of UI events and replay it for deterministic bug repros, demos and 'do that again', with no clock and no dispatch of its own."
---

`UXEventRecorder` tees a copy of each event into a list, and replays them to a
sink.

```c
#use <UXKit>            // or #import "UXEventRecorder.xc"
```

## Overview

```c
UXEventRecorder* r = new UXEventRecorder();
r.start(nowMs);
// … the application runs; the event tap calls r.record(e, nowMs) …
r.stop();

r.replay(&self.dispatch);        // feed them back, in order
```

Use it for deterministic bug repros, demos, and "do that again".

## It taps a funnel that already exists

The neutral run loop puts **every** event through one place. A recorder is a
tee off that funnel and adds nothing to the dispatch path.

The toolkit therefore needs no special recording mode. Anything that reaches the
application reaches the recorder, with no second code path that could behave
differently.

## No clock, no dispatch

The recorder does **not** own two things:

- **the clock**: the caller passes `nowMs` in, from the driver
- **the sink**: the caller provides where replayed events go, which is the
  application's own dispatch

The model is backend-neutral and testable with **synthetic time**. A test
records at times it chose, replays into a sink it wrote, and asserts on the
output, with no window, no driver and no waiting.

[`UXTimerScheduler`](/compiler/api/uxkit/uxtimerscheduler/) uses the same
design, for the same reason.

## Events are deep-copied

```c
static UXEvent* copyEvent(UXEvent* e)
```

Drivers usually reuse **one** [`UXEvent`](/compiler/api/uxkit/uxevent/) object
for every event they announce, filling in the fields and dispatching, because an
allocation per mouse-move is too expensive.

A recorder storing pointers would end up with a thousand references to one
object holding whatever arrived last. Copying keeps each recorded event intact,
and lets a tape captured under AppKit replay with no AppKit present.

## Replay does not sleep

```c
void replay(callback sink void(UXEvent* e))
void replayRange(callback sink void(UXEvent* e), i32 fromMs, i32 toMs)
```

Events are fed to the sink **in order**, as fast as the loop runs. Timing is
recorded, not enforced.

The caller decides the replay speed: instant for a test, real-time for a demo,
one at a time for a debugging session. The recorder does not choose, because
the three cases need different things.

[`replayRange`](#replayrange) makes a long recording useful. A bug 40 seconds
into a session is reproduced by replaying 38 to 42, without sitting through the
rest.

## Recording is a switch, not a lifetime

```c
r.start(nowMs);      // clears the tape and begins
r.stop();            // stops; the tape is kept
r.isRecording();
```

[`start`](#start) **clears** the tape, so it begins a new recording and does not
resume. `stop` keeps the events, so the tape is available to replay or inspect
afterwards. [`clear`](#clear) discards it.

A `record` call while not recording is ignored. The tap can stay installed
permanently and costs one boolean test when nothing is being recorded.

## Topics

[start](#start) · [stop](#stop) · [isRecording](#isrecording) · [record](#record) · [count](#count) · [eventAt](#eventat) · [timeAt](#timeat) · [durationMs](#durationms) · [clear](#clear) · [replay](#replay) · [replayRange](#replayrange)

### start

```c
void start(i32 nowMs)
```

Clears the tape, begins recording, and takes `nowMs` as time zero. Every
recorded timestamp is relative to it.

### stop

```c
void stop(void)
```

### isRecording

```c
bool isRecording(void)
```

### record

```c
void record(UXEvent* e, i32 nowMs)
```

Called by the tap. Copies the event and stamps it. A no-op when not recording.

### count

```c
i32 count(void)
```

### eventAt

```c
UXEvent* eventAt(i32 i)
```

One recorded event, **unwrapped** from its
[`UXRecordedEvent`](/compiler/api/uxkit/uxrecordedevent/), for asserting on
what arrived without replaying it.

### timeAt

```c
i32 timeAt(i32 i)
```

That event's offset in milliseconds from the start of recording. Together with
`eventAt`, it lets you inspect a recording without the boxing type.

### durationMs

```c
i32 durationMs(void)
```

The last event's timestamp, which is how long the recording spans. `0` for an
empty tape.

Use it to choose a [`replayRange`](#replayrange) window, or as the length a demo
paces against.

### clear

```c
void clear(void)
```

### replay

```c
void replay(callback sink void(UXEvent* e))
```

Replays every event, in order.

### replayRange

```c
void replayRange(callback sink void(UXEvent* e), i32 fromMs, i32 toMs)
```

Replays only the events whose timestamps fall in the window.

:::note[The sink is a callback, so nothing is owned]
A replay into a sink whose receiver has died is silently skipped instead of
crashing. Every other callback in the toolkit follows the same lifetime model.

If a replay produces nothing, check that the receiver is still alive before
checking the tape.
:::

## See also

- [`UXRecordedEvent`](/compiler/api/uxkit/uxrecordedevent/): one entry, and why
  the copy matters
- [`UXEvent`](/compiler/api/uxkit/uxevent/): what is being recorded, and why it
  is reused
- [`UXTimerScheduler`](/compiler/api/uxkit/uxtimerscheduler/): the same
  no-clock-of-its-own design
