// OptDevirt.xc — the Devirtualise pass (guarded devirtualisation), as the
// reference's XTIROptDevirtualise.m. One of the files class Opt is split into,
// so the split build compiles the optimiser side by side; Opt.xc says how the
// files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (Devirt)
    {

    // ── devirtualise ─────────────────────────────────────────────────────
    //
    // A virtual call in a loop whose method has few implementations in the
    // program becomes a test of the receiver's class against each class that
    // has one, a direct call to that class's method where it matches (which
    // the inliner then inlines), and the virtual call itself where none does.
    // The test is the object's word 0 — its class's vtable — against the
    // address of each candidate vtable, so it is right for any object: a match
    // means that class, and its slot is the method the dispatch would have
    // called. A class the program does not know (a plugin's) takes the
    // dispatch as before. method_call and poly_dispatch: GCC does the same.
    //
    // Only for a site inside a loop, at most DV_MAX candidate classes, each
    // method a small leaf (the point is to inline it).
    final void devirtualise(IRModule* m)
        {
        if (!_profile.devirtualise())
            return;
        // Indexes for the run, each keeping the FIRST match the scans they
        // replace found (a whole-module build: 1.7 s became 5.6 s without).
        _dvVt = new Map();
        _dvFn = new Map();
        _dvLay = new Map();
        _dvCand = new Map();
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() == (u8)SYM_VTABLE && _dvVt.get((Hashable*)s.name()) == (Object*)0)
                _dvVt.set((Hashable*)s.name(), (Object*)s);
            }
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)m.funcs().get(i);
            if (_dvFn.get((Hashable*)f.name()) == (Object*)0)
                _dvFn.set((Hashable*)f.name(), (Object*)f);
            }
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 guard = (u32)0;
            while (guard < (u32)64 && dvOne(m, fn))
                guard = guard + (u32)1;
            }
        }

    // The classes the receiver can be: the vtable of the receiver's static
    // class (by its layout, the type its own methods take as self), walked
    // up to the highest ancestor that still has a method in the slot, and
    // every class below that, in the module's symbol order. Empty when the
    // class is unknown, when any method is not a small leaf this module
    // defines, or when there are more than DV_MAX.
    final Array* dvCandidates(IRModule* m, i64 slot, String* recvTy)
        {
        if (slot < (i64)0 || recvTy == (String*)0)
            return new Array();
        // A leaf method has no call for this pass to rewrite, so the answer
        // for a slot and type holds for the whole run.
        String* key = String.withFormat("%ld|%s", slot, recvTy.cString());
        Array* had = (Array*)_dvCand.get((Hashable*)key);
        if (had != (Array*)0)
            return had;
        Array* got = dvCandidatesOf(m, slot, recvTy);
        _dvCand.set((Hashable*)key, (Object*)got);
        return got;
        }

    final Array* dvCandidatesOf(IRModule* m, i64 slot, String* recvTy)
        {
        Array* out = new Array();
        IRSymbol* c0 = dvVtableOfLayout(m, recvTy);
        if (c0 == (IRSymbol*)0 || !dvHasSlot(c0, slot))
            return out;
        // Up while the ancestor's slot holds the same method (an override
        // keeps the name after the class: Boxy$score over Shape$score). A
        // slot past the end of an ancestor's methods can hold something else
        // in a class above it.
        String* sel = dvSelector((String*)c0.slots().get((u32)slot));
        IRSymbol* root = c0;
        for (u32 guard = (u32)0; guard < (u32)64; guard = guard + (u32)1)
            {
            IRSymbol* up = dvParent(m, root);
            if (up == (IRSymbol*)0 || !dvHasSlot(up, slot) || !dvSelector((String*)up.slots().get((u32)slot)).equals(sel))
                break;
            root = up;
            }
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() != (u8)SYM_VTABLE || !dvHasSlot(s, slot) || !dvDescends(m, s, root))
                continue;
            IRFunc* body = dvFunc(m, (String*)s.slots().get((u32)slot));
            if (body == (IRFunc*)0 || !dvSmallLeaf(body))
                return new Array();
            out.add((Object*)s);
            if (out.count() > (u32)DV_MAX)
                return new Array();
            }
        return out;
        }

    // A method's name after its class: "score" of "Boxy$score".
    final String* dvSelector(String* impl)
        {
        u32 d = impl.indexOfByte((u8)'$');
        return d == (u32)$FFFF_FFFF ? impl : impl.substringFromByte(d + (u32)1);
        }

    final bool dvHasSlot(IRSymbol* v, i64 slot)
        {
        if (v.slots() == (Array*)0 || (u32)slot >= v.slots().count())
            return false;
        String* impl = (String*)v.slots().get((u32)slot);
        return impl != (String*)0 && !impl.equals(String.withCString("_"));
        }

    final IRSymbol* dvVtableNamed(IRModule* m, String* name)
        {
        return (IRSymbol*)_dvVt.get((Hashable*)name);
        }

    // A vtable's superclass: its slot 0 names the parent's vtable.
    final IRSymbol* dvParent(IRModule* m, IRSymbol* v)
        {
        if (v.slots() == (Array*)0 || v.slots().count() == (u32)0)
            return (IRSymbol*)0;
        String* up = (String*)v.slots().get((u32)0);
        if (up == (String*)0 || up.equals(String.withCString("_")))
            return (IRSymbol*)0;
        return dvVtableNamed(m, up);
        }

    final bool dvDescends(IRModule* m, IRSymbol* v, IRSymbol* root)
        {
        IRSymbol* c = v;
        for (u32 guard = (u32)0; c != (IRSymbol*)0 && guard < (u32)64; guard = guard + (u32)1)
            {
            if (c == root)
                return true;
            c = dvParent(m, c);
            }
        return false;
        }

    // The class whose own methods (named "<Class>$...", in its vtable) take
    // a self of this type.
    final IRSymbol* dvVtableOfLayout(IRModule* m, String* ty)
        {
        Object* had = _dvLay.get((Hashable*)ty);
        if (had != (Object*)0)
            return had == (Object*)m ? (IRSymbol*)0 : (IRSymbol*)had;   // the module: none
        IRSymbol* v = dvVtableOfLayoutScan(m, ty);
        _dvLay.set((Hashable*)ty, v != (IRSymbol*)0 ? (Object*)v : (Object*)m);
        return v;
        }

    final IRSymbol* dvVtableOfLayoutScan(IRModule* m, String* ty)
        {
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* v = (IRSymbol*)m.syms().get(i);
            if (v.kind() != (u8)SYM_VTABLE || v.slots() == (Array*)0 || !v.name().hasSuffix(String.withCString("$vtbl")))
                continue;
            String* cls = v.name().substringBytes((u32)0, v.name().byteLength() - (u32)4);   // "<Class>$"
            for (u32 k = (u32)1; k < v.slots().count(); k = k + (u32)1)
                {
                String* impl = (String*)v.slots().get(k);
                if (impl == (String*)0 || !impl.hasPrefix(cls))
                    continue;
                IRFunc* f = dvFunc(m, impl);
                if (f == (IRFunc*)0 || f.params().count() == (u32)0)
                    continue;
                String* pt = ((IRValue*)f.params().get((u32)0)).ty();
                if (pt != (String*)0 && pt.equals(ty))
                    return v;
                break;
                }
            }
        return (IRSymbol*)0;
        }

    final IRFunc* dvFunc(IRModule* m, String* name)
        {
        return (IRFunc*)_dvFn.get((Hashable*)name);
        }

    // One block, no call, at most DV_BODY instructions: worth inlining.
    final bool dvSmallLeaf(IRFunc* f)
        {
        if (f.blocks().count() != (u32)1)
            return false;
        IRBlock* b = (IRBlock*)f.blocks().get((u32)0);
        if (b.insns().count() > (u32)DV_BODY)
            return false;
        for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)b.insns().get(i)).op();
            if (op.equals(String.withCString("Call")) || op.equals(String.withCString("VTblDispatch"))
                || op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("CallIndirect")))
                return false;
            }
        return true;
        }

    // Is block index bi inside a loop: a branch from a block at or after it
    // back to one at or before it.
    final bool dvInLoop(IRFunc* fn, u32 bi)
        {
        for (u32 u = bi; u < fn.blocks().count(); u = u + (u32)1)
            {
            IRInsn* t = ((IRBlock*)fn.blocks().get(u)).term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                for (u32 h = (u32)0; h <= bi; h = h + (u32)1)
                    if ((IRBlock*)fn.blocks().get(h) == o.blk())
                        return true;
                }
            }
        return false;
        }

    // The first suitable site in fn, rewritten; false when there is none.
    final bool dvOne(IRModule* m, IRFunc* fn)
        {
        for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* B = (IRBlock*)fn.blocks().get(bi);
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* d = (IRInsn*)B.insns().get(i);
                if (!d.op().equals(String.withCString("VTblDispatch")) || d.ops().count() < (u32)3)
                    continue;
                if (_dvDone != (Array*)0 && _dvDone.contains((Object*)d))
                    continue;
                if (d.memRes() == (IRValue*)0)
                    continue;
                IROperand* so = (IROperand*)d.ops().get((u32)1);
                IROperand* ro = (IROperand*)d.ops().get((u32)0);
                IROperand* mo = (IROperand*)d.ops().get(d.ops().count() - (u32)1);
                if (so.kind() != (u8)OPK_IMMI || ro.kind() != (u8)OPK_USE || mo.kind() != (u8)OPK_USE)
                    continue;
                if (!dvInLoop(fn, bi))
                    continue;
                Array* cands = dvCandidates(m, (i64)so.imm(), ro.val().ty());
                if (cands.count() == (u32)0)
                    continue;
                _dvModule = m;
                if (_dvDone == (Array*)0)
                    _dvDone = new Array();
                // A receiver that does not change in the loop: the test goes
                // before the loop, and each class gets a copy of the loop with
                // a direct call (no test, no call left to stop the unroller).
                if (dvVersion(fn, B, d, cands))
                    return true;
                dvApply(fn, B, bi, i, d, cands);
                return true;
                }
            }
        return false;
        }

    // B[..i) | test 0 .. test n-1 | call k | the dispatch | join: B(i..] + B's
    // terminator. The result and the memory token after the site are phis in
    // the join.
    // A checked build's vtable check (#34) on the dispatch d, in its block b:
    // the call `_xt_check_vtbl(recv, site)` on d's receiver whose memory token
    // d takes. Where the class test proves the class, the call is direct and
    // reads no vtable, so the check goes with the dispatch: into the fallback
    // (the split form), or out of a class's copy of the loop (versioning).
    final IRInsn* dvCheckOf(IRInsn* d, IRBlock* b)
        {
        IROperand* ro = (IROperand*)d.ops().get((u32)0);
        IROperand* mo = (IROperand*)d.ops().get(d.ops().count() - (u32)1);
        if (ro.kind() != (u8)OPK_USE || mo.kind() != (u8)OPK_USE)
            return (IRInsn*)0;
        for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)b.insns().get(i);
            if (n.memRes() == (IRValue*)0 || n.memRes() != mo.val())
                continue;
            if (!n.op().equals(String.withCString("Call")) || n.ops().count() < (u32)3)
                return (IRInsn*)0;
            IROperand* c0 = (IROperand*)n.ops().get((u32)0);
            IROperand* c1 = (IROperand*)n.ops().get((u32)1);
            if (c0.kind() != (u8)OPK_SYM || c1.kind() != (u8)OPK_USE || c1.val() != ro.val()
                || c0.name() == (String*)0 || !c0.name().equals(String.withCString("_xt_check_vtbl")))
                return (IRInsn*)0;
            return n;
            }
        return (IRInsn*)0;
        }

    final void dvApply(IRFunc* fn, IRBlock* B, u32 bi, u32 i, IRInsn* d, Array* cands)
        {
        if (_dvDone == (Array*)0)
            _dvDone = new Array();
        _dvDone.add((Object*)d);
        _dvSeq = _dvSeq + (u32)1;
        String* base = String.withCString("");
        base.appendFormat("%s_dv%lu", B.name().cString(), _dvSeq);
        IROperand* ro = (IROperand*)d.ops().get((u32)0);
        IROperand* mo = (IROperand*)d.ops().get(d.ops().count() - (u32)1);
        // The vtable check moves to the fallback: the tests and the direct
        // calls take the memory it took.
        IRInsn* chk = dvCheckOf(d, B);
        if (chk != (IRInsn*)0)
            {
            u32 ci = (u32)0;
            while (ci < B.insns().count() && (IRInsn*)B.insns().get(ci) != chk)
                ci = ci + (u32)1;
            B.insns().removeAt(ci);
            if (ci < i)
                i = i - (u32)1;
            mo = (IROperand*)chk.ops().get(chk.ops().count() - (u32)1);
            }

        // The join: what followed the site, and B's terminator.
        IRBlock* J = new IRBlock(String.withFormat("%s_join", base.cString()));
        for (u32 k = i + (u32)1; k < B.insns().count(); k = k + (u32)1)
            J.add((IRInsn*)B.insns().get(k));
        J.setTerm(B.term());
        while (B.insns().count() > i)
            B.insns().removeAt(B.insns().count() - (u32)1);
        dvRetargetSuccPhis(fn, J, B);

        // The class: the object's word 0.
        IRValue* fa = new IRValue(String.withCString("Ptr(Ptr(Void, unbanked), xt_data)"));
        IRInsn* fai = IRInsn.with(String.withCString("FieldAddr"));
        fai.copyDbg(d);
        fai.setRes(fa);
        fai.add(ro);
        fai.add(IROperand.immI((i32)0, String.withCString("U8")));
        B.add(fai);
        IRValue* cls = new IRValue(String.withCString("Ptr(Void, unbanked)"));
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        ld.copyDbg(d);
        ld.setRes(cls);
        ld.setMemRes(new IRValue(String.withCString("Mem")));
        ld.add(IROperand.useVal(fa));
        ld.add(mo);
        B.add(ld);

        // The fallback: the dispatch as it was.
        IRBlock* F = new IRBlock(String.withFormat("%s_virt", base.cString()));
        if (chk != (IRInsn*)0)
            F.add(chk);
        F.add(d);
        IRInsn* fbr = IRInsn.with(String.withCString("Branch"));
        fbr.add(IROperand.block(J));
        F.setTerm(fbr);

        // The tests, one block each after the first, and a call block per class.
        Array* newBlocks = new Array();
        Array* calls = new Array();
        Array* callBlocks = new Array();
        IRBlock* testBlk = B;
        for (u32 c = (u32)0; c < cands.count(); c = c + (u32)1)
            {
            IRSymbol* vt = (IRSymbol*)cands.get(c);
            String* impl = (String*)vt.slots().get((u32)((IROperand*)d.ops().get((u32)1)).imm());
            IRValue* va = new IRValue(String.withCString("Ptr(Void, unbanked)"));
            IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
            ao.copyDbg(d);
            ao.setRes(va);
            ao.add(IROperand.sym(vt.name()));
            testBlk.add(ao);
            IRValue* eq = new IRValue(String.withCString("Bool"));
            IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
            cmp.copyDbg(d);
            cmp.setPred(String.withCString("EQ"));
            cmp.setRes(eq);
            cmp.add(IROperand.useVal(cls));
            cmp.add(IROperand.useVal(va));
            testBlk.add(cmp);

            IRBlock* T = new IRBlock(String.withFormat("%s_c%lu", base.cString(), c));
            // The receiver as the method's own first parameter: a subclass's
            // method takes its own layout.
            IROperand* recv = ro;
            IRFunc* body = dvFunc(_dvModule, impl);
            if (body != (IRFunc*)0 && body.params().count() > (u32)0)
                {
                String* pt = ((IRValue*)body.params().get((u32)0)).ty();
                if (pt != (String*)0 && ro.val().ty() != (String*)0 && !pt.equals(ro.val().ty()))
                    {
                    IRValue* rc = new IRValue(pt);
                    IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
                    bc.copyDbg(d);
                    bc.setRes(rc);
                    bc.add(ro);
                    T.add(bc);
                    recv = IROperand.useVal(rc);
                    }
                }
            IRInsn* call = IRInsn.with(String.withCString("Call"));
            call.copyDbg(d);
            call.setCc(String.withCString("CallConv::Standard"));
            call.add(IROperand.sym(impl));
            call.add(recv);
            for (u32 k = (u32)2; k < d.ops().count(); k = k + (u32)1)
                call.add(k + (u32)1 == d.ops().count() ? mo : (IROperand*)d.ops().get(k));
            // The result at the method's own return type, cast to the site's:
            // the inliner hands its uses the method's value (a subclass's
            // Array$get returns Object*; its reader keeps Number's layout).
            IRValue* cres = (IRValue*)0;
            IRValue* want = (IRValue*)0;
            if (d.res() != (IRValue*)0)
                {
                want = new IRValue(d.res().ty());
                cres = dvResultAs(body, want);
                call.setRes(cres);
                }
            call.setMemRes(new IRValue(String.withCString("Mem")));
            T.add(call);
            if (cres != want)
                dvCastResult(T, d, cres, want);
            IRInsn* tbr = IRInsn.with(String.withCString("Branch"));
            tbr.add(IROperand.block(J));
            T.setTerm(tbr);
            calls.add((Object*)call);
            callBlocks.add((Object*)T);

            IRBlock* next = c + (u32)1 < cands.count()
                ? new IRBlock(String.withFormat("%s_t%lu", base.cString(), c + (u32)1)) : F;
            IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
            cb.add(IROperand.useVal(eq));
            cb.add(IROperand.block(T));
            cb.add(IROperand.block(next));
            testBlk.setTerm(cb);
            newBlocks.add((Object*)T);
            if (next != F)
                newBlocks.add((Object*)next);
            testBlk = next;
            }
        newBlocks.add((Object*)F);
        newBlocks.add((Object*)J);

        // The join's phis: the result and the memory after the site, from
        // each call and from the dispatch.
        IRValue* oldRes = d.res();
        IRValue* rp = (IRValue*)0;
        if (oldRes != (IRValue*)0)
            {
            rp = new IRValue(oldRes.ty());
            IRInsn* ph = IRInsn.with(String.withCString("Phi"));
            ph.setRes(rp);
            for (u32 c = (u32)0; c < calls.count(); c = c + (u32)1)
                {
                ph.add(IROperand.block((IRBlock*)callBlocks.get(c)));
                ph.add(IROperand.useVal(((IRInsn*)calls.get(c)).res()));
                }
            ph.add(IROperand.block(F));
            ph.add(IROperand.useVal(oldRes));
            J.phis().add(ph);
            }
        // No memory phi: the IR threads its memory token in emission order
        // (lowering makes no memory phis), and F, just before J, ends with
        // the dispatch's token, which the join's readers keep.

        // Readers of the site's result now read the join's phi.
        if (oldRes != (IRValue*)0)
            {
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                dvReplaceIn((IRBlock*)fn.blocks().get(b), oldRes, rp);
            dvReplaceIn(J, oldRes, rp);
            }

        // Place the new blocks after B.
        Array* kept = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            kept.add(fn.blocks().get(b));
            if (b == bi)
                for (u32 k = (u32)0; k < newBlocks.count(); k = k + (u32)1)
                    kept.add(newBlocks.get(k));
            }
        fn.setBlocks(kept);
        }

    // ── loop versioning ─────────────────────────────────────────────────
    //
    // The innermost natural loop holding B, when it has a unique preheader
    // ending in a plain branch to the header, one exit block whose
    // predecessors are all in the loop, and at most DV_LOOP instructions; the
    // receiver defined outside it. The preheader then tests the class, and
    // each candidate class runs a copy of the loop where the site is a direct
    // call; any other class runs the loop as it was.
    final bool dvVersion(IRFunc* fn, IRBlock* B, IRInsn* d, Array* cands)
        {
        IROperand* ro = (IROperand*)d.ops().get((u32)0);
        Map* dom = self.dominators(fn);
        Map* preds = self.lrcPredMap(fn);
        Array* best = (Array*)0;
        IRBlock* bestH = (IRBlock*)0;
        for (u32 li = (u32)0; li < fn.blocks().count(); li = li + (u32)1)
            {
            IRBlock* latch = (IRBlock*)fn.blocks().get(li);
            Array* ss = self.lrcSuccs(fn, latch);
            for (u32 s = (u32)0; s < ss.count(); s = s + (u32)1)
                {
                IRBlock* H = (IRBlock*)ss.get(s);
                Array* dl = (Array*)dom.get((Hashable*)latch);
                if (dl == (Array*)0 || !self.hasBlock(dl, H))
                    continue;
                Array* body = dvLoopBody(preds, H, latch);
                if (!self.hasBlock(body, B))
                    continue;
                if (best == (Array*)0 || body.count() < best.count())
                    {
                    best = body;
                    bestH = H;
                    }
                }
            }
        if (best == (Array*)0)
            return false;
        IRBlock* H = bestH;
        // The receiver is defined outside the loop.
        for (u32 b = (u32)0; b < best.count(); b = b + (u32)1)
            if (dvDefines((IRBlock*)best.get(b), ro.val()))
                return false;
        // The preheader: H's one predecessor outside the loop, branching to H alone.
        IRBlock* P = (IRBlock*)0;
        Array* hp = self.lrcPredsIn(preds, H);
        for (u32 k = (u32)0; k < hp.count(); k = k + (u32)1)
            {
            IRBlock* q = (IRBlock*)hp.get(k);
            if (self.hasBlock(best, q))
                continue;
            if (P != (IRBlock*)0)
                return false;
            P = q;
            }
        if (P == (IRBlock*)0 || P.term() == (IRInsn*)0 || !P.term().op().equals(String.withCString("Branch")))
            return false;
        // One exit block, reached from the loop only.
        IRBlock* X = (IRBlock*)0;
        u32 ninsns = (u32)0;
        for (u32 b = (u32)0; b < best.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)best.get(b);
            ninsns = ninsns + bb.insns().count() + bb.phis().count();
            Array* ss = self.lrcSuccs(fn, bb);
            for (u32 s = (u32)0; s < ss.count(); s = s + (u32)1)
                {
                IRBlock* t = (IRBlock*)ss.get(s);
                if (self.hasBlock(best, t))
                    continue;
                if (X != (IRBlock*)0 && X != t)
                    return false;
                X = t;
                }
            }
        if (X == (IRBlock*)0 || ninsns > (u32)DV_LOOP)
            return false;
        Array* xp = self.lrcPredsIn(preds, X);
        for (u32 k = (u32)0; k < xp.count(); k = k + (u32)1)
            if (!self.hasBlock(best, (IRBlock*)xp.get(k)))
                return false;
        // One exiting block: each version's exit then carries its values
        // over one edge.
        if (xp.count() != (u32)1)
            return false;

        IROperand* memP = dvMemAtEnd(P, H);
        // A preheader that touches no memory: the token comes down from the
        // blocks above it, through single predecessors.
        IRBlock* up = P;
        for (u32 k = (u32)0; memP == (IROperand*)0 && k < (u32)64; k = k + (u32)1)
            {
            Array* ups = self.lrcPredsIn(preds, up);
            if (ups.count() != (u32)1)
                break;
            up = (IRBlock*)ups.get((u32)0);
            memP = dvMemAtEnd(up, H);
            }
        // Up to the entry with nothing touching memory: the function's own
        // memory parameter (its last) is the token.
        if (memP == (IROperand*)0 && self.lrcPredsIn(preds, up).count() == (u32)0 && fn.params().count() > (u32)0)
            {
            IRValue* lp = (IRValue*)fn.params().get(fn.params().count() - (u32)1);
            if (lp.ty() != (String*)0 && lp.ty().equals(String.withCString("Mem")))
                memP = IROperand.useVal(lp);
            }
        if (memP == (IROperand*)0)
            return false;
        _dvDone.add((Object*)d);
        _dvSeq = _dvSeq + (u32)1;
        // The loop's blocks in layout order.
        Array* body = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (self.hasBlock(best, (IRBlock*)fn.blocks().get(b)))
                body.add(fn.blocks().get(b));
        i64 slot = (i64)((IROperand*)d.ops().get((u32)1)).imm();

        // The test chain at the end of P: P, then one block per further class.
        IRValue* fa = new IRValue(String.withCString("Ptr(Ptr(Void, unbanked), xt_data)"));
        IRInsn* fai = IRInsn.with(String.withCString("FieldAddr"));
        fai.copyDbg(d);
        fai.setRes(fa);
        fai.add(ro);
        fai.add(IROperand.immI((i32)0, String.withCString("U8")));
        P.add(fai);
        IRValue* cls = new IRValue(String.withCString("Ptr(Void, unbanked)"));
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        ld.copyDbg(d);
        ld.setRes(cls);
        ld.setMemRes(new IRValue(String.withCString("Mem")));
        ld.add(IROperand.useVal(fa));
        ld.add(memP);
        P.add(ld);

        Array* vmaps = new Array();      // per class: its value map
        Array* pres = new Array();       // per class: its copy's preheader
        // The original loop's preheader, after the last test.
        IRBlock* preOrig = new IRBlock(String.withFormat("%s_dv%lu_po", P.name().cString(), _dvSeq));
        IRInsn* pob = IRInsn.with(String.withCString("Branch"));
        pob.add(IROperand.block(H));
        preOrig.setTerm(pob);
        Array* entries = new Array();    // per class: the test block entering its copy
        Array* copies = new Array();     // per class: its block map
        IRBlock* tb = P;
        for (u32 c = (u32)0; c < cands.count(); c = c + (u32)1)
            {
            IRSymbol* vt = (IRSymbol*)cands.get(c);
            IRValue* va = new IRValue(String.withCString("Ptr(Void, unbanked)"));
            IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
            ao.copyDbg(d);
            ao.setRes(va);
            ao.add(IROperand.sym(vt.name()));
            tb.add(ao);
            IRValue* eq = new IRValue(String.withCString("Bool"));
            IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
            cmp.copyDbg(d);
            cmp.setPred(String.withCString("EQ"));
            cmp.setRes(eq);
            cmp.add(IROperand.useVal(cls));
            cmp.add(IROperand.useVal(va));
            tb.add(cmp);
            Map* bmap = new Map();
            Map* vmap = new Map();
            String* sfx = String.withFormat("_dv%lu_v%lu", _dvSeq, c);
            for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
                {
                IRBlock* ob = (IRBlock*)body.get(b);
                IRBlock* nb = new IRBlock(String.withFormat("%s%s", ob.name().cString(), sfx.cString()));
                bmap.set((Hashable*)ob, (Object*)nb);
                }
            IRBlock* next = c + (u32)1 < cands.count()
                ? new IRBlock(String.withFormat("%s_dv%lu_t%lu", P.name().cString(), _dvSeq, c + (u32)1)) : preOrig;
            // Each copy has a preheader of its own, ending in a plain branch,
            // as the loop passes after this one expect.
            IRBlock* pre = new IRBlock(String.withFormat("%s_dv%lu_p%lu", P.name().cString(), _dvSeq, c));
            IRInsn* pb = IRInsn.with(String.withCString("Branch"));
            pb.add(IROperand.block((IRBlock*)bmap.get((Hashable*)H)));
            pre.setTerm(pb);
            pres.add((Object*)pre);
            IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
            cb.add(IROperand.useVal(eq));
            cb.add(IROperand.block(pre));
            cb.add(IROperand.block(next));
            if (tb == P)
                P.setTerm(cb);
            else
                tb.setTerm(cb);
            entries.add((Object*)tb);
            copies.add((Object*)bmap);
            dvCloneLoop(body, bmap, vmap, d, vt, (String*)vt.slots().get((u32)slot), P, pre);
            vmaps.add((Object*)vmap);
            if (next != preOrig)
                tb = next;
            }
        // The original loop is entered from the last test block.
        dvRetargetPhiPred(H, P, preOrig);

        // The exit: each copy's exiting edges carry the same values, mapped.
        Array* exits = dvJoinExit(fn, body, X, copies, vmaps);

        // Place the test blocks and the copies after P.
        Array* added = new Array();
        for (u32 c = (u32)0; c < cands.count(); c = c + (u32)1)
            {
            IRBlock* e = (IRBlock*)entries.get(c);
            if (e != P)
                added.add((Object*)e);
            added.add(pres.get(c));
            Map* bmap = (Map*)copies.get(c);
            for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
                added.add(bmap.get((Hashable*)body.get(b)));
            added.add(exits.get(c + (u32)1));
            }
        added.add((Object*)preOrig);
        Array* kept = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            // The original loop's exit block goes just before X.
            if ((IRBlock*)fn.blocks().get(b) == X)
                kept.add(exits.get((u32)0));
            kept.add(fn.blocks().get(b));
            if ((IRBlock*)fn.blocks().get(b) == P)
                for (u32 k = (u32)0; k < added.count(); k = k + (u32)1)
                    kept.add(added.get(k));
            }
        fn.setBlocks(kept);
        return true;
        }

    final Array* dvLoopBody(Map* preds, IRBlock* H, IRBlock* latch)
        {
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
            Array* ps = self.lrcPredsIn(preds, n);
            for (u32 p = (u32)0; p < ps.count(); p = p + (u32)1)
                wl.add(ps.get(p));
            }
        return body;
        }

    // Identity, not equals: blocks are compared as objects.
    final bool dvHasBlockIn(Array* a, IRBlock* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRBlock*)a.get(i) == b)
                return true;
        return false;
        }

    final bool dvDefines(IRBlock* b, IRValue* v)
        {
        for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1)
            if (((IRInsn*)b.phis().get(i)).res() == v)
                return true;
        for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
            if (((IRInsn*)b.insns().get(i)).res() == v)
                return true;
        return false;
        }

    // The memory token live at the end of P: what H's memory phi takes from
    // P, else P's last memory result, else P's own memory phi; 0 when none
    // is found (the caller then does not version).
    final IROperand* dvMemAtEnd(IRBlock* P, IRBlock* H)
        {
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* ph = (IRInsn*)H.phis().get(i);
            if (dvPhiMem(ph) == (IRValue*)0)
                continue;
            for (u32 q = (u32)0; q + (u32)1 < ph.ops().count(); q = q + (u32)2)
                if (((IROperand*)ph.ops().get(q)).blk() == P)
                    return (IROperand*)ph.ops().get(q + (u32)1);
            }
        for (i32 i = (i32)P.insns().count() - (i32)1; i >= (i32)0; i = i - (i32)1)
            {
            IRInsn* n = (IRInsn*)P.insns().get((u32)i);
            if (n.memRes() != (IRValue*)0)
                return IROperand.useVal(n.memRes());
            }
        // A join block's memory is a phi of its own.
        for (u32 i = (u32)0; i < P.phis().count(); i = i + (u32)1)
            {
            IRValue* pm = dvPhiMem((IRInsn*)P.phis().get(i));
            if (pm != (IRValue*)0)
                return IROperand.useVal(pm);
            }
        return (IROperand*)0;
        }

    // A phi's memory token: its memory result (as lowering makes a memory
    // phi), else a result typed Mem.
    final IRValue* dvPhiMem(IRInsn* ph)
        {
        if (ph.memRes() != (IRValue*)0)
            return ph.memRes();
        if (ph.res() != (IRValue*)0 && ph.res().ty() != (String*)0 && ph.res().ty().equals(String.withCString("Mem")))
            return ph.res();
        return (IRValue*)0;
        }

    // The copy of the loop for one class: every block, its values renamed,
    // the site a direct call; H's incomings from P come from `entry`.
    final void dvCloneLoop(Array* body, Map* bmap, Map* vmap, IRInsn* d, IRSymbol* vt, String* impl, IRBlock* P, IRBlock* entry)
        {
        // The vtable checks of the dispatches this copy makes direct: the
        // class is known here and a direct call reads no vtable, so each goes,
        // its memory token standing for the one it took.
        Set* drops = dvCopyDrops(body, d, vt);
        // Names first: a phi can read a value defined later in the loop.
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)body.get(b);
            for (u32 i = (u32)0; i < ob.phis().count(); i = i + (u32)1)
                dvName(vmap, (IRInsn*)ob.phis().get(i));
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                if (!drops.contains((Hashable*)ob.insns().get(i)))
                    dvName(vmap, (IRInsn*)ob.insns().get(i));
            }
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)body.get(b);
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)ob.insns().get(i);
                if (!drops.contains((Hashable*)n))
                    continue;
                IRValue* src = ((IROperand*)n.ops().get(n.ops().count() - (u32)1)).val();
                Object* m = vmap.get((Hashable*)src);
                vmap.set((Hashable*)n.memRes(), m != (Object*)0 ? m : (Object*)src);
                }
            }
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)body.get(b);
            IRBlock* nb = (IRBlock*)bmap.get((Hashable*)ob);
            for (u32 i = (u32)0; i < ob.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)ob.phis().get(i);
                IRInsn* np = dvCloneInsn(p, vmap, bmap);
                for (u32 q = (u32)0; q + (u32)1 < np.ops().count(); q = q + (u32)2)
                    if (((IROperand*)np.ops().get(q)).blk() == P)
                        np.ops().set(q, (Object*)IROperand.block(entry));
                nb.phis().add(np);
                }
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)ob.insns().get(i);
                if (drops.contains((Hashable*)n))
                    continue;
                if (n == d)
                    {
                    dvDirectCall(nb, n, vmap, impl);
                    continue;
                    }
                // Another dispatch on the same receiver: its class is known
                // in this copy, so the call is direct. A dispatch on anything
                // else is done with here: versioned again, each copy would
                // copy the loop again (BinaryHeap$_siftDown: 448 copies).
                if (n.op().equals(String.withCString("VTblDispatch")) && n.ops().count() >= (u32)2)
                    {
                    IROperand* r0 = (IROperand*)n.ops().get((u32)0);
                    IROperand* s0 = (IROperand*)n.ops().get((u32)1);
                    IROperand* dr = (IROperand*)d.ops().get((u32)0);
                    if (r0.kind() == (u8)OPK_USE && r0.val() == dr.val() && dvHasSlot(vt, (i64)s0.imm()))
                        {
                        dvDirectCall(nb, n, vmap, (String*)vt.slots().get((u32)s0.imm()));
                        continue;
                        }
                    IRInsn* nc = dvCloneInsn(n, vmap, bmap);
                    _dvDone.add((Object*)nc);
                    nb.add(nc);
                    continue;
                    }
                nb.add(dvCloneInsn(n, vmap, bmap));
                }
            if (ob.term() != (IRInsn*)0)
                nb.setTerm(dvCloneInsn(ob.term(), vmap, bmap));
            }
        }

    // dvCloneLoop's drops: the check of each dispatch a copy makes direct —
    // the site itself, and any other on its receiver whose slot the class has.
    final Set* dvCopyDrops(Array* body, IRInsn* d, IRSymbol* vt)
        {
        Set* drops = new Set();
        IROperand* dr = (IROperand*)d.ops().get((u32)0);
        for (u32 b = (u32)0; b < body.count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)body.get(b);
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)ob.insns().get(i);
                if (!n.op().equals(String.withCString("VTblDispatch")) || n.ops().count() < (u32)3)
                    continue;
                IROperand* r0 = (IROperand*)n.ops().get((u32)0);
                IROperand* s0 = (IROperand*)n.ops().get((u32)1);
                if (n != d && !(r0.kind() == (u8)OPK_USE && r0.val() == dr.val() && dvHasSlot(vt, (i64)s0.imm())))
                    continue;
                IRInsn* c = dvCheckOf(n, ob);
                if (c != (IRInsn*)0)
                    drops.add((Hashable*)c);
                }
            }
        return drops;
        }

    final void dvName(Map* vmap, IRInsn* n)
        {
        if (n.res() != (IRValue*)0)
            vmap.set((Hashable*)n.res(), (Object*)new IRValue(n.res().ty()));
        if (n.memRes() != (IRValue*)0)
            vmap.set((Hashable*)n.memRes(), (Object*)new IRValue(String.withCString("Mem")));
        }

    final IRInsn* dvCloneInsn(IRInsn* n, Map* vmap, Map* bmap)
        {
        IRInsn* c = IRInsn.with(n.op());
        c.copyDbg(n);
        c.setPred(n.pred());
        c.setCc(n.cc());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            c.add(dvMapOp((IROperand*)n.ops().get(k), vmap, bmap));
        if (n.res() != (IRValue*)0)
            c.setRes((IRValue*)vmap.get((Hashable*)n.res()));
        if (n.memRes() != (IRValue*)0)
            c.setMemRes((IRValue*)vmap.get((Hashable*)n.memRes()));
        return c;
        }

    final IROperand* dvMapOp(IROperand* o, Map* vmap, Map* bmap)
        {
        if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
            {
            Object* nv = vmap.get((Hashable*)o.val());
            return nv != (Object*)0 ? IROperand.useVal((IRValue*)nv) : o;
            }
        if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0)
            {
            Object* nb = bmap.get((Hashable*)o.blk());
            return nb != (Object*)0 ? IROperand.block((IRBlock*)nb) : o;
            }
        return o;
        }

    // The site in a copy: a direct call to the class's method.
    final void dvDirectCall(IRBlock* nb, IRInsn* d, Map* vmap, String* impl)
        {
        IROperand* recv = dvMapOp((IROperand*)d.ops().get((u32)0), vmap, new Map());
        IRFunc* body = dvFunc(_dvModule, impl);
        if (body != (IRFunc*)0 && body.params().count() > (u32)0 && recv.kind() == (u8)OPK_USE)
            {
            String* pt = ((IRValue*)body.params().get((u32)0)).ty();
            if (pt != (String*)0 && recv.val().ty() != (String*)0 && !pt.equals(recv.val().ty()))
                {
                IRValue* rc = new IRValue(pt);
                IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
                bc.copyDbg(d);
                bc.setRes(rc);
                bc.add(recv);
                nb.add(bc);
                recv = IROperand.useVal(rc);
                }
            }
        IRInsn* call = IRInsn.with(String.withCString("Call"));
        call.copyDbg(d);
        call.setCc(String.withCString("CallConv::Standard"));
        call.add(IROperand.sym(impl));
        call.add(recv);
        for (u32 k = (u32)2; k < d.ops().count(); k = k + (u32)1)
            call.add(dvMapOp((IROperand*)d.ops().get(k), vmap, new Map()));
        IRValue* want = d.res() != (IRValue*)0 ? (IRValue*)vmap.get((Hashable*)d.res()) : (IRValue*)0;
        IRValue* cres = want != (IRValue*)0 ? dvResultAs(body, want) : (IRValue*)0;
        if (cres != (IRValue*)0)
            call.setRes(cres);
        call.setMemRes((IRValue*)vmap.get((Hashable*)d.memRes()));
        nb.add(call);
        if (cres != want)
            dvCastResult(nb, d, cres, want);
        }

    // The value a direct call to body yields for a site whose result is want:
    // want itself when the method returns its type, else a new value of the
    // method's return type (dvCastResult casts it to want after the call).
    final IRValue* dvResultAs(IRFunc* body, IRValue* want)
        {
        if (body == (IRFunc*)0 || body.ret() == (String*)0 || want.ty() == (String*)0 || body.ret().equals(want.ty()))
            return want;
        return new IRValue(body.ret());
        }

    final void dvCastResult(IRBlock* b, IRInsn* d, IRValue* from, IRValue* to)
        {
        IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
        bc.copyDbg(d);
        bc.setRes(to);
        bc.add(IROperand.useVal(from));
        b.add(bc);
        }

    final void dvRetargetPhiPred(IRBlock* H, IRBlock* from, IRBlock* to)
        {
        if (from == to)
            return;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* ph = (IRInsn*)H.phis().get(i);
            for (u32 q = (u32)0; q + (u32)1 < ph.ops().count(); q = q + (u32)2)
                if (((IROperand*)ph.ops().get(q)).blk() == from)
                    ph.ops().set(q, (Object*)IROperand.block(to));
            }
        }

    // Each version leaves through an exit block of its own, branching to X,
    // so every loop is in the shape the later loop passes expect. X's phis
    // take each version's value from its exit block; a loop value read after
    // the loop becomes a phi in X over the versions. Returns the exit blocks:
    // the original loop's first, then one per copy.
    final Array* dvJoinExit(IRFunc* fn, Array* body, IRBlock* X, Array* copies, Array* vmaps)
        {
        IRBlock* ex = (IRBlock*)0;
        for (u32 b = (u32)0; b < body.count() && ex == (IRBlock*)0; b = b + (u32)1)
            {
            IRInsn* t = ((IRBlock*)body.get(b)).term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == X)
                    ex = (IRBlock*)body.get(b);
                }
            }
        Array* exits = new Array();
        Array* exiting = new Array();
        exiting.add((Object*)ex);
        for (u32 c = (u32)0; c < copies.count(); c = c + (u32)1)
            exiting.add(((Map*)copies.get(c)).get((Hashable*)ex));
        for (u32 e = (u32)0; e < exiting.count(); e = e + (u32)1)
            {
            IRBlock* eb = (IRBlock*)exiting.get(e);
            IRBlock* xb = new IRBlock(String.withFormat("%s_dv%lu_x%lu", eb.name().cString(), _dvSeq, e));
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(X));
            xb.setTerm(br);
            IRInsn* t = eb.term();
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == X)
                    t.ops().set(k, (Object*)IROperand.block(xb));
                }
            exits.add((Object*)xb);
            }
        // X's own phis: the original's edge now comes from its exit block,
        // and each copy adds its mapped value.
        for (u32 i = (u32)0; i < X.phis().count(); i = i + (u32)1)
            {
            IRInsn* ph = (IRInsn*)X.phis().get(i);
            u32 n0 = ph.ops().count();
            for (u32 q = (u32)0; q + (u32)1 < n0; q = q + (u32)2)
                {
                IROperand* bo = (IROperand*)ph.ops().get(q);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != ex)
                    continue;
                IROperand* vo = (IROperand*)ph.ops().get(q + (u32)1);
                ph.ops().set(q, (Object*)IROperand.block((IRBlock*)exits.get((u32)0)));
                for (u32 c = (u32)0; c < copies.count(); c = c + (u32)1)
                    {
                    ph.add(IROperand.block((IRBlock*)exits.get(c + (u32)1)));
                    ph.add(dvMapOp(vo, (Map*)vmaps.get(c), new Map()));
                    }
                }
            }
        // Loop values read outside the loop.
        Map* phiOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* ob = (IRBlock*)fn.blocks().get(b);
            if (dvHasBlockIn(body, ob))
                continue;
            Array* all = new Array();
            if (ob != X)
                for (u32 i = (u32)0; i < ob.phis().count(); i = i + (u32)1)
                    all.add(ob.phis().get(i));
            for (u32 i = (u32)0; i < ob.insns().count(); i = i + (u32)1)
                all.add(ob.insns().get(i));
            if (ob.term() != (IRInsn*)0)
                all.add((Object*)ob.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* u = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < u.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)u.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || ((Map*)vmaps.get((u32)0)).get((Hashable*)o.val()) == (Object*)0)
                        continue;
                    // A memory token keeps naming the original loop's: it is
                    // laid out last before X, so its token is the latest.
                    if (o.val().ty() != (String*)0 && o.val().ty().equals(String.withCString("Mem")))
                        continue;
                    IRValue* pv = (IRValue*)phiOf.get((Hashable*)o.val());
                    if (pv == (IRValue*)0)
                        {
                        pv = new IRValue(o.val().ty());
                        IRInsn* ph = IRInsn.with(String.withCString("Phi"));
                        ph.setRes(pv);
                        ph.add(IROperand.block((IRBlock*)exits.get((u32)0)));
                        ph.add(IROperand.useVal(o.val()));
                        for (u32 c = (u32)0; c < copies.count(); c = c + (u32)1)
                            {
                            ph.add(IROperand.block((IRBlock*)exits.get(c + (u32)1)));
                            ph.add(IROperand.useVal((IRValue*)((Map*)vmaps.get(c)).get((Hashable*)o.val())));
                            }
                        X.phis().add(ph);
                        phiOf.set((Hashable*)o.val(), (Object*)pv);
                        }
                    u.ops().set(k, (Object*)IROperand.useVal(pv));
                    }
                }
            }
        return exits;
        }

    // A successor's phi that took a value from B takes it from J now.
    final void dvRetargetSuccPhis(IRFunc* fn, IRBlock* J, IRBlock* B)
        {
        IRInsn* t = J.term();
        if (t == (IRInsn*)0)
            return;
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                continue;
            IRBlock* s = o.blk();
            for (u32 p = (u32)0; p < s.phis().count(); p = p + (u32)1)
                {
                IRInsn* ph = (IRInsn*)s.phis().get(p);
                for (u32 q = (u32)0; q + (u32)1 < ph.ops().count(); q = q + (u32)2)
                    if (((IROperand*)ph.ops().get(q)).blk() == B)
                        ph.ops().set(q, (Object*)IROperand.block(J));
                }
            }
        }

    final void dvReplaceIn(IRBlock* bb, IRValue* oldRes, IRValue* rp)
        {
        Array* all = new Array();
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) all.add(bb.phis().get(i));
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) all.add(bb.insns().get(i));
        if (bb.term() != (IRInsn*)0) all.add((Object*)bb.term());
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            IRInsn* u = (IRInsn*)all.get(i);
            if (u.res() == rp)
                continue;   // the join's own phi
            for (u32 k = (u32)0; k < u.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)u.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                if (o.val() == oldRes)
                    u.ops().set(k, (Object*)IROperand.useVal(rp));
                }
            }
        }
    }
