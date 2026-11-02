// OptLoopUnroll.xc — the LoopUnroll pass, ported from src/xtc/ir/XTIROptLoopUnroll.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptLoopReductionCollapse>
#import <OptRedundantLoadCSE>

    class Opt (LoopUnroll)
    {

    // ── loop-unroll ──────────────────────────────────────────────────────
    //
    // A counted loop with a constant trip and a single straight-line body
    // becomes `trip` copies of that body, the induction variable becoming a
    // Const per copy and each accumulator threaded copy-to-copy. The header,
    // the compare and the back edge all go away.
    //
    // The caps come from the target profile — the 6502 keeps the shipped
    // conservative set because a large unroll cannot fit its 16 KB code bank,
    // while the 32-bit targets relax them.
    final void loopUnroll(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            unrollInFunc((IRFunc*)m.funcs().get(f));
            if (_failed)
                return;
            }
        }

    final void unrollInFunc(IRFunc* fn)
        {
        // Unroll one loop at a time, re-recognising after each: the apply
        // rewrites uses across sibling and outer loops, so a captured operand
        // from a stale scan would name a value that is no longer there. Each
        // unroll removes a loop, so the set shrinks; the cap is a backstop.
        for (u32 iter = (u32)0; iter < (u32)4096; iter = iter + (u32)1)
            {
            Array* cands = unrollCandidates(fn);
            if (_failed)
                return;
            if (cands.count() == (u32)0)
                return;

            u32 fnInsns = (u32)0;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                fnInsns = fnInsns + bb.phis().count() + bb.insns().count();
                if (bb.term() != (IRInsn*)0)
                    fnInsns = fnInsns + (u32)1;
                }
            LUCand* chosen = (LUCand*)0;
            for (u32 i = (u32)0; i < cands.count(); i = i + (u32)1)
                {
                LUCand* c = (LUCand*)cands.get(i);
                u32 added = (c.trip() - (u32)1) * (c.b().insns().count() + (u32)1);
                if (fnInsns + added > _profile.unrollBudget())
                    continue;
                // A call body grows the value count — each copy allocates fresh
                // result and memory-result slots — and on arm64 that sizes the
                // stack frame, so every slot has to stay addressable
                // (str/ldr w,[sp,#<=16380]). Counted over the values the
                // function HOLDS: the original used to count every id ever
                // allocated, which made the decision depend on how many ids
                // earlier passes happened to burn.
                if (_profile.unrollFrameIds() > (u32)0 && unrollBodyHasCall(c.b()))
                    {
                    u32 addedIds = c.trip() * ((u32)2 * c.b().insns().count() + (u32)1) + (u32)1;
                    if (unrollLiveIds(fn) + addedIds > _profile.unrollFrameIds())
                        continue;
                    }
                chosen = c;
                break;
                }
            // A loop that would bust the budget is left alone, and so is
            // everything after it — the original stops scanning here too.
            if (chosen == (LUCand*)0)
                return;
            unrollApply(fn, chosen);
            }
        }

    final bool unrollBodyHasCall(IRBlock* B)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            if (unrollIsCall(((IRInsn*)B.insns().get(i)).op()))
                return true;
        return false;
        }

    // How many values the function holds: parameters, pinned locals, and every
    // instruction result and memory result.
    final u32 unrollLiveIds(IRFunc* fn)
        {
        u32 n = fn.params().count() + fn.pinned().count();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            n = n + unrollCountDefs(bb.phis()) + unrollCountDefs(bb.insns());
            if (bb.term() != (IRInsn*)0)
                {
                if (bb.term().res() != (IRValue*)0)
                    n = n + (u32)1;
                if (bb.term().memRes() != (IRValue*)0)
                    n = n + (u32)1;
                }
            }
        return n;
        }

    final u32 unrollCountDefs(Array* list)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* x = (IRInsn*)list.get(i);
            if (x.res() != (IRValue*)0)
                n = n + (u32)1;
            if (x.memRes() != (IRValue*)0)
                n = n + (u32)1;
            }
        return n;
        }

    final Array* unrollCandidates(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    defOf.set((Hashable*)p.res(), (Object*)p);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }

        Array* cands = new Array();
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            LUCand* c = unrollRecognise(fn, (IRBlock*)fn.blocks().get(hi), defOf);
            if (_failed)
                return cands;
            if (c != (LUCand*)0)
                cands.add((Object*)c);
            }
        return cands;
        }

    // One header block, or null.
    final LUCand* unrollRecognise(IRFunc* fn, IRBlock* H, Map* defOf)
        {
        IRInsn* icmp = unrollHeaderCmp(H);
        if (icmp == (IRInsn*)0)
            return (LUCand*)0;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return (LUCand*)0;
        IROperand* cond = (IROperand*)term.ops().get((u32)0);
        IROperand* o1 = (IROperand*)term.ops().get((u32)1);
        IROperand* o2 = (IROperand*)term.ops().get((u32)2);
        if (cond.kind() != (u8)OPK_USE || cond.val() != icmp.res())
            return (LUCand*)0;
        if (o1.kind() != (u8)OPK_BLOCK || o2.kind() != (u8)OPK_BLOCK)
            return (LUCand*)0;

        // The body/latch is whichever target branches unconditionally back to
        // the header; the other is the exit.
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (unrollIsLatch(o1.blk(), H))
            {
            B = o1.blk();
            E = o2.blk();
            }
        else if (unrollIsLatch(o2.blk(), H))
            {
            B = o2.blk();
            E = o1.blk();
            }
        if (B == (IRBlock*)0 || E == (IRBlock*)0 || B == H || E == H || B == E)
            return (LUCand*)0;

        if (!unrollBodyShape(fn, H, B, E))
            return (LUCand*)0;
        if (!unrollIvAndCarried(fn, H, B, icmp, defOf))
            return (LUCand*)0;

        LUCand* c = new LUCand();
        c.setBlocks(H, B, E, _luPre);
        c.setIv(_luIvPhi, _luIvPhi.res().ty(), _luInit, _luStep, _luTrip);
        c.setCarried(_luCarried);
        return c;
        }

    // The header's single ICmp, or null if the header is not the clean
    // const/widen + one-compare shape (or carries a vector accumulator).
    final IRInsn* unrollHeaderCmp(IRBlock* H)
        {
        if (H.phis().count() < (u32)1)
            return (IRInsn*)0;
        if (H.phis().count() > (u32)1 && !_profile.unrollMultiCarried())
            return (IRInsn*)0;
        // An already-vectorised reduction loop carries a VECTOR accumulator
        // phi; cloning it would defeat the backend's in-place accumulate
        // coalescing, so those are left alone.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && self.isVectorType(p.res().ty()))
                return (IRInsn*)0;
            }
        IRInsn* icmp = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n.op().equals(String.withCString("ICmp")))
                {
                if (icmp != (IRInsn*)0)
                    return (IRInsn*)0;
                icmp = n;
                continue;
                }
            if (!n.op().equals(String.withCString("Const")) && !n.op().equals(String.withCString("ZExt")) && !n.op().equals(String.withCString("SExt")) && !n.op().equals(String.withCString("Trunc")))
                return (IRInsn*)0;
            }
        if (icmp == (IRInsn*)0 || icmp.res() == (IRValue*)0)
            return (IRInsn*)0;
        return icmp;
        }

    // The body must be one straight-line block whose only predecessor is the
    // header, small enough for the target's cap, free of ops that cannot be
    // replicated, and the exit must have no phi to rewire.
    // `for (...) : unroll` raises the BUDGETS for the loops that asked, and
    // nothing else. The profile's maxTrip/maxBody are a judgement about when
    // unrolling PAYS — and that judgement is exactly what the annotation
    // overrides, because the author knows something the heuristic does not.
    //
    // Every other gate stays: multiple carried phis, vector phis, the
    // single-predecessor body shape, forbidden opcodes. Those are CORRECTNESS
    // limits, not budget ones — a loop the unroller cannot transform safely is
    // not made safe by being asked twice.
    final bool unrollForced(IRFunc* fn, IRBlock* H)
        {
        if (fn == (IRFunc*)0 || H == (IRBlock*)0)
            return false;
        Array* hs = fn.unrollHeaders();
        for (u32 i = (u32)0; i < hs.count(); i = i + (u32)1)
            if (((String*)hs.get(i)).equals(H.name()))
                return true;
        return false;
        }

    final u32 unrollTripCap(IRFunc* fn, IRBlock* H)
        {
        u32 d = _profile.unrollMaxTrip();
        if (!unrollForced(fn, H))
            return d;
        return d > (u32)64 ? d : (u32)64;
        }

    final u32 unrollBodyCap(IRFunc* fn, IRBlock* H)
        {
        u32 d = _profile.unrollMaxBody();
        if (!unrollForced(fn, H))
            return d;
        return d > (u32)64 ? d : (u32)64;
        }

    final bool unrollBodyShape(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* E)
        {
        Array* bp = unrollPreds(fn, B);
        if (bp.count() != (u32)1 || (IRBlock*)bp.get((u32)0) != H)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;
        if (B.insns().count() == (u32)0 || B.insns().count() > unrollBodyCap(fn, H))
            return false;
        bool hasCall = false;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (unrollIsCall(n.op()))
                hasCall = true;
            if (unrollForbidden(n.op()))
                return false;
            }
        // A call body is fine — the apply threads its memory token through a
        // transient header phi. `hasCall` is still wanted by the caller.
        _luBodyHasCall = hasCall;
        return true;
        }

    // The induction phi, its closed-form start/step/trip, and the accumulators
    // carried alongside it. Results land in the _lu* ivars.
    final bool unrollIvAndCarried(IRFunc* fn, IRBlock* H, IRBlock* B,
                            IRInsn* icmp, Map* defOf)
        {
        _luIvPhi = (IRInsn*)0;
        _luPre = (IRBlock*)0;
        _luInit = (i64)0;
        _luStep = (i32)0;
        _luTrip = (u32)0;
        _luCarried = new Array();

        // The induction phi is the one whose result the compare tests.
        if (icmp.ops().count() < (u32)2)
            return false;
        IROperand* cmpL = (IROperand*)icmp.ops().get((u32)0);
        if (cmpL.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = cmpL.val();
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
        if (ivPhi == (IRInsn*)0 || ivPhi.memRes() != (IRValue*)0)
            return false;

        // iv incomings: a const init from the preheader, and `Add iv, c` back.
        Array* sp = unrollSplitPhi(ivPhi, B);
        if (sp == (Array*)0)
            return false;
        IRBlock* P = (IRBlock*)sp.get((u32)0);
        IROperand* seedOp = (IROperand*)sp.get((u32)1);
        IROperand* nextOp = (IROperand*)sp.get((u32)2);
        if (P.term() == (IRInsn*)0)
            return false;
        i64 initV = (i64)0;
        if (!unrollConst(defOf, seedOp, &initV))
            return false;
        if (nextOp.kind() != (u8)OPK_USE)
            return false;
        Object* ndo = defOf.get((Hashable*)nextOp.val());
        if (ndo == (Object*)0)
            return false;
        IRInsn* nextDef = (IRInsn*)ndo;
        if (!nextDef.op().equals(String.withCString("Add")) || nextDef.ops().count() < (u32)2)
            return false;
        IROperand* na = (IROperand*)nextDef.ops().get((u32)0);
        IROperand* nb = (IROperand*)nextDef.ops().get((u32)1);
        i64 stepV = (i64)0;
        if (na.kind() == (u8)OPK_USE && na.val() == iv && unrollConst(defOf, nb, &stepV))
            {
            }
        else if (nb.kind() == (u8)OPK_USE && nb.val() == iv && unrollConst(defOf, na, &stepV))
            {
            }
        else
            return false;
        i64 boundV = (i64)0;
        if (!unrollConst(defOf, (IROperand*)icmp.ops().get((u32)1), &boundV))
            return false;
        if (icmp.pred() == (String*)0)
            return false;
        u32 trip = unrollTrip(initV, stepV, boundV, icmp.pred(),
                              unrollTripCap(fn, H));
        if (trip < (u32)2)
            return false; // trip 0/1 is not worth the machinery

        // The unrolled body is one block and everything in it is live there.
        // Past a point that costs more in spills than the removed branches
        // save — see the note on unrollMaxTotal.
        u32 totalCap = _profile.unrollMaxTotal();
        if (!unrollForced(fn, H) && totalCap > (u32)0
            && trip * B.insns().count() > totalCap)
            return false;

        // Every other header phi is an accumulator carried across iterations,
        // and each must have the same (preheader init, body next) shape with
        // both values SSA uses — the per-copy threading is value-to-value.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p == ivPhi)
                continue;
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0)
                return false;
            Array* csp = unrollSplitPhi(p, B);
            if (csp == (Array*)0 || (IRBlock*)csp.get((u32)0) != P)
                return false;
            IROperand* ci = (IROperand*)csp.get((u32)1);
            IROperand* cn = (IROperand*)csp.get((u32)2);
            if (ci.kind() != (u8)OPK_USE || cn.kind() != (u8)OPK_USE)
                return false;
            LUCarried* cr = new LUCarried();
            cr.set(p.res(), ci, cn);
            _luCarried.add((Object*)cr);
            }

        // The iv must not be read outside the header/body: running the copies
        // never materialises its final value. Accumulators MAY escape — their
        // uses are remapped to the final copy in the apply.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            if (unrollUsesValue(bb, iv))
                return false;
            }

        _luIvPhi = ivPhi;
        _luPre = P;
        _luInit = initV;
        _luStep = stepV;
        _luTrip = trip;
        return true;
        }

    final bool unrollIsLatch(IRBlock* b, IRBlock* H)
        {
        if (b == (IRBlock*)0 || b.term() == (IRInsn*)0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        Array* ss = unrollSuccs(b);
        return ss.count() == (u32)1 && (IRBlock*)ss.get((u32)0) == H;
        }

    final Array* unrollSuccs(IRBlock* b)
        {
        Array* out = new Array();
        if (b.term() == (IRInsn*)0)
            return out;
        for (u32 i = (u32)0; i < b.term().ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)b.term().ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0)
                out.add((Object*)o.blk());
            }
        return out;
        }

    // Predecessors, DEDUPED — the original builds these as a set, so a block
    // that names its target twice counts once. (loop-reduction-collapse wants
    // the opposite; see lrcPreds.)
    final Array* unrollPreds(IRFunc* fn, IRBlock* target)
        {
        Array* out = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)fn.blocks().get(b);
            Array* ss = unrollSuccs(src);
            for (u32 i = (u32)0; i < ss.count(); i = i + (u32)1)
                if ((IRBlock*)ss.get(i) == target)
                    {
                    if (!self.hasBlock(out, src))
                        out.add((Object*)src);
                    break;
                    }
            }
        return out;
        }

    final bool unrollIsCall(String* op)
        {
        return self.isCallOp(op) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch"));
        }

    // A body op that makes unrolling unsafe. Plain scalar Load/Store are always
    // fine — the backend emits them in program order. Calls are allowed only
    // where the target opts in, since each copy re-issues the call, which is
    // exactly the trip executions. Everything else that touches memory stays
    // forbidden: replicating a Retain/Release is unsound, and replicating a
    // MemCopy or an Asm is pointless.
    final bool unrollForbidden(String* op)
        {
        if (op.equals(String.withCString("Load")) || op.equals(String.withCString("Store")))
            return false;
        if (unrollIsCall(op))
            return !_profile.unrollCallsInBody();
        return self.touchesMemory(op);
        }

    // Split a 2-incoming header phi into (preheader, init, next) given the body
    // block. Null unless it has exactly that shape.
    final Array* unrollSplitPhi(IRInsn* phi, IRBlock* B)
        {
        if (phi.ops().count() != (u32)4)
            return (Array*)0;
        IRBlock* b0 = ((IROperand*)phi.ops().get((u32)0)).blk();
        IRBlock* b1 = ((IROperand*)phi.ops().get((u32)2)).blk();
        Object* v0 = phi.ops().get((u32)1);
        Object* v1 = phi.ops().get((u32)3);
        Array* out = new Array();
        if (b1 == B && b0 != B)
            {
            out.add((Object*)b0);
            out.add(v0);
            out.add(v1);
            return out;
            }
        if (b0 == B && b1 != B)
            {
            out.add((Object*)b1);
            out.add(v1);
            out.add(v0);
            return out;
            }
        return (Array*)0;
        }

    // A compile-time int, seen through the widened-literal form. Unlike the
    // collapse's, this one does NOT follow Bitcast — the original's two
    // resolvers differ there and the difference is load-bearing.
  // i64: IROperand.imm() is already 64-bit, and the reference holds every
  // one of these in an int64_t. Narrowing here made a u32 loop bound above
  // 2^31 come back NEGATIVE, and every guard that tests it silently gave
  // up. private:docs/bugs/243.
    final bool unrollConst(Map* defOf, IROperand* op, i64* out)
        {
        if (op == (IROperand*)0)
            return false;
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
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
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

    // Simulate to a trip count, capped. Zero unless it is a terminating
    // ascending counted loop within the cap — unlike the collapse's closed
    // form, the unroller only wants trips it can afford to replicate.
    final u32 unrollTrip(i64 startv, i64 step, i64 bound, String* pred, u32 maxTrip)
        {
        if (step <= (i32)0)
            return (u32)0; // ascending counters only
        i32 i = startv;
        u32 trip = (u32)0;
        for (u32 n = (u32)0; n <= maxTrip; n = n + (u32)1)
            {
            bool cont = false;
            if (pred.equals(String.withCString("ULT")))
                cont = (u32)i < (u32)bound;
            else if (pred.equals(String.withCString("SLT")))
                cont = i < bound;
            else if (pred.equals(String.withCString("ULE")))
                cont = (u32)i <= (u32)bound;
            else if (pred.equals(String.withCString("SLE")))
                cont = i <= bound;
            else
                return (u32)0; // unsupported predicate
            if (!cont)
                break;
            trip = trip + (u32)1;
            i = i + step;
            }
        if (trip == (u32)0 || trip > maxTrip)
            return (u32)0;
        return trip;
        }

    // Replace the loop with `trip` copies of its body: the induction variable
    // becomes a Const per copy, each accumulator is threaded copy-to-copy, and
    // the header and body blocks are spliced out.
    final void unrollApply(IRFunc* fn, LUCand* c)
        {
        IRBlock* H = c.h();
        IRBlock* B = c.b();
        IRBlock* E = c.e();
        IRBlock* P = c.p();
        IRValue* iv = c.phi().res();

        // A body with a CALL threads its memory through an opaque callee, so a
        // transient header memory phi is synthesised and registered as a carried
        // value — that is what makes the copies thread the token one to the
        // next. It is spliced out with the loop, so it never reaches the
        // verifier, the CSE or a backend. Plain load/store bodies need none of
        // this and keep the original no-phi path.
        unrollThreadMemory(fn, c, H, B, P);

        // Values defined in the body — what the post-loop escape remap
        // redirects to the final copy.
        Array* bodyDefs = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.res() != (IRValue*)0)
                bodyDefs.add((Object*)n.res());
            if (n.memRes() != (IRValue*)0)
                bodyDefs.add((Object*)n.memRes());
            }

        // Each accumulator's incoming value for the copy about to be built;
        // copy 0 gets its seed.
        Map* carriedCur = new Map();
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            carriedCur.set((Hashable*)cr.phi(), (Object*)cr.seed().val());
            }

        Array* clones = new Array();
        Map* lastMap = new Map();
        for (u32 j = (u32)0; j < c.trip(); j = j + (u32)1)
            {
            Map* map = new Map();
            IRBlock* C = unrollCopy(fn, c, B, j, map, carriedCur);
            clones.add((Object*)C);
            lastMap = map;
            }

        // Wire the copies: c_j → c_{j+1}, and the last one to the exit.
        for (u32 j = (u32)0; j < clones.count(); j = j + (u32)1)
            {
            IRBlock* target = (j + (u32)1 < clones.count())
                                  ? (IRBlock*)clones.get(j + (u32)1)
                                  : E;
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(target));
            ((IRBlock*)clones.get(j)).setTerm(br);
            }

        // The preheader now enters the first copy.
        self.lrcRetarget(P, H, (IRBlock*)clones.get((u32)0));

        // Escape remap for everything outside the loop: a body-defined value
        // becomes the final copy's, and an accumulator phi becomes its final
        // carried value.
        Array* escapeDefs = new Array();
        for (u32 i = (u32)0; i < bodyDefs.count(); i = i + (u32)1)
            escapeDefs.add(bodyDefs.get(i));
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            lastMap.set((Hashable*)cr.phi(), carriedCur.get((Hashable*)cr.phi()));
            escapeDefs.add((Object*)cr.phi());
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            unrollRemapUses(bb, escapeDefs, lastMap);
            }

        // Splice: drop the header and the body, put the copies where the
        // header was so the block order still matches the control flow (the
        // register allocators read live-interval positions from it).
        // The original takes H's index in the OLD array, removes H and B, then
        // inserts at that same index clamped to the shortened array — NOT at
        // "however many survivors preceded H". The two differ whenever B sits
        // before H, so this follows the original's arithmetic literally.
        u32 pos = fn.blocks().count();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if ((IRBlock*)fn.blocks().get(b) == H)
                {
                pos = b;
                break;
                }
        Array* kept = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            kept.add((Object*)bb);
            }
        if (pos > kept.count())
            pos = kept.count();
        for (u32 j = (u32)0; j < clones.count(); j = j + (u32)1)
            kept.insert(pos + j, clones.get(j));
        fn.setBlocks(kept);
        }

    final void unrollThreadMemory(IRFunc* fn, LUCand* c, IRBlock* H, IRBlock* B, IRBlock* P)
        {
        bool hasCall = false;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            if (unrollIsCall(((IRInsn*)B.insns().get(i)).op()))
                {
                hasCall = true;
                break;
                }
        if (!hasCall)
            return;

        // The first instruction that takes the memory token, whatever its
        // opcode (a VaArg is not one that touches memory). As the reference
        // (bug 623).
        IRInsn* firstMem = (IRInsn*)0;
        for (u32 i = (u32)0; i < B.insns().count() && firstMem == (IRInsn*)0; i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && o.val().ty() != (String*)0 &&
                    o.val().ty().equals(String.withCString("Mem")))
                    {
                    firstMem = n;
                    break;
                    }
                }
            }
        if (firstMem == (IRInsn*)0)
            return;
        IRValue* tin = (IRValue*)0;
        for (u32 k = (u32)0; k < firstMem.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)firstMem.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            if (o.val().ty() != (String*)0 && o.val().ty().equals(String.withCString("Mem")))
                {
                tin = o.val();
                break;
                }
            }
        IRValue* tlast = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                tlast = n.memRes();
            }
        if (tin == (IRValue*)0 || tlast == (IRValue*)0)
            return;

        IRValue* memPhi = new IRValue(String.withCString("Mem"));
        IRInsn* ph = IRInsn.with(String.withCString("Phi"));
        ph.setRes(memPhi);
        // The incoming order follows BLOCK ORDER, as the original's does.
        if (blockIndex(fn, P) <= self.blockIndex(fn, B))
            {
            ph.add(IROperand.block(P));
            ph.add(IROperand.useVal(tin));
            ph.add(IROperand.block(B));
            ph.add(IROperand.useVal(tlast));
            }
        else
            {
            ph.add(IROperand.block(B));
            ph.add(IROperand.useVal(tlast));
            ph.add(IROperand.block(P));
            ph.add(IROperand.useVal(tin));
            }
        H.addPhi(ph);

        // The first memory op now reads the phi instead of the incoming token.
        for (u32 k = (u32)0; k < firstMem.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)firstMem.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == tin)
                firstMem.ops().set(k, (Object*)IROperand.useVal(memPhi));
            }

        LUCarried* cr = new LUCarried();
        cr.set(memPhi, IROperand.useVal(tin), IROperand.useVal(tlast));
        c.carried().add((Object*)cr);
        }

    // One copy of the body. `map` collects this copy's old→new values, and
    // `carriedCur` advances to what this copy produced.
    final IRBlock* unrollCopy(IRFunc* fn, LUCand* c, IRBlock* B, u32 j,
                        Map* map, Map* carriedCur)
        {
        String* base = B.name() == (String*)0
                           ? String.withCString("body")
                           : B.name();
        String* nm = new String();
        nm.appendFormat("%s_u%lu", base.cString(), j);
        IRBlock* C = new IRBlock(nm);

        // The induction variable is a fresh Const of its value for this copy.
        // 64-bit, as the reference: a u32 iv at 2^31 or more (the vectoriser's
        // remainder loop from 2,199,999,992) printed as a negative constant.
        i64 ivVal = c.start() + (i64)j * (i64)c.step();
        IRInsn* ivConst = IRInsn.with(String.withCString("Const"));
        ivConst.setRes(new IRValue(c.ivTy()));
        ivConst.add(IROperand.immI(ivVal, c.ivTy()));
        C.add(ivConst);
        map.set((Hashable*)c.phi().res(), (Object*)ivConst.res());

        // Each accumulator phi resolves to its incoming value for this copy.
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            map.set((Hashable*)cr.phi(), carriedCur.get((Hashable*)cr.phi()));
            }

        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            IRInsn* cl = IRInsn.with(n.op());
            cl.copyDbg(n);
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                cl.add(unrollSubst(map, (IROperand*)n.ops().get(k)));
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                map.set((Hashable*)n.res(), (Object*)cl.res());
                }
            if (n.memRes() != (IRValue*)0)
                {
                cl.setMemRes(new IRValue(String.withCString("Mem")));
                map.set((Hashable*)n.memRes(), (Object*)cl.memRes());
                }
            C.add(cl);
            }

        // Advance each accumulator to what this copy produced.
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            Object* nn = map.get((Hashable*)cr.next().val());
            if (nn == (Object*)0)
                nn = (Object*)cr.next().val();
            carriedCur.set((Hashable*)cr.phi(), nn);
            }
        return C;
        }

    final IROperand* unrollSubst(Map* map, IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* n = map.get((Hashable*)o.val());
        if (n == (Object*)0)
            return o;
        return IROperand.useVal((IRValue*)n);
        }

    final void unrollRemapUses(IRBlock* bb, Array* defs, Map* map)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            unrollRemapInsn((IRInsn*)bb.phis().get(k), defs, map);
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            unrollRemapInsn((IRInsn*)bb.insns().get(k), defs, map);
        if (bb.term() != (IRInsn*)0)
            unrollRemapInsn(bb.term(), defs, map);
        }

    final void unrollRemapInsn(IRInsn* n, Array* defs, Map* map)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            if (!self.hasValue(defs, o.val()))
                continue;
            Object* to = map.get((Hashable*)o.val());
            if (to == (Object*)0)
                continue;
            n.ops().set(i, (Object*)IROperand.useVal((IRValue*)to));
            }
        }
    }
