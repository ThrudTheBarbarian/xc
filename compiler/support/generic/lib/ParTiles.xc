// ParTiles.xc — one queue of tiles, several workers (par-tiles-and-devices.md
// step 3). The range is cut into tiles of a size the workers' floors and the
// footprints allow; each worker takes the next tile while it is below its
// depth and holds the block; finished tiles are folded into the block in
// TILE ORDER, whichever worker finished them and in whatever order, so the
// result does not depend on which device took what. A device that cannot
// hold the block is skipped; if none can, the caller runs the block its old
// way.
#import "ParWorker.xc"

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
            String* id = ((ParWorker*)_workers.get(i)).identity();
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
        bool seen = false;
        if (vid.byteLength() > (u32)18)
            {
            String* vname = vid.substringBytes((u32)7, vid.byteLength() - (u32)17);
            for (u32 i = (u32)0; i < _workers.count(); i = i + (u32)1)
                {
                String* cid = ((ParWorker*)_workers.get(i)).identity();
                if (cid.byteLength() > (u32)5 && cid.substringBytes((u32)5, cid.byteLength() - (u32)5).equals(vname))
                    seen = true;
                }
            }
        if (vid.byteLength() > (u32)0 && !seen)
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
        _workers.add((Object*)new ParCpuWorker());
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
            if (!w.holds(proto, src, l))
                continue;
            ws.add((Object*)w);
            if (w.floor() > floor)
                floor = w.floor();
            totalDepth = totalDepth + w.depth();
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
        while (folded < ntiles)
            {
            for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                full[i] = false;
            while (next < ntiles)
                {
                ParTile* pt = (ParTile*)tiles.get((u32)next);
                i64 items = pt.hi - pt.lo;
                i64 now = ParDevice.nowUs();
                i64 best = (i64)-1;
                i64 bestAt = (i64)0;
                for (u32 i = (u32)0; i < nw; i = i + (u32)1)
                    {
                    if (full[i])
                        continue;
                    i64 at;
                    if (doneItems[i] == (i64)0)
                        // Unmeasured: an idle one is tried before anything; a
                        // busy one waits its turn behind every measured one.
                        at = inItems[i] == (i64)0 ? (i64)0 : (i64)1 << (i64)60;
                    else
                        {
                        i64 elapsed = now - firstTake[i];
                        if (elapsed < (i64)1) elapsed = (i64)1;
                        at = (i64)2 + (inItems[i] + items) * elapsed / doneItems[i];
                        }
                    if (best < (i64)0 || at < bestAt)
                        {
                        best = (i64)i;
                        bestAt = at;
                        }
                    }
                if (best < (i64)0)
                    break;
                ParWorker* w = (ParWorker*)ws.get((u32)best);
                if (!w.take(pt, proto, src, l))
                    {
                    full[best] = true;
                    continue;
                    }
                if (firstTake[best] == (i64)0)
                    firstTake[best] = now;
                inItems[best] = inItems[best] + items;
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
            if (!got && inFlight == (u32)0 && next >= ntiles && folded < ntiles)
                break; // nothing in flight and nothing finishing: cannot happen, but do not spin
            }
        for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
            {
            ((ParWorker*)ws.get(i)).drain();
            ((ParWorker*)ws.get(i)).finish();
            }
        i64 took = ParDevice.nowUs() - started;
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
