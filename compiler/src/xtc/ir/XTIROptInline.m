#import "XTIROptInline.h"
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

// Body-size ceiling for an inlinable callee (instruction count, excluding
// the terminator). Keeps code growth bounded; the hot library leaves
// (Math$step ~30, the sqrt/pow wrappers ~3) sit comfortably under it.
static const NSUInteger kMaxInlineInsns = 64;

@implementation XTIROptInline

- (NSString*)passName
    {
    return @"inline";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

#pragma mark - Insn rebuild helpers

// Rebuild an instruction with a (possibly) new result / operands / memory
// result, preserving opcode, predicate, calling convention and dbg loc.
static XTIRInsn* rebuildInsn(XTIRInsn* insn, XTIRValue* result,
                             NSArray<XTIROperand*>* ops, XTIRValue* memResult)
    {
    XTIROpcode op = insn.opcode;
    XTIRInsn* out;
    if (insn.callConv)
        {
        out = [[XTIRInsn alloc] initWithOpcode:op
                                        result:result
                                      operands:ops
                                      callConv:insn.callConv
                                        dbgLoc:insn.dbgLoc];
        }
    else if (op == XTIROpICmp || op == XTIROpFCmp)
        {
        out = [[XTIRInsn alloc] initWithOpcode:op
                                        result:result
                                      operands:ops
                                     predicate:insn.predicate
                                        dbgLoc:insn.dbgLoc];
        }
    else
        {
        out = [[XTIRInsn alloc] initWithOpcode:op
                                        result:result
                                      operands:ops
                                        dbgLoc:insn.dbgLoc];
        }
    out.memoryResult = memResult;
    return out;
    }

// Substitute Use(oldVid) → newOp across an operand list, returning a fresh
// array (or the original when nothing matched).
static NSArray<XTIROperand*>* substUses(NSArray<XTIROperand*>* ops,
                                        XTIRValueId oldVid, XTIROperand* newOp)
    {
    BOOL hit = NO;
    for (XTIROperand* o in ops)
        {
        if (o.kind == XTIROperandKindUse && o.valueId == oldVid)
            {
            hit = YES;
            break;
            }
        }
    if (!hit)
        return ops;
    NSMutableArray<XTIROperand*>* out = [NSMutableArray arrayWithCapacity:ops.count];
    for (XTIROperand* o in ops)
        {
        [out addObject:(o.kind == XTIROperandKindUse && o.valueId == oldVid) ? newOp : o];
        }
    return out;
    }

// Rewrite every use of `oldVid` in `fn` to `newOp`, rebuilding the
// instructions that referenced it. Used to forward an inlined call's
// result / memory-result to the value the callee actually returned.
static void rewriteUses(XTIRFunction* fn, XTIRValueId oldVid, XTIROperand* newOp)
    {
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.phiNodes.count; i++)
            {
            XTIRInsn* p = bb.phiNodes[i];
            NSArray* no = substUses(p.operands, oldVid, newOp);
            if (no != p.operands)
                bb.phiNodes[i] = rebuildInsn(p, p.result, no, p.memoryResult);
            }
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* in = bb.instructions[i];
            NSArray* no = substUses(in.operands, oldVid, newOp);
            if (no != in.operands)
                bb.instructions[i] = rebuildInsn(in, in.result, no, in.memoryResult);
            }
        XTIRInsn* t = bb.terminator;
        if (t)
            {
            NSArray* no = substUses(t.operands, oldVid, newOp);
            if (no != t.operands)
                {
                [bb resetTerminator];
                [bb setTerminator:rebuildInsn(t, t.result, no, t.memoryResult)];
                }
            }
        }
    }

#pragma mark - Candidate selection

// Return the callee XTIRFunction this Call can be inlined from, or nil.
- (nullable XTIRFunction*)inlinableCalleeFor:(XTIRInsn*)insn
                                      caller:(XTIRFunction*)caller
                                         mod:(XTIRModule*)mod
                                    fnByName:(NSDictionary<NSString*, XTIRFunction*>*)fnByName
    {
    if (insn.opcode != XTIROpCall)
        return nil; // plain Call only
    if (insn.operands.count < 1)
        return nil;
    XTIROperand* c = insn.operands[0];
    if (c.kind != XTIROperandKindSym)
        return nil;
    XTIRSymbol* sym = [mod symbolForId:c.symbolId];
    if (!sym)
        return nil;
    XTIRFunction* callee = fnByName[sym.name];
    if (!callee || callee == caller)
        return nil; // unknown body / self
    if (callee.blocks.count == 0)
        return nil;
    // Single-block bodies splice in place; a multi-block body is inlined by
    // splitting the caller block and wiring the CFG, but only when it has a
    // SINGLE return and NO phis (so the return value/memory forward to one
    // value with no merge — covers diamond-CFG accessors like a tagged-union
    // getter, whose only cross-block reference is the loose memory token).
    BOOL multi = callee.blocks.count > 1;
    NSUInteger returns = 0, totalInsns = 0;
    for (XTIRBlock* cbb in callee.blocks)
        {
        if (cbb.phiNodes.count > 0)
            return nil;
        totalInsns += cbb.instructions.count;
        if (cbb.terminator && cbb.terminator.opcode == XTIROpReturn)
            returns++;
        for (XTIRInsn* bi in cbb.instructions)
            {
            if (bi.opcode == XTIROpAsm)
                return nil; // {{XTLOCAL}} slot refs
            // A multi-block callee with a call could be (mutually) recursive —
            // inlining it would re-expose the call and loop forever (the digit-
            // recursive Stdio$_emitU32). Restrict multi-block inlining to leaves.
            if (multi)
                switch (bi.opcode)
                    {
                case XTIROpCall:
                case XTIROpCallBanked:
                case XTIROpCallCloaked:
                case XTIROpVTblDispatch:
                case XTIROpProtoDispatch:
                    return nil;
                default:
                    break;
                    }
            }
        }
    if (returns != 1)
        return nil;
    if (totalInsns > kMaxInlineInsns)
        return nil;
    // A pinned local is a frame SLOT the callee takes the address of. It can
    // come across, because every back end lays these out ITSELF, in list order,
    // from the local's TYPE — none reads the byteOffset recorded here — so the
    // callee's own frame offset does not have to travel with it. inlineCall
    // gives each one a fresh caller value and appends it to the caller's list.
    //
    // Only for a SINGLE-BLOCK callee: the multi-block path splits the caller
    // and wires the CFG through a different splice that does not do this.
    // …and only where the target can address a frame temp reliably. On the
    // 6502 it cannot — struct_byval_rvalue came back wrong when this was
    // allowed there — which is the same constraint the aggregate-parameter
    // knob describes, so it shares it.
    if ((multi || !self.profile.inlinesAggregateParams)
        && callee.frameInfo.pinnedLocals.count > 0)
        return nil;
    // Operand shape must match the callee's parameter list exactly
    // (callee params = [user0..userN-1, Mem]; call operands = [sym, args..,
    // memIn]). A mismatch (e.g. a variadic/cloaked call) is not inlinable.
    NSUInteger nParams = callee.paramTypes.count; // includes the Mem token
    if (nParams < 1)
        return nil;
    NSUInteger nUser = nParams - 1;
    if (insn.operands.count != 1 + nUser + 1)
        return nil;
    // Don't inline a callee that takes an aggregate-by-value parameter. Such a
    // param is only ever read via AddrOf(param); after inlining that becomes
    // AddrOf of the caller's *loaded* Agg temp (Load result), which is not
    // reliably addressable on the 6502 — the second consecutive such inline
    // harvested zeros (struct_return_field). Passing the aggregate through a
    // real call keeps it on the stack where AddrOf is well-defined.
    if (!self.profile.inlinesAggregateParams)
        for (NSUInteger k = 0; k < nUser; k++)
            if (callee.paramTypes[k].kind == XTIRTypeKindAgg)
                return nil;
    return callee;
    }

#pragma mark - Splice

// Inline `callee` (single block) at `callInsn` within `bb` of `caller`.
// Returns the cloned body instructions to splice in place of the call, or
// nil if the site can't be inlined.
- (nullable NSArray<XTIRInsn*>*)inlineCall:(XTIRInsn*)callInsn
                                    callee:(XTIRFunction*)callee
                                    caller:(XTIRFunction*)caller
                                     block:(XTIRBlock*)bb
    {
    XTIRBlock* cb = callee.blocks[0];
    NSUInteger nParams = callee.paramTypes.count;
    NSUInteger nUser = nParams - 1;

    // remap: callee value-id → substituted caller operand.
    NSMutableDictionary<NSNumber*, XTIROperand*>* remap = [NSMutableDictionary dictionary];
    // Parameters: callee gives param value-ids 0..nParams-1 in order, the
    // last being the Mem token. Map each to the actual call operand.
    for (NSUInteger i = 0; i < nUser; i++)
        {
        remap[@(i)] = callInsn.operands[1 + i];
        }
    remap[@(nParams - 1)] = callInsn.operands.lastObject; // mem input

    XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:bb insnIndex:0];

    // The callee's pinned locals become the caller's. A pinned local is a frame
    // slot rather than an instruction result, so it never appears in the body
    // walk below: give each a fresh caller value, map it, and append it. The
    // back ends re-lay them out from the type, so byteOffset travels as 0.
    if (callee.frameInfo.pinnedLocals.count)
        {
        NSMutableArray<XTIRPinnedLocal*>* pins =
            [caller.frameInfo.pinnedLocals mutableCopy] ?: [NSMutableArray array];
        for (XTIRPinnedLocal* pl in callee.frameInfo.pinnedLocals)
            {
            XTIRValueId nv = [caller allocateValueId];
            XTIRValue* v = [[XTIRValue alloc] initWithValueId:nv
                                                         type:pl.type
                                                      defSite:site];
            [caller registerValue:v];
            remap[@(pl.valueId)] = [XTIROperand useWithValueId:nv];
            [pins addObject:[[XTIRPinnedLocal alloc] initWithName:pl.name
                                                             type:pl.type
                                                       byteOffset:0
                                                          valueId:nv]];
            }
        caller.frameInfo.pinnedLocals = pins;
        }

    // Allocate fresh caller values for every value the callee body defines.
    for (XTIRInsn* bi in cb.instructions)
        {
        if (bi.result)
            {
            XTIRValueId nv = [caller allocateValueId];
            XTIRValue* v = [[XTIRValue alloc] initWithValueId:nv
                                                         type:bi.result.type
                                                      defSite:site];
            [caller registerValue:v];
            remap[@(bi.result.valueId)] = [XTIROperand useWithValueId:nv];
            }
        if (bi.memoryResult)
            {
            XTIRValueId nv = [caller allocateValueId];
            XTIRValue* v = [[XTIRValue alloc] initWithValueId:nv
                                                         type:bi.memoryResult.type
                                                      defSite:site];
            [caller registerValue:v];
            remap[@(bi.memoryResult.valueId)] = [XTIROperand useWithValueId:nv];
            }
        }

    XTIROperand* (^subst)(XTIROperand*) = ^XTIROperand*(XTIROperand* o) {
      if (o.kind == XTIROperandKindUse)
          {
          XTIROperand* r = remap[@(o.valueId)];
          if (r)
              return r;
          }
      return o;
    };

    // Clone the body.
    NSMutableArray<XTIRInsn*>* spliced = [NSMutableArray arrayWithCapacity:cb.instructions.count];
    for (XTIRInsn* bi in cb.instructions)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:bi.operands.count];
        for (XTIROperand* o in bi.operands)
            [ops addObject:subst(o)];
        XTIRValue* newResult = bi.result
                                   ? [caller valueForId:remap[@(bi.result.valueId)].valueId]
                                   : nil;
        XTIRValue* newMem = bi.memoryResult
                                ? [caller valueForId:remap[@(bi.memoryResult.valueId)].valueId]
                                : nil;
        [spliced addObject:rebuildInsn(bi, newResult, ops, newMem)];
        }

    // Forward the call's results to the callee's Return operands. The mem
    // operand is always last; the value operand (if the call has a result)
    // is first.
    XTIRInsn* ret = cb.terminator;
    XTIROperand* retMem = ret.operands.count >= 1 ? subst(ret.operands.lastObject) : nil;
    XTIROperand* retVal = nil;
    if (callInsn.result)
        {
        if (ret.operands.count < 2)
            return nil; // value expected but absent
        retVal = subst(ret.operands[0]);
        }
    if (callInsn.result && retVal)
        {
        rewriteUses(caller, callInsn.result.valueId, retVal);
        }
    if (callInsn.memoryResult && retMem)
        {
        rewriteUses(caller, callInsn.memoryResult.valueId, retMem);
        }
    return spliced;
    }

// Inline a single-return, phi-free MULTI-block `callee` at `callInsn` (index
// `callIndex` in `bb`). Splits `bb` at the call: the prefix keeps its
// instructions and branches into the cloned callee entry; a fresh continuation
// block takes the suffix + the original terminator; the callee's one Return
// becomes a Branch to the continuation, forwarding the returned value/memory.
- (void)multiBlockInline:(XTIRInsn*)callInsn
                  callee:(XTIRFunction*)callee
                  caller:(XTIRFunction*)caller
                   block:(XTIRBlock*)bb
                   index:(NSUInteger)callIndex
    {
    NSUInteger nParams = callee.paramTypes.count;
    NSUInteger nUser = nParams - 1;
    XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:bb insnIndex:0];

    // Value remap: params → call args; mem param → call mem; every callee
    // result / memory result → a fresh caller value.
    NSMutableDictionary<NSNumber*, XTIROperand*>* remap = [NSMutableDictionary dictionary];
    for (NSUInteger k = 0; k < nUser; k++)
        remap[@(k)] = callInsn.operands[1 + k];
    remap[@(nParams - 1)] = callInsn.operands.lastObject;
    for (XTIRBlock* cbb in callee.blocks)
        {
        for (XTIRInsn* bi in cbb.instructions)
            {
            if (bi.result)
                {
                XTIRValueId nv = [caller allocateValueId];
                [caller registerValue:[[XTIRValue alloc] initWithValueId:nv type:bi.result.type defSite:site]];
                remap[@(bi.result.valueId)] = [XTIROperand useWithValueId:nv];
                }
            if (bi.memoryResult)
                {
                XTIRValueId nv = [caller allocateValueId];
                [caller registerValue:[[XTIRValue alloc] initWithValueId:nv type:bi.memoryResult.type defSite:site]];
                remap[@(bi.memoryResult.valueId)] = [XTIROperand useWithValueId:nv];
                }
            }
        }

    // One fresh caller block per callee block.
    NSMapTable<XTIRBlock*, XTIRBlock*>* blockMap = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray<XTIRBlock*>* clones = [NSMutableArray array];
    NSUInteger tag = caller.blocks.count;
    for (XTIRBlock* cbb in callee.blocks)
        {
        XTIRBlock* nb = [[XTIRBlock alloc] init];
        nb.name = [NSString stringWithFormat:@"il%lu_%@", (unsigned long)tag, cbb.name ?: @"b"];
        [blockMap setObject:nb forKey:cbb];
        [clones addObject:nb];
        }
    XTIRBlock* cont = [[XTIRBlock alloc] init];
    cont.name = [NSString stringWithFormat:@"il%lu_cont", (unsigned long)tag];

    XTIROperand* (^subst)(XTIROperand*) = ^XTIROperand*(XTIROperand* o) {
      if (o.kind == XTIROperandKindUse)
          {
          XTIROperand* r = remap[@(o.valueId)];
          if (r)
              return r;
          }
      if (o.kind == XTIROperandKindBlock && o.blockRef)
          {
          XTIRBlock* nb = [blockMap objectForKey:o.blockRef];
          if (nb)
              return [XTIROperand blockWithRef:nb];
          }
      return o;
    };

    // Continuation: the suffix instructions + the original terminator.
    for (NSUInteger j = callIndex + 1; j < bb.instructions.count; j++)
        [cont.instructions addObject:bb.instructions[j]];
    if (bb.terminator)
        {
        XTIRInsn* t = bb.terminator;
        [bb resetTerminator];
        [cont setTerminator:t];
        // `cont` now branches where `bb` did, so any phi in those successors
        // that names `bb` as its predecessor must be re-pointed at `cont` —
        // crucial when `bb` is a loop body (the back-edge phi feeds the
        // induction variable; a stale predecessor freezes it → infinite loop).
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            XTIRBlock* succ = o.blockRef;
            for (NSUInteger pi = 0; pi < succ.phiNodes.count; pi++)
                {
                XTIRInsn* phi = succ.phiNodes[pi];
                BOOL hit = NO;
                NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
                for (NSUInteger k = 0; k < ops.count; k++)
                    if (ops[k].kind == XTIROperandKindBlock && ops[k].blockRef == bb)
                        {
                        ops[k] = [XTIROperand blockWithRef:cont];
                        hit = YES;
                        }
                if (hit)
                    succ.phiNodes[pi] = rebuildInsn(phi, phi.result, ops, phi.memoryResult);
                }
            }
        }
    if (callIndex < bb.instructions.count)
        [bb.instructions removeObjectsInRange:NSMakeRange(callIndex, bb.instructions.count - callIndex)];

    // Clone each callee block; the Return becomes a Branch to `cont`.
    XTIROperand *retVal = nil, *retMem = nil;
    for (XTIRBlock* cbb in callee.blocks)
        {
        XTIRBlock* nb = [blockMap objectForKey:cbb];
        for (XTIRInsn* bi in cbb.instructions)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:bi.operands.count];
            for (XTIROperand* o in bi.operands)
                [ops addObject:subst(o)];
            XTIRValue* nr = bi.result ? [caller valueForId:remap[@(bi.result.valueId)].valueId] : nil;
            XTIRValue* nm = bi.memoryResult ? [caller valueForId:remap[@(bi.memoryResult.valueId)].valueId] : nil;
            [nb.instructions addObject:rebuildInsn(bi, nr, ops, nm)];
            }
        XTIRInsn* t = cbb.terminator;
        if (t && t.opcode == XTIROpReturn)
            {
            retMem = t.operands.count >= 1 ? subst(t.operands.lastObject) : nil;
            if (callInsn.result && t.operands.count >= 2)
                retVal = subst(t.operands[0]);
            [nb setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                        result:nil
                                                      operands:@[ [XTIROperand blockWithRef:cont] ]
                                                        dbgLoc:nil]];
            }
        else if (t)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:t.operands.count];
            for (XTIROperand* o in t.operands)
                [ops addObject:subst(o)];
            [nb setTerminator:rebuildInsn(t, nil, ops, nil)];
            }
        }

    // Prefix branches into the cloned entry.
    [bb setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                result:nil
                                              operands:@[ [XTIROperand blockWithRef:clones.firstObject] ]
                                                dbgLoc:nil]];

    // Splice the cloned blocks + continuation in BEFORE forwarding the call's
    // result — the suffix moved into `cont` still references the call result,
    // so rewriteUses must see `cont` in the block list.
    NSUInteger pos = [caller.blocks indexOfObjectIdenticalTo:bb] + 1;
    [clones addObject:cont];
    [caller.blocks insertObjects:clones
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(pos, clones.count)]];

    // The single return value/memory forwards to the call's result.
    if (callInsn.result && retVal)
        rewriteUses(caller, callInsn.result.valueId, retVal);
    if (callInsn.memoryResult && retMem)
        rewriteUses(caller, callInsn.memoryResult.valueId, retMem);
    }

#pragma mark - Driver

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    NSMutableDictionary<NSString*, XTIRFunction*>* fnByName =
        [NSMutableDictionary dictionaryWithCapacity:mod.functions.count];
    for (XTIRFunction* fn in mod.functions)
        fnByName[fn.name] = fn;

    for (XTIRFunction* caller in mod.functions)
        {
        // Single-block callees splice in place; a multi-block callee splits the
        // block (growing the block list), so after one we restart the caller's
        // scan. Bounded by `guard` against pathological recursion.
        BOOL again = YES;
        NSUInteger guard = 0;
        while (again && guard++ < 8192)
            {
            again = NO;
            for (NSUInteger bi = 0; bi < caller.blocks.count && !again; bi++)
                {
                XTIRBlock* bb = caller.blocks[bi];
                NSUInteger i = 0;
                while (i < bb.instructions.count)
                    {
                    XTIRInsn* insn = bb.instructions[i];
                    XTIRFunction* callee = [self inlinableCalleeFor:insn
                                                             caller:caller
                                                                mod:mod
                                                           fnByName:fnByName];
                    if (!callee)
                        {
                        i++;
                        continue;
                        }
                    if (callee.blocks.count == 1)
                        {
                        NSArray<XTIRInsn*>* spliced =
                            [self inlineCall:insn
                                      callee:callee
                                      caller:caller
                                       block:bb];
                        if (!spliced)
                            {
                            i++;
                            continue;
                            }
                        [bb.instructions replaceObjectsInRange:NSMakeRange(i, 1)
                                          withObjectsFromArray:spliced];
                        i += spliced.count;
                        }
                    else
                        {
                        if (getenv("XTC_INLINE_TRACE"))
                            fprintf(stderr,
                                    "multiblock-inline %s into %s (guard %lu, blocks→%lu)\n",
                                    callee.name.UTF8String, caller.name.UTF8String,
                                    (unsigned long)guard, (unsigned long)caller.blocks.count);
                        [self multiBlockInline:insn callee:callee caller:caller block:bb index:i];
                        again = YES; // block list changed — rescan caller
                        break;
                        }
                    }
                }
            }
        }
    return YES;
    }

@end
