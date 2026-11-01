// OptLoopReductionCollapse.xc — the LoopReductionCollapse pass, ported from src/xtc/ir/XTIROptLoopReductionCollapse.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (LoopReductionCollapse)
    {

    // ── loop-reduction-collapse ──────────────────────────────────────────
    //
    // A rep loop wrapped around an invariant reduction
    //     for (rep = 0; rep < T; rep++)
    //         for (i = 0; i < N; i++) acc += g(i);   // g outer-invariant
    // adds the SAME delta Σg(i) on every outer iteration, so the closed form
    // acc_T = init + T·(acc₁ − init) is exact. The transform runs the outer
    // loop exactly ONCE (its header compare's bound drops to one trip) and
    // rescales the live-out accumulator with three ops at the head of the exit
    // block. Nothing is cloned and no block moves — only the bound changes and
    // the post-loop uses are redirected. Exact for `+` over 2's-complement
    // integers: T·Σδ mod 2^w is what T repeated adds produce.
    //
    // The HOIST half runs first. It lifts an invariant inner store loop out of
    // the rep loop (map.xc's `b[i] = f(a[i])`), after which the rep loop is
    // store-free and the collapse fires on the next round — which is why the
    // whole thing iterates to a fixpoint per function.
    final void loopReductionCollapse(IRModule* m)
        {
        if (!_profile.reductionCollapse())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // Each transform invalidates the CFG and def analysis, so the
            // round rebuilds it. Capped as a backstop.
            u32 round = (u32)0;
            while (round < (u32)16 && lrcAnalyze(fn))
                round = round + (u32)1;
            }
        }

    // One round: build the def maps, discover the natural loops, and apply at
    // most ONE transform (the mutation invalidates everything above it).
    final bool lrcAnalyze(IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return false;

        Map* defOf = new Map();  // instruction results
        Map* defPhi = new Map(); // phi results
        Map* defBlk = new Map(); // any def → its block (memory tokens too)
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0)
                    continue;
                defPhi.set((Hashable*)p.res(), (Object*)p);
                defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    {
                    defOf.set((Hashable*)n.res(), (Object*)n);
                    defBlk.set((Hashable*)n.res(), (Object*)bb);
                    }
                if (n.memRes() != (IRValue*)0)
                    defBlk.set((Hashable*)n.memRes(), (Object*)bb);
                }
            }

        Array* loops = self.lrcLoops(fn);
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            if (lrcHoistInner(fn, (LRCLoop*)loops.get(i), loops, defBlk))
                return true;
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            if (lrcCollapseOuter(fn, (LRCLoop*)loops.get(i), loops,
                                 defOf, defPhi, defBlk))
                return true;
        return false;
        }

    final bool lrcSubset(Array* a, Array* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (!self.hasBlock(b, (IRBlock*)a.get(i)))
                return false;
        return true;
        }

    // A const reached through ZExt / SExt / Trunc / Bitcast. A bound wider than
    // 16 bits arrives via Bitcast (U32→I32) rather than ZExt, so that step is
    // followed too — which is why this is not `resolveInt`.
  // i64: IROperand.imm() is already 64-bit, and the reference holds every
  // one of these in an int64_t. Narrowing here made a u32 loop bound above
  // 2^31 come back NEGATIVE, and every guard that tests it silently gave
  // up. private:docs/bugs/243.
    final bool lrcConst(Map* defOf, IROperand* op, i64* out)
        {
        if (op == (IROperand*)0)
            return false;
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!lrcIsCast(def.op()))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    final bool lrcIsCast(String* op)
        {
        return op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast"));
        }

    // Exact iteration count of an ascending counted loop, in closed form. No
    // simulation and no cap — the whole point is folding a BIG rep loop, and
    // T·Σδ mod 2^w is exact for any T. Zero when it is not a terminating
    // ascending counted loop.
    final u32 lrcTrip(i64 startv, i64 step, i64 bound, String* pred)
        {
        if (step <= (i32)0)
            return (u32)0;
        if (pred.equals(String.withCString("SLT")))
            {
            if (bound <= startv)
                return (u32)0;
            return (u32)((bound - startv + step - (i32)1) / step);
            }
        if (pred.equals(String.withCString("SLE")))
            {
            if (bound < startv)
                return (u32)0;
            return (u32)((bound - startv) / step + (i32)1);
            }
        if (pred.equals(String.withCString("ULT")))
            {
            u32 ui = (u32)startv;
            u32 ub = (u32)bound;
            u32 us = (u32)step;
            if (ub <= ui)
                return (u32)0;
            return (ub - ui + us - (u32)1) / us;
            }
        if (pred.equals(String.withCString("ULE")))
            {
            u32 ui = (u32)startv;
            u32 ub = (u32)bound;
            u32 us = (u32)step;
            if (ub < ui)
                return (u32)0;
            return (ub - ui) / us + (u32)1;
            }
        return (u32)0;
        }

    // Does the def cone of `start`, restricted to `region`, reach anything in
    // `taboo`? Proves the inner reduction's per-step delta depends on neither
    // the outer accumulator nor the outer induction variable.
    final bool lrcConeReaches(IRValue* start, Array* taboo, Array* region,
                        Map* defOf, Map* defPhi, Map* defBlk)
        {
        Map* seen = new Map();
        Array* wl = new Array();
        wl.add((Object*)start);
        while (wl.count() > (u32)0)
            {
            IRValue* v = (IRValue*)wl.get(wl.count() - (u32)1);
            wl.removeLast();
            if (seen.get((Hashable*)v) != (Object*)0)
                continue;
            seen.set((Hashable*)v, (Object*)v);
            for (u32 t = (u32)0; t < taboo.count(); t = t + (u32)1)
                if ((IRValue*)taboo.get(t) == v)
                    return true;
            Object* dbo = defBlk.get((Hashable*)v);
            // Defined outside the region ⇒ an invariant leaf.
            if (dbo == (Object*)0 || !self.hasBlock(region, (IRBlock*)dbo))
                continue;
            Object* d = defOf.get((Hashable*)v);
            if (d == (Object*)0)
                d = defPhi.get((Hashable*)v);
            if (d == (Object*)0)
                continue;
            IRInsn* def = (IRInsn*)d;
            for (u32 i = (u32)0; i < def.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)def.ops().get(i);
                if (o.kind() == (u8)OPK_USE)
                    wl.add((Object*)o.val());
                }
            }
        return false;
        }

    // The base an address ultimately roots at — an `AddrOf @sym` reached
    // through any number of ElementAddr / Bitcast steps. Spelled as a string so
    // a global symbol and a stack slot cannot collide: "S:<name>" for a symbol,
    // "L:<n>" for a frame slot (a pinned local, stable across the loop and
    // distinct per local, so map.xc's a[] and b[] are provably disjoint). Null
    // when the base cannot be determined — a loaded pointer, IntToPtr, a phi.
    final String* lrcAddrBase(IROperand* addr, Map* defOf, Array* locals)
        {
        IROperand* a = addr;
        for (u32 guard = (u32)0; guard < (u32)64; guard = guard + (u32)1)
            {
            if (a == (IROperand*)0 || a.kind() != (u8)OPK_USE)
                return (String*)0;
            Object* o = defOf.get((Hashable*)a.val());
            if (o == (Object*)0)
                return (String*)0;
            IRInsn* d = (IRInsn*)o;
            if (d.ops().count() < (u32)1)
                return (String*)0;
            IROperand* b = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("AddrOf")))
                {
                if (b.kind() == (u8)OPK_SYM)
                    {
                    String* s = String.withCString("S:");
                    s.append(b.name());
                    return s;
                    }
                if (b.kind() != (u8)OPK_USE)
                    return (String*)0;
                u32 idx = locals.count();
                for (u32 i = (u32)0; i < locals.count(); i = i + (u32)1)
                    if ((IRValue*)locals.get(i) == b.val())
                        {
                        idx = i;
                        break;
                        }
                if (idx == locals.count())
                    locals.add((Object*)b.val());
                String* s = new String();
                s.appendFormat("L:%lu", idx);
                return s;
                }
            if (d.op().equals(String.withCString("ElementAddr")) || d.op().equals(String.withCString("Bitcast")))
                {
                a = b;
                continue;
                }
            return (String*)0;
            }
        return (String*)0;
        }

    final bool lrcHasString(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(s))
                return true;
        return false;
        }

    // Rebuild `bb`'s terminator so every block operand naming `oldT` names
    // `newT` instead.
    final void lrcRetarget(IRBlock* bb, IRBlock* oldT, IRBlock* newT)
        {
        IRInsn* t = bb.term();
        if (t == (IRInsn*)0)
            return;
        for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(i);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() != oldT)
                continue;
            t.ops().set(i, (Object*)IROperand.block(newT));
            }
        }

    // Relabel every phi in `bb`: an incoming edge from `oldB` now comes from
    // `newB`, keeping the paired value.
    final void lrcRelabelPhis(IRBlock* bb, IRBlock* oldB, IRBlock* newB)
        {
        for (u32 p = (u32)0; p < bb.phis().count(); p = p + (u32)1)
            {
            IRInsn* phi = (IRInsn*)bb.phis().get(p);
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != oldB)
                    continue;
                phi.ops().set(k, (Object*)IROperand.block(newB));
                }
            }
        }

    // Hoist an invariant inner loop L out of outer loop O, to run once BEFORE
    // it. Requires the map.xc shape: O's header continues to L's preheader P_i
    // (whose sole predecessor is that header), L has a single exit E_i, L and
    // its preheader use no value defined inside O's body, and O's body outside
    // L writes no memory. The relocation is three edge redirects and one phi
    // relabel — P_i and E_i are repurposed rather than moved.
    final bool lrcHoistInner(IRFunc* fn, LRCLoop* O, Array* loops, Map* defBlk)
        {
        if (O.pre() == (IRBlock*)0)
            return false;
        IRBlock* Ho = O.header();
        IRBlock* Po = O.pre();

        // O's continue-target: the one header successor inside the body.
        IRBlock* cont = (IRBlock*)0;
        Array* hs = self.lrcSuccs(fn, Ho);
        for (u32 i = (u32)0; i < hs.count(); i = i + (u32)1)
            {
            IRBlock* s = (IRBlock*)hs.get(i);
            if (!self.hasBlock(O.body(), s))
                continue;
            if (cont == (IRBlock*)0)
                cont = s;
            else
                return false;
            }
        if (cont == (IRBlock*)0)
            return false;

        for (u32 li = (u32)0; li < loops.count(); li = li + (u32)1)
            {
            LRCLoop* L = (LRCLoop*)loops.get(li);
            if (L.pre() == (IRBlock*)0 || L.header() == Ho)
                continue;
            if (!lrcSubset(L.body(), O.body()) || L.body().count() >= O.body().count())
                continue;
            if (L.pre() != cont)
                continue; // P_i must be O's continue-target
            Array* pp = self.lrcPreds(fn, L.pre());
            if (pp.count() != (u32)1 || (IRBlock*)pp.get((u32)0) != Ho)
                continue;

            IRBlock* Pi = L.pre();
            IRBlock* Hi = L.header();

            // L's single exit: the header successor outside L's body.
            IRBlock* Ei = (IRBlock*)0;
            bool multiExit = false;
            Array* ls = self.lrcSuccs(fn, Hi);
            for (u32 i = (u32)0; i < ls.count(); i = i + (u32)1)
                {
                IRBlock* s = (IRBlock*)ls.get(i);
                if (hasBlock(L.body(), s))
                    continue;
                if (Ei == (IRBlock*)0)
                    Ei = s;
                else
                    {
                    multiExit = true;
                    break;
                    }
                }
            if (Ei == (IRBlock*)0 || multiExit)
                return false;

            // The region that moves out is L's body plus its preheader. It must
            // use no value defined inside O's body but outside the region — so
            // it cannot depend on O's carried accumulator or IV.
            Array* region = new Array();
            for (u32 i = (u32)0; i < L.body().count(); i = i + (u32)1)
                region.add(L.body().get(i));
            region.add((Object*)Pi);
            if (lrcRegionEscapes(region, O.body(), defBlk))
                return false;

            // Every store in the outer loop must sit inside L's body, so that L
            // is O's only writer and O is store-free once L leaves. Scanning
            // O.body \ L.body also covers P_i, which moves out with L but must
            // carry no store of its own.
            for (u32 i = (u32)0; i < O.body().count(); i = i + (u32)1)
                {
                IRBlock* bb = (IRBlock*)O.body().get(i);
                if (hasBlock(L.body(), bb))
                    continue;
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    if (lrcWritesMemory(((IRInsn*)bb.insns().get(k)).op()))
                        return false;
                }

            if (!lrcIdempotent(fn, L))
                return false;

            // ── Surgery ─────────────────────────────────────────────────
            // A dedicated exit block routes L → O's header, so the L-header →
            // O-header edge is not critical (L's header has two successors and
            // O's header two predecessors — a direct edge would misplace O's
            // phi-resolution copies and corrupt the accumulator seed).
            String* nm = Hi.name() == (String*)0
                             ? String.withCString("loop")
                             : Hi.name();
            String* exitName = new String();
            exitName.appendFormat("%s_hoisted_exit", nm.cString());
            IRBlock* L1exit = new IRBlock(exitName);
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(Ho));
            L1exit.setTerm(br);

            // Insert just after L's last body block so the array position
            // matches the control-flow position: the register allocators derive
            // live-interval positions from block order, and a block appended at
            // the end but executed mid-CFG scrambles liveness.
            u32 insertAt = (u32)0;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                if (hasBlock(L.body(), (IRBlock*)fn.blocks().get(b)) && b + (u32)1 > insertAt)
                    insertAt = b + (u32)1;
            fn.blocks().insert(insertAt, (Object*)L1exit);

            lrcRetarget(Po, Ho, Pi);        // (a) preheader now enters L first
            lrcRetarget(Hi, Ei, L1exit);    // (b) L's exit → dedicated block → O header
            lrcRetarget(Ho, Pi, Ei);        // (c) O's body now starts at E_i (the rest)
            lrcRelabelPhis(Ho, Po, L1exit); // (d) O header phis: preheader edge → new block
            return true;
            }
        return false;
        }

    // True when any instruction in `region` uses a value defined inside
    // `outer` but outside the region.
    final bool lrcRegionEscapes(Array* region, Array* outer, Map* defBlk)
        {
        for (u32 i = (u32)0; i < region.count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)region.get(i);
            Array* all = new Array();
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                all.add(bb.phis().get(k));
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                all.add(bb.insns().get(k));
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(k);
                for (u32 o = (u32)0; o < n.ops().count(); o = o + (u32)1)
                    {
                    IROperand* op = (IROperand*)n.ops().get(o);
                    if (op.kind() != (u8)OPK_USE)
                        continue;
                    Object* db = defBlk.get((Hashable*)op.val());
                    if (db == (Object*)0)
                        continue;
                    if (hasBlock(outer, (IRBlock*)db) && !self.hasBlock(region, (IRBlock*)db))
                        return true;
                    }
                }
            }
        return false;
        }

    // The hoist runs L exactly ONCE in place of O's T iterations, so it only
    // preserves the final memory state if re-executing L would recompute the
    // same values — L must be a MAP, not a read-modify-write ACCUMULATE. A
    // store loop with no loads is idempotent outright. Once it also loads, what
    // it LOADS must be disjoint from what it STORES, else a stored value
    // depends on memory L itself wrote on an earlier pass (`m[i] = m[i] + 5`
    // run once gives 5 where T passes give 5·T). Any opaque base, or any other
    // memory-effecting op, refuses.
    final bool lrcIdempotent(IRFunc* fn, LRCLoop* L)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        Array* locals = new Array();
        Array* storeSyms = new Array();
        Array* loadSyms = new Array();
        bool anyLoad = false;
        bool baseOpaque = false;
        for (u32 i = (u32)0; i < L.body().count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)L.body().get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(k);
                bool isLoad = n.op().equals(String.withCString("Load")) || n.op().equals(String.withCString("LoadVolatile")) || n.op().equals(String.withCString("VLoad"));
                bool isStore = n.op().equals(String.withCString("Store")) || n.op().equals(String.withCString("StoreVolatile")) || n.op().equals(String.withCString("VStore"));
                if (!isLoad && !isStore)
                    {
                    if (lrcWritesMemory(n.op()))
                        return false; // side effect
                    continue;
                    }
                String* s = n.ops().count() >= (u32)1
                                ? lrcAddrBase((IROperand*)n.ops().get((u32)0), defOf, locals)
                                : (String*)0;
                if (isLoad)
                    anyLoad = true;
                if (s == (String*)0)
                    {
                    baseOpaque = true;
                    continue;
                    }
                if (isLoad)
                    {
                    if (!lrcHasString(loadSyms, s))
                        loadSyms.add((Object*)s);
                    }
                else
                    {
                    if (!lrcHasString(storeSyms, s))
                        storeSyms.add((Object*)s);
                    }
                }
            }
        if (!anyLoad)
            return true;
        if (baseOpaque)
            return false; // cannot prove load/store disjoint
        for (u32 i = (u32)0; i < storeSyms.count(); i = i + (u32)1)
            if (lrcHasString(loadSyms, (String*)storeSyms.get(i)))
                return false; // an array is both read and written
        return true;
        }

    // The collapse proper. O must be a counted outer loop with a const trip, a
    // single integer accumulator carried through an inner reduction whose delta
    // is O-invariant, no memory writes in its body, and no value other than the
    // accumulator leaking out of it.
    final bool lrcCollapseOuter(IRFunc* fn, LRCLoop* O, Array* loops,
                          Map* defOf, Map* defPhi, Map* defBlk)
        {
        if (O.pre() == (IRBlock*)0)
            return false;

        // The outer body must write no memory. (A store there needs the
        // invariant inner-loop hoist first — the other half of this pass.)
        for (u32 i = (u32)0; i < O.body().count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)O.body().get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                {
                String* op = ((IRInsn*)bb.insns().get(k)).op();
                if (lrcWritesMemory(op) || op.equals(String.withCString("LoadVolatile")))
                    return false;
                }
            }

        if (!lrcClassifyHeader(O, defOf))
            return false;
        if (!lrcInnerReduction(O, loops, defOf, defPhi, defBlk))
            return false;

        // Single exit, and the iteration count must leak ONLY through the
        // accumulator: any other value defined inside the body and used outside
        // it (the outer IV read after the loop, say) would be miscompiled by
        // running the body once. Memory tokens are exempt — advisory in a loose
        // model.
        IRBlock* exitBB = (IRBlock*)0;
        for (u32 i = (u32)0; i < O.body().count(); i = i + (u32)1)
            {
            Array* ss = self.lrcSuccs(fn, (IRBlock*)O.body().get(i));
            for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                {
                IRBlock* s = (IRBlock*)ss.get(k);
                if (hasBlock(O.body(), s))
                    continue;
                if (exitBB == (IRBlock*)0)
                    exitBB = s;
                else if (exitBB != s)
                    return false; // multiple exits
                }
            }
        if (exitBB == (IRBlock*)0)
            return false;
        u32 accUses = lrcCountLiveOut(fn, O.body(), _lrcAcc.res(), defBlk);
        if (accUses == (u32)0)
            return false; // accumulator dead afterwards
        if (accUses == LRC_LEAK)
            return false; // something else leaks

        lrcApply(fn, O, exitBB);
        return true;
        }

    // Classify the outer header's phis: exactly one induction variable
    // (counted, const trip) plus exactly one integer accumulator. Anything else
    // refuses. Results land in the _lrc* ivars.
    final bool lrcClassifyHeader(LRCLoop* O, Map* defOf)
        {
        IRBlock* H = O.header();
        _lrcIv = (IRInsn*)0;
        _lrcAcc = (IRInsn*)0;
        _lrcCmp = (IRInsn*)0;
        _lrcTrip = (u32)0;
        _lrcInit = (i32)0;
        _lrcStep = (i32)0;
        _lrcAccNext = (IRValue*)0;
        _lrcAccSeed = (IRValue*)0;

        for (u32 p = (u32)0; p < H.phis().count(); p = p + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(p);
            if (phi.res() == (IRValue*)0)
                return false;
            IRValue* seed = lrcIncoming(phi, O.pre());
            IRValue* next = lrcIncoming(phi, O.latch());
            if (seed == (IRValue*)0 || next == (IRValue*)0)
                return false;

            if (_lrcIv == (IRInsn*)0 && lrcTryInductionVar(O, phi, next, defOf))
                continue;
            // Otherwise it must be the single accumulator.
            if (_lrcAcc != (IRInsn*)0)
                return false; // a second carried value
            _lrcAcc = phi;
            _lrcAccNext = next;
            _lrcAccSeed = seed;
            }
        return _lrcIv != (IRInsn*)0 && _lrcAcc != (IRInsn*)0 && _lrcCmp != (IRInsn*)0 && _lrcTrip >= (u32)2;
        }

    // Is `phi` the induction variable? next = Add(phi, constStep), and the
    // header compares it to a const bound with an ascending predicate.
    final bool lrcTryInductionVar(LRCLoop* O, IRInsn* phi, IRValue* next, Map* defOf)
        {
        Object* nd = defOf.get((Hashable*)next);
        if (nd == (Object*)0)
            return false;
        IRInsn* nextDef = (IRInsn*)nd;
        if (!nextDef.op().equals(String.withCString("Add")) || nextDef.ops().count() != (u32)2)
            return false;

        i64 step = (i64)0;
        IROperand* a = (IROperand*)nextDef.ops().get((u32)0);
        IROperand* b = (IROperand*)nextDef.ops().get((u32)1);
        bool isIV = false;
        if (a.kind() == (u8)OPK_USE && a.val() == phi.res() && lrcConst(defOf, b, &step))
            isIV = true;
        else if (b.kind() == (u8)OPK_USE && b.val() == phi.res() && lrcConst(defOf, a, &step))
            isIV = true;
        if (!isIV)
            return false;

        IRBlock* H = O.header();
        for (u32 k = (u32)0; k < H.insns().count(); k = k + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(k);
            if (!n.op().equals(String.withCString("ICmp")) || n.ops().count() < (u32)2 || n.pred() == (String*)0)
                continue;
            IROperand* lhs = (IROperand*)n.ops().get((u32)0);
            if (lhs.kind() != (u8)OPK_USE || lhs.val() != phi.res())
                continue;
            i64 start = (i64)0;
            i64 bound = (i64)0;
            if (!lrcConst(defOf, lrcSeedOperand(phi, O.pre()), &start))
                continue;
            if (!lrcConst(defOf, (IROperand*)n.ops().get((u32)1), &bound))
                continue;
            u32 t = lrcTrip(start, step, bound, n.pred());
            if (t == (u32)0)
                continue;
            _lrcTrip = t;
            _lrcInit = start;
            _lrcStep = step;
            _lrcCmp = n;
            }
        if (_lrcTrip == (u32)0)
            return false;
        _lrcIv = phi;
        return true;
        }

    // The accumulator's latch-incoming must be an INNER reduction loop's
    // accumulator phi, seeded by the outer accumulator and accumulating a
    // per-step delta that depends on neither the outer accumulator nor the
    // outer IV — so Σδ is the same on every outer iteration.
    final bool lrcInnerReduction(LRCLoop* O, Array* loops,
                           Map* defOf, Map* defPhi, Map* defBlk)
        {
        Object* iao = defPhi.get((Hashable*)_lrcAccNext);
        Object* ihb = defBlk.get((Hashable*)_lrcAccNext);
        if (iao == (Object*)0 || ihb == (Object*)0)
            return false;
        IRInsn* innerAcc = (IRInsn*)iao;

        LRCLoop* L = (LRCLoop*)0;
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            {
            LRCLoop* cand = (LRCLoop*)loops.get(i);
            if (cand.header() != (IRBlock*)ihb)
                continue;
            if (!lrcSubset(cand.body(), O.body()) || cand.body().count() >= O.body().count())
                continue;
            L = cand;
            break;
            }
        if (L == (LRCLoop*)0 || L.pre() == (IRBlock*)0)
            return false;

        IRValue* innerSeed = lrcIncoming(innerAcc, L.pre());
        IRValue* innerNext = lrcIncoming(innerAcc, L.latch());
        if (innerSeed == (IRValue*)0 || innerNext == (IRValue*)0)
            return false;
        if (innerSeed != _lrcAcc.res())
            return false; // must chain the outer acc

        Object* ind = defOf.get((Hashable*)innerNext);
        if (ind == (Object*)0)
            return false;
        IRInsn* innerNextDef = (IRInsn*)ind;
        if (!innerNextDef.op().equals(String.withCString("Add")) || innerNextDef.ops().count() != (u32)2)
            return false;
        IROperand* ia = (IROperand*)innerNextDef.ops().get((u32)0);
        IROperand* ib = (IROperand*)innerNextDef.ops().get((u32)1);
        IRValue* delta = (IRValue*)0;
        if (ia.kind() == (u8)OPK_USE && ia.val() == innerAcc.res() && ib.kind() == (u8)OPK_USE)
            delta = ib.val();
        else if (ib.kind() == (u8)OPK_USE && ib.val() == innerAcc.res() && ia.kind() == (u8)OPK_USE)
            delta = ia.val();
        else
            return false;

        Array* taboo = new Array();
        taboo.add((Object*)_lrcAcc.res());
        taboo.add((Object*)_lrcIv.res());
        taboo.add((Object*)innerAcc.res());
        return !lrcConeReaches(delta, taboo, O.body(), defOf, defPhi, defBlk);
        }

    // Run the outer loop exactly ONCE (acc₁ = init + Σδ), then rescale its
    // live-out to init + T·(acc₁ − init) = init + T·Σδ.
    final void lrcApply(IRFunc* fn, LRCLoop* O, IRBlock* exitBB)
        {
        String* accTy = _lrcAcc.res().ty();

        // 1. Rewrite the outer IV's header compare so the loop runs once.
        i32 onceBound = (_lrcCmp.pred().equals(String.withCString("SLE")) || _lrcCmp.pred().equals(String.withCString("ULE")))
                            ? _lrcInit
                            : _lrcInit + _lrcStep;
        IROperand* oldBound = (IROperand*)_lrcCmp.ops().get((u32)1);
        String* boundTy = accTy;
        if (oldBound.kind() == (u8)OPK_USE && oldBound.val() != (IRValue*)0 && oldBound.val().ty() != (String*)0)
            boundTy = oldBound.val().ty();
        _lrcCmp.ops().set((u32)1, (Object*)IROperand.immI(onceBound, boundTy));

        // 2. closed = init + T·(acc − init), three ops at the head of the exit.
        IROperand* initOp = IROperand.useVal(_lrcAccSeed);
        IRInsn* subI = IRInsn.with(String.withCString("Sub"));
        subI.setRes(new IRValue(accTy));
        subI.add(IROperand.useVal(_lrcAcc.res()));
        subI.add(initOp);
        IRInsn* mulI = IRInsn.with(String.withCString("Mul"));
        mulI.setRes(new IRValue(accTy));
        mulI.add(IROperand.useVal(subI.res()));
        mulI.add(IROperand.immI((i32)_lrcTrip, accTy));
        IRInsn* addI = IRInsn.with(String.withCString("Add"));
        addI.setRes(new IRValue(accTy));
        addI.add(initOp);
        addI.add(IROperand.useVal(mulI.res()));

        // 3. Redirect the post-loop accumulator uses to the closed form. This
        //    runs BEFORE the three ops are inserted — the original collects the
        //    use sites first, so the new Sub keeps reading the raw accumulator.
        lrcRewriteLiveOut(fn, O.body(), _lrcAcc.res(), IROperand.useVal(addI.res()));
        exitBB.insns().insert((u32)0, (Object*)subI);
        exitBB.insns().insert((u32)1, (Object*)mulI);
        exitBB.insns().insert((u32)2, (Object*)addI);
        }

    // The value paired with the `from` edge in a phi, or null.
    final IRValue* lrcIncoming(IRInsn* phi, IRBlock* from)
        {
        IROperand* o = lrcSeedOperand(phi, from);
        return o == (IROperand*)0 ? (IRValue*)0 : o.val();
        }

    final IROperand* lrcSeedOperand(IRInsn* phi, IRBlock* from)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IROperand* bo = (IROperand*)phi.ops().get(k);
            IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
            if (bo.kind() != (u8)OPK_BLOCK || vo.kind() != (u8)OPK_USE)
                continue;
            if (bo.blk() == from)
                return vo;
            }
        return (IROperand*)0;
        }

    // How many uses OUTSIDE `body` read a value defined inside it. LRC_LEAK
    // when one of them is not `acc` — the caller refuses, because running the
    // body once would then be observable.
    final u32 lrcCountLiveOut(IRFunc* fn, Array* body, IRValue* acc, Map* defBlk)
        {
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(body, bb))
                continue;
            Array* all = new Array();
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                all.add(bb.phis().get(k));
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                all.add(bb.insns().get(k));
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                IRInsn* insn = (IRInsn*)all.get(k);
                for (u32 o = (u32)0; o < insn.ops().count(); o = o + (u32)1)
                    {
                    IROperand* op = (IROperand*)insn.ops().get(o);
                    if (op.kind() != (u8)OPK_USE)
                        continue;
                    Object* db = defBlk.get((Hashable*)op.val());
                    if (db == (Object*)0 || !self.hasBlock(body, (IRBlock*)db))
                        continue;
                    if (op.val().ty() != (String*)0 && op.val().ty().equals(String.withCString("Mem")))
                        continue;
                    if (op.val() != acc)
                        return LRC_LEAK;
                    n = n + (u32)1;
                    }
                }
            }
        return n;
        }

    final void lrcRewriteLiveOut(IRFunc* fn, Array* body, IRValue* acc, IROperand* to)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(body, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.replaceUse((IRInsn*)bb.phis().get(k), acc, to);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.replaceUse((IRInsn*)bb.insns().get(k), acc, to);
            if (bb.term() != (IRInsn*)0)
                self.replaceUse(bb.term(), acc, to);
            }
        }
    }
