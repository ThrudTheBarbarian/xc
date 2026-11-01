// OptLoopRotate.xc — the LoopRotate pass, ported from src/xtc/ir/XTIROptLoopRotate.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (LoopRotate)
    {

    // ── loop-rotate ──────────────────────────────────────────────────────
    //
    // A top-tested loop becomes bottom-tested: the header's guard is PEELED —
    // evaluated once on the preheader's values — and a copy of it moves to the
    // bottom of the body, where it drives a conditional back edge. The body
    // then costs one conditional branch per iteration instead of a branch to
    // the header plus a branch back.
    //
    // The header's phis move into the body (a rotated loop is entered only from
    // the preheader), and any carried value read after the loop gets an exit phi
    // in E covering both the peeled path and the loop path.
    final void loopRotate(IRModule* m)
        {
        if (!_profile.loopRotate())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop at a time, re-recognised from the live CFG: a rotated
            // loop's back edge is conditional and no longer matches, so the
            // bound is only a backstop.
            u32 iter = (u32)0;
            while (iter < (u32)512 && rotOne(fn))
                iter = iter + (u32)1;
            }
        }

    final bool rotInRegion(IRBlock* b)
        {
        return _rotR != (Array*)0 && self.hasBlock(_rotR, b);
        }

    final bool rotOne(IRFunc* fn)
        {
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defBlk.set((Hashable*)n.res(), (Object*)bb);
                if (n.memRes() != (IRValue*)0)
                    defBlk.set((Hashable*)n.memRes(), (Object*)bb);
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            if (!rotRecognise(fn, (IRBlock*)fn.blocks().get(b), defBlk))
                continue;
            rotApply(fn);
            return true;
            }
        // Then a loop whose test is a short-circuit chain. Mirrors the original.
        for (u32 b = (u32)0; _profile.loopRotateChain() && b < fn.blocks().count(); b = b + (u32)1)
            {
            if (!rcRecognise(fn, (IRBlock*)fn.blocks().get(b), defBlk))
                continue;
            rcApply(fn);
            return true;
            }
        return false;
        }

    final bool rotRecognise(IRFunc* fn, IRBlock* H, Map* defBlk)
        {
        _rotH = (IRBlock*)0;
        _rotB = (IRBlock*)0;
        _rotL = (IRBlock*)0;
        _rotR = (Array*)0;
        _rotE = (IRBlock*)0;
        _rotCond = (IRValue*)0;
        _rotEntryTrue = false;
        if (H.phis().count() == (u32)0)
            return false;
        // A header carrying a VECTOR accumulator phi is an already-vectorised
        // loop; rotating it would duplicate that phi, which the backend's
        // in-place accumulate coalescing cannot represent — unless the guard
        // holds on entry (below), when the rotated loop needs no exit phi.
        bool hasVecPhi = false;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && self.isVectorType(p.res().ty()))
                hasVecPhi = true;
            }
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* cb = defBlk.get((Hashable*)c0.val());
        if (cb == (Object*)0 || (IRBlock*)cb != H)
            return false; // guard computed in H
        // …by an INSTRUCTION. A condition that is itself one of H's phis
        // (`while (again)`) has no guard to clone: the rewrite removes the
        // phi and left both branches testing a value that no longer existed.
        // Mirrors the original.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            if (((IRInsn*)H.phis().get(i)).res() == c0.val())
                return false;

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        if (t0 == (IRBlock*)0 || t1 == (IRBlock*)0 || t0 == t1)
            return false;
        // The body is a REGION, not only a single block: B, the successor of
        // H that starts it, and everything reachable from B without passing
        // through H. It must be left only by going back to H, and exactly one
        // of its blocks — the latch L — does that, with a plain branch. A
        // one-block body is the case L == B. Mirrors the original.
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        IRBlock* L = (IRBlock*)0;
        Array* R = (Array*)0;
        for (u32 side = (u32)0; side < (u32)2 && B == (IRBlock*)0; side = side + (u32)1)
            {
            IRBlock* b = side == (u32)0 ? t0 : t1;
            IRBlock* e = side == (u32)0 ? t1 : t0;
            if (b == H || b.phis().count() != (u32)0)
                continue;
            Array* reg = new Array();
            reg.add((Object*)b);
            Array* work = new Array();
            work.add((Object*)b);
            bool okR = true;
            IRBlock* latchBlk = (IRBlock*)0;
            while (work.count() > (u32)0 && okR)
                {
                IRBlock* x = (IRBlock*)work.get(work.count() - (u32)1);
                work.removeAt(work.count() - (u32)1);
                IRInsn* xt = x.term();
                if (xt == (IRInsn*)0)
                    {
                    okR = false;
                    break;
                    }
                for (u32 k = (u32)0; k < xt.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)xt.ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                        continue;
                    IRBlock* sb = o.blk();
                    if (sb == H)
                        {
                        // The one way back, and an unconditional one.
                        if (latchBlk != (IRBlock*)0 || !xt.op().equals(String.withCString("Branch")))
                            okR = false;
                        latchBlk = x;
                        continue;
                        }
                    if (sb == e)
                        {
                        okR = false; // a second exit
                        break;
                        }
                    if (!self.hasBlock(reg, sb))
                        {
                        reg.add((Object*)sb);
                        work.add((Object*)sb);
                        }
                    }
                }
            if (!okR || latchBlk == (IRBlock*)0 || self.hasBlock(reg, e))
                continue;
            // Nothing outside the region may enter it except H into B.
            bool closed = true;
            for (u32 r = (u32)0; r < reg.count() && closed; r = r + (u32)1)
                {
                IRBlock* x = (IRBlock*)reg.get(r);
                Array* ps = self.predsOfBlock(fn, x);
                for (u32 q = (u32)0; q < ps.count(); q = q + (u32)1)
                    {
                    IRBlock* pb = (IRBlock*)ps.get(q);
                    if (!self.hasBlock(reg, pb) && !(x == b && pb == H))
                        closed = false;
                    }
                }
            if (!closed)
                continue;
            // A multi-block body with no branching of its own — the chain of
            // blocks an unrolled body is split into — is left as it was: the
            // one-block rule never rotated it, and rotating it measured slower
            // (mem_copy on the x86-64 host, 1.08 s -> 1.41 s) with no branch
            // saved. Rotation pays where the body branches (an `if`, an inner
            // loop): there it removes the trip through the header.
            if (reg.count() > (u32)1)
                {
                bool branches = false;
                for (u32 r = (u32)0; r < reg.count(); r = r + (u32)1)
                    if (!((IRBlock*)reg.get(r)).term().op().equals(String.withCString("Branch")))
                        branches = true;
                if (!branches)
                    continue;
                }
            B = b;
            E = e;
            L = latchBlk;
            R = reg;
            }
        if (B == (IRBlock*)0 || B == E || E == (IRBlock*)0)
            return false;

        // B's only predecessor is H, and H's are exactly the preheader and L.
        if (predsOfBlock(fn, B).count() != (u32)1)
            return false;
        Array* hp = self.predsOfBlock(fn, H);
        if (hp.count() != (u32)2 || !self.hasBlock(hp, L))
            return false;
        // rotUsedOutsideLoop reads these two, so they are set before the
        // escape test below (they are cleared again on every bail).
        _rotH = H;
        _rotR = R;

        // Every header non-phi instruction is part of the guard: safe to
        // duplicate, referencing no B-defined value (the peeled copy must be
        // computable from preheader data), and with its result read only inside
        // H — otherwise the body would depend on something the rotation would
        // have to thread out.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (!rotDupSafe(n.op()))
                return false;
            for (u32 o = (u32)0; o < n.ops().count(); o = o + (u32)1)
                {
                IROperand* op = (IROperand*)n.ops().get(o);
                if (op.kind() != (u8)OPK_USE)
                    continue;
                Object* db = defBlk.get((Hashable*)op.val());
                if (db != (Object*)0 && self.hasBlock(R, (IRBlock*)db))
                    return false;
                }
            if (n.res() != (IRValue*)0 && rotUsedOutside(fn, n.res(), H, H))
                return false;
            }

        // Each header phi is a clean two-way merge.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            }

        // A header phi whose BACK-EDGE value is computed by a header guard is a
        // loop-carried recurrence the rotation cannot thread: the guard (e.g. the
        // `n - 1` of `while (n-- > 0)`) is duplicated, but the phi still reads the
        // original H-defined value, so the variable never advances and the loop
        // runs forever (bug 02). The condition modifies the induction variable, so
        // the "guard result used only in H" test above passes — the phi's own
        // back-edge use is in H — yet rotation is still unsound. Bail.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)p.ops().get(k);
                IROperand* vo = (IROperand*)p.ops().get(k + (u32)1);
                if (bo.blk() == L && vo.kind() == (u8)OPK_USE)
                    {
                    Object* db = defBlk.get((Hashable*)vo.val());
                    if (db != (Object*)0 && (IRBlock*)db == H)
                        return false;
                    }
                }
            }

        // If any carried value is read after the loop, an exit phi is
        // materialised in E — which then must have no phis of its own and must
        // be reached only from H before the rotation.
        bool anyEscape = false;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (rotUsedOutsideLoop(fn, p.res()))
                {
                anyEscape = true;
                break;
                }
            }
        if (anyEscape)
            {
            if (E.phis().count() != (u32)0)
                return false;
            Array* ep = self.predsOfBlock(fn, E);
            if (ep.count() != (u32)1 || (IRBlock*)ep.get((u32)0) != H)
                return false;
            }

        // Whether the guard holds on the entry values, so the loop runs at
        // least once (`for (k = 0; k < 32; k++)`): then the rotated loop needs
        // no zero-trip path and no exit phi, so a vector accumulator phi is not
        // duplicated. As the reference.
        bool entryTrue = false;
        IRInsn* condInsn = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).res() == c0.val())
                condInsn = (IRInsn*)H.insns().get(i);
        if (condInsn != (IRInsn*)0 && condInsn.op().equals(String.withCString("ICmp")) &&
            condInsn.ops().count() == (u32)2 && E.phis().count() == (u32)0)
            {
            Array* ep = self.predsOfBlock(fn, E);
            Map* defs = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    if (n.res() != (IRValue*)0)
                        defs.set((Hashable*)n.res(), (Object*)n);
                    }
                }
            i64 va = (i64)0;
            i64 vb = (i64)0;
            bool known = ep.count() == (u32)1 && (IRBlock*)ep.get((u32)0) == H;
            for (u32 k = (u32)0; k < (u32)2 && known; k = k + (u32)1)
                {
                IROperand* o = (IROperand*)condInsn.ops().get(k);
                // A header phi stands for its entry value.
                if (o.kind() == (u8)OPK_USE)
                    for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
                        {
                        IRInsn* phi = (IRInsn*)H.phis().get(i);
                        if (phi.res() != o.val())
                            continue;
                        for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                            if (((IROperand*)phi.ops().get(q)).blk() != L)
                                o = (IROperand*)phi.ops().get(q + (u32)1);
                        }
                known = rotConst(o, defs, (u32)0);
                if (k == (u32)0) va = _rcVal; else vb = _rcVal;
                }
            if (known)
                {
                String* pr = condInsn.pred();
                if (pr != (String*)0)
                    {
                    if (pr.equals(String.withCString("EQ"))) entryTrue = va == vb;
                    else if (pr.equals(String.withCString("NE"))) entryTrue = va != vb;
                    else if (pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("ULT"))) entryTrue = va < vb;
                    else if (pr.equals(String.withCString("SGT")) || pr.equals(String.withCString("UGT"))) entryTrue = va > vb;
                    else if (pr.equals(String.withCString("SLE")) || pr.equals(String.withCString("ULE"))) entryTrue = va <= vb;
                    else if (pr.equals(String.withCString("SGE")) || pr.equals(String.withCString("UGE"))) entryTrue = va >= vb;
                    }
                // The branch must go to the body when the guard holds.
                if (((IROperand*)term.ops().get((u32)1)).blk() != B)
                    entryTrue = false;
                }
            // Every escaping value must be a value the latch computes.
            for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)H.phis().get(i);
                for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                    if (((IROperand*)phi.ops().get(q)).blk() == L &&
                        ((IROperand*)phi.ops().get(q + (u32)1)).kind() != (u8)OPK_USE)
                        entryTrue = false;
                }
            }
        if (hasVecPhi && !entryTrue)
            return false;

        _rotH = H;
        _rotB = B;
        _rotL = L;
        _rotE = E;
        _rotCond = c0.val();
        _rotEntryTrue = entryTrue;
        return true;
        }

    // A small non-negative constant an operand is known to hold (into
    // _rcVal): an immediate, a Const, or an extension or truncation of one,
    // within [0, 2^31) and what its type holds as a positive value. As the
    // reference's rotConst.
    final bool rotConst(IROperand* o, Map* defs, u32 depth)
        {
        if (depth > (u32)4 || o == (IROperand*)0)
            return false;
        i64 v = (i64)0;
        String* t = (String*)0;
        if (o.kind() == (u8)OPK_IMMI)
            {
            v = o.imm();
            t = o.ty();
            }
        else if (o.kind() == (u8)OPK_USE)
            {
            Object* dobj = defs.get((Hashable*)o.val());
            if (dobj == (Object*)0)
                return false;
            IRInsn* d = (IRInsn*)dobj;
            if (d.ops().count() < (u32)1)
                return false;
            if (d.op().equals(String.withCString("Const")))
                {
                IROperand* c = (IROperand*)d.ops().get((u32)0);
                if (c.kind() != (u8)OPK_IMMI)
                    return false;
                v = c.imm();
                }
            else if (d.op().equals(String.withCString("ZExt")) || d.op().equals(String.withCString("SExt")) ||
                     d.op().equals(String.withCString("Trunc")))
                {
                if (!rotConst((IROperand*)d.ops().get((u32)0), defs, depth + (u32)1))
                    return false;
                v = _rcVal;
                }
            else
                return false;
            t = d.res().ty();
            }
        else
            return false;
        if (v < (i64)0 || v >= ((i64)1 << 31))
            return false;
        u32 bw = self.irWidth(t);
        if (bw >= (u32)1 && bw < (u32)4 && v >= ((i64)1 << ((u32)8 * bw - (u32)1)))
            return false;
        _rcVal = v;
        return true;
        }

    // Is `v` read anywhere outside the header and the loop's body region?
    final bool rotUsedOutsideLoop(IRFunc* fn, IRValue* v)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == _rotH || rotInRegion(bb))
                continue;
            if (unrollUsesValue(bb, v))
                return true;
            }
        return false;
        }

    // Is `v` read anywhere outside blocks `x` and `y`?
    final bool rotUsedOutside(IRFunc* fn, IRValue* v, IRBlock* x, IRBlock* y)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == x || bb == y)
                continue;
            if (unrollUsesValue(bb, v))
                return true;
            }
        return false;
        }

    // The guard must be safe to duplicate: pure value computation, or a plain
    // speculatable load — the peeled copy reads exactly what the header read on
    // entry, so duplicating a load adds no new access. No store, call, or other
    // side effect.
    final bool rotDupSafe(String* op)
        {
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("Copy")) || op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("Neg")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Not")) || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")) || op.equals(String.withCString("Rol")) || op.equals(String.withCString("Ror")) || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FNeg")) || op.equals(String.withCString("FSqrt")) || op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")) || op.equals(String.withCString("Select")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast")) || op.equals(String.withCString("IntToPtr")) || op.equals(String.withCString("PtrToInt")) || op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")) || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")) || op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc")) || op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("FieldAddr")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Load"));
        }

    final void rotApply(IRFunc* fn)
        {
        IRBlock* H = _rotH;
        IRBlock* B = _rotB;
        IRBlock* L = _rotL;

        // 1. Each phi's (preheader init, back-edge next) operands.
        Array* phis = new Array();
        Array* initOp = new Array();
        Array* nextOp = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            phis.add((Object*)phi);
            IROperand* fromPH = (IROperand*)0;
            IROperand* fromB = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
                if (bo.blk() == L)
                    fromB = vo;
                else
                    fromPH = vo;
                }
            initOp.add((Object*)fromPH);
            nextOp.add((Object*)fromB);
            }

        // 2. New body-resident phis: P_B = phi[(H, init), (B, next)]. The
        //    values come FIRST, because `next` may itself be one of H's phis —
        //    a tail-recursion parameter the loop never changes is lowered as
        //    `%p = Phi [(entry, arg), (latch, %p)]` — and step 7 removes H's
        //    phis, so such a `next` has to name the NEW phi or the operand is
        //    left dangling.
        Array* pbVals = new Array();
        Map* bMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)phis.get(i);
            IRValue* v = new IRValue(phi.res().ty());
            pbVals.add((Object*)v);
            bMap.set((Hashable*)phi.res(), (Object*)v);
            }
        // `next` in terms of the new phis (unchanged unless it named an old).
        Array* nextMapped = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IROperand* nx = (IROperand*)nextOp.get(i);
            Object* rm = nx.kind() == (u8)OPK_USE
                             ? bMap.get((Hashable*)nx.val())
                             : (Object*)0;
            nextMapped.add(rm == (Object*)0 ? (Object*)nx
                                            : (Object*)IROperand.useVal((IRValue*)rm));
            }
        Array* pbPhis = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* p = IRInsn.with(String.withCString("Phi"));
            p.setRes((IRValue*)pbVals.get(i));
            p.add(IROperand.block(H));
            p.add((IROperand*)initOp.get(i));
            p.add(IROperand.block(L));
            p.add((IROperand*)nextMapped.get(i));
            pbPhis.add((Object*)p);
            }

        // 3. In the body, this iteration's phi values become the new B-phis. B
        //    dominates every block of the region, so they are valid throughout.
        for (u32 rb = (u32)0; rb < fn.blocks().count(); rb = rb + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(rb);
            if (rotInRegion(bb))
                rotRemapBlock(bb, bMap);
            }
        for (u32 i = (u32)0; i < pbPhis.count(); i = i + (u32)1)
            B.phis().insert(i, pbPhis.get(i));

        // 4. Clone the guard to the BOTTOM of the body FIRST — while H still
        //    references the phis — with each phi value replaced by its
        //    next-iteration value. This has to precede step 5, which rewrites
        //    H's operands to the preheader inits.
        Map* gMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IROperand* nx = (IROperand*)nextMapped.get(i); // mapped: see step 2
            if (nx.kind() == (u8)OPK_USE)
                gMap.set((Hashable*)((IRInsn*)phis.get(i)).res(), (Object*)nx.val());
            }
        IRValue* cB = rotCloneGuard(H, L, gMap);

        // 5. In H — now the peeled test — each phi value becomes its preheader
        //    init. That init may be an IMMEDIATE, so this substitutes operands
        //    rather than values.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE)
                    continue;
                for (u32 j = (u32)0; j < phis.count(); j = j + (u32)1)
                    if (((IRInsn*)phis.get(j)).res() == o.val())
                        {
                        n.ops().set(k, initOp.get(j));
                        break;
                        }
                }
            }

        // 6. The body's terminator is now the conditional back edge, in the
        //    same orientation the header's had.
        IRInsn* ht = H.term();
        IROperand* h1 = (IROperand*)ht.ops().get((u32)1);
        IROperand* h2 = (IROperand*)ht.ops().get((u32)2);
        IRInsn* bt = IRInsn.with(String.withCString("CondBranch"));
        bt.copyDbg(ht);
        bt.setPred(ht.pred());
        bt.add(IROperand.useVal(cB));
        bt.add(h1.blk() == B ? IROperand.block(B) : h1);
        bt.add(h2.blk() == B ? IROperand.block(B) : h2);
        L.setTerm(bt);

        // 7. H keeps its (now init-using) guard and branch; its phis are gone,
        //    since it is entered only from the preheader — the back edge is B→B.
        //    When the guard holds on entry, H goes straight to B and the exit
        //    values are the latch's (step 8).
        H.setPhis(new Array());
        if (_rotEntryTrue)
            {
            IRInsn* hb = IRInsn.with(String.withCString("Branch"));
            hb.copyDbg(ht);
            hb.add(IROperand.block(B));
            H.setTerm(hb);
            }

        // 7b. L's back-edge test exits to E too, so every phi E already has
        //     needs an L incoming: the value it took from H, which was defined
        //     outside the loop and so is the same on the new edge. Without it a
        //     checked downcast's join lost its hit value whenever the walk
        //     matched past the first parent.
        IRBlock* E = _rotE;
        for (u32 i = (u32)0; i < E.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)E.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                if (bo.blk() == H)
                    {
                    phi.add(IROperand.block(L));
                    phi.add((IROperand*)phi.ops().get(k + (u32)1));
                    break;
                    }
                }
            }

        // 8. Exit phis for the carried values read after the loop.
        rotExitPhis(fn, phis, initOp, nextMapped);
        }

    // Copy the header's guard to the bottom of the body, substituting each
    // phi's next-iteration value. Returns the copy of the condition — the value
    // the new conditional back edge tests.
    final IRValue* rotCloneGuard(IRBlock* H, IRBlock* B, Map* gMap)
        {
        IRValue* cB = (IRValue*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            IRInsn* cl = IRInsn.with(n.op());
            cl.copyDbg(n);
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE)
                    {
                    cl.add(o);
                    continue;
                    }
                Object* r = gMap.get((Hashable*)o.val());
                cl.add(r == (Object*)0 ? o : IROperand.useVal((IRValue*)r));
                }
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                gMap.set((Hashable*)n.res(), (Object*)cl.res());
                if (n.res() == _rotCond)
                    cB = cl.res();
                }
            if (n.memRes() != (IRValue*)0)
                cl.setMemRes(new IRValue(String.withCString("Mem")));
            B.insns().add((Object*)cl);
            }
        return cB;
        }

    final void rotExitPhis(IRFunc* fn, Array* phis, Array* initOp, Array* nextMapped)
        {
        IRBlock* H = _rotH;
        IRBlock* L = _rotL;
        IRBlock* E = _rotE;
        Array* exitPhis = new Array();
        Map* exitMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRValue* pid = ((IRInsn*)phis.get(i)).res();
            if (!rotUsedOutsideLoop(fn, pid))
                continue;
            if (_rotEntryTrue)
                {
                // No zero-trip path: after the loop the value is the latch's.
                exitMap.set((Hashable*)pid, (Object*)((IROperand*)nextMapped.get(i)).val());
                continue;
                }
            IRValue* v = new IRValue(pid.ty());
            // The B→E incoming is the carried value on the exit edge as
            // evaluated in B — already in terms of the new phis (step 2).
            IROperand* bInc = (IROperand*)nextMapped.get(i);
            IRInsn* ep = IRInsn.with(String.withCString("Phi"));
            ep.setRes(v);
            ep.add(IROperand.block(H));
            ep.add(initOp.get(i));
            ep.add(IROperand.block(L));
            ep.add(bInc);
            E.phis().insert((u32)0, (Object*)ep);
            exitPhis.add((Object*)ep);
            exitMap.set((Hashable*)pid, (Object*)v);
            }
        if (exitMap.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || rotInRegion(bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(k);
                if (hasInsn(exitPhis, n))
                    continue;
                self.pivReplaceIn(n, exitMap);
                }
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.insns().get(k), exitMap);
            if (bb.term() != (IRInsn*)0)
                self.pivReplaceIn(bb.term(), exitMap);
            }
        }

    final void rotRemapBlock(IRBlock* bb, Map* map)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            self.pivReplaceIn((IRInsn*)bb.phis().get(k), map);
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            self.pivReplaceIn((IRInsn*)bb.insns().get(k), map);
        if (bb.term() != (IRInsn*)0)
            self.pivReplaceIn(bb.term(), map);
        }

    // A block that tests a condition it computes itself and branches on it.
    final bool rcTest(IRBlock* h)
        {
        IRInsn* t = h.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3)
            return false;
        IROperand* c = (IROperand*)t.ops().get((u32)0);
        if (c.kind() != (u8)OPK_USE)
            return false;
        IRBlock* t0 = ((IROperand*)t.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)t.ops().get((u32)2)).blk();
        if (t0 == (IRBlock*)0 || t1 == (IRBlock*)0 || t0 == t1)
            return false;
        for (u32 i = (u32)0; i < h.insns().count(); i = i + (u32)1)
            if (((IRInsn*)h.insns().get(i)).res() == c.val())
                return true;
        return false;
        }

    // The target of h's CondBranch that is not E.
    final IRBlock* rcNext(IRBlock* h, IRBlock* E)
        {
        IRBlock* t0 = ((IROperand*)h.term().ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)h.term().ops().get((u32)2)).blk();
        return t0 == E ? t1 : t0;
        }

    final bool rcTargets(IRBlock* h, IRBlock* e)
        {
        return ((IROperand*)h.term().ops().get((u32)1)).blk() == e || ((IROperand*)h.term().ops().get((u32)2)).blk() == e;
        }

    final bool rcUses(IRInsn* n, Map* vals)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && vals.get((Hashable*)o.val()) != (Object*)0)
                return true;
            }
        return false;
        }

    final bool rcBlockUses(IRBlock* bb, Map* vals)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            if (rcUses((IRInsn*)bb.phis().get(k), vals))
                return true;
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            if (rcUses((IRInsn*)bb.insns().get(k), vals))
                return true;
        return bb.term() != (IRInsn*)0 && rcUses(bb.term(), vals);
        }

    // Each use of a mapped value becomes the operand it maps to.
    final void rcSubst(IRInsn* n, Map* m)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE)
                continue;
            Object* to = m.get((Hashable*)o.val());
            if (to != (Object*)0)
                n.ops().set(k, to);
            }
        }

    final void rcSubstBlock(IRBlock* bb, Map* m)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            rcSubst((IRInsn*)bb.phis().get(k), m);
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            rcSubst((IRInsn*)bb.insns().get(k), m);
        if (bb.term() != (IRInsn*)0)
            rcSubst(bb.term(), m);
        }

    final bool rcRecognise(IRFunc* fn, IRBlock* H1, Map* defBlk)
        {
        _rcChain = (Array*)0;
        _rotH = (IRBlock*)0;
        _rotB = (IRBlock*)0;
        _rotL = (IRBlock*)0;
        _rotR = (Array*)0;
        _rotE = (IRBlock*)0;
        if (H1.phis().count() == (u32)0 || !rcTest(H1))
            return false;
        for (u32 i = (u32)0; i < H1.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H1.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4 || self.isVectorType(p.res().ty()))
                return false;
            }
        // E is the target H1 shares with the block it continues to.
        IRBlock* E = (IRBlock*)0;
        for (u32 side = (u32)1; side <= (u32)2 && E == (IRBlock*)0; side = side + (u32)1)
            {
            IRBlock* n = ((IROperand*)H1.term().ops().get(side)).blk();
            IRBlock* e = ((IROperand*)H1.term().ops().get((u32)3 - side)).blk();
            if (n == H1 || e == H1 || n.phis().count() != (u32)0 || !rcTest(n))
                continue;
            if (rcTargets(n, e))
                E = e;
            }
        if (E == (IRBlock*)0 || E.phis().count() != (u32)0)
            return false;
        Array* chain = new Array();
        chain.add((Object*)H1);
        IRBlock* x = rcNext(H1, E);
        while (chain.count() < (u32)4 && x != H1 && x != E && x.phis().count() == (u32)0 && rcTest(x) && rcTargets(x, E))
            {
            Array* xp = self.predsOfBlock(fn, x);
            if (xp.count() != (u32)1 || (IRBlock*)xp.get((u32)0) != (IRBlock*)chain.get(chain.count() - (u32)1))
                break;
            chain.add((Object*)x);
            x = rcNext(x, E);
            }
        IRBlock* B = x;
        if (chain.count() < (u32)2 || B == H1 || B == E || B.phis().count() != (u32)0 || self.hasBlock(chain, B))
            return false;
        if (predsOfBlock(fn, B).count() != (u32)1)
            return false;
        // The body region, as the one-block case finds it.
        Array* R = new Array();
        R.add((Object*)B);
        Array* work = new Array();
        work.add((Object*)B);
        IRBlock* L = (IRBlock*)0;
        while (work.count() > (u32)0)
            {
            IRBlock* w = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            IRInsn* wt = w.term();
            if (wt == (IRInsn*)0)
                return false;
            for (u32 k = (u32)0; k < wt.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)wt.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                IRBlock* sb = o.blk();
                if (sb == H1)
                    {
                    if (L != (IRBlock*)0 || !wt.op().equals(String.withCString("Branch")))
                        return false;
                    L = w;
                    continue;
                    }
                if (sb == E || self.hasBlock(chain, sb))
                    return false;
                if (!self.hasBlock(R, sb))
                    {
                    R.add((Object*)sb);
                    work.add((Object*)sb);
                    }
                }
            }
        if (L == (IRBlock*)0)
            return false;
        for (u32 r = (u32)0; r < R.count(); r = r + (u32)1)
            {
            IRBlock* rb = (IRBlock*)R.get(r);
            Array* rp = self.predsOfBlock(fn, rb);
            for (u32 q = (u32)0; q < rp.count(); q = q + (u32)1)
                {
                IRBlock* pb = (IRBlock*)rp.get(q);
                if (!self.hasBlock(R, pb) && !(rb == B && pb == (IRBlock*)chain.get(chain.count() - (u32)1)))
                    return false;
                }
            }
        Array* hp = self.predsOfBlock(fn, H1);
        if (hp.count() != (u32)2 || !self.hasBlock(hp, L))
            return false;
        // E is reached from the chain alone.
        Array* ep = self.predsOfBlock(fn, E);
        if (ep.count() != chain.count())
            return false;
        for (u32 q = (u32)0; q < ep.count(); q = q + (u32)1)
            if (!self.hasBlock(chain, (IRBlock*)ep.get(q)))
                return false;
        // Every guard instruction can be duplicated and reads nothing the body
        // computes; a value it defines is read only in the chain, the body or
        // (H1's phis alone) after the loop.
        Map* chainVals = new Map();
        for (u32 h = (u32)0; h < chain.count(); h = h + (u32)1)
            {
            IRBlock* hb = (IRBlock*)chain.get(h);
            for (u32 i = (u32)0; i < hb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)hb.insns().get(i);
                if (!rotDupSafe(n.op()))
                    return false;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_USE)
                        continue;
                    Object* db = defBlk.get((Hashable*)o.val());
                    if (db != (Object*)0 && self.hasBlock(R, (IRBlock*)db))
                        return false;
                    }
                if (n.res() != (IRValue*)0)
                    chainVals.set((Hashable*)n.res(), (Object*)Number.with((u32)1));
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(chain, bb) || self.hasBlock(R, bb))
                continue;
            if (rcBlockUses(bb, chainVals))
                return false;
            }
        _rcChain = chain;
        _rotH = H1;
        _rotB = B;
        _rotL = L;
        _rotR = R;
        _rotE = E;
        return true;
        }

    // A chain value's mark in `set`, when an operand of n is a chain value.
    final void rcMarkOps(IRInsn* n, Map* chainVals, Map* set)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && chainVals.get((Hashable*)o.val()) != (Object*)0)
                set.set((Hashable*)o.val(), (Object*)Number.with((u32)1));
            }
        }

    // Each operand mapped through m (operands that are not uses, or unmapped,
    // as they are).
    final IROperand* rcMapOp(IROperand* o, Map* m)
        {
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* to = m.get((Hashable*)o.val());
        return to == (Object*)0 ? o : (IROperand*)to;
        }

    final IRInsn* rcCopy(IRInsn* n, IRValue* res, Map* m)
        {
        IRInsn* cl = IRInsn.with(n.op());
        cl.copyDbg(n);
        cl.setPred(n.pred());
        cl.setCc(n.cc());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            cl.add(rcMapOp((IROperand*)n.ops().get(k), m));
        if (res != (IRValue*)0)
            cl.setRes(res);
        return cl;
        }

    // Rotation of a chain loop: H1..Hk become the peeled first test; B gets
    // the phis and the chain values the body reads; L and new blocks after it
    // get the chain's copy, on the next values; E gets a phi merging every exit
    // edge for each carried value read after the loop. A chain value the body
    // reads is recomputed at the top of B when it is arithmetic, and carried in
    // by a phi of B when it is a load; one only the back edge reads is
    // recomputed at the end of L, after the body's last read of the value it
    // replaces, so the two can share a register.
    final void rcApply(IRFunc* fn)
        {
        Array* chain = _rcChain;
        IRBlock* H1 = _rotH;
        IRBlock* B = _rotB;
        IRBlock* L = _rotL;
        IRBlock* E = _rotE;
        Array* R = _rotR;
        IRBlock* Hk = (IRBlock*)chain.get(chain.count() - (u32)1);

        // 1. Each H1 phi's (preheader init, back-edge next), and a B phi value.
        Array* phis = new Array();
        Array* initOp = new Array();
        Array* nextOp = new Array();
        Array* pbVals = new Array();
        Map* bMap = new Map(); // value → its B version (an operand)
        for (u32 i = (u32)0; i < H1.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H1.phis().get(i);
            phis.add((Object*)phi);
            IROperand* fromPH = (IROperand*)0;
            IROperand* fromL = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                if (((IROperand*)phi.ops().get(k)).blk() == L)
                    fromL = (IROperand*)phi.ops().get(k + (u32)1);
                else
                    fromPH = (IROperand*)phi.ops().get(k + (u32)1);
                }
            initOp.add((Object*)fromPH);
            nextOp.add((Object*)fromL);
            IRValue* v = new IRValue(phi.res().ty());
            pbVals.add((Object*)v);
            bMap.set((Hashable*)phi.res(), (Object*)IROperand.useVal(v));
            }

        // 2. The chain values B needs.
        Array* chainInsns = new Array();
        for (u32 h = (u32)0; h < chain.count(); h = h + (u32)1)
            {
            IRBlock* hb = (IRBlock*)chain.get(h);
            for (u32 i = (u32)0; i < hb.insns().count(); i = i + (u32)1)
                chainInsns.add(hb.insns().get(i));
            }
        Map* chainVals = new Map();
        for (u32 i = (u32)0; i < chainInsns.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)chainInsns.get(i);
            if (n.res() != (IRValue*)0)
                chainVals.set((Hashable*)n.res(), (Object*)Number.with((u32)1));
            }
        Map* needR = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* rb = (IRBlock*)fn.blocks().get(b);
            if (!self.hasBlock(R, rb))
                continue;
            for (u32 k = (u32)0; k < rb.phis().count(); k = k + (u32)1)
                rcMarkOps((IRInsn*)rb.phis().get(k), chainVals, needR);
            for (u32 k = (u32)0; k < rb.insns().count(); k = k + (u32)1)
                rcMarkOps((IRInsn*)rb.insns().get(k), chainVals, needR);
            if (rb.term() != (IRInsn*)0)
                rcMarkOps(rb.term(), chainVals, needR);
            }
        Map* need = new Map();
        for (u32 i = (u32)0; i < nextOp.count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)nextOp.get(i);
            if (o.kind() == (u8)OPK_USE && chainVals.get((Hashable*)o.val()) != (Object*)0)
                need.set((Hashable*)o.val(), (Object*)Number.with((u32)1));
            }
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            {
            Map* set = pass == (u32)0 ? needR : need;
            u32 q = chainInsns.count();
            while (q > (u32)0)
                {
                q = q - (u32)1;
                IRInsn* n = (IRInsn*)chainInsns.get(q);
                if (n.res() == (IRValue*)0 || set.get((Hashable*)n.res()) == (Object*)0 || n.op().equals(String.withCString("Load")))
                    continue;
                rcMarkOps(n, chainVals, set);
                }
            }
        for (u32 i = (u32)0; i < chainInsns.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)chainInsns.get(i);
            if (n.res() != (IRValue*)0 && needR.get((Hashable*)n.res()) != (Object*)0)
                need.set((Hashable*)n.res(), (Object*)Number.with((u32)1));
            }

        // 3. Their B versions, in chain order.
        Array* remat = new Array();
        Array* lateRemat = new Array();
        Array* loadPhis = new Array();
        Array* loadOrig = new Array();
        for (u32 i = (u32)0; i < chainInsns.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)chainInsns.get(i);
            if (n.res() == (IRValue*)0 || need.get((Hashable*)n.res()) == (Object*)0)
                continue;
            IRValue* v = new IRValue(n.res().ty());
            if (n.op().equals(String.withCString("Load")))
                {
                IRInsn* p = IRInsn.with(String.withCString("Phi"));
                p.copyDbg(n);
                p.setRes(v);
                loadPhis.add((Object*)p);
                loadOrig.add((Object*)n);
                }
            else
                {
                IRInsn* r = rcCopy(n, v, bMap);
                if (needR.get((Hashable*)n.res()) != (Object*)0)
                    remat.add((Object*)r);
                else
                    lateRemat.add((Object*)r);
                }
            bMap.set((Hashable*)n.res(), (Object*)IROperand.useVal(v));
            }
        Array* nextB = new Array();
        for (u32 i = (u32)0; i < nextOp.count(); i = i + (u32)1)
            nextB.add((Object*)rcMapOp((IROperand*)nextOp.get(i), bMap));

        // 4. The body reads the B versions.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* rb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(R, rb))
                rcSubstBlock(rb, bMap);
            }

        // 5. The chain's copy at the bottom of the body: H1's into L, each
        //    later block's into a new block after it.
        for (u32 i = (u32)0; i < lateRemat.count(); i = i + (u32)1)
            L.insns().add(lateRemat.get(i));
        Map* gMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            gMap.set((Hashable*)((IRInsn*)phis.get(i)).res(), nextB.get(i));
        Array* clones = new Array();
        clones.add((Object*)L);
        for (u32 h = (u32)1; h < chain.count(); h = h + (u32)1)
            {
            IRBlock* hb = (IRBlock*)chain.get(h);
            String* nm = new String();
            nm.appendFormat("%s_rot", hb.name() == (String*)0 ? "test" : hb.name().cString());
            clones.add((Object*)new IRBlock(nm));
            }
        for (u32 h = (u32)0; h < chain.count(); h = h + (u32)1)
            {
            IRBlock* src = (IRBlock*)chain.get(h);
            IRBlock* dst = (IRBlock*)clones.get(h);
            for (u32 i = (u32)0; i < src.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)src.insns().get(i);
                IRValue* nr = (IRValue*)0;
                if (n.res() != (IRValue*)0)
                    nr = new IRValue(n.res().ty());
                IRInsn* cl = rcCopy(n, nr, gMap);
                if (n.res() != (IRValue*)0)
                    gMap.set((Hashable*)n.res(), (Object*)IROperand.useVal(nr));
                if (n.memRes() != (IRValue*)0)
                    cl.setMemRes(new IRValue(String.withCString("Mem")));
                dst.insns().add((Object*)cl);
                }
            IRInsn* ht = src.term();
            IRInsn* bt = IRInsn.with(String.withCString("CondBranch"));
            bt.copyDbg(ht);
            bt.setPred(ht.pred());
            bt.add(rcMapOp((IROperand*)ht.ops().get((u32)0), gMap));
            for (u32 k = (u32)1; k < (u32)3; k = k + (u32)1)
                {
                IROperand* to = (IROperand*)ht.ops().get(k);
                if (h + (u32)1 < chain.count() && to.blk() == (IRBlock*)chain.get(h + (u32)1))
                    bt.add(IROperand.block((IRBlock*)clones.get(h + (u32)1)));
                else
                    bt.add(to);
                }
            dst.setTerm(bt);
            }
        u32 at = (u32)0;
        while ((IRBlock*)fn.blocks().get(at) != L)
            at = at + (u32)1;
        for (u32 h = (u32)1; h < clones.count(); h = h + (u32)1)
            fn.blocks().insert(at + h, clones.get(h));
        IRBlock* Lk = (IRBlock*)clones.get(clones.count() - (u32)1);

        // 6. B's phis and recomputations.
        Array* bPhis = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* p = IRInsn.with(String.withCString("Phi"));
            p.copyDbg((IRInsn*)phis.get(i));
            p.setRes((IRValue*)pbVals.get(i));
            p.add(IROperand.block(Hk));
            p.add((IROperand*)initOp.get(i));
            p.add(IROperand.block(Lk));
            p.add((IROperand*)nextB.get(i));
            bPhis.add((Object*)p);
            }
        for (u32 i = (u32)0; i < loadPhis.count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)loadPhis.get(i);
            IRValue* ov = ((IRInsn*)loadOrig.get(i)).res();
            p.add(IROperand.block(Hk));
            p.add(IROperand.useVal(ov));
            p.add(IROperand.block(Lk));
            p.add((IROperand*)gMap.get((Hashable*)ov));
            bPhis.add((Object*)p);
            }
        for (u32 i = (u32)0; i < bPhis.count(); i = i + (u32)1)
            B.phis().insert(i, bPhis.get(i));
        for (u32 i = (u32)0; i < remat.count(); i = i + (u32)1)
            B.insns().insert(i, remat.get(i));

        // 7. The chain itself is the peeled test: phi values become the inits.
        Map* hReplace = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            hReplace.set((Hashable*)((IRInsn*)phis.get(i)).res(), initOp.get(i));
        for (u32 h = (u32)0; h < chain.count(); h = h + (u32)1)
            {
            IRBlock* hb = (IRBlock*)chain.get(h);
            for (u32 i = (u32)0; i < hb.insns().count(); i = i + (u32)1)
                rcSubst((IRInsn*)hb.insns().get(i), hReplace);
            }
        H1.setPhis(new Array());

        // 8. Exit phis for the carried values read after the loop.
        Array* exitPhis = new Array();
        Map* exitMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRValue* pid = ((IRInsn*)phis.get(i)).res();
            Map* one = new Map();
            one.set((Hashable*)pid, (Object*)Number.with((u32)1));
            bool esc = false;
            for (u32 b = (u32)0; b < fn.blocks().count() && !esc; b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (hasBlock(chain, bb) || self.hasBlock(R, bb) || self.hasBlock(clones, bb))
                    continue;
                esc = rcBlockUses(bb, one);
                }
            if (!esc)
                continue;
            IRValue* v = new IRValue(pid.ty());
            IRInsn* ep = IRInsn.with(String.withCString("Phi"));
            ep.setRes(v);
            for (u32 h = (u32)0; h < chain.count(); h = h + (u32)1)
                {
                ep.add(IROperand.block((IRBlock*)chain.get(h)));
                ep.add((IROperand*)initOp.get(i));
                }
            for (u32 h = (u32)0; h < clones.count(); h = h + (u32)1)
                {
                ep.add(IROperand.block((IRBlock*)clones.get(h)));
                ep.add((IROperand*)nextB.get(i));
                }
            exitPhis.add((Object*)ep);
            exitMap.set((Hashable*)pid, (Object*)IROperand.useVal(v));
            }
        for (u32 i = (u32)0; i < exitPhis.count(); i = i + (u32)1)
            E.phis().insert(i, exitPhis.get(i));
        if (exitPhis.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(chain, bb) || self.hasBlock(R, bb) || self.hasBlock(clones, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(k);
                if (!self.hasInsn(exitPhis, n))
                    rcSubst(n, exitMap);
                }
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                rcSubst((IRInsn*)bb.insns().get(k), exitMap);
            if (bb.term() != (IRInsn*)0)
                rcSubst(bb.term(), exitMap);
            }
        }
    }
