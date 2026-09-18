// Opt.xc — the IR optimiser, ported: the pipeline and the passes it runs.
// =========================================================================
//
// self-hosting M13. The front end and the back end are ported and at parity;
// between them sits `XTIROpt*` — twenty-odd passes that run inside `xtcg-<arch>`
// and decide what the production `-O3` build actually looks like. Until they
// are here too, a program built by the ported chain is an `-O0` program.
//
// The oracle costs nothing, exactly as `Lower.xc`'s did: `xtcg-<arch> -O<n>
// --dump-opt-ir` prints the IR the pipeline produced, and the ported pipeline
// has to print the same text. `selfhost/tools/opt-diff.sh <target> <level>` is
// the harness, and every `.xc` in the tree is a case.
//
// A pass the port does not have yet is not silently skipped: the pipeline
// reports it by name (exit 3), so the list of what is missing is the work
// queue rather than a mystery diff.

#import "Foundation.xc"
#import "Ir.xc"

// A sentinel count from lrcCountLiveOut: a value OTHER than the accumulator
// escapes the outer loop, so the collapse is unsafe. Distinct from 0, which
// means the accumulator itself is dead afterwards (nothing to rescale).
#define LRC_LEAK $FFFFFFFF

// The per-target knobs. `XTIROptTargetProfile` is a conservative base with an
// arm64/arm9 relaxation on top; only the knobs a ported pass actually consults
// are here, and each one arrives with the pass that reads it.
class OptProfile
    {
    bool _nativeVarargs;     // arm9: VaStart/VaArg never reach the buffer form
    bool _sqrtIntrinsic;     // a target whose backend has a sqrt instruction
    bool _powSquare;         // …and one where x*x beats a call to pow
    bool _ifConvert;         // a predicate diamond becomes a branchless Select
    // May a callee taking an aggregate BY VALUE be inlined? Such a parameter is
    // only read through AddrOf(param), which after inlining becomes AddrOf of
    // the caller's LOADED Agg temp — not reliably addressable on the 6502.
    bool _inlineAggParams;
    bool _vectorize;         // map/reduce kernels go to SIMD
    bool _highMul;           // back end lowers VMulHi/VLShr (constant divide)
    bool _reductionCollapse; // an invariant reduction nest collapses
    bool _memsetIdiom;       // a byte-fill loop becomes one MemSet
    bool _initGuardElim;     // a redundant static-init guard comes out
    bool _initGuardHoist;    // …and one guard per class moves to the entry
    bool _tailRecursion;     // self-recursion in tail position becomes a loop
    bool _accumRecursion;    // …and so does `return g + f(x)` (in-order cores)
    // loop-unroll caps. The conservative defaults are the constants the pass
    // shipped with, sized so an unroll cannot tip a 6502 code bank; the bigger
    // targets relax them. `_unrollFrameIds` is arm64's slot-offset gate — 0
    // here stands for the original's NSUIntegerMax (no gate).
    u32 _unrollMaxTrip;
    u32 _unrollMaxBody;
    u32 _unrollBudget;
    bool _unrollMultiCarried;
    bool _unrollCallsInBody;
    u32 _unrollFrameIds;
    bool _pointerIV;       // loop array addressing becomes an advancing phi
    bool _unrollVarTrip;   // …and a variable-trip loop partially unrolls
    bool _licm;            // loop-invariant code moves to the preheader
    bool _hoistGlobalAddr; // …and a repeated AddrOf @sym dedupes to the entry
    bool _narrowIV;        // a counted IV is recomputed at its smallest width
    bool _loopRotate;      // top-tested loops become bottom-tested

    void init(void)
        {
        _nativeVarargs = false;
        _sqrtIntrinsic = false;
        _powSquare = false;
        _ifConvert = false;
        _inlineAggParams = false;
        _tailRecursion = false;
        _accumRecursion = false;
        _vectorize = false;
        _highMul = false;
        _reductionCollapse = false;
        _memsetIdiom = false;
        _initGuardElim = false;
        _initGuardHoist = false;
        _unrollMaxTrip = (u32)4;
        _unrollMaxBody = (u32)8;
        _unrollBudget = (u32)512;
        _unrollMultiCarried = false;
        _unrollCallsInBody = false;
        _unrollFrameIds = (u32)0;
        _pointerIV = false;
        _unrollVarTrip = false;
        _licm = false;
        _hoistGlobalAddr = false;
        _narrowIV = false;
        _loopRotate = false;
        }

    static OptProfile* forTarget(String* t)
        {
        OptProfile* p = new OptProfile();
        // Tier-1 is on everywhere; Tier-2 (accumulator recursion) only where the
        // campaign measured a win — an in-order core, where the call overhead is
        // not hidden.
        p._tailRecursion = true;
        p._ifConvert = true; // every live target if-converts
        // Aggregates are ordinary addressable memory on the register machines.
        p._inlineAggParams = t.equals(String.withCString("arm64"))
                          || t.equals(String.withCString("x86_64"))
                          || t.equals(String.withCString("win64"));
        p._initGuardElim = true;
        // The 6502 and the 68000 backends do not lower MemSet, so the idiom
        // stays a loop there.
        // arm9 leaves the reduction collapse OFF: its trip-1 rewrite and
        // reduction-nest surgery mis-lower there (see the target profile).
        // wasm32 keeps the base-profile NO (§9: measure under a real engine
        // before turning loop surgery on).
        p._reductionCollapse = !(t.equals(String.withCString("arm9")) || t.equals(String.withCString("wasm32")));
        // NEON on arm9/arm64, SSE on x86_64, v128 on wasm32 (W4); the 6502
        // and the 68000 have no vector unit and their profiles say so.
        p._vectorize = t.equals(String.withCString("arm9")) || t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")) || t.equals(String.withCString("wasm32"));
        // umull/umull2 + uzp2 build the high half of a 32x32 lane product
        // and ushr does the post-shift, so constant division vectorises on
        // arm64. The other vectorising back ends have no lowering yet, and
        // the pass leaves those loops scalar rather than emitting an opcode
        // they would drop.
        p._highMul = t.equals(String.withCString("arm64"));
        p._memsetIdiom = !(t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")) || t.equals(String.withCString("atarist")));
        // The 6502 does NOT hoist: an eager init at entry costs it more than
        // the guard it saves.
        p._initGuardHoist = !(t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")));
        if (t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")) || t.equals(String.withCString("atarist")))
            p._accumRecursion = true;
        if (t.equals(String.withCString("arm9")))
            {
            p._nativeVarargs = true;
            p._sqrtIntrinsic = true;
            p._powSquare = true;
            }
        // arm64 also uses the native AAPCS va_list (bug 179), so VaStart/VaArg
        // stay abstract for the backend and the pack-buffer expand is skipped.
        if (t.equals(String.withCString("arm64")))
            p._nativeVarargs = true;
        // arm64, x86_64 and win64 (which uses the x86_64 profile) have a
        // hardware sqrt; the 6502 and the 68000 do not, and their profiles say
        // so — the pass is a no-op there rather than a different lowering.
        // f32.sqrt/f64.sqrt; f64.mul is IEEE
        if (t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")) || t.equals(String.withCString("wasm32")))
            {
            p._sqrtIntrinsic = true;
            p._powSquare = true;
            }
        // Unroll caps, per target. xt6502 keeps the conservative defaults — its
        // 16 KB code bank cannot absorb a large unroll. m68k and arm9 take the
        // moderate set; arm64 and x86_64/win64 the large one, and only arm64
        // opts into unrolling CALL bodies (frame-gated, since each clone
        // allocates fresh value ids and those size its stack frame).
        if (t.equals(String.withCString("atarist")) || t.equals(String.withCString("arm9")))
            {
            p._unrollMaxTrip = (u32)16;
            p._unrollMaxBody = (u32)32;
            p._unrollBudget = (u32)4096;
            p._unrollMultiCarried = true;
            }
        if (t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")))
            {
            p._unrollMaxTrip = (u32)32;
            p._unrollMaxBody = (u32)64;
            p._unrollBudget = (u32)8192;
            p._unrollMultiCarried = true;
            }
        if (t.equals(String.withCString("arm64")))
            {
            p._unrollCallsInBody = true;
            p._unrollFrameIds = (u32)1900;
            }
        // wasm32: modest caps between the 6502's 4/8 and arm64's 32/64 —
        // code size is download size (XTIRWasm32TargetProfile).
        if (t.equals(String.withCString("wasm32")))
            {
            p._unrollMaxTrip = (u32)8;
            p._unrollMaxBody = (u32)24;
            p._unrollBudget = (u32)2048;
            p._unrollMultiCarried = true;
            }
        // A walking pointer beats a scaled-index recompute everywhere with
        // address registers or a wide GP file. The 6502 has neither — its
        // ZP walking pointer plus per-iteration advance costs more than the
        // index arithmetic it replaces — so it stays off there.
        // wasm32: pointer-IV OFF until measured under a real engine (§9).
        p._pointerIV = !(t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")) || t.equals(String.withCString("wasm32")));
        // Variable-trip partial unrolling is kernel-dependent on the 68000 —
        // the extra live values an unrolled body carries spill — so it stays
        // off there as well as on the 6502.
        p._unrollVarTrip = t.equals(String.withCString("arm64")) || t.equals(String.withCString("arm9")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
        // LICM is on for every live target. The global-address hoist is on
        // everywhere EXCEPT wasm32 — there a data address IS an i32 const,
        // so hoisting it to a local buys nothing.
        p._licm = true;
        p._hoistGlobalAddr = !t.equals(String.withCString("wasm32"));
        // Narrowing the induction variable pays where the compare and the
        // increment get cheaper at a smaller width — the 8-bit and the 16-bit
        // targets. The 32-bit ones already compare at their natural width.
        p._narrowIV = t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")) || t.equals(String.withCString("atarist"));
        // Every live target rotates except the 6502.
        p._loopRotate = !(t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")));
        return p;
        }

    bool nativeVarargs(void)
        {
        return _nativeVarargs;
        }
    bool sqrtIntrinsic(void)
        {
        return _sqrtIntrinsic;
        }
    bool powSquare(void)
        {
        return _powSquare;
        }
    bool ifConvert(void)
        {
        return _ifConvert;
        }
    bool inlineAggParams(void)
        {
        return _inlineAggParams;
        }
    bool vectorize(void)
        {
        return _vectorize;
        }
    bool highMul(void)
        {
        return _highMul;
        }
    bool reductionCollapse(void)
        {
        return _reductionCollapse;
        }
    bool memsetIdiom(void)
        {
        return _memsetIdiom;
        }
    bool initGuardElim(void)
        {
        return _initGuardElim;
        }
    bool initGuardHoist(void)
        {
        return _initGuardHoist;
        }
    bool tailRecursion(void)
        {
        return _tailRecursion;
        }
    bool accumRecursion(void)
        {
        return _accumRecursion;
        }
    u32 unrollMaxTrip(void)
        {
        return _unrollMaxTrip;
        }
    u32 unrollMaxBody(void)
        {
        return _unrollMaxBody;
        }
    u32 unrollBudget(void)
        {
        return _unrollBudget;
        }
    bool unrollMultiCarried(void)
        {
        return _unrollMultiCarried;
        }
    bool unrollCallsInBody(void)
        {
        return _unrollCallsInBody;
        }
    u32 unrollFrameIds(void)
        {
        return _unrollFrameIds;
        }
    bool pointerIV(void)
        {
        return _pointerIV;
        }
    bool unrollVarTrip(void)
        {
        return _unrollVarTrip;
        }
    bool licm(void)
        {
        return _licm;
        }
    bool hoistGlobalAddr(void)
        {
        return _hoistGlobalAddr;
        }
    bool narrowIV(void)
        {
        return _narrowIV;
        }
    bool loopRotate(void)
        {
        return _loopRotate;
        }
    }

    // A natural loop discovered from a back edge, for loop-reduction-collapse.
    // The original keeps block INDICES; blocks here are objects, and identity is
    // the only thing the pass compares, so it keeps the blocks themselves. A null
    // preheader is the original's -1 ("not unique").
    class LRCLoop
    {
    IRBlock* _header;
    IRBlock* _latch;
    IRBlock* _pre;
    Array* _body;

    void init(void)
        {
        _body = new Array();
        }

    IRBlock* header(void)
        {
        return _header;
        }
    IRBlock* latch(void)
        {
        return _latch;
        }
    IRBlock* pre(void)
        {
        return _pre;
        }
    Array* body(void)
        {
        return _body;
        }
    void setHeader(IRBlock* b)
        {
        _header = b;
        }
    void setLatch(IRBlock* b)
        {
        _latch = b;
        }
    void setPre(IRBlock* b)
        {
        _pre = b;
        }
    }

    // A value carried across iterations besides the induction variable — an
    // accumulator / reduction header phi. `seed` is its value on the preheader
    // edge, `next` the value the body feeds back. Both are SSA uses: the lowering
    // never threads an immediate through a phi.
    class LUCarried
    {
    IRValue* _phi;
    IROperand* _seed;
    IROperand* _next;

    void init(void)
        {
        }
    IRValue* phi(void)
        {
        return _phi;
        }
    IROperand* seed(void)
        {
        return _seed;
        }
    IROperand* next(void)
        {
        return _next;
        }
    void set(IRValue* p, IROperand* s, IROperand* n)
        {
        _phi = p;
        _seed = s;
        _next = n;
        }
    }

    // A recognised unrollable loop: header, single-block body/latch, exit,
    // preheader, the induction phi and its closed-form start/step/trip.
    class LUCand
    {
    IRBlock* _h;
    IRBlock* _b;
    IRBlock* _e;
    IRBlock* _p;
    IRInsn* _phi;
    String* _ivTy;
    i32 _start;
    i32 _step;
    u32 _trip;
    Array* _carried;

    void init(void)
        {
        _carried = new Array();
        _start = (i32)0;
        _step = (i32)0;
        _trip = (u32)0;
        }

    IRBlock* h(void)
        {
        return _h;
        }
    IRBlock* b(void)
        {
        return _b;
        }
    IRBlock* e(void)
        {
        return _e;
        }
    IRBlock* p(void)
        {
        return _p;
        }
    IRInsn* phi(void)
        {
        return _phi;
        }
    String* ivTy(void)
        {
        return _ivTy;
        }
    i32 start(void)
        {
        return _start;
        }
    i32 step(void)
        {
        return _step;
        }
    u32 trip(void)
        {
        return _trip;
        }
    Array* carried(void)
        {
        return _carried;
        }

    void setBlocks(IRBlock* h, IRBlock* b, IRBlock* e, IRBlock* p)
        {
        _h = h;
        _b = b;
        _e = e;
        _p = p;
        }
    void setIv(IRInsn* phi, String* ty, i32 s, i32 st, u32 t)
        {
        _phi = phi;
        _ivTy = ty;
        _start = s;
        _step = st;
        _trip = t;
        }
    void setCarried(Array* c)
        {
        _carried = c;
        }
    }

    // A recognised vectorisable loop. The map fields (header, body, exit, the
    // induction phi and its step, the lane type and how many lanes fit a vector)
    // describe every shape; the reduction shapes add their accumulator on top.
    class VecCand
    {
    // Per-UDiv magic recorded by the recogniser; see _vrDivMagic.
    Map* _divMagic;
    IRBlock* _h;
    IRBlock* _b;
    IRBlock* _e;
    IRInsn* _ivPhi;
    IRInsn* _ivNext;
    IRInsn* _guard;
    IRValue* _iv;
    String* _laneTy;
    u32 _vw; // lanes per vector — 4 for a 32-bit lane
    // Epilogue: when the trip count is not a whole number of vectors, the vector
    // loop stops at _epiM and a CLONE of the scalar loop runs the tail.
    bool _needEpi;
    i32 _epiM;

    void init(void)
        {
        _vw = (u32)0;
        _needEpi = false;
        _epiM = (i32)0;
        _rtTrip = false;
        _bound = (IROperand*)0;
        _ivStart = (i32)0;
        }

    IRBlock* h(void)
        {
        return _h;
        }
    IRBlock* b(void)
        {
        return _b;
        }
    IRBlock* e(void)
        {
        return _e;
        }
    IRInsn* ivPhi(void)
        {
        return _ivPhi;
        }
    IRInsn* ivNext(void)
        {
        return _ivNext;
        }
    IRInsn* guard(void)
        {
        return _guard;
        }
    IRValue* iv(void)
        {
        return _iv;
        }
    String* laneTy(void)
        {
        return _laneTy;
        }
    u32 vw(void)
        {
        return _vw;
        }
    bool needEpi(void)
        {
        return _needEpi;
        }
    i32 epiM(void)
        {
        return _epiM;
        }
    void setEpi(bool need, i32 m)
        {
        _needEpi = need;
        _epiM = m;
        }
    // A RUNTIME trip count: the vector limit M = n & ~(vw-1) is computed in the
    // preheader, so _epiM is meaningless and the clone's induction phi is seeded
    // from that VALUE rather than an immediate.
    bool _rtTrip;
    IROperand* _bound;
    // The iv's (constant) entry value. The runtime-trip limit M must be
    // computed from the trip LENGTH (n - ivStart), not the bound: see
    // vecRuntimeLimit.
    i32 _ivStart;
    bool rtTrip(void)
        {
        return _rtTrip;
        }
    IROperand* bound(void)
        {
        return _bound;
        }
    i32 ivStart(void)
        {
        return _ivStart;
        }
    void setRuntime(bool r, IROperand* b)
        {
        _rtTrip = r;
        _bound = b;
        }
    void setIvStart(i32 s)
        {
        _ivStart = s;
        }

    void setLoop(IRBlock* h, IRBlock* b, IRBlock* e)
        {
        _h = h;
        _b = b;
        _e = e;
        }
    void setIv(IRInsn* phi, IRInsn* next, IRInsn* g, IRValue* v)
        {
        _ivPhi = phi;
        _ivNext = next;
        _guard = g;
        _iv = v;
        }
    void setLane(String* t, u32 w)
        {
        _laneTy = t;
        _vw = w;
        }

    // The ELEMENT's lane, when it is narrower than the accumulator's. Only the
    // widening paths set it; everything else leaves it nil and the two widths
    // are the same.
    void setLoadLane(String* lt)
        {
        _loadLaneTy = lt;
        }

    // Additive-reduction fields: the loop carries a second phi whose back-edge
    // value is `accNext = Add(acc, elem)` with `elem` an iv-indexed elementwise
    // value. The map fields above still describe the induction variable.
    IRInsn* _accPhi;
    IRInsn* _accNext;
    IRValue* _acc;
    IRValue* _elem;
    IROperand* _seed;
    IRBlock* _pre;

    IRInsn* accPhi(void)
        {
        return _accPhi;
        }
    IRInsn* accNext(void)
        {
        return _accNext;
        }
    IRValue* acc(void)
        {
        return _acc;
        }
    Map* divMagic(void)
        {
        return _divMagic;
        }
    void setDivMagic(Map* m)
        {
        _divMagic = m;
        }
    IRValue* elem(void)
        {
        return _elem;
        }
    IROperand* seed(void)
        {
        return _seed;
        }
    IRBlock* pre(void)
        {
        return _pre;
        }
    void setReduction(IRInsn* ap, IRInsn* an, IRValue* a, IRValue* el,
                      IROperand* s, IRBlock* p)
        {
        _accPhi = ap;
        _accNext = an;
        _acc = a;
        _elem = el;
        _seed = s;
        _pre = p;
        }

    // A MAP has no accumulator but still needs its preheader, to reseed the
    // remainder loop's phis when an epilogue is taken.
    void setPre(IRBlock* p)
        {
        _pre = p;
        }

    // Min/max reduction: the body is a diamond
    //   body: load elem; cmp(elem,acc); CondBranch then, join
    //   then: [reload elem]; Branch join
    //   join: accNext = Phi[(body,acc),(then,elem)]; ivNext; Branch H
    // `_b` holds the diamond head; `_mmThen` and `_mmLatch` the arm and join.
    bool _isMax;
    IRBlock* _mmThen;
    IRBlock* _mmLatch;

    bool isMax(void)
        {
        return _isMax;
        }
    IRBlock* mmThen(void)
        {
        return _mmThen;
        }
    IRBlock* mmLatch(void)
        {
        return _mmLatch;
        }
    void setMaxMin(bool mx, IRBlock* th, IRBlock* l)
        {
        _isMax = mx;
        _mmThen = th;
        _mmLatch = l;
        }

    // Count reduction: `if (a[i] <cmp> k) n += delta`, which reaches the
    // vectoriser already if-converted to a Select, so the body is ONE block.
    // `_cmp` is the per-lane compare and `_delta` the invariant increment.
    IRInsn* _cmp;
    IROperand* _delta;
    IRInsn* cmpInsn(void)
        {
        return _cmp;
        }
    IROperand* delta(void)
        {
        return _delta;
        }
    void setCount(IRInsn* cm, IROperand* d, IRBlock* l)
        {
        _cmp = cm;
        _delta = d;
        _mmLatch = l;
        }

    // Widening sum: `acc:u32 += (u32)a[i]` over a u8/u16 array. The narrow load
    // is vector-loaded (16×u8 / 8×u16) and folded into a 4×u32 accumulator by
    // repeated pairwise widening. Dot product is the same with a second load and
    // a narrow-lane multiply in front.
    bool _isDot;
    String* _loadLaneTy;
    IRValue* _load;
    IRValue* _load2;

    bool isDot(void)
        {
        return _isDot;
        }
    String* loadLaneTy(void)
        {
        return _loadLaneTy;
        }
    IRValue* load(void)
        {
        return _load;
        }
    IRValue* load2(void)
        {
        return _load2;
        }
    void setWidening(String* lt, IRValue* l1, IRValue* l2, bool dot)
        {
        _loadLaneTy = lt;
        _load = l1;
        _load2 = l2;
        _isDot = dot;
        }
    }

    // A recognised single-block-body VARIABLE-trip loop. Unlike the const-trip
    // unroller this one cannot know the count, so it emits `kUnrollFactor` copies
    // each guarded by its own compare, and the last one takes the back edge.
    class VTCand
    {
    IRBlock* _h;
    IRBlock* _b;
    IRBlock* _e;
    IRInsn* _ivPhi;
    IRInsn* _guard;
    IRInsn* _ivNext;
    IRValue* _iv;
    IROperand* _step; // the loop-invariant addend of ivNext
    bool _stepIsConst;
    i32 _stepK;
    // The trip is a compile-time constant that divides EXACTLY by the
    // unroll factor AND the body is vector, so the intermediate copies'
    // guards are provably true and are not emitted.
    bool _exactTrip;
    // YES when the body computes vector values. Both the guard removal and
    // the pointer re-basing are gated on it: each trades a longer live range
    // for fewer instructions, which a vector body (values in the separate
    // v18-v31 pool) absorbs and a GP-bound scalar body pays for in spills.
    bool _vectorBody;
    // Carried accumulators threaded alongside the induction variable.
    Array* _redPhis;  // the accumulator phis in the header
    Array* _redNexts; // their back-edge updates, in the body
    Array* _redVals;  // the phi results
    Array* _redEsc;   // Number: 1 when read outside the loop

    void init(void)
        {
        _redPhis = new Array();
        _redNexts = new Array();
        _redVals = new Array();
        _redEsc = new Array();
        _stepIsConst = false;
        _stepK = (i32)0;
        }

    IRBlock* h(void)
        {
        return _h;
        }
    IRBlock* b(void)
        {
        return _b;
        }
    IRBlock* e(void)
        {
        return _e;
        }
    IRInsn* ivPhi(void)
        {
        return _ivPhi;
        }
    IRInsn* guard(void)
        {
        return _guard;
        }
    IRInsn* ivNext(void)
        {
        return _ivNext;
        }
    IRValue* iv(void)
        {
        return _iv;
        }
    IROperand* step(void)
        {
        return _step;
        }
    bool stepIsConst(void)
        {
        return _stepIsConst;
        }
    i32 stepK(void)
        {
        return _stepK;
        }
    Array* redPhis(void)
        {
        return _redPhis;
        }
    Array* redNexts(void)
        {
        return _redNexts;
        }
    Array* redVals(void)
        {
        return _redVals;
        }
    Array* redEsc(void)
        {
        return _redEsc;
        }

    void setLoop(IRBlock* h, IRBlock* b, IRBlock* e)
        {
        _h = h;
        _b = b;
        _e = e;
        }
    void setIv(IRInsn* p, IRInsn* g, IRInsn* nx, IRValue* v)
        {
        _ivPhi = p;
        _guard = g;
        _ivNext = nx;
        _iv = v;
        }
    bool exactTrip(void)
        {
        return _exactTrip;
        }
    bool vectorBody(void)
        {
        return _vectorBody;
        }
    void setVectorBody(bool v)
        {
        _vectorBody = v;
        }
    void setExactTrip(bool v)
        {
        _exactTrip = v;
        }
    void setStep(IROperand* s, bool isK, i32 k)
        {
        _step = s;
        _stepIsConst = isK;
        _stepK = k;
        }
    }

    class Opt
    {
    u32 _level;
    OptProfile* _profile;
    bool _failed;
    String* _why;
    // Stop after the named pass — the per-pass oracle. Without it a pass can
    // only be measured once every pass before it in the pipeline is ported,
    // which makes a twenty-pass level all-or-nothing.
    String* _stopAfter;

    // Library build (--emit-lib): the whole module is the API surface, so
    // dead-function-elim seeds EVERY function (the twin of the oracle's
    // +[XTIROptDeadFunctionElim setKeepAllFunctions:]).
    bool _keepAllFunctions;

    void init(void)
        {
        _level = (u32)0;
        _failed = false;
        }

    void setStopAfter(String* n)
        {
        _stopAfter = n;
        }
    void setKeepAllFunctions(bool on)
        {
        _keepAllFunctions = on;
        }

    // True when the pipeline should stop here — the caller returns.
    bool stopHere(String* passName)
        {
        return _stopAfter != 0 && _stopAfter.equals(passName);
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

    static Opt* atLevel(u32 level, OptProfile* profile)
        {
        Opt* o = new Opt();
        o._level = level;
        o._profile = profile;
        return o;
        }

    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    void giveUp(String* w)
        {
        if (_failed)
            return;
        _failed = true;
        _why = w;
        }

    // The pipeline, in the original's order. Each pass is gated on the level it
    // declares (`minOptLevel`) and, where it has one, on a profile knob.
    void run(IRModule* m)
        {
        // VaArgExpand is MANDATORY at every level — the backend has no case for
        // the abstract VaStart/VaArg — but a native-varargs target has already
        // passed its tail in registers and there is nothing to expand.
        if (!_profile.nativeVarargs())
            vaArgExpand(m);
        if (stopHere(String.withCString("vaarg-expand")))
            return;
        if (_level >= (u32)1)
            deadFunctionElim(m);
        if (stopHere(String.withCString("dead-function-elim")))
            return;
        if (_level >= (u32)1)
            sqrtIntrinsic(m);
        if (stopHere(String.withCString("sqrt-intrinsic")))
            return;
        if (_level >= (u32)2)
            powSquare(m);
        if (stopHere(String.withCString("pow-square")))
            return;
        if (_level >= (u32)2)
            arcSelfRetain(m);
        if (stopHere(String.withCString("arc-self-retain")))
            return;
        if (_level >= (u32)2)
            inlineLeaves(m);
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
            narrow(m);
        if (stopHere(String.withCString("narrow")))
            return;
        if (_level >= (u32)2)
            tailRecursion(m);
        if (_failed)
            return;
        if (stopHere(String.withCString("tail-recursion")))
            return;
        if (_level >= (u32)2)
            ifConvert(m);
        if (stopHere(String.withCString("if-convert")))
            return;
        if (_level >= (u32)2)
            jumpThread(m);
        if (stopHere(String.withCString("jump-thread")))
            return;
        if (_level >= (u32)2)
            staticInitGuard(m);
        if (stopHere(String.withCString("static-init-guard-elim")))
            return;
        if (_level >= (u32)2)
            idiomMemset(m);
        if (stopHere(String.withCString("idiom-memset")))
            return;
        if (_level >= (u32)2)
            deadCode(m);
        if (stopHere(String.withCString("dead-code")))
            return;
        if (_level >= (u32)2)
            loopReductionCollapse(m);
        if (stopHere(String.withCString("loop-reduction-collapse")))
            return;
        if (_level >= (u32)2)
            redundantLoadCSE(m);
        if (stopHere(String.withCString("redundant-load-cse")))
            return;
        if (_level >= (u32)2)
            vectorize(m);
        if (stopHere(String.withCString("vectorize")))
            return;
        if (_level >= (u32)2)
            loopUnroll(m);
        if (_failed)
            return;
        if (stopHere(String.withCString("loop-unroll")))
            return;
        // Dead code (including dead phis) comes out before the variable-trip
        // unroller, so a loop-carried value the lowering threads but never
        // reads cannot pin its source live and block the no-escape check.
        if (_level >= (u32)2)
            deadCode(m);
        if (stopHere(String.withCString("dead-code")))
            return;
        if (_level >= (u32)2)
            pointerIV(m);
        if (stopHere(String.withCString("pointer-iv")))
            return;
        if (_level >= (u32)2)
            loopUnrollVarTrip(m);
        if (stopHere(String.withCString("loop-unroll-vartrip")))
            return;
        if (_level >= (u32)2)
            strengthReduce(m);
        if (stopHere(String.withCString("strength-reduce")))
            return;
        if (_level >= (u32)2)
            constOperandFold(m);
        if (stopHere(String.withCString("const-operand-fold")))
            return;
        if (_level >= (u32)2)
            redundantLoadCSE(m);
        if (stopHere(String.withCString("redundant-load-cse")))
            return;
        if (_level >= (u32)2)
            licm(m);
        if (stopHere(String.withCString("licm")))
            return;
        if (_level >= (u32)2)
            constHoist(m);
        if (stopHere(String.withCString("const-hoist")))
            return;
        if (_level >= (u32)2)
            loopRotate(m);
        if (stopHere(String.withCString("loop-rotate")))
            return;
        if (_level >= (u32)2)
            narrowIV(m);
        if (stopHere(String.withCString("narrow-iv")))
            return;
        // The final sweep: pure instructions orphaned by everything above.
        if (_level >= (u32)2)
            deadCode(m);
        if (stopHere(String.withCString("dead-code")))
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
        }

    /************************************************************************\
    |* Drop every value the function still has registered that nothing defines.
    |*
    |* "Defines" is wider than an instruction's result, and the reference got it
    |* wrong in both directions it could:
    |*
    |*   * a MULTI-RESULT instruction (`%50:Agg, %51 = Load`) defines its memory
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

    void markDefsIn(Array* live, Array* insns, u32 n)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            markDefsOf(live, (IRInsn*)insns.get(i), n);
        }

    void markDefsOf(Array* live, IRInsn* i, u32 n)
        {
        markLive(live, i.res(), n);
        markLive(live, i.memRes(), n);
        }

    void markLive(Array* live, IRValue* v, u32 n)
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
    void deadFunctionElim(IRModule* m)
        {
        Array* reachable = new Array(); // String@ — names kept
        Array* work = new Array();

        // `main` is the canonical entry, and a load-time constructor is a root
        // even though nothing calls it: the backend emits the constructor list
        // after this pass, so the reference does not exist yet.
        seed(m, reachable, work, String.withCString("main"));
        for (u32 i = (u32)0; i < m.modinits().count(); i = i + (u32)1)
            seed(m, reachable, work, (String*)m.modinits().get(i));

        // Library mode: seed EVERY function — the module IS the API surface.
        if (_keepAllFunctions)
            for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
                seed(m, reachable, work, ((IRFunc*)m.funcs().get(i)).name());

        // A function symbol that ESCAPES may be called through a pointer, and
        // every vtable slot may be called through dispatch — neither is visible
        // at a call site.
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            if (s.kind() == (u8)SYM_FUNCTION)
                {
                if (s.escapes())
                    seed(m, reachable, work, s.name());
                // `extern`-on-a-definition = the module's public surface (a
                // wasm export): nothing in-module need call it — the HOST
                // does. A DFE-stripped export fails at instance.exports call
                // time, far from the build (wasm-target.md §6).
                if (s.attr(String.withCString("exported")))
                    seed(m, reachable, work, s.name());
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
            IRFunc* fn = funcNamed(m, name);
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
            if (has(reachable, fn.name()))
                survivors.add((Object*)fn);
            }
        if (survivors.count() == m.funcs().count())
            return;
        m.setFuncs(survivors);
        }

    // Every SYMBOL an instruction names is a reference: a call, an AddrOf, a
    // vtable — the pass does not distinguish, because any of them keeps the
    // function alive.
    void seedFromInsn(IRModule* m, Array* reachable, Array* work, IRInsn* n)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_SYM || o.name() == 0)
                continue;
            IRSymbol* s = symNamed(m, o.name());
            if (s == 0)
                {
                seed(m, reachable, work, o.name());
                continue;
                }
            if (s.kind() == (u8)SYM_VTABLE)
                seedSlots(m, reachable, work, s);
            else
                seed(m, reachable, work, s.name());
            }
        }

    void seedSlots(IRModule* m, Array* reachable, Array* work, IRSymbol* s)
        {
        if (s.slots() == 0)
            return;
        for (u32 k = (u32)0; k < s.slots().count(); k = k + (u32)1)
            seed(m, reachable, work, (String*)s.slots().get(k));
        }

    void seed(IRModule* m, Array* reachable, Array* work, String* name)
        {
        if (name == 0)
            return;
        if (funcNamed(m, name) == 0)
            return; // no body here to keep
        if (has(reachable, name))
            return;
        reachable.add((Object*)name);
        work.add((Object*)name);
        }

    bool has(Array* names, String* name)
        {
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (((String*)names.get(i)).equals(name))
                return true;
        return false;
        }

    IRFunc* funcNamed(IRModule* m, String* name)
        {
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)m.funcs().get(i);
            // The accessor is read ONCE deliberately — see private:docs/bugs/025.
            String* fn = f.name();
            if (fn == 0)
                continue;
            if (fn.equals(name))
                return f;
            }
        return (IRFunc*)0;
        }

    IRSymbol* symNamed(IRModule* m, String* name)
        {
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)m.syms().get(i);
            // Cached for the same reason funcNamed's is — private:docs/bugs/025.
            String* sn = s.name();
            if (sn != 0 && sn.equals(name))
                return s;
            }
        return (IRSymbol*)0;
        }
    // ── sqrt-intrinsic ───────────────────────────────────────────────────
    //
    // `sqrt(x)` is a library CALL in the IR and one instruction on a target
    // with a hardware sqrt. Rewriting it here, rather than name-matching in the
    // back end, is what lets the call be inlined-through and the now-callerless
    // extern dropped by the next dead-function sweep.
    void sqrtIntrinsic(IRModule* m)
        {
        if (!_profile.sqrtIntrinsic())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            sqrtInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    void sqrtInFunc(IRModule* m, IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!isSqrtCall(n))
                    continue;
                IROperand* arg = (IROperand*)n.ops().get((u32)1);
                IRInsn* fs = IRInsn.with(String.withCString("FSqrt"));
                fs.setRes(n.res());
                fs.add(arg);
                bb.insns().set(i, (Object*)fs);
                // sqrt is PURE: it produces no memory, so anything that used the
                // call's memory result now uses the call's memory INPUT.
                if (n.memRes() == 0)
                    continue;
                IROperand* memIn = (IROperand*)n.ops().get(n.ops().count() - (u32)1);
                if (memIn.kind() != (u8)OPK_USE)
                    continue;
                forwardMem(fn, n.memRes(), memIn.val());
                }
            }
        }

    // A one-argument call returning a float, to one of the four names a sqrt
    // reaches the IR under: libm's own (arm9 calls those directly) and the
    // `_xm_` intrinsic the arch libraries use.
    bool isSqrtCall(IRInsn* n)
        {
        if (!n.op().equals(String.withCString("Call")))
            return false;
        if (n.res() == 0)
            return false;
        String* t = n.res().ty();
        if (!t.equals(String.withCString("F32")) && !t.equals(String.withCString("F64")))
            return false;
        if (n.ops().count() != (u32)3)
            return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM || callee.name() == 0)
            return false;
        String* nm = callee.name();
        if (!nm.equals(String.withCString("sqrt")) && !nm.equals(String.withCString("sqrtf")) && !nm.equals(String.withCString("_xm_sqrt")) && !nm.equals(String.withCString("_xm_sqrtf")))
            return false;
        return ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE;
        }

    // Every use of `oldMem` in the function becomes a use of `newMem`.
    void forwardMem(IRFunc* fn, IRValue* oldMem, IRValue* newMem)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                rewriteUses((IRInsn*)bb.phis().get(i), oldMem, newMem);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                rewriteUses((IRInsn*)bb.insns().get(i), oldMem, newMem);
            if (bb.term() != 0)
                rewriteUses(bb.term(), oldMem, newMem);
            }
        }

    void rewriteUses(IRInsn* n, IRValue* oldMem, IRValue* newMem)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() != oldMem)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(newMem));
            }
        }
    // ── pow-square ───────────────────────────────────────────────────────
    //
    // `pow(x, 2)` is a call in the IR and a multiply everywhere else. It runs
    // BEFORE inlining, while the library wrapper's call is still there to match;
    // the wrapper and libm's `pow` are then dropped by the dead-function sweep.
    void powSquare(IRModule* m)
        {
        if (!_profile.powSquare())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            powInFunc((IRFunc*)m.funcs().get(f));
        }

    void powInFunc(IRFunc* fn)
        {
        Map* defOf = defMap(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!isPowCall(n, defOf))
                    continue;
                IROperand* base = (IROperand*)n.ops().get((u32)1);
                IRInsn* fm = IRInsn.with(String.withCString("FMul"));
                fm.setRes(n.res());
                fm.add(base);
                fm.add(base);
                bb.insns().set(i, (Object*)fm);
                if (n.memRes() == 0)
                    continue;
                IROperand* memIn = (IROperand*)n.ops().get(n.ops().count() - (u32)1);
                if (memIn.kind() != (u8)OPK_USE)
                    continue;
                forwardMem(fn, n.memRes(), memIn.val());
                }
            }
        }

    // `Math$pow__…(base, 2)` — a two-argument call returning a float whose
    // exponent resolves to the literal 2.
    bool isPowCall(IRInsn* n, Map* defOf)
        {
        if (!n.op().equals(String.withCString("Call")))
            return false;
        if (n.res() == 0)
            return false;
        String* t = n.res().ty();
        if (!t.equals(String.withCString("F32")) && !t.equals(String.withCString("F64")))
            return false;
        if (n.ops().count() != (u32)4)
            return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM || callee.name() == 0)
            return false;
        if (!callee.name().hasPrefix(String.withCString("Math$pow__")))
            return false;
        if (((IROperand*)n.ops().get((u32)1)).kind() != (u8)OPK_USE)
            return false;
        i32 exp = (i32)0;
        if (!resolveInt(defOf, (IROperand*)n.ops().get((u32)2), &exp))
            return false;
        return exp == (i32)2;
        }

    // The instruction that DEFINES each value, keyed by the value's own
    // identity — the port's operands hold values, not ids, so the key is the
    // value's address as a string of its print id would not be stable here.
    Map* defMap(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != 0)
                    defOf.set((Hashable*)p.res(), (Object*)p);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != 0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        return defOf;
        }

    // A compile-time integer, seen through the widening and int↔float
    // conversions the lowering wraps a literal in.
    bool resolveInt(Map* defOf, IROperand* op, i32* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == 0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!isWidening(def.op()))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    bool isWidening(String* op)
        {
        return op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp"));
        }
    // ── vaarg-expand ─────────────────────────────────────────────────────
    //
    // MANDATORY on every target whose varargs travel in the pack buffer: the
    // back end has no case for the abstract VaStart/VaArg, so they are gone by
    // the time it runs whatever the level. (arm9 passes its tail in registers
    // and lowers the ops itself, which is why the profile turns this off.)
    //
    // `VaStart` zeroes the cursor; `VaArg` reads `__xtc_va_buf[cursor]` at the
    // result type and advances. The expansion is the lowering's old inline one,
    // instruction for instruction.
    void vaArgExpand(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            vaInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    void vaInFunc(IRModule* m, IRFunc* fn)
        {
        if (!hasVaOps(fn))
            return;
        String* buf = vaBuffer(m);
        // old value -> its replacement; the originals leave the IR, so every
        // remaining use of one is rewritten in a second walk.
        Map* remap = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* out = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.op().equals(String.withCString("VaStart")))
                    expandVaStart(n, out, remap);
                else if (n.op().equals(String.withCString("VaArg")))
                    expandVaArg(m, n, out, remap, buf);
                else
                    out.add((Object*)n);
                }
            bb.setInsns(out);
            }
        applyRemap(fn, remap);
        }

    bool hasVaOps(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                String* op = ((IRInsn*)bb.insns().get(i)).op();
                if (op.equals(String.withCString("VaStart")) || op.equals(String.withCString("VaArg")))
                    return true;
                }
            }
        return false;
        }

    // The shared 128-byte pack buffer — found or made, exactly as the lowering
    // makes it, because a second one would be a second buffer.
    String* vaBuffer(IRModule* m)
        {
        String* name = String.withCString("__xtc_va_buf");
        if (symNamed(m, name) != 0)
            return name;
        IRLayout* l = IRLayout.with((u32)128, (u32)1);
        u32 id = m.addLayout(l);
        String* ty = String.withCString("Agg(");
        ty.appendFormat("%ld", (i32)id);
        ty.appendCString(")");
        m.addSym(IRSymbol.dataGlobal(name, ty));
        return name;
        }

    void push(Array* out, IRInsn* n)
        {
        out.add((Object*)n);
        }

    // What `readVaSlot` reports back alongside the value it produced: how far
    // the cursor moves, and which memory token the cursor's store follows.
    u32 _vaAdvance;
    IRValue* _vaMem;

    // Read one argument out of the buffer at `slotPtr`. Three shapes: a struct
    // stays IN the buffer and only its address is handed back; a narrow int was
    // widened by the packer and is read wide and truncated; everything else is
    // one load at its own type.
    IRValue* readVaSlot(IRModule* m, Array* out, String* resT,
                        IRValue* slotPtr, IRValue* m1)
        {
        if (isStructPtr(resT))
            {
            IRValue* r = new IRValue(resT);
            IRInsn* bc = IRInsn.with(String.withCString("Bitcast"));
            bc.setRes(r);
            bc.add(IROperand.useVal(slotPtr));
            push(out, bc);
            u32 w = aggWidth(m, resT);
            if (w > (u32)0)
                _vaAdvance = w;
            return r;
            }
        if (isNarrowInt(resT))
            {
            // The packer widened a narrow int to two bytes: read it wide and
            // truncate, or the high byte is read as the next argument.
            bool sgn = resT.equals(String.withCString("I8"));
            String* wide = String.withCString(sgn ? "I16" : "U16");
            IRValue* wv = new IRValue(wide);
            IRValue* m2 = new IRValue(String.withCString("Mem"));
            IRInsn* l2 = IRInsn.with(String.withCString("Load"));
            l2.setRes(wv);
            l2.setMemRes(m2);
            l2.add(IROperand.useVal(slotPtr));
            l2.add(IROperand.useVal(m1));
            push(out, l2);
            _vaMem = m2;
            IRValue* r = new IRValue(resT);
            IRInsn* tr = IRInsn.with(String.withCString("Trunc"));
            tr.setRes(r);
            tr.add(IROperand.useVal(wv));
            push(out, tr);
            return r;
            }
        IRValue* m2 = new IRValue(String.withCString("Mem"));
        IRValue* r = new IRValue(resT);
        IRInsn* l2 = IRInsn.with(String.withCString("Load"));
        l2.setRes(r);
        l2.setMemRes(m2);
        l2.add(IROperand.useVal(slotPtr));
        l2.add(IROperand.useVal(m1));
        push(out, l2);
        _vaMem = m2;
        return r;
        }

    IRValue* emitConstU8(Array* out, u32 v)
        {
        IRValue* c = new IRValue(String.withCString("U8"));
        IRInsn* n = IRInsn.with(String.withCString("Const"));
        n.setRes(c);
        n.add(IROperand.immU(v, String.withCString("U8")));
        push(out, n);
        return c;
        }

    // VaStart cursorAddr, memIn → Store(cursorAddr, 0:u8, memIn)
    void expandVaStart(IRInsn* va, Array* out, Map* remap)
        {
        IROperand* cursorAddr = (IROperand*)va.ops().get((u32)0);
        IROperand* memIn = (IROperand*)va.ops().get((u32)1);
        IRValue* zero = emitConstU8(out, (u32)0);
        IRValue* newMem = new IRValue(String.withCString("Mem"));
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        st.setMemRes(newMem);
        st.add(cursorAddr);
        st.add(IROperand.useVal(zero));
        st.add(memIn);
        push(out, st);
        if (va.memRes() != 0)
            remap.set((Hashable*)va.memRes(), (Object*)newMem);
        }

    void expandVaArg(IRModule* m, IRInsn* va, Array* out, Map* remap, String* buf)
        {
        IROperand* cursorAddr = (IROperand*)va.ops().get((u32)0);
        IROperand* memIn = (IROperand*)va.ops().get((u32)1);
        String* resT = va.res().ty();
        String* u8Ptr = String.withCString("Ptr(U8, unbanked)");

        IRValue* bufPtr = new IRValue(u8Ptr);
        IRInsn* ad = IRInsn.with(String.withCString("AddrOf"));
        ad.setRes(bufPtr);
        ad.add(IROperand.sym(buf));
        push(out, ad);

        IRValue* cursor = new IRValue(String.withCString("U8"));
        IRValue* m1 = new IRValue(String.withCString("Mem"));
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        ld.setRes(cursor);
        ld.setMemRes(m1);
        ld.add(cursorAddr);
        ld.add(memIn);
        push(out, ld);

        IRValue* idx = new IRValue(String.withCString("U16"));
        IRInsn* zx = IRInsn.with(String.withCString("ZExt"));
        zx.setRes(idx);
        zx.add(IROperand.useVal(cursor));
        push(out, zx);

        IRValue* slotPtr = new IRValue(u8Ptr);
        IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
        ea.setRes(slotPtr);
        ea.add(IROperand.useVal(bufPtr));
        ea.add(IROperand.useVal(idx));
        push(out, ea);

        // The packer's fixed slot stride, unless the value IS the struct in the
        // buffer — then the pointer is handed back and the cursor steps over the
        // struct itself. `_vaAdvance` / `_vaMem` are how the shape below reports
        // back: the three cases differ in all three of result, memory and stride.
        _vaAdvance = (u32)8;
        _vaMem = m1;
        IRValue* newResult = readVaSlot(m, out, resT, slotPtr, m1);
        IRValue* delta = emitConstU8(out, _vaAdvance);
        IRValue* next = new IRValue(String.withCString("U8"));
        IRInsn* ad2 = IRInsn.with(String.withCString("Add"));
        ad2.setRes(next);
        ad2.add(IROperand.useVal(cursor));
        ad2.add(IROperand.useVal(delta));
        push(out, ad2);

        IRValue* newMem = new IRValue(String.withCString("Mem"));
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        st.setMemRes(newMem);
        st.add(cursorAddr);
        st.add(IROperand.useVal(next));
        st.add(IROperand.useVal(_vaMem));
        push(out, st);

        if (va.res() != 0)
            remap.set((Hashable*)va.res(), (Object*)newResult);
        if (va.memRes() != 0)
            remap.set((Hashable*)va.memRes(), (Object*)newMem);
        }

    bool isStructPtr(String* t)
        {
        return t.hasPrefix(String.withCString("Ptr(Agg("));
        }

    bool isNarrowInt(String* t)
        {
        return t.equals(String.withCString("U8")) || t.equals(String.withCString("I8"));
        }

    // `Ptr(Agg(N), unbanked)` -> the size layout N records.
    u32 aggWidth(IRModule* m, String* t)
        {
        u32 i = (u32)8; // past `Ptr(Agg(`
        u32 id = (u32)0;
        while (i < t.byteLength())
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            id = id * (u32)10 + (u32)(c - (u8)'0');
            i = i + (u32)1;
            }
        if (id >= m.layouts().count())
            return (u32)0;
        return ((IRLayout*)m.layouts().get(id)).size();
        }

    void applyRemap(IRFunc* fn, Map* remap)
        {
        if (remap.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                remapUses((IRInsn*)bb.phis().get(i), remap);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                remapUses((IRInsn*)bb.insns().get(i), remap);
            if (bb.term() != 0)
                remapUses(bb.term(), remap);
            }
        }

    void remapUses(IRInsn* n, Map* remap)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            Object* to = remap.get((Hashable*)o.val());
            if (to == 0)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal((IRValue*)to));
            }
        }
    // ── arc-self-retain ──────────────────────────────────────────────────
    //
    // A method retains its receiver on entry and releases it on every exit, so
    // an opaque call inside cannot free the object out from under it. When
    // nothing the method reaches can release anything, that bracket is pure
    // cost and comes out.
    //
    // "Nothing it reaches" is a FIXPOINT, not a scan: a method is inert until
    // proved otherwise, and calling a function that is later found guilty makes
    // it guilty in the next round.
    void arcSelfRetain(IRModule* m)
        {
        Array* funcs = m.funcs();
        Array* brackets = new Array(); // parallel to funcs: Array@ or 0
        for (u32 i = (u32)0; i < funcs.count(); i = i + (u32)1)
            brackets.add((Object*)selfBracket((IRFunc*)funcs.get(i)));

        Array* notInert = new Array(); // IRFunc@
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 i = (u32)0; i < funcs.count(); i = i + (u32)1)
                {
                IRFunc* fn = (IRFunc*)funcs.get(i);
                if (hasFunc(notInert, fn))
                    continue;
                if (isInert(m, fn, (Array*)brackets.get(i), notInert))
                    continue;
                notInert.add((Object*)fn);
                changed = true;
                }
            }

        for (u32 i = (u32)0; i < funcs.count(); i = i + (u32)1)
            {
            IRFunc* fn = (IRFunc*)funcs.get(i);
            Array* b = (Array*)brackets.get(i);
            if (b == 0 || hasFunc(notInert, fn))
                continue;
            elideBracket(fn, b);
            }
        }

    // The receiver's Retain + its Releases, or 0. The Retain must be the FIRST
    // entry instruction and the ONLY retain of that parameter — a strong-local
    // copy's retain is not first, and excluding it is what keeps this from
    // eliding a bracket that is doing real work.
    Array* selfBracket(IRFunc* fn)
        {
        if (fn.name() == 0)
            return (Array*)0;
        if (fn.name().indexOfByte((u8)'$') == String.notFound())
            return (Array*)0;
        if (fn.blocks().count() == (u32)0)
            return (Array*)0;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        if (entry.insns().count() == (u32)0)
            return (Array*)0;
        IRInsn* first = (IRInsn*)entry.insns().get((u32)0);
        if (!first.op().equals(String.withCString("Retain")))
            return (Array*)0;
        if (first.ops().count() < (u32)1)
            return (Array*)0;
        IROperand* o0 = (IROperand*)first.ops().get((u32)0);
        if (o0.kind() != (u8)OPK_USE)
            return (Array*)0;
        IRValue* recv = o0.val();
        if (!isParam(fn, recv))
            return (Array*)0;
        if (!isStructPtr(recv.ty()))
            return (Array*)0;

        u32 retains = (u32)0;
        Array* bracket = new Array();
        bracket.add((Object*)first);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.ops().count() < (u32)1)
                    continue;
                IROperand* o = (IROperand*)n.ops().get((u32)0);
                if (o.kind() != (u8)OPK_USE || o.val() != recv)
                    continue;
                if (n.op().equals(String.withCString("Retain")))
                    retains = retains + (u32)1;
                if (n.op().equals(String.withCString("Release")))
                    bracket.add((Object*)n);
                }
            }
        if (retains != (u32)1)
            return (Array*)0;
        if (bracket.count() < (u32)2)
            return (Array*)0; // 1 retain + >= 1 release
        return bracket;
        }

    // Inert = releases nothing, dispatches nothing it cannot see, and calls only
    // functions that are themselves inert. Its own bracket does not count: it is
    // net zero on the receiver.
    bool isInert(IRModule* m, IRFunc* fn, Array* bracket, Array* notInert)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (bracket != 0 && hasInsn(bracket, n))
                    continue;
                String* op = n.op();
                if (op.equals(String.withCString("Release")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")))
                    return false;
                if (!isCallOp(op))
                    continue;
                if (n.ops().count() < (u32)1)
                    return false;
                IROperand* c = (IROperand*)n.ops().get((u32)0);
                if (c.kind() != (u8)OPK_SYM || c.name() == 0)
                    return false;
                IRFunc* g = funcNamed(m, c.name());
                if (g == 0 || hasFunc(notInert, g))
                    return false;
                }
            }
        return true;
        }

    bool isCallOp(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked"));
        }

    // Drop the bracket, threading the memory token past each removed op so a
    // later use rewires to the first surviving token.
    void elideBracket(IRFunc* fn, Array* remove)
        {
        Map* bypass = new Map();
        for (u32 i = (u32)0; i < remove.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)remove.get(i);
            if (n.ops().count() < (u32)2 || n.memRes() == 0)
                continue;
            IROperand* memIn = (IROperand*)n.ops().get((u32)1);
            if (memIn.kind() != (u8)OPK_USE)
                continue;
            bypass.set((Hashable*)n.memRes(), (Object*)memIn.val());
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                bypassUses((IRInsn*)bb.phis().get(i), bypass);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (hasInsn(remove, n))
                    continue; // it is on its way out
                bypassUses(n, bypass);
                }
            if (bb.term() != 0)
                bypassUses(bb.term(), bypass);
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!hasInsn(remove, n))
                    keep.add((Object*)n);
                }
            bb.setInsns(keep);
            }
        }

    void bypassUses(IRInsn* n, Map* bypass)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            if (bypass.get((Hashable*)o.val()) == 0)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(resolveBypass(bypass, o.val())));
            }
        }

    // A removed op's memory input may itself have been removed, so the chain is
    // followed to the first token that survives.
    IRValue* resolveBypass(Map* bypass, IRValue* v)
        {
        IRValue* cur = v;
        for (u32 d = (u32)0; d < (u32)64; d = d + (u32)1)
            {
            Object* nxt = bypass.get((Hashable*)cur);
            if (nxt == 0)
                return cur;
            cur = (IRValue*)nxt;
            }
        return cur;
        }

    bool isParam(IRFunc* fn, IRValue* v)
        {
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            if ((IRValue*)fn.params().get(i) == v)
                return true;
        return false;
        }

    bool hasFunc(Array* fs, IRFunc* f)
        {
        for (u32 i = (u32)0; i < fs.count(); i = i + (u32)1)
            if ((IRFunc*)fs.get(i) == f)
                return true;
        return false;
        }

    bool hasInsn(Array* ns, IRInsn* n)
        {
        for (u32 i = (u32)0; i < ns.count(); i = i + (u32)1)
            if ((IRInsn*)ns.get(i) == n)
                return true;
        return false;
        }
    // ── inline ───────────────────────────────────────────────────────────
    //
    // Splice a small leaf's body into its caller. Only the SINGLE-BLOCK shape
    // is here: a multi-block callee splits the caller's block and rewires the
    // CFG, which is the other half of the original's pass and is refused by
    // name until it is ported too.
    void inlineLeaves(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            inlineInto(m, (IRFunc*)m.funcs().get(f));
        }

    // A single-block callee splices in place; a multi-block one SPLITS the
    // caller's block, so the block list changes underneath the scan and the
    // caller is rescanned. The guard is the original's, against a pathological
    // chain of inlines.
    void inlineInto(IRModule* m, IRFunc* caller)
        {
        bool again = true;
        u32 guard = (u32)0;
        while (again && guard < (u32)8192)
            {
            guard = guard + (u32)1;
            again = false;
            for (u32 b = (u32)0; b < caller.blocks().count(); b = b + (u32)1)
                {
                if (again)
                    break;
                IRBlock* bb = (IRBlock*)caller.blocks().get(b);
                u32 i = (u32)0;
                while (i < bb.insns().count())
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    IRFunc* callee = inlinableCallee(m, n, caller);
                    if (callee == 0)
                        {
                        i = i + (u32)1;
                        continue;
                        }
                    if (callee.blocks().count() != (u32)1)
                        {
                        multiBlockInline(m, n, callee, caller, bb, i);
                        if (_failed)
                            return;
                        again = true; // the block list changed
                        break;
                        }
                    Array* spliced = spliceCall(n, callee, caller, bb);
                    if (spliced == 0)
                        {
                        i = i + (u32)1;
                        continue;
                        }
                    Array* out = new Array();
                    for (u32 k = (u32)0; k < i; k = k + (u32)1)
                        out.add(bb.insns().get(k));
                    for (u32 k = (u32)0; k < spliced.count(); k = k + (u32)1)
                        out.add(spliced.get(k));
                    for (u32 k = i + (u32)1; k < bb.insns().count(); k = k + (u32)1)
                        out.add(bb.insns().get(k));
                    bb.setInsns(out);
                    i = i + spliced.count();
                    }
                }
            }
        }

    // Params map to the call's actual operands; everything the body defines
    // gets a fresh caller value. Shared by both halves of the inliner.
    Map* calleeRemap(IRInsn* call, IRFunc* callee)
        {
        u32 nUser = callee.params().count() - (u32)1;
        Map* remap = new Map();
        for (u32 k = (u32)0; k < nUser; k = k + (u32)1)
            remap.set((Hashable*)(IRValue*)callee.params().get(k),
                      (Object*)(IROperand*)call.ops().get(k + (u32)1));
        remap.set((Hashable*)(IRValue*)callee.params().get(nUser),
                  (Object*)(IROperand*)call.ops().get(call.ops().count() - (u32)1));
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cbb = (IRBlock*)callee.blocks().get(b);
            for (u32 i = (u32)0; i < cbb.insns().count(); i = i + (u32)1)
                {
                IRInsn* bi = (IRInsn*)cbb.insns().get(i);
                if (bi.res() != 0)
                    remap.set((Hashable*)bi.res(),
                              (Object*)IROperand.useVal(new IRValue(bi.res().ty())));
                if (bi.memRes() != 0)
                    remap.set((Hashable*)bi.memRes(),
                              (Object*)IROperand.useVal(new IRValue(bi.memRes().ty())));
                }
            }
        return remap;
        }

    // Split `bb` at the call: the prefix keeps what came before, `cont` takes
    // the suffix and the terminator, and every successor phi that named `bb`
    // now names `cont`.
    void splitAtCall(IRBlock* bb, IRBlock* cont, u32 callIndex)
        {
        Array* keep = new Array();
        Array* tail = new Array();
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            {
            if (k < callIndex)
                keep.add(bb.insns().get(k));
            else if (k > callIndex)
                tail.add(bb.insns().get(k));
            }
        cont.setInsns(tail);
        bb.setInsns(keep);
        if (bb.term() == 0)
            return;
        IRInsn* t = bb.term();
        cont.setTerm(t);
        bb.setTerm((IRInsn*)0);
        repointSuccessorPhis(t, bb, cont);
        }

    // Inline a single-return, phi-free MULTI-block callee: the caller's block is
    // SPLIT at the call. The prefix keeps its instructions and branches into the
    // cloned callee entry; a fresh continuation takes the suffix and the
    // original terminator; the callee's one Return becomes a Branch to that
    // continuation, forwarding what it returned.
    void multiBlockInline(IRModule* m, IRInsn* call, IRFunc* callee,
                          IRFunc* caller, IRBlock* bb, u32 callIndex)
        {
        Map* remap = calleeRemap(call, callee);

        // One fresh caller block per callee block, plus the continuation. The
        // names carry the caller's block count so two inlines cannot collide.
        u32 tag = caller.blocks().count();
        Map* blockMap = new Map();
        Array* clones = new Array();
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cbb = (IRBlock*)callee.blocks().get(b);
            String* nm = String.withCString("il");
            nm.appendFormat("%ld_", (i32)tag);
            nm.append(cbb.name() == 0 ? String.withCString("b") : cbb.name());
            IRBlock* nb = new IRBlock(nm);
            blockMap.set((Hashable*)cbb, (Object*)nb);
            clones.add((Object*)nb);
            }
        String* contName = String.withCString("il");
        contName.appendFormat("%ld_cont", (i32)tag);
        IRBlock* cont = new IRBlock(contName);

        // The continuation takes the suffix and the terminator.
        splitAtCall(bb, cont, callIndex);

        // Clone each callee block; its one Return becomes a Branch to `cont`.
        IROperand* retVal = (IROperand*)0;
        IROperand* retMem = (IROperand*)0;
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* cbb = (IRBlock*)callee.blocks().get(b);
            IRBlock* nb = (IRBlock*)blockMap.get((Hashable*)cbb);
            for (u32 i = (u32)0; i < cbb.insns().count(); i = i + (u32)1)
                nb.add(cloneInsn(remap, blockMap, (IRInsn*)cbb.insns().get(i)));
            IRInsn* t = cbb.term();
            if (t == 0)
                continue;
            if (t.op().equals(String.withCString("Return")))
                {
                if (t.ops().count() >= (u32)1)
                    retMem = substBoth(remap, blockMap,
                                       (IROperand*)t.ops().get(t.ops().count() - (u32)1));
                if (call.res() != 0 && t.ops().count() >= (u32)2)
                    retVal = substBoth(remap, blockMap, (IROperand*)t.ops().get((u32)0));
                IRInsn* br = IRInsn.with(String.withCString("Branch"));
                br.add(IROperand.block(cont));
                nb.setTerm(br);
                }
            else
                {
                nb.setTerm(cloneInsn(remap, blockMap, t));
                }
            }

        // The prefix branches into the cloned entry, and the new blocks land
        // straight after it.
        IRInsn* into = IRInsn.with(String.withCString("Branch"));
        into.add(IROperand.block((IRBlock*)clones.get((u32)0)));
        bb.setTerm(into);
        clones.add((Object*)cont);
        u32 pos = blockIndex(caller, bb) + (u32)1;
        caller.blocks().insertAll(pos, clones);

        // Forwarding comes LAST: the suffix now living in `cont` still refers to
        // the call's result, and it has to be in the block list to be rewritten.
        if (call.res() != 0 && retVal != 0)
            rewriteUsesTo(caller, call.res(), retVal);
        if (call.memRes() != 0 && retMem != 0)
            rewriteUsesTo(caller, call.memRes(), retMem);
        }

    // Re-point every phi in `t`'s successors from `from` to `to`.
    void repointSuccessorPhis(IRInsn* t, IRBlock* from, IRBlock* to)
        {
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() == 0)
                continue;
            IRBlock* succ = o.blk();
            for (u32 pi = (u32)0; pi < succ.phis().count(); pi = pi + (u32)1)
                {
                IRInsn* phi = (IRInsn*)succ.phis().get(pi);
                for (u32 j = (u32)0; j < phi.ops().count(); j = j + (u32)1)
                    {
                    IROperand* po = (IROperand*)phi.ops().get(j);
                    if (po.kind() != (u8)OPK_BLOCK || po.blk() != from)
                        continue;
                    phi.ops().set(j, (Object*)IROperand.block(to));
                    }
                }
            }
        }

    IRInsn* cloneInsn(Map* remap, Map* blockMap, IRInsn* bi)
        {
        IRInsn* cl = IRInsn.with(bi.op());
        cl.setPred(bi.pred());
        cl.setCc(bi.cc());
        for (u32 k = (u32)0; k < bi.ops().count(); k = k + (u32)1)
            cl.add(substBoth(remap, blockMap, (IROperand*)bi.ops().get(k)));
        if (bi.res() != 0)
            cl.setRes(remappedValue(remap, bi.res()));
        if (bi.memRes() != 0)
            cl.setMemRes(remappedValue(remap, bi.memRes()));
        return cl;
        }

    // An operand in a cloned body names either a callee VALUE or a callee
    // BLOCK, and both have moved.
    IROperand* substBoth(Map* remap, Map* blockMap, IROperand* o)
        {
        if (o.kind() == (u8)OPK_BLOCK && o.blk() != 0)
            {
            Object* nb = blockMap.get((Hashable*)o.blk());
            if (nb == 0)
                return o;
            return IROperand.block((IRBlock*)nb);
            }
        return substOperand(remap, o);
        }

    u32 blockIndex(IRFunc* fn, IRBlock* bb)
        {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == bb)
                return i;
        return fn.blocks().count();
        }

    // The callee this Call can be inlined from, or 0. Every rule is the
    // original's: a plain Call to a known body that is not the caller, one
    // Return, no phis, no inline asm, no pinned locals, no aggregate-by-value
    // parameter, and a body under the size ceiling.
    IRFunc* inlinableCallee(IRModule* m, IRInsn* n, IRFunc* caller)
        {
        if (!n.op().equals(String.withCString("Call")))
            return (IRFunc*)0;
        if (n.ops().count() < (u32)1)
            return (IRFunc*)0;
        IROperand* c = (IROperand*)n.ops().get((u32)0);
        if (c.kind() != (u8)OPK_SYM || c.name() == 0)
            return (IRFunc*)0;
        IRFunc* callee = funcNamed(m, c.name());
        if (callee == 0 || callee == caller)
            return (IRFunc*)0;
        if (callee.blocks().count() == (u32)0)
            return (IRFunc*)0;
        bool multi = callee.blocks().count() > (u32)1;
        // A pinned local is a frame SLOT the callee takes the address of. It can
        // come across: every back end lays these out ITSELF, in list order, from
        // the local's TYPE — none reads the recorded offset — so the callee's
        // own frame offset need not travel. spliceCall gives each a fresh caller
        // value and adds it to the caller. Single-block only; the multi-block
        // path wires the CFG through a different splice that does not do this.
        // …and only where the target can address a frame temp reliably. The
        // 6502 cannot — struct_byval_rvalue came back wrong when this was
        // allowed there — the same constraint the aggregate-parameter knob
        // describes, so it shares it.
        if ((multi || !_profile.inlineAggParams()) && callee.pinned().count() > (u32)0)
            return (IRFunc*)0;
        u32 returns = (u32)0;
        u32 total = (u32)0;
        for (u32 b = (u32)0; b < callee.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)callee.blocks().get(b);
            if (bb.phis().count() > (u32)0)
                return (IRFunc*)0;
            total = total + bb.insns().count();
            if (bb.term() != 0 && bb.term().op().equals(String.withCString("Return")))
                returns = returns + (u32)1;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                String* op = ((IRInsn*)bb.insns().get(i)).op();
                if (op.equals(String.withCString("Asm")))
                    return (IRFunc*)0; // {{XTLOCAL}}
                // A MULTI-block callee that calls anything could be (mutually)
                // recursive, and inlining it would re-expose the call and grow
                // for ever. Multi-block inlining is leaves only.
                if (!multi)
                    continue;
                if (isCallOp(op) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")))
                    return (IRFunc*)0;
                }
            }
        if (returns != (u32)1)
            return (IRFunc*)0;
        if (total > (u32)64)
            return (IRFunc*)0; // the size ceiling

        // The call's shape must match the parameter list exactly: params are
        // [user…, Mem] and the operands [callee, args…, memIn]. A variadic or
        // cloaked call does not, and is not inlinable.
        u32 nParams = callee.params().count();
        if (nParams < (u32)1)
            return (IRFunc*)0;
        u32 nUser = nParams - (u32)1;
        if (n.ops().count() != (u32)2 + nUser)
            return (IRFunc*)0;
        // An aggregate BY VALUE is only ever read through AddrOf(param); after
        // inlining that is AddrOf of the caller's loaded temp, which is not
        // reliably addressable. Pass it through a real call.
        if (!_profile.inlineAggParams())
            for (u32 k = (u32)0; k < nUser; k = k + (u32)1)
                if (((IRValue*)callee.params().get(k)).ty().hasPrefix(String.withCString("Agg(")))
                    return (IRFunc*)0;
        return callee;
        }

    // Clone the callee's one block with its values substituted, and forward the
    // call's result and memory token to what the Return hands back.
    Array* spliceCall(IRInsn* call, IRFunc* callee, IRFunc* caller, IRBlock* bb)
        {
        IRBlock* cb = (IRBlock*)callee.blocks().get((u32)0);
        u32 nUser = callee.params().count() - (u32)1;

        Map* remap = new Map(); // callee value -> caller OPERAND
        for (u32 k = (u32)0; k < nUser; k = k + (u32)1)
            remap.set((Hashable*)(IRValue*)callee.params().get(k),
                      (Object*)(IROperand*)call.ops().get(k + (u32)1));
        remap.set((Hashable*)(IRValue*)callee.params().get(nUser),
                  (Object*)(IROperand*)call.ops().get(call.ops().count() - (u32)1));

        // The callee's pinned locals become the caller's. A pinned local is a
        // frame slot rather than an instruction result, so it never appears in
        // the body walk below: give each a fresh caller value, map it, and add
        // it. The back ends re-lay them out from the type, so the offset
        // travels as 0.
        for (u32 i = (u32)0; i < callee.pinned().count(); i = i + (u32)1)
            {
            IRPinned* pl = (IRPinned*)callee.pinned().get(i);
            IRValue* nv = new IRValue(pl.ty());
            remap.set((Hashable*)pl.val(), (Object*)IROperand.useVal(nv));
            caller.addPinned(IRPinned.with(nv, pl.ty(), (u32)0, pl.esc()));
            }

        // A fresh caller value for everything the body defines.
        for (u32 i = (u32)0; i < cb.insns().count(); i = i + (u32)1)
            {
            IRInsn* bi = (IRInsn*)cb.insns().get(i);
            if (bi.res() != 0)
                remap.set((Hashable*)bi.res(), (Object*)IROperand.useVal(new IRValue(bi.res().ty())));
            if (bi.memRes() != 0)
                remap.set((Hashable*)bi.memRes(), (Object*)IROperand.useVal(new IRValue(bi.memRes().ty())));
            }

        Array* spliced = new Array();
        for (u32 i = (u32)0; i < cb.insns().count(); i = i + (u32)1)
            {
            IRInsn* bi = (IRInsn*)cb.insns().get(i);
            IRInsn* cl = IRInsn.with(bi.op());
            cl.setPred(bi.pred());
            cl.setCc(bi.cc());
            for (u32 k = (u32)0; k < bi.ops().count(); k = k + (u32)1)
                cl.add(substOperand(remap, (IROperand*)bi.ops().get(k)));
            if (bi.res() != 0)
                cl.setRes(remappedValue(remap, bi.res()));
            if (bi.memRes() != 0)
                cl.setMemRes(remappedValue(remap, bi.memRes()));
            spliced.add((Object*)cl);
            }

        // The Return's operands are [value?, mem] — memory last, value first.
        IRInsn* ret = cb.term();
        if (ret == 0)
            return (Array*)0;
        IROperand* retMem = (IROperand*)0;
        if (ret.ops().count() >= (u32)1)
            retMem = substOperand(remap, (IROperand*)ret.ops().get(ret.ops().count() - (u32)1));
        IROperand* retVal = (IROperand*)0;
        if (call.res() != 0)
            {
            if (ret.ops().count() < (u32)2)
                return (Array*)0; // a value was expected
            retVal = substOperand(remap, (IROperand*)ret.ops().get((u32)0));
            }
        if (call.res() != 0 && retVal != 0)
            rewriteUsesTo(caller, call.res(), retVal);
        if (call.memRes() != 0 && retMem != 0)
            rewriteUsesTo(caller, call.memRes(), retMem);
        return spliced;
        }

    IROperand* substOperand(Map* remap, IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return o;
        Object* r = remap.get((Hashable*)o.val());
        if (r == 0)
            return o;
        return (IROperand*)r;
        }

    IRValue* remappedValue(Map* remap, IRValue* v)
        {
        Object* r = remap.get((Hashable*)v);
        if (r == 0)
            return v;
        return ((IROperand*)r).val();
        }

    // Every use of `old` in the caller becomes `to` — the call's result and its
    // memory token, forwarded to what the body actually produced.
    void rewriteUsesTo(IRFunc* fn, IRValue* old, IROperand* to)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                replaceUse((IRInsn*)bb.phis().get(i), old, to);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                replaceUse((IRInsn*)bb.insns().get(i), old, to);
            if (bb.term() != 0)
                replaceUse(bb.term(), old, to);
            }
        }

    void replaceUse(IRInsn* n, IRValue* old, IROperand* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() != old)
                continue;
            n.ops().set(k, (Object*)to);
            }
        }
    // ── narrow ───────────────────────────────────────────────────────────
    //
    // Demanded-width narrowing: an arithmetic result that is immediately
    // truncated is recomputed AT the narrow width, so C-style promotion costs
    // nothing where the result is narrowed anyway (`u16 y = a * b`). The wide
    // op and its Ext feeders are left for the dead-code sweep.
    void narrow(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            narrowInFunc((IRFunc*)m.funcs().get(f));
        }

    void narrowInFunc(IRFunc* fn)
        {
        bool changed = true;
        for (u32 round = (u32)0; round < (u32)8; round = round + (u32)1)
            {
            if (!changed)
                return;
            changed = false;
            Map* defOf = defMapInsns(fn);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                if (narrowInBlock(fn, (IRBlock*)fn.blocks().get(b), defOf))
                    changed = true;
            }
        }

    bool narrowInBlock(IRFunc* fn, IRBlock* bb, Map* defOf)
        {
        bool changed = false;
        u32 idx = (u32)0;
        while (idx < bb.insns().count())
            {
            IRInsn* tr = (IRInsn*)bb.insns().get(idx);
            IRInsn* src = truncSource(tr, defOf);
            if (src == 0)
                {
                idx = idx + (u32)1;
                continue;
                }
            u32 w = irWidth(tr.res().ty());
            _narrowInserts = new Array();
            Array* nops = narrowedOperands(fn, defOf, src, tr, w);
            if (nops == 0)
                {
                idx = idx + (u32)1;
                continue;
                }
            // The narrow op REUSES the Trunc's result value, so every consumer
            // follows without being rewritten.
            IRInsn* nOp = IRInsn.with(src.op());
            nOp.setRes(tr.res());
            for (u32 k = (u32)0; k < nops.count(); k = k + (u32)1)
                nOp.add((IROperand*)nops.get(k));
            Array* out = new Array();
            for (u32 k = (u32)0; k < idx; k = k + (u32)1)
                out.add(bb.insns().get(k));
            for (u32 k = (u32)0; k < _narrowInserts.count(); k = k + (u32)1)
                out.add(_narrowInserts.get(k));
            out.add((Object*)nOp);
            for (u32 k = idx + (u32)1; k < bb.insns().count(); k = k + (u32)1)
                out.add(bb.insns().get(k));
            bb.setInsns(out);
            idx = idx + _narrowInserts.count() + (u32)1;
            changed = true;
            }
        return changed;
        }

    // The wide arithmetic this Trunc consumes, when there is one to narrow.
    IRInsn* truncSource(IRInsn* tr, Map* defOf)
        {
        if (!tr.op().equals(String.withCString("Trunc")))
            return (IRInsn*)0;
        if (tr.res() == 0 || tr.ops().count() < (u32)1)
            return (IRInsn*)0;
        IROperand* o = (IROperand*)tr.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE || o.val() == 0)
            return (IRInsn*)0;
        Object* d = defOf.get((Hashable*)o.val());
        if (d == 0)
            return (IRInsn*)0;
        IRInsn* src = (IRInsn*)d;
        if (!isNarrowable(src.op()))
            return (IRInsn*)0;
        if (src.res() == 0 || src.ops().count() < (u32)2)
            return (IRInsn*)0;
        if (irWidth(src.res().ty()) <= irWidth(tr.res().ty()))
            return (IRInsn*)0;
        return src;
        }

    // The Truncs this narrowing has to insert ahead of the op.
    Array* _narrowInserts;

    // Each operand at width `w`, or 0 when one cannot be narrowed cleanly —
    // correctness first, the pass simply declines.
    Array* narrowedOperands(IRFunc* fn, Map* defOf, IRInsn* src, IRInsn* tr, u32 w)
        {
        Array* nops = new Array();
        for (u32 k = (u32)0; k < src.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)src.ops().get(k);
            if (o.kind() == (u8)OPK_IMMI)
                {
                nops.add((Object*)o);
                continue;
                }
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                return (Array*)0;
            // Trunc_w(Ext(x_w)) is x_w — collapse rather than re-truncate.
            Object* d = defOf.get((Hashable*)o.val());
            if (d != 0)
                {
                IRInsn* od = (IRInsn*)d;
                if ((od.op().equals(String.withCString("ZExt")) || od.op().equals(String.withCString("SExt"))) && od.ops().count() >= (u32)1)
                    {
                    IROperand* inner = (IROperand*)od.ops().get((u32)0);
                    if (inner.kind() == (u8)OPK_USE && inner.val() != 0 && irWidth(inner.val().ty()) == w)
                        {
                        nops.add((Object*)IROperand.useVal(inner.val()));
                        continue;
                        }
                    }
                }
            u32 ow = irWidth(o.val().ty());
            if (ow == w)
                {
                nops.add((Object*)o);
                continue;
                }
            if (ow > w)
                {
                IRValue* rv = new IRValue(tr.res().ty());
                IRInsn* nt = IRInsn.with(String.withCString("Trunc"));
                nt.setRes(rv);
                nt.add(o);
                _narrowInserts.add((Object*)nt);
                nops.add((Object*)IROperand.useVal(rv));
                continue;
                }
            return (Array*)0; // narrower than asked: unexpected
            }
        return nops;
        }

    // Ops whose low W bits depend only on the operands' low W bits. Div, the
    // shifts and the remainders are NOT among them: their high bits leak down.
    bool isNarrowable(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor"));
        }

    // Value -> the INSTRUCTION that defines it, phis excluded (the original's
    // narrow map is built from instructions only).
    Map* defMapInsns(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != 0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        return defOf;
        }

    // The byte width of an IR type spelling. Pointers and aggregates are not
    // narrowing candidates, and report 0.
    u32 irWidth(String* t)
        {
        if (t == 0)
            return (u32)0;
        if (t.equals(String.withCString("U8")) || t.equals(String.withCString("I8")) || t.equals(String.withCString("Bool")))
            return (u32)1;
        if (t.equals(String.withCString("U16")) || t.equals(String.withCString("I16")))
            return (u32)2;
        if (t.equals(String.withCString("U32")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("F32")))
            return (u32)4;
        if (t.equals(String.withCString("U64")) || t.equals(String.withCString("I64")) || t.equals(String.withCString("F64")))
            return (u32)8;
        return (u32)0;
        }
    // ── tail-recursion ───────────────────────────────────────────────────
    //
    // `return f(args)` becomes a loop: the entry block is split into a
    // preheader and a header carrying one phi per parameter, and every
    // iterated return becomes a back edge that feeds the phis its arguments.
    // Tier-2 does the same for `return g ⊕ f(args)` with an accumulator phi,
    // and is profile-gated — it is a win on an in-order core and a loss where
    // the call overhead is already hidden.
    //
    // Memory is LOOSE in this IR: there is no memory phi, and the body's memory
    // operations simply re-run in order each iteration.
    void tailRecursion(IRModule* m)
        {
        if (!_profile.tailRecursion())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            tailRecInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    // Everything the transform needs to know about one iterated return.
    Array* _trBlocks;   // IRBlock@  — the block the return lives in
    Array* _trCalls;    // IRInsn@   — the self call
    Array* _trCombines; // IRInsn@ or 0 — Tier-2's ⊕
    Array* _trGIdx;     // Number@   — which combine operand is `g`

    void tailRecInFunc(IRModule* m, IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        if (entry.phis().count() != (u32)0)
            return; // entry must be phi-free

        // Variadic self-recursion: the arg marshalling cannot be re-expressed
        // as a parameter reassignment.
        IRSymbol* selfSym = symNamed(m, fn.name());
        if (selfSym != 0 && selfSym.variadic())
            return;
        // A pinned local whose address ESCAPES is unsafe: the loop reuses one
        // frame slot, so a callee holding a pointer into a previous "frame"
        // would alias it.
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            if (((IRPinned*)fn.pinned().get(i)).esc())
                return;

        u32 nParams = fn.params().count();
        if (nParams == (u32)0)
            return;
        IRValue* memParam = (IRValue*)fn.params().get(nParams - (u32)1);
        if (!memParam.ty().equals(String.withCString("Mem")))
            return;
        u32 userParams = nParams - (u32)1;

        if (!collectTailReturns(m, fn, userParams))
            return;

        // The parallel-copy hazard: a back edge that feeds parameter phi j the
        // value of a DIFFERENT parameter is a permutation, and the sequential
        // phi-edge copies cannot express it. Passing a parameter through to its
        // own slot is a no-op and fine.
        for (u32 c = (u32)0; c < _trCalls.count(); c = c + (u32)1)
            {
            IRInsn* tc = (IRInsn*)_trCalls.get(c);
            for (u32 j = (u32)0; j < userParams; j = j + (u32)1)
                {
                IROperand* arg = (IROperand*)tc.ops().get((u32)1 + j);
                if (arg.kind() != (u8)OPK_USE || arg.val() == 0)
                    continue;
                i32 pi = paramIndex(fn, arg.val());
                if (pi >= (i32)0 && (u32)pi != j)
                    return;
                }
            }
        buildTailLoop(fn, entry, userParams);
        }

    // Every `return f(args)` (Tier-1) and, where the profile allows it,
    // `return g ⊕ f(args)` (Tier-2). False when there is nothing to iterate.
    bool collectTailReturns(IRModule* m, IRFunc* fn, u32 userParams)
        {
        _trBlocks = new Array();
        _trCalls = new Array();
        _trCombines = new Array();
        _trGIdx = new Array();
        Map* defOf = defMapAll(fn);
        Map* defBlk = defBlockMap(fn);
        Map* useCount = useCounts(fn);
        Array* t1b = new Array();
        Array* t1c = new Array();
        Array* t2b = new Array();
        Array* t2c = new Array();
        Array* t2m = new Array();
        Array* t2g = new Array();

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == 0 || !term.op().equals(String.withCString("Return")))
                continue;
            if (term.ops().count() == (u32)0)
                continue;
            IROperand* memOp = (IROperand*)term.ops().get(term.ops().count() - (u32)1);
            if (memOp.kind() != (u8)OPK_USE)
                continue;
            IROperand* valOp = term.ops().count() >= (u32)2
                                   ? (IROperand*)term.ops().get((u32)0)
                                   : (IROperand*)0;

            IRInsn* tc1 = selfTailCall(m, fn, bb, valOp, memOp, defOf, defBlk,
                                       useCount, userParams);
            if (tc1 != 0)
                {
                t1b.add((Object*)bb);
                t1c.add((Object*)tc1);
                continue;
                }
            if (!_profile.accumRecursion())
                continue;
            if (valOp == 0 || valOp.kind() != (u8)OPK_USE || valOp.val() == 0)
                continue;
            Object* cd = defOf.get((Hashable*)valOp.val());
            if (cd == 0)
                continue;
            IRInsn* cmb = (IRInsn*)cd;
            if (defBlk.get((Hashable*)valOp.val()) != (Object*)bb)
                continue;
            if (cmb.ops().count() != (u32)2 || cmb.res() == 0)
                continue;
            if (!isCombineOp(cmb.op()))
                continue;
            if (irWidth(cmb.res().ty()) == (u32)0)
                continue; // integers only
            if (countOf(useCount, valOp.val()) != (u32)1)
                continue;
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                IRInsn* c = selfTailCall(m, fn, bb, (IROperand*)cmb.ops().get(k), memOp,
                                         defOf, defBlk, useCount, userParams);
                if (c == 0)
                    continue;
                t2b.add((Object*)bb);
                t2c.add((Object*)c);
                t2m.add((Object*)cmb);
                t2g.add((Object*)Number.with(k == (u32)0 ? (u32)1 : (u32)0));
                break;
                }
            }

        // Tier-2 wins when it is available: every return using the SAME ⊕ is
        // iterated, and the bare tail calls join them.
        if (t2c.count() > (u32)0)
            {
            IRInsn* first = (IRInsn*)t2m.get((u32)0);
            for (u32 i = (u32)0; i < t2c.count(); i = i + (u32)1)
                {
                IRInsn* cmb = (IRInsn*)t2m.get(i);
                if (!cmb.op().equals(first.op()))
                    continue;
                if (!cmb.res().ty().equals(first.res().ty()))
                    continue;
                _trBlocks.add(t2b.get(i));
                _trCalls.add(t2c.get(i));
                _trCombines.add(t2m.get(i));
                _trGIdx.add(t2g.get(i));
                }
            }
        for (u32 i = (u32)0; i < t1c.count(); i = i + (u32)1)
            {
            _trBlocks.add(t1b.get(i));
            _trCalls.add(t1c.get(i));
            _trCombines.add((Object*)0);
            _trGIdx.add((Object*)Number.with((u32)0));
            }
        return _trCalls.count() > (u32)0;
        }

    // A Use of a self-call in THIS block whose memory result is the return's
    // memory (so the call is the last side effect) and whose value is used
    // exactly once — here.
    IRInsn* selfTailCall(IRModule* m, IRFunc* fn, IRBlock* bb, IROperand* op,
                         IROperand* memOp, Map* defOf, Map* defBlk,
                         Map* useCount, u32 userParams)
        {
        if (op == 0 || op.kind() != (u8)OPK_USE || op.val() == 0)
            return (IRInsn*)0;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return (IRInsn*)0;
        IRInsn* c = (IRInsn*)d;
        if (!callIsSelf(m, c, fn))
            return (IRInsn*)0;
        if (defBlk.get((Hashable*)op.val()) != (Object*)bb)
            return (IRInsn*)0;
        if (c.res() != op.val())
            return (IRInsn*)0;
        if (c.memRes() == 0 || c.memRes() != memOp.val())
            return (IRInsn*)0;
        if (countOf(useCount, op.val()) != (u32)1)
            return (IRInsn*)0;
        if (c.ops().count() != userParams + (u32)2)
            return (IRInsn*)0;
        return c;
        }

    bool callIsSelf(IRModule* m, IRInsn* n, IRFunc* fn)
        {
        if (!isCallOp(n.op()) || n.ops().count() < (u32)2)
            return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM || callee.name() == 0)
            return false;
        return callee.name().equals(fn.name());
        }

    // Associative AND commutative with an unambiguous identity: `And`'s is
    // width-dependent to materialise and is left out, as in the original.
    bool isCombineOp(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Mul"));
        }

    i32 combineIdentity(String* op)
        {
        if (op.equals(String.withCString("Mul")))
            return (i32)1;
        return (i32)0;
        }

    i32 paramIndex(IRFunc* fn, IRValue* v)
        {
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            if ((IRValue*)fn.params().get(i) == v)
                return (i32)i;
        return (i32)-1;
        }
    // ── the loop the transform builds ────────────────────────────────────
    void buildTailLoop(IRFunc* fn, IRBlock* entry, u32 userParams)
        {
        String* hname = entry.name() == 0 ? String.withCString("entry")
                                          : String.withString(entry.name());
        hname.appendCString("_loop");
        IRBlock* H = new IRBlock(hname);
        H.setPhis(entry.phis());
        H.setInsns(entry.insns());
        if (entry.term() != 0)
            H.setTerm(entry.term());
        entry.setPhis(new Array());
        entry.setInsns(new Array());
        entry.setTerm((IRInsn*)0);
        Array* one = new Array();
        one.add((Object*)H);
        fn.blocks().insertAll((u32)1, one);
        // A return that lived in the old entry now lives in the header.
        for (u32 i = (u32)0; i < _trBlocks.count(); i = i + (u32)1)
            if ((IRBlock*)_trBlocks.get(i) == entry)
                _trBlocks.set(i, (Object*)H);

        // One phi per parameter, and every use of a parameter becomes a use of
        // its phi. A phi that named the old entry as a predecessor now names H,
        // because the entry's terminator — and so its out-edges — moved there.
        Array* phiRes = new Array();
        Map* remap = new Map();
        for (u32 i = (u32)0; i < userParams; i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)fn.params().get(i);
            IRValue* nv = new IRValue(pv.ty());
            phiRes.add((Object*)nv);
            remap.set((Hashable*)pv, (Object*)IROperand.useVal(nv));
            }
        retargetParams(fn, remap, entry, H);

        // Tier-2's accumulator: the identity in the preheader, a phi in H.
        bool tier2 = _trCombines.count() > (u32)0 && firstCombine() != 0;
        IRValue* accPhi = (IRValue*)0;
        IROperand* accInit = (IROperand*)0;
        String* accTy = (String*)0;
        String* combineOp = (String*)0;
        if (tier2)
            {
            IRInsn* first = firstCombine();
            combineOp = first.op();
            accTy = first.res().ty();
            IRValue* idVal = new IRValue(accTy);
            IRInsn* k = IRInsn.with(String.withCString("Const"));
            k.setRes(idVal);
            k.add(IROperand.immI(combineIdentity(combineOp), accTy));
            entry.add(k);
            accInit = IROperand.useVal(idVal);
            accPhi = new IRValue(accTy);
            }

        // Phi operand lists: the preheader edge first, then one per back edge.
        Array* phiOps = new Array();
        for (u32 i = (u32)0; i < userParams; i = i + (u32)1)
            {
            Array* ops = new Array();
            ops.add((Object*)IROperand.block(entry));
            ops.add((Object*)IROperand.useVal((IRValue*)fn.params().get(i)));
            phiOps.add((Object*)ops);
            }
        Array* accOps = new Array();
        if (tier2)
            {
            accOps.add((Object*)IROperand.block(entry));
            accOps.add((Object*)accInit);
            }

        for (u32 c = (u32)0; c < _trCalls.count(); c = c + (u32)1)
            closeBackEdge(fn, H, c, userParams, phiOps, accOps, accPhi, combineOp, accTy);

        if (tier2)
            wrapBaseReturns(fn, accPhi, combineOp, accTy);

        materialiseHeaderPhis(H, userParams, phiRes, phiOps, accPhi, accOps);

        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H));
        entry.setTerm(br);
        }

    // The header's phis go in FRONT of whatever it already had.
    void materialiseHeaderPhis(IRBlock* H, u32 userParams, Array* phiRes,
                               Array* phiOps, IRValue* accPhi, Array* accOps)
        {
        Array* newPhis = new Array();
        for (u32 i = (u32)0; i < userParams; i = i + (u32)1)
            newPhis.add((Object*)makePhi((IRValue*)phiRes.get(i), (Array*)phiOps.get(i)));
        if (accPhi != 0)
            newPhis.add((Object*)makePhi(accPhi, accOps));
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            newPhis.add(H.phis().get(i));
        H.setPhis(newPhis);
        }

    IRInsn* makePhi(IRValue* res, Array* ops)
        {
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        phi.setRes(res);
        for (u32 k = (u32)0; k < ops.count(); k = k + (u32)1)
            phi.add((IROperand*)ops.get(k));
        return phi;
        }

    IRInsn* firstCombine(void)
        {
        for (u32 i = (u32)0; i < _trCombines.count(); i = i + (u32)1)
            if (_trCombines.get(i) != 0)
                return (IRInsn*)_trCombines.get(i);
        return (IRInsn*)0;
        }

    // Parameter uses become phi uses, and a phi edge that named the old entry
    // block now names the header.
    void retargetParams(IRFunc* fn, Map* remap, IRBlock* entry, IRBlock* H)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                retargetInsn((IRInsn*)bb.phis().get(i), remap, entry, H, true);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                retargetInsn((IRInsn*)bb.insns().get(i), remap, entry, H, false);
            if (bb.term() != 0)
                retargetInsn(bb.term(), remap, entry, H, false);
            }
        }

    void retargetInsn(IRInsn* n, Map* remap, IRBlock* entry, IRBlock* H, bool isPhi)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != 0)
                {
                Object* r = remap.get((Hashable*)o.val());
                if (r != 0)
                    n.ops().set(k, (Object*)(IROperand*)r);
                continue;
                }
            if (isPhi && o.kind() == (u8)OPK_BLOCK && o.blk() == entry)
                n.ops().set(k, (Object*)IROperand.block(H));
            }
        }

    // One iterated return becomes a back edge: the call (and Tier-2's combine)
    // leave the block, the arguments feed the phis, and the terminator becomes
    // a Branch to the header. The call's memory input is DROPPED — memory is
    // loose, so the body simply re-runs its memory ops next time round.
    void closeBackEdge(IRFunc* fn, IRBlock* H, u32 c, u32 userParams,
                       Array* phiOps, Array* accOps, IRValue* accPhi,
                       String* combineOp, String* accTy)
        {
        IRBlock* RB = (IRBlock*)_trBlocks.get(c);
        IRInsn* tc = (IRInsn*)_trCalls.get(c);
        IRInsn* cmb = (IRInsn*)_trCombines.get(c);
        RB.setTerm((IRInsn*)0);
        // The call is about to go, so a later use of its memory result would
        // name a value nothing defines. Forward it to the call's own memory
        // input — memory is loose here, so this changes no behaviour.
        if (tc.memRes() != 0)
            {
            IROperand* memIn = (IROperand*)tc.ops().get(tc.ops().count() - (u32)1);
            if (memIn.kind() == (u8)OPK_USE)
                forwardMem(fn, tc.memRes(), memIn.val());
            }
        Array* keep = new Array();
        for (u32 i = (u32)0; i < RB.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)RB.insns().get(i);
            if (n == tc || (cmb != 0 && n == cmb))
                continue;
            keep.add((Object*)n);
            }
        RB.setInsns(keep);

        IROperand* accBack = accPhi == 0 ? (IROperand*)0 : IROperand.useVal(accPhi);
        if (cmb != 0)
            {
            // acc_next = acc_phi ⊕ g, where g is the combine's other operand.
            u32 gi = ((Number*)_trGIdx.get(c)).asU32();
            IROperand* gUse = (IROperand*)cmb.ops().get(gi);
            IRValue* anVal = new IRValue(accTy);
            IRInsn* an = IRInsn.with(combineOp);
            an.setRes(anVal);
            an.add(IROperand.useVal(accPhi));
            an.add(gUse);
            RB.add(an);
            accBack = IROperand.useVal(anVal);
            }
        for (u32 j = (u32)0; j < userParams; j = j + (u32)1)
            {
            Array* ops = (Array*)phiOps.get(j);
            ops.add((Object*)IROperand.block(RB));
            ops.add(tc.ops().get((u32)1 + j));
            }
        if (accPhi != 0)
            {
            accOps.add((Object*)IROperand.block(RB));
            accOps.add((Object*)accBack);
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H));
        RB.setTerm(br);
        }

    // Tier-2: every remaining (base-case) return hands back acc ⊕ its value.
    void wrapBaseReturns(IRFunc* fn, IRValue* accPhi, String* combineOp, String* accTy)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == 0 || !term.op().equals(String.withCString("Return")))
                continue;
            if (term.ops().count() < (u32)2)
                continue;
            IROperand* valOp = (IROperand*)term.ops().get((u32)0);
            IRValue* wVal = new IRValue(accTy);
            IRInsn* w = IRInsn.with(combineOp);
            w.setRes(wVal);
            w.add(IROperand.useVal(accPhi));
            w.add(valOp);
            bb.add(w);
            term.ops().set((u32)0, (Object*)IROperand.useVal(wVal));
            }
        }

    // ── small maps the passes share ──────────────────────────────────────
    Map* defMapAll(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            noteDefs(defOf, bb.phis());
            noteDefs(defOf, bb.insns());
            if (bb.term() != 0)
                noteDef(defOf, bb.term());
            }
        return defOf;
        }

    void noteDefs(Map* defOf, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            noteDef(defOf, (IRInsn*)list.get(i));
        }

    void noteDef(Map* defOf, IRInsn* n)
        {
        if (n.res() != 0)
            defOf.set((Hashable*)n.res(), (Object*)n);
        if (n.memRes() != 0)
            defOf.set((Hashable*)n.memRes(), (Object*)n);
        }

    Map* defBlockMap(IRFunc* fn)
        {
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            noteBlocks(defBlk, bb.phis(), bb);
            noteBlocks(defBlk, bb.insns(), bb);
            if (bb.term() != 0)
                noteBlock(defBlk, bb.term(), bb);
            }
        return defBlk;
        }

    void noteBlocks(Map* defBlk, Array* list, IRBlock* bb)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            noteBlock(defBlk, (IRInsn*)list.get(i), bb);
        }

    void noteBlock(Map* defBlk, IRInsn* n, IRBlock* bb)
        {
        if (n.res() != 0)
            defBlk.set((Hashable*)n.res(), (Object*)bb);
        if (n.memRes() != 0)
            defBlk.set((Hashable*)n.memRes(), (Object*)bb);
        }

    Map* useCounts(IRFunc* fn)
        {
        Map* uses = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            countUses(uses, bb.phis());
            countUses(uses, bb.insns());
            if (bb.term() != 0)
                countInsnUses(uses, bb.term());
            }
        return uses;
        }

    void countUses(Map* uses, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            countInsnUses(uses, (IRInsn*)list.get(i));
        }

    void countInsnUses(Map* uses, IRInsn* n)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            uses.set((Hashable*)o.val(), (Object*)Number.with(countOf(uses, o.val()) + (u32)1));
            }
        }

    u32 countOf(Map* uses, IRValue* v)
        {
        Object* o = uses.get((Hashable*)v);
        if (o == 0)
            return (u32)0;
        return ((Number*)o).asU32();
        }
    // ── if-convert ───────────────────────────────────────────────────────
    //
    // A diamond whose one arm is PURE — `cond ? f(x) : x` with no memory, no
    // call and nothing that can trap — becomes straight-line code: the arm's
    // instructions are hoisted (they now run unconditionally, which is sound
    // because none of them can be observed) and the join's phis become Selects.
    //
    // One diamond at a time, re-recognised from the live CFG after each
    // transform, because applying one removes a block and rewrites phis.
    // ── jump-thread ──────────────────────────────────────────────────────
    //
    // When a block does nothing but merge a boolean and branch on it, a
    // predecessor supplying a CONSTANT already knows where control goes.
    // Rewiring it to jump straight there removes its edge, and once the phi is
    // down to one incoming the boolean stops existing at all.
    //
    // This is what a short-circuit `&&` leaves behind: the left test's false
    // arm feeds the merge a literal 0, so it is a branch to the exit wearing a
    // phi. sort_small's `j > 0 && a[j-1] > v` was materialising that 0, storing
    // it to a frame slot and loading it back on every iteration of an O(n^2)
    // loop. It cannot be if-converted — the right arm loads a[j-1] and j may
    // be 0.
    void jumpThread(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 pass = (u32)0;
            while (pass < (u32)8 && jumpThreadOnce(fn))
                pass = pass + (u32)1;
            }
        }

    // The constant an operand resolves to, through the widening casts the front
    // end puts on a boolean.
    bool jtConst(IROperand* op, Map* defOf, i32* out)
        {
        if (op == (IROperand*)0)
            return false;
        if (op.kind() == (u8)OPK_IMMI)
            {
            *out = (i32)op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 hop = (u32)0; hop < (u32)8; hop = hop + (u32)1)
            {
            Object* dd = defOf.get((Hashable*)cur);
            if (dd == (Object*)0)
                return false;
            IRInsn* d = (IRInsn*)dd;
            if (d.ops().count() < (u32)1)
                return false;
            IROperand* a0 = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("Const")) && a0.kind() == (u8)OPK_IMMI)
                {
                *out = (i32)a0.imm();
                return true;
                }
            if (!d.op().equals(String.withCString("ZExt")) && !d.op().equals(String.withCString("SExt"))
                && !d.op().equals(String.withCString("Trunc")))
                return false;
            if (a0.kind() != (u8)OPK_USE)
                return false;
            cur = a0.val();
            }
        return false;
        }

    u32 jtUseCount(IRFunc* fn, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            n = n + jtCountIn(bb.phis(), v);
            n = n + jtCountIn(bb.insns(), v);
            if (bb.term() != (IRInsn*)0)
                n = n + jtCountOne(bb.term(), v);
            }
        return n;
        }

    u32 jtCountIn(Array* insns, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            n = n + jtCountOne((IRInsn*)insns.get(i), v);
        return n;
        }

    u32 jtCountOne(IRInsn* i, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 q = (u32)0; q < i.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)i.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                n = n + (u32)1;
            }
        return n;
        }

    bool jumpThreadOnce(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(i);
                if (n.res() != (IRValue*)0) defOf.set((Hashable*)n.res(), (Object*)n);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0) defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* J = (IRBlock*)fn.blocks().get(b);
            // J must do NOTHING but merge and branch: a predecessor rewired
            // past it would skip anything it held.
            if (J.insns().count() != (u32)0 || J.phis().count() != (u32)1)
                continue;
            IRInsn* term = J.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))
                || term.ops().count() < (u32)3)
                continue;
            IROperand* c0 = (IROperand*)term.ops().get((u32)0);
            if (c0.kind() != (u8)OPK_USE)
                continue;
            IRInsn* phi = (IRInsn*)J.phis().get((u32)0);
            if (phi.res() == (IRValue*)0 || phi.res() != c0.val())
                continue;
            if (phi.ops().count() < (u32)4)
                continue;
            // The phi must be read by NOTHING but J's own branch. If anything
            // else reads it — a block J dominates, say — a predecessor rewired
            // past J reaches that read with the phi never having executed and
            // sees whatever was in the register. That shape segfaulted the
            // self-hosted compiler while all 19 benchmarks stayed correct.
            if (jtUseCount(fn, phi.res()) != (u32)1)
                continue;
            IRBlock* onTrue = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* onFalse = ((IROperand*)term.ops().get((u32)2)).blk();
            if (onTrue == (IRBlock*)0 || onFalse == (IRBlock*)0)
                continue;
            // Redirecting into a block with phis would need a new incoming on
            // each; keep to the case where there is nothing to add.
            if (onTrue.phis().count() != (u32)0 || onFalse.phis().count() != (u32)0)
                continue;
            if (onTrue == J || onFalse == J)
                continue;  // a self-edge would drop an incoming still needed
            // The phi's incoming list is NOT the authority on who reaches J:
            // an earlier pass can redirect an edge without touching the phi.
            u32 realPreds = (u32)0;
            for (u32 pb = (u32)0; pb < fn.blocks().count(); pb = pb + (u32)1)
                {
                IRBlock* pbb = (IRBlock*)fn.blocks().get(pb);
                if (pbb.term() == (IRInsn*)0) continue;
                for (u32 q = (u32)0; q < pbb.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)pbb.term().ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == J)
                        realPreds = realPreds + (u32)1;
                    }
                }
            if (realPreds != phi.ops().count() / (u32)2)
                continue;
            if (jtThreadEdge(fn, J, phi, onTrue, onFalse, defOf))
                return true;
            }
        return false;
        }

    // Split out for the arm64 frame budget.
    bool jtThreadEdge(IRFunc* fn, IRBlock* J, IRInsn* phi,
                      IRBlock* onTrue, IRBlock* onFalse, Map* defOf)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IRBlock* P = ((IROperand*)phi.ops().get(k)).blk();
            i32 kv = (i32)0;
            if (P == (IRBlock*)0 || P == J)
                continue;
            if (!jtConst((IROperand*)phi.ops().get(k + (u32)1), defOf, &kv))
                continue;
            IRBlock* dest = (kv != (i32)0) ? onTrue : onFalse;
            IRInsn* pt = P.term();
            if (pt == (IRInsn*)0)
                continue;
            u32 hits = (u32)0;
            for (u32 q = (u32)0; q < pt.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)pt.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == J)
                    hits = hits + (u32)1;
                }
            if (hits != (u32)1)
                continue;
            for (u32 q = (u32)0; q < pt.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)pt.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == J)
                    pt.ops().set(q, (Object*)IROperand.block(dest));
                }
            Array* keep = new Array();
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                if (q != k)
                    {
                    keep.add(phi.ops().get(q));
                    keep.add(phi.ops().get(q + (u32)1));
                    }
            while (phi.ops().count() > (u32)0)
                phi.ops().removeAt(phi.ops().count() - (u32)1);
            for (u32 q = (u32)0; q < keep.count(); q = q + (u32)1)
                phi.ops().add(keep.get(q));

            // A phi with ONE incoming IS that incoming. Collapsing it is what
            // actually removes the boolean: left standing it is a value the
            // allocator must place, and a miss costs a store and a reload every
            // iteration — the whole cost this pass exists to remove.
            if (keep.count() == (u32)2
                && ((IROperand*)keep.get((u32)1)).kind() == (u8)OPK_USE)
                {
                IRValue* from = phi.res();
                IRValue* to = ((IROperand*)keep.get((u32)1)).val();
                for (u32 bb2 = (u32)0; bb2 < fn.blocks().count(); bb2 = bb2 + (u32)1)
                    {
                    IRBlock* bb = (IRBlock*)fn.blocks().get(bb2);
                    jtReplace(bb.phis(), from, to);
                    jtReplace(bb.insns(), from, to);
                    if (bb.term() != (IRInsn*)0)
                        jtReplaceOne(bb.term(), from, to);
                    }
                J.phis().removeAt((u32)0);
                }
            return true;
            }
        return false;
        }

    void jtReplace(Array* insns, IRValue* from, IRValue* to)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            jtReplaceOne((IRInsn*)insns.get(i), from, to);
        }

    void jtReplaceOne(IRInsn* n, IRValue* from, IRValue* to)
        {
        for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() == from)
                n.ops().set(q, (Object*)IROperand.useVal(to));
            }
        }

    void ifConvert(IRModule* m)
        {
        if (!_profile.ifConvert())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 iter = (u32)0; iter < (u32)4096; iter = iter + (u32)1)
                if (!ifConvertOnce(fn))
                    break;
            }
        }

    // The recognised diamond, reported through fields: the language has no
    // tuple return that would read better here.
    IRBlock* _icH;
    IRBlock* _icT;
    IRBlock* _icJ;
    IRValue* _icCond;
    bool _icTIsTrue;

    bool ifConvertOnce(IRFunc* fn)
        {
        if (!recogniseDiamond(fn))
            return false;
        applyDiamond(fn);
        return true;
        }

    bool recogniseDiamond(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = H.term();
            if (term == 0)
                continue;
            if (!term.op().equals(String.withCString("CondBranch")))
                continue;
            if (term.ops().count() < (u32)3)
                continue;
            IROperand* condOp = (IROperand*)term.ops().get((u32)0);
            if (condOp.kind() != (u8)OPK_USE || condOp.val() == 0)
                continue;
            IRBlock* tA = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* fA = ((IROperand*)term.ops().get((u32)2)).blk();
            if (tA == 0 || fA == 0 || tA == fA)
                continue;

            IRBlock* T = (IRBlock*)0;
            IRBlock* J = (IRBlock*)0;
            bool tIsTrue = false;
            if (isPureMiddle(fn, tA, H, fA))
                {
                T = tA;
                J = fA;
                tIsTrue = true;
                }
            else if (isPureMiddle(fn, fA, H, tA))
                {
                T = fA;
                J = tA;
                tIsTrue = false;
                }
            else
                continue;
            if (J == 0 || J == H || J == T)
                continue;
            if (J.phis().count() == (u32)0)
                continue; // nothing to select

            // The join's predecessors must be exactly {H, T}: any other edge
            // and the phis carry values this transform cannot account for.
            Array* jp = predsOfBlock(fn, J);
            if (jp.count() != (u32)2)
                continue;
            if (!(hasBlock(jp, H) && hasBlock(jp, T)))
                continue;

            _icH = H;
            _icT = T;
            _icJ = J;
            _icCond = condOp.val();
            _icTIsTrue = tIsTrue;
            return true;
            }
        return false;
        }

    // A "pure middle": one predecessor (the head), no phis, a body that can run
    // unconditionally, and an unconditional Branch to the join.
    bool isPureMiddle(IRFunc* fn, IRBlock* M, IRBlock* H, IRBlock* dest)
        {
        if (M == 0 || M == H)
            return false;
        if (M.phis().count() != (u32)0)
            return false;
        IRInsn* t = M.term();
        if (t == 0 || !t.op().equals(String.withCString("Branch")))
            return false;
        if (t.ops().count() < (u32)1)
            return false;
        if (((IROperand*)t.ops().get((u32)0)).blk() != dest)
            return false;
        for (u32 i = (u32)0; i < M.insns().count(); i = i + (u32)1)
            if (!speculatable((IRInsn*)M.insns().get(i)))
                return false;
        Array* mp = predsOfBlock(fn, M);
        return mp.count() == (u32)1 && (IRBlock*)mp.get((u32)0) == H;
        }

    // Safe to execute unconditionally: a pure value computation with no memory
    // effect and nothing that traps. Div and Rem are NOT here (divide by zero),
    // nor is anything with a memory result.
    bool speculatable(IRInsn* n)
        {
        if (n.memRes() != 0)
            return false;
        String* op = n.op();
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("Copy")) || op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("Neg")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Not")) || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")) || op.equals(String.withCString("Rol")) || op.equals(String.withCString("Ror")) || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FNeg")) || op.equals(String.withCString("FSqrt")) || op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")) || op.equals(String.withCString("Select")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast")) || op.equals(String.withCString("IntToPtr")) || op.equals(String.withCString("PtrToInt")) || op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")) || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")) || op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc")) || op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("FieldAddr")) || op.equals(String.withCString("ElementAddr"));
        }

    Array* predsOfBlock(IRFunc* fn, IRBlock* target)
        {
        Array* out = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = src.term();
            if (t == 0)
                continue;
            for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(i);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() != target)
                    continue;
                out.add((Object*)src);
                break;
                }
            }
        return out;
        }

    bool hasBlock(Array* bs, IRBlock* b)
        {
        for (u32 i = (u32)0; i < bs.count(); i = i + (u32)1)
            if ((IRBlock*)bs.get(i) == b)
                return true;
        return false;
        }

    void applyDiamond(IRFunc* fn)
        {
        IRBlock* H = _icH;
        IRBlock* T = _icT;
        IRBlock* J = _icJ;
        Map* defOf = defMapAll(fn);

        // The arm's instructions move into the head, ahead of its terminator.
        for (u32 i = (u32)0; i < T.insns().count(); i = i + (u32)1)
            H.add((IRInsn*)T.insns().get(i));

        Array* phis = new Array();
        for (u32 i = (u32)0; i < J.phis().count(); i = i + (u32)1)
            phis.add(J.phis().get(i));
        Array* keptPhis = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)phis.get(i);
            if (!selectForPhi(fn, defOf, phi, H, T))
                keptPhis.add((Object*)phi);
            }
        J.setPhis(keptPhis);

        // The head now falls straight through to the join; the arm is gone.
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(J));
        H.setTerm(br);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != T)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }

    // One join phi becomes a Select (or a boolean And/Or) in the head. False
    // when the phi is not the two-way merge this transform expects.
    bool selectForPhi(IRFunc* fn, Map* defOf, IRInsn* phi, IRBlock* H, IRBlock* T)
        {
        if (phi.res() == 0)
            return false;
        IROperand* vT = (IROperand*)0;
        IROperand* vH = (IROperand*)0;
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IRBlock* pb = ((IROperand*)phi.ops().get(k)).blk();
            if (pb == T)
                vT = (IROperand*)phi.ops().get(k + (u32)1);
            else if (pb == H)
                vH = (IROperand*)phi.ops().get(k + (u32)1);
            }
        if (vT == 0 || vH == 0)
            return false;

        IROperand* selTrue = _icTIsTrue ? vT : vH;
        IROperand* selFalse = _icTIsTrue ? vH : vT;
        String* ty = phi.res().ty();
        IRValue* res = new IRValue(ty);
        IROperand* condUse = IROperand.useVal(_icCond);

        // `cond ? rhs : false` is `cond & rhs`, and `cond ? true : rhs` is
        // `cond | rhs` — one instruction, no condition to materialise. Only
        // when BOTH inputs are strictly 0/1: And(2,1) is 0 where 2?1:0 is 1.
        bool isBool = ty.equals(String.withCString("Bool"));
        bool condOK = isBool01(defOf, condUse);
        IRInsn* repl;
        if (isBool && condOK && isBoolConst(defOf, selFalse, (i32)0) && isBool01(defOf, selTrue))
            {
            repl = IRInsn.with(String.withCString("And"));
            repl.add(condUse);
            repl.add(selTrue);
            }
        else if (isBool && condOK && isBoolConst(defOf, selTrue, (i32)1) && isBool01(defOf, selFalse))
            {
            repl = IRInsn.with(String.withCString("Or"));
            repl.add(condUse);
            repl.add(selFalse);
            }
        else
            {
            repl = IRInsn.with(String.withCString("Select"));
            repl.add(condUse);
            repl.add(selTrue);
            repl.add(selFalse);
            }
        repl.setRes(res);
        H.add(repl);
        rewriteUsesTo(fn, phi.res(), IROperand.useVal(res));
        return true;
        }

    // A Use that resolves to a Bool Const of exactly `want`.
    bool isBoolConst(Map* defOf, IROperand* op, i32 want)
        {
        if (op == 0 || op.kind() != (u8)OPK_USE || op.val() == 0)
            return false;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return false;
        IRInsn* n = (IRInsn*)d;
        if (!n.op().equals(String.withCString("Const")))
            return false;
        if (n.ops().count() < (u32)1)
            return false;
        IROperand* imm = (IROperand*)n.ops().get((u32)0);
        if (imm.kind() != (u8)OPK_IMMI)
            return false;
        if (imm.ty() == 0 || !imm.ty().equals(String.withCString("Bool")))
            return false;
        return imm.imm() == want;
        }

    // Provably 0 or 1: a comparison result, or a 0/1 bool constant. A loaded
    // bool or a truncation is not, and the caller falls back to Select.
    bool isBool01(Map* defOf, IROperand* op)
        {
        if (op == 0 || op.kind() != (u8)OPK_USE || op.val() == 0)
            return false;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return false;
        IRInsn* n = (IRInsn*)d;
        if (n.op().equals(String.withCString("ICmp")) || n.op().equals(String.withCString("FCmp")))
            return true;
        return isBoolConst(defOf, op, (i32)0) || isBoolConst(defOf, op, (i32)1);
        }
    // ── static-init-guard-elim ───────────────────────────────────────────
    //
    // A class's statics are initialised behind a flag:
    //
    //     %p   = AddrOf @__sinit_X ; %v = Load %p ; %c = ICmp EQ %v, 0
    //     CondBranch %c, run, cont       run: Store %p,1 ; … ; Call X$init
    //
    // Once one such guard has run, every later guard for the same class on a
    // path it dominates is provably taken — so it comes out. Where the profile
    // allows it, one guard per class is HOISTED to the function entry first,
    // which makes it dominate every in-body guard and turns a loop body back
    // into a single block.
    //
    // The recognised guard, reported through fields.
    IRBlock* _sgGuard;
    IRBlock* _sgRun;
    IRBlock* _sgCont;
    String* _sgSym;
    IROperand* _sgLoadMemIn;
    IRInsn* _sgAddr;
    IRInsn* _sgLoad;
    IRInsn* _sgIcmp;
    IRInsn* _sgConst0;

    void staticInitGuard(IRModule* m)
        {
        if (!_profile.initGuardElim())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            initGuardsInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    // Each guard is kept as five parallel arrays — the language has no record
    // type here, and a class per pass would say less than the names do.
    Array* _sgGuards; // IRBlock@ (the check)
    Array* _sgRuns;   // IRBlock@ (the init body)
    Array* _sgConts;  // IRBlock@ (the straight-through)
    Array* _sgSyms;   // String@  (__sinit_X)
    Array* _sgMemIns; // IROperand@ or 0 (the flag Load's incoming memory)
    Array* _sgAddrs;  // IRInsn@  (AddrOf)
    Array* _sgLoads;  // IRInsn@  (Load)
    Array* _sgIcmps;  // IRInsn@  (ICmp)
    Array* _sgConsts; // IRInsn@ or 0 (the Const 0, when separate)

    // Memory tokens this pass has already bypassed, so a later fold whose
    // target an earlier one removed can follow the chain to a live one.
    Map* _sgBypass;

    void initGuardsInFunc(IRModule* m, IRFunc* fn)
        {
        if (fn.blocks().count() < (u32)2)
            return;
        _sgBypass = new Map();
        recogniseGuards(m, fn);
        if (_sgGuards.count() < (u32)1)
            return;

        if (_profile.initGuardHoist())
            {
            hoistGuardsToEntry(m, fn);
            recogniseGuards(m, fn);
            }
        if (_sgGuards.count() < (u32)2)
            return;

        // Redundant: another guard for the SAME class has its straight-through
        // block dominating this one — the flag is set on every path here.
        Map* dom = dominators(fn);
        Array* redundant = new Array();
        for (u32 i = (u32)0; i < _sgGuards.count(); i = i + (u32)1)
            {
            for (u32 j = (u32)0; j < _sgGuards.count(); j = j + (u32)1)
                {
                if (i == j)
                    continue;
                if (!((String*)_sgSyms.get(j)).equals((String*)_sgSyms.get(i)))
                    continue;
                Object* ds = dom.get((Hashable*)(IRBlock*)_sgGuards.get(i));
                if (ds == 0)
                    continue;
                if (!hasBlock((Array*)ds, (IRBlock*)_sgConts.get(j)))
                    continue;
                redundant.add((Object*)Number.with(i));
                break;
                }
            }
        for (u32 k = (u32)0; k < redundant.count(); k = k + (u32)1)
            foldGuard(fn, ((Number*)redundant.get(k)).asU32());
        // Folding leaves a chain of unconditional branches; coalescing them is
        // what puts the loop body back in one block for the unroller.
        if (redundant.count() > (u32)0)
            coalesceStraightLine(fn);
        }

    void recogniseGuards(IRModule* m, IRFunc* fn)
        {
        _sgGuards = new Array();
        _sgRuns = new Array();
        _sgConts = new Array();
        _sgSyms = new Array();
        _sgMemIns = new Array();
        _sgAddrs = new Array();
        _sgLoads = new Array();
        _sgIcmps = new Array();
        _sgConsts = new Array();
        Map* defOf = defMapAll(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* G = (IRBlock*)fn.blocks().get(b);
            if (!recogniseGuard(m, fn, G, defOf))
                continue;
            _sgGuards.add((Object*)_sgGuard);
            _sgRuns.add((Object*)_sgRun);
            _sgConts.add((Object*)_sgCont);
            _sgSyms.add((Object*)_sgSym);
            _sgMemIns.add((Object*)_sgLoadMemIn);
            _sgAddrs.add((Object*)_sgAddr);
            _sgLoads.add((Object*)_sgLoad);
            _sgIcmps.add((Object*)_sgIcmp);
            _sgConsts.add((Object*)_sgConst0);
            }
        }

    bool recogniseGuard(IRModule* m, IRFunc* fn, IRBlock* G, Map* defOf)
        {
        IRInsn* term = G.term();
        if (term == 0 || !term.op().equals(String.withCString("CondBranch")))
            return false;
        if (term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE || c0.val() == 0)
            return false;
        IROperand* o1 = (IROperand*)term.ops().get((u32)1);
        IROperand* o2 = (IROperand*)term.ops().get((u32)2);
        if (o1.kind() != (u8)OPK_BLOCK || o2.kind() != (u8)OPK_BLOCK)
            return false;

        Object* d = defOf.get((Hashable*)c0.val());
        if (d == 0)
            return false;
        IRInsn* icmp = (IRInsn*)d;
        if (!icmp.op().equals(String.withCString("ICmp")))
            return false;
        // Two shapes. Single-threaded: `ICmp EQ flag, 0`, run block stores 1.
        // Threaded (threading.md §9.5): `ICmp NE flag, 2`, run block calls
        // _xtc_sinit_run, which sets the flag itself.
        if (icmp.pred() == 0)
            return false;
        i32 wantConst = (i32)0;
        if (icmp.pred().equals(String.withCString("EQ")))
            wantConst = (i32)0;
        else if (icmp.pred().equals(String.withCString("NE")))
            wantConst = (i32)2;
        else
            return false;
        if (icmp.ops().count() < (u32)2)
            return false;
        IROperand* lhs = (IROperand*)icmp.ops().get((u32)0);
        if (lhs.kind() != (u8)OPK_USE || lhs.val() == 0)
            return false;
        if (!isConstOperand(defOf, (IROperand*)icmp.ops().get((u32)1), wantConst))
            return false;

        Object* dl = defOf.get((Hashable*)lhs.val());
        if (dl == 0)
            return false;
        IRInsn* load = (IRInsn*)dl;
        if (!load.op().equals(String.withCString("Load")))
            return false;
        if (load.ops().count() < (u32)1)
            return false;
        IROperand* pa = (IROperand*)load.ops().get((u32)0);
        if (pa.kind() != (u8)OPK_USE || pa.val() == 0)
            return false;
        Object* da = defOf.get((Hashable*)pa.val());
        if (da == 0)
            return false;
        IRInsn* addr = (IRInsn*)da;
        if (!addr.op().equals(String.withCString("AddrOf")))
            return false;
        if (addr.ops().count() < (u32)1)
            return false;
        IROperand* sym = (IROperand*)addr.ops().get((u32)0);
        if (sym.kind() != (u8)OPK_SYM || sym.name() == 0)
            return false;
        if (!sym.name().hasPrefix(String.withCString("__sinit")))
            return false;

        IRBlock* run = o1.blk(); // EQ true (flag == 0) → initialise
        IRBlock* cont = o2.blk();
        if (run == 0 || cont == 0 || run == cont)
            return false;
        // A phi in `cont` could carry a value from the init block; folding the
        // guard would leave it dangling. The lowering's cont has none.
        if (cont.phis().count() != (u32)0)
            return false;
        Array* rp = predsOfBlock(fn, run);
        if (rp.count() != (u32)1 || (IRBlock*)rp.get((u32)0) != G)
            return false;
        if (run.term() == 0 || !run.term().op().equals(String.withCString("Branch")))
            return false;
        Array* rs = successorsOf(run);
        if (rs.count() != (u32)1 || (IRBlock*)rs.get((u32)0) != cont)
            return false;
        if (!storesFlag(m, defOf, run, sym.name()))
            return false;

        _sgGuard = G;
        _sgRun = run;
        _sgCont = cont;
        _sgSym = sym.name();
        _sgLoadMemIn = load.ops().count() >= (u32)2
                           ? (IROperand*)load.ops().get((u32)1)
                           : (IROperand*)0;
        _sgAddr = addr;
        _sgLoad = load;
        _sgIcmp = icmp;
        IROperand* rhs = (IROperand*)icmp.ops().get((u32)1);
        _sgConst0 = (IRInsn*)0;
        if (rhs.kind() == (u8)OPK_USE && rhs.val() != 0)
            {
            Object* cd = defOf.get((Hashable*)rhs.val());
            if (cd != 0)
                _sgConst0 = (IRInsn*)cd;
            }
        return true;
        }

    // The init block must set the very flag the check read.
    bool storesFlag(IRModule* m, Map* defOf, IRBlock* run, String* symName)
        {
        for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)run.insns().get(i);
            // Single-threaded: a Store of 1 to the flag. Threaded: the store
            // happens inside _xtc_sinit_run, so the proof is a call to it whose
            // first argument is this flag.
            IROperand* a = (IROperand*)0;
            if (n.op().equals(String.withCString("Store")))
                {
                if (n.ops().count() < (u32)1)
                    continue;
                a = (IROperand*)n.ops().get((u32)0);
                }
            else if (n.op().equals(String.withCString("Call")))
                {
                if (n.ops().count() < (u32)2)
                    continue;
                IROperand* cal = (IROperand*)n.ops().get((u32)0);
                if (cal.kind() != (u8)OPK_SYM || cal.name() == 0)
                    continue;
                if (!cal.name().equals(String.withCString("_xtc_sinit_run")))
                    continue;
                a = (IROperand*)n.ops().get((u32)1);
                }
            else
                continue;
            if (a.kind() != (u8)OPK_USE || a.val() == 0)
                continue;
            Object* d = defOf.get((Hashable*)a.val());
            if (d == 0)
                continue;
            IRInsn* sa = (IRInsn*)d;
            if (!sa.op().equals(String.withCString("AddrOf")))
                continue;
            if (sa.ops().count() < (u32)1)
                continue;
            IROperand* ss = (IROperand*)sa.ops().get((u32)0);
            if (ss.kind() != (u8)OPK_SYM || ss.name() == 0)
                continue;
            if (ss.name().equals(symName))
                return true;
            }
        return false;
        }

    bool isConstOperand(Map* defOf, IROperand* op, i32 want)
        {
        if (op.kind() == (u8)OPK_IMMI)
            return op.imm() == want;
        if (op.kind() != (u8)OPK_USE || op.val() == 0)
            return false;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return false;
        IRInsn* n = (IRInsn*)d;
        if (!n.op().equals(String.withCString("Const")))
            return false;
        if (n.ops().count() < (u32)1)
            return false;
        IROperand* imm = (IROperand*)n.ops().get((u32)0);
        return imm.kind() == (u8)OPK_IMMI && imm.imm() == want;
        }

    Array* successorsOf(IRBlock* b)
        {
        Array* out = new Array();
        if (b.term() == 0)
            return out;
        for (u32 i = (u32)0; i < b.term().ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)b.term().ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != 0)
                out.add((Object*)o.blk());
            }
        return out;
        }

    // Iterative dominators over the CFG, entry = the first block. A block maps
    // to the ARRAY of blocks that dominate it.
    Map* dominators(IRFunc* fn)
        {
        Map* dom = new Map();
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* init = new Array();
            if (bb == entry)
                init.add((Object*)entry);
            else
                for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
                    init.add(fn.blocks().get(k));
            dom.set((Hashable*)bb, (Object*)init);
            }
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (bb == entry)
                    continue;
                if (refineDominators(fn, dom, bb))
                    changed = true;
                }
            }
        return dom;
        }

    // One block's dominator set: the intersection of its predecessors' sets,
    // plus itself. True when it shrank.
    bool refineDominators(IRFunc* fn, Map* dom, IRBlock* bb)
        {
        Array* preds = predsOfBlock(fn, bb);
        Array* nd = (Array*)0;
        for (u32 p = (u32)0; p < preds.count(); p = p + (u32)1)
            {
            Array* dp = (Array*)dom.get((Hashable*)(IRBlock*)preds.get(p));
            if (dp == 0)
                continue;
            if (nd == 0)
                {
                nd = new Array();
                for (u32 k = (u32)0; k < dp.count(); k = k + (u32)1)
                    nd.add(dp.get(k));
                continue;
                }
            Array* keep = new Array();
            for (u32 k = (u32)0; k < nd.count(); k = k + (u32)1)
                if (hasBlock(dp, (IRBlock*)nd.get(k)))
                    keep.add(nd.get(k));
            nd = keep;
            }
        if (nd == 0)
            nd = new Array();
        if (!hasBlock(nd, bb))
            nd.add((Object*)bb);
        Array* old = (Array*)dom.get((Hashable*)bb);
        if (old != 0 && old.count() == nd.count())
            return false;
        dom.set((Hashable*)bb, (Object*)nd);
        return true;
        }

    // Bypass the check, drop the now-unreachable init block, and rewire uses of
    // its memory tokens to the guard's incoming memory so the chain stays
    // well-formed. The dead check tail is left to the dead-code pass.
    void foldGuard(IRFunc* fn, u32 idx)
        {
        IRBlock* G = (IRBlock*)_sgGuards.get(idx);
        IRBlock* run = (IRBlock*)_sgRuns.get(idx);
        IRBlock* cont = (IRBlock*)_sgConts.get(idx);
        if (!hasBlock(fn.blocks(), G) || !hasBlock(fn.blocks(), run))
            return;
        IROperand* memIn = (IROperand*)_sgMemIns.get(idx);
        if (memIn != 0 && memIn.kind() == (u8)OPK_USE && memIn.val() != 0)
            {
            // The target may itself have been removed by an earlier fold — two
            // guards for one class chain, and the second's incoming memory was
            // defined in the first's init block.
            IRValue* target = resolveBypass(_sgBypass, memIn.val());
            for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)run.insns().get(i);
                if (n.memRes() == 0)
                    continue;
                _sgBypass.set((Hashable*)n.memRes(), (Object*)target);
                forwardMem(fn, n.memRes(), target);
                }
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(cont));
        G.setTerm(br);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != run)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }

    // Merge `A -Branch-> B` when B's only predecessor is A: B's instructions
    // and terminator move into A, and B's successors' phis now name A.
    void coalesceStraightLine(IRFunc* fn)
        {
        bool changed = true;
        while (changed)
            {
            changed = false;
            IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
            for (u32 a = (u32)0; a < fn.blocks().count(); a = a + (u32)1)
                {
                if (changed)
                    break;
                IRBlock* A = (IRBlock*)fn.blocks().get(a);
                IRInsn* t = A.term();
                if (t == 0 || !t.op().equals(String.withCString("Branch")))
                    continue;
                if (t.ops().count() < (u32)1)
                    continue;
                IROperand* o = (IROperand*)t.ops().get((u32)0);
                if (o.kind() != (u8)OPK_BLOCK)
                    continue;
                IRBlock* B = o.blk();
                if (B == 0 || B == A || B == entry)
                    continue;
                if (B.phis().count() != (u32)0)
                    continue;
                Array* bp = predsOfBlock(fn, B);
                if (bp.count() != (u32)1 || (IRBlock*)bp.get((u32)0) != A)
                    continue;
                mergeBlocks(fn, A, B);
                changed = true;
                }
            }
        }

    void mergeBlocks(IRFunc* fn, IRBlock* A, IRBlock* B)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            A.add((IRInsn*)B.insns().get(i));
        A.setTerm(B.term());
        // B's successors named B as a predecessor; they now name A.
        Array* succ = successorsOf(A);
        for (u32 s = (u32)0; s < succ.count(); s = s + (u32)1)
            {
            IRBlock* S = (IRBlock*)succ.get(s);
            for (u32 i = (u32)0; i < S.phis().count(); i = i + (u32)1)
                {
                IRInsn* phi = (IRInsn*)S.phis().get(i);
                for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
                    {
                    IROperand* po = (IROperand*)phi.ops().get(k);
                    if (po.kind() != (u8)OPK_BLOCK || po.blk() != B)
                        continue;
                    phi.ops().set(k, (Object*)IROperand.block(A));
                    }
                }
            }
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != B)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }
    // Hoist ONE guard per class to the entry: chk_0 → (run_0) → mrg_0 → chk_1
    // → … → the old entry. Each is built from a representative in-body guard,
    // and the in-body ones are then dominated and folded away. Eager init at
    // entry rather than at first use — sound for an idempotent class init the
    // function unconditionally reaches, and validated by the sweep.
    // ── Is it safe to run this class's `init` EARLIER than its first use? ──
    //
    // Hoisting to the function entry relocates the initialiser, so an `init`
    // that can OBSERVE program state set up in between reads the earlier value —
    // silently, and only at -O2. See private:docs/bugs/059.
    //
    // Deliberately crude, because a wrong YES is a wrong answer in the compiled
    // program: any Call at all, or any symbol reference that is not this class's
    // own static data, disqualifies it. Stdio/Assert-style initialisers — set my
    // own statics from constants — still pass, which is the case the
    // optimisation exists for.
    bool initIsHoistable(IRModule* m, String* flagSym)
        {
        if (!flagSym.hasPrefix(String.withCString("__sinit_")))
            return false;
        String* cls = flagSym.substringFromByte((u32)8);
        String* initName = String.withString(cls);
        initName.appendCString("$init");
        String* ownData = String.withCString("__sdata_");
        ownData.append(cls);
        String* ownIvar = String.withCString("__sivar_");
        ownIvar.append(cls);
        ownIvar.appendCString("_");

        IRFunc* initFn = (IRFunc*)0;
        for (u32 i = (u32)0; i < m.funcs().count(); i = i + (u32)1)
            {
            IRFunc* f = (IRFunc*)m.funcs().get(i);
            if (f.name().equals(initName))
                {
                initFn = f;
                break;
                }
            }
        if (initFn == 0)
            return false; // no body visible -> assume the worst

        for (u32 b = (u32)0; b < initFn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)initFn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (n.op().equals(String.withCString("Call")))
                    return false;
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* op = (IROperand*)n.ops().get(k);
                    if (op.kind() != (u8)OPK_SYM || op.name() == 0)
                        continue;
                    if (op.name().equals(ownData))
                        continue;
                    if (op.name().hasPrefix(ownIvar))
                        continue;
                    return false;
                    }
                }
            }
        return true;
        }

    void hoistGuardsToEntry(IRModule* m, IRFunc* fn)
        {
        if (_sgGuards.count() == (u32)0 || fn.blocks().count() == (u32)0)
            return;
        u32 pc = fn.params().count();
        if (pc == (u32)0)
            return;
        // The function's memory token is its last parameter, and it dominates
        // everything — so it is what the entry guard's Load reads.
        IROperand* entryMem = IROperand.useVal((IRValue*)fn.params().get(pc - (u32)1));
        IRBlock* oldEntry = (IRBlock*)fn.blocks().get((u32)0);

        Array* reps = new Array(); // one guard index per class
        Array* seen = new Array();
        for (u32 i = (u32)0; i < _sgGuards.count(); i = i + (u32)1)
            {
            String* sym = (String*)_sgSyms.get(i);
            if (has(seen, sym))
                continue;
            // bug 059: only relocate an initialiser that cannot tell it moved.
            if (!initIsHoistable(m, sym))
                continue;
            seen.add((Object*)sym);
            reps.add((Object*)Number.with(i));
            }
        if (reps.count() == (u32)0)
            return;

        Array* newBlocks = new Array();
        Array* checks = new Array();
        Array* merges = new Array();
        for (u32 r = (u32)0; r < reps.count(); r = r + (u32)1)
            {
            u32 idx = ((Number*)reps.get(r)).asU32();
            buildHoistedGuard(fn, idx, entryMem, newBlocks, checks, merges);
            }

        // mrg_i branches to chk_{i+1}; the last one to the old entry.
        for (u32 i = (u32)0; i < merges.count(); i = i + (u32)1)
            {
            IRBlock* target = (i + (u32)1 < checks.count())
                                  ? (IRBlock*)checks.get(i + (u32)1)
                                  : oldEntry;
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(target));
            ((IRBlock*)merges.get(i)).setTerm(br);
            }
        fn.blocks().insertAll((u32)0, newBlocks);
        }

    void buildHoistedGuard(IRFunc* fn, u32 idx, IROperand* entryMem,
                           Array* newBlocks, Array* checks, Array* merges)
        {
        String* sym = (String*)_sgSyms.get(idx);
        IRInsn* addr = (IRInsn*)_sgAddrs.get(idx);
        IRInsn* load = (IRInsn*)_sgLoads.get(idx);
        IRInsn* icmp = (IRInsn*)_sgIcmps.get(idx);
        IRInsn* const0 = (IRInsn*)_sgConsts.get(idx);
        IRBlock* run = (IRBlock*)_sgRuns.get(idx);

        IRBlock* C = new IRBlock(hoistName(sym, "_hoist_chk"));
        IRBlock* R = new IRBlock(hoistName(sym, "_hoist_run"));
        IRBlock* M = new IRBlock(hoistName(sym, "_hoist_mrg"));
        // Creation ORDER is load-bearing: the original allocates the load's
        // DATA value before its memory token (freshVal v, then m1), and the
        // after-the-fact numbering must replay exactly that sequence.
        IRValue* a = new IRValue(addr.res().ty());
        IRValue* v = new IRValue(load.res().ty());
        IRValue* m1 = new IRValue(String.withCString("Mem"));

        buildHoistedCheck(C, R, M, addr, load, icmp, const0, entryMem, a, v, m1);
        cloneInitBlock(run, R, M, addr, load, a, m1);

        newBlocks.add((Object*)C);
        newBlocks.add((Object*)R);
        newBlocks.add((Object*)M);
        checks.add((Object*)C);
        merges.add((Object*)M);
        }

    // The hoisted CHECK block: AddrOf the flag, Load it, compare against zero,
    // and branch to the cloned init or straight to the merge.
    void buildHoistedCheck(IRBlock* C, IRBlock* R, IRBlock* M,
                           IRInsn* addr, IRInsn* load, IRInsn* icmp, IRInsn* const0,
                           IROperand* entryMem, IRValue* a, IRValue* v, IRValue* m1)
        {
        IRInsn* ad = IRInsn.with(String.withCString("AddrOf"));
        ad.setRes(a);
        for (u32 k = (u32)0; k < addr.ops().count(); k = k + (u32)1)
            ad.add((IROperand*)addr.ops().get(k));
        C.add(ad);

        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        ld.setRes(v);
        ld.setMemRes(m1);
        ld.add(IROperand.useVal(a));
        ld.add(entryMem);
        C.add(ld);

        IROperand* rhs;
        if (const0 != 0)
            {
            IRValue* z = new IRValue(const0.res().ty());
            IRInsn* zi = IRInsn.with(String.withCString("Const"));
            zi.setRes(z);
            for (u32 k = (u32)0; k < const0.ops().count(); k = k + (u32)1)
                zi.add((IROperand*)const0.ops().get(k));
            C.add(zi);
            rhs = IROperand.useVal(z);
            }
        else
            {
            rhs = (IROperand*)icmp.ops().get((u32)1); // the immediate 0
            }
        IRValue* c = new IRValue(icmp.res().ty());
        IRInsn* cm = IRInsn.with(String.withCString("ICmp"));
        cm.setRes(c);
        cm.setPred(String.withString(icmp.pred())); // EQ/0 or NE/2 — same guard
        cm.add(IROperand.useVal(ld.res()));
        cm.add(rhs);
        C.add(cm);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(c));
        cb.add(IROperand.block(R));
        cb.add(IROperand.block(M));
        C.setTerm(cb);
        }

    // The representative's init block, cloned into `R`. Its Store names the
    // guard block's AddrOf and threads the guard Load's memory, so both remap
    // onto the clones the check block just built.
    void cloneInitBlock(IRBlock* run, IRBlock* R, IRBlock* M,
                        IRInsn* addr, IRInsn* load, IRValue* a, IRValue* m1)
        {
        Map* map = new Map();
        map.set((Hashable*)addr.res(), (Object*)IROperand.useVal(a));
        if (load.memRes() != 0)
            map.set((Hashable*)load.memRes(), (Object*)IROperand.useVal(m1));
        for (u32 i = (u32)0; i < run.insns().count(); i = i + (u32)1)
            R.add(cloneWithFreshResults(map, (IRInsn*)run.insns().get(i)));
        IRInsn* rbr = IRInsn.with(String.withCString("Branch"));
        rbr.add(IROperand.block(M));
        R.setTerm(rbr);
        }

    IRInsn* cloneWithFreshResults(Map* map, IRInsn* n)
        {
        IRInsn* cl = IRInsn.with(n.op());
        cl.setPred(n.pred());
        cl.setCc(n.cc());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            cl.add(substOperand(map, (IROperand*)n.ops().get(k)));
        if (n.res() != 0)
            {
            IRValue* nr = new IRValue(n.res().ty());
            cl.setRes(nr);
            map.set((Hashable*)n.res(), (Object*)IROperand.useVal(nr));
            }
        if (n.memRes() != 0)
            {
            IRValue* nm = new IRValue(String.withCString("Mem"));
            cl.setMemRes(nm);
            map.set((Hashable*)n.memRes(), (Object*)IROperand.useVal(nm));
            }
        return cl;
        }

    String* hoistName(String* sym, string suffix)
        {
        String* n = String.withString(sym);
        n.appendCString(suffix);
        return n;
        }
    // ── idiom-memset ─────────────────────────────────────────────────────
    //
    // `for (i = 0; i < N; i++) p[i] = k;` over BYTES, with a constant bound and
    // a constant fill, is one MemSet in the preheader and no loop at all. The
    // recognition is deliberately narrow — unit stride from zero, one store,
    // nothing else with a memory effect, an induction variable that does not
    // escape — because everything it does not recognise simply stays a loop.
    IRBlock* _msH;
    IRBlock* _msB;
    IRBlock* _msE;
    IRBlock* _msP;
    IRInsn* _msStore;
    IRInsn* _msBaseDef; // an AddrOf to clone into the preheader, or 0
    IRValue* _msBase;
    i32 _msBound;
    bool _msInclusive;
    i32 _msFill;
    IRValue* _msMemIn;
    IRValue* _msMemOut;

    void idiomMemset(IRModule* m)
        {
        if (!_profile.memsetIdiom())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 iter = (u32)0; iter < (u32)256; iter = iter + (u32)1)
                {
                if (!recogniseMemset(fn))
                    break;
                applyMemset(fn);
                }
            }
        }

    bool recogniseMemset(IRFunc* fn)
        {
        Map* defOf = defMapAll(fn);
        Map* defBlk = defBlockMap(fn);
        Map* uses = useCounts(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            if (memsetHeader(fn, H, defOf, defBlk, uses))
                return true;
            }
        return false;
        }

    // The loop HEADER: one integer phi, a pure body, and a CondBranch on a
    // comparison of that phi against a constant.
    bool memsetHeader(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (H.phis().count() != (u32)1)
            return false;
        IRInsn* ivPhi = (IRInsn*)H.phis().get((u32)0);
        if (ivPhi.res() == 0 || ivPhi.memRes() != 0)
            return false;
        if (irWidth(ivPhi.res().ty()) == (u32)0)
            return false;
        IRValue* iv = ivPhi.res();
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != 0)
                return false;

        IRInsn* term = H.term();
        if (term == 0 || !term.op().equals(String.withCString("CondBranch")))
            return false;
        if (term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE || c0.val() == 0)
            return false;
        Object* gd = defOf.get((Hashable*)c0.val());
        if (gd == 0)
            return false;
        IRInsn* guard = (IRInsn*)gd;
        if (!guard.op().equals(String.withCString("ICmp")))
            return false;
        if (defBlk.get((Hashable*)c0.val()) != (Object*)H)
            return false;
        if (guard.ops().count() < (u32)2)
            return false;
        IROperand* g0 = (IROperand*)guard.ops().get((u32)0);
        IROperand* g1 = (IROperand*)guard.ops().get((u32)1);
        bool ivIs0 = g0.kind() == (u8)OPK_USE && g0.val() == iv;
        bool ivIs1 = g1.kind() == (u8)OPK_USE && g1.val() == iv;
        if (ivIs0 == ivIs1)
            return false;
        i32 bound = (i32)0;
        if (!constValue(defOf, ivIs0 ? g1 : g0, &bound))
            return false;
        if (bound < (i32)0)
            return false;

        IRBlock* T = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* F = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        bool bodyOnTrue = false;
        if (latchesTo(T, H))
            {
            B = T;
            E = F;
            bodyOnTrue = true;
            }
        else if (latchesTo(F, H))
            {
            B = F;
            E = T;
            bodyOnTrue = false;
            }
        else
            return false;
        if (E == 0)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;

        String* eff = effectivePredicate(guard.pred(), ivIs1, bodyOnTrue);
        if (eff == 0)
            return false;
        bool inclusive = eff.equals(String.withCString("ULE"));

        _msH = H;
        _msB = B;
        _msE = E;
        _msBound = bound;
        _msInclusive = inclusive;
        return memsetBody(fn, ivPhi, iv, defOf, defBlk, uses);
        }

    bool latchesTo(IRBlock* b, IRBlock* H)
        {
        if (b == 0 || b == H || b.term() == 0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        if (b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    // The loop-continue predicate, with the operands swapped and the edge
    // negated as needed. 0 when it is not a `<` or `<=` against the bound.
    String* effectivePredicate(String* pred, bool swapped, bool bodyOnTrue)
        {
        if (pred == 0)
            return (String*)0;
        String* eff = String.withString(pred);
        if (swapped)
            {
            if (eff.equals(String.withCString("ULT")))
                eff = String.withCString("UGT");
            else if (eff.equals(String.withCString("UGT")))
                eff = String.withCString("ULT");
            else if (eff.equals(String.withCString("ULE")))
                eff = String.withCString("UGE");
            else if (eff.equals(String.withCString("UGE")))
                eff = String.withCString("ULE");
            }
        if (!bodyOnTrue)
            {
            if (eff.equals(String.withCString("ULT")))
                eff = String.withCString("UGE");
            else if (eff.equals(String.withCString("UGE")))
                eff = String.withCString("ULT");
            else if (eff.equals(String.withCString("ULE")))
                eff = String.withCString("UGT");
            else if (eff.equals(String.withCString("UGT")))
                eff = String.withCString("ULE");
            else
                return (String*)0;
            }
        if (eff.equals(String.withCString("ULT")) || eff.equals(String.withCString("ULE")))
            return eff;
        return (String*)0;
        }

    // The induction variable's incomings, the body's single store, and the
    // conditions that make the whole loop one MemSet.
    bool memsetBody(IRFunc* fn, IRInsn* ivPhi, IRValue* iv,
                    Map* defOf, Map* defBlk, Map* uses)
        {
        if (ivPhi.ops().count() != (u32)4)
            return false;
        IROperand* initOp = (IROperand*)0;
        IROperand* nextOp = (IROperand*)0;
        IRBlock* P = (IRBlock*)0;
        if (((IROperand*)ivPhi.ops().get((u32)0)).blk() == _msB)
            {
            nextOp = (IROperand*)ivPhi.ops().get((u32)1);
            P = ((IROperand*)ivPhi.ops().get((u32)2)).blk();
            initOp = (IROperand*)ivPhi.ops().get((u32)3);
            }
        else if (((IROperand*)ivPhi.ops().get((u32)2)).blk() == _msB)
            {
            nextOp = (IROperand*)ivPhi.ops().get((u32)3);
            P = ((IROperand*)ivPhi.ops().get((u32)0)).blk();
            initOp = (IROperand*)ivPhi.ops().get((u32)1);
            }
        if (nextOp == 0 || initOp == 0 || P == 0)
            return false;
        i32 initV = (i32)0;
        if (!constValue(defOf, initOp, &initV) || initV != (i32)0)
            return false;
        if (nextOp.kind() != (u8)OPK_USE || nextOp.val() == 0)
            return false;
        Object* nd = defOf.get((Hashable*)nextOp.val());
        if (nd == 0)
            return false;
        IRInsn* ivNext = (IRInsn*)nd;
        if (!ivNext.op().equals(String.withCString("Add")))
            return false;
        if (defBlk.get((Hashable*)nextOp.val()) != (Object*)_msB)
            return false;
        if (countOf(uses, nextOp.val()) != (u32)1)
            return false;
        if (ivNext.ops().count() < (u32)2)
            return false;
        IROperand* na = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* nb = (IROperand*)ivNext.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (na.kind() == (u8)OPK_USE && na.val() == iv)
            stepOp = nb;
        else if (nb.kind() == (u8)OPK_USE && nb.val() == iv)
            stepOp = na;
        i32 step = (i32)0;
        if (stepOp == 0 || !constValue(defOf, stepOp, &step) || step != (i32)1)
            return false;

        IRInsn* store = soleStoreIn(_msB);
        if (store == 0 || store.ops().count() < (u32)3)
            return false;
        IROperand* pa = (IROperand*)store.ops().get((u32)0);
        if (pa.kind() != (u8)OPK_USE || pa.val() == 0)
            return false;
        Object* ed = defOf.get((Hashable*)pa.val());
        if (ed == 0)
            return false;
        IRInsn* ea = (IRInsn*)ed;
        if (!ea.op().equals(String.withCString("ElementAddr")))
            return false;
        if (ea.ops().count() < (u32)2)
            return false;
        IROperand* ix = (IROperand*)ea.ops().get((u32)1);
        if (ix.kind() != (u8)OPK_USE || ix.val() != iv)
            return false;
        IROperand* ba = (IROperand*)ea.ops().get((u32)0);
        if (ba.kind() != (u8)OPK_USE || ba.val() == 0)
            return false;
        // A memset fills BYTES: the element has to be one.
        if (!isBytePointer(ba.val().ty()))
            return false;

        // The base must be reconstructable in the preheader: an AddrOf to
        // clone, or a value defined outside the loop.
        Object* bd = defOf.get((Hashable*)ba.val());
        Object* bb = defBlk.get((Hashable*)ba.val());
        bool clonable = bd != 0 && ((IRInsn*)bd).op().equals(String.withCString("AddrOf")) && bb == (Object*)_msB;
        bool invariant = bd == 0 || (bb != (Object*)_msH && bb != (Object*)_msB);
        if (!clonable && !invariant)
            return false;

        i32 fill = (i32)0;
        if (!constValue(defOf, (IROperand*)store.ops().get((u32)1), &fill))
            return false;
        IROperand* mi = (IROperand*)store.ops().get((u32)2);
        if (mi.kind() != (u8)OPK_USE || mi.val() == 0)
            return false;
        Object* mb = defBlk.get((Hashable*)mi.val());
        if (mb == (Object*)_msB || mb == (Object*)_msH)
            return false;
        if (ivEscapes(fn, iv))
            return false;

        _msP = P;
        _msStore = store;
        _msBaseDef = clonable ? (IRInsn*)bd : (IRInsn*)0;
        _msBase = ba.val();
        _msFill = fill;
        _msMemIn = mi.val();
        _msMemOut = store.memRes();
        return true;
        }

    // The body's ONE store — and 0 when there is another memory operation, a
    // call, or a volatile store in there with it.
    IRInsn* soleStoreIn(IRBlock* B)
        {
        IRInsn* store = (IRInsn*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            String* op = n.op();
            if (op.equals(String.withCString("Store")))
                {
                if (store != 0)
                    return (IRInsn*)0;
                store = n;
                continue;
                }
            if (op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet")) || isCallOp(op))
                return (IRInsn*)0;
            }
        return store;
        }

    bool isBytePointer(String* t)
        {
        return t.equals(String.withCString("Ptr(U8, unbanked)")) || t.equals(String.withCString("Ptr(I8, unbanked)")) || t.equals(String.withCString("Ptr(Bool, unbanked)"));
        }

    // The loop's final index must not be read outside it.
    bool ivEscapes(IRFunc* fn, IRValue* iv)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == _msH || bb == _msB)
                continue;
            if (usesValue(bb.phis(), iv) || usesValue(bb.insns(), iv))
                return true;
            if (bb.term() != 0 && insnUses(bb.term(), iv))
                return true;
            }
        return false;
        }

    bool usesValue(Array* list, IRValue* v)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            if (insnUses((IRInsn*)list.get(i), v))
                return true;
        return false;
        }

    bool insnUses(IRInsn* n, IRValue* v)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                return true;
            }
        return false;
        }

    // A compile-time integer, seen through the ZExt a `(u16)0` lowers to.
    bool constValue(Map* defOf, IROperand* op, i32* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == 0)
            return false;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return false;
        IRInsn* n = (IRInsn*)d;
        if (n.ops().count() < (u32)1)
            return false;
        if (n.op().equals(String.withCString("Const")))
            {
            IROperand* imm = (IROperand*)n.ops().get((u32)0);
            if (imm.kind() != (u8)OPK_IMMI)
                return false;
            out[0] = imm.imm();
            return true;
            }
        // A zero-extend preserves a non-negative constant.
        if (!n.op().equals(String.withCString("ZExt")))
            return false;
        i32 v = (i32)0;
        if (!constValue(defOf, (IROperand*)n.ops().get((u32)0), &v))
            return false;
        if (v < (i32)0)
            return false;
        out[0] = v;
        return true;
        }

    void applyMemset(IRFunc* fn)
        {
        IRValue* dst = _msBase;
        if (_msBaseDef != 0)
            {
            // The AddrOf lived in the body; the preheader gets its own copy.
            IRValue* res = new IRValue(_msBaseDef.res().ty());
            IRInsn* ad = IRInsn.with(String.withCString("AddrOf"));
            ad.setRes(res);
            for (u32 k = (u32)0; k < _msBaseDef.ops().count(); k = k + (u32)1)
                ad.add((IROperand*)_msBaseDef.ops().get(k));
            _msP.add(ad);
            dst = res;
            }
        i32 n = _msBound + (_msInclusive ? (i32)1 : (i32)0);
        IRValue* memRes = new IRValue(String.withCString("Mem"));
        IRInsn* ms = IRInsn.with(String.withCString("MemSet"));
        ms.setMemRes(memRes);
        ms.add(IROperand.useVal(dst));
        ms.add(IROperand.immI(_msFill & (i32)$FF, String.withCString("U8")));
        ms.add(IROperand.immI(n, String.withCString("U32")));
        ms.add(IROperand.useVal(_msMemIn));
        _msP.add(ms);

        // Anything outside the loop that read the loop's memory output now
        // reads the MemSet's.
        if (_msMemOut != 0)
            {
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (bb == _msH || bb == _msB)
                    continue;
                remapUsesInBlock(bb, _msMemOut, memRes);
                }
            }

        retargetTerminator(_msP, _msH, _msE);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != _msH && bb != _msB)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }

    void retargetTerminator(IRBlock* blk, IRBlock* from, IRBlock* to)
        {
        IRInsn* t = blk.term();
        if (t == 0)
            return;
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() != from)
                continue;
            t.ops().set(k, (Object*)IROperand.block(to));
            }
        }

    void remapUsesInBlock(IRBlock* bb, IRValue* from, IRValue* to)
        {
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
            replaceUse((IRInsn*)bb.phis().get(i), from, IROperand.useVal(to));
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            replaceUse((IRInsn*)bb.insns().get(i), from, IROperand.useVal(to));
        if (bb.term() != 0)
            replaceUse(bb.term(), from, IROperand.useVal(to));
        }
    // ── dead-code ────────────────────────────────────────────────────────
    //
    // A PURE instruction whose result nothing reads comes out, and so does a
    // phi nobody reads — dropping either frees its operands, so the sweep
    // repeats until nothing changes. Deliberately conservative: anything that
    // touches memory, calls, refcounts, dispatches or runs inline asm stays,
    // whether its result is read or not.
    void deadCode(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            deadCodeInFunc((IRFunc*)m.funcs().get(f));
        }

    void deadCodeInFunc(IRFunc* fn)
        {
        bool changed = true;
        while (changed)
            {
            changed = false;
            Map* uses = useCounts(fn);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                if (sweepBlock((IRBlock*)fn.blocks().get(b), uses))
                    changed = true;
            }
        }

    bool sweepBlock(IRBlock* bb, Map* uses)
        {
        bool changed = false;
        Array* keep = new Array();
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.res() != 0 && isPureOp(n) && countOf(uses, n.res()) == (u32)0)
                {
                changed = true;
                continue;
                }
            keep.add((Object*)n);
            }
        if (changed)
            bb.setInsns(keep);
        // A phi whose result nobody reads is dead too — a phi never has an
        // effect. A MEMORY phi (no language result) is left alone.
        Array* keepPhis = new Array();
        bool phiChanged = false;
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)bb.phis().get(i);
            if (phi.res() != 0 && phi.memRes() == 0 && countOf(uses, phi.res()) == (u32)0)
                {
                phiChanged = true;
                continue;
                }
            keepPhis.add((Object*)phi);
            }
        if (phiChanged)
            {
            bb.setPhis(keepPhis);
            changed = true;
            }
        return changed;
        }

    // No side effect and no memory result: safe to DROP when the result is
    // unused. This list is NOT if-conversion's — a division may not be
    // SPECULATED (it can trap), but a dead one can certainly be deleted, so
    // Div and Rem are here and not there.
    bool isPureOp(IRInsn* n)
        {
        if (n.memRes() != 0)
            return false;
        String* op = n.op();
        if (op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem")) || op.equals(String.withCString("FDiv")) || op.equals(String.withCString("AggBuild")) || op.equals(String.withCString("AggExtract")))
            return true;
        return speculatable(n);
        }
    // ── redundant-load-cse ───────────────────────────────────────────────
    //
    // Two things at once, both BLOCK-LOCAL (no reasoning across edges):
    // a pure instruction computed twice with the same operands collapses to
    // one, and a Load of a pointer already loaded in this block hands back the
    // value already read. Anything that may write memory — or a bank-state op,
    // which repoints what a pointer addresses — clears the load cache.
    //
    // The port has no value ids, so a value's key is a number handed out on
    // first sight; the keys only have to be stable within one function.
    Map* _cseIds;
    u32 _cseNext;

    void redundantLoadCSE(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            cseInFunc((IRFunc*)m.funcs().get(f));
        }

    // Defining instruction per value, so the alias test can look through a
    // pointer to the FieldAddr that produced it.
    Map* _cseDefOf;

    void cseInFunc(IRFunc* fn)
        {
        _cseIds = new Map();
        _cseDefOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    _cseDefOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        _cseNext = (u32)0;
        Map* replace = new Map();  // value -> the value that wins
        Array* dead = new Array(); // IRInsn@ to drop

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            cseInBlock((IRBlock*)fn.blocks().get(b), replace, dead);
        if (replace.count() == (u32)0 && dead.count() == (u32)0)
            return;

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!hasInsn(dead, n))
                    keep.add((Object*)n);
                }
            bb.setInsns(keep);
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            rewriteThroughReplace(bb.phis(), replace);
            rewriteThroughReplace(bb.insns(), replace);
            if (bb.term() != 0)
                rewriteInsnThroughReplace(bb.term(), replace);
            }
        }

    void cseInBlock(IRBlock* bb, Map* replace, Array* dead)
        {
        Map* availPure = new Map(); // key -> the value that computed it
        Map* loaded = new Map();    // pointer value -> the value loaded
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.res() != 0 && n.memRes() == 0 && isCSEable(n.op()))
                {
                String* key = pureKey(n, replace);
                Object* have = availPure.get((Hashable*)key);
                if (have != 0)
                    {
                    replace.set((Hashable*)n.res(), have);
                    dead.add((Object*)n);
                    }
                else
                    {
                    availPure.set((Hashable*)key, (Object*)n.res());
                    }
                continue;
                }
            if (n.op().equals(String.withCString("Load")) && n.res() != 0 && n.ops().count() >= (u32)1 && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE)
                {
                if (reuseLoad(n, replace, loaded, dead))
                    continue;
                continue;
                }
            // A plain Store makes its value available at that pointer, and
            // disturbs only the cached loads that may alias it. Without this a
            // struct field written and read back in the same block went to the
            // frame and came straight back.
            //
            // VOLATILE stores are excluded: the whole point of one is that the
            // memory, not the value, is the observable thing.
            if (n.op().equals(String.withCString("Store")) && n.ops().count() >= (u32)2
                && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE)
                {
                IRValue* sp = resolveReplace(replace, ((IROperand*)n.ops().get((u32)0)).val());
                Array* keys = loaded.allKeys();
                for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
                    {
                    IRValue* lp = (IRValue*)keys.get(k);
                    if (cseMayAlias(sp, lp, replace))
                        loaded.remove((Hashable*)lp);
                    }
                // Only a Use can be forwarded: the table maps value to value,
                // and an immediate has no value to hand a later load.
                IROperand* sv = (IROperand*)n.ops().get((u32)1);
                if (sv.kind() == (u8)OPK_USE)
                    loaded.set((Hashable*)sp, (Object*)resolveReplace(replace, sv.val()));
                continue;
                }
            // Anything that may write memory, and the bank-state ops that
            // repoint pointers, invalidate what this block has loaded.
            if (touchesMemory(n.op()) || isBankStateOp(n.op()))
                loaded = new Map();
            }
        }

    // Can a store through `sp` change what a load through `lp` would see?
    //
    // Conservative by default — true for anything not proved apart. The one
    // case proved apart is the one that matters: two FieldAddrs off the SAME
    // base with DIFFERENT constant field indices are distinct addresses, so
    // storing p.y does not disturb a cached p.x. Without this the forwarding is
    // useless on the shape it exists for, because `store p.x; store p.y;
    // load p.x` would have the second store wipe what the first just recorded.
    bool cseMayAlias(IRValue* sp, IRValue* lp, Map* replace)
        {
        if (sp == lp)
            return true;
        Object* so = _cseDefOf.get((Hashable*)sp);
        Object* lo = _cseDefOf.get((Hashable*)lp);
        if (so == (Object*)0 || lo == (Object*)0)
            return true;
        IRInsn* sd = (IRInsn*)so;
        IRInsn* ld = (IRInsn*)lo;
        if (!sd.op().equals(String.withCString("FieldAddr"))
            || !ld.op().equals(String.withCString("FieldAddr")))
            return true;
        if (sd.ops().count() < (u32)2 || ld.ops().count() < (u32)2)
            return true;
        IROperand* sb = (IROperand*)sd.ops().get((u32)0);
        IROperand* lb = (IROperand*)ld.ops().get((u32)0);
        if (sb.kind() != (u8)OPK_USE || lb.kind() != (u8)OPK_USE)
            return true;
        if (resolveReplace(replace, sb.val()) != resolveReplace(replace, lb.val()))
            return true;                  // different, or unknown, objects
        IROperand* si = (IROperand*)sd.ops().get((u32)1);
        IROperand* li = (IROperand*)ld.ops().get((u32)1);
        if (si.kind() != (u8)OPK_IMMI || li.kind() != (u8)OPK_IMMI)
            return true;                  // a non-constant field index
        return si.imm() == li.imm();
        }

    // A Load whose pointer this block has already read hands back the value it
    // read — provided the memory token can be rewired too.
    bool reuseLoad(IRInsn* n, Map* replace, Map* loaded, Array* dead)
        {
        IROperand* p = (IROperand*)n.ops().get((u32)0);
        IRValue* ptr = resolveReplace(replace, p.val());
        Object* have = loaded.get((Hashable*)ptr);
        // The cached value must be the WIDTH the load wants. A u32 stored at an
        // address and read back as a u8 is not the same value, and the table is
        // keyed only by address.
        if (have != (Object*)0 && n.res() != (IRValue*)0)
            {
            IRValue* cv = (IRValue*)have;
            if (cv.ty() == (String*)0 || !cv.ty().equals(n.res().ty()))
                have = (Object*)0;
            }
        bool canRewire = n.memRes() == 0 || (n.ops().count() >= (u32)2 && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE);
        if (have != 0 && canRewire)
            {
            replace.set((Hashable*)n.res(), have);
            if (n.memRes() != 0)
                {
                IROperand* mi = (IROperand*)n.ops().get((u32)1);
                replace.set((Hashable*)n.memRes(),
                            (Object*)resolveReplace(replace, mi.val()));
                }
            dead.add((Object*)n);
            return true;
            }
        loaded.set((Hashable*)ptr, (Object*)n.res());
        return false;
        }

    // The key an instruction is value-numbered under: its opcode, predicate,
    // result TYPE (so casts to different widths do not collapse together) and
    // its operands, with uses resolved through the replacements so far.
    String* pureKey(IRInsn* n, Map* replace)
        {
        String* key = String.withString(n.op());
        key.appendCString("|p");
        if (n.pred() != 0)
            key.append(n.pred());
        key.appendCString("|t");
        key.append(n.res().ty());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            key.appendCString("|");
            key.append(operandKey((IROperand*)n.ops().get(k), replace));
            }
        return key;
        }

    String* operandKey(IROperand* o, Map* replace)
        {
        String* out = String.withCString("");
        if (o.kind() == (u8)OPK_USE)
            {
            out.appendCString("u");
            out.appendFormat("%ld", (i32)valueNumber(resolveReplace(replace, o.val())));
            return out;
            }
        if (o.kind() == (u8)OPK_SYM)
            {
            out.appendCString("s");
            if (o.name() != 0)
                out.append(o.name());
            return out;
            }
        if (o.kind() == (u8)OPK_BLOCK)
            {
            out.appendCString("b");
            if (o.blk() != 0 && o.blk().name() != 0)
                out.append(o.blk().name());
            return out;
            }
        // An immediate keys on its TYPE and its bits — `#1:U8` and `#1:U16`
        // are not the same value.
        out.appendCString("i");
        if (o.ty() != 0)
            out.append(o.ty());
        out.appendCString(":");
        out.append(o.text());
        return out;
        }

    u32 valueNumber(IRValue* v)
        {
        if (v == 0)
            return (u32)0;
        Object* have = _cseIds.get((Hashable*)v);
        if (have != 0)
            return ((Number*)have).asU32();
        _cseNext = _cseNext + (u32)1;
        _cseIds.set((Hashable*)v, (Object*)Number.with(_cseNext));
        return _cseNext;
        }

    IRValue* resolveReplace(Map* replace, IRValue* v)
        {
        IRValue* cur = v;
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            {
            Object* nx = replace.get((Hashable*)cur);
            if (nx == 0)
                return cur;
            if ((IRValue*)nx == cur)
                return cur;
            cur = (IRValue*)nx;
            }
        return cur;
        }

    void rewriteThroughReplace(Array* list, Map* replace)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            rewriteInsnThroughReplace((IRInsn*)list.get(i), replace);
        }

    void rewriteInsnThroughReplace(IRInsn* n, Map* replace)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == 0)
                continue;
            IRValue* r = resolveReplace(replace, o.val());
            if (r == o.val())
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(r));
            }
        }

    // Pure, deterministic and memory-free: safe to value-number. Div and Rem
    // are here — computing one twice with the same operands gives the same
    // answer, and the first one has already trapped if it was going to.
    bool isCSEable(String* op)
        {
        if (op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem")) || op.equals(String.withCString("FDiv")) || op.equals(String.withCString("AggExtract")))
            return true;
        return speculatable0(op);
        }

    // The `speculatable` list, keyed on the opcode alone.
    bool speculatable0(String* op)
        {
        IRInsn* probe = IRInsn.with(op);
        return speculatable(probe);
        }

    bool touchesMemory(String* op)
        {
        return op.equals(String.withCString("Load")) || op.equals(String.withCString("Store")) || op.equals(String.withCString("LoadVolatile")) || op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet")) || op.equals(String.withCString("AggLoad")) || op.equals(String.withCString("AggStore")) || isCallOp(op) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("CallBankedIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("VTblLoad")) || op.equals(String.withCString("ProtoLoad")) || op.equals(String.withCString("Retain")) || op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease")) || op.equals(String.withCString("WeakRegister")) || op.equals(String.withCString("WeakUnregister")) || op.equals(String.withCString("WeakLoad")) || op.equals(String.withCString("Asm")) || op.equals(String.withCString("VLoad")) || op.equals(String.withCString("VStore"));
        }

    bool isBankStateOp(String* op)
        {
        return op.equals(String.withCString("BankSave")) || op.equals(String.withCString("BankRestore")) || op.equals(String.withCString("BankSelectFor"));
        }

    // ── loop-reduction-collapse ──────────────────────────────────────────
    //
    // A rep loop wrapped around an invariant reduction
    //     for (rep = 0; rep < T; rep++)
    //         for (i = 0; i < N; i++) acc += g(i);   // g outer-invariant
    // adds the SAME delta Σg(i) on every outer iteration, so the closed form
    // acc_T = init + T·(acc₁ − init) is exact. The transform runs the outer
    // loop exactly ONCE (its header compare's bound drops to one trip) and
    // rescales the live-out accumulator with three ops at the head of the exit
    // block. Nothing is cloned and no block moves — only the bound changes and
    // the post-loop uses are redirected. Exact for `+` over 2's-complement
    // integers: T·Σδ mod 2^w is what T repeated adds produce.
    //
    // The HOIST half runs first. It lifts an invariant inner store loop out of
    // the rep loop (map.xc's `b[i] = f(a[i])`), after which the rep loop is
    // store-free and the collapse fires on the next round — which is why the
    // whole thing iterates to a fixpoint per function.
    void loopReductionCollapse(IRModule* m)
        {
        if (!_profile.reductionCollapse())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // Each transform invalidates the CFG and def analysis, so the
            // round rebuilds it. Capped as a backstop.
            u32 round = (u32)0;
            while (round < (u32)16 && lrcAnalyze(fn))
                round = round + (u32)1;
            }
        }

    // One round: build the def maps, discover the natural loops, and apply at
    // most ONE transform (the mutation invalidates everything above it).
    bool lrcAnalyze(IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return false;

        Map* defOf = new Map();  // instruction results
        Map* defPhi = new Map(); // phi results
        Map* defBlk = new Map(); // any def → its block (memory tokens too)
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0)
                    continue;
                defPhi.set((Hashable*)p.res(), (Object*)p);
                defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    {
                    defOf.set((Hashable*)n.res(), (Object*)n);
                    defBlk.set((Hashable*)n.res(), (Object*)bb);
                    }
                if (n.memRes() != (IRValue*)0)
                    defBlk.set((Hashable*)n.memRes(), (Object*)bb);
                }
            }

        Array* loops = lrcLoops(fn);
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            if (lrcHoistInner(fn, (LRCLoop*)loops.get(i), loops, defBlk))
                return true;
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            if (lrcCollapseOuter(fn, (LRCLoop*)loops.get(i), loops,
                                 defOf, defPhi, defBlk))
                return true;
        return false;
        }

    // Natural loops, one per back edge (latch → header where the header
    // dominates the latch).
    Array* lrcLoops(IRFunc* fn)
        {
        Map* dom = dominators(fn);
        Array* loops = new Array();
        for (u32 li = (u32)0; li < fn.blocks().count(); li = li + (u32)1)
            {
            IRBlock* latch = (IRBlock*)fn.blocks().get(li);
            Array* ss = lrcSuccs(fn, latch);
            for (u32 s = (u32)0; s < ss.count(); s = s + (u32)1)
                {
                IRBlock* H = (IRBlock*)ss.get(s);
                Array* dl = (Array*)dom.get((Hashable*)latch);
                if (dl == (Array*)0 || !hasBlock(dl, H))
                    continue;
                LRCLoop* L = new LRCLoop();
                L.setHeader(H);
                L.setLatch(latch);
                L.body().add((Object*)H);
                Array* wl = new Array();
                wl.add((Object*)latch);
                while (wl.count() > (u32)0)
                    {
                    IRBlock* n = (IRBlock*)wl.get(wl.count() - (u32)1);
                    wl.removeLast();
                    if (hasBlock(L.body(), n))
                        continue;
                    L.body().add((Object*)n);
                    if (n == H)
                        continue;
                    Array* ps = lrcPreds(fn, n);
                    for (u32 p = (u32)0; p < ps.count(); p = p + (u32)1)
                        wl.add(ps.get(p));
                    }
                // A unique out-of-loop predecessor is the preheader; anything
                // else leaves it null (the original's -1).
                Array* hp = lrcPreds(fn, H);
                IRBlock* pre = (IRBlock*)0;
                u32 outside = (u32)0;
                for (u32 p = (u32)0; p < hp.count(); p = p + (u32)1)
                    {
                    IRBlock* pb = (IRBlock*)hp.get(p);
                    if (hasBlock(L.body(), pb))
                        continue;
                    outside = outside + (u32)1;
                    pre = pb;
                    }
                if (outside != (u32)1)
                    pre = (IRBlock*)0;
                L.setPre(pre);
                loops.add((Object*)L);
                }
            }
        return loops;
        }

    // Successors, in terminator-operand order. Unlike `predsOfBlock` this
    // counts a target named TWICE by one terminator twice — the original
    // derives preds from succs and does the same, and the count is what
    // decides whether a preheader is unique.
    Array* lrcSuccs(IRFunc* fn, IRBlock* bb)
        {
        Array* out = new Array();
        IRInsn* t = bb.term();
        if (t == (IRInsn*)0)
            return out;
        for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(i);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                continue;
            if (!hasBlock(fn.blocks(), o.blk()))
                continue;
            out.add((Object*)o.blk());
            }
        return out;
        }

    Array* lrcPreds(IRFunc* fn, IRBlock* target)
        {
        Array* out = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)fn.blocks().get(b);
            Array* ss = lrcSuccs(fn, src);
            for (u32 i = (u32)0; i < ss.count(); i = i + (u32)1)
                if ((IRBlock*)ss.get(i) == target)
                    out.add((Object*)src);
            }
        return out;
        }

    bool lrcSubset(Array* a, Array* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (!hasBlock(b, (IRBlock*)a.get(i)))
                return false;
        return true;
        }

    // A const reached through ZExt / SExt / Trunc / Bitcast. A bound wider than
    // 16 bits arrives via Bitcast (U32→I32) rather than ZExt, so that step is
    // followed too — which is why this is not `resolveInt`.
    bool lrcConst(Map* defOf, IROperand* op, i32* out)
        {
        if (op == (IROperand*)0)
            return false;
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!lrcIsCast(def.op()))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    bool lrcIsCast(String* op)
        {
        return op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast"));
        }

    // Exact iteration count of an ascending counted loop, in closed form. No
    // simulation and no cap — the whole point is folding a BIG rep loop, and
    // T·Σδ mod 2^w is exact for any T. Zero when it is not a terminating
    // ascending counted loop.
    u32 lrcTrip(i32 startv, i32 step, i32 bound, String* pred)
        {
        if (step <= (i32)0)
            return (u32)0;
        if (pred.equals(String.withCString("SLT")))
            {
            if (bound <= startv)
                return (u32)0;
            return (u32)((bound - startv + step - (i32)1) / step);
            }
        if (pred.equals(String.withCString("SLE")))
            {
            if (bound < startv)
                return (u32)0;
            return (u32)((bound - startv) / step + (i32)1);
            }
        if (pred.equals(String.withCString("ULT")))
            {
            u32 ui = (u32)startv;
            u32 ub = (u32)bound;
            u32 us = (u32)step;
            if (ub <= ui)
                return (u32)0;
            return (ub - ui + us - (u32)1) / us;
            }
        if (pred.equals(String.withCString("ULE")))
            {
            u32 ui = (u32)startv;
            u32 ub = (u32)bound;
            u32 us = (u32)step;
            if (ub < ui)
                return (u32)0;
            return (ub - ui) / us + (u32)1;
            }
        return (u32)0;
        }

    // Does the def cone of `start`, restricted to `region`, reach anything in
    // `taboo`? Proves the inner reduction's per-step delta depends on neither
    // the outer accumulator nor the outer induction variable.
    bool lrcConeReaches(IRValue* start, Array* taboo, Array* region,
                        Map* defOf, Map* defPhi, Map* defBlk)
        {
        Map* seen = new Map();
        Array* wl = new Array();
        wl.add((Object*)start);
        while (wl.count() > (u32)0)
            {
            IRValue* v = (IRValue*)wl.get(wl.count() - (u32)1);
            wl.removeLast();
            if (seen.get((Hashable*)v) != (Object*)0)
                continue;
            seen.set((Hashable*)v, (Object*)v);
            for (u32 t = (u32)0; t < taboo.count(); t = t + (u32)1)
                if ((IRValue*)taboo.get(t) == v)
                    return true;
            Object* dbo = defBlk.get((Hashable*)v);
            // Defined outside the region ⇒ an invariant leaf.
            if (dbo == (Object*)0 || !hasBlock(region, (IRBlock*)dbo))
                continue;
            Object* d = defOf.get((Hashable*)v);
            if (d == (Object*)0)
                d = defPhi.get((Hashable*)v);
            if (d == (Object*)0)
                continue;
            IRInsn* def = (IRInsn*)d;
            for (u32 i = (u32)0; i < def.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)def.ops().get(i);
                if (o.kind() == (u8)OPK_USE)
                    wl.add((Object*)o.val());
                }
            }
        return false;
        }

    bool lrcWritesMemory(String* op)
        {
        return op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("MemSet")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("Retain")) || op.equals(String.withCString("Release")) || op.equals(String.withCString("WeakRegister")) || op.equals(String.withCString("WeakUnregister")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("Asm"));
        }

    // The base an address ultimately roots at — an `AddrOf @sym` reached
    // through any number of ElementAddr / Bitcast steps. Spelled as a string so
    // a global symbol and a stack slot cannot collide: "S:<name>" for a symbol,
    // "L:<n>" for a frame slot (a pinned local, stable across the loop and
    // distinct per local, so map.xc's a[] and b[] are provably disjoint). Null
    // when the base cannot be determined — a loaded pointer, IntToPtr, a phi.
    String* lrcAddrBase(IROperand* addr, Map* defOf, Array* locals)
        {
        IROperand* a = addr;
        for (u32 guard = (u32)0; guard < (u32)64; guard = guard + (u32)1)
            {
            if (a == (IROperand*)0 || a.kind() != (u8)OPK_USE)
                return (String*)0;
            Object* o = defOf.get((Hashable*)a.val());
            if (o == (Object*)0)
                return (String*)0;
            IRInsn* d = (IRInsn*)o;
            if (d.ops().count() < (u32)1)
                return (String*)0;
            IROperand* b = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("AddrOf")))
                {
                if (b.kind() == (u8)OPK_SYM)
                    {
                    String* s = String.withCString("S:");
                    s.append(b.name());
                    return s;
                    }
                if (b.kind() != (u8)OPK_USE)
                    return (String*)0;
                u32 idx = locals.count();
                for (u32 i = (u32)0; i < locals.count(); i = i + (u32)1)
                    if ((IRValue*)locals.get(i) == b.val())
                        {
                        idx = i;
                        break;
                        }
                if (idx == locals.count())
                    locals.add((Object*)b.val());
                String* s = new String();
                s.appendFormat("L:%lu", idx);
                return s;
                }
            if (d.op().equals(String.withCString("ElementAddr")) || d.op().equals(String.withCString("Bitcast")))
                {
                a = b;
                continue;
                }
            return (String*)0;
            }
        return (String*)0;
        }

    bool lrcHasString(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(s))
                return true;
        return false;
        }

    // Rebuild `bb`'s terminator so every block operand naming `oldT` names
    // `newT` instead.
    void lrcRetarget(IRBlock* bb, IRBlock* oldT, IRBlock* newT)
        {
        IRInsn* t = bb.term();
        if (t == (IRInsn*)0)
            return;
        for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(i);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() != oldT)
                continue;
            t.ops().set(i, (Object*)IROperand.block(newT));
            }
        }

    // Relabel every phi in `bb`: an incoming edge from `oldB` now comes from
    // `newB`, keeping the paired value.
    void lrcRelabelPhis(IRBlock* bb, IRBlock* oldB, IRBlock* newB)
        {
        for (u32 p = (u32)0; p < bb.phis().count(); p = p + (u32)1)
            {
            IRInsn* phi = (IRInsn*)bb.phis().get(p);
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != oldB)
                    continue;
                phi.ops().set(k, (Object*)IROperand.block(newB));
                }
            }
        }

    // Hoist an invariant inner loop L out of outer loop O, to run once BEFORE
    // it. Requires the map.xc shape: O's header continues to L's preheader P_i
    // (whose sole predecessor is that header), L has a single exit E_i, L and
    // its preheader use no value defined inside O's body, and O's body outside
    // L writes no memory. The relocation is three edge redirects and one phi
    // relabel — P_i and E_i are repurposed rather than moved.
    bool lrcHoistInner(IRFunc* fn, LRCLoop* O, Array* loops, Map* defBlk)
        {
        if (O.pre() == (IRBlock*)0)
            return false;
        IRBlock* Ho = O.header();
        IRBlock* Po = O.pre();

        // O's continue-target: the one header successor inside the body.
        IRBlock* cont = (IRBlock*)0;
        Array* hs = lrcSuccs(fn, Ho);
        for (u32 i = (u32)0; i < hs.count(); i = i + (u32)1)
            {
            IRBlock* s = (IRBlock*)hs.get(i);
            if (!hasBlock(O.body(), s))
                continue;
            if (cont == (IRBlock*)0)
                cont = s;
            else
                return false;
            }
        if (cont == (IRBlock*)0)
            return false;

        for (u32 li = (u32)0; li < loops.count(); li = li + (u32)1)
            {
            LRCLoop* L = (LRCLoop*)loops.get(li);
            if (L.pre() == (IRBlock*)0 || L.header() == Ho)
                continue;
            if (!lrcSubset(L.body(), O.body()) || L.body().count() >= O.body().count())
                continue;
            if (L.pre() != cont)
                continue; // P_i must be O's continue-target
            Array* pp = lrcPreds(fn, L.pre());
            if (pp.count() != (u32)1 || (IRBlock*)pp.get((u32)0) != Ho)
                continue;

            IRBlock* Pi = L.pre();
            IRBlock* Hi = L.header();

            // L's single exit: the header successor outside L's body.
            IRBlock* Ei = (IRBlock*)0;
            bool multiExit = false;
            Array* ls = lrcSuccs(fn, Hi);
            for (u32 i = (u32)0; i < ls.count(); i = i + (u32)1)
                {
                IRBlock* s = (IRBlock*)ls.get(i);
                if (hasBlock(L.body(), s))
                    continue;
                if (Ei == (IRBlock*)0)
                    Ei = s;
                else
                    {
                    multiExit = true;
                    break;
                    }
                }
            if (Ei == (IRBlock*)0 || multiExit)
                return false;

            // The region that moves out is L's body plus its preheader. It must
            // use no value defined inside O's body but outside the region — so
            // it cannot depend on O's carried accumulator or IV.
            Array* region = new Array();
            for (u32 i = (u32)0; i < L.body().count(); i = i + (u32)1)
                region.add(L.body().get(i));
            region.add((Object*)Pi);
            if (lrcRegionEscapes(region, O.body(), defBlk))
                return false;

            // Every store in the outer loop must sit inside L's body, so that L
            // is O's only writer and O is store-free once L leaves. Scanning
            // O.body \ L.body also covers P_i, which moves out with L but must
            // carry no store of its own.
            for (u32 i = (u32)0; i < O.body().count(); i = i + (u32)1)
                {
                IRBlock* bb = (IRBlock*)O.body().get(i);
                if (hasBlock(L.body(), bb))
                    continue;
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    if (lrcWritesMemory(((IRInsn*)bb.insns().get(k)).op()))
                        return false;
                }

            if (!lrcIdempotent(fn, L))
                return false;

            // ── Surgery ─────────────────────────────────────────────────
            // A dedicated exit block routes L → O's header, so the L-header →
            // O-header edge is not critical (L's header has two successors and
            // O's header two predecessors — a direct edge would misplace O's
            // phi-resolution copies and corrupt the accumulator seed).
            String* nm = Hi.name() == (String*)0
                             ? String.withCString("loop")
                             : Hi.name();
            String* exitName = new String();
            exitName.appendFormat("%s_hoisted_exit", nm.cString());
            IRBlock* L1exit = new IRBlock(exitName);
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(Ho));
            L1exit.setTerm(br);

            // Insert just after L's last body block so the array position
            // matches the control-flow position: the register allocators derive
            // live-interval positions from block order, and a block appended at
            // the end but executed mid-CFG scrambles liveness.
            u32 insertAt = (u32)0;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                if (hasBlock(L.body(), (IRBlock*)fn.blocks().get(b)) && b + (u32)1 > insertAt)
                    insertAt = b + (u32)1;
            fn.blocks().insert(insertAt, (Object*)L1exit);

            lrcRetarget(Po, Ho, Pi);        // (a) preheader now enters L first
            lrcRetarget(Hi, Ei, L1exit);    // (b) L's exit → dedicated block → O header
            lrcRetarget(Ho, Pi, Ei);        // (c) O's body now starts at E_i (the rest)
            lrcRelabelPhis(Ho, Po, L1exit); // (d) O header phis: preheader edge → new block
            return true;
            }
        return false;
        }

    // True when any instruction in `region` uses a value defined inside
    // `outer` but outside the region.
    bool lrcRegionEscapes(Array* region, Array* outer, Map* defBlk)
        {
        for (u32 i = (u32)0; i < region.count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)region.get(i);
            Array* all = new Array();
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                all.add(bb.phis().get(k));
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                all.add(bb.insns().get(k));
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(k);
                for (u32 o = (u32)0; o < n.ops().count(); o = o + (u32)1)
                    {
                    IROperand* op = (IROperand*)n.ops().get(o);
                    if (op.kind() != (u8)OPK_USE)
                        continue;
                    Object* db = defBlk.get((Hashable*)op.val());
                    if (db == (Object*)0)
                        continue;
                    if (hasBlock(outer, (IRBlock*)db) && !hasBlock(region, (IRBlock*)db))
                        return true;
                    }
                }
            }
        return false;
        }

    // The hoist runs L exactly ONCE in place of O's T iterations, so it only
    // preserves the final memory state if re-executing L would recompute the
    // same values — L must be a MAP, not a read-modify-write ACCUMULATE. A
    // store loop with no loads is idempotent outright. Once it also loads, what
    // it LOADS must be disjoint from what it STORES, else a stored value
    // depends on memory L itself wrote on an earlier pass (`m[i] = m[i] + 5`
    // run once gives 5 where T passes give 5·T). Any opaque base, or any other
    // memory-effecting op, refuses.
    bool lrcIdempotent(IRFunc* fn, LRCLoop* L)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        Array* locals = new Array();
        Array* storeSyms = new Array();
        Array* loadSyms = new Array();
        bool anyLoad = false;
        bool baseOpaque = false;
        for (u32 i = (u32)0; i < L.body().count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)L.body().get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(k);
                bool isLoad = n.op().equals(String.withCString("Load")) || n.op().equals(String.withCString("LoadVolatile")) || n.op().equals(String.withCString("VLoad"));
                bool isStore = n.op().equals(String.withCString("Store")) || n.op().equals(String.withCString("StoreVolatile")) || n.op().equals(String.withCString("VStore"));
                if (!isLoad && !isStore)
                    {
                    if (lrcWritesMemory(n.op()))
                        return false; // side effect
                    continue;
                    }
                String* s = n.ops().count() >= (u32)1
                                ? lrcAddrBase((IROperand*)n.ops().get((u32)0), defOf, locals)
                                : (String*)0;
                if (isLoad)
                    anyLoad = true;
                if (s == (String*)0)
                    {
                    baseOpaque = true;
                    continue;
                    }
                if (isLoad)
                    {
                    if (!lrcHasString(loadSyms, s))
                        loadSyms.add((Object*)s);
                    }
                else
                    {
                    if (!lrcHasString(storeSyms, s))
                        storeSyms.add((Object*)s);
                    }
                }
            }
        if (!anyLoad)
            return true;
        if (baseOpaque)
            return false; // cannot prove load/store disjoint
        for (u32 i = (u32)0; i < storeSyms.count(); i = i + (u32)1)
            if (lrcHasString(loadSyms, (String*)storeSyms.get(i)))
                return false; // an array is both read and written
        return true;
        }

    // What the header classification found. Ivars rather than locals because
    // the arm64 backend budgets 16 KB of frame per function and the collapse
    // is well over it as one body.
    IRInsn* _lrcIv;       // the induction-variable phi
    IRInsn* _lrcAcc;      // the accumulator phi
    IRInsn* _lrcCmp;      // the header ICmp that bounds the IV
    u32 _lrcTrip;         // its exact trip count
    i32 _lrcInit;         // the IV's start…
    i32 _lrcStep;         // …and its step
    IRValue* _lrcAccNext; // the accumulator's latch-incoming
    IRValue* _lrcAccSeed; // …and its preheader-incoming

    // The collapse proper. O must be a counted outer loop with a const trip, a
    // single integer accumulator carried through an inner reduction whose delta
    // is O-invariant, no memory writes in its body, and no value other than the
    // accumulator leaking out of it.
    bool lrcCollapseOuter(IRFunc* fn, LRCLoop* O, Array* loops,
                          Map* defOf, Map* defPhi, Map* defBlk)
        {
        if (O.pre() == (IRBlock*)0)
            return false;

        // The outer body must write no memory. (A store there needs the
        // invariant inner-loop hoist first — the other half of this pass.)
        for (u32 i = (u32)0; i < O.body().count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)O.body().get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                {
                String* op = ((IRInsn*)bb.insns().get(k)).op();
                if (lrcWritesMemory(op) || op.equals(String.withCString("LoadVolatile")))
                    return false;
                }
            }

        if (!lrcClassifyHeader(O, defOf))
            return false;
        if (!lrcInnerReduction(O, loops, defOf, defPhi, defBlk))
            return false;

        // Single exit, and the iteration count must leak ONLY through the
        // accumulator: any other value defined inside the body and used outside
        // it (the outer IV read after the loop, say) would be miscompiled by
        // running the body once. Memory tokens are exempt — advisory in a loose
        // model.
        IRBlock* exitBB = (IRBlock*)0;
        for (u32 i = (u32)0; i < O.body().count(); i = i + (u32)1)
            {
            Array* ss = lrcSuccs(fn, (IRBlock*)O.body().get(i));
            for (u32 k = (u32)0; k < ss.count(); k = k + (u32)1)
                {
                IRBlock* s = (IRBlock*)ss.get(k);
                if (hasBlock(O.body(), s))
                    continue;
                if (exitBB == (IRBlock*)0)
                    exitBB = s;
                else if (exitBB != s)
                    return false; // multiple exits
                }
            }
        if (exitBB == (IRBlock*)0)
            return false;
        u32 accUses = lrcCountLiveOut(fn, O.body(), _lrcAcc.res(), defBlk);
        if (accUses == (u32)0)
            return false; // accumulator dead afterwards
        if (accUses == LRC_LEAK)
            return false; // something else leaks

        lrcApply(fn, O, exitBB);
        return true;
        }

    // Classify the outer header's phis: exactly one induction variable
    // (counted, const trip) plus exactly one integer accumulator. Anything else
    // refuses. Results land in the _lrc* ivars.
    bool lrcClassifyHeader(LRCLoop* O, Map* defOf)
        {
        IRBlock* H = O.header();
        _lrcIv = (IRInsn*)0;
        _lrcAcc = (IRInsn*)0;
        _lrcCmp = (IRInsn*)0;
        _lrcTrip = (u32)0;
        _lrcInit = (i32)0;
        _lrcStep = (i32)0;
        _lrcAccNext = (IRValue*)0;
        _lrcAccSeed = (IRValue*)0;

        for (u32 p = (u32)0; p < H.phis().count(); p = p + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(p);
            if (phi.res() == (IRValue*)0)
                return false;
            IRValue* seed = lrcIncoming(phi, O.pre());
            IRValue* next = lrcIncoming(phi, O.latch());
            if (seed == (IRValue*)0 || next == (IRValue*)0)
                return false;

            if (_lrcIv == (IRInsn*)0 && lrcTryInductionVar(O, phi, next, defOf))
                continue;
            // Otherwise it must be the single accumulator.
            if (_lrcAcc != (IRInsn*)0)
                return false; // a second carried value
            _lrcAcc = phi;
            _lrcAccNext = next;
            _lrcAccSeed = seed;
            }
        return _lrcIv != (IRInsn*)0 && _lrcAcc != (IRInsn*)0 && _lrcCmp != (IRInsn*)0 && _lrcTrip >= (u32)2;
        }

    // Is `phi` the induction variable? next = Add(phi, constStep), and the
    // header compares it to a const bound with an ascending predicate.
    bool lrcTryInductionVar(LRCLoop* O, IRInsn* phi, IRValue* next, Map* defOf)
        {
        Object* nd = defOf.get((Hashable*)next);
        if (nd == (Object*)0)
            return false;
        IRInsn* nextDef = (IRInsn*)nd;
        if (!nextDef.op().equals(String.withCString("Add")) || nextDef.ops().count() != (u32)2)
            return false;

        i32 step = (i32)0;
        IROperand* a = (IROperand*)nextDef.ops().get((u32)0);
        IROperand* b = (IROperand*)nextDef.ops().get((u32)1);
        bool isIV = false;
        if (a.kind() == (u8)OPK_USE && a.val() == phi.res() && lrcConst(defOf, b, &step))
            isIV = true;
        else if (b.kind() == (u8)OPK_USE && b.val() == phi.res() && lrcConst(defOf, a, &step))
            isIV = true;
        if (!isIV)
            return false;

        IRBlock* H = O.header();
        for (u32 k = (u32)0; k < H.insns().count(); k = k + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(k);
            if (!n.op().equals(String.withCString("ICmp")) || n.ops().count() < (u32)2 || n.pred() == (String*)0)
                continue;
            IROperand* lhs = (IROperand*)n.ops().get((u32)0);
            if (lhs.kind() != (u8)OPK_USE || lhs.val() != phi.res())
                continue;
            i32 start = (i32)0;
            i32 bound = (i32)0;
            if (!lrcConst(defOf, lrcSeedOperand(phi, O.pre()), &start))
                continue;
            if (!lrcConst(defOf, (IROperand*)n.ops().get((u32)1), &bound))
                continue;
            u32 t = lrcTrip(start, step, bound, n.pred());
            if (t == (u32)0)
                continue;
            _lrcTrip = t;
            _lrcInit = start;
            _lrcStep = step;
            _lrcCmp = n;
            }
        if (_lrcTrip == (u32)0)
            return false;
        _lrcIv = phi;
        return true;
        }

    // The accumulator's latch-incoming must be an INNER reduction loop's
    // accumulator phi, seeded by the outer accumulator and accumulating a
    // per-step delta that depends on neither the outer accumulator nor the
    // outer IV — so Σδ is the same on every outer iteration.
    bool lrcInnerReduction(LRCLoop* O, Array* loops,
                           Map* defOf, Map* defPhi, Map* defBlk)
        {
        Object* iao = defPhi.get((Hashable*)_lrcAccNext);
        Object* ihb = defBlk.get((Hashable*)_lrcAccNext);
        if (iao == (Object*)0 || ihb == (Object*)0)
            return false;
        IRInsn* innerAcc = (IRInsn*)iao;

        LRCLoop* L = (LRCLoop*)0;
        for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
            {
            LRCLoop* cand = (LRCLoop*)loops.get(i);
            if (cand.header() != (IRBlock*)ihb)
                continue;
            if (!lrcSubset(cand.body(), O.body()) || cand.body().count() >= O.body().count())
                continue;
            L = cand;
            break;
            }
        if (L == (LRCLoop*)0 || L.pre() == (IRBlock*)0)
            return false;

        IRValue* innerSeed = lrcIncoming(innerAcc, L.pre());
        IRValue* innerNext = lrcIncoming(innerAcc, L.latch());
        if (innerSeed == (IRValue*)0 || innerNext == (IRValue*)0)
            return false;
        if (innerSeed != _lrcAcc.res())
            return false; // must chain the outer acc

        Object* ind = defOf.get((Hashable*)innerNext);
        if (ind == (Object*)0)
            return false;
        IRInsn* innerNextDef = (IRInsn*)ind;
        if (!innerNextDef.op().equals(String.withCString("Add")) || innerNextDef.ops().count() != (u32)2)
            return false;
        IROperand* ia = (IROperand*)innerNextDef.ops().get((u32)0);
        IROperand* ib = (IROperand*)innerNextDef.ops().get((u32)1);
        IRValue* delta = (IRValue*)0;
        if (ia.kind() == (u8)OPK_USE && ia.val() == innerAcc.res() && ib.kind() == (u8)OPK_USE)
            delta = ib.val();
        else if (ib.kind() == (u8)OPK_USE && ib.val() == innerAcc.res() && ia.kind() == (u8)OPK_USE)
            delta = ia.val();
        else
            return false;

        Array* taboo = new Array();
        taboo.add((Object*)_lrcAcc.res());
        taboo.add((Object*)_lrcIv.res());
        taboo.add((Object*)innerAcc.res());
        return !lrcConeReaches(delta, taboo, O.body(), defOf, defPhi, defBlk);
        }

    // Run the outer loop exactly ONCE (acc₁ = init + Σδ), then rescale its
    // live-out to init + T·(acc₁ − init) = init + T·Σδ.
    void lrcApply(IRFunc* fn, LRCLoop* O, IRBlock* exitBB)
        {
        String* accTy = _lrcAcc.res().ty();

        // 1. Rewrite the outer IV's header compare so the loop runs once.
        i32 onceBound = (_lrcCmp.pred().equals(String.withCString("SLE")) || _lrcCmp.pred().equals(String.withCString("ULE")))
                            ? _lrcInit
                            : _lrcInit + _lrcStep;
        IROperand* oldBound = (IROperand*)_lrcCmp.ops().get((u32)1);
        String* boundTy = accTy;
        if (oldBound.kind() == (u8)OPK_USE && oldBound.val() != (IRValue*)0 && oldBound.val().ty() != (String*)0)
            boundTy = oldBound.val().ty();
        _lrcCmp.ops().set((u32)1, (Object*)IROperand.immI(onceBound, boundTy));

        // 2. closed = init + T·(acc − init), three ops at the head of the exit.
        IROperand* initOp = IROperand.useVal(_lrcAccSeed);
        IRInsn* subI = IRInsn.with(String.withCString("Sub"));
        subI.setRes(new IRValue(accTy));
        subI.add(IROperand.useVal(_lrcAcc.res()));
        subI.add(initOp);
        IRInsn* mulI = IRInsn.with(String.withCString("Mul"));
        mulI.setRes(new IRValue(accTy));
        mulI.add(IROperand.useVal(subI.res()));
        mulI.add(IROperand.immI((i32)_lrcTrip, accTy));
        IRInsn* addI = IRInsn.with(String.withCString("Add"));
        addI.setRes(new IRValue(accTy));
        addI.add(initOp);
        addI.add(IROperand.useVal(mulI.res()));

        // 3. Redirect the post-loop accumulator uses to the closed form. This
        //    runs BEFORE the three ops are inserted — the original collects the
        //    use sites first, so the new Sub keeps reading the raw accumulator.
        lrcRewriteLiveOut(fn, O.body(), _lrcAcc.res(), IROperand.useVal(addI.res()));
        exitBB.insns().insert((u32)0, (Object*)subI);
        exitBB.insns().insert((u32)1, (Object*)mulI);
        exitBB.insns().insert((u32)2, (Object*)addI);
        }

    // The value paired with the `from` edge in a phi, or null.
    IRValue* lrcIncoming(IRInsn* phi, IRBlock* from)
        {
        IROperand* o = lrcSeedOperand(phi, from);
        return o == (IROperand*)0 ? (IRValue*)0 : o.val();
        }

    IROperand* lrcSeedOperand(IRInsn* phi, IRBlock* from)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IROperand* bo = (IROperand*)phi.ops().get(k);
            IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
            if (bo.kind() != (u8)OPK_BLOCK || vo.kind() != (u8)OPK_USE)
                continue;
            if (bo.blk() == from)
                return vo;
            }
        return (IROperand*)0;
        }

    // How many uses OUTSIDE `body` read a value defined inside it. LRC_LEAK
    // when one of them is not `acc` — the caller refuses, because running the
    // body once would then be observable.
    u32 lrcCountLiveOut(IRFunc* fn, Array* body, IRValue* acc, Map* defBlk)
        {
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(body, bb))
                continue;
            Array* all = new Array();
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                all.add(bb.phis().get(k));
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                all.add(bb.insns().get(k));
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
                {
                IRInsn* insn = (IRInsn*)all.get(k);
                for (u32 o = (u32)0; o < insn.ops().count(); o = o + (u32)1)
                    {
                    IROperand* op = (IROperand*)insn.ops().get(o);
                    if (op.kind() != (u8)OPK_USE)
                        continue;
                    Object* db = defBlk.get((Hashable*)op.val());
                    if (db == (Object*)0 || !hasBlock(body, (IRBlock*)db))
                        continue;
                    if (op.val().ty() != (String*)0 && op.val().ty().equals(String.withCString("Mem")))
                        continue;
                    if (op.val() != acc)
                        return LRC_LEAK;
                    n = n + (u32)1;
                    }
                }
            }
        return n;
        }

    void lrcRewriteLiveOut(IRFunc* fn, Array* body, IRValue* acc, IROperand* to)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(body, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                replaceUse((IRInsn*)bb.phis().get(k), acc, to);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                replaceUse((IRInsn*)bb.insns().get(k), acc, to);
            if (bb.term() != (IRInsn*)0)
                replaceUse(bb.term(), acc, to);
            }
        }

    // ── loop-unroll ──────────────────────────────────────────────────────
    //
    // A counted loop with a constant trip and a single straight-line body
    // becomes `trip` copies of that body, the induction variable becoming a
    // Const per copy and each accumulator threaded copy-to-copy. The header,
    // the compare and the back edge all go away.
    //
    // The caps come from the target profile — the 6502 keeps the shipped
    // conservative set because a large unroll cannot fit its 16 KB code bank,
    // while the 32-bit targets relax them.
    void loopUnroll(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            unrollInFunc((IRFunc*)m.funcs().get(f));
            if (_failed)
                return;
            }
        }

    void unrollInFunc(IRFunc* fn)
        {
        // Unroll one loop at a time, re-recognising after each: the apply
        // rewrites uses across sibling and outer loops, so a captured operand
        // from a stale scan would name a value that is no longer there. Each
        // unroll removes a loop, so the set shrinks; the cap is a backstop.
        for (u32 iter = (u32)0; iter < (u32)4096; iter = iter + (u32)1)
            {
            Array* cands = unrollCandidates(fn);
            if (_failed)
                return;
            if (cands.count() == (u32)0)
                return;

            u32 fnInsns = (u32)0;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                fnInsns = fnInsns + bb.phis().count() + bb.insns().count();
                if (bb.term() != (IRInsn*)0)
                    fnInsns = fnInsns + (u32)1;
                }
            LUCand* chosen = (LUCand*)0;
            for (u32 i = (u32)0; i < cands.count(); i = i + (u32)1)
                {
                LUCand* c = (LUCand*)cands.get(i);
                u32 added = (c.trip() - (u32)1) * (c.b().insns().count() + (u32)1);
                if (fnInsns + added > _profile.unrollBudget())
                    continue;
                // A call body grows the value count — each copy allocates fresh
                // result and memory-result slots — and on arm64 that sizes the
                // stack frame, so every slot has to stay addressable
                // (str/ldr w,[sp,#<=16380]). Counted over the values the
                // function HOLDS: the original used to count every id ever
                // allocated, which made the decision depend on how many ids
                // earlier passes happened to burn.
                if (_profile.unrollFrameIds() > (u32)0 && unrollBodyHasCall(c.b()))
                    {
                    u32 addedIds = c.trip() * ((u32)2 * c.b().insns().count() + (u32)1) + (u32)1;
                    if (unrollLiveIds(fn) + addedIds > _profile.unrollFrameIds())
                        continue;
                    }
                chosen = c;
                break;
                }
            // A loop that would bust the budget is left alone, and so is
            // everything after it — the original stops scanning here too.
            if (chosen == (LUCand*)0)
                return;
            unrollApply(fn, chosen);
            }
        }

    bool unrollBodyHasCall(IRBlock* B)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            if (unrollIsCall(((IRInsn*)B.insns().get(i)).op()))
                return true;
        return false;
        }

    // How many values the function holds: parameters, pinned locals, and every
    // instruction result and memory result.
    u32 unrollLiveIds(IRFunc* fn)
        {
        u32 n = fn.params().count() + fn.pinned().count();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            n = n + unrollCountDefs(bb.phis()) + unrollCountDefs(bb.insns());
            if (bb.term() != (IRInsn*)0)
                {
                if (bb.term().res() != (IRValue*)0)
                    n = n + (u32)1;
                if (bb.term().memRes() != (IRValue*)0)
                    n = n + (u32)1;
                }
            }
        return n;
        }

    u32 unrollCountDefs(Array* list)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* x = (IRInsn*)list.get(i);
            if (x.res() != (IRValue*)0)
                n = n + (u32)1;
            if (x.memRes() != (IRValue*)0)
                n = n + (u32)1;
            }
        return n;
        }

    Array* unrollCandidates(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    defOf.set((Hashable*)p.res(), (Object*)p);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }

        Array* cands = new Array();
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            LUCand* c = unrollRecognise(fn, (IRBlock*)fn.blocks().get(hi), defOf);
            if (_failed)
                return cands;
            if (c != (LUCand*)0)
                cands.add((Object*)c);
            }
        return cands;
        }

    // What the induction analysis found. Ivars, not locals: the arm64 backend
    // budgets 16 KB of frame per function and the recogniser is over it whole.
    bool _luBodyHasCall;
    IRInsn* _luIvPhi;
    IRBlock* _luPre;
    i32 _luInit;
    i32 _luStep;
    u32 _luTrip;
    Array* _luCarried;

    // One header block, or null.
    LUCand* unrollRecognise(IRFunc* fn, IRBlock* H, Map* defOf)
        {
        IRInsn* icmp = unrollHeaderCmp(H);
        if (icmp == (IRInsn*)0)
            return (LUCand*)0;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return (LUCand*)0;
        IROperand* cond = (IROperand*)term.ops().get((u32)0);
        IROperand* o1 = (IROperand*)term.ops().get((u32)1);
        IROperand* o2 = (IROperand*)term.ops().get((u32)2);
        if (cond.kind() != (u8)OPK_USE || cond.val() != icmp.res())
            return (LUCand*)0;
        if (o1.kind() != (u8)OPK_BLOCK || o2.kind() != (u8)OPK_BLOCK)
            return (LUCand*)0;

        // The body/latch is whichever target branches unconditionally back to
        // the header; the other is the exit.
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (unrollIsLatch(o1.blk(), H))
            {
            B = o1.blk();
            E = o2.blk();
            }
        else if (unrollIsLatch(o2.blk(), H))
            {
            B = o2.blk();
            E = o1.blk();
            }
        if (B == (IRBlock*)0 || E == (IRBlock*)0 || B == H || E == H || B == E)
            return (LUCand*)0;

        if (!unrollBodyShape(fn, H, B, E))
            return (LUCand*)0;
        if (!unrollIvAndCarried(fn, H, B, icmp, defOf))
            return (LUCand*)0;

        LUCand* c = new LUCand();
        c.setBlocks(H, B, E, _luPre);
        c.setIv(_luIvPhi, _luIvPhi.res().ty(), _luInit, _luStep, _luTrip);
        c.setCarried(_luCarried);
        return c;
        }

    // The header's single ICmp, or null if the header is not the clean
    // const/widen + one-compare shape (or carries a vector accumulator).
    IRInsn* unrollHeaderCmp(IRBlock* H)
        {
        if (H.phis().count() < (u32)1)
            return (IRInsn*)0;
        if (H.phis().count() > (u32)1 && !_profile.unrollMultiCarried())
            return (IRInsn*)0;
        // An already-vectorised reduction loop carries a VECTOR accumulator
        // phi; cloning it would defeat the backend's in-place accumulate
        // coalescing, so those are left alone.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && isVectorType(p.res().ty()))
                return (IRInsn*)0;
            }
        IRInsn* icmp = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n.op().equals(String.withCString("ICmp")))
                {
                if (icmp != (IRInsn*)0)
                    return (IRInsn*)0;
                icmp = n;
                continue;
                }
            if (!n.op().equals(String.withCString("Const")) && !n.op().equals(String.withCString("ZExt")) && !n.op().equals(String.withCString("SExt")) && !n.op().equals(String.withCString("Trunc")))
                return (IRInsn*)0;
            }
        if (icmp == (IRInsn*)0 || icmp.res() == (IRValue*)0)
            return (IRInsn*)0;
        return icmp;
        }

    // The body must be one straight-line block whose only predecessor is the
    // header, small enough for the target's cap, free of ops that cannot be
    // replicated, and the exit must have no phi to rewire.
    // `for (...) : unroll` raises the BUDGETS for the loops that asked, and
    // nothing else. The profile's maxTrip/maxBody are a judgement about when
    // unrolling PAYS — and that judgement is exactly what the annotation
    // overrides, because the author knows something the heuristic does not.
    //
    // Every other gate stays: multiple carried phis, vector phis, the
    // single-predecessor body shape, forbidden opcodes. Those are CORRECTNESS
    // limits, not budget ones — a loop the unroller cannot transform safely is
    // not made safe by being asked twice.
    bool unrollForced(IRFunc* fn, IRBlock* H)
        {
        if (fn == (IRFunc*)0 || H == (IRBlock*)0)
            return false;
        Array* hs = fn.unrollHeaders();
        for (u32 i = (u32)0; i < hs.count(); i = i + (u32)1)
            if (((String*)hs.get(i)).equals(H.name()))
                return true;
        return false;
        }

    u32 unrollTripCap(IRFunc* fn, IRBlock* H)
        {
        u32 d = _profile.unrollMaxTrip();
        if (!unrollForced(fn, H))
            return d;
        return d > (u32)64 ? d : (u32)64;
        }

    u32 unrollBodyCap(IRFunc* fn, IRBlock* H)
        {
        u32 d = _profile.unrollMaxBody();
        if (!unrollForced(fn, H))
            return d;
        return d > (u32)64 ? d : (u32)64;
        }

    bool unrollBodyShape(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* E)
        {
        Array* bp = unrollPreds(fn, B);
        if (bp.count() != (u32)1 || (IRBlock*)bp.get((u32)0) != H)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;
        if (B.insns().count() == (u32)0 || B.insns().count() > unrollBodyCap(fn, H))
            return false;
        bool hasCall = false;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (unrollIsCall(n.op()))
                hasCall = true;
            if (unrollForbidden(n.op()))
                return false;
            }
        // A call body is fine — the apply threads its memory token through a
        // transient header phi. `hasCall` is still wanted by the caller.
        _luBodyHasCall = hasCall;
        return true;
        }

    // The induction phi, its closed-form start/step/trip, and the accumulators
    // carried alongside it. Results land in the _lu* ivars.
    bool unrollIvAndCarried(IRFunc* fn, IRBlock* H, IRBlock* B,
                            IRInsn* icmp, Map* defOf)
        {
        _luIvPhi = (IRInsn*)0;
        _luPre = (IRBlock*)0;
        _luInit = (i32)0;
        _luStep = (i32)0;
        _luTrip = (u32)0;
        _luCarried = new Array();

        // The induction phi is the one whose result the compare tests.
        if (icmp.ops().count() < (u32)2)
            return false;
        IROperand* cmpL = (IROperand*)icmp.ops().get((u32)0);
        if (cmpL.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = cmpL.val();
        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == iv)
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0 || ivPhi.memRes() != (IRValue*)0)
            return false;

        // iv incomings: a const init from the preheader, and `Add iv, c` back.
        Array* sp = unrollSplitPhi(ivPhi, B);
        if (sp == (Array*)0)
            return false;
        IRBlock* P = (IRBlock*)sp.get((u32)0);
        IROperand* seedOp = (IROperand*)sp.get((u32)1);
        IROperand* nextOp = (IROperand*)sp.get((u32)2);
        if (P.term() == (IRInsn*)0)
            return false;
        i32 initV = (i32)0;
        if (!unrollConst(defOf, seedOp, &initV))
            return false;
        if (nextOp.kind() != (u8)OPK_USE)
            return false;
        Object* ndo = defOf.get((Hashable*)nextOp.val());
        if (ndo == (Object*)0)
            return false;
        IRInsn* nextDef = (IRInsn*)ndo;
        if (!nextDef.op().equals(String.withCString("Add")) || nextDef.ops().count() < (u32)2)
            return false;
        IROperand* na = (IROperand*)nextDef.ops().get((u32)0);
        IROperand* nb = (IROperand*)nextDef.ops().get((u32)1);
        i32 stepV = (i32)0;
        if (na.kind() == (u8)OPK_USE && na.val() == iv && unrollConst(defOf, nb, &stepV))
            {
            }
        else if (nb.kind() == (u8)OPK_USE && nb.val() == iv && unrollConst(defOf, na, &stepV))
            {
            }
        else
            return false;
        i32 boundV = (i32)0;
        if (!unrollConst(defOf, (IROperand*)icmp.ops().get((u32)1), &boundV))
            return false;
        if (icmp.pred() == (String*)0)
            return false;
        u32 trip = unrollTrip(initV, stepV, boundV, icmp.pred(),
                              unrollTripCap(fn, H));
        if (trip < (u32)2)
            return false; // trip 0/1 is not worth the machinery

        // Every other header phi is an accumulator carried across iterations,
        // and each must have the same (preheader init, body next) shape with
        // both values SSA uses — the per-copy threading is value-to-value.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p == ivPhi)
                continue;
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0)
                return false;
            Array* csp = unrollSplitPhi(p, B);
            if (csp == (Array*)0 || (IRBlock*)csp.get((u32)0) != P)
                return false;
            IROperand* ci = (IROperand*)csp.get((u32)1);
            IROperand* cn = (IROperand*)csp.get((u32)2);
            if (ci.kind() != (u8)OPK_USE || cn.kind() != (u8)OPK_USE)
                return false;
            LUCarried* cr = new LUCarried();
            cr.set(p.res(), ci, cn);
            _luCarried.add((Object*)cr);
            }

        // The iv must not be read outside the header/body: running the copies
        // never materialises its final value. Accumulators MAY escape — their
        // uses are remapped to the final copy in the apply.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            if (unrollUsesValue(bb, iv))
                return false;
            }

        _luIvPhi = ivPhi;
        _luPre = P;
        _luInit = initV;
        _luStep = stepV;
        _luTrip = trip;
        return true;
        }

    bool unrollIsLatch(IRBlock* b, IRBlock* H)
        {
        if (b == (IRBlock*)0 || b.term() == (IRInsn*)0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        Array* ss = unrollSuccs(b);
        return ss.count() == (u32)1 && (IRBlock*)ss.get((u32)0) == H;
        }

    Array* unrollSuccs(IRBlock* b)
        {
        Array* out = new Array();
        if (b.term() == (IRInsn*)0)
            return out;
        for (u32 i = (u32)0; i < b.term().ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)b.term().ops().get(i);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0)
                out.add((Object*)o.blk());
            }
        return out;
        }

    // Predecessors, DEDUPED — the original builds these as a set, so a block
    // that names its target twice counts once. (loop-reduction-collapse wants
    // the opposite; see lrcPreds.)
    Array* unrollPreds(IRFunc* fn, IRBlock* target)
        {
        Array* out = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)fn.blocks().get(b);
            Array* ss = unrollSuccs(src);
            for (u32 i = (u32)0; i < ss.count(); i = i + (u32)1)
                if ((IRBlock*)ss.get(i) == target)
                    {
                    if (!hasBlock(out, src))
                        out.add((Object*)src);
                    break;
                    }
            }
        return out;
        }

    bool unrollIsCall(String* op)
        {
        return isCallOp(op) || op.equals(String.withCString("CallIndirect")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch"));
        }

    // A body op that makes unrolling unsafe. Plain scalar Load/Store are always
    // fine — the backend emits them in program order. Calls are allowed only
    // where the target opts in, since each copy re-issues the call, which is
    // exactly the trip executions. Everything else that touches memory stays
    // forbidden: replicating a Retain/Release is unsound, and replicating a
    // MemCopy or an Asm is pointless.
    bool unrollForbidden(String* op)
        {
        if (op.equals(String.withCString("Load")) || op.equals(String.withCString("Store")))
            return false;
        if (unrollIsCall(op))
            return !_profile.unrollCallsInBody();
        return touchesMemory(op);
        }

    // Split a 2-incoming header phi into (preheader, init, next) given the body
    // block. Null unless it has exactly that shape.
    Array* unrollSplitPhi(IRInsn* phi, IRBlock* B)
        {
        if (phi.ops().count() != (u32)4)
            return (Array*)0;
        IRBlock* b0 = ((IROperand*)phi.ops().get((u32)0)).blk();
        IRBlock* b1 = ((IROperand*)phi.ops().get((u32)2)).blk();
        Object* v0 = phi.ops().get((u32)1);
        Object* v1 = phi.ops().get((u32)3);
        Array* out = new Array();
        if (b1 == B && b0 != B)
            {
            out.add((Object*)b0);
            out.add(v0);
            out.add(v1);
            return out;
            }
        if (b0 == B && b1 != B)
            {
            out.add((Object*)b1);
            out.add(v1);
            out.add(v0);
            return out;
            }
        return (Array*)0;
        }

    // A compile-time int, seen through the widened-literal form. Unlike the
    // collapse's, this one does NOT follow Bitcast — the original's two
    // resolvers differ there and the difference is load-bearing.
    bool unrollConst(Map* defOf, IROperand* op, i32* out)
        {
        if (op == (IROperand*)0)
            return false;
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    // Simulate to a trip count, capped. Zero unless it is a terminating
    // ascending counted loop within the cap — unlike the collapse's closed
    // form, the unroller only wants trips it can afford to replicate.
    u32 unrollTrip(i32 startv, i32 step, i32 bound, String* pred, u32 maxTrip)
        {
        if (step <= (i32)0)
            return (u32)0; // ascending counters only
        i32 i = startv;
        u32 trip = (u32)0;
        for (u32 n = (u32)0; n <= maxTrip; n = n + (u32)1)
            {
            bool cont = false;
            if (pred.equals(String.withCString("ULT")))
                cont = (u32)i < (u32)bound;
            else if (pred.equals(String.withCString("SLT")))
                cont = i < bound;
            else if (pred.equals(String.withCString("ULE")))
                cont = (u32)i <= (u32)bound;
            else if (pred.equals(String.withCString("SLE")))
                cont = i <= bound;
            else
                return (u32)0; // unsupported predicate
            if (!cont)
                break;
            trip = trip + (u32)1;
            i = i + step;
            }
        if (trip == (u32)0 || trip > maxTrip)
            return (u32)0;
        return trip;
        }

    bool unrollUsesValue(IRBlock* bb, IRValue* v)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            if (insnUsesValue((IRInsn*)bb.phis().get(k), v))
                return true;
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            if (insnUsesValue((IRInsn*)bb.insns().get(k), v))
                return true;
        if (bb.term() != (IRInsn*)0 && insnUsesValue(bb.term(), v))
            return true;
        return false;
        }

    bool insnUsesValue(IRInsn* n, IRValue* v)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                return true;
            }
        return false;
        }

    bool isVectorType(String* t)
        {
        return t != (String*)0 && t.hasPrefix(String.withCString("Vec"));
        }

    // Replace the loop with `trip` copies of its body: the induction variable
    // becomes a Const per copy, each accumulator is threaded copy-to-copy, and
    // the header and body blocks are spliced out.
    void unrollApply(IRFunc* fn, LUCand* c)
        {
        IRBlock* H = c.h();
        IRBlock* B = c.b();
        IRBlock* E = c.e();
        IRBlock* P = c.p();
        IRValue* iv = c.phi().res();

        // A body with a CALL threads its memory through an opaque callee, so a
        // transient header memory phi is synthesised and registered as a carried
        // value — that is what makes the copies thread the token one to the
        // next. It is spliced out with the loop, so it never reaches the
        // verifier, the CSE or a backend. Plain load/store bodies need none of
        // this and keep the original no-phi path.
        unrollThreadMemory(fn, c, H, B, P);

        // Values defined in the body — what the post-loop escape remap
        // redirects to the final copy.
        Array* bodyDefs = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.res() != (IRValue*)0)
                bodyDefs.add((Object*)n.res());
            if (n.memRes() != (IRValue*)0)
                bodyDefs.add((Object*)n.memRes());
            }

        // Each accumulator's incoming value for the copy about to be built;
        // copy 0 gets its seed.
        Map* carriedCur = new Map();
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            carriedCur.set((Hashable*)cr.phi(), (Object*)cr.seed().val());
            }

        Array* clones = new Array();
        Map* lastMap = new Map();
        for (u32 j = (u32)0; j < c.trip(); j = j + (u32)1)
            {
            Map* map = new Map();
            IRBlock* C = unrollCopy(fn, c, B, j, map, carriedCur);
            clones.add((Object*)C);
            lastMap = map;
            }

        // Wire the copies: c_j → c_{j+1}, and the last one to the exit.
        for (u32 j = (u32)0; j < clones.count(); j = j + (u32)1)
            {
            IRBlock* target = (j + (u32)1 < clones.count())
                                  ? (IRBlock*)clones.get(j + (u32)1)
                                  : E;
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(target));
            ((IRBlock*)clones.get(j)).setTerm(br);
            }

        // The preheader now enters the first copy.
        lrcRetarget(P, H, (IRBlock*)clones.get((u32)0));

        // Escape remap for everything outside the loop: a body-defined value
        // becomes the final copy's, and an accumulator phi becomes its final
        // carried value.
        Array* escapeDefs = new Array();
        for (u32 i = (u32)0; i < bodyDefs.count(); i = i + (u32)1)
            escapeDefs.add(bodyDefs.get(i));
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            lastMap.set((Hashable*)cr.phi(), carriedCur.get((Hashable*)cr.phi()));
            escapeDefs.add((Object*)cr.phi());
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            unrollRemapUses(bb, escapeDefs, lastMap);
            }

        // Splice: drop the header and the body, put the copies where the
        // header was so the block order still matches the control flow (the
        // register allocators read live-interval positions from it).
        // The original takes H's index in the OLD array, removes H and B, then
        // inserts at that same index clamped to the shortened array — NOT at
        // "however many survivors preceded H". The two differ whenever B sits
        // before H, so this follows the original's arithmetic literally.
        u32 pos = fn.blocks().count();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if ((IRBlock*)fn.blocks().get(b) == H)
                {
                pos = b;
                break;
                }
        Array* kept = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            kept.add((Object*)bb);
            }
        if (pos > kept.count())
            pos = kept.count();
        for (u32 j = (u32)0; j < clones.count(); j = j + (u32)1)
            kept.insert(pos + j, clones.get(j));
        fn.setBlocks(kept);
        }

    void unrollThreadMemory(IRFunc* fn, LUCand* c, IRBlock* H, IRBlock* B, IRBlock* P)
        {
        bool hasCall = false;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            if (unrollIsCall(((IRInsn*)B.insns().get(i)).op()))
                {
                hasCall = true;
                break;
                }
        if (!hasCall)
            return;

        IRInsn* firstMem = (IRInsn*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (touchesMemory(n.op()))
                {
                firstMem = n;
                break;
                }
            }
        if (firstMem == (IRInsn*)0)
            return;
        IRValue* tin = (IRValue*)0;
        for (u32 k = (u32)0; k < firstMem.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)firstMem.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                continue;
            if (o.val().ty() != (String*)0 && o.val().ty().equals(String.withCString("Mem")))
                {
                tin = o.val();
                break;
                }
            }
        IRValue* tlast = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                tlast = n.memRes();
            }
        if (tin == (IRValue*)0 || tlast == (IRValue*)0)
            return;

        IRValue* memPhi = new IRValue(String.withCString("Mem"));
        IRInsn* ph = IRInsn.with(String.withCString("Phi"));
        ph.setRes(memPhi);
        // The incoming order follows BLOCK ORDER, as the original's does.
        if (blockIndex(fn, P) <= blockIndex(fn, B))
            {
            ph.add(IROperand.block(P));
            ph.add(IROperand.useVal(tin));
            ph.add(IROperand.block(B));
            ph.add(IROperand.useVal(tlast));
            }
        else
            {
            ph.add(IROperand.block(B));
            ph.add(IROperand.useVal(tlast));
            ph.add(IROperand.block(P));
            ph.add(IROperand.useVal(tin));
            }
        H.addPhi(ph);

        // The first memory op now reads the phi instead of the incoming token.
        for (u32 k = (u32)0; k < firstMem.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)firstMem.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == tin)
                firstMem.ops().set(k, (Object*)IROperand.useVal(memPhi));
            }

        LUCarried* cr = new LUCarried();
        cr.set(memPhi, IROperand.useVal(tin), IROperand.useVal(tlast));
        c.carried().add((Object*)cr);
        }

    // One copy of the body. `map` collects this copy's old→new values, and
    // `carriedCur` advances to what this copy produced.
    IRBlock* unrollCopy(IRFunc* fn, LUCand* c, IRBlock* B, u32 j,
                        Map* map, Map* carriedCur)
        {
        String* base = B.name() == (String*)0
                           ? String.withCString("body")
                           : B.name();
        String* nm = new String();
        nm.appendFormat("%s_u%lu", base.cString(), j);
        IRBlock* C = new IRBlock(nm);

        // The induction variable is a fresh Const of its value for this copy.
        i32 ivVal = c.start() + (i32)j * c.step();
        IRInsn* ivConst = IRInsn.with(String.withCString("Const"));
        ivConst.setRes(new IRValue(c.ivTy()));
        ivConst.add(IROperand.immI(ivVal, c.ivTy()));
        C.add(ivConst);
        map.set((Hashable*)c.phi().res(), (Object*)ivConst.res());

        // Each accumulator phi resolves to its incoming value for this copy.
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            map.set((Hashable*)cr.phi(), carriedCur.get((Hashable*)cr.phi()));
            }

        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            IRInsn* cl = IRInsn.with(n.op());
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                cl.add(unrollSubst(map, (IROperand*)n.ops().get(k)));
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                map.set((Hashable*)n.res(), (Object*)cl.res());
                }
            if (n.memRes() != (IRValue*)0)
                {
                cl.setMemRes(new IRValue(String.withCString("Mem")));
                map.set((Hashable*)n.memRes(), (Object*)cl.memRes());
                }
            C.add(cl);
            }

        // Advance each accumulator to what this copy produced.
        for (u32 i = (u32)0; i < c.carried().count(); i = i + (u32)1)
            {
            LUCarried* cr = (LUCarried*)c.carried().get(i);
            Object* nn = map.get((Hashable*)cr.next().val());
            if (nn == (Object*)0)
                nn = (Object*)cr.next().val();
            carriedCur.set((Hashable*)cr.phi(), nn);
            }
        return C;
        }

    IROperand* unrollSubst(Map* map, IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* n = map.get((Hashable*)o.val());
        if (n == (Object*)0)
            return o;
        return IROperand.useVal((IRValue*)n);
        }

    void unrollRemapUses(IRBlock* bb, Array* defs, Map* map)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            unrollRemapInsn((IRInsn*)bb.phis().get(k), defs, map);
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            unrollRemapInsn((IRInsn*)bb.insns().get(k), defs, map);
        if (bb.term() != (IRInsn*)0)
            unrollRemapInsn(bb.term(), defs, map);
        }

    void unrollRemapInsn(IRInsn* n, Array* defs, Map* map)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            if (!hasValue(defs, o.val()))
                continue;
            Object* to = map.get((Hashable*)o.val());
            if (to == (Object*)0)
                continue;
            n.ops().set(i, (Object*)IROperand.useVal((IRValue*)to));
            }
        }

    bool hasValue(Array* vs, IRValue* v)
        {
        for (u32 i = (u32)0; i < vs.count(); i = i + (u32)1)
            if ((IRValue*)vs.get(i) == v)
                return true;
        return false;
        }

    // ── pointer-iv ───────────────────────────────────────────────────────
    //
    // Loop array addressing becomes an advancing pointer. `a[i]` inside a
    // counted loop is an ElementAddr recomputed from the induction variable
    // every iteration; this replaces it with a pointer phi stepped by the
    // loop's constant stride, so the body loads through `(p)` and adds the
    // step once. The variable-trip unroller then threads each pointer phi
    // through the copies, and no copy recomputes an address at all.
    //
    // Off on the 6502: its ZP walking pointer plus the per-iteration advance
    // costs more than the index arithmetic it would replace.
    void pointerIV(IRModule* m)
        {
        if (!_profile.pointerIV())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop per scan; repeat until nothing more rewrites (a
            // function may hold several independent loops).
            u32 iter = (u32)0;
            while (iter < (u32)64 && pivOnce(fn))
                iter = iter + (u32)1;
            }
        }

    bool pivOnce(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0)
                    continue;
                defOf.set((Hashable*)p.res(), (Object*)p);
                defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() == (IRValue*)0)
                    continue;
                defOf.set((Hashable*)n.res(), (Object*)n);
                defBlk.set((Hashable*)n.res(), (Object*)bb);
                }
            }
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            if (pivLoop(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk))
                return true;
        return false;
        }

    // The loop's header phi, its single-block latch, its preheader and its
    // constant step — set when pivShape succeeds.
    IRInsn* _pivIvPhi;
    IRBlock* _pivLatch;
    IRBlock* _pivPre;
    i32 _pivStep;

    bool pivLoop(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        if (!pivShape(fn, H, defOf, defBlk))
            return false;
        IRInsn* ivPhi = _pivIvPhi;
        IRBlock* B = _pivLatch;
        IRBlock* PH = _pivPre;
        IRValue* iv = ivPhi.res();

        // Loop-invariant-base ElementAddrs at affine-iv indices, grouped by
        // base. Insertion order, NOT hash order: the original walks an
        // NSDictionary here and the group order decides which pointer phi is
        // emitted first, so a dictionary would make the printed IR depend on
        // hashing. First appearance scanning the body is the stable choice.
        Array* bases = new Array();  // IRValue@
        Array* groups = new Array(); // Array@ of [IRInsn@, offset]
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (!n.op().equals(String.withCString("ElementAddr")) || n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
                continue;
            IROperand* baseOp = (IROperand*)n.ops().get((u32)0);
            IROperand* idxOp = (IROperand*)n.ops().get((u32)1);
            if (baseOp.kind() != (u8)OPK_USE || idxOp.kind() != (u8)OPK_USE)
                continue;
            if (!pivInvariantBase(baseOp.val(), H, B, defOf, defBlk))
                continue;
            if (baseOp.val().ty() == (String*)0 || !baseOp.val().ty().hasPrefix(String.withCString("Ptr(")))
                continue;
            i32 off = (i32)0;
            if (!pivAffine(idxOp.val(), iv, defOf, &off, (u32)0) || off < (i32)0)
                continue;
            u32 gi = bases.count();
            for (u32 k = (u32)0; k < bases.count(); k = k + (u32)1)
                if ((IRValue*)bases.get(k) == baseOp.val())
                    {
                    gi = k;
                    break;
                    }
            if (gi == bases.count())
                {
                bases.add((Object*)baseOp.val());
                groups.add((Object*)new Array());
                }
            Array* g = (Array*)groups.get(gi);
            g.add((Object*)n);
            g.add((Object*)Number.withI32(off));
            }
        if (bases.count() == (u32)0)
            return false;
        // Register-pressure cap. Each base becomes a loop-carried pointer phi
        // that the unroller threads through every copy — roughly two live
        // values apiece, against a nine-register callee-saved home pool.
        //
        // Re-measured 2026-09-18, best of five at -O3:
        //
        //   cap   array_map   mem_copy   struct_copy   matrix_mul   sieve
        //    2      15392       8253        16379        10082      32689
        //    3      12480       8138        16397         9996      32184
        //    4      12658       8548        15427        10005      33221
        //
        // 3 is the sweet spot, and 2 was leaving a fifth of array_map on the
        // table: it reads a[i] and b[i] and writes c[i], so THREE bases, and at
        // a cap of 2 the loop recomputed `base + i*4` three times per vector and
        // spilled the store address, there being only one address scratch.
        // 4 is only slightly worse than 3, so this is a tuning parameter and
        // not a cliff. Re-measure before moving it.
        if (bases.count() > (u32)3)
            return false;

        // Where the induction variable STARTS — the iv phi's preheader incoming.
        // The pointer phi must begin at `base + ivInit`, not at `base`.
        IROperand* pivInit = (IROperand*)0;
        if (((IROperand*)ivPhi.ops().get((u32)0)).blk() == B)
            {
            pivInit = (IROperand*)ivPhi.ops().get((u32)3);
            }
        else
            {
            pivInit = (IROperand*)ivPhi.ops().get((u32)1);
            }
        pivRewrite(fn, H, B, PH, ivPhi.res().ty(), bases, groups, defOf, pivInit);
        return true;
        }

    // The header must end in a CondBranch on an ICmp of an integer phi, with a
    // single-block latch branching back to it and a distinct preheader; the
    // phi's back-edge value must be `Add(iv, positive const)` computed in the
    // latch.
    bool pivShape(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        _pivIvPhi = (IRInsn*)0;
        _pivLatch = (IRBlock*)0;
        _pivPre = (IRBlock*)0;
        _pivStep = (i32)0;
        if (H.phis().count() == (u32)0)
            return false;
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        if (go == (Object*)0)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = gl.val();

        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == iv)
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0 || ivPhi.ops().count() != (u32)4)
            return false;
        if (!isIntType(iv.ty()))
            return false;

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = pivIsLatch(t0, H) ? t0 : (pivIsLatch(t1, H) ? t1 : (IRBlock*)0);
        if (B == (IRBlock*)0)
            return false;

        IRBlock* e0 = ((IROperand*)ivPhi.ops().get((u32)0)).blk();
        IRBlock* PH = (e0 == B) ? ((IROperand*)ivPhi.ops().get((u32)2)).blk() : e0;
        if (PH == (IRBlock*)0 || PH == B || PH == H)
            return false;

        IROperand* ivBack = (e0 == B) ? (IROperand*)ivPhi.ops().get((u32)1)
                                      : (IROperand*)ivPhi.ops().get((u32)3);
        if (ivBack.kind() != (u8)OPK_USE)
            return false;
        Object* no = defOf.get((Hashable*)ivBack.val());
        if (no == (Object*)0)
            return false;
        IRInsn* ivNext = (IRInsn*)no;
        if (!ivNext.op().equals(String.withCString("Add")))
            return false;
        Object* nb = defBlk.get((Hashable*)ivBack.val());
        if (nb == (Object*)0 || (IRBlock*)nb != B)
            return false;
        if (ivNext.ops().count() < (u32)2)
            return false;

        // The step may still be a separate `Const` — const-operand-fold runs
        // AFTER this pass, so `i + 1` need not be an inline immediate yet.
        IROperand* a = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* b = (IROperand*)ivNext.ops().get((u32)1);
        i32 step = (i32)0;
        bool have = false;
        if (a.kind() == (u8)OPK_USE && a.val() == iv)
            have = pivConst(defOf, b, &step);
        else if (b.kind() == (u8)OPK_USE && b.val() == iv)
            have = pivConst(defOf, a, &step);
        if (!have || step <= (i32)0)
            return false;

        _pivIvPhi = ivPhi;
        _pivLatch = B;
        _pivPre = PH;
        _pivStep = step;
        return true;
        }

    bool pivIsLatch(IRBlock* b, IRBlock* H)
        {
        if (b == (IRBlock*)0 || b == H || b.term() == (IRInsn*)0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        if (b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    // Loop-invariant base: a parameter (no def site — live from entry), a value
    // defined outside the header and latch, or an `AddrOf @sym` (a constant
    // address, hoisted to the preheader by the rewrite). All three give the
    // pointer phi a preheader incoming that dominates the loop.
    bool pivInvariantBase(IRValue* base, IRBlock* H, IRBlock* B,
                          Map* defOf, Map* defBlk)
        {
        Object* bBlk = defBlk.get((Hashable*)base);
        Object* bdef = defOf.get((Hashable*)base);
        if (bBlk == (Object*)0 && bdef == (Object*)0)
            return true; // a parameter
        if (bBlk != (Object*)0 && (IRBlock*)bBlk != H && (IRBlock*)bBlk != B)
            return true;
        return bdef != (Object*)0 && ((IRInsn*)bdef).op().equals(String.withCString("AddrOf"));
        }

    // Resolve a value to the induction variable plus a constant element offset:
    // iv itself is 0, `Add(x, const)` is offset(x) + const. False when it is
    // not an affine function of the iv.
    bool pivAffine(IRValue* v, IRValue* iv, Map* defOf, i32* out, u32 depth)
        {
        if (v == iv)
            {
            out[0] = (i32)0;
            return true;
            }
        if (depth > (u32)16)
            return false;
        Object* o = defOf.get((Hashable*)v);
        if (o == (Object*)0)
            return false;
        IRInsn* d = (IRInsn*)o;
        if (!d.op().equals(String.withCString("Add")) || d.ops().count() < (u32)2)
            return false;
        IROperand* a = (IROperand*)d.ops().get((u32)0);
        IROperand* b = (IROperand*)d.ops().get((u32)1);
        i32 inner = (i32)0;
        i32 c = (i32)0;
        if (a.kind() == (u8)OPK_USE && pivAffine(a.val(), iv, defOf, &inner, depth + (u32)1) && pivConst(defOf, b, &c))
            {
            out[0] = inner + c;
            return true;
            }
        if (b.kind() == (u8)OPK_USE && pivAffine(b.val(), iv, defOf, &inner, depth + (u32)1) && pivConst(defOf, a, &c))
            {
            out[0] = inner + c;
            return true;
            }
        return false;
        }

    // An immediate, or a `Const` instruction's immediate.
    bool pivConst(Map* defOf, IROperand* o, i32* out)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            out[0] = o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE)
            return false;
        Object* d = defOf.get((Hashable*)o.val());
        if (d == (Object*)0)
            return false;
        IRInsn* cd = (IRInsn*)d;
        if (!cd.op().equals(String.withCString("Const")) || cd.ops().count() < (u32)1)
            return false;
        IROperand* k = (IROperand*)cd.ops().get((u32)0);
        if (k.kind() != (u8)OPK_IMMI)
            return false;
        out[0] = k.imm();
        return true;
        }

    bool isIntType(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")) || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"));
        }

    // Give each base a pointer phi stepped by the loop's stride, point every
    // grouped ElementAddr at it (directly when the offset is zero, through one
    // small ElementAddr otherwise), and drop the originals.
    // `base + ivInit` in the preheader: the pointer induction variable's true
    // starting address when the loop does not count from zero.
    IRValue* pivSeed(IRBlock* PH, IRValue* base, String* ptrTy, String* ivTy,
                     IROperand* ivInit, i32 initV)
        {
        IRValue* seed = new IRValue(ptrTy);
        IRInsn* seedInsn = IRInsn.with(String.withCString("ElementAddr"));
        seedInsn.setRes(seed);
        seedInsn.add(IROperand.useVal(base));
        if (ivInit.kind() == (u8)OPK_USE)
            {
            seedInsn.add(IROperand.useVal(ivInit.val()));
            }
        else
            {
            seedInsn.add(IROperand.immI(initV, ivTy));
            }
        PH.insns().add((Object*)seedInsn);
        return seed;
        }

    void pivRewrite(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* PH,
                    String* ivTy, Array* bases, Array* groups, Map* defOf,
                    IROperand* ivInit)
        {
        // Seed the pointer phi at `base + ivInit`, not `base`. Seeding with the
        // bare base is right only when the loop counts from zero, so
        // `for (i = a; ...)` read from the start of the array instead of from
        // `a` — correct at -O0/-O1, wrong at -O2+ (#1125).
        i32 pivInitV = (i32)0;
        bool pivInitZero = constValue(defOf, ivInit, &pivInitV) && pivInitV == (i32)0;
        Array* head = new Array();    // pointer steps + offset ElementAddrs
        Array* deadEAs = new Array(); // the originals they replace
        Map* replace = new Map();     // old ElementAddr result → new value

        for (u32 gi = (u32)0; gi < bases.count(); gi = gi + (u32)1)
            {
            IRValue* base = (IRValue*)bases.get(gi);
            String* ptrTy = base.ty();

            // A base that is an `AddrOf @sym` defined INSIDE the loop is a
            // constant address, so it moves to the preheader — otherwise the
            // pointer phi's preheader incoming would not dominate the loop.
            Object* bo = defOf.get((Hashable*)base);
            if (bo != (Object*)0 && ((IRInsn*)bo).op().equals(String.withCString("AddrOf")))
                {
                IRInsn* bdef = (IRInsn*)bo;
                bool moved = removeInsn(H, bdef);
                if (removeInsn(B, bdef))
                    moved = true;
                if (moved)
                    PH.insns().add((Object*)bdef);
                }

            // p = phi[(PH, base), (B, pNext)];  pNext = ElementAddr(p, step).
            IRValue* p = new IRValue(ptrTy);
            IRValue* pNext = new IRValue(ptrTy);
            IRInsn* stepInsn = IRInsn.with(String.withCString("ElementAddr"));
            stepInsn.setRes(pNext);
            stepInsn.add(IROperand.useVal(p));
            stepInsn.add(IROperand.immI(_pivStep, ivTy));
            head.add((Object*)stepInsn);

            // `base + ivInit`, materialised in the PREHEADER when the loop does
            // not start at zero. In a HELPER, not inline: pivRewrite is already
            // near the 16 KB arm64 frame budget and these locals push it over.
            IRValue* phIn = base;
            if (!pivInitZero)
                {
                phIn = pivSeed(PH, base, ptrTy, ivTy, ivInit, pivInitV);
                }

            IRInsn* pPhi = IRInsn.with(String.withCString("Phi"));
            pPhi.setRes(p);
            pPhi.add(IROperand.block(PH));
            pPhi.add(IROperand.useVal(phIn));
            pPhi.add(IROperand.block(B));
            pPhi.add(IROperand.useVal(pNext));
            H.addPhi(pPhi);

            Array* g = (Array*)groups.get(gi);
            for (u32 k = (u32)0; k + (u32)1 < g.count(); k = k + (u32)2)
                {
                IRInsn* E = (IRInsn*)g.get(k);
                i32 off = ((Number*)g.get(k + (u32)1)).asI32();
                if (off == (i32)0)
                    {
                    replace.set((Hashable*)E.res(), (Object*)p);
                    }
                else
                    {
                    IRValue* ea = new IRValue(ptrTy);
                    IRInsn* eaInsn = IRInsn.with(String.withCString("ElementAddr"));
                    eaInsn.setRes(ea);
                    eaInsn.add(IROperand.useVal(p));
                    eaInsn.add(IROperand.immI(off, ivTy));
                    head.add((Object*)eaInsn);
                    replace.set((Hashable*)E.res(), (Object*)ea);
                    }
                deadEAs.add((Object*)E);
                }
            }

        // Rebuild the latch: the pointer steps and offset addresses first (they
        // depend only on the new phis and each other), then the surviving body
        // with the old ElementAddrs dropped.
        Array* nb = new Array();
        for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
            nb.add(head.get(i));
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (hasInsn(deadEAs, n))
                continue;
            nb.add((Object*)n);
            }
        B.setInsns(nb);

        // Every use of a replaced address, across the whole function.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.phis().get(k), replace);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.insns().get(k), replace);
            if (bb.term() != (IRInsn*)0)
                pivReplaceIn(bb.term(), replace);
            }
        }

    void pivReplaceIn(IRInsn* n, Map* replace)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            Object* to = replace.get((Hashable*)o.val());
            if (to == (Object*)0)
                continue;
            n.ops().set(i, (Object*)IROperand.useVal((IRValue*)to));
            }
        }

    bool removeInsn(IRBlock* bb, IRInsn* n)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            if ((IRInsn*)bb.insns().get(i) == n)
                {
                bb.insns().removeAt(i);
                return true;
                }
        return false;
        }

    // ── strength-reduce ──────────────────────────────────────────────────
    //
    // Multiply and divide by a power of two become a shift, and the ×0 / %1
    // cases become a constant. `x*1` and `x/1` are deliberately left alone:
    // reducing them to `x` needs a use-rewrite, and the xt6502 backend has no
    // Copy to lower, so the identities that pay are the ones emitting a
    // supported Shl / LShr / And / Const.
    void strengthReduce(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            srInFunc((IRFunc*)m.funcs().get(f));
        }

    void srInFunc(IRFunc* fn)
        {
        Map* defOf = defMap(fn);
        bool changed = false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (srInsn(bb, i, defOf))
                    changed = true;
            }
        if (!changed)
            return;
        srSweepDead(fn);
        }

    // Drop Const / ZExt / SExt / Trunc whose result nothing reads any more —
    // the detached multiplier constant and its widening — to a fixpoint, since
    // removing a widening can orphan the constant behind it. Shared by
    // strength-reduce and const-operand-fold, which end the same way.
    void srSweepDead(IRFunc* fn)
        {
        bool removed = true;
        while (removed)
            {
            removed = false;
            Map* used = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.phis().get(k));
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.insns().get(k));
                if (bb.term() != (IRInsn*)0)
                    srNoteUses(used, bb.term());
                }
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = bb.insns().count(); i > (u32)0; i = i - (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i - (u32)1);
                    if (!srIsPure(n.op()))
                        continue;
                    if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
                        continue;
                    if (used.get((Hashable*)n.res()) != (Object*)0)
                        continue;
                    bb.insns().removeAt(i - (u32)1);
                    removed = true;
                    }
                }
            }
        }

    void srNoteUses(Map* used, IRInsn* n)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE)
                used.set((Hashable*)o.val(), (Object*)o.val());
            }
        }

    bool srIsPure(String* op)
        {
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc"));
        }

    bool srInsn(IRBlock* bb, u32 i, Map* defOf)
        {
        IRInsn* n = (IRInsn*)bb.insns().get(i);
        String* op = n.op();
        bool isMul = op.equals(String.withCString("Mul"));
        if (!isMul && !op.equals(String.withCString("UDiv")) && !op.equals(String.withCString("URem")) && !op.equals(String.withCString("SDiv")) && !op.equals(String.withCString("SRem")))
            return false;
        if (n.ops().count() < (u32)2 || n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
            return false;

        // The constant must be the RHS; Mul commutes, so its LHS is tried too,
        // keeping the other operand as the variable.
        i64 c = (i64)0;
        bool cu = false;
        IROperand* xop = (IROperand*)0;
        if (srConst(defOf, (IROperand*)n.ops().get((u32)1), &c, &cu))
            xop = (IROperand*)n.ops().get((u32)0);
        else if (isMul && srConst(defOf, (IROperand*)n.ops().get((u32)0), &c, &cu))
            xop = (IROperand*)n.ops().get((u32)1);
        else
            return false;

        String* rt = n.res().ty();
        u32 widthBits = srWidth(rt) * (u32)8;
        i32 k = srLog2Pow2(c); // 64-bit aware: the original resolves int64_t
        // The shift count stays in range, so nothing depends on the runtime
        // shift routine's out-of-range behaviour.
        bool pow2 = k >= (i32)1 && widthBits > (u32)0 && (u32)k < widthBits;

        IRInsn* repl = (IRInsn*)0;
        if (isMul)
            {
            if (c == (i64)0)
                repl = srConstZero(n, rt);
            else if (pow2)
                repl = srBinImm(n, String.withCString("Shl"), xop,
                                (i64)k, false, String.withCString("U8"));
            }
        else if (op.equals(String.withCString("UDiv")))
            {
            if (pow2)
                repl = srBinImm(n, String.withCString("LShr"), xop,
                                (i64)k, false, String.withCString("U8"));
            }
        else if (op.equals(String.withCString("URem")))
            {
            if (c == (i64)1)
                repl = srConstZero(n, rt);
            else if (pow2)
                repl = srBinImm(n, String.withCString("And"), xop,
                                c - (i64)1, cu, rt);
            }
        else if (op.equals(String.withCString("SRem")))
            {
            if (c == (i64)1)
                repl = srConstZero(n, rt); // x%1 == 0, any sign
            }
        if (repl == (IRInsn*)0)
            return false;
        bb.insns().set(i, (Object*)repl);
        return true;
        }

    IRInsn* srBinImm(IRInsn* n, String* newOp, IROperand* xop,
                     i64 imm, bool isU, String* immTy)
        {
        IRInsn* r = IRInsn.with(newOp);
        r.setRes(n.res());
        r.add(xop);
        r.add(mkImm(imm, isU, immTy));
        return r;
        }

    // An integer immediate that prints the way the one it came from printed —
    // `%lu` for bits that read unsigned, `%ld` otherwise. Rebuilding a folded
    // constant without this turns `#2246822519:U32` into `#-2048144777:U32`.
    IROperand* mkImm(i64 v, bool isU, String* ty)
        {
        return isU ? IROperand.immU64((u64)v, ty) : IROperand.immI(v, ty);
        }

    IRInsn* srConstZero(IRInsn* n, String* rt)
        {
        IRInsn* r = IRInsn.with(String.withCString("Const"));
        r.setRes(n.res());
        r.add(IROperand.immI((i32)0, rt));
        return r;
        }

    // log2(n) when n is a positive power of two, else -1.
    i32 srLog2Pow2(i64 n)
        {
        if (n <= (i64)0)
            return (i32)-1;
        u64 u = (u64)n;
        if ((u & (u - (u64)1)) != (u64)0)
            return (i32)-1;
        i32 k = (i32)0;
        while ((u >> (u64)k) != (u64)1)
            k = k + (i32)1;
        return k;
        }

    // Byte width of a scalar type spelling. Wider than irWidth (which the
    // narrower needs kept as it is) because a Mul result can be 64-bit.
    u32 srWidth(String* t)
        {
        if (t == (String*)0)
            return (u32)0;
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")))
            return (u32)8;
        return irWidth(t);
        }

    // ── loop-unroll-var-trip ─────────────────────────────────────────────
    //
    // Partial-unroll a loop whose trip count is NOT known: emit four copies of
    // the body, each intermediate one guarded by its own compare so it can fall
    // out to the exit, and the last taking the back edge. Four is clang's
    // common choice — the out-of-order host hides most of the cross-iteration
    // overlap anyway, so a larger factor buys little and bloats the code.
    //
    // Profile-gated: on for arm64, arm9, x86_64 and win64; off for the 68000
    // (kernel-dependent there — the extra live values an unrolled body carries
    // spill) and for the 6502.
    void loopUnrollVarTrip(IRModule* m)
        {
        if (!_profile.unrollVarTrip())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop at a time, re-recognised from the live CFG: an unrolled
            // body is no longer a single block, so it cannot re-match and the
            // bound is only a runaway backstop.
            u32 iter = (u32)0;
            while (iter < (u32)256)
                {
                VTCand* c = vtRecognise(fn);
                if (c == (VTCand*)0)
                    break;
                vtApply(fn, c);
                iter = iter + (u32)1;
                }
            }
        }

    VTCand* vtRecognise(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                {
                defOf.set((Hashable*)bb.term().res(), (Object*)bb.term());
                defBlk.set((Hashable*)bb.term().res(), (Object*)bb);
                }
            }
        Map* uses = useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VTCand* c = vtAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VTCand*)0)
                return c;
            }
        return (VTCand*)0;
        }

    IRInsn* _vtIvPhi;
    IRInsn* _vtGuard;
    IRValue* _vtIv;
    IRBlock* _vtB;
    IRBlock* _vtE;

    // The header/body/exit shape: at least the induction phi, a pure header, a
    // CondBranch on an ICmp, a single-block call-free body that latches back.
    bool vtShape(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        _vtIvPhi = (IRInsn*)0;
        _vtGuard = (IRInsn*)0;
        _vtIv = (IRValue*)0;
        _vtB = (IRBlock*)0;
        _vtE = (IRBlock*)0;
        if (H.phis().count() == (u32)0)
            return false;
        if (H.phis().count() > (u32)1 && !_profile.unrollMultiCarried())
            return false;
        // An already-vectorised reduction carries a VECTOR phi; cloning it would
        // defeat the backend's in-place accumulate coalescing.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && isVectorType(p.res().ty()))
                return false;
            }
        // The header runs once per group after unrolling, so anything with a
        // side effect there would fire a different number of times.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n.memRes() != (IRValue*)0 || vtIsCall(n.op()))
                return false;
            }
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;

        // The induction phi is whichever header phi the guard tests directly.
        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0)
                continue;
            if (insnUsesValue(guard, p.res()))
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0)
            return false;
        if (!isIntType(ivPhi.res().ty()))
            return false;

        IRBlock* T = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* F = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (vtLatches(T, H))
            {
            B = T;
            E = F;
            }
        else if (vtLatches(F, H))
            {
            B = F;
            E = T;
            }
        else
            return false;
        if (E == (IRBlock*)0 || B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;
        if (B.insns().count() == (u32)0 || B.insns().count() > (u32)48)
            return false;
        // Call-free, and free of the horizontal reduces (which live in the exit
        // block, never the body). A vectorised MAP body is fine — the clone path
        // handles VLoad/VStore memory tokens like any other.
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)B.insns().get(i)).op();
            if (vtIsCall(op) || op.equals(String.withCString("VReduceAdd")) || op.equals(String.withCString("VReduceMax")) || op.equals(String.withCString("VReduceMin")))
                return false;
            }
        _vtIvPhi = ivPhi;
        _vtGuard = guard;
        _vtIv = ivPhi.res();
        _vtB = B;
        _vtE = E;
        return true;
        }

    // The variable-trip unroller's own call test, which is NARROWER than the
    // const-trip one: it does not count CallIndirect / VTblDispatch /
    // ProtoDispatch, so a body that dispatches through a vtable still unrolls.
    // The two passes really do differ here.
    bool vtIsCall(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked"));
        }

    bool vtLatches(IRBlock* b, IRBlock* H)
        {
        return b != (IRBlock*)0 && b != H && b.term() != (IRInsn*)0 && b.term().op().equals(String.withCString("Branch")) && b.term().ops().count() >= (u32)1 && ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    VTCand* vtAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (!vtShape(fn, H, defOf, defBlk))
            return (VTCand*)0;
        IRInsn* ivPhi = _vtIvPhi;
        IRInsn* guard = _vtGuard;
        IRValue* iv = _vtIv;
        IRBlock* B = _vtB;
        IRBlock* E = _vtE;

        // ivNext = Add(iv, step) in the body, read only by the phi.
        if (ivPhi.ops().count() != (u32)4)
            return (VTCand*)0;
        IROperand* nextOp = vecBackOp(ivPhi, B);
        if (nextOp == (IROperand*)0 || nextOp.kind() != (u8)OPK_USE)
            return (VTCand*)0;
        Object* no = defOf.get((Hashable*)nextOp.val());
        Object* nb = defBlk.get((Hashable*)nextOp.val());
        if (no == (Object*)0 || nb == (Object*)0 || (IRBlock*)nb != B)
            return (VTCand*)0;
        IRInsn* ivNext = (IRInsn*)no;
        if (!ivNext.op().equals(String.withCString("Add")) || countOf(uses, nextOp.val()) != (u32)1 || ivNext.ops().count() < (u32)2)
            return (VTCand*)0;
        IROperand* a0 = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* a1 = (IROperand*)ivNext.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
            stepOp = a1;
        else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
            stepOp = a0;
        if (stepOp == (IROperand*)0)
            return (VTCand*)0;
        // The step must not vary with the iv — a per-copy clone would recompute
        // a different value. Defined outside the body means loop-invariant; a
        // body-defined step is safe only when it folds to a constant, which each
        // copy simply re-materialises.
        i32 stepK = (i32)0;
        bool stepConst = vecConst(stepOp, defOf, &stepK);
        if (stepOp.kind() == (u8)OPK_USE && !stepConst)
            {
            Object* sb = defBlk.get((Hashable*)stepOp.val());
            if (sb != (Object*)0 && (IRBlock*)sb == B)
                return (VTCand*)0;
            }
        // The guard's bound must not live in the body either — the cloned guards
        // reference it from outside the block that is about to be removed.
        for (u32 i = (u32)0; i < guard.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)guard.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == iv)
                continue;
            Object* ob = defBlk.get((Hashable*)o.val());
            if (ob != (Object*)0 && (IRBlock*)ob == B)
                return (VTCand*)0;
            }
        // The iv must not escape: there is no exit phi materialising its final
        // value, so an outside reader would see the wrong one.
        if (vtEscapes(fn, H, B, iv))
            return (VTCand*)0;

        VTCand* c = new VTCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, guard, ivNext, iv);
        c.setStep(stepOp, stepConst, stepK);

        // A CONSTANT trip that is a whole number of unrolled groups needs no
        // per-copy guard: the vectoriser leaves exactly that behind, array_map
        // counting 0..4096 by 4 being 256 groups of four.
        //
        // Only a STRICT `<` with the iv on the left gives trip = (N - S) / step;
        // `<=` is one more and the arithmetic would be off in the unsafe
        // direction. And only for a VECTOR body: dropping the guards merges the
        // copies into one straight-line run, which lengthens every live range in
        // it. A vector body barely notices — its values live in their own pool —
        // but a scalar body spills instead. Measured: array_map 11431 -> 6730us
        // with the gate, bit_ops unchanged; without the gate bit_ops loses 5%.
        bool vecBody = false;
        for (u32 k = (u32)0; k < B.insns().count(); k = k + (u32)1)
            {
            IRInsn* bi = (IRInsn*)B.insns().get(k);
            if (bi.res() != (IRValue*)0 && bi.res().ty().hasPrefix(String.withCString("Vec(")))
                vecBody = true;
            }
        c.setVectorBody(vecBody);
        bool exact = false;
        if (stepConst && stepK > (i32)0 && guard.ops().count() >= (u32)2
            && (guard.pred().equals(String.withCString("ULT"))
                || guard.pred().equals(String.withCString("SLT")))
            && ((IROperand*)guard.ops().get((u32)0)).kind() == (u8)OPK_USE
            && ((IROperand*)guard.ops().get((u32)0)).val() == iv)
            {
            IROperand* initOp = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < ivPhi.ops().count(); k = k + (u32)2)
                if (((IROperand*)ivPhi.ops().get(k)).blk() != B)
                    initOp = (IROperand*)ivPhi.ops().get(k + (u32)1);
            i32 boundK = (i32)0;
            i32 startK = (i32)0;
            if (initOp != (IROperand*)0
                && vecConst((IROperand*)guard.ops().get((u32)1), defOf, &boundK)
                && vecConst(initOp, defOf, &startK))
                {
                i32 span = boundK - startK;
                i32 group = stepK * (i32)4;
                if (span > (i32)0 && group > (i32)0 && span % group == (i32)0
                    && c.vectorBody())
                    exact = true;
                }
            }
        c.setExactTrip(exact);
        if (!vtCarried(fn, H, B, c, defOf, defBlk, uses))
            return (VTCand*)0;

        // When an accumulator escapes, the apply builds an exit phi in E whose
        // incomings are the header plus the intermediate copies. That covers all
        // of E's edges only if E was reached solely from the header beforehand —
        // otherwise an external predecessor would leave the phi an incoming short.
        bool anyEsc = false;
        for (u32 i = (u32)0; i < c.redEsc().count(); i = i + (u32)1)
            if (((Number*)c.redEsc().get(i)).asI32() != (i32)0)
                {
                anyEsc = true;
                break;
                }
        if (anyEsc)
            {
            u32 ePreds = (u32)0;
            bool onlyH = true;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (bb.term() == (IRInsn*)0)
                    continue;
                for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)bb.term().ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() != E)
                        continue;
                    ePreds = ePreds + (u32)1;
                    if (bb != H)
                        onlyH = false;
                    break;
                    }
                }
            if (!onlyH || ePreds != (u32)1)
                return (VTCand*)0;
            }
        return c;
        }

    // Is `v` read anywhere outside the header and the body?
    bool vtEscapes(IRFunc* fn, IRBlock* H, IRBlock* B, IRValue* v)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            if (unrollUsesValue(bb, v))
                return true;
            }
        return false;
        }

    // Every non-induction header phi is a carried accumulator, and each must have
    // the standard (preheader init, body update) shape with the update in the
    // body and read only by the phi. The copies then serial-chain it, preserving
    // order — so no associativity is required and float reductions are fine.
    bool vtCarried(IRFunc* fn, IRBlock* H, IRBlock* B, VTCand* c,
                   Map* defOf, Map* defBlk, Map* uses)
        {
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p == c.ivPhi())
                continue;
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            String* rt = p.res().ty();
            if (rt == (String*)0 || rt.equals(String.withCString("Mem")) || rt.equals(String.withCString("Void")) || rt.hasPrefix(String.withCString("Agg(")))
                return false;
            IROperand* rNextOp = vecBackOp(p, B);
            if (rNextOp == (IROperand*)0 || rNextOp.kind() != (u8)OPK_USE)
                return false;
            Object* ro = defOf.get((Hashable*)rNextOp.val());
            Object* rb = defBlk.get((Hashable*)rNextOp.val());
            if (ro == (Object*)0 || rb == (Object*)0 || (IRBlock*)rb != B)
                return false;
            if (countOf(uses, rNextOp.val()) != (u32)1)
                return false;
            c.redPhis().add((Object*)p);
            c.redNexts().add(ro);
            c.redVals().add((Object*)p.res());
            c.redEsc().add((Object*)Number.withI32(
                vtEscapes(fn, H, B, p.res()) ? (i32)1 : (i32)0));
            }
        return true;
        }

    // Four copies, each intermediate one guarded so it can fall out to the exit,
    // the last taking the back edge. Accumulators are serial-chained through
    // the copies; escaping ones get an exit phi covering every way out.
    Array* _vtClones;
    Array* _vtGuards;   // per copy; the last has none
    Array* _vtAccAfter; // per accumulator: its value after each copy
    Array* _vtLastRed;  // per accumulator: the value feeding the back edge
    Map* _vtLastMap;    // the last copy's old→new value map
    Map* _vtSharedPure; // orig result → copy-0 clone, for pure invariant insns
    IRValue* _vtLastIvNext;

    void vtApply(IRFunc* fn, VTCand* c)
        {
        IRBlock* H = c.h();
        IRBlock* B = c.b();
        IRBlock* E = c.e();
        u32 U = (u32)4;

        _vtClones = new Array();
        _vtGuards = new Array();
        _vtAccAfter = new Array();
        _vtLastRed = new Array();
        _vtLastIvNext = c.iv();
        Array* prevRed = new Array();
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            {
            prevRed.add(c.redVals().get(i));
            _vtLastRed.add(c.redVals().get(i));
            _vtAccAfter.add((Object*)new Array());
            }

        IRValue* prevIv = c.iv(); // copy 0 enters with the header phi
        _vtLastMap = new Map();
        // A pure LOOP-INVARIANT body instruction (a VSplat of an outer-loop
        // value the vectoriser left in the body, or the Const/cast chain
        // feeding it) computes the same value in every copy: clone it once, in
        // copy 0, and let the later copies reference that result — copy 0
        // dominates them. One live broadcast instead of U is what keeps the
        // backends' 8-register vector pools from overflowing (#1198).
        _vtSharedPure = new Map();
        for (u32 j = (u32)0; j < U; j = j + (u32)1)
            prevIv = vtCopy(fn, c, j, U, prevIv, prevRed);

        vtWire(fn, c, U);
        }

    // Invariant iff pure (VSplat / Const / a cast) and every Use operand is
    // either defined outside the body (not remapped) or itself a shared
    // invariant clone (#1198). A helper so vtCopy stays under the arm64
    // frame budget.
    bool vtShareable(IRInsn* n, VTCand* c, Map* map)
        {
        if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0 || n == c.ivNext())
            return false;
        if (!n.op().equals(String.withCString("VSplat")) && !n.op().equals(String.withCString("Const")) && !n.op().equals(String.withCString("ZExt")) && !n.op().equals(String.withCString("SExt")) && !n.op().equals(String.withCString("Trunc")))
            return false;
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && map.get((Hashable*)o.val()) != (Object*)0 && _vtSharedPure.get((Hashable*)o.val()) == (Object*)0)
                return false;
            }
        return true;
        }

    // One copy of the body. Returns the induction value the NEXT copy enters
    // with; `prevRed` carries each accumulator's incoming value and is advanced.
    IRValue* vtCopy(IRFunc* fn, VTCand* c, u32 j, u32 U,
                    IRValue* prevIv, Array* prevRed)
        {
        IRBlock* B = c.b();
        String* base = B.name() == (String*)0 ? String.withCString("body") : B.name();
        String* nm = new String();
        nm.appendFormat("%s_vu%lu", base.cString(), j);
        IRBlock* C = new IRBlock(nm);

        Map* map = new Map();
        map.set((Hashable*)c.iv(), (Object*)prevIv);
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            map.set((Hashable*)(IRValue*)c.redVals().get(i), prevRed.get(i));

        // A POINTER carried by a constant stride is RE-BASED on copy 0 rather
        // than chained. The chain `p -> p+16 -> p+32 -> p+48` costs one add per
        // copy per array; `p+0, p+16, p+32, p+48` costs none, because the back
        // end folds ElementAddr(base, CONSTANT) into `ldr/str q, [base, #imm]`.
        // mem_copy carries two pointers over four copies — eight adds on a
        // twenty-instruction body.
        if (j > (u32)0 && c.vectorBody())
            {
            for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
                {
                IRInsn* rn = (IRInsn*)c.redNexts().get(i);
                IRValue* rp = (IRValue*)c.redVals().get(i);
                if (rn == (IRInsn*)0 || !rn.op().equals(String.withCString("ElementAddr")))
                    continue;
                if (rn.ops().count() < (u32)2)
                    continue;
                IROperand* b0 = (IROperand*)rn.ops().get((u32)0);
                IROperand* b1 = (IROperand*)rn.ops().get((u32)1);
                if (b0.kind() != (u8)OPK_USE || b0.val() != rp || b1.kind() != (u8)OPK_IMMI)
                    continue;
                if (!rp.ty().hasPrefix(String.withCString("Ptr(")))
                    continue;
                IRValue* rv = new IRValue(rp.ty());
                IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
                ea.setRes(rv);
                ea.add(IROperand.useVal(rp));
                ea.add(IROperand.immI((i32)(b1.imm() * (i64)j), b1.ty()));
                C.add(ea);
                map.set((Hashable*)rp, (Object*)rv);
                }
            }

        IRValue* cloneIvNext = prevIv;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            bool shareable = vtShareable(n, c, map);
            if (shareable && _vtSharedPure.get((Hashable*)n.res()) != (Object*)0)
                {
                map.set((Hashable*)n.res(), _vtSharedPure.get((Hashable*)n.res()));
                continue; // copies 1..U-1 reuse copy 0's
                }
            IRInsn* cl = IRInsn.with(n.op());
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                cl.add(unrollSubstMap(map, (IROperand*)n.ops().get(k)));
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                map.set((Hashable*)n.res(), (Object*)cl.res());
                }
            if (n.memRes() != (IRValue*)0)
                {
                cl.setMemRes(new IRValue(String.withCString("Mem")));
                map.set((Hashable*)n.memRes(), (Object*)cl.memRes());
                }
            C.add(cl);
            if (n == c.ivNext())
                cloneIvNext = cl.res();
            if (shareable)
                _vtSharedPure.set((Hashable*)n.res(), (Object*)cl.res());
            }

        // Each accumulator's update in this copy is its value afterwards.
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            {
            IRInsn* rn = (IRInsn*)c.redNexts().get(i);
            Object* cn = map.get((Hashable*)rn.res());
            ((Array*)_vtAccAfter.get(i)).add(cn);
            prevRed.set(i, cn);
            if (j + (u32)1 == U)
                _vtLastRed.set(i, cn);
            }

        if (j + (u32)1 < U && c.exactTrip())
            {
            // Provably true — no guard; the copy falls into the next one.
            _vtGuards.add((Object*)0);
            }
        else if (j + (u32)1 < U)
            {
            // An intermediate copy tests `iv_{j+1} <cmp> bound` and either falls
            // through to the next copy or leaves for the exit.
            Map* gmap = new Map();
            gmap.set((Hashable*)c.iv(), (Object*)cloneIvNext);
            IRInsn* g = IRInsn.with(c.guard().op());
            g.setPred(c.guard().pred());
            g.setRes(new IRValue(c.guard().res().ty()));
            for (u32 k = (u32)0; k < c.guard().ops().count(); k = k + (u32)1)
                g.add(unrollSubstMap(gmap, (IROperand*)c.guard().ops().get(k)));
            C.add(g);
            _vtGuards.add((Object*)g.res());
            }
        else
            {
            _vtGuards.add((Object*)0);
            // The back-edge induction update is computed INDEPENDENTLY of the
            // per-copy chain: iv_next = iv_0 + U*step rather than iv_{U-1}+step.
            // The chain still feeds the copies' bodies, but the value crossing
            // the back edge no longer waits on it — the carried recurrence drops
            // from U serial adds to one. The multiply is loop-invariant and off
            // the carried path, and for a power-of-two U folds to a shifted add.
            String* ivTy = c.ivPhi().res().ty();
            IROperand* nStep = (IROperand*)0;
            if (c.stepIsConst())
                {
                nStep = IROperand.immI(c.stepK() * (i32)U, ivTy);
                }
            else
                {
                IRValue* mres = new IRValue(ivTy);
                IRInsn* mi = IRInsn.with(String.withCString("Mul"));
                mi.setRes(mres);
                mi.add(c.step());
                mi.add(IROperand.immI((i32)U, ivTy));
                C.add(mi);
                nStep = IROperand.useVal(mres);
                }
            IRValue* ares = new IRValue(ivTy);
            IRInsn* ai = IRInsn.with(String.withCString("Add"));
            ai.setRes(ares);
            ai.add(IROperand.useVal(c.iv()));
            ai.add(nStep);
            C.add(ai);
            _vtLastIvNext = ares;
            }
        _vtClones.add((Object*)C);
        _vtLastMap = map;
        return cloneIvNext;
        }

    // ── Loop cloning, for the vectoriser epilogue ────────────────────────
    //
    // Mirrors xtvCloneLoop in XTIROptVectorize.m. Clones a loop (header H with
    // its phis, single body B) into a fresh pair with all-new values, so the
    // ORIGINAL can be vectorised in place while the clone survives as the
    // scalar remainder. `vmap` receives old value -> new value for everything
    // the clone defines; block references are remapped H->H2 and B->B2, while
    // any OTHER block reference (the preheader edge of a phi, the exit target)
    // is left pointing at the original for the caller to re-point.
    IROperand* vecSubst(Map* vmap, Map* bmap, IROperand* o)
        {
        if (o.kind() == (u8)OPK_BLOCK)
            {
            Object* nb = bmap.get((Hashable*)o.blk());
            return nb == (Object*)0 ? o : IROperand.block((IRBlock*)nb);
            }
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* nv = vmap.get((Hashable*)o.val());
        return nv == (Object*)0 ? o : IROperand.useVal((IRValue*)nv);
        }

    IRInsn* vecCloneInsn(IRInsn* n, Map* vmap, Map* bmap)
        {
        IRInsn* cl = IRInsn.with(n.op());
        cl.setPred(n.pred());
        cl.setCc(n.cc());
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            cl.add(vecSubst(vmap, bmap, (IROperand*)n.ops().get(k)));
        if (n.res() != (IRValue*)0)
            {
            cl.setRes(new IRValue(n.res().ty()));
            vmap.set((Hashable*)n.res(), (Object*)cl.res());
            }
        if (n.memRes() != (IRValue*)0)
            {
            cl.setMemRes(new IRValue(String.withCString("Mem")));
            vmap.set((Hashable*)n.memRes(), (Object*)cl.memRes());
            }
        return cl;
        }

    Array* vecCloneLoop(IRBlock* H, IRBlock* B, Map* vmap)
        {
        IRBlock* H2 = new IRBlock(hoistName2(H.name(), "_rem"));
        IRBlock* B2 = new IRBlock(hoistName2(B.name(), "_rem"));
        Map* bmap = new Map();
        bmap.set((Hashable*)H, (Object*)H2);
        bmap.set((Hashable*)B, (Object*)B2);

        // PHIS IN TWO PASSES. A phi names values defined LATER in the loop (its
        // back-edge update), so every result must exist before any operand is
        // remapped — a single pass would leave the back edge pointing at the
        // original loop's values.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == (IRValue*)0)
                continue;
            vmap.set((Hashable*)phi.res(), (Object*)new IRValue(phi.res().ty()));
            }
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            B2.add(vecCloneInsn((IRInsn*)B.insns().get(i), vmap, bmap));
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == (IRValue*)0)
                continue;
            IRInsn* cl = IRInsn.with(phi.op());
            cl.setRes((IRValue*)vmap.get((Hashable*)phi.res()));
            for (u32 k = (u32)0; k < phi.ops().count(); k = k + (u32)1)
                cl.add(vecSubst(vmap, bmap, (IROperand*)phi.ops().get(k)));
            H2.addPhi(cl);
            }
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            H2.add(vecCloneInsn((IRInsn*)H.insns().get(i), vmap, bmap));
        if (H.term() != (IRInsn*)0)
            H2.setTerm(vecCloneInsn(H.term(), vmap, bmap));
        if (B.term() != (IRInsn*)0)
            B2.setTerm(vecCloneInsn(B.term(), vmap, bmap));

        Array* out = new Array();
        out.add((Object*)H2);
        out.add((Object*)B2);
        return out;
        }

    // `string` (a C literal), NOT String* — the same convention hoistName uses.
    // Declaring the parameter as String* and passing "_rem" made cString() read
    // a raw literal as an object: the ported optimiser segfaulted (exit 139) on
    // the first loop it tried to clone.
    static String* hoistName2(String* base, string suffix)
        {
        String* s = String.withCString("");
        s.append(base);
        s.appendCString(suffix);
        return s;
        }

    IROperand* unrollSubstMap(Map* map, IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE)
            return o;
        Object* n = map.get((Hashable*)o.val());
        if (n == (Object*)0)
            return o;
        return IROperand.useVal((IRValue*)n);
        }

    // Terminators, header phis, the splice, and the exit phis for accumulators
    // that are read after the loop.
    void vtWire(IRFunc* fn, VTCand* c, u32 U)
        {
        IRBlock* H = c.h();
        IRBlock* B = c.b();
        IRBlock* E = c.e();
        IRBlock* last = (IRBlock*)_vtClones.get(_vtClones.count() - (u32)1);

        for (u32 j = (u32)0; j < _vtClones.count(); j = j + (u32)1)
            {
            IRBlock* C = (IRBlock*)_vtClones.get(j);
            if (j + (u32)1 < _vtClones.count() && _vtGuards.get(j) == (Object*)0)
                {
                IRInsn* br = IRInsn.with(String.withCString("Branch"));
                br.add(IROperand.block((IRBlock*)_vtClones.get(j + (u32)1)));
                C.setTerm(br);
                }
            else if (j + (u32)1 < _vtClones.count())
                {
                IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
                cb.add(IROperand.useVal((IRValue*)_vtGuards.get(j)));
                cb.add(IROperand.block((IRBlock*)_vtClones.get(j + (u32)1)));
                cb.add(IROperand.block(E));
                C.setTerm(cb);
                }
            else
                {
                IRInsn* br = IRInsn.with(String.withCString("Branch"));
                br.add(IROperand.block(H));
                C.setTerm(br);
                }
            }

        // The header phis' body incoming moves to the last copy.
        vtRetargetPhi(c.ivPhi(), B, last, _vtLastIvNext);
        for (u32 i = (u32)0; i < c.redPhis().count(); i = i + (u32)1)
            vtRetargetPhi((IRInsn*)c.redPhis().get(i), B, last,
                          (IRValue*)_vtLastRed.get(i));

        // …and the header's guard branch now enters the first copy.
        IRInsn* t = H.term();
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == B)
                t.ops().set(k, (Object*)IROperand.block((IRBlock*)_vtClones.get((u32)0)));
            }

        // Splice: drop the body, put the copies where it was.
        u32 pos = fn.blocks().count();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if ((IRBlock*)fn.blocks().get(b) == B)
                {
                pos = b;
                break;
                }
        Array* kept = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != B)
                kept.add((Object*)bb);
            }
        if (pos > kept.count())
            pos = kept.count();
        for (u32 j = (u32)0; j < _vtClones.count(); j = j + (u32)1)
            kept.insert(pos + j, _vtClones.get(j));
        fn.setBlocks(kept);

        vtRepairMem(fn, c, B);
        vtExitPhis(fn, c);
        }

    // Memory tokens defined in the body outlive it: the body is spliced out, so
    // a post-loop Load/Store/Return still naming one would reference a value
    // with no definition. Point them at the LAST copy's corresponding token —
    // sound because this IR's memory model is advisory (a token orders
    // operations, it does not name storage), the same reasoning the const-trip
    // unroller's escape remap rests on.
    void vtRepairMem(IRFunc* fn, VTCand* c, IRBlock* B)
        {
        Map* memRemap = new Map();
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* x = (IRInsn*)B.insns().get(i);
            if (x.memRes() == (IRValue*)0)
                continue;
            Object* to = _vtLastMap.get((Hashable*)x.memRes());
            if (to == (Object*)0)
                continue;
            memRemap.set((Hashable*)x.memRes(), to);
            n = n + (u32)1;
            }
        if (n == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (hasBlock(_vtClones, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.phis().get(k), memRemap);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.insns().get(k), memRemap);
            if (bb.term() != (IRInsn*)0)
                pivReplaceIn(bb.term(), memRemap);
            }
        }

    void vtRetargetPhi(IRInsn* phi, IRBlock* from, IRBlock* to, IRValue* v)
        {
        for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
            {
            IROperand* bo = (IROperand*)phi.ops().get(k);
            if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != from)
                continue;
            phi.ops().set(k, (Object*)IROperand.block(to));
            phi.ops().set(k + (u32)1, (Object*)IROperand.useVal(v));
            }
        }

    // After unrolling, the exit is reached from the header (its guard false, so
    // no copy ran this group, carrying the header phi) and from each
    // intermediate copy (its guard false, so copies 0..j ran). The last copy
    // takes the back edge and never exits. The recogniser guaranteed the exit's
    // only predecessor beforehand was the header, so these cover every edge.
    void vtExitPhis(IRFunc* fn, VTCand* c)
        {
        IRBlock* E = c.e();
        Array* exitPhis = new Array();
        Map* remap = new Map();
        for (u32 i = (u32)0; i < c.redPhis().count(); i = i + (u32)1)
            {
            if (((Number*)c.redEsc().get(i)).asI32() == (i32)0)
                continue;
            IRInsn* rp = (IRInsn*)c.redPhis().get(i);
            IRInsn* ep = IRInsn.with(String.withCString("Phi"));
            IRValue* ev = new IRValue(rp.res().ty());
            ep.setRes(ev);
            ep.add(IROperand.block(c.h()));
            ep.add(IROperand.useVal((IRValue*)c.redVals().get(i)));
            Array* after = (Array*)_vtAccAfter.get(i);
            for (u32 j = (u32)0; j + (u32)1 < _vtClones.count(); j = j + (u32)1)
                {
                ep.add(IROperand.block((IRBlock*)_vtClones.get(j)));
                ep.add(IROperand.useVal((IRValue*)after.get(j)));
                }
            E.phis().insert((u32)0, (Object*)ep);
            exitPhis.add((Object*)ep);
            remap.set((Hashable*)(IRValue*)c.redVals().get(i), (Object*)ev);
            }
        if (remap.count() == (u32)0)
            return;
        // Post-loop readers used the header phi, which is now stale mid-group.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == c.h() || hasBlock(_vtClones, bb))
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(k);
                if (hasInsn(exitPhis, n))
                    continue; // not the phi's own header arm
                pivReplaceIn(n, remap);
                }
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.insns().get(k), remap);
            if (bb.term() != (IRInsn*)0)
                pivReplaceIn(bb.term(), remap);
            }
        }

    // ── vectorize ────────────────────────────────────────────────────────
    //
    // Auto-vectorisation: a counted loop whose body is elementwise over
    // iv-indexed arrays becomes one that steps by the vector width and works a
    // whole register at a time. On arm64 and arm9 that is NEON, on x86_64/win64
    // SSE; the 6502 and the 68000 have no vector unit and their profiles say so.
    //
    // Six shapes, tried in the original's order — map, additive reduction,
    // min/max, conditional count, widening sum, dot product — then a final pass
    // that unrolls vectorised reductions across several accumulators to break
    // the serial dependency. Each lands here as it is ported; what is not
    // ported yet simply does not fire, and shows up as a diff rather than as a
    // silent under-optimisation, because the shapes are recognised by structure
    // and the harness compares the whole text.
    void vectorize(IRModule* m)
        {
        if (!_profile.vectorize())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 iter = (u32)0;
            while (iter < (u32)256)
                {
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
                    vecApplyMaxMin(fn, mm);
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
                    vecApplyWidening(fn, ws);
                    iter = iter + (u32)1;
                    continue;
                    }
                VecCand* dp = vecRecogniseDotProduct(fn);
                if (dp != (VecCand*)0)
                    {
                    vecApplyWidening(fn, dp);
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
            // …then break the serial accumulator dependency.
            vecUnrollReductions(fn);
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
    bool vecReassociate(IRFunc* fn)
        {
        bool changed = false;
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(hi);
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

    // Split out for the arm64 frame budget, as vecWideningAt was.
    bool vecReassociateIn(IRFunc* fn, IRBlock* B, Map* accs)
        {
        bool changed = false;
        Map* uses = useCounts(fn);
        for (u32 oi = (u32)0; oi < B.insns().count(); oi = oi + (u32)1)
            {
            IRInsn* outer = (IRInsn*)B.insns().get(oi);
            if (!outer.op().equals(String.withCString("Add")) || outer.res() == (IRValue*)0
                || outer.ops().count() < (u32)2)
                continue;
            // The accumulator must not already be a direct operand.
            bool direct = false;
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                IROperand* o = (IROperand*)outer.ops().get(k);
                if (o.kind() == (u8)OPK_USE && accs.get((Hashable*)o.val()) != (Object*)0)
                    direct = true;
                }
            if (direct)
                continue;
            for (u32 side = (u32)0; side < (u32)2; side = side + (u32)1)
                {
                IROperand* spine = (IROperand*)outer.ops().get(side);
                IROperand* other = (IROperand*)outer.ops().get((u32)1 - side);
                if (spine.kind() != (u8)OPK_USE || countOf(uses, spine.val()) != (u32)1)
                    continue;
                u32 ii = oi;
                bool found = false;
                for (u32 k = (u32)0; k < oi; k = k + (u32)1)
                    if (((IRInsn*)B.insns().get(k)).res() == spine.val())
                        { ii = k; found = true; }
                if (!found)
                    continue;
                IRInsn* inner = (IRInsn*)B.insns().get(ii);
                if (!inner.op().equals(String.withCString("Add")) || inner.ops().count() < (u32)2)
                    continue;
                u32 accSide = (u32)2;
                for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)inner.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && accs.get((Hashable*)o.val()) != (Object*)0)
                        accSide = k;
                    }
                if (accSide == (u32)2)
                    continue;
                IROperand* accOp = (IROperand*)inner.ops().get(accSide);
                IROperand* x = (IROperand*)inner.ops().get((u32)1 - accSide);

                // inner becomes X + Y, keeping its result — its only user is
                // outer — and outer becomes acc + that.
                //
                // It must also MOVE to just before outer. Y is normally
                // computed AFTER the inner Add (it is the next term of the
                // expression), so rewriting inner where it stands would read Y
                // before it is defined. That is not a crash: the register holds
                // whatever was there, and int_muldiv came back 837576896
                // instead of 2079322496 — fast and wrong. Moving it down is
                // safe because X precedes inner and Y precedes outer, so both
                // dominate the new position.
                inner.ops().set((u32)0, (Object*)x);
                inner.ops().set((u32)1, (Object*)other);
                outer.ops().set((u32)0, (Object*)accOp);
                outer.ops().set((u32)1, (Object*)IROperand.useVal(spine.val()));
                B.insns().removeAt(ii);
                B.insns().insert(oi - (u32)1, (Object*)inner);
                changed = true;
                break;
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
    bool vecDistribute(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            if (vecDistributeAt(fn, (IRBlock*)fn.blocks().get(hi)))
                return true;
        return false;
        }

    // Split out for the arm64 frame budget, as vecWideningAt was.
    bool vecDistributeAt(IRFunc* fn, IRBlock* H)
        {
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
        if (!vecDistributePure(B))
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
            IROperand* back = vecBackOp(phi, B);
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
            cones.add((Object*)vecDistributeCone((IRInsn*)accNexts.get(a), B));
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
        IRInsn* victim = (IRInsn*)accPhis.get(accPhis.count() - (u32)1);

        Map* cmap = new Map();
        Array* cl = vecCloneLoop(H, B, cmap);
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
            vecDistributeRewrite(bb.phis(), victim.res(), victimClone);
            vecDistributeRewrite(bb.insns(), victim.res(), victimClone);
            if (bb.term() != (IRInsn*)0)
                vecDistributeRewriteOne(bb.term(), victim.res(), victimClone);
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
        vecDropAcc(fn, victim.res(), H, B);
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
            vecDropAcc(fn, (IRValue*)drop.get(i), H2, B2);
        return true;
        }

    // Every value the cycle-closing instruction depends on, walked backwards
    // through the body. Values defined outside the body (the header's phis, the
    // preheader's invariants) are recorded but not walked through.
    Map* vecDistributeCone(IRInsn* accNext, IRBlock* B)
        {
        Map* cone = new Map();
        Array* work = new Array();
        cone.set((Hashable*)accNext.res(), (Object*)accNext);
        work.add((Object*)accNext);
        while (work.count() > (u32)0)
            {
            IRInsn* cur = (IRInsn*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            for (u32 k = (u32)0; k < cur.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)cur.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == 0)
                    continue;
                if (cone.get((Hashable*)o.val()) != (Object*)0)
                    continue;
                cone.set((Hashable*)o.val(), (Object*)cur);
                for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                    if (((IRInsn*)B.insns().get(i)).res() == o.val())
                        work.add((Object*)B.insns().get(i));
                }
            }
        return cone;
        }

    // Nothing in the body may be observable twice, so the copy may hold only
    // pure arithmetic and loads.
    bool vecDistributePure(IRBlock* B)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)B.insns().get(i)).op();
            if (op.equals(String.withCString("Load")) || op.equals(String.withCString("Const"))
                || op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"))
                || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And"))
                || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor"))
                || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr"))
                || op.equals(String.withCString("AShr")) || op.equals(String.withCString("ICmp"))
                || op.equals(String.withCString("Select")) || op.equals(String.withCString("ZExt"))
                || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc"))
                || op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("FieldAddr"))
                || op.equals(String.withCString("ElementAddr")))
                continue;
            return false;
            }
        return true;
        }

    void vecDistributeRewrite(Array* insns, IRValue* from, IRValue* to)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            vecDistributeRewriteOne((IRInsn*)insns.get(i), from, to);
        }

    void vecDistributeRewriteOne(IRInsn* n, IRValue* from, IRValue* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == from)
                n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    // Remove one accumulator's phi and back-edge definition from a loop, then
    // sweep whatever that orphans out of the body. The cycle is closed, so
    // nothing else can refer to either once the uses outside have been
    // rewritten.
    void vecDropAcc(IRFunc* fn, IRValue* acc, IRBlock* H, IRBlock* B)
        {
        IRValue* back = (IRValue*)0;
        Array* keptPhis = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == acc && phi.ops().count() == (u32)4)
                {
                IROperand* bo = vecBackOp(phi, B);
                if (bo != (IROperand*)0 && bo.kind() == (u8)OPK_USE)
                    back = bo.val();
                continue;
                }
            keptPhis.add((Object*)phi);
            }
        H.setPhis(keptPhis);

        Array* kept = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.res() != (IRValue*)0 && n.res() == back)
                continue;
            kept.add((Object*)n);
            }
        B.setInsns(kept);

        // Sweep the orphans to a fixpoint: removing one can orphan the one
        // behind it.
        bool removed = true;
        while (removed)
            {
            removed = false;
            Map* uses = useCounts(fn);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)B.insns().get(i);
                if (n.res() != (IRValue*)0 && n.memRes() == 0 && countOf(uses, n.res()) == (u32)0)
                    {
                    removed = true;
                    continue;
                    }
                keep.add((Object*)n);
                }
            B.setInsns(keep);
            }
        }

    VecCand* vecRecogniseMap(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                {
                defOf.set((Hashable*)bb.term().res(), (Object*)bb.term());
                defBlk.set((Hashable*)bb.term().res(), (Object*)bb);
                }
            }
        Map* uses = useCounts(fn);

        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecMapAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    void vecNoteDefs(Map* defOf, Map* defBlk, Array* list, IRBlock* bb)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)list.get(i);
            if (n.res() == (IRValue*)0)
                continue;
            defOf.set((Hashable*)n.res(), (Object*)n);
            defBlk.set((Hashable*)n.res(), (Object*)bb);
            }
        }

    // Point the vector loop's guard at its new limit: the runtime M computed in
    // the preheader, or the folded constant. EXTRACTED for the arm64 frame
    // budget -- inline, vecApplyMap needed 16640 bytes against 16384.
    void vecMapSetBound(VecCand* c)
        {
        if (c.rtTrip())
            {
            _vecMapRtM = vecRuntimeLimit(c, c.pre());
            c.guard().ops().set((u32)1, (Object*)IROperand.useVal(_vecMapRtM));
            }
        else
            {
            _vecMapRtM = (IRValue*)0;
            c.guard().ops().set((u32)1, (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
            }
        }

    // A literal, or a RUNTIME bound; sets _vrMapRT to say which. Kept to ONE
    // call at the use site, and the locals kept in here, because vecMapAt is at
    // the arm64 frame ceiling: the same test written inline cost it 176 bytes.
    bool vecMapBound(IRInsn* guard, Map* defOf, i32* n)
        {
        _vrMapRT = false;
        if (vecConst((IROperand*)guard.ops().get((u32)1), defOf, n))
            return *n > (i32)0;
        if (((IROperand*)guard.ops().get((u32)1)).kind() != (u8)OPK_USE)
            return false;
        _vrMapRT = true;
        return true;
        }

    // Is a RUNTIME map bound usable? It needs a strict `<` -- with `i <= n` the
    // trip count is n+1 and the vector limit n & ~(vw-1) is simply wrong -- and
    // it must be loop-INVARIANT. A value with NO defining instruction is a
    // parameter, invariant by construction, so an absent defBlk entry must not
    // read as a refusal. EXTRACTED for the arm64 frame budget: inline, vecMapAt
    // needed 18080 bytes against a 16384 ceiling.
    bool vecMapRTOK(IRInsn* guard, Map* defBlk, IRBlock* H, IRBlock* B)
        {
        if (!guard.pred().equals(String.withCString("ULT")) && !guard.pred().equals(String.withCString("SLT")))
            return false;
        Object* bdb = defBlk.get((Hashable*)((IROperand*)guard.ops().get((u32)1)).val());
        if (bdb != (Object*)0 && ((IRBlock*)bdb == H || (IRBlock*)bdb == B))
            return false;
        return true;
        }

    VecCand* vecMapAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
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
        i32 n = (i32)0;
        if (!vecMapBound(guard, defOf, &n))
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
        if (stepOp == (IROperand*)0 || !vecConst(stepOp, defOf, &step) || step != (i32)1)
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

        String* laneTy = vecClassifyBody(B, iv, ivNext, defOf, defBlk);
        if (laneTy == (String*)0)
            return (VecCand*)0;
        u32 lw = irWidth(laneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vw = (u32)16 / lw;
        // A partial final vector would need a scalar tail, which this does not
        // emit — so the trip count has to divide evenly.
        // Trailing test: the non-zero-start refusal, folded in to avoid a
        // separate branch (see vecIvStartsAtZero).
        // A NON-ZERO start is refused (#1125), and refusing it is also what
        // stops the REMAINDER being re-recognised and re-cloned: the clone's
        // induction phi enters at M, so it fails this test by construction.
        i32 mapStart = vecIvStart(ivPhi, B, defOf);
        if (vw < (u32)2 || mapStart < (i32)0)
            return (VecCand*)0;
        if (!_vrMapRT && mapStart >= n)
            return (VecCand*)0;
        if (_vrMapRT && !vecMapRTOK(guard, defBlk, H, B))
            return (VecCand*)0;
        IRBlock* PH = vecEntryBlkOf(ivPhi, B);
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
        if (!_vrMapRT && (epiM - mapStart) < (i32)vw)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, guard, iv);
        c.setLane(laneTy, vw);
        c.setPre(PH);
        c.setEpi(_vrMapRT || epiM != n, epiM);
        c.setRuntime(_vrMapRT, (IROperand*)guard.ops().get((u32)1));
        c.setIvStart(mapStart);
        return c;
        }

    // `for (i=0; i<N; i++) acc += elem(a[i])` — the header carries the induction
    // phi AND a single associative-add accumulator, and the body stores nothing:
    // the reduce IS the output. Shares the induction/guard/latch shape with the
    // map recogniser; the extra structure is the accumulator.
    VecCand* vecRecogniseReduction(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        Map* uses = useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecReductionAt(fn, (IRBlock*)fn.blocks().get(hi),
                                        defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    // The shape shared with the map recogniser, plus the second phi. Results in
    // the _vr* ivars — split out because the arm64 backend budgets 16 KB of
    // frame per function.
    IRInsn* _vrIvPhi;
    IRInsn* _vrAccPhi;
    IRInsn* _vrGuard;
    IRValue* _vrIv;
    IRBlock* _vrB;
    IRBlock* _vrE;
    i32 _vrN;
    i32 _vrIvStart;        // the induction phi's constant start, -1 if not one
    bool _vrRuntime;       // the bound is a RUNTIME value, not a literal
    bool _vrMapRT;         // ... the same, for the MAP recogniser's own bound check
    u32 _magicM;           // magic multiplier from vecMagicU32
    u32 _magicS;           // and its post-shift
    // Constant divides in the body, keyed by the UDiv result, each holding
    // the magic the RECOGNISER derived. Recorded rather than recomputed in
    // the rewriter so the two cannot disagree: when they did, the rewriter
    // fell through to emitting a vector UDiv, which no back end lowers and
    // which silently returned a wrong sum.
    Map* _vrDivMagic;
    bool _vrAllowRT;       // one-shot: the NEXT vecReduxShape may accept one
    IROperand* _vrBoundOp; // that bound, when it is

    bool vecReduxShape(IRBlock* H, Map* defOf, Map* defBlk)
        {
        _vrIvPhi = (IRInsn*)0;
        _vrAccPhi = (IRInsn*)0;
        _vrGuard = (IRInsn*)0;
        _vrIv = (IRValue*)0;
        _vrB = (IRBlock*)0;
        _vrE = (IRBlock*)0;
        _vrN = (i32)0;
        _vrIvStart = (i32)-1;
        _vrRuntime = false;
        _vrMapRT = false;
        _vrBoundOp = (IROperand*)0;
        // _vrAllowRT is deliberately NOT reset here: it is the CALLER's one-shot
        // opt-in, set immediately before this call, and clearing it at the top
        // of the routine it gates would wipe it before the bound check reads it.
        // It is cleared below instead, on both paths.
        if (H.phis().count() != (u32)2)
            return false; // induction + accumulator
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != (IRValue*)0)
                return false;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = gl.val();

        // The guarded value is the induction phi; the other phi is the carry.
        IRInsn* ivPhi = (IRInsn*)0;
        IRInsn* accPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0)
                return false;
            if (p.res() == iv)
                ivPhi = p;
            else
                accPhi = p;
            }
        if (ivPhi == (IRInsn*)0 || accPhi == (IRInsn*)0)
            return false;
        // The bound may be a literal or a RUNTIME value, recorded rather than
        // decided here: this routine is shared by the reduction, widening-sum
        // and dot-product recognisers, and only the reduction opts in (via
        // _vrAllowRT). The predicate check and the invariance check are the
        // caller's, keeping this routine's frame cost at zero new locals.
        i32 n = (i32)0;
        _vrRuntime = false;
        _vrBoundOp = (IROperand*)guard.ops().get((u32)1);
        if (!vecConst(_vrBoundOp, defOf, &n))
            {
            if (!_vrAllowRT)
                {
                _vrAllowRT = false;
                return false;
                }
            _vrAllowRT = false;
            if (_vrBoundOp.kind() != (u8)OPK_USE)
                return false;
            _vrRuntime = true;
            }
        else
            {
            _vrAllowRT = false;
            if (n <= (i32)0)
                return false;
            }

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
            return false;
        if (E == (IRBlock*)0 || B.insns().count() == (u32)0)
            return false;
        // The horizontal reduce goes at the top of E. A phi there referencing the
        // accumulator on the H→E edge would have to be rewired to a value defined
        // LATER in E, which is not valid SSA — so an exit phi refuses.
        if (E.phis().count() != (u32)0)
            return false;
        if (ivPhi.ops().count() != (u32)4 || accPhi.ops().count() != (u32)4)
            return false;

        _vrIvPhi = ivPhi;
        _vrAccPhi = accPhi;
        _vrGuard = guard;
        _vrIv = iv;
        _vrB = B;
        _vrE = E;
        _vrN = n;
        // Computed ONCE here rather than called from each recogniser: the call's
        // operands and result each claim a frame slot, and vecWideningAt is
        // already within 80 bytes of the arm64 frame budget.
        _vrIvStart = vecIvStart(ivPhi, B, defOf);
        return true;
        }

    VecCand* vecReductionAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        _vrAllowRT = true; // reduction, widening-sum and dot all accept one
        if (!vecReduxShape(H, defOf, defBlk))
            return (VecCand*)0;
        IRInsn* ivPhi = _vrIvPhi;
        IRInsn* accPhi = _vrAccPhi;
        IRInsn* guard = _vrGuard;
        IRValue* iv = _vrIv;
        IRBlock* B = _vrB;
        IRBlock* E = _vrE;
        i32 n = _vrN;
        IRValue* acc = accPhi.res();
        IROperand* nextOp = vecBackOp(ivPhi, B);
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
        if (stepOp == (IROperand*)0 || !vecConst(stepOp, defOf, &step) || step != (i32)1)
            return (VecCand*)0;

        // accNext = Add(acc, elem), in the body and read exactly once.
        IROperand* accNextOp = vecBackOp(accPhi, B);
        if (accNextOp == (IROperand*)0 || accNextOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* ao = defOf.get((Hashable*)accNextOp.val());
        Object* ab = defBlk.get((Hashable*)accNextOp.val());
        if (ao == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return (VecCand*)0;
        IRInsn* accNext = (IRInsn*)ao;
        if (!accNext.op().equals(String.withCString("Add")))
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
        IROperand* initOp = vecEntryOpOf(accPhi, B);
        IRBlock* PH = vecEntryBlkOf(accPhi, B);
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
                                              defOf, defBlk);
        if (laneTy == (String*)0)
            return (VecCand*)0;
        // The accumulator's own width must match the loads — this is an i32/u32
        // add, not a widening one (that shape has its own recogniser).
        if (accNext.res() == (IRValue*)0 || !laneTy.equals(accNext.res().ty()))
            return (VecCand*)0;
        u32 lw = irWidth(laneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vw = (u32)16 / lw;
        // The trailing test is the non-zero-start refusal (see
        // vecIvStartsAtZero); folded into this condition rather than written as
        // its own statement, because a separate branch costs frame slots and
        // vecWideningAt sits 80 bytes from the arm64 budget.
        if (vw < (u32)2 || _vrIvStart < (i32)0)
            return (VecCand*)0;
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
            Object* bdb = defBlk.get((Hashable*)_vrBoundOp.val());
            if (bdb != (Object*)0 && ((IRBlock*)bdb == H || (IRBlock*)bdb == B))
                return (VecCand*)0;
            }
        i32 redTrip = n - _vrIvStart;
        i32 epiM = _vrIvStart + (redTrip - (redTrip % (i32)vw));
        if (!_vrRuntime && epiM != n && (epiM - _vrIvStart) < (i32)vw)
            return (VecCand*)0;
        // A NON-ZERO start is refused, and this is a BUG FIX (#1125), not
        // caution. The transform steps the EXISTING induction phi by the vector
        // width and keeps the guard, which is equivalent to the scalar loop only
        // when the counter begins at 0. Nothing checked, so
        //     for (i = 1; i < 64; i++) s += a[i];
        // passed on `64 % 4 == 0` with a real trip count of 63 and returned 1956
        // for a sum that is 2016, at -O2 and above, on every vectorising back
        // end. tests/fixtures/vectorize_const_tail.xc pins it.
        if (_vrIvStart < (i32)0)
            return (VecCand*)0;
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, guard, iv);
        c.setLane(laneTy, vw);
        c.setReduction(accPhi, accNext, acc, elemOp.val(), initOp, PH);
        c.setDivMagic(_vrDivMagic);
        c.setEpi(_vrRuntime || epiM != n, epiM);
        c.setRuntime(_vrRuntime, _vrBoundOp);
        c.setIvStart(_vrIvStart);
        return c;
        }

    // The phi value on the back edge from `B`.
    IROperand* vecBackOp(IRInsn* phi, IRBlock* B)
        {
        if (((IROperand*)phi.ops().get((u32)0)).blk() == B)
            return (IROperand*)phi.ops().get((u32)1);
        if (((IROperand*)phi.ops().get((u32)2)).blk() == B)
            return (IROperand*)phi.ops().get((u32)3);
        return (IROperand*)0;
        }

    // The value paired with the ENTRY (non-latch) block, and that block. The
    // operands are (block, value) pairs, so when B is the first pair the entry
    // value is the second one.
    // Does this induction phi provably start at ZERO on the loop's entry edge?
    // EVERY recogniser needs it (see XTIROptVectorize.m). The transforms step
    // the existing phi by the vector width and keep the guard, which reproduces
    // the scalar loop only from 0. A non-zero start miscompiled BOTH shapes:
    // a reduction returned 1956 instead of 2016, and a map WROTE b[0] and b[1]
    // for a loop starting at 2 — memory outside the range.
    // The induction variable's constant start, or -1 when it is not a
    // non-negative constant. A non-zero start is VECTORISED now rather than
    // refused: every epilogue here works from the trip LENGTH, so [start, n)
    // splits into whole vectors plus a scalar tail exactly as [0, n) does.
    //
    // Returning the value rather than a bool keeps the CALL SITES to one
    // expression each — #1126 found that adding a separate branch pushed
    // Opt$vecWideningAt 80 bytes past the 16 KB arm64 frame budget, and that
    // constraint has not gone away.
    i32 vecIvStart(IRInsn* ivPhi, IRBlock* latch, Map* defOf)
        {
        if (ivPhi == (IRInsn*)0 || ivPhi.ops().count() != (u32)4)
            return (i32)-1;
        IROperand* entry = ((IROperand*)ivPhi.ops().get((u32)0)).blk() == latch
                               ? (IROperand*)ivPhi.ops().get((u32)3)
                               : (IROperand*)ivPhi.ops().get((u32)1);
        if (entry == (IROperand*)0)
            return (i32)-1;
        i32 start = (i32)0;
        if (!vecConst(entry, defOf, &start))
            return (i32)-1;
        if (start < (i32)0)
            return (i32)-1;
        return start;
        }

    IROperand* vecEntryOpOf(IRInsn* phi, IRBlock* B)
        {
        return ((IROperand*)phi.ops().get((u32)0)).blk() == B
                   ? (IROperand*)phi.ops().get((u32)3)
                   : (IROperand*)phi.ops().get((u32)1);
        }

    IRBlock* vecEntryBlkOf(IRInsn* phi, IRBlock* B)
        {
        return ((IROperand*)phi.ops().get((u32)0)).blk() == B
                   ? ((IROperand*)phi.ops().get((u32)2)).blk()
                   : ((IROperand*)phi.ops().get((u32)0)).blk();
        }

    bool vecAccReadElsewhere(IRBlock* bb, IRInsn* accNext, IRValue* acc)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n == accNext)
                continue;
            if (insnUsesValue(n, acc))
                return true;
            }
        return false;
        }

    // The reduction body: the map's allowed set minus Store, plus the ivNext and
    // accNext handled separately. The lane is restricted to 32-bit integer —
    // a narrower one is the widening-sum shape, and float needs an associativity
    // the source language does not grant.
    // Unsigned magic-number division, the SIMPLE form only (Hacker's Delight
    // §10-9). Returns false unless x/d == mulhu(x, M) >>u s holds for every x,
    // which is the `a == 0` case; the other form needs an extra add and a shift
    // that cannot overflow, and there is no vector idiom for it here. d = 7 and
    // d = 14 are the small divisors that fall out — they stay scalar and
    // correct. Results land in _magicM / _magicS.
    //
    // The same computation lives in the arm64 back end, which is where the
    // SCALAR lowering gets its constants. Both must agree, or a loop would
    // compute one answer vectorised and another scalar.
    bool vecMagicU32(u32 d)
        {
        if (d < (u32)2)
            return false;
        u64 twoWm1 = (u64)$80000000;
        u64 maxu = (u64)$FFFFFFFF;
        u64 twoW = (u64)$100000000;
        u64 dd = (u64)d;
        bool addForm = false;
        u32 p = (u32)31;
        u64 nc = maxu - (twoW % dd);
        u64 q1 = twoWm1 / nc;
        u64 r1 = twoWm1 - q1 * nc;
        u64 q2 = (twoWm1 - (u64)1) / dd;
        u64 r2 = (twoWm1 - (u64)1) - q2 * dd;
        u64 delta = (u64)0;
        bool more = true;
        while (more)
            {
            p = p + (u32)1;
            if (r1 >= nc - r1) { q1 = (u64)2 * q1 + (u64)1; r1 = (u64)2 * r1 - nc; }
            else               { q1 = (u64)2 * q1;          r1 = (u64)2 * r1; }
            if (r2 + (u64)1 >= dd - r2)
                {
                if (q2 >= twoWm1 - (u64)1) addForm = true;
                q2 = (u64)2 * q2 + (u64)1;
                r2 = (u64)2 * r2 + (u64)1 - dd;
                }
            else
                {
                if (q2 >= twoWm1) addForm = true;
                q2 = (u64)2 * q2;
                r2 = (u64)2 * r2 + (u64)1;
                }
            delta = dd - (u64)1 - r2;
            more = p < (u32)64 && (q1 < delta || (q1 == delta && r1 == (u64)0));
            }
        if (addForm)
            return false;
        _magicM = (u32)((q2 + (u64)1) & maxu);
        _magicS = p - (u32)32;
        return true;
        }

    String* vecClassifyReduxBody(IRBlock* B, IRValue* iv, IRInsn* ivNext,
                                 IRInsn* accNext, IROperand* elemOp,
                                 Map* defOf, Map* defBlk)
        {
        String* laneTy = (String*)0;
        bool sawLoad = false;
        _vrDivMagic = new Map();
        Array* elems = new Array();
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
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (String*)0;
                if (!vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                String* lt = n.res().ty();
                if (!vecRedux32(lt))
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
                if (!vecOperandOK((IROperand*)n.ops().get((u32)0), elems, B, defOf, defBlk))
                    return (String*)0;
                i32 dv = (i32)0;
                if (!vecConst((IROperand*)n.ops().get((u32)1), defOf, &dv))
                    return (String*)0;
                if (dv <= (i32)1 || !vecMagicU32((u32)dv))
                    return (String*)0;
                Array* mg = new Array();
                mg.add((Object*)Number.with(_magicM));
                mg.add((Object*)Number.with(_magicS));
                _vrDivMagic.set((Hashable*)n.res(), (Object*)mg);
                elems.add((Object*)n.res());
                continue;
                }
            if (vecElementwise(op))
                {
                if (n.res() == (IRValue*)0 || !vecRedux32(n.res().ty()))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)0), elems, B, defOf, defBlk))
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)1), elems, B, defOf, defBlk))
                    return (String*)0;
                elems.add((Object*)n.res());
                continue;
                }
            return (String*)0; // a store, a call, a per-lane-varying scalar
            }
        if (!sawLoad || laneTy == (String*)0)
            return (String*)0;
        // The reduced element must itself be per-lane. A loop-invariant one
        // would be `acc += k` — a scaled count, not a lane-wise reduction.
        if (!hasValue(elems, elemOp.val()))
            return (String*)0;
        return laneTy;
        }

    bool vecRedux32(String* t)
        {
        return t != (String*)0 && (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")));
        }

    // Classify every body instruction, returning the consistent lane type or
    // null if anything disqualifies the loop. Allowed: AddrOf, ElementAddr at
    // the iv over a loop-invariant base, Load/Store through such an address,
    // elementwise arithmetic, and the scalar plumbing (Const and the width
    // casts). Anything else — a call, a shifted load, a value that varies per
    // lane — refuses.
    String* vecClassifyBody(IRBlock* B, IRValue* iv, IRInsn* ivNext,
                            Map* defOf, Map* defBlk)
        {
        String* laneTy = (String*)0;
        bool sawLoad = false;
        bool sawStore = false;
        // The elementwise set: results of iv-indexed loads and of elementwise
        // arithmetic over them. An operand must be in this set, or be a
        // loop-invariant scalar that is safe to broadcast — which is what
        // rejects `b[i] * i`, where the multiplier differs per lane.
        Array* elems = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == ivNext)
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
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (String*)0;
                if (!vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                String* lt = n.res().ty();
                if (!vecLaneOK(lt))
                    return (String*)0;
                if (laneTy != (String*)0 && !laneTy.equals(lt))
                    return (String*)0;
                laneTy = lt;
                sawLoad = true;
                elems.add((Object*)n.res());
                continue;
                }
            if (op.equals(String.withCString("Store")))
                {
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)1), elems, B, defOf, defBlk))
                    return (String*)0;
                sawStore = true;
                continue;
                }
            // Scalar plumbing, kept verbatim — constants and the widen/narrow
            // of the step or of an invariant operand.
            if (op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            if (vecElementwise(op))
                {
                if (n.res() == (IRValue*)0 || !vecLaneOK(n.res().ty()))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)0), elems, B, defOf, defBlk))
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)1), elems, B, defOf, defBlk))
                    return (String*)0;
                elems.add((Object*)n.res());
                continue;
                }
            return (String*)0;
            }
        if (!sawLoad || !sawStore)
            return (String*)0;
        return laneTy;
        }

    // Is this operand an ElementAddr indexed by the induction variable?
    bool vecIsElemAddr(IROperand* p, IRValue* iv, Map* defOf)
        {
        if (p.kind() != (u8)OPK_USE)
            return false;
        Object* o = defOf.get((Hashable*)p.val());
        if (o == (Object*)0)
            return false;
        IRInsn* ea = (IRInsn*)o;
        if (!ea.op().equals(String.withCString("ElementAddr")) || ea.ops().count() < (u32)2)
            return false;
        IROperand* idx = (IROperand*)ea.ops().get((u32)1);
        return idx.kind() == (u8)OPK_USE && idx.val() == iv;
        }

    // Usable in the elementwise computation: an already-elementwise value (one
    // vector lane each), or a loop-INVARIANT scalar — a constant, or something
    // defined outside the loop — which is the same in every lane and so safe to
    // broadcast.
    bool vecOperandOK(IROperand* o, Array* elems, IRBlock* B, Map* defOf, Map* defBlk)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return true;
        if (o.kind() != (u8)OPK_USE)
            return false;
        if (hasValue(elems, o.val()))
            return true;
        i32 k = (i32)0;
        if (vecConst(o, defOf, &k))
            return true;
        Object* db = defBlk.get((Hashable*)o.val());
        return db != (Object*)0 && (IRBlock*)db != B;
        }

    bool vecElementwise(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul"));
        }

    // The vector opcode for a scalar elementwise one. The float ops reuse
    // VAdd/VSub/VMul — the backend emits fadd/fsub/fmul when the result
    // vector's lane is floating.
    String* vecOpFor(String* op)
        {
        if (op.equals(String.withCString("Add")) || op.equals(String.withCString("FAdd")))
            return String.withCString("VAdd");
        if (op.equals(String.withCString("Sub")) || op.equals(String.withCString("FSub")))
            return String.withCString("VSub");
        if (op.equals(String.withCString("Mul")) || op.equals(String.withCString("FMul")))
            return String.withCString("VMul");
        if (op.equals(String.withCString("And")))
            return String.withCString("VAnd");
        if (op.equals(String.withCString("Or")))
            return String.withCString("VOr");
        if (op.equals(String.withCString("Xor")))
            return String.withCString("VXor");
        return op;
        }

    // Lane types the map vectoriser handles: 8/16/32-bit integer (same-width
    // wrapping arithmetic) or 32-bit float. Float REDUCTIONS need an
    // associativity the source language does not grant, so they are not here.
    bool vecLaneOK(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")) || t.equals(String.withCString("F32"));
        }

    // A compile-time integer through Const and the width casts.
    bool vecConst(IROperand* op, Map* defOf, i32* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* a = (IROperand*)def.ops().get((u32)0);
            if (def.op().equals(String.withCString("Const")))
                {
                if (a.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = a.imm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
                return false;
            if (a.kind() == (u8)OPK_IMMI)
                {
                out[0] = a.imm();
                return true;
                }
            if (a.kind() != (u8)OPK_USE)
                return false;
            cur = a.val();
            }
        return false;
        }

    // The vectorised body: loads become VLoad, stores VStore, elementwise
    // arithmetic its vector opcode, and the induction variable steps by the
    // vector width instead of one.
    Map* _vecMap;   // scalar value → its vector value
    Map* _vecSplat; // scalar value → the in-body broadcast of it
    IRBlock* _vecSplatPH;  // preheader for loop-INVARIANT splats, or 0
    Map* _vecSplatK;       // constant → its preheader broadcast
    Map* _vecSplatDefs;    // value → defining insn, to spot a Const
    String* _vecSplatTy;   // the lane type a hoisted Const takes
    // Epilogue state, set by vecApplyReduction and read by vecReduxExit: the
    // cloned remainder loop, the original->clone value map, and the preheader
    // whose phi edge the clone still names.
    IRBlock* _vecH2;
    IRBlock* _vecB2;
    Map* _vecCmap;
    IRValue* _vecRtM;    // the runtime vector limit M, when the trip is runtime
    IRValue* _vecMapRtM; // ... the same, for the map applier
    IRBlock* _vecPH;
    Map* _vecEntryCache; // key → a broadcast hoisted to the entry block
    Array* _vecBody;     // the body being built
    String* _vecTy;      // Vec(lane)

    void vecApplyMap(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        // Epilogue part 1: clone the scalar loop BEFORE the body below is
        // rewritten in place. The remainder has to be taken now or not at all.
        IRBlock* mH2 = (IRBlock*)0;
        IRBlock* mB2 = (IRBlock*)0;
        Map* mcmap = new Map();
        if (c.needEpi())
            {
            Array* cl = vecCloneLoop(c.h(), B, mcmap);
            mH2 = (IRBlock*)cl.get((u32)0);
            mB2 = (IRBlock*)cl.get((u32)1);
            // The vector loop now stops at the last whole vector; the clone's
            // own (cloned) guard still tests the original bound.
            vecMapSetBound(c);
            }
        _vecTy = new String();
        _vecTy.appendFormat("Vec(%s)", c.laneTy().cString());
        _vecMap = new Map();
        _vecSplat = new Map();
        _vecEntryCache = new Map();
        _vecBody = new Array();

        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
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
                IRValue* vr = new IRValue(_vecTy);
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
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
                IROperand* vval = vecOperandFor((IROperand*)n.ops().get((u32)1),
                                                fn, entry, B, c, defOf, defBlk);
                IRInsn* vs = IRInsn.with(String.withCString("VStore"));
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vs.add(k == (u32)1 ? vval : (IROperand*)n.ops().get(k));
                vs.setMemRes(n.memRes());
                _vecBody.add((Object*)vs);
                continue;
                }
            // Elementwise arithmetic.
            IROperand* va = vecOperandFor((IROperand*)n.ops().get((u32)0),
                                          fn, entry, B, c, defOf, defBlk);
            IROperand* vb = vecOperandFor((IROperand*)n.ops().get((u32)1),
                                          fn, entry, B, c, defOf, defBlk);
            IRValue* vr = new IRValue(_vecTy);
            IRInsn* vop = IRInsn.with(vecOpFor(op));
            vop.setRes(vr);
            vop.add(va);
            vop.add(vb);
            _vecBody.add((Object*)vop);
            _vecMap.set((Hashable*)n.res(), (Object*)vr);
            }
        B.setInsns(_vecBody);
        if (c.needEpi())
            vecMapEpilogue(fn, c, mH2, mB2, mcmap);
        }

    // Epilogue part 2 for a MAP: the vector loop falls into the remainder
    // through a LANDING PAD that does nothing but branch.
    //
    // The empty block is load-bearing. Sending the vector loop straight to H2
    // looks right — a map carries nothing out but the induction variable, which
    // enters as the constant M — and it works until loop rotation gives the
    // vector loop its SECOND exit (the body's own back-edge test). That edge
    // then lands on a phi-carrying header with no incoming for it, so the iv is
    // undefined on entry and the remainder is skipped:
    //     for (i = 0; i < 5; i++) b[i] = a[i] * 3;
    // wrote four elements and left the fifth untouched. One pred keeps H2's
    // phis well-formed however the loop is later reshaped. The reduction
    // epilogue gets this for free — its VE is where the reduce lands.
    // Pinned by tests/fixtures/vectorize_map_tail.xc.
    void vecMapEpilogue(IRFunc* fn, VecCand* c, IRBlock* H2, IRBlock* B2, Map* cmap)
        {
        IRBlock* H = c.h();
        IRBlock* E2 = c.e();
        IRBlock* PH = c.pre();
        IRBlock* VE = new IRBlock(hoistName2(H.name(), "_vexit"));
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H2));
        VE.setTerm(br);

        // The vector loop exits to VE instead of E.
        IRInsn* t = H.term();
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == E2)
                t.ops().set(k, (Object*)IROperand.block(VE));
            }

        // Seed the clone: its iv enters at M, on the edge from VE — which is
        // where the clone's phis still name the ORIGINAL preheader.
        Object* ivC = cmap.get((Hashable*)c.ivPhi().res());
        for (u32 k = (u32)0; k < H2.phis().count(); k = k + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H2.phis().get(k);
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(q);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != PH)
                    continue;
                phi.ops().set(q, (Object*)IROperand.block(VE));
                if (ivC != (Object*)0 && phi.res() == (IRValue*)ivC)
                    phi.ops().set(q + (u32)1, c.rtTrip()
                                                  ? (Object*)IROperand.useVal(_vecMapRtM)
                                                  : (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
                }
            }

        u32 at = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            if ((IRBlock*)fn.blocks().get(k) == c.b())
                at = k + (u32)1;
        Array* three = new Array();
        three.add((Object*)VE);
        three.add((Object*)H2);
        three.add((Object*)B2);
        fn.blocks().insertAll(at, three);
        }

    // `acc:u32 += (u32)a[i]` over a u8/u16 array cannot accumulate in narrow
    // lanes — the sum overflows a byte — so the narrow load is vector-loaded,
    // its lanes folded up to u32 by pairwise widening, accumulated in a 4×u32
    // vector and reduced at the exit. Sound because addition mod 2^32 is
    // associative and commutative, so the regrouping matches the scalar
    // wraparound sum exactly.
    VecCand* vecRecogniseWideningSum(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        Map* uses = useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecWideningAt(fn, (IRBlock*)fn.blocks().get(hi),
                                       defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    // EXTRACTED for the arm64 frame budget, like vecReduxEpilogue and
    // vecWidenEpiSetup before it: vecWideningAt sits AT the 16 KB ceiling, so
    // its body validation lives in its own frame. Pure checks -- the body must
    // be EXACTLY address / narrow load / widen / the two adds / constants
    // (anything else and the rewrite would drop work), the accumulator must not
    // be read elsewhere, and the induction variable must not escape the loop.
    bool vecWideningBodyOK(IRFunc* fn, IRBlock* H, IRBlock* B, IRValue* iv,
                           IRValue* acc, IRInsn* accNext, IRInsn* ivNext,
                           IRInsn* zx, IRInsn* load)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* nn = (IRInsn*)B.insns().get(i);
            if (nn == accNext || nn == ivNext || nn == zx || nn == load)
                continue;
            String* op = nn.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            return false;
            }
        if (vecAccReadElsewhere(H, accNext, acc))
            return false;
        if (vecAccReadElsewhere(B, accNext, acc))
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return false;
            }
        return true;
        }

    VecCand* vecWideningAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        _vrAllowRT = true; // widening-sum / dot accept one too (see vecReduxShape)
        if (!vecReduxShape(H, defOf, defBlk))
            return (VecCand*)0;
        IRInsn* ivPhi = _vrIvPhi;
        IRInsn* accPhi = _vrAccPhi;
        IRBlock* B = _vrB;
        IRBlock* E = _vrE;
        IRValue* iv = _vrIv;
        i32 n = _vrN;
        IRValue* acc = accPhi.res();
        // The accumulator is unsigned 32-bit — that is what makes the widening
        // regrouping sound.
        if (!acc.ty().equals(String.withCString("U32")))
            return (VecCand*)0;

        IROperand* accBack = vecBackOp(accPhi, B);
        if (accBack == (IROperand*)0 || accBack.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* ao = defOf.get((Hashable*)accBack.val());
        Object* ab = defBlk.get((Hashable*)accBack.val());
        if (ao == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return (VecCand*)0;
        IRInsn* accNext = (IRInsn*)ao;
        if (!accNext.op().equals(String.withCString("Add")) || countOf(uses, accBack.val()) != (u32)1 || accNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* x0 = (IROperand*)accNext.ops().get((u32)0);
        IROperand* x1 = (IROperand*)accNext.ops().get((u32)1);
        IROperand* elemOp = (IROperand*)0;
        if (x0.kind() == (u8)OPK_USE && x0.val() == acc)
            elemOp = x1;
        else if (x1.kind() == (u8)OPK_USE && x1.val() == acc)
            elemOp = x0;
        if (elemOp == (IROperand*)0 || elemOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;

        // The element is ZExt(load) — an unsigned widening of a narrow,
        // iv-indexed load that feeds nothing else.
        Object* zo = defOf.get((Hashable*)elemOp.val());
        Object* zb = defBlk.get((Hashable*)elemOp.val());
        if (zo == (Object*)0 || zb == (Object*)0 || (IRBlock*)zb != B)
            return (VecCand*)0;
        IRInsn* zx = (IRInsn*)zo;
        if (!zx.op().equals(String.withCString("ZExt")) || zx.ops().count() < (u32)1)
            return (VecCand*)0;
        IROperand* zs = (IROperand*)zx.ops().get((u32)0);
        if (zs.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* lo = defOf.get((Hashable*)zs.val());
        Object* lb = defBlk.get((Hashable*)zs.val());
        if (lo == (Object*)0 || lb == (Object*)0 || (IRBlock*)lb != B)
            return (VecCand*)0;
        IRInsn* load = (IRInsn*)lo;
        if (!load.op().equals(String.withCString("Load")) || load.res() == (IRValue*)0 || load.ops().count() < (u32)1)
            return (VecCand*)0;
        String* lt = load.res().ty();
        if (lt == (String*)0 || (!lt.equals(String.withCString("U8")) && !lt.equals(String.withCString("U16"))))
            return (VecCand*)0;
        if (!vecIsElemAddr((IROperand*)load.ops().get((u32)0), iv, defOf))
            return (VecCand*)0;
        if (countOf(uses, elemOp.val()) != (u32)1 || countOf(uses, load.res()) != (u32)1)
            return (VecCand*)0;

        IRInsn* ivNext = vecFindStep(B, iv, accNext, defOf);
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = vecBackOp(ivPhi, B);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        if (!vecWideningBodyOK(fn, H, B, iv, acc, accNext, ivNext, zx, load))
            return (VecCand*)0;

        u32 lw = irWidth(lt);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vw = (u32)16 / lw; // 16 per iteration for u8, 8 for u16
        // The trailing test is the non-zero-start refusal (see
        // vecIvStartsAtZero); folded into this condition rather than written as
        // its own statement, because a separate branch costs frame slots and
        // vecWideningAt sits 80 bytes from the arm64 budget.
        // The trip no longer has to be a whole number of vectors -- a CLONE
        // finishes the tail -- but fewer than ONE full vector still has nothing
        // to gain. That test is just `n < vw`: writing n = q*vw + r, the last
        // whole boundary n - r is q*vw, which is >= vw exactly when q >= 1. So
        // no subtraction and no second modulo, which matters because this
        // function sits ~80 bytes from the arm64 frame ceiling. The bound is
        // carried on the candidate for vecSetEpi to use.
        if (vw < (u32)2 || _vrIvStart < (i32)0)
            return (VecCand*)0;
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;
        // Fewer than one whole vector: stay scalar. The test is on the trip
        // LENGTH `n - ivStart`, not the bound — gating on `n` accepted the
        // epilogue CLONE (iv enters at M, so its length is under a vector by
        // construction) and re-vectorised it into an EMPTY vector loop plus a
        // fresh clone, again every pipeline iteration. That runaway was the
        // vectorize_widen_tail opt-diff divergence: the reference refuses on
        // length and const-unrolls the tail instead.
        if (!_vrRuntime && n - _vrIvStart < (i32)vw)
            return (VecCand*)0;
        // A runtime bound needs a strict `<` and must be loop-INVARIANT.
        if (_vrRuntime && !vecMapRTOK(_vrGuard, defBlk, H, B))
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, _vrGuard, iv);
        c.setLane(String.withCString("U32"), vw);
        c.setReduction(accPhi, accNext, acc, elemOp.val(),
                       vecEntryOpOf(accPhi, B), vecEntryBlkOf(accPhi, B));
        c.setWidening(lt, load.res(), (IRValue*)0, false);
        c.setRuntime(_vrRuntime, _vrBoundOp);
        c.setIvStart(_vrIvStart);
        return c;
        }

    // Dot product: `acc += (u32)(a[i]*b[i])` over two u16 arrays. Same shape as
    // the widening sum, but the accumulated element is a product of two
    // iv-indexed narrow loads, multiplied in the NARROW lane so it wraps exactly
    // like the scalar u16*u16 it replaces. Shares the widening lowering with a
    // VMul inserted in front.
    VecCand* vecRecogniseDotProduct(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        Map* uses = useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecDotAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    VecCand* vecDotAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        _vrAllowRT = true; // widening-sum / dot accept one too (see vecReduxShape)
        if (!vecReduxShape(H, defOf, defBlk))
            return (VecCand*)0;
        IRInsn* ivPhi = _vrIvPhi;
        IRInsn* accPhi = _vrAccPhi;
        IRBlock* B = _vrB;
        IRBlock* E = _vrE;
        IRValue* iv = _vrIv;
        i32 n = _vrN;
        IRValue* acc = accPhi.res();
        if (!vecRedux32(acc.ty()))
            return (VecCand*)0;

        IROperand* accBack = vecBackOp(accPhi, B);
        if (accBack == (IROperand*)0 || accBack.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* ao = defOf.get((Hashable*)accBack.val());
        Object* ab = defBlk.get((Hashable*)accBack.val());
        if (ao == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return (VecCand*)0;
        IRInsn* accNext = (IRInsn*)ao;
        if (!accNext.op().equals(String.withCString("Add")) || countOf(uses, accBack.val()) != (u32)1 || accNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* x0 = (IROperand*)accNext.ops().get((u32)0);
        IROperand* x1 = (IROperand*)accNext.ops().get((u32)1);
        IROperand* elemOp = (IROperand*)0;
        if (x0.kind() == (u8)OPK_USE && x0.val() == acc)
            elemOp = x1;
        else if (x1.kind() == (u8)OPK_USE && x1.val() == acc)
            elemOp = x0;
        if (elemOp == (IROperand*)0 || elemOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;

        // elem = ZExt(prod), prod = Mul(loadA, loadB) in the narrow lane.
        Object* zo = defOf.get((Hashable*)elemOp.val());
        Object* zb = defBlk.get((Hashable*)elemOp.val());
        if (zo == (Object*)0 || zb == (Object*)0 || (IRBlock*)zb != B)
            return (VecCand*)0;
        IRInsn* zx = (IRInsn*)zo;
        if (!zx.op().equals(String.withCString("ZExt")) || zx.ops().count() < (u32)1)
            return (VecCand*)0;
        if (countOf(uses, elemOp.val()) != (u32)1)
            return (VecCand*)0;
        IROperand* zs = (IROperand*)zx.ops().get((u32)0);
        if (zs.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* mo = defOf.get((Hashable*)zs.val());
        Object* mb = defBlk.get((Hashable*)zs.val());
        if (mo == (Object*)0 || mb == (Object*)0 || (IRBlock*)mb != B)
            return (VecCand*)0;
        IRInsn* mul = (IRInsn*)mo;
        if (!mul.op().equals(String.withCString("Mul")) || countOf(uses, zs.val()) != (u32)1 || mul.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* m0 = (IROperand*)mul.ops().get((u32)0);
        IROperand* m1 = (IROperand*)mul.ops().get((u32)1);
        if (m0.kind() != (u8)OPK_USE || m1.kind() != (u8)OPK_USE)
            return (VecCand*)0;

        IRInsn* loadA = vecDotLoad(m0.val(), iv, B, defOf, defBlk, uses);
        IRInsn* loadB = vecDotLoad(m1.val(), iv, B, defOf, defBlk, uses);
        if (loadA == (IRInsn*)0 || loadB == (IRInsn*)0 || loadA == loadB)
            return (VecCand*)0;
        String* lt = loadA.res().ty();
        if (!lt.equals(loadB.res().ty()))
            return (VecCand*)0;

        IRInsn* ivNext = vecFindStep(B, iv, accNext, defOf);
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = vecBackOp(ivPhi, B);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        Array* known = new Array();
        known.add((Object*)accNext);
        known.add((Object*)ivNext);
        known.add((Object*)zx);
        known.add((Object*)mul);
        known.add((Object*)loadA);
        known.add((Object*)loadB);
        if (!vecDotBodyClean(fn, H, B, known, acc, accNext, iv))
            return (VecCand*)0;

        u32 lw = irWidth(lt);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vw = (u32)16 / lw;
        // The trailing test is the non-zero-start refusal (see
        // vecIvStartsAtZero); folded into this condition rather than written as
        // its own statement, because a separate branch costs frame slots and
        // vecWideningAt sits 80 bytes from the arm64 budget.
        // See vecWideningAt: `n < vw` is the fewer-than-one-vector refusal.
        if (vw < (u32)2 || _vrIvStart < (i32)0)
            return (VecCand*)0;
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;
        // Fewer than one whole vector: stay scalar. On the trip LENGTH, not
        // the bound — see vecWideningAt for why gating on `n` re-vectorised
        // the epilogue clone into an empty vector loop, forever.
        if (!_vrRuntime && n - _vrIvStart < (i32)vw)
            return (VecCand*)0;
        // A runtime bound needs a strict `<` and must be loop-INVARIANT.
        if (_vrRuntime && !vecMapRTOK(_vrGuard, defBlk, H, B))
            return (VecCand*)0;
        IRBlock* PH = vecHeaderPred(fn, H, B);
        if (PH == (IRBlock*)0)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, _vrGuard, iv);
        c.setLane(String.withCString("U32"), vw);
        c.setReduction(accPhi, accNext, acc, elemOp.val(),
                       vecEntryOpOf(accPhi, B), PH);
        c.setWidening(lt, loadA.res(), loadB.res(), true);
        c.setRuntime(_vrRuntime, _vrBoundOp);
        c.setIvStart(_vrIvStart);
        return c;
        }

    // The body is exactly the recognised shape — two addresses, two loads, the
    // multiply, the widen, the two adds and constants — the accumulator is read
    // only by its own add, and the induction variable does not escape.
    bool vecDotBodyClean(IRFunc* fn, IRBlock* H, IRBlock* B, Array* known,
                         IRValue* acc, IRInsn* accNext, IRValue* iv)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* nn = (IRInsn*)B.insns().get(i);
            if (hasInsn(known, nn))
                continue;
            String* op = nn.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            return false;
            }
        if (vecAccReadElsewhere(H, accNext, acc))
            return false;
        if (vecAccReadElsewhere(B, accNext, acc))
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return false;
            }
        return true;
        }

    // The header's predecessor that is not the latch.
    IRBlock* vecHeaderPred(IRFunc* fn, IRBlock* H, IRBlock* B)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == B || bb.term() == (IRInsn*)0)
                continue;
            for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)bb.term().ops().get(k);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == H)
                    return bb;
                }
            }
        return (IRBlock*)0;
        }

    // An iv-indexed narrow load feeding only the multiply. The lane must be u16
    // — VMul has no 8-bit-lane form.
    IRInsn* vecDotLoad(IRValue* v, IRValue* iv, IRBlock* B,
                       Map* defOf, Map* defBlk, Map* uses)
        {
        Object* o = defOf.get((Hashable*)v);
        Object* b = defBlk.get((Hashable*)v);
        if (o == (Object*)0 || b == (Object*)0 || (IRBlock*)b != B)
            return (IRInsn*)0;
        IRInsn* ld = (IRInsn*)o;
        if (!ld.op().equals(String.withCString("Load")) || ld.res() == (IRValue*)0 || countOf(uses, v) != (u32)1 || ld.ops().count() < (u32)1)
            return (IRInsn*)0;
        if (ld.res().ty() == (String*)0 || !ld.res().ty().equals(String.withCString("U16")))
            return (IRInsn*)0;
        if (!vecIsElemAddr((IROperand*)ld.ops().get((u32)0), iv, defOf))
            return (IRInsn*)0;
        return ld;
        }

    // `ivNext = Add(iv, 1)` in the body, skipping the accumulator's own add.
    IRInsn* vecFindStep(IRBlock* B, IRValue* iv, IRInsn* accNext, Map* defOf)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == accNext)
                continue;
            if (!n.op().equals(String.withCString("Add")) || n.res() == (IRValue*)0)
                continue;
            if (n.ops().count() < (u32)2)
                continue;
            IROperand* a0 = (IROperand*)n.ops().get((u32)0);
            IROperand* a1 = (IROperand*)n.ops().get((u32)1);
            IROperand* so = (IROperand*)0;
            if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
                so = a1;
            else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
                so = a0;
            i32 one = (i32)0;
            if (so != (IROperand*)0 && vecConst(so, defOf, &one) && one == (i32)1)
                return n;
            }
        return (IRInsn*)0;
        }

    // `for (i<N) if (a[i] > m) m = a[i]` lowers to a diamond the if-converter
    // cannot linearise — the then-arm reloads a[i], and it will not speculate a
    // load. So the diamond is recognised directly and replaced with a vector
    // max/min accumulate plus a horizontal reduce.
    VecCand* vecRecogniseCount(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        Map* uses = useCounts(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecCountAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    VecCand* vecRecogniseMaxMin(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VecCand* c = vecMaxMinAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk);
            if (c != (VecCand*)0)
                return c;
            }
        return (VecCand*)0;
        }

    // The diamond's blocks and phis, found from the header.
    IRInsn* _mmIvPhi;
    IRInsn* _mmAccPhi;
    IRInsn* _mmGuard;
    IRInsn* _mmJoinPhi;
    IRValue* _mmIv;
    IRBlock* _mmB;
    IRBlock* _mmE;
    IRBlock* _mmTH;
    IRBlock* _mmL;
    IRBlock* _mmPH;
    i32 _mmN;

    bool vecMaxMinShape(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        _mmIvPhi = (IRInsn*)0;
        _mmAccPhi = (IRInsn*)0;
        _mmGuard = (IRInsn*)0;
        _mmJoinPhi = (IRInsn*)0;
        _mmIv = (IRValue*)0;
        _mmB = (IRBlock*)0;
        _mmE = (IRBlock*)0;
        _mmTH = (IRBlock*)0;
        _mmL = (IRBlock*)0;
        _mmPH = (IRBlock*)0;
        _mmN = (i32)0;

        if (H.phis().count() != (u32)2)
            return false;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != (IRValue*)0)
                return false;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = gl.val();

        IRInsn* ivPhi = (IRInsn*)0;
        IRInsn* accPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            if (p.res() == iv)
                ivPhi = p;
            else
                accPhi = p;
            }
        if (ivPhi == (IRInsn*)0 || accPhi == (IRInsn*)0)
            return false;
        i32 n = (i32)0;
        if (!vecConst((IROperand*)guard.ops().get((u32)1), defOf, &n) || n <= (i32)0)
            return false;

        // Both the preheader and the latch branch to the header, so they are
        // told apart by BLOCK ORDER: the back-edge source follows the header,
        // the preheader precedes it. Both phis must agree on the same latch.
        u32 idxH = blockIndex(fn, H);
        IRBlock* L = vecIncoming(fn, accPhi, idxH, true);
        IRBlock* PH = vecIncoming(fn, accPhi, idxH, false);
        if (L == (IRBlock*)0 || PH == (IRBlock*)0 || L == H || L == PH)
            return false;
        if (vecIncoming(fn, ivPhi, idxH, true) != L)
            return false;
        if (L.term() == (IRInsn*)0 || !L.term().op().equals(String.withCString("Branch")) || L.term().ops().count() < (u32)1 || ((IROperand*)L.term().ops().get((u32)0)).blk() != H)
            return false;

        // The join holds the accumulator's merge phi, the iv step and the branch.
        if (L.phis().count() != (u32)1)
            return false;
        IRInsn* joinPhi = (IRInsn*)L.phis().get((u32)0);
        if (joinPhi.res() == (IRValue*)0 || joinPhi.ops().count() != (u32)4)
            return false;
        IROperand* accBack = vecBackOp(accPhi, L);
        if (accBack == (IROperand*)0 || accBack.kind() != (u8)OPK_USE || accBack.val() != joinPhi.res())
            return false;

        // The diamond head is the guard target that feeds the join; the other
        // target exits.
        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* jb0 = ((IROperand*)joinPhi.ops().get((u32)0)).blk();
        IRBlock* jb1 = ((IROperand*)joinPhi.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (t0 == jb0 || t0 == jb1)
            {
            B = t0;
            E = t1;
            }
        else if (t1 == jb0 || t1 == jb1)
            {
            B = t1;
            E = t0;
            }
        else
            return false;
        IRBlock* TH = (jb0 == B) ? jb1 : jb0;
        if (B == (IRBlock*)0 || E == (IRBlock*)0 || TH == (IRBlock*)0 || B == TH)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;

        _mmIvPhi = ivPhi;
        _mmAccPhi = accPhi;
        _mmGuard = guard;
        _mmJoinPhi = joinPhi;
        _mmIv = iv;
        _mmB = B;
        _mmE = E;
        _mmTH = TH;
        _mmL = L;
        _mmPH = PH;
        _mmN = n;
        return true;
        }

    // The phi's incoming block on the latch side (or the preheader side). The
    // back-edge source is the one that FOLLOWS the header in block order.
    IRBlock* vecIncoming(IRFunc* fn, IRInsn* phi, u32 idxH, bool wantLatch)
        {
        IRBlock* b0 = ((IROperand*)phi.ops().get((u32)0)).blk();
        IRBlock* b1 = ((IROperand*)phi.ops().get((u32)2)).blk();
        if (b0 == (IRBlock*)0 || b1 == (IRBlock*)0)
            return (IRBlock*)0;
        if (!hasBlock(fn.blocks(), b0) || !hasBlock(fn.blocks(), b1))
            return (IRBlock*)0;
        bool b0latch = blockIndex(fn, b0) > idxH;
        if (wantLatch)
            return b0latch ? b0 : b1;
        return b0latch ? b1 : b0;
        }

    // ── Count reduction ──────────────────────────────────────────────────
    //
    // `for (i<N) if (a[i] <cmp> k) n += delta` arrives if-converted to a Select,
    // so the body is a single block and the accumulator's back-edge value is
    // Select(cmp, Add(acc, delta), acc). Ported to close a real parity gap: the
    // original has SIX recognisers and this port had five, and no differential
    // could see it, because not one file in the tree has this loop shape (#1131).
    //
    // Split into helpers from the outset rather than after the fact: every
    // recogniser here sits within a few hundred bytes of the 16 KB arm64 frame
    // ceiling, and six functions had to be carved up today to get back under it.

    i32 vecBlockIndex(IRFunc* fn, IRBlock* b)
        {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b)
                return (i32)i;
        return (i32)-1;
        }

    // The latch is the header predecessor that comes AFTER the header in block
    // order; the preheader is the other one.
    IRBlock* vecCountEdge(IRFunc* fn, IRInsn* phi, IRBlock* H, bool wantLatch)
        {
        if (phi.ops().count() < (u32)4)
            return (IRBlock*)0;
        IRBlock* b0 = ((IROperand*)phi.ops().get((u32)0)).blk();
        IRBlock* b1 = ((IROperand*)phi.ops().get((u32)2)).blk();
        i32 i0 = vecBlockIndex(fn, b0);
        i32 i1 = vecBlockIndex(fn, b1);
        if (i0 < (i32)0 || i1 < (i32)0)
            return (IRBlock*)0;
        bool b0latch = i0 > vecBlockIndex(fn, H);
        if (wantLatch)
            return b0latch ? b0 : b1;
        return b0latch ? b1 : b0;
        }

    // The guard target that leads into the loop: the latch itself when the body
    // is merged, otherwise a single-successor block branching to it.
    bool vecCountLeadsTo(IRBlock* b, IRBlock* L, IRBlock* H)
        {
        if (b == L)
            return true;
        if (b == (IRBlock*)0 || b == H)
            return false;
        if (b.phis().count() != (u32)0)
            return false;
        if (b.term() == (IRInsn*)0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        if (b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == L;
        }

    // The accumulator's back edge must be Select(cmp, Add(acc, delta), acc):
    // the compare selects between incrementing and keeping the count, which is
    // what an if-converted `if (...) n += delta` becomes. The delta has to be
    // loop-invariant, and the Select single-use — anything else reading it would
    // see the scalar count this rewrite is about to replace.
    IRInsn* _vcAccNext;
    IRInsn* _vcIncr;
    IRInsn* _vcCmp;
    IROperand* _vcDelta;

    bool vecCountAcc(IRInsn* accPhi, IRValue* acc, IRBlock* B, IRBlock* L,
                     Map* defOf, Map* defBlk, Map* uses)
        {
        IROperand* accBack = ((IROperand*)accPhi.ops().get((u32)0)).blk() == L
                                 ? (IROperand*)accPhi.ops().get((u32)1)
                                 : (IROperand*)accPhi.ops().get((u32)3);
        if (accBack.kind() != (u8)OPK_USE)
            return false;
        Object* an = defOf.get((Hashable*)accBack.val());
        Object* ab = defBlk.get((Hashable*)accBack.val());
        if (an == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return false;
        IRInsn* accNext = (IRInsn*)an;
        if (!accNext.op().equals(String.withCString("Select")) || accNext.ops().count() < (u32)3)
            return false;
        if (countOf(uses, accBack.val()) != (u32)1)
            return false;

        IROperand* condOp = (IROperand*)accNext.ops().get((u32)0);
        IROperand* tOp = (IROperand*)accNext.ops().get((u32)1);
        IROperand* fOp = (IROperand*)accNext.ops().get((u32)2);
        if (condOp.kind() != (u8)OPK_USE || tOp.kind() != (u8)OPK_USE || fOp.kind() != (u8)OPK_USE)
            return false;
        if (fOp.val() != acc)
            return false; // the unselected arm keeps acc

        Object* io = defOf.get((Hashable*)tOp.val());
        Object* ib = defBlk.get((Hashable*)tOp.val());
        if (io == (Object*)0 || ib == (Object*)0 || (IRBlock*)ib != B)
            return false;
        IRInsn* incr = (IRInsn*)io;
        if (!incr.op().equals(String.withCString("Add")) || incr.ops().count() < (u32)2)
            return false;
        IROperand* x0 = (IROperand*)incr.ops().get((u32)0);
        IROperand* x1 = (IROperand*)incr.ops().get((u32)1);
        IROperand* d = (IROperand*)0;
        if (x0.kind() == (u8)OPK_USE && x0.val() == acc)
            d = x1;
        else if (x1.kind() == (u8)OPK_USE && x1.val() == acc)
            d = x0;
        if (d == (IROperand*)0)
            return false;
        i32 dk = (i32)0;
        if (!vecConst(d, defOf, &dk))
            return false; // invariant increment

        Object* co = defOf.get((Hashable*)condOp.val());
        Object* cb = defBlk.get((Hashable*)condOp.val());
        if (co == (Object*)0 || cb == (Object*)0 || (IRBlock*)cb != B)
            return false;
        IRInsn* cmp = (IRInsn*)co;
        if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() < (u32)2)
            return false;

        _vcAccNext = accNext;
        _vcIncr = incr;
        _vcCmp = cmp;
        _vcDelta = d;
        return true;
        }

    String* _vcLaneTy;
    IRValue* _vcElem;

    // Is this operand usable as an elementwise input: a literal, a value already
    // classified elementwise, a constant, or something defined OUTSIDE the loop
    // (hence invariant)? Anything else varies per lane in a way the rewrite
    // cannot reproduce.
    bool vecCountOperandOK(IROperand* o, Array* elemIds, Map* defOf, Map* defBlk,
                           IRBlock* H, IRBlock* B, IRBlock* L)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return true;
        if (o.kind() != (u8)OPK_USE)
            return false;
        if (hasValue(elemIds, o.val()))
            return true;
        i32 k = (i32)0;
        if (vecConst(o, defOf, &k))
            return true;
        Object* db = defBlk.get((Hashable*)o.val());
        if (db == (Object*)0)
            return false;
        return (IRBlock*)db != B && (IRBlock*)db != L && (IRBlock*)db != H;
        }

    // The body must be exactly the elementwise computation feeding the compare,
    // plus the count plumbing (compare, increment, Select, iv step) which is
    // skipped. Sets _vcLaneTy and _vcElem.
    bool vecCountBody(IRBlock* B, IRBlock* H, IRBlock* L, IRValue* iv, IRInsn* ivNext,
                      Array* elemIds, Map* defOf, Map* defBlk)
        {
        _vcLaneTy = (String*)0;
        _vcElem = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == _vcCmp || n == _vcIncr || n == _vcAccNext || n == ivNext)
                continue;
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            if (op.equals(String.withCString("ElementAddr")))
                {
                if (n.ops().count() < (u32)2)
                    return false;
                IROperand* ix = (IROperand*)n.ops().get((u32)1);
                if (ix.kind() != (u8)OPK_USE || ix.val() != iv)
                    return false;
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return false;
                if (!vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return false;
                String* lt = n.res().ty();
                if (lt == (String*)0)
                    return false;
                // A NARROW element counts too: the compare and mask run at the
                // load's width and climb to the accumulator's with VAddLP. A
                // narrow lane only ever holds ONE iteration's mask before being
                // widened — the accumulation happens at 32 bits — so there is no
                // overflow beyond the delta having to fit the lane.
                if (!lt.equals(String.withCString("I32")) && !lt.equals(String.withCString("U32"))
                 && !lt.equals(String.withCString("I8"))  && !lt.equals(String.withCString("U8"))
                 && !lt.equals(String.withCString("I16")) && !lt.equals(String.withCString("U16")))
                    return false;
                if (_vcLaneTy != (String*)0 && !_vcLaneTy.equals(lt))
                    return false;
                _vcLaneTy = lt;
                _vcElem = n.res();
                if (!hasValue(elemIds, n.res()))
                    elemIds.add((Object*)n.res());
                continue;
                }
            if (vecElementwise(op))
                {
                if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
                    return false;
                if (!vecCountOperandOK((IROperand*)n.ops().get((u32)0), elemIds, defOf, defBlk, H, B, L))
                    return false;
                if (!vecCountOperandOK((IROperand*)n.ops().get((u32)1), elemIds, defOf, defBlk, H, B, L))
                    return false;
                if (!hasValue(elemIds, n.res()))
                    elemIds.add((Object*)n.res());
                continue;
                }
            return false;
            }
        return _vcLaneTy != (String*)0 && _vcElem != (IRValue*)0;
        }

    // The counter must be read ONLY by the Select and its increment, and the
    // induction variable must not escape the loop: either would still be live
    // after the rewrite replaced them.
    bool vecCountClean(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* L,
                       IRValue* acc, IRValue* iv)
        {
        if (vecCountAccRead(H, acc))
            return false;
        if (vecCountAccRead(B, acc))
            return false;
        if (vecCountAccRead(L, acc))
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B || bb == L)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return false;
            }
        return true;
        }

    bool vecCountAccRead(IRBlock* bb, IRValue* acc)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n == _vcAccNext || n == _vcIncr)
                continue;
            if (insnUsesValue(n, acc))
                return true;
            }
        return false;
        }

    // ivNext = Add(iv, 1) in the latch, found BEFORE the body is classified so
    // the classifier can skip it: when the body is merged it shares a block with
    // the count plumbing.
    IRInsn* vecCountStep(IRBlock* L, IRValue* iv, Map* defOf)
        {
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (!n.op().equals(String.withCString("Add")) || n.res() == (IRValue*)0)
                continue;
            if (n.ops().count() < (u32)2)
                continue;
            IROperand* a0 = (IROperand*)n.ops().get((u32)0);
            IROperand* a1 = (IROperand*)n.ops().get((u32)1);
            IROperand* so = (IROperand*)0;
            if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
                so = a1;
            else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
                so = a0;
            if (so == (IROperand*)0)
                continue;
            i32 one = (i32)0;
            if (vecConst(so, defOf, &one) && one == (i32)1)
                return n;
            }
        return (IRInsn*)0;
        }

    // The compare must be elementwise-vs-invariant: exactly one side elementwise
    // and the other loop-invariant. Both sides elementwise would vary per lane on
    // the right too; neither would make the compare loop-invariant and the count
    // a multiple of the trip.
    //
    // The original also whitelists the ICmp predicate, but that list is every
    // predicate ICmp has (EQ NE ULT UGT ULE UGE SLT SGT SLE SGE), so testing it
    // would refuse nothing and cost frame this function does not have.
    bool vecCountCmpOK(Array* elemIds, Map* defOf, Map* defBlk,
                       IRBlock* H, IRBlock* B, IRBlock* L)
        {
        IROperand* o0 = (IROperand*)_vcCmp.ops().get((u32)0);
        IROperand* o1 = (IROperand*)_vcCmp.ops().get((u32)1);
        bool e0 = o0.kind() == (u8)OPK_USE && hasValue(elemIds, o0.val());
        bool e1 = o1.kind() == (u8)OPK_USE && hasValue(elemIds, o1.val());
        if (e0 == e1)
            return false;
        IROperand* k = e0 ? o1 : o0;
        if (!vecCountOperandOK(k, elemIds, defOf, defBlk, H, B, L))
            return false;
        if (k.kind() == (u8)OPK_USE && hasValue(elemIds, k.val()))
            return false;
        return true;
        }

    VecCand* vecCountAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
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
        if (!vecConst((IROperand*)guard.ops().get((u32)1), defOf, &n) || n <= (i32)0)
            return (VecCand*)0;

        IRBlock* L = vecCountEdge(fn, accPhi, H, true);
        IRBlock* PH = vecCountEdge(fn, accPhi, H, false);
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

        if (!vecCountAcc(accPhi, acc, B, L, defOf, defBlk, uses))
            return (VecCand*)0;

        IRInsn* ivNext = vecCountStep(L, iv, defOf);
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = ((IROperand*)ivPhi.ops().get((u32)0)).blk() == L
                                ? (IROperand*)ivPhi.ops().get((u32)1)
                                : (IROperand*)ivPhi.ops().get((u32)3);
        if (ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        Array* elemIds = new Array();
        if (!vecCountBody(B, H, L, iv, ivNext, elemIds, defOf, defBlk))
            return (VecCand*)0;
        if (!vecCountCmpOK(elemIds, defOf, defBlk, H, B, L))
            return (VecCand*)0;
        if (!vecCountClean(fn, H, B, L, acc, iv))
            return (VecCand*)0;

        u32 lw = irWidth(_vcLaneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vw = (u32)16 / lw;
        // No epilogue for this shape yet, matching the original: the trip must be
        // a whole number of vectors.
        i32 dpStart = vecIvStart(ivPhi, L, defOf);
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
            if (accTy == (String*)0 || irWidth(accTy) != (u32)4)
                return (VecCand*)0;             // only a 32-bit count
            i64 dk2 = (i64)0;
            if (!vecConst(_vcDelta, defOf, &dk2))
                return (VecCand*)0;
            i64 laneMax = irWidth(_vcLaneTy) == (u32)1 ? (i64)255 : (i64)65535;
            if (dk2 < (i64)0 || dk2 > laneMax)
                return (VecCand*)0;             // the delta must fit the lane
            c.setLoadLane(_vcLaneTy);
            c.setLane(accTy, vw);
            }
        else
            c.setLane(_vcLaneTy, vw);
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
    IRValue* vecCountBodyRewrite(IRFunc* fn, VecCand* c, IRBlock* B, IRBlock* PH,
                                 String* vecTy, IRValue* vacc, Map* defOf, Map* defBlk)
        {
        _vecBody = new Array();
        _vecMap = new Map();
        _vecSplat = new Map();
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
                IROperand* va = vecOperandFor((IROperand*)n.ops().get((u32)0), fn, PH, B, c, defOf, defBlk);
                IROperand* vb = vecOperandFor((IROperand*)n.ops().get((u32)1), fn, PH, B, c, defOf, defBlk);
                IRValue* vr = new IRValue(vecTy);
                IRInsn* vi = IRInsn.with(vecOpFor(op));
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

    // Splat a loop-INVARIANT operand in the preheader, so it is computed once on
    // loop entry rather than per iteration. A compile-time constant is
    // rematerialised there; a value defined before the loop is splatted directly.
    IROperand* vecCountSplatPH(IRBlock* PH, IROperand* op, String* laneTy,
                               String* vecTy, Map* defOf)
        {
        IROperand* scalar = op;
        i32 k = (i32)0;
        if (vecConst(op, defOf, &k))
            {
            IRValue* cv = new IRValue(laneTy);
            IRInsn* ci = IRInsn.with(String.withCString("Const"));
            ci.setRes(cv);
            ci.add(IROperand.immI(k, laneTy));
            PH.insns().add((Object*)ci);
            scalar = IROperand.useVal(cv);
            }
        IRValue* sv = new IRValue(vecTy);
        IRInsn* si = IRInsn.with(String.withCString("VSplat"));
        si.setRes(sv);
        si.add(scalar);
        PH.insns().add((Object*)si);
        return IROperand.useVal(sv);
        }

    // An operand of the COMPARE: the elementwise side is already a vector, the
    // invariant side is splatted in the preheader.
    IROperand* vecCountCmpOperand(IROperand* op, IRBlock* PH, String* laneTy,
                                  String* vecTy, Map* defOf)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            Object* vv = _vecMap.get((Hashable*)op.val());
            if (vv != (Object*)0)
                return IROperand.useVal((IRValue*)vv);
            }
        return vecCountSplatPH(PH, op, laneTy, vecTy, defOf);
        }

    void vecApplyCount(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* PH = c.pre();
        IRBlock* L = c.mmLatch();
        // The load, compare and mask run at the ELEMENT's width; the accumulator
        // keeps its own. They are the same unless the element is narrower,
        // which is what loadLaneTy records — so the 32-bit path is unchanged.
        String* elemLane = c.loadLaneTy() != (String*)0 ? c.loadLaneTy() : c.laneTy();
        String* vecTy = new String();
        vecTy.appendFormat("Vec(%s)", elemLane.cString());
        String* accVecTy = new String();
        accVecTy.appendFormat("Vec(%s)", c.laneTy().cString());

        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            }

        IRValue* vacc = new IRValue(accVecTy);
        vecCountBodyRewrite(fn, c, B, PH, vecTy, vacc, defOf, defBlk);

        // mask = VICmp(elem, k); inc = mask AND splat(delta); vacc += inc.
        // The mask is all-ones in the lanes that matched, so the AND turns each
        // into delta or zero and no per-lane branch is needed.
        IRValue* vmask = new IRValue(vecTy);
        IRInsn* vic = IRInsn.with(String.withCString("VICmp"));
        vic.setRes(vmask);
        vic.add(vecCountCmpOperand((IROperand*)c.cmpInsn().ops().get((u32)0), PH,
                                   elemLane, vecTy, defOf));
        vic.add(vecCountCmpOperand((IROperand*)c.cmpInsn().ops().get((u32)1), PH,
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
        va.add(vecCountSplatPH(PH, c.delta(), elemLane, vecTy, defOf));
        _vecBody.add((Object*)va);

        // Climb the masked increments to the accumulator's width with uaddlp —
        // the ladder the widening sum uses. Pairwise summing preserves a total,
        // so folding lanes together does not disturb a count.
        IRValue* curInc = vinc;
        String* curLane = elemLane;
        while (irWidth(curLane) < irWidth(c.laneTy()))
            {
            String* nextLane = irWidth(curLane) == (u32)1
                                   ? String.withCString("U16")
                                   : String.withCString("U32");
            String* wTy = new String();
            wTy.appendFormat("Vec(%s)", nextLane.cString());
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
        vecZeroSeedPhi(c, H, L, PH, accVecTy, c.laneTy(), vacc, vnext);
        vecReduxExit(fn, c, vacc);
        }

    VecCand* vecMaxMinAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        if (!vecMaxMinShape(fn, H, defOf, defBlk))
            return (VecCand*)0;
        IRValue* iv = _mmIv;
        IRBlock* B = _mmB;
        IRBlock* TH = _mmTH;
        IRBlock* L = _mmL;
        IRValue* acc = _mmAccPhi.res();

        // The head: address, load, compare, conditional branch — nothing else.
        IRInsn* bterm = B.term();
        if (bterm == (IRInsn*)0 || !bterm.op().equals(String.withCString("CondBranch")) || bterm.ops().count() < (u32)3)
            return (VecCand*)0;
        IROperand* bc = (IROperand*)bterm.ops().get((u32)0);
        if (bc.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* co = defOf.get((Hashable*)bc.val());
        Object* cb = defBlk.get((Hashable*)bc.val());
        if (co == (Object*)0 || cb == (Object*)0 || (IRBlock*)cb != B)
            return (VecCand*)0;
        IRInsn* cmp = (IRInsn*)co;
        if (!cmp.op().equals(String.withCString("ICmp")))
            return (VecCand*)0;

        IRValue* elem = vecMaxMinHead(B, iv, defOf);
        if (elem == (IRValue*)0)
            return (VecCand*)0;
        String* laneTy = elem.ty();
        if (!vecMaxMinArms(B, TH, L, iv, acc, elem, defOf, defBlk))
            return (VecCand*)0;

        // ivNext = Add(iv, 1) in the join, and it is the iv phi's back edge.
        IRInsn* ivNext = (IRInsn*)0;
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (!n.op().equals(String.withCString("Add")) || n.res() == (IRValue*)0)
                continue;
            if (n.ops().count() < (u32)2)
                continue;
            IROperand* x0 = (IROperand*)n.ops().get((u32)0);
            IROperand* x1 = (IROperand*)n.ops().get((u32)1);
            IROperand* so = (IROperand*)0;
            if (x0.kind() == (u8)OPK_USE && x0.val() == iv)
                so = x1;
            else if (x1.kind() == (u8)OPK_USE && x1.val() == iv)
                so = x0;
            i32 one = (i32)0;
            if (so != (IROperand*)0 && vecConst(so, defOf, &one) && one == (i32)1)
                {
                ivNext = n;
                break;
                }
            }
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = vecBackOp(_mmIvPhi, L);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        // Max or min, and the signedness, from the compare. The true arm keeps
        // the element, so "element is larger" means max.
        IROperand* ca = (IROperand*)cmp.ops().get((u32)0);
        IROperand* cbb = (IROperand*)cmp.ops().get((u32)1);
        bool elemLeft = false;
        if (ca.kind() == (u8)OPK_USE && ca.val() == elem && cbb.kind() == (u8)OPK_USE && cbb.val() == acc)
            elemLeft = true;
        else if (ca.kind() == (u8)OPK_USE && ca.val() == acc && cbb.kind() == (u8)OPK_USE && cbb.val() == elem)
            elemLeft = false;
        else
            return (VecCand*)0;
        String* pr = cmp.pred();
        if (pr == (String*)0)
            return (VecCand*)0;
        bool gtFam = pr.equals(String.withCString("UGT")) || pr.equals(String.withCString("SGT")) || pr.equals(String.withCString("UGE")) || pr.equals(String.withCString("SGE"));
        bool ltFam = pr.equals(String.withCString("ULT")) || pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("ULE")) || pr.equals(String.withCString("SLE"));
        if (!gtFam && !ltFam)
            return (VecCand*)0;
        bool signedCmp = pr.equals(String.withCString("SGT")) || pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("SGE")) || pr.equals(String.withCString("SLE"));
        if (signedCmp != laneTy.equals(String.withCString("I32")))
            return (VecCand*)0;
        bool isMax = elemLeft ? gtFam : ltFam;

        IROperand* seedOp = vecEntryOpOf(_mmAccPhi, L);
        u32 lw = irWidth(laneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vw = (u32)16 / lw;
        if (vw < (u32)2 || (_mmN % (i32)vw) != (i32)0)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, _mmE);
        c.setIv(_mmIvPhi, ivNext, _mmGuard, iv);
        c.setLane(laneTy, vw);
        c.setReduction(_mmAccPhi, (IRInsn*)0, acc, elem, seedOp, _mmPH);
        c.setMaxMin(isMax, TH, L);
        return c;
        }

    // The diamond head: address, load, compare, conditional branch — and
    // nothing else. Returns the loaded element, or null.
    IRValue* vecMaxMinHead(IRBlock* B, IRValue* iv, Map* defOf)
        {
        IRValue* elem = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")))
                continue;
            if (op.equals(String.withCString("ElementAddr")))
                {
                if (n.ops().count() < (u32)2)
                    return (IRValue*)0;
                IROperand* idx = (IROperand*)n.ops().get((u32)1);
                if (idx.kind() != (u8)OPK_USE || idx.val() != iv)
                    return (IRValue*)0;
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (IRValue*)0;
                if (!vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (IRValue*)0;
                if (!vecRedux32(n.res().ty()))
                    return (IRValue*)0;
                elem = n.res();
                continue;
                }
            if (op.equals(String.withCString("ICmp")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            return (IRValue*)0;
            }
        return elem;
        }

    // The then arm holds nothing but a reload, and the join's arms are
    // (body → accumulator, then → element): the `if (cmp) m = a[i]` shape.
    bool vecMaxMinArms(IRBlock* B, IRBlock* TH, IRBlock* L, IRValue* iv,
                       IRValue* acc, IRValue* elem, Map* defOf, Map* defBlk)
        {
        if (TH.phis().count() != (u32)0 || TH.term() == (IRInsn*)0 || !TH.term().op().equals(String.withCString("Branch")) || TH.term().ops().count() < (u32)1 || ((IROperand*)TH.term().ops().get((u32)0)).blk() != L)
            return false;
        for (u32 i = (u32)0; i < TH.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)TH.insns().get(i)).op();
            if (!op.equals(String.withCString("AddrOf")) && !op.equals(String.withCString("ElementAddr")) && !op.equals(String.withCString("Load")))
                return false;
            }
        IROperand* armFromB = vecArmFrom(_mmJoinPhi, B);
        IROperand* armFromTH = vecArmFrom(_mmJoinPhi, TH);
        if (armFromB == (IROperand*)0 || armFromB.kind() != (u8)OPK_USE || armFromB.val() != acc)
            return false;
        if (armFromTH == (IROperand*)0 || armFromTH.kind() != (u8)OPK_USE)
            return false;
        if (armFromTH.val() == elem)
            return true;
        Object* ro = defOf.get((Hashable*)armFromTH.val());
        Object* rb = defBlk.get((Hashable*)armFromTH.val());
        if (ro == (Object*)0 || rb == (Object*)0 || (IRBlock*)rb != TH)
            return false;
        IRInsn* rl = (IRInsn*)ro;
        if (!rl.op().equals(String.withCString("Load")) || rl.ops().count() < (u32)1)
            return false;
        return vecIsElemAddr((IROperand*)rl.ops().get((u32)0), iv, defOf);
        }

    void vecRepairMem(IRFunc* fn, VecCand* c, IRBlock* B, IRBlock* L)
        {
        Array* gone = new Array();
        vecCollectDefs(gone, c.mmThen());
        vecCollectDefs(gone, L);
        IRValue* liveMem = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                liveMem = n.memRes();
            }
        if (gone.count() == (u32)0 || liveMem == (IRValue*)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == L || bb == c.mmThen())
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                vecRewireGone((IRInsn*)bb.phis().get(k), gone, liveMem);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                vecRewireGone((IRInsn*)bb.insns().get(k), gone, liveMem);
            if (bb.term() != (IRInsn*)0)
                vecRewireGone(bb.term(), gone, liveMem);
            }
        }

    // Every value a block defines — results and memory results alike.
    void vecCollectDefs(Array* out, IRBlock* bb)
        {
        if (bb == (IRBlock*)0)
            return;
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                out.add((Object*)n.memRes());
            if (n.res() != (IRValue*)0)
                out.add((Object*)n.res());
            }
        }

    void vecRewireGone(IRInsn* n, Array* gone, IRValue* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || !hasValue(gone, o.val()))
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    // The phi arm paired with a given incoming block.
    IROperand* vecArmFrom(IRInsn* phi, IRBlock* from)
        {
        if (((IROperand*)phi.ops().get((u32)0)).blk() == from)
            return (IROperand*)phi.ops().get((u32)1);
        if (((IROperand*)phi.ops().get((u32)2)).blk() == from)
            return (IROperand*)phi.ops().get((u32)3);
        return (IROperand*)0;
        }

    // Break the serial accumulator dependency: a vectorised reduction loop is
    // unrolled across several independent accumulators (clang does the same), so
    // an out-of-order core can overlap the add chains instead of waiting a full
    // latency per iteration. The copies are combined at the exit with the same
    // op the reduction used, and the existing horizontal reduce then reads the
    // combined vector.
    void vecUnrollReductions(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            vecUnrollAt(fn, (IRBlock*)fn.blocks().get(hi));
        }

    // A RUNTIME bound. The vectoriser emitted `M = n & ~(vw-1)`, and the unroll
    // needs the trip to be a whole number of U vectors -- so widen that mask to
    // ~(U*vw-1) and it is one by construction. Nothing else changes: the guard
    // and the scalar clone's induction seed are the SAME value, so lowering M
    // moves both, and the clone already runs [M, n) -- the tail merely gets up
    // to U*vw-1 elements instead of vw-1.
    //
    // Refused (returns 1) unless the mask is EXACTLY the one the vectoriser
    // built: any other bound is one this pass does not understand, and
    // rewriting it would change the loop's trip count. EXTRACTED for the arm64
    // frame budget -- inline, vecUnrollAt needed 20032 bytes against 16384.
    u32 vecWidenRuntimeMask(IRInsn* guard, Map* defOf, u32 vw)
        {
        IROperand* gb = (IROperand*)guard.ops().get((u32)1);
        if (gb.kind() != (u8)OPK_USE)
            return (u32)1;
        Object* mo = defOf.get((Hashable*)gb.val());
        if (mo == (Object*)0)
            return (u32)1;
        IRInsn* mask = (IRInsn*)mo;
        if (!mask.op().equals(String.withCString("And")) || mask.ops().count() < (u32)2)
            return (u32)1;
        IROperand* mi = (IROperand*)mask.ops().get((u32)1);
        if (mi.kind() != (u8)OPK_IMMI)
            return (u32)1;
        if (mi.imm() != (i64) ~((i32)vw - (i32)1))
            return (u32)1;
        mask.ops().set((u32)1,
                       (Object*)IROperand.immI((i64) ~((i32)((u32)4 * vw) - (i32)1), mask.res().ty()));
        return (u32)4;
        }

    void vecUnrollAt(IRFunc* fn, IRBlock* H)
        {
        if (H.phis().count() != (u32)2)
            return;
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            vecNoteDefs(defOf, defBlk, bb.insns(), bb);
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
        i32 n = (i32)0;
        // The bound may be a literal, or the runtime limit M = n & ~(vw-1) the
        // vectoriser builds for a runtime trip count. Both are unrollable; which
        // one it is decides how U is chosen, below.
        bool constN = vecConst((IROperand*)guard.ops().get((u32)1), defOf, &n);
        if (constN && n <= (i32)0)
            return;

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = rotIsLatch(t0, H) ? t0 : (rotIsLatch(t1, H) ? t1 : (IRBlock*)0);
        if (B == (IRBlock*)0)
            return;
        IRBlock* E = (B == t0) ? t1 : t0;
        if (E == (IRBlock*)0)
            return;

        // vnext = Vop(vacc, X) and ivNext = Add(iv, vw), both in the body.
        IROperand* vnextOp = vecBackOp(vaccPhi, B);
        IROperand* ivNextOp = vecBackOp(ivPhi, B);
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
        if (stepOp == (IROperand*)0 || !vecConst(stepOp, defOf, &vw) || vw < (i32)2)
            return;

        // The preheader's lane init is a VSplat we replicate per copy.
        IRBlock* PH = vecEntryBlkOf(vaccPhi, B);
        IROperand* initOp = vecEntryOpOf(vaccPhi, B);
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
            U = (n % ((i32)4 * vw)) == (i32)0 ? (u32)4
                                              : ((n % ((i32)2 * vw)) == (i32)0 ? (u32)2 : (u32)1);
            }
        else
            {
            U = vecWidenRuntimeMask(guard, defOf, vw);
            }
        if (U < (u32)2)
            return;

        vecUnrollApply(fn, H, B, E, PH, iv, vacc, vecTy, ivNextInsn, vnextInsn,
                       initInsn, vw, U);
        }

    void vecUnrollApply(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* E, IRBlock* PH,
                        IRValue* iv, IRValue* vacc, String* vecTy,
                        IRInsn* ivNextInsn, IRInsn* vnextInsn, IRInsn* initInsn,
                        i32 vw, u32 U)
        {
        String* ivTy = ivNextInsn.res().ty();

        // The iv-dependent chain, in order, EXCEPT the iv step (re-stepped to
        // U*vw separately). vnextInsn is in it, because it consumes a value that
        // depends on the iv.
        Array* dep = new Array();
        dep.add((Object*)iv);
        Array* ivDep = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == ivNextInsn)
                continue;
            bool d = false;
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() == (u8)OPK_USE && hasValue(dep, o.val()))
                    {
                    d = true;
                    break;
                    }
                }
            if (!d)
                continue;
            ivDep.add((Object*)n);
            if (n.res() != (IRValue*)0)
                dep.add((Object*)n.res());
            }

        Array* appended = new Array();
        Array* newPhis = new Array();
        Array* accs = new Array();
        accs.add((Object*)vacc); // copy 0 is the original
        for (u32 k = (u32)1; k < U; k = k + (u32)1)
            vecUnrollCopy(k, vw, ivTy, vecTy, iv, vacc, B, PH, initInsn, vnextInsn,
                          ivDep, appended, newPhis, accs);

        vecUnrollSplice(fn, H, B, E, iv, vacc, vecTy, ivNextInsn, vnextInsn,
                        ivTy, vw, U, appended, newPhis, accs);
        }

    // One extra accumulator: its zeroed init in the preheader, its own iv offset,
    // and a clone of the iv-dependent chain with iv → iv+k*vw and vacc → vacc_k.
    void vecUnrollCopy(u32 k, i32 vw, String* ivTy, String* vecTy,
                       IRValue* iv, IRValue* vacc, IRBlock* B, IRBlock* PH,
                       IRInsn* initInsn, IRInsn* vnextInsn, Array* ivDep,
                       Array* appended, Array* newPhis, Array* accs)
        {
        IRValue* vaccK = new IRValue(vecTy);
        // All U accumulators start from the SAME preheader broadcast — reuse
        // copy 0's VSplat rather than cloning it per copy. U-1 phi copies
        // replace U-1 live splats, which is what keeps the backends'
        // 8-register vector pools from overflowing (#1198).
        IRValue* ivK = new IRValue(ivTy);
        IRInsn* ia = IRInsn.with(String.withCString("Add"));
        ia.setRes(ivK);
        ia.add(IROperand.useVal(iv));
        ia.add(IROperand.immI((i32)k * vw, ivTy));
        appended.add((Object*)ia);

        Map* remap = new Map();
        remap.set((Hashable*)iv, (Object*)ivK);
        remap.set((Hashable*)vacc, (Object*)vaccK);
        IRValue* vnextK = (IRValue*)0;
        for (u32 i = (u32)0; i < ivDep.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)ivDep.get(i);
            IRInsn* cl = IRInsn.with(n.op());
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 j = (u32)0; j < n.ops().count(); j = j + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(j);
                Object* r = o.kind() == (u8)OPK_USE
                                ? remap.get((Hashable*)o.val())
                                : (Object*)0;
                cl.add(r == (Object*)0 ? o : IROperand.useVal((IRValue*)r));
                }
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                remap.set((Hashable*)n.res(), (Object*)cl.res());
                }
            if (n.memRes() != (IRValue*)0)
                cl.setMemRes(new IRValue(String.withCString("Mem")));
            appended.add((Object*)cl);
            if (n == vnextInsn)
                vnextK = cl.res();
            }
        IRInsn* ph = IRInsn.with(String.withCString("Phi"));
        ph.setRes(vaccK);
        ph.add(IROperand.block(PH));
        ph.add(IROperand.useVal(initInsn.res()));
        ph.add(IROperand.block(B));
        ph.add(IROperand.useVal(vnextK));
        newPhis.add((Object*)ph);
        accs.add((Object*)vaccK);
        }

    void vecUnrollSplice(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* E,
                         IRValue* iv, IRValue* vacc, String* vecTy,
                         IRInsn* ivNextInsn, IRInsn* vnextInsn, String* ivTy,
                         i32 vw, u32 U, Array* appended, Array* newPhis, Array* accs)
        {
        // The clones go at the END of the body, after copy 0's whole chain, so
        // the loop-invariant values copy 0 computes mid-body are defined before
        // the clones that share them. The iv step is order-independent — it
        // reads only the phi.
        for (u32 i = (u32)0; i < appended.count(); i = i + (u32)1)
            B.insns().add(appended.get(i));
        for (u32 j = (u32)0; j < ivNextInsn.ops().count(); j = j + (u32)1)
            {
            IROperand* o = (IROperand*)ivNextInsn.ops().get(j);
            if (o.kind() == (u8)OPK_IMMI || (o.kind() == (u8)OPK_USE && o.val() != iv))
                ivNextInsn.ops().set(j, (Object*)IROperand.immI((i32)U * vw, ivTy));
            }
        for (u32 i = (u32)0; i < newPhis.count(); i = i + (u32)1)
            H.addPhi((IRInsn*)newPhis.get(i));

        // Combine the copies at the exit with the reduction's own op, then point
        // the existing horizontal reduce at the combined accumulator.
        Array* combine = new Array();
        IRValue* cur = vacc;
        for (u32 k = (u32)1; k < U; k = k + (u32)1)
            {
            IRValue* r = new IRValue(vecTy);
            IRInsn* cb = IRInsn.with(vnextInsn.op());
            cb.setRes(r);
            cb.add(IROperand.useVal(cur));
            cb.add(IROperand.useVal((IRValue*)accs.get(k)));
            combine.add((Object*)cb);
            cur = r;
            }
        for (u32 i = (u32)0; i < combine.count(); i = i + (u32)1)
            E.insns().insert(i, combine.get(i));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (hasInsn(combine, n))
                    continue;
                vecReplaceUse(n, vacc, cur, (IRInsn*)0);
                }
            }
        }

    // The widening-sum rewrite, shared with the dot product: vector-load the
    // narrow array (16×u8 or 8×u16), fold the lanes up to u32 by repeated
    // pairwise widening, accumulate in a 4×u32 vector, reduce at the exit. The
    // accumulator update stays a plain VAdd, so the multi-accumulator unroller
    // then treats it like any other add reduction.
    // EXTRACTED purely for the arm64 frame budget, like vecReduxEpilogue:
    // vecWideningAt sits ~80 bytes from the 16 KB ceiling, and computing the
    // epilogue bound inline pushed it 240 bytes OVER. Every IR value gets its
    // own frame slot, so two lines of arithmetic cost far more stack than they
    // look like they should. Sets the candidate's epilogue fields; returns false
    // when the loop has fewer than one whole vector and must stay scalar.
    // Epilogue part 1 for the widening/dot applier, EXTRACTED for the arm64
    // frame budget exactly as vecReduxEpilogue was: inlined, the clone, its map
    // and the guard rewrite pushed vecApplyWidening to 17168 bytes against a
    // 16384 ceiling. Part 2 needs no code here -- the applier ends in
    // vecReduxExit, which lands the horizontal add in a VE landing pad and
    // seeds the clone whenever needEpi() is set.
    void vecWidenEpiSetup(VecCand* c, IRBlock* H, IRBlock* B, IRBlock* PH)
        {
        _vecH2 = (IRBlock*)0;
        _vecB2 = (IRBlock*)0;
        _vecCmap = (Map*)0;
        _vecPH = (IRBlock*)0;
        vecSetEpi(c);
        if (!c.needEpi())
            return;
        Map* cmap = new Map();
        Array* cl = vecCloneLoop(H, B, cmap);
        _vecH2 = (IRBlock*)cl.get((u32)0);
        _vecB2 = (IRBlock*)cl.get((u32)1);
        _vecCmap = cmap;
        _vecPH = PH;
        // The vector loop now stops at the last whole vector; the clone's own
        // (cloned) guard still tests the original bound.
        if (c.rtTrip())
            {
            _vecRtM = vecRuntimeLimit(c, PH);
            c.guard().ops().set((u32)1, (Object*)IROperand.useVal(_vecRtM));
            }
        else
            {
            _vecRtM = (IRValue*)0;
            c.guard().ops().set((u32)1, (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
            }
        }

    // The bound comes from the candidate, NOT from re-reading the guard: the
    // guard's bound is a USE of a Const, not an immediate operand, so reading it
    // here returned nothing and an earlier version quietly set needEpi=false --
    // which vectorised a 100-element loop with no remainder and stepped clean
    // past the end. Recording n at recognition time removes the guess.
    void vecSetEpi(VecCand* c)
        {
        // A RUNTIME bound always takes the epilogue and has no compile-time M:
        // the limit is computed in the preheader instead.
        if (c.rtTrip())
            {
            c.setEpi(true, (i32)0);
            return;
            }
        // M is the last whole-vector boundary of the trip LENGTH `n - ivStart`,
        // rebased onto the start — `n - n%vw` was right only for a zero start.
        i32 n = _vrN;
        i32 trip = n - _vrIvStart;
        i32 m = _vrIvStart + (trip - (trip % (i32)c.vw()));
        c.setEpi(m != n, m);
        }

    void vecApplyWidening(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* PH = c.pre();

        // Epilogue part 1: clone the scalar loop BEFORE the body and the
        // header's phis are rewritten in place. Part 2 comes free — this
        // applier already ends in vecReduxExit, which lands the horizontal add
        // in a VE landing pad and seeds the clone whenever needEpi() is set.
        vecWidenEpiSetup(c, H, B, PH);
        String* u32t = String.withCString("U32");
        String* accVecTy = String.withCString("Vec(U32)");
        String* loadVecTy = new String();
        loadVecTy.appendFormat("Vec(%s)", c.loadLaneTy().cString());

        // For a dot product the accumulated element is ZExt(Mul(a,b)); find that
        // scalar multiply so it and its widening can become a VMul of the two
        // vector loads.
        IRValue* mul = (IRValue*)0;
        if (c.isDot())
            {
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)B.insns().get(i);
                if (!n.op().equals(String.withCString("Mul")) || n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
                    continue;
                IROperand* m0 = (IROperand*)n.ops().get((u32)0);
                IROperand* m1 = (IROperand*)n.ops().get((u32)1);
                if (m0.kind() != (u8)OPK_USE || m1.kind() != (u8)OPK_USE)
                    continue;
                if ((m0.val() == c.load() && m1.val() == c.load2()) || (m0.val() == c.load2() && m1.val() == c.load()))
                    {
                    mul = n.res();
                    break;
                    }
                }
            }
        IRValue* zxSrc = c.isDot() ? mul : c.load();

        IRValue* vacc = new IRValue(accVecTy);
        Array* nb = new Array();
        Array* vls = vecWideningLoads(c, B, mul, zxSrc, loadVecTy, nb);
        IRValue* vload = (IRValue*)vls.get((u32)0);
        IRValue* vload2 = (IRValue*)vls.get((u32)1);
        if (vload == (IRValue*)0)
            return;

        // The dot product multiplies in the NARROW lane first: VMul keeps the low
        // half, so it wraps exactly like the scalar u16*u16 it replaces.
        IRValue* cur = vload;
        if (c.isDot())
            {
            if (vload2 == (IRValue*)0)
                return;
            IRValue* vprod = new IRValue(loadVecTy);
            IRInsn* vm = IRInsn.with(String.withCString("VMul"));
            vm.setRes(vprod);
            vm.add(IROperand.useVal(vload));
            vm.add(IROperand.useVal(vload2));
            nb.add((Object*)vm);
            cur = vprod;
            }
        // Fold the lanes up to u32, one pairwise widening at a time.
        String* curLane = c.loadLaneTy();
        while (irWidth(curLane) < (u32)4)
            {
            String* nextLane = irWidth(curLane) == (u32)1
                                   ? String.withCString("U16")
                                   : u32t;
            String* wTy = new String();
            wTy.appendFormat("Vec(%s)", nextLane.cString());
            IRValue* w = new IRValue(wTy);
            IRInsn* wi = IRInsn.with(String.withCString("VAddLP"));
            wi.setRes(w);
            wi.add(IROperand.useVal(cur));
            nb.add((Object*)wi);
            cur = w;
            curLane = nextLane;
            }
        IRValue* vnext = new IRValue(accVecTy);
        IRInsn* va = IRInsn.with(String.withCString("VAdd"));
        va.setRes(vnext);
        va.add(IROperand.useVal(vacc));
        va.add(IROperand.useVal(cur));
        nb.add((Object*)va);
        B.setInsns(nb);

        // The iv steps by the lane count — 16 for u8, 8 for u16.
        for (u32 k = (u32)0; k < c.ivNext().ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)c.ivNext().ops().get(k);
            if (o.kind() == (u8)OPK_IMMI || (o.kind() == (u8)OPK_USE && o.val() != c.iv()))
                c.ivNext().ops().set(k,
                                     (Object*)IROperand.immI((i32)c.vw(), c.ivNext().res().ty()));
            }

        vecZeroSeedPhi(c, H, B, PH, accVecTy, u32t, vacc, vnext);
        vecReduxExit(fn, c, vacc);
        _vecSplatPH = (IRBlock*)0;
        }

    // The zeroed vector accumulator in the preheader and the phi that replaces
    // the scalar one in the header.
    void vecZeroSeedPhi(VecCand* c, IRBlock* H, IRBlock* B, IRBlock* PH,
                        String* accVecTy, String* u32t,
                        IRValue* vacc, IRValue* vnext)
        {
        IRValue* vacc0 = new IRValue(accVecTy);
        IRValue* zero = new IRValue(u32t);
        IRInsn* zc = IRInsn.with(String.withCString("Const"));
        zc.setRes(zero);
        zc.add(IROperand.immI((i32)0, u32t));
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
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            newPhis.add(p == c.accPhi() ? (Object*)vphi : (Object*)p);
            }
        H.setPhis(newPhis);
        }

    // Rebuild the widening body: the narrow loads become vector loads, and the
    // scalar multiply and widening are dropped (replaced by VMul / VAddLP).
    // Returns [vload, vload2].
    Array* vecWideningLoads(VecCand* c, IRBlock* B, IRValue* mul, IRValue* zxSrc,
                            String* loadVecTy, Array* nb)
        {
        IRValue* vload = (IRValue*)0;
        IRValue* vload2 = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == c.accNext())
                continue; // the scalar accumulate goes
            if (c.isDot() && n.res() != (IRValue*)0 && n.res() == mul)
                continue; // → VMul
            if (n.res() != (IRValue*)0 && (n.res() == c.load() || (c.isDot() && n.res() == c.load2())))
                {
                IRValue* vl = new IRValue(loadVecTy);
                IRInsn* vi = IRInsn.with(String.withCString("VLoad"));
                vi.setRes(vl);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vi.add((IROperand*)n.ops().get(k));
                vi.setMemRes(n.memRes());
                nb.add((Object*)vi);
                if (n.res() == c.load())
                    vload = vl;
                else
                    vload2 = vl;
                continue;
                }
            if (n.op().equals(String.withCString("ZExt")) && n.ops().count() >= (u32)1)
                {
                IROperand* zs = (IROperand*)n.ops().get((u32)0);
                if (zs.kind() == (u8)OPK_USE && zs.val() == zxSrc)
                    continue; // replaced
                }
            nb.add((Object*)n); // address, iv step, constants
            }
        Array* out = new Array();
        out.add((Object*)vload);
        out.add((Object*)vload2);
        return out;
        }

    // The min/max rewrite. The diamond collapses to a single straight-line
    // vector latch: keep the address computation, vector-load the element, fold
    // it in with VMax/VMin, step the iv by the vector width, branch back. The
    // then-arm and the join go away entirely.
    void vecApplyMaxMin(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* E = c.e();
        IRBlock* PH = c.pre();
        IRBlock* L = c.mmLatch();
        String* vecTy = new String();
        vecTy.appendFormat("Vec(%s)", c.laneTy().cString());

        // Creation order matters: fresh values take ids in creation (seq)
        // order, and the original allocates vacc, vload, vnext, ivNext.
        IRValue* vacc = new IRValue(vecTy);
        IRValue* vload = new IRValue(vecTy);
        IRValue* vnext = new IRValue(vecTy);
        IRValue* ivNextV = new IRValue(c.ivNext().res().ty());
        if (!vecMaxMinLatch(c, B, H, vecTy, vacc, vload, vnext, ivNextV))
            return;

        // The vector accumulator seeds every lane with the scalar seed: min and
        // max are idempotent, so no end-combine is needed for the seed.
        IRValue* vacc0 = new IRValue(vecTy);
        IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
        sp.setRes(vacc0);
        sp.add(c.seed());
        PH.insns().add((Object*)sp);
        IRInsn* vphi = IRInsn.with(String.withCString("Phi"));
        vphi.setRes(vacc);
        vphi.add(IROperand.block(PH));
        vphi.add(IROperand.useVal(vacc0));
        vphi.add(IROperand.block(B));
        vphi.add(IROperand.useVal(vnext));

        Array* newPhis = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p == c.accPhi())
                {
                newPhis.add((Object*)vphi);
                continue;
                }
            // The iv phi's back edge moves from the old join to the new latch.
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)p.ops().get(k);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != L)
                    continue;
                p.ops().set(k, (Object*)IROperand.block(B));
                p.ops().set(k + (u32)1, (Object*)IROperand.useVal(ivNextV));
                }
            newPhis.add((Object*)p);
            }
        H.setPhis(newPhis);

        // Repair the memory chain BEFORE the diamond goes. The scalar loop
        // threaded its token through the then-arm's reload, so post-loop code
        // reads a token defined in a block about to disappear; every value
        // defined in the arm or the join becomes the surviving VLoad's token.
        // Skipping this leaves a reference with no definition — which the
        // original's printer spells `%?36` and this one hides behind a stale
        // parse-time id, so neither says it out loud.
        vecRepairMem(fn, c, B, L);

        // The diamond arm and the join are now unreachable.
        Array* keep = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != L && bb != c.mmThen())
                keep.add((Object*)bb);
            }
        fn.setBlocks(keep);

        // Horizontal reduce at the exit, and the live-out readers follow it.
        IRValue* red = new IRValue(c.laneTy());
        IRInsn* rd = IRInsn.with(c.isMax() ? String.withCString("VReduceMax")
                                           : String.withCString("VReduceMin"));
        rd.setRes(red);
        rd.add(IROperand.useVal(vacc));
        E.insns().insert((u32)0, (Object*)rd);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                vecReplaceUse((IRInsn*)bb.phis().get(k), c.acc(), red, rd);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                vecReplaceUse((IRInsn*)bb.insns().get(k), c.acc(), red, rd);
            if (bb.term() != (IRInsn*)0)
                vecReplaceUse(bb.term(), c.acc(), red, rd);
            }
        }

    // Rebuild the diamond head as the loop's single straight-line vector latch.
    bool vecMaxMinLatch(VecCand* c, IRBlock* B, IRBlock* H, String* vecTy,
                        IRValue* vacc, IRValue* vload, IRValue* vnext,
                        IRValue* ivNextV)
        {
        Array* nb = new Array();
        bool sawLoad = false;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.op().equals(String.withCString("Load")) && n.res() == c.elem())
                {
                sawLoad = true;
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                vl.setRes(vload);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vl.add((IROperand*)n.ops().get(k));
                vl.setMemRes(n.memRes());
                nb.add((Object*)vl);
                continue;
                }
            if (n.op().equals(String.withCString("AddrOf")) || n.op().equals(String.withCString("ElementAddr")) || n.op().equals(String.withCString("Const")))
                nb.add((Object*)n); // the address plumbing stays
            // The compare and the casts are dropped — folded into the vector op.
            }
        if (!sawLoad)
            return false;

        IRInsn* vop = IRInsn.with(c.isMax() ? String.withCString("VMax")
                                            : String.withCString("VMin"));
        vop.setRes(vnext);
        vop.add(IROperand.useVal(vacc));
        vop.add(IROperand.useVal(vload));
        nb.add((Object*)vop);

        IRInsn* ia = IRInsn.with(String.withCString("Add"));
        ia.setRes(ivNextV);
        ia.add(IROperand.useVal(c.iv()));
        ia.add(IROperand.immI((i32)c.vw(), c.ivNext().res().ty()));
        nb.add((Object*)ia);
        B.setInsns(nb);
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H));
        B.setTerm(br);
        return true;
        }

    // The reduction rewrite: the scalar accumulator phi becomes a VECTOR one
    // seeded with zeroed lanes in the preheader, the body accumulates into it,
    // and the exit block horizontally reduces it back to a scalar.
    // M = ivStart + (max(n - ivStart, 0) & ~(vw-1)), emitted into the
    // preheader. The old form, M = n & ~(vw-1), rounded the BOUND down instead
    // of the trip length, which is only the same number when ivStart is 0 and
    // n >= 0: a bound below the start seeded the remainder BELOW the start
    // (fuzz 267 wrote a[0] from a [2, 1) loop), and a start off the vector
    // stride let the last vector step overrun M so the remainder re-applied
    // the overlap. The clamp is a sign-mask (AShr/Not/And), not a Select, so
    // it stays in the basic-ALU subset every vectorising back end handles.
    // EXTRACTED for the arm64 frame budget -- vecApplyReduction has no slots
    // to spare. Mirrors xtvEmitRuntimeM, byte-identically.
    IRValue* vecRuntimeLimit(VecCand* c, IRBlock* PH)
        {
        String* ivTy = c.iv().ty();
        IROperand* tl = c.bound();
        if (c.ivStart() != (i32)0)
            {
            IRValue* tv = new IRValue(ivTy);
            IRInsn* sb = IRInsn.with(String.withCString("Sub"));
            sb.setRes(tv);
            sb.add(c.bound());
            sb.add(IROperand.immI((i64)c.ivStart(), ivTy));
            PH.add(sb);
            tl = IROperand.useVal(tv);
            }
        // max(tl, 0): tl & ~(tl >> (bits-1)) — the sign fills the mask when
        // tl is negative, so the And zeroes it.
        IRValue* sv = new IRValue(ivTy);
        IRInsn* sh = IRInsn.with(String.withCString("AShr"));
        sh.setRes(sv);
        sh.add(tl);
        sh.add(IROperand.immI((i64)(irWidth(ivTy) * (u32)8 - (u32)1),
                              String.withCString("U8")));
        PH.add(sh);
        IRValue* nv = new IRValue(ivTy);
        IRInsn* nt = IRInsn.with(String.withCString("Not"));
        nt.setRes(nv);
        nt.add(IROperand.useVal(sv));
        PH.add(nt);
        IRValue* cv = new IRValue(ivTy);
        IRInsn* an0 = IRInsn.with(String.withCString("And"));
        an0.setRes(cv);
        an0.add(tl);
        an0.add(IROperand.useVal(nv));
        PH.add(an0);
        IRValue* mv = new IRValue(ivTy);
        IRInsn* an = IRInsn.with(String.withCString("And"));
        an.setRes(mv);
        an.add(IROperand.useVal(cv));
        an.add(IROperand.immI((i64) ~((i32)c.vw() - (i32)1), ivTy));
        PH.add(an);
        if (c.ivStart() == (i32)0)
            return mv;
        IRValue* rv = new IRValue(ivTy);
        IRInsn* ad = IRInsn.with(String.withCString("Add"));
        ad.setRes(rv);
        ad.add(IROperand.useVal(mv));
        ad.add(IROperand.immI((i64)c.ivStart(), ivTy));
        PH.add(ad);
        return rv;
        }

    void vecApplyReduction(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* E = c.e();
        IRBlock* PH = c.pre();
        _vecTy = new String();
        _vecTy.appendFormat("Vec(%s)", c.laneTy().cString());
        _vecMap = new Map();
        _vecSplat = new Map();
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
            Array* cl = vecCloneLoop(H, B, cmap);
            H2 = (IRBlock*)cl.get((u32)0);
            B2 = (IRBlock*)cl.get((u32)1);
            _vecH2 = H2;
            _vecB2 = B2;
            _vecCmap = cmap;
            _vecPH = PH;
            // The vector loop now stops at the last whole vector; the clone's
            // own (cloned) guard still tests the original bound.
            if (c.rtTrip())
                {
                _vecRtM = vecRuntimeLimit(c, PH);
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

        // The vector accumulator, needed by name before the body's VAdd is built.
        IRValue* vacc = new IRValue(_vecTy);
        vecReduxBody(c, B, vacc);
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

        vecReduxExit(fn, c, vacc);
        }

    // The horizontal reduce at the loop exit, plus the initial scalar added back
    // if the accumulator did not start at zero, and the rewiring of every
    // post-loop reader of the old scalar accumulator.
    // Splice the remainder loop in between the vector loop and the exit.
    //
    // EXTRACTED from vecReduxExit purely for the arm64 frame budget: inlined, it
    // needed 18096 bytes against a 16384 limit, because every IR value in a
    // function gets its own frame slot whether or not its live range overlaps
    // anything. Same wall, same workaround as the settings handler — and the
    // reason stack-slot colouring is worth building.
    IRValue* vecReduxEpilogue(IRFunc* fn, VecCand* c, IRValue* outV, Array* head)
        {
        IRValue* finalV = outV;
        // Epilogue part 2: the reduction lands between the vector loop and
        // the remainder, because the remainder's accumulator starts FROM it.
        IRBlock* H = c.h();
        IRBlock* E2 = c.e();
        IRBlock* H2 = _vecH2;
        IRBlock* B2 = _vecB2;
        IRBlock* PH = _vecPH;
        Map* cmap = _vecCmap;
        IRBlock* VE = new IRBlock(hoistName2(H.name(), "_vexit"));
        for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
            VE.add((IRInsn*)head.get(i));
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H2));
        VE.setTerm(br);

        // The vector loop exits to VE instead of E.
        IRInsn* t = H.term();
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() == E2)
                t.ops().set(k, (Object*)IROperand.block(VE));
            }

        // Seed the clone: iv enters at M, accumulator at the reduced total.
        Object* ivC = cmap.get((Hashable*)c.ivPhi().res());
        Object* accC = cmap.get((Hashable*)c.accPhi().res());
        for (u32 k = (u32)0; k < H2.phis().count(); k = k + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H2.phis().get(k);
            for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(q);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != PH)
                    continue;
                phi.ops().set(q, (Object*)IROperand.block(VE));
                if (accC != (Object*)0 && phi.res() == (IRValue*)accC)
                    phi.ops().set(q + (u32)1, (Object*)IROperand.useVal(outV));
                else if (ivC != (Object*)0 && phi.res() == (IRValue*)ivC)
                    phi.ops().set(q + (u32)1, c.rtTrip()
                                                  ? (Object*)IROperand.useVal(_vecRtM)
                                                  : (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
                }
            }
        if (accC != (Object*)0)
            finalV = (IRValue*)accC;

        u32 at = (u32)0;
        for (u32 k = (u32)0; k < fn.blocks().count(); k = k + (u32)1)
            if ((IRBlock*)fn.blocks().get(k) == c.b())
                at = k + (u32)1;
        Array* three = new Array();
        three.add((Object*)VE);
        three.add((Object*)H2);
        three.add((Object*)B2);
        fn.blocks().insertAll(at, three);
        return finalV;
        }

    void vecReduxExit(IRFunc* fn, VecCand* c, IRValue* vacc)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        IRValue* red = new IRValue(c.laneTy());
        IRInsn* rd = IRInsn.with(String.withCString("VReduceAdd"));
        rd.setRes(red);
        rd.add(IROperand.useVal(vacc));
        Array* head = new Array();
        head.add((Object*)rd);
        IRValue* outV = red;
        i32 initK = (i32)0;
        bool initIsZero = vecConst(c.seed(), defOf, &initK) && initK == (i32)0;
        if (!initIsZero)
            {
            IRValue* withInit = new IRValue(c.laneTy());
            IRInsn* ai = IRInsn.with(String.withCString("Add"));
            ai.setRes(withInit);
            ai.add(IROperand.useVal(red));
            ai.add(c.seed());
            head.add((Object*)ai);
            outV = withInit;
            }
        IRValue* finalV = outV;
        if (c.needEpi())
            finalV = vecReduxEpilogue(fn, c, outV, head);
        else
            {
            for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
                c.e().insns().insert(i, head.get(i));
            }

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            // The clone legitimately reads the original accumulator through its
            // own remapped values; rewriting inside it would point the remainder
            // at its own result.
            if (bb == c.h() || bb == c.b() || bb == _vecH2 || bb == _vecB2)
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                vecReplaceUse((IRInsn*)bb.phis().get(k), c.acc(), finalV, rd);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                vecReplaceUse((IRInsn*)bb.insns().get(k), c.acc(), finalV, rd);
            if (bb.term() != (IRInsn*)0)
                vecReplaceUse(bb.term(), c.acc(), finalV, rd);
            }
        }

    // Rewrite the reduction loop's body into vector form.
    void vecReduxBody(VecCand* c, IRBlock* B, IRValue* vacc)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == c.ivNext())
                {
                IROperand* a0 = (IROperand*)n.ops().get((u32)0);
                IROperand* a1 = (IROperand*)n.ops().get((u32)1);
                bool ivLeft = a0.kind() == (u8)OPK_USE && a0.val() == c.iv();
                IRInsn* add = IRInsn.with(String.withCString("Add"));
                add.setRes(n.res());
                add.add(ivLeft ? a0 : a1);
                add.add(IROperand.immI((i32)c.vw(), n.res().ty()));
                _vecBody.add((Object*)add);
                continue;
                }
            // vacc += vec(elem)
            if (n == c.accNext())
                {
                IRValue* vnext = new IRValue(_vecTy);
                IROperand* velem = vecSplatOperand(IROperand.useVal(c.elem()));
                IRInsn* va = IRInsn.with(String.withCString("VAdd"));
                va.setRes(vnext);
                va.add(IROperand.useVal(vacc));
                va.add(velem);
                _vecBody.add((Object*)va);
                _vecMap.set((Hashable*)n.res(), (Object*)vnext);
                continue;
                }
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                {
                _vecBody.add((Object*)n);
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                IRValue* vr = new IRValue(_vecTy);
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                vl.setRes(vr);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vl.add((IROperand*)n.ops().get(k));
                vl.setMemRes(n.memRes());
                _vecBody.add((Object*)vl);
                _vecMap.set((Hashable*)n.res(), (Object*)vr);
                continue;
                }
            // `x / d` with d a compile-time constant: mulhu(x, M) >>u s. The
            // magic comes from the candidate, derived when the loop was
            // recognised. There is no fallback — a UDiv reaching here that the
            // recogniser did not clear would mean the loop should never have
            // been accepted, and the only "generic" lowering available is a
            // vector UDiv that no back end implements.
            if (op.equals(String.withCString("UDiv")))
                {
                Object* mo = c.divMagic() == (Map*)0
                                 ? (Object*)0
                                 : c.divMagic().get((Hashable*)n.res());
                if (mo == (Object*)0)
                    {
                    _vecBody.add((Object*)n);
                    continue;
                    }
                Array* mg = (Array*)mo;
                u32 mm = ((Number*)mg.get((u32)0)).asU32();
                u32 ss = ((Number*)mg.get((u32)1)).asU32();
                IROperand* vm = vecSplatOperand(IROperand.immI((i32)mm, n.res().ty()));
                IROperand* vx = vecSplatOperand((IROperand*)n.ops().get((u32)0));
                IRValue* hi = new IRValue(_vecTy);
                IRInsn* mh = IRInsn.with(String.withCString("VMulHi"));
                mh.setRes(hi);
                mh.add(vx);
                mh.add(vm);
                _vecBody.add((Object*)mh);
                IRValue* qv = new IRValue(_vecTy);
                IRInsn* sr = IRInsn.with(String.withCString("VLShr"));
                sr.setRes(qv);
                sr.add(IROperand.useVal(hi));
                sr.add(IROperand.immI((i32)ss, n.res().ty()));
                _vecBody.add((Object*)sr);
                _vecMap.set((Hashable*)n.res(), (Object*)qv);
                continue;
                }
            IROperand* va = vecSplatOperand((IROperand*)n.ops().get((u32)0));
            IROperand* vb = vecSplatOperand((IROperand*)n.ops().get((u32)1));
            IRValue* vr = new IRValue(_vecTy);
            IRInsn* vop = IRInsn.with(vecOpFor(op));
            vop.setRes(vr);
            vop.add(va);
            vop.add(vb);
            _vecBody.add((Object*)vop);
            _vecMap.set((Hashable*)n.res(), (Object*)vr);
            }
        B.setInsns(_vecBody);
        }

    void vecReplaceUse(IRInsn* n, IRValue* old, IRValue* to, IRInsn* skip)
        {
        if (n == skip)
            return;
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() != (u8)OPK_USE || o.val() != old)
                continue;
            n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    // The simpler operand form the reduction paths use: an already-vectorised
    // value, else a broadcast made in the body. (The map path also hoists
    // invariant broadcasts to the entry block; the reduction path does not, and
    // the difference is the original's.)
    // A splat of a COMPILE-TIME CONSTANT belongs in the preheader, not the body:
    // it is the same vector on every iteration. `a[i] * 7` rebuilt the splat of
    // 7 every iteration — three instructions in int_muldiv's hot loop for a
    // constant. A non-constant operand still splats in the body, where it is
    // correct whether or not it is invariant.
    IROperand* vecSplatConst(i32 k)
        {
        Object* have = _vecSplatK.get((Hashable*)Number.withI32(k));
        if (have != (Object*)0)
            return IROperand.useVal((IRValue*)have);
        IRValue* cst = new IRValue(_vecSplatTy);
        IRInsn* cn = IRInsn.with(String.withCString("Const"));
        cn.setRes(cst);
        cn.add(IROperand.immI(k, _vecSplatTy));
        _vecSplatPH.insns().add((Object*)cn);
        IRValue* v = new IRValue(_vecTy);
        IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
        sp.setRes(v);
        sp.add(IROperand.useVal(cst));
        _vecSplatPH.insns().add((Object*)sp);
        _vecSplatK.set((Hashable*)Number.withI32(k), (Object*)v);
        return IROperand.useVal(v);
        }

    IROperand* vecSplatOperand(IROperand* op)
        {
        if (_vecSplatPH != (IRBlock*)0 && op.kind() == (u8)OPK_IMMI)
            return vecSplatConst((i32)op.imm());
        if (op.kind() == (u8)OPK_USE)
            {
            Object* vv = _vecMap.get((Hashable*)op.val());
            if (vv != (Object*)0)
                return IROperand.useVal((IRValue*)vv);
            if (_vecSplatPH != (IRBlock*)0)
                {
                i32 kv = (i32)0;
                if (vecConst(op, _vecSplatDefs, &kv))
                    return vecSplatConst(kv);
                }
            Object* sp = _vecSplat.get((Hashable*)op.val());
            if (sp == (Object*)0)
                {
                IRValue* v = new IRValue(_vecTy);
                IRInsn* s = IRInsn.with(String.withCString("VSplat"));
                s.setRes(v);
                s.add(op);
                _vecBody.add((Object*)s);
                _vecSplat.set((Hashable*)op.val(), (Object*)v);
                sp = (Object*)v;
                }
            return IROperand.useVal((IRValue*)sp);
            }
        IRValue* v = new IRValue(_vecTy);
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(v);
        s.add(op);
        _vecBody.add((Object*)s);
        return IROperand.useVal(v);
        }

    // The vector form of a scalar body operand: an already-vectorised value, an
    // entry-hoisted broadcast of a loop-invariant scalar, or a per-body VSplat.
    IROperand* vecOperandFor(IROperand* op, IRFunc* fn, IRBlock* entry, IRBlock* B,
                             VecCand* c, Map* defOf, Map* defBlk)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            Object* vv = _vecMap.get((Hashable*)op.val());
            if (vv != (Object*)0)
                return IROperand.useVal((IRValue*)vv);
            }
        IROperand* hoisted = vecEntrySplat(op, fn, entry, B, c, defOf, defBlk);
        if (hoisted != (IROperand*)0)
            return hoisted;
        if (op.kind() == (u8)OPK_USE)
            {
            Object* sp = _vecSplat.get((Hashable*)op.val());
            if (sp == (Object*)0)
                {
                IRValue* v = new IRValue(_vecTy);
                IRInsn* s = IRInsn.with(String.withCString("VSplat"));
                s.setRes(v);
                s.add(op);
                _vecBody.add((Object*)s);
                _vecSplat.set((Hashable*)op.val(), (Object*)v);
                sp = (Object*)v;
                }
            return IROperand.useVal((IRValue*)sp);
            }
        // An immediate: broadcast straight from it.
        IRValue* v = new IRValue(_vecTy);
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(v);
        s.add(op);
        _vecBody.add((Object*)s);
        return IROperand.useVal(v);
        }

    // Hoist a LOOP-INVARIANT operand's broadcast to the function ENTRY block.
    // Entry dominates every loop, including any enclosing one, so the splat is
    // materialised once on the way in rather than every iteration — and it stays
    // correct under nesting, which hoisting to a particular preheader does not.
    // Null when the operand is not provably entry-dominating; the caller then
    // keeps the in-body splat.
    IROperand* vecEntrySplat(IROperand* op, IRFunc* fn, IRBlock* entry, IRBlock* B,
                             VecCand* c, Map* defOf, Map* defBlk)
        {
        if (entry == (IRBlock*)0 || entry == B || entry == c.h())
            return (IROperand*)0;
        i32 kv = (i32)0;
        bool isConst = vecConst(op, defOf, &kv);
        String* ck = (String*)0;
        if (isConst)
            {
            ck = new String();
            ck.appendFormat("c%ld", kv);
            }
        else if (op.kind() == (u8)OPK_USE)
            {
            ck = vecValueKey(fn, op.val());
            }
        if (ck != (String*)0)
            {
            Object* hit = _vecEntryCache.get((Hashable*)ck);
            if (hit != (Object*)0)
                return IROperand.useVal((IRValue*)hit);
            }
        IROperand* scalar = (IROperand*)0;
        if (isConst)
            {
            IRValue* cst = new IRValue(c.laneTy());
            IRInsn* ci = IRInsn.with(String.withCString("Const"));
            ci.setRes(cst);
            ci.add(IROperand.immI(kv, c.laneTy()));
            entry.insns().add((Object*)ci);
            scalar = IROperand.useVal(cst);
            }
        else if (op.kind() == (u8)OPK_USE)
            {
            // A parameter has no defining instruction and is available at
            // entry; an entry-defined value dominates the rest of entry.
            // Anything defined mid-CFG cannot be named from entry. A nil
            // defBlk proves NOTHING beyond "absent when the map was built":
            // a value CREATED by vectorising an earlier loop (the new outer
            // phi carrying an induction var) is missing from the stale map,
            // and treating absent-as-param hoisted its splat to entry, where
            // it read default 0. Only a REAL param may hoist on nil.
            Object* db = defBlk.get((Hashable*)op.val());
            if (db != (Object*)0 && (IRBlock*)db != entry)
                return (IROperand*)0;
            if (db == (Object*)0)
                {
                bool isParam = false;
                for (u32 pi = (u32)0; pi < fn.params().count(); pi = pi + (u32)1)
                    if ((IRValue*)fn.params().get(pi) == op.val())
                        {
                        isParam = true;
                        break;
                        }
                if (!isParam)
                    return (IROperand*)0;
                }
            scalar = op;
            }
        else
            {
            return (IROperand*)0;
            }
        IRValue* sp = new IRValue(_vecTy);
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(sp);
        s.add(scalar);
        entry.insns().add((Object*)s);
        if (ck != (String*)0)
            _vecEntryCache.set((Hashable*)ck, (Object*)sp);
        return IROperand.useVal(sp);
        }

    // A stable key for a value, for the entry-splat cache. The original uses the
    // value id; ids here are stamped at print time, so identity is found by
    // position — params first, then each block's phis and instructions, which is
    // the same order the printer numbers in.
    String* vecValueKey(IRFunc* fn, IRValue* v)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            {
            if ((IRValue*)fn.params().get(i) == v)
                return vecKeyOf(n);
            n = n + (u32)1;
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                if (((IRInsn*)bb.phis().get(i)).res() == v)
                    return vecKeyOf(n);
                n = n + (u32)1;
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                if (((IRInsn*)bb.insns().get(i)).res() == v)
                    return vecKeyOf(n);
                n = n + (u32)1;
                }
            }
        return (String*)0;
        }

    String* vecKeyOf(u32 n)
        {
        String* s = new String();
        s.appendFormat("v%lu", n);
        return s;
        }

    // ── loop-rotate ──────────────────────────────────────────────────────
    //
    // A top-tested loop becomes bottom-tested: the header's guard is PEELED —
    // evaluated once on the preheader's values — and a copy of it moves to the
    // bottom of the body, where it drives a conditional back edge. The body
    // then costs one conditional branch per iteration instead of a branch to
    // the header plus a branch back.
    //
    // The header's phis move into the body (a rotated loop is entered only from
    // the preheader), and any carried value read after the loop gets an exit phi
    // in E covering both the peeled path and the loop path.
    void loopRotate(IRModule* m)
        {
        if (!_profile.loopRotate())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop at a time, re-recognised from the live CFG: a rotated
            // loop's back edge is conditional and no longer matches, so the
            // bound is only a backstop.
            u32 iter = (u32)0;
            while (iter < (u32)512 && rotOne(fn))
                iter = iter + (u32)1;
            }
        }

    IRBlock* _rotH;
    IRBlock* _rotB;
    IRBlock* _rotE;
    IRValue* _rotCond;

    bool rotOne(IRFunc* fn)
        {
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defBlk.set((Hashable*)n.res(), (Object*)bb);
                if (n.memRes() != (IRValue*)0)
                    defBlk.set((Hashable*)n.memRes(), (Object*)bb);
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            if (!rotRecognise(fn, (IRBlock*)fn.blocks().get(b), defBlk))
                continue;
            rotApply(fn);
            return true;
            }
        return false;
        }

    bool rotRecognise(IRFunc* fn, IRBlock* H, Map* defBlk)
        {
        _rotH = (IRBlock*)0;
        _rotB = (IRBlock*)0;
        _rotE = (IRBlock*)0;
        _rotCond = (IRValue*)0;
        if (H.phis().count() == (u32)0)
            return false;
        // A header carrying a VECTOR accumulator phi is an already-vectorised
        // loop; rotating it would duplicate that phi, which the backend's
        // in-place accumulate coalescing cannot represent.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && isVectorType(p.res().ty()))
                return false;
            }
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* cb = defBlk.get((Hashable*)c0.val());
        if (cb == (Object*)0 || (IRBlock*)cb != H)
            return false; // guard computed in H

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        if (t0 == (IRBlock*)0 || t1 == (IRBlock*)0 || t0 == t1)
            return false;
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
            return false;
        if (B == E || E == (IRBlock*)0)
            return false;

        // B's only predecessor is H, and H's are exactly the preheader and B.
        if (predsOfBlock(fn, B).count() != (u32)1)
            return false;
        Array* hp = predsOfBlock(fn, H);
        if (hp.count() != (u32)2 || !hasBlock(hp, B))
            return false;

        // Every header non-phi instruction is part of the guard: safe to
        // duplicate, referencing no B-defined value (the peeled copy must be
        // computable from preheader data), and with its result read only inside
        // H — otherwise the body would depend on something the rotation would
        // have to thread out.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (!rotDupSafe(n.op()))
                return false;
            for (u32 o = (u32)0; o < n.ops().count(); o = o + (u32)1)
                {
                IROperand* op = (IROperand*)n.ops().get(o);
                if (op.kind() != (u8)OPK_USE)
                    continue;
                Object* db = defBlk.get((Hashable*)op.val());
                if (db != (Object*)0 && (IRBlock*)db == B)
                    return false;
                }
            if (n.res() != (IRValue*)0 && rotUsedOutside(fn, n.res(), H, H))
                return false;
            }

        // Each header phi is a clean two-way merge.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            }

        // A header phi whose BACK-EDGE value is computed by a header guard is a
        // loop-carried recurrence the rotation cannot thread: the guard (e.g. the
        // `n - 1` of `while (n-- > 0)`) is duplicated, but the phi still reads the
        // original H-defined value, so the variable never advances and the loop
        // runs forever (bug 02). The condition modifies the induction variable, so
        // the "guard result used only in H" test above passes — the phi's own
        // back-edge use is in H — yet rotation is still unsound. Bail.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)p.ops().get(k);
                IROperand* vo = (IROperand*)p.ops().get(k + (u32)1);
                if (bo.blk() == B && vo.kind() == (u8)OPK_USE)
                    {
                    Object* db = defBlk.get((Hashable*)vo.val());
                    if (db != (Object*)0 && (IRBlock*)db == H)
                        return false;
                    }
                }
            }

        // If any carried value is read after the loop, an exit phi is
        // materialised in E — which then must have no phis of its own and must
        // be reached only from H before the rotation.
        bool anyEscape = false;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (rotUsedOutside(fn, p.res(), H, B))
                {
                anyEscape = true;
                break;
                }
            }
        if (anyEscape)
            {
            if (E.phis().count() != (u32)0)
                return false;
            Array* ep = predsOfBlock(fn, E);
            if (ep.count() != (u32)1 || (IRBlock*)ep.get((u32)0) != H)
                return false;
            }

        _rotH = H;
        _rotB = B;
        _rotE = E;
        _rotCond = c0.val();
        return true;
        }

    bool rotIsLatch(IRBlock* b, IRBlock* H)
        {
        if (b == (IRBlock*)0 || b == H || b.phis().count() != (u32)0)
            return false;
        if (b.term() == (IRInsn*)0 || !b.term().op().equals(String.withCString("Branch")) || b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    // Is `v` read anywhere outside blocks `x` and `y`?
    bool rotUsedOutside(IRFunc* fn, IRValue* v, IRBlock* x, IRBlock* y)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == x || bb == y)
                continue;
            if (unrollUsesValue(bb, v))
                return true;
            }
        return false;
        }

    // The guard must be safe to duplicate: pure value computation, or a plain
    // speculatable load — the peeled copy reads exactly what the header read on
    // entry, so duplicating a load adds no new access. No store, call, or other
    // side effect.
    bool rotDupSafe(String* op)
        {
        return op.equals(String.withCString("Const")) || op.equals(String.withCString("Copy")) || op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("Neg")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Not")) || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")) || op.equals(String.withCString("Rol")) || op.equals(String.withCString("Ror")) || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub")) || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FNeg")) || op.equals(String.withCString("FSqrt")) || op.equals(String.withCString("ICmp")) || op.equals(String.withCString("FCmp")) || op.equals(String.withCString("Select")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("Trunc")) || op.equals(String.withCString("Bitcast")) || op.equals(String.withCString("IntToPtr")) || op.equals(String.withCString("PtrToInt")) || op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI")) || op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp")) || op.equals(String.withCString("FpExt")) || op.equals(String.withCString("FpTrunc")) || op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("FieldAddr")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Load"));
        }

    void rotApply(IRFunc* fn)
        {
        IRBlock* H = _rotH;
        IRBlock* B = _rotB;
        IRBlock* E = _rotE;

        // 1. Each phi's (preheader init, back-edge next) operands.
        Array* phis = new Array();
        Array* initOp = new Array();
        Array* nextOp = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            phis.add((Object*)phi);
            IROperand* fromPH = (IROperand*)0;
            IROperand* fromB = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < phi.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)phi.ops().get(k);
                IROperand* vo = (IROperand*)phi.ops().get(k + (u32)1);
                if (bo.blk() == B)
                    fromB = vo;
                else
                    fromPH = vo;
                }
            initOp.add((Object*)fromPH);
            nextOp.add((Object*)fromB);
            }

        // 2. New body-resident phis: P_B = phi[(H, init), (B, next)]. The
        //    values come FIRST, because `next` may itself be one of H's phis —
        //    a tail-recursion parameter the loop never changes is lowered as
        //    `%p = Phi [(entry, arg), (latch, %p)]` — and step 7 removes H's
        //    phis, so such a `next` has to name the NEW phi or the operand is
        //    left dangling.
        Array* pbVals = new Array();
        Map* bMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)phis.get(i);
            IRValue* v = new IRValue(phi.res().ty());
            pbVals.add((Object*)v);
            bMap.set((Hashable*)phi.res(), (Object*)v);
            }
        // `next` in terms of the new phis (unchanged unless it named an old).
        Array* nextMapped = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IROperand* nx = (IROperand*)nextOp.get(i);
            Object* rm = nx.kind() == (u8)OPK_USE
                             ? bMap.get((Hashable*)nx.val())
                             : (Object*)0;
            nextMapped.add(rm == (Object*)0 ? (Object*)nx
                                            : (Object*)IROperand.useVal((IRValue*)rm));
            }
        Array* pbPhis = new Array();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRInsn* p = IRInsn.with(String.withCString("Phi"));
            p.setRes((IRValue*)pbVals.get(i));
            p.add(IROperand.block(H));
            p.add((IROperand*)initOp.get(i));
            p.add(IROperand.block(B));
            p.add((IROperand*)nextMapped.get(i));
            pbPhis.add((Object*)p);
            }

        // 3. In the body, this iteration's phi values become the new B-phis.
        rotRemapBlock(B, bMap);
        for (u32 i = (u32)0; i < pbPhis.count(); i = i + (u32)1)
            B.phis().insert(i, pbPhis.get(i));

        // 4. Clone the guard to the BOTTOM of the body FIRST — while H still
        //    references the phis — with each phi value replaced by its
        //    next-iteration value. This has to precede step 5, which rewrites
        //    H's operands to the preheader inits.
        Map* gMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IROperand* nx = (IROperand*)nextMapped.get(i); // mapped: see step 2
            if (nx.kind() == (u8)OPK_USE)
                gMap.set((Hashable*)((IRInsn*)phis.get(i)).res(), (Object*)nx.val());
            }
        IRValue* cB = rotCloneGuard(H, B, gMap);

        // 5. In H — now the peeled test — each phi value becomes its preheader
        //    init. That init may be an IMMEDIATE, so this substitutes operands
        //    rather than values.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE)
                    continue;
                for (u32 j = (u32)0; j < phis.count(); j = j + (u32)1)
                    if (((IRInsn*)phis.get(j)).res() == o.val())
                        {
                        n.ops().set(k, initOp.get(j));
                        break;
                        }
                }
            }

        // 6. The body's terminator is now the conditional back edge, in the
        //    same orientation the header's had.
        IRInsn* ht = H.term();
        IROperand* h1 = (IROperand*)ht.ops().get((u32)1);
        IROperand* h2 = (IROperand*)ht.ops().get((u32)2);
        IRInsn* bt = IRInsn.with(String.withCString("CondBranch"));
        bt.setPred(ht.pred());
        bt.add(IROperand.useVal(cB));
        bt.add(h1.blk() == B ? IROperand.block(B) : h1);
        bt.add(h2.blk() == B ? IROperand.block(B) : h2);
        B.setTerm(bt);

        // 7. H keeps its (now init-using) guard and branch; its phis are gone,
        //    since it is entered only from the preheader — the back edge is B→B.
        H.setPhis(new Array());

        // 8. Exit phis for the carried values read after the loop.
        rotExitPhis(fn, phis, initOp, nextMapped);
        }

    // Copy the header's guard to the bottom of the body, substituting each
    // phi's next-iteration value. Returns the copy of the condition — the value
    // the new conditional back edge tests.
    IRValue* rotCloneGuard(IRBlock* H, IRBlock* B, Map* gMap)
        {
        IRValue* cB = (IRValue*)0;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            IRInsn* cl = IRInsn.with(n.op());
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE)
                    {
                    cl.add(o);
                    continue;
                    }
                Object* r = gMap.get((Hashable*)o.val());
                cl.add(r == (Object*)0 ? o : IROperand.useVal((IRValue*)r));
                }
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                gMap.set((Hashable*)n.res(), (Object*)cl.res());
                if (n.res() == _rotCond)
                    cB = cl.res();
                }
            if (n.memRes() != (IRValue*)0)
                cl.setMemRes(new IRValue(String.withCString("Mem")));
            B.insns().add((Object*)cl);
            }
        return cB;
        }

    void rotExitPhis(IRFunc* fn, Array* phis, Array* initOp, Array* nextMapped)
        {
        IRBlock* H = _rotH;
        IRBlock* B = _rotB;
        IRBlock* E = _rotE;
        Array* exitPhis = new Array();
        Map* exitMap = new Map();
        for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
            {
            IRValue* pid = ((IRInsn*)phis.get(i)).res();
            if (!rotUsedOutside(fn, pid, H, B))
                continue;
            IRValue* v = new IRValue(pid.ty());
            // The B→E incoming is the carried value on the exit edge as
            // evaluated in B — already in terms of the new phis (step 2).
            IROperand* bInc = (IROperand*)nextMapped.get(i);
            IRInsn* ep = IRInsn.with(String.withCString("Phi"));
            ep.setRes(v);
            ep.add(IROperand.block(H));
            ep.add(initOp.get(i));
            ep.add(IROperand.block(B));
            ep.add(bInc);
            E.phis().insert((u32)0, (Object*)ep);
            exitPhis.add((Object*)ep);
            exitMap.set((Hashable*)pid, (Object*)v);
            }
        if (exitMap.count() == (u32)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(k);
                if (hasInsn(exitPhis, n))
                    continue;
                pivReplaceIn(n, exitMap);
                }
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.insns().get(k), exitMap);
            if (bb.term() != (IRInsn*)0)
                pivReplaceIn(bb.term(), exitMap);
            }
        }

    void rotRemapBlock(IRBlock* bb, Map* map)
        {
        for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
            pivReplaceIn((IRInsn*)bb.phis().get(k), map);
        for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
            pivReplaceIn((IRInsn*)bb.insns().get(k), map);
        if (bb.term() != (IRInsn*)0)
            pivReplaceIn(bb.term(), map);
        }

    // ── narrow-iv ────────────────────────────────────────────────────────
    //
    // A counted loop's induction variable is recomputed at the smallest width
    // that holds its range, so a 4-byte compare and increment become 1-byte on
    // an 8-bit target. Runs last, on the final loop shape; the dead-code sweep
    // after it drops the now-orphaned wide bound.
    void narrowIV(IRModule* m)
        {
        if (!_profile.narrowIV())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 guard = (u32)0;
            while (guard < (u32)256 && nivOne(fn))
                guard = guard + (u32)1;
            }
        }

    // The recognised loop, filled by nivShape.
    IRInsn* _nivPhi;
    IRInsn* _nivCmp;
    IRInsn* _nivAdd;
    IRBlock* _nivPre;
    IRBlock* _nivIncBlk;
    i32 _nivInit;
    i32 _nivStep;
    i32 _nivBound;
    u32 _nivNewW;
    String* _nivPred;

    bool nivOne(IRFunc* fn)
        {
        Map* defOf = defMap(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            if (!nivShape(fn, H, defOf))
                continue;
            if (!nivUsesOK(fn))
                continue;
            nivApply(fn, H);
            return true;
            }
        return false;
        }

    bool nivShape(IRFunc* fn, IRBlock* H, Map* defOf)
        {
        _nivPhi = (IRInsn*)0;
        _nivCmp = (IRInsn*)0;
        _nivAdd = (IRInsn*)0;
        _nivPre = (IRBlock*)0;
        _nivIncBlk = (IRBlock*)0;
        if (H.phis().count() == (u32)0)
            return false;
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)1)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* co = defOf.get((Hashable*)c0.val());
        if (co == (Object*)0)
            return false;
        IRInsn* cmp = (IRInsn*)co;
        if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() != (u32)2)
            return false;
        if (!hasInsn(H.insns(), cmp))
            return false; // the guard is computed in H
        String* pred = cmp.pred();
        if (pred == (String*)0)
            return false;
        if (!pred.equals(String.withCString("SLT")) && !pred.equals(String.withCString("SLE")) && !pred.equals(String.withCString("ULT")) && !pred.equals(String.withCString("ULE")))
            return false;
        IROperand* l = (IROperand*)cmp.ops().get((u32)0);
        if (l.kind() != (u8)OPK_USE)
            return false; // the iv is on the left
        IRValue* iv = l.val();

        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == iv)
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0 || ivPhi.ops().count() != (u32)4)
            return false;
        if (!isIntType(iv.ty()))
            return false;
        u32 curW = srWidth(iv.ty());

        i32 bound = (i32)0;
        if (!nivConst(defOf, (IROperand*)cmp.ops().get((u32)1), &bound) || bound < (i32)0)
            return false;

        // One incoming is the loop-entry init (a const >= 0), the other the
        // latch value Add(iv, step) with step > 0.
        IRBlock* ph = (IRBlock*)0;
        i32 c = (i32)0;
        i32 step = (i32)0;
        IRInsn* incAdd = (IRInsn*)0;
        bool haveInit = false;
        bool haveNext = false;
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
            {
            IROperand* blkOp = (IROperand*)ivPhi.ops().get((u32)2 * k);
            IROperand* useOp = (IROperand*)ivPhi.ops().get((u32)2 * k + (u32)1);
            if (blkOp.kind() != (u8)OPK_BLOCK || useOp.kind() != (u8)OPK_USE)
                return false;
            Object* dobj = defOf.get((Hashable*)useOp.val());
            if (dobj != (Object*)0)
                {
                IRInsn* d = (IRInsn*)dobj;
                if (d.op().equals(String.withCString("Add")) && d.ops().count() == (u32)2)
                    {
                    IROperand* a = (IROperand*)d.ops().get((u32)0);
                    IROperand* bb2 = (IROperand*)d.ops().get((u32)1);
                    i32 s = (i32)0;
                    bool formsInc = false;
                    if (a.kind() == (u8)OPK_USE && a.val() == iv && nivConst(defOf, bb2, &s))
                        formsInc = true;
                    else if (bb2.kind() == (u8)OPK_USE && bb2.val() == iv && nivConst(defOf, a, &s))
                        formsInc = true;
                    if (formsInc && s > (i32)0)
                        {
                        incAdd = d;
                        step = s;
                        haveNext = true;
                        continue;
                        }
                    }
                }
            if (!nivConst(defOf, useOp, &c) || c < (i32)0)
                return false;
            ph = blkOp.blk();
            haveInit = true;
            }
        if (!haveInit || !haveNext || ph == (IRBlock*)0 || incAdd == (IRInsn*)0)
            return false;

        i32 maxV = bound + step; // a safe upper bound on any value the iv holds
        u32 newW = maxV <= (i32)255 ? (u32)1 : (maxV <= (i32)65535 ? (u32)2 : (u32)4);
        if (newW >= curW)
            return false; // already minimal

        IRBlock* incBlk = (IRBlock*)0;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (hasInsn(((IRBlock*)fn.blocks().get(b)).insns(), incAdd))
                {
                incBlk = (IRBlock*)fn.blocks().get(b);
                break;
                }
        if (incBlk == (IRBlock*)0)
            return false;

        _nivPhi = ivPhi;
        _nivCmp = cmp;
        _nivAdd = incAdd;
        _nivPre = ph;
        _nivIncBlk = incBlk;
        _nivInit = c;
        _nivStep = step;
        _nivBound = bound;
        _nivNewW = newW;
        _nivPred = pred;
        return true;
        }

    // Every DIRECT use of the iv and of its next value must tolerate a narrower
    // one. The iv is an integer, so inside an ElementAddr it can only be the
    // index, never the base; a ZExt/SExt of it keeps the same logical value.
    // Anything else observes the wide bit pattern and refuses the narrowing.
    bool nivUsesOK(IRFunc* fn)
        {
        IRValue* iv = _nivPhi.res();
        IRValue* next = _nivAdd.res();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                if (!nivUseOK((IRInsn*)bb.phis().get(k), iv, next))
                    return false;
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                if (!nivUseOK((IRInsn*)bb.insns().get(k), iv, next))
                    return false;
            if (bb.term() != (IRInsn*)0 && !nivUseOK(bb.term(), iv, next))
                return false;
            }
        return true;
        }

    bool nivUseOK(IRInsn* n, IRValue* iv, IRValue* next)
        {
        bool wide = n.op().equals(String.withCString("ElementAddr")) || n.op().equals(String.withCString("ZExt")) || n.op().equals(String.withCString("SExt"));
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            if (o.val() == iv)
                {
                if (n != _nivCmp && n != _nivAdd && !wide)
                    return false;
                }
            else if (o.val() == next)
                {
                if (n != _nivPhi && !wide)
                    return false;
                }
            }
        return true;
        }

    void nivApply(IRFunc* fn, IRBlock* H)
        {
        String* nt = _nivNewW == (u32)1 ? String.withCString("U8")
                                        : String.withCString("U16");
        // The narrowed compare is unsigned: the range is known non-negative, so
        // a signed predicate over the narrow width would read the top bit as a
        // sign.
        String* np = _nivPred.equals(String.withCString("SLT"))
                         ? String.withCString("ULT")
                         : (_nivPred.equals(String.withCString("SLE"))
                                ? String.withCString("ULE")
                                : _nivPred);

        IRValue* oldIv = _nivPhi.res();
        IRValue* oldNext = _nivAdd.res();
        IRValue* newIv = new IRValue(nt);
        IRValue* newNext = new IRValue(nt);

        // The narrowed init constant, materialised in the preheader.
        IRValue* initC = new IRValue(nt);
        IRInsn* initI = IRInsn.with(String.withCString("Const"));
        initI.setRes(initC);
        initI.add(IROperand.immI(_nivInit, nt));
        _nivPre.insns().add((Object*)initI);

        IRInsn* nPhi = IRInsn.with(String.withCString("Phi"));
        nPhi.setRes(newIv);
        nPhi.add(IROperand.block(_nivPre));
        nPhi.add(IROperand.useVal(initC));
        nPhi.add(IROperand.block(_nivIncBlk));
        nPhi.add(IROperand.useVal(newNext));
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            if ((IRInsn*)H.phis().get(i) == _nivPhi)
                {
                H.phis().set(i, (Object*)nPhi);
                break;
                }

        IRInsn* nAdd = IRInsn.with(String.withCString("Add"));
        nAdd.setRes(newNext);
        nAdd.add(IROperand.useVal(newIv));
        nAdd.add(IROperand.immI(_nivStep, nt));
        for (u32 i = (u32)0; i < _nivIncBlk.insns().count(); i = i + (u32)1)
            if ((IRInsn*)_nivIncBlk.insns().get(i) == _nivAdd)
                {
                _nivIncBlk.insns().set(i, (Object*)nAdd);
                break;
                }

        nivRewriteGuard(H, np, nt, newIv);

        // The remaining direct uses — ElementAddr indices and the extensions.
        // The rebuilt phi / add / guard already name the new values.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                nivRemap((IRInsn*)bb.phis().get(k), oldIv, newIv, oldNext, newNext);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                nivRemap((IRInsn*)bb.insns().get(k), oldIv, newIv, oldNext, newNext);
            if (bb.term() != (IRInsn*)0)
                nivRemap(bb.term(), oldIv, newIv, oldNext, newNext);
            }
        }

    // Split out for the frame budget alone.
    void nivRewriteGuard(IRBlock* H, String* np, String* nt, IRValue* newIv)
        {
        IRInsn* nCmp = IRInsn.with(String.withCString("ICmp"));
        nCmp.setRes(_nivCmp.res());
        nCmp.setPred(np);
        nCmp.add(IROperand.useVal(newIv));
        nCmp.add(IROperand.immI(_nivBound, nt));
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if ((IRInsn*)H.insns().get(i) == _nivCmp)
                {
                H.insns().set(i, (Object*)nCmp);
                break;
                }
        }

    void nivRemap(IRInsn* n, IRValue* oldIv, IRValue* newIv,
                  IRValue* oldNext, IRValue* newNext)
        {
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE)
                continue;
            if (o.val() == oldIv)
                n.ops().set(i, (Object*)IROperand.useVal(newIv));
            else if (o.val() == oldNext)
                n.ops().set(i, (Object*)IROperand.useVal(newNext));
            }
        }

    // A constant through Const and the width casts that preserve a
    // non-negative value — including Bitcast, which the unroller's resolver
    // does not follow.
    bool nivConst(Map* defOf, IROperand* op, i32* out)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.ops().count() < (u32)1)
                return false;
            if (def.op().equals(String.withCString("Const")))
                {
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Bitcast")))
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    // ── const-hoist ──────────────────────────────────────────────────────
    //
    // Dedupe repeated float constants and (profile-gated) repeated
    // `AddrOf @sym`: the earliest occurrence moves to the front of the entry
    // block, which dominates everything, and the duplicates' uses point at it.
    // Unrolling and inlining are what replicate these in the first place, and
    // one definition lets the allocator home the value across the loop.
    void constHoist(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            chInFunc(m, (IRFunc*)m.funcs().get(f));
            chHoistMulImms((IRFunc*)m.funcs().get(f));
            }
        }

    // arm64 has no immediate form of `mul`, so every `x * K` in a loop body
    // pays a `mov wS, #K` to put the constant where the multiply can read it —
    // every iteration, once per multiply. call_depth's inlined body does four
    // of them for the same literal 3. Turning the immediate into a Const in the
    // PREHEADER gives it a value the allocator can home.
    void chHoistMulImms(IRFunc* fn)
        {
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(hi);
            IRInsn* term = H.term();
            if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch"))
                || term.ops().count() < (u32)3)
                continue;
            IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
            IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
            Array* body = chLoopBody(fn, H, t0, t1);
            if (body == (Array*)0)
                body = chLoopBody(fn, H, t1, t0);
            if (body == (Array*)0)
                continue;

            // The preheader is the header's predecessor that is NOT in the
            // body. Taking "not the entry block" instead picks the LATCH, which
            // is inside the loop, and plants the constant after its own uses.
            IRBlock* PH = (IRBlock*)0;
            u32 preds = (u32)0;
            for (u32 pi = (u32)0; pi < fn.blocks().count(); pi = pi + (u32)1)
                {
                IRBlock* p = (IRBlock*)fn.blocks().get(pi);
                if (p.term() == (IRInsn*)0) continue;
                for (u32 q = (u32)0; q < p.term().ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)p.term().ops().get(q);
                    if (o.kind() == (u8)OPK_BLOCK && o.blk() == H)
                        {
                        preds = preds + (u32)1;
                        if (!chHas(body, p))
                            PH = p;
                        }
                    }
                }
            if (PH == (IRBlock*)0 || preds != (u32)2 || PH == H)
                continue;
            chRewriteMuls(fn, body, PH);
            }
        }

    // Every block reachable from `entry` without going through `other`, when
    // that region closes back on H. nil when it escapes or is too large.
    Array* chLoopBody(IRFunc* fn, IRBlock* H, IRBlock* entry, IRBlock* other)
        {
        if (entry == (IRBlock*)0)
            return (Array*)0;
        Array* seen = new Array();
        Array* work = new Array();
        work.add((Object*)entry);
        bool closes = false;
        while (work.count() > (u32)0)
            {
            IRBlock* b = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            if (b == H) { closes = true; continue; }
            if (b == other || chHas(seen, b)) continue;
            if (b.term() == (IRInsn*)0) return (Array*)0;
            seen.add((Object*)b);
            if (seen.count() > (u32)8) return (Array*)0;
            for (u32 q = (u32)0; q < b.term().ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)b.term().ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0)
                    work.add((Object*)o.blk());
                }
            }
        if (!closes || seen.count() == (u32)0)
            return (Array*)0;
        return seen;
        }

    bool chHas(Array* a, IRBlock* b)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if ((IRBlock*)a.get(i) == b)
                return true;
        return false;
        }

    void chRewriteMuls(IRFunc* fn, Array* body, IRBlock* PH)
        {
        Map* made = new Map();
        for (u32 bi = (u32)0; bi < body.count(); bi = bi + (u32)1)
            {
            IRBlock* bb = (IRBlock*)body.get(bi);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!n.op().equals(String.withCString("Mul")) || n.res() == (IRValue*)0
                    || n.ops().count() < (u32)2)
                    continue;
                u32 side = (u32)2;
                if (((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_IMMI) side = (u32)1;
                else if (((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_IMMI) side = (u32)0;
                if (side == (u32)2)
                    continue;
                IROperand* imm = (IROperand*)n.ops().get(side);
                String* ity = imm.ty() == (String*)0 ? n.res().ty() : imm.ty();
                String* key = new String();
                key.appendFormat("%ld|%s", (i32)imm.imm(), ity.cString());
                Object* have = made.get((Hashable*)key);
                if (have == (Object*)0)
                    {
                    IRValue* cv = new IRValue(ity);
                    IRInsn* cn = IRInsn.with(String.withCString("Const"));
                    cn.setRes(cv);
                    cn.add(imm);
                    PH.insns().add((Object*)cn);
                    made.set((Hashable*)key, (Object*)cv);
                    have = (Object*)cv;
                    }
                n.ops().set(side, (Object*)IROperand.useVal((IRValue*)have));
                }
            }
        }

    void chInFunc(IRModule* m, IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);

        // Grouped by a value-equivalence key, in FIRST-APPEARANCE order: the
        // group order fixes the order the canonicals go in at the entry front,
        // so a hash-ordered walk would make the printed IR depend on hashing.
        Array* keys = new Array();   // String@
        Array* groups = new Array(); // Array@ of IRInsn@
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                String* key = chKeyFor(n);
                if (key == (String*)0)
                    continue;
                u32 gi = keys.count();
                for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
                    if (((String*)keys.get(k)).equals(key))
                        {
                        gi = k;
                        break;
                        }
                if (gi == keys.count())
                    {
                    keys.add((Object*)key);
                    groups.add((Object*)new Array());
                    }
                ((Array*)groups.get(gi)).add((Object*)n);
                }
            }

        Map* replace = new Map();
        Array* dead = new Array();
        Array* hoist = new Array();
        for (u32 gi = (u32)0; gi < groups.count(); gi = gi + (u32)1)
            {
            Array* g = (Array*)groups.get(gi);
            if (g.count() < (u32)2)
                continue;                           // only dedupe repeats
            IRInsn* canon = (IRInsn*)g.get((u32)0); // earliest occurrence
            hoist.add((Object*)canon);
            for (u32 i = (u32)1; i < g.count(); i = i + (u32)1)
                {
                IRInsn* dup = (IRInsn*)g.get(i);
                replace.set((Hashable*)dup.res(), (Object*)canon.res());
                dead.add((Object*)dup);
                }
            }
        if (hoist.count() == (u32)0)
            return;

        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            dead.add(hoist.get(i));
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = bb.insns().count(); i > (u32)0; i = i - (u32)1)
                if (hasInsn(dead, (IRInsn*)bb.insns().get(i - (u32)1)))
                    bb.insns().removeAt(i - (u32)1);
            }
        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            entry.insns().insert(i, hoist.get(i));

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.phis().get(k), replace);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                pivReplaceIn((IRInsn*)bb.insns().get(k), replace);
            if (bb.term() != (IRInsn*)0)
                pivReplaceIn(bb.term(), replace);
            }
        }

    // The value-equivalence key, or null when the instruction is not a
    // candidate. A float Const is keyed by its type and RAW BITS (the printer
    // spells them, so two literals that print alike are alike); an AddrOf is
    // keyed by symbol name and pointee spelling, because merging a Ptr(U8)
    // base into a Ptr(Agg) access would mis-size its stride.
    String* chKeyFor(IRInsn* n)
        {
        if (n.res() == (IRValue*)0 || n.ops().count() < (u32)1)
            return (String*)0;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        if (n.op().equals(String.withCString("Const")) && a.kind() == (u8)OPK_IMMF && n.res().ty() != (String*)0)
            {
            String* k = String.withCString("f:");
            k.append(n.res().ty());
            k.appendCString(":");
            if (a.fpHex() != (String*)0)
                k.append(a.fpHex());
            return k;
            }
        if (_profile.hoistGlobalAddr() && n.op().equals(String.withCString("AddrOf")) && a.kind() == (u8)OPK_SYM && n.res().ty() != (String*)0 && n.res().ty().hasPrefix(String.withCString("Ptr(")))
            {
            String* k = String.withCString("a:");
            k.append(a.name());
            k.appendCString(":");
            k.append(n.res().ty()); // carries pointee AND window
            return k;
            }
        return (String*)0;
        }

    // ── licm ─────────────────────────────────────────────────────────────
    //
    // Loop-invariant code motion: an instruction inside a loop whose operands
    // are all defined outside it (or already hoisted) moves to the preheader.
    // Field LOADS come too, but only when nothing in the loop writes memory.
    //
    // Termination is structural: each hoist moves instructions to the
    // preheader, which strictly dominates the header — strictly closer to the
    // entry in the dominator tree — so an instruction only ever moves toward
    // the root and can never re-enter a block it left. The 32-round cap is a
    // backstop, not the argument.
    void licm(IRModule* m)
        {
        if (!_profile.licm())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 pass = (u32)0;
            while (pass < (u32)32 && licmOnce(fn))
                pass = pass + (u32)1;
            }
        }

    bool licmOnce(IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return false;
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    {
                    defOf.set((Hashable*)n.res(), (Object*)n);
                    defBlk.set((Hashable*)n.res(), (Object*)bb);
                    }
                if (n.memRes() != (IRValue*)0)
                    defBlk.set((Hashable*)n.memRes(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() != (IRValue*)0)
                    defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            }
        Map* dom = dominators(fn);

        for (u32 li = (u32)0; li < fn.blocks().count(); li = li + (u32)1)
            {
            IRBlock* latch = (IRBlock*)fn.blocks().get(li);
            Array* ss = lrcSuccs(fn, latch);
            for (u32 s = (u32)0; s < ss.count(); s = s + (u32)1)
                {
                IRBlock* H = (IRBlock*)ss.get(s);
                Array* dl = (Array*)dom.get((Hashable*)latch);
                // A real back edge only: the header must DOMINATE the latch.
                // Without that test a forward edge into an earlier block —
                // which inlining and unrolling can produce — masquerades as one,
                // and the body walk either escapes into an outer preheader or
                // stops short of a real body block.
                if (dl == (Array*)0 || !hasBlock(dl, H))
                    continue;
                if (licmLoop(fn, H, latch, dom, defOf, defBlk))
                    return true;
                }
            }
        return false;
        }

    bool licmLoop(IRFunc* fn, IRBlock* H, IRBlock* latch,
                  Map* dom, Map* defOf, Map* defBlk)
        {
        // Natural loop body: every block reaching the latch without passing
        // through the header, plus the header itself.
        Array* body = new Array();
        body.add((Object*)H);
        Array* wl = new Array();
        wl.add((Object*)latch);
        while (wl.count() > (u32)0)
            {
            IRBlock* n = (IRBlock*)wl.get(wl.count() - (u32)1);
            wl.removeLast();
            if (hasBlock(body, n))
                continue;
            body.add((Object*)n);
            if (n == H)
                continue;
            Array* ps = lrcPreds(fn, n);
            for (u32 p = (u32)0; p < ps.count(); p = p + (u32)1)
                wl.add(ps.get(p));
            }

        // A unique preheader — the header's one predecessor outside the loop —
        // which, being the sole entry to a natural loop, dominates the header.
        Array* hp = lrcPreds(fn, H);
        IRBlock* pre = (IRBlock*)0;
        u32 outside = (u32)0;
        for (u32 p = (u32)0; p < hp.count(); p = p + (u32)1)
            {
            IRBlock* pb = (IRBlock*)hp.get(p);
            if (hasBlock(body, pb))
                continue;
            outside = outside + (u32)1;
            pre = pb;
            }
        if (outside != (u32)1)
            return false;
        Array* dh = (Array*)dom.get((Hashable*)H);
        if (dh == (Array*)0 || !hasBlock(dh, pre))
            return false;

        bool hasMemWrite = false;
        for (u32 i = (u32)0; i < body.count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)body.get(i);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                if (licmWritesMemory(((IRInsn*)bb.insns().get(k)).op()))
                    {
                    hasMemWrite = true;
                    break;
                    }
            if (hasMemWrite)
                break;
            }

        // Grow the hoist set to a fixpoint: an instruction joins once all its
        // operands are invariant, which can make the next one invariant too.
        // Blocks are visited in function order, so the result does not depend
        // on any set's iteration order.
        Array* hoist = new Array();
        Map* invariant = new Map();
        Map* inHoist = new Map();
        bool progress = true;
        while (progress)
            {
            progress = false;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (!hasBlock(body, bb))
                    continue;
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(k);
                    if (inHoist.get((Hashable*)n) != (Object*)0)
                        continue;
                    if (!licmHoistable(n, hasMemWrite, defOf))
                        continue;
                    bool inv = true;
                    for (u32 o = (u32)0; o < n.ops().count(); o = o + (u32)1)
                        if (!licmOpInvariant((IROperand*)n.ops().get(o), body,
                                             defBlk, invariant))
                            {
                            inv = false;
                            break;
                            }
                    if (!inv)
                        continue;
                    inHoist.set((Hashable*)n, (Object*)n);
                    hoist.add((Object*)n);
                    if (n.res() != (IRValue*)0)
                        invariant.set((Hashable*)n.res(), (Object*)n.res());
                    if (n.memRes() != (IRValue*)0)
                        invariant.set((Hashable*)n.memRes(), (Object*)n.memRes());
                    progress = true;
                    }
                }
            }
        if (hoist.count() == (u32)0)
            return false;

        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)hoist.get(i);
            IRValue* key = n.res() != (IRValue*)0 ? n.res() : n.memRes();
            Object* bo = defBlk.get((Hashable*)key);
            if (bo != (Object*)0)
                removeInsn((IRBlock*)bo, n);
            }
        // In dependency order, before the preheader's terminator (which the
        // block holds separately, so appending is enough).
        for (u32 i = (u32)0; i < hoist.count(); i = i + (u32)1)
            pre.insns().add(hoist.get(i));
        return true; // the CFG facts above are stale now; recompute next round
        }

    // Is this operand invariant for the loop? Anything not a use is; so is a
    // memory token (advisory in this loose model) and anything defined outside
    // the body or already marked to hoist.
    bool licmOpInvariant(IROperand* o, Array* body, Map* defBlk, Map* invariant)
        {
        if (o.kind() != (u8)OPK_USE)
            return true;
        if (o.val().ty() != (String*)0 && o.val().ty().equals(String.withCString("Mem")))
            return true;
        Object* db = defBlk.get((Hashable*)o.val());
        if (db == (Object*)0 || !hasBlock(body, (IRBlock*)db))
            return true;
        return invariant.get((Hashable*)o.val()) != (Object*)0;
        }

    // A field LOAD may move only when nothing in the loop writes memory;
    // everything else must be pure and speculation-safe.
    bool licmHoistable(IRInsn* n, bool hasMemWrite, Map* defOf)
        {
        if (n.op().equals(String.withCString("Load")))
            {
            if (hasMemWrite || n.ops().count() < (u32)1)
                return false;
            IROperand* a = (IROperand*)n.ops().get((u32)0);
            if (a.kind() != (u8)OPK_USE)
                return false;
            Object* pd = defOf.get((Hashable*)a.val());
            return pd != (Object*)0 && ((IRInsn*)pd).op().equals(String.withCString("FieldAddr"));
            }
        return licmPure(n);
        }

    // Pure and speculation-safe: no memory result, no side effect, no trap.
    // Const is excluded because it rematerialises cheaply and belongs to the
    // constant passes; the divides are excluded because they may trap.
    bool licmPure(IRInsn* n)
        {
        if (n.memRes() != (IRValue*)0)
            return false;
        String* op = n.op();
        if (op.equals(String.withCString("Const")) || op.equals(String.withCString("Phi")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SRem")) || op.equals(String.withCString("URem")))
            return false;
        return !licmIsTerminator(op);
        }

    bool licmIsTerminator(String* op)
        {
        return op.equals(String.withCString("Branch")) || op.equals(String.withCString("CondBranch")) || op.equals(String.withCString("Switch")) || op.equals(String.withCString("Return")) || op.equals(String.withCString("IndirectBranch")) || op.equals(String.withCString("Unreachable"));
        }

    bool licmWritesMemory(String* op)
        {
        return lrcWritesMemory(op) || op.equals(String.withCString("LoadVolatile"));
        }

    // ── const-operand-fold ───────────────────────────────────────────────
    //
    // Fold a constant RHS into an immediate, so the backend emits `ADC #k` /
    // `CMP #k` / `imul r,r,#k` directly instead of materialising the constant
    // into a register or slot and loading it back. Every backend's operand
    // loader already accepts an ImmI here.
    void constOperandFold(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            cofInFunc((IRFunc*)m.funcs().get(f));
        }

    void cofInFunc(IRFunc* fn)
        {
        Map* defOf = defMap(fn);
        bool changed = false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!cofFoldable(n.op()) || n.ops().count() < (u32)2)
                    continue;
                IROperand* rhs = (IROperand*)n.ops().get((u32)1);
                if (rhs.kind() != (u8)OPK_USE)
                    continue;
                i64 k = (i64)0;
                bool ku = false;
                if (!cofConst(defOf, rhs.val(), &k, &ku))
                    continue;
                String* immTy = rhs.val().ty();
                if (immTy == (String*)0)
                    continue;
                n.ops().set((u32)1, (Object*)mkImm(k, ku, immTy));
                changed = true;
                }
            }
        if (!changed)
            return;
        // Dead-strip the Const / ZExt / SExt / Trunc the fold detached, to a
        // fixpoint — removing a ZExt can orphan the Const behind it.
        //
        // NOT srSweepDead: that uses the broad pure set (Add, Mul, And, shifts,
        // AddrOf…) and so cascades into arithmetic the original's sweep leaves
        // alone. Harmless while the fold only orphaned conversions, but once it
        // follows Trunc the chains run deeper, and the two compilers then
        // number IR values differently — invisible on arm64, where registers
        // are allocated, and 793/793 differing on wasm32, whose locals are
        // named straight from value ids.
        cofSweepDead(fn);
        }

    // The fold's own dead-strip: exactly the four opcodes the original's sweep
    // considers, so both compilers orphan and remove the same instructions.
    void cofSweepDead(IRFunc* fn)
        {
        bool removed = true;
        while (removed)
            {
            removed = false;
            Map* used = new Map();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.phis().get(k));
                for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                    srNoteUses(used, (IRInsn*)bb.insns().get(k));
                if (bb.term() != (IRInsn*)0)
                    srNoteUses(used, bb.term());
                }
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = bb.insns().count(); i > (u32)0; i = i - (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i - (u32)1);
                    String* o = n.op();
                    bool pure = o.equals(String.withCString("Const"))
                             || o.equals(String.withCString("ZExt"))
                             || o.equals(String.withCString("SExt"))
                             || o.equals(String.withCString("Trunc"));
                    if (!pure)
                        continue;
                    if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
                        continue;
                    if (used.get((Hashable*)n.res()) != (Object*)0)
                        continue;
                    bb.insns().removeAt(i - (u32)1);
                    removed = true;
                    }
                }
            }
        }

    bool cofFoldable(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub")) || op.equals(String.withCString("And")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("ICmp")) || op.equals(String.withCString("Mul")) || op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr")) || op.equals(String.withCString("AShr")) || op.equals(String.withCString("UDiv")) || op.equals(String.withCString("SDiv")) || op.equals(String.withCString("URem")) || op.equals(String.withCString("SRem"));
        }

    // A compile-time integer through ZExt / SExt / Trunc of a Const.
    //
    // A TRUNC narrows the value, so each one is re-applied to the constant
    // afterwards (innermost first) in its own width and signedness. Without
    // this a narrowed literal never folds — which is what a shift count is,
    // since lowering gives the count its own narrow type — and the back end
    // then materialises the constant, homes it to a frame slot and extends it
    // before a shift the hardware takes as an immediate.
    bool cofConst(Map* defOf, IRValue* v, i64* out, bool* isU)
        {
        IRValue* cur = v;
        Array* truncBits = new Array();     // outermost first; negative = signed
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                i64 val = k.imm();
                u32 ti = truncBits.count();
                while (ti > (u32)0)
                    {
                    ti = ti - (u32)1;
                    i32 spec = ((Number*)truncBits.get(ti)).asI32();
                    i32 bits = spec < (i32)0 ? -spec : spec;
                    if (bits > (i32)0 && bits < (i32)64)
                        {
                        u64 mask = ((u64)1 << (u64)bits) - (u64)1;
                        u64 uv = (u64)val & mask;
                        if (spec < (i32)0
                         && (uv & ((u64)1 << (u64)(bits - (i32)1))) != (u64)0)
                            val = (i64)(uv | ~mask);
                        else
                            val = (i64)uv;
                        }
                    }
                out[0] = val;
                isU[0] = k.uimm();
                return true;
                }
            if (def.op().equals(String.withCString("Trunc")))
                {
                if (def.res() == (IRValue*)0 || def.ops().count() < (u32)1)
                    return false;
                String* rt = def.res().ty();
                u32 w = irWidth(rt);
                if (w == (u32)0 || w > (u32)8)
                    return false;
                i32 bits = (i32)((i32)w * (i32)8);
                bool sgn = rt.hasPrefix(String.withCString("I"));
                truncBits.add((Object*)Number.with(sgn ? -bits : bits));
                IROperand* tsrc = (IROperand*)def.ops().get((u32)0);
                if (tsrc.kind() != (u8)OPK_USE)
                    return false;
                cur = tsrc.val();
                continue;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }

    // A compile-time integer, through the widened-literal form.
    bool srConst(Map* defOf, IROperand* op, i64* out, bool* isU)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            out[0] = op.imm();
            isU[0] = op.uimm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE)
            return false;
        IRValue* cur = op.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* o = defOf.get((Hashable*)cur);
            if (o == (Object*)0)
                return false;
            IRInsn* def = (IRInsn*)o;
            if (def.op().equals(String.withCString("Const")))
                {
                if (def.ops().count() < (u32)1)
                    return false;
                IROperand* k = (IROperand*)def.ops().get((u32)0);
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                isU[0] = k.uimm();
                return true;
                }
            if (!def.op().equals(String.withCString("ZExt")) && !def.op().equals(String.withCString("SExt")) && !def.op().equals(String.withCString("Trunc")))
                return false;
            if (def.ops().count() < (u32)1)
                return false;
            IROperand* src = (IROperand*)def.ops().get((u32)0);
            if (src.kind() != (u8)OPK_USE)
                return false;
            cur = src.val();
            }
        return false;
        }
    }
