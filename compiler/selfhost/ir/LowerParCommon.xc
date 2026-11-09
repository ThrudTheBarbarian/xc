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
        if (t.equals(String.withCString("I8"))) base = String.withCString("char");
        else if (t.equals(String.withCString("U8"))) base = String.withCString("uchar");
        else if (t.equals(String.withCString("I16"))) base = String.withCString("short");
        else if (t.equals(String.withCString("U16"))) base = String.withCString("ushort");
        else if (t.equals(String.withCString("I32"))) base = String.withCString("int");
        else if (t.equals(String.withCString("U32"))) base = String.withCString("uint");
        else if (t.equals(String.withCString("I64"))) base = String.withCString("long");
        else if (t.equals(String.withCString("U64"))) base = String.withCString("ulong");
        else if (t.equals(String.withCString("F32"))) base = String.withCString("float");
        else if (t.equals(String.withCString("Bool"))) return String.withCString("bool");
        else return (String*)0; // f64 (refused on Metal, §7), aggregates, vectors
        // Inside a vectorised body every value is a lane vector: uint -> uint2.
        if (_mVecW == (u32)2)
            base.appendCString("2");
        return base;
        }
    final u32 mslWidth(String* t)
        {
        if (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("Bool"))) return (u32)1;
        if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16"))) return (u32)2;
        if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")) || t.equals(String.withCString("F32"))) return (u32)4;
        return (u32)8;
        }
    final bool mslIsPtr(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Ptr("));
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
        if (t == (String*)0 || !t.hasPrefix(String.withCString("Agg("))) return (IRLayout*)0;
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
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("FieldAddr")) || d.ops().count() < (u32)2) return (i64)-1;
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
                        u32 ew = en != (String*)0 ? mslWidth(mslPointee(r.ty())) : (u32)0;
                        u32 total = (u32)0;
                        if (pl != (IRPinned*)0 && pl.ty().hasPrefix(String.withCString("Agg(")))
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
                        bool dbl = r != (IRValue*)0 && mslIsPtr(r.ty()) && self.ptxIs(mslPointee(r.ty()), "F64");
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
            String* op = t.op();
            Array* ss = new Array();
            if (op.equals(String.withCString("Branch")))
                ss.add((Object*)Number.with(sIndexOf(((IROperand*)t.ops().get((u32)0)).blk())));
            else if (op.equals(String.withCString("CondBranch")))
                {
                ss.add((Object*)Number.with(sIndexOf(((IROperand*)t.ops().get((u32)1)).blk())));
                ss.add((Object*)Number.with(sIndexOf(((IROperand*)t.ops().get((u32)2)).blk())));
                }
            else if (!op.equals(String.withCString("Return")))
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
        // Each loop leaves to exactly one block.
        for (u32 h = (u32)0; h < n; h = h + (u32)1)
            {
            if (!sIsHeader(h)) continue;
            i64 exitTo = (i64)-1;
            for (u32 w = (u32)0; w < n; w = w + (u32)1)
                {
                if (!sInLoop((i64)h, w)) continue;
                Array* sw = (Array*)_sSucc.get(w);
                for (u32 q = (u32)0; q < sw.count(); q = q + (u32)1)
                    {
                    u32 v = ((Number*)sw.get(q)).asU32();
                    if (sInLoop((i64)h, v)) continue;
                    if (exitTo >= (i64)0 && exitTo != (i64)v) return false;
                    exitTo = (i64)v;
                    }
                }
            if (exitTo < (i64)0) return false;
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
        u32 w = mslWidth(ft);
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
                if (w != (u32)4 || mslWidth(l.typeAt(k)) != (u32)4 || mslScalar(l.typeAt(k)) == (String*)0
                    || l.typeAt(k).equals(String.withCString("Bool")))
                    return (String*)0;
                mixed = true;
                }
            }
        if (mixed)
            {
            if (ft.equals(String.withCString("Bool")))
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
            return self.mslWidth(t);
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
        return t != (String*)0 && (self.mslScalar(t) != (String*)0 || t.equals(String.withCString("F64")));
        }

    final void parBecause(String* why)
        {
        if (_mWhy == (String*)0)
            _mWhy = why;
        }

    // The reason an instruction could not be printed.
    final String* parWhyFor(IRInsn* ip, bool ptx)
        {
        if (ip.op().equals(String.withCString("Call")) && ip.ops().count() > (u32)0 && ((IROperand*)ip.ops().get((u32)0)).kind() == (u8)OPK_SYM)
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
        if (!ptx && ip.res() != (IRValue*)0 && ip.res().ty().equals(String.withCString("F64")))
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
