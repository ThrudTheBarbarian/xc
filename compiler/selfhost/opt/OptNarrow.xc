// OptNarrow.xc — the Narrow pass, ported from src/xtc/ir/XTIROptNarrow.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (Narrow)
    {
    // ── narrow ───────────────────────────────────────────────────────────
    //
    // Demanded-width narrowing: an arithmetic result that is immediately
    // truncated is recomputed AT the narrow width, so C-style promotion costs
    // nothing where the result is narrowed anyway (`u16 y = a * b`). The wide
    // op and its Ext feeders are left for the dead-code sweep.
    final void narrow(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            narrowInFunc((IRFunc*)m.funcs().get(f));
        }

    final void narrowInFunc(IRFunc* fn)
        {
        bool changed = true;
        for (u32 round = (u32)0; round < (u32)8; round = round + (u32)1)
            {
            if (!changed)
                return;
            changed = false;
            Map* defOf = defMapInsns(fn);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                if (narrowInBlock(fn, (IRBlock*)fn.blocks().get(b), defOf))
                    changed = true;
            }
        }

    final bool narrowInBlock(IRFunc* fn, IRBlock* bb, Map* defOf)
        {
        bool changed = false;
        u32 idx = (u32)0;
        while (idx < bb.insns().count())
            {
            IRInsn* tr = (IRInsn*)bb.insns().get(idx);
            IRInsn* src = truncSource(tr, defOf);
            if (src == 0)
                {
                idx = idx + (u32)1;
                continue;
                }
            u32 w = self.irWidth(tr.res().ty());
            _narrowInserts = new Array();
            Array* nops = narrowedOperands(fn, defOf, src, tr, w);
            if (nops == 0)
                {
                idx = idx + (u32)1;
                continue;
                }
            // The narrow op REUSES the Trunc's result value, so every consumer
            // follows without being rewritten.
            IRInsn* nOp = IRInsn.with(src.op());
            nOp.copyDbg(tr);
            nOp.setRes(tr.res());
            for (u32 k = (u32)0; k < nops.count(); k = k + (u32)1)
                nOp.add((IROperand*)nops.get(k));
            Array* out = new Array();
            for (u32 k = (u32)0; k < idx; k = k + (u32)1)
                out.add(bb.insns().get(k));
            for (u32 k = (u32)0; k < _narrowInserts.count(); k = k + (u32)1)
                out.add(_narrowInserts.get(k));
            out.add((Object*)nOp);
            for (u32 k = idx + (u32)1; k < bb.insns().count(); k = k + (u32)1)
                out.add(bb.insns().get(k));
            bb.setInsns(out);
            idx = idx + _narrowInserts.count() + (u32)1;
            changed = true;
            }
        return changed;
        }

    // The wide arithmetic this Trunc consumes, when there is one to narrow.
    final IRInsn* truncSource(IRInsn* tr, Map* defOf)
        {
        if (!tr.op().equals(String.withCString("Trunc")))
            return (IRInsn*)0;
        if (tr.res() == 0 || tr.ops().count() < (u32)1)
            return (IRInsn*)0;
        IROperand* o = (IROperand*)tr.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return (IRInsn*)0;
        Object* d = defOf.get((Hashable*)o.val());
        if (d == 0)
            return (IRInsn*)0;
        IRInsn* src = (IRInsn*)d;
        if (!isNarrowable(src.op()))
            return (IRInsn*)0;
        if (src.res() == 0 || src.ops().count() < (u32)2)
            return (IRInsn*)0;
        if (irWidth(src.res().ty()) <= self.irWidth(tr.res().ty()))
            return (IRInsn*)0;
        return src;
        }

    // Each operand at width `w`, or 0 when one cannot be narrowed cleanly —
    // correctness first, the pass simply declines.
    final Array* narrowedOperands(IRFunc* fn, Map* defOf, IRInsn* src, IRInsn* tr, u32 w)
        {
        Array* nops = new Array();
        for (u32 k = (u32)0; k < src.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)src.ops().get(k);
            if (o.kind() == (u8)OPK_IMMI)
                {
                nops.add((Object*)o);
                continue;
                }
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                return (Array*)0;
            // Trunc_w(Ext(x_w)) is x_w — collapse rather than re-truncate.
            Object* d = defOf.get((Hashable*)o.val());
            if (d != 0)
                {
                IRInsn* od = (IRInsn*)d;
                if ((od.op().equals(String.withCString("ZExt")) || od.op().equals(String.withCString("SExt"))) && od.ops().count() >= (u32)1)
                    {
                    IROperand* inner = (IROperand*)od.ops().get((u32)0);
                    if (inner.kind() == (u8)OPK_USE && inner.val() != 0 && self.irWidth(inner.val().ty()) == w)
                        {
                        nops.add((Object*)IROperand.useVal(inner.val()));
                        continue;
                        }
                    }
                }
            u32 ow = self.irWidth(o.val().ty());
            if (ow == w)
                {
                nops.add((Object*)o);
                continue;
                }
            if (ow > w)
                {
                IRValue* rv = new IRValue(tr.res().ty());
                IRInsn* nt = IRInsn.with(String.withCString("Trunc"));
                nt.copyDbg(tr);
                nt.setRes(rv);
                nt.add(o);
                _narrowInserts.add((Object*)nt);
                nops.add((Object*)IROperand.useVal(rv));
                continue;
                }
            return (Array*)0; // narrower than asked: unexpected
            }
        return nops;
        }

    // Ops whose low W bits depend only on the operands' low W bits. Div, the
    // shifts and the remainders are NOT among them: their high bits leak down.
    final bool isNarrowable(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor"));
        }

    // Value -> the INSTRUCTION that defines it, phis excluded (the original's
    // narrow map is built from instructions only).
    final Map* defMapInsns(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != 0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        return defOf;
        }
    }
