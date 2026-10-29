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
// Socket.xc — a TCP connection, the same calls on every hosted target.
// ===========================================================================
//
//     try
//         {
//         Socket* s = Socket.connect(String.withCString("localhost"), (u16)7070);
//         s.writeString(String.withCString("hello\n"));
//         s.waitReadable((i32)1000);          // up to a second for a reply
//         Data* reply = s.readAvailable((u32)4096);
//         s.close();
//         }
//     catch (SocketError e) { … e.message() says why }
//
// It hides what differs between the hosts: Winsock's start-up, SOCKET and
// closesocket on Windows, the two addrinfo layouts, SIGPIPE from a peer that
// went away. The address comes from getaddrinfo, IPv4 or IPv6.
//
// Reading never blocks: read and readAvailable return what has arrived, so a
// client can poll from a timer and the run loop keeps turning; waitReadable
// blocks for as long as the caller chooses. A connection that fails or that
// the peer closes is closed here, and reads then report it.
//
// Http.xc speaks HTTP over the same declarations.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// arm64 (macOS, iOS, Android), x86_64 and win64 have TCP. On wasm32, arm9 and
// m68k this file compiles, so a program can import it everywhere, and
// connect throws "no TCP sockets on this platform". Not on xt6502.

#if ARCH_6502
#error "Socket: not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"

#if ARCH_wasm32 || ARCH_arm9 || ARCH_m68k
#define _SOCKET_NO_TCP 1
#endif

// ── The host's sockets ──────────────────────────────────────────────────
//
// Three families of declaration. Windows: Winsock, a SOCKET is 64 bits and
// lengths are int. Linux (x86_64): glibc/musl, whose addrinfo puts ai_addr
// BEFORE ai_canonname. Everything else here (macOS, iOS, Android): BSD, whose
// addrinfo puts ai_canonname first. The two addrinfo shapes differ only in
// that order; Windows's size_t ai_addrlen fills the padding the others have.

#if !_SOCKET_NO_TCP
#if OS_windows
struct _HttpAddr { i32 flags; i32 family; i32 socktype; i32 proto; u32 addrlen; u32 _pad; u8* canon; u8* addr; _HttpAddr* next; }
i32 WSAStartup(u16 version, u8* data);
u64 socket(i32 domain, i32 type, i32 proto);
i32 connect(u64 s, u8* addr, i32 len);
i32 send(u64 s, u8* buf, i32 len, i32 flags);
i32 recv(u64 s, u8* buf, i32 len, i32 flags);
i32 setsockopt(u64 s, i32 level, i32 name, u8* value, i32 len);
i32 closesocket(u64 s);
struct _SocketPoll { u64 fd; i16 events; i16 revents; i32 _pad; }
i32 WSAPoll(pointer fds, u32 n, i32 timeout);
#define _SOCKET_POLLIN 0x0100
#define _SOCKET_POLLGONE 0x0003
#elif ARCH_x86_64
struct _HttpAddr { i32 flags; i32 family; i32 socktype; i32 proto; u32 addrlen; u32 _pad; u8* addr; u8* canon; _HttpAddr* next; }
i32 socket(i32 domain, i32 type, i32 proto);
i32 connect(i32 fd, u8* addr, u32 len);
i64 send(i32 fd, u8* buf, u64 len, i32 flags);
i64 recv(i32 fd, u8* buf, u64 len, i32 flags);
i32 setsockopt(i32 fd, i32 level, i32 name, u8* value, u32 len);
i32 close(i32 fd);
struct _SocketPoll { i32 fd; i16 events; i16 revents; }
i32 poll(pointer fds, u64 n, i32 timeout);
#define _SOCKET_POLLIN 0x0001
#define _SOCKET_POLLGONE 0x0018
#else
struct _HttpAddr { i32 flags; i32 family; i32 socktype; i32 proto; u32 addrlen; u32 _pad; u8* canon; u8* addr; _HttpAddr* next; }
i32 socket(i32 domain, i32 type, i32 proto);
i32 connect(i32 fd, u8* addr, u32 len);
i64 send(i32 fd, u8* buf, u64 len, i32 flags);
i64 recv(i32 fd, u8* buf, u64 len, i32 flags);
i32 setsockopt(i32 fd, i32 level, i32 name, u8* value, u32 len);
i32 close(i32 fd);
struct _SocketPoll { i32 fd; i16 events; i16 revents; }
i32 poll(pointer fds, u32 n, i32 timeout);
#define _SOCKET_POLLIN 0x0001
#define _SOCKET_POLLGONE 0x0018
#endif

i32 getaddrinfo(u8* node, u8* service, _HttpAddr* hints, _HttpAddr** res);
void freeaddrinfo(_HttpAddr* res);
// A connect with a time limit: the socket non-blocking for the connect, the
// wait a poll for writable, the outcome SO_ERROR (Socket.connectWithin).
#if OS_windows
i32 ioctlsocket(u64 s, i32 cmd, u32* arg);
i32 getsockopt(u64 s, i32 level, i32 name, u8* value, i32* len);
#define _SOCKET_POLLOUT 0x0010
#elif ARCH_x86_64 || OS_android
i32 fcntl(i32 fd, i32 cmd, ...);
i32 getsockopt(i32 fd, i32 level, i32 name, u8* value, u32* len);
#define _SOCKET_O_NONBLOCK 0x800
#define _SOCKET_SOL 1
#define _SOCKET_SO_ERROR 4
#define _SOCKET_POLLOUT 0x0004
#else
// Variadic in C, and on Darwin arm64 a variadic argument goes on the stack:
// declared with fixed arguments, fcntl never saw the flags.
i32 fcntl(i32 fd, i32 cmd, ...);
i32 getsockopt(i32 fd, i32 level, i32 name, u8* value, u32* len);
#define _SOCKET_O_NONBLOCK 0x4
#define _SOCKET_SOL 0xFFFF
#define _SOCKET_SO_ERROR 0x1007
#define _SOCKET_POLLOUT 0x0004
#endif
// The server side: bind, listen, accept (Socket.listen / accept below).
#if OS_windows
i32 bind(u64 s, u8* addr, i32 len);
i32 listen(u64 s, i32 backlog);
u64 accept(u64 s, u8* addr, i32* len);
#else
i32 bind(i32 fd, u8* addr, u32 len);
i32 listen(i32 fd, i32 backlog);
i32 accept(i32 fd, u8* addr, u32* len);
#endif

bool _socket_winsock_ready = false;

// Winsock's start-up, once (true on the other hosts).
bool _socket_startup(void)
    {
#if OS_windows
    if (!_socket_winsock_ready)
        {
        u8 wsa[512];
        if (WSAStartup((u16)0x0202, wsa) != (i32)0)
            return false;
        _socket_winsock_ready = true;
        }
#endif
    return true;
    }

// C's connect, by another name: inside Socket the bare name is its own.
bool _socket_connectFd(i64 fd, u8* addr, u32 len)
    {
#if OS_windows
    return connect((u64)fd, addr, (i32)len) == (i32)0;
#else
    return connect((i32)fd, addr, len) == (i32)0;
#endif
    }

// C's close, by another name: inside Socket the bare name is its own close().
void _socket_closeFd(i64 fd)
    {
#if OS_windows
    closesocket((u64)fd);
#else
    close((i32)fd);
#endif
    }
#endif

class SocketError <Error>
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

class Socket
    {
    i64 _fd;
    bool _open;

    void init(void)
        {
        _fd = (i64)-1;
        _open = false;
        }

    // A connection to host:port (a name or a numeric address, IPv4 or IPv6),
    // blocking until it is made or refused. Throws a SocketError saying why
    // when it cannot be.
    static Socket* connect(String* host, u16 port) throws
        {
        return Socket.connectWithin(host, port, (i32)-1);
        }

    // As connect, giving up after `ms` milliseconds (-1: the system's own
    // limit, which can be minutes): a host that silently drops the packets
    // (a firewall) would otherwise hold the caller that long.
    static Socket* connectWithin(String* host, u16 port, i32 ms) throws
        {
#if _SOCKET_NO_TCP
        throw new SocketError(String.withCString("no TCP sockets on this platform"));
        return (Socket*)0;
#else
        if (host == 0)
            throw new SocketError(String.withCString("no host"));
        if (!_socket_startup())
            throw new SocketError(String.withCString("Winsock would not start"));
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
        String* service = String.withU32((u32)port);
        if (getaddrinfo(host.cString(), service.cString(), &hints, &res) != (i32)0 || res == (_HttpAddr*)0)
            {
            String* m = String.withCString("cannot resolve the host '");
            m.append(host);
            m.appendCString("'");
            throw new SocketError(m);
            }
        Socket* s = (Socket*)0;
        for (_HttpAddr* a = res; a != (_HttpAddr*)0 && s == 0; a = a.next)
            {
#if OS_windows
            u64 h = socket(a.family, a.socktype, a.proto);
            if (h == (u64)0xFFFFFFFFFFFFFFFF)
                continue;
            if (Socket._connectOne((i64)h, a.addr, a.addrlen, ms))
                {
                s = new Socket();
                s._fd = (i64)h;
                }
            else
                closesocket(h);
#else
            i32 h = socket(a.family, a.socktype, a.proto);
            if (h < (i32)0)
                continue;
            if (Socket._connectOne((i64)h, a.addr, a.addrlen, ms))
                {
                s = new Socket();
                s._fd = (i64)h;
                }
            else
                _socket_closeFd((i64)h);
#endif
            }
        freeaddrinfo(res);
        if (s == 0)
            {
            String* m = String.withCString("cannot connect to ");
            m.append(host);
            m.appendCString(":");
            m.append(service);
            throw new SocketError(m);
            }
        s._open = true;
#if !OS_windows && !ARCH_x86_64 && !OS_android
        // A peer that closes early must fail the write, not kill the process.
        i32 one = (i32)1;
        setsockopt((i32)s._fd, (i32)0xFFFF, (i32)0x1022, (u8*)&one, (u32)4);  // SO_NOSIGPIPE
#endif
        return s;
#endif
        }

    bool isOpen(void)
        {
        return _open;
        }

#if !_SOCKET_NO_TCP
    // One address: connected (true), or not within `ms` (-1: blocking, as
    // the system does it). The socket is left blocking either way.
    static bool _connectOne(i64 h, u8* addr, u32 len, i32 ms)
        {
#if OS_windows
        if (ms < (i32)0)
            return _socket_connectFd(h, addr, len);
        u32 on = (u32)1;
        ioctlsocket((u64)h, (i32)0x8004667E, &on);          // FIONBIO
        bool ok = _socket_connectFd(h, addr, len);
        if (!ok)
            {
            _SocketPoll p;
            p.fd = (u64)h;
            p._pad = (i32)0;
            p.events = (i16)_SOCKET_POLLOUT;
            p.revents = (i16)0;
            if (WSAPoll((pointer)&p, (u32)1, ms) > (i32)0 && ((i32)p.revents & (i32)_SOCKET_POLLOUT) != (i32)0)
                {
                i32 err = (i32)0;
                i32 el = (i32)4;
                getsockopt((u64)h, (i32)0xFFFF, (i32)0x1007, (u8*)&err, &el);   // SOL_SOCKET, SO_ERROR
                ok = err == (i32)0;
                }
            }
        u32 off = (u32)0;
        ioctlsocket((u64)h, (i32)0x8004667E, &off);
        return ok;
#else
        if (ms < (i32)0)
            return _socket_connectFd(h, addr, len);
        i32 fl = fcntl((i32)h, (i32)3, (i32)0);              // F_GETFL
        fcntl((i32)h, (i32)4, fl | (i32)_SOCKET_O_NONBLOCK); // F_SETFL
        bool ok = _socket_connectFd(h, addr, len);
        if (!ok)
            {
            _SocketPoll p;
            p.fd = (i32)h;
            p.events = (i16)_SOCKET_POLLOUT;
            p.revents = (i16)0;
#if ARCH_x86_64
            i32 r = poll((pointer)&p, (u64)1, ms);
#else
            i32 r = poll((pointer)&p, (u32)1, ms);
#endif
            if (r > (i32)0 && ((i32)p.revents & (i32)_SOCKET_POLLOUT) != (i32)0)
                {
                i32 err = (i32)0;
                u32 el = (u32)4;
                getsockopt((i32)h, (i32)_SOCKET_SOL, (i32)_SOCKET_SO_ERROR, (u8*)&err, &el);
                ok = err == (i32)0;
                }
            }
        fcntl((i32)h, (i32)4, fl);
        return ok;
#endif
        }
#endif

    // TCP_NODELAY: a write leaves at once instead of waiting until the last
    // one is acknowledged. For a request/answer protocol of small frames:
    // against the peer's delayed acknowledgement that wait is ~40 ms a
    // round trip on Linux.
    void setNoDelay(void)
        {
#if !_SOCKET_NO_TCP
        if (!_open)
            return;
        i32 one = (i32)1;
#if OS_windows
        setsockopt((u64)_fd, (i32)6, (i32)1, (u8*)&one, (i32)4);    // IPPROTO_TCP, TCP_NODELAY
#else
        setsockopt((i32)_fd, (i32)6, (i32)1, (u8*)&one, (u32)4);    // IPPROTO_TCP, TCP_NODELAY
#endif
#endif
        }
    // The host's descriptor (a SOCKET on Windows), for a layer over the
    // connection such as TLS; -1 when closed.
    i64 fd(void)
        {
        return _fd;
        }

    // ── Serving ──────────────────────────────────────────────────────────

    // A listening socket on every IPv4 address, port `port` (the address is
    // reusable at once, so a restarted server binds again). Throws a
    // SocketError saying why when it cannot be. accept() takes connections.
    static Socket* listen(u16 port) throws
        {
#if _SOCKET_NO_TCP
        throw new SocketError(String.withCString("no TCP sockets on this platform"));
        return (Socket*)0;
#else
        if (!_socket_startup())
            throw new SocketError(String.withCString("Winsock would not start"));
        // sockaddr_in: 16 bytes. BSD puts a length byte first; Linux and
        // Windows a 16-bit family. AF_INET is 2, the port is big-endian.
        u8 sa[16];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            sa[i] = (u8)0;
#if OS_windows || ARCH_x86_64 || OS_android
        sa[0] = (u8)2;
#else
        sa[0] = (u8)16;
        sa[1] = (u8)2;
#endif
        sa[2] = (u8)(port >> (u16)8);
        sa[3] = (u8)(port & (u16)255);
        i32 one = (i32)1;
#if OS_windows
        u64 h = socket((i32)2, (i32)1, (i32)0);
        if (h == (u64)0xFFFFFFFFFFFFFFFF)
            throw new SocketError(String.withCString("cannot make a socket"));
        // SO_EXCLUSIVEADDRUSE, not SO_REUSEADDR: on Windows the latter lets a
        // SECOND process bind the same port while a listener holds it, and
        // connections then reach either server (two sweeps running the
        // websocket fixture at once shared one port). Exclusive use is what
        // SO_REUSEADDR means on every other platform, and a port whose last
        // connection is in TIME_WAIT can still be bound.
        i32 exclusive = (i32)1;
        setsockopt(h, (i32)0xFFFF, (i32)0 - (i32)5, (u8*)&exclusive, (i32)4);   // SO_EXCLUSIVEADDRUSE (~SO_REUSEADDR)
        if (bind(h, &sa[0], (i32)16) != (i32)0 || listen(h, (i32)16) != (i32)0)
            {
            closesocket(h);
            throw new SocketError(String.withCString("cannot listen on the port"));
            }
        i64 fd = (i64)h;
#else
        i32 h = socket((i32)2, (i32)1, (i32)0);
        if (h < (i32)0)
            throw new SocketError(String.withCString("cannot make a socket"));
#if ARCH_x86_64 || OS_android
        setsockopt(h, (i32)1, (i32)2, (u8*)&one, (u32)4);                    // SOL_SOCKET, SO_REUSEADDR
#else
        setsockopt(h, (i32)0xFFFF, (i32)4, (u8*)&one, (u32)4);
#endif
        if (bind(h, &sa[0], (u32)16) != (i32)0 || listen(h, (i32)16) != (i32)0)
            {
            _socket_closeFd((i64)h);
            throw new SocketError(String.withCString("cannot listen on the port"));
            }
        i64 fd = (i64)h;
#endif
        Socket* s = new Socket();
        s._fd = fd;
        s._open = true;
        return s;
#endif
        }

    // The next connection to a listening socket, waiting up to `ms` for one
    // (-1: as long as it takes); null when none came in time, or on failure.
    Socket* accept(i32 ms)
        {
#if _SOCKET_NO_TCP
        return (Socket*)0;
#else
        if (!_open || !waitReadable(ms))
            return (Socket*)0;
        u8 sa[128];
#if OS_windows
        i32 len = (i32)128;
        u64 h = accept((u64)_fd, &sa[0], &len);
        if (h == (u64)0xFFFFFFFFFFFFFFFF)
            return (Socket*)0;
        i64 fd = (i64)h;
#else
        u32 len = (u32)128;
        i32 h = accept((i32)_fd, &sa[0], &len);
        if (h < (i32)0)
            return (Socket*)0;
        i64 fd = (i64)h;
#endif
        Socket* s = new Socket();
        s._fd = fd;
        s._open = true;
#if !OS_windows && !ARCH_x86_64 && !OS_android
        i32 one = (i32)1;
        setsockopt((i32)fd, (i32)0xFFFF, (i32)0x1022, (u8*)&one, (u32)4);  // SO_NOSIGPIPE
#endif
        return s;
#endif
        }

    // Exactly n bytes, waiting up to `ms` for each piece to arrive (-1: as
    // long as it takes); false when the connection closed or time ran out.
    bool readExact(u8* p, u32 n, i32 ms)
        {
        u32 got = (u32)0;
        while (got < n)
            {
            if (!waitReadable(ms))
                return false;
            i32 r = read(p + got, n - got);
            if (r < (i32)0)
                return false;
            if (r == (i32)0 && !_open)
                return false;
            got = got + (u32)r;
            }
        return true;
        }

    // ── Writing ──────────────────────────────────────────────────────────

    // Sends every byte; false when the connection has gone (it is then
    // closed).
    bool write(u8* p, u32 n)
        {
#if _SOCKET_NO_TCP
        return false;
#else
        if (!_open)
            return false;
        u32 done = (u32)0;
        while (done < n)
            {
#if OS_windows
            i32 put = send((u64)_fd, p + done, (i32)(n - done), (i32)0);
            if (put <= (i32)0)
                {
                close();
                return false;
                }
            done = done + (u32)put;
#elif ARCH_x86_64 || OS_android
            i64 put = send((i32)_fd, p + done, (u64)(n - done), (i32)0x4000);   // MSG_NOSIGNAL
            if (put <= (i64)0)
                {
                close();
                return false;
                }
            done = done + (u32)put;
#else
            i64 put = send((i32)_fd, p + done, (u64)(n - done), (i32)0);
            if (put <= (i64)0)
                {
                close();
                return false;
                }
            done = done + (u32)put;
#endif
            }
        return true;
#endif
        }

    bool writeData(Data* d)
        {
        return d != 0 && write(d.bytes(), d.length());
        }

    // The String's UTF-8 bytes, without a terminator.
    bool writeString(String* s)
        {
        return s != 0 && write(s.cString(), s.byteLength());
        }

    // ── Reading ──────────────────────────────────────────────────────────

    // Waits up to `ms` milliseconds (0: not at all, -1: for as long as it
    // takes) for something to read or for the peer to go; true when read
    // would return something other than 0.
    bool waitReadable(i32 ms)
        {
#if _SOCKET_NO_TCP
        return true;
#else
        if (!_open)
            return true;
        _SocketPoll p;
#if OS_windows
        p.fd = (u64)_fd;
        p._pad = (i32)0;
#else
        p.fd = (i32)_fd;
#endif
        p.events = (i16)_SOCKET_POLLIN;
        p.revents = (i16)0;
#if OS_windows
        i32 r = WSAPoll((pointer)&p, (u32)1, ms);
#elif ARCH_x86_64
        i32 r = poll((pointer)&p, (u64)1, ms);
#else
        i32 r = poll((pointer)&p, (u32)1, ms);
#endif
        return r > (i32)0 && ((i32)p.revents & ((i32)_SOCKET_POLLIN | (i32)_SOCKET_POLLGONE)) != (i32)0;
#endif
        }

    // What has arrived, without waiting: the byte count (up to cap), 0 when
    // nothing has yet, -1 when the peer has closed the connection or it
    // failed (it is then closed).
    i32 read(u8* p, u32 cap)
        {
#if _SOCKET_NO_TCP
        return (i32)-1;
#else
        if (!_open)
            return (i32)-1;
        if (cap == (u32)0 || !waitReadable((i32)0))
            return (i32)0;
#if OS_windows
        i32 got = recv((u64)_fd, p, (i32)cap, (i32)0);
#else
        i32 got = (i32)recv((i32)_fd, p, (u64)cap, (i32)0);
#endif
        if (got <= (i32)0)
            {
            close();
            return (i32)-1;
            }
        return got;
#endif
        }

    // What has arrived, up to `max` bytes, as Data: empty when nothing has
    // yet, null when the connection is closed.
    Data* readAvailable(u32 max)
        {
        u8* buf = new u8[max == (u32)0 ? (u32)1 : max];
        i32 got = read(buf, max);
        Data* d = (Data*)0;
        if (got >= (i32)0)
            d = Data.withBytes(buf, (u32)got);
        __arc_release((pointer)buf);
        return d;
        }

    // ── Closing ──────────────────────────────────────────────────────────

    void close(void)
        {
#if !_SOCKET_NO_TCP
        if (_open)
            _socket_closeFd(_fd);
#endif
        _open = false;
        _fd = (i64)-1;
        }

    void dealloc(void)
        {
        close();
        }
    }
