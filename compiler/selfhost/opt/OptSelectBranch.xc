// OptSelectBranch.xc — a float Select whose arm computes becomes a branch (#22).
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptDevirt>

    class Opt (SelectBranch)
    {

    // If-conversion makes every small diamond a Select, which is what lets the
    // inliner take a helper of ternaries (perlin's grad). In a loop, a float
    // Select on one bit of a value (`(h & 2) != 0 ? 0 - u : u`) then makes
    // every iteration wait for that value — perlin's hash, two loads deep —
    // and computes both arms. GCC keeps a branch where an arm computes: the
    // branch is predicted (perlin's hash bits hold for runs of pixels), the
    // arithmetic runs only when taken, and nothing waits. So, late, after the
    // inliner and every loop pass: such a Select becomes a branch around the
    // arithmetic its arm alone uses, and a phi.
    final void selectBranch(IRModule* m)
        {
        if (!_profile.selectBranch())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 guard = (u32)0;
            while (guard < (u32)SB_MAX && sbOne(fn))
                guard = guard + (u32)1;
            }
        }

    final bool sbFloatTy(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
        }

    final bool sbArith(String* op)
        {
        return op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub"))
            || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FNeg"));
        }

    // How many operands in fn read v.
    final u32 sbUses(IRFunc* fn, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* all = new Array();
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                all.add(bb.phis().get(i));
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                all.add(bb.insns().get(i));
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* u = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < u.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)u.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() == v)
                        n = n + (u32)1;
                    }
                }
            }
        return n;
        }

    // The condition tests one bit: ICmp EQ/NE of (x & 2^k) against 0.
    final bool sbBitTest(Map* defOf, IROperand* c)
        {
        if (c.kind() != (u8)OPK_USE || c.val() == (IRValue*)0)
            return false;
        IRInsn* cmp = (IRInsn*)defOf.get((Hashable*)c.val());
        if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() != (u32)2
            || cmp.pred() == (String*)0)
            return false;
        if (!cmp.pred().equals(String.withCString("EQ")) && !cmp.pred().equals(String.withCString("NE")))
            return false;
        i64 z = (i64)1;
        if (!self.constValue(defOf, (IROperand*)cmp.ops().get((u32)1), &z) || z != (i64)0)
            return false;
        IROperand* a = (IROperand*)cmp.ops().get((u32)0);
        if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0)
            return false;
        IRInsn* an = (IRInsn*)defOf.get((Hashable*)a.val());
        if (an == (IRInsn*)0 || !an.op().equals(String.withCString("And")) || an.ops().count() != (u32)2)
            return false;
        i64 k = (i64)0;
        if (!self.constValue(defOf, (IROperand*)an.ops().get((u32)1), &k) || k <= (i64)0)
            return false;
        return (k & (k - (i64)1)) == (i64)0;
        }

    // Per block index, 1 when the block is inside a loop: between the target
    // and the source of a branch back to it, inclusive (dvInLoop's question,
    // asked of every block at once; asking it per block was quadratic in a
    // function of many blocks, the class table of a module of many classes).
    final Array* sbLoopBlocks(IRFunc* fn)
        {
        u32 nb = fn.blocks().count();
        Map* idx = new Map();
        Array* cov = new Array();
        for (u32 b = (u32)0; b < nb; b = b + (u32)1)
            {
            idx.set((Hashable*)fn.blocks().get(b), (Object*)Number.withU32(b));
            cov.add((Object*)Number.withI32((i32)0));
            }
        cov.add((Object*)Number.withI32((i32)0));
        for (u32 u = (u32)0; u < nb; u = u + (u32)1)
            {
            IRInsn* t = ((IRBlock*)fn.blocks().get(u)).term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                Object* ho = idx.get((Hashable*)o.blk());
                if (ho == (Object*)0)
                    continue;
                u32 h = ((Number*)ho).asU32();
                if (h > u)
                    continue;
                cov.set(h, (Object*)Number.withI32(((Number*)cov.get(h)).asI32() + (i32)1));
                cov.set(u + (u32)1, (Object*)Number.withI32(((Number*)cov.get(u + (u32)1)).asI32() - (i32)1));
                }
            }
        Array* out = new Array();
        i32 run = (i32)0;
        for (u32 b = (u32)0; b < nb; b = b + (u32)1)
            {
            run = run + ((Number*)cov.get(b)).asI32();
            out.add((Object*)Number.withU32(run > (i32)0 ? (u32)1 : (u32)0));
            }
        return out;
        }

    // The index in B of the instruction defining v, or -1.
    final i32 sbIndexIn(IRBlock* B, IRValue* v)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            if (((IRInsn*)B.insns().get(i)).res() == v)
                return (i32)i;
        return (i32)-1;
        }

    final bool sbOne(IRFunc* fn)
        {
        Map* defOf = self.defMapAll(fn);
        Array* inLoop = sbLoopBlocks(fn);
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* B = (IRBlock*)fn.blocks().get(bi);
            if (((Number*)inLoop.get(bi)).asU32() == (u32)0)
                continue;
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)B.insns().get(i);
                if (!n.op().equals(String.withCString("Select")) || n.res() == (IRValue*)0 || n.ops().count() != (u32)3
                    || !sbFloatTy(n.res().ty()))
                    continue;
                if (!sbBitTest(defOf, (IROperand*)n.ops().get((u32)0)))
                    continue;
                // The arm whose value only this Select reads and this block
                // computes, before it.
                u32 arm = (u32)0;
                i32 at = (i32)-1;
                for (u32 k = (u32)1; k <= (u32)2 && arm == (u32)0; k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    i32 j = sbIndexIn(B, o.val());
                    if (j < (i32)0 || (u32)j >= i || !sbArith(((IRInsn*)B.insns().get((u32)j)).op()))
                        continue;
                    if (sbUses(fn, o.val()) != (u32)1)
                        continue;
                    arm = k;
                    at = j;
                    }
                if (arm == (u32)0)
                    continue;
                sbApply(fn, bi, i, (u32)at, arm);
                return true;
                }
            }
        return false;
        }

    // B: ... d (the arm's arithmetic) ... n = Select c, a, b ... rest
    //  ->  B: ... CondBranch c, A|J, J|A
    //      A: d; Branch J
    //      J: n = Phi [(A, d), (B, the other)]; rest
    final void sbApply(IRFunc* fn, u32 bi, u32 i, u32 at, u32 arm)
        {
        IRBlock* B = (IRBlock*)fn.blocks().get(bi);
        IRInsn* n = (IRInsn*)B.insns().get(i);
        IRInsn* d = (IRInsn*)B.insns().get(at);
        _sbSeq = _sbSeq + (u32)1;
        IRBlock* A = new IRBlock(String.withFormat("%s_sb%lu_a", B.name().cString(), _sbSeq));
        IRBlock* J = new IRBlock(String.withFormat("%s_sb%lu_j", B.name().cString(), _sbSeq));
        // J takes what follows the Select, and B's terminator.
        for (u32 k = i + (u32)1; k < B.insns().count(); k = k + (u32)1)
            J.add((IRInsn*)B.insns().get(k));
        J.setTerm(B.term());
        dvRetargetSuccPhis(fn, J, B);
        // A computes the arm.
        A.add(d);
        IRInsn* ab = IRInsn.with(String.withCString("Branch"));
        ab.add(IROperand.block(J));
        A.setTerm(ab);
        // B keeps what came before, less the arm.
        Array* keep = new Array();
        for (u32 k = (u32)0; k < i; k = k + (u32)1)
            if (k != at)
                keep.add(B.insns().get(k));
        B.insns().removeAll();
        for (u32 k = (u32)0; k < keep.count(); k = k + (u32)1)
            B.add((IRInsn*)keep.get(k));
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add((IROperand*)n.ops().get((u32)0));
        cb.add(IROperand.block(arm == (u32)1 ? A : J));
        cb.add(IROperand.block(arm == (u32)1 ? J : A));
        B.setTerm(cb);
        // J's phi is the Select's result.
        IRInsn* ph = IRInsn.with(String.withCString("Phi"));
        ph.setRes(n.res());
        ph.add(IROperand.block(A));
        ph.add((IROperand*)n.ops().get(arm));
        ph.add(IROperand.block(B));
        ph.add((IROperand*)n.ops().get(arm == (u32)1 ? (u32)2 : (u32)1));
        J.phis().add(ph);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            blocks.add(fn.blocks().get(b));
            if (b == bi)
                {
                blocks.add((Object*)A);
                blocks.add((Object*)J);
                }
            }
        fn.setBlocks(blocks);
        }

    }
