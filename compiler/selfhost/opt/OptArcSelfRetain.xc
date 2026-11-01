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
    }
