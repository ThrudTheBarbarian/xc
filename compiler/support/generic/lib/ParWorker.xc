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

class ParTile : Object
    {
    i64 index;          // its place in the run: the fold order
    i64 lo;
    i64 hi;
    ParChunk* partial;  // the tile's reductions, a chunk copy, once finished
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
    // Tiles the worker keeps in flight at once.
    u32 depth(void)
        {
        return (u32)1;
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

// The CPU pool as a worker: a lane per core, each tile on one lane, so the
// CPU holds as many tiles as it has cores and the queue's rate for it is the
// cores' together. Its lanes outlive the run.
class ParCpuWorker : ParWorker
    {
    Array* _lanes;
    u32 _busy;

    String* identity(void)
        {
        return String.withCString("cpu");
        }
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        return true;
        }
    u32 depth(void)
        {
        return (u32)Par.threads();
        }
    i64 floor(void)
        {
        return (i64)1024;
        }
    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        if (_lanes == (Array*)0)
            {
            _lanes = new Array();
            i32 n = Par.threads();
            for (i32 i = (i32)0; i < n; i = i + (i32)1)
                {
                ParCpuLane* lane = new ParCpuLane();
                lane.start();
                _lanes.add((Object*)lane);
                }
            }
        return true;
        }
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_lanes == (Array*)0 || _busy >= _lanes.count())
            return false;
        for (u32 i = (u32)0; i < _lanes.count(); i = i + (u32)1)
            {
            ParCpuLane* lane = (ParCpuLane*)_lanes.get(i);
            if (lane._busy)
                continue;
            lane._chunk = proto.copyChunk();
            lane._lo = t.lo;
            lane._hi = t.hi;
            lane._tile = t;
            lane._busy = true;
            lane._done.store((i32)0);
            t.worker = (ParWorker*)self;
            _busy = _busy + (u32)1;
            lane._go.post();
            return true;
            }
        return false;
        }
    // Asked, not waited for: the queue polls every worker in turn, and a
    // wait here would hold the GPUs' feeding until a CPU tile ended.
    ParTile* poll(void)
        {
        if (_busy == (u32)0)
            return (ParTile*)0;
        for (u32 i = (u32)0; i < _lanes.count(); i = i + (u32)1)
            {
            ParCpuLane* lane = (ParCpuLane*)_lanes.get(i);
            if (!lane._busy || lane._done.load() == (i32)0)
                continue;
            ParTile* t = lane._tile;
            t.partial = lane._chunk;
            t.done = true;
            lane._chunk = (ParChunk*)0;
            lane._tile = (ParTile*)0;
            lane._busy = false;
            _busy = _busy - (u32)1;
            return t;
            }
        return (ParTile*)0;
        }
    void drain(void)
        {
        while (_busy > (u32)0)
            if (poll() == (ParTile*)0)
                Thread.yield();
        }
    }
#endif
