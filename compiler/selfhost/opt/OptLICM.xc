// OptLICM.xc — the LICM pass, ported from src/xtc/ir/XTIROptLICM.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptReassociate>

    class Opt (LICM)
    {

    // ── licm ─────────────────────────────────────────────────────────────
    //
    // Loop-invariant code motion: an instruction inside a loop whose operands
    // are all defined outside it (or already hoisted) moves to the preheader.
    // Field LOADS come too, but only when nothing in the loop writes memory
    // and their block runs at every iteration.
    //
    // Termination is structural: each hoist moves instructions to the
    // preheader, which strictly dominates the header — strictly closer to the
    // entry in the dominator tree — so an instruction only ever moves toward
    // the root and can never re-enter a block it left. The 32-round cap is a
    // backstop, not the argument.
    final void licm(IRModule* m)
        {
        if (!_profile.licm())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // A round moves instructions into a preheader's body and never a
            // terminator, so the blocks and edges stand still: the dominators
            // and predecessors are found once for all the function's rounds.
            DomTree* dom = self.domTree(fn);
            Map* preds = self.lrcPredMap(fn);
            u32 pass = (u32)0;
            while (pass < (u32)32 && licmOnce(fn, dom, preds))
                pass = pass + (u32)1;
            if (pass == (u32)32)
                optRoundCap("LICM", (u32)32, fn);
            }
        }

    final bool licmOnce(IRFunc* fn, DomTree* dom, Map* preds)
        {
        _licmVecPhiIns = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* pb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < pb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)pb.phis().get(i);
                if (p.res() == (IRValue*)0 || p.res().ty() == (String*)0 || !p.res().ty().hasPrefix(String.withCString("Vec(")))
                    continue;
                for (u32 q = (u32)0; q < p.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)p.ops().get(q);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        _licmVecPhiIns.add((Object*)o.val());
                    }
                }
            }
        if (fn.blocks().count() == (u32)0)
            return false;
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    {
                    defOf.set((Hashable*)n.res(), (Object*)n);
                    defBlk.set((Hashable*)n.res(), (Object*)bb);
                    }
                if (n.memRes() != (IRValue*)0)
                    defBlk.set((Hashable*)n.memRes(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            }

        for (u32 li = (u32)0; li < fn.blocks().count(); li = li + (u32)1)
            {
            IRBlock* latch = (IRBlock*)fn.blocks().get(li);
            Array* ss = self.lrcSuccs(fn, latch);
            for (u32 s = (u32)0; s < ss.count(); s = s + (u32)1)
                {
                IRBlock* H = (IRBlock*)ss.get(s);
                // A real back edge only: the header must DOMINATE the latch.
                // Without that test a forward edge into an earlier block —
                // which inlining and unrolling can produce — masquerades as one,
                // and the body walk either escapes into an outer preheader or
                // stops short of a real body block.
                if (!dom.dominates(H, latch))
                    continue;
                if (licmLoop(fn, H, latch, dom, preds, defOf, defBlk))
                    return true;
                }
            }
        return false;
        }

    final bool licmLoop(IRFunc* fn, IRBlock* H, IRBlock* latch,
                  DomTree* dom, Map* preds, Map* defOf, Map* defBlk)
        {
        // Natural loop body: every block reaching the latch without passing
        // through the header, plus the header itself.
        // The predecessors are the function's, found once (licm says why)
        // and the body is a set as well as a list.
        Array* body = new Array();
        Map* inBody = new Map();
        body.add((Object*)H);
        inBody.set((Hashable*)H, (Object*)H);
        Array* wl = new Array();
        wl.add((Object*)latch);
        while (wl.count() > (u32)0)
            {
            IRBlock* n = (IRBlock*)wl.get(wl.count() - (u32)1);
            wl.removeLast();
            if (inBody.get((Hashable*)n) != (Object*)0)
                continue;
            body.add((Object*)n);
            inBody.set((Hashable*)n, (Object*)n);
            if (n == H)
                continue;
            Array* ps = self.lrcPredsIn(preds, n);
            for (u32 p = (u32)0; p < ps.count(); p = p + (u32)1)
                wl.add(ps.get(p));
            }

        // A unique preheader — the header's one predecessor outside the loop —
        // which, being the sole entry to a natural loop, dominates the header.
        Array* hp = self.lrcPredsIn(preds, H);
        IRBlock* pre = (IRBlock*)0;
        u32 outside = (u32)0;
        for (u32 p = (u32)0; p < hp.count(); p = p + (u32)1)
            {
            IRBlock* pb = (IRBlock*)hp.get(p);
            if (inBody.get((Hashable*)pb) != (Object*)0)
                continue;
            outside = outside + (u32)1;
            pre = pb;
            }
        if (outside != (u32)1)
            return false;
        if (!dom.dominates(pre, H))
            return false;

        bool hasMemWrite = false;
        // A large loop keeps its vector splats where they are used: hoisted,
        // each is a vector register held across a body that needs them for
        // its own values (MD5's rounds; the vectoriser holds none there).
        u32 bodySize = (u32)0;
        for (u32 i = (u32)0; i < body.count(); i = i + (u32)1)
            bodySize = bodySize + ((IRBlock*)body.get(i)).insns().count();
        bool keepSplats = bodySize > (u32)VEC_SPLAT_BIG_BODY;
        for (u32 i = (u32)0; i < body.count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)body.get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                if (licmWritesMemory(((IRInsn*)bb.insns().get(k)).opc()))
                    {
                    hasMemWrite = true;
                    break;
                    }
            if (hasMemWrite)
                break;
            }
        // A loop that calls keeps its vectors: hoisted, one is live across the
        // call, and every vector register is the caller's to save, which no
        // back end does. The lane-index load of an inner loop, hoisted out of
        // an outer one that called a function, came back from the call as
        // whatever the callee left in ymm15 (an AVX2 clone's reduction).
        bool hasCall = false;
        for (u32 i = (u32)0; i < body.count() && !hasCall; i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)body.get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                if (licmIsCall(((IRInsn*)bb.insns().get(k)).opc()))
                    {
                    hasCall = true;
                    break;
                    }
            }

        // Grow the hoist set to a fixpoint: an instruction joins once all its
        // operands are invariant, which can make the next one invariant too.
        // Blocks are visited in function order, so the result does not depend
        // on any set's iteration order.
        Array* hoist = new Array();
        Map* invariant = new Map();
        Map* inHoist = new Map();
        bool progress = true;
        while (progress)
            {
            progress = false;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (inBody.get((Hashable*)bb) == (Object*)0)
                    continue;
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(k);
                    if (inHoist.get((Hashable*)n) != (Object*)0)
                        continue;
                    if (!licmHoistable(n, hasMemWrite, defOf))
                        continue;
                    // A load runs in the preheader only if its block runs at
                    // every iteration (dominates the latch): one under an `if`
                    // may be the guard's whole point (`if (p != null) s +=
                    // p.x`), and hoisted it loads through null. As the reference.
                    if (n.isOp(opLoad) && !dom.dominates(bb, latch))
                        continue;
                    if (keepSplats && n.isOp(opVSplat))
                        continue;
                    if (hasCall && n.res() != (IRValue*)0 && n.res().ty() != (String*)0
                        && n.res().ty().hasPrefix(String.withCString("Vec(")))
                        continue;
                    bool inv = true;
                    for (u32 o = (u32)0; o < n.ops().count(); o = o + (u32)1)
                        if (!licmOpInvariant((IROperand*)n.ops().get(o), inBody,
                                             defBlk, invariant))
                            {
                            inv = false;
                            break;
                            }
                    if (!inv)
                        continue;
                    inHoist.set((Hashable*)n, (Object*)n);
                    hoist.add((Object*)n);
                    if (n.res() != (IRValue*)0)
                        invariant.set((Hashable*)n.res(), (Object*)n.res());
                    if (n.memRes() != (IRValue*)0)
                        invariant.set((Hashable*)n.memRes(), (Object*)n.memRes());
                    progress = true;
                    }
                }
            }
        if (hoist.count() == (u32)0)
            return false;

        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)hoist.get(i);
            IRValue* key = n.res() != (IRValue*)0 ? n.res() : n.memRes();
            Object* bo = defBlk.get((Hashable*)key);
            if (bo != (Object*)0)
                self.removeInsn((IRBlock*)bo, n);
            }
        // In dependency order, before the preheader's terminator (which the
        // block holds separately, so appending is enough).
        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            pre.insns().add(hoist.get(i));
        return true;
        }

    // Is this operand invariant for the loop? Anything not a use is; so is a
    // memory token (advisory in this loose model) and anything defined outside
    // the body or already marked to hoist.
    final bool licmOpInvariant(IROperand* o, Map* inBody, Map* defBlk, Map* invariant)
        {
        if (o.kind() != (u8)OPK_USE)
            return true;
        if (o.val().ty() != (String*)0 && o.val().ty().equals(String.withCString("Mem")))
            return true;
        Object* db = defBlk.get((Hashable*)o.val());
        if (db == (Object*)0 || inBody.get((Hashable*)db) == (Object*)0)
            return true;
        return invariant.get((Hashable*)o.val()) != (Object*)0;
        }

    final bool licmHoistable(IRInsn* n, bool hasMemWrite, Map* defOf)
        {
        // A vector feeding a phi is an accumulator's seed and must be made on
        // every entry (the reference explains).
        if (n.res() != (IRValue*)0 && n.res().ty() != (String*)0 && n.res().ty().hasPrefix(String.withCString("Vec("))
            && _licmVecPhiIns != (Array*)0 && Opt.bmHas2(_licmVecPhiIns, n.res()))
            return false;
        if (n.isOp(opLoad))
            {
            if (hasMemWrite || n.ops().count() < (u32)1)
                return false;
            IROperand* a = (IROperand*)n.ops().get((u32)0);
            if (a.kind() != (u8)OPK_USE)
                return false;
            Object* pd = defOf.get((Hashable*)a.val());
            if (pd == (Object*)0)
                return false;
            // A field load, or an ELEMENT load whose address is invariant (the
            // address is an operand, checked by the caller). nbody's inner loop
            // reads px[i] with i the OUTER loop's iv; that load is invariant
            // here and was never hoisted, which kept a non-iv load in the body
            // and stopped the reduction recogniser vectorising it.
            u16 pdo = ((IRInsn*)pd).opc();
            return pdo == opFieldAddr || pdo == opElementAddr;
            }
        return licmPure(n);
        }

    // Pure and speculation-safe: no memory result, no side effect, no trap.
    // Const is excluded because it rematerialises cheaply and belongs to the
    // constant passes; the divides are excluded because they may trap.
    final bool licmPure(IRInsn* n)
        {
        if (n.memRes() != (IRValue*)0)
            return false;
        u16 oc = n.opc();
        if (oc == opConst || oc == opPhi || oc == opSDiv || oc == opUDiv || oc == opSRem || oc == opURem)
            return false;
        return !licmIsTerminator(oc);
        }

    // Not Invoke or Resume.
    final bool licmIsTerminator(u16 oc)
        {
        return IROp.has(oc, OPF_TERM) && oc != opInvoke && oc != opResume;
        }

    // Not the indirect calls.
    final bool licmIsCall(u16 oc)
        {
        return IROp.has(oc, OPF_CALL_DIRECT | OPF_DISPATCH);
        }

    final bool licmWritesMemory(u16 oc)
        {
        return self.lrcWritesMemory(oc) || oc == opLoadVolatile;
        }
    }
