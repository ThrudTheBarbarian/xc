// XTIRVerifier.m
#import "XTIRVerifier.h"
#import "XTIR.h"

@implementation XTIRVerifier

#pragma mark - Helpers

+ (NSArray<XTIRInsn*>*)allInsnsInBlock:(XTIRBlock*)block
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
    [all addObjectsFromArray:block.phiNodes];
    [all addObjectsFromArray:block.instructions];
    if (block.terminator)
        [all addObject:block.terminator];
    return all;
    }

+ (NSSet<XTIRBlock*>*)successorsOfBlock:(XTIRBlock*)block
    {
    NSMutableSet<XTIRBlock*>* out = [NSMutableSet set];
    XTIRInsn* term = block.terminator;
    if (!term)
        return out;
    for (XTIROperand* op in term.operands)
        {
        if (op.kind == XTIROperandKindBlock && op.blockRef)
            {
            [out addObject:op.blockRef];
            }
        }
    return out;
    }

+ (BOOL)typesMatch:(XTIRType*)a withType:(XTIRType*)b
    {
    if (a == b)
        return YES;
    if (!a || !b)
        return NO;
    if (a.kind != b.kind)
        return NO;
    if (a.kind == XTIRTypeKindPtr)
        {
        return a.windowId == b.windowId && [self typesMatch:a.pointeeType withType:b.pointeeType];
        }
    if (a.kind == XTIRTypeKindAgg)
        {
        return a.layout == b.layout;
        }
    return YES;
    }

#pragma mark - Invariant checks

// §12.1 — Single-def SSA.
+ (void)checkSingleDef:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    NSMutableDictionary<NSNumber*, NSNumber*>* counts = [NSMutableDictionary dictionary];
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            if (insn.result)
                {
                NSNumber* k = @(insn.result.valueId);
                counts[k] = @(counts[k].unsignedIntegerValue + 1);
                }
            if (insn.memoryResult)
                {
                NSNumber* k = @(insn.memoryResult.valueId);
                counts[k] = @(counts[k].unsignedIntegerValue + 1);
                }
            }
        }
    for (NSNumber* k in counts)
        {
        if (counts[k].unsignedIntegerValue > 1)
            {
            [errors addObject:[NSString stringWithFormat:
                                            @"§12.1: value %%%u in function '%@' is defined %lu times",
                                            (unsigned)k.unsignedIntValue, fn.name,
                                            (unsigned long)counts[k].unsignedIntegerValue]];
            }
        }
    }

// §12.2 — Operand types match def types (per-opcode rules).
+ (void)checkOperandTypes:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            // Binary integer arith: Add/Sub/Mul/SDiv/UDiv/SRem/URem/And/Or/Xor.
            // Both operands and result must share the same integer type.
            switch (insn.opcode)
                {
            case XTIROpAdd:
            case XTIROpSub:
            case XTIROpMul:
            case XTIROpSDiv:
            case XTIROpUDiv:
            case XTIROpSRem:
            case XTIROpURem:
            case XTIROpAnd:
            case XTIROpOr:
            case XTIROpXor:
                {
                if (insn.operands.count < 2)
                    break;
                XTIROperand* a = insn.operands[0];
                XTIROperand* b = insn.operands[1];
                XTIRValue* va = (a.kind == XTIROperandKindUse) ? [fn valueForId:a.valueId] : nil;
                XTIRValue* vb = (b.kind == XTIROperandKindUse) ? [fn valueForId:b.valueId] : nil;
                if (va && vb && ![self typesMatch:va.type withType:vb.type])
                    {
                    [errors addObject:[NSString stringWithFormat:
                                                    @"§12.2: %@ in '%@' has operands of different types",
                                                    [self mnemonic:insn.opcode], fn.name]];
                    }
                if (insn.result && va && ![self typesMatch:insn.result.type withType:va.type])
                    {
                    [errors addObject:[NSString stringWithFormat:
                                                    @"§12.2: %@ in '%@' result type differs from operand type",
                                                    [self mnemonic:insn.opcode], fn.name]];
                    }
                break;
                }
            default:
                break;
                }
            }
        }
    }

+ (NSString*)mnemonic:(XTIROpcode)op
    {
    switch (op)
        {
    case XTIROpAdd:
        return @"Add";
    case XTIROpSub:
        return @"Sub";
    case XTIROpMul:
        return @"Mul";
    case XTIROpSDiv:
        return @"SDiv";
    case XTIROpUDiv:
        return @"UDiv";
    case XTIROpSRem:
        return @"SRem";
    case XTIROpURem:
        return @"URem";
    case XTIROpAnd:
        return @"And";
    case XTIROpOr:
        return @"Or";
    case XTIROpXor:
        return @"Xor";
    default:
        return @"Op";
        }
    }

// §12.3 — One terminator per block, at the end. The data structure
// enforces "terminator is single" at construction; the verifier
// additionally rejects any instruction appended after a terminator
// (which the parser routes into the regular instructions array for
// fixtures designed to test this).
+ (void)checkTerminators:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    for (XTIRBlock* block in fn.blocks)
        {
        if (!block.terminator)
            {
            [errors addObject:[NSString stringWithFormat:
                                            @"§12.3: block '%@' in '%@' has no terminator",
                                            block.name ?: @"?", fn.name]];
            continue;
            }
        // Two ways to violate "one terminator, at the end":
        //   - A regular instruction in .instructions is itself a
        //     terminator (second terminator in the block).
        //   - The parser flagged that an insn was appended after the
        //     terminator was set.
        for (XTIRInsn* insn in block.instructions)
            {
            if (insn.isTerminator)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.3: block '%@' in '%@' contains a second terminator",
                                                block.name ?: @"?", fn.name]];
                break;
                }
            }
        if (block.hasInstructionAfterTerminator)
            {
            [errors addObject:[NSString stringWithFormat:
                                            @"§12.3: block '%@' in '%@' has an instruction after its terminator",
                                            block.name ?: @"?", fn.name]];
            }
        }
    }

// §12.4 — Phi operand count and order match preds.
+ (void)checkPhiPreds:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    // Compute preds for every block (from terminators).
    NSMutableDictionary<NSValue*, NSMutableArray<XTIRBlock*>*>* predsByBlock =
        [NSMutableDictionary dictionary];
    for (XTIRBlock* src in fn.blocks)
        {
        XTIRInsn* term = src.terminator;
        if (!term)
            continue;
        for (XTIROperand* op in term.operands)
            {
            if (op.kind != XTIROperandKindBlock || !op.blockRef)
                continue;
            NSValue* k = [NSValue valueWithNonretainedObject:op.blockRef];
            NSMutableArray* list = predsByBlock[k];
            if (!list)
                {
                list = [NSMutableArray array];
                predsByBlock[k] = list;
                }
            [list addObject:src];
            }
        }
    for (XTIRBlock* block in fn.blocks)
        {
        NSArray* preds = predsByBlock[[NSValue valueWithNonretainedObject:block]] ?: @[];
        for (XTIRInsn* phi in block.phiNodes)
            {
            if (phi.opcode != XTIROpPhi)
                continue;
            // Phi operands are pairs (Block, Use). Count of pairs:
            NSUInteger pairCount = phi.operands.count / 2;
            if (pairCount != preds.count)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.4: phi in '%@/%@' has %lu operand(s) but block has %lu pred(s)",
                                                fn.name, block.name ?: @"?",
                                                (unsigned long)pairCount, (unsigned long)preds.count]];
                continue;
                }
            // Pair[i].block must equal preds[i] (order matters).
            for (NSUInteger i = 0; i < pairCount; i++)
                {
                XTIROperand* bop = phi.operands[i * 2];
                if (bop.kind != XTIROperandKindBlock)
                    continue;
                if (bop.blockRef != preds[i])
                    {
                    [errors addObject:[NSString stringWithFormat:
                                                    @"§12.4: phi in '%@/%@' pair %lu refs '%@' but pred %lu is '%@'",
                                                    fn.name, block.name ?: @"?", (unsigned long)i,
                                                    bop.blockRef.name ?: @"?",
                                                    (unsigned long)i, [preds[i] name] ?: @"?"]];
                    }
                }
            }
        }
    }

// §12.5 — Memory tokens used at most once *within a block*.
//
// IR-SPEC §7.1 says memory tokens are linear, but §7.2 also says the
// MemSplit primitive needed to break a token across CondBranch arms
// is "optimiser-introduced; the frontend never emits them". So at a
// fork, both successors inherit the predecessor's outgoing token; if
// both eventually consume it (each side's first Load/Store/Return),
// the same SSA value is used twice globally. The frontend physically
// can't avoid this without MemSplit.
//
// The intent of "single use" is linearity *along an execution path*,
// not in the static CFG: each basic block runs at most once per
// function invocation between branches, so within one block the
// chain must still be linear (a double-consume in one block is a
// real bug). Cross-block reuse is OK — runtime mutual exclusion
// makes it linear per actual execution.
+ (void)checkMemorySingleUse:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    for (XTIRBlock* block in fn.blocks)
        {
        NSMutableDictionary<NSNumber*, NSNumber*>* blockUses = [NSMutableDictionary dictionary];
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            for (XTIROperand* op in insn.operands)
                {
                if (op.kind != XTIROperandKindUse)
                    continue;
                XTIRValue* v = [fn valueForId:op.valueId];
                if (!v)
                    continue;
                if (v.type.kind != XTIRTypeKindMemory)
                    continue;
                NSNumber* k = @(op.valueId);
                blockUses[k] = @(blockUses[k].unsignedIntegerValue + 1);
                }
            }
        for (NSNumber* k in blockUses)
            {
            if (blockUses[k].unsignedIntegerValue > 1)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.5: memory token %%%u in '%@/%@' is consumed %lu times within a single block",
                                                (unsigned)k.unsignedIntValue, fn.name, block.name ?: @"?",
                                                (unsigned long)blockUses[k].unsignedIntegerValue]];
                }
            }
        }
    }

// §12.6 — Every memory-touching op has a Memory input (and the
// memory-producing ones have a memory output).
+ (BOOL)opcodeNeedsMemInput:(XTIROpcode)op
    {
    return XTIROpcodeTouchesMemory(op) || op == XTIROpReturn;
    }

+ (void)checkMemoryReachesOps:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            if (![self opcodeNeedsMemInput:insn.opcode])
                continue;
            // Find a Mem-typed Use among operands.
            BOOL found = NO;
            for (XTIROperand* op in insn.operands)
                {
                if (op.kind != XTIROperandKindUse)
                    continue;
                XTIRValue* v = [fn valueForId:op.valueId];
                if (v && v.type.kind == XTIRTypeKindMemory)
                    {
                    found = YES;
                    break;
                    }
                }
            if (!found)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.6: %@ in '%@/%@' (op=%d, %lu operands) touches memory but has no Mem input",
                                                [self mnemonic:insn.opcode], fn.name, block.name ?: @"?",
                                                (int)insn.opcode, (unsigned long)insn.operands.count]];
                }
            // Memory-producing ops (anything that XTIROpcodeTouchesMemory
            // returns YES for except a few) must have a memoryResult.
            if (XTIROpcodeTouchesMemory(insn.opcode) && !insn.memoryResult)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.6: %@ in '%@/%@' (op=%d) touches memory but produces no Mem output",
                                                [self mnemonic:insn.opcode], fn.name, block.name ?: @"?", (int)insn.opcode]];
                }
            }
        }
    }

// §12.7 — AddrOf only on pinnable values.
+ (void)checkAddrOf:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    NSMutableSet<NSNumber*>* pinnedIds = [NSMutableSet set];
    for (XTIRPinnedLocal* local in fn.frameInfo.pinnedLocals)
        {
        [pinnedIds addObject:@(local.valueId)];
        }
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            if (insn.opcode != XTIROpAddrOf)
                continue;
            if (insn.operands.count < 1)
                continue;
            XTIROperand* op = insn.operands[0];
            if (op.kind == XTIROperandKindSym)
                continue; // OK
            if (op.kind == XTIROperandKindUse)
                {
                if ([pinnedIds containsObject:@(op.valueId)])
                    continue; // OK — frame pinned local
                // A PARAMETER is also a valid AddrOf target. An aggregate
                // param can't live in an SSA scalar, and any param whose
                // address is taken (e.g. a scalar referenced from inline
                // asm — `LDA len` in Memory.memset) needs an addressable
                // home; the backend gives such params an addressable slot
                // (arm64 spills params to the frame; xt6502 routes
                // address-taken params to ZP / spill). These aren't in
                // frameInfo.pinnedLocals — they occupy the param slot, not
                // the frame-locals region.
                XTIRValue* v = [fn valueForId:op.valueId];
                if (v && v.defSite.isParameter)
                    continue; // OK
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.7: AddrOf in '%@/%@' targets %%%u which is not a Sym or pinned local",
                                                fn.name, block.name ?: @"?", (unsigned)op.valueId]];
                continue;
                }
            [errors addObject:[NSString stringWithFormat:
                                            @"§12.7: AddrOf in '%@/%@' has non-Sym non-Use operand",
                                            fn.name, block.name ?: @"?"]];
            }
        }
    }

// §12.8 — Symbol references resolve.
+ (void)checkSymbolRefs:(XTIRFunction*)fn
                 module:(XTIRModule*)mod
                 errors:(NSMutableArray<NSString*>*)errors
    {
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            for (XTIROperand* op in insn.operands)
                {
                if (op.kind != XTIROperandKindSym)
                    continue;
                XTIRSymbol* sym = [mod symbolForId:op.symbolId];
                if (!sym)
                    {
                    [errors addObject:[NSString stringWithFormat:
                                                    @"§12.8: instruction in '%@/%@' references unresolved symbol id %lu",
                                                    fn.name, block.name ?: @"?", (unsigned long)op.symbolId]];
                    }
                }
            }
        }
    }

// §12.9 — CallConv matches callee.
+ (void)checkCallConv:(XTIRFunction*)fn
               module:(XTIRModule*)mod
               errors:(NSMutableArray<NSString*>*)errors
    {
    for (XTIRBlock* block in fn.blocks)
        {
        for (XTIRInsn* insn in [self allInsnsInBlock:block])
            {
            BOOL isCloaked = (insn.opcode == XTIROpCallCloaked);
            BOOL isBanked = (insn.opcode == XTIROpCallBanked || insn.opcode == XTIROpCallBankedIndirect);
            BOOL isPlain = (insn.opcode == XTIROpCall);
            if (!isCloaked && !isBanked && !isPlain)
                continue;
            if (insn.operands.count == 0)
                continue;
            XTIROperand* callee = insn.operands[0];
            if (callee.kind != XTIROperandKindSym)
                continue;
            XTIRSymbol* sym = [mod symbolForId:callee.symbolId];
            if (!sym)
                continue; // §12.8 already reported.
            BOOL symCloaked = sym.attributes[@"cloaked"].boolValue;
            BOOL symBanked = sym.attributes[@"banked"].boolValue;
            if (isCloaked && !symCloaked)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.9: CallCloaked in '%@' targets '%@' whose attributes say cloaked: false",
                                                fn.name, sym.name]];
                }
            if (isBanked && !symBanked)
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.9: CallBanked in '%@' targets '%@' whose attributes say banked: false",
                                                fn.name, sym.name]];
                }
            if (isPlain && (symCloaked || symBanked))
                {
                [errors addObject:[NSString stringWithFormat:
                                                @"§12.9: plain Call in '%@' targets '%@' which is %@",
                                                fn.name, sym.name,
                                                symCloaked ? @"cloaked" : @"banked"]];
                }
            }
        }
    }

// §12.10 — Every non-entry block is reachable from the entry block.
+ (void)checkReachability:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    NSMutableSet<XTIRBlock*>* reached = [NSMutableSet set];
    NSMutableArray<XTIRBlock*>* worklist = [NSMutableArray array];
    if (fn.entryBlock)
        {
        [reached addObject:fn.entryBlock];
        [worklist addObject:fn.entryBlock];
        }
    while (worklist.count > 0)
        {
        XTIRBlock* cur = worklist.firstObject;
        [worklist removeObjectAtIndex:0];
        for (XTIRBlock* succ in [self successorsOfBlock:cur])
            {
            if (![reached containsObject:succ])
                {
                [reached addObject:succ];
                [worklist addObject:succ];
                }
            }
        }
    for (XTIRBlock* block in fn.blocks)
        {
        if (block == fn.entryBlock)
            continue;
        if ([reached containsObject:block])
            continue;
        // A block that TERMINATES IN Unreachable is allowed to be unreachable — it is
        // saying so. This is not a loophole, it is the shape the lowering produces for
        //
        //     i16 pick(bool c, i16 a, i16 b) { if (c) { return a; } else { return b; } }
        //
        // where both arms `return`, so nothing branches to the if's join block. Rejecting
        // it meant that -- as ordinary as code gets -- FAILED TO COMPILE. (Dropping the
        // block instead is worse: it orphans the lowering's current block, and a nested
        // `if` then reports the orphan as a live exit to the enclosing arm, which just
        // moves the problem one level out.)
        //
        // Still a genuine error for any OTHER terminator: a block reachable by no path
        // that nonetheless branches or returns is a real lowering bug.
        if (block.terminator && block.terminator.opcode == XTIROpUnreachable)
            continue;
        [errors addObject:[NSString stringWithFormat:
                                        @"§12.10: block '%@' in '%@' is unreachable from entry",
                                        block.name ?: @"?", fn.name]];
        }
    }

// §12.11 — Frame discipline.
+ (void)checkFrame:(XTIRFunction*)fn errors:(NSMutableArray<NSString*>*)errors
    {
    uint32_t sum = 0;
    for (XTIRPinnedLocal* local in fn.frameInfo.pinnedLocals)
        {
        sum += local.type.byteWidth;
        }
    if (sum != fn.frameInfo.pinnedLocalSize)
        {
        [errors addObject:[NSString stringWithFormat:
                                        @"§12.11: function '%@' declares frame size %u but pinned locals sum to %u",
                                        fn.name, (unsigned)fn.frameInfo.pinnedLocalSize, (unsigned)sum]];
        }
    }

#pragma mark - Public

+ (BOOL)verifyModule:(XTIRModule*)mod
              errors:(NSArray<NSString*>* _Nullable* _Nullable)errorsOut
    {
    NSMutableArray<NSString*>* errors = [NSMutableArray array];

    for (XTIRFunction* fn in mod.functions)
        {
        [self checkSingleDef:fn errors:errors];
        [self checkOperandTypes:fn errors:errors];
        [self checkTerminators:fn errors:errors];
        [self checkPhiPreds:fn errors:errors];
        [self checkMemorySingleUse:fn errors:errors];
        [self checkMemoryReachesOps:fn errors:errors];
        [self checkAddrOf:fn errors:errors];
        [self checkSymbolRefs:fn module:mod errors:errors];
        [self checkCallConv:fn module:mod errors:errors];
        [self checkReachability:fn errors:errors];
        [self checkFrame:fn errors:errors];
        }

    if (errorsOut)
        *errorsOut = [errors copy];
    return errors.count == 0;
    }

@end
