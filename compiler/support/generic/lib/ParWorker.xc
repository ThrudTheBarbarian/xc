// ParWorker.xc — a device that runs tiles of a `par` block: the interface the
// GPU runtimes and the CPU pool implement, and the tile record they share
// (par-tiles-and-devices.md step 3). A run of a block over [lo, hi) is cut
// into tiles (ParTiles.xc); each worker takes tiles while it has room, runs
// them its own way, and hands each back finished with its partials in a
// chunk copy, which the queue folds into the block in tile order whatever
// order the workers finish in.
#import "Par.xc"
#import "Sem.xc"
#import "Atomic.xc"
#import "Mutex.xc"

class ParTile : Object
    {
    i64 index;          // its place in the run: the fold order
    i64 lo;
    i64 hi;
    ParChunk* partial;  // the tile's reductions, a chunk copy, once finished
    Data* raw;          // or the partials as bytes, for a chunk that asks (rawPartials)
    bool done;
    ParWorker* worker;  // who took it
    }

class ParWorker : Object
    {
    // For auto's hardware key: "cuda:<name>", "vulkan:<name>:…", "cpu".
    String* identity(void)
        {
        return String.withCString("");
        }
    // Whether this worker can run the block at all: its kernel form is
    // printed, compiles here, and the device has the features and memory the
    // block's resident set needs. Memoised by the worker per block.
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        return false;
        }
    // A faster-API worker for the SAME physical device (a card reached by both
    // CUDA and Vulkan has one CUDA worker set here on the Vulkan one), or null.
    // The queue runs a device through one back end at a time and prefers the
    // faster one, so this worker stands aside for a block its peer can take.
    ParWorker* _preferredPeer;
    // Whether the queue should use this worker for THIS block: it can run the
    // block, and no preferred peer for the same device can (else the peer runs
    // the card). Per block — kernel availability does not change within a run.
    // So a block with no PTX, which a CUDA worker cannot take, still runs on
    // that card through its Vulkan worker instead of leaving it idle.
    bool forBlock(ParChunk* proto, u8* src, ParLayout* l)
        {
        if (!holds(proto, src, l))
            return false;
        if (_preferredPeer != (ParWorker*)0 && _preferredPeer.holds(proto, src, l))
            return false;
        return true;
        }
    // The peer this worker stands aside for on a block, or null: the report
    // says which it was, rather than that the block was declined.
    ParWorker* standsAsideFor(ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_preferredPeer != (ParWorker*)0 && _preferredPeer.holds(proto, src, l) && holds(proto, src, l))
            return _preferredPeer;
        return (ParWorker*)0;
        }
    // Whether the worker can take a tile RIGHT NOW: reachable, and not so
    // loaded that giving it work would lose time. A local device is always
    // ready; a remote one answers from a cached load/health probe. Re-asked
    // every dispatch round, so a worker drops out and rejoins as its load
    // moves (par-tiles-and-devices.md, dynamic worker eligibility) — the
    // networked case where a machine's load jumps then falls on a long job.
    bool ready(i64 now)
        {
        return true;
        }
    // Tiles the worker keeps in flight at once.
    u32 depth(void)
        {
        return (u32)1;
        }
    // The section of a block's kernel source this worker runs (its own
    // form: MSL, PTX, SPIR-V), or null when the source has none; the queue's
    // layout is read from the source's first section, and a worker lays the
    // block out again from its own, whose header may differ in what the
    // kernel form needs (by-value arguments, device-side reduction).
    u8* section(u8* src)
        {
        return src;
        }
    // The tile size this worker would choose for the block, in work items,
    // or 0 for no preference (the queue takes the smallest preference).
    i64 tileItems(ParLayout* l)
        {
        return (i64)0;
        }
    // Before a run: what the worker needs for tiles of `tile` items (device
    // slices, the block's whole buffers). False drops the worker from the run.
    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        return true;
        }
    // After a run: release what prepare made.
    void finish(void)
        {
        }
    // The smallest tile that still fills the worker, in work items.
    i64 floor(void)
        {
        return (i64)1;
        }
    // Start a tile: its copies and launch, or its thread. False when the
    // worker cannot take it after all (the queue gives it to another).
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        return false;
        }
    // The oldest tile this worker has finished, marked done with its
    // partials set, or 0 when none is finished yet.
    ParTile* poll(void)
        {
        return (ParTile*)0;
        }
    // Wait for every tile in flight (poll until empty).
    void drain(void)
        {
        }
    // Tiles this worker took and will never finish (its connection died),
    // handed back once for the queue to give to another worker; null when
    // none. A local worker loses none.
    Array* lost(void)
        {
        return (Array*)0;
        }
    // Whether the worker is gone for good (a remote whose connection died):
    // the queue stops waiting on it.
    bool dead(void)
        {
        return false;
        }
    }

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
// The CPU pool as a worker: a tile runs through Par.runCpu on a chunk copy,
// on a thread of its own, one tile in flight. It never refuses a block,
// which is what makes it the worker of last resort, and the second worker
// that proves the queue is not shaped like one GPU runtime.
// One of the CPU worker's threads: made once, it waits for a tile, runs the
// chunk over the tile's range on its own, and flags it done. The pool is not
// used: its fan-out and join per tile cost more than a small tile's work.
class ParCpuLane : Object
    {
    Thread* _thread;
    Sem* _go;
    Atomic* _done;      // 1 once the tile's chunk has run
    bool _busy;         // the queue's side: a tile is in the lane
    bool _quit;
    ParChunk* _chunk;
    i64 _lo;
    i64 _hi;
    ParTile* _tile;

    void start(void)
        {
        _go = Sem.withCount((i32)0);
        _done = Atomic.withValue((i32)0);
        _thread = Thread.spawn(&self.loop);
        }
    void loop(void)
        {
        while (true)
            {
            _go.wait();
            if (_quit)
                return;
            _chunk.lo = _lo;
            _chunk.hi = _hi;
            _chunk.run();
            _done.store((i32)1);
            }
        }
    }

// The lanes, made once for the process and shared by the CPU worker and the
// direct CPU path (Par.runCpu): a thread spawned per run cost more than a
// small block's work.
Array* gParLanes;
u32 gParLanesBusy;
Mutex* gParLanesLock;   // held by whoever runs on the lanes; a loser spawns

class ParCpuLanes
    {
    static Mutex* lock(void)
        {
        if (gParLanesLock == (Mutex*)0)
            gParLanesLock = new Mutex();
        return gParLanesLock;
        }
    static Array* lanes(void)
        {
        if (gParLanes == (Array*)0)
            {
            gParLanes = new Array();
            i32 n = Par.threads();
            for (i32 i = (i32)0; i < n; i = i + (i32)1)
                {
                ParCpuLane* lane = new ParCpuLane();
                lane.start();
                gParLanes.add((Object*)lane);
                }
            }
        return gParLanes;
        }

    // The direct path: [lo, hi) split across the lanes, the calling thread
    // taking the first chunk on `proto` itself, the lanes' chunks merged in
    // order. False when the lanes are taken (a block inside a tile, or a
    // run on the queue): the caller spawns as before.
    static bool run(ParChunk* proto, i64 lo, i64 hi, i32 k)
        {
        if (gParLanesBusy > (u32)0 || !ParCpuLanes.lock().tryLock())
            return false;
        Array* ls = ParCpuLanes.lanes();
        if ((u32)k > ls.count() + (u32)1)
            k = (i32)(ls.count() + (u32)1);
        if (k <= (i32)1)
            {
            ParCpuLanes.lock().unlock();
            return false;
            }
        i64 n = hi - lo;
        gParLanesBusy = (u32)(k - (i32)1);
        Array* chunks = new Array();
        for (i32 j = (i32)1; j < k; j = j + (i32)1)
            {
            ParCpuLane* lane = (ParCpuLane*)ls.get((u32)(j - (i32)1));
            ParChunk* c = proto.copyChunk();
            lane._chunk = c;
            lane._lo = lo + (n * (i64)j) / (i64)k;
            lane._hi = lo + (n * (i64)(j + (i32)1)) / (i64)k;
            lane._busy = true;
            lane._done.store((i32)0);
            chunks.add((Object*)c);
            lane._go.post();
            }
        proto.lo = lo;
        proto.hi = lo + n / (i64)k;
        proto.run();
        for (i32 j = (i32)1; j < k; j = j + (i32)1)
            {
            ParCpuLane* lane = (ParCpuLane*)ls.get((u32)(j - (i32)1));
            while (lane._done.load() == (i32)0)
                Thread.yield();
            lane._busy = false;
            lane._chunk = (ParChunk*)0;
            }
        gParLanesBusy = (u32)0;
        ParCpuLanes.lock().unlock();
        for (u32 j = (u32)0; j < chunks.count(); j = j + (u32)1)
            proto.merge((ParChunk*)chunks.get(j));
        return true;
        }
    }

// The CPU pool as a worker: a lane per core, each tile on one lane, so the
// CPU holds as many tiles as it has cores and the queue's rate for it is the
// cores' together. Its lanes outlive the run.
class ParCpuWorker : ParWorker
    {
    Array* _lanes;
    u32 _busy;          // lanes running a part of the tile in flight
    u32 _parts;         // the parts the tile was cut into (lanes 0..parts-1)
    ParTile* _tile;     // the tile in flight, or null

    String* identity(void)
        {
        return String.withCString("cpu");
        }
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        return true;
        }
    // One tile at a time, spread over every lane: a GPU-sized tile on ONE
    // lane was a run of its own (mandel_deep's 2M items: 10 s on a lane
    // beside the GPUs' 15 ms), and the queue's estimate for the pool — its
    // throughput over all its lanes — said otherwise. Cut across the lanes
    // the way the direct CPU path cuts a whole block (Par.runCpu: k equal
    // parts, partials merged in order, so the fold is the same one), a tile
    // takes what the estimate says.
    u32 depth(void)
        {
        return (u32)1;
        }
    i64 floor(void)
        {
        return (i64)1024;
        }
    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        if (_lanes == (Array*)0)
            _lanes = ParCpuLanes.lanes();
        return true;
        }
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_lanes == (Array*)0 || _tile != (ParTile*)0)
            return false;
        i64 n = t.hi - t.lo;
        if (n <= (i64)0)
            return false;
        u32 k = _lanes.count();
        if ((i64)k > n)
            k = (u32)n;
        for (u32 j = (u32)0; j < k; j = j + (u32)1)
            if (((ParCpuLane*)_lanes.get(j))._busy)
                return false;   // the direct path has a lane: not now
        _tile = t;
        _parts = k;
        t.worker = (ParWorker*)self;
        for (u32 j = (u32)0; j < k; j = j + (u32)1)
            {
            ParCpuLane* lane = (ParCpuLane*)_lanes.get(j);
            lane._chunk = proto.copyChunk();
            lane._lo = t.lo + (n * (i64)j) / (i64)k;
            lane._hi = t.lo + (n * (i64)(j + (u32)1)) / (i64)k;
            lane._tile = t;
            lane._busy = true;
            lane._done.store((i32)0);
            _busy = _busy + (u32)1;
            gParLanesBusy = gParLanesBusy + (u32)1;
            lane._go.post();
            }
        return true;
        }
    // Asked, not waited for: the queue polls every worker in turn, and a
    // wait here would hold the GPUs' feeding until a CPU tile ended. The
    // tile is done when its last part is; the parts' partials are folded
    // into the first in lane order, as the direct path folds its chunks.
    ParTile* poll(void)
        {
        if (_tile == (ParTile*)0)
            return (ParTile*)0;
        for (u32 j = (u32)0; j < _parts; j = j + (u32)1)
            if (((ParCpuLane*)_lanes.get(j))._done.load() == (i32)0)
                return (ParTile*)0;
        ParCpuLane* first = (ParCpuLane*)_lanes.get((u32)0);
        ParChunk* whole = first._chunk;
        for (u32 j = (u32)1; j < _parts; j = j + (u32)1)
            whole.merge(((ParCpuLane*)_lanes.get(j))._chunk);
        ParTile* t = _tile;
        t.partial = whole;
        t.done = true;
        for (u32 j = (u32)0; j < _parts; j = j + (u32)1)
            {
            ParCpuLane* lane = (ParCpuLane*)_lanes.get(j);
            lane._chunk = (ParChunk*)0;
            lane._tile = (ParTile*)0;
            lane._busy = false;
            }
        gParLanesBusy = gParLanesBusy - _busy;
        _busy = (u32)0;
        _parts = (u32)0;
        _tile = (ParTile*)0;
        return t;
        }
    void drain(void)
        {
        while (_tile != (ParTile*)0)
            if (poll() == (ParTile*)0)
                Thread.yield();
        }
    }
#endif
