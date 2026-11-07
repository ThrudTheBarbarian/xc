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

    // A CondBranch on a constant becomes a Branch, and the blocks no path from
    // the entry reaches any more go, with their phi incomings; then again,
    // for a branch on a phi those incomings left one value. `Par.kept(n)`,
    // which par-check answers, is what makes these: the side of a lifted
    // loop's site it does not take (the block, or the loop as written)
    // must not stay in the function. As the reference.
    final void constBranches(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            while (cbFoldOnce(fn))
                {
                cbDropUnreachable(fn);
                pruneStaleIncomings(fn);
                }
            }
        }

    final bool cbFoldOnce(IRFunc* fn)
        {
        bool changed = false;
        Map* defOf = (Map*)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() != (u32)3)
                continue;
            IROperand* c = (IROperand*)t.ops().get((u32)0);
            i64 k = (i64)-1;
            if (c.kind() == (u8)OPK_IMMI)
                k = c.imm();
            else if (c.kind() == (u8)OPK_USE)
                {
                if (defOf == (Map*)0)
                    defOf = self.defMapAll(fn);
                IRInsn* d = (IRInsn*)defOf.get((Hashable*)c.val());
                if (d != (IRInsn*)0 && d.op().equals(String.withCString("Const")) && d.ops().count() == (u32)1
                    && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_IMMI)
                    k = ((IROperand*)d.ops().get((u32)0)).imm();
                }
            if (k < (i64)0)
                continue;
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.copyDbg(t);
            br.add((IROperand*)t.ops().get(k != (i64)0 ? (u32)1 : (u32)2));
            bb.setTerm(br);
            changed = true;
            }
        return changed;
        }

    // A check that fails calls a trap that never returns (_xt_check_trap,
    // _xt_check_cast_trap). Ending its block there, with Unreachable, takes
    // the trap's path out of the loop it sits in: the loop's body then holds
    // no call, and the loads the check made of an array's header (its magic
    // and its count) are loop-invariant and hoist (issue #28). Lowering
    // carries a join on from one side's memory token rather than merging
    // them, so a token the trap made may be named after the join: it is
    // renamed to the token the trap call took, which is the state on every
    // path that does not trap.
    final bool trapCutIsTrap(IRInsn* n)
        {
        if (!n.op().equals(String.withCString("Call")) || n.ops().count() < (u32)1)
            return false;
        IROperand* c = (IROperand*)n.ops().get((u32)0);
        if (c.kind() != (u8)OPK_SYM || c.name() == 0)
            return false;
        return c.name().equals(String.withCString("_xt_check_trap"))
            || c.name().equals(String.withCString("_xt_check_cast_trap"));
        }

    final void trapCut(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            Map* rename = new Map();   // a dropped memory token -> the trap's own input
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    if (!trapCutIsTrap(n))
                        continue;
                    IRValue* memIn = (IRValue*)0;
                    for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)n.ops().get(k);
                        if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && o.val().ty() != (String*)0
                            && o.val().ty().equals(String.withCString("Mem")))
                            memIn = o.val();
                        }
                    if (memIn == (IRValue*)0)
                        continue;
                    // Already cut: nothing after the trap, and Unreachable.
                    if (i + (u32)1 == bb.insns().count() && bb.term() != (IRInsn*)0
                        && bb.term().op().equals(String.withCString("Unreachable")))
                        break;
                    if (n.memRes() != (IRValue*)0)
                        rename.set((Hashable*)n.memRes(), (Object*)memIn);
                    while (bb.insns().count() > i + (u32)1)
                        {
                        IRInsn* d = (IRInsn*)bb.insns().get(bb.insns().count() - (u32)1);
                        if (d.memRes() != (IRValue*)0)
                            rename.set((Hashable*)d.memRes(), (Object*)memIn);
                        bb.insns().removeAt(bb.insns().count() - (u32)1);
                        }
                    IRInsn* u = IRInsn.with(String.withCString("Unreachable"));
                    if (bb.term() != (IRInsn*)0)
                        u.copyDbg(bb.term());
                    bb.setTerm(u);
                    break;
                    }
                }
            if (rename.count() == (u32)0)
                continue;
            // A renamed token may itself map on (one trap's input made by
            // another cut block's call): follow the chain to its end.
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                    trapCutRename((IRInsn*)bb.phis().get(i), rename);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    trapCutRename((IRInsn*)bb.insns().get(i), rename);
                if (bb.term() != (IRInsn*)0)
                    trapCutRename(bb.term(), rename);
                }
            cbDropUnreachable(fn);
            pruneStaleIncomings(fn);
            }
        }

    final void trapCutRename(IRInsn* n, Map* rename)
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

    // The blocks a path from the entry reaches, in the function's order.
    final void cbDropUnreachable(IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return;
        Set* seen = new Set();
        Array* work = new Array();
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        seen.add((Hashable*)entry);
        work.add((Object*)entry);
        while (work.count() > (u32)0)
            {
            IRBlock* bb = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 q = (u32)0; q < t.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(q);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0 || seen.contains((Hashable*)o.blk()))
                    continue;
                seen.add((Hashable*)o.blk());
                work.add((Object*)o.blk());
                }
            }
        // The memory tokens the dropped blocks made. Lowering does not merge
        // memory at a join (after `if (c) A else B` it carries on from B's),
        // so a kept block may name one: it takes the last token on its own
        // path instead (cbMemBefore).
        Set* dead = new Set();
        for (u32 j = (u32)0; j < fn.blocks().count(); j = j + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(j);
            if (seen.contains((Hashable*)bb))
                continue;
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                if (((IRInsn*)bb.phis().get(i)).memRes() != (IRValue*)0)
                    dead.add((Hashable*)((IRInsn*)bb.phis().get(i)).memRes());
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (((IRInsn*)bb.insns().get(i)).memRes() != (IRValue*)0)
                    dead.add((Hashable*)((IRInsn*)bb.insns().get(i)).memRes());
            }
        u32 k = fn.blocks().count();
        while (k > (u32)1)
            {
            k = k - (u32)1;
            if (!seen.contains((Hashable*)fn.blocks().get(k)))
                fn.blocks().removeAt(k);
            }
        if (dead.count() == (u32)0)
            return;
        for (u32 j = (u32)0; j < fn.blocks().count(); j = j + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(j);
            IRValue* cur = (IRValue*)0;
            for (u32 i = (u32)0; i <= bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* x = i < bb.insns().count() ? (IRInsn*)bb.insns().get(i) : bb.term();
                if (x == (IRInsn*)0)
                    continue;
                for (u32 q = (u32)0; q < x.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)x.ops().get(q);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || !dead.contains((Hashable*)o.val()))
                        continue;
                    IRValue* to = cur != (IRValue*)0 ? cur : cbMemBefore(fn, bb, (u32)0);
                    x.ops().set(q, (Object*)IROperand.useVal(to));
                    }
                if (x.memRes() != (IRValue*)0)
                    cur = x.memRes();
                }
            }
        }

    // The memory token in effect where block bb starts: the last one its one
    // predecessor made (or had in effect), else the function's own.
    final IRValue* cbMemBefore(IRFunc* fn, IRBlock* bb, u32 depth)
        {
        IRBlock* pred = (IRBlock*)0;
        u32 preds = (u32)0;
        for (u32 j = (u32)0; j < fn.blocks().count() && depth < (u32)64; j = j + (u32)1)
            {
            IRBlock* p = (IRBlock*)fn.blocks().get(j);
            IRInsn* t = p.term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 q = (u32)0; q < t.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == bb)
                    {
                    if (pred != p)
                        preds = preds + (u32)1;
                    pred = p;
                    break;
                    }
                }
            }
        if (preds == (u32)1)
            {
            u32 i = pred.insns().count();
            while (i > (u32)0)
                {
                i = i - (u32)1;
                IRValue* mr = ((IRInsn*)pred.insns().get(i)).memRes();
                if (mr != (IRValue*)0)
                    return mr;
                }
            for (u32 i2 = (u32)0; i2 < pred.phis().count(); i2 = i2 + (u32)1)
                if (((IRInsn*)pred.phis().get(i2)).memRes() != (IRValue*)0)
                    return ((IRInsn*)pred.phis().get(i2)).memRes();
            return cbMemBefore(fn, pred, depth + (u32)1);
            }
        return (IRValue*)fn.params().get(fn.params().count() - (u32)1);
        }

    // Every block's count of references from an instruction or terminator —
    // anything but a phi's incoming list. One scan for all the blocks: counted
    // a block at a time (a scan of the function for each candidate) this was
    // blocks x instructions per merge, and the par runtime's large functions
    // spent a tenth of a lifted loop's compile here.
    final Map* bmRefCounts(IRFunc* fn)
        {
        Map* counts = new Map();
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
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                        continue;
                    Number* c = (Number*)counts.get((Hashable*)o.blk());
                    u32 n = c == (Number*)0 ? (u32)0 : c.asU32();
                    counts.set((Hashable*)o.blk(), (Object*)Number.with(n + (u32)1));
                    }
                }
            }
        return counts;
        }

    final u32 bmRefs(Map* counts, IRBlock* b)
        {
        Number* c = (Number*)counts.get((Hashable*)b);
        return c == (Number*)0 ? (u32)0 : c.asU32();
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
        // Taken once: nothing changes the function until the one merge this
        // call makes, and it returns straight after.
        Map* refs = bmRefCounts(fn);
        for (u32 a = (u32)0; a < fn.blocks().count(); a = a + (u32)1)
            {
            IRBlock* A = (IRBlock*)fn.blocks().get(a);
            IRInsn* term = A.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("Branch")) || term.ops().count() != (u32)1)
                continue;
            IRBlock* B = ((IROperand*)term.ops().get((u32)0)).blk();
            if (B == (IRBlock*)0 || B == A || B == entry || bmRefs(refs, B) != (u32)1)
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
