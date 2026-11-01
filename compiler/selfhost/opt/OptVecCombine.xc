// OptVecCombine.xc — the VecCombine pass, ported from src/xtc/ir/XTIROptVecCombine.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptSimplify>
#import <OptVectorizeParts>

    class Opt (VecCombine)
    {

    final void vecCombine(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (vcWanted(fn))
                self.vecCombineFn(fn);
            }
        }

    // The constant tables, LATE: after the last LICM, which would take each
    // table load out of the loop as invariant and hold all 64 of MD5's in
    // the 14 vector registers.
    final void vecPool(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (!self.vcWanted(fn))
                continue;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                if (_profile.bitSelect())
                    vcPool(m, fn, (IRBlock*)fn.blocks().get(b), b);
                else
                    vcPoolWide(m, fn, (IRBlock*)fn.blocks().get(b), b);
                }
            }
        }

    // x86 at 64 bytes: the same table, one 4-byte entry per constant, and each
    // splat reading its entry. A Load feeding a VSplat folds into one
    // vpbroadcastd from memory, against the constant's own mov and the mov,
    // movd and vpbroadcastd of a register splat (MD5's 64 round constants).
    final void vcPoolWide(IRModule* m, IRFunc* fn, IRBlock* bb, u32 bi)
        {
        if (bb.insns().count() <= (u32)VEC_SPLAT_BIG_BODY)
            return;
        Map* defIn = new Map();
        u32 cands = (u32)0;
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.res() != (IRValue*)0)
                defIn.set((Hashable*)n.res(), (Object*)n);
            if (vcPoolableWide(n, defIn) != (IRInsn*)0)
                cands = cands + (u32)1;
            }
        if (cands < (u32)2)
            return;
        String* nm = new String();
        nm.appendFormat("__xtv_kpool_%s_%u", fn.name().cString(), bi);
        if (symNamed(m, nm) != (IRSymbol*)0)
            return;
        IRValue* base = new IRValue(String.withCString("Ptr(U32, unbanked)"));
        IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
        ao.setRes(base);
        ao.add(IROperand.sym(nm));
        Array* bytes = new Array();
        Map* idxOf = new Map();
        String* symTy = (String*)0;
        Array* out = new Array();
        out.add((Object*)ao);
        IRValue* mem = (IRValue*)fn.params().get(fn.params().count() - (u32)1);
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            IRInsn* kc = vcPoolableWide(n, defIn);
            if (kc == (IRInsn*)0)
                {
                out.add((Object*)n);
                continue;
                }
            i64 v = ((IROperand*)kc.ops().get((u32)0)).imm() & (i64)$FFFFFFFF;
            String* key = new String();
            key.appendFormat("%lld", v);
            Object* have = idxOf.get((Hashable*)key);
            u32 idx = (u32)0;
            if (have != (Object*)0)
                idx = ((Number*)have).asU32();
            else
                {
                idx = idxOf.count();
                idxOf.set((Hashable*)key, (Object*)Number.with(idx));
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    bytes.add((Object*)Number.with((u32)((v >> (i64)((u32)8 * k)) & (i64)255))); // LE
                }
            if (symTy == (String*)0)
                symTy = n.res().ty();
            IRValue* ea = new IRValue(String.withCString("Ptr(U32, unbanked)"));
            IRInsn* en = IRInsn.with(String.withCString("ElementAddr"));
            en.copyDbg(n);
            en.setRes(ea);
            en.add(IROperand.useVal(base));
            en.add(IROperand.immI((i64)idx, String.withCString("I64")));
            out.add((Object*)en);
            IRValue* sv = new IRValue(kc.res().ty());
            IRInsn* ld = IRInsn.with(String.withCString("Load"));
            ld.copyDbg(n);
            ld.setRes(sv);
            ld.add(IROperand.useVal(ea));
            ld.add(IROperand.useVal(mem));
            ld.setMemRes(new IRValue(String.withCString("Mem")));
            out.add((Object*)ld);
            n.ops().set((u32)0, (Object*)IROperand.useVal(sv));
            out.add((Object*)n);
            }
        IRSymbol* sym = IRSymbol.dataGlobal(nm, symTy);
        sym.clearEscapes();
        sym.setNoAttrs();
        sym.setBytes(bytes);
        m.addSym(sym);
        bb.insns().removeAll();
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1)
            bb.insns().add(out.get(i));
        }

    // vcPoolable for a 64-byte vector of 32-bit integer lanes.
    final IRInsn* vcPoolableWide(IRInsn* n, Map* defIn)
        {
        if (!n.op().equals(String.withCString("VSplat")) || n.ops().count() != (u32)1 || n.res() == (IRValue*)0)
            return (IRInsn*)0;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (IRInsn*)0;
        IRInsn* d = (IRInsn*)defIn.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Const")) || d.ops().count() < (u32)1
            || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_IMMI)
            return (IRInsn*)0;
        String* t = n.res().ty();
        if (!(t.equals(String.withCString("Vec(I32, 64)")) || t.equals(String.withCString("Vec(U32, 64)"))))
            return (IRInsn*)0;
        if (d.res() == (IRValue*)0 || fieldWidth4(d.res().ty()) != (u32)4)
            return (IRInsn*)0;
        return d;
        }

    static u32 fieldWidth4(String* t)
        {
        if (t != (String*)0 && (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))))
            return (u32)4;
        return (u32)0;
        }

    final void vcPool(IRModule* m, IRFunc* fn, IRBlock* bb, u32 bi)
        {
        if (bb.insns().count() <= (u32)VEC_SPLAT_BIG_BODY)
            return;
        Map* defIn = new Map();
        u32 cands = (u32)0;
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.res() != (IRValue*)0)
                defIn.set((Hashable*)n.res(), (Object*)n);
            if (vcPoolable(n, defIn) != (IRInsn*)0)
                cands = cands + (u32)1;
            }
        if (cands < (u32)2)
            return;
        String* nm = new String();
        nm.appendFormat("__xtv_kpool_%s_%u", fn.name().cString(), bi);
        if (symNamed(m, nm) != (IRSymbol*)0)
            return;
        IRValue* base = new IRValue(String.withCString("Ptr(U8, unbanked)"));
        IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
        ao.setRes(base);
        ao.add(IROperand.sym(nm));
        Array* bytes = new Array();
        Map* idxOf = new Map();
        String* symTy = (String*)0;
        Array* out = new Array();
        out.add((Object*)ao);
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            IRInsn* kc = vcPoolable(n, defIn);
            if (kc == (IRInsn*)0)
                {
                out.add((Object*)n);
                continue;
                }
            String* lane = laneOfVec(n.res().ty());
            u32 w = self.irWidth(lane);
            i64 v = ((IROperand*)kc.ops().get((u32)0)).imm();
            if (w < (u32)8)
                v = v & (((i64)1 << (i64)(w * (u32)8)) - (i64)1);
            String* key = new String();
            key.appendFormat("%u:%lld", w, v);
            Object* have = idxOf.get((Hashable*)key);
            u32 idx = (u32)0;
            if (have != (Object*)0)
                idx = ((Number*)have).asU32();
            else
                {
                idx = idxOf.count();
                idxOf.set((Hashable*)key, (Object*)Number.with(idx));
                for (u32 l = (u32)0; l < (u32)16 / w; l = l + (u32)1)
                    for (u32 k = (u32)0; k < w; k = k + (u32)1)
                        bytes.add((Object*)Number.with((u32)((v >> (i64)((u32)8 * k)) & (i64)255))); // LE
                }
            if (symTy == (String*)0)
                symTy = n.res().ty();
            IRValue* ea = new IRValue(String.withCString("Ptr(U8, unbanked)"));
            IRInsn* en = IRInsn.with(String.withCString("ElementAddr"));
            en.copyDbg(n);
            en.setRes(ea);
            en.add(IROperand.useVal(base));
            en.add(IROperand.immI((i64)idx * (i64)16, String.withCString("I64")));
            out.add((Object*)en);
            IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
            vl.copyDbg(n);
            vl.setRes(n.res());
            vl.add(IROperand.useVal(ea));
            out.add((Object*)vl);
            }
        IRSymbol* sym = IRSymbol.dataGlobal(nm, symTy);
        // Read-only, compiler-made, never address-taken beyond these loads.
        // The type is the 16-byte vector; the payload is the whole table, and
        // the back ends emit every byte of it.
        sym.clearEscapes();
        sym.setNoAttrs();
        sym.setBytes(bytes);
        m.addSym(sym);
        bb.insns().removeAll();
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1)
            bb.insns().add(out.get(i));
        }

    // The lane of a 16-byte vector type `Vec(L)`; null for any other.
    final String* laneOfVec(String* t)
        {
        if (t == (String*)0 || !t.hasPrefix(String.withCString("Vec(")) || !t.hasSuffix(String.withCString(")")))
            return (String*)0;
        String* inner = t.substringFromByte((u32)4);
        String* lane = inner.substringToByte(inner.byteLength() - (u32)1);
        for (u32 i = (u32)0; i < lane.byteLength(); i = i + (u32)1)
            if (lane.byteAt(i) == (u8)',' || lane.byteAt(i) == (u8)'(')
                return (String*)0;
        return lane;
        }

    // The Const a VSplat broadcasts, when it can come from the table: an
    // integer constant defined in this block, into a 16-byte integer vector.
    final IRInsn* vcPoolable(IRInsn* n, Map* defIn)
        {
        if (!n.op().equals(String.withCString("VSplat")) || n.ops().count() != (u32)1 || n.res() == (IRValue*)0)
            return (IRInsn*)0;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (IRInsn*)0;
        IRInsn* d = (IRInsn*)defIn.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Const")) || d.ops().count() < (u32)1
            || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_IMMI)
            return (IRInsn*)0;
        String* lane = laneOfVec(n.res().ty());
        if (lane == (String*)0 || !self.simpIntTy(lane) || !self.vecTyOf(lane, (u32)16).equals(n.res().ty()))
            return (IRInsn*)0;
        return d;
        }
    }
