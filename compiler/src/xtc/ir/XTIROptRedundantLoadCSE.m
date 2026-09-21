#import "XTIROptRedundantLoadCSE.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// ── Pure, deterministic, memory-free ops safe to value-number ──────────
// (Anything with a memoryResult is excluded by the caller, which also
// keeps Load/Store/Call/etc. out regardless of this list.)
static BOOL isPureCSEable(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpConst:
    case XTIROpCopy:
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpSDiv:
    case XTIROpUDiv:
    case XTIROpSRem:
    case XTIROpURem:
    case XTIROpNeg:
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFDiv:
    case XTIROpFNeg:
    case XTIROpFSqrt:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
    case XTIROpNot:
    case XTIROpShl:
    case XTIROpLShr:
    case XTIROpAShr:
    case XTIROpRol:
    case XTIROpRor:
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
    case XTIROpICmp:
    case XTIROpFCmp:
    case XTIROpSelect:
    case XTIROpAddrOf:
    case XTIROpFieldAddr:
    case XTIROpElementAddr:
    case XTIROpAggExtract:
        return YES;
    default:
        return NO;
        }
    }

// Bank-state ops change which physical page a pointer addresses, so they
// invalidate cached loads even though they don't "touch memory".
static BOOL isBankStateOp(XTIROpcode op)
    {
    return op == XTIROpBankSave || op == XTIROpBankRestore || op == XTIROpBankSelectFor;
    }

// Stable structural key for a type (so casts to different widths don't CSE
// together). Recurses through Ptr; aggregates key on layout identity.
static NSString* typeKey(XTIRType* t)
    {
    if (!t)
        return @"?";
    switch (t.kind)
        {
    case XTIRTypeKindPtr:
        return [NSString stringWithFormat:@"P(%@,%lu)",
                                          typeKey(t.pointeeType), (unsigned long)t.windowId];
    case XTIRTypeKindAgg:
        return [NSString stringWithFormat:@"A%p", (void*)t.layout];
    default:
        return [NSString stringWithFormat:@"k%u", (unsigned)t.kind];
        }
    }

// Follow the replace chain to the canonical value id (cycle-guarded).
static XTIRValueId resolveVid(NSDictionary<NSNumber*, NSNumber*>* replace,
                              XTIRValueId vid)
    {
    XTIRValueId cur = vid;
    for (int i = 0; i < 64; i++)
        {
        NSNumber* n = replace[@(cur)];
        if (!n)
            break;
        XTIRValueId nx = (XTIRValueId)n.unsignedLongLongValue;
        if (nx == cur)
            break;
        cur = nx;
        }
    return cur;
    }

// Can a store through `sp` change what a load through `lp` would see?
//
// Conservative by default — YES for anything not proved apart. The one case
// proved apart is the one that matters: two FieldAddrs off the SAME base with
// DIFFERENT constant field indices are distinct addresses, so storing p.y does
// not disturb a cached p.x. Without this the forwarding below is useless on the
// shape it exists for: `store p.x; store p.y; load p.x` would have the second
// store wipe the entry the first one just made.
static BOOL mayAliasPtr(XTIRValueId sp, XTIRValueId lp,
                        NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                        NSDictionary<NSNumber*, NSNumber*>* replace)
    {
    if (sp == lp)
        return YES;
    XTIRInsn* sd = defOf[@(sp)];
    XTIRInsn* ld = defOf[@(lp)];
    if (!sd || !ld || sd.opcode != XTIROpFieldAddr || ld.opcode != XTIROpFieldAddr)
        return YES;
    if (sd.operands.count < 2 || ld.operands.count < 2)
        return YES;
    if (sd.operands[0].kind != XTIROperandKindUse || ld.operands[0].kind != XTIROperandKindUse)
        return YES;
    if (resolveVid(replace, sd.operands[0].valueId) != resolveVid(replace, ld.operands[0].valueId))
        return YES;                       // different, or unknown, objects
    if (sd.operands[1].kind != XTIROperandKindImmI || ld.operands[1].kind != XTIROperandKindImmI)
        return YES;                       // a non-constant field index
    return sd.operands[1].intValue == ld.operands[1].intValue;
    }

// Canonical key for an operand (Use ids resolved through `replace`).
static NSString* operandKey(XTIROperand* o,
                            NSDictionary<NSNumber*, NSNumber*>* replace)
    {
    switch (o.kind)
        {
    case XTIROperandKindUse:
        return [NSString stringWithFormat:@"u%llu",
                                          (unsigned long long)resolveVid(replace, o.valueId)];
    case XTIROperandKindImmI:
        return [NSString stringWithFormat:@"i%@:%lld",
                                          typeKey(o.type), (long long)o.intValue];
    case XTIROperandKindImmF:
        return [NSString stringWithFormat:@"f%@:%llu",
                                          typeKey(o.type), (unsigned long long)o.floatRawBytes];
    case XTIROperandKindSym:
        return [NSString stringWithFormat:@"s%llu",
                                          (unsigned long long)o.symbolId];
    case XTIROperandKindConstAgg:
        return [NSString stringWithFormat:@"c%llu",
                                          (unsigned long long)o.constantId];
    case XTIROperandKindBlock:
        return [NSString stringWithFormat:@"b%p", (void*)o.blockRef];
        }
    return @"?";
    }

// Rewrite an insn's Use operands through `replace`. Returns the new operand
// array if anything changed, else nil (caller keeps the original insn).
static NSArray<XTIROperand*>* rewrittenOperands(
    XTIRInsn* insn, NSDictionary<NSNumber*, NSNumber*>* replace)
    {
    NSArray<XTIROperand*>* ops = insn.operands;
    NSMutableArray<XTIROperand*>* out = nil;
    for (NSUInteger i = 0; i < ops.count; i++)
        {
        XTIROperand* o = ops[i];
        if (o.kind != XTIROperandKindUse)
            continue;
        XTIRValueId r = resolveVid(replace, o.valueId);
        if (r == o.valueId)
            continue;
        if (!out)
            out = [ops mutableCopy];
        out[i] = [XTIROperand useWithValueId:r];
        }
    return out;
    }

// Rebuild an insn with new operands, preserving result/memoryResult and the
// call-conv / predicate carried by the right initializer.
static XTIRInsn* rebuiltInsn(XTIRInsn* insn, NSArray<XTIROperand*>* newOps)
    {
    XTIRInsn* r;
    if (insn.callConv)
        {
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:newOps
                                    callConv:insn.callConv
                                      dbgLoc:insn.dbgLoc];
        }
    else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
        {
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:newOps
                                   predicate:insn.predicate
                                      dbgLoc:insn.dbgLoc];
        }
    else
        {
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:newOps
                                      dbgLoc:insn.dbgLoc];
        }
    r.memoryResult = insn.memoryResult;
    return r;
    }

@implementation XTIROptRedundantLoadCSE

- (NSString*)passName
    {
    return @"redundant-load-cse";
    }
- (NSInteger)minOptLevel
    {
    return 2;
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
    // valueId → canonical (winning) value id. Accumulated across the
    // function; applied to every operand in the final rewrite.
    NSMutableDictionary<NSNumber*, NSNumber*>* replace =
        [NSMutableDictionary dictionary];
    // Instructions to drop (their results are redirected via `replace`).
    NSMutableSet<XTIRInsn*>* toDelete = [NSMutableSet set];
    // Defining instruction per value, so the alias test can look through a
    // pointer to the FieldAddr that produced it.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* insn in bb.instructions)
            if (insn.result)
                defOf[@(insn.result.valueId)] = insn;

    for (XTIRBlock* bb in fn.blocks)
        {
        // Per-block tables (block-local — no cross-edge reasoning).
        NSMutableDictionary<NSString*, NSNumber*>* availPure =
            [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber*, NSNumber*>* loadedValue =
            [NSMutableDictionary dictionary];

        for (XTIRInsn* insn in bb.instructions)
            {
            XTIROpcode op = insn.opcode;

            // ── Pure-op CSE ──────────────────────────────────────────
            if (insn.result && !insn.memoryResult && isPureCSEable(op))
                {
                NSMutableString* key = [NSMutableString stringWithFormat:
                                                            @"o%u|p%u|t%@", (unsigned)op, (unsigned)insn.predicate,
                                                            typeKey(insn.result.type)];
                for (XTIROperand* o in insn.operands)
                    [key appendFormat:@"|%@", operandKey(o, replace)];
                NSNumber* have = availPure[key];
                if (have)
                    {
                    replace[@(insn.result.valueId)] = have;
                    [toDelete addObject:insn];
                    }
                else
                    {
                    availPure[key] = @(insn.result.valueId);
                    }
                continue;
                }

            // ── Redundant-load elimination ───────────────────────────
            if (op == XTIROpLoad && insn.result && insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindUse)
                {
                XTIRValueId ptr = resolveVid(replace, insn.operands[0].valueId);
                NSNumber* have = loadedValue[@(ptr)];
                // The cached value must be the TYPE the load wants. A u32
                // stored at an address and read back as a u8 is not the same
                // value, and the table is keyed only by address.
                //
                // Comparing only the KIND was too loose, and in a way that only
                // a pointer shows: every Ptr has the same kind, so a stored
                // `Ptr(Agg(115))` forwarded into a load typed `Ptr(Agg(101))`
                // and the load's users were left holding a value of a different
                // pointee type. Sound for the address, but the SHIPPED compiler
                // compares the whole type and refused the same forward, so the
                // two disagreed on indirect_callee_shapes (bug 228 / bug 226).
                if (have && insn.result.type)
                    {
                    XTIRValue* cv = [fn valueForId:(XTIRValueId)have.unsignedLongLongValue];
                    if (!cv || !cv.type || ![cv.type isEqual:insn.result.type])
                        have = nil;
                    }
                // To delete we must rewire the produced memory token to the
                // load's mem-in; that requires mem-in to be a Use (it always
                // is in well-formed IR, but guard anyway).
                BOOL canRewireMem = (insn.memoryResult == nil) || (insn.operands.count >= 2 && insn.operands[1].kind == XTIROperandKindUse);
                if (have && canRewireMem)
                    {
                    replace[@(insn.result.valueId)] = have;
                    if (insn.memoryResult)
                        {
                        replace[@(insn.memoryResult.valueId)] =
                            @(resolveVid(replace, insn.operands[1].valueId));
                        }
                    [toDelete addObject:insn];
                    }
                else
                    {
                    loadedValue[@(ptr)] = @(insn.result.valueId);
                    }
                continue;
                }

            // ── Store-to-load forwarding ─────────────────────────────
            // A plain Store makes its value available at that pointer, and
            // disturbs only the cached loads that may alias it. Without this a
            // struct field written and read back in the same block went to the
            // frame and came straight back: struct_copy spent most of its loop
            // doing exactly that.
            //
            // VOLATILE stores are excluded — the whole point of one is that the
            // memory, not the value, is the observable thing.
            if (op == XTIROpStore && insn.operands.count >= 2 &&
                insn.operands[0].kind == XTIROperandKindUse)
                {
                XTIRValueId sp = resolveVid(replace, insn.operands[0].valueId);
                for (NSNumber* lp in loadedValue.allKeys)
                    if (mayAliasPtr(sp, (XTIRValueId)lp.unsignedLongLongValue, defOf, replace))
                        [loadedValue removeObjectForKey:lp];
                // Only a Use can be forwarded: the table maps value to value,
                // and an immediate has no value id to hand a later load.
                if (insn.operands[1].kind == XTIROperandKindUse)
                    loadedValue[@(sp)] = @(resolveVid(replace, insn.operands[1].valueId));
                continue;
                }

            // ── Cache invalidation ───────────────────────────────────
            // Any op that may write memory or be opaque (every TouchesMemory
            // op except a plain Load and the Store handled above), plus
            // bank-state ops that repoint pointers, invalidates the cache.
            if ((XTIROpcodeTouchesMemory(op) && op != XTIROpLoad) || isBankStateOp(op))
                {
                [loadedValue removeAllObjects];
                }
            }
        }

    if (replace.count == 0 && toDelete.count == 0)
        return;

    // 1. Drop the dead instructions (their results are redirected below).
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSInteger i = (NSInteger)bb.instructions.count - 1; i >= 0; i--)
            {
            if ([toDelete containsObject:bb.instructions[i]])
                [bb.instructions removeObjectAtIndex:(NSUInteger)i];
            }
        }

    // 2. Rewrite every surviving operand through `replace`.
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.phiNodes.count; i++)
            {
            NSArray<XTIROperand*>* no = rewrittenOperands(bb.phiNodes[i], replace);
            if (no)
                bb.phiNodes[i] = rebuiltInsn(bb.phiNodes[i], no);
            }
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            NSArray<XTIROperand*>* no = rewrittenOperands(bb.instructions[i], replace);
            if (no)
                bb.instructions[i] = rebuiltInsn(bb.instructions[i], no);
            }
        if (bb.terminator)
            {
            NSArray<XTIROperand*>* no = rewrittenOperands(bb.terminator, replace);
            if (no)
                {
                XTIRInsn* nt = rebuiltInsn(bb.terminator, no);
                [bb resetTerminator];
                [bb setTerminator:nt];
                }
            }
        }
    }

@end
