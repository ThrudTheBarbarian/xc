#import "XTIROptConstOperandFold.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"

@implementation XTIROptConstOperandFold

- (NSString*)passName
    {
    return @"const-operand-fold";
    }
- (NSInteger)minOptLevel
    {
    return 2;
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
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* phi in bb.phiNodes)
            if (phi.result)
                defOf[@(phi.result.valueId)] = phi;
        for (XTIRInsn* insn in bb.instructions)
            if (insn.result)
                defOf[@(insn.result.valueId)] = insn;
        }

    // Resolve a value to a compile-time int, walking through ZExt / SExt of
    // a Const (iterative — no self-capturing block). nil if not constant.
    NSNumber* (^resolveConst)(XTIRValueId) = ^NSNumber*(XTIRValueId vid) {
      XTIRValueId cur = vid;
      for (int depth = 0; depth < 16; depth++)
          {
          XTIRInsn* d = defOf[@(cur)];
          if (!d)
              return nil;
          if (d.opcode == XTIROpConst)
              {
              if (d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindImmI)
                  return @(d.operands[0].intValue);
              return nil;
              }
          if ((d.opcode == XTIROpZExt || d.opcode == XTIROpSExt) && d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindUse)
              {
              cur = d.operands[0].valueId;
              continue;
              }
          return nil;
          }
      return nil;
    };

    // Fold the RHS (operands[1]) constant of arithmetic / bitwise / shift /
    // compare ops into an immediate so the backend emits `ADC #k` / `CMP #k` /
    // `imul r,r,#k` / `shl r,#k` directly instead of materialising the constant
    // into a register/slot and loading it back. Every backend already accepts an
    // ImmI RHS here (its operand loader materialises it) — the folded Add/Sub/…
    // have relied on that for a while; Mul/shift join them. Folding compares
    // relies on the rule-1 (redundant-reload) peephole being flag-aware (phase-248).
    BOOL changed = NO;
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* insn = bb.instructions[i];
            BOOL foldable = insn.opcode == XTIROpAdd || insn.opcode == XTIROpSub || insn.opcode == XTIROpAnd || insn.opcode == XTIROpOr || insn.opcode == XTIROpXor || insn.opcode == XTIROpICmp || insn.opcode == XTIROpMul || insn.opcode == XTIROpShl || insn.opcode == XTIROpLShr || insn.opcode == XTIROpAShr;
            if (!foldable || insn.operands.count < 2)
                continue;
            XTIROperand* rhs = insn.operands[1];
            if (rhs.kind != XTIROperandKindUse)
                continue;
            NSNumber* k = resolveConst(rhs.valueId);
            if (!k)
                continue;
            XTIRValue* rhsVal = [fn valueForId:rhs.valueId];
            XTIRType* immType = rhsVal.type;
            if (!immType)
                continue;
            XTIROperand* imm = [XTIROperand immIWithType:immType value:k.longLongValue];
            NSMutableArray<XTIROperand*>* newOps = [insn.operands mutableCopy];
            newOps[1] = imm;
            XTIRInsn* repl;
            if (insn.opcode == XTIROpICmp)
                repl = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                 result:insn.result
                                               operands:newOps
                                              predicate:insn.predicate
                                                 dbgLoc:insn.dbgLoc];
            else
                repl = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                 result:insn.result
                                               operands:newOps
                                                 dbgLoc:insn.dbgLoc];
            repl.memoryResult = insn.memoryResult;
            bb.instructions[i] = repl;
            changed = YES;
            }
        }
    if (!changed)
        return;

    // Dead-strip the now-unreferenced Const / ZExt / SExt / Trunc the fold
    // detached. Pure ops with an unused result are dead. Recompute uses and
    // sweep to a fixpoint (removing a ZExt can orphan its Const).
    BOOL removed = YES;
    while (removed)
        {
        removed = NO;
        NSMutableSet<NSNumber*>* used = [NSMutableSet set];
        void (^count)(NSArray<XTIROperand*>*) = ^(NSArray<XTIROperand*>* ops) {
          for (XTIROperand* op in ops)
              if (op.kind == XTIROperandKindUse)
                  [used addObject:@(op.valueId)];
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* phi in bb.phiNodes)
                count(phi.operands);
            for (XTIRInsn* insn in bb.instructions)
                count(insn.operands);
            if (bb.terminator)
                count(bb.terminator.operands);
            }
        for (XTIRBlock* bb in fn.blocks)
            {
            for (NSInteger i = (NSInteger)bb.instructions.count - 1; i >= 0; i--)
                {
                XTIRInsn* insn = bb.instructions[i];
                BOOL pure = insn.opcode == XTIROpConst || insn.opcode == XTIROpZExt || insn.opcode == XTIROpSExt || insn.opcode == XTIROpTrunc;
                if (pure && insn.result && !insn.memoryResult && ![used containsObject:@(insn.result.valueId)])
                    {
                    [bb.instructions removeObjectAtIndex:(NSUInteger)i];
                    removed = YES;
                    }
                }
            }
        }
    }

@end
