#import "XTIROptConstOperandFold.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"


// Both operands known: evaluate the operation at compile time, in the RESULT's
// width and signedness. Returns NO for anything whose value is not decidable
// here — a division (the divisor may be zero), a shift past the width, a type
// that is not an integer the host can hold.
static BOOL evalConstPair(XTIROpcode op, int64_t a, int64_t b, XTIRType* rty,
                          int64_t* out)
    {
    // 32 bits and under. A 64-bit result would have to be written back as an
    // immediate, and the two compilers spell a wide unsigned immediate
    // differently — not worth a divergence for a fold that never fires in a
    // hot loop.
    if (!rty || !XTIRTypeKindIsInteger(rty.kind) || rty.byteWidth == 0 ||
        rty.byteWidth > 4)
        return NO;
    int bits = (int)rty.byteWidth * 8;
    uint64_t mask = (bits >= 64) ? ~0ULL : ((1ULL << bits) - 1ULL);
    uint64_t ua = (uint64_t)a & mask, ub = (uint64_t)b & mask;
    uint64_t r;
    switch (op)
        {
        case XTIROpAdd:  r = ua + ub; break;
        case XTIROpSub:  r = ua - ub; break;
        case XTIROpAnd:  r = ua & ub; break;
        case XTIROpOr:   r = ua | ub; break;
        case XTIROpXor:  r = ua ^ ub; break;
        case XTIROpMul:  r = ua * ub; break;
        case XTIROpShl:
            if (b < 0 || b >= bits) return NO;
            r = ua << b;
            break;
        case XTIROpLShr:
            if (b < 0 || b >= bits) return NO;
            r = ua >> b;
            break;
        case XTIROpAShr:
            {
            if (b < 0 || b >= bits) return NO;
            int64_t sa = (int64_t)ua;
            if (bits < 64 && (ua & (1ULL << (bits - 1))))
                sa = (int64_t)(ua | ~mask);
            r = (uint64_t)(sa >> b);
            break;
            }
        default: return NO;
        }
    r &= mask;
    if (XTIRTypeKindIsSigned(rty.kind) && bits < 64 && (r & (1ULL << (bits - 1))))
        *out = (int64_t)(r | ~mask);
    else
        *out = (int64_t)r;
    return YES;
    }

// Add, Mul and the bitwise ops do not care which side a constant is on, but
// the immediate fold below only looks at the RHS. Canonicalising puts the
// constant where it can be used.
static BOOL isCommutative(XTIROpcode op)
    {
    return op == XTIROpAdd || op == XTIROpMul || op == XTIROpAnd ||
           op == XTIROpOr || op == XTIROpXor;
    }

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
    // To a fixed point: evaluating a constant pair turns an instruction into
    // a Const, which the next round can then fold into its consumer as an
    // immediate. One round leaves `mov w16,#160; add w16,w16,w11` where two
    // give `add w16,w11,#160`.
    for (XTIRFunction* fn in mod.functions)
        for (int round = 0; round < 8 && [self runOnFunction:fn]; round++)
            ;
    return YES;
    }

- (BOOL)runOnFunction:(XTIRFunction*)fn
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
    // A TRUNC on the way to the Const is walked too, but it narrows the value,
    // so each one is re-applied to the constant afterwards (innermost first) in
    // its own width and signedness. Without this a narrowed literal — which is
    // what a shift count becomes, since lowering gives the count a u8 type —
    // never folds, and the backend materialises the constant, homes it to a
    // frame slot and zero-extends it before a shift the hardware takes as an
    // immediate.
    NSMutableArray<NSNumber*>* truncBits = [NSMutableArray array];   // outermost first; <0 = signed
    NSNumber* (^resolveConst)(XTIRValueId) = ^NSNumber*(XTIRValueId vid) {
      XTIRValueId cur = vid;
      [truncBits removeAllObjects];
      for (int depth = 0; depth < 16; depth++)
          {
          XTIRInsn* d = defOf[@(cur)];
          if (!d)
              return nil;
          if (d.opcode == XTIROpConst)
              {
              if (!(d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindImmI))
                  return nil;
              int64_t v = d.operands[0].intValue;
              for (NSInteger i = (NSInteger)truncBits.count - 1; i >= 0; i--)
                  {
                  int64_t spec = truncBits[(NSUInteger)i].longLongValue;
                  int bits = (int)llabs(spec);
                  if (bits <= 0 || bits >= 64)
                      continue;
                  uint64_t mask = (1ULL << bits) - 1ULL;
                  uint64_t uv = (uint64_t)v & mask;
                  if (spec < 0 && (uv & (1ULL << (bits - 1))))
                      v = (int64_t)(uv | ~mask);          // sign-extend back
                  else
                      v = (int64_t)uv;
                  }
              return @(v);
              }
          if ((d.opcode == XTIROpZExt || d.opcode == XTIROpSExt) && d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindUse)
              {
              cur = d.operands[0].valueId;
              continue;
              }
          if (d.opcode == XTIROpTrunc && d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindUse)
              {
              XTIRType* rt = d.result.type;
              if (!rt || rt.byteWidth == 0 || rt.byteWidth > 8)
                  return nil;
              int64_t bits = (int64_t)rt.byteWidth * 8;
              [truncBits addObject:@(XTIRTypeKindIsSigned(rt.kind) ? -bits : bits)];
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
            BOOL foldable = insn.opcode == XTIROpAdd || insn.opcode == XTIROpSub || insn.opcode == XTIROpAnd || insn.opcode == XTIROpOr || insn.opcode == XTIROpXor || insn.opcode == XTIROpICmp || insn.opcode == XTIROpMul || insn.opcode == XTIROpShl || insn.opcode == XTIROpLShr || insn.opcode == XTIROpAShr || insn.opcode == XTIROpUDiv || insn.opcode == XTIROpSDiv || insn.opcode == XTIROpURem || insn.opcode == XTIROpSRem;
            if (!foldable || insn.operands.count < 2)
                continue;
            XTIROperand* lhs = insn.operands[0];
            XTIROperand* rhs = insn.operands[1];

            // Both sides constant: evaluate it. The unrollers substitute the
            // induction variable with a literal, so a fully unrolled body is
            // full of `Const k` feeding an arithmetic op on another constant —
            // matrix_mul's k loop unrolls 32 times and each copy recomputes
            // `k * M` at run time from two literals.
            NSNumber* lk = (lhs.kind == XTIROperandKindImmI)
                               ? @(lhs.intValue)
                               : (lhs.kind == XTIROperandKindUse ? resolveConst(lhs.valueId) : nil);
            NSNumber* rk = (rhs.kind == XTIROperandKindImmI)
                               ? @(rhs.intValue)
                               : (rhs.kind == XTIROperandKindUse ? resolveConst(rhs.valueId) : nil);
            int64_t folded = 0;
            if (lk && rk && insn.result &&
                evalConstPair(insn.opcode, lk.longLongValue, rk.longLongValue,
                              insn.result.type, &folded))
                {
                XTIRInsn* c = [[XTIRInsn alloc]
                    initWithOpcode:XTIROpConst
                            result:insn.result
                          operands:@[ [XTIROperand immIWithType:insn.result.type
                                                          value:folded] ]
                            dbgLoc:insn.dbgLoc];
                c.memoryResult = insn.memoryResult;
                bb.instructions[i] = c;
                changed = YES;
                continue;
                }
            // Constant on the left of a commutative op: swap it to the right,
            // where the immediate fold can see it.
            if (lk && !rk && isCommutative(insn.opcode) &&
                lhs.kind == XTIROperandKindUse && rhs.kind == XTIROperandKindUse)
                {
                NSMutableArray<XTIROperand*>* sw = [insn.operands mutableCopy];
                sw[0] = rhs;
                sw[1] = lhs;
                XTIRInsn* r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                        result:insn.result
                                                      operands:sw
                                                        dbgLoc:insn.dbgLoc];
                r.memoryResult = insn.memoryResult;
                bb.instructions[i] = r;
                insn = r;
                lhs = sw[0];
                rhs = sw[1];
                rk = lk;
                changed = YES;
                }

            if (rhs.kind != XTIROperandKindUse)
                continue;
            NSNumber* k = rk;
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
        return NO;

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
    return YES;
    }

@end
