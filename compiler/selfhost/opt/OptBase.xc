// OptBase.xc — the IR optimiser, ported: its state and its lowest helpers.
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
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"

// The one host call this file makes: the pipeline's stop-after hook, which has
// to be readable from an installed compiler and not only from the harness.
u8* _xt_getenv(u8* name);

// The lowering's kernel printers, for the blocks the IR outliner makes (stage
// 4); 0 when nothing set it.
ParKernelHook* gParKernelHook;

// The C path (cpp-front-end.md): a C program's locals are allocas, pinned
// slots of a scalar or a pointer, which xc's lowering never makes (its
// scalars are SSA from the start). True when the module came from C: then
// mem2reg promotes such a slot too, where only loads and stores reach it.
bool gOptPromoteScalars;

// The IR outliner on for this compile without XC_PAR_PROPOSE: a C file
// built with --par-style=auto (the C path has no parser scan; the outliner is
// how its loops become blocks).
bool gOptOutline;

// The three switches above, as functions: a file compiled against Opt's
// interface (the split build) sees functions, not globals.
bool optOutline(void) { return gOptOutline; }
// The globals as functions, for the files compiled against this one's
// interface (a global is not in an interface).
bool optPromoteScalars(void) { return gOptPromoteScalars; }
ParKernelHook* optParKernelHook(void) { return gParKernelHook; }
u8* optGetenv(u8* name) { return _xt_getenv(name); }
void optSetOutline(bool b) { gOptOutline = b; }
void optSetPromoteScalars(bool b) { gOptPromoteScalars = b; }
void optSetParKernelHook(ParKernelHook* h) { gParKernelHook = h; }

// A sentinel count from lrcCountLiveOut: a value OTHER than the accumulator
// escapes the outer loop, so the collapse is unsafe. Distinct from 0, which
// means the accumulator itself is dead afterwards (nothing to rescale).
#import "OptDefs.xc"
// The constant splats a vectorised loop holds in registers before it
// splats the rest where they are used.
// A loop body larger than this (instructions) hoists none.

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
    bool _highMul;           // back end lowers VMulHi (constant divide)
    bool _laneShift;         // back end lowers VLShr (lane shift by a constant)
    bool _iota;              // back end can build the lane-index vector
    bool _escapeVec;         // back end has VFCmp and VSIToFp (escape-time loops)
    u32 _escapeJam;          // vectors an escape-time loop runs side by side (escapeInterleave)
    bool _floatReduce;       // FLOAT reductions may reassociate (arm64/x86-64)
    bool _orderedFloat;      // an ordered float sum: lanes added in order (arm64)
    bool _bitSelect;         // back end lowers VBsl and VRotl (arm64)
    bool _bitSelect512;      // ...at 64 bytes only (x86: vpternlogd, vprold)
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
    u32 _unrollMaxTotal;
    u32 _unrollMaxBody;
    u32 _unrollBudget;
    bool _unrollMultiCarried;
    bool _unrollCallsInBody;
    u32 _unrollFrameIds;
    bool _pointerIV;       // loop array addressing becomes an advancing phi
    bool _unrollVarTrip;   // …and a variable-trip loop partially unrolls
    bool _unrollChains;    // …and so does a loop of independent vector chains (#8)
    bool _devirtualise;    // a virtual call in a loop tests the receiver's class (OptDevirt)
    bool _selectBranch;    // a float Select whose arm computes, on one bit, is a branch (arm64)
    bool _licm;            // loop-invariant code moves to the preheader
    bool _hoistGlobalAddr; // …and a repeated AddrOf @sym dedupes to the entry
    bool _hoistLocalAddr;  // …and a repeated AddrOf of a pinned LOCAL (arm64)
    bool _hoistCmpImm;     // a loop's compare immediate cmp cannot encode → a Const (arm64)
    bool _floatMulToAdd;   // x*2 -> x+x and -k*x + c -> c - k*x (no fusing back end)
    bool _layoutHotPath;   // blocks ordered so the expected branch falls through
    bool _narrowIV;        // a counted IV is recomputed at its smallest width
    bool _ptr64;           // pointers are 8 bytes and threads exist (arm64, x86-64, win64): IR outlining runs blocks in parallel
    // Bytes in one vector register the vectoriser may use: 16 (SSE2 / NEON /
    // simd128) or 32 (AVX2, -mavx2). The lane count, remainder loop and unroll
    // factor key off it (SIMD step 1, S2); set from the driver's vector level.
    u32 _vectorLaneBytes;
    bool _simdDispatch;
    // Matrix kernels (--matmul): idiom-matmul puts a call to the back end's
    // kernel, prefix + "f32"/"f64" + suffix, in front of a matrix-multiply nest:
    // arm64 `__xt_sme_gemm_`, x86-64 `__xt_x86_gemm_` + `_<tier>`. 0: off.
    String* _matMulPrefix;
    String* _matMulSuffix;
    String* _matMulFastSuffix;  // appended under `:goal(speed)`: arm64 "_fast"
    bool _matMulInts;           // integer kernels too (prefix + "u32"/"i32"): arm64
    bool _loopRotate;      // top-tested loops become bottom-tested
    bool _loopRotateChain; // and loops whose test is a short-circuit chain
    u32 _inlineMax;        // the largest callee (IR instructions) the inliner splices
    bool _dceTrace;        // name each function dead-function elimination removes
    bool _inlineChecks;    // -fbounds-check=light: inline the subscript checks in loops after bounds-elide

    void init(void)
        {
        _vectorLaneBytes = (u32)16;
        _simdDispatch = false;
        _matMulPrefix = (String*)0;
        _matMulSuffix = String.withCString("");
        _matMulFastSuffix = (String*)0;
        _matMulInts = false;
        _inlineMax = (u32)64;
        _dceTrace = false;
        _inlineChecks = false;
        _nativeVarargs = false;
        _sqrtIntrinsic = false;
        _powSquare = false;
        _ifConvert = false;
        _inlineAggParams = false;
        _tailRecursion = false;
        _accumRecursion = false;
        _vectorize = false;
        _highMul = false;
        _laneShift = false;
        _iota = false;
        _escapeVec = false;
        _escapeJam = (u32)1;
        _floatReduce = false;
        _orderedFloat = false;
        _bitSelect = false;
        _bitSelect512 = false;
        _reductionCollapse = false;
        _memsetIdiom = false;
        _initGuardElim = false;
        _initGuardHoist = false;
        _unrollMaxTrip = (u32)4;
        _unrollMaxTotal = (u32)0;
        _unrollMaxBody = (u32)8;
        _unrollBudget = (u32)512;
        _unrollMultiCarried = false;
        _unrollCallsInBody = false;
        _unrollFrameIds = (u32)0;
        _pointerIV = false;
        _unrollVarTrip = false;
        _licm = false;
        _hoistGlobalAddr = false;
        _hoistLocalAddr = false;
        _hoistCmpImm = false;
        _floatMulToAdd = false;
        _layoutHotPath = false;
        _narrowIV = false;
        _loopRotate = false;
        _loopRotateChain = false;
        }

    u32 vectorLaneBytes(void) { return _vectorLaneBytes; }
    void setVectorLaneBytes(u32 n) { _vectorLaneBytes = n; }
    // Runtime SIMD dispatch (-msimd=auto): base code at vectorLaneBytes, plus
    // `<name>$avx2` clones at 32 that the runtime picks between at load.
    bool simdDispatch(void) { return _simdDispatch; }
    void setSimdDispatch(bool d) { _simdDispatch = d; }
    String* matMulPrefix(void) { return _matMulPrefix; }
    String* matMulSuffix(void) { return _matMulSuffix; }
    void setMatMul(String* prefix, String* suffix) { _matMulPrefix = prefix; _matMulSuffix = suffix; }
    String* matMulFastSuffix(void) { return _matMulFastSuffix; }
    void setMatMulFastSuffix(String* s) { _matMulFastSuffix = s; }
    bool matMulInts(void) { return _matMulInts; }
    void setMatMulInts(bool b) { _matMulInts = b; }
    bool inlineChecks(void) { return _inlineChecks; }
    void setInlineChecks(bool b) { _inlineChecks = b; }

    bool ptr64(void)
        {
        return _ptr64;
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
        // wasm32 joins them: passing an aggregate through linear memory costs a
        // copy the callee then reads field by field, and inlining lets the
        // fields stay values. Measured under Node over eight benchmarks: 13.9%
        // faster for eighteen bytes of module, almost all of it struct_copy,
        // which goes 2.8x. private:docs/bugs/238.
        p._inlineAggParams = t.equals(String.withCString("arm64"))
                          || t.equals(String.withCString("x86_64"))
                          || t.equals(String.withCString("win64"))
                          || t.equals(String.withCString("wasm32"));
        p._initGuardElim = true;
        p._ptr64 = t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64"))
                || t.equals(String.withCString("win64"));
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
        p._highMul = t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
        // ushr on arm64, psrlw/psrld/psrlq on x86. Separate from _highMul
        // because a back end can have the lane shift without the widening
        // multiply the magic divide needs.
        p._laneShift = t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
        // The lane-index vector is a 16-byte read-only global loaded with the
        // VLoad the back end already has, so this needs no instruction
        // selection of its own — only somewhere to put the constant.
        p._iota = p._laneShift;
        // The float lane compare and the int-to-float lane conversion the
        // escape-time loops need: fcm*/scvtf on arm64, cmpps/cvtdq2ps on x86.
        p._escapeVec = p._laneShift;
        p._escapeJam = t.equals(String.withCString("arm64")) ? (u32)4
                     : (t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"))) ? (u32)2 : (u32)1;
        // FLOAT reductions (a reassociation): only where the back end lowers
        // VDiv/VSqrt and a float VReduceAdd — arm64 and x86-64/win64. The
        // vectoriser also requires the source to grant it (see floatRedux).
        p._floatReduce = t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
        p._orderedFloat = t.equals(String.withCString("arm64"));
        // bsl/bit/bif and shl+usra on arm64. x86 would need AVX-512's
        // vpternlogd/vprold for a gain, and its AVX2 copies cannot use them.
        p._bitSelect = t.equals(String.withCString("arm64"));
        // AVX-512 has both as one instruction (vpternlogd 0xCA, vprold); the
        // AVX2 and SSE copies do not, so x86 combines 64-byte functions only.
        p._bitSelect512 = t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
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
            // A fully unrolled loop is ONE basic block, and every value it
            // computes is live inside it. matrix_mul's k loop is trip 32 over
            // a 9-instruction body: unrolled whole that is ~290 instructions
            // and ~160 short-lived values in one block, far past the register
            // pool, so every one of them round trips through the frame.
            // Measured, that loop runs 9.8ms fully unrolled and 3.1ms not.
            // Trip alone does not say this — trip 32 over a 2-instruction
            // body is fine. The product does, because it is what the
            // allocator sees.
            p._hoistLocalAddr = true;
            p._hoistCmpImm = true;
            p._layoutHotPath = true;
            p._unrollMaxTotal = (u32)128;
            p._unrollCallsInBody = true;
            p._unrollFrameIds = (u32)1900;
            }
        // x86-64 gets the local-address dedupe too. It is held back from the
        // base profile because it produces WRONG ANSWERS on xt6502 (bug 221,
        // cause undiagnosed) — but that is an xt6502 fault, not a reason to
        // keep it off a host back end. matrix_mul was emitting 32 copies of
        // `lea rax, [rbp-4112]`, one per unrolled copy, each spilled to its
        // own frame slot: 3.79x off clang -> 2.06x with them deduped.
        // win64 is the same back end and the reference runs it under the
        // x86-64 profile, so it takes this too. Leaving it out also turned off
        // the cross-block CSE that reads the same knob, and every win64 build
        // differed from the reference (bug 251).
        if (t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")))
            p._hoistLocalAddr = true;
        // x86-64 fuses no plain multiply-add (only :goal(speed) code, owner
        // 2026-10-26), so a product by 2 is cheaper as a sum, and a negated
        // product added to something is a subtraction. arm64 fuses both into
        // one instruction already and keeps them.
        if (t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")))
            p._floatMulToAdd = true;
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
        // wasm32 was off for "download size", which is the wrong side of the
        // trade: measured, the module grows 3.6% and the runtime drops 21.2%
        // (int_accum -45%, mem_copy -37%, hash_mix -35%). The engine does not
        // unroll for us, and a loop whose trip count it cannot see pays the
        // branch every iteration. private:docs/bugs/238.
        p._unrollVarTrip = t.equals(String.withCString("arm64")) || t.equals(String.withCString("arm9")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")) || t.equals(String.withCString("wasm32"));
        // A loop of several independent vector chains (v = v*k + c per chain)
        // unrolls on arm64, the copies regrouped chain by chain: each copy's
        // fmla then writes a register other than its multiplicand, two
        // instructions a step instead of three (#8: 8 chains on a Pi 5,
        // 42.5 GFLOPS bound by the moves).
        p._unrollChains = t.equals(String.withCString("arm64"));
        // Float Selects back to branches where an arm computes (#22: faster on
        // a Pi 5 and an M4 Max, OptSelectBranch.xc).
        p._selectBranch = t.equals(String.withCString("arm64"));
        // Guarded devirtualisation on the 64-bit targets (OptDevirt).
        p._devirtualise = t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
        // LICM is on for every live target, and so now is the global-address
        // hoist. It was off on wasm32 because a data address IS an i32 const —
        // true, and it still pays, just not in the column that was watched:
        // the const stops being re-materialised at each use, and every module
        // came out about 450 bytes smaller, 2.2%. Time is unchanged (0.1%,
        // noise). On a target where code size is download size that is the
        // whole argument. private:docs/bugs/238.
        p._licm = true;
        p._hoistGlobalAddr = true;
        // Narrowing the induction variable pays where the compare and the
        // increment get cheaper at a smaller width — the 8-bit and the 16-bit
        // targets. The 32-bit ones already compare at their natural width.
        p._narrowIV = t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")) || t.equals(String.withCString("atarist"));
        // Every live target rotates except the 6502.
        p._loopRotate = !(t.equals(String.withCString("xt")) || t.equals(String.withCString("xt6502")));
        // A test that is a short-circuit chain rotates on x86-64; on arm64
        // where the target row says (rotateChain: not on Apple's cores, where
        // the unrotated loop is as fast, measured on an M4 Max and an M3 Max;
        // on the Pi 5 sort_small's insertion loop goes 4.50 s -> 3.54 s, its
        // exit copies in an out-of-line stub).
        p._loopRotateChain = t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64"));
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
    bool orderedFloat(void)
        {
        return _orderedFloat;
        }
    bool bitSelect512(void)
        {
        return _bitSelect512;
        }

    bool bitSelect(void)
        {
        return _bitSelect;
        }
    bool floatReduce(void)
        {
        return _floatReduce;
        }
    bool highMul(void)
        {
        return _highMul;
        }
    bool laneShift(void)
        {
        return _laneShift;
        }
    bool escapeVec(void)
        {
        return _escapeVec;
        }
    // How many vectors an escape-time loop with a counted inner loop and no
    // reduction runs side by side, their chains interleaved: 4 on arm64 (32
    // vector registers), 2 on x86-64, 1 elsewhere. The reference's
    // escapeInterleave.
    u32 escapeJam(void)
        {
        return _escapeJam;
        }

    bool iota(void)
        {
        return _iota;
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
    // Cap on trip x body for a FULL unroll — the size of the single block that
    // results, which is what decides whether the allocator can hold it.
    // 0 = none.
    u32 unrollMaxTotal(void)
        {
        return _unrollMaxTotal;
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
    u32 inlineMax(void)
        {
        return _inlineMax;
        }
    bool dceTrace(void)
        {
        return _dceTrace;
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
    bool unrollChains(void)
        {
        return _unrollChains;
        }

    bool devirtualise(void)
        {
        return _devirtualise;
        }

    bool selectBranch(void)
        {
        return _selectBranch;
        }
    bool licm(void)
        {
        return _licm;
        }
    // Reorder blocks so a conditional branch's expected successor falls
    // through. Depends on the back end having a fallthrough peephole that can
    // invert a conditional, which arm64 has.
    bool layoutHotPath(void)
        {
        return _layoutHotPath;
        }

    // Separate from hoistGlobalAddr because it regresses xt6502.
    bool floatMulToAdd(void)
        {
        return _floatMulToAdd;
        }
    bool hoistLocalAddr(void)
        {
        return _hoistLocalAddr;
        }
    bool hoistCmpImm(void)
        {
        return _hoistCmpImm;
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
    bool loopRotateChain(void)
        {
        return _loopRotateChain;
        }
    void setLoopRotateChain(bool b) { _loopRotateChain = b; }
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
    i64 _start;   // 64-bit, as the reference's startVal: a u32 start of 2^31 or more stays positive
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
    i64 start(void)
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
    void setIv(IRInsn* phi, String* ty, i64 s, i32 st, u32 t)
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
    u32 _vecBytes; // vector width: 16, or 32 under -mavx2 (SIMD step 1, S2)
    // IOTA: the per-lane value is derived from the INDUCTION VARIABLE rather
    // than from a load, so the applier maps the iv to <i, i+1, i+2, i+3>
    // instead of splatting it. `acc += f(i)` with no array anywhere.
    bool _isIota;
    // Epilogue: when the trip count is not a whole number of vectors, the vector
    // loop stops at _epiM and a CLONE of the scalar loop runs the tail.
    bool _needEpi;
    // 64-bit, as the reference's int64_t: a u32 limit of 2^31 or more (a loop
    // to 2,200,000,000) truncated to a negative immediate, which the unroller
    // then read as "no positive bound" and left the loop alone (2026-11-01).
    i64 _epiM;

    void init(void)
        {
        _vw = (u32)0;
        _vecBytes = (u32)16;
        _needEpi = false;
        _epiM = (i32)0;
        _rtTrip = false;
        _bound = (IROperand*)0;
        _ivStart = (i64)0;
        _ivStartOp = (IROperand*)0;
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
    u32 vecBytes(void) { return _vecBytes; }
    void setVecBytes(u32 b) { _vecBytes = b; }
    u32 vw(void)
        {
        return _vw;
        }
    bool needEpi(void)
        {
        return _needEpi;
        }
    void setIota(bool v)
        {
        _isIota = v;
        }
    // An ordered float sum: the accumulator stays scalar and each vector's
    // lanes are added to it in order, so the result is the scalar loop's.
    bool _ordered;
    void setOrdered(bool v)
        {
        _ordered = v;
        }
    bool ordered(void)
        {
        return _ordered;
        }
    bool isIota(void)
        {
        return _isIota;
        }
    i64 epiM(void)
        {
        return _epiM;
        }
    void setEpi(bool need, i64 m)
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
    // vecRuntimeLimit. 64-bit: a u32 start of 2^31 or more is a constant, as
    // the reference's int64_t reads it, not a negative number.
    i64 _ivStart;
    // A RUNTIME iv entry value (a par chunk's `lo`): the loop does not start at
    // a literal, which used to refuse it outright. When set, the vector loop
    // begins at this value and the runtime limit is computed from
    // (bound - start). The value must be loop-invariant.
    IROperand* _ivStartOp;
    // A map's store and load bases that may overlap (#95), in pairs: the
    // preheader checks them and runs the whole range in the scalar clone
    // when a store lands within the vector loop's reach of a load.
    Array* _overlap;
    Array* overlap(void)
        {
        return _overlap;
        }
    void setOverlap(Array* a)
        {
        _overlap = a;
        }
    bool rtTrip(void)
        {
        return _rtTrip;
        }
    IROperand* bound(void)
        {
        return _bound;
        }
    i64 ivStart(void)
        {
        return _ivStart;
        }
    IROperand* ivStartOp(void)
        {
        return _ivStartOp;
        }
    void setIvStartOp(IROperand* o)
        {
        _ivStartOp = o;
        }
    void setRuntime(bool r, IROperand* b)
        {
        _rtTrip = r;
        _bound = b;
        }
    void setIvStart(i64 s)
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
    i64 _stepK;          // i64 like the reference: a bound over 2^31 wraps
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
        _stepK = (i64)0;
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
    i64 stepK(void)
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
    void setStep(IROperand* s, bool isK, i64 k)
        {
        _step = s;
        _stepIsConst = isK;
        _stepK = k;
        }
    }

    // IR outlining, stage 4: the kernels. The printers live in the lowering,
    // which has printed every block it made by the time the optimiser runs;
    // for the blocks the outliner makes it hands the optimiser this hook (a
    // subclass of it) and the optimiser calls it with them.
    class ParOutBlock
    {
    String* _cls;       // ParImpl$o<n>: the name the printers know the block by
    Array* _fieldTypes; // the record's types from field 3 on: the captures, then the accumulators

    static ParOutBlock* with(String* cls, Array* types)
        {
        ParOutBlock* b = new ParOutBlock();
        b._cls = cls;
        b._fieldTypes = types;
        return b;
        }
    String* cls(void)        { return _cls; }
    Array* fieldTypes(void)  { return _fieldTypes; }
    }

    class ParKernelHook
    {
    void print(IRModule* m, Array* blocks)
        {
        }
    }

// bounds-elide: what a guard's edge says of one value, as a closed range.
class BeFact : Object
    {
    IRValue* _v;
    i64 _lo;
    i64 _hi;
    }

// gpu-globals: the size from which a numeric global array gets pages of its
// own (rt.c's threshold for a heap array), and the page it is aligned to
// (16 KB covers Apple silicon's pages as well as 4 KB ones).

    class Opt
    {
    u32 _level;
    Map* _vecRemainders;   // vectorize: the remainder loops it made, this function
    Map* _raDefIn;   // reassociate: the current block's defining insn per value
    Map* _raUses;    // reassociate: the function's use count per value, 0 after a rewrite
    Array* _raPhis;  // reassociate: the function's phi results, with _raUses
    u32 _vecFnBytes; // the vectorised function's own width (a dispatch clone), else 0
    OptProfile* _profile;
    bool _inlineChecks; // inline: only the subscript checks (after bounds-elide)
    bool _failed;
    String* _why;
    // Stop after the named pass — the per-pass oracle. Without it a pass can
    // only be measured once every pass before it in the pipeline is ported,
    // which makes a twenty-pass level all-or-nothing.
    String* _stopAfter;
    Array*  _seen;          // every pass name stopHere was offered, in order

    // Library build (--emit-lib): the whole module is the API surface, so
    // dead-function-elim seeds EVERY function (the twin of the oracle's
    // +[XTIROptDeadFunctionElim setKeepAllFunctions:]).
    bool _keepAllFunctions;
    // A program whose link takes objects as well (-Wl,foo.o, $XTC_LDFLAGS):
    // keep the class-name root `_xtc_class_new`, which those objects call
    // though nothing in this module does (bug 605). The twin of the oracle's
    // +[XTIROptDeadFunctionElim setKeepClassRoot:].
    bool _keepClassRoot;

    u32 _escTrips;     // the variant copy's trips per escape test (Lower.parKernelModule), 0: off
    Array* _escChanged; // of String*: the functions whose loops gpuEscapeTrips changed

    // What `readVaSlot` reports back alongside the value it produced: how far
    // the cursor moves, and which memory token the cursor's store follows.
    u32 _vaAdvance;
    IRValue* _vaMem;

    // The Truncs this narrowing has to insert ahead of the op.
    Array* _narrowInserts;

    // A multiply by a constant of a value plus constants, `(b + c) * k`, where
    // another such product (or b * k itself) has the same b and k: each
    // becomes `b * k + c * k`, so CSE leaves one multiply for the group
    // (call_depth's inlined leaf(x) .. leaf(x + 3)). As the reference's
    // distributeMulsIn. simpPeel: the base and the constant sum of an Add/Sub
    // chain with constants, true when there was at least one step.
    IRValue* _peelBase;
    i64 _peelSum;

    // ── vec-combine ──────────────────────────────────────────────────────
    //
    // The vectoriser's output, two shapes made one op where the back end has
    // it (bitSelect: arm64):
    //   VOr(VShl(x, c), VLShr(x, w - c))          → VRotl x, c
    //   VOr(VAnd(m, a), VAnd(VNot(m), b))         → VBsl m, a, b
    //   VXor(b, VAnd(m, VXor(a, b)))              → VBsl m, a, b
    // (the last is the xor form of the same select, md5_mask's F and G) with
    // either operand of an Or, Xor or And in either place (MD5's F is the
    // second as written, its G with the Not on the other side; every round's
    // rotate the first). Each inner node must have this one use and be in the
    // same block. The nodes a match consumed go with it (dead-code keeps
    // vector ops).
    // Then, in a big block (over VEC_SPLAT_BIG_BODY, where the vectoriser
    // splats each constant where it is used), the integer constants' splats
    // become loads from a read-only table, `__xtv_kpool_<fn>_<block>`: one
    // `ldr q` each, against `movz, movk, dup` (MD5's 64 round constants).
    // That step runs late (vec-pool, before the final dead-code) with the
    // table's address an AddrOf at the block's top. As the reference's
    // XTIROptVecCombine (its pool instance).
    Array* _vcDead;

    // Everything the transform needs to know about one iterated return.
    Array* _trBlocks;   // IRBlock@  — the block the return lives in
    Array* _trCalls;    // IRInsn@   — the self call
    Array* _trCombines; // IRInsn@ or 0 — Tier-2's ⊕
    Array* _trGIdx;     // Number@   — which combine operand is `g`


    // ── mem2reg ──────────────────────────────────────────────────────────
    //
    // Scalar replacement of aggregates, in the only shape the IR actually
    // produces: a pinned local reached exclusively through
    // `AddrOf` -> `FieldAddr(base, constant)` -> scalar Load/Store. Each field
    // becomes an independent SSA variable — phis at the iterated dominance
    // frontier of the blocks that store it, renamed by a walk of the dominator
    // tree — and the loads and stores disappear.
    //
    // Runs after agg-expand, which is what turns whole-aggregate traffic into
    // the per-field form this recognises.
    //
    // Nothing here depends on how the dominator tree is BUILT, only on the
    // idom relation, which is a fact about the CFG. Every traversal runs in
    // block DECLARATION order, which is the one ordering both compilers can
    // reproduce without sharing an implementation — and the order decides
    // which value id each phi gets, so it is not cosmetic.
    Array* _m2rLocal;   // IRValue@  the pinned local of each variable
    Array* _m2rField;   // Number@   its field index
    Array* _m2rType;    // String@   its field type
    Map* _m2rPtrVar;    // FieldAddr result -> Number(variable)
    Array* _m2rBad;     // Number@   1 when the variable was given up on
    Map* _m2rPhis;      // IRBlock*  -> Array of IRInsn@ this pass added
    Map* _m2rPhiVar;    // IRBlock*  -> Array of Number (parallel)
    Map* _m2rValueMap;  // promoted load result -> IROperand@ it now names
    Array* _m2rDead;    // IRInsn@   loads and stores to delete
    Map* _m2rKids;      // IRBlock*  -> dominator-tree children
    Map* _m2rPreds;     // IRBlock*  -> predecessors
    Map* _m2rIdom;      // IRBlock*  -> immediate dominator

    // A C local's value before it is written (gOptPromoteScalars): a zero of
    // its type, made once per function at the top of the entry block. In a
    // dry run, only a stand-in operand.
    Map* _m2rUndefs;

    // The recognised diamond, reported through fields: the language has no
    // tuple return that would read better here.
    IRBlock* _icH;
    IRBlock* _icT;
    IRBlock* _icF; // the SECOND arm, for a full if-then-else diamond; 0 for a triangle
    IRBlock* _icJ;
    IRValue* _icCond;
    bool _icTIsTrue;
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
    // ── bounds-elide ─────────────────────────────────────────────────────
    //
    // A checked build's subscript checks that cannot fail come out, so a loop
    // over a fixed-size array is the loop an unchecked build has (a call in a
    // loop keeps it scalar, and kept matrix_mul_f32 off its SME kernel).
    // `_xt_check_bounds_n(p, i, count, site)` goes when i's range is inside
    // [0, count). The ranges are intervals: a value's type gives the widest,
    // its definition narrows it (constants, the width casts, + - * << >> & %
    // and / by constants, a loop phi from its entries when its back edges only
    // add or only subtract), and the guards on the way in narrow it again: an
    // edge `ICmp <pred> v, c` into a block with no other way in says v < c,
    // v >= c and so on in every block that edge dominates. Arithmetic that
    // could wrap gives up (the type's range). The `for (i in 0..N) a[i]` loop
    // over `T a[N]`, a nest's `a[i * M + k]`, and an insertion sort's
    // `a[j - 1]` under `j > 0` all prove.
    Map* _beDef;        // value -> defining insn (phis included)
    Map* _beVisit;      // phis being ranged (a cycle reads as the type's range)
    Array* _beFacts;    // BeFact@ that hold in the check's block

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
    // ── idiom-matmul ─────────────────────────────────────────────────────
    //
    // A dense matrix multiply
    //   for i < M: for j < N: { s = 0.0; for k < K: s = s + A[i*lda+k] * B[k*ldb+j];
    //                           C[i*ldc+j] = s; }
    // (F32 or F64) gets a call to the back end's SME kernel in front of it:
    //   %done = Call @__xt_sme_gemm_f32(A, B, C, M | N<<32, K, lda, ldb, ldc)
    //   CondBranch %done, <nest exit>, <nest>
    // The nest stays as the fallback. Only the canonical shape lowering gives
    // (ICmp ULT iv, bound; body on the true edge), so it matches exactly what the
    // reference's XTIROptIdiomMatMul matches. private:docs/Design/simd-sme-plan.md.
    IRBlock* _mxPre;
    IRBlock* _mxHead;
    IRBlock* _mxExit;
    bool _mmF64;
    String* _mmElem;     // "f32", "f64", "u32" or "i32": the element type, and the kernel's name
    IROperand* _mxM;
    IROperand* _mxN;
    IROperand* _mxK;
    IROperand* _mxLda;
    IROperand* _mxLdb;
    IROperand* _mxLdc;
    IROperand* _mxA;
    IROperand* _mxB;
    IROperand* _mxC;
    // A base that is a global's address taken inside the nest: the call in the
    // preheader takes its own AddrOf (the reference's addrA/B/C), or 0.
    IRInsn* _mxAddrA;
    IRInsn* _mxAddrB;
    IRInsn* _mxAddrC;
    // Where the i loop starts when that is not 0 (a par tile's lo), else 0;
    // the element pointer type, for advancing A and C to that row.
    IROperand* _mxStart;
    String* _mxPtrTy;
    bool _mxTakeStart;   // mmCountedHeader may accept a nonzero start (into _mxStartOf)
    IROperand* _mxStartOf;
    IRValue* _mxMem;
    IRInsn* _mxAcc;      // the k loop's FAdd, marked `contract` (0 for an integer nest)
    // The constant value of each of M, N, K, lda, ldb, ldc, or -1 (a value).
    i64* _mxConsts;
    // countedHeader's outputs
    IRInsn* _mxIv;
    IROperand* _mxBound;
    IRBlock* _mxBody;
    IRBlock* _mxExitOf;
    IRBlock* _mxPreOf;

    // index = Add(Mul(p, q), r) in either order: the Mul, and the addend in _mxAddend.
    IROperand* _mxAddend;

    // A store's address as a key, when it is a function's own local reached
    // by constant field and element steps (`q.x`, `a[2]`); 0 for anything
    // else (a global, a pointer from anywhere, a variable index), so a store
    // through memory the program does not own here, a volatile one or a
    // device register, is never touched. As the reference's XTIRDSEKey.
    // The locals a function's dead-store keys name, numbered on first sight
    // (an IRValue's pid is not unique among a frame's pinned locals).
    Map* _dseLocals;
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

    // Defining instruction per value, so the alias test can look through a
    // pointer to the FieldAddr that produced it.
    Map* _cseDefOf;

    bool _cseCrossBlock;
    bool _cseLate;

    // ── par-propose (report) ─────────────────────────────────────────────
    //
    // IR Propose, step 1 (cpp-front-end.md, c-and-cpp-one-path.md): find the
    // loops --par-style=auto would make blocks of, in the IR rather than the
    // parser's tokens, so loops from C and C++ are found the same way. For
    // now a REPORT only, beside the parser's scan, until the two choose the
    // same loops on the xc corpus: XC_PAR_PROPOSE=report lowers with source
    // lines (and no -g pinning, so locals are SSA) and prints, after mem2reg,
    //   propose: <file>:<line>: wrap
    //   propose: <file>:<line>: no (<why>)
    // for each outermost natural loop outside the standard library.
    IRModule* _ppModule;

    // ── IR outlining, stage 1 ───────────────────────────────────────────
    // Every outermost loop Propose would wrap is cut out of its function into
    // `ParOut$<n>$run`, whose parameters are the values the loop reads from
    // outside it (and the memory token), and replaced by one call. Serial: no
    // runtime and no range split yet. Taken only where the cut is clean: one
    // exit, a preheader that branches straight in, one memory token in and at
    // most one out, and at most one other value live after the loop (a
    // reduction's result, or the induction variable), which the function
    // returns. Stage 2's serial half: several results, and the merge of
    // partial results, come with the block's class (stage 3).
    u32 _ppOutN;
    Array* _ppMade;     // ParOutBlock@: the blocks made, for the kernel printers
    bool _ppOutlined;   // the outliner has run (the runtime need not be kept for it)
    i64 _ppRowC;
    i64 _ppRowLo;
    i64 _ppRowHi;

    Map* _ppDefBlk;

    Map* _ppLabels;     // block labels given so far (file:line), how many each
    String* _ppWhere;      // the loop being tried, for the trace
    IRValue* _ppLastMem;   // the memory token the last ppCtxLoad / ppCall produced

    IRValue* _ppRangeLo;
    IRValue* _ppRangeHi;

    // The base an address is an element of, as a key: "@sym" for a global
    // (AddrOf), the value itself otherwise; and whether the index is the
    // induction variable (through a widening or narrowing of it).
    String* _ppKey;
    bool _ppAtIv;
    IRValue* _ppBase;    // the base value: the AddrOf's result, or the pointer
    String* _ppAddrTy;   // the element pointer's type (a field's element's, for a field)
    // Where an access is the iteration's own: element k * i + c for a c in
    // [c0, c1] ([i + c]: k = 1, c0 = c1 = c; a row: k = C, [c0, c1] in
    // [0, C)), as _ppOff (k) and _ppOffLo / _ppOffHi.
    i64 _ppOff;
    i64 _ppOffLo;
    i64 _ppOffHi;

    // The arrays a loop touches, as ppParMemoryOk found them: a key each
    // ("@sym" for a global, else the base value's), the base (the AddrOf or
    // the pointer value), the element's size, whether every access is at [i]
    // and whether the loop stores to it.
    Array* _ppGKeys;
    Array* _ppGBase;
    Array* _ppGElem;
    Array* _ppGAtIv;
    Array* _ppGOff;     // Number@: each array's k (elements per iteration)
    Array* _ppGOffLo;   // Number@: and the c0, c1 of k * i + [c0, c1]
    Array* _ppGOffHi;
    Array* _ppGStored;
    Array* _ppGUncond;     // Number@: 1 while every access of the base is made on every iteration
    bool _ppUncond;        // the access being noted is (its block dominates the loop's latch)
    bool _ppEarlyExit;     // the loop can leave from a block other than its header
    Map* _ppFpDefOf;       // ppParMemoryOk's defOf, for ppFootprintOf
    // The pairs that need a check at run time (indices into the above).
    Array* _ppPairA;
    Array* _ppPairB;

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
    Map* _lrcUses;        // the function's use counts (lrcAddLeaves)

    // What the induction analysis found. Ivars, not locals: the arm64 backend
    // budgets 16 KB of frame per function and the recogniser is over it whole.
    bool _luBodyHasCall;
    IRInsn* _luIvPhi;
    IRBlock* _luPre;
    i64 _luInit;
    i32 _luStep;
    u32 _luTrip;
    Array* _luCarried;

    // The loop's header phi, its single-block latch, its preheader and its
    // constant step — set when pivShape succeeds.
    IRInsn* _pivIvPhi;
    IRBlock* _pivLatch;
    IRBlock* _pivPre;
    i32 _pivStep;

    // The invariant terms pivAffIdx found, indexed from its result.
    Array* _pivInvs;

    bool _srFloatMul; // the float multiply rewrites (set for the main pipeline)

    // Set for par kernels only: unroll a loop only when its constant trip is
    // a whole number of groups, so no copy needs a guard. A GPU pays for the
    // guards more than for the back edge they save (nbody's inner loop on the
    // Pi 5's V3D: 110.7 ms rolled, 32.5 ms in exact groups, 270.8 ms guarded).
    bool _vtExactOnly;

    // Par kernels only: fold EVERY static-init guard (the reference's
    // foldAll explains).
    bool _sgFoldAll;

    IRInsn* _ucIv;         // unrollChainLoops: the counter phi, its add and its compare
    IRInsn* _ucNext;
    IRInsn* _ucCmp;
    IRBlock* _ucPre;       // …and, for an odd trip, the block that runs one step first
    Map* _apDefs;          // arcPairElide: a function's definitions, its phis' blocks,
    Map* _apPhiBlock;
    IRBlock* _apRelBlock;  // and the block of the release apFindRelease found
    u32 _sbSeq;            // selectBranch: its block names' counter
    bool _ppStayPut;       // ppOutlinePar: the loop is too small to outline at all
    Map* _dvVt;            // devirtualise's indexes for one run: vtables and functions by name,
    Map* _dvFn;
    Map* _dvLay;           // a receiver type's class (the module itself: none),
    Map* _dvCand;          // and a slot and type's candidates
    Array* _dvDone;        // devirtualise: the sites already rewritten (each keeps its dispatch)
    u32 _dvSeq;            // its block names' counter
    IRModule* _dvModule;

    IRInsn* _vtIvPhi;
    IRInsn* _vtGuard;
    IRValue* _vtIv;
    IRBlock* _vtB;
    IRBlock* _vtE;

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
    // ── outer-vectorize ──────────────────────────────────────────────────
    //
    // `for j { s = 0; for k { s += f(k, j) } out[.. + j] = g(s) }`: four
    // neighbouring j are four lanes of one vector (the reference explains).
    // Roles: 0 uniform (scalar), 1 index (j + uniform), 2 lane-0 address,
    // 3 vector.
    Map* _ovRole;

    // The array a pointer derives from: a local value (returned), or a
    // global, whose name is left in _ovRootName (and 0 returned with it set).
    String* _ovRootName;

    // ── ESCAPE-TIME loops (2026-10-22). A counted loop over pixels whose body
    // runs an inner loop until a per-pixel condition fails — mandelbrot's
    //
    //     for (i = s; i < N; i++) {
    //         <lane arithmetic on i>
    //         while (k < 256 && x*x + y*y < 4) { <lane arithmetic> }
    //         total += k;
    //     }
    //
    // goes across pixels: VF of them a step, each a lane. The inner loop runs
    // with a lane mask: a lane whose condition has failed keeps its values
    // (a blend), and the loop leaves when no lane is left. The scalar loop
    // stays, as the remainder after the last whole step.
    //
    //   PH:  splats, the iota, the zero sums                 -> VH
    //   VH:  viv; vsum… ; viv <= N - VF ?                    -> VB / VX
    //   VB:  <i, i+1, …>, the pixel's lane arithmetic         -> VI
    //   VI:  values, mask; tests, body, blends; any lane?    -> VI / VE
    //   VE:  vsum += w; viv += VF                            -> VH
    //   VX:  sum = entry + reduce(vsum)                      -> H (the scalar loop)
    //
    // Every instruction between the tests is computed for every lane, live or
    // not, so all of them must be pure and unable to trap: no loads, stores,
    // calls or division by a value. Recognition checks everything, so the
    // rewrite never has to give up half-way.
    IRBlock* _esH;
    IRBlock* _esPH;
    IRBlock* _esB;
    IRBlock* _esT0;
    IRBlock* _esL;
    IRBlock* _esE;
    IRBlock* _esX;
    Array* _esTests;     // T0..Tm, in order
    Array* _esCont;      // per test: Number 1 when it continues on true
    IRInsn* _esIvPhi;
    IRInsn* _esIvNext;
    IRInsn* _esStoreAddr;    // E's `&a[i]`, or 0
    IRInsn* _esStore;        // E's store of a lane value there, or 0
    i64 _esN;
    IROperand* _esBoundOp;
    bool _esBoundConst;
    bool _esSigned;
    Array* _esAccPhis;
    Array* _esAccW;      // the IROperand each sum adds
    Set* _esRegion;      // values defined in B, the tests and L, and T0's phis
    Map* _esDefOf;
    Map* _esMap;         // scalar -> vector value
    Map* _esSplat;       // invariant scalar -> its splat in PH
    Map* _esExit;        // a T0 phi -> its blended value, as E reads it
    u32 _esBytes;
    u32 _esVF;
    bool _esParItems;    // the item loop of a par body: its items are independent by the language
    u32 _esJam;          // vectors side by side in this loop (escApply): 1, or the profile's escapeJam
    IRInsn* _esJamCmp;   // the head's test that names _esVF * _esJam (operand 1)
    IRInsn* _esJamStep;  // the latch's iv step by _esVF * _esJam (operand 1)

    Set* _esDone;        // headers already rewritten (their scalar loops remain)
    IRFunc* _esFn;

    // E: constants, iv + 1, one sum per other phi of H (`s = s + w`, or
    // `s = c ? s + w : s` — nbody's `if (ax > 0) right++`), at most one store
    // of a lane value to a[i], and lane arithmetic feeding those.
    Array* _esAccKind;   // per sum: 0 always adds, 1 adds where c, 2 where !c
    Array* _esPassPhis;  // phis of H the loop does not change
    Array* _esAccCond;   // per sum: the IROperand c, or 0
    Array* _esELane;     // E's own lane instructions, in order
    Set* _esLoadRoots;   // what the loads read: "s:<symbol>" or "v:<value>"
    Set* _esIdxPhis;     // T0 phis that index a load (a[j])
    bool _esCounted;     // no lane test: every lane makes every trip
    IRInsn* _esTripPhi;  // the counter the trip count replaces, or 0
    Set* _esUniform;     // T0 phis read only as that index: no lane vector
    IRValue* _esViv;     // the vector loop's scalar iv
    IRValue* _esTripV;   // the inner loop's trip count, as it runs

    Array* _esPre;       // PH's new instructions, before its branch
    // Where a splat goes. The vector registers are few and an invariant
    // made before a loop holds one for all of it, so what only the pixel
    // arithmetic reads is made in VB, once a step; only the inner loop's own
    // invariants are made in PH. Each region has its own cache.
    Array* _esSplatTo;
    bool _esFresh;       // an entry value: a splat of its own, never shared

    Map* _esCse;         // "op:a:b" -> the vector value already computed

    Array* _esVSum;
    Array* _esVSumNext;

    IRBlock* _esVB;
    Set* _esSkip;        // counter adds the mask subtraction replaces

    // `k < N` on a counter k that enters at a constant c0 < N (mandelbrot's
    // iteration cap). A live lane's k is c0 plus the trips the inner loop has
    // made, so the lane test is the SCALAR test on that trip count: no splat
    // of N, no lane compare, no mask And. Lanes that left earlier keep their
    // smaller k and are already out of the mask.
    i32 _esTripTest;     // the test's index in _esTests, or -1
    i64 _esTripN;
    i64 _esTripC0;
    String* _esTripTy;
    bool _esTripSigned;

    IRInsn* _esTripAnd;      // the And the trip test sits in, or 0
    IROperand* _esTripOther; // that And's other side, still a lane test

    // The shape shared with the map recogniser, plus the second phi. Results in
    // the _vr* ivars — split out because the arm64 backend budgets 16 KB of
    // frame per function.
    IRInsn* _vrIvPhi;
    IRInsn* _vrAccPhi;
    IRInsn* _vrGuard;
    IRValue* _vrIv;
    IRBlock* _vrB;
    IRBlock* _vrE;
    i64 _vrN;
    i64 _vrIvStart;        // the induction phi's constant start, -1 if not one
    IROperand* _vrIvStartOp; // a RUNTIME start (a par chunk's `lo`), else 0
    bool _vrRuntime;       // the bound is a RUNTIME value, not a literal
    bool _vrMapRT;         // ... the same, for the MAP recogniser's own bound check
    Array* _vrOverlap;     // the map body's base pairs that may overlap (#95)
    u32 _magicM;           // magic multiplier from vecMagicU32
    u32 _magicS;           // and its post-shift
    // Constant divides in the body, keyed by the UDiv result, each holding
    // the magic the RECOGNISER derived. Recorded rather than recomputed in
    // the rewriter so the two cannot disagree: when they did, the rewriter
    // fell through to emitting a vector UDiv, which no back end lowers and
    // which silently returned a wrong sum.
    Map* _vrDivMagic;
    // Set by vecClassifyReduxBody: the body read the induction variable as a
    // per-lane VALUE, so the applier must map it to <i, i+1, i+2, i+3>.
    bool _vrUsesIv;
    // The map recogniser's: the body read the iv as a value (an iota map).
    bool _vrMapUsesIv;
    IRModule* _vecModule; // for the lane-index global
    IRFunc* _vecFn;       // the function being rewritten (names that global)
    bool _vrAllowRT;       // one-shot: the NEXT vecReduxShape may accept one
    IROperand* _vrBoundOp; // that bound, when it is

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
    String* _vecLane;    // the map value's own lane, when the loop mixes them (#27); 0 else

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

    // The accumulator's back edge must be Select(cmp, Add(acc, delta), acc):
    // the compare selects between incrementing and keeping the count, which is
    // what an if-converted `if (...) n += delta` becomes. The delta has to be
    // loop-invariant, and the Select single-use — anything else reading it would
    // see the scalar count this rewrite is about to replace.
    IRInsn* _vcAccNext;
    IRInsn* _vcIncr;
    IRInsn* _vcCmp;
    IROperand* _vcDelta;

    String* _vcLaneTy;
    IRValue* _vcElem;

    // The simpler operand form the reduction paths use: an already-vectorised
    // value, else a broadcast made in the body. (The map path also hoists
    // invariant broadcasts to the entry block; the reduction path does not, and
    // the difference is the original's.)
    // A splat of a COMPILE-TIME CONSTANT belongs in the preheader, not the body:
    // it is the same vector on every iteration. `a[i] * 7` rebuilt the splat of
    // 7 every iteration — three instructions in int_muldiv's hot loop for a
    // constant. A non-constant operand still splats in the body, where it is
    // correct whether or not it is invariant.
    bool _vecSplatBig;  // the body is too large to hold constant splats across it

    IRBlock* _rotH;
    IRBlock* _rotB;   // the body's entry (becomes the loop header)
    IRBlock* _rotL;   // the latch: the one body block that branches back to H
    Array* _rotR;     // the body: everything reachable from B without passing H
    IRBlock* _rotE;
    IRValue* _rotCond;
    bool _rotEntryTrue;   // the guard holds on the entry values: no zero-trip path
    i64 _rcVal;           // rotConst's result

    // ── loop-rotate: a short-circuit chain ──────────────────────────────
    //
    // A top-tested loop whose test is a chain of two or more blocks, as
    // `while (j > 0 && a[j-1] > v)` lowers:
    //
    //     H1:  phi …; <guard 1>; CondBranch c1, H2, E
    //     H2:  <guard 2>;        CondBranch c2, B, E        (… up to Hk)
    //     B…L: <body>; Branch H1
    //
    // Unlike the one-block case, the body may read what the guard computed (the
    // loaded `a[j-1]`, and `j-1` as the next `j`): rotation threads those values
    // into B. Mirrors the original.
    Array* _rcChain;

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

    // ── const-hoist ──────────────────────────────────────────────────────
    //
    // Dedupe repeated float constants and (profile-gated) repeated
    // `AddrOf @sym`: the earliest occurrence moves to the front of the entry
    // block, which dominates everything, and the duplicates' uses point at it.
    // Unrolling and inlining are what replicate these in the first place, and
    // one definition lets the allocator home the value across the loop.
    // The function whose keys are being computed — `hoistKey` needs it to ask
    // whether an AddrOf names a pinned local, and has no other way to reach it.
    IRFunc* _hoistFn;

    // A field LOAD may move only when nothing in the loop writes memory;
    // everything else must be pure and speculation-safe.
    // Values that are an incoming of a vector phi, set by licmOnce.
    Array* _licmVecPhiIns;

    // The pipeline, in the original's order. Each pass is gated on the level it
    // declares (`minOptLevel`) and, where it has one, on a profile knob.
    // Whether an environment variable is set to something (the host call
    // gives "" for one that is not set at all).
    static bool ppEnvSet(u8* name)
        {
        u8* e = _xt_getenv(name);
        return e != (u8*)0 && e[0] != (u8)0;
        }

    // dead-function-elim's indexes, for the length of one run of the pass (the
    // module does not change until its end): name -> the first function of that
    // name, and the names kept. Linear searches made the pass quadratic in the
    // number of functions (2026-11-02); the reference uses a dictionary and a set.
    // _dfeSyms is symNamed's answer by name (the first symbol of that name) for
    // the same run: the par runtime's thousands of symbol operands each searched
    // the module's symbols.
    Map* _dfeFns;
    Map* _dfeReach;
    Map* _dfeSyms;

    void seed(IRModule* m, Array* reachable, Array* work, String* name)
        {
        if (name == 0)
            return;
        if (_dfeFns.get((Hashable*)name) == (Object*)0)
            return; // no body here to keep
        if (_dfeReach.get((Hashable*)name) != (Object*)0)
            return;
        _dfeReach.set((Hashable*)name, (Object*)name);
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

    // Name indexes for funcNamed and symNamed: a scan per lookup made the
    // inliner, which looks up every call's callee, quadratic in a module's
    // functions (issue #18). An index holds while its module, list and
    // count are the ones it was built from; any other state (a function
    // added, the list replaced by dead-function elimination) rebuilds it on
    // the next lookup. Every name is set before its function joins the
    // module, and a hit is checked against the name all the same.
    Map* _fnIdx;
    IRModule* _fnIdxMod;
    Array* _fnIdxArr;
    u32 _fnIdxCount;
    Map* _symIdx;
    IRModule* _symIdxMod;
    Array* _symIdxArr;
    u32 _symIdxCount;

    IRFunc* funcNamed(IRModule* m, String* name)
        {
        Array* fs = m.funcs();
        if (_fnIdx == (Map*)0 || _fnIdxMod != m || _fnIdxArr != fs || _fnIdxCount != fs.count())
            {
            _fnIdx = new Map();
            for (u32 i = (u32)0; i < fs.count(); i = i + (u32)1)
                {
                IRFunc* f = (IRFunc*)fs.get(i);
                // The accessor is read ONCE deliberately — see private:docs/bugs/025.
                String* fn = f.name();
                // The first of a name, as the scan this replaces found.
                if (fn != 0 && _fnIdx.get((Hashable*)fn) == (Object*)0)
                    _fnIdx.set((Hashable*)fn, (Object*)f);
                }
            _fnIdxMod = m;
            _fnIdxArr = fs;
            _fnIdxCount = fs.count();
            }
        IRFunc* f = (IRFunc*)_fnIdx.get((Hashable*)name);
        if (f == (IRFunc*)0)
            return (IRFunc*)0;
        String* fn = f.name();
        return fn != 0 && fn.equals(name) ? f : (IRFunc*)0;
        }

    IRSymbol* symNamed(IRModule* m, String* name)
        {
        Array* ss = m.syms();
        if (_symIdx == (Map*)0 || _symIdxMod != m || _symIdxArr != ss || _symIdxCount != ss.count())
            {
            _symIdx = new Map();
            for (u32 i = (u32)0; i < ss.count(); i = i + (u32)1)
                {
                IRSymbol* s = (IRSymbol*)ss.get(i);
                // Read once, as funcNamed's is — private:docs/bugs/025.
                String* sn = s.name();
                if (sn != 0 && _symIdx.get((Hashable*)sn) == (Object*)0)
                    _symIdx.set((Hashable*)sn, (Object*)s);
                }
            _symIdxMod = m;
            _symIdxArr = ss;
            _symIdxCount = ss.count();
            }
        IRSymbol* s = (IRSymbol*)_symIdx.get((Hashable*)name);
        if (s == (IRSymbol*)0)
            return (IRSymbol*)0;
        String* sn = s.name();
        return sn != 0 && sn.equals(name) ? s : (IRSymbol*)0;
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

    bool isCallOp(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked"));
        }

    bool hasInsn(Array* ns, IRInsn* n)
        {
        for (u32 i = (u32)0; i < ns.count(); i = i + (u32)1)
            if ((IRInsn*)ns.get(i) == n)
                return true;
        return false;
        }

    u32 blockIndex(IRFunc* fn, IRBlock* bb)
        {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == bb)
                return i;
        return fn.blocks().count();
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

    // Whether fn's vector code may use the bit select and the lane rotate:
    // everywhere on arm64; on x86 in a function 64 bytes wide (an AVX-512
    // dispatch copy, or the whole program under -mavx512).
    bool vcWanted(IRFunc* fn)
        {
        if (_profile.bitSelect())
            return true;
        if (!_profile.bitSelect512())
            return false;
        u32 w = fn.simdLaneBytes() != (u32)0 ? fn.simdLaneBytes() : _profile.vectorLaneBytes();
        return w == (u32)64;
        }

    // The defining insn of a use operand, when it is `op`, in `bb`, with one use.
    IRInsn* vcDef(IROperand* o, String* op, Map* defIn, Map* uses)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (IRInsn*)0;
        IRInsn* d = (IRInsn*)defIn.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || !d.op().equals(op) || countOf(uses, o.val()) != (u32)1)
            return (IRInsn*)0;
        return d;
        }

    bool vcSame(IROperand* a, IROperand* b)
        {
        return a.kind() == (u8)OPK_USE && b.kind() == (u8)OPK_USE && a.val() != (IRValue*)0 && a.val() == b.val();
        }

    // VRotl for VOr(p, q): p a VShl and q a VLShr of the same x, by c and w - c.
    IRInsn* vcRotate(IRInsn* n, IROperand* p, IROperand* q, Map* defIn, Map* uses)
        {
        IRInsn* sl = vcDef(p, String.withCString("VShl"), defIn, uses);
        IRInsn* sr = vcDef(q, String.withCString("VLShr"), defIn, uses);
        if (sl == (IRInsn*)0 || sr == (IRInsn*)0 || sl.ops().count() != (u32)2 || sr.ops().count() != (u32)2)
            return (IRInsn*)0;
        IROperand* x = (IROperand*)sl.ops().get((u32)0);
        if (!vcSame(x, (IROperand*)sr.ops().get((u32)0)))
            return (IRInsn*)0;
        IROperand* c = (IROperand*)sl.ops().get((u32)1);
        IROperand* d = (IROperand*)sr.ops().get((u32)1);
        if (c.kind() != (u8)OPK_IMMI || d.kind() != (u8)OPK_IMMI || c.ty() == (String*)0)
            return (IRInsn*)0;
        i64 w = (i64)(irWidth(c.ty()) * (u32)8);
        if (w == (i64)0 || c.imm() <= (i64)0 || c.imm() >= w || c.imm() + d.imm() != w)
            return (IRInsn*)0;
        IRInsn* r = IRInsn.with(String.withCString("VRotl"));
        r.copyDbg(n);
        r.setRes(n.res());
        r.add(x);
        r.add(IROperand.immI(c.imm(), c.ty()));
        _vcDead.add((Object*)sl);
        _vcDead.add((Object*)sr);
        return r;
        }

    // VBsl for VOr(p, q): p = VAnd(m, a) (either order), q = VAnd(VNot(m), b)
    // (either order).
    IRInsn* vcSelect(IRInsn* n, IROperand* p, IROperand* q, Map* defIn, Map* uses)
        {
        IRInsn* ap = vcDef(p, String.withCString("VAnd"), defIn, uses);
        IRInsn* aq = vcDef(q, String.withCString("VAnd"), defIn, uses);
        if (ap == (IRInsn*)0 || aq == (IRInsn*)0 || ap.ops().count() != (u32)2 || aq.ops().count() != (u32)2)
            return (IRInsn*)0;
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
            {
            IRInsn* nt = vcDef((IROperand*)aq.ops().get(k), String.withCString("VNot"), defIn, uses);
            if (nt == (IRInsn*)0 || nt.ops().count() != (u32)1)
                continue;
            IROperand* mk = (IROperand*)nt.ops().get((u32)0);
            IROperand* b = (IROperand*)aq.ops().get((u32)1 - k);
            for (u32 j = (u32)0; j < (u32)2; j = j + (u32)1)
                {
                if (!vcSame((IROperand*)ap.ops().get(j), mk))
                    continue;
                IRInsn* r = IRInsn.with(String.withCString("VBsl"));
                r.copyDbg(n);
                r.setRes(n.res());
                r.add(mk);
                r.add((IROperand*)ap.ops().get((u32)1 - j));
                r.add(b);
                _vcDead.add((Object*)ap);
                _vcDead.add((Object*)aq);
                _vcDead.add((Object*)nt);
                return r;
                }
            }
        return (IRInsn*)0;
        }

    // VBsl for VXor(p, q): q = VAnd(m, VXor(a, p)) (either order throughout).
    IRInsn* vcSelectXor(IRInsn* n, IROperand* p, IROperand* q, Map* defIn, Map* uses)
        {
        IRInsn* aq = vcDef(q, String.withCString("VAnd"), defIn, uses);
        if (aq == (IRInsn*)0 || aq.ops().count() != (u32)2 || p.kind() != (u8)OPK_USE)
            return (IRInsn*)0;
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
            {
            IRInsn* x = vcDef((IROperand*)aq.ops().get(k), String.withCString("VXor"), defIn, uses);
            if (x == (IRInsn*)0 || x.ops().count() != (u32)2)
                continue;
            IROperand* mk = (IROperand*)aq.ops().get((u32)1 - k);
            for (u32 j = (u32)0; j < (u32)2; j = j + (u32)1)
                {
                if (!vcSame((IROperand*)x.ops().get(j), p))
                    continue;
                IRInsn* r = IRInsn.with(String.withCString("VBsl"));
                r.copyDbg(n);
                r.setRes(n.res());
                r.add(mk);
                r.add((IROperand*)x.ops().get((u32)1 - j));
                r.add(p);
                _vcDead.add((Object*)aq);
                _vcDead.add((Object*)x);
                return r;
                }
            }
        return (IRInsn*)0;
        }

    void vecCombineFn(IRFunc* fn)
        {
        Map* uses = useCounts(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Map* defIn = new Map();
            _vcDead = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defIn.set((Hashable*)n.res(), (Object*)n);
                if (n.ops().count() != (u32)2 || n.res() == (IRValue*)0)
                    continue;
                IROperand* p = (IROperand*)n.ops().get((u32)0);
                IROperand* q = (IROperand*)n.ops().get((u32)1);
                if (n.op().equals(String.withCString("VXor")))
                    {
                    IRInsn* rx = vcSelectXor(n, p, q, defIn, uses);
                    if (rx == (IRInsn*)0)
                        rx = vcSelectXor(n, q, p, defIn, uses);
                    if (rx != (IRInsn*)0)
                        {
                        bb.insns().set(i, (Object*)rx);
                        defIn.set((Hashable*)rx.res(), (Object*)rx);
                        }
                    continue;
                    }
                if (!n.op().equals(String.withCString("VOr")))
                    continue;
                IRInsn* r = vcRotate(n, p, q, defIn, uses);
                if (r == (IRInsn*)0)
                    r = vcRotate(n, q, p, defIn, uses);
                if (r == (IRInsn*)0)
                    r = vcSelect(n, p, q, defIn, uses);
                if (r == (IRInsn*)0)
                    r = vcSelect(n, q, p, defIn, uses);
                if (r == (IRInsn*)0)
                    continue;
                bb.insns().set(i, (Object*)r);
                defIn.set((Hashable*)r.res(), (Object*)r);
                }
            if (_vcDead.count() == (u32)0)
                continue;
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                bool dead = false;
                for (u32 k = (u32)0; k < _vcDead.count() && !dead; k = k + (u32)1)
                    dead = (IRInsn*)_vcDead.get(k) == n;
                if (!dead)
                    keep.add((Object*)n);
                }
            bb.insns().removeAll();
            for (u32 i = (u32)0; i < keep.count(); i = i + (u32)1)
                bb.insns().add(keep.get(i));
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

    // The layout id in an `Agg(N)` spelling, or the layout count when absent.
    u32 aeLayoutId(IRModule* m, String* t)
        {
        u32 i = (u32)4;
        u32 id = (u32)0;
        bool any = false;
        while (i < t.byteLength())
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            id = id * (u32)10 + (u32)(c - (u8)'0');
            any = true;
            i = i + (u32)1;
            }
        if (!any)
            return m.layouts().count();
        return id;
        }

    // Every user of `v`, in program order.
    Array* aeUsersOf(IRFunc* fn, IRValue* v)
        {
        Array* out = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            aeCollectUsers(bb.phis(), v, out);
            aeCollectUsers(bb.insns(), v, out);
            if (bb.term() != (IRInsn*)0)
                aeCollectOne(bb.term(), v, out);
            }
        return out;
        }

    void aeCollectUsers(Array* insns, IRValue* v, Array* out)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            aeCollectOne((IRInsn*)insns.get(i), v, out);
        }

    void aeCollectOne(IRInsn* n, IRValue* v, Array* out)
        {
        for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                {
                out.add((Object*)n);
                return;
                }
            }
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
    // to the ARRAY of blocks that dominate it, in the function's block order.
    //
    // The sets are bit rows indexed by block position and each block's
    // predecessors are found once: rebuilt per block per pass (a scan of every
    // terminator) and intersected by search, this was cubic in the blocks, and
    // the par runtime a lifted loop brings in spent half its compile here (33 s
    // for a one-loop program on x86-64 Linux). The passes, their order and the
    // in-place update are as before, so the fixed point is the same.
    Map* dominators(IRFunc* fn)
        {
        Map* dom = new Map();
        u32 n = fn.blocks().count();
        if (n == (u32)0)
            return dom;
        Map* index = new Map();
        for (u32 b = (u32)0; b < n; b = b + (u32)1)
            index.set((Hashable*)(IRBlock*)fn.blocks().get(b), (Object*)Number.with(b));
        // preds[b]: the positions of the blocks whose terminator names b, each once.
        Array* preds = new Array();
        for (u32 b = (u32)0; b < n; b = b + (u32)1)
            preds.add((Object*)new Array());
        for (u32 b = (u32)0; b < n; b = b + (u32)1)
            {
            IRInsn* t = ((IRBlock*)fn.blocks().get(b)).term();
            if (t == 0)
                continue;
            for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(i);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == 0)
                    continue;
                Number* at = (Number*)index.get((Hashable*)o.blk());
                if (at == (Number*)0)
                    continue;
                Array* ps = (Array*)preds.get(at.asU32());
                bool seen = false;
                for (u32 k = (u32)0; k < ps.count(); k = k + (u32)1)
                    if (((Number*)ps.get(k)).asU32() == b)
                        seen = true;
                if (!seen)
                    ps.add((Object*)Number.with(b));
                }
            }
        u32 w = (n >> (u32)3) + (u32)1;
        Data* store = Data.withLength(n * w);
        u8* rows = store.bytes();
        Data* scratch = Data.withLength(w);
        u8* nd = scratch.bytes();
        u32* counts = (u32*)0;
        Data* countStore = Data.withLength(n * (u32)4);
        counts = (u32*)countStore.bytes();
        // The entry dominates itself only; every other block starts as all.
        rows[0] = (u8)1;
        counts[0] = (u32)1;
        for (u32 b = (u32)1; b < n; b = b + (u32)1)
            {
            for (u32 k = (u32)0; k < n; k = k + (u32)1)
                rows[b * w + (k >> (u32)3)] = rows[b * w + (k >> (u32)3)] | ((u8)1 << (u8)(k & (u32)7));
            counts[b] = n;
            }
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 b = (u32)1; b < n; b = b + (u32)1)
                {
                // The intersection of its predecessors' sets, plus itself.
                Array* ps = (Array*)preds.get(b);
                for (u32 k = (u32)0; k < w; k = k + (u32)1)
                    nd[k] = ps.count() == (u32)0 ? (u8)0 : (u8)255;
                for (u32 p = (u32)0; p < ps.count(); p = p + (u32)1)
                    {
                    u32 q = ((Number*)ps.get(p)).asU32();
                    for (u32 k = (u32)0; k < w; k = k + (u32)1)
                        nd[k] = nd[k] & rows[q * w + k];
                    }
                nd[b >> (u32)3] = nd[b >> (u32)3] | ((u8)1 << (u8)(b & (u32)7));
                u32 c = (u32)0;
                for (u32 k = (u32)0; k < n; k = k + (u32)1)
                    if ((nd[k >> (u32)3] & ((u8)1 << (u8)(k & (u32)7))) != (u8)0)
                        c = c + (u32)1;
                // Sets only shrink, so a count that held is a set that held.
                if (c == counts[b])
                    continue;
                for (u32 k = (u32)0; k < w; k = k + (u32)1)
                    rows[b * w + k] = nd[k];
                counts[b] = c;
                changed = true;
                }
            }
        for (u32 b = (u32)0; b < n; b = b + (u32)1)
            {
            Array* ds = new Array();
            for (u32 k = (u32)0; k < n; k = k + (u32)1)
                if ((rows[b * w + (k >> (u32)3)] & ((u8)1 << (u8)(k & (u32)7))) != (u8)0)
                    ds.add(fn.blocks().get(k));
            dom.set((Hashable*)(IRBlock*)fn.blocks().get(b), (Object*)ds);
            }
        return dom;
        }

    // A compile-time integer, seen through the ZExt a `(u16)0` lowers to.
  // i64: IROperand.imm() is already 64-bit, and the reference holds every
  // one of these in an int64_t. Narrowing here made a u32 loop bound above
  // 2^31 come back NEGATIVE, and every guard that tests it silently gave
  // up. private:docs/bugs/243.
    bool constValue(Map* defOf, IROperand* op, i64* out)
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
        i64 v = (i64)0;
        if (!constValue(defOf, (IROperand*)n.ops().get((u32)0), &v))
            return false;
        if (v < (i32)0)
            return false;
        out[0] = v;
        return true;
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

    // The blocks whose terminator names `target`, once per mention — what
    // filtering every block's lrcSuccs for target gave. lrcSuccs checks each
    // successor is still one of fn's blocks; only target's answer matters here,
    // so it is asked once rather than once per edge, which made this the
    // square of the block count and a long function's whole LICM time (bug 621).
    Array* lrcPreds(IRFunc* fn, IRBlock* target)
        {
        Array* out = new Array();
        if (target == (IRBlock*)0 || !hasBlock(fn.blocks(), target))
            return out;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = src.term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(i);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == target)
                    out.add((Object*)src);
                }
            }
        return out;
        }

    // lrcPreds for every block at once: block -> the blocks whose terminator
    // names it, once per mention, in the same order; a block that is not one
    // of fn's has none, as lrcPreds says. For a walk that asks of many blocks
    // while the function stands still (LICM's loop bodies: one scan of the
    // function per body block was a tenth of a long function's LICM).
    Map* lrcPredMap(IRFunc* fn)
        {
        Map* inFn = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            inFn.set((Hashable*)(IRBlock*)fn.blocks().get(b), (Object*)fn.blocks().get(b));
        Map* out = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = src.term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(i);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0 || inFn.get((Hashable*)o.blk()) == (Object*)0)
                    continue;
                Array* ps = (Array*)out.get((Hashable*)o.blk());
                if (ps == (Array*)0)
                    {
                    ps = new Array();
                    out.set((Hashable*)o.blk(), (Object*)ps);
                    }
                ps.add((Object*)src);
                }
            }
        return out;
        }

    Array* lrcPredsIn(Map* preds, IRBlock* target)
        {
        Array* ps = target == (IRBlock*)0 ? (Array*)0 : (Array*)preds.get((Hashable*)target);
        return ps == (Array*)0 ? new Array() : ps;
        }

    bool lrcWritesMemory(String* op)
        {
        return op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked")) || op.equals(String.withCString("MemSet")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("Retain")) || op.equals(String.withCString("Release")) || op.equals(String.withCString("WeakRegister")) || op.equals(String.withCString("WeakUnregister")) || op.equals(String.withCString("VTblDispatch")) || op.equals(String.withCString("ProtoDispatch")) || op.equals(String.withCString("Asm"));
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

    bool hasValue(Array* vs, IRValue* v)
        {
        for (u32 i = (u32)0; i < vs.count(); i = i + (u32)1)
            if ((IRValue*)vs.get(i) == v)
                return true;
        return false;
        }

    bool isIntType(String* t)
        {
        if (t == (String*)0)
            return false;
        return t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")) || t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")) || t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")) || t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"));
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
        cl.copyDbg(n);
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

    // A block name not already used in `fn`. The first caller gets the name it
    // asked for, so single-clone output is unchanged; later ones get _2, _3...
    //
    // Accumulator distribution clones the SAME loop once per accumulator, and a
    // bare `<name>_rem` then named every clone alike: a loop carrying four
    // reductions produced four blocks called `<hdr>_rem`, the back end emitted
    // the label four times and the assembler refused the unit. It needs a whole
    // translation unit to show — a small file distributes nothing.
    String* vecUniqueBlockName(IRFunc* fn, String* want)
        {
        bool taken = false;
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            {
            String* bn = ((IRBlock*)fn.blocks().get(i)).name();
            if (bn != (String*)0 && bn.equals(want))
                taken = true;
            }
        if (!taken)
            return want;
        for (u32 n = (u32)2; n < (u32)10000; n = n + (u32)1)
            {
            String* c = String.withString(want);
            c.appendFormat("_%lu", n);
            bool hit = false;
            for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
                {
                String* bn = ((IRBlock*)fn.blocks().get(i)).name();
                if (bn != (String*)0 && bn.equals(c))
                    hit = true;
                }
            if (!hit)
                return c;
            }
        return want;
        }

    // The remainder loops this pass made (an epilogue's scalar clone), per
    // function: never vectorised again, as the reference's sVecRemainders.
    bool vecIsRemainder(IRBlock* H)
        {
        return _vecRemainders != (Map*)0 && _vecRemainders.get((Hashable*)H) != (Object*)0;
        }

    Array* vecCloneLoop(IRFunc* fn, IRBlock* H, IRBlock* B, Map* vmap)
        {
        IRBlock* H2 = new IRBlock(vecUniqueBlockName(fn, hoistName2(H.name(), "_rem")));
        IRBlock* B2 = new IRBlock(vecUniqueBlockName(fn, hoistName2(B.name(), "_rem")));
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
            cl.copyDbg(phi);
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

    bool rotIsLatch(IRBlock* b, IRBlock* H)
        {
        if (b == (IRBlock*)0 || b == H || b.phis().count() != (u32)0)
            return false;
        if (b.term() == (IRInsn*)0 || !b.term().op().equals(String.withCString("Branch")) || b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }
    }
