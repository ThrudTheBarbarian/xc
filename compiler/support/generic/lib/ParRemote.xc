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
// The frames: u32 type, u32 length, payload, little-endian throughout. The
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
// Not yet: TLS and TOFU worker certificates, mDNS discovery, the GPU-RAM
// cache, a load check at tile acceptance (GPU utilisation, free VRAM) and
// a refusal of tiles that would run past the window's end. An array whose footprint the compiler
// knows travels as the slices each tile reads, with the tile (as to a
// discrete card); the rest go over whole once per run at PREPARE.
#import "Par.xc"
#import "ParWorker.xc"
#import "Socket.xc"
#import "Sha256.xc"

#define PAR_REMOTE_PROTO 2
#define PAR_REMOTE_PORT 7227
#define PAR_REMOTE_DEPTH 3

// Frame types.
#define PRM_HELLO 1      // daemon -> program: magic, proto, nonce, version, identity, depth, floor
#define PRM_AUTH 2       // program -> daemon: proto, version, proof
#define PRM_OK 3         // daemon -> program
#define PRM_BYE 4        // either way: the reason, then the connection closes
#define PRM_HOLDS 5      // program -> daemon: the block described (no data); reply OK (1) or BYE... no: PRM_ANSWER
#define PRM_ANSWER 6     // daemon -> program: one byte
#define PRM_PREPARE 7    // program -> daemon: the block with its data, and the tile size
#define PRM_TILE 8       // program -> daemon: index, lo, hi, then each sliced array's and global's slice
#define PRM_DONE 9       // daemon -> program: index, written slices, partials
#define PRM_FINISH 10    // program -> daemon: the run is over
#define PRM_PING 11      // program -> daemon: sent-at (its own clock), kind (0 heartbeat, 1 bandwidth probe), padding
#define PRM_PONG 12      // daemon -> program: sent-at and kind echoed, available (1 = takes tiles now), tiles queued
#define PAR_REMOTE_PROBE_BYTES (1024 * 1024)

// A little-endian byte writer and reader over Data.
class ParWire
    {
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

    // One frame out: the header then the payload.
    static bool send(Socket* s, u32 type, Data* payload)
        {
        u8 hdr[8];
        u32 n = payload != (Data*)0 ? payload.length() : (u32)0;
        hdr[0] = (u8)type; hdr[1] = (u8)(type >> (u32)8); hdr[2] = (u8)(type >> (u32)16); hdr[3] = (u8)(type >> (u32)24);
        hdr[4] = (u8)n; hdr[5] = (u8)(n >> (u32)8); hdr[6] = (u8)(n >> (u32)16); hdr[7] = (u8)(n >> (u32)24);
        if (!s.write(&hdr[0], (u32)8))
            return false;
        return n == (u32)0 || s.write(payload.bytes(), n);
        }
    // One frame in, waiting up to ms for it: the payload, with *type set;
    // null when the connection closed or time ran out.
    static Data* recv(Socket* s, u32* type, i32 ms)
        {
        u8 hdr[8];
        if (!s.readExact(&hdr[0], (u32)8, ms))
            return (Data*)0;
        u32 at = (u32)0;
        *type = ParWire.rdU32(&hdr[0], &at);
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
            if (spirv)
                return h + (u32)1 + words * (u32)4;
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
    static Data* describe(ParChunk* proto, u8* src, ParLayout* l, bool data)
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
            if (data && l.bufFp[i] == (i64)0)
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
            if (data && l.globFp[i] == (i64)0)
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
    Socket* _s;
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
    i64 _sizedFloor;        // the tile floor the link's latency asks for this block
    Array* _finished;       // tiles completed while reading for a pong, for poll()
    // The run in progress.
    ParChunk* _proto;
    ParLayout* _l;
    u32 _inFlight;
    Array* _tiles;          // ParTile, by their order of taking
    // What the daemon last answered holds() for, so a block is asked once.
    pointer _heldSrc;
    bool _held;

    void init(String* host, u16 port)
        {
        _host = host;
        _port = port;
        _depth = (u32)PAR_REMOTE_DEPTH;
        _floor = (i64)1024;
        _identity = new String();
        _tiles = new Array();
        _finished = new Array();
        _available = true;
        }

    // Connect and shake hands, once. The identity is "" after a failure.
    bool connect(void)
        {
        if (_s != (Socket*)0 && _s.isOpen())
            return true;
        if (_tried)
            return false;
        _tried = true;
        try
            {
            _s = Socket.connect(_host, _port);
            }
        catch (SocketError e)
            {
            if (ParDevice.reporting())
                Log.info("par: remote %s: %s", _host.cString(), e.message().cString());
            return false;
            }
        u32 type = (u32)0;
        Data* hello = ParWire.recv(_s, &type, (i32)5000);
        if (hello == (Data*)0 || type != (u32)PRM_HELLO || hello.length() < (u32)44)
            return fail("no greeting");
        u8* p = hello.bytes();
        u32 at = (u32)0;
        if (p[0] != (u8)'X' || p[1] != (u8)'C' || p[2] != (u8)'D' || p[3] != (u8)'1')
            return fail("not an xcd");
        at = (u32)4;
        u32 proto = ParWire.rdU32(p, &at);
        u8* nonce = p + at;
        at = at + (u32)32;
        String* version = ParWire.rdStr(p, &at);
        String* ident = ParWire.rdStr(p, &at);
        _depth = ParWire.rdU32(p, &at);
        _floor = ParWire.rdI64(p, &at);
        if (proto != (u32)PAR_REMOTE_PROTO)
            return fail("another protocol version");
        if (!version.equals(String.withCString(PAR_CACHE_VER)))
            return fail("another xcc version");
        Data* auth = new Data();
        ParWire.putU32(auth, (u32)PAR_REMOTE_PROTO);
        ParWire.putStr(auth, PAR_CACHE_VER);
        Data* proof = ParRemote.proof(nonce);
        auth.appendBytes(proof.bytes(), (u32)32);
        if (!ParWire.send(_s, (u32)PRM_AUTH, auth))
            return fail("the daemon went away");
        Data* ok = ParWire.recv(_s, &type, (i32)5000);
        if (ok == (Data*)0 || type != (u32)PRM_OK)
            return fail("the daemon declined the pool secret");
        _identity = String.withCString("remote:");
        _identity.append(_host);
        _identity.appendCString(":");
        _identity.append(ident);
        if (ParDevice.reporting())
            Log.info("par: remote worker %s, depth %u", _identity.cString(), _depth);
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
        ParWire.putI64(d, ParDevice.nowUs());
        ParWire.putU8(d, kind);
        if (pad > (u32)0)
            {
            Data* z = Data.withLength(pad);
            d.appendBytes(z.bytes(), pad);
            }
        _lastPing = ParDevice.nowUs();
        return ParWire.send(_s, (u32)PRM_PING, d);
        }
    // Frames until a pong (a DONE on the way is completed and kept for poll()).
    bool awaitPong(void)
        {
        i64 before = _lastPong;
        while (_lastPong == before && _s != (Socket*)0 && _s.isOpen())
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
        u8* p = f.bytes();
        u32 at = (u32)0;
        i64 sent = ParWire.rdI64(p, &at);
        u8 kind = ParWire.rdU8(p, &at);
        _available = ParWire.rdU8(p, &at) != (u8)0;
        _lastPong = ParDevice.nowUs();
        if (kind == (u8)0 && _lastPong - sent > (i64)0)
            _rttUs = _lastPong - sent;
        }
    // One frame: a pong, or a finished tile completed and kept. False when
    // the connection is lost.
    bool readFrame(void)
        {
        u32 type = (u32)0;
        Data* f = ParWire.recv(_s, &type, (i32)-1);
        if (f == (Data*)0)
            {
            fail("lost the connection");
            return false;
            }
        if (type == (u32)PRM_PONG)
            {
            pong(f);
            return true;
            }
        if (type == (u32)PRM_DONE)
            {
            ParTile* t = complete(f);
            if (t != (ParTile*)0)
                _finished.add((Object*)t);
            return true;
            }
        fail("an unexpected frame mid-run");
        return false;
        }
    // The daemon's last word, re-asked by a heartbeat every second while the
    // queue is dispatching; not ready either when a ping has gone unanswered
    // for five seconds (the queue then hands its tiles elsewhere; the ones
    // in flight are waited for by drain()).
    bool ready(i64 now)
        {
        if (_s == (Socket*)0 || !_s.isOpen())
            return false;
        while (_s.waitReadable((i32)0))
            if (!readFrame())
                return false;
        if (now - _lastPing > (i64)1000000)
            ping((u8)0, (u32)0);
        if (_lastPing > _lastPong && now - _lastPing > (i64)5000000)
            return false;
        return _available;
        }
    bool fail(u8* why)
        {
        if (ParDevice.reporting())
            Log.info("par: remote %s: %s", _host.cString(), why);
        if (_s != (Socket*)0)
            _s.close();
        _identity = new String();
        return false;
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
        if (!ParWire.send(_s, (u32)PRM_HOLDS, ParWire.describe(proto, src, l, false)))
            return false;
        u32 type = (u32)0;
        Data* a = ParWire.recv(_s, &type, (i32)30000);
        _held = a != (Data*)0 && type == (u32)PRM_ANSWER && a.length() == (u32)1 && a.byteAt((u32)0) == (u8)1;
        if (ParDevice.reporting() && !_held)
            Log.info("par: %s does not take %s", _identity.cString(), proto.parName());
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
        Data* d = ParWire.describe(proto, src, l, true);
        ParWire.putI64(d, tile);
        ParWire.putI64(d, l.n);
        if (!ParWire.send(_s, (u32)PRM_PREPARE, d))
            return false;
        u32 type = (u32)0;
        Data* a = ParWire.recv(_s, &type, (i32)60000);
        return a != (Data*)0 && type == (u32)PRM_ANSWER && a.length() == (u32)1 && a.byteAt((u32)0) == (u8)1;
        }
    void finish(void)
        {
        if (_s != (Socket*)0 && _s.isOpen())
            ParWire.send(_s, (u32)PRM_FINISH, (Data*)0);
        _proto = (ParChunk*)0;
        _l = (ParLayout*)0;
        }
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_inFlight >= _depth || _s == (Socket*)0 || !_s.isOpen())
            return false;
        Data* d = new Data();
        ParWire.putI64(d, t.index);
        ParWire.putI64(d, t.lo);
        ParWire.putI64(d, t.hi);
        // Each sliced array's and global's slice for this tile: its byte
        // offset, then the bytes — none for a global the tile's items
        // overwrite whole (the kernel fills it), as a discrete card's
        // tile loop stages them.
        u8* obj = proto.objBytes();
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] == (i64)0)
                continue;
            i64 count = l.bufLen[i] / l.bufElem[i];
            i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
            ParWire.putI64(d, e0 * l.bufElem[i]);
            ParWire.putBytes(d, *(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i], e1 > e0 ? (u32)((e1 - e0) * l.bufElem[i]) : (u32)0);
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
            ParWire.putI64(d, e0 * l.globElem[i]);
            ParWire.putBytes(d, (u8*)l.globPtr[i] + e0 * l.globElem[i], e1 > e0 ? (u32)((e1 - e0) * l.globElem[i]) : (u32)0);
            }
        if (!ParWire.send(_s, (u32)PRM_TILE, d))
            return false;
        t.worker = (ParWorker*)self;
        _tiles.add((Object*)t);
        _inFlight = _inFlight + (u32)1;
        return true;
        }
    // A finished tile's frame: its written slices into the program's arrays
    // and globals, its partials folded into a chunk copy.
    ParTile* complete(Data* f)
        {
        u8* p = f.bytes();
        u32 at = (u32)0;
        i64 index = ParWire.rdI64(p, &at);
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
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufIn[i] != (i64)0 || l.bufFp[i] == (i64)0)
                continue;
            i64 e0 = ParWire.rdI64(p, &at);
            i64 e1 = ParWire.rdI64(p, &at);
            u8* b = (u8*)0;
            u32 n = ParWire.rdBytes(p, &at, &b);
            if (e1 > e0 && n == (u32)((e1 - e0) * l.bufElem[i]))
                memcpy((pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]), (pointer)b, (u64)n);
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globIn[i] != (i64)0 || l.globFp[i] == (i64)0)
                continue;
            i64 e0 = ParWire.rdI64(p, &at);
            i64 e1 = ParWire.rdI64(p, &at);
            u8* b = (u8*)0;
            u32 n = ParWire.rdBytes(p, &at, &b);
            if (e1 > e0 && n == (u32)((e1 - e0) * l.globElem[i]))
                memcpy((pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]), (pointer)b, (u64)n);
            }
        if (l.nred > (u32)0)
            {
            u8* raw = (u8*)0;
            ParWire.rdBytes(p, &at, &raw);
            i64 nback = ParWire.rdI64(p, &at);
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
        t.done = true;
        _inFlight = _inFlight - (u32)1;
        return t;
        }
    ParTile* poll(void)
        {
        while (_finished.count() == (u32)0 && _inFlight > (u32)0 && _s != (Socket*)0 && _s.isOpen() && _s.waitReadable((i32)0))
            if (!readFrame())
                break;
        if (_finished.count() == (u32)0)
            return (ParTile*)0;
        ParTile* t = (ParTile*)_finished.get((u32)0);
        _finished.removeAt((u32)0);
        return t;
        }
    void drain(void)
        {
        while (_inFlight > (u32)0 && _s != (Socket*)0 && _s.isOpen())
            {
            _s.waitReadable((i32)-1);
            if (!readFrame())
                break;
            }
        // Tiles a dead connection never returned are not done: the queue's
        // loop ends with them pending and the run fails on, which is the
        // honest outcome until tiles are re-issued (idempotent tiles, step 3).
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

    // XC_PAR_REMOTE=host[:port],host[:port],…: a worker per entry.
    static void addWorkers(Array* into)
        {
        String* v = Platform.env(String.withCString("XC_PAR_REMOTE"));
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
    static ParRemoteChunk* from(u8* p, u32* at, bool data)
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
            if (data)
                {
                if (!c._bufSliced[i])
                    {
                    memcpy((pointer)b.bytes(), (pointer)(p + *at), (u64)c._bufLen[i]);
                    *at = *at + (u32)c._bufLen[i];
                    }
                *(pointer*)(c._obj.bytes() + off) = (pointer)b.bytes();
                }
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
            if (data && !c._globSliced[i])
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

class ParRemoteServe
    {
    // The nimby window (`xcd -nimby hh:mm-hh:mm`): minutes of the local day
    // the daemon takes no block and tells a heartbeat it is unavailable;
    // from -1 means no window. A window may cross midnight.
    static i32 _nimbyFrom;
    static i32 _nimbyTo;
    static void setNimby(i32 fromMinutes, i32 toMinutes)
        {
        _nimbyFrom = fromMinutes;
        _nimbyTo = toMinutes;
        }
    static bool hasNimby(void)
        {
        return _nimbyFrom >= (i32)0;
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
        if (_nimbyFrom < (i32)0)
            return false;
        i32 m = localMinutes();
        if (_nimbyFrom <= _nimbyTo)
            return m >= _nimbyFrom && m < _nimbyTo;
        return m >= _nimbyFrom || m < _nimbyTo;
        }

    // One connection, start to end: the handshake, then blocks and tiles
    // until the program goes away. The GPU workers are the daemon's own.
    static void serve(Socket* s, Array* workers, String* identity)
        {
        // HELLO.
        Data* hello = new Data();
        hello.appendBytes((u8*)"XCD1", (u32)4);
        ParWire.putU32(hello, (u32)PAR_REMOTE_PROTO);
        u8 nonce[32];
        i64 t = ParDevice.nowUs();
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            {
            t = t * (i64)6364136223846793005 + (i64)1442695040888963407;
            nonce[i] = (u8)((u64)t >> (u64)33);
            }
        hello.appendBytes(&nonce[0], (u32)32);
        ParWire.putStr(hello, PAR_CACHE_VER);
        ParWire.putStr(hello, identity.cString());
        u32 depth = (u32)PAR_REMOTE_DEPTH;
        i64 floor = (i64)1024;
        for (u32 i = (u32)0; i < workers.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)workers.get(i);
            if (w.depth() < depth) depth = w.depth();
            if (w.floor() > floor) floor = w.floor();
            }
        ParWire.putU32(hello, depth);
        ParWire.putI64(hello, floor);
        if (!ParWire.send(s, (u32)PRM_HELLO, hello))
            return;
        u32 type = (u32)0;
        Data* auth = ParWire.recv(s, &type, (i32)10000);
        if (auth == (Data*)0 || type != (u32)PRM_AUTH)
            return;
        u8* p = auth.bytes();
        u32 at = (u32)0;
        u32 proto = ParWire.rdU32(p, &at);
        String* version = ParWire.rdStr(p, &at);
        Data* want = ParRemote.proof(&nonce[0]);
        bool ok = proto == (u32)PAR_REMOTE_PROTO && version.equals(String.withCString(PAR_CACHE_VER))
               && auth.length() == at + (u32)32;
        for (u32 i = (u32)0; ok && i < (u32)32; i = i + (u32)1)
            if (p[at + i] != want.byteAt(i))
                ok = false;
        if (!ok)
            {
            Data* why = new Data();
            ParWire.putStr(why, "version or pool secret");
            ParWire.send(s, (u32)PRM_BYE, why);
            Log.info("xcd: a program declined: version %s, protocol %u", version.cString(), proto);
            return;
            }
        ParWire.send(s, (u32)PRM_OK, (Data*)0);
        Log.info("xcd: a program connected");

        ParRemoteChunk* chunk = (ParRemoteChunk*)0;
        ParLayout* l = (ParLayout*)0;
        ParWorker* w = (ParWorker*)0;
        Array* pending = new Array();   // tiles sent and not yet taken
        u32 inFlight = (u32)0;
        while (s.isOpen())
            {
            // Hand pending tiles to the worker while it has room; collect
            // what finished and send it back.
            bool busy = false;
            if (w != (ParWorker*)0)
                {
                while (pending.count() > (u32)0)
                    {
                    ParTile* t0 = (ParTile*)pending.get((u32)0);
                    if (!w.take(t0, (ParChunk*)chunk, chunk.gpuSource(), l))
                        break;
                    pending.removeAt((u32)0);
                    inFlight = inFlight + (u32)1;
                    }
                ParTile* d = w.poll();
                while (d != (ParTile*)0)
                    {
                    busy = true;
                    inFlight = inFlight - (u32)1;
                    ParWire.send(s, (u32)PRM_DONE, ParRemoteServe.doneFrame(chunk, l, d));
                    d = w.poll();
                    }
                }
            // A frame, when one is there (a millisecond's wait while tiles
            // are in flight, else as long as it takes).
            if (!s.waitReadable(inFlight > (u32)0 || pending.count() > (u32)0 ? (i32)1 : (i32)1000))
                continue;
            Data* f = ParWire.recv(s, &type, (i32)-1);
            if (f == (Data*)0)
                break;
            p = f.bytes();
            at = (u32)0;
            if (type == (u32)PRM_HOLDS)
                {
                ParRemoteChunk* c = ParRemoteChunk.from(p, &at, false);
                bool held = false;
                bool nimby = ParRemoteServe.nimbyNow();
                for (u32 i = (u32)0; i < workers.count() && !held && !nimby; i = i + (u32)1)
                    {
                    // Each worker lays the block out from its own section.
                    ParWorker* cand = (ParWorker*)workers.get(i);
                    u8* sec = cand.section(c.gpuSource());
                    ParLayout* lc = sec != (u8*)0 ? ParDevice.layout((ParChunk*)c, sec, (i64)0, (i64)1) : (ParLayout*)0;
                    if (lc != (ParLayout*)0 && cand.forBlock((ParChunk*)c, c.gpuSource(), lc))
                        held = true;
                    }
                Data* a = new Data();
                ParWire.putU8(a, held ? (u8)1 : (u8)0);
                ParWire.send(s, (u32)PRM_ANSWER, a);
                Log.info("xcd: %s %s", c.parName(), held ? "taken" : nimby ? "declined (nimby)" : "declined");
                }
            else if (type == (u32)PRM_PING)
                {
                // The heartbeat: the stamp and kind echoed, whether tiles are
                // welcome now, and how many wait here.
                Data* a = new Data();
                ParWire.putI64(a, ParWire.rdI64(p, &at));
                ParWire.putU8(a, ParWire.rdU8(p, &at));
                ParWire.putU8(a, ParRemoteServe.nimbyNow() ? (u8)0 : (u8)1);
                ParWire.putU32(a, (u32)pending.count() + inFlight);
                ParWire.send(s, (u32)PRM_PONG, a);
                }
            else if (type == (u32)PRM_PREPARE)
                {
                chunk = ParRemoteChunk.from(p, &at, true);
                i64 tile = ParWire.rdI64(p, &at);
                i64 n = ParWire.rdI64(p, &at);
                w = (ParWorker*)0;
                l = (ParLayout*)0;
                for (u32 i = (u32)0; i < workers.count() && w == (ParWorker*)0; i = i + (u32)1)
                    {
                    ParWorker* cand = (ParWorker*)workers.get(i);
                    u8* sec = cand.section(chunk.gpuSource());
                    ParLayout* lc = sec != (u8*)0 ? ParDevice.layout((ParChunk*)chunk, sec, (i64)0, n) : (ParLayout*)0;
                    if (lc != (ParLayout*)0 && cand.forBlock((ParChunk*)chunk, chunk.gpuSource(), lc)
                        && cand.prepare((ParChunk*)chunk, chunk.gpuSource(), lc, tile))
                        {
                        w = cand;
                        l = lc;
                        }
                    }
                Data* a = new Data();
                ParWire.putU8(a, w != (ParWorker*)0 ? (u8)1 : (u8)0);
                ParWire.send(s, (u32)PRM_ANSWER, a);
                pending = new Array();
                inFlight = (u32)0;
                }
            else if (type == (u32)PRM_TILE && w != (ParWorker*)0)
                {
                ParTile* t1 = new ParTile();
                t1.index = ParWire.rdI64(p, &at);
                t1.lo = ParWire.rdI64(p, &at);
                t1.hi = ParWire.rdI64(p, &at);
                // The slices it brought, into the daemon's arrays. A tile
                // still in flight reads other elements, or the same bytes
                // where footprints overlap (a stencil's halo).
                bool fits = true;
                for (u32 i = (u32)0; i < chunk.bufCount() && at <= f.length(); i = i + (u32)1)
                    {
                    if (!chunk.bufSliced(i))
                        continue;
                    i64 off = ParWire.rdI64(p, &at);
                    u8* b = (u8*)0;
                    u32 n = ParWire.rdBytes(p, &at, &b);
                    if (at > f.length() || !chunk.takeSlice(false, i, off, b, n))
                        fits = false;
                    }
                for (u32 i = (u32)0; i < chunk.globCount() && at <= f.length(); i = i + (u32)1)
                    {
                    if (!chunk.globSliced(i))
                        continue;
                    i64 off = ParWire.rdI64(p, &at);
                    u8* b = (u8*)0;
                    u32 n = ParWire.rdBytes(p, &at, &b);
                    if (at > f.length() || !chunk.takeSlice(true, i, off, b, n))
                        fits = false;
                    }
                if (!fits)
                    {
                    Log.info("xcd: a tile's slices do not fit its block; closing");
                    break;
                    }
                pending.add((Object*)t1);
                }
            else if (type == (u32)PRM_FINISH)
                {
                if (w != (ParWorker*)0)
                    {
                    w.drain();
                    ParTile* d2 = w.poll();
                    while (d2 != (ParTile*)0)
                        {
                        ParWire.send(s, (u32)PRM_DONE, ParRemoteServe.doneFrame(chunk, l, d2));
                        d2 = w.poll();
                        }
                    w.finish();
                    }
                w = (ParWorker*)0;
                }
            }
        if (w != (ParWorker*)0)
            {
            w.drain();
            w.finish();
            }
        Log.info("xcd: the program went away");
        }

    // A finished tile for the program: its index, the written slices of
    // every footprinted array and global, and the partials.
    static Data* doneFrame(ParRemoteChunk* chunk, ParLayout* l, ParTile* t)
        {
        Data* d = new Data();
        ParWire.putI64(d, t.index);
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
            ParWire.putBytes(d, *(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i], e1 > e0 ? (u32)((e1 - e0) * l.bufElem[i]) : (u32)0);
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
            ParWire.putBytes(d, (u8*)l.globPtr[i] + e0 * l.globElem[i], e1 > e0 ? (u32)((e1 - e0) * l.globElem[i]) : (u32)0);
            }
        if (l.nred > (u32)0)
            {
            if (t.raw != (Data*)0)
                ParWire.putBytes(d, t.raw.bytes(), t.raw.length());
            else
                ParWire.putU32(d, (u32)0);
            // How many partials each reduction has, by this worker's layout
            // (its kernel form may reduce on the device): the program folds
            // by this count, not its own.
            l.plan(t.lo, t.hi);
            ParWire.putI64(d, l.nback);
            }
        return d;
        }
    }
#endif
