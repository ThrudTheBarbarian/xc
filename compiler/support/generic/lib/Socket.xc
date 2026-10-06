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
#if ARCH_win64
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

bool _socket_winsock_ready = false;

// Winsock's start-up, once (true on the other hosts).
bool _socket_startup(void)
    {
#if ARCH_win64
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

// C's close, by another name: inside Socket the bare name is its own close().
void _socket_closeFd(i64 fd)
    {
#if ARCH_win64
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
#if ARCH_win64
            u64 h = socket(a.family, a.socktype, a.proto);
            if (h == (u64)0xFFFFFFFFFFFFFFFF)
                continue;
            if (connect(h, a.addr, (i32)a.addrlen) == (i32)0)
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
            if (connect(h, a.addr, a.addrlen) == (i32)0)
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
#if !ARCH_win64 && !ARCH_x86_64 && !PLATFORM_android
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
#if ARCH_win64
            i32 put = send((u64)_fd, p + done, (i32)(n - done), (i32)0);
            if (put <= (i32)0)
                {
                close();
                return false;
                }
            done = done + (u32)put;
#elif ARCH_x86_64 || PLATFORM_android
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
#if ARCH_win64
        p.fd = (u64)_fd;
        p._pad = (i32)0;
#else
        p.fd = (i32)_fd;
#endif
        p.events = (i16)_SOCKET_POLLIN;
        p.revents = (i16)0;
#if ARCH_win64
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
#if ARCH_win64
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
