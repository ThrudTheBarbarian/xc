// OptLoopClone.xc — loop cloning for the vectoriser epilogue (xtvCloneLoop in src/xtc/ir/XTIROptVectorize.m).
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (LoopClone)
    {

    final IROperand* unrollSubstMap(Map* map, IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* n = map.get((Hashable*)o.val());
        if (n == (Object*)0)
            return o;
        return IROperand.useVal((IRValue*)n);
        }

    // Terminators, header phis, the splice, and the exit phis for accumulators
    // that are read after the loop.
    final void vtWire(IRFunc* fn, VTCand* c, u32 U)
        {
        IRBlock* H = c.h();
        IRBlock* B = c.b();
        IRBlock* E = c.e();
        IRBlock* last = (IRBlock*)_vtClones.get(_vtClones.count() - (u32)1);

        for (u32 j = (u32)0; j < _vtClones.count(); j = j + (u32)1)
            {
            IRBlock* C = (IRBlock*)_vtClones.get(j);
            if (j + (u32)1 < _vtClones.count() && _vtGuards.get(j) == (Object*)0)
                {
                IRInsn* br = IRInsn.with(String.withCString("Branch"));
                br.add(IROperand.block((IRBlock*)_vtClones.get(j + (u32)1)));
                C.setTerm(br);
                }
            else if (j + (u32)1 < _vtClones.count())
                {
                IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
                cb.add(IROperand.useVal((IRValue*)_vtGuards.get(j)));
                cb.add(IROperand.block((IRBlock*)_vtClones.get(j + (u32)1)));
                cb.add(IROperand.block(E));
                C.setTerm(cb);
                }
            else
                {
                IRInsn* br = IRInsn.with(String.withCString("Branch"));
                br.add(IROperand.block(H));
                C.setTerm(br);
                }
            }

        // The header phis' body incoming moves to the last copy.
        vtRetargetPhi(c.ivPhi(), B, last, _vtLastIvNext);
        for (u32 i = (u32)0; i < c.redPhis().count(); i = i + (u32)1)
            vtRetargetPhi((IRInsn*)c.redPhis().get(i), B, last,
                          (IRValue*)_vtLastRed.get(i));

        // …and the header's guard branch now enters the first copy.
        IRInsn* t = H.term();
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == B)
                t.ops().set(k, (Object*)IROperand.block((IRBlock*)_vtClones.get((u32)0)));
            }

        // Splice: drop the body, put the copies where it was.
        u32 pos = fn.blocks().count();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if ((IRBlock*)fn.blocks().get(b) == B)
                {
                pos = b;
                break;
                }
        Array* kept = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != B)
                kept.add((Object*)bb);
            }
        if (pos > kept.count())
            pos = kept.count();
        for (u32 j = (u32)0; j < _vtClones.count(); j = j + (u32)1)
            kept.insert(pos + j, _vtClones.get(j));
        fn.setBlocks(kept);

        vtRepairMem(fn, c, B);
        vtExitPhis(fn, c);
        }

    // Memory tokens defined in the body outlive it: the body is spliced out, so
    // a post-loop Load/Store/Return still naming one would reference a value
    // with no definition. Point them at the LAST copy's corresponding token —
    // sound because this IR's memory model is advisory (a token orders
    // operations, it does not name storage), the same reasoning the const-trip
    // unroller's escape remap rests on.
    final void vtRepairMem(IRFunc* fn, VTCand* c, IRBlock* B)
        {
        Map* memRemap = new Map();
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* x = (IRInsn*)B.insns().get(i);
            if (x.memRes() == (IRValue*)0)
                continue;
            Object* to = _vtLastMap.get((Hashable*)x.memRes());
            if (to == (Object*)0)
                continue;
            memRemap.set((Hashable*)x.memRes(), to);
            n = n + (u32)1;
            }
        if (n == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(_vtClones, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.phis().get(k), memRemap);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.insns().get(k), memRemap);
            if (bb.term() != (IRInsn*)0)
                self.pivReplaceIn(bb.term(), memRemap);
            }
        }

    final void vtRetargetPhi(IRInsn* phi, IRBlock* from, IRBlock* to, IRValue* v)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IROperand* bo = (IROperand*)phi.ops().get(k);
            if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != from)
                continue;
            phi.ops().set(k, (Object*)IROperand.block(to));
            phi.ops().set(k + (u32)1, (Object*)IROperand.useVal(v));
            }
        }

    // After unrolling, the exit is reached from the header (its guard false, so
    // no copy ran this group, carrying the header phi) and from each
    // intermediate copy (its guard false, so copies 0..j ran). The last copy
    // takes the back edge and never exits. The recogniser guaranteed the exit's
    // only predecessor beforehand was the header, so these cover every edge.
    final void vtExitPhis(IRFunc* fn, VTCand* c)
        {
        IRBlock* E = c.e();
        Array* exitPhis = new Array();
        Map* remap = new Map();
        for (u32 i = (u32)0; i < c.redPhis().count(); i = i + (u32)1)
            {
            if (((Number*)c.redEsc().get(i)).asI32() == (i32)0)
                continue;
            IRInsn* rp = (IRInsn*)c.redPhis().get(i);
            IRInsn* ep = IRInsn.with(String.withCString("Phi"));
            IRValue* ev = new IRValue(rp.res().ty());
            ep.setRes(ev);
            ep.add(IROperand.block(c.h()));
            ep.add(IROperand.useVal((IRValue*)c.redVals().get(i)));
            Array* after = (Array*)_vtAccAfter.get(i);
            for (u32 j = (u32)0; j + (u32)1 < _vtClones.count(); j = j + (u32)1)
                {
                ep.add(IROperand.block((IRBlock*)_vtClones.get(j)));
                ep.add(IROperand.useVal((IRValue*)after.get(j)));
                }
            E.phis().insert((u32)0, (Object*)ep);
            exitPhis.add((Object*)ep);
            remap.set((Hashable*)(IRValue*)c.redVals().get(i), (Object*)ev);
            }
        if (remap.count() == (u32)0)
            return;
        // Post-loop readers used the header phi, which is now stale mid-group.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == c.h() || self.hasBlock(_vtClones, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(k);
                if (hasInsn(exitPhis, n))
                    continue; // not the phi's own header arm
                self.pivReplaceIn(n, remap);
                }
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.pivReplaceIn((IRInsn*)bb.insns().get(k), remap);
            if (bb.term() != (IRInsn*)0)
                self.pivReplaceIn(bb.term(), remap);
            }
        }
    }
