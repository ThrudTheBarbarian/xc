// OptFpContract.xc — the FpContract pass, ported from src/xtc/ir/XTIROptFpContract.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (FpContract)
    {

    // ── fp-contract ─────────────────────────────────────────────────────────
    //
    // Code under `:goal(speed)` (a `par` block's run function, a loop marked
    // so) may fuse a float multiply with the add or subtract that consumes it,
    // rounding once (FMA). Owner, 2026-10-26: x86-64 does it only there, so a
    // plain loop's answer never depends on the CPU running it. Every scalar
    // FAdd and FSub in a speed loop is marked `contract`; the back end fuses
    // those with a product for an operand where the code has FMA (x86-64's
    // avx2 and avx512 copies). A speed loop is the cycle through its header:
    // the blocks reachable from it that reach it again, inner loops included.
    // As the reference's fp-contract (XTIROptFpContract.m).
    final void fpContract(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.speedHeaders().count() == (u32)0)
                continue;
            Map* pred = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                Array* ss = self.successorsOf(bb);
                for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                    {
                    Object* ps = pred.get((Hashable*)ss.get(k));
                    if (ps == (Object*)0)
                        {
                        ps = (Object*)new Array();
                        pred.set((Hashable*)ss.get(k), ps);
                        }
                    ((Array*)ps).add((Object*)bb);
                    }
                }
            Map* speed = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* H = (IRBlock*)fn.blocks().get(b);
                if (H.name() == (String*)0 || !fn.isSpeedHeader(H.name()))
                    continue;
                Map* fwd = fpcReach(H, pred, true);
                Map* bwd = fpcReach(H, pred, false);
                for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
                    {
                    IRBlock* x = (IRBlock*)fn.blocks().get(k);
                    if (fwd.get((Hashable*)x) != (Object*)0 && bwd.get((Hashable*)x) != (Object*)0)
                        speed.set((Hashable*)x, (Object*)x);
                    }
                }
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (speed.get((Hashable*)bb) == (Object*)0)
                    continue;
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    bool vec = n.op().equals(String.withCString("VAdd")) || n.op().equals(String.withCString("VSub"));
                    if (!n.op().equals(String.withCString("FAdd")) && !n.op().equals(String.withCString("FSub")) && !vec)
                        continue;
                    if (n.res() == (IRValue*)0 || n.pred() != (String*)0)
                        continue;
                    // A vector add over float lanes too (the reference says why).
                    String* t = n.res().ty();
                    bool flt = vec ? (t.hasPrefix(String.withCString("Vec(F32")) || t.hasPrefix(String.withCString("Vec(F64")))
                                   : (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
                    if (!flt)
                        continue;
                    n.setPred(String.withCString("contract"));
                    }
                }
            }
        }

    // The blocks reachable from H (forward) or reaching it (backward), H's
    // own included when a path returns to it.
    final Map* fpcReach(IRBlock* H, Map* pred, bool forward)
        {
        Map* seen = new Map();
        Array* work = new Array();
        work.add((Object*)H);
        while (work.count() > (u32)0)
            {
            IRBlock* b = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            Array* next = forward ? self.successorsOf(b) : (Array*)pred.get((Hashable*)b);
            if (next == (Array*)0)
                continue;
            for (u32 k = (u32)0; k < next.count(); k = k + (u32)1)
                {
                IRBlock* x = (IRBlock*)next.get(k);
                if (seen.get((Hashable*)x) != (Object*)0)
                    continue;
                seen.set((Hashable*)x, (Object*)x);
                work.add((Object*)x);
                }
            }
        return seen;
        }
    }
