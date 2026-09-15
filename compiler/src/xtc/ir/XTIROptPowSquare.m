#import "XTIROptPowSquare.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIROptTargetProfile.h"

@implementation XTIROptPowSquare

- (NSString*)passName
    {
    return @"pow-square";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// Resolve an operand to a compile-time integer, walking the widening /
// int↔float conversions the lowering wraps a literal exponent in.
static BOOL resolveInt(NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                       XTIROperand* op, int64_t* out)
    {
    if (op.kind == XTIROperandKindImmI)
        {
        if (out)
            *out = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId cur = op.valueId;
    for (int d = 0; d < 16; d++)
        {
        XTIRInsn* def = defOf[@(cur)];
        if (!def)
            return NO;
        if (def.opcode == XTIROpConst)
            {
            if (def.operands.count >= 1 && def.operands[0].kind == XTIROperandKindImmI)
                {
                if (out)
                    *out = def.operands[0].intValue;
                return YES;
                }
            return NO;
            }
        if ((def.opcode == XTIROpZExt || def.opcode == XTIROpSExt || def.opcode == XTIROpTrunc || def.opcode == XTIROpSIToFp || def.opcode == XTIROpUIToFp) && def.operands.count >= 1 && def.operands[0].kind == XTIROperandKindUse)
            {
            cur = def.operands[0].valueId;
            continue;
            }
        return NO;
        }
    return NO;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.foldsPowSquare)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn module:mod];
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;
        }

    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* insn = bb.instructions[i];
            if (insn.opcode != XTIROpCall || !insn.result || !XTIRTypeKindIsFloating(insn.result.type.kind))
                continue;
            // Operands: [callee, base, exp, mem]. Need exactly base + exp.
            if (insn.operands.count != 4)
                continue;
            XTIROperand* callee = insn.operands[0];
            if (callee.kind != XTIROperandKindSym)
                continue;
            XTIRSymbol* sym = [mod symbolForId:callee.symbolId];
            if (!sym || ![sym.name hasPrefix:@"Math$pow__"])
                continue;
            XTIROperand* base = insn.operands[1];
            if (base.kind != XTIROperandKindUse)
                continue;
            int64_t exp;
            if (!resolveInt(defOf, insn.operands[2], &exp) || exp != 2)
                continue;

            // Replace the call with `result = FMul base, base`.
            XTIRInsn* fmul = [[XTIRInsn alloc] initWithOpcode:XTIROpFMul
                                                       result:insn.result
                                                     operands:@[ base, base ]
                                                       dbgLoc:insn.dbgLoc];
            bb.instructions[i] = fmul;

            // pow is pure: forward its memory token to its memory input.
            if (insn.memoryResult)
                {
                XTIROperand* memIn = insn.operands.lastObject;
                if (memIn.kind == XTIROperandKindUse)
                    [self forwardMemIn:fn from:insn.memoryResult.valueId to:memIn.valueId];
                }
            }
        }
    }

// Replace every Use of `oldMem` across the function with `newMem`.
- (void)forwardMemIn:(XTIRFunction*)fn from:(XTIRValueId)oldMem to:(XTIRValueId)newMem
    {
    for (XTIRBlock* bb in fn.blocks)
        {
        [self rewriteList:bb.phiNodes from:oldMem to:newMem];
        [self rewriteList:bb.instructions from:oldMem to:newMem];
        XTIRInsn* t = bb.terminator;
        if (t)
            {
            XTIRInsn* nt = [self rebuild:t from:oldMem to:newMem];
            if (nt)
                {
                [bb resetTerminator];
                [bb setTerminator:nt];
                }
            }
        }
    }

- (void)rewriteList:(NSMutableArray<XTIRInsn*>*)list
               from:(XTIRValueId)oldMem
                 to:(XTIRValueId)newMem
    {
    for (NSUInteger i = 0; i < list.count; i++)
        {
        XTIRInsn* nt = [self rebuild:list[i] from:oldMem to:newMem];
        if (nt)
            list[i] = nt;
        }
    }

- (nullable XTIRInsn*)rebuild:(XTIRInsn*)insn
                         from:(XTIRValueId)oldMem
                           to:(XTIRValueId)newMem
    {
    NSMutableArray<XTIROperand*>* out = nil;
    for (NSUInteger i = 0; i < insn.operands.count; i++)
        {
        XTIROperand* op = insn.operands[i];
        if (op.kind == XTIROperandKindUse && op.valueId == oldMem)
            {
            if (!out)
                out = [insn.operands mutableCopy];
            out[i] = [XTIROperand useWithValueId:newMem];
            }
        }
    if (!out)
        return nil;
    XTIRInsn* r;
    if (insn.callConv)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:out
                                    callConv:insn.callConv
                                      dbgLoc:insn.dbgLoc];
    else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:out
                                   predicate:insn.predicate
                                      dbgLoc:insn.dbgLoc];
    else
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:insn.result
                                    operands:out
                                      dbgLoc:insn.dbgLoc];
    r.memoryResult = insn.memoryResult;
    return r;
    }

@end
