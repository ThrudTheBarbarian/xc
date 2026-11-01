// OptSqrtIntrinsic.xc — the SqrtIntrinsic pass, ported from src/xtc/ir/XTIROptSqrtIntrinsic.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (SqrtIntrinsic)
    {
    // ── sqrt-intrinsic ───────────────────────────────────────────────────
    //
    // `sqrt(x)` is a library CALL in the IR and one instruction on a target
    // with a hardware sqrt. Rewriting it here, rather than name-matching in the
    // back end, is what lets the call be inlined-through and the now-callerless
    // extern dropped by the next dead-function sweep.
    final void sqrtIntrinsic(IRModule* m)
        {
        if (!_profile.sqrtIntrinsic())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            sqrtInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    final void sqrtInFunc(IRModule* m, IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!isSqrtCall(n))
                    continue;
                IROperand* arg = (IROperand*)n.ops().get((u32)1);
                IRInsn* fs = IRInsn.with(String.withCString("FSqrt"));
                fs.copyDbg(n);
                fs.setRes(n.res());
                fs.add(arg);
                bb.insns().set(i, (Object*)fs);
                // sqrt is PURE: it produces no memory, so anything that used the
                // call's memory result now uses the call's memory INPUT.
                if (n.memRes() == 0)
                    continue;
                IROperand* memIn = (IROperand*)n.ops().get(n.ops().count() - (u32)1);
                if (memIn.kind() != (u8)OPK_USE)
                    continue;
                self.forwardMem(fn, n.memRes(), memIn.val());
                }
            }
        }

    // A one-argument call returning a float, to one of the four names a sqrt
    // reaches the IR under: libm's own (arm9 calls those directly) and the
    // `_xm_` intrinsic the arch libraries use.
    final bool isSqrtCall(IRInsn* n)
        {
        if (!n.op().equals(String.withCString("Call")))
            return false;
        if (n.res() == 0)
            return false;
        String* t = n.res().ty();
        if (!t.equals(String.withCString("F32")) && !t.equals(String.withCString("F64")))
            return false;
        if (n.ops().count() != (u32)3)
            return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM || callee.name() == 0)
            return false;
        String* nm = callee.name();
        if (!nm.equals(String.withCString("sqrt")) && !nm.equals(String.withCString("sqrtf")) && !nm.equals(String.withCString("_xm_sqrt")) && !nm.equals(String.withCString("_xm_sqrtf")))
            return false;
        return ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE;
        }
    }
