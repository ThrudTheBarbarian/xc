// LowerParSpirv.xc — a `par` kernel as a SPIR-V module, for Vulkan (par-spirv-wgsl.md).
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
#import <LowerParCommon>
#import <LowerParPtx>

    class Lower (ParSpirv)
    {

    final String* spvS(string c) { return String.withCString(c); }
    final bool spvIsFloat(String* t) { return ptxIs(t, "F32") || ptxIs(t, "F64"); }
    final u32 spvNarrowBits(String* t)
        {
        if (ptxIs(t, "I8") || self.ptxIs(t, "U8")) return (u32)8;
        if (ptxIs(t, "I16") || self.ptxIs(t, "U16")) return (u32)16;
        return (u32)0;
        }
    final bool spvNarrowSigned(String* t) { return ptxIs(t, "I8") || ptxIs(t, "I16"); }
    // The bytes of a value memory holds narrower than a word: 8/16-bit, or a bool.
    final u32 spvNarrowBytes(String* t)
        {
        if (ptxIs(t, "I8") || self.ptxIs(t, "U8") || self.ptxIs(t, "Bool")) return (u32)1;
        if (ptxIs(t, "I16") || self.ptxIs(t, "U16")) return (u32)2;
        return (u32)0;
        }
    final bool spvWide(String* t) { return ptxIs(t, "I64") || ptxIs(t, "U64"); }
    final u32 spvWidth(String* t)
        {
        if (ptxIs(t, "I8") || self.ptxIs(t, "U8") || self.ptxIs(t, "Bool")) return (u32)1;
        if (ptxIs(t, "I16") || self.ptxIs(t, "U16")) return (u32)2;
        if (ptxIs(t, "I32") || self.ptxIs(t, "U32") || self.ptxIs(t, "F32")) return (u32)4;
        if (ptxIs(t, "I64") || self.ptxIs(t, "U64") || self.ptxIs(t, "F64") || self.mslIsPtr(t)) return (u32)8;
        return (u32)0;
        }

    // A scalar type's id; 0 for a type this cut does not print.
    final u32 spvType(String* t)
        {
        if (t == (String*)0) return (u32)0;
        if (spvNarrowBits(t) != (u32)0 || self.ptxIs(t, "I32") || self.ptxIs(t, "U32")) return _sMod.typeInt((u32)32);
        if (ptxIs(t, "I64") || self.ptxIs(t, "U64")) return _sMod.typeInt((u32)64);
        if (ptxIs(t, "F32")) return _sMod.typeFloat((u32)32);
        if (ptxIs(t, "F64")) return _sMod.typeFloat((u32)64);
        if (ptxIs(t, "Bool")) return _sMod.typeBool();
        return (u32)0;
        }

    final void spvEmit(u32 op, Array* w)
        {
        spvOp(_spvFn.code, op, w);
        }

    // A result-producing instruction: its new id.
    final u32 spvEmitR(u32 op, u32 t, Array* args)
        {
        u32 r = _sMod.newId();
        Array* w = new Array();
        w.add((Object*)Number.withU32(t));
        w.add((Object*)Number.withU32(r));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            w.add(args.get(i));
        spvOp(_spvFn.code, op, w);
        return r;
        }
    final Array* spvA1(u32 a) { return spvW((u32)1, a, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0); }
    final Array* spvA2(u32 a, u32 b) { return spvW((u32)2, a, b, (u32)0, (u32)0, (u32)0, (u32)0); }
    final Array* spvA3(u32 a, u32 b, u32 c) { return spvW((u32)3, a, b, c, (u32)0, (u32)0, (u32)0); }

    final u32 spvLocalVar(u32 t)
        {
        u32 p = _sMod.ptrType((u32)SPV_ST_FUNCTION, t);
        u32 v = _sMod.newId();
        spvOp(_spvFn.vars, (u32)SPV_VARIABLE, spvA3(p, v, (u32)SPV_ST_FUNCTION));
        return v;
        }

    final u32 spvLabel(void) { return _sMod.newId(); }
    final void spvPlace(u32 l) { spvEmit((u32)SPV_LABEL, spvA1(l)); }

    // a combined with b under a reduction's operator, as t. The kernel's
    // workgroup tree and the module's fold entry point (bug 645) both need it,
    // with the same instructions in the same order.
    final u32 spvReduceVal(String* op, bool isF, bool sgn, u32 t, u32 boolT, u32 a, u32 b)
        {
        if (op.equals(spvS("+")))
            return spvEmitR(isF ? (u32)SPV_FADD : (u32)SPV_IADD, t, spvA2(a, b));
        if (op.equals(spvS("*")))
            return spvEmitR(isF ? (u32)SPV_FMUL : (u32)SPV_IMUL, t, spvA2(a, b));
        if (op.equals(spvS("&")))
            return spvEmitR((u32)SPV_BITWISEAND, t, spvA2(a, b));
        if (op.equals(spvS("|")))
            return spvEmitR((u32)SPV_BITWISEOR, t, spvA2(a, b));
        if (op.equals(spvS("^")))
            return spvEmitR((u32)SPV_BITWISEXOR, t, spvA2(a, b));
        bool isMin = op.equals(spvS("min"));
        u32 cmpOp = isF ? (isMin ? (u32)SPV_FORDLESSTHAN : (u32)SPV_FORDGREATERTHAN)
                  : sgn ? (isMin ? (u32)SPV_SLESSTHAN : (u32)SPV_SGREATERTHAN)
                        : (isMin ? (u32)SPV_ULESSTHAN : (u32)SPV_UGREATERTHAN);
        u32 cmp = spvEmitR(cmpOp, boolT, spvA2(a, b));
        return spvEmitR((u32)SPV_SELECT, t, spvA3(cmp, a, b));
        }

    // A 32-bit value wrapped to narrow type t, in t's form.
    final u32 spvCanon(u32 v, String* t)
        {
        u32 bits = spvNarrowBits(t);
        if (bits == (u32)0)
            return v;
        u32 w32 = _sMod.typeInt((u32)32);
        if (!spvNarrowSigned(t))
            return spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(v, _sMod.u32c(((u32)1 << bits) - (u32)1)));
        u32 sh = _sMod.u32c((u32)32 - bits);
        u32 up = spvEmitR((u32)SPV_SHIFTLEFTLOGICAL, w32, spvA2(v, sh));
        return spvEmitR((u32)SPV_SHIFTRIGHTARITHMETIC, w32, spvA2(up, sh));
        }

    // An integer immediate as type `want`.
    final u32 spvImm(i64 iv, String* want)
        {
        if (want == (String*)0)
            return (u32)0;
        if (ptxIs(want, "Bool"))
            return _sMod.constBool(iv != (i64)0);
        u32 t = spvType(want);
        if (t == (u32)0 || spvIsFloat(want))
            return (u32)0;
        bool wide = spvWide(want);
        u32 nb = spvNarrowBits(want);
        if (nb != (u32)0)
            {
            u64 mask = ((u64)1 << (u64)nb) - (u64)1;
            iv = (i64)((u64)iv & mask);
            if (spvNarrowSigned(want) && ((iv >> (i64)(nb - (u32)1)) & (i64)1) != (i64)0)
                iv = iv - (i64)((u64)1 << (u64)nb);
            }
        return _sMod.constant(t, wide ? (u64)iv : (u64)(u32)iv, wide);
        }

    // An operand's value (an id); 0 when it cannot be.
    // The type a value takes in the kernel: a load of lo or hi that is only
    // truncated to 32 bits or less is a u32 in the 32-bit span form.
    final String* spvValType(IRValue* v)
        {
        if (_sSpan32 && _sNarrowVals != (Map*)0 && _sNarrowVals.get((Hashable*)self.mslKey(v)) != (Object*)0)
            return spvS("U32");
        return v.ty();
        }

    final u32 spvValue(IROperand* op, String* want)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            if (op.val() == (IRValue*)0) return (u32)0;
            Number* var = (Number*)_spvFn.varOf.get((Hashable*)self.mslKey(op.val()));
            if (var == (Number*)0) return (u32)0;
            return spvEmitR((u32)SPV_LOAD, spvType(spvValType(op.val())), spvA1(var.asU32()));
            }
        if (op.kind() == (u8)OPK_IMMI)
            return spvImm(op.imm(), want);
        if (op.kind() == (u8)OPK_IMMF)
            {
            u64 raw = (u64)0;
            String* h = op.fpHex();
            for (u32 i = (u32)0; i < h.byteLength(); i = i + (u32)1)
                {
                u8 c = h.byteAt(i);
                u64 d = c >= (u8)'a' ? (u64)(c - (u8)'a' + (u8)10) : c >= (u8)'A' ? (u64)(c - (u8)'A' + (u8)10) : (u64)(c - (u8)'0');
                raw = (raw << (u64)4) | d;
                }
            if (ptxIs(want, "F64"))
                return _sMod.constant(_sMod.typeFloat((u32)64), raw, true);
            if (!self.ptxIs(want, "F32"))
                return (u32)0;
            double dv = *(double*)(pointer)&raw;
            float fv = (float)dv;
            u32 bits = *(u32*)(pointer)&fv;
            return _sMod.constant(_sMod.typeFloat((u32)32), (u64)bits, false);
            }
        return (u32)0;
        }

    final void spvSetResult(IRInsn* ip, u32 v)
        {
        Number* var = (Number*)_spvFn.varOf.get((Hashable*)self.mslKey(ip.res()));
        spvEmit((u32)SPV_STORE, spvA2(var.asU32(), v));
        }

    // The id of a pointer to where `r` points.
    final u32 spvAddress(SpvRecipe* r)
        {
        u32 et = spvType(r.pointee);
        if (et == (u32)0)
            return (u32)0;
        Array* idx = new Array();
        for (u32 i = (u32)0; i < r.members.count(); i = i + (u32)1)
            idx.add(r.members.get(i));
        if (r.indexVar != (u32)0)
            idx.add((Object*)Number.withU32(spvEmitR((u32)SPV_LOAD, r.indexType, spvA1(r.indexVar))));
        else if (r.local)
            idx.add((Object*)Number.withU32(_sMod.u32c((u32)0)));   // the array itself: its first element
        if (idx.count() == (u32)0)
            return r.base;
        Array* a = new Array();
        a.add((Object*)Number.withU32(r.base));
        for (u32 i = (u32)0; i < idx.count(); i = i + (u32)1)
            a.add(idx.get(i));
        return spvEmitR((u32)SPV_ACCESSCHAIN, _sMod.ptrType(r.storage, et), a);
        }
    final u32 spvWordAddress(SpvRecipe* r)
        {
        u32 w32 = _sMod.typeInt((u32)32);
        u32 n = spvNarrowBytes(r.pointee);
        if (n == (u32)0 || r.indexVar == (u32)0)
            return (u32)0;
        u32 idx = spvEmitR((u32)SPV_LOAD, r.indexType, spvA1(r.indexVar));
        if (r.indexType != w32)
            idx = spvEmitR((u32)SPV_UCONVERT, w32, spvA1(idx));
        u32 word = spvEmitR((u32)SPV_SHIFTRIGHTLOGICAL, w32, spvA2(idx, _sMod.u32c(n == (u32)1 ? (u32)2 : (u32)1)));
        u32 low = spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(idx, _sMod.u32c(n == (u32)1 ? (u32)3 : (u32)1)));
        _spvShift = spvEmitR((u32)SPV_SHIFTLEFTLOGICAL, w32, spvA2(low, _sMod.u32c(n == (u32)1 ? (u32)3 : (u32)4)));
        Array* a = new Array();
        a.add((Object*)Number.withU32(r.base));
        for (u32 i = (u32)0; i < r.members.count(); i = i + (u32)1)
            a.add(r.members.get(i));
        a.add((Object*)Number.withU32(word));
        return spvEmitR((u32)SPV_ACCESSCHAIN, _sMod.ptrType(r.storage, w32), a);
        }

    // A narrow value from its word, in the value's own form.
    final u32 spvNarrowFrom(u32 word, u32 shift, String* t)
        {
        u32 w32 = _sMod.typeInt((u32)32);
        u32 v = spvEmitR((u32)SPV_SHIFTRIGHTLOGICAL, w32, spvA2(word, shift));
        if (ptxIs(t, "Bool"))
            {
            u32 b = spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(v, _sMod.u32c((u32)$FF)));
            u32 bt = _sMod.typeBool();
            return spvEmitR((u32)SPV_INOTEQUAL, bt, spvA2(b, _sMod.u32c((u32)0)));
            }
        if (spvNarrowSigned(t))
            return spvCanon(v, t);
        return spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(v, _sMod.u32c(((u32)1 << spvNarrowBits(t)) - (u32)1)));
        }

    final u32 spvNarrowLoad(SpvRecipe* r)
        {
        u32 w32 = _sMod.typeInt((u32)32);
        if (r.wordShift != (u32)0)
            {
            Array* a = new Array();
            a.add((Object*)Number.withU32(r.base));
            for (u32 i = (u32)0; i < r.members.count(); i = i + (u32)1)
                a.add(r.members.get(i));
            u32 p = spvEmitR((u32)SPV_ACCESSCHAIN, _sMod.ptrType(r.storage, w32), a);
            u32 word = spvEmitR((u32)SPV_LOAD, w32, spvA1(p));
            u32 sh = _sMod.u32c(r.wordShift - (u32)1);
            return spvNarrowFrom(word, sh, r.pointee);
            }
        u32 p = spvWordAddress(r);
        if (p == (u32)0)
            return (u32)0;
        u32 shift = _spvShift;
        u32 word = spvEmitR((u32)SPV_LOAD, w32, spvA1(p));
        return spvNarrowFrom(word, shift, r.pointee);
        }

    // A narrow field of the kernel's own copy of the object (a reduction), in
    // the word it shares: cleared, then set. As the reference's fieldStore.
    final bool spvFieldStore(SpvRecipe* r, u32 v)
        {
        u32 w32 = _sMod.typeInt((u32)32);
        Array* a = new Array();
        a.add((Object*)Number.withU32(r.base));
        for (u32 i = (u32)0; i < r.members.count(); i = i + (u32)1)
            a.add(r.members.get(i));
        u32 p = spvEmitR((u32)SPV_ACCESSCHAIN, _sMod.ptrType(r.storage, w32), a);
        u32 word = spvEmitR((u32)SPV_LOAD, w32, spvA1(p));
        u32 sh = r.wordShift - (u32)1;
        u32 low = ((u32)1 << ((u32)8 * spvNarrowBytes(r.pointee))) - (u32)1;   // a bool is a byte
        if (ptxIs(r.pointee, "Bool"))
            v = spvEmitR((u32)SPV_SELECT, w32, spvA3(v, _sMod.u32c((u32)1), _sMod.u32c((u32)0)));
        u32 bits = spvEmitR((u32)SPV_SHIFTLEFTLOGICAL, w32,
                            spvA2(spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(v, _sMod.u32c(low))), _sMod.u32c(sh)));
        u32 kept = spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(word, _sMod.u32c(~(low << sh))));
        spvEmit((u32)SPV_STORE, spvA2(p, spvEmitR((u32)SPV_BITWISEOR, w32, spvA2(kept, bits))));
        return true;
        }

    // Clear the element's bits in its word, then set them: two atomic
    // updates, so a neighbour writing the other bytes keeps its bytes.
    final bool spvNarrowStore(SpvRecipe* r, u32 v)
        {
        u32 w32 = _sMod.typeInt((u32)32);
        u32 p = spvWordAddress(r);
        if (p == (u32)0)
            return false;
        u32 shift = _spvShift;
        u32 mask = _sMod.u32c(spvNarrowBytes(r.pointee) == (u32)1 ? (u32)$FF : (u32)$FFFF);
        u32 bits = (u32)0;
        if (ptxIs(r.pointee, "Bool"))
            {
            u32 one = _sMod.u32c((u32)1);
            u32 zero = _sMod.u32c((u32)0);
            bits = spvEmitR((u32)SPV_SELECT, w32, spvA3(v, one, zero));
            }
        else
            bits = spvEmitR((u32)SPV_BITWISEAND, w32, spvA2(v, mask));
        u32 shm = spvEmitR((u32)SPV_SHIFTLEFTLOGICAL, w32, spvA2(mask, shift));
        u32 keep = spvEmitR((u32)SPV_NOT, w32, spvA1(shm));
        u32 scope = _sMod.u32c((u32)1);   // Device
        u32 sem = _sMod.u32c((u32)0);     // relaxed
        spvEmitR((u32)SPV_ATOMICAND, w32, spvW((u32)4, p, scope, sem, keep, (u32)0, (u32)0));
        u32 sb = spvEmitR((u32)SPV_SHIFTLEFTLOGICAL, w32, spvA2(bits, shift));
        spvEmitR((u32)SPV_ATOMICOR, w32, spvW((u32)4, p, scope, sem, sb, (u32)0, (u32)0));
        return true;
        }

    // An element of a buffer of 8-bit integers (#7): its address, a plain
    // load widened to the value's 32-bit form (sign-extended for I8, 0 or 1
    // compared for Bool), and a plain store of the low byte.
    final u32 spvByteAddress(SpvRecipe* r)
        {
        if (r.indexVar == (u32)0)
            return (u32)0;
        Array* a = new Array();
        a.add((Object*)Number.withU32(r.base));
        for (u32 i = (u32)0; i < r.members.count(); i = i + (u32)1)
            a.add(r.members.get(i));
        a.add((Object*)Number.withU32(spvEmitR((u32)SPV_LOAD, r.indexType, spvA1(r.indexVar))));
        return spvEmitR((u32)SPV_ACCESSCHAIN, _sMod.ptrType(r.storage, _sMod.typeInt8Storage()), a);
        }
    final u32 spvByteLoad(SpvRecipe* r)
        {
        u32 p = spvByteAddress(r);
        if (p == (u32)0)
            return (u32)0;
        u32 w32 = _sMod.typeInt((u32)32);
        u32 b = spvEmitR((u32)SPV_LOAD, _sMod.typeInt8Storage(), spvA1(p));
        if (ptxIs(r.pointee, "Bool"))
            {
            u32 wv = spvEmitR((u32)SPV_UCONVERT, w32, spvA1(b));
            return spvEmitR((u32)SPV_INOTEQUAL, _sMod.typeBool(), spvA2(wv, _sMod.u32c((u32)0)));
            }
        u32 wv = spvEmitR((u32)SPV_UCONVERT, w32, spvA1(b));
        return spvNarrowSigned(r.pointee) ? spvCanon(wv, r.pointee) : wv;
        }
    final bool spvByteStore(SpvRecipe* r, u32 v)
        {
        u32 p = spvByteAddress(r);
        if (p == (u32)0)
            return false;
        u32 w32 = _sMod.typeInt((u32)32);
        u32 wv = v;
        if (ptxIs(r.pointee, "Bool"))
            wv = spvEmitR((u32)SPV_SELECT, w32, spvA3(v, _sMod.u32c((u32)1), _sMod.u32c((u32)0)));
        spvEmit((u32)SPV_STORE, spvA2(p, spvEmitR((u32)SPV_UCONVERT, _sMod.typeInt8Storage(), spvA1(wv))));
        return true;
        }

    final bool spvBinary(IRInsn* ip)
        {
        String* t = ip.res().ty();
        u32 ty = spvType(t);
        u32 a = spvValue((IROperand*)ip.ops().get((u32)0), t);
        u32 b = spvValue((IROperand*)ip.ops().get((u32)1), t);
        if (ty == (u32)0 || a == (u32)0 || b == (u32)0)
            return false;
        String* o = ip.op();
        u32 nb = spvNarrowBits(t);
        if (nb != (u32)0)
            {
            bool wantsUnsigned = o.equals(spvS("UDiv")) || o.equals(spvS("URem")) || o.equals(spvS("LShr"));
            bool wantsSigned = o.equals(spvS("SDiv")) || o.equals(spvS("SRem")) || o.equals(spvS("AShr"));
            String* as = (String*)0;
            if (wantsUnsigned && spvNarrowSigned(t))
                as = spvS(nb == (u32)8 ? "U8" : "U16");
            else if (wantsSigned && !spvNarrowSigned(t))
                as = spvS(nb == (u32)8 ? "I8" : "I16");
            if (as != (String*)0)
                {
                a = spvCanon(a, as);
                if (!o.equals(spvS("LShr")) && !o.equals(spvS("AShr")))
                    b = spvCanon(b, as);
                }
            }
        bool isBool = self.ptxIs(t, "Bool");
        u32 op = (u32)0;
        if (o.equals(spvS("Add"))) op = (u32)SPV_IADD;
        else if (o.equals(spvS("Sub"))) op = (u32)SPV_ISUB;
        else if (o.equals(spvS("Mul"))) op = (u32)SPV_IMUL;
        else if (o.equals(spvS("UDiv"))) op = (u32)SPV_UDIV;
        else if (o.equals(spvS("SDiv"))) op = (u32)SPV_SDIV;
        else if (o.equals(spvS("URem"))) op = (u32)SPV_UMOD;
        else if (o.equals(spvS("SRem"))) op = (u32)SPV_SREM;
        else if (o.equals(spvS("And"))) op = isBool ? (u32)SPV_LOGICALAND : (u32)SPV_BITWISEAND;
        else if (o.equals(spvS("Or"))) op = isBool ? (u32)SPV_LOGICALOR : (u32)SPV_BITWISEOR;
        else if (o.equals(spvS("Xor"))) op = isBool ? (u32)SPV_LOGICALNOTEQUAL : (u32)SPV_BITWISEXOR;
        else if (o.equals(spvS("Shl"))) op = (u32)SPV_SHIFTLEFTLOGICAL;
        else if (o.equals(spvS("LShr"))) op = (u32)SPV_SHIFTRIGHTLOGICAL;
        else if (o.equals(spvS("AShr"))) op = (u32)SPV_SHIFTRIGHTARITHMETIC;
        else if (o.equals(spvS("FAdd"))) op = (u32)SPV_FADD;
        else if (o.equals(spvS("FSub"))) op = (u32)SPV_FSUB;
        else if (o.equals(spvS("FMul"))) op = (u32)SPV_FMUL;
        else if (o.equals(spvS("FDiv")))
            {
            // An accuracy block divides in integer arithmetic (the reference explains).
            if (!_mFast)
                {
                u32 fid = spvHelperId(spvS("xcFdivRn"));
                if (fid == (u32)0)
                    {
                    self.parBecause(spvS("it divides floats, which a Vulkan GPU does not round exactly, and the block's goal is accuracy"));
                    return false;
                    }
                spvSetResult(ip, spvEmitR((u32)SPV_FUNCTIONCALL, ty, spvA3(fid, a, b)));
                return true;
                }
            op = (u32)SPV_FDIV;
            }
        else
            return false;
        bool isSgn = self.ptxIs(t, "I8") || self.ptxIs(t, "I16") || self.ptxIs(t, "I32") || self.ptxIs(t, "I64");
        // A signed divide carries the SIGNED type on the instruction; a signed
        // REMAINDER is not OpSRem at all (the reference explains both, bug 649).
        if (isSgn && (op == (u32)SPV_SDIV || op == (u32)SPV_SREM))
            {
            u32 sg = _sMod.typeIntSigned(self.ptxIs(t, "I64") ? (u32)64 : (u32)32);
            u32 sa = spvEmitR((u32)SPV_BITCAST, sg, spvA1(a));
            u32 sb = spvEmitR((u32)SPV_BITCAST, sg, spvA1(b));
            u32 q = spvEmitR((u32)SPV_SDIV, sg, spvA2(sa, sb));
            u32 qu = spvEmitR((u32)SPV_BITCAST, ty, spvA1(q));
            if (op == (u32)SPV_SDIV)
                {
                spvSetResult(ip, spvCanon(qu, t));
                return true;
                }
            u32 p = spvEmitR((u32)SPV_IMUL, ty, spvA2(qu, b));
            spvSetResult(ip, spvCanon(spvEmitR((u32)SPV_ISUB, ty, spvA2(a, p)), t));
            return true;
            }
        u32 r = spvEmitR(op, ty, spvA2(a, b));
        // NoContraction in an accuracy block, so no driver fuses a multiply
        // into the add after it (the reference explains).
        if (!_mFast && (op == (u32)SPV_FADD || op == (u32)SPV_FSUB || op == (u32)SPV_FMUL))
            spvOp(_sMod.decos, (u32)SPV_DECORATE, spvA2(r, (u32)SPV_DEC_NOCONTRACTION));
        spvSetResult(ip, spvCanon(r, t));
        return true;
        }

    final bool spvCompare(IRInsn* ip)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
        String* t = self.mslTypeOf(o0) != (String*)0 ? self.mslTypeOf(o0) : self.mslTypeOf(o1);
        if (t == (String*)0)
            return false;
        u32 a = spvValue(o0, t);
        u32 b = spvValue(o1, t);
        if (a == (u32)0 || b == (u32)0)
            return false;
        String* p = ip.pred();
        u32 op = (u32)0;
        if (ip.op().equals(spvS("FCmp")))
            {
            if (p.equals(spvS("OEQ"))) op = (u32)SPV_FORDEQUAL;
            else if (p.equals(spvS("ONE"))) op = (u32)SPV_FUNORDNOTEQUAL;
            else if (p.equals(spvS("OLT"))) op = (u32)SPV_FORDLESSTHAN;
            else if (p.equals(spvS("OGT"))) op = (u32)SPV_FORDGREATERTHAN;
            else if (p.equals(spvS("OLE"))) op = (u32)SPV_FORDLESSTHANEQUAL;
            else if (p.equals(spvS("OGE"))) op = (u32)SPV_FORDGREATERTHANEQUAL;
            else return false;
            }
        else
            {
            if (p.equals(spvS("EQ"))) op = (u32)SPV_IEQUAL;
            else if (p.equals(spvS("NE"))) op = (u32)SPV_INOTEQUAL;
            else if (p.equals(spvS("SLT"))) op = (u32)SPV_SLESSTHAN;
            else if (p.equals(spvS("SGT"))) op = (u32)SPV_SGREATERTHAN;
            else if (p.equals(spvS("SLE"))) op = (u32)SPV_SLESSTHANEQUAL;
            else if (p.equals(spvS("SGE"))) op = (u32)SPV_SGREATERTHANEQUAL;
            else if (p.equals(spvS("ULT"))) op = (u32)SPV_ULESSTHAN;
            else if (p.equals(spvS("UGT"))) op = (u32)SPV_UGREATERTHAN;
            else if (p.equals(spvS("ULE"))) op = (u32)SPV_ULESSTHANEQUAL;
            else if (p.equals(spvS("UGE"))) op = (u32)SPV_UGREATERTHANEQUAL;
            else return false;
            if (ptxIs(t, "Bool"))
                {
                if (p.equals(spvS("EQ"))) op = (u32)SPV_LOGICALEQUAL;
                else if (p.equals(spvS("NE"))) op = (u32)SPV_LOGICALNOTEQUAL;
                else return false;
                }
            }
        u32 r = spvEmitR(op, _sMod.typeBool(), spvA2(a, b));
        // The full form's entry and latch tests (spvFullCmps): true and false
        // there, as they are anyway when every thread has its one item.
        String* fc = _sFullC != (u32)0 && ip.res() != (IRValue*)0 ? (String*)_sFullCmps.get((Hashable*)self.mslKey(ip.res())) : (String*)0;
        if (fc != (String*)0 && fc.equals(spvS("h")))
            r = spvEmitR((u32)SPV_LOGICALOR, _sMod.typeBool(), spvA2(_sFullC, r));
        else if (fc != (String*)0)
            r = spvEmitR((u32)SPV_LOGICALAND, _sMod.typeBool(),
                         spvA2(spvEmitR((u32)SPV_LOGICALNOT, _sMod.typeBool(), spvA1(_sFullC)), r));
        spvSetResult(ip, r);
        return true;
        }

    final bool spvConvert(IRInsn* ip)
        {
        String* rt = ip.res().ty();
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
        if (o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0)
            st = _sSpan32 && _sNarrowVals.get((Hashable*)self.mslKey(o0.val())) != (Object*)0 ? spvS("U32") : st;
        u32 a = spvValue(o0, st);
        u32 ty = spvType(rt);
        if (a == (u32)0 || ty == (u32)0 || spvType(st) == (u32)0)
            return false;
        bool sameWidth = spvWidth(st) == spvWidth(rt);
        u32 v = (u32)0;
        String* o = ip.op();
        if (ptxIs(st, "Bool") && !self.ptxIs(rt, "Bool"))
            {
            if (spvIsFloat(rt))
                return false;
            u32 one = spvImm((i64)1, rt);
            u32 zero = spvImm((i64)0, rt);
            v = spvEmitR((u32)SPV_SELECT, ty, spvA3(a, one, zero));
            }
        else if (ptxIs(rt, "Bool"))
            {
            if (ptxIs(st, "Bool"))
                v = a;
            else if (spvIsFloat(st))
                return false;
            else
                v = spvEmitR((u32)SPV_INOTEQUAL, ty, spvA2(a, spvImm((i64)0, st)));
            }
        else
            {
            u32 sb = spvNarrowBits(st);
            bool sWide = spvWide(st);
            bool rWide = spvWide(rt);
            u32 w32 = _sMod.typeInt((u32)32);
            if (o.equals(spvS("ZExt")) || o.equals(spvS("SExt")) || o.equals(spvS("Trunc")) || o.equals(spvS("Copy")))
                {
                if (spvIsFloat(st) || spvIsFloat(rt))
                    {
                    if (!o.equals(spvS("Copy")))
                        return false;
                    if (spvIsFloat(st) && spvIsFloat(rt))
                        v = sameWidth ? a : spvEmitR((u32)SPV_FCONVERT, ty, spvA1(a));
                    else if (spvIsFloat(rt))
                        v = spvEmitR(ptxSigned(st) ? (u32)SPV_CONVERTSTOF : (u32)SPV_CONVERTUTOF, ty, spvA1(a));
                    else
                        v = spvCanon(spvEmitR(self.ptxSigned(rt) ? (u32)SPV_CONVERTFTOS : (u32)SPV_CONVERTFTOU, ty, spvA1(a)), rt);
                    }
                else
                    {
                    bool extSigned = o.equals(spvS("SExt")) || (!o.equals(spvS("ZExt")) && self.ptxSigned(st));
                    u32 x = a;
                    if (sb != (u32)0 && extSigned != spvNarrowSigned(st))
                        {
                        String* as = extSigned ? spvS(sb == (u32)8 ? "I8" : "I16") : spvS(sb == (u32)8 ? "U8" : "U16");
                        x = spvCanon(x, as);
                        }
                    if (sWide != rWide)
                        x = spvEmitR(rWide ? (extSigned ? (u32)SPV_SCONVERT : (u32)SPV_UCONVERT) : (u32)SPV_UCONVERT,
                                     rWide ? _sMod.typeInt((u32)64) : w32, spvA1(x));
                    v = spvCanon(x, rt);
                    }
                }
            else if (o.equals(spvS("SIToFp")))
                v = spvEmitR((u32)SPV_CONVERTSTOF, ty, spvA1(a));
            else if (o.equals(spvS("UIToFp")))
                v = spvEmitR((u32)SPV_CONVERTUTOF, ty, spvA1(a));
            else if (o.equals(spvS("FpToSI")))
                v = spvCanon(spvEmitR((u32)SPV_CONVERTFTOS, ty, spvA1(a)), rt);
            else if (o.equals(spvS("FpToUI")))
                v = spvCanon(spvEmitR((u32)SPV_CONVERTFTOU, ty, spvA1(a)), rt);
            else
                return false;
            }
        spvSetResult(ip, v);
        return true;
        }

    // A maths call by name: its GLSL.std.450 instruction, or 0.
    final u32 spvGlslFor(String* callee, String* t)
        {
        String* m = self.ptxMathName(callee);
        bool f = spvIsFloat(t);
        if (m.equals(spvS("floor"))) return f ? (u32)GLSL_FLOOR : (u32)0;
        if (m.equals(spvS("abs")) || m.equals(spvS("fabs"))) return f ? (u32)GLSL_FABS : self.ptxSigned(t) ? (u32)GLSL_SABS : (u32)0;
        if (m.equals(spvS("min"))) return f ? (u32)GLSL_FMIN : self.ptxSigned(t) ? (u32)GLSL_SMIN : (u32)GLSL_UMIN;
        if (m.equals(spvS("max"))) return f ? (u32)GLSL_FMAX : self.ptxSigned(t) ? (u32)GLSL_SMAX : (u32)GLSL_UMAX;
        if (!_mFast)
            return (u32)0;
        if (m.equals(spvS("sqrt"))) return (u32)GLSL_SQRT;
        if (m.equals(spvS("sin"))) return (u32)GLSL_SIN;
        if (m.equals(spvS("cos"))) return (u32)GLSL_COS;
        if (m.equals(spvS("exp"))) return (u32)GLSL_EXP;
        if (m.equals(spvS("ln")) || m.equals(spvS("log"))) return (u32)GLSL_LOG;
        if (m.equals(spvS("pow"))) return (u32)GLSL_POW;
        if (m.equals(spvS("fma"))) return (u32)GLSL_FMA;
        return (u32)0;
        }

    final bool spvIsMaths(String* callee)
        {
        String* m = self.ptxMathName(callee);
        return m.equals(spvS("sqrt")) || m.equals(spvS("sin")) || m.equals(spvS("cos")) || m.equals(spvS("exp")) ||
               m.equals(spvS("ln")) || m.equals(spvS("log")) || m.equals(spvS("pow")) || m.equals(spvS("floor")) ||
               m.equals(spvS("fma")) || m.equals(spvS("abs")) || m.equals(spvS("fabs")) || m.equals(spvS("min")) ||
               m.equals(spvS("max"));
        }

    // The SPIR-V function of a function of the program the kernel calls,
    // printed once as a helper; 0 (with the reason) when it cannot be. As the
    // reference's spvHelperId.
    final u32 spvHelperId(String* callee)
        {
        Number* fid = (Number*)_sHelpers.get((Hashable*)callee);
        if (fid != (Number*)0)
            return fid.asU32();
        IRFunc* target = (IRFunc*)0;
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)_m.funcs().get(i)).name().equals(callee))
                target = (IRFunc*)_m.funcs().get(i);
        if (target == (IRFunc*)0)
            return (u32)0;
        u32 f = spvHelper(target);
        if (f == (u32)0)
            {
            self.parBecause(parCallFailed(callee, _mHelperWhy));
            return (u32)0;
            }
        _sHelpers.set((Hashable*)callee, (Object*)Number.withU32(f));
        return f;
        }

    final bool spvCall(IRInsn* ip)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* callee = o0.name();
        if (callee.equals(spvS("_xtc_sinit_run")) || callee.hasSuffix(spvS("$init")))
            return true;
        String* rt = ip.res() != (IRValue*)0 ? ip.res().ty() : (String*)0;
        bool isVoid = rt == (String*)0 || self.ptxIs(rt, "Mem");
        Array* args = new Array();
        for (u32 k = (u32)1; k < ip.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)ip.ops().get(k);
            if (o.kind() == (u8)OPK_USE && self.ptxIs(mslTypeOf(o), "Mem"))
                continue;
            String* at = o.kind() == (u8)OPK_USE ? self.mslTypeOf(o) : rt;
            u32 v = spvValue(o, at);
            if (v == (u32)0)
                return false;
            args.add((Object*)Number.withU32(v));
            }
        // A float's bits and back (ParSoftFloat.xc): a bit cast.
        if ((callee.equals(spvS("xcF32Bits")) || callee.equals(spvS("xcF32FromBits"))) && args.count() == (u32)1)
            {
            spvSetResult(ip, spvEmitR((u32)SPV_BITCAST, spvType(rt), spvA1(((Number*)args.get((u32)0)).asU32())));
            return true;
            }
        if (spvIsMaths(callee))
            {
            if (isVoid || args.count() == (u32)0)
                return false;
            u32 g = spvGlslFor(callee, rt);
            // An accuracy block's square root (the reference explains).
            if (g == (u32)0 && !_mFast && self.ptxIs(rt, "F32") && self.ptxMathName(callee).equals(spvS("sqrt")))
                {
                u32 sfid = spvHelperId(spvS("xcFsqrtRn"));
                if (sfid != (u32)0)
                    {
                    spvSetResult(ip, spvEmitR((u32)SPV_FUNCTIONCALL, spvType(rt), spvA2(sfid, ((Number*)args.get((u32)0)).asU32())));
                    return true;
                    }
                }
            if (g == (u32)0)
                {
                String* w = spvS("it calls ");
                w.append(self.parShown(callee));
                w.appendCString(", which a Vulkan GPU has only in an approximate form, and the block's goal is accuracy");
                self.parBecause(w);
                return false;
                }
            Array* a = new Array();
            a.add((Object*)Number.withU32(_sMod.glslImport()));
            a.add((Object*)Number.withU32(g));
            for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
                a.add(args.get(i));
            spvSetResult(ip, spvEmitR((u32)SPV_EXTINST, spvType(rt), a));
            return true;
            }
        // A function of the program: printed once, as a SPIR-V function.
        u32 hf = spvHelperId(callee);
        if (hf == (u32)0)
            return false;
        Number* fid = Number.withU32(hf);
        u32 ret = isVoid ? _sMod.typeVoid() : spvType(rt);
        if (ret == (u32)0)
            return false;
        Array* a = new Array();
        a.add((Object*)fid);
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            a.add(args.get(i));
        u32 r = spvEmitR((u32)SPV_FUNCTIONCALL, ret, a);
        if (!isVoid)
            spvSetResult(ip, r);
        return true;
        }

    final bool spvStatement(IRInsn* ip)
        {
        IRValue* res = ip.res();
        String* rt = res != (IRValue*)0 ? res.ty() : (String*)0;
        String* o = ip.op();
        // A value nothing reads, from an instruction with no other effect.
        if (res != (IRValue*)0 && !self.ptxIs(rt, "Mem") && _spvFn.used.get((Hashable*)self.mslKey(res)) == (Object*)0 &&
            !o.equals(spvS("Call")) && !o.equals(spvS("Store")))
            return true;
        IROperand* o0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
        if (o.equals(spvS("Const")))
            {
            u32 v = spvValue(o0, rt);
            if (v == (u32)0) return false;
            spvSetResult(ip, v);
            return true;
            }
        if (o.equals(spvS("Add")) || o.equals(spvS("Sub")) || o.equals(spvS("Mul")) || o.equals(spvS("UDiv")) ||
            o.equals(spvS("SDiv")) || o.equals(spvS("URem")) || o.equals(spvS("SRem")) || o.equals(spvS("And")) ||
            o.equals(spvS("Or")) || o.equals(spvS("Xor")) || o.equals(spvS("Shl")) || o.equals(spvS("LShr")) ||
            o.equals(spvS("AShr")) || o.equals(spvS("FAdd")) || o.equals(spvS("FSub")) || o.equals(spvS("FMul")) ||
            o.equals(spvS("FDiv")))
            return spvBinary(ip);
        if (o.equals(spvS("Not")))
            {
            u32 a = spvValue(o0, rt);
            if (a == (u32)0) return false;
            spvSetResult(ip, spvCanon(spvEmitR(self.ptxIs(rt, "Bool") ? (u32)SPV_LOGICALNOT : (u32)SPV_NOT, spvType(rt), spvA1(a)), rt));
            return true;
            }
        if (o.equals(spvS("Neg")) || o.equals(spvS("FNeg")))
            {
            u32 a = spvValue(o0, rt);
            if (a == (u32)0) return false;
            spvSetResult(ip, spvCanon(spvEmitR(spvIsFloat(rt) ? (u32)SPV_FNEGATE : (u32)SPV_SNEGATE, spvType(rt), spvA1(a)), rt));
            return true;
            }
        if (o.equals(spvS("FSqrt")))
            {
            u32 a = spvValue(o0, rt);
            if (a == (u32)0) return false;
            if (!_mFast)
                {
                u32 fid = self.ptxIs(rt, "F32") ? spvHelperId(spvS("xcFsqrtRn")) : (u32)0;
                if (fid == (u32)0)
                    {
                    self.parBecause(spvS("it takes a square root, which a Vulkan GPU does not round exactly, and the block's goal is accuracy"));
                    return false;
                    }
                spvSetResult(ip, spvEmitR((u32)SPV_FUNCTIONCALL, spvType(rt), spvA2(fid, a)));
                return true;
                }
            spvSetResult(ip, spvEmitR((u32)SPV_EXTINST, spvType(rt), spvA3(_sMod.glslImport(), (u32)GLSL_SQRT, a)));
            return true;
            }
        if (o.equals(spvS("ICmp")) || o.equals(spvS("FCmp")))
            return spvCompare(ip);
        if (o.equals(spvS("ZExt")) || o.equals(spvS("SExt")) || o.equals(spvS("Trunc")) || o.equals(spvS("SIToFp")) ||
            o.equals(spvS("UIToFp")) || o.equals(spvS("FpToSI")) || o.equals(spvS("FpToUI")) || o.equals(spvS("Copy")))
            return spvConvert(ip);
        if (o.equals(spvS("Select")))
            {
            u32 c = spvValue(o0, (String*)0);
            u32 a = spvValue((IROperand*)ip.ops().get((u32)1), rt);
            u32 b = spvValue((IROperand*)ip.ops().get((u32)2), rt);
            if (c == (u32)0 || a == (u32)0 || b == (u32)0) return false;
            spvSetResult(ip, spvEmitR((u32)SPV_SELECT, spvType(rt), spvA3(c, a, b)));
            return true;
            }
        if (o.equals(spvS("FieldAddr")))
            {
            i64 k = self.mslSelfField(ip);
            if (k >= (i64)0)
                {
                // The slot of a captured array: only ever loaded, as the buffer.
                if (mslIsPtr(_mObj.typeAt((u32)k)))
                    return true;
                Number* m = (Number*)_sMember.get((Hashable*)String.withI64(k));
                if (m == (Number*)0) return false;
                SpvRecipe* r = new SpvRecipe();
                r.base = _sLocalObj;
                r.storage = (u32)SPV_ST_FUNCTION;
                r.members = new Array();
                r.members.add((Object*)Number.withU32(_sMod.u32c(m.asU32())));
                r.pointee = _mObj.typeAt((u32)k);
                // The 32-bit span form holds lo and hi as u32.
                if (_sSpan32 && (k == (i64)1 || k == (i64)2))
                    r.pointee = spvS("U32");
                Number* sh = (Number*)_sNarrowShift.get((Hashable*)String.withI64(k));
                if (sh != (Number*)0)
                    r.wordShift = sh.asU32() + (u32)1;
                _spvFn.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
                return true;
                }
            return false;
            }
        if (o.equals(spvS("ElementAddr")))
            {
            SpvRecipe* b = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 ? (SpvRecipe*)_spvFn.recipeOf.get((Hashable*)self.mslKey(o0.val())) : (SpvRecipe*)0;
            String* pe = self.mslPointee(rt);
            if (b == (SpvRecipe*)0 || pe == (String*)0) return false;
            // A work item's array holds one slot per element of its own type:
            // an index by any other width would land elsewhere. As the reference.
            if (b.local && self.mslWidth(pe) != self.mslWidth(b.pointee)) return false;
            IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
            // A constant index is 64-bit unless it is a 32-bit one (a field's
            // word in an array of structs): the 32-bit span form then needs
            // no 64-bit integer for it.
            String* it = o1.kind() == (u8)OPK_USE ? self.mslTypeOf(o1) : spvS("I64");
            if (o1.kind() == (u8)OPK_IMMI && o1.ty() != (String*)0 && (self.ptxIs(o1.ty(), "U32") || self.ptxIs(o1.ty(), "I32")))
                it = o1.ty();
            u32 ity = spvType(it);
            u32 idx = spvValue(o1, it);
            if (ity == (u32)0 || idx == (u32)0 || spvIsFloat(it) || self.ptxIs(it, "Bool")) return false;
            SpvRecipe* r = b.copy();
            r.pointee = pe;
            if (b.indexVar != (u32)0)
                {
                u32 prev = spvEmitR((u32)SPV_LOAD, b.indexType, spvA1(b.indexVar));
                if (b.indexType != ity)
                    idx = spvEmitR(ptxSigned(it) ? (u32)SPV_SCONVERT : (u32)SPV_UCONVERT, b.indexType, spvA1(idx));
                idx = spvEmitR((u32)SPV_IADD, b.indexType, spvA2(prev, idx));
                ity = b.indexType;
                }
            else if (b.storage == (u32)SPV_ST_FUNCTION && !b.local)
                return false;
            r.indexVar = spvLocalVar(ity);
            r.indexType = ity;
            spvEmit((u32)SPV_STORE, spvA2(r.indexVar, idx));
            _spvFn.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
            return true;
            }
        if (o.equals(spvS("Bitcast")))
            {
            if (mslIsPtr(rt))
                {
                SpvRecipe* b = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 ? (SpvRecipe*)_spvFn.recipeOf.get((Hashable*)self.mslKey(o0.val())) : (SpvRecipe*)0;
                String* pe = self.mslPointee(rt);
                if (b == (SpvRecipe*)0 || spvWidth(b.pointee) != spvWidth(pe) || spvType(b.pointee) != spvType(pe))
                    return false;
                _spvFn.recipeOf.set((Hashable*)self.mslKey(res), (Object*)b);
                return true;
                }
            String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
            u32 a = spvValue(o0, st);
            if (a == (u32)0 || spvWidth(st) != spvWidth(rt) || spvType(rt) == (u32)0) return false;
            // A narrow result is re-wrapped to its own form. As the reference.
            spvSetResult(ip, spvCanon(spvEmitR((u32)SPV_BITCAST, spvType(rt), spvA1(a)), rt));
            return true;
            }
        if (o.equals(spvS("Load")))
            {
            String* buf = res != (IRValue*)0 ? (String*)_mBufOf.get((Hashable*)self.mslKey(res)) : (String*)0;
            if (buf != (String*)0)
                {
                SpvRecipe* r = new SpvRecipe();
                String* key = spvS("f");
                key.append(buf);
                r.base = ((Number*)_sBufVar.get((Hashable*)key)).asU32();
                r.storage = (u32)SPV_ST_STORAGEBUFFER;
                r.members = new Array();
                r.members.add((Object*)Number.withU32(_sMod.u32c((u32)0)));
                r.pointee = self.mslPointee(rt);
                r.words = _sWordBufs.get((Hashable*)String.withU32(r.base)) != (Object*)0;
                r.bytes = _sByteBufs.get((Hashable*)String.withU32(r.base)) != (Object*)0;
            r.bytes = _sByteBufs.get((Hashable*)String.withU32(r.base)) != (Object*)0;
                _spvFn.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
                return true;
                }
            if (mslIsPtr(rt)) return false;
            if (parSinitFlag(o0))
                {
                spvSetResult(ip, spvImm((i64)2, rt));
                return true;
                }
            SpvRecipe* r = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 ? (SpvRecipe*)_spvFn.recipeOf.get((Hashable*)self.mslKey(o0.val())) : (SpvRecipe*)0;
            u32 ty = spvType(spvValType(res));
            if (r == (SpvRecipe*)0 || ty == (u32)0 || spvType(r.pointee) != ty) return false;
            if (r.bytes)
                {
                u32 bv = spvByteLoad(r);
                if (bv == (u32)0) return false;
                spvSetResult(ip, bv);
                return true;
                }
            if (r.words || r.wordShift != (u32)0)
                {
                u32 nv = spvNarrowLoad(r);
                if (nv == (u32)0) return false;
                spvSetResult(ip, nv);
                return true;
                }
            u32 p = spvAddress(r);
            if (p == (u32)0) return false;
            spvSetResult(ip, spvEmitR((u32)SPV_LOAD, ty, spvA1(p)));
            return true;
            }
        if (o.equals(spvS("Store")))
            {
            if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0) return false;
            SpvRecipe* r = (SpvRecipe*)_spvFn.recipeOf.get((Hashable*)self.mslKey(o0.val()));
            if (r == (SpvRecipe*)0) return false;
            u32 v = spvValue((IROperand*)ip.ops().get((u32)1), r.pointee);
            if (r.wordShift != (u32)0)
                return v != (u32)0 && spvFieldStore(r, v);
            if (r.bytes)
                return v != (u32)0 && spvByteStore(r, v);
            if (r.words)
                return v != (u32)0 && spvNarrowStore(r, v);
            u32 p = spvAddress(r);
            if (v == (u32)0 || p == (u32)0) return false;
            spvEmit((u32)SPV_STORE, spvA2(p, v));
            return true;
            }
        if (o.equals(spvS("Call")))
            return spvCall(ip);
        if (o.equals(spvS("AddrOf")))
            {
            if (res != (IRValue*)0 && _mSinit.get((Hashable*)self.mslKey(res)) != (Object*)0)
                return true;
            // A work item's own array: a Function variable of an array type,
            // an element a slot of its SPIR-V type (a narrow one in 32 bits).
            // Ids in the reference's order: the length constant, the array
            // type, the variable, then its pointer type.
            String* lk = res != (IRValue*)0 ? (String*)_mLocalOf.get((Hashable*)self.mslKey(res)) : (String*)0;
            if (lk != (String*)0)
                {
                u32 k = (u32)0;
                while (k < _mLocalBytes.count() && !String.withU32(k).equals(lk)) k = k + (u32)1;
                if (k >= _mLocalBytes.count()) return false;
                String* et = (String*)_mLocalElem.get(k);
                u32 ety = spvType(et);
                u32 ew = self.mslWidth(et);
                if (ety == (u32)0 || ew == (u32)0) return false;
                Number* var = (Number*)_spvFn.locals.get((Hashable*)lk);
                if (var == (Number*)0)
                    {
                    u32 n = ((Number*)_mLocalBytes.get(k)).asU32() / ew;
                    String* akey = spvS("farr");
                    akey.append(String.withU32(ety)); akey.appendCString("_"); akey.append(String.withU32(n));
                    u32 nc = _sMod.u32c(n);
                    u32 arrT = _sMod.cached(akey, (u32)SPV_TYPEARRAY, spvA2(ety, nc), true);
                    u32 v = _sMod.newId();
                    u32 pt = _sMod.ptrType((u32)SPV_ST_FUNCTION, arrT);
                    spvOp(_spvFn.vars, (u32)SPV_VARIABLE, spvA3(pt, v, (u32)SPV_ST_FUNCTION));
                    var = Number.withU32(v);
                    _spvFn.locals.set((Hashable*)lk, (Object*)var);
                    }
                SpvRecipe* lr = new SpvRecipe();
                lr.base = var.asU32();
                lr.storage = (u32)SPV_ST_FUNCTION;
                lr.members = new Array();
                lr.pointee = self.mslPointee(rt);
                lr.local = true;
                _spvFn.recipeOf.set((Hashable*)self.mslKey(res), (Object*)lr);
                return true;
                }
            String* g = res != (IRValue*)0 ? (String*)_mGlobalOf.get((Hashable*)self.mslKey(res)) : (String*)0;
            if (g == (String*)0) return false;
            u32 gi = (u32)0;
            for (u32 q = (u32)0; q < _mGlobals.count(); q = q + (u32)1)
                if (((String*)_mGlobals.get(q)).equals(g)) { gi = q; break; }
            SpvRecipe* r = new SpvRecipe();
            String* key = spvS("g");
            key.append(String.withU32(gi));
            r.base = ((Number*)_sBufVar.get((Hashable*)key)).asU32();
            r.storage = (u32)SPV_ST_STORAGEBUFFER;
            r.members = new Array();
            r.members.add((Object*)Number.withU32(_sMod.u32c((u32)0)));
            r.pointee = self.mslPointee(rt);
            r.words = _sWordBufs.get((Hashable*)String.withU32(r.base)) != (Object*)0;
            r.bytes = _sByteBufs.get((Hashable*)String.withU32(r.base)) != (Object*)0;
            _spvFn.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
            return true;
            }
        if (o.equals(spvS("DbgValue")))
            return true;
        return false;
        }

    // The phi copies for the edge from -> target (each incoming value read
    // before any is written), each conditional on `cond` when it is not 0.
    final bool spvEdge(IRBlock* from, IRBlock* target, u32 cond, bool whenTrue, Array* vals, Array* dsts)
        {
        for (u32 i = (u32)0; i < target.phis().count(); i = i + (u32)1)
            {
            IRInsn* ph = (IRInsn*)target.phis().get(i);
            if (ph.res() == (IRValue*)0 || self.ptxIs(ph.res().ty(), "Mem")) continue;
            if (mslIsPtr(ph.res().ty())) return false;
            IROperand* inc = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < ph.ops().count(); k = k + (u32)2)
                if (((IROperand*)ph.ops().get(k)).blk() == from)
                    inc = (IROperand*)ph.ops().get(k + (u32)1);
            if (inc == (IROperand*)0) return false;
            u32 v = spvValue(inc, ph.res().ty());
            if (v == (u32)0) return false;
            Number* dst = (Number*)_spvFn.varOf.get((Hashable*)self.mslKey(ph.res()));
            if (cond != (u32)0)
                {
                u32 ty = spvType(ph.res().ty());
                u32 old = spvEmitR((u32)SPV_LOAD, ty, spvA1(dst.asU32()));
                v = spvEmitR((u32)SPV_SELECT, ty, whenTrue ? spvA3(cond, v, old) : spvA3(cond, old, v));
                }
            vals.add((Object*)Number.withU32(v));
            dsts.add((Object*)dst);
            }
        return true;
        }

    final void spvStores(Array* vals, Array* dsts)
        {
        for (u32 k = (u32)0; k < vals.count(); k = k + (u32)1)
            spvEmit((u32)SPV_STORE, spvA2(((Number*)dsts.get(k)).asU32(), ((Number*)vals.get(k)).asU32()));
        }

    final u32 spvBlockNumber(IRBlock* b)
        {
        return _sMod.u32c(((Number*)_spvFn.blockNum.get((Hashable*)b.name())).asU32());
        }

    // The function's blocks as the dispatch loop.
    final bool spvDispatch(IRFunc* f, u32 mergeLabel, u32 guard)
        {
        SpvFn* fn = _spvFn;
        u32 head = spvLabel();
        u32 test = spvLabel();
        u32 body = spvLabel();
        u32 cont = spvLabel();
        u32 dflt = spvLabel();
        fn.loopContinue = cont;
        spvEmit((u32)SPV_BRANCH, spvA1(head));
        spvPlace(head);
        spvEmit((u32)SPV_LOOPMERGE, spvA3(mergeLabel, cont, (u32)0));
        spvEmit((u32)SPV_BRANCH, spvA1(test));
        spvPlace(test);
        u32 pc = spvEmitR((u32)SPV_LOAD, _sMod.typeInt((u32)32), spvA1(fn.pcVar));
        u32 go = spvEmitR((u32)SPV_INOTEQUAL, _sMod.typeBool(), spvA2(pc, _sMod.u32c((u32)0xFFFFFFFF)));
        if (guard != (u32)0)
            go = spvEmitR((u32)SPV_LOGICALAND, _sMod.typeBool(), spvA2(go, guard));
        spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(go, body, mergeLabel));
        spvPlace(body);
        Array* caseLabels = new Array();
        Array* sw = new Array();
        sw.add((Object*)Number.withU32(pc));
        sw.add((Object*)Number.withU32(dflt));
        for (u32 k = (u32)0; k < f.blocks().count(); k = k + (u32)1)
            {
            u32 l = spvLabel();
            caseLabels.add((Object*)Number.withU32(l));
            sw.add((Object*)Number.withU32(k));
            sw.add((Object*)Number.withU32(l));
            }
        u32 swMerge = spvLabel();
        spvEmit((u32)SPV_SELECTIONMERGE, spvA2(swMerge, (u32)0));
        spvEmit((u32)SPV_SWITCH, sw);
        for (u32 k = (u32)0; k < f.blocks().count(); k = k + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(k);
            spvPlace(((Number*)caseLabels.get(k)).asU32());
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                if (!spvStatement((IRInsn*)b.insns().get(i)))
                    {
                    self.parBecause(parWhyFor((IRInsn*)b.insns().get(i), true));
                    return false;
                    }
            IRInsn* t = b.term();
            if (t == (IRInsn*)0) return false;
            Array* vals = new Array();
            Array* dsts = new Array();
            if (t.op().equals(spvS("Branch")))
                {
                IRBlock* to = ((IROperand*)t.ops().get((u32)0)).blk();
                if (!spvEdge(b, to, (u32)0, true, vals, dsts)) return false;
                spvStores(vals, dsts);
                spvEmit((u32)SPV_STORE, spvA2(fn.pcVar, spvBlockNumber(to)));
                }
            else if (t.op().equals(spvS("CondBranch")))
                {
                u32 c = spvValue((IROperand*)t.ops().get((u32)0), (String*)0);
                if (c == (u32)0) return false;
                IRBlock* yes = ((IROperand*)t.ops().get((u32)1)).blk();
                IRBlock* no = ((IROperand*)t.ops().get((u32)2)).blk();
                if (yes == no)
                    {
                    if (!spvEdge(b, yes, (u32)0, true, vals, dsts)) return false;
                    }
                else if (!spvEdge(b, yes, c, true, vals, dsts) || !spvEdge(b, no, c, false, vals, dsts))
                    return false;
                spvStores(vals, dsts);
                u32 next = spvEmitR((u32)SPV_SELECT, _sMod.typeInt((u32)32), spvA3(c, spvBlockNumber(yes), spvBlockNumber(no)));
                spvEmit((u32)SPV_STORE, spvA2(fn.pcVar, next));
                }
            else if (t.op().equals(spvS("Return")))
                {
                IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                String* rvt = rv == (IROperand*)0 ? (String*)0 : rv.kind() == (u8)OPK_USE ? self.mslTypeOf(rv) : f.ret();
                if (_mHelper && rvt != (String*)0 && !self.ptxIs(rvt, "Mem"))
                    {
                    u32 v = spvValue(rv, rvt);
                    if (v == (u32)0 || fn.retVar == (u32)0) return false;
                    spvEmit((u32)SPV_STORE, spvA2(fn.retVar, v));
                    }
                spvEmit((u32)SPV_STORE, spvA2(fn.pcVar, _sMod.u32c((u32)0xFFFFFFFF)));
                }
            else
                return false;
            spvEmit((u32)SPV_BRANCH, spvA1(swMerge));
            }
        spvPlace(dflt);
        spvEmit((u32)SPV_STORE, spvA2(fn.pcVar, _sMod.u32c((u32)0xFFFFFFFF)));
        spvEmit((u32)SPV_BRANCH, spvA1(swMerge));
        spvPlace(swMerge);
        spvEmit((u32)SPV_BRANCH, spvA1(cont));
        spvPlace(cont);
        spvEmit((u32)SPV_BRANCH, spvA1(head));
        spvPlace(mergeLabel);
        return true;
        }

    // ── structured control flow ─────────────────────────────────────────────
    // The reference's spvStructured…: the Metal plan (sPlan) as SPIR-V loop
    // and selection constructs, values in Function variables, phis copies on
    // their edges; a dry walk first, else the dispatch loop.
    // A loop's label, 0 in the dry walk (which names none).
    final u32 spvNum(Map* m, i64 k)
        {
        Number* v = (Number*)m.get((Hashable*)self.sKey((u32)k));
        return v == (Number*)0 ? (u32)0 : v.asU32();
        }
    final void spvBranchTo(u32 to)
        {
        if (!_spvFn.dry) spvEmit((u32)SPV_BRANCH, spvA1(to));
        _spvFn.open = false;
        }
    final bool spvSJump(u32 u, u32 v, i64 h, i64 e, i64 fo)
        {
        SpvFn* f = _spvFn;
        if (!f.dry)
            {
            Array* vals = new Array();
            Array* dsts = new Array();
            if (!spvEdge((IRBlock*)_sFn.blocks().get(u), (IRBlock*)_sFn.blocks().get(v), (u32)0, true, vals, dsts))
                return false;
            spvStores(vals, dsts);
            }
        if ((i64)v == h) { spvBranchTo(spvNum(f.loopCont, h)); return true; }
        if ((i64)v == e) { spvBranchTo(spvNum(f.loopMerge, h)); return true; }
        if ((i64)v == fo) return true;
        if (sIsHeader(v)) return spvSLoop(v, e, fo, h);
        if (((Number*)_sFwd.get(v)).asU32() != (u32)1) return false;
        return spvSBlock(v, h, e, fo);
        }
    final bool spvSLoop(u32 x, i64 oe, i64 of, i64 oh)
        {
        SpvFn* f = _spvFn;
        if (((Number*)_sFwd.get(x)).asU32() != (u32)1) return false;
        u32 ex = (u32)((Number*)_sExit.get((Hashable*)self.sKey(x))).asI64();
        if (oh >= (i64)0 && !self.sInLoop(oh, ex) && (i64)ex != oe && (i64)ex != of) return false;
        u32 head = (u32)0;
        u32 body = (u32)0;
        u32 cont = (u32)0;
        u32 merge = (u32)0;
        if (!f.dry)
            {
            head = spvLabel(); body = spvLabel(); cont = spvLabel(); merge = spvLabel();
            f.loopCont.set((Hashable*)self.sKey(x), (Object*)Number.withU32(cont));
            f.loopMerge.set((Hashable*)self.sKey(x), (Object*)Number.withU32(merge));
            spvEmit((u32)SPV_BRANCH, spvA1(head));
            spvPlace(head);
            spvEmit((u32)SPV_LOOPMERGE, spvA3(merge, cont, (u32)0));
            spvEmit((u32)SPV_BRANCH, spvA1(body));
            spvPlace(body);
            }
        f.open = true;
        if (!spvSBlock(x, (i64)x, (i64)ex, (i64)-1)) return false;
        if (f.open) spvBranchTo(cont);
        if (!f.dry)
            {
            spvPlace(cont);
            spvEmit((u32)SPV_BRANCH, spvA1(head));
            spvPlace(merge);
            }
        f.open = true;
        if ((i64)ex == of) return true;
        if ((i64)ex == oh) { spvBranchTo(spvNum(f.loopCont, oh)); return true; }
        if ((i64)ex == oe) { spvBranchTo(spvNum(f.loopMerge, oh)); return true; }
        if (sIsHeader(ex)) return false;
        return spvSBlock(ex, oh, oe, of);
        }
    final bool spvSBlock(u32 x, i64 h, i64 e, i64 fo)
        {
        SpvFn* f = _spvFn;
        IRBlock* b = (IRBlock*)_sFn.blocks().get(x);
        if (!f.dry)
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                if (!spvStatement((IRInsn*)b.insns().get(i)))
                    {
                    self.parBecause(parWhyFor((IRInsn*)b.insns().get(i), true));
                    return false;
                    }
        IRInsn* t = b.term();
        if (t == (IRInsn*)0) return false;
        if (t.op().equals(spvS("Return")))
            {
            if (_mHelper)
                {
                // A function's return may stand anywhere in structured SPIR-V.
                IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                String* rvt = rv == (IROperand*)0 ? (String*)0 : rv.kind() == (u8)OPK_USE ? self.mslTypeOf(rv) : _sFn.ret();
                if (!f.dry)
                    {
                    if (rvt != (String*)0 && !self.ptxIs(rvt, "Mem"))
                        {
                        u32 v = spvValue(rv, rvt);
                        if (v == (u32)0) return false;
                        spvEmit((u32)SPV_RETURNVALUE, spvA1(v));
                        }
                    else
                        spvEmit((u32)SPV_RETURN, new Array());
                    }
                f.open = false;
                return true;
                }
            // The kernel's work ends: a break from the loop that runs once,
            // which only works from outside any loop of the kernel's own.
            if (h >= (i64)0) return false;
            spvBranchTo(f.exitLabel);
            return true;
            }
        if (t.op().equals(spvS("Branch")))
            return spvSJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)0)).blk()), h, e, fo);
        if (!t.op().equals(spvS("CondBranch"))) return false;
        u32 n = _sFn.blocks().count();
        i64 j = ((Number*)_sIpdom.get(x)).asI64();
        if (j < (i64)0) return false;
        i64 join = j == (i64)n ? fo : j;
        if (join >= (i64)0 && join != h && join != e && join != fo)
            if (h >= (i64)0 && !self.sInLoop(h, (u32)join)) return false;
        u32 yes = (u32)0;
        u32 no = (u32)0;
        u32 merge = (u32)0;
        if (!f.dry)
            {
            u32 c = spvValue((IROperand*)t.ops().get((u32)0), (String*)0);
            if (c == (u32)0) return false;
            yes = spvLabel(); no = spvLabel(); merge = spvLabel();
            spvEmit((u32)SPV_SELECTIONMERGE, spvA2(merge, (u32)0));
            spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(c, yes, no));
            spvPlace(yes);
            }
        f.open = true;
        if (!spvSJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)1)).blk()), h, e, join)) return false;
        if (f.open) spvBranchTo(merge);
        if (!f.dry) spvPlace(no);
        f.open = true;
        if (!spvSJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)2)).blk()), h, e, join)) return false;
        if (f.open) spvBranchTo(merge);
        if (!f.dry) spvPlace(merge);
        f.open = true;
        if (join < (i64)0)
            {
            // Both ways left by a branch: the merge is never reached.
            if (!f.dry) spvEmit((u32)SPV_UNREACHABLE, new Array());
            f.open = false;
            return true;
            }
        if (join == fo) return true;
        if (join == h) { spvBranchTo(spvNum(f.loopCont, h)); return true; }
        if (join == e) { spvBranchTo(spvNum(f.loopMerge, h)); return true; }
        if (sIsHeader((u32)join)) return spvSLoop((u32)join, e, fo, h);
        return spvSBlock((u32)join, h, e, fo);
        }
    final bool spvSWalk(void)
        {
        _spvFn.open = true;
        return self.sIsHeader((u32)0) ? spvSLoop((u32)0, (i64)-1, (i64)-1, (i64)-1)
                                 : spvSBlock((u32)0, (i64)-1, (i64)-1, (i64)-1);
        }
    // The function's blocks, structured where their shape allows, else as
    // the dispatch loop; then mergeLabel is placed.
    final bool spvBody(IRFunc* g, u32 mergeLabel, u32 guard)
        {
        SpvFn* f = _spvFn;
        f.dry = true;
        bool fits = self.sPlan(g) && spvSWalk();
        f.dry = false;
        if (!fits) return spvDispatch(g, mergeLabel, guard);
        f.loopCont = new Map();
        f.loopMerge = new Map();
        f.exitLabel = mergeLabel;
        u32 head = spvLabel();
        u32 body = spvLabel();
        u32 cont = spvLabel();
        spvEmit((u32)SPV_BRANCH, spvA1(head));
        spvPlace(head);
        spvEmit((u32)SPV_LOOPMERGE, spvA3(mergeLabel, cont, (u32)0));
        if (guard != (u32)0)
            spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(guard, body, mergeLabel));
        else
            spvEmit((u32)SPV_BRANCH, spvA1(body));
        spvPlace(body);
        if (!spvSWalk()) return false;
        if (f.open) spvEmit((u32)SPV_BRANCH, spvA1(mergeLabel));
        spvPlace(cont);
        spvEmit((u32)SPV_BRANCH, spvA1(head));
        spvPlace(mergeLabel);
        return true;
        }

    // A variable for every value that is read and is not a pointer or the
    // memory token.
    final bool spvDeclareValues(IRFunc* f)
        {
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(bi);
            Array* all = new Array();
            for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1) all.add(b.phis().get(i));
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1) all.add(b.insns().get(i));
            if (b.term() != (IRInsn*)0) all.add((Object*)b.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                    {
                    IROperand* op = (IROperand*)ip.ops().get(k);
                    if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
                        _spvFn.used.set((Hashable*)self.mslKey(op.val()), (Object*)spvS("1"));
                    }
                }
            }
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(bi);
            Array* all = new Array();
            for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1) all.add(b.phis().get(i));
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1) all.add(b.insns().get(i));
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)all.get(i);
                if (ip.res() == (IRValue*)0) continue;
                String* t = spvValType(ip.res());
                if (ptxIs(t, "Mem") || self.mslIsPtr(t) || _spvFn.used.get((Hashable*)self.mslKey(ip.res())) == (Object*)0) continue;
                u32 ty = spvType(t);
                if (ty == (u32)0)
                    {
                    self.parBecause(spvS("it uses a value its Vulkan version cannot hold yet"));
                    return false;
                    }
                _spvFn.varOf.set((Hashable*)self.mslKey(ip.res()), (Object*)Number.withU32(spvLocalVar(ty)));
                }
            }
        return true;
        }

    // The function's variables at the head of its entry block (after the
    // entry label, the code's first instruction).
    final void spvFinish(SpvFn* fn, Array* out)
        {
        out.add(fn.code.get((u32)0));
        out.add(fn.code.get((u32)1));
        for (u32 i = (u32)0; i < fn.vars.count(); i = i + (u32)1) out.add(fn.vars.get(i));
        for (u32 i = (u32)2; i < fn.code.count(); i = i + (u32)1) out.add(fn.code.get(i));
        }

    // A helper as a SPIR-V function of scalars: its id, or 0. The caller's
    // state comes back afterwards; the helper's reason is in _mHelperWhy.
    final u32 spvHelper(IRFunc* g)
        {
        Map* sDef = _mDef; Map* sSpace = _mSpace; Map* sBufOf = _mBufOf; Map* sOrd = _mOrd;
        Map* sBlk = _mBlk; Map* sBufs = _mBufs; Map* sReds = _mReds; IRLayout* sObj = _mObj;
        bool sFailed = _mFailed; bool sHelper = _mHelper; Map* sParams = _mParams; Map* sSinit = _mSinit; String* sWhy = _mWhy;
        Map* sLocalOf = _mLocalOf; Map* sLocalIndex = _mLocalIndex; Array* sLocalDecls = _mLocalDecls; Array* sLocalBytes = _mLocalBytes; Array* sLocalElem = _mLocalElem;
        Array* sGlobals = _mGlobals; Map* sGlobalOf = _mGlobalOf; SpvFn* sFn = _spvFn;
        Array* sSucc = _sSucc; Array* sRpo = _sRpo; Array* sFwd = _sFwd; Map* sLoop = _sLoop; Map* sExit = _sExit;
        Array* sIpdom = _sIpdom; IRFunc* sSFn = _sFn;
        u32 out = spvHelperBody(g);
        _sSucc = sSucc; _sRpo = sRpo; _sFwd = sFwd; _sLoop = sLoop; _sExit = sExit; _sIpdom = sIpdom; _sFn = sSFn;
        _mHelperWhy = _mWhy;
        _mDef = sDef; _mSpace = sSpace; _mBufOf = sBufOf; _mOrd = sOrd;
        _mBlk = sBlk; _mBufs = sBufs; _mReds = sReds; _mObj = sObj;
        _mFailed = sFailed; _mHelper = sHelper; _mParams = sParams; _mSinit = sSinit; _mWhy = sWhy;
        _mLocalOf = sLocalOf; _mLocalIndex = sLocalIndex; _mLocalDecls = sLocalDecls; _mLocalBytes = sLocalBytes; _mLocalElem = sLocalElem;
        _mGlobals = sGlobals; _mGlobalOf = sGlobalOf; _spvFn = sFn;
        return out;
        }

    final u32 spvHelperBody(IRFunc* g)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = true;
        _mParams = new Map();
        _mObj = (IRLayout*)0;
        _mGlobals = new Array();
        _mGlobalOf = new Map();
        if (!self.mslAnalyse(g)) return (u32)0;
        SpvFn* fn = new SpvFn();
        for (u32 bi = (u32)0; bi < g.blocks().count(); bi = bi + (u32)1)
            {
            fn.blockNum.set((Hashable*)((IRBlock*)g.blocks().get(bi)).name(), (Object*)Number.withU32(bi));
            // The structured walk's block indexes (sPlan), as the Metal printer's.
            _mBlk.set((Hashable*)((IRBlock*)g.blocks().get(bi)).name(), (Object*)String.withU32(bi));
            }
        String* rt = g.ret();
        bool isVoid = rt == (String*)0 || self.ptxIs(rt, "Void") || self.ptxIs(rt, "Mem");
        u32 ret = isVoid ? _sMod.typeVoid() : spvType(rt);
        if (ret == (u32)0) return (u32)0;
        Array* fnTypeWords = new Array();
        fnTypeWords.add((Object*)Number.withU32(ret));
        Array* paramTys = new Array();
        String* key = spvS("fn");
        key.append(String.withU32(ret));
        for (u32 k = (u32)0; k + (u32)1 < g.params().count(); k = k + (u32)1)
            {
            u32 t = spvType(((IRValue*)g.params().get(k)).ty());
            if (t == (u32)0) return (u32)0;
            paramTys.add((Object*)Number.withU32(t));
            fnTypeWords.add((Object*)Number.withU32(t));
            key.appendCString("_");
            key.append(String.withU32(t));
            }
        u32 fnType = _sMod.cached(key, (u32)SPV_TYPEFUNCTION, fnTypeWords, true);
        u32 fid = _sMod.newId();
        _spvFn = fn;
        Array* header = new Array();
        spvOp(header, (u32)SPV_FUNCTION, spvW((u32)4, ret, fid, (u32)0, fnType, (u32)0, (u32)0));
        Array* params = new Array();
        for (u32 k = (u32)0; k < paramTys.count(); k = k + (u32)1)
            {
            u32 p = _sMod.newId();
            spvOp(header, (u32)SPV_FUNCTIONPARAMETER, spvA2(((Number*)paramTys.get(k)).asU32(), p));
            params.add((Object*)Number.withU32(p));
            }
        spvPlace(spvLabel());
        for (u32 k = (u32)0; k < params.count(); k = k + (u32)1)
            {
            u32 v = spvLocalVar(((Number*)paramTys.get(k)).asU32());
            fn.varOf.set((Hashable*)self.mslKey((IRValue*)g.params().get(k)), (Object*)Number.withU32(v));
            spvEmit((u32)SPV_STORE, spvA2(v, ((Number*)params.get(k)).asU32()));
            }
        if (!spvDeclareValues(g)) return (u32)0;
        fn.pcVar = spvLocalVar(_sMod.typeInt((u32)32));
        spvEmit((u32)SPV_STORE, spvA2(fn.pcVar, _sMod.u32c((u32)0)));
        if (!isVoid)
            fn.retVar = spvLocalVar(ret);
        u32 merge = spvLabel();
        if (!spvBody(g, merge, (u32)0)) return (u32)0;
        if (isVoid)
            spvEmit((u32)SPV_RETURN, new Array());
        else
            spvEmit((u32)SPV_RETURNVALUE, spvA1(spvEmitR((u32)SPV_LOAD, ret, spvA1(fn.retVar))));
        spvEmit((u32)SPV_FUNCTIONEND, new Array());
        for (u32 i = (u32)0; i < header.count(); i = i + (u32)1) _sMod.funcs.add(header.get(i));
        spvFinish(fn, _sMod.funcs);
        return fid;
        }

    // A storage buffer of `elem` (runtime array, stride `stride`) at `binding`.
    final u32 spvBuffer(u32 elem, u32 stride, u32 binding)
        {
        SpvMod* m = _sMod;
        u32 arr = m.newId();
        spvOp(m.globals, (u32)SPV_TYPERUNTIMEARRAY, spvA2(arr, elem));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA3(arr, (u32)SPV_DEC_ARRAYSTRIDE, stride));
        u32 st = m.newId();
        spvOp(m.globals, (u32)SPV_TYPESTRUCT, spvA2(st, arr));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA2(st, (u32)SPV_DEC_BLOCK));
        spvOp(m.decos, (u32)SPV_MEMBERDECORATE, spvW((u32)4, st, (u32)0, (u32)SPV_DEC_OFFSET, (u32)0, (u32)0, (u32)0));
        u32 v = m.newId();
        spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(m.ptrType((u32)SPV_ST_STORAGEBUFFER, st), v, (u32)SPV_ST_STORAGEBUFFER));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA3(v, (u32)SPV_DEC_DESCRIPTORSET, (u32)0));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA3(v, (u32)SPV_DEC_BINDING, binding));
        return v;
        }

    // The kernel: true with its bytes in _sOut, or false. The 32-bit span
    // form first, which declares no 64-bit integer and so runs on a device
    // without Int64 (the Raspberry Pi 5's V3D); the 64-bit one when anything
    // in the kernel still needs one. As the reference (spirvForKernel).
    final bool parSpirv(IRFunc* f)
        {
        _sSpan32 = true;
        if (parSpirvForm(f) && !_sMod.usesInt64)
            return true;
        _sSpan32 = false;
        _mWhy = (String*)0;
        return parSpirvForm(f);
        }

    // In the 32-bit span form, the loads of lo or hi (fields 1 and 2) whose
    // every use truncates to 32 bits or less: those, and only those, are u32.
    // A loop over a 32-bit variable reads its bounds that way.
    final Map* spvNarrowLoHi(IRFunc* f)
        {
        Map* addrs = new Map();
        Map* loads = new Map();
        for (u32 pass = (u32)0; pass < (u32)3; pass = pass + (u32)1)
            for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
                {
                IRBlock* b = (IRBlock*)f.blocks().get(bi);
                Array* all = new Array();
                for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1) all.add(b.phis().get(i));
                for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1) all.add(b.insns().get(i));
                if (b.term() != (IRInsn*)0) all.add((Object*)b.term());
                for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                    {
                    IRInsn* ip = (IRInsn*)all.get(i);
                    if (pass == (u32)0)
                        {
                        if (ip.op().equals(spvS("FieldAddr")) && ip.res() != (IRValue*)0)
                            {
                            i64 k = self.mslSelfField(ip);
                            if (k == (i64)1 || k == (i64)2)
                                addrs.set((Hashable*)self.mslKey(ip.res()), (Object*)spvS("1"));
                            }
                        continue;
                        }
                    if (pass == (u32)1)
                        {
                        if (!ip.op().equals(spvS("Load")) || ip.res() == (IRValue*)0 || ip.ops().count() == (u32)0) continue;
                        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
                        if (o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 && addrs.get((Hashable*)self.mslKey(o0.val())) != (Object*)0)
                            loads.set((Hashable*)self.mslKey(ip.res()), (Object*)spvS("1"));
                        continue;
                        }
                    // pass 2: a use other than a truncation to 32 bits or less widens it.
                    bool narrowing = ip.op().equals(spvS("Trunc")) && ip.res() != (IRValue*)0 &&
                        (self.ptxIs(ip.res().ty(), "U32") || self.ptxIs(ip.res().ty(), "I32") || self.ptxIs(ip.res().ty(), "U16") ||
                         self.ptxIs(ip.res().ty(), "I16") || self.ptxIs(ip.res().ty(), "U8") || self.ptxIs(ip.res().ty(), "I8"));
                    for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                        {
                        IROperand* op = (IROperand*)ip.ops().get(k);
                        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0) continue;
                        if (!narrowing && loads.get((Hashable*)self.mslKey(op.val())) != (Object*)0)
                            loads.remove((Hashable*)self.mslKey(op.val()));
                        }
                    }
                }
        return loads;
        }

    // The "full" form (V3D, 2026-10-30): a pipeline specialised with SpecId 0
    // true runs only where every thread has exactly one item, and there the
    // item loop's entry test (lo < hi) is true and its latch test (i + 1 < hi)
    // false. Folding both lets the driver see the item's own loops as uniform
    // (Mesa's V3D compiles a loop inside divergent control flow lane by lane).
    // The compares against hi qualify only in that shape: the entry's left side
    // is lo; the latch's is i + 1 for the induction variable i, a phi of lo
    // and that sum. Anything else that uses hi, or a reduction, and the
    // kernel has no full form: 0.
    final Map* spvFullCmps(IRFunc* f)
        {
        Map* addrK = new Map();     // FieldAddr self #1/#2 -> "1"/"2"
        Map* loadK = new Map();     // narrowed load -> "1"/"2"
        Map* truncK = new Map();    // Trunc of one -> "1"/"2"
        Map* phiLo = new Map();     // phi with a lo trunc among its incomings
        Map* addOf = new Map();     // Add(phi, 1) -> the phi's key
        Array* insns = new Array();
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(bi);
            for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1) insns.add(b.phis().get(i));
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1) insns.add(b.insns().get(i));
            if (b.term() != (IRInsn*)0) insns.add((Object*)b.term());
            }
        for (u32 pass = (u32)0; pass < (u32)5; pass = pass + (u32)1)
            for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)insns.get(i);
                IRValue* res = ip.res();
                IROperand* o0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
                bool u0 = o0 != (IROperand*)0 && o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0;
                if (pass == (u32)0 && ip.op().equals(spvS("FieldAddr")) && res != (IRValue*)0)
                    {
                    i64 k = self.mslSelfField(ip);
                    if (k == (i64)1 || k == (i64)2) addrK.set((Hashable*)self.mslKey(res), (Object*)String.withI64(k));
                    }
                if (pass == (u32)1 && ip.op().equals(spvS("Load")) && res != (IRValue*)0 && u0 &&
                    addrK.get((Hashable*)self.mslKey(o0.val())) != (Object*)0 && _sNarrowVals.get((Hashable*)self.mslKey(res)) != (Object*)0)
                    loadK.set((Hashable*)self.mslKey(res), addrK.get((Hashable*)self.mslKey(o0.val())));
                if (pass == (u32)2 && ip.op().equals(spvS("Trunc")) && res != (IRValue*)0 && u0 &&
                    loadK.get((Hashable*)self.mslKey(o0.val())) != (Object*)0)
                    truncK.set((Hashable*)self.mslKey(res), loadK.get((Hashable*)self.mslKey(o0.val())));
                if (pass == (u32)3 && ip.op().equals(spvS("Phi")) && res != (IRValue*)0)
                    for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                        {
                        IROperand* op = (IROperand*)ip.ops().get(k);
                        if (op.kind() == (u8)OPK_USE && op.val() != (IRValue*)0)
                            {
                            String* tk = (String*)truncK.get((Hashable*)self.mslKey(op.val()));
                            if (tk != (String*)0 && tk.equals(spvS("1"))) phiLo.set((Hashable*)self.mslKey(res), (Object*)spvS("1"));
                            }
                        }
                if (pass == (u32)4 && ip.op().equals(spvS("Add")) && res != (IRValue*)0 && u0 && ip.ops().count() == (u32)2 &&
                    phiLo.get((Hashable*)self.mslKey(o0.val())) != (Object*)0)
                    {
                    IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
                    if (o1.kind() == (u8)OPK_IMMI && o1.imm() == (i64)1)
                        addOf.set((Hashable*)self.mslKey(res), (Object*)self.mslKey(o0.val()));
                    }
                }
        // The induction phi's incomings: lo, or its own sum, and nothing else.
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            {
            IRInsn* ip = (IRInsn*)insns.get(i);
            if (!ip.op().equals(spvS("Phi")) || ip.res() == (IRValue*)0 || phiLo.get((Hashable*)self.mslKey(ip.res())) == (Object*)0) continue;
            for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                {
                IROperand* op = (IROperand*)ip.ops().get(k);
                if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0) continue;
                String* key = self.mslKey(op.val());
                String* tk = (String*)truncK.get((Hashable*)key);
                String* ak = (String*)addOf.get((Hashable*)key);
                bool ok = (tk != (String*)0 && tk.equals(spvS("1"))) || (ak != (String*)0 && ak.equals(self.mslKey(ip.res())));
                if (!ok) phiLo.remove((Hashable*)self.mslKey(ip.res()));
                }
            }
        Map* out = new Map();
        bool any = false;
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            {
            IRInsn* ip = (IRInsn*)insns.get(i);
            for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                {
                IROperand* op = (IROperand*)ip.ops().get(k);
                if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0) continue;
                String* tk = (String*)truncK.get((Hashable*)self.mslKey(op.val()));
                if (tk == (String*)0 || !tk.equals(spvS("2"))) continue;
                // A use of hi: only as the right side of lo < hi or i + 1 < hi.
                if (!ip.op().equals(spvS("ICmp")) || k != (u32)1 || ip.res() == (IRValue*)0 ||
                    !(ip.pred().equals(spvS("ULT")) || ip.pred().equals(spvS("SLT"))))
                    return (Map*)0;
                IROperand* a = (IROperand*)ip.ops().get((u32)0);
                if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0) return (Map*)0;
                String* ak = self.mslKey(a.val());
                String* atk = (String*)truncK.get((Hashable*)ak);
                String* aph = (String*)addOf.get((Hashable*)ak);
                if (atk != (String*)0 && atk.equals(spvS("1")))
                    out.set((Hashable*)self.mslKey(ip.res()), (Object*)spvS("h"));
                else if (aph != (String*)0 && phiLo.get((Hashable*)aph) != (Object*)0)
                    out.set((Hashable*)self.mslKey(ip.res()), (Object*)spvS("l"));
                else
                    return (Map*)0;
                any = true;
                }
            }
        return any ? out : (Map*)0;
        }

    final bool parSpirvForm(IRFunc* f)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = false;
        _mParams = (Map*)0;
        _mGlobals = new Array();
        _mGlobalOf = new Map();
        if (f.params().count() == (u32)0) return false;
        _mObj = self.mslLayoutOf(mslPointee(((IRValue*)f.params().get((u32)0)).ty()));
        if (_mObj == (IRLayout*)0 || _mObj.fieldCount() < (u32)3 || !self.ptxIs(_mObj.typeAt((u32)1), "I64") || !self.ptxIs(_mObj.typeAt((u32)2), "I64"))
            return false;
        if (!self.mslAnalyse(f)) return false;
        SpvFn* fn = new SpvFn();
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            fn.blockNum.set((Hashable*)((IRBlock*)f.blocks().get(bi)).name(), (Object*)Number.withU32(bi));
            // The structured walk's block indexes (sPlan), as the Metal printer's.
            _mBlk.set((Hashable*)((IRBlock*)f.blocks().get(bi)).name(), (Object*)String.withU32(bi));
            }

        SpvMod* m = new SpvMod();
        _sMod = m;
        _sHelpers = new Map();
        _sBufVar = new Map();
        _sMember = new Map();
        _sNarrowShift = new Map();
        _sWordBufs = new Map();
        _sByteBufs = new Map();
        _sNarrowVals = _sSpan32 ? spvNarrowLoHi(f) : new Map();

        // The object's fields the kernel uses (other than captured arrays).
        Map* used = new Map();
        used.set((Hashable*)spvS("1"), (Object*)spvS("1"));
        used.set((Hashable*)spvS("2"), (Object*)spvS("1"));
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(bi);
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)b.insns().get(i);
                if (!ip.op().equals(spvS("FieldAddr")) || ip.res() == (IRValue*)0) continue;
                i64 k = self.mslSelfField(ip);
                if (k >= (i64)0 && !self.mslIsPtr(_mObj.typeAt((u32)k)))
                    used.set((Hashable*)String.withI64(k), (Object*)spvS("1"));
                }
            }
        // A narrow field is read from the 32-bit word that holds it, shared
        // with any other narrow field in that word. As the reference.
        Array* memberTypes = new Array();
        Array* memberOffsets = new Array();
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (used.get((Hashable*)String.withU32(k)) == (Object*)0) continue;
            String* ft = _mObj.typeAt(k);
            // The 32-bit span form: lo and hi are their fields' low words.
            if (_sSpan32 && (k == (u32)1 || k == (u32)2))
                ft = spvS("U32");
            u32 t = spvType(ft);
            if (t == (u32)0)
                {
                self.parBecause(spvS("it uses a captured value its Vulkan version cannot hold"));
                return false;
                }
            u32 off = _mObj.offsetAt(k);
            if (spvNarrowBytes(ft) != (u32)0)
                {
                _sNarrowShift.set((Hashable*)String.withU32(k), (Object*)Number.withU32((off & (u32)3) * (u32)8));
                off = off & (u32)$FFFFFFFC;
                t = m.typeInt((u32)32);
                if (memberOffsets.count() > (u32)0 && ((Number*)memberOffsets.get(memberOffsets.count() - (u32)1)).asU32() == off)
                    {
                    _sMember.set((Hashable*)String.withU32(k), (Object*)Number.withU32(memberTypes.count() - (u32)1));
                    continue;
                    }
                }
            _sMember.set((Hashable*)String.withU32(k), (Object*)Number.withU32(memberTypes.count()));
            memberTypes.add((Object*)Number.withU32(t));
            memberOffsets.add((Object*)Number.withU32(off));
            }

        // The args struct (binding 0) and the kernel's Function copy.
        u32 argsT = m.newId();
        Array* sw = new Array();
        sw.add((Object*)Number.withU32(argsT));
        for (u32 i = (u32)0; i < memberTypes.count(); i = i + (u32)1) sw.add(memberTypes.get(i));
        spvOp(m.globals, (u32)SPV_TYPESTRUCT, sw);
        spvOp(m.decos, (u32)SPV_DECORATE, spvA2(argsT, (u32)SPV_DEC_BLOCK));
        for (u32 mi = (u32)0; mi < memberOffsets.count(); mi = mi + (u32)1)
            {
            spvOp(m.decos, (u32)SPV_MEMBERDECORATE, spvW((u32)4, argsT, mi, (u32)SPV_DEC_OFFSET, ((Number*)memberOffsets.get(mi)).asU32(), (u32)0, (u32)0));
            spvOp(m.decos, (u32)SPV_MEMBERDECORATE, spvA3(argsT, mi, (u32)SPV_DEC_NONWRITABLE));
            }
        u32 argsV = m.newId();
        spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(m.ptrType((u32)SPV_ST_STORAGEBUFFER, argsT), argsV, (u32)SPV_ST_STORAGEBUFFER));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA3(argsV, (u32)SPV_DEC_DESCRIPTORSET, (u32)0));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA3(argsV, (u32)SPV_DEC_BINDING, (u32)0));
        u32 localT = m.newId();
        Array* lw = new Array();
        lw.add((Object*)Number.withU32(localT));
        for (u32 i = (u32)0; i < memberTypes.count(); i = i + (u32)1) lw.add(memberTypes.get(i));
        spvOp(m.globals, (u32)SPV_TYPESTRUCT, lw);

        // The span: four i64 push constants — lo, hi, per, and (bug 645) the
        // number of partials the fold entry point has to combine, which the
        // kernel itself does not read (the reference explains).
        // The 32-bit span form reads the low word of each (the host writes
        // the same four i64 values either way), and has no 64-bit integer.
        u32 i64t = _sSpan32 ? m.typeInt((u32)32) : m.typeInt((u32)64);
        u32 spanT = m.newId();
        spvOp(m.globals, (u32)SPV_TYPESTRUCT, spvW((u32)5, spanT, i64t, i64t, i64t, i64t, (u32)0));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA2(spanT, (u32)SPV_DEC_BLOCK));
        for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
            spvOp(m.decos, (u32)SPV_MEMBERDECORATE, spvW((u32)4, spanT, k, (u32)SPV_DEC_OFFSET, (u32)8 * k, (u32)0, (u32)0));
        u32 spanV = m.newId();
        spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(m.ptrType((u32)SPV_ST_PUSHCONSTANT, spanT), spanV, (u32)SPV_ST_PUSHCONSTANT));

        // The thread's index.
        u32 u32t = m.typeInt((u32)32);
        u32 uvec3 = m.cached(spvS("uvec3"), (u32)SPV_TYPEVECTOR, spvA2(u32t, (u32)3), true);
        u32 gidV = m.newId();
        spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(m.ptrType((u32)SPV_ST_INPUT, uvec3), gidV, (u32)SPV_ST_INPUT));
        spvOp(m.decos, (u32)SPV_DECORATE, spvA3(gidV, (u32)SPV_DEC_BUILTIN, (u32)SPV_BUILTIN_GLOBALINVOCATIONID));
        // A device-side reduction (bug 645) when every reduced field is a full
        // 32- or 64-bit value with an operator its type takes (the reference
        // explains).
        bool devred = _mRedOps != (Map*)0;
        bool anyRed = false;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mReds.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            anyRed = true;
            String* rt = _mObj.typeAt(k);
            String* op = _mRedOps != (Map*)0 ? (String*)_mRedOps.get((Hashable*)String.withU32(k)) : (String*)0;
            bool isF = self.ptxIs(rt, "F32") || self.ptxIs(rt, "F64");
            bool okT = self.ptxIs(rt, "I32") || self.ptxIs(rt, "U32") || self.ptxIs(rt, "I64") || self.ptxIs(rt, "U64") || isF;
            bool okOp = op != (String*)0 && (op.equals(spvS("+")) || op.equals(spvS("*")) || op.equals(spvS("min")) ||
                        op.equals(spvS("max")) ||
                        (!isF && (op.equals(spvS("&")) || op.equals(spvS("|")) || op.equals(spvS("^")))));
            if (!okT || !okOp)
                devred = false;
            }
        if (!anyRed)
            devred = false;
        // The full form, where the shape allows it (spvFullCmps): the
        // specialization constant the runtime sets for the whole workgroups.
        _sFullCmps = _sSpan32 && !anyRed ? spvFullCmps(f) : (Map*)0;
        _sFullC = (u32)0;
        if (_sFullCmps != (Map*)0)
            {
            _sFullC = m.newId();
            spvOp(m.globals, (u32)SPV_SPECCONSTANTFALSE, spvA2(m.typeBool(), _sFullC));
            spvOp(m.decos, (u32)SPV_DECORATE, spvA3(_sFullC, (u32)SPV_DEC_SPECID, (u32)0));
            }
        u32 lidV = (u32)0;
        u32 wgV = (u32)0;
        if (devred)
            {
            lidV = m.newId();
            spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(m.ptrType((u32)SPV_ST_INPUT, uvec3), lidV, (u32)SPV_ST_INPUT));
            spvOp(m.decos, (u32)SPV_DECORATE, spvA3(lidV, (u32)SPV_DEC_BUILTIN, (u32)SPV_BUILTIN_LOCALINVOCATIONID));
            wgV = m.newId();
            spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(m.ptrType((u32)SPV_ST_INPUT, uvec3), wgV, (u32)SPV_ST_INPUT));
            spvOp(m.decos, (u32)SPV_DECORATE, spvA3(wgV, (u32)SPV_DEC_BUILTIN, (u32)SPV_BUILTIN_WORKGROUPID));
            }

        // Buffers: captured arrays, globals, reductions, in the header's order.
        String* meta = spvS("// xcpar size=");
        meta.append(String.withU32(_mObj.size())); meta.appendCString(" lo="); meta.append(String.withU32(_mObj.offsetAt((u32)1)));
        meta.appendCString(" hi="); meta.append(String.withU32(_mObj.offsetAt((u32)2)));
        if (_sSpan32)
            meta.appendCString(" span=32");
        if (_sFullC != (u32)0)
            meta.appendCString(" full");
        // Workgroups of 256 for every kernel (the reference explains).
        meta.appendCString(" wg=256");
        Array* iface = new Array();
        iface.add((Object*)Number.withU32(gidV));
        iface.add((Object*)Number.withU32(argsV));
        iface.add((Object*)Number.withU32(spanV));
        if (devred)
            {
            iface.add((Object*)Number.withU32(lidV));
            iface.add((Object*)Number.withU32(wgV));
            }
        u32 binding = (u32)1;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mBufs.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* et = self.mslPointee(_mObj.typeAt(k));
            u32 t = spvType(et);
            if (t == (u32)0)
                {
                self.parBecause(spvS("it uses an array of values its Vulkan version cannot hold"));
                return false;
                }
            meta.appendCString(" buf="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":");
            meta.append(String.withU32(k - (u32)3)); meta.appendCString(":"); meta.append(String.withU32(spvWidth(et)));
            // A byte array is a buffer of 8-bit integers (#7); a 16-bit one
            // lives in 32-bit words.
            bool bytes = spvNarrowBytes(et) == (u32)1;
            bool narrow = !bytes && spvNarrowBytes(et) != (u32)0;
            u32 v = bytes ? spvBuffer(m.typeInt8Storage(), (u32)1, binding)
                          : spvBuffer(narrow ? m.typeInt((u32)32) : t, narrow ? (u32)4 : spvWidth(et), binding);
            if (narrow)
                _sWordBufs.set((Hashable*)String.withU32(v), (Object*)spvS("1"));
            if (bytes)
                _sByteBufs.set((Hashable*)String.withU32(v), (Object*)spvS("1"));
            binding = binding + (u32)1;
            String* key = spvS("f");
            key.append(String.withI64((i64)k));
            _sBufVar.set((Hashable*)key, (Object*)Number.withU32(v));
            iface.add((Object*)Number.withU32(v));
            }
        for (u32 gi = (u32)0; gi < _mGlobals.count(); gi = gi + (u32)1)
            {
            String* gn = (String*)_mGlobals.get(gi);
            IRSymbol* gs = (IRSymbol*)0;
            for (u32 q = (u32)0; q < _m.syms().count(); q = q + (u32)1)
                if (((IRSymbol*)_m.syms().get(q)).name().equals(gn))
                    gs = (IRSymbol*)_m.syms().get(q);
            String* gt = gs != (IRSymbol*)0 ? gs.dataType() : (String*)0;
            IRLayout* gl = self.mslLayoutOf(gt);
            String* et = gl != (IRLayout*)0 ? gl.typeAt((u32)0) : gt;
            String* fe = self.parWordOf(et);
            if (fe != (String*)0) et = fe;
            u32 t = spvType(et);
            if (t == (u32)0)
                {
                String* w = spvS("it uses ");
                w.append(self.parShown(gn));
                w.appendCString(", which its Vulkan version cannot hold");
                self.parBecause(w);
                return false;
                }
            meta.appendCString(" glob="); meta.append(gn); meta.appendCString(":"); meta.append(String.withU32(spvWidth(et)));
            bool bytesG = spvNarrowBytes(et) == (u32)1;
            bool narrowG = !bytesG && spvNarrowBytes(et) != (u32)0;
            u32 v = bytesG ? spvBuffer(m.typeInt8Storage(), (u32)1, binding)
                           : spvBuffer(narrowG ? m.typeInt((u32)32) : t, narrowG ? (u32)4 : spvWidth(et), binding);
            if (narrowG)
                _sWordBufs.set((Hashable*)String.withU32(v), (Object*)spvS("1"));
            if (bytesG)
                _sByteBufs.set((Hashable*)String.withU32(v), (Object*)spvS("1"));
            binding = binding + (u32)1;
            String* key = spvS("g");
            key.append(String.withU32(gi));
            _sBufVar.set((Hashable*)key, (Object*)Number.withU32(v));
            iface.add((Object*)Number.withU32(v));
            }
        // A byte array's buffer needs 8-bit storage: the runtime runs the
        // block on the CPU where the device has none (#7).
        if (m.uses8BitStorage)
            meta.appendCString(" bytes8");
        if (_parExtraMeta != (String*)0) meta.append(_parExtraMeta);
        Array* redVars = new Array();
        Array* redFields = new Array();
        Array* shVars = new Array();
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mReds.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* ft = _mObj.typeAt(k);
            u32 t = spvType(ft);
            if (t == (u32)0 || _sMember.get((Hashable*)String.withU32(k)) == (Object*)0)
                {
                self.parBecause(spvS("it reduces a value its Vulkan version cannot hold"));
                return false;
                }
            // An 8- or 16-bit value or a bool: a 32-bit slot per thread (the
            // reference explains).
            bool narrow = spvNarrowBytes(ft) != (u32)0;
            meta.appendCString(" red="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":"); meta.append(String.withU32(spvWidth(ft)));
            if (narrow) meta.appendCString(":4");
            u32 v = narrow ? spvBuffer(m.typeInt((u32)32), (u32)4, binding) : spvBuffer(t, spvWidth(ft), binding);
            binding = binding + (u32)1;
            redVars.add((Object*)Number.withU32(v));
            redFields.add((Object*)Number.withU32(k));
            iface.add((Object*)Number.withU32(v));
            if (devred)
                {
                // The workgroup's 256 values of this field.
                u32 n256 = m.u32c((u32)256);
                String* akey = spvS("arr256_");
                akey.append(String.withU32(t));
                u32 arrT = m.cached(akey, (u32)SPV_TYPEARRAY, spvA2(t, n256), true);
                u32 pArr = m.ptrType((u32)SPV_ST_WORKGROUP, arrT);
                u32 sv = m.newId();
                spvOp(m.globals, (u32)SPV_VARIABLE, spvA3(pArr, sv, (u32)SPV_ST_WORKGROUP));
                shVars.add((Object*)Number.withU32(sv));
                iface.add((Object*)Number.withU32(sv));
                }
            }

        // The kernel function.
        u32 voidT = m.typeVoid();
        String* fkey = spvS("fn");
        fkey.append(String.withU32(voidT));
        u32 fnT = m.cached(fkey, (u32)SPV_TYPEFUNCTION, spvA1(voidT), true);
        u32 mainId = m.newId();
        _spvFn = fn;
        Array* header = new Array();
        spvOp(header, (u32)SPV_FUNCTION, spvW((u32)4, voidT, mainId, (u32)0, fnT, (u32)0, (u32)0));
        spvPlace(spvLabel());
        _sLocalObj = spvLocalVar(localT);
        if (!spvDeclareValues(f)) return false;

        u32 gid = spvEmitR((u32)SPV_LOAD, uvec3, spvA1(gidV));
        u32 tid32 = spvEmitR((u32)SPV_COMPOSITEEXTRACT, u32t, spvA2(gid, (u32)0));
        u32 tid = _sSpan32 ? tid32 : spvEmitR((u32)SPV_UCONVERT, i64t, spvA1(tid32));
        u32 pI64 = m.ptrType((u32)SPV_ST_PUSHCONSTANT, i64t);
        u32 spanLo = spvEmitR((u32)SPV_LOAD, i64t, spvA1(spvEmitR((u32)SPV_ACCESSCHAIN, pI64, spvA2(spanV, m.u32c((u32)0)))));
        u32 spanHi = spvEmitR((u32)SPV_LOAD, i64t, spvA1(spvEmitR((u32)SPV_ACCESSCHAIN, pI64, spvA2(spanV, m.u32c((u32)1)))));
        u32 per = spvEmitR((u32)SPV_LOAD, i64t, spvA1(spvEmitR((u32)SPV_ACCESSCHAIN, pI64, spvA2(spanV, m.u32c((u32)2)))));
        u32 lo = spvEmitR((u32)SPV_IADD, i64t, spvA2(spanLo, spvEmitR((u32)SPV_IMUL, i64t, spvA2(tid, per))));
        u32 end = spvEmitR((u32)SPV_IADD, i64t, spvA2(lo, per));
        u32 hi = spvEmitR((u32)SPV_SELECT, i64t, spvA3(spvEmitR((u32)SPV_SLESSTHAN, m.typeBool(), spvA2(end, spanHi)), end, spanHi));
        for (u32 k = (u32)0; k < memberTypes.count(); k = k + (u32)1)
            {
            u32 mt = ((Number*)memberTypes.get(k)).asU32();
            u32 src = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_STORAGEBUFFER, mt), spvA2(argsV, m.u32c(k)));
            u32 dst = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_FUNCTION, mt), spvA2(_sLocalObj, m.u32c(k)));
            spvEmit((u32)SPV_STORE, spvA2(dst, spvEmitR((u32)SPV_LOAD, mt, spvA1(src))));
            }
        u32 pLocal64 = m.ptrType((u32)SPV_ST_FUNCTION, i64t);
        u32 m1 = ((Number*)_sMember.get((Hashable*)spvS("1"))).asU32();
        u32 m2 = ((Number*)_sMember.get((Hashable*)spvS("2"))).asU32();
        spvEmit((u32)SPV_STORE, spvA2(spvEmitR((u32)SPV_ACCESSCHAIN, pLocal64, spvA2(_sLocalObj, m.u32c(m1))), lo));
        spvEmit((u32)SPV_STORE, spvA2(spvEmitR((u32)SPV_ACCESSCHAIN, pLocal64, spvA2(_sLocalObj, m.u32c(m2))), hi));
        fn.pcVar = spvLocalVar(u32t);
        spvEmit((u32)SPV_STORE, spvA2(fn.pcVar, m.u32c((u32)0)));
        u32 guard = spvEmitR((u32)SPV_SLESSTHAN, m.typeBool(), spvA2(lo, hi));
        if (_sFullC != (u32)0)
            guard = spvEmitR((u32)SPV_LOGICALOR, m.typeBool(), spvA2(_sFullC, guard));
        u32 merge = spvLabel();
        if (!spvBody(f, merge, guard)) return false;
        if (devred)
            {
            // Every thread reaches every barrier: one past the range holds its
            // reductions' starting values, which leave the result unchanged.
            u32 boolT = m.typeBool();
            u32 lidv = spvEmitR((u32)SPV_LOAD, uvec3, spvA1(lidV));
            u32 lid32 = spvEmitR((u32)SPV_COMPOSITEEXTRACT, u32t, spvA2(lidv, (u32)0));
            u32 wgv = spvEmitR((u32)SPV_LOAD, uvec3, spvA1(wgV));
            u32 wg32 = spvEmitR((u32)SPV_COMPOSITEEXTRACT, u32t, spvA2(wgv, (u32)0));
            u32 scope = m.u32c((u32)2);      // Workgroup
            u32 sem = m.u32c((u32)0x108);    // AcquireRelease | WorkgroupMemory
            for (u32 di = (u32)0; di < redFields.count(); di = di + (u32)1)
                {
                u32 k = ((Number*)redFields.get(di)).asU32();
                String* rt = _mObj.typeAt(k);
                String* op = (String*)_mRedOps.get((Hashable*)String.withU32(k));
                bool isF = self.ptxIs(rt, "F32") || self.ptxIs(rt, "F64");
                bool sgn = self.ptxIs(rt, "I32") || self.ptxIs(rt, "I64");
                u32 t = spvType(rt);
                u32 sv = ((Number*)shVars.get(di)).asU32();
                u32 pW = m.ptrType((u32)SPV_ST_WORKGROUP, t);
                u32 src = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_FUNCTION, t),
                                   spvA2(_sLocalObj, m.u32c(((Number*)_sMember.get((Hashable*)String.withU32(k))).asU32())));
                u32 val = spvEmitR((u32)SPV_LOAD, t, spvA1(src));
                u32 mine = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, lid32));
                spvEmit((u32)SPV_STORE, spvA2(mine, val));
                spvEmit((u32)SPV_CONTROLBARRIER, spvA3(scope, scope, sem));
                for (u32 lvl = (u32)128; lvl >= (u32)1; lvl = lvl / (u32)2)
                    {
                    u32 swc = m.u32c(lvl);
                    u32 c = spvEmitR((u32)SPV_ULESSTHAN, boolT, spvA2(lid32, swc));
                    u32 body = spvLabel();
                    u32 mrg = spvLabel();
                    spvEmit((u32)SPV_SELECTIONMERGE, spvA2(mrg, (u32)0));
                    spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(c, body, mrg));
                    spvPlace(body);
                    u32 pa = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, lid32));
                    u32 a = spvEmitR((u32)SPV_LOAD, t, spvA1(pa));
                    u32 other = spvEmitR((u32)SPV_IADD, u32t, spvA2(lid32, swc));
                    u32 pb = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, other));
                    u32 b = spvEmitR((u32)SPV_LOAD, t, spvA1(pb));
                    u32 r = spvReduceVal(op, isF, sgn, t, boolT, a, b);
                    u32 pc = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, lid32));
                    spvEmit((u32)SPV_STORE, spvA2(pc, r));
                    spvEmit((u32)SPV_BRANCH, spvA1(mrg));
                    spvPlace(mrg);
                    spvEmit((u32)SPV_CONTROLBARRIER, spvA3(scope, scope, sem));
                    }
                u32 zero = m.u32c((u32)0);
                u32 c0 = spvEmitR((u32)SPV_IEQUAL, boolT, spvA2(lid32, zero));
                u32 wbody = spvLabel();
                u32 wmrg = spvLabel();
                spvEmit((u32)SPV_SELECTIONMERGE, spvA2(wmrg, (u32)0));
                spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(c0, wbody, wmrg));
                spvPlace(wbody);
                u32 p0 = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, zero));
                u32 v0 = spvEmitR((u32)SPV_LOAD, t, spvA1(p0));
                u32 dst = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_STORAGEBUFFER, t),
                                   spvA3(((Number*)redVars.get(di)).asU32(), zero, wg32));
                spvEmit((u32)SPV_STORE, spvA2(dst, v0));
                spvEmit((u32)SPV_BRANCH, spvA1(wmrg));
                spvPlace(wmrg);
                }
            spvEmit((u32)SPV_RETURN, new Array());
            spvEmit((u32)SPV_FUNCTIONEND, new Array());
            }
        else
        {
        u32 inRange = spvEmitR((u32)SPV_SLESSTHAN, m.typeBool(), spvA2(lo, spanHi));
        u32 write = spvLabel();
        u32 done = spvLabel();
        spvEmit((u32)SPV_SELECTIONMERGE, spvA2(done, (u32)0));
        spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(inRange, write, done));
        spvPlace(write);
        for (u32 ri = (u32)0; ri < redFields.count(); ri = ri + (u32)1)
            {
            u32 k = ((Number*)redFields.get(ri)).asU32();
            bool narrow = spvNarrowBytes(_mObj.typeAt(k)) != (u32)0;
            // A narrow field shares its 32-bit word: the word, shifted down to it.
            u32 mt = narrow ? m.typeInt((u32)32) : spvType(_mObj.typeAt(k));
            u32 src = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_FUNCTION, mt),
                               spvA2(_sLocalObj, m.u32c(((Number*)_sMember.get((Hashable*)String.withU32(k))).asU32())));
            u32 dst = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_STORAGEBUFFER, mt),
                               spvA3(((Number*)redVars.get(ri)).asU32(), m.u32c((u32)0), tid32));
            u32 val = spvEmitR((u32)SPV_LOAD, mt, spvA1(src));
            if (narrow)
                val = spvEmitR((u32)SPV_SHIFTRIGHTLOGICAL, mt,
                               spvA2(val, m.u32c(((Number*)_sNarrowShift.get((Hashable*)String.withI64((i64)k))).asU32())));
            spvEmit((u32)SPV_STORE, spvA2(dst, val));
            }
        spvEmit((u32)SPV_BRANCH, spvA1(done));
        spvPlace(done);
        spvEmit((u32)SPV_RETURN, new Array());
        spvEmit((u32)SPV_FUNCTIONEND, new Array());
        }
        if (_mWhy != (String*)0)
            return false;

        // The head, now that the interface is known.
        spvOp(m.head, (u32)SPV_MEMORYMODEL, spvA2((u32)0, (u32)1));
        Array* ep = new Array();
        ep.add((Object*)Number.withU32((u32)5));
        ep.add((Object*)Number.withU32(mainId));
        Array* nm = spvString(spvS("main"));
        for (u32 i = (u32)0; i < nm.count(); i = i + (u32)1) ep.add(nm.get(i));
        for (u32 i = (u32)0; i < iface.count(); i = i + (u32)1) ep.add(iface.get(i));
        spvOp(m.head, (u32)SPV_ENTRYPOINT, ep);
        // A device-side fold (bug 645): the workgroups' partials are combined
        // by a SECOND entry point of the same module, dispatched after the
        // kernel (the reference explains why not a counter).
        u32 foldId = (u32)0;
        if (devred)
            {
            foldId = m.newId();
            Array* fep = new Array();
            fep.add((Object*)Number.withU32((u32)5));
            fep.add((Object*)Number.withU32(foldId));
            Array* fnm = spvString(spvS("par_fold"));
            for (u32 i = (u32)0; i < fnm.count(); i = i + (u32)1) fep.add(fnm.get(i));
            fep.add((Object*)Number.withU32(lidV));
            fep.add((Object*)Number.withU32(argsV));
            fep.add((Object*)Number.withU32(spanV));
            for (u32 i = (u32)0; i < redVars.count(); i = i + (u32)1) fep.add(redVars.get(i));
            for (u32 i = (u32)0; i < shVars.count(); i = i + (u32)1) fep.add(shVars.get(i));
            spvOp(m.head, (u32)SPV_ENTRYPOINT, fep);
            }
        spvOp(m.head, (u32)SPV_EXECUTIONMODE, spvW((u32)5, mainId, (u32)17, (u32)256, (u32)1, (u32)1, (u32)0));
        if (devred)
            spvOp(m.head, (u32)SPV_EXECUTIONMODE, spvW((u32)5, foldId, (u32)17, (u32)256, (u32)1, (u32)1, (u32)0));
        for (u32 i = (u32)0; i < header.count(); i = i + (u32)1) m.funcs.add(header.get(i));
        spvFinish(fn, m.funcs);

        // The fold function's body (its entry point is already in the head):
        // one workgroup of 256, each lane accumulating the partials it owns
        // from the identity the block object holds, then the same workgroup
        // tree the kernel's own device reduction runs, and the result in slot 0.
        if (devred)
            {
            SpvFn* ffn = new SpvFn();
            _spvFn = ffn;
            u32 fi64 = _sSpan32 ? m.typeInt((u32)32) : m.typeInt((u32)64);
            u32 fpI64 = m.ptrType((u32)SPV_ST_PUSHCONSTANT, fi64);
            u32 fscope = m.u32c((u32)2);      // Workgroup
            u32 fsem = m.u32c((u32)0x108);    // AcquireRelease | WorkgroupMemory
            Array* foldHeader = new Array();
            spvOp(foldHeader, (u32)SPV_FUNCTION, spvW((u32)4, voidT, foldId, (u32)0, fnT, (u32)0, (u32)0));
            spvPlace(spvLabel());
            u32 flidv = spvEmitR((u32)SPV_LOAD, uvec3, spvA1(lidV));
            u32 flid = spvEmitR((u32)SPV_COMPOSITEEXTRACT, u32t, spvA2(flidv, (u32)0));
            u32 fpn = spvEmitR((u32)SPV_ACCESSCHAIN, fpI64, spvA2(spanV, m.u32c((u32)3)));
            u32 fnload = spvEmitR((u32)SPV_LOAD, fi64, spvA1(fpn));
            u32 fnparts = _sSpan32 ? fnload : spvEmitR((u32)SPV_UCONVERT, u32t, spvA1(fnload));
            for (u32 di = (u32)0; di < redFields.count(); di = di + (u32)1)
                {
                u32 k = ((Number*)redFields.get(di)).asU32();
                String* rt = _mObj.typeAt(k);
                String* op = (String*)_mRedOps.get((Hashable*)String.withU32(k));
                bool isF = self.ptxIs(rt, "F32") || self.ptxIs(rt, "F64");
                bool sgn = self.ptxIs(rt, "I32") || self.ptxIs(rt, "I64");
                u32 t = spvType(rt);
                u32 bT = m.typeBool();
                u32 sv = ((Number*)shVars.get(di)).asU32();
                u32 pW = m.ptrType((u32)SPV_ST_WORKGROUP, t);
                u32 pRv = m.ptrType((u32)SPV_ST_STORAGEBUFFER, t);
                // The identity the object holds: a lane with no partial of its
                // own leaves the answer unchanged.
                u32 idSrc = spvEmitR((u32)SPV_ACCESSCHAIN, m.ptrType((u32)SPV_ST_STORAGEBUFFER, t),
                                     spvA2(argsV, m.u32c(((Number*)_sMember.get((Hashable*)String.withU32(k))).asU32())));
                u32 acc = spvLocalVar(t);
                spvEmit((u32)SPV_STORE, spvA2(acc, spvEmitR((u32)SPV_LOAD, t, spvA1(idSrc))));
                u32 jv = spvLocalVar(u32t);
                spvEmit((u32)SPV_STORE, spvA2(jv, flid));
                u32 lhead = spvLabel();
                u32 lcheck = spvLabel();
                u32 lbody = spvLabel();
                u32 lcont = spvLabel();
                u32 lmerge = spvLabel();
                spvEmit((u32)SPV_BRANCH, spvA1(lhead));
                spvPlace(lhead);
                spvEmit((u32)SPV_LOOPMERGE, spvA3(lmerge, lcont, (u32)0));
                spvEmit((u32)SPV_BRANCH, spvA1(lcheck));
                spvPlace(lcheck);
                u32 more = spvEmitR((u32)SPV_ULESSTHAN, bT, spvA2(spvEmitR((u32)SPV_LOAD, u32t, spvA1(jv)), fnparts));
                spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(more, lbody, lmerge));
                spvPlace(lbody);
                u32 fa = spvEmitR((u32)SPV_LOAD, t, spvA1(acc));
                u32 fjl = spvEmitR((u32)SPV_LOAD, u32t, spvA1(jv));
                u32 fpb = spvEmitR((u32)SPV_ACCESSCHAIN, pRv,
                                   spvA3(((Number*)redVars.get(di)).asU32(), m.u32c((u32)0), fjl));
                u32 fb = spvEmitR((u32)SPV_LOAD, t, spvA1(fpb));
                spvEmit((u32)SPV_STORE, spvA2(acc, spvReduceVal(op, isF, sgn, t, bT, fa, fb)));
                spvEmit((u32)SPV_BRANCH, spvA1(lcont));
                spvPlace(lcont);
                spvEmit((u32)SPV_STORE, spvA2(jv, spvEmitR((u32)SPV_IADD, u32t,
                                                          spvA2(fjl, m.u32c((u32)256)))));
                spvEmit((u32)SPV_BRANCH, spvA1(lhead));
                spvPlace(lmerge);
                u32 fmine = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, flid));
                spvEmit((u32)SPV_STORE, spvA2(fmine, spvEmitR((u32)SPV_LOAD, t, spvA1(acc))));
                spvEmit((u32)SPV_CONTROLBARRIER, spvA3(fscope, fscope, fsem));
                for (u32 lvl = (u32)128; lvl >= (u32)1; lvl = lvl / (u32)2)
                    {
                    u32 swc = m.u32c(lvl);
                    u32 c = spvEmitR((u32)SPV_ULESSTHAN, bT, spvA2(flid, swc));
                    u32 tb = spvLabel();
                    u32 tm = spvLabel();
                    spvEmit((u32)SPV_SELECTIONMERGE, spvA2(tm, (u32)0));
                    spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(c, tb, tm));
                    spvPlace(tb);
                    u32 pa = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, flid));
                    u32 ta = spvEmitR((u32)SPV_LOAD, t, spvA1(pa));
                    u32 other = spvEmitR((u32)SPV_IADD, u32t, spvA2(flid, swc));
                    u32 pbo = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, other));
                    u32 tbo = spvEmitR((u32)SPV_LOAD, t, spvA1(pbo));
                    spvEmit((u32)SPV_STORE, spvA2(pa, spvReduceVal(op, isF, sgn, t, bT, ta, tbo)));
                    spvEmit((u32)SPV_BRANCH, spvA1(tm));
                    spvPlace(tm);
                    spvEmit((u32)SPV_CONTROLBARRIER, spvA3(fscope, fscope, fsem));
                    }
                u32 zero = m.u32c((u32)0);
                u32 c0 = spvEmitR((u32)SPV_IEQUAL, bT, spvA2(flid, zero));
                u32 wb = spvLabel();
                u32 wm = spvLabel();
                spvEmit((u32)SPV_SELECTIONMERGE, spvA2(wm, (u32)0));
                spvEmit((u32)SPV_BRANCHCONDITIONAL, spvA3(c0, wb, wm));
                spvPlace(wb);
                u32 s0 = spvEmitR((u32)SPV_ACCESSCHAIN, pW, spvA2(sv, zero));
                u32 dst = spvEmitR((u32)SPV_ACCESSCHAIN, pRv,
                                   spvA3(((Number*)redVars.get(di)).asU32(), zero, zero));
                spvEmit((u32)SPV_STORE, spvA2(dst, spvEmitR((u32)SPV_LOAD, t, spvA1(s0))));
                spvEmit((u32)SPV_BRANCH, spvA1(wm));
                spvPlace(wm);
                }
            spvEmit((u32)SPV_RETURN, new Array());
            spvEmit((u32)SPV_FUNCTIONEND, new Array());
            for (u32 i = (u32)0; i < foldHeader.count(); i = i + (u32)1) m.funcs.add(foldHeader.get(i));
            spvFinish(ffn, m.funcs);
            }

        Array* words = m.bytes();
        if (devred) meta.appendCString(" devred devlast");
        meta.appendCString(" spirv=");
        meta.append(String.withU32(words.count() / (u32)4));
        if (_mFast) meta.appendCString(" fast");
        meta.appendCString("\n");
        Array* out = new Array();
        for (u32 i = (u32)0; i < meta.byteLength(); i = i + (u32)1)
            out.add((Object*)Number.withU8(meta.byteAt(i)));
        out.add((Object*)Number.withU8((u8)0));
        while (out.count() % (u32)4 != (u32)0)
            out.add((Object*)Number.withU8((u8)0));
        for (u32 i = (u32)0; i < words.count(); i = i + (u32)1)
            out.add(words.get(i));
        _sOut = out;
        return true;
        }
    }
