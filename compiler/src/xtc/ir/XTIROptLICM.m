#import "XTIROptLICM.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@implementation XTIROptLICM

- (NSString*)passName
    {
    return @"licm";
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
    if (!prof.hoistsLoopInvariants)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

// Opcodes that write memory or have side effects; their presence in a loop makes
// loads in that loop non-invariant.
static BOOL writesMemory(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpStore:
    case XTIROpStoreVolatile:
    case XTIROpLoadVolatile:
    case XTIROpCall:
    case XTIROpCallBanked:
    case XTIROpCallCloaked:
    case XTIROpMemSet:
    case XTIROpMemCopy:
    case XTIROpRetain:
    case XTIROpRelease:
    case XTIROpWeakRegister:
    case XTIROpWeakUnregister:
    case XTIROpVTblDispatch:
    case XTIROpProtoDispatch:
    case XTIROpAsm:
        return YES;
    default:
        return NO;
        }
    }

// A pure, speculation-safe op (no memory result, no side effect, no trap).
static BOOL pureHoistable(XTIRInsn* insn)
    {
    if (insn.memoryResult)
        return NO;
    switch (insn.opcode)
        {
    case XTIROpConst: // rematerialised cheaply; leave to const passes
    case XTIROpPhi:
    case XTIROpSDiv:
    case XTIROpUDiv:
    case XTIROpSRem:
    case XTIROpURem: // may trap
        return NO;
    default:
        // Terminators / memory / calls all carry a memoryResult or are
        // handled above; everything else (AddrOf, Field/ElementAddr, casts,
        // integer/float arithmetic, ICmp/FCmp, Select, …) is pure.
        return !XTIROpcodeIsTerminator(insn.opcode);
        }
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    for (NSUInteger pass = 0; pass < 32; pass++)
        {
        if (![self hoistOnce:fn])
            break;
        }
    }

- (BOOL)hoistOnce:(XTIRFunction*)fn
    {
    NSArray<XTIRBlock*>* blocks = fn.blocks;
    NSUInteger nb = blocks.count;
    if (nb == 0)
        return NO;

    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* defBlk = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableArray<NSNumber*>*>* preds = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber*>*>* succs = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++)
        {
        [preds addObject:[NSMutableArray array]];
        [succs addObject:[NSMutableArray array]];
        }
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        XTIRBlock* bb = blocks[bi];
        for (XTIRInsn* insn in bb.instructions)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = @(bi);
                }
            if (insn.memoryResult)
                defBlk[@(insn.memoryResult.valueId)] = @(bi);
            }
        for (XTIRInsn* phi in bb.phiNodes)
            if (phi.result)
                defBlk[@(phi.result.valueId)] = @(bi);
        XTIRInsn* t = bb.terminator;
        if (t)
            for (XTIROperand* o in t.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef)
                    {
                    NSUInteger ti = [blocks indexOfObjectIdenticalTo:o.blockRef];
                    if (ti != NSNotFound)
                        {
                        [succs[bi] addObject:@(ti)];
                        [preds[ti] addObject:@(bi)];
                        }
                    }
        }

    // Dominators (iterative data-flow over the CFG, block 0 = entry). A real
    // loop back-edge is an edge latch→header where the header *dominates* the
    // latch; without this dominance test, a forward edge into an earlier block
    // (irreducible / shared-boundary regions, which inlining and unrolling can
    // produce) masquerades as a back-edge and the loop-body walk below either
    // escapes upward into an outer preheader or stops short of a real body
    // block — both corrupt the IR (infinite ping-pong, or hoisting a live
    // induction update out of its loop). dom[n] = {n} ∪ ⋂ dom[p].
    NSMutableArray<NSMutableIndexSet*>* dom = [NSMutableArray array];
    NSMutableIndexSet* universe = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, nb)];
    for (NSUInteger i = 0; i < nb; i++)
        [dom addObject:(i == 0 ? [NSMutableIndexSet indexSetWithIndex:0]
                               : [universe mutableCopy])];
    BOOL domChanged = YES;
    while (domChanged)
        {
        domChanged = NO;
        for (NSUInteger n = 1; n < nb; n++)
            {
            NSMutableIndexSet* inter = nil;
            for (NSNumber* p in preds[n])
                {
                if (!inter)
                    inter = [dom[p.unsignedIntegerValue] mutableCopy];
                else
                    [inter removeIndexes:({
                    NSMutableIndexSet *diff = [inter mutableCopy];
                    [diff removeIndexes:dom[p.unsignedIntegerValue]]; diff; })];
                }
            if (!inter)
                inter = [NSMutableIndexSet indexSet]; // unreachable
            [inter addIndex:n];
            if (![inter isEqualToIndexSet:dom[n]])
                {
                dom[n] = inter;
                domChanged = YES;
                }
            }
        }

    BOOL changed = NO;
    for (NSUInteger li = 0; li < nb; li++)
        {
        for (NSNumber* hn in succs[li])
            {
            NSUInteger hi = hn.unsignedIntegerValue;
            if (![dom[li] containsIndex:hi])
                continue; // not a real back-edge
            // Natural loop body: every block that reaches the latch without
            // passing through the header, plus the header. Because the header
            // dominates the latch (real back-edge), no path into a body block
            // bypasses the header, so this backward walk provably stays within
            // the loop — it can neither escape up to an outer preheader nor miss
            // an inlined/non-contiguous body block.
            NSMutableSet<NSNumber*>* body = [NSMutableSet setWithObject:@(hi)];
            NSMutableArray<NSNumber*>* wl = [NSMutableArray arrayWithObject:@(li)];
            while (wl.count)
                {
                NSNumber* n = wl.lastObject;
                [wl removeLastObject];
                if ([body containsObject:n])
                    continue;
                [body addObject:n];
                if (n.unsignedIntegerValue != hi)
                    for (NSNumber* p in preds[n.unsignedIntegerValue])
                        [wl addObject:p];
                }
            // Unique preheader: the header's one predecessor outside the loop,
            // which (being the sole entry to a natural loop) dominates the header.
            NSMutableArray<NSNumber*>* outside = [NSMutableArray array];
            for (NSNumber* p in preds[hi])
                if (![body containsObject:p])
                    [outside addObject:p];
            if (outside.count != 1)
                continue;
            if (![dom[hi] containsIndex:outside[0].unsignedIntegerValue])
                continue;
            // Termination: each hoist moves instructions from the loop body into
            // the preheader, which strictly dominates the header — i.e. strictly
            // closer to the entry in the dominator tree. An instruction can only
            // ever move toward the root, so it can never re-enter a block it left;
            // the per-function pass loop converges (the 32-cap is a backstop).
            XTIRBlock* preheader = blocks[outside[0].unsignedIntegerValue];

            BOOL hasMemWrite = NO;
            for (NSNumber* bn in body)
                {
                for (XTIRInsn* insn in blocks[bn.unsignedIntegerValue].instructions)
                    if (writesMemory(insn.opcode))
                        {
                        hasMemWrite = YES;
                        break;
                        }
                if (hasMemWrite)
                    break;
                }

            // Is value `vid` invariant for this loop (defined outside, or already
            // marked to hoist)? Memory tokens are advisory (loose model) — ignore.
            NSMutableSet<NSNumber*>* invariant = [NSMutableSet set];
            BOOL (^opInvariant)(XTIROperand*) = ^BOOL(XTIROperand* o) {
              if (o.kind != XTIROperandKindUse)
                  return YES; // imm / sym / block
              XTIRValue* v = [fn valueForId:o.valueId];
              if (v && v.type.kind == XTIRTypeKindMemory)
                  return YES;
              NSNumber* db = defBlk[@(o.valueId)];
              if (!db || ![body containsObject:db])
                  return YES; // defined outside
              return [invariant containsObject:@(o.valueId)];
            };
            BOOL (^isHoistable)(XTIRInsn*) = ^BOOL(XTIRInsn* insn) {
              if (insn.opcode == XTIROpLoad)
                  {
                  if (hasMemWrite || insn.operands.count < 1 ||
                      insn.operands[0].kind != XTIROperandKindUse)
                      return NO;
                  XTIRInsn* pd = defOf[@(insn.operands[0].valueId)];
                  return pd && pd.opcode == XTIROpFieldAddr; // field loads only
                  }
              return pureHoistable(insn);
            };

            NSMutableArray<XTIRInsn*>* hoist = [NSMutableArray array];
            NSMutableSet<XTIRInsn*>* hoistSet = [NSMutableSet set];
            BOOL progress = YES;
            while (progress)
                {
                progress = NO;
                for (NSNumber* bn in [body.allObjects sortedArrayUsingSelector:@selector(compare:)])
                    {
                    XTIRBlock* bb = blocks[bn.unsignedIntegerValue];
                    for (XTIRInsn* insn in bb.instructions)
                        {
                        if ([hoistSet containsObject:insn] || !isHoistable(insn))
                            continue;
                        BOOL inv = YES;
                        for (XTIROperand* o in insn.operands)
                            if (!opInvariant(o))
                                {
                                inv = NO;
                                break;
                                }
                        if (!inv)
                            continue;
                        [hoistSet addObject:insn];
                        [hoist addObject:insn];
                        if (insn.result)
                            [invariant addObject:@(insn.result.valueId)];
                        if (insn.memoryResult)
                            [invariant addObject:@(insn.memoryResult.valueId)];
                        progress = YES;
                        }
                    }
                }
            if (hoist.count == 0)
                continue;

            // Remove from their blocks, append (in dependency order) to the
            // preheader before its terminator.
            for (XTIRInsn* insn in hoist)
                {
                NSNumber* bn = defBlk[insn.result ? @(insn.result.valueId)
                                                  : @(insn.memoryResult.valueId)];
                [blocks[bn.unsignedIntegerValue].instructions removeObjectIdenticalTo:insn];
                }
            for (XTIRInsn* insn in hoist)
                [preheader.instructions addObject:insn];
            changed = YES;
            return YES; // CFG facts (defBlk) are now stale — recompute next pass
            }
        }
    return changed;
    }

@end
