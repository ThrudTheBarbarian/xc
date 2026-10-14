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
// WebSocket.xc — WebSocket (RFC 6455) clients and servers over Socket.
//
//     WebSocket* ws = WebSocket.connect(Url.withString("ws://host:7070/path"));
//     ws.sendText(String.withCString("hello"));
//     WebSocketMessage* m = ws.receive(5000);     // up to 5 s; null on none
//     ws.close();                                // or closeWith(code, reason)
//
//     WebSocketServer* s = WebSocketServer.listen(7070);
//     WebSocket* c = s.accept(-1);                // a client, handshake done
//
// Text and binary messages, fragmented or not; ping is answered with pong
// inside `receive`, and a close from the peer is answered and reported by
// `closeCode`. `wss:` goes through the TLS layer Http uses: import HttpTls.xc
// and call HttpTls.install() first, and connect verifies the certificate as
// https does. A server takes plain `ws:` connections; put a TLS-terminating
// proxy in front of it for `wss:`.
//
// Reading blocks only for as long as `receive` is told to; a connection the
// peer closes, or that fails, reads as closed from then on (isOpen).
#import "Foundation.xc"
#import "Error.xc"
#import "Socket.xc"
#import "Http.xc"
#import "Url.xc"
#import "Sha1.xc"
#import "Base64.xc"
#import "RunLoop.xc"

#define _WS_GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
#define _WS_MAX_FRAME 67108864
#define _WS_HEAD_MS 10000

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

// The bytes under the frames: the TCP connection, or the secure layer over it.
class _WsLink
    {
    Socket* _sock;
    HttpSecureConnection* _tls;
    bool waitReadable(i32 ms)
        {
        return _sock.waitReadable(ms);
        }
    // Exactly n bytes, or false (the connection is then closed).
    bool readExact(u8* p, u32 n, i32 ms)
        {
        if (n == (u32)0)
            return true;
        if (_tls == (HttpSecureConnection*)0)
            {
            if (_sock.readExact(p, n, ms))
                return true;
            _sock.close();
            return false;
            }
        u32 got = (u32)0;
        while (got < n)
            {
            i32 r = _tls.read(p + got, n - got);
            if (r <= (i32)0)
                {
                drop();
                return false;
                }
            got = got + (u32)r;
            }
        return true;
        }
    bool write(u8* p, u32 n)
        {
        if (_tls != (HttpSecureConnection*)0)
            return _tls.write(p, n);
        return _sock.write(p, n);
        }
    bool isOpen(void)
        {
        return _sock.isOpen();
        }
    // Closes the connection. (Not `close`: inside the class that name is
    // the host's close(fd).)
    void drop(void)
        {
        if (_tls != (HttpSecureConnection*)0)
            {
            _tls.close();
            _tls = (HttpSecureConnection*)0;
            }
        _sock.close();
        }
    }

u32 _ws_rng_state = (u32)0;

class WebSocket
    {
    _WsLink* _link;
    bool _client;           // a client masks what it sends
    bool _open;
    bool _closeSent;
    u16 _closeCode;
    String* _closeReason;
    String* _path;          // the request's path (a server-side connection)
    Map* _headers;          // the request's (or response's) headers, names lower-cased
    Data* _partial;         // a fragmented message so far
    bool _partialText;
    bool _inFragment;

    void init(void)
        {
        _open = false;
        _closeSent = false;
        _closeCode = (u16)0;
        _inFragment = false;
        _headers = new Map();
        _path = String.withCString("/");
        }

    // ── connecting ───────────────────────────────────────────────────────

    // Open `url` (ws: or wss:) and complete the handshake; throws a
    // WebSocketError naming what went wrong.
    static WebSocket* connect(Url* url) throws
        {
        String* scheme = url.scheme().lowercased();
        bool secure = scheme.equals(String.withCString("wss"));
        if (!secure && !scheme.equals(String.withCString("ws")))
            throw new WebSocketError(String.withFormat("unsupported scheme '%s'", scheme.cString()));
        String* host = url.host();
        if (host == (String*)0 || host.byteLength() == (u32)0)
            throw new WebSocketError(String.withCString("no host in URL"));
        u32 port = url.port();
        if (port == (u32)0)
            port = secure ? (u32)443 : (u32)80;
        if (secure && _http_secure == (HttpSecureLayer*)0)
            throw new WebSocketError(String.withCString("wss: needs the TLS layer: import HttpTls.xc and call HttpTls.install()"));
        Socket* sock = (Socket*)0;
        try
            {
            sock = Socket.connect(host, (u16)port);
            }
        catch (SocketError e)
            {
            throw new WebSocketError(e.message());
            }
        _WsLink* link = new _WsLink();
        link._sock = sock;
        if (secure)
            {
            link._tls = _http_secure.connect(sock.fd(), host);
            if (link._tls == (HttpSecureConnection*)0)
                {
                sock.close();
                throw new WebSocketError(String.withFormat("TLS handshake with %s failed", host.cString()));
                }
            }
        // the key: 16 random bytes, base64
        u8 raw[16];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            raw[i] = (u8)WebSocket._random();
        String* key = Base64.encode(&raw[0], (u32)16);
        String* path = url.path();
        if (path == (String*)0 || path.byteLength() == (u32)0)
            path = String.withCString("/");
        String* query = url.query();
        if (query != (String*)0 && query.byteLength() > (u32)0)
            path = String.withFormat("%s?%s", path.cString(), query.cString());
        String* req = String.withFormat("GET %s HTTP/1.1\r\nHost: %s", path.cString(), host.cString());
        if (url.port() != (u32)0)
            req.append(String.withFormat(":%lu", url.port()));
        req.appendCString("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
        req.append(key);
        req.appendCString("\r\nSec-WebSocket-Version: 13\r\n\r\n");
        if (!link.write(req.cString(), req.byteLength()))
            {
            link.drop();
            throw new WebSocketError(String.withCString("the handshake could not be sent"));
            }
        WebSocket* ws = new WebSocket();
        ws._link = link;
        ws._client = true;
        String* first = ws._readHead(link);
        if (first == (String*)0)
            {
            link.drop();
            throw new WebSocketError(String.withCString("no handshake reply"));
            }
        // "HTTP/1.1 101 Switching Protocols"
        bool is101 = first.byteLength() >= (u32)12 && first.hasPrefix(String.withCString("HTTP/1.1 101"));
        String* accept = ws.header(String.withCString("sec-websocket-accept"));
        if (!is101 || accept == (String*)0 || !accept.equals(WebSocket._acceptFor(key)))
            {
            link.drop();
            throw new WebSocketError(String.withFormat("handshake refused: %s", first.cString()));
            }
        ws._open = true;
        ws._path = path;
        return ws;
        }

    // Sec-WebSocket-Accept for a key: base64(sha1(key + GUID)).
    static String* _acceptFor(String* key)
        {
        String* s = String.withString(key);
        s.appendCString(_WS_GUID);
        Data* h = Sha1.of(s.cString(), s.byteLength());
        return Base64.encodeData(h);
        }

    static u32 _random(void)
        {
        if (_ws_rng_state == (u32)0)
            _ws_rng_state = (u32)_runloop_now_us() | (u32)1;
        u32 x = _ws_rng_state;
        x = x ^ (x << (u32)13);
        x = x ^ (x >> (u32)17);
        x = x ^ (x << (u32)5);
        _ws_rng_state = x;
        return x;
        }

    // The HTTP head of a handshake, a byte at a time up to the blank line:
    // the first line is returned, the headers go into _headers (names
    // lower-cased, values trimmed). Null when it does not arrive whole.
    String* _readHead(_WsLink* link)
        {
        String* head = new String();
        u8 c;
        u32 run = (u32)0;       // the bytes of "\r\n\r\n" matched so far
        while (head.byteLength() < (u32)16384)
            {
            if (!link.readExact(&c, (u32)1, _WS_HEAD_MS))
                return (String*)0;
            head.appendByte(c);
            if ((run == (u32)0 || run == (u32)2) && c == (u8)'\r')
                run = run + (u32)1;
            else if ((run == (u32)1 || run == (u32)3) && c == (u8)'\n')
                run = run + (u32)1;
            else
                run = c == (u8)'\r' ? (u32)1 : (u32)0;
            if (run == (u32)4)
                break;
            }
        if (run != (u32)4)
            return (String*)0;
        // split the lines
        String* first = (String*)0;
        u32 at = (u32)0;
        u32 n = head.byteLength();
        while (at < n)
            {
            u32 end = at;
            while (end < n && head.byteAt(end) != (u8)'\r')
                end = end + (u32)1;
            if (end == at)
                break;                                  // the blank line
            String* line = head.substringBytes(at, end - at);
            if (first == (String*)0)
                first = line;
            else
                {
                u32 colon = (u32)0;
                while (colon < line.byteLength() && line.byteAt(colon) != (u8)':')
                    colon = colon + (u32)1;
                if (colon < line.byteLength())
                    {
                    String* name = line.substringBytes((u32)0, colon).trimmed().lowercased();
                    String* value = line.substringFromByte(colon + (u32)1).trimmed();
                    _headers.set((Hashable*)name, (Object*)value);
                    }
                }
            at = end + (u32)2;                           // past "\r\n"
            }
        return first;
        }

    // ── sending ──────────────────────────────────────────────────────────

    bool sendText(String* s)
        {
        return _send((u8)1, s.cString(), s.byteLength());
        }
    bool sendData(Data* d)
        {
        return _send((u8)2, d.bytes(), d.length());
        }
    bool sendBytes(u8* p, u32 n)
        {
        return _send((u8)2, p, n);
        }
    // A ping; the peer's pong is consumed by receive.
    bool ping(void)
        {
        u8 none[1];
        return _send((u8)9, &none[0], (u32)0);
        }

    // One frame: FIN set, the opcode, the length in its shortest form, and
    // (from a client) a fresh mask applied to the payload.
    bool _send(u8 opcode, u8* p, u32 n)
        {
        if (!_open)
            return false;
        Data* f = new Data();
        f.appendByte((u8)((u8)0x80 | opcode));
        u8 maskBit = _client ? (u8)0x80 : (u8)0;
        if (n < (u32)126)
            f.appendByte((u8)(maskBit | (u8)n));
        else if (n < (u32)65536)
            {
            f.appendByte((u8)(maskBit | (u8)126));
            f.appendByte((u8)(n >> (u32)8));
            f.appendByte((u8)n);
            }
        else
            {
            f.appendByte((u8)(maskBit | (u8)127));
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                f.appendByte((u8)0);
            f.appendByte((u8)(n >> (u32)24));
            f.appendByte((u8)(n >> (u32)16));
            f.appendByte((u8)(n >> (u32)8));
            f.appendByte((u8)n);
            }
        if (_client)
            {
            u32 m = WebSocket._random();
            u8 mask[4];
            mask[0] = (u8)(m >> (u32)24);
            mask[1] = (u8)(m >> (u32)16);
            mask[2] = (u8)(m >> (u32)8);
            mask[3] = (u8)m;
            f.appendBytes(&mask[0], (u32)4);
            u32 at = f.length();
            f.setLength(at + n);
            u8* o = f.bytes();
            for (u32 i = (u32)0; i < n; i = i + (u32)1)
                o[at + i] = p[i] ^ mask[i & (u32)3];
            }
        else
            f.appendBytes(p, n);
        if (_link.write(f.bytes(), f.length()))
            return true;
        _drop();
        return false;
        }

    // ── receiving ────────────────────────────────────────────────────────

    // The next message, waiting up to `ms` milliseconds (-1: for as long as
    // it takes) for one to start; null on none in time, or once the
    // connection is closed (isOpen tells which). Pings are answered and
    // pongs consumed on the way.
    WebSocketMessage* receive(i32 ms)
        {
        if (!_open)
            return (WebSocketMessage*)0;
        i64 deadline = ms < (i32)0 ? (i64)-1 : _runloop_now_us() + (i64)ms * (i64)1000;
        for (;;)
            {
            i32 wait = (i32)-1;
            if (deadline >= (i64)0)
                {
                i64 left = deadline - _runloop_now_us();
                wait = left <= (i64)0 ? (i32)0 : (i32)(left / (i64)1000);
                }
            if (!_link.waitReadable(wait))
                return (WebSocketMessage*)0;
            u8 h[2];
            if (!_link.readExact(&h[0], (u32)2, (i32)5000))
                {
                _drop();
                return (WebSocketMessage*)0;
                }
            bool fin = (h[0] & (u8)0x80) != (u8)0;
            u8 op = h[0] & (u8)0x0f;
            bool masked = (h[1] & (u8)0x80) != (u8)0;
            u64 len = (u64)(h[1] & (u8)0x7f);
            if (len == (u64)126)
                {
                u8 e[2];
                if (!_link.readExact(&e[0], (u32)2, (i32)5000))
                    {
                    _drop();
                    return (WebSocketMessage*)0;
                    }
                len = ((u64)e[0] << (u64)8) | (u64)e[1];
                }
            else if (len == (u64)127)
                {
                u8 e[8];
                if (!_link.readExact(&e[0], (u32)8, (i32)5000))
                    {
                    _drop();
                    return (WebSocketMessage*)0;
                    }
                len = (u64)0;
                for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
                    len = (len << (u64)8) | (u64)e[i];
                }
            if (len > (u64)_WS_MAX_FRAME)
                {
                _abort((u16)1009);
                return (WebSocketMessage*)0;
                }
            u8 mask[4];
            if (masked && !_link.readExact(&mask[0], (u32)4, (i32)5000))
                {
                _drop();
                return (WebSocketMessage*)0;
                }
            Data* payload = Data.withLength((u32)len);
            if (len > (u64)0 && !_link.readExact(payload.bytes(), (u32)len, (i32)30000))
                {
                _drop();
                return (WebSocketMessage*)0;
                }
            if (masked)
                {
                u8* b = payload.bytes();
                for (u32 i = (u32)0; i < (u32)len; i = i + (u32)1)
                    b[i] = b[i] ^ mask[i & (u32)3];
                }
            if (op == (u8)8)
                {
                // the peer's close: its code and reason, our close back, done
                _closeCode = (u16)1005;
                if (payload.length() >= (u32)2)
                    {
                    _closeCode = (u16)(((u16)payload.bytes()[0] << (u16)8) | (u16)payload.bytes()[1]);
                    _closeReason = String.withBytes(payload.bytes() + 2, payload.length() - (u32)2);
                    }
                if (!_closeSent)
                    {
                    _closeSent = true;
                    _send((u8)8, payload.bytes(), payload.length() >= (u32)2 ? (u32)2 : (u32)0);
                    }
                _open = false;
                _link.drop();
                return (WebSocketMessage*)0;
                }
            if (op == (u8)9)
                {
                _send((u8)10, payload.bytes(), payload.length());
                continue;
                }
            if (op == (u8)10)
                continue;
            if (op == (u8)1 || op == (u8)2)
                {
                if (!fin)
                    {
                    _partial = payload;
                    _partialText = op == (u8)1;
                    _inFragment = true;
                    continue;
                    }
                return _message(op == (u8)1, payload);
                }
            if (op == (u8)0)
                {
                if (!_inFragment)
                    {
                    _abort((u16)1002);
                    return (WebSocketMessage*)0;
                    }
                _partial.append(payload);
                if (!fin)
                    continue;
                _inFragment = false;
                return _message(_partialText, _partial);
                }
            _abort((u16)1002);
            return (WebSocketMessage*)0;
            }
        }

    WebSocketMessage* _message(bool text, Data* d)
        {
        WebSocketMessage* m = new WebSocketMessage();
        m._text = text;
        m._data = d;
        return m;
        }

    // ── closing ──────────────────────────────────────────────────────────

    // The closing handshake: our close frame with the code and reason, then
    // up to two seconds for the peer's, then the connection goes.
    void closeWith(u16 code, String* reason)
        {
        if (!_open)
            return;
        if (!_closeSent)
            {
            Data* p = new Data();
            p.appendByte((u8)(code >> (u16)8));
            p.appendByte((u8)code);
            if (reason != (String*)0)
                p.appendBytes(reason.cString(), reason.byteLength());
            _closeSent = true;
            _send((u8)8, p.bytes(), p.length());
            }
        i64 until = _runloop_now_us() + (i64)2000000;
        while (_open && _runloop_now_us() < until)
            receive((i32)200);
        _open = false;
        _link.drop();
        }
    // A normal close (1000) with no reason.
    void close(void)
        {
        closeWith((u16)1000, (String*)0);
        }
    // A protocol failure: close with the code and drop the connection.
    void _abort(u16 code)
        {
        if (_open && !_closeSent)
            {
            u8 p[2];
            p[0] = (u8)(code >> (u16)8);
            p[1] = (u8)code;
            _closeSent = true;
            _send((u8)8, &p[0], (u32)2);
            }
        _closeCode = code;
        _drop();
        }
    void _drop(void)
        {
        if (_closeCode == (u16)0)
            _closeCode = (u16)1006;
        _open = false;
        _link.drop();
        }

    // ── state ────────────────────────────────────────────────────────────

    bool isOpen(void)
        {
        return _open;
        }
    // After a close: the peer's code (1005 when it sent none, 1006 when the
    // connection just went), or ours.
    u16 closeCode(void)
        {
        return _closeCode;
        }
    String* closeReason(void)
        {
        return _closeReason;
        }
    // A server-side connection: the request's path (with its query).
    String* path(void)
        {
        return _path;
        }
    // A header of the handshake (the request's on a server, the reply's on a
    // client), by its name in any case; null when absent.
    String* header(String* name)
        {
        return (String*)_headers.get((Hashable*)name.lowercased());
        }
    void dealloc(void)
        {
        if (_open)
            _link.drop();
        }
    }

// A listening socket that completes the handshake with each client.
class WebSocketServer
    {
    Socket* _listener;

    static WebSocketServer* listen(u16 port) throws
        {
        WebSocketServer* s = new WebSocketServer();
        s._listener = Socket.listen(port);
        return s;
        }

    // The next client, waiting up to `ms` milliseconds (-1: for as long as
    // it takes) for one to connect; null on none, or on a connection that
    // was not a WebSocket handshake (it is answered 400 and closed).
    WebSocket* accept(i32 ms)
        {
        Socket* c = _listener.accept(ms);
        if (c == (Socket*)0)
            return (WebSocket*)0;
        _WsLink* link = new _WsLink();
        link._sock = c;
        WebSocket* ws = new WebSocket();
        ws._link = link;
        ws._client = false;
        String* first = ws._readHead(link);
        String* key = ws.header(String.withCString("sec-websocket-key"));
        String* upgrade = ws.header(String.withCString("upgrade"));
        bool ok = first != (String*)0 && first.hasPrefix(String.withCString("GET ")) && key != (String*)0
                  && upgrade != (String*)0 && upgrade.lowercased().equals(String.withCString("websocket"));
        if (!ok)
            {
            if (first != (String*)0)
                {
                String* no = String.withCString("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
                link.write(no.cString(), no.byteLength());
                }
            link.drop();
            return (WebSocket*)0;
            }
        // "GET /path?query HTTP/1.1"
        u32 end = (u32)4;
        while (end < first.byteLength() && first.byteAt(end) != (u8)' ')
            end = end + (u32)1;
        ws._path = first.substringBytes((u32)4, end - (u32)4);
        String* reply = String.withCString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
        reply.append(WebSocket._acceptFor(key));
        reply.appendCString("\r\n\r\n");
        if (!link.write(reply.cString(), reply.byteLength()))
            {
            link.drop();
            return (WebSocket*)0;
            }
        ws._open = true;
        return ws;
        }

    void close(void)
        {
        _listener.close();
        }
    }
