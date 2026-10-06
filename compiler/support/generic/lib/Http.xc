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

// Http.xc — an HTTP/1.1 client over the host's sockets, and a native
// transport for Url.fetch.
//
//     HttpResponse* r = Http.get(Url.withCString("http://example.com/"));
//     if (r.status() == (u32)200) … r.bodyString() …
//
//     Http.fetch(url, block void(u32 status, String* body) { … });
//
//     Http.install();            // plain url.fetch(…) now uses this transport
//
// `get` blocks the calling thread until the response has arrived (or failed).
// `fetch` runs the same request on a new thread and calls the block ON THAT
// THREAD when it finishes, so the block must not touch state the caller's
// thread is using without a Mutex — unless `Http.deliverOn(RunLoop.main())`
// has been called, which posts every completion to that run loop instead.
// `install` makes this the platform delegate's fetch, which is how
// `url.fetch` reaches it.
//
// One request per connection (`Connection: close`). Redirects (301, 302, 303,
// 307, 308) are followed, up to five. A chunked or Content-Length body is
// decoded. A connection that sends or receives nothing for 30 seconds fails.
//
// https: needs a TLS layer registered with Http.setSecureLayer (the optional
// TLS library provides one); without it an https URL fails with an error
// saying so.
//
// Hosted targets only: arm64 (macOS, iOS, Android), x86_64 (Linux) and win64.

#import "Foundation.xc"

#if ARCH_6502 || ARCH_m68k || ARCH_arm9 || ARCH_wasm32
#error "Http: needs a hosted target with sockets (arm64, android, x86_64 or win64)"
#endif

#import "Thread.xc"
#import "Mutex.xc"
#import "RunLoop.xc"

// ── the host's sockets ──────────────────────────────────────────────────
//
// The C declarations (socket, connect, send, recv, getaddrinfo and the two
// addrinfo layouts) are Socket.xc's.
#import "Socket.xc"

// SOL_SOCKET and the option numbers are per OS. The timeout value is a
// struct timeval on the POSIX hosts (16 bytes; macOS reads a 4-byte usec at
// offset 8, which is zero either way) and a DWORD of milliseconds on Windows.
struct _HttpTimeVal { i64 sec; i64 usec; }

#define _HTTP_TIMEOUT_SECONDS 30

bool _http_winsock_ready = false;

// One TCP connection, plain or wrapped by a secure layer.
class _HttpSocket
    {
    i64 _fd;
    bool _open;
    HttpSecureConnection* _tls;
    String* _error;

    void init(void)
        {
        _fd = (i64)-1;
        _open = false;
        }

    String* error(void)
        {
        return _error;
        }

    bool open(String* host, u32 port)
        {
#if ARCH_win64
        if (!_http_winsock_ready)
            {
            u8 wsa[512];
            if (WSAStartup((u16)0x0202, wsa) != (i32)0)
                {
                _error = String.withCString("Winsock would not start");
                return false;
                }
            _http_winsock_ready = true;
            }
#endif
        _HttpAddr hints;
        hints.flags = (i32)0;
        hints.family = (i32)0;          // AF_UNSPEC: IPv4 or IPv6
        hints.socktype = (i32)1;        // SOCK_STREAM
        hints.proto = (i32)0;
        hints.addrlen = (u32)0;
        hints._pad = (u32)0;
        hints.canon = (u8*)0;
        hints.addr = (u8*)0;
        hints.next = (_HttpAddr*)0;
        _HttpAddr* res = (_HttpAddr*)0;
        String* service = String.withFormat("%lu", port);
        if (getaddrinfo(host.cString(), service.cString(), &hints, &res) != (i32)0 || res == (_HttpAddr*)0)
            {
            _error = String.withFormat("cannot resolve host '%s'", host.cString());
            return false;
            }
        bool ok = false;
        for (_HttpAddr* a = res; a != (_HttpAddr*)0 && !ok; a = a.next)
            {
#if ARCH_win64
            u64 s = socket(a.family, a.socktype, a.proto);
            if (s == (u64)0xFFFFFFFFFFFFFFFF)
                continue;
            if (connect(s, a.addr, (i32)a.addrlen) == (i32)0)
                {
                _fd = (i64)s;
                ok = true;
                }
            else
                closesocket(s);
#else
            i32 s = socket(a.family, a.socktype, a.proto);
            if (s < (i32)0)
                continue;
            if (connect(s, a.addr, a.addrlen) == (i32)0)
                {
                _fd = (i64)s;
                ok = true;
                }
            else
                close(s);
#endif
            }
        freeaddrinfo(res);
        if (!ok)
            {
            _error = String.withFormat("cannot connect to %s:%lu", host.cString(), port);
            return false;
            }
        _open = true;
        _setOptions();
        return true;
        }

    void _setOptions(void)
        {
#if ARCH_win64
        u32 ms = (u32)_HTTP_TIMEOUT_SECONDS * (u32)1000;
        setsockopt((u64)_fd, (i32)0xFFFF, (i32)0x1006, (u8*)&ms, (i32)4);
        setsockopt((u64)_fd, (i32)0xFFFF, (i32)0x1005, (u8*)&ms, (i32)4);
#else
        _HttpTimeVal tv;
        tv.sec = (i64)_HTTP_TIMEOUT_SECONDS;
        tv.usec = (i64)0;
#if ARCH_x86_64 || PLATFORM_android
        setsockopt((i32)_fd, (i32)1, (i32)20, (u8*)&tv, (u32)16);    // SO_RCVTIMEO
        setsockopt((i32)_fd, (i32)1, (i32)21, (u8*)&tv, (u32)16);    // SO_SNDTIMEO
#else
        setsockopt((i32)_fd, (i32)0xFFFF, (i32)0x1006, (u8*)&tv, (u32)16);
        setsockopt((i32)_fd, (i32)0xFFFF, (i32)0x1005, (u8*)&tv, (u32)16);
        // A peer that closes early must fail the send, not kill the process.
        i32 one = (i32)1;
        setsockopt((i32)_fd, (i32)0xFFFF, (i32)0x1022, (u8*)&one, (u32)4);  // SO_NOSIGPIPE
#endif
#endif
        }

    // Wrap the open connection in a secure layer; false (with the error) if
    // the handshake fails.
    bool startSecure(HttpSecureLayer* layer, String* host)
        {
        _tls = layer.connect(_fd, host);
        if (_tls == (HttpSecureConnection*)0)
            {
            _error = String.withFormat("TLS handshake with %s failed", host.cString());
            return false;
            }
        return true;
        }

    // Send every byte, or fail.
    bool sendAll(u8* p, u32 n)
        {
        if (_tls != (HttpSecureConnection*)0)
            return _tls.write(p, n);
        u32 done = (u32)0;
        while (done < n)
            {
#if ARCH_win64
            i32 put = send((u64)_fd, p + done, (i32)(n - done), (i32)0);
            if (put <= (i32)0)
                return false;
            done = done + (u32)put;
#elif ARCH_x86_64 || PLATFORM_android
            i64 put = send((i32)_fd, p + done, (u64)(n - done), (i32)0x4000);   // MSG_NOSIGNAL
            if (put <= (i64)0)
                return false;
            done = done + (u32)put;
#else
            i64 put = send((i32)_fd, p + done, (u64)(n - done), (i32)0);
            if (put <= (i64)0)
                return false;
            done = done + (u32)put;
#endif
            }
        return true;
        }

    // Up to `n` bytes: the count, 0 at the end of the stream, negative on an
    // error or a timeout.
    i32 receive(u8* p, u32 n)
        {
        if (_tls != (HttpSecureConnection*)0)
            return _tls.read(p, n);
#if ARCH_win64
        return recv((u64)_fd, p, (i32)n, (i32)0);
#else
        return (i32)recv((i32)_fd, p, (u64)n, (i32)0);
#endif
        }

    void disconnect(void)
        {
        if (!_open)
            return;
        if (_tls != (HttpSecureConnection*)0)
            {
            _tls.close();
            _tls = (HttpSecureConnection*)0;
            }
#if ARCH_win64
        closesocket((u64)_fd);
#else
        close((i32)_fd);
#endif
        _open = false;
        _fd = (i64)-1;
        }

    void dealloc(void)
        {
        disconnect();
        }
    }

// ── the secure layer seam ───────────────────────────────────────────────
//
// Http does no cryptography. A TLS library adapts itself to these two
// protocols and registers with Http.setSecureLayer; `connect` takes an open,
// connected socket and the host name to verify, and returns null when the
// handshake (or the certificate check) fails.

protocol HttpSecureConnection
    {
    bool write(u8* p, u32 n);
    i32 read(u8* p, u32 n);
    void close(void);
    }

protocol HttpSecureLayer
    {
    HttpSecureConnection* connect(i64 fd, String* host);
    }

// ── the response ────────────────────────────────────────────────────────

class HttpResponse
    {
    u32 _status;
    String* _error;
    Map* _headers;
    Data* _body;
    Url* _url;

    void init(void)
        {
        _status = (u32)0;
        _headers = new Map();
        _body = new Data();
        }

    static HttpResponse* failure(Url* url, String* why)
        {
        HttpResponse* r = new HttpResponse();
        r._url = url;
        r._error = why;
        return r;
        }

    // The HTTP status, or 0 when there was no response (see error()).
    u32 status(void)
        {
        return _status;
        }

    // Why there is no response, or null when there is one.
    String* error(void)
        {
        return _error;
        }

    // The URL that answered, after any redirects.
    Url* url(void)
        {
        return _url;
        }

    Data* body(void)
        {
        return _body;
        }

    String* bodyString(void)
        {
        return _body.stringValue();
        }

    // A response header by name, any case; null when absent. A header sent
    // more than once reads as its values joined by ", ".
    String* header(String* name)
        {
        return (String*)_headers.get((Hashable*)name.lowercased());
        }

    Map* headers(void)
        {
        return _headers;
        }
    }

// ── the client ──────────────────────────────────────────────────────────

// Process-wide state: the registered secure layer, and the jobs running on
// their own threads (see Http._start).
HttpSecureLayer* _http_secure = (HttpSecureLayer*)0;
Mutex* _http_jobs_lock = (Mutex*)0;
Array* _http_jobs = (Array*)0;
RunLoop* _http_deliver = (RunLoop*)0;

class Http
    {
    static void setSecureLayer(HttpSecureLayer* layer)
        {
        _http_secure = layer;
        }

    // Run every completion (from fetch, and url.fetch after install) on
    // `loop`'s thread instead of the request's own; 0 goes back to the
    // request's thread. Set it before starting requests.
    static void deliverOn(RunLoop* loop)
        {
        _http_deliver = loop;
        }

    // GET `url`, following redirects; blocks until it has an answer.
    static HttpResponse* get(Url* url)
        {
        Url* cur = url;
        for (u32 hop = (u32)0; hop <= (u32)5; hop = hop + (u32)1)
            {
            HttpResponse* r = Http._once(cur);
            u32 s = r.status();
            if (s != (u32)301 && s != (u32)302 && s != (u32)303 && s != (u32)307 && s != (u32)308)
                return r;
            String* loc = r.header(String.withCString("Location"));
            if (loc == (String*)0)
                return r;
            cur = Http._resolve(cur, loc);
            }
        return HttpResponse.failure(url, String.withCString("too many redirects"));
        }

    // GET `url` on a new thread and call `cb` on that thread with the status
    // (0 on failure) and the body (null on failure).
    static void fetch(Url* url, block cb void(u32, String*))
        {
        _HttpJob* job = new _HttpJob();
        job.url = url;
        job.cb = cb;
        Http._start(job);
        }

    // Make this the transport behind `url.fetch(…)`: installs a platform
    // delegate whose fetch runs here. Replaces any delegate already set.
    static void install(void)
        {
        Platform.setDelegate(new _HttpDelegate());
        }

    // ── internals ────────────────────────────────────────────────────────

    // A job must outlive its thread (a thread body's receiver is not
    // retained), so each running job is held here and swept once finished.
    static void _start(_HttpJob* job)
        {
        if (_http_jobs_lock == (Mutex*)0)
            {
            _http_jobs_lock = new Mutex();
            _http_jobs = new Array();
            }
        _http_jobs_lock.lock();
        Array* keep = new Array();
        for (u32 i = (u32)0; i < _http_jobs.count(); i = i + (u32)1)
            {
            _HttpJob* j = (_HttpJob*)_http_jobs.get(i);
            if (!j.done)
                keep.add((Object*)j);
            }
        keep.add((Object*)job);
        _http_jobs = keep;
        _http_jobs_lock.unlock();
        Thread* t = Thread.spawn(&job.run);
        t.detach();
        }

    static void _finished(_HttpJob* job)
        {
        _http_jobs_lock.lock();
        job.done = true;
        _http_jobs_lock.unlock();
        }

    static HttpResponse* _once(Url* url)
        {
        String* scheme = url.scheme().lowercased();
        bool secure = scheme.equals(String.withCString("https"));
        if (!secure && !scheme.equals(String.withCString("http")))
            return HttpResponse.failure(url, String.withFormat("unsupported scheme '%s'", scheme.cString()));
        if (secure && _http_secure == (HttpSecureLayer*)0)
            return HttpResponse.failure(url, String.withCString("https needs a TLS layer (Http.setSecureLayer)"));
        String* host = url.host();
        if (host.byteLength() == (u32)0)
            return HttpResponse.failure(url, String.withCString("no host in URL"));
        u32 port = url.port();
        if (port == (u32)0)
            port = secure ? (u32)443 : (u32)80;

        _HttpSocket* sock = new _HttpSocket();
        if (!sock.open(host, port))
            return HttpResponse.failure(url, sock.error());
        if (secure && !sock.startSecure(_http_secure, host))
            {
            String* why = sock.error();
            sock.disconnect();
            return HttpResponse.failure(url, why);
            }

        String* req = String.withCString("GET ");
        req.append(url.path());
        String* q = url.query();
        if (q.byteLength() > (u32)0)
            {
            req.appendCString("?");
            req.append(q);
            }
        req.appendCString(" HTTP/1.1\r\nHost: ");
        req.append(host);
        if (url.port() != (u32)0)
            req.append(String.withFormat(":%lu", url.port()));
        req.appendCString("\r\nUser-Agent: xcc-http\r\nAccept: */*\r\nConnection: close\r\n\r\n");
        if (!sock.sendAll(req.cString(), req.byteLength()))
            {
            sock.disconnect();
            return HttpResponse.failure(url, String.withCString("send failed"));
            }

        Data* raw = new Data();
        u8 buf[8192];
        bool failed = false;
        while (true)
            {
            i32 got = sock.receive(buf, (u32)8192);
            if (got == (i32)0)
                break;
            if (got < (i32)0)
                {
                failed = true;
                break;
                }
            raw.appendBytes(buf, (u32)got);
            }
        sock.disconnect();
        HttpResponse* r = Http._parse(url, raw);
        if (failed && r.status() == (u32)0 && r.error() == (String*)0)
            r._error = String.withCString("receive failed or timed out");
        return r;
        }

    // The status line, the headers, then the body: chunked, Content-Length,
    // or everything to the end of the stream.
    static HttpResponse* _parse(Url* url, Data* raw)
        {
        u8* b = raw.bytes();
        u32 n = raw.length();
        u32 end = (u32)0xFFFFFFFF;
        for (u32 i = (u32)0; i + (u32)3 < n; i = i + (u32)1)
            if (b[i] == (u8)13 && b[i + (u32)1] == (u8)10 && b[i + (u32)2] == (u8)13 && b[i + (u32)3] == (u8)10)
                {
                end = i;
                break;
                }
        if (end == (u32)0xFFFFFFFF)
            return HttpResponse.failure(url, String.withCString("malformed response (no end of headers)"));

        HttpResponse* r = new HttpResponse();
        r._url = url;
        String* head = String.withBytes(b, end);
        // Lines end in CR LF; splitting on LF leaves the CR, which trimmed() drops.
        Array* lines = head.splitOnByte((u8)10);
        String* status = ((String*)lines.get((u32)0)).trimmed();
        if (!status.hasPrefix(String.withCString("HTTP/")))
            return HttpResponse.failure(url, String.withCString("malformed response (no status line)"));
        u32 sp = status.indexOfByte((u8)' ');
        u32 code = (u32)0;
        if (sp != String.notFound())
            for (u32 i = sp + (u32)1; i < status.byteLength() && i < sp + (u32)4; i = i + (u32)1)
                {
                u8 c = status.byteAt(i);
                if (c < (u8)'0' || c > (u8)'9')
                    break;
                code = code * (u32)10 + (u32)(c - (u8)'0');
                }
        r._status = code;
        for (u32 li = (u32)1; li < lines.count(); li = li + (u32)1)
            {
            String* line = (String*)lines.get(li);
            u32 colon = line.indexOfByte((u8)':');
            if (colon == String.notFound())
                continue;
            String* name = line.substringBytes((u32)0, colon).trimmed().lowercased();
            String* value = line.substringBytes(colon + (u32)1, line.byteLength() - colon - (u32)1).trimmed();
            String* prev = (String*)r._headers.get((Hashable*)name);
            if (prev != (String*)0)
                {
                String* joined = String.withString(prev);
                joined.appendCString(", ");
                joined.append(value);
                value = joined;
                }
            r._headers.set((Hashable*)name, (Object*)value);
            }

        u32 bodyAt = end + (u32)4;
        String* te = r.header(String.withCString("Transfer-Encoding"));
        if (te != (String*)0 && te.lowercased().contains(String.withCString("chunked")))
            {
            if (!Http._dechunk(b, bodyAt, n, r._body))
                r._error = String.withCString("malformed chunked body");
            return r;
            }
        u32 len = n - bodyAt;
        String* cl = r.header(String.withCString("Content-Length"));
        if (cl != (String*)0)
            {
            u32 want = (u32)0;
            for (u32 i = (u32)0; i < cl.byteLength(); i = i + (u32)1)
                {
                u8 c = cl.byteAt(i);
                if (c < (u8)'0' || c > (u8)'9')
                    break;
                want = want * (u32)10 + (u32)(c - (u8)'0');
                }
            if (want < len)
                len = want;
            }
        r._body.appendBytes(b + bodyAt, len);
        return r;
        }

    // `<hex size>[;ext]\r\n<bytes>\r\n` … `0\r\n`.
    static bool _dechunk(u8* b, u32 at, u32 n, Data* out)
        {
        u32 i = at;
        while (i < n)
            {
            u32 size = (u32)0;
            bool digits = false;
            while (i < n)
                {
                u8 c = b[i];
                u32 v = (u32)16;
                if (c >= (u8)'0' && c <= (u8)'9') v = (u32)(c - (u8)'0');
                else if (c >= (u8)'a' && c <= (u8)'f') v = (u32)(c - (u8)'a') + (u32)10;
                else if (c >= (u8)'A' && c <= (u8)'F') v = (u32)(c - (u8)'A') + (u32)10;
                if (v == (u32)16)
                    break;
                size = size * (u32)16 + v;
                digits = true;
                i = i + (u32)1;
                }
            if (!digits)
                return false;
            while (i + (u32)1 < n && !(b[i] == (u8)13 && b[i + (u32)1] == (u8)10))
                i = i + (u32)1;
            i = i + (u32)2;
            if (size == (u32)0)
                return true;
            if (i + size > n)
                return false;
            out.appendBytes(b + i, size);
            i = i + size + (u32)2;
            }
        return false;
        }

    // A Location header against the URL that sent it: absolute, host-
    // relative (`/x`) or path-relative (`x`).
    static Url* _resolve(Url* base, String* loc)
        {
        String* l = loc.lowercased();
        if (l.hasPrefix(String.withCString("http://")) || l.hasPrefix(String.withCString("https://")))
            return Url.withString(loc);
        String* s = String.withString(base.scheme());
        s.appendCString("://");
        s.append(base.host());
        if (base.port() != (u32)0)
            s.append(String.withFormat(":%lu", base.port()));
        if (loc.hasPrefix(String.withCString("/")))
            {
            s.append(loc);
            return Url.withString(s);
            }
        String* p = base.path();
        u32 slash = (u32)0;
        for (u32 i = (u32)0; i < p.byteLength(); i = i + (u32)1)
            if (p.byteAt(i) == (u8)'/')
                slash = i;
        s.append(p.substringBytes((u32)0, slash + (u32)1));
        s.append(loc);
        return Url.withString(s);
        }
    }

// A request running on its own thread.
class _HttpJob
    {
    Url* url;
    block cb void(u32, String*);
    bool done;

    void run(void)
        {
        HttpResponse* r = Http.get(url);
        u32 status = r.status();
        String* body = status == (u32)0 ? (String*)0 : r.bodyString();
        if (_http_deliver != (RunLoop*)0)
            {
            block done void(u32, String*) = cb;
            _http_deliver.post(block void(void) { done(status, body); });
            }
        else
            cb(status, body);
        Http._finished(self);
        }
    }

// The platform delegate `Http.install` sets: url.fetch lands in startFetch,
// which claims the request from Url on the CALLING thread (so Url's list of
// pending fetches is never touched by a worker) and runs it on a new one.
class _HttpDelegate<PlatformDelegate>
    {
    void inject(String* sel, String* html)
        {
        }

    void pushState(String* url)
        {
        }

    void startFetch(u32 token, Url* url)
        {
        FetchReq* req = Url.take(token);
        if (req == (FetchReq*)0)
            return;
        _HttpJob* job = new _HttpJob();
        job.url = url;
        job.cb = req.cb;
        Http._start(job);
        }
    }
