// OptNarrowIV.xc — the NarrowIV pass, ported from src/xtc/ir/XTIROptNarrowIV.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptStrengthReduce>

    class Opt (NarrowIV)
    {

    // ── narrow-iv ────────────────────────────────────────────────────────
    //
    // A counted loop's induction variable is recomputed at the smallest width
    // that holds its range, so a 4-byte compare and increment become 1-byte on
    // an 8-bit target. Runs last, on the final loop shape; the dead-code sweep
    // after it drops the now-orphaned wide bound.
    final void narrowIV(IRModule* m)
        {
        if (!_profile.narrowIV())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 guard = (u32)0;
            while (guard < (u32)256 && nivOne(fn))
                guard = guard + (u32)1;
            }
        }

    final bool nivOne(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            if (!nivShape(fn, H, defOf))
                continue;
            if (!nivUsesOK(fn))
                continue;
            nivApply(fn, H);
            return true;
            }
        return false;
        }

    final bool nivShape(IRFunc* fn, IRBlock* H, Map* defOf)
        {
        _nivPhi = (IRInsn*)0;
        _nivCmp = (IRInsn*)0;
        _nivAdd = (IRInsn*)0;
        _nivPre = (IRBlock*)0;
        _nivIncBlk = (IRBlock*)0;
        if (H.phis().count() == (u32)0)
            return false;
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)1)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* co = defOf.get((Hashable*)c0.val());
        if (co == (Object*)0)
            return false;
        IRInsn* cmp = (IRInsn*)co;
        if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() != (u32)2)
            return false;
        if (!self.hasInsn(H.insns(), cmp))
            return false; // the guard is computed in H
        String* pred = cmp.pred();
        if (pred == (String*)0)
            return false;
        if (!pred.equals(String.withCString("SLT")) && !pred.equals(String.withCString("SLE")) && !pred.equals(String.withCString("ULT")) && !pred.equals(String.withCString("ULE")))
            return false;
        IROperand* l = (IROperand*)cmp.ops().get((u32)0);
        if (l.kind() != (u8)OPK_USE)
            return false; // the iv is on the left
        IRValue* iv = l.val();

        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == iv)
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0 || ivPhi.ops().count() != (u32)4)
            return false;
        if (!self.isIntType(iv.ty()))
            return false;
        u32 curW = self.srWidth(iv.ty());

        i64 bound = (i64)0;
        if (!nivConst(defOf, (IROperand*)cmp.ops().get((u32)1), &bound) || bound < (i64)0)
            return false;

        // One incoming is the loop-entry init (a const >= 0), the other the
        // latch value Add(iv, step) with step > 0.
        IRBlock* ph = (IRBlock*)0;
        i64 c = (i64)0;
        i64 step = (i64)0;
        IRInsn* incAdd = (IRInsn*)0;
        bool haveInit = false;
        bool haveNext = false;
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
            {
            IROperand* blkOp = (IROperand*)ivPhi.ops().get((u32)2 * k);
            IROperand* useOp = (IROperand*)ivPhi.ops().get((u32)2 * k + (u32)1);
            if (blkOp.kind() != (u8)OPK_BLOCK || useOp.kind() != (u8)OPK_USE)
                return false;
            Object* dobj = defOf.get((Hashable*)useOp.val());
            if (dobj != (Object*)0)
                {
                IRInsn* d = (IRInsn*)dobj;
                if (d.op().equals(String.withCString("Add")) && d.ops().count() == (u32)2)
                    {
                    IROperand* a = (IROperand*)d.ops().get((u32)0);
                    IROperand* bb2 = (IROperand*)d.ops().get((u32)1);
                    i64 s = (i64)0;
                    bool formsInc = false;
                    if (a.kind() == (u8)OPK_USE && a.val() == iv && nivConst(defOf, bb2, &s))
                        formsInc = true;
                    else if (bb2.kind() == (u8)OPK_USE && bb2.val() == iv && nivConst(defOf, a, &s))
                        formsInc = true;
                    if (formsInc && s > (i32)0)
                        {
                        incAdd = d;
                        step = s;
                        haveNext = true;
                        continue;
                        }
                    }
                }
            if (!nivConst(defOf, useOp, &c) || c < (i64)0)
                return false;
            ph = blkOp.blk();
            haveInit = true;
            }
        if (!haveInit || !haveNext || ph == (IRBlock*)0 || incAdd == (IRInsn*)0)
            return false;

        i32 maxV = bound + step; // a safe upper bound on any value the iv holds
        u32 newW = maxV <= (i32)255 ? (u32)1 : (maxV <= (i32)65535 ? (u32)2 : (u32)4);
        if (newW >= curW)
            return false; // already minimal

        IRBlock* incBlk = (IRBlock*)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (hasInsn(((IRBlock*)fn.blocks().get(b)).insns(), incAdd))
                {
                incBlk = (IRBlock*)fn.blocks().get(b);
                break;
                }
        if (incBlk == (IRBlock*)0)
            return false;

        _nivPhi = ivPhi;
        _nivCmp = cmp;
        _nivAdd = incAdd;
        _nivPre = ph;
        _nivIncBlk = incBlk;
        _nivInit = c;
        _nivStep = step;
        _nivBound = bound;
        _nivNewW = newW;
        _nivPred = pred;
        return true;
        }

    // Every DIRECT use of the iv and of its next value must tolerate a narrower
    // one. The iv is an integer, so inside an ElementAddr it can only be the
    // index, never the base; a ZExt/SExt of it keeps the same logical value.
    // Anything else observes the wide bit pattern and refuses the narrowing.
    final bool nivUsesOK(IRFunc* fn)
        {
        IRValue* iv = _nivPhi.res();
        IRValue* next = _nivAdd.res();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                if (!nivUseOK((IRInsn*)bb.phis().get(k), iv, next))
                    return false;
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                if (!nivUseOK((IRInsn*)bb.insns().get(k), iv, next))
                    return false;
            if (bb.term() != (IRInsn*)0 && !nivUseOK(bb.term(), iv, next))
                return false;
            }
        return true;
        }

    final bool nivUseOK(IRInsn* n, IRValue* iv, IRValue* next)
        {
        bool wide = n.op().equals(String.withCString("ElementAddr")) || n.op().equals(String.withCString("ZExt")) || n.op().equals(String.withCString("SExt"));
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            if (o.val() == iv)
                {
                if (n != _nivCmp && n != _nivAdd && !wide)
                    return false;
                }
            else if (o.val() == next)
                {
                if (n != _nivPhi && !wide)
                    return false;
                }
            }
        return true;
        }

    final void nivApply(IRFunc* fn, IRBlock* H)
        {
        String* nt = _nivNewW == (u32)1 ? String.withCString("U8")
                                        : String.withCString("U16");
        // The narrowed compare is unsigned: the range is known non-negative, so
        // a signed predicate over the narrow width would read the top bit as a
        // sign.
        String* np = _nivPred.equals(String.withCString("SLT"))
                         ? String.withCString("ULT")
                         : (_nivPred.equals(String.withCString("SLE"))
                                ? String.withCString("ULE")
                                : _nivPred);

        IRValue* oldIv = _nivPhi.res();
        IRValue* oldNext = _nivAdd.res();
        IRValue* newIv = new IRValue(nt);
        IRValue* newNext = new IRValue(nt);

        // The narrowed init constant, materialised in the preheader.
        IRValue* initC = new IRValue(nt);
        IRInsn* initI = IRInsn.with(String.withCString("Const"));
        initI.setRes(initC);
        initI.add(IROperand.immI(_nivInit, nt));
        _nivPre.insns().add((Object*)initI);

        IRInsn* nPhi = IRInsn.with(String.withCString("Phi"));
        nPhi.setRes(newIv);
        nPhi.add(IROperand.block(_nivPre));
        nPhi.add(IROperand.useVal(initC));
        nPhi.add(IROperand.block(_nivIncBlk));
        nPhi.add(IROperand.useVal(newNext));
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            if ((IRInsn*)H.phis().get(i) == _nivPhi)
                {
                H.phis().set(i, (Object*)nPhi);
                break;
                }

        IRInsn* nAdd = IRInsn.with(String.withCString("Add"));
        nAdd.setRes(newNext);
        nAdd.add(IROperand.useVal(newIv));
        nAdd.add(IROperand.immI(_nivStep, nt));
        for (u32 i = (u32)0; i < _nivIncBlk.insns().count(); i = i + (u32)1)
            if ((IRInsn*)_nivIncBlk.insns().get(i) == _nivAdd)
                {
                _nivIncBlk.insns().set(i, (Object*)nAdd);
                break;
                }

        nivRewriteGuard(H, np, nt, newIv);

        // The remaining direct uses — ElementAddr indices and the extensions.
        // The rebuilt phi / add / guard already name the new values.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                nivRemap((IRInsn*)bb.phis().get(k), oldIv, newIv, oldNext, newNext);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                nivRemap((IRInsn*)bb.insns().get(k), oldIv, newIv, oldNext, newNext);
            if (bb.term() != (IRInsn*)0)
                nivRemap(bb.term(), oldIv, newIv, oldNext, newNext);
            }
        }

    // Split out for the frame budget alone.
    final void nivRewriteGuard(IRBlock* H, String* np, String* nt, IRValue* newIv)
        {
        IRInsn* nCmp = IRInsn.with(String.withCString("ICmp"));
        nCmp.setRes(_nivCmp.res());
        nCmp.setPred(np);
        nCmp.add(IROperand.useVal(newIv));
        nCmp.add(IROperand.immI(_nivBound, nt));
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if ((IRInsn*)H.insns().get(i) == _nivCmp)
                {
                H.insns().set(i, (Object*)nCmp);
                break;
                }
        }

    final void nivRemap(IRInsn* n, IRValue* oldIv, IRValue* newIv,
                  IRValue* oldNext, IRValue* newNext)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            if (o.val() == oldIv)
                n.ops().set(i, (Object*)IROperand.useVal(newIv));
            else if (o.val() == oldNext)
                n.ops().set(i, (Object*)IROperand.useVal(newNext));
            }
        }

    // A constant through Const and the width casts that preserve a
    // non-negative value — including Bitcast, which the unroller's resolver
    // does not follow.
  // i64: IROperand.imm() is already 64-bit, and the reference holds every
  // one of these in an int64_t. Narrowing here made a u32 loop bound above
  // 2^31 come back NEGATIVE, and every guard that tests it silently gave
  // up. private:docs/bugs/243.
    final bool nivConst(Map* defOf, IROperand* op, i64* out)
        {
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
            if (def.ops().count() < (u32)1)
                return false;
            if (def.op().equals(String.withCString("Const")))
                {
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Bitcast")))
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }
    }
