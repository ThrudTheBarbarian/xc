// LowerPar.xc — `par` blocks: the subset check, and each block's kernels printed and filled into its placeholder.
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
#import <LowerParLanes>
#import <LowerParPtx>
#import <LowerParSpirv>
#import <LowerParWgsl>

    class Lower (Par)
    {

    final void parCheck(void)
        {
        _parGuards = new Map();
        _parFns = new Map();
        _parSyms = new Map();
        _parVerdict = new Map();
        _parOnStack = new Map();
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)_m.funcs().get(i);
            _parFns.set((Hashable*)f.name(), (Object*)f);
            }
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)_m.syms().get(i);
            _parSyms.set((Hashable*)sym.name(), (Object*)sym);
            }
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)_m.funcs().get(i);
            if (!f.name().hasPrefix(String.withCString("ParImpl$")) || !f.name().hasSuffix(String.withCString("$run")))
                continue;
            String* cls = f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4);
            // An auto block (--par-auto made it from a plain loop) the check
            // would refuse is demoted to a serial run instead, with a warning.
            bool isAuto = parIsAutoBlock(cls.substringBytes((u32)8, cls.byteLength() - (u32)8));
            parReadGridWords(cls.substringBytes((u32)8, cls.byteLength() - (u32)8));
            String* why = (String*)0;
            // A captured class instance, String, Array, Map or block is an owned
            // ivar of the block's class, so its dealloc releases it.
            String* dn = String.withString(cls);
            dn.appendCString("$dealloc");
            IRFunc* dealloc = (IRFunc*)_parFns.get((Hashable*)dn);
            if (dealloc != (IRFunc*)0 && parReleases(dealloc))
                why = String.withCString("captures an ARC'd value (a class instance, String, Array, Map or block); capture plain values, structs and sized arrays");
            if (why == (String*)0)
                {
                String* r = parReason(f);
                if (r.byteLength() > (u32)0)
                    why = r;
                }
            if (why == (String*)0)
                {
                // §4: the work items must not touch each other's data.
                _parScatter = (String*)0;
                _parGuardList = new Array();
                String* dep = parDependence(f, parIvarNames(cls));
                if (dep == (String*)0 && _parGuardList.count() > (u32)0)
                    _parGuards.set((Hashable*)cls, (Object*)_parGuardList);
                _parGuardList = (Array*)0;
                if (dep == (String*)0)
                    {
                    if (_parScatter != (String*)0)
                        {
                        String* w = String.withCString("a 'par' block writes ");
                        w.append(_parScatter);
                        w.appendCString(", so the compiler cannot prove two work items never write the same element; if they can, the result depends on which runs last");
                        self.warnAtNode(String.withCString("par-scatter"), w, (Node*)_classDecls.get((Hashable*)cls));
                        }
                    // -Wpar-auto says what was wrapped as well as what was demoted.
                    if (isAuto)
                        self.warnAtNode(String.withCString("par-auto"), String.withCString("this loop became a 'par' block (--par-auto)"),
                                   (Node*)_classDecls.get((Hashable*)cls));
                    continue;
                    }
                if (isAuto)
                    {
                    if (_parSerial == (Set*)0) _parSerial = new Set();
                    _parSerial.add((Hashable*)cls);
                    String* w2 = String.withCString("this loop runs serially, not as a 'par' block (--par-auto): its work items are not independent, since it ");
                    w2.append(dep);
                    self.warnAtNode(String.withCString("par-auto"), w2, (Node*)_classDecls.get((Hashable*)cls));
                    continue;
                    }
                String* m2 = String.withCString("a 'par' block's work items must be independent, but this one ");
                m2.append(dep);
                self.errorAtNode(m2, (Node*)_classDecls.get((Hashable*)cls));
                return;
                }
            if (isAuto)
                {
                if (_parSerial == (Set*)0) _parSerial = new Set();
                _parSerial.add((Hashable*)cls);
                String* w3 = String.withCString("this loop runs serially, not as a 'par' block (--par-auto): a GPU could not run it, since it ");
                w3.append(why);
                self.warnAtNode(String.withCString("par-auto"), w3, (Node*)_classDecls.get((Hashable*)cls));
                continue;
                }
            String* msg = String.withCString("a 'par' block must be able to run on a GPU, but this one ");
            msg.append(why);
            self.errorAtNode(msg, (Node*)_classDecls.get((Hashable*)cls));
            return;
            }
        }

    // Whether block <n> (its class ParImpl$<n>) is one --par-auto made from a
    // plain loop: its GPU placeholder literal carries `auto;` after the tag.
    // Mirrors the reference's isAutoBlock.
    // The grid's constant width and height for block n, from its placeholder's
    // `gw=`/`gh=` words (0 when absent): set for the dependence test, which
    // runs before the printers' pass reads the words again. As the reference.
    final void parReadGridWords(String* n)
        {
        _mGridW = (i64)0;
        _mGridH = (i64)0;
        String* plain = String.withCString("__XC_PAR_MSL_");
        plain.append(n);
        plain.appendCString("__");
        String* fastTag = String.withCString("__XC_PAR_FAST_");
        fastTag.append(n);
        fastTag.appendCString("__");
        for (u32 j = (u32)0; j < _m.syms().count(); j = j + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)_m.syms().get(j);
            if (sym.kind() != (u8)SYM_STRINGLIT || sym.bytes() == (Array*)0)
                continue;
            String* tag = (String*)0;
            if (parBytesHavePrefix(sym.bytes(), fastTag)) tag = fastTag;
            else if (parBytesHavePrefix(sym.bytes(), plain)) tag = plain;
            if (tag == (String*)0)
                continue;
            String* key = new String();
            String* val = new String();
            bool inVal = false;
            for (u32 q = tag.byteLength(); q < sym.bytes().count(); q = q + (u32)1)
                {
                u8 c = (u8)((Number*)sym.bytes().get(q)).asU32();
                if (c == (u8)0)
                    break;
                if (c == (u8)';')
                    {
                    if (inVal && key.equals(String.withCString("gw"))) _mGridW = parWordI64(val);
                    if (inVal && key.equals(String.withCString("gh"))) _mGridH = parWordI64(val);
                    key = new String();
                    val = new String();
                    inVal = false;
                    }
                else if (c == (u8)'=' && !inVal)
                    inVal = true;
                else if (inVal)
                    val.appendByte(c);
                else
                    key.appendByte(c);
                }
            return;
            }
        }
    final bool parIsAutoBlock(String* n)
        {
        String* plain = String.withCString("__XC_PAR_MSL_");
        plain.append(n);
        plain.appendCString("__");
        String* fastTag = String.withCString("__XC_PAR_FAST_");
        fastTag.append(n);
        fastTag.appendCString("__");
        for (u32 j = (u32)0; j < _m.syms().count(); j = j + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)_m.syms().get(j);
            if (sym.kind() != (u8)SYM_STRINGLIT || sym.bytes() == (Array*)0)
                continue;
            String* tag = (String*)0;
            if (parBytesHavePrefix(sym.bytes(), fastTag)) tag = fastTag;
            else if (parBytesHavePrefix(sym.bytes(), plain)) tag = plain;
            if (tag == (String*)0)
                continue;
            String* autoWord = String.withCString("auto;");
            u32 at = tag.byteLength();
            if (sym.bytes().count() < at + autoWord.byteLength())
                return false;
            for (u32 q = (u32)0; q < autoWord.byteLength(); q = q + (u32)1)
                if (((Number*)sym.bytes().get(at + q)).asU32() != (u32)autoWord.byteAt(q))
                    return false;
            return true;
            }
        return false;
        }
    static bool parBytesHavePrefix(Array* bytes, String* s)
        {
        if (bytes.count() < s.byteLength())
            return false;
        for (u32 q = (u32)0; q < s.byteLength(); q = q + (u32)1)
            if (((Number*)bytes.get(q)).asU32() != (u32)s.byteAt(q))
                return false;
        return true;
        }

    // The block class's ivars in field order (its parents' first), so field #k
    // of the object is name k-1: field 0 is the object header.
    final Array* parIvarNames(String* cls)
        {
        Array* chain = new Array();
        Node* d = (Node*)_classDecls.get((Hashable*)cls);
        for (u32 depth = (u32)0; d != (Node*)0 && depth < (u32)16; depth = depth + (u32)1)
            {
            chain.insert((u32)0, (Object*)d);
            String* pn = d.op();
            if (pn == (String*)0 || pn.byteLength() == (u32)0 || pn.equals(d.name()))
                break;
            d = (Node*)_classDecls.get((Hashable*)pn);
            }
        Array* names = new Array();
        for (u32 i = (u32)0; i < chain.count(); i = i + (u32)1)
            {
            Node* c = (Node*)chain.get(i);
            for (u32 j = (u32)0; j < c.kids().count(); j = j + (u32)1)
                {
                Node* v = c.kid(j);
                if (v.kind() == (u16)nkVariableDecl)
                    names.add((Object*)v.name());
                }
            }
        return names;
        }

    // An index as k*i + c in the work item's index i, when it is one.
    final ParIdx* parIndex(IROperand* op, IRValue* iv, Map* def, u32 depth)
        {
        if (depth > (u32)32)
            return ParIdx.of(false, (i64)0, (i64)0);
        if (op.kind() == (u8)OPK_IMMI)
            return ParIdx.of(true, (i64)0, op.imm());
        if (op.kind() != (u8)OPK_USE)
            return ParIdx.of(false, (i64)0, (i64)0);
        if (op.val() != (IRValue*)0 && op.val().seq() == iv.seq())
            return ParIdx.of(true, (i64)1, (i64)0);
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(op.val().seq()));
        if (d == (IRInsn*)0 || d.ops().count() == (u32)0)
            return ParIdx.of(false, (i64)0, (i64)0);
        String* o = d.op();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o.equals(String.withCString("Const")))
            {
            if (o0.kind() == (u8)OPK_IMMI)
                return ParIdx.of(true, (i64)0, o0.imm());
            return ParIdx.of(false, (i64)0, (i64)0);
            }
        if (o.equals(String.withCString("ZExt")) || o.equals(String.withCString("SExt")) || o.equals(String.withCString("Trunc")) || o.equals(String.withCString("Copy")))
            return parIndex(o0, iv, def, depth + (u32)1);
        bool isAdd = o.equals(String.withCString("Add"));
        bool isSub = o.equals(String.withCString("Sub"));
        bool isMul = o.equals(String.withCString("Mul"));
        if ((!isAdd && !isSub && !isMul) || d.ops().count() < (u32)2)
            return ParIdx.of(false, (i64)0, (i64)0);
        ParIdx* x = parIndex(o0, iv, def, depth + (u32)1);
        ParIdx* y = parIndex((IROperand*)d.ops().get((u32)1), iv, def, depth + (u32)1);
        bool aa = x.affine; i64 ak = x.k; i64 ac = x.c;
        bool ba = y.affine; i64 bk = y.k; i64 bc = y.c;
        if (!aa || !ba)
            return ParIdx.of(false, (i64)0, (i64)0);
        if (isAdd)
            return ParIdx.of(true, ak + bk, ac + bc);
        if (isSub)
            return ParIdx.of(true, ak - bk, ac - bc);
        if (ak == (i64)0)
            return ParIdx.of(true, ac * bk, ac * bc);
        if (bk == (i64)0)
            return ParIdx.of(true, bc * ak, bc * ac);
        return ParIdx.of(false, (i64)0, (i64)0);
        }

    // An index with one symbolic term besides i: k*i + c + m*v, where v is a
    // captured integer of the block (a field of its object). As the reference.
    final ParIdx* parSymIndex(IROperand* op, IRValue* iv, IRValue* selfVal, Map* def, u32 depth)
        {
        ParIdx* no = ParIdx.of(false, (i64)0, (i64)0);
        if (depth > (u32)32)
            return no;
        if (op.kind() == (u8)OPK_IMMI)
            return ParIdx.of(true, (i64)0, op.imm());
        if (op.kind() != (u8)OPK_USE)
            return no;
        if (op.val() != (IRValue*)0 && op.val().seq() == iv.seq())
            return ParIdx.of(true, (i64)1, (i64)0);
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(op.val().seq()));
        if (d == (IRInsn*)0 || d.ops().count() == (u32)0)
            return no;
        String* o = d.op();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o.equals(String.withCString("Const")))
            return o0.kind() == (u8)OPK_IMMI ? ParIdx.of(true, (i64)0, o0.imm()) : no;
        if (o.equals(String.withCString("ZExt")) || o.equals(String.withCString("SExt")) || o.equals(String.withCString("Trunc")) || o.equals(String.withCString("Copy")))
            return parSymIndex(o0, iv, selfVal, def, depth + (u32)1);
        if (o.equals(String.withCString("Load")))
            {
            if (o0.kind() != (u8)OPK_USE || d.res() == (IRValue*)0 || !Lower.parIntType(d.res().ty()))
                return no;
            IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o0.val().seq()));
            if (fa == (IRInsn*)0 || !fa.op().equals(String.withCString("FieldAddr")) || fa.ops().count() < (u32)2)
                return no;
            IROperand* f0 = (IROperand*)fa.ops().get((u32)0);
            IROperand* f1 = (IROperand*)fa.ops().get((u32)1);
            if (f0.kind() != (u8)OPK_USE || f0.val() == (IRValue*)0 || selfVal == (IRValue*)0 || f0.val().seq() != selfVal.seq()
                || f1.kind() != (u8)OPK_IMMI || f1.imm() < (i64)3)
                return no;
            return ParIdx.sym(true, (i64)0, (i64)0, f1.imm(), (i64)1);
            }
        bool isAdd = o.equals(String.withCString("Add"));
        bool isSub = o.equals(String.withCString("Sub"));
        bool isMul = o.equals(String.withCString("Mul"));
        if ((!isAdd && !isSub && !isMul) || d.ops().count() < (u32)2)
            return no;
        ParIdx* a = parSymIndex(o0, iv, selfVal, def, depth + (u32)1);
        ParIdx* b = parSymIndex((IROperand*)d.ops().get((u32)1), iv, selfVal, def, depth + (u32)1);
        if (!a.affine || !b.affine)
            return no;
        if (isMul)
            {
            // Only by a constant: k*i times v is not a form.
            bool aConst = a.k == (i64)0 && a.slot < (i64)0;
            bool bConst = b.k == (i64)0 && b.slot < (i64)0;
            if (!aConst && !bConst)
                return no;
            ParIdx* s = aConst ? b : a;
            i64 fct = aConst ? a.c : b.c;
            ParIdx* r = ParIdx.sym(true, s.k * fct, s.c * fct, s.slot, s.m * fct);
            r.slot2 = s.slot2;
            r.m2 = s.m2 * fct;
            return r;
            }
        // The terms of both sides, merged by field: two at most, as the
        // reference.
        i64 sign = isSub ? (i64)-1 : (i64)1;
        i64 tsl[4];
        i64 tm[4];
        tsl[0] = a.slot; tm[0] = a.slot >= (i64)0 ? a.m : (i64)0;
        tsl[1] = a.slot2; tm[1] = a.m2;
        tsl[2] = b.slot; tm[2] = sign * (b.slot >= (i64)0 ? b.m : (i64)0);
        tsl[3] = b.slot2; tm[3] = sign * b.m2;
        i64 sl[4];
        i64 mm[4];
        u32 n = (u32)0;
        for (u32 t = (u32)0; t < (u32)4; t = t + (u32)1)
            {
            if (tm[t] == (i64)0)
                continue;
            u32 at = n;
            for (u32 q = (u32)0; q < n; q = q + (u32)1)
                if (sl[q] == tsl[t])
                    at = q;
            if (at == n)
                {
                sl[n] = tsl[t];
                mm[n] = (i64)0;
                n = n + (u32)1;
                }
            mm[at] = mm[at] + tm[t];
            }
        u32 kept = (u32)0;
        for (u32 q = (u32)0; q < n; q = q + (u32)1)
            if (mm[q] != (i64)0)
                {
                sl[kept] = sl[q];
                mm[kept] = mm[q];
                kept = kept + (u32)1;
                }
        if (kept > (u32)2)
            return no;
        if (kept == (u32)2 && sl[1] < sl[0])
            {
            i64 ts = sl[0]; sl[0] = sl[1]; sl[1] = ts;
            i64 tv = mm[0]; mm[0] = mm[1]; mm[1] = tv;
            }
        ParIdx* r = ParIdx.sym(true, a.k + sign * b.k, a.c + sign * b.c, kept > (u32)0 ? sl[0] : (i64)-1,
                               kept > (u32)0 ? mm[0] : (i64)0);
        r.slot2 = kept > (u32)1 ? sl[1] : (i64)0;
        r.m2 = kept > (u32)1 ? mm[1] : (i64)0;
        return r;
        }
    static bool parIntType(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("I16"))
            || t.equals(String.withCString("U16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
            || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"));
        }
    // Whether a read at r and a write at w (symbolic forms) can be settled by
    // the run, and the guard "slot:m:d0:k" if so (as the reference's
    // parGuardFor), else 0.
    static String* parGuardFor(ParIdx* r, ParIdx* w)
        {
        if (!r.affine || !w.affine || r.k != w.k || r.k == (i64)0 || r.m2 != (i64)0 || w.m2 != (i64)0)
            return (String*)0;
        if (r.slot >= (i64)0 && w.slot >= (i64)0 && r.slot != w.slot)
            return (String*)0;
        i64 sl = w.slot >= (i64)0 ? w.slot : r.slot;
        i64 mm = (w.slot >= (i64)0 ? w.m : (i64)0) - (r.slot >= (i64)0 ? r.m : (i64)0);
        if (sl < (i64)0 || mm == (i64)0)
            return (String*)0;
        String* g = String.withI64(sl);
        g.appendCString(":"); g.append(String.withI64(mm));
        g.appendCString(":"); g.append(String.withI64(w.c - r.c));
        g.appendCString(":"); g.append(String.withI64(r.k));
        return g;
        }

    // The general form where parGuardFor cannot settle a pair (unequal
    // strides, or a captured integer on each side): the run checks the
    // written and the read elements are disjoint ranges, or, with one stride,
    // the parGuardFor test. "x:<kw>:<cw>:<slotw>:<mw>:<kr>:<cr>:<slotr>:<mr>",
    // slot -1 (m 0) for a side with none. As the reference's
    // parIntervalGuardFor.
    static String* parIntervalGuardFor(ParIdx* r, ParIdx* w)
        {
        if (!r.affine || !w.affine || (r.k == (i64)0 && w.k == (i64)0))
            return (String*)0;
        if (r.k == w.k && r.slot < (i64)0 && w.slot < (i64)0)
            return (String*)0;
        if (r.k == w.k && ParIdx.sameTerms(r, w))
            return (String*)0;
        String* g = String.withCString("x:");
        g.append(String.withI64(w.k)); g.appendCString(":");
        g.append(String.withI64(w.c)); g.appendCString(":");
        g.append(String.withI64(w.slot >= (i64)0 ? w.slot : (i64)-1)); g.appendCString(":");
        g.append(String.withI64(w.slot >= (i64)0 ? w.m : (i64)0)); g.appendCString(":");
        g.append(String.withI64(r.k)); g.appendCString(":");
        g.append(String.withI64(r.c)); g.appendCString(":");
        g.append(String.withI64(r.slot >= (i64)0 ? r.slot : (i64)-1)); g.appendCString(":");
        g.append(String.withI64(r.slot >= (i64)0 ? r.m : (i64)0));
        // A second captured integer on either side, after both.
        if (r.m2 != (i64)0 || w.m2 != (i64)0)
            {
            g.appendCString(":"); g.append(String.withI64(w.m2 != (i64)0 ? w.slot2 : (i64)-1));
            g.appendCString(":"); g.append(String.withI64(w.m2));
            g.appendCString(":"); g.append(String.withI64(r.m2 != (i64)0 ? r.slot2 : (i64)-1));
            g.appendCString(":"); g.append(String.withI64(r.m2));
            }
        return g;
        }

    // The GCD test, on the "1 k c" / "0 0 0" forms the dependence check
    // keeps (mirrors parDependent in the reference): a read at r and a write
    // at w can meet across two work items unless they are the same element
    // of the same item, or k1*i1 + c1 == k2*i2 + c2 has no integer solution,
    // which is when gcd(k1, k2) does not divide c2 - c1. A form that is not
    // affine in i is taken as able to meet anything.
    static i64 parFormNum(String* s, u32 field)
        {
        u32 at = (u32)0;
        for (u32 f = (u32)0; f < field; f = f + (u32)1)
            {
            while (at < s.byteLength() && s.byteAt(at) != (u8)' ')
                at = at + (u32)1;
            at = at + (u32)1;
            }
        bool neg = at < s.byteLength() && s.byteAt(at) == (u8)'-';
        if (neg)
            at = at + (u32)1;
        i64 v = (i64)0;
        while (at < s.byteLength() && s.byteAt(at) >= (u8)'0' && s.byteAt(at) <= (u8)'9')
            {
            v = v * (i64)10 + (i64)(s.byteAt(at) - (u8)'0');
            at = at + (u32)1;
            }
        return neg ? (i64)0 - v : v;
        }
    static i64 parGcd(i64 a, i64 b)
        {
        if (a < (i64)0) a = (i64)0 - a;
        if (b < (i64)0) b = (i64)0 - b;
        while (b != (i64)0)
            {
            i64 t = a % b;
            a = b;
            b = t;
            }
        return a;
        }
    static bool parFormDep(String* r, String* w)
        {
        if (!r.hasPrefix(String.withCString("1 ")) || !w.hasPrefix(String.withCString("1 ")))
            return true;
        return Lower.parAffineDep(Lower.parFormNum(r, (u32)1), Lower.parFormNum(r, (u32)2),
                                  Lower.parFormNum(w, (u32)1), Lower.parFormNum(w, (u32)2));
        }
    static bool parAffineDep(i64 rk, i64 rc, i64 wk, i64 wc)
        {
        if (rk == wk && rc == wc)
            return false;
        i64 g = Lower.parGcd(rk, wk);
        i64 d = wc - rc;
        if (g == (i64)0)
            return false;
        return d % g == (i64)0;
        }

    final String* parShownIndex(bool affine, i64 k, i64 c)
        {
        if (!affine)
            return String.withCString(" at an index computed from data");
        String* s = String.withCString("[");
        if (k == (i64)1)
            s.appendCString("i");
        else if (k != (i64)0)
            {
            s.append(String.withI64(k));
            s.appendCString("*i");
            }
        if (k == (i64)0)
            s.append(String.withI64(c));
        else if (c > (i64)0)
            {
            s.appendCString(" + ");
            s.append(String.withI64(c));
            }
        else if (c < (i64)0)
            {
            s.appendCString(" - ");
            s.append(String.withI64((i64)0 - c));
            }
        s.appendCString("]");
        return s;
        }

    // The buffer an address indexes into, by name, or 0 when it is not one: a
    // captured array is a pointer ivar of the block's object, a global array
    // its symbol.
    final String* parBufferOf(IROperand* base, IRValue* selfVal, Array* ivars, Map* def)
        {
        if (base.kind() != (u8)OPK_USE)
            return (String*)0;
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(base.val().seq()));
        // Through a pointer cast (the C path casts its untyped pointers
        // where they are used).
        while (d != (IRInsn*)0 && d.op().equals(String.withCString("Bitcast")) && d.ops().count() == (u32)1
               && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            d = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)d.ops().get((u32)0)).val().seq()));
        if (d == (IRInsn*)0 || d.ops().count() == (u32)0)
            return (String*)0;
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (d.op().equals(String.withCString("AddrOf")) && o0.kind() == (u8)OPK_SYM)
            {
            IRSymbol* s = (IRSymbol*)_parSyms.get((Hashable*)o0.name());
            if (s != (IRSymbol*)0 && s.kind() == (u8)SYM_DATAGLOBAL)
                return o0.name();
            return (String*)0;
            }
        if (!d.op().equals(String.withCString("Load")) || o0.kind() != (u8)OPK_USE)
            return (String*)0;
        IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o0.val().seq()));
        if (fa == (IRInsn*)0 || !fa.op().equals(String.withCString("FieldAddr")) || fa.ops().count() < (u32)2)
            return (String*)0;
        IROperand* f0 = (IROperand*)fa.ops().get((u32)0);
        IROperand* f1 = (IROperand*)fa.ops().get((u32)1);
        // `self`: the body refers to its first parameter through a value it
        // does not define (the parameters are made again for the body, so
        // params()[0] is not the same object).
        if (f0.kind() != (u8)OPK_USE || f0.val() == (IRValue*)0 || def.get((Hashable*)String.withU32(f0.val().seq())) != (Object*)0 || f1.kind() != (u8)OPK_IMMI)
            return (String*)0;
        i64 k = f1.imm();
        if (k < (i64)1 || k > (i64)ivars.count())
            return (String*)0;
        return (String*)ivars.get((u32)(k - (i64)1));
        }

    // A monomial's atoms in byte order: the product's name. As the
    // reference's sorted '.'-joined atoms (the atoms are one letter each).
    final String* parMono(String* a, String* b)
        {
        String* all = String.withString(a);
        all.append(b);
        String* out = String.withCString("");
        u32 n = all.byteLength();
        Array* used = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            used.add((Object*)Number.with((u32)0));
        for (u32 r = (u32)0; r < n; r = r + (u32)1)
            {
            u32 best = n;
            for (u32 i = (u32)0; i < n; i = i + (u32)1)
                {
                if (((Number*)used.get(i)).asU32() != (u32)0)
                    continue;
                if (best == n || all.byteAt(i) < all.byteAt(best))
                    best = i;
                }
            used.set(best, (Object*)Number.with((u32)1));
            out.appendByte(all.byteAt(best));
            }
        return out;
        }

    // The decimal value of a placeholder word (`gw=640`).
    static i64 parWordI64(String* s)
        {
        i64 v = (i64)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) >= (u8)'0' && s.byteAt(i) <= (u8)'9')
                v = v * (i64)10 + (i64)(s.byteAt(i) - (u8)'0');
        return v;
        }

    final i64 parCoef(Map* p, String* m)
        {
        Number* v = (Number*)p.get((Hashable*)m);
        return v == (Number*)0 ? (i64)0 : v.asI64();
        }

    final Map* parPoly1(string m, i64 c)
        {
        Map* p = new Map();
        p.set((Hashable*)String.withCString(m), (Object*)Number.with(c));
        return p;
        }

    final bool parIsAtom(Map* p, string a)
        {
        return p.count() == (u32)1 && parCoef(p, String.withCString(a)) == (i64)1;
        }

    // A `par :grid` block's index as a polynomial over its point and size:
    // atoms i (the flat index), W and H (the par$w and par$h ivars), x (i % W),
    // q (i / W), y ((i / W) % H) and z (i / (W*H)); "" is the constant. 0 when
    // the index is anything else. A captured integer (another field of the
    // block's object, as parSymIndex takes it) is the atom "#<field>", only ever
    // times a constant. As the reference's gridPoly.
    final Map* parGridPoly(IROperand* op, IRValue* iv, IRValue* selfVal, Array* ivars, Map* def, u32 depth)
        {
        if (depth > (u32)32)
            return (Map*)0;
        if (op.kind() == (u8)OPK_IMMI)
            return parPoly1("", op.imm());
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            return (Map*)0;
        if (op.val().seq() == iv.seq())
            return parPoly1("i", (i64)1);
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(op.val().seq()));
        if (d == (IRInsn*)0 || d.ops().count() == (u32)0)
            return (Map*)0;
        String* o = d.op();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o.equals(String.withCString("Const")))
            return o0.kind() == (u8)OPK_IMMI ? parPoly1("", o0.imm()) : (Map*)0;
        if (o.equals(String.withCString("ZExt")) || o.equals(String.withCString("SExt")) || o.equals(String.withCString("Trunc")) || o.equals(String.withCString("Copy")))
            return parGridPoly(o0, iv, selfVal, ivars, def, depth + (u32)1);
        if (o.equals(String.withCString("Load")))
            {
            // An ivar of the block's object: the grid's width or height.
            String* n = parBufferOf(op, (IRValue*)0, ivars, def);
            if (n != (String*)0 && n.equals(String.withCString("par$w")))
                return parPoly1("W", (i64)1);
            if (n != (String*)0 && n.equals(String.withCString("par$h")))
                return parPoly1("H", (i64)1);
            // A captured integer: the same test as parSymIndex's.
            if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0 || d.res() == (IRValue*)0 || !Lower.parIntType(d.res().ty()))
                return (Map*)0;
            IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o0.val().seq()));
            if (fa == (IRInsn*)0 || !fa.op().equals(String.withCString("FieldAddr")) || fa.ops().count() < (u32)2)
                return (Map*)0;
            IROperand* f0 = (IROperand*)fa.ops().get((u32)0);
            IROperand* f1 = (IROperand*)fa.ops().get((u32)1);
            if (f0.kind() != (u8)OPK_USE || f0.val() == (IRValue*)0 || selfVal == (IRValue*)0 || f0.val().seq() != selfVal.seq()
                || f1.kind() != (u8)OPK_IMMI || f1.imm() < (i64)3)
                return (Map*)0;
            Map* cp = new Map();
            String* cm = String.withCString("#");
            cm.append(String.withI64(f1.imm()));
            cp.set((Hashable*)cm, (Object*)Number.with((i64)1));
            return cp;
            }
        if (d.ops().count() < (u32)2)
            return (Map*)0;
        bool isRem = o.equals(String.withCString("URem"));
        bool isDiv = o.equals(String.withCString("UDiv"));
        bool isAdd = o.equals(String.withCString("Add"));
        bool isSub = o.equals(String.withCString("Sub"));
        bool isMul = o.equals(String.withCString("Mul"));
        if (!isRem && !isDiv && !isAdd && !isSub && !isMul)
            return (Map*)0;
        Map* a = parGridPoly(o0, iv, selfVal, ivars, def, depth + (u32)1);
        Map* b = parGridPoly((IROperand*)d.ops().get((u32)1), iv, selfVal, ivars, def, depth + (u32)1);
        if (a == (Map*)0 || b == (Map*)0)
            return (Map*)0;
        if (isRem && parIsAtom(a, "i") && parIsAtom(b, "W"))
            return parPoly1("x", (i64)1);
        if (isRem && parIsAtom(a, "q") && parIsAtom(b, "H"))
            return parPoly1("y", (i64)1);
        if (isDiv && parIsAtom(a, "i") && parIsAtom(b, "W"))
            return parPoly1("q", (i64)1);
        if (isDiv && parIsAtom(a, "i") && parIsAtom(b, "HW"))
            return parPoly1("z", (i64)1);
        if (isRem || isDiv)
            return (Map*)0;
        Map* r = new Map();
        Array* ak = a.allKeys();
        Array* bk = b.allKeys();
        if (isMul)
            {
            // A captured integer only times a constant.
            if ((parHasCap(a) && !parIsConst(b)) || (parHasCap(b) && !parIsConst(a)))
                return (Map*)0;
            for (u32 i = (u32)0; i < ak.count(); i = i + (u32)1)
                for (u32 j = (u32)0; j < bk.count(); j = j + (u32)1)
                    {
                    String* ma = (String*)ak.get(i);
                    String* mb = (String*)bk.get(j);
                    String* m = parMono(ma, mb);
                    r.set((Hashable*)m, (Object*)Number.with(parCoef(r, m) + parCoef(a, ma) * parCoef(b, mb)));
                    }
            }
        else
            {
            for (u32 i = (u32)0; i < ak.count(); i = i + (u32)1)
                {
                String* m = (String*)ak.get(i);
                r.set((Hashable*)m, (Object*)Number.with(parCoef(a, m)));
                }
            i64 sign = isSub ? (i64)-1 : (i64)1;
            for (u32 j = (u32)0; j < bk.count(); j = j + (u32)1)
                {
                String* m = (String*)bk.get(j);
                r.set((Hashable*)m, (Object*)Number.with(parCoef(r, m) + sign * parCoef(b, m)));
                }
            }
        Array* rk = r.allKeys();
        for (u32 i = (u32)0; i < rk.count(); i = i + (u32)1)
            {
            String* m = (String*)rk.get(i);
            if (m.byteLength() > (u32)0 && parCoef(r, m) == (i64)0)
                r.remove((Hashable*)m);
            }
        return r;
        }

    final bool parHasCap(Map* p)
        {
        Array* ks = p.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            if (((String*)ks.get(i)).hasPrefix(String.withCString("#")))
                return true;
        return false;
        }

    final bool parIsConst(Map* p)
        {
        return p.count() == (u32)0 || (p.count() == (u32)1 && p.get((Hashable*)String.withCString("")) != (Object*)0);
        }

    // Does the polynomial (without its constant) equal k times one form?
    final i64 parGridForm(Map* p, Array* form)
        {
        if (p.count() != form.count())
            return (i64)0;
        i64 k = parCoef(p, (String*)form.get((u32)0));
        if (k == (i64)0)
            return (i64)0;
        for (u32 i = (u32)0; i < form.count(); i = i + (u32)1)
            if (parCoef(p, (String*)form.get(i)) != k)
                return (i64)0;
        return k;
        }

    final Array* parForm(string a, string b, string c)
        {
        Array* f = new Array();
        f.add((Object*)String.withCString(a));
        if (b != (string)0) f.add((Object*)String.withCString(b));
        if (c != (string)0) f.add((Object*)String.withCString(c));
        return f;
        }

    // The index as k*i + c when its polynomial is k times the flat index of
    // the point plus a constant: i, x + W*q, and x + W*y in a 2-D grid or
    // x + W*y + W*H*z in a 3-D one (a par$d ivar). As the reference.
    final ParIdx* parGridIndex(IROperand* op, IRValue* iv, IRValue* selfVal, Array* ivars, Map* def)
        {
        bool hasW = false;
        bool threeD = false;
        for (u32 i = (u32)0; i < ivars.count(); i = i + (u32)1)
            {
            String* n = (String*)ivars.get(i);
            if (n.equals(String.withCString("par$w"))) hasW = true;
            if (n.equals(String.withCString("par$d"))) threeD = true;
            }
        if (!hasW)
            return ParIdx.of(false, (i64)0, (i64)0);
        Map* p = parGridPoly(op, iv, selfVal, ivars, def, (u32)0);
        if (p == (Map*)0 || parHasCap(p))
            return ParIdx.of(false, (i64)0, (i64)0);
        i64 c = parCoef(p, String.withCString(""));
        p.remove((Hashable*)String.withCString(""));
        return parGridMatch(p, c, threeD, (i64)-1, (i64)0, (i64)0, (i64)0);
        }

    // The grid index with up to two captured integers in it, as parSymIndex
    // gives the loop form's: k*i + c + m*field (+ m2*field2), the fields in
    // order. As the reference's gridSymIndexOf.
    final ParIdx* parGridSym(IROperand* op, IRValue* iv, IRValue* selfVal, Array* ivars, Map* def)
        {
        bool hasW = false;
        bool threeD = false;
        for (u32 i = (u32)0; i < ivars.count(); i = i + (u32)1)
            {
            String* n = (String*)ivars.get(i);
            if (n.equals(String.withCString("par$w"))) hasW = true;
            if (n.equals(String.withCString("par$d"))) threeD = true;
            }
        if (!hasW)
            return ParIdx.of(false, (i64)0, (i64)0);
        Map* p = parGridPoly(op, iv, selfVal, ivars, def, (u32)0);
        if (p == (Map*)0)
            return ParIdx.of(false, (i64)0, (i64)0);
        Array* slots = new Array();
        Array* ks = p.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            String* m = (String*)ks.get(i);
            if (m.hasPrefix(String.withCString("#")))
                {
                i64 v = (i64)0;
                for (u32 j = (u32)1; j < m.byteLength(); j = j + (u32)1)
                    v = v * (i64)10 + (i64)(m.byteAt(j) - (u8)'0');
                slots.add((Object*)Number.with(v));
                }
            }
        if (slots.count() == (u32)0 || slots.count() > (u32)2)
            return ParIdx.of(false, (i64)0, (i64)0);
        i64 s1 = ((Number*)slots.get((u32)0)).asI64();
        i64 s2 = slots.count() > (u32)1 ? ((Number*)slots.get((u32)1)).asI64() : (i64)0;
        if (slots.count() > (u32)1 && s2 < s1)
            {
            i64 t = s1;
            s1 = s2;
            s2 = t;
            }
        String* k1 = String.withCString("#");
        k1.append(String.withI64(s1));
        i64 m1 = parCoef(p, k1);
        p.remove((Hashable*)k1);
        i64 m2 = (i64)0;
        if (slots.count() > (u32)1)
            {
            String* k2 = String.withCString("#");
            k2.append(String.withI64(s2));
            m2 = parCoef(p, k2);
            p.remove((Hashable*)k2);
            }
        i64 c = parCoef(p, String.withCString(""));
        p.remove((Hashable*)String.withCString(""));
        return parGridMatch(p, c, threeD, s1, m1, slots.count() > (u32)1 ? s2 : (i64)0, m2);
        }

    // k*i + c (+ the captured terms) when p is k times a form of the flat
    // index: i, x + W*q, and x + W*y in a 2-D grid or x + W*y + W*H*z in a
    // 3-D one; a constant grid's `640 * y` renamed first.
    final ParIdx* parGridMatch(Map* p, i64 c, bool threeD, i64 s1, i64 m1, i64 s2, i64 m2)
        {
        // A constant grid: `640 * y + x` is the flat index as `W * y + x` is
        // (the reference's parRenameConstantGrid).
        if (_mGridW > (i64)0)
            {
            i64 cy = parCoef(p, String.withCString("y"));
            if (cy != (i64)0 && cy % _mGridW == (i64)0)
                {
                p.set((Hashable*)String.withCString("Wy"), (Object*)Number.with(parCoef(p, String.withCString("Wy")) + cy / _mGridW));
                p.remove((Hashable*)String.withCString("y"));
                }
            i64 cq = parCoef(p, String.withCString("q"));
            if (cq != (i64)0 && cq % _mGridW == (i64)0)
                {
                p.set((Hashable*)String.withCString("Wq"), (Object*)Number.with(parCoef(p, String.withCString("Wq")) + cq / _mGridW));
                p.remove((Hashable*)String.withCString("q"));
                }
            i64 cz = parCoef(p, String.withCString("z"));
            if (threeD && _mGridH > (i64)0 && cz != (i64)0 && cz % (_mGridW * _mGridH) == (i64)0)
                {
                p.set((Hashable*)String.withCString("HWz"), (Object*)Number.with(parCoef(p, String.withCString("HWz")) + cz / (_mGridW * _mGridH)));
                p.remove((Hashable*)String.withCString("z"));
                }
            }
        Array* forms = new Array();
        forms.add((Object*)parForm("i", (string)0, (string)0));
        forms.add((Object*)parForm("Wq", "x", (string)0));
        if (threeD) forms.add((Object*)parForm("HWz", "Wy", "x"));
        else forms.add((Object*)parForm("Wy", "x", (string)0));
        for (u32 i = (u32)0; i < forms.count(); i = i + (u32)1)
            {
            i64 k = parGridForm(p, (Array*)forms.get(i));
            if (k != (i64)0)
                {
                ParIdx* x = ParIdx.of(true, k, c);
                if (m1 != (i64)0)
                    {
                    x.slot = s1;
                    x.m = m1;
                    x.slot2 = s2;
                    x.m2 = m2;
                    }
                return x;
                }
            }
        return ParIdx.of(false, (i64)0, (i64)0);
        }

    // The work item's index: the phi the loop's guard compares (not simply
    // the first phi, which may be a reduction's accumulator). Mirrors the
    // original.
    final IRValue* parInductionVariable(IRFunc* f, Map* def, IRValue* firstPhi)
        {
        IRValue* ivGuard = (IRValue*)0;
        for (u32 gb = (u32)0; gb < f.blocks().count() && ivGuard == (IRValue*)0; gb = gb + (u32)1) {
            IRBlock* gbb = (IRBlock*)f.blocks().get(gb);
            for (u32 gi = (u32)0; gi < gbb.insns().count() && ivGuard == (IRValue*)0; gi = gi + (u32)1) {
                IRInsn* gb2 = (IRInsn*)gbb.insns().get(gi);
                if (!gb2.op().equals(String.withCString("ICmp")))
                    continue;
                for (u32 q = (u32)0; q < gb2.ops().count(); q = q + (u32)1) {
                    IROperand* o = (IROperand*)gb2.ops().get(q);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    IRInsn* dd = (IRInsn*)def.get((Hashable*)String.withU32(o.val().seq()));
                    if (dd != (IRInsn*)0 && dd.op().equals(String.withCString("Phi")))
                        { ivGuard = o.val(); break; }
                }
            }
        }
        return ivGuard != (IRValue*)0 ? ivGuard : firstPhi;
        }
    // The guards as header words, `guard=<offset>:<bytes>:<m>:<d0>:<k>` (as
    // the reference's guardWordsIn).
    final Array* parSplitColons(String* g)
        {
        Array* out = new Array();
        String* cur = new String();
        for (u32 i = (u32)0; i < g.byteLength(); i = i + (u32)1)
            {
            if (g.byteAt(i) == (u8)':')
                {
                out.add((Object*)cur);
                cur = new String();
                }
            else
                cur.appendByte(g.byteAt(i));
            }
        out.add((Object*)cur);
        return out;
        }

    // One side of a guardx word: k:c:offset:bytes:m, offset -1 when the
    // side has no captured integer.
    final void parGuardSide(String* words, IRLayout* lay, Array* p, u32 at)
        {
        String* sl = (String*)p.get(at + (u32)2);
        i64 q = sl.byteLength() > (u32)0 && sl.byteAt((u32)0) == (u8)'-' ? (i64)-1 : parWordI64(sl);
        words.append((String*)p.get(at));
        words.appendCString(":");
        words.append((String*)p.get(at + (u32)1));
        if (q < (i64)0 || q >= (i64)lay.fieldCount())
            {
            words.appendCString(":-1:0:0");
            return;
            }
        words.appendCString(":");
        words.append(String.withU32(lay.offsetAt((u32)q)));
        words.appendCString(":");
        words.append(String.withU32(self.mslWidth(lay.typeAt((u32)q))));
        words.appendCString(":");
        words.append((String*)p.get(at + (u32)3));
        }

    // ":offset:bytes:m" of a second captured integer, ":-1:0:0" for none.
    final void parGuardTerm(String* words, IRLayout* lay, Array* p, u32 at)
        {
        String* sl = (String*)p.get(at);
        i64 q = sl.byteLength() > (u32)0 && sl.byteAt((u32)0) == (u8)'-' ? (i64)-1 : parWordI64(sl);
        if (q < (i64)0 || q >= (i64)lay.fieldCount())
            {
            words.appendCString(":-1:0:0");
            return;
            }
        words.appendCString(":");
        words.append(String.withU32(lay.offsetAt((u32)q)));
        words.appendCString(":");
        words.append(String.withU32(self.mslWidth(lay.typeAt((u32)q))));
        words.appendCString(":");
        words.append((String*)p.get(at + (u32)1));
        }

    final String* parGuardWords(IRFunc* f, Array* guards)
        {
        String* words = String.withCString("");
        if (guards == (Array*)0 || guards.count() == (u32)0 || f.params().count() == (u32)0)
            return words;
        IRLayout* lay = self.mslLayoutOf(mslPointee(((IRValue*)f.params().get((u32)0)).ty()));
        if (lay == (IRLayout*)0)
            return words;
        for (u32 i = (u32)0; i < guards.count(); i = i + (u32)1)
            {
            String* g = (String*)guards.get(i);
            // `guardx=<kw>:<cw>:<offw>:<bytesw>:<mw>:<kr>:<cr>:<offr>:<bytesr>:<mr>`.
            if (g.hasPrefix(String.withCString("x:")))
                {
                Array* p = parSplitColons(g);
                if (p.count() != (u32)9 && p.count() != (u32)13)
                    continue;
                words.appendCString(" guardx=");
                parGuardSide(words, lay, p, (u32)1);
                words.appendCString(":");
                parGuardSide(words, lay, p, (u32)5);
                // A second captured integer a side: offset:bytes:m, after both.
                if (p.count() == (u32)13)
                    {
                    parGuardTerm(words, lay, p, (u32)9);
                    parGuardTerm(words, lay, p, (u32)11);
                    }
                continue;
                }
            u32 c1 = (u32)0;
            i64 sl = (i64)0;
            while (c1 < g.byteLength() && g.byteAt(c1) != (u8)':')
                {
                sl = sl * (i64)10 + (i64)(g.byteAt(c1) - (u8)'0');
                c1 = c1 + (u32)1;
                }
            if (sl >= (i64)lay.fieldCount())
                continue;
            words.appendCString(" guard=");
            words.append(String.withU32(lay.offsetAt((u32)sl)));
            words.appendCString(":");
            words.append(String.withU32(self.mslWidth(lay.typeAt((u32)sl))));
            words.append(g.substringBytes(c1, g.byteLength() - c1));
            }
        return words;
        }

    final String* parFootprintWords(IRFunc* f, Array* ivars)
        {
        Map* def = new Map();
        Map* phiBlk = new Map();
        IRValue* firstPhi = (IRValue*)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ph = (IRInsn*)bb.phis().get(i);
                if (ph.res() == (IRValue*)0)
                    continue;
                def.set((Hashable*)String.withU32(ph.res().seq()), (Object*)ph);
                phiBlk.set((Hashable*)String.withU32(ph.res().seq()), (Object*)bb);
                if (firstPhi == (IRValue*)0)
                    firstPhi = ph.res();
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0)
                    def.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
                }
            }
        if (firstPhi == (IRValue*)0 || f.params().count() == (u32)0)
            return String.withCString("");
        IRValue* iv = parInductionVariable(f, def, firstPhi);
        IRValue* selfVal = (IRValue*)f.params().get((u32)0);
        // Per buffer, in first-seen order: k, the lowest and highest c, and
        // whether every access was affine with that k.
        Array* order = new Array();
        Map* fpK = new Map();
        Map* fpLo = new Map();
        Map* fpHi = new Map();
        Map* fpOk = new Map();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                String* op = ip.op();
                bool isStore = op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile"));
                bool isLoad = op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile"));
                if ((!isStore && !isLoad) || ip.ops().count() == (u32)0)
                    continue;
                IROperand* a0 = (IROperand*)ip.ops().get((u32)0);
                if (a0.kind() != (u8)OPK_USE)
                    continue;
                IRInsn* ea = (IRInsn*)def.get((Hashable*)String.withU32(a0.val().seq()));
                if (ea == (IRInsn*)0 || !ea.op().equals(String.withCString("ElementAddr")) || ea.ops().count() < (u32)2)
                    continue;
                // Element addresses of one type nested (a row of C's a[R][C],
                // then its element; a flattened struct's element, then its
                // field): their indices summed, into the array outermost.
                IROperand* baseOp = (IROperand*)ea.ops().get((u32)0);
                Array* terms = new Array();
                terms.add(ea.ops().get((u32)1));
                for (u32 dd = (u32)0; dd < (u32)4 && baseOp.kind() == (u8)OPK_USE; dd = dd + (u32)1)
                    {
                    IRInsn* inner = (IRInsn*)def.get((Hashable*)String.withU32(baseOp.val().seq()));
                    if (inner == (IRInsn*)0 || !inner.op().equals(String.withCString("ElementAddr")) || inner.ops().count() < (u32)2
                        || inner.res() == (IRValue*)0 || ea.res() == (IRValue*)0 || !inner.res().ty().equals(ea.res().ty()))
                        break;
                    terms.add(inner.ops().get((u32)1));
                    baseOp = (IROperand*)inner.ops().get((u32)0);
                    }
                String* buf = parBufferOf(baseOp, selfVal, ivars, def);
                if (buf == (String*)0)
                    continue;
                ParIdx* px = (ParIdx*)0;
                i64 rlo = (i64)0;
                i64 rhi = (i64)0;
                if (terms.count() == (u32)1)
                    {
                    px = parIndex((IROperand*)ea.ops().get((u32)1), iv, def, (u32)0);
                    if (!px.affine)
                        px = parGridIndex((IROperand*)ea.ops().get((u32)1), iv, selfVal, ivars, def);
                    rlo = px.c;
                    rhi = px.c;
                    }
                // Else, or where that is not affine: k * i plus terms whose
                // range is known (an inner counting loop's counter).
                if (px == (ParIdx*)0 || !px.affine)
                    {
                    i64 rk = (i64)0;
                    bool ok = true;
                    rlo = (i64)0;
                    rhi = (i64)0;
                    for (u32 q = (u32)0; q < terms.count() && ok; q = q + (u32)1)
                        {
                        i64 tk = (i64)0;
                        i64 tl = (i64)0;
                        i64 th = (i64)0;
                        ok = parRangeIndex((IROperand*)terms.get(q), iv, def, phiBlk, (u32)0, &tk, &tl, &th);
                        rk = rk + tk;
                        rlo = rlo + tl;
                        rhi = rhi + th;
                        }
                    px = ParIdx.of(ok, rk, rlo);
                    }
                if (fpOk.get((Hashable*)buf) == (Object*)0)
                    {
                    order.add((Object*)buf);
                    fpK.set((Hashable*)buf, (Object*)Number.withI64(px.k));
                    fpLo.set((Hashable*)buf, (Object*)Number.withI64(rlo));
                    fpHi.set((Hashable*)buf, (Object*)Number.withI64(rhi));
                    fpOk.set((Hashable*)buf, (Object*)Number.withI64(px.affine && px.k != (i64)0 ? (i64)1 : (i64)0));
                    continue;
                    }
                if (!px.affine || px.k == (i64)0 || px.k != ((Number*)fpK.get((Hashable*)buf)).asI64())
                    fpOk.set((Hashable*)buf, (Object*)Number.withI64((i64)0));
                else
                    {
                    if (rlo < ((Number*)fpLo.get((Hashable*)buf)).asI64())
                        fpLo.set((Hashable*)buf, (Object*)Number.withI64(rlo));
                    if (rhi > ((Number*)fpHi.get((Hashable*)buf)).asI64())
                        fpHi.set((Hashable*)buf, (Object*)Number.withI64(rhi));
                    }
                }
            }
        String* words = new String();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* buf = (String*)order.get(i);
            if (((Number*)fpOk.get((Hashable*)buf)).asI64() == (i64)0)
                continue;
            u32 at = (u32)0;
            bool found = false;
            for (u32 j = (u32)0; j < ivars.count() && !found; j = j + (u32)1)
                if (((String*)ivars.get(j)).equals(buf))
                    { at = j; found = true; }
            // A captured array is ivar 2 + <index> (after lo and hi); a
            // global is named as the glob= word names it.
            if (found && at < (u32)2)
                continue;
            words.appendCString(found ? " fp=" : " gfp=");
            if (found)
                words.append(String.withU32(at - (u32)2));
            else
                words.append(buf);
            words.appendCString(":"); words.append(String.withI64(((Number*)fpK.get((Hashable*)buf)).asI64()));
            words.appendCString(":"); words.append(String.withI64(((Number*)fpLo.get((Hashable*)buf)).asI64()));
            words.appendCString(":"); words.append(String.withI64(((Number*)fpHi.get((Hashable*)buf)).asI64() + (i64)1));
            }
        return words;
        }

    // An index term as k * i plus a value in [lo, hi]: a constant, i, an
    // extension or sum or difference of such, a product with a constant, or
    // an inner counting loop's induction phi (from a constant, by a positive
    // constant step, while below a constant).
    final bool parRangeIndex(IROperand* op, IRValue* iv, Map* def, Map* phiBlk, u32 depth, i64* k, i64* lo, i64* hi)
        {
        k[0] = (i64)0;
        if (depth > (u32)16)
            return false;
        if (op.kind() == (u8)OPK_IMMI)
            {
            lo[0] = op.imm();
            hi[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0)
            return false;
        if (op.val().seq() == iv.seq())
            {
            k[0] = (i64)1;
            lo[0] = (i64)0;
            hi[0] = (i64)0;
            return true;
            }
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(op.val().seq()));
        if (d == (IRInsn*)0 || d.ops().count() == (u32)0)
            return false;
        String* o = d.op();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o.equals(String.withCString("Const")))
            {
            if (o0.kind() != (u8)OPK_IMMI)
                return false;
            lo[0] = o0.imm();
            hi[0] = o0.imm();
            return true;
            }
        if (o.equals(String.withCString("ZExt")) || o.equals(String.withCString("SExt")) || o.equals(String.withCString("Copy")))
            {
            if (!parRangeIndex(o0, iv, def, phiBlk, depth + (u32)1, k, lo, hi))
                return false;
            return o.equals(String.withCString("SExt")) || o.equals(String.withCString("Copy")) || (lo[0] >= (i64)0 && k[0] == (i64)0);
            }
        if ((o.equals(String.withCString("Add")) || o.equals(String.withCString("Sub")) || o.equals(String.withCString("Mul"))) && d.ops().count() == (u32)2)
            {
            i64 ak = (i64)0; i64 al = (i64)0; i64 ah = (i64)0;
            i64 bk = (i64)0; i64 bl = (i64)0; i64 bh = (i64)0;
            if (!parRangeIndex(o0, iv, def, phiBlk, depth + (u32)1, &ak, &al, &ah)
                || !parRangeIndex((IROperand*)d.ops().get((u32)1), iv, def, phiBlk, depth + (u32)1, &bk, &bl, &bh))
                return false;
            if (o.equals(String.withCString("Add")))
                {
                k[0] = ak + bk; lo[0] = al + bl; hi[0] = ah + bh;
                return true;
                }
            if (o.equals(String.withCString("Sub")))
                {
                k[0] = ak - bk; lo[0] = al - bh; hi[0] = ah - bl;
                return true;
                }
            // A product with a constant (one side a single value, no i).
            i64 m = (i64)0;
            if (bk == (i64)0 && bl == bh) { m = bl; k[0] = ak * m; lo[0] = al * m; hi[0] = ah * m; }
            else if (ak == (i64)0 && al == ah) { m = al; k[0] = bk * m; lo[0] = bl * m; hi[0] = bh * m; }
            else
                return false;
            if (m < (i64)0)
                {
                i64 t = lo[0]; lo[0] = hi[0]; hi[0] = t;
                }
            return true;
            }
        // A multiply by a power of two, as the optimiser leaves it.
        if (o.equals(String.withCString("Shl")) && d.ops().count() == (u32)2)
            {
            IROperand* sh = (IROperand*)d.ops().get((u32)1);
            i64 n = (i64)0 - (i64)1;
            if (sh.kind() == (u8)OPK_IMMI)
                n = sh.imm();
            else if (sh.kind() == (u8)OPK_USE)
                {
                IRInsn* sd = (IRInsn*)def.get((Hashable*)String.withU32(sh.val().seq()));
                if (sd != (IRInsn*)0 && sd.op().equals(String.withCString("Const")) && ((IROperand*)sd.ops().get((u32)0)).kind() == (u8)OPK_IMMI)
                    n = ((IROperand*)sd.ops().get((u32)0)).imm();
                }
            if (n < (i64)0 || n > (i64)30)
                return false;
            if (!parRangeIndex(o0, iv, def, phiBlk, depth + (u32)1, k, lo, hi))
                return false;
            i64 m = (i64)1 << n;
            k[0] = k[0] * m;
            lo[0] = lo[0] * m;
            hi[0] = hi[0] * m;
            return true;
            }
        if (o.equals(String.withCString("Phi")) && d.ops().count() == (u32)4)
            return parPhiRange(d, def, phiBlk, lo, hi);
        return false;
        }

    final bool parPhiRange(IRInsn* phi, Map* def, Map* phiBlk, i64* lo, i64* hi)
        {
        IRValue* pv = phi.res();
        IRBlock* H = (IRBlock*)phiBlk.get((Hashable*)String.withU32(pv.seq()));
        if (H == (IRBlock*)0)
            return false;
        i64 start = (i64)0;
        bool haveStart = false;
        bool stepped = false;
        for (u32 e = (u32)0; e < (u32)2; e = e + (u32)1)
            {
            IROperand* ev = (IROperand*)phi.ops().get(e * (u32)2 + (u32)1);
            if (ev.kind() == (u8)OPK_IMMI)
                {
                start = ev.imm();
                haveStart = true;
                continue;
                }
            if (ev.kind() != (u8)OPK_USE || ev.val() == (IRValue*)0)
                return false;
            IRInsn* ed = (IRInsn*)def.get((Hashable*)String.withU32(ev.val().seq()));
            if (ed == (IRInsn*)0)
                return false;
            if (ed.op().equals(String.withCString("Const")) && ((IROperand*)ed.ops().get((u32)0)).kind() == (u8)OPK_IMMI)
                {
                start = ((IROperand*)ed.ops().get((u32)0)).imm();
                haveStart = true;
                continue;
                }
            IROperand* a0 = ed.ops().count() == (u32)2 ? (IROperand*)ed.ops().get((u32)0) : (IROperand*)0;
            IROperand* a1 = ed.ops().count() == (u32)2 ? (IROperand*)ed.ops().get((u32)1) : (IROperand*)0;
            if (ed.op().equals(String.withCString("Add")) && a0 != (IROperand*)0 && a0.kind() == (u8)OPK_USE && a0.val() == pv
                && a1.kind() == (u8)OPK_IMMI && a1.imm() > (i64)0)
                {
                stepped = true;
                continue;
                }
            return false;
            }
        if (!haveStart || !stepped)
            return false;
        // The test in the phi's block: pv < bound, the body on the true edge
        // and the exit on the false (the header's own CondBranch).
        IRInsn* t = H.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)t.ops().get((u32)0);
        IRInsn* g = c0.kind() == (u8)OPK_USE ? (IRInsn*)def.get((Hashable*)String.withU32(c0.val().seq())) : (IRInsn*)0;
        if (g == (IRInsn*)0 || !g.op().equals(String.withCString("ICmp")) || g.ops().count() < (u32)2 || g.pred() == (String*)0)
            return false;
        IROperand* g0 = (IROperand*)g.ops().get((u32)0);
        IROperand* g1 = (IROperand*)g.ops().get((u32)1);
        // Or rotated, the test at the bottom on the next value: pv + step
        // < bound loops back to the phi's own block.
        bool rotated = false;
        if (g0.kind() == (u8)OPK_USE && g0.val() != pv)
            {
            IRInsn* nd = (IRInsn*)def.get((Hashable*)String.withU32(g0.val().seq()));
            IROperand* t1 = (IROperand*)t.ops().get((u32)1);
            if (nd != (IRInsn*)0 && nd.op().equals(String.withCString("Add")) && nd.ops().count() == (u32)2
                && ((IROperand*)nd.ops().get((u32)0)).kind() == (u8)OPK_USE && ((IROperand*)nd.ops().get((u32)0)).val() == pv
                && t1.kind() == (u8)OPK_BLOCK && t1.blk() == H)
                rotated = true;
            else
                return false;
            }
        if (g0.kind() != (u8)OPK_USE || (g0.val() != pv && !rotated))
            return false;
        i64 bound = (i64)0;
        if (g1.kind() == (u8)OPK_IMMI)
            bound = g1.imm();
        else
            {
            IRInsn* bd = g1.kind() == (u8)OPK_USE ? (IRInsn*)def.get((Hashable*)String.withU32(g1.val().seq())) : (IRInsn*)0;
            if (bd == (IRInsn*)0 || !bd.op().equals(String.withCString("Const")) || ((IROperand*)bd.ops().get((u32)0)).kind() != (u8)OPK_IMMI)
                return false;
            bound = ((IROperand*)bd.ops().get((u32)0)).imm();
            }
        String* pr = g.pred();
        bool lt = pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("ULT"));
        bool le = pr.equals(String.withCString("SLE")) || pr.equals(String.withCString("ULE"));
        if ((!lt && !le) || start < (i64)0)
            return false;
        lo[0] = start;
        hi[0] = le ? bound : bound - (i64)1;
        // A rotated loop runs its body once before its first test.
        if (rotated && hi[0] < start)
            hi[0] = start;
        return hi[0] >= lo[0];
        }

    // Arithmetic / compare / convert, the ops that count as per-item compute
    // for the cost model (not loads, stores, address maths, phis or branches).
    final bool parIsComputeOp(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"))
            || op.equals(String.withCString("Mul")) || op.equals(String.withCString("UDiv"))
            || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem"))
            || op.equals(String.withCString("SRem")) || op.equals(String.withCString("Shl"))
            || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr"))
            || op.equals(String.withCString("And")) || op.equals(String.withCString("Or"))
            || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Neg"))
            || op.equals(String.withCString("Not")) || op.equals(String.withCString("FAdd"))
            || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul"))
            || op.equals(String.withCString("FDiv")) || op.equals(String.withCString("FNeg"))
            || op.equals(String.withCString("FSqrt")) || op.equals(String.withCString("ICmp"))
            || op.equals(String.withCString("FCmp")) || op.equals(String.withCString("Select"))
            || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp"))
            || op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI"))
            || op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc"));
        }
    // The block's per-item cost, for par-auto's static classifier
    // (par-auto-parallelisation.md): `ops=<n>` the compute-op count, and `loop`
    // when the body has an inner loop (a branch back to an earlier block). The
    // runtime already has bytes-per-item from the footprints, so intensity is
    // ops/byte; a `loop` makes the item compute-heavy whatever the straight-line
    // count (its trips are data-dependent), so the runtime does not prune the
    // GPU for it. Both compilers emit this identically (same IR).
    // The cost of f and of every function of the program it calls, once
    // each (a kernel inlines its helpers, so their work is the item's work):
    // ops summed, and `loop` when f has a nested loop (its outer parallel
    // loop is one back edge, so a second is a nested one) or any helper has
    // a loop at all. Intrinsics and runtime calls add nothing. As the
    // reference (costOf:).
    final void parCostOf(IRFunc* f, Map* visited, i64* ops, bool* loop, bool top)
        {
        visited.set((Hashable*)f.name(), (Object*)f.name());
        i64 backEdges = (i64)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ins = (IRInsn*)bb.insns().get(i);
                if (parIsComputeOp(ins.op()))
                    *ops = *ops + (i64)1;
                if ((ins.op().equals(String.withCString("Call")) || ins.op().equals(String.withCString("CallBanked"))
                     || ins.op().equals(String.withCString("CallCloaked")))
                    && ins.ops().count() > (u32)0 && ((IROperand*)ins.ops().get((u32)0)).kind() == (u8)OPK_SYM)
                    {
                    String* callee = ((IROperand*)ins.ops().get((u32)0)).name();
                    IRFunc* target = (IRFunc*)0;
                    for (u32 q = (u32)0; q < _m.funcs().count(); q = q + (u32)1)
                        if (((IRFunc*)_m.funcs().get(q)).name().equals(callee))
                            target = (IRFunc*)_m.funcs().get(q);
                    if (target != (IRFunc*)0 && visited.get((Hashable*)callee) == (Object*)0)
                        parCostOf(target, visited, ops, loop, false);
                    }
                }
            IRInsn* t = bb.term();
            if (t != (IRInsn*)0)
                for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)t.ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK)
                        continue;
                    for (u32 j = (u32)0; j < f.blocks().count(); j = j + (u32)1)
                        if ((IRBlock*)f.blocks().get(j) == o.blk() && j <= b)
                            backEdges = backEdges + (i64)1;
                    }
            }
        if (backEdges >= (top ? (i64)2 : (i64)1))
            *loop = true;
        }

    // ` merge=<n>,…` (or nothing; n counts the red= words from 0): the
    // reductions a node may fold before
    // the coordinator does — integer + * & | ^, min and max always; float +
    // and * only under :goal(speed); float min and max always. In field
    // order. As the reference's mergeWordsIn.
    final String* parMergeWords(IRFunc* f)
        {
        String* w = String.withCString("");
        if (_mRedOps == (Map*)0 || f.params().count() == (u32)0)
            return w;
        IRLayout* lay = self.mslLayoutOf(mslPointee(((IRValue*)f.params().get((u32)0)).ty()));
        if (lay == (IRLayout*)0)
            return w;
        bool first = true;
        u32 ord = (u32)0;
        for (u32 k = (u32)0; k < lay.fieldCount(); k = k + (u32)1)
            {
            String* op = (String*)_mRedOps.get((Hashable*)String.withU32(k));
            if (op == (String*)0)
                continue;
            u32 at = ord;
            ord = ord + (u32)1;
            String* t = lay.typeAt(k);
            bool isFloat = t != (String*)0 && (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
            bool m = op.equals(String.withCString("min")) || op.equals(String.withCString("max"));
            bool arith = op.equals(String.withCString("+")) || op.equals(String.withCString("*"));
            if (!isFloat)
                m = m || arith || op.equals(String.withCString("&")) || op.equals(String.withCString("|"))
                    || op.equals(String.withCString("^"));
            else if (_mFast)
                m = m || arith;
            if (!m)
                continue;
            w.appendCString(first ? " merge=" : ",");
            w.append(String.withU32(at));
            first = false;
            }
        return w;
        }

    final String* parCostWords(IRFunc* f)
        {
        i64 ops = (i64)0;
        bool loop = false;
        parCostOf(f, new Map(), &ops, &loop, true);
        String* w = new String();
        w.appendCString(" ops=");
        w.append(String.withI64(ops));
        if (loop)
            w.appendCString(" loop");
        return w;
        }

    // §4: a read of a buffer the block also writes must be at the element
    // this work item writes. `b[i] = b[i - 1] + …` reads another item's
    // result: that is a scan, not a par. Returns the complaint, or 0.
    final String* parDependence(IRFunc* f, Array* ivars)
        {
        Map* def = new Map();
        IRValue* iv = (IRValue*)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ph = (IRInsn*)bb.phis().get(i);
                if (ph.res() == (IRValue*)0)
                    continue;
                def.set((Hashable*)String.withU32(ph.res().seq()), (Object*)ph);
                if (iv == (IRValue*)0)
                    iv = ph.res(); // the outer loop's counter: the first phi
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0)
                    def.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
                }
            }
        if (iv == (IRValue*)0 || f.params().count() == (u32)0)
            return (String*)0;
        // The induction variable is the phi the loop's GUARD compares, not
        // simply the first phi: a reduction's accumulator is a phi too, and a
        // block with reductions lists one of those first (the reference's IR
        // does). An ICmp that takes a phi is the guard (or a min/max test, but
        // the guard comes first in block order); its phi operand is the iv.
        iv = parInductionVariable(f, def, iv);
        IRValue* selfVal = (IRValue*)f.params().get((u32)0);
        Map* writes = new Map();        // buffer -> Array of "affine k c" strings
        Map* wShown = new Map();        // buffer -> its first write's index, as shown
        Map* wSym = new Map();          // buffer -> Array of its writes' symbolic forms (ParIdx)
        Array* reads = new Array();     // [buffer, form, shown]
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                String* op = ip.op();
                bool isStore = op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile"));
                bool isLoad = op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile"));
                if ((!isStore && !isLoad) || ip.ops().count() == (u32)0)
                    continue;
                IROperand* a0 = (IROperand*)ip.ops().get((u32)0);
                if (a0.kind() != (u8)OPK_USE)
                    continue;
                IRInsn* ea = (IRInsn*)def.get((Hashable*)String.withU32(a0.val().seq()));
                if (ea == (IRInsn*)0 || !ea.op().equals(String.withCString("ElementAddr")) || ea.ops().count() < (u32)2)
                    continue;
                String* buf = parBufferOf((IROperand*)ea.ops().get((u32)0), selfVal, ivars, def);
                if (buf == (String*)0)
                    continue;
                ParIdx* px = parIndex((IROperand*)ea.ops().get((u32)1), iv, def, (u32)0);
                if (!px.affine)
                    px = parGridIndex((IROperand*)ea.ops().get((u32)1), iv, selfVal, ivars, def);
                bool af = px.affine; i64 k = px.k; i64 c = px.c;
                ParIdx* sx = ParIdx.of(false, (i64)0, (i64)0);
                if (_parGuardList != (Array*)0)
                    sx = af ? ParIdx.of(true, k, c) : parSymIndex((IROperand*)ea.ops().get((u32)1), iv, selfVal, def, (u32)0);
                // …and in a grid, the point's flat index plus captured integers.
                if (_parGuardList != (Array*)0 && !sx.affine)
                    sx = parGridSym((IROperand*)ea.ops().get((u32)1), iv, selfVal, ivars, def);
                // A symbolic write with stride k != 0 is no scatter (as the reference).
                bool symStrided = sx.affine && sx.k != (i64)0;
                String* form = String.withCString(af ? "1 " : "0 ");
                form.append(String.withI64(af ? k : (i64)0));
                form.appendCString(" ");
                form.append(String.withI64(af ? c : (i64)0));
                String* shown = parShownIndex(af, k, c);
                // §4: a write the shapes above do not cover (a scatter, or
                // every item writing one element) is legal but unprovable: a
                // warning, the first one per block.
                if (isStore && _parScatter == (String*)0 && !symStrided && (!af || k == (i64)0))
                    {
                    String* sc = String.withCString("'");
                    sc.append(self.parShown(buf));
                    if (af)
                        {
                        sc.append(shown);
                        sc.appendCString("' from every work item");
                        }
                    else
                        sc.appendCString("' at an index computed from data");
                    _parScatter = sc;
                    }
                if (isStore)
                    {
                    Array* ws = (Array*)writes.get((Hashable*)buf);
                    if (ws == (Array*)0)
                        {
                        ws = new Array();
                        writes.set((Hashable*)buf, (Object*)ws);
                        wShown.set((Hashable*)buf, (Object*)shown);
                        wSym.set((Hashable*)buf, (Object*)new Array());
                        }
                    ws.add((Object*)form);
                    ((Array*)wSym.get((Hashable*)buf)).add((Object*)sx);
                    }
                else
                    {
                    Array* r = new Array();
                    r.add((Object*)buf);
                    r.add((Object*)form);
                    r.add((Object*)shown);
                    r.add((Object*)sx);
                    reads.add((Object*)r);
                    }
                }
            }
        for (u32 i = (u32)0; i < reads.count(); i = i + (u32)1)
            {
            Array* r = (Array*)reads.get(i);
            String* buf = (String*)r.get((u32)0);
            String* form = (String*)r.get((u32)1);
            Array* ws = (Array*)writes.get((Hashable*)buf);
            if (ws == (Array*)0 || ws.count() == (u32)0)
                continue;
            bool dependent = false;
            Array* wsy = (Array*)wSym.get((Hashable*)buf);
            for (u32 j = (u32)0; j < ws.count(); j = j + (u32)1)
                {
                if (!Lower.parFormDep(form, (String*)ws.get(j)))
                    continue;
                // The same captured integers on both sides: they differ by a
                // constant, which the plain test settles. As the reference.
                ParIdx* rsy = (ParIdx*)r.get((u32)3);
                ParIdx* wsym = (ParIdx*)wsy.get(j);
                if (_parGuardList != (Array*)0 && rsy.affine && wsym.affine && ParIdx.sameTerms(rsy, wsym)
                    && !Lower.parAffineDep(rsy.k, rsy.c, wsym.k, wsym.c))
                    continue;
                String* g = _parGuardList != (Array*)0 ? Lower.parGuardFor((ParIdx*)r.get((u32)3), (ParIdx*)wsy.get(j)) : (String*)0;
                if (g == (String*)0 && _parGuardList != (Array*)0)
                    g = Lower.parIntervalGuardFor((ParIdx*)r.get((u32)3), (ParIdx*)wsy.get(j));
                if (g != (String*)0)
                    {
                    bool have = false;
                    for (u32 q = (u32)0; q < _parGuardList.count(); q = q + (u32)1)
                        if (((String*)_parGuardList.get(q)).equals(g))
                            have = true;
                    if (!have)
                        _parGuardList.add((Object*)g);
                    continue;
                    }
                dependent = true;
                }
            if (!dependent)
                continue;
            String* name = self.parShown(buf);
            String* out = String.withCString("reads ");
            out.append(name);
            out.append((String*)r.get((u32)2));
            out.appendCString(" while writing ");
            out.append(name);
            out.append((String*)wShown.get((Hashable*)buf));
            out.appendCString(", so an item would read another item's result; that is a scan, not a par");
            return out;
            }
        return (String*)0;
        }

    // ── the par kernels: printed and filled into their blocks ───────────

    // Each block's gpuSource() returns a placeholder literal,
    // `__XC_PAR_MSL_<n>__`; give it the kernel's source for the target's GPU
    // (Metal on macOS, PTX for NVIDIA on Windows), or "" when the block
    // stays on the CPU.
    // The kernels as the optimiser leaves them (the reference explains:
    // XTIRParCheck kernelModuleFrom, bug 645). 0 when the round trip is not
    // exact or a pass fails.
    final IRModule* parKernelModule()
        {
        _kPrinted = (String*)0;
        return parKernelModuleV((u32)0);
        }

    final IRModule* parKernelModuleV(u32 trips)
        {
        // Nothing to render without a block: the round trip prints and
        // reparses the whole module, and a program with a 64M-element global
        // took two minutes and 23 GB in it for no kernel at all.
        bool any = false;
        for (u32 i = (u32)0; i < _m.funcs().count() && !any; i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)_m.funcs().get(i);
            if (f.name().hasPrefix(String.withCString("ParImpl$")) && f.name().hasSuffix(String.withCString("$run")))
                any = true;
            }
        if (!any) return (IRModule*)0;
        bool again = _kPrinted != (String*)0;
        String* printed = again ? _kPrinted : _m.text();
        IRModule* copy = IrParser.parseText(printed, new IrParser());
        if (copy == (IRModule*)0 || (!again && !copy.text().equals(printed))) return (IRModule*)0;
        _kPrinted = printed;
        Map* byName = new Map();
        for (u32 i = (u32)0; i < copy.funcs().count(); i = i + (u32)1)
            byName.set((Hashable*)((IRFunc*)copy.funcs().get(i)).name(), copy.funcs().get(i));
        Array* keep = new Array();
        Map* seen = new Map();
        Array* work = new Array();
        for (u32 i = (u32)0; i < copy.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)copy.funcs().get(i);
            if (f.name().hasPrefix(String.withCString("ParImpl$")) && f.name().hasSuffix(String.withCString("$run")))
                {
                work.add((Object*)f);
                seen.set((Hashable*)f.name(), (Object*)f.name());
                }
            }
        if (work.count() == (u32)0) return (IRModule*)0;
        while (work.count() > (u32)0)
            {
            IRFunc* f = (IRFunc*)work.get(work.count() - (u32)1);
            work.removeLast();
            keep.add((Object*)f);
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* blk = (IRBlock*)f.blocks().get(b);
                for (u32 k = (u32)0; k < blk.insns().count(); k = k + (u32)1)
                    {
                    IRInsn* ip = (IRInsn*)blk.insns().get(k);
                    if (!ip.op().equals(String.withCString("Call")) || ip.ops().count() == (u32)0) continue;
                    IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
                    if (o0.kind() != (u8)OPK_SYM) continue;
                    String* nm = o0.name();
                    // Not the standard output library (the reference explains).
                    if (nm != (String*)0 && byName.get((Hashable*)nm) != (Object*)0 && seen.get((Hashable*)nm) == (Object*)0
                        && !nm.hasPrefix(String.withCString("Stdio$")))
                        {
                        seen.set((Hashable*)nm, (Object*)nm);
                        work.add(byName.get((Hashable*)nm));
                        }
                    }
                }
            }
        copy.funcs().removeAll();
        for (u32 i = (u32)0; i < keep.count(); i = i + (u32)1)
            copy.funcs().add(keep.get(i));
        Opt* opt = Opt.atLevel((u32)3, OptProfile.forTarget(String.withCString("arm64")));
        opt.setEscTrips(trips);
        opt.parKernels(copy);
        if (opt.failed()) return (IRModule*)0;
        _kChanged = opt.escChanged();
        return copy;
        }

    // Each printer on the optimised kernel first, then the plain one if that
    // declines (the reference explains). The printers read _m for context.
    final String* parPtxK(IRFunc* f, IRFunc* kf, IRModule* km)
        {
        if (kf != (IRFunc*)0)
            {
            IRModule* sm = _m;
            _m = km;
            String* r = self.parPtx(kf);
            _m = sm;
            _mWhy = (String*)0;
            if (r != (String*)0) return r;
            }
        return self.parPtx(f);
        }
    final Array* parSpirvK(IRFunc* f, IRFunc* kf, IRModule* km)
        {
        if (kf != (IRFunc*)0)
            {
            IRModule* sm = _m;
            _m = km;
            bool ok = self.parSpirv(kf);
            _m = sm;
            _mWhy = (String*)0;
            if (ok) return _sOut;
            }
        return self.parSpirv(f) ? _sOut : (Array*)0;
        }
    final String* parMslK(IRFunc* f, IRFunc* kf, IRModule* km)
        {
        if (kf != (IRFunc*)0)
            {
            IRModule* sm = _m;
            _m = km;
            String* r = self.parMsl(kf);
            _m = sm;
            _mWhy = (String*)0;
            if (r != (String*)0) return r;
            }
        return self.parMsl(f);
        }
    final String* parWgslK(IRFunc* f, IRFunc* kf, IRModule* km)
        {
        if (kf != (IRFunc*)0)
            {
            IRModule* sm = _m;
            _m = km;
            bool ok = self.parWgsl(kf);
            _m = sm;
            _mWhy = (String*)0;
            if (ok) return _wgOut;
            }
        return self.parWgsl(f) ? _wgOut : (String*)0;
        }

    final void parFillSources()
        {
        IRModule* kmod = parKernelModule();
        Map* kfns = new Map();
        if (kmod != (IRModule*)0)
            for (u32 i = (u32)0; i < kmod.funcs().count(); i = i + (u32)1)
                kfns.set((Hashable*)((IRFunc*)kmod.funcs().get(i)).name(), kmod.funcs().get(i));
        // XTGPU_ESC_TRIPS=<n> sets the variant's trips, 0 or 1 for none; not
        // for a module whose printed text is past 64 MB.
        _kvTrips = (u32)8;
        u8* et = _xt_getenv("XTGPU_ESC_TRIPS");
        if (et != (u8*)0 && et[0] != (u8)0)
            {
            _kvTrips = (u32)0;
            for (u32 k = (u32)0; et[k] >= (u8)'0' && et[k] <= (u8)'9'; k = k + (u32)1)
                _kvTrips = _kvTrips * (u32)10 + (u32)(et[k] - (u8)'0');
            }
        _kvMod = (IRModule*)0;
        _kvFns = new Map();
        if (kmod != (IRModule*)0 && _kvTrips >= (u32)2 && _kPrinted != (String*)0
            && _kPrinted.byteLength() <= ((u32)64 << (u32)20))
            {
            _kvMod = parKernelModuleV(_kvTrips);
            if (_kvMod != (IRModule*)0)
                for (u32 i = (u32)0; i < _kvMod.funcs().count(); i = i + (u32)1)
                    {
                    IRFunc* g = (IRFunc*)_kvMod.funcs().get(i);
                    for (u32 k = (u32)0; k < _kChanged.count(); k = k + (u32)1)
                        if (((String*)_kChanged.get(k)).equals(g.name()))
                            _kvFns.set((Hashable*)g.name(), (Object*)g);
                    }
            }
        for (u32 i = (u32)0; i < _m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)_m.funcs().get(i);
            if (!f.name().hasPrefix(String.withCString("ParImpl$")) || !f.name().hasSuffix(String.withCString("$run")))
                continue;
            parFillBlock(f, (IRFunc*)kfns.get((Hashable*)f.name()), kmod);
            }
        _kvMod = (IRModule*)0;
        _kvFns = (Map*)0;
        }

    // The IR outliner's blocks (stage 4): each made after lowering, in the
    // optimiser, on SSA, as a record read by field. Each gets the class
    // declaration a parser block would have had (ParChunk's, then a field per
    // capture and accumulator), so the printers name its fields, and is
    // printed from itself: it is already in the optimised shape.
    final void parFillOutlined(IRModule* m, Array* blocks)
        {
        IRModule* saved = _m;
        _m = m;
        // The symbols as they are now (a C program's globals were read into
        // the module after the parser's blocks were checked): the footprints
        // look their arrays up here.
        if (_parSyms == (Map*)0)
            _parSyms = new Map();
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            _parSyms.set((Hashable*)((IRSymbol*)m.syms().get(i)).name(), m.syms().get(i));
        // The printers may change what they print: they print from a copy,
        // the kernel module the parser's blocks are printed from (the blocks
        // and what they call, cleaned up by the kernel passes), and write
        // into the real module's placeholders. A plain copy where that fails.
        IRModule* copy = parKernelModule();
        if (copy == (IRModule*)0)
            copy = IrParser.parseText(m.text(), new IrParser());
        if (copy == (IRModule*)0)
            {
            _m = saved;
            return;
            }
        for (u32 i = (u32)0; i < blocks.count(); i = i + (u32)1)
            {
            ParOutBlock* b = (ParOutBlock*)blocks.get(i);
            Node* d = Node.withName((u16)nkClassDecl, b.cls());
            d.setOp(String.withCString("ParChunk"));
            for (u32 k = (u32)0; k < b.fieldTypes().count(); k = k + (u32)1)
                {
                Node* v = Node.withName((u16)nkVariableDecl, String.withFormat("c%u", k));
                v.setOp((String*)b.fieldTypes().get(k));
                d.add(v);
                }
            _classDecls.set((Hashable*)b.cls(), (Object*)d);
            IRFunc* f = (IRFunc*)0;
            String* rn = String.withFormat("%s$run", b.cls().cString());
            for (u32 k = (u32)0; k < copy.funcs().count() && f == (IRFunc*)0; k = k + (u32)1)
                if (((IRFunc*)copy.funcs().get(k)).name().equals(rn))
                    f = (IRFunc*)copy.funcs().get(k);
            if (f != (IRFunc*)0)
                {
                _mWhy = (String*)0;
                _mMslWhy = (String*)0;
                parFlatStructGlobals(f);
                parFillBlock(f, f, copy);
                // XC_PAR_OUTLINE_TRACE: why a block has no GPU form (the
                // Metal form's reason, else the last form's).
                String* why = _mMslWhy != (String*)0 ? _mMslWhy : _mWhy;
                if (why != (String*)0 && Platform.env(String.withCString("XC_PAR_OUTLINE_TRACE")).byteLength() > (u32)0)
                    Stdio.error(String.withFormat("outline: %s: no GPU form: %s\n", b.cls().cString(), why.cString()));
                }
            }
        _m = saved;
        }

    // A global array of structs whose fields are all one number type (C's
    // `struct P { int x, y; } ps[N]`, a vector's coordinates), in the kernel
    // copy of an outlined block, as the array of that number it is in
    // memory: its address a pointer to the number, element i's field k the
    // number at i * fields + k. The printers then hold it as any array of
    // numbers. Nothing changes where the struct is used otherwise.
    final void parFlatStructGlobals(IRFunc* f)
        {
        Map* def = new Map();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0)
                    def.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
                }
            }
        // The candidates: an AddrOf of a global whose pointee is such a struct.
        Map* flat = new Map();      // value seq -> the field type
        Map* nf = new Map();        // value seq -> the number of fields
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (!ip.op().equals(String.withCString("AddrOf")) || ip.res() == (IRValue*)0 || ip.ops().count() != (u32)1
                    || ((IROperand*)ip.ops().get((u32)0)).kind() != (u8)OPK_SYM || !self.mslIsPtr(ip.res().ty()))
                    continue;
                String* ft = self.parFlatField(mslPointee(ip.res().ty()));
                if (ft == (String*)0)
                    continue;
                IRLayout* l = self.mslLayoutOf(mslPointee(ip.res().ty()));
                flat.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ft);
                nf.set((Hashable*)String.withU32(ip.res().seq()), (Object*)Number.with(l.fieldCount()));
                }
            }
        if (flat.count() == (u32)0)
            return;
        // Every use is an element's address, then only a field's; else the
        // global stays as it is (and the kernel declines it).
        Map* elems = new Map();     // element value seq -> its global's seq
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)f.blocks().get(b);
                Array* all = new Array();
                for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) all.add(bb.phis().get(i));
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) all.add(bb.insns().get(i));
                if (bb.term() != (IRInsn*)0) all.add((Object*)bb.term());
                for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                    {
                    IRInsn* ip = (IRInsn*)all.get(i);
                    for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)ip.ops().get(k);
                        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                            continue;
                        String* key = String.withU32(o.val().seq());
                        bool g = flat.get((Hashable*)key) != (Object*)0;
                        bool e = elems.get((Hashable*)key) != (Object*)0;
                        if (!g && !e)
                            continue;
                        bool ok = false;
                        if (g && k == (u32)0 && ip.op().equals(String.withCString("ElementAddr")) && ip.res() != (IRValue*)0)
                            {
                            ok = true;
                            if (pass == (u32)0)
                                elems.set((Hashable*)String.withU32(ip.res().seq()), (Object*)key);
                            }
                        if (k == (u32)0 && ip.op().equals(String.withCString("FieldAddr")) && ip.ops().count() == (u32)2
                            && ((IROperand*)ip.ops().get((u32)1)).kind() == (u8)OPK_IMMI)
                            ok = true;
                        if (!ok)
                            {
                            if (g)
                                flat.set((Hashable*)key, (Object*)0);
                            else
                                flat.set((Hashable*)elems.get((Hashable*)key), (Object*)0);
                            }
                        }
                    }
                }
        // A field of a mixed struct may only be loaded or stored through:
        // anything else (its address passed on, compared, offset) keeps the
        // global as it is. A uniform struct's fields are plain numbers, as
        // before.
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            Array* all = new Array();
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) all.add(bb.phis().get(i));
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) all.add(bb.insns().get(i));
            if (bb.term() != (IRInsn*)0) all.add((Object*)bb.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)ip.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(o.val().seq()));
                    if (d == (IRInsn*)0 || !d.op().equals(String.withCString("FieldAddr")) || d.ops().count() != (u32)2)
                        continue;
                    IROperand* eo = (IROperand*)d.ops().get((u32)0);
                    if (eo.kind() != (u8)OPK_USE || eo.val() == (IRValue*)0)
                        continue;
                    String* g = (String*)elems.get((Hashable*)String.withU32(eo.val().seq()));
                    if (g == (String*)0 || flat.get((Hashable*)g) == (Object*)0
                        || !((String*)flat.get((Hashable*)g)).equals(String.withCString("U32")))
                        continue;
                    bool viaLoad = ip.op().equals(String.withCString("Load")) && k == (u32)0;
                    bool viaStore = ip.op().equals(String.withCString("Store")) && k == (u32)0;
                    // A float literal stored there would need its bits worked
                    // out here; rare in a kernel, so the global stays.
                    if (viaStore && ip.ops().count() >= (u32)2
                        && ((IROperand*)ip.ops().get((u32)1)).kind() == (u8)OPK_IMMF)
                        viaStore = false;
                    if (!viaLoad && !viaStore)
                        flat.set((Hashable*)g, (Object*)0);
                    }
                }
            }
        // The rewrite.
        Map* recast = new Map();    // field address seq -> the field's own type
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            u32 i = (u32)0;
            while (i < bb.insns().count())
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                IRValue* r = ip.res();
                String* op = ip.op();
                if (r == (IRValue*)0 || ip.ops().count() == (u32)0)
                    {
                    i = i + (u32)1;
                    continue;
                    }
                IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
                String* gk = (String*)0;
                if (op.equals(String.withCString("AddrOf")))
                    gk = String.withU32(r.seq());
                else if (o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0)
                    {
                    String* ok0 = String.withU32(o0.val().seq());
                    gk = flat.get((Hashable*)ok0) != (Object*)0 ? ok0 : (String*)elems.get((Hashable*)ok0);
                    }
                String* ft = gk != (String*)0 ? (String*)flat.get((Hashable*)gk) : (String*)0;
                if (ft == (String*)0)
                    {
                    i = i + (u32)1;
                    continue;
                    }
                String* pt = parPtrRetyped(r.ty(), ft);
                if (op.equals(String.withCString("AddrOf")))
                    r.setTy(pt);
                else if (op.equals(String.withCString("ElementAddr")) && ip.ops().count() == (u32)2)
                    {
                    // [i] of the struct: [i * fields] of the number.
                    u32 n = ((Number*)nf.get((Hashable*)gk)).asU32();
                    IROperand* io = (IROperand*)ip.ops().get((u32)1);
                    IROperand* scaled = (IROperand*)0;
                    if (io.kind() == (u8)OPK_IMMI)
                        scaled = IROperand.immI(io.imm() * (i64)n, io.ty());
                    else if (io.kind() == (u8)OPK_USE && io.val() != (IRValue*)0)
                        {
                        IRValue* mv = new IRValue(io.val().ty());
                        IRInsn* mul = IRInsn.with(String.withCString("Mul"));
                        mul.add(IROperand.useVal(io.val()));
                        mul.add(IROperand.immI((i64)n, io.val().ty()));
                        mul.setRes(mv);
                        bb.insns().insert(i, (Object*)mul);
                        i = i + (u32)1;
                        scaled = IROperand.useVal(mv);
                        }
                    if (scaled != (IROperand*)0)
                        {
                        ip.ops().set((u32)1, (Object*)scaled);
                        r.setTy(pt);
                        }
                    }
                else if (op.equals(String.withCString("FieldAddr")))
                    {
                    // Field k: the number k further on.
                    i64 k = ((IROperand*)ip.ops().get((u32)1)).imm();
                    String* fty = self.mslIsPtr(r.ty()) ? self.mslPointee(r.ty()) : (String*)0;
                    if (fty != (String*)0 && !fty.equals(ft))
                        recast.set((Hashable*)String.withU32(r.seq()), (Object*)fty);
                    IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
                    ea.add(o0);
                    ea.add(IROperand.immI(k, String.withCString("I64")));
                    ea.setRes(r);
                    r.setTy(pt);
                    bb.insns().set(i, (Object*)ea);
                    }
                i = i + (u32)1;
                }
            }
        if (recast.count() == (u32)0)
            return;
        // A field whose type is not the word's: read the word and reinterpret
        // it, reinterpret before writing.
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            u32 i = (u32)0;
            while (i < bb.insns().count())
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                IROperand* a0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
                String* fty = a0 != (IROperand*)0 && a0.kind() == (u8)OPK_USE && a0.val() != (IRValue*)0
                              ? (String*)recast.get((Hashable*)String.withU32(a0.val().seq())) : (String*)0;
                if (fty == (String*)0)
                    {
                    i = i + (u32)1;
                    continue;
                    }
                if (ip.op().equals(String.withCString("Load")) && ip.res() != (IRValue*)0)
                    {
                    IRValue* orig = ip.res();
                    IRValue* word = new IRValue(String.withCString("U32"));
                    ip.setRes(word);
                    IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
                    bc.add(IROperand.useVal(word));
                    bc.setRes(orig);
                    bb.insns().insert(i + (u32)1, (Object*)bc);
                    i = i + (u32)2;
                    continue;
                    }
                if (ip.op().equals(String.withCString("Store")) && ip.ops().count() >= (u32)2
                    && ((IROperand*)ip.ops().get((u32)1)).kind() == (u8)OPK_USE)
                    {
                    IROperand* vo = (IROperand*)ip.ops().get((u32)1);
                    IRValue* word = new IRValue(String.withCString("U32"));
                    IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
                    bc.add(vo);
                    bc.setRes(word);
                    bb.insns().insert(i, (Object*)bc);
                    ip.ops().set((u32)1, (Object*)IROperand.useVal(word));
                    i = i + (u32)2;
                    continue;
                    }
                i = i + (u32)1;
                }
            }
        }

    // Ptr(T, space) as Ptr(ft, space).
    final String* parPtrRetyped(String* t, String* ft)
        {
        String* inner = self.mslPointee(t);
        String* s = String.withCString("Ptr(");
        s.append(ft);
        s.append(t.substringFromByte((u32)4 + inner.byteLength()));
        return s;
        }

    // One block's kernels, printed and written into its placeholder: every
    // block of the parser's (parFillSources), and each the IR outliner makes
    // after lowering (parFillOutlined).
    final void parFillBlock(IRFunc* f, IRFunc* kf, IRModule* kmod)
        {
        String* n = f.name().substringBytes((u32)8, f.name().byteLength() - (u32)12);
        String* tag = String.withCString("__XC_PAR_MSL_");
        tag.append(n);
        tag.appendCString("__");
        // Which placeholder the block has says whether its goal is speed.
        String* fastTag = String.withCString("__XC_PAR_FAST_");
        fastTag.append(n);
        fastTag.appendCString("__");
        _mFast = false;
        for (u32 j = (u32)0; j < _m.syms().count(); j = j + (u32)1)
            if (parSymHasPrefix((IRSymbol*)_m.syms().get(j), fastTag))
                _mFast = true;
        if (_mFast) tag = fastTag;
        // The block's reductions, after the tag: `<field>=<op>;` each (bug 645).
        _mRedOps = (Map*)0;
        _mConst = new Map();
        _mGridW = (i64)0;
        _mGridH = (i64)0;
        for (u32 j = (u32)0; j < _m.syms().count(); j = j + (u32)1)
            {
            IRSymbol* ls = (IRSymbol*)_m.syms().get(j);
            if (!parSymHasPrefix(ls, tag))
                continue;
            u32 end = ls.bytes().count();
            while (end > tag.byteLength() && ((Number*)ls.bytes().get(end - (u32)1)).asU32() == (u32)0)
                end = end - (u32)1;
            if (end <= tag.byteLength())
                continue;
            _mRedOps = new Map();
            String* key = new String();
            String* val = new String();
            bool inVal = false;
            for (u32 q = tag.byteLength(); q < end; q = q + (u32)1)
                {
                u8 c = (u8)((Number*)ls.bytes().get(q)).asU32();
                if (c == (u8)';')
                    {
                    if (key.byteLength() > (u32)0 && inVal && key.equals(String.withCString("gw")))
                        _mGridW = parWordI64(val);
                    else if (key.byteLength() > (u32)0 && inVal && key.equals(String.withCString("gh")))
                        _mGridH = parWordI64(val);
                    else if (key.byteLength() > (u32)0 && inVal)
                        _mRedOps.set((Hashable*)key, (Object*)val);
                    // `c<field>`: a :constant capture (storage hints).
                    else if (key.byteLength() > (u32)1 && !inVal && key.byteAt((u32)0) == (u8)'c')
                        _mConst.set((Hashable*)key.substringFromByte((u32)1), (Object*)String.withCString("1"));
                    key = new String();
                    val = new String();
                    inVal = false;
                    }
                else if (c == (u8)'=' && !inVal)
                    inVal = true;
                else if (inVal)
                    val.appendByte(c);
                else
                    key.appendByte(c);
                }
            }
        // The buffers' footprints, as words on the header line every
        // printer writes (step 1 of par-tiles-and-devices.md).
        _parExtraMeta = parFootprintWords(f, parIvarNames(f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4)));
        _parExtraMeta.append(parCostWords(f));
        _parExtraMeta.append(parGuardWords(f, (Array*)_parGuards.get((Hashable*)f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4))));
        _parExtraMeta.append(parMergeWords(f));
        String* msl = (String*)0;
        // A SPIR-V module is bytes (it holds NULs): it goes in as they are.
        Array* kernelBytes = (Array*)0;
        // The forms this target asked for (every one under
        // -fpar-kernels=all, so a worker on another machine finds its
        // own: ParRemote.xc), in a fixed order — the MSL, PTX and WGSL
        // text sections, each ended by a NUL with the next on a 4-byte
        // boundary, and the SPIR-V module last. Each header names its
        // kind, and a runtime finds its section by that
        // (ParDevice.sectionOf). A block with no form at all stays on the
        // CPU, with the first printer's reason. As the reference.
        String* mslWhy = (String*)0;
        String* ptxWhy = (String*)0;
        String* wgslWhy = (String*)0;
        String* spvWhy = (String*)0;
        // A demoted auto block gets the serial marker instead of a kernel:
        // Par.run then runs it on one thread, and no GPU sees it.
        String* fcls = f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4);
        // The optimised kernel can name a global the block cannot locate (a
        // helper's, inlined): the plain one then speaks for the block, and
        // its helper says why it stays on the CPU. As the reference.
        IRFunc* kfUse = kf;
        if (kf != (IRFunc*)0 && kmod != (IRModule*)0 && parUnlocatedGlobal(kmod, _m, kf, fcls) != (String*)0)
            kfUse = (IRFunc*)0;
        bool serialBlock = _parSerial != (Set*)0 && _parSerial.contains((Hashable*)fcls);
        // A global its run could not locate: no form at all, and that reason.
        String* lost = serialBlock ? (String*)0 : parUnlocatedGlobal(_m, _m, f, fcls);
        String* lostWhy = (String*)0;
        if (lost != (String*)0)
            {
            lostWhy = String.withCString("it uses the global ");
            lostWhy.append(self.parShown(lost));
            }
        bool noForms = serialBlock || lost != (String*)0;
        _mWhy = lostWhy;
        String* mslText = _parMetal && !noForms ? parMslK(f, kfUse, kmod) : (String*)0;
        mslWhy = _mWhy;
        _mMslWhy = mslWhy;
        _mWhy = lostWhy;
        String* ptx = _parPTX && !noForms ? parPtxK(f, kfUse, kmod) : (String*)0;
        ptxWhy = _mWhy;
        _mWhy = lostWhy;
        String* wgsl = _parWGSL && !noForms ? parWgslK(f, kfUse, kmod) : (String*)0;
        wgslWhy = _mWhy;
        _mWhy = lostWhy;
        Array* spv = _parSPIRV && !noForms ? parSpirvK(f, kfUse, kmod) : (Array*)0;
        spvWhy = _mWhy;
        // The variant of each form there is (`trips=<n>` on its header line),
        // printed from the variant copy with no fallback. As the reference.
        IRFunc* kvf = noForms || _kvFns == (Map*)0 ? (IRFunc*)0 : (IRFunc*)_kvFns.get((Hashable*)f.name());
        String* vmsl = (String*)0;
        String* vptx = (String*)0;
        String* vwgsl = (String*)0;
        Array* vspv = (Array*)0;
        if (kvf != (IRFunc*)0)
            {
            String* meta = _parExtraMeta;
            String* vmeta = String.withString(meta);
            vmeta.appendFormat(" trips=%ld", (i64)_kvTrips);
            _parExtraMeta = vmeta;
            String* keepWhy = _mWhy;
            IRModule* sm = _m;
            _m = _kvMod;
            if (mslText != (String*)0)
                vmsl = self.parMsl(kvf);
            if (ptx != (String*)0)
                vptx = self.parPtx(kvf);
            if (wgsl != (String*)0)
                vwgsl = self.parWgsl(kvf) ? _wgOut : (String*)0;
            if (spv != (Array*)0)
                vspv = self.parSpirv(kvf) ? _sOut : (Array*)0;
            _m = sm;
            _mWhy = keepWhy;
            _parExtraMeta = meta;
            }
        Array* all = new Array();
        if (serialBlock)
            {
            String* marker = String.withCString("// xcpar serial\n");
            for (u32 q = (u32)0; q < marker.byteLength(); q = q + (u32)1)
                all.add((Object*)Number.withU8(marker.byteAt(q)));
            }
        // The plain forms' text, then the variants', then the SPIR-V modules
        // in the same order (the reference explains).
        for (u32 t = (u32)0; t < (u32)6; t = t + (u32)1)
            {
            String* text = t == (u32)0 ? mslText : t == (u32)1 ? ptx : t == (u32)2 ? wgsl
                         : t == (u32)3 ? vmsl : t == (u32)4 ? vptx : vwgsl;
            if (text == (String*)0 || text.byteLength() == (u32)0)
                continue;
            while (all.count() % (u32)4 != (u32)0)
                all.add((Object*)Number.withU8((u8)0));
            for (u32 q = (u32)0; q < text.byteLength(); q = q + (u32)1)
                all.add((Object*)Number.withU8(text.byteAt(q)));
            all.add((Object*)Number.withU8((u8)0));
            }
        for (u32 t = (u32)0; t < (u32)2; t = t + (u32)1)
            {
            Array* mod = t == (u32)0 ? spv : vspv;
            if (mod == (Array*)0 || mod.count() == (u32)0)
                continue;
            while (all.count() % (u32)4 != (u32)0)
                all.add((Object*)Number.withU8((u8)0));
            for (u32 q = (u32)0; q < mod.count(); q = q + (u32)1)
                all.add(mod.get(q));
            }
        // A block the run must check and no form to carry the check runs
        // serially (as the reference).
        Array* fg = (Array*)_parGuards.get((Hashable*)fcls);
        if (all.count() == (u32)0 && fg != (Array*)0 && fg.count() > (u32)0)
            {
            String* marker2 = String.withCString("// xcpar serial\n");
            for (u32 q = (u32)0; q < marker2.byteLength(); q = q + (u32)1)
                all.add((Object*)Number.withU8(marker2.byteAt(q)));
            }
        if (all.count() > (u32)0)
            {
            kernelBytes = all;
            msl = String.withCString("");
            }
        else
            {
            // The first form's reason, of those the target has: Vulkan's
            // before CUDA's, so a Linux build that carries both (2026-10-28)
            // still says what Vulkan could not do. As the reference.
            _mWhy = (String*)0;
            if (_parMetal) _mWhy = mslWhy;
            if (_mWhy == (String*)0 && _parSPIRV) _mWhy = spvWhy;
            if (_mWhy == (String*)0 && _parPTX) _mWhy = ptxWhy;
            if (_mWhy == (String*)0 && _parWGSL) _mWhy = wgslWhy;
            }
        if (msl == (String*)0 && (_parMetal || _parPTX || _parSPIRV || _parWGSL))
            {
            // On a target with a GPU, say why this block stays on the CPU.
            String* w = String.withCString("this 'par' block runs on the CPU only, because ");
            w.append(_mWhy != (String*)0 ? _mWhy : String.withCString("its GPU version cannot express something it uses yet"));
            String* cls = f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4);
            self.warnAtNode(String.withCString("par-gpu"), w, (Node*)_classDecls.get((Hashable*)cls));
            }
        // No form to run, but the run still checks the block's arrays against
        // each other (ParDevice.bufferOverlap) from the header line: a block
        // with no form gets that line alone, `// xcpar cpu`, with every
        // captured pointer to numbers. As the reference.
        if (msl == (String*)0 && kernelBytes == (Array*)0)
            {
            msl = String.withCString("// xcpar cpu");
            IRValue* selfV = f.params().count() > (u32)0 ? (IRValue*)f.params().get((u32)0) : (IRValue*)0;
            String* selfPointee = selfV != (IRValue*)0 ? self.mslPointee(selfV.ty()) : (String*)0;
            IRLayout* bl = selfPointee != (String*)0 && selfPointee.hasPrefix(String.withCString("Agg(")) ? self.layoutOfAgg(selfPointee) : (IRLayout*)0;
            for (u32 k = (u32)3; bl != (IRLayout*)0 && k < bl.fieldCount(); k = k + (u32)1)
                {
                String* e = self.mslPointee(bl.typeAt(k));
                if (e == (String*)0 || e.hasPrefix(String.withCString("Agg(")) || self.irWidth(e) == (u32)0)
                    continue;
                msl.appendCString(" buf=");
                msl.append(String.withU32(bl.offsetAt(k)));
                msl.appendCString(":");
                msl.append(String.withU32(k - (u32)3));
                msl.appendCString(":");
                msl.append(String.withU32(self.irWidth(e)));
                }
            msl.appendCString("\n");
            }
        if (msl == (String*)0)
            msl = String.withCString("");
        for (u32 j = (u32)0; j < _m.syms().count(); j = j + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)_m.syms().get(j);
            if (sym.kind() != (u8)SYM_STRINGLIT || sym.bytes() == (Array*)0 || sym.bytes().count() < tag.byteLength())
                continue;
            bool same = true;
            for (u32 q = (u32)0; q < tag.byteLength() && same; q = q + (u32)1)
                if (((Number*)sym.bytes().get(q)).asU32() != (u32)tag.byteAt(q))
                    same = false;
            if (!same)
                continue;
            Array* nb = new Array();
            if (kernelBytes != (Array*)0)
                {
                for (u32 q = (u32)0; q < kernelBytes.count(); q = q + (u32)1)
                    nb.add(kernelBytes.get(q));
                }
            for (u32 q = (u32)0; q < msl.byteLength(); q = q + (u32)1)
                nb.add((Object*)Number.withU8(msl.byteAt(q)));
            // Keep the terminator the literal had — its trailing NULs only:
            // the reductions listed after the tag (bug 645) are not the kernel's.
            u32 z = sym.bytes().count();
            while (z > tag.byteLength() && ((Number*)sym.bytes().get(z - (u32)1)).asU32() == (u32)0)
                z = z - (u32)1;
            for (u32 q = z; q < sym.bytes().count(); q = q + (u32)1)
                nb.add(sym.bytes().get(q));
            sym.setBytes(nb);
            }
        }

    // Whether a string literal's bytes start with tag.
    final bool parSymHasPrefix(IRSymbol* sym, String* tag)
        {
        if (sym.kind() != (u8)SYM_STRINGLIT || sym.bytes() == (Array*)0 || sym.bytes().count() < tag.byteLength())
            return false;
        for (u32 q = (u32)0; q < tag.byteLength(); q = q + (u32)1)
            if (((Number*)sym.bytes().get(q)).asU32() != (u32)tag.byteAt(q))
                return false;
        return true;
        }

    final bool parReleases(IRFunc* f)
        {
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = (u32)0; i < ins.count(); i = i + (u32)1)
                if (((IRInsn*)ins.get(i)).op().equals(String.withCString("Release")))
                    return true;
            }
        return false;
        }

    // `Stdio$printf` reads as `Stdio.printf`, and an overload's `__double` tail goes.
    // A data global the block's kernel would name (glob=) that the block's
    // gpuGlobal() cannot locate, or nil. That method knows only the globals
    // the body names itself; one a helper uses arrives with the helper once
    // it is inlined, and the run then refused the kernel with no warning at
    // compile time. Compared as the run compares: the IR name against the
    // method's string literals. The method is in the program's module
    // (`mod`); the kernel may be in the kernels' copy (`runMod`), which
    // holds only what they need. As the reference.
    final String* parUnlocatedGlobal(IRModule* runMod, IRModule* mod, IRFunc* run, String* cls)
        {
        String* want = String.withString(cls);
        want.appendCString("$gpuGlobal");
        IRFunc* lookup = (IRFunc*)0;
        for (u32 i = (u32)0; i < mod.funcs().count(); i = i + (u32)1)
            if (((IRFunc*)mod.funcs().get(i)).name().equals(want))
                lookup = (IRFunc*)mod.funcs().get(i);
        if (lookup == (IRFunc*)0)
            return (String*)0;
        Map* symOf = new Map();
        for (u32 q = (u32)0; q < mod.syms().count(); q = q + (u32)1)
            symOf.set((Hashable*)((IRSymbol*)mod.syms().get(q)).name(), mod.syms().get(q));
        Map* runSymOf = symOf;
        if (runMod != mod)
            {
            runSymOf = new Map();
            for (u32 q = (u32)0; q < runMod.syms().count(); q = q + (u32)1)
                runSymOf.set((Hashable*)((IRSymbol*)runMod.syms().get(q)).name(), runMod.syms().get(q));
            }
        Set* known = new Set();
        for (u32 b = (u32)0; b < lookup.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)lookup.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)ip.ops().get(k);
                    if (o.kind() != (u8)OPK_SYM)
                        continue;
                    IRSymbol* ls = (IRSymbol*)symOf.get((Hashable*)o.name());
                    if (ls == (IRSymbol*)0 || ls.kind() != (u8)SYM_STRINGLIT || ls.bytes() == (Array*)0)
                        continue;
                    String* t = new String();
                    for (u32 q = (u32)0; q < ls.bytes().count(); q = q + (u32)1)
                        {
                        u8 c = (u8)((Number*)ls.bytes().get(q)).asU32();
                        if (c != (u8)0)
                            t.appendByte(c);
                        }
                    known.add((Hashable*)t);
                    }
                }
            }
        for (u32 b = (u32)0; b < run.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)run.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (!ip.op().equals(String.withCString("AddrOf")) || ip.ops().count() == (u32)0
                    || ((IROperand*)ip.ops().get((u32)0)).kind() != (u8)OPK_SYM)
                    continue;
                String* gn = ((IROperand*)ip.ops().get((u32)0)).name();
                IRSymbol* gs = (IRSymbol*)runSymOf.get((Hashable*)gn);
                if (gs == (IRSymbol*)0 || gs.kind() != (u8)SYM_DATAGLOBAL || gn.hasPrefix(String.withCString("__sinit_"))
                    || gn.hasPrefix(String.withCString("__sdata_")) || gn.hasSuffix(String.withCString("$init")))
                    continue;
                if (!known.contains((Hashable*)gn))
                    return gn;
                }
            }
        return (String*)0;
        }

    // What a kernel may call outside the program: the static-init once (the
    // host has run it before any block starts), the bounds checks of a
    // -fbounds-check build, block copies, and the maths every GPU has natively.
    final bool parAllowedExternal(String* n)
        {
        String* ok = String.withCString(" _xtc_sinit_run _xt_check_bounds _xt_check_bounds_n _xt_check_object memcpy memmove memset sqrt sqrtf sin sinf cos cosf exp expf log logf pow powf floor floorf fma fmaf fabs fabsf abs _xm_sqrt _xm_sqrtf _xm_sin _xm_sinf _xm_cos _xm_cosf _xm_exp _xm_expf _xm_ln _xm_lnf _xm_pow _xm_powf ");
        String* key = String.withCString(" ");
        key.append(n);
        key.appendCString(" ");
        return ok.contains(key);
        }

    // The maths intrinsics (par-blocks.md §2), as Math's methods: allowed by
    // name without looking inside, because each target implements them its own
    // way (in assembly on the 6502 and the 68000) and a GPU has every one.
    final bool parMathIntrinsic(String* n)
        {
        if (!n.hasPrefix(String.withCString("Math$")))
            return false;
        String* m = String.withCString(" ");
        for (u32 i = (u32)5; i < n.byteLength(); i = i + (u32)1)
            {
            if (n.byteAt(i) == (u8)'_' && i + (u32)1 < n.byteLength() && n.byteAt(i + (u32)1) == (u8)'_')
                break;
            m.appendByte(n.byteAt(i));
            }
        m.appendCString(" ");
        return String.withCString(" sqrt sin cos exp ln pow min max abs floor fma ").contains(m);
        }

    final String* parReason(IRFunc* f)
        {
        String* known = (String*)_parVerdict.get((Hashable*)f.name());
        if (known != (String*)0)
            return known;
        _parOnStack.set((Hashable*)f.name(), (Object*)f);
        String* why = parScan(f);
        _parOnStack.remove((Hashable*)f.name());
        _parVerdict.set((Hashable*)f.name(), (Object*)why);
        return why;
        }

    final String* parScan(IRFunc* f)
        {
        Map* def = new Map();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0)
                    def.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
                }
            }
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                String* op = ip.op();
                if (op.equals(String.withCString("Retain")) || op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")) || op.equals(String.withCString("WeakLoad")) || op.equals(String.withCString("WeakRegister")) || op.equals(String.withCString("WeakUnregister")))
                    return String.withCString("uses an ARC'd value (a class instance, String, Array, Map or block)");
                if (op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("VTblLoad")) || op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("ProtoLoad")))
                    return String.withCString("makes a dynamic call (a virtual or protocol call, a function pointer or a callback)");
                if (op.equals(String.withCString("VaStart")) || op.equals(String.withCString("VaArg")))
                    return String.withCString("uses varargs");
                if (op.equals(String.withCString("Asm")))
                    return String.withCString("contains inline assembly");
                if (op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("AggStore")))
                    {
                    String* g = parGlobalWritten(ip, def);
                    // A class's static-init guard (inlined where there are no
                    // threads) is the host's business: it has run before any
                    // block starts.
                    if (g != (String*)0 && !g.hasPrefix(String.withCString("__sinit_")))
                        {
                        String* r = String.withCString("writes the global '");
                        r.append(self.parShown(g));
                        r.appendCString("' (a global can be read, and a global array written element by element)");
                        return r;
                        }
                    continue;
                    }
                if (op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked")))
                    {
                    if (ip.ops().count() == (u32)0 || ((IROperand*)ip.ops().get((u32)0)).kind() != (u8)OPK_SYM)
                        return String.withCString("makes a dynamic call (a virtual or protocol call, a function pointer or a callback)");
                    String* name = ((IROperand*)ip.ops().get((u32)0)).name();
                    if (name.equals(String.withCString("_xtc_alloc")) || name.equals(String.withCString("_xtc_alloc_object")) || name.hasPrefix(String.withCString("_xtc_new")))
                        return String.withCString("allocates on the heap ('new')");
                    if (parMathIntrinsic(name))
                        continue;
                    // A class's static initialiser, behind its `__sinit_` guard:
                    // the host has run it before any block starts.
                    if (name.hasSuffix(String.withCString("$init")))
                        {
                        String* gn = String.withCString("__sinit_");
                        gn.append(name.substringBytes((u32)0, name.byteLength() - (u32)5));
                        if (_parSyms.get((Hashable*)gn) != (Object*)0)
                            continue;
                        }
                    // A subscript check is allowed by name: outside the program
                    // in a -fbounds-check build, Checked.xc's own body (which
                    // writes to stderr) under -fbounds-check=light.
                    if (name.hasPrefix(String.withCString("_xt_check_")) && parAllowedExternal(name))
                        continue;
                    IRFunc* callee = (IRFunc*)_parFns.get((Hashable*)name);
                    if (callee == (IRFunc*)0)
                        {
                        if (parAllowedExternal(name))
                            continue;
                        String* r = String.withCString("calls '");
                        r.append(self.parShown(name));
                        r.appendCString("', which is outside the program and cannot run on a GPU");
                        return r;
                        }
                    if (_parOnStack.get((Hashable*)name) != (Object*)0)
                        {
                        String* r = String.withCString("calls '");
                        r.append(self.parShown(name));
                        r.appendCString("' recursively; a GPU has no call stack for recursion");
                        return r;
                        }
                    String* inner = parReason(callee);
                    if (inner.byteLength() > (u32)0)
                        {
                        String* r = String.withCString("calls '");
                        r.append(self.parShown(name));
                        r.appendCString("', which ");
                        r.append(inner);
                        return r;
                        }
                    }
                }
            }
        return String.withCString("");
        }

    // The global a store writes, when its address is the global itself or a
    // field of it. An element of a global ARRAY is a buffer write: allowed.
    final String* parGlobalWritten(IRInsn* st, Map* def)
        {
        if (st.ops().count() == (u32)0 || ((IROperand*)st.ops().get((u32)0)).kind() != (u8)OPK_USE)
            return (String*)0;
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)st.ops().get((u32)0)).val().seq()));
        for (u32 hops = (u32)0; d != (IRInsn*)0 && hops < (u32)64; hops = hops + (u32)1)
            {
            if (d.op().equals(String.withCString("AddrOf")))
                {
                if (d.ops().count() > (u32)0 && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_SYM)
                    {
                    String* n = ((IROperand*)d.ops().get((u32)0)).name();
                    IRSymbol* s = (IRSymbol*)_parSyms.get((Hashable*)n);
                    if (s != (IRSymbol*)0 && s.kind() == (u8)SYM_DATAGLOBAL)
                        return n;
                    }
                return (String*)0;
                }
            if (!d.op().equals(String.withCString("FieldAddr")) && !d.op().equals(String.withCString("Bitcast")))
                return (String*)0;
            if (d.ops().count() == (u32)0 || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_USE)
                return (String*)0;
            d = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)d.ops().get((u32)0)).val().seq()));
            }
        return (String*)0;
        }
    }
