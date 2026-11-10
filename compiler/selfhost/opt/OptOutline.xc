// OptOutline.xc — IR outlining: a loop par-propose would wrap becomes a function of its own, and a block the par runtime runs (selfhost only: on for a C file under --par-style=auto, which has no parser scan; for xc with XC_PAR_PROPOSE=outline).
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptInline>
#import <OptVectorizeShapes>

    class Opt (Outline)
    {

    final void parProposeOutline(IRModule* m)
        {
        // The functions made here are visited too (the count grows): a loop
        // outlined serially is in one, and so are the loops inside it.
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0 || fn.name().hasPrefix(String.withCString("ParImpl$")))
                continue;
            bool again = true;
            u32 guard = (u32)0;
            // Loops that are not blocks, by header: a loop inside one of them
            // is judged on its own (the work inside a timing loop), as the
            // parser's scan judges it.
            Array* declined = new Array();
            // A serially outlined loop's function: that loop was judged
            // already; the loops inside it were not.
            if (fn.name().hasPrefix(String.withCString("ParOut$")))
                {
                Array* ls = self.lrcLoops(fn);
                for (u32 i = (u32)0; i < ls.count(); i = i + (u32)1)
                    {
                    LRCLoop* L = (LRCLoop*)ls.get(i);
                    bool inner = false;
                    for (u32 j = (u32)0; j < ls.count() && !inner; j = j + (u32)1)
                        {
                        LRCLoop* M = (LRCLoop*)ls.get(j);
                        if (M != L && M.header() != L.header() && self.hasBlock(M.body(), L.header()))
                            inner = true;
                        }
                    if (!inner)
                        declined.add((Object*)L.header());
                    }
                }
            while (again && guard < (u32)64)
                {
                again = false;
                guard = guard + (u32)1;
                _ppModule = m;
                Array* loops = self.lrcLoops(fn);
                // Outermost first: a loop is taken only once every loop
                // around it has been declined.
                bool progress = true;
                while (progress && !again)
                    {
                    progress = false;
                for (u32 i = (u32)0; i < loops.count() && !again; i = i + (u32)1)
                    {
                    LRCLoop* L = (LRCLoop*)loops.get(i);
                    if (declined.indexOf((Object*)L.header()) != (u32)$FFFFFFFF)
                        continue;
                    bool inner = false;
                    for (u32 j = (u32)0; j < loops.count() && !inner; j = j + (u32)1)
                        {
                        LRCLoop* M = (LRCLoop*)loops.get(j);
                        if (M != L && M.header() != L.header() && self.hasBlock(M.body(), L.header())
                            && declined.indexOf((Object*)M.header()) == (u32)$FFFFFFFF)
                            inner = true;
                        }
                    if (inner)
                        continue;
                    progress = true;
                    declined.add((Object*)L.header());
                    // The program's loops only: one with no source line, or the
                        // standard library's (the runtime's own loops among them:
                        // outlining Data.withLength's made a block that made a
                        // block), stays.
                    IRInsn* at = ppFirstDbg(L);
                    if (at == (IRInsn*)0)
                        continue;
                    String* path = (String*)IRDbg.files().get(at.dbgFile());
                    if (path == (String*)0 || IRDbg.isLibraryPath(path))
                        continue;
                    String* verdict = ppVerdict(fn, L);
                    if (verdict != (String*)0)
                        {
                        _ppWhere = fn.name();
                        ppNo(verdict.cString());
                        continue;
                        }
                    if (ppOutlineLoop(m, fn, L, at))
                        again = true;
                    }
                    }
                }
            }
        }

    // The memory token current at the end of block b: the last one an
    // instruction of b produces, else the one current at the end of b's only
    // predecessor, up to the entry and the function's own token. 0 where a
    // join (two predecessors) comes first: there is no one token there.
    final IRValue* ppMemAtEnd(IRFunc* fn, IRBlock* b)
        {
        IRBlock* at = b;
        for (u32 guard = (u32)0; at != (IRBlock*)0 && guard < (u32)256; guard = guard + (u32)1)
            {
            for (u32 i = at.insns().count(); i > (u32)0; i = i - (u32)1)
                {
                IRInsn* n = (IRInsn*)at.insns().get(i - (u32)1);
                if (n.memRes() != (IRValue*)0)
                    return n.memRes();
                }
            IRBlock* pred = (IRBlock*)0;
            u32 preds = (u32)0;
            for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
                {
                IRBlock* q = (IRBlock*)fn.blocks().get(k);
                IRInsn* t = q.term();
                if (t == (IRInsn*)0)
                    continue;
                for (u32 o = (u32)0; o < t.ops().count(); o = o + (u32)1)
                    {
                    IROperand* op = (IROperand*)t.ops().get(o);
                    if (op.kind() == (u8)OPK_BLOCK && op.blk() == at)
                        {
                        if (pred != q)
                            preds = preds + (u32)1;
                        pred = q;
                        }
                    }
                }
            if (preds == (u32)0)
                {
                // The entry: the function's own token, its last parameter.
                if (at == (IRBlock*)fn.blocks().get((u32)0) && fn.params().count() > (u32)0)
                    {
                    IRValue* m = (IRValue*)fn.params().get(fn.params().count() - (u32)1);
                    return ppIsMem(m) ? m : (IRValue*)0;
                    }
                return (IRValue*)0;
                }
            if (preds > (u32)1)
                return (IRValue*)0;
            at = pred;
            }
        return (IRValue*)0;
        }

    static void ppAddOnce(Array* a, IRValue* v)
        {
        if (a.indexOf((Object*)v) == (u32)$FFFFFFFF)
            a.add((Object*)v);
        }

    // The instructions of a block, phis and terminator included, in order.
    static Array* ppAllInsns(IRBlock* b)
        {
        Array* out = new Array();
        out.addAll(b.phis());
        out.addAll(b.insns());
        if (b.term() != (IRInsn*)0)
            out.add((Object*)b.term());
        return out;
        }

    final bool ppOutlineLoop(IRModule* m, IRFunc* fn, LRCLoop* L, IRInsn* at)
        {
        _ppWhere = fn.name();
        if (at != (IRInsn*)0)
            _ppWhere = String.withFormat("%s:%ld", fn.name().cString(), (i32)at.dbgLine());
        IRBlock* P = L.pre();
        IRBlock* H = L.header();
        Array* body = L.body();
        if (P == (IRBlock*)0 || P.term() == (IRInsn*)0 || !P.term().op().equals(String.withCString("Branch")))
            return ppNo("cut 1");
        Map* defBlk = self.defBlockMap(fn);
        // One exit block.
        IRBlock* E = (IRBlock*)0;
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRInsn* t = ((IRBlock*)body.get(b)).term();
            if (t == (IRInsn*)0)
                return ppNo("cut 2");
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || self.hasBlock(body, o.blk()))
                    continue;
                if (E == (IRBlock*)0)
                    E = o.blk();
                else if (E != o.blk())
                    return ppNo("cut 3");
                }
            if (t.op().equals(String.withCString("Return")))
                return ppNo("cut 4");
            }
        if (E == (IRBlock*)0)
            return ppNo("cut 5");
        // A frame slot's address taken in the loop (a local array's) is the
        // same every iteration: taken before the loop instead, it is an
        // ordinary value the block captures.
        bool hoisted = false;
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)body.get(b);
            u32 i = (u32)0;
            while (i < bb.insns().count())
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.op().equals(String.withCString("AddrOf")) && n.ops().count() == (u32)1
                    && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                    && ppIsPinned(fn, ((IROperand*)n.ops().get((u32)0)).val()))
                    {
                    bb.insns().removeAt(i);
                    P.insns().add((Object*)n);
                    hoisted = true;
                    continue;
                    }
                i = i + (u32)1;
                }
            }
        if (hoisted)
            defBlk = self.defBlockMap(fn);
        // The values the loop reads from outside it.
        Array* liveIns = new Array();
        Array* memIns = new Array();
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            Array* all = ppAllInsns((IRBlock*)body.get(b));
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                // An address nothing uses (a promoted local's, which dead-code
                // removes later) reads nothing.
                if (n.op().equals(String.withCString("AddrOf")) && n.res() != (IRValue*)0
                    && self.aeUsersOf(fn, n.res()).count() == (u32)0)
                    continue;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    IRBlock* db = (IRBlock*)defBlk.get((Hashable*)o.val());
                    if (db != (IRBlock*)0 && self.hasBlock(body, db))
                        continue;
                    if (ppIsMem(o.val()))
                        ppAddOnce(memIns, o.val());
                    else
                        ppAddOnce(liveIns, o.val());
                    }
                }
            }
        // A loop that touches no memory (a pure reduction) still needs a
        // token for the call: the one current where the loop begins.
        if (memIns.count() == (u32)0)
            {
            IRValue* cur = ppMemAtEnd(fn, P);
            if (cur != (IRValue*)0)
                memIns.add((Object*)cur);
            }
        if (memIns.count() != (u32)1)
            return ppNo(String.withFormat("cut 6: %u memory tokens in", memIns.count()).cString());
        // A frame slot is the function's own: not passed.
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            if (liveIns.indexOf((Object*)((IRPinned*)fn.pinned().get(i)).val()) != (u32)$FFFFFFFF)
                return ppNo("cut 7");
        // What is live after it: one memory token at most, and one value.
        Array* memOuts = new Array();
        Array* liveOuts = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(body, ob))
                continue;
            Array* all = ppAllInsns(ob);
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                u32 fromBody = (u32)0;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_BLOCK && self.hasBlock(body, o.blk()))
                        fromBody = fromBody + (u32)1;
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    IRBlock* db = (IRBlock*)defBlk.get((Hashable*)o.val());
                    if (db == (IRBlock*)0 || !self.hasBlock(body, db))
                        continue;
                    if (ppIsMem(o.val()))
                        ppAddOnce(memOuts, o.val());
                    else
                        ppAddOnce(liveOuts, o.val());
                    }
                // A phi in the exit with two edges from the loop: they become
                // one edge from the call.
                if (n.op().equals(String.withCString("Phi")) && fromBody > (u32)1)
                    return ppNo("cut 8");
                }
            }
        if (memOuts.count() > (u32)1)
            return ppNo("cut 9");
        // Stage 3: a block of its own, run by the par runtime, where the shape
        // is one it can split (ppOutlinePar says which).
        _ppWhere = fn.name();
        if (at != (IRInsn*)0)
            _ppWhere = String.withFormat("%s:%ld", fn.name().cString(), (i32)at.dbgLine());
        if (ppOutlinePar(m, fn, L, at, E, liveIns, (IRValue*)memIns.get((u32)0),
                         memOuts.count() == (u32)1 ? (IRValue*)memOuts.get((u32)0) : (IRValue*)0, liveOuts))
            {
            ppTrace("a block");
            return true;
            }
        // Too small to be a block, and no loop inside it to judge: it stays,
        // not outlined serially.
        if (_ppStayPut)
            {
            _ppStayPut = false;
            return false;
            }
        if (liveOuts.count() > (u32)1)
            return ppNo("cut 10");
        IRValue* outV = liveOuts.count() == (u32)1 ? (IRValue*)liveOuts.get((u32)0) : (IRValue*)0;

        // The outlined function.
        _ppOutN = _ppOutN + (u32)1;
        String* name = String.withFormat("ParOut$%u$run", _ppOutN);
        IRFunc* O = new IRFunc();
        O.setName(name);
        O.setRet(outV != (IRValue*)0 ? outV.ty() : String.withCString("Void"));
        if (fn.hasDbg())
            O.setDbg(fn.dbgFile(), fn.dbgLine(), fn.dbgCol());
        Map* remap = new Map();
        String* sig = String.withCString("(");
        for (u32 i = (u32)0; i < liveIns.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)liveIns.get(i);
            IRValue* p = new IRValue(v.ty());
            O.addParam(p);
            remap.set((Hashable*)v, (Object*)IROperand.useVal(p));
            if (i > (u32)0)
                sig.appendCString(", ");
            sig.append(v.ty());
            }
        sig.appendCString(") -> ");
        sig.append(O.ret());
        IRValue* mp = new IRValue(String.withCString("Mem"));
        O.addParam(mp);
        remap.set((Hashable*)memIns.get((u32)0), (Object*)IROperand.useVal(mp));
        Map* blockMap = new Map();
        IRBlock* entry = new IRBlock(String.withCString("bb_entry"));
        IRBlock* exitB = new IRBlock(String.withCString("bb_out_exit"));
        blockMap.set((Hashable*)E, (Object*)exitB);
        Array* ordered = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)fn.blocks().get(b);
            if (!self.hasBlock(body, ob))
                continue;
            ordered.add((Object*)ob);
            blockMap.set((Hashable*)ob, (Object*)new IRBlock(ob.name()));
            Array* all = ppAllInsns(ob);
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                if (n.res() != (IRValue*)0)
                    remap.set((Hashable*)n.res(), (Object*)IROperand.useVal(new IRValue(n.res().ty())));
                if (n.memRes() != (IRValue*)0)
                    remap.set((Hashable*)n.memRes(), (Object*)IROperand.useVal(new IRValue(n.memRes().ty())));
                }
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block((IRBlock*)blockMap.get((Hashable*)H)));
        entry.setTerm(br);
        O.addBlock(entry);
        for (u32 b = (u32)0; b < ordered.count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)ordered.get(b);
            IRBlock* nb = (IRBlock*)blockMap.get((Hashable*)ob);
            for (u32 i = (u32)0; i < ob.phis().count(); i = i + (u32)1)
                {
                IRInsn* c = self.cloneInsn(remap, blockMap, (IRInsn*)ob.phis().get(i));
                // The edge from the preheader is the edge from the entry now.
                for (u32 k = (u32)0; k < c.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)c.ops().get(k);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == P)
                        c.ops().set(k, (Object*)IROperand.block(entry));
                    }
                nb.addPhi(c);
                }
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                nb.add(self.cloneInsn(remap, blockMap, (IRInsn*)ob.insns().get(i)));
            nb.setTerm(self.cloneInsn(remap, blockMap, ob.term()));
            O.addBlock(nb);
            }
        IRInsn* ret = IRInsn.with(String.withCString("Return"));
        if (outV != (IRValue*)0)
            ret.add(IROperand.useVal(self.remappedValue(remap, outV)));
        ret.add(IROperand.useVal(memOuts.count() == (u32)1 ? self.remappedValue(remap, (IRValue*)memOuts.get((u32)0)) : mp));
        exitB.setTerm(ret);
        O.addBlock(exitB);
        m.addFunc(O);
        m.addSym(IRSymbol.func(name, sig, false, false));

        // In its place, the call.
        IRInsn* call = IRInsn.with(String.withCString("Call"));
        call.setCc(String.withCString("CallConv::Standard"));
        if (at != (IRInsn*)0)
            call.copyDbg(at);
        call.add(IROperand.sym(name));
        for (u32 i = (u32)0; i < liveIns.count(); i = i + (u32)1)
            call.add(IROperand.useVal((IRValue*)liveIns.get(i)));
        call.add(IROperand.useVal((IRValue*)memIns.get((u32)0)));
        IRValue* memOut = new IRValue(String.withCString("Mem"));
        call.setMemRes(memOut);
        IRValue* callRes = (IRValue*)0;
        if (outV != (IRValue*)0)
            {
            callRes = new IRValue(outV.ty());
            call.setRes(callRes);
            }
        P.add(call);
        IRInsn* jump = IRInsn.with(String.withCString("Branch"));
        jump.copyDbg(P.term());
        jump.add(IROperand.block(E));
        P.setTerm(jump);
        for (u32 i = (u32)0; i < E.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)E.phis().get(i);
            for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)phi.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && self.hasBlock(body, o.blk()))
                    phi.ops().set(k, (Object*)IROperand.block(P));
                }
            }
        if (memOuts.count() == (u32)1)
            self.rewriteUsesTo(fn, (IRValue*)memOuts.get((u32)0), IROperand.useVal(memOut));
        if (outV != (IRValue*)0)
            self.rewriteUsesTo(fn, outV, IROperand.useVal(callRes));
        Array* keep = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (!self.hasBlock(body, (IRBlock*)fn.blocks().get(b)))
                keep.add(fn.blocks().get(b));
        fn.setBlocks(keep);
        ppTrace("serial");
        return true;
        }

    // A function defined here that touches no memory at all (no load, store,
    // call but to such a function, or reference counting): what it returns
    // is its arguments' alone.
    final bool ppPureFn(String* name, u32 depth)
        {
        if (depth > (u32)4 || _ppModule == (IRModule*)0)
            return false;
        IRFunc* f = self.funcNamed(_ppModule, name);
        if (f == (IRFunc*)0 || f.blocks().count() == (u32)0)
            return false;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                String* op = n.op();
                if (op.equals(String.withCString("Call")))
                    {
                    IROperand* c = n.ops().count() > (u32)0 ? (IROperand*)n.ops().get((u32)0) : (IROperand*)0;
                    if (c == (IROperand*)0 || c.kind() != (u8)OPK_SYM || !ppPureFn(c.name(), depth + (u32)1))
                        return false;
                    continue;
                    }
                // An address nothing uses (a promoted local's, which dead-code
                // removes later) touches nothing.
                if (op.equals(String.withCString("AddrOf")) && n.res() != (IRValue*)0
                    && self.aeUsersOf(f, n.res()).count() == (u32)0)
                    continue;
                if (lrcWritesMemory(op) || op.hasPrefix(String.withCString("Load")) || op.equals(String.withCString("AddrOf")))
                    return false;
                }
            }
        return true;
        }

    // The index terms (operands, summed) are iteration iv's own: one is
    // iv * c (iv itself, c = 1, an extension of either), and the others sum
    // to a value in [0, c), so that no two iterations' elements meet.
    final bool ppRowOwned(Array* terms, IRValue* iv, Map* defOf)
        {
        Array* flat = new Array();
        for (u32 i = (u32)0; i < terms.count(); i = i + (u32)1)
            ppFlattenAdd((IROperand*)terms.get(i), defOf, flat, (u32)0);
        i64 c = (i64)0;
        i64 lo = (i64)0;
        i64 hi = (i64)0;
        for (u32 i = (u32)0; i < flat.count(); i = i + (u32)1)
            {
            IROperand* t = (IROperand*)flat.get(i);
            i64 k = (i64)0;
            if (constValue(defOf, t, &k))
                {
                lo = lo + k;
                hi = hi + k;
                continue;
                }
            IRValue* v = ppStripExt(t.val(), defOf);
            if (v == iv)
                {
                if (c != (i64)0)
                    return false;
                c = (i64)1;
                continue;
                }
            IRInsn* m = (IRInsn*)defOf.get((Hashable*)v);
            if (m != (IRInsn*)0 && m.op().equals(String.withCString("Mul")) && m.ops().count() == (u32)2)
                {
                IROperand* a = (IROperand*)m.ops().get((u32)0);
                IROperand* b = (IROperand*)m.ops().get((u32)1);
                i64 s = (i64)0;
                IROperand* other = (IROperand*)0;
                if (constValue(defOf, b, &s))
                    other = a;
                else if (constValue(defOf, a, &s))
                    other = b;
                if (other != (IROperand*)0 && s > (i64)0 && other.kind() == (u8)OPK_USE)
                    {
                    if (ppStripExt(other.val(), defOf) == iv)
                        {
                        if (c != (i64)0)
                            return false;
                        c = s;
                        continue;
                        }
                    i64 l2 = (i64)0;
                    i64 h2 = (i64)0;
                    if (!ppIval(other.val(), defOf, (u32)0, &l2, &h2))
                        return false;
                    lo = lo + l2 * s;
                    hi = hi + h2 * s;
                    continue;
                    }
                }
            i64 l3 = (i64)0;
            i64 h3 = (i64)0;
            if (!ppIval(t.val(), defOf, (u32)0, &l3, &h3))
                return false;
            lo = lo + l3;
            hi = hi + h3;
            }
        if (c == (i64)0)
            return false;
        _ppRowC = c;
        _ppRowLo = lo;
        _ppRowHi = hi;
        return lo >= (i64)0 && hi < c;
        }

    final void ppFlattenAdd(IROperand* o, Map* defOf, Array* out, u32 depth)
        {
        if (o.kind() == (u8)OPK_USE && depth < (u32)6)
            {
            IRValue* v = o.val();
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
            // Through a sign extension of a sum: C's int index arithmetic,
            // which may not overflow.
            if (d != (IRInsn*)0 && d.op().equals(String.withCString("SExt")) && d.ops().count() == (u32)1)
                {
                IRInsn* inner = (IRInsn*)defOf.get((Hashable*)((IROperand*)d.ops().get((u32)0)).val());
                if (inner != (IRInsn*)0 && inner.op().equals(String.withCString("Add")))
                    d = inner;
                }
            if (d != (IRInsn*)0 && d.op().equals(String.withCString("Add")) && d.ops().count() == (u32)2)
                {
                ppFlattenAdd((IROperand*)d.ops().get((u32)0), defOf, out, depth + (u32)1);
                ppFlattenAdd((IROperand*)d.ops().get((u32)1), defOf, out, depth + (u32)1);
                return;
                }
            }
        out.add((Object*)o);
        }

    final IRValue* ppStripExt(IRValue* v, Map* defOf)
        {
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        while (d != (IRInsn*)0 && (d.op().equals(String.withCString("SExt")) || d.op().equals(String.withCString("ZExt")))
               && d.ops().count() == (u32)1 && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            {
            v = ((IROperand*)d.ops().get((u32)0)).val();
            d = (IRInsn*)defOf.get((Hashable*)v);
            }
        return v;
        }

    // The values v takes where it is used, when known: a constant; an
    // extension, or a sum or difference with a constant, of a value known;
    // a counting loop's induction phi (from a constant, by a positive
    // constant step, while it is below a constant: [start, bound - 1]).
    final bool ppIval(IRValue* v, Map* defOf, u32 depth, i64* lo, i64* hi)
        {
        if (depth > (u32)6 || v == (IRValue*)0)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        if (d == (IRInsn*)0)
            return false;
        String* op = d.op();
        if (op.equals(String.withCString("Const")))
            {
            IROperand* k = (IROperand*)d.ops().get((u32)0);
            if (k.kind() != (u8)OPK_IMMI)
                return false;
            lo[0] = k.imm();
            hi[0] = k.imm();
            return true;
            }
        if ((op.equals(String.withCString("SExt")) || op.equals(String.withCString("ZExt"))) && d.ops().count() == (u32)1
            && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            {
            if (!ppIval(((IROperand*)d.ops().get((u32)0)).val(), defOf, depth + (u32)1, lo, hi))
                return false;
            return op.equals(String.withCString("SExt")) || lo[0] >= (i64)0;
            }
        if ((op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"))) && d.ops().count() == (u32)2)
            {
            i64 k = (i64)0;
            IROperand* a = (IROperand*)d.ops().get((u32)0);
            IROperand* b = (IROperand*)d.ops().get((u32)1);
            bool sub = op.equals(String.withCString("Sub"));
            IROperand* x = (IROperand*)0;
            if (constValue(defOf, b, &k))
                x = a;
            else if (!sub && self.constValue(defOf, a, &k))
                x = b;
            if (x == (IROperand*)0 || x.kind() != (u8)OPK_USE)
                return false;
            if (!ppIval(x.val(), defOf, depth + (u32)1, lo, hi))
                return false;
            if (sub)
                k = (i64)0 - k;
            lo[0] = lo[0] + k;
            hi[0] = hi[0] + k;
            return true;
            }
        if (op.equals(String.withCString("Phi")) && d.ops().count() == (u32)4 && _ppDefBlk != (Map*)0)
            return ppIvalPhi(d, defOf, lo, hi);
        return false;
        }

    final bool ppIvalPhi(IRInsn* phi, Map* defOf, i64* lo, i64* hi)
        {
        IRValue* pv = phi.res();
        IRBlock* H = (IRBlock*)_ppDefBlk.get((Hashable*)pv);
        if (H == (IRBlock*)0 || H.term() == (IRInsn*)0 || !H.term().op().equals(String.withCString("CondBranch"))
            || H.term().ops().count() < (u32)3)
            return false;
        // The start (a constant) and the step (pv + a positive constant).
        i64 start = (i64)0;
        i64 step = (i64)0;
        bool haveStart = false;
        IRBlock* latch = (IRBlock*)0;
        for (u32 e = (u32)0; e < (u32)2; e = e + (u32)1)
            {
            IROperand* eb = (IROperand*)phi.ops().get(e * (u32)2);
            IROperand* ev = (IROperand*)phi.ops().get(e * (u32)2 + (u32)1);
            i64 k = (i64)0;
            IRInsn* ed = ev.kind() == (u8)OPK_USE ? (IRInsn*)defOf.get((Hashable*)ev.val()) : (IRInsn*)0;
            if (ed != (IRInsn*)0 && ed.op().equals(String.withCString("Add")) && ed.ops().count() == (u32)2
                && ((IROperand*)ed.ops().get((u32)0)).kind() == (u8)OPK_USE && ((IROperand*)ed.ops().get((u32)0)).val() == pv
                && self.constValue(defOf, (IROperand*)ed.ops().get((u32)1), &k) && k > (i64)0)
                {
                step = k;
                latch = eb.blk();
                }
            else if (constValue(defOf, ev, &k))
                {
                start = k;
                haveStart = true;
                }
            }
        if (!haveStart || step == (i64)0 || latch == (IRBlock*)0)
            return false;
        // The test: pv < bound (or <=), the body on the true edge.
        IROperand* c0 = (IROperand*)H.term().ops().get((u32)0);
        IRInsn* g = c0.kind() == (u8)OPK_USE ? (IRInsn*)defOf.get((Hashable*)c0.val()) : (IRInsn*)0;
        if (g == (IRInsn*)0 || !g.op().equals(String.withCString("ICmp")) || g.ops().count() < (u32)2 || g.pred() == (String*)0)
            return false;
        IROperand* g0 = (IROperand*)g.ops().get((u32)0);
        if (g0.kind() != (u8)OPK_USE || g0.val() != pv)
            return false;
        i64 bound = (i64)0;
        if (!self.constValue(defOf, (IROperand*)g.ops().get((u32)1), &bound))
            return false;
        String* pr = g.pred();
        bool lt = pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("ULT"));
        bool le = pr.equals(String.withCString("SLE")) || pr.equals(String.withCString("ULE"));
        if (!lt && !le)
            return false;
        // The body is the true edge: it reaches the latch without passing
        // the header, and the false edge does not.
        IRBlock* T = ((IROperand*)H.term().ops().get((u32)1)).blk();
        IRBlock* F = ((IROperand*)H.term().ops().get((u32)2)).blk();
        if (!ppReaches(T, latch, H) || ppReaches(F, latch, H))
            return false;
        if (start < (i64)0 && (pr.equals(String.withCString("ULT")) || pr.equals(String.withCString("ULE"))))
            return false;
        lo[0] = start;
        hi[0] = le ? bound : bound - (i64)1;
        return hi[0] >= lo[0];
        }

    // A path from `from` to `to` that does not pass `stop`.
    final bool ppReaches(IRBlock* from, IRBlock* to, IRBlock* stop)
        {
        Array* seen = new Array();
        Array* work = new Array();
        work.add((Object*)from);
        while (work.count() > (u32)0)
            {
            IRBlock* b = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (b == to)
                return true;
            if (b == stop || seen.indexOf((Object*)b) != (u32)$FFFFFFFF)
                continue;
            seen.add((Object*)b);
            IRInsn* t = b.term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK)
                    work.add((Object*)o.blk());
                }
            }
        return false;
        }

    // A C module's array indices, widened by clang to i64 (`sext i32 %i`),
    // as the 32-bit values they were: a signed 32-bit index is sign-extended
    // where it is used, so that one is exact; a zero-extended one is taken
    // only when its value is known to be in [0, 2^31) (a counting loop's
    // counter). The vectoriser and the outliner then see the loop counter
    // itself as the index, as they do in an xc program.
    final void cNarrowIndices(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0)
                continue;
            Map* defOf = self.defMapAll(fn);
            _ppDefBlk = self.defBlockMap(fn);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    if (!n.op().equals(String.withCString("ElementAddr")) || n.ops().count() != (u32)2)
                        continue;
                    IROperand* io = (IROperand*)n.ops().get((u32)1);
                    if (io.kind() != (u8)OPK_USE || io.val() == (IRValue*)0)
                        continue;
                    IRInsn* x = (IRInsn*)defOf.get((Hashable*)io.val());
                    if (x == (IRInsn*)0 || x.ops().count() != (u32)1 || ((IROperand*)x.ops().get((u32)0)).kind() != (u8)OPK_USE)
                        continue;
                    IRValue* src = ((IROperand*)x.ops().get((u32)0)).val();
                    if (src == (IRValue*)0 || !src.ty().equals(String.withCString("I32")))
                        continue;
                    bool ok = x.op().equals(String.withCString("SExt"));
                    if (!ok && x.op().equals(String.withCString("ZExt")))
                        {
                        i64 lo = (i64)0;
                        i64 hi = (i64)0;
                        ok = ppIval(src, defOf, (u32)0, &lo, &hi) && lo >= (i64)0 && hi <= (i64)2147483647;
                        }
                    if (ok)
                        n.ops().set((u32)1, (Object*)IROperand.useVal(src));
                    }
                }
            _ppDefBlk = (Map*)0;
            }
        }

    final bool ppIsPinned(IRFunc* fn, IRValue* v)
        {
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            if (((IRPinned*)fn.pinned().get(i)).val() == v)
                return true;
        return false;
        }

    // inner: a phi in a header inside L, [acc (from outside that loop),
    // inner op x (from inside it)], with op one a reduction may use, x not
    // reading acc or inner, and nothing else using acc, inner or the update:
    // op, else 0.
    final String* ppNestedRedOf(IRFunc* fn, LRCLoop* L, IRInsn* inner, IRValue* acc, Map* defOf)
        {
        if (!inner.op().equals(String.withCString("Phi")) || inner.ops().count() != (u32)4 || inner.res() == (IRValue*)0)
            return (String*)0;
        IRValue* pv = inner.res();
        IROperand* v0 = (IROperand*)inner.ops().get((u32)1);
        IROperand* v1 = (IROperand*)inner.ops().get((u32)3);
        if (v0.kind() != (u8)OPK_USE || v1.kind() != (u8)OPK_USE)
            return (String*)0;
        IRValue* upd = (IRValue*)0;
        if (v0.val() == acc)
            upd = v1.val();
        else if (v1.val() == acc)
            upd = v0.val();
        else
            return (String*)0;
        IRInsn* u = (IRInsn*)defOf.get((Hashable*)upd);
        if (u == (IRInsn*)0 || u.ops().count() != (u32)2 || !ppRedOp(u.op()))
            return (String*)0;
        IROperand* a = (IROperand*)u.ops().get((u32)0);
        IROperand* b = (IROperand*)u.ops().get((u32)1);
        IROperand* x = (IROperand*)0;
        if (a.kind() == (u8)OPK_USE && a.val() == pv)
            x = b;
        else if (b.kind() == (u8)OPK_USE && b.val() == pv)
            x = a;
        // Or a tree of the operator holding the inner phi once.
        bool tree = x == (IROperand*)0 && ppAssocChainOf(u, pv, defOf) && !ppTreeReads(u, pv, acc, defOf);
        if (x == (IROperand*)0 && !tree)
            return (String*)0;
        if (x != (IROperand*)0 && x.kind() == (u8)OPK_USE && (ppDependsOn(x.val(), pv, defOf, (u32)0) || ppDependsOn(x.val(), acc, defOf, (u32)0)))
            return (String*)0;
        // The partial sums are used by the chain alone: acc by the inner phi
        // (and after the loop), the inner phi by the update and as acc's
        // next value, the update by the inner phi.
        Array* ua = self.aeUsersOf(fn, acc);
        for (u32 i = (u32)0; i < ua.count(); i = i + (u32)1)
            {
            IRInsn* w = (IRInsn*)ua.get(i);
            if (w != inner && w != (IRInsn*)defOf.get((Hashable*)acc) && ppInLoop(L, w))
                return (String*)0;
            }
        Array* up = self.aeUsersOf(fn, pv);
        for (u32 i = (u32)0; i < up.count(); i = i + (u32)1)
            {
            IRInsn* w = (IRInsn*)up.get(i);
            if (w != u && w != (IRInsn*)defOf.get((Hashable*)acc) && !(tree && ppInTree(u, w, defOf)))
                return (String*)0;
            }
        Array* uu = self.aeUsersOf(fn, upd);
        for (u32 i = (u32)0; i < uu.count(); i = i + (u32)1)
            if ((IRInsn*)uu.get(i) != inner)
                return (String*)0;
        return u.op();
        }

    // Whether insn u is a tree of its one (associative, commutative,
    // integer) operator whose leaves hold acc exactly once, as a leaf, the
    // others free of it; the inner nodes used only within the tree.
    final bool ppAssocChainOf(IRInsn* u, IRValue* acc, Map* defOf)
        {
        String* op = u.op();
        if (!op.equals(String.withCString("Add")) && !op.equals(String.withCString("Mul")) && !op.equals(String.withCString("And"))
            && !op.equals(String.withCString("Or")) && !op.equals(String.withCString("Xor")))
            return false;
        u32 hits = (u32)0;
        Array* work = new Array();
        work.add((Object*)u);
        for (u32 guard = (u32)0; work.count() > (u32)0 && guard < (u32)256; guard = guard + (u32)1)
            {
            IRInsn* n = (IRInsn*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (n.ops().count() != (u32)2)
                return false;
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                if (o.val() == acc)
                    {
                    hits = hits + (u32)1;
                    continue;
                    }
                IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
                if (d != (IRInsn*)0 && d.op().equals(op) && ppDependsOn(o.val(), acc, defOf, (u32)0))
                    {
                    work.add((Object*)d);
                    continue;
                    }
                if (ppDependsOn(o.val(), acc, defOf, (u32)0))
                    return false;
                }
            }
        return hits == (u32)1 && work.count() == (u32)0;
        }

    // Whether a leaf of u's tree (other than pv itself) reads pv or acc.
    final bool ppTreeReads(IRInsn* u, IRValue* pv, IRValue* acc, Map* defOf)
        {
        Array* work = new Array();
        work.add((Object*)u);
        while (work.count() > (u32)0)
            {
            IRInsn* n = (IRInsn*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || o.val() == pv)
                    continue;
                IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
                if (d != (IRInsn*)0 && d.op().equals(u.op()) && ppDependsOn(o.val(), pv, defOf, (u32)0))
                    {
                    work.add((Object*)d);
                    continue;
                    }
                if (ppDependsOn(o.val(), acc, defOf, (u32)0))
                    return true;
                }
            }
        return false;
        }

    // Whether w is one of the inner nodes of u's operator tree (the path
    // from u down to the accumulator).
    final bool ppInTree(IRInsn* u, IRInsn* w, Map* defOf)
        {
        Array* work = new Array();
        work.add((Object*)u);
        for (u32 guard = (u32)0; work.count() > (u32)0 && guard < (u32)256; guard = guard + (u32)1)
            {
            IRInsn* n = (IRInsn*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (n == w)
                return true;
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
                if (d != (IRInsn*)0 && d.op().equals(u.op()))
                    work.add((Object*)d);
                }
            }
        return false;
        }

    final bool ppInLoop(LRCLoop* L, IRInsn* w)
        {
        Array* body = L.body();
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)body.get(b);
            if (bb.insns().indexOf((Object*)w) != (u32)$FFFFFFFF || bb.phis().indexOf((Object*)w) != (u32)$FFFFFFFF
                || bb.term() == w)
                return true;
            }
        return false;
        }

    // Select(c, acc op x, acc) or Select(c, acc, acc op x), op one a
    // reduction may use and x not reading acc: op, else 0.
    final String* ppCondUpdateOf(IRInsn* sel, IRValue* acc, Map* defOf)
        {
        IROperand* tv = (IROperand*)0;
        IROperand* fv = (IROperand*)0;
        // Or not if-converted: the join's Phi [(then, acc op x), (else, acc)].
        if (sel.op().equals(String.withCString("Phi")) && sel.ops().count() == (u32)4)
            {
            tv = (IROperand*)sel.ops().get((u32)1);
            fv = (IROperand*)sel.ops().get((u32)3);
            }
        else if (sel.op().equals(String.withCString("Select")) && sel.ops().count() == (u32)3)
            {
            tv = (IROperand*)sel.ops().get((u32)1);
            fv = (IROperand*)sel.ops().get((u32)2);
            }
        else
            return (String*)0;
        if (tv.kind() != (u8)OPK_USE || fv.kind() != (u8)OPK_USE)
            return (String*)0;
        IRValue* upd = (IRValue*)0;
        if (fv.val() == acc)
            upd = tv.val();
        else if (tv.val() == acc)
            upd = fv.val();
        else
            return (String*)0;
        IRInsn* u = (IRInsn*)defOf.get((Hashable*)upd);
        if (u == (IRInsn*)0 || u.ops().count() != (u32)2 || !ppRedOp(u.op()))
            return (String*)0;
        IROperand* a = (IROperand*)u.ops().get((u32)0);
        IROperand* b = (IROperand*)u.ops().get((u32)1);
        IROperand* other = (IROperand*)0;
        if (a.kind() == (u8)OPK_USE && a.val() == acc)
            other = b;
        else if (b.kind() == (u8)OPK_USE && b.val() == acc)
            other = a;
        if (other == (IROperand*)0)
            return (String*)0;
        if (other.kind() == (u8)OPK_USE && ppDependsOn(other.val(), acc, defOf, (u32)0))
            return (String*)0;
        return u.op();
        }

    // A running min or max: next = Select(cmp(x, acc), x, acc) in any of its
    // spellings (operands either way round, the branches either way). Says
    // "Max:S", "Min:U", "Max:F" ... or 0. x must not depend on acc.
    final String* ppMinMaxOf(IRInsn* sel, IRValue* acc, Map* defOf)
        {
        if (!sel.op().equals(String.withCString("Select")) || sel.ops().count() != (u32)3)
            return (String*)0;
        IROperand* co = (IROperand*)sel.ops().get((u32)0);
        IROperand* tv = (IROperand*)sel.ops().get((u32)1);
        IROperand* fv = (IROperand*)sel.ops().get((u32)2);
        if (co.kind() != (u8)OPK_USE || tv.kind() != (u8)OPK_USE || fv.kind() != (u8)OPK_USE)
            return (String*)0;
        IRValue* x = (IRValue*)0;
        bool pickXWhenTrue = false;
        if (fv.val() == acc && tv.val() != acc)
            {
            x = tv.val();
            pickXWhenTrue = true;
            }
        else if (tv.val() == acc && fv.val() != acc)
            x = fv.val();
        else
            return (String*)0;
        if (ppDependsOn(x, acc, defOf, (u32)0))
            return (String*)0;
        IRInsn* c = (IRInsn*)defOf.get((Hashable*)co.val());
        if (c == (IRInsn*)0 || c.ops().count() != (u32)2
            || !(c.op().equals(String.withCString("ICmp")) || c.op().equals(String.withCString("FCmp"))))
            return (String*)0;
        IROperand* l = (IROperand*)c.ops().get((u32)0);
        IROperand* r = (IROperand*)c.ops().get((u32)1);
        if (l.kind() != (u8)OPK_USE || r.kind() != (u8)OPK_USE)
            return (String*)0;
        // Is the condition "x is greater"?
        bool xLeft = false;
        if (l.val() == x && r.val() == acc)
            xLeft = true;
        else if (!(l.val() == acc && r.val() == x))
            return (String*)0;
        String* p = c.pred();
        bool gt = p.hasSuffix(String.withCString("GT")) || p.hasSuffix(String.withCString("GE"));
        bool lt = p.hasSuffix(String.withCString("LT")) || p.hasSuffix(String.withCString("LE"));
        if (!gt && !lt)
            return (String*)0;
        bool xGreater = xLeft ? gt : lt;
        // Taking x when it is greater is a max; when it is smaller, a min.
        bool isMax = pickXWhenTrue ? xGreater : !xGreater;
        String* kind = c.op().equals(String.withCString("FCmp")) ? String.withCString("F")
                     : p.hasPrefix(String.withCString("U")) ? String.withCString("U") : String.withCString("S");
        return String.withFormat("%s:%s", isMax ? "Max" : "Min", kind.cString());
        }

    // gpuGlobal(self, name) (addr) or gpuGlobalBytes(self, name): for each
    // global the loop names, by name (parSameName), its address or its size;
    // else 0 / -1. A chain of Selects. Its name.
    final String* ppGpuGlobals(IRModule* m, String* stem, String* objT, IRFunc* run, bool addr)
        {
        String* u8p = String.withCString("Ptr(U8, unbanked)");
        String* vp = String.withCString("Ptr(Void, unbanked)");
        String* i64t = String.withCString("I64");
        String* rt = addr ? vp : i64t;
        IRFunc* F = new IRFunc();
        F.setName(String.withFormat(addr ? "%s$gpuGlobal" : "%s$gpuGlobalBytes", stem.cString()));
        F.setRet(rt);
        IRValue* sv = new IRValue(objT);
        IRValue* nm = new IRValue(u8p);
        IRValue* mem = new IRValue(String.withCString("Mem"));
        F.addParam(sv);
        F.addParam(nm);
        F.addParam(mem);
        IRBlock* b = new IRBlock(String.withCString("bb_entry"));
        IRValue* acc = (IRValue*)0;
        if (addr)
            {
            IRValue* z = ppEmit(b, String.withCString("Const"), i64t, IROperand.immI((i64)0, i64t), (IROperand*)0, (IROperand*)0);
            acc = ppEmit(b, String.withCString("IntToPtr"), vp, IROperand.useVal(z), (IROperand*)0, (IROperand*)0);
            }
        else
            acc = ppEmit(b, String.withCString("Const"), i64t, IROperand.immI((i64)0 - (i64)1, i64t), (IROperand*)0, (IROperand*)0);
        Array* seen = new Array();
        IRValue* mm = mem;
        for (u32 bb = (u32)0; bb < run.blocks().count(); bb = bb + (u32)1)
            {
            IRBlock* blk = (IRBlock*)run.blocks().get(bb);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (!n.op().equals(String.withCString("AddrOf")) || n.ops().count() != (u32)1)
                    continue;
                IROperand* o = (IROperand*)n.ops().get((u32)0);
                if (o.kind() != (u8)OPK_SYM)
                    continue;
                IRSymbol* g = self.symNamed(m, o.name());
                if (g == (IRSymbol*)0 || g.kind() != (u8)SYM_DATAGLOBAL)
                    continue;
                bool dup = false;
                for (u32 k = (u32)0; k < seen.count() && !dup; k = k + (u32)1)
                    dup = ((String*)seen.get(k)).equals(o.name());
                if (dup)
                    continue;
                seen.add((Object*)o.name());
                Array* nb = new Array();
                for (u32 k = (u32)0; k < o.name().byteLength(); k = k + (u32)1)
                    nb.add((Object*)Number.with((u32)o.name().byteAt(k)));
                nb.add((Object*)Number.with((u32)0));
                String* sn = String.withFormat("%s$g%u%s", stem.cString(), seen.count(), addr ? "a" : "b");
                m.addSym(IRSymbol.stringLit(sn, nb));
                IRValue* lit = ppEmit(b, String.withCString("AddrOf"), u8p, IROperand.sym(sn), (IROperand*)0, (IROperand*)0);
                IRValue* same = ppCall(b, String.withCString("parSameName"), String.withCString("Bool"),
                                       IROperand.useVal(nm), IROperand.useVal(lit), (IROperand*)0, mm);
                mm = _ppLastMem;
                IRValue* v = (IRValue*)0;
                if (addr)
                    {
                    IRValue* ga = ppEmit(b, String.withCString("AddrOf"), n.res().ty(), IROperand.sym(o.name()), (IROperand*)0, (IROperand*)0);
                    v = ppEmit(b, String.withCString("Bitcast"), vp, IROperand.useVal(ga), (IROperand*)0, (IROperand*)0);
                    }
                else
                    {
                    u32 size = (u32)0;
                    String* gt = g.globalTy();
                    if (gt != (String*)0 && gt.hasPrefix(String.withCString("Agg(")))
                        {
                        u32 id = (u32)0;
                        for (u32 k = (u32)4; k < gt.byteLength() && gt.byteAt(k) >= (u8)'0' && gt.byteAt(k) <= (u8)'9'; k = k + (u32)1)
                            id = id * (u32)10 + (u32)(gt.byteAt(k) - (u8)'0');
                        if (id < m.layouts().count())
                            size = ((IRLayout*)m.layouts().get(id)).size();
                        }
                    else
                        size = self.irWidth(gt);
                    v = ppEmit(b, String.withCString("Const"), i64t, IROperand.immI((i64)size, i64t), (IROperand*)0, (IROperand*)0);
                    }
                acc = ppEmit(b, String.withCString("Select"), rt, IROperand.useVal(same), IROperand.useVal(v), IROperand.useVal(acc));
                }
            }
        IRInsn* r = IRInsn.with(String.withCString("Return"));
        r.add(IROperand.useVal(acc));
        r.add(IROperand.useVal(mm));
        b.setTerm(r);
        F.addBlock(b);
        m.addFunc(F);
        m.addSym(IRSymbol.func(F.name(), String.withFormat("(%s, %s) -> %s", objT.cString(), u8p.cString(), rt.cString()), false, false));
        return F.name();
        }

    // gpuLength(self, k): for record field k a pointer capture, the bytes from
    // it to the end of its heap block (Par.spanOf, as a generated block's);
    // -1 for any other field. Its name.
    final String* ppGpuLength(IRModule* m, String* stem, String* objT, String* recT, Array* liveIns)
        {
        String* i64t = String.withCString("I64");
        String* u8p = String.withCString("Ptr(U8, unbanked)");
        IRFunc* F = new IRFunc();
        F.setName(String.withFormat("%s$gpuLength", stem.cString()));
        F.setRet(i64t);
        IRValue* sv = new IRValue(objT);
        IRValue* k = new IRValue(String.withCString("I32"));
        IRValue* mem = new IRValue(String.withCString("Mem"));
        F.addParam(sv);
        F.addParam(k);
        F.addParam(mem);
        IRBlock* b = new IRBlock(String.withCString("bb_entry"));
        IRValue* acc = ppEmit(b, String.withCString("Const"), i64t, IROperand.immI((i64)0 - (i64)1, i64t), (IROperand*)0, (IROperand*)0);
        IRValue* mm = mem;
        IRValue* rec = (IRValue*)0;
        for (u32 i = (u32)0; i < liveIns.count(); i = i + (u32)1)
            {
            String* t = ((IRValue*)liveIns.get(i)).ty();
            if (!t.hasPrefix(String.withCString("Ptr(")))
                continue;
            u32 comma = t.indexOfByte((u8)',');
            u32 es = comma == (u32)$FFFFFFFF ? (u32)0 : self.irWidth(t.substringBytes((u32)4, comma - (u32)4));
            if (es == (u32)0)
                continue;
            if (rec == (IRValue*)0)
                {
                IRValue* cb = ppCall(b, String.withCString("ParFnChunk$ctx"), u8p, IROperand.useVal(sv), (IROperand*)0, (IROperand*)0, mm);
                mm = _ppLastMem;
                rec = ppEmit(b, String.withCString("Bitcast"), recT, IROperand.useVal(cb), (IROperand*)0, (IROperand*)0);
                }
            IRValue* p = ppFieldLoad(b, rec, (u32)3 + i, t, mm);
            mm = _ppLastMem;
            IRValue* pv = ppEmit(b, String.withCString("Bitcast"), String.withCString("Ptr(Void, unbanked)"), IROperand.useVal(p), (IROperand*)0, (IROperand*)0);
            IRValue* esv = ppEmit(b, String.withCString("Const"), i64t, IROperand.immI((i64)es, i64t), (IROperand*)0, (IROperand*)0);
            IRValue* no = ppEmit(b, String.withCString("Const"), String.withCString("Bool"), IROperand.immI((i64)0, String.withCString("Bool")), (IROperand*)0, (IROperand*)0);
            IRValue* sp = ppCall(b, String.withCString("Par$spanOf"), i64t, IROperand.useVal(pv), IROperand.useVal(esv), IROperand.useVal(no), mm);
            mm = _ppLastMem;
            IRValue* fk = ppEmit(b, String.withCString("Const"), String.withCString("I32"), IROperand.immI((i64)((u32)3 + i), String.withCString("I32")), (IROperand*)0, (IROperand*)0);
            IRValue* is = ppCmp(b, String.withCString("EQ"), k, fk);
            acc = ppEmit(b, String.withCString("Select"), i64t, IROperand.useVal(is), IROperand.useVal(sp), IROperand.useVal(acc));
            }
        IRInsn* r = IRInsn.with(String.withCString("Return"));
        r.add(IROperand.useVal(acc));
        r.add(IROperand.useVal(mm));
        b.setTerm(r);
        F.addBlock(b);
        m.addFunc(F);
        m.addSym(IRSymbol.func(F.name(), String.withFormat("(%s, I32) -> I64", objT.cString()), false, false));
        return F.name();
        }

    // A reduction's operator as the parser's placeholder words spell it.
    static String* ppRedWord(String* op)
        {
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("FAdd")))
            return String.withCString("+");
        if (op.equals(String.withCString("Mul")) || op.equals(String.withCString("FMul")))
            return String.withCString("*");
        if (op.equals(String.withCString("Xor")))
            return String.withCString("^");
        if (op.equals(String.withCString("Or")))
            return String.withCString("|");
        if (op.equals(String.withCString("And")))
            return String.withCString("&");
        if (op.hasPrefix(String.withCString("Min:")))
            return String.withCString("min");
        return String.withCString("max");
        }

    // The operators an accumulator may be updated by: associative and
    // commutative, so partial results fold in any order (FAdd and FMul only
    // reach here under :goal(speed), which Propose's verdict checks).
    static bool ppRedOp(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("FAdd"))
            || op.equals(String.withCString("Mul")) || op.equals(String.withCString("FMul"))
            || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("And"));
        }

    // ── IR outlining, stage 3: a block the par runtime runs ─────────────────
    // The loop becomes ParOut$<n>$body(self, ctx, lo, hi), a method of a class
    // that is ParFnChunk with its own vtable (Par.xc): the captured values
    // and the reductions' accumulators are a byte record (ctx), resetCtx sets
    // a copy's accumulators to their identities and mergeCtx folds one
    // record's into another's. The call site makes the chunk, fills the record,
    // and calls Par.run over the loop's range. Taken only where that is
    // plainly right, on a 64-bit target with the runtime in the program:
    //   * the induction variable steps by 1 from a value set before the loop,
    //     and the exit test is i < b or i <= b with b from outside the loop;
    //   * every other carried value is an accumulator updated by +, and only
    //     accumulators (no induction variable) are read after the loop;
    //   * every store is to element [i] of an array from outside the loop, and
    //     an array that is stored to is read only at [i];
    //   * no calls, and two arrays the loop touches are either the same value
    //     or two different globals (pointers that may overlap need a check at
    //     run time, which is the next piece).
    // Anything else stays the serial outline (stages 1-2).
    // A function symbol's return type: what follows `-> ` in its signature,
    // or 0.
    static String* ppSigRet(IRSymbol* s)
        {
        if (s == (IRSymbol*)0 || s.signature() == (String*)0)
            return (String*)0;
        String* g = s.signature();
        u32 at = g.byteIndexOf(String.withCString("-> "));
        if (at == String.notFound())
            return (String*)0;
        return g.substringFromByte(at + (u32)3).trimmed();
        }

    // The product of the trips of the loops inside a loop's body (each inner
    // header: a block past H with phis, ending in a counted test against a
    // constant from a constant start, by one), or -1 when one is not known.
    // Sibling inner loops multiply too, which only overstates the work, and
    // the product stops growing at PP_MIN_TRIP.
    final i64 ppInnerTrips(Array* body, IRBlock* H, Map* defOf)
        {
        i64 work = (i64)1;
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* ib = (IRBlock*)body.get(b);
            if (ib == H || ib.phis().count() == (u32)0)
                continue;
            IRInsn* t = ib.term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)1)
                return (i64)-1;
            IROperand* c = (IROperand*)t.ops().get((u32)0);
            if (c.kind() != (u8)OPK_USE || c.val() == (IRValue*)0)
                return (i64)-1;
            IRInsn* cmp = (IRInsn*)defOf.get((Hashable*)c.val());
            if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() != (u32)2)
                return (i64)-1;
            String* pr = cmp.pred();
            bool le = pr.equals(String.withCString("SLE")) || pr.equals(String.withCString("ULE"));
            if (!le && !pr.equals(String.withCString("SLT")) && !pr.equals(String.withCString("ULT")))
                return (i64)-1;
            IROperand* c0 = (IROperand*)cmp.ops().get((u32)0);
            i64 hi = (i64)0;
            if (c0.kind() != (u8)OPK_USE || !constValue(defOf, (IROperand*)cmp.ops().get((u32)1), &hi))
                return (i64)-1;
            // The counter: a phi of this block, a constant on one edge and
            // itself plus one on the other.
            IRInsn* ph = (IRInsn*)0;
            for (u32 i = (u32)0; i < ib.phis().count(); i = i + (u32)1)
                if (((IRInsn*)ib.phis().get(i)).res() == c0.val())
                    ph = (IRInsn*)ib.phis().get(i);
            if (ph == (IRInsn*)0 || ph.ops().count() != (u32)4)
                return (i64)-1;
            i64 lo = (i64)0;
            bool haveLo = false;
            bool stepOne = false;
            for (u32 q = (u32)1; q < (u32)4; q = q + (u32)2)
                {
                IROperand* o = (IROperand*)ph.ops().get(q);
                i64 k = (i64)0;
                if (constValue(defOf, o, &k))
                    {
                    lo = k;
                    haveLo = true;
                    continue;
                    }
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    return (i64)-1;
                IRInsn* st = (IRInsn*)defOf.get((Hashable*)o.val());
                if (st == (IRInsn*)0 || !st.op().equals(String.withCString("Add")) || st.ops().count() != (u32)2)
                    return (i64)-1;
                IROperand* s0 = (IROperand*)st.ops().get((u32)0);
                IROperand* s1 = (IROperand*)st.ops().get((u32)1);
                i64 one = (i64)0;
                if ((s0.kind() == (u8)OPK_USE && s0.val() == ph.res() && constValue(defOf, s1, &one) && one == (i64)1)
                    || (s1.kind() == (u8)OPK_USE && s1.val() == ph.res() && constValue(defOf, s0, &one) && one == (i64)1))
                    stepOne = true;
                }
            if (!haveLo || !stepOne)
                return (i64)-1;
            i64 trip = hi + (le ? (i64)1 : (i64)0) - lo;
            if (trip < (i64)0)
                trip = (i64)0;
            work = work * trip;
            if (work >= (i64)PP_MIN_TRIP)
                return (i64)PP_MIN_TRIP;
            }
        return work;
        }

    final bool ppOutlinePar(IRModule* m, IRFunc* fn, LRCLoop* L, IRInsn* at, IRBlock* E,
                      Array* liveIns, IRValue* memIn, IRValue* memLast, Array* liveOuts)
        {
        if (_profile == (OptProfile*)0 || !_profile.ptr64())
            return ppNo("ppOutlinePar 1");
        // The runtime in the program, or its declarations from libRuntime
        // (2026-11-03): a method of an imported class is a symbol with its
        // signature, not a function with a body; its return type is the
        // signature's.
        IRFunc* makeF = self.funcNamed(m, String.withCString("ParFnChunk$make"));
        IRSymbol* baseVt = self.symNamed(m, String.withCString("ParFnChunk$vtbl"));
        String* makeRet = makeF != (IRFunc*)0 ? makeF.ret() : ppSigRet(self.symNamed(m, String.withCString("ParFnChunk$make")));
        if (makeRet == (String*)0)
            return ppNo("no ParFnChunk.make");
        if (funcNamed(m, String.withCString("ParFnChunk$runOn")) == (IRFunc*)0
            && symNamed(m, String.withCString("ParFnChunk$runOn")) == (IRSymbol*)0)
            return ppNo("no ParFnChunk.runOn");
        if (funcNamed(m, String.withCString("ParFnChunk$ctx")) == (IRFunc*)0
            && symNamed(m, String.withCString("ParFnChunk$ctx")) == (IRSymbol*)0)
            return ppNo("no ParFnChunk.ctx");
        if (baseVt == (IRSymbol*)0 || baseVt.slots() == 0)
            return ppNo("no ParFnChunk vtable");
        // The three per-block methods are in the vtable (ParFnChunkBase).
        u32 have = (u32)0;
        for (u32 k = (u32)0; k < baseVt.slots().count(); k = k + (u32)1)
            {
            String* s = (String*)baseVt.slots().get(k);
            if (s.equals(String.withCString("ParFnChunk$body")) || s.equals(String.withCString("ParFnChunk$resetCtx"))
                || s.equals(String.withCString("ParFnChunk$mergeCtx")))
                have = have + (u32)1;
            }
        if (have != (u32)3)
            return ppNo("ParFnChunk's vtable lacks body, resetCtx or mergeCtx");
        IRBlock* P = L.pre();
        IRBlock* H = L.header();
        Array* body = L.body();
        Map* defOf = self.defMapAll(fn);
        Map* defBlk = self.defBlockMap(fn);
        // The exit test.
        IRInsn* t = H.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3)
            return ppNo("ppOutlinePar 3");
        IROperand* onTrue = (IROperand*)t.ops().get((u32)1);
        IROperand* onFalse = (IROperand*)t.ops().get((u32)2);
        if (onTrue.kind() != (u8)OPK_BLOCK || !self.hasBlock(body, onTrue.blk())
            || onFalse.kind() != (u8)OPK_BLOCK || onFalse.blk() != E)
            return ppNo("ppOutlinePar 4");
        IRInsn* cmp = (IRInsn*)defOf.get((Hashable*)((IROperand*)t.ops().get((u32)0)).val());
        if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() != (u32)2)
            return ppNo("ppOutlinePar 5");
        String* pred = cmp.pred();
        bool le = pred.equals(String.withCString("SLE")) || pred.equals(String.withCString("ULE"));
        if (!le && !pred.equals(String.withCString("SLT")) && !pred.equals(String.withCString("ULT")))
            return ppNo("ppOutlinePar 6");
        IROperand* c0 = (IROperand*)cmp.ops().get((u32)0);
        IROperand* c1 = (IROperand*)cmp.ops().get((u32)1);
        if (c0.kind() != (u8)OPK_USE || c1.kind() != (u8)OPK_USE)
            return ppNo("ppOutlinePar 7");
        // The induction variable and the accumulators.
        IRInsn* iv = (IRInsn*)0;
        Array* reds = new Array();      // the accumulator phis
        Array* redOps = new Array();    // String@: Add, FAdd, Mul, FMul, Xor, Or, And, or Min:/Max: S, U or F
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == (IRValue*)0 || ppIsMem(phi.res()))
                continue;
            if (phi.ops().count() != (u32)4)
                return ppNo("ppOutlinePar 8");
            IRValue* nx = ppPhiIn(phi, L, true);
            IRInsn* step = nx != (IRValue*)0 ? (IRInsn*)defOf.get((Hashable*)nx) : (IRInsn*)0;
            // A running minimum or maximum, if-converted to a Select.
            String* mm = step != (IRInsn*)0 ? ppMinMaxOf(step, phi.res(), defOf) : (String*)0;
            if (mm != (String*)0)
                {
                reds.add((Object*)phi);
                redOps.add((Object*)mm);
                continue;
                }
            // A conditional update, `if (c) acc = acc op x` if-converted to
            // Select(c, acc op x, acc): each chunk folds its own, from the
            // identity, and the partials fold as any of op's.
            String* co = step != (IRInsn*)0 ? ppCondUpdateOf(step, phi.res(), defOf) : (String*)0;
            if (co != (String*)0)
                {
                reds.add((Object*)phi);
                redOps.add((Object*)co);
                continue;
                }
            // Carried through an inner loop (`for i: for j: t += x`): the next
            // value is the inner header's phi, which starts from this one and
            // steps by an operator a reduction may use.
            String* nest = step != (IRInsn*)0 ? ppNestedRedOf(fn, L, step, phi.res(), defOf) : (String*)0;
            if (nest != (String*)0)
                {
                reds.add((Object*)phi);
                redOps.add((Object*)nest);
                continue;
                }
            if (step == (IRInsn*)0 || step.ops().count() != (u32)2)
                return ppNo("ppOutlinePar 9");
            bool addI = step.op().equals(String.withCString("Add"));
            if (!addI && !ppRedOp(step.op()))
                return ppNo("ppOutlinePar 10");
            IROperand* s0 = (IROperand*)step.ops().get((u32)0);
            IROperand* s1 = (IROperand*)step.ops().get((u32)1);
            IROperand* other = (IROperand*)0;
            if (s0.kind() == (u8)OPK_USE && s0.val() == phi.res())
                other = s1;
            else if (s1.kind() == (u8)OPK_USE && s1.val() == phi.res())
                other = s0;
            // A tree of the one operator, the accumulator once among its
            // leaves (`t = t + x1 + x2 + x3`): a reduction by it.
            if (other == (IROperand*)0 && ppAssocChainOf(step, phi.res(), defOf))
                {
                reds.add((Object*)phi);
                redOps.add((Object*)step.op());
                continue;
                }
            if (other == (IROperand*)0)
                return ppNo("ppOutlinePar 11");
            if (iv == (IRInsn*)0 && addI && c0.val() == phi.res() && ppConstOne(other, defOf))
                {
                iv = phi;
                continue;
                }
            if (other.kind() == (u8)OPK_USE && ppDependsOn(other.val(), phi.res(), defOf, (u32)0))
                return ppNo("ppOutlinePar 12");
            reds.add((Object*)phi);
            redOps.add((Object*)step.op());
            }
        if (iv == (IRInsn*)0 || !ppIntType(iv.res().ty()))
            return ppNo("ppOutlinePar 13");
        // The bound is from outside the loop, or constants the loop recomputes
        // (a `#define` bound, widened in the header), which the call site
        // computes again.
        IRValue* bound = c1.val();
        IRBlock* bb = (IRBlock*)defBlk.get((Hashable*)bound);
        bool remat = bb != (IRBlock*)0 && self.hasBlock(body, bb);
        if (remat && !ppConstChain(bound, defOf, (u32)0))
            return ppNo("ppOutlinePar 14");
        // An innermost loop of a few items known here (a 3x3 stencil's row) is no block:
        // a block costs a launch, which a GPU pays per run of the outer loop.
        IRValue* start = ppPhiIn(iv, L, false);
        i64 klo = (i64)0;
        i64 khi = (i64)0;
        // Innermost only: a short loop around inner loops (gemm's rows) is
        // work enough. An inner loop shows as phis in a block past the header.
        bool innermost = true;
        for (u32 b = (u32)0; b < body.count() && innermost; b = b + (u32)1)
            if ((IRBlock*)body.get(b) != H && ((IRBlock*)body.get(b)).phis().count() > (u32)0)
                innermost = false;
        // A nest of such loops (a 3x3 stencil: dy around dx) is judged by its
        // whole work: the product of the trips, when every inner loop's is
        // known too. An inner trip not known here (gemm's columns) leaves the
        // nest a block.
        if (start != (IRValue*)0 && constValue(defOf, IROperand.useVal(start), &klo) && constValue(defOf, c1, &khi))
            {
            i64 work = khi + (le ? (i64)1 : (i64)0) - klo;
            if (!innermost)
                {
                i64 inner = ppInnerTrips(body, H, defOf);
                work = inner < (i64)0 ? (i64)PP_MIN_TRIP : work * inner;
                }
            if (work < (i64)PP_MIN_TRIP)
                {
                _ppStayPut = true;
                return ppNo("a constant trip below PP_MIN_TRIP items");
                }
            }
        // Only accumulators are read after the loop.
        for (u32 i = (u32)0; i < liveOuts.count(); i = i + (u32)1)
            {
            bool isRed = false;
            for (u32 r = (u32)0; r < reds.count() && !isRed; r = r + (u32)1)
                isRed = ((IRInsn*)reds.get(r)).res() == (IRValue*)liveOuts.get(i);
            if (!isRed)
                return ppNo("ppOutlinePar 15");
            }
        // The memory: stores to [i] only, a stored array read only at [i].
        if (!ppParMemoryOk(fn, L, iv.res(), defOf, defBlk))
            return ppNo("ppOutlinePar 16");

        // The captures: the live-ins the body reads, less those only the
        // counter's start and the exit test read (lo and hi stand for them).
        Array* ins = new Array();
        for (u32 i = (u32)0; i < liveIns.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)liveIns.get(i);
            bool used = false;
            for (u32 bb2 = (u32)0; bb2 < body.count() && !used; bb2 = bb2 + (u32)1)
                {
                Array* all = ppAllInsns((IRBlock*)body.get(bb2));
                for (u32 q = (u32)0; q < all.count() && !used; q = q + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)all.get(q);
                    for (u32 k = (u32)0; k < n.ops().count() && !used; k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)n.ops().get(k);
                        if (o.kind() != (u8)OPK_USE || o.val() != v)
                            continue;
                        if (n == cmp && k == (u32)1)
                            continue;
                        // The counter's start and an accumulator's: lo, and
                        // the accumulator's own slot, carry them.
                        if ((n == iv || reds.indexOf((Object*)n) != (u32)$FFFFFFFF) && k > (u32)0
                            && ((IROperand*)n.ops().get(k - (u32)1)).kind() == (u8)OPK_BLOCK
                            && ((IROperand*)n.ops().get(k - (u32)1)).blk() == P)
                            continue;
                        used = true;
                        }
                    }
                }
            if (used)
                ins.add((Object*)v);
            }
        liveIns = ins;
        // An untyped pointer (the C path's `ptr`) that the loop only ever
        // casts to one element type is captured as that type, cast once at
        // the call: a kernel cannot cast a device pointer, and the loop then
        // reads it as a typed pointer, as xc's own do.
        Map* castTo = new Map();       // a cast's result in the loop -> the live-in index it stands for
        for (u32 i = (u32)0; i < liveIns.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)liveIns.get(i);
            if (!v.ty().equals(String.withCString("Ptr(U8, unbanked)")))
                continue;
            String* tt = (String*)0;
            bool ok = true;
            Array* casts = new Array();
            for (u32 bb2 = (u32)0; bb2 < body.count() && ok; bb2 = bb2 + (u32)1)
                {
                Array* all = ppAllInsns((IRBlock*)body.get(bb2));
                for (u32 q = (u32)0; q < all.count() && ok; q = q + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)all.get(q);
                    for (u32 k = (u32)0; k < n.ops().count() && ok; k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)n.ops().get(k);
                        if (o.kind() != (u8)OPK_USE || o.val() != v)
                            continue;
                        if (!n.op().equals(String.withCString("Bitcast")) || n.res() == (IRValue*)0
                            || !n.res().ty().hasPrefix(String.withCString("Ptr(")))
                            ok = false;
                        else if (tt == (String*)0)
                            tt = n.res().ty();
                        else if (!tt.equals(n.res().ty()))
                            ok = false;
                        if (ok)
                            casts.add((Object*)n);
                        }
                    }
                }
            if (!ok || tt == (String*)0)
                continue;
            IRValue* vt = ppEmit(P, String.withCString("Bitcast"), tt, IROperand.useVal(v), (IROperand*)0, (IROperand*)0);
            liveIns.set(i, (Object*)vt);
            for (u32 c = (u32)0; c < casts.count(); c = c + (u32)1)
                castTo.set((Hashable*)((IRInsn*)casts.get(c)).res(), (Object*)Number.with(i));
            }
        // ── the record: ParChunk's prefix (a word, lo, hi), then the live-ins,
        // then the accumulators, 8 bytes each. A struct of its own, read
        // with FieldAddr, so that the loop's function has the shape of a
        // generated block's run(): what the kernel printers read.
        u32 nIn = liveIns.count();
        u32 bytes = (u32)24 + (nIn + reds.count()) * (u32)8;
        IRLayout* recL = IRLayout.with(bytes, (u32)8);
        recL.addField((u32)0, String.withCString("Ptr(Void, unbanked)"));
        recL.addField((u32)8, String.withCString("I64"));
        recL.addField((u32)16, String.withCString("I64"));
        for (u32 i = (u32)0; i < nIn; i = i + (u32)1)
            recL.addField((u32)24 + i * (u32)8, ((IRValue*)liveIns.get(i)).ty());
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            recL.addField((u32)24 + (nIn + i) * (u32)8, ((IRInsn*)reds.get(i)).res().ty());
        String* recT = String.withFormat("Ptr(Agg(%u), unbanked)", m.addLayout(recL));
        _ppOutN = _ppOutN + (u32)1;
        String* stem = String.withFormat("ParOut$%u", _ppOutN);
        String* objT = makeRet;
        String* u8p = String.withCString("Ptr(U8, unbanked)");
        String* ivT = iv.res().ty();

        // ── run(rec): the loop over [rec.lo, rec.hi) ──
        IRFunc* B = new IRFunc();
        // ParImpl$o<n>$run: the name the kernel printers find a block by.
        String* pcls = String.withFormat("ParImpl$o%u", _ppOutN);
        B.setName(String.withFormat("%s$run", pcls.cString()));
        if (fn.hasDbg())
            B.setDbg(fn.dbgFile(), fn.dbgLine(), fn.dbgCol());
        IRValue* bRec = new IRValue(recT);
        IRValue* bMem = new IRValue(String.withCString("Mem"));
        B.addParam(bRec);
        B.addParam(bMem);
        IRBlock* entry = new IRBlock(String.withCString("bb_entry"));
        Map* remap = new Map();
        IRValue* mcur = bMem;
        // hi, then the captures and accumulators, then lo, each narrowed as
        // it is read: the order a generated block's run reads them in.
        IRValue* bHi = ppFieldLoad(entry, bRec, (u32)2, String.withCString("I64"), mcur);
        mcur = _ppLastMem;
        IRValue* hiT = ppConvertTo(entry, bHi, ivT);
        // The chunk's end is never past the loop's own bound, so where that
        // bound is a constant N below 2^31 and the test unsigned, the end is
        // clamped to it: free at run time, and it proves the iv inside
        // [0, N), so `a[zext i]` narrows to the iv-indexed form the escape-time
        // vectoriser takes (bounds-elide's wide-index narrowing). C nbody's
        // outlined block stayed scalar without it: 95 ms on one thread
        // against the plain build's 6.0 (2026-10-25).
        i32 boundN = (i32)0;
        bool unsignedTest = pred.equals(String.withCString("ULT")) || pred.equals(String.withCString("ULE"));
        if (unsignedTest && (ivT.equals(String.withCString("I32")) || ivT.equals(String.withCString("U32")))
            && self.vecConst((IROperand*)cmp.ops().get((u32)1), defOf, &boundN) && boundN > (i32)0
            && (le ? boundN < (i32)$7FFFFFFF : true))
            {
            i32 cap = le ? boundN + (i32)1 : boundN;
            IRInsn* lt = IRInsn.with(String.withCString("ICmp"));
            lt.setRes(new IRValue(String.withCString("Bool")));
            lt.setPred(String.withCString("ULT"));
            lt.add(IROperand.useVal(hiT));
            lt.add(IROperand.immI((i64)cap, ivT));
            entry.add(lt);
            IRInsn* sel = IRInsn.with(String.withCString("Select"));
            sel.setRes(new IRValue(ivT));
            sel.add(IROperand.useVal(lt.res()));
            sel.add(IROperand.useVal(hiT));
            sel.add(IROperand.immI((i64)cap, ivT));
            entry.add(sel);
            hiT = sel.res();
            }
        for (u32 i = (u32)0; i < nIn; i = i + (u32)1)
            {
            IRValue* v = (IRValue*)liveIns.get(i);
            IRValue* ld = ppFieldLoad(entry, bRec, (u32)3 + i, v.ty(), mcur);
            mcur = _ppLastMem;
            remap.set((Hashable*)v, (Object*)IROperand.useVal(ld));
            }
        // The casts the typed captures stand for read the capture.
        Array* castKeys = castTo.allKeys();
        for (u32 c = (u32)0; c < castKeys.count(); c = c + (u32)1)
            {
            IRValue* cr = (IRValue*)castKeys.get(c);
            u32 li = ((Number*)castTo.get((Hashable*)cr)).asU32();
            remap.set((Hashable*)cr, remap.get((Hashable*)liveIns.get(li)));
            }
        Array* redInit = new Array();
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            {
            IRInsn* r = (IRInsn*)reds.get(i);
            redInit.add((Object*)ppFieldLoad(entry, bRec, (u32)3 + nIn + i, r.res().ty(), mcur));
            mcur = _ppLastMem;
            }
        IRValue* bLo = ppFieldLoad(entry, bRec, (u32)1, String.withCString("I64"), mcur);
        mcur = _ppLastMem;
        remap.set((Hashable*)memIn, (Object*)IROperand.useVal(mcur));
        IRValue* loT = ppConvertTo(entry, bLo, ivT);
        Map* blockMap = new Map();
        IRBlock* exitB = new IRBlock(String.withCString("bb_out_exit"));
        blockMap.set((Hashable*)E, (Object*)exitB);
        Array* ordered = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)fn.blocks().get(b);
            if (!self.hasBlock(body, ob))
                continue;
            ordered.add((Object*)ob);
            blockMap.set((Hashable*)ob, (Object*)new IRBlock(ob.name()));
            Array* all = ppAllInsns(ob);
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                if (n.res() != (IRValue*)0 && castTo.get((Hashable*)n.res()) != (Object*)0)
                    continue;
                if (n.res() != (IRValue*)0)
                    remap.set((Hashable*)n.res(), (Object*)IROperand.useVal(new IRValue(n.res().ty())));
                if (n.memRes() != (IRValue*)0)
                    remap.set((Hashable*)n.memRes(), (Object*)IROperand.useVal(new IRValue(n.memRes().ty())));
                }
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block((IRBlock*)blockMap.get((Hashable*)H)));
        entry.setTerm(br);
        B.addBlock(entry);
        for (u32 b = (u32)0; b < ordered.count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)ordered.get(b);
            IRBlock* nb = (IRBlock*)blockMap.get((Hashable*)ob);
            for (u32 i = (u32)0; i < ob.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)ob.phis().get(i);
                IRInsn* c = self.cloneInsn(remap, blockMap, phi);
                // The edge from the preheader: from the entry, with the chunk's
                // start for the induction variable and the record's value for
                // an accumulator.
                IRValue* first = (IRValue*)0;
                if (phi == iv)
                    first = loT;
                else if (reds.indexOf((Object*)phi) != (u32)$FFFFFFFF)
                    first = (IRValue*)redInit.get(reds.indexOf((Object*)phi));
                for (u32 k = (u32)0; k + (u32)1 < c.ops().count(); k = k + (u32)2)
                    {
                    IROperand* o = (IROperand*)c.ops().get(k);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == P)
                        {
                        c.ops().set(k, (Object*)IROperand.block(entry));
                        if (first != (IRValue*)0)
                            c.ops().set(k + (u32)1, (Object*)IROperand.useVal(first));
                        }
                    }
                nb.addPhi(c);
                }
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)ob.insns().get(i);
                if (n.res() != (IRValue*)0 && castTo.get((Hashable*)n.res()) != (Object*)0)
                    continue;
                IRInsn* c = self.cloneInsn(remap, blockMap, n);
                // The exit test against the chunk's end, always `<`.
                if (n == cmp)
                    {
                    c.ops().set((u32)1, (Object*)IROperand.useVal(hiT));
                    if (le)
                        c.setPred(pred.equals(String.withCString("SLE")) ? String.withCString("SLT") : String.withCString("ULT"));
                    }
                nb.add(c);
                }
            nb.setTerm(self.cloneInsn(remap, blockMap, ob.term()));
            B.addBlock(nb);
            }
        // At the exit, the accumulators back into the record.
        IRValue* mx = memLast != (IRValue*)0 ? self.remappedValue(remap, memLast) : mcur;
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            {
            IRInsn* r = (IRInsn*)reds.get(i);
            mx = ppFieldStore(exitB, bRec, (u32)3 + nIn + i, self.remappedValue(remap, r.res()), mx);
            }
        IRInsn* ret = IRInsn.with(String.withCString("Return"));
        ret.add(IROperand.useVal(mx));
        exitB.setTerm(ret);
        B.addBlock(exitB);

        // ── body(self, ctx, lo, hi): the chunk's range into its record, and run ──
        IRFunc* W = new IRFunc();
        W.setName(String.withFormat("%s$body", stem.cString()));
        IRValue* wSelf = new IRValue(objT);
        IRValue* wCtx = new IRValue(u8p);
        IRValue* wLo = new IRValue(String.withCString("I64"));
        IRValue* wHi = new IRValue(String.withCString("I64"));
        IRValue* wMem = new IRValue(String.withCString("Mem"));
        W.addParam(wSelf);
        W.addParam(wCtx);
        W.addParam(wLo);
        W.addParam(wHi);
        W.addParam(wMem);
        IRBlock* wb = new IRBlock(String.withCString("bb_entry"));
        IRValue* wRec = ppEmit(wb, String.withCString("Bitcast"), recT, IROperand.useVal(wCtx), (IROperand*)0, (IROperand*)0);
        IRValue* wm = ppFieldStore(wb, wRec, (u32)1, wLo, wMem);
        wm = ppFieldStore(wb, wRec, (u32)2, wHi, wm);
        IRInsn* wc = IRInsn.with(String.withCString("Call"));
        wc.setCc(String.withCString("CallConv::Standard"));
        wc.add(IROperand.sym(B.name()));
        wc.add(IROperand.useVal(wRec));
        wc.add(IROperand.useVal(wm));
        wm = new IRValue(String.withCString("Mem"));
        wc.setMemRes(wm);
        wb.add(wc);
        IRInsn* wr = IRInsn.with(String.withCString("Return"));
        wr.add(IROperand.useVal(wm));
        wb.setTerm(wr);
        W.addBlock(wb);

        // ── resetCtx(self, ctx) and mergeCtx(self, into, from) ──
        IRFunc* R = new IRFunc();
        R.setName(String.withFormat("%s$resetCtx", stem.cString()));
        IRValue* rSelf = new IRValue(objT);
        IRValue* rCtx = new IRValue(u8p);
        IRValue* rMem = new IRValue(String.withCString("Mem"));
        R.addParam(rSelf);
        R.addParam(rCtx);
        R.addParam(rMem);
        IRBlock* rb = new IRBlock(String.withCString("bb_entry"));
        IRValue* rm = rMem;
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            {
            String* ty = ((IRInsn*)reds.get(i)).res().ty();
            IRValue* z = ppIdentity(rb, ty, (String*)redOps.get(i));
            rm = ppCtxStore(rb, rCtx, (u32)24 + (nIn + i) * (u32)8, z, rm);
            }
        IRInsn* rr = IRInsn.with(String.withCString("Return"));
        rr.add(IROperand.useVal(rm));
        rb.setTerm(rr);
        R.addBlock(rb);
        IRFunc* G = new IRFunc();
        G.setName(String.withFormat("%s$mergeCtx", stem.cString()));
        IRValue* gSelf = new IRValue(objT);
        IRValue* gInto = new IRValue(u8p);
        IRValue* gFrom = new IRValue(u8p);
        IRValue* gMem = new IRValue(String.withCString("Mem"));
        G.addParam(gSelf);
        G.addParam(gInto);
        G.addParam(gFrom);
        G.addParam(gMem);
        IRBlock* gb = new IRBlock(String.withCString("bb_entry"));
        IRValue* gm = gMem;
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            {
            String* ty = ((IRInsn*)reds.get(i)).res().ty();
            u32 off = (u32)24 + (nIn + i) * (u32)8;
            IRValue* a = ppCtxLoad(gb, gInto, off, ty, gm);
            gm = _ppLastMem;
            IRValue* b2 = ppCtxLoad(gb, gFrom, off, ty, gm);
            gm = _ppLastMem;
            String* rop = (String*)redOps.get(i);
            IRValue* sum = (IRValue*)0;
            if (rop.hasPrefix(String.withCString("Min:")) || rop.hasPrefix(String.withCString("Max:")))
                {
                // The other's when it is smaller (min) or larger (max).
                bool isMax = rop.hasPrefix(String.withCString("Max:"));
                u8 kind = rop.byteAt((u32)4);
                IRInsn* c = IRInsn.with(String.withCString(kind == (u8)'F' ? "FCmp" : "ICmp"));
                IRValue* cv = new IRValue(String.withCString("Bool"));
                c.setRes(cv);
                c.setPred(String.withCString(kind == (u8)'F' ? (isMax ? "OGT" : "OLT")
                                             : kind == (u8)'U' ? (isMax ? "UGT" : "ULT")
                                             : (isMax ? "SGT" : "SLT")));
                c.add(IROperand.useVal(b2));
                c.add(IROperand.useVal(a));
                gb.add(c);
                sum = ppEmit(gb, String.withCString("Select"), ty, IROperand.useVal(cv), IROperand.useVal(b2), IROperand.useVal(a));
                }
            else
                {
                sum = new IRValue(ty);
                IRInsn* add = IRInsn.with(rop);
                add.setRes(sum);
                add.add(IROperand.useVal(a));
                add.add(IROperand.useVal(b2));
                gb.add(add);
                }
            gm = ppCtxStore(gb, gInto, off, sum, gm);
            }
        IRInsn* gr = IRInsn.with(String.withCString("Return"));
        gr.add(IROperand.useVal(gm));
        gb.setTerm(gr);
        G.addBlock(gb);

        // gpuSource(): the placeholder the printers fill: the tag, `auto;`,
        // and each reduction as `<field>=<op>;`, as the parser writes them.
        String* tagText = String.withFormat("__XC_PAR_FAST_o%u__auto;", _ppOutN);
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            tagText.append(String.withFormat("%u=%s;", (u32)3 + nIn + i, ppRedWord((String*)redOps.get(i)).cString()));
        Array* tagBytes = new Array();
        for (u32 i = (u32)0; i < tagText.byteLength(); i = i + (u32)1)
            tagBytes.add((Object*)Number.with((u32)tagText.byteAt(i)));
        tagBytes.add((Object*)Number.with((u32)0));
        String* srcSym = String.withFormat("%s$src", stem.cString());
        m.addSym(IRSymbol.stringLit(srcSym, tagBytes));
        IRFunc* S = new IRFunc();
        S.setName(String.withFormat("%s$gpuSource", stem.cString()));
        S.setRet(u8p);
        IRValue* sSelf = new IRValue(objT);
        IRValue* sMem = new IRValue(String.withCString("Mem"));
        S.addParam(sSelf);
        S.addParam(sMem);
        IRBlock* sb = new IRBlock(String.withCString("bb_entry"));
        IRValue* sp = ppEmit(sb, String.withCString("AddrOf"), u8p, IROperand.sym(srcSym), (IROperand*)0, (IROperand*)0);
        IRInsn* sr = IRInsn.with(String.withCString("Return"));
        sr.add(IROperand.useVal(sp));
        sr.add(IROperand.useVal(sMem));
        sb.setTerm(sr);
        S.addBlock(sb);
        m.addFunc(S);
        m.addSym(IRSymbol.func(S.name(), String.withFormat("(%s) -> %s", objT.cString(), u8p.cString()), false, false));
        // gpuGlobal / gpuGlobalBytes (the globals the loop names) and
        // gpuLength (the bytes behind each pointer capture): what a GPU binds.
        String* gName = ppGpuGlobals(m, stem, objT, B, true);
        String* gbName = ppGpuGlobals(m, stem, objT, B, false);
        String* glName = ppGpuLength(m, stem, objT, recT, liveIns);
        Array* ftys = new Array();
        for (u32 i = (u32)0; i < nIn; i = i + (u32)1)
            ftys.add((Object*)((IRValue*)liveIns.get(i)).ty());
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            ftys.add((Object*)((IRInsn*)reds.get(i)).res().ty());
        _ppMade.add((Object*)ParOutBlock.with(pcls, ftys));
        // ── the class: ParFnChunk's vtable with the three replaced (they are
        // dispatched: Par.xc's ParFnChunkBase overrides them too) ──
        Array* slots = new Array();
        for (u32 k = (u32)0; k < baseVt.slots().count(); k = k + (u32)1)
            {
            String* s = (String*)baseVt.slots().get(k);
            if (k == (u32)0)
                s = String.withCString("ParFnChunk$vtbl");
            else if (s.equals(String.withCString("ParFnChunk$body")))
                s = W.name();
            else if (s.equals(String.withCString("ParFnChunk$resetCtx")))
                s = R.name();
            else if (s.equals(String.withCString("ParFnChunk$mergeCtx")))
                s = G.name();
            else if (s.equals(String.withCString("ParChunk$gpuSource")) || s.equals(String.withCString("ParFnChunk$gpuSource")))
                s = S.name();
            else if (s.equals(String.withCString("ParChunk$gpuGlobal")))
                s = gName;
            else if (s.equals(String.withCString("ParChunk$gpuGlobalBytes")))
                s = gbName;
            else if (s.equals(String.withCString("ParChunk$gpuLength")))
                s = glName;
            slots.add((Object*)s);
            }
        String* vtName = String.withFormat("%s$vtbl", stem.cString());
        m.addSym(IRSymbol.vtable(vtName, slots));
        m.addFunc(B);
        m.addSym(IRSymbol.func(B.name(), String.withFormat("(%s) -> Void", recT.cString()), false, false));
        m.addFunc(W);
        m.addSym(IRSymbol.func(W.name(), String.withFormat("(%s, %s, I64, I64) -> Void", objT.cString(), u8p.cString()), false, false));
        m.addFunc(R);
        m.addSym(IRSymbol.func(R.name(), String.withFormat("(%s, %s) -> Void", objT.cString(), u8p.cString()), false, false));
        m.addFunc(G);
        m.addSym(IRSymbol.func(G.name(), String.withFormat("(%s, %s, %s) -> Void", objT.cString(), u8p.cString(), u8p.cString()), false, false));
        // The block's name, as the learned device choices key it: file:line.
        String* label = fn.name();
        if (at != (IRInsn*)0)
            {
            String* path = (String*)IRDbg.files().get(at.dbgFile());
            if (path != (String*)0)
                label = String.withFormat("%s:%ld", path.lastPathComponent().cString(), (i32)at.dbgLine());
            }
        // The runtime keeps each block's device choice and measurements by
        // this name: a second block from the same line (a macro, a nest on
        // one line) is told apart.
        if (_ppLabels == (Map*)0)
            _ppLabels = new Map();
        Number* seen = (Number*)_ppLabels.get((Hashable*)label);
        u32 nth = seen != (Number*)0 ? seen.asU32() + (u32)1 : (u32)1;
        _ppLabels.set((Hashable*)String.withString(label), (Object*)Number.with(nth));
        if (nth > (u32)1)
            label = String.withFormat("%s#%u", label.cString(), nth);
        Array* nameBytes = new Array();
        for (u32 i = (u32)0; i < label.byteLength(); i = i + (u32)1)
            nameBytes.add((Object*)Number.with((u32)label.byteAt(i)));
        nameBytes.add((Object*)Number.with((u32)0));
        String* strName = String.withFormat("%s$name", stem.cString());
        m.addSym(IRSymbol.stringLit(strName, nameBytes));

        // ── the call site, in the preheader ──
        IRValue* nm = ppEmit(P, String.withCString("AddrOf"), u8p, IROperand.sym(strName), (IROperand*)0, (IROperand*)0);
        IRValue* nb2 = ppEmit(P, String.withCString("Const"), String.withCString("U32"), IROperand.immI((i64)bytes, String.withCString("U32")), (IROperand*)0, (IROperand*)0);
        IRValue* pm = memIn;
        IRValue* obj = ppCall(P, String.withCString("ParFnChunk$make"), objT, IROperand.useVal(nb2), IROperand.useVal(nm), (IROperand*)0, pm);
        pm = _ppLastMem;
        IRValue* isa = ppEmit(P, String.withCString("FieldAddr"), String.withCString("Ptr(Ptr(Void, unbanked), xt_data)"),
                              IROperand.useVal(obj), IROperand.immI((i64)0, String.withCString("U8")), (IROperand*)0);
        IRValue* vt = ppEmit(P, String.withCString("AddrOf"), String.withCString("Ptr(Void, unbanked)"), IROperand.sym(vtName), (IROperand*)0, (IROperand*)0);
        pm = ppStore(P, isa, vt, pm);
        IRValue* ctx = ppCall(P, String.withCString("ParFnChunk$ctx"), u8p, IROperand.useVal(obj), (IROperand*)0, (IROperand*)0, pm);
        pm = _ppLastMem;
        for (u32 i = (u32)0; i < nIn; i = i + (u32)1)
            pm = ppCtxStore(P, ctx, (u32)24 + i * (u32)8, (IRValue*)liveIns.get(i), pm);
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            {
            IRInsn* r = (IRInsn*)reds.get(i);
            pm = ppCtxStore(P, ctx, (u32)24 + (nIn + i) * (u32)8, ppPhiIn(r, L, false), pm);
            }
        IRValue* lo64 = ppConvertTo(P, ppPhiIn(iv, L, false), String.withCString("I64"));
        IRValue* hi64 = ppConvertTo(P, remat ? ppRemat(P, bound, defOf) : bound, String.withCString("I64"));
        if (le)
            hi64 = ppEmit(P, String.withCString("Add"), String.withCString("I64"), IROperand.useVal(hi64),
                          IROperand.immI((i64)1, String.withCString("I64")), (IROperand*)0);
        // Arrays that may be one: serial where their ranges overlap.
        IRValue* serial = ppOverlapGuard(P, lo64, hi64);
        IRInsn* runC = IRInsn.with(String.withCString("Call"));
        runC.setCc(String.withCString("CallConv::Standard"));
        if (at != (IRInsn*)0)
            runC.copyDbg(at);
        runC.add(IROperand.sym(String.withCString("ParFnChunk$runOn")));
        runC.add(IROperand.useVal(obj));
        runC.add(IROperand.useVal(lo64));
        runC.add(IROperand.useVal(hi64));
        runC.add(IROperand.useVal(serial));
        runC.add(IROperand.useVal(pm));
        pm = new IRValue(String.withCString("Mem"));
        runC.setMemRes(pm);
        P.add(runC);
        Array* results = new Array();
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            {
            IRInsn* r = (IRInsn*)reds.get(i);
            results.add((Object*)ppCtxLoad(P, ctx, (u32)24 + (nIn + i) * (u32)8, r.res().ty(), pm));
            pm = _ppLastMem;
            }
        IRInsn* rel = IRInsn.with(String.withCString("Release"));
        rel.add(IROperand.useVal(obj));
        rel.add(IROperand.useVal(pm));
        pm = new IRValue(String.withCString("Mem"));
        rel.setMemRes(pm);
        P.add(rel);
        IRInsn* jump = IRInsn.with(String.withCString("Branch"));
        jump.copyDbg(P.term());
        jump.add(IROperand.block(E));
        P.setTerm(jump);
        for (u32 i = (u32)0; i < E.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)E.phis().get(i);
            for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)phi.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && self.hasBlock(body, o.blk()))
                    phi.ops().set(k, (Object*)IROperand.block(P));
                }
            }
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
            self.rewriteUsesTo(fn, ((IRInsn*)reds.get(i)).res(), IROperand.useVal((IRValue*)results.get(i)));
        if (memLast != (IRValue*)0)
            self.rewriteUsesTo(fn, memLast, IROperand.useVal(pm));
        Array* keep = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (!self.hasBlock(body, (IRBlock*)fn.blocks().get(b)))
                keep.add(fn.blocks().get(b));
        fn.setBlocks(keep);
        return true;
        }

    // XC_PAR_OUTLINE_TRACE: say which test a loop failed (always false).
    final bool ppNo(u8* why)
        {
        if (ppEnvSet("XC_PAR_OUTLINE_TRACE"))
            Stdio.error(String.withFormat("outline: %s: not a block: %s\n", _ppWhere.cString(), why));
        return false;
        }

    // XC_PAR_OUTLINE_TRACE: say what became of a loop that was outlined.
    final void ppTrace(u8* how)
        {
        if (ppEnvSet("XC_PAR_OUTLINE_TRACE"))
            Stdio.error(String.withFormat("outline: %s: outlined, %s\n", _ppWhere.cString(), how));
        }

    static bool ppIntType(String* t)
        {
        return t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
            || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"))
            || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16"));
        }

    // Whether v is made of constants alone: Const, through widenings,
    // narrowings and reinterpretations.
    final bool ppConstChain(IRValue* v, Map* defOf, u32 depth)
        {
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        if (d == (IRInsn*)0 || depth > (u32)8)
            return false;
        if (d.op().equals(String.withCString("Const")))
            return true;
        // Arithmetic on constants (`#define N (1024 * 1024)`, `D * H * W`).
        if (ppConstBinOp(d.op()) && d.ops().count() == (u32)2)
            {
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                IROperand* o = (IROperand*)d.ops().get(k);
                if (o.kind() == (u8)OPK_IMMI)
                    continue;
                if (o.kind() != (u8)OPK_USE || !ppConstChain(o.val(), defOf, depth + (u32)1))
                    return false;
                }
            return true;
            }
        if ((d.op().equals(String.withCString("ZExt")) || d.op().equals(String.withCString("SExt"))
             || d.op().equals(String.withCString("Trunc")) || d.op().equals(String.withCString("Bitcast"))) && d.ops().count() == (u32)1
            && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            return ppConstChain(((IROperand*)d.ops().get((u32)0)).val(), defOf, depth + (u32)1);
        return false;
        }

    static bool ppConstBinOp(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"))
            || op.equals(String.withCString("Mul")) || op.equals(String.withCString("Shl"))
            || op.equals(String.withCString("And")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("Xor"));
        }

    // A copy of a constant chain (ppConstChain), appended to b.
    final IRValue* ppRemat(IRBlock* b, IRValue* v, Map* defOf)
        {
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        IRInsn* c = IRInsn.with(d.op());
        IRValue* r = new IRValue(v.ty());
        c.setRes(r);
        if (d.op().equals(String.withCString("Const")))
            c.add((IROperand*)d.ops().get((u32)0));
        else
            for (u32 k = (u32)0; k < d.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)d.ops().get(k);
                c.add(o.kind() == (u8)OPK_USE ? IROperand.useVal(ppRemat(b, o.val(), defOf)) : o);
                }
        b.add(c);
        return r;
        }

    final bool ppConstOne(IROperand* o, Map* defOf)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return o.imm() == (i64)1;
        if (o.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
        // Through a widening: a range loop steps by `1` made a U8 and widened.
        while (d != (IRInsn*)0 && (d.op().equals(String.withCString("ZExt")) || d.op().equals(String.withCString("SExt"))
                                  || d.op().equals(String.withCString("Bitcast")))
               && d.ops().count() == (u32)1 && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            d = (IRInsn*)defOf.get((Hashable*)((IROperand*)d.ops().get((u32)0)).val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Const")) || d.ops().count() != (u32)1)
            return false;
        IROperand* c = (IROperand*)d.ops().get((u32)0);
        return c.kind() == (u8)OPK_IMMI && c.imm() == (i64)1;
        }

    // One instruction with a result, appended to b.
    final IRValue* ppEmit(IRBlock* b, String* op, String* ty, IROperand* a0, IROperand* a1, IROperand* a2)
        {
        IRInsn* n = IRInsn.with(op);
        IRValue* r = new IRValue(ty);
        n.setRes(r);
        if (a0 != (IROperand*)0) n.add(a0);
        if (a1 != (IROperand*)0) n.add(a1);
        if (a2 != (IROperand*)0) n.add(a2);
        b.add(n);
        return r;
        }

    final IRValue* ppStore(IRBlock* b, IRValue* addr, IRValue* v, IRValue* mem)
        {
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        st.add(IROperand.useVal(addr));
        st.add(IROperand.useVal(v));
        st.add(IROperand.useVal(mem));
        IRValue* mo = new IRValue(String.withCString("Mem"));
        st.setMemRes(mo);
        b.add(st);
        return mo;
        }

    // The run-time check for the pairs ppParMemoryOk could not tell apart:
    // true when, for some pair, the bytes the loop touches in one over
    // [lo, hi) overlap those it touches in the other — unless the two are the
    // same array of the same element, where iteration i touches element i in
    // both and nothing else. A Bool, false where there is no pair.
    final IRValue* ppOverlapGuard(IRBlock* P, IRValue* lo64, IRValue* hi64)
        {
        String* bt = String.withCString("Bool");
        IRValue* acc = ppEmit(P, String.withCString("Const"), bt, IROperand.immI((i64)0, bt), (IROperand*)0, (IROperand*)0);
        for (u32 p = (u32)0; p < _ppPairA.count(); p = p + (u32)1)
            {
            u32 a = ((Number*)_ppPairA.get(p)).asU32();
            u32 b = ((Number*)_ppPairB.get(p)).asU32();
            IRValue* aAt = ppRangeOf(P, a, lo64, hi64);
            IRValue* aLo = _ppRangeLo;
            IRValue* aHi = _ppRangeHi;
            IRValue* bAt = ppRangeOf(P, b, lo64, hi64);
            IRValue* bLo = _ppRangeLo;
            IRValue* bHi = _ppRangeHi;
            IRValue* c1 = ppCmp(P, String.withCString("ULT"), aLo, bHi);
            IRValue* c2 = ppCmp(P, String.withCString("ULT"), bLo, aHi);
            IRValue* ov = ppEmit(P, String.withCString("And"), bt, IROperand.useVal(c1), IROperand.useVal(c2), (IROperand*)0);
            // One array (the same base): safe only when both touch each
            // iteration's elements the same way.
            if (((Number*)_ppGElem.get(a)).asU32() == ((Number*)_ppGElem.get(b)).asU32()
                && ((Number*)_ppGOff.get(a)).asI64() == ((Number*)_ppGOff.get(b)).asI64()
                && ((Number*)_ppGOffLo.get(a)).asI64() == ((Number*)_ppGOffLo.get(b)).asI64()
                && ((Number*)_ppGOffHi.get(a)).asI64() == ((Number*)_ppGOffHi.get(b)).asI64())
                {
                IRValue* diff = ppCmp(P, String.withCString("NE"), aAt, bAt);
                ov = ppEmit(P, String.withCString("And"), bt, IROperand.useVal(ov), IROperand.useVal(diff), (IROperand*)0);
                }
            acc = ppEmit(P, String.withCString("Or"), bt, IROperand.useVal(acc), IROperand.useVal(ov), (IROperand*)0);
            }
        return acc;
        }
    // Array k's base as an integer (its result), and the byte range [lo, hi)
    // the loop touches in it, in _ppRangeLo / _ppRangeHi.
    final IRValue* ppRangeOf(IRBlock* P, u32 k, IRValue* lo64, IRValue* hi64)
        {
        String* i64t = String.withCString("I64");
        String* key = (String*)_ppGKeys.get(k);
        IRValue* base = (IRValue*)_ppGBase.get(k);
        if (key.hasPrefix(String.withCString("@")))
            base = ppEmit(P, String.withCString("AddrOf"), base.ty(),
                          IROperand.sym(key.substringFromByte((u32)1)), (IROperand*)0, (IROperand*)0);
        IRValue* at = ppEmit(P, String.withCString("PtrToInt"), i64t, IROperand.useVal(base), (IROperand*)0, (IROperand*)0);
        IRValue* es = ppEmit(P, String.withCString("Const"), i64t,
                             IROperand.immI((i64)((Number*)_ppGElem.get(k)).asU32(), i64t), (IROperand*)0, (IROperand*)0);
        // Elements k * lo + c0 to k * (hi - 1) + c1, inclusive: [k * lo + c0,
        // k * hi - k + c1 + 1), in bytes.
        i64 kk = ((Number*)_ppGOff.get(k)).asI64();
        i64 c0 = ((Number*)_ppGOffLo.get(k)).asI64();
        i64 c1 = ((Number*)_ppGOffHi.get(k)).asI64();
        IRValue* kv = ppEmit(P, String.withCString("Const"), i64t, IROperand.immI(kk, i64t), (IROperand*)0, (IROperand*)0);
        IRValue* c0v = ppEmit(P, String.withCString("Const"), i64t, IROperand.immI(c0, i64t), (IROperand*)0, (IROperand*)0);
        IRValue* c1v = ppEmit(P, String.withCString("Const"), i64t, IROperand.immI(c1 + (i64)1 - kk, i64t), (IROperand*)0, (IROperand*)0);
        IRValue* le = ppEmit(P, String.withCString("Mul"), i64t, IROperand.useVal(lo64), IROperand.useVal(kv), (IROperand*)0);
        le = ppEmit(P, String.withCString("Add"), i64t, IROperand.useVal(le), IROperand.useVal(c0v), (IROperand*)0);
        IRValue* he = ppEmit(P, String.withCString("Mul"), i64t, IROperand.useVal(hi64), IROperand.useVal(kv), (IROperand*)0);
        he = ppEmit(P, String.withCString("Add"), i64t, IROperand.useVal(he), IROperand.useVal(c1v), (IROperand*)0);
        IRValue* lb = ppEmit(P, String.withCString("Mul"), i64t, IROperand.useVal(le), IROperand.useVal(es), (IROperand*)0);
        IRValue* hb = ppEmit(P, String.withCString("Mul"), i64t, IROperand.useVal(he), IROperand.useVal(es), (IROperand*)0);
        _ppRangeLo = ppEmit(P, String.withCString("Add"), i64t, IROperand.useVal(at), IROperand.useVal(lb), (IROperand*)0);
        _ppRangeHi = ppEmit(P, String.withCString("Add"), i64t, IROperand.useVal(at), IROperand.useVal(hb), (IROperand*)0);
        return at;
        }

    final IRValue* ppCmp(IRBlock* P, String* pred, IRValue* a, IRValue* b)
        {
        IRInsn* c = IRInsn.with(String.withCString("ICmp"));
        IRValue* r = new IRValue(String.withCString("Bool"));
        c.setRes(r);
        c.setPred(pred);
        c.add(IROperand.useVal(a));
        c.add(IROperand.useVal(b));
        P.add(c);
        return r;
        }

    // Field k of the record `rec` (a struct pointer), loaded / stored.
    final IRValue* ppFieldLoad(IRBlock* b, IRValue* rec, u32 k, String* ty, IRValue* mem)
        {
        IRValue* p = ppEmit(b, String.withCString("FieldAddr"), String.withFormat("Ptr(%s, unbanked)", ty.cString()),
                            IROperand.useVal(rec), IROperand.immI((i64)k, String.withCString("U8")), (IROperand*)0);
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        IRValue* r = new IRValue(ty);
        _ppLastMem = new IRValue(String.withCString("Mem"));
        ld.setRes(r);
        ld.setMemRes(_ppLastMem);
        ld.add(IROperand.useVal(p));
        ld.add(IROperand.useVal(mem));
        b.add(ld);
        return r;
        }

    final IRValue* ppFieldStore(IRBlock* b, IRValue* rec, u32 k, IRValue* v, IRValue* mem)
        {
        IRValue* p = ppEmit(b, String.withCString("FieldAddr"), String.withFormat("Ptr(%s, unbanked)", v.ty().cString()),
                            IROperand.useVal(rec), IROperand.immI((i64)k, String.withCString("U8")), (IROperand*)0);
        return ppStore(b, p, v, mem);
        }

    // The address of the record's slot at byte `off`, typed as a T*.
    final IRValue* ppSlot(IRBlock* b, IRValue* ctx, u32 off, String* ty)
        {
        IRValue* p = ctx;
        if (off != (u32)0)
            {
            // An ElementAddr's index is a value, never an immediate.
            IRValue* ix = ppEmit(b, String.withCString("Const"), String.withCString("I64"),
                                 IROperand.immI((i64)off, String.withCString("I64")), (IROperand*)0, (IROperand*)0);
            p = ppEmit(b, String.withCString("ElementAddr"), String.withCString("Ptr(U8, unbanked)"),
                       IROperand.useVal(ctx), IROperand.useVal(ix), (IROperand*)0);
            }
        return ppEmit(b, String.withCString("Bitcast"), String.withFormat("Ptr(%s, unbanked)", ty.cString()),
                      IROperand.useVal(p), (IROperand*)0, (IROperand*)0);
        }

    final IRValue* ppCtxLoad(IRBlock* b, IRValue* ctx, u32 off, String* ty, IRValue* mem)
        {
        IRValue* p = ppSlot(b, ctx, off, ty);
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        IRValue* r = new IRValue(ty);
        _ppLastMem = new IRValue(String.withCString("Mem"));
        ld.setRes(r);
        ld.setMemRes(_ppLastMem);
        ld.add(IROperand.useVal(p));
        ld.add(IROperand.useVal(mem));
        b.add(ld);
        return r;
        }

    final IRValue* ppCtxStore(IRBlock* b, IRValue* ctx, u32 off, IRValue* v, IRValue* mem)
        {
        return ppStore(b, ppSlot(b, ctx, off, v.ty()), v, mem);
        }

    final IRValue* ppCall(IRBlock* b, String* callee, String* ty, IROperand* a0, IROperand* a1, IROperand* a2, IRValue* mem)
        {
        IRInsn* c = IRInsn.with(String.withCString("Call"));
        c.setCc(String.withCString("CallConv::Standard"));
        c.add(IROperand.sym(callee));
        if (a0 != (IROperand*)0) c.add(a0);
        if (a1 != (IROperand*)0) c.add(a1);
        if (a2 != (IROperand*)0) c.add(a2);
        c.add(IROperand.useVal(mem));
        IRValue* r = new IRValue(ty);
        c.setRes(r);
        _ppLastMem = new IRValue(String.withCString("Mem"));
        c.setMemRes(_ppLastMem);
        b.add(c);
        return r;
        }

    // v as an integer of type `to` (widened by its own signedness, or cut).
    final IRValue* ppConvertTo(IRBlock* b, IRValue* v, String* to)
        {
        u32 have = self.irWidth(v.ty());
        u32 want = self.irWidth(to);
        if (have == want)
            {
            if (v.ty().equals(to))
                return v;
            return ppEmit(b, String.withCString("Bitcast"), to, IROperand.useVal(v), (IROperand*)0, (IROperand*)0);
            }
        String* op = have > want ? String.withCString("Trunc")
                   : v.ty().hasPrefix(String.withCString("U")) ? String.withCString("ZExt") : String.withCString("SExt");
        return ppEmit(b, op, to, IROperand.useVal(v), (IROperand*)0, (IROperand*)0);
        }

    // The identity of a reduction operator: 0 for + ^ |, 1 for *, all ones for &.
    final IRValue* ppIdentity(IRBlock* b, String* ty, String* op)
        {
        // A maximum starts at the type's least value, a minimum at its
        // greatest; floats at -inf and +inf.
        if (op.hasPrefix(String.withCString("Min:")) || op.hasPrefix(String.withCString("Max:")))
            {
            bool isMax = op.hasPrefix(String.withCString("Max:"));
            u8 kind = op.byteAt((u32)4);
            if (kind == (u8)'F')
                return ppEmit(b, String.withCString("Const"), ty,
                              IROperand.immF(String.withCString(isMax ? "fff0000000000000" : "7ff0000000000000"), ty), (IROperand*)0, (IROperand*)0);
            u32 bits = self.irWidth(ty) * (u32)8;
            i64 v = (i64)0;
            if (kind == (u8)'U')
                v = isMax ? (i64)0 : (i64)0 - (i64)1;
            else
                {
                i64 top = bits >= (u32)64 ? (i64)$7FFFFFFFFFFFFFFF : ((i64)1 << (i64)(bits - (u32)1)) - (i64)1;
                v = isMax ? (i64)0 - top - (i64)1 : top;
                }
            return ppEmit(b, String.withCString("Const"), ty, IROperand.immI(v, ty), (IROperand*)0, (IROperand*)0);
            }
        if (op.equals(String.withCString("FMul")))
            return ppEmit(b, String.withCString("Const"), ty, IROperand.immF(String.withCString("3ff0000000000000"), ty), (IROperand*)0, (IROperand*)0);
        if (op.equals(String.withCString("Mul")))
            return ppEmit(b, String.withCString("Const"), ty, IROperand.immI((i64)1, ty), (IROperand*)0, (IROperand*)0);
        if (op.equals(String.withCString("And")))
            return ppEmit(b, String.withCString("Const"), ty, IROperand.immI((i64)0 - (i64)1, ty), (IROperand*)0, (IROperand*)0);
        return ppZero(b, ty);
        }

    final IRValue* ppZero(IRBlock* b, String* ty)
        {
        if (ty.hasPrefix(String.withCString("F")))
            return ppEmit(b, String.withCString("Const"), ty, IROperand.immF(String.withCString("0000000000000000"), ty), (IROperand*)0, (IROperand*)0);
        return ppEmit(b, String.withCString("Const"), ty, IROperand.immI((i64)0, ty), (IROperand*)0, (IROperand*)0);
        }

    final void ppShapeRow(void)
        {
        if (_ppAtIv)
            {
            _ppOff = _ppRowC;
            _ppOffLo = _ppRowLo;
            _ppOffHi = _ppRowHi;
            }
        }

    final bool ppAddrKey(IRValue* addr, IRValue* iv, Map* defOf)
        {
        _ppKey = (String*)0;
        _ppAtIv = false;
        _ppOff = (i64)1;
        _ppOffLo = (i64)0;
        _ppOffHi = (i64)0;
        _ppAddrTy = addr.ty();
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)addr);
        // A field of an element, or of a struct in one: the element's (its
        // array, its index, its size).
        IRInsn* fd = d;
        for (u32 dd = (u32)0; dd < (u32)8 && fd != (IRInsn*)0 && fd.op().equals(String.withCString("FieldAddr"))
             && fd.ops().count() >= (u32)1 && ((IROperand*)fd.ops().get((u32)0)).kind() == (u8)OPK_USE; dd = dd + (u32)1)
            {
            IRInsn* fb = (IRInsn*)defOf.get((Hashable*)((IROperand*)fd.ops().get((u32)0)).val());
            if (fb != (IRInsn*)0 && fb.op().equals(String.withCString("ElementAddr")) && fb.res() != (IRValue*)0)
                {
                d = fb;
                _ppAddrTy = fb.res().ty();
                }
            fd = fb;
            }
        IRValue* base = addr;
        if (d != (IRInsn*)0 && d.op().equals(String.withCString("ElementAddr")) && d.ops().count() == (u32)2)
            {
            IROperand* bo = (IROperand*)d.ops().get((u32)0);
            IROperand* io = (IROperand*)d.ops().get((u32)1);
            if (bo.kind() != (u8)OPK_USE)
                return false;
            base = bo.val();
            if (io.kind() == (u8)OPK_USE)
                {
                IRValue* x = io.val();
                IRInsn* xd = (IRInsn*)defOf.get((Hashable*)x);
                if (xd != (IRInsn*)0 && (xd.op().equals(String.withCString("SExt")) || xd.op().equals(String.withCString("ZExt")))
                    && xd.ops().count() == (u32)1 && ((IROperand*)xd.ops().get((u32)0)).kind() == (u8)OPK_USE)
                    x = ((IROperand*)xd.ops().get((u32)0)).val();
                _ppAtIv = x == iv;
                // [i + c] / [i - c]: the iteration's own element, c further on.
                if (!_ppAtIv)
                    {
                    IRInsn* ad = (IRInsn*)defOf.get((Hashable*)x);
                    if (ad != (IRInsn*)0 && (ad.op().equals(String.withCString("Add")) || ad.op().equals(String.withCString("Sub")))
                        && ad.ops().count() == (u32)2)
                        {
                        IROperand* a0 = (IROperand*)ad.ops().get((u32)0);
                        IROperand* a1 = (IROperand*)ad.ops().get((u32)1);
                        i64 c = (i64)0;
                        bool sub = ad.op().equals(String.withCString("Sub"));
                        if (a0.kind() == (u8)OPK_USE && ppStripExt(a0.val(), defOf) == iv && self.constValue(defOf, a1, &c))
                            {
                            _ppAtIv = true;
                            _ppOffLo = sub ? (i64)0 - c : c;
                            _ppOffHi = _ppOffLo;
                            }
                        else if (!sub && a1.kind() == (u8)OPK_USE && ppStripExt(a1.val(), defOf) == iv && self.constValue(defOf, a0, &c))
                            {
                            _ppAtIv = true;
                            _ppOffLo = c;
                            _ppOffHi = c;
                            }
                        }
                    }
                }
            // An element of a row (C's a[i][j]: the row's address an element
            // of the same type at i * C, j an element of it): one index, the
            // sum, into the array the row is in.
            Array* terms = new Array();
            terms.add((Object*)io);
            IRValue* rb = base;
            for (u32 depth = (u32)0; depth < (u32)4; depth = depth + (u32)1)
                {
                IRInsn* rd = (IRInsn*)defOf.get((Hashable*)rb);
                while (rd != (IRInsn*)0 && rd.op().equals(String.withCString("Bitcast")) && rd.ops().count() == (u32)1
                       && ((IROperand*)rd.ops().get((u32)0)).kind() == (u8)OPK_USE)
                    {
                    rb = ((IROperand*)rd.ops().get((u32)0)).val();
                    rd = (IRInsn*)defOf.get((Hashable*)rb);
                    }
                if (rd == (IRInsn*)0 || !rd.op().equals(String.withCString("ElementAddr")) || rd.ops().count() != (u32)2
                    || ((IROperand*)rd.ops().get((u32)0)).kind() != (u8)OPK_USE || rd.res() == (IRValue*)0
                    || !rd.res().ty().equals(d.res().ty()))
                    break;
                terms.add((Object*)rd.ops().get((u32)1));
                rb = ((IROperand*)rd.ops().get((u32)0)).val();
                }
            if (terms.count() > (u32)1)
                {
                base = rb;
                _ppAtIv = ppRowOwned(terms, iv, defOf);
                ppShapeRow();
                }
            else if (!_ppAtIv && io.kind() == (u8)OPK_USE)
                {
                _ppAtIv = ppRowOwned(terms, iv, defOf);
                ppShapeRow();
                }
            }
        // Through a cast of a pointer to its element type (the C path casts
        // its untyped pointers where they are used): the array is the
        // value cast.
        IRInsn* bc = (IRInsn*)defOf.get((Hashable*)base);
        while (bc != (IRInsn*)0 && bc.op().equals(String.withCString("Bitcast")) && bc.ops().count() == (u32)1
               && ((IROperand*)bc.ops().get((u32)0)).kind() == (u8)OPK_USE)
            {
            base = ((IROperand*)bc.ops().get((u32)0)).val();
            bc = (IRInsn*)defOf.get((Hashable*)base);
            }
        _ppBase = base;
        IRInsn* bd = (IRInsn*)defOf.get((Hashable*)base);
        if (bd != (IRInsn*)0 && bd.op().equals(String.withCString("AddrOf")) && bd.ops().count() == (u32)1
            && ((IROperand*)bd.ops().get((u32)0)).kind() == (u8)OPK_SYM)
            _ppKey = String.withFormat("@%s", ((IROperand*)bd.ops().get((u32)0)).name().cString());
        else
            _ppKey = String.withFormat("%%%u", base.seq());
        return true;
        }

    final void ppNoteKey(IRValue* base, IRValue* addr, bool atIv, bool stored)
        {
        u32 k = (u32)$FFFFFFFF;
        for (u32 i = (u32)0; i < _ppGKeys.count() && k == (u32)$FFFFFFFF; i = i + (u32)1)
            if (((String*)_ppGKeys.get(i)).equals(_ppKey))
                k = i;
        String* pt = _ppAddrTy != (String*)0 ? _ppAddrTy : addr.ty();
        u32 es = (u32)0;
        if (pt.hasPrefix(String.withCString("Ptr(")))
            {
            // The element: `Agg(N), ...` holds a comma inside, so the last one.
            u32 comma = (u32)$FFFFFFFF;
            for (u32 k = pt.byteLength(); k > (u32)0; k = k - (u32)1)
                if (pt.byteAt(k - (u32)1) == (u8)',')
                    {
                    comma = k - (u32)1;
                    break;
                    }
            if (comma != (u32)$FFFFFFFF)
                {
                String* et = pt.substringBytes((u32)4, comma - (u32)4);
                if (et.hasPrefix(String.withCString("Agg(")) && _ppModule != (IRModule*)0)
                    {
                    u32 lid = self.aeLayoutId(_ppModule, et);
                    if (lid < _ppModule.layouts().count())
                        es = ((IRLayout*)_ppModule.layouts().get(lid)).size();
                    }
                else
                    es = self.irWidth(et);
                }
            }
        if (k == (u32)$FFFFFFFF)
            {
            _ppGKeys.add((Object*)_ppKey);
            _ppGBase.add((Object*)base);
            _ppGElem.add((Object*)Number.with(es));
            _ppGAtIv.add((Object*)Number.with(atIv ? (u32)1 : (u32)0));
            _ppGOff.add((Object*)Number.withI64(_ppOff));
            _ppGOffLo.add((Object*)Number.withI64(_ppOffLo));
            _ppGOffHi.add((Object*)Number.withI64(_ppOffHi));
            _ppGStored.add((Object*)Number.with(stored ? (u32)1 : (u32)0));
            return;
            }
        // Every access the iteration's own at one offset, or none is.
        if (!atIv || ((Number*)_ppGOff.get(k)).asI64() != _ppOff)
            _ppGAtIv.set(k, (Object*)Number.with((u32)0));
        // A row's elements: the range over every access (a stencil's rows
        // are the same row: one iteration's).
        else if (_ppOff != (i64)1)
            {
            if (_ppOffLo < ((Number*)_ppGOffLo.get(k)).asI64())
                _ppGOffLo.set(k, (Object*)Number.withI64(_ppOffLo));
            if (_ppOffHi > ((Number*)_ppGOffHi.get(k)).asI64())
                _ppGOffHi.set(k, (Object*)Number.withI64(_ppOffHi));
            }
        else if (((Number*)_ppGOffLo.get(k)).asI64() != _ppOffLo)
            _ppGAtIv.set(k, (Object*)Number.with((u32)0));
        if (stored)
            _ppGStored.set(k, (Object*)Number.with((u32)1));
        if (((Number*)_ppGElem.get(k)).asU32() != es)
            _ppGElem.set(k, (Object*)Number.with((u32)0));
        }

    // A function the C++ path took from its read build (libc++'s parallel
    // algorithms as plain loops) has a twin, `<name>_xclib`: clang's own
    // version, with libc++'s parallel backend. Where no block was made of
    // the function (or no loop was lifted at all, `outlined` false), its
    // body becomes a call of the twin, so a parallel algorithm xcc cannot
    // lift keeps the library's parallelism. A module without such a symbol
    // (every xc and C one) is left as it is, after one look at its symbols.
    final void libFallback(IRModule* m, bool outlined)
        {
        Map* twins = (Map*)0;
        for (u32 i = 0; i < m.syms().count(); i = i + 1)
            {
            IRSymbol* sy = (IRSymbol*)m.syms().get(i);
            if (sy.name().hasSuffix(String.withCString("_xclib")))
                {
                if (twins == (Map*)0)
                    twins = new Map();
                twins.set((Hashable*)sy.name().substringBytes(0, sy.name().byteLength() - 6), (Object*)sy);
                }
            }
        if (twins == (Map*)0)
            return;
        for (u32 f = 0; f < m.funcs().count(); f = f + 1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            IRSymbol* twin = (IRSymbol*)twins.get((Hashable*)fn.name());
            if (twin == (IRSymbol*)0 || fn.blocks().count() == 0)
                continue;
            if (outlined && self.libMadeBlock(fn))
                continue;
            // The body: the twin's result for the same arguments.
            u32 np = fn.params().count();
            IRValue* mem = np > 0 ? (IRValue*)fn.params().get(np - 1) : (IRValue*)0;
            if (mem == (IRValue*)0 || !mem.ty().equals(String.withCString("Mem")))
                continue;
            IRBlock* b = new IRBlock(String.withCString("bb_entry"));
            IRInsn* c = IRInsn.with(String.withCString("Call"));
            c.setCc(String.withCString("CallConv::Standard"));
            c.add(IROperand.sym(twin.name()));
            for (u32 p = 0; p + 1 < np; p = p + 1)
                c.add(IROperand.useVal((IRValue*)fn.params().get(p)));
            c.add(IROperand.useVal(mem));
            IRValue* r = (IRValue*)0;
            if (!fn.ret().equals(String.withCString("Void")))
                {
                r = new IRValue(fn.ret());
                c.setRes(r);
                }
            IRValue* mo = new IRValue(String.withCString("Mem"));
            c.setMemRes(mo);
            b.add(c);
            IRInsn* ret = IRInsn.with(String.withCString("Return"));
            if (r != (IRValue*)0)
                ret.add(IROperand.useVal(r));
            ret.add(IROperand.useVal(mo));
            b.setTerm(ret);
            Array* only = new Array();
            only.add((Object*)b);
            fn.setBlocks(only);
            }
        }

    // Whether the outliner made a block in fn: a call of ParFnChunk$make.
    final bool libMadeBlock(IRFunc* fn)
        {
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* blk = (IRBlock*)fn.blocks().get(b);
            for (u32 i = 0; i < blk.insns().count(); i = i + 1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (n.op().equals(String.withCString("Call")) && n.ops().count() > 0
                    && ((IROperand*)n.ops().get(0)).kind() == (u8)OPK_SYM
                    && ((IROperand*)n.ops().get(0)).name().equals(String.withCString("ParFnChunk$make")))
                    return true;
                }
            }
        return false;
        }

    final bool ppParMemoryOk(IRFunc* fn, LRCLoop* L, IRValue* iv, Map* defOf, Map* defBlk)
        {
        _ppDefBlk = defBlk;
        _ppGKeys = new Array();
        _ppGBase = new Array();
        _ppGElem = new Array();
        _ppGAtIv = new Array();
        _ppGOff = new Array();
        _ppGOffLo = new Array();
        _ppGOffHi = new Array();
        _ppGStored = new Array();
        _ppPairA = new Array();
        _ppPairB = new Array();
        Array* body = L.body();
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)body.get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                String* op = n.op();
                bool st = op.equals(String.withCString("Store"));
                // A class's one-time initialisation, which the loop may run:
                // its flag and its run are the runtime's, thread-safe, and
                // touch nothing of the loop's.
                if (op.equals(String.withCString("Call")) && n.ops().count() > (u32)0
                    && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_SYM
                    && ((IROperand*)n.ops().get((u32)0)).name().equals(String.withCString("_xtc_sinit_run")))
                    continue;
                // A call to a function that touches no memory (a C helper such
                // as perlin's fade, which C does not let the first inlining
                // take): each iteration's call is its own.
                if (op.equals(String.withCString("Call")) && n.ops().count() > (u32)0
                    && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_SYM
                    && ppPureFn(((IROperand*)n.ops().get((u32)0)).name(), (u32)0))
                    continue;
                if (st || op.equals(String.withCString("Load")))
                    {
                    IRValue* addr = ((IROperand*)n.ops().get((u32)0)).val();
                    if (!ppAddrKey(addr, iv, defOf))
                        return ppNo("ppParMemoryOk 1");
                    if (!st && _ppKey.hasPrefix(String.withCString("@__sinit_")))
                        continue;
                    if (st && !_ppAtIv)
                        return ppNo("a store not at [i]");
                    ppNoteKey(_ppBase, addr, _ppAtIv, st);
                    }
                else if (lrcWritesMemory(op) || op.hasPrefix(String.withCString("Load")))
                    {
                    String* what = String.withString(op);
                    if (op.equals(String.withCString("Call")) && n.ops().count() > (u32)0
                        && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_SYM)
                        what = String.withFormat("a call to %s", ((IROperand*)n.ops().get((u32)0)).name().cString());
                    return ppNo(String.withFormat("memory touched by %s", what.cString()).cString());
                    }
                }
            }
        for (u32 s = (u32)0; s < _ppGKeys.count(); s = s + (u32)1)
            {
            if (((Number*)_ppGStored.get(s)).asU32() == (u32)0)
                continue;
            String* sk = (String*)_ppGKeys.get(s);
            // A stored array is read only at [i].
            if (((Number*)_ppGAtIv.get(s)).asU32() == (u32)0)
                return ppNo("a stored array read away from [i]");
            for (u32 x = (u32)0; x < _ppGKeys.count(); x = x + (u32)1)
                {
                if (x == s)
                    continue;
                String* xk = (String*)_ppGKeys.get(x);
                // Two globals are two arrays.
                if (sk.hasPrefix(String.withCString("@")) && xk.hasPrefix(String.withCString("@")))
                    continue;
                // A pair stored-and-other once (two stored arrays: once).
                if (((Number*)_ppGStored.get(x)).asU32() != (u32)0 && x < s)
                    continue;
                // Otherwise they may be one array: checked at run time, which
                // needs both touched only at [i], their element sizes known
                // and their bases from outside the loop.
                if (((Number*)_ppGAtIv.get(x)).asU32() == (u32)0)
                    return ppNo("an array that may overlap a stored one, read away from [i]");
                // (The run-time check compares the elements each touches,
                // k * lo + c0 up to k * (hi - 1) + c1: ppRangeOf.)
                if (((Number*)_ppGElem.get(s)).asU32() == (u32)0 || ((Number*)_ppGElem.get(x)).asU32() == (u32)0)
                    return ppNo("an array of an element whose size is not known");
                for (u32 w = (u32)0; w < (u32)2; w = w + (u32)1)
                    {
                    u32 idx = w == (u32)0 ? s : x;
                    if (((String*)_ppGKeys.get(idx)).hasPrefix(String.withCString("@")))
                        continue;
                    IRBlock* db = (IRBlock*)defBlk.get((Hashable*)_ppGBase.get(idx));
                    if (db != (IRBlock*)0 && self.hasBlock(body, db))
                        return ppNo("a pointer computed in the loop");
                    }
                _ppPairA.add((Object*)Number.with(s));
                _ppPairB.add((Object*)Number.with(x));
                }
            }
        return true;
        }

    // Whether a loop nested in L runs a number of times that depends on L's
    // induction variable: its bound does (`for j in 0..i`) or its start does
    // (`for j in i..n`). Rows of unequal work.
    final bool ppTriangular(IRFunc* fn, LRCLoop* L, Array* loops)
        {
        Map* defOf = self.defMapAll(fn);
        IRInsn* oiv = (IRInsn*)0;
        for (u32 i = (u32)0; i < L.header().phis().count() && oiv == (IRInsn*)0; i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)L.header().phis().get(i);
            if (phi.res() != (IRValue*)0 && !ppIsMem(phi.res()))
                oiv = phi;      // the first value phi: the induction variable, as the verdict found it
            }
        if (oiv == (IRInsn*)0)
            return false;
        for (u32 j = (u32)0; j < loops.count(); j = j + (u32)1)
            {
            LRCLoop* M = (LRCLoop*)loops.get(j);
            if (M == L || M.header() == L.header() || !self.hasBlock(L.body(), M.header()))
                continue;
            IRInsn* t = M.header().term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")))
                continue;
            IRInsn* cmp = (IRInsn*)defOf.get((Hashable*)((IROperand*)t.ops().get((u32)0)).val());
            if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")))
                continue;
            for (u32 k = (u32)0; k < cmp.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)cmp.ops().get(k);
                if (o.kind() == (u8)OPK_USE && ppDependsOn(o.val(), oiv.res(), defOf, (u32)0))
                    {
                    // The inner loop's own variable: triangular when it STARTS
                    // from the outer one (`for j in i..n`); its bound otherwise.
                    IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
                    if (d != (IRInsn*)0 && d.op().equals(String.withCString("Phi")) &&
                        M.header().phis().indexOf((Object*)d) != (u32)$FFFFFFFF)
                        {
                        IRValue* start = ppPhiIn(d, M, false);
                        if (start != (IRValue*)0 && ppDependsOn(start, oiv.res(), defOf, (u32)0))
                            return true;
                        continue;
                        }
                    return true;
                    }
                }
            }
        return false;
        }

    // The loop's position: its header's first located instruction, else the
    // preheader's branch into it.
    final IRInsn* ppFirstDbg(LRCLoop* L)
        {
        IRBlock* H = L.header();
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).hasDbg())
                return (IRInsn*)H.insns().get(i);
        if (H.term() != 0 && H.term().hasDbg())
            return H.term();
        if (L.pre() != (IRBlock*)0 && L.pre().term() != 0 && L.pre().term().hasDbg())
            return L.pre().term();
        return (IRInsn*)0;
        }

    // A phi's value on the edge from one of `from` (true: inside the loop) or
    // from outside it (false).
    final IRValue* ppPhiIn(IRInsn* phi, LRCLoop* L, bool inside)
        {
        IRValue* v = (IRValue*)0;
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IROperand* b = (IROperand*)phi.ops().get(k);
            IROperand* o = (IROperand*)phi.ops().get(k + (u32)1);
            if (b.kind() != (u8)OPK_BLOCK || o.kind() != (u8)OPK_USE)
                continue;
            if (hasBlock(L.body(), b.blk()) == inside)
                v = o.val();
            }
        return v;
        }

    final bool ppDefinedIn(Map* defBlk, IRValue* v, LRCLoop* L)
        {
        IRBlock* b = (IRBlock*)defBlk.get((Hashable*)v);
        return b != (IRBlock*)0 && self.hasBlock(L.body(), b);
        }

    // Why the loop is not a candidate, or 0 when it is. The rules follow the
    // parser's scan: a counted loop (an induction variable stepped by a
    // positive constant, tested against a bound fixed for the loop), whose
    // other carried values are integer reductions, and whose stores are to
    // array elements.
    final String* ppVerdict(IRFunc* fn, LRCLoop* L)
        {
        if (L.pre() == (IRBlock*)0)
            return String.withCString("no single entry");
        Map* defOf = self.defMapAll(fn);
        Map* defBlk = self.defBlockMap(fn);
        IRBlock* H = L.header();
        // The exit test: the header ends in a CondBranch on an ICmp.
        IRInsn* t = H.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")))
            return String.withCString("the loop is not tested at its top");
        IRValue* cv = ((IROperand*)t.ops().get((u32)0)).val();
        IRInsn* cmp = cv != (IRValue*)0 ? (IRInsn*)defOf.get((Hashable*)cv) : (IRInsn*)0;
        if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")))
            return String.withCString("no integer exit test");
        // The induction variable: a header phi stepped by a positive constant.
        IRInsn* iv = (IRInsn*)0;
        u32 reductions = (u32)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == (IRValue*)0 || phi.res().ty().hasPrefix(String.withCString("Mem")))
                continue;
            IRValue* nx = ppPhiIn(phi, L, true);
            IRInsn* step = nx != (IRValue*)0 ? (IRInsn*)defOf.get((Hashable*)nx) : (IRInsn*)0;
            if (step == (IRInsn*)0)
                return String.withCString("a carried value with no step");
            // The induction variable: stepped straight by a positive constant
            // and tested by the exit.
            if (iv == (IRInsn*)0 && step.op().equals(String.withCString("Add")) && ppStepOf(step, phi.res()) &&
                ppCmpUses(cmp, phi.res(), step.res()))
                {
                IROperand* other = (IROperand*)0;
                for (u32 k = (u32)0; k < step.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)step.ops().get(k);
                    if (!(o.kind() == (u8)OPK_USE && o.val() == phi.res()))
                        other = o;
                    }
                if (other != (IROperand*)0 && ppIsPositiveConst(other, defOf))
                    {
                    iv = phi;
                    continue;
                    }
                }
            // A reduction: every path from the accumulator back to it applies
            // one operator (or none), through merge phis and inner loops'
            // phis alike — `if (c) acc += x;` and a sum over a 2-D nest.
            Set* seen = new Set();
            seen.add((Hashable*)phi.res());
            String* op = ppChainOp(nx, phi.res(), defOf, seen, (u32)0);
            if (op == (String*)0)
                return String.withCString("a carried value that is not an accumulator");
            if (op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FMul")))
                return String.withCString("a float reduction (only under :goal(speed))");
            if (!(op.equals(String.withCString("Add")) || op.equals(String.withCString("Mul")) ||
                  op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) ||
                  op.equals(String.withCString("Xor")) || op.equals(String.withCString("Select")) ||
                  op.equals(String.withCString("="))))
                {
                String* w = String.withCString("a carried value updated by ");
                w.append(op);
                return w;
                }
            reductions = reductions + (u32)1;
            }
        if (iv == (IRInsn*)0)
            return String.withCString("no induction variable");
        // The bound must not change inside the loop.
        for (u32 k = (u32)0; k < cmp.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)cmp.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == iv.res())
                continue;
            if (!ppInvariant(o.val(), L, defOf, defBlk, (u32)0))
                {
                IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
                if (d == (IRInsn*)0 || !(d.op().equals(String.withCString("Add")) && ppStepOf(d, iv.res())))
                    return String.withCString("a bound computed in the loop");
                }
            }
        // One way out: the header's test. A `break` (or a return) leaves from
        // the body as well, and an iteration's work then depends on the ones
        // before it.
        for (u32 b = (u32)0; b < L.body().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)L.body().get(b);
            if (bb == H)
                continue;
            Array* ss = self.lrcSuccs(fn, bb);
            for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                if (!self.hasBlock(L.body(), (IRBlock*)ss.get(k)))
                    return String.withCString("a way out of the loop besides its test (break or return)");
            }
        // The body: stores only to array elements, no calls.
        for (u32 b = (u32)0; b < L.body().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)L.body().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.isCall())
                    {
                    String* w = ppCallWhy(n);
                    if (w != (String*)0)
                        return w;
                    }
                if (n.op().equals(String.withCString("Store")))
                    {
                    IRValue* a = ((IROperand*)n.ops().get((u32)0)).val();
                    IRInsn* ad = a != (IRValue*)0 ? (IRInsn*)defOf.get((Hashable*)a) : (IRInsn*)0;
                    // A local slot used only inside the loop is each iteration's
                    // own scratch (an inlined callee's `u32 bits` behind a
                    // bitcast, say): private, as the scan treats a body's locals.
                    bool scratch = ad != (IRInsn*)0 && ad.op().equals(String.withCString("AddrOf")) &&
                                   ppSlotOnlyIn(fn, L, ad);
                    // A field of an element (`pts[i].x = …`), or of a struct
                    // in one (`pts[i].tag.kind`), is an element's.
                    IRInsn* fa = ad;
                    for (u32 dd = (u32)0; dd < (u32)8 && fa != (IRInsn*)0 && fa.op().equals(String.withCString("FieldAddr"))
                         && fa.ops().count() >= (u32)1 && ((IROperand*)fa.ops().get((u32)0)).kind() == (u8)OPK_USE; dd = dd + (u32)1)
                        {
                        fa = (IRInsn*)defOf.get((Hashable*)((IROperand*)fa.ops().get((u32)0)).val());
                        if (fa != (IRInsn*)0 && fa.op().equals(String.withCString("ElementAddr")))
                            ad = fa;
                        }
                    if (!scratch && (ad == (IRInsn*)0 || !ad.op().equals(String.withCString("ElementAddr"))))
                        return String.withCString("a store that is not to an array element");
                    }
                if (n.op().equals(String.withCString("Return")))
                    return String.withCString("a return");
                }
            }
        return (String*)0;
        }

    // The one stepping instruction of a conditional reduction's merge phi, or
    // 0: every incoming value is the accumulator itself or the same op on it.
    final IRInsn* ppCondStep(IRInsn* merge, IRValue* acc, Map* defOf)
        {
        IRInsn* one = (IRInsn*)0;
        for (u32 k = (u32)0; k + (u32)1 < merge.ops().count(); k = k + (u32)2)
            {
            IROperand* o = (IROperand*)merge.ops().get(k + (u32)1);
            if (o.kind() != (u8)OPK_USE)
                return (IRInsn*)0;
            if (o.val() == acc)
                continue;
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
            if (d == (IRInsn*)0 || !ppStepOf(d, acc))
                return (IRInsn*)0;
            if (one != (IRInsn*)0 && !one.op().equals(d.op()))
                return (IRInsn*)0;
            one = d;
            }
        return one;
        }

    // Why a call keeps the loop serial, or 0: a direct call to a function of
    // the program itself (not the standard library) is allowed, as the scan
    // allows it; the check later decides whether a device can run it.
    final String* ppCallWhy(IRInsn* n)
        {
        String* callee = (String*)0;
        for (u32 k = (u32)0; k < n.ops().count() && callee == (String*)0; k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_SYM)
                callee = o.name();
            }
        if (callee == (String*)0)
            return String.withCString("an indirect call");
        // A class's one-time initialisation (Math.sqrt in a loop brings it):
        // thread-safe, and after the first time a load and a compare.
        if (callee.equals(String.withCString("_xtc_sinit_run")))
            return (String*)0;
        IRFunc* f = self.funcNamed(_ppModule, callee);
        if (f == (IRFunc*)0 || f.blocks().count() == (u32)0)
            {
            String* w = String.withCString("a call to ");
            w.append(callee);
            return w;
            }
        if (f.hasDbg() && f.dbgFile() < IRDbg.files().count())
            {
            String* fp = (String*)IRDbg.files().get(f.dbgFile());
            if (fp != (String*)0 && IRDbg.isLibraryPath(fp))
                {
                String* w = String.withCString("a call into the standard library (");
                w.append(callee);
                w.appendCString(")");
                return w;
                }
            }
        return (String*)0;
        }

    // The one operator every path from `acc` to v applies to it: "=" when v
    // is acc unchanged on every path, 0 when the paths disagree, the value is
    // used some other way, or the other operand depends on acc. Phis (merges,
    // inner loops' headers) are followed; one met again is part of the cycle.
    final String* ppChainOp(IRValue* v, IRValue* acc, Map* defOf, Set* seen, u32 depth)
        {
        if (v == acc)
            return String.withCString("=");
        if (depth > (u32)32)
            return (String*)0;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        if (d == (IRInsn*)0)
            return (String*)0;
        if (d.op().equals(String.withCString("Phi")))
            {
            if (seen.contains((Hashable*)v))
                return String.withCString("=");
            seen.add((Hashable*)v);
            String* got = String.withCString("=");
            for (u32 k = (u32)0; k + (u32)1 < d.ops().count(); k = k + (u32)2)
                {
                IROperand* o = (IROperand*)d.ops().get(k + (u32)1);
                if (o.kind() != (u8)OPK_USE)
                    return (String*)0;
                String* one = ppChainOp(o.val(), acc, defOf, seen, depth + (u32)1);
                if (one == (String*)0)
                    return (String*)0;
                if (one.equals(String.withCString("=")))
                    continue;
                if (got.equals(String.withCString("=")))
                    got = one;
                else if (!got.equals(one))
                    return (String*)0;
                }
            return got;
            }
        // `Select c, a, b`: when c does not involve the accumulator, a merge
        // (if-conversion's form of `if (c) acc += x;`), followed like a phi;
        // when it does, a min or max (`acc = x < acc ? x : acc`): one arm the
        // accumulator unchanged, the other free of it.
        if (d.op().equals(String.withCString("Select")) && d.ops().count() == (u32)3)
            {
            IROperand* c = (IROperand*)d.ops().get((u32)0);
            IROperand* x = (IROperand*)d.ops().get((u32)1);
            IROperand* y = (IROperand*)d.ops().get((u32)2);
            if (x.kind() != (u8)OPK_USE || y.kind() != (u8)OPK_USE)
                return (String*)0;
            bool cAcc = c.kind() == (u8)OPK_USE && ppDependsOn(c.val(), acc, defOf, (u32)0);
            if (!cAcc)
                {
                String* l = ppChainOp(x.val(), acc, defOf, seen, depth + (u32)1);
                String* r = ppChainOp(y.val(), acc, defOf, seen, depth + (u32)1);
                if (l == (String*)0 || r == (String*)0)
                    return (String*)0;
                if (l.equals(String.withCString("=")))
                    return r;
                if (r.equals(String.withCString("=")) || l.equals(r))
                    return l;
                return (String*)0;
                }
            bool xAcc = x.val() == acc;
            bool yAcc = y.val() == acc;
            if (xAcc == yAcc)
                return (String*)0;
            IRValue* other = xAcc ? y.val() : x.val();
            if (ppDependsOn(other, acc, defOf, (u32)0))
                return (String*)0;
            return String.withCString("Select");
            }
        // One operand on the accumulator's chain, the others free of it.
        String* inner = (String*)0;
        for (u32 k = (u32)0; k < d.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)d.ops().get(k);
            if (o.kind() != (u8)OPK_USE || ppIsMem(o.val()))
                continue;
            if (!ppDependsOn(o.val(), acc, defOf, (u32)0))
                continue;
            if (inner != (String*)0)
                return (String*)0;      // acc on two operands
            inner = ppChainOp(o.val(), acc, defOf, seen, depth + (u32)1);
            if (inner == (String*)0)
                return (String*)0;
            }
        if (inner == (String*)0)
            return (String*)0;
        if (inner.equals(String.withCString("=")) || inner.equals(d.op()))
            return d.op();
        return (String*)0;
        }

    // Whether v's value is computed from acc (through anything but a phi:
    // a phi is a path, followed by ppChainOp).
    // Exactly, however deep (MD5's 64 rounds are hundreds of operations): a
    // search of the values v is computed from, each once, stopping at phis.
    // The depth argument is kept for the callers; it no longer limits.
    final bool ppDependsOn(IRValue* v, IRValue* acc, Map* defOf, u32 depth)
        {
        Set* seen = new Set();
        Array* work = new Array();
        work.add((Object*)v);
        while (work.count() > (u32)0)
            {
            IRValue* x = (IRValue*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (x == acc)
                return true;
            if (seen.contains((Hashable*)x))
                continue;
            seen.add((Hashable*)x);
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)x);
            if (d == (IRInsn*)0)
                continue;
            if (d.op().equals(String.withCString("Phi")))
                {
                for (u32 k = (u32)0; k + (u32)1 < d.ops().count(); k = k + (u32)2)
                    {
                    IROperand* o = (IROperand*)d.ops().get(k + (u32)1);
                    if (o.kind() == (u8)OPK_USE && o.val() == acc)
                        return true;
                    }
                continue;
                }
            for (u32 k = (u32)0; k < d.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)d.ops().get(k);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && !ppIsMem(o.val()))
                    work.add((Object*)o.val());
                }
            }
        return false;
        }

    // A memory token: it orders the loads and stores, it carries no value.
    final bool ppIsMem(IRValue* v)
        {
        return v != (IRValue*)0 && v.ty() != (String*)0 && v.ty().equals(String.withCString("Mem"));
        }

    // Whether the frame slot `addr` takes the address of is reached only from
    // inside the loop (no AddrOf of it anywhere else in the function).
    final bool ppSlotOnlyIn(IRFunc* fn, LRCLoop* L, IRInsn* addr)
        {
        if (addr.ops().count() == (u32)0)
            return false;
        IROperand* slot = (IROperand*)addr.ops().get((u32)0);
        if (slot.kind() != (u8)OPK_USE)
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(L.body(), bb))
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("AddrOf")) || n.ops().count() == (u32)0)
                    continue;
                IROperand* o = (IROperand*)n.ops().get((u32)0);
                if (o.kind() == (u8)OPK_USE && o.val() == slot.val())
                    return false;
                }
            }
        return true;
        }

    final bool ppIsPositiveConst(IROperand* o, Map* defOf)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return o.imm() > (i64)0;
        if (o.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
        // Through the widenings the lowering wraps a small literal in.
        while (d != (IRInsn*)0 && (d.op().equals(String.withCString("ZExt")) || d.op().equals(String.withCString("SExt"))) &&
               d.ops().count() > (u32)0 && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            d = (IRInsn*)defOf.get((Hashable*)((IROperand*)d.ops().get((u32)0)).val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Const")) || d.ops().count() == (u32)0)
            return false;
        IROperand* c = (IROperand*)d.ops().get((u32)0);
        return c.kind() == (u8)OPK_IMMI && c.imm() > (i64)0;
        }

    // Whether v is the same on every iteration: defined outside the loop, or a
    // constant, or pure arithmetic on such values (the lowering puts
    // `(u32)D + (u32)1` and `1 << 18` in the header).
    final bool ppInvariant(IRValue* v, LRCLoop* L, Map* defOf, Map* defBlk, u32 depth)
        {
        if (!ppDefinedIn(defBlk, v, L))
            return true;
        if (depth > (u32)8)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
        if (d == (IRInsn*)0)
            return false;
        String* op = d.op();
        if (op.equals(String.withCString("Const")))
            return true;
        // Pure: touches no memory (no memory result) and is no phi, load or
        // call — arithmetic, shifts, widenings and the like.
        if (d.memRes() != (IRValue*)0 || d.isCall() || op.equals(String.withCString("Phi")) ||
            op.equals(String.withCString("Load")))
            return false;
        for (u32 k = (u32)0; k < d.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)d.ops().get(k);
            if (o.kind() == (u8)OPK_USE && !ppInvariant(o.val(), L, defOf, defBlk, depth + (u32)1))
                return false;
            }
        return true;
        }

    // The exit test reads the induction variable (or its next value).
    final bool ppCmpUses(IRInsn* cmp, IRValue* phi, IRValue* next)
        {
        for (u32 k = (u32)0; k < cmp.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)cmp.ops().get(k);
            if (o.kind() == (u8)OPK_USE && (o.val() == phi || o.val() == next))
                return true;
            }
        return false;
        }

    final bool ppStepOf(IRInsn* d, IRValue* phi)
        {
        for (u32 k = (u32)0; k < d.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)d.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == phi)
                return true;
            }
        return false;
        }
    }
