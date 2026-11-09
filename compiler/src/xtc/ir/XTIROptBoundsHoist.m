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
    NSArray<NSIndexSet*>* _dom;                  // a round's dominators, by block index
    NSMapTable<XTIRBlock*, NSNumber*>* _ix;      // a round's block indices
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
    _dom = dom;
    _ix = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger i = 0; i < nb; i++)
        [_ix setObject:@(i) forKey:blocks[i]];
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
        NSArray<XTIRBlock*>* exits = sureExits([self exitsOf:body in:inBody head:H], H, [self guardable:H in:inBody]);
        if (![self hasWork:body in:inBody head:H exits:exits defs:defBlk defOf:defOf done:done])
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
        NSUInteger pix = [blocks indexOfObjectIdenticalTo:pre];
        if (![dom[hi] containsIndex:pix] || ![self quiet:body])
            continue;
        bestH = H;
        bestPre = pre;
        }
    if (!bestH)
        return NO;
    NSMutableArray<XTIRBlock*>* bestBody = [bodyOf objectForKey:bestH];
    NSMutableSet<XTIRBlock*>* bestIn = [inOf objectForKey:bestH];
    BOOL guarded = [self guardable:bestH in:bestIn];
    [self hoist:bestBody in:bestIn head:bestH pre:bestPre
          exits:sureExits([self exitsOf:bestBody in:bestIn head:bestH], bestH, guarded) guarded:guarded
           defs:defBlk defOf:defOf done:done];
    return YES;
    }

// The loop's blocks that go round it again or leave it: its latches, the
// blocks with an edge out, and any that end otherwise (a Return).
- (NSArray<XTIRBlock*>*)exitsOf:(NSArray<XTIRBlock*>*)body in:(NSSet<XTIRBlock*>*)inBody head:(XTIRBlock*)H
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    for (XTIRBlock* bb in body)
        {
        XTIRInsn* t = bb.terminator;
        BOOL ex = !t || !(t.opcode == XTIROpBranch || t.opcode == XTIROpCondBranch);
        if (t)
            for (XTIROperand* o in t.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef && [_fn.blocks indexOfObjectIdenticalTo:o.blockRef] != NSNotFound
                    && (o.blockRef == H || ![inBody containsObject:o.blockRef]))
                    ex = YES;
        if (ex)
            [out addObject:bb];
        }
    return out;
    }

// Does every way round the loop and out of it pass through X? Then once the
// loop is entered X runs, and what X reads may be read before the loop (the
// port's bhSure explains).
- (BOOL)sure:(XTIRBlock*)X exits:(NSArray<XTIRBlock*>*)exits
    {
    NSNumber* xi = [_ix objectForKey:X];
    if (!xi)
        return NO;
    for (XTIRBlock* e in exits)
        {
        NSNumber* ei = [_ix objectForKey:e];
        if (!ei || ![_dom[ei.unsignedIntegerValue] containsIndex:xi.unsignedIntegerValue])
            return NO;
        }
    return YES;
    }

- (BOOL)hasWork:(NSArray<XTIRBlock*>*)body
             in:(NSSet<XTIRBlock*>*)inBody
           head:(XTIRBlock*)H
          exits:(NSArray<XTIRBlock*>*)exits
           defs:(NSDictionary<NSNumber*, XTIRBlock*>*)defBlk
          defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
           done:(NSHashTable<XTIRInsn*>*)done
    {
    BOOL noStore = noStores(body);
    for (XTIRBlock* bb in body)
        {
        if (![self sure:bb exits:exits])
            continue;
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
    if (!d || depth > 8)
        return NO;
    // Arithmetic, casts and compares of values the loop can have (the port's
    // bhChain explains).
    if (pureOp(d.opcode))
        {
        for (XTIROperand* o in d.operands)
            if (o.kind == XTIROperandKindUse && !chain(o.valueId, defBlk, defOf, inBody, H, noStore, out, depth + 1))
                return NO;
        if ([out indexOfObjectIdenticalTo:d] == NSNotFound)
            [out addObject:d];
        return YES;
        }
    if (d.operands.count < 1 || d.operands[0].kind != XTIROperandKindUse)
        return NO;
    XTIRValueId a = d.operands[0].valueId;
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
    if (ab && [inBody containsObject:ab] && [out indexOfObjectIdenticalTo:fa] == NSNotFound)
        [out addObject:fa];
    if ([out indexOfObjectIdenticalTo:d] == NSNotFound)
        [out addObject:d];
    return YES;
    }

static BOOL pureOp(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpBitcast:
    case XTIROpSelect:
    case XTIROpICmp:
    case XTIROpConst:
    case XTIROpIntToPtr:
    case XTIROpPtrToInt:
    case XTIROpZExt:
    case XTIROpSExt:
    case XTIROpTrunc:
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
        return YES;
    default:
        return NO;
        }
    }

// Does H leave the loop through a CondBranch with one edge in, holding nothing
// that writes or calls? Then a copy of it before the loop says whether the
// body runs at all (the guard).
- (BOOL)guardable:(XTIRBlock*)H in:(NSSet<XTIRBlock*>*)inBody
    {
    XTIRInsn* t = H.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count != 3 || t.operands[1].kind != XTIROperandKindBlock
        || t.operands[2].kind != XTIROperandKindBlock)
        return NO;
    BOOL in1 = [inBody containsObject:t.operands[1].blockRef];
    BOOL in2 = [inBody containsObject:t.operands[2].blockRef];
    if (in1 == in2)
        return NO;
    for (XTIRInsn* n in H.instructions)
        switch (n.opcode)
            {
        case XTIROpStore:
        case XTIROpStoreVolatile:
        case XTIROpLoadVolatile:
        case XTIROpCall:
        case XTIROpCallIndirect:
        case XTIROpCallCloaked:
        case XTIROpCallBanked:
        case XTIROpCallBankedIndirect:
        case XTIROpMemSet:
        case XTIROpMemCopy:
        case XTIROpRetain:
        case XTIROpRelease:
        case XTIROpWeakRegister:
        case XTIROpWeakUnregister:
        case XTIROpVTblDispatch:
        case XTIROpProtoDispatch:
        case XTIROpAsm:
            return NO;
        default:
            break;
            }
    return YES;
    }

// The exits sure: asks about: with a guard, not H's own.
static NSArray<XTIRBlock*>* sureExits(NSArray<XTIRBlock*>* exits, XTIRBlock* H, BOOL guarded)
    {
    if (!guarded)
        return exits;
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    for (XTIRBlock* b in exits)
        if (b != H)
            [out addObject:b];
    return out;
    }

// `enter ? p : null` (or the other way round), at the end of e.
- (XTIRValueId)gate:(XTIRBlock*)e enter:(XTIRValueId)enter sense:(BOOL)sense p:(XTIROperand*)p at:(XTIRInsn*)at
    {
    XTIRType* pt = [_fn valueForId:p.valueId].type;
    XTIRValue* z = [self value:[XTIRType u8Type] in:e];
    [e.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                        result:z
                                                      operands:@[ [XTIROperand immIWithType:[XTIRType u8Type] value:0] ]
                                                        dbgLoc:nil]];
    XTIRValue* np = [self value:pt in:e];
    [e.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpIntToPtr
                                                        result:np
                                                      operands:@[ [XTIROperand useWithValueId:z.valueId] ]
                                                        dbgLoc:nil]];
    XTIRValue* g = [self value:pt in:e];
    XTIROperand* nul = [XTIROperand useWithValueId:np.valueId];
    [e.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                        result:g
                                                      operands:@[ [XTIROperand useWithValueId:enter], sense ? p : nul, sense ? nul : p ]
                                                        dbgLoc:at.dbgLoc]];
    return g.valueId;
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

// A copy of insn with new operands and results (XTIROptInline's rebuildInsn).
static XTIRInsn* rebuild(XTIRInsn* insn, XTIRValue* result, NSArray<XTIROperand*>* ops, XTIRValue* memResult)
    {
    XTIRInsn* out;
    if (insn.callConv)
        out = [[XTIRInsn alloc] initWithOpcode:insn.opcode result:result operands:ops callConv:insn.callConv dbgLoc:insn.dbgLoc];
    else if (XTIROpCarriesPredicate(insn.opcode))
        out = [[XTIRInsn alloc] initWithOpcode:insn.opcode result:result operands:ops predicate:insn.predicate dbgLoc:insn.dbgLoc];
    else
        out = [[XTIRInsn alloc] initWithOpcode:insn.opcode result:result operands:ops dbgLoc:insn.dbgLoc];
    out.memoryResult = memResult;
    return out;
    }

// A terminator's every edge to `from` goes to `to`.
static void replaceBlock(XTIRInsn* t, XTIRBlock* from, XTIRBlock* to)
    {
    NSMutableArray<XTIROperand*>* ops = nil;
    for (NSUInteger k = 0; k < t.operands.count; k++)
        if (t.operands[k].kind == XTIROperandKindBlock && t.operands[k].blockRef == from)
            {
            if (!ops)
                ops = [t.operands mutableCopy];
            ops[k] = [XTIROperand blockWithRef:to];
            }
    if (ops)
        [t replaceOperands:ops];
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
        exits:(NSArray<XTIRBlock*>*)exits
      guarded:(BOOL)guarded
         defs:(NSMutableDictionary<NSNumber*, XTIRBlock*>*)defBlk
        defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
         done:(NSHashTable<XTIRInsn*>*)done
    {
    BOOL noStore = noStores(body);
    NSMutableDictionary<NSNumber*, XTIRValue*>* limOf = [NSMutableDictionary dictionary];
    // What is hoisted runs only when the loop is entered: a preheader that may
    // go elsewhere (a rotated loop's trip test) gets a block of its own on the
    // edge into the loop.
    if (guarded || !pre.terminator || pre.terminator.opcode != XTIROpBranch)
        {
        XTIRBlock* e = [[XTIRBlock alloc] init];
        e.name = [NSString stringWithFormat:@"bh%lu_pre", (unsigned long)_fn.blocks.count];
        [e setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                   result:nil
                                                 operands:@[ [XTIROperand blockWithRef:H] ]
                                                   dbgLoc:nil]];
        XTIRInsn* pt = pre.terminator;
        if (pt)
            replaceBlock(pt, H, e);
        retargetPhis(H, pre, e);
        [_fn.blocks insertObject:e atIndex:[_fn.blocks indexOfObjectIdenticalTo:pre] + 1];
        pre = e;
        }
    // The guard: H's instructions again in the new preheader, each phi read as
    // the value it takes on entry, and H's condition.
    XTIRValueId enter = 0;
    BOOL haveEnter = NO, sense = YES;
    if (guarded)
        {
        NSMutableDictionary<NSNumber*, XTIROperand*>* remap = [NSMutableDictionary dictionary];
        for (XTIRInsn* phi in H.phiNodes)
            for (NSUInteger j = 0; j + 1 < phi.operands.count; j += 2)
                if (phi.operands[j].kind == XTIROperandKindBlock && phi.operands[j].blockRef == pre && phi.result)
                    remap[@(phi.result.valueId)] = phi.operands[j + 1];
        XTIROperand* (^subst)(XTIROperand*) = ^XTIROperand*(XTIROperand* o) {
          if (o.kind == XTIROperandKindUse && remap[@(o.valueId)])
              return remap[@(o.valueId)];
          return o;
        };
        for (XTIRInsn* n in H.instructions)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
            for (XTIROperand* o in n.operands)
                [ops addObject:subst(o)];
            XTIRValue* r = n.result ? [self value:n.result.type in:pre] : nil;
            if (r)
                remap[@(n.result.valueId)] = [XTIROperand useWithValueId:r.valueId];
            XTIRValue* m = n.memoryResult ? [self value:n.memoryResult.type in:pre] : nil;
            if (m)
                remap[@(n.memoryResult.valueId)] = [XTIROperand useWithValueId:m.valueId];
            [pre.instructions addObject:rebuild(n, r, ops, m)];
            }
        XTIRInsn* t = H.terminator;
        XTIROperand* co = subst(t.operands[0]);
        if (co.kind != XTIROperandKindUse)
            {
            XTIRValue* cv = [self value:[XTIRType boolType] in:pre];
            [pre.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst result:cv operands:@[ co ] dbgLoc:nil]];
            co = [XTIROperand useWithValueId:cv.valueId];
            }
        enter = co.valueId;
        haveEnter = YES;
        sense = [inBody containsObject:t.operands[1].blockRef];
        }
    // The block each of the body's blocks was split from, for sure:.
    NSMapTable<XTIRBlock*, XTIRBlock*>* origOf = [NSMapTable strongToStrongObjectsMapTable];
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
            if (![self isLimit:n] || ![self sure:bb exits:exits] || !chain(n.operands[1].valueId, defBlk, defOf, inBody, H, noStore, ch, 0))
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
            if (haveEnter)
                {
                NSMutableArray<XTIROperand*>* ops = [n.operands mutableCopy];
                ops[1] = [XTIROperand useWithValueId:[self gate:pre enter:enter sense:sense p:n.operands[1] at:n]];
                [n replaceOperands:ops];
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
            XTIRBlock* ob = [origOf objectForKey:bb];
            if (io.kind != XTIROperandKindUse || po.kind != XTIROperandKindUse || ![self sure:(ob ?: bb) exits:exits]
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
                XTIRValue* lm = [self value:[XTIRType memoryType] in:pre];
                XTIRValueId arg = haveEnter ? [self gate:pre enter:enter sense:sense p:po at:n] : po.valueId;
                XTIRInsn* lc = [[XTIRInsn alloc] initWithOpcode:XTIROpCall
                                                         result:lim
                                                       operands:@[ [XTIROperand symWithSymbolId:_lim],
                                                                   [XTIROperand useWithValueId:arg], mo ]
                                                       callConv:[XTIRCallConv standard]
                                                         dbgLoc:n.dbgLoc];
                lc.memoryResult = lm;
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
            [origOf setObject:(ob ?: bb) forKey:cont];
            break;
            }
        }
    }

@end

// ── bounds-version ─────────────────────────────────────────────────────────
// A counted loop whose hoisted checks are on p[i] runs an unchecked copy when
// its trip count is within every bound (the port's Opt.boundsVersion explains).
// Every value and block is made in the port's order.

@implementation XTIROptBoundsVersion
    {
    XTIRModule* _mod;
    XTIRFunction* _fn;
    }

- (NSString*)passName
    {
    return @"bounds-version";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static BOOL bvIsHeapCheck(XTIRModule* mod, XTIRInsn* n)
    {
    return n.opcode == XTIROpCall && n.operands.count == 5 && n.operands[0].kind == XTIROperandKindSym
        && [[mod symbolForId:n.operands[0].symbolId].name isEqualToString:@"_xt_check_bounds"];
    }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    _mod = mod;
    for (XTIRFunction* fn in [mod.functions copy])
        {
        if (fn.blocks.count == 0 || !fn.name || [fn.name hasPrefix:@"_xt_check"])
            continue;
        BOOL any = NO;
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* n in bb.instructions)
                if (bvIsHeapCheck(mod, n))
                    any = YES;
        if (!any)
            continue;
        _fn = fn;
        NSHashTable<XTIRBlock*>* seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        for (NSUInteger guard = 0; guard < 64; guard++)
            if (![self once:seen])
                break;
        }
    return YES;
    }

- (XTIRValue*)value:(XTIRType*)ty
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[_fn allocateValueId]
                                                 type:ty
                                              defSite:[[XTIRDefSite alloc] initWithBlock:_fn.blocks[0] insnIndex:0]];
    [_fn registerValue:v];
    return v;
    }

- (BOOL)guard:(XTIRBlock*)B defs:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
    {
    XTIRInsn* t = B.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count != 3 || t.operands[0].kind != XTIROperandKindUse
        || t.operands[1].kind != XTIROperandKindBlock || t.operands[2].kind != XTIROperandKindBlock)
        return NO;
    XTIRBlock* slow = t.operands[1].blockRef;
    XTIRBlock* cont = t.operands[2].blockRef;
    if (slow.instructions.count != 1 || !bvIsHeapCheck(_mod, slow.instructions[0]) || slow.phiNodes.count > 0
        || !slow.terminator || slow.terminator.opcode != XTIROpBranch || slow.terminator.operands[0].blockRef != cont
        || cont.phiNodes.count > 0)
        return NO;
    XTIRInsn* c = defOf[@(t.operands[0].valueId)];
    return c && c.opcode == XTIROpICmp && c.predicate == XTIRICmpUGE && c.operands.count == 2
        && c.operands[0].kind == XTIROperandKindUse && c.operands[1].kind == XTIROperandKindUse;
    }

// 1 as an operand: an immediate, or a Const through the width casts.
static BOOL bvOne(XTIROperand* o, NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    for (int hop = 0; hop < 4; hop++)
        {
        if (o.kind == XTIROperandKindImmI)
            return o.intValue == 1;
        if (o.kind != XTIROperandKindUse)
            return NO;
        XTIRInsn* d = defOf[@(o.valueId)];
        if (!d || d.operands.count != 1)
            return NO;
        if (d.opcode != XTIROpConst && d.opcode != XTIROpZExt && d.opcode != XTIROpSExt && d.opcode != XTIROpTrunc)
            return NO;
        o = d.operands[0];
        }
    return NO;
    }

static BOOL isU32(XTIRType* t) { return t.kind == XTIRTypeKindU32; }
static BOOL isU64(XTIRType* t) { return t.kind == XTIRTypeKindU64; }

- (BOOL)once:(NSHashTable<XTIRBlock*>*)seen
    {
    NSArray<XTIRBlock*>* blocks = [_fn.blocks copy];
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
                {
                defBlk[@(p.result.valueId)] = bb;
                defOf[@(p.result.valueId)] = p;
                }
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
    NSMutableArray<XTIRBlock*>* heads = [NSMutableArray array];
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* bodyOf = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* inOf = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock*, XTIRBlock*>* latchOf = [NSMapTable strongToStrongObjectsMapTable];
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
                [latchOf setObject:latch forKey:H];
                }
            else if ([latchOf objectForKey:H] != latch)
                [latchOf setObject:H forKey:H];
            NSMutableArray<XTIRBlock*>* wl = [NSMutableArray arrayWithObject:latch];
            while (wl.count)
                {
                XTIRBlock* n = wl.lastObject;
                [wl removeLastObject];
                if ([inBody containsObject:n])
                    continue;
                [body addObject:n];
                [inBody addObject:n];
                NSArray<XTIRBlock*>* ps = [preds objectForKey:n];
                if (ps)
                    [wl addObjectsFromArray:ps];
                }
            }
        }
    for (XTIRBlock* H in heads)
        {
        if ([seen containsObject:H])
            continue;
        [seen addObject:H];
        NSMutableArray<XTIRBlock*>* body = [bodyOf objectForKey:H];
        NSMutableSet<XTIRBlock*>* inBody = [inOf objectForKey:H];
        XTIRBlock* L = [latchOf objectForKey:H];
        BOOL inner = YES;
        for (XTIRBlock* h2 in heads)
            if (h2 != H && [inBody containsObject:h2])
                inner = NO;
        if (!inner || L == H)
            continue;
        if ([self tryLoop:H latch:L body:body in:inBody preds:preds dom:dom blocks:blocks defs:defBlk defOf:defOf])
            return YES;
        }
    return NO;
    }

- (BOOL)tryLoop:(XTIRBlock*)H
          latch:(XTIRBlock*)L
           body:(NSArray<XTIRBlock*>*)body
             in:(NSSet<XTIRBlock*>*)inBody
          preds:(NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>*)preds
            dom:(NSArray<NSIndexSet*>*)dom
         blocks:(NSArray<XTIRBlock*>*)blocks
           defs:(NSDictionary<NSNumber*, XTIRBlock*>*)defBlk
          defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
    {
    XTIRBlock* P = nil;
    for (XTIRBlock* q in ([preds objectForKey:H] ?: @[]))
        {
        if ([inBody containsObject:q])
            continue;
        if (P)
            return NO;
        P = q;
        }
    if (!P || !P.terminator || P.terminator.opcode != XTIROpBranch)
        return NO;
    XTIRInsn* t = H.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count != 3 || t.operands[0].kind != XTIROperandKindUse)
        return NO;
    XTIRBlock* S = t.operands[1].blockRef;
    XTIRBlock* X = t.operands[2].blockRef;
    if (!S || !X || ![inBody containsObject:S] || [inBody containsObject:X])
        return NO;
    if ([[preds objectForKey:X] ?: @[] count] != 1)
        return NO;
    XTIRInsn* c = defOf[@(t.operands[0].valueId)];
    if (!c || c.opcode != XTIROpICmp || c.predicate != XTIRICmpULT || c.operands.count != 2
        || c.operands[0].kind != XTIROperandKindUse || c.operands[1].kind != XTIROperandKindUse)
        return NO;
    XTIRValueId iv = c.operands[0].valueId;
    XTIRValueId nv = c.operands[1].valueId;
    XTIRInsn* phi = defOf[@(iv)];
    XTIRType* ivt = [_fn valueForId:iv].type;
    if (!phi || phi.opcode != XTIROpPhi || defBlk[@(iv)] != H || phi.operands.count != 4 || !ivt || !(isU32(ivt) || isU64(ivt)))
        return NO;
    XTIROperand* step = nil;
    for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
        if (phi.operands[q].blockRef == L)
            step = phi.operands[q + 1];
    if (!step || step.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* add = defOf[@(step.valueId)];
    if (!add || add.opcode != XTIROpAdd || add.operands.count != 2 || add.operands[0].kind != XTIROperandKindUse
        || add.operands[0].valueId != iv || !bvOne(add.operands[1], defOf))
        return NO;
    NSMutableArray<XTIRInsn*>* nchain = [NSMutableArray array];
    if (!chain(nv, defBlk, defOf, inBody, H, noStores(body), nchain, 0))
        return NO;
    NSMutableArray<XTIRBlock*>* guards = [NSMutableArray array];
    NSMutableArray<NSNumber*>* bounds = [NSMutableArray array];
    NSMutableArray* offs = [NSMutableArray array];   // per guard: k for p[k + i], else NSNull
    NSUInteger size = 0;
    for (XTIRBlock* bb in body)
        {
        size += bb.instructions.count + bb.phiNodes.count;
        // An edge out of the loop to anywhere but X must find no phi there.
        if (bb.terminator)
            for (XTIROperand* o in bb.terminator.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef && o.blockRef != X && ![inBody containsObject:o.blockRef]
                    && o.blockRef.phiNodes.count > 0)
                    return NO;
        if (![self guard:bb defs:defOf])
            continue;
        XTIRInsn* cmp = defOf[@(bb.terminator.operands[0].valueId)];
        XTIRValueId idx = cmp.operands[0].valueId;
        XTIRValueId lim = cmp.operands[1].valueId;
        XTIRBlock* lb = defBlk[@(lim)];
        if (!lb || [inBody containsObject:lb])
            continue;
        XTIRInsn* z = defOf[@(idx)];
        BOOL onI = idx == iv || (z && z.opcode == XTIROpZExt && z.operands.count == 1 && z.operands[0].kind == XTIROperandKindUse
                                 && z.operands[0].valueId == iv);
        // p[k + i], k a u32 from before the loop and i a u32 (the port's
        // bvTry explains).
        id off = [NSNull null];
        if (!onI)
            {
            XTIRInsn* a = (z && z.opcode == XTIROpZExt && z.operands.count == 1 && z.operands[0].kind == XTIROperandKindUse)
                ? defOf[@(z.operands[0].valueId)] : nil;
            if (!a || a.opcode != XTIROpAdd || a.operands.count != 2 || !isU32(ivt))
                continue;
            XTIROperand* a0 = a.operands[0];
            XTIROperand* a1 = a.operands[1];
            XTIROperand* ko = (a0.kind == XTIROperandKindUse && a0.valueId == iv) ? a1
                            : ((a1.kind == XTIROperandKindUse && a1.valueId == iv) ? a0 : nil);
            if (!ko || ko.kind != XTIROperandKindUse || !isU32([_fn valueForId:ko.valueId].type))
                continue;
            XTIRBlock* kb = defBlk[@(ko.valueId)];
            if (kb && [inBody containsObject:kb])
                continue;
            off = @(ko.valueId);
            }
        [guards addObject:bb];
        [bounds addObject:@(lim)];
        [offs addObject:off];
        }
    if (guards.count == 0 || size > 96)
        return NO;
    NSMutableArray<XTIRBlock*>* bodyOrder = [NSMutableArray array];
    for (XTIRBlock* b in _fn.blocks)
        if ([inBody containsObject:b])
            [bodyOrder addObject:b];
    NSUInteger xi = [blocks indexOfObjectIdenticalTo:X];
    for (NSUInteger bi = 0; bi < blocks.count; bi++)
        {
        XTIRBlock* ob = blocks[bi];
        if ([inBody containsObject:ob] || [dom[bi] containsIndex:xi])
            continue;
        if (usesLoop(ob, inBody, defBlk, _fn))
            return NO;
        }
    [self applyLoop:H latch:L pre:P exit:X body:bodyOrder in:inBody guards:guards bounds:bounds offs:offs n:nv chain:nchain];
    return YES;
    }

static BOOL usesLoop(XTIRBlock* ob, NSSet<XTIRBlock*>* inBody, NSDictionary<NSNumber*, XTIRBlock*>* defBlk, XTIRFunction* fn)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:ob.phiNodes];
    [all addObjectsFromArray:ob.instructions];
    if (ob.terminator)
        [all addObject:ob.terminator];
    for (XTIRInsn* u in all)
        for (XTIROperand* o in u.operands)
            {
            if (o.kind != XTIROperandKindUse)
                continue;
            XTIRValue* v = [fn valueForId:o.valueId];
            if (v && v.type.kind == XTIRTypeKindMemory)
                continue;
            XTIRBlock* db = defBlk[@(o.valueId)];
            if (db && [inBody containsObject:db])
                return YES;
            }
    return NO;
    }

- (XTIROperand*)map:(XTIROperand*)o values:(NSDictionary<NSNumber*, XTIRValue*>*)vmap
             blocks:(NSMapTable<XTIRBlock*, XTIRBlock*>*)bmap
    {
    if (o.kind == XTIROperandKindUse)
        {
        XTIRValue* nv = vmap[@(o.valueId)];
        return nv ? [XTIROperand useWithValueId:nv.valueId] : o;
        }
    if (o.kind == XTIROperandKindBlock && o.blockRef)
        {
        XTIRBlock* nb = bmap ? [bmap objectForKey:o.blockRef] : nil;
        return nb ? [XTIROperand blockWithRef:nb] : o;
        }
    return o;
    }

- (XTIRInsn*)clone:(XTIRInsn*)n values:(NSDictionary<NSNumber*, XTIRValue*>*)vmap
            blocks:(NSMapTable<XTIRBlock*, XTIRBlock*>*)bmap
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
    for (XTIROperand* o in n.operands)
        [ops addObject:[self map:o values:vmap blocks:bmap]];
    return rebuild(n, n.result ? vmap[@(n.result.valueId)] : nil, ops, n.memoryResult ? vmap[@(n.memoryResult.valueId)] : nil);
    }

- (void)name:(XTIRInsn*)n values:(NSMutableDictionary<NSNumber*, XTIRValue*>*)vmap
    {
    if (n.result)
        vmap[@(n.result.valueId)] = [self value:n.result.type];
    if (n.memoryResult)
        vmap[@(n.memoryResult.valueId)] = [self value:[XTIRType memoryType]];
    }

- (void)applyLoop:(XTIRBlock*)H
            latch:(XTIRBlock*)L
              pre:(XTIRBlock*)P
             exit:(XTIRBlock*)X
             body:(NSArray<XTIRBlock*>*)body
               in:(NSSet<XTIRBlock*>*)inBody
           guards:(NSArray<XTIRBlock*>*)guards
           bounds:(NSArray<NSNumber*>*)bounds
             offs:(NSArray*)offs
                n:(XTIRValueId)nv
            chain:(NSArray<XTIRInsn*>*)nchain
    {
    (void)L;
    NSUInteger tag = _fn.blocks.count;
    NSMutableDictionary<NSNumber*, XTIRValue*>* pmap = [NSMutableDictionary dictionary];
    for (XTIRInsn* n in nchain)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
        for (XTIROperand* o in n.operands)
            [ops addObject:[self map:o values:pmap blocks:nil]];
        XTIRValue* r = n.result ? [self value:n.result.type] : nil;
        if (r)
            pmap[@(n.result.valueId)] = r;
        XTIRValue* m = n.memoryResult ? [self value:n.memoryResult.type] : nil;
        if (m)
            pmap[@(n.memoryResult.valueId)] = m;
        [P.instructions addObject:rebuild(n, r, ops, m)];
        }
    XTIROperand* n0 = [self map:[XTIROperand useWithValueId:nv] values:pmap blocks:nil];
    if (isU32([_fn valueForId:nv].type))
        {
        XTIRValue* w = [self value:[XTIRType u64Type]];
        [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpZExt result:w operands:@[ n0 ] dbgLoc:nil]];
        n0 = [XTIROperand useWithValueId:w.valueId];
        }
    XTIRValue* all = nil;
    for (NSUInteger bk = 0; bk < bounds.count; bk++)
        {
        NSNumber* b = bounds[bk];
        XTIROperand* top = n0;
        if ([offs[bk] isKindOfClass:[NSNumber class]])
            {
            XTIRValue* kw = [self value:[XTIRType u64Type]];
            [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpZExt
                                                                result:kw
                                                              operands:@[ [XTIROperand useWithValueId:(XTIRValueId)[offs[bk] unsignedIntegerValue]] ]
                                                                dbgLoc:nil]];
            XTIRValue* sum = [self value:[XTIRType u64Type]];
            [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                                result:sum
                                                              operands:@[ [XTIROperand useWithValueId:kw.valueId], n0 ]
                                                                dbgLoc:nil]];
            top = [XTIROperand useWithValueId:sum.valueId];
            }
        XTIRValue* ok = [self value:[XTIRType boolType]];
        [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                            result:ok
                                                          operands:@[ top, [XTIROperand useWithValueId:(XTIRValueId)b.unsignedIntegerValue] ]
                                                         predicate:XTIRICmpULE
                                                            dbgLoc:nil]];
        if (!all)
            all = ok;
        else
            {
            XTIRValue* a = [self value:[XTIRType boolType]];
            [P.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAnd
                                                                result:a
                                                              operands:@[ [XTIROperand useWithValueId:all.valueId],
                                                                          [XTIROperand useWithValueId:ok.valueId] ]
                                                                dbgLoc:nil]];
            all = a;
            }
        }
    XTIRBlock* pc = [[XTIRBlock alloc] init];
    pc.name = [NSString stringWithFormat:@"bv%lu_fast", (unsigned long)tag];
    XTIRBlock* po = [[XTIRBlock alloc] init];
    po.name = [NSString stringWithFormat:@"bv%lu_checked", (unsigned long)tag];
    [P resetTerminator];
    [P setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:all.valueId], [XTIROperand blockWithRef:pc],
                                                         [XTIROperand blockWithRef:po] ]
                                               dbgLoc:nil]];
    [po setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                result:nil
                                              operands:@[ [XTIROperand blockWithRef:H] ]
                                                dbgLoc:nil]];
    for (XTIRInsn* ph in H.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger q = 0; q + 1 < ph.operands.count; q += 2)
            if (ph.operands[q].blockRef == P)
                {
                if (!ops)
                    ops = [ph.operands mutableCopy];
                ops[q] = [XTIROperand blockWithRef:po];
                }
        if (ops)
            [ph replaceOperands:ops];
        }
    NSHashTable<XTIRBlock*>* slows = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (XTIRBlock* g in guards)
        [slows addObject:g.terminator.operands[1].blockRef];
    NSMapTable<XTIRBlock*, XTIRBlock*>* bmap = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];
    NSMutableArray<XTIRBlock*>* copies = [NSMutableArray array];
    for (XTIRBlock* bb in body)
        {
        if ([slows containsObject:bb])
            continue;
        for (XTIRInsn* p in bb.phiNodes)
            [self name:p values:vmap];
        for (XTIRInsn* n in bb.instructions)
            [self name:n values:vmap];
        if (![bmap objectForKey:bb])
            {
            XTIRBlock* nb = [[XTIRBlock alloc] init];
            nb.name = [NSString stringWithFormat:@"%@_bv%lu", bb.name ?: @"", (unsigned long)tag];
            [bmap setObject:nb forKey:bb];
            [copies addObject:nb];
            }
        if (bb.terminator && [guards indexOfObjectIdenticalTo:bb] != NSNotFound)
            [bmap setObject:[bmap objectForKey:bb] forKey:bb.terminator.operands[2].blockRef];
        }
    // What read a check's memory reads what the check read.
    for (XTIRBlock* bb in body)
        {
        if (![slows containsObject:bb])
            continue;
        XTIRInsn* ck = bb.instructions[0];
        XTIROperand* mi = ck.operands.lastObject;
        if (!ck.memoryResult || mi.kind != XTIROperandKindUse)
            continue;
        XTIRValue* mm = vmap[@(mi.valueId)];
        vmap[@(ck.memoryResult.valueId)] = mm ?: [_fn valueForId:mi.valueId];
        }
    for (XTIRBlock* bb in body)
        {
        if ([slows containsObject:bb])
            continue;
        XTIRBlock* nb = [bmap objectForKey:bb];
        for (XTIRInsn* p in bb.phiNodes)
            {
            XTIRInsn* np = [self clone:p values:vmap blocks:bmap];
            NSMutableArray<XTIROperand*>* ops = nil;
            for (NSUInteger q = 0; q + 1 < np.operands.count; q += 2)
                if (np.operands[q].blockRef == po)
                    {
                    if (!ops)
                        ops = [np.operands mutableCopy];
                    ops[q] = [XTIROperand blockWithRef:pc];
                    }
            if (ops)
                [np replaceOperands:ops];
            [nb.phiNodes addObject:np];
            }
        for (XTIRInsn* n in bb.instructions)
            [nb.instructions addObject:[self clone:n values:vmap blocks:bmap]];
        if (bb.terminator && [guards indexOfObjectIdenticalTo:bb] == NSNotFound)
            [nb setTerminator:[self clone:bb.terminator values:vmap blocks:bmap]];
        }
    [pc setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                result:nil
                                              operands:@[ [XTIROperand blockWithRef:[bmap objectForKey:H]] ]
                                                dbgLoc:nil]];
    // Each loop leaves through an exit block of its own, going to X.
    XTIRBlock* hc = [bmap objectForKey:H];
    XTIRBlock* xo = [[XTIRBlock alloc] init];
    xo.name = [NSString stringWithFormat:@"bv%lu_xo", (unsigned long)tag];
    XTIRBlock* xc = [[XTIRBlock alloc] init];
    xc.name = [NSString stringWithFormat:@"bv%lu_xc", (unsigned long)tag];
    [xo setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch result:nil operands:@[ [XTIROperand blockWithRef:X] ] dbgLoc:nil]];
    [xc setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch result:nil operands:@[ [XTIROperand blockWithRef:X] ] dbgLoc:nil]];
    replaceBlock(H.terminator, X, xo);
    replaceBlock(hc.terminator, X, xc);
    for (XTIRInsn* ph in X.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = [ph.operands mutableCopy];
        NSUInteger n0c = ph.operands.count;
        for (NSUInteger q = 0; q + 1 < n0c; q += 2)
            if (ph.operands[q].blockRef == H)
                {
                ops[q] = [XTIROperand blockWithRef:xo];
                [ops addObject:[XTIROperand blockWithRef:xc]];
                [ops addObject:[self map:ph.operands[q + 1] values:vmap blocks:nil]];
                }
        if (ops.count != n0c)
            [ph replaceOperands:ops];
        }
    NSMutableDictionary<NSNumber*, XTIRValue*>* phiOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* ub in [_fn.blocks copy])
        {
        if ([inBody containsObject:ub])
            continue;
        NSMutableArray<XTIRInsn*>* all2 = [NSMutableArray array];
        if (ub != X)
            [all2 addObjectsFromArray:ub.phiNodes];
        [all2 addObjectsFromArray:ub.instructions];
        if (ub.terminator)
            [all2 addObject:ub.terminator];
        for (XTIRInsn* u in all2)
            {
            NSMutableArray<XTIROperand*>* ops = nil;
            for (NSUInteger k = 0; k < u.operands.count; k++)
                {
                XTIROperand* o = u.operands[k];
                if (o.kind != XTIROperandKindUse || !vmap[@(o.valueId)])
                    continue;
                XTIRValue* ov = [_fn valueForId:o.valueId];
                if (ov && ov.type.kind == XTIRTypeKindMemory)
                    continue;
                XTIRValue* pv = phiOf[@(o.valueId)];
                if (!pv)
                    {
                    pv = [self value:ov.type];
                    [X.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                                    result:pv
                                                                  operands:@[ [XTIROperand blockWithRef:xo],
                                                                              [XTIROperand useWithValueId:o.valueId],
                                                                              [XTIROperand blockWithRef:xc],
                                                                              [XTIROperand useWithValueId:vmap[@(o.valueId)].valueId] ]
                                                                    dbgLoc:nil]];
                    phiOf[@(o.valueId)] = pv;
                    }
                if (!ops)
                    ops = [u.operands mutableCopy];
                ops[k] = [XTIROperand useWithValueId:pv.valueId];
                }
            if (ops)
                [u replaceOperands:ops];
            }
        }
    NSMutableArray<XTIRBlock*>* added = [NSMutableArray arrayWithObject:pc];
    [added addObjectsFromArray:copies];
    [added addObject:xc];
    [added addObject:po];
    NSUInteger at = [_fn.blocks indexOfObjectIdenticalTo:P] + 1;
    [_fn.blocks insertObjects:added atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at, added.count)]];
    [_fn.blocks insertObject:xo atIndex:[_fn.blocks indexOfObjectIdenticalTo:X]];
    }

@end
