// OptPowSquare.xc — the PowSquare pass, ported from src/xtc/ir/XTIROptPowSquare.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (PowSquare)
    {
    // ── pow-square ───────────────────────────────────────────────────────
    //
    // `pow(x, 2)` is a call in the IR and a multiply everywhere else. It runs
    // BEFORE inlining, while the library wrapper's call is still there to match;
    // the wrapper and libm's `pow` are then dropped by the dead-function sweep.
    final void powSquare(IRModule* m)
        {
        if (!_profile.powSquare())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            powInFunc((IRFunc*)m.funcs().get(f));
        }

    final void powInFunc(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!isPowCall(n, defOf))
                    continue;
                IROperand* base = (IROperand*)n.ops().get((u32)1);
                IRInsn* fm = IRInsn.with(String.withCString("FMul"));
                fm.copyDbg(n);
                fm.setRes(n.res());
                fm.add(base);
                fm.add(base);
                bb.insns().set(i, (Object*)fm);
                if (n.memRes() == 0)
                    continue;
                IROperand* memIn = (IROperand*)n.ops().get(n.ops().count() - (u32)1);
                if (memIn.kind() != (u8)OPK_USE)
                    continue;
                self.forwardMem(fn, n.memRes(), memIn.val());
                }
            }
        }

    // `Math$pow__…(base, 2)` — a two-argument call returning a float whose
    // exponent resolves to the literal 2.
    final bool isPowCall(IRInsn* n, Map* defOf)
        {
        if (!n.op().equals(String.withCString("Call")))
            return false;
        if (n.res() == 0)
            return false;
        String* t = n.res().ty();
        if (!t.equals(String.withCString("F32")) && !t.equals(String.withCString("F64")))
            return false;
        if (n.ops().count() != (u32)4)
            return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM || callee.name() == 0)
            return false;
        if (!callee.name().hasPrefix(String.withCString("Math$pow__")))
            return false;
        if (((IROperand*)n.ops().get((u32)1)).kind() != (u8)OPK_USE)
            return false;
        i32 exp = (i32)0;
        if (!resolveInt(defOf, (IROperand*)n.ops().get((u32)2), &exp))
            return false;
        return exp == (i32)2;
        }

    // A compile-time integer, seen through the widening and int↔float
    // conversions the lowering wraps a literal in.
    final bool resolveInt(Map* defOf, IROperand* op, i32* out)
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
            if (o == 0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!isWidening(def.op()))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    final bool isWidening(String* op)
        {
        return op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp"));
        }
    }
