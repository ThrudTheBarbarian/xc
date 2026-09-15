---
title: UXTimer
description: "Scheduled callbacks with no clock of their own: the caller passes the time in, so firing is deterministic and testable with synthetic time."
---

`UXTimer` fires a callback at an absolute time and, if it repeats, again every
interval after that. [`UXTimerScheduler`](#uxtimerscheduler) holds a set of
timers and fires every one that is due.

```c
#use <UXKit>            // or #import "UXTimer.xc"
```

## Overview

```c
UXTimer* once  = UXTimer.oneShot(100, &h.onOnce);        // at t=100
UXTimer* every = UXTimer.every(100, 50, &h.onEvery);     // t=100, then every 50ms

UXTimerScheduler* s = new UXTimerScheduler();
s.schedule(once);
s.schedule(every);
```

**The scheduler has no clock.** The driver passes the time to `tick(now)`; the
scheduler never reads a clock. Firing logic that never calls a clock is
deterministic, so the behaviour below (catch-up, pruning, cancellation) is
tested with synthetic time in a headless test instead of by sleeping.

Times are milliseconds, absolute rather than relative.

## The callback never owns its target

```c
callback onFire void(UXTimer* t)
```

A timer holds a [`callback`](/compiler/language/bound-methods/), which never
retains its receiver. When a controller is deallocated, its timers **stop
firing**. The timer neither keeps the controller alive nor calls into freed
memory. A teardown path does not need to invalidate every timer to stay safe;
invalidate the ones whose work you want to stop.

## Topics

[make](#make) · [oneShot](#oneshot) · [every](#every) · [fire](#fire) · [invalidate](#invalidate) · [isValid](#isvalid) · [schedule](#schedule) · [tick](#tick) · [nextFireTime](#nextfiretime) · [activeCount](#activecount)

### make

```c
static UXTimer* make(i32 fireTime, i32 interval, bool repeats, callback cb void(UXTimer* t))
```

The general constructor. Prefer [`oneShot`](#oneshot) or [`every`](#every),
which show at the call site whether the timer repeats.

### oneShot

```c
static UXTimer* oneShot(i32 at, callback cb void(UXTimer* t))
```

Fires once at `at`, then invalidates itself.

### every

```c
static UXTimer* every(i32 firstAt, i32 interval, callback cb void(UXTimer* t))
```

Fires at `firstAt` and every `interval` milliseconds after. The first fire is an
absolute time, not a delay, so timers given the same `firstAt` fire together.

### fire

```c
void fire(void)
```

Invokes the callback immediately, passing the timer itself. One handler can
therefore serve several timers and tell them apart by [`tag`](#fields) or
identity. The scheduler calls this; you rarely need to.

### invalidate

```c
void invalidate(void)
```

Stops the timer. It will not fire again, and the next [`tick`](#tick) removes it
from the scheduler. These happen at different times: the timer stops counting as
active immediately, and its array entry is removed on the next tick.

### isValid

```c
bool isValid(void)
```

Whether the timer will still fire.

### UXTimerScheduler

#### schedule

```c
void schedule(UXTimer* t)
```

Adds a timer. The scheduler owns it from then on.

#### tick

```c
i32 tick(i32 nowMs)      // returns how many fires happened
```

Fires every timer due at `nowMs`, reschedules repeaters, invalidates one-shots
and prunes invalid timers.

**A repeater that fell behind catches up.** If the loop was blocked and `tick`
jumps from 100 to 260, a 50ms repeater owes fires at 150, 200 and 250, and it
fires all three:

```
tick(260) -> the repeater catches up
  repeater fired (2)
  repeater fired (3)
  repeater fired (4)
  fires: 3
```

This suits anything that counts. For a handler that does real work on each
fire, a long stall produces a burst.

#### nextFireTime

```c
i32 nextFireTime(void)      // -1 when nothing is scheduled
```

The earliest pending fire time. The run loop uses it to decide **how long it may
sleep**, which lets an event loop idle at 0% CPU and still fire on time.

#### activeCount

```c
i32 activeCount(void)
```

How many timers are still valid. Invalidated timers drop out of this count
immediately, before they are pruned from the array.

## Example

Deterministic and headless, with no window and synthetic time throughout.

```c
#import <Stdio.xc>
#import "UXTimer.xc"

i32 gTicks;

class Handlers : Object {
    void init(void) { }
    void onOnce(UXTimer* t)  { Stdio.printf("  one-shot fired\n"); }
    void onEvery(UXTimer* t) { gTicks = gTicks + 1; Stdio.printf("  repeater fired (%d)\n", gTicks); }
}

void main(void) {
    gTicks = 0;
    Handlers* h = new Handlers();
    UXTimerScheduler* s = new UXTimerScheduler();

    s.schedule(UXTimer.oneShot(100, &h.onOnce));
    s.schedule(UXTimer.every(100, 50, &h.onEvery));

    s.tick(50);       // 0 fires — nothing due
    s.tick(100);      // 2 fires — both; the one-shot then prunes itself
    s.tick(260);      // 3 fires — the repeater catches up (150, 200, 250)

    Stdio.printf("next fire at: %d\n", s.nextFireTime());   // 300
}
```

The [catch-up](#tick) section quotes its output. The program is
`website/site/examples/uxkit/timers.xc`, and the `doc-examples` gate compiles it.

## Fields

```c
i32  fireTime     // next absolute fire time (ms)
i32  interval     // repeat interval (ms); 0 = one-shot
bool repeats
bool valid
i32  tag          // yours — tell timers apart in a shared handler
```

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXApplication`](/compiler/api/uxkit/uxapplication/): the run loop that
  ticks the scheduler and sleeps until `nextFireTime`
- [`UXAnimation`](/compiler/api/uxkit/uxanimation/): built on scheduled fires
- [Bound methods and callbacks](/compiler/language/bound-methods/): why a timer
  cannot keep a deallocated controller alive
