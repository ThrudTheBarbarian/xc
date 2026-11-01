// OptBlockLayout.xc — the BlockLayout pass, ported from src/xtc/ir/XTIROptBlockLayout.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptMem2Reg>

    class Opt (BlockLayout)
    {


    // ── block-layout ─────────────────────────────────────────────────────
    //
    // Orders a function's blocks so the successor a conditional branch is
    // EXPECTED to take is the one laid out next. That costs no instructions to
    // decide and removes TAKEN branches, which on a tight loop is the whole
    // cost. sort_small's inner loop was three blocks in declaration order with
    // every edge between them a taken branch — three per iteration against
    // clang's one. At roughly one taken branch per cycle that was the entire
    // 3x gap, and the arithmetic in between was free.
    //
    // The back end's fallthrough peephole already drops a `b` to the next
    // block and INVERTS a conditional whose taken target is next, so ordering
    // the blocks is the whole transform.
    final void blockLayout(IRModule* m)
        {
        if (!_profile.layoutHotPath())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            blFunc((IRFunc*)m.funcs().get(f));
        }

    final u32 blIndexOf(Array* orig, IRBlock* b)
        {
        for (u32 i = (u32)0; i < orig.count(); i = i + (u32)1)
            if ((IRBlock*)orig.get(i) == b)
                return i;
        return orig.count();
        }

    final void blFunc(IRFunc* fn)
        {
        u32 n = fn.blocks().count();
        if (n < (u32)3)
            return;

        Array* orig = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            orig.add(fn.blocks().get(i));

        // Predecessors, by index.
        Array* preds = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            preds.add((Object*)new Array());
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            Array* ss = self.m2rSuccs((IRBlock*)orig.get(i));
            for (u32 q = (u32)0; q < ss.count(); q = q + (u32)1)
                {
                u32 si = blIndexOf(orig, (IRBlock*)ss.get(q));
                if (si >= n)
                    continue;
                Array* pl = (Array*)preds.get(si);
                bool have = false;
                for (u32 k = (u32)0; k < pl.count(); k = k + (u32)1)
                    if (((Number*)pl.get(k)).asU32() == i)
                        have = true;
                if (!have)
                    pl.add((Object*)Number.with(i));
                }
            }

        // Loop depth, by natural loops. For a back edge n -> h (h earlier in
        // the original order) the loop is h plus everything reaching n without
        // going through h. Approximating the back edge by position is what the
        // register allocator already does.
        Array* depth = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            depth.add((Object*)Number.with((u32)0));
        for (u32 li = (u32)0; li < n; li = li + (u32)1)
            {
            Array* ss = self.m2rSuccs((IRBlock*)orig.get(li));
            for (u32 q = (u32)0; q < ss.count(); q = q + (u32)1)
                {
                u32 hb = blIndexOf(orig, (IRBlock*)ss.get(q));
                if (hb >= n || hb > li)
                    continue;                  // forward edge, not a loop
                Array* inLoop = new Array();
                for (u32 i = (u32)0; i < n; i = i + (u32)1)
                    inLoop.add((Object*)Number.with((u32)0));
                inLoop.set(hb, (Object*)Number.with((u32)1));
                inLoop.set(li, (Object*)Number.with((u32)1));
                Array* work = new Array();
                work.add((Object*)Number.with(li));
                while (work.count() > (u32)0)
                    {
                    u32 b = ((Number*)work.get(work.count() - (u32)1)).asU32();
                    work.removeAt(work.count() - (u32)1);
                    if (b == hb)
                        continue;
                    Array* pl = (Array*)preds.get(b);
                    for (u32 k = (u32)0; k < pl.count(); k = k + (u32)1)
                        {
                        u32 pi = ((Number*)pl.get(k)).asU32();
                        if (((Number*)inLoop.get(pi)).asU32() != (u32)0)
                            continue;
                        inLoop.set(pi, (Object*)Number.with((u32)1));
                        work.add((Object*)Number.with(pi));
                        }
                    }
                for (u32 i = (u32)0; i < n; i = i + (u32)1)
                    if (((Number*)inLoop.get(i)).asU32() != (u32)0)
                        depth.set(i, (Object*)Number.with(((Number*)depth.get(i)).asU32() + (u32)1));
                }
            }

        // Reverse postorder, visiting the COLD successor first.
        //
        // The order has to stay a reverse postorder, not just any trace: the
        // register allocator's live intervals are LINEAR over this order, so a
        // value's definition must come before its uses or its interval runs
        // backwards and the allocator hands its register to something still
        // live. A first cut used a greedy trace and did exactly that — sieve
        // read a clockid from a register whose `mov #6` was laid out later,
        // and printed a garbage elapsed time while its checksum still matched.
        //
        // In a DFS postorder a node is appended after all its descendants, so
        // reversing puts a node immediately before the subtree of its
        // LAST-visited successor. Visiting the cold successor first leaves the
        // hot one adjacent, and reverse postorder gives definition-before-use
        // for free.
        Array* post = new Array();
        Array* seen = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            seen.add((Object*)Number.with((u32)0));
        Array* stack = new Array();
        Array* pending = new Array();
        seen.set((u32)0, (Object*)Number.with((u32)1));
        stack.add((Object*)Number.with((u32)0));
        pending.add((Object*)blColdFirst(orig, depth, (u32)0, n));
        while (stack.count() > (u32)0)
            {
            u32 b = ((Number*)stack.get(stack.count() - (u32)1)).asU32();
            Array* todo = (Array*)pending.get(pending.count() - (u32)1);
            if (todo.count() == (u32)0)
                {
                post.add(orig.get(b));
                stack.removeAt(stack.count() - (u32)1);
                pending.removeAt(pending.count() - (u32)1);
                continue;
                }
            u32 sIdx = ((Number*)todo.get((u32)0)).asU32();
            todo.removeAt((u32)0);
            if (((Number*)seen.get(sIdx)).asU32() != (u32)0)
                continue;
            seen.set(sIdx, (Object*)Number.with((u32)1));
            stack.add((Object*)Number.with(sIdx));
            pending.add((Object*)blColdFirst(orig, depth, sIdx, n));
            }

        Array* out = new Array();
        u32 i = post.count();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            out.add(post.get(i));
            }
        // A block the entry cannot reach keeps its place at the end rather
        // than being dropped — nothing here is entitled to delete code.
        for (u32 q = (u32)0; q < n; q = q + (u32)1)
            if (((Number*)seen.get(q)).asU32() == (u32)0)
                out.add(orig.get(q));
        if (out.count() != n)
            return;
        while (fn.blocks().count() > (u32)0)
            fn.blocks().removeAt(fn.blocks().count() - (u32)1);
        for (u32 q = (u32)0; q < out.count(); q = q + (u32)1)
            fn.blocks().add(out.get(q));
        }

    // Successors of block `b`, COLDEST first: lower loop depth is colder, and
    // among equals the LATER original block is treated as colder so the
    // earlier one stays adjacent — which keeps the layout close to the
    // original wherever there is nothing to gain, and is reproducible.
    final Array* blColdFirst(Array* orig, Array* depth, u32 b, u32 n)
        {
        Array* ss = new Array();
        Array* raw = self.m2rSuccs((IRBlock*)orig.get(b));
        for (u32 q = (u32)0; q < raw.count(); q = q + (u32)1)
            {
            u32 si = blIndexOf(orig, (IRBlock*)raw.get(q));
            if (si >= n)
                continue;
            bool have = false;
            for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                if (((Number*)ss.get(k)).asU32() == si)
                    have = true;
            if (!have)
                ss.add((Object*)Number.with(si));
            }
        // Insertion sort on the total order (depth asc, then index desc).
        for (u32 a = (u32)1; a < ss.count(); a = a + (u32)1)
            {
            u32 key = ((Number*)ss.get(a)).asU32();
            u32 kd = ((Number*)depth.get(key)).asU32();
            u32 j = a;
            while (j > (u32)0)
                {
                u32 prev = ((Number*)ss.get(j - (u32)1)).asU32();
                u32 pd = ((Number*)depth.get(prev)).asU32();
                bool swap = false;
                if (pd > kd)
                    swap = true;
                else if (pd == kd && prev < key)
                    swap = true;
                if (!swap)
                    j = (u32)0;
                else
                    {
                    ss.set(j, (Object*)Number.with(prev));
                    ss.set(j - (u32)1, (Object*)Number.with(key));
                    j = j - (u32)1;
                    }
                }
            }
        return ss;
        }
    }
