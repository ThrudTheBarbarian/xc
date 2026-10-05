#import "XTIRParMSL_Private.h"
#import "XTIROpcode.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

// A `par` block's kernel as PTX, for NVIDIA GPUs (par-blocks.md §6): the same
// kernel and the same header line as the Metal printer, from the same
// analysis. PTX takes arbitrary branches, so the CFG is printed as it is:
// every block a label, every phi a parallel move on each edge into it. SSA
// values are virtual registers; the block object's copy is a .local array.
// The driver compiles the text at run time (cuModuleLoadData), so a program
// needs no CUDA toolkit.
//
// Precise maths only: PTX has no precise sin, cos, exp, log or pow, so a block
// that calls one stays on the CPU (nil). 8- and 16-bit values live in 32-bit
// registers in one form: a signed one sign-extended, an unsigned one
// zero-extended, so a 32-bit compare of two of them is exact. Arithmetic on
// them is not printed (nil) in this first cut.

static NSString* ptxRegType(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindI16: case XTIRTypeKindU16:
        case XTIRTypeKindI32: case XTIRTypeKindU32:
            return @".b32";
        case XTIRTypeKindI64: case XTIRTypeKindU64: case XTIRTypeKindPtr:
            return @".b64";
        case XTIRTypeKindF32: return @".f32";
        case XTIRTypeKindF64: return @".f64";
        case XTIRTypeKindBool: return @".pred";
        default: return nil;
        }
    }

static BOOL ptxNarrow(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI8 || t.kind == XTIRTypeKindU8 || t.kind == XTIRTypeKindI16 ||
           t.kind == XTIRTypeKindU16;
    }

static BOOL ptxSigned(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI8 || t.kind == XTIRTypeKindI16 || t.kind == XTIRTypeKindI32 ||
           t.kind == XTIRTypeKindI64;
    }

static BOOL ptxWide(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64 || t.kind == XTIRTypeKindPtr;
    }

// The arithmetic suffix for an integer or float type: s32 u32 s64 u64 f32 f64.
static NSString* ptxArith(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI32: return @"s32";
        case XTIRTypeKindU32: return @"u32";
        case XTIRTypeKindI64: return @"s64";
        case XTIRTypeKindU64: case XTIRTypeKindPtr: return @"u64";
        case XTIRTypeKindF32: return @"f32";
        case XTIRTypeKindF64: return @"f64";
        default: return nil;
        }
    }

// A load or store's width suffix for a memory value of type t.
static NSString* ptxMem(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: return @"s8";
        case XTIRTypeKindU8: case XTIRTypeKindBool: return @"u8";
        case XTIRTypeKindI16: return @"s16";
        case XTIRTypeKindU16: return @"u16";
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"u32";
        case XTIRTypeKindI64: case XTIRTypeKindU64: case XTIRTypeKindPtr: return @"u64";
        case XTIRTypeKindF32: return @"f32";
        case XTIRTypeKindF64: return @"f64";
        default: return nil;
        }
    }

// A constant of type t in its register form: a narrow one extended by its own
// signedness.
static long long ptxNarrowValue(XTIRType* t, long long v)
    {
    if (t.kind == XTIRTypeKindI8)
        return (long long)(int8_t)v;
    if (t.kind == XTIRTypeKindU8)
        return (long long)(uint8_t)v;
    if (t.kind == XTIRTypeKindI16)
        return (long long)(int16_t)v;
    if (t.kind == XTIRTypeKindU16)
        return (long long)(uint16_t)v;
    return v;
    }

// The line that puts a narrow result in r back in its register form.
static NSString* ptxNarrowFix(XTIRType* t, NSString* r)
    {
    switch (t.kind)
        {
        case XTIRTypeKindU8: return [NSString stringWithFormat:@"\tand.b32 %@, %@, 255;\n", r, r];
        case XTIRTypeKindU16: return [NSString stringWithFormat:@"\tand.b32 %@, %@, 65535;\n", r, r];
        case XTIRTypeKindI8: return [NSString stringWithFormat:@"\tbfe.s32 %@, %@, 0, 8;\n", r, r];
        case XTIRTypeKindI16: return [NSString stringWithFormat:@"\tbfe.s32 %@, %@, 0, 16;\n", r, r];
        default: return @"";
        }
    }

@interface XTIRParPTXState : NSObject
@property(nonatomic) NSMutableString* out;
@property(nonatomic) NSUInteger edgeLabels;
@end
@implementation XTIRParPTXState
@end

@implementation XTIRParMSL (PTX)

+ (nullable NSString*)ptxForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                why:(NSString* _Nullable* _Nullable)why
    {
    XTIRParMSL* p = [XTIRParMSL new];
    p.module = module;
    p.fn = run;
    p.fast = fast;
    p.helperText = [NSMutableArray array];
    p.helperNames = [NSMutableSet set];
    NSString* out = [p ptxKernel];
    if (!out && why)
        *why = p.why;
    return out;
    }

- (NSString*)ptxReg:(XTIRValueId)v
    {
    if (self.helperMode && v + 1 < self.fn.paramTypes.count)
        return [NSString stringWithFormat:@"%%a%llu", (unsigned long long)v];
    return [NSString stringWithFormat:@"%%v%lu", (unsigned long)[self.ordinal[@(v)] unsignedIntegerValue]];
    }

// An operand as a register or an immediate in t's PTX spelling.
- (nullable NSString*)ptxOp:(XTIROperand*)op type:(nullable XTIRType*)t
    {
    if (op.kind == XTIROperandKindUse)
        return [self ptxReg:op.valueId];
    if (op.kind == XTIROperandKindImmI)
        {
        return [NSString stringWithFormat:@"%lld", ptxNarrowValue(t, (long long)op.intValue)];
        }
    if (op.kind == XTIROperandKindImmF)
        {
        uint64_t raw = op.floatRawBytes;
        if (t.kind == XTIRTypeKindF64)
            return [NSString stringWithFormat:@"0d%016llX", (unsigned long long)raw];
        double d;
        memcpy(&d, &raw, sizeof d);
        float f = (float)d;
        uint32_t bits;
        memcpy(&bits, &f, sizeof bits);
        return [NSString stringWithFormat:@"0f%08X", bits];
        }
    return nil;
    }

// Declare every value's register (and a copy register per phi).
- (nullable NSString*)ptxDecls
    {
    NSMutableString* d = [NSMutableString string];
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            {
            if (!i.result || i.result.type.kind == XTIRTypeKindMemory)
                continue;
            NSString* rt = ptxRegType(i.result.type);
            if (!rt)
                return nil;
            NSUInteger o = [self.ordinal[@(i.result.valueId)] unsignedIntegerValue];
            [d appendFormat:@"\t.reg %@ %%v%lu, %%c%lu;\n", rt, (unsigned long)o, (unsigned long)o];
            }
        for (XTIRInsn* i in b.instructions)
            {
            if (!i.result || i.result.type.kind == XTIRTypeKindMemory)
                continue;
            NSString* rt = ptxRegType(i.result.type);
            if (!rt)
                return nil;
            [d appendFormat:@"\t.reg %@ %@;\n", rt, [self ptxReg:i.result.valueId]];
            }
        }
    return d;
    }

// The moves for the edge from -> target: through the copy registers, so a
// phi that reads another phi of the same block reads its old value.
- (nullable NSString*)ptxCopiesFrom:(XTIRBlock*)from to:(XTIRBlock*)target
    {
    NSMutableString* a = [NSMutableString string];
    NSMutableString* b = [NSMutableString string];
    for (XTIRInsn* phi in target.phiNodes)
        {
        if (!phi.result || phi.result.type.kind == XTIRTypeKindMemory)
            continue;
        XTIROperand* in = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].blockRef == from)
                in = phi.operands[k + 1];
        NSString* src = in ? [self ptxOp:in type:phi.result.type] : nil;
        NSString* rt = ptxRegType(phi.result.type);
        if (!src || !rt)
            return nil;
        NSUInteger o = [self.ordinal[@(phi.result.valueId)] unsignedIntegerValue];
        NSString* mt = [rt isEqualToString:@".pred"] ? @".pred" : rt;
        [a appendFormat:@"\tmov%@ %%c%lu, %@;\n", mt, (unsigned long)o, src];
        [b appendFormat:@"\tmov%@ %%v%lu, %%c%lu;\n", mt, (unsigned long)o, (unsigned long)o];
        }
    [a appendString:b];
    return a;
    }

// An address: device pointers are global, the block's own copy local.
- (NSString*)ptxSpaceOf:(XTIROperand*)addr
    {
    return [self.space[@(addr.valueId)] unsignedIntegerValue] == XTParSpaceDevice ? @"global" : @"local";
    }

- (nullable NSString*)ptxStatement:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    NSString* r = i.result ? [self ptxReg:i.result.valueId] : nil;
    NSArray<XTIROperand*>* o = i.operands;
    switch (i.opcode)
        {
        case XTIROpConst:
            {
            if (rt.kind == XTIRTypeKindBool)
                return [NSString stringWithFormat:@"\tmov.b32 %%k, %lld;\n\tsetp.ne.s32 %@, %%k, 0;\n",
                                                  (long long)o[0].intValue, r];
            NSString* v = [self ptxOp:o[0] type:rt];
            NSString* t = ptxRegType(rt);
            return (v && t) ? [NSString stringWithFormat:@"\tmov%@ %@, %@;\n", t, r, v] : nil;
            }
        case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpUDiv: case XTIROpSDiv:
        case XTIROpURem: case XTIROpSRem: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
        case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
        case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv:
            {
            if (ptxNarrow(rt) || rt.kind == XTIRTypeKindBool)
                return nil; // first cut: no 8/16-bit or bool arithmetic
            NSString* a = [self ptxOp:o[0] type:rt];
            NSString* b = [self ptxOp:o[1] type:rt];
            NSString* sfx = ptxArith(rt);
            if (!a || !b || !sfx)
                return nil;
            NSString* bits = ptxWide(rt) ? @"b64" : @"b32";
            NSString* us = ptxWide(rt) ? @"u64" : @"u32";
            NSString* ss = ptxWide(rt) ? @"s64" : @"s32";
            BOOL fl = rt.kind == XTIRTypeKindF32 || rt.kind == XTIRTypeKindF64;
            NSString* line = nil;
            switch (i.opcode)
                {
                case XTIROpAdd: line = [NSString stringWithFormat:@"add.%@", sfx]; break;
                case XTIROpSub: line = [NSString stringWithFormat:@"sub.%@", sfx]; break;
                case XTIROpMul: line = [NSString stringWithFormat:@"mul.lo.%@", sfx]; break;
                case XTIROpUDiv: line = [NSString stringWithFormat:@"div.%@", us]; break;
                case XTIROpSDiv: line = [NSString stringWithFormat:@"div.%@", ss]; break;
                case XTIROpURem: line = [NSString stringWithFormat:@"rem.%@", us]; break;
                case XTIROpSRem: line = [NSString stringWithFormat:@"rem.%@", ss]; break;
                case XTIROpAnd: line = [NSString stringWithFormat:@"and.%@", bits]; break;
                case XTIROpOr: line = [NSString stringWithFormat:@"or.%@", bits]; break;
                case XTIROpXor: line = [NSString stringWithFormat:@"xor.%@", bits]; break;
                case XTIROpFAdd: line = [NSString stringWithFormat:@"add.rn.%@", sfx]; break;
                case XTIROpFSub: line = [NSString stringWithFormat:@"sub.rn.%@", sfx]; break;
                case XTIROpFMul: line = [NSString stringWithFormat:@"mul.rn.%@", sfx]; break;
                case XTIROpFDiv: line = [NSString stringWithFormat:@"div.rn.%@", sfx]; break;
                case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
                    {
                    // The shift count is a u32 operand.
                    NSString* op = i.opcode == XTIROpShl ? [NSString stringWithFormat:@"shl.%@", bits]
                                 : i.opcode == XTIROpLShr ? [NSString stringWithFormat:@"shr.%@", us]
                                                          : [NSString stringWithFormat:@"shr.%@", ss];
                    if (ptxWide(rt) && o[1].kind == XTIROperandKindUse)
                        return [NSString stringWithFormat:@"\tcvt.u32.u64 %%k, %@;\n\t%@ %@, %@, %%k;\n", b, op, r, a];
                    return [NSString stringWithFormat:@"\t%@ %@, %@, %@;\n", op, r, a, b];
                    }
                default: break;
                }
            (void)fl;
            return line ? [NSString stringWithFormat:@"\t%@ %@, %@, %@;\n", line, r, a, b] : nil;
            }
        case XTIROpNot:
            {
            NSString* a = [self ptxOp:o[0] type:rt];
            if (!a)
                return nil;
            if (rt.kind == XTIRTypeKindBool)
                return [NSString stringWithFormat:@"\tnot.pred %@, %@;\n", r, a];
            if (ptxNarrow(rt))
                {
                // In 32 bits, then back in the register form.
                if (o[0].kind == XTIROperandKindImmI)
                    return [NSString stringWithFormat:@"\tmov.b32 %@, %lld;\n", r, ptxNarrowValue(rt, ~(long long)o[0].intValue)];
                return [[NSString stringWithFormat:@"\tnot.b32 %@, %@;\n", r, a] stringByAppendingString:ptxNarrowFix(rt, r)];
                }
            return [NSString stringWithFormat:@"\tnot.%@ %@, %@;\n", ptxWide(rt) ? @"b64" : @"b32", r, a];
            }
        case XTIROpNeg:
        case XTIROpFNeg:
            {
            NSString* a = [self ptxOp:o[0] type:rt];
            if (a && ptxNarrow(rt))
                {
                // In 32 bits, then back in the register form.
                if (o[0].kind == XTIROperandKindImmI)
                    return [NSString stringWithFormat:@"\tmov.b32 %@, %lld;\n", r, ptxNarrowValue(rt, -(long long)o[0].intValue)];
                return [[NSString stringWithFormat:@"\tneg.s32 %@, %@;\n", r, a] stringByAppendingString:ptxNarrowFix(rt, r)];
                }
            NSString* sfx = ptxArith(rt);
            if (!a || !sfx)
                return nil;
            if (rt.kind == XTIRTypeKindU32)
                sfx = @"s32";
            if (rt.kind == XTIRTypeKindU64)
                sfx = @"s64";
            return [NSString stringWithFormat:@"\tneg.%@ %@, %@;\n", sfx, r, a];
            }
        case XTIROpFSqrt:
            {
            NSString* a = [self ptxOp:o[0] type:rt];
            return a ? [NSString stringWithFormat:@"\tsqrt.rn.%@ %@, %@;\n", ptxArith(rt), r, a] : nil;
            }
        case XTIROpICmp:
        case XTIROpFCmp:
            {
            XTIRType* t = o[0].kind == XTIROperandKindUse ? [self typeOf:o[0].valueId]
                                                          : [self typeOf:o[1].valueId];
            // An 8- or 16-bit value sits in its 32-bit register extended by its
            // own signedness, so it compares as a 32-bit one.
            if (!t || t.kind == XTIRTypeKindBool)
                return nil;
            NSString* a = [self ptxOp:o[0] type:t];
            NSString* b = [self ptxOp:o[1] type:t];
            if (!a || !b)
                return nil;
            NSString* cmp = nil;
            NSString* ty = nil;
            if (i.opcode == XTIROpFCmp)
                {
                static NSString* f[] = { @"eq", @"ne", @"lt", @"gt", @"le", @"ge" };
                if (i.predicate > XTIRFCmpOGE)
                    return nil;
                cmp = f[i.predicate];
                ty = ptxArith(t);
                }
            else
                {
                static NSString* c[] = { @"eq", @"ne", @"lt", @"gt", @"le", @"ge", @"lt", @"gt", @"le", @"ge" };
                if (i.predicate > XTIRICmpUGE)
                    return nil;
                cmp = c[i.predicate];
                BOOL sg = i.predicate >= XTIRICmpSLT && i.predicate <= XTIRICmpSGE;
                ty = ptxWide(t) ? (sg ? @"s64" : @"u64") : (sg ? @"s32" : @"u32");
                }
            return [NSString stringWithFormat:@"\tsetp.%@.%@ %@, %@, %@;\n", cmp, ty, r, a, b];
            }
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
        case XTIROpCopy:
            {
            XTIRType* st = o[0].kind == XTIROperandKindUse ? [self typeOf:o[0].valueId] : rt;
            NSString* a = [self ptxOp:o[0] type:st];
            if (!a || !st)
                return nil;
            if (st.kind == XTIRTypeKindBool)
                {
                if (rt.kind == XTIRTypeKindBool)
                    return [NSString stringWithFormat:@"\tmov.pred %@, %@;\n", r, a];
                return [NSString stringWithFormat:@"\tselp.%@ %@, 1, 0, %@;\n", ptxWide(rt) ? @"b64" : @"b32", r, a];
                }
            if (rt.kind == XTIRTypeKindBool)
                return [NSString stringWithFormat:@"\tsetp.ne.%@ %@, %@, 0;\n", ptxWide(st) ? @"u64" : @"u32", r, a];
            BOOL sw = ptxWide(st), rw = ptxWide(rt);
            if (i.opcode == XTIROpTrunc)
                {
                NSString* lo = sw ? [NSString stringWithFormat:@"\tcvt.u32.u64 %@, %@;\n", r, a]
                                  : [NSString stringWithFormat:@"\tmov.b32 %@, %@;\n", r, a];
                if (rw)
                    return [NSString stringWithFormat:@"\tmov.b64 %@, %@;\n", r, a];
                if (rt.kind == XTIRTypeKindU8)
                    return [lo stringByAppendingFormat:@"\tand.b32 %@, %@, 255;\n", r, r];
                if (rt.kind == XTIRTypeKindU16)
                    return [lo stringByAppendingFormat:@"\tand.b32 %@, %@, 65535;\n", r, r];
                if (rt.kind == XTIRTypeKindI8)
                    return [lo stringByAppendingFormat:@"\tbfe.s32 %@, %@, 0, 8;\n", r, r];
                if (rt.kind == XTIRTypeKindI16)
                    return [lo stringByAppendingFormat:@"\tbfe.s32 %@, %@, 0, 16;\n", r, r];
                return lo;
                }
            if (i.opcode == XTIROpSExt && ptxNarrow(st))
                {
                NSString* bits = (st.kind == XTIRTypeKindI8 || st.kind == XTIRTypeKindU8) ? @"8" : @"16";
                NSString* x = [NSString stringWithFormat:@"\tbfe.s32 %%k, %@, 0, %@;\n", a, bits];
                if (rw)
                    return [x stringByAppendingFormat:@"\tcvt.s64.s32 %@, %%k;\n", r];
                return [x stringByAppendingFormat:@"\tmov.b32 %@, %%k;\n", r];
                }
            if (i.opcode == XTIROpZExt && (st.kind == XTIRTypeKindI8 || st.kind == XTIRTypeKindI16))
                {
                // A signed narrow value is sign-extended in its register:
                // zero-extending it clears those bits first.
                NSString* x = [NSString stringWithFormat:@"\tand.b32 %%k, %@, %@;\n", a,
                                                         st.kind == XTIRTypeKindI8 ? @"255" : @"65535"];
                if (rw)
                    return [x stringByAppendingFormat:@"\tcvt.u64.u32 %@, %%k;\n", r];
                return [x stringByAppendingFormat:@"\tmov.b32 %@, %%k;\n", r];
                }
            if (!sw && rw)
                return [NSString stringWithFormat:@"\tcvt.%@64.%@32 %@, %@;\n",
                                                  i.opcode == XTIROpSExt ? @"s" : @"u",
                                                  i.opcode == XTIROpSExt ? @"s" : @"u", r, a];
            return [NSString stringWithFormat:@"\tmov.%@ %@, %@;\n", rw ? @"b64" : @"b32", r, a];
            }
        case XTIROpBitcast:
            {
            // The same bits under another type: a move, and a narrow result
            // put back in its register form (an i8 read as a u8).
            XTIRType* st = o[0].kind == XTIROperandKindUse ? [self typeOf:o[0].valueId] : rt;
            NSString* a = [self ptxOp:o[0] type:st];
            if (!a || !st || rt.kind == XTIRTypeKindBool || st.kind == XTIRTypeKindBool)
                return nil;
            BOOL w = ptxWide(rt) || rt.kind == XTIRTypeKindF64;
            NSString* mv = [NSString stringWithFormat:@"\tmov.b%@ %@, %@;\n", w ? @"64" : @"32", r, a];
            return [mv stringByAppendingString:ptxNarrowFix(rt, r)];
            }
        case XTIROpSIToFp:
        case XTIROpUIToFp:
        case XTIROpFpToSI:
        case XTIROpFpToUI:
        case XTIROpFpExt:
        case XTIROpFpTrunc:
            {
            XTIRType* st = o[0].kind == XTIROperandKindUse ? [self typeOf:o[0].valueId] : rt;
            NSString* a = [self ptxOp:o[0] type:st];
            if (!a || ptxNarrow(st) || ptxNarrow(rt))
                return nil;
            NSString* d = ptxArith(rt);
            NSString* s = ptxArith(st);
            if (i.opcode == XTIROpUIToFp)
                s = ptxWide(st) ? @"u64" : @"u32";
            if (i.opcode == XTIROpFpToUI)
                d = ptxWide(rt) ? @"u64" : @"u32";
            if (i.opcode == XTIROpSIToFp)
                s = ptxWide(st) ? @"s64" : @"s32";
            if (i.opcode == XTIROpFpToSI)
                d = ptxWide(rt) ? @"s64" : @"s32";
            if (!d || !s)
                return nil;
            NSString* mode = (i.opcode == XTIROpFpToSI || i.opcode == XTIROpFpToUI) ? @".rzi"
                           : i.opcode == XTIROpFpExt ? @"" : @".rn";
            return [NSString stringWithFormat:@"\tcvt%@.%@.%@ %@, %@;\n", mode, d, s, r, a];
            }
        case XTIROpSelect:
            {
            if (rt.kind == XTIRTypeKindBool)
                return nil;
            NSString* c = [self ptxOp:o[0] type:nil];
            NSString* a = [self ptxOp:o[1] type:rt];
            NSString* b = [self ptxOp:o[2] type:rt];
            NSString* t = ptxNarrow(rt) ? @"b32" : (ptxWide(rt) ? @"b64" : ptxArith(rt));
            return (c && a && b && t) ? [NSString stringWithFormat:@"\tselp.%@ %@, %@, %@, %@;\n", t, r, a, b, c] : nil;
            }
        case XTIROpFieldAddr:
            {
            NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:i.result.valueId]];
            if (k >= 0 && self.objLayout.fields[(NSUInteger)k].type.kind == XTIRTypeKindPtr)
                return @""; // a captured array's slot: only ever loaded, as the buffer
            if (k >= 0)
                return [NSString stringWithFormat:@"\tadd.u64 %@, %%stp, %u;\n", r,
                                                  self.objLayout.fields[(NSUInteger)k].byteOffset];
            XTIRType* bt = [self typeOf:o[0].valueId];
            XTIRLayout* l = bt.pointeeType.layout;
            NSInteger f = (NSInteger)o[1].intValue;
            if (!l || f < 0 || (NSUInteger)f >= l.fields.count)
                return nil;
            return [NSString stringWithFormat:@"\tadd.u64 %@, %@, %u;\n", r, [self ptxReg:o[0].valueId],
                                              l.fields[(NSUInteger)f].byteOffset];
            }
        case XTIROpElementAddr:
            {
            XTIRType* pt = [self typeOf:o[0].valueId];
            uint32_t size = pt.pointeeType.byteWidth;
            NSString* base = [self ptxReg:o[0].valueId];
            if (o[1].kind == XTIROperandKindImmI)
                return [NSString stringWithFormat:@"\tadd.u64 %@, %@, %lld;\n", r, base, (long long)o[1].intValue * size];
            XTIRType* it = [self typeOf:o[1].valueId];
            NSString* idx = [self ptxReg:o[1].valueId];
            NSMutableString* s = [NSMutableString string];
            if (ptxWide(it))
                [s appendFormat:@"\tmov.b64 %%x, %@;\n", idx];
            else
                [s appendFormat:@"\tcvt.%@64.%@32 %%x, %@;\n", ptxSigned(it) ? @"s" : @"u", ptxSigned(it) ? @"s" : @"u", idx];
            [s appendFormat:@"\tmad.lo.u64 %@, %%x, %u, %@;\n", r, size, base];
            return s;
            }
        case XTIROpAddrOf:
            {
            if (self.sinitOf[@(i.result.valueId)])
                return @"";
            NSString* g = self.globalOf[@(i.result.valueId)];
            if (!g)
                return nil;
            return [NSString stringWithFormat:@"\tld.param.u64 %@, [glob_%lu];\n\tcvta.to.global.u64 %@, %@;\n", r,
                                              (unsigned long)[self.globals indexOfObject:g], r, r];
            }
        case XTIROpLoad:
            {
            NSNumber* buf = self.bufferOf[@(i.result.valueId)];
            if (buf)
                return [NSString stringWithFormat:@"\tld.param.u64 %@, [buf_%@];\n\tcvta.to.global.u64 %@, %@;\n", r, buf, r, r];
            NSString* m = ptxMem(rt);
            if (!m)
                return nil;
            if ([self.sinitOf[@(o[0].valueId)] boolValue]) // a static-init flag: done
                return [NSString stringWithFormat:@"\tmov.b32 %@, 2;\n", r];
            NSString* sp = [self ptxSpaceOf:o[0]];
            NSString* a = [self ptxReg:o[0].valueId];
            if (rt.kind == XTIRTypeKindBool)
                return [NSString stringWithFormat:@"\tld.%@.u8 %%k, [%@];\n\tsetp.ne.u32 %@, %%k, 0;\n", sp, a, r];
            return [NSString stringWithFormat:@"\tld.%@.%@ %@, [%@];\n", sp, m, r, a];
            }
        case XTIROpStore:
            {
            if (o[0].kind != XTIROperandKindUse)
                return nil;
            XTIRType* pt = [self typeOf:o[0].valueId].pointeeType;
            NSString* m = ptxMem(pt);
            NSString* v = [self ptxOp:o[1] type:pt];
            if (!m || !v)
                return nil;
            NSString* sp = [self ptxSpaceOf:o[0]];
            NSString* a = [self ptxReg:o[0].valueId];
            if (pt.kind == XTIRTypeKindBool && o[1].kind != XTIROperandKindUse)
                return [NSString stringWithFormat:@"\tmov.b32 %%k, %@;\n\tst.%@.u8 [%@], %%k;\n", v, sp, a];
            if (pt.kind == XTIRTypeKindBool)
                return [NSString stringWithFormat:@"\tselp.b32 %%k, 1, 0, %@;\n\tst.%@.u8 [%@], %%k;\n", v, sp, a];
            if (o[1].kind != XTIROperandKindUse)
                {
                NSString* t = ptxRegType(pt);
                NSString* tmp = [t isEqualToString:@".b64"] ? @"%x" : [t isEqualToString:@".f32"] ? @"%fk"
                              : [t isEqualToString:@".f64"] ? @"%dk" : @"%k";
                return [NSString stringWithFormat:@"\tmov%@ %@, %@;\n\tst.%@.%@ [%@], %@;\n", t, tmp, v, sp, m, a, tmp];
                }
            return [NSString stringWithFormat:@"\tst.%@.%@ [%@], %@;\n", sp, m, a, v];
            }
        case XTIROpCall:
            {
            XTIRSymbol* sym = [self.module symbolForId:o[0].symbolId];
            NSString* callee = sym.name;
            if ([callee isEqualToString:@"_xtc_sinit_run"] || [callee hasSuffix:@"$init"])
                return @"";
            BOOL isVoid = !rt || rt.kind == XTIRTypeKindMemory;
            NSMutableArray<NSString*>* args = [NSMutableArray array];
            NSMutableArray<XTIRType*>* argTypes = [NSMutableArray array];
            for (NSUInteger k = 1; k < o.count; k++)
                {
                XTIRType* at = o[k].kind == XTIROperandKindUse ? [self typeOf:o[k].valueId] : rt;
                if (at.kind == XTIRTypeKindMemory)
                    continue;
                NSString* e = [self ptxOp:o[k] type:at];
                if (!e)
                    return nil;
                [args addObject:e];
                [argTypes addObject:at];
                }
            // The precise maths PTX has as instructions.
            NSString* m = callee;
            if ([m hasPrefix:@"Math$"])
                m = [m substringFromIndex:5];
            NSRange cut = [m rangeOfString:@"__"];
            if (cut.location != NSNotFound)
                m = [m substringToIndex:cut.location];
            if ([m hasPrefix:@"_xm_"])
                m = [m substringFromIndex:4];
            if ([m hasSuffix:@"f"] && m.length > 3)
                m = [m substringToIndex:m.length - 1];
            BOOL fl = rt.kind == XTIRTypeKindF32 || rt.kind == XTIRTypeKindF64;
            if (!isVoid && fl && [m isEqualToString:@"sqrt"] && args.count == 1)
                return [NSString stringWithFormat:@"\tsqrt.rn.%@ %@, %@;\n", ptxArith(rt), r, args[0]];
            if (!isVoid && fl && [m isEqualToString:@"fma"] && args.count == 3)
                return [NSString stringWithFormat:@"\tfma.rn.%@ %@, %@, %@, %@;\n", ptxArith(rt), r, args[0], args[1], args[2]];
            if (!isVoid && fl && [m isEqualToString:@"floor"] && args.count == 1)
                return [NSString stringWithFormat:@"\tcvt.rmi.%@.%@ %@, %@;\n", ptxArith(rt), ptxArith(rt), r, args[0]];
            if (!isVoid && ([m isEqualToString:@"abs"] || [m isEqualToString:@"fabs"]) && args.count == 1 && ptxArith(rt))
                return [NSString stringWithFormat:@"\tabs.%@ %@, %@;\n", fl ? ptxArith(rt) : (ptxWide(rt) ? @"s64" : @"s32"), r, args[0]];
            if (!isVoid && ([m isEqualToString:@"min"] || [m isEqualToString:@"max"]) && args.count == 2 && ptxArith(rt))
                return [NSString stringWithFormat:@"\t%@.%@ %@, %@, %@;\n", m, ptxArith(rt), r, args[0], args[1]];
            if ([@[ @"sin", @"cos", @"exp", @"ln", @"log", @"pow" ] containsObject:m])
                {
                // No precise PTX instruction: the CPU runs this block, unless
                // its goal is speed and it is single precision, where the
                // GPU's own approximations will do (exp through ex2, ln
                // through lg2).
                if (!self.fast || isVoid || rt.kind != XTIRTypeKindF32)
                    return nil;
                if (([m isEqualToString:@"sin"] || [m isEqualToString:@"cos"]) && args.count == 1)
                    return [NSString stringWithFormat:@"\t%@.approx.f32 %@, %@;\n", m, r, args[0]];
                if ([m isEqualToString:@"exp"] && args.count == 1)
                    return [NSString stringWithFormat:@"\tmul.f32 %%fk, %@, 0f3FB8AA3B;\n\tex2.approx.f32 %@, %%fk;\n",
                                                      args[0], r];
                if (([m isEqualToString:@"ln"] || [m isEqualToString:@"log"]) && args.count == 1)
                    return [NSString stringWithFormat:@"\tlg2.approx.f32 %%fk, %@;\n\tmul.f32 %@, %%fk, 0f3F317218;\n",
                                                      args[0], r];
                if ([m isEqualToString:@"pow"] && args.count == 2)
                    return [NSString stringWithFormat:@"\tlg2.approx.f32 %%fk, %@;\n\tmul.f32 %%fk, %%fk, %@;\n"
                                                      @"\tex2.approx.f32 %@, %%fk;\n",
                                                      args[0], args[1], r];
                return nil;
                }
            // A function of the program: printed once, before the kernel.
            XTIRFunction* target = nil;
            for (XTIRFunction* g in self.module.functions)
                if ([g.name isEqualToString:callee])
                    target = g;
            if (!target)
                return nil;
            NSString* fn = [@"h_" stringByAppendingString:[callee stringByReplacingOccurrencesOfString:@"$" withString:@"_"]];
            if (![self.helperNames containsObject:callee])
                {
                [self.helperNames addObject:callee];
                XTIRParMSL* h = [XTIRParMSL new];
                h.module = self.module;
                h.fn = target;
                h.helperMode = YES;
                h.fast = self.fast;
                h.helperText = self.helperText;
                h.helperNames = self.helperNames;
                NSString* text = [h ptxHelper:fn];
                if (!text)
                    {
                    [self because:[self callFailed:callee helper:h]];
                    return nil;
                    }
                [self.helperText addObject:text];
                }
            NSMutableString* s = [NSMutableString stringWithString:@"\t{\n"];
            NSMutableArray<NSString*>* pnames = [NSMutableArray array];
            for (NSUInteger k = 0; k < args.count; k++)
                {
                NSString* pt = ptxRegType(argTypes[k]);
                if (!pt || [pt isEqualToString:@".pred"])
                    return nil;
                [s appendFormat:@"\t.param %@ q%lu;\n\tst.param%@ [q%lu], %@;\n", pt, (unsigned long)k, pt,
                                (unsigned long)k, args[k]];
                [pnames addObject:[NSString stringWithFormat:@"q%lu", (unsigned long)k]];
                }
            if (isVoid)
                [s appendFormat:@"\tcall.uni %@, (%@);\n", fn, [pnames componentsJoinedByString:@", "]];
            else
                {
                NSString* pt = ptxRegType(rt);
                if (!pt || [pt isEqualToString:@".pred"])
                    return nil;
                [s appendFormat:@"\t.param %@ rq;\n\tcall.uni (rq), %@, (%@);\n\tld.param%@ %@, [rq];\n", pt, fn,
                                [pnames componentsJoinedByString:@", "], pt, r];
                }
            [s appendString:@"\t}\n"];
            return s;
            }
        case XTIROpDbgValue:
            return @"";
        default:
            return nil;
        }
    }

// The blocks as labels: statements, then the edge moves and the branch.
- (nullable NSString*)ptxBody:(NSString*)endLabel
    {
    NSMutableString* s = [NSMutableString string];
    NSUInteger edge = 0;
    for (NSUInteger bi = 0; bi < self.fn.blocks.count; bi++)
        {
        XTIRBlock* b = self.fn.blocks[bi];
        [s appendFormat:@"BB%lu:\n", (unsigned long)bi];
        for (XTIRInsn* i in b.instructions)
            {
            NSString* st = [self ptxStatement:i];
            if (!st)
                {
                [self because:[self whyFor:i ptx:YES]];
                return nil;
                }
            [s appendString:st];
            }
        XTIRInsn* t = b.terminator;
        if (t.opcode == XTIROpBranch)
            {
            XTIRBlock* to = t.operands[0].blockRef;
            NSString* c = [self ptxCopiesFrom:b to:to];
            if (!c)
                return nil;
            [s appendFormat:@"%@\tbra.uni BB%lu;\n", c, (unsigned long)[self.blockIndex[to.name] unsignedIntegerValue]];
            }
        else if (t.opcode == XTIROpCondBranch)
            {
            XTIRBlock* tt = t.operands[1].blockRef;
            XTIRBlock* ff = t.operands[2].blockRef;
            NSString* c = [self ptxOp:t.operands[0] type:nil];
            NSString* ct = [self ptxCopiesFrom:b to:tt];
            NSString* cf = [self ptxCopiesFrom:b to:ff];
            if (!c || !ct || !cf)
                return nil;
            NSUInteger e = edge++;
            [s appendFormat:@"\t@%@ bra E%lu;\n%@\tbra.uni BB%lu;\nE%lu:\n%@\tbra.uni BB%lu;\n", c, (unsigned long)e, cf,
                            (unsigned long)[self.blockIndex[ff.name] unsignedIntegerValue], (unsigned long)e, ct,
                            (unsigned long)[self.blockIndex[tt.name] unsignedIntegerValue]];
            }
        else if (t.opcode == XTIROpReturn)
            {
            if (self.helperMode)
                {
                XTIROperand* rv = t.operands.count ? t.operands[0] : nil;
                XTIRType* rvt = !rv ? nil : rv.kind == XTIROperandKindUse ? [self typeOf:rv.valueId] : self.fn.returnType;
                if (rvt && rvt.kind != XTIRTypeKindMemory && rvt.kind != XTIRTypeKindVoid)
                    {
                    NSString* v = [self ptxOp:rv type:rvt];
                    NSString* pt = ptxRegType(rvt);
                    if (!v || !pt)
                        return nil;
                    [s appendFormat:@"\tst.param%@ [rv], %@;\n", pt, v];
                    }
                [s appendString:@"\tret;\n"];
                }
            else
                [s appendFormat:@"\tbra.uni %@;\n", endLabel];
            }
        else
            return nil;
        }
    return s;
    }

- (void)ptxOrdinals
    {
    NSUInteger bi = 0;
    for (XTIRBlock* b in self.fn.blocks)
        self.blockIndex[b.name] = @(bi++);
    self.ordinal = [NSMutableDictionary dictionary];
    NSUInteger ord = 0;
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            if (i.result && i.result.type.kind != XTIRTypeKindMemory)
                self.ordinal[@(i.result.valueId)] = @(ord++);
        for (XTIRInsn* i in b.instructions)
            if (i.result && i.result.type.kind != XTIRTypeKindMemory)
                self.ordinal[@(i.result.valueId)] = @(ord++);
        }
    }

- (void)ptxReset
    {
    self.def = [NSMutableDictionary dictionary];
    self.space = [NSMutableDictionary dictionary];
    self.bufferOf = [NSMutableDictionary dictionary];
    self.bufferFields = [NSMutableIndexSet indexSet];
    self.reductionFields = [NSMutableIndexSet indexSet];
    self.blockIndex = [NSMutableDictionary dictionary];
    self.globals = [NSMutableArray array];
    self.globalOf = [NSMutableDictionary dictionary];
    }

// A helper as a .func: scalars in and out, as .param values.
- (nullable NSString*)ptxHelper:(NSString*)name
    {
    [self ptxReset];
    if (![self analyse])
        return nil;
    [self ptxOrdinals];
    NSMutableArray<NSString*>* params = [NSMutableArray array];
    NSMutableString* loads = [NSMutableString string];
    for (NSUInteger k = 0; k + 1 < self.fn.paramTypes.count; k++)
        {
        NSString* t = ptxRegType(self.fn.paramTypes[k]);
        if (!t || [t isEqualToString:@".pred"])
            return nil;
        [params addObject:[NSString stringWithFormat:@".param %@ p%lu", t, (unsigned long)k]];
        [loads appendFormat:@"\t.reg %@ %%a%lu;\n\tld.param%@ %%a%lu, [p%lu];\n", t, (unsigned long)k, t,
                            (unsigned long)k, (unsigned long)k];
        }
    XTIRType* rt = self.fn.returnType;
    BOOL isVoid = !rt || rt.kind == XTIRTypeKindVoid || rt.kind == XTIRTypeKindMemory;
    NSString* rtt = isVoid ? nil : ptxRegType(rt);
    if (!isVoid && (!rtt || [rtt isEqualToString:@".pred"]))
        return nil;
    NSString* decls = [self ptxDecls];
    NSString* body = [self ptxBody:@""];
    if (!decls || !body || self.failed)
        return nil;
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@".func %@%@(%@)\n{\n", isVoid ? @"" : [NSString stringWithFormat:@"(.param %@ rv) ", rtt], name,
                      [params componentsJoinedByString:@", "]];
    [out appendString:@"\t.reg .b32 %k;\n\t.reg .b64 %x;\n\t.reg .f32 %fk;\n\t.reg .f64 %dk;\n"];
    [out appendString:loads];
    [out appendString:decls];
    [out appendString:body];
    [out appendString:@"}\n"];
    return out;
    }

- (nullable NSString*)ptxKernel
    {
    [self ptxReset];
    XTIRType* selfT = self.fn.paramTypes.count ? self.fn.paramTypes[0] : nil;
    self.objLayout = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    if (!self.objLayout || self.objLayout.fields.count < 3 ||
        self.objLayout.fields[1].type.kind != XTIRTypeKindI64 || self.objLayout.fields[2].type.kind != XTIRTypeKindI64)
        return nil;
    if (![self analyse])
        return nil;
    [self ptxOrdinals];
    NSString* decls = [self ptxDecls];
    NSString* body = [self ptxBody:@"BODY_END"];
    if (!decls || !body || self.failed)
        return nil;

    NSArray<XTIRLayoutField*>* fl = self.objLayout.fields;
    NSMutableString* meta = [NSMutableString stringWithFormat:@"// xcpar size=%u lo=%u hi=%u", self.objLayout.size,
                                                              fl[1].byteOffset, fl[2].byteOffset];
    NSMutableArray<NSString*>* params = [NSMutableArray arrayWithObjects:@".param .u64 args", @".param .u64 span", nil];
    __block BOOL bad = NO;
    [self.bufferFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        XTIRType* et = fl[k].type.pointeeType;
        if (!ptxMem(et))
            {
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" buf=%u:%lu:%u", fl[k].byteOffset, (unsigned long)(k - 3), et.byteWidth];
        [params addObject:[NSString stringWithFormat:@".param .u64 buf_%lu", (unsigned long)k]];
    }];
    for (NSUInteger gi = 0; gi < self.globals.count; gi++)
        {
        XTIRSymbol* g = [self.module symbolForName:self.globals[gi]];
        XTIRType* gt = g.globalType;
        XTIRType* et = gt.kind == XTIRTypeKindAgg ? gt.layout.fields.firstObject.type : gt;
        if (!ptxMem(et))
            return nil;
        [meta appendFormat:@" glob=%@:%u", self.globals[gi], et.byteWidth];
        [params addObject:[NSString stringWithFormat:@".param .u64 glob_%lu", (unsigned long)gi]];
        }
    NSMutableString* tail = [NSMutableString string];
    [self.reductionFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        XTIRType* t = fl[k].type;
        NSString* m = ptxMem(t);
        NSString* rt = ptxRegType(t);
        if (!m || !rt || [rt isEqualToString:@".pred"])
            {
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" red=%u:%u", fl[k].byteOffset, t.byteWidth];
        [params addObject:[NSString stringWithFormat:@".param .u64 red_%lu", (unsigned long)k]];
        NSString* tmp = [rt isEqualToString:@".b64"] ? @"%y" : [rt isEqualToString:@".f32"] ? @"%fk"
                      : [rt isEqualToString:@".f64"] ? @"%dk" : @"%k";
        [tail appendFormat:@"\tld.local.%@ %@, [%%stp+%u];\n\tld.param.u64 %%x, [red_%lu];\n\tcvta.to.global.u64 %%x, %%x;\n"
                           @"\tmad.lo.u64 %%x, %%tid64, %u, %%x;\n\tst.global.%@ [%%x], %@;\n",
                           m, tmp, fl[k].byteOffset, (unsigned long)k, t.byteWidth, m, tmp];
    }];
    if (bad)
        return nil;

    NSMutableString* out = [NSMutableString string];
    if (self.fast)
        [meta appendString:@" fast"];
    [out appendFormat:@"%@\n.version 7.0\n.target sm_52\n.address_size 64\n", meta];
    for (NSString* h in self.helperText)
        [out appendString:h];
    [out appendFormat:@".visible .entry par_kernel(%@)\n{\n", [params componentsJoinedByString:@", "]];
    [out appendFormat:@"\t.local .align 8 .b8 st[%u];\n", self.objLayout.size];
    [out appendString:@"\t.reg .b64 %stp, %ga, %gs, %lo, %hi, %end, %per, %tid64, %x, %y;\n"
                      @"\t.reg .b32 %gid, %k, %nt, %ct, %tx;\n\t.reg .f32 %fk;\n\t.reg .f64 %dk;\n\t.reg .pred %pz;\n"];
    [out appendString:decls];
    [out appendString:@"\tmov.u64 %stp, st;\n\tld.param.u64 %ga, [args];\n\tcvta.to.global.u64 %ga, %ga;\n"];
    for (uint32_t q = 0; q < self.objLayout.size; q++)
        [out appendFormat:@"\tld.global.u8 %%k, [%%ga+%u];\n\tst.local.u8 [%%stp+%u], %%k;\n", q, q];
    [out appendString:@"\tld.param.u64 %gs, [span];\n\tcvta.to.global.u64 %gs, %gs;\n"
                      @"\tmov.u32 %ct, %ctaid.x;\n\tmov.u32 %nt, %ntid.x;\n\tmov.u32 %tx, %tid.x;\n"
                      @"\tmad.lo.u32 %gid, %ct, %nt, %tx;\n\tcvt.u64.u32 %tid64, %gid;\n"
                      @"\tld.global.u64 %lo, [%gs];\n\tld.global.u64 %end, [%gs+8];\n\tld.global.u64 %per, [%gs+16];\n"
                      @"\tmad.lo.u64 %lo, %tid64, %per, %lo;\n\tadd.s64 %hi, %lo, %per;\n\tmin.s64 %hi, %hi, %end;\n"];
    [out appendFormat:@"\tst.local.u64 [%%stp+%u], %%lo;\n\tst.local.u64 [%%stp+%u], %%hi;\n", fl[1].byteOffset,
                      fl[2].byteOffset];
    [out appendString:@"\tsetp.ge.s64 %pz, %lo, %hi;\n\t@%pz bra BODY_END;\n"];
    [out appendString:body];
    [out appendString:@"BODY_END:\n\tsetp.ge.s64 %pz, %lo, %end;\n\t@%pz bra DONE;\n"];
    [out appendString:tail];
    [out appendString:@"DONE:\n\tret;\n}\n"];
    return out;
    }

@end
