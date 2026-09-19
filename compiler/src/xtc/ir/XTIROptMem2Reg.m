#import "XTIROptMem2Reg.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
#import "XTIRDominators.h"

// One promoted field: a pinned local and an index into its layout.
@interface XTM2RVar : NSObject
@property(nonatomic) XTIRValueId local;
@property(nonatomic) NSUInteger field;
@property(nonatomic, strong) XTIRType* type;
@end
@implementation XTM2RVar
@end

@implementation XTIROptMem2Reg
{
    NSMutableArray<XTM2RVar*>* _vars;
    // FieldAddr result -> index into _vars.
    NSMutableDictionary<NSNumber*, NSNumber*>* _varOfPtr;
    // Block -> the phis this pass put there, parallel to _phiVar.
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRInsn*>*>* _phis;
    NSMapTable<XTIRBlock*, NSMutableArray<NSNumber*>*>* _phiVar;
    NSMutableIndexSet* _bad;
    // Block -> its children in the dominator tree, and the predecessors of
    // each block. Both in fn.blocks DECLARATION order: the two compilers must
    // walk the tree identically, and declaration order is the one ordering
    // both can reproduce without sharing an implementation.
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* _kids;
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* _preds;
    NSMutableDictionary<NSNumber*, XTIROperand*>* _valueMap;
    NSMutableArray<XTIRInsn*>* _dead;
    XTIRDominators* _dom;
}

- (NSString*)passName { return @"mem2reg"; }
- (NSInteger)minOptLevel { return 2; }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn module:mod];
    return YES;
    }

static NSArray<XTIRInsn*>* allInsns(XTIRFunction* fn)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        {
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator) [all addObject:bb.terminator];
        }
    return all;
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    if (fn.blocks.count == 0 || fn.frameInfo.pinnedLocals.count == 0)
        return;

    NSMutableDictionary<NSNumber*, NSMutableArray<XTIRInsn*>*>* userOf =
        [NSMutableDictionary dictionary];
    for (XTIRInsn* i in allInsns(fn))
        for (XTIROperand* o in i.operands)
            if (o.kind == XTIROperandKindUse)
                {
                NSMutableArray* u = userOf[@(o.valueId)];
                if (!u) { u = [NSMutableArray array]; userOf[@(o.valueId)] = u; }
                if (![u containsObject:i]) [u addObject:i];
                }

    _vars = [NSMutableArray array];
    _varOfPtr = [NSMutableDictionary dictionary];
    for (XTIRPinnedLocal* pl in fn.frameInfo.pinnedLocals)
        [self collectLocal:pl fn:fn userOf:userOf];
    if (_vars.count == 0)
        return;

    _dom = [XTIRDominators forFunction:fn];
    [self buildTree:fn];
    // A phi needs one incoming per predecessor, and an unreachable predecessor
    // is not one the dominator tree knows about — so the phis this pass writes
    // would be short an entry. Rare enough to simply decline.
    if (!_dom || _dom.reversePostorder.count != fn.blocks.count)
        return;

    // Dry run first: a field READ on a path that never wrote it cannot be
    // promoted — there is no value to name. Drop those and retry, because
    // dropping one can only ever help the others.
    _bad = [NSMutableIndexSet indexSet];
    for (int attempt = 0; attempt < 4; attempt++)
        {
        NSUInteger before = _bad.count;
        [self placePhis:fn dryRun:YES];
        [self renameFrom:fn.blocks[0] stacks:[self freshStacks] dryRun:YES];
        if (_bad.count == before)
            break;
        }
    if (_bad.count >= _vars.count)
        return;

    _valueMap = [NSMutableDictionary dictionary];
    _dead = [NSMutableArray array];
    [self placePhis:fn dryRun:NO];
    [self renameFrom:fn.blocks[0] stacks:[self freshStacks] dryRun:NO];
    [self commit:fn];
    }

- (NSMutableArray<NSMutableArray<XTIROperand*>*>*)freshStacks
    {
    NSMutableArray* s = [NSMutableArray array];
    for (NSUInteger i = 0; i < _vars.count; i++)
        [s addObject:[NSMutableArray array]];
    return s;
    }

// A local qualifies when it is reached ONLY through
// AddrOf -> FieldAddr(constant) -> scalar Load/Store.
- (void)collectLocal:(XTIRPinnedLocal*)pl
                  fn:(XTIRFunction*)fn
              userOf:(NSDictionary<NSNumber*, NSArray<XTIRInsn*>*>*)userOf
    {
    XTIRType* ty = pl.type;
    if (!ty || ty.kind != XTIRTypeKindAgg || !ty.layout || ty.layout.fields.count == 0)
        return;
    XTIRLayout* lay = ty.layout;

    NSArray<XTIRInsn*>* addrs = userOf[@(pl.valueId)];
    if (addrs.count == 0)
        return;
    NSMutableArray<XTIRInsn*>* ptrs = [NSMutableArray array];
    for (XTIRInsn* ao in addrs)
        {
        if (ao.opcode != XTIROpAddrOf || !ao.result)
            return;
        NSArray<XTIRInsn*>* fs = userOf[@(ao.result.valueId)];
        if (fs.count == 0)
            return;
        for (XTIRInsn* f in fs)
            {
            if (f.opcode != XTIROpFieldAddr || !f.result || f.operands.count < 2 ||
                f.operands[1].kind != XTIROperandKindImmI)
                return;
            int64_t k = f.operands[1].intValue;
            if (k < 0 || (NSUInteger)k >= lay.fields.count)
                return;
            // Plain scalars only. A promoted value has to be type-identical
            // to the field, and a KIND is all that is available here — two
            // pointers of different pointee or window share a kind, so a
            // pointer field cannot be checked to the same standard. The port
            // compares type SPELLINGS; restricting to scalars is what makes
            // the two tests agree.
            XTIRType* fty = lay.fields[(NSUInteger)k].type;
            if (!fty || fty.kind == XTIRTypeKindAgg || fty.kind == XTIRTypeKindPtr ||
                fty.kind == XTIRTypeKindVec || fty.kind == XTIRTypeKindMemory)
                return;
            // The pointer itself must never be anything but the address a
            // Load reads or a Store writes — stored AS a value, or handed to
            // a call, it escapes and the frame slot is the only truth.
            for (XTIRInsn* u in userOf[@(f.result.valueId)])
                {
                BOOL addressOnly =
                    ((u.opcode == XTIROpLoad || u.opcode == XTIROpStore) &&
                     u.operands.count >= 2 &&
                     u.operands[0].kind == XTIROperandKindUse &&
                     u.operands[0].valueId == f.result.valueId);
                if (!addressOnly)
                    return;
                for (NSUInteger q = 1; q < u.operands.count; q++)
                    if (u.operands[q].kind == XTIROperandKindUse &&
                        u.operands[q].valueId == f.result.valueId)
                        return;
                // A Load's width must be the field's, or promoting it would
                // name a value of the wrong type.
                if (u.opcode == XTIROpLoad && u.result && u.result.type.kind != fty.kind)
                    return;
                }
            [ptrs addObject:f];
            }
        }

    // Accepted: give every field index used its own variable.
    NSMutableDictionary<NSNumber*, NSNumber*>* varOfField = [NSMutableDictionary dictionary];
    for (XTIRInsn* f in ptrs)
        {
        NSNumber* k = @(f.operands[1].intValue);
        NSNumber* vi = varOfField[k];
        if (!vi)
            {
            XTM2RVar* v = [[XTM2RVar alloc] init];
            v.local = pl.valueId;
            v.field = k.unsignedIntegerValue;
            v.type = lay.fields[v.field].type;
            vi = @(_vars.count);
            [_vars addObject:v];
            varOfField[k] = vi;
            }
        _varOfPtr[@(f.result.valueId)] = vi;
        }
    }


// Predecessors and dominator-tree children, both in fn.blocks declaration
// order. Nothing here depends on how the dominator tree was BUILT — only on
// the idom relation, which is a fact about the CFG and not an artefact of one
// implementation's traversal.
- (void)buildTree:(XTIRFunction*)fn
    {
    _kids = [NSMapTable strongToStrongObjectsMapTable];
    _preds = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* bb in fn.blocks)
        {
        [_kids setObject:[NSMutableArray array] forKey:bb];
        [_preds setObject:[NSMutableArray array] forKey:bb];
        }
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRBlock* s in [self successorsOf:bb])
            {
            NSMutableArray* p = [_preds objectForKey:s];
            if (p && ![p containsObject:bb]) [p addObject:bb];
            }
    for (XTIRBlock* c in fn.blocks)
        {
        XTIRBlock* d = [_dom idomOf:c];
        if (d && d != c)
            [[_kids objectForKey:d] addObject:c];
        }
    }

// The dominance frontier of `b`: a block `b` reaches through some predecessor
// it dominates, but does not itself strictly dominate.
- (BOOL)block:(XTIRBlock*)b inFrontierOf:(XTIRBlock*)j
    {
    BOOL reaches = NO;
    for (XTIRBlock* p in [_preds objectForKey:j])
        if ([_dom block:b dominates:p])
            { reaches = YES; break; }
    if (!reaches)
        return NO;
    return (b == j) || ![_dom block:b dominates:j];
    }

// The iterated dominance frontier, to a fixed point. Both loops run in
// fn.blocks order so the result's ORDER is reproducible, not just its members
// — the phis come out in this order and their value ids follow.
- (NSArray<XTIRBlock*>*)iteratedFrontierOf:(NSArray<XTIRBlock*>*)defs
                                        fn:(XTIRFunction*)fn
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* seeds = [defs mutableCopy];
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (XTIRBlock* b in fn.blocks)
            {
            if (![seeds containsObject:b])
                continue;
            for (XTIRBlock* j in fn.blocks)
                {
                if ([out containsObject:j] || ![self block:b inFrontierOf:j])
                    continue;
                [out addObject:j];
                [seeds addObject:j];
                changed = YES;
                }
            }
        }
    return out;
    }

- (NSNumber*)varForPointerOperand:(XTIROperand*)op
    {
    if (!op || op.kind != XTIROperandKindUse)
        return nil;
    NSNumber* v = _varOfPtr[@(op.valueId)];
    if (v && [_bad containsIndex:v.unsignedIntegerValue])
        return nil;
    return v;
    }

- (void)placePhis:(XTIRFunction*)fn dryRun:(BOOL)dry
    {
    _phis = [NSMapTable strongToStrongObjectsMapTable];
    _phiVar = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger vi = 0; vi < _vars.count; vi++)
        {
        if ([_bad containsIndex:vi])
            continue;
        NSMutableArray<XTIRBlock*>* defs = [NSMutableArray array];
        for (XTIRBlock* bb in fn.blocks)
            {
            BOOL stores = NO;
            for (XTIRInsn* i in bb.instructions)
                if (i.opcode == XTIROpStore &&
                    [[self varForPointerOperand:i.operands.firstObject] isEqual:@(vi)])
                    { stores = YES; break; }
            if (stores) [defs addObject:bb];
            }
        if (defs.count == 0)
            continue;
        for (XTIRBlock* j in [self iteratedFrontierOf:defs fn:fn])
            {
            NSMutableArray<XTIRInsn*>* ps = [_phis objectForKey:j];
            NSMutableArray<NSNumber*>* vs = [_phiVar objectForKey:j];
            if (!ps)
                {
                ps = [NSMutableArray array];
                vs = [NSMutableArray array];
                [_phis setObject:ps forKey:j];
                [_phiVar setObject:vs forKey:j];
                }
            // The dry run builds the phi WITHOUT a result: it needs a
            // placeholder in the array, and allocating a value id for a run
            // whose only output is a rejection list would shift every id the
            // real run then hands out.
            XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                      result:nil
                                                    operands:@[]
                                                      dbgLoc:nil];
            if (!dry)
                {
                XTIRValue* r =
                    [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                  type:_vars[vi].type
                                               defSite:[[XTIRDefSite alloc] initWithBlock:j
                                                                                insnIndex:0]];
                [fn registerValue:r];
                NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
                for (XTIRBlock* p in [_preds objectForKey:j])
                    {
                    [ops addObject:[XTIROperand blockWithRef:p]];
                    [ops addObject:[XTIROperand useWithValueId:0]];
                    }
                phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                result:r
                                              operands:ops
                                                dbgLoc:nil];
                }
            [ps addObject:phi];
            [vs addObject:@(vi)];
            }
        }
    }

- (void)renameFrom:(XTIRBlock*)bb
            stacks:(NSMutableArray<NSMutableArray<XTIROperand*>*>*)stacks
            dryRun:(BOOL)dry
    {
    NSMutableArray<NSNumber*>* pushed = [NSMutableArray array];
    for (NSUInteger i = 0; i < _vars.count; i++)
        [pushed addObject:@0];

    NSMutableArray<NSNumber*>* pv = [_phiVar objectForKey:bb];
    NSMutableArray<XTIRInsn*>* pi = [_phis objectForKey:bb];
    for (NSUInteger k = 0; k < pv.count; k++)
        {
        NSUInteger vi = pv[k].unsignedIntegerValue;
        if ([_bad containsIndex:vi])
            continue;
        XTIROperand* val = dry ? [XTIROperand useWithValueId:0]
                               : [XTIROperand useWithValueId:pi[k].result.valueId];
        [stacks[vi] addObject:val];
        pushed[vi] = @(pushed[vi].unsignedIntegerValue + 1);
        }

    for (XTIRInsn* i in bb.instructions)
        {
        NSNumber* vn = [self varForPointerOperand:i.operands.firstObject];
        if (!vn)
            continue;
        NSUInteger vi = vn.unsignedIntegerValue;
        if (i.opcode == XTIROpLoad)
            {
            if (stacks[vi].count == 0)
                { [_bad addIndex:vi]; continue; }
            if (!dry && i.result)
                {
                _valueMap[@(i.result.valueId)] = stacks[vi].lastObject;
                [_dead addObject:i];
                }
            }
        else if (i.opcode == XTIROpStore && i.operands.count >= 2)
            {
            [stacks[vi] addObject:[self resolve:i.operands[1] dryRun:dry]];
            pushed[vi] = @(pushed[vi].unsignedIntegerValue + 1);
            if (!dry)
                [_dead addObject:i];
            }
        }

    for (XTIRBlock* s in [self successorsOf:bb])
        {
        NSMutableArray<NSNumber*>* spv = [_phiVar objectForKey:s];
        NSMutableArray<XTIRInsn*>* spi = [_phis objectForKey:s];
        for (NSUInteger k = 0; k < spv.count; k++)
            {
            NSUInteger vi = spv[k].unsignedIntegerValue;
            if ([_bad containsIndex:vi])
                continue;
            if (stacks[vi].count == 0)
                { [_bad addIndex:vi]; continue; }
            if (dry)
                continue;
            XTIRInsn* phi = spi[k];
            NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
            for (NSUInteger q = 0; q + 1 < ops.count; q += 2)
                if (ops[q].blockRef == bb)
                    ops[q + 1] = stacks[vi].lastObject;
            [phi replaceOperands:ops];
            }
        }

    for (XTIRBlock* c in [_kids objectForKey:bb])
        [self renameFrom:c stacks:stacks dryRun:dry];

    for (NSUInteger vi = 0; vi < _vars.count; vi++)
        {
        NSUInteger n = pushed[vi].unsignedIntegerValue;
        while (n-- > 0 && stacks[vi].count > 0)
            [stacks[vi] removeLastObject];
        }
    }

// A stored value may itself be a load this pass has already replaced, so it is
// resolved AT PUSH TIME — which is what keeps the value map one level deep.
- (XTIROperand*)resolve:(XTIROperand*)op dryRun:(BOOL)dry
    {
    if (dry || !op || op.kind != XTIROperandKindUse)
        return op;
    XTIROperand* r = _valueMap[@(op.valueId)];
    return r ?: op;
    }

- (NSArray<XTIRBlock*>*)successorsOf:(XTIRBlock*)bb
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    if (!bb.terminator)
        return out;
    for (XTIROperand* o in bb.terminator.operands)
        if (o.kind == XTIROperandKindBlock && o.blockRef &&
            ![out containsObject:o.blockRef])
            [out addObject:o.blockRef];
    return out;
    }

- (void)commit:(XTIRFunction*)fn
    {
    // Install the phis.
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* ps = [_phis objectForKey:bb];
        NSMutableArray<NSNumber*>* vs = [_phiVar objectForKey:bb];
        for (NSUInteger k = 0; k < ps.count; k++)
            if (![_bad containsIndex:vs[k].unsignedIntegerValue])
                [bb.phiNodes addObject:ps[k]];
        }

    // Point every reader of a promoted load at the value it now names.
    for (XTIRInsn* x in allInsns(fn))
        {
        NSMutableArray<XTIROperand*>* ops = [x.operands mutableCopy];
        BOOL hit = NO;
        for (NSUInteger q = 0; q < ops.count; q++)
            if (ops[q].kind == XTIROperandKindUse)
                {
                XTIROperand* r = _valueMap[@(ops[q].valueId)];
                if (r) { ops[q] = r; hit = YES; }
                }
        if (hit) [x replaceOperands:ops];
        }

    // Drop the loads and stores, IN PROGRAM ORDER so each one's memory result
    // forwards onto an input its predecessor has already rewritten.
    NSMutableSet<NSValue*>* deadSet = [NSMutableSet set];
    for (XTIRInsn* d in _dead)
        [deadSet addObject:[NSValue valueWithNonretainedObject:d]];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in [bb.instructions copy])
            {
            if (![deadSet containsObject:[NSValue valueWithNonretainedObject:i]])
                continue;
            if (!i.memoryResult)
                continue;
            XTIROperand* in = (i.opcode == XTIROpStore) ? i.operands[2] : i.operands[1];
            for (XTIRInsn* x in allInsns(fn))
                {
                NSMutableArray<XTIROperand*>* ops = [x.operands mutableCopy];
                BOOL hit = NO;
                for (NSUInteger q = 0; q < ops.count; q++)
                    if (ops[q].kind == XTIROperandKindUse &&
                        ops[q].valueId == i.memoryResult.valueId)
                        { ops[q] = in; hit = YES; }
                if (hit) [x replaceOperands:ops];
                }
            }
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* keep = [NSMutableArray array];
        for (XTIRInsn* i in bb.instructions)
            if (![deadSet containsObject:[NSValue valueWithNonretainedObject:i]])
                [keep addObject:i];
        [bb.instructions setArray:keep];
        }
    }

@end
