// LowerParWgsl.xc — a `par` kernel as WGSL, for WebGPU (the reference's XTIRParWGSL.m).
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
#import <LowerParSpirv>

    class Lower (ParWgsl)
    {

    final string wgKExit(void) { return "4294967295u"; }

    final bool wgWide(String* t) { return ptxIs(t, "I64") || ptxIs(t, "U64"); }
    final bool wgSigned(String* t) { return ptxIs(t, "I8") || ptxIs(t, "I16") || ptxIs(t, "I32") || ptxIs(t, "I64"); }
    final bool wgIsFloat(String* t) { return ptxIs(t, "F32") || ptxIs(t, "F64"); }
    final String* wgType(String* t)
        {
        if (t == (String*)0) return (String*)0;
        if (ptxIs(t, "I8") || self.ptxIs(t, "U8") || self.ptxIs(t, "I16") || self.ptxIs(t, "U16") || self.ptxIs(t, "I32") || self.ptxIs(t, "U32"))
            return self.spvS("u32");
        if (wgWide(t)) return self.spvS("vec2<u32>");
        if (ptxIs(t, "F32")) return self.spvS("f32");
        if (ptxIs(t, "Bool")) return self.spvS("bool");
        return (String*)0;
        }
    final bool wgSameType(String* a, String* b)
        {
        String* x = wgType(a);
        String* y = wgType(b);
        return x != (String*)0 && y != (String*)0 && x.equals(y);
        }

    final void wgLine(String* s)
        {
        _wf.code.appendCString("      ");
        _wf.code.append(s);
        _wf.code.appendCString("\n");
        }
    final String* wgLet(String* expr)
        {
        String* n = self.spvS("t");
        n.append(String.withU32(_wf.temps));
        _wf.temps = _wf.temps + (u32)1;
        String* l = self.spvS("let ");
        l.append(n); l.appendCString(" = "); l.append(expr); l.appendCString(";");
        wgLine(l);
        return n;
        }
    final void wgSet(IRInsn* ip, String* expr)
        {
        String* l = String.withString((String*)_wf.varOf.get((Hashable*)self.mslKey(ip.res())));
        l.appendCString(" = "); l.append(expr); l.appendCString(";");
        wgLine(l);
        }
    final String* wgCanon(String* v, String* t)
        {
        u32 bits = self.spvNarrowBits(t);
        if (bits == (u32)0) return v;
        if (ptxIs(t, "U8") || self.ptxIs(t, "U16"))
            return String.withFormat("((%s) & 0x%xu)", v.cString(), ((u32)1 << bits) - (u32)1);
        return String.withFormat("u32(i32((%s) << %uu) >> %uu)", v.cString(), (u32)32 - bits, (u32)32 - bits);
        }
    final String* wgU32Lit(u32 v) { return String.withFormat("%uu", v); }

    final String* wgValue(IROperand* op, String* want)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            if (op.val() == (IRValue*)0) return (String*)0;
            return (String*)_wf.varOf.get((Hashable*)self.mslKey(op.val()));
            }
        if (op.kind() == (u8)OPK_IMMI)
            {
            if (want == (String*)0) return (String*)0;
            if (ptxIs(want, "Bool")) return self.spvS(op.imm() != (i64)0 ? "true" : "false");
            if (wgIsFloat(want) || wgType(want) == (String*)0) return (String*)0;
            i64 iv = op.imm();
            if (wgWide(want))
                return String.withFormat("vec2<u32>(%uu, %uu)", (u32)(u64)iv, (u32)((u64)iv >> (u64)32));
            u32 nb = self.spvNarrowBits(want);
            if (nb != (u32)0)
                {
                u64 mask = ((u64)1 << (u64)nb) - (u64)1;
                iv = (i64)((u64)iv & mask);
                if (wgSigned(want) && ((iv >> (i64)(nb - (u32)1)) & (i64)1) != (i64)0)
                    iv = iv - (i64)((u64)1 << (u64)nb);
                }
            return wgU32Lit((u32)iv);
            }
        if (op.kind() == (u8)OPK_IMMF)
            {
            if (!self.ptxIs(want, "F32")) return (String*)0;
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
            return String.withFormat("bitcast<f32>(%uu)", bits);
            }
        return (String*)0;
        }

    final String* wgFmt2(string f, String* a, String* b) { return String.withFormat(f, a.cString(), b.cString()); }

    final bool wgBinary(IRInsn* ip)
        {
        String* t = ip.res().ty();
        String* o = ip.op();
        IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
        String* a = wgValue((IROperand*)ip.ops().get((u32)0), t);
        String* b = wgValue(o1, t);
        if (a == (String*)0 || b == (String*)0 || wgType(t) == (String*)0)
            return false;
        if (wgWide(t))
            {
            // A shift's count may be 32-bit: its low word either way.
            String* ct = o1.kind() == (u8)OPK_USE ? self.mslTypeOf(o1) : t;
            String* cnt = wgWide(ct) ? String.withFormat("%s.x", b.cString()) : b;
            if (!wgWide(ct) && o1.kind() == (u8)OPK_USE)
                b = wgValue(o1, ct);
            String* e = (String*)0;
            if (o.equals(self.spvS("Add"))) e = wgFmt2("xc_add64(%s, %s)", a, b);
            else if (o.equals(self.spvS("Sub"))) e = wgFmt2("xc_sub64(%s, %s)", a, b);
            else if (o.equals(self.spvS("Mul"))) e = wgFmt2("xc_mul64(%s, %s)", a, b);
            else if (o.equals(self.spvS("And"))) e = wgFmt2("(%s & %s)", a, b);
            else if (o.equals(self.spvS("Or"))) e = wgFmt2("(%s | %s)", a, b);
            else if (o.equals(self.spvS("Xor"))) e = wgFmt2("(%s ^ %s)", a, b);
            else if (o.equals(self.spvS("Shl"))) e = wgFmt2("xc_shl64(%s, %s)", a, cnt);
            else if (o.equals(self.spvS("LShr"))) e = wgFmt2("xc_lshr64(%s, %s)", a, cnt);
            else if (o.equals(self.spvS("AShr"))) e = wgFmt2("xc_ashr64(%s, %s)", a, cnt);
            else if (o.equals(self.spvS("UDiv"))) e = wgFmt2("xc_udiv64(%s, %s)", a, b);
            else if (o.equals(self.spvS("URem"))) e = wgFmt2("xc_urem64(%s, %s)", a, b);
            else if (o.equals(self.spvS("SDiv"))) e = wgFmt2("xc_sdiv64(%s, %s)", a, b);
            else if (o.equals(self.spvS("SRem"))) e = wgFmt2("xc_srem64(%s, %s)", a, b);
            else
                return false;
            wgSet(ip, e);
            return true;
            }
        if (ptxIs(t, "F32"))
            {
            string op = (string)0;
            if (o.equals(self.spvS("FAdd"))) op = "+";
            else if (o.equals(self.spvS("FSub"))) op = "-";
            else if (o.equals(self.spvS("FMul"))) op = "*";
            else if (o.equals(self.spvS("FDiv")))
                {
                if (!_mFast)
                    {
                    // Correctly rounded in integer arithmetic (the reference explains).
                    String* h = wgHelperName(spvS("xcFdivRn"));
                    if (h == (String*)0)
                        {
                        self.parBecause(spvS("it divides floats, which a WebGPU device does not round exactly, and the block's goal is accuracy"));
                        return false;
                        }
                    wgSet(ip, String.withFormat("%s(%s, %s)", h.cString(), a.cString(), b.cString()));
                    return true;
                    }
                op = "/";
                }
            else return false;
            wgSet(ip, String.withFormat("(%s %s %s)", a.cString(), op, b.cString()));
            return true;
            }
        if (ptxIs(t, "Bool"))
            {
            string op = (string)0;
            if (o.equals(self.spvS("And"))) op = "&";
            else if (o.equals(self.spvS("Or"))) op = "|";
            else if (o.equals(self.spvS("Xor"))) op = "!=";
            else return false;
            wgSet(ip, String.withFormat("(%s %s %s)", a.cString(), op, b.cString()));
            return true;
            }
        // A narrow operand is held in its own type's form; an operation of
        // the other signedness rereads its bits that way first.
        u32 nb = self.spvNarrowBits(t);
        bool wantsUnsigned = o.equals(self.spvS("UDiv")) || o.equals(self.spvS("URem")) || o.equals(self.spvS("LShr"));
        bool wantsSigned = o.equals(self.spvS("SDiv")) || o.equals(self.spvS("SRem")) || o.equals(self.spvS("AShr"));
        if (nb != (u32)0)
            {
            String* as = (String*)0;
            if (wantsUnsigned && wgSigned(t))
                as = self.spvS(nb == (u32)8 ? "U8" : "U16");
            else if (wantsSigned && !wgSigned(t))
                as = self.spvS(nb == (u32)8 ? "I8" : "I16");
            if (as != (String*)0)
                {
                a = wgCanon(a, as);
                if (!o.equals(self.spvS("LShr")) && !o.equals(self.spvS("AShr")))
                    b = wgCanon(b, as);
                }
            }
        String* e = (String*)0;
        if (o.equals(self.spvS("Add"))) e = wgFmt2("(%s + %s)", a, b);
        else if (o.equals(self.spvS("Sub"))) e = wgFmt2("(%s - %s)", a, b);
        else if (o.equals(self.spvS("Mul"))) e = wgFmt2("(%s * %s)", a, b);
        else if (o.equals(self.spvS("UDiv"))) e = wgFmt2("(%s / %s)", a, b);
        else if (o.equals(self.spvS("URem"))) e = wgFmt2("(%s %% %s)", a, b);
        else if (o.equals(self.spvS("SDiv"))) e = wgFmt2("u32(i32(%s) / i32(%s))", a, b);
        else if (o.equals(self.spvS("SRem"))) e = wgFmt2("u32(i32(%s) %% i32(%s))", a, b);
        else if (o.equals(self.spvS("And"))) e = wgFmt2("(%s & %s)", a, b);
        else if (o.equals(self.spvS("Or"))) e = wgFmt2("(%s | %s)", a, b);
        else if (o.equals(self.spvS("Xor"))) e = wgFmt2("(%s ^ %s)", a, b);
        else if (o.equals(self.spvS("Shl"))) e = wgFmt2("(%s << (%s & 31u))", a, b);
        else if (o.equals(self.spvS("LShr"))) e = wgFmt2("(%s >> (%s & 31u))", a, b);
        else if (o.equals(self.spvS("AShr"))) e = wgFmt2("u32(i32(%s) >> (%s & 31u))", a, b);
        else return false;
        wgSet(ip, wgCanon(e, t));
        return true;
        }

    final bool wgCompare(IRInsn* ip)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
        String* t = self.mslTypeOf(o0) != (String*)0 ? self.mslTypeOf(o0) : self.mslTypeOf(o1);
        if (t == (String*)0) return false;
        String* a = wgValue(o0, t);
        String* b = wgValue(o1, t);
        if (a == (String*)0 || b == (String*)0) return false;
        String* p = ip.pred();
        String* e = (String*)0;
        if (ip.op().equals(self.spvS("FCmp")))
            {
            string op = (string)0;
            if (p.equals(self.spvS("OEQ"))) op = "==";
            else if (p.equals(self.spvS("ONE"))) op = "!=";
            else if (p.equals(self.spvS("OLT"))) op = "<";
            else if (p.equals(self.spvS("OGT"))) op = ">";
            else if (p.equals(self.spvS("OLE"))) op = "<=";
            else if (p.equals(self.spvS("OGE"))) op = ">=";
            if (op == (string)0 || !self.ptxIs(t, "F32")) return false;
            e = String.withFormat("(%s %s %s)", a.cString(), op, b.cString());
            }
        else if (wgWide(t))
            {
            if (p.equals(self.spvS("EQ"))) e = wgFmt2("all(%s == %s)", a, b);
            else if (p.equals(self.spvS("NE"))) e = wgFmt2("any(%s != %s)", a, b);
            else if (p.equals(self.spvS("SLT"))) e = wgFmt2("xc_slt64(%s, %s)", a, b);
            else if (p.equals(self.spvS("SGT"))) e = wgFmt2("xc_slt64(%s, %s)", b, a);
            else if (p.equals(self.spvS("SLE"))) e = wgFmt2("!xc_slt64(%s, %s)", b, a);
            else if (p.equals(self.spvS("SGE"))) e = wgFmt2("!xc_slt64(%s, %s)", a, b);
            else if (p.equals(self.spvS("ULT"))) e = wgFmt2("xc_ult64(%s, %s)", a, b);
            else if (p.equals(self.spvS("UGT"))) e = wgFmt2("xc_ult64(%s, %s)", b, a);
            else if (p.equals(self.spvS("ULE"))) e = wgFmt2("!xc_ult64(%s, %s)", b, a);
            else if (p.equals(self.spvS("UGE"))) e = wgFmt2("!xc_ult64(%s, %s)", a, b);
            else return false;
            }
        else if (ptxIs(t, "Bool"))
            {
            if (p.equals(self.spvS("EQ"))) e = wgFmt2("(%s == %s)", a, b);
            else if (p.equals(self.spvS("NE"))) e = wgFmt2("(%s != %s)", a, b);
            else return false;
            }
        else
            {
            string op = (string)0;
            bool s = false;
            if (p.equals(self.spvS("EQ"))) op = "==";
            else if (p.equals(self.spvS("NE"))) op = "!=";
            else if (p.equals(self.spvS("SLT"))) { op = "<"; s = true; }
            else if (p.equals(self.spvS("SGT"))) { op = ">"; s = true; }
            else if (p.equals(self.spvS("SLE"))) { op = "<="; s = true; }
            else if (p.equals(self.spvS("SGE"))) { op = ">="; s = true; }
            else if (p.equals(self.spvS("ULT"))) op = "<";
            else if (p.equals(self.spvS("UGT"))) op = ">";
            else if (p.equals(self.spvS("ULE"))) op = "<=";
            else if (p.equals(self.spvS("UGE"))) op = ">=";
            else return false;
            e = s ? String.withFormat("(i32(%s) %s i32(%s))", a.cString(), op, b.cString())
                  : String.withFormat("(%s %s %s)", a.cString(), op, b.cString());
            }
        wgSet(ip, e);
        return true;
        }

    final bool wgConvert(IRInsn* ip)
        {
        String* rt = ip.res().ty();
        String* o = ip.op();
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
        String* a = wgValue(o0, st);
        if (a == (String*)0 || wgType(rt) == (String*)0 || wgType(st) == (String*)0)
            return false;
        String* v = (String*)0;
        if (ptxIs(st, "Bool") && !self.ptxIs(rt, "Bool"))
            {
            if (wgIsFloat(rt)) return false;
            v = wgWide(rt) ? String.withFormat("vec2<u32>(select(0u, 1u, %s), 0u)", a.cString())
                           : String.withFormat("select(0u, 1u, %s)", a.cString());
            }
        else if (ptxIs(rt, "Bool"))
            {
            if (ptxIs(st, "Bool")) v = a;
            else if (wgIsFloat(st)) return false;
            else v = wgWide(st) ? String.withFormat("any(%s != vec2<u32>(0u, 0u))", a.cString())
                                : String.withFormat("(%s != 0u)", a.cString());
            }
        else if (wgIsFloat(st) || wgIsFloat(rt))
            {
            // 64-bit integers and floats convert through the helpers (the
            // reference explains).
            if (wgWide(st) && wgIsFloat(rt))
                {
                bool sg = o.equals(self.spvS("SIToFp")) || (o.equals(self.spvS("Copy")) && wgSigned(st));
                wgSet(ip, String.withFormat(sg ? "xc_s64tof32(%s)" : "xc_u64tof32(%s)", a.cString()));
                return true;
                }
            if (wgIsFloat(st) && wgWide(rt))
                {
                bool sg = o.equals(self.spvS("FpToSI")) || (o.equals(self.spvS("Copy")) && wgSigned(rt));
                wgSet(ip, String.withFormat(sg ? "xc_f32tos64(%s)" : "xc_f32tou64(%s)", a.cString()));
                return true;
                }
            bool isCopy = o.equals(self.spvS("Copy"));
            if (!isCopy && !o.equals(self.spvS("SIToFp")) && !o.equals(self.spvS("UIToFp")) && !o.equals(self.spvS("FpToSI")) && !o.equals(self.spvS("FpToUI")))
                return false;
            if (wgIsFloat(st) && wgIsFloat(rt))
                v = a;
            else if (wgIsFloat(rt))
                {
                bool s = o.equals(self.spvS("SIToFp")) || (isCopy && wgSigned(st));
                v = s ? String.withFormat("f32(i32(%s))", a.cString()) : String.withFormat("f32(%s)", a.cString());
                }
            else
                {
                bool s = o.equals(self.spvS("FpToSI")) || (isCopy && wgSigned(rt));
                v = wgCanon(s ? String.withFormat("u32(i32(%s))", a.cString()) : String.withFormat("u32(%s)", a.cString()), rt);
                }
            }
        else
            {
            if (!o.equals(self.spvS("ZExt")) && !o.equals(self.spvS("SExt")) && !o.equals(self.spvS("Trunc")) && !o.equals(self.spvS("Copy")))
                return false;
            u32 sb = self.spvNarrowBits(st);
            bool extSigned = o.equals(self.spvS("SExt")) || (!o.equals(self.spvS("ZExt")) && wgSigned(st));
            String* x = a;
            if (sb != (u32)0 && extSigned != wgSigned(st))
                {
                String* as = extSigned ? self.spvS(sb == (u32)8 ? "I8" : "I16") : self.spvS(sb == (u32)8 ? "U8" : "U16");
                x = wgCanon(x, as);
                }
            if (wgWide(st) && !wgWide(rt))
                x = String.withFormat("%s.x", x.cString());
            else if (!wgWide(st) && wgWide(rt))
                x = extSigned ? String.withFormat("xc_sext64(%s)", x.cString()) : String.withFormat("vec2<u32>(%s, 0u)", x.cString());
            v = wgCanon(x, rt);
            }
        wgSet(ip, v);
        return true;
        }

    // A maths call's WGSL built-in, or 0 when it has none here (or none that
    // is exact, for an accuracy block).
    final String* wgMaths(String* callee, String* t, Array* args)
        {
        String* m = self.ptxMathName(callee);
        bool f = self.ptxIs(t, "F32");
        if (!f && (wgWide(t) || wgType(t) == (String*)0 || self.ptxIs(t, "Bool")))
            return (String*)0;
        String* j = new String();
        String* ij = new String();
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            if (i > (u32)0) { j.appendCString(", "); ij.appendCString(", "); }
            j.append((String*)args.get(i));
            ij.appendCString("i32(");
            ij.append((String*)args.get(i));
            ij.appendCString(")");
            }
        bool s = !f && wgSigned(t);
        if (m.equals(self.spvS("floor"))) return f ? String.withFormat("floor(%s)", j.cString()) : (String*)0;
        if (m.equals(self.spvS("abs")) || m.equals(self.spvS("fabs")))
            return f ? String.withFormat("abs(%s)", j.cString()) : s ? wgCanon(String.withFormat("u32(abs(%s))", ij.cString()), t) : (String*)0;
        if (m.equals(self.spvS("min")))
            return f ? String.withFormat("min(%s)", j.cString()) : s ? wgCanon(String.withFormat("u32(min(%s))", ij.cString()), t) : String.withFormat("min(%s)", j.cString());
        if (m.equals(self.spvS("max")))
            return f ? String.withFormat("max(%s)", j.cString()) : s ? wgCanon(String.withFormat("u32(max(%s))", ij.cString()), t) : String.withFormat("max(%s)", j.cString());
        if (!_mFast && f && m.equals(self.spvS("sqrt")))
            {
            String* h = wgHelperName(spvS("xcFsqrtRn"));
            return h != (String*)0 ? String.withFormat("%s(%s)", h.cString(), j.cString()) : (String*)0;
            }
        if (!_mFast || !f) return (String*)0;
        if (m.equals(self.spvS("sqrt"))) return String.withFormat("sqrt(%s)", j.cString());
        if (m.equals(self.spvS("sin"))) return String.withFormat("sin(%s)", j.cString());
        if (m.equals(self.spvS("cos"))) return String.withFormat("cos(%s)", j.cString());
        if (m.equals(self.spvS("exp"))) return String.withFormat("exp(%s)", j.cString());
        if (m.equals(self.spvS("ln")) || m.equals(self.spvS("log"))) return String.withFormat("log(%s)", j.cString());
        if (m.equals(self.spvS("pow"))) return String.withFormat("pow(%s)", j.cString());
        if (m.equals(self.spvS("fma"))) return String.withFormat("fma(%s)", j.cString());
        return (String*)0;
        }

    // The WGSL name of a function of the program the kernel calls, printed
    // once as a helper; 0 (with the reason) when it cannot be. As the
    // reference's wgHelperName.
    final String* wgHelperName(String* callee)
        {
        String* name = (String*)_wgHelpers.get((Hashable*)callee);
        if (name != (String*)0) return name;
        IRFunc* target = (IRFunc*)0;
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)_m.funcs().get(i)).name().equals(callee))
                target = (IRFunc*)_m.funcs().get(i);
        if (target == (IRFunc*)0) return (String*)0;
        name = String.withFormat("h%u", _wgHelpers.count());
        _wgHelpers.set((Hashable*)callee, (Object*)name);
        if (!wgHelper(target, name))
            {
            _wgHelpers.remove((Hashable*)callee);
            self.parBecause(parCallFailed(callee, _mHelperWhy));
            return (String*)0;
            }
        return name;
        }

    final bool wgCall(IRInsn* ip)
        {
        IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
        String* callee = o0.name();
        if (callee.equals(self.spvS("_xtc_sinit_run")) || callee.hasSuffix(self.spvS("$init")))
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
            String* v = wgValue(o, at);
            if (v == (String*)0) return false;
            args.add((Object*)v);
            }
        // A float's bits and back (ParSoftFloat.xc): WGSL's bit cast.
        if ((callee.equals(self.spvS("xcF32Bits")) || callee.equals(self.spvS("xcF32FromBits"))) && args.count() == (u32)1)
            {
            wgSet(ip, String.withFormat(callee.equals(self.spvS("xcF32Bits")) ? "bitcast<u32>(%s)" : "bitcast<f32>(%s)",
                                        ((String*)args.get((u32)0)).cString()));
            return true;
            }
        if (spvIsMaths(callee))
            {
            if (isVoid || args.count() == (u32)0) return false;
            String* e = wgMaths(callee, rt, args);
            if (e == (String*)0)
                {
                String* w = self.spvS("it calls ");
                w.append(self.parShown(callee));
                w.appendCString(", which a WebGPU device has only in an approximate form, and the block's goal is accuracy");
                self.parBecause(w);
                return false;
                }
            wgSet(ip, e);
            return true;
            }
        // A function of the program: printed once, as a WGSL function.
        String* name = wgHelperName(callee);
        if (name == (String*)0) return false;
        String* call = String.withString(name);
        call.appendCString("(");
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            if (i > (u32)0) call.appendCString(", ");
            call.append((String*)args.get(i));
            }
        call.appendCString(")");
        if (isVoid)
            {
            call.appendCString(";");
            wgLine(call);
            }
        else
            wgSet(ip, call);
        return true;
        }
    final String* wgWord(WgRecipe* r)
        {
        u32 n = self.spvNarrowBytes(r.pointee);
        if (n == (u32)0 || r.index == (String*)0) return (String*)0;
        String* word = wgLet(String.withFormat("%s >> %uu", r.index.cString(), n == (u32)1 ? (u32)2 : (u32)1));
        _wgShift = wgLet(String.withFormat("(%s & %uu) << %uu", r.index.cString(), n == (u32)1 ? (u32)3 : (u32)1,
                                           n == (u32)1 ? (u32)3 : (u32)4));
        return word;
        }

    final String* wgNarrowFrom(String* word, String* shift, String* t)
        {
        String* v = String.withFormat("(%s >> %s)", word.cString(), shift.cString());
        if (ptxIs(t, "Bool")) return String.withFormat("((%s & 0xffu) != 0u)", v.cString());
        if (wgSigned(t)) return wgCanon(v, t);
        return String.withFormat("(%s & 0x%xu)", v.cString(), ((u32)1 << self.spvNarrowBits(t)) - (u32)1);
        }

    final String* wgAccess(WgRecipe* r)
        {
        if (r.index == (String*)0)
            return r.base.hasPrefix(self.spvS("f")) ? r.base : String.withFormat("%s[0]", r.base.cString());
        return String.withFormat("%s[%s]", r.base.cString(), r.index.cString());
        }

    final bool wgStatement(IRInsn* ip)
        {
        IRValue* res = ip.res();
        String* rt = res != (IRValue*)0 ? res.ty() : (String*)0;
        String* o = ip.op();
        if (res != (IRValue*)0 && !self.ptxIs(rt, "Mem") && _wf.used.get((Hashable*)self.mslKey(res)) == (Object*)0 &&
            !o.equals(self.spvS("Call")) && !o.equals(self.spvS("Store")))
            return true;
        IROperand* o0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
        if (o.equals(self.spvS("Const")))
            {
            String* v = wgValue(o0, rt);
            if (v == (String*)0) return false;
            wgSet(ip, v);
            return true;
            }
        if (o.equals(self.spvS("Add")) || o.equals(self.spvS("Sub")) || o.equals(self.spvS("Mul")) || o.equals(self.spvS("UDiv")) ||
            o.equals(self.spvS("SDiv")) || o.equals(self.spvS("URem")) || o.equals(self.spvS("SRem")) || o.equals(self.spvS("And")) ||
            o.equals(self.spvS("Or")) || o.equals(self.spvS("Xor")) || o.equals(self.spvS("Shl")) || o.equals(self.spvS("LShr")) ||
            o.equals(self.spvS("AShr")) || o.equals(self.spvS("FAdd")) || o.equals(self.spvS("FSub")) || o.equals(self.spvS("FMul")) ||
            o.equals(self.spvS("FDiv")))
            return wgBinary(ip);
        if (o.equals(self.spvS("Not")))
            {
            String* a = wgValue(o0, rt);
            if (a == (String*)0) return false;
            wgSet(ip, self.ptxIs(rt, "Bool") ? String.withFormat("!%s", a.cString()) : wgCanon(String.withFormat("~%s", a.cString()), rt));
            return true;
            }
        if (o.equals(self.spvS("Neg")) || o.equals(self.spvS("FNeg")))
            {
            String* a = wgValue(o0, rt);
            if (a == (String*)0) return false;
            if (ptxIs(rt, "F32"))
                wgSet(ip, String.withFormat("-%s", a.cString()));
            else if (wgWide(rt))
                wgSet(ip, String.withFormat("xc_sub64(vec2<u32>(0u, 0u), %s)", a.cString()));
            else
                wgSet(ip, wgCanon(String.withFormat("(0u - %s)", a.cString()), rt));
            return true;
            }
        if (o.equals(self.spvS("FSqrt")))
            {
            String* a = wgValue(o0, rt);
            if (a == (String*)0 || !self.ptxIs(rt, "F32")) return false;
            if (!_mFast)
                {
                String* h = wgHelperName(spvS("xcFsqrtRn"));
                if (h == (String*)0)
                    {
                    self.parBecause(spvS("it takes a square root, which a WebGPU device does not round exactly, and the block's goal is accuracy"));
                    return false;
                    }
                wgSet(ip, String.withFormat("%s(%s)", h.cString(), a.cString()));
                return true;
                }
            wgSet(ip, String.withFormat("sqrt(%s)", a.cString()));
            return true;
            }
        if (o.equals(self.spvS("ICmp")) || o.equals(self.spvS("FCmp")))
            return wgCompare(ip);
        if (o.equals(self.spvS("ZExt")) || o.equals(self.spvS("SExt")) || o.equals(self.spvS("Trunc")) || o.equals(self.spvS("SIToFp")) ||
            o.equals(self.spvS("UIToFp")) || o.equals(self.spvS("FpToSI")) || o.equals(self.spvS("FpToUI")) || o.equals(self.spvS("Copy")))
            return wgConvert(ip);
        if (o.equals(self.spvS("Select")))
            {
            String* c = wgValue(o0, (String*)0);
            String* a = wgValue((IROperand*)ip.ops().get((u32)1), rt);
            String* b = wgValue((IROperand*)ip.ops().get((u32)2), rt);
            if (c == (String*)0 || a == (String*)0 || b == (String*)0) return false;
            wgSet(ip, String.withFormat("select(%s, %s, %s)", b.cString(), a.cString(), c.cString()));
            return true;
            }
        if (o.equals(self.spvS("FieldAddr")))
            {
            i64 k = self.mslSelfField(ip);
            if (k < (i64)0) return false;   // a field of a struct element: not in this cut
            if (mslIsPtr(_mObj.typeAt((u32)k))) return true;
            WgRecipe* r = new WgRecipe();
            r.base = String.withFormat("f%u", (u32)k);
            r.index = (String*)0;
            r.pointee = _mObj.typeAt((u32)k);
            r.words = false;
            _wf.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
            return true;
            }
        if (o.equals(self.spvS("ElementAddr")))
            {
            WgRecipe* b = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 ? (WgRecipe*)_wf.recipeOf.get((Hashable*)self.mslKey(o0.val())) : (WgRecipe*)0;
            String* pe = self.mslPointee(rt);
            if (b == (WgRecipe*)0 || pe == (String*)0 || b.base.hasPrefix(self.spvS("f"))) return false;
            // A work item's array holds one slot per element of its own type:
            // an index by any other width would land elsewhere. As the reference.
            if (b.base.hasPrefix(self.spvS("loc_")) && self.mslWidth(pe) != self.mslWidth(b.pointee)) return false;
            IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
            String* it = o1.kind() == (u8)OPK_USE ? self.mslTypeOf(o1) : self.spvS("I64");
            String* idx = wgValue(o1, it);
            if (idx == (String*)0 || wgIsFloat(it) || self.ptxIs(it, "Bool") || wgType(it) == (String*)0) return false;
            if (wgWide(it)) idx = String.withFormat("%s.x", idx.cString());
            if (b.index != (String*)0) idx = String.withFormat("(%s + %s)", b.index.cString(), idx.cString());
            // In a function variable: the pointer may be used in another block.
            String* nm = self.mslName(res);
            String* e = self.spvS("e");
            e.append(nm.substringBytes((u32)1, nm.byteLength() - (u32)1));
            _wf.vars.appendCString("  var ");
            _wf.vars.append(e);
            _wf.vars.appendCString(": u32;\n");
            String* l = String.withString(e);
            l.appendCString(" = "); l.append(idx); l.appendCString(";");
            wgLine(l);
            WgRecipe* r = new WgRecipe();
            r.base = b.base;
            r.words = b.words;
            r.pointee = pe;
            r.index = e;
            _wf.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
            return true;
            }
        if (o.equals(self.spvS("Bitcast")))
            {
            if (mslIsPtr(rt))
                {
                WgRecipe* b = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 ? (WgRecipe*)_wf.recipeOf.get((Hashable*)self.mslKey(o0.val())) : (WgRecipe*)0;
                String* pe = self.mslPointee(rt);
                if (b == (WgRecipe*)0 || self.spvWidth(b.pointee) != self.spvWidth(pe) || !wgSameType(b.pointee, pe))
                    return false;
                _wf.recipeOf.set((Hashable*)self.mslKey(res), (Object*)b);
                return true;
                }
            String* st = o0.kind() == (u8)OPK_USE ? self.mslTypeOf(o0) : rt;
            String* a = wgValue(o0, st);
            if (a == (String*)0 || self.spvWidth(st) != self.spvWidth(rt) || wgType(rt) == (String*)0 || wgType(st) == (String*)0) return false;
            if (wgType(st).equals(wgType(rt)))
                wgSet(ip, wgCanon(a, rt));   // a narrow result in its own form
            else if (spvWidth(st) == (u32)4)
                wgSet(ip, String.withFormat("bitcast<%s>(%s)", wgType(rt).cString(), a.cString()));
            else
                return false;
            return true;
            }
        if (o.equals(self.spvS("Load")))
            {
            String* buf = res != (IRValue*)0 ? (String*)_mBufOf.get((Hashable*)self.mslKey(res)) : (String*)0;
            if (buf != (String*)0)
                {
                WgRecipe* r = new WgRecipe();
                String* key = self.spvS("k");
                key.append(buf);
                r.base = (String*)_wgBufName.get((Hashable*)key);
                r.index = (String*)0;
                r.pointee = self.mslPointee(rt);
                r.words = _wgWordBufs.get((Hashable*)r.base) != (Object*)0;
                _wf.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
                return true;
                }
            if (mslIsPtr(rt)) return false;
            if (parSinitFlag(o0))
                {
                wgSet(ip, wgValue(IROperand.immI((i64)2, rt), rt));
                return true;
                }
            WgRecipe* r = o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0 ? (WgRecipe*)_wf.recipeOf.get((Hashable*)self.mslKey(o0.val())) : (WgRecipe*)0;
            if (r == (WgRecipe*)0 || wgType(rt) == (String*)0 || !wgSameType(r.pointee, rt)) return false;
            if (r.words)
                {
                String* w = wgWord(r);
                if (w == (String*)0) return false;
                String* sh = _wgShift;
                String* word = wgLet(String.withFormat("atomicLoad(&%s[%s])", r.base.cString(), w.cString()));
                wgSet(ip, wgNarrowFrom(word, sh, r.pointee));
                return true;
                }
            wgSet(ip, wgAccess(r));
            return true;
            }
        if (o.equals(self.spvS("Store")))
            {
            if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0) return false;
            // A class's static-init flag: the host ran the init before the
            // block, so the flag reads as done and a store to it changes nothing.
            if (parSinitFlag(o0)) return true;
            WgRecipe* r = (WgRecipe*)_wf.recipeOf.get((Hashable*)self.mslKey(o0.val()));
            if (r == (WgRecipe*)0) return false;
            String* v = wgValue((IROperand*)ip.ops().get((u32)1), r.pointee);
            if (v == (String*)0) return false;
            if (r.words)
                {
                String* w = wgWord(r);
                if (w == (String*)0) return false;
                String* sh = _wgShift;
                u32 mask = self.spvNarrowBytes(r.pointee) == (u32)1 ? (u32)$FF : (u32)$FFFF;
                String* bits = self.ptxIs(r.pointee, "Bool") ? String.withFormat("select(0u, 1u, %s)", v.cString())
                                                        : String.withFormat("(%s & 0x%xu)", v.cString(), mask);
                wgLine(String.withFormat("atomicAnd(&%s[%s], ~(0x%xu << %s));", r.base.cString(), w.cString(), mask, sh.cString()));
                wgLine(String.withFormat("atomicOr(&%s[%s], %s << %s);", r.base.cString(), w.cString(), bits.cString(), sh.cString()));
                return true;
                }
            String* l = wgAccess(r);
            l.appendCString(" = "); l.append(v); l.appendCString(";");
            wgLine(l);
            return true;
            }
        if (o.equals(self.spvS("Call")))
            return wgCall(ip);
        if (o.equals(self.spvS("AddrOf")))
            {
            if (res != (IRValue*)0 && _mSinit.get((Hashable*)self.mslKey(res)) != (Object*)0)
                return true;
            // A work item's own array (declared by wgDeclareValues). As the reference.
            String* lk = res != (IRValue*)0 ? (String*)_mLocalOf.get((Hashable*)self.mslKey(res)) : (String*)0;
            if (lk != (String*)0)
                {
                WgRecipe* lr = new WgRecipe();
                lr.base = self.spvS("loc_");
                lr.base.append(lk);
                lr.index = (String*)0;
                lr.pointee = self.mslPointee(rt);
                lr.words = false;
                _wf.recipeOf.set((Hashable*)self.mslKey(res), (Object*)lr);
                return true;
                }
            String* g = res != (IRValue*)0 ? (String*)_mGlobalOf.get((Hashable*)self.mslKey(res)) : (String*)0;
            if (g == (String*)0) return false;
            u32 gi = (u32)0;
            for (u32 q = (u32)0; q < _mGlobals.count(); q = q + (u32)1)
                if (((String*)_mGlobals.get(q)).equals(g)) { gi = q; break; }
            WgRecipe* r = new WgRecipe();
            String* key = self.spvS("g");
            key.append(String.withU32(gi));
            r.base = (String*)_wgBufName.get((Hashable*)key);
            r.index = (String*)0;
            r.pointee = self.mslPointee(rt);
            r.words = _wgWordBufs.get((Hashable*)r.base) != (Object*)0;
            _wf.recipeOf.set((Hashable*)self.mslKey(res), (Object*)r);
            return true;
            }
        if (o.equals(self.spvS("DbgValue")))
            return true;
        return false;
        }

    // The phi copies for an edge, as a parallel copy into lets first.
    final bool wgEdge(IRBlock* from, IRBlock* target, String* cond, bool whenTrue, Array* lets, Array* dsts)
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
            String* v = wgValue(inc, ph.res().ty());
            String* dst = (String*)_wf.varOf.get((Hashable*)self.mslKey(ph.res()));
            if (v == (String*)0) return false;
            if (dst == (String*)0) continue;
            if (cond != (String*)0)
                v = whenTrue ? String.withFormat("select(%s, %s, %s)", dst.cString(), v.cString(), cond.cString())
                             : String.withFormat("select(%s, %s, %s)", v.cString(), dst.cString(), cond.cString());
            lets.add((Object*)wgLet(v));
            dsts.add((Object*)dst);
            }
        return true;
        }

    final void wgStores(Array* lets, Array* dsts)
        {
        for (u32 k = (u32)0; k < lets.count(); k = k + (u32)1)
            {
            String* l = String.withString((String*)dsts.get(k));
            l.appendCString(" = "); l.append((String*)lets.get(k)); l.appendCString(";");
            wgLine(l);
            }
        }

    final String* wgBlockNum(IRBlock* b) { return (String*)_mBlk.get((Hashable*)b.name()); }

    final bool wgDispatch(IRFunc* f, String* guard)
        {
        _wf.code.appendCString("  var pc: u32 = 0u;\n");
        _wf.code.appendCString("  loop {\n    if (pc == 4294967295u");
        if (guard != (String*)0)
            {
            _wf.code.appendCString(" || !(");
            _wf.code.append(guard);
            _wf.code.appendCString(")");
            }
        _wf.code.appendCString(") { break; }\n    switch pc {\n");
        for (u32 k = (u32)0; k < f.blocks().count(); k = k + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(k);
            _wf.code.append(String.withFormat("    case %uu: {\n", k));
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                if (!wgStatement((IRInsn*)b.insns().get(i)))
                    {
                    self.parBecause(parWhyFor((IRInsn*)b.insns().get(i), true));
                    return false;
                    }
            IRInsn* t = b.term();
            if (t == (IRInsn*)0) return false;
            Array* lets = new Array();
            Array* dsts = new Array();
            if (t.op().equals(self.spvS("Branch")))
                {
                IRBlock* to = ((IROperand*)t.ops().get((u32)0)).blk();
                if (!wgEdge(b, to, (String*)0, true, lets, dsts)) return false;
                wgStores(lets, dsts);
                wgLine(String.withFormat("pc = %su;", wgBlockNum(to).cString()));
                }
            else if (t.op().equals(self.spvS("CondBranch")))
                {
                String* c = wgValue((IROperand*)t.ops().get((u32)0), (String*)0);
                if (c == (String*)0) return false;
                c = wgLet(c);
                IRBlock* yes = ((IROperand*)t.ops().get((u32)1)).blk();
                IRBlock* no = ((IROperand*)t.ops().get((u32)2)).blk();
                if (yes == no)
                    {
                    if (!wgEdge(b, yes, (String*)0, true, lets, dsts)) return false;
                    }
                else if (!wgEdge(b, yes, c, true, lets, dsts) || !wgEdge(b, no, c, false, lets, dsts))
                    return false;
                wgStores(lets, dsts);
                wgLine(String.withFormat("pc = select(%su, %su, %s);", wgBlockNum(no).cString(), wgBlockNum(yes).cString(), c.cString()));
                }
            else if (t.op().equals(self.spvS("Return")))
                {
                IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                String* rvt = rv == (IROperand*)0 ? (String*)0 : rv.kind() == (u8)OPK_USE ? self.mslTypeOf(rv) : f.ret();
                if (_mHelper && rvt != (String*)0 && !self.ptxIs(rvt, "Mem"))
                    {
                    String* v = wgValue(rv, rvt);
                    if (v == (String*)0 || _wf.retVar == (String*)0) return false;
                    String* l = String.withString(_wf.retVar);
                    l.appendCString(" = "); l.append(v); l.appendCString(";");
                    wgLine(l);
                    }
                wgLine(spvS("pc = 4294967295u;"));
                }
            else
                return false;
            _wf.code.appendCString("    }\n");
            }
        _wf.code.appendCString("    default: { pc = 4294967295u; }\n    }\n  }\n");
        return true;
        }

    // ── control flow: structured ────────────────────────────────────────
    // The reference's wgStructured…: the Metal plan (sPlan) as WGSL loop and
    // if/else, values in variables, phis copies on their edges; a dry walk
    // first, else the dispatch loop.
    final void wgStructLine(string s)
        {
        if (!_wf.dry) wgLine(spvS(s));
        }
    final bool wgSJump(u32 u, u32 v, i64 h, i64 e, i64 fo)
        {
        if (!_wf.dry)
            {
            Array* lets = new Array();
            Array* dsts = new Array();
            if (!wgEdge((IRBlock*)_sFn.blocks().get(u), (IRBlock*)_sFn.blocks().get(v), (String*)0, true, lets, dsts))
                return false;
            wgStores(lets, dsts);
            }
        if ((i64)v == h) { wgStructLine("continue;"); return true; }
        if ((i64)v == e) { wgStructLine("break;"); return true; }
        if ((i64)v == fo) return true;
        if (sIsHeader(v)) return wgSLoop(v, e, fo, h);
        if (((Number*)_sFwd.get(v)).asU32() != (u32)1) return false;
        return wgSBlock(v, h, e, fo);
        }
    final bool wgSLoop(u32 x, i64 oe, i64 of, i64 oh)
        {
        if (((Number*)_sFwd.get(x)).asU32() != (u32)1) return false;
        u32 ex = (u32)((Number*)_sExit.get((Hashable*)self.sKey(x))).asI64();
        if (oh >= (i64)0 && !self.sInLoop(oh, ex) && (i64)ex != oe && (i64)ex != of) return false;
        wgStructLine("loop {");
        if (!wgSBlock(x, (i64)x, (i64)ex, (i64)-1)) return false;
        wgStructLine("}");
        if ((i64)ex == of) return true;
        if ((i64)ex == oh) { wgStructLine("continue;"); return true; }
        if ((i64)ex == oe) { wgStructLine("break;"); return true; }
        if (sIsHeader(ex)) return false;
        return wgSBlock(ex, oh, oe, of);
        }
    final bool wgSBlock(u32 x, i64 h, i64 e, i64 fo)
        {
        IRBlock* b = (IRBlock*)_sFn.blocks().get(x);
        if (!_wf.dry)
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                if (!wgStatement((IRInsn*)b.insns().get(i)))
                    {
                    self.parBecause(parWhyFor((IRInsn*)b.insns().get(i), true));
                    return false;
                    }
        IRInsn* t = b.term();
        if (t == (IRInsn*)0) return false;
        if (t.op().equals(self.spvS("Return")))
            {
            if (_mHelper)
                {
                IROperand* rv = t.ops().count() > (u32)0 ? (IROperand*)t.ops().get((u32)0) : (IROperand*)0;
                String* rvt = rv == (IROperand*)0 ? (String*)0 : rv.kind() == (u8)OPK_USE ? self.mslTypeOf(rv) : _sFn.ret();
                if (!_wf.dry)
                    {
                    if (rvt != (String*)0 && !self.ptxIs(rvt, "Mem"))
                        {
                        String* v = wgValue(rv, rvt);
                        if (v == (String*)0) return false;
                        String* l = self.spvS("return ");
                        l.append(v); l.appendCString(";");
                        wgLine(l);
                        }
                    else
                        wgLine(spvS("return;"));
                    }
                return true;
                }
            // The kernel's work ends: a break from the loop that runs once,
            // which only works from outside any loop of the kernel's own.
            if (h >= (i64)0) return false;
            wgStructLine("break;");
            return true;
            }
        if (t.op().equals(self.spvS("Branch")))
            return wgSJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)0)).blk()), h, e, fo);
        if (!t.op().equals(self.spvS("CondBranch"))) return false;
        u32 n = _sFn.blocks().count();
        i64 j = ((Number*)_sIpdom.get(x)).asI64();
        if (j < (i64)0) return false;
        i64 join = j == (i64)n ? fo : j;
        if (join >= (i64)0 && join != h && join != e && join != fo)
            if (h >= (i64)0 && !self.sInLoop(h, (u32)join)) return false;
        if (!_wf.dry)
            {
            String* c = wgValue((IROperand*)t.ops().get((u32)0), (String*)0);
            if (c == (String*)0) return false;
            String* l = self.spvS("if (");
            l.append(c); l.appendCString(") {");
            wgLine(l);
            }
        if (!wgSJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)1)).blk()), h, e, join)) return false;
        wgStructLine("} else {");
        if (!wgSJump(x, self.sIndexOf(((IROperand*)t.ops().get((u32)2)).blk()), h, e, join)) return false;
        wgStructLine("}");
        if (join < (i64)0 || join == fo) return true;
        if (join == h) { wgStructLine("continue;"); return true; }
        if (join == e) { wgStructLine("break;"); return true; }
        if (sIsHeader((u32)join)) return wgSLoop((u32)join, e, fo, h);
        return wgSBlock((u32)join, h, e, fo);
        }
    final bool wgSWalk(void)
        {
        return self.sIsHeader((u32)0) ? wgSLoop((u32)0, (i64)-1, (i64)-1, (i64)-1)
                                 : wgSBlock((u32)0, (i64)-1, (i64)-1, (i64)-1);
        }
    // The function's blocks, structured where their shape allows, else as
    // the dispatch loop; run while guard (0: always) holds.
    final bool wgBody(IRFunc* g, String* guard)
        {
        _wf.dry = true;
        bool fits = self.sPlan(g) && wgSWalk();
        _wf.dry = false;
        if (!fits) return wgDispatch(g, guard);
        wgLine(spvS("loop {"));
        if (guard != (String*)0)
            {
            String* l = self.spvS("if (!(");
            l.append(guard); l.appendCString(")) { break; }");
            wgLine(l);
            }
        if (!wgSWalk()) return false;
        wgLine(spvS("break;"));
        wgLine(spvS("}"));
        return true;
        }

    final bool wgDeclareValues(IRFunc* f)
        {
        // Values are named by their order in the walk, as the Metal printer
        // names them (mslName). As the reference.
        _mOrd = new Map();
        u32 ord = (u32)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(self.spvS("Mem")))
                    { _mOrd.set((Hashable*)self.mslKey(ip.res()), (Object*)String.withU32(ord)); ord = ord + (u32)1; }
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0 && !ip.res().ty().equals(self.spvS("Mem")))
                    { _mOrd.set((Hashable*)self.mslKey(ip.res()), (Object*)String.withU32(ord)); ord = ord + (u32)1; }
                }
            }
        Map* used = new Map();
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
                        used.set((Hashable*)self.mslKey(op.val()), (Object*)self.spvS("1"));
                    }
                }
            }
        _wf.used = used;
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
                String* t = ip.res().ty();
                if (ptxIs(t, "Mem") || self.mslIsPtr(t) || used.get((Hashable*)self.mslKey(ip.res())) == (Object*)0) continue;
                String* ty = wgType(t);
                if (ty == (String*)0)
                    {
                    self.parBecause(ptxIs(t, "F64") ? self.spvS("it uses a double, which WebGPU does not have") : self.spvS("it uses a value its WebGPU version cannot hold"));
                    return false;
                    }
                String* n = self.mslName(ip.res());
                _wf.varOf.set((Hashable*)self.mslKey(ip.res()), (Object*)n);
                _wf.vars.appendCString("  var ");
                _wf.vars.append(n);
                _wf.vars.appendCString(": ");
                _wf.vars.append(ty);
                _wf.vars.appendCString(";\n");
                }
            }
        // The work item's own arrays, in the order first met: function-scope
        // arrays, an element a slot of its WGSL type (a narrow one in a u32).
        // As the reference.
        for (u32 q = (u32)0; q < _mLocalBytes.count(); q = q + (u32)1)
            {
            String* et = (String*)_mLocalElem.get(q);
            String* ty = wgType(et);
            u32 ew = self.mslWidth(et);
            if (ty == (String*)0 || ew == (u32)0)
                {
                self.parBecause(ptxIs(et, "F64") ? self.spvS("it uses a double, which WebGPU does not have") : self.spvS("it uses a local value its WebGPU version cannot place"));
                return false;
                }
            _wf.vars.appendCString("  var loc_");
            _wf.vars.append(String.withU32(q));
            _wf.vars.appendCString(": array<");
            _wf.vars.append(ty);
            _wf.vars.appendCString(", ");
            _wf.vars.append(String.withU32(((Number*)_mLocalBytes.get(q)).asU32() / ew));
            _wf.vars.appendCString(">;\n");
            }
        return true;
        }

    // A helper the kernel calls, printed into _wgHelperText as `fn name(…)`.
    final bool wgHelper(IRFunc* g, String* name)
        {
        Map* sDef = _mDef; Map* sSpace = _mSpace; Map* sBufOf = _mBufOf; Map* sOrd = _mOrd;
        Map* sBlk = _mBlk; Map* sBufs = _mBufs; Map* sReds = _mReds; IRLayout* sObj = _mObj;
        bool sFailed = _mFailed; bool sHelper = _mHelper; Map* sParams = _mParams; Map* sSinit = _mSinit; String* sWhy = _mWhy;
        Map* sLocalOf = _mLocalOf; Map* sLocalIndex = _mLocalIndex; Array* sLocalDecls = _mLocalDecls; Array* sLocalBytes = _mLocalBytes; Array* sLocalElem = _mLocalElem;
        Array* sGlobals = _mGlobals; Map* sGlobalOf = _mGlobalOf; WgFn* sFn = _wf;
        Array* sSucc = _sSucc; Array* sRpo = _sRpo; Array* sFwd = _sFwd; Map* sLoop = _sLoop; Map* sExit = _sExit;
        Array* sIpdom = _sIpdom; IRFunc* sSFn = _sFn;
        bool ok = wgHelperBody(g, name);
        _sSucc = sSucc; _sRpo = sRpo; _sFwd = sFwd; _sLoop = sLoop; _sExit = sExit; _sIpdom = sIpdom; _sFn = sSFn;
        _mHelperWhy = _mWhy;
        _mDef = sDef; _mSpace = sSpace; _mBufOf = sBufOf; _mOrd = sOrd;
        _mBlk = sBlk; _mBufs = sBufs; _mReds = sReds; _mObj = sObj;
        _mFailed = sFailed; _mHelper = sHelper; _mParams = sParams; _mSinit = sSinit; _mWhy = sWhy;
        _mLocalOf = sLocalOf; _mLocalIndex = sLocalIndex; _mLocalDecls = sLocalDecls; _mLocalBytes = sLocalBytes; _mLocalElem = sLocalElem;
        _mGlobals = sGlobals; _mGlobalOf = sGlobalOf; _wf = sFn;
        return ok;
        }

    final bool wgHelperBody(IRFunc* g, String* name)
        {
        _mDef = new Map(); _mSpace = new Map(); _mBufOf = new Map(); _mOrd = new Map();
        _mBlk = new Map(); _mBufs = new Map(); _mReds = new Map(); _mFailed = false; _mSinit = new Map(); _mWhy = (String*)0; _mLocalOf = new Map(); _mLocalIndex = new Map(); _mLocalDecls = new Array(); _mLocalBytes = new Array(); _mLocalElem = new Array();
        _mHelper = true;
        _mParams = new Map();
        _mObj = (IRLayout*)0;
        _mGlobals = new Array();
        _mGlobalOf = new Map();
        if (!self.mslAnalyse(g)) return false;
        for (u32 bi = (u32)0; bi < g.blocks().count(); bi = bi + (u32)1)
            _mBlk.set((Hashable*)((IRBlock*)g.blocks().get(bi)).name(), (Object*)String.withU32(bi));
        String* rt = g.ret();
        bool isVoid = rt == (String*)0 || self.ptxIs(rt, "Void") || self.ptxIs(rt, "Mem");
        String* ret = isVoid ? (String*)0 : wgType(rt);
        if (!isVoid && ret == (String*)0) return false;
        _wf = new WgFn();
        String* params = new String();
        for (u32 k = (u32)0; k + (u32)1 < g.params().count(); k = k + (u32)1)
            {
            IRValue* pv = (IRValue*)g.params().get(k);
            String* t = wgType(pv.ty());
            if (t == (String*)0) return false;
            if (k > (u32)0) params.appendCString(", ");
            params.append(String.withFormat("p%u: %s", k, t.cString()));
            // Parameter n is value n, read as the parameter itself.
            _mParams.set((Hashable*)self.mslKey(pv), (Object*)String.withU32(k));
            _wf.varOf.set((Hashable*)self.mslKey(pv), (Object*)String.withFormat("p%u", k));
            }
        if (!wgDeclareValues(g)) return false;
        if (!isVoid)
            {
            _wf.retVar = self.spvS("ret");
            _wf.vars.append(String.withFormat("  var ret: %s;\n", ret.cString()));
            }
        if (!wgBody(g, (String*)0)) return false;
        _wgHelperText.appendCString("fn ");
        _wgHelperText.append(name);
        _wgHelperText.appendCString("(");
        _wgHelperText.append(params);
        _wgHelperText.appendCString(")");
        if (!isVoid)
            {
            _wgHelperText.appendCString(" -> ");
            _wgHelperText.append(ret);
            }
        _wgHelperText.appendCString(" {\n");
        _wgHelperText.append(_wf.vars);
        _wgHelperText.append(_wf.code);
        if (!isVoid)
            _wgHelperText.appendCString("  return ret;\n");
        _wgHelperText.appendCString("}\n");
        return true;
        }

    // A field of the object from its bytes (binding 0, array<u32>) at byte
    // offset `off`, as type t; or 0.
    final String* wgFieldFrom(u32 off, String* t)
        {
        u32 w = off >> (u32)2;
        if (spvNarrowBytes(t) != (u32)0)
            return wgNarrowFrom(String.withFormat("args[%uu]", w), wgU32Lit((off & (u32)3) * (u32)8), t);
        if ((off & (u32)3) != (u32)0) return (String*)0;
        if (ptxIs(t, "I32") || self.ptxIs(t, "U32")) return String.withFormat("args[%uu]", w);
        if (ptxIs(t, "F32")) return String.withFormat("bitcast<f32>(args[%uu])", w);
        if (wgWide(t)) return String.withFormat("vec2<u32>(args[%uu], args[%uu])", w, w + (u32)1);
        return (String*)0;
        }
    final String* wgDeclare(String* decls, String* name, String* et)
        {
        String* t = wgType(et);
        if (t == (String*)0 || self.ptxIs(et, "F64")) return (String*)0;
        bool narrow = self.spvNarrowBytes(et) != (u32)0;
        decls.append(String.withFormat("@group(0) @binding(%u) var<storage, read_write> %s: array<%s>;\n", _wgBinding,
                                       name.cString(), narrow ? "atomic<u32>" : t.cString()));
        _wgBinding = _wgBinding + (u32)1;
        if (narrow)
            _wgWordBufs.set((Hashable*)name, (Object*)self.spvS("1"));
        return name;
        }

    final bool parWgsl(IRFunc* f)
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
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            _mBlk.set((Hashable*)((IRBlock*)f.blocks().get(bi)).name(), (Object*)String.withU32(bi));
        _wgHelpers = new Map();
        _wgHelperText = new String();
        _wgWordBufs = new Map();
        _wgBufName = new Map();

        // The object's fields the kernel uses (other than captured arrays).
        Map* used = new Map();
        used.set((Hashable*)self.spvS("1"), (Object*)self.spvS("1"));
        used.set((Hashable*)self.spvS("2"), (Object*)self.spvS("1"));
        for (u32 bi = (u32)0; bi < f.blocks().count(); bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)f.blocks().get(bi);
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)b.insns().get(i);
                if (!ip.op().equals(self.spvS("FieldAddr")) || ip.res() == (IRValue*)0) continue;
                i64 k = self.mslSelfField(ip);
                if (k >= (i64)0 && !self.mslIsPtr(_mObj.typeAt((u32)k)))
                    used.set((Hashable*)String.withI64(k), (Object*)self.spvS("1"));
                }
            }
        _wf = new WgFn();
        String* fieldInit = new String();
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (used.get((Hashable*)String.withU32(k)) == (Object*)0) continue;
            String* ft = _mObj.typeAt(k);
            String* ty = wgType(ft);
            String* from = ty != (String*)0 ? wgFieldFrom(_mObj.offsetAt(k), ft) : (String*)0;
            if (from == (String*)0)
                {
                self.parBecause(ptxIs(ft, "F64") ? self.spvS("it uses a double, which WebGPU does not have") : self.spvS("it uses a captured value its WebGPU version cannot hold"));
                return false;
                }
            _wf.vars.append(String.withFormat("  var f%u: %s;\n", k, ty.cString()));
            fieldInit.append(String.withFormat("  f%u = %s;\n", k, from.cString()));
            }

        String* meta = self.spvS("// xcpar wgsl size=");
        meta.append(String.withU32(_mObj.size())); meta.appendCString(" lo="); meta.append(String.withU32(_mObj.offsetAt((u32)1)));
        meta.appendCString(" hi="); meta.append(String.withU32(_mObj.offsetAt((u32)2)));
        String* decls = new String();
        decls.appendCString("@group(0) @binding(0) var<storage, read> args: array<u32>;\n");
        decls.appendCString("@group(0) @binding(1) var<storage, read> span: array<vec2<u32>, 3>;\n");
        _wgBinding = (u32)2;
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mBufs.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            String* et = self.mslPointee(_mObj.typeAt(k));
            String* n = wgDeclare(decls, String.withFormat("b%u", k), et);
            if (n == (String*)0)
                {
                self.parBecause(ptxIs(et, "F64") ? self.spvS("it uses an array of doubles, which WebGPU does not have") : self.spvS("it uses an array of values its WebGPU version cannot hold"));
                return false;
                }
            meta.appendCString(" buf="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":");
            meta.append(String.withU32(k - (u32)3)); meta.appendCString(":"); meta.append(String.withU32(self.spvWidth(et)));
            String* key = self.spvS("k");
            key.append(String.withI64((i64)k));
            _wgBufName.set((Hashable*)key, (Object*)n);
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
            String* n = wgDeclare(decls, String.withFormat("g%u", gi), et);
            if (n == (String*)0)
                {
                String* w = self.spvS("it uses ");
                w.append(self.parShown(gn));
                w.appendCString(", which its WebGPU version cannot hold");
                self.parBecause(w);
                return false;
                }
            meta.appendCString(" glob="); meta.append(gn); meta.appendCString(":"); meta.append(String.withU32(self.spvWidth(et)));
            String* key = self.spvS("g");
            key.append(String.withU32(gi));
            _wgBufName.set((Hashable*)key, (Object*)n);
            }
        if (_parExtraMeta != (String*)0) meta.append(_parExtraMeta);
        Array* reds = new Array();
        // A device-side reduction (bug 645) when every reduced field is a
        // 32-bit value with an operator its type takes (the reference explains).
        bool devred = _mRedOps != (Map*)0;
        bool anyRed = false;
        String* wgDecls = new String();
        String* wgTail = new String();
        for (u32 k = (u32)0; k < _mObj.fieldCount(); k = k + (u32)1)
            {
            if (_mReds.get((Hashable*)String.withI64((i64)k)) == (Object*)0) continue;
            anyRed = true;
            String* t = _mObj.typeAt(k);
            if (wgType(t) == (String*)0 || used.get((Hashable*)String.withU32(k)) == (Object*)0)
                {
                self.parBecause(spvS("it reduces a value its WebGPU version cannot hold"));
                return false;
                }
            // An 8- or 16-bit value or a bool: a u32 slot per thread (the
            // reference explains).
            bool narrow = self.spvNarrowBytes(t) != (u32)0;
            meta.appendCString(" red="); meta.append(String.withU32(_mObj.offsetAt(k))); meta.appendCString(":"); meta.append(String.withU32(self.spvWidth(t)));
            if (narrow) meta.appendCString(":4");
            decls.append(String.withFormat("@group(0) @binding(%u) var<storage, read_write> r%u: array<%s>;\n", _wgBinding, k,
                                           narrow ? "u32" : wgType(t).cString()));
            _wgBinding = _wgBinding + (u32)1;
            if (ptxIs(t, "Bool")) reds.add((Object*)String.withFormat("r%u[tid] = select(0u, 1u, f%u);", k, k));
            else reds.add((Object*)String.withFormat("r%u[tid] = f%u;", k, k));
            String* op = _mRedOps != (Map*)0 ? (String*)_mRedOps.get((Hashable*)String.withU32(k)) : (String*)0;
            bool isF = self.ptxIs(t, "F32");
            bool okT = self.ptxIs(t, "I32") || self.ptxIs(t, "U32") || isF;
            String* comb = (String*)0;
            if (okT && op != (String*)0 && (op.equals(self.spvS("min")) || op.equals(self.spvS("max"))))
                comb = String.withFormat("%s(w%u[lid], w%u[lid + s])", op.cString(), k, k);
            else if (okT && op != (String*)0 && (op.equals(self.spvS("+")) || op.equals(self.spvS("*")) ||
                     (!isF && (op.equals(self.spvS("&")) || op.equals(self.spvS("|")) || op.equals(self.spvS("^"))))))
                comb = String.withFormat("w%u[lid] %s w%u[lid + s]", k, op.cString(), k);
            if (comb == (String*)0)
                devred = false;
            else
                {
                wgDecls.append(String.withFormat("var<workgroup> w%u: array<%s, 256>;\n", k, wgType(t).cString()));
                wgTail.append(String.withFormat("  w%u[lid] = f%u;\n  workgroupBarrier();\n", k, k));
                wgTail.appendCString("  for (var s = 128u; s > 0u; s = s >> 1u) {\n");
                wgTail.append(String.withFormat("    if (lid < s) { w%u[lid] = %s; }\n    workgroupBarrier();\n  }\n", k, comb.cString()));
                wgTail.append(String.withFormat("  if (lid == 0u) { r%u[wid.x + wid.y * 65535u] = w%u[0]; }\n", k, k));
                }
            }
        if (!anyRed)
            devred = false;

        if (!wgDeclareValues(f)) return false;
        String* body = new String();
        body.append(fieldInit);
        if (devred)
            body.appendCString("  let tid = gid.x + gid.y * 16776960u;\n");
        else
            body.appendCString("  let tid = gid.x + gid.y * 4194240u;\n");
        body.appendCString("  let lo = xc_add64(span[0], xc_mul64(vec2<u32>(tid, 0u), span[2]));\n");
        body.appendCString("  let end = xc_add64(lo, span[2]);\n");
        body.appendCString("  let hi = select(span[1], end, xc_slt64(end, span[1]));\n");
        body.appendCString("  f1 = lo;\n  f2 = hi;\n");
        if (!wgBody(f, self.spvS("xc_slt64(lo, hi)"))) return false;
        body.append(_wf.code);
        if (devred)
            // Every thread reaches every barrier: one past the range holds its
            // reductions' starting values, which leave the result unchanged.
            body.append(wgTail);
        else if (reds.count() > (u32)0)
            {
            body.appendCString("  if (xc_slt64(lo, span[1])) {\n    ");
            for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1)
                {
                if (i > (u32)0) body.appendCString("\n    ");
                body.append((String*)reds.get(i));
                }
            body.appendCString("\n  }\n");
            }
        if (_mWhy != (String*)0) return false;
        if (devred) meta.appendCString(" devred");
        meta.appendCString(_mFast ? " wgsl fast" : " wgsl");
        String* out = String.withString(meta);
        out.appendCString("\n");
        out.append(decls);
        if (devred) out.append(wgDecls);
        out.append(wgSixtyFour());
        out.append(_wgHelperText);
        if (devred)
            out.appendCString("@compute @workgroup_size(256)\nfn main(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(local_invocation_index) lid: u32, @builtin(workgroup_id) wid: vec3<u32>) {\n");
        else
            out.appendCString("@compute @workgroup_size(64)\nfn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n");
        out.append(_wf.vars);
        out.append(body);
        out.appendCString("}\n");
        _wgOut = out;
        return true;
        }

    // The 64-bit helpers: (low, high) pairs. As the reference's kWg64.
    final String* wgSixtyFour(void)
        {
        String* s = new String();
        s.appendCString("fn xc_add64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n");
        s.appendCString("  let lo = a.x + b.x;\n");
        s.appendCString("  return vec2<u32>(lo, a.y + b.y + select(0u, 1u, lo < a.x));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_sub64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n");
        s.appendCString("  return vec2<u32>(a.x - b.x, a.y - b.y - select(0u, 1u, a.x < b.x));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_mulwide(a: u32, b: u32) -> vec2<u32> {\n");
        s.appendCString("  let al = a & 0xffffu; let ah = a >> 16u; let bl = b & 0xffffu; let bh = b >> 16u;\n");
        s.appendCString("  let ll = al * bl; let lh = al * bh; let hl = ah * bl; let hh = ah * bh;\n");
        s.appendCString("  let mid = (ll >> 16u) + (lh & 0xffffu) + (hl & 0xffffu);\n");
        s.appendCString("  return vec2<u32>((ll & 0xffffu) | (mid << 16u), hh + (lh >> 16u) + (hl >> 16u) + (mid >> 16u));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_mul64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n");
        s.appendCString("  let w = xc_mulwide(a.x, b.x);\n");
        s.appendCString("  return vec2<u32>(w.x, w.y + a.x * b.y + a.y * b.x);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_shl64(a: vec2<u32>, n: u32) -> vec2<u32> {\n");
        s.appendCString("  let s = n & 63u;\n");
        s.appendCString("  if (s == 0u) { return a; }\n");
        s.appendCString("  if (s >= 32u) { return vec2<u32>(0u, a.x << (s - 32u)); }\n");
        s.appendCString("  return vec2<u32>(a.x << s, (a.y << s) | (a.x >> (32u - s)));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_lshr64(a: vec2<u32>, n: u32) -> vec2<u32> {\n");
        s.appendCString("  let s = n & 63u;\n");
        s.appendCString("  if (s == 0u) { return a; }\n");
        s.appendCString("  if (s >= 32u) { return vec2<u32>(a.y >> (s - 32u), 0u); }\n");
        s.appendCString("  return vec2<u32>((a.x >> s) | (a.y << (32u - s)), a.y >> s);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_ashr64(a: vec2<u32>, n: u32) -> vec2<u32> {\n");
        s.appendCString("  let s = n & 63u;\n");
        s.appendCString("  let sign = select(0u, 0xffffffffu, (a.y & 0x80000000u) != 0u);\n");
        s.appendCString("  if (s == 0u) { return a; }\n");
        s.appendCString("  if (s >= 32u) { return vec2<u32>(u32(i32(a.y) >> (s - 32u)), sign); }\n");
        s.appendCString("  return vec2<u32>((a.x >> s) | (a.y << (32u - s)), u32(i32(a.y) >> s));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_ult64(a: vec2<u32>, b: vec2<u32>) -> bool {\n");
        s.appendCString("  return a.y < b.y || (a.y == b.y && a.x < b.x);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_slt64(a: vec2<u32>, b: vec2<u32>) -> bool {\n");
        s.appendCString("  return i32(a.y) < i32(b.y) || (a.y == b.y && a.x < b.x);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_sext64(x: u32) -> vec2<u32> {\n");
        s.appendCString("  return vec2<u32>(x, select(0u, 0xffffffffu, (x & 0x80000000u) != 0u));\n");
        s.appendCString("}\n");
        s.appendCString("struct XcQR { q: vec2<u32>, r: vec2<u32> }\n");
        s.appendCString("fn xc_neg64(a: vec2<u32>) -> vec2<u32> {\n");
        s.appendCString("  return xc_sub64(vec2<u32>(0u, 0u), a);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_udivrem64(n: vec2<u32>, d: vec2<u32>) -> XcQR {\n");
        s.appendCString("  if (d.x == 0u && d.y == 0u) { return XcQR(n, vec2<u32>(0u, 0u)); }\n");
        s.appendCString("  var q = vec2<u32>(0u, 0u);\n");
        s.appendCString("  var r = vec2<u32>(0u, 0u);\n");
        s.appendCString("  var i = 64u;\n");
        s.appendCString("  loop {\n");
        s.appendCString("    if (i == 0u) { break; }\n");
        s.appendCString("    i = i - 1u;\n");
        s.appendCString("    var bit = (n.x >> i) & 1u;\n");
        s.appendCString("    if (i >= 32u) { bit = (n.y >> (i - 32u)) & 1u; }\n");
        s.appendCString("    r = vec2<u32>((r.x << 1u) | bit, (r.y << 1u) | (r.x >> 31u));\n");
        s.appendCString("    if (!xc_ult64(r, d)) {\n");
        s.appendCString("      r = xc_sub64(r, d);\n");
        s.appendCString("      if (i >= 32u) { q.y = q.y | (1u << (i - 32u)); } else { q.x = q.x | (1u << i); }\n");
        s.appendCString("    }\n");
        s.appendCString("  }\n");
        s.appendCString("  return XcQR(q, r);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_sdivrem64(a: vec2<u32>, b: vec2<u32>) -> XcQR {\n");
        s.appendCString("  let na = (a.y >> 31u) != 0u;\n");
        s.appendCString("  let nb = (b.y >> 31u) != 0u;\n");
        s.appendCString("  let qr = xc_udivrem64(select(a, xc_neg64(a), na), select(b, xc_neg64(b), nb));\n");
        s.appendCString("  return XcQR(select(qr.q, xc_neg64(qr.q), na != nb), select(qr.r, xc_neg64(qr.r), na));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_udiv64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> { return xc_udivrem64(a, b).q; }\n");
        s.appendCString("fn xc_urem64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> { return xc_udivrem64(a, b).r; }\n");
        s.appendCString("fn xc_sdiv64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n");
        s.appendCString("  if (b.x == 0u && b.y == 0u) { return a; }\n");
        s.appendCString("  if (b.x == 0xffffffffu && b.y == 0xffffffffu && a.x == 0u && a.y == 0x80000000u) { return a; }\n");
        s.appendCString("  return xc_sdivrem64(a, b).q;\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_srem64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n");
        s.appendCString("  if (b.x == 0u && b.y == 0u) { return vec2<u32>(0u, 0u); }\n");
        s.appendCString("  if (b.x == 0xffffffffu && b.y == 0xffffffffu && a.x == 0u && a.y == 0x80000000u) { return vec2<u32>(0u, 0u); }\n");
        s.appendCString("  return xc_sdivrem64(a, b).r;\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_u64tof32(a: vec2<u32>) -> f32 {\n");
        s.appendCString("  if (a.x == 0u && a.y == 0u) { return 0.0; }\n");
        s.appendCString("  var lz = countLeadingZeros(a.y);\n");
        s.appendCString("  if (a.y == 0u) { lz = 32u + countLeadingZeros(a.x); }\n");
        s.appendCString("  let m = xc_shl64(a, lz);\n");
        s.appendCString("  var mant = m.y >> 8u;\n");
        s.appendCString("  let rest = m.y & 0xffu;\n");
        s.appendCString("  let lower = (rest & 0x7fu) != 0u || m.x != 0u;\n");
        s.appendCString("  if ((rest & 0x80u) != 0u && (lower || (mant & 1u) != 0u)) { mant = mant + 1u; }\n");
        s.appendCString("  var e = 63u - lz;\n");
        s.appendCString("  if (mant == 0x1000000u) { mant = 0x800000u; e = e + 1u; }\n");
        s.appendCString("  return bitcast<f32>(((e + 127u) << 23u) | (mant & 0x7fffffu));\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_s64tof32(a: vec2<u32>) -> f32 {\n");
        s.appendCString("  if ((a.y >> 31u) != 0u) { return -xc_u64tof32(xc_neg64(a)); }\n");
        s.appendCString("  return xc_u64tof32(a);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_f32tou64(f: f32) -> vec2<u32> {\n");
        s.appendCString("  if (!(f >= 1.0)) { return vec2<u32>(0u, 0u); }\n");
        s.appendCString("  if (f >= bitcast<f32>(0x5f800000u)) { return vec2<u32>(0xffffffffu, 0xffffffffu); }\n");
        s.appendCString("  let bits = bitcast<u32>(f);\n");
        s.appendCString("  let e = ((bits >> 23u) & 0xffu) - 127u;\n");
        s.appendCString("  let mant = (bits & 0x7fffffu) | 0x800000u;\n");
        s.appendCString("  if (e >= 23u) { return xc_shl64(vec2<u32>(mant, 0u), e - 23u); }\n");
        s.appendCString("  return vec2<u32>(mant >> (23u - e), 0u);\n");
        s.appendCString("}\n");
        s.appendCString("fn xc_f32tos64(f: f32) -> vec2<u32> {\n");
        s.appendCString("  if (f != f) { return vec2<u32>(0u, 0u); }\n");
        s.appendCString("  if (f >= bitcast<f32>(0x5f000000u)) { return vec2<u32>(0xffffffffu, 0x7fffffffu); }\n");
        s.appendCString("  if (f <= -bitcast<f32>(0x5f000000u)) { return vec2<u32>(0u, 0x80000000u); }\n");
        s.appendCString("  if (f < 0.0) { return xc_neg64(xc_f32tou64(-f)); }\n");
        s.appendCString("  return xc_f32tou64(f);\n");
        s.appendCString("}\n");
        return s;
        }
    }
