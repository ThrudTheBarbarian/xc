// ParWorker.xc — a device that runs tiles of a `par` block: the interface the
// GPU runtimes and the CPU pool implement, and the tile record they share
// (par-tiles-and-devices.md step 3). A run of a block over [lo, hi) is cut
// into tiles (ParTiles.xc); each worker takes tiles while it has room, runs
// them its own way, and hands each back finished with its partials in a
// chunk copy, which the queue folds into the block in tile order whatever
// order the workers finish in.
#import "Par.xc"

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
class ParCpuWorker : ParWorker
    {
    ParTile* _tile;
    Thread* _thread;
    ParChunk* _chunk;
    i64 _lo;
    i64 _hi;
    bool _finished;     // set by the thread when its tile is done; poll joins only then

    String* identity(void)
        {
        return String.withCString("cpu");
        }
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        return true;
        }
    i64 floor(void)
        {
        return (i64)1024;
        }
    void go(void)
        {
        Par.runCpu(_chunk, _lo, _hi);
        _finished = true;
        }
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_tile != (ParTile*)0)
            return false;
        _chunk = proto.copyChunk();
        _lo = t.lo;
        _hi = t.hi;
        _tile = t;
        _finished = false;
        t.worker = (ParWorker*)self;
        _thread = Thread.spawn(&self.go);
        return true;
        }
    // Asked, not waited for: the queue polls every worker in turn, and a
    // join here would hold the GPUs' feeding until the CPU's tile ended.
    ParTile* poll(void)
        {
        if (_tile == (ParTile*)0 || !_finished)
            return (ParTile*)0;
        _thread.join();
        ParTile* t = _tile;
        t.partial = _chunk;
        t.done = true;
        _tile = (ParTile*)0;
        _thread = (Thread*)0;
        _chunk = (ParChunk*)0;
        return t;
        }
    void drain(void)
        {
        if (_tile == (ParTile*)0)
            return;
        _thread.join();
        _finished = true;
        poll();
        }
    }
#endif
