#import "XTIROptNarrow.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@implementation XTIROptNarrow

- (NSString*)passName
    {
    return @"narrow";
    }
- (NSInteger)minOptLevel
    {
    return 1;
    }

// Ops whose low W bits are a function of only the operands' low W bits, so the
// op can be recomputed at width W under a truncation (2's-complement).
static BOOL narrowable(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
        return YES;
    default:
        return NO; // Div/Mod/Shr/Shl: high bits leak into low W
        }
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    // Def map (valueId → defining instruction), rebuilt per fixpoint round since
    // narrowing rewrites instructions.
    BOOL changed = YES;
    for (int round = 0; round < 8 && changed; round++)
        {
        changed = NO;
        NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* i in bb.instructions)
                if (i.result)
                    defOf[@(i.result.valueId)] = i;

        for (XTIRBlock* bb in fn.blocks)
            {
            for (NSUInteger idx = 0; idx < bb.instructions.count; idx++)
                {
                XTIRInsn* tr = bb.instructions[idx];
                if (tr.opcode != XTIROpTrunc || !tr.result || tr.operands.count < 1)
                    continue;
                if (tr.operands[0].kind != XTIROperandKindUse)
                    continue;
                XTIRInsn* src = defOf[@(tr.operands[0].valueId)];
                if (!src || !narrowable(src.opcode) || !src.result || src.operands.count < 2)
                    continue;
                NSUInteger w = tr.result.type.byteWidth;
                if (src.result.type.byteWidth <= w)
                    continue; // not actually wider

                // Narrow each operand to width w. Prefer collapsing an
                // ext-from-w source; otherwise insert a Trunc. Bail if any
                // operand can't be narrowed cleanly (keep it correct + simple).
                NSMutableArray<XTIRInsn*>* inserts = [NSMutableArray array];
                NSMutableArray<XTIROperand*>* nops = [NSMutableArray array];
                BOOL ok = YES;
                for (XTIROperand* o in src.operands)
                    {
                    if (o.kind == XTIROperandKindImmI)
                        {
                        [nops addObject:o];
                        continue;
                        }
                    if (o.kind != XTIROperandKindUse)
                        {
                        ok = NO;
                        break;
                        }
                    XTIRValue* ov = [fn valueForId:o.valueId];
                    XTIRInsn* od = defOf[@(o.valueId)];
                    if (od && (od.opcode == XTIROpZExt || od.opcode == XTIROpSExt) && od.operands.count >= 1 && od.operands[0].kind == XTIROperandKindUse)
                        {
                        XTIRValue* srcV = [fn valueForId:od.operands[0].valueId];
                        // Trunc_w(Ext(x_w)) == x_w
                        if (srcV && srcV.type.byteWidth == w)
                            {
                            [nops addObject:[XTIROperand useWithValueId:od.operands[0].valueId]];
                            continue;
                            }
                        }
                    // already the right width
                    if (ov && ov.type.byteWidth == w)
                        {
                        [nops addObject:o];
                        continue;
                        }
                    // insert a Trunc to w
                    if (ov && ov.type.byteWidth > w)
                        {
                        XTIRValueId rid = [fn allocateValueId];
                        XTIRValue* rv = [[XTIRValue alloc] initWithValueId:rid
                                                                      type:tr.result.type
                                                                   defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:idx]];
                        [fn registerValue:rv];
                        XTIRInsn* nt = [[XTIRInsn alloc] initWithOpcode:XTIROpTrunc
                                                                 result:rv
                                                               operands:@[ o ]
                                                                 dbgLoc:tr.dbgLoc];
                        [inserts addObject:nt];
                        [nops addObject:[XTIROperand useWithValueId:rid]];
                        continue;
                        }
                    ok = NO;
                    break; // narrower operand: unexpected
                    }
                if (!ok)
                    continue;

                // Replace the Trunc with the narrow Op (reusing the Trunc's
                // result value so all consumers follow), preceded by any inserted
                // narrowing Truncs. The wide Op + its Ext feeders become dead
                // (DCE removes them).
                XTIRInsn* nOp = [[XTIRInsn alloc] initWithOpcode:src.opcode
                                                          result:tr.result
                                                        operands:nops
                                                          dbgLoc:tr.dbgLoc];
                [bb.instructions replaceObjectAtIndex:idx withObject:nOp];
                for (NSUInteger k = 0; k < inserts.count; k++)
                    [bb.instructions insertObject:inserts[k] atIndex:idx + k];
                idx += inserts.count;
                changed = YES;
                }
            }
        }
    }

@end
