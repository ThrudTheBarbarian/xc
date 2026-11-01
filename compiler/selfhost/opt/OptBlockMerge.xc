// OptBlockMerge.xc — the BlockMerge pass, ported from src/xtc/ir/XTIROptBlockMerge.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (BlockMerge)
    {

    // ── jump-thread ──────────────────────────────────────────────────────
    //
    // When a block does nothing but merge a boolean and branch on it, a
    // predecessor supplying a CONSTANT already knows where control goes.
    // Rewiring it to jump straight there removes its edge, and once the phi is
    // down to one incoming the boolean stops existing at all.
    //
    // This is what a short-circuit `&&` leaves behind: the left test's false
    // arm feeds the merge a literal 0, so it is a branch to the exit wearing a
    // phi. sort_small's `j > 0 && a[j-1] > v` was materialising that 0, storing
    // it to a frame slot and loading it back on every iteration of an O(n^2)
    // loop. It cannot be if-converted — the right arm loads a[j-1] and j may
    // be 0.
    // ── block-merge ───────────────────────────────────────────────────────
    // When a block A ends in an unconditional branch to B, and A is the only
    // way into B, the two are one straight run of code split in two. Folding B
    // into A removes the branch and the block boundary: an unrolled loop body is
    // four copies chained by plain branches, which loop rotation and the back
    // ends treat as four blocks; merged, it is the single-block body they handle
    // best.
    final void blockMerge(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            pruneStaleIncomings(fn);
            bool more = true;
            while (more)
                more = blockMergeOnce(fn);
            }
        }

    // Every reference to `b` from an instruction or terminator — anything but
    // a phi's incoming list.
    final u32 bmRefs(IRFunc* fn, IRBlock* b)
        {
        u32 n = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(k);
            for (u32 i = (u32)0; i <= bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* x = i < bb.insns().count() ? (IRInsn*)bb.insns().get(i) : bb.term();
                if (x == (IRInsn*)0)
                    continue;
                for (u32 q = (u32)0; q < x.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)x.ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == b)
                        n = n + (u32)1;
                    }
                }
            }
        return n;
        }

    // Replace every use of `from` with `to` (any operand), outside `skip`.
    final void bmReplaceUses(IRFunc* fn, IRValue* from, IROperand* to, IRInsn* skip)
        {
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(k);
            u32 total = bb.phis().count() + bb.insns().count() + (u32)1;
            for (u32 i = (u32)0; i < total; i = i + (u32)1)
                {
                IRInsn* x = (IRInsn*)0;
                if (i < bb.phis().count())
                    x = (IRInsn*)bb.phis().get(i);
                else if (i < bb.phis().count() + bb.insns().count())
                    x = (IRInsn*)bb.insns().get(i - bb.phis().count());
                else
                    x = bb.term();
                if (x == (IRInsn*)0 || x == skip)
                    continue;
                for (u32 q = (u32)0; q < x.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)x.ops().get(q);
                    if (o.kind() == (u8)OPK_USE && o.val() == from)
                        x.ops().set(q, (Object*)to);
                    }
                }
            }
        }

    // Drop every phi incoming whose block does not branch to the phi's block
    // (the reference explains).
    final void pruneStaleIncomings(IRFunc* fn)
        {
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            {
            IRBlock* S = (IRBlock*)fn.blocks().get(k);
            if (S.phis().count() == (u32)0)
                continue;
            Array* ps = new Array();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                IRInsn* t = bb.term();
                if (t == (IRInsn*)0)
                    continue;
                for (u32 q = (u32)0; q < t.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)t.ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == S)
                        {
                        ps.add((Object*)bb);
                        break;
                        }
                    }
                }
            for (u32 i = (u32)0; i < S.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)S.phis().get(i);
                u32 live = (u32)0;
                for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                    if (bmHas(ps, ((IROperand*)phi.ops().get(q)).blk()))
                        live = live + (u32)1;
                if (live == (u32)0)
                    continue;
                u32 q = phi.ops().count() & ~(u32)1;
                while (q >= (u32)2)
                    {
                    q = q - (u32)2;
                    if (!bmHas(ps, ((IROperand*)phi.ops().get(q)).blk()))
                        {
                        phi.ops().removeAt(q + (u32)1);
                        phi.ops().removeAt(q);
                        }
                    }
                }
            }
        // A block with ONE predecessor has phis of one incoming each, and each
        // IS its value: folded away (loop-rotate will not touch a loop whose
        // exit block already has phis).
        for (u32 k = (u32)1; k < fn.blocks().count(); k = k + (u32)1)
            {
            IRBlock* S = (IRBlock*)fn.blocks().get(k);
            if (S.phis().count() == (u32)0)
                continue;
            Array* ps = new Array();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                IRInsn* t = bb.term();
                if (t == (IRInsn*)0)
                    continue;
                for (u32 q = (u32)0; q < t.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)t.ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == S)
                        {
                        ps.add((Object*)bb);
                        break;
                        }
                    }
                }
            if (ps.count() != (u32)1)
                continue;
            IRBlock* P = (IRBlock*)ps.get((u32)0);
            bool ok = true;
            for (u32 i = (u32)0; i < S.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)S.phis().get(i);
                if (phi.ops().count() != (u32)2 || ((IROperand*)phi.ops().get((u32)0)).blk() != P
                    || phi.res() == (IRValue*)0 || phi.memRes() != (IRValue*)0)
                    ok = false;
                }
            if (!ok)
                continue;
            for (u32 i = (u32)0; i < S.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)S.phis().get(i);
                bmReplaceUses(fn, phi.res(), (IROperand*)phi.ops().get((u32)1), phi);
                }
            while (S.phis().count() > (u32)0)
                S.phis().removeAt((u32)0);
            }
        }

    static bool bmHas(Array* a, IRBlock* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRBlock*)a.get(i) == b)
                return true;
        return false;
        }

    final bool blockMergeOnce(IRFunc* fn)
        {
        IRBlock* entry = fn.blocks().count() > (u32)0 ? (IRBlock*)fn.blocks().get((u32)0) : (IRBlock*)0;
        for (u32 a = (u32)0; a < fn.blocks().count(); a = a + (u32)1)
            {
            IRBlock* A = (IRBlock*)fn.blocks().get(a);
            IRInsn* term = A.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("Branch")) || term.ops().count() != (u32)1)
                continue;
            IRBlock* B = ((IROperand*)term.ops().get((u32)0)).blk();
            if (B == (IRBlock*)0 || B == A || B == entry || bmRefs(fn, B) != (u32)1)
                continue;
            // B's phis each have one incoming, from A: each IS that value.
            bool ok = true;
            for (u32 i = (u32)0; i < B.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)B.phis().get(i);
                if (phi.ops().count() != (u32)2 || ((IROperand*)phi.ops().get((u32)0)).blk() != A
                    || phi.res() == (IRValue*)0)
                    ok = false;
                }
            if (!ok)
                continue;
            for (u32 i = (u32)0; i < B.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)B.phis().get(i);
                bmReplaceUses(fn, phi.res(), (IROperand*)phi.ops().get((u32)1), phi);
                }
            // B's real successors: the blocks its terminator names.
            Array* succ = new Array();
            if (B.term() != (IRInsn*)0)
                for (u32 q = (u32)0; q < B.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)B.term().ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0)
                        succ.add((Object*)o.blk());
                    }
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                A.insns().add(B.insns().get(i));
            A.setTerm(B.term());
            // B's successors now have A where they had B. A phi anywhere else
            // that names B names a block that never branched to it: a stale
            // entry, left by a pass that deleted the edge but not the incoming.
            // It is dropped, not re-pointed: moved onto A it would keep its
            // value live across all of A (poly_dispatch: two spills).
            for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
                {
                IRBlock* S = (IRBlock*)fn.blocks().get(k);
                bool isSucc = false;
                for (u32 q = (u32)0; q < succ.count(); q = q + (u32)1)
                    if ((IRBlock*)succ.get(q) == S)
                        isSucc = true;
                for (u32 i = (u32)0; i < S.phis().count(); i = i + (u32)1)
                    {
                    IRInsn* phi = (IRInsn*)S.phis().get(i);
                    u32 q = phi.ops().count() & ~(u32)1;
                    while (q >= (u32)2)
                        {
                        q = q - (u32)2;
                        if (((IROperand*)phi.ops().get(q)).blk() != B)
                            continue;
                        if (isSucc)
                            phi.ops().set(q, (Object*)IROperand.block(A));
                        else
                            {
                            phi.ops().removeAt(q + (u32)1);
                            phi.ops().removeAt(q);
                            }
                        }
                    }
                }
            for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
                if ((IRBlock*)fn.blocks().get(k) == B)
                    {
                    fn.blocks().removeAt(k);
                    break;
                    }
            return true;
            }
        return false;
        }
    }
