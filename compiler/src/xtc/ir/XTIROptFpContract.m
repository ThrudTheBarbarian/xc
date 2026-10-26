// XTIROptFpContract.m — see the header.
#import "XTIROptFpContract.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSupport.h"

@implementation XTIROptFpContract

- (NSString*)passName
    {
    return @"fp-contract";
    }

- (NSInteger)minOptLevel
    {
    return 2;
    }

static NSArray<XTIRBlock*>* successorsOf(XTIRBlock* b)
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    for (XTIROperand* o in b.terminator.operands)
        if (o.kind == XTIROperandKindBlock && o.blockRef)
            [out addObject:o.blockRef];
    return out;
    }

// The blocks reachable from H (forward) or reaching it (backward), H's own
// included when a path returns to it.
static NSSet<NSValue*>* reach(XTIRBlock* H, NSDictionary<NSValue*, NSArray<XTIRBlock*>*>* pred, BOOL forward)
    {
    NSMutableSet<NSValue*>* seen = [NSMutableSet set];
    NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:H];
    while (work.count)
        {
        XTIRBlock* b = work.lastObject;
        [work removeLastObject];
        NSArray<XTIRBlock*>* next = forward ? successorsOf(b) : pred[[NSValue valueWithNonretainedObject:b]];
        for (XTIRBlock* x in next)
            {
            NSValue* k = [NSValue valueWithNonretainedObject:x];
            if ([seen containsObject:k])
                continue;
            [seen addObject:k];
            [work addObject:x];
            }
        }
    return seen;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        {
        if (fn.speedLoopHeaders.count == 0)
            continue;
        NSMutableDictionary<NSValue*, NSMutableArray<XTIRBlock*>*>* pred = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRBlock* s in successorsOf(bb))
                {
                NSValue* k = [NSValue valueWithNonretainedObject:s];
                if (!pred[k])
                    pred[k] = [NSMutableArray array];
                [pred[k] addObject:bb];
                }
        NSMutableSet<NSValue*>* speed = [NSMutableSet set];
        for (XTIRBlock* H in fn.blocks)
            {
            if (!H.name || ![fn.speedLoopHeaders containsObject:H.name])
                continue;
            NSSet<NSValue*>* fwd = reach(H, pred, YES);
            NSSet<NSValue*>* bwd = reach(H, pred, NO);
            for (XTIRBlock* x in fn.blocks)
                {
                NSValue* k = [NSValue valueWithNonretainedObject:x];
                if ([fwd containsObject:k] && [bwd containsObject:k])
                    [speed addObject:k];
                }
            }
        for (XTIRBlock* bb in fn.blocks)
            {
            if (![speed containsObject:[NSValue valueWithNonretainedObject:bb]])
                continue;
            for (XTIRInsn* n in bb.instructions)
                {
                if (n.opcode != XTIROpFAdd && n.opcode != XTIROpFSub)
                    continue;
                if (!n.result || n.predicate != XTIRFpExact)
                    continue;
                XTIRTypeKind k = n.result.type.kind;
                if (k != XTIRTypeKindF32 && k != XTIRTypeKindF64)
                    continue;
                n.predicate = XTIRFpContract;
                }
            }
        }
    return YES;
    }

@end
