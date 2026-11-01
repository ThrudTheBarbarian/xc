// OptConstHoist.xc — the ConstHoist pass, ported from src/xtc/ir/XTIROptConstHoist.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptAggExpand>

    class Opt (ConstHoist)
    {

    final void constHoist(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            _hoistFn = (IRFunc*)m.funcs().get(f);
            chInFunc(m, (IRFunc*)m.funcs().get(f));
            chHoistMulImms((IRFunc*)m.funcs().get(f));
            if (_profile.hoistCmpImm())
                chHoistCmpImms((IRFunc*)m.funcs().get(f));
            }
        }

    // Can arm64's cmp (or cmn, for the negation) take `v` as an immediate? A
    // 12-bit value, optionally shifted left by 12, of the operand's width. As
    // the reference's chArm64CmpImm.
    final bool chCmpImmFits(u64 x)
        {
        return x <= (u64)$FFF || ((x & (u64)$FFF) == (u64)0 && x <= (u64)$FFF000);
        }
    final bool chArm64CmpImm(i64 v, u32 width)
        {
        u64 mask = width >= (u32)8 ? (u64)0 - (u64)1 : ((u64)1 << (u64)(width * (u32)8)) - (u64)1;
        u64 u = (u64)v & mask;
        u64 n = ((u64)0 - (u64)v) & mask;
        return chCmpImmFits(u) || chCmpImmFits(n);
        }

    // A loop's compare against an immediate arm64's cmp cannot take becomes a
    // compare against a Const in the preheader (struct_copy's one-block loop
    // rebuilt 2200000000 with movz + movk every turn). The loop is the header
    // and its body, or a one-block loop branching to itself. As the
    // reference's hoistCmpImmediates.
    final void chHoistCmpImms(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(hi);
            IRInsn* term = H.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))
                || term.ops().count() < (u32)3)
                continue;
            IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
            Array* loop = (Array*)0;
            if (t0 == H || t1 == H)
                {
                loop = new Array();
                loop.add((Object*)H);
                }
            else
                {
                loop = chLoopBody(fn, H, t0, t1);
                if (loop == (Array*)0)
                    loop = chLoopBody(fn, H, t1, t0);
                if (loop != (Array*)0)
                    loop.add((Object*)H);
                }
            if (loop == (Array*)0)
                continue;
            IRBlock* PH = (IRBlock*)0;
            u32 preds = (u32)0;
            for (u32 pi = (u32)0; pi < fn.blocks().count(); pi = pi + (u32)1)
                {
                IRBlock* p = (IRBlock*)fn.blocks().get(pi);
                if (p.term() == (IRInsn*)0) continue;
                for (u32 q = (u32)0; q < p.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)p.term().ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == H)
                        {
                        preds = preds + (u32)1;
                        if (!chHas(loop, p) && chDominates(fn, p, H))
                            PH = p;
                        }
                    }
                }
            if (PH == (IRBlock*)0 || preds != (u32)2 || PH == H)
                continue;
            Map* made = new Map();
            for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(bi);
                if (!chHas(loop, bb))
                    continue;
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    if (!n.op().equals(String.withCString("ICmp")) || n.ops().count() != (u32)2)
                        continue;
                    u32 side = (u32)2;
                    if (((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_IMMI) side = (u32)1;
                    else if (((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_IMMI) side = (u32)0;
                    if (side == (u32)2)
                        continue;
                    IROperand* imm = (IROperand*)n.ops().get(side);
                    IROperand* oth = (IROperand*)n.ops().get((u32)1 - side);
                    String* ity = imm.ty();
                    if (ity == (String*)0 && oth.kind() == (u8)OPK_USE && oth.val() != (IRValue*)0)
                        ity = oth.val().ty();
                    if (ity == (String*)0)
                        continue;
                    u32 w = self.irWidth(ity);
                    if (w == (u32)0 || chArm64CmpImm(imm.imm(), w))
                        continue;
                    String* key = new String();
                    key.appendFormat("%lld|%s", imm.imm(), ity.cString());
                    Object* have = made.get((Hashable*)key);
                    if (have == (Object*)0)
                        {
                        IRValue* cv = new IRValue(ity);
                        IRInsn* cn = IRInsn.with(String.withCString("Const"));
                        cn.copyDbg(n);
                        cn.setRes(cv);
                        cn.add(imm);
                        PH.insns().add((Object*)cn);
                        made.set((Hashable*)key, (Object*)cv);
                        have = (Object*)cv;
                        }
                    n.ops().set(side, (Object*)IROperand.useVal((IRValue*)have));
                    }
                }
            }
        }

    // arm64 has no immediate form of `mul`, so every `x * K` in a loop body
    // pays a `mov wS, #K` to put the constant where the multiply can read it —
    // every iteration, once per multiply. call_depth's inlined body does four
    // of them for the same literal 3. Turning the immediate into a Const in the
    // PREHEADER gives it a value the allocator can home.
    // Does `a` dominate `b`? By definition: every path from the entry to `b`
    // goes through `a`, i.e. `b` is unreachable from the entry once `a` is
    // removed.
    //
    // Written out rather than taken from dominators() because the ORIGINAL has
    // a different dominator implementation and the two disagreed on real
    // functions — five new opt-diff divergences. One definition, spelled the
    // same way on both sides, is worth more than a shared one that is only
    // nearly shared.
    final bool chDominates(IRFunc* fn, IRBlock* a, IRBlock* b)
        {
        if (a == b)
            return true;
        if (fn.blocks().count() == (u32)0)
            return false;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        if (a == entry)
            return true;
        Array* seen = new Array();
        Array* work = new Array();
        seen.add((Object*)entry);
        work.add((Object*)entry);
        while (work.count() > (u32)0)
            {
            IRBlock* n = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (n == a)
                continue;               // removed: do not go through it
            if (n.term() == (IRInsn*)0)
                continue;
            for (u32 q = (u32)0; q < n.term().ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)n.term().ops().get(q);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                if (hasBlock(seen, o.blk()))
                    continue;
                seen.add((Object*)o.blk());
                work.add((Object*)o.blk());
                }
            }
        return !self.hasBlock(seen, b);
        }

    final void chHoistMulImms(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(hi);
            IRInsn* term = H.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))
                || term.ops().count() < (u32)3)
                continue;
            IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
            Array* body = chLoopBody(fn, H, t0, t1);
            if (body == (Array*)0)
                body = chLoopBody(fn, H, t1, t0);
            if (body == (Array*)0)
                continue;

            // The preheader is the header's predecessor that is NOT in the
            // body. Taking "not the entry block" instead picks the LATCH, which
            // is inside the loop, and plants the constant after its own uses.
            IRBlock* PH = (IRBlock*)0;
            u32 preds = (u32)0;
            for (u32 pi = (u32)0; pi < fn.blocks().count(); pi = pi + (u32)1)
                {
                IRBlock* p = (IRBlock*)fn.blocks().get(pi);
                if (p.term() == (IRInsn*)0) continue;
                for (u32 q = (u32)0; q < p.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)p.term().ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == H)
                        {
                        preds = preds + (u32)1;
                        // The preheader is the predecessor that DOMINATES the
                        // header — not merely one outside the body walk. That
                        // walk is capped and a nested loop overruns it, and
                        // then BOTH predecessors look like preheaders and the
                        // last in block order won, which is the latch. The
                        // Const landed inside the loop with its uses outside
                        // it, and the value was read where it was never
                        // defined: sieve on x86-64 computed `ts.sec * ts.sec`
                        // for `ts.sec * 1000000` and printed 1.9e11
                        // microseconds (bug 224).
                        //
                        // Dominance is the property actually wanted, and it
                        // still holds for a nested loop's preheader, which IS
                        // reachable from its header by going round the outer
                        // loop.
                        if (!chHas(body, p) && chDominates(fn, p, H))
                            PH = p;
                        }
                    }
                }
            if (PH == (IRBlock*)0 || preds != (u32)2 || PH == H)
                continue;
            chRewriteMuls(fn, body, PH);
            }
        }

    // Every block reachable from `entry` without going through `other`, when
    // that region closes back on H. nil when it escapes or is too large.
    final Array* chLoopBody(IRFunc* fn, IRBlock* H, IRBlock* entry, IRBlock* other)
        {
        if (entry == (IRBlock*)0)
            return (Array*)0;
        Array* seen = new Array();
        Array* work = new Array();
        work.add((Object*)entry);
        bool closes = false;
        while (work.count() > (u32)0)
            {
            IRBlock* b = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (b == H) { closes = true; continue; }
            if (b == other || chHas(seen, b)) continue;
            if (b.term() == (IRInsn*)0) return (Array*)0;
            seen.add((Object*)b);
            if (seen.count() > (u32)8) return (Array*)0;
            for (u32 q = (u32)0; q < b.term().ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)b.term().ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0)
                    work.add((Object*)o.blk());
                }
            }
        if (!closes || seen.count() == (u32)0)
            return (Array*)0;
        return seen;
        }

    final bool chHas(Array* a, IRBlock* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRBlock*)a.get(i) == b)
                return true;
        return false;
        }

    final void chRewriteMuls(IRFunc* fn, Array* body, IRBlock* PH)
        {
        Map* made = new Map();
        // FUNCTION BLOCK ORDER, not the order chLoopBody's DFS returned. The
        // Consts are appended to the preheader as they are first met, so the
        // walk order IS the emitted order, and the reference walked a SET —
        // hash order. Same constants, different value numbers, identical code.
        // private:docs/bugs/242.
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(bi);
            if (!chHas(body, bb))
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("Mul")) || n.res() == (IRValue*)0
                    || n.ops().count() < (u32)2)
                    continue;
                u32 side = (u32)2;
                if (((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_IMMI) side = (u32)1;
                else if (((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_IMMI) side = (u32)0;
                if (side == (u32)2)
                    continue;
                IROperand* imm = (IROperand*)n.ops().get(side);
                String* ity = imm.ty() == (String*)0 ? n.res().ty() : imm.ty();
                String* key = new String();
                key.appendFormat("%ld|%s", (i32)imm.imm(), ity.cString());
                Object* have = made.get((Hashable*)key);
                if (have == (Object*)0)
                    {
                    IRValue* cv = new IRValue(ity);
                    IRInsn* cn = IRInsn.with(String.withCString("Const"));
                    cn.copyDbg(n);
                    cn.setRes(cv);
                    cn.add(imm);
                    PH.insns().add((Object*)cn);
                    made.set((Hashable*)key, (Object*)cv);
                    have = (Object*)cv;
                    }
                n.ops().set(side, (Object*)IROperand.useVal((IRValue*)have));
                }
            }
        }

    // Is `b` on a cycle: can it reach itself through its successors?
    static bool chOnCycle(IRBlock* b)
        {
        Array* seen = new Array();
        Array* work = new Array();
        if (b.term() == (IRInsn*)0)
            return false;
        for (u32 i = (u32)0; i < b.term().ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)b.term().ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0 && !seen.contains((Object*)o.blk()))
                {
                seen.add((Object*)o.blk());
                work.add((Object*)o.blk());
                }
            }
        while (work.count() > (u32)0)
            {
            IRBlock* n = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (n == b)
                return true;
            if (n.term() == (IRInsn*)0)
                continue;
            for (u32 i = (u32)0; i < n.term().ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)n.term().ops().get(i);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0 && !seen.contains((Object*)o.blk()))
                    {
                    seen.add((Object*)o.blk());
                    work.add((Object*)o.blk());
                    }
                }
            }
        return false;
        }

    final void chInFunc(IRModule* m, IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);

        // Grouped by a value-equivalence key, in FIRST-APPEARANCE order: the
        // group order fixes the order the canonicals go in at the entry front,
        // so a hash-ordered walk would make the printed IR depend on hashing.
        Array* keys = new Array();   // String@
        Array* groups = new Array(); // Array@ of IRInsn@
        Array* firstBlk = new Array(); // IRBlock@ of each group's first member
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                String* key = chKeyFor(n);
                if (key == (String*)0)
                    continue;
                u32 gi = keys.count();
                for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
                    if (((String*)keys.get(k)).equals(key))
                        {
                        gi = k;
                        break;
                        }
                if (gi == keys.count())
                    {
                    keys.add((Object*)key);
                    groups.add((Object*)new Array());
                    firstBlk.add((Object*)bb);
                    }
                ((Array*)groups.get(gi)).add((Object*)n);
                }
            }

        Map* replace = new Map();
        Array* dead = new Array();
        Array* hoist = new Array();
        for (u32 gi = (u32)0; gi < groups.count(); gi = gi + (u32)1)
            {
            Array* g = (Array*)groups.get(gi);
            // A float constant used once is moved too when it sits on a loop:
            // x86 builds one with a mov and a movd (arm64 with up to three
            // instructions for a value fmov cannot encode) EVERY iteration,
            // where from the entry it is a register or a folded slot read.
            // Positive zero stays: xorps / movi make it in one.
            bool loopConst = false;
            if (g.count() == (u32)1)
                {
                IRInsn* only = (IRInsn*)g.get((u32)0);
                IROperand* oa = (IROperand*)only.ops().get((u32)0);
                if (only.op().equals(String.withCString("Const")) && oa.kind() == (u8)OPK_IMMF
                    && oa.fpHex() != (String*)0 && !oa.fpHex().equals(String.withCString("0000000000000000"))
                    && (IRBlock*)firstBlk.get(gi) != entry && chOnCycle((IRBlock*)firstBlk.get(gi)))
                    loopConst = true;
                }
            if (g.count() < (u32)2 && !loopConst)
                continue;                           // only dedupe repeats
            IRInsn* canon = (IRInsn*)g.get((u32)0); // earliest occurrence
            hoist.add((Object*)canon);
            for (u32 i = (u32)1; i < g.count(); i = i + (u32)1)
                {
                IRInsn* dup = (IRInsn*)g.get(i);
                replace.set((Hashable*)dup.res(), (Object*)canon.res());
                dead.add((Object*)dup);
                }
            }
        if (hoist.count() == (u32)0)
            return;

        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            dead.add(hoist.get(i));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = bb.insns().count(); i > (u32)0; i = i - (u32)1)
                if (hasInsn(dead, (IRInsn*)bb.insns().get(i - (u32)1)))
                    bb.insns().removeAt(i - (u32)1);
            }
        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            entry.insns().insert(i, hoist.get(i));

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.phis().get(k), replace);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.insns().get(k), replace);
            if (bb.term() != (IRInsn*)0)
                self.pivReplaceIn(bb.term(), replace);
            }
        }

    // The value-equivalence key, or null when the instruction is not a
    // candidate. A float Const is keyed by its type and RAW BITS (the printer
    // spells them, so two literals that print alike are alike); an AddrOf is
    // keyed by symbol name and pointee spelling, because merging a Ptr(U8)
    // base into a Ptr(Agg) access would mis-size its stride.
    final String* chKeyFor(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return (String*)0;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        if (n.op().equals(String.withCString("Const")) && a.kind() == (u8)OPK_IMMF && n.res().ty() != (String*)0)
            {
            String* k = String.withCString("f:");
            k.append(n.res().ty());
            k.appendCString(":");
            if (a.fpHex() != (String*)0)
                k.append(a.fpHex());
            return k;
            }
        if (_profile.hoistGlobalAddr() && n.op().equals(String.withCString("AddrOf")) && a.kind() == (u8)OPK_SYM && n.res().ty() != (String*)0 && n.res().ty().hasPrefix(String.withCString("Ptr(")))
            {
            String* k = String.withCString("a:");
            k.append(a.name());
            k.appendCString(":");
            k.append(n.res().ty()); // carries pointee AND window
            return k;
            }
        // A pinned local IS a frame slot, so its address is one value for the
        // whole function however many times it is taken. The unrollers clone
        // the AddrOf with the rest of the body: matrix_mul's k loop ends up
        // with 32 copies of `AddrOf a` and 32 of `AddrOf b`, 64 live values
        // where two would do.
        if (_profile.hoistLocalAddr() && n.op().equals(String.withCString("AddrOf"))
            && a.kind() == (u8)OPK_USE && n.res().ty() != (String*)0
            && n.res().ty().hasPrefix(String.withCString("Ptr("))
            && _hoistFn != (IRFunc*)0 && self.aeIsPinned(_hoistFn, a.val()))
            {
            String* k = String.withCString("l:");
            k.appendFormat("%ld", (i32)a.val().seq());
            k.appendCString(":");
            k.append(n.res().ty()); // carries pointee AND window
            return k;
            }
        return (String*)0;
        }
    }
