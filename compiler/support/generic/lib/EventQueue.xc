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

// EventQueue.xc — one wait for "a socket has something to read, or another
// thread has something for me": the loop that serves a program's tiles, or
// runs a block's tiles across devices, blocks here instead of sleeping a
// millisecond at a time and asking again (a sleep Windows rounds up to its
// 15.6 ms timer tick).
//
//     EventQueue* q = EventQueue.make();
//     q.watch(sock.fd());          // readable (or closed) wakes the wait
//     ... another thread, when its work is done: q.wake();
//     q.wait((i32)-1);              // until either; true when one happened
//
//   macOS, iOS  kqueue, woken through an EVFILT_USER event
//   Linux, Android  epoll, woken through an eventfd
//   Windows  WSAPoll over the sockets and a loopback UDP socket the wake
//            sends a byte to (WSAEventSelect would make the watched sockets
//            non-blocking, which the TLS layer's reads are not written for)
//
// A wake that comes while nobody waits is kept, so the next wait returns at
// once: a completion between "nothing finished" and "wait" is not lost.
// make() gives 0 where there is nothing to wait on (wasm32, the retro
// targets); callers then keep their timed wait.
#import "Foundation.xc"
#import "Socket.xc"

#if OS_windows
i32 sendto(u64 s, u8* buf, i32 len, i32 flags, u8* to, i32 tolen);
i32 recvfrom(u64 s, u8* buf, i32 len, i32 flags, u8* from, i32* fromlen);
i32 getsockname(u64 s, u8* name, i32* namelen);
#define _EVQ_OK 1
#elif OS_darwin
// struct kevent: ident, filter, flags, fflags, data, udata (32 bytes).
struct _EvqKevent { u64 ident; i16 filter; u16 flags; u32 fflags; i64 data; u64 udata; }
struct _EvqTimespec { i64 sec; i64 nsec; }
i32 kqueue(void);
i32 kevent(i32 kq, pointer changes, i32 nchanges, pointer events, i32 nevents, pointer timeout);
#define _EVQ_KQUEUE 1
#define _EVQ_OK 1
#elif ARCH_x86_64 || OS_linux || OS_android
i32 epoll_create1(i32 flags);
i32 epoll_ctl(i32 epfd, i32 op, i32 fd, pointer ev);
i32 epoll_wait(i32 epfd, pointer evs, i32 max, i32 timeout);
i32 eventfd(u32 initval, i32 flags);
i32 write(i32 fd, u8* buf, i32 len);
i32 read(i32 fd, u8* buf, i32 len);
#define _EVQ_EPOLL 1
#define _EVQ_OK 1
#endif

class EventQueue : Object
    {
    i64 _q;          // kqueue / epoll descriptor (Windows: unused)
    i64 _wakeFd;     // eventfd (Linux) / the loopback UDP socket (Windows)
    u8[16] _self;    // Windows: the wake socket's own address
    Array* _fds;     // Windows: the watched sockets, as Numbers
    bool _open;

    static EventQueue* make(void)
        {
#if _EVQ_OK
        EventQueue* q = new EventQueue();
        q._fds = new Array();
        if (!q._start())
            return (EventQueue*)0;
        q._open = true;
        return q;
#else
        return (EventQueue*)0;
#endif
        }

    bool _start(void)
        {
#if _EVQ_KQUEUE
        _q = (i64)kqueue();
        if (_q < (i64)0)
            return false;
        _EvqKevent ev;
        ev.ident = (u64)1;
        ev.filter = (i16)-10;                 // EVFILT_USER
        ev.flags = (u16)(0x0001 | 0x0020);    // EV_ADD | EV_CLEAR
        ev.fflags = (u32)0;
        ev.data = (i64)0;
        ev.udata = (u64)0;
        return kevent((i32)_q, (pointer)&ev, (i32)1, (pointer)0, (i32)0, (pointer)0) == (i32)0;
#elif _EVQ_EPOLL
        _q = (i64)epoll_create1((i32)0x80000);            // EPOLL_CLOEXEC
        _wakeFd = (i64)eventfd((u32)0, (i32)(0x800 | 0x80000));   // EFD_NONBLOCK | EFD_CLOEXEC
        if (_q < (i64)0 || _wakeFd < (i64)0)
            return false;
        return self._add(_wakeFd);
#elif OS_windows
        if (!_socket_startup())
            return false;
        u64 s = socket((i32)2, (i32)2, (i32)17);          // AF_INET, SOCK_DGRAM, UDP
        if (s == (u64)0xFFFFFFFFFFFFFFFF)
            return false;
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            _self[i] = (u8)0;
        _self[0] = (u8)2;                                  // AF_INET, little-endian u16
        _self[4] = (u8)127;
        _self[7] = (u8)1;                                  // 127.0.0.1, port 0: any
        if (bind(s, &_self[0], (i32)16) != (i32)0)
            return false;
        i32 len = (i32)16;
        if (getsockname(s, &_self[0], &len) != (i32)0)
            return false;
        _wakeFd = (i64)s;
        return true;
#else
        return false;
#endif
        }

#if _EVQ_EPOLL
    bool _add(i64 fd)
        {
        // struct epoll_event: u32 events, u64 data; packed (12 bytes) on
        // x86-64, naturally aligned (16) on arm64.
        u8[16] ev;
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            ev[i] = (u8)0;
        *(u32*)&ev[0] = (u32)(0x001 | 0x010 | 0x2000);    // EPOLLIN | EPOLLHUP | EPOLLRDHUP
#if ARCH_x86_64
        *(i64*)&ev[4] = fd;
#else
        *(i64*)&ev[8] = fd;
#endif
        return epoll_ctl((i32)_q, (i32)1, (i32)fd, (pointer)&ev[0]) == (i32)0;   // EPOLL_CTL_ADD
        }
#endif

    // Wake the wait when fd has something to read, or has closed.
    bool watch(i64 fd)
        {
        if (!_open || fd < (i64)0)
            return false;
#if _EVQ_KQUEUE
        _EvqKevent ev;
        ev.ident = (u64)fd;
        ev.filter = (i16)-1;                  // EVFILT_READ
        ev.flags = (u16)0x0001;               // EV_ADD
        ev.fflags = (u32)0;
        ev.data = (i64)0;
        ev.udata = (u64)0;
        return kevent((i32)_q, (pointer)&ev, (i32)1, (pointer)0, (i32)0, (pointer)0) == (i32)0;
#elif _EVQ_EPOLL
        return self._add(fd);
#elif OS_windows
        _fds.add((Object*)Number.with((u64)fd));
        return true;
#else
        return false;
#endif
        }

    // Stop watching fd (before it is closed).
    void unwatch(i64 fd)
        {
        if (!_open || fd < (i64)0)
            return;
#if _EVQ_KQUEUE
        _EvqKevent ev;
        ev.ident = (u64)fd;
        ev.filter = (i16)-1;
        ev.flags = (u16)0x0002;               // EV_DELETE
        ev.fflags = (u32)0;
        ev.data = (i64)0;
        ev.udata = (u64)0;
        kevent((i32)_q, (pointer)&ev, (i32)1, (pointer)0, (i32)0, (pointer)0);
#elif _EVQ_EPOLL
        u8[16] ev;
        epoll_ctl((i32)_q, (i32)2, (i32)fd, (pointer)&ev[0]);   // EPOLL_CTL_DEL
#elif OS_windows
        for (u32 i = (u32)0; i < _fds.count(); i = i + (u32)1)
            if (((Number*)_fds.get(i)).asU64() == (u64)fd)
                {
                _fds.removeAt(i);
                return;
                }
#endif
        }

    // Free what the queue holds (its descriptors; the watched ones are the
    // caller's). Nothing may wait or wake it after.
    void close(void)
        {
        if (!_open)
            return;
        _open = false;
#if _EVQ_KQUEUE
        _socket_closeFd(_q);              // C's close (the bare name is this method)
#elif _EVQ_EPOLL
        _socket_closeFd(_q);
        _socket_closeFd(_wakeFd);
#elif OS_windows
        _socket_closeFd(_wakeFd);
#endif
        }

    // From any thread: the wait returns (now, or at once when it next waits).
    void wake(void)
        {
        if (!_open)
            return;
#if _EVQ_KQUEUE
        _EvqKevent ev;
        ev.ident = (u64)1;
        ev.filter = (i16)-10;                 // EVFILT_USER
        ev.flags = (u16)0;
        ev.fflags = (u32)0x01000000;          // NOTE_TRIGGER
        ev.data = (i64)0;
        ev.udata = (u64)0;
        kevent((i32)_q, (pointer)&ev, (i32)1, (pointer)0, (i32)0, (pointer)0);
#elif _EVQ_EPOLL
        u64 one = (u64)1;
        write((i32)_wakeFd, (u8*)&one, (i32)8);
#elif OS_windows
        u8 b = (u8)1;
        sendto((u64)_wakeFd, &b, (i32)1, (i32)0, &_self[0], (i32)16);
#endif
        }

    // Up to ms (-1: as long as it takes) for a watched fd to be readable or
    // a wake; true when one of them happened, false on the time running out.
    bool wait(i32 ms)
        {
        if (!_open)
            return false;
#if _EVQ_KQUEUE
        u8[256] got;                                       // 8 events at 32 bytes
        _EvqTimespec ts;
        ts.sec = ms < (i32)0 ? (i64)0 : (i64)(ms / (i32)1000);
        ts.nsec = ms < (i32)0 ? (i64)0 : (i64)(ms % (i32)1000) * (i64)1000000;
        i32 n = kevent((i32)_q, (pointer)0, (i32)0, (pointer)&got[0], (i32)8,
                       ms < (i32)0 ? (pointer)0 : (pointer)&ts);
        return n > (i32)0;
#elif _EVQ_EPOLL
        u8[192] got;                                       // 12 events at 16 bytes
        i32 n = epoll_wait((i32)_q, (pointer)&got[0], (i32)12, ms);
        if (n > (i32)0)
            {
            u64 drain = (u64)0;
            read((i32)_wakeFd, (u8*)&drain, (i32)8);       // non-blocking: 0 or the count
            }
        return n > (i32)0;
#elif OS_windows
        u32 n = _fds.count() + (u32)1;
        u8* polls = new u8[n * (u32)16];
        // WSAPOLLFD: SOCKET fd (8), short events, short revents (+4 padding).
        *(u64*)&polls[0] = (u64)_wakeFd;
        *(i16*)&polls[8] = (i16)0x0100;                    // POLLRDNORM
        *(i16*)&polls[10] = (i16)0;
        for (u32 i = (u32)1; i < n; i = i + (u32)1)
            {
            *(u64*)&polls[i * (u32)16] = ((Number*)_fds.get(i - (u32)1)).asU64();
            *(i16*)&polls[i * (u32)16 + (u32)8] = (i16)0x0100;
            *(i16*)&polls[i * (u32)16 + (u32)10] = (i16)0;
            }
        i32 r = WSAPoll((pointer)polls, n, ms);
        if (r > (i32)0 && *(i16*)&polls[10] != (i16)0)
            {
            // Drain the wake bytes that are there (the socket is readable).
            u8[64] b;
            while (true)
                {
                i32 fl = (i32)16;
                u8[16] from;
                recvfrom((u64)_wakeFd, &b[0], (i32)64, (i32)0, &from[0], &fl);
                *(i16*)&polls[10] = (i16)0;
                if (WSAPoll((pointer)polls, (u32)1, (i32)0) <= (i32)0 || *(i16*)&polls[10] == (i16)0)
                    break;
                }
            }
        delete polls;
        return r > (i32)0;
#else
        return false;
#endif
        }
    }
