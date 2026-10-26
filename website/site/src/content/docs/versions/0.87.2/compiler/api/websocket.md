---
title: WebSocket
description: "WebSocket clients and servers over Socket: the handshake, text and binary messages, ping, and the closing handshake; wss through the TLS layer Http uses."
slug: versions/0.87.2/compiler/api/websocket
banner:
  content: 'This is the documentation for xc 0.87.2. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

`WebSocket` is a WebSocket connection (RFC 6455), as a client or as one of a
`WebSocketServer`'s clients, with the same calls on macOS, iOS, Android, Linux
and Windows.

```c
#import "WebSocket.xc"     // not in the Foundation umbrella: import it by name
```

## Overview

```c
try
    {
    WebSocket* ws = WebSocket.connect(Url.withString(String.withCString("ws://localhost:7070/chat")));
    ws.sendText(String.withCString("hello"));
    WebSocketMessage* m = ws.receive(5000);           // up to 5 s for a reply
    if (m != nil && m.isText())
        Stdio.printf("%s\n", m.text().cString());
    ws.close();
    }
catch (WebSocketError e)
    {
    Stdio.printf("%s\n", e.message().cString());    // cannot connect to localhost:7070
    }
```

A server listens on a port and completes the handshake with each client that
connects; what it gets back is a `WebSocket` like any other, with the request's
path and headers:

```c
WebSocketServer* server = WebSocketServer.listen(7070);
for (;;)
    {
    WebSocket* c = server.accept(-1);                 // a client, handshake done
    if (c == nil) continue;
    Stdio.printf("%s\n", c.path().cString());         // /chat?room=1
    WebSocketMessage* m;
    while ((m = c.receive(-1)) != nil)
        c.sendText(m.text());                          // echo
    }
```

Messages are text (UTF-8) or binary, whole: a fragmented message is
reassembled before `receive` returns it. A ping from the peer is answered with
a pong inside `receive`, and a pong to one of yours is consumed there. A close
from the peer is answered and reported: `receive` returns `nil`, `isOpen` is
false and `closeCode` holds its code. A client masks what it sends, as the
protocol requires; a server does not.

**Reading blocks only as long as you say.** `receive` waits up to its `ms` for
a message to start, so a program can poll from a timer and the
[run loop](/versions/0.87.2/compiler/api/runloop/) keeps turning; `-1` waits for as long as it
takes. A connection the peer closes, or that fails, reads as closed from then
on.

`wss:` goes through the TLS layer [`Http`](/versions/0.87.2/compiler/api/http/) uses: import
`HttpTls.xc` and call `HttpTls.install()` first, and `connect` verifies the
server's certificate as https does. A `WebSocketServer` takes plain `ws:`
connections; put a TLS-terminating proxy in front of it for `wss:`.

:::note[Availability]
arm64 (macOS, iOS, Android), x86_64 and win64. On arm9 and m68k the file
compiles and `connect` and `listen` throw `no TCP sockets on this platform`,
as [`Socket`](/versions/0.87.2/compiler/api/socket/) does. Not on xt6502. wasm32 has the
client only, described below.
:::

## In a browser (wasm32)

On wasm32 the client is the host's own WebSocket: the browser's, or Node's.
A page's thread cannot block, so what waits is different:

- `connect` returns at once with the connection still opening. What you send
  before it opens is queued and goes when it does. A connection that fails is
  not a throw: the delivery's last call is `nil` and `closeCode` is 1006.
- Messages arrive through [`deliver`](#deliveron), called from the host's
  event loop after `main` has returned. `receive` hands back only a message
  that has already arrived.
- There is no `WebSocketServer`: a page cannot listen.

```c
WebSocket* ws = WebSocket.connect(Url.withString(String.withCString("wss://example.com/feed")));
ws.sendText(String.withCString("hello"));
ws.deliver(block void(WebSocketMessage* m) {
    if (m == nil) { Stdio.printf("closed %u\n", (u32)ws.closeCode()); return; }
    Stdio.printf("%s\n", m.text().cString());
    });
```

## Topics

**Connecting** · [connect](#connect) · [isOpen](#isopen) · [close](#close) · [closeWith](#closewith)

**Sending** · [sendText](#sendtext) · [sendData](#senddata) · [sendBytes](#sendbytes) · [ping](#ping)

**Receiving** · [receive](#receive) · [deliverOn](#deliveron) · [WebSocketMessage](#websocketmessage)

**After a close** · [closeCode](#closecode) · [closeReason](#closereason)

**The handshake** · [path](#path) · [header](#header)

**Serving** · [WebSocketServer](#websocketserver)

**Errors** · [WebSocketError](#websocketerror)

---

## Connecting

### connect
```c
static WebSocket* connect(Url* url) throws
```
Opens `url` (`ws:` or `wss:`; the port defaults to 80 or 443) and completes
the handshake, blocking until it is done or refused. Throws a
[`WebSocketError`](#websocketerror) saying why when it cannot be: the host, a
refused connection, a TLS failure, or a reply that is not `101` with the right
`Sec-WebSocket-Accept`.

### isOpen
```c
bool isOpen(void)
```

### close
```c
void close(void)
```
The closing handshake with code 1000: sends a close frame, waits up to two
seconds for the peer's, and closes the connection. A connection is also closed
when it is freed, without the handshake.

### closeWith
```c
void closeWith(u16 code, String* reason)
```
The same with a code of your own and a reason (may be `nil`).

[↑ Topics](#topics)

## Sending

### sendText
```c
bool sendText(String* s)
```
A text message, the String's UTF-8 bytes. False when the connection has gone
(it is then closed).

### sendData
```c
bool sendData(Data* d)
```
A binary message.

### sendBytes
```c
bool sendBytes(u8* p, u32 n)
```
A binary message of `n` bytes at `p`.

### ping
```c
bool ping(void)
```
A ping; the peer's pong is consumed by [`receive`](#receive).

[↑ Topics](#topics)

## Receiving

### receive
```c
WebSocketMessage* receive(i32 ms)
```
The next message, waiting up to `ms` milliseconds (0: not at all, -1: for as
long as it takes) for one to start; `nil` when none starts in time, and `nil`
once the connection is closed — [`isOpen`](#isopen) tells which. Pings are
answered and pongs consumed on the way. A frame over 64 MB, or a frame that
breaks the protocol, closes the connection with code 1009 or 1002.

### deliverOn
```c
void deliverOn(RunLoop* loop, block onMessage void(WebSocketMessage*))
void deliver(block onMessage void(WebSocketMessage*))
```
Messages as callbacks. `receive` runs on a thread of its own, and each
message is handed to `onMessage` on the thread running `loop`, in order. The
last call has `nil`: the connection has closed. Do not call `receive` on the
socket once it is delivering. `deliver` does the same without a run loop: the
calls come on the receive thread itself, or on wasm32 from the host's event
loop (the only form there).
```c
RunLoop* loop = RunLoop.main();
ws.deliverOn(loop, block void(WebSocketMessage* m) {
    if (m == nil) { loop.stop(); return; }
    Stdio.printf("%s\n", m.text().cString());
    });
loop.run();
```

### WebSocketMessage
```c
bool isText(void)
String* text(void)      // the bytes as a String
Data* data(void)        // the bytes
```

[↑ Topics](#topics)

## After a close

### closeCode
```c
u16 closeCode(void)
```
The peer's code when it closed (1005 when it sent none), 1006 when the
connection went without a close frame, or the code this side closed with.

### closeReason
```c
String* closeReason(void)
```
The peer's reason, or `nil`.

[↑ Topics](#topics)

## The handshake

### path
```c
String* path(void)
```
On a server's connection, the request's path with its query (`/chat?room=1`);
on a client's, the path it asked for.

### header
```c
String* header(String* name)
```
A header of the handshake — the request's on a server's connection, the
reply's on a client's — by its name in any case; `nil` when absent.

[↑ Topics](#topics)

## WebSocketServer

```c
static WebSocketServer* listen(u16 port) throws
WebSocket* accept(i32 ms)
void close(void)
```
`listen` binds the port (throws a `SocketError` when it cannot). `accept`
waits up to `ms` milliseconds (-1: for as long as it takes) for a client, reads
its handshake and answers it; `nil` when none connects in time, or when what
connected was not a WebSocket handshake (it is answered `400` and closed).

[↑ Topics](#topics)

## WebSocketError

```c
class WebSocketError <Error>
String* message(void)
```
What [`connect`](#connect) throws.
