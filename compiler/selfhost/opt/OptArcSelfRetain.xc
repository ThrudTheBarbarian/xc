// OptArcSelfRetain.xc — the ArcSelfRetain pass, ported from src/xtc/ir/XTIROptArcSelfRetain.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptVaArgExpand>

    class Opt (ArcSelfRetain)
    {
    // ── arc-self-retain ──────────────────────────────────────────────────
    //
    // A method retains its receiver on entry and releases it on every exit, so
    // an opaque call inside cannot free the object out from under it. When
    // nothing the method reaches can release anything, that bracket is pure
    // cost and comes out.
    //
    // "Nothing it reaches" is a FIXPOINT, not a scan: a method is inert until
    // proved otherwise, and calling a function that is later found guilty makes
    // it guilty in the next round.
    final void arcSelfRetain(IRModule* m)
        {
        Array* funcs = m.funcs();
        Array* brackets = new Array(); // parallel to funcs: Array@ or 0
        for (u32 i = (u32)0; i < funcs.count(); i = i + (u32)1)
            brackets.add((Object*)selfBracket((IRFunc*)funcs.get(i)));

        Array* notInert = new Array(); // IRFunc@
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 i = (u32)0; i < funcs.count(); i = i + (u32)1)
                {
                IRFunc* fn = (IRFunc*)funcs.get(i);
                if (hasFunc(notInert, fn))
                    continue;
                if (isInert(m, fn, (Array*)brackets.get(i), notInert))
                    continue;
                notInert.add((Object*)fn);
                changed = true;
                }
            }

        for (u32 i = (u32)0; i < funcs.count(); i = i + (u32)1)
            {
            IRFunc* fn = (IRFunc*)funcs.get(i);
            Array* b = (Array*)brackets.get(i);
            if (b == 0 || hasFunc(notInert, fn))
                continue;
            elideBracket(fn, b);
            }
        }

    // The receiver's Retain + its Releases, or 0. The Retain must be the FIRST
    // entry instruction and the ONLY retain of that parameter — a strong-local
    // copy's retain is not first, and excluding it is what keeps this from
    // eliding a bracket that is doing real work.
    final Array* selfBracket(IRFunc* fn)
        {
        if (fn.name() == 0)
            return (Array*)0;
        if (fn.name().indexOfByte((u8)'$') == String.notFound())
            return (Array*)0;
        if (fn.blocks().count() == (u32)0)
            return (Array*)0;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        if (entry.insns().count() == (u32)0)
            return (Array*)0;
        IRInsn* first = (IRInsn*)entry.insns().get((u32)0);
        if (!first.op().equals(String.withCString("Retain")))
            return (Array*)0;
        if (first.ops().count() < (u32)1)
            return (Array*)0;
        IROperand* o0 = (IROperand*)first.ops().get((u32)0);
        if (o0.kind() != (u8)OPK_USE)
            return (Array*)0;
        IRValue* recv = o0.val();
        if (!isParam(fn, recv))
            return (Array*)0;
        if (!self.isStructPtr(recv.ty()))
            return (Array*)0;

        u32 retains = (u32)0;
        Array* bracket = new Array();
        bracket.add((Object*)first);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.ops().count() < (u32)1)
                    continue;
                IROperand* o = (IROperand*)n.ops().get((u32)0);
                if (o.kind() != (u8)OPK_USE || o.val() != recv)
                    continue;
                if (n.op().equals(String.withCString("Retain")))
                    retains = retains + (u32)1;
                if (n.op().equals(String.withCString("Release")))
                    bracket.add((Object*)n);
                }
            }
        if (retains != (u32)1)
            return (Array*)0;
        if (bracket.count() < (u32)2)
            return (Array*)0; // 1 retain + >= 1 release
        return bracket;
        }

    // Inert = releases nothing, dispatches nothing it cannot see, and calls only
    // functions that are themselves inert. Its own bracket does not count: it is
    // net zero on the receiver.
    final bool isInert(IRModule* m, IRFunc* fn, Array* bracket, Array* notInert)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (bracket != 0 && self.hasInsn(bracket, n))
                    continue;
                String* op = n.op();
                if (op.equals(String.withCString("Release")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")))
                    return false;
                if (!self.isCallOp(op))
                    continue;
                if (n.ops().count() < (u32)1)
                    return false;
                IROperand* c = (IROperand*)n.ops().get((u32)0);
                if (c.kind() != (u8)OPK_SYM || c.name() == 0)
                    return false;
                IRFunc* g = self.funcNamed(m, c.name());
                if (g == 0 || hasFunc(notInert, g))
                    return false;
                }
            }
        return true;
        }

    final bool callsTrap(IRInsn* n)
        {
        if (!n.op().equals(String.withCString("Call")) || n.ops().count() < (u32)1)
            return false;
        IROperand* c = (IROperand*)n.ops().get((u32)0);
        return c.kind() == (u8)OPK_SYM && c.name() != 0 && c.name().hasPrefix(String.withCString("_xt_check_"))
            && c.name().hasSuffix(String.withCString("_trap"));
        }

    // Drop the bracket, threading the memory token past each removed op so a
    // later use rewires to the first surviving token.
    final void elideBracket(IRFunc* fn, Array* remove)
        {
        Map* bypass = new Map();
        for (u32 i = (u32)0; i < remove.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)remove.get(i);
            if (n.ops().count() < (u32)2 || n.memRes() == 0)
                continue;
            IROperand* memIn = (IROperand*)n.ops().get((u32)1);
            if (memIn.kind() != (u8)OPK_USE)
                continue;
            bypass.set((Hashable*)n.memRes(), (Object*)memIn.val());
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                bypassUses((IRInsn*)bb.phis().get(i), bypass);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (hasInsn(remove, n))
                    continue; // it is on its way out
                bypassUses(n, bypass);
                }
            if (bb.term() != 0)
                bypassUses(bb.term(), bypass);
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!self.hasInsn(remove, n))
                    keep.add((Object*)n);
                }
            bb.setInsns(keep);
            }
        }

    final void bypassUses(IRInsn* n, Map* bypass)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            if (bypass.get((Hashable*)o.val()) == 0)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(resolveBypass(bypass, o.val())));
            }
        }

    // A removed op's memory input may itself have been removed, so the chain is
    // followed to the first token that survives.
    final IRValue* resolveBypass(Map* bypass, IRValue* v)
        {
        IRValue* cur = v;
        for (u32 d = (u32)0; d < (u32)64; d = d + (u32)1)
            {
            Object* nxt = bypass.get((Hashable*)cur);
            if (nxt == 0)
                return cur;
            cur = (IRValue*)nxt;
            }
        return cur;
        }

    final bool isParam(IRFunc* fn, IRValue* v)
        {
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            if ((IRValue*)fn.params().get(i) == v)
                return true;
        return false;
        }

    final bool hasFunc(Array* fs, IRFunc* f)
        {
        for (u32 i = (u32)0; i < fs.count(); i = i + (u32)1)
            if ((IRFunc*)fs.get(i) == f)
                return true;
        return false;
        }

    // ── arc-pair ─────────────────────────────────────────────────────────
    //
    // A value retained and then released, with nothing between them that can
    // free or change anything (no call, no store, no other release), keeps
    // the count it had: the pair does nothing and both go. Lowering makes this
    // for a temporary that is only looked at: `(Number*)a.get(i) == v` retains
    // the element, checks the cast, compares, and releases it. With the pair
    // gone, a loop like that writes no memory, and LICM can hoist the loads a
    // bounds check makes of the array's header (issue #28).
    //
    // The release may name the value through casts, or through the phi a
    // downcast leaves: the cast value where it held, null where the value was
    // null (on the edge taken when it tests null). Every path from the retain
    // must reach the release, or end in Unreachable (a failed check's trap),
    // without a Return and without coming round to the retain again. The
    // memory tokens the pair made become the ones it took.
    final void arcPairElide(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // The definitions, once a function (a pair's removal takes out
            // only its own two instructions, which define no value but their
            // memory tokens).
            _apDefs = new Map();
            _apPhiBlock = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* q = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < q.phis().count(); i = i + (u32)1)
                    {
                    IRInsn* p = (IRInsn*)q.phis().get(i);
                    if (p.res() != (IRValue*)0)
                        {
                        _apDefs.set((Hashable*)p.res(), (Object*)p);
                        _apPhiBlock.set((Hashable*)p.res(), (Object*)q);
                        }
                    }
                for (u32 i = (u32)0; i < q.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)q.insns().get(i);
                    if (n.res() != (IRValue*)0)
                        _apDefs.set((Hashable*)n.res(), (Object*)n);
                    }
                }
            Map* rename = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                u32 i = (u32)0;
                while (i < bb.insns().count())
                    {
                    IRInsn* r = (IRInsn*)bb.insns().get(i);
                    IROperand* xo = r.ops().count() >= (u32)2 ? (IROperand*)r.ops().get((u32)0) : (IROperand*)0;
                    if (!r.op().equals(String.withCString("Retain")) || xo == (IROperand*)0
                        || xo.kind() != (u8)OPK_USE || xo.val() == (IRValue*)0 || r.memRes() == (IRValue*)0)
                        {
                        i = i + (u32)1;
                        continue;
                        }
                    IRInsn* rel = apFindRelease(bb, i, xo.val());
                    if (rel == (IRInsn*)0)
                        {
                        i = i + (u32)1;
                        continue;
                        }
                    IROperand* rm = (IROperand*)r.ops().get(r.ops().count() - (u32)1);
                    IROperand* lm = (IROperand*)rel.ops().get(rel.ops().count() - (u32)1);
                    rename.set((Hashable*)r.memRes(), (Object*)rm.val());
                    if (rel.memRes() != (IRValue*)0)
                        rename.set((Hashable*)rel.memRes(), (Object*)lm.val());
                    for (u32 k = (u32)0; k < _apRelBlock.insns().count(); k = k + (u32)1)
                        if ((IRInsn*)_apRelBlock.insns().get(k) == rel)
                            {
                            _apRelBlock.insns().removeAt(k);
                            break;
                            }
                    bb.insns().removeAt(i);   // the next instruction is at i now
                    }
                }
            if (rename.count() > (u32)0)
                apRenameAll(fn, rename);
            }
        }

    final void apRenameAll(IRFunc* fn, Map* rename)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                apRename((IRInsn*)bb.phis().get(i), rename);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                apRename((IRInsn*)bb.insns().get(i), rename);
            if (bb.term() != (IRInsn*)0)
                apRename(bb.term(), rename);
            }
        }

    // A memory token the pair made becomes the one it took (followed through
    // a chain of them).
    final void apRename(IRInsn* n, Map* rename)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            IRValue* to = o.val();
            for (u32 hop = (u32)0; hop < (u32)64; hop = hop + (u32)1)
                {
                Object* next = rename.get((Hashable*)to);
                if (next == (Object*)0)
                    break;
                to = (IRValue*)next;
                }
            if (to != o.val())
                n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    // Does an instruction stop the pair: may it free, write or change a count?
    final bool apBlocks(IRInsn* n)
        {
        String* op = n.op();
        if (op.equals(String.withCString("Retain")))
            return false;    // another count going up frees nothing
        // A subscript check frees nothing (the reference explains).
        if (op.equals(String.withCString("Call")) && n.ops().count() > (u32)0)
            {
            IROperand* c = (IROperand*)n.ops().get((u32)0);
            if (c.kind() == (u8)OPK_SYM && c.name() != (String*)0 && c.name().hasPrefix(String.withCString("_xt_check_")))
                return false;
            }
        // Every call, an indirect one too (lrcWritesMemory leaves those out).
        return self.lrcWritesMemory(op) || op.hasPrefix(String.withCString("Call"))
            || op.equals(String.withCString("LoadVolatile")) || op.equals(String.withCString("Return"));
        }

    // Is v the retained value x, through casts?
    final bool apSameObject(IRFunc* fn, IRValue* v, IRValue* x, Map* defs)
        {
        for (u32 hop = (u32)0; hop < (u32)8 && v != (IRValue*)0; hop = hop + (u32)1)
            {
            if (v == x)
                return true;
            IRInsn* d = (IRInsn*)defs.get((Hashable*)v);
            if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Bitcast")) || d.ops().count() < (u32)1)
                return false;
            IROperand* o = (IROperand*)d.ops().get((u32)0);
            if (o.kind() != (u8)OPK_USE)
                return false;
            v = o.val();
            }
        return false;
        }

    // Is v a null pointer constant (IntToPtr of a zero Const or immediate)?
    final bool apIsNull(IRValue* v, Map* defs)
        {
        IRInsn* d = (IRInsn*)defs.get((Hashable*)v);
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("IntToPtr")) || d.ops().count() < (u32)1)
            return false;
        IROperand* o = (IROperand*)d.ops().get((u32)0);
        if (o.kind() == (u8)OPK_IMMI)
            return o.imm() == (i64)0;
        if (o.kind() != (u8)OPK_USE)
            return false;
        IRInsn* c = (IRInsn*)defs.get((Hashable*)o.val());
        return c != (IRInsn*)0 && c.op().equals(String.withCString("Const")) && c.ops().count() == (u32)1
            && ((IROperand*)c.ops().get((u32)0)).kind() == (u8)OPK_IMMI && ((IROperand*)c.ops().get((u32)0)).imm() == (i64)0;
        }

    // Does block p reach s only when x is null: p ends in CondBranch on
    // ICmp EQ (x, null) with s as its true target (and not its false one)?
    final bool apNullEdge(IRBlock* p, IRBlock* s, IRValue* x, Map* defs)
        {
        IRInsn* t = p.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3)
            return false;
        if (((IROperand*)t.ops().get((u32)1)).blk() != s || ((IROperand*)t.ops().get((u32)2)).blk() == s)
            return false;
        IROperand* c = (IROperand*)t.ops().get((u32)0);
        if (c.kind() != (u8)OPK_USE)
            return false;
        IRInsn* cmp = (IRInsn*)defs.get((Hashable*)c.val());
        if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || cmp.pred() == (String*)0
            || !cmp.pred().equals(String.withCString("EQ")) || cmp.ops().count() < (u32)2)
            return false;
        IROperand* a = (IROperand*)cmp.ops().get((u32)0);
        IROperand* bnull = (IROperand*)cmp.ops().get((u32)1);
        if (a.kind() != (u8)OPK_USE || bnull.kind() != (u8)OPK_USE)
            return false;
        return apSameObject((IRFunc*)0, a.val(), x, defs) && apIsNull(bnull.val(), defs);
        }

    // Does Release operand v name x: x through casts, or a phi of casts of x
    // and nulls, each null on an edge taken only when x is null?
    final bool apNames(IRValue* v, IRValue* x, Map* defs, Map* phiBlock)
        {
        if (apSameObject((IRFunc*)0, v, x, defs))
            return true;
        IRInsn* d = (IRInsn*)defs.get((Hashable*)v);
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Phi")))
            return false;
        IRBlock* s = (IRBlock*)phiBlock.get((Hashable*)v);
        for (u32 k = (u32)0; k + (u32)1 < d.ops().count(); k = k + (u32)2)
            {
            IRBlock* p = ((IROperand*)d.ops().get(k)).blk();
            IROperand* o = (IROperand*)d.ops().get(k + (u32)1);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                return false;
            if (apSameObject((IRFunc*)0, o.val(), x, defs))
                continue;
            if (apIsNull(o.val(), defs) && s != (IRBlock*)0 && apNullEdge(p, s, x, defs))
                continue;
            return false;
            }
        return true;
        }

    // The Release that ends x's Retain at (bb, at), if every path from it
    // reaches that Release, or Unreachable, with nothing in between that
    // stops the pair; else 0.
    final IRInsn* apFindRelease(IRBlock* bb, u32 at, IRValue* x)
        {
        Map* defs = _apDefs;
        Map* phiBlock = _apPhiBlock;
        IRInsn* found = (IRInsn*)0;
        Array* work = new Array();
        Array* seen = new Array();
        Array* from = new Array();      // where each block's scan starts
        work.add((Object*)bb);
        from.add((Object*)Number.withU32(at + (u32)1));
        while (work.count() > (u32)0)
            {
            IRBlock* q = (IRBlock*)work.get(work.count() - (u32)1);
            u32 start = ((Number*)from.get(from.count() - (u32)1)).asU32();
            work.removeAt(work.count() - (u32)1);
            from.removeAt(from.count() - (u32)1);
            bool stopped = false;
            for (u32 i = start; i < q.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)q.insns().get(i);
                if (n.op().equals(String.withCString("Release")) && n.ops().count() >= (u32)2
                    && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                    && apNames(((IROperand*)n.ops().get((u32)0)).val(), x, defs, phiBlock))
                    {
                    if (found != (IRInsn*)0 && found != n)
                        return (IRInsn*)0;          // two releases: not one pair
                    found = n;
                    _apRelBlock = q;
                    stopped = true;
                    break;
                    }
                if (apBlocks(n))
                    return (IRInsn*)0;
                }
            if (stopped)
                continue;
            IRInsn* t = q.term();
            if (t == (IRInsn*)0)
                return (IRInsn*)0;
            if (t.op().equals(String.withCString("Unreachable")))
                continue;
            if (!t.op().equals(String.withCString("Branch")) && !t.op().equals(String.withCString("CondBranch")))
                return (IRInsn*)0;         // a Return, or anything else, before the release
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                IRBlock* s = o.blk();
                if (s == bb)
                    return (IRInsn*)0;     // round to the retain again
                if (self.hasBlock(seen, s))
                    continue;
                seen.add((Object*)s);
                work.add((Object*)s);
                from.add((Object*)Number.withU32((u32)0));
                }
            }
        return found;
        }
    }
