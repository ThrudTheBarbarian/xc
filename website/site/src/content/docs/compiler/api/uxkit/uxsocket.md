---
title: UXSocket
description: "A TCP connection with the same calls on every desktop and phone backend: connect by name, whole writes, reads that never block."
---

`UXSocket` is one TCP connection. It hides what differs between the hosts:
Winsock's start-up, `SOCKET` and `closesocket` on Windows, the two `addrinfo`
layouts, and `SIGPIPE` from a peer that has gone. The address comes from
`getaddrinfo`, IPv4 or IPv6, so nothing builds a `sockaddr` by hand.

```c
#import "UXSocket.xc"
```

## Overview

```c
UXSocket* s = UXSocket.connectTo((u8*)"localhost", (i32)7070);
if (s == (UXSocket*)0) {
    Stdio.printf("no daemon: %s\n", UXSocket.lastError());
    return;
}
s.write(request, n);
// each turn of the frame clock:
i32 got = s.read(buf, cap);   // > 0 bytes, 0 nothing yet, -1 the peer closed
```

`read` never blocks, so a client can poll it from its frame clock
([`UXApplication.everyTurn`](/compiler/api/uxkit/uxapplication/#everyturn)) while
the run loop keeps turning. [`waitReadable`](#waitreadable) blocks for up to a
given time, for a tool that has nothing else to do.

There is no TCP in a browser (wasm32) or on XTOS here: `connectTo` answers null
with the reason.

## Topics

**Connecting** · [connectTo](#connectto) · [lastError](#lasterror) · [isOpen](#isopen) · [close](#close)
**Data** · [write](#write) · [writeData](#writedata) · [read](#read) · [waitReadable](#waitreadable)

### connectTo

```c
static UXSocket* connectTo(u8* host, i32 port)
```

A connection to `host:port`, a name or a numeric address. It blocks until the
connection is made or refused. Null when it cannot be made, with
[`lastError`](#lasterror) saying why.

### lastError

```c
static u8* lastError(void)
```

Why the last `connectTo` failed, or `""` after one that succeeded.

### isOpen

```c
bool isOpen(void)
```

False once the connection is closed, by [`close`](#close) or by the peer.

### write

```c
bool write(u8* p, i32 n)
```

Sends every byte. False when the connection has gone, and the socket is then
closed.

### writeData

```c
bool writeData(Data* d)
```

`write` of a [`Data`](/compiler/api/data/)'s bytes.

### read

```c
i32 read(u8* p, i32 cap)
```

What has arrived, without waiting: the byte count (up to `cap`), `0` when
nothing has arrived yet, or `-1` when the peer has closed the connection or it
failed. The socket is then closed.

### waitReadable

```c
bool waitReadable(i32 ms)
```

Waits up to `ms` milliseconds (`0`: not at all, `-1`: as long as it takes) for
something to read or for the peer to go. True when `read` would return something
other than `0`.

### close

```c
void close(void)
```

Closes the connection. A socket also closes when it is freed.
