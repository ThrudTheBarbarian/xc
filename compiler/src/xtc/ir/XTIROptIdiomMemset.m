#import "XTIROptIdiomMemset.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSupport.h"

// A recognised byte-fill loop.
@interface XTMemsetCand : NSObject
@property(nonatomic) XTIRBlock* header;    // H: induction phi + guard
@property(nonatomic) XTIRBlock* body;      // B: the single-block fill body
@property(nonatomic) XTIRBlock* exit;      // E: loop exit
@property(nonatomic) XTIRBlock* preheader; // P: the non-body phi incoming
@property(nonatomic) XTIRInsn* store;      // the fill store in B
@property(nonatomic) XTIRInsn* baseDef;    // the ElementAddr base's defining insn (or nil = param)
@property(nonatomic) XTIRValueId baseId;   // ElementAddr base value
@property(nonatomic) int64_t boundConst;   // loop bound (constant)
@property(nonatomic) BOOL inclusive;       // ULE (vs ULT)
@property(nonatomic) int64_t fillByte;     // store value (constant)
@property(nonatomic) XTIRValueId memIn;    // store's incoming memory token
@property(nonatomic) XTIRValueId memOut;   // store's memory result (loop mem out)
@end
@implementation XTMemsetCand
@end

@implementation XTIROptIdiomMemset

- (NSString*)passName
    {
    return @"idiom-memset";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.recognisesMemsetIdiom)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    for (NSUInteger iter = 0; iter < 256; iter++)
        {
        XTMemsetCand* c = [self recognise:fn];
        if (!c)
            break;
        [self apply:c inFunction:fn];
        }
    }

// Constant integer value of a Const-defined operand, via defOf. Returns NO if
// the operand isn't a Use of an integer `Const`.
static BOOL constOf(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
    {
    if (op.kind == XTIROperandKindImmI)
        {
        if (out)
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
        if (out)
            *out = d.operands[0].intValue;
        return YES;
        }
    // `(u16)0` etc. lower to ZExt(Const) — a zero-extend preserves a
    // non-negative constant's value, so see through it.
    if (d.opcode == XTIROpZExt)
        {
        int64_t v;
        if (constOf(d.operands[0], defOf, &v) && v >= 0)
            {
            if (out)
                *out = v;
            return YES;
            }
        }
    return NO;
    }

- (nullable XTMemsetCand*)recognise:(XTIRFunction*)fn
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
            if (insn.memoryResult)
                {
                defOf[@(insn.memoryResult.valueId)] = insn;
                defBlk[@(insn.memoryResult.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 1)
            continue; // single induction; loose mem ⇒ no mem phi
        XTIRInsn* ivPhi = H.phiNodes[0];
        if (!ivPhi.result || ivPhi.memoryResult)
            continue;
        if (!XTIRTypeKindIsInteger(ivPhi.result.type.kind))
            continue;
        XTIRValueId ivId = ivPhi.result.valueId;

        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            // side-effecting header
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        // Terminator: CondBranch on ICmp(iv, BOUND-const).
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
        XTIROperand *g0 = guard.operands[0], *g1 = guard.operands[1];
        BOOL ivIs0 = (g0.kind == XTIROperandKindUse && g0.valueId == ivId);
        BOOL ivIs1 = (g1.kind == XTIROperandKindUse && g1.valueId == ivId);
        if (ivIs0 == ivIs1)
            continue;
        int64_t bound;
        if (!constOf(ivIs0 ? g1 : g0, defOf, &bound))
            continue; // BOUND must be constant
        if (bound < 0)
            continue;

        XTIRBlock *T = term.operands[1].blockRef, *F = term.operands[2].blockRef;
        BOOL (^latches)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.terminator && b.terminator.opcode == XTIROpBranch &&
                 b.terminator.operands.count >= 1 && b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock *B = nil, *E = nil;
        BOOL bodyOnTrue = NO;
        if (latches(T))
            {
            B = T;
            E = F;
            bodyOnTrue = YES;
            }
        else if (latches(F))
            {
            B = F;
            E = T;
            bodyOnTrue = NO;
            }
        else
            continue;
        if (!E || B.phiNodes.count != 0 || E.phiNodes.count != 0)
            continue;

        // Reduce the guard to a loop-continue predicate facing the bound.
        XTIRICmpPredicate eff = guard.predicate;
        // swap operands
        if (ivIs1)
            {
            switch (eff)
                {
            case XTIRICmpULT:
                eff = XTIRICmpUGT;
                break;
            case XTIRICmpUGT:
                eff = XTIRICmpULT;
                break;
            case XTIRICmpULE:
                eff = XTIRICmpUGE;
                break;
            case XTIRICmpUGE:
                eff = XTIRICmpULE;
                break;
            default:
                break;
                }
            }
        // loop continues on the false edge → negate
        if (!bodyOnTrue)
            {
            switch (eff)
                {
            case XTIRICmpULT:
                eff = XTIRICmpUGE;
                break;
            case XTIRICmpUGE:
                eff = XTIRICmpULT;
                break;
            case XTIRICmpULE:
                eff = XTIRICmpUGT;
                break;
            case XTIRICmpUGT:
                eff = XTIRICmpULE;
                break;
            default:
                eff = XTIRICmpEQ;
                break;
                }
            }
        BOOL inclusive;
        if (eff == XTIRICmpULT)
            inclusive = NO;
        else if (eff == XTIRICmpULE)
            inclusive = YES;
        else
            continue;

        // iv incomings: (preheader, Const 0) + (B, ivNext = Add(iv, 1)).
        if (ivPhi.operands.count != 4)
            continue;
        XTIROperand *initOp = nil, *nextOp = nil;
        XTIRBlock* P = nil;
        if (ivPhi.operands[0].blockRef == B)
            {
            nextOp = ivPhi.operands[1];
            P = ivPhi.operands[2].blockRef;
            initOp = ivPhi.operands[3];
            }
        else if (ivPhi.operands[2].blockRef == B)
            {
            nextOp = ivPhi.operands[3];
            P = ivPhi.operands[0].blockRef;
            initOp = ivPhi.operands[1];
            }
        if (!nextOp || !initOp || !P)
            continue;
        int64_t initV;
        if (!constOf(initOp, defOf, &initV) || initV != 0)
            continue; // start at 0
        if (nextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ivNext = defOf[@(nextOp.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlk[@(nextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(nextOp.valueId)] != 1)
            continue;
        if (ivNext.operands.count < 2)
            continue;
        XTIROperand *na = ivNext.operands[0], *nb = ivNext.operands[1];
        XTIROperand* stepOp = (na.kind == XTIROperandKindUse && na.valueId == ivId)   ? nb
                              : (nb.kind == XTIROperandKindUse && nb.valueId == ivId) ? na
                                                                                      : nil;
        int64_t stepV;
        if (!stepOp || !constOf(stepOp, defOf, &stepV) || stepV != 1)
            continue; // unit stride

        // Body: exactly one Store of a constant byte to ElementAddr(base, iv)
        // over a 1-byte element; everything else pure and call/load free.
        XTIRInsn* store = nil;
        BOOL bodyOK = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            switch (insn.opcode)
                {
            case XTIROpStore:
            case XTIROpStoreVolatile:
                // only one store
                if (store)
                    {
                    bodyOK = NO;
                    }
                store = insn;
                break;
            case XTIROpLoad:
            case XTIROpLoadVolatile:
            case XTIROpCall:
            case XTIROpCallBanked:
            case XTIROpCallCloaked:
            case XTIROpMemCopy:
            case XTIROpMemSet:
                bodyOK = NO;
                break;
            default:
                break; // AddrOf / ElementAddr / Const / Add(iv) — pure
                }
            if (!bodyOK)
                break;
            }
        if (!bodyOK || !store || store.opcode == XTIROpStoreVolatile)
            continue;
        if (store.operands.count < 3)
            continue;
        // pointer = ElementAddr(base, iv), 1-byte element.
        if (store.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ea = defOf[@(store.operands[0].valueId)];
        if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2)
            continue;
        if (ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
            continue;
        if (ea.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId baseId = ea.operands[0].valueId;
        XTIRType* pte = [fn valueForId:baseId].type.pointeeType;
        if (!pte || pte.byteWidth != 1)
            continue; // memset fills bytes
        // base must be reconstructable in P: an AddrOf (clonable) or a param /
        // value defined outside the loop.
        XTIRInsn* baseDef = defOf[@(baseId)];
        XTIRBlock* baseBlk = defBlk[@(baseId)];
        BOOL baseClonableAddrOf = (baseDef && baseDef.opcode == XTIROpAddrOf && baseBlk == B);
        BOOL baseInvariant = (!baseDef) || (baseBlk != H && baseBlk != B);
        if (!baseClonableAddrOf && !baseInvariant)
            continue;
        // fill value: a constant byte.
        int64_t fill;
        if (!constOf(store.operands[1], defOf, &fill))
            continue;
        // memory in (operand 2) must be loop-invariant (no header mem phi exists).
        if (store.operands[2].kind != XTIROperandKindUse)
            continue;
        XTIRValueId memIn = store.operands[2].valueId;
        if (defBlk[@(memIn)] == B || defBlk[@(memIn)] == H)
            continue;

        // iv must not escape (its final value isn't materialised).
        BOOL ivEscapes = NO;
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
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        ivEscapes = YES;
                        break;
                        }
            if (ivEscapes)
                break;
            }
        if (ivEscapes)
            continue;

        XTMemsetCand* c = [XTMemsetCand new];
        c.header = H;
        c.body = B;
        c.exit = E;
        c.preheader = P;
        c.store = store;
        c.baseDef = baseClonableAddrOf ? baseDef : nil;
        c.baseId = baseId;
        c.boundConst = bound;
        c.inclusive = inclusive;
        c.fillByte = fill;
        c.memIn = memIn;
        c.memOut = store.memoryResult ? store.memoryResult.valueId : 0;
        return c;
        }
    return nil;
    }

- (void)apply:(XTMemsetCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *H = c.header, *B = c.body, *E = c.exit, *P = c.preheader;
    XTIRType* memTy = [XTIRType memoryType];
    XTIRType* u32 = [XTIRType u32Type];

    // dst: a fresh AddrOf in P (clone), or the loop-invariant base used directly.
    XTIRValueId dstId;
    if (c.baseDef)
        {
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* res = [[XTIRValue alloc] initWithValueId:rid
                                                       type:c.baseDef.result.type
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:P insnIndex:P.instructions.count]];
        [fn registerValue:res];
        [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                                            result:res
                                                          operands:c.baseDef.operands
                                                            dbgLoc:c.baseDef.dbgLoc]];
        dstId = rid;
        }
    else
        {
        dstId = c.baseId; // loop-invariant / param
        }

    // size = bound (+1 if inclusive); the count fits a u32 immediate.
    int64_t n = c.boundConst + (c.inclusive ? 1 : 0);

    // MemSet [dst, byte:ImmI(fill), size:ImmI(n), memIn] → fresh memory result.
    XTIRValueId memId = [fn allocateValueId];
    XTIRValue* memRes = [[XTIRValue alloc] initWithValueId:memId
                                                      type:memTy
                                                   defSite:[[XTIRDefSite alloc] initWithBlock:P insnIndex:P.instructions.count]];
    [fn registerValue:memRes];
    XTIRInsn* ms = [[XTIRInsn alloc] initWithOpcode:XTIROpMemSet
                                             result:nil
                                           operands:@[ [XTIROperand useWithValueId:dstId],
                                                       [XTIROperand immIWithType:[XTIRType u8Type]
                                                                           value:(c.fillByte & 0xFF)],
                                                       [XTIROperand immIWithType:u32
                                                                           value:n],
                                                       [XTIROperand useWithValueId:c.memIn] ]
                                             dbgLoc:nil];
    ms.memoryResult = memRes;
    [P.instructions addObject:ms];

    // Redirect the loop's memory output to the MemSet's result, for any external
    // reader (loose model usually has none).
    if (c.memOut)
        {
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            [self remapUsesIn:bb from:c.memOut to:memId];
            }
        }

    // Preheader now branches straight to the exit.
    [self retargetTerminatorOf:P from:H to:E];

    [fn.blocks removeObjectIdenticalTo:H];
    [fn.blocks removeObjectIdenticalTo:B];
    }

- (void)retargetTerminatorOf:(XTIRBlock*)blk from:(XTIRBlock*)from to:(XTIRBlock*)to
    {
    XTIRInsn* t = blk.terminator;
    if (!t)
        return;
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:t.operands.count];
    for (XTIROperand* op in t.operands)
        [ops addObject:(op.kind == XTIROperandKindBlock && op.blockRef == from)
                           ? [XTIROperand blockWithRef:to]
                           : op];
    XTIRInsn* nt = [[XTIRInsn alloc] initWithOpcode:t.opcode
                                             result:nil
                                           operands:ops
                                          predicate:t.predicate
                                             dbgLoc:t.dbgLoc];
    [blk resetTerminator];
    [blk setTerminator:nt];
    }

- (void)remapUsesIn:(XTIRBlock*)blk from:(XTIRValueId)from to:(XTIRValueId)to
    {
    void (^rew)(NSMutableArray<XTIRInsn*>*) = ^(NSMutableArray<XTIRInsn*>* arr) {
      for (NSUInteger i = 0; i < arr.count; i++)
          {
          XTIRInsn* insn = arr[i];
          BOOL changed = NO;
          NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
          for (NSUInteger j = 0; j < ops.count; j++)
              if (ops[j].kind == XTIROperandKindUse && ops[j].valueId == from)
                  {
                  ops[j] = [XTIROperand useWithValueId:to];
                  changed = YES;
                  }
          if (!changed)
              continue;
          XTIRInsn* r = (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
                            ? [[XTIRInsn alloc] initWithOpcode:insn.opcode result:insn.result operands:ops predicate:insn.predicate dbgLoc:insn.dbgLoc]
                            : [[XTIRInsn alloc] initWithOpcode:insn.opcode result:insn.result operands:ops dbgLoc:insn.dbgLoc];
          r.memoryResult = insn.memoryResult;
          arr[i] = r;
          }
    };
    rew(blk.phiNodes);
    rew(blk.instructions);
    if (blk.terminator)
        {
        NSMutableArray<XTIRInsn*>* t = [NSMutableArray arrayWithObject:blk.terminator];
        rew(t);
        if (t[0] != blk.terminator)
            {
            [blk resetTerminator];
            [blk setTerminator:t[0]];
            }
        }
    }

@end
