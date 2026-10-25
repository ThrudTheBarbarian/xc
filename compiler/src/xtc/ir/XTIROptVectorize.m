#import "XTIROptVectorize.h"
#import "XTIROptVecCombine.h"

// ── THE LIMIT, AND THE WAY OUT (not yet implemented) ─────────────────────
//
// Every recogniser below bails on the same line:
//
//     if (vw < 2 || (N % (int64_t)vw) != 0) continue;
//
// so a loop vectorises only when its trip count is a compile-time CONSTANT and
// an exact multiple of the vector width. There is no epilogue anywhere in this
// pass, which means a constant 63 fails exactly as hard as a runtime `n` — and
// `for (i = 0; i < n; i++)` is the shape essentially all real code uses, and the
// only shape a library function CAN use. Measured cost, each compiler against
// its own platform's on the same machine, on a hoist-proof reduction+dot kernel:
// arm64 8.6x off clang -O3, x86-64 3.1x off gcc -O3. Fixture:
// tests/fixtures/vectorize_var_trip.xc.
//
// The cheap way out is NOT to clone the loop. `apply:` already builds the vector
// body into a SEPARATE `newBody` array and only then overwrites the scalar body
// (`[B.instructions setArray:newBody]`). So instead of mutating the loop in
// place and needing a scalar tail cloned from what was just destroyed:
//
//   1. emit `newBody` into a FRESH block B' with a fresh header H',
//   2. compute M = bound & ~(vw-1) in a new preheader — provably a multiple of
//      vw, so the existing "lands exactly on the bound" reasoning still holds,
//   3. run the vector loop to M, reduce the accumulator at its exit,
//   4. leave the ORIGINAL scalar loop completely untouched, and only re-point
//      its preheader phi incomings: iv 0 -> M, accumulator seed -> the reduced
//      vector value.
//
// The scalar loop is then the remainder by construction — no clone, no
// duplicated body, and the tail is the code that was already proven correct.
// A signed bound needs the `n <= 0` case to fall straight through to the scalar
// loop, which it already does (`i < n` is false at i = 0).

#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRSymbol.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@interface XTVecCand : NSObject
@property(nonatomic) XTIRBlock *H, *B, *E;
@property(nonatomic) XTIRInsn *ivPhi, *ivNext, *guard;
@property(nonatomic) XTIRValueId ivId;
@property(nonatomic) XTIRType* laneType; // i32/u32
@property(nonatomic) NSUInteger vw;      // lanes per vector (4 for i32)
@property(nonatomic) NSUInteger vecBytes; // vector width: 16, or 32 under -mavx2 (S2)
// Reduction candidates only (isReduction = YES). The loop carries a second
// (accumulator) phi whose back-edge value is `accNext = Add(acc, elem)`, where
// `elem` is an elementwise (iv-indexed) value. The map fields above still
// describe the induction variable.
@property(nonatomic) BOOL isReduction;
@property(nonatomic) XTIRInsn *accPhi, *accNext;
@property(nonatomic) XTIRValueId accId;   // accPhi result (the carry)
@property(nonatomic) XTIRValueId elemId;  // the per-lane value added each iter
@property(nonatomic) XTIROperand* seedOp; // accumulator's pre-loop value
// IOTA: the per-lane value is derived from the INDUCTION VARIABLE rather than
// from a load, so the applier must map the iv to <i, i+1, i+2, i+3> instead of
// splatting it. `acc += f(i)` with no array anywhere.
@property(nonatomic) BOOL isIota;
// An ordered float sum: the accumulator stays scalar and each vector's lanes
// are added to it in order, so the result is the scalar loop's.
@property(nonatomic) BOOL isOrdered;
// Epilogue: when the trip count is not an exact multiple of the vector width,
// the vector loop runs to `epiM` and a CLONE of the scalar loop finishes the
// tail. epiN is the original bound, kept for the clone's own guard.
@property(nonatomic) BOOL needsEpilogue;
@property(nonatomic) int64_t epiM;
@property(nonatomic) int64_t epiN;
// A RUNTIME trip count: the bound is not a literal, so the vector loop's limit
// M = n & ~(vw-1) is computed in the preheader and epiM is meaningless. The
// clone's induction phi is then seeded from that VALUE rather than an immediate.
@property(nonatomic) BOOL runtimeTrip;
@property(nonatomic) XTIROperand* boundOp;
// The iv's (constant) entry value. The runtime-trip limit M must be computed
// from the trip LENGTH (n - ivStart), not the bound: see xtvEmitRuntimeM.
@property(nonatomic) int64_t ivStart;
// A RUNTIME iv entry value (a `par` chunk's `lo`): the loop does not start at
// a literal, which used to refuse it outright. When set, the vector loop begins
// at this value and the runtime limit M is computed from (bound - start); the
// constant `ivStart` is then 0. The value must be loop-invariant.
@property(nonatomic) XTIROperand* ivStartOp;
@property(nonatomic) XTIRBlock* preheader; // header pred that is not the latch
// Min/max reduction (isMaxMin = YES): the loop body is a diamond
//   body: load elem; cmp(elem,acc); CondBranch then, join
//   then: [reload elem]; Branch join
//   join: accNext = Phi[(body,acc),(then,elem)]; ivNext; Branch H
// B holds the diamond head (body); mmThen / mmLatch are the arm / join blocks.
@property(nonatomic) BOOL isMaxMin;
@property(nonatomic) BOOL isMax; // YES = max, NO = min
@property(nonatomic) XTIRBlock *mmThen, *mmLatch;
// Conditional-count reduction (isCount = YES): `for (i<N) if (a[i] <cmp> k) c += d`
// — an additive reduction whose per-iteration increment is masked by a compare.
// `accNext = Select(cmp, Add(acc, delta), acc)`. Vectorised as
// vacc += (VICmp(vload, splat k) & splat delta). B holds the Select; mmLatch
// holds the iv step.
@property(nonatomic) BOOL isCount;
@property(nonatomic) XTIRInsn* cmpInsn; // the per-lane ICmp(elem, k)
@property(nonatomic) XTIROperand* countDeltaOp;
// Widening sum (isWideningSum = YES): `acc:u32 += (u32)a[i]` over u8/u16 a[].
// The narrow load is vector-loaded (16×u8 / 8×u16) and folded into a 4×u32
// accumulator via uaddlp widening, then horizontally reduced.
// Constant divides in the body, keyed by the UDiv result id, each carrying
// the magic multiplier and post-shift the recogniser DERIVED. Recorded here
// rather than recomputed in the applier so the two cannot disagree: when
// they did, the applier fell through to emitting a vector UDiv, which no
// back end lowers and which silently returned a wrong sum.
@property(nonatomic) NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* divMagic;
@property(nonatomic) BOOL isWideningSum;
@property(nonatomic) XTIRType* loadLaneType; // u8 or u16
@property(nonatomic) XTIRValueId loadId;     // the narrow Load result
// Dot product (isDotProduct = YES): `acc:u32/i32 += (u32)(a[i]*b[i])` over two
// u8/u16 arrays. Both narrow loads are vector-loaded and multiplied in the narrow
// lane (VMul = pmullw/mul.8h keeps the low half, matching u16*u16 wrap), then the
// product vector is uaddlp-widened into the u32 accumulator and reduced. Reuses
// the widening-sum lowering with a VMul inserted before the widen.
@property(nonatomic) BOOL isDotProduct;
@property(nonatomic) XTIRValueId loadId2; // the second narrow Load result
@end
@implementation XTVecCand
@end

// The vector width of the function being vectorised, when it is a dispatch
// clone with its own (0: the profile's).
static NSUInteger sVecFnBytes = 0;

// Escape-time loops (mandelbrot): the pass is at the end of this file.
@interface XTEscapeVec : NSObject
@property(nonatomic) NSUInteger bytes;
- (BOOL)runOnFunction:(XTIRFunction*)fn done:(NSMutableSet<NSValue*>*)done;
@end

// The headers the escape-time pass has rewritten in this function: their
// scalar loops remain, as the remainder, and are not taken again.
static NSMutableSet<NSValue*>* sEscDone = nil;

@implementation XTIROptVectorize

- (NSString*)passName
    {
    return @"vectorize";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// Unsigned magic-number division, the SIMPLE form only (Hacker's Delight
// §10-9). Returns NO unless x/d == mulhu(x, M) >>u s holds for every x, which
// is the `a == 0` case; the other form needs an extra add and a shift that
// cannot overflow, and there is no vector idiom for it here. d = 7 and d = 14
// are the small divisors that fall out — they stay scalar and correct.
//
// The same computation lives in the arm64 back end as xtMagicU, which is where
// the scalar lowering gets its constants. Both sides must agree, or a loop
// would compute one answer vectorised and another scalar.
static BOOL xtvMagicU32(uint64_t d, uint64_t* Mout, int* sout)
    {
    if (d < 2)
        return NO;
    const int W = 32;
    uint64_t twoWm1 = (uint64_t)1 << (W - 1);
    uint64_t maxu = ((uint64_t)1 << W) - 1;
    uint64_t twoW = (uint64_t)1 << W;
    int a = 0, p = W - 1;
    uint64_t nc = maxu - (twoW % d);
    uint64_t q1 = twoWm1 / nc, r1 = twoWm1 - q1 * nc;
    uint64_t q2 = (twoWm1 - 1) / d, r2 = (twoWm1 - 1) - q2 * d;
    uint64_t delta;
    do {
        p++;
        if (r1 >= nc - r1) { q1 = 2*q1 + 1; r1 = 2*r1 - nc; }
        else               { q1 = 2*q1;     r1 = 2*r1; }
        if (r2 + 1 >= d - r2) { if (q2 >= twoWm1 - 1) a = 1; q2 = 2*q2 + 1; r2 = 2*r2 + 1 - d; }
        else                  { if (q2 >= twoWm1)     a = 1; q2 = 2*q2;     r2 = 2*r2 + 1; }
        delta = d - 1 - r2;
    } while (p < 2*W && (q1 < delta || (q1 == delta && r1 == 0)));
    if (a)
        return NO;
    *Mout = (q2 + 1) & maxu;
    *sout = p - W;
    return YES;
    }

static BOOL vecScalarBodyFits(XTIRBlock* B, NSSet<NSNumber*>* elemIds, NSUInteger pool);
static NSUInteger vecPoolFor(XTIRFunction* fn, XTIROptTargetProfile* prof);
static NSUInteger vecPoolForTy(XTIRFunction* fn, XTIROptTargetProfile* prof, XTIRType* t);
static void vecRematLanes(XTIRFunction* fn, XTIRBlock* B, NSDictionary<NSNumber*, XTIRBlock*>* defBlk);
static BOOL vecInterleaveFits(XTIRFunction* fn, XTIRBlock* B, XTIRValueId vaccId, XTIRValueId ivId,
                              XTIRInsn* ivNextInsn, NSUInteger pool);

static BOOL elementwiseArith(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul: // float maps
        return YES;
    default:
        return NO;
        }
    }

// The vector opcode for a scalar elementwise op. Float ops reuse VAdd/VSub/VMul;
// the backend emits fadd/fsub/fmul when the result vector's lane is floating.
static XTIROpcode vectorOpFor(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAdd:
    case XTIROpFAdd:
        return XTIROpVAdd;
    case XTIROpSub:
    case XTIROpFSub:
        return XTIROpVSub;
    case XTIROpMul:
    case XTIROpFMul:
        return XTIROpVMul;
    case XTIROpAnd:
        return XTIROpVAnd;
    case XTIROpOr:
        return XTIROpVOr;
    case XTIROpXor:
        return XTIROpVXor;
    default:
        return op;
        }
    }

// Lane types the map vectoriser handles: 8/16/32-bit integer (same-width
// wrapping arithmetic — 16×i8 / 8×i16 / 4×i32 per vector), or 32-bit float
// (float maps; float reductions need associativity the source doesn't grant).
static BOOL vectorisableLane(XTIRTypeKind k)
    {
    return k == XTIRTypeKindI8 || k == XTIRTypeKindU8 ||
           k == XTIRTypeKindI16 || k == XTIRTypeKindU16 ||
           k == XTIRTypeKindI32 || k == XTIRTypeKindU32 || k == XTIRTypeKindF32;
    }

static BOOL resolveConstIntExt(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
    {
    if (op.kind == XTIROperandKindImmI)
        {
        *out = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(op.valueId)];
    if (!d || d.operands.count < 1)
        return NO;
    if (d.opcode == XTIROpConst && d.operands[0].kind == XTIROperandKindImmI)
        {
        *out = d.operands[0].intValue;
        return YES;
        }
    if (d.opcode == XTIROpZExt || d.opcode == XTIROpSExt || d.opcode == XTIROpTrunc)
        return resolveConstIntExt(d.operands[0], defOf, out);
    return NO;
    }

// A compile-time constant: a literal, a Const, an extension of one, or integer
// arithmetic of constants (`32 - c`, which the front end leaves to the
// optimiser: ROTL's shift amount). Folded only where every value involved is in
// [0, 2^31), so that both compilers' widths agree.
static BOOL resolveConstIntFold(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out,
                                unsigned depth)
    {
    int64_t k = 0;
    if (resolveConstIntExt(op, defOf, &k))
        {
        *out = k;
        return YES;
        }
    if (depth > 8 || op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(op.valueId)];
    if (!d || d.operands.count != 2)
        return NO;
    XTIROpcode o = d.opcode;
    if (o != XTIROpAdd && o != XTIROpSub && o != XTIROpMul && o != XTIROpAnd && o != XTIROpOr &&
        o != XTIROpXor && o != XTIROpShl && o != XTIROpLShr)
        return NO;
    int64_t a = 0, b = 0;
    if (!resolveConstIntFold(d.operands[0], defOf, &a, depth + 1) ||
        !resolveConstIntFold(d.operands[1], defOf, &b, depth + 1))
        return NO;
    const int64_t lim = 2147483647;
    if (a < 0 || a > lim || b < 0 || b > lim)
        return NO;
    int64_t r = 0;
    switch (o)
        {
    case XTIROpAdd: r = a + b; break;
    case XTIROpSub: r = a - b; break;
    case XTIROpMul: r = a * b; break;
    case XTIROpAnd: r = a & b; break;
    case XTIROpOr: r = a | b; break;
    case XTIROpXor: r = a ^ b; break;
    case XTIROpShl:
        if (b > 30)
            return NO;
        r = a << b;
        break;
    default:
        if (b > 30)
            return NO;
        r = a >> b;
        break;
        }
    if (r < 0 || r > lim)
        return NO;
    *out = r;
    return YES;
    }

// The folding form, where the port reads vecConst; a loop's bound is read
// without folding (resolveConstIntExt) where the port reads vecConstWide.
static BOOL resolveConstInt(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
    {
    return resolveConstIntFold(op, defOf, out, 0);
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.vectorizesLoops)
        return YES;
    if (getenv("XTVEC_OFF"))
        return YES; // A/B measurement escape hatch
    sVecModule = mod;
    for (XTIRFunction* fn in mod.functions)
        {
        // A dispatch clone carries its own vector width (runtime SIMD dispatch).
        sVecFnBytes = fn.simdLaneBytes;
        [self runOnFunction:fn];
        }
    sVecFnBytes = 0;
    sVecModule = nil;
    return YES;
    }

// The lane-index vector <0,1,2,3>, as a read-only 16-byte global emitted once
// per module. Building it in REGISTERS would need a lane-insert sequence or a
// literal pool in each back end; loading it needs only the VLoad both already
// have, and it is loop-invariant so the load is hoisted to the preheader.
//
// The name is fixed, and the symbol is reused across every loop in the module:
// two definitions of one label is a hard error in the in-house assemblers.
static XTIRModule* sVecModule = nil;

static XTIRSymbolId xtvIotaSymbol(XTIRType* laneType, NSUInteger vecBytes, XTIRFunction* fn)
    {
    // Named per FUNCTION, not per module. An initialised data global is emitted
    // with .globl, so one fixed name would put the same label in every object
    // that vectorises an iota loop and the link would refuse the second. A
    // function name is already unique across the link, so this is too.
    // A 32-byte vector's table gets its own name (suffix `_w32`), so a 16- and a
    // 32-byte one never collide; the 16-byte name is unchanged.
    NSString* nm = [NSString stringWithFormat:@"__xtv_iota_%@_%lu%@", fn.name,
                             (unsigned long)laneType.byteWidth, vecBytes == 16 ? @"" : vecBytes == 64 ? @"_w64" : @"_w32"];
    for (NSUInteger i = 0; i < sVecModule.symbols.count; i++)
        if ([sVecModule.symbols[i].name isEqualToString:nm])
            return (XTIRSymbolId)i;
    NSUInteger lanes = vecBytes / laneType.byteWidth;
    NSMutableData* bytes = [NSMutableData dataWithLength:vecBytes];
    uint8_t* b = (uint8_t*)bytes.mutableBytes;
    for (NSUInteger l = 0; l < lanes; l++)
        for (NSUInteger k = 0; k < laneType.byteWidth; k++)
            b[l * laneType.byteWidth + k] = (uint8_t)((l >> (8 * k)) & 0xFF); // LE
    // A Vec type: exactly 16 bytes, not an Agg (which would go through the
    // aggregate-initialiser relay) and not a float (which would be re-encoded).
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:nm
                                                type:[XTIRType vecWithLane:laneType bytes:(uint32_t)vecBytes]
                                            volatile:NO
                                             escapes:NO
                                           taskLocal:NO];
    sym.initialBytes = bytes;
    return [sVecModule addSymbol:sym];
    }

// Split a loop that carries SEVERAL independent accumulators into one loop per
// accumulator, so the single-accumulator recognisers can take each in turn.
//
// Every recogniser here gates on the header carrying exactly two phis — the
// induction variable and one accumulator — so a loop like string_scan's
//
//     for (i) { if (buf[i] == 44) n++;  acc += (u32)buf[i]; }
//
// was refused outright, whatever its chains looked like. Rather than teach each
// recogniser to carry N accumulators, peel ONE accumulator into its own copy of
// the loop: runOnFunction iterates, so the copies come back round and are
// vectorised by the existing machinery. A loop with K accumulators peels K-1
// times and ends as K ordinary loops.
//
// Duplicating the loop duplicates its LOADS, which is why the body must be free
// of stores and calls — nothing here may be observed twice. The chains are
// otherwise independent by construction: each accumulator's cycle is closed
// (phi -> … -> accNext -> phi), so removing one pair takes its whole chain with
// it once the leftovers are swept.
// `acc = acc + X + Y` is left-associated by the parser, so the back-edge value
// is Add(Add(acc, X), Y) and the accumulator is one Add DEEPER than every
// recogniser looks — each wants Add(acc, elem). Integer addition is associative
// modulo 2^32, so rotating the chain is exact, not an approximation:
//
//     (acc + X) + Y   ->   acc + (X + Y)
//
// Applied repeatedly, that lifts the accumulator out of a chain of any depth.
// This is worth more than it looks: int_muldiv reads
// `acc = acc + ((a[i] * 7) / 3) + (a[i] / 11)`, and BOTH halves of it — the
// magic-division work and the reduction itself — were blocked by nothing but
// the shape of those two plus signs. Writing the same expression with the
// right-hand side bracketed vectorised all along.
//
// The inner Add must have exactly one user, the outer one. Otherwise something
// else reads the partial sum and rotating changes what it sees.
- (BOOL)reassociateReductions:(XTIRFunction*)fn
    {
    BOOL changed = NO;
    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count < 2)
            continue;
        // Candidate accumulators: every phi in this header. Which one is the
        // induction variable does not matter — rotating is sound for any of
        // them, and a phi that is not an accumulator simply never matches.
        NSMutableSet<NSNumber*>* accs = [NSMutableSet set];
        for (XTIRInsn* phi in H.phiNodes)
            if (phi.result)
                [accs addObject:@(phi.result.valueId)];

        for (XTIRBlock* B in fn.blocks)
            {
            if (B == H)
                continue;
            // Only the loop's own latch: a block whose terminator branches back.
            if (!B.terminator || B.terminator.opcode != XTIROpBranch ||
                B.terminator.operands.count < 1 ||
                B.terminator.operands[0].blockRef != H)
                continue;

            NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
            for (XTIRBlock* bb in fn.blocks)
                {
                NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
                [all addObjectsFromArray:bb.phiNodes];
                [all addObjectsFromArray:bb.instructions];
                if (bb.terminator) [all addObject:bb.terminator];
                for (XTIRInsn* i in all)
                    for (XTIROperand* o in i.operands)
                        if (o.kind == XTIROperandKindUse)
                            [uses addObject:@(o.valueId)];
                }

            for (NSUInteger oi = 0; oi < B.instructions.count; oi++)
                {
                XTIRInsn* outer = B.instructions[oi];
                if (outer.opcode != XTIROpAdd || !outer.result || outer.operands.count < 2)
                    continue;
                // The accumulator must not already be a direct operand.
                BOOL direct = NO;
                for (XTIROperand* o in outer.operands)
                    if (o.kind == XTIROperandKindUse && [accs containsObject:@(o.valueId)])
                        direct = YES;
                if (direct)
                    continue;

                for (NSUInteger side = 0; side < 2; side++)
                    {
                    XTIROperand* spine = outer.operands[side];
                    XTIROperand* other = outer.operands[1 - side];
                    if (spine.kind != XTIROperandKindUse ||
                        [uses countForObject:@(spine.valueId)] != 1)
                        continue;
                    NSUInteger ii = NSNotFound;
                    for (NSUInteger k = 0; k < oi; k++)
                        if (B.instructions[k].result &&
                            B.instructions[k].result.valueId == spine.valueId)
                            ii = k;
                    if (ii == NSNotFound)
                        continue;
                    XTIRInsn* inner = B.instructions[ii];
                    if (inner.opcode != XTIROpAdd || inner.operands.count < 2)
                        continue;
                    NSUInteger accSide = NSNotFound;
                    for (NSUInteger k = 0; k < 2; k++)
                        if (inner.operands[k].kind == XTIROperandKindUse &&
                            [accs containsObject:@(inner.operands[k].valueId)])
                            accSide = k;
                    if (accSide == NSNotFound)
                        continue;
                    XTIROperand* accOp = inner.operands[accSide];
                    XTIROperand* x = inner.operands[1 - accSide];

                    // inner becomes X + Y, keeping its result id — its only
                    // user is outer — and outer becomes acc + that.
                    //
                    // It must also MOVE to just before outer. Y is normally
                    // computed AFTER the inner Add (it is the next term of the
                    // expression), so rewriting inner where it stands would
                    // read Y before it is defined. That is not a crash: the
                    // register holds whatever was there, and int_muldiv came
                    // back 837576896 instead of 2079322496 — fast and wrong.
                    // Moving it down is safe because X precedes inner and Y
                    // precedes outer, so both dominate the new position.
                    [inner replaceOperands:@[ x, other ]];
                    [outer replaceOperands:@[ accOp, [XTIROperand useWithValueId:spine.valueId] ]];
                    [B.instructions removeObjectAtIndex:ii];
                    [B.instructions insertObject:inner atIndex:oi - 1];
                    changed = YES;
                    break;
                    }
                }
            }
        }
    return changed;
    }

- (BOOL)distributeAccumulators:(XTIRFunction*)fn
    {
    static int off = -1;
    if (off < 0) off = getenv("XTVEC_NO_DISTRIBUTE") ? 1 : 0;
    if (off) return NO;
    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count < 3)
            continue;

        // The guard names the induction variable; everything else in the header
        // is an accumulator.
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = nil;
        for (XTIRInsn* i in H.instructions)
            if (i.result && i.result.valueId == term.operands[0].valueId)
                guard = i;
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;

        // One body, one latch, one exit — the shape every recogniser assumes.
        XTIRBlock *B = nil, *E = nil;
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        for (XTIRInsn* phi in H.phiNodes)
            if (phi.result && phi.result.valueId == ivId && phi.operands.count == 4)
                {
                XTIRBlock* latch = (phi.operands[0].blockRef == t0 || phi.operands[2].blockRef == t0) ? t0 : t1;
                B = latch;
                E = (latch == t0) ? t1 : t0;
                }
        if (!B || !E || B == H || E == H || B.phiNodes.count || E.phiNodes.count)
            continue;
        if (!B.terminator || B.terminator.opcode != XTIROpBranch ||
            B.terminator.operands.count < 1 || B.terminator.operands[0].blockRef != H)
            continue;

        // Nothing in the body may be observable twice.
        BOOL pure = YES;
        for (XTIRInsn* i in B.instructions)
            switch (i.opcode)
                {
            case XTIROpLoad: case XTIROpConst: case XTIROpAdd: case XTIROpSub:
            case XTIROpMul: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
            case XTIROpShl: case XTIROpLShr: case XTIROpAShr: case XTIROpICmp:
            case XTIROpSelect: case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc:
            case XTIROpAddrOf: case XTIROpFieldAddr: case XTIROpElementAddr:
                break;
            default:
                pure = NO;
                break;
                }
        if (!pure)
            continue;

        // The accumulators, paired with the body instruction that closes each
        // cycle. The peel target is the LAST of them.
        NSMutableArray<XTIRInsn*>* accPhis = [NSMutableArray array];
        NSMutableArray<XTIRInsn*>* accNexts = [NSMutableArray array];
        BOOL shaped = YES;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.result.valueId == ivId || phi.operands.count != 4)
                continue;
            XTIROperand* back = (phi.operands[0].blockRef == B) ? phi.operands[1] : phi.operands[3];
            if (back.kind != XTIROperandKindUse)
                { shaped = NO; break; }
            XTIRInsn* accNext = nil;
            for (XTIRInsn* i in B.instructions)
                if (i.result && i.result.valueId == back.valueId)
                    accNext = i;
            if (!accNext)
                { shaped = NO; break; }
            [accPhis addObject:phi];
            [accNexts addObject:accNext];
            }
        if (!shaped || accPhis.count < 2)
            continue;

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
        NSMutableArray<NSMutableSet<NSNumber*>*>* cones = [NSMutableArray array];
        for (XTIRInsn* accNext in accNexts)
            {
            NSMutableSet<NSNumber*>* cone = [NSMutableSet set];
            NSMutableArray<XTIRInsn*>* work = [NSMutableArray arrayWithObject:accNext];
            [cone addObject:@(accNext.result.valueId)];
            while (work.count)
                {
                XTIRInsn* cur = work.lastObject;
                [work removeLastObject];
                for (XTIROperand* o in cur.operands)
                    {
                    if (o.kind != XTIROperandKindUse || [cone containsObject:@(o.valueId)])
                        continue;
                    [cone addObject:@(o.valueId)];
                    for (XTIRInsn* i in B.instructions)
                        if (i.result && i.result.valueId == o.valueId)
                            [work addObject:i];
                    }
                }
            [cones addObject:cone];
            }
        BOOL independent = YES;
        for (NSUInteger a = 0; a < cones.count && independent; a++)
            for (NSUInteger b2 = 0; b2 < accPhis.count; b2++)
                {
                if (a == b2)
                    continue;
                if ([cones[a] containsObject:@(accPhis[b2].result.valueId)] ||
                    [cones[a] containsObject:@(accNexts[b2].result.valueId)])
                    { independent = NO; break; }
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
        // The printer showed it as `%?23`; the back end reads a missing value
        // as ZERO, so it became `n >= 0` and the loop ran to the wrong answer.
        // gfx8_oval printed three wrong results at -O2 and above; make test was
        // green, and there is no post-opt verifier to have caught it.
        if (independent)
            {
            XTIRInsn* ivPhi = nil;
            for (XTIRInsn* phi in H.phiNodes)
                if (phi.result && phi.result.valueId == ivId)
                    ivPhi = phi;
            XTIRInsn* ivNextI = nil;
            if (ivPhi && ivPhi.operands.count == 4)
                {
                XTIROperand* back = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1]
                                                                     : ivPhi.operands[3];
                if (back.kind == XTIROperandKindUse)
                    for (XTIRInsn* i in B.instructions)
                        if (i.result && i.result.valueId == back.valueId)
                            ivNextI = i;
                }
            if (ivNextI)
                {
                NSMutableSet<NSNumber*>* ivCone = [NSMutableSet set];
                NSMutableArray<XTIRInsn*>* ivWork = [NSMutableArray arrayWithObject:ivNextI];
                [ivCone addObject:@(ivNextI.result.valueId)];
                while (ivWork.count)
                    {
                    XTIRInsn* cur = ivWork.lastObject;
                    [ivWork removeLastObject];
                    for (XTIROperand* o in cur.operands)
                        {
                        if (o.kind != XTIROperandKindUse || [ivCone containsObject:@(o.valueId)])
                            continue;
                        [ivCone addObject:@(o.valueId)];
                        for (XTIRInsn* i in B.instructions)
                            if (i.result && i.result.valueId == o.valueId)
                                [ivWork addObject:i];
                        }
                    }
                for (NSUInteger b2 = 0; b2 < accPhis.count; b2++)
                    if ([ivCone containsObject:@(accPhis[b2].result.valueId)] ||
                        [ivCone containsObject:@(accNexts[b2].result.valueId)])
                        { independent = NO; break; }
                }
            }
        if (!independent)
            continue;
        XTIRInsn* victim = accPhis.lastObject;

        // Copy the whole loop; the copy keeps the peeled accumulator and the
        // original keeps the rest.
        XTIRBlock *H2 = nil, *B2 = nil;
        NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
        xtvCloneLoop(fn, H, B, &H2, &B2, cmap);
        XTIRValueId victimCloneId = (XTIRValueId)cmap[@(victim.result.valueId)].unsignedLongLongValue;

        // The original exits into a fresh PREHEADER for the copy, which then
        // falls into it. Branching H straight at H2 would work, but every
        // recogniser refuses a loop whose exit block carries phis — and H2's
        // phis are exactly that — so the original would stop being vectorisable
        // the moment it was split. The empty block costs one branch and keeps
        // both halves in the shape the recognisers expect.
        XTIRBlock* PH2 = [[XTIRBlock alloc] init];
        PH2.name = [NSString stringWithFormat:@"%@_pre", H2.name ?: @"hdr"];
        [PH2 setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                     result:nil
                                                   operands:@[ [XTIROperand blockWithRef:H2] ]
                                                     dbgLoc:term.dbgLoc]];

        NSMutableArray<XTIROperand*>* tops = [term.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:PH2];
        [term replaceOperands:tops];

        // The copy is entered from that preheader now, not the original's. Its
        // seeds are unchanged: it runs the same range from the same starting
        // values.
        XTIRBlock* PH = (H.phiNodes.count && H.phiNodes[0].operands[0].blockRef == B)
                            ? H.phiNodes[0].operands[2].blockRef
                            : (H.phiNodes.count ? H.phiNodes[0].operands[0].blockRef : nil);
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                if (pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH)
                    pops[k] = [XTIROperand blockWithRef:PH2];
            [phi replaceOperands:pops];
            }

        // After the loops, the peeled accumulator is the COPY's.
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator) [all addObject:bb.terminator];
            for (XTIRInsn* i in all)
                {
                if (bb == H2 || bb == B2)
                    continue;
                NSMutableArray<XTIROperand*>* ops = [i.operands mutableCopy];
                BOOL hit = NO;
                for (NSUInteger k = 0; k < ops.count; k++)
                    if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == victim.result.valueId)
                        { ops[k] = [XTIROperand useWithValueId:victimCloneId]; hit = YES; }
                if (hit) [i replaceOperands:ops];
                }
            }

        // The copy must be IN the function before anything is dropped: the sweep
        // in dropAccumulator decides what is dead by walking fn.blocks, so a
        // copy that is not yet listed contributes no uses and its whole body
        // scores dead.
        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ PH2, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];

        // Drop the peeled accumulator from the original, and the others from the
        // copy. Each is a closed cycle, so the phi and its back-edge definition
        // go together and the rest of the chain falls out in the sweep below.
        [self dropAccumulator:victim.result.valueId header:H body:B fn:fn];
        for (XTIRInsn* phi in [H2.phiNodes copy])
            {
            if (!phi.result || phi.result.valueId == victimCloneId)
                continue;
            XTIRValueId ivCloneId = (XTIRValueId)cmap[@(ivId)].unsignedLongLongValue;
            if (phi.result.valueId == ivCloneId)
                continue;
            [self dropAccumulator:phi.result.valueId header:H2 body:B2 fn:fn];
            }

        return YES;
        }
    return NO;
    }

// Remove one accumulator's phi and back-edge definition from a loop, then sweep
// whatever that orphans out of the body. The cycle is closed, so nothing else
// can be referring to either once the uses outside the loop have been rewritten.
- (void)dropAccumulator:(XTIRValueId)accId
                 header:(XTIRBlock*)H
                   body:(XTIRBlock*)B
                     fn:(XTIRFunction*)fn
    {
    XTIRValueId backId = 0;
    NSMutableArray<XTIRInsn*>* keptPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        {
        if (phi.result && phi.result.valueId == accId && phi.operands.count == 4)
            {
            XTIROperand* back = (phi.operands[0].blockRef == B) ? phi.operands[1] : phi.operands[3];
            if (back.kind == XTIROperandKindUse)
                backId = back.valueId;
            continue;
            }
        [keptPhis addObject:phi];
        }
    [H.phiNodes setArray:keptPhis];

    NSMutableArray<XTIRInsn*>* kept = [NSMutableArray array];
    for (XTIRInsn* i in B.instructions)
        if (!(i.result && i.result.valueId == backId))
            [kept addObject:i];
    [B.instructions setArray:kept];

    // Sweep the orphans: a pure body instruction nothing reads any more. To a
    // fixpoint, because removing one can orphan the one behind it.
    BOOL removed = YES;
    while (removed)
        {
        removed = NO;
        NSCountedSet<NSNumber*>* used = [NSCountedSet set];
        for (XTIRBlock* bb in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator) [all addObject:bb.terminator];
            for (XTIRInsn* i in all)
                for (XTIROperand* o in i.operands)
                    if (o.kind == XTIROperandKindUse)
                        [used addObject:@(o.valueId)];
            }
        NSMutableArray<XTIRInsn*>* keep = [NSMutableArray array];
        for (XTIRInsn* i in B.instructions)
            {
            BOOL dead = i.result && !i.memoryResult &&
                        [used countForObject:@(i.result.valueId)] == 0 &&
                        (i.opcode == XTIROpICmp || i.opcode == XTIROpSelect ||
                         i.opcode == XTIROpAdd || i.opcode == XTIROpSub ||
                         i.opcode == XTIROpMul || i.opcode == XTIROpAnd ||
                         i.opcode == XTIROpOr || i.opcode == XTIROpXor ||
                         i.opcode == XTIROpZExt || i.opcode == XTIROpSExt ||
                         i.opcode == XTIROpTrunc || i.opcode == XTIROpConst ||
                         i.opcode == XTIROpShl || i.opcode == XTIROpLShr ||
                         i.opcode == XTIROpAShr);
            if (dead) { removed = YES; continue; }
            [keep addObject:i];
            }
        [B.instructions setArray:keep];
        }
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    BOOL reduxOff = getenv("XTVEC_REDUX_OFF") != NULL;
    sVecRemainders = [NSMutableSet set];
    sEscDone = [NSMutableSet set];
    for (NSUInteger iter = 0; iter < 256; iter++)
        {
        // A loop around an escape-time or counted inner loop, across its items
        // (mandelbrot, nbody), FIRST: taking the inner loop first (an ordered
        // float sum) would leave it serial.
        if ([self vectorizeEscapeLoop:fn])
            continue;
        XTVecCand* c = [self recognise:fn];
        if (c)
            {
            [self apply:c inFunction:fn];
            continue;
            }
        XTVecCand* r = reduxOff ? nil : [self recogniseReduction:fn];
        if (r)
            {
            [self applyReduction:r inFunction:fn];
            continue;
            }
        XTVecCand* m = reduxOff ? nil : [self recogniseMaxMin:fn];
        if (m)
            {
            [self applyMaxMin:m inFunction:fn];
            continue;
            }
        XTVecCand* cn = reduxOff ? nil : [self recogniseCountReduction:fn];
        if (cn)
            {
            [self applyCountReduction:cn inFunction:fn];
            continue;
            }
        XTVecCand* ws = reduxOff ? nil : [self recogniseWideningSum:fn];
        if (ws)
            {
            [self applyWideningSum:ws inFunction:fn];
            continue;
            }
        XTVecCand* dp = reduxOff ? nil : [self recogniseDotProduct:fn];
        // shares the widening-sum lowering
        if (dp)
            {
            [self applyWideningSum:dp inFunction:fn];
            continue;
            }
        // Nothing matched. `acc = acc + X + Y` parses left-associated, which
        // hides the accumulator one Add deep; rotate it back out and try again.
        if (!reduxOff && [self reassociateReductions:fn])
            continue;
        // If the loop carries several accumulators, peel one into its own copy
        // and come round again — the copies are ordinary single-accumulator
        // loops that the recognisers above already handle.
        if (!reduxOff && [self distributeAccumulators:fn])
            continue;
        break;
        }
    // Break the serial accumulator dependency: unroll vectorised reduction loops
    // with several independent accumulators (clang-style), so the OoO core
    // overlaps the add/max chains. Profile-gated; XTVEC_NOUNROLL disables.
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    // The bit selects and rotates first (where the back end has them), so the
    // interleave's register estimate sees the body the back end will.
    if ([XTIROptVecCombine wantedFor:fn profile:prof])
        [[[XTIROptVecCombine alloc] init] runOnFunction:fn];
    if (prof.vectorizesLoops && !getenv("XTVEC_NOUNROLL"))
        [self unrollVectorReductionsInFunction:fn];
    }

- (BOOL)vectorizeEscapeLoop:(XTIRFunction*)fn
    {
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.vectorizesEscapeLoops)
        return NO;
    XTEscapeVec* e = [[XTEscapeVec alloc] init];
    e.bytes = [self vectorBytes];
    return [e runOnFunction:fn done:sEscDone];
    }

// Does this induction phi provably start at ZERO on the loop's entry edge?
//
// EVERY recogniser needs this, and none of them had it. The transforms step the
// EXISTING induction phi by the vector width and keep the loop's guard, which
// reproduces the scalar loop only when the counter starts at 0. With a non-zero
// start the guard `i < N` is still tested, but the vector body reads and writes
// a whole vector at each step — so the iteration space is wrong at BOTH ends:
//
//   reduction:  for (i = 1; i < 64; i++) s += a[i];   returned 1956, not 2016
//   map:        for (i = 2; i < 16; i++) b[i] = ...;  wrote b[0] and b[1] too
//
// The map case is the more alarming one: it CLOBBERS memory before the range.
// Both were live at -O2 and above on arm64, x86-64 and arm9.
//
// `latch` is the block the back edge comes from, so the OTHER incoming operand
// is the entry value.
// SUPERSEDED by xtvIvStartConst below, which returns the start rather than
// only testing it for zero. A non-zero start is now VECTORISED rather than
// refused: the transforms step the existing phi by vw and keep the guard, so
// the loop covers whole vectors of [start, N) provided the arithmetic is done
// on the trip LENGTH (N - start) instead of the bound N. The reduction
// recogniser's epilogue already did exactly that and refused anyway.
//
// What must not happen is approximating: a start the pass cannot resolve to a
// non-negative constant is still refused, because the gate below reasons about
// a concrete iteration space.
static BOOL xtvIvStartConst(XTIRInsn* ivPhi, XTIRBlock* latch,
                            NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                            int64_t* startOut)
    {
    if (!ivPhi || ivPhi.operands.count != 4)
        return NO;
    XTIROperand* entry = (ivPhi.operands[0].blockRef == latch)
                             ? ivPhi.operands[3]
                             : ivPhi.operands[1];
    int64_t start = 0;
    if (!entry || !resolveConstInt(entry, defOf, &start))
        return NO;
    if (start < 0)
        return NO;
    if (startOut)
        *startOut = start;
    return YES;
    }

- (nullable XTVecCand*)recognise:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count != 1)
            continue; // single induction; no reduction
        XTIRInsn* ivPhi = H.phiNodes[0];
        if (!ivPhi.result || ivPhi.memoryResult)
            continue;
        XTIRValueId ivId = ivPhi.result.valueId;

        // header pure (just the guard)
        BOOL hp = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                hp = NO;
                break;
                }
        if (!hp)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2)
            continue;
        // guard: ICmp <ULT/SLT> i, N(const); i is the iv on the left.
        if (guard.operands[0].kind != XTIROperandKindUse || guard.operands[0].valueId != ivId)
            continue;
        int64_t N = 0;
        // A literal, or the RUNTIME bound handled below. Same rule as the
        // reduction: a runtime bound needs a strict `<` (with `i <= n` the trip
        // is n+1 and n & ~(vw-1) is wrong) and must be loop-invariant, which is
        // checked once the body block is known.
        BOOL constBound = resolveConstIntExt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        // body B latches to H unconditionally; E is the other target.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock *B = nil, *E = nil;
        if (latch(t0))
            {
            B = t0;
            E = t1;
            }
        else if (latch(t1))
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        if (!E || B.instructions.count == 0)
            continue;

        // ivNext = Add(i, 1), back-edge of the phi, used once.
        if (ivPhi.operands.count != 4)
            continue;
        XTIROperand* nextOp = (ivPhi.operands[0].blockRef == B)   ? ivPhi.operands[1]
                              : (ivPhi.operands[2].blockRef == B) ? ivPhi.operands[3]
                                                                  : nil;
        if (!nextOp || nextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ivNext = defOf[@(nextOp.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlk[@(nextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(nextOp.valueId)] != 1)
            continue;
        int64_t step = 0;
        XTIROperand* stepOp = nil;
        if (ivNext.operands[0].kind == XTIROperandKindUse && ivNext.operands[0].valueId == ivId)
            stepOp = ivNext.operands[1];
        else if (ivNext.operands[1].kind == XTIROperandKindUse && ivNext.operands[1].valueId == ivId)
            stepOp = ivNext.operands[0];
        if (!stepOp || !resolveConstInt(stepOp, defOf, &step) || step != 1)
            continue;

        // iv must not escape (used only in H/B); guard + ElementAddr indices + ivNext use it.
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        hp = NO;
                        break;
                        }
            }
        if (!hp)
            continue;

        // Classify every body instruction. Allowed: AddrOf(Sym), ElementAddr
        // (invariant base, index == i), Load(EA), Store(EA,val), elementwise
        // int arith, Const, and the single ivNext. Anything else → bail. Gather
        // the lane type from the loads/stores (must be a consistent i32/u32).
        XTIRType* laneType = nil;
        BOOL ok = YES, sawLoad = NO, sawStore = NO;
        // The elementwise value set: results of iv-indexed loads and of
        // elementwise arith. An arith/store operand must be in this set, or a
        // loop-invariant constant (splattable). This rejects a per-lane-varying
        // scalar (e.g. `b[i]*i`, where `i` differs per lane) being broadcast.
        NSMutableSet<NSNumber*>* elemIds = [NSMutableSet set];
        BOOL (^isElemAddrAtIv)(XTIROperand*) = ^BOOL(XTIROperand* p) {
          if (p.kind != XTIROperandKindUse)
              return NO;
          XTIRInsn* ea = defOf[@(p.valueId)];
          if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2)
              return NO;
          if (ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
              return NO;
          return YES;
        };
        // An operand usable in the elementwise computation: an elementwise value
        // (per-lane vector), or a loop-INVARIANT scalar (same for every lane, so
        // safely splattable) — a constant (possibly widened/narrowed), or a value
        // defined outside the loop. A per-lane-varying value (the iv, or anything
        // derived from it in the body) is neither, and is rejected.
        int64_t _k;
        BOOL (^elemOperandOK)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          if (o.kind == XTIROperandKindImmI)
              return YES;
          if (o.kind != XTIROperandKindUse)
              return NO;
          if ([elemIds containsObject:@(o.valueId)])
              return YES;
          int64_t kk;
          if (resolveConstInt(o, defOf, &kk))
              return YES; // (widened) constant
          XTIRBlock* db = defBlk[@(o.valueId)];
          return db != nil && db != B && db != H; // loop-invariant
        };
        (void)_k;
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == ivNext)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf)
                continue;
            if (op == XTIROpElementAddr)
                {
                // base loop-invariant (an AddrOf, or defined outside B); index == iv.
                if (insn.operands.count < 2 ||
                    insn.operands[1].kind != XTIROperandKindUse || insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                XTIROperand* base = insn.operands[0];
                if (base.kind == XTIROperandKindUse && defBlk[@(base.valueId)] == B)
                    {
                    XTIRInsn* bd = defOf[@(base.valueId)];
                    if (!bd || bd.opcode != XTIROpAddrOf)
                        {
                        ok = NO;
                        break;
                        }
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || !isElemAddrAtIv(insn.operands[0]) || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                if (!lt || !vectorisableLane(lt.kind))
                    {
                    ok = NO;
                    break;
                    }
                if (laneType && laneType.kind != lt.kind)
                    {
                    ok = NO;
                    break;
                    }
                laneType = lt;
                sawLoad = YES;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            if (op == XTIROpStore)
                {
                if (insn.operands.count < 2 || !isElemAddrAtIv(insn.operands[0]) ||
                    !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                sawStore = YES;
                continue;
                }
            // Scalar plumbing kept verbatim (constants, and the widen/narrow of
            // the step or invariant operands) — not part of the elementwise set.
            if (op == XTIROpConst || op == XTIROpZExt || op == XTIROpSExt ||
                op == XTIROpTrunc)
                continue;
            if (elementwiseArith(op))
                {
                if (!insn.result || !vectorisableLane(insn.result.type.kind))
                    {
                    ok = NO;
                    break;
                    }
                if (insn.operands.count < 2 ||
                    !elemOperandOK(insn.operands[0]) || !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            ok = NO;
            break; // call, shifted load, per-lane-varying scalar, etc.
            }
        if (!ok || !sawLoad || !sawStore || !laneType)
            continue;

        NSUInteger vb = [self vectorBytes];
        NSUInteger vw = vb / laneType.byteWidth; // 4 for i32 at 16 bytes
        if (vw < 2)
            continue;
        // A non-zero start is VECTORISED, not refused: the epilogue below works
        // from the trip LENGTH, so [ivStart, N) splits into whole vectors plus a
        // scalar tail exactly as [0, N) does.
        //
        // The zero test used to double as what stopped the REMAINDER being
        // re-recognised and re-cloned — the clone's iv enters at M, so it failed
        // by construction. That job now belongs to the `< vw` test below, which
        // is the honest statement of it: a range with no whole vector in it is
        // not vectorisable, whatever it starts at.
        int64_t ivStart = 0;
        // A RUNTIME start (`for (i = lo; …)`): the vector loop begins at it and
        // runs to the runtime limit start + ((bound - start) & ~(vw-1)), as a
        // reduction's does, so even a constant bound becomes a runtime trip (as
        // an immediate: the limit is computed in the preheader, ahead of the
        // header that holds the bound's Const). The start must be
        // loop-invariant; the remainder clone is refused by xtvIsRemainder.
        // Mirrors the self-hosted vecMapAt.
        XTIROperand* rtStart = nil;
        if (!xtvIvStartConst(ivPhi, B, defOf, &ivStart))
            {
            XTIROperand* so = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[3] : ivPhi.operands[1];
            if (!so || so.kind != XTIROperandKindUse)
                continue;
            XTIRBlock* sdb = defBlk[@(so.valueId)];
            if (sdb == H || sdb == B)
                continue;
            rtStart = so;
            ivStart = 0;
            }
        BOOL rt = runtimeTrip || rtStart != nil;
        XTIROperand* boundOp = guard.operands[1];
        if (!runtimeTrip && rtStart)
            boundOp = [XTIROperand immIWithType:ivPhi.result.type value:N];
        // N is only meaningful when the bound is a CONSTANT — with a runtime
        // trip it is still 0, so an unguarded `ivStart >= N` refuses every
        // runtime-bound loop, including the zero-start ones that vectorised
        // before. That is how this first showed up: the self-hosted optimiser
        // stopped vectorising vectorize_map_tail while the reference still did.
        if (!rt && ivStart >= N)
            continue;
        // The header predecessor that is not the latch (same rule the reduction
        // recogniser uses; it spells this as a local `entryBlk` block).
        XTIRBlock* preheader = (ivPhi.operands[0].blockRef == B)
                                   ? ivPhi.operands[2].blockRef
                                   : ivPhi.operands[0].blockRef;
        if (!preheader || preheader == B || preheader == H)
            continue;

        // A trip that is not a whole number of vectors is still vectorisable:
        // the vector loop runs to the last whole vector and a CLONE of this loop
        // finishes the tail. The map case needs no VExit block — with no
        // accumulator to reduce, the only thing handed to the remainder is the
        // induction variable, and that is a constant (M). Mirrored in
        // selfhost/opt/Opt.xc.
        // A RUNTIME bound must be loop-INVARIANT: defined outside H and B, or
        // (a parameter) not defined by any instruction at all, so an absent
        // defBlk entry must NOT read as a refusal. It always takes the epilogue.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        // Under one whole vector: stay scalar. Also what refuses the epilogue
        // CLONE, whose range is shorter than a vector by construction.
        if (!rt && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = laneType;
        c.vw = vw;
        c.vecBytes = vb;
        c.preheader = preheader;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (rt || epiM_ != N);
        c.runtimeTrip = rt;
        c.boundOp = boundOp;
        c.ivStart = ivStart;
        c.ivStartOp = rtStart;
        return c;
        }
    return nil;
    }

// ── Loop cloning, for the vector epilogue ────────────────────────────────
//
// Clone a single-body loop (header H with its phis, body B) into a fresh pair
// with all-new value ids, so the ORIGINAL can be vectorised in place while the
// clone survives as the scalar remainder. Modelled on XTIROptLoopUnroll's clone
// (same three constructor forms — callConv for calls, predicate for ICmp/FCmp,
// plain otherwise, because instructions are immutable and a rebuild must
// preserve their metadata), with one addition it does not need: the header's
// PHIS are cloned too, so phi operands need their BLOCK references remapped as
// well as their value ids.
//
// Returns the cloned header; `outMap` receives old value id -> new value id for
// every result the clone defines, so the caller can seed the clone's phi
// incomings (iv from the vector loop's end, accumulator from its reduction).
static XTIROperand* xtvRemapOperand(XTIROperand* op,
                                    NSDictionary<NSNumber*, NSNumber*>* vmap,
                                    NSDictionary<NSValue*, XTIRBlock*>* bmap)
    {
    if (op.kind == XTIROperandKindBlock)
        {
        XTIRBlock* nb = bmap[[NSValue valueWithNonretainedObject:op.blockRef]];
        return nb ? [XTIROperand blockWithRef:nb] : op;
        }
    if (op.kind != XTIROperandKindUse)
        return op;
    NSNumber* n = vmap[@(op.valueId)];
    return n ? [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue] : op;
    }

static XTIRInsn* xtvCloneInsn(XTIRInsn* insn, XTIRBlock* into, NSUInteger idx,
                              XTIRFunction* fn,
                              NSMutableDictionary<NSNumber*, NSNumber*>* vmap,
                              NSDictionary<NSValue*, XTIRBlock*>* bmap)
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:insn.operands.count];
    for (XTIROperand* o in insn.operands)
        [ops addObject:xtvRemapOperand(o, vmap, bmap)];

    XTIRValue *res = nil, *mem = nil;
    if (insn.result)
        {
        XTIRValueId rid = [fn allocateValueId];
        res = [[XTIRValue alloc] initWithValueId:rid
                                            type:insn.result.type
                                         defSite:[[XTIRDefSite alloc] initWithBlock:into insnIndex:idx]];
        [fn registerValue:res];
        }
    if (insn.memoryResult)
        {
        XTIRValueId mid = [fn allocateValueId];
        mem = [[XTIRValue alloc] initWithValueId:mid
                                            type:[XTIRType memoryType]
                                         defSite:[[XTIRDefSite alloc] initWithBlock:into insnIndex:idx]];
        [fn registerValue:mem];
        }
    XTIRInsn* clone;
    if (insn.callConv)
        clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                          result:res
                                        operands:ops
                                        callConv:insn.callConv
                                          dbgLoc:insn.dbgLoc];
    else if (XTIROpCarriesPredicate(insn.opcode))
        clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                          result:res
                                        operands:ops
                                       predicate:insn.predicate
                                          dbgLoc:insn.dbgLoc];
    else
        clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                          result:res
                                        operands:ops
                                          dbgLoc:insn.dbgLoc];
    clone.memoryResult = mem;
    if (insn.result)
        vmap[@(insn.result.valueId)] = @(res.valueId);
    if (insn.memoryResult)
        vmap[@(insn.memoryResult.valueId)] = @(mem.valueId);
    return clone;
    }

// Clone a loop (header H with its phis + single body B) into a fresh pair with
// all-new value ids. `vmap` receives old id -> new id for everything the clone
// defines. Block references inside the clone are remapped H->H2, B->B2; any
// OTHER block reference (the preheader edge of a phi, the exit target of the
// terminator) is left pointing at the original, for the caller to re-point.
// A block name not already used in `fn`. The first caller gets the name it
// asked for, so single-clone output is unchanged; later ones get _2, _3, ...
static NSString* xtvUniqueBlockName(XTIRFunction* fn, NSString* want)
    {
    NSMutableSet<NSString*>* used = [NSMutableSet set];
    for (XTIRBlock* b in fn.blocks)
        if (b.name)
            [used addObject:b.name];
    if (![used containsObject:want])
        return want;
    for (NSUInteger n = 2; n < 10000; n++)
        {
        NSString* c = [NSString stringWithFormat:@"%@_%lu", want, (unsigned long)n];
        if (![used containsObject:c])
            return c;
        }
    return want;
    }

// The remainder loops this pass made (an epilogue's scalar clone), per
// function. One is never vectorised again: it runs fewer than one vector of
// iterations, and a loop with a runtime start (a par chunk) is accepted, so
// re-recognising it cloned its remainder in turn, 256 deep (the driver's
// iteration cap), turning a 42-line par loop into 20 000 lines.
static NSMutableSet<NSValue*>* sVecRemainders = nil;

static BOOL xtvIsRemainder(XTIRBlock* H)
    {
    return [sVecRemainders containsObject:[NSValue valueWithNonretainedObject:H]];
    }

static void xtvCloneLoop(XTIRFunction* fn, XTIRBlock* H, XTIRBlock* B,
                         XTIRBlock** outH2, XTIRBlock** outB2,
                         NSMutableDictionary<NSNumber*, NSNumber*>* vmap)
    {
    XTIRBlock* H2 = [[XTIRBlock alloc] init];
    XTIRBlock* B2 = [[XTIRBlock alloc] init];
    // UNIQUE names. This used to be a bare `<name>_rem`, which is fine for one
    // clone and wrong for the second: accumulator distribution clones the same
    // loop once per accumulator, so a loop carrying four reductions produced
    // four blocks all called `<hdr>_rem`, the back end emitted the label four
    // times, and the assembler refused the unit — `duplicate label
    // Lpl3Render_bb_36_for_header_rem_pre`. It took a whole 3000-line
    // translation unit to show: a small file distributes nothing.
    H2.name = xtvUniqueBlockName(fn, [NSString stringWithFormat:@"%@_rem", H.name ?: @"hdr"]);
    B2.name = xtvUniqueBlockName(fn, [NSString stringWithFormat:@"%@_rem", B.name ?: @"body"]);

    NSDictionary<NSValue*, XTIRBlock*>* bmap = @{
        [NSValue valueWithNonretainedObject:H] : H2,
        [NSValue valueWithNonretainedObject:B] : B2,
    };

    // PHIS FIRST, and in two passes: a phi's operands may name values defined
    // later in the loop (the back-edge update), so the ids must all exist before
    // any operand is remapped. Pass 1 allocates the results; pass 2 fills in.
    NSMutableArray<XTIRInsn*>* phiClones = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        {
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* res = [[XTIRValue alloc] initWithValueId:rid
                                                       type:phi.result.type
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:H2 insnIndex:0]];
        [fn registerValue:res];
        vmap[@(phi.result.valueId)] = @(rid);
        [phiClones addObject:phi];
        }
    // Body next, so its results are in the map before the phis are filled.
    NSUInteger idx = 0;
    for (XTIRInsn* insn in B.instructions)
        [B2 appendInstruction:xtvCloneInsn(insn, B2, idx++, fn, vmap, bmap)];

    for (XTIRInsn* phi in phiClones)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIROperand* o in phi.operands)
            [ops addObject:xtvRemapOperand(o, vmap, bmap)];
        XTIRValueId rid = (XTIRValueId)vmap[@(phi.result.valueId)].unsignedLongLongValue;
        XTIRValue* res = fn.values[@(rid)];
        [H2.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:res
                                                       operands:ops
                                                         dbgLoc:phi.dbgLoc]];
        }
    // Header's own instructions (the guard), then the terminators.
    idx = 0;
    for (XTIRInsn* insn in H.instructions)
        [H2 appendInstruction:xtvCloneInsn(insn, H2, idx++, fn, vmap, bmap)];
    if (H.terminator)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIROperand* o in H.terminator.operands)
            [ops addObject:xtvRemapOperand(o, vmap, bmap)];
        [H2 setTerminator:[[XTIRInsn alloc] initWithOpcode:H.terminator.opcode
                                                    result:nil
                                                  operands:ops
                                                    dbgLoc:H.terminator.dbgLoc]];
        }
    if (B.terminator)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIROperand* o in B.terminator.operands)
            [ops addObject:xtvRemapOperand(o, vmap, bmap)];
        [B2 setTerminator:[[XTIRInsn alloc] initWithOpcode:B.terminator.opcode
                                                    result:nil
                                                  operands:ops
                                                    dbgLoc:B.terminator.dbgLoc]];
        }
    *outH2 = H2;
    *outB2 = B2;
    }

// ── Runtime vector limit ─────────────────────────────────────────────────
//
// M = ivStart + (max(n - ivStart, 0) & ~(vw-1)), emitted into the preheader.
// The old form, M = n & ~(vw-1), rounded the BOUND down instead of the trip
// length, which is only the same number when ivStart is 0 and n >= 0. It was
// wrong in two ways for `for (i = 2; i < n; i++)`:
//   - n below the start: the remainder phi seeds at M, and M = n & ~7 lands
//     BELOW ivStart — a [2, 1) loop (zero trips scalar) ran its remainder
//     from 0 and wrote a[0] (fuzz seed 267).
//   - a start that is not a multiple of vw: the iv steps ivStart + k*vw, so
//     it never equals n & ~7 and the last vector step overruns it — those
//     elements were then re-applied by the remainder ([2, 20), vw 8: vectors
//     cover 2..17 but M = 16, so 16 and 17 ran twice.
// Computing from the clamped trip length makes M exactly the iv's exit value
// on every path, so the remainder covers [M, n) and nothing else. The clamp
// is a sign-mask (AShr/Not/And) rather than a Select so it stays in the
// basic-ALU subset every vectorising back end already handles.
static XTIRValueId xtvEmitRuntimeM(XTIRFunction* fn, XTIRBlock* PH,
                                   XTIROperand* boundOp, int64_t ivStart,
                                   XTIROperand* startOp,
                                   NSUInteger vw, XTIRType* ivTy)
    {
    XTIROperand* (^emit)(XTIROpcode, NSArray<XTIROperand*>*) =
        ^XTIROperand*(XTIROpcode op, NSArray<XTIROperand*>* ops) {
          XTIRValueId rid = [fn allocateValueId];
          XTIRValue* rv = [[XTIRValue alloc] initWithValueId:rid
                                                        type:ivTy
                                                     defSite:[[XTIRDefSite alloc] initWithBlock:PH insnIndex:0]];
          [fn registerValue:rv];
          [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:op
                                                               result:rv
                                                             operands:ops
                                                               dbgLoc:nil]];
          return [XTIROperand useWithValueId:rid];
        };
    XTIROperand* start = startOp;
    if (!start && ivStart != 0)
        start = [XTIROperand immIWithType:ivTy value:ivStart];
    XTIROperand* tl = start ? emit(XTIROpSub, @[ boundOp, start ]) : boundOp;
    // max(tl, 0): tl & ~(tl >> (bits-1)) — the sign fills the mask when tl is
    // negative, so the And zeroes it; a non-negative tl is left alone.
    XTIROperand* sgn = emit(XTIROpAShr,
                            @[ tl, [XTIROperand immIWithType:[XTIRType u8Type]
                                                       value:(int64_t)(ivTy.byteWidth * 8 - 1)] ]);
    XTIROperand* inv = emit(XTIROpNot, @[ sgn ]);
    XTIROperand* ctl = emit(XTIROpAnd, @[ tl, inv ]);
    XTIROperand* steps = emit(XTIROpAnd,
                              @[ ctl, [XTIROperand immIWithType:ivTy value:~((int64_t)vw - 1)] ]);
    XTIROperand* m = steps;
    if (start)
        m = emit(XTIROpAdd, @[ steps, start ]);
    return m.valueId;
    }

// The vector width this target's profile allows: 16 bytes, 32 under -mavx2
// (SIMD step 1, S2), or 64 under -mavx512. Map, reduce and min/max loops take it; the
// widening forms (u8/u16 sums and products) stay at 16 until the back ends
// can emit their 256-bit shapes.
- (NSUInteger)vectorBytes
    {
    NSUInteger b = sVecFnBytes ? sVecFnBytes
                               : (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorLaneBytes;
    return b == 64 ? 64 : b == 32 ? 32 : 16;
    }

- (void)apply:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock* B = c.B;
    XTIRType* vecTy = [XTIRType vecWithLane:c.laneType bytes:(uint32_t)c.vecBytes];

    // ── Epilogue, part 1: clone the scalar loop BEFORE anything below mutates
    // it. The vector transform overwrites B's instructions in place, so the
    // remainder has to be taken now or not at all.
    XTIRBlock *H2 = nil, *B2 = nil;
    XTIRValueId runtimeMId = 0; // the computed vector limit, when the trip is runtime
    NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
    if (c.needsEpilogue)
        {
        xtvCloneLoop(fn, c.H, B, &H2, &B2, cmap);
        [sVecRemainders addObject:[NSValue valueWithNonretainedObject:H2]];
        // The vector loop now stops at the largest whole number of vectors; the
        // clone picks up from there and runs to the original bound (its own
        // guard, cloned, still tests against the original n).
        NSMutableArray<XTIROperand*>* gops = [c.guard.operands mutableCopy];
        if (c.runtimeTrip)
            {
            XTIRValueId mid = xtvEmitRuntimeM(fn, c.preheader, c.boundOp,
                                              c.ivStart, c.ivStartOp, c.vw,
                                              c.ivPhi.result.type);
            runtimeMId = mid;
            gops[1] = [XTIROperand useWithValueId:mid];
            }
        else
            {
            gops[1] = [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
            }
        [c.guard replaceOperands:gops];
        }

    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;

    NSMutableArray<XTIRInsn*>* newBody = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];  // scalar id → vector value
    NSMutableDictionary<NSNumber*, XTIRValue*>* splat = [NSMutableDictionary dictionary]; // scalar id → splat vector

    // Block each value is defined in (for the entry-hoist invariance test below).
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defBlk[@(i.result.valueId)] = bb;
    // Hoist invariant splats to the loop's PREHEADER, not the function entry.
    //
    // Entry was wrong, and dangerously so: the arm64 vector register pool is
    // v18..v31, every one of them CALLER-saved under AAPCS, and the allocator
    // has no call-clobber handling at all. A splat parked in the entry block
    // lives for the whole function, so any `bl` between it and the loop
    // destroys it -- the loop then adds whatever the callee left behind.
    // Reproduced as `gb[i] = ga[i] + 10` writing 112,115,118,121, where the
    // "splat" register held a vector of another array's data (#1134).
    //
    // The preheader keeps the compute-once property while making the range too
    // short to span a call -- and a vectorised loop body cannot itself contain a
    // call, since every recogniser rejects one, so entry-hoisted splats were the
    // only vector values that could ever cross one. applyCountReduction already
    // hoisted to the preheader; this brings the map applier into line. The
    // acceptance rules below are unchanged and remain sound: entry dominates the
    // preheader, so anything that dominated entry dominates it too.
    XTIRBlock* entry = c.preheader ?: fn.blocks.firstObject;
    NSMutableDictionary<NSString*, XTIRValue*>* entrySplatCache = [NSMutableDictionary dictionary];

    XTIRValue* (^newVecIn)(XTIRBlock*) = ^XTIRValue*(XTIRBlock* home) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:vecTy
                                                defSite:[[XTIRDefSite alloc] initWithBlock:home insnIndex:0]];
      [fn registerValue:v];
      return v;
    };
    XTIRValue* (^newVec)(void) = ^XTIRValue* {
      return newVecIn(B);
    };

    // Hoist a LOOP-INVARIANT operand's VSplat to the function ENTRY block. Entry
    // dominates every loop — including any enclosing one — so the broadcast is
    // materialised ONCE on the way in instead of every iteration, and it stays
    // correct under nesting (unlike hoisting to a specific preheader, which is
    // what made the earlier general LICM-splat attempt miscompile nested loops).
    // A compile-time constant is rematerialised in entry; a param or an
    // entry-defined value is splatted in place. Returns nil when the operand
    // isn't provably entry-dominating, and the caller keeps the in-body splat.
    XTIROperand* (^entrySplat)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (!entry || entry == B || entry == c.H)
          return nil; // no distinct entry
      int64_t kv;
      BOOL isConst = resolveConstInt(op, defOf, &kv);
      NSString* ck = isConst ? [NSString stringWithFormat:@"c%lld", (long long)kv]
                             : (op.kind == XTIROperandKindUse ? [NSString stringWithFormat:@"v%llu",
                                                                                           (unsigned long long)op.valueId]
                                                              : nil);
      if (ck && entrySplatCache[ck])
          return [XTIROperand useWithValueId:entrySplatCache[ck].valueId];
      XTIROperand* scalar;
      if (isConst)
          {
          XTIRValue* cst = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                         type:c.laneType
                                                      defSite:[[XTIRDefSite alloc] initWithBlock:entry insnIndex:0]];
          [fn registerValue:cst];
          [entry.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                  result:cst
                                                                operands:@[ [XTIROperand immIWithType:c.laneType value:kv] ]
                                                                  dbgLoc:nil]];
          scalar = [XTIROperand useWithValueId:cst.valueId];
          }
      else if (op.kind == XTIROperandKindUse)
          {
          // A param has no defining insn (available at entry); an entry-defined
          // value dominates the rest of entry. Anything defined mid-CFG can't be
          // referenced from entry — keep it in the body. A nil defBlk proves
          // NOTHING beyond "not defined when the map was built": defBlk is
          // computed once at pass entry, and a value CREATED by vectorising an
          // earlier loop (e.g. the new outer-loop phi carrying `rep`) is absent
          // from it. Treating absent as param hoisted a splat of a loop-carried
          // value to entry — it read the local's default 0 and the vectorised
          // loop silently dropped the addend. Only a REAL param may hoist on nil.
          XTIRBlock* db = defBlk[@(op.valueId)];
          if (db && db != entry)
              return nil;
          if (!db && op.valueId >= fn.paramTypes.count)
              return nil;
          scalar = op;
          }
      else
          {
          return nil;
          }
      XTIRValue* sp = newVecIn(entry);
      [entry.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                              result:sp
                                                            operands:@[ scalar ]
                                                              dbgLoc:nil]];
      if (ck)
          entrySplatCache[ck] = sp;
      return [XTIROperand useWithValueId:sp.valueId];
    };

    // The vector form of a scalar body operand: a previously-vectorised value, an
    // entry-hoisted broadcast of a loop-invariant scalar, or (fallback) a per-body
    // VSplat.
    XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* vv = vmap[@(op.valueId)];
          if (vv)
              return [XTIROperand useWithValueId:vv.valueId]; // elementwise (loop-varying)
          }
      XTIROperand* hoisted = entrySplat(op); // loop-invariant → splat once in entry
      if (hoisted)
          return hoisted;
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* sp = splat[@(op.valueId)];
          if (!sp)
              {
              sp = newVec();
              [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ op ]
                                                           dbgLoc:nil]];
              splat[@(op.valueId)] = sp;
              }
          return [XTIROperand useWithValueId:sp.valueId];
          }
      // Immediate: materialise a splat from it directly.
      XTIRValue* sp = newVec();
      [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                   result:sp
                                                 operands:@[ op ]
                                                   dbgLoc:nil]];
      return [XTIROperand useWithValueId:sp.valueId];
    };

    for (XTIRInsn* insn in B.instructions)
        {
        if (insn == c.ivNext)
            {
            // Step the induction variable by the vector width.
            XTIROperand *a0 = insn.operands[0], *a1 = insn.operands[1];
            BOOL ivLeft = (a0.kind == XTIROperandKindUse && a0.valueId == c.ivId);
            XTIROperand* ivOp = ivLeft ? a0 : a1;
            XTIROperand* vwOp = [XTIROperand immIWithType:insn.result.type value:(int64_t)c.vw];
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                         result:insn.result
                                                       operands:@[ ivOp, vwOp ]
                                                         dbgLoc:insn.dbgLoc]];
            continue;
            }
        switch (insn.opcode)
            {
        case XTIROpAddrOf:
        case XTIROpElementAddr:
        case XTIROpConst:
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
            [newBody addObject:insn]; // kept scalar (address / splat
                                      // source / dead step plumbing)
            break;
        case XTIROpLoad:
            {
            XTIRValue* vr = newVec();
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vr
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc]; // [ea, mem]
            vl.memoryResult = insn.memoryResult;                          // preserve mem chain
            [newBody addObject:vl];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        case XTIROpStore:
            {
            XTIROperand* vval = vecOperand(insn.operands[1]);
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            ops[1] = vval;
            XTIRInsn* vs = [[XTIRInsn alloc] initWithOpcode:XTIROpVStore
                                                     result:nil
                                                   operands:ops
                                                     dbgLoc:insn.dbgLoc]; // [ea, vval, mem]
            vs.memoryResult = insn.memoryResult;
            [newBody addObject:vs];
            break;
            }
        // elementwise arith
        default:
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVec();
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:vectorOpFor(insn.opcode)
                                                         result:vr
                                                       operands:@[ va, vb ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
            }
        }

    [B.instructions setArray:newBody];

    // ── Epilogue, part 2: the vector loop falls into the remainder instead of
    // the exit, through a LANDING PAD (VE) that does nothing but branch.
    //
    // The empty block is load-bearing, and the map case is where that shows.
    // Sending the vector loop straight to H2 looks right — a map carries
    // nothing out but the induction variable, which enters as the constant M —
    // and it works until LoopRotate gives the vector loop its SECOND exit (the
    // body's own back-edge test). That new edge then lands directly on a
    // phi-carrying header without an incoming for it, so the iv is undefined on
    // entry and the remainder is skipped: `for (i = 0; i < 5; i++) b[i] = ...`
    // wrote four elements and left the fifth untouched. Funnelling every vector
    // exit through one pred keeps H2's phis well-formed however the loop is
    // later reshaped. (The reduction epilogue gets this for free — its VE is
    // where the horizontal reduce lands.) Pinned by vectorize_map_tail.xc.
    if (c.needsEpilogue)
        {
        XTIRBlock *H = c.H, *E = c.E, *PH = c.preheader;
        XTIRBlock* VE = [[XTIRBlock alloc] init];
        VE.name = [NSString stringWithFormat:@"%@_vexit", H.name ?: @"hdr"];
        [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H2] ]
                                                    dbgLoc:nil]];

        NSMutableArray<XTIROperand*>* tops = [H.terminator.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:VE];
        [H.terminator replaceOperands:tops];

        // Seed the clone: its iv enters at M, on the edge from VE — which is
        // where the clone's phis still name the ORIGINAL preheader.
        XTIRValueId ivCloneId = (XTIRValueId)cmap[@(c.ivPhi.result.valueId)].unsignedLongLongValue;
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                {
                if (!(pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH))
                    continue;
                pops[k] = [XTIROperand blockWithRef:VE];
                if (phi.result.valueId == ivCloneId)
                    pops[k + 1] = c.runtimeTrip
                                      ? [XTIROperand useWithValueId:runtimeMId]
                                      : [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
                }
            [phi replaceOperands:pops];
            }

        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ VE, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];
        }
    }

// ── Reduction recognition ────────────────────────────────────────────────
//
// Recognises `for (i=0; i<N; i++) acc += elem(a[i])` — a loop whose header
// carries the induction phi AND a single associative-add accumulator phi, with
// no store in the body. Shares the induction-variable / guard / latch shape
// with the map recogniser above; the extra structure is the accumulator phi
// `acc` whose back-edge value is `accNext = Add(acc, elem)`, where `elem` is an
// iv-indexed elementwise value (a load, or arith over loads / invariants).
- (nullable XTVecCand*)recogniseReduction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count != 2)
            continue; // induction + accumulator

        // FLOAT reductions reassociate the additions, so they are taken only
        // where the source grants it AND the target can lower the lane ops. A
        // `par` block is :goal(speed) by default and its run function carries
        // the loop header in `speedLoopHeaders`; both must be true. This is the
        // gate that makes nbody's `ax += mass[j]*dx/(d2*sqrt(d2))` legal.
        BOOL floatRedux = (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesFloatReduce
                          && fn.speedLoopHeaders && H.name
                          && [fn.speedLoopHeaders containsObject:H.name];

        // header pure (just the guard)
        BOOL hp = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                hp = NO;
                break;
                }
        if (!hp)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2 || guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        // the guarded value must be one of the header phis (the induction var);
        // the other phi is the accumulator.
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        // The bound may be a literal or a RUNTIME value. A runtime bound is
        // accepted only when loop-INVARIANT (checked below, once the body block
        // is known) and the guard is a STRICT less-than: with `i <= n` the trip
        // count is n+1 and the vector limit n & ~(vw-1) is simply wrong. The
        // constant path is left exactly as it was -- it has always assumed `<`
        // without checking, and tightening it here would alter accepted loops.
        int64_t N = 0;
        BOOL constBound = resolveConstIntExt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        // body B latches to H unconditionally; E is the other target.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock *B = nil, *E = nil;
        if (latch(t0))
            {
            B = t0;
            E = t1;
            }
        else if (latch(t1))
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        if (!E || B.instructions.count == 0)
            continue;
        // The horizontal reduce is inserted at the top of E; if E carried a phi
        // referencing the accumulator on the H→E edge, rewiring it to the reduce
        // result (defined later in E) would be invalid SSA. Bail on exit phis.
        if (E.phiNodes.count != 0)
            continue;

        // ivNext = Add(i, 1), back-edge of the iv phi, used once.
        if (ivPhi.operands.count != 4 || accPhi.operands.count != 4)
            continue;
        XTIROperand* (^backOp)(XTIRInsn*) = ^XTIROperand*(XTIRInsn* phi) {
          return (phi.operands[0].blockRef == B)   ? phi.operands[1]
                 : (phi.operands[2].blockRef == B) ? phi.operands[3]
                                                   : nil;
        };
        // The VALUE paired with the entry (non-latch) block: operands are
        // (block, value) pairs, so the entry value is index 3 when B is the
        // first pair, else index 1.
        XTIROperand* (^entryOp)(XTIRInsn*) = ^XTIROperand*(XTIRInsn* phi) {
          return (phi.operands[0].blockRef == B) ? phi.operands[3] : phi.operands[1];
        };
        XTIRBlock* (^entryBlk)(XTIRInsn*) = ^XTIRBlock*(XTIRInsn* phi) {
          return (phi.operands[0].blockRef == B) ? phi.operands[2].blockRef : phi.operands[0].blockRef;
        };
        XTIROperand* nextOp = backOp(ivPhi);
        if (!nextOp || nextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ivNext = defOf[@(nextOp.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlk[@(nextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(nextOp.valueId)] != 1)
            continue;
        int64_t step = 0;
        XTIROperand* stepOp = nil;
        if (ivNext.operands[0].kind == XTIROperandKindUse && ivNext.operands[0].valueId == ivId)
            stepOp = ivNext.operands[1];
        else if (ivNext.operands[1].kind == XTIROperandKindUse && ivNext.operands[1].valueId == ivId)
            stepOp = ivNext.operands[0];
        if (!stepOp || !resolveConstInt(stepOp, defOf, &step) || step != 1)
            continue;

        // accNext = back-edge value of the accumulator phi: Add(acc, elem),
        // defined in B and used exactly once (by the phi).
        XTIROperand* accNextOp = backOp(accPhi);
        if (!accNextOp || accNextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accNextOp.valueId)];
        // Else, at the default goal, an ORDERED float sum where the loop has
        // lane work worth it (a square root, a divide: nbody's): the elements
        // are computed lane-wise and added to the scalar sum one by one, in
        // order, so nothing is reassociated. Looked for in both of the
        // header's successors, as the port does.
        BOOL orderedRedux = NO;
        if (!floatRedux && (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesOrderedFloat &&
            H.terminator && H.terminator.operands.count >= 3)
            for (NSUInteger q = 1; q < 3 && !orderedRedux; q++)
                {
                XTIRBlock* sb = H.terminator.operands[q].blockRef;
                for (XTIRInsn* si in sb.instructions)
                    if (si.opcode == XTIROpFSqrt || si.opcode == XTIROpFDiv)
                        {
                        orderedRedux = YES;
                        break;
                        }
                }
        BOOL floatLanes = floatRedux || orderedRedux;
        // An ADD, or a FLOAT add in a float reduction (the reassociation gate).
        BOOL accIsAdd = accNext && (accNext.opcode == XTIROpAdd ||
                                    (floatLanes && accNext.opcode == XTIROpFAdd));
        if (!accIsAdd || defBlk[@(accNextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(accNextOp.valueId)] != 1)
            continue;
        XTIROperand* elemOp = nil;
        if (accNext.operands[0].kind == XTIROperandKindUse && accNext.operands[0].valueId == accId)
            elemOp = accNext.operands[1];
        else if (accNext.operands[1].kind == XTIROperandKindUse && accNext.operands[1].valueId == accId)
            elemOp = accNext.operands[0];
        if (!elemOp || elemOp.kind != XTIROperandKindUse)
            continue;
        XTIROperand* initOp = entryOp(accPhi);
        XTIRBlock* preheader = entryBlk(accPhi);
        if (!initOp || !preheader || preheader == B || preheader == H)
            continue;

        // The carry (accId) must be used inside the loop ONLY by accNext; the
        // induction var (ivId) must not escape H/B (guard + index + ivNext).
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        hp = NO;
                        break;
                        }
            }
        if (!hp)
            continue;
        BOOL accClean = YES;
        for (XTIRBlock* bb in @[ H, B ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        accClean = NO;
                        break;
                        }
                if (!accClean)
                    break;
                }
            if (!accClean)
                break;
            }
        if (!accClean)
            continue;

        // Classify the body's elementwise computation (no store; the reduce is
        // the output). Same allowed set as the map path, minus Store, plus the
        // ivNext / accNext we handle specially.
        XTIRType* laneType = nil;
        BOOL ok = YES, sawLoad = NO;
        NSMutableSet<NSNumber*>* elemIds = [NSMutableSet set];
        // IOTA. The per-lane value does not have to come from memory: in
        // `acc += f(r)` the element IS the induction variable, and there is no
        // array anywhere. Seeding the element set with the iv makes every
        // instruction that reads it elementwise, exactly as a Load's result is.
        // `usesIv` records whether the body actually did read it, so a loop with
        // neither loads nor iv uses is still refused.
        BOOL wantIota = (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesIota;
        BOOL usesIv = NO;
        XTIRType* ivTy = ivPhi.result.type;
        BOOL ivLaneOK = ivTy && (ivTy.kind == XTIRTypeKindI32 || ivTy.kind == XTIRTypeKindU32);
        if (wantIota && ivLaneOK)
            [elemIds addObject:@(ivId)];
        NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* divMagic = nil;
        BOOL (^isElemAddrAtIv)(XTIROperand*) = ^BOOL(XTIROperand* p) {
          if (p.kind != XTIROperandKindUse)
              return NO;
          XTIRInsn* ea = defOf[@(p.valueId)];
          if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2)
              return NO;
          if (ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
              return NO;
          return YES;
        };
        BOOL (^elemOperandOK)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          if (o.kind == XTIROperandKindImmI)
              return YES;
          if (o.kind != XTIROperandKindUse)
              return NO;
          if ([elemIds containsObject:@(o.valueId)])
              return YES;
          // A CONSTANT literal, int or FLOAT (a float const's bits are not an
          // int, so resolveConstInt alone missed `d2 + 0.0001` in a float
          // reduction). It is loop-invariant whatever block it sits in.
          XTIRInsn* cd = defOf[@(o.valueId)];
          if (cd && cd.opcode == XTIROpConst)
              return YES;
          int64_t kk;
          if (resolveConstInt(o, defOf, &kk))
              return YES;
          XTIRBlock* db = defBlk[@(o.valueId)];
          return db != nil && db != B && db != H;
        };
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == ivNext || insn == accNext)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf)
                continue;
            if (op == XTIROpElementAddr)
                {
                if (insn.operands.count < 2 ||
                    insn.operands[1].kind != XTIROperandKindUse || insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                XTIROperand* base = insn.operands[0];
                if (base.kind == XTIROperandKindUse && defBlk[@(base.valueId)] == B)
                    {
                    XTIRInsn* bd = defOf[@(base.valueId)];
                    if (!bd || bd.opcode != XTIROpAddrOf)
                        {
                        ok = NO;
                        break;
                        }
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                // A fully DEAD load — its value AND its memory token unused
                // anywhere — has no effect, so skip it rather than refuse the
                // loop: a static-init guard's leftover flag load can sit in a
                // loop body, and a body with any non-iv memory op was refused,
                // which kept nbody's float reduction scalar.
                if (insn.result && [uses countForObject:@(insn.result.valueId)] == 0 &&
                    (!insn.memoryResult || [uses countForObject:@(insn.memoryResult.valueId)] == 0))
                    continue;
                if (insn.operands.count < 1 || !isElemAddrAtIv(insn.operands[0]) || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                if (!lt || !(lt.kind == XTIRTypeKindI32 || lt.kind == XTIRTypeKindU32 ||
                             (floatLanes && lt.kind == XTIRTypeKindF32)))
                    {
                    ok = NO;
                    break;
                    }
                if (laneType && laneType.kind != lt.kind)
                    {
                    ok = NO;
                    break;
                    }
                laneType = lt;
                sawLoad = YES;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            // A STORE of an elementwise value to an iv-indexed address, alongside
            // the reduction: saxpy's `v = 3*xs[i]+ys[i]; ys[i] = v; total += v`.
            // The stored value is already in the elementwise set (it is exactly
            // what the reduction folds), so the address is the only new shape and
            // it must be an iv-indexed ElementAddr, the same one a Load uses. The
            // applier turns this into a VStore; no lane type is taken from it.
            if (op == XTIROpStore)
                {
                if (insn.operands.count < 2 || !isElemAddrAtIv(insn.operands[0]) ||
                    !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                continue;
                }
            if (op == XTIROpConst || op == XTIROpZExt || op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            // A value computed from constants alone (`32 - c`): itself a
            // constant, which its users read as one.
            int64_t kq = 0;
            if (insn.result && resolveConstInt([XTIROperand useWithValueId:insn.result.valueId], defOf, &kq))
                continue;
            // A shift LEFT by a compile-time amount, as the shift right below
            // (a rotate is one of each: MD5's rounds), lowered as VShl.
            if (op == XTIROpShl &&
                (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesLaneShift)
                {
                int64_t sh = 0;
                if (insn.result &&
                    (insn.result.type.kind == XTIRTypeKindI32 ||
                     insn.result.type.kind == XTIRTypeKindU32) &&
                    insn.operands.count >= 2 && elemOperandOK(insn.operands[0]) &&
                    resolveConstInt(insn.operands[1], defOf, &sh) && sh >= 0 && sh < 32)
                    {
                    if (insn.operands[0].kind == XTIROperandKindUse &&
                        insn.operands[0].valueId == ivId)
                        usesIv = YES;
                    [elemIds addObject:@(insn.result.valueId)];
                    continue;
                    }
                ok = NO;
                break;
                }
            // A bitwise not (one operand), lowered as VNot; gated with the
            // shifts (the back ends that lower those lower this).
            if (op == XTIROpNot &&
                (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesLaneShift)
                {
                if (insn.result &&
                    (insn.result.type.kind == XTIRTypeKindI32 ||
                     insn.result.type.kind == XTIRTypeKindU32) &&
                    insn.operands.count >= 1 && elemOperandOK(insn.operands[0]))
                    {
                    if (insn.operands[0].kind == XTIROperandKindUse &&
                        insn.operands[0].valueId == ivId)
                        usesIv = YES;
                    [elemIds addObject:@(insn.result.valueId)];
                    continue;
                    }
                ok = NO;
                break;
                }
            // Unsigned division by a compile-time constant. There is no lane
            // divide; it becomes a magic multiply, which needs the HIGH half of
            // the lane product. Only the simple magic form is taken (see
            // xtvMagicU32) and only where the back end can lower VMulHi.
            if (op == XTIROpUDiv &&
                (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesHighMultiply)
                {
                int64_t dv = 0;
                uint64_t M; int sh;
                if (insn.result && insn.result.type.kind == XTIRTypeKindU32 &&
                    insn.operands.count >= 2 && elemOperandOK(insn.operands[0]) &&
                    resolveConstInt(insn.operands[1], defOf, &dv) && dv > 1 &&
                    xtvMagicU32((uint64_t)dv, &M, &sh))
                    {
                    if (!divMagic)
                        divMagic = [NSMutableDictionary dictionary];
                    divMagic[@(insn.result.valueId)] = @[ @(M), @(sh) ];
                    [elemIds addObject:@(insn.result.valueId)];
                    continue;
                    }
                ok = NO;
                break;
                }
            // A logical shift right by a COMPILE-TIME amount. There is no
            // lane-wise variable shift here, and none is needed: every shift in
            // the shapes this recognises is by a literal. Gated on the flag that
            // says the back end lowers VLShr — emitting it where it is not
            // lowered is silence, not a build failure.
            if (op == XTIROpLShr &&
                (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorizesLaneShift)
                {
                int64_t sh = 0;
                if (insn.result &&
                    (insn.result.type.kind == XTIRTypeKindI32 ||
                     insn.result.type.kind == XTIRTypeKindU32) &&
                    insn.operands.count >= 2 && elemOperandOK(insn.operands[0]) &&
                    resolveConstInt(insn.operands[1], defOf, &sh) && sh >= 0 && sh < 32)
                    {
                    if (insn.operands[0].kind == XTIROperandKindUse &&
                        insn.operands[0].valueId == ivId)
                        usesIv = YES;
                    [elemIds addObject:@(insn.result.valueId)];
                    continue;
                    }
                ok = NO;
                break;
                }
            // FLOAT lane ops, only in a float reduction: a lane square root
            // (nbody's `sqrt(d2)`) and a lane divide (`mass*dx / (d2*sqrt)`).
            // Both produce f32 lanes, which is what the lane type records.
            if (floatLanes && (op == XTIROpFSqrt || op == XTIROpFDiv))
                {
                if (!insn.result || insn.result.type.kind != XTIRTypeKindF32)
                    {
                    ok = NO;
                    break;
                    }
                NSUInteger want = (op == XTIROpFSqrt) ? 1 : 2;
                BOOL good = insn.operands.count >= want;
                for (NSUInteger k = 0; good && k < want; k++)
                    if (!elemOperandOK(insn.operands[k]))
                        good = NO;
                if (!good)
                    {
                    ok = NO;
                    break;
                    }
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            if (elementwiseArith(op))
                {
                if (!insn.result || !(insn.result.type.kind == XTIRTypeKindI32 ||
                                      insn.result.type.kind == XTIRTypeKindU32 ||
                                      (floatLanes && insn.result.type.kind == XTIRTypeKindF32)))
                    {
                    ok = NO;
                    break;
                    }
                if (insn.operands.count < 2 ||
                    !elemOperandOK(insn.operands[0]) || !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        usesIv = YES;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            ok = NO;
            break; // Store, call, per-lane-varying scalar, etc.
            }
        // With loads, the lane type comes from them. With none, the elements ARE
        // the induction variable and its type is the lane type.
        if (!laneType && wantIota && ivLaneOK && usesIv)
            laneType = ivTy;
        if (!ok || !laneType || !(sawLoad || (wantIota && usesIv)))
            continue;
        // The reduced element must itself be an elementwise (per-lane) value —
        // not a loop-invariant (that would be `acc += k`, a scaled count, not a
        // lane-wise reduction).
        if (![elemIds containsObject:@(elemOp.valueId)])
            continue;
        // A big body must fit the vector registers: the back ends do not spill
        // a vector, and running out is a build error.
        if (B.instructions.count > XTIR_VEC_SPLAT_BIG_BODY &&
            !vecScalarBodyFits(B, elemIds, vecPoolFor(fn, self.profile ?: [XTIROptTargetProfile conservativeProfile])))
            continue;
        // The accumulator lane type must match the loads (i32/u32 add, or f32
        // in a float reduction).
        if (!(accNext.result.type.kind == XTIRTypeKindI32 ||
              accNext.result.type.kind == XTIRTypeKindU32 ||
              (floatLanes && accNext.result.type.kind == XTIRTypeKindF32)))
            continue;
        if (accNext.result.type.kind != laneType.kind)
            continue;

        NSUInteger vb = [self vectorBytes];
        NSUInteger vw = vb / laneType.byteWidth; // 4 for i32 at 16 bytes
        if (vw < 2)
            continue;

        // The induction variable's START matters, and nothing used to check it.
        // The guard gives the BOUND, not the trip count: a loop from S runs
        // N - S times, and stepping by vw from S lands exactly on N only when
        // (N - S) is a whole number of vectors. With the old `N % vw` test a
        // loop like `for (i = 1; i < 64; i++)` was accepted — 64 % 4 == 0 —
        // while its real trip is 63, so the last vector read one element PAST
        // the array. Requiring a known S fixes that and is also what stops the
        // remainder loop below from being re-recognised as if it started at 0
        // (it starts at M, and re-analysing it re-clones it, without bound).
        XTIROperand* ivInitOp = entryOp(ivPhi);
        int64_t ivStart = 0;
        XTIROperand* ivStartOp = nil;
        XTIROperand* redBoundImm = nil;  // a literal bound, once a runtime start made the trip runtime
        if (!ivInitOp)
            continue;
        if (!resolveConstInt(ivInitOp, defOf, &ivStart))
            {
            // The induction variable does not start at a literal. This is the
            // normal shape of a `par` chunk: the loop runs [lo, hi) and both are
            // runtime values, so EVERY par loop used to be refused here and the
            // whole CPU path stayed scalar. A runtime start is vectorisable: the
            // vector loop begins at it and steps by vw, and the runtime limit is
            // computed from (bound - start) in the preheader, exactly as a
            // runtime BOUND already is. What the transform needs is that the
            // start is loop-INVARIANT (defined outside H and B), because it is
            // read once, in the preheader, to seed both.
            if (ivInitOp.kind != XTIROperandKindUse)
                continue;
            XTIRBlock* sb = defBlk[@(ivInitOp.valueId)];
            if (sb == H || sb == B)
                continue;
            // The constant-bound epilogue arithmetic below assumes a known
            // start; with a runtime start, only the runtime-trip path works,
            // so a literal bound becomes a runtime trip, the bound as an
            // immediate (the limit is computed in the preheader, ahead of the
            // header holding its Const). Mirrors the self-hosted vecReductionAt.
            if (!runtimeTrip)
                {
                runtimeTrip = YES;
                redBoundImm = [XTIROperand immIWithType:ivPhi.result.type value:N];
                }
            ivStartOp = ivInitOp;
            ivStart = 0;
            }
        if (!runtimeTrip && N <= ivStart)
            continue;
        // A NON-ZERO start is refused outright, and this is a BUG FIX, not a
        // conservative choice. The transform steps the existing iv phi by vw and
        // keeps the guard, which is only equivalent to the scalar loop when the
        // counter begins at 0; with `for (i = 1; i < 64; i++)` it produced a
        // WRONG ANSWER (1956 for a sum that is 2016) at -O2 and above, on every
        // vectorising back end, and had done so before this epilogue existed:
        // XTVEC_REDUX_OFF=1 gives the right answer, redux on gives 1956.
        // tests/fixtures/vectorize_const_tail.xc pins both shapes. Supporting a
        // non-zero start means rebasing the vector iv to 0, which is a separate
        // change; until then these loops stay scalar and CORRECT.
        // A non-zero start needs NOTHING here: the epilogue below is already
        // computed from the trip length (`trip_ = N - ivStart`), so it splits
        // [ivStart, N) into whole vectors plus a scalar tail. The refusal that
        // stood here was obsolete the moment that epilogue landed — verified by
        // lifting it: `for (i = 1; i < 64; i++) s += a[i]` gives 2016 and emits
        // NEON, where refusing gave 2016 scalar and no vector ops at all.

        // A trip that is not a whole number of vectors is still vectorisable:
        // the vector loop runs to the last whole vector and a CLONE of this loop
        // finishes the tail (xtvCloneLoop + the wiring in applyReduction).
        // Mirrored in selfhost/opt/Opt.xc.
        // A RUNTIME bound always takes the epilogue: how many whole vectors fit
        // is not knowable here, so the limit is computed in the preheader and
        // the clone runs [M, n). No separate `n < vw` guard is needed -- that
        // case gives M = 0, the vector loop's own guard fails at once, and the
        // clone runs the whole range from 0, the scalar loop unchanged. The
        // bound must be loop-INVARIANT: a value with NO defining instruction is
        // a parameter, invariant by construction, so an absent defBlk entry
        // must not read as a refusal.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = redBoundImm ? nil : defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        if (!runtimeTrip && epiM_ != N && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = laneType;
        c.vw = vw;
        c.vecBytes = vb;
        c.isReduction = YES;
        c.isIota = (wantIota && usesIv);
        c.isOrdered = orderedRedux;
        c.divMagic = divMagic;
        c.accPhi = accPhi;
        c.accNext = accNext;
        c.accId = accId;
        c.elemId = elemOp.valueId;
        c.seedOp = initOp;
        c.preheader = preheader;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = redBoundImm ?: guard.operands[1];
        c.ivStart = ivStart;
        c.ivStartOp = ivStartOp;
        return c;
        }
    return nil;
    }

- (void)applyReduction:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader;
    // Defining instruction per value, so a constant reached through a ZExt or
    // a Const can be recognised and splatted once in the preheader.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;
    // Value ids used anywhere, so the body walk can drop a fully dead load
    // exactly as the recogniser skipped it.
    NSCountedSet<NSNumber*>* vecUsed = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* i in bb.instructions)
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindUse)
                    [vecUsed addObject:@(o.valueId)];
        for (XTIRInsn* p in bb.phiNodes)
            for (XTIROperand* o in p.operands)
                if (o.kind == XTIROperandKindUse)
                    [vecUsed addObject:@(o.valueId)];
        if (bb.terminator)
            for (XTIROperand* o in bb.terminator.operands)
                if (o.kind == XTIROperandKindUse)
                    [vecUsed addObject:@(o.valueId)];
        }

    // ── Epilogue, part 1: clone the scalar loop BEFORE anything below mutates
    // it. The vector transform overwrites B's instructions in place and rewrites
    // H's phis, so the remainder has to be taken now or not at all.
    XTIRBlock *H2 = nil, *B2 = nil;
    NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
    XTIRValueId runtimeMId = 0; // the computed vector limit, when the trip is runtime
    if (c.needsEpilogue)
        {
        xtvCloneLoop(fn, H, B, &H2, &B2, cmap);
        [sVecRemainders addObject:[NSValue valueWithNonretainedObject:H2]];
        // The vector loop now stops at the largest whole number of vectors; the
        // clone picks up from there and runs to the original bound (its own
        // guard, cloned, still tests against the original n).
        NSMutableArray<XTIROperand*>* gops = [c.guard.operands mutableCopy];
        if (c.runtimeTrip)
            {
            XTIRValueId mid = xtvEmitRuntimeM(fn, PH, c.boundOp, c.ivStart,
                                              c.ivStartOp, c.vw, c.ivPhi.result.type);
            runtimeMId = mid;
            gops[1] = [XTIROperand useWithValueId:mid];
            }
        else
            {
            gops[1] = [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
            }
        [c.guard replaceOperands:gops];
        }
    XTIRType* vecTy = [XTIRType vecWithLane:c.laneType bytes:(uint32_t)c.vecBytes];

    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    NSMutableArray<XTIRInsn*>* newBody = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRValue*>* splat = [NSMutableDictionary dictionary];

    // A splat of a COMPILE-TIME CONSTANT belongs in the preheader, not the body:
    // it is the same vector on every iteration. The count applier has done this
    // since it was written; this one did not, so `a[i] * 7` rebuilt the splat of
    // 7 every iteration — `mov w3,#7; mov w4,w3; dup v24.4s,w4` — three
    // instructions per iteration of int_muldiv's hot loop for a constant.
    //
    // A non-constant operand still splats in the body, where it is correct
    // whether or not it is invariant.
    NSMutableDictionary<NSNumber*, XTIRValue*>* phSplatCache = [NSMutableDictionary dictionary];
    // A large body (MD5's 64 rounds) holds no constant splats in registers
    // across the loop: it needs them for its own values. Past a few, neither
    // does any other; and in a large one each use has its own splat.
    BOOL splatBig = B.instructions.count > XTIR_VEC_SPLAT_BIG_BODY;
    XTIROperand* (^phSplat)(XTIROperand*, int64_t) = ^XTIROperand*(XTIROperand* op, int64_t kv) {
      NSNumber* key = @(kv);
      if (phSplatCache[key])
          return [XTIROperand useWithValueId:phSplatCache[key].valueId];
      if (splatBig || phSplatCache.count >= XTIR_VEC_SPLAT_HOIST_MAX)
          {
          XTIRValue* bc = newVal(c.laneType);
          [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                       result:bc
                                                     operands:@[ [XTIROperand immIWithType:c.laneType
                                                                                     value:kv] ]
                                                       dbgLoc:nil]];
          XTIRValue* bs = newVal(vecTy);
          [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                       result:bs
                                                     operands:@[ [XTIROperand useWithValueId:bc.valueId] ]
                                                       dbgLoc:nil]];
          return [XTIROperand useWithValueId:bs.valueId];
          }
      XTIRValue* cst = newVal(c.laneType);
      [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                           result:cst
                                                         operands:@[ [XTIROperand immIWithType:c.laneType
                                                                                         value:kv] ]
                                                           dbgLoc:nil]];
      XTIRValue* sp = newVal(vecTy);
      [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ [XTIROperand useWithValueId:cst.valueId] ]
                                                           dbgLoc:nil]];
      phSplatCache[key] = sp;
      return [XTIROperand useWithValueId:sp.valueId];
    };

    XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* vv = vmap[@(op.valueId)];
          if (vv)
              return [XTIROperand useWithValueId:vv.valueId];
          int64_t kv;
          if (PH && resolveConstInt(op, defOf, &kv))
              return phSplat(op, kv);
          XTIRValue* sp = splatBig ? nil : splat[@(op.valueId)];
          if (!sp)
              {
              sp = newVal(vecTy);
              [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ op ]
                                                           dbgLoc:nil]];
              if (!splatBig)
                  splat[@(op.valueId)] = sp;
              }
          return [XTIROperand useWithValueId:sp.valueId];
          }
      if (PH && op.kind == XTIROperandKindImmI)
          return phSplat(op, op.intValue);
      XTIRValue* sp = newVal(vecTy);
      [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                   result:sp
                                                 operands:@[ op ]
                                                   dbgLoc:nil]];
      return [XTIROperand useWithValueId:sp.valueId];
    };

    // The vector accumulator phi (created below) — its result id is needed when
    // the body's VAdd consumes it.
    XTIRValue* vacc = newVal(vecTy);

    // IOTA. The per-lane value is derived from the induction variable, so lane l
    // of this iteration must hold i+l, not i. Splatting i would give every lane
    // the same value and compute a different answer.
    //
    //   preheader:  viota = VLoad(&__xtv_iota_<fn>_4)     <0,1,2,3>, once
    //   body:       viv   = VAdd(VSplat(i), viota)        <i,i+1,i+2,i+3>
    //
    // Mapping the iv to viv makes every existing rule below work unchanged: the
    // arithmetic on i vectorises through `vecOperand` exactly as arithmetic on a
    // loaded element does. VSplat and VAdd are already lowered everywhere, and
    // the lane-index vector needs no lane-insert sequence and no literal pool.
    if (c.isIota && PH)
        {
        XTIRSymbolId iotaSym = xtvIotaSymbol(c.laneType, c.vecBytes, fn);
        XTIRValue* iotaPtr = newVal([XTIRType ptrToType:c.laneType window:0]);
        [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                                             result:iotaPtr
                                                           operands:@[ [XTIROperand symWithSymbolId:iotaSym] ]
                                                             dbgLoc:nil]];
        XTIRValue* viota = newVal(vecTy);
        [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                             result:viota
                                                           operands:@[ [XTIROperand useWithValueId:iotaPtr.valueId] ]
                                                             dbgLoc:nil]];
        XTIRValue* vsp = newVal(vecTy);
        [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                     result:vsp
                                                   operands:@[ [XTIROperand useWithValueId:c.ivId] ]
                                                     dbgLoc:nil]];
        XTIRValue* viv = newVal(vecTy);
        [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                                     result:viv
                                                   operands:@[ [XTIROperand useWithValueId:vsp.valueId],
                                                               [XTIROperand useWithValueId:viota.valueId] ]
                                                     dbgLoc:nil]];
        vmap[@(c.ivId)] = viv;
        }

    for (XTIRInsn* insn in B.instructions)
        {
        // step iv by the vector width
        if (insn == c.ivNext)
            {
            XTIROperand *a0 = insn.operands[0], *a1 = insn.operands[1];
            BOOL ivLeft = (a0.kind == XTIROperandKindUse && a0.valueId == c.ivId);
            XTIROperand* ivOp = ivLeft ? a0 : a1;
            XTIROperand* vwOp = [XTIROperand immIWithType:insn.result.type value:(int64_t)c.vw];
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                         result:insn.result
                                                       operands:@[ ivOp, vwOp ]
                                                         dbgLoc:insn.dbgLoc]];
            continue;
            }
        // ordered: acc + e[0] + e[1] + ..., the lanes in order, scalar.
        if (insn == c.accNext && c.isOrdered)
            {
            XTIROperand* ve = vecOperand([XTIROperand useWithValueId:c.elemId]);
            XTIRValueId t = c.accPhi.result.valueId;
            for (NSUInteger k = 0; k < c.vw; k++)
                {
                XTIRValue* x = newVal(c.laneType);
                [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVExtract
                                                             result:x
                                                           operands:@[ ve, [XTIROperand immIWithType:[XTIRType u32Type]
                                                                                                value:(int64_t)k] ]
                                                             dbgLoc:insn.dbgLoc]];
                XTIRValue* sum = (k + 1 == c.vw) ? insn.result : newVal(c.laneType);
                [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpFAdd
                                                             result:sum
                                                           operands:@[ [XTIROperand useWithValueId:t],
                                                                       [XTIROperand useWithValueId:x.valueId] ]
                                                             dbgLoc:insn.dbgLoc]];
                t = sum.valueId;
                }
            continue;
            }
        // vacc += vec(elem)
        if (insn == c.accNext)
            {
            XTIRValue* vnext = newVal(vecTy);
            XTIROperand* velem = vecOperand([XTIROperand useWithValueId:c.elemId]);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                                         result:vnext
                                                       operands:@[ [XTIROperand useWithValueId:vacc.valueId], velem ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vnext; // accNext id → vector next
            continue;
            }
        // A value computed from constants alone stays the scalar it is; its
        // users read it as a constant.
        int64_t kq = 0;
        if (insn.result && insn.opcode != XTIROpAddrOf && insn.opcode != XTIROpElementAddr &&
            resolveConstInt([XTIROperand useWithValueId:insn.result.valueId], defOf, &kq))
            {
            [newBody addObject:insn];
            continue;
            }
        switch (insn.opcode)
            {
        case XTIROpAddrOf:
        case XTIROpElementAddr:
        case XTIROpConst:
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
            [newBody addObject:insn];
            break;
        case XTIROpLoad:
            {
            // Mirror the recogniser: a load that is fully DEAD (its value and
            // memory token unused) has no vector form and is dropped, so a
            // guard's leftover flag load does not become a bogus VLoad.
            if (insn.result && [vecUsed countForObject:@(insn.result.valueId)] == 0 &&
                (!insn.memoryResult || [vecUsed countForObject:@(insn.memoryResult.valueId)] == 0))
                break;
            XTIRValue* vr = newVal(vecTy);
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vr
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vl.memoryResult = insn.memoryResult;
            [newBody addObject:vl];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // A store of an elementwise value: the vectorised form writes the whole
        // vector at once. Mirrors the map applier; the recogniser has already
        // proved the address is iv-indexed and the value is elementwise.
        case XTIROpStore:
            {
            XTIROperand* vval = vecOperand(insn.operands[1]);
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            ops[1] = vval;
            XTIRInsn* vs = [[XTIRInsn alloc] initWithOpcode:XTIROpVStore
                                                     result:nil
                                                   operands:ops
                                                     dbgLoc:insn.dbgLoc];
            vs.memoryResult = insn.memoryResult;
            [newBody addObject:vs];
            break;
            }
        // `x / d` with d a compile-time constant: mulhu(x, M) >>u s. The
        // recogniser has already proved the simple magic form applies, so a
        // failure here would mean the two disagreed — bail rather than emit
        // something that computes a different answer from the scalar loop.
        case XTIROpUDiv:
            {
            // The magic comes from the candidate, derived when the loop was
            // recognised. There is no fallback: a UDiv reaching here that the
            // recogniser did not clear would mean the loop should never have
            // been accepted, and the only "generic" lowering available is a
            // vector UDiv that no back end implements.
            NSArray<NSNumber*>* mg = c.divMagic[@(insn.result.valueId)];
            NSAssert(mg != nil, @"UDiv in a vectorised reduction with no magic");
            if (!mg)
                {
                [newBody addObject:insn];
                break;
                }
            uint64_t M = mg[0].unsignedLongLongValue;
            int sh = mg[1].intValue;
            XTIROperand* vm = vecOperand([XTIROperand immIWithType:c.laneType
                                                              value:(int64_t)M]);
            XTIROperand* vx = vecOperand(insn.operands[0]);
            XTIRValue* hi = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVMulHi
                                                         result:hi
                                                       operands:@[ vx, vm ]
                                                         dbgLoc:insn.dbgLoc]];
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVLShr
                                                         result:vr
                                                       operands:@[ [XTIROperand useWithValueId:hi.valueId],
                                                                   [XTIROperand immIWithType:c.laneType
                                                                                       value:sh] ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // Shift right by a constant: the lane-wise form takes the amount as an
        // immediate, not a splatted vector, so the operand is NOT run through
        // vecOperand. Splatting it would produce a lane-wise variable shift that
        // no back end here implements.
        case XTIROpLShr:
            {
            int64_t sh = 0;
            if (!resolveConstInt(insn.operands[1], defOf, &sh))
                {
                [newBody addObject:insn]; // recogniser and applier disagree
                break;
                }
            XTIROperand* vx = vecOperand(insn.operands[0]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVLShr
                                                         result:vr
                                                       operands:@[ vx,
                                                                   [XTIROperand immIWithType:c.laneType
                                                                                       value:sh] ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // Shift left by a constant: as the shift right, the amount an
        // immediate.
        case XTIROpShl:
            {
            int64_t sh = 0;
            if (!resolveConstInt(insn.operands[1], defOf, &sh))
                {
                [newBody addObject:insn]; // recogniser and applier disagree
                break;
                }
            XTIROperand* vx = vecOperand(insn.operands[0]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVShl
                                                         result:vr
                                                       operands:@[ vx,
                                                                   [XTIROperand immIWithType:c.laneType
                                                                                       value:sh] ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // A bitwise not: one operand.
        case XTIROpNot:
            {
            XTIROperand* vx = vecOperand(insn.operands[0]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVNot
                                                         result:vr
                                                       operands:@[ vx ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // A lane square root (one operand) and a lane divide, both float and
        // both only reachable from a float reduction the recogniser accepted.
        case XTIROpFSqrt:
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSqrt
                                                         result:vr
                                                       operands:@[ va ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        case XTIROpFDiv:
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVDiv
                                                         result:vr
                                                       operands:@[ va, vb ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // elementwise arith
        default:
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:vectorOpFor(insn.opcode)
                                                         result:vr
                                                       operands:@[ va, vb ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
            }
        }
    [B.instructions setArray:newBody];

    // An ordered sum keeps its scalar accumulator phi, and nothing is reduced
    // at the exit: the remainder (if any) starts from the scalar total.
    NSMutableArray<XTIRInsn*>* head = [NSMutableArray array];
    XTIRValueId outId = c.accPhi.result.valueId;
    XTIRInsn* rd = nil;
    if (!c.isOrdered)
    {
    XTIRValue* vnext = vmap[@(c.accNext.result.valueId)]; // vector accNext id

    // Vector accumulator phi: [(preheader, vacc0), (B, vnext)]. The preheader
    // initialises the lanes to 0 (a VSplat of a scalar zero). vacc / vacc0 /
    // vnext are coalesced onto one v-register by the backend (associative
    // in-place accumulate), so the back-edge needs no copy.
    XTIRValue* vacc0 = newVal(vecTy);
    XTIRValue* zero = newVal(c.laneType);
    XTIRInsn* zc = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                             result:zero
                                           operands:@[ [XTIROperand immIWithType:c.laneType value:0] ]
                                             dbgLoc:nil];
    XTIRInsn* sp = [[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                             result:vacc0
                                           operands:@[ [XTIROperand useWithValueId:zero.valueId] ]
                                             dbgLoc:nil];
    // Insert init before the preheader's terminator.
    [PH.instructions addObject:zc];
    [PH.instructions addObject:sp];

    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    // Replace the scalar accumulator phi with the vector one; keep the iv phi.
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        if (phi != c.accPhi)
            [newPhis addObject:phi];
    [newPhis addObject:vphi];
    [H.phiNodes setArray:newPhis];

    // Horizontal reduce at loop exit: scalar = addv(vacc); if the accumulator
    // started non-zero, add the initial scalar back. Rewire external uses of
    // the old scalar accumulator phi to the reduced result.
    XTIRValue* red = newVal(c.laneType);
    rd = [[XTIRInsn alloc] initWithOpcode:XTIROpVReduceAdd
                                   result:red
                                 operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                   dbgLoc:nil];
    [head addObject:rd];
    outId = red.valueId;
    int64_t initK = 0;
    BOOL initIsZero = resolveConstInt(c.seedOp, ({
                                          NSMutableDictionary<NSNumber*, XTIRInsn*>* d = [NSMutableDictionary dictionary];
                                          for (XTIRBlock* bb in fn.blocks)
                                              for (XTIRInsn* i in bb.instructions)
                                                  if (i.result)
                                                      d[@(i.result.valueId)] = i;
                                          d;
                                      }),
                                      &initK) &&
                      initK == 0;
    if (!initIsZero)
        {
        XTIRValue* withInit = newVal(c.laneType);
        // FADD for a float lane: the seed is an f32 (nbody's 0.0f) and an
        // integer Add with s-registers is not an encodable instruction.
        BOOL laneF = c.laneType.kind == XTIRTypeKindF32 || c.laneType.kind == XTIRTypeKindF64;
        [head addObject:[[XTIRInsn alloc] initWithOpcode:(laneF ? XTIROpFAdd : XTIROpAdd)
                                                  result:withInit
                                                operands:@[ [XTIROperand useWithValueId:red.valueId], c.seedOp ]
                                                  dbgLoc:nil]];
        outId = withInit.valueId;
        }
    }
    // ── Epilogue, part 2: the reduction lands in a new block between the vector
    // loop and the remainder, because the remainder's accumulator STARTS from it.
    XTIRValueId finalId = outId;
    if (c.needsEpilogue)
        {
        XTIRBlock* VE = [[XTIRBlock alloc] init];
        VE.name = [NSString stringWithFormat:@"%@_vexit", H.name ?: @"hdr"];
        for (XTIRInsn* i in head)
            [VE appendInstruction:i];
        [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H2] ]
                                                    dbgLoc:nil]];

        // The vector loop exits to VE instead of E.
        NSMutableArray<XTIROperand*>* tops = [H.terminator.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:VE];
        [H.terminator replaceOperands:tops];

        // Seed the clone: its iv enters at M, its accumulator at the reduced
        // vector total. Both arrive on the edge from VE, which is where the
        // clone's phis still name the ORIGINAL preheader.
        XTIRValueId ivCloneId = (XTIRValueId)cmap[@(c.ivPhi.result.valueId)].unsignedLongLongValue;
        XTIRValueId accCloneId = (XTIRValueId)cmap[@(c.accPhi.result.valueId)].unsignedLongLongValue;
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                {
                if (!(pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH))
                    continue;
                pops[k] = [XTIROperand blockWithRef:VE];
                if (phi.result.valueId == ivCloneId)
                    pops[k + 1] = c.runtimeTrip
                                      ? [XTIROperand useWithValueId:runtimeMId]
                                      : [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
                else if (phi.result.valueId == accCloneId)
                    pops[k + 1] = [XTIROperand useWithValueId:outId];
                }
            [phi replaceOperands:pops];
            }
        // Everything after the loop reads the REMAINDER's accumulator now.
        finalId = accCloneId;

        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ VE, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];
        }
    else
        {
        [E.instructions insertObjects:head
                            atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, head.count)]];
        }

    // Rewire uses of the old scalar accumulator (outside H/B) to the reduce.
    for (XTIRBlock* bb in fn.blocks)
        {
        // The clone is a copy of the ORIGINAL loop and legitimately reads the
        // original accumulator id through its own remapped values; rewriting
        // inside it would point the remainder at its own result.
        if (bb == H || bb == B || bb == H2 || bb == B2)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                {
                XTIROperand* o = ops[k];
                if (o.kind == XTIROperandKindUse && o.valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:finalId];
                    changed = YES;
                    }
                }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

// ── Min/max reduction recognition ────────────────────────────────────────
//
// `for (i<N) if (a[i] <cmp> m) m = a[i]` lowers to a diamond the if-converter
// can't linearise (the then-arm reloads a[i], a Load it won't speculate). We
// recognise the diamond directly: header carries the iv + accumulator phis; the
// loop body is { head: load+compare+condbranch, then: [reload], join: phi }.
// Transformed to a vector umax/umin accumulate + a horizontal umaxv/uminv.
- (nullable XTVecCand*)recogniseMaxMin:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                {
                defOf[@(p.result.valueId)] = p;
                defBlk[@(p.result.valueId)] = bb;
                }
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                {
                defOf[@(i.result.valueId)] = i;
                defBlk[@(i.result.valueId)] = bb;
                }
        }

    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2 || guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        if (!resolveConstInt(guard.operands[1], defOf, &N) || N <= 0)
            continue;

        // Both the preheader (loop entry) and the latch (back-edge) branch to H,
        // so distinguish by block order: the latch follows H (back-edge), the
        // preheader precedes it. Both phis must agree on the same latch.
        NSUInteger idxH = [fn.blocks indexOfObjectIdenticalTo:H];
        XTIRBlock* (^incoming)(XTIRInsn*, BOOL) = ^XTIRBlock*(XTIRInsn* phi, BOOL wantLatch) {
          XTIRBlock *b0 = phi.operands[0].blockRef, *b1 = phi.operands[2].blockRef;
          NSUInteger i0 = [fn.blocks indexOfObjectIdenticalTo:b0];
          NSUInteger i1 = [fn.blocks indexOfObjectIdenticalTo:b1];
          if (i0 == NSNotFound || i1 == NSNotFound)
              return nil;
          BOOL b0latch = i0 > idxH; // back-edge source follows H
          if (wantLatch)
              return b0latch ? b0 : b1;
          return b0latch ? b1 : b0;
        };
        XTIRBlock* L = incoming(accPhi, YES);
        XTIRBlock* PH = incoming(accPhi, NO);
        if (!L || !PH || L == H || L == PH)
            continue;
        if (incoming(ivPhi, YES) != L)
            continue; // both phis latch via L
        if (!L.terminator || L.terminator.opcode != XTIROpBranch ||
            L.terminator.operands.count < 1 || L.terminator.operands[0].blockRef != H)
            continue;

        // L (join): preds {body, then}; holds accNext phi + ivNext add + Branch H.
        if (L.phiNodes.count != 1 || L.terminator.opcode != XTIROpBranch)
            continue;
        XTIRInsn* accNextPhi = L.phiNodes[0];
        if (!accNextPhi.result || accNextPhi.operands.count != 4)
            continue;
        // accPhi's back-edge value must be this join phi.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == L) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse || accBack.valueId != accNextPhi.result.valueId)
            continue;

        // Body = guard target that is a pred of L (the diamond head); exit = other.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        XTIRBlock *jb0 = accNextPhi.operands[0].blockRef, *jb1 = accNextPhi.operands[2].blockRef;
        XTIRBlock *B = nil, *E = nil;
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
            continue;
        XTIRBlock* TH = (jb0 == B) ? jb1 : jb0; // the then arm
        if (!B || !E || !TH || B == TH)
            continue;
        if (B.phiNodes.count != 0 || E.phiNodes.count != 0)
            continue;

        // Body: ElementAddr(base,iv) + Load(elem) + ICmp(elem,acc), ends in
        // CondBranch(cmp, {TH or L}, {L or TH}). No other memory/side effects.
        XTIRInsn* bterm = B.terminator;
        if (!bterm || bterm.opcode != XTIROpCondBranch || bterm.operands.count < 3)
            continue;
        if (bterm.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* cmp = defOf[@(bterm.operands[0].valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || defBlk[@(bterm.operands[0].valueId)] != B)
            continue;
        XTIRValueId elemId = 0;
        XTIRType* laneType = nil;
        BOOL ok = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf)
                continue;
            if (op == XTIROpElementAddr)
                {
                if (insn.operands.count < 2 || insn.operands[1].kind != XTIROperandKindUse ||
                    insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindUse || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRInsn* ea = defOf[@(insn.operands[0].valueId)];
                if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
                    ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                if (!lt || !(lt.kind == XTIRTypeKindI32 || lt.kind == XTIRTypeKindU32))
                    {
                    ok = NO;
                    break;
                    }
                elemId = insn.result.valueId;
                laneType = lt;
                continue;
                }
            if (op == XTIROpICmp || op == XTIROpConst || op == XTIROpZExt ||
                op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            ok = NO;
            break;
            }
        if (!ok || !laneType || elemId == 0)
            continue;

        // then arm: pred = B only, no phis, pure-ish (only a reload of elem), Branch L.
        if (TH.phiNodes.count != 0 || !TH.terminator || TH.terminator.opcode != XTIROpBranch ||
            TH.terminator.operands.count < 1 || TH.terminator.operands[0].blockRef != L)
            continue;
        for (XTIRInsn* insn in TH.instructions)
            {
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpElementAddr || op == XTIROpLoad)
                continue;
            ok = NO;
            break;
            }
        if (!ok)
            continue;

        // join phi arms: one arm == acc (kept when not selected), the other ==
        // elem (the reload, or elemId directly). The acc-arm comes from B, the
        // elem-arm from TH (matching the `if (cmp) m = a[i]` shape).
        XTIROperand* armFromB = (accNextPhi.operands[0].blockRef == B) ? accNextPhi.operands[1] : accNextPhi.operands[3];
        XTIROperand* armFromTH = (accNextPhi.operands[0].blockRef == TH) ? accNextPhi.operands[1] : accNextPhi.operands[3];
        if (armFromB.kind != XTIROperandKindUse || armFromB.valueId != accId)
            continue;
        if (armFromTH.kind != XTIROperandKindUse)
            continue;
        BOOL armIsElem = (armFromTH.valueId == elemId);
        // a reload of the same element
        if (!armIsElem)
            {
            XTIRInsn* rl = defOf[@(armFromTH.valueId)];
            if (!rl || rl.opcode != XTIROpLoad || defBlk[@(armFromTH.valueId)] != TH ||
                rl.operands.count < 1 || rl.operands[0].kind != XTIROperandKindUse)
                continue;
            XTIRInsn* ea = defOf[@(rl.operands[0].valueId)];
            if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
                ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
                continue;
            }

        // ivNext = Add(iv,1) in L, used once (the iv phi back-edge).
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in L.instructions)
            if (insn.opcode == XTIROpAdd && insn.result)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == L) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Classify max vs min + signedness from the compare (operands are elem
        // and acc; the elem arm of the select is chosen when cmp is true).
        XTIROperand *ca = cmp.operands[0], *cb = cmp.operands[1];
        BOOL cmpElemLeft;
        if (ca.kind == XTIROperandKindUse && ca.valueId == elemId &&
            cb.kind == XTIROperandKindUse && cb.valueId == accId)
            cmpElemLeft = YES;
        else if (ca.kind == XTIROperandKindUse && ca.valueId == accId &&
                 cb.kind == XTIROperandKindUse && cb.valueId == elemId)
            cmpElemLeft = NO;
        else
            continue;
        uint8_t pred = cmp.predicate;
        BOOL gtFam = (pred == XTIRICmpUGT || pred == XTIRICmpSGT || pred == XTIRICmpUGE || pred == XTIRICmpSGE);
        BOOL ltFam = (pred == XTIRICmpULT || pred == XTIRICmpSLT || pred == XTIRICmpULE || pred == XTIRICmpSLE);
        if (!gtFam && !ltFam)
            continue;
        BOOL signedCmp = (pred == XTIRICmpSGT || pred == XTIRICmpSLT || pred == XTIRICmpSGE || pred == XTIRICmpSLE);
        if (signedCmp != (laneType.kind == XTIRTypeKindI32))
            continue;
        // cmp true selects elem. elem-is-larger ⟺ max.
        //  elem-left  GT  → elem>acc → true keeps elem(larger) → MAX
        //  elem-left  LT  → MIN ;  acc-left GT → acc>elem → keep elem(smaller) → MIN ; acc-left LT → MAX
        BOOL isMax = cmpElemLeft ? gtFam : ltFam;

        XTIROperand* seedOp = (accPhi.operands[0].blockRef == L) ? accPhi.operands[3] : accPhi.operands[1];

        NSUInteger vb = [self vectorBytes];
        NSUInteger vw = vb / laneType.byteWidth;
        // The iteration space is [ivStart, N), so it is the trip LENGTH that must
        // be a whole number of vectors — not the bound. Gating on `N % vw` was
        // right only for a zero start, and silently wrong for any other: with
        // `for (i = 2; i < 16; i++)` and vw=4 it accepted 16%4==0 while the real
        // length is 14, which is how the vector store ran past the range.
        // These two recognisers have no epilogue, so an uneven length stays
        // scalar; the three that do take the tail instead.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, L, defOf, &ivStart))
            continue;
        if (ivStart >= N)
            continue;
        if (vw < 2 || (((N - ivStart) % (int64_t)vw) != 0))
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = laneType;
        c.vw = vw;
        c.vecBytes = vb;
        c.accPhi = accPhi;
        c.accId = accId;
        c.elemId = elemId;
        c.seedOp = seedOp;
        c.preheader = PH;
        c.isMaxMin = YES;
        c.isMax = isMax;
        c.mmThen = TH;
        c.mmLatch = L;
        return c;
        }
    return nil;
    }

- (void)applyMaxMin:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader, *L = c.mmLatch;
    XTIRType* vecTy = [XTIRType vecWithLane:c.laneType bytes:(uint32_t)c.vecBytes];
    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    XTIRValue* vacc = newVal(vecTy);

    // Rebuild B as the single straight-line vector latch: keep the address
    // computation, vector-load the element, fold it into the accumulator with
    // VMax/VMin, step the iv by the vector width, then branch to H.
    NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
    XTIRValue* vload = nil;
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn.opcode == XTIROpLoad && insn.result && insn.result.valueId == c.elemId)
            {
            vload = newVal(vecTy);
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vload
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vl.memoryResult = insn.memoryResult;
            [nb addObject:vl];
            }
        else if (insn.opcode == XTIROpAddrOf || insn.opcode == XTIROpElementAddr ||
                 insn.opcode == XTIROpConst)
            {
            [nb addObject:insn]; // keep address plumbing
            }
        // ICmp / casts are dropped (folded into the vector min/max).
        }
    XTIRValue* vnext = newVal(vecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:(c.isMax ? XTIROpVMax : XTIROpVMin)
                                            result:vnext
                                          operands:@[ [XTIROperand useWithValueId:vacc.valueId], [XTIROperand useWithValueId:vload.valueId] ]
                                            dbgLoc:nil]];
    XTIRValue* ivNext = newVal(c.ivNext.result.type);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                            result:ivNext
                                          operands:@[ [XTIROperand useWithValueId:c.ivId],
                                                      [XTIROperand immIWithType:c.ivNext.result.type
                                                                          value:(int64_t)c.vw] ]
                                            dbgLoc:nil]];
    [B.instructions setArray:nb];
    [B resetTerminator];
    [B setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                               result:nil
                                             operands:@[ [XTIROperand blockWithRef:H] ]
                                               dbgLoc:nil]];

    // Vector accumulator phi in H: init = splat(seed) (min/max are idempotent,
    // so seeding all lanes is correct without an end-combine); back-edge = vnext
    // from B (the new latch). Replace the scalar accumulator phi.
    XTIRValue* vacc0 = newVal(vecTy);
    XTIRInsn* sp = [[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                             result:vacc0
                                           operands:@[ c.seedOp ]
                                             dbgLoc:nil];
    [PH.instructions addObject:sp];
    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        {
        if (phi == c.accPhi)
            {
            [newPhis addObject:vphi];
            continue;
            }
        // iv phi: retarget its back-edge from the old latch L to the new latch B.
        NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
        for (NSUInteger k = 0; k + 1 < ops.count; k += 2)
            {
            if (ops[k].kind == XTIROperandKindBlock && ops[k].blockRef == L)
                {
                ops[k] = [XTIROperand blockWithRef:B];
                ops[k + 1] = [XTIROperand useWithValueId:ivNext.valueId];
                }
            }
        [phi replaceOperands:ops];
        [newPhis addObject:phi];
        }
    [H.phiNodes setArray:newPhis];

    // The memory chain has to be repaired BEFORE the diamond goes: the scalar
    // loop threaded its token through the then-arm's reload, so post-loop code
    // reads a token defined in a block that is about to disappear. Every memory
    // result defined in the arm or the join becomes the surviving VLoad's token
    // (the loop's last memory op). Without this the exit block references a
    // value with no definition — the printer spells it `%?36`, and a backend
    // that resolves tokens by id would read a dead slot.
    NSMutableSet<NSNumber*>* goneMem = [NSMutableSet set];
    for (XTIRBlock* bb in @[ c.mmThen, L ])
        for (XTIRInsn* insn in bb.instructions)
            {
            if (insn.memoryResult)
                [goneMem addObject:@(insn.memoryResult.valueId)];
            if (insn.result)
                [goneMem addObject:@(insn.result.valueId)];
            }
    XTIRValueId liveMem = vload.valueId; // placeholder; replaced below
    for (XTIRInsn* insn in B.instructions)
        if (insn.memoryResult)
            liveMem = insn.memoryResult.valueId;
    if (goneMem.count)
        {
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == L || bb == c.mmThen)
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                {
                NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                BOOL changed = NO;
                for (NSUInteger k = 0; k < ops.count; k++)
                    if (ops[k].kind == XTIROperandKindUse &&
                        [goneMem containsObject:@(ops[k].valueId)])
                        {
                        ops[k] = [XTIROperand useWithValueId:liveMem];
                        changed = YES;
                        }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        }

    // Drop the now-dead diamond arm + join.
    NSMutableArray<XTIRBlock*>* keep = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        if (bb != L && bb != c.mmThen)
            [keep addObject:bb];
    [fn.blocks setArray:keep];

    // Horizontal reduce at the exit; rewire live-out uses of the old accumulator.
    XTIRValue* red = newVal(c.laneType);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:(c.isMax ? XTIROpVReduceMax : XTIROpVReduceMin)
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    [E.instructions insertObject:rd atIndex:0];
    for (XTIRBlock* bb in fn.blocks)
        {
        if (bb == H || bb == B)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:red.valueId];
                    changed = YES;
                    }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

// ── Conditional-count reduction recognition ──────────────────────────────
//
// `for (i<N) if (a[i] <cmp> k) c += d` — if-converts to a straight-line body
// whose accumulator back-edge is `accNext = Select(ICmp(elem,k), Add(acc,d), acc)`.
// It is an additive reduction with a masked increment, so vectorise it as
// `vacc += (VICmp(vload, splat k) & splat d)` + a horizontal add at exit. The
// body (Select) and the iv-step often sit in separate blocks (body → join →
// header); we vectorise the body block in place and only re-step the iv.
- (nullable XTVecCand*)recogniseCountReduction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2 || guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        if (!resolveConstInt(guard.operands[1], defOf, &N) || N <= 0)
            continue;

        // Latch L (back-edge block, follows H); preheader precedes H. Both phis agree.
        NSUInteger idxH = [fn.blocks indexOfObjectIdenticalTo:H];
        XTIRBlock* (^incoming)(XTIRInsn*, BOOL) = ^XTIRBlock*(XTIRInsn* phi, BOOL wantLatch) {
          XTIRBlock *b0 = phi.operands[0].blockRef, *b1 = phi.operands[2].blockRef;
          NSUInteger i0 = [fn.blocks indexOfObjectIdenticalTo:b0];
          NSUInteger i1 = [fn.blocks indexOfObjectIdenticalTo:b1];
          if (i0 == NSNotFound || i1 == NSNotFound)
              return nil;
          BOOL b0latch = i0 > idxH;
          if (wantLatch)
              return b0latch ? b0 : b1;
          return b0latch ? b1 : b0;
        };
        XTIRBlock* L = incoming(accPhi, YES);
        XTIRBlock* PH = incoming(accPhi, NO);
        if (!L || !PH || L == H || L == PH || incoming(ivPhi, YES) != L)
            continue;
        if (!L.terminator || L.terminator.opcode != XTIROpBranch ||
            L.terminator.operands.count < 1 || L.terminator.operands[0].blockRef != H ||
            L.phiNodes.count != 0)
            continue;

        // B = guard target that leads into the loop (== L when merged, else a
        // single-successor block that branches to L). E = the other guard target.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^leadsToL)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b == L || (b && b != H && b.phiNodes.count == 0 && b.terminator &&
                            b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                            b.terminator.operands[0].blockRef == L);
        };
        XTIRBlock *B = nil, *E = nil;
        if (leadsToL(t0))
            {
            B = t0;
            E = t1;
            }
        else if (leadsToL(t1))
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        if (!E || E.phiNodes.count != 0)
            continue;

        // accNext = acc phi back-edge value: a Select defined in B.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == L) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accBack.valueId)];
        if (!accNext || accNext.opcode != XTIROpSelect || accNext.operands.count < 3 ||
            defBlk[@(accBack.valueId)] != B)
            continue;
        if ([uses countForObject:@(accBack.valueId)] != 1)
            continue;
        // Select(cmp, Add(acc, delta), acc): cond true → increment (canonical).
        XTIROperand *condOp = accNext.operands[0], *tOp = accNext.operands[1], *fOp = accNext.operands[2];
        if (condOp.kind != XTIROperandKindUse || tOp.kind != XTIROperandKindUse ||
            fOp.kind != XTIROperandKindUse)
            continue;
        if (fOp.valueId != accId)
            continue; // unselected arm keeps acc
        XTIRInsn* incr = defOf[@(tOp.valueId)];
        if (!incr || incr.opcode != XTIROpAdd || defBlk[@(tOp.valueId)] != B)
            continue;
        XTIROperand* deltaOp = nil;
        if (incr.operands[0].kind == XTIROperandKindUse && incr.operands[0].valueId == accId)
            deltaOp = incr.operands[1];
        else if (incr.operands[1].kind == XTIROperandKindUse && incr.operands[1].valueId == accId)
            deltaOp = incr.operands[0];
        if (!deltaOp)
            continue;
        int64_t deltaK;
        if (!resolveConstInt(deltaOp, defOf, &deltaK))
            continue; // invariant increment
        XTIRInsn* cmp = defOf[@(condOp.valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2 || defBlk[@(condOp.valueId)] != B)
            continue;

        // ivNext = Add(iv,1) in the latch L (== B when the body is merged), the
        // iv phi's back-edge. Found before classification so the body classifier
        // can skip it (when merged it shares the block with the count plumbing).
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in L.instructions)
            if (insn.opcode == XTIROpAdd && insn.result)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == L) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Classify B: the elementwise computation feeding the compare. Skip the
        // count plumbing (the compare, the increment Add, the Select, the iv step).
        XTIRType* laneType = nil;
        BOOL ok = YES;
        XTIRValueId elemId = 0;
        NSMutableSet<NSNumber*>* elemIds = [NSMutableSet set];
        BOOL (^isElemAddrAtIv)(XTIROperand*) = ^BOOL(XTIROperand* p) {
          if (p.kind != XTIROperandKindUse)
              return NO;
          XTIRInsn* ea = defOf[@(p.valueId)];
          return ea && ea.opcode == XTIROpElementAddr && ea.operands.count >= 2 &&
                 ea.operands[1].kind == XTIROperandKindUse && ea.operands[1].valueId == ivId;
        };
        BOOL (^elemOperandOK)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          if (o.kind == XTIROperandKindImmI)
              return YES;
          if (o.kind != XTIROperandKindUse)
              return NO;
          if ([elemIds containsObject:@(o.valueId)])
              return YES;
          int64_t kk;
          if (resolveConstInt(o, defOf, &kk))
              return YES;
          XTIRBlock* db = defBlk[@(o.valueId)];
          return db != nil && db != B && db != L && db != H;
        };
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == cmp || insn == incr || insn == accNext || insn == ivNext)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpConst || op == XTIROpZExt ||
                op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            if (op == XTIROpElementAddr)
                {
                if (insn.operands.count < 2 || insn.operands[1].kind != XTIROperandKindUse ||
                    insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || !isElemAddrAtIv(insn.operands[0]) || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                // A NARROW element counts too: the compare and mask run at the
                // load's width and climb to the accumulator's with VAddLP. A
                // narrow lane only ever holds ONE iteration's mask before being
                // widened — the accumulation happens at 32 bits — so there is no
                // overflow to reason about beyond the delta fitting the lane.
                if (!lt || !(lt.kind == XTIRTypeKindI32 || lt.kind == XTIRTypeKindU32 ||
                             lt.kind == XTIRTypeKindI8  || lt.kind == XTIRTypeKindU8 ||
                             lt.kind == XTIRTypeKindI16 || lt.kind == XTIRTypeKindU16))
                    {
                    ok = NO;
                    break;
                    }
                if (laneType && laneType.kind != lt.kind)
                    {
                    ok = NO;
                    break;
                    }
                laneType = lt;
                elemId = insn.result.valueId;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            if (elementwiseArith(op))
                {
                if (!insn.result || insn.operands.count < 2 ||
                    !elemOperandOK(insn.operands[0]) || !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            ok = NO;
            break;
            }
        if (!ok || !laneType || elemId == 0)
            continue;
        // The compare must be elem-vs-invariant: one operand elementwise, the
        // other loop-invariant (constant or defined outside the loop).
        BOOL c0elem = cmp.operands[0].kind == XTIROperandKindUse && [elemIds containsObject:@(cmp.operands[0].valueId)];
        BOOL c1elem = cmp.operands[1].kind == XTIROperandKindUse && [elemIds containsObject:@(cmp.operands[1].valueId)];
        if (c0elem == c1elem)
            continue; // exactly one side elementwise
        XTIROperand* kSide = c0elem ? cmp.operands[1] : cmp.operands[0];
        if (!elemOperandOK(kSide) || [elemIds containsObject:@(kSide.valueId)])
            continue;
        if (cmp.predicate == XTIRICmpEQ || cmp.predicate == XTIRICmpNE ||
            cmp.predicate == XTIRICmpULT || cmp.predicate == XTIRICmpUGT ||
            cmp.predicate == XTIRICmpULE || cmp.predicate == XTIRICmpUGE ||
            cmp.predicate == XTIRICmpSLT || cmp.predicate == XTIRICmpSGT ||
            /* supported */
            cmp.predicate == XTIRICmpSLE || cmp.predicate == XTIRICmpSGE)
            {
            }
        else
            continue;

        // acc used in the loop only by the Select; iv must not escape.
        BOOL clean = YES;
        for (XTIRBlock* bb in @[ H, B, L ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext || u == incr)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        clean = NO;
                        break;
                        }
                if (!clean)
                    break;
                }
            if (!clean)
                break;
            }
        if (!clean)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B || bb == L)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        clean = NO;
                        break;
                        }
            }
        if (!clean)
            continue;

        XTIROperand* seedOp = (accPhi.operands[0].blockRef == L) ? accPhi.operands[3] : accPhi.operands[1];
        NSUInteger wvb = [self vectorBytes]; // 16, or 32/64 on an x86-64 clone (bug 644)
        NSUInteger vw = wvb / laneType.byteWidth;
        // The iteration space is [ivStart, N), so it is the trip LENGTH that must
        // be a whole number of vectors — not the bound. Gating on `N % vw` was
        // right only for a zero start, and silently wrong for any other: with
        // `for (i = 2; i < 16; i++)` and vw=4 it accepted 16%4==0 while the real
        // length is 14, which is how the vector store ran past the range.
        // These two recognisers have no epilogue, so an uneven length stays
        // scalar; the three that do take the tail instead.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, L, defOf, &ivStart))
            continue;
        if (ivStart >= N)
            continue;
        if (vw < 2 || (((N - ivStart) % (int64_t)vw) != 0))
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        // vw came from the LOAD's width above (16 lanes for a byte). When the
        // element is narrower than the count, the accumulator keeps its own
        // width and loadLaneType records the element's — exactly as the
        // widening sum does — and the apply climbs between them.
        XTIRType* accTy = accPhi.result.type;
        if (laneType.byteWidth < 4)
            {
            if (!accTy || accTy.byteWidth != 4)
                continue;                        // only a 32-bit count
            uint64_t laneMax = (laneType.byteWidth == 1) ? 0xFFULL : 0xFFFFULL;
            if (deltaK < 0 || (uint64_t)deltaK > laneMax)
                continue;                        // the delta must fit the lane
            c.loadLaneType = laneType;
            c.laneType = accTy;
            }
        else
            c.laneType = laneType;
        c.vw = vw;
        c.vecBytes = wvb;
        c.accPhi = accPhi;
        c.accId = accId;
        c.elemId = elemId;
        c.seedOp = seedOp;
        c.preheader = PH;
        c.mmLatch = L;
        c.isCount = YES;
        c.cmpInsn = cmp;
        c.countDeltaOp = deltaOp;
        return c;
        }
    return nil;
    }

- (void)applyCountReduction:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader, *L = c.mmLatch;
    // The load, compare and mask run at the ELEMENT's width; the accumulator
    // keeps its own. They are the same type unless the element is narrower,
    // which is what loadLaneType records — so the 32-bit path is unchanged.
    XTIRType* elemLane = c.loadLaneType ?: c.laneType;
    XTIRType* vecTy = [XTIRType vecWithLane:elemLane bytes:(uint32_t)c.vecBytes];
    XTIRType* accVecTy = [XTIRType vecWithLane:c.laneType bytes:(uint32_t)c.vecBytes];
    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;

    XTIRValue* vacc = newVal(accVecTy);
    NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRValue*>* splat = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRValue*>* phSplatCache = [NSMutableDictionary dictionary];
    // Splat a LOOP-INVARIANT operand (the compare bound k, the increment delta)
    // into the preheader, so it is computed once on loop entry rather than every
    // iteration. A compile-time constant is rematerialised fresh in the
    // preheader; a value defined before the loop is splatted directly (it
    // dominates the preheader).
    XTIROperand* (^phSplat)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      NSNumber* cacheKey = (op.kind == XTIROperandKindUse) ? @(op.valueId) : nil;
      if (cacheKey && phSplatCache[cacheKey])
          return [XTIROperand useWithValueId:phSplatCache[cacheKey].valueId];
      XTIROperand* scalar = op;
      int64_t kv;
      if (resolveConstInt(op, defOf, &kv))
          {
          // elemLane, not c.laneType. This applier has TWO lane types — the
          // ELEMENT's (u8 for a byte compare) and the ACCUMULATOR's (u32) — and
          // this splat goes into the element vector. Typing its scalar from the
          // accumulator produced `%v:Vec(U8) = VSplat %c:U32`, a splat whose
          // scalar is wider than the lanes it fills. The back ends take the
          // width from the RESULT so it worked, but the SHIPPED compiler types
          // it from the element lane and the two disagreed on every file that
          // counts bytes (bug 228 / bug 226).
          XTIRValue* cst = newVal(elemLane);
          [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                               result:cst
                                                             operands:@[ [XTIROperand immIWithType:elemLane value:kv] ]
                                                               dbgLoc:nil]];
          scalar = [XTIROperand useWithValueId:cst.valueId];
          }
      XTIRValue* sp = newVal(vecTy);
      [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ scalar ]
                                                           dbgLoc:nil]];
      if (cacheKey)
          phSplatCache[cacheKey] = sp;
      return [XTIROperand useWithValueId:sp.valueId];
    };
    XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* vv = vmap[@(op.valueId)];
          if (vv)
              return [XTIROperand useWithValueId:vv.valueId];
          XTIRValue* sp = splat[@(op.valueId)];
          if (!sp)
              {
              sp = newVal(vecTy);
              [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat result:sp operands:@[ op ] dbgLoc:nil]];
              splat[@(op.valueId)] = sp;
              }
          return [XTIROperand useWithValueId:sp.valueId];
          }
      XTIRValue* sp = newVal(vecTy);
      [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat result:sp operands:@[ op ] dbgLoc:nil]];
      return [XTIROperand useWithValueId:sp.valueId];
    };

    // Rebuild B: keep address/const plumbing, vector-load the element and any
    // elementwise arith; drop the scalar compare / increment / select.
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn == c.cmpInsn || insn.opcode == XTIROpSelect)
            continue; // count plumbing
        // keep iv step scalar (merged body)
        if (insn == c.ivNext)
            {
            [nb addObject:insn];
            continue;
            }
        // the scalar c+delta
        if (insn.result && insn.opcode == XTIROpAdd)
            {
            // skip the increment Add (its result feeds only the Select)
            if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == c.accId)
                continue;
            if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == c.accId)
                continue;
            }
        if (insn.opcode == XTIROpLoad && insn.result)
            {
            XTIRValue* vr = newVal(vecTy);
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vr
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vl.memoryResult = insn.memoryResult;
            [nb addObject:vl];
            vmap[@(insn.result.valueId)] = vr;
            }
        else if (insn.opcode == XTIROpAddrOf || insn.opcode == XTIROpElementAddr ||
                 insn.opcode == XTIROpConst || insn.opcode == XTIROpZExt ||
                 insn.opcode == XTIROpSExt || insn.opcode == XTIROpTrunc)
            {
            [nb addObject:insn];
            }
        else if (elementwiseArith(insn.opcode) && insn.result)
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVal(vecTy);
            [nb addObject:[[XTIRInsn alloc] initWithOpcode:vectorOpFor(insn.opcode)
                                                    result:vr
                                                  operands:@[ va, vb ]
                                                    dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            }
        }
    // vmask = VICmp(elem, k); vinc = vmask & splat(delta); vacc += vinc.
    // The elementwise side comes from the body (vmap); the loop-invariant bound
    // k and the increment delta are splatted once in the preheader.
    XTIROperand* (^cmpOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse && vmap[@(op.valueId)])
          return vecOperand(op); // elementwise
      int64_t kv;
      if (resolveConstInt(op, defOf, &kv))
          return phSplat(op); // constant → preheader
      return vecOperand(op);  // non-const invariant: body splat (always dominates)
    };
    XTIRValue* vmask = newVal(vecTy);
    XTIRInsn* vic = [[XTIRInsn alloc] initWithOpcode:XTIROpVICmp
                                              result:vmask
                                            operands:@[ cmpOperand(c.cmpInsn.operands[0]), cmpOperand(c.cmpInsn.operands[1]) ]
                                           predicate:c.cmpInsn.predicate
                                              dbgLoc:nil];
    [nb addObject:vic];
    XTIRValue* vinc = newVal(vecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAnd
                                            result:vinc
                                          operands:@[ [XTIROperand useWithValueId:vmask.valueId], phSplat(c.countDeltaOp) ]
                                            dbgLoc:nil]];
    // Climb the masked increments to the accumulator's width with uaddlp — the
    // same ladder the widening sum uses. Pairwise summing preserves a total, so
    // folding lanes together does not disturb a count.
    XTIRValue* curInc = vinc;
    XTIRType* curLane = elemLane;
    while (curLane.byteWidth < c.laneType.byteWidth)
        {
        XTIRType* nextLane = (curLane.byteWidth == 1) ? [XTIRType u16Type] : [XTIRType u32Type];
        XTIRValue* w = newVal([XTIRType vecWithLane:nextLane bytes:(uint32_t)c.vecBytes]);
        [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAddLP
                                                result:w
                                              operands:@[ [XTIROperand useWithValueId:curInc.valueId] ]
                                                dbgLoc:nil]];
        curInc = w;
        curLane = nextLane;
        }
    XTIRValue* vnext = newVal(accVecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                            result:vnext
                                          operands:@[ [XTIROperand useWithValueId:vacc.valueId], [XTIROperand useWithValueId:curInc.valueId] ]
                                            dbgLoc:nil]];
    [B.instructions setArray:nb];

    // Re-step the iv by the vector width (in the latch L).
    NSMutableArray<XTIROperand*>* ivOps = [c.ivNext.operands mutableCopy];
    for (NSUInteger k = 0; k < ivOps.count; k++)
        if (ivOps[k].kind == XTIROperandKindImmI || (ivOps[k].kind == XTIROperandKindUse && ivOps[k].valueId != c.ivId))
            ivOps[k] = [XTIROperand immIWithType:c.ivNext.result.type value:(int64_t)c.vw];
    [c.ivNext replaceOperands:ivOps];

    // Vector accumulator phi: splat(0) init, back-edge value vnext (defined in
    // B, dominates the latch L). Additive, so seed is added back at the exit.
    XTIRValue* vacc0 = newVal(accVecTy);
    XTIRValue* zero = newVal(c.laneType);
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:zero
                                                       operands:@[ [XTIROperand immIWithType:c.laneType value:0] ]
                                                         dbgLoc:nil]];
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                         result:vacc0
                                                       operands:@[ [XTIROperand useWithValueId:zero.valueId] ]
                                                         dbgLoc:nil]];
    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:L], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        [newPhis addObject:(phi == c.accPhi ? vphi : phi)];
    [H.phiNodes setArray:newPhis];

    // Horizontal add at exit; add back a non-zero seed; rewire live-out.
    XTIRValue* red = newVal(c.laneType);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:XTIROpVReduceAdd
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* head = [@[ rd ] mutableCopy];
    XTIRValueId outId = red.valueId;
    int64_t sk = 0;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* d2 = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                d2[@(i.result.valueId)] = i;
    if (!(resolveConstInt(c.seedOp, d2, &sk) && sk == 0))
        {
        XTIRValue* withSeed = newVal(c.laneType);
        [head addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                  result:withSeed
                                                operands:@[ [XTIROperand useWithValueId:red.valueId], c.seedOp ]
                                                  dbgLoc:nil]];
        outId = withSeed.valueId;
        }
    [E.instructions insertObjects:head atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, head.count)]];
    for (XTIRBlock* bb in fn.blocks)
        {
        if (bb == H || bb == B)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:outId];
                    changed = YES;
                    }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

// ── Multi-accumulator unroll of vectorised reduction loops ───────────────
//
// A vectorised reduction loop `H: vacc=phi; iv=phi; guard / B: …; vnext=Vop(vacc,X);
// iv+=vw; ->H` carries a SERIAL dependency through `vnext = Vop(vacc, …)` — each
// iteration waits for the previous add/max. Unrolling ×U with U independent
// accumulators (each summing every U-th vector) turns it into U parallel chains
// the out-of-order core overlaps, then combines them at the exit. Only the
// single-block-latch shape (H → B → H) is handled; others are left as-is.
- (void)unrollVectorReductionsInFunction:(XTIRFunction*)fn
    {
    for (NSUInteger hi = 0; hi < fn.blocks.count; hi++)
        {
        XTIRBlock* H = fn.blocks[hi];
        if (xtvIsRemainder(H))
            continue;
        if (H.phiNodes.count != 2)
            continue;

        NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                if (p.result)
                    {
                    defOf[@(p.result.valueId)] = p;
                    defBlk[@(p.result.valueId)] = bb;
                    }
            for (XTIRInsn* i in bb.instructions)
                if (i.result)
                    {
                    defOf[@(i.result.valueId)] = i;
                    defBlk[@(i.result.valueId)] = bb;
                    }
            }

        XTIRInsn *vaccPhi = nil, *ivPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.operands.count != 4)
                {
                vaccPhi = nil;
                break;
                }
            if (phi.result.type.kind == XTIRTypeKindVec)
                vaccPhi = phi;
            else
                ivPhi = phi;
            }
        if (!vaccPhi || !ivPhi)
            continue;
        XTIRValueId vaccId = vaccPhi.result.valueId, ivId = ivPhi.result.valueId;
        XTIRType* vecTy = vaccPhi.result.type;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse || guard.operands[0].valueId != ivId)
            continue;
        // The bound may be a literal, or the runtime limit M = n & ~(vw-1) that
        // the vectoriser builds for a runtime trip count (#1136). Both are
        // unrollable; which one it is decides how U is chosen, below.
        int64_t N = 0;
        BOOL constN = resolveConstIntExt(guard.operands[1], defOf, &N);
        if (constN && N <= 0)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^isLatch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = isLatch(t0) ? t0 : (isLatch(t1) ? t1 : nil);
        XTIRBlock* E = (B == t0) ? t1 : t0;
        if (!B || !E)
            continue;
        // A large body (MD5's rounds) gets two copies, not four, and those
        // INTERLEAVED (each clone straight after its original): the body is
        // one long dependency chain, and the second copy's is independent, so
        // the core runs both at once. Only where the two copies' vectors fit
        // the back end's pool (vecInterleaveFits); four would hold four sets.
        BOOL bigBody = B.instructions.count > XTIR_VEC_SPLAT_BIG_BODY;

        // vnext = vacc back-edge: Vop(vacc, X); ivNext = Add(iv, vw); both in B.
        XTIROperand* vnextOp = (vaccPhi.operands[0].blockRef == B) ? vaccPhi.operands[1] : vaccPhi.operands[3];
        XTIROperand* ivNextOp = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (vnextOp.kind != XTIROperandKindUse || ivNextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* vnextInsn = defOf[@(vnextOp.valueId)];
        XTIRInsn* ivNextInsn = defOf[@(ivNextOp.valueId)];
        if (!vnextInsn || defBlk[@(vnextOp.valueId)] != B)
            continue;
        if (!ivNextInsn || ivNextInsn.opcode != XTIROpAdd || defBlk[@(ivNextOp.valueId)] != B)
            continue;
        if (!(vnextInsn.opcode == XTIROpVAdd || vnextInsn.opcode == XTIROpVMax || vnextInsn.opcode == XTIROpVMin))
            continue;
        if (vnextInsn.operands.count < 2 ||
            vnextInsn.operands[0].kind != XTIROperandKindUse || vnextInsn.operands[1].kind != XTIROperandKindUse)
            continue;
        // vnext must be Vop(vacc, X) — one operand is the accumulator.
        if (vnextInsn.operands[0].valueId != vaccId && vnextInsn.operands[1].valueId != vaccId)
            continue;
        int64_t vw = 0;
        XTIROperand* stepOp = nil;
        if (ivNextInsn.operands[0].kind == XTIROperandKindUse && ivNextInsn.operands[0].valueId == ivId)
            stepOp = ivNextInsn.operands[1];
        else if (ivNextInsn.operands[1].kind == XTIROperandKindUse && ivNextInsn.operands[1].valueId == ivId)
            stepOp = ivNextInsn.operands[0];
        if (!stepOp || !resolveConstInt(stepOp, defOf, &vw) || vw < 2)
            continue;

        // Preheader init: vacc's non-B incoming is a VSplat we replicate per copy.
        XTIRBlock* PH = (vaccPhi.operands[0].blockRef == B) ? vaccPhi.operands[2].blockRef : vaccPhi.operands[0].blockRef;
        XTIROperand* initOp = (vaccPhi.operands[0].blockRef == B) ? vaccPhi.operands[3] : vaccPhi.operands[1];
        if (!PH || initOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* initInsn = defOf[@(initOp.valueId)];
        if (!initInsn || initInsn.opcode != XTIROpVSplat || defBlk[@(initOp.valueId)] != PH)
            continue;

        NSInteger U;
        if (constN)
            {
            U = (!bigBody && N % (4 * vw) == 0) ? 4 : (N % (2 * vw) == 0 ? 2 : 1);
            }
        else
            {
            // A RUNTIME bound. The vectoriser emitted `M = n & ~(vw-1)`, and the
            // unroll needs the trip to be a whole number of U vectors -- so widen
            // that mask to ~(U*vw-1), and it is one by construction. Nothing else
            // has to change: the guard and the scalar clone's induction seed are
            // the SAME value, so lowering M moves both together, and the clone
            // already runs [M, n). The tail merely gets up to U*vw-1 elements
            // instead of vw-1, which on any loop worth vectorising is noise.
            //
            // Refused unless the mask is EXACTLY the one the vectoriser built:
            // any other bound is one this pass does not understand, and
            // rewriting it would change the loop's trip count.
            XTIRInsn* mask = (guard.operands[1].kind == XTIROperandKindUse)
                                 ? defOf[@(guard.operands[1].valueId)]
                                 : nil;
            // A loop from a start s (a par block's run over [lo, hi)) has the
            // limit `((n - s) & ~(vw-1)) + s`: the mask is under the Add, and
            // widening it keeps the trip from s a whole number of U vectors.
            if (mask && mask.opcode == XTIROpAdd && mask.operands.count == 2)
                {
                XTIRInsn* m0 = mask.operands[0].kind == XTIROperandKindUse ? defOf[@(mask.operands[0].valueId)] : nil;
                XTIRInsn* m1 = mask.operands[1].kind == XTIROperandKindUse ? defOf[@(mask.operands[1].valueId)] : nil;
                if (m0 && m0.opcode == XTIROpAnd)
                    mask = m0;
                else if (m1 && m1.opcode == XTIROpAnd)
                    mask = m1;
                }
            if (!mask || mask.opcode != XTIROpAnd || mask.operands.count < 2)
                continue;
            if (mask.operands[1].kind != XTIROperandKindImmI)
                continue;
            if (mask.operands[1].intValue != ~((int64_t)vw - 1))
                continue;
            U = bigBody ? 2 : 4;
            if (bigBody)
                vecRematLanes(fn, B, defBlk);
            if (bigBody && !vecInterleaveFits(fn, B, vaccId, ivId, ivNextInsn, vecPoolForTy(fn, self.profile ?: [XTIROptTargetProfile conservativeProfile], vaccPhi.result.type)))
                continue;
            NSMutableArray<XTIROperand*>* mops = [mask.operands mutableCopy];
            mops[1] = [XTIROperand immIWithType:mask.result.type
                                          value:~((int64_t)(U * vw) - 1)];
            [mask replaceOperands:mops];
            }
        if (U < 2)
            continue;
        if (bigBody && constN)
            vecRematLanes(fn, B, defBlk);
        if (bigBody && constN && !vecInterleaveFits(fn, B, vaccId, ivId, ivNextInsn, vecPoolForTy(fn, self.profile ?: [XTIROptTargetProfile conservativeProfile], vaccPhi.result.type)))
            continue;

        XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
          XTIRValueId rid = [fn allocateValueId];
          XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                       type:ty
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
          [fn registerValue:v];
          return v;
        };

        // iv-dependent body instructions (transitively use iv), in order, EXCEPT
        // the iv step (re-stepped to U*vw separately). vnextInsn is included
        // (it depends on X, which depends on iv).
        NSMutableSet<NSNumber*>* dep = [NSMutableSet setWithObject:@(ivId)];
        NSMutableArray<XTIRInsn*>* ivDep = [NSMutableArray array];
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == ivNextInsn)
                continue;
            BOOL d = NO;
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse && [dep containsObject:@(o.valueId)])
                    {
                    d = YES;
                    break;
                    }
            if (d)
                {
                [ivDep addObject:insn];
                if (insn.result)
                    [dep addObject:@(insn.result.valueId)];
                }
            }

        // Build U-1 extra accumulators by cloning the iv-dependent chain with
        // iv → iv+k*vw and vacc → vacc_k.
        XTIRType* ivTy = ivNextInsn.result.type;
        NSMutableArray<XTIRInsn*>* appended = [NSMutableArray array];
        NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
        NSMutableArray<NSNumber*>* accIds = [NSMutableArray arrayWithObject:@(vaccId)]; // copy 0 = original
        for (NSInteger k = 1; k < U; k++)
            {
            XTIRValue* vacc_k = newVal(vecTy);
            // All U accumulators start from the SAME preheader broadcast — reuse
            // copy 0's VSplat rather than cloning it per copy. U-1 phi copies
            // (movdqa/mov) replace U-1 live splats: the backends' vector
            // register pools hold 8, and U extra splats on top of the U
            // accumulators is how the pool overflowed (#1198).
            XTIRValue* iv_k = newVal(ivTy);
            [appended addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                          result:iv_k
                                                        operands:@[ [XTIROperand useWithValueId:ivId], [XTIROperand immIWithType:ivTy value:k * vw] ]
                                                          dbgLoc:nil]];
            NSMutableDictionary<NSNumber*, NSNumber*>* remap = [NSMutableDictionary dictionary];
            remap[@(ivId)] = @(iv_k.valueId);
            remap[@(vaccId)] = @(vacc_k.valueId);
            XTIRValueId vnext_k = 0;
            for (XTIRInsn* insn in ivDep)
                {
                NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
                for (XTIROperand* o in insn.operands)
                    {
                    if (o.kind == XTIROperandKindUse && remap[@(o.valueId)])
                        [ops addObject:[XTIROperand useWithValueId:remap[@(o.valueId)].unsignedIntegerValue]];
                    else
                        [ops addObject:o];
                    }
                XTIRValue* r = insn.result ? newVal(insn.result.type) : nil;
                XTIRInsn* clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                            result:r
                                                          operands:ops
                                                         predicate:insn.predicate
                                                            dbgLoc:insn.dbgLoc];
                if (insn.memoryResult)
                    clone.memoryResult = newVal([XTIRType memoryType]);
                if (r)
                    remap[@(insn.result.valueId)] = @(r.valueId);
                [appended addObject:clone];
                if (insn == vnextInsn)
                    vnext_k = r.valueId;
                }
            [newPhis addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:vacc_k
                                                       operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:initOp.valueId],
                                                                   [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext_k] ]
                                                         dbgLoc:nil]];
            [accIds addObject:@(vacc_k.valueId)];
            }

        // Append the clones at the END of B (after copy-0's full chain), so the
        // loop-invariant values copy-0 computes mid-body (e.g. the count splats)
        // are defined before the clones that share them. The iv step is also in
        // B but order-independent (it reads only the iv phi). A big body's
        // (U = 2) go each straight after its original instead: the shared
        // values an original reads come before it, so before its clone too.
        if (bigBody)
            {
            NSMutableDictionary<NSValue*, XTIRInsn*>* cloneOf = [NSMutableDictionary dictionary];
            for (NSUInteger j = 0; j < ivDep.count; j++)
                cloneOf[[NSValue valueWithNonretainedObject:ivDep[j]]] = appended[j + 1];
            NSMutableArray<XTIRInsn*>* il = [NSMutableArray arrayWithObject:appended[0]];
            for (XTIRInsn* insn in B.instructions)
                {
                [il addObject:insn];
                XTIRInsn* cl = cloneOf[[NSValue valueWithNonretainedObject:insn]];
                if (cl)
                    [il addObject:cl];
                }
            [B.instructions setArray:il];
            }
        else
            [B.instructions addObjectsFromArray:appended];
        NSMutableArray<XTIROperand*>* ivOps = [ivNextInsn.operands mutableCopy];
        for (NSUInteger j = 0; j < ivOps.count; j++)
            if (ivOps[j].kind == XTIROperandKindImmI || (ivOps[j].kind == XTIROperandKindUse && ivOps[j].valueId != ivId))
                ivOps[j] = [XTIROperand immIWithType:ivTy value:U * vw];
        [ivNextInsn replaceOperands:ivOps];

        for (XTIRInsn* p in newPhis)
            [H.phiNodes addObject:p];

        // Combine the U accumulators at the exit (same op as the reduction),
        // then point the existing reduce at the combined accumulator.
        NSMutableArray<XTIRInsn*>* combine = [NSMutableArray array];
        XTIRValueId cur = vaccId;
        for (NSInteger k = 1; k < U; k++)
            {
            XTIRValue* r = newVal(vecTy);
            [combine addObject:[[XTIRInsn alloc] initWithOpcode:vnextInsn.opcode
                                                         result:r
                                                       operands:@[ [XTIROperand useWithValueId:cur], [XTIROperand useWithValueId:accIds[k].unsignedIntegerValue] ]
                                                         dbgLoc:nil]];
            cur = r.valueId;
            }
        [E.instructions insertObjects:combine atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, combine.count)]];
        // Rewrite uses of the original accumulator outside H/B (the reduce) to
        // the combined value — but not inside the combine chain we just built.
        NSSet<XTIRInsn*>* combineSet = [NSSet setWithArray:combine];
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* insn in bb.instructions)
                {
                if ([combineSet containsObject:insn])
                    continue;
                NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                BOOL changed = NO;
                for (NSUInteger j = 0; j < ops.count; j++)
                    if (ops[j].kind == XTIROperandKindUse && ops[j].valueId == vaccId)
                        {
                        ops[j] = [XTIROperand useWithValueId:cur];
                        changed = YES;
                        }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        }
    }

// The vector registers the back end has for fn: 14 (arm64 v18-v31, x86
// xmm/ymm 2-15), or 22 on arm64 in a function with no float scalars, where the
// FP allocator's homes v8-v15 are free (the arm64 back end then takes them).
static NSUInteger vecPoolFor(XTIRFunction* fn, XTIROptTargetProfile* prof)
    {
    if (!prof.vectorizesBitSelect)
        return 14;
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        for (XTIRInsn* insn in all)
            {
            if (insn.result && XTIRTypeKindIsFloating(insn.result.type.kind))
                return 14;
            for (XTIROperand* o in insn.operands)
                {
                XTIRValue* ov = o.kind == XTIROperandKindUse ? [fn valueForId:o.valueId] : nil;
                if (ov && XTIRTypeKindIsFloating(ov.type.kind))
                    return 14;
                }
            }
        }
    return 22;
    }

// The pool for a loop over vectors of type t: on x86 a 64-byte (AVX-512)
// loop has zmm16-31 too, which the back end gives to classes whose every value
// is 64 bytes (21e53d67): 30, not 14. That is what lets a big body (MD5's 64
// rounds) interleave two lane groups, as clang does. As the port.
static NSUInteger vecPoolForTy(XTIRFunction* fn, XTIROptTargetProfile* prof, XTIRType* t)
    {
    if (!prof.vectorizesBitSelect && t.kind == XTIRTypeKindVec && t.byteWidth == 64)
        return 30;
    return vecPoolFor(fn, prof);
    }

// In a big body, a lane vector built from a scalar, `VAdd(VSplat(x), t)` with
// t from outside the body (the iota: `<i, i+1, i+2, i+3>`), is rebuilt next to
// each later use instead of held: two cheap ops against a register for the
// whole body (MD5's candidate word, read in four rounds).
static void vecRematLanes(XTIRFunction* fn, XTIRBlock* B, NSDictionary<NSNumber*, XTIRBlock*>* defBlk)
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defIn = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* usesIn = [NSCountedSet set];
    for (XTIRInsn* insn in B.instructions)
        for (XTIROperand* o in insn.operands)
            if (o.kind == XTIROperandKindUse)
                [usesIn addObject:@(o.valueId)];
    NSCountedSet<NSNumber*>* usesAll = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [usesAll addObject:@(o.valueId)];
        }
    NSMutableArray<XTIRInsn*>* out = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRInsn*>* lane = [NSMutableDictionary dictionary]; // value → its VAdd
    NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
    for (XTIRInsn* insn in B.instructions)
        {
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger k = 0; k < insn.operands.count; k++)
            {
            XTIROperand* o = insn.operands[k];
            if (o.kind != XTIROperandKindUse)
                continue;
            XTIRInsn* va = lane[@(o.valueId)];
            if (!va)
                continue;
            if (![seen containsObject:@(o.valueId)])
                {
                [seen addObject:@(o.valueId)];
                continue;
                }
            // A later use: a fresh splat and add, just before it.
            XTIRInsn* sp = defIn[@(va.operands[0].valueId)];
            NSUInteger ti = sp ? 1 : 0;
            if (!sp)
                sp = defIn[@(va.operands[1].valueId)];
            XTIRValue* s2 = [[XTIRValue alloc] initWithValueId:[fn allocateValueId] type:sp.result.type
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
            [fn registerValue:s2];
            [out addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat result:s2 operands:sp.operands dbgLoc:insn.dbgLoc]];
            XTIRValue* a2 = [[XTIRValue alloc] initWithValueId:[fn allocateValueId] type:va.result.type
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
            [fn registerValue:a2];
            NSArray<XTIROperand*>* aops = ti == 1 ? @[ [XTIROperand useWithValueId:s2.valueId], va.operands[1] ]
                                                  : @[ va.operands[0], [XTIROperand useWithValueId:s2.valueId] ];
            [out addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd result:a2 operands:aops dbgLoc:insn.dbgLoc]];
            if (!ops)
                ops = [insn.operands mutableCopy];
            ops[k] = [XTIROperand useWithValueId:a2.valueId];
            }
        if (ops)
            [insn replaceOperands:ops];
        [out addObject:insn];
        if (insn.result)
            defIn[@(insn.result.valueId)] = insn;
        // Is this such a lane vector? VAdd of a single-use in-body VSplat and
        // an outside value, read only in B, more than once.
        if (insn.opcode == XTIROpVAdd && insn.result && insn.operands.count == 2 &&
            insn.operands[0].kind == XTIROperandKindUse && insn.operands[1].kind == XTIROperandKindUse &&
            [usesIn countForObject:@(insn.result.valueId)] > 1 &&
            [usesIn countForObject:@(insn.result.valueId)] == [usesAll countForObject:@(insn.result.valueId)])
            {
            for (NSUInteger k = 0; k < 2; k++)
                {
                XTIRInsn* sp = defIn[@(insn.operands[k].valueId)];
                XTIROperand* t = insn.operands[1 - k];
                if (sp && sp.opcode == XTIROpVSplat && [usesAll countForObject:@(sp.result.valueId)] == 1 &&
                    !defIn[@(t.valueId)] && defBlk[@(t.valueId)] != B)
                    {
                    lane[@(insn.result.valueId)] = insn;
                    break;
                    }
                }
            }
        }
    [B.instructions setArray:out];
    }

// Would B's vector form fit the back end's pool? An upper bound, on the scalar
// body: each per-lane value (elemIds) is a vector from its definition to its
// last use, each splatted operand of a per-lane op holds one more for that op,
// and the accumulator and the lane-index vector are live throughout. No
// register reuse is credited. It is NOT an upper bound of the back end's own
// count (values the allocator holds across the loop are not all seen here), so
// it keeps a margin of three: a 14-register function whose MD5-like body
// counted 14 overflowed. As the port's vecScalarBodyFits.
static BOOL vecScalarBodyFits(XTIRBlock* B, NSSet<NSNumber*>* elemIds, NSUInteger pool)
    {
    NSUInteger n = B.instructions.count;
    NSMutableDictionary<NSNumber*, NSNumber*>* lastUse = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < n; i++)
        for (XTIROperand* o in B.instructions[i].operands)
            if (o.kind == XTIROperandKindUse)
                lastUse[@(o.valueId)] = @(i);
    NSUInteger live = 2;
    NSUInteger peak = live;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTIRInsn* insn = B.instructions[i];
        if (!insn.result || ![elemIds containsObject:@(insn.result.valueId)])
            continue;
        NSUInteger splats = 0;
        for (XTIROperand* o in insn.operands)
            if (o.kind != XTIROperandKindUse || ![elemIds containsObject:@(o.valueId)])
                splats++;
        if (live + 1 + splats > peak)
            peak = live + 1 + splats;
        live++;
        for (XTIROperand* o in insn.operands)
            {
            if (o.kind != XTIROperandKindUse || ![elemIds containsObject:@(o.valueId)])
                continue;
            if (lastUse[@(o.valueId)].unsignedIntegerValue == i)
                {
                lastUse[@(o.valueId)] = @(n);
                live--;
                }
            }
        }
    return peak + 3 <= pool;
    }

// Would two interleaved copies of B's vector work fit the back end's pool?
// A sweep of B in order: each vector value B defines is live from its
// definition to its last use in B, twice over when it depends on the iv (its
// clone stands next to it); the two accumulators, and every vector B reads
// from outside (a preheader splat, the iota load), are live throughout. The
// peak must leave a margin in the 14 registers the back ends have (arm64
// v18-v31, x86 xmm/ymm 2-15): they do not spill a vector, and an overflow is a
// build error. As the port's vecInterleaveFits.
static BOOL vecInterleaveFits(XTIRFunction* fn, XTIRBlock* B, XTIRValueId vaccId, XTIRValueId ivId,
                              XTIRInsn* ivNextInsn, NSUInteger pool)
    {
    NSUInteger n = B.instructions.count;
    NSMutableSet<NSNumber*>* dep = [NSMutableSet setWithObjects:@(ivId), @(vaccId), nil];
    NSMutableSet<NSNumber*>* inB = [NSMutableSet set];
    NSMutableDictionary<NSNumber*, NSNumber*>* lastUse = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* outside = [NSMutableSet set];
    for (NSUInteger i = 0; i < n; i++)
        {
        XTIRInsn* insn = B.instructions[i];
        if (insn == ivNextInsn)
            continue;
        BOOL d = NO;
        for (XTIROperand* o in insn.operands)
            {
            if (o.kind != XTIROperandKindUse)
                continue;
            lastUse[@(o.valueId)] = @(i);
            if ([dep containsObject:@(o.valueId)])
                d = YES;
            XTIRValue* v = [fn valueForId:o.valueId];
            if (v && v.type.kind == XTIRTypeKindVec && o.valueId != vaccId && ![inB containsObject:@(o.valueId)])
                [outside addObject:@(o.valueId)];
            }
        if (insn.result)
            {
            [inB addObject:@(insn.result.valueId)];
            if (d)
                [dep addObject:@(insn.result.valueId)];
            }
        }
    NSUInteger live = 2;
    NSUInteger peak = live;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTIRInsn* insn = B.instructions[i];
        if (insn == ivNextInsn)
            continue;
        // What dies here: B's vectors read for the last time (counted once).
        NSUInteger dying = 0;
        for (XTIROperand* o in insn.operands)
            {
            if (o.kind != XTIROperandKindUse || o.valueId == vaccId || ![inB containsObject:@(o.valueId)])
                continue;
            XTIRValue* v = [fn valueForId:o.valueId];
            if (!v || v.type.kind != XTIRTypeKindVec || lastUse[@(o.valueId)].unsignedIntegerValue != i)
                continue;
            lastUse[@(o.valueId)] = @(n);
            dying += [dep containsObject:@(o.valueId)] ? 2 : 1;
            }
        BOOL vecDef = insn.result && insn.result.type.kind == XTIRTypeKindVec;
        NSUInteger born = vecDef ? ([dep containsObject:@(insn.result.valueId)] ? 2 : 1) : 0;
        // A VAdd takes the register of an operand that dies at it (the back
        // ends' reuse); anything else needs its own while its operands live.
        if (insn.opcode == XTIROpVAdd && dying > 0)
            {
            live = live + born - dying;
            if (live > peak)
                peak = live;
            }
        else
            {
            live += born;
            if (live > peak)
                peak = live;
            live -= dying;
            }
        }
    return peak + outside.count <= pool;
    }

// ── Widening sum reduction (u8/u16 → u32) ────────────────────────────────
//
// `acc:u32 += (u32)a[i]` over a u8/u16 array can't accumulate in narrow lanes
// (the sum overflows a byte/short), so we vector-load 16×u8 / 8×u16, fold the
// lanes up to u32 with `uaddlp` widening, accumulate into a 4×u32 vector, and
// horizontally reduce at the exit (sound: addition mod 2^32 is associative /
// commutative, so the lane regrouping matches the scalar wraparound sum). The
// accumulator update stays a VAdd, so the multi-accumulator unroller then
// unrolls it like any other add reduction.
// Dot product: `acc:u32/i32 += (u32)(a[i]*b[i])` over two u8/u16 arrays. Same
// shape as the widening sum, but the accumulated element is a product of two
// iv-indexed narrow loads (multiplied in the narrow lane, so it wraps exactly
// like the scalar u16*u16). Reuses applyWideningSum with a VMul inserted.
- (nullable XTVecCand*)recogniseDotProduct:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRTypeKind ak = accPhi.result.type.kind;
        if (ak != XTIRTypeKindU32 && ak != XTIRTypeKindI32)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        // A literal, or a RUNTIME bound. Accepted only when loop-INVARIANT
        // (checked below, once the body block is known) and the guard is a
        // strict `<`: with `i <= n` the trip is n+1 and n & ~(vw-1) is wrong.
        BOOL constBound = resolveConstIntExt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = latch(t0) ? t0 : (latch(t1) ? t1 : nil);
        XTIRBlock* E = (B == t0) ? t1 : t0;
        if (!B || !E || B.instructions.count == 0 || E.phiNodes.count != 0)
            continue;

        // accNext = Add(acc, ZExt(Mul(loadA, loadB))), in B, used once.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == B) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accBack.valueId)];
        if (!accNext || accNext.opcode != XTIROpAdd || defBlk[@(accBack.valueId)] != B ||
            [uses countForObject:@(accBack.valueId)] != 1)
            continue;
        XTIROperand* elemOp = nil;
        if (accNext.operands[0].kind == XTIROperandKindUse && accNext.operands[0].valueId == accId)
            elemOp = accNext.operands[1];
        else if (accNext.operands[1].kind == XTIROperandKindUse && accNext.operands[1].valueId == accId)
            elemOp = accNext.operands[0];
        if (!elemOp || elemOp.kind != XTIROperandKindUse)
            continue;
        // elem = ZExt(prod); prod = Mul(loadA, loadB), narrow lane, in B.
        XTIRInsn* zx = defOf[@(elemOp.valueId)];
        if (!zx || zx.opcode != XTIROpZExt || defBlk[@(elemOp.valueId)] != B ||
            zx.operands.count < 1 || zx.operands[0].kind != XTIROperandKindUse)
            continue;
        if ([uses countForObject:@(elemOp.valueId)] != 1)
            continue;
        XTIRInsn* mul = defOf[@(zx.operands[0].valueId)];
        if (!mul || mul.opcode != XTIROpMul || defBlk[@(zx.operands[0].valueId)] != B ||
            [uses countForObject:@(zx.operands[0].valueId)] != 1 || mul.operands.count < 2 ||
            mul.operands[0].kind != XTIROperandKindUse || mul.operands[1].kind != XTIROperandKindUse)
            continue;

        // Both mul operands are iv-indexed narrow loads of the SAME lane type,
        // each used once (only by the mul); their loads feed nothing else.
        XTIRInsn* (^ivLoad)(XTIRValueId) = ^XTIRInsn*(XTIRValueId vid) {
          XTIRInsn* ld = defOf[@(vid)];
          if (!ld || ld.opcode != XTIROpLoad || !ld.result || defBlk[@(vid)] != B ||
              [uses countForObject:@(vid)] != 1 || ld.operands.count < 1 ||
              ld.operands[0].kind != XTIROperandKindUse)
              return nil;
          XTIRType* lt = ld.result.type;
          if (!lt || lt.kind != XTIRTypeKindU16)
              return nil; // VMul has no 8-bit-lane form
          XTIRInsn* ea = defOf[@(ld.operands[0].valueId)];
          if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
              ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
              return nil;
          return ld;
        };
        XTIRInsn* loadA = ivLoad(mul.operands[0].valueId);
        XTIRInsn* loadB = ivLoad(mul.operands[1].valueId);
        if (!loadA || !loadB || loadA == loadB)
            continue;
        if (loadA.result.type.kind != loadB.result.type.kind)
            continue;
        XTIRType* lt = loadA.result.type;

        // ivNext = Add(iv,1) in B, the iv phi's back-edge.
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in B.instructions)
            if (insn.opcode == XTIROpAdd && insn.result && insn != accNext)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Body must be exactly the recognised shape (2 addresses + 2 loads + mul +
        // ZExt + the two Adds + constants) — no other side effects / arith.
        BOOL ok = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == accNext || insn == ivNext || insn == zx || insn == mul ||
                insn == loadA || insn == loadB)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpElementAddr || op == XTIROpConst ||
                op == XTIROpZExt || op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            ok = NO;
            break;
            }
        if (!ok)
            continue;
        // acc used in the loop only by accNext; iv must not escape H/B.
        for (XTIRBlock* bb in @[ H, B ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        ok = NO;
                        break;
                        }
                if (!ok)
                    break;
                }
            if (!ok)
                break;
            }
        if (!ok)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        ok = NO;
                        break;
                        }
            }
        if (!ok)
            continue;

        NSUInteger wvb = [self vectorBytes]; // 16, or 32/64 on an x86-64 clone (bug 644)
        NSUInteger vw = wvb / lt.byteWidth;
        if (vw < 2)
            continue;
        // A non-zero start is VECTORISED, not refused: the epilogue below works
        // from the trip LENGTH, so [ivStart, N) splits into whole vectors plus a
        // scalar tail exactly as [0, N) does.
        //
        // The zero test used to double as what stopped the REMAINDER being
        // re-recognised and re-cloned — the clone's iv enters at M, so it failed
        // by construction. That job now belongs to the `< vw` test below, which
        // is the honest statement of it: a range with no whole vector in it is
        // not vectorisable, whatever it starts at.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, B, defOf, &ivStart))
            continue;
        // N is only meaningful when the bound is a CONSTANT — with a runtime
        // trip it is still 0, so an unguarded `ivStart >= N` refuses every
        // runtime-bound loop, including the zero-start ones that vectorised
        // before. That is how this first showed up: the self-hosted optimiser
        // stopped vectorising vectorize_map_tail while the reference still did.
        if (!runtimeTrip && ivStart >= N)
            continue;
        // Not a whole number of vectors: the vector loop runs to the last whole
        // one and a CLONE finishes the tail (see applyWideningSum). A RUNTIME
        // bound always takes that path, and must be loop-INVARIANT: a value with
        // no defining instruction is a parameter, invariant by construction, so
        // an absent defBlk entry must NOT read as a refusal.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        // Under one whole vector: stay scalar — and this is what refuses the
        // epilogue CLONE, which is shorter than a vector by construction.
        if (!runtimeTrip && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        // Preheader (the header pred that is not the latch) and the accumulator seed.
        XTIRBlock* PH = nil;
        for (XTIRBlock* bb in fn.blocks)
            if (bb != B && bb.terminator)
                for (XTIROperand* o in bb.terminator.operands)
                    if (o.kind == XTIROperandKindBlock && o.blockRef == H)
                        {
                        PH = bb;
                        break;
                        }
        if (!PH)
            continue;
        XTIROperand* seedOp = (accPhi.operands[0].blockRef == B) ? accPhi.operands[3] : accPhi.operands[1];

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.preheader = PH;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.accPhi = accPhi;
        c.accNext = accNext;
        c.accId = accId;
        c.seedOp = seedOp;
        c.isDotProduct = YES;
        c.loadLaneType = lt;
        c.vw = vw;
        c.vecBytes = wvb;
        c.loadId = loadA.result.valueId;
        c.loadId2 = loadB.result.valueId;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = guard.operands[1];
        c.ivStart = ivStart;
        return c;
        }
    return nil;
    }

- (nullable XTVecCand*)recogniseWideningSum:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
            if (xtvIsRemainder(H))
                continue;
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi || accPhi.result.type.kind != XTIRTypeKindU32)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        // A literal, or a RUNTIME bound. Accepted only when loop-INVARIANT
        // (checked below, once the body block is known) and the guard is a
        // strict `<`: with `i <= n` the trip is n+1 and n & ~(vw-1) is wrong.
        BOOL constBound = resolveConstIntExt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = latch(t0) ? t0 : (latch(t1) ? t1 : nil);
        XTIRBlock* E = (B == t0) ? t1 : t0;
        if (!B || !E || B.instructions.count == 0 || E.phiNodes.count != 0)
            continue;

        // accNext = acc back-edge = Add(acc, elem), in B, used once.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == B) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accBack.valueId)];
        if (!accNext || accNext.opcode != XTIROpAdd || defBlk[@(accBack.valueId)] != B ||
            [uses countForObject:@(accBack.valueId)] != 1)
            continue;
        XTIROperand* elemOp = nil;
        if (accNext.operands[0].kind == XTIROperandKindUse && accNext.operands[0].valueId == accId)
            elemOp = accNext.operands[1];
        else if (accNext.operands[1].kind == XTIROperandKindUse && accNext.operands[1].valueId == accId)
            elemOp = accNext.operands[0];
        if (!elemOp || elemOp.kind != XTIROperandKindUse)
            continue;
        // elem = ZExt(load) — unsigned widening of a u8/u16 iv-indexed load.
        XTIRInsn* zx = defOf[@(elemOp.valueId)];
        if (!zx || zx.opcode != XTIROpZExt || defBlk[@(elemOp.valueId)] != B ||
            zx.operands.count < 1 || zx.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* load = defOf[@(zx.operands[0].valueId)];
        if (!load || load.opcode != XTIROpLoad || !load.result || defBlk[@(load.result.valueId)] != B ||
            load.operands.count < 1 || load.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRType* lt = load.result.type;
        if (!lt || !(lt.kind == XTIRTypeKindU8 || lt.kind == XTIRTypeKindU16))
            continue;
        XTIRInsn* ea = defOf[@(load.operands[0].valueId)];
        if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
            ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
            continue;
        // The ZExt feeds only the accumulator; the load feeds only the ZExt.
        if ([uses countForObject:@(elemOp.valueId)] != 1 || [uses countForObject:@(load.result.valueId)] != 1)
            continue;

        // ivNext = Add(iv,1) in B, the iv phi's back-edge.
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in B.instructions)
            if (insn.opcode == XTIROpAdd && insn.result && insn != accNext)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Body must be exactly the recognised shape (address + narrow load +
        // ZExt + the two Adds + constants) — no other side effects / arith.
        BOOL ok = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == accNext || insn == ivNext || insn == zx || insn == load)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpElementAddr || op == XTIROpConst ||
                op == XTIROpZExt || op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            ok = NO;
            break;
            }
        if (!ok)
            continue;
        // acc used in the loop only by accNext; iv must not escape H/B.
        for (XTIRBlock* bb in @[ H, B ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        ok = NO;
                        break;
                        }
                if (!ok)
                    break;
                }
            if (!ok)
                break;
            }
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        ok = NO;
                        break;
                        }
            }
        if (!ok)
            continue;

        NSUInteger wvb = [self vectorBytes]; // 16, or 32/64 on an x86-64 clone (bug 644)
        NSUInteger vw = wvb / lt.byteWidth; // 16 (u8) or 8 (u16) per iter at 16 bytes
        if (vw < 2)
            continue;
        // A non-zero start is VECTORISED, not refused: the epilogue below works
        // from the trip LENGTH, so [ivStart, N) splits into whole vectors plus a
        // scalar tail exactly as [0, N) does.
        //
        // The zero test used to double as what stopped the REMAINDER being
        // re-recognised and re-cloned — the clone's iv enters at M, so it failed
        // by construction. That job now belongs to the `< vw` test below, which
        // is the honest statement of it: a range with no whole vector in it is
        // not vectorisable, whatever it starts at.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, B, defOf, &ivStart))
            continue;
        // N is only meaningful when the bound is a CONSTANT — with a runtime
        // trip it is still 0, so an unguarded `ivStart >= N` refuses every
        // runtime-bound loop, including the zero-start ones that vectorised
        // before. That is how this first showed up: the self-hosted optimiser
        // stopped vectorising vectorize_map_tail while the reference still did.
        if (!runtimeTrip && ivStart >= N)
            continue;
        // Not a whole number of vectors: the vector loop runs to the last whole
        // one and a CLONE finishes the tail (see applyWideningSum). A RUNTIME
        // bound always takes that path, and must be loop-INVARIANT: a value with
        // no defining instruction is a parameter, invariant by construction, so
        // an absent defBlk entry must NOT read as a refusal.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        // Under one whole vector: stay scalar — and this is what refuses the
        // epilogue CLONE, which is shorter than a vector by construction.
        if (!runtimeTrip && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        XTIROperand* seedOp = (accPhi.operands[0].blockRef == B) ? accPhi.operands[3] : accPhi.operands[1];
        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = [XTIRType u32Type];
        c.vw = vw;
        c.vecBytes = wvb;
        c.accPhi = accPhi;
        c.accId = accId;
        c.accNext = accNext;
        c.seedOp = seedOp;
        c.preheader = (accPhi.operands[0].blockRef == B) ? accPhi.operands[2].blockRef : accPhi.operands[0].blockRef;
        c.isWideningSum = YES;
        c.loadLaneType = lt;
        c.loadId = load.result.valueId;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = guard.operands[1];
        c.ivStart = ivStart;
        return c;
        }
    return nil;
    }

- (void)applyWideningSum:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader;

    // Epilogue, part 1: clone the scalar loop BEFORE the body and the header's
    // phis are rewritten in place. Shared by the widening-sum and dot-product
    // recognisers, both of which consume 16 (u8) or 8 (u16) elements per vector,
    // so a non-multiple trip is the COMMON case for them rather than the rare one.
    XTIRBlock *H2 = nil, *B2 = nil;
    NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
    XTIRValueId runtimeMId = 0; // the computed vector limit, when the trip is runtime
    if (c.needsEpilogue)
        {
        xtvCloneLoop(fn, H, B, &H2, &B2, cmap);
        [sVecRemainders addObject:[NSValue valueWithNonretainedObject:H2]];
        NSMutableArray<XTIROperand*>* gops = [c.guard.operands mutableCopy];
        if (c.runtimeTrip)
            {
            XTIRValueId mid = xtvEmitRuntimeM(fn, PH, c.boundOp, c.ivStart,
                                              c.ivStartOp, c.vw, c.ivPhi.result.type);
            runtimeMId = mid;
            gops[1] = [XTIROperand useWithValueId:mid];
            }
        else
            {
            gops[1] = [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
            }
        [c.guard replaceOperands:gops];
        }
    XTIRType* u32 = [XTIRType u32Type];
    XTIRType* accVecTy = [XTIRType vecWithLane:u32 bytes:(uint32_t)c.vecBytes];
    XTIRType* loadVecTy = [XTIRType vecWithLane:c.loadLaneType bytes:(uint32_t)c.vecBytes];
    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    // For a dot product the accumulated element is ZExt(Mul(loadA, loadB)); find
    // the scalar Mul so it (and its ZExt) can be replaced by a VMul of the two
    // vector loads. The ZExt to drop widens the mul result (dot) or the load
    // directly (plain widening sum).
    BOOL isDot = c.isDotProduct;
    XTIRValueId mulId = 0;
    if (isDot)
        for (XTIRInsn* insn in B.instructions)
            if (insn.opcode == XTIROpMul && insn.result && insn.operands.count >= 2 &&
                insn.operands[0].kind == XTIROperandKindUse && insn.operands[1].kind == XTIROperandKindUse &&
                ((insn.operands[0].valueId == c.loadId && insn.operands[1].valueId == c.loadId2) ||
                 (insn.operands[0].valueId == c.loadId2 && insn.operands[1].valueId == c.loadId)))
                {
                mulId = insn.result.valueId;
                break;
                }
    XTIRValueId zxSrc = isDot ? mulId : c.loadId;

    XTIRValue* vacc = newVal(accVecTy);
    NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
    XTIRValue *vload = nil, *vload2 = nil;
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn == c.accNext)
            continue; // scalar accumulate (replaced)
        if (isDot && insn.result && insn.result.valueId == mulId)
            continue; // scalar mul → VMul
        if (insn.result && (insn.result.valueId == c.loadId ||
                            (isDot && insn.result.valueId == c.loadId2)))
            {
            XTIRValue* vl = newVal(loadVecTy);
            XTIRInsn* vi = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vl
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vi.memoryResult = insn.memoryResult;
            [nb addObject:vi];
            if (insn.result.valueId == c.loadId)
                vload = vl;
            else
                vload2 = vl;
            continue;
            }
        if (insn.opcode == XTIROpZExt && insn.operands.count >= 1 &&
            insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == zxSrc)
            continue;        // the widened element (replaced)
        [nb addObject:insn]; // address / iv-step / constants
        }
    // Dot product: multiply the two loaded vectors in the narrow lane first
    // (VMul = pmullw / mul.8h keeps the low half, so it wraps exactly like the
    // scalar u16*u16). Then widen the product up to u32 and accumulate.
    XTIRValue* cur = vload;
    if (isDot)
        {
        XTIRValue* vprod = newVal(loadVecTy);
        [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVMul
                                                result:vprod
                                              operands:@[ [XTIROperand useWithValueId:vload.valueId],
                                                          [XTIROperand useWithValueId:vload2.valueId] ]
                                                dbgLoc:nil]];
        cur = vprod;
        }
    // Widen the (product) lanes up to u32 with uaddlp, then accumulate.
    XTIRType* curLane = c.loadLaneType;
    while (curLane.byteWidth < 4)
        {
        XTIRType* nextLane = (curLane.byteWidth == 1) ? [XTIRType u16Type] : u32;
        XTIRValue* w = newVal([XTIRType vecWithLane:nextLane bytes:(uint32_t)c.vecBytes]);
        [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAddLP
                                                result:w
                                              operands:@[ [XTIROperand useWithValueId:cur.valueId] ]
                                                dbgLoc:nil]];
        cur = w;
        curLane = nextLane;
        }
    XTIRValue* vnext = newVal(accVecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                            result:vnext
                                          operands:@[ [XTIROperand useWithValueId:vacc.valueId], [XTIROperand useWithValueId:cur.valueId] ]
                                            dbgLoc:nil]];
    [B.instructions setArray:nb];

    // Step the iv by the lane count (16 for u8, 8 for u16).
    NSMutableArray<XTIROperand*>* ivOps = [c.ivNext.operands mutableCopy];
    for (NSUInteger k = 0; k < ivOps.count; k++)
        if (ivOps[k].kind == XTIROperandKindImmI || (ivOps[k].kind == XTIROperandKindUse && ivOps[k].valueId != c.ivId))
            ivOps[k] = [XTIROperand immIWithType:c.ivNext.result.type value:(int64_t)c.vw];
    [c.ivNext replaceOperands:ivOps];

    // Vector accumulator phi: splat(0) init (additive, seed added back at exit).
    XTIRValue* vacc0 = newVal(accVecTy);
    XTIRValue* zero = newVal(u32);
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:zero
                                                       operands:@[ [XTIROperand immIWithType:u32 value:0] ]
                                                         dbgLoc:nil]];
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                         result:vacc0
                                                       operands:@[ [XTIROperand useWithValueId:zero.valueId] ]
                                                         dbgLoc:nil]];
    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        [newPhis addObject:(phi == c.accPhi ? vphi : phi)];
    [H.phiNodes setArray:newPhis];

    // Horizontal add at exit; add back a non-zero seed; rewire live-out.
    XTIRValue* red = newVal(u32);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:XTIROpVReduceAdd
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* head = [@[ rd ] mutableCopy];
    XTIRValueId outId = red.valueId;
    int64_t sk = 0;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* d2 = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                d2[@(i.result.valueId)] = i;
    if (!(resolveConstInt(c.seedOp, d2, &sk) && sk == 0))
        {
        XTIRValue* withSeed = newVal(u32);
        [head addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                  result:withSeed
                                                operands:@[ [XTIROperand useWithValueId:red.valueId], c.seedOp ]
                                                  dbgLoc:nil]];
        outId = withSeed.valueId;
        }
    // Epilogue, part 2: the horizontal add lands in a landing pad between the
    // vector loop and the remainder, because the remainder's accumulator starts
    // FROM it -- and because ONE predecessor is what keeps the remainder's phis
    // well-formed when the loop is later rotated (see apply:, part 2, for the
    // bug that costs).
    XTIRValueId finalId = outId;
    if (c.needsEpilogue)
        {
        XTIRBlock* VE = [[XTIRBlock alloc] init];
        VE.name = [NSString stringWithFormat:@"%@_vexit", H.name ?: @"hdr"];
        for (XTIRInsn* i in head)
            [VE appendInstruction:i];
        [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H2] ]
                                                    dbgLoc:nil]];

        NSMutableArray<XTIROperand*>* tops = [H.terminator.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:VE];
        [H.terminator replaceOperands:tops];

        XTIRValueId ivCloneId = (XTIRValueId)cmap[@(c.ivPhi.result.valueId)].unsignedLongLongValue;
        XTIRValueId accCloneId = (XTIRValueId)cmap[@(c.accPhi.result.valueId)].unsignedLongLongValue;
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                {
                if (!(pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH))
                    continue;
                pops[k] = [XTIROperand blockWithRef:VE];
                if (phi.result.valueId == ivCloneId)
                    pops[k + 1] = c.runtimeTrip
                                      ? [XTIROperand useWithValueId:runtimeMId]
                                      : [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
                else if (phi.result.valueId == accCloneId)
                    pops[k + 1] = [XTIROperand useWithValueId:outId];
                }
            [phi replaceOperands:pops];
            }
        finalId = accCloneId; // after the loop, read the REMAINDER's total

        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ VE, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];
        }
    else
        {
        [E.instructions insertObjects:head atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, head.count)]];
        }
    for (XTIRBlock* bb in fn.blocks)
        {
        // The clone reads the original accumulator id through its own remapped
        // values; rewriting inside it would point the remainder at its own result.
        if (bb == H || bb == B || bb == H2 || bb == B2)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:finalId];
                    changed = YES;
                    }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

@end

// ── ESCAPE-TIME loops (2026-10-22). The port's vecEscape (selfhost/opt/Opt.xc),
// which explains the shape and the rewrite; this mirrors it step for step, and
// makes its values in the same order (a back end lays frames out by value id).
//
//   for (i = s; i < N; i++) { <lanes>; while (k < 256 && x*x + y*y < 4) {…}; total += k; }
//
// goes across pixels, VF a step; the inner loop runs under a lane mask and
// leaves when no lane is live; the scalar loop stays as the remainder.
@implementation XTEscapeVec
    {
    XTIRFunction* _fn;
    NSDictionary<NSNumber*, XTIRInsn*>* _defOf;
    NSDictionary<NSNumber*, XTIRBlock*>* _blkOf;
    NSMutableDictionary<NSNumber*, XTIRValue*>* _valOf;
    XTIRBlock *_H, *_PH, *_B, *_T0, *_L, *_E, *_X, *_VB;
    NSMutableArray<XTIRBlock*>* _tests;
    NSMutableArray<NSNumber*>* _cont;
    XTIRInsn *_ivPhi, *_ivNext;
    XTIRInsn *_storeAddr, *_store;
    NSMutableArray<NSNumber*>* _accKind;
    NSMutableArray<XTIRInsn*>* _passPhis;
    NSMutableArray* _accCond;           // XTIROperand or NSNull
    NSMutableArray<XTIRInsn*>* _eLane;
    NSMutableSet<NSString*>* _loadRoots;
    NSMutableSet<NSNumber*>* _idxPhis;
    BOOL _counted;
    XTIRInsn* _tripPhi;
    NSMutableSet<NSNumber*>* _uniform;
    XTIRValue *_viv, *_tripV;
    int64_t _n;
    XTIROperand* _boundOp;
    BOOL _boundConst;
    XTIRInsn* _tripAnd;
    XTIROperand* _tripOther;
    BOOL _signed;
    NSMutableArray<XTIRInsn*>* _accPhis;
    NSMutableArray<XTIROperand*>* _accW;
    NSMutableSet<NSNumber*>* _region;
    NSMutableDictionary<NSNumber*, NSNumber*>* _map;
    NSMutableDictionary<NSNumber*, NSNumber*>* _splat;
    NSMutableDictionary<NSNumber*, NSNumber*>* _exit;
    NSMutableDictionary<NSString*, NSNumber*>* _cse;
    NSMutableSet<NSNumber*>* _skip;
    NSMutableArray<XTIRInsn*>* _pre;
    NSMutableArray<XTIRInsn*>* _splatTo;
    XTIRBlock* _splatHome;
    BOOL _fresh;
    NSUInteger _vf;
    NSMutableArray<XTIRValue*>* _vsum;
    NSMutableArray<XTIRValue*>* _vsumNext;
    NSInteger _tripTest;
    int64_t _tripN, _tripC0;
    XTIRType* _tripTy;
    BOOL _tripSigned;
    }

// xc leaves a `for` loop's step in a block of its own when the body ends in
// `c ? a : b`: folded into its one predecessor, a loop's exit (the port explains).
static NSArray<XTIRBlock*>* escPreds(XTIRFunction* fn, XTIRBlock* t);
static XTIROperand* escFrom(XTIRInsn* phi, XTIRBlock* b);

static void escMergeLatches(XTIRFunction* fn)
    {
    NSUInteger b = 0;
    while (b < fn.blocks.count)
        {
        XTIRBlock* X = fn.blocks[b];
        b++;
        if (X.phiNodes.count != 0 || !X.terminator || X.terminator.opcode != XTIROpBranch || X.terminator.operands.count < 1)
            continue;
        XTIRBlock* H = X.terminator.operands[0].blockRef;
        if (H == X || H.phiNodes.count == 0 || !escFrom(H.phiNodes[0], X))
            continue;
        NSArray<XTIRBlock*>* ps = escPreds(fn, X);
        if (ps.count != 1)
            continue;
        XTIRBlock* P = ps[0];
        if (P == X || P == H || !P.terminator || P.terminator.opcode != XTIROpBranch || P.phiNodes.count != 0)
            continue;
        NSArray<XTIRBlock*>* pp = escPreds(fn, P);
        BOOL exitOfLoop = pp.count > 0;
        for (XTIRBlock* q in pp)
            if (!q.terminator || q.terminator.opcode != XTIROpCondBranch)
                exitOfLoop = NO;
        if (!exitOfLoop)
            continue;
        [P.instructions addObjectsFromArray:X.instructions];
        XTIRInsn* xt = X.terminator;
        [P resetTerminator];
        [P setTerminator:xt];
        for (XTIRInsn* phi in H.phiNodes)
            {
            NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
            for (NSUInteger q = 0; q + 1 < ops.count; q += 2)
                if (ops[q].blockRef == X)
                    ops[q] = [XTIROperand blockWithRef:P];
            [phi replaceOperands:ops];
            }
        b--;
        [fn.blocks removeObjectAtIndex:b];
        }
    }

- (BOOL)runOnFunction:(XTIRFunction*)fn done:(NSMutableSet<NSValue*>*)done
    {
    escMergeLatches(fn);
    _fn = fn;
    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    NSMutableDictionary* bo = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                {
                d[@(p.result.valueId)] = p;
                bo[@(p.result.valueId)] = bb;
                }
        for (XTIRInsn* n in bb.instructions)
            if (n.result)
                {
                d[@(n.result.valueId)] = n;
                bo[@(n.result.valueId)] = bb;
                }
        }
    _defOf = d;
    _blkOf = bo;
    _valOf = [NSMutableDictionary dictionary];
    for (XTIRValue* v in fn.values.allValues)
        _valOf[@(v.valueId)] = v;
    for (XTIRBlock* H in fn.blocks)
        {
        if ([done containsObject:[NSValue valueWithNonretainedObject:H]])
            continue;
        if ([self recognise:H])
            {
            [self apply];
            [done addObject:[NSValue valueWithNonretainedObject:H]];
            return YES;
            }
        }
    return NO;
    }

static NSArray<XTIRBlock*>* escPreds(XTIRFunction* fn, XTIRBlock* t)
    {
    NSMutableArray* ps = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        {
        if (!bb.terminator)
            continue;
        for (XTIROperand* o in bb.terminator.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef == t)
                {
                [ps addObject:bb];
                break;
                }
        }
    return ps;
    }

static XTIROperand* escFrom(XTIRInsn* phi, XTIRBlock* b)
    {
    for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
        if (phi.operands[q].blockRef == b)
            return phi.operands[q + 1];
    return nil;
    }

static BOOL escLane32(XTIRType* t)
    {
    return t && (t.kind == XTIRTypeKindI32 || t.kind == XTIRTypeKindU32 || t.kind == XTIRTypeKindF32);
    }

- (XTIRBlock*)blockOf:(XTIRValueId)v
    {
    return _blkOf[@(v)];
    }

// The port's vecConst: an i32, folded.
- (BOOL)constOf:(XTIROperand*)o into:(int32_t*)out
    {
    int64_t v = 0;
    if (!resolveConstInt(o, _defOf, &v))
        return NO;
    *out = (int32_t)v;
    return YES;
    }

- (BOOL)recognise:(XTIRBlock*)H
    {
    _H = H;
    if (![self outer] || ![self inner] || ![self exitBlock])
        return NO;
    _vf = self.bytes / 4;
    if (_boundConst && (_n < (int64_t)_vf || _n > 0x7FFFFFFF))
        return NO;
    if (!_boundConst)
        {
        XTIRBlock* at = [self blockOf:_boundOp.valueId];
        XTIRType* bt = _valOf[@(_boundOp.valueId)].type;
        if (at == _H || at == _E || [[self regionBlocks] indexOfObjectIdenticalTo:at] != NSNotFound || !bt
            || bt.kind != _ivPhi.result.type.kind)
            return NO;
        }
    if (![self regionOK])
        return NO;
    return [self plan];
    }

- (BOOL)outer
    {
    XTIRInsn* term = _H.terminator;
    if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
        return NO;
    XTIROperand* co = term.operands[0];
    if (co.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* g = _defOf[@(co.valueId)];
    if (!g || g.opcode != XTIROpICmp || g.operands.count < 2)
        return NO;
    BOOL ult = g.predicate == XTIRICmpULT;
    if (!ult && g.predicate != XTIRICmpSLT)
        return NO;
    _signed = !ult;
    for (XTIRInsn* n in _H.instructions)
        if (n != g && n.opcode != XTIROpConst)
            return NO;
    XTIROperand* g0 = g.operands[0];
    if (g0.kind != XTIROperandKindUse)
        return NO;
    // The bound: a constant, or a value from outside the loop (checked once the
    // loop's blocks are known, in recognise).
    int32_t nk = 0;
    _boundOp = g.operands[1];
    _boundConst = [self constOf:_boundOp into:&nk];
    _n = nk;
    if (!_boundConst && (_boundOp.kind != XTIROperandKindUse || _boundOp.valueId == g0.valueId))
        return NO;
    _B = term.operands[1].blockRef;
    _X = term.operands[2].blockRef;
    if (_B == _H || _X == _H)
        return NO;
    NSArray<XTIRBlock*>* ps = escPreds(_fn, _H);
    if (ps.count != 2)
        return NO;
    _ivPhi = nil;
    for (XTIRInsn* p in _H.phiNodes)
        if (p.result && p.result.valueId == g0.valueId)
            _ivPhi = p;
    if (!_ivPhi || !escLane32(_ivPhi.result.type) || _ivPhi.result.type.kind == XTIRTypeKindF32)
        return NO;
    XTIRBlock *p0 = ps[0], *p1 = ps[1];
    XTIROperand* b0 = escFrom(_ivPhi, p0);
    BOOL firstIsLatch = b0 && b0.kind == XTIROperandKindUse && _defOf[@(b0.valueId)].opcode == XTIROpAdd
                        && _defOf[@(b0.valueId)] && [self blockOf:b0.valueId] == p0;
    _E = firstIsLatch ? p0 : p1;
    _PH = firstIsLatch ? p1 : p0;
    if (_E == _B || _PH == _B || !_PH.terminator || _PH.terminator.opcode != XTIROpBranch)
        return NO;
    return escPreds(_fn, _B).count == 1 && _B.phiNodes.count == 0 && _B.terminator
        && _B.terminator.opcode == XTIROpBranch;
    }

- (BOOL)inner
    {
    _T0 = _B.terminator.operands[0].blockRef;
    if (_T0 == _H || _T0 == _B || _T0.phiNodes.count == 0)
        return NO;
    _tests = [NSMutableArray array];
    _cont = [NSMutableArray array];
    XTIRBlock* cur = _T0;
    _L = nil;
    while (_tests.count < 8)
        {
        XTIRInsn* t = cur.terminator;
        if (cur != _T0 && (cur.phiNodes.count != 0 || escPreds(_fn, cur).count != 1))
            return NO;
        // A block that only passes on (xc's `&&`, if-converted, leaves the test
        // in a join block after the header): part of the chain, no test.
        if (t && t.opcode == XTIROpBranch && t.operands.count >= 1)
            {
            XTIRBlock* nx = t.operands[0].blockRef;
            if (nx == _T0 || nx == _H || nx == _B || nx == _E || [_tests indexOfObjectIdenticalTo:nx] != NSNotFound)
                return NO;
            [_tests addObject:cur];
            [_cont addObject:@2];
            cur = nx;
            continue;
            }
        if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
            return NO;
        XTIRBlock* a = t.operands[1].blockRef;
        XTIRBlock* b = t.operands[2].blockRef;
        XTIRBlock* next = nil;
        if (b == _E && a != _E)
            {
            next = a;
            [_cont addObject:@1];
            }
        else if (a == _E && b != _E)
            {
            next = b;
            [_cont addObject:@0];
            }
        else
            return NO;
        if (t.operands[0].kind != XTIROperandKindUse)
            return NO;
        [_tests addObject:cur];
        if (next == _T0 || next == _H || next == _B || [_tests indexOfObjectIdenticalTo:next] != NSNotFound)
            return NO;
        if (next.terminator && next.terminator.opcode == XTIROpBranch && next.terminator.operands[0].blockRef == _T0)
            {
            _L = next;
            break;
            }
        cur = next;
        }
    if (!_L || _L.phiNodes.count != 0 || escPreds(_fn, _L).count != 1)
        return NO;
    if (escPreds(_fn, _T0).count != 2)
        return NO;
    for (XTIRInsn* p in _T0.phiNodes)
        if (!p.result || !escLane32(p.result.type) || p.operands.count != 4 || !escFrom(p, _B) || !escFrom(p, _L))
            return NO;
    NSArray<XTIRBlock*>* ep = escPreds(_fn, _E);
    NSUInteger testing = 0;
    for (NSNumber* c in _cont)
        if (c.intValue != 2)
            testing++;
    if (ep.count != testing || testing == 0 || _E.phiNodes.count != 0)
        return NO;
    for (XTIRBlock* p in ep)
        if ([_tests indexOfObjectIdenticalTo:p] == NSNotFound)
            return NO;
    return YES;
    }

// E: constants, iv + 1, one sum per other phi of H (`s + w`, or `c ? s + w : s`),
// at most one store of a lane value to a[i], and lane arithmetic feeding those.
- (BOOL)exitBlock
    {
    if (!_E.terminator || _E.terminator.opcode != XTIROpBranch || _E.terminator.operands[0].blockRef != _H)
        return NO;
    XTIRValueId iv = _ivPhi.result.valueId;
    XTIROperand* ivBack = escFrom(_ivPhi, _E);
    if (!ivBack || ivBack.kind != XTIROperandKindUse)
        return NO;
    _ivNext = _defOf[@(ivBack.valueId)];
    if (!_ivNext || _ivNext.opcode != XTIROpAdd || _ivNext.operands.count != 2 || [self blockOf:ivBack.valueId] != _E)
        return NO;
    XTIROperand *a = _ivNext.operands[0], *b = _ivNext.operands[1];
    int32_t one = 0;
    BOOL aIv = a.kind == XTIROperandKindUse && a.valueId == iv;
    XTIROperand* step = aIv ? b : a;
    XTIROperand* self0 = aIv ? a : b;
    if (self0.kind != XTIROperandKindUse || self0.valueId != iv || ![self constOf:step into:&one] || one != 1)
        return NO;
    NSMutableSet<NSNumber*>* special = [NSMutableSet setWithObject:@(_ivNext.result.valueId)];
    _accPhis = [NSMutableArray array];
    _accW = [NSMutableArray array];
    _accKind = [NSMutableArray array];
    _accCond = [NSMutableArray array];
    _passPhis = [NSMutableArray array];
    for (XTIRInsn* p in _H.phiNodes)
        {
        if (p == _ivPhi)
            continue;
        // A phi the loop leaves as it is: it re-enters unchanged.
        XTIROperand* pb = escFrom(p, _E);
        if (pb && pb.kind == XTIROperandKindUse && pb.valueId == p.result.valueId && p.operands.count == 4
            && [self uses:p.result.valueId] == 1)
            {
            [_passPhis addObject:p];
            continue;
            }
        if (![self accOf:p special:special])
            return NO;
        }
    // ONE store of a lane value to a[i] (the port explains).
    _storeAddr = nil;
    _store = nil;
    for (XTIRInsn* n in _E.instructions)
        {
        if (n.opcode != XTIROpStore)
            continue;
        if (_store || n.operands.count < 2)
            return NO;
        XTIROperand* ad = n.operands[0];
        XTIRInsn* ea = ad.kind == XTIROperandKindUse ? _defOf[@(ad.valueId)] : nil;
        if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count != 2 || [self blockOf:ea.result.valueId] != _E
            || [self uses:ea.result.valueId] != 1)
            return NO;
        XTIROperand* ix = ea.operands[1];
        if (ix.kind != XTIROperandKindUse || ix.valueId != iv || ea.operands[0].kind != XTIROperandKindUse)
            return NO;
        _store = n;
        _storeAddr = ea;
        [special addObject:@(ea.result.valueId)];
        }
    _eLane = [NSMutableArray array];
    for (XTIRInsn* n in _E.instructions)
        {
        if (n.opcode == XTIROpConst || n == _store || (n.result && [special containsObject:@(n.result.valueId)]))
            continue;
        [_eLane addObject:n];
        }
    return YES;
    }

- (BOOL)accOf:(XTIRInsn*)p special:(NSMutableSet<NSNumber*>*)special
    {
    XTIROperand* back = escFrom(p, _E);
    if (p.operands.count != 4 || !back || back.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = _defOf[@(back.valueId)];
    XTIRType* t = p.result.type;
    if (!d || [self blockOf:d.result.valueId] != _E || !t || !(t.kind == XTIRTypeKindI32 || t.kind == XTIRTypeKindU32)
        || t.kind != d.result.type.kind)
        return NO;
    XTIRInsn* add = d;
    NSUInteger kind = 0;
    XTIROperand* cond = nil;
    if (d.opcode == XTIROpSelect && d.operands.count == 3)
        {
        XTIROperand *x = d.operands[1], *y = d.operands[2];
        XTIROperand* other = nil;
        if (y.kind == XTIROperandKindUse && y.valueId == p.result.valueId)
            {
            kind = 1;
            other = x;
            }
        else if (x.kind == XTIROperandKindUse && x.valueId == p.result.valueId)
            {
            kind = 2;
            other = y;
            }
        if (!other || other.kind != XTIROperandKindUse)
            return NO;
        add = _defOf[@(other.valueId)];
        if (!add || [self blockOf:add.result.valueId] != _E || [self uses:add.result.valueId] != 1)
            return NO;
        cond = d.operands[0];
        [special addObject:@(add.result.valueId)];
        }
    if (add.opcode != XTIROpAdd || add.operands.count != 2 || add.result.type.kind != t.kind)
        return NO;
    XTIROperand *a = add.operands[0], *b = add.operands[1];
    BOOL aIs = a.kind == XTIROperandKindUse && a.valueId == p.result.valueId;
    BOOL bIs = b.kind == XTIROperandKindUse && b.valueId == p.result.valueId;
    if (!aIs && !bIs)
        return NO;
    [special addObject:@(d.result.valueId)];
    [_accPhis addObject:p];
    [_accW addObject:aIs ? b : a];
    [_accKind addObject:@(kind)];
    [_accCond addObject:cond ?: (id)[NSNull null]];
    return YES;
    }

- (NSArray<XTIRBlock*>*)regionBlocks
    {
    NSMutableArray* r = [NSMutableArray arrayWithObject:_B];
    [r addObjectsFromArray:_tests];
    [r addObject:_L];
    return r;
    }

- (BOOL)isAcc:(XTIRValueId)v
    {
    for (XTIRInsn* p in _accPhis)
        if (p.result.valueId == v)
            return YES;
    return NO;
    }

- (BOOL)isInvariant:(XTIRValueId)v
    {
    if (v == _ivPhi.result.valueId || [_region containsObject:@(v)] || [self isAcc:v])
        return NO;
    XTIRBlock* at = [self blockOf:v];
    return !at || !(at == _H || at == _E || [[self regionBlocks] indexOfObjectIdenticalTo:at] != NSNotFound);
    }

- (NSString*)rootOf:(XTIRValueId)p
    {
    XTIRValueId v = p;
    for (NSUInteger hop = 0; hop < 16; hop++)
        {
        XTIRInsn* d = _defOf[@(v)];
        if (!d || d.operands.count < 1)
            break;
        XTIROperand* o = d.operands[0];
        if (d.opcode == XTIROpAddrOf && o.kind == XTIROperandKindSym)
            return [NSString stringWithFormat:@"s:%@", sVecModule.symbols[o.symbolId].name];
        if ((d.opcode == XTIROpElementAddr || d.opcode == XTIROpFieldAddr) && o.kind == XTIROperandKindUse)
            {
            v = o.valueId;
            continue;
            }
        break;
        }
    return [NSString stringWithFormat:@"v:%llu", (unsigned long long)v];
    }

- (NSUInteger)addrKind:(XTIRInsn*)ea
    {
    if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count != 2)
        return 0;
    XTIROperand *base = ea.operands[0], *ix = ea.operands[1];
    if (base.kind != XTIROperandKindUse || ![self isInvariant:base.valueId])
        return 0;
    if (ix.kind == XTIROperandKindImmI)
        return 3;
    if (ix.kind != XTIROperandKindUse)
        return 0;
    if (ix.valueId == _ivPhi.result.valueId)
        return 1;
    for (XTIRInsn* p in _T0.phiNodes)
        if (p.result.valueId == ix.valueId)
            return 2;
    return [self isInvariant:ix.valueId] ? 3 : 0;
    }

- (XTIRInsn*)ownAddr:(XTIROperand*)ad
    {
    if (ad.kind != XTIROperandKindUse || ![_region containsObject:@(ad.valueId)])
        return nil;
    XTIRInsn* d = _defOf[@(ad.valueId)];
    return d && d.opcode == XTIROpElementAddr ? d : nil;
    }

- (BOOL)loadOK:(XTIRInsn*)n
    {
    if (n.operands.count < 1 || !n.result || !escLane32(n.result.type))
        return NO;
    XTIROperand* ad = n.operands[0];
    if (ad.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* ea = [self ownAddr:ad];
    if (ea)
        {
        NSUInteger k = [self addrKind:ea];
        if (k == 0)
            return NO;
        if (k == 2)
            [_idxPhis addObject:@(ea.operands[1].valueId)];
        [_loadRoots addObject:[self rootOf:ea.operands[0].valueId]];
        return YES;
        }
    if (![self isInvariant:ad.valueId])
        return NO;
    [_loadRoots addObject:[self rootOf:ad.valueId]];
    return YES;
    }

- (BOOL)addrOK:(XTIRInsn*)n
    {
    if ([self addrKind:n] == 0)
        return NO;
    NSUInteger loads = 0;
    NSMutableArray<XTIRBlock*>* blks = [[self regionBlocks] mutableCopy];
    [blks addObject:_E];
    for (XTIRBlock* bb in blks)
        for (XTIRInsn* m in bb.instructions)
            if (m.opcode == XTIROpLoad && m.operands.count >= 1 && m.operands[0].kind == XTIROperandKindUse
                && m.operands[0].valueId == n.result.valueId)
                loads++;
    return loads == [self uses:n.result.valueId];
    }

- (BOOL)regionOK
    {
    _region = [NSMutableSet set];
    _loadRoots = [NSMutableSet set];
    _idxPhis = [NSMutableSet set];
    for (XTIRInsn* p in _T0.phiNodes)
        [_region addObject:@(p.result.valueId)];
    NSArray<XTIRBlock*>* blks = [self regionBlocks];
    for (XTIRBlock* bb in blks)
        for (XTIRInsn* n in bb.instructions)
            if (n.result)
                [_region addObject:@(n.result.valueId)];
    for (XTIRInsn* n in _eLane)
        if (n.result)
            [_region addObject:@(n.result.valueId)];
    for (XTIRBlock* bb in blks)
        for (XTIRInsn* n in bb.instructions)
            if (![self laneable:n])
                return NO;
    for (XTIRInsn* n in _eLane)
        if (![self laneable:n])
            return NO;
    for (NSUInteger i = 0; i < _accW.count; i++)
        {
        if (![self operandOK:_accW[i] mask:NO])
            return NO;
        id c = _accCond[i];
        if (c != [NSNull null])
            {
            XTIROperand* co = c;
            if (co.kind != XTIROperandKindUse || ![self operandOK:co mask:YES]
                || _valOf[@(co.valueId)].type.kind != XTIRTypeKindBool || ![_region containsObject:@(co.valueId)])
                return NO;
            }
        }
    if (_store)
        {
        XTIROperand* sv = _store.operands[1];
        XTIRBlock* at = [self blockOf:_storeAddr.operands[0].valueId];
        if (![self operandOK:sv mask:NO] || sv.kind != XTIROperandKindUse
            || at == _H || at == _E || [blks indexOfObjectIdenticalTo:at] != NSNotFound)
            return NO;
        NSString* sr = [self rootOf:_storeAddr.operands[0].valueId];
        if (_loadRoots.count > 0 && (![sr hasPrefix:@"s:"] || [_loadRoots containsObject:sr]))
            return NO;
        for (NSString* r in _loadRoots)
            if (![r hasPrefix:@"s:"])
                return NO;
        }
    for (XTIRBlock* bb in _fn.blocks)
        {
        BOOL inLoop = bb == _H || bb == _E || [blks indexOfObjectIdenticalTo:bb] != NSNotFound || bb == _T0;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (NSUInteger i = 0; i < all.count; i++)
            {
            if (bb == _T0 && i < bb.phiNodes.count)
                continue;
            for (XTIROperand* o in all[i].operands)
                {
                if (o.kind != XTIROperandKindUse)
                    continue;
                if (!inLoop && [_region containsObject:@(o.valueId)])
                    return NO;
                if (inLoop && bb != _E && bb != _H && [self isAcc:o.valueId])
                    return NO;
                }
            }
        }
    return YES;
    }

// After recognition: the counters, the trip count, and whether the inner loop
// is COUNTED (no lane test left), which a[j] loads need.
- (BOOL)plan
    {
    _skip = [NSMutableSet set];
    for (XTIRInsn* p in _T0.phiNodes)
        {
        XTIRInsn* ctr = [self counterOf:p];
        if (ctr)
            [_skip addObject:@(ctr.result.valueId)];
        }
    [self tripTest];
    _counted = _tripTest >= 0 && !_tripOther;
    for (NSUInteger t = 0; t < _tests.count; t++)
        if (_cont[t].intValue != 2 && (NSInteger)t != _tripTest)
            _counted = NO;
    _uniform = [NSMutableSet set];
    if (_idxPhis.count > 0)
        {
        if (!_counted || !_tripPhi)
            return NO;
        for (NSNumber* v in _idxPhis)
            if (v.unsignedLongLongValue != _tripPhi.result.valueId)
                return NO;
        }
    if (_counted && _tripPhi)
        {
        NSUInteger idx = 0;
        for (XTIRBlock* bb in [self regionBlocks])
            for (XTIRInsn* m in bb.instructions)
                if (m.opcode == XTIROpElementAddr && m.operands.count == 2 && m.operands[1].kind == XTIROperandKindUse
                    && m.operands[1].valueId == _tripPhi.result.valueId)
                    idx++;
        if ([self uses:_tripPhi.result.valueId] == idx + 2)
            [_uniform addObject:@(_tripPhi.result.valueId)];
        }
    return YES;
    }

- (BOOL)operandOK:(XTIROperand*)o mask:(BOOL)maskOK
    {
    if (o.kind == XTIROperandKindImmI || o.kind == XTIROperandKindImmF)
        return YES;
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId v = o.valueId;
    XTIRType* t = _valOf[@(v)].type;
    if (v == _ivPhi.result.valueId || [_region containsObject:@(v)])
        return escLane32(t) || (maskOK && t.kind == XTIRTypeKindBool);
    if ([self isAcc:v])
        return NO;
    if (!escLane32(t))
        return NO;
    XTIRInsn* d = _defOf[@(v)];
    if (d && d.opcode == XTIROpConst)
        return YES;
    XTIRBlock* at = [self blockOf:v];
    return !at || !(at == _H || at == _E || [[self regionBlocks] indexOfObjectIdenticalTo:at] != NSNotFound);
    }

- (int64_t)constOfOrNeg:(XTIROperand*)o
    {
    int32_t k = 0;
    if (![self constOf:o into:&k])
        return -1;
    return k;
    }

static int64_t escLog2(int64_t v)
    {
    if (v <= 0 || (v & (v - 1)) != 0)
        return -1;
    int64_t s = 0;
    while (((int64_t)1 << s) < v)
        s++;
    return s;
    }

- (BOOL)smallUnsigned:(XTIROperand*)o
    {
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = _defOf[@(o.valueId)];
    if (!d || d.operands.count < 2)
        return NO;
    int64_t k = [self constOfOrNeg:d.operands[1]];
    if (d.opcode == XTIROpURem)
        return k > 0 && k <= 0x80000000LL;
    if (d.opcode == XTIROpUDiv)
        return k >= 2;
    if (d.opcode == XTIROpLShr)
        return k >= 1 && k < 32;
    if (d.opcode == XTIROpAnd)
        return k >= 0 && k <= 0x7FFFFFFF;
    return NO;
    }

static BOOL escFloatPred(uint8_t p)
    {
    return p == XTIRFCmpOLT || p == XTIRFCmpOLE || p == XTIRFCmpOGT || p == XTIRFCmpOGE || p == XTIRFCmpOEQ;
    }

// `(u32)100`: a ZExt/SExt/Trunc of a constant, which is itself a constant.
- (BOOL)isConstExt:(XTIRInsn*)n
    {
    if (!n || !n.result)
        return NO;
    if (n.opcode != XTIROpZExt && n.opcode != XTIROpSExt && n.opcode != XTIROpTrunc)
        return NO;
    int32_t k = 0;
    return escLane32(n.result.type) && n.result.type.kind != XTIRTypeKindF32
        && [self constOf:[XTIROperand useWithValueId:n.result.valueId] into:&k];
    }

- (BOOL)laneable:(XTIRInsn*)n
    {
    XTIROpcode op = n.opcode;
    // A constant of any width: one is only read through a splat (a lane
    // operation on a narrow one would itself be narrow, and refused).
    if (op == XTIROpConst)
        return n.result != nil;
    if ([self isConstExt:n])
        return YES;
    if (op == XTIROpElementAddr)
        return [self addrOK:n];
    if (op == XTIROpLoad)
        return [self loadOK:n];
    if (!n.result)
        return NO;
    XTIRType* t = n.result.type;
    BOOL isBool = t.kind == XTIRTypeKindBool;
    if (!escLane32(t) && !isBool)
        return NO;
    NSUInteger nops = n.operands.count;
    if (op == XTIROpAdd || op == XTIROpSub || op == XTIROpMul || op == XTIROpFAdd || op == XTIROpFSub
        || op == XTIROpFMul || op == XTIROpFDiv)
        return !isBool && nops == 2 && [self operandOK:n.operands[0] mask:NO] && [self operandOK:n.operands[1] mask:NO];
    if (op == XTIROpAnd || op == XTIROpOr || op == XTIROpXor)
        return nops == 2 && t.kind != XTIRTypeKindF32 && [self operandOK:n.operands[0] mask:isBool]
            && [self operandOK:n.operands[1] mask:isBool]
            && (!isBool || (n.operands[0].kind == XTIROperandKindUse && n.operands[1].kind == XTIROperandKindUse));
    if (op == XTIROpNot)
        return isBool && nops == 1 && [self operandOK:n.operands[0] mask:YES]
            && n.operands[0].kind == XTIROperandKindUse;
    if (op == XTIROpFSqrt)
        return t.kind == XTIRTypeKindF32 && nops == 1 && [self operandOK:n.operands[0] mask:NO];
    if (op == XTIROpShl || op == XTIROpLShr)
        {
        int64_t k = nops == 2 ? [self constOfOrNeg:n.operands[1]] : -1;
        return !isBool && t.kind != XTIRTypeKindF32 && k >= 0 && k < 32 && [self operandOK:n.operands[0] mask:NO];
        }
    if (op == XTIROpURem || op == XTIROpUDiv)
        return !isBool && t.kind != XTIRTypeKindF32 && nops == 2 && escLog2([self constOfOrNeg:n.operands[1]]) >= 0
            && [self operandOK:n.operands[0] mask:NO];
    if (op == XTIROpSIToFp || op == XTIROpUIToFp)
        {
        if (nops != 1 || t.kind != XTIRTypeKindF32)
            return NO;
        XTIROperand* a = n.operands[0];
        if (![self operandOK:a mask:NO] || a.kind != XTIROperandKindUse || _valOf[@(a.valueId)].type.kind == XTIRTypeKindF32)
            return NO;
        return op == XTIROpSIToFp || [self smallUnsigned:a];
        }
    if (op == XTIROpICmp || op == XTIROpFCmp)
        {
        if (!isBool || nops != 2)
            return NO;
        XTIROperand *a = n.operands[0], *b = n.operands[1];
        if (![self operandOK:a mask:NO] || ![self operandOK:b mask:NO])
            return NO;
        if (a.kind != XTIROperandKindUse && b.kind != XTIROperandKindUse)
            return NO;
        return op == XTIROpICmp || escFloatPred(n.predicate);
        }
    if (op == XTIROpSelect)
        {
        if (isBool || nops != 3)
            return NO;
        XTIROperand* c = n.operands[0];
        return c.kind == XTIROperandKindUse && [self operandOK:c mask:YES]
            && _valOf[@(c.valueId)].type.kind == XTIRTypeKindBool
            && [self operandOK:n.operands[1] mask:NO] && [self operandOK:n.operands[2] mask:NO];
        }
    return NO;
    }

// ── the rewrite ──────────────────────────────────────────────────────────────

- (XTIRType*)vecTy:(XTIRType*)scalar
    {
    if (scalar.kind == XTIRTypeKindBool)
        return [XTIRType vecWithLane:[XTIRType i32Type] bytes:(uint32_t)self.bytes];
    return [XTIRType vecWithLane:scalar bytes:(uint32_t)self.bytes];
    }

- (XTIRValue*)newVal:(XTIRType*)t home:(XTIRBlock*)home
    {
    XTIRValueId rid = [_fn allocateValueId];
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                 type:t
                                              defSite:[[XTIRDefSite alloc] initWithBlock:home insnIndex:0]];
    [_fn registerValue:v];
    _valOf[@(rid)] = v;
    return v;
    }

// escPut: a new value of `t`, made by `op` from `a` (and `b`), appended.
- (XTIRValue*)put:(NSMutableArray<XTIRInsn*>*)into home:(XTIRBlock*)home op:(XTIROpcode)op ty:(XTIRType*)t
                a:(XTIROperand*)a b:(XTIROperand*)b
    {
    XTIRValue* r = [self newVal:t home:home];
    NSMutableArray* ops = [NSMutableArray array];
    if (a)
        [ops addObject:a];
    if (b)
        [ops addObject:b];
    [into addObject:[[XTIRInsn alloc] initWithOpcode:op result:r operands:ops dbgLoc:nil]];
    return r;
    }

- (XTIRValue*)put:(NSMutableArray<XTIRInsn*>*)into home:(XTIRBlock*)home op:(XTIROpcode)op ty:(XTIRType*)t
                a:(XTIROperand*)a b:(XTIROperand*)b pred:(uint8_t)pred
    {
    XTIRValue* r = [self newVal:t home:home];
    [into addObject:[[XTIRInsn alloc] initWithOpcode:op result:r operands:@[ a, b ] predicate:pred dbgLoc:nil]];
    return r;
    }

- (XTIRValue*)splatOf:(XTIROperand*)o scalar:(XTIRType*)scalarTy
    {
    NSMutableArray* pre = _splatTo;
    XTIRBlock* home = _splatHome;
    if (o.kind == XTIROperandKindUse)
        {
        NSNumber* have = _fresh ? nil : _splat[@(o.valueId)];
        if (have)
            return _valOf[have];
        XTIROperand* src = o;
        XTIRInsn* d = _defOf[@(o.valueId)];
        XTIRType* ot = _valOf[@(o.valueId)].type;
        if (d && (d.opcode == XTIROpConst || [self isConstExt:d]))
            {
            XTIRValue* cv = [self newVal:ot home:home];
            XTIROperand* k0 = d.operands[0];
            if (d.opcode != XTIROpConst)
                {
                int32_t k = 0;
                [self constOf:o into:&k];
                k0 = [XTIROperand immIWithType:ot value:(int64_t)k];
                }
            [pre addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst result:cv operands:@[ k0 ] dbgLoc:nil]];
            src = [XTIROperand useWithValueId:cv.valueId];
            }
        XTIRValue* s = [self put:pre home:home op:XTIROpVSplat ty:[self vecTy:ot] a:src b:nil];
        if (!_fresh)
            _splat[@(o.valueId)] = @(s.valueId);
        return s;
        }
    XTIRValue* cv = [self newVal:scalarTy home:home];
    [pre addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst result:cv operands:@[ o ] dbgLoc:nil]];
    return [self put:pre home:home op:XTIROpVSplat ty:[self vecTy:scalarTy]
                   a:[XTIROperand useWithValueId:cv.valueId] b:nil];
    }

- (XTIROperand*)v:(XTIROperand*)o scalar:(XTIRType*)scalarTy
    {
    if (o.kind == XTIROperandKindUse)
        {
        NSNumber* m = _map[@(o.valueId)];
        if (m)
            return [XTIROperand useWithValueId:m.unsignedLongLongValue];
        return [XTIROperand useWithValueId:[self splatOf:o scalar:_valOf[@(o.valueId)].type].valueId];
        }
    return [XTIROperand useWithValueId:[self splatOf:o scalar:scalarTy].valueId];
    }

- (XTIRType*)opTy:(XTIRInsn*)n at:(NSUInteger)k
    {
    XTIROperand* o = n.operands[k];
    if (o.kind == XTIROperandKindUse && _valOf[@(o.valueId)])
        return _valOf[@(o.valueId)].type;
    for (XTIROperand* p in n.operands)
        if (p.kind == XTIROperandKindUse && _valOf[@(p.valueId)])
            return _valOf[@(p.valueId)].type;
    return n.result.type;
    }

- (XTIRValue*)blend:(NSMutableArray*)into home:(XTIRBlock*)home ty:(XTIRType*)vty
               mask:(XTIRValue*)m a:(XTIRValue*)a b:(XTIRValue*)b
    {
    XTIRValue* d = [self put:into home:home op:XTIROpVXor ty:vty a:[XTIROperand useWithValueId:a.valueId]
                           b:[XTIROperand useWithValueId:b.valueId]];
    XTIRValue* e = [self put:into home:home op:XTIROpVAnd ty:vty a:[XTIROperand useWithValueId:d.valueId]
                           b:[XTIROperand useWithValueId:m.valueId]];
    return [self put:into home:home op:XTIROpVXor ty:vty a:[XTIROperand useWithValueId:b.valueId]
                   b:[XTIROperand useWithValueId:e.valueId]];
    }

- (void)lane:(NSMutableArray<XTIRInsn*>*)into home:(XTIRBlock*)home insn:(XTIRInsn*)n
    {
    XTIROpcode op = n.opcode;
    if (op == XTIROpConst || [_skip containsObject:@(n.result.valueId)] || [self isConstExt:n]
        || op == XTIROpElementAddr)
        return;     // an address is made by the load that reads it
    if (op == XTIROpLoad)
        {
        [self laneLoad:into home:home insn:n];
        return;
        }
    XTIRType* vty = [self vecTy:n.result.type];
    XTIRValue* r = nil;
    XTIROperand* a = n.operands[0];
    if (op == XTIROpNot)
        {
        XTIROperand* va = [self v:a scalar:n.result.type];
        r = [self put:into home:home op:XTIROpVNot ty:vty a:va b:nil];
        }
    else if (op == XTIROpFSqrt)
        {
        XTIROperand* va = [self v:a scalar:n.result.type];
        r = [self put:into home:home op:XTIROpVSqrt ty:vty a:va b:nil];
        }
    else if (op == XTIROpSIToFp || op == XTIROpUIToFp)
        {
        XTIROperand* va = [self v:a scalar:_valOf[@(a.valueId)].type];
        r = [self put:into home:home op:XTIROpVSIToFp ty:vty a:va b:nil];
        }
    else if (op == XTIROpSelect)
        {
        XTIRValue* m = _valOf[_map[@(a.valueId)]];
        XTIRValue* x = _valOf[@([self v:n.operands[1] scalar:n.result.type].valueId)];
        XTIRValue* y = _valOf[@([self v:n.operands[2] scalar:n.result.type].valueId)];
        r = [self blend:into home:home ty:vty mask:m a:x b:y];
        }
    else
        {
        NSUInteger before = into.count;
        r = [self lane2:into home:home insn:n ty:vty];
        if (into.count == before)
            {
            _map[@(n.result.valueId)] = @(r.valueId);
            return;
            }
        }
    _map[@(n.result.valueId)] = @(r.valueId);
    XTIRInsn* last = into.lastObject;
    if (n.dbgLoc)
        into[into.count - 1] = [[XTIRInsn alloc] initWithOpcode:last.opcode result:last.result operands:last.operands
                                                      predicate:last.predicate dbgLoc:n.dbgLoc];
    }

// A load: a[i] a vector load at a[viv]; a[j] (j the trip count) and an address
// from outside the loop one scalar load, splat (the port explains the token).
- (void)laneLoad:(NSMutableArray<XTIRInsn*>*)into home:(XTIRBlock*)home insn:(XTIRInsn*)n
    {
    XTIROperand* ad = n.operands[0];
    XTIRInsn* ea = [self ownAddr:ad];
    NSUInteger kind = ea ? [self addrKind:ea] : 3;
    XTIRType* vty = [self vecTy:n.result.type];
    XTIRValue* r = nil;
    if (kind == 1)
        {
        XTIRValue* av = [self newVal:ea.result.type home:home];
        [into addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                  result:av
                                                operands:@[ ea.operands[0], [XTIROperand useWithValueId:_viv.valueId] ]
                                                  dbgLoc:nil]];
        r = [self put:into home:home op:XTIROpVLoad ty:vty a:[XTIROperand useWithValueId:av.valueId] b:nil];
        }
    else
        {
        XTIROperand* addr = ad;
        if (ea)
            {
            XTIRValue* av = [self newVal:ea.result.type home:home];
            XTIROperand* ix = kind == 2 ? [XTIROperand useWithValueId:_tripV.valueId] : ea.operands[1];
            [into addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                      result:av
                                                    operands:@[ ea.operands[0], ix ]
                                                      dbgLoc:nil]];
            addr = [XTIROperand useWithValueId:av.valueId];
            }
        XTIRValue* sv = [self newVal:n.result.type home:home];
        XTIRValueId mem = (XTIRValueId)(_fn.paramTypes.count - 1);
        XTIRInsn* ld = [[XTIRInsn alloc] initWithOpcode:XTIROpLoad
                                                 result:sv
                                               operands:@[ addr, [XTIROperand useWithValueId:mem] ]
                                                 dbgLoc:nil];
        ld.memoryResult = [self newVal:[XTIRType memoryType] home:home];
        [into addObject:ld];
        r = [self put:into home:home op:XTIROpVSplat ty:vty a:[XTIROperand useWithValueId:sv.valueId] b:nil];
        }
    _map[@(n.result.valueId)] = @(r.valueId);
    XTIRInsn* last = into.lastObject;
    if (n.dbgLoc)
        into[into.count - 1] = [[XTIRInsn alloc] initWithOpcode:last.opcode result:last.result operands:last.operands
                                                      predicate:last.predicate dbgLoc:n.dbgLoc];
    }

- (BOOL)isTwo:(XTIROperand*)o
    {
    XTIROperand* c = o;
    if (o.kind == XTIROperandKindUse)
        {
        XTIRInsn* d = _defOf[@(o.valueId)];
        if (!d || d.opcode != XTIROpConst || d.operands.count < 1)
            return NO;
        c = d.operands[0];
        }
    return c.kind == XTIROperandKindImmF && c.floatRawBytes == 0x4000000000000000ULL;
    }

- (XTIRValue*)putC:(NSMutableArray*)into home:(XTIRBlock*)home op:(XTIROpcode)op ty:(XTIRType*)t
                 a:(XTIROperand*)a b:(XTIROperand*)b
    {
    NSString* k = [NSString stringWithFormat:@"%u:%llu:%llu", (unsigned)op, (unsigned long long)a.valueId,
                            (unsigned long long)b.valueId];
    NSNumber* have = _cse[k];
    if (have)
        return _valOf[have];
    XTIRValue* r = [self put:into home:home op:op ty:t a:a b:b];
    _cse[k] = @(r.valueId);
    return r;
    }

- (XTIRValue*)lane2:(NSMutableArray*)into home:(XTIRBlock*)home insn:(XTIRInsn*)n ty:(XTIRType*)vty
    {
    XTIROpcode op = n.opcode;
    XTIROperand *a = n.operands[0], *b = n.operands[1];
    XTIRType* ta = [self opTy:n at:0];
    XTIRType* tb = [self opTy:n at:1];
    if (op == XTIROpShl || op == XTIROpLShr)
        {
        XTIROperand* va = [self v:a scalar:ta];
        return [self put:into home:home op:(op == XTIROpShl ? XTIROpVShl : XTIROpVLShr) ty:vty a:va
                       b:[XTIROperand immIWithType:n.result.type value:[self constOfOrNeg:b]]];
        }
    if (op == XTIROpUDiv)
        {
        XTIROperand* va = [self v:a scalar:ta];
        return [self put:into home:home op:XTIROpVLShr ty:vty a:va
                       b:[XTIROperand immIWithType:n.result.type value:escLog2([self constOfOrNeg:b])]];
        }
    if (op == XTIROpURem)
        {
        XTIROperand* va = [self v:a scalar:ta];
        XTIRValue* m = [self splatOf:[XTIROperand immIWithType:n.result.type value:[self constOfOrNeg:b] - 1]
                              scalar:n.result.type];
        return [self put:into home:home op:XTIROpVAnd ty:vty a:va b:[XTIROperand useWithValueId:m.valueId]];
        }
    if (op == XTIROpICmp || op == XTIROpFCmp)
        {
        XTIROperand* va = [self v:a scalar:ta];
        XTIROperand* vb = [self v:b scalar:tb];
        return [self put:into home:home op:(op == XTIROpICmp ? XTIROpVICmp : XTIROpVFCmp) ty:vty a:va b:vb
                    pred:n.predicate];
        }
    if (op == XTIROpFMul && ([self isTwo:a] || [self isTwo:b]))
        {
        XTIROperand* v = [self v:([self isTwo:a] ? b : a) scalar:n.result.type];
        return [self putC:into home:home op:XTIROpVAdd ty:vty a:v b:v];
        }
    XTIROpcode vop = XTIROpVAdd;
    if (op == XTIROpSub || op == XTIROpFSub)
        vop = XTIROpVSub;
    else if (op == XTIROpMul || op == XTIROpFMul)
        vop = XTIROpVMul;
    else if (op == XTIROpFDiv)
        vop = XTIROpVDiv;
    else if (op == XTIROpAnd)
        vop = XTIROpVAnd;
    else if (op == XTIROpOr)
        vop = XTIROpVOr;
    else if (op == XTIROpXor)
        vop = XTIROpVXor;
    XTIROperand* va = [self v:a scalar:ta];
    XTIROperand* vb = [self v:b scalar:tb];
    return [self putC:into home:home op:vop ty:vty a:va b:vb];
    }

// The `p + 1` in L that is T0 phi p's next value and read by nothing else.
- (XTIRInsn*)counterOf:(XTIRInsn*)p
    {
    if (p.result.type.kind == XTIRTypeKindF32)
        return nil;
    XTIROperand* back = escFrom(p, _L);
    if (!back || back.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = _defOf[@(back.valueId)];
    if (!d || d.opcode != XTIROpAdd || d.operands.count != 2 || [self blockOf:d.result.valueId] != _L)
        return nil;
    XTIROperand *a = d.operands[0], *b = d.operands[1];
    BOOL aP = a.kind == XTIROperandKindUse && a.valueId == p.result.valueId;
    XTIROperand* step = aP ? b : a;
    XTIROperand* self0 = aP ? a : b;
    int32_t one = 0;
    if (self0.kind != XTIROperandKindUse || self0.valueId != p.result.valueId || ![self constOf:step into:&one]
        || one != 1)
        return nil;
    if ([self uses:d.result.valueId] != 1)
        return nil;
    return d;
    }

- (NSUInteger)uses:(XTIRValueId)v
    {
    NSUInteger c = 0;
    for (XTIRBlock* bb in _fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* n in all)
            for (XTIROperand* o in n.operands)
                if (o.kind == XTIROperandKindUse && o.valueId == v)
                    c++;
        }
    return c;
    }

// `k < N` on a counter k that enters at a constant c0 < N: the scalar test on
// the inner loop's trip count (the port's escTripTest explains).
- (void)tripTest
    {
    _tripTest = -1;
    _tripPhi = nil;
    for (NSUInteger t = 0; t < _tests.count; t++)
        {
        if (_cont[t].intValue != 1)
            continue;
        XTIRBlock* T = _tests[t];
        XTIROperand* co = T.terminator.operands[0];
        XTIRInsn* g = _defOf[@(co.valueId)];
        // `k < N && rest`, if-converted to an And: the trip count takes the
        // `k < N` half and the rest stays a lane test.
        _tripAnd = nil;
        _tripOther = nil;
        if (g && g.opcode == XTIROpAnd && g.operands.count == 2 && [self uses:g.result.valueId] == 1
            && [_region containsObject:@(g.result.valueId)])
            {
            XTIRInsn* andI = g;
            g = nil;
            for (NSUInteger h = 0; h < 2 && !g; h++)
                {
                XTIROperand* side = andI.operands[h];
                XTIROperand* other = andI.operands[1 - h];
                if (side.kind != XTIROperandKindUse || other.kind != XTIROperandKindUse)
                    continue;
                XTIRInsn* q = _defOf[@(side.valueId)];
                if (q && q.opcode == XTIROpICmp && [self tripCmpOK:q inAnd:YES])
                    {
                    g = q;
                    _tripAnd = andI;
                    _tripOther = other;
                    }
                }
            if (!g)
                continue;
            }
        else if (!g || g.opcode != XTIROpICmp || ![self tripCmpOK:g inAnd:NO] || [self blockOf:g.result.valueId] != T)
            continue;
        BOOL ult = g.predicate == XTIRICmpULT;
        if (!ult && g.predicate != XTIRICmpSLT)
            continue;
        XTIROperand* k = g.operands[0];
        int32_t n = 0, c0 = 0;
        if (k.kind != XTIROperandKindUse || ![self constOf:g.operands[1] into:&n])
            continue;
        XTIRInsn* p = nil;
        for (XTIRInsn* q in _T0.phiNodes)
            if (q.result.valueId == k.valueId)
                p = q;
        if (!p || ![self counterOf:p] || ![self constOf:escFrom(p, _B) into:&c0])
            continue;
        BOOL below = ult ? (uint32_t)c0 < (uint32_t)n : c0 < n;
        if (!below)
            continue;
        _tripTest = (NSInteger)t;
        _tripPhi = p;
        _tripN = ult ? (int64_t)(uint32_t)n : (int64_t)n;
        _tripC0 = ult ? (int64_t)(uint32_t)c0 : (int64_t)c0;
        _tripTy = p.result.type;
        _tripSigned = !ult;
        [_skip addObject:@(g.result.valueId)];
        if (_tripAnd)
            [_skip addObject:@(_tripAnd.result.valueId)];
        return;
        }
    }

// A compare the trip count can replace: two operands, read once, defined in
// the loop.
- (BOOL)tripCmpOK:(XTIRInsn*)g inAnd:(BOOL)inAnd
    {
    if (g.operands.count != 2 || [self uses:g.result.valueId] != 1)
        return NO;
    return !inAnd || [_region containsObject:@(g.result.valueId)];
    }

- (void)apply
    {
    _map = [NSMutableDictionary dictionary];
    _splat = [NSMutableDictionary dictionary];
    _exit = [NSMutableDictionary dictionary];
    _pre = [NSMutableArray array];
    _splatTo = _pre;
    _splatHome = _PH;
    _fresh = NO;
    _cse = [NSMutableDictionary dictionary];
    XTIRBlock* VH = [[XTIRBlock alloc] init];
    VH.name = xtvUniqueBlockName(_fn, [NSString stringWithFormat:@"%@_esc", _H.name ?: @""]);
    XTIRBlock* VB = [[XTIRBlock alloc] init];
    VB.name = xtvUniqueBlockName(_fn, [NSString stringWithFormat:@"%@_esc", _B.name ?: @""]);
    XTIRBlock* VI = [[XTIRBlock alloc] init];
    VI.name = xtvUniqueBlockName(_fn, [NSString stringWithFormat:@"%@_esc", _T0.name ?: @""]);
    XTIRBlock* VE = [[XTIRBlock alloc] init];
    VE.name = xtvUniqueBlockName(_fn, [NSString stringWithFormat:@"%@_esc", _E.name ?: @""]);
    XTIRBlock* VX = [[XTIRBlock alloc] init];
    VX.name = xtvUniqueBlockName(_fn, [NSString stringWithFormat:@"%@_escx", _H.name ?: @""]);
    XTIRValue* viv = [self newVal:_ivPhi.result.type home:VH];
    _viv = viv;
    _VB = VB;
    XTIRValue* vivNext = [self head:VH body:VB latch:VE exit:VX iv:viv];
    [self body:VB inner:VI iv:viv];
    [self innerLoop:VI exit:VE];
    [self latch:VE head:VH iv:viv next:vivNext];
    [self exitTo:VX iv:viv];
    [_PH.instructions addObjectsFromArray:_pre];
    [_PH.terminator replaceOperands:@[ [XTIROperand blockWithRef:VH] ]];
    NSUInteger at = [_fn.blocks indexOfObjectIdenticalTo:_PH];
    [_fn.blocks insertObjects:@[ VH, VB, VI, VE, VX ]
                    atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 5)]];
    }

- (XTIRValue*)head:(XTIRBlock*)VH body:(XTIRBlock*)VB latch:(XTIRBlock*)VE exit:(XTIRBlock*)VX iv:(XTIRValue*)viv
    {
    XTIRType* ivTy = _ivPhi.result.type;
    XTIRValue* vivNext = [self newVal:ivTy home:VE];
    [VH.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                     result:viv
                                                   operands:@[ [XTIROperand blockWithRef:_PH], escFrom(_ivPhi, _PH),
                                                               [XTIROperand blockWithRef:VE],
                                                               [XTIROperand useWithValueId:vivNext.valueId] ]
                                                     dbgLoc:nil]];
    _vsum = [NSMutableArray array];
    _vsumNext = [NSMutableArray array];
    for (XTIRInsn* acc in _accPhis)
        {
        XTIRType* t = acc.result.type;
        XTIRValue* vs = [self newVal:t home:VH];
        XTIRValue* vn = [self newVal:t home:VE];
        [VH.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:vs
                                                       operands:@[ [XTIROperand blockWithRef:_PH], escFrom(acc, _PH),
                                                                   [XTIROperand blockWithRef:VE],
                                                                   [XTIROperand useWithValueId:vn.valueId] ]
                                                         dbgLoc:nil]];
        [_vsum addObject:vs];
        [_vsumNext addObject:vn];
        }
    XTIRValue* c = nil;
    if (_boundConst)
        c = [self put:VH.instructions home:VH op:XTIROpICmp ty:[XTIRType boolType]
                    a:[XTIROperand useWithValueId:viv.valueId]
                    b:[XTIROperand immIWithType:ivTy value:_n - (int64_t)_vf]
                 pred:(_signed ? XTIRICmpSLE : XTIRICmpULE)];
    else
        {
        // A run-time bound: viv < N and N - viv >= VF (N - VF could wrap).
        XTIRType* b = [XTIRType boolType];
        XTIRValue* c1 = [self put:VH.instructions home:VH op:XTIROpICmp ty:b
                                a:[XTIROperand useWithValueId:viv.valueId] b:_boundOp
                             pred:(_signed ? XTIRICmpSLT : XTIRICmpULT)];
        XTIRValue* rem = [self put:VH.instructions home:VH op:XTIROpSub ty:ivTy a:_boundOp
                                 b:[XTIROperand useWithValueId:viv.valueId]];
        XTIRValue* c2 = [self put:VH.instructions home:VH op:XTIROpICmp ty:b
                                a:[XTIROperand useWithValueId:rem.valueId]
                                b:[XTIROperand immIWithType:ivTy value:(int64_t)_vf]
                             pred:(_signed ? XTIRICmpSGE : XTIRICmpUGE)];
        c = [self put:VH.instructions home:VH op:XTIROpAnd ty:b a:[XTIROperand useWithValueId:c1.valueId]
                    b:[XTIROperand useWithValueId:c2.valueId]];
        }
    [VH setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                result:nil
                                              operands:@[ [XTIROperand useWithValueId:c.valueId],
                                                          [XTIROperand blockWithRef:VB], [XTIROperand blockWithRef:VX] ]
                                                dbgLoc:nil]];
    return vivNext;
    }

- (void)body:(XTIRBlock*)VB inner:(XTIRBlock*)VI iv:(XTIRValue*)viv
    {
    XTIRType* ivTy = _ivPhi.result.type;
    XTIRType* vty = [self vecTy:ivTy];
    XTIRSymbolId nm = xtvIotaSymbol(ivTy, self.bytes, _fn);
    XTIRValue* ip = [self newVal:[XTIRType ptrToType:ivTy window:0] home:VB];
    [VB.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                                         result:ip
                                                       operands:@[ [XTIROperand symWithSymbolId:nm] ]
                                                         dbgLoc:nil]];
    XTIRValue* iota = [self put:VB.instructions home:VB op:XTIROpVLoad ty:vty
                              a:[XTIROperand useWithValueId:ip.valueId] b:nil];
    _splatTo = VB.instructions;
    _splatHome = VB;
    NSMutableDictionary* outer = _splat;
    _splat = [NSMutableDictionary dictionary];
    NSMutableArray* body = [NSMutableArray array];
    XTIRValue* s = [self put:body home:VB op:XTIROpVSplat ty:vty a:[XTIROperand useWithValueId:viv.valueId] b:nil];
    XTIRValue* lanes = [self put:body home:VB op:XTIROpVAdd ty:vty a:[XTIROperand useWithValueId:s.valueId]
                               b:[XTIROperand useWithValueId:iota.valueId]];
    _map[@(_ivPhi.result.valueId)] = @(lanes.valueId);
    for (XTIRInsn* n in _B.instructions)
        [self lane:body home:VB insn:n];
    [VB.instructions addObjectsFromArray:body];
    _splat = outer;
    [VB setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                result:nil
                                              operands:@[ [XTIROperand blockWithRef:VI] ]
                                                dbgLoc:nil]];
    }

- (void)innerLoop:(XTIRBlock*)VI exit:(XTIRBlock*)VE
    {
    XTIRType* mty = [self vecTy:[XTIRType boolType]];
    // COUNTED (no lane test): every lane makes every trip, so there is no mask,
    // no blend and no any-lane test; the trip count alone ends it.
    BOOL counted = _counted;
    _splatTo = _VB.instructions;
    _splatHome = _VB;
    _fresh = YES;
    XTIRValue* ones = nil;
    if (!counted)
        ones = [self splatOf:[XTIROperand immIWithType:[XTIRType i32Type] value:-1] scalar:[XTIRType i32Type]];
    NSMutableArray<XTIRInsn*>* kept = [NSMutableArray array];
    NSMutableArray<XTIRValue*>* phis = [NSMutableArray array];
    NSMutableArray<XTIRValue*>* nexts = [NSMutableArray array];
    for (XTIRInsn* p in _T0.phiNodes)
        {
        if ([_uniform containsObject:@(p.result.valueId)])
            continue;
        [kept addObject:p];
        [phis addObject:[self newVal:[self vecTy:p.result.type] home:VI]];
        if (!counted)
            [nexts addObject:[self newVal:[self vecTy:p.result.type] home:VI]];
        }
    NSMutableArray<XTIROperand*>* entries = [NSMutableArray array];
    NSMutableSet<NSNumber*>* taken = [NSMutableSet set];
    for (XTIRInsn* p in kept)
        {
        XTIROperand* ev = [self v:escFrom(p, _B) scalar:p.result.type];
        if ([taken containsObject:@(ev.valueId)])
            ev = [XTIROperand useWithValueId:[self put:_VB.instructions home:_VB op:XTIROpVOr
                                                    ty:[self vecTy:p.result.type] a:ev b:ev].valueId];
        [taken addObject:@(ev.valueId)];
        [entries addObject:ev];
        }
    _fresh = NO;
    _splatTo = _pre;
    _splatHome = _PH;
    for (NSUInteger i = 0; i < kept.count; i++)
        _map[@(kept[i].result.valueId)] = @(phis[i].valueId);
    XTIRValue* act = counted ? nil : [self newVal:mty home:VI];
    XTIRValue *trip = nil, *tripNext = nil;
    if (_tripTest >= 0)
        {
        trip = [self newVal:_tripTy home:VI];
        tripNext = [self newVal:_tripTy home:VI];
        }
    _tripV = trip;
    NSMutableArray<XTIRValue*>* backs = [NSMutableArray array];
    XTIRValue* actNext = [self innerBody:VI mask:mty act:act kept:kept phis:phis nexts:nexts backs:backs];
    for (NSUInteger i = 0; i < kept.count; i++)
        {
        XTIRValue* back = counted ? backs[i] : nexts[i];
        [VI.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:phis[i]
                                                       operands:@[ [XTIROperand blockWithRef:_VB], entries[i],
                                                                   [XTIROperand blockWithRef:VI],
                                                                   [XTIROperand useWithValueId:back.valueId] ]
                                                         dbgLoc:nil]];
        _exit[@(kept[i].result.valueId)] = @(back.valueId);
        }
    XTIRValue* c = nil;
    if (!counted)
        {
        [VI.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:act
                                                       operands:@[ [XTIROperand blockWithRef:_VB],
                                                                   [XTIROperand useWithValueId:ones.valueId],
                                                                   [XTIROperand blockWithRef:VI],
                                                                   [XTIROperand useWithValueId:actNext.valueId] ]
                                                         dbgLoc:nil]];
        // The reduction reads a copy of the mask: some back ends fold a
        // reduction in its operand's register, and the mask goes round again.
        XTIRValue* probe = [self put:VI.instructions home:VI op:XTIROpVAnd ty:mty
                                   a:[XTIROperand useWithValueId:actNext.valueId]
                                   b:[XTIROperand useWithValueId:actNext.valueId]];
        XTIRValue* any = [self put:VI.instructions home:VI op:XTIROpVReduceAdd ty:[XTIRType i32Type]
                                 a:[XTIROperand useWithValueId:probe.valueId] b:nil];
        c = [self put:VI.instructions home:VI op:XTIROpICmp ty:[XTIRType boolType]
                    a:[XTIROperand useWithValueId:any.valueId]
                    b:[XTIROperand immIWithType:[XTIRType i32Type] value:0]
                 pred:XTIRICmpNE];
        }
    if (trip)
        {
        [VI.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:trip
                                                       operands:@[ [XTIROperand blockWithRef:_VB],
                                                                   [XTIROperand immIWithType:_tripTy value:_tripC0],
                                                                   [XTIROperand blockWithRef:VI],
                                                                   [XTIROperand useWithValueId:tripNext.valueId] ]
                                                         dbgLoc:nil]];
        [VI.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                             result:tripNext
                                                           operands:@[ [XTIROperand useWithValueId:trip.valueId],
                                                                       [XTIROperand immIWithType:_tripTy value:1] ]
                                                             dbgLoc:nil]];
        XTIRValue* more = [self put:VI.instructions home:VI op:XTIROpICmp ty:[XTIRType boolType]
                                  a:[XTIROperand useWithValueId:tripNext.valueId]
                                  b:[XTIROperand immIWithType:_tripTy value:_tripN]
                               pred:(_tripSigned ? XTIRICmpSLT : XTIRICmpULT)];
        if (!c)
            c = more;
        else
            c = [self put:VI.instructions home:VI op:XTIROpAnd ty:[XTIRType boolType]
                        a:[XTIROperand useWithValueId:c.valueId] b:[XTIROperand useWithValueId:more.valueId]];
        }
    [VI setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                result:nil
                                              operands:@[ [XTIROperand useWithValueId:c.valueId],
                                                          [XTIROperand blockWithRef:VI], [XTIROperand blockWithRef:VE] ]
                                                dbgLoc:nil]];
    }

- (XTIRValue*)innerBody:(XTIRBlock*)VI mask:(XTIRType*)mty act:(XTIRValue*)act kept:(NSArray<XTIRInsn*>*)kept
                   phis:(NSArray<XTIRValue*>*)phis nexts:(NSArray<XTIRValue*>*)nexts
                  backs:(NSMutableArray<XTIRValue*>*)backs
    {
    NSMutableArray* into = VI.instructions;
    XTIRValue* live = act;
    for (NSUInteger t = 0; t < _tests.count; t++)
        {
        XTIRBlock* T = _tests[t];
        for (XTIRInsn* n in T.instructions)
            [self lane:into home:VI insn:n];
        if (_counted || _cont[t].intValue == 2)
            continue;   // counted, or passes on: no lane test
        XTIROperand* co = T.terminator.operands[0];
        XTIRValue* m = nil;
        if ((NSInteger)t == _tripTest)
            {
            if (!_tripOther)
                continue;
            m = _valOf[_map[@(_tripOther.valueId)]];
            }
        else
            m = _valOf[_map[@(co.valueId)]];
        if (_cont[t].intValue == 0)
            m = [self put:into home:VI op:XTIROpVNot ty:mty a:[XTIROperand useWithValueId:m.valueId] b:nil];
        live = [self put:into home:VI op:XTIROpVAnd ty:mty a:[XTIROperand useWithValueId:live.valueId]
                       b:[XTIROperand useWithValueId:m.valueId]];
        }
    for (XTIRInsn* n in _L.instructions)
        [self lane:into home:VI insn:n];
    for (NSUInteger i = 0; i < kept.count; i++)
        {
        XTIRInsn* p = kept[i];
        XTIRType* vty = [self vecTy:p.result.type];
        if ([self counterOf:p])
            {
            if (_counted)
                {
                XTIRValue* m1 = [self splatOf:[XTIROperand immIWithType:[XTIRType i32Type] value:-1]
                                       scalar:[XTIRType i32Type]];
                [backs addObject:[self put:into home:VI op:XTIROpVSub ty:vty
                                         a:[XTIROperand useWithValueId:phis[i].valueId]
                                         b:[XTIROperand useWithValueId:m1.valueId]]];
                continue;
                }
            [into addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSub
                                                      result:nexts[i]
                                                    operands:@[ [XTIROperand useWithValueId:phis[i].valueId],
                                                                [XTIROperand useWithValueId:live.valueId] ]
                                                      dbgLoc:nil]];
            continue;
            }
        XTIRValue* nv = _valOf[@([self v:escFrom(p, _L) scalar:p.result.type].valueId)];
        if (_counted)
            {
            [backs addObject:nv];
            continue;
            }
        XTIRValue* old = phis[i];
        XTIRValue* d = [self put:into home:VI op:XTIROpVXor ty:vty a:[XTIROperand useWithValueId:nv.valueId]
                               b:[XTIROperand useWithValueId:old.valueId]];
        XTIRValue* e = [self put:into home:VI op:XTIROpVAnd ty:vty a:[XTIROperand useWithValueId:d.valueId]
                               b:[XTIROperand useWithValueId:live.valueId]];
        [into addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVXor
                                                  result:nexts[i]
                                                operands:@[ [XTIROperand useWithValueId:old.valueId],
                                                            [XTIROperand useWithValueId:e.valueId] ]
                                                  dbgLoc:nil]];
        }
    return live;
    }

- (void)latch:(XTIRBlock*)VE head:(XTIRBlock*)VH iv:(XTIRValue*)viv next:(XTIRValue*)vivNext
    {
    for (XTIRInsn* p in _T0.phiNodes)
        if (_exit[@(p.result.valueId)])
            _map[@(p.result.valueId)] = _exit[@(p.result.valueId)];
    // E's own lane work (nbody's `ax > 0`).
    for (XTIRInsn* n in _eLane)
        [self lane:VE.instructions home:VE insn:n];
    for (NSUInteger i = 0; i < _accPhis.count; i++)
        {
        XTIRType* t = _accPhis[i].result.type;
        XTIROperand* w = [self v:_accW[i] scalar:t];
        // `s = c ? s + w : s`: w where c, else 0.
        NSUInteger kind = _accKind[i].unsignedIntegerValue;
        if (kind != 0)
            {
            XTIROperand* co = _accCond[i];
            XTIRValue* m = _valOf[_map[@(co.valueId)]];
            if (kind == 2)
                m = [self put:VE.instructions home:VE op:XTIROpVNot ty:[self vecTy:[XTIRType boolType]]
                            a:[XTIROperand useWithValueId:m.valueId] b:nil];
            w = [XTIROperand useWithValueId:[self put:VE.instructions home:VE op:XTIROpVAnd ty:[self vecTy:t]
                                                    a:w b:[XTIROperand useWithValueId:m.valueId]].valueId];
            }
        // The reduction folds in its operand's register on some back ends: it
        // reads a copy.
        XTIRValue* cp = [self put:VE.instructions home:VE op:XTIROpVOr ty:[self vecTy:t] a:w b:w];
        XTIRValue* r = [self put:VE.instructions home:VE op:XTIROpVReduceAdd ty:t
                               a:[XTIROperand useWithValueId:cp.valueId] b:nil];
        [VE.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                             result:_vsumNext[i]
                                                           operands:@[ [XTIROperand useWithValueId:_vsum[i].valueId],
                                                                       [XTIROperand useWithValueId:r.valueId] ]
                                                             dbgLoc:nil]];
        }
    if (_store)
        {
        // a[viv .. viv+VF-1] = the lanes, one vector store.
        XTIROperand* sv = _store.operands[1];
        XTIROperand* vv = [self v:sv scalar:_valOf[@(sv.valueId)].type];
        XTIRValue* av = [self newVal:_storeAddr.result.type home:VE];
        [VE.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                             result:av
                                                           operands:@[ _storeAddr.operands[0],
                                                                       [XTIROperand useWithValueId:viv.valueId] ]
                                                             dbgLoc:nil]];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithObjects:[XTIROperand useWithValueId:av.valueId], vv, nil];
        for (NSUInteger q = 2; q < _store.operands.count; q++)
            [ops addObject:_store.operands[q]];
        XTIRInsn* vs = [[XTIRInsn alloc] initWithOpcode:XTIROpVStore result:nil operands:ops dbgLoc:_store.dbgLoc];
        if (_store.memoryResult)
            vs.memoryResult = [self newVal:[XTIRType memoryType] home:VE];
        [VE.instructions addObject:vs];
        }
    [VE.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                         result:vivNext
                                                       operands:@[ [XTIROperand useWithValueId:viv.valueId],
                                                                   [XTIROperand immIWithType:viv.type value:(int64_t)_vf] ]
                                                         dbgLoc:nil]];
    [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                result:nil
                                              operands:@[ [XTIROperand blockWithRef:VH] ]
                                                dbgLoc:nil]];
    }

- (void)exitTo:(XTIRBlock*)VX iv:(XTIRValue*)viv
    {
    for (NSUInteger i = 0; i < _accPhis.count; i++)
        [self reenter:_accPhis[i] from:VX with:[XTIROperand useWithValueId:_vsum[i].valueId]];
    [self reenter:_ivPhi from:VX with:[XTIROperand useWithValueId:viv.valueId]];
    for (XTIRInsn* p in _passPhis)
        [self reenter:p from:VX with:escFrom(p, _PH)];
    [VX setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                result:nil
                                              operands:@[ [XTIROperand blockWithRef:_H] ]
                                                dbgLoc:nil]];
    }

- (void)reenter:(XTIRInsn*)p from:(XTIRBlock*)VX with:(XTIROperand*)v
    {
    NSMutableArray<XTIROperand*>* ops = [p.operands mutableCopy];
    for (NSUInteger q = 0; q + 1 < ops.count; q += 2)
        if (ops[q].blockRef == _PH)
            {
            ops[q] = [XTIROperand blockWithRef:VX];
            ops[q + 1] = v;
            }
    [p replaceOperands:ops];
    }

@end
