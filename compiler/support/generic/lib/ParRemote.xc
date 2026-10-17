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

// ParRemote.xc — a GPU on another machine as a worker on the tile queue
// (par-tiles-and-devices.md "Beyond one box"; par-auto-parallelisation.md,
// the xcd requirements). Two halves over one wire format:
//
//   ParRemoteWorker   in the program (the coordinator): a ParWorker whose
//                     take() sends a tile over TCP and whose poll() reads
//                     the written slices and the reduction partials back.
//                     XC_PAR_REMOTE=host[:port],… names the workers.
//   ParRemoteServe    in `xcd` (the worker daemon): takes a block as bytes —
//                     its kernel source, its object, its arrays and globals —
//                     stands a chunk in for the class it has no code for,
//                     and runs the tiles on its own GPU workers.
//
// The frames: u32 type, u32 length, payload, little-endian throughout, over
// TLS (ParTls, ParLink: the daemon's certificate, pinned by the program on
// first sight). A program holds two links to a daemon: it writes tiles on
// the first and the daemon writes finished tiles on the second, from a
// thread of its own, so neither side ever waits on a write the other is
// not reading (both writing a large frame at once would wait for ever). The
// handshake carries the protocol version and the runtime's version (the
// par.learned lesson: never act on a mismatched peer) and proves a pool
// secret (XC_PAR_SECRET on both sides) by SHA-256 over a nonce the daemon
// chose; a daemon with no secret takes anyone on its subnet. Only the GPU
// runs a tile on the far side: the CPU would need the block's compiled
// code, which stays where the program is. The reduction fold stays with
// the program too, in tile order, so a run is bit-equal to a local one.
//
// A heartbeat (PING/PONG) measures the link once at connect — its round
// trip, and its upload bandwidth from a 1 MB ping — and then, every second
// while the queue asks, whether the daemon may take tiles now: `ready()` is
// the daemon's last word, false when the daemon is inside its nimby window
// (`xcd -nimby hh:mm-hh:mm`, the owner's hours) or has not answered a ping
// for five seconds. The link's latency sets the block's tile floor on this
// worker: a tile's transfer is at least twenty round trips long, so the
// latency costs five percent at most.
//
// Not yet: the GPU-RAM cache, a load check at tile acceptance (GPU
// utilisation, free VRAM) and a refusal of tiles that would run past the
// window's end. An array whose footprint the compiler knows travels as the
// slices each tile reads, with the tile (as to a discrete card); the rest go
// over whole once per run at PREPARE.
#import "Par.xc"
#import "ParWorker.xc"
#import "Socket.xc"
#import "Sha256.xc"
#import "Mdns.xc"
#import "Mutex.xc"
#import "Cond.xc"
#import "Thread.xc"
#import "EventQueue.xc"
#import "Settings.xc"
#import "Files.xc"
#import "Base64.xc"
#import "Bundle.xc"

#define PAR_REMOTE_PROTO 5
#define PAR_REMOTE_PORT 7227
#define PAR_REMOTE_DEPTH 3

// Frame types.
// The frames (protocol 4): a tag of 8 bytes of ASCII, NUL-padded, a u32
// length and a body of fields of the same shape, read by tag (ParWire).
//   HELLO    daemon -> program: PROTO, NONCE, VERSION, IDENT, DEPTH, FLOOR,
//            VRAMTOT, VRAMFREE, RAMTOT, RAMFREE
//   AUTH     program -> daemon: PROTO, VERSION, PROOF; reply OK (TOKEN) or BYE (WHY)
//   RESULTS  program -> daemon, first on its second link: TOKEN; reply OK
//   HOLDS    program -> daemon: BLOCK (no data); reply ANSWER (TAKEN: 1 yes, 0 no, 2 busy)
//   PREPARE  program -> daemon: BLOCK (with data), TILE, N; reply ANSWER
//   TILE     program -> daemon: INDEX, LO, HI, SLICES
//   DONE     daemon -> program, on the results link: INDEX, SLICES, PARTS, NBACK, KERNELUS
//   FINISH   program -> daemon: the run is over
//   PING     program -> daemon: SENT, KIND (0 heartbeat, 1 bandwidth probe), PAD
//   PONG     daemon -> program: SENT, KIND, AVAILABLE, QUEUED
#define PAR_REMOTE_PROBE_BYTES (1024 * 1024)

// ── TLS: the library, loaded when a daemon is first spoken to ────────────
// A daemon takes TLS only, and ParRemote links nothing for it: libtls (the
// shared TLS module, frameworks/3p/tls) is loaded by name the first time a
// program speaks to a daemon, as ParVulkan loads its driver, and its plain
// xctls_* entry points are resolved by name. A program on a machine with no
// library reports the daemon unreachable and runs on; the daemon itself
// refuses to start. The library is looked for as the file XC_TLS_LIB names,
// beside the executable (the xcd archive puts it there), in the toolchain's
// third-party tree, then by its bare name through the system's loader.
#if ARCH_win64
pointer LoadLibraryA(u8* name);
pointer GetProcAddress(pointer module, u8* name);
#define PAR_TLS_LOADER 1
#elif ARCH_arm64 || LINK_DYNAMIC || PLATFORM_android
pointer dlopen(u8* path, i32 mode);
pointer dlsym(pointer handle, u8* name);
#define PAR_TLS_LOADER 1
#else
#define PAR_TLS_LOADER 0
#endif
#if ARCH_x86_64 || PLATFORM_android
pointer signal(i32 sig, pointer handler);
#endif
typedef i32 xctlsMakeSelfSigned_t(u8* certPath, u8* keyPath, u8* cn);
typedef pointer xctlsServer_t(u8* certPath, u8* keyPath);
typedef pointer xctlsClient_t(void);
typedef pointer xctlsAccept_t(pointer server, i32 fd);
typedef pointer xctlsConnect_t(pointer client, i32 fd, u8* hostname);
typedef i32 xctlsFingerprint_t(pointer conn, u8* out32);
typedef i32 xctlsPending_t(pointer conn);
typedef i32 xctlsRead_t(pointer conn, u8* buf, i32 len);
typedef i32 xctlsWrite_t(pointer conn, u8* buf, i32 len);
typedef void xctlsClose_t(pointer conn);

class ParTls
    {
    static i32 _state;      // 0 not tried, 1 loaded, 2 not there
    static pointer _lib;
    static pointer _client; // one pinning client configuration per process
    static xctlsMakeSelfSigned_t* _makeSelfSigned;
    static xctlsServer_t* _server;
    static xctlsClient_t* _clientNew;
    static xctlsAccept_t* _accept;
    static xctlsConnect_t* _connect;
    static xctlsFingerprint_t* _fingerprint;
    static xctlsPending_t* _pending;
    static xctlsRead_t* _read;
    static xctlsWrite_t* _write;
    static xctlsClose_t* _close;

#if PAR_TLS_LOADER
    static pointer openLib(u8* path)
        {
#if ARCH_win64
        return LoadLibraryA(path);
#else
        return dlopen(path, (i32)2);   // RTLD_NOW
#endif
        }
    static pointer fn(u8* name)
        {
#if ARCH_win64
        return GetProcAddress(_lib, name);
#else
        return dlsym(_lib, name);
#endif
        }
#endif

    // The library, once: XC_TLS_LIB, beside the executable, the toolchain's
    // third-party tree, then the system loader's own search.
    static bool load(void)
        {
        if (_state != (i32)0)
            return _state == (i32)1;
        _state = (i32)2;
#if ARCH_x86_64 || PLATFORM_android
        // The library writes to the socket itself, so a peer that has gone
        // raises SIGPIPE, which kills the process (exit 141) where the write
        // should fail and the tiles be re-issued. Socket's own writes say
        // MSG_NOSIGNAL and Apple's sockets SO_NOSIGPIPE; this covers the TLS
        // writes on Linux and Android.
        signal((i32)13, (pointer)1);    // SIGPIPE, SIG_IGN
#endif
#if PAR_TLS_LOADER
        String* env = Platform.env(String.withCString("XC_TLS_LIB"));
        if (env.byteLength() > (u32)0)
            _lib = openLib(env.cString());
        String* exe = Bundle.executablePath();
        if (_lib == (pointer)0 && exe != (String*)0 && exe.byteLength() > (u32)0)
            {
            u32 cut = exe.byteLength();
            while (cut > (u32)0 && exe.byteAt(cut - (u32)1) != (u8)'/' && exe.byteAt(cut - (u32)1) != (u8)'\\')
                cut = cut - (u32)1;
#if ARCH_win64
            String* beside = exe.substringBytes((u32)0, cut).appending(String.withCString("libtls.dll"));
#elif ARCH_arm64 && !PLATFORM_android
            String* beside = exe.substringBytes((u32)0, cut).appending(String.withCString("libtls.dylib"));
#else
            String* beside = exe.substringBytes((u32)0, cut).appending(String.withCString("libtls.so"));
#endif
            if (cut > (u32)0 && Files.exists(beside))
                _lib = openLib(beside.cString());
            }
#if ARCH_win64
        if (_lib == (pointer)0)
            _lib = openLib("C:/Program Files/xcc/3p/tls/win64/libtls.dll");
        if (_lib == (pointer)0)
            _lib = openLib("C:/Program Files/3p/tls/win64/libtls.dll");
        if (_lib == (pointer)0)
            _lib = openLib("libtls.dll");
#elif PLATFORM_android
        if (_lib == (pointer)0)
            _lib = openLib("libtls.so");
#elif PLATFORM_ios
        if (_lib == (pointer)0)
            _lib = openLib("libtls.dylib");
#elif ARCH_arm64
        if (_lib == (pointer)0)
            _lib = openLib("/opt/xcc/3p/tls/arm64/libtls.dylib");
        if (_lib == (pointer)0)
            _lib = openLib("libtls.dylib");
#else
        if (_lib == (pointer)0)
            _lib = openLib("/opt/xcc/3p/tls/x86_64/libtls.so");
        if (_lib == (pointer)0)
            _lib = openLib("libtls.so");
#endif
        if (_lib == (pointer)0)
            return false;
        _makeSelfSigned = (xctlsMakeSelfSigned_t*)fn("xctls_make_self_signed");
        _server = (xctlsServer_t*)fn("xctls_server");
        _clientNew = (xctlsClient_t*)fn("xctls_client_pinning");
        _accept = (xctlsAccept_t*)fn("xctls_accept");
        _connect = (xctlsConnect_t*)fn("xctls_connect");
        _fingerprint = (xctlsFingerprint_t*)fn("xctls_fingerprint");
        _pending = (xctlsPending_t*)fn("xctls_pending");
        _read = (xctlsRead_t*)fn("xctls_read");
        _write = (xctlsWrite_t*)fn("xctls_write");
        _close = (xctlsClose_t*)fn("xctls_close");
        // A library from before these entry points is no use.
        if (_makeSelfSigned == (pointer)0 || _server == (pointer)0 || _clientNew == (pointer)0
            || _accept == (pointer)0 || _connect == (pointer)0 || _fingerprint == (pointer)0
            || _pending == (pointer)0 || _read == (pointer)0 || _write == (pointer)0 || _close == (pointer)0)
            return false;
        _state = (i32)1;
#endif
        return _state == (i32)1;
        }

    // A self-signed certificate and its key, as PEM files; false when they
    // could not be written.
    static bool makeSelfSigned(String* certPath, String* keyPath, u8* cn)
        {
        return load() && _makeSelfSigned(certPath.cString(), keyPath.cString(), cn) == (i32)0;
        }
    // A server configuration from a certificate and key, or null.
    static pointer server(String* certPath, String* keyPath)
        {
        return load() ? _server(certPath.cString(), keyPath.cString()) : (pointer)0;
        }
    // The server's side of a handshake on a connected socket, or null.
    static pointer accept(pointer server, i32 fd)
        {
        return load() && server != (pointer)0 ? _accept(server, fd) : (pointer)0;
        }
    // The program's side: the daemon's certificate is taken as it comes,
    // and the caller pins its fingerprint. Null when the handshake failed.
    static pointer connect(i32 fd, u8* host)
        {
        if (!load())
            return (pointer)0;
        if (_client == (pointer)0)
            _client = _clientNew();
        return _client != (pointer)0 ? _connect(_client, fd, host) : (pointer)0;
        }
    // The peer's certificate's SHA-256 as lowercase hex, or "" when it sent none.
    static String* fingerprint(pointer conn)
        {
        u8 fp[32];
        if (conn == (pointer)0 || _fingerprint(conn, &fp[0]) != (i32)0)
            return String.withCString("");
        return Data.withBytes(&fp[0], (u32)32).hexString();
        }
    // A certificate file's SHA-256 (of its DER) as hex, the value a program
    // pins, or "" when the file is not a PEM certificate.
    static String* certFingerprint(String* certPath)
        {
        String* pem = Files.readText(certPath);
        if (pem == (String*)0)
            return String.withCString("");
        Array* lines = pem.splitOnByte((u8)'\n');
        String* b64 = new String();
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = ((String*)lines.get(i)).trimmed();
            if (line.byteLength() == (u32)0 || line.hasPrefix(String.withCString("-----")))
                continue;
            b64.append(line);
            }
        Data* der = Base64.decode(b64);
        if (der == (Data*)0 || der.length() == (u32)0)
            return String.withCString("");
        return Sha256.of(der.bytes(), der.length()).hexString();
        }
    static i32 pending(pointer conn)
        {
        return _pending(conn);
        }
    static i32 read(pointer conn, u8* buf, i32 len)
        {
        return _read(conn, buf, len);
        }
    static i32 write(pointer conn, u8* buf, i32 len)
        {
        return _write(conn, buf, len);
        }
    static void close(pointer conn)
        {
        _close(conn);
        }
    }

// A connection between a program and a daemon: the socket, and the TLS
// session over it. Every frame goes through the session; a link whose
// handshake has not happened carries nothing, so no frame ever travels in
// the clear.
class ParLink
    {
    Socket* _s;
    pointer _tls;

    void init(Socket* s)
        {
        _s = s;
        }
    bool isOpen(void)
        {
        return _s != (Socket*)0 && _s.isOpen();
        }
    // The program's side of the handshake; false when it failed (the link
    // is then closed).
    bool connect(u8* host)
        {
        if (!isOpen())
            return false;
        _tls = ParTls.connect((i32)_s.fd(), host);
        if (_tls == (pointer)0)
            close();
        return _tls != (pointer)0;
        }
    // The daemon's side.
    bool accept(pointer server)
        {
        if (!isOpen())
            return false;
        _tls = ParTls.accept(server, (i32)_s.fd());
        if (_tls == (pointer)0)
            close();
        return _tls != (pointer)0;
        }
    // The peer's certificate's SHA-256 as hex, "" when there is none.
    String* fingerprint(void)
        {
        return ParTls.fingerprint(_tls);
        }
    bool write(u8* p, u32 n)
        {
        if (_tls == (pointer)0 || !isOpen())
            return false;
        if (n > (u32)0 && ParTls.write(_tls, p, (i32)n) != (i32)n)
            {
            close();
            return false;
            }
        return true;
        }
    // Exactly n bytes, waiting up to `ms` for the first (-1: as long as it
    // takes); false when the connection closed or time ran out.
    bool readExact(u8* p, u32 n, i32 ms)
        {
        if (_tls == (pointer)0 || !isOpen())
            return false;
        u32 got = (u32)0;
        while (got < n)
            {
            if (!waitReadable(ms))
                return false;
            i32 r = ParTls.read(_tls, p + got, (i32)(n - got));
            if (r <= (i32)0)
                {
                close();
                return false;
                }
            got = got + (u32)r;
            }
        return true;
        }
    // The socket's descriptor, for an EventQueue to watch; -1 when closed.
    i64 fd(void)
        {
        return isOpen() ? _s.fd() : (i64)-1;
        }
    // Whether a read would return something now: bytes the session has
    // decrypted and holds (the socket says nothing about those), or bytes
    // on the socket, waited for up to `ms` (0: not at all, -1: as long as
    // it takes); true as well when the peer has gone.
    bool waitReadable(i32 ms)
        {
        if (!isOpen())
            return true;
        if (_tls != (pointer)0 && ParTls.pending(_tls) > (i32)0)
            return true;
        return _s.waitReadable(ms);
        }
    void close(void)
        {
        if (_tls != (pointer)0)
            {
            ParTls.close(_tls);
            _tls = (pointer)0;
            }
        if (_s != (Socket*)0)
            _s.close();
        }
    }


// A little-endian byte writer and reader over Data.
class ParWire
    {
    // A content hash for the daemon's slice cache: 64 bits over the bytes as
    // words in two lanes (rotate, multiply by odd constants), the tail by
    // byte, the length folded in. Memory speed; the link is the slow part.
    static u64 hash64(u8* p, u32 n)
        {
        u64 a = (u64)0x9E3779B97F4A7C15 ^ (u64)n;
        u64 b = (u64)0xC2B2AE3D27D4EB4F;
        u32 i = (u32)0;
        while (i + (u32)16 <= n)
            {
            u64 x = *(u64*)(p + i);
            u64 y = *(u64*)(p + i + (u32)8);
            a = ((a ^ x) * (u64)0x9FB21C651E98DF25);
            a = (a << (u64)27) | (a >> (u64)37);
            b = ((b ^ y) * (u64)0x9E6C63D0676A9A99);
            b = (b << (u64)31) | (b >> (u64)33);
            i = i + (u32)16;
            }
        while (i < n)
            {
            a = (a ^ (u64)p[i]) * (u64)0x100000001B3;
            i = i + (u32)1;
            }
        u64 h = a ^ (b * (u64)0x9E3779B97F4A7C15);
        h = h ^ (h >> (u64)29);
        h = h * (u64)0xBF58476D1CE4E5B9;
        return h ^ (h >> (u64)32);
        }
    static void putU8(Data* d, u8 v) { d.appendByte(v); }
    static void putU32(Data* d, u32 v)
        {
        d.appendByte((u8)v); d.appendByte((u8)(v >> (u32)8)); d.appendByte((u8)(v >> (u32)16)); d.appendByte((u8)(v >> (u32)24));
        }
    static void putI64(Data* d, i64 v)
        {
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            d.appendByte((u8)((u64)v >> ((u64)i * (u64)8)));
        }
    static void putBytes(Data* d, u8* p, u32 n)
        {
        ParWire.putU32(d, n);
        if (n > (u32)0)
            d.appendBytes(p, n);
        }
    static void putStr(Data* d, u8* s)
        {
        u32 n = (u32)0;
        while (s[n] != (u8)0)
            n = n + (u32)1;
        ParWire.putBytes(d, s, n);
        }
    static u8 rdU8(u8* p, u32* at) { u8 v = p[*at]; *at = *at + (u32)1; return v; }
    static u32 rdU32(u8* p, u32* at)
        {
        u32 v = (u32)p[*at] | ((u32)p[*at + (u32)1] << (u32)8) | ((u32)p[*at + (u32)2] << (u32)16) | ((u32)p[*at + (u32)3] << (u32)24);
        *at = *at + (u32)4;
        return v;
        }
    static i64 rdI64(u8* p, u32* at)
        {
        u64 v = (u64)0;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            v = v | ((u64)p[*at + i] << ((u64)i * (u64)8));
        *at = *at + (u32)8;
        return (i64)v;
        }
    // A counted byte string: its length, and where it starts (the caller
    // copies). The cursor moves past it.
    static u32 rdBytes(u8* p, u32* at, u8** start)
        {
        u32 n = ParWire.rdU32(p, at);
        *start = p + *at;
        *at = *at + n;
        return n;
        }
    // A counted string as a NUL-terminated copy.
    static String* rdStr(u8* p, u32* at)
        {
        u8* s = (u8*)0;
        u32 n = ParWire.rdBytes(p, at, &s);
        String* r = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            r.appendByte(s[i]);
        return r;
        }

    // ── tag, length, value ───────────────────────────────────────────
    // A tag is 8 bytes of ASCII, NUL-padded (`DONE` reads as itself in a
    // capture); a field is a tag, a u32 length and the bytes; a frame is the
    // same with its body made of fields. A reader takes a field by tag and
    // skips what it does not know, so the two sides may differ by a field.
    static void tag8(Data* d, u8* tag)
        {
        u32 i = (u32)0;
        while (i < (u32)8 && tag[i] != (u8)0)
            {
            d.appendByte(tag[i]);
            i = i + (u32)1;
            }
        while (i < (u32)8)
            {
            d.appendByte((u8)0);
            i = i + (u32)1;
            }
        }
    static bool tagIs(u8* have8, u8* tag)
        {
        u32 i = (u32)0;
        while (i < (u32)8 && tag[i] != (u8)0)
            {
            if (have8[i] != tag[i])
                return false;
            i = i + (u32)1;
            }
        while (i < (u32)8)
            {
            if (have8[i] != (u8)0)
                return false;
            i = i + (u32)1;
            }
        return true;
        }
    static void field(Data* d, u8* tag, u8* p, u32 n)
        {
        ParWire.tag8(d, tag);
        ParWire.putU32(d, n);
        if (n > (u32)0)
            d.appendBytes(p, n);
        }
    static void fieldU8(Data* d, u8* tag, u8 v)
        {
        u8 b[1];
        b[0] = v;
        ParWire.field(d, tag, &b[0], (u32)1);
        }
    static void fieldU32(Data* d, u8* tag, u32 v)
        {
        Data* x = new Data();
        ParWire.putU32(x, v);
        ParWire.field(d, tag, x.bytes(), (u32)4);
        }
    static void fieldI64(Data* d, u8* tag, i64 v)
        {
        Data* x = new Data();
        ParWire.putI64(x, v);
        ParWire.field(d, tag, x.bytes(), (u32)8);
        }
    static void fieldStr(Data* d, u8* tag, u8* s)
        {
        u32 n = (u32)0;
        while (s[n] != (u8)0)
            n = n + (u32)1;
        ParWire.field(d, tag, s, n);
        }
    static void fieldData(Data* d, u8* tag, Data* v)
        {
        ParWire.field(d, tag, v.bytes(), v.length());
        }
    // The field `tag` of a body: its bytes and length, or false.
    static bool find(Data* body, u8* tag, u8** p, u32* n)
        {
        if (body == (Data*)0)
            return false;
        u8* b = body.bytes();
        u32 len = body.length();
        u32 at = (u32)0;
        while (at + (u32)12 <= len)
            {
            u32 q = at + (u32)8;
            u32 fl = ParWire.rdU32(b, &q);
            if (q + fl > len)
                return false;
            if (ParWire.tagIs(b + at, tag))
                {
                *p = b + q;
                *n = fl;
                return true;
                }
            at = q + fl;
            }
        return false;
        }
    static u8 getU8(Data* body, u8* tag, u8 dflt)
        {
        u8* p = (u8*)0;
        u32 n = (u32)0;
        if (!ParWire.find(body, tag, &p, &n) || n < (u32)1)
            return dflt;
        return p[0];
        }
    static u32 getU32(Data* body, u8* tag, u32 dflt)
        {
        u8* p = (u8*)0;
        u32 n = (u32)0;
        if (!ParWire.find(body, tag, &p, &n) || n < (u32)4)
            return dflt;
        u32 at = (u32)0;
        return ParWire.rdU32(p, &at);
        }
    static i64 getI64(Data* body, u8* tag, i64 dflt)
        {
        u8* p = (u8*)0;
        u32 n = (u32)0;
        if (!ParWire.find(body, tag, &p, &n) || n < (u32)8)
            return dflt;
        u32 at = (u32)0;
        return ParWire.rdI64(p, &at);
        }
    static String* getStr(Data* body, u8* tag)
        {
        u8* p = (u8*)0;
        u32 n = (u32)0;
        if (!ParWire.find(body, tag, &p, &n))
            return (String*)0;
        String* r = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            r.appendByte(p[i]);
        return r;
        }
    static Data* getData(Data* body, u8* tag)
        {
        u8* p = (u8*)0;
        u32 n = (u32)0;
        if (!ParWire.find(body, tag, &p, &n))
            return (Data*)0;
        return Data.withBytes(p, n);
        }

    // One frame out: the tag, the length, the body.
    static bool send(ParLink* s, u8* tag, Data* body)
        {
        Data* h = new Data();
        ParWire.tag8(h, tag);
        u32 n = body != (Data*)0 ? body.length() : (u32)0;
        ParWire.putU32(h, n);
        if (!s.write(h.bytes(), (u32)12))
            return false;
        return n == (u32)0 || s.write(body.bytes(), n);
        }
    // One frame in, waiting up to ms for it: the body, with its tag copied
    // into `tag8`; null when the connection closed or time ran out.
    static Data* recv(ParLink* s, u8* tag8, i32 ms)
        {
        u8 hdr[12];
        if (!s.readExact(&hdr[0], (u32)12, ms))
            return (Data*)0;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            tag8[i] = hdr[i];
        u32 at = (u32)8;
        u32 n = ParWire.rdU32(&hdr[0], &at);
        Data* d = Data.withLength(n);
        if (n > (u32)0 && !s.readExact(d.bytes(), n, (i32)-1))
            return (Data*)0;
        return d;
        }

    // The length of a block's kernel source with every section: text
    // sections end at a NUL and the next starts on the following 4-byte
    // boundary; the SPIR-V section, which is always last, says its length
    // in words in its header (`spirv=<n>`), after the header line.
    static u32 sourceLength(u8* src)
        {
        if (src == (u8*)0)
            return (u32)0;
        u32 at = (u32)0;
        while (true)
            {
            // The header line of this section.
            u32 words = (u32)0;
            bool spirv = false;
            u32 h = at;
            while (src[h] != (u8)0 && src[h] != (u8)10)
                {
                if (src[h] == (u8)'s' && src[h + (u32)1] == (u8)'p' && src[h + (u32)5] == (u8)'=')
                    {
                    spirv = true;
                    u32 q = h + (u32)6;
                    while (src[q] >= (u8)'0' && src[q] <= (u8)'9')
                        {
                        words = words * (u32)10 + (u32)(src[q] - (u8)'0');
                        q = q + (u32)1;
                        }
                    }
                h = h + (u32)1;
                }
            // The words start at the 4-byte boundary after the header's NUL,
            // where ParVulkan.pipeline reads them. Counting from the NUL alone
            // cut the copy a far daemon got by up to three bytes: its module
            // ended in whatever followed, and RADV crashed compiling it.
            if (spirv)
                {
                while (src[h] != (u8)0)
                    h = h + (u32)1;
                return ((h + (u32)4) & ~(u32)3) + words * (u32)4;
                }
            // A text section: to its NUL.
            while (src[at] != (u8)0)
                at = at + (u32)1;
            u32 next = (at + (u32)4) & ~(u32)3;
            if (!(src[next] == (u8)'/' && src[next + (u32)1] == (u8)'/'))
                return at + (u32)1;
            at = next;
            }
        return at;
        }

    // The block described for the far side: its name, its kernel source,
    // and its arrays and globals — lengths and flags, and with `data`, the
    // object's bytes and every array's and global's bytes.
    // data: the chunk's object bytes go too; arrays: so do the whole (not
    // sliced) arrays' and globals' bytes. PREPARE sends the object and the
    // arrays' hashes (field HASHES), the bytes only for what the daemon's
    // cache lacks (frame DATA); HOLDS sends neither.
    static Data* describe(ParChunk* proto, u8* src, ParLayout* l, bool data, bool arrays)
        {
        Data* d = new Data();
        ParWire.putStr(d, proto.parName());
        ParWire.putBytes(d, src, ParWire.sourceLength(src));
        u8* obj = proto.objBytes();
        ParWire.putU32(d, (u32)l.size);
        if (data)
            d.appendBytes(obj, (u32)l.size);
        ParWire.putU32(d, l.nbuf);
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            ParWire.putU32(d, (u32)l.bufOff[i]);
            ParWire.putI64(d, l.bufIvar[i]);
            ParWire.putI64(d, l.bufLen[i]);
            ParWire.putU8(d, l.bufIn[i] != (i64)0 ? (u8)1 : (u8)0);
            // Sliced: its footprint is known, so each tile brings the
            // elements it reads and the whole array stays home.
            ParWire.putU8(d, l.bufFp[i] != (i64)0 ? (u8)1 : (u8)0);
            if (arrays && l.bufFp[i] == (i64)0)
                d.appendBytes(*(u8**)(obj + l.bufOff[i]), (u32)l.bufLen[i]);
            }
        ParWire.putU32(d, l.nglob);
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            ParWire.putStr(d, &l.globName[i * (u32)64]);
            ParWire.putI64(d, l.globLen[i]);
            ParWire.putU8(d, l.globIn[i] != (i64)0 ? (u8)1 : (u8)0);
            ParWire.putU8(d, l.globAll[i] != (i64)0 ? (u8)1 : (u8)0);
            ParWire.putU8(d, l.globFp[i] != (i64)0 ? (u8)1 : (u8)0);
            if (arrays && l.globFp[i] == (i64)0)
                d.appendBytes((u8*)l.globPtr[i], (u32)l.globLen[i]);
            }
        return d;
        }
    }

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)

// ── The program's side ──────────────────────────────────────────────────

class ParRemoteWorker : ParWorker
    {
    String* _host;
    u16 _port;
    ParLink* _s;            // the command link: tiles and requests out, answers back
    ParLink* _r;            // the results link: finished tiles, written by a thread of the daemon's
    i64 _vramTotal;         // the daemon's figures from HELLO, bytes; 0 unknown
    i64 _vramFree;
    i64 _ramTotal;
    i64 _ramFree;
    i64 _kernelUs;          // the daemon's time on this run's tiles, summed from DONE
    i64 _kernelItems;
    String* _identity;      // "remote:<host>:<the daemon's device>", "" when unreachable
    u32 _depth;
    i64 _floor;
    bool _tried;
    // The link and the daemon's availability, from the heartbeat.
    i64 _rttUs;             // the round trip, from the last heartbeat
    i64 _bwBytesPerUs;      // upload bandwidth, from the probe at connect; 0 unknown
    i64 _lastPing;          // when the last ping went (this clock, us); 0 none
    i64 _lastPong;          // when the last pong came
    bool _available;        // the daemon's last word
    u32 _queued;            // and the tiles waiting there (PONG's QUEUED)
    i64 _sizedFloor;        // the tile floor the link's latency asks for this block
    Array* _finished;       // tiles completed while reading for a pong, for poll()
    // The run in progress.
    ParChunk* _proto;
    ParLayout* _l;
    u32 _inFlight;
    Array* _tiles;          // ParTile, by their order of taking
    Array* _lostTiles;      // tiles in flight when the connection died, for lost()
    bool _dead;             // the connection died
    // What the daemon last answered holds() for, so a block is asked once.
    pointer _heldSrc;
    bool _held;
    // The daemon's slice cache as this side knows it: slice key -> the hash
    // last sent or returned, per connection. A slice whose hash matches is
    // sent as its hash alone; a MISS (evicted) brings the tile back with
    // its bytes.
    Map* _view;
    u8* _src;
    bool _resend;           // the tile being taken again after a MISS: bytes regardless
    bool _noRoom;           // the daemon refused a tile this run for want of device memory
    i64 _savedBytes;        // this run: bytes the view let us leave out
    i64 _savedSlices;
    i64 _sentSlices;

    void init(String* host, u16 port)
        {
        _host = host;
        _port = port;
        _depth = (u32)PAR_REMOTE_DEPTH;
        _floor = (i64)1024;
        _identity = new String();
        _tiles = new Array();
        _finished = new Array();
        _view = new Map();
        _available = true;
        }

    // A TLS link to the daemon, its certificate checked against the pin
    // kept in the par settings under tls.pin.<host>:<port>: the fingerprint
    // seen first is kept, and a daemon showing another one later is refused
    // until the user removes the pin. Null, with the reason reported, when
    // the link could not be made.
    ParLink* open(void)
        {
        Socket* sock = (Socket*)0;
        try
            {
            sock = Socket.connect(_host, _port);
            }
        catch (SocketError e)
            {
            if (ParDevice.reporting())
                Log.info("par: remote %s: %s", _host.cString(), e.message().cString());
            return (ParLink*)0;
            }
        // Small frames, each answered: no Nagle wait on them.
        sock.setNoDelay();
        ParLink* link = new ParLink(sock);
        String* why = (String*)0;
        if (!ParTls.load())
            why = String.withCString("no TLS library here (a daemon takes TLS only)");
        else if (!link.connect(_host.cString()))
            why = String.withCString("the TLS handshake failed");
        if (why == (String*)0)
            {
            String* fp = link.fingerprint();
            String* key = String.withCString("tls.pin.");
            key.append(_host);
            key.appendCString(":");
            key.append(String.withU32((u32)_port));
            Settings* st = Settings.standard(String.withCString("par"));
            String* known = st.get(key);
            if (fp.byteLength() == (u32)0)
                why = String.withCString("the daemon sent no certificate");
            else if (known == (String*)0)
                {
                st.set(key, fp);
                st.save();
                if (ParDevice.reporting())
                    Log.info("par: remote %s: certificate %s pinned as %s", _host.cString(), fp.cString(), key.cString());
                }
            else if (!known.equals(fp))
                {
                why = String.withCString("certificate changed (now ");
                why.append(fp);
                why.appendCString("): remove ");
                why.append(key);
                why.appendCString(" from ");
                why.append(st.path() != (String*)0 ? st.path() : String.withCString("the par settings"));
                why.appendCString(" to trust it again");
                }
            }
        if (why != (String*)0)
            {
            if (ParDevice.reporting())
                Log.info("par: remote %s: %s", _host.cString(), why.cString());
            link.close();
            return (ParLink*)0;
            }
        return link;
        }

    // Connect and shake hands, once. The identity is "" after a failure.
    bool connect(void)
        {
        if (_s != (ParLink*)0 && _s.isOpen())
            return true;
        if (_tried)
            return false;
        _tried = true;
        _s = open();
        if (_s == (ParLink*)0)
            return false;
        _view = new Map();
        u8 tag[8];
        Data* hello = ParWire.recv(_s, &tag[0], (i32)5000);
        if (hello == (Data*)0 || !ParWire.tagIs(&tag[0], "HELLO"))
            return fail("no greeting");
        u32 proto = ParWire.getU32(hello, "PROTO", (u32)0);
        u8* nonce = (u8*)0;
        u32 nn = (u32)0;
        if (!ParWire.find(hello, "NONCE", &nonce, &nn) || nn != (u32)32)
            return fail("not an xcd");
        String* version = ParWire.getStr(hello, "VERSION");
        String* ident = ParWire.getStr(hello, "IDENT");
        _depth = ParWire.getU32(hello, "DEPTH", (u32)PAR_REMOTE_DEPTH);
        _floor = ParWire.getI64(hello, "FLOOR", (i64)1024);
        _vramTotal = ParWire.getI64(hello, "VRAMTOT", (i64)0);
        _vramFree = ParWire.getI64(hello, "VRAMFREE", (i64)0);
        _ramTotal = ParWire.getI64(hello, "RAMTOT", (i64)0);
        _ramFree = ParWire.getI64(hello, "RAMFREE", (i64)0);
        if (proto != (u32)PAR_REMOTE_PROTO)
            return fail("another protocol version");
        if (version == (String*)0 || ident == (String*)0 || !version.equals(String.withCString(PAR_CACHE_VER)))
            return fail("another xcc version");
        Data* auth = new Data();
        ParWire.fieldU32(auth, "PROTO", (u32)PAR_REMOTE_PROTO);
        ParWire.fieldStr(auth, "VERSION", PAR_CACHE_VER);
        Data* proof = ParRemote.proof(nonce);
        ParWire.field(auth, "PROOF", proof.bytes(), (u32)32);
        if (!ParWire.send(_s, "AUTH", auth))
            return fail("the daemon went away");
        Data* ok = ParWire.recv(_s, &tag[0], (i32)5000);
        u8* token = (u8*)0;
        u32 tn = (u32)0;
        if (ok == (Data*)0 || !ParWire.tagIs(&tag[0], "OK") || !ParWire.find(ok, "TOKEN", &token, &tn) || tn != (u32)32)
            return fail("the daemon declined the pool secret");
        Data* tokenD = Data.withBytes(token, (u32)32);
        // The results link, named to the daemon by the session token it
        // answered with.
        _r = open();
        if (_r == (ParLink*)0)
            return fail("no results link");
        Data* hello2 = ParWire.recv(_r, &tag[0], (i32)5000);
        if (hello2 == (Data*)0 || !ParWire.tagIs(&tag[0], "HELLO"))
            return fail("no greeting on the results link");
        Data* rq = new Data();
        ParWire.field(rq, "TOKEN", tokenD.bytes(), (u32)32);
        if (!ParWire.send(_r, "RESULTS", rq))
            return fail("the daemon went away");
        Data* ok2 = ParWire.recv(_r, &tag[0], (i32)5000);
        if (ok2 == (Data*)0 || !ParWire.tagIs(&tag[0], "OK"))
            return fail("the daemon declined the results link");
        _identity = String.withCString("remote:");
        _identity.append(_host);
        _identity.appendCString(":");
        _identity.append(ident);
        if (ParDevice.reporting())
            {
            if (_vramTotal > (i64)0)
                Log.info("par: remote worker %s, depth %u, %ld MB of %ld MB VRAM free, %ld MB of %ld MB RAM free", _identity.cString(), _depth,
                         _vramFree >> (i64)20, _vramTotal >> (i64)20, _ramFree >> (i64)20, _ramTotal >> (i64)20);
            else
                Log.info("par: remote worker %s, depth %u", _identity.cString(), _depth);
            }
        _available = true;
        _lastPong = ParDevice.nowUs();
        return probeLink();
        }
    // The link, measured once: a heartbeat's round trip, then a ping padded
    // to a megabyte for the upload bandwidth (the daemon echoes the stamp
    // alone, so the second round trip less the first is the upload).
    bool probeLink(void)
        {
        i64 t0 = ParDevice.nowUs();
        if (!ping((u8)0, (u32)0) || !awaitPong())
            return fail("no heartbeat");
        i64 t1 = ParDevice.nowUs();
        _rttUs = t1 - t0;
        if (_rttUs < (i64)1)
            _rttUs = (i64)1;
        if (!ping((u8)1, (u32)PAR_REMOTE_PROBE_BYTES) || !awaitPong())
            return fail("no heartbeat");
        i64 up = (ParDevice.nowUs() - t1) - _rttUs;
        if (up < (i64)1)
            up = (i64)1;
        _bwBytesPerUs = (i64)PAR_REMOTE_PROBE_BYTES / up;
        if (ParDevice.reporting())
            Log.info("par: remote %s: %ld us round trip, %ld MB/s up", _host.cString(), _rttUs, _bwBytesPerUs);
        return true;
        }
    bool ping(u8 kind, u32 pad)
        {
        Data* d = new Data();
        ParWire.fieldI64(d, "SENT", ParDevice.nowUs());
        ParWire.fieldU8(d, "KIND", kind);
        if (pad > (u32)0)
            {
            Data* z = Data.withLength(pad);
            ParWire.fieldData(d, "PAD", z);
            }
        _lastPing = ParDevice.nowUs();
        return ParWire.send(_s, "PING", d);
        }
    // Frames until a pong.
    bool awaitPong(void)
        {
        i64 before = _lastPong;
        while (_lastPong == before && _s != (ParLink*)0 && _s.isOpen())
            {
            if (!_s.waitReadable((i32)5000))
                return false;
            if (!readFrame())
                return false;
            }
        return _lastPong != before;
        }
    void pong(Data* f)
        {
        i64 sent = ParWire.getI64(f, "SENT", (i64)0);
        u8 kind = ParWire.getU8(f, "KIND", (u8)0);
        _available = ParWire.getU8(f, "AVAILABLE", (u8)1) != (u8)0;
        _queued = ParWire.getU32(f, "QUEUED", (u32)0);
        _lastPong = ParDevice.nowUs();
        if (kind == (u8)0 && _lastPong - sent > (i64)0)
            _rttUs = _lastPong - sent;
        }
    // One frame on the command link: a pong. False when the connection is
    // lost.
    bool readFrame(void)
        {
        u8 tag[8];
        Data* f = ParWire.recv(_s, &tag[0], (i32)-1);
        if (f == (Data*)0)
            {
            fail("lost the connection");
            return false;
            }
        if (ParWire.tagIs(&tag[0], "PONG"))
            {
            pong(f);
            return true;
            }
        fail("an unexpected frame mid-run");
        return false;
        }
    // The answer to a request on the control link. A heartbeat's PONG can
    // come first: ready() pings every second while the queue dispatches, and
    // a run that ends before the answer leaves it for the next request to
    // read. Taken for the PONG it is, not the answer: read as NEED it failed
    // the next run's prepare, and the worker sat out every later run of the
    // program (mandel_deep from the Mac fell back to its own GPU after a
    // second of runs, 2026-10-17).
    Data* reply(u8* tag, i32 ms)
        {
        while (true)
            {
            Data* f = ParWire.recv(_s, tag, ms);
            if (f == (Data*)0 || !ParWire.tagIs(tag, "PONG"))
                return f;
            pong(f);
            }
        return (Data*)0;
        }
    // One finished tile from the results link, completed and kept for
    // poll(). False when the link is lost.
    bool readResult(void)
        {
        u8 tag[8];
        Data* f = ParWire.recv(_r, &tag[0], (i32)-1);
        if (f == (Data*)0 || !ParWire.tagIs(&tag[0], "DONE"))
            {
            fail("lost the results link");
            return false;
            }
        if (ParWire.getU8(f, "REFUSED", (u8)0) != (u8)0)
            {
            // The daemon's device memory is full: the tile goes back to the
            // queue for another worker, and this one takes no more this run.
            i64 index = ParWire.getI64(f, "INDEX", (i64)-1);
            for (u32 i = (u32)0; i < _tiles.count(); i = i + (u32)1)
                if (((ParTile*)_tiles.get(i)).index == index)
                    {
                    if (_lostTiles == (Array*)0)
                        _lostTiles = new Array();
                    _lostTiles.add(_tiles.get(i));
                    _tiles.removeAt(i);
                    _inFlight = _inFlight - (u32)1;
                    break;
                    }
            if (!_noRoom && ParDevice.reporting())
                Log.info("par: remote %s: tile %ld refused, the daemon's device memory is full; it goes elsewhere", _host.cString(), index);
            _noRoom = true;
            return true;
            }
        if (ParWire.getU8(f, "MISS", (u8)0) != (u8)0)
            {
            // The daemon's cache had dropped a slice the view said it held:
            // the tile goes again with every byte.
            i64 index = ParWire.getI64(f, "INDEX", (i64)-1);
            ParTile* m = (ParTile*)0;
            for (u32 i = (u32)0; i < _tiles.count(); i = i + (u32)1)
                if (((ParTile*)_tiles.get(i)).index == index)
                    {
                    m = (ParTile*)_tiles.get(i);
                    _tiles.removeAt(i);
                    break;
                    }
            if (m == (ParTile*)0)
                return true;
            _inFlight = _inFlight - (u32)1;
            _resend = true;
            bool ok = take(m, _proto, _src, _l);
            _resend = false;
            if (!ok)
                {
                _tiles.add((Object*)m);
                _inFlight = _inFlight + (u32)1;
                fail("could not send a tile again after the daemon's cache dropped its slices");
                return false;
                }
            if (ParDevice.tracing())
                Log.info("par: remote %s: tile %ld sent again, its slices gone from the daemon's cache", _host.cString(), index);
            return true;
            }
        ParTile* t = complete(f);
        if (t != (ParTile*)0)
            _finished.add((Object*)t);
        return true;
        }
    // The daemon's last word, re-asked by a heartbeat every second while the
    // queue is dispatching; not ready either when a ping has gone unanswered
    // for five seconds (the queue then hands its tiles elsewhere; the ones
    // in flight are waited for by drain()).
    bool ready(i64 now)
        {
        if (_s == (ParLink*)0 || !_s.isOpen() || _r == (ParLink*)0 || !_r.isOpen())
            return false;
        while (_s.waitReadable((i32)0))
            if (!readFrame())
                return false;
        if (now - _lastPing > (i64)1000000)
            ping((u8)0, (u32)0);
        if (_lastPing > _lastPong && now - _lastPing > (i64)5000000)
            return false;
        return _available && !_noRoom;
        }
    bool fail(u8* why)
        {
        if (ParDevice.reporting())
            Log.info("par: remote %s: %s", _host.cString(), why);
        if (_s != (ParLink*)0)
            _s.close();
        if (_r != (ParLink*)0)
            _r.close();
        _identity = new String();
        _dead = true;
        // The tiles it was running are never coming back: the queue
        // re-issues them (a tile is idempotent: its writes are its own
        // slices, its partials are folded only once it is done).
        if (_tiles != (Array*)0 && _tiles.count() > (u32)0)
            {
            if (_lostTiles == (Array*)0)
                _lostTiles = new Array();
            for (u32 i = (u32)0; i < _tiles.count(); i = i + (u32)1)
                _lostTiles.add(_tiles.get(i));
            _tiles = new Array();
            }
        _inFlight = (u32)0;
        return false;
        }
    // The link and the daemon as the last heartbeat saw them (xcmon).
    i64 rttUs(void)
        {
        return _rttUs;
        }
    bool available(void)
        {
        return _available;
        }
    u32 queued(void)
        {
        return _queued;
        }
    i64 vramTotal(void)
        {
        return _vramTotal;
        }
    i64 vramFree(void)
        {
        return _vramFree;
        }
    i64 ramTotal(void)
        {
        return _ramTotal;
        }
    i64 ramFree(void)
        {
        return _ramFree;
        }
    // A heartbeat on an idle link: the round trip and the daemon's word.
    // False when the daemon has gone.
    bool heartbeat(void)
        {
        if (_s == (ParLink*)0 || !_s.isOpen())
            return false;
        if (!ping((u8)0, (u32)0))
            return false;
        return awaitPong();
        }
    i64 kernelUs(void)
        {
        return _kernelUs;
        }
    Array* lost(void)
        {
        Array* l = _lostTiles;
        _lostTiles = (Array*)0;
        return l;
        }
    bool dead(void)
        {
        return _dead;
        }

    String* identity(void)
        {
        connect();
        return _identity;
        }
    u32 depth(void)
        {
        return _depth;
        }
    i64 floor(void)
        {
        return _sizedFloor > _floor ? _sizedFloor : _floor;
        }
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        if (src == (u8*)0 || src[0] == (u8)0 || l == (ParLayout*)0 || !connect())
            return false;
        if (_heldSrc == (pointer)src)
            return _held;
        _heldSrc = (pointer)src;
        _held = false;
        Data* q = new Data();
        ParWire.fieldData(q, "BLOCK", ParWire.describe(proto, src, l, false, false));
        if (!ParWire.send(_s, "HOLDS", q))
            return false;
        u8 tag[8];
        Data* a = reply(&tag[0], (i32)30000);
        u8 taken = a != (Data*)0 && ParWire.tagIs(&tag[0], "ANSWER") ? ParWire.getU8(a, "TAKEN", (u8)0) : (u8)0;
        _held = taken == (u8)1;
        // 2: the daemon's GPUs are another program's just now — not a
        // verdict on the block, so it is asked again next run.
        if (taken == (u8)2)
            _heldSrc = (pointer)0;
        if (ParDevice.reporting() && !_held)
            Log.info("par: %s does not take %s%s", _identity.cString(), proto.parName(),
                     _heldSrc == (pointer)0 ? " just now (busy)" : "");
        // The tile floor the link asks for: a tile's bytes (each sliced
        // array's and global's element, there or back) take at least twenty
        // round trips to move, so the latency is five percent of it at most.
        _sizedFloor = (i64)0;
        if (_held && _rttUs > (i64)0 && _bwBytesPerUs > (i64)0)
            {
            i64 per = (i64)0;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                if (l.bufFp[i] != (i64)0)
                    per = per + l.bufElem[i];
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                if (l.globFp[i] != (i64)0)
                    per = per + l.globElem[i];
            if (per > (i64)0)
                _sizedFloor = (((i64)20 * _rttUs * _bwBytesPerUs) / per + (i64)1023) & ~(i64)1023;
            }
        return _held;
        }
    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        if (!connect())
            return false;
        _proto = proto;
        _l = l;
        _inFlight = (u32)0;
        _tiles = new Array();
        _kernelUs = (i64)0;
        _kernelItems = (i64)0;
        _src = src;
        _noRoom = false;
        _savedBytes = (i64)0;
        _savedSlices = (i64)0;
        _sentSlices = (i64)0;
        Data* d = new Data();
        ParWire.fieldData(d, "BLOCK", ParWire.describe(proto, src, l, true, false));
        ParWire.fieldI64(d, "TILE", tile);
        ParWire.fieldI64(d, "N", l.n);
        // The whole arrays by hash; the daemon says which it lacks.
        Data* hs = new Data();
        u8* obj = proto.objBytes();
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufFp[i] == (i64)0)
                {
                ParWire.putU8(hs, (u8)0);
                ParWire.putU32(hs, i);
                ParWire.putI64(hs, l.bufLen[i]);
                ParWire.putI64(hs, (i64)ParWire.hash64(*(u8**)(obj + l.bufOff[i]), (u32)l.bufLen[i]));
                }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globFp[i] == (i64)0)
                {
                ParWire.putU8(hs, (u8)1);
                ParWire.putU32(hs, i);
                ParWire.putI64(hs, l.globLen[i]);
                ParWire.putI64(hs, (i64)ParWire.hash64((u8*)l.globPtr[i], (u32)l.globLen[i]));
                }
        ParWire.fieldData(d, "HASHES", hs);
        if (!ParWire.send(_s, "PREPARE", d))
            return false;
        u8 tag[8];
        Data* nd = reply(&tag[0], (i32)60000);
        if (nd == (Data*)0 || !ParWire.tagIs(&tag[0], "NEED"))
            return false;
        Data* arrays = new Data();
        u8* np = (u8*)0;
        u32 nn = (u32)0;
        u32 na = (u32)0;
        i64 wholeBytes = (i64)0;
        i64 wholeSent = (i64)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufFp[i] == (i64)0) wholeBytes = wholeBytes + l.bufLen[i];
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globFp[i] == (i64)0) wholeBytes = wholeBytes + l.globLen[i];
        if (ParWire.find(nd, "LIST", &np, &nn))
            while (na + (u32)5 <= nn)
                {
                u8 kind = ParWire.rdU8(np, &na);
                u32 idx = ParWire.rdU32(np, &na);
                ParWire.putU8(arrays, kind);
                ParWire.putU32(arrays, idx);
                if (kind == (u8)0 && idx < l.nbuf)
                    {
                    ParWire.putBytes(arrays, *(u8**)(obj + l.bufOff[idx]), (u32)l.bufLen[idx]);
                    wholeSent = wholeSent + l.bufLen[idx];
                    }
                else if (kind != (u8)0 && idx < l.nglob)
                    {
                    ParWire.putBytes(arrays, (u8*)l.globPtr[idx], (u32)l.globLen[idx]);
                    wholeSent = wholeSent + l.globLen[idx];
                    }
                else
                    ParWire.putBytes(arrays, (u8*)0, (u32)0);
                }
        _savedBytes = _savedBytes + (wholeBytes - wholeSent);
        Data* dd = new Data();
        ParWire.fieldData(dd, "ARRAYS", arrays);
        if (!ParWire.send(_s, "DATA", dd))
            return false;
        Data* a = reply(&tag[0], (i32)60000);
        if (a == (Data*)0 || !ParWire.tagIs(&tag[0], "ANSWER"))
            return false;
        u8 taken = ParWire.getU8(a, "TAKEN", (u8)0);
        if (taken == (u8)3 && ParDevice.reporting())
            Log.info("par: remote %s does not take %s: it needs %ld MB of device memory there, %ld MB are free",
                     _host.cString(), proto.parName(), ParWire.getI64(a, "NEEDMB", (i64)0), ParWire.getI64(a, "FREEMB", (i64)0));
        return taken == (u8)1;
        }
    void finish(void)
        {
        if (_s != (ParLink*)0 && _s.isOpen())
            ParWire.send(_s, "FINISH", (Data*)0);
        if (ParDevice.reporting() && _kernelItems > (i64)0)
            Log.info("par: remote %s: %ld items in %ld us on the daemon's GPU (%ld ns an item)", _host.cString(),
                     _kernelItems, _kernelUs, _kernelUs * (i64)1000 / _kernelItems);
        if (ParDevice.reporting() && _savedBytes > (i64)0)
            Log.info("par: remote %s: %ld KB not sent, cached on the daemon (%ld of %ld slices)", _host.cString(),
                     _savedBytes >> (i64)10, _savedSlices, _savedSlices + _sentSlices);
        _proto = (ParChunk*)0;
        _l = (ParLayout*)0;
        }
    // The tile's slice hashes, once per tile (every remote reads them).
    static void hashTile(ParTile* t, ParChunk* proto, ParLayout* l)
        {
        if (t.hashed)
            return;
        u32 hk = (u32)0;
        u8* obj = proto.objBytes();
        for (u32 i = (u32)0; i < l.nbuf && hk < (u32)32; i = i + (u32)1)
            {
            if (l.bufFp[i] == (i64)0)
                continue;
            i64 count = l.bufLen[i] / l.bufElem[i];
            i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
            u32 n = e1 > e0 ? (u32)((e1 - e0) * l.bufElem[i]) : (u32)0;
            t.sliceHash[hk] = n > (u32)0 ? ParWire.hash64(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i], n) : (u64)0;
            hk = hk + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob && hk < (u32)32; i = i + (u32)1)
            {
            if (l.globFp[i] == (i64)0)
                continue;
            i64 count = l.globLen[i] / l.globElem[i];
            i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
            if (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1)
                e1 = e0;
            u32 n = e1 > e0 ? (u32)((e1 - e0) * l.globElem[i]) : (u32)0;
            t.sliceHash[hk] = n > (u32)0 ? ParWire.hash64((u8*)l.globPtr[i] + e0 * l.globElem[i], n) : (u64)0;
            hk = hk + (u32)1;
            }
        t.sliceCount = hk;
        t.hashed = true;
        }
    static String* viewKey(bool glob, u32 i, i64 off, u32 n)
        {
        return String.withFormat("%ld:%ld:%ld:%ld", glob ? (i64)1 : (i64)0, (i64)i, off, (i64)n);
        }
    bool viewHolds(bool glob, u32 i, i64 off, u32 n, u64 h)
        {
        String* v = (String*)_view.get((Hashable*)ParRemoteWorker.viewKey(glob, i, off, n));
        return v != (String*)0 && v.equals(String.withFormat("%ld", (i64)h));
        }
    // One slice into a TILE frame: offset, length, hash, then whether the
    // bytes follow — not when the view says the daemon holds them.
    void putSlice(Data* sl, bool glob, u32 i, i64 off, u8* p, u32 n, u64 h)
        {
        ParWire.putI64(sl, off);
        ParWire.putI64(sl, (i64)n);
        ParWire.putI64(sl, (i64)h);
        if (n > (u32)0 && !_resend && viewHolds(glob, i, off, n, h))
            {
            if (ParDevice.tracing())
                Log.info("par: remote %s: slice %s held at %ld, not sent", _host.cString(), ParRemoteWorker.viewKey(glob, i, off, n).cString(), (i64)h);
            ParWire.putU8(sl, (u8)0);
            _savedBytes = _savedBytes + (i64)n;
            _savedSlices = _savedSlices + (i64)1;
            return;
            }
        ParWire.putU8(sl, (u8)1);
        ParWire.putBytes(sl, p, n);
        if (n > (u32)0)
            {
            _view.set((Hashable*)ParRemoteWorker.viewKey(glob, i, off, n), (Object*)String.withFormat("%ld", (i64)h));
            _sentSlices = _sentSlices + (i64)1;
            }
        }
    // The upload this tile would not need, when the daemon holds every
    // slice of it: its bytes over the link's bandwidth.
    i64 cachedSaving(ParTile* t)
        {
        if (_bwBytesPerUs <= (i64)0 || _proto == (ParChunk*)0 || _l == (ParLayout*)0)
            return (i64)0;
        ParLayout* l = _l;
        ParRemoteWorker.hashTile(t, _proto, l);
        u32 hk = (u32)0;
        i64 bytes = (i64)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] == (i64)0)
                continue;
            i64 count = l.bufLen[i] / l.bufElem[i];
            i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
            u32 n = e1 > e0 ? (u32)((e1 - e0) * l.bufElem[i]) : (u32)0;
            if (n > (u32)0 && !viewHolds(false, i, e0 * l.bufElem[i], n, t.sliceHash[hk]))
                return (i64)0;
            bytes = bytes + (i64)n;
            hk = hk + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] == (i64)0)
                continue;
            i64 count = l.globLen[i] / l.globElem[i];
            i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
            if (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1)
                e1 = e0;
            u32 n = e1 > e0 ? (u32)((e1 - e0) * l.globElem[i]) : (u32)0;
            if (n > (u32)0 && !viewHolds(true, i, e0 * l.globElem[i], n, t.sliceHash[hk]))
                return (i64)0;
            bytes = bytes + (i64)n;
            hk = hk + (u32)1;
            }
        return bytes / _bwBytesPerUs;
        }
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_inFlight >= _depth || _s == (ParLink*)0 || !_s.isOpen())
            return false;
        Data* d = new Data();
        ParWire.fieldI64(d, "INDEX", t.index);
        ParWire.fieldI64(d, "LO", t.lo);
        ParWire.fieldI64(d, "HI", t.hi);
        // Each sliced array's and global's slice for this tile: its byte
        // offset, then the bytes — none for a global the tile's items
        // overwrite whole (the kernel fills it), as a discrete card's
        // tile loop stages them.
        Data* sl = new Data();
        ParRemoteWorker.hashTile(t, proto, l);
        u32 hk = (u32)0;
        u8* obj = proto.objBytes();
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] == (i64)0)
                continue;
            i64 count = l.bufLen[i] / l.bufElem[i];
            i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
            putSlice(sl, false, i, e0 * l.bufElem[i], *(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i],
                     e1 > e0 ? (u32)((e1 - e0) * l.bufElem[i]) : (u32)0, t.sliceHash[hk]);
            hk = hk + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] == (i64)0)
                continue;
            i64 count = l.globLen[i] / l.globElem[i];
            i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
            if (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1)
                e1 = e0;
            putSlice(sl, true, i, e0 * l.globElem[i], (u8*)l.globPtr[i] + e0 * l.globElem[i],
                     e1 > e0 ? (u32)((e1 - e0) * l.globElem[i]) : (u32)0, t.sliceHash[hk]);
            hk = hk + (u32)1;
            }
        ParWire.fieldData(d, "SLICES", sl);
        if (!ParWire.send(_s, "TILE", d))
            return false;
        t.worker = (ParWorker*)self;
        _tiles.add((Object*)t);
        _inFlight = _inFlight + (u32)1;
        return true;
        }
    // A finished tile's frame: its written slices into the program's arrays
    // and globals, its partials folded into a chunk copy, and the daemon's
    // time on it.
    ParTile* complete(Data* f)
        {
        i64 index = ParWire.getI64(f, "INDEX", (i64)-1);
        ParTile* t = (ParTile*)0;
        for (u32 i = (u32)0; i < _tiles.count(); i = i + (u32)1)
            if (((ParTile*)_tiles.get(i)).index == index)
                {
                t = (ParTile*)_tiles.get(i);
                _tiles.removeAt(i);
                break;
                }
        if (t == (ParTile*)0)
            return (ParTile*)0;
        ParLayout* l = _l;
        u8* obj = _proto.objBytes();
        u8* p = (u8*)0;
        u32 pn = (u32)0;
        ParWire.find(f, "SLICES", &p, &pn);
        u32 at = (u32)0;
        for (u32 i = (u32)0; i < l.nbuf && p != (u8*)0; i = i + (u32)1)
            {
            if (l.bufIn[i] != (i64)0 || l.bufFp[i] == (i64)0)
                continue;
            i64 e0 = ParWire.rdI64(p, &at);
            i64 e1 = ParWire.rdI64(p, &at);
            u8* b = (u8*)0;
            u32 n = ParWire.rdBytes(p, &at, &b);
            if (e1 > e0 && n == (u32)((e1 - e0) * l.bufElem[i]))
                memcpy((pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]), (pointer)b, (u64)n);
            i64 wh = ParWire.rdI64(p, &at);
            if (n > (u32)0)
                _view.set((Hashable*)ParRemoteWorker.viewKey(false, i, e0 * l.bufElem[i], n), (Object*)String.withFormat("%ld", wh));
            }
        for (u32 i = (u32)0; i < l.nglob && p != (u8*)0; i = i + (u32)1)
            {
            if (l.globIn[i] != (i64)0 || l.globFp[i] == (i64)0)
                continue;
            i64 e0 = ParWire.rdI64(p, &at);
            i64 e1 = ParWire.rdI64(p, &at);
            u8* b = (u8*)0;
            u32 n = ParWire.rdBytes(p, &at, &b);
            if (e1 > e0 && n == (u32)((e1 - e0) * l.globElem[i]))
                memcpy((pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]), (pointer)b, (u64)n);
            i64 wh = ParWire.rdI64(p, &at);
            if (n > (u32)0)
                _view.set((Hashable*)ParRemoteWorker.viewKey(true, i, e0 * l.globElem[i], n), (Object*)String.withFormat("%ld", wh));
            }
        if (l.nred > (u32)0)
            {
            u8* raw = (u8*)0;
            u32 rn = (u32)0;
            ParWire.find(f, "PARTS", &raw, &rn);
            i64 nback = ParWire.getI64(f, "NBACK", (i64)0);
            u8* parts[16];
            u32 off = (u32)0;
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                {
                parts[r] = raw + off;
                off = off + (u32)(nback * l.redStride[r]);
                }
            ParChunk* c = _proto.copyChunk();
            l.foldN(c, &parts[0], nback);
            t.partial = c;
            }
        t.usTaken = ParWire.getI64(f, "KERNELUS", (i64)0);
        _kernelUs = _kernelUs + t.usTaken;
        _kernelItems = _kernelItems + (t.hi - t.lo);
        t.done = true;
        _inFlight = _inFlight - (u32)1;
        return t;
        }
    // The results link: poll returned nothing, so it holds no decrypted
    // bytes, and a frame arriving makes the socket readable.
    i64 waitFd(void)
        {
        return _r != (ParLink*)0 ? _r.fd() : (i64)-1;
        }
    ParTile* poll(void)
        {
        while (_finished.count() == (u32)0 && _inFlight > (u32)0 && _r != (ParLink*)0 && _r.isOpen() && _r.waitReadable((i32)0))
            if (!readResult())
                break;
        if (_finished.count() == (u32)0)
            return (ParTile*)0;
        ParTile* t = (ParTile*)_finished.get((u32)0);
        _finished.removeAt((u32)0);
        return t;
        }
    void drain(void)
        {
        while (_inFlight > (u32)0 && _r != (ParLink*)0 && _r.isOpen())
            {
            _r.waitReadable((i32)-1);
            if (!readResult())
                break;
            }
        // Tiles a dead connection never returned are not done: the queue's
        // loop ends with them pending and the run fails on, which is the
        // honest outcome until tiles are re-issued (idempotent tiles, step 3).
        }
    }

// One connection on a thread of the daemon's (xcd spawns one per accept).
class ParRemoteConnection : Object
    {
    ParLink* _s;
    Array* _workers;
    String* _identity;
    Atomic* _done;      // 1 once the program has gone: the daemon may drop the object
    void init(Socket* s, Array* workers, String* identity)
        {
        _s = new ParLink(s);
        _workers = workers;
        _identity = identity;
        _done = new Atomic();
        }
    bool done(void)
        {
        return _done.load() != (i32)0;
        }
    void run(void)
        {
        ParRemoteServe.serve(_s, _workers, _identity);
        _s.close();
        _done.store((i32)1);
        }
    }

// ── Shared ──────────────────────────────────────────────────────────────

class ParRemote
    {
    // The proof of the pool secret for a nonce: SHA-256(nonce || secret).
    // A daemon started with no secret takes any proof, so a pool on a shared
    // subnet should set one.
    static Data* proof(u8* nonce)
        {
        String* secret = Platform.env(String.withCString("XC_PAR_SECRET"));
        Data* d = Data.withBytes(nonce, (u32)32);
        d.appendBytes(secret.cString(), secret.byteLength());
        return Sha256.of(d.bytes(), d.length());
        }

    // XC_PAR_REMOTE=host[:port],host[:port],…: a worker per entry. An entry
    // `mdns` is every daemon on this subnet that answers within 300 ms and
    // is of the pool XC_PAR_POOL names (none when unset) and this xcc
    // version. With no setting at all, discovery is ON (owner 2026-10-16:
    // it simplifies people's lives): the program browses once, at its first
    // par run, and takes what it finds; `XC_PAR_REMOTE=none` turns it off,
    // as does a forced XC_PAR=cpu. A daemon never browses for its peers.
    static bool _off;
    static void noRemotes(void)
        {
        _off = true;
        }
    static void addWorkers(Array* into)
        {
        if (_off)
            return;
        String* v = Platform.env(String.withCString("XC_PAR_REMOTE"));
        if (v.equals(String.withCString("none")))
            return;
        if (v.byteLength() == (u32)0)
            {
            if (Platform.env(String.withCString("XC_PAR")).equals(String.withCString("cpu")))
                return;
            v = String.withCString("mdns");
            }
        u32 at = (u32)0;
        while (at < v.byteLength())
            {
            u32 end = at;
            while (end < v.byteLength() && v.byteAt(end) != (u8)',')
                end = end + (u32)1;
            String* entry = v.substringBytes(at, end - at);
            at = end + (u32)1;
            if (entry.byteLength() == (u32)0)
                continue;
            if (entry.equals(String.withCString("mdns")))
                {
                String* pool = Platform.env(String.withCString("XC_PAR_POOL"));
                Array* found = Mdns.browse(pool.cString(), PAR_CACHE_VER, (i32)300);
                if (ParDevice.reporting())
                    Log.info("par: mdns: %u daemon(s) of pool '%s' on this subnet", found.count(), pool.cString());
                for (u32 i = (u32)0; i < found.count(); i = i + (u32)1)
                    {
                    MdnsService* svc = (MdnsService*)found.get(i);
                    ParRemoteWorker* w = new ParRemoteWorker(svc.host, svc.port);
                    if (w.identity().byteLength() > (u32)0)
                        into.add((Object*)w);
                    }
                continue;
                }
            u32 colon = entry.indexOfByte((u8)':');
            String* host = entry;
            u16 port = (u16)PAR_REMOTE_PORT;
            if (colon != (u32)$FFFFFFFF)
                {
                host = entry.substringBytes((u32)0, colon);
                u32 n = (u32)0;
                for (u32 i = colon + (u32)1; i < entry.byteLength(); i = i + (u32)1)
                    n = n * (u32)10 + (u32)(entry.byteAt(i) - (u8)'0');
                port = (u16)n;
                }
            ParRemoteWorker* w = new ParRemoteWorker(host, port);
            if (w.identity().byteLength() > (u32)0)
                into.add((Object*)w);
            }
        }
    }

// ── The daemon's side ───────────────────────────────────────────────────

// The block as the daemon holds it: a chunk with no code, whose bytes and
// arrays are the ones the program sent.
class ParRemoteChunk : ParChunk
    {
    String* _name;
    Data* _src;
    Data* _obj;             // the object bytes, array pointers rewritten to _bufs
    Array* _bufs;           // Data, per captured array
    i64 _bufLen[16];
    bool _bufRo[16];
    bool _bufSliced[16];    // its slices come with each tile
    i64 _bufIvar[16];
    u32 _nbuf;
    Array* _globs;          // Data, per global
    Array* _globNames;      // String
    i64 _globLen[16];
    bool _globRo[16];
    bool _globAll[16];
    bool _globSliced[16];
    u32 _nglob;

    u32 bufCount(void) { return _nbuf; }
    u32 globCount(void) { return _nglob; }
    i64 bufLength(u32 i) { return _bufLen[i]; }
    i64 globLength(u32 i) { return _globLen[i]; }
    // The kernel source's hash: the cache's key names the block by it.
    u32 srcHash(void)
        {
        return ParDevice.hash(gpuSource(), (u32)2166136261);
        }
    bool bufSliced(u32 i) { return _bufSliced[i]; }
    bool globSliced(u32 i) { return _globSliced[i]; }
    // A tile's slice of array (glob = false) or global i, n bytes at byte
    // offset off, into the daemon's copy; refused when it does not fit.
    bool takeSlice(bool glob, u32 i, i64 off, u8* p, u32 n)
        {
        i64 len = glob ? _globLen[i] : _bufLen[i];
        if (off < (i64)0 || (i64)n < (i64)0 || off + (i64)n > len)
            return false;
        Data* b = (Data*)(glob ? _globs.get(i) : _bufs.get(i));
        if (n > (u32)0)
            memcpy((pointer)(b.bytes() + off), (pointer)p, (u64)n);
        return true;
        }

    static Array* _sources;  // every kernel source the daemon has seen, kept

    // The kernel source as one copy per distinct text, never freed: the
    // workers remember a compiled kernel by its source's ADDRESS (a program's
    // sources sit in its binary and never move), so a source the daemon
    // freed and a different one allocated at the same address would run the
    // old kernel on the new block's data. A later program with the same
    // kernel finds it compiled already. The source is read beyond its length
    // by the section scan (a NUL then the next section's "//"), so each copy
    // keeps a few spare zero bytes.
    static Data* internSource(u8* s, u32 n)
        {
        if (_sources == (Array*)0)
            _sources = new Array();
        for (u32 i = (u32)0; i < _sources.count(); i = i + (u32)1)
            {
            Data* d = (Data*)_sources.get(i);
            if (d.length() != n + (u32)8)
                continue;
            u32 q = (u32)0;
            while (q < n && d.bytes()[q] == s[q])
                q = q + (u32)1;
            if (q == n)
                return d;
            }
        Data* d = Data.withLength(n + (u32)8);
        memcpy((pointer)d.bytes(), (pointer)s, (u64)n);
        _sources.add((Object*)d);
        return d;
        }
    u8* objBytes(void)
        {
        return _obj.bytes();
        }
    bool rawPartials(void)
        {
        return true;
        }
    u8* gpuSource(void)
        {
        return _src.bytes();
        }
    u8* parName(void)
        {
        return _name.cString();
        }
    i64 gpuLength(i32 k)
        {
        for (u32 i = (u32)0; i < _nbuf; i = i + (u32)1)
            if (_bufIvar[i] == (i64)k)
                return _bufLen[i];
        return (i64)-1;
        }
    bool gpuReadsOnly(i32 k)
        {
        for (u32 i = (u32)0; i < _nbuf; i = i + (u32)1)
            if (_bufIvar[i] == (i64)k)
                return _bufRo[i];
        return false;
        }
    i32 globIndex(u8* name)
        {
        for (u32 i = (u32)0; i < _nglob; i = i + (u32)1)
            if (parSameName(((String*)_globNames.get(i)).cString(), name))
                return (i32)i;
        return (i32)-1;
        }
    pointer gpuGlobal(u8* name)
        {
        i32 g = globIndex(name);
        return g < (i32)0 ? (pointer)0 : (pointer)((Data*)_globs.get((u32)g)).bytes();
        }
    i64 gpuGlobalBytes(u8* name)
        {
        i32 g = globIndex(name);
        return g < (i32)0 ? (i64)-1 : _globLen[g];
        }
    bool gpuWritesAll(u8* name)
        {
        i32 g = globIndex(name);
        return g >= (i32)0 && _globAll[g];
        }
    bool gpuReadsOnlyGlobal(u8* name)
        {
        i32 g = globIndex(name);
        return g >= (i32)0 && _globRo[g];
        }

    // From a HOLDS or PREPARE payload (data: the bytes are there too).
    static ParRemoteChunk* from(u8* p, u32* at, bool data, bool arrays)
        {
        ParRemoteChunk* c = new ParRemoteChunk();
        c._name = ParWire.rdStr(p, at);
        u8* s = (u8*)0;
        u32 n = ParWire.rdBytes(p, at, &s);
        c._src = ParRemoteChunk.internSource(s, n);
        u32 size = ParWire.rdU32(p, at);
        c._obj = Data.withLength(size);
        if (data)
            {
            memcpy((pointer)c._obj.bytes(), (pointer)(p + *at), (u64)size);
            *at = *at + size;
            }
        c._bufs = new Array();
        c._nbuf = ParWire.rdU32(p, at);
        for (u32 i = (u32)0; i < c._nbuf; i = i + (u32)1)
            {
            u32 off = ParWire.rdU32(p, at);
            c._bufIvar[i] = ParWire.rdI64(p, at);
            c._bufLen[i] = ParWire.rdI64(p, at);
            c._bufRo[i] = ParWire.rdU8(p, at) != (u8)0;
            c._bufSliced[i] = ParWire.rdU8(p, at) != (u8)0;
            Data* b = Data.withLength((u32)c._bufLen[i] + (u32)16);
            if (arrays && !c._bufSliced[i])
                {
                memcpy((pointer)b.bytes(), (pointer)(p + *at), (u64)c._bufLen[i]);
                *at = *at + (u32)c._bufLen[i];
                }
            *(pointer*)(c._obj.bytes() + off) = (pointer)b.bytes();
            c._bufs.add((Object*)b);
            }
        c._globs = new Array();
        c._globNames = new Array();
        c._nglob = ParWire.rdU32(p, at);
        for (u32 i = (u32)0; i < c._nglob; i = i + (u32)1)
            {
            c._globNames.add((Object*)ParWire.rdStr(p, at));
            c._globLen[i] = ParWire.rdI64(p, at);
            c._globRo[i] = ParWire.rdU8(p, at) != (u8)0;
            c._globAll[i] = ParWire.rdU8(p, at) != (u8)0;
            c._globSliced[i] = ParWire.rdU8(p, at) != (u8)0;
            Data* g = Data.withLength((u32)c._globLen[i] + (u32)16);
            if (arrays && !c._globSliced[i])
                {
                memcpy((pointer)g.bytes(), (pointer)(p + *at), (u64)c._globLen[i]);
                *at = *at + (u32)c._globLen[i];
                }
            c._globs.add((Object*)g);
            }
        return c;
        }
    }

#if ARCH_win64
void GetLocalTime(u16* systemTime);
#elif !ARCH_wasm32
pointer localtime_r(i64* t, i32* tm);
#endif

// A program's session on the daemon: the finished tiles the serve loop
// queues, which the thread of the program's results link writes out, so
// the loop never waits on a write.
// The daemon's wait for its GPU (2026-10-17): a thread that blocks on each
// tile's completion object in turn (ParWorker.waitFor) and wakes the serve
// loop's EventQueue, so the loop waits once for "a frame came, or a tile
// finished" rather than polling every millisecond. The loop polls a tile
// only after the watcher has seen it finish (ready()), since the wait holds
// the tile's completion object until then.
class ParTileWatch : Object
    {
    EventQueue* _q;
    Mutex* _lock;
    Cond* _more;
    Cond* _idle;
    Array* _tiles;        // (worker, tile) pairs to wait for, in take order
    u32 _seen;            // finished, not yet collected by the loop
    bool _waiting;        // a wait is under way
    bool _stop;
    Thread* _thread;

    static ParTileWatch* start(EventQueue* q)
        {
        ParTileWatch* tw = new ParTileWatch();
        tw._q = q;
        tw._lock = new Mutex();
        tw._more = new Cond();
        tw._idle = new Cond();
        tw._tiles = new Array();
        tw._thread = Thread.spawn(&tw.run);
        if (!tw._thread.isValid())
            return (ParTileWatch*)0;
        return tw;
        }
    // A tile w has just taken.
    void add(ParWorker* w, ParTile* t)
        {
        _lock.lock();
        _tiles.add((Object*)w);
        _tiles.add((Object*)t);
        _more.signal();
        _lock.unlock();
        }
    // How many tiles have finished and may be polled; the loop takes them.
    u32 ready(void)
        {
        _lock.lock();
        u32 n = _seen;
        _seen = (u32)0;
        _lock.unlock();
        return n;
        }
    // Until every tile added is seen finished: before a drain, which
    // collects them all, or the worker's end.
    void settle(void)
        {
        _lock.lock();
        while (_tiles.count() > (u32)0 || _waiting)
            _idle.wait(_lock);
        _lock.unlock();
        }
    void stop(void)
        {
        _lock.lock();
        _stop = true;
        _more.signal();
        _lock.unlock();
        _thread.join();
        }
    void run(void)
        {
        _lock.lock();
        while (true)
            {
            while (_tiles.count() == (u32)0 && !_stop)
                _more.wait(_lock);
            if (_tiles.count() == (u32)0)
                break;
            ParWorker* w = (ParWorker*)_tiles.get((u32)0);
            ParTile* t = (ParTile*)_tiles.get((u32)1);
            _tiles.removeAt((u32)0);
            _tiles.removeAt((u32)0);
            _waiting = true;
            _lock.unlock();
            w.waitFor(t);
            _lock.lock();
            _waiting = false;
            _seen = _seen + (u32)1;
            if (_tiles.count() == (u32)0)
                _idle.broadcast();
            _q.wake();
            }
        _lock.unlock();
        }
    }

class ParRemoteSession : Object
    {
    Data* _token;
    Array* _queue;
    Mutex* _lock;
    Cond* _ready;
    bool _ended;
    bool _attached;
    void init(Data* token)
        {
        _token = token;
        _queue = new Array();
        _lock = new Mutex();
        _ready = new Cond();
        }
    bool matches(Data* token)
        {
        if (token == (Data*)0 || token.length() != _token.length())
            return false;
        for (u32 i = (u32)0; i < _token.length(); i = i + (u32)1)
            if (token.byteAt(i) != _token.byteAt(i))
                return false;
        return true;
        }
    void push(Data* frame)
        {
        _lock.lock();
        _queue.add((Object*)frame);
        _ready.signal();
        _lock.unlock();
        }
    // The next finished tile, waiting for one; 0 once the session has ended
    // and the queue is empty. The results link sends each the moment it is
    // queued: a poll with a 1 ms sleep waited a whole timer tick on Windows
    // (15.6 ms), which put a floor of about 8 ms under every remote run.
    Data* popWait(void)
        {
        Data* d = (Data*)0;
        _lock.lock();
        while (_queue.count() == (u32)0 && !_ended)
            _ready.wait(_lock);
        if (_queue.count() > (u32)0)
            {
            d = (Data*)_queue.get((u32)0);
            _queue.removeAt((u32)0);
            }
        _lock.unlock();
        return d;
        }
    Data* pop(void)
        {
        Data* d = (Data*)0;
        _lock.lock();
        if (_queue.count() > (u32)0)
            {
            d = (Data*)_queue.get((u32)0);
            _queue.removeAt((u32)0);
            }
        _lock.unlock();
        return d;
        }
    // The results link is taken once.
    bool attach(void)
        {
        _lock.lock();
        bool first = !_attached;
        _attached = true;
        _lock.unlock();
        return first;
        }
    void end(void)
        {
        _lock.lock();
        _ended = true;
        _ready.broadcast();
        _lock.unlock();
        }
    bool ended(void)
        {
        _lock.lock();
        bool e = _ended;
        _lock.unlock();
        return e;
        }
    }

// ── The daemon's slice cache ────────────────────────────────────────────
// Every whole array and every tile slice a program sends is kept, keyed by
// the block (its kernel source's hash), the array, the byte offset and the
// length, with the content hash the program computed (ParWire.hash64). A
// later run — of the same program, or another with the same block — sends
// hashes first and bytes only for what the cache lacks; a written slice's
// result is kept too, hashed here, so a stencil's next pass finds what the
// last wrote. Host RAM; LRU by bytes under `xcd -cache <MB>` (default half
// of the first card's VRAM). Owner 2026-10-16: key per slice, affinity
// (ParWorker.cachedSaving), default eviction.
class ParRemoteSlice : Object
    {
    String* _key;
    u64 _code;      // the content hash (`hash` is every object's method: an ivar of that name reads as it)
    Data* _bytes;
    i64 _used;      // the tick it was last hit
    }

class ParRemoteCache
    {
    static Map* _slices;
    static Array* _list;        // every slice, for the eviction scan
    static Mutex* _lock;
    static i64 _bytes;
    static i64 _cap;
    static i64 _tick;
    static void setup(void)
        {
        if (_lock == (Mutex*)0)
            {
            _lock = new Mutex();
            _slices = new Map();
            _list = new Array();
            if (_cap == (i64)0)
                _cap = (i64)1 << (i64)30;
            }
        }
    static void setCap(i64 bytes)
        {
        ParRemoteCache.setup();
        _cap = bytes;
        }
    static i64 cap(void)
        {
        return _cap;
        }
    static String* key(u32 src, bool glob, u32 i, i64 off, i64 len)
        {
        return String.withFormat("%ld:%ld:%ld:%ld:%ld", (i64)src, glob ? (i64)1 : (i64)0, (i64)i, off, len);
        }
    // The bytes under key, when the cache holds them at that content hash.
    static Data* get(String* k, u64 hash)
        {
        ParRemoteCache.setup();
        _lock.lock();
        ParRemoteSlice* s = (ParRemoteSlice*)_slices.get((Hashable*)k);
        Data* d = (Data*)0;
        if (s != (ParRemoteSlice*)0 && s._code == hash)
            {
            _tick = _tick + (i64)1;
            s._used = _tick;
            d = s._bytes;
            }
        _lock.unlock();
        return d;
        }
    static void put(String* k, u64 hash, u8* p, u32 n)
        {
        ParRemoteCache.setup();
        if ((i64)n > _cap)
            return;
        _lock.lock();
        ParRemoteSlice* s = (ParRemoteSlice*)_slices.get((Hashable*)k);
        if (s != (ParRemoteSlice*)0)
            {
            _bytes = _bytes - (i64)s._bytes.length();
            s._bytes = Data.withBytes(p, n);
            s._code = hash;
            }
        else
            {
            s = new ParRemoteSlice();
            s._key = k;
            s._code = hash;
            s._bytes = Data.withBytes(p, n);
            _slices.set((Hashable*)k, (Object*)s);
            _list.add((Object*)s);
            }
        _tick = _tick + (i64)1;
        s._used = _tick;
        _bytes = _bytes + (i64)n;
        // Over the cap: the least recently hit go first.
        while (_bytes > _cap && _list.count() > (u32)1)
            {
            u32 oldest = (u32)0;
            for (u32 i = (u32)1; i < _list.count(); i = i + (u32)1)
                if (((ParRemoteSlice*)_list.get(i))._used < ((ParRemoteSlice*)_list.get(oldest))._used)
                    oldest = i;
            ParRemoteSlice* o = (ParRemoteSlice*)_list.get(oldest);
            if (o == s)
                break;
            _bytes = _bytes - (i64)o._bytes.length();
            _slices.remove((Hashable*)o._key);
            _list.removeAt(oldest);
            }
        _lock.unlock();
        }
    static i64 bytes(void)
        {
        return _bytes;
        }
    // The hash held under key, or 0: for the trace.
    static i64 heldHash(String* k)
        {
        ParRemoteCache.setup();
        _lock.lock();
        ParRemoteSlice* s = (ParRemoteSlice*)_slices.get((Hashable*)k);
        i64 h = s != (ParRemoteSlice*)0 ? (i64)s._code : (i64)0;
        _lock.unlock();
        return h;
        }
    }

class ParRemoteServe
    {
    // The nimby window (`xcd -nimby hh:mm-hh:mm`): minutes of the local day
    // the daemon takes no block and tells a heartbeat it is unavailable;
    // from -1 means no window. A window may cross midnight.
    static i32 _nimbyFrom;
    static i32 _nimbyTo;
    static bool _nimbySet;    // a static's default is 0, which is a valid minute
    // The daemon's TLS server configuration (its certificate and key), from
    // xcd at start; a connection is served only through it.
    static pointer _tls;
    static void setTls(pointer server)
        {
        _tls = server;
        }
    static void setNimby(i32 fromMinutes, i32 toMinutes)
        {
        _nimbyFrom = fromMinutes;
        _nimbyTo = toMinutes;
        _nimbySet = true;
        }
    static bool hasNimby(void)
        {
        return _nimbySet;
        }
    // The local time of day in minutes.
    static i32 localMinutes(void)
        {
#if ARCH_win64
        u16 st[8];
        GetLocalTime(&st[0]);
        return (i32)st[4] * (i32)60 + (i32)st[5];
#elif !ARCH_wasm32
        i64 t = time((pointer)0);
        i32 tm[16];
        localtime_r(&t, &tm[0]);
        return tm[2] * (i32)60 + tm[1];
#else
        return (i32)0;
#endif
        }
    static bool nimbyNow(void)
        {
        if (!_nimbySet)
            return false;
        i32 m = localMinutes();
        if (_nimbyFrom <= _nimbyTo)
            return m >= _nimbyFrom && m < _nimbyTo;
        return m >= _nimbyFrom || m < _nimbyTo;
        }

    // The GPUs serve one program's RUN at a time. Several programs may be
    // connected, each on a thread of its own (xcd spawns one per
    // connection): their heartbeats are answered meanwhile — "not now"
    // while another program holds the GPUs, so they send their tiles
    // elsewhere — and a HOLDS or PREPARE that finds the GPUs held waits a
    // while, then answers 2 (busy), which the program asks again next run.
    // A FINISH, or the connection going away, hands the GPUs on.
    static Mutex* _gpus;
    static Mutex* _state;     // over _holder and _nextConn
    static i64 _holder;       // the connection holding the GPUs; 0 none
    static i64 _nextConn;
    static void setup(void)
        {
        _gpus = new Mutex();
        _state = new Mutex();
        _holder = (i64)0;
        _nextConn = (i64)0;
        _sessions = new Array();
        }
    // The live sessions, by token (ParRemoteSession).
    static Array* _sessions;
    static ParRemoteSession* newSession(Data* token)
        {
        ParRemoteSession* s = new ParRemoteSession(token);
        _state.lock();
        _sessions.add((Object*)s);
        _state.unlock();
        return s;
        }
    static ParRemoteSession* findSession(Data* token)
        {
        ParRemoteSession* found = (ParRemoteSession*)0;
        _state.lock();
        for (u32 i = (u32)0; i < _sessions.count() && found == (ParRemoteSession*)0; i = i + (u32)1)
            if (((ParRemoteSession*)_sessions.get(i)).matches(token))
                found = (ParRemoteSession*)_sessions.get(i);
        _state.unlock();
        return found;
        }
    static void endSession(ParRemoteSession* s)
        {
        s.end();
        _state.lock();
        for (u32 i = (u32)0; i < _sessions.count(); i = i + (u32)1)
            if (_sessions.get(i) == (Object*)s)
                {
                _sessions.removeAt(i);
                break;
                }
        _state.unlock();
        }
    // A session's results link, on the thread of that connection: the
    // finished tiles the serve loop queues go out here until the session
    // ends, and the program reads them in its own time.
    static void sendResults(ParLink* s, Data* token)
        {
        ParRemoteSession* session = ParRemoteServe.findSession(token);
        if (session == (ParRemoteSession*)0 || !session.attach())
            {
            Data* why = new Data();
            ParWire.fieldStr(why, "WHY", "no such session");
            ParWire.send(s, "BYE", why);
            return;
            }
        if (!ParWire.send(s, "OK", (Data*)0))
            return;
        while (s.isOpen())
            {
            Data* f = session.popWait();
            if (f == (Data*)0)
                break;
            if (!ParWire.send(s, "DONE", f))
                break;
            }
        }
    static i64 newConnection(void)
        {
        _state.lock();
        _nextConn = _nextConn + (i64)1;
        i64 id = _nextConn;
        _state.unlock();
        return id;
        }
    static bool gpusFree(i64 me)
        {
        _state.lock();
        bool free = _holder == (i64)0 || _holder == me;
        _state.unlock();
        return free;
        }
    // The GPUs for connection me, waiting up to ms for them: false when
    // another program kept them that long.
    static bool takeGpus(i64 me, i32 ms)
        {
        if (gpusFree(me) && _holder == me)
            return true;
        i64 until = ParDevice.nowUs() + (i64)ms * (i64)1000;
        while (!_gpus.tryLock())
            {
            if (ParDevice.nowUs() > until)
                return false;
            Thread.sleepMs((u32)5);
            }
        _state.lock();
        _holder = me;
        _state.unlock();
        return true;
        }
    static void releaseGpus(i64 me)
        {
        _state.lock();
        bool mine = _holder == me;
        if (mine)
            _holder = (i64)0;
        _state.unlock();
        if (mine)
            _gpus.unlock();
        }

    // One connection, start to end: the handshake, then blocks and tiles
    // until the program goes away. The GPU workers are the daemon's own.
    static void serve(ParLink* s, Array* workers, String* identity)
        {
        if (_gpus == (Mutex*)0)
            ParRemoteServe.setup();
        if (_tls == (pointer)0 || !s.accept(_tls))
            {
            Log.info("xcd: a connection failed the TLS handshake");
            return;
            }
        i64 me = ParRemoteServe.newConnection();
        i64 runTile = (i64)0;       // the run's tile size, from PREPARE
        i64 cacheHits = (i64)0;     // this run's slices found in the cache
        i64 cacheBytes = (i64)0;
        i64 recvBytes = (i64)0;     // and the bytes that had to come
        // HELLO: the protocol, a nonce for the proof, the versions and what
        // this daemon is and has.
        Data* hello = new Data();
        ParWire.fieldU32(hello, "PROTO", (u32)PAR_REMOTE_PROTO);
        u8 nonce[32];
        i64 t = ParDevice.nowUs();
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            {
            t = t * (i64)6364136223846793005 + (i64)1442695040888963407;
            nonce[i] = (u8)((u64)t >> (u64)33);
            }
        ParWire.field(hello, "NONCE", &nonce[0], (u32)32);
        ParWire.fieldStr(hello, "VERSION", PAR_CACHE_VER);
        ParWire.fieldStr(hello, "IDENT", identity.cString());
        u32 depth = (u32)PAR_REMOTE_DEPTH;
        i64 floor = (i64)1024;
        for (u32 i = (u32)0; i < workers.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)workers.get(i);
            if (w.depth() < depth) depth = w.depth();
            if (w.floor() > floor) floor = w.floor();
            }
        ParWire.fieldU32(hello, "DEPTH", depth);
        ParWire.fieldI64(hello, "FLOOR", floor);
        // The first worker's card, which the identity names, and the host.
        u64 vt = (u64)0;
        u64 vf = (u64)0;
        if (workers.count() > (u32)0)
            ((ParWorker*)workers.get((u32)0)).memory(&vt, &vf);
        u64 rt = (u64)0;
        u64 rf = (u64)0;
        ParDevice.systemMemory(&rt, &rf);
        ParWire.fieldI64(hello, "VRAMTOT", (i64)vt);
        ParWire.fieldI64(hello, "VRAMFREE", (i64)vf);
        ParWire.fieldI64(hello, "RAMTOT", (i64)rt);
        ParWire.fieldI64(hello, "RAMFREE", (i64)rf);
        if (!ParWire.send(s, "HELLO", hello))
            return;
        u8 tag[8];
        Data* auth = ParWire.recv(s, &tag[0], (i32)10000);
        if (auth == (Data*)0)
            return;
        if (ParWire.tagIs(&tag[0], "RESULTS"))
            {
            Data* token = ParWire.getData(auth, "TOKEN");
            if (token != (Data*)0)
                ParRemoteServe.sendResults(s, token);
            return;
            }
        if (!ParWire.tagIs(&tag[0], "AUTH"))
            return;
        u32 proto = ParWire.getU32(auth, "PROTO", (u32)0);
        String* version = ParWire.getStr(auth, "VERSION");
        u8* proof = (u8*)0;
        u32 pn = (u32)0;
        Data* want = ParRemote.proof(&nonce[0]);
        bool ok = proto == (u32)PAR_REMOTE_PROTO && version != (String*)0 && version.equals(String.withCString(PAR_CACHE_VER))
               && ParWire.find(auth, "PROOF", &proof, &pn) && pn == (u32)32;
        for (u32 i = (u32)0; ok && i < (u32)32; i = i + (u32)1)
            if (proof[i] != want.byteAt(i))
                ok = false;
        if (!ok)
            {
            Data* why = new Data();
            ParWire.fieldStr(why, "WHY", "version or pool secret");
            ParWire.send(s, "BYE", why);
            Log.info("xcd: a program declined: version %s, protocol %u", version != (String*)0 ? version.cString() : "?", proto);
            return;
            }
        // The session token the program names its results link by: known
        // to the two of them alone (the proof is the secret's, and the
        // link is TLS).
        Data* tk = Data.withBytes(&nonce[0], (u32)32);
        tk.appendBytes(proof, (u32)32);
        Data* token = Sha256.of(tk.bytes(), tk.length());
        ParRemoteSession* session = ParRemoteServe.newSession(token);
        Data* okd = new Data();
        ParWire.field(okd, "TOKEN", token.bytes(), (u32)32);
        ParWire.send(s, "OK", okd);
        Log.info("xcd: a program connected");

        ParRemoteChunk* chunk = (ParRemoteChunk*)0;
        ParLayout* l = (ParLayout*)0;
        ParWorker* w = (ParWorker*)0;
        Array* pending = new Array();   // tiles sent and not yet taken
        u32 inFlight = (u32)0;
        // XC_PAR_DIE_AFTER=<n>: the connection is dropped after n tiles have
        // been taken — the test of a program surviving a lost worker.
        i64 dieAfter = (i64)-1;
        String* dieV = Platform.env(String.withCString("XC_PAR_DIE_AFTER"));
        if (dieV.byteLength() > (u32)0)
            {
            dieAfter = (i64)0;
            for (u32 i = (u32)0; i < dieV.byteLength(); i = i + (u32)1)
                dieAfter = dieAfter * (i64)10 + (i64)(dieV.byteAt(i) - (u8)'0');
            }
        i64 taken = (i64)0;
        // One wait for a frame or a finished tile, where the platform has
        // an EventQueue and the worker a waitFor; else the 1 ms poll.
        EventQueue* evq = EventQueue.make();
        ParTileWatch* watch = (ParTileWatch*)0;
        if (evq != (EventQueue*)0 && evq.watch(s.fd()))
            watch = ParTileWatch.start(evq);
        bool watching = false;      // this block's worker has a waitFor
        while (s.isOpen())
            {
            // Hand pending tiles to the worker while it has room; collect
            // what finished and queue it for the results link.
            if (w != (ParWorker*)0)
                {
                while (pending.count() > (u32)0)
                    {
                    ParTile* t0 = (ParTile*)pending.get((u32)0);
                    if (!w.take(t0, (ParChunk*)chunk, chunk.gpuSource(), l))
                        break;
                    pending.removeAt((u32)0);
                    if (watching)
                        watch.add(w, t0);
                    inFlight = inFlight + (u32)1;
                    taken = taken + (i64)1;
                    if (dieAfter >= (i64)0 && taken >= dieAfter)
                        {
                        Log.info("xcd: dropping the connection after %ld tiles (XC_PAR_DIE_AFTER)", taken);
                        s.close();
                        break;
                        }
                    }
                if (watching)
                    {
                    // Only what the watcher has seen finish.
                    for (u32 k = watch.ready(); k > (u32)0; k = k - (u32)1)
                        {
                        ParTile* d = w.poll();
                        if (d == (ParTile*)0)
                            break;
                        inFlight = inFlight - (u32)1;
                        session.push(ParRemoteServe.doneFrame(chunk, l, d));
                        }
                    }
                else
                    {
                    ParTile* d = w.poll();
                    while (d != (ParTile*)0)
                        {
                        inFlight = inFlight - (u32)1;
                        session.push(ParRemoteServe.doneFrame(chunk, l, d));
                        d = w.poll();
                        }
                    }
                }
            // A frame, when one is there: with the watcher, one wait for a
            // frame or a finished tile; else a millisecond's wait while
            // tiles are in flight, and as long as it takes when none are.
            if (watch != (ParTileWatch*)0 && !s.waitReadable((i32)0))
                {
                bool busy = inFlight > (u32)0 || pending.count() > (u32)0;
                if (busy && !watching)
                    {
                    if (!s.waitReadable((i32)1))
                        continue;
                    }
                else
                    {
                    evq.wait((i32)1000);
                    continue;
                    }
                }
            else if (watch == (ParTileWatch*)0 && !s.waitReadable(inFlight > (u32)0 || pending.count() > (u32)0 ? (i32)1 : (i32)1000))
                continue;
            Data* f = ParWire.recv(s, &tag[0], (i32)-1);
            if (f == (Data*)0)
                break;
            if (ParWire.tagIs(&tag[0], "HOLDS"))
                {
                u8* bp = (u8*)0;
                u32 bn = (u32)0;
                if (!ParWire.find(f, "BLOCK", &bp, &bn))
                    break;
                u32 at = (u32)0;
                ParRemoteChunk* c = ParRemoteChunk.from(bp, &at, false, false);
                bool held = false;
                bool nimby = ParRemoteServe.nimbyNow();
                // Compiling the block's kernel touches the workers: the GPUs
                // are taken for it, briefly, and given back unless this
                // connection is mid-run.
                bool busy = !nimby && !ParRemoteServe.takeGpus(me, (i32)20000);
                for (u32 i = (u32)0; i < workers.count() && !held && !nimby && !busy; i = i + (u32)1)
                    {
                    // Each worker lays the block out from its own section.
                    ParWorker* cand = (ParWorker*)workers.get(i);
                    u8* sec = cand.section(c.gpuSource());
                    ParLayout* lc = sec != (u8*)0 ? ParDevice.layout((ParChunk*)c, sec, (i64)0, (i64)1) : (ParLayout*)0;
                    if (lc != (ParLayout*)0 && cand.forBlock((ParChunk*)c, c.gpuSource(), lc))
                        held = true;
                    }
                if (w == (ParWorker*)0)
                    ParRemoteServe.releaseGpus(me);
                Data* a = new Data();
                ParWire.fieldU8(a, "TAKEN", held ? (u8)1 : busy ? (u8)2 : (u8)0);
                ParWire.send(s, "ANSWER", a);
                Log.info("xcd: %s %s", c.parName(), held ? "taken" : nimby ? "declined (nimby)" : busy ? "busy" : "declined");
                }
            else if (ParWire.tagIs(&tag[0], "PING"))
                {
                // The heartbeat: the stamp and kind echoed, whether tiles are
                // welcome now, and how many wait here.
                Data* a = new Data();
                ParWire.fieldI64(a, "SENT", ParWire.getI64(f, "SENT", (i64)0));
                ParWire.fieldU8(a, "KIND", ParWire.getU8(f, "KIND", (u8)0));
                ParWire.fieldU8(a, "AVAILABLE", ParRemoteServe.nimbyNow() || !ParRemoteServe.gpusFree(me) ? (u8)0 : (u8)1);
                ParWire.fieldU32(a, "QUEUED", (u32)pending.count() + inFlight);
                ParWire.send(s, "PONG", a);
                }
            else if (ParWire.tagIs(&tag[0], "PREPARE"))
                {
                u8* bp = (u8*)0;
                u32 bn = (u32)0;
                if (!ParWire.find(f, "BLOCK", &bp, &bn))
                    break;
                u32 at = (u32)0;
                chunk = ParRemoteChunk.from(bp, &at, true, false);
                i64 tile = ParWire.getI64(f, "TILE", (i64)0);
                i64 n = ParWire.getI64(f, "N", (i64)0);
                // The whole arrays: each one's hash looked up in the cache,
                // and NEED names the ones to send; DATA brings them.
                u32 sh = chunk.srcHash();
                u8* hp = (u8*)0;
                u32 hn = (u32)0;
                Data* need = new Data();
                u32 nneed = (u32)0;
                u64 wantHash[32];
                cacheHits = (i64)0;
                cacheBytes = (i64)0;
                recvBytes = (i64)0;
                if (ParWire.find(f, "HASHES", &hp, &hn))
                    {
                    u32 ha = (u32)0;
                    while (ha + (u32)21 <= hn)
                        {
                        u8 kind = ParWire.rdU8(hp, &ha);
                        u32 idx = ParWire.rdU32(hp, &ha);
                        i64 len = ParWire.rdI64(hp, &ha);
                        u64 h = (u64)ParWire.rdI64(hp, &ha);
                        Data* have = ParRemoteCache.get(ParRemoteCache.key(sh, kind != (u8)0, idx, (i64)0, len), h);
                        if (have != (Data*)0 && (i64)have.length() == len && chunk.takeSlice(kind != (u8)0, idx, (i64)0, have.bytes(), (u32)len))
                            {
                            cacheHits = cacheHits + (i64)1;
                            cacheBytes = cacheBytes + len;
                            }
                        else if (nneed < (u32)32)
                            {
                            ParWire.putU8(need, kind);
                            ParWire.putU32(need, idx);
                            wantHash[nneed] = h;
                            nneed = nneed + (u32)1;
                            }
                        }
                    }
                Data* nd = new Data();
                ParWire.fieldData(nd, "LIST", need);
                if (!ParWire.send(s, "NEED", nd))
                    break;
                Data* dd = ParWire.recv(s, &tag[0], (i32)60000);
                if (dd == (Data*)0 || !ParWire.tagIs(&tag[0], "DATA"))
                    break;
                u8* dp = (u8*)0;
                u32 dn = (u32)0;
                bool fitsData = true;
                if (ParWire.find(dd, "ARRAYS", &dp, &dn))
                    {
                    u32 da = (u32)0;
                    for (u32 k = (u32)0; k < nneed && da < dn; k = k + (u32)1)
                        {
                        u8 kind = ParWire.rdU8(dp, &da);
                        u32 idx = ParWire.rdU32(dp, &da);
                        u8* b = (u8*)0;
                        u32 bn = ParWire.rdBytes(dp, &da, &b);
                        if (da > dn || !chunk.takeSlice(kind != (u8)0, idx, (i64)0, b, bn))
                            {
                            fitsData = false;
                            break;
                            }
                        ParRemoteCache.put(ParRemoteCache.key(sh, kind != (u8)0, idx, (i64)0, (i64)bn), wantHash[k], b, bn);
                        recvBytes = recvBytes + (i64)bn;
                        }
                    }
                if (!fitsData)
                    {
                    Log.info("xcd: a block's arrays do not fit its description; closing");
                    break;
                    }
                w = (ParWorker*)0;
                l = (ParLayout*)0;
                // The GPUs for the run: waited for up to 50 s (the program
                // waits 60 for the answer), else busy.
                bool busyRun = !ParRemoteServe.takeGpus(me, (i32)50000);
                bool noRoom = false;
                i64 needMb = (i64)0;
                i64 freeMb = (i64)0;
                runTile = tile;
                for (u32 i = (u32)0; i < workers.count() && w == (ParWorker*)0 && !busyRun; i = i + (u32)1)
                    {
                    ParWorker* cand = (ParWorker*)workers.get(i);
                    u8* sec = cand.section(chunk.gpuSource());
                    ParLayout* lc = sec != (u8*)0 ? ParDevice.layout((ParChunk*)chunk, sec, (i64)0, n) : (ParLayout*)0;
                    if (lc == (ParLayout*)0 || !cand.forBlock((ParChunk*)chunk, chunk.gpuSource(), lc))
                        continue;
                    i64 devNeed = ParRemoteServe.blockBytes(lc, tile, cand.depth());
                    i64 freeB = (i64)0;
                    if (!ParRemoteServe.fits(cand, devNeed, &freeB))
                        {
                        Log.info("xcd: %s: %s declines it: needs %ld MB of device memory, %ld MB free",
                                 chunk.parName(), cand.identity().cString(), devNeed >> (i64)20, freeB >> (i64)20);
                        noRoom = true;
                        needMb = devNeed >> (i64)20;
                        freeMb = freeB >> (i64)20;
                        continue;
                        }
                    if (cand.prepare((ParChunk*)chunk, chunk.gpuSource(), lc, tile))
                        {
                        w = cand;
                        l = lc;
                        watching = watch != (ParTileWatch*)0 && w.waits();
                        }
                    }
                if (w == (ParWorker*)0)
                    ParRemoteServe.releaseGpus(me);
                Data* a = new Data();
                // TAKEN 3: no worker has the device memory for it now.
                ParWire.fieldU8(a, "TAKEN", w != (ParWorker*)0 ? (u8)1 : busyRun ? (u8)2 : noRoom ? (u8)3 : (u8)0);
                if (noRoom && w == (ParWorker*)0)
                    {
                    ParWire.fieldI64(a, "NEEDMB", needMb);
                    ParWire.fieldI64(a, "FREEMB", freeMb);
                    }
                ParWire.send(s, "ANSWER", a);
                if (busyRun)
                    Log.info("xcd: %s: busy, another program has the GPUs", chunk.parName());
                pending = new Array();
                inFlight = (u32)0;
                }
            else if (ParWire.tagIs(&tag[0], "TILE") && w != (ParWorker*)0)
                {
                ParTile* t1 = new ParTile();
                t1.index = ParWire.getI64(f, "INDEX", (i64)0);
                t1.lo = ParWire.getI64(f, "LO", (i64)0);
                t1.hi = ParWire.getI64(f, "HI", (i64)0);
                // The slices it brought, into the daemon's arrays. A tile
                // still in flight reads other elements, or the same bytes
                // where footprints overlap (a stencil's halo).
                u8* p = (u8*)0;
                u32 pn2 = (u32)0;
                bool fits = ParWire.find(f, "SLICES", &p, &pn2);
                bool missing = false;
                u32 at = (u32)0;
                for (u32 i = (u32)0; fits && i < chunk.bufCount() && at <= pn2; i = i + (u32)1)
                    {
                    if (!chunk.bufSliced(i))
                        continue;
                    if (!ParRemoteServe.takeTileSlice(chunk, false, i, p, &at, pn2, &cacheHits, &cacheBytes, &recvBytes, &missing))
                        fits = false;
                    }
                for (u32 i = (u32)0; fits && i < chunk.globCount() && at <= pn2; i = i + (u32)1)
                    {
                    if (!chunk.globSliced(i))
                        continue;
                    if (!ParRemoteServe.takeTileSlice(chunk, true, i, p, &at, pn2, &cacheHits, &cacheBytes, &recvBytes, &missing))
                        fits = false;
                    }
                if (!fits)
                    {
                    Log.info("xcd: a tile's slices do not fit its block; closing");
                    break;
                    }
                // The load check per tile: what this tile brings, against the
                // device memory free now (another program may have taken it
                // since PREPARE). Refused, it goes back to the program's
                // queue, as a lost tile does.
                i64 tileFree = (i64)0;
                i64 tileNeed = l != (ParLayout*)0 ? ParRemoteServe.blockBytes(l, t1.hi - t1.lo, (u32)1) - ParRemoteServe.blockBytes(l, (i64)0, (u32)0) : (i64)0;
                if (!missing && tileNeed > (i64)0 && !ParRemoteServe.fits(w, tileNeed * (i64)((u32)pending.count() + inFlight + (u32)1), &tileFree))
                    {
                    Log.info("xcd: %s: tile %ld refused: %ld MB in flight would not fit %ld MB free",
                             chunk.parName(), t1.index, (tileNeed * (i64)((u32)pending.count() + inFlight + (u32)1)) >> (i64)20, tileFree >> (i64)20);
                    Data* m = new Data();
                    ParWire.fieldI64(m, "INDEX", t1.index);
                    ParWire.fieldU8(m, "REFUSED", (u8)1);
                    session.push(m);
                    }
                else if (missing)
                    {
                    // A slice the program thought held was evicted: the tile
                    // goes back on the results link as a MISS, and comes
                    // again with its bytes.
                    Data* m = new Data();
                    ParWire.fieldI64(m, "INDEX", t1.index);
                    ParWire.fieldU8(m, "MISS", (u8)1);
                    session.push(m);
                    }
                else
                    pending.add((Object*)t1);
                }
            else if (ParWire.tagIs(&tag[0], "FINISH"))
                {
                if (w != (ParWorker*)0 && (cacheHits > (i64)0 || recvBytes > (i64)0))
                    Log.info("xcd: %s: %ld slice(s) from the cache (%ld KB), %ld KB received; cache holds %ld MB of %ld",
                             chunk.parName(), cacheHits, cacheBytes >> (i64)10, recvBytes >> (i64)10,
                             ParRemoteCache.bytes() >> (i64)20, ParRemoteCache.cap() >> (i64)20);
                if (w != (ParWorker*)0)
                    {
                    if (watching)
                        {
                        watch.settle();
                        watch.ready();
                        }
                    w.drain();
                    ParTile* d2 = w.poll();
                    while (d2 != (ParTile*)0)
                        {
                        session.push(ParRemoteServe.doneFrame(chunk, l, d2));
                        d2 = w.poll();
                        }
                    w.finish();
                    }
                w = (ParWorker*)0;
                watching = false;
                ParRemoteServe.releaseGpus(me);
                }
            }
        if (watch != (ParTileWatch*)0)
            {
            watch.settle();
            watch.stop();
            }
        if (evq != (EventQueue*)0)
            evq.close();
        if (w != (ParWorker*)0)
            {
            w.drain();
            w.finish();
            }
        ParRemoteServe.releaseGpus(me);
        ParRemoteServe.endSession(session);
        Log.info("xcd: the program went away");
        }

    // A finished tile for the program: its index, the written slices of
    // every footprinted array and global, and the partials.
    // The device memory a block needs on worker w: its whole arrays and
    // globals, resident for the run, and `depth` tiles' slices in flight.
    static i64 blockBytes(ParLayout* l, i64 tile, u32 depth)
        {
        i64 whole = (i64)0;
        i64 per = (i64)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] == (i64)0) whole = whole + l.bufLen[i];
            else per = per + l.bufElem[i];
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] == (i64)0) whole = whole + l.globLen[i];
            else per = per + l.globElem[i];
            }
        return whole + (i64)depth * tile * per;
        }
    // The load check (owner 2026-10-16: VRAM only for now): need bytes
    // against the worker's free device memory. A worker that reports no
    // figure (0: Vulkan has no portable free count) is not refused.
    static bool fits(ParWorker* w, i64 need, i64* freeOut)
        {
        u64 total = (u64)0;
        u64 free = (u64)0;
        w.memory(&total, &free);
        // XCD_VRAM_FREE_MB: the free figure to check against, for the tests
        // (no machine here has a card small enough to refuse a fixture).
        String* fake = Platform.env(String.withCString("XCD_VRAM_FREE_MB"));
        if (fake.byteLength() > (u32)0)
            {
            u64 mb = (u64)0;
            for (u32 k = (u32)0; k < fake.byteLength(); k = k + (u32)1)
                if (fake.byteAt(k) >= (u8)'0' && fake.byteAt(k) <= (u8)'9')
                    mb = mb * (u64)10 + (u64)(fake.byteAt(k) - (u8)'0');
            free = mb << (u64)20;
            if (free == (u64)0) free = (u64)1;
            }
        *freeOut = (i64)free;
        if (free == (u64)0 || Platform.env(String.withCString("XCD_VRAM_IGNORE")).byteLength() > (u32)0)
            return true;
        return need <= (i64)free;
        }
    // One slice of a TILE frame: offset, length, hash, then a flag and the
    // bytes when the program sent them (kept in the cache), else the cache's
    // copy at that hash — or, evicted, *missing.
    static bool takeTileSlice(ParRemoteChunk* chunk, bool glob, u32 i, u8* p, u32* at, u32 pn, i64* hits, i64* hitBytes, i64* recv, bool* missing)
        {
        i64 off = ParWire.rdI64(p, at);
        i64 len = ParWire.rdI64(p, at);
        u64 h = (u64)ParWire.rdI64(p, at);
        u8 sent = ParWire.rdU8(p, at);
        if (*at > pn || len < (i64)0)
            return false;
        if (sent != (u8)0)
            {
            u8* b = (u8*)0;
            u32 n = ParWire.rdBytes(p, at, &b);
            if (*at > pn || (i64)n != len || !chunk.takeSlice(glob, i, off, b, n))
                return false;
            if (n > (u32)0)
                ParRemoteCache.put(ParRemoteCache.key(chunk.srcHash(), glob, i, off, len), h, b, n);
            if (ParDevice.tracing() && n > (u32)0)
                Log.info("xcd: cache: %s received at %ld", ParRemoteCache.key(chunk.srcHash(), glob, i, off, len).cString(), (i64)h);
            *recv = *recv + (i64)n;
            return true;
            }
        if (len == (i64)0)
            return true;
        Data* have = ParRemoteCache.get(ParRemoteCache.key(chunk.srcHash(), glob, i, off, len), h);
        if (have == (Data*)0 || (i64)have.length() != len)
            {
            if (ParDevice.tracing())
                Log.info("xcd: cache: %s wanted at %ld, held at %ld", ParRemoteCache.key(chunk.srcHash(), glob, i, off, len).cString(), (i64)h,
                         ParRemoteCache.heldHash(ParRemoteCache.key(chunk.srcHash(), glob, i, off, len)));
            *missing = true;
            return true;
            }
        if (!chunk.takeSlice(glob, i, off, have.bytes(), (u32)len))
            return false;
        *hits = *hits + (i64)1;
        *hitBytes = *hitBytes + len;
        return true;
        }
    static Data* doneFrame(ParRemoteChunk* chunk, ParLayout* l, ParTile* t)
        {
        Data* f = new Data();
        ParWire.fieldI64(f, "INDEX", t.index);
        Data* d = new Data();
        u8* obj = chunk.objBytes();
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufIn[i] != (i64)0 || l.bufFp[i] == (i64)0)
                continue;
            i64 count = l.bufLen[i] / l.bufElem[i];
            i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
            ParWire.putI64(d, e0);
            ParWire.putI64(d, e1);
            u8* wb = *(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i];
            u32 wn = e1 > e0 ? (u32)((e1 - e0) * l.bufElem[i]) : (u32)0;
            ParWire.putBytes(d, wb, wn);
            // What it wrote stays cached under its new hash, and the program
            // is told it, so the next run's tile over the same elements
            // need not bring them.
            u64 wh = wn > (u32)0 ? ParWire.hash64(wb, wn) : (u64)0;
            if (wn > (u32)0)
                ParRemoteCache.put(ParRemoteCache.key(chunk.srcHash(), false, i, e0 * l.bufElem[i], (i64)wn), wh, wb, wn);
            if (ParDevice.tracing() && wn > (u32)0)
                Log.info("xcd: cache: %s written at %ld", ParRemoteCache.key(chunk.srcHash(), false, i, e0 * l.bufElem[i], (i64)wn).cString(), (i64)wh);
            ParWire.putI64(d, (i64)wh);
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globIn[i] != (i64)0 || l.globFp[i] == (i64)0)
                continue;
            i64 count = l.globLen[i] / l.globElem[i];
            i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
            ParWire.putI64(d, e0);
            ParWire.putI64(d, e1);
            u8* wb = (u8*)l.globPtr[i] + e0 * l.globElem[i];
            u32 wn = e1 > e0 ? (u32)((e1 - e0) * l.globElem[i]) : (u32)0;
            ParWire.putBytes(d, wb, wn);
            u64 wh = wn > (u32)0 ? ParWire.hash64(wb, wn) : (u64)0;
            if (wn > (u32)0)
                ParRemoteCache.put(ParRemoteCache.key(chunk.srcHash(), true, i, e0 * l.globElem[i], (i64)wn), wh, wb, wn);
            ParWire.putI64(d, (i64)wh);
            }
        ParWire.fieldData(f, "SLICES", d);
        if (l.nred > (u32)0)
            {
            if (t.raw != (Data*)0)
                ParWire.field(f, "PARTS", t.raw.bytes(), t.raw.length());
            else
                ParWire.field(f, "PARTS", (u8*)0, (u32)0);
            // How many partials each reduction has, by this worker's layout
            // (its kernel form may reduce on the device): the program folds
            // by this count, not its own.
            l.plan(t.lo, t.hi);
            ParWire.fieldI64(f, "NBACK", l.nback);
            }
        // The daemon's time on the tile, from take to completion, so the
        // program separates the link from the compute.
        ParWire.fieldI64(f, "KERNELUS", t.usTaken);
        return f;
        }
    }
#endif
