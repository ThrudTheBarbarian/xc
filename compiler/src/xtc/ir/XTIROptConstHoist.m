#import "XTIROptConstHoist.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"


// Does `a` dominate `b`? By definition: every path from the entry to `b` goes
// through `a`, i.e. `b` is unreachable from the entry once `a` is removed.
//
// Written out here rather than taken from XTIRDominators because the PORT has
// a different dominator implementation, and the two disagreed on real
// functions — which showed up as five new opt-diff divergences. One definition,
// spelled the same way on both sides, is worth more here than a shared one
// that is only nearly shared.
static BOOL chDominates(XTIRFunction* fn, XTIRBlock* a, XTIRBlock* b)
    {
    if (a == b)
        return YES;
    if (fn.blocks.count == 0)
        return NO;
    XTIRBlock* entry = fn.blocks[0];
    if (a == entry)
        return YES;
    NSMutableSet<NSValue*>* seen = [NSMutableSet set];
    NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:entry];
    [seen addObject:[NSValue valueWithNonretainedObject:entry]];
    while (work.count)
        {
        XTIRBlock* n = work.lastObject;
        [work removeLastObject];
        if (n == a)
            continue;                    // removed: do not go through it
        if (!n.terminator)
            continue;
        for (XTIROperand* o in n.terminator.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            NSValue* k = [NSValue valueWithNonretainedObject:o.blockRef];
            if ([seen containsObject:k])
                continue;
            [seen addObject:k];
            [work addObject:o.blockRef];
            }
        }
    return ![seen containsObject:[NSValue valueWithNonretainedObject:b]];
    }

@implementation XTIROptConstHoist

- (NSString*)passName
    {
    return @"const-hoist";
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
        {
        if (!getenv("XTNODEDUPE")) [self runOnFunction:fn module:mod];
        if (!getenv("XTNOMULHOIST")) [self hoistMulImmediates:fn];
        }
    return YES;
    }

// arm64 has no immediate form of `mul`, so every `x * K` in a loop body pays a
// `mov wS, #K` to put the constant somewhere the multiply can read — every
// iteration, once per multiply. call_depth's inlined body does four of them for
// the same literal 3.
//
// Turning the immediate into a Const in the PREHEADER gives it a value the
// allocator can home, and the multiply then reads that register directly. One
// register for a constant used four times in the hottest loop is a good trade;
// if the allocator cannot spare one, `loadValue` rematerialises it and we are
// back where we started.
//
// Loops are recognised by the structural shape every pass here uses: a header
// whose CondBranch goes to a body that branches back to it, with a single other
// predecessor as the preheader.
- (void)hoistMulImmediates:(XTIRFunction*)fn
    {
    NSSet<XTIRBlock*>* bodyBlocks = nil;
    for (XTIRBlock* H in fn.blocks)
        {
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        XTIRBlock* t0 = term.operands[1].blockRef;
        XTIRBlock* t1 = term.operands[2].blockRef;
        // The body is every block reachable from the loop-entry successor
        // without going through the exit — NOT just the latch. By the time this
        // runs the unroller has already turned one body into a chain
        // vu0 -> vu1 -> vu2 -> vu3 -> H, and only the last of those branches
        // back to the header; hoisting from that one alone left three quarters
        // of the multiplies still rebuilding their constant.
        XTIRBlock* B = nil;
        XTIRBlock* E = nil;
        for (NSUInteger pick = 0; pick < 2 && !B; pick++)
            {
            XTIRBlock* entry = pick ? t1 : t0;
            XTIRBlock* other = pick ? t0 : t1;
            if (!entry) continue;
            NSMutableSet<XTIRBlock*>* seen = [NSMutableSet set];
            NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:entry];
            BOOL closes = NO, escaped = NO;
            while (work.count && !escaped)
                {
                XTIRBlock* b = work.lastObject;
                [work removeLastObject];
                if (b == H) { closes = YES; continue; }
                if (b == other || [seen containsObject:b]) continue;
                [seen addObject:b];
                if (!b.terminator) { escaped = YES; break; }
                if (b.terminator.operands.count == 0 &&
                    b.terminator.opcode != XTIROpBranch) { escaped = YES; break; }
                for (XTIROperand* o in b.terminator.operands)
                    if (o.kind == XTIROperandKindBlock && o.blockRef)
                        [work addObject:o.blockRef];
                }
            if (closes && !escaped && seen.count && seen.count <= 8)
                { B = entry; E = other; bodyBlocks = [seen copy]; }
            }
        if (!B)
            continue;

        // The preheader: H's one predecessor that is not the latch.
        XTIRBlock* PH = nil;
        NSUInteger preds = 0, inBody = 0;
        (void)E;
        for (XTIRBlock* p in fn.blocks)
            {
            if (!p.terminator) continue;
            for (XTIROperand* o in p.terminator.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef == H)
                    {
                    preds++;
                    // NOT simply "p != B": B is the loop's ENTRY block, while
                    // the other predecessor of the header is the LATCH, which
                    // is inside the loop. Excluding only B picked the latch as
                    // the preheader and planted the constant after its own
                    // uses — a definition that never runs, and two benchmarks
                    // silently computed the wrong answer.
                    // The preheader is the predecessor OUTSIDE the loop
                    // body, and the latch is the one inside it. Counting both
                    // is what matters: the body walk is capped, a nested loop
                    // overruns the cap, and then NEITHER predecessor is in the
                    // body — both look like preheaders and the last in block
                    // order won, which is the latch. The Const landed inside
                    // the loop with its uses outside it, and the value was
                    // read where it was never defined: sieve on x86-64
                    // computed `ts.sec * ts.sec` for `ts.sec * 1000000` and
                    // printed 1.9e11 microseconds (bug 224).
                    if ([bodyBlocks containsObject:p])
                        inBody++;
                    else if (chDominates(fn, p, H))
                        PH = p;
                    }
            }
        // Exactly one predecessor inside the loop (the latch) and one outside
        // (the preheader). Anything else means the body walk did not describe
        // this loop, and the block it would pick is not a preheader.
        if (!PH || preds != 2 || PH == H)
            continue;

        NSMutableDictionary<NSString*, NSNumber*>* made = [NSMutableDictionary dictionary];
        for (XTIRBlock* body in bodyBlocks)
        for (NSUInteger i = 0; i < body.instructions.count; i++)
            {
            XTIRInsn* insn = body.instructions[i];
            if (insn.opcode != XTIROpMul || !insn.result || insn.operands.count < 2)
                continue;
            NSUInteger side = NSNotFound;
            if (insn.operands[1].kind == XTIROperandKindImmI) side = 1;
            else if (insn.operands[0].kind == XTIROperandKindImmI) side = 0;
            if (side == NSNotFound)
                continue;
            XTIROperand* imm = insn.operands[side];
            XTIRType* ity = imm.type ?: insn.result.type;
            if (!ity)
                continue;
            NSString* key = [NSString stringWithFormat:@"%lld|%u",
                                                       (long long)imm.intValue, (unsigned)ity.kind];
            NSNumber* have = made[key];
            if (!have)
                {
                XTIRValueId cid = [fn allocateValueId];
                XTIRValue* cv = [[XTIRValue alloc] initWithValueId:cid
                                                              type:ity
                                                           defSite:[[XTIRDefSite alloc] initWithBlock:PH
                                                                                            insnIndex:PH.instructions.count]];
                [fn registerValue:cv];
                [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                     result:cv
                                                                   operands:@[ imm ]
                                                                     dbgLoc:insn.dbgLoc]];
                have = @(cid);
                made[key] = have;
                }
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            ops[side] = [XTIROperand useWithValueId:(XTIRValueId)have.unsignedLongLongValue];
            [insn replaceOperands:ops];
            }
        }
    }

// A key for the pointee shape the backend keys element/field strides off — two
// `AddrOf @sym` are mergeable only when these match (same symbol, window, and
// pointee), or a Ptr(U8) base would mis-size a Ptr(Agg) access after the merge.
static NSString* addrPointeeKey(XTIRType* ptrType, XTIRModule* mod)
    {
    XTIRType* p = ptrType.pointeeType;
    if (!p)
        return @"void";
    if (p.kind == XTIRTypeKindAgg)
        {
        NSUInteger idx = [mod.layoutTable indexOfObjectIdenticalTo:p.layout];
        return [NSString stringWithFormat:@"agg%lu", (unsigned long)idx];
        }
    if (p.kind == XTIRTypeKindPtr)
        return [NSString stringWithFormat:@"ptr:%@", addrPointeeKey(p, mod)];
    return [NSString stringWithFormat:@"k%d.w%u", (int)p.kind, p.byteWidth];
    }

// Rebuild an insn with new operands, preserving result/memResult/callConv/pred.
static XTIRInsn* rebuilt(XTIRInsn* insn, NSArray<XTIROperand*>* ops)
    {
    XTIRInsn* r;
    if (insn.callConv)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:ops
                                    callConv:insn.callConv
                                      dbgLoc:insn.dbgLoc];
    else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:ops
                                   predicate:insn.predicate
                                      dbgLoc:insn.dbgLoc];
    else
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:ops
                                      dbgLoc:insn.dbgLoc];
    r.memoryResult = insn.memoryResult;
    return r;
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    if (fn.blocks.count == 0)
        return;
    XTIRBlock* entry = fn.blocks[0];
    BOOL hoistAddr = self.profile.hoistsGlobalAddr;
    BOOL hoistLocal = self.profile.hoistsLocalAddr;

    // A pinned local IS a frame slot, so its address is one value for the
    // whole function however many times it is taken. The unrollers clone the
    // AddrOf with the rest of the body: matrix_mul's k loop unrolls 32 times
    // and ends up with 32 copies of `AddrOf a` and 32 of `AddrOf b`, 64 live
    // values where two would do, which exhausts the register pool and pushes
    // every intermediate in the loop into memory.
    NSMutableSet<NSNumber*>* pinned = [NSMutableSet set];
    for (XTIRPinnedLocal* pl in fn.frameInfo.pinnedLocals)
        [pinned addObject:@(pl.valueId)];

    // Group repeatable defs by a value-equivalence key, in program order:
    //   float Const  → "f:<typekind>:<rawbits>"
    //   AddrOf @sym  → "a:<symbolId>:<windowId>:<pointeeKey>"  (profile-gated)
    // Iterated in FIRST-APPEARANCE order, not the dictionary's: the group
    // order fixes the order the canonicals are inserted at the entry front, so
    // enumerating the dictionary would make the emitted IR a function of
    // NSString hash bucket layout — the same leak fixed in XTIROptPointerIV.
    NSMutableDictionary<NSString*, NSMutableArray<XTIRInsn*>*>* groups =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* groupOrder = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* insn in bb.instructions)
            {
            NSString* key = nil;
            if (insn.opcode == XTIROpConst && insn.result &&
                XTIRTypeKindIsFloating(insn.result.type.kind) &&
                insn.operands.count >= 1 && insn.operands[0].kind == XTIROperandKindImmF)
                {
                key = [NSString stringWithFormat:@"f:%d:%llu",
                                                 (int)insn.result.type.kind,
                                                 (unsigned long long)insn.operands[0].floatRawBytes];
                }
            else if (hoistAddr && insn.opcode == XTIROpAddrOf && insn.result &&
                     insn.result.type.kind == XTIRTypeKindPtr &&
                     insn.operands.count >= 1 &&
                     insn.operands[0].kind == XTIROperandKindSym)
                {
                key = [NSString stringWithFormat:@"a:%llu:%d:%@",
                                                 (unsigned long long)insn.operands[0].symbolId,
                                                 (int)insn.result.type.windowId,
                                                 addrPointeeKey(insn.result.type, mod)];
                }
            else if (hoistLocal && insn.opcode == XTIROpAddrOf && insn.result &&
                     insn.result.type.kind == XTIRTypeKindPtr &&
                     insn.operands.count >= 1 &&
                     insn.operands[0].kind == XTIROperandKindUse &&
                     [pinned containsObject:@(insn.operands[0].valueId)])
                {
                key = [NSString stringWithFormat:@"l:%llu:%d:%@",
                                                 (unsigned long long)insn.operands[0].valueId,
                                                 (int)insn.result.type.windowId,
                                                 addrPointeeKey(insn.result.type, mod)];
                }
            if (!key)
                continue;
            NSMutableArray* g = groups[key];
            if (!g)
                {
                g = [NSMutableArray array];
                groups[key] = g;
                [groupOrder addObject:key];
                }
            [g addObject:insn];
            }
        }

    NSMutableDictionary<NSNumber*, NSNumber*>* replace = [NSMutableDictionary dictionary];
    NSMutableSet<XTIRInsn*>* remove = [NSMutableSet set];
    NSMutableArray<XTIRInsn*>* hoist = [NSMutableArray array];
    for (NSString* key in groupOrder)
        {
        NSArray<XTIRInsn*>* g = groups[key];
        if (g.count < 2)
            continue;            // only dedupe repeats
        XTIRInsn* canon = g[0];  // earliest occurrence
        [hoist addObject:canon]; // relocate to entry front
        for (NSUInteger i = 1; i < g.count; i++)
            {
            replace[@(g[i].result.valueId)] = @(canon.result.valueId);
            [remove addObject:g[i]];
            }
        }
    if (hoist.count == 0)
        return;

    // Drop the duplicates and pull the canonicals out of their blocks.
    [remove addObjectsFromArray:hoist];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSInteger i = (NSInteger)bb.instructions.count - 1; i >= 0; i--)
            if ([remove containsObject:bb.instructions[i]])
                [bb.instructions removeObjectAtIndex:(NSUInteger)i];
        }
    // Insert the canonicals at the front of the entry block (dominates all).
    [entry.instructions insertObjects:hoist
                            atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, hoist.count)]];

    // Rewrite every use of a removed duplicate to its canonical.
    NSArray<XTIROperand*>* (^rew)(XTIRInsn*) = ^NSArray*(XTIRInsn* insn) {
      NSMutableArray<XTIROperand*>* out = nil;
      for (NSUInteger i = 0; i < insn.operands.count; i++)
          {
          XTIROperand* o = insn.operands[i];
          if (o.kind != XTIROperandKindUse)
              continue;
          NSNumber* c = replace[@(o.valueId)];
          if (!c)
              continue;
          if (!out)
              out = [insn.operands mutableCopy];
          out[i] = [XTIROperand useWithValueId:(XTIRValueId)c.unsignedLongLongValue];
          }
      return out;
    };
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.phiNodes.count; i++)
            {
            NSArray* no = rew(bb.phiNodes[i]);
            if (no)
                bb.phiNodes[i] = rebuilt(bb.phiNodes[i], no);
            }
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            NSArray* no = rew(bb.instructions[i]);
            if (no)
                bb.instructions[i] = rebuilt(bb.instructions[i], no);
            }
        if (bb.terminator)
            {
            NSArray* no = rew(bb.terminator);
            if (no)
                {
                XTIRInsn* nt = rebuilt(bb.terminator, no);
                [bb resetTerminator];
                [bb setTerminator:nt];
                }
            }
        }
    }

@end
