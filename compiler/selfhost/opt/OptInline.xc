// OptInline.xc — the Inline pass, ported from src/xtc/ir/XTIROptInline.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptArcSelfRetain>

    class Opt (Inline)
    {
    // ── inline ───────────────────────────────────────────────────────────
    //
    // Splice a small leaf's body into its caller. Only the SINGLE-BLOCK shape
    // is here: a multi-block callee splits the caller's block and rewires the
    // CFG, which is the other half of the original's pass and is refused by
    // name until it is ported too.
    final void inlineLeaves(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            inlineInto(m, (IRFunc*)m.funcs().get(f));
        }

    // A single-block callee splices in place; a multi-block one SPLITS the
    // caller's block, so the block list changes underneath the scan and the
    // caller is rescanned. The guard is the original's, against a pathological
    // chain of inlines.
    // The blocks on a cycle of the CFG: in a strongly connected component of
    // more than one block, or branching to themselves (Kosaraju, iterative,
    // linear). A set, so the order blocks are visited in does not matter; the
    // reference's +cyclicBlocksOf: is the same.
    // Every call in fn is to a check (_xt_check_*), with no dispatch.
    final bool checksOnlyCalls(IRModule* m, IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                String* op = n.op();
                if (op.equals(String.withCString("Call")))
                    {
                    IROperand* o = n.ops().count() > (u32)0 ? (IROperand*)n.ops().get((u32)0) : (IROperand*)0;
                    if (o == (IROperand*)0 || o.kind() != (u8)OPK_SYM || o.name() == (String*)0
                        || !o.name().hasPrefix(String.withCString("_xt_check")))
                        return false;
                    }
                else if (op.hasPrefix(String.withCString("Call")) || op.equals(String.withCString("VTblDispatch"))
                         || op.equals(String.withCString("ProtoDispatch")))
                    return false;
                }
            }
        return true;
        }

    final Map* cyclicBlocks(IRFunc* fn)
        {
        Array* bs = fn.blocks();
        Map* idx = new Map();
        for (u32 i = (u32)0; i < bs.count(); i = i + (u32)1)
            idx.set((Hashable*)bs.get(i), (Object*)Number.with(i));
        Array* succ = new Array();
        Array* pred = new Array();
        for (u32 i = (u32)0; i < bs.count(); i = i + (u32)1)
            {
            succ.add((Object*)new Array());
            pred.add((Object*)new Array());
            }
        Map* loops = new Map();
        for (u32 i = (u32)0; i < bs.count(); i = i + (u32)1)
            {
            Array* ss = self.successorsOf((IRBlock*)bs.get(i));
            for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                {
                Object* j = idx.get((Hashable*)ss.get(k));
                if (j == (Object*)0)
                    continue;
                u32 jj = ((Number*)j).asU32();
                ((Array*)succ.get(i)).add((Object*)Number.with(jj));
                ((Array*)pred.get(jj)).add((Object*)Number.with(i));
                if (jj == i)
                    loops.set((Hashable*)bs.get(i), (Object*)Number.with((u32)1));
                }
            }
        // 1. Postorder over the successors.
        Array* order = new Array();
        Map* seen = new Map();
        for (u32 r = (u32)0; r < bs.count(); r = r + (u32)1)
            {
            if (seen.get((Hashable*)Number.with(r)) != (Object*)0)
                continue;
            Array* stN = new Array();
            Array* stK = new Array();
            seen.set((Hashable*)Number.with(r), (Object*)Number.with((u32)1));
            stN.add((Object*)Number.with(r));
            stK.add((Object*)Number.with((u32)0));
            while (stN.count() > (u32)0)
                {
                u32 top = stN.count() - (u32)1;
                u32 n = ((Number*)stN.get(top)).asU32();
                u32 k = ((Number*)stK.get(top)).asU32();
                Array* ss = (Array*)succ.get(n);
                if (k < ss.count())
                    {
                    stK.set(top, (Object*)Number.with(k + (u32)1));
                    u32 c = ((Number*)ss.get(k)).asU32();
                    if (seen.get((Hashable*)Number.with(c)) == (Object*)0)
                        {
                        seen.set((Hashable*)Number.with(c), (Object*)Number.with((u32)1));
                        stN.add((Object*)Number.with(c));
                        stK.add((Object*)Number.with((u32)0));
                        }
                    }
                else
                    {
                    order.add((Object*)Number.with(n));
                    stN.removeLast();
                    stK.removeLast();
                    }
                }
            }
        // 2. Components over the predecessors, in reverse postorder.
        Map* comp = new Map();
        u32 nc = (u32)0;
        for (u32 q = order.count(); q > (u32)0; q = q - (u32)1)
            {
            u32 r = ((Number*)order.get(q - (u32)1)).asU32();
            if (comp.get((Hashable*)Number.with(r)) != (Object*)0)
                continue;
            nc = nc + (u32)1;
            Array* members = new Array();
            Array* st = new Array();
            comp.set((Hashable*)Number.with(r), (Object*)Number.with(nc));
            st.add((Object*)Number.with(r));
            while (st.count() > (u32)0)
                {
                u32 n = ((Number*)st.get(st.count() - (u32)1)).asU32();
                st.removeLast();
                members.add((Object*)Number.with(n));
                Array* ps = (Array*)pred.get(n);
                for (u32 k = (u32)0; k < ps.count(); k = k + (u32)1)
                    {
                    u32 c = ((Number*)ps.get(k)).asU32();
                    if (comp.get((Hashable*)Number.with(c)) == (Object*)0)
                        {
                        comp.set((Hashable*)Number.with(c), (Object*)Number.with(nc));
                        st.add((Object*)Number.with(c));
                        }
                    }
                }
            if (members.count() > (u32)1)
                for (u32 k = (u32)0; k < members.count(); k = k + (u32)1)
                    loops.set((Hashable*)bs.get(((Number*)members.get(k)).asU32()), (Object*)Number.with((u32)1));
            }
        return loops;
        }

    final void inlineInto(IRModule* m, IRFunc* caller)
        {
        bool again = true;
        u32 guard = (u32)0;
        while (again && guard < (u32)8192)
            {
            guard = guard + (u32)1;
            again = false;
            // Checks inline only where they repeat: in a block on a cycle
            // (inlined everywhere, binaries grew 1.93x, cold code included).
            // Recomputed on each rescan, as an inline splits blocks.
            Map* loops = _inlineChecks ? cyclicBlocks(caller) : (Map*)0;
            // An accessor's checks inline everywhere in it (the reference
            // explains).
            if (loops != (Map*)0 && loops.count() == (u32)0 && checksOnlyCalls(m, caller))
                loops = (Map*)0;
            for (u32 b = (u32)0; b < caller.blocks().count(); b = b + (u32)1)
                {
                if (again)
                    break;
                IRBlock* bb = (IRBlock*)caller.blocks().get(b);
                if (loops != (Map*)0 && loops.get((Hashable*)bb) == (Object*)0)
                    continue;
                u32 i = (u32)0;
                while (i < bb.insns().count())
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    IRFunc* callee = inlinableCallee(m, n, caller);
                    if (callee == 0)
                        {
                        i = i + (u32)1;
                        continue;
                        }
                    if (callee.blocks().count() != (u32)1)
                        {
                        multiBlockInline(m, n, callee, caller, bb, i);
                        if (_failed)
                            return;
                        again = true; // the block list changed
                        break;
                        }
                    Array* spliced = spliceCall(n, callee, caller, bb);
                    if (spliced == 0)
                        {
                        i = i + (u32)1;
                        continue;
                        }
                    Array* out = new Array();
                    for (u32 k = (u32)0; k < i; k = k + (u32)1)
                        out.add(bb.insns().get(k));
                    for (u32 k = (u32)0; k < spliced.count(); k = k + (u32)1)
                        out.add(spliced.get(k));
                    for (u32 k = i + (u32)1; k < bb.insns().count(); k = k + (u32)1)
                        out.add(bb.insns().get(k));
                    bb.setInsns(out);
                    i = i + spliced.count();
                    }
                }
            }
        }

    // Params map to the call's actual operands; everything the body defines
    // gets a fresh caller value. Shared by both halves of the inliner.
    final Map* calleeRemap(IRInsn* call, IRFunc* callee)
        {
        u32 nUser = callee.params().count() - (u32)1;
        Map* remap = new Map();
        for (u32 k = (u32)0; k < nUser; k = k + (u32)1)
            remap.set((Hashable*)(IRValue*)callee.params().get(k),
                      (Object*)(IROperand*)call.ops().get(k + (u32)1));
        remap.set((Hashable*)(IRValue*)callee.params().get(nUser),
                  (Object*)(IROperand*)call.ops().get(call.ops().count() - (u32)1));
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cbb = (IRBlock*)callee.blocks().get(b);
            for (u32 i = (u32)0; i < cbb.insns().count(); i = i + (u32)1)
                {
                IRInsn* bi = (IRInsn*)cbb.insns().get(i);
                if (bi.res() != 0)
                    remap.set((Hashable*)bi.res(),
                              (Object*)IROperand.useVal(new IRValue(bi.res().ty())));
                if (bi.memRes() != 0)
                    remap.set((Hashable*)bi.memRes(),
                              (Object*)IROperand.useVal(new IRValue(bi.memRes().ty())));
                }
            }
        return remap;
        }

    // Split `bb` at the call: the prefix keeps what came before, `cont` takes
    // the suffix and the terminator, and every successor phi that named `bb`
    // now names `cont`.
    final void splitAtCall(IRBlock* bb, IRBlock* cont, u32 callIndex)
        {
        Array* keep = new Array();
        Array* tail = new Array();
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            {
            if (k < callIndex)
                keep.add(bb.insns().get(k));
            else if (k > callIndex)
                tail.add(bb.insns().get(k));
            }
        cont.setInsns(tail);
        bb.setInsns(keep);
        if (bb.term() == 0)
            return;
        IRInsn* t = bb.term();
        cont.setTerm(t);
        bb.setTerm((IRInsn*)0);
        repointSuccessorPhis(t, bb, cont);
        }

    // Inline a single-return, phi-free MULTI-block callee: the caller's block is
    // SPLIT at the call. The prefix keeps its instructions and branches into the
    // cloned callee entry; a fresh continuation takes the suffix and the
    // original terminator; the callee's one Return becomes a Branch to that
    // continuation, forwarding what it returned.
    final void multiBlockInline(IRModule* m, IRInsn* call, IRFunc* callee,
                          IRFunc* caller, IRBlock* bb, u32 callIndex)
        {
        Map* remap = calleeRemap(call, callee);

        // One fresh caller block per callee block, plus the continuation. The
        // names carry the caller's block count so two inlines cannot collide.
        u32 tag = caller.blocks().count();
        Map* blockMap = new Map();
        Array* clones = new Array();
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cbb = (IRBlock*)callee.blocks().get(b);
            String* nm = String.withCString("il");
            nm.appendFormat("%ld_", (i32)tag);
            nm.append(cbb.name() == 0 ? String.withCString("b") : cbb.name());
            IRBlock* nb = new IRBlock(nm);
            blockMap.set((Hashable*)cbb, (Object*)nb);
            clones.add((Object*)nb);
            }
        String* contName = String.withCString("il");
        contName.appendFormat("%ld_cont", (i32)tag);
        IRBlock* cont = new IRBlock(contName);

        // The continuation takes the suffix and the terminator.
        splitAtCall(bb, cont, callIndex);

        // Clone each callee block; its one Return becomes a Branch to `cont`.
        IROperand* retVal = (IROperand*)0;
        IROperand* retMem = (IROperand*)0;
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cbb = (IRBlock*)callee.blocks().get(b);
            IRBlock* nb = (IRBlock*)blockMap.get((Hashable*)cbb);
            for (u32 i = (u32)0; i < cbb.insns().count(); i = i + (u32)1)
                nb.add(cloneInsn(remap, blockMap, (IRInsn*)cbb.insns().get(i)));
            IRInsn* t = cbb.term();
            if (t == 0)
                continue;
            if (t.op().equals(String.withCString("Return")))
                {
                if (t.ops().count() >= (u32)1)
                    retMem = substBoth(remap, blockMap,
                                       (IROperand*)t.ops().get(t.ops().count() - (u32)1));
                if (call.res() != 0 && t.ops().count() >= (u32)2)
                    retVal = substBoth(remap, blockMap, (IROperand*)t.ops().get((u32)0));
                IRInsn* br = IRInsn.with(String.withCString("Branch"));
                br.add(IROperand.block(cont));
                nb.setTerm(br);
                }
            else
                {
                nb.setTerm(cloneInsn(remap, blockMap, t));
                }
            }

        // The prefix branches into the cloned entry, and the new blocks land
        // straight after it.
        IRInsn* into = IRInsn.with(String.withCString("Branch"));
        into.add(IROperand.block((IRBlock*)clones.get((u32)0)));
        bb.setTerm(into);
        clones.add((Object*)cont);
        u32 pos = self.blockIndex(caller, bb) + (u32)1;
        caller.blocks().insertAll(pos, clones);

        // Forwarding comes LAST: the suffix now living in `cont` still refers to
        // the call's result, and it has to be in the block list to be rewritten.
        if (call.res() != 0 && retVal != 0)
            self.rewriteUsesTo(caller, call.res(), retVal);
        if (call.memRes() != 0 && retMem != 0)
            self.rewriteUsesTo(caller, call.memRes(), retMem);
        }

    // Re-point every phi in `t`'s successors from `from` to `to`.
    final void repointSuccessorPhis(IRInsn* t, IRBlock* from, IRBlock* to)
        {
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() == 0)
                continue;
            IRBlock* succ = o.blk();
            for (u32 pi = (u32)0; pi < succ.phis().count(); pi = pi + (u32)1)
                {
                IRInsn* phi = (IRInsn*)succ.phis().get(pi);
                for (u32 j = (u32)0; j < phi.ops().count(); j = j + (u32)1)
                    {
                    IROperand* po = (IROperand*)phi.ops().get(j);
                    if (po.kind() != (u8)OPK_BLOCK || po.blk() != from)
                        continue;
                    phi.ops().set(j, (Object*)IROperand.block(to));
                    }
                }
            }
        }

    final IRInsn* cloneInsn(Map* remap, Map* blockMap, IRInsn* bi)
        {
        IRInsn* cl = IRInsn.with(bi.op());
        cl.setPred(bi.pred());
        cl.setCc(bi.cc());
        cl.copyDbg(bi);
        for (u32 k = (u32)0; k < bi.ops().count(); k = k + (u32)1)
            cl.add(substBoth(remap, blockMap, (IROperand*)bi.ops().get(k)));
        if (bi.res() != 0)
            cl.setRes(remappedValue(remap, bi.res()));
        if (bi.memRes() != 0)
            cl.setMemRes(remappedValue(remap, bi.memRes()));
        return cl;
        }

    // An operand in a cloned body names either a callee VALUE or a callee
    // BLOCK, and both have moved.
    final IROperand* substBoth(Map* remap, Map* blockMap, IROperand* o)
        {
        if (o.kind() == (u8)OPK_BLOCK && o.blk() != 0)
            {
            Object* nb = blockMap.get((Hashable*)o.blk());
            if (nb == 0)
                return o;
            return IROperand.block((IRBlock*)nb);
            }
        return substOperand(remap, o);
        }

    // The callee this Call can be inlined from, or 0. Every rule is the
    // original's: a plain Call to a known body that is not the caller, one
    // Return, no phis, no inline asm, no pinned locals, no aggregate-by-value
    // parameter, and a body under the size ceiling.
    final IRFunc* inlinableCallee(IRModule* m, IRInsn* n, IRFunc* caller)
        {
        if (!n.op().equals(String.withCString("Call")))
            return (IRFunc*)0;
        if (n.ops().count() < (u32)1)
            return (IRFunc*)0;
        IROperand* c = (IROperand*)n.ops().get((u32)0);
        if (c.kind() != (u8)OPK_SYM || c.name() == 0)
            return (IRFunc*)0;
        IRFunc* callee = self.funcNamed(m, c.name());
        if (callee == 0 || callee == caller)
            return (IRFunc*)0;
        // A subscript check inlines only after bounds-elide, and then nothing else.
        bool isCheck = c.name().hasPrefix(String.withCString("_xt_check_")) && !c.name().hasSuffix(String.withCString("_trap"));
        if (isCheck != _inlineChecks)
            return (IRFunc*)0;
        if (callee.blocks().count() == (u32)0)
            return (IRFunc*)0;
        bool multi = callee.blocks().count() > (u32)1;
        // A pinned local is a frame SLOT the callee takes the address of. It can
        // come across: every back end lays these out ITSELF, in list order, from
        // the local's TYPE — none reads the recorded offset — so the callee's
        // own frame offset need not travel. spliceCall gives each a fresh caller
        // value and adds it to the caller. Single-block only; the multi-block
        // path wires the CFG through a different splice that does not do this.
        // …and only where the target can address a frame temp reliably. The
        // 6502 cannot — struct_byval_rvalue came back wrong when this was
        // allowed there — the same constraint the aggregate-parameter knob
        // describes, so it shares it.
        if ((multi || !_profile.inlineAggParams()) && callee.pinned().count() > (u32)0)
            return (IRFunc*)0;
        u32 returns = (u32)0;
        u32 total = (u32)0;
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)callee.blocks().get(b);
            if (bb.phis().count() > (u32)0)
                return (IRFunc*)0;
            total = total + bb.insns().count();
            if (bb.term() != 0 && bb.term().op().equals(String.withCString("Return")))
                returns = returns + (u32)1;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                String* op = ((IRInsn*)bb.insns().get(i)).op();
                if (op.equals(String.withCString("Asm")))
                    return (IRFunc*)0; // {{XTLOCAL}}
                // A MULTI-block callee that calls anything could be (mutually)
                // recursive, and inlining it would re-expose the call and grow
                // for ever. Multi-block inlining is leaves only.
                if (!multi)
                    continue;
                // …except the subscript checks' report, which never returns:
                // a check (Checked.xc) inlines as a compare with a cold trap.
                if (callsTrap((IRInsn*)bb.insns().get(i)))
                    continue;
                if (isCallOp(op) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")))
                    return (IRFunc*)0;
                }
            }
        if (returns != (u32)1)
            return (IRFunc*)0;
        if (total > _profile.inlineMax())
            return (IRFunc*)0; // the size ceiling (64 unless -Fli says otherwise)

        // The call's shape must match the parameter list exactly: params are
        // [user…, Mem] and the operands [callee, args…, memIn]. A variadic or
        // cloaked call does not, and is not inlinable.
        u32 nParams = callee.params().count();
        if (nParams < (u32)1)
            return (IRFunc*)0;
        u32 nUser = nParams - (u32)1;
        if (n.ops().count() != (u32)2 + nUser)
            return (IRFunc*)0;
        // An aggregate BY VALUE is only ever read through AddrOf(param); after
        // inlining that is AddrOf of the caller's loaded temp, which is not
        // reliably addressable. Pass it through a real call.
        if (!_profile.inlineAggParams())
            for (u32 k = (u32)0; k < nUser; k = k + (u32)1)
                if (((IRValue*)callee.params().get(k)).ty().hasPrefix(String.withCString("Agg(")))
                    return (IRFunc*)0;
        return callee;
        }

    // Clone the callee's one block with its values substituted, and forward the
    // call's result and memory token to what the Return hands back.
    final Array* spliceCall(IRInsn* call, IRFunc* callee, IRFunc* caller, IRBlock* bb)
        {
        IRBlock* cb = (IRBlock*)callee.blocks().get((u32)0);
        u32 nUser = callee.params().count() - (u32)1;

        Map* remap = new Map(); // callee value -> caller OPERAND
        for (u32 k = (u32)0; k < nUser; k = k + (u32)1)
            remap.set((Hashable*)(IRValue*)callee.params().get(k),
                      (Object*)(IROperand*)call.ops().get(k + (u32)1));
        remap.set((Hashable*)(IRValue*)callee.params().get(nUser),
                  (Object*)(IROperand*)call.ops().get(call.ops().count() - (u32)1));

        // The callee's pinned locals become the caller's. A pinned local is a
        // frame slot rather than an instruction result, so it never appears in
        // the body walk below: give each a fresh caller value, map it, and add
        // it. The back ends re-lay them out from the type, so the offset
        // travels as 0.
        for (u32 i = (u32)0; i < callee.pinned().count(); i = i + (u32)1)
            {
            IRPinned* pl = (IRPinned*)callee.pinned().get(i);
            IRValue* nv = new IRValue(pl.ty());
            remap.set((Hashable*)pl.val(), (Object*)IROperand.useVal(nv));
            caller.addPinned(IRPinned.with(nv, pl.ty(), (u32)0, pl.esc()));
            }

        // A fresh caller value for everything the body defines.
        for (u32 i = (u32)0; i < cb.insns().count(); i = i + (u32)1)
            {
            IRInsn* bi = (IRInsn*)cb.insns().get(i);
            if (bi.res() != 0)
                remap.set((Hashable*)bi.res(), (Object*)IROperand.useVal(new IRValue(bi.res().ty())));
            if (bi.memRes() != 0)
                remap.set((Hashable*)bi.memRes(), (Object*)IROperand.useVal(new IRValue(bi.memRes().ty())));
            }

        Array* spliced = new Array();
        for (u32 i = (u32)0; i < cb.insns().count(); i = i + (u32)1)
            {
            IRInsn* bi = (IRInsn*)cb.insns().get(i);
            IRInsn* cl = IRInsn.with(bi.op());
            cl.setPred(bi.pred());
            cl.setCc(bi.cc());
            cl.copyDbg(bi);
            for (u32 k = (u32)0; k < bi.ops().count(); k = k + (u32)1)
                cl.add(substOperand(remap, (IROperand*)bi.ops().get(k)));
            if (bi.res() != 0)
                cl.setRes(remappedValue(remap, bi.res()));
            if (bi.memRes() != 0)
                cl.setMemRes(remappedValue(remap, bi.memRes()));
            spliced.add((Object*)cl);
            }

        // The Return's operands are [value?, mem] — memory last, value first.
        IRInsn* ret = cb.term();
        if (ret == 0)
            return (Array*)0;
        IROperand* retMem = (IROperand*)0;
        if (ret.ops().count() >= (u32)1)
            retMem = substOperand(remap, (IROperand*)ret.ops().get(ret.ops().count() - (u32)1));
        IROperand* retVal = (IROperand*)0;
        if (call.res() != 0)
            {
            if (ret.ops().count() < (u32)2)
                return (Array*)0; // a value was expected
            retVal = substOperand(remap, (IROperand*)ret.ops().get((u32)0));
            }
        if (call.res() != 0 && retVal != 0)
            self.rewriteUsesTo(caller, call.res(), retVal);
        if (call.memRes() != 0 && retMem != 0)
            self.rewriteUsesTo(caller, call.memRes(), retMem);
        return spliced;
        }

    final IROperand* substOperand(Map* remap, IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return o;
        Object* r = remap.get((Hashable*)o.val());
        if (r == 0)
            return o;
        return (IROperand*)r;
        }

    final IRValue* remappedValue(Map* remap, IRValue* v)
        {
        Object* r = remap.get((Hashable*)v);
        if (r == 0)
            return v;
        return ((IROperand*)r).val();
        }
    }
