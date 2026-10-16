// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// WebSocket.xc — the wasm32 form: the client over the browser's (or Node's)
// own WebSocket, through the `browser` package. Shadows the generic file.
//
// A page's thread cannot block, so the shape differs from the native one
// in what waits. connect() returns at once with the connection opening;
// messages sent before it is open are queued and go when it opens. Messages
// arrive through deliver(), called from the host's event loop after main has
// returned; receive() hands back only what has already arrived. A failure to
// connect is not a throw here but the delivery's nil. There is no server: a
// page cannot listen.

#import "String.xc"
#import "Data.xc"
#import "Error.xc"
#import "Url.xc"
#import "Map.xc"
#import "Array.xc"
#import "Number.xc"

#package browser
extern void _b_ws_open(u32 token, u8* url, u32 n);
extern void _b_ws_send(u32 token, u32 text, u8* p, u32 n);
extern void _b_ws_close(u32 token, u32 code, u8* reason, u32 n);

class WebSocketError <Error>
    {
    String* _message;
    void init(String* message)
        {
        _message = message;
        }
    String* message(void)
        {
        return _message;
        }
    }

// One message: text (UTF-8) or binary.
class WebSocketMessage
    {
    bool _text;
    Data* _data;
    bool isText(void)
        {
        return _text;
        }
    Data* data(void)
        {
        return _data;
        }
    String* text(void)
        {
        return String.withBytes(_data.bytes(), _data.length());
        }
    }

// The open connections by token, so an event from the host finds its socket;
// a socket stays here until it has closed.
Map* _ws_open;
u32 _ws_next;

class WebSocket
    {
    u32 _token;
    bool _open;
    bool _closed;
    u16 _closeCode;
    String* _closeReason;
    Array* _queue;          // arrived, not yet taken by receive()
    block _cb void(WebSocketMessage*);
    bool _hasCb;

    static WebSocket* connect(Url* url)
        {
        if (_ws_open == (Map*)0)
            {
            _ws_open = new Map();
            _ws_next = (u32)1;
            }
        WebSocket* ws = new WebSocket();
        ws._token = _ws_next;
        _ws_next = _ws_next + (u32)1;
        ws._open = true;
        ws._closed = false;
        ws._closeCode = (u16)0;
        ws._closeReason = String.withCString("");
        ws._queue = new Array();
        ws._hasCb = false;
        _ws_open.set((Hashable*)Number.with(ws._token), (Object*)ws);
        String* s = url.toString();
        _b_ws_open(ws._token, s.cString(), s.byteLength());
        return ws;
        }

    bool sendText(String* s)
        {
        if (!_open)
            return false;
        _b_ws_send(_token, (u32)1, s.cString(), s.byteLength());
        return true;
        }
    bool sendData(Data* d)
        {
        return sendBytes(d.bytes(), d.length());
        }
    bool sendBytes(u8* p, u32 n)
        {
        if (!_open)
            return false;
        _b_ws_send(_token, (u32)0, p, n);
        return true;
        }
    // The host answers pings and sends none of a program's own.
    bool ping(void)
        {
        return _open;
        }

    // What has arrived, oldest first; nil when nothing has (`ms` is not
    // waited: a page's thread cannot block).
    WebSocketMessage* receive(i32 ms)
        {
        if (_queue.count() == (u32)0)
            return (WebSocketMessage*)0;
        WebSocketMessage* m = (WebSocketMessage*)_queue.get((u32)0);
        _queue.removeAt((u32)0);
        return m;
        }

    // Each message to `onMessage` as it arrives, from the host's event loop;
    // nil last, once the connection has closed (or never opened). Messages
    // that arrived before are handed over first.
    void deliver(block onMessage void(WebSocketMessage*))
        {
        _cb = onMessage;
        _hasCb = true;
        while (_queue.count() > (u32)0)
            {
            WebSocketMessage* m = (WebSocketMessage*)_queue.get((u32)0);
            _queue.removeAt((u32)0);
            onMessage(m);
            }
        if (_closed)
            onMessage((WebSocketMessage*)0);
        }

    void closeWith(u16 code, String* reason)
        {
        if (!_open)
            return;
        _b_ws_close(_token, (u32)code, reason.cString(), reason.byteLength());
        }
    void close(void)
        {
        closeWith((u16)1000, String.withCString(""));
        }
    bool isOpen(void)
        {
        return _open;
        }
    u16 closeCode(void)
        {
        return _closeCode;
        }
    String* closeReason(void)
        {
        return _closeReason;
        }
    // A server-side connection's path and the handshake's headers: neither
    // reaches a page.
    String* path(void)
        {
        return String.withCString("");
        }
    String* header(String* name)
        {
        return (String*)0;
        }

    void _arrived(WebSocketMessage* m)
        {
        if (_hasCb)
            _cb(m);
        else if (m != (WebSocketMessage*)0)
            _queue.add((Object*)m);
        }
    }

// The host's events (the loader's `browser` package): kind 1 a text message,
// 2 a binary one, 3 closed (with its code and reason), 4 failed. The bytes
// are at p, from _xt_browser_alloc, and are the program's to free.
extern void _xt_ws_event(u32 token, u32 kind, u32 code, u8* p, u32 n)
    {
    WebSocket* ws = _ws_open == (Map*)0 ? (WebSocket*)0 : (WebSocket*)_ws_open.get((Hashable*)Number.with(token));
    if (ws == (WebSocket*)0)
        {
        if (p != 0)
            delete p;
        return;
        }
    if (kind == (u32)1 || kind == (u32)2)
        {
        WebSocketMessage* m = new WebSocketMessage();
        m._text = kind == (u32)1;
        m._data = Data.withBytes(p, n);
        if (p != 0)
            delete p;
        ws._arrived(m);
        return;
        }
    ws._open = false;
    ws._closed = true;
    ws._closeCode = kind == (u32)3 ? (u16)code : (u16)1006;
    ws._closeReason = p != 0 ? String.withBytes(p, n) : String.withCString("");
    if (p != 0)
        delete p;
    _ws_open.remove((Hashable*)Number.with(token));
    if (ws._hasCb)
        ws._cb((WebSocketMessage*)0);
    }
