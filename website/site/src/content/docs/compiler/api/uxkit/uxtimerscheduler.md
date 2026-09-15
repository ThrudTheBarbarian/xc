---
title: UXTimerScheduler
description: "Fires timers that are due and tells the run loop how long it may sleep. It has no clock of its own, so the firing logic is testable with synthetic time."
---

`UXTimerScheduler` holds [`UXTimer`](/compiler/api/uxkit/uxtimer/)s.
[`tick`](#tick) fires every timer that is due; [`nextFireTime`](#nextfiretime)
returns when the next one is.

```c
#use <UXKit>            // or #import "UXTimer.xc"
```

## Overview

```c
UXTimerScheduler* s = new UXTimerScheduler();
s.schedule(UXTimer.oneShot(100, &h.onOnce));
s.schedule(UXTimer.every(100, 50, &h.onEvery));

s.nextFireTime();     // 100
s.tick(50);           // 0 fires — nothing is due
s.tick(100);          // 2 fires
```

## It has no clock

The time is **passed in**, and the rest of the design follows from that.

A scheduler that read the clock itself could only be tested by waiting. This one
is a pure function of `(timers, now)`, so all of the firing logic (catch-up,
rescheduling, pruning) runs headless in microseconds against synthetic time.

The driver supplies the real clock at the one call site that needs it. A backend
with an unusual source of time changes that one line, not the scheduler.

## Backlogged repeaters catch up

```
tick(100) -> repeater fires
tick(260) -> fires THREE times: it owed 150, 200 and 250
```

A repeating timer that fell behind fires once for every interval it missed.
`tick` loops while the timer is still due.

This is correct for anything that counts, such as an animation frame counter or
a timeout accumulating elapsed time: the number of fires equals the number of
intervals that passed, regardless of when `tick` was called.

:::caution[A long stall means a burst of fires in one tick]
If the process is suspended, a modal loop blocks, or a slow paint runs long, the
next `tick` fires all the missed intervals at once. A 10 ms repeater across a
10-second stall fires a thousand times in one call.

For a timer whose handler is expensive, or where firing once after a gap is the
right behaviour, invalidate and reschedule instead of repeating, or check the
elapsed time in the handler and return early. The scheduler cannot tell which
behaviour you want, so it fires once per interval.
:::

Calling [`invalidate`](/compiler/api/uxkit/uxtimer/#invalidate) **inside** a
handler stops the catch-up immediately. The loop tests validity on each pass, so
the timer stops at once instead of after the backlog drains.

## One-shots prune themselves

A one-shot invalidates when it fires, and `tick` removes every invalid timer
after the pass. A scheduler therefore does not accumulate spent timers, and
[`activeCount`](#activecount) drops without any cleanup code.

Pruning happens **after** the firing loop, so invalidating during a handler is
safe: nothing is removed from the array while it is being walked.

## nextFireTime is how the run loop sleeps

```c
i32 next = s.nextFireTime();     // -1 when nothing is scheduled
```

`-1` means *nothing pending*, so the run loop may block indefinitely waiting for
input instead of spinning. Any other value is an absolute time, and the sleep is
`next - now` clamped at zero.

This lets an idle application use no CPU instead of waking many times a second
to find nothing to do.

## Topics

[schedule](#schedule) · [tick](#tick) · [nextFireTime](#nextfiretime) · [activeCount](#activecount)

### schedule

```c
void schedule(UXTimer* t)
```

Adds a timer. The scheduler holds it **strongly** until it is invalidated and
pruned, so the caller does not need to keep a one-shot alive.

A timer whose fire time has already passed can be scheduled; it fires on the
next `tick`.

### tick

```c
i32 tick(i32 nowMs)
```

Fires every timer that is due, reschedules repeaters, invalidates one-shots, and
prunes invalid timers. Returns the **number of fires**, which exceeds the number
of timers when repeaters caught up.

Time is in milliseconds, absolute rather than a delta. The scheduler compares
times instead of accumulating them, so an occasional missed tick does not make
timers drift.

### nextFireTime

```c
i32 nextFireTime(void)
```

The earliest pending fire time, or `-1`.

### activeCount

```c
i32 activeCount(void)
```

The number of valid timers. Invalid timers are pruned on the next `tick`, so
between a manual `invalidate` and that tick the array holds more entries than
this count.

## Example

```
active: 2  next fire at: 100
tick(50)  -> nothing is due yet
  fires: 0
tick(100) -> both are due
  fires: 2
  active now: 1 (the one-shot pruned itself)
tick(260) -> the repeater catches up
  fires: 3
```

The three fires at `tick(260)` are the intervals at 150, 200 and 250. The
program is `website/site/examples/uxkit/timers.xc`. The `doc-examples` gate
compiles it, and the output above is what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXTimer`](/compiler/api/uxkit/uxtimer/): one scheduled callback
- [`UXOperationQueue`](/compiler/api/uxkit/uxoperationqueue/): the other
  deterministic scheduler, ordered by dependency rather than time
- [`UXDate`](/compiler/api/uxkit/uxdate/): wall-clock time, where this is
  elapsed milliseconds
