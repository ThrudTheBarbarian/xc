// OptDeadCode.xc — the DeadCode pass, ported from src/xtc/ir/XTIROptDeadCode.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (DeadCode)
    {

    // ── dead-code ────────────────────────────────────────────────────────
    //
    // A PURE instruction whose result nothing reads comes out, and so does a
    // phi nobody reads — dropping either frees its operands, so the sweep
    // repeats until nothing changes. Deliberately conservative: anything that
    // touches memory, calls, refcounts, dispatches or runs inline asm stays,
    // whether its result is read or not.
    final void deadCode(IRModule* m)
        {
        _dcModule = m;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            deadCodeInFunc((IRFunc*)m.funcs().get(f));
        _dcModule = (IRModule*)0;
        }

    final String* dseKey(IROperand* p, Map* defOf, u32 depth)
        {
        if (depth > (u32)16 || p.kind() != (u8)OPK_USE || p.val() == (IRValue*)0)
            return (String*)0;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)p.val());
        if (d == (IRInsn*)0 || d.ops().count() < (u32)1)
            return (String*)0;
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (d.isOp(opAddrOf))
            {
            if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0)
                return (String*)0;
            Object* seen = _dseLocals.get((Hashable*)o0.val());
            if (seen == (Object*)0)
                {
                seen = (Object*)Number.with(_dseLocals.count());
                _dseLocals.set((Hashable*)o0.val(), seen);
                }
            String* k = String.withCString("L");
            k.append(String.withU64((u64)((Number*)seen).asU32()));
            return k;
            }
        bool fa = d.isOp(opFieldAddr);
        if ((fa || d.isOp(opElementAddr)) && d.ops().count() == 2
            && ((IROperand*)d.ops().get((u32)1)).kind() == (u8)OPK_IMMI)
            {
            String* base = dseKey(o0, defOf, depth + (u32)1);
            if (base == (String*)0)
                return (String*)0;
            base.appendCString(fa ? "/f" : "/e");
            base.append(String.withI64(((IROperand*)d.ops().get((u32)1)).imm()));
            return base;
            }
        return (String*)0;
        }

    final String* dseTy(IRFunc* fn, IROperand* v)
        {
        if (v.kind() == (u8)OPK_USE)
            return v.val() == (IRValue*)0 ? (String*)0 : v.val().ty();
        return v.ty();
        }

    // Dead stores, block by block: a scalar store to a local, overwritten by
    // a later store to the same place and of the same type with nothing
    // between that reads memory (a load, a call, anything else with a memory
    // token), is never read. A struct local with no initialiser is
    // zero-filled and then usually assigned field by field at once:
    // struct_copy paid two zero stores a call. As the reference.
    final void deadStoresIn(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        _dseLocals = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Map* pending = new Map();
            Array* dead = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.isOp(opStore) && n.ops().count() == 3 && n.memRes() != (IRValue*)0)
                    {
                    String* key = dseKey((IROperand*)n.ops().get((u32)0), defOf, (u32)0);
                    String* t = dseTy(fn, (IROperand*)n.ops().get((u32)1));
                    if (key == (String*)0 || t == (String*)0 || IRType.isAgg(t)
                        || IRType.isVec(t))
                        continue; // a store elsewhere reads nothing: no barrier
                    IRInsn* prev = (IRInsn*)pending.get((Hashable*)key);
                    if (prev != (IRInsn*)0)
                        {
                        String* pt = dseTy(fn, (IROperand*)prev.ops().get((u32)1));
                        if (pt != (String*)0 && pt.equals(t))
                            dead.add((Object*)prev);
                        }
                    pending.set((Hashable*)key, (Object*)n);
                    continue;
                    }
                if (n.memRes() != (IRValue*)0)
                    pending = new Map();
                }
            for (u32 k = (u32)0; k < dead.count(); k = k + (u32)1)
                {
                IRInsn* st = (IRInsn*)dead.get(k);
                self.rewriteUsesTo(fn, st.memRes(), (IROperand*)st.ops().get((u32)2));
                Array* keep = new Array();
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    if ((IRInsn*)bb.insns().get(i) != st)
                        keep.add(bb.insns().get(i));
                bb.setInsns(keep);
                }
            }
        }

    // Removes from `slots` every pinned local an asm body names: the digits
    // after each "{{XTLOCAL:" or "{{XTLOCALB:" are the local's value id.
    final void dcDropAsmNamed(Array* bytes, Set* slots, IRFunc* fn)
        {
        String* t = String.withCString("");
        for (u32 b = (u32)0; b < bytes.count(); b = b + (u32)1)
            t.appendByte((u8)((Number*)bytes.get(b)).asU32());
        String* marker = String.withCString("{{XTLOCAL");
        u32 i = (u32)0;
        while (i < t.byteLength())
            {
            u32 at = t.byteIndexOf(marker, i);
            if (at == (u32)$FFFF_FFFF)
                return;
            u32 j = at + marker.byteLength();
            if (j < t.byteLength() && t.byteAt(j) == (u8)'B')
                j = j + (u32)1;
            i = j;
            if (j >= t.byteLength() || t.byteAt(j) != (u8)':')
                continue;
            j = j + (u32)1;
            u32 vid = (u32)0;
            u32 digits = (u32)0;
            while (j < t.byteLength() && t.byteAt(j) >= (u8)'0' && t.byteAt(j) <= (u8)'9')
                {
                vid = vid * (u32)10 + (u32)(t.byteAt(j) - (u8)'0');
                j = j + (u32)1;
                digits = digits + (u32)1;
                }
            i = j;
            if (digits == (u32)0)
                continue;
            for (u32 p = (u32)0; p < fn.pinned().count(); p = p + (u32)1)
                {
                IRPinned* pl = (IRPinned*)fn.pinned().get(p);
                if (pl.val() != (IRValue*)0 && pl.val().pid() == vid)
                    slots.remove((Hashable*)pl.val());
                }
            }
        }

    // Write-only locals: a frame slot that does not escape and whose address
    // (AddrOf, then field and element steps) is used only as a store's
    // address is never read, so every store to it is dead (struct_copy's
    // `p = bump(p, r)` after inlining). Any other use of an address into the
    // slot keeps every store. As the reference's writeOnlyLocalsIn.
    final void writeOnlyLocalsIn(IRFunc* fn)
        {
        Set* slots = new Set();
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            {
            IRPinned* pl = (IRPinned*)fn.pinned().get(i);
            if (!pl.esc())
                slots.add((Hashable*)pl.val());
            }
        if (slots.count() == (u32)0)
            return;
        Array* all = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                all.add(bb.phis().get(i));
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                all.add(bb.insns().get(i));
            if (bb.term() != 0)
                all.add((Object*)bb.term());
            }
        // Inline asm names locals inside its text, as {{XTLOCAL:<vid>}} (or
        // {{XTLOCALB:<vid>:<sel>}}) placeholders in the constant pool, not as
        // operands. A local an Asm names is read, so it is not write-only
        // (#400: every store feeding Gfx8's asm went, so every gfx8 program
        // drew nothing at -O2; on arm64 a local only an asm block loaded read
        // garbage). A body with no constant to read keeps every slot. As the
        // reference.
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            IRInsn* an = (IRInsn*)all.get(i);
            if (!an.isOp(opAsm))
                continue;
            bool seen = false;
            for (u32 k = (u32)0; k < an.ops().count(); k = k + (u32)1)
                {
                IROperand* ao = (IROperand*)an.ops().get(k);
                if (ao.kind() != (u8)OPK_CPOOL || _dcModule == (IRModule*)0 || ao.cid() >= _dcModule.consts().count())
                    continue;
                Array* bytes = (Array*)_dcModule.consts().get(ao.cid());
                if (bytes == (Array*)0)
                    continue;
                seen = true;
                dcDropAsmNamed(bytes, slots, fn);
                }
            if (!seen)
                return;
            }
        if (slots.count() == (u32)0)
            return;
        Map* slotOf = new Map();
        bool grew = true;
        while (grew)
            {
            grew = false;
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                if (n.res() == (IRValue*)0 || slotOf.get((Hashable*)n.res()) != (Object*)0 || n.ops().count() < (u32)1)
                    continue;
                IROperand* o0 = (IROperand*)n.ops().get((u32)0);
                if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0)
                    continue;
                Object* sl = (Object*)0;
                if (n.isOp(opAddrOf) && slots.contains((Hashable*)o0.val()))
                    sl = (Object*)o0.val();
                else if (n.isOp(opFieldAddr) || n.isOp(opElementAddr))
                    sl = slotOf.get((Hashable*)o0.val());
                if (sl != (Object*)0)
                    {
                    slotOf.set((Hashable*)n.res(), sl);
                    grew = true;
                    }
                }
            }
        if (slotOf.count() == (u32)0)
            return;
        Set* read = new Set();
        Array* stores = new Array();
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)all.get(i);
            bool isAddrOf = n.isOp(opAddrOf);
            bool step = (n.isOp(opFieldAddr) || n.isOp(opElementAddr))
                && n.res() != (IRValue*)0 && slotOf.get((Hashable*)n.res()) != (Object*)0;
            bool store = n.isOp(opStore) && n.ops().count() == 3 && n.memRes() != (IRValue*)0;
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                if (!isAddrOf && slots.contains((Hashable*)o.val()))
                    {
                    read.add((Hashable*)o.val()); // the slot itself, other than by its address
                    continue;
                    }
                Object* sl = slotOf.get((Hashable*)o.val());
                if (sl == (Object*)0 || (k == (u32)0 && (step || store)))
                    continue;
                read.add((Hashable*)sl);
                }
            if (store)
                {
                IROperand* a = (IROperand*)n.ops().get((u32)0);
                if (a.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 && slotOf.get((Hashable*)a.val()) != (Object*)0)
                    stores.add((Object*)n);
                }
            }
        for (u32 i = (u32)0; i < stores.count(); i = i + (u32)1)
            {
            IRInsn* st = (IRInsn*)stores.get(i);
            IROperand* a = (IROperand*)st.ops().get((u32)0);
            if (read.contains((Hashable*)slotOf.get((Hashable*)a.val())))
                continue;
            self.rewriteUsesTo(fn, st.memRes(), (IROperand*)st.ops().get((u32)2));
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                Array* keep = new Array();
                for (u32 m = (u32)0; m < bb.insns().count(); m = m + (u32)1)
                    if ((IRInsn*)bb.insns().get(m) != st)
                        keep.add(bb.insns().get(m));
                bb.setInsns(keep);
                }
            }
        }

    // A Release of a join's phi, where an arm feeding it retained its value
    // (#477): a guarded devirtualisation's inlined arm holds the Retain, the
    // virtual arm returns its result owned, and the Release follows the join.
    // The Release moves into the arms: in an arm whose last effect is the
    // Retain of its incoming value, the two cancel; any other arm releases its
    // own incoming value at its end. Only pure instructions may lie between
    // the join's top and the Release, and each arm must branch only to the
    // join, so on every path the Release still follows exactly the work it
    // followed before.
    final void retainPairsAtJoins(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* J = (IRBlock*)fn.blocks().get(b);
            if (J.phis().count() == (u32)0)
                continue;
            Array* ins = J.insns();
            IRInsn* q = (IRInsn*)0;
            for (u32 i = (u32)0; i < ins.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)ins.get(i);
                if (n.isOp(opRelease))
                    {
                    q = n;
                    break;
                    }
                if (n.memRes() != (IRValue*)0 || !isPureOp(n))
                    break;
                }
            if (q == (IRInsn*)0 || q.ops().count() != (u32)2 || q.memRes() == (IRValue*)0
                || ((IROperand*)q.ops().get((u32)0)).kind() != (u8)OPK_USE
                || ((IROperand*)q.ops().get((u32)1)).kind() != (u8)OPK_USE)
                continue;
            IRValue* pv = ((IROperand*)q.ops().get((u32)0)).val();
            IRInsn* phi = (IRInsn*)0;
            for (u32 i = (u32)0; i < J.phis().count(); i = i + (u32)1)
                if (((IRInsn*)J.phis().get(i)).res() == pv)
                    phi = (IRInsn*)J.phis().get(i);
            if (phi == (IRInsn*)0)
                continue;
            IRValue* qMem = ((IROperand*)q.ops().get((u32)1)).val();
            bool memInJ = false;
            for (u32 i = (u32)0; i < J.phis().count(); i = i + (u32)1)
                if (((IRInsn*)J.phis().get(i)).memRes() == qMem || ((IRInsn*)J.phis().get(i)).res() == qMem)
                    memInJ = true;
            if (memInJ)
                continue;
            // Each incoming arm: it branches to J alone, and the Retain it may
            // end with (the index of it in the arm, or -1).
            Array* arms = new Array();
            Array* vals = new Array();
            Array* rets = new Array();
            bool ok = phi.ops().count() >= (u32)2;
            bool gain = false;
            for (u32 k = (u32)0; ok && k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() == (IRBlock*)0 || vo.kind() != (u8)OPK_USE)
                    {
                    ok = false;
                    break;
                    }
                IRBlock* P = bo.blk();
                IRInsn* t = P.term();
                if (t == (IRInsn*)0 || !t.isOp(opBranch) || arms.contains((Object*)P))
                    {
                    ok = false;
                    break;
                    }
                IRValue* v = vo.val();
                i32 at = (i32)-1;
                Array* pi = P.insns();
                for (u32 m = pi.count(); m > (u32)0; m = m - (u32)1)
                    {
                    IRInsn* n = (IRInsn*)pi.get(m - (u32)1);
                    if (n.isOp(opRetain) && n.ops().count() == (u32)2
                        && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                        && ((IROperand*)n.ops().get((u32)0)).val() == v
                        && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE)
                        {
                        at = (i32)(m - (u32)1);
                        break;
                        }
                    if (n.memRes() != (IRValue*)0 || !isPureOp(n))
                        break;
                    }
                if (at >= (i32)0)
                    gain = true;
                arms.add((Object*)P);
                vals.add((Object*)v);
                rets.add((Object*)Number.with(at));
                }
            if (!ok || !gain)
                continue;
            // The Release's memory result now continues from its memory input.
            self.rewriteUsesTo(fn, q.memRes(), (IROperand*)q.ops().get((u32)1));
            Array* keepJ = new Array();
            for (u32 m = (u32)0; m < ins.count(); m = m + (u32)1)
                if ((IRInsn*)ins.get(m) != q)
                    keepJ.add(ins.get(m));
            J.setInsns(keepJ);
            for (u32 a = (u32)0; a < arms.count(); a = a + (u32)1)
                {
                IRBlock* P = (IRBlock*)arms.get(a);
                i32 at = ((Number*)rets.get(a)).asI32();
                Array* pi = P.insns();
                if (at >= (i32)0)
                    {
                    IRInsn* r = (IRInsn*)pi.get((u32)at);
                    if (r.memRes() != (IRValue*)0)
                        self.rewriteUsesTo(fn, r.memRes(), (IROperand*)r.ops().get((u32)1));
                    pi.removeAt((u32)at);
                    }
                else
                    {
                    IRInsn* rel = IRInsn.withOpOf(q);
                    rel.ops().add((Object*)IROperand.useVal((IRValue*)vals.get(a)));
                    rel.ops().add((Object*)IROperand.useVal(qMem));
                    rel.setMemRes(new IRValue(String.withCString("Mem")));
                    pi.add((Object*)rel);
                    }
                }
            }
        }

    // A Retain and a Release of the same value that cancel, block by block:
    // the Release takes its memory token straight from the Retain and only
    // pure instructions lie between, so nothing can drop the count meanwhile
    // and the Release cannot free what the Retain held. As the reference's
    // retainPairsIn (an Array search retained and released every element
    // around one compare).
    final void retainPairsIn(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            bool again = true;
            while (again)
                {
                again = false;
                Array* ins = bb.insns();
                for (u32 i = (u32)0; i < ins.count() && !again; i = i + (u32)1)
                    {
                    IRInsn* r = (IRInsn*)ins.get(i);
                    if (!r.isOp(opRetain) || r.ops().count() != 2 || r.memRes() == (IRValue*)0
                        || ((IROperand*)r.ops().get((u32)0)).kind() != (u8)OPK_USE)
                        continue;
                    IRValue* rv = ((IROperand*)r.ops().get((u32)0)).val();
                    for (u32 k = i + (u32)1; k < ins.count(); k = k + (u32)1)
                        {
                        IRInsn* q = (IRInsn*)ins.get(k);
                        if (q.isOp(opRelease))
                            {
                            if (q.ops().count() == (u32)2 && q.memRes() != (IRValue*)0
                                && ((IROperand*)q.ops().get((u32)0)).kind() == (u8)OPK_USE
                                && ((IROperand*)q.ops().get((u32)0)).val() == rv
                                && ((IROperand*)q.ops().get((u32)1)).kind() == (u8)OPK_USE
                                && ((IROperand*)q.ops().get((u32)1)).val() == r.memRes())
                                {
                                self.rewriteUsesTo(fn, q.memRes(), (IROperand*)r.ops().get((u32)1));
                                Array* keep = new Array();
                                for (u32 m = (u32)0; m < ins.count(); m = m + (u32)1)
                                    if ((IRInsn*)ins.get(m) != q && (IRInsn*)ins.get(m) != r)
                                        keep.add(ins.get(m));
                                bb.setInsns(keep);
                                again = true;
                                }
                            break;
                            }
                        if (q.memRes() != (IRValue*)0 || !isPureOp(q))
                            break;
                        }
                    }
                }
            }
        }

    final void deadCodeInFunc(IRFunc* fn)
        {
        retainPairsAtJoins(fn);
        retainPairsIn(fn);
        deadStoresIn(fn);
        writeOnlyLocalsIn(fn);
        // Each sweep reads the use counts as they stood when it began. They
        // are built once and then kept: what a sweep removed leaves the
        // counts before the next one (faDropUses), which is what rebuilding
        // them gave.
        bool began = _faFn == (IRFunc*)0;
        if (began)
            self.faBegin(fn, "deadCode");
        bool changed = true;
        while (changed)
            {
            changed = false;
            Map* uses = self.faUseCounts(fn);
            _dcRemoved = new Array();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                if (sweepBlock((IRBlock*)fn.blocks().get(b), uses))
                    changed = true;
            self.faDropUses(fn, _dcRemoved);
            _dcRemoved = (Array*)0;
            }
        if (began)
            self.faEnd();
        }

    final bool sweepBlock(IRBlock* bb, Map* uses)
        {
        bool changed = false;
        Array* keep = new Array();
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.res() != 0 && isPureOp(n) && self.countOf(uses, n.res()) == (u32)0)
                {
                _dcRemoved.add((Object*)n);
                changed = true;
                continue;
                }
            keep.add((Object*)n);
            }
        if (changed)
            bb.setInsns(keep);
        // A phi whose result nobody reads is dead too — a phi never has an
        // effect. A MEMORY phi (no language result) is left alone.
        Array* keepPhis = new Array();
        bool phiChanged = false;
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)bb.phis().get(i);
            if (phi.res() != 0 && phi.memRes() == 0 && self.countOf(uses, phi.res()) == (u32)0)
                {
                _dcRemoved.add((Object*)phi);
                phiChanged = true;
                continue;
                }
            keepPhis.add((Object*)phi);
            }
        if (phiChanged)
            {
            bb.setPhis(keepPhis);
            changed = true;
            }
        return changed;
        }

    // No side effect and no memory result: safe to DROP when the result is
    // unused. This list is NOT if-conversion's — a division may not be
    // SPECULATED (it can trap), but a dead one can certainly be deleted, so
    // Div and Rem are here and not there.
    final bool isPureOp(IRInsn* n)
        {
        if (n.memRes() != 0)
            return false;
        u16 oc = n.opc();
        return IROp.has(oc, OPF_PURE | OPF_TRAPS) || oc == opAggBuild || oc == opAggExtract;
        }
    }
