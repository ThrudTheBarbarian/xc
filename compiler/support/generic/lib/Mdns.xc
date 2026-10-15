// Mdns.xc — service discovery on one subnet, as much of multicast DNS
// (RFC 6762, DNS-SD RFC 6763) as the par worker daemon needs: a daemon
// advertises `_xcd._tcp.local` — its port, and a TXT `pool=` so projects on
// one LAN keep separate host sets — and a program browses for it.
//
// The group is 224.0.0.251, port 5353. A browser sends one query from a port
// of its own with the unicast-response bit set, and every daemon answers it
// directly (a "legacy unicast" response, which the standard asks for when the
// query did not come from 5353); the daemon's address is the datagram's
// source, so no A record is needed, and no host name. The daemon answers
// queries for the service only; the system's own responder (Bonjour, Avahi)
// keeps its port with us through SO_REUSEPORT/SO_REUSEADDR and is not
// consulted. One subnet only: multicast does not cross routers or VPNs, by
// the owner's decision.
#import "Socket.xc"
#import "ParDevice.xc"   // the clock

#define MDNS_PORT 5353
#define MDNS_GROUP_BE 0xFB0000E0       // 224.0.0.251 in network byte order (as a u32 in memory)
#define MDNS_SERVICE "_xcd._tcp.local"

#if !_SOCKET_NO_TCP
#if ARCH_win64
i32 sendto(u64 s, u8* buf, i32 len, i32 flags, u8* to, i32 tolen);
i32 recvfrom(u64 s, u8* buf, i32 len, i32 flags, u8* from, i32* fromlen);
#else
i64 sendto(i32 fd, u8* buf, u64 len, i32 flags, u8* to, u32 tolen);
i64 recvfrom(i32 fd, u8* buf, u64 len, i32 flags, u8* from, u32* fromlen);
#endif
#endif

// A UDP socket: the daemon's, bound to 5353 and joined to the group, or a
// browser's on a port of its own.
class MdnsSocket
    {
    i64 _fd;
    bool _open;

    static MdnsSocket* open(bool responder)
        {
#if _SOCKET_NO_TCP
        return (MdnsSocket*)0;
#else
        if (!_socket_startup())
            return (MdnsSocket*)0;
        u8 sa[16];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            sa[i] = (u8)0;
#if ARCH_win64 || ARCH_x86_64 || PLATFORM_android
        sa[0] = (u8)2;
#else
        sa[0] = (u8)16;
        sa[1] = (u8)2;
#endif
        if (responder)
            {
            sa[2] = (u8)(MDNS_PORT >> 8);
            sa[3] = (u8)(MDNS_PORT & 255);
            }
        i32 one = (i32)1;
        // ip_mreq: the group, then the interface (any).
        u8 mreq[8];
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            mreq[i] = (u8)0;
        mreq[0] = (u8)224;
        mreq[3] = (u8)251;
#if ARCH_win64
        u64 h = socket((i32)2, (i32)2, (i32)17);
        if (h == (u64)0xFFFFFFFFFFFFFFFF)
            return (MdnsSocket*)0;
        if (responder)
            {
            setsockopt(h, (i32)0xFFFF, (i32)4, (u8*)&one, (i32)4);          // SO_REUSEADDR
            if (bind(h, &sa[0], (i32)16) != (i32)0)
                {
                closesocket(h);
                return (MdnsSocket*)0;
                }
            setsockopt(h, (i32)0, (i32)12, &mreq[0], (i32)8);               // IP_ADD_MEMBERSHIP
            }
        i64 fd = (i64)h;
#else
        i32 h = socket((i32)2, (i32)2, (i32)17);
        if (h < (i32)0)
            return (MdnsSocket*)0;
        if (responder)
            {
#if ARCH_x86_64 || PLATFORM_android
            setsockopt(h, (i32)1, (i32)2, (u8*)&one, (u32)4);                // SO_REUSEADDR
            setsockopt(h, (i32)1, (i32)15, (u8*)&one, (u32)4);               // SO_REUSEPORT
#else
            setsockopt(h, (i32)0xFFFF, (i32)4, (u8*)&one, (u32)4);           // SO_REUSEADDR
            setsockopt(h, (i32)0xFFFF, (i32)0x0200, (u8*)&one, (u32)4);      // SO_REUSEPORT
#endif
            if (bind(h, &sa[0], (u32)16) != (i32)0)
                {
                _socket_closeFd((i64)h);
                return (MdnsSocket*)0;
                }
#if ARCH_x86_64 || PLATFORM_android
            setsockopt(h, (i32)0, (i32)35, &mreq[0], (u32)8);                // IP_ADD_MEMBERSHIP
#else
            setsockopt(h, (i32)0, (i32)12, &mreq[0], (u32)8);
#endif
            }
        i64 fd = (i64)h;
#endif
        MdnsSocket* s = new MdnsSocket();
        s._fd = fd;
        s._open = true;
        return s;
#endif
        }

    void close(void)
        {
#if !_SOCKET_NO_TCP
        if (_open)
            _socket_closeFd(_fd);
#endif
        _open = false;
        }

    // A datagram to ip (network byte order, as four bytes) and port.
    bool send(u8* p, u32 n, u8* ip, u16 port)
        {
#if _SOCKET_NO_TCP
        return false;
#else
        u8 sa[16];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            sa[i] = (u8)0;
#if ARCH_win64 || ARCH_x86_64 || PLATFORM_android
        sa[0] = (u8)2;
#else
        sa[0] = (u8)16;
        sa[1] = (u8)2;
#endif
        sa[2] = (u8)(port >> (u16)8);
        sa[3] = (u8)(port & (u16)255);
        sa[4] = ip[0];
        sa[5] = ip[1];
        sa[6] = ip[2];
        sa[7] = ip[3];
#if ARCH_win64
        return sendto((u64)_fd, p, (i32)n, (i32)0, &sa[0], (i32)16) == (i32)n;
#else
        return sendto((i32)_fd, p, (u64)n, (i32)0, &sa[0], (u32)16) == (i64)n;
#endif
#endif
        }

    // The next datagram within ms: its length, or -1 when none came. The
    // sender's address and port are written to ip (four bytes) and port.
    i32 recv(u8* p, u32 cap, u8* ip, u16* port, i32 ms)
        {
#if _SOCKET_NO_TCP
        return (i32)-1;
#else
        _SocketPoll pl;
#if ARCH_win64
        pl.fd = (u64)_fd;
        pl._pad = (i32)0;
#else
        pl.fd = (i32)_fd;
#endif
        pl.events = (i16)_SOCKET_POLLIN;
        pl.revents = (i16)0;
#if ARCH_win64
        i32 r = WSAPoll((pointer)&pl, (u32)1, ms);
#elif ARCH_x86_64
        i32 r = poll((pointer)&pl, (u64)1, ms);
#else
        i32 r = poll((pointer)&pl, (u32)1, ms);
#endif
        if (r <= (i32)0 || ((i32)pl.revents & (i32)_SOCKET_POLLIN) == (i32)0)
            return (i32)-1;
        u8 sa[128];
#if ARCH_win64
        i32 len = (i32)128;
        i32 n = recvfrom((u64)_fd, p, (i32)cap, (i32)0, &sa[0], &len);
#else
        u32 len = (u32)128;
        i32 n = (i32)recvfrom((i32)_fd, p, (u64)cap, (i32)0, &sa[0], &len);
#endif
        if (n < (i32)0)
            return (i32)-1;
        *port = ((u16)sa[2] << (u16)8) | (u16)sa[3];
        ip[0] = sa[4];
        ip[1] = sa[5];
        ip[2] = sa[6];
        ip[3] = sa[7];
        return n;
#endif
        }
    }

// A service found by a browse: where it is, and its pool.
class MdnsService : Object
    {
    String* host;       // dotted IPv4, the datagram's source
    u16 port;           // from the SRV record
    String* pool;       // from TXT pool=, "" when none
    }

class Mdns
    {
    // ── DNS wire helpers ───────────────────────────────────────────────
    static void put16(Data* d, u32 v)
        {
        d.appendByte((u8)(v >> 8));
        d.appendByte((u8)(v & 255));
        }
    static void put32(Data* d, u32 v)
        {
        Mdns.put16(d, v >> 16);
        Mdns.put16(d, v & 65535);
        }
    // A name as labels: "a.b.c" -> 1 a 1 b 1 c 0.
    static void putName(Data* d, u8* name)
        {
        u32 at = (u32)0;
        while (name[at] != (u8)0)
            {
            u32 end = at;
            while (name[end] != (u8)0 && name[end] != (u8)'.')
                end = end + (u32)1;
            d.appendByte((u8)(end - at));
            for (u32 i = at; i < end; i = i + (u32)1)
                d.appendByte(name[i]);
            at = name[end] == (u8)'.' ? end + (u32)1 : end;
            }
        d.appendByte((u8)0);
        }
    static u32 rd16(u8* p, u32 at)
        {
        return ((u32)p[at] << 8) | (u32)p[at + (u32)1];
        }
    // The name at *at, as "a.b.c" (compression pointers followed); *at
    // moves past the name's bytes in the packet. Null when malformed.
    static String* readName(u8* p, u32 n, u32* at)
        {
        String* s = new String();
        u32 pos = *at;
        bool jumped = false;
        u32 hops = (u32)0;
        while (pos < n)
            {
            u32 len = (u32)p[pos];
            if (len == (u32)0)
                {
                if (!jumped)
                    *at = pos + (u32)1;
                return s;
                }
            if ((len & (u32)0xC0) == (u32)0xC0)
                {
                if (pos + (u32)1 >= n || hops > (u32)16)
                    return (String*)0;
                u32 to = ((len & (u32)0x3F) << 8) | (u32)p[pos + (u32)1];
                if (!jumped)
                    *at = pos + (u32)2;
                jumped = true;
                hops = hops + (u32)1;
                pos = to;
                continue;
                }
            if (pos + (u32)1 + len > n)
                return (String*)0;
            if (s.byteLength() > (u32)0)
                s.appendByte((u8)'.');
            for (u32 i = (u32)0; i < len; i = i + (u32)1)
                s.appendByte(p[pos + (u32)1 + i]);
            pos = pos + (u32)1 + len;
            }
        return (String*)0;
        }
    static bool sameName(String* a, u8* b)
        {
        u32 i = (u32)0;
        while (i < a.byteLength() && b[i] != (u8)0)
            {
            u8 x = a.byteAt(i);
            u8 y = b[i];
            if (x >= (u8)'A' && x <= (u8)'Z') x = x + (u8)32;
            if (y >= (u8)'A' && y <= (u8)'Z') y = y + (u8)32;
            if (x != y)
                return false;
            i = i + (u32)1;
            }
        return i == a.byteLength() && b[i] == (u8)0;
        }

    // ── The packets ────────────────────────────────────────────────────
    // A query for the service's instances (PTR), asking for a unicast reply.
    static Data* query(void)
        {
        Data* d = new Data();
        Mdns.put16(d, (u32)0);          // id
        Mdns.put16(d, (u32)0);          // flags: a standard query
        Mdns.put16(d, (u32)1);          // one question
        Mdns.put16(d, (u32)0);
        Mdns.put16(d, (u32)0);
        Mdns.put16(d, (u32)0);
        Mdns.putName(d, MDNS_SERVICE);
        Mdns.put16(d, (u32)12);         // PTR
        Mdns.put16(d, (u32)0x8001);     // IN, unicast response wanted
        return d;
        }
    // Whether a packet is a query that asks for the service.
    static bool asksForService(u8* p, u32 n)
        {
        if (n < (u32)12 || ((u32)p[2] & (u32)0x80) != (u32)0)
            return false;
        u32 qd = Mdns.rd16(p, (u32)4);
        u32 at = (u32)12;
        for (u32 q = (u32)0; q < qd; q = q + (u32)1)
            {
            String* name = Mdns.readName(p, n, &at);
            if (name == (String*)0 || at + (u32)4 > n)
                return false;
            u32 type = Mdns.rd16(p, at);
            at = at + (u32)4;
            if (Mdns.sameName(name, MDNS_SERVICE) && (type == (u32)12 || type == (u32)255))
                return true;
            }
        return false;
        }
    // A daemon's answer: the service's instance (PTR), where it is (SRV)
    // and its pool and version (TXT).
    static Data* answer(u8* instance, u16 port, u8* pool, u8* version)
        {
        String* inst = String.withCString(instance);
        inst.appendCString(".");
        inst.appendCString(MDNS_SERVICE);
        Data* d = new Data();
        Mdns.put16(d, (u32)0);
        Mdns.put16(d, (u32)0x8400);     // a response, authoritative
        Mdns.put16(d, (u32)0);
        Mdns.put16(d, (u32)3);          // three answers
        Mdns.put16(d, (u32)0);
        Mdns.put16(d, (u32)0);
        // PTR _xcd._tcp.local -> <instance>._xcd._tcp.local
        Mdns.putName(d, MDNS_SERVICE);
        Mdns.put16(d, (u32)12);
        Mdns.put16(d, (u32)1);
        Mdns.put32(d, (u32)120);
        Data* rd = new Data();
        Mdns.putName(rd, inst.cString());
        Mdns.put16(d, rd.length());
        d.appendBytes(rd.bytes(), rd.length());
        // SRV <instance> -> port, target xcd.local (unused: the address is the datagram's source)
        Mdns.putName(d, inst.cString());
        Mdns.put16(d, (u32)33);
        Mdns.put16(d, (u32)0x8001);     // IN, cache-flush
        Mdns.put32(d, (u32)120);
        rd = new Data();
        Mdns.put16(rd, (u32)0);         // priority
        Mdns.put16(rd, (u32)0);         // weight
        Mdns.put16(rd, (u32)port);
        Mdns.putName(rd, "xcd.local");
        Mdns.put16(d, rd.length());
        d.appendBytes(rd.bytes(), rd.length());
        // TXT <instance> -> "pool=<pool>" "ver=<version>"
        Mdns.putName(d, inst.cString());
        Mdns.put16(d, (u32)16);
        Mdns.put16(d, (u32)0x8001);
        Mdns.put32(d, (u32)120);
        rd = new Data();
        String* t1 = String.withCString("pool=");
        t1.appendCString(pool);
        rd.appendByte((u8)t1.byteLength());
        rd.appendBytes(t1.cString(), t1.byteLength());
        String* t2 = String.withCString("ver=");
        t2.appendCString(version);
        rd.appendByte((u8)t2.byteLength());
        rd.appendBytes(t2.cString(), t2.byteLength());
        Mdns.put16(d, rd.length());
        d.appendBytes(rd.bytes(), rd.length());
        return d;
        }
    // A response's SRV port and TXT pool for the service, or null when the
    // packet is not one (the address is the sender's).
    static MdnsService* parseAnswer(u8* p, u32 n, u8* ip, u8* version)
        {
        if (n < (u32)12 || ((u32)p[2] & (u32)0x80) == (u32)0)
            return (MdnsService*)0;
        u32 qd = Mdns.rd16(p, (u32)4);
        u32 an = Mdns.rd16(p, (u32)6) + Mdns.rd16(p, (u32)8) + Mdns.rd16(p, (u32)10);
        u32 at = (u32)12;
        for (u32 q = (u32)0; q < qd; q = q + (u32)1)
            {
            if (Mdns.readName(p, n, &at) == (String*)0)
                return (MdnsService*)0;
            at = at + (u32)4;
            }
        bool ours = false;
        u16 port = (u16)0;
        String* pool = new String();
        bool sameVersion = false;
        for (u32 a = (u32)0; a < an && at < n; a = a + (u32)1)
            {
            String* name = Mdns.readName(p, n, &at);
            if (name == (String*)0 || at + (u32)10 > n)
                break;
            u32 type = Mdns.rd16(p, at);
            u32 rdlen = Mdns.rd16(p, at + (u32)8);
            at = at + (u32)10;
            if (at + rdlen > n)
                break;
            if (type == (u32)12 && Mdns.sameName(name, MDNS_SERVICE))
                ours = true;
            else if (type == (u32)33 && rdlen >= (u32)6)
                port = (u16)Mdns.rd16(p, at + (u32)4);
            else if (type == (u32)16)
                {
                u32 q = at;
                while (q < at + rdlen)
                    {
                    u32 len = (u32)p[q];
                    q = q + (u32)1;
                    if (q + len > at + rdlen)
                        break;
                    if (len >= (u32)5 && p[q] == (u8)'p' && p[q + (u32)1] == (u8)'o' && p[q + (u32)2] == (u8)'o' && p[q + (u32)3] == (u8)'l' && p[q + (u32)4] == (u8)'=')
                        {
                        pool = new String();
                        for (u32 i = (u32)5; i < len; i = i + (u32)1)
                            pool.appendByte(p[q + i]);
                        }
                    if (len >= (u32)4 && p[q] == (u8)'v' && p[q + (u32)1] == (u8)'e' && p[q + (u32)2] == (u8)'r' && p[q + (u32)3] == (u8)'=')
                        {
                        String* v = new String();
                        for (u32 i = (u32)4; i < len; i = i + (u32)1)
                            v.appendByte(p[q + i]);
                        sameVersion = v.equals(String.withCString(version));
                        }
                    q = q + len;
                    }
                }
            at = at + rdlen;
            }
        if (!ours || port == (u16)0 || !sameVersion)
            return (MdnsService*)0;
        MdnsService* s = new MdnsService();
        s.host = Mdns.dotted(ip);
        s.port = port;
        s.pool = pool;
        return s;
        }
    static String* dotted(u8* ip)
        {
        String* s = new String();
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            {
            if (i > (u32)0)
                s.appendByte((u8)'.');
            s.append(String.withU32((u32)ip[i]));
            }
        return s;
        }

    // ── Browsing ───────────────────────────────────────────────────────
    // The daemons on this subnet that answer within ms, of the given pool
    // ("" for those with none) and this xcc version: MdnsService each.
    static Array* browse(u8* pool, u8* version, i32 ms)
        {
        Array* found = new Array();
        MdnsSocket* s = MdnsSocket.open(false);
        if (s == (MdnsSocket*)0)
            return found;
        u8 group[4];
        group[0] = (u8)224;
        group[1] = (u8)0;
        group[2] = (u8)0;
        group[3] = (u8)251;
        Data* q = Mdns.query();
        s.send(q.bytes(), q.length(), &group[0], (u16)MDNS_PORT);
        i64 until = ParDevice.nowUs() / (i64)1000 + (i64)ms;
        u8 buf[1500];
        u8 ip[4];
        u16 port = (u16)0;
        while (true)
            {
            i64 left = until - ParDevice.nowUs() / (i64)1000;
            if (left <= (i64)0)
                break;
            i32 n = s.recv(&buf[0], (u32)1500, &ip[0], &port, (i32)left);
            if (n <= (i32)0)
                continue;
            MdnsService* svc = Mdns.parseAnswer(&buf[0], (u32)n, &ip[0], version);
            if (ParDevice.reporting())
                {
                Log.info("par: mdns: %d bytes from %s:%u, %s", n, Mdns.dotted(&ip[0]).cString(), (u32)port,
                         svc == (MdnsService*)0 ? "not a daemon's answer" : "a daemon");
                }
            if (svc == (MdnsService*)0 || !svc.pool.equals(String.withCString(pool)))
                continue;
            bool seen = false;
            for (u32 i = (u32)0; i < found.count(); i = i + (u32)1)
                {
                MdnsService* o = (MdnsService*)found.get(i);
                if (o.host.equals(svc.host) && o.port == svc.port)
                    seen = true;
                }
            if (!seen)
                found.add((Object*)svc);
            }
        s.close();
        return found;
        }
    }

// The daemon's responder: answers every query for the service with where
// this daemon is, and announces itself once when it starts. Runs on a
// thread of its own (Thread.spawn(&r.run)).
class MdnsResponder : Object
    {
    u16 _port;
    String* _pool;
    String* _version;
    bool _stop;

    void init(u16 port, String* pool, String* version)
        {
        _port = port;
        _pool = pool;
        _version = version;
        _stop = false;
        }
    void stop(void)
        {
        _stop = true;
        }
    void run(void)
        {
        MdnsSocket* s = MdnsSocket.open(true);
        if (s == (MdnsSocket*)0)
            {
            Log.info("xcd: mdns: cannot open port 5353, not advertising");
            return;
            }
        Data* a = Mdns.answer("xcd", _port, _pool.cString(), _version.cString());
        u8 group[4];
        group[0] = (u8)224;
        group[1] = (u8)0;
        group[2] = (u8)0;
        group[3] = (u8)251;
        s.send(a.bytes(), a.length(), &group[0], (u16)MDNS_PORT);
        u8 buf[1500];
        u8 ip[4];
        u16 port = (u16)0;
        while (!_stop)
            {
            i32 n = s.recv(&buf[0], (u32)1500, &ip[0], &port, (i32)500);
            if (n <= (i32)0)
                continue;
            if (Mdns.asksForService(&buf[0], (u32)n))
                {
                if (ParDevice.reporting())
                    Log.info("xcd: mdns: query from %s:%u, answered", Mdns.dotted(&ip[0]).cString(), (u32)port);
                s.send(a.bytes(), a.length(), &ip[0], port);
                }
            }
        s.close();
        }
    }
