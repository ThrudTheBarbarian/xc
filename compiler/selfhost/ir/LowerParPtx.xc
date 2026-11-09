// LowerParPtx.xc — a `par` kernel as PTX, for NVIDIA GPUs.
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

    class Lower (ParPtx)
    {
    final bool ptxNarrow(String* t) { return ptxIs(t, "I8") || ptxIs(t, "U8") || ptxIs(t, "I16") || ptxIs(t, "U16"); }
    final bool ptxSigned(String* t) { return ptxIs(t, "I8") || ptxIs(t, "I16") || ptxIs(t, "I32") || ptxIs(t, "I64"); }
    final bool ptxWide(String* t) { return ptxIs(t, "I64") || ptxIs(t, "U64") || mslIsPtr(t); }
    final bool ptxFloat(String* t) { return ptxIs(t, "F32") || ptxIs(t, "F64"); }
    final String* ptxRegType(String* t)
        {
        if (t == (String*)0) return (String*)0;
        if (ptxNarrow(t) || self.ptxIs(t, "I32") || self.ptxIs(t, "U32")) return self.ptxS(".b32");
        if (ptxWide(t)) return self.ptxS(".b64");
        if (ptxIs(t, "F32")) return self.ptxS(".f32");
        if (ptxIs(t, "F64")) return self.ptxS(".f64");
        if (ptxIs(t, "Bool")) return self.ptxS(".pred");
        return (String*)0;
        }
    final String* ptxArith(String* t)
        {
        if (ptxIs(t, "I32")) return self.ptxS("s32");
        if (ptxIs(t, "U32")) return self.ptxS("u32");
        if (ptxIs(t, "I64")) return self.ptxS("s64");
        if (ptxIs(t, "U64") || self.mslIsPtr(t)) return self.ptxS("u64");
        if (ptxIs(t, "F32")) return self.ptxS("f32");
        if (ptxIs(t, "F64")) return self.ptxS("f64");
        return (String*)0;
        }
    final String* ptxMem(String* t)
        {
        if (ptxIs(t, "I8")) return self.ptxS("s8");
        if (ptxIs(t, "U8") || self.ptxIs(t, "Bool")) return self.ptxS("u8");
        if (ptxIs(t, "I16")) return self.ptxS("s16");
        if (ptxIs(t, "U16")) return self.ptxS("u16");
        if (ptxIs(t, "I32") || self.ptxIs(t, "U32")) return self.ptxS("u32");
        if (ptxIs(t, "I64") || self.ptxIs(t, "U64") || self.mslIsPtr(t)) return self.ptxS("u64");
        if (ptxIs(t, "F32")) return self.ptxS("f32");
        if (ptxIs(t, "F64")) return self.ptxS("f64");
        return (String*)0;
        }
    // A type's size in bytes (an aggregate's is its layout's).
    final u32 ptxSize(String* t)
        {
        IRLayout* l = self.mslLayoutOf(t);
        if (l != (IRLayout*)0) return l.size();
        if (mslIsPtr(t)) return (u32)8;
        return self.mslWidth(t);
        }
    final String* ptxReg(IRValue* v)
        {
        if (_mHelper && _mParams != (Map*)0)
            {
            String* pk = (String*)_mParams.get((Hashable*)self.mslKey(v));
            if (pk != (String*)0)
                {
                String* ps = self.ptxS("%a");
                ps.append(pk);
                return ps;
                }
            }
        String* s = self.ptxS("%v");
        String* o = (String*)_mOrd.get((Hashable*)self.mslKey(v));
        s.append(o != (String*)0 ? o : self.ptxS("0"));
        return s;
        }
    final String* ptxOrdOf(IRValue* v)
        {
        String* o = (String*)_mOrd.get((Hashable*)self.mslKey(v));
        return o != (String*)0 ? o : self.ptxS("0");
        }
    final String* ptxHex(u64 v, i32 digits)
        {
        String* s = self.ptxS("");
        for (i32 sh = (digits - (i32)1) * (i32)4; sh >= (i32)0; sh = sh - (i32)4)
            {
            u64 d = (v >> (u64)sh) & (u64)15;
            s.appendByte(d < (u64)10 ? (u8)((u64)'0' + d) : (u8)((u64)'A' + d - (u64)10));
            }
        return s;
        }
    // A constant of type t in its register form: a narrow one extended by
    // its own signedness.
    final i64 ptxNarrowValue(String* t, i64 v)
        {
        if (ptxIs(t, "I8")) return (i64)(i8)v;
        if (ptxIs(t, "U8")) return (i64)(u8)v;
        if (ptxIs(t, "I16")) return (i64)(i16)v;
        if (ptxIs(t, "U16")) return (i64)(u16)v;
        return v;
        }
    // The line that puts a narrow result in r back in its register form.
    final String* ptxNarrowFix(String* t, String* r)
        {
        if (ptxIs(t, "U8")) return ptx3(ptxS("and.b32"), r, r, self.ptxS("255"));
        if (ptxIs(t, "U16")) return ptx3(ptxS("and.b32"), r, r, self.ptxS("65535"));
        if (ptxIs(t, "I8")) return ptxBfe(r, "8");
        if (ptxIs(t, "I16")) return ptxBfe(r, "16");
        return self.ptxS("");
        }

    // An operand as a register or an immediate in t's PTX spelling.
    final String* ptxOp(IROperand* op, String* t)
        {
        if (op.kind() == (u8)OPK_USE)
            return ptxReg(op.val());
        if (op.kind() == (u8)OPK_IMMI)
            {
            return String.withI64(ptxNarrowValue(t, op.imm()));
            }
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
            if (ptxIs(t, "F64"))
                {
                String* s = self.ptxS("0d");
                s.append(ptxHex(raw, (i32)16));
                return s;
                }
            double dv = *(double*)(pointer)&raw;
            float fv = (float)dv;
            u32 bits = *(u32*)(pointer)&fv;
            String* s = self.ptxS("0f");
            s.append(ptxHex((u64)bits, (i32)8));
            return s;
            }
        return (String*)0;
        }
    // Joins: a list of pieces into one string.
    final String* ptxJoin(Array* parts)
        {
        String* s = self.ptxS("");
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            s.append((String*)parts.get(i));
        return s;
        }
    final Array* ptxL(void) { return new Array(); }
    final void ptxA(Array* a, String* s) { a.add((Object*)s); }
    final void ptxC(Array* a, string s) { a.add((Object*)String.withCString(s)); }

    // Declare every value's register (and a copy register per phi).
    final String* ptxDecls(IRFunc* f)
        {
        String* d = self.ptxS("");
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                if (ip.res() == (IRValue*)0 || ip.res().ty().equals(self.ptxS("Mem"))) continue;
                String* rt = ptxRegType(ip.res().ty());
                if (rt == (String*)0) return (String*)0;
                String* o = ptxOrdOf(ip.res());
                d.appendCString("\t.reg "); d.append(rt); d.appendCString(" %v"); d.append(o); d.appendCString(", %c"); d.append(o); d.appendCString(";\n");
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() == (IRValue*)0 || ip.res().ty().equals(self.ptxS("Mem"))) continue;
                String* rt = ptxRegType(ip.res().ty());
                if (rt == (String*)0) return (String*)0;
                d.appendCString("\t.reg "); d.append(rt); d.appendCString(" "); d.append(ptxReg(ip.res())); d.appendCString(";\n");
                }
            }
        return d;
        }

    // The moves for the edge from -> target, through the copy registers.
    final String* ptxCopies(IRBlock* from, IRBlock* target)
        {
        String* a = self.ptxS("");
        String* b = self.ptxS("");
        for (u32 i = (u32)0; i < target.phis().count(); i = i + (u32)1)
            {
            IRInsn* ph = (IRInsn*)target.phis().get(i);
            if (ph.res() == (IRValue*)0 || ph.res().ty().equals(self.ptxS("Mem"))) continue;
            IROperand* inc = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < ph.ops().count(); k = k + (u32)2)
                if (((IROperand*)ph.ops().get(k)).blk() == from)
                    inc = (IROperand*)ph.ops().get(k + (u32)1);
            String* src = inc != (IROperand*)0 ? ptxOp(inc, ph.res().ty()) : (String*)0;
            String* rt = ptxRegType(ph.res().ty());
            if (src == (String*)0 || rt == (String*)0) return (String*)0;
            String* o = ptxOrdOf(ph.res());
            a.appendCString("\tmov"); a.append(rt); a.appendCString(" %c"); a.append(o); a.appendCString(", "); a.append(src); a.appendCString(";\n");
            b.appendCString("\tmov"); b.append(rt); b.appendCString(" %v"); b.append(o); b.appendCString(", %c"); b.append(o); b.appendCString(";\n");
            }
        a.append(b);
        return a;
        }

    final String* ptxSpaceOf(IROperand* addr)
        {
        String* sp = self.mslSpaceOfOp(addr);
        return sp != (String*)0 && (sp.equals(self.ptxS("device")) || sp.equals(self.ptxS("constant"))) ? self.ptxS("global") : self.ptxS("local");
        }

    // "\t<op> <r>, <a>, <b>;\n"
    final String* ptx3(String* op, String* r, String* a, String* b)
        {
        Array* l = ptxL();
        ptxC(l, "\t"); ptxA(l, op); ptxC(l, " "); ptxA(l, r); ptxC(l, ", "); ptxA(l, a); ptxC(l, ", "); ptxA(l, b); ptxC(l, ";\n");
        return ptxJoin(l);
        }
    final String* ptx2(String* op, String* r, String* a)
        {
        Array* l = ptxL();
        ptxC(l, "\t"); ptxA(l, op); ptxC(l, " "); ptxA(l, r); ptxC(l, ", "); ptxA(l, a); ptxC(l, ";\n");
        return ptxJoin(l);
        }
    final String* ptxCat(string a, String* b)
        {
        String* s = self.ptxS(a);
        s.append(b);
        return s;
        }

    final String* ptxBinary(IRInsn* ip, String* r, String* rt)
        {
        // Logic on predicates (the reference explains).
        if (ptxIs(rt, "Bool") && (ip.op().equals(self.ptxS("And")) || ip.op().equals(self.ptxS("Or")) || ip.op().equals(self.ptxS("Xor")))
            && ((IROperand*)ip.ops().get((u32)0)).kind() == (u8)OPK_USE && ((IROperand*)ip.ops().get((u32)1)).kind() == (u8)OPK_USE)
            {
            String* pa = ptxOp((IROperand*)ip.ops().get((u32)0), rt);
            String* pb = ptxOp((IROperand*)ip.ops().get((u32)1), rt);
            if (pa == (String*)0 || pb == (String*)0) return (String*)0;
            String* pl = self.ptxS("\t");
            pl.appendCString(ip.op().equals(self.ptxS("And")) ? "and" : ip.op().equals(self.ptxS("Or")) ? "or" : "xor");
            pl.appendCString(".pred "); pl.append(r); pl.appendCString(", "); pl.append(pa); pl.appendCString(", ");
            pl.append(pb); pl.appendCString(";\n");
            return pl;
            }
        if (ptxNarrow(rt))
            {
            // An 8- or 16-bit value sits in its 32-bit register extended by
            // its own signedness: the operation in 32 bits, and its result
            // put back in that form. A division, remainder or right shift
            // whose signedness is not the type's stays refused.
            String* nop = ip.op();
            bool sg = ptxSigned(rt);
            bool uop = nop.equals(self.ptxS("UDiv")) || nop.equals(self.ptxS("URem")) || nop.equals(self.ptxS("LShr"));
            bool sop = nop.equals(self.ptxS("SDiv")) || nop.equals(self.ptxS("SRem")) || nop.equals(self.ptxS("AShr"));
            if ((uop && sg) || (sop && !sg)) return (String*)0;
            IROperand* nb = (IROperand*)ip.ops().get((u32)1);
            if (nb.kind() == (u8)OPK_USE && ptxWide(mslTypeOf(nb))) return (String*)0;
            String* na = ptxOp((IROperand*)ip.ops().get((u32)0), rt);
            String* nbs = ptxOp(nb, rt);
            if (na == (String*)0 || nbs == (String*)0) return (String*)0;
            String* n32 = self.ptxS(sg ? "s32" : "u32");
            String* nl = (String*)0;
            if (nop.equals(self.ptxS("Add"))) nl = ptxCat("add.", n32);
            else if (nop.equals(self.ptxS("Sub"))) nl = ptxCat("sub.", n32);
            else if (nop.equals(self.ptxS("Mul"))) nl = ptxCat("mul.lo.", n32);
            else if (nop.equals(self.ptxS("UDiv")) || nop.equals(self.ptxS("SDiv"))) nl = ptxCat("div.", n32);
            else if (nop.equals(self.ptxS("URem")) || nop.equals(self.ptxS("SRem"))) nl = ptxCat("rem.", n32);
            else if (nop.equals(self.ptxS("And"))) nl = self.ptxS("and.b32");
            else if (nop.equals(self.ptxS("Or"))) nl = self.ptxS("or.b32");
            else if (nop.equals(self.ptxS("Xor"))) nl = self.ptxS("xor.b32");
            else if (nop.equals(self.ptxS("Shl"))) nl = self.ptxS("shl.b32");
            else if (nop.equals(self.ptxS("LShr")) || nop.equals(self.ptxS("AShr"))) nl = ptxCat("shr.", n32);
            if (nl == (String*)0) return (String*)0;
            String* ns = ptx3(nl, r, na, nbs);
            ns.append(ptxNarrowFix(rt, r));
            return ns;
            }
        if (self.ptxIs(rt, "Bool")) return (String*)0; // no bool arithmetic
        String* a = ptxOp((IROperand*)ip.ops().get((u32)0), rt);
        String* b = ptxOp((IROperand*)ip.ops().get((u32)1), rt);
        String* sfx = ptxArith(rt);
        if (a == (String*)0 || b == (String*)0 || sfx == (String*)0) return (String*)0;
        bool w = ptxWide(rt);
        String* bits = self.ptxS(w ? "b64" : "b32");
        String* us = self.ptxS(w ? "u64" : "u32");
        String* ss = self.ptxS(w ? "s64" : "s32");
        String* op = ip.op();
        String* line = (String*)0;
        if (op.equals(self.ptxS("Add"))) line = ptxCat("add.", sfx);
        else if (op.equals(self.ptxS("Sub"))) line = ptxCat("sub.", sfx);
        else if (op.equals(self.ptxS("Mul"))) line = ptxCat("mul.lo.", sfx);
        else if (op.equals(self.ptxS("UDiv"))) line = ptxCat("div.", us);
        else if (op.equals(self.ptxS("SDiv"))) line = ptxCat("div.", ss);
        else if (op.equals(self.ptxS("URem"))) line = ptxCat("rem.", us);
        else if (op.equals(self.ptxS("SRem"))) line = ptxCat("rem.", ss);
        else if (op.equals(self.ptxS("And"))) line = ptxCat("and.", bits);
        else if (op.equals(self.ptxS("Or"))) line = ptxCat("or.", bits);
        else if (op.equals(self.ptxS("Xor"))) line = ptxCat("xor.", bits);
        // Bug 643: `.rn` pins every float op to its exact result, so ptxas may
        // not contract a mul and an add into an FMA and a divide takes the
        // correctly rounded sequence. A block whose goal is speed drops the
        // modifier (plain add/mul contract) and divides approximately; f64
        // keeps .rn, PTX has no approximate f64 divide. :goal(accuracy) is
        // unchanged.
        else if (op.equals(self.ptxS("FAdd"))) line = _mFast ? ptxCat("add.", sfx) : ptxCat("add.rn.", sfx);
        else if (op.equals(self.ptxS("FSub"))) line = _mFast ? ptxCat("sub.", sfx) : ptxCat("sub.rn.", sfx);
        else if (op.equals(self.ptxS("FMul"))) line = _mFast ? ptxCat("mul.", sfx) : ptxCat("mul.rn.", sfx);
        else if (op.equals(self.ptxS("FDiv"))) line = (_mFast && self.ptxIs(rt, "F32")) ? self.ptxS("div.approx.ftz.f32") : ptxCat("div.rn.", sfx);
        else if (op.equals(self.ptxS("Shl")) || op.equals(self.ptxS("LShr")) || op.equals(self.ptxS("AShr")))
            {
            // The shift count is a u32 operand.
            String* sop = op.equals(self.ptxS("Shl")) ? ptxCat("shl.", bits) : op.equals(self.ptxS("LShr")) ? ptxCat("shr.", us) : ptxCat("shr.", ss);
            // A 64-bit count is narrowed first; a 32-bit one is already the operand.
            if (w && ((IROperand*)ip.ops().get((u32)1)).kind() == (u8)OPK_USE && ptxWide(mslTypeOf((IROperand*)ip.ops().get((u32)1))))
                {
                String* s = ptx2(ptxS("cvt.u32.u64"), self.ptxS("%k"), b);
                s.append(ptx3(sop, r, a, self.ptxS("%k")));
                return s;
                }
            return ptx3(sop, r, a, b);
            }
        if (line == (String*)0) return (String*)0;
        return ptx3(line, r, a, b);
        }

    final String* ptxCompare(IRInsn* ip, String* r)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
        String* t = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : self.mslTypeOf(o1);
        // Two predicates are equal when their exclusive or is false; one
        // against a constant is itself or its negation.
        if (t != (String*)0 && self.ptxIs(t, "Bool") && ip.op().equals(self.ptxS("ICmp"))
            && (ip.pred().equals(self.ptxS("EQ")) || ip.pred().equals(self.ptxS("NE"))))
            {
            bool eq = ip.pred().equals(self.ptxS("EQ"));
            if (o0.kind() == (u8)OPK_USE && o1.kind() == (u8)OPK_USE)
                {
                String* x = ptx3(ptxS("xor.pred"), r, ptxReg(o0.val()), ptxReg(o1.val()));
                if (eq) x.append(ptx2(ptxS("not.pred"), r, r));
                return x;
                }
            IROperand* pv = o0.kind() == (u8)OPK_USE ? o0 : o1;
            IROperand* pk = o0.kind() == (u8)OPK_USE ? o1 : o0;
            if (pv.kind() != (u8)OPK_USE || pk.kind() != (u8)OPK_IMMI) return (String*)0;
            return ptx2(ptxS((pk.imm() != (i64)0) == eq ? "mov.pred" : "not.pred"), r, ptxReg(pv.val()));
            }
        // An 8- or 16-bit value sits in its 32-bit register extended by its
        // own signedness, so it compares as a 32-bit one.
        if (t == (String*)0 || self.ptxIs(t, "Bool")) return (String*)0;
        String* a = ptxOp(o0, t);
        String* b = ptxOp(o1, t);
        if (a == (String*)0 || b == (String*)0) return (String*)0;
        String* p = ip.pred();
        String* cmp = (String*)0;
        String* ty = (String*)0;
        if (ip.op().equals(self.ptxS("FCmp")))
            {
            if (p.equals(self.ptxS("OEQ"))) cmp = self.ptxS("eq");
            else if (p.equals(self.ptxS("ONE"))) cmp = self.ptxS("ne");
            else if (p.equals(self.ptxS("OLT"))) cmp = self.ptxS("lt");
            else if (p.equals(self.ptxS("OGT"))) cmp = self.ptxS("gt");
            else if (p.equals(self.ptxS("OLE"))) cmp = self.ptxS("le");
            else if (p.equals(self.ptxS("OGE"))) cmp = self.ptxS("ge");
            ty = ptxArith(t);
            }
        else
            {
            bool sg = false;
            if (p.equals(self.ptxS("EQ"))) cmp = self.ptxS("eq");
            else if (p.equals(self.ptxS("NE"))) cmp = self.ptxS("ne");
            else if (p.equals(self.ptxS("SLT"))) { cmp = self.ptxS("lt"); sg = true; }
            else if (p.equals(self.ptxS("SGT"))) { cmp = self.ptxS("gt"); sg = true; }
            else if (p.equals(self.ptxS("SLE"))) { cmp = self.ptxS("le"); sg = true; }
            else if (p.equals(self.ptxS("SGE"))) { cmp = self.ptxS("ge"); sg = true; }
            else if (p.equals(self.ptxS("ULT"))) cmp = self.ptxS("lt");
            else if (p.equals(self.ptxS("UGT"))) cmp = self.ptxS("gt");
            else if (p.equals(self.ptxS("ULE"))) cmp = self.ptxS("le");
            else if (p.equals(self.ptxS("UGE"))) cmp = self.ptxS("ge");
            ty = ptxWide(t) ? self.ptxS(sg ? "s64" : "u64") : self.ptxS(sg ? "s32" : "u32");
            }
        if (cmp == (String*)0 || ty == (String*)0) return (String*)0;
        String* op = self.ptxS("setp.");
        op.append(cmp); op.appendCString("."); op.append(ty);
        return ptx3(op, r, a, b);
        }

    final String* ptxCall(IRInsn* ip, String* r, String* rt)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* callee = o0.name();
        if (callee.equals(self.ptxS("_xtc_sinit_run")) || callee.hasSuffix(self.ptxS("$init")))
            return self.ptxS("");
        bool isVoid = rt == (String*)0 || rt.equals(self.ptxS("Mem"));
        Array* args = new Array();
        Array* argTypes = new Array();
        for (u32 k = (u32)1; k < ip.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)ip.ops().get(k);
            String* at = o.kind() == (u8)OPK_USE ? self.mslTypeOf(o) : rt;
            if (ptxIs(at, "Mem")) continue;
            String* e = ptxOp(o, at);
            if (e == (String*)0) return (String*)0;
            args.add((Object*)e);
            argTypes.add((Object*)at);
            }
        // The precise maths PTX has as instructions.
        String* m = self.ptxMathName(callee);
        bool fl = ptxFloat(rt);
        u32 n = args.count();
        if (!isVoid && fl && m.equals(self.ptxS("sqrt")) && n == (u32)1)
            {
            if (_mFast && self.ptxIs(rt, "F32")) // bug 643
                return ptx2(ptxS("sqrt.approx.ftz.f32"), r, (String*)args.get((u32)0));
            return ptx2(ptxCat("sqrt.rn.", ptxArith(rt)), r, (String*)args.get((u32)0));
            }
        if (!isVoid && fl && m.equals(self.ptxS("fma")) && n == (u32)3)
            {
            String* s = ptx3(ptxCat("fma.rn.", ptxArith(rt)), r, (String*)args.get((u32)0), (String*)args.get((u32)1));
            // ptx3 ends "b;\n": put the third operand in.
            String* t = s.substringBytes((u32)0, s.byteLength() - (u32)2);
            t.appendCString(", "); t.append((String*)args.get((u32)2)); t.appendCString(";\n");
            return t;
            }
        if (!isVoid && fl && m.equals(self.ptxS("floor")) && n == (u32)1)
            {
            String* op = ptxCat("cvt.rmi.", ptxArith(rt));
            op.appendCString("."); op.append(ptxArith(rt));
            return ptx2(op, r, (String*)args.get((u32)0));
            }
        if (!isVoid && (m.equals(self.ptxS("abs")) || m.equals(self.ptxS("fabs"))) && n == (u32)1 && ptxArith(rt) != (String*)0)
            return ptx2(ptxCat("abs.", fl ? ptxArith(rt) : self.ptxS(ptxWide(rt) ? "s64" : "s32")), r, (String*)args.get((u32)0));
        if (!isVoid && (m.equals(self.ptxS("min")) || m.equals(self.ptxS("max"))) && n == (u32)2 && ptxArith(rt) != (String*)0)
            {
            String* op = String.withString(m);
            op.appendCString("."); op.append(ptxArith(rt));
            return ptx3(op, r, (String*)args.get((u32)0), (String*)args.get((u32)1));
            }
        if (m.equals(self.ptxS("sin")) || m.equals(self.ptxS("cos")) || m.equals(self.ptxS("exp")) || m.equals(self.ptxS("ln")) || m.equals(self.ptxS("log")) || m.equals(self.ptxS("pow")))
            {
            // No precise PTX instruction: the CPU runs this block, unless its
            // goal is speed and it is single precision, where the GPU's own
            // approximations will do (exp through ex2, ln through lg2).
            if (!_mFast || isVoid || !self.ptxIs(rt, "F32")) return (String*)0;
            if ((m.equals(self.ptxS("sin")) || m.equals(self.ptxS("cos"))) && n == (u32)1)
                {
                String* op = String.withString(m);
                op.appendCString(".approx.f32");
                return ptx2(op, r, (String*)args.get((u32)0));
                }
            if (m.equals(self.ptxS("exp")) && n == (u32)1)
                {
                String* s = ptx3(ptxS("mul.f32"), self.ptxS("%fk"), (String*)args.get((u32)0), self.ptxS("0f3FB8AA3B"));
                s.append(ptx2(ptxS("ex2.approx.f32"), r, self.ptxS("%fk")));
                return s;
                }
            if ((m.equals(self.ptxS("ln")) || m.equals(self.ptxS("log"))) && n == (u32)1)
                {
                String* s = ptx2(ptxS("lg2.approx.f32"), self.ptxS("%fk"), (String*)args.get((u32)0));
                s.append(ptx3(ptxS("mul.f32"), r, self.ptxS("%fk"), self.ptxS("0f3F317218")));
                return s;
                }
            if (m.equals(self.ptxS("pow")) && n == (u32)2)
                {
                String* s = ptx2(ptxS("lg2.approx.f32"), self.ptxS("%fk"), (String*)args.get((u32)0));
                s.append(ptx3(ptxS("mul.f32"), self.ptxS("%fk"), self.ptxS("%fk"), (String*)args.get((u32)1)));
                s.append(ptx2(ptxS("ex2.approx.f32"), r, self.ptxS("%fk")));
                return s;
                }
            return (String*)0;
            }
        // A function of the program: printed once, before the kernel.
        IRFunc* target = (IRFunc*)0;
        for (u32 q = (u32)0; q < _m.funcs().count(); q = q + (u32)1)
            if (((IRFunc*)_m.funcs().get(q)).name().equals(callee))
                target = (IRFunc*)_m.funcs().get(q);
        if (target == (IRFunc*)0) return (String*)0;
        String* fn = self.ptxS("h_");
        for (u32 q = (u32)0; q < callee.byteLength(); q = q + (u32)1)
            fn.appendByte(callee.byteAt(q) == (u8)'$' ? (u8)'_' : callee.byteAt(q));
        if (_mHelperNames.get((Hashable*)callee) == (Object*)0)
            {
            _mHelperNames.set((Hashable*)callee, (Object*)callee);
            String* text = ptxHelper(target, fn);
            if (text == (String*)0) { self.parBecause(parCallFailed(callee, _mHelperWhy)); return (String*)0; }
            _mHelperBodies.set((Hashable*)callee, (Object*)text);
            // Called while it was being printed: recursive, keeps a real .func.
            if (_mHelperCalled.get((Hashable*)callee) != (Object*)0)
                _mHelperText.add((Object*)text);
            }
        // Inlined (the reference explains; bug 645).
        String* hbody = (String*)_mHelperBodies.get((Hashable*)callee);
        if (hbody != (String*)0)
            {
            u32 serial = _mInlineSerial;
            _mInlineSerial = _mInlineSerial + (u32)1;
            return Lower.ptxInline(hbody, serial, args, isVoid ? (String*)0 : r);
            }
        _mHelperCalled.set((Hashable*)callee, (Object*)callee);
        String* s = self.ptxS("\t{\n");
        String* pnames = self.ptxS("");
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
            {
            String* pt = ptxRegType((String*)argTypes.get(k));
            if (pt == (String*)0 || pt.equals(self.ptxS(".pred"))) return (String*)0;
            String* q = self.ptxS("q");
            q.append(String.withU32(k));
            s.appendCString("\t.param "); s.append(pt); s.appendCString(" "); s.append(q); s.appendCString(";\n");
            s.appendCString("\tst.param"); s.append(pt); s.appendCString(" ["); s.append(q); s.appendCString("], ");
            s.append((String*)args.get(k)); s.appendCString(";\n");
            if (k > (u32)0) pnames.appendCString(", ");
            pnames.append(q);
            }
        if (isVoid)
            {
            s.appendCString("\tcall.uni "); s.append(fn); s.appendCString(", ("); s.append(pnames); s.appendCString(");\n");
            }
        else
            {
            String* pt = ptxRegType(rt);
            if (pt == (String*)0 || pt.equals(self.ptxS(".pred"))) return (String*)0;
            s.appendCString("\t.param "); s.append(pt); s.appendCString(" rq;\n\tcall.uni (rq), "); s.append(fn);
            s.appendCString(", ("); s.append(pnames); s.appendCString(");\n\tld.param"); s.append(pt); s.appendCString(" ");
            s.append(r); s.appendCString(", [rq];\n");
            }
        s.appendCString("\t}\n");
        return s;
        }

    // "\tbfe.s32 r, r, 0, bits;\n": the low bits of r, sign-extended.
    final String* ptxBfe(String* r, string bits)
        {
        String* s = self.ptxS("\tbfe.s32 ");
        s.append(r); s.appendCString(", "); s.append(r); s.appendCString(", 0, "); s.appendCString(bits); s.appendCString(";\n");
        return s;
        }

    final String* ptxConvert(IRInsn* ip, String* r, String* rt)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* op = ip.op();
        String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
        String* a = ptxOp(o0, st);
        if (a == (String*)0 || st == (String*)0) return (String*)0;
        if (ptxIs(st, "Bool"))
            {
            if (ptxIs(rt, "Bool")) return ptx2(ptxS("mov.pred"), r, a);
            String* s = self.ptxS("\tselp.");
            s.appendCString(ptxWide(rt) ? "b64 " : "b32 "); s.append(r); s.appendCString(", 1, 0, "); s.append(a); s.appendCString(";\n");
            return s;
            }
        if (ptxIs(rt, "Bool"))
            {
            String* s = self.ptxS("\tsetp.ne.");
            s.appendCString(ptxWide(st) ? "u64 " : "u32 "); s.append(r); s.appendCString(", "); s.append(a); s.appendCString(", 0;\n");
            return s;
            }
        bool sw = ptxWide(st);
        bool rw = ptxWide(rt);
        if (op.equals(self.ptxS("Trunc")))
            {
            String* lo = sw ? ptx2(ptxS("cvt.u32.u64"), r, a) : ptx2(ptxS("mov.b32"), r, a);
            if (rw) return ptx2(ptxS("mov.b64"), r, a);
            if (ptxIs(rt, "U8")) { lo.append(ptx3(ptxS("and.b32"), r, r, self.ptxS("255"))); return lo; }
            if (ptxIs(rt, "U16")) { lo.append(ptx3(ptxS("and.b32"), r, r, self.ptxS("65535"))); return lo; }
            if (ptxIs(rt, "I8")) { lo.append(ptxBfe(r, "8")); return lo; }
            if (ptxIs(rt, "I16")) { lo.append(ptxBfe(r, "16")); return lo; }
            return lo;
            }
        if (op.equals(self.ptxS("SExt")) && ptxNarrow(st))
            {
            String* bits = self.ptxS((self.ptxIs(st, "I8") || self.ptxIs(st, "U8")) ? "8" : "16");
            String* x = self.ptxS("\tbfe.s32 %k, ");
            x.append(a); x.appendCString(", 0, "); x.append(bits); x.appendCString(";\n");
            if (rw) x.append(ptx2(ptxS("cvt.s64.s32"), r, self.ptxS("%k")));
            else x.append(ptx2(ptxS("mov.b32"), r, self.ptxS("%k")));
            return x;
            }
        if (op.equals(self.ptxS("ZExt")) && (self.ptxIs(st, "I8") || self.ptxIs(st, "I16")))
            {
            // A signed narrow value is sign-extended in its register:
            // zero-extending it clears those bits first.
            String* x = ptx3(ptxS("and.b32"), self.ptxS("%k"), a, self.ptxS(ptxIs(st, "I8") ? "255" : "65535"));
            if (rw) x.append(ptx2(ptxS("cvt.u64.u32"), r, self.ptxS("%k")));
            else x.append(ptx2(ptxS("mov.b32"), r, self.ptxS("%k")));
            return x;
            }
        if (!sw && rw)
            return ptx2(ptxS(op.equals(self.ptxS("SExt")) ? "cvt.s64.s32" : "cvt.u64.u32"), r, a);
        return ptx2(ptxS(rw ? "mov.b64" : "mov.b32"), r, a);
        }

    final String* ptxFpConvert(IRInsn* ip, String* r, String* rt)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* op = ip.op();
        String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
        String* a = ptxOp(o0, st);
        if (a == (String*)0) return (String*)0;
        // A narrow integer sits in its 32-bit register extended by its own
        // signedness (as ZExt/SExt above rely on), so an int-to-float
        // conversion reads it in the 32-bit u32/s32 form the UIToFp/SIToFp
        // cases below already pick, and a narrow float-to-int result is masked
        // back afterwards, the way Trunc does. Without this a `(float)<u16>` —
        // e.g. `1.5f / (float)W` with a `#define W` that fits in 16 bits — sank
        // the whole PTX kernel to a silent SPIR-V fallback, and the CUDA cards
        // then could not run or tile the block. FpExt/FpTrunc are float to
        // float, never narrow.
        String* d = ptxArith(rt);
        String* s = ptxArith(st);
        if (op.equals(self.ptxS("UIToFp"))) s = self.ptxS(ptxWide(st) ? "u64" : "u32");
        if (op.equals(self.ptxS("FpToUI"))) d = self.ptxS(ptxWide(rt) ? "u64" : "u32");
        if (op.equals(self.ptxS("SIToFp"))) s = self.ptxS(ptxWide(st) ? "s64" : "s32");
        if (op.equals(self.ptxS("FpToSI"))) d = self.ptxS(ptxWide(rt) ? "s64" : "s32");
        if (d == (String*)0 || s == (String*)0) return (String*)0;
        String* c = self.ptxS("cvt");
        if (op.equals(self.ptxS("FpToSI")) || op.equals(self.ptxS("FpToUI"))) c.appendCString(".rzi");
        else if (!op.equals(self.ptxS("FpExt"))) c.appendCString(".rn");
        c.appendCString("."); c.append(d); c.appendCString("."); c.append(s);
        String* out = ptx2(c, r, a);
        if ((op.equals(self.ptxS("FpToUI")) || op.equals(self.ptxS("FpToSI"))) && ptxNarrow(rt))
            {
            if (ptxIs(rt, "U8")) out.append(ptx3(ptxS("and.b32"), r, r, self.ptxS("255")));
            else if (ptxIs(rt, "U16")) out.append(ptx3(ptxS("and.b32"), r, r, self.ptxS("65535")));
            else if (ptxIs(rt, "I8")) out.append(ptxBfe(r, "8"));
            else if (ptxIs(rt, "I16")) out.append(ptxBfe(r, "16"));
            }
        return out;
        }

    final String* ptxStatement(IRInsn* ip)
        {
        String* op = ip.op();
        IRValue* rv = ip.res();
        String* rt = rv != (IRValue*)0 ? rv.ty() : (String*)0;
        String* r = rv != (IRValue*)0 ? ptxReg(rv) : (String*)0;
        IROperand* o0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
        if (op.equals(self.ptxS("Const")))
            {
            if (ptxIs(rt, "Bool"))
                {
                String* s = self.ptxS("\tmov.b32 %k, ");
                s.append(String.withI64(o0.imm())); s.appendCString(";\n\tsetp.ne.s32 "); s.append(r); s.appendCString(", %k, 0;\n");
                return s;
                }
            String* v = ptxOp(o0, rt);
            String* t = ptxRegType(rt);
            if (v == (String*)0 || t == (String*)0) return (String*)0;
            return ptx2(ptxCat("mov", t), r, v);
            }
        if (op.equals(self.ptxS("Add")) || op.equals(self.ptxS("Sub")) || op.equals(self.ptxS("Mul")) || op.equals(self.ptxS("UDiv")) || op.equals(self.ptxS("SDiv")) || op.equals(self.ptxS("URem")) || op.equals(self.ptxS("SRem")) || op.equals(self.ptxS("And")) || op.equals(self.ptxS("Or")) || op.equals(self.ptxS("Xor")) || op.equals(self.ptxS("Shl")) || op.equals(self.ptxS("LShr")) || op.equals(self.ptxS("AShr")) || op.equals(self.ptxS("FAdd")) || op.equals(self.ptxS("FSub")) || op.equals(self.ptxS("FMul")) || op.equals(self.ptxS("FDiv")))
            return ptxBinary(ip, r, rt);
        if (op.equals(self.ptxS("Not")))
            {
            String* a = ptxOp(o0, rt);
            if (a == (String*)0) return (String*)0;
            if (ptxIs(rt, "Bool")) return ptx2(ptxS("not.pred"), r, a);
            if (ptxNarrow(rt))
                {
                // In 32 bits, then back in the register form.
                if (o0.kind() == (u8)OPK_IMMI) return ptx2(ptxS("mov.b32"), r, String.withI64(ptxNarrowValue(rt, ~o0.imm())));
                String* s = ptx2(ptxS("not.b32"), r, a);
                s.append(ptxNarrowFix(rt, r));
                return s;
                }
            return ptx2(ptxS(ptxWide(rt) ? "not.b64" : "not.b32"), r, a);
            }
        if (op.equals(self.ptxS("Neg")) || op.equals(self.ptxS("FNeg")))
            {
            String* a = ptxOp(o0, rt);
            if (a != (String*)0 && ptxNarrow(rt))
                {
                // In 32 bits, then back in the register form.
                if (o0.kind() == (u8)OPK_IMMI) return ptx2(ptxS("mov.b32"), r, String.withI64(ptxNarrowValue(rt, (i64)0 - o0.imm())));
                String* s = ptx2(ptxS("neg.s32"), r, a);
                s.append(ptxNarrowFix(rt, r));
                return s;
                }
            String* sfx = ptxArith(rt);
            if (a == (String*)0 || sfx == (String*)0) return (String*)0;
            if (ptxIs(rt, "U32")) sfx = self.ptxS("s32");
            if (ptxIs(rt, "U64")) sfx = self.ptxS("s64");
            return ptx2(ptxCat("neg.", sfx), r, a);
            }
        if (op.equals(self.ptxS("FSqrt")))
            {
            String* a = ptxOp(o0, rt);
            if (a == (String*)0 || ptxArith(rt) == (String*)0) return (String*)0;
            // bug 643: approximate under :goal(speed), for f32
            if (_mFast && self.ptxIs(rt, "F32"))
                return ptx2(ptxS("sqrt.approx.ftz.f32"), r, a);
            return ptx2(ptxCat("sqrt.rn.", ptxArith(rt)), r, a);
            }
        if (op.equals(self.ptxS("ICmp")) || op.equals(self.ptxS("FCmp")))
            return ptxCompare(ip, r);
        if (op.equals(self.ptxS("ZExt")) || op.equals(self.ptxS("SExt")) || op.equals(self.ptxS("Trunc")) || op.equals(self.ptxS("Copy")))
            return ptxConvert(ip, r, rt);
        if (op.equals(self.ptxS("SIToFp")) || op.equals(self.ptxS("UIToFp")) || op.equals(self.ptxS("FpToSI")) || op.equals(self.ptxS("FpToUI")) || op.equals(self.ptxS("FpExt")) || op.equals(self.ptxS("FpTrunc")))
            return ptxFpConvert(ip, r, rt);
        if (op.equals(self.ptxS("Bitcast")))
            {
            // The same bits under another type: a move, and a narrow result
            // put back in its register form (an i8 read as a u8).
            String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
            String* a = ptxOp(o0, st);
            if (a == (String*)0 || st == (String*)0 || self.ptxIs(rt, "Bool") || self.ptxIs(st, "Bool")) return (String*)0;
            bool w = ptxWide(rt) || self.ptxIs(rt, "F64");
            String* s = ptx2(ptxS(w ? "mov.b64" : "mov.b32"), r, a);
            s.append(ptxNarrowFix(rt, r));
            return s;
            }
        if (op.equals(self.ptxS("Select")))
            {
            if (ptxIs(rt, "Bool")) return (String*)0;
            String* c = ptxOp(o0, (String*)0);
            String* a = ptxOp((IROperand*)ip.ops().get((u32)1), rt);
            String* b = ptxOp((IROperand*)ip.ops().get((u32)2), rt);
            String* t = ptxNarrow(rt) ? self.ptxS("b32") : ptxWide(rt) ? self.ptxS("b64") : ptxArith(rt);
            if (c == (String*)0 || a == (String*)0 || b == (String*)0 || t == (String*)0) return (String*)0;
            String* s = ptx3(ptxCat("selp.", t), r, a, b);
            String* u = s.substringBytes((u32)0, s.byteLength() - (u32)2);
            u.appendCString(", "); u.append(c); u.appendCString(";\n");
            return u;
            }
        if (op.equals(self.ptxS("FieldAddr")))
            {
            i64 k = self.mslSelfField(ip);
            if (k >= (i64)0 && self.mslIsPtr(_mObj.typeAt((u32)k)))
                return self.ptxS(""); // a captured array's slot: only ever loaded, as the buffer
            if (k >= (i64)0)
                return ptx3(ptxS("add.u64"), r, self.ptxS("%stp"), String.withU32(_mObj.offsetAt((u32)k)));
            IRLayout* l = self.mslLayoutOf(mslPointee(self.mslTypeOf(o0)));
            IROperand* fo = (IROperand*)ip.ops().get((u32)1);
            if (l == (IRLayout*)0 || fo.kind() != (u8)OPK_IMMI || fo.imm() < (i64)0 || fo.imm() >= (i64)l.fieldCount()) return (String*)0;
            return ptx3(ptxS("add.u64"), r, ptxReg(o0.val()), String.withU32(l.offsetAt((u32)fo.imm())));
            }
        if (op.equals(self.ptxS("ElementAddr")))
            {
            u32 size = ptxSize(mslPointee(self.mslTypeOf(o0)));
            String* base = ptxReg(o0.val());
            IROperand* io = (IROperand*)ip.ops().get((u32)1);
            if (io.kind() == (u8)OPK_IMMI)
                return ptx3(ptxS("add.u64"), r, base, String.withI64(io.imm() * (i64)size));
            String* it = self.mslTypeOf(io);
            String* idx = ptxReg(io.val());
            String* s = self.ptxS("");
            if (ptxWide(it))
                s.append(ptx2(ptxS("mov.b64"), self.ptxS("%x"), idx));
            else
                s.append(ptx2(ptxS(ptxSigned(it) ? "cvt.s64.s32" : "cvt.u64.u32"), self.ptxS("%x"), idx));
            String* m = ptx3(ptxS("mad.lo.u64"), r, self.ptxS("%x"), String.withU32(size));
            String* u = m.substringBytes((u32)0, m.byteLength() - (u32)2);
            u.appendCString(", "); u.append(base); u.appendCString(";\n");
            s.append(u);
            return s;
            }
        if (op.equals(self.ptxS("AddrOf")))
            {
            if (_mSinit.get((Hashable*)self.mslKey(rv)) != (Object*)0) return self.ptxS("");
            // A work item's own array: a .local array of the thread's. As the reference.
            String* lk = (String*)_mLocalOf.get((Hashable*)self.mslKey(rv));
            if (lk != (String*)0)
                {
                String* s = self.ptxS("\tmov.u64 ");
                s.append(r); s.appendCString(", loc_"); s.append(lk); s.appendCString(";\n");
                return s;
                }
            String* g = (String*)_mGlobalOf.get((Hashable*)self.mslKey(rv));
            if (g == (String*)0) return (String*)0;
            u32 gi = (u32)0;
            for (u32 q = (u32)0; q < _mGlobals.count(); q = q + (u32)1)
                if (((String*)_mGlobals.get(q)).equals(g)) { gi = q; break; }
            String* s = self.ptxS("\tld.param.u64 ");
            s.append(r); s.appendCString(", [glob_"); s.append(String.withU32(gi)); s.appendCString("];\n");
            s.append(ptx2(ptxS("cvta.to.global.u64"), r, r));
            return s;
            }
        if (op.equals(self.ptxS("Load")))
            {
            String* buf = (String*)_mBufOf.get((Hashable*)self.mslKey(rv));
            if (buf != (String*)0)
                {
                String* s = self.ptxS("\tld.param.u64 ");
                s.append(r); s.appendCString(", [buf_"); s.append(buf); s.appendCString("];\n");
                s.append(ptx2(ptxS("cvta.to.global.u64"), r, r));
                return s;
                }
            String* m = ptxMem(rt);
            if (m == (String*)0) return (String*)0;
            if (parSinitFlag(o0)) return ptx2(ptxS("mov.b32"), r, self.ptxS("2")); // a static-init flag: done
            String* sp = ptxSpaceOf(o0);
            String* a = ptxReg(o0.val());
            String* ld = self.ptxS("ld.");
            ld.append(sp); ld.appendCString(".");
            if (ptxIs(rt, "Bool"))
                {
                ld.appendCString("u8");
                String* s = ptx2(ld, self.ptxS("%k"), ptxCat("[", ptxCat("", a)));
                // ptx2 printed "%k, [a;": close the bracket.
                String* u = s.substringBytes((u32)0, s.byteLength() - (u32)2);
                u.appendCString("];\n");
                u.append(ptx3(ptxS("setp.ne.u32"), r, self.ptxS("%k"), self.ptxS("0")));
                return u;
                }
            ld.append(m);
            String* s = self.ptxS("\t");
            s.append(ld); s.appendCString(" "); s.append(r); s.appendCString(", ["); s.append(a); s.appendCString("];\n");
            return s;
            }
        if (op.equals(self.ptxS("Store")))
            {
            if (o0.kind() != (u8)OPK_USE) return (String*)0;
            String* pt = self.mslPointee(mslTypeOf(o0));
            IROperand* vo = (IROperand*)ip.ops().get((u32)1);
            String* m = ptxMem(pt);
            String* v = ptxOp(vo, pt);
            if (m == (String*)0 || v == (String*)0) return (String*)0;
            String* sp = ptxSpaceOf(o0);
            String* a = ptxReg(o0.val());
            String* st = self.ptxS("\tst.");
            st.append(sp); st.appendCString(".");
            if (ptxIs(pt, "Bool"))
                {
                String* s = self.ptxS("");
                if (vo.kind() != (u8)OPK_USE) s.append(ptx2(ptxS("mov.b32"), self.ptxS("%k"), v));
                else { s.appendCString("\tselp.b32 %k, 1, 0, "); s.append(v); s.appendCString(";\n"); }
                s.append(st); s.appendCString("u8 ["); s.append(a); s.appendCString("], %k;\n");
                return s;
                }
            if (vo.kind() != (u8)OPK_USE)
                {
                String* t = ptxRegType(pt);
                String* tmp = self.ptxS(t.equals(self.ptxS(".b64")) ? "%x" : t.equals(self.ptxS(".f32")) ? "%fk" : t.equals(self.ptxS(".f64")) ? "%dk" : "%k");
                String* s = ptx2(ptxCat("mov", t), tmp, v);
                s.append(st); s.append(m); s.appendCString(" ["); s.append(a); s.appendCString("], "); s.append(tmp); s.appendCString(";\n");
                return s;
                }
            String* s = String.withString(st);
            s.append(m); s.appendCString(" ["); s.append(a); s.appendCString("], "); s.append(v); s.appendCString(";\n");
            return s;
            }
        if (op.equals(self.ptxS("Call")))
            return ptxCall(ip, r, rt);
        if (op.equals(self.ptxS("DbgValue")))
            return self.ptxS("");
        return (String*)0;
        }

    // The blocks as labels: statements, then the edge moves and the branch.
    final String* ptxBody(IRFunc* f, string endLabel)
        {
        String* s = self.ptxS("");
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(bi);
            s.appendCString("BB"); s.append(String.withU32(bi)); s.appendCString(":\n");
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                {
                String* st = ptxStatement((IRInsn*)b.insns().get(i));
                if (st == (String*)0) { self.parBecause(parWhyFor((IRInsn*)b.insns().get(i), true)); return (String*)0; }
                s.append(st);
                }
            IRInsn* t = b.term();
            if (t == (IRInsn*)0) return (String*)0;
            if (t.op().equals(self.ptxS("Branch")))
                {
                IRBlock* to = ((IROperand*)t.ops().get((u32)0)).blk();
                String* c = ptxCopies(b, to);
                if (c == (String*)0) return (String*)0;
                s.append(c); s.appendCString("\tbra.uni BB"); s.append((String*)_mBlk.get((Hashable*)to.name())); s.appendCString(";\n");
                }
            else if (t.op().equals(self.ptxS("CondBranch")))
                {
                IRBlock* tt = ((IROperand*)t.ops().get((u32)1)).blk();
                IRBlock* ff = ((IROperand*)t.ops().get((u32)2)).blk();
                String* c = ptxOp((IROperand*)t.ops().get((u32)0), (String*)0);
                String* ct = ptxCopies(b, tt);
                String* cf = ptxCopies(b, ff);
                if (c == (String*)0 || ct == (String*)0 || cf == (String*)0) return (String*)0;
                String* e = String.withU32(_pEdge);
                _pEdge = _pEdge + (u32)1;
                s.appendCString("\t@"); s.append(c); s.appendCString(" bra E"); s.append(e); s.appendCString(";\n");
                s.append(cf); s.appendCString("\tbra.uni BB"); s.append((String*)_mBlk.get((Hashable*)ff.name())); s.appendCString(";\n");
                s.appendCString("E"); s.append(e); s.appendCString(":\n");
                s.append(ct); s.appendCString("\tbra.uni BB"); s.append((String*)_mBlk.get((Hashable*)tt.name())); s.appendCString(";\n");
                }
            else if (t.op().equals(self.ptxS("Return")))
                {
                if (_mHelper)
                    {
                    IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                    String* rvt = rv == (IROperand*)0 ? (String*)0 : rv.kind() == (u8)OPK_USE ? self.mslTypeOf(rv) : f.ret();
                    if (rvt != (String*)0 && !rvt.equals(self.ptxS("Mem")) && !rvt.equals(self.ptxS("Void")))
                        {
                        String* v = ptxOp(rv, rvt);
                        String* pt = ptxRegType(rvt);
                        if (v == (String*)0 || pt == (String*)0) return (String*)0;
                        s.appendCString("\tst.param"); s.append(pt); s.appendCString(" [rv], "); s.append(v); s.appendCString(";\n");
                        }
                    s.appendCString("\tret;\n");
                    }
                else
                    { s.appendCString("\tbra.uni "); s.appendCString(endLabel); s.appendCString(";\n"); }
                }
            else
                return (String*)0;
            }
        return s;
        }

    final void ptxOrdinals(IRFunc* f)
        {
        u32 ord = (u32)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            _mBlk.set((Hashable*)bb.name(), (Object*)String.withU32(b));
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(self.ptxS("Mem")))
                    { _mOrd.set((Hashable*)self.mslKey(ip.res()), (Object*)String.withU32(ord)); ord = ord + (u32)1; }
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(self.ptxS("Mem")))
                    { _mOrd.set((Hashable*)self.mslKey(ip.res()), (Object*)String.withU32(ord)); ord = ord + (u32)1; }
                }
            }
        }

    static bool ptxIdentStart(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z') || c == (u8)'_';
        }

    static bool ptxIdentChar(u8 c)
        {
        return Lower.ptxIdentStart(c) || (c >= (u8)'0' && c <= (u8)'9');
        }

    // A declared register after `%`, or a label, gets the prefix (the
    // reference's rename block).
    static String* ptxRename(String* ln, String* pre, Set* regs, Set* labels)
        {
        String* o = String.withCString("");
        u32 i = (u32)0;
        u32 n = ln.byteLength();
        while (i < n)
            {
            u8 c = ln.byteAt(i);
            bool afterDot = i > (u32)0 && ln.byteAt(i - (u32)1) == (u8)'.';
            if (c == (u8)'%' && i + (u32)1 < n && Lower.ptxIdentStart(ln.byteAt(i + (u32)1)))
                {
                u32 e = i + (u32)1;
                while (e < n && Lower.ptxIdentChar(ln.byteAt(e)))
                    e = e + (u32)1;
                String* nm = ln.substringBytes(i + (u32)1, e - i - (u32)1);
                o.appendByte((u8)'%');
                if (regs.contains((Hashable*)nm))
                    o.append(pre);
                o.append(nm);
                i = e;
                }
            else if (Lower.ptxIdentStart(c) && !afterDot && (i == (u32)0 || !Lower.ptxIdentChar(ln.byteAt(i - (u32)1))))
                {
                u32 e = i;
                while (e < n && Lower.ptxIdentChar(ln.byteAt(e)))
                    e = e + (u32)1;
                String* nm = ln.substringBytes(i, e - i);
                if (labels.contains((Hashable*)nm))
                    o.append(pre);
                o.append(nm);
                i = e;
                }
            else
                {
                o.appendByte(c);
                i = i + (u32)1;
                }
            }
        return o;
        }

    // ptxFieldReg / ptxFieldAt / ptxScalarReplace: the block object's fields
    // in registers (the reference explains; bug 645).
    static String* ptxFieldReg(String* t)
        {
        if (t.equals(String.withCString("u64")) || t.equals(String.withCString("s64")) || t.equals(String.withCString("b64")))
            return String.withCString("b64");
        if (t.equals(String.withCString("u32")) || t.equals(String.withCString("s32")) || t.equals(String.withCString("b32")))
            return String.withCString("b32");
        if (t.equals(String.withCString("f32")) || t.equals(String.withCString("f64")))
            return String.withString(t);
        return (String*)0;
        }

    static i64 ptxDigits(String* s, u32 from)
        {
        i64 v = (i64)0;
        for (u32 q = from; q < s.byteLength() && s.byteAt(q) >= (u8)'0' && s.byteAt(q) <= (u8)'9'; q = q + (u32)1)
            v = v * (i64)10 + (i64)(s.byteAt(q) - (u8)'0');
        return v;
        }

    static i64 ptxFieldAt(String* a, Map* addr)
        {
        Number* n = (Number*)addr.get((Hashable*)a);
        if (n != (Number*)0) return n.asI64();
        if (a.hasPrefix(String.withCString("%stp+"))) return Lower.ptxDigits(a, (u32)5);
        if (a.equals(String.withCString("%stp"))) return (i64)0;
        return (i64)0 - (i64)1;
        }

    static String* ptxScalarReplace(String* text)
        {
        Array* lines = text.splitOnByte((u8)10);
        u32 nl = lines.count();
        Map* addr = new Map();
        Array* addrNames = new Array();
        for (u32 i = (u32)0; i < nl; i = i + (u32)1)
            {
            String* ln = (String*)lines.get(i);
            if (ln.hasPrefix(String.withCString("\tadd.u64 %v")) && ln.hasSuffix(String.withCString(";")))
                {
                u32 c = ln.byteIndexOf(String.withCString(", %stp, "));
                if (c != String.notFound())
                    {
                    String* nm = ln.substringBytes((u32)9, c - (u32)9);
                    if (addr.get((Hashable*)nm) == (Object*)0) addrNames.add((Object*)nm);
                    addr.set((Hashable*)nm, (Object*)Number.withI64(Lower.ptxDigits(ln, c + (u32)8)));
                    }
                }
            }
        Map* type = new Map();          // decimal offset -> type
        Map* stored = new Map();        // decimal offset -> itself
        Map* copyLines = new Map();     // decimal line index -> itself
        Map* defLines = new Map();
        u32 nCopy = (u32)0;
        u32 nDef = (u32)0;
        u32 uses = (u32)0;
        u32 i = (u32)0;
        while (i < nl)
            {
            String* ln = (String*)lines.get(i);
            if (ln.hasPrefix(String.withCString("\tld.param.")) && ln.contains(String.withCString(", [args+")) && i + (u32)1 < nl
                && ((String*)lines.get(i + (u32)1)).hasPrefix(String.withCString("\tst.local.")))
                {
                copyLines.set((Hashable*)String.withU32(i), (Object*)String.withU32(i));
                copyLines.set((Hashable*)String.withU32(i + (u32)1), (Object*)String.withU32(i + (u32)1));
                nCopy = nCopy + (u32)2;
                i = i + (u32)2;
                continue;
                }
            if (ln.hasPrefix(String.withCString("\tadd.u64 %v")) && ln.contains(String.withCString(", %stp, ")))
                {
                defLines.set((Hashable*)String.withU32(i), (Object*)String.withU32(i));
                nDef = nDef + (u32)1;
                i = i + (u32)1;
                continue;
                }
            bool ld = ln.hasPrefix(String.withCString("\tld.local."));
            bool st = ln.hasPrefix(String.withCString("\tst.local."));
            if (!ld && !st) { i = i + (u32)1; continue; }
            u32 sp = ln.indexOfByte((u8)' ');
            String* t = ln.substringBytes((u32)10, sp - (u32)10);
            u32 lb = ln.indexOfByte((u8)'[');
            u32 rb = ln.indexOfByte((u8)']');
            if (lb == String.notFound() || rb == String.notFound() || Lower.ptxFieldReg(t) == (String*)0) return text;
            i64 off = Lower.ptxFieldAt(ln.substringBytes(lb + (u32)1, rb - lb - (u32)1), addr);
            if (off < (i64)0) return text;
            String* ok = String.withU32((u32)off);
            String* had = (String*)type.get((Hashable*)ok);
            if (had != (String*)0 && !had.equals(t)) return text;
            type.set((Hashable*)ok, (Object*)t);
            if (st) stored.set((Hashable*)ok, (Object*)ok);
            uses = uses + (u32)1;
            i = i + (u32)1;
            }
        // Every mention of %stp and of each field address must be one of those.
        u32 stpSeen = (u32)0;
        u32 addrSeen = (u32)0;
        for (u32 li = (u32)0; li < nl; li = li + (u32)1)
            {
            String* ln = (String*)lines.get(li);
            // A declaration is not a use.
            if (copyLines.get((Hashable*)String.withU32(li)) != (Object*)0 || ln.hasPrefix(String.withCString("\t.reg "))
                || ln.equals(String.withCString("\tmov.u64 %stp, st;")))
                continue;
            if (ln.contains(String.withCString("%stp"))) stpSeen = stpSeen + (u32)1;
            for (u32 ai = (u32)0; ai < addrNames.count(); ai = ai + (u32)1)
                {
                String* a = (String*)addrNames.get(ai);
                u32 r = ln.byteIndexOf(a);
                while (r != String.notFound())
                    {
                    u32 e = r + a.byteLength();
                    if (e >= ln.byteLength() || !Lower.ptxIdentChar(ln.byteAt(e))) addrSeen = addrSeen + (u32)1;
                    if (e >= ln.byteLength()) break;
                    r = ln.byteIndexOf(a, e);
                    }
                }
            }
        u32 direct = (u32)0;
        u32 through = (u32)0;
        for (u32 li = (u32)0; li < nl; li = li + (u32)1)
            {
            String* ln = (String*)lines.get(li);
            if (ln.hasPrefix(String.withCString("\tld.local.")) || ln.hasPrefix(String.withCString("\tst.local.")))
                {
                if (ln.contains(String.withCString("[%stp"))) direct = direct + (u32)1;
                else through = through + (u32)1;
                }
            }
        direct = direct - nCopy / (u32)2;
        if (stpSeen != nDef + direct || addrSeen != nDef + through || uses != direct + through) return text;
        // Only a field the kernel writes lives in a register (the reference).
        Array* offs = new Array();
        Array* keys = type.allKeys();
        for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
            {
            String* key = (String*)keys.get(k);
            if (stored.get((Hashable*)key) == (Object*)0) continue;
            u32 v = (u32)Lower.ptxDigits(key, (u32)0);
            u32 at = offs.count();
            while (at > (u32)0 && (u32)Lower.ptxDigits((String*)offs.get(at - (u32)1), (u32)0) > v)
                at = at - (u32)1;
            offs.insert(at, (Object*)key);
            }
        String* out = String.withCString("");
        for (u32 li = (u32)0; li < nl; li = li + (u32)1)
            {
            String* ln = (String*)lines.get(li);
            if (copyLines.get((Hashable*)String.withU32(li)) != (Object*)0 || defLines.get((Hashable*)String.withU32(li)) != (Object*)0)
                continue;
            if (ln.hasPrefix(String.withCString("\t.local .align 8 .b8 st[")))
                {
                for (u32 k = (u32)0; k < offs.count(); k = k + (u32)1)
                    {
                    String* o = (String*)offs.get(k);
                    out.appendCString("\t.reg ."); out.append(Lower.ptxFieldReg((String*)type.get((Hashable*)o)));
                    out.appendCString(" %fd"); out.append(o); out.appendCString(";\n");
                    }
                continue;
                }
            if (ln.equals(String.withCString("\tmov.u64 %stp, st;")))
                {
                for (u32 k = (u32)0; k < offs.count(); k = k + (u32)1)
                    {
                    String* o = (String*)offs.get(k);
                    out.appendCString("\tld.param."); out.append((String*)type.get((Hashable*)o));
                    out.appendCString(" %fd"); out.append(o); out.appendCString(", [args+"); out.append(o); out.appendCString("];\n");
                    }
                continue;
                }
            bool ld = ln.hasPrefix(String.withCString("\tld.local."));
            bool st = ln.hasPrefix(String.withCString("\tst.local."));
            if (ld || st)
                {
                u32 sp = ln.indexOfByte((u8)' ');
                String* t = ln.substringBytes((u32)10, sp - (u32)10);
                u32 lb = ln.indexOfByte((u8)'[');
                u32 rb = ln.indexOfByte((u8)']');
                String* o = String.withU32((u32)Lower.ptxFieldAt(ln.substringBytes(lb + (u32)1, rb - lb - (u32)1), addr));
                String* mt = Lower.ptxFieldReg(t);
                if (ld)
                    {
                    String* r = ln.substringBytes(sp + (u32)1, lb - (u32)2 - sp - (u32)1);
                    if (stored.get((Hashable*)o) != (Object*)0)
                        {
                        out.appendCString("\tmov."); out.append(mt); out.appendCString(" "); out.append(r);
                        out.appendCString(", %fd"); out.append(o); out.appendCString(";\n");
                        }
                    else
                        {
                        out.appendCString("\tld.param."); out.append(t); out.appendCString(" "); out.append(r);
                        out.appendCString(", [args+"); out.append(o); out.appendCString("];\n");
                        }
                    }
                else
                    {
                    String* r = ln.substringBytes(rb + (u32)3, ln.byteLength() - rb - (u32)4);
                    out.appendCString("\tmov."); out.append(mt); out.appendCString(" %fd"); out.append(o);
                    out.appendCString(", "); out.append(r); out.appendCString(";\n");
                    }
                continue;
                }
            out.append(ln);
            if (li + (u32)1 < nl) out.appendCString("\n");
            }
        return out;
        }

    // A printed helper as a block inside the caller (the reference explains;
    // bug 645).
    static String* ptxInline(String* text, u32 serial, Array* args, String* result)
        {
        String* pre = String.withCString("h");
        pre.append(String.withU32(serial));
        pre.appendByte((u8)'_');
        Array* lines = text.splitOnByte((u8)10);
        Set* regs = new Set();
        Set* labels = new Set();
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1)
            {
            String* ln = (String*)lines.get(li);
            if (ln.hasPrefix(String.withCString("\t.reg ")))
                {
                u32 at = (u32)6;
                while (at < ln.byteLength() && ln.byteAt(at) != (u8)' ')
                    at = at + (u32)1;
                Array* parts = ln.substringFromByte(at).splitOnByte((u8)',');
                for (u32 pi = (u32)0; pi < parts.count(); pi = pi + (u32)1)
                    {
                    String* nm = ((String*)parts.get(pi)).replacing(String.withCString(";"), String.withCString("")).trimmed();
                    if (nm.hasPrefix(String.withCString("%")))
                        regs.add((Hashable*)nm.substringFromByte((u32)1));
                    }
                }
            else if (ln.byteLength() > (u32)1 && ln.hasSuffix(String.withCString(":")) && Lower.ptxIdentStart(ln.byteAt((u32)0)))
                labels.add((Hashable*)ln.substringBytes((u32)0, ln.byteLength() - (u32)1));
            }
        String* out = String.withCString("\t{\n");
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1)
            {
            String* ln = (String*)lines.get(li);
            if (ln.byteLength() == (u32)0 || ln.hasPrefix(String.withCString(".func ")) || ln.equals(String.withCString("{"))
                || ln.equals(String.withCString("}")))
                continue;
            if (ln.hasPrefix(String.withCString("\tld.param")) && ln.contains(String.withCString(", [p")))
                {
                u32 sp = ln.indexOfByte((u8)' ');
                String* ty = ln.substringBytes((u32)9, sp - (u32)9);
                u32 lb = ln.byteIndexOf(String.withCString("[p"));
                u32 k = (u32)0;
                for (u32 q = lb + (u32)2; q < ln.byteLength() && ln.byteAt(q) >= (u8)'0' && ln.byteAt(q) <= (u8)'9'; q = q + (u32)1)
                    k = k * (u32)10 + (u32)(ln.byteAt(q) - (u8)'0');
                String* dst = ln.substringBytes(sp + (u32)1, lb - (u32)2 - sp - (u32)1);
                out.appendCString("\tmov"); out.append(ty); out.appendCString(" ");
                out.append(Lower.ptxRename(dst, pre, regs, labels)); out.appendCString(", ");
                if (k < args.count()) out.append((String*)args.get(k)); else out.appendCString("0");
                out.appendCString(";\n");
                continue;
                }
            if (ln.hasPrefix(String.withCString("\tst.param")) && ln.contains(String.withCString("[rv], ")))
                {
                u32 sp = ln.indexOfByte((u8)' ');
                String* ty = ln.substringBytes((u32)9, sp - (u32)9);
                u32 rv = ln.byteIndexOf(String.withCString("[rv], "));
                String* val = ln.substringBytes(rv + (u32)6, ln.byteLength() - rv - (u32)7);
                if (result != (String*)0)
                    {
                    out.appendCString("\tmov"); out.append(ty); out.appendCString(" "); out.append(result);
                    out.appendCString(", "); out.append(Lower.ptxRename(val, pre, regs, labels)); out.appendCString(";\n");
                    }
                continue;
                }
            if (ln.equals(String.withCString("\tret;")))
                {
                out.appendCString("\tbra.uni "); out.append(pre); out.appendCString("END;\n");
                continue;
                }
            out.append(Lower.ptxRename(ln, pre, regs, labels));
            out.appendCString("\n");
            }
        out.append(pre);
        out.appendCString("END:\n\t}\n");
        return out;
        }

    // A helper as a .func: scalars in and out, as .param values. The
    // caller's state comes back afterwards.
    final String* ptxHelper(IRFunc* g, String* name)
        {
        Map* sDef = _mDef; Map* sSpace = _mSpace; Map* sBufOf = _mBufOf; Map* sOrd = _mOrd;
        Map* sBlk = _mBlk; Map* sBufs = _mBufs; Map* sReds = _mReds; IRLayout* sObj = _mObj;
        bool sFailed = _mFailed; bool sHelper = _mHelper; Map* sParams = _mParams; Map* sSinit = _mSinit; String* sWhy = _mWhy;
        Map* sLocalOf = _mLocalOf; Map* sLocalIndex = _mLocalIndex; Array* sLocalDecls = _mLocalDecls; Array* sLocalBytes = _mLocalBytes; Array* sLocalElem = _mLocalElem;
        u32 sEdge = _pEdge;
        String* out = ptxHelperText(g, name);
        _mHelperWhy = _mWhy;
        _mDef = sDef; _mSpace = sSpace; _mBufOf = sBufOf; _mOrd = sOrd;
        _mBlk = sBlk; _mBufs = sBufs; _mReds = sReds; _mObj = sObj;
        _mFailed = sFailed; _mHelper = sHelper; _mParams = sParams; _mSinit = sSinit; _mWhy = sWhy;
        _mLocalOf = sLocalOf; _mLocalIndex = sLocalIndex; _mLocalDecls = sLocalDecls; _mLocalBytes = sLocalBytes; _mLocalElem = sLocalElem;
        _pEdge = sEdge;
        return out;
        }
    final String* ptxHelperText(IRFunc* g, String* name)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = true;
        _mParams = new Map();
        _mObj = (IRLayout*)0;
        _pEdge = (u32)0;
        if (!self.mslAnalyse(g)) return (String*)0;
        ptxOrdinals(g);
        String* params = self.ptxS("");
        String* loads = self.ptxS("");
        for (u32 k = (u32)0; k + (u32)1 < g.params().count(); k = k + (u32)1)
            {
            IRValue* pv = (IRValue*)g.params().get(k);
            String* t = ptxRegType(pv.ty());
            if (t == (String*)0 || t.equals(self.ptxS(".pred"))) return (String*)0;
            _mParams.set((Hashable*)self.mslKey(pv), (Object*)String.withU32(k));
            String* kk = String.withU32(k);
            if (k > (u32)0) params.appendCString(", ");
            params.appendCString(".param "); params.append(t); params.appendCString(" p"); params.append(kk);
            loads.appendCString("\t.reg "); loads.append(t); loads.appendCString(" %a"); loads.append(kk); loads.appendCString(";\n");
            loads.appendCString("\tld.param"); loads.append(t); loads.appendCString(" %a"); loads.append(kk); loads.appendCString(", [p"); loads.append(kk); loads.appendCString("];\n");
            }
        String* rt = g.ret();
        bool isVoid = rt == (String*)0 || rt.equals(self.ptxS("Void")) || rt.equals(self.ptxS("Mem"));
        String* rtt = isVoid ? (String*)0 : ptxRegType(rt);
        if (!isVoid && (rtt == (String*)0 || rtt.equals(self.ptxS(".pred")))) return (String*)0;
        String* decls = ptxDecls(g);
        String* body = ptxBody(g, "");
        if (decls == (String*)0 || body == (String*)0 || _mFailed) return (String*)0;
        String* out = self.ptxS(".func ");
        if (!isVoid) { out.appendCString("(.param "); out.append(rtt); out.appendCString(" rv) "); }
        out.append(name); out.appendCString("("); out.append(params); out.appendCString(")\n{\n");
        out.appendCString("\t.reg .b32 %k;\n\t.reg .b64 %x;\n\t.reg .f32 %fk;\n\t.reg .f64 %dk;\n");
        out.append(loads);
        out.append(decls);
        out.append(body);
        out.appendCString("}\n");
        return out;
        }

    // One step of a device-side reduction (bug 645): d = a <op> b in t's PTX
    // spelling, or 0 for an operator t cannot take (a bitwise one on a float).
    // A float is combined exactly rounded (.rn) whatever the block's goal: the
    // tree's order is fixed, so the result is the same run to run.
    final String* ptxRedStep(String* op, String* t, string d, string a, string b)
        {
        bool f = self.ptxIs(t, "F32") || self.ptxIs(t, "F64");
        bool w = self.ptxIs(t, "I64") || self.ptxIs(t, "U64") || self.ptxIs(t, "F64");
        string bits = w ? "64" : "32";
        string ft = self.ptxIs(t, "F64") ? "f64" : "f32";
        bool sg = self.ptxIs(t, "I8") || self.ptxIs(t, "I16") || self.ptxIs(t, "I32") || self.ptxIs(t, "I64");
        String* ins = (String*)0;
        if (op.equals(self.ptxS("+")))
            ins = f ? String.withFormat("add.rn.%s", ft) : String.withFormat("add.s%s", bits);
        else if (op.equals(self.ptxS("*")))
            ins = f ? String.withFormat("mul.rn.%s", ft) : String.withFormat("mul.lo.s%s", bits);
        else if (op.equals(self.ptxS("&")) && !f)
            ins = String.withFormat("and.b%s", bits);
        else if (op.equals(self.ptxS("|")) && !f)
            ins = String.withFormat("or.b%s", bits);
        else if (op.equals(self.ptxS("^")) && !f)
            ins = String.withFormat("xor.b%s", bits);
        else if (op.equals(self.ptxS("min")))
            ins = f ? String.withFormat("min.%s", ft) : String.withFormat("min.%s%s", sg ? "s" : "u", bits);
        else if (op.equals(self.ptxS("max")))
            ins = f ? String.withFormat("max.%s", ft) : String.withFormat("max.%s%s", sg ? "s" : "u", bits);
        if (ins == (String*)0)
            return (String*)0;
        return String.withFormat("\t%s %s, %s, %s;\n", ins.cString(), d, a, b);
        }

    final String* parPtx(IRFunc* f)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = false;
        _mParams = (Map*)0;
        _mGlobals = new Array();
        _mGlobalOf = new Map();
        _pEdge = (u32)0;
        if (f.params().count() == (u32)0) return (String*)0;
        _mObj = self.mslLayoutOf(mslPointee(((IRValue*)f.params().get((u32)0)).ty()));
        if (_mObj == (IRLayout*)0 || _mObj.fieldCount() < (u32)3 || !_mObj.typeAt((u32)1).equals(self.ptxS("I64")) || !_mObj.typeAt((u32)2).equals(self.ptxS("I64")))
            return (String*)0;
        if (!self.mslAnalyse(f)) return (String*)0;
        _mHelperText = new Array();
        _mHelperNames = new Map();
        _mHelperBodies = new Map();
        _mHelperCalled = new Map();
        _mInlineSerial = (u32)0;
        ptxOrdinals(f);
        String* decls = ptxDecls(f);
        String* body = ptxBody(f, "BODY_END");
        if (decls == (String*)0 || body == (String*)0 || _mFailed) return (String*)0;

        String* meta = self.ptxS("// xcpar ptx size=");
        meta.append(String.withU32(_mObj.size())); meta.appendCString(" lo="); meta.append(String.withU32(_mObj.offsetAt((u32)1)));
        meta.appendCString(" hi="); meta.append(String.withU32(_mObj.offsetAt((u32)2)));
        // The block object and the range by value (the reference explains;
        // bug 645), when the object fits in parameter space.
        bool byval = _mObj.size() <= (u32)3072;
        String* params = self.ptxS(".param .u64 args, .param .u64 span");
        if (byval)
            {
            params = self.ptxS(".param .align 8 .b8 args[");
            params.append(String.withU32(_mObj.size()));
            params.appendCString("], .param .align 8 .b8 span[24]");
            }
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mBufs.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* et = self.mslPointee(_mObj.typeAt(k));
            if (ptxMem(et) == (String*)0) return (String*)0;
            meta.appendCString(" buf="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":");
            meta.append(String.withU32(k - (u32)3)); meta.appendCString(":"); meta.append(String.withU32(ptxSize(et)));
            params.appendCString(", .param .u64 buf_"); params.append(String.withU32(k));
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
            if (ptxMem(et) == (String*)0) return (String*)0;
            meta.appendCString(" glob="); meta.append(gn); meta.appendCString(":"); meta.append(String.withU32(ptxSize(et)));
            params.appendCString(", .param .u64 glob_"); params.append(String.withU32(gi));
            }
        if (_parExtraMeta != (String*)0) meta.append(_parExtraMeta);
        String* tail = self.ptxS("");
        String* dtail = self.ptxS("");
        String* ftail = self.ptxS("");
        bool anyRed = false;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            if (_mReds.get((Hashable*)String.withI64((i64)k)) != (Object*)0)
                anyRed = true;
        bool devred = _mRedOps != (Map*)0 && anyRed;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mReds.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* t = _mObj.typeAt(k);
            String* m = ptxMem(t);
            String* rt = ptxRegType(t);
            if (m == (String*)0 || rt == (String*)0 || rt.equals(self.ptxS(".pred"))) return (String*)0;
            String* kk = String.withU32(k);
            meta.appendCString(" red="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":"); meta.append(String.withU32(ptxSize(t)));
            params.appendCString(", .param .u64 red_"); params.append(kk);
            String* tmp = self.ptxS(rt.equals(self.ptxS(".b64")) ? "%y" : rt.equals(self.ptxS(".f32")) ? "%fk" : rt.equals(self.ptxS(".f64")) ? "%dk" : "%k");
            tail.appendCString("\tld.local."); tail.append(m); tail.appendCString(" "); tail.append(tmp); tail.appendCString(", [%stp+");
            tail.append(String.withU32(_mObj.offsetAt(k))); tail.appendCString("];\n\tld.param.u64 %x, [red_"); tail.append(kk);
            tail.appendCString("];\n\tcvta.to.global.u64 %x, %x;\n\tmad.lo.u64 %x, %tid64, "); tail.append(String.withU32(ptxSize(t)));
            tail.appendCString(", %x;\n\tst.global."); tail.append(m); tail.appendCString(" [%x], "); tail.append(tmp); tail.appendCString(";\n");
            // On the device (bug 645): this field's value from every thread of
            // the workgroup, through shared memory, combined in a fixed tree;
            // thread 0 writes the workgroup's one partial at red_k + ctaid * width.
            String* rop = _mRedOps != (Map*)0 ? (String*)_mRedOps.get((Hashable*)kk) : (String*)0;
            String* tmp2 = String.withString(tmp);
            tmp2.appendCString("2");
            String* step = rop != (String*)0 ? ptxRedStep(rop, t, tmp.cString(), tmp.cString(), tmp2.cString()) : (String*)0;
            if (step == (String*)0)
                devred = false;
            else
                {
                dtail.appendFormat("\tld.local.%s %s, [%%stp+%u];\n\tst.shared.%s [%%sha], %s;\n\tbar.sync 0;\n", m.cString(),
                                   tmp.cString(), _mObj.offsetAt(k), m.cString(), tmp.cString());
                for (u32 sw = (u32)128; sw >= (u32)1; sw = sw / (u32)2)
                    {
                    dtail.appendFormat("\tsetp.ge.u32 %%pz, %%tx, %u;\n\t@%%pz bra RS_%u_%u;\n", sw, k, sw);
                    dtail.appendFormat("\tld.shared.%s %s, [%%sha];\n\tld.shared.%s %s, [%%sha+%u];\n", m.cString(), tmp.cString(),
                                       m.cString(), tmp2.cString(), sw * (u32)8);
                    dtail.append(step);
                    dtail.appendFormat("\tst.shared.%s [%%sha], %s;\nRS_%u_%u:\n\tbar.sync 0;\n", m.cString(), tmp.cString(), k, sw);
                    }
                dtail.appendFormat("\tsetp.ne.u32 %%pz, %%tx, 0;\n\t@%%pz bra RN_%u;\n\tld.shared.%s %s, [%%shb];\n", k, m.cString(),
                                   tmp.cString());
                dtail.appendFormat("\tld.param.u64 %%x, [red_%u];\n\tcvta.to.global.u64 %%x, %%x;\n", k);
                dtail.appendFormat("\tmad.lo.u64 %%x, %%cta64, %u, %%x;\n\tst.global.%s [%%x], %s;\nRN_%u:\n\tbar.sync 0;\n",
                                   ptxSize(t), m.cString(), tmp.cString(), k);
                // The last workgroup's fold of this field (the reference
                // explains; bug 645).
                ftail.appendFormat("\tld.param.u64 %%x, [red_%u];\n\tcvta.to.global.u64 %%x, %%x;\n", k);
                ftail.appendFormat("\tsetp.ge.u32 %%pz, %%tx, %%nc;\n\t@%%pz bra FA_%u;\n", k);
                ftail.appendFormat("\tmul.wide.u32 %%fa, %%tx, %u;\n\tadd.u64 %%fa, %%fa, %%x;\n\tld.global.cg.%s %s, [%%fa];\n",
                                   ptxSize(t), m.cString(), tmp.cString());
                ftail.appendFormat("\tadd.u32 %%j, %%tx, 256;\nFL_%u:\n\tsetp.ge.u32 %%pz, %%j, %%nc;\n\t@%%pz bra FS_%u;\n", k, k);
                ftail.appendFormat("\tmul.wide.u32 %%fa, %%j, %u;\n\tadd.u64 %%fa, %%fa, %%x;\n\tld.global.cg.%s %s, [%%fa];\n",
                                   ptxSize(t), m.cString(), tmp2.cString());
                ftail.append(step);
                ftail.appendFormat("\tadd.u32 %%j, %%j, 256;\n\tbra.uni FL_%u;\nFS_%u:\n\tst.shared.%s [%%sha], %s;\nFA_%u:\n\tbar.sync 0;\n",
                                   k, k, m.cString(), tmp.cString(), k);
                for (u32 sw = (u32)128; sw >= (u32)1; sw = sw / (u32)2)
                    {
                    ftail.appendFormat("\tsetp.ge.u32 %%pz, %%tx, %u;\n\t@%%pz bra FR_%u_%u;\n", sw, k, sw);
                    ftail.appendFormat("\tadd.u32 %%j, %%tx, %u;\n\tsetp.ge.u32 %%pz, %%j, %%nv;\n\t@%%pz bra FR_%u_%u;\n", sw, k, sw);
                    ftail.appendFormat("\tld.shared.%s %s, [%%sha];\n\tld.shared.%s %s, [%%sha+%u];\n", m.cString(), tmp.cString(),
                                       m.cString(), tmp2.cString(), sw * (u32)8);
                    ftail.append(step);
                    ftail.appendFormat("\tst.shared.%s [%%sha], %s;\nFR_%u_%u:\n\tbar.sync 0;\n", m.cString(), tmp.cString(), k, sw);
                    }
                ftail.appendFormat("\tsetp.ne.u32 %%pz, %%tx, 0;\n\t@%%pz bra FN_%u;\n\tld.shared.%s %s, [%%shb];\n", k, m.cString(),
                                   tmp.cString());
                ftail.appendFormat("\tst.global.%s [%%x], %s;\nFN_%u:\n\tbar.sync 0;\n", m.cString(), tmp.cString(), k);
                }
            }

        if (devred) meta.appendCString(" devred devlast");
        if (byval) meta.appendCString(" byval");
        if (_mFast) meta.appendCString(" fast");
        String* out = String.withString(meta);
        out.appendCString("\n.version 7.0\n.target sm_52\n.address_size 64\n");
        // How many workgroups have finished (the reference explains).
        if (devred)
            out.appendCString(".global .align 4 .u32 par_done;\n");
        for (u32 i = (u32)0; i < _mHelperText.count(); i = i + (u32)1)
            out.append((String*)_mHelperText.get(i));
        out.appendCString(".visible .entry par_kernel("); out.append(params); out.appendCString(")\n{\n");
        out.appendCString("\t.local .align 8 .b8 st["); out.append(String.withU32(_mObj.size())); out.appendCString("];\n");
        // The work item's own arrays, in the order first met.
        for (u32 q = (u32)0; q < _mLocalBytes.count(); q = q + (u32)1)
            {
            out.appendCString("\t.local .align 8 .b8 loc_"); out.append(String.withU32(q)); out.appendCString("[");
            out.append(String.withU32(((Number*)_mLocalBytes.get(q)).asU32())); out.appendCString("];\n");
            }
        if (devred)
            out.appendCString("\t.shared .align 8 .b8 sh[2056];\n\t.reg .b64 %sha, %shb, %cta64, %y2, %fa;\n\t.reg .b32 %k2, %nc, %nv, %j;\n\t.reg .f32 %fk2;\n\t.reg .f64 %dk2;\n\t.reg .pred %pl;\n");
        out.appendCString("\t.reg .b64 %stp, %ga, %gs, %lo, %hi, %end, %per, %tid64, %x, %y;\n");
        out.appendCString("\t.reg .b32 %gid, %k, %nt, %ct, %tx;\n\t.reg .f32 %fk;\n\t.reg .f64 %dk;\n\t.reg .pred %pz;\n");
        out.append(decls);
        if (byval)
            out.appendCString("\tmov.u64 %stp, st;\n");
        else
            out.appendCString("\tmov.u64 %stp, st;\n\tld.param.u64 %ga, [args];\n\tcvta.to.global.u64 %ga, %ga;\n");
        // The block object into the thread's copy, eight bytes at a time,
        // then any tail byte by byte (the reference explains; bug 645).
        string from = byval ? "\tld.param." : "\tld.global.";
        string base = byval ? "args+" : "%ga+";
        u32 q = (u32)0;
        while (q + (u32)8 <= _mObj.size())
            {
            String* qs = String.withU32(q);
            out.appendCString(from); out.appendCString("u64 %x, ["); out.appendCString(base); out.append(qs);
            out.appendCString("];\n\tst.local.u64 [%stp+"); out.append(qs); out.appendCString("], %x;\n");
            q = q + (u32)8;
            }
        while (q < _mObj.size())
            {
            String* qs = String.withU32(q);
            out.appendCString(from); out.appendCString("u8 %k, ["); out.appendCString(base); out.append(qs);
            out.appendCString("];\n\tst.local.u8 [%stp+"); out.append(qs); out.appendCString("], %k;\n");
            q = q + (u32)1;
            }
        if (byval)
            {
            out.appendCString("\tmov.u32 %ct, %ctaid.x;\n\tmov.u32 %nt, %ntid.x;\n\tmov.u32 %tx, %tid.x;\n");
            out.appendCString("\tmad.lo.u32 %gid, %ct, %nt, %tx;\n\tcvt.u64.u32 %tid64, %gid;\n");
            out.appendCString("\tld.param.u64 %lo, [span];\n\tld.param.u64 %end, [span+8];\n\tld.param.u64 %per, [span+16];\n");
            }
        else
            {
            out.appendCString("\tld.param.u64 %gs, [span];\n\tcvta.to.global.u64 %gs, %gs;\n");
            out.appendCString("\tmov.u32 %ct, %ctaid.x;\n\tmov.u32 %nt, %ntid.x;\n\tmov.u32 %tx, %tid.x;\n");
            out.appendCString("\tmad.lo.u32 %gid, %ct, %nt, %tx;\n\tcvt.u64.u32 %tid64, %gid;\n");
            out.appendCString("\tld.global.u64 %lo, [%gs];\n\tld.global.u64 %end, [%gs+8];\n\tld.global.u64 %per, [%gs+16];\n");
            }
        out.appendCString("\tmad.lo.u64 %lo, %tid64, %per, %lo;\n\tadd.s64 %hi, %lo, %per;\n\tmin.s64 %hi, %hi, %end;\n");
        out.appendCString("\tst.local.u64 [%stp+"); out.append(String.withU32(_mObj.offsetAt((u32)1))); out.appendCString("], %lo;\n");
        out.appendCString("\tst.local.u64 [%stp+"); out.append(String.withU32(_mObj.offsetAt((u32)2))); out.appendCString("], %hi;\n");
        out.appendCString("\tsetp.ge.s64 %pz, %lo, %hi;\n\t@%pz bra BODY_END;\n");
        out.append(body);
        if (devred)
            {
            // Every thread reaches every barrier: one past the range holds its
            // reductions' starting values, which leave the result unchanged.
            out.appendCString("BODY_END:\n\tmov.u64 %shb, sh;\n\tmul.wide.u32 %sha, %tx, 8;\n\tadd.u64 %sha, %sha, %shb;\n\tcvt.u64.u32 %cta64, %ct;\n");
            out.append(dtail);
            // The last workgroup to finish folds them all (the reference
            // explains; bug 645).
            out.appendCString("\tmov.u32 %nc, %nctaid.x;\n\tmin.u32 %nv, %nc, 256;\n");
            out.appendCString("\tsetp.ne.u32 %pz, %tx, 0;\n\t@%pz bra FW;\n\tmembar.gl;\n");
            out.appendCString("\tmov.u64 %fa, par_done;\n\tatom.global.add.u32 %k, [%fa], 1;\n\tsub.u32 %j, %nc, 1;\n");
            out.appendCString("\tsetp.eq.u32 %pl, %k, %j;\n\tselp.u32 %k, 1, 0, %pl;\n\tst.shared.u32 [%shb+2048], %k;\n");
            out.appendCString("FW:\n\tbar.sync 0;\n\tld.shared.u32 %k, [%shb+2048];\n\tsetp.eq.u32 %pz, %k, 0;\n\t@%pz bra DONE;\n");
            out.appendCString("\tmembar.gl;\n");
            out.append(ftail);
            out.appendCString("\tsetp.ne.u32 %pz, %tx, 0;\n\t@%pz bra DONE;\n\tmov.u64 %fa, par_done;\n");
            out.appendCString("\tst.global.u32 [%fa], 0;\n");
            }
        else
            {
            out.appendCString("BODY_END:\n\tsetp.ge.s64 %pz, %lo, %end;\n\t@%pz bra DONE;\n");
            out.append(tail);
            }
        out.appendCString("DONE:\n\tret;\n}\n");
        if (byval) return Lower.ptxScalarReplace(out);
        return out;
        }
    }
