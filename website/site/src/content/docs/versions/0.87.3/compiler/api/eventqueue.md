---
title: EventQueue
description: "One wait for a socket to have something to read or for another thread to say it has work: kqueue, epoll or WSAPoll underneath."
slug: versions/0.87.3/compiler/api/eventqueue
banner:
  content: 'This is the documentation for xc 0.87.3. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

`EventQueue` is one wait for two kinds of event: a socket has something to
read (or has closed), or another thread has called `wake()`. A loop that
serves connections and hands work to threads blocks here once, instead of
waiting a millisecond at a time and asking again.

```c
#import "EventQueue.xc"    // not in the Foundation umbrella: import it by name
```

## Overview

```c
EventQueue* q = EventQueue.make();
q.watch(sock.fd());              // readable, or closed, ends the wait
// ... on a worker thread, when its result is ready:
q.wake();
// ... on the loop's thread:
if (q.wait(1000))                // up to a second; -1 waits as long as it takes
    {
    // a socket is readable, or a thread woke the queue: look at both
    }
q.close();
```

A wake that comes while nobody is waiting is kept, so the next `wait` returns
at once. A result finished between "nothing yet" and "wait" is never missed.
A wait says only *that* something happened, not what: after it, ask each
socket and each queue of results, as the loop would after any wait.

## Underneath

| | |
|---|---|
| macOS, iOS | `kqueue`, woken through an `EVFILT_USER` event |
| Linux, Android | `epoll`, woken through an `eventfd` |
| Windows | `WSAPoll` over the watched sockets and a loopback UDP socket that `wake` sends a byte to |

On wasm32 and the retro targets `make` returns 0. There is nothing there to
wait on, so a caller keeps a timed wait.

## Calls

| | |
|---|---|
| `static EventQueue* make(void)` | A new queue, or 0 where the platform has none |
| `bool watch(i64 fd)` | Wake the wait when `fd` (a `Socket`'s `fd()`) is readable or closed |
| `void unwatch(i64 fd)` | Stop watching `fd`; call it before closing a socket you keep the queue for |
| `void wake(void)` | From any thread: end the wait now, or the next one at once |
| `bool wait(i32 ms)` | Up to `ms` milliseconds (`-1`: no limit); true when a socket or a wake ended it |
| `void close(void)` | Free the queue's own descriptors; the watched sockets stay the caller's |

## Where it is used

`xcd`, the `par` daemon, waits on its connection and on its GPU's tiles with
one `EventQueue`. A thread blocks on each tile's completion and wakes the
queue, so a finished tile is sent back the moment it is ready. A program's
tile loop waits the same way when all its tiles are out on remote GPUs.
