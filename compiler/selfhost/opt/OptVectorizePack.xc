// OptVectorizePack.xc — maps over 16-bit float arrays (float sizes P1): FloatPack's conversions in lanes (src/xtc/ir/XTIROptVectorize.m).
// One of the files class Opt is split into, so the split build compiles the
// optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptVectorizeParts>
#import <OptVectorizeShapes>

    class Opt (VectorizePack)
    {

    // (vecConstSplat and vecPut1 live here so the pack map's builders can
    // reach them; vecApplyMap and its kin use them too.)
    final IROperand* vecConstSplat(IRBlock* entry, String* lane, IROperand* imm, VecCand* c)
        {
        String* ck = String.withCString("k");
        ck.append(lane);
        ck.appendCString(":");
        if (imm.kind() == (u8)OPK_IMMF)
            ck.append(imm.fpHex());
        else
            ck.appendFormat("%lld", imm.imm());
        Object* hit = _vecEntryCache.get((Hashable*)ck);
        if (hit != (Object*)0)
            return IROperand.useVal((IRValue*)hit);
        IRValue* cst = new IRValue(lane);
        IRInsn* ci = IRInsn.with(String.withCString("Const"));
        ci.setRes(cst);
        ci.add(imm);
        entry.insns().add((Object*)ci);
        IRValue* sp = new IRValue(self.vecTyOf(lane, c.vecBytes()));
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(sp);
        s.add(IROperand.useVal(cst));
        entry.insns().add((Object*)s);
        _vecEntryCache.set((Hashable*)ck, (Object*)sp);
        return IROperand.useVal(sp);
        }

    final IRValue* vecPut1(string op, String* ty, IROperand* a, IROperand* b, IRInsn* dbg)
        {
        IRValue* r = new IRValue(ty);
        IRInsn* n = IRInsn.with(String.withCString(op));
        n.copyDbg(dbg);
        n.setRes(r);
        n.add(a);
        if (b != (IROperand*)0)
            n.add(b);
        _vecBody.add((Object*)n);
        return r;
        }

    // A FloatPack call a pack map converts in lanes: 1 for the unpack of a
    // 16-bit float to f32, 2 for the f32 pack to one, plus 4 for bf16 (e8m7;
    // else f16, e5m10); 0 for anything else. As the reference's xtvPackCall.
    final u32 vecPackCall(IRInsn* n, Map* defOf)
        {
        if (!n.isOp(opCall) || n.res() == (IRValue*)0 || n.ops().count() != (u32)5)
            return (u32)0;
        IROperand* c = (IROperand*)n.ops().get((u32)0);
        IROperand* a = (IROperand*)n.ops().get((u32)1);
        if (c.kind() != (u8)OPK_SYM || c.name() == (String*)0 || a.kind() != (u8)OPK_USE)
            return (u32)0;
        u32 k = (u32)0;
        if (c.name().equals(String.withCString("_xt_fpk_unpack")))
            k = (u32)1;
        else if (c.name().equals(String.withCString("_xt_fpk_pack_f32")))
            k = (u32)2;
        if (k == (u32)0)
            return (u32)0;
        i64 e = (i64)0;
        i64 m = (i64)0;
        if (!self.vecConstWide((IROperand*)n.ops().get((u32)2), defOf, &e)
            || !self.vecConstWide((IROperand*)n.ops().get((u32)3), defOf, &m))
            return (u32)0;
        u32 bf = (u32)0;
        if (e == (i64)5 && m == (i64)10)
            bf = (u32)0;
        else if (e == (i64)8 && m == (i64)7)
            bf = (u32)4;
        else
            return (u32)0;
        if (k == (u32)1 && !IRType.is(n.res().ty(), tyF32))
            return (u32)0;
        if (k == (u32)2 && !IRType.is(n.res().ty(), tyU16))
            return (u32)0;
        return k + bf;
        }

    // Can fn's loops convert 16-bit floats in lanes? Where pack-native makes
    // the scalar conversions native: every arm64 row, and on x86 the F16C
    // levels (an avx2 or avx512 copy, or a fixed -mavx2 build). Not at 64
    // bytes: the half vectors would be ymm16-31, which the assemblers do not
    // name. As the reference's xtvPackLanes.
    final bool vecPackLanes(IRFunc* fn)
        {
        String* lvl = fn.simdLevel();
        bool hw = _profile.packF16Hw()
                  || (lvl != (String*)0 && (lvl.equals(String.withCString("avx2")) || lvl.equals(String.withCString("avx512"))));
        return hw && _profile.packBf16() && _profile.escapeVec() && self.vectorBytes() <= (u32)32;
        }

    // Does fn's code have FEAT_FP16 arithmetic (pack-native's arith)?
    final bool vecHalfArith(IRFunc* fn)
        {
        String* lvl = fn.simdLevel();
        return _profile.packF16Arith() || (lvl != (String*)0 && lvl.equals(String.withCString("fp16")));
        }

    static bool vecHalfOpc(u16 op)
        {
        return op == opFAdd || op == opFSub || op == opFMul || op == opFDiv;
        }

    // Uses of v in fn, counted.
    final u32 vecUsesOf(IRFunc* fn, IRValue* v)
        {
        u32 k = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                k = k + self.vecReads((IRInsn*)bb.phis().get(i), v);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                k = k + self.vecReads((IRInsn*)bb.insns().get(i), v);
            if (bb.term() != (IRInsn*)0)
                k = k + self.vecReads(bb.term(), v);
            }
        return k;
        }

    final u32 vecReads(IRInsn* n, IRValue* v)
        {
        u32 k = (u32)0;
        for (u32 j = (u32)0; j < n.ops().count(); j = j + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(j);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                k = k + (u32)1;
            }
        return k;
        }

    // The f32 operations of a pack map that become f16 ones where the code
    // has FEAT_FP16, as pack-native fuses them: + - * / of two f16 unpacks
    // (sqrt of one), read by an f16 pack alone. A set of their results;
    // _vrPackPure says the body is those, the unpacks they read, the packs of
    // them and 16-bit loads and stores and nothing else. As the reference's
    // xtvHalfFused.
    final Map* vecHalfFused(IRFunc* fn, IRBlock* B, Map* defOf)
        {
        Map* fused = new Map();
        bool p = true;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            u32 pk = self.vecPackCall(n, defOf);
            if (pk > (u32)4)
                p = false;
            if (pk != (u32)2)
                continue;
            Object* dobj = defOf.get((Hashable*)((IROperand*)n.ops().get((u32)1)).val());
            if (dobj == (Object*)0)
                continue;
            IRInsn* d = (IRInsn*)dobj;
            u32 ar = Opt.vecHalfOpc(d.opc()) ? (u32)2 : d.isOp(opFSqrt) ? (u32)1 : (u32)0;
            bool ok = ar != (u32)0 && d.ops().count() == ar && self.vecUsesOf(fn, d.res()) == (u32)1
                      && vecHasInsn(B.insns(), d);
            for (u32 k = (u32)0; ok && k < ar; k = k + (u32)1)
                {
                IROperand* o = (IROperand*)d.ops().get(k);
                Object* u = o.kind() == (u8)OPK_USE ? defOf.get((Hashable*)o.val()) : (Object*)0;
                if (u == (Object*)0 || self.vecPackCall((IRInsn*)u, defOf) != (u32)1)
                    ok = false;
                }
            if (ok)
                fused.set((Hashable*)d.res(), (Object*)d.res());
            }
        // Pure: each unpack read only by fused operations, each operation
        // fused, each load and store 16-bit.
        for (u32 i = (u32)0; i < B.insns().count() && p; i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            u16 op = n.opc();
            u32 pk = self.vecPackCall(n, defOf);
            if (pk % (u32)4 == (u32)1)
                {
                u32 seen = (u32)0;
                for (u32 j = (u32)0; j < B.insns().count(); j = j + (u32)1)
                    {
                    IRInsn* m = (IRInsn*)B.insns().get(j);
                    if (m.res() != (IRValue*)0 && fused.get((Hashable*)m.res()) != (Object*)0)
                        seen = seen + self.vecReads(m, n.res());
                    }
                if (seen != self.vecUsesOf(fn, n.res()))
                    p = false;
                }
            else if (op == opLoad)
                p = IRType.is(n.res().ty(), tyU16);
            else if (op == opStore)
                p = IRType.is(Opt.vecOperandTy((IROperand*)n.ops().get((u32)1)), tyU16);
            else if (n.res() != (IRValue*)0 && pk == (u32)0 && op != opConst && op != opAddrOf && op != opElementAddr
                     && op != opAdd && op != opZExt && op != opSExt && op != opTrunc)
                p = fused.get((Hashable*)n.res()) != (Object*)0;
            }
        _vrPackPure = p;
        return fused;
        }

    static bool vecHasInsn(Array* a, IRInsn* n)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRInsn*)a.get(i) == n)
                return true;
        return false;
        }

    // A pack map's body, classified as vecClassifyBody does an ordinary
    // map's: the lane type (32-bit; F32 when no 32-bit array is read), or 0
    // to refuse. A 16-bit float (in _vrHalf) is loaded, stored, unpacked and
    // packed and nothing else. Sets _vrOverlap and _vrMixed. As the
    // reference's recogniser in pack mode.
    final String* vecClassifyPack(IRBlock* B, IRValue* iv, IRInsn* ivNext, Map* defOf, Map* defBlk)
        {
        String* laneTy = (String*)0;
        bool sawLoad = false;
        bool sawStore = false;
        bool wantIota = _profile != (OptProfile*)0 && _profile.iota();
        bool ivLaneOK = IRType.is(iv.ty(), tyI32) || IRType.is(iv.ty(), tyU32);
        Array* elems = new Array();
        if (wantIota && ivLaneOK)
            elems.add((Object*)iv);
        Map* half = new Map();
        u32 packCalls = (u32)0;
        Array* stSized = new Array();
        Array* ldSized = new Array();
        IRBlock* H = (IRBlock*)defBlk.get((Hashable*)iv);
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == ivNext)
                continue;
            u16 op = n.opc();
            if (op == opAddrOf)
                continue;
            if (op == opElementAddr)
                {
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                IROperand* idx = (IROperand*)n.ops().get((u32)1);
                if (idx.kind() != (u8)OPK_USE || idx.val() != iv)
                    return (String*)0;
                IROperand* base = (IROperand*)n.ops().get((u32)0);
                if (base.kind() == (u8)OPK_USE)
                    {
                    Object* db = defBlk.get((Hashable*)base.val());
                    if (db != (Object*)0 && (IRBlock*)db == B)
                        {
                        Object* bd = defOf.get((Hashable*)base.val());
                        if (bd == (Object*)0 || !((IRInsn*)bd).isOp(opAddrOf))
                            return (String*)0;
                        }
                    }
                continue;
                }
            if (op == opLoad)
                {
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (String*)0;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                String* lt = n.res().ty();
                if (!self.vecLaneOK(lt))
                    return (String*)0;
                IROperand* lb = self.vecElemBase((IROperand*)n.ops().get((u32)0), defOf);
                if (IRType.is(lt, tyU16))
                    {
                    half.set((Hashable*)n.res(), (Object*)n.res());
                    elems.add((Object*)n.res());
                    sawLoad = true;
                    ldSized.add((Object*)Opt.vecSized(lb, (u32)2));
                    continue;
                    }
                if (IRType.bytes(lt) != (u32)4)
                    return (String*)0;
                ldSized.add((Object*)Opt.vecSized(lb, (u32)4));
                if (laneTy != (String*)0 && !laneTy.equals(lt) && !self.vecLanesMix(laneTy, lt))
                    return (String*)0;
                if (laneTy == (String*)0)
                    laneTy = lt;
                sawLoad = true;
                elems.add((Object*)n.res());
                continue;
                }
            if (op == opStore)
                {
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                IROperand* sv = (IROperand*)n.ops().get((u32)1);
                if (!vecMapOperandOK(sv, elems, B, H, defOf, defBlk))
                    return (String*)0;
                // The iv as a stored value: an iota map, which a pack map is not.
                if (Opt.vecIsIvUse(sv, iv))
                    return (String*)0;
                String* sty = Opt.vecOperandTy(sv);
                bool isHalf = sv.kind() == (u8)OPK_USE && half.get((Hashable*)sv.val()) != (Object*)0;
                if (sty != (String*)0 && IRType.is(sty, tyU16) ? !isHalf
                                                             : (isHalf || sty == (String*)0 || IRType.bytes(sty) != (u32)4))
                    return (String*)0;
                stSized.add((Object*)Opt.vecSized(self.vecElemBase((IROperand*)n.ops().get((u32)0), defOf),
                                                  isHalf ? (u32)2 : (u32)4));
                sawStore = true;
                continue;
                }
            if (op == opConst || op == opZExt || op == opSExt || op == opTrunc)
                continue;
            u32 pk = self.vecPackCall(n, defOf);
            if (pk != (u32)0)
                {
                IROperand* a = (IROperand*)n.ops().get((u32)1);
                bool isHalf = half.get((Hashable*)a.val()) != (Object*)0;
                packCalls = packCalls + (u32)1;
                if ((pk % (u32)4 == (u32)1) != isHalf || !hasValue(elems, a.val()) || packCalls > (u32)12
                    || (pk % (u32)4 == (u32)2 && !IRType.is(Opt.vecOperandTy(a), tyF32)))
                    return (String*)0;
                if (pk % (u32)4 == (u32)2)
                    half.set((Hashable*)n.res(), (Object*)n.res());
                elems.add((Object*)n.res());
                continue;
                }
            bool fdiv = op == opFDiv;
            bool fsq = op == opFSqrt;
            if (fdiv || fsq || vecElementwise(op))
                {
                u32 ar = fsq ? (u32)1 : (u32)2;
                bool fine = n.res() != (IRValue*)0 && n.ops().count() == ar && self.vecLaneOK(n.res().ty())
                            && ((!fdiv && !fsq) || IRType.is(n.res().ty(), tyF32));
                for (u32 k = (u32)0; fine && k < ar; k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (!vecMapOperandOK(o, elems, B, H, defOf, defBlk)
                        || (o.kind() == (u8)OPK_USE && half.get((Hashable*)o.val()) != (Object*)0)
                        || (o.kind() == (u8)OPK_USE && o.val() == iv))
                        fine = false;
                    }
                if (!fine)
                    return (String*)0;
                elems.add((Object*)n.res());
                continue;
                }
            return (String*)0;
            }
        if (packCalls == (u32)0)
            return (String*)0;
        if (laneTy == (String*)0)
            laneTy = String.withCString("F32");
        if (!sawLoad || !sawStore)
            return (String*)0;
        if (!self.vecPackBases(stSized, ldSized, B, defOf, defBlk))
            return (String*)0;
        return laneTy;
        }

    // A base and its element size, as one entry of the sized lists.
    static Array* vecSized(IROperand* base, u32 size)
        {
        Array* e = new Array();
        e.add((Object*)base);
        e.add((Object*)Number.withU32(size));
        return e;
        }

    static u32 vecSizeOf(Array* e)
        {
        return ((Number*)e.get((u32)1)).asU32();
        }

    // Bases of one element size as any map's (vecBasesApart); of two sizes,
    // apart when both are objects of known identity and not the same one,
    // else checked in the preheader over the whole vector range
    // (vecMixedGuard): the two advance at different rates, so no distance is
    // safe. A store pairs with every load and with every store of the other
    // size.
    final bool vecPackBases(Array* stSized, Array* ldSized, IRBlock* B, Map* defOf, Map* defBlk)
        {
        Array* overlap = new Array();
        for (u32 w = (u32)2; w <= (u32)4; w = w + (u32)2)
            {
            Array* sb = new Array();
            Array* lb = new Array();
            for (u32 i = (u32)0; i < stSized.count(); i = i + (u32)1)
                if (Opt.vecSizeOf((Array*)stSized.get(i)) == w)
                    sb.add(((Array*)stSized.get(i)).get((u32)0));
            for (u32 i = (u32)0; i < ldSized.count(); i = i + (u32)1)
                if (Opt.vecSizeOf((Array*)ldSized.get(i)) == w)
                    lb.add(((Array*)ldSized.get(i)).get((u32)0));
            if (!self.vecBasesApart(sb, lb, B, defOf, defBlk))
                return false;
            for (u32 i = (u32)0; i < _vrOverlap.count(); i = i + (u32)1)
                overlap.add(_vrOverlap.get(i));
            }
        _vrOverlap = overlap;
        _vrMixed = new Array();
        Array* others = new Array();
        for (u32 i = (u32)0; i < ldSized.count(); i = i + (u32)1)
            others.add(ldSized.get(i));
        for (u32 i = (u32)0; i < stSized.count(); i = i + (u32)1)
            others.add(stSized.get(i));
        for (u32 i = (u32)0; i < stSized.count(); i = i + (u32)1)
            {
            Array* st = (Array*)stSized.get(i);
            for (u32 j = (u32)0; j < others.count(); j = j + (u32)1)
                {
                Array* ot = (Array*)others.get(j);
                if (Opt.vecSizeOf(st) == Opt.vecSizeOf(ot))
                    continue;
                IROperand* a = (IROperand*)st.get((u32)0);
                IROperand* b = (IROperand*)ot.get((u32)0);
                Object* oa = self.vecBaseObject(a, defOf);
                Object* ob = self.vecBaseObject(b, defOf);
                if (oa != (Object*)0 && ob != (Object*)0)
                    {
                    if (Opt.vecSameObject(oa, ob))
                        return false;
                    continue;
                    }
                if (a.kind() != (u8)OPK_USE || b.kind() != (u8)OPK_USE
                    || (IRBlock*)defBlk.get((Hashable*)a.val()) == B || (IRBlock*)defBlk.get((Hashable*)b.val()) == B)
                    return false;
                Array* pr = new Array();
                pr.add((Object*)st);
                pr.add((Object*)ot);
                _vrMixed.add((Object*)pr);
                }
            }
        return true;
        }

    // Two base objects (vecBaseObject's: a global's name, or a frame slot or
    // allocation's value) are the same one.
    static bool vecSameObject(Object* a, Object* b)
        {
        if (a == b)
            return true;
        return a.className().equals(b.className()) && a.equals(b);
        }

    // The vector limit again, for a pack map's bases of different element
    // sizes: where the bytes the vector loop stores through one base meet the
    // bytes it reads or stores through the other, the limit is the start and
    // the scalar clone takes the whole range. As the reference's
    // xtvEmitMixedGuard.
    final IRValue* vecMixedGuard(VecCand* c, IRBlock* PH, IRValue* lim)
        {
        String* ivTy = c.iv().ty();
        String* wty = String.withCString("I64");
        IROperand* start = c.ivStartOp();
        if (start == (IROperand*)0)
            start = IROperand.immI(c.ivStart(), ivTy);
        string ext = IRType.is(ivTy, tyI8) || IRType.is(ivTy, tyI16) || IRType.is(ivTy, tyI32) || IRType.is(ivTy, tyI64)
                         ? "SExt" : "ZExt";
        Array* pairs = c.mixed();
        for (u32 i = (u32)0; i < pairs.count(); i = i + (u32)1)
            {
            Array* a = (Array*)((Array*)pairs.get(i)).get((u32)0);
            Array* b = (Array*)((Array*)pairs.get(i)).get((u32)1);
            IRValue* s64 = self.vecPhPut(PH, ext, wty, start, (IROperand*)0, (string)0);
            IRValue* l64 = self.vecPhPut(PH, ext, wty, IROperand.useVal(lim), (IROperand*)0, (string)0);
            IRValue* aLo = self.vecPhEdge(PH, (IROperand*)a.get((u32)0), s64, Opt.vecSizeOf(a));
            IRValue* aHi = self.vecPhEdge(PH, (IROperand*)a.get((u32)0), l64, Opt.vecSizeOf(a));
            IRValue* bLo = self.vecPhEdge(PH, (IROperand*)b.get((u32)0), s64, Opt.vecSizeOf(b));
            IRValue* bHi = self.vecPhEdge(PH, (IROperand*)b.get((u32)0), l64, Opt.vecSizeOf(b));
            IRValue* c1 = self.vecPhPut(PH, "ICmp", String.withCString("Bool"), IROperand.useVal(aLo), IROperand.useVal(bHi), "ULT");
            IRValue* c2 = self.vecPhPut(PH, "ICmp", String.withCString("Bool"), IROperand.useVal(bLo), IROperand.useVal(aHi), "ULT");
            IRValue* t = self.vecPhPut3(PH, ivTy, IROperand.useVal(c1), start, IROperand.useVal(lim));
            lim = self.vecPhPut3(PH, ivTy, IROperand.useVal(c2), IROperand.useVal(t), IROperand.useVal(lim));
            }
        return lim;
        }

    // base + at * size, in 64 bits.
    final IRValue* vecPhEdge(IRBlock* PH, IROperand* base, IRValue* at, u32 size)
        {
        String* wty = String.withCString("I64");
        IRValue* p = self.vecPhPut(PH, "PtrToInt", wty, base, (IROperand*)0, (string)0);
        IRValue* off = self.vecPhPut(PH, "Shl", wty, IROperand.useVal(at),
                                     IROperand.immI(size == (u32)2 ? (i64)1 : (i64)2, wty), (string)0);
        return self.vecPhPut(PH, "Add", wty, IROperand.useVal(p), IROperand.useVal(off), (string)0);
        }

    final IRValue* vecPhPut(IRBlock* PH, string op, String* ty, IROperand* a, IROperand* b, string pred)
        {
        IRValue* r = new IRValue(ty);
        IRInsn* n = IRInsn.with(String.withCString(op));
        n.setRes(r);
        if (pred != (string)0)
            n.setPred(String.withCString(pred));
        n.add(a);
        if (b != (IROperand*)0)
            n.add(b);
        PH.add(n);
        return r;
        }

    final IRValue* vecPhPut3(IRBlock* PH, String* ty, IROperand* a, IROperand* b, IROperand* c)
        {
        IRValue* r = new IRValue(ty);
        IRInsn* n = IRInsn.with(String.withCString("Select"));
        n.setRes(r);
        n.add(a);
        n.add(b);
        n.add(c);
        PH.add(n);
        return r;
        }

    // Does a use of the f16 widening v tell a quiet NaN from a signalling
    // one, as pack-native asks of the scalar one (quietIsInvisible)? Its pack
    // back to a 16-bit float, a square root and a fused half operation
    // cannot, nor f32 arithmetic where the target picks between NaN operands
    // by position alone; a store, anything else and any use outside the loop
    // body can. As the reference's xtvQuietSeen.
    final bool vecHalfQuietSeen(IRFunc* fn, IRBlock* B, IRValue* v, Map* defOf, Map* fused)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                if (self.vecReads((IRInsn*)bb.phis().get(i), v) != (u32)0)
                    return true;
            if (bb.term() != (IRInsn*)0 && self.vecReads(bb.term(), v) != (u32)0)
                return true;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (self.vecReads(n, v) == (u32)0)
                    continue;
                if (bb != B)
                    return true;
                if (n.res() != (IRValue*)0 && fused.get((Hashable*)n.res()) != (Object*)0)
                    continue;
                if (self.vecPackCall(n, defOf) % (u32)4 == (u32)2 || n.isOp(opFSqrt))
                    continue;
                if (Opt.vecHalfOpc(n.opc()) && !_profile.packNanOrder())
                    continue;
                return true;
                }
            }
        return false;
        }

    // A pack map's memory token: a dropped call's is its input's.
    final IROperand* vecMemFwd(IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || _vecMemFwd == (Map*)0)
            return o;
        Object* t = _vecMemFwd.get((Hashable*)o.val());
        if (t == (Object*)0)
            return o;
        return IROperand.useVal((IRValue*)t);
        }

    // After the loop: every token a dropped call made names its input.
    final void vecMemFwdRest(IRFunc* fn, IRBlock* B)
        {
        if (_vecMemFwd == (Map*)0 || _vecMemFwd.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                self.vecMemFwdInsn((IRInsn*)bb.phis().get(i));
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                self.vecMemFwdInsn((IRInsn*)bb.insns().get(i));
            if (bb.term() != (IRInsn*)0)
                self.vecMemFwdInsn(bb.term());
            }
        }

    final void vecMemFwdInsn(IRInsn* n)
        {
        for (u32 j = (u32)0; j < n.ops().count(); j = j + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(j);
            IROperand* t = self.vecMemFwd(o);
            if (t != o)
                n.ops().set(j, (Object*)t);
            }
        }

    // The pack map's state for vecApplyMap: the fused set, the halves, the
    // dropped calls' tokens.
    final void vecPackBegin(IRFunc* fn, VecCand* c, Map* defOf)
        {
        _vecMemFwd = new Map();
        _vecHalfSrc = new Map();
        _vecFused = new Map();
        if (c.isPack() && self.vecHalfArith(fn))
            _vecFused = self.vecHalfFused(fn, c.b(), defOf);
        }

    final IROperand* vecU32k(IRBlock* entry, VecCand* c, i64 v)
        {
        return self.vecConstSplat(entry, String.withCString("U32"), IROperand.immI(v, String.withCString("U32")), c);
        }

    static IROperand* vecImm32(i64 v)
        {
        return IROperand.immI(v, String.withCString("U32"));
        }

    // One instruction of a pack map's body, if it is one this rewrites: a
    // FloatPack call, a 16-bit load, a fused operation, a square root. As
    // the reference's apply in pack mode.
    final bool vecApplyPack(IRFunc* fn, IRInsn* n, VecCand* c, IRBlock* entry, IRBlock* B, Map* defOf, Map* defBlk)
        {
        String* halfTy = self.vecTyOf(String.withCString("U16"), c.isPure() ? c.vecBytes() : c.vecBytes() / (u32)2);
        String* wordTy = self.vecTyOf(String.withCString("U32"), c.vecBytes());
        String* floatTy = self.vecTyOf(String.withCString("F32"), c.vecBytes());
        u32 pk = self.vecPackCall(n, defOf);
        if (pk != (u32)0)
            {
            if (n.memRes() != (IRValue*)0)
                {
                IROperand* mi = (IROperand*)n.ops().get(n.ops().count() - (u32)1);
                if (mi.kind() == (u8)OPK_USE)
                    _vecMemFwd.set((Hashable*)n.memRes(), (Object*)self.vecMemFwd(mi).val());
                }
            IRValue* a = (IRValue*)_vecMap.get((Hashable*)((IROperand*)n.ops().get((u32)1)).val());
            if (pk == (u32)1)
                {
                _vecHalfSrc.set((Hashable*)n.res(), (Object*)a);
                if (!self.vecReadOutsideFused(fn, n.res()))
                    return true;
                }
            if (pk == (u32)2)
                {
                Object* fdo = defOf.get((Hashable*)((IROperand*)n.ops().get((u32)1)).val());
                if (fdo != (Object*)0 && _vecFused.get((Hashable*)((IRInsn*)fdo).res()) != (Object*)0)
                    {
                    IRInsn* fd = (IRInsn*)fdo;
                    string hop = fd.isOp(opFAdd) ? "VHAdd" : fd.isOp(opFSub) ? "VHSub" : fd.isOp(opFMul) ? "VHMul"
                                 : fd.isOp(opFDiv) ? "VHDiv" : "VHSqrt";
                    IROperand* h0 = IROperand.useVal((IRValue*)_vecHalfSrc.get((Hashable*)((IROperand*)fd.ops().get((u32)0)).val()));
                    IROperand* h1 = fd.ops().count() > (u32)1
                                        ? IROperand.useVal((IRValue*)_vecHalfSrc.get((Hashable*)((IROperand*)fd.ops().get((u32)1)).val()))
                                        : (IROperand*)0;
                    _vecMap.set((Hashable*)n.res(), (Object*)self.vecPut1(hop, halfTy, h0, h1, n));
                    return true;
                    }
                }
            IRValue* r = (IRValue*)0;
            if (pk == (u32)5)
                r = self.vecPut1("VWiden", floatTy, IROperand.useVal(a), Opt.vecImm32((i64)16), n);
            else if (pk == (u32)1)
                {
                r = self.vecPut1("VFpExt", floatTy, IROperand.useVal(a), (IROperand*)0, n);
                if (self.vecHalfQuietSeen(fn, B, n.res(), defOf, _vecFused))
                    r = self.vecKeepSignalling(n, c, entry, a, r);
                }
            else if (pk == (u32)2)
                r = self.vecPut1("VFpTrunc", halfTy, IROperand.useVal(a), (IROperand*)0, n);
            else
                r = self.vecRoundBf16(n, c, entry, a);
            _vecMap.set((Hashable*)n.res(), (Object*)r);
            return true;
            }
        if (n.isOp(opLoad) && n.res() != (IRValue*)0 && IRType.is(n.res().ty(), tyU16))
            {
            IRValue* vr = new IRValue(halfTy);
            IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
            vl.copyDbg(n);
            vl.setRes(vr);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                vl.add(self.vecMemFwd((IROperand*)n.ops().get(k)));
            vl.setMemRes(n.memRes());
            _vecBody.add((Object*)vl);
            _vecMap.set((Hashable*)n.res(), (Object*)vr);
            return true;
            }
        if (n.res() != (IRValue*)0 && _vecFused.get((Hashable*)n.res()) != (Object*)0)
            return true;
        if (n.isOp(opFSqrt))
            {
            IROperand* va = self.vecOperandFor((IROperand*)n.ops().get((u32)0), fn, entry, B, c, defOf, defBlk);
            _vecMap.set((Hashable*)n.res(), (Object*)self.vecPut1("VSqrt", floatTy, va, (IROperand*)0, n));
            return true;
            }
        return false;
        }

    // Is the f16 unpack v read by anything but a fused operation?
    final bool vecReadOutsideFused(IRFunc* fn, IRValue* v)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                if (self.vecReads((IRInsn*)bb.phis().get(i), v) != (u32)0)
                    return true;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* m = (IRInsn*)bb.insns().get(i);
                if (m.res() != (IRValue*)0 && _vecFused.get((Hashable*)m.res()) != (Object*)0)
                    continue;
                if (self.vecReads(m, v) != (u32)0)
                    return true;
                }
            if (bb.term() != (IRInsn*)0 && self.vecReads(bb.term(), v) != (u32)0)
                return true;
            }
        return false;
        }

    // FloatPack keeps a signalling NaN signalling where the hardware quiets
    // it: clear the quiet bit again for the halves 0x7C01..0x7DFF of either
    // sign, as pack-native's keepSignalling does.
    final IRValue* vecKeepSignalling(IRInsn* n, VecCand* c, IRBlock* entry, IRValue* a, IRValue* w)
        {
        String* wordTy = self.vecTyOf(String.withCString("U32"), c.vecBytes());
        String* floatTy = self.vecTyOf(String.withCString("F32"), c.vecBytes());
        IRValue* z = self.vecPut1("VWiden", wordTy, IROperand.useVal(a), Opt.vecImm32((i64)0), n);
        IROperand* k1 = self.vecU32k(entry, c, (i64)32767);
        IRValue* mag = self.vecPut1("VAnd", wordTy, IROperand.useVal(z), k1, n);
        IROperand* k2 = self.vecU32k(entry, c, (i64)31745);
        IRValue* d = self.vecPut1("VSub", wordTy, IROperand.useVal(mag), k2, n);
        IROperand* k3 = self.vecU32k(entry, c, (i64)511);
        IRValue* sig = self.vecPut1("VICmp", wordTy, IROperand.useVal(d), k3, n);
        ((IRInsn*)_vecBody.get(_vecBody.count() - (u32)1)).setPred(String.withCString("ULT"));
        IROperand* k4 = self.vecU32k(entry, c, (i64)4290772991);
        IRValue* cl = self.vecPut1("VAnd", wordTy, IROperand.useVal(w), k4, n);
        IRValue* r = self.vecPut1("VBsl", floatTy, IROperand.useVal(sig), IROperand.useVal(cl), n);
        ((IRInsn*)_vecBody.get(_vecBody.count() - (u32)1)).add(IROperand.useVal(w));
        return r;
        }

    // Round f32 lanes to bf16: to nearest even on the bits; a NaN keeps its
    // sign and top payload and is made quiet (pack-native's form).
    final IRValue* vecRoundBf16(IRInsn* n, VecCand* c, IRBlock* entry, IRValue* a)
        {
        String* wordTy = self.vecTyOf(String.withCString("U32"), c.vecBytes());
        String* halfTy = self.vecTyOf(String.withCString("U16"), c.vecBytes() / (u32)2);
        IRValue* hi = self.vecPut1("VLShr", wordTy, IROperand.useVal(a), Opt.vecImm32((i64)16), n);
        IROperand* k1 = self.vecU32k(entry, c, (i64)1);
        IRValue* lsb = self.vecPut1("VAnd", wordTy, IROperand.useVal(hi), k1, n);
        IROperand* k2 = self.vecU32k(entry, c, (i64)32767);
        IRValue* t1 = self.vecPut1("VAdd", wordTy, IROperand.useVal(a), k2, n);
        IRValue* t2 = self.vecPut1("VAdd", wordTy, IROperand.useVal(t1), IROperand.useVal(lsb), n);
        IRValue* rne = self.vecPut1("VLShr", wordTy, IROperand.useVal(t2), Opt.vecImm32((i64)16), n);
        IROperand* k3 = self.vecU32k(entry, c, (i64)2147483647);
        IRValue* mag = self.vecPut1("VAnd", wordTy, IROperand.useVal(a), k3, n);
        IROperand* k4 = self.vecU32k(entry, c, (i64)2139095040);
        IRValue* nan = self.vecPut1("VICmp", wordTy, IROperand.useVal(mag), k4, n);
        ((IRInsn*)_vecBody.get(_vecBody.count() - (u32)1)).setPred(String.withCString("SGT"));
        IROperand* k5 = self.vecU32k(entry, c, (i64)64);
        IRValue* q = self.vecPut1("VOr", wordTy, IROperand.useVal(hi), k5, n);
        IRValue* sel = self.vecPut1("VBsl", wordTy, IROperand.useVal(nan), IROperand.useVal(q), n);
        ((IRInsn*)_vecBody.get(_vecBody.count() - (u32)1)).add(IROperand.useVal(rne));
        return self.vecPut1("VNarrow", halfTy, IROperand.useVal(sel), (IROperand*)0, n);
        }

    }
