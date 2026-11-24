// OptOuterUnroll.xc — the OuterUnroll pass; the reference is
// src/xtc/ir/XTIROptOuterUnroll.m, and the two make the same blocks, values
// and order. One of the files class Opt is split into, so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (OuterUnroll)
    {
    // ── outer-unroll ─────────────────────────────────────────────────────
    //
    // A counted loop around ONE inner loop whose exit depends on data it
    // loads (an insertion sort's `while (j > 0 && a[j-1] > v)`) runs K copies
    // of its body per trip, each copy with its own inner loop (#41). The
    // copies run in order, so nothing has to be independent: copy j starts
    // from the values copy j-1 leaves on its back edge. What it buys is one
    // exit branch per copy, each with its own predictor history for that
    // position's trip count. clang does the same to sort_small's `i` loop.
    //
    // The shape is the rotated (bottom-tested) loop LoopRotate leaves:
    //
    //     B:   phi i = [(pre, S), (L, next)] ...  <body, inner loop> ...
    //     L:   next = Add i, 1; c = ICmp ULT|SLT|NE next, N; CondBranch c, B, X
    //
    // with S and N constants, so the trip T = N - S, and K the largest of 4,
    // 3 and 2 that divides T: no copy needs the test, no remainder loop. The
    // loop has no other exit and no call, and its body stays small. The
    // inner loop must be innermost, and one of its exits must compare a value
    // it loads; a counted inner loop gains nothing from the copies.
    //
    // The 64-bit targets only (the profile's outerUnroll).

    final void outerUnroll(IRModule* m)
        {
        if (!_profile.outerUnroll())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop at a time, re-recognised from the live CFG. An unrolled
            // loop holds K inner loops and steps by more than one, so it never
            // matches again; the bound is a backstop.
            u32 iter = (u32)0;
            while (iter < (u32)64 && ouOne(fn))
                iter = iter + (u32)1;
            }
        }

    final bool ouOne(IRFunc* fn)
        {
        Array* loops = lrcLoops(fn);
        for (u32 li = (u32)0; li < loops.count(); li = li + (u32)1)
            if (ouTry(fn, (LRCLoop*)loops.get(li), loops))
                return true;
        return false;
        }

    // A constant: an immediate, a Const, or a ZExt/SExt of one.
    final bool ouConst(IROperand* o, Map* defOf, i64* out, u32 depth)
        {
        if (o == (IROperand*)0 || depth > (u32)3)
            return false;
        if (o.kind() == (u8)OPK_IMMI)
            {
            *out = o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || d.ops().count() < (u32)1)
            return false;
        if (d.isOp(opConst))
            {
            IROperand* c = (IROperand*)d.ops().get((u32)0);
            if (c.kind() != (u8)OPK_IMMI)
                return false;
            *out = c.imm();
            return true;
            }
        if (d.isOp(opZExt) || d.isOp(opSExt))
            return ouConst((IROperand*)d.ops().get((u32)0), defOf, out, depth + (u32)1);
        return false;
        }

    // The operand of `phi` that arrives from `from`, or 0.
    final IROperand* ouIncoming(IRInsn* phi, IRBlock* from)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            if (((IROperand*)phi.ops().get(k)).blk() == from)
                return (IROperand*)phi.ops().get(k + (u32)1);
        return (IROperand*)0;
        }

    // Does one of the inner loop's exits compare a value the inner loop loads?
    final bool ouDataExit(IRFunc* fn, Map* inI, Map* defOf)
        {
        Map* loads = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (inI.get((Hashable*)bb) == (Object*)0)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.isOp(opLoad) && n.res() != (IRValue*)0)
                    loads.set((Hashable*)n.res(), (Object*)n);
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (inI.get((Hashable*)bb) == (Object*)0)
                continue;
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0 || !t.isOp(opCondBranch) || t.ops().count() < (u32)3)
                continue;
            bool exits = false;
            for (u32 k = (u32)1; k < (u32)3; k = k + (u32)1)
                if (inI.get((Hashable*)((IROperand*)t.ops().get(k)).blk()) == (Object*)0)
                    exits = true;
            IROperand* c = (IROperand*)t.ops().get((u32)0);
            if (!exits || c.kind() != (u8)OPK_USE)
                continue;
            IRInsn* cmp = (IRInsn*)defOf.get((Hashable*)c.val());
            if (cmp == (IRInsn*)0 || !cmp.isOp(opICmp))
                continue;
            for (u32 k = (u32)0; k < cmp.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)cmp.ops().get(k);
                if (o.kind() == (u8)OPK_USE && loads.get((Hashable*)o.val()) != (Object*)0)
                    return true;
                }
            }
        return false;
        }

    final bool ouTry(IRFunc* fn, LRCLoop* L, Array* loops)
        {
        IRBlock* B = L.header();
        IRBlock* Lt = L.latch();
        if (L.pre() == (IRBlock*)0 || B == Lt)
            return false;
        Map* inL = new Map();
        for (u32 i = (u32)0; i < L.body().count(); i = i + (u32)1)
            inL.set((Hashable*)L.body().get(i), L.body().get(i));
        // One back edge to B.
        u32 sameHeader = (u32)0;
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            if (((LRCLoop*)loops.get(i)).header() == B)
                sameHeader = sameHeader + (u32)1;
        if (sameHeader != (u32)1)
            return false;
        // The latch goes back to B on true and out to X on false.
        IRInsn* t = Lt.term();
        if (t == (IRInsn*)0 || !t.isOp(opCondBranch) || t.ops().count() < (u32)3)
            return false;
        IROperand* tc = (IROperand*)t.ops().get((u32)0);
        IRBlock* X = ((IROperand*)t.ops().get((u32)2)).blk();
        if (tc.kind() != (u8)OPK_USE || ((IROperand*)t.ops().get((u32)1)).blk() != B
            || X == (IRBlock*)0 || inL.get((Hashable*)X) != (Object*)0)
            return false;
        // No other way out, no call, and a small body.
        u32 size = (u32)0;
        for (u32 i = (u32)0; i < L.body().count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)L.body().get(i);
            Array* ss = lrcSuccs(fn, bb);
            for (u32 s = (u32)0; s < ss.count(); s = s + (u32)1)
                {
                IRBlock* sb = (IRBlock*)ss.get(s);
                if (inL.get((Hashable*)sb) == (Object*)0 && !(bb == Lt && sb == X))
                    return false;
                }
            size = size + bb.phis().count() + bb.insns().count() + (u32)1;
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                if (callsOut(((IRInsn*)bb.insns().get(k)).opc()))
                    return false;
            }
        if (size > (u32)64)
            return false;
        // Exactly one inner loop, innermost.
        IRBlock* I = (IRBlock*)0;
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            {
            IRBlock* h = ((LRCLoop*)loops.get(i)).header();
            if (h == B || inL.get((Hashable*)h) == (Object*)0)
                continue;
            if (I == (IRBlock*)0)
                I = h;
            else if (h != I)
                return false;
            }
        if (I == (IRBlock*)0)
            return false;
        Map* inI = new Map();
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            {
            LRCLoop* K = (LRCLoop*)loops.get(i);
            if (K.header() != I)
                continue;
            for (u32 j = (u32)0; j < K.body().count(); j = j + (u32)1)
                inI.set((Hashable*)K.body().get(j), K.body().get(j));
            }
        if (inI.get((Hashable*)B) != (Object*)0)
            return false;
        Map* defOf = defMap(fn);
        if (!ouDataExit(fn, inI, defOf))
            return false;
        // The trip: i from S, next = i + 1, the test next <> N.
        IRInsn* cmp = (IRInsn*)defOf.get((Hashable*)tc.val());
        if (cmp == (IRInsn*)0 || !cmp.isOp(opICmp) || cmp.ops().count() < (u32)2)
            return false;
        String* p = cmp.pred();
        if (p == (String*)0 || !(p.equals(String.withCString("ULT")) || p.equals(String.withCString("SLT"))
                                 || p.equals(String.withCString("NE"))))
            return false;
        i64 N = (i64)0;
        IROperand* nxo = (IROperand*)cmp.ops().get((u32)0);
        if (nxo.kind() != (u8)OPK_USE || !ouConst((IROperand*)cmp.ops().get((u32)1), defOf, &N, (u32)0))
            return false;
        IRInsn* add = (IRInsn*)defOf.get((Hashable*)nxo.val());
        if (add == (IRInsn*)0 || !add.isOp(opAdd) || add.ops().count() < (u32)2)
            return false;
        IRInsn* iv = (IRInsn*)0;
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
            {
            IROperand* a = (IROperand*)add.ops().get(k);
            IROperand* o = (IROperand*)add.ops().get((u32)1 - k);
            i64 one = (i64)0;
            if (a.kind() != (u8)OPK_USE || !ouConst(o, defOf, &one, (u32)0) || one != (i64)1)
                continue;
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)a.val());
            if (d != (IRInsn*)0 && d.isOp(opPhi) && B.phis().contains((Object*)d))
                iv = d;
            }
        if (iv == (IRInsn*)0)
            return false;
        IROperand* back = ouIncoming(iv, Lt);
        i64 S = (i64)0;
        if (back == (IROperand*)0 || back.kind() != (u8)OPK_USE || back.val() != nxo.val()
            || !ouConst(ouIncoming(iv, L.pre()), defOf, &S, (u32)0))
            return false;
        if (S < (i64)0 || N <= S || N - S > (i64)$40000000)
            return false;
        // Every value B's phis take on the back edge is a value, not an
        // immediate, so each copy's phi has something to stand for it.
        for (u32 i = (u32)0; i < B.phis().count(); i = i + (u32)1)
            {
            IROperand* o = ouIncoming((IRInsn*)B.phis().get(i), Lt);
            if (o == (IROperand*)0 || o.kind() != (u8)OPK_USE)
                return false;
            }
        i64 T = N - S;
        u32 K = (u32)0;
        if (T % (i64)4 == (i64)0)
            K = (u32)4;
        else if (T % (i64)3 == (i64)0)
            K = (u32)3;
        else if (T % (i64)2 == (i64)0)
            K = (u32)2;
        if (K == (u32)0 || T < (i64)K)
            return false;
        ouApply(fn, B, Lt, X, inL, K);
        return true;
        }

    final IROperand* ouSubst(Map* vmap, Map* bmap, IROperand* o)
        {
        if (o.kind() == (u8)OPK_BLOCK)
            {
            Object* nb = bmap.get((Hashable*)o.blk());
            return nb == (Object*)0 ? o : IROperand.block((IRBlock*)nb);
            }
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* nv = vmap.get((Hashable*)o.val());
        return nv == (Object*)0 ? o : IROperand.useVal((IRValue*)nv);
        }

    final IRInsn* ouClone(IRInsn* n, Map* vmap, Map* bmap)
        {
        IRInsn* cl = IRInsn.withOpOf(n);
        cl.copyDbg(n);
        cl.setPred(n.pred());
        cl.setCc(n.cc());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            cl.add(ouSubst(vmap, bmap, (IROperand*)n.ops().get(k)));
        if (n.res() != (IRValue*)0)
            cl.setRes((IRValue*)vmap.get((Hashable*)n.res()));
        if (n.memRes() != (IRValue*)0)
            cl.setMemRes((IRValue*)vmap.get((Hashable*)n.memRes()));
        return cl;
        }

    final void ouNewResult(Map* vmap, IRInsn* n)
        {
        if (n.res() != (IRValue*)0)
            vmap.set((Hashable*)n.res(), (Object*)new IRValue(n.res().ty()));
        if (n.memRes() != (IRValue*)0)
            vmap.set((Hashable*)n.memRes(), (Object*)new IRValue(String.withCString("Mem")));
        }

    final void ouApply(IRFunc* fn, IRBlock* B, IRBlock* Lt, IRBlock* X, Map* inL, u32 K)
        {
        // The loop's blocks in function order; the copies go after the last.
        Array* blks = new Array();
        u32 lastIdx = (u32)0;
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(i);
            if (inL.get((Hashable*)bb) == (Object*)0)
                continue;
            blks.add((Object*)bb);
            lastIdx = i;
            }
        Array* made = new Array();
        Map* prev = (Map*)0;
        Map* vmap = (Map*)0;
        Map* bmap = (Map*)0;
        // Each copy's latch and entry; the latches are rewired only once
        // every copy is made, so each is cloned from the untouched original.
        Array* latches = new Array();
        Array* entries = new Array();
        latches.add((Object*)Lt);
        entries.add((Object*)B);
        for (u32 j = (u32)1; j < K; j = j + (u32)1)
            {
            vmap = new Map();
            bmap = new Map();
            // Copy j's header phis are the values copy j-1 sent back.
            for (u32 i = (u32)0; i < B.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)B.phis().get(i);
                IRValue* v = ouIncoming(phi, Lt).val();
                Object* m = prev == (Map*)0 ? (Object*)0 : prev.get((Hashable*)v);
                vmap.set((Hashable*)phi.res(), m == (Object*)0 ? (Object*)v : m);
                }
            for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)blks.get(b);
                String* nm = String.withString(bb.name());
                nm.appendFormat("_ou%lu", j);
                bmap.set((Hashable*)bb, (Object*)new IRBlock(vecUniqueBlockName(fn, nm)));
                }
            // Every result first: a phi, and an instruction in a block listed
            // before the one defining its operand, name values made later.
            for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)blks.get(b);
                if (bb != B)
                    for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                        ouNewResult(vmap, (IRInsn*)bb.phis().get(i));
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    ouNewResult(vmap, (IRInsn*)bb.insns().get(i));
                if (bb.term() != (IRInsn*)0)
                    ouNewResult(vmap, bb.term());
                }
            for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)blks.get(b);
                IRBlock* nb = (IRBlock*)bmap.get((Hashable*)bb);
                if (bb != B)
                    for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                        nb.addPhi(ouClone((IRInsn*)bb.phis().get(i), vmap, bmap));
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    nb.add(ouClone((IRInsn*)bb.insns().get(i), vmap, bmap));
                if (bb.term() != (IRInsn*)0)
                    nb.setTerm(ouClone(bb.term(), vmap, bmap));
                made.add((Object*)nb);
                }
            latches.add(bmap.get((Hashable*)Lt));
            entries.add(bmap.get((Hashable*)B));
            prev = vmap;
            }
        // Each copy but the last falls straight into the next: T is a
        // multiple of K, so its test would always go round.
        for (u32 j = (u32)0; j + (u32)1 < K; j = j + (u32)1)
            {
            IRBlock* lj = (IRBlock*)latches.get(j);
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.copyDbg(lj.term());
            br.add(IROperand.block((IRBlock*)entries.get(j + (u32)1)));
            lj.setTerm(br);
            }
        IRBlock* prevLatch = (IRBlock*)latches.get(K - (u32)1);
        // The last copy tests, and goes round to B or out to X.
        prevLatch.term().ops().set((u32)1, (Object*)IROperand.block(B));
        for (u32 i = (u32)0; i < B.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)B.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                if (((IROperand*)phi.ops().get(k)).blk() == Lt)
                    {
                    phi.ops().set(k, (Object*)IROperand.block(prevLatch));
                    phi.ops().set(k + (u32)1, (Object*)ouSubst(prev, new Map(), (IROperand*)phi.ops().get(k + (u32)1)));
                    }
            }
        // After the loop, every value it made is the last copy's, and X's
        // phis come from the last copy's latch.
        Map* none = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (inL.get((Hashable*)bb) != (Object*)0)
                continue;
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)bb.phis().get(i);
                for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)phi.ops().get(k);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == Lt)
                        phi.ops().set(k, (Object*)IROperand.block(prevLatch));
                    else
                        phi.ops().set(k, (Object*)ouSubst(prev, none, o));
                    }
                }
            for (u32 i = (u32)0; i <= bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = i < bb.insns().count() ? (IRInsn*)bb.insns().get(i) : bb.term();
                if (n == (IRInsn*)0)
                    continue;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    n.ops().set(k, (Object*)ouSubst(prev, none, (IROperand*)n.ops().get(k)));
                }
            }
        fn.blocks().insertAll(lastIdx + (u32)1, made);
        }
    }
