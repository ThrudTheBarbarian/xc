// OptIdiomMatMul.xc — the IdiomMatMul pass, ported from src/xtc/ir/XTIROptIdiomMatMul.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (IdiomMatMul)
    {

    final void idiomMatMul(IRModule* m)
        {
        if (_profile.matMulPrefix() == (String*)0)
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 iter = (u32)0; iter < (u32)64; iter = iter + (u32)1)
                {
                if (!recogniseMatMul(fn))
                    break;
                applyMatMul(m, fn);
                }
            }
        }

    final bool mmIsUse(IROperand* o, IRValue* v)
        {
        return o.kind() == (u8)OPK_USE && o.val() == v;
        }

    // The defining insn of a Use operand, when it has the given opcode.
    final IRInsn* mmDefWith(IROperand* o, String* op, Map* defOf)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return (IRInsn*)0;
        Object* d = defOf.get((Hashable*)o.val());
        if (d == 0)
            return (IRInsn*)0;
        IRInsn* n = (IRInsn*)d;
        return n.op().equals(op) ? n : (IRInsn*)0;
        }

    // "Ptr(<ty>,", the prefix of a pointer type to ty.
    static String* mmPtrOf(String* ty)
        {
        String* p = String.withCString("Ptr(");
        p.append(ty);
        p.appendCString(",");
        return p;
        }

    // The same integer width, the other signedness.
    static bool mmOtherSign(String* a, String* b)
        {
        u8* x = a.cString();
        u8* y = b.cString();
        if (a.byteLength() != (u32)3 || b.byteLength() != (u32)3 || x[1] != y[1] || x[2] != y[2])
            return false;
        if (!(x[1] == (u8)'3' && x[2] == (u8)'2') && !(x[1] == (u8)'6' && x[2] == (u8)'4'))
            return false;
        return (x[0] == (u8)'I' && y[0] == (u8)'U') || (x[0] == (u8)'U' && y[0] == (u8)'I');
        }

    // A Bitcast to the integer type fty of a value of the other signedness at
    // the same width, else 0. As the reference.
    final IRInsn* mmSameWidthBitcast(IROperand* o, String* fty, Map* defOf)
        {
        IRInsn* bc = mmDefWith(o, String.withCString("Bitcast"), defOf);
        if (bc == 0 || bc.ops().count() != (u32)1 || bc.res() == 0 || !bc.res().ty().equals(fty))
            return (IRInsn*)0;
        IROperand* src = (IROperand*)bc.ops().get((u32)0);
        if (src.kind() != (u8)OPK_USE || src.val() == 0)
            return (IRInsn*)0;
        IRInsn* def = (IRInsn*)defOf.get((Hashable*)src.val());
        return (def != 0 && def.res() != 0 && mmOtherSign(fty, def.res().ty())) ? bc : (IRInsn*)0;
        }

    // Such a Bitcast of a load (I32 of a U32, U64 of an I64, ...), else 0.
    final IRInsn* mmSameWidthCast(IROperand* o, String* fty, Map* defOf)
        {
        IRInsn* bc = mmSameWidthBitcast(o, fty, defOf);
        if (bc == 0 || mmDefWith((IROperand*)bc.ops().get((u32)0), String.withCString("Load"), defOf) == 0)
            return (IRInsn*)0;
        return bc;
        }

    // A use of `Const +0.0` of the given float type (or an ImmF of +0.0).
    final bool mmPlusZero(IROperand* o, Map* defOf, String* fty)
        {
        String* zero = String.withCString("0000000000000000");
        if (o.kind() == (u8)OPK_IMMF)
            return o.fpHex().equals(zero);
        IRInsn* d = mmDefWith(o, String.withCString("Const"), defOf);
        if (d == 0 || d.res() == 0 || !d.res().ty().equals(fty) || d.ops().count() != (u32)1)
            return false;
        IROperand* c = (IROperand*)d.ops().get((u32)0);
        return c.kind() == (u8)OPK_IMMF && c.fpHex().equals(zero);
        }

    // Phi incoming from block b (operands alternate block, value).
    final IROperand* mmIncoming(IRInsn* phi, IRBlock* b)
        {
        for (u32 i = (u32)0; i + (u32)1 < phi.ops().count(); i = i + (u32)2)
            if (((IROperand*)phi.ops().get(i)).blk() == b)
                return (IROperand*)phi.ops().get(i + (u32)1);
        return (IROperand*)0;
        }

    // `x + 1`.
    final bool mmIncOf(IROperand* o, IRValue* x, Map* defOf)
        {
        IRInsn* add = mmDefWith(o, String.withCString("Add"), defOf);
        if (add == 0 || add.ops().count() != (u32)2)
            return false;
        IROperand* a0 = (IROperand*)add.ops().get((u32)0);
        IROperand* a1 = (IROperand*)add.ops().get((u32)1);
        i64 one = (i64)0;
        if (mmIsUse(a0, x) && self.constValue(defOf, a1, &one) && one == (i64)1)
            return true;
        one = (i64)0;
        if (mmIsUse(a1, x) && self.constValue(defOf, a0, &one) && one == (i64)1)
            return true;
        return false;
        }

    // `AddrOf @g` of a global symbol: invariant wherever it is taken.
    final IRInsn* mmGlobalAddr(IROperand* o, Map* defOf)
        {
        IRInsn* a = mmDefWith(o, String.withCString("AddrOf"), defOf);
        if (a == 0 || a.ops().count() != (u32)1 || ((IROperand*)a.ops().get((u32)0)).kind() != (u8)OPK_SYM)
            return (IRInsn*)0;
        return a;
        }

    // Mul(p, q), or Shl(p, #n) — a constant stride that is a power of two.
    final IRInsn* mmScaleOf(IROperand* o, Map* defOf)
        {
        IRInsn* m = mmDefWith(o, String.withCString("Mul"), defOf);
        return m != 0 ? m : mmDefWith(o, String.withCString("Shl"), defOf);
        }
    final IRInsn* mmSplitIndex(IROperand* idx, Map* defOf)
        {
        IRInsn* add = mmDefWith(idx, String.withCString("Add"), defOf);
        if (add == 0 || add.ops().count() != (u32)2)
            return (IRInsn*)0;
        IROperand* a0 = (IROperand*)add.ops().get((u32)0);
        IROperand* a1 = (IROperand*)add.ops().get((u32)1);
        IRInsn* m0 = mmScaleOf(a0, defOf);
        IRInsn* m1 = mmScaleOf(a1, defOf);
        if (m0 != 0 && m0.ops().count() == (u32)2)
            {
            _mxAddend = a1;
            return m0;
            }
        if (m1 != 0 && m1.ops().count() == (u32)2)
            {
            _mxAddend = a0;
            return m1;
            }
        return (IRInsn*)0;
        }

    // Mul(v, other) in either order: the operand that is not v, or 0. For
    // Shl(v, #n) the stride 1 << n, as a U32 immediate; the amount may come
    // narrowed (`i << 9` lowers it as Trunc(ZExt(Const))).
    final IROperand* mmMulOther(IRInsn* mul, IRValue* v, Map* defOf)
        {
        IROperand* a0 = (IROperand*)mul.ops().get((u32)0);
        IROperand* a1 = (IROperand*)mul.ops().get((u32)1);
        if (mul.op().equals(String.withCString("Shl")))
            {
            i64 n = (i64)0;
            IRInsn* tr = mmDefWith(a1, String.withCString("Trunc"), defOf);
            bool amt = tr != 0 ? self.constValue(defOf, (IROperand*)tr.ops().get((u32)0), &n) : self.constValue(defOf, a1, &n);
            if (mmIsUse(a0, v) && amt && n >= (i64)0 && n < (i64)32)
                return IROperand.immI((i64)1 << n, String.withCString("U32"));
            return (IROperand*)0;
            }
        if (mmIsUse(a0, v) && !mmIsUse(a1, v))
            return a1;
        if (mmIsUse(a1, v) && !mmIsUse(a0, v))
            return a0;
        return (IROperand*)0;
        }

    final Array* mmSuccs(IRBlock* b)
        {
        Array* out = new Array();
        if (b.term() == 0)
            return out;
        for (u32 i = (u32)0; i < b.term().ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)b.term().ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != 0)
                out.add((Object*)o.blk());
            }
        return out;
        }

    final bool mmBranchesTo(IRBlock* b, IRBlock* to)
        {
        IRInsn* t = b.term();
        return t != 0 && t.op().equals(String.withCString("Branch")) && t.ops().count() == (u32)1
            && ((IROperand*)t.ops().get((u32)0)).blk() == to;
        }

    final bool mmOnlyConsts(IRBlock* b, Map* defOf)
        {
        for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)b.insns().get(i);
            if (n.memRes() != 0)
                return false;
            if (n.op().equals(String.withCString("Const")))
                continue;
            i64 v = (i64)0;
            if (n.op().equals(String.withCString("ZExt")) && self.constValue(defOf, (IROperand*)n.ops().get((u32)0), &v))
                continue;
            return false;
            }
        return true;
        }

    // A counted loop header (see the reference's countedHeader).
    final bool mmCountedHeader(IRBlock* H, u32 extraPhis, IRBlock* latch, Map* defOf)
        {
        if (H.phis().count() != (u32)1 + extraPhis || H.insns().count() < (u32)1)
            return false;
        // The guard is the last instruction; anything before it is a constant
        // (a literal bound is materialised in the header: Const, ZExt).
        IRInsn* guard = (IRInsn*)H.insns().get(H.insns().count() - (u32)1);
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n == guard)
                continue;
            if (n.memRes() != 0 || n.res() == 0)
                return false;
            i64 v = (i64)0;
            bool k = n.op().equals(String.withCString("Const")) && n.ops().count() == (u32)1
                  && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_IMMI;
            if (!k && !(n.op().equals(String.withCString("ZExt")) && self.constValue(defOf, (IROperand*)n.ops().get((u32)0), &v)))
                return false;
            }
        IRInsn* t = H.term();
        if (!guard.op().equals(String.withCString("ICmp")) || guard.pred() == 0
            || !guard.pred().equals(String.withCString("ULT")) || guard.ops().count() != (u32)2 || guard.res() == 0)
            return false;
        if (t == 0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() != (u32)3
            || !mmIsUse((IROperand*)t.ops().get((u32)0), guard.res()))
            return false;
        IRInsn* iv = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() != 0 && mmIsUse((IROperand*)guard.ops().get((u32)0), phi.res()))
                iv = phi;
            }
        if (iv == 0 || !iv.res().ty().equals(String.withCString("U32")) || iv.ops().count() != (u32)4)
            return false;
        IRBlock* body = ((IROperand*)t.ops().get((u32)1)).blk();
        IRBlock* exitB = ((IROperand*)t.ops().get((u32)2)).blk();
        if (body == 0 || exitB == 0 || body == H || exitB == H)
            return false;
        IRBlock* pre = (IRBlock*)0;
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)2)
            if (((IROperand*)iv.ops().get(i)).blk() != latch)
                pre = ((IROperand*)iv.ops().get(i)).blk();
        if (pre == 0 || mmIncoming(iv, latch) == 0)
            return false;
        // The init is 0, or — where the caller takes a start — any value,
        // which the caller checks is made outside the nest.
        i64 init = (i64)0;
        bool zero = self.constValue(defOf, mmIncoming(iv, pre), &init) && init == (i64)0;
        if (!zero && !_mxTakeStart)
            return false;
        _mxStartOf = zero ? (IROperand*)0 : mmIncoming(iv, pre);
        if (!mmIncOf(mmIncoming(iv, latch), iv.res(), defOf))
            return false;
        _mxIv = iv;
        _mxBound = (IROperand*)guard.ops().get((u32)1);
        _mxBody = body;
        _mxExitOf = exitB;
        _mxPreOf = pre;
        return true;
        }

    final bool mmU32(IROperand* o, Map* defOf)
        {
        i64 v = (i64)0;
        if (constValue(defOf, o, &v))
            return v >= (i64)0 && v <= (i64)$FFFFFFFF;
        return o.kind() == (u8)OPK_USE && o.val() != 0 && o.val().ty().equals(String.withCString("U32"));
        }

    final bool mmInBlocks(Array* bs, IRBlock* b)
        {
        for (u32 i = (u32)0; i < bs.count(); i = i + (u32)1)
            if ((IRBlock*)bs.get(i) == b)
                return true;
        return false;
        }

    // Defined outside the nest (a parameter has no defining block).
    final bool mmOutside(IROperand* o, Map* defOf, Map* defBlk, Array* nest)
        {
        i64 v = (i64)0;
        if (constValue(defOf, o, &v))
            return true; // a constant is invariant wherever it is spelled
        if (mmGlobalAddr(o, defOf) != 0)
            return true; // so is a global's address; the call takes its own
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return false;
        Object* b = defBlk.get((Hashable*)o.val());
        return b == 0 || !mmInBlocks(nest, (IRBlock*)b);
        }

    // Ek / Bk / Ej may hold only these opcodes besides the named memory ops.
    final bool mmOpIn(String* op, u32 set)
        {
        if (op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt"))
            || op.equals(String.withCString("Add")))
            return true;
        if (set >= (u32)1 && (op.equals(String.withCString("Mul")) || op.equals(String.withCString("ElementAddr"))
                              || op.equals(String.withCString("Shl")) || op.equals(String.withCString("Trunc"))
                              || op.equals(String.withCString("AddrOf"))))
            return true;
        if (set >= (u32)2 && (op.equals(String.withCString("FMul")) || op.equals(String.withCString("FAdd"))))
            return true;
        return false;
        }

    final bool recogniseMatMul(IRFunc* fn)
        {
        Map* defOf = self.defMapAll(fn);
        Map* defBlk = self.defBlockMap(fn);
        for (u32 hb = (u32)0; hb < fn.blocks().count(); hb = hb + (u32)1)
            {
            IRBlock* Hk = (IRBlock*)fn.blocks().get(hb);
            if (Hk.phis().count() != (u32)2)
                continue;
            Array* hkPreds = self.predsOfBlock(fn, Hk);
            IRBlock* Bk = (IRBlock*)0;
            for (u32 i = (u32)0; i < hkPreds.count(); i = i + (u32)1)
                {
                IRBlock* p = (IRBlock*)hkPreds.get(i);
                if (mmBranchesTo(p, Hk) && p != Hk && mmSuccs(p).count() == (u32)1)
                    {
                    IRInsn* t = Hk.term();
                    if (t != 0 && t.op().equals(String.withCString("CondBranch")) && t.ops().count() == (u32)3
                        && ((IROperand*)t.ops().get((u32)1)).blk() == p)
                        Bk = p;
                    }
                }
            if (Bk == 0)
                continue;
            if (!mmCountedHeader(Hk, (u32)1, Bk, defOf) || _mxBody != Bk)
                continue;
            IRInsn* kPhi = _mxIv;
            IROperand* K = _mxBound;
            IRBlock* Ek = _mxExitOf;
            IRBlock* Pk = _mxPreOf;
            if (hkPreds.count() != (u32)2 || self.predsOfBlock(fn, Ek).count() != (u32)1 || Ek.phis().count() != (u32)0
                || Bk.phis().count() != (u32)0)
                continue;
            IRInsn* sPhi = (IRInsn*)Hk.phis().get((u32)0) == kPhi ? (IRInsn*)Hk.phis().get((u32)1)
                                                                   : (IRInsn*)Hk.phis().get((u32)0);
            if (sPhi.res() == 0 || sPhi.ops().count() != (u32)4)
                continue;
            String* fty = sPhi.res().ty();
            bool f64 = fty.equals(String.withCString("F64"));
            // An integer nest (u32, i32, u64 or i64 elements, Add and Mul)
            // goes to the target's integer kernel, where it has one. As the
            // reference.
            bool isInt = fty.equals(String.withCString("U32")) || fty.equals(String.withCString("I32"))
                         || fty.equals(String.withCString("U64")) || fty.equals(String.withCString("I64"));
            if (!f64 && !isInt && !fty.equals(String.withCString("F32")))
                continue;
            if (isInt && !_profile.matMulInts())
                continue;
            if (mmIncoming(sPhi, Pk) == 0 || mmIncoming(sPhi, Bk) == 0)
                continue;
            i64 zero = (i64)0;
            if (isInt ? !(self.constValue(defOf, mmIncoming(sPhi, Pk), &zero) && zero == (i64)0)
                      : !mmPlusZero(mmIncoming(sPhi, Pk), defOf, fty))
                continue;
            IRInsn* fadd = mmDefWith(mmIncoming(sPhi, Bk), String.withCString(isInt ? "Add" : "FAdd"), defOf);
            // An unsigned sum of a mixed-signedness product is added in the
            // signed type: s' = Bitcast(Add(Bitcast(s), Mul)). As the reference.
            IRInsn* sumOut = (IRInsn*)0;
            IRInsn* sumIn = (IRInsn*)0;
            String* mty = fty;
            if (fadd == 0 && isInt)
                {
                sumOut = mmSameWidthBitcast(mmIncoming(sPhi, Bk), fty, defOf);
                fadd = sumOut != 0 ? mmDefWith((IROperand*)sumOut.ops().get((u32)0), String.withCString("Add"), defOf) : (IRInsn*)0;
                if (fadd != 0)
                    mty = fadd.res().ty();
                }
            if (fadd == 0 || fadd.ops().count() != (u32)2 || defBlk.get((Hashable*)fadd.res()) != (Object*)Bk)
                continue;
            if (sumOut != 0 && defBlk.get((Hashable*)sumOut.res()) != (Object*)Bk)
                continue;
            IROperand* prodOp = (IROperand*)0;
            for (u32 q = (u32)0; q < (u32)2 && prodOp == 0; q = q + (u32)1)
                {
                IROperand* sOp = (IROperand*)fadd.ops().get(q);
                IRInsn* inCast = sumOut != 0 ? mmDefWith(sOp, String.withCString("Bitcast"), defOf) : (IRInsn*)0;
                if (inCast != 0 && (inCast.ops().count() != (u32)1 || !inCast.res().ty().equals(mty)))
                    inCast = (IRInsn*)0;
                bool hit = sumOut != 0
                    ? (inCast != 0 && mmIsUse((IROperand*)inCast.ops().get((u32)0), sPhi.res())
                       && defBlk.get((Hashable*)inCast.res()) == (Object*)Bk)
                    : mmIsUse(sOp, sPhi.res());
                if (hit)
                    {
                    prodOp = (IROperand*)fadd.ops().get((u32)1 - q);
                    sumIn = inCast;
                    }
                }
            IRInsn* fmul = prodOp != 0 ? mmDefWith(prodOp, String.withCString(isInt ? "Mul" : "FMul"), defOf) : (IRInsn*)0;
            if (fmul == 0 || fmul.ops().count() != (u32)2 || defBlk.get((Hashable*)fmul.res()) != (Object*)Bk)
                continue;
            // A load of the other signedness at the same width arrives through
            // a Bitcast (u32 x i32): the product's low bits are the same either
            // way, so the nest is the kernel of the sum's type.
            IRInsn* cast0 = isInt ? mmSameWidthCast((IROperand*)fmul.ops().get((u32)0), mty, defOf) : (IRInsn*)0;
            IRInsn* cast1 = isInt ? mmSameWidthCast((IROperand*)fmul.ops().get((u32)1), mty, defOf) : (IRInsn*)0;
            IRInsn* l0 = mmDefWith(cast0 != 0 ? (IROperand*)cast0.ops().get((u32)0) : (IROperand*)fmul.ops().get((u32)0),
                                   String.withCString("Load"), defOf);
            IRInsn* l1 = mmDefWith(cast1 != 0 ? (IROperand*)cast1.ops().get((u32)0) : (IROperand*)fmul.ops().get((u32)1),
                                   String.withCString("Load"), defOf);
            if (l0 == 0 || l1 == 0 || l0 == l1 || defBlk.get((Hashable*)l0.res()) != (Object*)Bk
                || defBlk.get((Hashable*)l1.res()) != (Object*)Bk)
                continue;
            if ((cast0 != 0 && defBlk.get((Hashable*)cast0.res()) != (Object*)Bk)
                || (cast1 != 0 && defBlk.get((Hashable*)cast1.res()) != (Object*)Bk))
                continue;
            if ((cast0 == 0 && !l0.res().ty().equals(mty)) || (cast1 == 0 && !l1.res().ty().equals(mty)))
                continue;
            IRInsn* ea0 = mmDefWith((IROperand*)l0.ops().get((u32)0), String.withCString("ElementAddr"), defOf);
            IRInsn* ea1 = mmDefWith((IROperand*)l1.ops().get((u32)0), String.withCString("ElementAddr"), defOf);
            if (ea0 == 0 || ea1 == 0 || ea0.ops().count() != (u32)2 || ea1.ops().count() != (u32)2)
                continue;
            IRValue* kv = kPhi.res();
            IRInsn* mul0 = mmSplitIndex((IROperand*)ea0.ops().get((u32)1), defOf);
            IROperand* add0 = _mxAddend;
            if (mul0 == 0)
                continue;
            IRInsn* mul1 = mmSplitIndex((IROperand*)ea1.ops().get((u32)1), defOf);
            IROperand* add1 = _mxAddend;
            if (mul1 == 0)
                continue;
            IRInsn* eaA;
            IRInsn* eaB;
            IRInsn* mulA;
            IRInsn* mulB;
            IRInsn* loadA;
            IRInsn* loadB;
            IROperand* bCol;
            if (mmIsUse(add0, kv) && mmMulOther(mul1, kv, defOf) != 0 && !mmIsUse(add1, kv))
                {
                eaA = ea0; mulA = mul0; loadA = l0;
                eaB = ea1; mulB = mul1; loadB = l1; bCol = add1;
                }
            else if (mmIsUse(add1, kv) && mmMulOther(mul0, kv, defOf) != 0 && !mmIsUse(add0, kv))
                {
                eaA = ea1; mulA = mul1; loadA = l1;
                eaB = ea0; mulB = mul0; loadB = l0; bCol = add0;
                }
            else
                continue;
            IROperand* ldb = mmMulOther(mulB, kv, defOf);
            bool bkClean = true;
            for (u32 i = (u32)0; i < Bk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)Bk.insns().get(i);
                if (n == loadA || n == loadB || (cast0 != 0 && n == cast0) || (cast1 != 0 && n == cast1)
                    || (sumIn != 0 && n == sumIn) || (sumOut != 0 && n == sumOut))
                    continue;
                if (n.memRes() != 0 || !mmOpIn(n.op(), (u32)2))
                    {
                    bkClean = false;
                    break;
                    }
                }
            if (!bkClean || !mmBranchesTo(Bk, Hk))
                continue;
            IRInsn* store = (IRInsn*)0;
            bool twoStores = false;
            for (u32 i = (u32)0; i < Ek.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)Ek.insns().get(i);
                if (!n.op().equals(String.withCString("Store")))
                    continue;
                if (store != 0)
                    twoStores = true;
                store = n;
                }
            if (twoStores || store == 0 || store.ops().count() != (u32)3
                || !mmIsUse((IROperand*)store.ops().get((u32)1), sPhi.res()))
                continue;
            IRInsn* eaC = mmDefWith((IROperand*)store.ops().get((u32)0), String.withCString("ElementAddr"), defOf);
            if (eaC == 0 || eaC.ops().count() != (u32)2)
                continue;
            IRInsn* mulC = mmSplitIndex((IROperand*)eaC.ops().get((u32)1), defOf);
            IROperand* cCol = _mxAddend;
            if (mulC == 0)
                continue;
            Array* ekS = mmSuccs(Ek);
            IRBlock* Hj = ekS.count() == (u32)1 ? (IRBlock*)ekS.get((u32)0) : (IRBlock*)0;
            if (Hj == 0 || !mmBranchesTo(Ek, Hj))
                continue;
            bool ekClean = true;
            for (u32 i = (u32)0; i < Ek.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)Ek.insns().get(i);
                if (n == store)
                    continue;
                if (n.memRes() != 0 || !mmOpIn(n.op(), (u32)1))
                    {
                    ekClean = false;
                    break;
                    }
                }
            if (!ekClean)
                continue;

            if (!mmCountedHeader(Hj, (u32)0, Ek, defOf))
                continue;
            IRInsn* jPhi = _mxIv;
            IROperand* N = _mxBound;
            IRBlock* Bj = _mxBody;
            IRBlock* Ej = _mxExitOf;
            IRBlock* Pj = _mxPreOf;
            if (Bj != Pk || !mmBranchesTo(Bj, Hk) || Bj.phis().count() != (u32)0 || self.predsOfBlock(fn, Bj).count() != (u32)1
                || self.predsOfBlock(fn, Hj).count() != (u32)2 || self.predsOfBlock(fn, Ej).count() != (u32)1
                || Ej.phis().count() != (u32)0)
                continue;
            if (!mmOnlyConsts(Bj, defOf))
                continue;
            if (!mmIsUse(bCol, jPhi.res()) || !mmIsUse(cCol, jPhi.res()))
                continue;

            Array* ejS = mmSuccs(Ej);
            IRBlock* Hi = ejS.count() == (u32)1 ? (IRBlock*)ejS.get((u32)0) : (IRBlock*)0;
            if (Hi == 0 || !mmBranchesTo(Ej, Hi))
                continue;
            // The i loop may start anywhere: a matrix product in a `par`
            // block runs rows lo..hi of it.
            _mxTakeStart = true;
            bool hiOk = mmCountedHeader(Hi, (u32)0, Ej, defOf);
            _mxTakeStart = false;
            if (!hiOk)
                continue;
            IROperand* iStart = _mxStartOf;
            IRInsn* iPhi = _mxIv;
            IROperand* M = _mxBound;
            IRBlock* Bi = _mxBody;
            IRBlock* Ei = _mxExitOf;
            IRBlock* Pi = _mxPreOf;
            if (Bi != Pj || !mmBranchesTo(Bi, Hj) || Bi.phis().count() != (u32)0 || self.predsOfBlock(fn, Bi).count() != (u32)1
                || self.predsOfBlock(fn, Hi).count() != (u32)2 || self.predsOfBlock(fn, Ei).count() != (u32)1
                || Ei.phis().count() != (u32)0)
                continue;
            if (!mmOnlyConsts(Bi, defOf) || !mmBranchesTo(Pi, Hi) || Pi == Hi)
                continue;
            bool ejClean = true;
            for (u32 i = (u32)0; i < Ej.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)Ej.insns().get(i);
                if (n.memRes() != 0 || !mmOpIn(n.op(), (u32)0))
                    ejClean = false;
                }
            if (!ejClean)
                continue;
            IRValue* iv = iPhi.res();
            IROperand* lda = mmMulOther(mulA, iv, defOf);
            IROperand* ldc = mmMulOther(mulC, iv, defOf);
            if (lda == 0 || ldc == 0 || ldb == 0)
                continue;

            Array* nest = new Array();
            nest.add((Object*)Hi); nest.add((Object*)Bi); nest.add((Object*)Hj); nest.add((Object*)Bj);
            nest.add((Object*)Hk); nest.add((Object*)Bk); nest.add((Object*)Ek); nest.add((Object*)Ej);
            IROperand* Aop = (IROperand*)eaA.ops().get((u32)0);
            IROperand* Bop = (IROperand*)eaB.ops().get((u32)0);
            IROperand* Cop = (IROperand*)eaC.ops().get((u32)0);
            Array* inputs = new Array();
            inputs.add((Object*)M); inputs.add((Object*)N); inputs.add((Object*)K);
            inputs.add((Object*)lda); inputs.add((Object*)ldb); inputs.add((Object*)ldc);
            inputs.add((Object*)Aop); inputs.add((Object*)Bop); inputs.add((Object*)Cop);
            bool inv = true;
            for (u32 i = (u32)0; i < inputs.count(); i = i + (u32)1)
                if (!mmOutside((IROperand*)inputs.get(i), defOf, defBlk, nest))
                    inv = false;
            if (iStart != 0 && (!mmOutside(iStart, defOf, defBlk, nest) || !mmU32(iStart, defOf)))
                inv = false;
            if (!inv)
                continue;
            bool u32s = true;
            for (u32 i = (u32)0; i < (u32)6; i = i + (u32)1)
                if (!mmU32((IROperand*)inputs.get(i), defOf))
                    u32s = false;
            if (!u32s)
                continue;
            // The three bases point at the element type (A and B at their
            // loads', which differs from C's only in signedness).
            if (eaA.res() == 0 || eaB.res() == 0 || eaC.res() == 0 || !eaA.res().ty().hasPrefix(mmPtrOf(loadA.res().ty()))
                || !eaB.res().ty().hasPrefix(mmPtrOf(loadB.res().ty())) || !eaC.res().ty().hasPrefix(mmPtrOf(fty)))
                continue;
            if (mmEscapes(fn, nest))
                continue;
            bool haveMem = loadA.ops().count() > (u32)1 && ((IROperand*)loadA.ops().get((u32)1)).kind() == (u8)OPK_USE;
            IRValue* mem = haveMem ? ((IROperand*)loadA.ops().get((u32)1)).val() : (IRValue*)0;
            for (u32 i = (u32)0; i < Pi.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)Pi.insns().get(i);
                if (n.memRes() != 0)
                    {
                    mem = n.memRes();
                    haveMem = true;
                    }
                }
            if (!haveMem)
                continue;
            _mxPre = Pi;
            _mxHead = Hi;
            _mxExit = Ei;
            _mmF64 = f64;
            _mmElem = String.withCString(f64 ? "f64" : "f32");
            if (fty.equals(String.withCString("U32")))
                _mmElem = String.withCString("u32");
            else if (fty.equals(String.withCString("I32")))
                _mmElem = String.withCString("i32");
            else if (fty.equals(String.withCString("U64")))
                _mmElem = String.withCString("u64");
            else if (fty.equals(String.withCString("I64")))
                _mmElem = String.withCString("i64");
            _mxM = M; _mxN = N; _mxK = K;
            _mxLda = lda; _mxLdb = ldb; _mxLdc = ldc;
            _mxA = Aop; _mxB = Bop; _mxC = Cop;
            _mxAddrA = mmGlobalAddr(Aop, defOf);
            _mxAddrB = mmGlobalAddr(Bop, defOf);
            _mxAddrC = mmGlobalAddr(Cop, defOf);
            _mxStart = iStart;
            _mxPtrTy = eaA.res().ty();
            _mxMem = mem;
            if (_mxConsts == 0)
                _mxConsts = new i64[6];
            for (u32 i = (u32)0; i < (u32)6; i = i + (u32)1)
                {
                i64 v = (i64)0;
                _mxConsts[i] = self.constValue(defOf, (IROperand*)inputs.get(i), &v) ? v : (i64)-1;
                }
            return true;
            }
        return false;
        }

    // A value made in the nest (not memory) read outside it.
    final bool mmEscapes(IRFunc* fn, Array* nest)
        {
        Map* made = new Map();
        for (u32 b = (u32)0; b < nest.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)nest.get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(i);
                if (n.res() != 0)
                    made.set((Hashable*)n.res(), (Object*)n);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != 0)
                    made.set((Hashable*)n.res(), (Object*)n);
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (mmInBlocks(nest, bb))
                continue;
            if (mmReadsAny(bb.phis(), made) || mmReadsAny(bb.insns(), made))
                return true;
            if (bb.term() != 0)
                {
                Array* t = new Array();
                t.add((Object*)bb.term());
                if (mmReadsAny(t, made))
                    return true;
                }
            }
        return false;
        }

    final bool mmReadsAny(Array* list, Map* made)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)list.get(i);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() == (u8)OPK_USE && o.val() != 0 && made.get((Hashable*)o.val()) != 0)
                    return true;
                }
            }
        return false;
        }

    // A U32 operand as a value in the preheader: a constant (however it is
    // spelled and wherever it is defined) becomes a fresh `Const #v:U32` here.
    final IROperand* mmU32Value(IROperand* o, i64 k)
        {
        if (k < (i64)0)
            return o;
        IRValue* v = new IRValue(String.withCString("U32"));
        IRInsn* c = IRInsn.with(String.withCString("Const"));
        c.setRes(v);
        c.add(IROperand.immI(k, String.withCString("U32")));
        _mxPre.add(c);
        return IROperand.useVal(v);
        }

    final IRValue* mmEmit(String* op, String* ty, IROperand* a, IROperand* b)
        {
        IRValue* v = new IRValue(ty);
        IRInsn* n = IRInsn.with(op);
        n.setRes(v);
        n.add(a);
        if (b != 0)
            n.add(b);
        _mxPre.add(n);
        return v;
        }

    final void applyMatMul(IRModule* m, IRFunc* fn)
        {
        String* name = new String();
        name.append(_profile.matMulPrefix());
        name.append(_mmElem);
        name.append(_profile.matMulSuffix());
        // Under `:goal(speed)` (the i loop's header was lowered as one), the
        // target's kernel that may skip its exactness check. As the reference.
        // An integer kernel has no check to skip.
        if (_mmElem.byteAt((u32)0) == (u8)'f' && _profile.matMulFastSuffix() != (String*)0 && _mxHead.name() != (String*)0
            && fn.isSpeedHeader(_mxHead.name()))
            name.append(_profile.matMulFastSuffix());
        bool have = false;
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            if (((IRSymbol*)m.syms().get(i)).name().equals(name))
                have = true;
        if (!have)
            m.addSym(IRSymbol.runtime(name));
        String* tyU64 = String.withCString("U64");
        // In the reference's order: value creation order is frame-slot order.
        IROperand* M = mmU32Value(_mxM, _mxConsts[0]);
        // An i loop from `s`: the kernel runs its M - s rows (none when
        // s >= M), from A and C advanced by s rows (below).
        IROperand* S = _mxStart;
        if (S != 0)
            {
            String* tyU = String.withCString("U32");
            IRValue* lt = new IRValue(String.withCString("Bool"));
            IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
            cmp.setRes(lt);
            cmp.setPred(String.withCString("ULT"));
            cmp.add(S);
            cmp.add(M);
            _mxPre.add(cmp);
            IRValue* rows = mmEmit(String.withCString("Sub"), tyU, M, S);
            IRValue* none = mmEmit(String.withCString("Const"), tyU, IROperand.immI((i64)0, tyU), (IROperand*)0);
            IRValue* sel = new IRValue(tyU);
            IRInsn* sn = IRInsn.with(String.withCString("Select"));
            sn.setRes(sel);
            sn.add(IROperand.useVal(lt));
            sn.add(IROperand.useVal(rows));
            sn.add(IROperand.useVal(none));
            _mxPre.add(sn);
            M = IROperand.useVal(sel);
            }
        IROperand* N = mmU32Value(_mxN, _mxConsts[1]);
        IRValue* zm = mmEmit(String.withCString("ZExt"), tyU64, M, (IROperand*)0);
        IRValue* zn = mmEmit(String.withCString("ZExt"), tyU64, N, (IROperand*)0);
        IRValue* sh = mmEmit(String.withCString("Shl"), tyU64, IROperand.useVal(zn), IROperand.immI((i64)32, tyU64));
        IRValue* mn = mmEmit(String.withCString("Or"), tyU64, IROperand.useVal(zm), IROperand.useVal(sh));
        IROperand* K = mmU32Value(_mxK, _mxConsts[2]);
        IROperand* lda = mmU32Value(_mxLda, _mxConsts[3]);
        IROperand* ldb = mmU32Value(_mxLdb, _mxConsts[4]);
        IROperand* ldc = mmU32Value(_mxLdc, _mxConsts[5]);
        // A global's address taken inside the nest is taken again here, A
        // then B then C, so the call reads no value the nest defines.
        IROperand* A = _mxAddrA != 0 ? IROperand.useVal(mmEmit(String.withCString("AddrOf"), _mxAddrA.res().ty(), (IROperand*)_mxAddrA.ops().get((u32)0), (IROperand*)0)) : _mxA;
        IROperand* B = _mxAddrB != 0 ? IROperand.useVal(mmEmit(String.withCString("AddrOf"), _mxAddrB.res().ty(), (IROperand*)_mxAddrB.ops().get((u32)0), (IROperand*)0)) : _mxB;
        IROperand* Cb = _mxAddrC != 0 ? IROperand.useVal(mmEmit(String.withCString("AddrOf"), _mxAddrC.res().ty(), (IROperand*)_mxAddrC.ops().get((u32)0), (IROperand*)0)) : _mxC;
        if (S != 0)
            {
            String* u32b = String.withCString("U32");
            IRValue* offA = mmEmit(String.withCString("Mul"), u32b, S, lda);
            A = IROperand.useVal(mmEmit(String.withCString("ElementAddr"), _mxPtrTy, A, IROperand.useVal(offA)));
            IRValue* offC = mmEmit(String.withCString("Mul"), u32b, S, ldc);
            Cb = IROperand.useVal(mmEmit(String.withCString("ElementAddr"), _mxPtrTy, Cb, IROperand.useVal(offC)));
            }
        IRValue* done = new IRValue(String.withCString("Bool"));
        IRValue* mem = new IRValue(String.withCString("Mem"));
        IRInsn* call = IRInsn.with(String.withCString("Call"));
        call.setRes(done);
        call.setMemRes(mem);
        call.add(IROperand.sym(name));
        call.add(A);
        call.add(B);
        call.add(Cb);
        call.add(IROperand.useVal(mn));
        call.add(K);
        call.add(lda);
        call.add(ldb);
        call.add(ldc);
        call.add(IROperand.useVal(_mxMem));
        call.setCc(String.withCString("CallConv::Standard"));
        _mxPre.add(call);
        IRInsn* br = IRInsn.with(String.withCString("CondBranch"));
        br.add(IROperand.useVal(done));
        br.add(IROperand.block(_mxExit));
        br.add(IROperand.block(_mxHead));
        _mxPre.setTerm(br);
        }
    }
