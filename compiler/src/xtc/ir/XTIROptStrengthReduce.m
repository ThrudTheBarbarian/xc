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

// The bits of 1/c when c (a double's bits) is ±2^e and 1/c is a normal
// number of the type; NO otherwise.
static BOOL recipBits(uint64_t bits, BOOL f32, uint64_t* out)
    {
    if ((bits & 0xFFFFFFFFFFFFFULL) != 0)
        return NO;
    int64_t ex = (int64_t)((bits >> 52) & 0x7FF);
    if (ex == 0 || ex == 0x7FF)
        return NO;
    int64_t e = ex - 1023; // c = ±2^e, 1/c = ±2^-e
    int64_t lo = f32 ? -126 : -1022, hi = f32 ? 127 : 1023;
    if (-e < lo || -e > hi || e < lo || e > hi)
        return NO;
    *out = (bits & (1ULL << 63)) | ((uint64_t)(1023 - e) << 52);
    return YES;
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

// x / c, c = ±2^e, is x * (1/c) when 1/c is a normal number of the type: both
// are the one correctly rounded x·2^-e, NaN, infinities and signed zeros
// alike. The constant is rewritten in place, so every use of it must be such a
// divisor. On a target that fuses no plain multiply-add (profile.floatMulToAdd),
// x * 2 is x + x, and (x * -2) + c with the product read only there is
// c - (x + x): -2x is -(2x) exactly, and c + -(p) is c - p by definition.
// clang writes C's `0.0f - 2.0f * v` as fmuladd(-2, v, 0), which C perlin's
// gradient paid as two multiplies and an add where GCC does one add and a
// subtract from zero; the x + x it then shares with the other arm's 2v. Code
// under :goal(speed) is left as it is: its products fuse.
- (BOOL)runFloatOnFunction:(XTIRFunction*)fn defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
    {
    BOOL changed = NO;
    NSMutableDictionary<NSNumber*, NSMutableArray<XTIRInsn*>*>* uses = [NSMutableDictionary dictionary];
    void (^note)(XTIRInsn*) = ^(XTIRInsn* n) {
      for (XTIROperand* o in n.operands)
          {
          if (o.kind != XTIROperandKindUse)
              continue;
          NSMutableArray* l = uses[@(o.valueId)];
          if (!l)
              uses[@(o.valueId)] = l = [NSMutableArray array];
          [l addObject:n];
          }
    };
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* phi in bb.phiNodes)
            note(phi);
        for (XTIRInsn* insn in bb.instructions)
            note(insn);
        }
    BOOL (^isF)(XTIRType*) = ^BOOL(XTIRType* t) {
      return t && (t.kind == XTIRTypeKindF32 || t.kind == XTIRTypeKindF64);
    };
    // The Const defining o, when it is a float immediate of kind `k`.
    XTIRInsn* (^constOf)(XTIROperand*, XTIRTypeKind) = ^XTIRInsn*(XTIROperand* o, XTIRTypeKind k) {
      if (o.kind != XTIROperandKindUse)
          return nil;
      XTIRInsn* d = defOf[@(o.valueId)];
      if (!d || d.opcode != XTIROpConst || d.operands.count < 1 || !d.result || d.result.type.kind != k)
          return nil;
      if (d.operands[0].kind != XTIROperandKindImmF)
          return nil;
      return d;
    };
    BOOL (^isConst)(XTIROperand*, XTIRTypeKind, uint64_t) = ^BOOL(XTIROperand* o, XTIRTypeKind k, uint64_t bits) {
      XTIRInsn* d = constOf(o, k);
      return d && d.operands[0].floatRawBytes == bits;
    };
    // Replace n, wherever it sits, by `op` over the given operands.
    void (^retag)(XTIRInsn*, XTIROpcode, NSArray<XTIROperand*>*) = ^(XTIRInsn* n, XTIROpcode op, NSArray<XTIROperand*>* ops) {
      XTIRInsn* r = [[XTIRInsn alloc] initWithOpcode:op result:n.result operands:ops dbgLoc:n.dbgLoc];
      for (XTIRBlock* bb in fn.blocks)
          {
          NSUInteger at = [bb.instructions indexOfObjectIdenticalTo:n];
          if (at != NSNotFound)
              {
              bb.instructions[at] = r;
              return;
              }
          }
    };
    BOOL mulOk = self.profile.floatMulToAdd && fn.speedLoopHeaders.count == 0;
    const uint64_t two = 0x4000000000000000ULL, minusTwo = 0xC000000000000000ULL;
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* n = bb.instructions[i];
            if (!n.result || n.operands.count != 2 || n.predicate != XTIRFpExact || !isF(n.result.type))
                continue;
            XTIRTypeKind k = n.result.type.kind;
            XTIROperand *a = n.operands[0], *c = n.operands[1];
            if (n.opcode == XTIROpFDiv)
                {
                XTIRInsn* kc = constOf(c, k);
                uint64_t rb = 0;
                if (!kc || !recipBits(kc.operands[0].floatRawBytes, k == XTIRTypeKindF32, &rb))
                    continue;
                NSArray<XTIRInsn*>* us = uses[@(c.valueId)];
                BOOL allDiv = us != nil;
                for (XTIRInsn* u in us)
                    {
                    if (u.opcode != XTIROpFDiv || u.operands.count != 2 || u.predicate != XTIRFpExact || !u.result
                        || u.result.type.kind != k)
                        {
                        allDiv = NO;
                        break;
                        }
                    XTIROperand *u0 = u.operands[0], *u1 = u.operands[1];
                    if (u1.kind != XTIROperandKindUse || u1.valueId != c.valueId
                        || (u0.kind == XTIROperandKindUse && u0.valueId == c.valueId))
                        {
                        allDiv = NO;
                        break;
                        }
                    }
                if (!allDiv)
                    continue;
                [kc replaceOperands:@[ [XTIROperand immFWithType:kc.operands[0].type rawBytes:rb] ]];
                for (XTIRInsn* u in us)
                    retag(u, XTIROpFMul, u.operands);
                changed = YES;
                continue;
                }
            if (!mulOk)
                continue;
            if (n.opcode == XTIROpFMul)
                {
                XTIROperand* x = isConst(c, k, two) ? a : isConst(a, k, two) ? c : nil;
                if (!x)
                    continue;
                retag(n, XTIROpFAdd, @[ x, x ]);
                changed = YES;
                continue;
                }
            if (n.opcode == XTIROpFAdd)
                for (int side = 0; side < 2; side++)
                    {
                    XTIROperand* p = side == 0 ? a : c;
                    XTIROperand* o = side == 0 ? c : a;
                    if (p.kind != XTIROperandKindUse)
                        continue;
                    if (o.kind == XTIROperandKindUse && o.valueId == p.valueId)
                        continue;
                    XTIRInsn* d = defOf[@(p.valueId)];
                    if (!d || d.opcode != XTIROpFMul || d.operands.count != 2 || d.predicate != XTIRFpExact || !d.result
                        || d.result.type.kind != k)
                        continue;
                    if (uses[@(p.valueId)].count != 1)
                        continue;
                    XTIROperand *d0 = d.operands[0], *d1 = d.operands[1];
                    XTIROperand* x = isConst(d1, k, minusTwo) ? d0 : isConst(d0, k, minusTwo) ? d1 : nil;
                    if (!x)
                        continue;
                    retag(d, XTIROpFAdd, @[ x, x ]);
                    retag(n, XTIROpFSub, @[ o, p ]);
                    changed = YES;
                    break;
                    }
            }
        }
    return changed;
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

    BOOL changed = [self runFloatOnFunction:fn defOf:defOf];
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
