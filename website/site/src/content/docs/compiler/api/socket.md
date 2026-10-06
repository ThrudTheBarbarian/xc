---
title: Socket
description: "A TCP connection with the same calls on every hosted target: connect by name, write, and read what has arrived without blocking."
---

`Socket` is a TCP connection with the same calls on macOS, iOS, Android, Linux
and Windows. **From 0.72.**

```c
#import "Socket.xc"        // not in the Foundation umbrella: import it by name
```

## Overview

```c
try
    {
    Socket* s = Socket.connect(String.withCString("localhost"), (u16)7070);
    s.writeString(String.withCString("hello\n"));
    s.waitReadable((i32)1000);                 // up to a second for a reply
    Data* reply = s.readAvailable((u32)4096);
    s.close();
    }
catch (SocketError e)
    {
    Stdio.printf("%s\n", e.message().cString());   // cannot connect to localhost:7070
    }
```

It hides what differs between the hosts: Winsock's start-up, `SOCKET` and
`closesocket` on Windows, the two `addrinfo` layouts, and `SIGPIPE` from a peer
that went away. The address comes from `getaddrinfo`, IPv4 or IPv6.

**Reading never blocks.** [`read`](#read) and [`readAvailable`](#readavailable)
return what has arrived, so a client can poll from a timer and the
[run loop](/compiler/api/runloop/) keeps turning; [`waitReadable`](#waitreadable)
blocks for as long as the caller chooses. A connection that fails, or that the
peer closes, is closed here, and reads then report it.

[`Http`](/compiler/api/http/) speaks HTTP over the same declarations.

:::note[Availability]
arm64 (macOS, iOS, Android), x86_64 and win64 have TCP. On wasm32, arm9 and
m68k the file compiles, so a program can import it everywhere, and
[`connect`](#connect) throws `no TCP sockets on this platform`. Not on xt6502.
:::

## Topics

**Connecting** · [connect](#connect) · [isOpen](#isopen) · [close](#close)

**Writing** · [write](#write) · [writeData](#writedata) · [writeString](#writestring)

**Reading** · [waitReadable](#waitreadable) · [read](#read) · [readAvailable](#readavailable)

**Errors** · [SocketError](#socketerror)

---

## Connecting

### connect
```c
static Socket* connect(String* host, u16 port) throws
```
A connection to `host:port` (a name or a numeric address, IPv4 or IPv6),
blocking until it is made or refused. Throws a [`SocketError`](#socketerror)
saying why when it cannot be.

### isOpen
```c
bool isOpen(void)
```

### close
```c
void close(void)
```
A socket is also closed when it is freed.

[↑ Topics](#topics)

## Writing

### write
```c
bool write(u8* p, u32 n)
```
Sends every byte; false when the connection has gone (it is then closed).

### writeData
```c
bool writeData(Data* d)
```

### writeString
```c
bool writeString(String* s)
```
The String's UTF-8 bytes, without a terminator.

[↑ Topics](#topics)

## Reading

### waitReadable
```c
bool waitReadable(i32 ms)
```
Waits up to `ms` milliseconds (0: not at all, -1: for as long as it takes) for
something to read, or for the peer to go; true when [`read`](#read) would return
something other than 0.

### read
```c
i32 read(u8* p, u32 cap)
```
What has arrived, without waiting: the number of bytes (up to `cap`), 0 when
nothing has yet, -1 when the peer has closed the connection or it failed (it is
then closed).

### readAvailable
```c
Data* readAvailable(u32 max)
```
The same as [`Data`](/compiler/api/data/): empty when nothing has arrived, null
when the connection is closed.

[↑ Topics](#topics)

## Errors

### SocketError
```c
class SocketError <Error>
String* message(void)
```
What [`connect`](#connect) throws: `cannot resolve the host '…'`,
`cannot connect to host:port`, or `no TCP sockets on this platform`.

[↑ Topics](#topics)
