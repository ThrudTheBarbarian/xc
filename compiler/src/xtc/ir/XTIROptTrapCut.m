#import "XTIROptTrapCut.h"
#import "XTIROptBlockMerge.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"

@implementation XTIROptTrapCut

- (NSString*)passName
    {
    return @"trap-cut";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static BOOL isTrap(XTIRInsn* insn, XTIRModule* mod)
    {
    if (insn.opcode != XTIROpCall || insn.operands.count < 1)
        return NO;
    XTIROperand* c = insn.operands[0];
    if (c.kind != XTIROperandKindSym)
        return NO;
    NSString* nm = [mod symbolForId:c.symbolId].name;
    return [nm isEqualToString:@"_xt_check_trap"] || [nm isEqualToString:@"_xt_check_cast_trap"];
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptBlockMerge* bm = [[XTIROptBlockMerge alloc] init];
    XTIROptConstBranches* cb = [[XTIROptConstBranches alloc] init];
    for (XTIRFunction* fn in mod.functions)
        {
        // A dropped memory token -> the trap call's own memory input.
        NSMutableDictionary<NSNumber*, NSNumber*>* rename = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            {
            for (NSUInteger i = 0; i < bb.instructions.count; i++)
                {
                XTIRInsn* insn = bb.instructions[i];
                if (!isTrap(insn, mod))
                    continue;
                XTIROperand* memIn = nil;
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse && [fn valueForId:o.valueId].type.kind == XTIRTypeKindMemory)
                        memIn = o;
                if (!memIn)
                    continue;
                if (i + 1 == bb.instructions.count && bb.terminator.opcode == XTIROpUnreachable)
                    break;
                if (insn.memoryResult)
                    rename[@(insn.memoryResult.valueId)] = @(memIn.valueId);
                while (bb.instructions.count > i + 1)
                    {
                    XTIRInsn* d = bb.instructions.lastObject;
                    if (d.memoryResult)
                        rename[@(d.memoryResult.valueId)] = @(memIn.valueId);
                    [bb.instructions removeLastObject];
                    }
                XTIRInsn* u = [[XTIRInsn alloc] initWithOpcode:XTIROpUnreachable result:nil operands:@[]
                                                        dbgLoc:bb.terminator.dbgLoc];
                [bb resetTerminator];
                [bb setTerminator:u];
                break;
                }
            }
        if (rename.count == 0)
            continue;
        void (^renameIn)(XTIRInsn*) = ^(XTIRInsn* insn) {
            NSMutableArray<XTIROperand*>* ops = nil;
            for (NSUInteger k = 0; k < insn.operands.count; k++)
                {
                XTIROperand* o = insn.operands[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                XTIRValueId to = o.valueId;
                for (int hop = 0; hop < 64 && rename[@(to)]; hop++)
                    to = (XTIRValueId)rename[@(to)].unsignedLongLongValue;
                if (to == o.valueId)
                    continue;
                if (!ops)
                    ops = [insn.operands mutableCopy];
                ops[k] = [XTIROperand useWithValueId:to];
                }
            if (ops)
                [insn replaceOperands:ops];
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                renameIn(p);
            for (XTIRInsn* insn in bb.instructions)
                renameIn(insn);
            if (bb.terminator)
                renameIn(bb.terminator);
            }
        [cb dropUnreachable:fn];
        [bm pruneStaleIncomings:fn];
        }
    return YES;
    }

@end
