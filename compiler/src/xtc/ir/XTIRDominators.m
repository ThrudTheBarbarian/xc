#import "XTIRDominators.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"

@implementation XTIRDominators
{
    // Reverse postorder: index 0 is the entry. Every reachable block appears
    // exactly once; unreachable ones appear nowhere.
    NSArray<XTIRBlock*>* _rpo;
    NSMapTable<XTIRBlock*, NSNumber*>* _rpoIndex;
    // idom as an RPO index per RPO index; NSNotFound until computed.
    NSMutableArray<NSNumber*>* _idom;
}

+ (nullable instancetype)forFunction:(XTIRFunction*)fn
    {
    XTIRBlock* entry = fn.entryBlock ?: fn.blocks.firstObject;
    if (!entry)
        return nil;
    XTIRDominators* d = [[XTIRDominators alloc] init];
    [d buildFrom:entry];
    [d computeIdoms];
    return d;
    }

static NSArray<XTIRBlock*>* successorsOf(XTIRBlock* b)
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    if (!b.terminator)
        return out;
    for (XTIROperand* o in b.terminator.operands)
        if (o.kind == XTIROperandKindBlock && o.blockRef)
            [out addObject:o.blockRef];
    return out;
    }

// Postorder DFS from the entry, reversed. Iterative rather than recursive: a
// deeply nested function would otherwise depend on the host stack.
- (void)buildFrom:(XTIRBlock*)entry
    {
    NSMutableArray<XTIRBlock*>* post = [NSMutableArray array];
    NSMutableSet<XTIRBlock*>* seen = [NSMutableSet set];
    NSMutableArray* stack = [NSMutableArray arrayWithObject:@[ entry, @0 ]];
    [seen addObject:entry];
    while (stack.count)
        {
        NSArray* top = stack.lastObject;
        XTIRBlock* b = top[0];
        NSUInteger next = [top[1] unsignedIntegerValue];
        NSArray<XTIRBlock*>* succ = successorsOf(b);
        if (next < succ.count)
            {
            stack[stack.count - 1] = @[ b, @(next + 1) ];
            XTIRBlock* s = succ[next];
            if (![seen containsObject:s])
                {
                [seen addObject:s];
                [stack addObject:@[ s, @0 ]];
                }
            continue;
            }
        [stack removeLastObject];
        [post addObject:b];
        }
    _rpo = [[post reverseObjectEnumerator] allObjects];
    _rpoIndex = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger i = 0; i < _rpo.count; i++)
        [_rpoIndex setObject:@(i) forKey:_rpo[i]];
    }

// The two-pointer walk up the dominator tree: repeatedly move whichever finger
// is further from the entry (higher RPO index) to its own idom. Terminates
// because every step strictly decreases one index.
- (NSUInteger)intersect:(NSUInteger)a with:(NSUInteger)b
    {
    while (a != b)
        {
        while (a > b)
            {
            NSUInteger na = _idom[a].unsignedIntegerValue;
            if (na == NSNotFound || na == a) return b;
            a = na;
            }
        while (b > a)
            {
            NSUInteger nb = _idom[b].unsignedIntegerValue;
            if (nb == NSNotFound || nb == b) return a;
            b = nb;
            }
        }
    return a;
    }

- (void)computeIdoms
    {
    NSUInteger n = _rpo.count;
    _idom = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
        [_idom addObject:@(NSNotFound)];
    if (n == 0)
        return;
    _idom[0] = @0;                       // the entry dominates itself

    // Predecessors, restricted to reachable blocks.
    NSMutableArray<NSMutableArray<NSNumber*>*>* preds = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++)
        [preds addObject:[NSMutableArray array]];
    for (NSUInteger i = 0; i < n; i++)
        for (XTIRBlock* s in successorsOf(_rpo[i]))
            {
            NSNumber* si = [_rpoIndex objectForKey:s];
            if (si)
                [preds[si.unsignedIntegerValue] addObject:@(i)];
            }

    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (NSUInteger i = 1; i < n; i++)     // skip the entry
            {
            NSUInteger newIdom = NSNotFound;
            for (NSNumber* pn in preds[i])
                {
                NSUInteger p = pn.unsignedIntegerValue;
                if (_idom[p].unsignedIntegerValue == NSNotFound)
                    continue;               // not processed yet this round
                newIdom = (newIdom == NSNotFound) ? p : [self intersect:p with:newIdom];
                }
            if (newIdom != NSNotFound && _idom[i].unsignedIntegerValue != newIdom)
                {
                _idom[i] = @(newIdom);
                changed = YES;
                }
            }
        }
    }

- (nullable XTIRBlock*)idomOf:(XTIRBlock*)b
    {
    NSNumber* bi = [_rpoIndex objectForKey:b];
    if (!bi || bi.unsignedIntegerValue == 0)
        return nil;
    NSUInteger d = _idom[bi.unsignedIntegerValue].unsignedIntegerValue;
    if (d == NSNotFound || d == bi.unsignedIntegerValue)
        return nil;
    return _rpo[d];
    }

- (BOOL)block:(XTIRBlock*)a dominates:(XTIRBlock*)b
    {
    NSNumber* ai = [_rpoIndex objectForKey:a];
    NSNumber* bi = [_rpoIndex objectForKey:b];
    if (!ai || !bi)
        return NO;
    NSUInteger x = bi.unsignedIntegerValue, target = ai.unsignedIntegerValue;
    for (NSUInteger guard = 0; guard <= _rpo.count; guard++)
        {
        if (x == target)
            return YES;
        if (x == 0)
            return NO;
        NSUInteger nx = _idom[x].unsignedIntegerValue;
        if (nx == NSNotFound || nx == x)
            return NO;
        x = nx;
        }
    return NO;
    }

- (BOOL)isReachable:(XTIRBlock*)b
    {
    return [_rpoIndex objectForKey:b] != nil;
    }

- (NSArray<XTIRBlock*>*)reversePostorder
    {
    return _rpo;
    }

- (NSArray<XTIRBlock*>*)predecessorsOf:(XTIRBlock*)b
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    if (![_rpoIndex objectForKey:b])
        return out;
    for (XTIRBlock* p in _rpo)
        for (XTIRBlock* s in successorsOf(p))
            if (s == b)
                { [out addObject:p]; break; }
    return out;
    }

@end
