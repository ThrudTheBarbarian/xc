---
title: RunLoop
description: "Hand work to one thread from any other, and run timers there: post, run, stop, runPending, after and every. How a worker's result gets back to the main thread. A complete method reference."
---

A `RunLoop` is a queue of blocks and the thread that runs them. Any thread
can [`post`](#post) to it. The blocks run in order on the thread that calls
[`run`](#run).

```c
#import "RunLoop.xc"
```

## Overview

```c
RunLoop* main = RunLoop.main();

main.post(block void(void) { … });                           // from any thread
main.after((u32)500, block void(void) { … });                // once, in 500 ms
Timer* t = main.every((u32)1000, block void(void) { … });    // until t.cancel()

main.run();                                                  // until main.stop()
```

This is how work done on another thread gets back to the main one.
[`Http`](/compiler/api/http/) and [`AsyncFiles`](/compiler/api/asyncfiles/)
normally call their completion blocks on their own worker threads. After
`deliverOn(RunLoop.main())` they post them here instead:

```c
Http.deliverOn(RunLoop.main());
Http.fetch(url, block void(u32 status, String* body) {
    // runs on the thread that calls RunLoop.main().run()
    });
RunLoop.main().run();
```

[`run`](#run) blocks until [`stop`](#stop). A program that already has a
loop of its own, such as a UI toolkit's frame callback, calls
[`runPending`](#runpending) from it instead. That runs whatever is queued and
returns.

Timers are checked once per jiffy (1/60 s), so a timer can fire up to about
17 ms late. They use the host's monotonic clock, so changing the wall clock
does not move them.

:::note[Availability]
**arm64** (macOS, iOS, Android), **x86_64** and **win64**. Importing it on
**xt6502**, **m68k**, **arm9** or **wasm32** is a compile-time error.
:::

## RunLoop

### main

```c
static RunLoop* main(void)
```

The process's main run loop, created on first use. Make the first call from
one thread, before other threads use it.

### post

```c
void post(block work void(void))
```

Queues `work` to run on the loop's thread. Any thread may call it. Blocks run
in the order they were posted.

### run

```c
void run(void)
```

Runs posted blocks and timers on the calling thread until
[`stop`](#stop) is called.

### runPending

```c
u32 runPending(void)
```

Runs every block queued at the time of the call and returns how many ran.
It does not wait for more.

### stop

```c
void stop(void)
```

Makes [`run`](#run) return after the block it is running. Any thread may
call it. If no `run` is in progress, the next one returns at once.

### after

```c
Timer* after(u32 ms, block work void(void))
```

Runs `work` once, `ms` milliseconds from now, on the loop's thread.

### every

```c
Timer* every(u32 ms, block work void(void))
```

Runs `work` every `ms` milliseconds, starting `ms` from now, until the timer
is cancelled. If the loop falls behind, the missed ticks are skipped, not
run back to back.

## Timer

### cancel

```c
void cancel(void)
```

Stops the timer. A tick that is already queued does not run. Any thread may
call it.

### isCancelled

```c
bool isCancelled(void)
```

Whether [`cancel`](#cancel) has been called.
