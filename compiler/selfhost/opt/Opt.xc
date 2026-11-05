// Opt.xc — the IR optimiser, ported: the pipeline and the passes it runs.
// =========================================================================
//
// The optimiser is one class, Opt, in layers (2026-11-01: one file of 31,000
// lines made the split build wait ten minutes on its one object):
//
//   OptBase.xc            class Opt: every field, the target profile, and
//                         the helpers many passes share
//   OptVectorize{Parts,Shapes,Rewrite}.xc
//                         the vectoriser, which most loop passes build on,
//                         in three layers
//   Opt<Pass>.xc          a category per pass, named for its reference file
//                         (src/xtc/ir/XTIROpt<Pass>.m)
//   Opt.xc                this file: the pipeline, importing every pass, so
//                         importing Opt still sees all of it
//
// A file imports only what it calls, and the imports have no cycles (the
// split build refuses one). A helper a second pass needs moves down, into
// OptBase.xc or the vectoriser's layers; every field is declared in
// OptBase.xc, whichever pass owns it.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptAggExpand>
#import <OptVaArgExpand>
#import <OptArcSelfRetain>
#import <OptMem2Reg>
#import <OptBlockLayout>
#import <OptBlockMerge>
#import <OptDeadCode>
#import <OptReassociate>
#import <OptRedundantLoadCSE>
#import <OptVectorizeParts>
#import <OptBoundsElide>
#import <OptConstHoist>
#import <OptFpContract>
#import <OptGpuGlobals>
#import <OptIdiomMatMul>
#import <OptIdiomMemset>
#import <OptInline>
#import <OptLICM>
#import <OptLoopReductionCollapse>
#import <OptLoopRotate>
#import <OptLoopUnroll>
#import <OptLoopClone>
#import <OptLoopUnrollVarTrip>
#import <OptNarrow>
#import <OptStrengthReduce>
#import <OptNarrowIV>
#import <OptVectorizeShapes>
#import <OptVectorizeRewrite>
#import <OptOuterVectorize>
#import <OptOutline>
#import <OptParPropose>
#import <OptPointerIV>
#import <OptPowSquare>
#import <OptSimdClone>
#import <OptSimplify>
#import <OptSqrtIntrinsic>
#import <OptStaticInitGuard>
#import <OptTailRecursion>
#import <OptVecCombine>

    class Opt (Pipeline)
    {

    final void init(void)
        {
        _vecFnBytes = (u32)0;
        _level = (u32)0;
        _failed = false;
        _inlineChecks = false;
        }

    final void setStopAfter(String* n)
        {
        _stopAfter = n;
        }
    final void setKeepClassRoot(bool on)
        {
        _keepClassRoot = on;
        }
    final void setKeepAllFunctions(bool on)
        {
        _keepAllFunctions = on;
        }

    // True when the pipeline should stop here — the caller returns.
    final bool stopHere(String* passName)
        {
        // Every name the pipeline offers is collected as it goes, so the guard
        // below needs no second copy of the pass list to check a typo against —
        // a list that would drift the moment a pass is added or renamed.
        if (_seen == (Array*)0)
            _seen = new Array();
        _seen.add((Object*)passName);
        return _stopAfter != 0 && _stopAfter.equals(passName);
        }

    // A NAME THAT MATCHES NOTHING is refused, not ignored. run() returns the
    // moment a name matches, so reaching the end with _stopAfter still set
    // means it never did. A typo used to run the whole pipeline and look
    // exactly like a clean stop, so a bisection over pass names compared the
    // full build against itself at every point — which reads as "the fault is
    // before the first pass". Mirrors the reference. private:docs/bugs/237.
    final void refuseUnknownStop(void)
        {
        if (_stopAfter == 0)
            return;
        String* msg = String.withCString("xcc: XTIR_OPT_STOP_AFTER names no pass: '");
        msg.append(_stopAfter);
        msg.appendCString("'\n  the pipeline has: ");
        for (u32 i = (u32)0; _seen != (Array*)0 && i < _seen.count(); i = i + (u32)1)
            {
            msg.append((String*)_seen.get(i));
            msg.appendCString(" ");
            }
        msg.appendCString("\n");
        Stdio.error(msg);
        Process.exit((i32)2);
        }

    // `-Flu <n>` overrides the per-target unroll cap. A driver flag has to be
    // able to reach the profile, and the profile is chosen per target — so the
    // override is applied AFTER the target's defaults, or the target would win.
    static void setUnrollOverride(OptProfile* p, i32 n)
        {
        if (p == 0 || n < (i32)0)
            return;
        p._unrollMaxTrip = (u32)n;
        }

    // `-Fli <n>` replaces the inliner's size ceiling, and `-fdce-trace` asks
    // dead-function elimination to name what it removes. Applied to the
    // target's profile after its defaults, as the unroll override is.
    static void setInlineOverride(OptProfile* p, i32 n)
        {
        if (p == 0 || n < (i32)0)
            return;
        p._inlineMax = (u32)n;
        }
    static void setDceTrace(OptProfile* p, bool on)
        {
        if (p != 0)
            p._dceTrace = on;
        }

    static Opt* atLevel(u32 level, OptProfile* profile)
        {
        Opt* o = new Opt();
        o._level = level;
        o._profile = profile;
        // XTIR_OPT_STOP_AFTER, read HERE rather than at each of the eight
        // construction sites, so every caller gets it and the next one cannot
        // forget. Only the opt-diff harness used to set it, so a compiler run
        // from an INSTALL honoured it nowhere: bisecting an optimiser bug
        // against a release produced a table of stop points that were all the
        // full pipeline, which reads like "the fault is before the first pass"
        // and is worth nothing. docs/bugs/237.
        u8* sa = optGetenv("XTIR_OPT_STOP_AFTER");
        if (sa != (u8*)0 && sa[0] != (u8)0)
            o._stopAfter = String.withCString(sa);
        return o;
        }

    // The passes a par block's GPU kernel gets before it is printed (the
    // reference: XTIRParCheck kernelModuleFrom, bug 645), in its order.
    final void parKernels(IRModule* m)
        {
        // A sqrt call becomes the pure FSqrt first, as the main pipeline does
        // before it inlines: a call writes memory as far as licm knows, so a
        // kernel calling Math.sqrt kept every load in its loops (nbody's px[i]
        // reloaded per inner iteration on the GPU, issue #7).
        self.sqrtIntrinsic(m);
        self.inlineLeaves(m);
        if (_failed) return;
        // An inlined Math.sqrt brings its class's init guard into the loop,
        // a Call that kept every load there and the body two blocks. A kernel
        // never runs an initialiser (the printers skip those calls), so every
        // guard folds (the reference's foldAll explains).
        _sgFoldAll = true;
        self.staticInitGuard(m);
        _sgFoldAll = false;
        _cseCrossBlock = true;
        self.redundantLoadCSE(m);
        _cseCrossBlock = false;
        self.ifConvert(m);
        self.jumpThread(m);
        self.deadCode(m);
        self.strengthReduce(m);
        self.constOperandFold(m);
        self.redundantLoadCSE(m);
        self.licm(m);
        _cseCrossBlock = true;
        _cseLate = true;
        self.redundantLoadCSE(m);
        _cseCrossBlock = false;
        _cseLate = false;
        self.blockMerge(m);
        gpuEscapeTrips(m);
        // A counted inner loop whose constant trip is a whole number of
        // groups of four runs as four copies per back edge (issue #7): no
        // copy needs a guard, and a GPU pays for guards more than for the back
        // edge they save. Before loopRotate, whose shape it does not take.
        _vtExactOnly = true;
        self.loopUnrollVarTrip(m);
        _vtExactOnly = false;
        // The copies are a chain of blocks; one block again, so the rotate
        // below takes the loop.
        self.blockMerge(m);
        self.loopRotate(m);
        self.deadCode(m);
        }

    // Several trips of a GPU kernel's `while` per exit test (2026-11-01). A
    // GPU runs a group of lanes in step, and a loop whose lanes leave at
    // different trips (mandelbrot's escape test) pays for its per-lane control
    // on every trip: on the Pi 5's V3D some 25 of 33 instruction slots a trip.
    // Here the body is followed by trips-1 more trips, each the test and the
    // body over the values so far, a lane whose test fails keeping its values
    // by a select: the loop then tests once per `trips` trips and every lane
    // ends with exactly the values the plain loop gives it. Only a loop of one
    // test block (phis and pure work) and one body block, with no memory
    // access or call in either: a lane that has left still runs the copies.
    // The kernel copy only. XTGPU_ESC_TRIPS=<n> sets the trips (1: off). As
    // the reference's XTIROptGpuEscapeTrips.
    static bool escTripsPure(IRInsn* i)
        {
        if (i.memRes() != (IRValue*)0)
            return false;
        String* o = i.op();
        return o.equals(String.withCString("Const")) || o.equals(String.withCString("Copy")) || o.equals(String.withCString("Add"))
            || o.equals(String.withCString("Sub")) || o.equals(String.withCString("Mul")) || o.equals(String.withCString("Neg"))
            || o.equals(String.withCString("And")) || o.equals(String.withCString("Or")) || o.equals(String.withCString("Xor"))
            || o.equals(String.withCString("Not")) || o.equals(String.withCString("Shl")) || o.equals(String.withCString("LShr"))
            || o.equals(String.withCString("AShr")) || o.equals(String.withCString("FAdd")) || o.equals(String.withCString("FSub"))
            || o.equals(String.withCString("FMul")) || o.equals(String.withCString("FNeg")) || o.equals(String.withCString("ICmp"))
            || o.equals(String.withCString("FCmp")) || o.equals(String.withCString("Select")) || o.equals(String.withCString("SExt"))
            || o.equals(String.withCString("ZExt")) || o.equals(String.withCString("Trunc")) || o.equals(String.withCString("Bitcast"))
            || o.equals(String.withCString("FpToSI")) || o.equals(String.withCString("FpToUI")) || o.equals(String.withCString("SIToFp"))
            || o.equals(String.withCString("UIToFp")) || o.equals(String.withCString("FpExt")) || o.equals(String.withCString("FpTrunc"));
        }

    static IROperand* escTripsMap(IROperand* o, Map* m)
        {
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* v = m.get((Hashable*)o.val());
        return v == (Object*)0 ? o : IROperand.useVal((IRValue*)v);
        }

    static void escTripsClone(IRInsn* i, IRBlock* B, Map* m)
        {
        IRInsn* c = IRInsn.with(i.op());
        c.copyDbg(i);
        c.setPred(i.pred());
        for (u32 k = (u32)0; k < i.ops().count(); k = k + (u32)1)
            c.add(escTripsMap((IROperand*)i.ops().get(k), m));
        if (i.res() != (IRValue*)0)
            {
            c.setRes(new IRValue(i.res().ty()));
            m.set((Hashable*)i.res(), (Object*)c.res());
            }
        B.insns().add((Object*)c);
        }
    final void setEscTrips(u32 n)
        {
        _escTrips = n;
        }
    final Array* escChanged(void)
        {
        return _escChanged == (Array*)0 ? new Array() : _escChanged;
        }

    final void gpuEscapeTrips(IRModule* mod)
        {
        i64 trips = (i64)_escTrips;
        if (trips < (i64)2)
            return;
        if (_escChanged == (Array*)0)
            _escChanged = new Array();
        for (u32 fi = (u32)0; fi < mod.funcs().count(); fi = fi + (u32)1)
            {
            IRFunc* fn = (IRFunc*)mod.funcs().get(fi);
            for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
                {
                IRBlock* H = (IRBlock*)fn.blocks().get(hi);
                IRInsn* t = H.term();
                if (H.phis().count() == (u32)0 || t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch"))
                    || t.ops().count() < (u32)3)
                    continue;
                IRBlock* B = (IRBlock*)0;
                for (u32 k = (u32)1; k <= (u32)2; k = k + (u32)1)
                    {
                    IRBlock* c = ((IROperand*)t.ops().get(k)).blk();
                    if (c != (IRBlock*)0 && c != H && c.phis().count() == (u32)0 && c.term() != (IRInsn*)0
                        && c.term().op().equals(String.withCString("Branch")) && c.term().ops().count() >= (u32)1
                        && ((IROperand*)c.term().ops().get((u32)0)).blk() == H)
                        B = c;
                    }
                if (B == (IRBlock*)0 || ((IROperand*)t.ops().get((u32)1)).blk() == ((IROperand*)t.ops().get((u32)2)).blk())
                    continue;
                // B has H alone before it.
                u32 toB = (u32)0;
                for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
                    {
                    IRInsn* bt = ((IRBlock*)fn.blocks().get(bi)).term();
                    for (u32 k = (u32)0; bt != (IRInsn*)0 && k < bt.ops().count(); k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)bt.ops().get(k);
                        if (o.kind() == (u8)OPK_BLOCK && o.blk() == B)
                            toB = toB + (u32)1;
                        }
                    }
                bool ok = toB == (u32)1 && H.insns().count() + B.insns().count() <= (u32)64;
                Array* back = new Array();
                for (u32 q = (u32)0; ok && q < H.phis().count(); q = q + (u32)1)
                    {
                    IRInsn* p = (IRInsn*)H.phis().get(q);
                    if (p.res() == (IRValue*)0 || p.ops().count() != (u32)4 || p.res().ty().equals(String.withCString("Mem"))
                        || p.res().ty().hasPrefix(String.withCString("Ptr")))
                        {
                        ok = false;
                        continue;
                        }
                    IROperand* bv = ((IROperand*)p.ops().get((u32)0)).blk() == B ? (IROperand*)p.ops().get((u32)1)
                                  : ((IROperand*)p.ops().get((u32)2)).blk() == B ? (IROperand*)p.ops().get((u32)3) : (IROperand*)0;
                    // A value on the back edge (a constant there is not handled).
                    if (bv == (IROperand*)0 || bv.kind() != (u8)OPK_USE)
                        ok = false;
                    else
                        back.add((Object*)bv);
                    }
                for (u32 k = (u32)0; k < H.insns().count(); k = k + (u32)1)
                    if (!escTripsPure((IRInsn*)H.insns().get(k)))
                        ok = false;
                for (u32 k = (u32)0; k < B.insns().count(); k = k + (u32)1)
                    if (!escTripsPure((IRInsn*)B.insns().get(k)))
                        ok = false;
                if (!ok || ((IROperand*)t.ops().get((u32)0)).kind() != (u8)OPK_USE)
                    continue;
                bool stayOnTrue = ((IROperand*)t.ops().get((u32)1)).blk() == B;
                Array* cur = new Array();
                for (u32 q = (u32)0; q < back.count(); q = q + (u32)1)
                    cur.add(back.get(q));
                Array* hIns = new Array();
                for (u32 k = (u32)0; k < H.insns().count(); k = k + (u32)1)
                    hIns.add(H.insns().get(k));
                Array* bIns = new Array();
                for (u32 k = (u32)0; k < B.insns().count(); k = k + (u32)1)
                    bIns.add(B.insns().get(k));
                for (i64 j = (i64)1; j < trips; j = j + (i64)1)
                    {
                    Map* m = new Map();
                    for (u32 q = (u32)0; q < H.phis().count(); q = q + (u32)1)
                        m.set((Hashable*)((IRInsn*)H.phis().get(q)).res(), (Object*)((IROperand*)cur.get(q)).val());
                    for (u32 k = (u32)0; k < hIns.count(); k = k + (u32)1)
                        escTripsClone((IRInsn*)hIns.get(k), B, m);
                    for (u32 k = (u32)0; k < bIns.count(); k = k + (u32)1)
                        escTripsClone((IRInsn*)bIns.get(k), B, m);
                    IROperand* cond = escTripsMap((IROperand*)t.ops().get((u32)0), m);
                    for (u32 q = (u32)0; q < H.phis().count(); q = q + (u32)1)
                        {
                        IROperand* nv = escTripsMap((IROperand*)back.get(q), m);
                        IROperand* yes = stayOnTrue ? nv : (IROperand*)cur.get(q);
                        IROperand* no = stayOnTrue ? (IROperand*)cur.get(q) : nv;
                        IRInsn* sel = IRInsn.with(String.withCString("Select"));
                        sel.add(cond);
                        sel.add(yes);
                        sel.add(no);
                        sel.setRes(new IRValue(((IRInsn*)H.phis().get(q)).res().ty()));
                        B.insns().add((Object*)sel);
                        cur.set(q, (Object*)IROperand.useVal(sel.res()));
                        }
                    }
                for (u32 q = (u32)0; q < H.phis().count(); q = q + (u32)1)
                    {
                    IRInsn* p = (IRInsn*)H.phis().get(q);
                    p.ops().set(((IROperand*)p.ops().get((u32)0)).blk() == B ? (u32)1 : (u32)3, cur.get(q));
                    }
                bool listed = false;
                for (u32 k = (u32)0; k < _escChanged.count(); k = k + (u32)1)
                    if (((String*)_escChanged.get(k)).equals(fn.name()))
                        listed = true;
                if (!listed)
                    _escChanged.add((Object*)fn.name());
                }
            }
        }

    final bool failed(void)
        {
        return _failed;
        }
    final String* why(void)
        {
        return _why;
        }

    final void giveUp(String* w)
        {
        if (_failed)
            return;
        _failed = true;
        _why = w;
        }

    static bool ppReport(void)
        {
        u8* e = optGetenv("XC_PAR_PROPOSE");
        return e != (u8*)0 && String.withCString(e).equals(String.withCString("report"));
        }
    // XC_PAR_PROPOSE=outline: IR outlining, stage 1 (cpp-front-end.md, "B,
    // outlining in the IR"): each loop Propose would wrap becomes a function
    // of its own, called once in its place. Experimental, selfhost only.
    static bool ppOutline(void)
        {
        if (optOutline())
            return true;
        u8* e = optGetenv("XC_PAR_PROPOSE");
        return e != (u8*)0 && String.withCString(e).equals(String.withCString("outline"));
        }

    final void run(IRModule* m)
        {
        // VaArgExpand is MANDATORY at every level — the backend has no case for
        // the abstract VaStart/VaArg — but a native-varargs target has already
        // passed its tail in registers and there is nothing to expand.
        if (!_profile.nativeVarargs())
            self.vaArgExpand(m);
        if (stopHere(String.withCString("vaarg-expand")))
            return;
        self.gpuGlobals(m);
        if (stopHere(String.withCString("gpu-globals")))
            return;
        // Before dead-function elimination, so a block whose site's branch
        // goes takes its functions with it.
        if (_level >= (u32)1)
            self.constBranches(m);
        if (stopHere(String.withCString("const-branches")))
            return;
        if (_level >= (u32)1)
            deadFunctionElim(m);
        if (stopHere(String.withCString("dead-function-elim")))
            return;
        if (_level >= (u32)1)
            self.sqrtIntrinsic(m);
        if (stopHere(String.withCString("sqrt-intrinsic")))
            return;
        if (_level >= (u32)2)
            self.powSquare(m);
        if (stopHere(String.withCString("pow-square")))
            return;
        if (_level >= (u32)2)
            self.arcSelfRetain(m);
        if (stopHere(String.withCString("arc-self-retain")))
            return;
        if (_level >= (u32)2)
            self.inlineLeaves(m);
        if (_failed)
            return;
        if (stopHere(String.withCString("inline")))
            return;
        // Inlining leaves callees with no remaining callers.
        if (_level >= (u32)2)
            deadFunctionElim(m);
        if (stopHere(String.withCString("dead-function-elim")))
            return;
        if (_level >= (u32)2)
            self.narrow(m);
        if (stopHere(String.withCString("narrow")))
            return;
        if (_level >= (u32)2)
            self.tailRecursion(m);
        if (_failed)
            return;
        if (stopHere(String.withCString("tail-recursion")))
            return;
        // CSE BEFORE if-conversion as well as after it. If-conversion refuses
        // to speculate a memory op, so a diamond whose arms each reload the
        // same element is refused — and the load CSE that would have made it
        // convertible otherwise runs long after the decision was taken.
        // Cross-block is ON for this instance only; see cseInFunc.
        // Gated on hoistLocalAddr: may an ADDRESS value be shared between
        // blocks? On a banked target it may not — an address there carries an
        // implicit bank context, so the same ElementAddr in two blocks is not
        // the same value. xt6502 lost foundation_sort and arc_weak_local_return
        // to exactly that.
        if (_level >= (u32)2)
            {
            _cseCrossBlock = _profile.hoistLocalAddr();
            self.redundantLoadCSE(m);
            _cseCrossBlock = false;
            }
        // XTIR_OPT_STOP_AFTER matches the FIRST pass of a repeated name, and
        // there are now two `redundant-load-cse` runs. Without this the two
        // sides stop at DIFFERENT points and the per-pass comparison reports a
        // divergence neither compiler has.
        if (stopHere(String.withCString("redundant-load-cse")))
            return;
        if (_level >= (u32)2)
            self.ifConvert(m);
        if (stopHere(String.withCString("if-convert")))
            return;
        if (_level >= (u32)2)
            self.jumpThread(m);
        if (stopHere(String.withCString("jump-thread")))
            return;
        if (_level >= (u32)2)
            self.aggExpand(m);
        if (stopHere(String.withCString("agg-expand")))
            return;
        if (_level >= (u32)2)
            self.mem2reg(m);
        // A C module's loops come from clang as test, body and step blocks
        // (for.cond, for.body, for.inc): folded into one body block, as an
        // xc loop is lowered, before the passes that look for that shape
        // (the vectoriser's).
        if (_level >= (u32)2 && optPromoteScalars())
            {
            self.cNarrowIndices(m);
            // C's `c ? a : b` and `if (c) x = y` are stores to a local in
            // two arms until mem2reg: only now are they the diamonds the
            // if-conversion makes selects of (and a helper made of them one
            // block, which the inlining below takes).
            self.ifConvert(m);
            self.blockMerge(m);
            }
        if (ppReport())
            self.parProposeReport(m);
        if (ppOutline())
            {
            _ppMade = new Array();
            self.parProposeOutline(m);
            _ppOutlined = true;
            if (_ppMade.count() > (u32)0 && optParKernelHook() != (ParKernelHook*)0)
                optParKernelHook().print(m, _ppMade);
            // XC_PAR_OUTLINE_TRACE=ir: the functions the outliner made or cut.
            u8* tr = optGetenv("XC_PAR_OUTLINE_TRACE");
            if (tr != (u8*)0 && String.withCString(tr).equals(String.withCString("ir")))
                for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
                    {
                    IRFunc* fn = (IRFunc*)m.funcs().get(f);
                    if (fn.name().hasPrefix(String.withCString("ParOut$")) || fn.name().equals(String.withCString("main")))
                        Stdio.error(fn.text());
                    }
            // XC_PAR_OUTLINE_DUMP=<path>: the whole module after outlining.
            u8* dp = optGetenv("XC_PAR_OUTLINE_DUMP");
            if (ppEnvSet("XC_PAR_OUTLINE_DUMP"))
                Files.writeText(String.withCString(dp), m.text());
            }
        if (stopHere(String.withCString("mem2reg")))
            return;
        if (_level >= (u32)2)
            self.simplify(m);
        if (stopHere(String.withCString("simplify")))
            return;
        // SECOND inlining pass, after if-conversion has linearised the small
        // helpers that lowering gave as BRANCH DIAMONDS. A ternary lowers to a
        // two-block diamond with a join phi, so the first inline pass (which
        // refuses a callee with any phi) never touches a helper that is one —
        // the classic `a < b ? a : b`. Once if-conversion + mem2reg have turned
        // those diamonds into Selects the helper is a single-block leaf and
        // inlines here. perlin's grad() is exactly this shape.
        if (_level >= (u32)2)
            self.inlineLeaves(m);
        if (_failed)
            return;
        if (stopHere(String.withCString("inline")))
            return;
        if (_level >= (u32)2)
            deadFunctionElim(m);
        if (stopHere(String.withCString("dead-function-elim")))
            return;
        if (_level >= (u32)2)
            self.staticInitGuard(m);
        if (stopHere(String.withCString("static-init-guard-elim")))
            return;
        if (_level >= (u32)2)
            self.boundsElide(m);
        if (stopHere(String.withCString("bounds-elide")))
            return;
        // The checks bounds-elide could not prove stay calls. Under
        // -fbounds-check=light they inline here, only in loops (cyclicBlocks;
        // never before bounds-elide: then no call is left for it to find):
        // measured 2026-10-26, array_map 1.67x faster, sieve and mem_copy 3-4%
        // slower, checked binaries 1.43x larger. The debug build keeps calls.
        if (_level >= (u32)2 && _profile != (OptProfile*)0 && _profile.inlineChecks())
            {
            _inlineChecks = true;
            self.inlineLeaves(m);
            _inlineChecks = false;
            if (stopHere(String.withCString("inline-checks")))
                return;
            }
        if (_level >= (u32)2)
            self.idiomMemset(m);
        if (stopHere(String.withCString("idiom-memset")))
            return;
        if (_level >= (u32)2)
            self.idiomMatMul(m);
        if (stopHere(String.withCString("idiom-matmul")))
            return;
        if (_level >= (u32)2)
            self.deadCode(m);
        if (stopHere(String.withCString("dead-code")))
            return;
        if (_level >= (u32)2)
            self.loopReductionCollapse(m);
        if (stopHere(String.withCString("loop-reduction-collapse")))
            return;
        if (_level >= (u32)2)
            self.redundantLoadCSE(m);
        if (stopHere(String.withCString("redundant-load-cse")))
            return;
        // A run of LICM BEFORE the vectoriser: the reduction recogniser needs a
        // body free of loads that do not vary with the vectorised iv, and in a
        // NESTED loop a load indexed by the OUTER iv is exactly that (nbody's
        // px[i]). The post-vectoriser LICM below stays.
        if (_level >= (u32)2)
            self.licm(m);
        if (stopHere(String.withCString("licm")))
            return;
        // simplify again, for what the late inline pass made constant: its
        // `x <= K` to `x < K + 1` above all, since the vectoriser's
        // constant-trip paths read a bound as `<`.
        if (_level >= (u32)2)
            self.simplify(m);
        if (stopHere(String.withCString("simplify")))
            return;
        if (_level >= (u32)2)
            self.simdClone(m);
        if (stopHere(String.withCString("simd-clone")))
            return;
        if (_level >= (u32)2)
            self.outerVectorize(m);
        if (stopHere(String.withCString("outer-vectorize")))
            return;
        if (_level >= (u32)2)
            self.vectorize(m);
        if (stopHere(String.withCString("vectorize")))
            return;
        if (_level >= (u32)2 && (_profile.bitSelect() || _profile.bitSelect512()))
            self.vecCombine(m);
        if (stopHere(String.withCString("vec-combine")))
            return;
        if (_level >= (u32)2)
            self.simdPrune(m);
        if (stopHere(String.withCString("simd-prune")))
            return;
        if (_level >= (u32)2)
            self.loopUnroll(m);
        if (_failed)
            return;
        if (stopHere(String.withCString("loop-unroll")))
            return;
        // Dead code (including dead phis) comes out before the variable-trip
        // unroller, so a loop-carried value the lowering threads but never
        // reads cannot pin its source live and block the no-escape check.
        if (_level >= (u32)2)
            self.deadCode(m);
        if (stopHere(String.withCString("dead-code")))
            return;
        if (_level >= (u32)2)
            self.pointerIV(m);
        if (stopHere(String.withCString("pointer-iv")))
            return;
        if (_level >= (u32)2)
            self.loopUnrollVarTrip(m);
        if (stopHere(String.withCString("loop-unroll-vartrip")))
            return;
        if (_level >= (u32)2)
            self.unrollChainLoops(m);
        if (stopHere(String.withCString("unroll-chain-loops")))
            return;
        if (_level >= (u32)2)
            {
            _srFloatMul = _profile.floatMulToAdd();
            self.strengthReduce(m);
            _srFloatMul = false;
            }
        if (stopHere(String.withCString("strength-reduce")))
            return;
        if (_level >= (u32)2)
            self.constOperandFold(m);
        if (stopHere(String.withCString("const-operand-fold")))
            return;
        if (_level >= (u32)2)
            self.redundantLoadCSE(m);
        if (stopHere(String.withCString("redundant-load-cse")))
            return;
        if (_level >= (u32)2)
            self.licm(m);
        if (stopHere(String.withCString("licm")))
            return;
        if (_level >= (u32)2)
            self.constHoist(m);
        if (stopHere(String.withCString("const-hoist")))
            return;
        // Value-number again: LICM hoists each unrolled copy's invariant
        // arithmetic separately, so a preheader can hold several copies of the
        // same `i * 32`. This run is the late one (the reference's `late`).
        if (_level >= (u32)2)
            {
            _cseCrossBlock = _profile.hoistLocalAddr();
            _cseLate = true;
            self.redundantLoadCSE(m);
            _cseCrossBlock = false;
            _cseLate = false;
            }
        if (stopHere(String.withCString("redundant-load-cse")))
            return;
        // Fold each block into its only predecessor first, so an unrolled
        // body (copies chained by plain branches) is one block when the
        // rotation below looks at it.
        if (_level >= (u32)2)
            self.blockMerge(m);
        if (stopHere(String.withCString("block-merge")))
            return;
        if (_level >= (u32)2)
            self.reassociate(m);
        if (stopHere(String.withCString("reassociate")))
            return;
        if (_level >= (u32)2)
            self.loopRotate(m);
        if (stopHere(String.withCString("loop-rotate")))
            return;
        if (_level >= (u32)2)
            self.narrowIV(m);
        if (stopHere(String.withCString("narrow-iv")))
            return;
        if (_level >= (u32)2 && (_profile.bitSelect() || _profile.bitSelect512()))
            self.vecPool(m);
        if (stopHere(String.withCString("vec-pool")))
            return;
        // The final sweep: pure instructions orphaned by everything above.
        if (_level >= (u32)2)
            self.deadCode(m);
        if (stopHere(String.withCString("dead-code")))
            return;
        // Under `:goal(speed)`, a product and the add or subtract consuming it
        // may round once (owner, 2026-10-26). After everything that rebuilds
        // instructions, so the mark is not lost on the way.
        if (_level >= (u32)2)
            self.fpContract(m);
        if (stopHere(String.withCString("fp-contract")))
            return;
        // LAST: order the blocks so a conditional branch's expected successor
        // falls through. Nothing after this may reorder or add blocks, and
        // nothing before it is affected — it rewrites no instruction, only the
        // order fn.blocks holds them in.
        if (_level >= (u32)2)
            self.blockLayout(m);
        if (stopHere(String.withCString("block-layout")))
            return;
        // Values that no surviving instruction defines are dropped. A pass that
        // deletes an instruction leaves its result registered — the function's
        // value table still holds it, nothing defines it, and the PRINTER
        // (which emits instructions) never mentions it again.
        //
        // The slot-per-value back ends then reserve a frame slot for every
        // registered value, so every optimised function carried dead stack. It
        // is invisible to every text-based differential, because they compare a
        // back end fed the PRINTED IR on both sides and the printed IR has only
        // the live values — it shows up only where a driver optimises and code
        // generates IN MEMORY, which is exactly what the shipped compiler does.
        // private:docs/bugs/090.
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            pruneDeadValues((IRFunc*)m.funcs().get(i));
        refuseUnknownStop();
        }

    /************************************************************************\
    |* Drop every value the function still has registered that nothing defines.
    |*
    |* "Defines" is wider than an instruction's result, and the reference got it
    |* wrong in both directions it could:
    |*
    final |*   * a MULTI-RESULT instruction (`%50:Agg, %51 = Load`) defines its memory
    |*     token as `memRes`, which walking `res` alone never sees;
    |*   * a FRAME-PINNED local is defined by the frame, not by any instruction —
    |*     dropping one removed the whole pinned area, and on one function that
    |*     single 32-byte aggregate WAS the entire frame discrepancy.
    |*
    |* Parameters are defined by the call, so they are never pruned either.
    \************************************************************************/
    void pruneDeadValues(IRFunc* fn)
        {
        Array* byId = fn.byId();
        u32 n = byId.count();
        if (n == (u32)0)
            return;
        Array* live = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            live.add((Object*)Number.with((u32)0));
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            markLive(live, (IRValue*)fn.params().get(i), n);
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            markLive(live, ((IRPinned*)fn.pinned().get(i)).val(), n);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)fn.blocks().get(b);
            markDefsIn(live, blk.phis(), n);
            markDefsIn(live, blk.insns(), n);
            if (blk.term() != 0)
                markDefsOf(live, (IRInsn*)blk.term(), n);
            }
        for (u32 v = (u32)0; v < n; v = v + (u32)1)
            if (byId.get(v) != (Object*)0 && ((Number*)live.get(v)).asU32() == (u32)0)
                byId.set(v, (Object*)0);
        }

    final void markDefsIn(Array* live, Array* insns, u32 n)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            markDefsOf(live, (IRInsn*)insns.get(i), n);
        }

    final void markDefsOf(Array* live, IRInsn* i, u32 n)
        {
        markLive(live, i.res(), n);
        markLive(live, i.memRes(), n);
        }

    final void markLive(Array* live, IRValue* v, u32 n)
        {
        if (v == (IRValue*)0)
            return;
        u32 id = v.pid();
        if (id < n)
            live.set(id, (Object*)Number.with((u32)1));
        }

    // ── dead-function-elim ───────────────────────────────────────────────
    //
    // Walk the call graph from the roots and drop every function body nothing
    // reaches. The SYMBOLS stay: the module's symbol table is referenced by id
    // elsewhere, so a stray entry whose body is gone is benign and renumbering
    // would not be. The bodies are the size driver anyway.
    final void deadFunctionElim(IRModule* m)
        {
        Array* reachable = new Array(); // String@ — names kept
        Array* work = new Array();
        _dfeFns = Map.withCapacity(m.funcs().count() + (u32)1);
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)m.funcs().get(i);
            String* fname = f.name();
            if (fname != 0 && _dfeFns.get((Hashable*)fname) == (Object*)0)
                _dfeFns.set((Hashable*)fname, (Object*)f);
            }
        _dfeSyms = Map.withCapacity(m.syms().count() + (u32)1);
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            String* sn = s.name();
            if (sn != 0 && _dfeSyms.get((Hashable*)sn) == (Object*)0)
                _dfeSyms.set((Hashable*)sn, (Object*)s);
            }
        _dfeReach = Map.withCapacity((u32)64);

        // `main` is the canonical entry, and a load-time constructor is a root
        // even though nothing calls it: the backend emits the constructor list
        // after this pass, so the reference does not exist yet.
        self.seed(m, reachable, work, String.withCString("main"));
        if (_keepClassRoot)
            self.seed(m, reachable, work, String.withCString("_xtc_class_new"));
        for (u32 i = (u32)0; i < m.modinits().count(); i = i + (u32)1)
            self.seed(m, reachable, work, (String*)m.modinits().get(i));
        // IR outlining dispatches blocks it has not made yet, after mem2reg:
        // the runtime's entry points stay until then (the pass after removes
        // them if no block was made).
        if (ppOutline() && !_ppOutlined)
            {
            self.seed(m, reachable, work, String.withCString("ParFnChunk$make"));
            self.seed(m, reachable, work, String.withCString("ParFnChunk$ctx"));
            self.seed(m, reachable, work, String.withCString("Par$run"));
            self.seed(m, reachable, work, String.withCString("ParFnChunk$runOn"));
            self.seed(m, reachable, work, String.withCString("parSameName"));
            self.seed(m, reachable, work, String.withCString("Par$spanOf"));
            }

        // Library mode: seed EVERY function — the module IS the API surface.
        if (_keepAllFunctions)
            for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
                self.seed(m, reachable, work, ((IRFunc*)m.funcs().get(i)).name());

        // A function symbol that ESCAPES may be called through a pointer, and
        // every vtable slot may be called through dispatch — neither is visible
        // at a call site.
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() == (u8)SYM_FUNCTION)
                {
                if (s.escapes())
                    self.seed(m, reachable, work, s.name());
                // `extern`-on-a-definition = the module's public surface (a
                // wasm export): nothing in-module need call it — the HOST
                // does. A DFE-stripped export fails at instance.exports call
                // time, far from the build (wasm-target.md §6).
                if (s.attr(String.withCString("exported")))
                    self.seed(m, reachable, work, s.name());
                }
            else if (s.kind() == (u8)SYM_VTABLE)
                {
                seedSlots(m, reachable, work, s);
                }
            }

        while (work.count() > (u32)0)
            {
            String* name = (String*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            IRFunc* fn = (IRFunc*)_dfeFns.get((Hashable*)name);
            if (fn == 0)
                continue;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    seedFromInsn(m, reachable, work, (IRInsn*)bb.insns().get(i));
                // A terminator can name a symbol too (a tail branch to one), and
                // a phi's operands are values, never symbols.
                if (bb.term() != 0)
                    seedFromInsn(m, reachable, work, bb.term());
                }
            }

        Array* survivors = new Array();
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(i);
            if (fn.name() != 0 && _dfeReach.get((Hashable*)fn.name()) != (Object*)0)
                survivors.add((Object*)fn);
            else if (_profile != (OptProfile*)0 && _profile.dceTrace())
                Stdio.error(String.withFormat("xcc: dce: removed unreachable function '%s'\n",
                                              fn.name().cString()));
            }
        _dfeFns = (Map*)0;
        _dfeReach = (Map*)0;
        _dfeSyms = (Map*)0;
        if (survivors.count() == m.funcs().count())
            return;
        m.setFuncs(survivors);
        }

    // Every SYMBOL an instruction names is a reference: a call, an AddrOf, a
    // vtable — the pass does not distinguish, because any of them keeps the
    // function alive.
    final void seedFromInsn(IRModule* m, Array* reachable, Array* work, IRInsn* n)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                continue;
            IRSymbol* s = _dfeSyms != (Map*)0 ? (IRSymbol*)_dfeSyms.get((Hashable*)o.name()) : self.symNamed(m, o.name());
            if (s == 0)
                {
                self.seed(m, reachable, work, o.name());
                continue;
                }
            if (s.kind() == (u8)SYM_VTABLE)
                seedSlots(m, reachable, work, s);
            else
                self.seed(m, reachable, work, s.name());
            }
        }

    final void seedSlots(IRModule* m, Array* reachable, Array* work, IRSymbol* s)
        {
        if (s.slots() == 0)
            return;
        for (u32 k = (u32)0; k < s.slots().count(); k = k + (u32)1)
            self.seed(m, reachable, work, (String*)s.slots().get(k));
        }
    }
