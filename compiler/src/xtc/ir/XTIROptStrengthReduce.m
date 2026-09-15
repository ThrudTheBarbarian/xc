#import "XTIROptStrengthReduce.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// log2(n) if n is a positive power of two, else -1.
static int log2IfPow2(int64_t n)
    {
    if (n <= 0)
        return -1;
    uint64_t u = (uint64_t)n;
    if (u & (u - 1))
        return -1;
    int k = 0;
    while ((u >> k) != 1)
        k++;
    return k;
    }

@implementation XTIROptStrengthReduce

- (NSString*)passName
    {
    return @"strength-reduce";
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

    // Resolve an operand to a compile-time integer, walking through
    // ZExt / SExt / Trunc of a Const (the widened-literal form). Returns YES
    // and writes *out when known.
    BOOL (^resolveConst)(XTIROperand*, int64_t*) = ^BOOL(XTIROperand* op, int64_t* out) {
      if (op.kind == XTIROperandKindImmI)
          {
          if (out)
              *out = op.intValue;
          return YES;
          }
      if (op.kind != XTIROperandKindUse)
          return NO;
      XTIRValueId cur = op.valueId;
      for (int depth = 0; depth < 16; depth++)
          {
          XTIRInsn* d = defOf[@(cur)];
          if (!d)
              return NO;
          if (d.opcode == XTIROpConst)
              {
              if (d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindImmI)
                  {
                  if (out)
                      *out = d.operands[0].intValue;
                  return YES;
                  }
              return NO;
              }
          if ((d.opcode == XTIROpZExt || d.opcode == XTIROpSExt || d.opcode == XTIROpTrunc) && d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindUse)
              {
              cur = d.operands[0].valueId;
              continue;
              }
          return NO;
          }
      return NO;
    };

    BOOL changed = NO;
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* insn = bb.instructions[i];
            XTIROpcode op = insn.opcode;
            if (op != XTIROpMul && op != XTIROpUDiv && op != XTIROpURem && op != XTIROpSDiv && op != XTIROpSRem)
                continue;
            if (insn.operands.count < 2 || !insn.result || insn.memoryResult)
                continue;

            // Constant must be the RHS; Mul is commutative so also try the
            // LHS, keeping the other operand as the variable `x`.
            int64_t c = 0;
            XTIROperand* xop = nil;
            if (resolveConst(insn.operands[1], &c))
                {
                xop = insn.operands[0];
                }
            else if (op == XTIROpMul && resolveConst(insn.operands[0], &c))
                {
                xop = insn.operands[1];
                }
            else
                {
                continue;
                }

            XTIRType* rt = insn.result.type;
            NSUInteger widthBits = (rt ? rt.byteWidth : 0) * 8;
            int k = log2IfPow2(c);
            // Keep the shift count in range so we never depend on the runtime
            // shift routine's out-of-range behaviour.
            BOOL pow2 = (k >= 1 && widthBits > 0 && (NSUInteger)k < widthBits);

            __block XTIRInsn* repl = nil;
            XTIRDbgLoc* dl = insn.dbgLoc;

            void (^makeBinImm)(XTIROpcode, int64_t, XTIRType*) =
                ^(XTIROpcode newOp, int64_t imm, XTIRType* immType) {
                  NSArray<XTIROperand*>* ops = @[ xop,
                                                  [XTIROperand immIWithType:immType
                                                                      value:imm] ];
                  repl = [[XTIRInsn alloc] initWithOpcode:newOp
                                                   result:insn.result
                                                 operands:ops
                                                   dbgLoc:dl];
                };
            void (^makeConstZero)(void) = ^{
              repl = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:insn.result
                                             operands:@[ [XTIROperand immIWithType:rt value:0] ]
                                               dbgLoc:dl];
            };

            // x*1 / x/1 reduce to x, but the xt6502 backend has no Copy
            // lowering and forwarding the value needs a use-rewrite, so those
            // identities are left alone; the power-of-2 and ×0 / %1 cases
            // (which emit a supported Shl/LShr/And/Const) are the win.
            switch (op)
                {
            case XTIROpMul:
                if (c == 0)
                    makeConstZero();
                else if (pow2)
                    makeBinImm(XTIROpShl, k, [XTIRType u8Type]);
                break;
            case XTIROpUDiv:
                if (pow2)
                    makeBinImm(XTIROpLShr, k, [XTIRType u8Type]);
                break;
            case XTIROpURem:
                if (c == 1)
                    makeConstZero();
                else if (pow2)
                    makeBinImm(XTIROpAnd, c - 1, rt);
                break;
            case XTIROpSRem:
                if (c == 1)
                    makeConstZero(); // x%1 == 0, any sign
                break;
            default:
                break;
                }

            if (repl)
                {
                bb.instructions[i] = repl;
                changed = YES;
                }
            }
        }
    if (!changed)
        return;

    // Dead-strip Const / ZExt / SExt / Trunc whose result is now unused
    // (the detached multiplier constant and its widening), to a fixpoint —
    // mirrors the const-operand-fold sweep.
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
