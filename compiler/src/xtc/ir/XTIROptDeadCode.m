#import "XTIROptDeadCode.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"

@implementation XTIROptDeadCode

- (NSString*)passName
    {
    return @"dead-code";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// Pure: no side effects, no memory token, safe to drop when the result is
// unused. Deliberately conservative — anything that loads/stores, calls,
// refcounts, registers a weak ref, copies memory, runs inline asm, dispatches
// a vtable, downcasts, switches banks, or terminates a block is excluded, as
// is Phi (handled by control flow). A DbgValue that references a value counts
// as a use (it appears in the use scan), so debug info pins its operands.
static BOOL XTIRDCEIsPure(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAddrOf:
    case XTIROpConst:
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpUDiv:
    case XTIROpSDiv:
    case XTIROpURem:
    case XTIROpSRem:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
    case XTIROpShl:
    case XTIROpLShr:
    case XTIROpAShr:
    case XTIROpRol:
    case XTIROpRor:
    case XTIROpNeg:
    case XTIROpNot:
    case XTIROpICmp:
    case XTIROpFCmp:
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFDiv:
    case XTIROpFNeg:
    case XTIROpFSqrt:
    case XTIROpZExt:
    case XTIROpSExt:
    case XTIROpTrunc:
    case XTIROpFpExt:
    case XTIROpFpTrunc:
    case XTIROpFpToSI:
    case XTIROpFpToUI:
    case XTIROpSIToFp:
    case XTIROpUIToFp:
    case XTIROpBitcast:
    case XTIROpIntToPtr:
    case XTIROpPtrToInt:
    case XTIROpFieldAddr:
    case XTIROpElementAddr:
    case XTIROpAggBuild:
    case XTIROpAggExtract:
    case XTIROpCopy:
    case XTIROpSelect:
        return YES;
    default:
        return NO;
        }
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;

        // Use count over every operand reference (instructions, phi nodes,
        // and terminators) — recomputed each round so a removal that orphans
        // its operands is picked up on the next pass.
        NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
        void (^count)(NSArray<XTIROperand*>*) = ^(NSArray<XTIROperand*>* ops) {
          for (XTIROperand* op in ops)
              if (op.kind == XTIROperandKindUse)
                  [uses addObject:@(op.valueId)];
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* phi in bb.phiNodes)
                count(phi.operands);
            for (XTIRInsn* insn in bb.instructions)
                count(insn.operands);
            if (bb.terminator)
                count(bb.terminator.operands);
            }

        for (XTIRBlock* bb in fn.blocks)
            {
            for (NSInteger i = (NSInteger)bb.instructions.count - 1; i >= 0; i--)
                {
                XTIRInsn* insn = bb.instructions[(NSUInteger)i];
                if (insn.result && XTIRDCEIsPure(insn.opcode) && [uses countForObject:@(insn.result.valueId)] == 0)
                    {
                    [bb.instructions removeObjectAtIndex:(NSUInteger)i];
                    changed = YES;
                    }
                }
            // Dead phis: a phi whose result is unused is pure dead code (a phi
            // never has side effects). Dropping it also releases its incoming
            // operands, which can free more on the next round. Skipping it (the
            // original behaviour) left loop-carried values that the lowering
            // threads but never reads — e.g. a nested loop's inner counter
            // carried into the outer header — pinning their sources "live" and
            // blocking the var-trip unroller's no-escape check. Memory phis (no
            // language result) are left alone.
            for (NSInteger i = (NSInteger)bb.phiNodes.count - 1; i >= 0; i--)
                {
                XTIRInsn* phi = bb.phiNodes[(NSUInteger)i];
                if (phi.result && !phi.memoryResult && [uses countForObject:@(phi.result.valueId)] == 0)
                    {
                    [bb.phiNodes removeObjectAtIndex:(NSUInteger)i];
                    changed = YES;
                    }
                }
            }
        }
    }

@end
