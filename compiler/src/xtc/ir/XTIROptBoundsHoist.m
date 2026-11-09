// XTIROptBoundsHoist.m — the bounds-hoist pass (see the header). Every step,
// every name and every value is made in the order the port's
// Opt.boundsHoist (selfhost/opt/OptBoundsElide.xc) makes it, so the two
// compilers write the same code.
#import "XTIROptBoundsHoist.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

@implementation XTIROptBoundsHoist
    {
    XTIRModule* _mod;
    XTIRFunction* _fn;
    XTIRSymbolId _chk;   // _xt_check_bounds
    XTIRSymbolId _lim;   // _xt_check_limit
    }

- (NSString*)passName
    {
    return @"bounds-hoist";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static NSString* symName(XTIRModule* mod, XTIROperand* o)
    {
    if (o.kind != XTIROperandKindSym)
        return nil;
    return [mod symbolForId:o.symbolId].name;
    }

- (BOOL)isCheck:(XTIRInsn*)n
    {
    return n.opcode == XTIROpCall && n.operands.count == 5 && n.operands[0].kind == XTIROperandKindSym
        && [symName(_mod, n.operands[0]) isEqualToString:@"_xt_check_bounds"];
    }

- (BOOL)isLimit:(XTIRInsn*)n
    {
    return n.opcode == XTIROpCall && n.operands.count == 3 && n.operands[0].kind == XTIROperandKindSym
        && [symName(_mod, n.operands[0]) isEqualToString:@"_xt_check_limit"]
        && n.operands[1].kind == XTIROperandKindUse && n.result != nil;
    }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    _mod = mod;
    XTIRFunction* lim = nil;
    for (XTIRFunction* f in mod.functions)
        if ([f.name isEqualToString:@"_xt_check_limit"])
            {
            lim = f;
            break;
            }
    if (!lim)
        return YES;
    XTIRSymbol* ls = [mod symbolForName:@"_xt_check_limit"];
    if (lim.blocks.count > 0 && ls)
        {
        _lim = (XTIRSymbolId)[mod.symbols indexOfObjectIdenticalTo:ls];
        for (XTIRFunction* fn in [mod.functions copy])
            {
            if (fn.blocks.count == 0 || !fn.name || [fn.name hasPrefix:@"_xt_check"] || ![self hasCheck:fn])
                continue;
            _fn = fn;
            NSHashTable<XTIRInsn*>* done = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
            for (NSUInteger guard = 0; guard < 64; guard++)
                if (![self once:done])
                    break;
            }
        }
    // Nothing hoisted: the bound goes, as dead-function-elim would have taken
    // it (it keeps it for this pass while _xt_check_bounds lives).
    for (XTIRFunction* fn in mod.functions)
        {
        if (fn == lim)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* n in bb.instructions)
                for (XTIROperand* o in n.operands)
                    if (o.kind == XTIROperandKindSym && [symName(mod, o) isEqualToString:@"_xt_check_limit"])
                        return YES;
        }
    [mod.functions removeObjectIdenticalTo:lim];
    return YES;
    }

- (BOOL)hasCheck:(XTIRFunction*)fn
    {
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* n in bb.instructions)
            if ([self isCheck:n])
                return YES;
    return NO;
    }

// Nothing in the loop writes but stores, retains and the checks.
- (BOOL)quiet:(NSArray<XTIRBlock*>*)body
    {
    for (XTIRBlock* bb in body)
        for (XTIRInsn* n in bb.instructions)
            {
            switch (n.opcode)
                {
            case XTIROpStore:
            case XTIROpRetain:
                continue;
            case XTIROpCall:
                {
                NSString* nm = n.operands.count > 0 ? symName(_mod, n.operands[0]) : nil;
                if (nm && [nm hasPrefix:@"_xt_check_"])
                    continue;
                return NO;
                }
            case XTIROpStoreVolatile:
            case XTIROpCallIndirect:
            case XTIROpCallCloaked:
            case XTIROpCallBanked:
            case XTIROpCallBankedIndirect:
            case XTIROpMemSet:
            case XTIROpMemCopy:
            case XTIROpRelease:
            case XTIROpWeakRegister:
            case XTIROpWeakUnregister:
            case XTIROpVTblDispatch:
            case XTIROpProtoDispatch:
            case XTIROpAsm:
                return NO;
            default:
                continue;
                }
            }
    return YES;
    }

// A value the loop does not define (a parameter has no definition).
static BOOL outside(XTIROperand* o, NSDictionary<NSNumber*, XTIRBlock*>* defBlk, NSSet<XTIRBlock*>* inBody)
    {
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRBlock* db = defBlk[@(o.valueId)];
    return !db || ![inBody containsObject:db];
    }

static NSArray<XTIRBlock*>* predsIn(NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* preds, XTIRBlock* b)
    {
    NSArray<XTIRBlock*>* ps = [preds objectForKey:b];
    return ps ?: @[];
    }

// One loop's checks guarded and its bounds moved out: the innermost loop
// (fewest blocks) that is quiet, has a preheader and has work.
- (BOOL)once:(NSHashTable<XTIRInsn*>*)done
    {
    NSArray<XTIRBlock*>* blocks = _fn.blocks;
    NSUInteger nb = blocks.count;
    NSMutableArray<NSMutableArray<NSNumber*>*>* predIx = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++)
        [predIx addObject:[NSMutableArray array]];
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* preds = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        XTIRBlock* bb = blocks[bi];
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defBlk[@(p.result.valueId)] = bb;
        for (XTIRInsn* n in bb.instructions)
            {
            if (n.result)
                {
                defBlk[@(n.result.valueId)] = bb;
                defOf[@(n.result.valueId)] = n;
                }
            if (n.memoryResult)
                defBlk[@(n.memoryResult.valueId)] = bb;
            }
        XTIRInsn* t = bb.terminator;
        if (t)
            for (XTIROperand* o in t.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef)
                    {
                    NSUInteger ti = [blocks indexOfObjectIdenticalTo:o.blockRef];
                    if (ti == NSNotFound)
                        continue;
                    [predIx[ti] addObject:@(bi)];
                    NSMutableArray<XTIRBlock*>* ps = [preds objectForKey:o.blockRef];
                    if (!ps)
                        {
                        ps = [NSMutableArray array];
                        [preds setObject:ps forKey:o.blockRef];
                        }
                    [ps addObject:bb];
                    }
        }
    // Dominators, as LICM finds them.
    NSMutableArray<NSMutableIndexSet*>* dom = [NSMutableArray array];
    NSMutableIndexSet* universe = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, nb)];
    for (NSUInteger i = 0; i < nb; i++)
        [dom addObject:(i == 0 ? [NSMutableIndexSet indexSetWithIndex:0] : [universe mutableCopy])];
    BOOL domChanged = YES;
    while (domChanged)
        {
        domChanged = NO;
        for (NSUInteger n = 1; n < nb; n++)
            {
            NSMutableIndexSet* inter = nil;
            for (NSNumber* p in predIx[n])
                {
                if (!inter)
                    inter = [dom[p.unsignedIntegerValue] mutableCopy];
                else
                    {
                    NSMutableIndexSet* diff = [inter mutableCopy];
                    [diff removeIndexes:dom[p.unsignedIntegerValue]];
                    [inter removeIndexes:diff];
                    }
                }
            if (!inter)
                inter = [NSMutableIndexSet indexSet];
            [inter addIndex:n];
            if (![inter isEqualToIndexSet:dom[n]])
                {
                dom[n] = inter;
                domChanged = YES;
                }
            }
        }
    // Each header's loop: the union of the natural loops of its back edges.
    NSMutableArray<XTIRBlock*>* heads = [NSMutableArray array];
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* bodyOf = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* inOf = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger li = 0; li < nb; li++)
        {
        XTIRBlock* latch = blocks[li];
        XTIRInsn* t = latch.terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            NSUInteger hi = [blocks indexOfObjectIdenticalTo:o.blockRef];
            if (hi == NSNotFound || ![dom[li] containsIndex:hi])
                continue;
            XTIRBlock* H = o.blockRef;
            NSMutableArray<XTIRBlock*>* body = [bodyOf objectForKey:H];
            NSMutableSet<XTIRBlock*>* inBody = [inOf objectForKey:H];
            if (!body)
                {
                body = [NSMutableArray arrayWithObject:H];
                inBody = [NSMutableSet setWithObject:H];
                [bodyOf setObject:body forKey:H];
                [inOf setObject:inBody forKey:H];
                [heads addObject:H];
                }
            NSMutableArray<XTIRBlock*>* wl = [NSMutableArray arrayWithObject:latch];
            while (wl.count)
                {
                XTIRBlock* n = wl.lastObject;
                [wl removeLastObject];
                if ([inBody containsObject:n])
                    continue;
                [body addObject:n];
                [inBody addObject:n];
                [wl addObjectsFromArray:predsIn(preds, n)];
                }
            }
        }
    XTIRBlock *bestH = nil, *bestPre = nil;
    for (XTIRBlock* H in heads)
        {
        NSMutableArray<XTIRBlock*>* body = [bodyOf objectForKey:H];
        NSMutableSet<XTIRBlock*>* inBody = [inOf objectForKey:H];
        if (bestH && body.count >= [bodyOf objectForKey:bestH].count)
            continue;
        if (![self hasWork:body in:inBody head:H defs:defBlk defOf:defOf done:done])
            continue;
        XTIRBlock* pre = nil;
        NSUInteger outsideCount = 0;
        for (XTIRBlock* pb in predsIn(preds, H))
            {
            if ([inBody containsObject:pb])
                continue;
            outsideCount++;
            pre = pb;
            }
        if (outsideCount != 1)
            continue;
        NSUInteger hi = [blocks indexOfObjectIdenticalTo:H];
        NSUInteger pi = [blocks indexOfObjectIdenticalTo:pre];
        if (![dom[hi] containsIndex:pi] || ![self quiet:body])
            continue;
        bestH = H;
        bestPre = pre;
        }
    if (!bestH)
        return NO;
    [self hoist:[bodyOf objectForKey:bestH] in:[inOf objectForKey:bestH] head:bestH pre:bestPre defs:defBlk defOf:defOf done:done];
    return YES;
    }

- (BOOL)hasWork:(NSArray<XTIRBlock*>*)body
             in:(NSSet<XTIRBlock*>*)inBody
           head:(XTIRBlock*)H
           defs:(NSDictionary<NSNumber*, XTIRBlock*>*)defBlk
          defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
           done:(NSHashTable<XTIRInsn*>*)done
    {
    BOOL noStore = noStores(body);
    for (XTIRBlock* bb in body)
        for (XTIRInsn* n in bb.instructions)
            {
            if ([self isLimit:n]
                && chain(n.operands[1].valueId, defBlk, defOf, inBody, H, noStore, [NSMutableArray array], 0))
                return YES;
            if ([self isCheck:n] && ![done containsObject:n] && n.operands[2].kind == XTIROperandKindUse
                && n.operands[1].kind == XTIROperandKindUse
                && chain(n.operands[1].valueId, defBlk, defOf, inBody, H, noStore, [NSMutableArray array], 0))
                return YES;
            }
    return NO;
    }

static BOOL noStores(NSArray<XTIRBlock*>* body)
    {
    for (XTIRBlock* bb in body)
        for (XTIRInsn* n in bb.instructions)
            if (n.opcode == XTIROpStore)
                return NO;
    return YES;
    }

// Can v be had before the loop? Defined there, or a field the loop reads of an
// object from before it that the header reads a field of too, in a loop that
// stores nothing (the port's bhChain explains).
static BOOL chain(XTIRValueId v, NSDictionary<NSNumber*, XTIRBlock*>* defBlk, NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                  NSSet<XTIRBlock*>* inBody, XTIRBlock* H, BOOL noStore, NSMutableArray<XTIRInsn*>* out, NSUInteger depth)
    {
    XTIRBlock* db = defBlk[@(v)];
    if (!db || ![inBody containsObject:db])
        return YES;
    XTIRInsn* d = defOf[@(v)];
    if (!d || depth > 4 || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindUse)
        return NO;
    XTIRValueId a = d.operands[0].valueId;
    if (d.opcode == XTIROpBitcast)
        {
        if (!chain(a, defBlk, defOf, inBody, H, noStore, out, depth + 1))
            return NO;
        [out addObject:d];
        return YES;
        }
    if (!noStore || d.opcode != XTIROpLoad)
        return NO;
    XTIRInsn* fa = defOf[@(a)];
    if (!fa || fa.opcode != XTIROpFieldAddr || fa.operands.count < 1 || fa.operands[0].kind != XTIROperandKindUse)
        return NO;
    XTIRValueId x = fa.operands[0].valueId;
    XTIRBlock* xb = defBlk[@(x)];
    if (xb && [inBody containsObject:xb])
        return NO;
    BOOL read = NO;
    for (NSUInteger i = 0; i < H.instructions.count && !read; i++)
        {
        XTIRInsn* n = H.instructions[i];
        if (n.opcode != XTIROpLoad || n.operands.count < 1 || n.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* f = defOf[@(n.operands[0].valueId)];
        read = f && f.opcode == XTIROpFieldAddr && f.operands.count > 0 && f.operands[0].kind == XTIROperandKindUse
            && f.operands[0].valueId == x;
        }
    if (!read)
        return NO;
    XTIRBlock* ab = defBlk[@(a)];
    if (ab && [inBody containsObject:ab])
        [out addObject:fa];
    [out addObject:d];
    return YES;
    }

// The instructions chain listed, moved to the end of the preheader. Each is
// looked for in the body's blocks: a split may have moved it on from the block
// that defined it.
static void move(NSArray<XTIRInsn*>* out, NSArray<XTIRBlock*>* body, XTIRBlock* pre,
                 NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk)
    {
    for (XTIRInsn* n in out)
        {
        if (defBlk[@(n.result.valueId)] == pre)
            continue;
        for (XTIRBlock* from in body)
            {
            NSUInteger at = [from.instructions indexOfObjectIdenticalTo:n];
            if (at != NSNotFound)
                {
                [from.instructions removeObjectAtIndex:at];
                break;
                }
            }
        [pre.instructions addObject:n];
        defBlk[@(n.result.valueId)] = pre;
        if (n.memoryResult)
            defBlk[@(n.memoryResult.valueId)] = pre;
        }
    }

- (XTIRValue*)value:(XTIRType*)ty in:(XTIRBlock*)b
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[_fn allocateValueId]
                                                 type:ty
                                              defSite:[[XTIRDefSite alloc] initWithBlock:b insnIndex:0]];
    [_fn registerValue:v];
    return v;
    }

static void retargetPhis(XTIRBlock* s, XTIRBlock* from, XTIRBlock* to)
    {
    for (XTIRInsn* ph in s.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger q = 0; q < ph.operands.count; q++)
            if (ph.operands[q].kind == XTIROperandKindBlock && ph.operands[q].blockRef == from)
                {
                if (!ops)
                    ops = [ph.operands mutableCopy];
                ops[q] = [XTIROperand blockWithRef:to];
                }
        if (ops)
            [ph replaceOperands:ops];
        }
    }

static void replaceUses(XTIRInsn* n, XTIRValueId old, XTIROperand* to)
    {
    NSMutableArray<XTIROperand*>* ops = nil;
    for (NSUInteger k = 0; k < n.operands.count; k++)
        if (n.operands[k].kind == XTIROperandKindUse && n.operands[k].valueId == old)
            {
            if (!ops)
                ops = [n.operands mutableCopy];
            ops[k] = to;
            }
    if (ops)
        [n replaceOperands:ops];
    }

- (void)rewriteUses:(XTIRValueId)old to:(XTIROperand*)to
    {
    for (XTIRBlock* bb in _fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            replaceUses(p, old, to);
        for (XTIRInsn* n in bb.instructions)
            replaceUses(n, old, to);
        if (bb.terminator)
            replaceUses(bb.terminator, old, to);
        }
    }

- (void)hoist:(NSMutableArray<XTIRBlock*>*)body
           in:(NSMutableSet<XTIRBlock*>*)inBody
         head:(XTIRBlock*)H
          pre:(XTIRBlock*)pre
         defs:(NSMutableDictionary<NSNumber*, XTIRBlock*>*)defBlk
        defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
         done:(NSHashTable<XTIRInsn*>*)done
    {
    BOOL noStore = noStores(body);
    NSMutableDictionary<NSNumber*, XTIRValue*>* limOf = [NSMutableDictionary dictionary];
    // The bounds an inner loop computed, moved on out. A second for the same
    // pointer takes the first's value.
    for (NSUInteger b = 0; b < body.count; b++)
        {
        XTIRBlock* bb = body[b];
        NSUInteger i = 0;
        while (i < bb.instructions.count)
            {
            XTIRInsn* n = bb.instructions[i];
            NSMutableArray<XTIRInsn*>* ch = [NSMutableArray array];
            if (![self isLimit:n] || !chain(n.operands[1].valueId, defBlk, defOf, inBody, H, noStore, ch, 0))
                {
                i++;
                continue;
                }
            [bb.instructions removeObjectAtIndex:i];
            move(ch, body, pre, defBlk);
            i = 0; // the move may have taken instructions before it
            NSNumber* p = @(n.operands[1].valueId);
            XTIRValue* had = limOf[p];
            if (had)
                {
                [self rewriteUses:n.result.valueId to:[XTIROperand useWithValueId:had.valueId]];
                continue;
                }
            [pre.instructions addObject:n];
            limOf[p] = n.result;
            }
        }
    // Each check on a pointer from outside: B[..i) + `i >= bound` | the check
    // | B(i..] + B's terminator.
    NSUInteger b = 0;
    while (b < body.count)
        {
        XTIRBlock* bb = body[b];
        b++;
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* n = bb.instructions[i];
            if (![self isCheck:n] || [done containsObject:n])
                continue;
            XTIROperand* po = n.operands[1];
            XTIROperand* io = n.operands[2];
            NSMutableArray<XTIRInsn*>* ch = [NSMutableArray array];
            if (io.kind != XTIROperandKindUse || po.kind != XTIROperandKindUse
                || !chain(po.valueId, defBlk, defOf, inBody, H, noStore, ch, 0))
                continue;
            move(ch, body, pre, defBlk);
            // The move may have taken instructions before it.
            i = [bb.instructions indexOfObjectIdenticalTo:n];
            [done addObject:n];
            XTIRValue* lim = limOf[@(po.valueId)];
            if (!lim)
                {
                XTIROperand* mo = n.operands.lastObject;
                if (!outside(mo, defBlk, inBody))
                    mo = [XTIROperand useWithValueId:(XTIRValueId)(_fn.paramTypes.count - 1)];
                lim = [self value:[XTIRType u64Type] in:pre];
                XTIRInsn* lc = [[XTIRInsn alloc] initWithOpcode:XTIROpCall
                                                         result:lim
                                                       operands:@[ [XTIROperand symWithSymbolId:_lim],
                                                                   [XTIROperand useWithValueId:po.valueId], mo ]
                                                       callConv:[XTIRCallConv standard]
                                                         dbgLoc:n.dbgLoc];
                lc.memoryResult = [self value:[XTIRType memoryType] in:pre];
                [pre.instructions addObject:lc];
                limOf[@(po.valueId)] = lim;
                }
            XTIRValue* past = [self value:[XTIRType boolType] in:bb];
            XTIRInsn* cmp = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                      result:past
                                                    operands:@[ io, [XTIROperand useWithValueId:lim.valueId] ]
                                                   predicate:XTIRICmpUGE
                                                      dbgLoc:n.dbgLoc];
            NSUInteger tag = _fn.blocks.count;
            XTIRBlock* cont = [[XTIRBlock alloc] init];
            cont.name = [NSString stringWithFormat:@"bh%lu_cont", (unsigned long)tag];
            XTIRBlock* slow = [[XTIRBlock alloc] init];
            slow.name = [NSString stringWithFormat:@"bh%lu_check", (unsigned long)tag];
            // The split: what follows the check, and B's terminator, go to cont.
            for (NSUInteger k = i + 1; k < bb.instructions.count; k++)
                [cont.instructions addObject:bb.instructions[k]];
            [bb.instructions removeObjectsInRange:NSMakeRange(i, bb.instructions.count - i)];
            XTIRInsn* t = bb.terminator;
            if (t)
                {
                [bb resetTerminator];
                [cont setTerminator:t];
                for (XTIROperand* o in t.operands)
                    if (o.kind == XTIROperandKindBlock && o.blockRef)
                        retargetPhis(o.blockRef, bb, cont);
                }
            [bb.instructions addObject:cmp];
            [bb setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                        result:nil
                                                      operands:@[ [XTIROperand useWithValueId:past.valueId],
                                                                  [XTIROperand blockWithRef:slow],
                                                                  [XTIROperand blockWithRef:cont] ]
                                                        dbgLoc:nil]];
            // The check keeps its memory token, which what follows it reads
            // (as the devirtualised dispatch's does).
            [slow.instructions addObject:n];
            [slow setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                          result:nil
                                                        operands:@[ [XTIROperand blockWithRef:cont] ]
                                                          dbgLoc:nil]];
            [_fn.blocks insertObject:cont atIndex:[_fn.blocks indexOfObjectIdenticalTo:bb] + 1];
            [_fn.blocks addObject:slow];
            [body addObject:cont];
            [inBody addObject:cont];
            break;
            }
        }
    }

@end
