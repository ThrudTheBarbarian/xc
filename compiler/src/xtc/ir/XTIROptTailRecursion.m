#import "XTIROptTailRecursion.h"
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

// One return statement selected for conversion to a loop back-edge.
@interface XTTRCand : NSObject
@property(nonatomic) XTIRBlock* block;            // block holding the Return (the latch)
@property(nonatomic) XTIRInsn* ret;               // the Return terminator
@property(nonatomic) XTIRInsn* tc;                // the iterated self-call
@property(nonatomic, nullable) XTIRInsn* combine; // Tier-2: the ⊕ insn (nil = Tier-1)
@property(nonatomic) NSUInteger gIdx;             // Tier-2: combine operand index of the g-term
@end

@implementation XTTRCand
@end

@implementation XTIROptTailRecursion

- (NSString*)passName
    {
    return @"tail-recursion";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// Allowed Tier-2 combine ops: associative AND commutative over 2's-complement
// integers, with an unambiguous identity. (And's identity is the all-ones value
// for the type, which is width-dependent to materialise, so it is left out of
// this first cut; max/min are not single opcodes.)
static BOOL combineIdentity(XTIROpcode op, int64_t* ident)
    {
    switch (op)
        {
    case XTIROpAdd:
    case XTIROpOr:
    case XTIROpXor:
        *ident = 0;
        return YES;
    case XTIROpMul:
        *ident = 1;
        return YES;
    default:
        return NO;
        }
    }

static BOOL isCallOpcode(XTIROpcode op)
    {
    return op == XTIROpCall || op == XTIROpCallBanked || op == XTIROpCallCloaked;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.convertsTailRecursion)
        return YES;
    if (getenv("XTTR_OFF"))
        return YES; // A/B measurement escape hatch
    // Tier 2 (accumulator recursion) is opt-in per target — it regresses on a
    // core whose call overhead is hidden (see XTIROptTargetProfile). XTTR_ACC=1
    // forces it on for A/B measurement.
    BOOL acc = prof.convertsAccumulatorRecursion || getenv("XTTR_ACC") != NULL;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn module:mod accumulator:acc];
    return YES;
    }

// Resolve a Call's callee to this function (direct self-recursion).
static BOOL callIsSelf(XTIRInsn* insn, XTIRFunction* fn, XTIRModule* mod)
    {
    if (!isCallOpcode(insn.opcode) || insn.operands.count < 2)
        return NO;
    XTIROperand* callee = insn.operands[0];
    if (callee.kind != XTIROperandKindSym)
        return NO;
    XTIRSymbol* s = [mod symbolForId:callee.symbolId];
    return s != nil && (s.function == fn || [s.name isEqualToString:fn.name]);
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
          accumulator:(BOOL)accumulatorEnabled
    {
    if (fn.blocks.count == 0)
        return;
    XTIRBlock* entry = fn.entryBlock;
    if (!entry || entry.phiNodes.count != 0)
        return; // entry must be phi-free

    // Variadic self-recursion: arg marshalling can't be re-expressed as a
    // straight parameter reassignment.
    XTIRSymbol* selfSym = [mod symbolForName:fn.name];
    if (selfSym.attributes[@"variadic"].boolValue)
        return;

    // Pinned locals whose address escapes are unsafe: the loop reuses a single
    // frame slot across iterations, so a callee holding a pointer into a prior
    // "frame" would alias. Non-escaping locals behave like ordinary loop
    // variables (written before read each iteration) and are fine.
    for (XTIRPinnedLocal* pl in fn.frameInfo.pinnedLocals)
        if (pl.escapesViaPointer)
            return;

    NSUInteger paramCount = fn.paramTypes.count;
    if (paramCount == 0)
        return; // need at least the Mem param
    BOOL lastIsMem = (fn.paramTypes.lastObject.kind == XTIRTypeKindMemory);
    if (!lastIsMem)
        return; // expect trailing Mem token
    NSUInteger userParams = paramCount - 1;
    XTIRValueId memParamId = (XTIRValueId)(paramCount - 1);

    // Definition site + use multiplicity for the whole function.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    BOOL anySelfCall = NO;
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
            if (callIsSelf(insn, fn, mod))
                anySelfCall = YES;
            }
        }
    if (!anySelfCall)
        return;

    // ── Classify every return ────────────────────────────────────────────
    NSMutableArray<XTTRCand*>* tier2 = [NSMutableArray array]; // g ⊕ self-call
    NSMutableArray<XTTRCand*>* tier1 = [NSMutableArray array]; // bare tail self-call
    for (XTIRBlock* bb in fn.blocks)
        {
        XTIRInsn* term = bb.terminator;
        if (!term || term.opcode != XTIROpReturn || term.operands.count == 0)
            continue;
        XTIROperand* memOp = term.operands.lastObject;
        XTIROperand* valOp = (term.operands.count >= 2) ? term.operands[0] : nil;
        if (memOp.kind != XTIROperandKindUse)
            continue;

        // Helper: is `op` a Use of a self-call in this block whose mem-out is
        // the return's mem (i.e. the call is the last side effect) and whose
        // result is used exactly once (by `consumerVid`, the value feeding it)?
        XTIRInsn* (^selfTailCall)(XTIROperand*) = ^XTIRInsn*(XTIROperand* op) {
          if (!op || op.kind != XTIROperandKindUse)
              return nil;
          XTIRInsn* c = defOf[@(op.valueId)];
          if (!c || !callIsSelf(c, fn, mod) || defBlk[@(op.valueId)] != bb)
              return nil;
          if (!c.result || c.result.valueId != op.valueId)
              return nil; // value result, used here
          if (!c.memoryResult || c.memoryResult.valueId != memOp.valueId)
              return nil;
          if ([uses countForObject:@(op.valueId)] != 1)
              return nil; // result used once
          if (c.operands.count != userParams + 2)
              return nil; // [callee,args…,mem]
          return c;
        };

        // Tier-1: `return f(args)` — value is the self-call directly.
        XTIRInsn* tc1 = selfTailCall(valOp);
        if (tc1)
            {
            XTTRCand* cand = [XTTRCand new];
            cand.block = bb;
            cand.ret = term;
            cand.tc = tc1;
            cand.combine = nil;
            [tier1 addObject:cand];
            continue;
            }

        // Tier-2: `return g ⊕ f(args)` — value is an associative combine, one
        // operand of which is a tail self-call.
        if (!valOp || valOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* cmb = defOf[@(valOp.valueId)];
        int64_t ident;
        if (!cmb || defBlk[@(valOp.valueId)] != bb || cmb.operands.count != 2 ||
            !combineIdentity(cmb.opcode, &ident) ||
            !cmb.result || !XTIRTypeKindIsInteger(cmb.result.type.kind))
            continue;
        if ([uses countForObject:@(valOp.valueId)] != 1)
            continue; // combine used once
        NSUInteger tcIdx = NSNotFound;
        XTIRInsn* tc2 = nil;
        for (NSUInteger k = 0; k < 2; k++)
            {
            XTIRInsn* c = selfTailCall(cmb.operands[k]);
            if (c)
                {
                tc2 = c;
                tcIdx = k;
                break;
                }
            }
        if (!tc2)
            continue;
        XTTRCand* cand = [XTTRCand new];
        cand.block = bb;
        cand.ret = term;
        cand.tc = tc2;
        cand.combine = cmb;
        cand.gIdx = (tcIdx == 0) ? 1 : 0;
        [tier2 addObject:cand];
        }

    // ── Choose the mode ───────────────────────────────────────────────────
    XTIROpcode combineOp = XTIROpAdd;
    int64_t identity = 0;
    BOOL tier2Mode = NO;
    NSMutableArray<XTTRCand*>* iterated = [NSMutableArray array];
    if (tier2.count > 0 && accumulatorEnabled)
        {
        tier2Mode = YES;
        combineOp = tier2[0].combine.opcode;
        combineIdentity(combineOp, &identity);
        XTIRType* accType = tier2[0].combine.result.type;
        // Iterate every Tier-2 return that uses the chosen ⊕ (others stay as
        // ordinary returns, wrapped below) plus any bare tail-call returns.
        for (XTTRCand* c in tier2)
            if (c.combine.opcode == combineOp && c.combine.result.type.kind == accType.kind)
                [iterated addObject:c];
        [iterated addObjectsFromArray:tier1];
        }
    else if (tier1.count > 0)
        {
        [iterated addObjectsFromArray:tier1];
        }
    else
        {
        return;
        }
    if (iterated.count == 0)
        return;

    // ── Parallel-copy hazard check (bail, don't mis-transform) ────────────
    // A back-edge that feeds parameter phi j a value that is *another*
    // parameter (a permutation) would need temporaries the sequential
    // phi-edge copies don't provide. Self-pass-through (arg j == param j) is a
    // no-op copy and is fine.
    for (XTTRCand* c in iterated)
        {
        XTIRInsn* tc = c.tc;
        for (NSUInteger j = 0; j < userParams; j++)
            {
            XTIROperand* arg = tc.operands[1 + j];
            if (arg.kind == XTIROperandKindUse &&
                arg.valueId < userParams && arg.valueId != (XTIRValueId)j)
                return;
            }
        }

    // ── Build the loop header and preheader ───────────────────────────────
    XTIRBlock* H = [[XTIRBlock alloc] init];
    H.name = [NSString stringWithFormat:@"%@_loop", entry.name ?: @"entry"];
    [H.phiNodes addObjectsFromArray:entry.phiNodes]; // (none expected)
    [H.instructions addObjectsFromArray:entry.instructions];
    XTIRInsn* entryTerm = entry.terminator;
    if (entryTerm)
        [H setTerminator:entryTerm];
    [entry.phiNodes removeAllObjects];
    [entry.instructions removeAllObjects];
    [entry resetTerminator];
    [fn.blocks insertObject:H atIndex:1];

    // Returns that lived in the old entry block now live in H.
    for (XTTRCand* c in iterated)
        if (c.block == entry)
            c.block = H;

    // ── Phi result values + remap of parameter uses ──────────────────────
    // Memory is loose in this IR (the backend emits loads/stores in program
    // order and treats the mem token as advisory — the var-trip unroller relies
    // on the same), so there is NO memory phi: every memory operation in the
    // loop body just runs each iteration in order. The Mem parameter stays
    // referenced verbatim by base-case returns (whose mem operand the backend
    // ignores) and by the body's calls/loads.
    (void)memParamId;
    NSMutableDictionary<NSNumber*, NSNumber*>* remap = [NSMutableDictionary dictionary];
    NSMutableArray<XTIRValue*>* paramPhiRes = [NSMutableArray array];
    for (NSUInteger i = 0; i < userParams; i++)
        {
        XTIRValueId vid = [fn allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                     type:fn.paramTypes[i]
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:H insnIndex:i]];
        [fn registerValue:v];
        [paramPhiRes addObject:v];
        remap[@((XTIRValueId)i)] = @(vid);
        }

    // Rewrite every existing instruction: param uses → phi results, and
    // phi predecessor block-refs entry → H (the old entry's terminator, and so
    // its out-edges, now originate in H). The phis we are about to add aren't
    // inserted yet, so they're untouched.
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
            for (NSUInteger k = 0; k < ops.count; k++)
                {
                XTIROperand* o = ops[k];
                if (o.kind == XTIROperandKindUse)
                    {
                    NSNumber* n = remap[@(o.valueId)];
                    if (n)
                        {
                        ops[k] = [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue];
                        changed = YES;
                        }
                    }
                else if (insn.opcode == XTIROpPhi && o.kind == XTIROperandKindBlock && o.blockRef == entry)
                    {
                    ops[k] = [XTIROperand blockWithRef:H];
                    changed = YES;
                    }
                }
            if (changed)
                [insn replaceOperands:ops];
            }
        }

    // ── Accumulator identity constant (Tier-2) ────────────────────────────
    XTIRValue* accPhiRes = nil;
    XTIRType* accType = tier2Mode ? tier2[0].combine.result.type : nil;
    XTIROperand* accInitUse = nil;
    if (tier2Mode)
        {
        XTIRValueId idVid = [fn allocateValueId];
        XTIRValue* idVal = [[XTIRValue alloc] initWithValueId:idVid
                                                         type:accType
                                                      defSite:[[XTIRDefSite alloc] initWithBlock:entry insnIndex:0]];
        [fn registerValue:idVal];
        [entry appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                           result:idVal
                                                         operands:@[ [XTIROperand immIWithType:accType value:identity] ]
                                                           dbgLoc:nil]];
        accInitUse = [XTIROperand useWithValueId:idVid];

        XTIRValueId accVid = [fn allocateValueId];
        accPhiRes = [[XTIRValue alloc] initWithValueId:accVid
                                                  type:accType
                                               defSite:[[XTIRDefSite alloc] initWithBlock:H insnIndex:userParams]];
        [fn registerValue:accPhiRes];
        }

    // Phi operand accumulators: start with the preheader (entry) incoming.
    NSMutableArray<NSMutableArray<XTIROperand*>*>* paramPhiOps = [NSMutableArray array];
    for (NSUInteger i = 0; i < userParams; i++)
        [paramPhiOps addObject:[@[ [XTIROperand blockWithRef:entry],
                                   [XTIROperand useWithValueId:(XTIRValueId)i] ] mutableCopy]];
    NSMutableArray<XTIROperand*>* accPhiOps =
        tier2Mode ? [@[ [XTIROperand blockWithRef:entry], accInitUse ] mutableCopy] : nil;

    // ── Convert each iterated return into a back-edge ─────────────────────
    for (XTTRCand* c in iterated)
        {
        XTIRBlock* RB = c.block;
        XTIRInsn* tc = c.tc;
        // Operands now remapped: [callee, arg0..arg_{p-1}, memIn]. memIn is
        // dropped — memory is loose, so the next iteration just re-runs the
        // body's memory ops in order.
        NSArray<XTIROperand*>* tcOps = tc.operands;

        [RB resetTerminator];
        [RB.instructions removeObjectIdenticalTo:tc];
        // The call is GONE, so every later use of its memory result would name a
        // value nothing defines — which the printer emits as `%?N` and a second
        // implementation cannot reproduce, because the number is an allocation
        // id rather than anything structural. Forward it to the call's own
        // memory input: memory is loose here, so this changes no behaviour, only
        // whether the text refers to something that exists.
        if (tc.memoryResult && tcOps.count >= 1)
            {
            XTIROperand* memIn = tcOps.lastObject;
            if (memIn.kind == XTIROperandKindUse)
                [self forwardMem:fn from:tc.memoryResult.valueId to:memIn.valueId];
            }

        XTIROperand* accBack = tier2Mode ? [XTIROperand useWithValueId:accPhiRes.valueId] : nil;
        if (c.combine)
            {
            [RB.instructions removeObjectIdenticalTo:c.combine];
            // acc_next = acc_phi ⊕ g  (g is the non-self-call combine operand).
            XTIROperand* gUse = c.combine.operands[c.gIdx];
            XTIRValueId anVid = [fn allocateValueId];
            XTIRValue* anVal = [[XTIRValue alloc] initWithValueId:anVid
                                                             type:accType
                                                          defSite:[[XTIRDefSite alloc] initWithBlock:RB insnIndex:RB.instructions.count]];
            [fn registerValue:anVal];
            [RB appendInstruction:[[XTIRInsn alloc] initWithOpcode:combineOp
                                                            result:anVal
                                                          operands:@[ [XTIROperand useWithValueId:accPhiRes.valueId], gUse ]
                                                            dbgLoc:nil]];
            accBack = [XTIROperand useWithValueId:anVid];
            }

        for (NSUInteger j = 0; j < userParams; j++)
            {
            [paramPhiOps[j] addObject:[XTIROperand blockWithRef:RB]];
            [paramPhiOps[j] addObject:tcOps[1 + j]];
            }
        if (tier2Mode)
            {
            [accPhiOps addObject:[XTIROperand blockWithRef:RB]];
            [accPhiOps addObject:accBack];
            }

        [RB setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H] ]
                                                    dbgLoc:nil]];
        }

    // ── Wrap every remaining (base-case) return with the accumulator ──────
    if (tier2Mode)
        {
        for (XTIRBlock* bb in fn.blocks)
            {
            XTIRInsn* term = bb.terminator;
            if (!term || term.opcode != XTIROpReturn || term.operands.count < 2)
                continue;
            XTIROperand* valOp = term.operands[0];
            XTIRValueId wVid = [fn allocateValueId];
            XTIRValue* wVal = [[XTIRValue alloc] initWithValueId:wVid
                                                            type:accType
                                                         defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:bb.instructions.count]];
            [fn registerValue:wVal];
            // The block still carries its Return terminator, so insert the
            // accumulator combine directly into the instruction list (before
            // the terminator) rather than via -appendInstruction:.
            [bb.instructions addObject:[[XTIRInsn alloc] initWithOpcode:combineOp
                                                                 result:wVal
                                                               operands:@[ [XTIROperand useWithValueId:accPhiRes.valueId], valOp ]
                                                                 dbgLoc:nil]];
            NSMutableArray<XTIROperand*>* rOps = [term.operands mutableCopy];
            rOps[0] = [XTIROperand useWithValueId:wVid];
            [term replaceOperands:rOps];
            }
        }

    // ── Materialise the header phis and close the preheader ───────────────
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (NSUInteger i = 0; i < userParams; i++)
        [newPhis addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                     result:paramPhiRes[i]
                                                   operands:paramPhiOps[i]
                                                     dbgLoc:nil]];
    if (tier2Mode)
        [newPhis addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                     result:accPhiRes
                                                   operands:accPhiOps
                                                     dbgLoc:nil]];
    [H.phiNodes insertObjects:newPhis
                    atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newPhis.count)]];

    [entry setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                   result:nil
                                                 operands:@[ [XTIROperand blockWithRef:H] ]
                                                   dbgLoc:nil]];
    }

// Replace every Use of `oldMem` in `fn` with `newMem`, rebuilding the
// instructions that referenced it.
- (void)forwardMem:(XTIRFunction*)fn from:(XTIRValueId)oldMem to:(XTIRValueId)newMem
    {
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.phiNodes.count; i++)
            [self rewriteInsn:bb.phiNodes[i] at:i inList:bb.phiNodes from:oldMem to:newMem];
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            [self rewriteInsn:bb.instructions[i] at:i inList:bb.instructions from:oldMem to:newMem];
        XTIRInsn* t = bb.terminator;
        if (!t)
            continue;
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger k = 0; k < t.operands.count; k++)
            {
            XTIROperand* o = t.operands[k];
            if (o.kind != XTIROperandKindUse || o.valueId != oldMem)
                continue;
            if (!ops)
                ops = [t.operands mutableCopy];
            ops[k] = [XTIROperand useWithValueId:newMem];
            }
        if (ops)
            [t replaceOperands:ops];
        }
    }

- (void)rewriteInsn:(XTIRInsn*)insn at:(NSUInteger)i
             inList:(NSMutableArray<XTIRInsn*>*)list
               from:(XTIRValueId)oldMem
                 to:(XTIRValueId)newMem
    {
    NSMutableArray<XTIROperand*>* ops = nil;
    for (NSUInteger k = 0; k < insn.operands.count; k++)
        {
        XTIROperand* o = insn.operands[k];
        if (o.kind != XTIROperandKindUse || o.valueId != oldMem)
            continue;
        if (!ops)
            ops = [insn.operands mutableCopy];
        ops[k] = [XTIROperand useWithValueId:newMem];
        }
    if (ops)
        [insn replaceOperands:ops];
    }

@end
