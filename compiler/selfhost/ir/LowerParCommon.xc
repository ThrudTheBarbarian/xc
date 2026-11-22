// LowerParCommon.xc — what the GPU kernel printers share: the Metal plan of a kernel's control flow, its values and types.
// One of the files class Lower is split into (2026-11-02), so the split
// build compiles the lowering side by side; Lower.xc says how they layer.


#import "Foundation.xc"
#import <Node>
#import "NodeDefs.xc"
#import <Types>
#import <Vtable>
#import <Ir>
#import "IrDefs.xc"
#import <FloatEncoding>
#import <ParSpirv>
#import "ParSpirvDefs.xc"
#import <ParWgsl>
#import <Overload>
#import "Process.xc"
#import <OptBase>
#import <Opt>
#import "OptDefs.xc"
#import <IrParse>
#import <LowerBase>

    class Lower (ParCommon)
    {

    final String* mslScalar(String* t)
        {
        if (t == (String*)0) return (String*)0;
        String* base = (String*)0;
        if (IRType.is(t, tyI8)) base = String.withCString("char");
        else if (IRType.is(t, tyU8)) base = String.withCString("uchar");
        else if (IRType.is(t, tyI16)) base = String.withCString("short");
        else if (IRType.is(t, tyU16)) base = String.withCString("ushort");
        else if (IRType.is(t, tyI32)) base = String.withCString("int");
        else if (IRType.is(t, tyU32)) base = String.withCString("uint");
        else if (IRType.is(t, tyI64)) base = String.withCString("long");
        else if (IRType.is(t, tyU64)) base = String.withCString("ulong");
        else if (IRType.is(t, tyF32)) base = String.withCString("float");
        else if (IRType.is(t, tyBool)) return String.withCString("bool");
        else return (String*)0; // f64 (refused on Metal, §7), aggregates, vectors
        // Inside a vectorised body every value is a lane vector: uint -> uint2.
        if (_mVecW == (u32)2)
            base.appendCString("2");
        return base;
        }
    // An element's size in a GPU buffer, on every GPU lowering (Metal, SPIR-V,
    // WGSL, PTX): its storage with 8-byte pointers, an aggregate's layout size
    // (#436: the three lowerings each had a helper that answered pointers,
    // aggregates and vectors differently).
    final u32 gpuBytes(String* t)
        {
        IRLayout* l = self.mslLayoutOf(t);
        if (l != (IRLayout*)0)
            return l.size();
        return IRType.storageBytes(t, (u32)8);
        }
    final bool mslIsPtr(String* t)
        {
        return IRType.isPtr(t);
        }
    // `Ptr(X, window)` -> X (X may hold its own parentheses).
    final String* mslPointee(String* t)
        {
        if (!mslIsPtr(t)) return (String*)0;
        u32 depth = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') { if (depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4); depth = depth - (u32)1; }
            else if (c == (u8)',' && depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4);
            }
        return (String*)0;
        }
    // `Agg(n)` -> layout n.
    final IRLayout* mslLayoutOf(String* t)
        {
        if (t == (String*)0 || !IRType.isAgg(t)) return (IRLayout*)0;
        u32 n = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength() && t.byteAt(i) >= (u8)'0' && t.byteAt(i) <= (u8)'9'; i = i + (u32)1)
            n = n * (u32)10 + (u32)(t.byteAt(i) - (u8)'0');
        if (n >= _m.layouts().count()) return (IRLayout*)0;
        return (IRLayout*)_m.layouts().get(n);
        }
    final String* mslKey(IRValue* v) { return String.withU32(v.seq()); }
    final IRInsn* mslDefOf(IROperand* op)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0) return (IRInsn*)0;
        return (IRInsn*)_mDef.get((Hashable*)mslKey(op.val()));
        }
    final String* mslName(IRValue* v)
        {
        if (_mHelper && _mParams != (Map*)0)
            {
            String* pk = (String*)_mParams.get((Hashable*)mslKey(v));
            if (pk != (String*)0)
                {
                String* ps = String.withCString("p");
                ps.append(pk);
                return ps;
                }
            }
        String* s = String.withCString("v");
        String* o = (String*)_mOrd.get((Hashable*)mslKey(v));
        s.append(o != (String*)0 ? o : String.withCString("0"));
        return s;
        }
    final String* mslTypeOf(IROperand* op)
        {
        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0) return op.val().ty();
        return (String*)0;
        }
    // `FieldAddr self, #k` -> k, else -1. `self` is the value the body uses
    // without defining it.
    final i64 mslSelfField(IRInsn* d)
        {
        if (_mHelper)
            return (i64)-1;
        if (d == (IRInsn*)0 || !d.isOp(opFieldAddr) || d.ops().count() < 2) return -1;
        IROperand* b = (IROperand*)d.ops().get((u32)0);
        IROperand* k = (IROperand*)d.ops().get((u32)1);
        if (b.kind() != (u8)OPK_USE || b.val() == (IRValue*)0 || _mDef.get((Hashable*)mslKey(b.val())) != (Object*)0 || k.kind() != (u8)OPK_IMMI)
            return (i64)-1;
        return k.imm();
        }
    // A :constant capture field (the placeholder's `c<field>;` words).
    final bool mslIsConst(i64 k)
        {
        return _mConst != (Map*)0 && _mConst.get((Hashable*)String.withI64(k)) != (Object*)0;
        }
    final String* mslSpaceOfOp(IROperand* op)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0) return (String*)0;
        return (String*)_mSpace.get((Hashable*)mslKey(op.val()));
        }
    final bool mslAnalyse(IRFunc* f)
        {
        if (!_mHelper)
            {
            _mArrOf = new Map();
            _mArrEl = new Map();
            _mArrSkip = new Map();
            _mArrUses = new Map();
            _mArrUsed = new Map();
            }
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                if (ip.res() != (IRValue*)0) _mDef.set((Hashable*)mslKey(ip.res()), (Object*)ip);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0) _mDef.set((Hashable*)mslKey(ip.res()), (Object*)ip);
                }
            }
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                String* op = ip.op();
                IRValue* r = ip.res();
                if (op.equals(String.withCString("FieldAddr")))
                    {
                    i64 k = mslSelfField(ip);
                    if (k >= (i64)0)
                        {
                        if (k >= (i64)_mObj.fieldCount()) { parBecause(String.withCString("it uses an operation its GPU version cannot express yet (IR op FieldAddr)")); return false; }
                        _mSpace.set((Hashable*)mslKey(r), (Object*)String.withCString("thread"));
                        }
                    else if (ip.ops().count() > (u32)0)
                        {
                        String* sp = mslSpaceOfOp((IROperand*)ip.ops().get((u32)0));
                        if (sp != (String*)0) _mSpace.set((Hashable*)mslKey(r), (Object*)sp);
                        }
                    }
                else if (op.equals(String.withCString("Load")))
                    {
                    if (r == (IRValue*)0 || !mslIsPtr(r.ty())) continue;
                    i64 k = mslSelfField(mslDefOf((IROperand*)ip.ops().get((u32)0)));
                    if (k <= (i64)0) { parBecause(String.withCString("it reads a pointer from memory, which its GPU version cannot follow")); return false; }
                    // An array reduction's array (:reduce(op a[])): updated
                    // with 32-bit atomics (mslArrCheck), not a captured array.
                    // As the reference.
                    if (_mArrRed != (Map*)0 && _mArrRed.get((Hashable*)String.withI64(k)) != (Object*)0)
                        {
                        String* pe = mslPointee(r.ty());
                        if (!IRType.is(pe, tyU32) && !IRType.is(pe, tyI32))
                            {
                            String* w = String.withCString("its array reduction (:reduce(op a[])) is over ");
                            w.append(String.withU32(gpuBytes(pe) * (u32)8));
                            w.appendCString("-bit integers, and its GPU version takes 32-bit ones");
                            parBecause(w);
                            return false;
                            }
                        _mArrOf.set((Hashable*)mslKey(r), (Object*)String.withI64(k));
                        _mArrUsed.set((Hashable*)String.withI64(k), (Object*)String.withCString("1"));
                        _mSpace.set((Hashable*)mslKey(r), (Object*)String.withCString("device"));
                        continue;
                        }
                    _mBufs.set((Hashable*)String.withI64(k), (Object*)String.withCString("1"));
                    _mSpace.set((Hashable*)mslKey(r), (Object*)String.withCString(mslIsConst(k) ? "constant" : "device"));
                    _mBufOf.set((Hashable*)mslKey(r), (Object*)String.withI64(k));
                    }
                else if (op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Bitcast")))
                    {
                    if (r != (IRValue*)0 && mslIsPtr(r.ty()) && ip.ops().count() > (u32)0)
                        {
                        String* sp = mslSpaceOfOp((IROperand*)ip.ops().get((u32)0));
                        if (sp != (String*)0) _mSpace.set((Hashable*)mslKey(r), (Object*)sp);
                        }
                    }
                else if (op.equals(String.withCString("Store")))
                    {
                    i64 k = mslSelfField(mslDefOf((IROperand*)ip.ops().get((u32)0)));
                    if (k > (i64)2) _mReds.set((Hashable*)String.withI64(k), (Object*)String.withCString("1"));
                    }
                else if (op.equals(String.withCString("AddrOf")))
                    {
                    // A work item's own array: a pinned frame value of
                    // scalars, a `thread` array in the kernel. Anything else
                    // in the frame stays on the CPU. As the reference.
                    if (ip.ops().count() > (u32)0 && ((IROperand*)ip.ops().get((u32)0)).kind() == (u8)OPK_USE && r != (IRValue*)0)
                        {
                        IRValue* pv = ((IROperand*)ip.ops().get((u32)0)).val();
                        IRPinned* pl = (IRPinned*)0;
                        for (u32 q = (u32)0; q < f.pinned().count(); q = q + (u32)1)
                            if (((IRPinned*)f.pinned().get(q)).val() == pv)
                                pl = (IRPinned*)f.pinned().get(q);
                        String* en = mslIsPtr(r.ty()) ? mslScalar(mslPointee(r.ty())) : (String*)0;
                        u32 ew = en != (String*)0 ? gpuBytes(mslPointee(r.ty())) : (u32)0;
                        u32 total = (u32)0;
                        if (pl != (IRPinned*)0 && IRType.isAgg(pl.ty()))
                            {
                            IRLayout* pll = self.layoutOfAgg(pl.ty());
                            if (pll != (IRLayout*)0)
                                total = pll.size();
                            }
                        if (pl == (IRPinned*)0 || en == (String*)0 || ew == (u32)0 || total == (u32)0 || total % ew != (u32)0)
                            { parBecause(String.withCString("it uses a local value its GPU version cannot place")); return false; }
                        // Numbered in the order first met, as the reference.
                        String* k = (String*)_mLocalIndex.get((Hashable*)mslKey(pv));
                        if (k == (String*)0)
                            {
                            k = String.withU32(_mLocalDecls.count());
                            _mLocalIndex.set((Hashable*)mslKey(pv), (Object*)k);
                            String* d = String.withCString("    thread ");
                            d.append(en); d.appendCString(" loc_"); d.append(k); d.appendCString("[");
                            d.append(String.withU32(total / ew)); d.appendCString("];\n");
                            _mLocalDecls.add((Object*)d);
                            // The PTX, WGSL and SPIR-V printers declare it from these.
                            _mLocalBytes.add((Object*)Number.withU32(total));
                            _mLocalElem.add((Object*)mslPointee(r.ty()));
                            }
                        _mLocalOf.set((Hashable*)mslKey(r), (Object*)k);
                        _mSpace.set((Hashable*)mslKey(r), (Object*)String.withCString("thread"));
                        continue;
                        }
                    // A static-init guard's parts (see _mSinit).
                    if (ip.ops().count() > (u32)0 && ((IROperand*)ip.ops().get((u32)0)).kind() == (u8)OPK_SYM && r != (IRValue*)0)
                        {
                        String* sn = ((IROperand*)ip.ops().get((u32)0)).name();
                        if (sn.hasPrefix(String.withCString("__sinit_")) || sn.hasPrefix(String.withCString("__sdata_")) || sn.hasSuffix(String.withCString("$init")))
                            {
                            _mSinit.set((Hashable*)mslKey(r), (Object*)String.withCString(sn.hasPrefix(String.withCString("__sinit_")) ? "1" : "0"));
                            _mSpace.set((Hashable*)mslKey(r), (Object*)String.withCString("thread"));
                            continue;
                            }
                        }
                    // A data global of scalars (an array, or one value): a
                    // device buffer. Anything else stays on the CPU.
                    if (ip.ops().count() == (u32)0 || ((IROperand*)ip.ops().get((u32)0)).kind() != (u8)OPK_SYM)
                        { parBecause(String.withCString("it uses an operation its GPU version cannot express yet (IR op AddrOf)")); return false; }
                    String* gn = ((IROperand*)ip.ops().get((u32)0)).name();
                    if (_mHelper)
                        {
                        String* w = String.withCString("it uses the global ");
                        w.append(parShown(gn));
                        parBecause(w);
                        return false;
                        }
                    IRSymbol* gs = (IRSymbol*)0;
                    for (u32 q = (u32)0; q < _m.syms().count(); q = q + (u32)1)
                        if (((IRSymbol*)_m.syms().get(q)).name().equals(gn))
                            gs = (IRSymbol*)_m.syms().get(q);
                    // A string: the site a checked build's subscript check
                    // reports (`file:line:col`), or one the body names. Said
                    // as that, not as the literal's internal name. As the
                    // reference.
                    if (gs != (IRSymbol*)0 && gs.kind() == (u8)SYM_STRINGLIT)
                        {
                        parBecause(String.withCString(Lower.isCheckSite(gs.bytes())
                                       ? "it checks its subscripts (a -fbounds-check build), and its GPU version has no checks"
                                       : "it uses a string literal"));
                        return false;
                        }
                    if (gs == (IRSymbol*)0 || gs.kind() != (u8)SYM_DATAGLOBAL || r == (IRValue*)0 || !mslIsPtr(r.ty()) || mslScalar(mslPointee(r.ty())) == (String*)0)
                        {
                        String* w = String.withCString("it uses ");
                        w.append(parShown(gn));
                        bool dbl = r != (IRValue*)0 && mslIsPtr(r.ty()) && IRType.is(mslPointee(r.ty()), tyF64);
                        w.appendCString(dbl ? ", an array of double; the GPU holds arrays of float and integers" : ", which is not a global array of numbers");
                        parBecause(w);
                        return false;
                        }
                    bool have = false;
                    for (u32 q = (u32)0; q < _mGlobals.count(); q = q + (u32)1)
                        if (((String*)_mGlobals.get(q)).equals(gn)) have = true;
                    if (!have) _mGlobals.add((Object*)gn);
                    _mSpace.set((Hashable*)mslKey(r), (Object*)String.withCString("device"));
                    _mGlobalOf.set((Hashable*)mslKey(r), (Object*)gn);
                    }
                }
            }
        // Every pointer value but a phi needs a known space.
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0 && mslIsPtr(ip.res().ty()) && _mSpace.get((Hashable*)mslKey(ip.res())) == (Object*)0)
                    { parBecause(String.withCString("it uses a pointer its GPU version cannot place")); return false; }
                }
            }
        if (!_mHelper && _mArrOf.count() > (u32)0 && !mslArrCheck(f))
            {
            parBecause(String.withCString("its GPU version cannot express its array reduction's updates (a[k] op= x)"));
            return false;
            }
        return true;
        }

    // ── an array reduction in the Metal kernel (:reduce(op a[])) ──────────
    // The body may use the array only as a[k] = a[k] op x: an element
    // address taken from the loaded pointer, a load from it whose one use is
    // op, and a store of op's result (its one use) to the same element. The
    // store prints as one atomic (mslArrStore); the load and op print as
    // nothing. Anything else keeps the block on the CPU. As the reference.

    // The IR operation of an array reduction's operator.
    final String* mslArrOpName(u8 c)
        {
        if (c == (u8)'+') return String.withCString("Add");
        if (c == (u8)'|') return String.withCString("Or");
        if (c == (u8)'&') return String.withCString("And");
        return String.withCString("Xor");
        }
    // The decimal number in s from byte `at`.
    final i64 mslArrNum(String* s, u32 at)
        {
        i64 n = (i64)0;
        for (u32 q = at; q < s.byteLength() && s.byteAt(q) >= (u8)'0' && s.byteAt(q) <= (u8)'9'; q = q + (u32)1)
            n = n * (i64)10 + (i64)(s.byteAt(q) - (u8)'0');
        return n;
        }
    // A value's uses, outside debug records.
    final u32 mslArrUseCount(IRValue* v)
        {
        Object* n = _mArrUses.get((Hashable*)mslKey(v));
        return n != (Object*)0 ? ((Number*)n).asU32() : (u32)0;
        }
    final void mslArrCount(IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return;
        _mArrUses.set((Hashable*)mslKey(o.val()), (Object*)Number.withU32(mslArrUseCount(o.val()) + (u32)1));
        }
    // Two element addresses alike: one value, or the same index from the
    // same loaded pointer.
    final bool mslArrSame(IROperand* p, IROperand* q)
        {
        if (p.kind() != (u8)OPK_USE || q.kind() != (u8)OPK_USE || p.val() == (IRValue*)0 || q.val() == (IRValue*)0)
            return false;
        if (p.val().seq() == q.val().seq())
            return true;
        IRInsn* a = mslDefOf(p);
        IRInsn* b = mslDefOf(q);
        if (a == (IRInsn*)0 || b == (IRInsn*)0 || !a.isOp(opElementAddr) || !b.isOp(opElementAddr)
            || a.ops().count() < (u32)2 || b.ops().count() < (u32)2)
            return false;
        IROperand* a0 = (IROperand*)a.ops().get((u32)0);
        IROperand* b0 = (IROperand*)b.ops().get((u32)0);
        IROperand* a1 = (IROperand*)a.ops().get((u32)1);
        IROperand* b1 = (IROperand*)b.ops().get((u32)1);
        if (a0.kind() != (u8)OPK_USE || b0.kind() != (u8)OPK_USE || a0.val().seq() != b0.val().seq() || a1.kind() != b1.kind())
            return false;
        if (a1.kind() == (u8)OPK_USE)
            return a1.val().seq() == b1.val().seq();
        return a1.kind() == (u8)OPK_IMMI && a1.imm() == b1.imm();
        }
    // A store that is an update a[k] = a[k] op x: the field in _mArrK, the
    // load and op in _mArrLd and _mArrBin, x in _mArrX.
    final bool mslArrMatch(IRInsn* st)
        {
        if (st.ops().count() < (u32)2)
            return false;
        IROperand* a = (IROperand*)st.ops().get((u32)0);
        if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0)
            return false;
        String* ks = (String*)_mArrEl.get((Hashable*)mslKey(a.val()));
        if (ks == (String*)0)
            return false;
        String* w = (String*)_mArrRed.get((Hashable*)ks);
        if (w == (String*)0 || w.byteLength() == (u32)0)
            return false;
        String* want = mslArrOpName(w.byteAt((u32)0));
        IRInsn* b = mslDefOf((IROperand*)st.ops().get((u32)1));
        if (b == (IRInsn*)0 || !b.op().equals(want) || b.ops().count() < (u32)2 || b.res() == (IRValue*)0)
            return false;
        for (u32 side = (u32)0; side < (u32)2; side = side + (u32)1)
            {
            IRInsn* ld = mslDefOf((IROperand*)b.ops().get(side));
            if (ld == (IRInsn*)0 || !ld.isOp(opLoad) || ld.ops().count() < 1 || ld.res() == (IRValue*)0)
                continue;
            if (!mslArrSame((IROperand*)ld.ops().get((u32)0), a))
                continue;
            if (mslArrUseCount(ld.res()) != (u32)1 || mslArrUseCount(b.res()) != (u32)1)
                return false;
            _mArrK = mslArrNum(ks, (u32)0);
            _mArrLd = ld.res();
            _mArrBin = b.res();
            _mArrX = (IROperand*)b.ops().get((u32)1 - side);
            return true;
            }
        return false;
        }
    final bool mslArrCheck(IRFunc* f)
        {
        // The element addresses, and every value's uses.
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                for (u32 q = (u32)0; q < ip.ops().count(); q = q + (u32)1)
                    mslArrCount((IROperand*)ip.ops().get(q));
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.isOp(opDbgValue))
                    continue;
                for (u32 q = (u32)0; q < ip.ops().count(); q = q + (u32)1)
                    mslArrCount((IROperand*)ip.ops().get(q));
                if (ip.isOp(opElementAddr) && ip.res() != (IRValue*)0 && ip.ops().count() > 0)
                    {
                    IROperand* o = (IROperand*)ip.ops().get((u32)0);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && _mArrOf.get((Hashable*)mslKey(o.val())) != (Object*)0)
                        _mArrEl.set((Hashable*)mslKey(ip.res()), _mArrOf.get((Hashable*)mslKey(o.val())));
                    }
                }
            if (bb.term() != (IRInsn*)0)
                for (u32 q = (u32)0; q < bb.term().ops().count(); q = q + (u32)1)
                    mslArrCount((IROperand*)bb.term().ops().get(q));
            }
        // Each use of the array's pointer or of an element address is one
        // the kernel prints: the pointer indexed, an element loaded by an
        // update, an update's store.
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                for (u32 q = (u32)0; q < ip.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)ip.ops().get(q);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0
                        && (_mArrOf.get((Hashable*)mslKey(o.val())) != (Object*)0 || _mArrEl.get((Hashable*)mslKey(o.val())) != (Object*)0))
                        return false;
                    }
                }
            if (bb.term() != (IRInsn*)0)
                for (u32 q = (u32)0; q < bb.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)bb.term().ops().get(q);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0
                        && (_mArrOf.get((Hashable*)mslKey(o.val())) != (Object*)0 || _mArrEl.get((Hashable*)mslKey(o.val())) != (Object*)0))
                        return false;
                    }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                u16 op = ip.opc();
                if (op == opDbgValue)
                    continue;
                if (op == opStore && mslArrMatch(ip))
                    {
                    _mArrSkip.set((Hashable*)mslKey(_mArrLd), (Object*)String.withCString("1"));
                    _mArrSkip.set((Hashable*)mslKey(_mArrBin), (Object*)String.withCString("1"));
                    // The store's value is op's result; its address is the
                    // element's, which needs no check beyond the match.
                    continue;
                    }
                for (u32 q = (u32)0; q < ip.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)ip.ops().get(q);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    bool base = _mArrOf.get((Hashable*)mslKey(o.val())) != (Object*)0;
                    bool elem = _mArrEl.get((Hashable*)mslKey(o.val())) != (Object*)0;
                    if (!base && !elem)
                        continue;
                    if (q == 0 && base && op == opElementAddr)
                        continue;
                    if (q == 0 && elem && op == opLoad)
                        continue;
                    return false;
                    }
                }
            }
        // And every element load is one an update replaces.
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (!ip.isOp(opLoad) || ip.res() == (IRValue*)0 || ip.ops().count() < 1)
                    continue;
                IROperand* o = (IROperand*)ip.ops().get((u32)0);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && _mArrEl.get((Hashable*)mslKey(o.val())) != (Object*)0
                    && _mArrSkip.get((Hashable*)mslKey(ip.res())) == (Object*)0)
                    return false;
                }
            }
        return true;
        }
    final String* sKey(u32 x) { return String.withU32(x); }
    final u32 sIndexOf(IRBlock* b)
        {
        String* ci = (String*)_mBlk.get((Hashable*)b.name());
        u32 v = (u32)0;
        if (ci != (String*)0)
            for (u32 i = (u32)0; i < ci.byteLength(); i = i + (u32)1)
                v = v * (u32)10 + (u32)(ci.byteAt(i) - (u8)'0');
        return v;
        }
    final bool sInLoop(i64 h, u32 w)
        {
        if (h < (i64)0) return false;
        Map* body = (Map*)_sLoop.get((Hashable*)sKey((u32)h));
        return body != (Map*)0 && body.get((Hashable*)sKey(w)) != (Object*)0;
        }
    final bool sIsHeader(u32 x) { return _sLoop.get((Hashable*)sKey(x)) != (Object*)0; }
    final i64 sRpo(u32 x) { return ((Number*)_sRpo.get(x)).asI64(); }
    final bool sPlan(IRFunc* f)
        {
        _sFn = f;
        u32 n = f.blocks().count();
        _sSucc = new Array();
        for (u32 u = (u32)0; u < n; u = u + (u32)1)
            {
            IRInsn* t = ((IRBlock*)f.blocks().get(u)).term();
            if (t == (IRInsn*)0) return false;
            u16 oc = t.opc();
            Array* ss = new Array();
            if (oc == opBranch)
                ss.add((Object*)Number.with(sIndexOf(((IROperand*)t.ops().get((u32)0)).blk())));
            else if (oc == opCondBranch)
                {
                ss.add((Object*)Number.with(sIndexOf(((IROperand*)t.ops().get((u32)1)).blk())));
                ss.add((Object*)Number.with(sIndexOf(((IROperand*)t.ops().get((u32)2)).blk())));
                }
            else if (oc != opReturn)
                return false;
            _sSucc.add((Object*)ss);
            }
        // Reverse postorder by an explicit DFS in successor order.
        Array* rpo = new Array();
        Array* state = new Array();
        for (u32 u = (u32)0; u < n; u = u + (u32)1) state.add((Object*)Number.with((u32)0));
        Array* stU = new Array();
        Array* stK = new Array();
        stU.add((Object*)Number.with((u32)0)); stK.add((Object*)Number.with((u32)0));
        state.set((u32)0, (Object*)Number.with((u32)1));
        while (stU.count() > (u32)0)
            {
            u32 top = stU.count() - (u32)1;
            u32 u = ((Number*)stU.get(top)).asU32();
            u32 k = ((Number*)stK.get(top)).asU32();
            Array* su = (Array*)_sSucc.get(u);
            if (k < su.count())
                {
                stK.set(top, (Object*)Number.with(k + (u32)1));
                u32 v = ((Number*)su.get(k)).asU32();
                if (((Number*)state.get(v)).asU32() == (u32)0)
                    {
                    state.set(v, (Object*)Number.with((u32)1));
                    stU.add((Object*)Number.with(v)); stK.add((Object*)Number.with((u32)0));
                    }
                continue;
                }
            state.set(u, (Object*)Number.with((u32)2));
            rpo.insert((u32)0, (Object*)Number.with(u));
            stU.removeAt(top); stK.removeAt(top);
            }
        _sRpo = new Array();
        for (u32 u = (u32)0; u < n; u = u + (u32)1) _sRpo.add((Object*)Number.with((i64)-1));
        for (u32 i = (u32)0; i < rpo.count(); i = i + (u32)1)
            _sRpo.set(((Number*)rpo.get(i)).asU32(), (Object*)Number.with((i64)i));
        // Back edges name the loop headers; a header's loop is every block that
        // reaches a back-edge source without passing the header.
        _sFwd = new Array();
        for (u32 u = (u32)0; u < n; u = u + (u32)1) _sFwd.add((Object*)Number.with((u32)0));
        _sLoop = new Map();
        _sExit = new Map();
        for (u32 u = (u32)0; u < n; u = u + (u32)1)
            {
            if (sRpo(u) < (i64)0) continue;
            Array* su = (Array*)_sSucc.get(u);
            for (u32 q = (u32)0; q < su.count(); q = q + (u32)1)
                {
                u32 v = ((Number*)su.get(q)).asU32();
                if (sRpo(v) > sRpo(u))
                    {
                    _sFwd.set(v, (Object*)Number.with(((Number*)_sFwd.get(v)).asU32() + (u32)1));
                    continue;
                    }
                Map* body = (Map*)_sLoop.get((Hashable*)sKey(v));
                if (body == (Map*)0)
                    {
                    body = new Map();
                    body.set((Hashable*)sKey(v), (Object*)sKey(v));
                    _sLoop.set((Hashable*)sKey(v), (Object*)body);
                    }
                Array* work = new Array();
                work.add((Object*)Number.with(u));
                while (work.count() > (u32)0)
                    {
                    u32 w = ((Number*)work.get(work.count() - (u32)1)).asU32();
                    work.removeAt(work.count() - (u32)1);
                    if (body.get((Hashable*)sKey(w)) != (Object*)0) continue;
                    body.set((Hashable*)sKey(w), (Object*)sKey(w));
                    for (u32 p = (u32)0; p < n; p = p + (u32)1)
                        {
                        Array* sp = (Array*)_sSucc.get(p);
                        for (u32 r = (u32)0; r < sp.count(); r = r + (u32)1)
                            if (((Number*)sp.get(r)).asU32() == w && sRpo(p) >= (i64)0)
                                work.add((Object*)Number.with(p));
                        }
                    }
                }
            }
        // Each loop leaves to one block. A loop that leaves to more than one
        // fits when each of the others only passes control on to that block
        // (one way in, an unconditional branch out), as the edge a `break`
        // takes does: those blocks join the loop, and their branch out is
        // printed as its `break`.
        for (u32 h = (u32)0; h < n; h = h + (u32)1)
            {
            if (!sIsHeader(h)) continue;
            Map* body = (Map*)_sLoop.get((Hashable*)sKey(h));
            Array* outs = new Array();
            for (u32 w = (u32)0; w < n; w = w + (u32)1)
                {
                if (!sInLoop((i64)h, w)) continue;
                Array* sw = (Array*)_sSucc.get(w);
                for (u32 q = (u32)0; q < sw.count(); q = q + (u32)1)
                    {
                    u32 v = ((Number*)sw.get(q)).asU32();
                    if (sInLoop((i64)h, v)) continue;
                    bool seen = false;
                    for (u32 k = (u32)0; k < outs.count(); k = k + (u32)1)
                        if (((Number*)outs.get(k)).asU32() == v) seen = true;
                    if (!seen) outs.add((Object*)Number.with(v));
                    }
                }
            if (outs.count() == (u32)0) return false;
            i64 exitTo = (i64)-1;
            if (outs.count() == (u32)1)
                exitTo = (i64)((Number*)outs.get((u32)0)).asU32();
            else
                {
                Array* pass = new Array();
                for (u32 k = (u32)0; k < outs.count(); k = k + (u32)1)
                    {
                    u32 x = ((Number*)outs.get(k)).asU32();
                    for (u32 g = (u32)0; g < n; g = g + (u32)1)
                        {
                        Array* sx = (Array*)_sSucc.get(x);
                        if (sIsHeader(x) || ((Number*)_sFwd.get(x)).asU32() != (u32)1
                            || sInLoop((i64)h, x) || sx.count() != (u32)1)
                            break;
                        pass.add((Object*)Number.with(x));
                        x = ((Number*)sx.get((u32)0)).asU32();
                        }
                    if (exitTo >= (i64)0 && exitTo != (i64)x) return false;
                    exitTo = (i64)x;
                    }
                for (u32 k = (u32)0; k < pass.count(); k = k + (u32)1)
                    {
                    String* pk = sKey(((Number*)pass.get(k)).asU32());
                    body.set((Hashable*)pk, (Object*)pk);
                    }
                }
            _sExit.set((Hashable*)sKey(h), (Object*)Number.with(exitTo));
            }
        // Immediate post-dominators, to a virtual exit (n) after every Return.
        _sIpdom = new Array();
        for (u32 u = (u32)0; u <= n; u = u + (u32)1) _sIpdom.add((Object*)Number.with((i64)-1));
        _sIpdom.set(n, (Object*)Number.with((i64)n));
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (i64 i = (i64)rpo.count() - (i64)1; i >= (i64)0; i = i - (i64)1)
                {
                u32 u = ((Number*)rpo.get((u32)i)).asU32();
                Array* su = (Array*)_sSucc.get(u);
                Array* ss = su;
                if (su.count() == (u32)0) { ss = new Array(); ss.add((Object*)Number.with(n)); }
                i64 best = (i64)-1;
                for (u32 q = (u32)0; q < ss.count(); q = q + (u32)1)
                    {
                    u32 sv = ((Number*)ss.get(q)).asU32();
                    if (((Number*)_sIpdom.get(sv)).asI64() < (i64)0) continue;
                    if (best < (i64)0) best = (i64)sv;
                    else best = (i64)sPdomMeet((u32)best, sv, n);
                    }
                if (best >= (i64)0 && ((Number*)_sIpdom.get(u)).asI64() != best)
                    {
                    _sIpdom.set(u, (Object*)Number.with(best));
                    changed = true;
                    }
                }
            }
        return true;
        }
    final u32 sPdomMeet(u32 a, u32 b, u32 n)
        {
        Map* up = new Map();
        u32 x = a;
        for (u32 g = (u32)0; g <= n + (u32)1; g = g + (u32)1)
            {
            up.set((Hashable*)sKey(x), (Object*)sKey(x));
            i64 nx = ((Number*)_sIpdom.get(x)).asI64();
            if (x == n || nx < (i64)0) break;
            x = (u32)nx;
            }
        x = b;
        for (u32 g = (u32)0; g <= n + (u32)1; g = g + (u32)1)
            {
            if (up.get((Hashable*)sKey(x)) != (Object*)0) return x;
            i64 nx = ((Number*)_sIpdom.get(x)).asI64();
            if (x == n || nx < (i64)0) break;
            x = (u32)nx;
            }
        return n;
        }

    // A struct type whose fields are all one number type, packed: that
    // type (U32 for a struct of mixed 4-byte numbers), else 0.
    final String* parFlatField(String* t)
        {
        IRLayout* l = mslLayoutOf(t);
        if (l == (IRLayout*)0 || l.fieldCount() == (u32)0)
            return (String*)0;
        String* ft = l.typeAt((u32)0);
        u32 w = gpuBytes(ft);
        if (mslScalar(ft) == (String*)0 || w == (u32)0 || l.size() != w * l.fieldCount())
            return (String*)0;
        bool mixed = false;
        for (u32 k = (u32)0; k < l.fieldCount(); k = k + (u32)1)
            {
            if (l.offsetAt(k) != w * k)
                return (String*)0;
            if (!l.typeAt(k).equals(ft))
                {
                // A struct mixing 4-byte numbers (int id; float m) is an array
                // of 32-bit words to a kernel; each field that is not a U32
                // is reinterpreted where it is read or written (see
                // parWordStructs).
                if (w != (u32)4 || gpuBytes(l.typeAt(k)) != (u32)4 || mslScalar(l.typeAt(k)) == (String*)0
                    || IRType.is(l.typeAt(k), tyBool))
                    return (String*)0;
                mixed = true;
                }
            }
        if (mixed)
            {
            if (IRType.is(ft, tyBool))
                return (String*)0;
            return String.withCString("U32");
            }
        return ft;
        }

    // The word a kernel holds an array of structs of type t in
    // (parWordStructs): the struct's number type (parFlatField), else an
    // unsigned word as wide as its widest field, up to 32 bits. 0 when a
    // field is not a number (a pointer, an object) or t is not a struct.
    final String* parWordOf(String* t)
        {
        String* fe = self.parFlatField(t);
        if (fe != (String*)0)
            return fe;
        IRLayout* l = self.mslLayoutOf(t);
        if (l == (IRLayout*)0 || l.isArray() || l.fieldCount() == (u32)0)
            return (String*)0;
        u32 mw = self.parLeafWidth(t, (u32)0);
        if (mw == (u32)0)
            return (String*)0;
        u32 w = mw > (u32)4 ? (u32)4 : mw;
        if (l.size() % w != (u32)0)
            return (String*)0;
        return String.withCString(w == (u32)4 ? "U32" : w == (u32)2 ? "U16" : "U8");
        }

    // The widest number in t (a number, or a struct or array of them), 0
    // when it holds anything else.
    final u32 parLeafWidth(String* t, u32 depth)
        {
        if (t == (String*)0 || depth > (u32)8)
            return (u32)0;
        if (self.parLeaf(t))
            return self.gpuBytes(t);
        IRLayout* l = self.mslLayoutOf(t);
        if (l == (IRLayout*)0 || l.fieldCount() == (u32)0)
            return (u32)0;
        if (l.isArray())
            return self.parLeafWidth(l.elemType(), depth + (u32)1);
        u32 mw = (u32)0;
        for (u32 k = (u32)0; k < l.fieldCount(); k = k + (u32)1)
            {
            u32 w = self.parLeafWidth(l.typeAt(k), depth + (u32)1);
            if (w == (u32)0)
                return (u32)0;
            if (w > mw)
                mw = w;
            }
        return mw;
        }

    // A number a struct's field may hold in a kernel's words.
    final bool parLeaf(String* t)
        {
        return t != (String*)0 && (self.mslScalar(t) != (String*)0 || IRType.is(t, tyF64));
        }

    final void parBecause(String* why)
        {
        if (_mWhy == (String*)0)
            _mWhy = why;
        }

    // The reason an instruction could not be printed.
    final String* parWhyFor(IRInsn* ip, bool ptx)
        {
        if (ip.isOp(opCall) && ip.ops().count() > 0 && ((IROperand*)ip.ops().get(0)).kind() == OPK_SYM)
            {
            String* callee = ((IROperand*)ip.ops().get((u32)0)).name();
            String* m = self.ptxMathName(callee);
            bool tr = m.equals(self.ptxS("sin")) || m.equals(self.ptxS("cos")) || m.equals(self.ptxS("exp")) || m.equals(self.ptxS("ln")) || m.equals(self.ptxS("log")) || m.equals(self.ptxS("pow"));
            if (ptx && tr)
                {
                String* w = String.withCString("it calls ");
                w.append(parShown(callee));
                w.appendCString(_mFast ? " on a double, which this GPU has in a fast form only for float" : ", which this GPU has only in an approximate form, and the block's goal is accuracy");
                return w;
                }
            return parCallFailed(callee, (String*)0);
            }
        if (!ptx && ip.res() != (IRValue*)0 && IRType.is(ip.res().ty(), tyF64))
            return String.withCString("it uses double, which Apple GPUs do not have");
        // Named, so the warning says what to change (astronomancy, 2026-10-24). As the reference.
        String* w = String.withCString("it uses an operation its GPU version cannot express yet (IR op ");
        w.append(ip.op());
        w.appendCString(")");
        return w;
        }

    // A call that could not be printed: the helper's own reason, when there is one.
    final String* parCallFailed(String* callee, String* helperWhy)
        {
        String* w = String.withCString("it calls ");
        w.append(parShown(callee));
        w.appendCString(", which cannot run on the GPU");
        if (helperWhy != (String*)0)
            {
            w.appendCString(" (");
            w.append(helperWhy);
            w.appendCString(")");
            }
        return w;
        }

    // Whether an address is a static-init flag (see _mSinit).
    final bool parSinitFlag(IROperand* op)
        {
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0) return false;
        String* k = (String*)_mSinit.get((Hashable*)mslKey(op.val()));
        return k != (String*)0 && k.equals(String.withCString("1"));
        }

    final String* parShown(String* n)
        {
        // A capture renamed for the block's own names (`__par_lo`) is shown
        // as the source spells it. As the reference.
        if (n.hasPrefix(String.withCString("__par_")) && n.byteLength() > (u32)6)
            n = n.substringFromByte((u32)6);
        String* out = String.withCString("");
        for (u32 i = (u32)0; i < n.byteLength(); i = i + (u32)1)
            {
            u8 c = n.byteAt(i);
            if (i > (u32)0 && c == (u8)'_' && i + (u32)1 < n.byteLength() && n.byteAt(i + (u32)1) == (u8)'_')
                break;
            out.appendByte(c == (u8)'$' ? (u8)'.' : c);
            }
        return out;
        }
    }
