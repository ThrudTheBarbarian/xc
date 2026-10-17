// ParTiles.xc — one queue of tiles, several workers (par-tiles-and-devices.md
// step 3). The range is cut into tiles of a size the workers' floors and the
// footprints allow; each worker takes the next tile while it is below its
// depth and holds the block; finished tiles are folded into the block in
// TILE ORDER, whichever worker finished them and in whatever order, so the
// result does not depend on which device took what. A device that cannot
// hold the block is skipped; if none can, the caller runs the block its old
// way.
#import "ParWorker.xc"
#import "ParRemote.xc"
#if !(ARCH_6502 || ARCH_m68k)
#import "Thread.xc"
#import "Files.xc"
#endif

// XC_PAR_TRACE=<file>: every tile queue run as fixed binary records, for
// tools/par-trace.html to draw. The file starts "XCPTRACE", a u32 version
// (1) and a u32 0; then 48-byte records, little-endian: u8 kind, u8 worker,
// u16 0, u32 run, five i64 a..e. Times are microseconds from the trace's
// start. Kinds:
//   1 RUN     a items, b tiles, c start, d workers
//   2 WORKER  (worker) a..e: its identity, NUL-padded to 40 bytes
//   3 BLOCK   a..e: the block's name, NUL-padded
//   4 TAKE    (worker) a tile, b lo, c hi, d when, e the queue's estimate of
//             when the worker would finish it (us from now)
//   5 DONE    (worker) a tile, b when, c the device's own time on it (the
//             daemon's for a remote; -1 unknown), d items
//   6 AGAIN   a tile, b when: re-issued (its worker lost or refused it)
//   7 END     a the run's time, b when
// The whole trace is rewritten at the end of each run (a few dozen records
// a run), so a program killed mid-run leaves the runs before it.
class ParTrace
    {
    static Data* _buf;
    static String* _path;
    static i64 _t0;
    static u32 _run;
    static bool _read;
    // XC_PAR_TRACE=host:port: each run's records go to a listener (xcmon)
    // as the run ends, the header first, rather than to a file.
    static Socket* _sock;
    static u32 _sent;
    static bool _net;
    static bool on(void)
        {
        if (!_read)
            {
            _read = true;
            String* p = Platform.env(String.withCString("XC_PAR_TRACE"));
            if (p.byteLength() > (u32)0)
                {
                _path = p;
                _net = ParTrace.isHostPort(p);
                _buf = new Data();
                _buf.appendBytes("XCPTRACE", (u32)8);
                ParTrace.u32le((u32)1);
                ParTrace.u32le((u32)0);
                _t0 = ParDevice.nowUs();
                }
            }
        return _path != (String*)0;
        }
    static i64 now(void)
        {
        return ParDevice.nowUs() - _t0;
        }
    static void u32le(u32 v)
        {
        for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
            _buf.appendByte((u8)(v >> (k * (u32)8)));
        }
    static void i64le(i64 v)
        {
        u64 u = (u64)v;
        for (u64 k = (u64)0; k < (u64)8; k = k + (u64)1)
            _buf.appendByte((u8)(u >> (k * (u64)8)));
        }
    static void rec(u8 kind, u32 worker, i64 a, i64 b, i64 c, i64 d, i64 e)
        {
        _buf.appendByte(kind);
        _buf.appendByte((u8)worker);
        _buf.appendByte((u8)0);
        _buf.appendByte((u8)0);
        ParTrace.u32le(_run);
        ParTrace.i64le(a);
        ParTrace.i64le(b);
        ParTrace.i64le(c);
        ParTrace.i64le(d);
        ParTrace.i64le(e);
        }
    static void text(u8 kind, u32 worker, u8* s)
        {
        _buf.appendByte(kind);
        _buf.appendByte((u8)worker);
        _buf.appendByte((u8)0);
        _buf.appendByte((u8)0);
        ParTrace.u32le(_run);
        u32 n = (u32)0;
        while (s[n] != (u8)0 && n < (u32)40)
            n = n + (u32)1;
        _buf.appendBytes(s, n);
        for (u32 k = n; k < (u32)40; k = k + (u32)1)
            _buf.appendByte((u8)0);
        }
    static void begin(u8* block, Array* ws, i64 n, i64 ntiles)
        {
        if (!ParTrace.on())
            return;
        _run = _run + (u32)1;
        ParTrace.rec((u8)1, (u32)0, n, ntiles, ParTrace.now(), (i64)ws.count(), (i64)0);
        ParTrace.text((u8)3, (u32)0, block);
        for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
            ParTrace.text((u8)2, i, ((ParWorker*)ws.get(i)).identity().cString());
        }
    static void take(u32 worker, ParTile* t, i64 estimate)
        {
        if (ParTrace.on())
            ParTrace.rec((u8)4, worker, t.index, t.lo, t.hi, ParTrace.now(), estimate);
        }
    static void done(u32 worker, ParTile* t)
        {
        if (ParTrace.on())
            ParTrace.rec((u8)5, worker, t.index, ParTrace.now(), t.usTaken > (i64)0 ? t.usTaken : (i64)-1, t.hi - t.lo, (i64)0);
        }
    static void again(ParTile* t)
        {
        if (ParTrace.on())
            ParTrace.rec((u8)6, (u32)0, t.index, ParTrace.now(), (i64)0, (i64)0, (i64)0);
        }
    static void end(i64 took)
        {
        if (!ParTrace.on())
            return;
        ParTrace.rec((u8)7, (u32)0, took, ParTrace.now(), (i64)0, (i64)0, (i64)0);
        if (!_net)
            {
            Files.writeData(_path, _buf);
            return;
            }
        // The listener gets what it has not had yet. One that cannot be
        // reached turns tracing off rather than slowing every run.
        if (_sock == (Socket*)0)
            {
            u32 colon = _path.byteLength();
            while (colon > (u32)0 && _path.byteAt(colon - (u32)1) != (u8)':')
                colon = colon - (u32)1;
            u32 port = (u32)0;
            for (u32 i = colon; i < _path.byteLength(); i = i + (u32)1)
                port = port * (u32)10 + (u32)(_path.byteAt(i) - (u8)'0');
            try
                {
                _sock = Socket.connect(_path.substringBytes((u32)0, colon - (u32)1), (u16)port);
                _sock.setNoDelay();
                }
            catch (SocketError e)
                {
                Log.info("par: XC_PAR_TRACE: %s", e.message().cString());
                _path = (String*)0;
                return;
                }
            }
        if (!_sock.write(_buf.bytes() + _sent, _buf.length() - _sent))
            {
            _path = (String*)0;
            return;
            }
        _sent = _buf.length();
        }

    // `host:port` (digits after the last colon, no slash) rather than a file.
    static bool isHostPort(String* p)
        {
        u32 colon = p.byteLength();
        while (colon > (u32)0 && p.byteAt(colon - (u32)1) != (u8)':')
            colon = colon - (u32)1;
        if (colon <= (u32)1 || colon == p.byteLength())
            return false;
        for (u32 i = colon; i < p.byteLength(); i = i + (u32)1)
            if (p.byteAt(i) < (u8)'0' || p.byteAt(i) > (u8)'9')
                return false;
        for (u32 i = (u32)0; i < p.byteLength(); i = i + (u32)1)
            if (p.byteAt(i) == (u8)'/' || p.byteAt(i) == (u8)'\\')
                return false;
        return true;
        }
    }

class ParTiles
    {
    // Element range [e0, e1) of a footprinted buffer of `count` elements
    // that the work items [tlo, thi) touch, clipped to the buffer.
    static i64 sliceLo(i64 k, i64 flo, i64 tlo, i64 count)
        {
        i64 e0 = k * tlo + flo;
        if (e0 < (i64)0) e0 = (i64)0;
        if (e0 > count) e0 = count;
        return e0;
        }
    static i64 sliceHi(i64 k, i64 fhi, i64 thi, i64 count)
        {
        i64 e1 = k * (thi - (i64)1) + fhi;
        if (e1 < (i64)0) e1 = (i64)0;
        if (e1 > count) e1 = count;
        return e1;
        }

    // The bytes a tile of `items` work items moves for a device with its own
    // memory: every footprinted slice up, the written ones down again.
    static i64 tileBytes(ParLayout* l, i64 items)
        {
        i64 b = (i64)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufFp[i] != (i64)0)
                b = b + (l.bufFpK[i] * items + (l.bufFpHi[i] - l.bufFpLo[i])) * l.bufElem[i] * (l.bufIn[i] != (i64)0 ? (i64)1 : (i64)2);
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globFp[i] != (i64)0)
                b = b + (l.globFpK[i] * items + (l.globFpHi[i] - l.globFpLo[i])) * l.globElem[i] *
                        (l.globIn[i] != (i64)0 || (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1) ? (i64)1 : (i64)2);
        return b;
        }
    // The items that move XC_PAR_TILE_MB per tile; 0 when nothing moves.
    static i64 tileItemsFor(ParLayout* l)
        {
        i64 perItem = ParTiles.tileBytes(l, (i64)1) - ParTiles.tileBytes(l, (i64)0);
        if (perItem <= (i64)0)
            return (i64)0;
        return (ParDevice.tileMegabytes() << (i64)20) / perItem;
        }

    // The workers for this process, made once. XC_PAR_WORKERS names them
    // ("cpu", "cuda", "metal", "vulkan", "cuda,vulkan,cpu") and then every
    // block runs on the queue, whatever auto would choose; unset, the
    // default set is every GPU the box has (each CUDA card; Vulkan for a
    // card CUDA does not reach; Metal) and the CPU pool, and auto measures
    // the queue's sets against the one GPU and the CPU (ParDevice.choose).
    static Array* _workers;
    static i32 _state;   // 0 unread, 1 named, 2 the default set (made when first needed)
    static String* _ids;

    static bool explicit(void)
        {
        if (_state == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR_WORKERS"));
            if (v.byteLength() > (u32)0)
                {
                _workers = new Array();
                ParTiles.makeWorkers(v);
                ParTiles.count();
                _state = (i32)1;
                }
            else
                _state = (i32)2;
            }
        return _state == (i32)1;
        }

    // The default set is made the first time auto's key or a queue run
    // needs it, not at the first par: opening every GPU costs hundreds of
    // milliseconds, and a block XC_PAR=cpu or a setting keeps on the CPU
    // never needs them.
    static void ready(void)
        {
        ParTiles.explicit();
        if (_workers == (Array*)0)
            {
            _workers = new Array();
            ParTiles.defaultWorkers();
            ParTiles.count();
            }
        }

    // The GPU workers in the set, for auto; and the sorted identities, for
    // its hardware key.
    static void count(void)
        {
        u32 gpus = (u32)0;
        Array* ids = new Array();
        for (u32 i = (u32)0; i < _workers.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)_workers.get(i);
            // A worker whose physical device a preferred peer also drives (the
            // Vulkan view of a card CUDA runs) is a per-block fallback, not a
            // device of its own: its peer already stands for that card in the
            // hardware key and the GPU count, so leaving it out keeps the
            // learned cache valid across this change (it is still in the pool
            // and dispatched to for a block only its back end can take).
            if (w._preferredPeer != (ParWorker*)0)
                continue;
            String* id = w.identity();
            if (!id.equals(String.withCString("cpu")))
                gpus = gpus + (u32)1;
            // Insertion, in byte order.
            u32 at = (u32)0;
            while (at < ids.count() && ParTiles.before((String*)ids.get(at), id))
                at = at + (u32)1;
            ids.insert(at, (Object*)id);
            }
        gParGpuWorkers = gpus;
        _ids = new String();
        for (u32 i = (u32)0; i < ids.count(); i = i + (u32)1)
            {
            if (i > (u32)0) _ids.appendCString(",");
            _ids.append((String*)ids.get(i));
            }
        }
    static bool before(String* a, String* b)
        {
        u32 n = a.byteLength() < b.byteLength() ? a.byteLength() : b.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            if (a.byteAt(i) != b.byteAt(i))
                return a.byteAt(i) < b.byteAt(i);
        return a.byteLength() < b.byteLength();
        }
    static String* identities(void)
        {
        ParTiles.ready();
        return _ids;
        }

    // Every GPU on the box, then the CPU pool. A card CUDA reaches is not
    // added again through Vulkan: a Vulkan identity is
    // "vulkan:<name>:<vendor>:<device>", a CUDA one "cuda:<name>".
    static void defaultWorkers(void)
        {
#if ARCH_win64
        if (!ParDevice.vulkanOnly())
            ParCuda.addWorkers(_workers);
        ParVulkanWorker* vk = new ParVulkanWorker();
        String* vid = vk.identity();
        // A card CUDA also drives keeps BOTH workers in the pool; the CUDA one
        // is the Vulkan worker's preferred peer, so CUDA runs the card for any
        // block it can take and Vulkan only steps in for a block with no PTX.
        // (It was dropped here before, which left such a card idle.)
        if (vid.byteLength() > (u32)18)
            {
            String* vname = vid.substringBytes((u32)7, vid.byteLength() - (u32)17);
            for (u32 i = (u32)0; i < _workers.count(); i = i + (u32)1)
                {
                ParWorker* w = (ParWorker*)_workers.get(i);
                String* cid = w.identity();
                if (cid.byteLength() > (u32)5 && cid.substringBytes((u32)5, cid.byteLength() - (u32)5).equals(vname))
                    vk._preferredPeer = w;
                }
            }
        if (vid.byteLength() > (u32)0)
            _workers.add((Object*)vk);
#elif ARCH_x86_64 || (ARCH_arm64 && PLATFORM_android)
        ParVulkanWorker* vk = new ParVulkanWorker();
        if (vk.identity().byteLength() > (u32)0)
            _workers.add((Object*)vk);
#elif ARCH_arm64 && !PLATFORM_ios
        ParMetalWorker* mtl = new ParMetalWorker();
        if (mtl.identity().byteLength() > (u32)0)
            _workers.add((Object*)mtl);
#endif
        // GPUs on other machines (ParRemote.xc), named by XC_PAR_REMOTE;
        // before the CPU pool, after the local devices.
        ParRemote.addWorkers(_workers);
        _workers.add((Object*)new ParCpuWorker());
        }

    // The local GPU workers, for a daemon that serves them to other machines
    // (xcd): the default set less the CPU pool and less the remote ones.
    static Array* gpuWorkers(void)
        {
        ParTiles.ready();
        Array* out = new Array();
        for (u32 i = (u32)0; i < _workers.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)_workers.get(i);
            String* id = w.identity();
            if (id.equals(String.withCString("cpu")) || id.hasPrefix(String.withCString("remote:")))
                continue;
            out.add((Object*)w);
            }
        return out;
        }

    // The named workers, GPUs before the CPU pool whatever the order given.
    static void makeWorkers(String* names)
        {
        bool cpu = false;
        u32 at = (u32)0;
        while (at < names.byteLength())
            {
            u32 end = at;
            while (end < names.byteLength() && names.byteAt(end) != (u8)',')
                end = end + (u32)1;
            String* name = names.substringBytes(at, end - at);
            if (name.equals(String.withCString("cpu")))
                cpu = true;
#if ARCH_win64
            else if (name.equals(String.withCString("cuda")))
                ParCuda.addWorkers(_workers);
#endif
#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
            else if (name.equals(String.withCString("metal")))
                _workers.add((Object*)new ParMetalWorker());
#endif
#if ARCH_x86_64 || ARCH_win64 || (ARCH_arm64 && PLATFORM_android)
            else if (name.equals(String.withCString("vulkan")))
                _workers.add((Object*)new ParVulkanWorker());
#endif
            at = end + (u32)1;
            }
        if (cpu)
            _workers.add((Object*)new ParCpuWorker());
        }

    // Run [lo, hi) of the block as tiles across the workers: set 0 is the
    // named list, 3 the GPU workers of the default set, 4 all of it. False
    // when no worker holds the block, before anything ran.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi, i32 set)
        {
        ParTiles.ready();
        if (_workers.count() == (u32)0)
            return false;
        // The CPU lanes are the queue's too: a block inside a tile, or a par
        // on another thread meanwhile, takes the single-device path.
        if (!ParCpuLanes.lock().tryLock())
            return false;
        bool ran = ParTiles.runLocked(proto, src, lo, hi, set);
        ParCpuLanes.lock().unlock();
        return ran;
        }

    // The probe's pass: one worker alone, one tile size, set by probe()
    // around a run and cleared after it.
    static ParWorker* _probeWorker;
    static i64 _probeTile;

    // XC_PAR_PROBE=1: the block's first run as a sweep. Every worker that
    // takes the block runs it alone at tile sizes from its floor up by
    // powers of two to half the range, a pass each; the written arrays and
    // globals are copied aside first and put back before every pass, since
    // a block that reads what it writes (`ys[i] = xs[i] + ys[i]`) is not the
    // same twice; reductions fold into a throwaway chunk. The KNEE is the
    // smallest size at nine tenths of the best rate, the SATURATION the
    // size of the best. The findings are saved as priors (ParDevice.
    // saveProbe, learn) and reported; the caller then runs the block for
    // real, from them. Owner 2026-10-16: boundaries found, not evolved.
    static bool probe(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        ParDevice.setProbed(proto);
        ParTiles.ready();
        if (_workers.count() == (u32)0 || src == (u8*)0 || src[0] == (u8)0)
            return false;
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        i64 n = hi - lo;
        Array* ws = new Array();
        for (u32 i = (u32)0; i < _workers.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)_workers.get(i);
            if (w.forBlock(proto, src, l))
                ws.add((Object*)w);
            }
        if (ws.count() == (u32)0 || n < (i64)2048)
            return false;
        // What the block writes, kept aside.
        u8* obj = proto.objBytes();
        Array* keptBuf = new Array();
        Array* keptGlob = new Array();
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            keptBuf.add(l.bufIn[i] == (i64)0 && l.bufLen[i] > (i64)0
                        ? (Object*)Data.withBytes(*(u8**)(obj + l.bufOff[i]), (u32)l.bufLen[i]) : (Object*)0);
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            keptGlob.add(l.globIn[i] == (i64)0 && l.globLen[i] > (i64)0
                         ? (Object*)Data.withBytes((u8*)l.globPtr[i], (u32)l.globLen[i]) : (Object*)0);
        String* record = new String();
        i64 bestCpuUs = (i64)-1;
        i64 bestGpuUs = (i64)-1;
        for (u32 k = (u32)0; k < ws.count(); k = k + (u32)1)
            {
            ParWorker* w = (ParWorker*)ws.get(k);
            i64 floor = w.floor() < (i64)1024 ? (i64)1024 : w.floor();
            i64 sizes[32];
            i64 rates[32];
            u32 np = (u32)0;
            i64 best = (i64)0;
            i64 bestS = (i64)0;
            i64 bestUs = (i64)-1;
            i64 linkUs = (i64)-1;
            for (i64 s = floor; s * (i64)2 <= n && np < (u32)32; s = s * (i64)2)
                {
                ParTiles.restore(l, obj, keptBuf, keptGlob);
                ParChunk* scratch = proto.copyChunk();
                _probeWorker = w;
                _probeTile = s;
                i64 t0 = ParDevice.nowUs();
                bool ok = ParTiles.run(scratch, src, lo, hi, (i32)0);
                i64 us = ParDevice.nowUs() - t0;
                _probeWorker = (ParWorker*)0;
                _probeTile = (i64)0;
                if (!ok)
                    break;
                if (us < (i64)1)
                    us = (i64)1;
                i64 rate = (n << (i64)10) / us;
                sizes[np] = s;
                rates[np] = rate;
                np = np + (u32)1;
                if (ParDevice.reporting())
                    Log.info("par: probe: %s: %s: tiles of %ld: %ld us (%ld items/ms)", proto.parName(), w.identity().cString(), s, us, rate * (i64)1000 >> (i64)10);
                if (rate > best)
                    {
                    best = rate;
                    bestS = s;
                    bestUs = us;
                    linkUs = w.kernelUs() >= (i64)0 ? us - w.kernelUs() : (i64)-1;
                    }
                }
            if (np == (u32)0)
                continue;
            i64 knee = bestS;
            for (u32 q = (u32)0; q < np; q = q + (u32)1)
                if (rates[q] * (i64)10 >= best * (i64)9)
                    {
                    knee = sizes[q];
                    break;
                    }
            if (ParDevice.reporting())
                {
                if (linkUs >= (i64)0)
                    Log.info("par: probe: %s: %s: knee %ld, saturation %ld, %ld items/ms, link %ld us of %ld", proto.parName(), w.identity().cString(), knee, bestS, best * (i64)1000 >> (i64)10, linkUs, bestUs);
                else
                    Log.info("par: probe: %s: %s: knee %ld, saturation %ld, %ld items/ms", proto.parName(), w.identity().cString(), knee, bestS, best * (i64)1000 >> (i64)10);
                }
            record.append(w.identity());
            record.appendFormat(":%ld:%ld:%ld;", knee, bestS, best);
            bool cpu = w.identity().equals(String.withCString("cpu"));
            if (cpu && (bestCpuUs < (i64)0 || bestUs < bestCpuUs))
                bestCpuUs = bestUs;
            if (!cpu && (bestGpuUs < (i64)0 || bestUs < bestGpuUs))
                bestGpuUs = bestUs;
            }
        ParTiles.restore(l, obj, keptBuf, keptGlob);
        if (record.byteLength() > (u32)0)
            ParDevice.saveProbe(proto, record);
        // The device crossover at this size, as a prior for auto: the CPU
        // pool against the best single GPU.
        if (bestCpuUs >= (i64)0 && bestGpuUs >= (i64)0)
            ParDevice.learn(ParDevice.slot(proto.parName()), proto, n, bestCpuUs <= bestGpuUs ? (i32)1 : (i32)2);
        return true;
        }
    static void restore(ParLayout* l, u8* obj, Array* keptBuf, Array* keptGlob)
        {
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            Data* d = (Data*)keptBuf.get(i);
            if (d != (Data*)0)
                memcpy((pointer)*(u8**)(obj + l.bufOff[i]), (pointer)d.bytes(), (u64)d.length());
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            Data* d = (Data*)keptGlob.get(i);
            if (d != (Data*)0)
                memcpy((pointer)l.globPtr[i], (pointer)d.bytes(), (u64)d.length());
            }
        }

    static bool runLocked(ParChunk* proto, u8* src, i64 lo, i64 hi, i32 set)
        {
        i64 started = ParDevice.nowUs();
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        Array* ws = new Array();
        i64 floor = (i64)1;
        u32 totalDepth = (u32)0;
        for (u32 i = (u32)0; i < _workers.count() && ws.count() < (u32)16; i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)_workers.get(i);
            if (set == (i32)3 && w.identity().equals(String.withCString("cpu")))
                continue;
            // forBlock, not holds: a worker whose device a preferred peer runs
            // for this block stands aside, so the pool can carry both back ends
            // for one card and pick per block.
            if (!w.forBlock(proto, src, l))
                {
                if (ParDevice.reporting())
                    {
                    ParWorker* peer = w.standsAsideFor(proto, src, l);
                    if (peer != (ParWorker*)0)
                        Log.info("par: %s: %s stands aside, %s runs the same card", proto.parName(), w.identity().cString(), peer.identity().cString());
                    else
                        Log.info("par: %s: %s does not take the block as tiles", proto.parName(), w.identity().cString());
                    }
                continue;
                }
            ws.add((Object*)w);
            if (w.floor() > floor)
                floor = w.floor();
            totalDepth = totalDepth + w.depth();
            }
        if (_probeWorker != (ParWorker*)0)
            {
            // The probe's pass: that worker alone.
            ws = new Array();
            ws.add((Object*)_probeWorker);
            floor = _probeWorker.floor();
            totalDepth = _probeWorker.depth();
            }
        if (ws.count() == (u32)0)
            return false;
        i64 n = hi - lo;
        // Tiles: the smallest size a GPU worker prefers (its bytes moved per
        // tile), else enough for every worker to hold its depth twice over;
        // at least the largest floor, a multiple of 1024 items.
        i64 tile = (i64)0;
        for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
            {
            i64 want = ((ParWorker*)ws.get(i)).tileItems(l);
            if (want > (i64)0 && (tile == (i64)0 || want < tile))
                tile = want;
            }
        if (tile == (i64)0)
            tile = n / (i64)(totalDepth * (u32)2);
        // Several workers: at least two tiles each, so none sits idle.
        if (ws.count() >= (u32)2)
            {
            i64 cap = n / (i64)(ws.count() * (u32)2);
            cap = (cap + (i64)1023) & ~(i64)1023;
            if (cap < floor) cap = floor;
            if (tile > cap) tile = cap;
            }
        if (tile < floor)
            tile = floor;
        tile = (tile + (i64)1023) & ~(i64)1023;
        // A tile costs the queue a fixed amount — submit, fences, the host
        // round trip, some 25-40 us through CUDA under Windows — so a block
        // the single GPU runs in a few hundred microseconds must not be cut
        // into dozens of them (mandelbrot: 140 us of kernel in 18 tiles took
        // 575 us). Where auto has the single GPU's time for this size, the
        // tile count is capped so the fixed costs stay under a tenth of the
        // run, with at least two tiles a worker.
        u32 bi = ParDevice.slot(proto.parName());
        if (gParGpuUs[bi] > (i64)0 && gParMeasN[bi] > (i64)0)
            {
            i64 expect = gParGpuUs[bi] * n / gParMeasN[bi];
            i64 most = expect / (i64)(10 * 40);
            if (most < (i64)(ws.count() * (u32)2))
                most = (i64)(ws.count() * (u32)2);
            if (n / tile > most)
                {
                tile = (n + most - (i64)1) / most;
                tile = (tile + (i64)1023) & ~(i64)1023;
                }
            }
        // And where the queue itself has run the block, the fastest worker's
        // rate then sets the least a tile may be worth: 400 us of its work,
        // ten times the fixed cost. A block too small for two such tiles is
        // one the queue declines (below), and the single GPU runs it — the
        // 140 us mandelbrot kernel, 18 tiles and 575 us on the first run,
        // 250 us single-shot on every run after.
        if (gParTileRate[bi] > (i64)0)
            {
            i64 least = (gParTileRate[bi] * (i64)400) >> (i64)10;
            least = (least + (i64)1023) & ~(i64)1023;
            if (tile < least)
                tile = least;
            }
        // The probe's pass sets the size outright; a probed block's knee is
        // the least a tile may be on a later run (the prior).
        if (_probeTile > (i64)0)
            tile = _probeTile;
        else
            {
            i64 kneeMax = (i64)0;
            for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
                {
                i64 pk = (i64)0;
                i64 ps = (i64)0;
                i64 pr = (i64)0;
                if (ParDevice.probePrior(proto, ((ParWorker*)ws.get(i)).identity(), &pk, &ps, &pr) && pk > kneeMax)
                    kneeMax = pk;
                }
            if (kneeMax > (i64)0 && tile < kneeMax && kneeMax * (i64)2 * (i64)ws.count() <= n)
                tile = kneeMax;
            }
        if (tile > n)
            tile = n;
        // The tile list: full tiles, then a tail that shrinks towards the
        // floor, so the last tiles are small and no worker waits long on
        // another's big one (guided self-scheduling). The fold order is the
        // list order, which depends on n and the workers alone.
        Array* tiles = new Array();
        i64 at = lo;
        i64 t = (i64)0;
        // The last depth's worth of the range goes as half tiles.
        i64 tailFrom = (i64)totalDepth * tile;
        i64 half = ((tile / (i64)2) + (i64)1023) & ~(i64)1023;
        if (half < floor) half = floor;
        while (at < hi)
            {
            i64 left = hi - at;
            i64 size = tile;
            if (left <= tailFrom && n > tailFrom)
                size = half;
            if (size > left) size = left;
            ParTile* pt = new ParTile();
            pt.index = t;
            pt.lo = at;
            pt.hi = at + size;
            tiles.add((Object*)pt);
            at = at + size;
            t = t + (i64)1;
            }
        i64 ntiles = t;
        // One tile is one device's single shot with the queue's overhead on
        // top: auto's sets decline it (and learn that), the named list runs.
        if (ntiles < (i64)2 && set != (i32)0)
            {
            ParDevice.setDeclined(proto, set);
            return false;
            }
        // Each worker readies itself for tiles of this size; one that cannot
        // drops out of this run.
        Array* ready = new Array();
        for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)ws.get(i);
            if (w.prepare(proto, src, l, tile))
                ready.add((Object*)w);
            else if (ParDevice.reporting())
                Log.info("par: %s: %s could not prepare for tiles of %ld items", proto.parName(), w.identity().cString(), tile);
            }
        ws = ready;
        if (ws.count() == (u32)0)
            {
            if (set != (i32)0)
                ParDevice.setDeclined(proto, set);
            return false;
            }
        i64 next = (i64)0;      // the next tile to hand out
        i64 folded = (i64)0;    // tiles folded so far, in order
        u32 inFlight = (u32)0;
        // Each worker's throughput so far (items per us, from its finished
        // tiles over the time since its first), and the items it holds: a
        // tile goes to whichever worker with room would finish it first, so
        // a slow device beside a fast one takes its share and no more, and
        // is not left holding the last tiles. Until a worker has a rate it
        // is tried in list order (GPUs first), up to its depth.
        u32 nw = ws.count();
        if (nw > (u32)16)
            nw = (u32)16;
        i64 inItems[16];
        i64 doneItems[16];
        i64 firstTake[16];
        bool full[16];
        for (u32 i = (u32)0; i < nw; i = i + (u32)1)
            {
            inItems[i] = (i64)0;
            doneItems[i] = (i64)0;
            firstTake[i] = (i64)0;
            }
        // The workers' rates are seeded from auto's measurements of the block
        // at this size, where it has them (the CPU's and the single GPU's; a
        // second card takes the first's and corrects itself from its tiles).
        // Unmeasured, an idle worker is given a tile before anything and a
        // busy one waits behind every measured one — and the CPU pool runs
        // each tile on ONE lane, so a GPU-sized tile there is a run of its
        // own: mandel_deep's 2M items took 10 s on a lane beside the GPUs'
        // 15 ms for the rest, every run of the all-devices set. Seeded, the
        // pool is offered a tile only when it would finish it before the
        // GPUs' queues would, which for a block the GPU wins by a hundredfold
        // is never.
        bool isCpuW[16];
        for (u32 i = (u32)0; i < nw; i = i + (u32)1)
            isCpuW[i] = ((ParWorker*)ws.get(i)).identity().equals(String.withCString("cpu"));
        if (gParMeasN[bi] > (i64)0)
            for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                {
                i64 us = isCpuW[i] ? gParCpuUs[bi] : gParGpuUs[bi];
                if (us > (i64)0)
                    {
                    doneItems[i] = gParMeasN[bi];
                    firstTake[i] = ParDevice.nowUs() - us;
                    }
                }
        // A probed block's rates seed the workers auto never measured (every
        // remote, a second card): the prior the probe left.
        for (u32 i = (u32)0; i < nw; i = i + (u32)1)
            {
            if (doneItems[i] != (i64)0 || _probeWorker != (ParWorker*)0)
                continue;
            i64 pk = (i64)0;
            i64 ps = (i64)0;
            i64 pr = (i64)0;
            if (ParDevice.probePrior(proto, ((ParWorker*)ws.get(i)).identity(), &pk, &ps, &pr) && pr > (i64)0)
                {
                doneItems[i] = n;
                firstTake[i] = ParDevice.nowUs() - ((n << (i64)10) / pr);
                if (ParDevice.tracing())
                    Log.info("par: %s: %s seeded from the probe (%ld items/ms)", proto.parName(), ((ParWorker*)ws.get(i)).identity().cString(), pr * (i64)1000 >> (i64)10);
                }
            }
        ParTrace.begin(proto.parName(), ws, n, ntiles);
        // Tiles a worker took and lost (its connection died) go out again,
        // before the ones not yet handed out: a tile is idempotent.
        Array* again = new Array();
        i64 reissued = (i64)0;
        while (folded < ntiles)
            {
            for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                {
                full[i] = false;
                Array* lostT = ((ParWorker*)ws.get(i)).lost();
                if (lostT == (Array*)0)
                    continue;
                for (u32 k = (u32)0; k < lostT.count(); k = k + (u32)1)
                    {
                    ParTile* lt = (ParTile*)lostT.get(k);
                    lt.done = false;
                    lt.worker = (ParWorker*)0;
                    lt.partial = (ParChunk*)0;
                    inFlight = inFlight - (u32)1;
                    inItems[i] = inItems[i] - (lt.hi - lt.lo);
                    again.add((Object*)lt);
                    ParTrace.again(lt);
                    reissued = reissued + (i64)1;
                    }
                }
            while (next < ntiles || again.count() > (u32)0)
                {
                bool fromAgain = again.count() > (u32)0;
                ParTile* pt = fromAgain ? (ParTile*)again.get((u32)0) : (ParTile*)tiles.get((u32)next);
                i64 items = pt.hi - pt.lo;
                i64 now = ParDevice.nowUs();
                i64 best = (i64)-1;
                i64 bestAt = (i64)0;
                // The soonest a worker already at its depth would finish this
                // tile: when that beats every worker with room, the tile waits
                // for it rather than going to a slower one. Without this the
                // CPU pool, last in the list, was handed a tile the moment
                // both GPUs were full — a run of its own on one lane.
                i64 fullAt = (i64)-1;
                // The best measured rate among the GPU workers, as us per
                // item scaled by 2^20, for the CPU pool's prior below.
                i64 gpuUsPerItem = (i64)-1;
                for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                    if (!isCpuW[i] && doneItems[i] != (i64)0)
                        {
                        i64 elapsed = now - firstTake[i];
                        if (elapsed < (i64)1) elapsed = (i64)1;
                        i64 r = (elapsed << (i64)20) / doneItems[i];
                        if (gpuUsPerItem < (i64)0 || r < gpuUsPerItem)
                            gpuUsPerItem = r;
                        }
                for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                    {
                    // Not available this round (a remote worker too loaded, say):
                    // skipped now, offered again next round once it is ready.
                    if (!((ParWorker*)ws.get(i)).ready(now))
                        continue;
                    i64 at;
                    if (doneItems[i] == (i64)0 && isCpuW[i] && nw > (u32)1)
                        {
                        // The CPU pool unmeasured beside GPUs: never first (a
                        // GPU-sized tile on one lane is a run of its own), and
                        // until a GPU is measured not at all; then it is taken
                        // as a hundred times slower than the best GPU for a
                        // block that computes, twice as slow for one that
                        // moves memory, until its own tiles say otherwise.
                        if (gpuUsPerItem < (i64)0)
                            continue;
                        i64 k = ParDevice.computeBound(l) ? (i64)100 : (i64)2;
                        at = (i64)2 + (((inItems[i] + items) * gpuUsPerItem) >> (i64)20) * k;
                        }
                    else if (doneItems[i] == (i64)0)
                        // Unmeasured: an idle one is tried before anything; a
                        // busy one waits its turn behind every measured one.
                        at = inItems[i] == (i64)0 ? (i64)0 : (i64)1 << (i64)60;
                    else
                        {
                        i64 elapsed = now - firstTake[i];
                        if (elapsed < (i64)1) elapsed = (i64)1;
                        at = (i64)2 + (inItems[i] + items) * elapsed / doneItems[i];
                        // A remote whose daemon holds this tile's slices
                        // already skips their upload (its cache).
                        at = at - ((ParWorker*)ws.get(i)).cachedSaving(pt);
                        if (at < (i64)2) at = (i64)2;
                        }
                    if (full[i])
                        {
                        if (doneItems[i] != (i64)0 && (fullAt < (i64)0 || at < fullAt))
                            fullAt = at;
                        continue;
                        }
                    if (best < (i64)0 || at < bestAt)
                        {
                        best = (i64)i;
                        bestAt = at;
                        }
                    }
                if (best < (i64)0)
                    break;
                if (fullAt >= (i64)0 && fullAt < bestAt)
                    break;
                ParWorker* w = (ParWorker*)ws.get((u32)best);
                if (!w.take(pt, proto, src, l))
                    {
                    full[best] = true;
                    continue;
                    }
                if (firstTake[best] == (i64)0)
                    firstTake[best] = now;
                ParTrace.take((u32)best, pt, bestAt);
                if (ParDevice.tracing())
                    Log.info("par: tile %ld [%ld, %ld) -> %s (would finish in %ld us) at +%ld us",
                             pt.index, pt.lo, pt.hi, w.identity().cString(), bestAt, now - started);
                inItems[best] = inItems[best] + items;
                if (fromAgain)
                    again.removeAt((u32)0);
                else
                    next = next + (i64)1;
                inFlight = inFlight + (u32)1;
                }
            // Collect what finished; fold in tile order.
            bool got = false;
            for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                {
                ParWorker* w = (ParWorker*)ws.get(i);
                ParTile* d = w.poll();
                while (d != (ParTile*)0)
                    {
                    got = true;
                    ParTrace.done(i, d);
                    inFlight = inFlight - (u32)1;
                    inItems[i] = inItems[i] - (d.hi - d.lo);
                    doneItems[i] = doneItems[i] + (d.hi - d.lo);
                    d = w.poll();
                    }
                }
            while (folded < ntiles && ((ParTile*)tiles.get((u32)folded)).done)
                {
                ParTile* d = (ParTile*)tiles.get((u32)folded);
                if (d.partial != (ParChunk*)0)
                    proto.merge(d.partial);
                d.partial = (ParChunk*)0;
                folded = folded + (i64)1;
                }
            if (!got && inFlight == (u32)0 && next >= ntiles && again.count() == (u32)0 && folded < ntiles)
                break; // nothing in flight and nothing finishing: cannot happen, but do not spin
            // Tiles remain, nothing is in flight and no worker is ready (every
            // remote in its nimby window, say): wait a little rather than
            // spin, and ask again — unless every worker is gone for good.
            if (!got && inFlight == (u32)0 && (next < ntiles || again.count() > (u32)0))
                {
                bool anyAlive = false;
                for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                    if (!((ParWorker*)ws.get(i)).dead())
                        anyAlive = true;
                if (!anyAlive)
                    break;
                Thread.sleepMs((u32)1);
                }
            }
        for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
            {
            ((ParWorker*)ws.get(i)).drain();
            ((ParWorker*)ws.get(i)).finish();
            }
        i64 took = ParDevice.nowUs() - started;
        ParTrace.end(took);
        if (reissued > (i64)0 && ParDevice.reporting())
            Log.info("par: %s: %ld tile(s) re-issued after a worker was lost", proto.parName(), reissued);
        // The fastest worker's rate, for the next run's tile sizing.
        i64 ended = ParDevice.nowUs();
        for (u32 i = (u32)0; i < nw; i = i + (u32)1)
            if (doneItems[i] > (i64)0 && ended > firstTake[i])
                {
                i64 r = (doneItems[i] << (i64)10) / (ended - firstTake[i]);
                if (r > gParTileRate[bi])
                    gParTileRate[bi] = r;
                }
        if (ParDevice.reporting())
            {
            String* names = new String();
            for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
                {
                if (i > (u32)0) names.appendCString(", ");
                names.append(((ParWorker*)ws.get(i)).identity());
                }
            Log.info("par: %s: %ld items in %ld tiles across %s (%ld us)", proto.parName(), n, ntiles, names.cString(), took);
            }
        if (set != (i32)0)
            ParDevice.ranOnSet(proto, set, took);
        return true;
        }
    }
