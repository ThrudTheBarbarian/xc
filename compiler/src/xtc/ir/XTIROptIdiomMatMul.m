#import "XTIROptIdiomMatMul.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

// One recognised nest. Operands are kept as the IR has them (a value or an
// integer immediate) and materialised in the preheader when rewritten.
@interface XTMatMulCand : NSObject
@property(nonatomic) XTIRBlock* preheader; // Pi: branches to Hi
@property(nonatomic) XTIRBlock* header;    // Hi
@property(nonatomic) XTIRBlock* exit;      // Ei
@property(nonatomic) BOOL f64;
@property(nonatomic) XTIROperand* M;
@property(nonatomic) XTIROperand* N;
@property(nonatomic) XTIROperand* K;
@property(nonatomic) XTIROperand* lda;
@property(nonatomic) XTIROperand* ldb;
@property(nonatomic) XTIROperand* ldc;
@property(nonatomic) XTIROperand* A;
@property(nonatomic) XTIROperand* B;
@property(nonatomic) XTIROperand* C;
@property(nonatomic) XTIRValueId memIn;
// The constant value of each of M, N, K, lda, ldb, ldc, or -1 (a value).
@property(nonatomic, copy) NSArray<NSNumber*>* consts;
@end
@implementation XTMatMulCand
@end

// The value/def tables recognise reads.
@interface XTMatMulDefs : NSObject
@property(nonatomic) NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf;
@property(nonatomic) NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk;
@end
@implementation XTMatMulDefs
@end

@implementation XTIROptIdiomMatMul

- (NSString*)passName
    {
    return @"idiom-matmul";
    }

- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    if (!self.profile || !self.profile.matMulPrefix)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        {
        // Each rewrite leaves the nest in place behind the call, so a nest
        // that has been given its call is skipped by the preheader check
        // (its preheader no longer ends in a plain Branch).
        for (NSUInteger iter = 0; iter < 64; iter++)
            {
            XTMatMulCand* c = [self recognise:fn];
            if (!c)
                break;
            [self apply:c inFunction:fn module:mod];
            }
        }
    return YES;
    }

#pragma mark - Matching helpers

static BOOL isUse(XTIROperand* o, XTIRValueId v)
    {
    return o.kind == XTIROperandKindUse && o.valueId == v;
    }

// Integer constant value of an operand: an ImmI, or a Use of `Const ImmI`,
// seen through ZExt (lowering spells `(u32)0` as ZExt(Const #0:U8)).
static BOOL intConst(XTIROperand* o, XTMatMulDefs* d, int64_t* out)
    {
    if (o.kind == XTIROperandKindImmI)
        {
        *out = o.intValue;
        return YES;
        }
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* def = d.defOf[@(o.valueId)];
    if (!def || def.operands.count < 1)
        return NO;
    if (def.opcode == XTIROpConst && def.operands[0].kind == XTIROperandKindImmI)
        {
        *out = def.operands[0].intValue;
        return YES;
        }
    if (def.opcode == XTIROpZExt)
        {
        int64_t v;
        if (intConst(def.operands[0], d, &v) && v >= 0)
            {
            *out = v;
            return YES;
            }
        }
    return NO;
    }

// A use of `Const +0.0` of the given float type.
static BOOL isPlusZero(XTIROperand* o, XTMatMulDefs* d, XTIRTypeKind fk)
    {
    if (o.kind == XTIROperandKindImmF)
        return o.floatRawBytes == 0;
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* def = d.defOf[@(o.valueId)];
    return def && def.opcode == XTIROpConst && def.result.type.kind == fk && def.operands.count == 1 &&
           def.operands[0].kind == XTIROperandKindImmF && def.operands[0].floatRawBytes == 0;
    }

// The defining insn of a Use operand, when it has the given opcode.
static XTIRInsn* defWith(XTIROperand* o, XTIROpcode op, XTMatMulDefs* d)
    {
    if (o.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* def = d.defOf[@(o.valueId)];
    return (def && def.opcode == op) ? def : nil;
    }

// Phi incoming from block b (operands alternate block, value).
static XTIROperand* incoming(XTIRInsn* phi, XTIRBlock* b)
    {
    for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2)
        if (phi.operands[i].blockRef == b)
            return phi.operands[i + 1];
    return nil;
    }

// `x + 1` where x is the given value.
static BOOL isIncOf(XTIROperand* o, XTIRValueId x, XTMatMulDefs* d)
    {
    XTIRInsn* add = defWith(o, XTIROpAdd, d);
    if (!add || add.operands.count != 2)
        return NO;
    int64_t one;
    if (isUse(add.operands[0], x) && intConst(add.operands[1], d, &one) && one == 1)
        return YES;
    if (isUse(add.operands[1], x) && intConst(add.operands[0], d, &one) && one == 1)
        return YES;
    return NO;
    }

// index = Add(Mul(p, q), r) in any operand order. Returns the Mul and the
// addend; the caller decides which Mul operand is which.
static BOOL splitIndex(XTIROperand* idx, XTMatMulDefs* d, XTIRInsn** mulOut, XTIROperand** addendOut)
    {
    XTIRInsn* add = defWith(idx, XTIROpAdd, d);
    if (!add || add.operands.count != 2)
        return NO;
    XTIRInsn* m0 = defWith(add.operands[0], XTIROpMul, d);
    XTIRInsn* m1 = defWith(add.operands[1], XTIROpMul, d);
    if (m0 && m0.operands.count == 2)
        {
        *mulOut = m0;
        *addendOut = add.operands[1];
        return YES;
        }
    if (m1 && m1.operands.count == 2)
        {
        *mulOut = m1;
        *addendOut = add.operands[0];
        return YES;
        }
    return NO;
    }

// Mul(v, other) in either order: the operand that is not v, or nil.
static XTIROperand* mulOther(XTIRInsn* mul, XTIRValueId v)
    {
    if (isUse(mul.operands[0], v) && !isUse(mul.operands[1], v))
        return mul.operands[1];
    if (isUse(mul.operands[1], v) && !isUse(mul.operands[0], v))
        return mul.operands[0];
    return nil;
    }

// A counted loop header: one integer phi (plus `extra` more phis), guard
// `ICmp ULT iv, bound` as the only instruction, CondBranch guard, body, exit.
// Fills the iv phi, the bound operand, the body and exit blocks, and the
// preheader (the phi's non-latch incoming block, whose init must be 0).
static BOOL countedHeader(XTIRBlock* H, NSUInteger extraPhis, XTIRBlock* latch, XTMatMulDefs* d,
                          XTIRInsn** ivOut, XTIROperand** boundOut, XTIRBlock** bodyOut,
                          XTIRBlock** exitOut, XTIRBlock** preOut)
    {
    if (H.phiNodes.count != 1 + extraPhis || H.instructions.count < 1)
        return NO;
    // The guard is the last instruction; anything before it is a constant
    // (a literal bound is materialised in the header: Const, ZExt).
    XTIRInsn* guard = H.instructions.lastObject;
    for (XTIRInsn* insn in H.instructions)
        {
        if (insn == guard)
            continue;
        int64_t v;
        if (insn.memoryResult || !insn.result)
            return NO;
        if (!(insn.opcode == XTIROpConst && insn.operands.count == 1 && insn.operands[0].kind == XTIROperandKindImmI) &&
            !(insn.opcode == XTIROpZExt && intConst(insn.operands[0], d, &v)))
            return NO;
        }
    XTIRInsn* t = H.terminator;
    if (guard.opcode != XTIROpICmp || guard.predicate != XTIRICmpULT || guard.operands.count != 2 || !guard.result)
        return NO;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count != 3 || !isUse(t.operands[0], guard.result.valueId))
        return NO;
    XTIRInsn* iv = nil;
    for (XTIRInsn* phi in H.phiNodes)
        if (phi.result && isUse(guard.operands[0], phi.result.valueId))
            iv = phi;
    if (!iv || iv.result.type.kind != XTIRTypeKindU32 || iv.operands.count != 4)
        return NO;
    XTIRBlock* body = t.operands[1].blockRef;
    XTIRBlock* exitB = t.operands[2].blockRef;
    if (!body || !exitB || body == H || exitB == H)
        return NO;
    // Exactly two incomings: the latch and the preheader.
    XTIRBlock* pre = nil;
    for (NSUInteger i = 0; i < 4; i += 2)
        if (iv.operands[i].blockRef != latch)
            pre = iv.operands[i].blockRef;
    if (!pre || !incoming(iv, latch))
        return NO;
    int64_t init;
    if (!intConst(incoming(iv, pre), d, &init) || init != 0)
        return NO;
    if (!isIncOf(incoming(iv, latch), iv.result.valueId, d))
        return NO;
    *ivOut = iv;
    *boundOut = guard.operands[1];
    *bodyOut = body;
    *exitOut = exitB;
    *preOut = pre;
    return YES;
    }

// The successors named by a block's terminator.
static NSArray<XTIRBlock*>* succs(XTIRBlock* b)
    {
    NSMutableArray* out = [NSMutableArray array];
    for (XTIROperand* o in b.terminator.operands)
        if (o.kind == XTIROperandKindBlock && o.blockRef)
            [out addObject:o.blockRef];
    return out;
    }

// A block whose terminator is `Branch to`.
static BOOL branchesTo(XTIRBlock* b, XTIRBlock* to)
    {
    XTIRInsn* t = b.terminator;
    return t && t.opcode == XTIROpBranch && t.operands.count == 1 && t.operands[0].blockRef == to;
    }

// Every instruction in b is a Const or a ZExt of a constant (loop inits),
// apart from the ones listed.
static BOOL onlyConstsBesides(XTIRBlock* b, NSArray<XTIRInsn*>* allowed, XTMatMulDefs* d)
    {
    for (XTIRInsn* insn in b.instructions)
        {
        if ([allowed indexOfObjectIdenticalTo:insn] != NSNotFound)
            continue;
        if (insn.opcode == XTIROpConst && !insn.memoryResult)
            continue;
        int64_t v;
        if (insn.opcode == XTIROpZExt && !insn.memoryResult && intConst(insn.operands[0], d, &v))
            continue;
        return NO;
        }
    return YES;
    }

#pragma mark - Recognition

- (nullable XTMatMulCand*)recognise:(XTIRFunction*)fn
    {
    XTMatMulDefs* d = [XTMatMulDefs new];
    d.defOf = [NSMutableDictionary dictionary];
    d.defBlk = [NSMutableDictionary dictionary];
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* predsOf =
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                              valueOptions:NSPointerFunctionsStrongMemory];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                d.defOf[@(insn.result.valueId)] = insn;
                d.defBlk[@(insn.result.valueId)] = bb;
                }
            if (insn.memoryResult)
                {
                d.defOf[@(insn.memoryResult.valueId)] = insn;
                d.defBlk[@(insn.memoryResult.valueId)] = bb;
                }
            }
        for (XTIRBlock* s in succs(bb))
            {
            NSMutableArray* ps = [predsOf objectForKey:s];
            if (!ps)
                {
                ps = [NSMutableArray array];
                [predsOf setObject:ps forKey:s];
                }
            if (ps.lastObject != bb) // once per predecessor, however many edges
                [ps addObject:bb];
            }
        }
    NSArray<XTIRBlock*>* (^preds)(XTIRBlock*) = ^NSArray<XTIRBlock*>*(XTIRBlock* b) {
      return [predsOf objectForKey:b] ?: @[];
    };
    // A U32 operand: an immediate in range, or a value whose type is U32.
    BOOL (^u32Op)(XTIROperand*) = ^BOOL(XTIROperand* o) {
      int64_t v;
      if (intConst(o, d, &v))
          return v >= 0 && v <= 0xFFFFFFFFLL;
      return o.kind == XTIROperandKindUse && fn.values[@(o.valueId)].type.kind == XTIRTypeKindU32;
    };

    for (XTIRBlock* Hk in fn.blocks)
        {
        // ── innermost: k loop with the accumulator phi ──
        if (Hk.phiNodes.count != 2)
            continue;
        // the latch is the block that loops back; find it from the phis
        XTIRBlock* Bk = nil;
        for (XTIRBlock* p in preds(Hk))
            if (branchesTo(p, Hk) && p != Hk && [succs(p) count] == 1)
                {
                // body: its single successor is Hk and Hk's CondBranch names it
                XTIRInsn* t = Hk.terminator;
                if (t && t.opcode == XTIROpCondBranch && t.operands.count == 3 && t.operands[1].blockRef == p)
                    Bk = p;
                }
        if (!Bk)
            continue;
        XTIRInsn* kPhi;
        XTIROperand* K;
        XTIRBlock *bodyK, *Ek, *Pk;
        if (!countedHeader(Hk, 1, Bk, d, &kPhi, &K, &bodyK, &Ek, &Pk) || bodyK != Bk)
            continue;
        if (preds(Hk).count != 2 || preds(Ek).count != 1 || Ek.phiNodes.count != 0 || Bk.phiNodes.count != 0)
            continue;
        XTIRInsn* sPhi = (Hk.phiNodes[0] == kPhi) ? Hk.phiNodes[1] : Hk.phiNodes[0];
        if (!sPhi.result || sPhi.operands.count != 4)
            continue;
        XTIRTypeKind fk = sPhi.result.type.kind;
        if (fk != XTIRTypeKindF32 && fk != XTIRTypeKindF64)
            continue;
        if (!incoming(sPhi, Pk) || !incoming(sPhi, Bk) || !isPlusZero(incoming(sPhi, Pk), d, fk))
            continue;
        // s' = FAdd(s, FMul(x, y)) in either order, in Bk
        XTIRInsn* fadd = defWith(incoming(sPhi, Bk), XTIROpFAdd, d);
        if (!fadd || fadd.operands.count != 2 || d.defBlk[@(fadd.result.valueId)] != Bk)
            continue;
        XTIROperand* prodOp = isUse(fadd.operands[0], sPhi.result.valueId)   ? fadd.operands[1]
                              : isUse(fadd.operands[1], sPhi.result.valueId) ? fadd.operands[0]
                                                                             : nil;
        XTIRInsn* fmul = prodOp ? defWith(prodOp, XTIROpFMul, d) : nil;
        if (!fmul || fmul.operands.count != 2 || d.defBlk[@(fmul.result.valueId)] != Bk)
            continue;
        XTIRInsn* l0 = defWith(fmul.operands[0], XTIROpLoad, d);
        XTIRInsn* l1 = defWith(fmul.operands[1], XTIROpLoad, d);
        if (!l0 || !l1 || l0 == l1 || d.defBlk[@(l0.result.valueId)] != Bk || d.defBlk[@(l1.result.valueId)] != Bk)
            continue;
        if (l0.result.type.kind != fk || l1.result.type.kind != fk)
            continue;
        XTIRInsn* ea0 = defWith(l0.operands[0], XTIROpElementAddr, d);
        XTIRInsn* ea1 = defWith(l1.operands[0], XTIROpElementAddr, d);
        if (!ea0 || !ea1 || ea0.operands.count != 2 || ea1.operands.count != 2)
            continue;
        // A-like: index = Mul(row, lda) + k.  B-like: index = Mul(k, ldb) + col.
        XTIRValueId kv = kPhi.result.valueId;
        XTIRInsn *mul0, *mul1;
        XTIROperand *add0, *add1;
        if (!splitIndex(ea0.operands[1], d, &mul0, &add0) || !splitIndex(ea1.operands[1], d, &mul1, &add1))
            continue;
        XTIRInsn *eaA, *eaB, *mulA, *mulB, *loadA, *loadB;
        XTIROperand* bCol;
        if (isUse(add0, kv) && mulOther(mul1, kv) && !isUse(add1, kv))
            {
            eaA = ea0, mulA = mul0, loadA = l0;
            eaB = ea1, mulB = mul1, loadB = l1, bCol = add1;
            }
        else if (isUse(add1, kv) && mulOther(mul0, kv) && !isUse(add0, kv))
            {
            eaA = ea1, mulA = mul1, loadA = l1;
            eaB = ea0, mulB = mul0, loadB = l0, bCol = add0;
            }
        else
            continue;
        XTIROperand* ldb = mulOther(mulB, kv);
        // Bk holds exactly: the two loads, their ElementAddrs, the products and
        // the k increment, plus index arithmetic and constants (nothing that
        // writes memory or calls).
        BOOL bkClean = YES;
        for (XTIRInsn* insn in Bk.instructions)
            {
            if (insn == loadA || insn == loadB)
                continue;
            if (insn.memoryResult)
                {
                bkClean = NO;
                break;
                }
            switch (insn.opcode)
                {
            case XTIROpConst:
            case XTIROpZExt:
            case XTIROpAdd:
            case XTIROpMul:
            case XTIROpElementAddr:
            case XTIROpFMul:
            case XTIROpFAdd:
                break;
            default:
                bkClean = NO;
                break;
                }
            if (!bkClean)
                break;
            }
        if (!bkClean || !branchesTo(Bk, Hk))
            continue;
        // Ek: Store s to C[Mul(row, ldc) + col]; then the j increment; Branch Hj.
        XTIRInsn* store = nil;
        for (XTIRInsn* insn in Ek.instructions)
            if (insn.opcode == XTIROpStore)
                {
                if (store)
                    {
                    store = nil;
                    break;
                    }
                store = insn;
                }
        if (!store || store.operands.count != 3 || !isUse(store.operands[1], sPhi.result.valueId))
            continue;
        XTIRInsn* eaC = defWith(store.operands[0], XTIROpElementAddr, d);
        XTIRInsn* mulC;
        XTIROperand* cCol;
        if (!eaC || eaC.operands.count != 2 || !splitIndex(eaC.operands[1], d, &mulC, &cCol))
            continue;
        XTIRBlock* Hj = succs(Ek).count == 1 ? succs(Ek)[0] : nil;
        if (!Hj || !branchesTo(Ek, Hj))
            continue;
        // Everything else in Ek is index arithmetic / constants / the j increment.
        BOOL ekClean = YES;
        for (XTIRInsn* insn in Ek.instructions)
            {
            if (insn == store)
                continue;
            if (insn.memoryResult ||
                !(insn.opcode == XTIROpConst || insn.opcode == XTIROpZExt || insn.opcode == XTIROpAdd ||
                  insn.opcode == XTIROpMul || insn.opcode == XTIROpElementAddr))
                {
                ekClean = NO;
                break;
                }
            }
        if (!ekClean)
            continue;

        // ── middle: j loop ──
        XTIRInsn* jPhi;
        XTIROperand* N;
        XTIRBlock *Bj, *Ej, *Pj;
        if (!countedHeader(Hj, 0, Ek, d, &jPhi, &N, &Bj, &Ej, &Pj))
            continue;
        if (Bj != Pk || !branchesTo(Bj, Hk) || Bj.phiNodes.count != 0 || preds(Bj).count != 1 ||
            preds(Hj).count != 2 || preds(Ej).count != 1 || Ej.phiNodes.count != 0)
            continue;
        if (!onlyConstsBesides(Bj, @[], d))
            continue;
        if (!isUse(bCol, jPhi.result.valueId) || !isUse(cCol, jPhi.result.valueId))
            continue;

        // ── outer: i loop ──
        XTIRBlock* Hi = succs(Ej).count == 1 ? succs(Ej)[0] : nil;
        if (!Hi || !branchesTo(Ej, Hi))
            continue;
        XTIRInsn* iPhi;
        XTIROperand* M;
        XTIRBlock *Bi, *Ei, *Pi;
        if (!countedHeader(Hi, 0, Ej, d, &iPhi, &M, &Bi, &Ei, &Pi))
            continue;
        if (Bi != Pj || !branchesTo(Bi, Hj) || Bi.phiNodes.count != 0 || preds(Bi).count != 1 ||
            preds(Hi).count != 2 || preds(Ei).count != 1 || Ei.phiNodes.count != 0)
            continue;
        if (!onlyConstsBesides(Bi, @[], d) || !branchesTo(Pi, Hi) || Pi == Hi)
            continue;
        // Ej: only the i increment (and constants).
        BOOL ejClean = YES;
        for (XTIRInsn* insn in Ej.instructions)
            if (insn.memoryResult || !(insn.opcode == XTIROpConst || insn.opcode == XTIROpZExt || insn.opcode == XTIROpAdd))
                ejClean = NO;
        if (!ejClean)
            continue;
        XTIRValueId iv = iPhi.result.valueId;
        XTIROperand* lda = mulOther(mulA, iv);
        XTIROperand* ldc = mulOther(mulC, iv);
        if (!lda || !ldc || !ldb)
            continue;

        // ── invariance: every input is defined outside the nest ──
        NSArray<XTIRBlock*>* nest = @[ Hi, Bi, Hj, Bj, Hk, Bk, Ek, Ej ];
        BOOL (^outside)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          int64_t v;
          if (intConst(o, d, &v))
              return YES; // a constant is invariant wherever it is spelled
          if (o.kind != XTIROperandKindUse)
              return NO;
          XTIRBlock* b = d.defBlk[@(o.valueId)];
          return !b || [nest indexOfObjectIdenticalTo:b] == NSNotFound;
        };
        XTIROperand *Aop = eaA.operands[0], *Bop = eaB.operands[0], *Cop = eaC.operands[0];
        NSArray<XTIROperand*>* inputs = @[ M, N, K, lda, ldb, ldc, Aop, Bop, Cop ];
        BOOL inv = YES;
        for (XTIROperand* o in inputs)
            if (!outside(o))
                inv = NO;
        if (!inv)
            continue;
        BOOL u32s = YES;
        for (XTIROperand* o in @[ M, N, K, lda, ldb, ldc ])
            if (!u32Op(o))
                u32s = NO;
        if (!u32s)
            continue;
        // The three bases point at the element type.
        BOOL ptrs = YES;
        for (XTIRInsn* ea in @[ eaA, eaB, eaC ])
            if (ea.result.type.kind != XTIRTypeKindPtr || ea.result.type.pointeeType.kind != fk)
                ptrs = NO;
        if (!ptrs)
            continue;

        // ── no value made in the nest is read outside it (memory aside) ──
        NSMutableSet<NSNumber*>* made = [NSMutableSet set];
        for (XTIRBlock* b in nest)
            {
            for (XTIRInsn* insn in b.phiNodes)
                if (insn.result)
                    [made addObject:@(insn.result.valueId)];
            for (XTIRInsn* insn in b.instructions)
                if (insn.result)
                    [made addObject:@(insn.result.valueId)];
            }
        BOOL escapes = NO;
        for (XTIRBlock* b in fn.blocks)
            {
            if ([nest indexOfObjectIdenticalTo:b] != NSNotFound)
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
            [all addObjectsFromArray:b.instructions];
            if (b.terminator)
                [all addObject:b.terminator];
            for (XTIRInsn* insn in all)
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse && [made containsObject:@(o.valueId)])
                        escapes = YES;
            }
        if (escapes)
            continue;

        XTMatMulCand* c = [XTMatMulCand new];
        c.preheader = Pi;
        c.header = Hi;
        c.exit = Ei;
        c.f64 = (fk == XTIRTypeKindF64);
        c.M = M, c.N = N, c.K = K;
        c.lda = lda, c.ldb = ldb, c.ldc = ldc;
        c.A = Aop, c.B = Bop, c.C = Cop;
        NSMutableArray<NSNumber*>* cv = [NSMutableArray array];
        for (XTIROperand* o in @[ M, N, K, lda, ldb, ldc ])
            {
            int64_t v;
            [cv addObject:@(intConst(o, d, &v) ? v : -1)];
            }
        c.consts = cv;
        // The memory state on entry: the last memory result in the preheader,
        // else what the A load reads.
        BOOL haveMem = loadA.operands.count > 1 && loadA.operands[1].kind == XTIROperandKindUse;
        XTIRValueId mem = haveMem ? loadA.operands[1].valueId : 0;
        for (XTIRInsn* insn in Pi.instructions)
            if (insn.memoryResult)
                {
                mem = insn.memoryResult.valueId;
                haveMem = YES;
                }
        if (!haveMem)
            continue;
        c.memIn = mem;
        return c;
        }
    return nil;
    }

#pragma mark - Rewrite

- (XTIRValueId)value:(XTIRType*)ty in:(XTIRBlock*)P fn:(XTIRFunction*)fn
                  op:(XTIROpcode)op operands:(NSArray<XTIROperand*>*)ops
    {
    XTIRValueId rid = [fn allocateValueId];
    XTIRValue* res = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:P insnIndex:P.instructions.count]];
    [fn registerValue:res];
    [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:op result:res operands:ops dbgLoc:nil]];
    return rid;
    }

// A U32 operand as a value in P: a constant (an immediate, or a Const however
// it is spelled and wherever it is defined) becomes a fresh `Const #v:U32`
// here; any other value is used as it is.
- (XTIROperand*)u32Value:(XTIROperand*)o konst:(NSNumber*)k in:(XTIRBlock*)P fn:(XTIRFunction*)fn
    {
    if (k.longLongValue < 0)
        return o;
    XTIRType* u32 = [XTIRType u32Type];
    return [XTIROperand useWithValueId:[self value:u32 in:P fn:fn op:XTIROpConst
                                          operands:@[ [XTIROperand immIWithType:u32 value:k.longLongValue] ]]];
    }

- (void)apply:(XTMatMulCand*)c inFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    XTIRBlock* P = c.preheader;
    XTIRType* u64 = [XTIRType u64Type];
    NSString* name = [NSString stringWithFormat:@"%@%@%@", self.profile.matMulPrefix, c.f64 ? @"f64" : @"f32",
                                                 self.profile.matMulSuffix ?: @""];
    // Under `:goal(speed)` (the i loop's header was lowered as one), the
    // target's kernel that may skip its exactness check, where it has one:
    // arm64's skips the NaN check of C (only NaN payloads can differ).
    if (self.profile.matMulFastSuffix && c.header.name && [fn.speedLoopHeaders containsObject:c.header.name])
        name = [name stringByAppendingString:self.profile.matMulFastSuffix];
    XTIRSymbol* sym = [mod symbolForName:name];
    if (!sym)
        {
        sym = [XTIRSymbol runtimeHelperWithName:name
                                     clobberSet:[[XTIRClobberSet alloc] initWithClobberedNames:@[]]
                                       mayAlloc:NO
                                       mayThrow:NO];
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO, @"variadic" : @NO};
        [mod addSymbol:sym];
        }
    XTIRSymbolId sid = [mod.symbols indexOfObjectIdenticalTo:sym];

    // M | N << 32 as one U64.
    XTIROperand* M = [self u32Value:c.M konst:c.consts[0] in:P fn:fn];
    XTIROperand* N = [self u32Value:c.N konst:c.consts[1] in:P fn:fn];
    XTIRValueId zm = [self value:u64 in:P fn:fn op:XTIROpZExt operands:@[ M ]];
    XTIRValueId zn = [self value:u64 in:P fn:fn op:XTIROpZExt operands:@[ N ]];
    XTIRValueId sh = [self value:u64 in:P fn:fn op:XTIROpShl
                        operands:@[ [XTIROperand useWithValueId:zn], [XTIROperand immIWithType:u64 value:32] ]];
    XTIRValueId mn = [self value:u64 in:P fn:fn op:XTIROpOr
                        operands:@[ [XTIROperand useWithValueId:zm], [XTIROperand useWithValueId:sh] ]];
    // One at a time, in this order: value ids are allocated as they are made,
    // and the port has to make them in the same order.
    XTIROperand* K = [self u32Value:c.K konst:c.consts[2] in:P fn:fn];
    XTIROperand* lda = [self u32Value:c.lda konst:c.consts[3] in:P fn:fn];
    XTIROperand* ldb = [self u32Value:c.ldb konst:c.consts[4] in:P fn:fn];
    XTIROperand* ldc = [self u32Value:c.ldc konst:c.consts[5] in:P fn:fn];
    NSArray<XTIROperand*>* args = @[
        [XTIROperand symWithSymbolId:sid], c.A, c.B, c.C, [XTIROperand useWithValueId:mn], K, lda, ldb, ldc,
        [XTIROperand useWithValueId:c.memIn]
    ];
    XTIRValueId doneId = [fn allocateValueId];
    XTIRValue* done = [[XTIRValue alloc] initWithValueId:doneId
                                                    type:[XTIRType boolType]
                                                 defSite:[[XTIRDefSite alloc] initWithBlock:P insnIndex:P.instructions.count]];
    [fn registerValue:done];
    XTIRValueId memId = [fn allocateValueId];
    XTIRValue* memRes = [[XTIRValue alloc] initWithValueId:memId
                                                      type:[XTIRType memoryType]
                                                   defSite:[[XTIRDefSite alloc] initWithBlock:P insnIndex:P.instructions.count]];
    [fn registerValue:memRes];
    XTIRInsn* call = [[XTIRInsn alloc] initWithOpcode:XTIROpCall
                                               result:done
                                             operands:args
                                             callConv:[XTIRCallConv standard]
                                               dbgLoc:nil];
    call.memoryResult = memRes;
    [P.instructions addObject:call];

    // Branch to the nest's exit when the kernel did the work, else into the nest.
    XTIRInsn* br = [[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                             result:nil
                                           operands:@[ [XTIROperand useWithValueId:doneId], [XTIROperand blockWithRef:c.exit],
                                                       [XTIROperand blockWithRef:c.header] ]
                                             dbgLoc:nil];
    [P resetTerminator];
    [P setTerminator:br];
    }

@end
