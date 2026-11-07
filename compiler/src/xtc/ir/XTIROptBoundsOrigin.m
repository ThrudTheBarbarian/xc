#import "XTIROptBoundsOrigin.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"

@implementation XTIROptBoundsOrigin

- (NSString*)passName
    {
    return @"bounds-origin";
    }
- (NSInteger)minOptLevel
    {
    return 0;
    }

static XTIRValue* newU64(XTIRFunction* fn, XTIRBlock* bb, NSUInteger at)
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                 type:[XTIRType u64Type]
                                              defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:at]];
    [fn registerValue:v];
    return v;
    }

// An ElementAddr index as a u64 operand: an immediate as it is, a value widened
// (sign-extended if signed) by an instruction placed before the check at *at - 1.
static XTIROperand* _Nullable widen(XTIROperand* k, XTIRFunction* fn, XTIRBlock* bb, NSUInteger* at)
    {
    if (k.kind == XTIROperandKindImmI)
        return [XTIROperand immIWithType:[XTIRType u64Type] value:k.intValue];
    if (k.kind != XTIROperandKindUse)
        return nil;
    XTIRValue* kv = [fn valueForId:k.valueId];
    if (!kv)
        return nil;
    XTIRTypeKind t = kv.type.kind;
    if (t == XTIRTypeKindU64 || t == XTIRTypeKindI64)
        return [XTIROperand useWithValueId:k.valueId];
    BOOL sgn = t == XTIRTypeKindI8 || t == XTIRTypeKindI16 || t == XTIRTypeKindI32;
    BOOL uns = t == XTIRTypeKindU8 || t == XTIRTypeKindU16 || t == XTIRTypeKindU32;
    if (!sgn && !uns)
        return nil;
    XTIRValue* v = newU64(fn, bb, *at - 1);
    [bb.instructions insertObject:[[XTIRInsn alloc] initWithOpcode:sgn ? XTIROpSExt : XTIROpZExt
                                                            result:v
                                                          operands:@[ [XTIROperand useWithValueId:k.valueId] ]
                                                            dbgLoc:nil]
                          atIndex:*at - 1];
    *at += 1;
    return [XTIROperand useWithValueId:v.valueId];
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIRSymbol* hchk = [mod symbolForName:@"_xt_check_bounds"];
    if (!hchk)
        return YES;
    XTIRSymbolId hid = [mod.symbols indexOfObjectIdenticalTo:hchk];
    for (XTIRFunction* fn in mod.functions)
        {
        NSMutableDictionary<NSNumber*, XTIRInsn*>* defs = nil;
        for (XTIRBlock* bb in fn.blocks)
            {
            NSUInteger i = 0;
            while (i < bb.instructions.count)
                {
                XTIRInsn* n = bb.instructions[i];
                i++;
                if (n.opcode != XTIROpCall || n.operands.count != 5 || n.operands[0].kind != XTIROperandKindSym ||
                    n.operands[0].symbolId != hid)
                    continue;
                XTIROperand *po = n.operands[1], *io = n.operands[2];
                if (po.kind != XTIROperandKindUse || io.kind != XTIROperandKindUse)
                    continue;
                if (!defs)
                    {
                    defs = [NSMutableDictionary dictionary];
                    for (XTIRBlock* q in fn.blocks)
                        {
                        for (XTIRInsn* ph in q.phiNodes)
                            if (ph.result)
                                defs[@(ph.result.valueId)] = ph;
                        for (XTIRInsn* d in q.instructions)
                            if (d.result)
                                defs[@(d.result.valueId)] = d;
                        }
                    }
                XTIRValueId p = po.valueId, idx = io.valueId;
                int hops = 0;
                while (hops < 16)
                    {
                    XTIRInsn* d = defs[@(p)];
                    if (!d || d.opcode != XTIROpElementAddr || d.operands.count != 2 || !d.result)
                        break;
                    XTIROperand *bo = d.operands[0], *ko = d.operands[1];
                    if (bo.kind != XTIROperandKindUse)
                        break;
                    XTIRValue* bv = [fn valueForId:bo.valueId];
                    if (!bv || ![bv.type isEqual:d.result.type])
                        break;
                    XTIROperand* k64 = widen(ko, fn, bb, &i);
                    if (!k64)
                        break;
                    XTIRValue* sum = newU64(fn, bb, i - 1);
                    [bb.instructions insertObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                                            result:sum
                                                                          operands:@[ k64, [XTIROperand useWithValueId:idx] ]
                                                                            dbgLoc:n.dbgLoc]
                                          atIndex:i - 1];
                    i++;
                    idx = sum.valueId;
                    p = bo.valueId;
                    hops++;
                    }
                if (hops == 0)
                    continue;
                NSMutableArray<XTIROperand*>* ops = [n.operands mutableCopy];
                ops[1] = [XTIROperand useWithValueId:p];
                ops[2] = [XTIROperand useWithValueId:idx];
                [n replaceOperands:ops];
                }
            }
        }
    return YES;
    }

@end
