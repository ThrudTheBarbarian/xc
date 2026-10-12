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

    // The workers for this process, made once: XC_PAR_WORKERS names them
    // ("cpu", "cuda", "cuda,cpu"); empty keeps the old single-device path.
    static Array* _workers;
    static i32 _state;   // 0 unread, 1 workers, 2 none

    static bool wanted(void)
        {
        if (_state == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR_WORKERS"));
            _workers = new Array();
            if (v.byteLength() > (u32)0)
                ParTiles.makeWorkers(v);
            _state = _workers.count() > (u32)0 ? (i32)1 : (i32)2;
            }
        return _state == (i32)1;
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
            at = end + (u32)1;
            }
        if (cpu)
            _workers.add((Object*)new ParCpuWorker());
        }

    // Run [lo, hi) of the block as tiles across the workers. False when no
    // worker holds the block, before anything ran.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        if (!wanted())
            return false;
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        Array* ws = new Array();
        i64 floor = (i64)1;
        u32 totalDepth = (u32)0;
        for (u32 i = (u32)0; i < _workers.count(); i = i + (u32)1)
            {
            ParWorker* w = (ParWorker*)_workers.get(i);
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
        if (tile < floor)
            tile = floor;
        tile = (tile + (i64)1023) & ~(i64)1023;
        if (tile > n)
            tile = n;
        i64 ntiles = (n + tile - (i64)1) / tile;
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
            return false;
        Array* tiles = new Array();
        for (i64 t = (i64)0; t < ntiles; t = t + (i64)1)
            {
            ParTile* pt = new ParTile();
            pt.index = t;
            pt.lo = lo + t * tile;
            pt.hi = pt.lo + tile;
            if (pt.hi > hi)
                pt.hi = hi;
            tiles.add((Object*)pt);
            }
        i64 started = ParDevice.nowUs();
        i64 next = (i64)0;      // the next tile to hand out
        i64 folded = (i64)0;    // tiles folded so far, in order
        u32 inFlight = (u32)0;
        while (folded < ntiles)
            {
            // Hand out tiles to any worker with room, GPUs first.
            bool gave = true;
            while (gave && next < ntiles)
                {
                gave = false;
                for (u32 i = (u32)0; i < ws.count() && next < ntiles; i = i + (u32)1)
                    {
                    ParWorker* w = (ParWorker*)ws.get(i);
                    ParTile* pt = (ParTile*)tiles.get((u32)next);
                    if (w.take(pt, proto, src, l))
                        {
                        next = next + (i64)1;
                        inFlight = inFlight + (u32)1;
                        gave = true;
                        }
                    }
                }
            // Collect what finished; fold in tile order.
            bool got = false;
            for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
                {
                ParWorker* w = (ParWorker*)ws.get(i);
                ParTile* d = w.poll();
                while (d != (ParTile*)0)
                    {
                    got = true;
                    inFlight = inFlight - (u32)1;
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
        if (ParDevice.reporting())
            {
            String* names = new String();
            for (u32 i = (u32)0; i < ws.count(); i = i + (u32)1)
                {
                if (i > (u32)0) names.appendCString(", ");
                names.append(((ParWorker*)ws.get(i)).identity());
                }
            Log.info("par: %s: %ld items in %ld tiles across %s (%ld us)", proto.parName(), n, ntiles, names.cString(),
                     ParDevice.nowUs() - started);
            }
        return true;
        }
    }
