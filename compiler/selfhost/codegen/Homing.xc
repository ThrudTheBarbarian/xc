// Homing.xc — which values live in registers, and which stay in their slots.
// =========================================================================
//
// self-hosting M8. The port of XTHomingAllocator, shared by every backend that
// homes SSA values in registers. It is not a graph-colouring allocator: every
// value already HAS a frame slot, and this decides which of them additionally
// live in a register so the common case never touches memory. A value that
// misses out simply stays in its slot, which is why the answer can be
// approximate without being wrong.
//
// The shape, in order:
//   * number every instruction, and record where each value is defined, last
//     read, and how often;
//   * backward liveness over the blocks, with the SSA phi rule (a phi's operand
//     is live out of the PREDECESSOR, not into the phi's own block);
//   * live intervals in DOUBLED positions, so a definition at p and a use at p
//     do not look like they overlap;
//   * assign, most-used first, reusing a register for non-overlapping
//     intervals. A value whose interval spans a call may only take a
//     callee-saved register; a phi result takes one exclusively, because the
//     edge copies write it outside the interval model.
//
// Sets are BITSETS over value ids rather than hash sets: liveness is a fixpoint
// over whole-block sets, and one allocation per id per iteration is the
// difference between a compiler that runs on the A9 and one that does not.

#import "Foundation.xc"
#import "Ir.xc"

class BitSet
    {
    u8* _bits;
    u32 _n; // capacity in BITS

    void init(void)
        {
        _n = (u32)0;
        }

    static BitSet* withCapacity(u32 n)
        {
        BitSet* b = new BitSet();
        b._n = n;
        b._bits = new u8[(n >> 3) + (u32)1];
        for (u32 i = (u32)0; i < (n >> 3) + (u32)1; i = i + (u32)1)
            b._bits[i] = (u8)0;
        return b;
        }

    bool has(u32 i)
        {
        if (i >= _n)
            return false;
        return (_bits[i >> 3] & ((u8)1 << (u8)(i & (u32)7))) != (u8)0;
        }

    void add(u32 i)
        {
        if (i >= _n)
            return;
        _bits[i >> 3] = _bits[i >> 3] | ((u8)1 << (u8)(i & (u32)7));
        }

    void remove(u32 i)
        {
        if (i >= _n)
            return;
        _bits[i >> 3] = _bits[i >> 3] & ~((u8)1 << (u8)(i & (u32)7));
        }

    u32 capacity(void)
        {
        return _n;
        }

    void unionWith(BitSet* o)
        {
        for (u32 i = (u32)0; i < (_n >> 3) + (u32)1; i = i + (u32)1)
            _bits[i] = _bits[i] | o._bits[i];
        }

    void minusWith(BitSet* o)
        {
        for (u32 i = (u32)0; i < (_n >> 3) + (u32)1; i = i + (u32)1)
            _bits[i] = _bits[i] & ~o._bits[i];
        }

    void copyFrom(BitSet* o)
        {
        for (u32 i = (u32)0; i < (_n >> 3) + (u32)1; i = i + (u32)1)
            _bits[i] = o._bits[i];
        }

    bool sameAs(BitSet* o)
        {
        for (u32 i = (u32)0; i < (_n >> 3) + (u32)1; i = i + (u32)1)
            if (_bits[i] != o._bits[i])
                return false;
        return true;
        }
    }

    // One value's live interval, in doubled positions.
    class Interval
    {
    u32 _lo;
    u32 _hi;
    void init(void)
        {
        }
    static Interval* with(u32 lo, u32 hi)
        {
        Interval* i = new Interval();
        i._lo = lo;
        i._hi = hi;
        return i;
        }
    u32 lo(void)
        {
        return _lo;
        }
    u32 hi(void)
        {
        return _hi;
        }
    }

    class Homing
    {
    IRFunc* _fn;
    Map* _rank; // pid -> position in print order (the tie-break)
    u32 _nv;    // value ids are 0.._nv-1
    u32 _nb;

    Array* _defPos; // Number@ per value, or 0
    Array* _lastUse;
    Array* _useCount;
    BitSet* _phiResults;
    BitSet* _excluded;
    Array* _callPos; // Number@

    Array* _defSet; // BitSet@ per block
    Array* _ueUse;
    Array* _phiResAt;
    Array* _phiEdge;
    Array* _blkEnd; // Number@ per block
    Array* _succ;   // Array@ of Number@ per block
    Array* _liveIn;
    Array* _liveOut;

    Array* _start; // Number@ per value, doubled
    Array* _end;
    BitSet* _crossesCall;
    Map* _home;          // value id (as Number@ key) -> register name
    Array* _usedCallee;  // callee-saved registers actually homed in
    Array* _preExcluded; // ids a BACK END rules out before the run

    void init(void)
        {
        _preExcluded = new Array();
        }

    Map* homes(void)
        {
        return _home;
        }

    // The callee-saved registers this function actually homed a value in, in
    // the order the pool offered them. A back end reserves one frame slot per
    // entry and saves/restores them around the body.
    Array* usedCalleeSaved(void)
        {
        return _usedCallee;
        }

    // A back end can rule a value out before the run — an ICmp fused into its
    // branch, an address op folded into a memory operand, a pointer-IV homed in
    // an address register. Each of those is either never emitted or lives
    // somewhere the general allocator does not know about, so a home for it
    // would be a register reserved for nothing.
    void exclude(u32 vid)
        {
        _preExcluded.add((Object*)Number.with(vid));
        }

    // A back end that FOLDS an address op into a Load/Store's memory operand
    // must say so: the folded op is elided, and its base and index are read at
    // the LOAD's position instead of its own. Without extending those live
    // ranges the allocator sees the index die at the elided op and reuses its
    // register for the load's own result, corrupting the base.
    // Keyed by the pointer value's id -> the address instruction.
    Map* _foldInfo;
    void setFoldInfo(Map* m)
        {
        _foldInfo = m;
        }

    // A back end that FUSES an ICmp into a Select must say so for the same
    // reason, and the window is wider: the compare is re-issued AT the Select,
    // several instructions after the ICmp the allocator sees, so its source
    // operands look dead and their registers go to the Select's own arms —
    // which then compare whichever arm landed there. Keyed by the Select's
    // CONDITION value id -> the ICmp instruction.
    Map* _selInfo;
    void setSelInfo(Map* m)
        {
        _selInfo = m;
        }

    // An opcode that emits a runtime call, so a value live across it cannot sit
    // in a caller-saved register. The hidden ones count too — bulk memory ops
    // and the ARC helpers are calls on some backends — and being generous here
    // only nudges a value to callee-saved.
    static bool isCallOp(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet")) || op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")) || op.equals(String.withCString("WeakRegister")) || op.equals(String.withCString("WeakUnregister")) || op.equals(String.withCString("WeakLoad"));
        }

    static bool isFloatTy(String* t)
        {
        return t != 0 && (t.equals(String.withCString("F32")) || t.equals(String.withCString("F64")));
        }

    // The one entry point: assign homes for `fn` out of the two tiers.
    void run(IRFunc* fn, Array* gpCallee, Array* gpCaller,
             Array* fpCallee, Array* fpCaller)
        {
        _fn = fn;
        // Ties broken by PRINT order, not id. In this compiler's own pipeline
        // a pass-created value's pid is appended in creation order, which is
        // not where it prints; the reference ranks by print order for the
        // same reason (bug 090). Both sides must sort by the one sequence
        // both can see.
        _rank = new Map();
        Array* order = fn.valuesInPrintOrder();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            _rank.set((Hashable*)Number.with(((IRValue*)order.get(i)).pid()), (Object*)Number.with(i));
        _home = new Map();
        _usedCallee = new Array();
        _nb = fn.blocks().count();
        if (_nb == (u32)0)
            return;
        _nv = fn.byId().count() + (u32)1;
        prepare();
        scan();
        phiEdges();
        liveness();
        intervals();
        Array* gp = new Array();
        Array* fp = new Array();
        candidates(gp, fp);
        assign(gp, gpCallee, gpCaller);
        assign(fp, fpCallee, fpCaller);
        }

    void prepare(void)
        {
        _defPos = new Array();
        _lastUse = new Array();
        _useCount = new Array();
        for (u32 i = (u32)0; i < _nv; i = i + (u32)1)
            {
            _defPos.add((Object*)0);
            _lastUse.add((Object*)0);
            _useCount.add((Object*)Number.with((u32)0));
            }
        _phiResults = BitSet.withCapacity(_nv);
        _excluded = BitSet.withCapacity(_nv);
        for (u32 i = (u32)0; i < _preExcluded.count(); i = i + (u32)1)
            {
            u32 v = ((Number*)_preExcluded.get(i)).asU32();
            if (v < _nv)
                _excluded.add(v);
            }
        _callPos = new Array();
        _defSet = new Array();
        _ueUse = new Array();
        _phiResAt = new Array();
        _phiEdge = new Array();
        _blkEnd = new Array();
        _succ = new Array();
        _liveIn = new Array();
        _liveOut = new Array();
        for (u32 i = (u32)0; i < _nb; i = i + (u32)1)
            {
            _defSet.add((Object*)BitSet.withCapacity(_nv));
            _ueUse.add((Object*)BitSet.withCapacity(_nv));
            _phiResAt.add((Object*)BitSet.withCapacity(_nv));
            _phiEdge.add((Object*)BitSet.withCapacity(_nv));
            _liveIn.add((Object*)BitSet.withCapacity(_nv));
            _liveOut.add((Object*)BitSet.withCapacity(_nv));
            _blkEnd.add((Object*)Number.with((u32)0));
            }
        }

    void bumpUse(u32 v, u32 pos, BitSet* defs, BitSet* ue)
        {
        if (v >= _nv)
            return;
        if (!defs.has(v))
            ue.add(v);
        _lastUse.set(v, (Object*)Number.with(pos));
        u32 c = ((Number*)_useCount.get(v)).asU32();
        _useCount.set(v, (Object*)Number.with(c + (u32)1));
        }

    void recordUses(IRInsn* insn, u32 pos, BitSet* defs, BitSet* ue)
        {
        for (u32 i = (u32)0; i < insn.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)insn.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            bumpUse(o.val().pid(), pos, defs, ue);
            }
        }

    void scan(void)
        {
        u32 pos = (u32)0;
        for (u32 bi = (u32)0; bi < _nb; bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)_fn.blocks().get(bi);
            BitSet* defs = (BitSet*)_defSet.get(bi);
            BitSet* ue = (BitSet*)_ueUse.get(bi);
            for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)b.phis().get(i);
                if (phi.res() != 0)
                    {
                    u32 v = phi.res().pid();
                    _defPos.set(v, (Object*)Number.with(pos));
                    defs.add(v);
                    ((BitSet*)_phiResAt.get(bi)).add(v);
                    _phiResults.add(v);
                    }
                pos = pos + (u32)1;
                }
            for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
                {
                IRInsn* insn = (IRInsn*)b.insns().get(i);
                recordUses(insn, pos, defs, ue);
                if (_foldInfo != 0 && insn.ops().count() >= (u32)1 && (insn.op().equals(String.withCString("Load")) || insn.op().equals(String.withCString("Store"))))
                    {
                    IROperand* p0 = (IROperand*)insn.ops().get((u32)0);
                    if (p0.kind() == (u8)OPK_USE && p0.val() != 0)
                        {
                        Object* fea = _foldInfo.get((Hashable*)Number.with(p0.val().pid()));
                        if (fea != 0)
                            recordUses((IRInsn*)fea, pos, defs, ue);
                        }
                    }
                if (_selInfo != 0 && insn.ops().count() >= (u32)1 && insn.op().equals(String.withCString("Select")))
                    {
                    IROperand* c0 = (IROperand*)insn.ops().get((u32)0);
                    if (c0.kind() == (u8)OPK_USE && c0.val() != 0)
                        {
                        Object* sc = _selInfo.get((Hashable*)Number.with(c0.val().pid()));
                        if (sc != 0)
                            recordUses((IRInsn*)sc, pos, defs, ue);
                        }
                    }
                if (Homing.isCallOp(insn.op()))
                    _callPos.add((Object*)Number.with(pos));
                // An AddrOf operand is address-TAKEN: it must live at a real
                // slot, so it never gets a home.
                if (insn.op().equals(String.withCString("AddrOf")))
                    for (u32 k = (u32)0; k < insn.ops().count(); k = k + (u32)1)
                        {
                        IROperand* o = (IROperand*)insn.ops().get(k);
                        if (o.kind() == (u8)OPK_USE && o.val() != 0)
                            _excluded.add(o.val().pid());
                        }
                if (insn.res() != 0)
                    {
                    _defPos.set(insn.res().pid(), (Object*)Number.with(pos));
                    defs.add(insn.res().pid());
                    }
                pos = pos + (u32)1;
                }
            if (b.term() != 0)
                {
                recordUses(b.term(), pos, defs, ue);
                if (Homing.isCallOp(b.term().op()))
                    _callPos.add((Object*)Number.with(pos));
                pos = pos + (u32)1;
                }
            _blkEnd.set(bi, (Object*)Number.with(pos - (u32)1));
            }
        }

    i32 blockIndexOf(IRBlock* b)
        {
        for (u32 i = (u32)0; i < _nb; i = i + (u32)1)
            if ((IRBlock*)_fn.blocks().get(i) == b)
                return (i32)i;
        return (i32)-1;
        }

    // A phi operand is a use on the PREDECESSOR's edge, which is what makes the
    // liveness rule an SSA one.
    void phiEdges(void)
        {
        for (u32 bi = (u32)0; bi < _nb; bi = bi + (u32)1)
            {
            IRBlock* b = (IRBlock*)_fn.blocks().get(bi);
            Array* s = new Array();
            if (b.term() != 0)
                for (u32 i = (u32)0; i < b.term().ops().count(); i = i + (u32)1)
                    {
                    IROperand* o = (IROperand*)b.term().ops().get(i);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() == 0)
                        continue;
                    i32 si = blockIndexOf(o.blk());
                    if (si >= (i32)0)
                        s.add((Object*)Number.with((u32)si));
                    }
            _succ.add((Object*)s);
            }
        for (u32 si = (u32)0; si < _nb; si = si + (u32)1)
            {
            IRBlock* b = (IRBlock*)_fn.blocks().get(si);
            for (u32 i = (u32)0; i < b.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)b.phis().get(i);
                for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                    {
                    IROperand* bo = (IROperand*)phi.ops().get(k);
                    IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
                    if (bo.kind() != (u8)OPK_BLOCK || bo.blk() == 0)
                        continue;
                    if (vo.kind() != (u8)OPK_USE || vo.val() == 0)
                        continue;
                    i32 pbi = blockIndexOf(bo.blk());
                    if (pbi < (i32)0)
                        continue;
                    u32 v = vo.val().pid();
                    ((BitSet*)_phiEdge.get((u32)pbi)).add(v);
                    u32 c = ((Number*)_useCount.get(v)).asU32();
                    _useCount.set(v, (Object*)Number.with(c + (u32)1));
                    }
                }
            }
        }

    void liveness(void)
        {
        bool changed = true;
        while (changed)
            {
            changed = false;
            u32 bi = _nb;
            while (bi > (u32)0)
                {
                bi = bi - (u32)1;
                BitSet* out = BitSet.withCapacity(_nv);
                out.copyFrom((BitSet*)_phiEdge.get(bi));
                Array* succ = (Array*)_succ.get(bi);
                for (u32 i = (u32)0; i < succ.count(); i = i + (u32)1)
                    {
                    u32 sn = ((Number*)succ.get(i)).asU32();
                    BitSet* sin = BitSet.withCapacity(_nv);
                    sin.copyFrom((BitSet*)_liveIn.get(sn));
                    sin.minusWith((BitSet*)_phiResAt.get(sn));
                    out.unionWith(sin);
                    }
                BitSet* live = BitSet.withCapacity(_nv);
                live.copyFrom((BitSet*)_ueUse.get(bi));
                BitSet* od = BitSet.withCapacity(_nv);
                od.copyFrom(out);
                od.minusWith((BitSet*)_defSet.get(bi));
                live.unionWith(od);
                if (!out.sameAs((BitSet*)_liveOut.get(bi)) || !live.sameAs((BitSet*)_liveIn.get(bi)))
                    {
                    _liveOut.set(bi, (Object*)out);
                    _liveIn.set(bi, (Object*)live);
                    changed = true;
                    }
                }
            }
        }

    // Positions are DOUBLED so that a value defined at p and one last read at p
    // do not overlap: the definition starts at 2p+1, a use ends at 2p.
    void intervals(void)
        {
        _start = new Array();
        _end = new Array();
        for (u32 i = (u32)0; i < _nv; i = i + (u32)1)
            {
            _start.add((Object*)0);
            _end.add((Object*)0);
            }
        Array* endByVal = new Array();
        for (u32 i = (u32)0; i < _nv; i = i + (u32)1)
            endByVal.add((Object*)0);
        for (u32 bi = (u32)0; bi < _nb; bi = bi + (u32)1)
            {
            u32 be = (u32)2 * ((Number*)_blkEnd.get(bi)).asU32() + (u32)2;
            BitSet* lo = (BitSet*)_liveOut.get(bi);
            for (u32 v = (u32)0; v < _nv; v = v + (u32)1)
                {
                if (!lo.has(v))
                    continue;
                Object* cur = endByVal.get(v);
                if (cur == 0 || be > ((Number*)cur).asU32())
                    endByVal.set(v, (Object*)Number.with(be));
                }
            }
        for (u32 v = (u32)0; v < _nv; v = v + (u32)1)
            {
            Object* dp = _defPos.get(v);
            Object* lu = _lastUse.get(v);
            Object* eb = endByVal.get(v);
            if (dp == 0 && lu == 0 && eb == 0)
                continue;
            u32 st = dp == 0 ? (u32)0 : (u32)2 * ((Number*)dp).asU32() + (u32)1;
            u32 en = st;
            if (lu != 0)
                {
                u32 e2 = (u32)2 * ((Number*)lu).asU32();
                if (e2 > en)
                    en = e2;
                }
            if (eb != 0)
                {
                u32 e3 = ((Number*)eb).asU32();
                if (e3 > en)
                    en = e3;
                }
            _start.set(v, (Object*)Number.with(st));
            _end.set(v, (Object*)Number.with(en));
            }
        _crossesCall = BitSet.withCapacity(_nv);
        for (u32 v = (u32)0; v < _nv; v = v + (u32)1)
            {
            Object* so = _start.get(v);
            if (so == 0)
                continue;
            u32 s = ((Number*)so).asU32();
            u32 e = ((Number*)_end.get(v)).asU32();
            for (u32 i = (u32)0; i < _callPos.count(); i = i + (u32)1)
                {
                u32 c = (u32)2 * ((Number*)_callPos.get(i)).asU32();
                if (s <= c && c <= e)
                    {
                    _crossesCall.add(v);
                    i = _callPos.count();
                    }
                }
            }
        }

    // Every value that could take a register, split by class and ordered by how
    // often it is read — most-used first, ties by id so the answer is a property
    // of the program and not of a hash order.
    void candidates(Array* gp, Array* fp)
        {
        for (u32 v = (u32)0; v < _nv; v = v + (u32)1)
            {
            if (_start.get(v) == 0)
                continue;
            if (_excluded.has(v))
                continue;
            if (((Number*)_useCount.get(v)).asU32() == (u32)0)
                continue; // never read
            IRValue* val = _fn.valueWithId(v);
            if (val == 0 || val.ty() == 0)
                continue;
            String* t = val.ty();
            if (t.equals(String.withCString("Mem")) || t.equals(String.withCString("Void")) || t.hasPrefix(String.withCString("Agg(")))
                continue;
            if (Homing.isFloatTy(t))
                fp.add((Object*)Number.with(v));
            else
                gp.add((Object*)Number.with(v));
            }
        sortByUses(gp);
        sortByUses(fp);
        }

    void sortByUses(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            u32 j = i;
            while (j > (u32)0 && lessThan((Number*)a.get(j), (Number*)a.get(j - (u32)1)))
                {
                Object* t = a.get(j - (u32)1);
                a.set(j - (u32)1, a.get(j));
                a.set(j, t);
                j = j - (u32)1;
                }
            }
        }

    bool lessThan(Number* a, Number* b)
        {
        u32 ua = ((Number*)_useCount.get(a.asU32())).asU32();
        u32 ub = ((Number*)_useCount.get(b.asU32())).asU32();
        if (ua != ub)
            return ua > ub;
        Object* ra = _rank.get((Hashable*)a);
        Object* rb = _rank.get((Hashable*)b);
        u32 ka = ra == (Object*)0 ? a.asU32() + (u32)1000000 : ((Number*)ra).asU32();
        u32 kb = rb == (Object*)0 ? b.asU32() + (u32)1000000 : ((Number*)rb).asU32();
        return ka < kb;
        }

    // Caller-saved first (no prologue cost), then callee-saved. A value that
    // crosses a call may only take the callee tier; a phi result takes a
    // register exclusively, because its edge copies write it outside the range
    // the interval model knows about.
    static bool hasReg(Array* a, String* r)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(r))
                return true;
        return false;
        }

    void assign(Array* cands, Array* callee, Array* caller)
        {
        Array* pool = new Array();
        for (u32 i = (u32)0; i < caller.count(); i = i + (u32)1)
            pool.add(caller.get(i));
        for (u32 i = (u32)0; i < callee.count(); i = i + (u32)1)
            pool.add(callee.get(i));
        u32 nr = pool.count();
        if (nr == (u32)0)
            return;
        Array* regIvls = new Array();
        Array* exclusive = new Array();
        for (u32 i = (u32)0; i < nr; i = i + (u32)1)
            {
            regIvls.add((Object*)new Array());
            exclusive.add((Object*)Number.with((u32)0));
            }
        for (u32 ci = (u32)0; ci < cands.count(); ci = ci + (u32)1)
            {
            u32 v = ((Number*)cands.get(ci)).asU32();
            u32 s = ((Number*)_start.get(v)).asU32();
            u32 e = ((Number*)_end.get(v)).asU32();
            bool isPhi = _phiResults.has(v);
            bool mayUseCaller = !_crossesCall.has(v);
            i32 chosen = (i32)-1;
            for (u32 r = (u32)0; r < nr && chosen < (i32)0; r = r + (u32)1)
                {
                if (!mayUseCaller && r < caller.count())
                    continue;
                if (((Number*)exclusive.get(r)).asU32() != (u32)0)
                    continue;
                Array* ivls = (Array*)regIvls.get(r);
                if (isPhi)
                    {
                    if (ivls.count() == (u32)0)
                        chosen = (i32)r;
                    continue;
                    }
                bool ok = true;
                for (u32 k = (u32)0; k < ivls.count() && ok; k = k + (u32)1)
                    {
                    Interval* iv = (Interval*)ivls.get(k);
                    if (s <= iv.hi() && iv.lo() <= e)
                        ok = false;
                    }
                if (ok)
                    chosen = (i32)r;
                }
            if (chosen < (i32)0)
                continue; // unhomed: stays in its slot
            String* reg = (String*)pool.get((u32)chosen);
            _home.set((Hashable*)Number.with(v), (Object*)reg);
            ((Array*)regIvls.get((u32)chosen)).add((Object*)Interval.with(s, e));
            if (isPhi)
                exclusive.set((u32)chosen, (Object*)Number.with((u32)1));
            // A caller-saved home needs no prologue save; a callee-saved one is
            // recorded once, in pool order.
            if ((u32)chosen >= caller.count() && !hasReg(_usedCallee, reg))
                _usedCallee.add((Object*)reg);
            }
        }

    // The register a value was homed in, or 0.
    String* homeOf(u32 v)
        {
        Object* o = _home.get((Hashable*)Number.with(v));
        return o == 0 ? (String*)0 : (String*)o;
        }
    }
