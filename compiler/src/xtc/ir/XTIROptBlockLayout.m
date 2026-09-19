#import "XTIROptBlockLayout.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"

@implementation XTIROptBlockLayout

- (NSString*)passName { return @"block-layout"; }
- (NSInteger)minOptLevel { return 2; }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    if (getenv("XTNOLAYOUT") || !self.profile.laysOutHotPath)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

static NSArray<XTIRBlock*>* succsOf(XTIRBlock* bb)
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

- (void)runOnFunction:(XTIRFunction*)fn
    {
    NSUInteger n = fn.blocks.count;
    if (n < 3)
        return;

    NSArray<XTIRBlock*>* orig = [fn.blocks copy];
    NSMutableDictionary<NSValue*, NSNumber*>* idx = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < n; i++)
        idx[[NSValue valueWithNonretainedObject:orig[i]]] = @(i);

    NSMutableArray<NSMutableArray<XTIRBlock*>*>* preds = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++)
        [preds addObject:[NSMutableArray array]];
    for (XTIRBlock* bb in orig)
        for (XTIRBlock* s in succsOf(bb))
            {
            NSNumber* si = idx[[NSValue valueWithNonretainedObject:s]];
            if (si && ![preds[si.unsignedIntegerValue] containsObject:bb])
                [preds[si.unsignedIntegerValue] addObject:bb];
            }

    // Loop depth, by natural loops. For a back edge n -> h (h earlier in the
    // original order), the loop is h plus everything that reaches n without
    // going through h. Approximating the back edge by position is what the
    // register allocator already does, and it is the same approximation here.
    NSMutableArray<NSNumber*>* depth = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++)
        [depth addObject:@0];
    for (NSUInteger li = 0; li < n; li++)
        for (XTIRBlock* s in succsOf(orig[li]))
            {
            NSNumber* hbN = idx[[NSValue valueWithNonretainedObject:s]];
            if (!hbN || hbN.unsignedIntegerValue > li)
                continue;                            // forward edge, not a loop
            NSUInteger hb = hbN.unsignedIntegerValue;
            NSMutableIndexSet* loop = [NSMutableIndexSet indexSet];
            [loop addIndex:hb];
            [loop addIndex:li];
            NSMutableArray<NSNumber*>* work = [NSMutableArray arrayWithObject:@(li)];
            while (work.count)
                {
                NSUInteger b = work.lastObject.unsignedIntegerValue;
                [work removeLastObject];
                if (b == hb)
                    continue;
                for (XTIRBlock* p in preds[b])
                    {
                    NSNumber* pi = idx[[NSValue valueWithNonretainedObject:p]];
                    if (!pi || [loop containsIndex:pi.unsignedIntegerValue])
                        continue;
                    [loop addIndex:pi.unsignedIntegerValue];
                    [work addObject:pi];
                    }
                }
            [loop enumerateIndexesUsingBlock:^(NSUInteger i, BOOL* stop) {
              (void)stop;
              depth[i] = @(depth[i].unsignedIntegerValue + 1);
            }];
            }

    // Reverse postorder, visiting the COLD successor first.
    //
    // The order has to stay a reverse postorder, not just any trace: the
    // register allocator's live intervals are LINEAR over this order, so a
    // value's definition must come before its uses or its interval runs
    // backwards and the allocator hands its register to something still live.
    // A first cut used a greedy trace and did exactly that — sieve read a
    // clockid from a register whose `mov #6` was laid out later, and printed a
    // garbage elapsed time while its checksum still matched.
    //
    // In a DFS postorder a node is appended after all its descendants, so
    // reversing puts a node immediately before the subtree of its LAST-visited
    // successor. Visiting the cold successor first therefore leaves the hot
    // one adjacent, which is the whole point, and reverse postorder gives the
    // definition-before-use property for free.
    NSMutableArray<XTIRBlock*>* post = [NSMutableArray array];
    NSMutableIndexSet* seen = [NSMutableIndexSet indexSet];
    NSMutableArray<NSNumber*>* stack = [NSMutableArray arrayWithObject:@0];
    NSMutableArray<NSMutableArray<NSNumber*>*>* pending = [NSMutableArray array];
    [seen addIndex:0];

    // Successors of `b`, coldest first: lower loop depth is colder, and among
    // equals the LATER original block is treated as colder so the earlier one
    // stays adjacent — which keeps the layout close to the original wherever
    // there is nothing to gain, and makes the result reproducible.
    NSMutableArray<NSNumber*>* (^coldFirst)(NSUInteger) = ^(NSUInteger b) {
      NSMutableArray<NSNumber*>* ss = [NSMutableArray array];
      for (XTIRBlock* s in succsOf(orig[b]))
          {
          NSNumber* si = idx[[NSValue valueWithNonretainedObject:s]];
          if (si && ![ss containsObject:si])
              [ss addObject:si];
          }
      [ss sortUsingComparator:^NSComparisonResult(NSNumber* x, NSNumber* y) {
        NSUInteger dx = depth[x.unsignedIntegerValue].unsignedIntegerValue;
        NSUInteger dy = depth[y.unsignedIntegerValue].unsignedIntegerValue;
        if (dx != dy) return dx < dy ? NSOrderedAscending : NSOrderedDescending;
        return x.unsignedIntegerValue > y.unsignedIntegerValue
                   ? NSOrderedAscending : NSOrderedDescending;
      }];
      return ss;
    };
    [pending addObject:coldFirst(0)];
    while (stack.count)
        {
        NSUInteger b = stack.lastObject.unsignedIntegerValue;
        NSMutableArray<NSNumber*>* todo = pending.lastObject;
        if (todo.count == 0)
            {
            [post addObject:orig[b]];
            [stack removeLastObject];
            [pending removeLastObject];
            continue;
            }
        NSUInteger s = todo[0].unsignedIntegerValue;
        [todo removeObjectAtIndex:0];
        if ([seen containsIndex:s])
            continue;
        [seen addIndex:s];
        [stack addObject:@(s)];
        [pending addObject:coldFirst(s)];
        }

    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    for (NSInteger i = (NSInteger)post.count - 1; i >= 0; i--)
        [out addObject:post[(NSUInteger)i]];
    // A block the entry cannot reach keeps its place at the end rather than
    // being dropped — nothing here is entitled to delete code.
    for (XTIRBlock* bb in orig)
        if (![out containsObject:bb])
            [out addObject:bb];

    if (out.count == n)
        [fn.blocks setArray:out];
    }

@end
