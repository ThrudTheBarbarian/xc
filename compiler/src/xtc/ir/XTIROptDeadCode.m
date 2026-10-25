#import "XTIRType.h"
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

// A store's address as a key, when it is a function's own local reached by
// constant field and element steps (`q.x`, `a[2]`); nil for anything else (a
// global, a pointer from anywhere, a variable index), so a store through
// memory the program does not own here, a volatile one or a device register,
// is never touched.
static NSString* XTIRDSEKey(XTIROperand* p, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int depth)
    {
    if (depth > 16 || p.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = defOf[@(p.valueId)];
    if (!d || d.operands.count < 1)
        return nil;
    XTIROperand* o0 = d.operands[0];
    if (d.opcode == XTIROpAddrOf)
        return o0.kind == XTIROperandKindUse ? [NSString stringWithFormat:@"L%llu", (unsigned long long)o0.valueId] : nil;
    if ((d.opcode == XTIROpFieldAddr || d.opcode == XTIROpElementAddr) && d.operands.count == 2 &&
        d.operands[1].kind == XTIROperandKindImmI)
        {
        NSString* base = XTIRDSEKey(o0, defOf, depth + 1);
        return base ? [NSString stringWithFormat:@"%@/%c%lld", base, d.opcode == XTIROpFieldAddr ? 'f' : 'e',
                                                  (long long)d.operands[1].intValue] : nil;
        }
    return nil;
    }

// Dead stores, block by block: a scalar store to a local, overwritten by a
// later store to the same place and of the same type with nothing between
// that reads memory (a load, a call, anything else with a memory token), is
// never read. A struct local with no initialiser is zero-filled (owner,
// 2026-10-24) and then usually assigned field by field at once: struct_copy's
// `Pt q; q.x = ...; q.y = ...;` paid two zero stores a call, 1.5x slower.
// The removed store's memory token is handed on to what used it.
- (void)deadStoresIn:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* insn in bb.instructions)
            if (insn.result)
                defOf[@(insn.result.valueId)] = insn;
    BOOL (^scalar)(XTIROperand*) = ^BOOL(XTIROperand* v) {
      XTIRType* t = v.kind == XTIROperandKindUse ? fn.values[@(v.valueId)].type : v.type;
      return t && t.kind != XTIRTypeKindAgg && t.kind != XTIRTypeKindVec;
    };
    XTIRType* (^typeOf)(XTIROperand*) = ^XTIRType*(XTIROperand* v) {
      return v.kind == XTIROperandKindUse ? fn.values[@(v.valueId)].type : v.type;
    };
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableDictionary<NSString*, XTIRInsn*>* pending = [NSMutableDictionary dictionary];
        NSMutableArray<XTIRInsn*>* dead = [NSMutableArray array];
        for (XTIRInsn* insn in bb.instructions)
            {
            if (insn.opcode == XTIROpStore && insn.operands.count == 3 && insn.memoryResult)
                {
                NSString* key = XTIRDSEKey(insn.operands[0], defOf, 0);
                if (!key || !scalar(insn.operands[1]))
                    continue; // a store elsewhere reads nothing: no barrier
                XTIRInsn* prev = pending[key];
                if (prev && [typeOf(prev.operands[1]) isEqual:typeOf(insn.operands[1])])
                    [dead addObject:prev];
                pending[key] = insn;
                continue;
                }
            if (insn.memoryResult)
                [pending removeAllObjects];
            }
        for (XTIRInsn* st in dead)
            {
            XTIRValueId old = st.memoryResult.valueId;
            XTIROperand* to = st.operands[2];
            for (XTIRBlock* b in fn.blocks)
                {
                NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
                [all addObjectsFromArray:b.instructions];
                if (b.terminator)
                    [all addObject:b.terminator];
                for (XTIRInsn* u in all)
                    {
                    NSMutableArray<XTIROperand*>* ops = [u.operands mutableCopy];
                    BOOL ch = NO;
                    for (NSUInteger k = 0; k < ops.count; k++)
                        if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == old)
                            {
                            ops[k] = to;
                            ch = YES;
                            }
                    if (ch)
                        [u replaceOperands:ops];
                    }
                }
            [bb.instructions removeObjectIdenticalTo:st];
            }
        }
    }

// A Retain and a Release of the same value that cancel, block by block: the
// Release takes its memory token straight from the Retain and only pure
// instructions (no memory token, no call) lie between, so nothing can drop the
// count in between and the Release cannot free what the Retain held. A loop
// that compares each element of an Array with a value retained and released
// every element around one compare (2026-10-25). Whatever used the Release's
// token uses the Retain's input token instead.
- (void)retainPairsIn:(XTIRFunction*)fn
    {
    for (XTIRBlock* bb in fn.blocks)
        {
        BOOL again = YES;
        while (again)
            {
            again = NO;
            NSArray<XTIRInsn*>* ins = bb.instructions;
            for (NSUInteger i = 0; i < ins.count && !again; i++)
                {
                XTIRInsn* r = ins[i];
                if (r.opcode != XTIROpRetain || r.operands.count != 2 || !r.memoryResult ||
                    r.operands[0].kind != XTIROperandKindUse)
                    continue;
                for (NSUInteger k = i + 1; k < ins.count; k++)
                    {
                    XTIRInsn* q = ins[k];
                    if (q.opcode == XTIROpRelease)
                        {
                        if (q.operands.count == 2 && q.memoryResult && q.operands[0].kind == XTIROperandKindUse &&
                            q.operands[0].valueId == r.operands[0].valueId &&
                            q.operands[1].kind == XTIROperandKindUse &&
                            q.operands[1].valueId == r.memoryResult.valueId)
                            {
                            XTIRValueId old = q.memoryResult.valueId;
                            XTIROperand* to = r.operands[1];
                            for (XTIRBlock* b in fn.blocks)
                                {
                                NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
                                [all addObjectsFromArray:b.instructions];
                                if (b.terminator)
                                    [all addObject:b.terminator];
                                for (XTIRInsn* u in all)
                                    {
                                    NSMutableArray<XTIROperand*>* ops = [u.operands mutableCopy];
                                    BOOL ch = NO;
                                    for (NSUInteger m = 0; m < ops.count; m++)
                                        if (ops[m].kind == XTIROperandKindUse && ops[m].valueId == old)
                                            {
                                            ops[m] = to;
                                            ch = YES;
                                            }
                                    if (ch)
                                        [u replaceOperands:ops];
                                    }
                                }
                            [bb.instructions removeObjectIdenticalTo:q];
                            [bb.instructions removeObjectIdenticalTo:r];
                            again = YES;
                            }
                        break;
                        }
                    if (q.memoryResult || !XTIRDCEIsPure(q.opcode))
                        break;
                    }
                }
            }
        }
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    [self retainPairsIn:fn];
    [self deadStoresIn:fn];
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
