// LowerParMetal.xc — a `par` kernel as Metal source (par-blocks.md §6).
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

    class Lower (ParMetal)
    {
    final String* mslSigned(String* t)
        {
        String* b = (String*)0;
        if (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8"))) b = String.withCString("char");
        else if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16"))) b = String.withCString("short");
        else if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))) b = String.withCString("int");
        else if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"))) b = String.withCString("long");
        else return self.mslScalar(t);
        if (_mVecW == (u32)2) b.appendCString("2");
        return b;
        }
    final String* mslUnsigned(String* t)
        {
        String* b = (String*)0;
        if (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8"))) b = String.withCString("uchar");
        else if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16"))) b = String.withCString("ushort");
        else if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))) b = String.withCString("uint");
        else if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"))) b = String.withCString("ulong");
        else return self.mslScalar(t);
        if (_mVecW == (u32)2) b.appendCString("2");
        return b;
        }
    // An operand as an MSL expression.
    final String* mslExpr(IROperand* op, String* want)
        {
        if (op.kind() == (u8)OPK_USE)
            return self.mslName(op.val());
        if (op.kind() == (u8)OPK_IMMI)
            {
            String* t = want != (String*)0 ? self.mslScalar(want) : String.withCString("long");
            if (t == (String*)0) return (String*)0;
            if (want != (String*)0 && want.equals(String.withCString("Bool")))
                return String.withCString(op.imm() != (i64)0 ? "true" : "false");
            String* s = String.withString(t);
            s.appendCString("(");
            s.append(String.withI64(op.imm()));
            s.appendCString("L)");
            return s;
            }
        if (op.kind() == (u8)OPK_IMMF)
            {
            if (want == (String*)0 || !want.equals(String.withCString("F32"))) return (String*)0;
            u64 raw = (u64)0;
            String* h = op.fpHex();
            for (u32 i = (u32)0; i < h.byteLength(); i = i + (u32)1)
                {
                u8 c = h.byteAt(i);
                u64 d = c >= (u8)'a' ? (u64)(c - (u8)'a' + (u8)10) : c >= (u8)'A' ? (u64)(c - (u8)'A' + (u8)10) : (u64)(c - (u8)'0');
                raw = (raw << (u64)4) | d;
                }
            double dv = *(double*)(pointer)&raw;
            float fv = (float)dv;
            u32 bits = *(u32*)(pointer)&fv;
            String* s = String.withCString("as_type<float>(0x");
            for (i32 sh = (i32)28; sh >= (i32)0; sh = sh - (i32)4)
                {
                u32 d = (bits >> (u32)sh) & (u32)15;
                s.appendByte(d < (u32)10 ? (u8)((u32)'0' + d) : (u8)((u32)'a' + d - (u32)10));
                }
            s.appendCString("u)");
            return s;
            }
        return (String*)0;
        }
    final String* mslPtrType(String* t, String* space)
        {
        if (!self.mslIsPtr(t)) return (String*)0;
        String* inner = self.mslScalar(mslPointee(t));
        if (inner == (String*)0) return (String*)0;
        String* s = mslSpaceName(space);
        s.appendCString(" ");
        s.append(inner);
        s.appendCString("*");
        return s;
        }
    // How a pointer's address space is spelt: device, constant, else thread.
    final String* mslSpaceName(String* space)
        {
        if (space != (String*)0 && (space.equals(String.withCString("device")) || space.equals(String.withCString("constant"))))
            return String.withString(space);
        return String.withCString("thread");
        }
    final String* mslDecl(IRValue* v)
        {
        String* t = v.ty();
        if (t.equals(String.withCString("Mem"))) return String.withCString("");
        if (mslIsPtr(t))
            {
            String* pt = mslPtrType(t, (String*)_mSpace.get((Hashable*)self.mslKey(v)));
            if (pt == (String*)0) return String.withCString("");
            String* s = String.withCString("    ");
            s.append(pt); s.appendCString(" "); s.append(self.mslName(v)); s.appendCString(" = 0;\n");
            return s;
            }
        String* n = self.mslScalar(t);
        if (n == (String*)0)
            {
            self.parBecause(String.withCString(t.equals(String.withCString("F64")) ? "it uses double, which Apple GPUs do not have" : "it uses a value its GPU version cannot hold yet"));
            _mFailed = true;
            return String.withCString("");
            }
        String* s = String.withCString("    ");
        s.append(n); s.appendCString(" "); s.append(self.mslName(v)); s.appendCString(" = "); s.append(n); s.appendCString("(0);\n");
        return s;
        }
    // The MSL type a value is declared with ("uint", "device uint*").
    final String* mslDeclType(IRValue* v)
        {
        if (mslIsPtr(v.ty())) return mslPtrType(v.ty(), (String*)_mSpace.get((Hashable*)self.mslKey(v)));
        return self.mslScalar(v.ty());
        }
    // Assign the phis of `target` for the edge from `from`, as a parallel copy.
    final String* mslEdge(IRBlock* from, IRBlock* target, string ind)
        {
        String* s = mslCopies(from, target, ind);
        s.appendCString(ind); s.appendCString("pc = ");
        String* ci = (String*)_mBlk.get((Hashable*)target.name());
        s.append(ci != (String*)0 ? ci : String.withCString("0"));
        s.appendCString("; continue;\n");
        return s;
        }
    // The phi copies for the edge from -> target, in their own braces (so two
    // edges' temporaries never share a scope); "" when target has no phis.
    final String* mslCopies(IRBlock* from, IRBlock* target, string ind)
        {
        String* s = String.withCString("");
        Array* tmps = new Array();
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < target.phis().count(); i = i + (u32)1)
            {
            IRInsn* ph = (IRInsn*)target.phis().get(i);
            if (ph.res() == (IRValue*)0 || ph.res().ty().equals(String.withCString("Mem"))) continue;
            IROperand* inc = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < ph.ops().count(); k = k + (u32)2)
                if (((IROperand*)ph.ops().get(k)).blk() == from)
                    inc = (IROperand*)ph.ops().get(k + (u32)1);
            if (inc == (IROperand*)0) { _mFailed = true; return String.withCString(""); }
            String* e = mslExpr(inc, ph.res().ty());
            String* ty = mslDeclType(ph.res());
            if (e == (String*)0 || ty == (String*)0) { _mFailed = true; return String.withCString(""); }
            s.appendCString(ind); s.append(ty); s.appendCString(" t"); s.append(String.withU32(n)); s.appendCString(" = "); s.append(e); s.appendCString(";\n");
            String* a = String.withCString(ind);
            a.append(self.mslName(ph.res())); a.appendCString(" = t"); a.append(String.withU32(n)); a.appendCString(";\n");
            tmps.add((Object*)a);
            n = n + (u32)1;
            }
        for (u32 i = (u32)0; i < tmps.count(); i = i + (u32)1)
            s.append((String*)tmps.get(i));
        if (n == (u32)0) return String.withCString("");
        String* w = String.withCString(ind);
        w.appendCString("{\n"); w.append(s); w.appendCString(ind); w.appendCString("}\n");
        return w;
        }
    final String* sIndent(String* ind)
        {
        String* s = String.withString(ind);
        s.appendCString("    ");
        return s;
        }
    final bool sJump(u32 u, u32 v, i64 h, i64 e, i64 f, String* ind, String* out)
        {
        out.append(mslCopies((IRBlock*)_sFn.blocks().get(u), (IRBlock*)_sFn.blocks().get(v), ind.cString()));
        if ((i64)v == h) { out.append(ind); out.appendCString("continue;\n"); return true; }
        if ((i64)v == e) { out.append(ind); out.appendCString("break;\n"); return true; }
        if ((i64)v == f) return true;
        if (sIsHeader(v)) return sEmitLoop(v, e, f, h, ind, out);
        if (((Number*)_sFwd.get(v)).asU32() != (u32)1) return false;
        return sEmitBlock(v, h, e, f, ind, out);
        }
    final bool sEmitLoop(u32 x, i64 oe, i64 of, i64 oh, String* ind, String* out)
        {
        if (((Number*)_sFwd.get(x)).asU32() != (u32)1) return false;
        u32 ex = (u32)((Number*)_sExit.get((Hashable*)self.sKey(x))).asI64();
        if (oh >= (i64)0 && !self.sInLoop(oh, ex) && (i64)ex != oe && (i64)ex != of) return false;
        out.append(ind); out.appendCString("while (true) {\n");
        if (!sEmitBlock(x, (i64)x, (i64)ex, (i64)-1, sIndent(ind), out)) return false;
        out.append(ind); out.appendCString("}\n");
        if ((i64)ex == of) return true;
        if ((i64)ex == oh) { out.append(ind); out.appendCString("continue;\n"); return true; }
        if ((i64)ex == oe) { out.append(ind); out.appendCString("break;\n"); return true; }
        if (sIsHeader(ex)) return false;
        return sEmitBlock(ex, oh, oe, of, ind, out);
        }
    final bool sEmitBlock(u32 x, i64 h, i64 e, i64 f, String* ind, String* out)
        {
        IRBlock* b = (IRBlock*)_sFn.blocks().get(x);
        for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
            {
            String* st = mslStatement((IRInsn*)b.insns().get(i));
            if (st == (String*)0) { self.parBecause(parWhyFor((IRInsn*)b.insns().get(i), false)); return false; }
            if (st.byteLength() > (u32)0) { out.append(ind); out.append(st); out.appendCString("\n"); }
            }
        IRInsn* t = b.term();
        if (t.op().equals(String.withCString("Return")))
            {
            if (_mHelper)
                {
                IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                String* rvt = rv != (IROperand*)0 ? self.mslTypeOf(rv) : (String*)0;
                if (rvt != (String*)0 && !rvt.equals(String.withCString("Mem")))
                    {
                    String* ex = mslExpr(rv, rvt);
                    if (ex == (String*)0) return false;
                    out.append(ind); out.appendCString("return "); out.append(ex); out.appendCString(";\n");
                    }
                else
                    { out.append(ind); out.appendCString("return;\n"); }
                return true;
                }
            // The kernel's work ends: leave the do/while(false) around the
            // body, which only works from outside any loop.
            if (h >= (i64)0) return false;
            out.append(ind); out.appendCString("break;\n");
            return true;
            }
        if (t.op().equals(String.withCString("Branch")))
            return sJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)0)).blk()), h, e, f, ind, out);
        // CondBranch: if/else that rejoin at x's immediate post-dominator.
        u32 n = _sFn.blocks().count();
        i64 j = ((Number*)_sIpdom.get(x)).asI64();
        if (j < (i64)0) return false;
        i64 join = j == (i64)n ? f : j;
        if (join >= (i64)0 && join != h && join != e && join != f)
            if (h >= (i64)0 && !self.sInLoop(h, (u32)join)) return false;
        String* c = mslExpr((IROperand*)t.ops().get((u32)0), (String*)0);
        if (c == (String*)0) return false;
        String* in2 = sIndent(ind);
        out.append(ind); out.appendCString("if ("); out.append(c); out.appendCString(") {\n");
        if (!sJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)1)).blk()), h, e, join, in2, out)) return false;
        out.append(ind); out.appendCString("} else {\n");
        if (!sJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)2)).blk()), h, e, join, in2, out)) return false;
        out.append(ind); out.appendCString("}\n");
        if (join < (i64)0 || join == f) return true;
        if (join == h) { out.append(ind); out.appendCString("continue;\n"); return true; }
        if (join == e) { out.append(ind); out.appendCString("break;\n"); return true; }
        if (sIsHeader((u32)join)) return sEmitLoop((u32)join, e, f, h, ind, out);
        return sEmitBlock((u32)join, h, e, f, ind, out);
        }
    // The structured body, or 0 (then the dispatch loop prints it).
    final String* sStructured(IRFunc* f, string ind)
        {
        if (!self.sPlan(f)) return (String*)0;
        String* out = String.withCString("");
        String* in0 = String.withCString(ind);
        bool ok = self.sIsHeader((u32)0) ? sEmitLoop((u32)0, (i64)-1, (i64)-1, (i64)-1, in0, out)
                                    : sEmitBlock((u32)0, (i64)-1, (i64)-1, (i64)-1, in0, out);
        if (!ok || _mFailed) return (String*)0;
        return out;
        }

    final String* mslCat3(String* a, string op, String* b)
        {
        String* s = String.withString(a); s.appendCString(op); s.append(b); return s;
        }
    final String* mslBinary(IRInsn* ip)
        {
        String* t = ip.res().ty();
        String* a = mslExpr((IROperand*)ip.ops().get((u32)0), t);
        String* b = mslExpr((IROperand*)ip.ops().get((u32)1), t);
        if (a == (String*)0 || b == (String*)0) return (String*)0;
        String* n = self.mslScalar(t);
        String* op = ip.op();
        String* sym = (String*)0;
        String* ca = (String*)0;   // the cast both operands take, if any
        bool castLeftOnly = false;
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("FAdd"))) sym = String.withCString(" + ");
        else if (op.equals(String.withCString("Sub")) || op.equals(String.withCString("FSub"))) sym = String.withCString(" - ");
        else if (op.equals(String.withCString("Mul")) || op.equals(String.withCString("FMul"))) sym = String.withCString(" * ");
        else if (op.equals(String.withCString("FDiv"))) sym = String.withCString(" / ");
        else if (op.equals(String.withCString("UDiv"))) { sym = String.withCString(" / "); ca = mslUnsigned(t); }
        else if (op.equals(String.withCString("URem"))) { sym = String.withCString(" % "); ca = mslUnsigned(t); }
        else if (op.equals(String.withCString("SDiv"))) { sym = String.withCString(" / "); ca = mslSigned(t); }
        else if (op.equals(String.withCString("SRem"))) { sym = String.withCString(" % "); ca = mslSigned(t); }
        else if (op.equals(String.withCString("And"))) sym = String.withCString(" & ");
        else if (op.equals(String.withCString("Or"))) sym = String.withCString(" | ");
        else if (op.equals(String.withCString("Xor"))) sym = String.withCString(" ^ ");
        else if (op.equals(String.withCString("Shl"))) sym = String.withCString(" << ");
        else if (op.equals(String.withCString("LShr"))) { sym = String.withCString(" >> "); ca = mslUnsigned(t); castLeftOnly = true; }
        else if (op.equals(String.withCString("AShr"))) { sym = String.withCString(" >> "); ca = mslSigned(t); castLeftOnly = true; }
        if (sym == (String*)0) return (String*)0;
        String* s = String.withString(n);
        s.appendCString("(");
        if (ca != (String*)0) { s.append(ca); s.appendCString("("); s.append(a); s.appendCString(")"); }
        else s.append(a);
        s.append(sym);
        if (ca != (String*)0 && !castLeftOnly) { s.append(ca); s.appendCString("("); s.append(b); s.appendCString(")"); }
        else s.append(b);
        s.appendCString(")");
        return s;
        }
    final String* mslCompare(IRInsn* ip)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
        String* t = self.mslTypeOf(o0) != (String*)0 ? self.mslTypeOf(o0) : self.mslTypeOf(o1);
        if (t == (String*)0) return (String*)0;
        String* a = mslExpr(o0, t);
        String* b = mslExpr(o1, t);
        if (a == (String*)0 || b == (String*)0) return (String*)0;
        String* p = ip.pred();
        String* sym = (String*)0;
        String* cast = (String*)0;
        if (ip.op().equals(String.withCString("FCmp")))
            {
            if (p.equals(String.withCString("OEQ"))) sym = String.withCString(" == ");
            else if (p.equals(String.withCString("ONE"))) sym = String.withCString(" != ");
            else if (p.equals(String.withCString("OLT"))) sym = String.withCString(" < ");
            else if (p.equals(String.withCString("OGT"))) sym = String.withCString(" > ");
            else if (p.equals(String.withCString("OLE"))) sym = String.withCString(" <= ");
            else if (p.equals(String.withCString("OGE"))) sym = String.withCString(" >= ");
            }
        else
            {
            if (p.equals(String.withCString("EQ"))) sym = String.withCString(" == ");
            else if (p.equals(String.withCString("NE"))) sym = String.withCString(" != ");
            else if (p.equals(String.withCString("SLT"))) { sym = String.withCString(" < "); cast = mslSigned(t); }
            else if (p.equals(String.withCString("SGT"))) { sym = String.withCString(" > "); cast = mslSigned(t); }
            else if (p.equals(String.withCString("SLE"))) { sym = String.withCString(" <= "); cast = mslSigned(t); }
            else if (p.equals(String.withCString("SGE"))) { sym = String.withCString(" >= "); cast = mslSigned(t); }
            else if (p.equals(String.withCString("ULT"))) { sym = String.withCString(" < "); cast = mslUnsigned(t); }
            else if (p.equals(String.withCString("UGT"))) { sym = String.withCString(" > "); cast = mslUnsigned(t); }
            else if (p.equals(String.withCString("ULE"))) { sym = String.withCString(" <= "); cast = mslUnsigned(t); }
            else if (p.equals(String.withCString("UGE"))) { sym = String.withCString(" >= "); cast = mslUnsigned(t); }
            }
        if (sym == (String*)0) return (String*)0;
        String* s = String.withCString("(");
        if (cast != (String*)0 && !t.equals(String.withCString("Bool")))
            {
            s.append(cast); s.appendCString("("); s.append(a); s.appendCString(")"); s.append(sym);
            s.append(cast); s.appendCString("("); s.append(b); s.appendCString(")");
            }
        else
            { s.append(a); s.append(sym); s.append(b); }
        s.appendCString(")");
        return s;
        }
    // The maths intrinsics, by the callee's name, as precise Metal functions (§7).
    final String* mslIntrinsic(String* callee)
        {
        String* m = callee;
        if (m.hasPrefix(String.withCString("Math$"))) m = m.substringBytes((u32)5, m.byteLength() - (u32)5);
        String* cut = String.withCString("");
        for (u32 i = (u32)0; i < m.byteLength(); i = i + (u32)1)
            {
            if (m.byteAt(i) == (u8)'_' && i + (u32)1 < m.byteLength() && m.byteAt(i + (u32)1) == (u8)'_') break;
            cut.appendByte(m.byteAt(i));
            }
        m = cut;
        if (m.hasPrefix(String.withCString("_xm_"))) m = m.substringBytes((u32)4, m.byteLength() - (u32)4);
        if (m.hasSuffix(String.withCString("f")) && m.byteLength() > (u32)3) m = m.substringBytes((u32)0, m.byteLength() - (u32)1);
        if (m.equals(String.withCString("sqrt"))) return String.withCString("precise::sqrt");
        if (m.equals(String.withCString("sin"))) return String.withCString("precise::sin");
        if (m.equals(String.withCString("cos"))) return String.withCString("precise::cos");
        if (m.equals(String.withCString("exp"))) return String.withCString("precise::exp");
        if (m.equals(String.withCString("ln")) || m.equals(String.withCString("log"))) return String.withCString("precise::log");
        if (m.equals(String.withCString("pow"))) return String.withCString("precise::pow");
        if (m.equals(String.withCString("floor"))) return String.withCString("floor");
        if (m.equals(String.withCString("fma"))) return String.withCString("fma");
        if (m.equals(String.withCString("abs")) || m.equals(String.withCString("fabs"))) return String.withCString("abs");
        if (m.equals(String.withCString("min"))) return String.withCString("min");
        if (m.equals(String.withCString("max"))) return String.withCString("max");
        return (String*)0;
        }
    final String* mslAssign(IRValue* r, String* e)
        {
        if (e == (String*)0) return (String*)0;
        String* s = self.mslName(r); s.appendCString(" = "); s.append(e); s.appendCString(";"); return s;
        }
    final String* mslStatement(IRInsn* ip)
        {
        String* op = ip.op();
        IRValue* r = ip.res();
        String* rt = r != (IRValue*)0 ? r.ty() : (String*)0;
        IROperand* o0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
        if (op.equals(String.withCString("Const")))
            return mslAssign(r, mslExpr(o0, rt));
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")) || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv")))
            return mslAssign(r, mslBinary(ip));
        if (op.equals(String.withCString("Not")))
            {
            String* a = mslExpr(o0, rt);
            if (a == (String*)0) return (String*)0;
            if (rt.equals(String.withCString("Bool"))) return mslAssign(r, mslCat3(String.withCString(""), "!", a));
            String* e = String.withString(self.mslScalar(rt)); e.appendCString("(~"); e.append(a); e.appendCString(")");
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("Neg")) || op.equals(String.withCString("FNeg")))
            {
            String* a = mslExpr(o0, rt);
            if (a == (String*)0) return (String*)0;
            String* e = String.withString(self.mslScalar(rt)); e.appendCString("(-"); e.append(a); e.appendCString(")");
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("FSqrt")))
            {
            String* a = mslExpr(o0, rt);
            if (a == (String*)0) return (String*)0;
            String* e = String.withCString(_mFast ? "fast::sqrt(" : "precise::sqrt("); e.append(a); e.appendCString(")");
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")))
            return mslAssign(r, mslCompare(ip));
        if (op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")) || op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")) || op.equals(String.withCString("Copy")))
            {
            String* st = self.mslTypeOf(o0) != (String*)0 ? self.mslTypeOf(o0) : rt;
            String* a = mslExpr(o0, st);
            if (a == (String*)0 || self.mslScalar(rt) == (String*)0) return (String*)0;
            // Widen through the source's own signedness, as the CPU does.
            if (op.equals(String.withCString("ZExt"))) { String* w = String.withString(mslUnsigned(st)); w.appendCString("("); w.append(a); w.appendCString(")"); a = w; }
            else if (op.equals(String.withCString("SExt"))) { String* w = String.withString(mslSigned(st)); w.appendCString("("); w.append(a); w.appendCString(")"); a = w; }
            String* e = String.withString(self.mslScalar(rt)); e.appendCString("("); e.append(a); e.appendCString(")");
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("Select")))
            {
            String* c = mslExpr(o0, (String*)0);
            String* a = mslExpr((IROperand*)ip.ops().get((u32)1), rt);
            String* b = mslExpr((IROperand*)ip.ops().get((u32)2), rt);
            if (c == (String*)0 || a == (String*)0 || b == (String*)0) return (String*)0;
            String* e = String.withString(c); e.appendCString(" ? "); e.append(a); e.appendCString(" : "); e.append(b);
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("FieldAddr")))
            {
            i64 k = self.mslSelfField(ip);
            // The slot of a captured array: only ever loaded, and that load is
            // the buffer itself, so the slot's address needs no code.
            if (k >= (i64)0 && self.mslIsPtr(_mObj.typeAt((u32)k)))
                return String.withCString("");
            String* sp = (String*)_mSpace.get((Hashable*)self.mslKey(r));
            String* pt = mslPtrType(rt, sp);
            if (pt == (String*)0) return (String*)0;
            if (k >= (i64)0)
                {
                String* e = String.withCString("("); e.append(pt); e.appendCString(")(st + "); e.append(String.withU32(_mObj.offsetAt((u32)k))); e.appendCString(")");
                return mslAssign(r, e);
                }
            // A field of a struct element in a buffer: by its byte offset.
            IRLayout* l = self.mslLayoutOf(mslPointee(self.mslTypeOf(o0)));
            IROperand* fo = (IROperand*)ip.ops().get((u32)1);
            if (l == (IRLayout*)0 || fo.kind() != (u8)OPK_IMMI || fo.imm() < (i64)0 || fo.imm() >= (i64)l.fieldCount()) return (String*)0;
            String* e = String.withCString("("); e.append(pt); e.appendCString(")((");
            e.append(mslSpaceName(sp));
            e.appendCString(" uchar*)"); e.append(self.mslName(o0.val())); e.appendCString(" + "); e.append(String.withU32(l.offsetAt((u32)fo.imm()))); e.appendCString(")");
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("ElementAddr")))
            {
            String* idx = mslExpr((IROperand*)ip.ops().get((u32)1), (String*)0);
            if (idx == (String*)0) return (String*)0;
            return mslAssign(r, mslCat3(mslName(o0.val()), " + ", idx));
            }
        if (op.equals(String.withCString("Bitcast")))
            {
            String* pt = self.mslIsPtr(rt) ? mslPtrType(rt, (String*)_mSpace.get((Hashable*)self.mslKey(r))) : self.mslScalar(rt);
            if (pt == (String*)0) return (String*)0;
            String* e = String.withCString("as_type<"); e.append(pt); e.appendCString(">("); e.append(mslExpr(o0, (String*)0)); e.appendCString(")");
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("Load")))
            {
            String* buf = (String*)_mBufOf.get((Hashable*)self.mslKey(r));
            if (buf != (String*)0) return mslAssign(r, mslCat3(String.withCString("buf_"), "", buf));
            if (mslScalar(rt) == (String*)0) return (String*)0;
            if (parSinitFlag(o0)) return mslAssign(r, mslCat3(mslScalar(rt), "", String.withCString("(2)")));
            return mslAssign(r, mslCat3(String.withCString("*"), "", self.mslName(o0.val())));
            }
        if (op.equals(String.withCString("Store")))
            {
            if (o0.kind() != (u8)OPK_USE) return (String*)0;
            String* v = mslExpr((IROperand*)ip.ops().get((u32)1), self.mslPointee(mslTypeOf(o0)));
            if (v == (String*)0) return (String*)0;
            String* s = String.withCString("*"); s.append(self.mslName(o0.val())); s.appendCString(" = "); s.append(v); s.appendCString(";");
            return s;
            }
        if (op.equals(String.withCString("Call")))
            {
            String* callee = o0.name();
            // The static-init machinery: the host has run it.
            if (callee.equals(String.withCString("_xtc_sinit_run")) || callee.hasSuffix(String.withCString("$init")))
                return String.withCString("");
            String* fn = mslIntrinsic(callee);
            // The speed goal: Metal's fast versions, in place of the precise ones.
            if (_mFast && fn != (String*)0 && fn.hasPrefix(String.withCString("precise::")))
                fn = self.ptxCat("fast::", fn.substringFromByte((u32)9));
            bool isVoid = rt == (String*)0 || rt.equals(String.withCString("Mem"));
            if (fn == (String*)0)
                {
                // A function of the program (the subset check has walked it):
                // printed once, before the kernel.
                IRFunc* target = (IRFunc*)0;
                for (u32 q = (u32)0; q < _m.funcs().count(); q = q + (u32)1)
                    if (((IRFunc*)_m.funcs().get(q)).name().equals(callee))
                        target = (IRFunc*)_m.funcs().get(q);
                if (target == (IRFunc*)0) return (String*)0;
                fn = String.withCString("h_");
                for (u32 q = (u32)0; q < callee.byteLength(); q = q + (u32)1)
                    fn.appendByte(callee.byteAt(q) == (u8)'$' ? (u8)'_' : callee.byteAt(q));
                if (_mHelperNames.get((Hashable*)callee) == (Object*)0)
                    {
                    _mHelperNames.set((Hashable*)callee, (Object*)callee);
                    String* text = mslHelper(target, fn);
                    if (text == (String*)0) { self.parBecause(parCallFailed(callee, _mHelperWhy)); return (String*)0; }
                    _mHelperText.add((Object*)text);
                    }
                }
            else if (isVoid)
                return (String*)0;
            String* e = String.withString(fn); e.appendCString("(");
            bool first = true;
            for (u32 k = (u32)1; k < ip.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)ip.ops().get(k);
                String* ot = self.mslTypeOf(o);
                if (ot != (String*)0 && ot.equals(String.withCString("Mem"))) continue;
                String* a = mslExpr(o, ot != (String*)0 ? ot : rt);
                if (a == (String*)0) return (String*)0;
                if (!first) e.appendCString(", ");
                e.append(a);
                first = false;
                }
            e.appendCString(")");
            if (isVoid) { e.appendCString(";"); return e; }
            return mslAssign(r, e);
            }
        if (op.equals(String.withCString("AddrOf")))
            {
            if (_mSinit.get((Hashable*)self.mslKey(r)) != (Object*)0) return String.withCString("");
            String* lk = (String*)_mLocalOf.get((Hashable*)self.mslKey(r));
            if (lk != (String*)0)
                return mslAssign(r, mslCat3(String.withCString("loc_"), "", lk));
            String* g = (String*)_mGlobalOf.get((Hashable*)self.mslKey(r));
            if (g == (String*)0) return (String*)0;
            u32 gi = (u32)0;
            for (u32 q = (u32)0; q < _mGlobals.count(); q = q + (u32)1)
                if (((String*)_mGlobals.get(q)).equals(g)) gi = q;
            return mslAssign(r, mslCat3(String.withCString("glob_"), "", String.withU32(gi)));
            }
        if (op.equals(String.withCString("DbgValue")))
            return String.withCString("");
        return (String*)0;
        }
    // The declarations and the dispatch-loop body of f (a kernel or a
    // helper): true when every instruction printed.
    final bool mslBody(IRFunc* f, String* decls, String* body)
        {
        u32 ord = (u32)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            _mBlk.set((Hashable*)bb.name(), (Object*)String.withU32(b));
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(String.withCString("Mem")))
                    { _mOrd.set((Hashable*)self.mslKey(ip.res()), (Object*)String.withU32(ord)); ord = ord + (u32)1; }
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(String.withCString("Mem")))
                    { _mOrd.set((Hashable*)self.mslKey(ip.res()), (Object*)String.withU32(ord)); ord = ord + (u32)1; }
                }
            }
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ph = (IRInsn*)bb.phis().get(i);
                if (ph.res() == (IRValue*)0 || ph.res().ty().equals(String.withCString("Mem"))) continue;
                // A phi of pointers takes its incomings' space.
                if (mslIsPtr(ph.res().ty()))
                    for (u32 k = (u32)1; k < ph.ops().count(); k = k + (u32)2)
                        {
                        String* sp = self.mslSpaceOfOp((IROperand*)ph.ops().get(k));
                        if (sp != (String*)0) _mSpace.set((Hashable*)self.mslKey(ph.res()), (Object*)sp);
                        }
                decls.append(mslDecl(ph.res()));
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(String.withCString("Mem")))
                    decls.append(mslDecl(ip.res()));
                }
            }
        // The work item's own arrays, in the order first met.
        for (u32 q = (u32)0; q < _mLocalDecls.count(); q = q + (u32)1)
            decls.append((String*)_mLocalDecls.get(q));
        if (_mFailed) return false;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            body.appendCString("        case "); body.append(String.withU32(b)); body.appendCString(": {\n");
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                String* st = mslStatement((IRInsn*)bb.insns().get(i));
                if (st == (String*)0) { self.parBecause(parWhyFor((IRInsn*)bb.insns().get(i), false)); return false; }
                if (st.byteLength() > (u32)0) { body.appendCString("            "); body.append(st); body.appendCString("\n"); }
                }
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0) return false;
            if (t.op().equals(String.withCString("Branch")))
                body.append(mslEdge(bb, ((IROperand*)t.ops().get((u32)0)).blk(), "            "));
            else if (t.op().equals(String.withCString("CondBranch")))
                {
                String* c = mslExpr((IROperand*)t.ops().get((u32)0), (String*)0);
                if (c == (String*)0) return false;
                body.appendCString("            if ("); body.append(c); body.appendCString(") {\n");
                body.append(mslEdge(bb, ((IROperand*)t.ops().get((u32)1)).blk(), "                "));
                body.appendCString("            }\n");
                body.append(mslEdge(bb, ((IROperand*)t.ops().get((u32)2)).blk(), "            "));
                }
            else if (t.op().equals(String.withCString("Return")))
                {
                // A helper returns its value; the kernel just stops.
                IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                String* rvt = rv != (IROperand*)0 ? self.mslTypeOf(rv) : (String*)0;
                if (_mHelper && rvt != (String*)0 && !rvt.equals(String.withCString("Mem")))
                    {
                    String* e = mslExpr(rv, rvt);
                    if (e == (String*)0) return false;
                    body.appendCString("            return "); body.append(e); body.appendCString(";\n");
                    }
                else if (_mHelper)
                    body.appendCString("            return;\n");
                else
                    body.appendCString("            pc = 0xffffffffu; continue;\n");
                }
            else
                return false;
            body.appendCString("        }\n");
            }
        return !_mFailed;
        }

    // A helper the kernel calls: `static <ret> <name>(<params>)`, its body the
    // same dispatch loop. Scalars only, in and out.
    final String* mslHelper(IRFunc* g, String* name)
        {
        // The caller's state, back afterwards.
        Map* sDef = _mDef; Map* sSpace = _mSpace; Map* sBufOf = _mBufOf; Map* sOrd = _mOrd;
        Map* sBlk = _mBlk; Map* sBufs = _mBufs; Map* sReds = _mReds; IRLayout* sObj = _mObj;
        bool sFailed = _mFailed; bool sHelper = _mHelper; Map* sParams = _mParams; Map* sSinit = _mSinit; String* sWhy = _mWhy;
        Map* sLocalOf = _mLocalOf; Map* sLocalIndex = _mLocalIndex; Array* sLocalDecls = _mLocalDecls; Array* sLocalBytes = _mLocalBytes; Array* sLocalElem = _mLocalElem;
        Array* sSucc = _sSucc; Array* sRpo = _sRpo; Array* sFwd = _sFwd; Map* sLoop = _sLoop; Map* sExit = _sExit;
        Array* sIpdom = _sIpdom; IRFunc* sFn = _sFn;
        String* out = mslHelperText(g, name);
        _mHelperWhy = _mWhy;
        _mDef = sDef; _mSpace = sSpace; _mBufOf = sBufOf; _mOrd = sOrd;
        _mBlk = sBlk; _mBufs = sBufs; _mReds = sReds; _mObj = sObj;
        _mFailed = sFailed; _mHelper = sHelper; _mParams = sParams; _mSinit = sSinit; _mWhy = sWhy;
        _mLocalOf = sLocalOf; _mLocalIndex = sLocalIndex; _mLocalDecls = sLocalDecls; _mLocalBytes = sLocalBytes; _mLocalElem = sLocalElem;
        _sSucc = sSucc; _sRpo = sRpo; _sFwd = sFwd; _sLoop = sLoop; _sExit = sExit; _sIpdom = sIpdom; _sFn = sFn;
        return out;
        }
    final String* mslHelperText(IRFunc* g, String* name)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = true;
        _mParams = new Map();
        if (!self.mslAnalyse(g)) return (String*)0;
        String* params = String.withCString("");
        for (u32 k = (u32)0; k + (u32)1 < g.params().count(); k = k + (u32)1)
            {
            IRValue* pv = (IRValue*)g.params().get(k);
            String* t = self.mslScalar(pv.ty());
            if (t == (String*)0) return (String*)0;
            _mParams.set((Hashable*)self.mslKey(pv), (Object*)String.withU32(k));
            if (k > (u32)0) params.appendCString(", ");
            params.append(t); params.appendCString(" p"); params.append(String.withU32(k));
            }
        String* rt = g.ret();
        String* ret = (rt == (String*)0 || rt.equals(String.withCString("Void")) || rt.equals(String.withCString("Mem")))
                          ? String.withCString("void") : self.mslScalar(rt);
        if (ret == (String*)0) return (String*)0;
        String* decls = String.withCString("");
        String* body = String.withCString("");
        if (!mslBody(g, decls, body)) return (String*)0;
        String* out = String.withCString("static ");
        out.append(ret); out.appendCString(" "); out.append(name); out.appendCString("("); out.append(params); out.appendCString(")\n{\n");
        out.append(decls);
        String* structured = sStructured(g, "    ");
        if (structured != (String*)0)
            out.append(structured);
        else
            {
            out.appendCString("    uint pc = 0;\n    while (pc != 0xffffffffu) {\n        switch (pc) {\n");
            out.append(body);
            out.appendCString("        default: pc = 0xffffffffu; continue;\n        }\n    }\n");
            }
        if (!ret.equals(String.withCString("void")))
            { out.appendCString("    return "); out.append(ret); out.appendCString("(0);\n"); }
        out.appendCString("}\n");
        return out;
        }
    }
