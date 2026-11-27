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
        _parPairs = new Map();
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
            if (f.parKernel() != (u8)PARK_BLOCK)
                continue;
            String* cls = f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4);
            // An auto block (--par-style=auto made it from a plain loop) the check
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
            // A :scan pass: its chunks own disjoint slices (#144).
            if (why == (String*)0 && parIsScanBlock(cls.substringBytes((u32)8, cls.byteLength() - (u32)8)))
                continue;
            if (why == (String*)0)
                {
                // §4: the work items must not touch each other's data.
                _parScatter = (String*)0;
                _parGuardList = new Array();
                _parFreshNow = Node.parFresh(cls);
                String* dep = parDependence(f, parIvarNames(cls));
                if (dep == (String*)0 && _parF4Pair >= (i32)0)
                    _parPairs.set((Hashable*)cls, (Object*)Number.with((u32)_parF4Pair));
                // A loop the compiler lifted by itself is a block only when its
                // items are proved apart: a scatter keeps it serial (a written
                // block's stays a warning). As the reference.
                if (dep == (String*)0 && isAuto && _parScatter != (String*)0)
                    {
                    dep = String.withCString("writes ");
                    dep.append(_parScatter);
                    dep.appendCString(", and two of them could write the same element");
                    }
                if (dep == (String*)0 && _parGuardList.count() > (u32)0)
                    _parGuards.set((Hashable*)cls, (Object*)_parGuardList);
                _parGuardList = (Array*)0;
                if (dep == (String*)0)
                    {
                    // A written block's call that may write a buffer from
                    // every item says so the same way (#513). Its code is
                    // unchanged.
                    String* passes = _parScatter == (String*)0 && !isAuto ? parCallScatter(f, parIvarNames(cls)) : (String*)0;
                    if (_parScatter != (String*)0 || passes != (String*)0)
                        {
                        String* w = String.withCString(_parScatter != (String*)0 ? "a 'par' block writes " : "a 'par' block passes ");
                        w.append(_parScatter != (String*)0 ? _parScatter : passes);
                        w.appendCString(", so the compiler cannot prove two work items never write the same element; if they can, the result depends on which runs last");
                        self.warnAtNode(String.withCString("par-scatter"), w, (Node*)_classDecls.get((Hashable*)cls));
                        }
                    // -Wpar-auto says what was wrapped as well as what was demoted.
                    if (isAuto)
                        self.warnAtNode(String.withCString("par-auto"), String.withCString("this loop became a 'par' block (--par-style)"),
                                   (Node*)_classDecls.get((Hashable*)cls));
                    continue;
                    }
                if (isAuto)
                    {
                    if (_parSerial == (Set*)0) _parSerial = new Set();
                    _parSerial.add((Hashable*)cls);
                    String* w2 = String.withCString("this loop runs serially, not as a 'par' block (--par-style): its work items are not independent, since it ");
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
                String* w3 = String.withCString("this loop runs serially, not as a 'par' block (--par-style): a GPU could not run it, since it ");
                w3.append(why);
                self.warnAtNode(String.withCString("par-auto"), w3, (Node*)_classDecls.get((Hashable*)cls));
                continue;
                }
            String* msg = String.withCString("a 'par' block must be able to run on a GPU, but this one ");
            msg.append(why);
            self.errorAtNode(msg, (Node*)_classDecls.get((Hashable*)cls));
            return;
            }
        self.parResolveKept();
        }

    // Each `Par.kept(n)` the parser put at a lifted loop's site becomes the
    // answer: true where block n stays a block, false where par-check demoted
    // it, so the branch not taken is dead code and goes. The call's memory
    // result is its memory input. As the reference.
    final void parResolveKept(void)
        {
        for (u32 fi = (u32)0; fi < _m.funcs().count(); fi = fi + (u32)1)
            {
            IRFunc* f = (IRFunc*)_m.funcs().get(fi);
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)f.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* c = (IRInsn*)bb.insns().get(i);
                    if (!c.isOp(opCall) || c.ops().count() != 3)
                        continue;
                    IROperand* callee = (IROperand*)c.ops().get((u32)0);
                    if (callee.kind() != (u8)OPK_SYM || !callee.name().equals(String.withCString("Par$kept")))
                        continue;
                    i64 n = parConstOperand(f, (IROperand*)c.ops().get((u32)1));
                    if (n < (i64)0)
                        continue;
                    String* cls = String.withCString("ParImpl$");
                    cls.append(String.withI64(n));
                    bool keep = _parSerial == (Set*)0 || !_parSerial.contains((Hashable*)cls);
                    IRInsn* k = IRInsn.with(String.withCString("Const"));
                    k.add(IROperand.immI(keep ? (i64)1 : (i64)0, String.withCString("Bool")));
                    k.setRes(c.res());
                    if (c.hasDbg())
                        k.setDbg(c.dbgFile(), c.dbgLine(), c.dbgCol());
                    bb.insns().set(i, (Object*)k);
                    if (c.memRes() != (IRValue*)0)
                        parRewriteUses(f, c.memRes(), (IROperand*)c.ops().get((u32)2));
                    }
                }
            }
        }

    // An integer operand's value: an immediate, or a Const through any
    // width changes. -1 when it is not one.
    final i64 parConstOperand(IRFunc* f, IROperand* o)
        {
        for (u32 depth = (u32)0; depth < (u32)8; depth = depth + (u32)1)
            {
            if (o.kind() == (u8)OPK_IMMI)
                return o.imm();
            if (o.kind() != (u8)OPK_USE)
                return (i64)-1;
            IRInsn* d = parDefOf(f, o.val());
            if (d == (IRInsn*)0 || d.ops().count() != (u32)1)
                return (i64)-1;
            u16 oc = d.opc();
            if (oc != opConst && oc != opZExt
                && oc != opSExt && oc != opTrunc)
                return (i64)-1;
            o = (IROperand*)d.ops().get((u32)0);
            }
        return (i64)-1;
        }

    final IRInsn* parDefOf(IRFunc* f, IRValue* v)
        {
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* d = (IRInsn*)bb.insns().get(i);
                if (d.res() == v)
                    return d;
                }
            }
        return (IRInsn*)0;
        }

    // Every use of `old` in f becomes `to`.
    final void parRewriteUses(IRFunc* f, IRValue* old, IROperand* to)
        {
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                parReplaceUse((IRInsn*)bb.phis().get(i), old, to);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                parReplaceUse((IRInsn*)bb.insns().get(i), old, to);
            if (bb.term() != (IRInsn*)0)
                parReplaceUse(bb.term(), old, to);
            }
        }

    final void parReplaceUse(IRInsn* n, IRValue* old, IROperand* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == old)
                n.ops().set(k, (Object*)to);
            }
        }

    // Whether block <n> (its class ParImpl$<n>) is one --par-style=auto made from a
    // plain loop: its GPU placeholder literal carries `auto;` after the tag.
    // Mirrors the reference's isAutoBlock.
    // The grid's constant width and height for block n, from its placeholder's
    // `gw=`/`gh=` words (0 when absent): set for the dependence test, which
    // runs before the printers' pass reads the words again. As the reference.
    final void parReadGridWords(String* n)
        {
        _mGridW = (i64)0;
        _mGridH = (i64)0;
        _mArrRed = new Map();
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
                    // `a<field>=<op>`: an array reduction's field.
                    if (inVal && key.byteLength() > (u32)1 && key.byteAt((u32)0) == (u8)'a')
                        _mArrRed.set((Hashable*)key.substringFromByte((u32)1), (Object*)val);
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
    // A pass of a rewritten :scan (#144): its placeholder's words hold
    // `scan;`. Its chunks own disjoint slices of what it writes, so the
    // dependence test does not apply, and it has no GPU form. Mirrors the
    // reference's isScanBlock.
    // Does the function, or one it calls, convert a 16-bit float (a call of
    // FloatPack.xc's _xt_fpk_*)? As the reference's XTParUsesFloatPack.
    // The element index an f4 array element's ElementAddr (the address of its
    // byte) was formed from (f4ElementAddr), or 0 for any other value.
    final IRValue* f4IndexOf(IRValue* ea)
        {
        if (ea == (IRValue*)0)
            return (IRValue*)0;
        for (u32 i = _nibAddrs.count(); i > (u32)0; i = i - (u32)1)
            if ((IRValue*)_nibAddrs.get(i - (u32)1) == ea)
                return (IRValue*)_nibIdx.get(i - (u32)1);
        return (IRValue*)0;
        }

    // Does the function, or one it calls, read or write an f4 array element?
    // A GPU kernel would rewrite a byte two work items share, so such a block
    // has no form. As the reference's XTParTouchesF4.
    final bool parTouchesF4(IRFunc* f, Map* seen)
        {
        if (f == 0 || seen.get((Hashable*)f.name()) != 0)
            return false;
        seen.set((Hashable*)f.name(), (Object*)f.name());
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* ci = (IRInsn*)ins.get(i);
                if (ci.isOp(opElementAddr) && f4IndexOf(ci.res()) != (IRValue*)0)
                    return true;
                if (!isName(ci.op(), "Call") || ci.ops().count() == 0)
                    continue;
                IROperand* o = (IROperand*)ci.ops().get(0);
                if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                    continue;
                for (u32 k = 0; k < _m.funcs().count(); k++)
                    {
                    IRFunc* g = (IRFunc*)_m.funcs().get(k);
                    if (g.name().equals(o.name()) && parTouchesF4(g, seen))
                        return true;
                    }
                }
            }
        return false;
        }

    // Does the function, or one it calls, use a tensor (a call of one of the
    // tensor classes' methods, `__tensor_<T>_<R>$…`)? GPU kernels take no
    // tensor yet, so such a block runs on the CPU. As the reference's
    // XTParTouchesTensor.
    final bool parTouchesTensor(IRFunc* f, Map* seen)
        {
        if (f == 0 || seen.get((Hashable*)f.name()) != 0)
            return false;
        seen.set((Hashable*)f.name(), (Object*)f.name());
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* ci = (IRInsn*)ins.get(i);
                if (!isName(ci.op(), "Call") || ci.ops().count() == 0)
                    continue;
                IROperand* o = (IROperand*)ci.ops().get(0);
                if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                    continue;
                if (o.name().hasPrefix(String.withCString("__tensor_")))
                    return true;
                for (u32 k = 0; k < _m.funcs().count(); k++)
                    {
                    IRFunc* g = (IRFunc*)_m.funcs().get(k);
                    if (g.name().equals(o.name()) && parTouchesTensor(g, seen))
                        return true;
                    }
                }
            }
        return false;
        }

    final bool parUsesFloatPack(IRFunc* f, Map* seen)
        {
        if (f == 0 || seen.get((Hashable*)f.name()) != 0)
            return false;
        seen.set((Hashable*)f.name(), (Object*)f.name());
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* ci = (IRInsn*)ins.get(i);
                if (!isName(ci.op(), "Call") || ci.ops().count() == 0)
                    continue;
                IROperand* o = (IROperand*)ci.ops().get(0);
                if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                    continue;
                if (o.name().hasPrefix(String.withCString("_xt_fpk_")))
                    return true;
                for (u32 k = 0; k < _m.funcs().count(); k++)
                    {
                    IRFunc* g = (IRFunc*)_m.funcs().get(k);
                    if (g.name().equals(o.name()) && parUsesFloatPack(g, seen))
                        return true;
                    }
                }
            }
        return false;
        }

    // Does the function, or one it calls, compute in a pack whose values reach
    // below float's normal range: a FloatPack call with 7 or more exponent
    // bits (bf16, f16:pack(e7m8))? Such a block's kernels keep subnormal
    // floats (_mSubn). As the reference's XTParPackKeepsSubnormals.
    final bool parPackKeepsSubnormals(IRFunc* f, Map* seen)
        {
        if (f == 0 || seen.get((Hashable*)f.name()) != 0)
            return false;
        seen.set((Hashable*)f.name(), (Object*)f.name());
        Map* defOf = new Map();
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* di = (IRInsn*)ins.get(i);
                if (di.res() != (IRValue*)0)
                    defOf.set((Hashable*)di.res(), (Object*)di);
                }
            }
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* ci = (IRInsn*)ins.get(i);
                if (!isName(ci.op(), "Call") || ci.ops().count() < 4)
                    continue;
                IROperand* o = (IROperand*)ci.ops().get(0);
                if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                    continue;
                if (o.name().hasPrefix(String.withCString("_xt_fpk_")))
                    {
                    // [callee, value, e, m, ...]: the exponent bits, a constant.
                    IROperand* e = (IROperand*)ci.ops().get(2);
                    i64 v = 0;
                    if (e.kind() == (u8)OPK_IMMI)
                        v = e.imm();
                    else if (e.kind() == (u8)OPK_USE)
                        {
                        IRInsn* d = (IRInsn*)defOf.get((Hashable*)e.val());
                        if (d != (IRInsn*)0 && d.isOp(opConst) && d.ops().count() > 0
                            && ((IROperand*)d.ops().get(0)).kind() == (u8)OPK_IMMI)
                            v = ((IROperand*)d.ops().get(0)).imm();
                        }
                    if (v >= 7)
                        return true;
                    continue;
                    }
                for (u32 k = 0; k < _m.funcs().count(); k++)
                    {
                    IRFunc* g = (IRFunc*)_m.funcs().get(k);
                    if (g.name().equals(o.name()) && parPackKeepsSubnormals(g, seen))
                        return true;
                    }
                }
            }
        return false;
        }

    // A pack's spelling from the (e, m) or (e, m, k) a FloatPack call takes,
    // as diagnostics write it. As the reference's XTParPackName.
    final String* parPackName(i64 e, i64 m, i64 k)
        {
        if ((k & 4) != 0)
            return String.withCString("f8:pack(ue8m0)");
        i64 kind = k & 3;
        i64 w = 1 + e + m;
        if (kind == 0 && e == 5 && m == 10)
            return String.withCString("f16");
        if (kind == 0 && e == 8 && m == 7)
            return String.withCString("bf16");
        if (kind == 1 && e == 4 && m == 3)
            return String.withCString("f8");
        if (kind == 2 && e == 2 && m == 1)
            return String.withCString("f4");
        // The kind is written when it is not the split's default: finite
        // for f8's e4m3, ieee for every other.
        i64 def = (w == 8 && e == 4 && m == 3) ? 1 : 0;
        string kn = kind == def ? "" : kind == 0 ? ",ieee" : kind == 1 ? ",finite" : ",none";
        return String.withFormat("f%ld:pack(e%ldm%ld%s)", w, e, m, kn);
        }

    final i64 parPackNum(IROperand* o, Map* defOf)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return o.imm();
        if (o.kind() != (u8)OPK_USE)
            return -1;
        IRInsn* d = (IRInsn*)defOf.get((Hashable*)o.val());
        if (d != (IRInsn*)0 && d.isOp(opConst) && d.ops().count() > 0
            && ((IROperand*)d.ops().get(0)).kind() == (u8)OPK_IMMI)
            return ((IROperand*)d.ops().get(0)).imm();
        return -1;
        }

    // The packs a block computes in, first met first, into names. As the
    // reference's XTParPackNames.
    final void parPackNames(IRFunc* f, Map* seen, Array* names)
        {
        if (f == 0 || seen.get((Hashable*)f.name()) != 0)
            return;
        seen.set((Hashable*)f.name(), (Object*)f.name());
        Map* defOf = new Map();
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* di = (IRInsn*)ins.get(i);
                if (di.res() != (IRValue*)0)
                    defOf.set((Hashable*)di.res(), (Object*)di);
                }
            }
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            Array* ins = ((IRBlock*)f.blocks().get(b)).insns();
            for (u32 i = 0; i < ins.count(); i++)
                {
                IRInsn* ci = (IRInsn*)ins.get(i);
                if (!isName(ci.op(), "Call") || ci.ops().count() == 0)
                    continue;
                IROperand* o = (IROperand*)ci.ops().get(0);
                if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                    continue;
                String* nm = o.name();
                if (nm.hasPrefix(String.withCString("_xt_fpk_unpack")) || nm.hasPrefix(String.withCString("_xt_fpk_pack_")))
                    {
                    // [callee, value, e, m, (k,) ...]; k for the kinds' routines.
                    bool kinds = nm.hasSuffix(String.withCString("k")) && !nm.equals(String.withCString("_xt_fpk_unpack"));
                    if (ci.ops().count() < (kinds ? (u32)5 : (u32)4))
                        continue;
                    i64 e = parPackNum((IROperand*)ci.ops().get(2), defOf);
                    i64 m = parPackNum((IROperand*)ci.ops().get(3), defOf);
                    i64 k = kinds ? parPackNum((IROperand*)ci.ops().get(4), defOf) : 0;
                    if (e < 0 || m < 0 || k < 0)
                        continue;
                    String* n = parPackName(e, m, k);
                    bool have = false;
                    for (u32 q = 0; q < names.count(); q++)
                        if (((String*)names.get(q)).equals(n))
                            have = true;
                    if (!have)
                        names.add((Object*)n);
                    continue;
                    }
                for (u32 k = 0; k < _m.funcs().count(); k++)
                    {
                    IRFunc* g = (IRFunc*)_m.funcs().get(k);
                    if (g.name().equals(nm))
                        parPackNames(g, seen, names);
                    }
                }
            }
        }

    // ` packs=<a>+<b>`, the packs a block's kernels compute in by converting
    // in the kernel, or "". As the reference.
    final String* parPackWords(IRFunc* f)
        {
        Array* names = new Array();
        parPackNames(f, new Map(), names);
        String* w = String.withCString("");
        for (u32 q = 0; q < names.count(); q++)
            {
            w.appendCString(q == 0 ? " packs=" : "+");
            w.append((String*)names.get(q));
            }
        return w;
        }

    final bool parIsScanBlock(String* n)
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
            String* word = new String();
            for (u32 q = tag.byteLength(); q < sym.bytes().count(); q = q + (u32)1)
                {
                u8 c = (u8)((Number*)sym.bytes().get(q)).asU32();
                if (c == (u8)0)
                    break;
                if (c == (u8)';')
                    {
                    if (word.equals(String.withCString("scan")))
                        return true;
                    word = new String();
                    }
                else
                    word.appendByte(c);
                }
            return false;
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
        // The whole ancestry, however deep (a cap of 16 named the wrong ivar
        // in a deeper hierarchy, #281); a class seen twice ends the walk.
        Array* chain = new Array();
        Set* seen = new Set();
        Node* d = (Node*)_classDecls.get((Hashable*)cls);
        while (d != (Node*)0 && !seen.contains((Hashable*)d.name()))
            {
            seen.add((Hashable*)d.name());
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
        u16 o = d.opc();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o == opConst)
            {
            if (o0.kind() == (u8)OPK_IMMI)
                return ParIdx.of(true, (i64)0, o0.imm());
            return ParIdx.of(false, (i64)0, (i64)0);
            }
        // A cut to 8 or 16 bits wraps inside the range ((u8)i repeats every
        // 256 items), so the index is not affine in i; a cut to 32 bits is
        // the loop variable's own width (#280).
        if (o == opTrunc && !Lower.parTruncWide(d))
            return ParIdx.of(false, (i64)0, (i64)0);
        if (o == opZExt || o == opSExt || o == opTrunc || o == opCopy)
            return parIndex(o0, iv, def, depth + (u32)1);
        bool isAdd = o == opAdd;
        bool isSub = o == opSub;
        bool isMul = o == opMul;
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
        // The products must not overflow (#280).
        if (ak == (i64)0 && Lower.parMulOk(ac, bk) && Lower.parMulOk(ac, bc))
            return ParIdx.of(true, ac * bk, ac * bc);
        if (bk == (i64)0 && Lower.parMulOk(bc, ak) && Lower.parMulOk(bc, ac))
            return ParIdx.of(true, bc * ak, bc * ac);
        return ParIdx.of(false, (i64)0, (i64)0);
        }

    // A Trunc to 32 bits or more (#280).
    static bool parTruncWide(IRInsn* d)
        {
        if (d.res() == (IRValue*)0 || d.res().ty() == (String*)0)
            return false;
        String* t = d.res().ty();
        return IRType.is(t, tyI32) || IRType.is(t, tyU32)
            || IRType.is(t, tyI64) || IRType.is(t, tyU64);
        }
    // a * b fits comfortably in an i64: both under 2^31 in magnitude.
    static bool parMulOk(i64 a, i64 b)
        {
        i64 lim = (i64)2147483647;
        return a == (i64)0 || b == (i64)0 || (a <= lim && a >= (i64)0 - lim && b <= lim && b >= (i64)0 - lim);
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
        u16 o = d.opc();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o == opConst)
            return o0.kind() == (u8)OPK_IMMI ? ParIdx.of(true, (i64)0, o0.imm()) : no;
        if (o == opTrunc && !Lower.parTruncWide(d))
            return no;
        if (o == opZExt || o == opSExt || o == opTrunc || o == opCopy)
            return parSymIndex(o0, iv, selfVal, def, depth + (u32)1);
        if (o == opLoad)
            {
            if (o0.kind() != (u8)OPK_USE || d.res() == (IRValue*)0 || !Lower.parIntType(d.res().ty()))
                return no;
            IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o0.val().seq()));
            if (fa == (IRInsn*)0 || !fa.isOp(opFieldAddr) || fa.ops().count() < 2)
                return no;
            IROperand* f0 = (IROperand*)fa.ops().get((u32)0);
            IROperand* f1 = (IROperand*)fa.ops().get((u32)1);
            if (f0.kind() != (u8)OPK_USE || f0.val() == (IRValue*)0 || selfVal == (IRValue*)0 || f0.val().seq() != selfVal.seq()
                || f1.kind() != (u8)OPK_IMMI || f1.imm() < (i64)3)
                return no;
            return ParIdx.sym(true, (i64)0, (i64)0, f1.imm(), (i64)1);
            }
        bool isAdd = o == opAdd;
        bool isSub = o == opSub;
        bool isMul = o == opMul;
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
            if (!Lower.parMulOk(s.k, fct) || !Lower.parMulOk(s.c, fct) || !Lower.parMulOk(s.m, fct) || !Lower.parMulOk(s.m2, fct))
                return no;
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
        return IRType.is(t, tyI8) || IRType.is(t, tyU8) || IRType.is(t, tyI16)
            || IRType.is(t, tyU16) || IRType.is(t, tyI32) || IRType.is(t, tyU32)
            || IRType.is(t, tyI64) || IRType.is(t, tyU64);
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
    // A tensor accessor's element type, from its symbol
    // `__tensor_<T>_<R>$_get`: `<T>` (the rank and method cut off). As the
    // reference's XTTensorElemOf.
    static String* tensorElemOf(String* sym)
        {
        u32 d = sym.indexOfByte((u8)'$');
        String* cls = sym;
        if (d != String.notFound())
            cls = sym.substringBytes((u32)0, d);
        u32 us = cls.lastIndexOfByte((u8)'_');
        if (us == String.notFound() || us < (u32)9)
            return cls;
        return cls.substringBytes((u32)9, us - (u32)9);
        }

    // The captured tensor whose address `base` is (the block object's field
    // k, or a pointer loaded from it): its name, or 0. As the reference's
    // tensorOf.
    final String* parTensorOf(IROperand* base, Array* ivars, Map* def)
        {
        if (base.kind() != (u8)OPK_USE)
            return (String*)0;
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(base.val().seq()));
        if (d != (IRInsn*)0 && d.isOp(opLoad) && d.ops().count() > (u32)0
            && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            d = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)d.ops().get((u32)0)).val().seq()));
        if (d == (IRInsn*)0 || !d.isOp(opFieldAddr) || d.ops().count() < 2)
            return (String*)0;
        IROperand* f0 = (IROperand*)d.ops().get((u32)0);
        IROperand* f1 = (IROperand*)d.ops().get((u32)1);
        if (f0.kind() != (u8)OPK_USE || f0.val() == (IRValue*)0 || def.get((Hashable*)String.withU32(f0.val().seq())) != (Object*)0 || f1.kind() != (u8)OPK_IMMI)
            return (String*)0;
        i64 k = f1.imm();
        if (k < (i64)1 || k > (i64)ivars.count())
            return (String*)0;
        return (String*)ivars.get((u32)(k - (i64)1));
        }

    // Tensor elements in a block: `t[i, j]` is a call of the tensor class's
    // _get or _set, the tensor's address first and its first index next. Two
    // tensor values may share one storage, so a block writes through one
    // tensor only, and each work item keeps to its own first index: every
    // write's, and every read's of the written tensor, is the one k * i + c
    // with k != 0. So is every read of another tensor of the same element
    // type, which may share the written one's storage, unless both are fresh
    // locals (Node.parFresh). The dependence, or 0. As the reference's
    // tensorDependenceIn.
    final String* parTensorDependence(IRFunc* f, IRValue* iv, Array* ivars, Map* def)
        {
        String* wbuf = (String*)0;
        String* wsym = (String*)0;
        i64 wk = 0;
        i64 wc = 0;
        // A second written tensor: a slice of the same tensor as the first,
        // split at the same place (`a&b` in Node.parFresh, the parser's
        // parTensorDisjoint).
        String* wbuf2 = (String*)0;
        i64 wk2 = 0;
        i64 wc2 = 0;
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)f.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* ip = (IRInsn*)bb.insns().get(i);
                    if (!isName(ip.op(), "Call") || ip.ops().count() < (u32)3)
                        continue;
                    IROperand* o = (IROperand*)ip.ops().get((u32)0);
                    if (o.kind() != (u8)OPK_SYM || o.name() == 0 || !o.name().hasPrefix(String.withCString("__tensor_")))
                        continue;
                    if (!o.name().hasSuffix(String.withCString(pass == (u32)0 ? "$_set" : "$_get")))
                        continue;
                    String* buf = parTensorOf((IROperand*)ip.ops().get((u32)1), ivars, def);
                    ParIdx* x = parIndex((IROperand*)ip.ops().get((u32)2), iv, def, (u32)0);
                    if (pass == (u32)0)
                        {
                        if (buf == (String*)0)
                            return String.withCString("writes a tensor it cannot name, which may share a storage with another, so two work items could write one element");
                        if (wbuf != (String*)0 && !buf.equals(wbuf))
                            {
                            bool second = false;
                            if (wbuf2 != (String*)0)
                                second = buf.equals(wbuf2);
                            else
                                second = self.parFreshHas(wbuf, "&", buf);
                            if (!second)
                                return String.withFormat("writes the tensors '%s' and '%s', which may share one storage, so two work items could write one element; write one tensor in a block",
                                                         self.parShown(wbuf).cString(), self.parShown(buf).cString());
                            if (!x.affine || x.k == (i64)0)
                                return String.withFormat("writes the tensor '%s' at a first index that is not k * i + c, so two work items could write one element",
                                                         self.parShown(buf).cString());
                            if (wbuf2 != (String*)0 && (x.k != wk2 || x.c != wc2))
                                return String.withFormat("writes the tensor '%s' at two first indices, so two work items could write one element",
                                                         self.parShown(buf).cString());
                            wbuf2 = buf;
                            wk2 = x.k;
                            wc2 = x.c;
                            continue;
                            }
                        if (!x.affine || x.k == (i64)0)
                            return String.withFormat("writes the tensor '%s' at a first index that is not k * i + c, so two work items could write one element",
                                                     self.parShown(buf).cString());
                        if (wbuf != (String*)0 && (x.k != wk || x.c != wc))
                            return String.withFormat("writes the tensor '%s' at two first indices, so two work items could write one element",
                                                     self.parShown(buf).cString());
                        wbuf = buf;
                        wk = x.k;
                        wc = x.c;
                        wsym = Lower.tensorElemOf(o.name());
                        continue;
                        }
                    if (wbuf == (String*)0)
                        continue;
                    bool at1 = x.affine && x.k == wk && x.c == wc;
                    bool at2 = wbuf2 != (String*)0 && x.affine && x.k == wk2 && x.c == wc2;
                    if (buf != (String*)0 && (buf.equals(wbuf) || (wbuf2 != (String*)0 && buf.equals(wbuf2))))
                        {
                        bool first = buf.equals(wbuf);
                        if ((first && !at1) || (!first && !at2))
                            return String.withFormat("reads the tensor '%s' at a first index other than the one it writes, so a work item could read an element another one writes",
                                                     self.parShown(buf).cString());
                        continue;
                        }
                    // A read of another tensor elsewhere than a written row:
                    // of any tensor that may share a written one's storage
                    // (the same element type, unless the two are distinct).
                    // As the reference.
                    if (!Lower.tensorElemOf(o.name()).equals(wsym))
                        continue;
                    for (u32 w = (u32)0; w < (u32)2; w = w + (u32)1)
                        {
                        String* wb = w == (u32)0 ? wbuf : wbuf2;
                        bool at = w == (u32)0 ? at1 : at2;
                        if (wb == (String*)0 || at || self.parTensorsDistinct(buf, wb))
                            continue;
                        String* bs = String.withCString("?");
                        if (buf != (String*)0)
                            bs = self.parShown(buf);
                        return String.withFormat("writes the tensor '%s' and reads the tensor '%s' at a different row; they may share storage: read '%s' at the same row, or copy it first",
                                                 self.parShown(wb).cString(), bs.cString(), bs.cString());
                        }
                    }
                }
        return (String*)0;
        }

    // Is "<x><sep><y>" in the block's tensor set (Node.parFresh)?
    final bool parFreshHas(String* x, string sep, String* y)
        {
        if (_parFreshNow == (Set*)0 || x == (String*)0 || y == (String*)0)
            return false;
        String* k = String.withString(x);
        k.appendCString(sep);
        k.append(y);
        return _parFreshNow.contains((Hashable*)k);
        }

    // Two tensors that cannot share a storage: both fresh locals, or views of
    // two fresh locals (`a|b`). As the reference's distinct.
    final bool parTensorsDistinct(String* x, String* y)
        {
        if (x == (String*)0 || y == (String*)0 || _parFreshNow == (Set*)0)
            return false;
        if (_parFreshNow.contains((Hashable*)x) && _parFreshNow.contains((Hashable*)y))
            return true;
        return self.parFreshHas(x, "|", y);
        }

    final String* parBufferOf(IROperand* base, IRValue* selfVal, Array* ivars, Map* def)
        {
        if (base.kind() != (u8)OPK_USE)
            return (String*)0;
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(base.val().seq()));
        // Through a pointer cast (the C path casts its untyped pointers
        // where they are used).
        while (d != (IRInsn*)0 && d.isOp(opBitcast) && d.ops().count() == 1
               && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            d = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)d.ops().get((u32)0)).val().seq()));
        if (d == (IRInsn*)0 || d.ops().count() == (u32)0)
            return (String*)0;
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (d.isOp(opAddrOf) && o0.kind() == OPK_SYM)
            {
            IRSymbol* s = (IRSymbol*)_parSyms.get((Hashable*)o0.name());
            if (s != (IRSymbol*)0 && s.kind() == (u8)SYM_DATAGLOBAL)
                return o0.name();
            return (String*)0;
            }
        if (!d.isOp(opLoad) || o0.kind() != OPK_USE)
            return (String*)0;
        IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o0.val().seq()));
        if (fa == (IRInsn*)0 || !fa.isOp(opFieldAddr) || fa.ops().count() < 2)
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
        u16 o = d.opc();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o == opConst)
            return o0.kind() == (u8)OPK_IMMI ? parPoly1("", o0.imm()) : (Map*)0;
        if (o == opTrunc && !Lower.parTruncWide(d))
            return (Map*)0;
        if (o == opZExt || o == opSExt || o == opTrunc || o == opCopy)
            return parGridPoly(o0, iv, selfVal, ivars, def, depth + (u32)1);
        if (o == opLoad)
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
            if (fa == (IRInsn*)0 || !fa.isOp(opFieldAddr) || fa.ops().count() < 2)
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
        bool isRem = o == opURem;
        bool isDiv = o == opUDiv;
        bool isAdd = o == opAdd;
        bool isSub = o == opSub;
        bool isMul = o == opMul;
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
                    if (!Lower.parMulOk(parCoef(a, ma), parCoef(b, mb)))
                        return (Map*)0;
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
                if (!gb2.isOp(opICmp))
                    continue;
                for (u32 q = (u32)0; q < gb2.ops().count(); q = q + (u32)1) {
                    IROperand* o = (IROperand*)gb2.ops().get(q);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    IRInsn* dd = (IRInsn*)def.get((Hashable*)String.withU32(o.val().seq()));
                    if (dd != (IRInsn*)0 && dd.isOp(opPhi))
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
        words.append(String.withU32(self.gpuBytes(lay.typeAt((u32)q))));
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
        words.append(String.withU32(self.gpuBytes(lay.typeAt((u32)q))));
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
            words.append(String.withU32(self.gpuBytes(lay.typeAt((u32)sl))));
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
        // A grid's rows (#776): per buffer, the field of K when every access
        // is y * K + k (k counting over [0, K)), else -1.
        Map* rowFld = new Map();
        // And whether every item walks all of its rows (whole=).
        Map* rowWhole = new Map();
        // whole=<k> (an outlined block only: C's malloc'd arrays are in no
        // registry, so the runtime sizes them from the footprint): accesses
        // that run for every item reach both ends of the array's footprint,
        // so the program itself touches all of it. The reference has no
        // outliner.
        // Written blocks too (#776): an array from new under 64 KB is in no
        // registry either, so a GPU sizes it from its footprint.
        Map* every = (Map*)0;
        if (iv != (IRValue*)0)
            {
            IRBlock* hb = (IRBlock*)phiBlk.get((Hashable*)String.withU32(iv.seq()));
            if (hb != (IRBlock*)0)
                every = parEveryItemBlocks(f, hb);
            }
        Map* onceLo = new Map();
        Map* onceHi = new Map();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                u16 oc = ip.opc();
                bool isStore = oc == opStore || oc == opStoreVolatile;
                bool isLoad = oc == opLoad || oc == opLoadVolatile;
                if ((!isStore && !isLoad) || ip.ops().count() == (u32)0)
                    continue;
                IROperand* a0 = (IROperand*)ip.ops().get((u32)0);
                if (a0.kind() != (u8)OPK_USE)
                    continue;
                IRInsn* ea = (IRInsn*)def.get((Hashable*)String.withU32(a0.val().seq()));
                if (ea == (IRInsn*)0 || !ea.isOp(opElementAddr) || ea.ops().count() < 2)
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
                    if (inner == (IRInsn*)0 || !inner.isOp(opElementAddr) || inner.ops().count() < 2
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
                // The accesses that run for every item, by their lowest and
                // highest offset (with the footprint's k).
                if (every != (Map*)0 && every.get((Hashable*)bb.name()) != (Object*)0 && px.affine && px.k != (i64)0)
                    {
                    String* kk = String.withFormat("%s:%ld", buf.cString(), px.k);
                    Number* ol = (Number*)onceLo.get((Hashable*)kk);
                    Number* oh = (Number*)onceHi.get((Hashable*)kk);
                    if (ol == (Number*)0 || rlo < ol.asI64())
                        onceLo.set((Hashable*)kk, (Object*)Number.withI64(rlo));
                    if (oh == (Number*)0 || rhi > oh.asI64())
                        onceHi.set((Hashable*)kk, (Object*)Number.withI64(rhi));
                    }
                i64 rowF = (i64)-1;
                if (terms.count() == (u32)1 && (px == (ParIdx*)0 || !px.affine))
                    rowF = parRowField((IROperand*)ea.ops().get((u32)1), iv, selfVal, ivars, def, phiBlk);
                // Whole: the access runs on every pass of an inner loop that
                // runs for every item, counting by one over all of [0, K).
                bool rw = rowF >= (i64)0 && every != (Map*)0 && _parRowHead != (IRBlock*)0 && _parRowStep == (i64)1
                          && every.get((Hashable*)_parRowHead.name()) != (Object*)0;
                // The inner loop's body is one block, the header's true edge,
                // straight back to the header: the access runs every pass.
                if (rw)
                    {
                    IRInsn* ht = _parRowHead.term();
                    IRInsn* bt = bb.term();
                    rw = ht != (IRInsn*)0 && ht.isOp(opCondBranch) && ht.ops().count() >= (u32)3
                         && ((IROperand*)ht.ops().get((u32)1)).kind() == (u8)OPK_BLOCK && ((IROperand*)ht.ops().get((u32)1)).blk() == bb
                         && bt != (IRInsn*)0 && bt.isOp(opBranch) && bt.ops().count() == (u32)1
                         && ((IROperand*)bt.ops().get((u32)0)).kind() == (u8)OPK_BLOCK && ((IROperand*)bt.ops().get((u32)0)).blk() == _parRowHead;
                    }
                if (rowFld.get((Hashable*)buf) == (Object*)0)
                    {
                    rowFld.set((Hashable*)buf, (Object*)Number.withI64(rowF));
                    rowWhole.set((Hashable*)buf, (Object*)Number.with(rw ? (u32)1 : (u32)0));
                    }
                else
                    {
                    if (((Number*)rowFld.get((Hashable*)buf)).asI64() != rowF)
                        rowFld.set((Hashable*)buf, (Object*)Number.withI64((i64)-1));
                    if (rw)
                        rowWhole.set((Hashable*)buf, (Object*)Number.with((u32)1));
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
        String* wholes = new String();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* buf = (String*)order.get(i);
            if (((Number*)fpOk.get((Hashable*)buf)).asI64() == (i64)0)
                {
                String* rw = parRowWord(f, buf, ivars, ((Number*)rowFld.get((Hashable*)buf)).asI64());
                words.append(rw);
                if (rw.byteLength() > (u32)0 && ((Number*)rowWhole.get((Hashable*)buf)).asU32() != (u32)0)
                    {
                    u32 ra = (u32)0;
                    for (u32 j = (u32)0; j < ivars.count(); j = j + (u32)1)
                        if (((String*)ivars.get(j)).equals(buf))
                            ra = j;
                    wholes.appendCString(" whole=");
                    wholes.append(String.withU32(ra - (u32)2));
                    }
                continue;
                }
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
            String* kk = String.withFormat("%s:%ld", buf.cString(), ((Number*)fpK.get((Hashable*)buf)).asI64());
            Number* ol = (Number*)onceLo.get((Hashable*)kk);
            Number* oh = (Number*)onceHi.get((Hashable*)kk);
            if (found && ol != (Number*)0 && oh != (Number*)0 && ol.asI64() == ((Number*)fpLo.get((Hashable*)buf)).asI64()
                && oh.asI64() == ((Number*)fpHi.get((Hashable*)buf)).asI64())
                {
                wholes.appendCString(" whole=");
                wholes.append(String.withU32(at - (u32)2));
                }
            }
        words.append(wholes);
        return words;
        }

    // fpr=<k>:<woff>:<koff> for captured array k when its rows are its
    // footprint (rowF the field of K, else -1): the runtime reads the grid's
    // width and K at those offsets in the block's object and takes rows
    // lo / W to (hi - 1) / W, each K elements (#776). "" otherwise.
    final String* parRowWord(IRFunc* f, String* buf, Array* ivars, i64 rowF)
        {
        if (rowF < (i64)0 || f.params().count() == (u32)0)
            return String.withCString("");
        u32 at = (u32)$FFFFFFFF;
        u32 wAt = (u32)$FFFFFFFF;
        for (u32 j = (u32)0; j < ivars.count(); j = j + (u32)1)
            {
            String* n = (String*)ivars.get(j);
            if (n.equals(buf)) at = j;
            if (n.equals(String.withCString("par$w"))) wAt = j;
            }
        if (at == (u32)$FFFFFFFF || at < (u32)2 || wAt == (u32)$FFFFFFFF)
            return String.withCString("");
        IRLayout* lay = self.mslLayoutOf(mslPointee(((IRValue*)f.params().get((u32)0)).ty()));
        if (lay == (IRLayout*)0 || (u32)rowF >= lay.fieldCount() || wAt + (u32)1 >= lay.fieldCount())
            return String.withCString("");
        String* w = String.withCString(" fpr=");
        w.append(String.withU32(at - (u32)2));
        w.appendCString(":");
        w.append(String.withU32(lay.offsetAt(wAt + (u32)1)));
        w.appendCString(":");
        w.append(String.withU32(lay.offsetAt((u32)rowF)));
        return w;
        }

    // The field of K when op is y * K + k in a 2-D grid: y the point's row,
    // K a captured integer, k an inner loop's counter from 0 while below that
    // same K, tested before its body. -1 for any other index (#776). As the
    // reference's rowFieldOf.
    final i64 parRowField(IROperand* op, IRValue* iv, IRValue* selfVal, Array* ivars, Map* def, Map* phiBlk)
        {
        bool hasW = false;
        for (u32 i = (u32)0; i < ivars.count(); i = i + (u32)1)
            {
            String* n = (String*)ivars.get(i);
            if (n.equals(String.withCString("par$w"))) hasW = true;
            if (n.equals(String.withCString("par$d"))) return (i64)-1;
            }
        if (!hasW || iv == (IRValue*)0)
            return (i64)-1;
        _parRowHead = (IRBlock*)0;
        _parRowStep = (i64)0;
        IRInsn* d = parStripExt(op, def);
        if (d == (IRInsn*)0 || !d.isOp(opAdd) || d.ops().count() != (u32)2)
            return (i64)-1;
        for (u32 s = (u32)0; s < (u32)2; s = s + (u32)1)
            {
            IRInsn* m = parStripExt((IROperand*)d.ops().get(s), def);
            if (m == (IRInsn*)0 || !m.isOp(opMul) || m.ops().count() != (u32)2)
                continue;
            for (u32 t = (u32)0; t < (u32)2; t = t + (u32)1)
                {
                Map* py = parGridPoly((IROperand*)m.ops().get(t), iv, selfVal, ivars, def, (u32)0);
                Map* pk = parGridPoly((IROperand*)m.ops().get((u32)1 - t), iv, selfVal, ivars, def, (u32)0);
                if (py == (Map*)0 || pk == (Map*)0 || !(parIsAtom(py, "y") || parIsAtom(py, "q")))
                    continue;
                i64 fld = parCapAtom(pk);
                if (fld < (i64)0)
                    continue;
                if (parCounterBelow((IROperand*)d.ops().get((u32)1 - s), fld, iv, selfVal, ivars, def, phiBlk))
                    return fld;
                }
            }
        return (i64)-1;
        }

    // The instruction behind op, through width changes; 0 for no instruction.
    final IRInsn* parStripExt(IROperand* op, Map* def)
        {
        IROperand* at = op;
        for (u32 g = (u32)0; g < (u32)4; g = g + (u32)1)
            {
            if (at.kind() != (u8)OPK_USE || at.val() == (IRValue*)0)
                return (IRInsn*)0;
            IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(at.val().seq()));
            if (d == (IRInsn*)0)
                return (IRInsn*)0;
            if (!(d.isOp(opZExt) || d.isOp(opSExt)) || d.ops().count() == (u32)0)
                return d;
            at = (IROperand*)d.ops().get((u32)0);
            }
        return (IRInsn*)0;
        }

    // The field of a polynomial that is one captured integer ("#<field>"
    // times 1), else -1.
    final i64 parCapAtom(Map* p)
        {
        if (p.count() != (u32)1)
            return (i64)-1;
        String* k = (String*)p.allKeys().get((u32)0);
        if (!k.hasPrefix(String.withCString("#")) || parCoef(p, k) != (i64)1)
            return (i64)-1;
        i64 v = (i64)0;
        for (u32 j = (u32)1; j < k.byteLength(); j = j + (u32)1)
            v = v * (i64)10 + (i64)(k.byteAt(j) - (u8)'0');
        return v;
        }

    // Whether op is an inner loop's counter: a phi in its loop's header, from
    // 0, stepped by a positive constant, the header's test `phi < K` (K the
    // captured field fld) with the body on its true edge.
    final bool parCounterBelow(IROperand* op, i64 fld, IRValue* iv, IRValue* selfVal, Array* ivars, Map* def, Map* phiBlk)
        {
        IRInsn* ph = parStripExt(op, def);
        if (ph == (IRInsn*)0 || !ph.isOp(opPhi) || ph.ops().count() != (u32)4 || ph.res() == (IRValue*)0 || ph.res() == iv)
            return false;
        IRValue* pv = ph.res();
        IRBlock* H = (IRBlock*)phiBlk.get((Hashable*)String.withU32(pv.seq()));
        if (H == (IRBlock*)0)
            return false;
        bool zero = false;
        bool stepped = false;
        i64 stepBy = (i64)0;
        for (u32 e = (u32)0; e < (u32)2; e = e + (u32)1)
            {
            IROperand* ev = (IROperand*)ph.ops().get(e * (u32)2 + (u32)1);
            if (ev.kind() == (u8)OPK_IMMI)
                {
                zero = zero || ev.imm() == (i64)0;
                continue;
                }
            // Through width changes: xc writes 0 as a byte, widened.
            IRInsn* ed = parStripExt(ev, def);
            if (ed == (IRInsn*)0)
                return false;
            if (ed.isOp(opConst) && ((IROperand*)ed.ops().get((u32)0)).kind() == (u8)OPK_IMMI)
                {
                zero = zero || ((IROperand*)ed.ops().get((u32)0)).imm() == (i64)0;
                continue;
                }
            IROperand* a0 = ed.ops().count() == (u32)2 ? (IROperand*)ed.ops().get((u32)0) : (IROperand*)0;
            IROperand* a1 = ed.ops().count() == (u32)2 ? (IROperand*)ed.ops().get((u32)1) : (IROperand*)0;
            i64 st = (i64)0;
            if (a1 != (IROperand*)0 && a1.kind() == (u8)OPK_IMMI)
                st = a1.imm();
            else if (a1 != (IROperand*)0 && a1.kind() == (u8)OPK_USE)
                {
                IRInsn* sd = parStripExt(a1, def);
                if (sd != (IRInsn*)0 && sd.isOp(opConst) && ((IROperand*)sd.ops().get((u32)0)).kind() == (u8)OPK_IMMI)
                    st = ((IROperand*)sd.ops().get((u32)0)).imm();
                }
            if (ed.isOp(opAdd) && a0 != (IROperand*)0 && a0.kind() == (u8)OPK_USE && a0.val() == pv && st > (i64)0)
                {
                stepped = true;
                stepBy = st;
                continue;
                }
            return false;
            }
        if (!zero || !stepped)
            return false;
        IRInsn* t = H.term();
        if (t == (IRInsn*)0 || !t.isOp(opCondBranch) || t.ops().count() < 3)
            return false;
        IROperand* c0 = (IROperand*)t.ops().get((u32)0);
        IRInsn* g = c0.kind() == (u8)OPK_USE ? (IRInsn*)def.get((Hashable*)String.withU32(c0.val().seq())) : (IRInsn*)0;
        if (g == (IRInsn*)0 || !g.isOp(opICmp) || g.ops().count() < 2 || g.pred() == (String*)0)
            return false;
        if (!(g.pred().equals(String.withCString("ULT")) || g.pred().equals(String.withCString("SLT"))))
            return false;
        IROperand* g0 = (IROperand*)g.ops().get((u32)0);
        if (g0.kind() != (u8)OPK_USE || g0.val() != pv)
            return false;
        Map* pb = parGridPoly((IROperand*)g.ops().get((u32)1), iv, selfVal, ivars, def, (u32)0);
        if (pb == (Map*)0 || parCapAtom(pb) != fld)
            return false;
        _parRowHead = H;
        _parRowStep = stepBy;
        return true;
        }

    // The blocks of f's item loop (through H, the induction phi's block) that
    // run once for every item: those on every path from H to the loop's one
    // back edge, when the loop is left only from H or from that back edge's
    // block. 0 for any other shape (a break, a second back edge, a switch).
    final Map* parEveryItemBlocks(IRFunc* f, IRBlock* H)
        {
        Map* fwd = new Map();
        Array* work = new Array();
        fwd.set((Hashable*)H.name(), (Object*)H);
        work.add((Object*)H);
        for (u32 w = (u32)0; w < work.count(); w = w + (u32)1)
            {
            IRInsn* t = ((IRBlock*)work.get(w)).term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && fwd.get((Hashable*)o.blk().name()) == (Object*)0)
                    {
                    fwd.set((Hashable*)o.blk().name(), (Object*)o.blk());
                    work.add((Object*)o.blk());
                    }
                }
            }
        // The blocks that reach H, among those H reaches: the loop.
        Map* loop = new Map();
        loop.set((Hashable*)H.name(), (Object*)H);
        bool grew = true;
        while (grew)
            {
            grew = false;
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)f.blocks().get(b);
                if (fwd.get((Hashable*)bb.name()) == (Object*)0 || loop.get((Hashable*)bb.name()) != (Object*)0 || bb.term() == (IRInsn*)0)
                    continue;
                for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)bb.term().ops().get(k);
                    if (o.kind() == (u8)OPK_BLOCK && loop.get((Hashable*)o.blk().name()) != (Object*)0)
                        {
                        loop.set((Hashable*)bb.name(), (Object*)bb);
                        grew = true;
                        break;
                        }
                    }
                }
            }
        // One back edge (its block, the latch) and every way out from H or
        // the latch.
        IRBlock* latch = (IRBlock*)0;
        u32 latches = (u32)0;
        IRBlock* exitFrom = (IRBlock*)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            if (loop.get((Hashable*)bb.name()) == (Object*)0)
                continue;
            IRInsn* t = bb.term();
            if (t == (IRInsn*)0 || (!t.isOp(opBranch) && !t.isOp(opCondBranch)))
                return (Map*)0;
            for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK)
                    continue;
                if (o.blk() == H)
                    {
                    if (latch != bb)
                        latches = latches + (u32)1;
                    latch = bb;
                    }
                else if (loop.get((Hashable*)o.blk().name()) == (Object*)0)
                    {
                    if (exitFrom != (IRBlock*)0 && exitFrom != bb)
                        return (Map*)0;
                    exitFrom = bb;
                    }
                }
            }
        if (latches != (u32)1 || exitFrom == (IRBlock*)0 || (exitFrom != H && exitFrom != latch))
            return (Map*)0;
        // A block runs for every item when the latch cannot be reached from
        // H without passing through it.
        Map* once = new Map();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cand = (IRBlock*)f.blocks().get(b);
            if (loop.get((Hashable*)cand.name()) == (Object*)0)
                continue;
            if (cand == H || cand == latch)
                {
                once.set((Hashable*)cand.name(), (Object*)cand);
                continue;
                }
            Map* seen = new Map();
            Array* q = new Array();
            seen.set((Hashable*)H.name(), (Object*)H);
            q.add((Object*)H);
            bool reached = false;
            for (u32 w = (u32)0; w < q.count() && !reached; w = w + (u32)1)
                {
                IRInsn* t = ((IRBlock*)q.get(w)).term();
                for (u32 k = (u32)0; k < t.ops().count() && !reached; k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)t.ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() == cand || o.blk() == H
                        || loop.get((Hashable*)o.blk().name()) == (Object*)0 || seen.get((Hashable*)o.blk().name()) != (Object*)0)
                        continue;
                    if (o.blk() == latch)
                        reached = true;
                    seen.set((Hashable*)o.blk().name(), (Object*)o.blk());
                    q.add((Object*)o.blk());
                    }
                }
            if (!reached)
                once.set((Hashable*)cand.name(), (Object*)cand);
            }
        return once;
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
        u16 o = d.opc();
        IROperand* o0 = (IROperand*)d.ops().get((u32)0);
        if (o == opConst)
            {
            if (o0.kind() != (u8)OPK_IMMI)
                return false;
            lo[0] = o0.imm();
            hi[0] = o0.imm();
            return true;
            }
        if (o == opZExt || o == opSExt || o == opCopy)
            {
            if (!parRangeIndex(o0, iv, def, phiBlk, depth + (u32)1, k, lo, hi))
                return false;
            return o == opSExt || o == opCopy || (lo[0] >= 0 && k[0] == 0);
            }
        if ((o == opAdd || o == opSub || o == opMul) && d.ops().count() == 2)
            {
            i64 ak = (i64)0; i64 al = (i64)0; i64 ah = (i64)0;
            i64 bk = (i64)0; i64 bl = (i64)0; i64 bh = (i64)0;
            if (!parRangeIndex(o0, iv, def, phiBlk, depth + (u32)1, &ak, &al, &ah)
                || !parRangeIndex((IROperand*)d.ops().get((u32)1), iv, def, phiBlk, depth + (u32)1, &bk, &bl, &bh))
                return false;
            if (o == opAdd)
                {
                k[0] = ak + bk; lo[0] = al + bl; hi[0] = ah + bh;
                return true;
                }
            if (o == opSub)
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
        if (o == opShl && d.ops().count() == 2)
            {
            IROperand* sh = (IROperand*)d.ops().get((u32)1);
            i64 n = (i64)0 - (i64)1;
            if (sh.kind() == (u8)OPK_IMMI)
                n = sh.imm();
            else if (sh.kind() == (u8)OPK_USE)
                {
                IRInsn* sd = (IRInsn*)def.get((Hashable*)String.withU32(sh.val().seq()));
                if (sd != (IRInsn*)0 && sd.isOp(opConst) && ((IROperand*)sd.ops().get(0)).kind() == OPK_IMMI)
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
        if (o == opPhi && d.ops().count() == 4)
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
            if (ed.isOp(opConst) && ((IROperand*)ed.ops().get(0)).kind() == OPK_IMMI)
                {
                start = ((IROperand*)ed.ops().get((u32)0)).imm();
                haveStart = true;
                continue;
                }
            IROperand* a0 = ed.ops().count() == (u32)2 ? (IROperand*)ed.ops().get((u32)0) : (IROperand*)0;
            IROperand* a1 = ed.ops().count() == (u32)2 ? (IROperand*)ed.ops().get((u32)1) : (IROperand*)0;
            if (ed.isOp(opAdd) && a0 != (IROperand*)0 && a0.kind() == OPK_USE && a0.val() == pv
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
        if (t == (IRInsn*)0 || !t.isOp(opCondBranch) || t.ops().count() < 3)
            return false;
        IROperand* c0 = (IROperand*)t.ops().get((u32)0);
        IRInsn* g = c0.kind() == (u8)OPK_USE ? (IRInsn*)def.get((Hashable*)String.withU32(c0.val().seq())) : (IRInsn*)0;
        if (g == (IRInsn*)0 || !g.isOp(opICmp) || g.ops().count() < 2 || g.pred() == (String*)0)
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
            if (nd != (IRInsn*)0 && nd.isOp(opAdd) && nd.ops().count() == 2
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
            if (bd == (IRInsn*)0 || !bd.isOp(opConst) || ((IROperand*)bd.ops().get(0)).kind() != OPK_IMMI)
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
    final bool parIsComputeOp(u16 op)
        {
        return op == opAdd || op == opSub
            || op == opMul || op == opUDiv
            || op == opSDiv || op == opURem
            || op == opSRem || op == opShl
            || op == opLShr || op == opAShr
            || op == opAnd || op == opOr
            || op == opXor || op == opNeg
            || op == opNot || op == opFAdd
            || op == opFSub || op == opFMul
            || op == opFDiv || op == opFNeg
            || op == opFSqrt || op == opICmp
            || op == opFCmp || op == opSelect
            || op == opSIToFp || op == opUIToFp
            || op == opFpToSI || op == opFpToUI
            || op == opFpExt || op == opFpTrunc;
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
                if (parIsComputeOp(ins.opc()))
                    *ops = *ops + (i64)1;
                if ((ins.isOp(opCall) || ins.isOp(opCallBanked)
                     || ins.isOp(opCallCloaked))
                    && ins.ops().count() > (u32)0 && ((IROperand*)ins.ops().get((u32)0)).kind() == (u8)OPK_SYM)
                    {
                    String* callee = ((IROperand*)ins.ops().get((u32)0)).name();
                    IRFunc* target = (IRFunc*)0;
                    for (u32 q = (u32)0; q < _m.funcs().count(); q = q + (u32)1)
                        if (((IRFunc*)_m.funcs().get(q)).name().equals(callee))
                            target = (IRFunc*)_m.funcs().get(q);
                    // A small float's conversion counts as the call alone (the
                    // reference explains).
                    if (target != (IRFunc*)0 && visited.get((Hashable*)callee) == (Object*)0
                        && !callee.hasPrefix(String.withCString("_xt_fpk_")))
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
            bool isFloat = t != (String*)0 && (IRType.is(t, tyF32) || IRType.is(t, tyF64));
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
        _parF4Pair = (i32)-1;
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
            {
            // No induction variable to place its writes by (under -g the
            // loop's counter lives in a slot): a block writing an f4 array runs
            // on one thread (pairs=2), since its chunks could not be cut
            // safely.
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)f.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* ip = (IRInsn*)bb.insns().get(i);
                    if ((ip.opc() == opStore || ip.opc() == opStoreVolatile) && ip.ops().count() > (u32)0)
                        {
                        IROperand* a0 = (IROperand*)ip.ops().get((u32)0);
                        if (a0.kind() == (u8)OPK_USE && f4IndexOf(a0.val()) != (IRValue*)0)
                            _parF4Pair = (i32)2;
                        }
                    }
                }
            return (String*)0;
            }
        // The induction variable is the phi the loop's GUARD compares, not
        // simply the first phi: a reduction's accumulator is a phi too, and a
        // block with reductions lists one of those first (the reference's IR
        // does). An ICmp that takes a phi is the guard (or a min/max test, but
        // the guard comes first in block order); its phi operand is the iv.
        iv = parInductionVariable(f, def, iv);
        IRValue* selfVal = (IRValue*)f.params().get((u32)0);
        String* tensorWhy = parTensorDependence(f, iv, ivars, def);
        if (tensorWhy != (String*)0)
            return tensorWhy;
        // An array reduction's array: each chunk updates its own copy, so its
        // accesses meet no other item's (parReadGridWords read the fields).
        Set* arrBufs = new Set();
        for (u32 k = (u32)1; _mArrRed != (Map*)0 && k <= ivars.count(); k = k + (u32)1)
            if (_mArrRed.get((Hashable*)String.withU32(k)) != (Object*)0)
                arrBufs.add((Hashable*)ivars.get(k - (u32)1));
        Map* writes = new Map();        // buffer -> Array of "affine k c" strings
        Map* wShown = new Map();        // buffer -> its first write's index, as shown
        Map* wSym = new Map();          // buffer -> Array of its writes' symbolic forms (ParIdx)
        Array* reads = new Array();     // [buffer, form, shown]
        // f4 arrays: their elements are tested, not their bytes; a write the
        // chunks cannot keep apart (two to a byte) is a dependence.
        String* f4Why = (String*)0;
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                u16 oc = ip.opc();
                bool isStore = oc == opStore || oc == opStoreVolatile;
                bool isLoad = oc == opLoad || oc == opLoadVolatile;
                if ((!isStore && !isLoad) || ip.ops().count() == (u32)0)
                    continue;
                IROperand* a0 = (IROperand*)ip.ops().get((u32)0);
                if (a0.kind() != (u8)OPK_USE)
                    continue;
                IRInsn* ea = (IRInsn*)def.get((Hashable*)String.withU32(a0.val().seq()));
                if (ea == (IRInsn*)0 || !ea.isOp(opElementAddr) || ea.ops().count() < 2)
                    continue;
                String* buf = parBufferOf((IROperand*)ea.ops().get((u32)0), selfVal, ivars, def);
                if (buf == (String*)0 || arrBufs.contains((Hashable*)buf))
                    continue;
                IRValue* f4i = f4IndexOf(ea.res());
                IROperand* idxOp = f4i != (IRValue*)0 ? IROperand.useVal(f4i) : (IROperand*)ea.ops().get((u32)1);
                ParIdx* px = parIndex(idxOp, iv, def, (u32)0);
                if (!px.affine)
                    px = parGridIndex(idxOp, iv, selfVal, ivars, def);
                bool af = px.affine; i64 k = px.k; i64 c = px.c;
                // An f4 write: two elements share each byte, so the chunks
                // must start on one parity of k * i + c (k odd); one every item
                // writes (k 0) or an index from data cannot be kept apart.
                if (f4i != (IRValue*)0 && isStore && f4Why == (String*)0)
                    {
                    if (!af || k == (i64)0)
                        {
                        f4Why = String.withCString("writes the f4 array '");
                        f4Why.append(self.parShown(buf));
                        f4Why.appendCString("' at an index that is not k * i + c, so two work items could write the two halves of one byte");
                        }
                    else if (k % (i64)2 != (i64)0)
                        {
                        i32 pr = (i32)(((c % (i64)2) + (i64)2) % (i64)2);
                        if (_parF4Pair >= (i32)0 && _parF4Pair != pr)
                            f4Why = String.withCString("writes f4 arrays at offsets of both parities (as a[i] and a[i + 1]), so no split of its items keeps each byte on one thread");
                        _parF4Pair = pr;
                        }
                    }
                ParIdx* sx = ParIdx.of(false, (i64)0, (i64)0);
                if (_parGuardList != (Array*)0)
                    sx = af ? ParIdx.of(true, k, c) : parSymIndex(idxOp, iv, selfVal, def, (u32)0);
                // …and in a grid, the point's flat index plus captured integers.
                if (_parGuardList != (Array*)0 && !sx.affine)
                    sx = parGridSym(idxOp, iv, selfVal, ivars, def);
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
        if (f4Why != (String*)0)
            return f4Why;
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

    // Whether the call `ci` may write through its argument `j`: a function
    // of the program that stores through that parameter, or through a
    // pointer made from it (an element, a member, a cast, a pointer loaded
    // from what it points to, or one kept in a local and read back), or
    // passes such a pointer to a call that may; a call to a function outside
    // the program or through a pointer; and an argument after the parameters
    // a function declares. `seen` holds the function:argument pairs already
    // asked. As the reference.
    final bool parCallMayWrite(IRInsn* ci, u32 j, Set* seen)
        {
        if ((!ci.isOp(opCall) && !ci.isOp(opCallBanked) && !ci.isOp(opCallCloaked)) || ci.ops().count() == 0
            || ((IROperand*)ci.ops().get(0)).kind() != OPK_SYM)
            return true;
        IRFunc* g = (IRFunc*)_parFns.get((Hashable*)((IROperand*)ci.ops().get(0)).name());
        if (g == (IRFunc*)0 || g.blocks().count() == 0 || j + 1 >= g.params().count())
            return true;
        String* key = String.withString(g.name());
        key.appendCString(":");
        key.append(String.withU32(j));
        if (seen.contains((Hashable*)key))
            return false;
        seen.add((Hashable*)key);
        // The pointers made from parameter j, and the locals that hold one.
        Set* from = new Set();
        from.add((Hashable*)String.withU32(((IRValue*)g.params().get(j)).seq()));
        Set* held = new Set();
        Map* def = new Map();
        Array* all = new Array();
        for (u32 b = 0; b < g.blocks().count(); b++)
            {
            IRBlock* bb = (IRBlock*)g.blocks().get(b);
            for (u32 i = 0; i < bb.phis().count(); i++)
                all.add(bb.phis().get(i));
            for (u32 i = 0; i < bb.insns().count(); i++)
                all.add(bb.insns().get(i));
            }
        for (u32 i = 0; i < all.count(); i++)
            {
            IRInsn* ip = (IRInsn*)all.get(i);
            if (ip.res() != (IRValue*)0)
                def.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
            }
        bool grew = true;
        while (grew)
            {
            grew = false;
            for (u32 i = 0; i < all.count(); i++)
                {
                IRInsn* ip = (IRInsn*)all.get(i);
                u32 n = ip.ops().count();
                if ((ip.isOp(opStore) || ip.isOp(opStoreVolatile)) && n >= 2 && Lower.parUseIn((IROperand*)ip.ops().get(1), from))
                    {
                    String* s = Lower.parSlotOf((IROperand*)ip.ops().get(0), def);
                    if (s != (String*)0 && !held.contains((Hashable*)s))
                        {
                        held.add((Hashable*)s);
                        grew = true;
                        }
                    continue;
                    }
                if (ip.res() == (IRValue*)0 || !IRType.isPtr(ip.res().ty()) || from.contains((Hashable*)String.withU32(ip.res().seq())))
                    continue;
                bool isLoad = ip.isOp(opLoad) || ip.isOp(opLoadVolatile);
                bool base = ip.isOp(opElementAddr) || ip.isOp(opFieldAddr) || isLoad;
                bool hit = false;
                if (isLoad && n > 0)
                    {
                    String* s = Lower.parSlotOf((IROperand*)ip.ops().get(0), def);
                    hit = s != (String*)0 && held.contains((Hashable*)s);
                    }
                u32 upto = base ? (n < 1 ? n : 1) : n;
                for (u32 k = 0; k < upto && !hit; k++)
                    hit = Lower.parUseIn((IROperand*)ip.ops().get(k), from);
                if (hit)
                    {
                    from.add((Hashable*)String.withU32(ip.res().seq()));
                    grew = true;
                    }
                }
            }
        for (u32 i = 0; i < all.count(); i++)
            {
            IRInsn* ip = (IRInsn*)all.get(i);
            u32 n = ip.ops().count();
            u16 oc = ip.opc();
            if (oc == opStore || oc == opStoreVolatile || oc == opAggStore || oc == opVStore || oc == opMemCopy || oc == opMemSet)
                {
                if (n > 0 && Lower.parUseIn((IROperand*)ip.ops().get(0), from))
                    return true;
                continue;
                }
            bool call = Lower.parCallsOut(oc);
            if (!call && oc != opAsm)
                continue;
            u32 k0 = call ? 1 : 0;
            u32 tail = call ? 1 : 0;
            for (u32 k = k0; k + tail < n; k++)
                {
                if (!Lower.parUseIn((IROperand*)ip.ops().get(k), from))
                    continue;
                if (!call || parCallMayWrite(ip, k - 1, seen))
                    return true;
                }
            }
        return false;
        }

    // A call, a call through a pointer, or a method's dispatch (the
    // reference's XTIROpcodeCallsOut).
    static bool parCallsOut(u16 oc)
        {
        return oc == opCall || oc == opCallIndirect || oc == opCallCloaked || oc == opCallBanked
            || oc == opCallBankedIndirect || oc == opVTblDispatch || oc == opProtoDispatch;
        }

    // A use of one of the values in `vals` (by sequence number).
    static bool parUseIn(IROperand* o, Set* vals)
        {
        return o.kind() == OPK_USE && o.val() != (IRValue*)0 && vals.contains((Hashable*)String.withU32(o.val().seq()));
        }

    // The local an address names: the value it is pinned to, whichever
    // AddrOf of it the access goes through; else the address itself.
    static String* parSlotOf(IROperand* a, Map* def)
        {
        if (a.kind() != OPK_USE || a.val() == (IRValue*)0)
            return (String*)0;
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(a.val().seq()));
        if (d != (IRInsn*)0 && d.isOp(opAddrOf) && d.ops().count() > 0)
            {
            IROperand* o0 = (IROperand*)d.ops().get(0);
            if (o0.kind() == OPK_USE && o0.val() != (IRValue*)0)
                return String.withU32(o0.val().seq());
            }
        return String.withU32(a.val().seq());
        }

    // A written block that passes a buffer (a captured array or pointer, or
    // a global array) to a call that may write through it (parCallMayWrite),
    // as the pointer itself, at one element for every work item, or at an
    // index computed from data: two items' calls may write the same element.
    // An element at the item's own index (`&c[i]`) is the item's. The first
    // such argument, as the warning words it, or 0. As the reference.
    final String* parCallScatter(IRFunc* f, Array* ivars)
        {
        Map* def = new Map();
        IRValue* iv = (IRValue*)0;
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = 0; i < bb.phis().count(); i++)
                {
                IRInsn* ph = (IRInsn*)bb.phis().get(i);
                if (ph.res() == (IRValue*)0)
                    continue;
                def.set((Hashable*)String.withU32(ph.res().seq()), (Object*)ph);
                if (iv == (IRValue*)0)
                    iv = ph.res();
                }
            for (u32 i = 0; i < bb.insns().count(); i++)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() != (IRValue*)0)
                    def.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
                }
            }
        if (iv == (IRValue*)0 || f.params().count() == 0)
            return (String*)0;
        iv = parInductionVariable(f, def, iv);
        IRValue* selfVal = (IRValue*)f.params().get(0);
        Set* seen = new Set();
        for (u32 b = 0; b < f.blocks().count(); b++)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = 0; i < bb.insns().count(); i++)
                {
                IRInsn* ci = (IRInsn*)bb.insns().get(i);
                if (!Lower.parCallsOut(ci.opc()))
                    continue;
                for (u32 k = 1; k + 1 < ci.ops().count(); k++)
                    {
                    // The buffer the argument points into, and the index of
                    // the element of it, when that is the last step to the
                    // argument.
                    IROperand* o = (IROperand*)ci.ops().get(k);
                    IROperand* idx = (IROperand*)0;
                    String* buf = (String*)0;
                    for (u32 step = 0; step < 32 && o.kind() == OPK_USE; step++)
                        {
                        buf = parBufferOf(o, selfVal, ivars, def);
                        if (buf != (String*)0)
                            break;
                        IRInsn* d = o.val() != (IRValue*)0 ? (IRInsn*)def.get((Hashable*)String.withU32(o.val().seq())) : (IRInsn*)0;
                        if (d == (IRInsn*)0 || d.ops().count() == 0)
                            break;
                        if (d.isOp(opElementAddr) && d.ops().count() >= 2)
                            idx = (IROperand*)d.ops().get(1);
                        else if (d.isOp(opFieldAddr) || d.isOp(opAdd) || d.isOp(opSub))
                            idx = (IROperand*)0;
                        else if (!d.isOp(opBitcast))
                            break;
                        if (d.res() == (IRValue*)0 || !IRType.isPtr(d.res().ty()))
                            break;
                        o = (IROperand*)d.ops().get(0);
                        }
                    // The compiler's own globals: a static initialiser's
                    // guard (`_xtc_sinit_run`) and a class's static data.
                    if (buf == (String*)0 || buf.hasPrefix(String.withCString("__sinit_")) || buf.hasPrefix(String.withCString("__sdata_"))
                        || buf.hasSuffix(String.withCString("$init")))
                        continue;
                    String* shown = String.withCString("'");
                    shown.append(self.parShown(buf));
                    if (idx != (IROperand*)0)
                        {
                        ParIdx* px = parIndex(idx, iv, def, 0);
                        if (!px.affine)
                            px = parGridIndex(idx, iv, selfVal, ivars, def);
                        ParIdx* sx = px.affine ? ParIdx.of(true, px.k, px.c) : parSymIndex(idx, iv, selfVal, def, 0);
                        if (!sx.affine)
                            sx = parGridSym(idx, iv, selfVal, ivars, def);
                        if (sx.affine && sx.k != 0)
                            continue;
                        if (px.affine)
                            {
                            shown.append(parShownIndex(true, px.k, px.c));
                            shown.appendCString("' to a call that may write through it, from every work item");
                            }
                        else
                            shown.appendCString("' at an index computed from data to a call that may write through it");
                        }
                    else
                        shown.appendCString("' to a call that may write through it, from every work item");
                    if (parCallMayWrite(ci, k - 1, seen))
                        return shown;
                    }
                }
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
            if (f.parKernel() != (u8)PARK_NONE)
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
            if (f.parKernel() != (u8)PARK_NONE)
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
                    if (!ip.isOp(opCall) || ip.ops().count() == 0) continue;
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
        bool kvBig = kmod != (IRModule*)0 && _kvTrips >= (u32)2 && _kPrinted != (String*)0
            && _kPrinted.byteLength() > ((u32)64 << (u32)20);
        if (kvBig)
            {
            // Skipping them looks the same from outside as a module with no
            // escape loop; XC_OPT_CAPS says so (#334), as the optimiser's
            // caps do. As the reference.
            u8* caps = _xt_getenv("XC_OPT_CAPS");
            if (caps != (u8*)0 && caps[0] != (u8)0)
                Stdio.error(String.withFormat("xcc: note: the GPU escape-trip kernel variants were skipped: the kernel module's text is %u MB, past 64 MB\n",
                                              _kPrinted.byteLength() >> (u32)20));
            }
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
            if (f.parKernel() != (u8)PARK_BLOCK)
                continue;
            // Its arrays of structs as arrays of words, in the copies the
            // kernels are printed from (parWordStructs).
            IRFunc* kf = (IRFunc*)kfns.get((Hashable*)f.name());
            IRModule* sm = _m;
            _mWordWhy = (String*)0;
            if (kf != (IRFunc*)0)
                {
                _m = kmod;
                _mWordWhy = parWordStructs(kf);
                }
            IRFunc* kvf = _kvFns.count() > (u32)0 ? (IRFunc*)_kvFns.get((Hashable*)f.name()) : (IRFunc*)0;
            if (kvf != (IRFunc*)0)
                {
                _m = _kvMod;
                parWordStructs(kvf);
                }
            _m = sm;
            parFillBlock(f, kf, kmod);
            _mWordWhy = (String*)0;
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
                // Layouts the rewrite adds belong to the copy it prints from.
                _m = copy;
                _mWordWhy = parWordStructs(f);
                _m = m;
                _mFieldWhere = b.where();
                parFillBlock(f, f, copy);
                _mFieldWhere = (String*)0;
                if (_mWordWhy != (String*)0 && _mMslWhy != (String*)0)
                    _mMslWhy = _mWordWhy;
                _mWordWhy = (String*)0;
                // XC_PAR_OUTLINE_TRACE: why a block has no GPU form (the
                // Metal form's reason, else the last form's).
                String* why = _mMslWhy != (String*)0 ? _mMslWhy : _mWhy;
                if (why != (String*)0 && Platform.env(String.withCString("XC_PAR_OUTLINE_TRACE")).byteLength() > (u32)0)
                    Stdio.error(String.withFormat("outline: %s: no GPU form: %s\n", b.cls().cString(), why.cString()));
                }
            }
        _m = saved;
        }

    // An array of structs in a kernel copy (a global's, or a captured
    // pointer's), as the array of words it is in memory, so the printers hold
    // it as any array of numbers. The word is the struct's one number type
    // when its fields are all that type, packed; else a 32-bit word (16- or
    // 8-bit when no field is wider). Element i starts at word i * (size /
    // word), and a field at byte offset o is read from word o / word: a field
    // of the word's width reinterpreted, a narrower one shifted out of its
    // word (and written back into it with the bytes around it kept), an
    // 8-byte one as two 32-bit words. The host's layout is kept as it is,
    // padding and nested structs included. An array whose element or field
    // addresses are used any other way (a whole element copied, a field's
    // address passed on) stays as it is, and the kernel declines it. Nothing
    // changes outside the copy.
    // -Wpar-fields (#146, stage 1): what one use of an address into an
    // array of structs does with the element: loads or stores the field at
    // that offset, or (the element's own address, or a field's address passed
    // on) uses the element whole.
    final void parNoteFieldUse(IRInsn* ip, u32 k, bool root, String* key, u32 off, String* t,
                               Map* rd, Map* wr, Map* whole)
        {
        bool load = ip.isOp(opLoad);
        bool store = ip.isOp(opStore) && ip.ops().count() >= (u32)2;
        if (root || k != (u32)0 || (!load && !store))
            {
            whole.set((Hashable*)key, (Object*)key);
            return;
            }
        Map* m = load ? rd : wr;
        Map* fm = (Map*)m.get((Hashable*)key);
        if (fm == (Map*)0)
            {
            fm = new Map();
            m.set((Hashable*)key, (Object*)fm);
            }
        Array* at = new Array();
        at.add((Object*)Number.with(off));
        at.add((Object*)t);
        fm.set((Hashable*)String.withU32(off), (Object*)at);
        }

    // The name of the field at byte offset off of layout l (a nested one as
    // `outer.inner`), from the struct's declaration when the layout is a
    // named struct's; else `+<offset>`.
    // The name of the struct whose layout is module layout n, or 0 (a C
    // program's structs, read from clang's IR, have none here).
    final String* parStructName(u32 n)
        {
        if (_layoutIds == (Map*)0)
            return (String*)0;
        Array* ks = _layoutIds.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            Number* ix = (Number*)_layoutIds.get((Hashable*)ks.get(i));
            if (ix != (Number*)0 && ix.asU32() == n && structDeclFor((String*)ks.get(i)) != (Node*)0)
                return (String*)ks.get(i);
            }
        return (String*)0;
        }

    final String* parFieldName(IRLayout* l, u32 n, u32 off, u32 depth)
        {
        String* sn = parStructName(n);
        Node* decl = sn != (String*)0 ? structDeclFor(sn) : (Node*)0;
        if (decl == (Node*)0 || decl.kidCount() != l.fieldCount() || depth > (u32)8)
            return String.withFormat("+%u", off);
        for (u32 i = (u32)0; i < l.fieldCount(); i = i + (u32)1)
            {
            u32 lo = l.offsetAt(i);
            u32 hi = i + (u32)1 < l.fieldCount() ? l.offsetAt(i + (u32)1) : l.size();
            if (off < lo || off >= hi)
                continue;
            String* nm = String.withString(decl.kid(i).name());
            String* ft = l.typeAt(i);
            IRLayout* inner = self.mslLayoutOf(ft);
            if (inner != (IRLayout*)0 && !inner.isArray())
                {
                u32 m = (u32)0;
                for (u32 q = (u32)4; q < ft.byteLength() && ft.byteAt(q) >= (u8)'0' && ft.byteAt(q) <= (u8)'9'; q = q + (u32)1)
                    m = m * (u32)10 + (u32)(ft.byteAt(q) - (u8)'0');
                nm.appendCString(".");
                nm.append(parFieldName(inner, m, off - lo, depth + (u32)1));
                }
            else if (inner != (IRLayout*)0 || off != lo)
                nm.append(String.withFormat("+%u", off - lo));
            return nm;
            }
        return String.withFormat("+%u", off);
        }

    // A field list, `x, y`, and the bytes those fields cover.
    final String* parFieldList(IRLayout* l, u32 n, Map* fm, u32* bytes)
        {
        String* out = new String();
        if (fm == (Map*)0)
            return out;
        // In offset order.
        Array* offs = new Array();
        Array* ks = fm.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            Array* e = (Array*)fm.get((Hashable*)ks.get(i));
            u32 v = ((Number*)e.get((u32)0)).asU32();
            u32 at = offs.count();
            for (u32 q = (u32)0; q < offs.count(); q = q + (u32)1)
                if (((Number*)((Array*)offs.get(q)).get((u32)0)).asU32() > v && at == offs.count())
                    at = q;
            offs.insert(at, (Object*)e);
            }
        for (u32 i = (u32)0; i < offs.count(); i = i + (u32)1)
            {
            Array* e = (Array*)offs.get(i);
            if (i > (u32)0)
                out.appendCString(", ");
            String* nm = parFieldName(l, n, ((Number*)e.get((u32)0)).asU32(), (u32)0);
            out.append(nm);
            // An unnamed one (a C struct's) says its type.
            if (nm.byteLength() > (u32)0 && nm.byteAt((u32)0) == (u8)'+')
                {
                out.appendCString(" ");
                out.append((String*)e.get((u32)1));
                }
            *bytes = *bytes + IRType.storageBytes((String*)e.get((u32)1), (u32)8);
            }
        return out;
        }

    // The report for one block, a line for each array of structs it uses:
    // the fields it reads and writes, the bytes of each element those cover,
    // and whether a copy holding only those fields (one array per field)
    // would move less than the copy of whole elements. The sliced form is
    // worth building when the fields used are at most half the element; an
    // element used whole has only the in-place form.
    final Array* parFieldReport(Array* keys, Map* sty, Map* rd, Map* wr, Map* whole)
        {
        Array* out = new Array();
        for (u32 q = (u32)0; q < keys.count(); q = q + (u32)1)
            {
            String* key = (String*)keys.get(q);
            String* st = (String*)sty.get((Hashable*)key);
            IRLayout* l = self.mslLayoutOf(st);
            if (l == (IRLayout*)0 || l.size() == (u32)0)
                continue;
            u32 n = (u32)0;
            for (u32 i = (u32)4; i < st.byteLength() && st.byteAt(i) >= (u8)'0' && st.byteAt(i) <= (u8)'9'; i = i + (u32)1)
                n = n * (u32)10 + (u32)(st.byteAt(i) - (u8)'0');
            String* sn = parStructName(n);
            String* arr = sn != (String*)0 ? String.withFormat("its array of %s (%u bytes an element)", sn.cString(), l.size())
                                           : String.withFormat("its array of %u-byte structs", l.size());
            String* line = new String();
            if (whole.get((Hashable*)key) != (Object*)0)
                {
                line.appendCString("uses whole elements of ");
                line.append(arr);
                line.appendCString(", so only the in-place copy applies");
                out.add((Object*)line);
                continue;
                }
            Map* r = (Map*)rd.get((Hashable*)key);
            Map* w = (Map*)wr.get((Hashable*)key);
            // The bytes used: each field once, read or written.
            Map* used = new Map();
            for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
                {
                Map* fm = pass == (u32)0 ? r : w;
                if (fm == (Map*)0)
                    continue;
                Array* ks = fm.allKeys();
                for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                    used.set((Hashable*)ks.get(i), fm.get((Hashable*)ks.get(i)));
                }
            u32 rb = (u32)0;
            u32 wb = (u32)0;
            u32 ub = (u32)0;
            String* rl = parFieldList(l, n, r, &rb);
            String* wl = parFieldList(l, n, w, &wb);
            parFieldList(l, n, used, &ub);
            if (rl.byteLength() > (u32)0)
                {
                line.appendCString("reads ");
                line.append(rl);
                }
            if (wl.byteLength() > (u32)0)
                {
                line.appendCString(rl.byteLength() > (u32)0 ? " and writes " : "writes ");
                line.append(wl);
                }
            line.appendCString(" of ");
            line.append(arr);
            line.append(String.withFormat(": %u of %u bytes an element; ", ub, l.size()));
            if (ub * (u32)2 <= l.size())
                line.append(String.withFormat("a copy of those fields alone would move %u bytes an element to the GPU and %u back, where whole elements move %u and %u",
                                              rb, wb, l.size(), wb > (u32)0 ? l.size() : (u32)0));
            else
                line.appendCString("it uses most of each element, so the in-place copy stays");
            out.add((Object*)line);
            }
        return out.count() > (u32)0 ? out : (Array*)0;
        }

    final String* parWordStructs(IRFunc* f)
        {
        if (f.params().count() == (u32)0)
            return (String*)0;
        IRValue* selfV = (IRValue*)f.params().get((u32)0);
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
        Map* phiDef = new Map();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.phis().get(i);
                if (ip.res() != (IRValue*)0)
                    phiDef.set((Hashable*)String.withU32(ip.res().seq()), (Object*)ip);
                }
            }
        String* why = (String*)0;
        // The arrays: a global's address, or a captured pointer loaded from
        // the block's object, whose element is a struct with a word.
        Map* baseOf = new Map();    // base value seq -> its array's key
        Map* sty = new Map();       // key -> the struct type
        Map* bad = new Map();       // key -> declined
        Array* keys = new Array();
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                if (ip.res() == (IRValue*)0 || ip.ops().count() == (u32)0 || !self.mslIsPtr(ip.res().ty()))
                    continue;
                String* st = self.mslPointee(ip.res().ty());
                IRLayout* sl = self.mslLayoutOf(st);
                if (sl == (IRLayout*)0 || sl.isArray() || self.parWordOf(st) == (String*)0)
                    continue;
                IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
                String* key = (String*)0;
                if (ip.isOp(opAddrOf) && ip.ops().count() == 1 && o0.kind() == OPK_SYM)
                    key = String.withFormat("g%s", o0.name().cString());
                else if (ip.isOp(opLoad) && o0.kind() == OPK_USE && o0.val() != (IRValue*)0)
                    {
                    IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o0.val().seq()));
                    if (fa != (IRInsn*)0 && fa.isOp(opFieldAddr) && fa.ops().count() == 2
                        && ((IROperand*)fa.ops().get((u32)0)).kind() == (u8)OPK_USE
                        && ((IROperand*)fa.ops().get((u32)0)).val() == selfV
                        && ((IROperand*)fa.ops().get((u32)1)).kind() == (u8)OPK_IMMI)
                        key = String.withFormat("b%ld", ((IROperand*)fa.ops().get((u32)1)).imm());
                    }
                if (key == (String*)0)
                    continue;
                if (sty.get((Hashable*)key) == (Object*)0)
                    {
                    sty.set((Hashable*)key, (Object*)st);
                    keys.add((Object*)key);
                    }
                else if (!((String*)sty.get((Hashable*)key)).equals(st))
                    bad.set((Hashable*)key, (Object*)key);
                baseOf.set((Hashable*)String.withU32(ip.res().seq()), (Object*)key);
                }
            }
        if (keys.count() == (u32)0)
            return (String*)0;
        // The addresses into them: an element's (the root), and a field's or
        // a nested field's, each at a byte offset from its element.
        Map* cKey = new Map();      // value seq -> key
        Map* cOff = new Map();      // value seq -> byte offset in the element
        Map* cTy = new Map();       // value seq -> the type there
        Map* cRoot = new Map();     // value seq -> the element's address
        // -Wpar-fields (#146): the fields each array's element is read and
        // written at (key -> byte offset -> type), and the arrays an element
        // is used whole in. Only seen here; nothing below reads them.
        Map* fuRead = new Map();
        Map* fuWrite = new Map();
        Map* fuWhole = new Map();
        for (u32 pass = (u32)0; pass < (u32)4; pass = pass + (u32)1)
            for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)f.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* ip = (IRInsn*)bb.insns().get(i);
                    if (ip.res() == (IRValue*)0 || ip.ops().count() != (u32)2)
                        continue;
                    String* rk = String.withU32(ip.res().seq());
                    if (cKey.get((Hashable*)rk) != (Object*)0)
                        continue;
                    IROperand* o0 = (IROperand*)ip.ops().get((u32)0);
                    IROperand* o1 = (IROperand*)ip.ops().get((u32)1);
                    if (o0.kind() != (u8)OPK_USE || o0.val() == (IRValue*)0)
                        continue;
                    String* vk = String.withU32(o0.val().seq());
                    String* bk = (String*)baseOf.get((Hashable*)vk);
                    if (bk != (String*)0)
                        {
                        if (ip.isOp(opElementAddr))
                            {
                            cKey.set((Hashable*)rk, (Object*)bk);
                            cOff.set((Hashable*)rk, (Object*)Number.with((u32)0));
                            cTy.set((Hashable*)rk, sty.get((Hashable*)bk));
                            cRoot.set((Hashable*)rk, (Object*)ip.res());
                            }
                        continue;
                        }
                    String* ck = (String*)cKey.get((Hashable*)vk);
                    if (ck == (String*)0 || o1.kind() != (u8)OPK_IMMI || o1.imm() < (i64)0)
                        continue;
                    IRLayout* l = self.mslLayoutOf((String*)cTy.get((Hashable*)vk));
                    u32 off = ((Number*)cOff.get((Hashable*)vk)).asU32();
                    bool isRoot = (IRValue*)cRoot.get((Hashable*)vk) == o0.val();
                    // A struct's field, or an element of an array inside one
                    // (an element's own address offset is not that).
                    bool field = ip.isOp(opFieldAddr) && l != (IRLayout*)0 && !l.isArray();
                    bool inner = ip.isOp(opElementAddr) && l != (IRLayout*)0 && l.isArray() && !isRoot;
                    if ((!field && !inner) || o1.imm() >= (i64)l.fieldCount())
                        continue;
                    cKey.set((Hashable*)rk, (Object*)ck);
                    cOff.set((Hashable*)rk, (Object*)Number.with(off + l.offsetAt((u32)o1.imm())));
                    cTy.set((Hashable*)rk, (Object*)l.typeAt((u32)o1.imm()));
                    cRoot.set((Hashable*)rk, cRoot.get((Hashable*)vk));
                    }
                }
        // Every use of them must be one of those, or a load or store of a
        // field the word holds; a field of the word's own type is a pointer
        // to a word and may be used as any.
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
                bool resIn = ip.res() != (IRValue*)0 && cKey.get((Hashable*)String.withU32(ip.res().seq())) != (Object*)0;
                for (u32 k = (u32)0; k < ip.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)ip.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    String* vk = String.withU32(o.val().seq());
                    String* bk = (String*)baseOf.get((Hashable*)vk);
                    String* ck = (String*)cKey.get((Hashable*)vk);
                    if (bk != (String*)0)
                        {
                        if (!(k == 0 && resIn && ip.isOp(opElementAddr)))
                            {
                            bad.set((Hashable*)bk, (Object*)bk);
                            fuWhole.set((Hashable*)bk, (Object*)bk);
                            }
                        continue;
                        }
                    if (ck == (String*)0)
                        continue;
                    if (k == (u32)0 && resIn)
                        continue;
                    String* t = (String*)cTy.get((Hashable*)vk);
                    String* wt = self.parWordOf((String*)sty.get((Hashable*)ck));
                    bool root = (IRValue*)cRoot.get((Hashable*)vk) == o.val();
                    parNoteFieldUse(ip, k, root, ck, ((Number*)cOff.get((Hashable*)vk)).asU32(), t, fuRead, fuWrite, fuWhole);
                    if (!root && t.equals(wt) && ((Number*)cOff.get((Hashable*)vk)).asU32() % self.gpuBytes(wt) == (u32)0)
                        continue;
                    bool access = k == 0 && !root && (ip.isOp(opLoad)
                                  || (ip.isOp(opStore) && ip.ops().count() >= 2));
                    if (!access || !self.parWordHolds(wt, t, ((Number*)cOff.get((Hashable*)vk)).asU32()))
                        bad.set((Hashable*)ck, (Object*)ck);
                    // A field narrower than its word is written with the
                    // bytes around it, which another work item writing
                    // another field of the element would lose: only at the
                    // item's own index, which no other item writes.
                    else if (ip.isOp(opStore)
                             && (self.gpuBytes(t) < self.gpuBytes(wt) || IRType.is(t, tyBool)))
                        {
                        IRValue* rv = (IRValue*)cRoot.get((Hashable*)vk);
                        IRInsn* re = (IRInsn*)def.get((Hashable*)String.withU32(rv.seq()));
                        if (re == (IRInsn*)0 || re.ops().count() != (u32)2
                            || !parOwnIndex((IROperand*)re.ops().get((u32)1), selfV, def, phiDef))
                            {
                            bad.set((Hashable*)ck, (Object*)ck);
                            why = String.withCString("it writes a field of an array of structs narrower than the word its GPU version writes, at an element another work item may write");
                            }
                        }
                    }
                }
            }
        // The captured pointers: their field in the object must be loaded
        // only, so the object's layout can say it points to words.
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
                    IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(o.val().seq()));
                    if (fa == (IRInsn*)0 || !fa.isOp(opFieldAddr) || fa.ops().count() != 2
                        || ((IROperand*)fa.ops().get((u32)0)).kind() != (u8)OPK_USE
                        || ((IROperand*)fa.ops().get((u32)0)).val() != selfV
                        || ((IROperand*)fa.ops().get((u32)1)).kind() != (u8)OPK_IMMI)
                        continue;
                    String* key = String.withFormat("b%ld", ((IROperand*)fa.ops().get((u32)1)).imm());
                    if (sty.get((Hashable*)key) == (Object*)0)
                        continue;
                    bool isBase = ip.res() != (IRValue*)0 && baseOf.get((Hashable*)String.withU32(ip.res().seq())) != (Object*)0;
                    if (!(k == 0 && ip.isOp(opLoad) && isBase))
                        bad.set((Hashable*)key, (Object*)key);
                    }
                }
            }
        if (_parFieldsOn && _mFieldReport == (Array*)0)
            _mFieldReport = parFieldReport(keys, sty, fuRead, fuWrite, fuWhole);
        bool any = false;
        for (u32 q = (u32)0; q < keys.count(); q = q + (u32)1)
            if (bad.get((Hashable*)keys.get(q)) == (Object*)0)
                any = true;
        if (!any)
            return why;
        // The rewrite.
        Map* fieldRetyped = new Map();  // captured field k -> its new pointer type
        for (u32 b = (u32)0; b < f.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)f.blocks().get(b);
            u32 i = (u32)0;
            while (i < bb.insns().count())
                {
                IRInsn* ip = (IRInsn*)bb.insns().get(i);
                IRValue* r = ip.res();
                u16 oc = ip.opc();
                IROperand* o0 = ip.ops().count() > (u32)0 ? (IROperand*)ip.ops().get((u32)0) : (IROperand*)0;
                String* rk = r != (IRValue*)0 ? String.withU32(r.seq()) : (String*)0;
                String* bk = rk != (String*)0 ? (String*)baseOf.get((Hashable*)rk) : (String*)0;
                String* ck = rk != (String*)0 ? (String*)cKey.get((Hashable*)rk) : (String*)0;
                // A load or store through a field's address.
                String* ak = o0 != (IROperand*)0 && o0.kind() == (u8)OPK_USE && o0.val() != (IRValue*)0
                             ? String.withU32(o0.val().seq()) : (String*)0;
                String* lk = ak != (String*)0 ? (String*)cKey.get((Hashable*)ak) : (String*)0;
                if (lk != (String*)0 && bad.get((Hashable*)lk) == (Object*)0
                    && (oc == opLoad || oc == opStore))
                    {
                    i = parWordAccess(bb, i, ip, (String*)cTy.get((Hashable*)ak), ((Number*)cOff.get((Hashable*)ak)).asU32(),
                                      self.parWordOf((String*)sty.get((Hashable*)lk)), (IRValue*)cRoot.get((Hashable*)ak));
                    continue;
                    }
                if (bk != (String*)0 && bad.get((Hashable*)bk) == (Object*)0)
                    {
                    String* wt = self.parWordOf((String*)sty.get((Hashable*)bk));
                    String* pt = parPtrRetyped(r.ty(), wt);
                    r.setTy(pt);
                    if (oc == opLoad)
                        {
                        // Its field in the object points to words now.
                        IRInsn* fa = (IRInsn*)def.get((Hashable*)ak);
                        fa.res().setTy(parPtrRetyped(fa.res().ty(), pt));
                        fieldRetyped.set((Hashable*)String.withI64(((IROperand*)fa.ops().get((u32)1)).imm()), (Object*)pt);
                        }
                    i = i + (u32)1;
                    continue;
                    }
                if (ck == (String*)0 || bad.get((Hashable*)ck) != (Object*)0)
                    {
                    i = i + (u32)1;
                    continue;
                    }
                String* wt = self.parWordOf((String*)sty.get((Hashable*)ck));
                String* pt = parPtrRetyped(r.ty(), wt);
                IRValue* root = (IRValue*)cRoot.get((Hashable*)rk);
                if (root == r)
                    {
                    // [i] of the struct: [i * (size / word)] of the word.
                    IRLayout* sl = self.mslLayoutOf((String*)sty.get((Hashable*)ck));
                    u32 n = sl.size() / self.gpuBytes(wt);
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
                        ip.ops().set((u32)1, (Object*)scaled);
                    r.setTy(pt);
                    }
                else
                    {
                    // A field: the word it starts in.
                    u32 off = ((Number*)cOff.get((Hashable*)rk)).asU32();
                    IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
                    ea.add(IROperand.useVal(root));
                    ea.add(IROperand.immI((i64)(off / self.gpuBytes(wt)), String.withCString("U32")));
                    ea.setRes(r);
                    r.setTy(pt);
                    bb.insns().set(i, (Object*)ea);
                    }
                i = i + (u32)1;
                }
            }
        // The object's layout, in this copy: each captured pointer's field
        // points to words.
        if (fieldRetyped.count() == (u32)0)
            return why;
        String* objT = self.mslPointee(selfV.ty());
        IRLayout* ol = self.mslLayoutOf(objT);
        if (ol == (IRLayout*)0)
            return why;
        IRLayout* nl = IRLayout.with(ol.size(), (u32)1);
        for (u32 k = (u32)0; k < ol.fieldCount(); k = k + (u32)1)
            {
            String* nt = (String*)fieldRetyped.get((Hashable*)String.withI64((i64)k));
            nl.addField(ol.offsetAt(k), nt != (String*)0 ? nt : ol.typeAt(k));
            }
        _m.layouts().add((Object*)nl);
        selfV.setTy(parPtrRetyped(selfV.ty(), String.withFormat("Agg(%u)", _m.layouts().count() - (u32)1)));
        return why;
        }

    // Whether an element index is the work item's own: the block's loop
    // counter, from lo (field 1 of the block's object) and stepping up by a
    // constant, so no two items reach the same element.
    final bool parOwnIndex(IROperand* o, IRValue* selfV, Map* def, Map* phiDef)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRValue* v = parStripExt(o.val(), def);
        IRInsn* phi = (IRInsn*)phiDef.get((Hashable*)String.withU32(v.seq()));
        if (phi == (IRInsn*)0)
            return false;
        u32 uses = (u32)0;
        for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
            {
            IROperand* po = (IROperand*)phi.ops().get(k);
            if (po.kind() != (u8)OPK_USE || po.val() == (IRValue*)0)
                continue;
            uses = uses + (u32)1;
            IRValue* x = parStripExt(po.val(), def);
            IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(x.seq()));
            if (d == (IRInsn*)0)
                return false;
            if (d.isOp(opLoad) && ((IROperand*)d.ops().get(0)).kind() == OPK_USE)
                {
                IRInsn* fa = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)d.ops().get((u32)0)).val().seq()));
                if (fa != (IRInsn*)0 && fa.isOp(opFieldAddr) && fa.ops().count() == 2
                    && ((IROperand*)fa.ops().get((u32)0)).kind() == (u8)OPK_USE && ((IROperand*)fa.ops().get((u32)0)).val() == selfV
                    && ((IROperand*)fa.ops().get((u32)1)).kind() == (u8)OPK_IMMI && ((IROperand*)fa.ops().get((u32)1)).imm() == (i64)1)
                    continue;
                return false;
                }
            if (!d.isOp(opAdd) || d.ops().count() != 2)
                return false;
            IROperand* a0 = (IROperand*)d.ops().get((u32)0);
            IROperand* a1 = (IROperand*)d.ops().get((u32)1);
            bool step = (a0.kind() == (u8)OPK_USE && a0.val() == v && parPositive(a1, def))
                        || (a1.kind() == (u8)OPK_USE && a1.val() == v && parPositive(a0, def));
            if (!step)
                return false;
            }
        return uses > (u32)0;
        }

    // v without the extensions and truncations around it.
    final IRValue* parStripExt(IRValue* v, Map* def)
        {
        for (u32 n = (u32)0; n < (u32)4; n = n + (u32)1)
            {
            IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(v.seq()));
            if (d == (IRInsn*)0 || d.ops().count() != (u32)1 || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_USE
                || !(d.isOp(opZExt) || d.isOp(opSExt) || d.isOp(opTrunc)))
                return v;
            v = ((IROperand*)d.ops().get((u32)0)).val();
            }
        return v;
        }

    // A constant above zero (an immediate, or a Const, extended maybe).
    final bool parPositive(IROperand* o, Map* def)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return o.imm() > (i64)0;
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRInsn* d = (IRInsn*)def.get((Hashable*)String.withU32(parStripExt(o.val(), def).seq()));
        return d != (IRInsn*)0 && d.isOp(opConst) && d.ops().count() == 1
               && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_IMMI && ((IROperand*)d.ops().get((u32)0)).imm() > (i64)0;
        }

    // Whether a word of type wt holds a field of type t at byte offset off:
    // a number on its own alignment, within one word, or an 8-byte one in
    // two 32-bit words.
    final bool parWordHolds(String* wt, String* t, u32 off)
        {
        if (!self.parLeaf(t))
            return false;
        u32 w = self.gpuBytes(t);
        u32 ww = self.gpuBytes(wt);
        if (off % w != (u32)0)
            return false;
        if (w <= ww)
            return off % ww + w <= ww;
        return w == (u32)8 && ww == (u32)4;
        }

    // A load or store at insns[i] of a field of type t, `off` bytes into the
    // element at `root`, through words of type wt: the instructions that do
    // it in words. The index after them.
    final u32 parWordAccess(IRBlock* bb, u32 i, IRInsn* ip, String* t, u32 off, String* wt, IRValue* root)
        {
        u32 w = self.gpuBytes(t);
        u32 ww = self.gpuBytes(wt);
        bool load = ip.isOp(opLoad);
        if (w == ww && !IRType.is(t, tyBool))
            {
            if (t.equals(wt))
                return i + (u32)1;
            // Reinterpreted: read the word and cast it, cast before writing.
            if (load)
                {
                IRValue* orig = ip.res();
                IRValue* word = new IRValue(wt);
                ip.setRes(word);
                bb.insns().insert(i + (u32)1, (Object*)parWordOp("Bitcast", orig, IROperand.useVal(word), (IROperand*)0));
                return i + (u32)2;
                }
            IROperand* v = parWordValue(bb, &i, (IROperand*)ip.ops().get((u32)1), t);
            IRValue* word = new IRValue(wt);
            bb.insns().insert(i, (Object*)parWordOp("Bitcast", word, v, (IROperand*)0));
            ip.ops().set((u32)1, (Object*)IROperand.useVal(word));
            return i + (u32)2;
            }
        IROperand* addr = (IROperand*)ip.ops().get((u32)0);
        IROperand* memIn = (IROperand*)ip.ops().get(load ? (u32)1 : (u32)2);
        if (w == (u32)8)
            {
            // Two 32-bit words, the low one first.
            IRValue* a2 = new IRValue(parPtrRetyped(addr.val().ty(), String.withCString("U32")));
            IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
            ea.add(IROperand.useVal(root));
            ea.add(IROperand.immI((i64)(off / (u32)4 + (u32)1), String.withCString("U32")));
            ea.setRes(a2);
            bb.insns().insert(i, (Object*)ea);
            i = i + (u32)1;
            IRValue* m1 = new IRValue(String.withCString("Mem"));
            if (load)
                {
                IRValue* orig = ip.res();
                IRValue* lo = new IRValue(String.withCString("U32"));
                IRInsn* l1 = IRInsn.with(String.withCString("Load"));
                l1.add(addr);
                l1.add(memIn);
                l1.setRes(lo);
                l1.setMemRes(m1);
                bb.insns().insert(i, (Object*)l1);
                i = i + (u32)1;
                IRValue* hi = new IRValue(String.withCString("U32"));
                ip.ops().set((u32)0, (Object*)IROperand.useVal(a2));
                ip.ops().set((u32)1, (Object*)IROperand.useVal(m1));
                ip.setRes(hi);
                i = i + (u32)1;
                IRValue* zl = new IRValue(String.withCString("U64"));
                IRValue* zh = new IRValue(String.withCString("U64"));
                IRValue* sh = new IRValue(String.withCString("U64"));
                IRValue* both = IRType.is(t, tyU64) ? orig : new IRValue(String.withCString("U64"));
                bb.insns().insert(i, (Object*)parWordOp("ZExt", zl, IROperand.useVal(lo), (IROperand*)0));
                bb.insns().insert(i + (u32)1, (Object*)parWordOp("ZExt", zh, IROperand.useVal(hi), (IROperand*)0));
                bb.insns().insert(i + (u32)2, (Object*)parWordOp("Shl", sh, IROperand.useVal(zh), IROperand.immI((i64)32, String.withCString("U64"))));
                bb.insns().insert(i + (u32)3, (Object*)parWordOp("Or", both, IROperand.useVal(zl), IROperand.useVal(sh)));
                i = i + (u32)4;
                if (both != orig)
                    {
                    bb.insns().insert(i, (Object*)parWordOp("Bitcast", orig, IROperand.useVal(both), (IROperand*)0));
                    i = i + (u32)1;
                    }
                return i;
                }
            IROperand* v = parWordValue(bb, &i, (IROperand*)ip.ops().get((u32)1), t);
            if (!IRType.is(t, tyU64))
                {
                IRValue* u = new IRValue(String.withCString("U64"));
                bb.insns().insert(i, (Object*)parWordOp("Bitcast", u, v, (IROperand*)0));
                i = i + (u32)1;
                v = IROperand.useVal(u);
                }
            IRValue* lo = new IRValue(String.withCString("U32"));
            IRValue* s = new IRValue(String.withCString("U64"));
            IRValue* hi = new IRValue(String.withCString("U32"));
            bb.insns().insert(i, (Object*)parWordOp("Trunc", lo, v, (IROperand*)0));
            bb.insns().insert(i + (u32)1, (Object*)parWordOp("LShr", s, v, IROperand.immI((i64)32, String.withCString("U64"))));
            bb.insns().insert(i + (u32)2, (Object*)parWordOp("Trunc", hi, IROperand.useVal(s), (IROperand*)0));
            i = i + (u32)3;
            IRInsn* s1 = IRInsn.with(String.withCString("Store"));
            s1.add(addr);
            s1.add(IROperand.useVal(lo));
            s1.add(memIn);
            s1.setMemRes(m1);
            bb.insns().insert(i, (Object*)s1);
            i = i + (u32)1;
            ip.ops().set((u32)0, (Object*)IROperand.useVal(a2));
            ip.ops().set((u32)1, (Object*)IROperand.useVal(hi));
            ip.ops().set((u32)2, (Object*)IROperand.useVal(m1));
            return i + (u32)1;
            }
        // A narrower field: its bits in the word.
        u32 shift = (off % ww) * (u32)8;
        i64 mask = ((i64)1 << (i64)(w * (u32)8)) - (i64)1;
        if (load)
            {
            IRValue* orig = ip.res();
            IRValue* word = new IRValue(wt);
            ip.setRes(word);
            i = i + (u32)1;
            IROperand* x = IROperand.useVal(word);
            if (shift != (u32)0)
                {
                IRValue* sv = new IRValue(wt);
                bb.insns().insert(i, (Object*)parWordOp("LShr", sv, x, IROperand.immI((i64)shift, wt)));
                i = i + (u32)1;
                x = IROperand.useVal(sv);
                }
            if (IRType.is(t, tyBool))
                {
                IRValue* bv = new IRValue(wt);
                bb.insns().insert(i, (Object*)parWordOp("And", bv, x, IROperand.immI(mask, wt)));
                IRInsn* ne = parWordOp("ICmp", orig, IROperand.useVal(bv), IROperand.immI((i64)0, wt));
                ne.setPred(String.withCString("NE"));
                bb.insns().insert(i + (u32)1, (Object*)ne);
                return i + (u32)2;
                }
            bb.insns().insert(i, (Object*)parWordOp("Trunc", orig, x, (IROperand*)0));
            return i + (u32)1;
            }
        // Written back into its word with the other bytes kept.
        IROperand* v = parWordValue(bb, &i, (IROperand*)ip.ops().get((u32)1), t);
        IRValue* m1 = new IRValue(String.withCString("Mem"));
        IRValue* old = new IRValue(wt);
        IRInsn* l1 = IRInsn.with(String.withCString("Load"));
        l1.add(addr);
        l1.add(memIn);
        l1.setRes(old);
        l1.setMemRes(m1);
        IRValue* z = new IRValue(wt);
        IRValue* zm = new IRValue(wt);
        IRValue* kept = new IRValue(wt);
        IRValue* nw = new IRValue(wt);
        bb.insns().insert(i, (Object*)l1);
        bb.insns().insert(i + (u32)1, (Object*)parWordOp("ZExt", z, v, (IROperand*)0));
        bb.insns().insert(i + (u32)2, (Object*)parWordOp("And", zm, IROperand.useVal(z), IROperand.immI(mask, wt)));
        i = i + (u32)3;
        IROperand* bits = IROperand.useVal(zm);
        if (shift != (u32)0)
            {
            IRValue* sv = new IRValue(wt);
            bb.insns().insert(i, (Object*)parWordOp("Shl", sv, bits, IROperand.immI((i64)shift, wt)));
            i = i + (u32)1;
            bits = IROperand.useVal(sv);
            }
        i64 wmask = ww == (u32)4 ? (i64)0xFFFFFFFF : ((i64)1 << (i64)(ww * (u32)8)) - (i64)1;
        bb.insns().insert(i, (Object*)parWordOp("And", kept, IROperand.useVal(old), IROperand.immI(wmask ^ (mask << (i64)shift), wt)));
        bb.insns().insert(i + (u32)1, (Object*)parWordOp("Or", nw, IROperand.useVal(kept), bits));
        i = i + (u32)2;
        ip.ops().set((u32)1, (Object*)IROperand.useVal(nw));
        ip.ops().set((u32)2, (Object*)IROperand.useVal(m1));
        return i + (u32)1;
        }

    // An instruction `res = op a[, b]`.
    final IRInsn* parWordOp(string op, IRValue* res, IROperand* a, IROperand* b)
        {
        IRInsn* n = IRInsn.with(String.withCString(op));
        n.add(a);
        if (b != (IROperand*)0)
            n.add(b);
        n.setRes(res);
        return n;
        }

    // A stored value as a value of type t: a constant gets its own Const
    // before insns[*at].
    final IROperand* parWordValue(IRBlock* bb, u32* at, IROperand* v, String* t)
        {
        if (v.kind() == (u8)OPK_USE)
            return v;
        IRValue* c = new IRValue(t);
        bb.insns().insert(*at, (Object*)parWordOp("Const", c, v, (IROperand*)0));
        *at = *at + (u32)1;
        return IROperand.useVal(c);
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
        // A block that computes in a pack rounds each operation to it, its
        // goal speed or not (as on the CPU): its kernels take the precise
        // forms of the float operations (correctly rounded division, no
        // flushing), which that one rounding relies on. As the reference.
        if (_mFast && parUsesFloatPack(f, new Map()))
            _mFast = false;
        _mSubn = parPackKeepsSubnormals(f, new Map());
        // The block's reductions, after the tag: `<field>=<op>;` each (bug 645).
        _mRedOps = (Map*)0;
        _mConst = new Map();
        _mArrRed = new Map();
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
                    // `a<field>=<op>`: an array reduction, not a scalar one.
                    else if (key.byteLength() > (u32)1 && inVal && key.byteAt((u32)0) == (u8)'a')
                        _mArrRed.set((Hashable*)key.substringFromByte((u32)1), (Object*)val);
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
        _parExtraMeta.append(parPackWords(f));
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
        // An array reduction has a Metal form only (its atomics, in
        // mslArrStore): the other printers keep the block on the CPU's
        // threads. As the reference.
        bool arrRed = !serialBlock && lost == (String*)0 && _mArrRed.count() > (u32)0;
        String* arrWhy = arrRed ? String.withCString("it has an array reduction (:reduce(op a[])), which has no GPU version yet") : (String*)0;
        bool scanPass = !serialBlock && lost == (String*)0 && !arrRed && parIsScanBlock(fcls.substringBytes((u32)8, fcls.byteLength() - (u32)8));
        if (scanPass)
            lostWhy = String.withCString("it is a pass of a :scan block, which has no GPU version yet");
        // A block that reads or writes f4 array elements has no form: a
        // kernel would rewrite a byte two work items share.
        if (!serialBlock && lost == (String*)0 && !arrRed && !scanPass && parTouchesF4(f, new Map()))
            lostWhy = String.withCString("it reads or writes f4 array elements, two to a byte, which GPU kernels do not take yet");
        // A block that uses a tensor has no form: GPU kernels take none yet.
        // As the reference.
        else if (!serialBlock && lost == (String*)0 && !arrRed && !scanPass && parTouchesTensor(f, new Map()))
            lostWhy = String.withCString("it reads or writes tensor elements, which GPU kernels do not take yet");
        bool noForms = serialBlock || lostWhy != (String*)0;
        _mWhy = lostWhy;
        String* mslText = _parMetal && !noForms ? parMslK(f, kfUse, kmod) : (String*)0;
        mslWhy = _mWhy;
        _mMslWhy = mslWhy;
        _mWhy = arrRed ? arrWhy : lostWhy;
        String* ptx = _parPTX && !noForms && !arrRed ? parPtxK(f, kfUse, kmod) : (String*)0;
        ptxWhy = _mWhy;
        _mWhy = arrRed ? arrWhy : lostWhy;
        String* wgsl = _parWGSL && !noForms && !arrRed ? parWgslK(f, kfUse, kmod) : (String*)0;
        wgslWhy = _mWhy;
        _mWhy = arrRed ? arrWhy : lostWhy;
        Array* spv = _parSPIRV && !noForms && !arrRed ? parSpirvK(f, kfUse, kmod) : (Array*)0;
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
        _mSubn = false;
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
            // An array of structs left as it was says why itself.
            if (_mWordWhy != (String*)0)
                _mWhy = _mWordWhy;
            }
        if (msl == (String*)0 && (_parMetal || _parPTX || _parSPIRV || _parWGSL))
            {
            // On a target with a GPU, say why this block stays on the CPU.
            String* cls = f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4);
            // A loop the compiler lifted by itself says so only under
            // -Wpar-auto: a plain program is not told about a block it never
            // wrote. As the reference.
            bool lifted = parIsAutoBlock(cls.substringBytes((u32)8, cls.byteLength() - (u32)8));
            String* w = String.withCString(lifted ? "this loop runs on the CPU only (--par-style), because "
                                                  : "this 'par' block runs on the CPU only, because ");
            String* why = _mWhy;
            w.append(why != (String*)0 ? why : String.withCString("its GPU version cannot express something it uses yet"));
            // A :scan's passes are the compiler's, not written blocks: they
            // say nothing (#144).
            if (!parIsScanBlock(cls.substringBytes((u32)8, cls.byteLength() - (u32)8)))
                self.warnAtNode(String.withCString(lifted ? "par-auto" : "par-gpu"), w, (Node*)_classDecls.get((Hashable*)cls));
            }
        // -Wpar-fields (#146): on a target with a GPU, the fields of each
        // array of structs the block uses (parFieldReport).
        if (_mFieldReport != (Array*)0 && (_parMetal || _parPTX || _parSPIRV || _parWGSL))
            {
            String* cls = f.name().substringBytes((u32)0, f.name().byteLength() - (u32)4);
            String* bn = cls.substringBytes((u32)8, cls.byteLength() - (u32)8);
            if (!parIsScanBlock(bn))
                {
                for (u32 q = (u32)0; q < _mFieldReport.count(); q = q + (u32)1)
                    {
                    String* w = String.withCString(parIsAutoBlock(bn) || _mFieldWhere != (String*)0
                                                   ? "this loop (--par-style) " : "this 'par' block ");
                    w.append((String*)_mFieldReport.get(q));
                    // An outlined block (the optimiser's, after the front end
                    // has printed its warnings) says it at its loop, now.
                    if (_mFieldWhere != (String*)0)
                        Stdio.error(String.withFormat("%s: warning: %s\n", _mFieldWhere.cString(), w.cString()));
                    else
                        self.warnAtNode(String.withCString("par-fields"), w, (Node*)_classDecls.get((Hashable*)cls));
                    }
                }
            }
        _mFieldReport = (Array*)0;
        // No form to run, but the run still checks the block's arrays against
        // each other (ParDevice.bufferOverlap) from the header line: a block
        // with no form gets that line alone, `// xcpar cpu`, with every
        // captured pointer to numbers. As the reference.
        if (msl == (String*)0 && kernelBytes == (Array*)0)
            {
            msl = String.withCString("// xcpar cpu");
            IRValue* selfV = f.params().count() > (u32)0 ? (IRValue*)f.params().get((u32)0) : (IRValue*)0;
            String* selfPointee = selfV != (IRValue*)0 ? self.mslPointee(selfV.ty()) : (String*)0;
            IRLayout* bl = selfPointee != (String*)0 && IRType.isAgg(selfPointee) ? self.layoutOfAgg(selfPointee) : (IRLayout*)0;
            for (u32 k = (u32)3; bl != (IRLayout*)0 && k < bl.fieldCount(); k = k + (u32)1)
                {
                String* e = self.mslPointee(bl.typeAt(k));
                if (e == (String*)0 || IRType.isAgg(e) || self.irWidth(e) == 0)
                    continue;
                // An array reduction's pointer is a chunk's own copy, or the
                // array itself, which no other buffer names.
                if (_mArrRed.get((Hashable*)String.withU32(k)) != (Object*)0)
                    continue;
                msl.appendCString(" buf=");
                msl.append(String.withU32(bl.offsetAt(k)));
                msl.appendCString(":");
                msl.append(String.withU32(k - (u32)3));
                msl.appendCString(":");
                msl.append(String.withU32(self.irWidth(e)));
                }
            // A block writing f4 arrays: the parity its chunks start on.
            Object* pp = _parPairs != (Map*)0 ? _parPairs.get((Hashable*)fcls) : (Object*)0;
            if (pp != (Object*)0)
                {
                msl.appendCString(" pairs=");
                msl.append(String.withU32(((Number*)pp).asU32()));
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
                if (((IRInsn*)ins.get(i)).isOp(opRelease))
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
                if (!ip.isOp(opAddrOf) || ip.ops().count() == 0
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
        String* ok = String.withCString(" _xtc_sinit_run _xt_check_bounds _xt_check_bounds_n _xt_check_object _xt_check_vtbl memcpy memmove memset sqrt sqrtf sin sinf cos cosf exp expf log logf pow powf floor floorf fma fmaf fabs fabsf abs _xm_sqrt _xm_sqrtf _xm_sin _xm_sinf _xm_cos _xm_cosf _xm_exp _xm_expf _xm_ln _xm_lnf _xm_pow _xm_powf ");
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
                u16 oc = ip.opc();
                if (oc == opRetain || oc == opRelease || oc == opAutorelease || oc == opWeakLoad || oc == opWeakRegister || oc == opWeakUnregister)
                    return String.withCString("uses an ARC'd value (a class instance, String, Array, Map or block)");
                if (oc == opCallIndirect || oc == opCallBankedIndirect || oc == opVTblDispatch || oc == opVTblLoad || oc == opProtoDispatch || oc == opProtoLoad)
                    return String.withCString("makes a dynamic call (a virtual or protocol call, a function pointer or a callback)");
                if (oc == opVaStart || oc == opVaArg)
                    return String.withCString("uses varargs");
                if (oc == opAsm)
                    return String.withCString("contains inline assembly");
                if (oc == opStore || oc == opStoreVolatile || oc == opAggStore)
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
                if (oc == opCall || oc == opCallBanked || oc == opCallCloaked)
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
                    if (IRRuntime.isRuntime(name) && parAllowedExternal(name))
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
            if (d.isOp(opAddrOf))
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
            if (!d.isOp(opFieldAddr) && !d.isOp(opBitcast))
                return (String*)0;
            if (d.ops().count() == (u32)0 || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_USE)
                return (String*)0;
            d = (IRInsn*)def.get((Hashable*)String.withU32(((IROperand*)d.ops().get((u32)0)).val().seq()));
            }
        return (String*)0;
        }
    }
