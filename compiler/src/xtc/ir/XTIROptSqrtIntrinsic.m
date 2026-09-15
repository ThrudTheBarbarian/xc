#import "XTIROptSqrtIntrinsic.h"
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

@implementation XTIROptSqrtIntrinsic

- (NSString*)passName
    {
    return @"sqrt-intrinsic";
    }
- (NSInteger)minOptLevel
    {
    return 1;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (![prof lowersSqrtToHardware])
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn module:mod];
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* insn = bb.instructions[i];
            if (insn.opcode != XTIROpCall || !insn.result || !XTIRTypeKindIsFloating(insn.result.type.kind))
                continue;
            // Operands of a 1-arg call: [callee, arg, memInput].
            if (insn.operands.count != 3)
                continue;
            XTIROperand* callee = insn.operands[0];
            if (callee.kind != XTIROperandKindSym)
                continue;
            XTIRSymbol* sym = [mod symbolForId:callee.symbolId];
            // libm `sqrt`/`sqrtf` (arm9 calls these directly) and the legacy
            // `_xm_sqrt[f]` intrinsic name (arm64/m68k arch libs) — both are a
            // single-fp-arg sqrt; the no-opt fallback is a plain call to the name.
            NSString* nm = sym.name;
            if (!sym || !([nm isEqualToString:@"sqrtf"] || [nm isEqualToString:@"sqrt"] || [nm isEqualToString:@"_xm_sqrtf"] || [nm isEqualToString:@"_xm_sqrt"]))
                continue;
            XTIROperand* arg = insn.operands[1];
            if (arg.kind != XTIROperandKindUse)
                continue;

            // Replace `result = Call _xm_sqrt[f], arg` with `result = FSqrt arg`.
            XTIRInsn* fsqrt = [[XTIRInsn alloc] initWithOpcode:XTIROpFSqrt
                                                        result:insn.result
                                                      operands:@[ arg ]
                                                        dbgLoc:insn.dbgLoc];
            bb.instructions[i] = fsqrt;

            // sqrt is pure: forward its memory token to its memory input so any
            // downstream user of the call's mem-result stays well-formed.
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
