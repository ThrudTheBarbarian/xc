#import "XTIROptIfConvert.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// A recognised predicate diamond.
@interface XTIfConvCand : NSObject
@property(nonatomic) XTIRBlock* H;       // header: ends in CondBranch cond, …
@property(nonatomic) XTIRBlock* T;       // pure middle arm: …; Branch J
@property(nonatomic) XTIRBlock* J;       // join: phis merging (H, T)
@property(nonatomic) XTIRValueId condId; // the CondBranch predicate value
@property(nonatomic) BOOL tIsTrueTarget; // YES if cond==true takes T
@end
@implementation XTIfConvCand
@end

@implementation XTIROptIfConvert

- (NSString*)passName
    {
    return @"if-convert";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// An instruction safe to execute unconditionally: pure value computation with
// no memory effect and no trapping behaviour. Excludes loads/stores (memory
// result), calls, integer div/rem (div-by-zero trap), and everything with a
// side effect. Address arithmetic (AddrOf/Field/Element) is pure.
static BOOL speculatable(XTIRInsn* insn)
    {
    if (insn.memoryResult)
        return NO;
    switch (insn.opcode)
        {
    case XTIROpConst:
    case XTIROpCopy:
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpNeg:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
    case XTIROpNot:
    case XTIROpShl:
    case XTIROpLShr:
    case XTIROpAShr:
    case XTIROpRol:
    case XTIROpRor:
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFNeg:
    case XTIROpFSqrt:
    case XTIROpICmp:
    case XTIROpFCmp:
    case XTIROpSelect:
    case XTIROpSExt:
    case XTIROpZExt:
    case XTIROpTrunc:
    case XTIROpBitcast:
    case XTIROpIntToPtr:
    case XTIROpPtrToInt:
    case XTIROpFpToSI:
    case XTIROpFpToUI:
    case XTIROpSIToFp:
    case XTIROpUIToFp:
    case XTIROpFpExt:
    case XTIROpFpTrunc:
    case XTIROpAddrOf:
    case XTIROpFieldAddr:
    case XTIROpElementAddr:
        return YES;
    default:
        // Div/Rem (trap), Load/Store, Call*, Agg*, VTbl, Retain/Release,
        // Weak*, Bank*, Asm, Phi, terminators — keep behind the branch.
        return NO;
        }
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.ifConvertsPredicates)
        return YES;
    if (getenv("XTIC_OFF"))
        return YES; // A/B measurement escape hatch
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    // One diamond at a time, re-recognising from the live CFG after each
    // transform (the apply removes a block and rewrites phis). The bound is a
    // runaway backstop — each apply removes one middle block, so it converges.
    for (NSUInteger iter = 0; iter < 4096; iter++)
        {
        XTIfConvCand* c = [self recognise:fn];
        if (!c)
            break;
        [self apply:c inFunction:fn];
        }
    }

// Predecessor block list for `target` (blocks whose terminator branches to it).
static NSArray<XTIRBlock*>* predsOf(XTIRBlock* target, XTIRFunction* fn)
    {
    NSMutableArray<XTIRBlock*>* p = [NSMutableArray array];
    for (XTIRBlock* b in fn.blocks)
        {
        XTIRInsn* t = b.terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef == target)
                {
                [p addObject:b];
                break;
                }
        }
    return p;
    }

// Is M a "pure middle" arm: single pred H, no phis, side-effect-free body, and an
// unconditional Branch to `dest`?
static BOOL isPureMiddle(XTIRBlock* M, XTIRBlock* H, XTIRBlock* dest, XTIRFunction* fn)
    {
    if (!M || M == H || M.phiNodes.count != 0)
        return NO;
    XTIRInsn* t = M.terminator;
    if (!t || t.opcode != XTIROpBranch || t.operands.count < 1 || t.operands[0].blockRef != dest)
        return NO;
    for (XTIRInsn* insn in M.instructions)
        if (!speculatable(insn))
            return NO;
    NSArray<XTIRBlock*>* mp = predsOf(M, fn);
    return mp.count == 1 && mp[0] == H;
    }

- (nullable XTIfConvCand*)recognise:(XTIRFunction*)fn
    {
    for (XTIRBlock* H in fn.blocks)
        {
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        XTIROperand* condOp = term.operands[0];
        if (condOp.kind != XTIROperandKindUse)
            continue;
        XTIRBlock* tA = term.operands[1].blockRef; // cond==true target
        XTIRBlock* fA = term.operands[2].blockRef; // cond==false target
        if (!tA || !fA || tA == fA)
            continue;

        XTIRBlock *T = nil, *J = nil;
        BOOL tIsTrue = NO;
        if (isPureMiddle(tA, H, fA, fn))
            {
            T = tA;
            J = fA;
            tIsTrue = YES;
            }
        else if (isPureMiddle(fA, H, tA, fn))
            {
            T = fA;
            J = tA;
            tIsTrue = NO;
            }
        else
            continue;
        if (!J || J == H || J == T)
            continue;
        if (J.phiNodes.count == 0)
            continue; // nothing to select; leave it

        // J's predecessors must be exactly {H, T} so every phi has just those
        // two incomings (otherwise it's not a clean diamond).
        NSArray<XTIRBlock*>* jp = predsOf(J, fn);
        if (jp.count != 2)
            continue;
        if (!([jp containsObject:H] && [jp containsObject:T]))
            continue;

        XTIfConvCand* c = [XTIfConvCand new];
        c.H = H;
        c.T = T;
        c.J = J;
        c.condId = condOp.valueId;
        c.tIsTrueTarget = tIsTrue;
        return c;
        }
    return nil;
    }

// Resolve a Use operand to a Bool Const with value `want` (0 or 1).
static BOOL isBoolConst(XTIROperand* op, int64_t want,
                        NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    if (!op || op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(op.valueId)];
    if (!d || d.opcode != XTIROpConst || d.operands.count < 1)
        return NO;
    XTIROperand* imm = d.operands[0];
    return imm.kind == XTIROperandKindImmI && imm.type &&
           imm.type.kind == XTIRTypeKindBool && imm.intValue == want;
    }

// YES if `op` is provably a 0/1 value. `And`/`Or` of two operands only equals
// `cond ? x : 0` / `cond ? 1 : x` when BOTH operands are strictly 0/1 (e.g.
// And(2,1)=0 but 2?1:0=1). A comparison result (cset → 0/1) or a 0/1 bool const
// qualifies; anything else (a loaded bool, a truncation, a wider And result)
// does not, and the caller falls back to the always-correct Select.
static BOOL isBool01(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    if (!op || op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(op.valueId)];
    if (!d)
        return NO;
    if (d.opcode == XTIROpICmp || d.opcode == XTIROpFCmp)
        return YES;
    return isBoolConst(op, 0, defOf) || isBoolConst(op, 1, defOf);
    }

- (void)apply:(XTIfConvCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *H = c.H, *T = c.T, *J = c.J;

    // Whole-function def map, for the And/Or short-circuit refinement below.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            if (insn.result)
                defOf[@(insn.result.valueId)] = insn;
        }

    // 1. Hoist T's (pure) instructions into H, before its terminator. They now
    //    run unconditionally — sound because every one is side-effect-free.
    [H.instructions addObjectsFromArray:T.instructions];

    // 2. Replace each join phi with a Select in H, and remap its uses.
    NSMutableArray<XTIRInsn*>* phis = [J.phiNodes mutableCopy];
    for (XTIRInsn* phi in phis)
        {
        if (!phi.result)
            continue;
        XTIROperand *vT = nil, *vH = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            {
            XTIRBlock* pb = phi.operands[k].blockRef;
            if (pb == T)
                vT = phi.operands[k + 1];
            else if (pb == H)
                vH = phi.operands[k + 1];
            }
        if (!vT || !vH)
            continue; // defensive: not the expected 2-way merge

        // cond==true picks T's value; orient the Select accordingly.
        XTIROperand* selTrue = c.tIsTrueTarget ? vT : vH;
        XTIROperand* selFalse = c.tIsTrueTarget ? vH : vT;

        XTIRType* ty = phi.result.type;
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* res = [[XTIRValue alloc] initWithValueId:rid
                                                       type:ty
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:H insnIndex:H.instructions.count]];
        [fn registerValue:res];
        XTIROperand* condUse = [XTIROperand useWithValueId:c.condId];
        // Boolean short-circuit refinement: `cond ? rhs : false` is `cond & rhs`
        // and `cond ? true : rhs` is `cond | rhs` — a single `and`/`orr` with no
        // condition materialisation or `csel`, shortening the dependency chain.
        // Only valid when both inputs are 0/1 booleans (cond is an ICmp result;
        // the other input is a Bool value), which is exactly the `&&` / `||`
        // lowering shape.
        XTIRInsn* repl;
        BOOL condOK = isBool01(condUse, defOf);
        if (ty.kind == XTIRTypeKindBool && condOK &&
            isBoolConst(selFalse, 0, defOf) && isBool01(selTrue, defOf))
            {
            repl = [[XTIRInsn alloc] initWithOpcode:XTIROpAnd
                                             result:res
                                           operands:@[ condUse, selTrue ]
                                             dbgLoc:phi.dbgLoc];
            }
        else if (ty.kind == XTIRTypeKindBool && condOK &&
                 isBoolConst(selTrue, 1, defOf) && isBool01(selFalse, defOf))
            {
            repl = [[XTIRInsn alloc] initWithOpcode:XTIROpOr
                                             result:res
                                           operands:@[ condUse, selFalse ]
                                             dbgLoc:phi.dbgLoc];
            }
        else
            {
            repl = [[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                             result:res
                                           operands:@[ condUse, selTrue, selFalse ]
                                             dbgLoc:phi.dbgLoc];
            }
        [H.instructions addObject:repl];

        // Rewrite every use of the phi result to the Select result.
        XTIRValueId oldId = phi.result.valueId;
        for (XTIRBlock* bb in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                {
                BOOL changed = NO;
                NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                for (NSUInteger i = 0; i < ops.count; i++)
                    {
                    XTIROperand* o = ops[i];
                    if (o.kind == XTIROperandKindUse && o.valueId == oldId)
                        {
                        ops[i] = [XTIROperand useWithValueId:rid];
                        changed = YES;
                        }
                    }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        [J.phiNodes removeObjectIdenticalTo:phi];
        }

    // 3. H falls straight through to J; the T arm is gone.
    [H resetTerminator];
    [H setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                               result:nil
                                             operands:@[ [XTIROperand blockWithRef:J] ]
                                               dbgLoc:nil]];
    [fn.blocks removeObjectIdenticalTo:T];
    }

@end
