// OptVectorizeRewrite.xc — the vectoriser's rewrites: a recognised loop made vector, and the pass's entry (XTIROptVectorize.m).
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptVectorizeParts>
#import <OptVectorizeShapes>

    class Opt (VectorizeRewrite)
    {

    final bool vecEscape(IRFunc* fn)
        {
        if (_profile == (OptProfile*)0 || !_profile.escapeVec())
            return false;
        self.escMergeLatches(fn);
        _esDefOf = self.defMap(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (escRecognise(fn, (IRBlock*)fn.blocks().get(b)))
                {
                escApply(fn);
                return true;
                }
        return false;
        }

    final bool escRecognise(IRFunc* fn, IRBlock* H)
        {
        if (_esDone.contains((Hashable*)H))
            return false;
        _esH = H;
        _esFn = fn;
        if (!self.escOuter(fn) || !self.escInner(fn) || !self.escExitBlock(fn))
            return false;
        _esParItems = self.escParItemLoop();
        _esBytes = self.vectorBytes();
        _esVF = _esBytes / (u32)4;
        if (_esBoundConst && (_esN < (i64)_esVF || _esN > (i64)$7FFFFFFF))
            return false;
        if (!_esBoundConst)
            {
            IRBlock* at = self.escBlockOf(fn, _esBoundOp.val());
            if (at == _esH || at == _esE || self.escRegionBlocks().contains((Object*)at)
                || _esBoundOp.val().ty() == (String*)0 || !_esBoundOp.val().ty().equals(_esIvPhi.res().ty()))
                return false;
            }
        if (!escRegionOK(fn))
            return false;
        return escPlan();
        }

    // Everything in the region (and E's own lane work) goes lane-wise, nothing
    // outside reads it, the sums are read only by their own adds, and a store
    // writes nothing a load reads.
    final bool escRegionOK(IRFunc* fn)
        {
        _esRegion = new Set();
        _esLoadRoots = new Set();
        _esIdxPhis = new Set();
        for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
            _esRegion.add((Hashable*)((IRInsn*)_esT0.phis().get(i)).res());
        Array* blks = self.escRegionBlocks();
        for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)blks.get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    _esRegion.add((Hashable*)n.res());
                }
            }
        for (u32 i = (u32)0; i < _esELane.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)_esELane.get(i);
            if (n.res() != (IRValue*)0)
                _esRegion.add((Hashable*)n.res());
            }
        for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)blks.get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (!escLaneable((IRInsn*)bb.insns().get(i)))
                    return false;
            }
        for (u32 i = (u32)0; i < _esELane.count(); i = i + (u32)1)
            if (!escLaneable((IRInsn*)_esELane.get(i)))
                return false;
        for (u32 i = (u32)0; i < _esAccW.count(); i = i + (u32)1)
            {
            if (!self.escOperandOK((IROperand*)_esAccW.get(i), false))
                return false;
            IROperand* c = (IROperand*)_esAccCond.get(i);
            if (c != (IROperand*)0 && (c.kind() != (u8)OPK_USE || !self.escOperandOK(c, true)
                                       || !c.val().ty().equals(String.withCString("Bool"))
                                       || !_esRegion.contains((Hashable*)c.val())))
                return false;
            }
        if (_esStore != (IRInsn*)0)
            {
            // The value a lane value, the base from outside the loop, and the
            // array no load reads: by name, both of them globals.
            IROperand* sv = (IROperand*)_esStore.ops().get((u32)1);
            IROperand* base = (IROperand*)_esStoreAddr.ops().get((u32)0);
            IRBlock* at = self.escBlockOf(fn, base.val());
            if (!self.escOperandOK(sv, false) || sv.kind() != (u8)OPK_USE
                || at == _esH || at == _esE || blks.contains((Object*)at))
                return false;
            String* sr = self.escRootOf(base.val());
            if (!_esParItems && _esLoadRoots.count() > (u32)0 && (!sr.hasPrefix(String.withCString("s:")) || _esLoadRoots.contains((Hashable*)sr)))
                return false;
            Array* roots = _esLoadRoots.allObjects();
            for (u32 i = (u32)0; i < roots.count(); i = i + (u32)1)
                if (!_esParItems && !((String*)roots.get(i)).hasPrefix(String.withCString("s:")))
                    return false;
            }
        // Outside the loop nothing reads a region value; inside it nothing but
        // E's add reads a sum.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            bool inLoop = bb == _esH || bb == _esE || blks.contains((Object*)bb) || bb == _esT0;
            Array* all = new Array();
            all.addAll(bb.phis());
            all.addAll(bb.insns());
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                if (bb == _esT0 && i < bb.phis().count())
                    continue;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                        continue;
                    if (!inLoop && _esRegion.contains((Hashable*)o.val()))
                        return false;
                    if (inLoop && bb != _esE && bb != _esH && self.escIsAcc(o.val()))
                        return false;
                    }
                }
            }
        return true;
        }

    // After recognition: the counters, the trip count, and whether the inner
    // loop is COUNTED (no lane test left), which a[j] loads need.
    final bool escPlan(void)
        {
        _esSkip = new Set();
        for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
            {
            IRInsn* ctr = self.escCounterOf((IRInsn*)_esT0.phis().get(i));
            if (ctr != (IRInsn*)0)
                _esSkip.add((Hashable*)ctr.res());
            }
        self.escTripTest();
        _esCounted = _esTripTest >= (i32)0 && _esTripOther == (IROperand*)0;
        for (u32 t = (u32)0; t < _esTests.count(); t = t + (u32)1)
            if (((Number*)_esCont.get(t)).asU32() != (u32)2 && (i32)t != _esTripTest)
                _esCounted = false;
        _esUniform = new Set();
        if (_esIdxPhis.count() > (u32)0)
            {
            if (!_esCounted || _esTripPhi == (IRInsn*)0)
                return false;
            Array* ix = _esIdxPhis.allObjects();
            for (u32 i = (u32)0; i < ix.count(); i = i + (u32)1)
                if ((IRValue*)ix.get(i) != _esTripPhi.res())
                    return false;
            }
        // The trip counter read only by its test, its add and load indices
        // needs no lane vector: the loads index by the trip count itself.
        if (_esCounted && _esTripPhi != (IRInsn*)0)
            {
            u32 idx = (u32)0;
            Array* blks = self.escRegionBlocks();
            for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)blks.get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* m = (IRInsn*)bb.insns().get(i);
                    if (escIs(m, "ElementAddr") && m.ops().count() == (u32)2)
                        {
                        IROperand* o = (IROperand*)m.ops().get((u32)1);
                        if (o.kind() == (u8)OPK_USE && o.val() == _esTripPhi.res())
                            idx = idx + (u32)1;
                        }
                    }
                }
            if (escUses(_esTripPhi.res()) == idx + (u32)2)
                _esUniform.add((Hashable*)_esTripPhi.res());
            }
        return true;
        }

    final bool escLaneable(IRInsn* n)
        {
        String* op = n.op();
        // A constant of any width: one is only read through a splat (a lane
        // operation on a narrow one would itself be narrow, and refused).
        if (op.equals(String.withCString("Const")))
            return n.res() != (IRValue*)0;
        if (escIsConstExt(n))
            return true;
        if (op.equals(String.withCString("ElementAddr")))
            return self.escAddrOK(n);
        if (op.equals(String.withCString("Load")))
            return self.escLoadOK(n);
        if (n.res() == (IRValue*)0)
            return false;
        String* t = n.res().ty();
        bool isBool = t.equals(String.withCString("Bool"));
        if (!Opt.escLane32(t) && !isBool)
            return false;
        u32 nops = n.ops().count();
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul"))
            || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul"))
            || op.equals(String.withCString("FDiv")))
            return !isBool && nops == (u32)2 && self.escOperandOK((IROperand*)n.ops().get((u32)0), false)
                && self.escOperandOK((IROperand*)n.ops().get((u32)1), false);
        if (op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")))
            return nops == (u32)2 && !t.equals(String.withCString("F32"))
                && self.escOperandOK((IROperand*)n.ops().get((u32)0), isBool)
                && self.escOperandOK((IROperand*)n.ops().get((u32)1), isBool)
                && (!isBool || (((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                                && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE));
        if (op.equals(String.withCString("Not")))
            return isBool && nops == (u32)1 && self.escOperandOK((IROperand*)n.ops().get((u32)0), true)
                && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE;
        if (op.equals(String.withCString("FSqrt")))
            return t.equals(String.withCString("F32")) && nops == (u32)1 && self.escOperandOK((IROperand*)n.ops().get((u32)0), false);
        if (op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")))
            {
            i64 k = nops == (u32)2 ? self.escConstOf((IROperand*)n.ops().get((u32)1)) : (i64)0 - (i64)1;
            return !isBool && !t.equals(String.withCString("F32")) && k >= (i64)0 && k < (i64)32
                && self.escOperandOK((IROperand*)n.ops().get((u32)0), false);
            }
        if (op.equals(String.withCString("URem")) || op.equals(String.withCString("UDiv")))
            return !isBool && !t.equals(String.withCString("F32")) && nops == (u32)2
                && Opt.escLog2(escConstOf((IROperand*)n.ops().get((u32)1))) >= (i64)0
                && self.escOperandOK((IROperand*)n.ops().get((u32)0), false);
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            {
            if (nops != (u32)1 || !t.equals(String.withCString("F32")))
                return false;
            IROperand* a = (IROperand*)n.ops().get((u32)0);
            if (!self.escOperandOK(a, false) || a.kind() != (u8)OPK_USE || a.val().ty().equals(String.withCString("F32")))
                return false;
            return op.equals(String.withCString("SIToFp")) || self.escSmallUnsigned(a);
            }
        if (op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")))
            {
            if (!isBool || nops != (u32)2 || n.pred() == (String*)0)
                return false;
            IROperand* a = (IROperand*)n.ops().get((u32)0);
            IROperand* b = (IROperand*)n.ops().get((u32)1);
            if (!self.escOperandOK(a, false) || !self.escOperandOK(b, false))
                return false;
            if (a.kind() != (u8)OPK_USE && b.kind() != (u8)OPK_USE)
                return false;
            return op.equals(String.withCString("ICmp")) || Opt.escFloatPred(n.pred());
            }
        if (op.equals(String.withCString("Select")))
            {
            if (isBool || nops != (u32)3)
                return false;
            IROperand* c = (IROperand*)n.ops().get((u32)0);
            return c.kind() == (u8)OPK_USE && self.escOperandOK(c, true) && c.val().ty().equals(String.withCString("Bool"))
                && self.escOperandOK((IROperand*)n.ops().get((u32)1), false)
                && self.escOperandOK((IROperand*)n.ops().get((u32)2), false);
            }
        return false;
        }

    // The vector form of a scalar operand.
    final IROperand* escV(IROperand* o, String* scalarTy)
        {
        if (o.kind() == (u8)OPK_USE)
            {
            Object* m = _esMap.get((Hashable*)o.val());
            if (m != (Object*)0)
                return IROperand.useVal((IRValue*)m);
            return IROperand.useVal(self.escSplatOf(o, o.val().ty()));
            }
        return IROperand.useVal(self.escSplatOf(o, scalarTy));
        }

    final void escLane(Array* into, IRInsn* n)
        {
        String* op = n.op();
        if (op.equals(String.withCString("Const")) || _esSkip.contains((Hashable*)n.res()) || self.escIsConstExt(n)
            || op.equals(String.withCString("ElementAddr")))
            return;     // an address is made by the load that reads it
        if (op.equals(String.withCString("Load")))
            {
            self.escLaneLoad(into, n);
            return;
            }
        String* vty = self.escVecTy(n.res().ty());
        IRValue* r = (IRValue*)0;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        if (op.equals(String.withCString("Not")))
            r = self.escPut(into, "VNot", vty, escV(a, n.res().ty()), (IROperand*)0);
        else if (op.equals(String.withCString("FSqrt")))
            r = self.escPut(into, "VSqrt", vty, escV(a, n.res().ty()), (IROperand*)0);
        else if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")))
            r = self.escPut(into, "VSIToFp", vty, escV(a, a.val().ty()), (IROperand*)0);
        else if (op.equals(String.withCString("Select")))
            {
            IRValue* m = (IRValue*)_esMap.get((Hashable*)a.val());
            IRValue* x = escV((IROperand*)n.ops().get((u32)1), n.res().ty()).val();
            IRValue* y = escV((IROperand*)n.ops().get((u32)2), n.res().ty()).val();
            r = self.escBlend(into, vty, m, x, y);
            }
        else
            {
            u32 before = into.count();
            r = escLane2(into, n, vty);
            if (into.count() == before)
                {
                _esMap.set((Hashable*)n.res(), (Object*)r);
                return;     // reused: no new instruction to carry the line
                }
            }
        _esMap.set((Hashable*)n.res(), (Object*)r);
        IRInsn* last = (IRInsn*)into.get(into.count() - (u32)1);
        last.copyDbg(n);
        }

    final IRValue* escLane2(Array* into, IRInsn* n, String* vty)
        {
        String* op = n.op();
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        IROperand* b = (IROperand*)n.ops().get((u32)1);
        String* ta = Opt.escOpTy(n, (u32)0);
        String* tb = Opt.escOpTy(n, (u32)1);
        if (op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")))
            return self.escPut(into, op.equals(String.withCString("Shl")) ? "VShl" : "VLShr", vty, escV(a, ta),
                          IROperand.immI(self.escConstOf(b), n.res().ty()));
        if (op.equals(String.withCString("UDiv")))
            return self.escPut(into, "VLShr", vty, escV(a, ta), IROperand.immI(Opt.escLog2(escConstOf(b)), n.res().ty()));
        if (op.equals(String.withCString("URem")))
            return self.escPut(into, "VAnd", vty, escV(a, ta),
                          IROperand.useVal(self.escSplatOf(IROperand.immI(self.escConstOf(b) - (i64)1, n.res().ty()), n.res().ty())));
        if (op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")))
            {
            IRValue* r = self.escPut(into, op.equals(String.withCString("ICmp")) ? "VICmp" : "VFCmp", vty, escV(a, ta), escV(b, tb));
            ((IRInsn*)into.get(into.count() - (u32)1)).setPred(n.pred());
            return r;
            }
        // 2.0 * v is v + v, exactly, and needs no splat of 2.0.
        if (op.equals(String.withCString("FMul")) && (self.escIsTwo(a) || self.escIsTwo(b)))
            {
            IROperand* v = escV(escIsTwo(a) ? b : a, n.res().ty());
            return self.escPutC(into, "VAdd", vty, v, v);
            }
        string vop = "VAdd";
        if (op.equals(String.withCString("Sub")) || op.equals(String.withCString("FSub")))
            vop = "VSub";
        else if (op.equals(String.withCString("Mul")) || op.equals(String.withCString("FMul")))
            vop = "VMul";
        else if (op.equals(String.withCString("FDiv")))
            vop = "VDiv";
        else if (op.equals(String.withCString("And")))
            vop = "VAnd";
        else if (op.equals(String.withCString("Or")))
            vop = "VOr";
        else if (op.equals(String.withCString("Xor")))
            vop = "VXor";
        return self.escPutC(into, vop, vty, escV(a, ta), escV(b, tb));
        }

    final void escApply(IRFunc* fn)
        {
        // Vectors side by side: a counted inner loop (every lane makes every
        // trip) and nothing summed across items, so the copies share the trip
        // and touch only their own items. As the reference.
        _esJam = (u32)1;
        u32 jam = _profile != (OptProfile*)0 ? _profile.escapeJam() : (u32)1;
        if (jam > (u32)1 && _esCounted && _esAccPhis.count() == (u32)0
            && !(_esBoundConst && _esN < (i64)(_esVF * jam)))
            _esJam = jam;
        _esMap = new Map();
        _esSplat = new Map();
        _esExit = new Map();
        _esPre = new Array();
        _esSplatTo = _esPre;
        _esFresh = false;
        _esCse = new Map();
        IRBlock* VH = new IRBlock(vecUniqueBlockName(fn, Opt.hoistName2(_esH.name(), "_esc")));
        IRBlock* VB = new IRBlock(vecUniqueBlockName(fn, Opt.hoistName2(_esB.name(), "_esc")));
        IRBlock* VI = new IRBlock(vecUniqueBlockName(fn, Opt.hoistName2(_esT0.name(), "_esc")));
        IRBlock* VE = new IRBlock(vecUniqueBlockName(fn, Opt.hoistName2(_esE.name(), "_esc")));
        IRBlock* VX = new IRBlock(vecUniqueBlockName(fn, Opt.hoistName2(_esH.name(), "_escx")));
        String* ivTy = _esIvPhi.res().ty();
        IRValue* viv = new IRValue(ivTy);
        _esViv = viv;
        _esVB = VB;
        IRValue* vivNext = self.escVecHead(fn, VH, VB, VE, VX, viv);
        escVecBody(fn, VB, VI, viv);
        escVecInner(fn, VI, VE);
        escVecLatch(VE, VH, viv, vivNext);
        // As many copies as the vector pool holds: halved until they fit, and
        // the head's test and the latch's step, which already name
        // _esVF * _esJam, told. As the reference.
        if (_esJam > (u32)1)
            {
            u32 j = _esJam;
            u32 pool = self.vecPoolFor(fn);
            while (j > (u32)1 && !self.escJamFits(j, VB, VI, viv, pool))
                j = j / (u32)2;
            if (j != _esJam)
                {
                _esJam = j;
                _esJamCmp.ops().set((u32)1, (Object*)IROperand.immI(_esBoundConst ? _esN - (i64)(_esVF * _esJam)
                                                                                   : (i64)(_esVF * _esJam), ivTy));
                _esJamStep.ops().set((u32)1, (Object*)IROperand.immI((i64)(_esVF * _esJam), viv.ty()));
                }
            }
        if (_esJam > (u32)1)
            self.escJam(VB, VI, VE, viv, vivNext);
        self.escVecExit(VX, viv);
        // PH's additions, before its branch, which now goes to VH.
        for (u32 i = (u32)0; i < _esPre.count(); i = i + (u32)1)
            _esPH.insns().add(_esPre.get(i));
        _esPH.term().ops().set((u32)0, (Object*)IROperand.block(VH));
        u32 at = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            if ((IRBlock*)fn.blocks().get(k) == _esPH)
                at = k + (u32)1;
        Array* five = new Array();
        five.add((Object*)VH);
        five.add((Object*)VB);
        five.add((Object*)VI);
        five.add((Object*)VE);
        five.add((Object*)VX);
        fn.blocks().insertAll(at, five);
        _esDone.add((Hashable*)_esH);
        }

    // VB: <i, i+1, …> and B's arithmetic, then into the masked inner loop.
    final void escVecBody(IRFunc* fn, IRBlock* VB, IRBlock* VI, IRValue* viv)
        {
        String* ivTy = _esIvPhi.res().ty();
        String* vty = self.escVecTy(ivTy);
        String* nm = self.vecIotaSymbol(ivTy, _esBytes, fn);
        String* pty = new String();
        pty.appendFormat("Ptr(%s, unbanked)", ivTy.cString());
        IRValue* ip = new IRValue(pty);
        IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
        ao.setRes(ip);
        ao.add(IROperand.sym(nm));
        VB.insns().add((Object*)ao);
        IRValue* iota = self.escPut(VB.insns(), "VLoad", vty, IROperand.useVal(ip), (IROperand*)0);
        _esSplatTo = VB.insns();
        Map* outer = _esSplat;
        _esSplat = new Map();
        Array* body = new Array();
        IRValue* s = self.escPut(body, "VSplat", vty, IROperand.useVal(viv), (IROperand*)0);
        IRValue* lanes = self.escPut(body, "VAdd", vty, IROperand.useVal(s), IROperand.useVal(iota));
        _esMap.set((Hashable*)_esIvPhi.res(), (Object*)lanes);
        for (u32 i = (u32)0; i < _esB.insns().count(); i = i + (u32)1)
            escLane(body, (IRInsn*)_esB.insns().get(i));
        for (u32 i = (u32)0; i < body.count(); i = i + (u32)1)
            VB.insns().add(body.get(i));
        _esSplat = outer;
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(VI));
        VB.setTerm(br);
        }

    // VI: T0's values and the live mask as phis; every test and the body
    // computed for all lanes; the mask narrowed by the tests; the values
    // blended under it; round again while any lane is live.
    final void escVecInner(IRFunc* fn, IRBlock* VI, IRBlock* VE)
        {
        String* mty = self.escVecTy(String.withCString("Bool"));
        // COUNTED (no lane test): every lane makes every trip, so there is no
        // mask, no blend and no any-lane test; the trip count alone ends it.
        bool counted = _esCounted;
        // Entry values are made in VB, each its own: a phi class starts at its
        // entry value, and one splat shared by two phis would join them.
        _esSplatTo = _esVB.insns();
        _esFresh = true;
        IRValue* ones = (IRValue*)0;
        if (!counted)
            ones = self.escSplatOf(IROperand.immI((i64)0 - (i64)1, String.withCString("I32")), String.withCString("I32"));
        // The T0 phis that have lane vectors: not the trip counter when it is
        // read only as an index (escPlan).
        Array* kept = new Array();
        Array* phis = new Array();
        Array* nexts = new Array();
        for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)_esT0.phis().get(i);
            if (_esUniform.contains((Hashable*)p.res()))
                continue;
            kept.add((Object*)p);
            phis.add((Object*)new IRValue(escVecTy(p.res().ty())));
            if (!counted)
                nexts.add((Object*)new IRValue(escVecTy(p.res().ty())));
            }
        // Entry values first, while the map still holds B's vector values.
        Array* entries = new Array();
        Set* taken = new Set();
        for (u32 i = (u32)0; i < kept.count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)kept.get(i);
            IROperand* ev = escV(escFrom(p, _esB), p.res().ty());
            // A B value entering two phis: the second gets a copy.
            if (taken.contains((Hashable*)ev.val()))
                ev = IROperand.useVal(self.escPut(_esVB.insns(), "VOr", self.escVecTy(p.res().ty()), ev, ev));
            taken.add((Hashable*)ev.val());
            entries.add((Object*)ev);
            }
        _esFresh = false;
        _esSplatTo = _esPre;
        for (u32 i = (u32)0; i < kept.count(); i = i + (u32)1)
            _esMap.set((Hashable*)((IRInsn*)kept.get(i)).res(), phis.get(i));
        IRValue* act = (IRValue*)0;
        if (!counted)
            act = new IRValue(mty);
        // The counter test as a scalar trip count (see escTripTest).
        IRValue* trip = (IRValue*)0;
        IRValue* tripNext = (IRValue*)0;
        if (_esTripTest >= (i32)0)
            {
            trip = new IRValue(_esTripTy);
            tripNext = new IRValue(_esTripTy);
            }
        _esTripV = trip;
        Array* backs = new Array();
        IRValue* actNext = escInnerBody(VI, mty, act, kept, phis, nexts, backs);
        for (u32 i = (u32)0; i < kept.count(); i = i + (u32)1)
            {
            IRValue* back = (IRValue*)(counted ? backs.get(i) : nexts.get(i));
            IRInsn* vp = IRInsn.with(String.withCString("Phi"));
            vp.setRes((IRValue*)phis.get(i));
            vp.add(IROperand.block(_esVB));
            vp.add((IROperand*)entries.get(i));
            vp.add(IROperand.block(VI));
            vp.add(IROperand.useVal(back));
            VI.addPhi(vp);
            _esExit.set((Hashable*)((IRInsn*)kept.get(i)).res(), (Object*)back);
            }
        IRValue* c = (IRValue*)0;
        if (!counted)
            {
            IRInsn* ap = IRInsn.with(String.withCString("Phi"));
            ap.setRes(act);
            ap.add(IROperand.block(_esVB));
            ap.add(IROperand.useVal(ones));
            ap.add(IROperand.block(VI));
            ap.add(IROperand.useVal(actNext));
            VI.addPhi(ap);
            // The reduction reads a copy of the mask: some back ends fold a
            // reduction in its operand's register, and the mask goes round again.
            IRValue* probe = self.escPut(VI.insns(), "VAnd", mty, IROperand.useVal(actNext), IROperand.useVal(actNext));
            IRValue* any = self.escPut(VI.insns(), "VReduceAdd", String.withCString("I32"), IROperand.useVal(probe), (IROperand*)0);
            c = self.escPut(VI.insns(), "ICmp", String.withCString("Bool"), IROperand.useVal(any),
                       IROperand.immI((i64)0, String.withCString("I32")));
            ((IRInsn*)VI.insns().get(VI.insns().count() - (u32)1)).setPred(String.withCString("NE"));
            }
        if (trip != (IRValue*)0)
            {
            IRInsn* tp = IRInsn.with(String.withCString("Phi"));
            tp.setRes(trip);
            tp.add(IROperand.block(_esVB));
            tp.add(IROperand.immI(_esTripC0, _esTripTy));
            tp.add(IROperand.block(VI));
            tp.add(IROperand.useVal(tripNext));
            VI.addPhi(tp);
            IRInsn* inc = IRInsn.with(String.withCString("Add"));
            inc.setRes(tripNext);
            inc.add(IROperand.useVal(trip));
            inc.add(IROperand.immI((i64)1, _esTripTy));
            VI.insns().add((Object*)inc);
            IRValue* more = self.escPut(VI.insns(), "ICmp", String.withCString("Bool"), IROperand.useVal(tripNext),
                                   IROperand.immI(_esTripN, _esTripTy));
            ((IRInsn*)VI.insns().get(VI.insns().count() - (u32)1)).setPred(String.withCString(_esTripSigned ? "SLT" : "ULT"));
            if (c == (IRValue*)0)
                c = more;
            else
                c = self.escPut(VI.insns(), "And", String.withCString("Bool"), IROperand.useVal(c), IROperand.useVal(more));
            }
        IRInsn* br = IRInsn.with(String.withCString("CondBranch"));
        br.add(IROperand.useVal(c));
        br.add(IROperand.block(VI));
        br.add(IROperand.block(VE));
        VI.setTerm(br);
        }

    final IRValue* escInnerBody(IRBlock* VI, String* mty, IRValue* act, Array* kept, Array* phis, Array* nexts,
                          Array* backs)
        {
        Array* into = VI.insns();
        IRValue* live = act;
        for (u32 t = (u32)0; t < _esTests.count(); t = t + (u32)1)
            {
            IRBlock* T = (IRBlock*)_esTests.get(t);
            for (u32 i = (u32)0; i < T.insns().count(); i = i + (u32)1)
                escLane(into, (IRInsn*)T.insns().get(i));
            if (_esCounted || ((Number*)_esCont.get(t)).asU32() == (u32)2)
                continue;   // counted, or passes on: no lane test
            IROperand* co = (IROperand*)T.term().ops().get((u32)0);
            IRValue* m = (IRValue*)0;
            if ((i32)t == _esTripTest)
                {
                // A scalar trip count instead (escTripTest); what is And-ed
                // with it is still a lane test.
                if (_esTripOther == (IROperand*)0)
                    continue;
                m = (IRValue*)_esMap.get((Hashable*)_esTripOther.val());
                }
            else
                m = (IRValue*)_esMap.get((Hashable*)co.val());
            if (((Number*)_esCont.get(t)).asU32() == (u32)0)
                m = self.escPut(into, "VNot", mty, IROperand.useVal(m), (IROperand*)0);
            live = self.escPut(into, "VAnd", mty, IROperand.useVal(live), IROperand.useVal(m));
            }
        for (u32 i = (u32)0; i < _esL.insns().count(); i = i + (u32)1)
            escLane(into, (IRInsn*)_esL.insns().get(i));
        for (u32 i = (u32)0; i < kept.count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)kept.get(i);
            String* vty = self.escVecTy(p.res().ty());
            // A counter: k + 1 on the live lanes is k - mask (the mask is -1);
            // counted, every lane is live: k - (-1).
            if (escCounterOf(p) != (IRInsn*)0)
                {
                if (_esCounted)
                    {
                    IRValue* m1 = self.escSplatOf(IROperand.immI((i64)0 - (i64)1, String.withCString("I32")), String.withCString("I32"));
                    backs.add((Object*)self.escPut(into, "VSub", vty, IROperand.useVal((IRValue*)phis.get(i)), IROperand.useVal(m1)));
                    continue;
                    }
                IRInsn* sb = IRInsn.with(String.withCString("VSub"));
                sb.setRes((IRValue*)nexts.get(i));
                sb.add(IROperand.useVal((IRValue*)phis.get(i)));
                sb.add(IROperand.useVal(live));
                into.add((Object*)sb);
                continue;
                }
            IRValue* nv = escV(escFrom(p, _esL), p.res().ty()).val();
            if (_esCounted)
                {
                backs.add((Object*)nv);
                continue;
                }
            IRValue* old = (IRValue*)phis.get(i);
            IRValue* d = self.escPut(into, "VXor", vty, IROperand.useVal(nv), IROperand.useVal(old));
            IRValue* e = self.escPut(into, "VAnd", vty, IROperand.useVal(d), IROperand.useVal(live));
            IRInsn* x = IRInsn.with(String.withCString("VXor"));
            x.setRes((IRValue*)nexts.get(i));
            x.add(IROperand.useVal(old));
            x.add(IROperand.useVal(e));
            into.add((Object*)x);
            }
        return live;
        }

    // VE: each sum takes its lane values; the iv steps by VF.
    final void escVecLatch(IRBlock* VE, IRBlock* VH, IRValue* viv, IRValue* vivNext)
        {
        // E reads T0's values as they stood when each lane left: the blends.
        for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
            {
            IRValue* p = ((IRInsn*)_esT0.phis().get(i)).res();
            Object* ex = _esExit.get((Hashable*)p);
            if (ex != (Object*)0)
                _esMap.set((Hashable*)p, ex);
            }
        // E's own lane work (nbody's `ax > 0`).
        for (u32 i = (u32)0; i < _esELane.count(); i = i + (u32)1)
            escLane(VE.insns(), (IRInsn*)_esELane.get(i));
        for (u32 i = (u32)0; i < _esAccPhis.count(); i = i + (u32)1)
            {
            String* t = ((IRInsn*)_esAccPhis.get(i)).res().ty();
            IROperand* w = escV((IROperand*)_esAccW.get(i), t);
            // `s = c ? s + w : s`: w where c, else 0.
            u32 kind = ((Number*)_esAccKind.get(i)).asU32();
            if (kind != (u32)0)
                {
                IRValue* m = (IRValue*)_esMap.get((Hashable*)((IROperand*)_esAccCond.get(i)).val());
                if (kind == (u32)2)
                    m = self.escPut(VE.insns(), "VNot", self.escVecTy(String.withCString("Bool")), IROperand.useVal(m), (IROperand*)0);
                w = IROperand.useVal(self.escPut(VE.insns(), "VAnd", self.escVecTy(t), w, IROperand.useVal(m)));
                }
            // The reduction folds in its operand's register on some back ends:
            // it reads a copy.
            IRValue* cp = self.escPut(VE.insns(), "VOr", self.escVecTy(t), w, w);
            IRValue* r = self.escPut(VE.insns(), "VReduceAdd", t, IROperand.useVal(cp), (IROperand*)0);
            IRInsn* a = IRInsn.with(String.withCString("Add"));
            a.setRes((IRValue*)_esVSumNext.get(i));
            a.add(IROperand.useVal((IRValue*)_esVSum.get(i)));
            a.add(IROperand.useVal(r));
            VE.insns().add((Object*)a);
            }
        if (_esStore != (IRInsn*)0)
            {
            // a[viv .. viv+VF-1] = the lanes, one vector store.
            IROperand* sv = (IROperand*)_esStore.ops().get((u32)1);
            IROperand* vv = escV(sv, sv.val().ty());
            IRValue* av = new IRValue(_esStoreAddr.res().ty());
            IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
            ea.setRes(av);
            ea.add((IROperand*)_esStoreAddr.ops().get((u32)0));
            ea.add(IROperand.useVal(viv));
            VE.insns().add((Object*)ea);
            IRInsn* vs = IRInsn.with(String.withCString("VStore"));
            vs.copyDbg(_esStore);
            vs.add(IROperand.useVal(av));
            vs.add(vv);
            for (u32 q = (u32)2; q < _esStore.ops().count(); q = q + (u32)1)
                vs.add((IROperand*)_esStore.ops().get(q));
            if (_esStore.memRes() != (IRValue*)0)
                vs.setMemRes(new IRValue(_esStore.memRes().ty()));
            VE.insns().add((Object*)vs);
            }
        IRInsn* inc = IRInsn.with(String.withCString("Add"));
        inc.setRes(vivNext);
        inc.add(IROperand.useVal(viv));
        inc.add(IROperand.immI((i64)(_esVF * _esJam), viv.ty()));
        VE.insns().add((Object*)inc);
        _esJamStep = inc;
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(VH));
        VE.setTerm(br);
        }

    final void vectorize(IRModule* m)
        {
        if (!_profile.vectorize())
            return;
        _vecModule = m;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // A dispatch clone carries its own vector width.
            _vecFnBytes = fn.simdLaneBytes();
            // The recognisers read it too (vecPoolFor), not only the appliers.
            _vecFn = fn;
            _vecRemainders = new Map();
            _esDone = new Set();
            u32 iter = (u32)0;
            while (iter < (u32)256)
                {
                // A loop around an escape-time or counted inner loop, across
                // its items (mandelbrot, nbody), FIRST: taking the inner loop
                // first (an ordered float sum) would leave it serial.
                if (vecEscape(fn))
                    {
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* c = vecRecogniseMap(fn);
                if (c != (VecCand*)0)
                    {
                    vecApplyMap(fn, c);
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* r = vecRecogniseReduction(fn);
                if (r != (VecCand*)0)
                    {
                    vecApplyReduction(fn, r);
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* mm = vecRecogniseMaxMin(fn);
                if (mm != (VecCand*)0)
                    {
                    self.vecApplyMaxMin(fn, mm);
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* cn = vecRecogniseCount(fn);
                if (cn != (VecCand*)0)
                    {
                    vecApplyCount(fn, cn);
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* ws = vecRecogniseWideningSum(fn);
                if (ws != (VecCand*)0)
                    {
                    self.vecApplyWidening(fn, ws);
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* dp = vecRecogniseDotProduct(fn);
                if (dp != (VecCand*)0)
                    {
                    self.vecApplyWidening(fn, dp);
                    iter = iter + (u32)1;
                    continue;
                    }
                // `acc = acc + X + Y` parses left-associated, which hides the
                // accumulator one Add deep; rotate it back out and try again.
                if (vecReassociate(fn))
                    {
                    iter = iter + (u32)1;
                    continue;
                    }
                // Last, because it is the only one that changes the loop
                // STRUCTURE rather than its body: splitting a loop nothing can
                // recognise gives the recognisers above two loops they can.
                if (vecDistribute(fn))
                    {
                    iter = iter + (u32)1;
                    continue;
                    }
                break;
                }
            // …then break the serial accumulator dependency. The bit selects
            // and rotates first (where the back end has them), so the
            // interleave's register estimate sees the body the back end will.
            if (vcWanted(fn))
                self.vecCombineFn(fn);
            vecUnrollReductions(fn);
            vecIVs(fn);
            }
        }

    // `for (i=0; i<N; i++) b[i] = f(a[i], …)` — a single induction variable, no
    // carried value, loads and stores all indexed by the iv, and arithmetic
    // that is elementwise over them.
    // `acc = acc + X + Y` is left-associated by the parser, so the back-edge
    // value is Add(Add(acc, X), Y) and the accumulator sits one Add DEEPER than
    // every recogniser looks — each wants Add(acc, elem). Integer addition is
    // associative modulo 2^32, so rotating the chain is exact:
    //
    //     (acc + X) + Y   ->   acc + (X + Y)
    //
    // Applied repeatedly, that lifts the accumulator out of a chain of any
    // depth. It is worth more than it looks: int_muldiv reads
    // `acc = acc + ((a[i] * 7) / 3) + (a[i] / 11)`, and BOTH halves of it — the
    // magic-division work and the reduction itself — were blocked by nothing
    // but the shape of those two plus signs.
    final bool vecReassociate(IRFunc* fn)
        {
        bool changed = false;
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(hi);
            if (vecIsRemainder(H))
                continue;
            if (H.phis().count() < (u32)2)
                continue;
            // Every phi in the header is a candidate accumulator. Which one is
            // the induction variable does not matter: rotating is sound for any
            // of them, and a phi that is not an accumulator never matches.
            Map* accs = new Map();
            for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)H.phis().get(i);
                if (phi.res() != (IRValue*)0)
                    accs.set((Hashable*)phi.res(), (Object*)phi);
                }
            for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
                {
                IRBlock* B = (IRBlock*)fn.blocks().get(bi);
                if (B == H)
                    continue;
                if (B.term() == (IRInsn*)0 || !B.term().op().equals(String.withCString("Branch"))
                    || B.term().ops().count() < (u32)1
                    || ((IROperand*)B.term().ops().get((u32)0)).blk() != H)
                    continue;
                if (vecReassociateIn(fn, B, accs))
                    changed = true;
                }
            }
        return changed;
        }

    // LOOP DISTRIBUTION for multiple accumulators. Every recogniser gates on a
    // header carrying exactly two phis — the induction variable and one
    // accumulator — so a loop summing two things at once is refused outright.
    // Rather than teach six recognisers about N accumulators, split the loop:
    // copy it, let the copy keep one accumulator and the original keep the
    // rest, and the existing recognisers then take each half on the next pass.
    //
    // Duplicating the loop duplicates its LOADS, so the body must be free of
    // stores and calls — nothing here may be observed twice. The chains are
    // otherwise independent by construction: each accumulator's cycle is closed
    // (phi -> ... -> accNext -> phi), so removing one pair takes its whole chain
    // with it once the leftovers are swept.
    final bool vecDistribute(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            if (vecDistributeAt(fn, (IRBlock*)fn.blocks().get(hi)))
                return true;
        return false;
        }

    // Split out for the arm64 frame budget, as vecWideningAt was.
    final bool vecDistributeAt(IRFunc* fn, IRBlock* H)
        {
        if (vecIsRemainder(H))
            return false;
        if (H.phis().count() < (u32)3)
            return false;
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* co = (IROperand*)term.ops().get((u32)0);
        if (co.kind() != (u8)OPK_USE)
            return false;
        IRInsn* guard = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n.res() == co.val())
                guard = n;
            }
        if (guard == (IRInsn*)0 || !guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* g0 = (IROperand*)guard.ops().get((u32)0);
        if (g0.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = g0.val();

        // One body, one latch, one exit — the shape every recogniser assumes.
        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() != iv || phi.ops().count() != (u32)4)
                continue;
            bool zeroIsLatch = ((IROperand*)phi.ops().get((u32)0)).blk() == t0
                            || ((IROperand*)phi.ops().get((u32)2)).blk() == t0;
            B = zeroIsLatch ? t0 : t1;
            E = zeroIsLatch ? t1 : t0;
            }
        if (B == (IRBlock*)0 || E == (IRBlock*)0 || B == H || E == H)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;
        if (B.term() == (IRInsn*)0 || !B.term().op().equals(String.withCString("Branch"))
            || B.term().ops().count() < (u32)1 || ((IROperand*)B.term().ops().get((u32)0)).blk() != H)
            return false;
        if (!self.vecDistributePure(B))
            return false;

        // The accumulators, paired with the body instruction that closes each
        // cycle. The peel target is the LAST of them.
        Array* accPhis = new Array();
        Array* accNexts = new Array();
        bool shaped = true;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == (IRValue*)0 || phi.res() == iv || phi.ops().count() != (u32)4)
                continue;
            IROperand* back = self.vecBackOp(phi, B);
            if (back == (IROperand*)0 || back.kind() != (u8)OPK_USE)
                {
                shaped = false;
                break;
                }
            IRInsn* accNext = (IRInsn*)0;
            for (u32 k = (u32)0; k < B.insns().count(); k = k + (u32)1)
                if (((IRInsn*)B.insns().get(k)).res() == back.val())
                    accNext = (IRInsn*)B.insns().get(k);
            if (accNext == (IRInsn*)0)
                {
                shaped = false;
                break;
                }
            accPhis.add((Object*)phi);
            accNexts.add((Object*)accNext);
            }
        if (!shaped || accPhis.count() < (u32)2)
            return false;

        // The chains must be INDEPENDENT. `a2 = a2 + a1` in the body would have
        // a1's chain swept out from under it and a2 would then read a deleted
        // value — which is not a theoretical worry: before this test, building
        // the self-hosted compiler with distribution on produced a compiler
        // that read float literals wrong, and the corpus lost twenty fixtures.
        //
        // The test is on the backward CONE of each cycle-closing instruction:
        // no accumulator's cone may contain another accumulator's phi or its
        // closing instruction. Sharing pure work is fine and expected — both of
        // string_scan's chains read the same load, and the copy simply loads it
        // again — so counting uses is the wrong test. It rejects the count
        // chain, whose phi an if-converted body reads twice.
        Array* cones = new Array();
        for (u32 a = (u32)0; a < accNexts.count(); a = a + (u32)1)
            cones.add((Object*)self.vecDistributeCone((IRInsn*)accNexts.get(a), B));
        for (u32 a = (u32)0; a < cones.count(); a = a + (u32)1)
            {
            Map* cone = (Map*)cones.get(a);
            for (u32 b2 = (u32)0; b2 < accPhis.count(); b2 = b2 + (u32)1)
                {
                if (a == b2)
                    continue;
                if (cone.get((Hashable*)((IRInsn*)accPhis.get(b2)).res()) != (Object*)0)
                    return false;
                if (cone.get((Hashable*)((IRInsn*)accNexts.get(b2)).res()) != (Object*)0)
                    return false;
                }
            }
        // ...and the INDUCTION VARIABLE's own update must read no accumulator
        // either. BOTH copies advance the iv, so an accumulator in its cone is
        // needed by both — but the copy keeps only the peeled one and the
        // original keeps the rest, so whichever copy drops it is left with a
        // use that has no definition.
        //
        // _isqrt is the shape: `while (n >= k) { n -= k; k += 2; c++; }`. The
        // two accumulators k and c pass the test above — neither cone contains
        // the other — but the iv update is `n - k`, so the copy peeled for c
        // dropped k and its guard compared n against a value nothing defines.
        // The back end reads a missing value as ZERO, so it became `n >= 0` and
        // the loop ran to the wrong answer: gfx8_oval printed three wrong
        // results at -O2 and above, with make test green and no post-opt
        // verifier to catch it.
        IRInsn* ivPhi2 = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == iv)
                ivPhi2 = phi;
            }
        IRInsn* ivNextI = (IRInsn*)0;
        if (ivPhi2 != (IRInsn*)0 && ivPhi2.ops().count() == (u32)4)
            {
            IROperand* back = self.vecBackOp(ivPhi2, B);
            if (back != (IROperand*)0 && back.kind() == (u8)OPK_USE)
                for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)B.insns().get(i);
                    if (n.res() != (IRValue*)0 && n.res() == back.val())
                        ivNextI = n;
                    }
            }
        if (ivNextI != (IRInsn*)0)
            {
            Map* ivCone = self.vecDistributeCone(ivNextI, B);
            for (u32 b2 = (u32)0; b2 < accPhis.count(); b2 = b2 + (u32)1)
                {
                if (ivCone.get((Hashable*)((IRInsn*)accPhis.get(b2)).res()) != (Object*)0)
                    return false;
                if (ivCone.get((Hashable*)((IRInsn*)accNexts.get(b2)).res()) != (Object*)0)
                    return false;
                }
            }
        IRInsn* victim = (IRInsn*)accPhis.get(accPhis.count() - (u32)1);

        Map* cmap = new Map();
        Array* cl = self.vecCloneLoop(fn, H, B, cmap);
        IRBlock* H2 = (IRBlock*)cl.get((u32)0);
        IRBlock* B2 = (IRBlock*)cl.get((u32)1);
        IRValue* victimClone = (IRValue*)cmap.get((Hashable*)victim.res());
        if (victimClone == (IRValue*)0)
            return false;

        // The original exits into a fresh PREHEADER for the copy, which falls
        // into it. Branching H straight at H2 would work, but every recogniser
        // refuses a loop whose exit block carries phis — and H2's phis are
        // exactly that — so the original would stop being vectorisable the
        // moment it was split. The empty block costs one branch and keeps both
        // halves in the shape the recognisers expect.
        IRBlock* PH2 = new IRBlock(hoistName2(H2.name(), "_pre"));
        IRInsn* into = IRInsn.with(String.withCString("Branch"));
        into.copyDbg(term);
        into.add(IROperand.block(H2));
        PH2.setTerm(into);
        for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)term.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == E)
                term.ops().set(k, (Object*)IROperand.block(PH2));
            }

        // The copy is entered from that preheader now, not the original's. Its
        // seeds are unchanged: it runs the same range from the same values.
        IRBlock* PH = ((IROperand*)((IRInsn*)H.phis().get((u32)0)).ops().get((u32)0)).blk() == B
                          ? ((IROperand*)((IRInsn*)H.phis().get((u32)0)).ops().get((u32)2)).blk()
                          : ((IROperand*)((IRInsn*)H.phis().get((u32)0)).ops().get((u32)0)).blk();
        for (u32 i = (u32)0; i < H2.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H2.phis().get(i);
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(q);
                if (bo.kind() == (u8)OPK_BLOCK && bo.blk() == PH)
                    phi.ops().set(q, (Object*)IROperand.block(PH2));
                }
            }

        // After the loops, the peeled accumulator is the COPY's.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            self.vecDistributeRewrite(bb.phis(), victim.res(), victimClone);
            self.vecDistributeRewrite(bb.insns(), victim.res(), victimClone);
            if (bb.term() != (IRInsn*)0)
                self.vecDistributeRewriteOne(bb.term(), victim.res(), victimClone);
            }

        // The copy must be IN the function before anything is dropped: the
        // sweep in vecDropAcc decides what is dead by walking fn.blocks(), so a
        // copy that is not yet listed contributes no uses and its whole body
        // scores dead.
        u32 at = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            if ((IRBlock*)fn.blocks().get(k) == B)
                at = k + (u32)1;
        Array* three = new Array();
        three.add((Object*)PH2);
        three.add((Object*)H2);
        three.add((Object*)B2);
        fn.blocks().insertAll(at, three);

        // Drop the peeled accumulator from the original and the others from the
        // copy. Each is a closed cycle, so the phi and its back-edge definition
        // go together and the rest of the chain falls out in the sweep.
        self.vecDropAcc(fn, victim.res(), H, B);
        IRValue* ivClone = (IRValue*)cmap.get((Hashable*)iv);
        Array* drop = new Array();
        for (u32 i = (u32)0; i < H2.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H2.phis().get(i);
            if (phi.res() == (IRValue*)0 || phi.res() == victimClone || phi.res() == ivClone)
                continue;
            drop.add((Object*)phi.res());
            }
        for (u32 i = (u32)0; i < drop.count(); i = i + (u32)1)
            self.vecDropAcc(fn, (IRValue*)drop.get(i), H2, B2);
        return true;
        }

    final VecCand* vecRecogniseMap(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                {
                defOf.set((Hashable*)bb.term().res(), (Object*)bb.term());
                defBlk.set((Hashable*)bb.term().res(), (Object*)bb);
                }
            }
        Map* uses = self.useCounts(fn);

        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecMapAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    final VecCand* vecMapAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (vecIsRemainder(H))
            return (VecCand*)0;
        // One phi only: an induction variable and nothing carried.
        if (H.phis().count() != (u32)1)
            return (VecCand*)0;
        IRInsn* ivPhi = (IRInsn*)H.phis().get((u32)0);
        if (ivPhi.res() == (IRValue*)0 || ivPhi.memRes() != (IRValue*)0)
            return (VecCand*)0;
        IRValue* iv = ivPhi.res();

        // The header holds the guard and nothing that touches memory.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != (IRValue*)0)
                return (VecCand*)0;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return (VecCand*)0;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return (VecCand*)0;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return (VecCand*)0;
        // The guard compares the iv against a positive constant trip count.
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE || gl.val() != iv)
            return (VecCand*)0;
        i64 n = (i64)0;
        if (!self.vecMapBound(guard, defOf, &n))
            return (VecCand*)0;

        // The body latches to the header unconditionally; the other target exits.
        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (rotIsLatch(t0, H))
            {
            B = t0;
            E = t1;
            }
        else if (rotIsLatch(t1, H))
            {
            B = t1;
            E = t0;
            }
        else
            return (VecCand*)0;
        if (E == (IRBlock*)0 || B.insns().count() == (u32)0)
            return (VecCand*)0;

        // ivNext = Add(iv, 1) in the body, read exactly once (by the phi).
        if (ivPhi.ops().count() != (u32)4)
            return (VecCand*)0;
        IROperand* nextOp = (IROperand*)0;
        if (((IROperand*)ivPhi.ops().get((u32)0)).blk() == B)
            nextOp = (IROperand*)ivPhi.ops().get((u32)1);
        else if (((IROperand*)ivPhi.ops().get((u32)2)).blk() == B)
            nextOp = (IROperand*)ivPhi.ops().get((u32)3);
        if (nextOp == (IROperand*)0 || nextOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* no = defOf.get((Hashable*)nextOp.val());
        Object* nb = defBlk.get((Hashable*)nextOp.val());
        if (no == (Object*)0 || nb == (Object*)0 || (IRBlock*)nb != B)
            return (VecCand*)0;
        IRInsn* ivNext = (IRInsn*)no;
        if (!ivNext.op().equals(String.withCString("Add")))
            return (VecCand*)0;
        if (countOf(uses, nextOp.val()) != (u32)1)
            return (VecCand*)0;
        if (ivNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* a0 = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* a1 = (IROperand*)ivNext.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
            stepOp = a1;
        else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
            stepOp = a0;
        i32 step = (i32)0;
        if (stepOp == (IROperand*)0 || !self.vecConst(stepOp, defOf, &step) || step != (i32)1)
            return (VecCand*)0;

        // The iv must not escape the header and body: after the rewrite it
        // advances by the vector width, so any outside reader would see the
        // wrong value.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return (VecCand*)0;
            }

        String* laneTy = self.vecClassifyBody(B, iv, ivNext, defOf, defBlk);
        if (laneTy == (String*)0)
            return (VecCand*)0;
        u32 lw = self.irWidth(laneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vb = self.vectorBytes();
        u32 vw = vb / lw;
        // A partial final vector would need a scalar tail, which this does not
        // emit — so the trip count has to divide evenly.
        // Trailing test: the non-zero-start refusal, folded in to avoid a
        // separate branch (see vecIvStartsAtZero).
        // A NON-ZERO start is refused (#1125), and refusing it is also what
        // stops the REMAINDER being re-recognised and re-cloned: the clone's
        // induction phi enters at M, so it fails this test by construction.
        // The map path's arithmetic is 32-bit: a start of 2^31 or more narrows
        // to a negative number and takes the runtime-start path, as before.
        i32 mapStart = (i32)self.vecIvStart(ivPhi, B, defOf);
        if (vw < (u32)2)
            return (VecCand*)0;
        // A RUNTIME start (`for (i = lo; …)`: a loop resumed, or a benchmark's
        // opaque zero): the vector loop begins at it and runs to the runtime
        // limit start + ((bound - start) & ~(vw-1)), as a reduction's does,
        // so even a constant bound becomes a runtime trip (as an immediate:
        // the limit is computed in the preheader, ahead of the header that
        // holds the bound's Const). The start must be loop-invariant; the
        // remainder clone is refused by vecIsRemainder above, not by this.
        IROperand* rtStart = (IROperand*)0;
        if (mapStart < (i32)0)
            {
            IROperand* so = self.vecEntryOpOf(ivPhi, B);
            if (so == (IROperand*)0 || so.kind() != (u8)OPK_USE)
                return (VecCand*)0;
            Object* sdb = defBlk.get((Hashable*)so.val());
            if (sdb != (Object*)0 && ((IRBlock*)sdb == H || (IRBlock*)sdb == B))
                return (VecCand*)0;
            rtStart = so;
            mapStart = (i32)0;
            }
        bool rt = _vrMapRT || rtStart != (IROperand*)0;
        // Bases that may overlap are checked in the preheader (#95), against
        // a limit computed there, as a runtime trip's is; the scalar clone
        // takes the range when they do.
        bool guarded = _vrOverlap.count() > (u32)0;
        IROperand* boundOp = (IROperand*)guard.ops().get((u32)1);
        if (!_vrMapRT && (rtStart != (IROperand*)0 || guarded))
            boundOp = IROperand.immI((i64)n, iv.ty());
        if (!rt && mapStart >= n)
            return (VecCand*)0;
        if (_vrMapRT && !self.vecMapRTOK(guard, defBlk, H, B))
            return (VecCand*)0;
        IRBlock* PH = self.vecEntryBlkOf(ivPhi, B);
        if (PH == (IRBlock*)0 || PH == B || PH == H)
            return (VecCand*)0;
        // Not a whole number of vectors: the vector loop runs to the last whole
        // one and a CLONE of this loop finishes the tail (vecCloneLoop +
        // vecMapEpilogue). Below one vector there is nothing to gain.
        i32 mapTrip = n - mapStart;
        i32 epiM = mapStart + (mapTrip - (mapTrip % (i32)vw));
        // Under one whole vector: nothing to gain — and this is what refuses the
        // epilogue CLONE, whose range is shorter than a vector by construction
        // (the zero-start test used to do that job).
        if (!rt && (epiM - mapStart) < (i32)vw)
            return (VecCand*)0;
        rt = rt || guarded;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, guard, iv);
        c.setLane(laneTy, vw);
        c.setVecBytes(vb);
        c.setPre(PH);
        c.setEpi(rt || epiM != n, epiM);
        c.setRuntime(rt, boundOp);
        c.setIvStart((i64)mapStart);
        c.setIvStartOp(rtStart);
        c.setOverlap(_vrOverlap);
        return c;
        }

    // `for (i=0; i<N; i++) acc += elem(a[i])` — the header carries the induction
    // phi AND a single associative-add accumulator, and the body stores nothing:
    // the reduce IS the output. Shares the induction/guard/latch shape with the
    // map recogniser; the extra structure is the accumulator.
    final VecCand* vecRecogniseReduction(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        Map* uses = self.useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecReductionAt(fn, (IRBlock*)fn.blocks().get(hi),
                                        defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    final VecCand* vecReductionAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (vecIsRemainder(H))
            return (VecCand*)0;
        _vrAllowRT = true; // reduction, widening-sum and dot all accept one
        // FLOAT reductions reassociate the additions, so they are taken only
        // where the source grants it AND the target can lower the lane ops. A
        // par block is :goal(speed) and its run function names the loop header
        // in speedHeaders; both must hold. This is nbody's inner loop.
        bool floatRedux = _profile.floatReduce() && fn.isSpeedHeader(H.name());
        // Else, at the default goal, an ORDERED float sum where the body has
        // lane work worth it (a square root, a divide: nbody's): the elements
        // are computed lane-wise and added to the scalar sum one by one, in
        // order, so nothing is reassociated.
        bool orderedRedux = !floatRedux && _profile.orderedFloat() && self.vecHeavyFloat(H, defOf, defBlk);
        if (!self.vecReduxShape(H, defOf, defBlk))
            return (VecCand*)0;
        IRInsn* ivPhi = _vrIvPhi;
        IRInsn* accPhi = _vrAccPhi;
        IRInsn* guard = _vrGuard;
        IRValue* iv = _vrIv;
        IRBlock* B = _vrB;
        IRBlock* E = _vrE;
        i64 n = _vrN;
        IRValue* acc = accPhi.res();
        IROperand* nextOp = self.vecBackOp(ivPhi, B);
        if (nextOp == (IROperand*)0 || nextOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* no = defOf.get((Hashable*)nextOp.val());
        Object* nb = defBlk.get((Hashable*)nextOp.val());
        if (no == (Object*)0 || nb == (Object*)0 || (IRBlock*)nb != B)
            return (VecCand*)0;
        IRInsn* ivNext = (IRInsn*)no;
        if (!ivNext.op().equals(String.withCString("Add")))
            return (VecCand*)0;
        if (countOf(uses, nextOp.val()) != (u32)1)
            return (VecCand*)0;
        if (ivNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* s0 = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* s1 = (IROperand*)ivNext.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (s0.kind() == (u8)OPK_USE && s0.val() == iv)
            stepOp = s1;
        else if (s1.kind() == (u8)OPK_USE && s1.val() == iv)
            stepOp = s0;
        i32 step = (i32)0;
        if (stepOp == (IROperand*)0 || !self.vecConst(stepOp, defOf, &step) || step != (i32)1)
            return (VecCand*)0;

        // accNext = Add(acc, elem), in the body and read exactly once.
        IROperand* accNextOp = self.vecBackOp(accPhi, B);
        if (accNextOp == (IROperand*)0 || accNextOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* ao = defOf.get((Hashable*)accNextOp.val());
        Object* ab = defBlk.get((Hashable*)accNextOp.val());
        if (ao == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return (VecCand*)0;
        IRInsn* accNext = (IRInsn*)ao;
        if (!(accNext.op().equals(String.withCString("Add"))
              || ((floatRedux || orderedRedux) && accNext.op().equals(String.withCString("FAdd")))))
            return (VecCand*)0;
        if (countOf(uses, accNextOp.val()) != (u32)1)
            return (VecCand*)0;
        if (accNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* e0 = (IROperand*)accNext.ops().get((u32)0);
        IROperand* e1 = (IROperand*)accNext.ops().get((u32)1);
        IROperand* elemOp = (IROperand*)0;
        if (e0.kind() == (u8)OPK_USE && e0.val() == acc)
            elemOp = e1;
        else if (e1.kind() == (u8)OPK_USE && e1.val() == acc)
            elemOp = e0;
        if (elemOp == (IROperand*)0 || elemOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        IROperand* initOp = self.vecEntryOpOf(accPhi, B);
        IRBlock* PH = self.vecEntryBlkOf(accPhi, B);
        if (initOp == (IROperand*)0 || PH == (IRBlock*)0 || PH == B || PH == H)
            return (VecCand*)0;

        // The induction variable must not escape, and the carry must be read
        // inside the loop ONLY by accNext.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return (VecCand*)0;
            }
        if (vecAccReadElsewhere(H, accNext, acc))
            return (VecCand*)0;
        if (vecAccReadElsewhere(B, accNext, acc))
            return (VecCand*)0;

        String* laneTy = vecClassifyReduxBody(B, iv, ivNext, accNext, elemOp,
                                              defOf, defBlk, uses, floatRedux || orderedRedux);
        if (laneTy == (String*)0)
            return (VecCand*)0;
        // The accumulator's own width must match the loads — this is an i32/u32
        // add, not a widening one (that shape has its own recogniser).
        if (accNext.res() == (IRValue*)0 || !laneTy.equals(accNext.res().ty()))
            return (VecCand*)0;
        u32 lw = self.irWidth(laneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vb = self.vectorBytes();
        u32 vw = vb / lw;
        // The trailing test was the non-zero-start refusal (see
        // vecIvStartsAtZero); folded into this condition rather than written as
        // its own statement, because a separate branch costs frame slots and
        // vecWideningAt sits 80 bytes from the arm64 budget.
        if (vw < (u32)2)
            return (VecCand*)0;
        // A RUNTIME start (a par chunk's `lo`) is vectorisable when the trip is
        // also runtime and the start is loop-invariant: the vector loop begins
        // at it and the runtime limit M is computed from (bound - start). This
        // is the shape of EVERY par loop, which is why the whole CPU path used
        // to stay scalar. `_vrIvStart` stays 0 and `_vrIvStartOp` carries it.
        if (_vrIvStart < (i64)0)
            {
            IROperand* startOp = self.vecEntryOpOf(ivPhi, B);
            if (startOp == (IROperand*)0 || startOp.kind() != (u8)OPK_USE)
                return (VecCand*)0;
            Object* sdb = defBlk.get((Hashable*)startOp.val());
            if (sdb != (Object*)0 && ((IRBlock*)sdb == H || (IRBlock*)sdb == B))
                return (VecCand*)0;
            // A literal bound with a runtime start is a runtime trip too, the
            // bound as an immediate (the limit is computed in the preheader,
            // ahead of the header holding its Const). As the map recogniser.
            if (!_vrRuntime)
                {
                _vrRuntime = true;
                _vrBoundOp = IROperand.immI((i64)n, _vrIv.ty());
                }
            _vrIvStartOp = startOp;
            _vrIvStart = (i64)0;
            }
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;
        // Not a whole number of vectors: the vector loop runs to the last whole
        // one and a CLONE of this loop finishes the tail (vecCloneLoop +
        // vecReduxEpilogue). Below one vector there is nothing to gain.
        // A RUNTIME bound always takes the epilogue: how many whole vectors fit
        // is not knowable here, so the limit is computed in the preheader and
        // the clone runs [M, n). No `n < vw` guard is needed -- that gives M = 0,
        // the vector guard fails at once, and the clone runs the whole range.
        if (_vrRuntime)
            {
            // A strict less-than is required: with `i <= n` the trip count is
            // n+1 and n & ~(vw-1) is simply wrong.
            if (!guard.pred().equals(String.withCString("ULT")) && !guard.pred().equals(String.withCString("SLT")))
                return (VecCand*)0;
            // Loop-INVARIANT: a value with no defining instruction is a
            // parameter, invariant by construction, so an absent entry here
            // must NOT read as a refusal.
            // An immediate (a literal bound with a runtime start) is
            // invariant and has no value to look up.
            Object* bdb = _vrBoundOp.kind() == (u8)OPK_USE ? defBlk.get((Hashable*)_vrBoundOp.val()) : (Object*)0;
            if (bdb != (Object*)0 && ((IRBlock*)bdb == H || (IRBlock*)bdb == B))
                return (VecCand*)0;
            }
        i64 redTrip = n - _vrIvStart;
        i64 epiM = _vrIvStart + (redTrip - (redTrip % (i64)vw));
        if (!_vrRuntime && epiM != n && (epiM - _vrIvStart) < (i64)vw)
            return (VecCand*)0;
        // A NON-ZERO start is refused, and this is a BUG FIX (#1125), not
        // caution. The transform steps the EXISTING induction phi by the vector
        // width and keeps the guard, which is equivalent to the scalar loop only
        // when the counter begins at 0. Nothing checked, so
        //     for (i = 1; i < 64; i++) s += a[i];
        // passed on `64 % 4 == 0` with a real trip count of 63 and returned 1956
        // for a sum that is 2016, at -O2 and above, on every vectorising back
        // end. tests/fixtures/vectorize_const_tail.xc pins it.
        if (_vrIvStart < (i64)0)
            return (VecCand*)0;
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, guard, iv);
        c.setLane(laneTy, vw);
        c.setVecBytes(vb);
        c.setReduction(accPhi, accNext, acc, elemOp.val(), initOp, PH);
        c.setDivMagic(_vrDivMagic);
        c.setIota(_profile.iota() && _vrUsesIv);
        c.setOrdered(orderedRedux);
        c.setEpi(_vrRuntime || epiM != n, epiM);
        c.setRuntime(_vrRuntime, _vrBoundOp);
        c.setIvStart(_vrIvStart);
        c.setIvStartOp(_vrIvStartOp);
        return c;
        }

    final String* vecClassifyReduxBody(IRBlock* B, IRValue* iv, IRInsn* ivNext,
                                 IRInsn* accNext, IROperand* elemOp,
                                 Map* defOf, Map* defBlk, Map* uses,
                                 bool floatRedux)
        {
        String* laneTy = (String*)0;
        bool sawLoad = false;
        _vrDivMagic = new Map();
        Array* elems = new Array();
        // IOTA. The per-lane value does not have to come from memory: in
        // `acc += f(r)` the element IS the induction variable and there is no
        // array anywhere. Seeding the element set with the iv makes every
        // instruction that reads it elementwise, exactly as a Load's result is.
        // _vrUsesIv records whether the body actually read it, so a loop with
        // neither loads nor iv uses is still refused.
        bool wantIota = _profile.iota();
        bool ivLaneOK = self.vecRedux32(iv.ty());
        _vrUsesIv = false;
        if (wantIota && ivLaneOK)
            elems.add((Object*)iv);
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == ivNext || n == accNext)
                continue;
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")))
                continue;
            if (op.equals(String.withCString("ElementAddr")))
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
                        if (bd == (Object*)0 || !((IRInsn*)bd).op().equals(String.withCString("AddrOf")))
                            return (String*)0;
                        }
                    }
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                // A fully DEAD load — its value AND memory token unused — has no
                // effect: skip it rather than refuse the loop. A static-init
                // guard's leftover flag load can sit in a loop body, and a body
                // with any non-iv memory op was refused.
                if (n.res() != (IRValue*)0 && self.countOf(uses, n.res()) == (u32)0
                    && (n.memRes() == (IRValue*)0 || self.countOf(uses, n.memRes()) == (u32)0))
                    continue;
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (String*)0;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                String* lt = n.res().ty();
                if (!self.vecRedux32(lt) && !(floatRedux && lt.equals(String.withCString("F32"))))
                    return (String*)0;
                if (laneTy != (String*)0 && !laneTy.equals(lt))
                    return (String*)0;
                laneTy = lt;
                sawLoad = true;
                elems.add((Object*)n.res());
                continue;
                }
            if (op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            // A value computed from constants alone (`32 - c`): itself a
            // constant, which its users read as one.
            i32 kq = (i32)0;
            if (n.res() != (IRValue*)0 && self.vecConst(IROperand.useVal(n.res()), defOf, &kq))
                continue;
            // A shift LEFT by a compile-time amount, as the shift right below
            // (a rotate is one of each: MD5's rounds), lowered as VShl.
            if (op.equals(String.withCString("Shl")) && _profile.laneShift())
                {
                if (n.res() == (IRValue*)0 || !self.vecRedux32(n.res().ty()))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)0), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                i32 shl = (i32)0;
                if (!self.vecConst((IROperand*)n.ops().get((u32)1), defOf, &shl))
                    return (String*)0;
                if (shl < (i32)0 || shl >= (i32)32)
                    return (String*)0;
                IROperand* l0 = (IROperand*)n.ops().get((u32)0);
                if (l0.kind() == (u8)OPK_USE && l0.val() == iv)
                    _vrUsesIv = true;
                elems.add((Object*)n.res());
                continue;
                }
            // A bitwise not (one operand), lowered as VNot; gated with the
            // shifts (the back ends that lower those lower this).
            if (op.equals(String.withCString("Not")) && _profile.laneShift())
                {
                if (n.res() == (IRValue*)0 || !self.vecRedux32(n.res().ty()))
                    return (String*)0;
                if (n.ops().count() < (u32)1)
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)0), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                IROperand* n0 = (IROperand*)n.ops().get((u32)0);
                if (n0.kind() == (u8)OPK_USE && n0.val() == iv)
                    _vrUsesIv = true;
                elems.add((Object*)n.res());
                continue;
                }
            // Unsigned division by a compile-time constant. There is no lane
            // divide; it becomes a magic multiply, which needs the HIGH half of
            // the lane product. Only the simple magic form is taken (see
            // vecMagicU32) and only where the back end lowers VMulHi.
            if (op.equals(String.withCString("UDiv")) && _profile.highMul())
                {
                if (n.res() == (IRValue*)0 || !n.res().ty().equals(String.withCString("U32")))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)0), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                i32 dv = (i32)0;
                if (!self.vecConst((IROperand*)n.ops().get((u32)1), defOf, &dv))
                    return (String*)0;
                if (dv <= (i32)1 || !self.vecMagicU32((u32)dv))
                    return (String*)0;
                Array* mg = new Array();
                mg.add((Object*)Number.with(_magicM));
                mg.add((Object*)Number.with(_magicS));
                _vrDivMagic.set((Hashable*)n.res(), (Object*)mg);
                elems.add((Object*)n.res());
                continue;
                }
            // A logical shift right by a COMPILE-TIME amount. There is no
            // lane-wise variable shift here, and none is needed: every shift in
            // the shapes this recognises is by a literal. Gated on the flag that
            // says the back end lowers VLShr — emitting it where it is not
            // lowered is silence, not a build failure.
            if (op.equals(String.withCString("LShr")) && _profile.laneShift())
                {
                if (n.res() == (IRValue*)0 || !self.vecRedux32(n.res().ty()))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)0), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                i32 sh = (i32)0;
                if (!self.vecConst((IROperand*)n.ops().get((u32)1), defOf, &sh))
                    return (String*)0;
                if (sh < (i32)0 || sh >= (i32)32)
                    return (String*)0;
                IROperand* s0 = (IROperand*)n.ops().get((u32)0);
                if (s0.kind() == (u8)OPK_USE && s0.val() == iv)
                    _vrUsesIv = true;
                elems.add((Object*)n.res());
                continue;
                }
            // FLOAT lane ops, only in a float reduction: a lane square root
            // (nbody's sqrt(d2)) and a lane divide.
            if (floatRedux && (op.equals(String.withCString("FSqrt")) || op.equals(String.withCString("FDiv"))))
                {
                if (n.res() == (IRValue*)0 || !n.res().ty().equals(String.withCString("F32")))
                    return (String*)0;
                u32 want = op.equals(String.withCString("FSqrt")) ? (u32)1 : (u32)2;
                if (n.ops().count() < want)
                    return (String*)0;
                for (u32 k = (u32)0; k < want; k = k + (u32)1)
                    if (!self.vecReduxOperandOK((IROperand*)n.ops().get(k), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                        return (String*)0;
                elems.add((Object*)n.res());
                continue;
                }
            if (vecElementwise(op))
                {
                if (n.res() == (IRValue*)0
                    || (!self.vecRedux32(n.res().ty()) && !(floatRedux && n.res().ty().equals(String.withCString("F32")))))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)0), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)1), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() == iv)
                        _vrUsesIv = true;
                    }
                elems.add((Object*)n.res());
                continue;
                }
            // A STORE of an elementwise value to an iv-indexed address, alongside
            // the reduction: saxpy's `v = 3*xs[i]+ys[i]; ys[i] = v; total += v`.
            // The stored value is already in the elementwise set; the address is
            // the only new shape and it must be an iv-indexed ElementAddr, the
            // same one a Load uses.
            if (op.equals(String.withCString("Store")))
                {
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                if (!self.vecReduxOperandOK((IROperand*)n.ops().get((u32)1), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                continue;
                }
            return (String*)0; // a store, a call, a per-lane-varying scalar
            }
        // With loads, the lane type comes from them. With none, the elements
        // ARE the induction variable and its type is the lane type.
        if (laneTy == (String*)0 && wantIota && ivLaneOK && _vrUsesIv)
            laneTy = iv.ty();
        if (laneTy == (String*)0)
            return (String*)0;
        if (!sawLoad && !(wantIota && _vrUsesIv))
            return (String*)0;
        // The reduced element must itself be per-lane. A loop-invariant one
        // would be `acc += k` — a scaled count, not a lane-wise reduction.
        if (!self.hasValue(elems, elemOp.val()))
            return (String*)0;
        // A big body must fit the vector registers: the back ends do not
        // spill a vector, and running out is a build error.
        if (B.insns().count() > (u32)VEC_SPLAT_BIG_BODY && !self.vecScalarBodyFits(B, elems, self.vecPoolFor(_vecFn)))
            return (String*)0;
        return laneTy;
        }

    final void vecApplyMap(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        // Epilogue part 1: clone the scalar loop BEFORE the body below is
        // rewritten in place. The remainder has to be taken now or not at all.
        IRBlock* mH2 = (IRBlock*)0;
        IRBlock* mB2 = (IRBlock*)0;
        Map* mcmap = new Map();
        if (c.needEpi())
            {
            Array* cl = self.vecCloneLoop(fn, c.h(), B, mcmap);
            mH2 = (IRBlock*)cl.get((u32)0);
            _vecRemainders.set((Hashable*)mH2, (Object*)mH2);
            mB2 = (IRBlock*)cl.get((u32)1);
            // The vector loop now stops at the last whole vector; the clone's
            // own (cloned) guard still tests the original bound.
            self.vecMapSetBound(c);
            }
        _vecTy = new String();
        _vecTy = self.vecTyOf(c.laneTy(), c.vecBytes());
        _vecMap = new Map();
        _vecSplat = new Map();
        _vecSplatBig = false;
        _vecEntryCache = new Map();
        _vecBody = new Array();

        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        // Hoist invariant splats to the loop's PREHEADER, not the function entry.
        // The arm64 vector pool is v18..v31, every one CALLER-saved under AAPCS,
        // and the allocator has no call-clobber handling: a splat parked in the
        // entry block lives for the whole function, so any `bl` before the loop
        // destroys it and the loop adds whatever the callee left behind (#1134).
        // The preheader keeps compute-once while making the range too short to
        // span a call, and a vectorised body cannot contain a call because every
        // recogniser rejects one. The count applier already did this.
        IRBlock* entry = c.pre();
        if (entry == (IRBlock*)0)
            entry = (IRBlock*)fn.blocks().get((u32)0);

        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == c.ivNext())
                {
                // Step the induction variable by the vector width.
                IROperand* a0 = (IROperand*)n.ops().get((u32)0);
                IROperand* a1 = (IROperand*)n.ops().get((u32)1);
                bool ivLeft = a0.kind() == (u8)OPK_USE && a0.val() == c.iv();
                IRInsn* add = IRInsn.with(String.withCString("Add"));
                add.copyDbg(n);
                add.setRes(n.res());
                add.add(ivLeft ? a0 : a1);
                add.add(IROperand.immI((i32)c.vw(), n.res().ty()));
                _vecBody.add((Object*)add);
                continue;
                }
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                {
                _vecBody.add((Object*)n); // address, splat source, dead plumbing
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                IRValue* vr = new IRValue(self.vecTyOf(n.res().ty(), c.vecBytes()));
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                vl.copyDbg(n);
                vl.setRes(vr);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vl.add((IROperand*)n.ops().get(k)); // [ea, mem]
                vl.setMemRes(n.memRes());               // keep the memory chain
                _vecBody.add((Object*)vl);
                _vecMap.set((Hashable*)n.res(), (Object*)vr);
                continue;
                }
            if (op.equals(String.withCString("Store")))
                {
                self.vecSetLane(Opt.vecOperandTy((IROperand*)n.ops().get((u32)1)), c);
                IROperand* vval = self.vecOperandFor((IROperand*)n.ops().get((u32)1),
                                                fn, entry, B, c, defOf, defBlk);
                IRInsn* vs = IRInsn.with(String.withCString("VStore"));
                vs.copyDbg(n);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vs.add(k == (u32)1 ? vval : (IROperand*)n.ops().get(k));
                vs.setMemRes(n.memRes());
                _vecBody.add((Object*)vs);
                continue;
                }
            if (Opt.vecConvOp(op))
                {
                self.vecApplyConv(n, c, entry);
                continue;
                }
            // Elementwise arithmetic.
            self.vecSetLane(n.res().ty(), c);
            IROperand* va = self.vecOperandFor((IROperand*)n.ops().get((u32)0),
                                          fn, entry, B, c, defOf, defBlk);
            IROperand* vb = self.vecOperandFor((IROperand*)n.ops().get((u32)1),
                                          fn, entry, B, c, defOf, defBlk);
            IRValue* vr = new IRValue(_vecTy);
            IRInsn* vop = IRInsn.with(self.vecOpFor(op));
            vop.copyDbg(n);
            vop.setRes(vr);
            vop.add(va);
            vop.add(vb);
            _vecBody.add((Object*)vop);
            _vecMap.set((Hashable*)n.res(), (Object*)vr);
            }
        B.setInsns(_vecBody);
        _vecLane = (String*)0;
        _vecTy = self.vecTyOf(c.laneTy(), c.vecBytes());
        if (c.needEpi())
            self.vecMapEpilogue(fn, c, mH2, mB2, mcmap);
        }

    // The lane the next map values are built in (#27): splats and results
    // take it. The loop's own lane leaves _vecLane 0, as before mixing.
    final void vecSetLane(String* lane, VecCand* c)
        {
        if (lane == (String*)0 || !self.vecLaneOK(lane) || lane.equals(c.laneTy()))
            {
            _vecLane = (String*)0;
            _vecTy = self.vecTyOf(c.laneTy(), c.vecBytes());
            return;
            }
        _vecLane = lane;
        _vecTy = self.vecTyOf(lane, c.vecBytes());
        }

    // A constant broadcast in the preheader, once per lane and bits (#27).
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

    final IRValue* vecPutCmp(string pred, String* ty, IRValue* a, IROperand* b, IRInsn* dbg)
        {
        IRValue* r = self.vecPut1("VFCmp", ty, IROperand.useVal(a), b, dbg);
        ((IRInsn*)_vecBody.get(_vecBody.count() - (u32)1)).setPred(String.withCString(pred));
        return r;
        }

    // A conversion between 32-bit integer and float lanes (#27). The back ends
    // convert signed lanes both ways (scvtf/fcvtzs, cvtdq2ps/cvttps2dq); the
    // unsigned forms and xc's rule that an out-of-range float converts to 0
    // (spec 3.1, where the lane instruction saturates or gives 2^31) are
    // built here from lane ops every such back end has:
    //   UIToFp: the high and low 16 bits converted apart, hi * 65536 + lo,
    //           one rounding of an exact sum, as ucvtf rounds;
    //   FpToSI: the result kept where -2^31 <= x < 2^31 (NaN fails both);
    //   FpToUI: x >= 2^31 converts x - 2^31 and sets the top bit back, the
    //           rest converts as signed; kept where -1 < x < 2^32.
    // An unchecked conversion (C's casts) leaves the range test out.
    final void vecApplyConv(IRInsn* n, VecCand* c, IRBlock* entry)
        {
        String* op = n.op();
        IRValue* a = (IRValue*)_vecMap.get((Hashable*)((IROperand*)n.ops().get((u32)0)).val());
        String* rl = n.res().ty();
        String* sl = ((IROperand*)n.ops().get((u32)0)).val().ty();
        String* rty = self.vecTyOf(rl, c.vecBytes());
        String* sty = self.vecTyOf(sl, c.vecBytes());
        bool unchecked = n.pred() != (String*)0 && n.pred().equals(String.withCString("unchecked"));
        IRValue* r = (IRValue*)0;
        if (op.equals(String.withCString("SIToFp")))
            r = self.vecPut1("VSIToFp", rty, IROperand.useVal(a), (IROperand*)0, n);
        else if (op.equals(String.withCString("UIToFp")))
            {
            IRValue* hi = self.vecPut1("VLShr", sty, IROperand.useVal(a), IROperand.immI((i64)16, sl), n);
            IROperand* m16 = self.vecConstSplat(entry, sl, IROperand.immI((i64)65535, sl), c);
            IRValue* lo = self.vecPut1("VAnd", sty, IROperand.useVal(a), m16, n);
            IRValue* fh = self.vecPut1("VSIToFp", rty, IROperand.useVal(hi), (IROperand*)0, n);
            IRValue* fl = self.vecPut1("VSIToFp", rty, IROperand.useVal(lo), (IROperand*)0, n);
            IROperand* k16 = self.vecConstSplat(entry, rl, IROperand.immF(String.withCString("40f0000000000000"), rl), c);
            IRValue* sh = self.vecPut1("VMul", rty, IROperand.useVal(fh), k16, n);
            r = self.vecPut1("VAdd", rty, IROperand.useVal(sh), IROperand.useVal(fl), n);
            }
        else if (op.equals(String.withCString("FpToSI")))
            {
            r = self.vecPut1("VFpToSI", rty, IROperand.useVal(a), (IROperand*)0, n);
            if (!unchecked)
                {
                IROperand* lo = self.vecConstSplat(entry, sl, IROperand.immF(String.withCString("c1e0000000000000"), sl), c);
                IROperand* hi = self.vecConstSplat(entry, sl, IROperand.immF(String.withCString("41e0000000000000"), sl), c);
                IRValue* m1 = self.vecPutCmp("OGE", rty, a, lo, n);
                IRValue* m2 = self.vecPutCmp("OLT", rty, a, hi, n);
                IRValue* m = self.vecPut1("VAnd", rty, IROperand.useVal(m1), IROperand.useVal(m2), n);
                r = self.vecPut1("VAnd", rty, IROperand.useVal(r), IROperand.useVal(m), n);
                }
            }
        else
            {
            IROperand* t31 = self.vecConstSplat(entry, sl, IROperand.immF(String.withCString("41e0000000000000"), sl), c);
            IRValue* lo = self.vecPut1("VFpToSI", rty, IROperand.useVal(a), (IROperand*)0, n);
            IRValue* s = self.vecPut1("VSub", sty, IROperand.useVal(a), t31, n);
            IRValue* h0 = self.vecPut1("VFpToSI", rty, IROperand.useVal(s), (IROperand*)0, n);
            IROperand* top = self.vecConstSplat(entry, rl, IROperand.immI((i64)2147483648, rl), c);
            IRValue* h = self.vecPut1("VXor", rty, IROperand.useVal(h0), top, n);
            IRValue* sel = self.vecPutCmp("OGE", rty, a, t31, n);
            r = self.vecPut1("VBsl", rty, IROperand.useVal(sel), IROperand.useVal(h), n);
            ((IRInsn*)_vecBody.get(_vecBody.count() - (u32)1)).add(IROperand.useVal(lo));
            if (!unchecked)
                {
                IROperand* m1k = self.vecConstSplat(entry, sl, IROperand.immF(String.withCString("bff0000000000000"), sl), c);
                IROperand* t32 = self.vecConstSplat(entry, sl, IROperand.immF(String.withCString("41f0000000000000"), sl), c);
                IRValue* m1 = self.vecPutCmp("OGT", rty, a, m1k, n);
                IRValue* m2 = self.vecPutCmp("OLT", rty, a, t32, n);
                IRValue* m = self.vecPut1("VAnd", rty, IROperand.useVal(m1), IROperand.useVal(m2), n);
                r = self.vecPut1("VAnd", rty, IROperand.useVal(r), IROperand.useVal(m), n);
                }
            }
        _vecMap.set((Hashable*)n.res(), (Object*)r);
        }

    // `acc:u32 += (u32)a[i]` over a u8/u16 array cannot accumulate in narrow
    // lanes — the sum overflows a byte — so the narrow load is vector-loaded,
    // its lanes folded up to u32 by pairwise widening, accumulated in a 4×u32
    // vector and reduced at the exit. Sound because addition mod 2^32 is
    // associative and commutative, so the regrouping matches the scalar
    // wraparound sum exactly.
    final VecCand* vecRecogniseWideningSum(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        Map* uses = self.useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = self.vecWideningAt(fn, (IRBlock*)fn.blocks().get(hi),
                                       defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    // Dot product: `acc += (u32)(a[i]*b[i])` over two u16 arrays. Same shape as
    // the widening sum, but the accumulated element is a product of two
    // iv-indexed narrow loads, multiplied in the NARROW lane so it wraps exactly
    // like the scalar u16*u16 it replaces. Shares the widening lowering with a
    // VMul inserted in front.
    final VecCand* vecRecogniseDotProduct(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        Map* uses = self.useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = self.vecDotAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    // `for (i<N) if (a[i] > m) m = a[i]` lowers to a diamond the if-converter
    // cannot linearise — the then-arm reloads a[i], and it will not speculate a
    // load. So the diamond is recognised directly and replaced with a vector
    // max/min accumulate plus a horizontal reduce.
    final VecCand* vecRecogniseCount(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        Map* uses = self.useCounts(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecCountAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    final VecCand* vecRecogniseMaxMin(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = self.vecMaxMinAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    final VecCand* vecCountAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (vecIsRemainder(H))
            return (VecCand*)0;
        if (H.phis().count() != (u32)2)
            return (VecCand*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != (IRValue*)0)
                return (VecCand*)0;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return (VecCand*)0;
        IROperand* cnd = (IROperand*)term.ops().get((u32)0);
        if (cnd.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* go = defOf.get((Hashable*)cnd.val());
        Object* gb = defBlk.get((Hashable*)cnd.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return (VecCand*)0;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        IRValue* iv = gl.val();

        IRInsn* ivPhi = (IRInsn*)0;
        IRInsn* accPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return (VecCand*)0;
            if (p.res() == iv)
                ivPhi = p;
            else
                accPhi = p;
            }
        if (ivPhi == (IRInsn*)0 || accPhi == (IRInsn*)0)
            return (VecCand*)0;
        IRValue* acc = accPhi.res();
        i32 n = (i32)0;
        if (!self.vecConst((IROperand*)guard.ops().get((u32)1), defOf, &n) || n <= (i32)0)
            return (VecCand*)0;

        IRBlock* L = self.vecCountEdge(fn, accPhi, H, true);
        IRBlock* PH = self.vecCountEdge(fn, accPhi, H, false);
        if (L == (IRBlock*)0 || PH == (IRBlock*)0 || L == H || L == PH)
            return (VecCand*)0;
        if (vecCountEdge(fn, ivPhi, H, true) != L)
            return (VecCand*)0;
        if (L.term() == (IRInsn*)0 || !L.term().op().equals(String.withCString("Branch")) || L.term().ops().count() < (u32)1)
            return (VecCand*)0;
        if (((IROperand*)L.term().ops().get((u32)0)).blk() != H)
            return (VecCand*)0;
        if (L.phis().count() != (u32)0)
            return (VecCand*)0;

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (vecCountLeadsTo(t0, L, H))
            {
            B = t0;
            E = t1;
            }
        else if (vecCountLeadsTo(t1, L, H))
            {
            B = t1;
            E = t0;
            }
        else
            return (VecCand*)0;
        if (E == (IRBlock*)0 || E.phis().count() != (u32)0)
            return (VecCand*)0;

        if (!self.vecCountAcc(accPhi, acc, B, L, defOf, defBlk, uses))
            return (VecCand*)0;

        IRInsn* ivNext = self.vecCountStep(L, iv, defOf);
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = ((IROperand*)ivPhi.ops().get((u32)0)).blk() == L
                                ? (IROperand*)ivPhi.ops().get((u32)1)
                                : (IROperand*)ivPhi.ops().get((u32)3);
        if (ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        Array* elemIds = new Array();
        if (!self.vecCountBody(B, H, L, iv, ivNext, elemIds, defOf, defBlk))
            return (VecCand*)0;
        if (!self.vecCountCmpOK(elemIds, defOf, defBlk, H, B, L))
            return (VecCand*)0;
        if (!self.vecCountClean(fn, H, B, L, acc, iv))
            return (VecCand*)0;

        u32 lw = self.irWidth(_vcLaneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 wvb = self.vectorBytes(); // 16, or 32/64 on an x86-64 clone (bug 644)
        u32 vw = wvb / lw;
        // No epilogue for this shape yet, matching the original: the trip must be
        // a whole number of vectors.
        i32 dpStart = (i32)self.vecIvStart(ivPhi, L, defOf);   // 32-bit path, as before
        if (dpStart < (i32)0 || dpStart >= n)
            return (VecCand*)0;
        if (vw < (u32)2 || (((n - dpStart) % (i32)vw) != (i32)0))
            return (VecCand*)0;

        IROperand* seedOp = ((IROperand*)accPhi.ops().get((u32)0)).blk() == L
                                ? (IROperand*)accPhi.ops().get((u32)3)
                                : (IROperand*)accPhi.ops().get((u32)1);
        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, guard, iv);
        // vw came from the LOAD's width (16 lanes for a byte). When the element
        // is narrower than the count, the accumulator keeps its own width and
        // loadLaneTy records the element's, exactly as the widening sum does.
        if (irWidth(_vcLaneTy) < (u32)4)
            {
            String* accTy = acc.ty();
            if (accTy == (String*)0 || self.irWidth(accTy) != (u32)4)
                return (VecCand*)0;             // only a 32-bit count
            // vecConstWIDE, because dk2 is an i64 and the narrow resolver
            // writes only its low four bytes. The high half then keeps its
            // initialiser instead of the sign, so a NEGATIVE delta came back
            // as a large positive and the `dk2 < 0` guard below could never
            // fire. Nothing diagnosed the i64*/i32* mismatch — that is
            // private:docs/bugs/244, and this is the one live victim of it in
            // the tree, found by auditing for exactly this shape.
            i64 dk2 = (i64)0;
            if (!self.vecConstWide(_vcDelta, defOf, &dk2))
                return (VecCand*)0;
            i64 laneMax = self.irWidth(_vcLaneTy) == (u32)1 ? (i64)255 : (i64)65535;
            if (dk2 < (i64)0 || dk2 > laneMax)
                return (VecCand*)0;             // the delta must fit the lane
            c.setLoadLane(_vcLaneTy);
            c.setLane(accTy, vw);
            }
        else
            c.setLane(_vcLaneTy, vw);
        c.setVecBytes(wvb);
        c.setReduction(accPhi, _vcAccNext, acc, _vcElem, seedOp, PH);
        c.setCount(_vcCmp, _vcDelta, L);
        c.setEpi(false, n);
        return c;
        }

    // Rebuild the body: keep the address/const plumbing, vector-load the element
    // and any elementwise arith, and DROP the scalar compare / increment /
    // Select. The count itself becomes mask-and-add: VICmp gives all-ones in the
    // lanes that match, VAnd with the splatted delta turns each into delta or 0,
    // and VAdd accumulates. No branch, no per-lane select.
    final IRValue* vecCountBodyRewrite(IRFunc* fn, VecCand* c, IRBlock* B, IRBlock* PH,
                                 String* vecTy, IRValue* vacc, Map* defOf, Map* defBlk)
        {
        _vecBody = new Array();
        _vecMap = new Map();
        _vecSplat = new Map();
        _vecSplatBig = false;
        // Its operands are splatted in the body at the ELEMENT's vector type,
        // as the reference's vecOperand (no entry hoist: vecOperandFor gets no
        // entry block); only the compare's constants go to the preheader (its
        // phSplat). _vecTy was the last applier's — a byte loop's Vec(U8) on
        // loop_goal_matmul's word loop, a mask splat of the wrong width.
        _vecSplatPH = (IRBlock*)0;
        _vecTy = vecTy;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == c.cmpInsn())
                continue;
            if (n.op().equals(String.withCString("Select")))
                continue;
            if (n == c.ivNext())
                {
                _vecBody.add((Object*)n);
                continue;
                }
            // the scalar increment feeds only the Select, so it goes too
            if (n.res() != (IRValue*)0 && n.op().equals(String.withCString("Add")) && n.ops().count() >= (u32)2)
                {
                IROperand* a0 = (IROperand*)n.ops().get((u32)0);
                IROperand* a1 = (IROperand*)n.ops().get((u32)1);
                if (a0.kind() == (u8)OPK_USE && a0.val() == c.acc())
                    continue;
                if (a1.kind() == (u8)OPK_USE && a1.val() == c.acc())
                    continue;
                }
            if (n.op().equals(String.withCString("Load")) && n.res() != (IRValue*)0)
                {
                IRValue* vr = new IRValue(vecTy);
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                vl.copyDbg(n);
                vl.setRes(vr);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vl.add((IROperand*)n.ops().get(k));
                vl.setMemRes(n.memRes());
                _vecBody.add((Object*)vl);
                _vecMap.set((Hashable*)n.res(), (Object*)vr);
                continue;
                }
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                {
                _vecBody.add((Object*)n);
                continue;
                }
            if (vecElementwise(op) && n.res() != (IRValue*)0)
                {
                IROperand* va = self.vecOperandFor((IROperand*)n.ops().get((u32)0), fn, (IRBlock*)0, B, c, defOf, defBlk);
                IROperand* vb = self.vecOperandFor((IROperand*)n.ops().get((u32)1), fn, (IRBlock*)0, B, c, defOf, defBlk);
                IRValue* vr = new IRValue(vecTy);
                IRInsn* vi = IRInsn.with(self.vecOpFor(op));
                vi.copyDbg(n);
                vi.setRes(vr);
                vi.add(va);
                vi.add(vb);
                _vecBody.add((Object*)vi);
                _vecMap.set((Hashable*)n.res(), (Object*)vr);
                continue;
                }
            }
        return vacc;
        }

    final void vecApplyCount(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* PH = c.pre();
        IRBlock* L = c.mmLatch();
        // The load, compare and mask run at the ELEMENT's width; the accumulator
        // keeps its own. They are the same unless the element is narrower,
        // which is what loadLaneTy records — so the 32-bit path is unchanged.
        String* elemLane = c.loadLaneTy() != (String*)0 ? c.loadLaneTy() : c.laneTy();
        String* vecTy = self.vecTyOf(elemLane, c.vecBytes());
        String* accVecTy = self.vecTyOf(c.laneTy(), c.vecBytes());

        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }

        IRValue* vacc = new IRValue(accVecTy);
        vecCountBodyRewrite(fn, c, B, PH, vecTy, vacc, defOf, defBlk);

        // mask = VICmp(elem, k); inc = mask AND splat(delta); vacc += inc.
        // The mask is all-ones in the lanes that matched, so the AND turns each
        // into delta or zero and no per-lane branch is needed.
        IRValue* vmask = new IRValue(vecTy);
        IRInsn* vic = IRInsn.with(String.withCString("VICmp"));
        vic.setRes(vmask);
        vic.add(self.vecCountCmpOperand((IROperand*)c.cmpInsn().ops().get((u32)0), PH,
                                   elemLane, vecTy, defOf));
        vic.add(self.vecCountCmpOperand((IROperand*)c.cmpInsn().ops().get((u32)1), PH,
                                   elemLane, vecTy, defOf));
        // The compare's own predicate, as the original does. This used to be
        // deliberately NOT set: XTIRPrinter printed a predicate for ICmp/FCmp
        // only, so VICmp fell to the generic case and the operator never
        // reached the text — setting it here would have diverged from a
        // reference that emitted nothing. That hole is closed (printer and both
        // parsers carry it now), so the predicate travels and the back end can
        // pick its cmhi/cmgt/cmeq instead of refusing VICmp:pred outright.
        vic.setPred(c.cmpInsn().pred());
        _vecBody.add((Object*)vic);

        IRValue* vinc = new IRValue(vecTy);
        IRInsn* va = IRInsn.with(String.withCString("VAnd"));
        va.setRes(vinc);
        va.add(IROperand.useVal(vmask));
        va.add(self.vecCountSplatPH(PH, c.delta(), elemLane, vecTy, defOf));
        _vecBody.add((Object*)va);

        // Climb the masked increments to the accumulator's width with uaddlp —
        // the ladder the widening sum uses. Pairwise summing preserves a total,
        // so folding lanes together does not disturb a count.
        IRValue* curInc = vinc;
        String* curLane = elemLane;
        while (irWidth(curLane) < self.irWidth(c.laneTy()))
            {
            String* nextLane = self.irWidth(curLane) == (u32)1
                                   ? String.withCString("U16")
                                   : String.withCString("U32");
            String* wTy = self.vecTyOf(nextLane, c.vecBytes());
            IRValue* w = new IRValue(wTy);
            IRInsn* wi = IRInsn.with(String.withCString("VAddLP"));
            wi.setRes(w);
            wi.add(IROperand.useVal(curInc));
            _vecBody.add((Object*)wi);
            curInc = w;
            curLane = nextLane;
            }
        IRValue* vnext = new IRValue(accVecTy);
        IRInsn* vad = IRInsn.with(String.withCString("VAdd"));
        vad.setRes(vnext);
        vad.add(IROperand.useVal(vacc));
        vad.add(IROperand.useVal(curInc));
        _vecBody.add((Object*)vad);
        B.setInsns(_vecBody);

        // The induction variable now steps by the vector width.
        for (u32 k = (u32)0; k < c.ivNext().ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)c.ivNext().ops().get(k);
            if (o.kind() == (u8)OPK_IMMI || (o.kind() == (u8)OPK_USE && o.val() != c.iv()))
                c.ivNext().ops().set(k,
                                     (Object*)IROperand.immI((i32)c.vw(), c.ivNext().res().ty()));
            }

        // Zero-seeded vector accumulator; the scalar seed is added back at the
        // exit, where the horizontal reduce lands. The back edge is the LATCH,
        // which is the body only when it was merged.
        self.vecZeroSeedPhi(c, H, L, PH, accVecTy, c.laneTy(), vacc, vnext);
        self.vecReduxExit(fn, c, vacc);
        }

    // Break the serial accumulator dependency: a vectorised reduction loop is
    // unrolled across several independent accumulators (clang does the same), so
    // an out-of-order core can overlap the add chains instead of waiting a full
    // latency per iteration. The copies are combined at the exit with the same
    // op the reduction used, and the existing horizontal reduce then reads the
    // combined vector.
    // A vector loop's lane indices as an induction variable of their own
    // (2026-11-02): VSplat(i), VAdd of the iota, VAdd of any loop invariant,
    // rebuilt every trip, become a phi -- the same chain over i's entry value
    // in the preheader, and one VAdd of splat(step) at the end of the body.
    // call_depth 0.230 -> 0.206 s. A single-block body, a constant step, each
    // link read once. As the reference's vectorIVsInFunction.
    final void vecIVs(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        Map* uses = new Map();      // IRValue -> Number@ count
        Map* useBlk = new Map();    // IRValue -> the block reading it
        Map* manyBlocks = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecIvNote(bb.phis(), bb, defOf, defBlk, uses, useBlk, manyBlocks);
            vecIvNote(bb.insns(), bb, defOf, defBlk, uses, useBlk, manyBlocks);
            if (bb.term() != (IRInsn*)0)
                {
                Array* t = new Array();
                t.add((Object*)bb.term());
                vecIvNote(t, bb, defOf, defBlk, uses, useBlk, manyBlocks);
                }
            }
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            blocks.add(fn.blocks().get(b));
        for (u32 hb = (u32)0; hb < blocks.count(); hb = hb + (u32)1)
            {
            IRBlock* H = (IRBlock*)blocks.get(hb);
            IRInsn* term = H.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
                continue;
            IRBlock* B = (IRBlock*)0;
            for (u32 k = (u32)1; k < (u32)3 && B == (IRBlock*)0; k = k + (u32)1)
                {
                IRBlock* c = ((IROperand*)term.ops().get(k)).blk();
                if (c == (IRBlock*)0 || c == H || c.term() == (IRInsn*)0)
                    continue;
                IRInsn* ct = c.term();
                if (ct.op().equals(String.withCString("Branch")) && ct.ops().count() >= (u32)1
                    && ((IROperand*)ct.ops().get((u32)0)).blk() == H)
                    B = c;
                }
            // Not a big body: the phi and its step splat stay live through it
            // (vec_interleave ran out of arm64's pool). As the reference.
            if (B == (IRBlock*)0 || B.insns().count() > (u32)VEC_SPLAT_BIG_BODY)
                continue;
            Array* phis = new Array();
            for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
                phis.add(H.phis().get(i));
            for (u32 pi = (u32)0; pi < phis.count(); pi = pi + (u32)1)
                {
                IRInsn* ivPhi = (IRInsn*)phis.get(pi);
                if (ivPhi.res() == (IRValue*)0 || ivPhi.ops().count() != (u32)4 || !isIntType(ivPhi.res().ty()))
                    continue;
                u32 bi = (u32)9;
                if (((IROperand*)ivPhi.ops().get((u32)0)).blk() == B)
                    bi = (u32)0;
                else if (((IROperand*)ivPhi.ops().get((u32)2)).blk() == B)
                    bi = (u32)2;
                if (bi == (u32)9)
                    continue;
                IRBlock* PH = ((IROperand*)ivPhi.ops().get((u32)2 - bi)).blk();
                IROperand* initOp = (IROperand*)ivPhi.ops().get((u32)3 - bi);
                IROperand* nextOp = (IROperand*)ivPhi.ops().get(bi + (u32)1);
                if (PH == (IRBlock*)0 || PH == B || PH == H || nextOp.kind() != (u8)OPK_USE)
                    continue;
                Object* nxo = defOf.get((Hashable*)nextOp.val());
                if (nxo == (Object*)0 || (IRBlock*)defBlk.get((Hashable*)nextOp.val()) != B)
                    continue;
                IRInsn* nx = (IRInsn*)nxo;
                if (!nx.op().equals(String.withCString("Add")) || nx.ops().count() != (u32)2)
                    continue;
                IROperand* n0 = (IROperand*)nx.ops().get((u32)0);
                IROperand* n1 = (IROperand*)nx.ops().get((u32)1);
                IROperand* stepOp = (IROperand*)0;
                if (n0.kind() == (u8)OPK_USE && n0.val() == ivPhi.res())
                    stepOp = n1;
                else if (n1.kind() == (u8)OPK_USE && n1.val() == ivPhi.res())
                    stepOp = n0;
                if (stepOp == (IROperand*)0 || stepOp.kind() != (u8)OPK_IMMI)
                    continue;
                i64 step = stepOp.imm();
                Array* body = new Array();
                for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                    body.add(B.insns().get(i));
                for (u32 si = (u32)0; si < body.count(); si = si + (u32)1)
                    {
                    IRInsn* sp = (IRInsn*)body.get(si);
                    if (!sp.op().equals(String.withCString("VSplat")) || sp.res() == (IRValue*)0 || sp.ops().count() < (u32)1)
                        continue;
                    IROperand* s0op = (IROperand*)sp.ops().get((u32)0);
                    if (s0op.kind() != (u8)OPK_USE || s0op.val() != ivPhi.res())
                        continue;
                    Array* chain = new Array();
                    chain.add((Object*)sp);
                    Array* bodySplats = new Array();
                    IRInsn* cur = sp;
                    while (vecIvCount(uses, cur.res()) == (u32)1)
                        {
                        IRInsn* nextL = (IRInsn*)0;
                        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                            {
                            IRInsn* u = (IRInsn*)B.insns().get(i);
                            for (u32 k = (u32)0; k < u.ops().count(); k = k + (u32)1)
                                {
                                IROperand* o = (IROperand*)u.ops().get(k);
                                if (o.kind() == (u8)OPK_USE && o.val() == cur.res())
                                    nextL = u;
                                }
                            }
                        if (nextL == (IRInsn*)0 || !nextL.op().equals(String.withCString("VAdd")) || nextL.res() == (IRValue*)0
                            || nextL.ops().count() != (u32)2)
                            break;
                        IROperand* a0 = (IROperand*)nextL.ops().get((u32)0);
                        IROperand* other = (a0.kind() == (u8)OPK_USE && a0.val() == cur.res())
                                               ? (IROperand*)nextL.ops().get((u32)1) : a0;
                        if (other.kind() != (u8)OPK_USE)
                            break;
                        IRBlock* ob = (IRBlock*)defBlk.get((Hashable*)other.val());
                        if (ob == H)
                            break;
                        if (ob == B)
                            {
                            // A splat of an invariant still in the body: the
                            // preheader makes its own. As the reference.
                            IRInsn* od = (IRInsn*)defOf.get((Hashable*)other.val());
                            if (od == (IRInsn*)0 || !od.op().equals(String.withCString("VSplat")) || od.ops().count() < (u32)1
                                || vecIvCount(uses, other.val()) != (u32)1)
                                break;
                            IROperand* so = (IROperand*)od.ops().get((u32)0);
                            IRBlock* sb = so.kind() == (u8)OPK_USE ? (IRBlock*)defBlk.get((Hashable*)so.val()) : (IRBlock*)0;
                            if (!(so.kind() == (u8)OPK_IMMI || (so.kind() == (u8)OPK_USE && (sb == (IRBlock*)0 || (sb != H && sb != B)))))
                                break;
                            bodySplats.add((Object*)od);
                            }
                        chain.add((Object*)nextL);
                        cur = nextL;
                        }
                    if (manyBlocks.get((Hashable*)cur.res()) != (Object*)0)
                        continue;
                    Object* ubo = useBlk.get((Hashable*)cur.res());
                    if (ubo != (Object*)0 && (IRBlock*)ubo != B)
                        continue;
                    String* vt = cur.res().ty();
                    String* lane = vuLaneOf(vt);
                    if (lane == (String*)0)
                        continue;
                    IRValue* s0 = new IRValue(sp.res().ty());
                    IRInsn* i0 = IRInsn.with(String.withCString("VSplat"));
                    i0.setRes(s0);
                    i0.add(initOp);
                    PH.insns().add((Object*)i0);
                    IRValue* acc = s0;
                    for (u32 q = (u32)1; q < chain.count(); q = q + (u32)1)
                        {
                        IRInsn* L = (IRInsn*)chain.get(q);
                        IRInsn* prevL = (IRInsn*)chain.get(q - (u32)1);
                        IROperand* l0 = (IROperand*)L.ops().get((u32)0);
                        bool left = l0.kind() == (u8)OPK_USE && l0.val() == prevL.res();
                        IROperand* other = left ? (IROperand*)L.ops().get((u32)1) : l0;
                        Object* odo = defOf.get((Hashable*)other.val());
                        if (odo != (Object*)0 && hasInsn(bodySplats, (IRInsn*)odo))
                            {
                            IRInsn* od = (IRInsn*)odo;
                            IRValue* cs = new IRValue(od.res().ty());
                            IRInsn* ic = IRInsn.with(String.withCString("VSplat"));
                            ic.setRes(cs);
                            ic.add((IROperand*)od.ops().get((u32)0));
                            PH.insns().add((Object*)ic);
                            other = IROperand.useVal(cs);
                            }
                        IRValue* nv = new IRValue(L.res().ty());
                        IRInsn* ia = IRInsn.with(String.withCString("VAdd"));
                        ia.setRes(nv);
                        if (left)
                            {
                            ia.add(IROperand.useVal(acc));
                            ia.add(other);
                            }
                        else
                            {
                            ia.add(other);
                            ia.add(IROperand.useVal(acc));
                            }
                        PH.insns().add((Object*)ia);
                        acc = nv;
                        }
                    IRValue* kc = new IRValue(lane);
                    IRInsn* ik = IRInsn.with(String.withCString("Const"));
                    ik.setRes(kc);
                    ik.add(IROperand.immI(step, lane));
                    PH.insns().add((Object*)ik);
                    IRValue* ks = new IRValue(vt);
                    IRInsn* isp = IRInsn.with(String.withCString("VSplat"));
                    isp.setRes(ks);
                    isp.add(IROperand.useVal(kc));
                    PH.insns().add((Object*)isp);
                    IRValue* pv = new IRValue(vt);
                    IRValue* pn = new IRValue(vt);
                    IRInsn* phi = IRInsn.with(String.withCString("Phi"));
                    phi.setRes(pv);
                    if (bi == (u32)0)
                        {
                        phi.add(IROperand.block(B));
                        phi.add(IROperand.useVal(pn));
                        phi.add(IROperand.block(PH));
                        phi.add(IROperand.useVal(acc));
                        }
                    else
                        {
                        phi.add(IROperand.block(PH));
                        phi.add(IROperand.useVal(acc));
                        phi.add(IROperand.block(B));
                        phi.add(IROperand.useVal(pn));
                        }
                    H.phis().add((Object*)phi);
                    IRInsn* st = IRInsn.with(String.withCString("VAdd"));
                    st.setRes(pn);
                    st.add(IROperand.useVal(pv));
                    st.add(IROperand.useVal(ks));
                    B.insns().add((Object*)st);
                    for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                        {
                        IRInsn* u = (IRInsn*)B.insns().get(i);
                        for (u32 k = (u32)0; k < u.ops().count(); k = k + (u32)1)
                            {
                            IROperand* o = (IROperand*)u.ops().get(k);
                            if (o.kind() == (u8)OPK_USE && o.val() == cur.res())
                                u.ops().set(k, (Object*)IROperand.useVal(pv));
                            }
                        }
                    Array* kept = new Array();
                    for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                        {
                        IRInsn* u = (IRInsn*)B.insns().get(i);
                        if (!hasInsn(chain, u) && !hasInsn(bodySplats, u))
                            kept.add((Object*)u);
                        }
                    B.setInsns(kept);
                    }
                }
            }
        }

    final void vecIvNote(Array* list, IRBlock* bb, Map* defOf, Map* defBlk, Map* uses, Map* useBlk, Map* manyBlocks)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() != (IRValue*)0)
                {
                defOf.set((Hashable*)n.res(), (Object*)n);
                defBlk.set((Hashable*)n.res(), (Object*)bb);
                }
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                uses.set((Hashable*)o.val(), (Object*)Number.with(vecIvCount(uses, o.val()) + (u32)1));
                Object* ub = useBlk.get((Hashable*)o.val());
                if (ub != (Object*)0 && (IRBlock*)ub != bb)
                    manyBlocks.set((Hashable*)o.val(), (Object*)o.val());
                useBlk.set((Hashable*)o.val(), (Object*)bb);
                }
            }
        }

    static u32 vecIvCount(Map* uses, IRValue* v)
        {
        Object* c = uses.get((Hashable*)v);
        return c == (Object*)0 ? (u32)0 : ((Number*)c).asU32();
        }

    final void vecUnrollReductions(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            vecUnrollAt(fn, (IRBlock*)fn.blocks().get(hi));
        }

    final void vecUnrollAt(IRFunc* fn, IRBlock* H)
        {
        if (vecIsRemainder(H))
            return;
        if (H.phis().count() != (u32)2)
            return;
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }

        IRInsn* vaccPhi = (IRInsn*)0;
        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.ops().count() != (u32)4)
                return;
            if (isVectorType(p.res().ty()))
                vaccPhi = p;
            else
                ivPhi = p;
            }
        if (vaccPhi == (IRInsn*)0 || ivPhi == (IRInsn*)0)
            return;
        IRValue* vacc = vaccPhi.res();
        IRValue* iv = ivPhi.res();
        String* vecTy = vacc.ty();

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return;
        Object* go = defOf.get((Hashable*)c0.val());
        if (go == (Object*)0)
            return;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE || gl.val() != iv)
            return;
        // WIDE, for the same reason the recogniser is: a u32 bound above 2^31
        // truncated into an i32 reads as negative, and this guard then takes it
        // for an empty loop and skips the unroll. That left the vector body
        // un-unrolled where the reference unrolled it — 28 NEON instructions
        // against 100 on call_depth, with the loop correctly vectorised either
        // way, which is why it looked like a missing transform rather than a
        // truncated constant.
        i64 n = (i64)0;
        // The bound may be a literal, or the runtime limit M = n & ~(vw-1) the
        // vectoriser builds for a runtime trip count. Both are unrollable; which
        // one it is decides how U is chosen, below.
        bool constN = self.vecConstWide((IROperand*)guard.ops().get((u32)1), defOf, &n);
        if (constN && n <= (i64)0)
            return;

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = self.rotIsLatch(t0, H) ? t0 : (self.rotIsLatch(t1, H) ? t1 : (IRBlock*)0);
        if (B == (IRBlock*)0)
            return;
        IRBlock* E = (B == t0) ? t1 : t0;
        if (E == (IRBlock*)0)
            return;
        // A large body (MD5's rounds) gets two copies, not four, and those
        // INTERLEAVED (each clone straight after its original): the body is
        // one long dependency chain, and the second copy's is independent, so
        // the core runs both at once. Only where the two copies' vectors fit
        // the back end's pool (vecInterleaveFits); four would hold four sets.
        bool bigBody = B.insns().count() > (u32)VEC_SPLAT_BIG_BODY;

        // vnext = Vop(vacc, X) and ivNext = Add(iv, vw), both in the body.
        IROperand* vnextOp = self.vecBackOp(vaccPhi, B);
        IROperand* ivNextOp = self.vecBackOp(ivPhi, B);
        if (vnextOp == (IROperand*)0 || ivNextOp == (IROperand*)0)
            return;
        if (vnextOp.kind() != (u8)OPK_USE || ivNextOp.kind() != (u8)OPK_USE)
            return;
        Object* vno = defOf.get((Hashable*)vnextOp.val());
        Object* vnb = defBlk.get((Hashable*)vnextOp.val());
        Object* ino = defOf.get((Hashable*)ivNextOp.val());
        Object* inb = defBlk.get((Hashable*)ivNextOp.val());
        if (vno == (Object*)0 || vnb == (Object*)0 || (IRBlock*)vnb != B)
            return;
        if (ino == (Object*)0 || inb == (Object*)0 || (IRBlock*)inb != B)
            return;
        IRInsn* vnextInsn = (IRInsn*)vno;
        IRInsn* ivNextInsn = (IRInsn*)ino;
        if (!ivNextInsn.op().equals(String.withCString("Add")))
            return;
        if (!vnextInsn.op().equals(String.withCString("VAdd")) && !vnextInsn.op().equals(String.withCString("VMax")) && !vnextInsn.op().equals(String.withCString("VMin")))
            return;
        if (vnextInsn.ops().count() < (u32)2)
            return;
        IROperand* w0 = (IROperand*)vnextInsn.ops().get((u32)0);
        IROperand* w1 = (IROperand*)vnextInsn.ops().get((u32)1);
        if (w0.kind() != (u8)OPK_USE || w1.kind() != (u8)OPK_USE)
            return;
        if (w0.val() != vacc && w1.val() != vacc)
            return;
        IROperand* i0 = (IROperand*)ivNextInsn.ops().get((u32)0);
        IROperand* i1 = (IROperand*)ivNextInsn.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (i0.kind() == (u8)OPK_USE && i0.val() == iv)
            stepOp = i1;
        else if (i1.kind() == (u8)OPK_USE && i1.val() == iv)
            stepOp = i0;
        i32 vw = (i32)0;
        if (stepOp == (IROperand*)0 || !self.vecConst(stepOp, defOf, &vw) || vw < (i32)2)
            return;

        // The preheader's lane init is a VSplat we replicate per copy.
        IRBlock* PH = self.vecEntryBlkOf(vaccPhi, B);
        IROperand* initOp = self.vecEntryOpOf(vaccPhi, B);
        if (PH == (IRBlock*)0 || initOp.kind() != (u8)OPK_USE)
            return;
        Object* io = defOf.get((Hashable*)initOp.val());
        Object* ib = defBlk.get((Hashable*)initOp.val());
        if (io == (Object*)0 || ib == (Object*)0 || (IRBlock*)ib != PH)
            return;
        IRInsn* initInsn = (IRInsn*)io;
        if (!initInsn.op().equals(String.withCString("VSplat")))
            return;

        // As many copies as the trip count divides evenly by.
        u32 U = (u32)1;
        if (constN)
            {
            // The TRIP, n - s, decides how many copies divide it evenly, not
            // the bound n: the iv runs from its start s. From 4 to 64 the bound
            // is a multiple of 16 and the trip, 60, is not, so four copies ran
            // 4 elements past the end. A start that is not a constant is not
            // unrolled. As the reference.
            i64 s0 = (i64)0;
            if (!self.vecConstWide(vecEntryOpOf(ivPhi, B), defOf, &s0))
                return;
            i64 trip = n - s0;
            U = (!bigBody && (trip % ((i64)4 * (i64)vw)) == (i64)0) ? (u32)4
                                              : ((trip % ((i64)2 * (i64)vw)) == (i64)0 ? (u32)2 : (u32)1);
            }
        else
            {
            IRInsn* mask = self.vecRuntimeMask(guard, defOf, vw);
            if (mask == (IRInsn*)0)
                return;
            U = bigBody ? (u32)2 : (u32)4;
            if (bigBody)
                self.vecRematLanes(fn, B, defBlk);
            if (bigBody && !self.vecInterleaveFits(fn, B, vacc, iv, ivNextInsn, self.vecPoolForTy(fn, vecTy)))
                return;
            mask.ops().set((u32)1,
                           (Object*)IROperand.immI((i64) ~((i32)(U * vw) - (i32)1), mask.res().ty()));
            }
        if (U < (u32)2)
            return;
        if (bigBody && constN)
            self.vecRematLanes(fn, B, defBlk);
        if (bigBody && constN && !self.vecInterleaveFits(fn, B, vacc, iv, ivNextInsn, self.vecPoolForTy(fn, vecTy)))
            return;

        self.vecUnrollApply(fn, H, B, E, PH, iv, vacc, vecTy, ivNextInsn, vnextInsn,
                       initInsn, vw, U, bigBody);
        }

    final void vecApplyReduction(IRFunc* fn, VecCand* c)
        {
        _vecFn = fn;
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* E = c.e();
        IRBlock* PH = c.pre();
        _vecTy = new String();
        _vecTy = self.vecTyOf(c.laneTy(), c.vecBytes());
        _vecMap = new Map();
        _vecSplat = new Map();
        _vecSplatBig = false;
        _vecBody = new Array();
        _vecH2 = (IRBlock*)0;
        _vecB2 = (IRBlock*)0;
        _vecCmap = (Map*)0;
        _vecPH = (IRBlock*)0;

        // Epilogue part 1: clone the scalar loop BEFORE vecReduxBody rewrites B
        // in place. The remainder has to be taken now or not at all.
        IRBlock* H2 = (IRBlock*)0;
        IRBlock* B2 = (IRBlock*)0;
        Map* cmap = new Map();
        if (c.needEpi())
            {
            Array* cl = self.vecCloneLoop(fn, H, B, cmap);
            H2 = (IRBlock*)cl.get((u32)0);
            _vecRemainders.set((Hashable*)H2, (Object*)H2);
            B2 = (IRBlock*)cl.get((u32)1);
            _vecH2 = H2;
            _vecB2 = B2;
            _vecCmap = cmap;
            _vecPH = PH;
            // The vector loop now stops at the last whole vector; the clone's
            // own (cloned) guard still tests the original bound.
            if (c.rtTrip())
                {
                _vecRtM = self.vecRuntimeLimit(c, PH);
                c.guard().ops().set((u32)1, (Object*)IROperand.useVal(_vecRtM));
                }
            else
                {
                _vecRtM = (IRValue*)0;
                c.guard().ops().set((u32)1,
                                    (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
                }
            }

        // Arm the preheader splat for loop-INVARIANT constants (see
        // vecSplatConst): the same vector on every iteration belongs on loop
        // entry, not in the body.
        _vecSplatPH = c.pre();
        _vecSplatK = new Map();
        _vecSplatTy = c.laneTy();
        // A large body (MD5's 64 rounds) holds no constant splats in
        // registers across the loop: it needs them for its own values.
        _vecSplatBig = c.b().insns().count() > (u32)VEC_SPLAT_BIG_BODY;
        _vecSplatDefs = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    _vecSplatDefs.set((Hashable*)n.res(), (Object*)n);
                }
            }

        // An ordered sum keeps its scalar accumulator: the body adds each
        // vector's lanes to it, and nothing is reduced at the exit.
        if (c.ordered())
            {
            self.vecReduxBody(c, B, (IRValue*)0);
            _vecSplatPH = (IRBlock*)0;
            self.vecOrderedExit(fn, c);
            return;
            }
        // The vector accumulator, needed by name before the body's VAdd is built.
        IRValue* vacc = new IRValue(_vecTy);
        self.vecReduxBody(c, B, vacc);
        // Disarmed once the body is built: a later loop's rewriter that does
        // not arm it (the count reduction) must not splat into this loop's
        // preheader at this loop's lane type (loop_goal_matmul: a Vec(U8)
        // splat of a U32 mask, a byte loop's type on a word loop).
        _vecSplatPH = (IRBlock*)0;
        Object* vnObj = _vecMap.get((Hashable*)c.accNext().res());
        if (vnObj == (Object*)0)
            return;
        IRValue* vnext = (IRValue*)vnObj;

        // Zeroed lanes in the preheader. vacc / vacc0 / vnext coalesce onto one
        // vector register in the backend (associative in-place accumulate), so
        // the back edge needs no copy.
        IRValue* vacc0 = new IRValue(_vecTy);
        IRValue* zero = new IRValue(c.laneTy());
        IRInsn* zc = IRInsn.with(String.withCString("Const"));
        zc.setRes(zero);
        zc.add(IROperand.immI((i32)0, c.laneTy()));
        IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
        sp.setRes(vacc0);
        sp.add(IROperand.useVal(zero));
        PH.insns().add((Object*)zc);
        PH.insns().add((Object*)sp);

        IRInsn* vphi = IRInsn.with(String.withCString("Phi"));
        vphi.setRes(vacc);
        vphi.add(IROperand.block(PH));
        vphi.add(IROperand.useVal(vacc0));
        vphi.add(IROperand.block(B));
        vphi.add(IROperand.useVal(vnext));
        Array* newPhis = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            if ((IRInsn*)H.phis().get(i) != c.accPhi())
                newPhis.add(H.phis().get(i));
        newPhis.add((Object*)vphi);
        H.setPhis(newPhis);

        self.vecReduxExit(fn, c, vacc);
        }
    }
