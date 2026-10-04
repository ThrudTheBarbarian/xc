// UXSocket.xc — a TCP connection, the same calls on every desktop and phone backend.
//
//     UXSocket* s = UXSocket.connectTo((u8*)"localhost", (i32)7070);
//     if (s == (UXSocket*)0) ... UXSocket.lastError() says why
//     s.write(bytes, n);              // every byte, or false
//     i32 got = s.read(buf, cap);     // what has arrived: > 0 bytes, 0 nothing yet, -1 closed
//     s.waitReadable(ms);             // block up to ms for something to read
//     s.close();
//
// It hides what differs between the hosts: Winsock's start-up, SOCKET and closesocket on Windows, the
// two addrinfo layouts (and so the sockaddr bytes a hand-built address gets wrong), SIGPIPE on a peer
// that went away.  The address comes from getaddrinfo, IPv4 or IPv6, so nothing builds a sockaddr by
// hand.  read never blocks, so a client polls it from its frame clock and the run loop keeps turning.
//
// The C declarations are the standard library's (Http.xc), which already carries the per-host
// signatures: a C symbol has one signature, so this file uses those and adds only poll.  No TCP in a
// browser (wasm32) or on XTOS here: connect answers null with the reason.
#import <Http.xc>
#import "UXData.xc"

#if ARCH_win64
struct _UXPollFd { u64 fd; i16 events; i16 revents; i32 _pad; }
i32 WSAPoll(pointer fds, u32 n, i32 timeout);
#define _UX_POLLIN $0100  // POLLRDNORM
#define _UX_POLLGONE $0003 // POLLERR | POLLHUP
#elif ARCH_x86_64
struct _UXPollFd { i32 fd; i16 events; i16 revents; }
i32 poll(pointer fds, u64 n, i32 timeout);
#define _UX_POLLIN $0001
#define _UX_POLLGONE $0018 // POLLERR | POLLHUP
#elif ARCH_wasm32 || ARCH_arm9
#define _UX_NO_TCP 1
#else
struct _UXPollFd { i32 fd; i16 events; i16 revents; }
i32 poll(pointer fds, u32 n, i32 timeout);
#define _UX_POLLIN $0001
#define _UX_POLLGONE $0018
#endif

u8* gUXSocketError;
#if !_UX_NO_TCP && !ARCH_win64
// C's close, by another name: inside UXSocket the bare name is its own close()
void _uxSocketCloseFd(i32 fd)
    {
    close(fd);
    }
#endif

class UXSocket
    {
    i64 fd;
    bool open;

    void init(void)
        {
        fd = (i64)-1;
        open = false;
        }

    // Why the last connect failed, or "" after one that did not.
    static u8* lastError(void)
        {
        return gUXSocketError != (u8*)0 ? gUXSocketError : (u8*)"";
        }

    // A connection to host:port (a name or a numeric address, IPv4 or IPv6), blocking until it is
    // made or refused; null when it cannot be, with lastError saying why.
    static UXSocket* connectTo(u8* host, i32 port)
        {
        gUXSocketError = (u8*)"";
#if _UX_NO_TCP
        gUXSocketError = (u8*)"no TCP sockets on this platform";
        return (UXSocket*)0;
#else
#if ARCH_win64
        if (!_http_winsock_ready)
            {
            u8 wsa[512];
            if (WSAStartup((u16)$0202, &wsa[0]) != (i32)0)
                {
                gUXSocketError = (u8*)"Winsock would not start";
                return (UXSocket*)0;
                }
            _http_winsock_ready = true;
            }
#endif
        _HttpAddr hints;
        hints.flags = (i32)0;
        hints.family = (i32)0;   // AF_UNSPEC
        hints.socktype = (i32)1; // SOCK_STREAM
        hints.proto = (i32)0;
        hints.addrlen = (u32)0;
        hints._pad = (u32)0;
        hints.canon = (u8*)0;
        hints.addr = (u8*)0;
        hints.next = (_HttpAddr*)0;
        _HttpAddr* res = (_HttpAddr*)0;
        String* service = String.withFormat("%d", port);
        if (getaddrinfo(host, service.cString(), &hints, &res) != (i32)0 || res == (_HttpAddr*)0)
            {
            gUXSocketError = (u8*)"cannot resolve the host";
            return (UXSocket*)0;
            }
        UXSocket* s = (UXSocket*)0;
        for (_HttpAddr* a = res; a != (_HttpAddr*)0 && s == (UXSocket*)0; a = a.next)
            {
#if ARCH_win64
            u64 h = socket(a.family, a.socktype, a.proto);
            if (h == (u64)$FFFFFFFFFFFFFFFF)
                {
                continue;
                }
            if (connect(h, a.addr, (i32)a.addrlen) == (i32)0)
                {
                s = new UXSocket();
                s.fd = (i64)h;
                }
            else
                {
                closesocket(h);
                }
#else
            i32 h = socket(a.family, a.socktype, a.proto);
            if (h < (i32)0)
                {
                continue;
                }
            if (connect(h, a.addr, a.addrlen) == (i32)0)
                {
                s = new UXSocket();
                s.fd = (i64)h;
                }
            else
                {
                _uxSocketCloseFd(h);
                }
#endif
            }
        freeaddrinfo(res);
        if (s == (UXSocket*)0)
            {
            gUXSocketError = (u8*)"cannot connect";
            return (UXSocket*)0;
            }
        s.open = true;
#if !ARCH_win64 && !ARCH_x86_64 && !PLATFORM_android
        // A peer that closes early must fail the write, not kill the process (macOS, iOS).
        i32 one = (i32)1;
        setsockopt((i32)s.fd, (i32)$FFFF, (i32)$1022, (u8*)&one, (u32)4); // SO_NOSIGPIPE
#endif
        return s;
#endif
        }

    bool isOpen(void)
        {
        return open;
        }

    // Send every byte; false when the connection has gone (it is then closed).
    bool write(u8* p, i32 n)
        {
#if _UX_NO_TCP
        return false;
#else
        if (!open)
            {
            return false;
            }
        i32 done = (i32)0;
        while (done < n)
            {
#if ARCH_win64
            i32 put = send((u64)fd, p + done, n - done, (i32)0);
            if (put <= (i32)0)
                {
                self.close();
                return false;
                }
            done = done + put;
#elif ARCH_x86_64 || PLATFORM_android
            i64 put = send((i32)fd, p + done, (u64)(n - done), (i32)$4000); // MSG_NOSIGNAL
            if (put <= (i64)0)
                {
                self.close();
                return false;
                }
            done = done + (i32)put;
#else
            i64 put = send((i32)fd, p + done, (u64)(n - done), (i32)0);
            if (put <= (i64)0)
                {
                self.close();
                return false;
                }
            done = done + (i32)put;
#endif
            }
        return true;
#endif
        }
    bool writeData(UXData* d)
        {
        return d != (UXData*)0 && self.write(d.bytes(), d.length());
        }

    // Wait up to ms (0: not at all, -1: for as long as it takes) for something to read, or for the
    // peer to go; true when read would return something other than 0.
    bool waitReadable(i32 ms)
        {
#if _UX_NO_TCP
        return false;
#else
        if (!open)
            {
            return true; // read answers -1 at once
            }
        _UXPollFd p;
#if ARCH_win64
        p.fd = (u64)fd;
        p._pad = (i32)0;
#else
        p.fd = (i32)fd;
#endif
        p.events = (i16)_UX_POLLIN;
        p.revents = (i16)0;
#if ARCH_win64
        i32 r = WSAPoll((pointer)&p, (u32)1, ms);
#elif ARCH_x86_64
        i32 r = poll((pointer)&p, (u64)1, ms);
#else
        i32 r = poll((pointer)&p, (u32)1, ms);
#endif
        return r > (i32)0 && ((i32)p.revents & ((i32)_UX_POLLIN | (i32)_UX_POLLGONE)) != (i32)0;
#endif
        }

    // What has arrived, without waiting: the byte count (up to cap), 0 when nothing has yet, -1 when
    // the peer has closed the connection or it failed (it is then closed).
    i32 read(u8* p, i32 cap)
        {
#if _UX_NO_TCP
        return (i32)-1;
#else
        if (!open)
            {
            return (i32)-1;
            }
        if (!self.waitReadable((i32)0))
            {
            return (i32)0;
            }
#if ARCH_win64
        i32 got = recv((u64)fd, p, cap, (i32)0);
#else
        i32 got = (i32)recv((i32)fd, p, (u64)cap, (i32)0);
#endif
        if (got <= (i32)0)
            {
            self.close(); // 0: the peer closed; negative: the connection failed
            return (i32)-1;
            }
        return got;
#endif
        }

    void close(void)
        {
#if !_UX_NO_TCP
        if (!open)
            {
            return;
            }
#if ARCH_win64
        closesocket((u64)fd);
#else
        _uxSocketCloseFd((i32)fd);
#endif
#endif
        open = false;
        fd = (i64)-1;
        }

    void dealloc(void)
        {
        self.close();
        }
    }
