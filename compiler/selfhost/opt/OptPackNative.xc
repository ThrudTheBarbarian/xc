// OptPackNative.xc — the PackNative pass, ported from src/xtc/ir/XTIROptPackNative.m.
// One of the files class Opt is split into, so the split build compiles the
// optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (PackNative)
    {
    // ── pack-native ──────────────────────────────────────────────────────
    //
    // The 16-bit floats' FloatPack calls the target can do in its own
    // instructions (float sizes, step F5a), each rewritten into IR whose
    // result is the call's bit for bit: bf16 by integer operations (the
    // pattern is the top half of an f32; round to nearest even on the bits,
    // a NaN made quiet), f16 by `FpExt`/`FpTrunc` on its U16 pattern, which
    // the back end lowers to its half-precision conversions, and, where the
    // target has FEAT_FP16, an f32 operation of two widened halves rounded
    // back to f16 as the operation on the halves; the 8- and 4-bit packs
    // (step P2) widen by a load from a table of their values, which the pass
    // adds to the module at the first use, and narrow from f32 by a
    // branch-free sequence. The last pass, at every level; it adds no block.
    // The reference says the rest.
    // Float dispatch: an `avx2`/`avx512` clone takes F16C, an `fp16` clone
    // FEAT_FP16 arithmetic; an fp16 clone with no half operation is its base's
    // code, and goes, and the base of one that stays is dispatched.
    final void packNative(IRModule* m)
        {
        if (!_profile.packF16Hw() && !_profile.packBf16() && !_profile.packF8())
            return;
        Array* keep = new Array();
        bool dropped = false;
        u32 nf = m.funcs().count();
        for (u32 f = 0; f < nf; f = f + 1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            pnFunc(fn, m);
            keep.add((Object*)fn);
            if (fn.simdLevel() == (String*)0 || !fn.simdLevel().equals(String.withCString("fp16")))
                continue;
            IRFunc* base = (IRFunc*)0;
            for (u32 g = 0; g < nf; g = g + 1)
                if (((IRFunc*)m.funcs().get(g)).name().equals(fn.simdBaseName()))
                    base = (IRFunc*)m.funcs().get(g);
            // Asked of the result, not of this run, so that IR this pass
            // already rewrote keeps its clones. As the reference.
            if (base != (IRFunc*)0 && pnHasHalfOp(fn))
                base.setSimdDispatch(true);
            else
                {
                keep.removeAt(keep.count() - 1);
                dropped = true;
                }
            }
        if (!dropped)
            return;
        while (m.funcs().count() > (u32)0)
            m.funcs().removeAt(m.funcs().count() - (u32)1);
        for (u32 f = 0; f < keep.count(); f = f + 1)
            m.funcs().add(keep.get(f));
        }

    // A half-precision operation or comparison, scalar or in lanes: what
    // FEAT_FP16 adds.
    final bool pnHasHalfOp(IRFunc* fn)
        {
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                {
                IRInsn* x = (IRInsn*)bb.insns().get(i);
                // The vectoriser's f16 lane operations (P1).
                if (x.isOp(opVHAdd) || x.isOp(opVHSub) || x.isOp(opVHMul) || x.isOp(opVHDiv) || x.isOp(opVHSqrt))
                    return true;
                if ((x.isOp(opFAdd) || x.isOp(opFSub) || x.isOp(opFMul) || x.isOp(opFDiv) || x.isOp(opFSqrt))
                    && x.res() != (IRValue*)0 && IRType.is(x.res().ty(), tyU16))
                    return true;
                if (x.isOp(opFCmp) && x.ops().count() > 0)
                    {
                    IROperand* o = (IROperand*)x.ops().get(0);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && IRType.is(o.val().ty(), tyU16))
                        return true;
                    }
                }
            }
        return false;
        }

    // Does fn call one of FloatPack's f16 conversions that a level with F16C
    // or FEAT_FP16 would rewrite: any but the one from f64? simd-clone asks.
    // As the reference's functionHasHalfCall.
    final bool pnHasHalfCall(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                {
                u32 code = pnKind((IRInsn*)bb.insns().get(i), defOf);
                if (code % 4 == 1 && code / 4 != 3)
                    return true;
                }
            }
        return false;
        }

    // An operand's integer constant (an immediate, or a Use of a Const), or -1.
    final i64 pnConst(IROperand* o, Map* defOf)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return o.imm();
        if (o.kind() != (u8)OPK_USE)
            return -1;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || !d.isOp(opConst) || d.ops().count() < 1)
            return -1;
        IROperand* k = (IROperand*)d.ops().get(0);
        if (k.kind() != (u8)OPK_IMMI)
            return -1;
        return k.imm();
        }

    // A direct call of one of FloatPack's conversions for f16 or bf16, as
    // [callee, value, e, m, mem] with the value a Use: kind * 4 + pack, with
    // kind 1 unpack, 2 from f32, 3 from f64, 4 i32, 5 u32, 6 i64, 7 u64 and
    // pack 1 f16, 2 bf16; 0 for anything else.
    final u32 pnKind(IRInsn* n, Map* defOf)
        {
        if (!n.isOp(opCall) || n.res() == (IRValue*)0 || n.ops().count() != 5)
            return 0;
        IROperand* c = (IROperand*)n.ops().get(0);
        if (c.kind() != (u8)OPK_SYM || c.name() == (String*)0)
            return 0;
        String* nm = c.name();
        if (!nm.hasPrefix(String.withCString("_xt_fpk_")))
            return 0;
        u32 k = 0;
        if (nm.equals(String.withCString("_xt_fpk_unpack")))
            k = 1;
        else if (nm.equals(String.withCString("_xt_fpk_pack_f32")))
            k = 2;
        else if (nm.equals(String.withCString("_xt_fpk_pack_f64")))
            k = 3;
        else if (nm.equals(String.withCString("_xt_fpk_pack_i32")))
            k = 4;
        else if (nm.equals(String.withCString("_xt_fpk_pack_u32")))
            k = 5;
        else if (nm.equals(String.withCString("_xt_fpk_pack_i64")))
            k = 6;
        else if (nm.equals(String.withCString("_xt_fpk_pack_u64")))
            k = 7;
        if (k == 0 || ((IROperand*)n.ops().get(1)).kind() != (u8)OPK_USE)
            return 0;
        i64 e = pnConst((IROperand*)n.ops().get(2), defOf);
        i64 m = pnConst((IROperand*)n.ops().get(3), defOf);
        if (e == 5 && m == 10)
            return k * 4 + 1;
        if (e == 8 && m == 7)
            return k * 4 + 2;
        return 0;
        }

    // A direct call of FloatPack's widening of a pack of at most 8 bits
    // (`_xt_fpk_unpack` [callee, value, e, m, mem], `_xt_fpk_unpackk`
    // [callee, value, e, m, k, mem]) with constant widths and word: the pack
    // as e * 256 + m * 16 + k (k's special-value bits alone; 8 and 16 change
    // only the narrowing), or -1. As the reference's tableCall.
    final i64 pnTableCall(IRInsn* n, Map* defOf)
        {
        if (!n.isOp(opCall) || n.res() == (IRValue*)0 || n.ops().count() < 5)
            return -1;
        IROperand* c = (IROperand*)n.ops().get(0);
        if (c.kind() != (u8)OPK_SYM || c.name() == (String*)0)
            return -1;
        bool kinds = c.name().equals(String.withCString("_xt_fpk_unpackk"));
        if (!kinds && !c.name().equals(String.withCString("_xt_fpk_unpack")))
            return -1;
        u32 want = 5;
        if (kinds)
            want = 6;
        if (n.ops().count() != want || ((IROperand*)n.ops().get(1)).kind() != (u8)OPK_USE)
            return -1;
        i64 e = pnConst((IROperand*)n.ops().get(2), defOf);
        i64 m = pnConst((IROperand*)n.ops().get(3), defOf);
        if (e < 0 || m < 0)
            return -1;
        i64 k = 0;
        if (kinds)
            {
            k = pnConst((IROperand*)n.ops().get(4), defOf);
            if (k < 0)
                return -1;
            }
        k = k & 7;
        if ((k & 4) == 0 && (e < 2 || m < 1 || e + m > 7 || (k & 3) == 3))
            return -1;
        if (e > 15 || m > 15)
            return -1;
        return e * 256 + m * 16 + k;
        }

    // A direct call of FloatPack's narrowing from f32 to a signed pack of at
    // most 8 bits (`_xt_fpk_pack_f32` [callee, value, e, m, mem],
    // `_xt_fpk_pack_f32k` [callee, value, e, m, k, mem]) with constant widths
    // and a word of the kind alone: e * 256 + m * 16 + kind, or -1. As the
    // reference's narrowCall.
    final i64 pnNarrowCall(IRInsn* n, Map* defOf)
        {
        if (!n.isOp(opCall) || n.res() == (IRValue*)0 || n.ops().count() < 5)
            return -1;
        IROperand* c = (IROperand*)n.ops().get(0);
        if (c.kind() != (u8)OPK_SYM || c.name() == (String*)0)
            return -1;
        bool kinds = c.name().equals(String.withCString("_xt_fpk_pack_f32k"));
        if (!kinds && !c.name().equals(String.withCString("_xt_fpk_pack_f32")))
            return -1;
        u32 want = 5;
        if (kinds)
            want = 6;
        if (n.ops().count() != want || ((IROperand*)n.ops().get(1)).kind() != (u8)OPK_USE)
            return -1;
        i64 e = pnConst((IROperand*)n.ops().get(2), defOf);
        i64 m = pnConst((IROperand*)n.ops().get(3), defOf);
        i64 k = 0;
        if (kinds)
            k = pnConst((IROperand*)n.ops().get(4), defOf);
        if (k < 0 || k > 2 || e < 2 || m < 1 || e + m > 7)
            return -1;
        return e * 256 + m * 16 + k;
        }

    // f32 to a signed pack of at most 8 bits, as FloatPack's rounding gives
    // it, without a branch: below the smallest normal an f32 addition rounds
    // to the subnormal spacing, above it the bits round on the integer; then
    // the kind's saturation, the sign and a NaN. As the reference's narrow,
    // which says more.
    final void pnNarrow(IRInsn* n, i64 tp, Array* out, Map* defOf, Array* maybeDead)
        {
        IROperand* src = (IROperand*)n.ops().get(1);
        for (u32 j = 2; j + 1 < n.ops().count(); j = j + 1)
            {
            IROperand* o = (IROperand*)n.ops().get(j);
            if (o.kind() == (u8)OPK_USE)
                maybeDead.add((Object*)o.val());
            }
        u32 e = (u32)(tp / 256);
        u32 m = (u32)((tp / 16) % 16);
        u32 kind = (u32)(tp % 16);
        u32 one = 1;
        u32 bias = (one << (e - one)) - one;
        u32 sh = 23 - m;
        u32 all = (one << (e + m)) - one;
        u32 inf = ((one << e) - one) << m;
        u32 mmax = (one << m) - one;
        u32 lim = all;
        if (kind == 0)
            lim = inf;
        else if (kind == 1)
            lim = all - one;
        u32 magic = (151 - bias - m) << 23;
        IRInsn* x = pnEmit(out, defOf, n, "Bitcast", "U32", (IRValue*)0);
        x.add(src);
        IRInsn* a = pnEmit(out, defOf, n, "And", "U32", (IRValue*)0);
        a.add(IROperand.useVal(x.res()));
        a.add(pnImm(2147483647));
        IRInsn* fa = pnEmit(out, defOf, n, "Bitcast", "F32", (IRValue*)0);
        fa.add(IROperand.useVal(a.res()));
        // The constant 2^(24-bias-m) as f64 bits, spelled as the printer does.
        u64 md = (u64)(1047 - bias - m) << 52;
        string digits = "0123456789abcdef";
        String* hex = String.withCString("");
        for (i32 b = 60; b >= 0; b = b - 4)
            hex.appendByte(digits[(u32)((md >> (u64)b) & (u64)$F)]);
        IRInsn* c = pnEmit(out, defOf, n, "Const", "F32", (IRValue*)0);
        c.add(IROperand.immF(hex, String.withCString("F32")));
        IRInsn* fs = pnEmit(out, defOf, n, "FAdd", "F32", (IRValue*)0);
        fs.add(IROperand.useVal(fa.res()));
        fs.add(IROperand.useVal(c.res()));
        IRInsn* sb = pnEmit(out, defOf, n, "Bitcast", "U32", (IRValue*)0);
        sb.add(IROperand.useVal(fs.res()));
        IRInsn* sub = pnEmit(out, defOf, n, "Sub", "U32", (IRValue*)0);
        sub.add(IROperand.useVal(sb.res()));
        sub.add(pnImm(magic));
        IRInsn* hi = pnEmit(out, defOf, n, "LShr", "U32", (IRValue*)0);
        hi.add(IROperand.useVal(a.res()));
        hi.add(pnImm(sh));
        IRInsn* lsb = pnEmit(out, defOf, n, "And", "U32", (IRValue*)0);
        lsb.add(IROperand.useVal(hi.res()));
        lsb.add(pnImm(1));
        IRInsn* t1 = pnEmit(out, defOf, n, "Add", "U32", (IRValue*)0);
        t1.add(IROperand.useVal(a.res()));
        t1.add(pnImm((one << (sh - one)) - one));
        IRInsn* t2 = pnEmit(out, defOf, n, "Add", "U32", (IRValue*)0);
        t2.add(IROperand.useVal(t1.res()));
        t2.add(IROperand.useVal(lsb.res()));
        IRInsn* t3 = pnEmit(out, defOf, n, "LShr", "U32", (IRValue*)0);
        t3.add(IROperand.useVal(t2.res()));
        t3.add(pnImm(sh));
        IRInsn* nrm = pnEmit(out, defOf, n, "Sub", "U32", (IRValue*)0);
        nrm.add(IROperand.useVal(t3.res()));
        nrm.add(pnImm((127 - bias) << m));
        IRInsn* isSub = pnEmit(out, defOf, n, "ICmp", "Bool", (IRValue*)0);
        isSub.setPred(String.withCString("ULT"));
        isSub.add(IROperand.useVal(a.res()));
        isSub.add(pnImm((128 - bias) << 23));
        IRInsn* q = pnEmit(out, defOf, n, "Select", "U32", (IRValue*)0);
        q.add(IROperand.useVal(isSub.res()));
        q.add(IROperand.useVal(sub.res()));
        q.add(IROperand.useVal(nrm.res()));
        IRInsn* big = pnEmit(out, defOf, n, "ICmp", "Bool", (IRValue*)0);
        big.setPred(String.withCString("UGT"));
        big.add(IROperand.useVal(q.res()));
        big.add(pnImm(lim));
        IRInsn* cl = pnEmit(out, defOf, n, "Const", "U32", (IRValue*)0);
        cl.add(pnImm(lim));
        IRInsn* q2 = pnEmit(out, defOf, n, "Select", "U32", (IRValue*)0);
        q2.add(IROperand.useVal(big.res()));
        q2.add(IROperand.useVal(cl.res()));
        q2.add(IROperand.useVal(q.res()));
        IRInsn* sg = pnEmit(out, defOf, n, "LShr", "U32", (IRValue*)0);
        sg.add(IROperand.useVal(x.res()));
        sg.add(pnImm(31));
        IRInsn* sgs = pnEmit(out, defOf, n, "Shl", "U32", (IRValue*)0);
        sgs.add(IROperand.useVal(sg.res()));
        sgs.add(pnImm(e + m));
        IRInsn* r = pnEmit(out, defOf, n, "Or", "U32", (IRValue*)0);
        r.add(IROperand.useVal(sgs.res()));
        r.add(IROperand.useVal(q2.res()));
        IRInsn* isNan = pnEmit(out, defOf, n, "ICmp", "Bool", (IRValue*)0);
        isNan.setPred(String.withCString("UGT"));
        isNan.add(IROperand.useVal(a.res()));
        isNan.add(pnImm(2139095040));
        IRInsn* nanv = (IRInsn*)0;
        if (kind == 0)
            {
            IRInsn* top = pnEmit(out, defOf, n, "And", "U32", (IRValue*)0);
            top.add(IROperand.useVal(hi.res()));
            top.add(pnImm(mmax));
            IRInsn* qn = pnEmit(out, defOf, n, "Or", "U32", (IRValue*)0);
            qn.add(IROperand.useVal(top.res()));
            qn.add(pnImm(inf | (one << (m - one))));
            nanv = pnEmit(out, defOf, n, "Or", "U32", (IRValue*)0);
            nanv.add(IROperand.useVal(sgs.res()));
            nanv.add(IROperand.useVal(qn.res()));
            }
        else if (kind == 1)
            {
            nanv = pnEmit(out, defOf, n, "Or", "U32", (IRValue*)0);
            nanv.add(IROperand.useVal(sgs.res()));
            nanv.add(pnImm(all));
            }
        else
            {
            nanv = pnEmit(out, defOf, n, "Const", "U32", (IRValue*)0);
            nanv.add(pnImm(0));
            }
        IRInsn* sel = pnEmit(out, defOf, n, "Select", "U32", (IRValue*)0);
        sel.add(IROperand.useVal(isNan.res()));
        sel.add(IROperand.useVal(nanv.res()));
        sel.add(IROperand.useVal(r.res()));
        IRInsn* t = pnEmit(out, defOf, n, "Trunc", "U16", n.res());
        t.add(IROperand.useVal(sel.res()));
        }

    // The f32 bits of pattern h of pack (e, m, k): FloatPackKinds'
    // `_xt_fpk_unpackk`, step for step, which for k = 0 and at most 6
    // exponent bits is FloatPack's `_xt_fpk_unpack`. As the reference.
    final u32 pnTableBits(u32 h, u32 e, u32 m, u32 k)
        {
        u32 one = 1;
        u32 x = h;
        u32 bits = 0;
        if ((k & 4) != 0)
            {
            u32 ue = x & (u32)255;
            if (ue == (u32)255)
                bits = (u32)$7FC00000;
            else if (ue == 0)
                bits = (u32)$00400000;
            else
                bits = ue << 23;
            return bits;
            }
        u32 sign = (x >> (e + m)) & one;
        u32 emax = (one << e) - one;
        u32 mmax = (one << m) - one;
        u32 ex = (x >> m) & emax;
        u32 mant = x & mmax;
        u32 sh = 23 - m;
        i32 bias = (i32)((one << (e - one)) - one);
        u32 kind = k & 3;
        if (ex == emax && kind == 0)
            bits = (u32)$7F800000 | (mant << sh);
        else if (ex == emax && kind == 1 && mant == mmax)
            bits = (u32)$7FC00000;
        else if (ex == 0)
            {
            if (mant != 0)
                {
                i32 unb = 1 - bias;
                while ((mant & (one << m)) == 0)
                    {
                    mant = mant << 1;
                    unb = unb - 1;
                    }
                bits = ((u32)(unb + 127) << 23) | ((mant & mmax) << sh);
                }
            }
        else
            bits = ((u32)((i32)ex - bias + 127) << 23) | (mant << sh);
        return bits | (sign << 31);
        }

    // The module's table for the pack (pnTableCall's word), made at its first
    // use: a module-local string literal of the pack's 2^(1+e+m) values (256
    // for ue8m0) as little-endian f32 bits, on a 4-byte boundary (align4),
    // named by the pack. As the reference's tableFor.
    final String* pnTableFor(i64 tp, IRModule* m)
        {
        u32 e = (u32)(tp / 256);
        u32 mb = (u32)((tp / 16) % 16);
        u32 k = (u32)(tp % 16);
        String* nm = new String();
        if ((k & 4) != 0)
            nm.appendCString("_xt_fpk_tab_ue8m0");
        else if ((k & 3) == 0)
            nm.appendFormat("_xt_fpk_tab_e%um%u_ieee", e, mb);
        else if ((k & 3) == 1)
            nm.appendFormat("_xt_fpk_tab_e%um%u_finite", e, mb);
        else
            nm.appendFormat("_xt_fpk_tab_e%um%u_none", e, mb);
        if (self.symNamed(m, nm) != (IRSymbol*)0)
            return nm;
        u32 count = 256;
        if ((k & 4) == 0)
            count = (u32)1 << (1 + e + mb);
        Array* bytes = new Array();
        for (u32 h = 0; h < count; h = h + 1)
            {
            u32 b = pnTableBits(h, e, mb, k);
            bytes.add((Object*)Number.with(b & (u32)255));
            bytes.add((Object*)Number.with((b >> 8) & (u32)255));
            bytes.add((Object*)Number.with((b >> 16) & (u32)255));
            bytes.add((Object*)Number.with(b >> 24));
            }
        IRSymbol* sym = IRSymbol.stringLit(nm, bytes);
        sym.setAttr(String.withCString("align4"), true);
        m.addSym(sym);
        return nm;
        }

    // An 8- or 4-bit pack widened by a load from its table: the index `ZExt
    // U32` of the pattern (of the byte, when it is a widened byte) and `And
    // mask` unless that byte needs none, `AddrOf` the table, `ElementAddr`,
    // `Load F32` taking the call's memory token and giving its result. As the
    // reference's tableLoad.
    final void pnTableLoad(IRInsn* n, i64 tp, Array* out, Map* defOf, Array* maybeDead, IRModule* m)
        {
        IROperand* src = (IROperand*)n.ops().get(1);
        for (u32 j = 2; j + 1 < n.ops().count(); j = j + 1)
            {
            IROperand* o = (IROperand*)n.ops().get(j);
            if (o.kind() == (u8)OPK_USE)
                maybeDead.add((Object*)o.val());
            }
        u32 k = (u32)(tp % 16);
        u32 count = 256;
        if ((k & 4) == 0)
            count = (u32)1 << (1 + (u32)(tp / 256) + (u32)((tp / 16) % 16));
        // A pattern widened from a byte is indexed by the byte.
        bool inRange = false;
        IROperand* narrow = src;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)src.val());
        if (d != (IRInsn*)0 && d.isOp(opZExt) && d.ops().count() == 1)
            {
            IROperand* dv = (IROperand*)d.ops().get(0);
            if (dv.kind() == (u8)OPK_USE && dv.val() != (IRValue*)0 && IRType.is(dv.val().ty(), tyU8))
                {
                IRInsn* w = (IRInsn*)defOf.get((Hashable*)dv.val());
                narrow = dv;
                maybeDead.add((Object*)src.val());
                if (count == 256)
                    inRange = true;
                else if (w != (IRInsn*)0 && w.isOp(opAnd) && w.ops().count() == 2)
                    {
                    i64 c = pnConst((IROperand*)w.ops().get(1), defOf);
                    if (c >= 0 && (c & ~(i64)(count - 1)) == 0)
                        inRange = true;
                    }
                }
            }
        IRInsn* z = pnEmit(out, defOf, n, "ZExt", "U32", (IRValue*)0);
        z.add(narrow);
        IROperand* idx = IROperand.useVal(z.res());
        if (!inRange)
            {
            IRInsn* a = pnEmit(out, defOf, n, "And", "U32", (IRValue*)0);
            a.add(IROperand.useVal(z.res()));
            a.add(pnImm(count - 1));
            idx = IROperand.useVal(a.res());
            }
        String* nm = pnTableFor(tp, m);
        IRInsn* base = pnEmit(out, defOf, n, "AddrOf", "Ptr(F32, unbanked)", (IRValue*)0);
        base.add(IROperand.sym(nm));
        IRInsn* ea = pnEmit(out, defOf, n, "ElementAddr", "Ptr(F32, unbanked)", (IRValue*)0);
        ea.add(IROperand.useVal(base.res()));
        ea.add(idx);
        IRInsn* ld = pnEmit(out, defOf, n, "Load", "F32", n.res());
        ld.add(IROperand.useVal(ea.res()));
        ld.add((IROperand*)n.ops().get(n.ops().count() - 1));
        ld.setMemRes(n.memRes());
        }

    // A new instruction located as `from`, with result res (a fresh value of
    // type ty when res is null), appended to list.
    final IRInsn* pnEmit(Array* list, Map* defOf, IRInsn* from, string op, string ty, IRValue* res)
        {
        IRInsn* n = IRInsn.with(String.withCString(op));
        n.copyDbg(from);
        IRValue* r = res;
        if (r == (IRValue*)0)
            r = new IRValue(String.withCString(ty));
        n.setRes(r);
        list.add((Object*)n);
        defOf.set((Hashable*)r, (Object*)n);
        return n;
        }

    final IROperand* pnImm(i64 v)
        {
        return IROperand.immI(v, String.withCString("U32"));
        }

    final void pnFunc(IRFunc* fn, IRModule* m)
        {
        Map* defOf = self.defMap(fn);
        String* lvl = fn.simdLevel();
        bool hw = _profile.packF16Hw()
                  || (lvl != (String*)0 && (lvl.equals(String.withCString("avx2")) || lvl.equals(String.withCString("avx512"))));
        bool arith = _profile.packF16Arith() || (lvl != (String*)0 && lvl.equals(String.withCString("fp16")));
        bool any = false;
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                if (((IRInsn*)bb.insns().get(i)).isOp(opCall))
                    any = true;
            }
        if (!any)
            return;

        // Every call this pass may rewrite, and for an f16 unpack the half it
        // reads.
        Map* unpackSrc = new Map();
        bool found = false;
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (_profile.packF8() && (pnTableCall(n, defOf) != -1 || pnNarrowCall(n, defOf) != -1))
                    found = true;
                u32 code = pnKind(n, defOf);
                if (code == 0)
                    continue;
                found = true;
                if (code == 5 && hw)
                    unpackSrc.set((Hashable*)n.res(), n.ops().get(1));
                }
            }
        if (!found)
            return;

        Map* uses = self.useCounts(fn);
        Array* maybeDead = new Array();
        Array* widened = new Array();
        Array* memFrom = new Array();
        Array* memTo = new Array();

        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* out = new Array();
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (_profile.packF8())
                    {
                    i64 tp = pnTableCall(n, defOf);
                    if (tp != -1)
                        {
                        pnTableLoad(n, tp, out, defOf, maybeDead, m);
                        continue;
                        }
                    tp = pnNarrowCall(n, defOf);
                    if (tp != -1)
                        {
                        pnNarrow(n, tp, out, defOf, maybeDead);
                        IROperand* mi = (IROperand*)n.ops().get(n.ops().count() - 1);
                        if (n.memRes() != (IRValue*)0 && mi.kind() == (u8)OPK_USE)
                            {
                            memFrom.add((Object*)n.memRes());
                            memTo.add((Object*)mi.val());
                            }
                        continue;
                        }
                    }
                u32 code = pnKind(n, defOf);
                u32 k = code / 4;
                u32 pk = code % 4;
                bool rewrite = (pk == 2 && _profile.packBf16() && (k == 1 || k == 2))
                            || (pk == 1 && hw && (k != 3 || _profile.packF16From64()));
                if (!rewrite)
                    {
                    // A comparison of two widened halves compares the halves.
                    if (arith && n.isOp(opFCmp) && n.ops().count() == 2
                        && ((IROperand*)n.ops().get(0)).kind() == (u8)OPK_USE
                        && ((IROperand*)n.ops().get(1)).kind() == (u8)OPK_USE)
                        {
                        IRValue* v0 = ((IROperand*)n.ops().get(0)).val();
                        IRValue* v1 = ((IROperand*)n.ops().get(1)).val();
                        IROperand* ha = (IROperand*)unpackSrc.get((Hashable*)v0);
                        IROperand* hb = (IROperand*)unpackSrc.get((Hashable*)v1);
                        if (ha != (IROperand*)0 && hb != (IROperand*)0)
                            {
                            maybeDead.add((Object*)v0);
                            maybeDead.add((Object*)v1);
                            IRInsn* fc = IRInsn.with(String.withCString("FCmp"));
                            fc.copyDbg(n);
                            fc.setPred(n.pred());
                            fc.setRes(n.res());
                            fc.add(ha);
                            fc.add(hb);
                            out.add((Object*)fc);
                            defOf.set((Hashable*)n.res(), (Object*)fc);
                            continue;
                            }
                        }
                    out.add((Object*)n);
                    continue;
                    }
                IROperand* src = (IROperand*)n.ops().get(1);
                IRValue* res = n.res();
                for (u32 j = 2; j < 4; j = j + 1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(j);
                    if (o.kind() == (u8)OPK_USE)
                        maybeDead.add((Object*)o.val());
                    }
                if (pk == 2 && k == 1)
                    {
                    // The pattern is the top half of the f32.
                    IRInsn* z = pnEmit(out, defOf, n, "ZExt", "U32", (IRValue*)0);
                    z.add(src);
                    IRInsn* s = pnEmit(out, defOf, n, "Shl", "U32", (IRValue*)0);
                    s.add(IROperand.useVal(z.res()));
                    s.add(pnImm(16));
                    IRInsn* r = pnEmit(out, defOf, n, "Bitcast", "F32", res);
                    r.add(IROperand.useVal(s.res()));
                    }
                else if (pk == 2)
                    {
                    // Round to nearest even on the bits; a NaN keeps its sign
                    // and top payload and is made quiet.
                    IRInsn* x = pnEmit(out, defOf, n, "Bitcast", "U32", (IRValue*)0);
                    x.add(src);
                    IRInsn* hi = pnEmit(out, defOf, n, "LShr", "U32", (IRValue*)0);
                    hi.add(IROperand.useVal(x.res()));
                    hi.add(pnImm(16));
                    IRInsn* lsb = pnEmit(out, defOf, n, "And", "U32", (IRValue*)0);
                    lsb.add(IROperand.useVal(hi.res()));
                    lsb.add(pnImm(1));
                    IRInsn* t1 = pnEmit(out, defOf, n, "Add", "U32", (IRValue*)0);
                    t1.add(IROperand.useVal(x.res()));
                    t1.add(pnImm(32767));
                    IRInsn* t2 = pnEmit(out, defOf, n, "Add", "U32", (IRValue*)0);
                    t2.add(IROperand.useVal(t1.res()));
                    t2.add(IROperand.useVal(lsb.res()));
                    IRInsn* rne = pnEmit(out, defOf, n, "LShr", "U32", (IRValue*)0);
                    rne.add(IROperand.useVal(t2.res()));
                    rne.add(pnImm(16));
                    IRInsn* mag = pnEmit(out, defOf, n, "And", "U32", (IRValue*)0);
                    mag.add(IROperand.useVal(x.res()));
                    mag.add(pnImm(2147483647));
                    IRInsn* isNan = pnEmit(out, defOf, n, "ICmp", "Bool", (IRValue*)0);
                    isNan.setPred(String.withCString("UGT"));
                    isNan.add(IROperand.useVal(mag.res()));
                    isNan.add(pnImm(2139095040));
                    IRInsn* q = pnEmit(out, defOf, n, "Or", "U32", (IRValue*)0);
                    q.add(IROperand.useVal(hi.res()));
                    q.add(pnImm(64));
                    IRInsn* sel = pnEmit(out, defOf, n, "Select", "U32", (IRValue*)0);
                    sel.add(IROperand.useVal(isNan.res()));
                    sel.add(IROperand.useVal(q.res()));
                    sel.add(IROperand.useVal(rne.res()));
                    IRInsn* r = pnEmit(out, defOf, n, "Trunc", "U16", res);
                    r.add(IROperand.useVal(sel.res()));
                    }
                else if (k == 1)
                    {
                    IRInsn* w = pnEmit(out, defOf, n, "FpExt", "F32", res);
                    w.add(src);
                    widened.add((Object*)res);
                    }
                else if (k == 2)
                    {
                    // A half operation where the f32 one is of two widened
                    // halves (or one, for sqrt), read by this rounding alone.
                    IRInsn* d = (IRInsn*)defOf.get((Hashable*)src.val());
                    bool fused = false;
                    if (arith && d != (IRInsn*)0 && self.countOf(uses, src.val()) == 1)
                        {
                        bool bin = d.isOp(opFAdd) || d.isOp(opFSub) || d.isOp(opFMul) || d.isOp(opFDiv);
                        u32 arity = 0;
                        if (bin)
                            arity = 2;
                        else if (d.isOp(opFSqrt))
                            arity = 1;
                        if (arity != 0 && d.ops().count() == arity && d.res() != (IRValue*)0
                            && IRType.is(d.res().ty(), tyF32))
                            {
                            Array* hs = new Array();
                            for (u32 j = 0; j < d.ops().count(); j = j + 1)
                                {
                                IROperand* o = (IROperand*)d.ops().get(j);
                                IROperand* h = (IROperand*)0;
                                if (o.kind() == (u8)OPK_USE)
                                    h = (IROperand*)unpackSrc.get((Hashable*)o.val());
                                if (h == (IROperand*)0)
                                    break;
                                hs.add((Object*)h);
                                }
                            if (hs.count() == arity)
                                {
                                IRInsn* hn = pnEmit(out, defOf, n, d.op().cString(), "U16", res);
                                for (u32 j = 0; j < hs.count(); j = j + 1)
                                    hn.add((IROperand*)hs.get(j));
                                maybeDead.add((Object*)src.val());
                                fused = true;
                                }
                            }
                        }
                    if (!fused)
                        {
                        IRInsn* t = pnEmit(out, defOf, n, "FpTrunc", "U16", res);
                        t.add(src);
                        }
                    }
                else if (k == 3)
                    {
                    IRInsn* t = pnEmit(out, defOf, n, "FpTrunc", "U16", res);
                    t.add(src);
                    }
                else
                    {
                    // An integer: its f32 is exact, or past f16's range so
                    // that either way the half is an infinity.
                    bool sgn = k == 4 || k == 6;
                    IRInsn* f = pnEmit(out, defOf, n, sgn ? "SIToFp" : "UIToFp", "F32", (IRValue*)0);
                    f.add(src);
                    IRInsn* t = pnEmit(out, defOf, n, "FpTrunc", "U16", res);
                    t.add(IROperand.useVal(f.res()));
                    }
                // The routines are pure: their memory token is their input's.
                if (n.memRes() != (IRValue*)0)
                    {
                    IROperand* memIn = (IROperand*)n.ops().get(n.ops().count() - 1);
                    if (memIn.kind() == (u8)OPK_USE)
                        {
                        memFrom.add((Object*)n.memRes());
                        memTo.add((Object*)memIn.val());
                        }
                    }
                }
            bb.setInsns(out);
            }
        // In order, so a token forwarded to one that is itself forwarded
        // later ends at the first input.
        for (u32 j = 0; j < memFrom.count(); j = j + 1)
            {
            IRValue* to = (IRValue*)memTo.get(j);
            for (u32 q = 0; q < j; q = q + 1)
                if ((IRValue*)memFrom.get(q) == to)
                    to = (IRValue*)memTo.get(q);
            memTo.set(j, (Object*)to);
            self.forwardMem(fn, (IRValue*)memFrom.get(j), to);
            }

        uses = self.useCounts(fn);
        pnRemoveDead(fn, maybeDead, uses, defOf);
        for (u32 j = 0; j < widened.count(); j = j + 1)
            {
            IRValue* v = (IRValue*)widened.get(j);
            if (self.countOf(uses, v) > 0 && !pnQuietInvisible(fn, v))
                pnKeepSignalling(fn, v, defOf);
            }
        }

    // Drops the listed values' definitions that nothing uses any more, and
    // then theirs, as long as they are pure.
    final void pnRemoveDead(IRFunc* fn, Array* work, Map* uses, Map* defOf)
        {
        Map* gone = new Map();
        while (work.count() > 0)
            {
            IRValue* v = (IRValue*)work.last();
            work.removeLast();
            if (gone.get((Hashable*)v) != (Object*)0 || self.countOf(uses, v) > 0)
                continue;
            IRInsn* d = (IRInsn*)defOf.get((Hashable*)v);
            if (d == (IRInsn*)0 || d.memRes() != (IRValue*)0)
                continue;
            if (!(d.isOp(opConst) || d.isOp(opFpExt) || d.isOp(opZExt) || d.isOp(opFAdd) || d.isOp(opFSub)
                  || d.isOp(opFMul) || d.isOp(opFDiv) || d.isOp(opFSqrt)))
                continue;
            for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                u32 at = bb.insns().count();
                for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                    if ((IRInsn*)bb.insns().get(i) == d)
                        {
                        at = i;
                        break;
                        }
                if (at == bb.insns().count())
                    continue;
                bb.insns().removeAt(at);
                break;
                }
            gone.set((Hashable*)v, (Object*)v);
            for (u32 k = 0; k < d.ops().count(); k = k + 1)
                {
                IROperand* o = (IROperand*)d.ops().get(k);
                if (o.kind() != (u8)OPK_USE)
                    continue;
                u32 c = self.countOf(uses, o.val());
                if (c > 0)
                    uses.set((Hashable*)o.val(), (Object*)Number.with(c - 1));
                work.add((Object*)o.val());
                }
            }
        }

    final bool pnReads(IRInsn* n, IRValue* v)
        {
        for (u32 k = 0; k < n.ops().count(); k = k + 1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                return true;
            }
        return false;
        }

    // Can no use of the widened half v tell a quiet NaN from a signalling
    // one? The reference says which uses cannot.
    final bool pnQuietInvisible(IRFunc* fn, IRValue* v)
        {
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = 0; i < bb.phis().count(); i = i + 1)
                if (pnReads((IRInsn*)bb.phis().get(i), v))
                    return false;
            if (bb.term() != (IRInsn*)0 && pnReads(bb.term(), v))
                return false;
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!pnReads(n, v))
                    continue;
                if (n.isOp(opFCmp) || n.isOp(opFpExt) || n.isOp(opFpTrunc) || n.isOp(opFpToSI)
                    || n.isOp(opFpToUI) || n.isOp(opFSqrt))
                    continue;
                if ((n.isOp(opFAdd) || n.isOp(opFSub) || n.isOp(opFMul) || n.isOp(opFDiv))
                    && !_profile.packNanOrder())
                    continue;
                if (n.isOp(opCall) && n.ops().count() > 0)
                    {
                    IROperand* c = (IROperand*)n.ops().get(0);
                    if (c.kind() == (u8)OPK_SYM && c.name() != (String*)0
                        && c.name().hasPrefix(String.withCString("_xt_fpk_")))
                        {
                        // The half itself, never the memory token.
                        bool asArg = false;
                        for (u32 j = 1; j + 1 < n.ops().count(); j = j + 1)
                            {
                            IROperand* o = (IROperand*)n.ops().get(j);
                            if (o.kind() == (u8)OPK_USE && o.val() == v)
                                asArg = true;
                            }
                        if (asArg)
                            continue;
                        }
                    }
                return false;
                }
            }
        return true;
        }

    // FloatPack widens a signalling NaN to a signalling f32 where the
    // hardware makes it quiet: clear the quiet bit again for exactly the
    // halves 0x7C01..0x7DFF of either sign. The widening takes a new value
    // and the last instruction of the fix-up takes v.
    final void pnKeepSignalling(IRFunc* fn, IRValue* v, Map* defOf)
        {
        IRInsn* w = (IRInsn*)defOf.get((Hashable*)v);
        for (u32 b = 0; b < fn.blocks().count(); b = b + 1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            u32 at = bb.insns().count();
            for (u32 i = 0; i < bb.insns().count(); i = i + 1)
                if ((IRInsn*)bb.insns().get(i) == w)
                    {
                    at = i;
                    break;
                    }
            if (at == bb.insns().count())
                continue;
            IROperand* h = (IROperand*)w.ops().get(0);
            Array* fix = new Array();
            IRInsn* t = pnEmit(fix, defOf, w, "FpExt", "F32", (IRValue*)0);
            t.add(h);
            IRInsn* z = pnEmit(fix, defOf, w, "ZExt", "U32", (IRValue*)0);
            z.add(h);
            IRInsn* mag = pnEmit(fix, defOf, w, "And", "U32", (IRValue*)0);
            mag.add(IROperand.useVal(z.res()));
            mag.add(pnImm(32767));
            IRInsn* d = pnEmit(fix, defOf, w, "Sub", "U32", (IRValue*)0);
            d.add(IROperand.useVal(mag.res()));
            d.add(pnImm(31745));
            IRInsn* sig = pnEmit(fix, defOf, w, "ICmp", "Bool", (IRValue*)0);
            sig.setPred(String.withCString("ULT"));
            sig.add(IROperand.useVal(d.res()));
            sig.add(pnImm(511));
            IRInsn* bits = pnEmit(fix, defOf, w, "Bitcast", "U32", (IRValue*)0);
            bits.add(IROperand.useVal(t.res()));
            IRInsn* cl = pnEmit(fix, defOf, w, "And", "U32", (IRValue*)0);
            cl.add(IROperand.useVal(bits.res()));
            cl.add(pnImm(4290772991));
            IRInsn* sel = pnEmit(fix, defOf, w, "Select", "U32", (IRValue*)0);
            sel.add(IROperand.useVal(sig.res()));
            sel.add(IROperand.useVal(cl.res()));
            sel.add(IROperand.useVal(bits.res()));
            IRInsn* r = pnEmit(fix, defOf, w, "Bitcast", "F32", v);
            r.add(IROperand.useVal(sel.res()));
            bb.insns().replaceRange(at, 1, fix);
            return;
            }
        }
    }
