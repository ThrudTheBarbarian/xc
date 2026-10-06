#import "XTIRParMSL_Private.h"
#import "XTIROpcode.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

// A `par` block's kernel in WGSL, for WebGPU (the wasm32 target). The same
// analysis as the Metal, PTX and SPIR-V printers (XTIRParMSL's analyse), and the
// SPIR-V printer's shape: every SSA value a function variable, control flow as
// a dispatch loop (`loop { switch pc { … } }`), each pointer value a recipe (a
// buffer or a field, and an element index) resolved at its load or store.
//
// WGSL has 32-bit integers only, so exactly as the design asks
// (private:docs/Design/par-spirv-wgsl.md):
// - 8- and 16-bit values live in a u32, wrapped after every operation (the
//   same canonical forms as SPIR-V's); every 32-bit and narrower integer is a
//   u32, and a signed operation reads it through bitcast<i32>;
// - 64-bit integers are vec2<u32> (low, high word), added, subtracted,
//   multiplied, shifted and compared by small functions printed with the
//   kernel; a 64-bit division or remainder, or a float conversion of one,
//   keeps the block on the CPU;
// - an array of 8- or 16-bit values or bools is an array<atomic<u32>>: a load
//   is atomicLoad and a shift and mask, a store clears and sets its bits with
//   atomicAnd / atomicOr, since the work items either side may write the other
//   bytes of the word at the same time (WGSL does not allow plain and atomic
//   access to one buffer, so its loads are atomic too).
// f64 has no WGSL form: a block that uses one runs on the CPU. Exactness is
// Vulkan's: +, -, * are correctly rounded, division and the transcendentals
// are not, so an accuracy block that uses one stays on the CPU.
//
// Bindings (group 0): 0 the object's bytes as array<u32> (read), 1 the span
// (lo, hi, per as three vec2<u32>), then one per captured array, global and
// reduction, in the header's order.

static const uint32_t kWgExit = 0xffffffffu;

static NSString* wgBareName(NSString* callee)
    {
    NSString* m = callee;
    if ([m hasPrefix:@"Math$"])
        m = [m substringFromIndex:5];
    NSRange r = [m rangeOfString:@"__"];
    if (r.location != NSNotFound)
        m = [m substringToIndex:r.location];
    if ([m hasPrefix:@"_xm_"])
        m = [m substringFromIndex:4];
    if ([m hasSuffix:@"f"] && m.length > 3)
        m = [m substringToIndex:m.length - 1];
    return m;
    }

static NSString* wgShownName(NSString* irName)
    {
    NSRange r = [irName rangeOfString:@"__"];
    NSString* s = (r.location != NSNotFound && r.location > 0) ? [irName substringToIndex:r.location] : irName;
    return [s stringByReplacingOccurrencesOfString:@"$" withString:@"."];
    }

static uint32_t wgNarrowBits(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: return 8;
        case XTIRTypeKindI16: case XTIRTypeKindU16: return 16;
        default: return 0;
        }
    }

static uint32_t wgNarrowBytes(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindBool: return 1;
        case XTIRTypeKindI16: case XTIRTypeKindU16: return 2;
        default: return 0;
        }
    }

static BOOL wgWide(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64;
    }

static BOOL wgSigned(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI8 || t.kind == XTIRTypeKindI16 || t.kind == XTIRTypeKindI32 ||
           t.kind == XTIRTypeKindI64;
    }

static BOOL wgIsFloat(XTIRType* t)
    {
    return t.kind == XTIRTypeKindF32 || t.kind == XTIRTypeKindF64;
    }

// A value's WGSL type; nil for one this printer cannot hold.
static NSString* wgType(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindI16: case XTIRTypeKindU16:
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"u32";
        case XTIRTypeKindI64: case XTIRTypeKindU64: return @"vec2<u32>";
        case XTIRTypeKindF32: return @"f32";
        case XTIRTypeKindBool: return @"bool";
        default: return nil;
        }
    }

// The 64-bit helpers, printed once at the top of every module that has a
// kernel: (low, high) pairs, wrapping as xc's 64-bit integers do.
static NSString* const kWg64 =
    @"fn xc_add64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n"
    @"  let lo = a.x + b.x;\n"
    @"  return vec2<u32>(lo, a.y + b.y + select(0u, 1u, lo < a.x));\n"
    @"}\n"
    @"fn xc_sub64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n"
    @"  return vec2<u32>(a.x - b.x, a.y - b.y - select(0u, 1u, a.x < b.x));\n"
    @"}\n"
    @"fn xc_mulwide(a: u32, b: u32) -> vec2<u32> {\n"
    @"  let al = a & 0xffffu; let ah = a >> 16u; let bl = b & 0xffffu; let bh = b >> 16u;\n"
    @"  let ll = al * bl; let lh = al * bh; let hl = ah * bl; let hh = ah * bh;\n"
    @"  let mid = (ll >> 16u) + (lh & 0xffffu) + (hl & 0xffffu);\n"
    @"  return vec2<u32>((ll & 0xffffu) | (mid << 16u), hh + (lh >> 16u) + (hl >> 16u) + (mid >> 16u));\n"
    @"}\n"
    @"fn xc_mul64(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {\n"
    @"  let w = xc_mulwide(a.x, b.x);\n"
    @"  return vec2<u32>(w.x, w.y + a.x * b.y + a.y * b.x);\n"
    @"}\n"
    @"fn xc_shl64(a: vec2<u32>, n: u32) -> vec2<u32> {\n"
    @"  let s = n & 63u;\n"
    @"  if (s == 0u) { return a; }\n"
    @"  if (s >= 32u) { return vec2<u32>(0u, a.x << (s - 32u)); }\n"
    @"  return vec2<u32>(a.x << s, (a.y << s) | (a.x >> (32u - s)));\n"
    @"}\n"
    @"fn xc_lshr64(a: vec2<u32>, n: u32) -> vec2<u32> {\n"
    @"  let s = n & 63u;\n"
    @"  if (s == 0u) { return a; }\n"
    @"  if (s >= 32u) { return vec2<u32>(a.y >> (s - 32u), 0u); }\n"
    @"  return vec2<u32>((a.x >> s) | (a.y << (32u - s)), a.y >> s);\n"
    @"}\n"
    @"fn xc_ashr64(a: vec2<u32>, n: u32) -> vec2<u32> {\n"
    @"  let s = n & 63u;\n"
    @"  let sign = select(0u, 0xffffffffu, (a.y & 0x80000000u) != 0u);\n"
    @"  if (s == 0u) { return a; }\n"
    @"  if (s >= 32u) { return vec2<u32>(u32(i32(a.y) >> (s - 32u)), sign); }\n"
    @"  return vec2<u32>((a.x >> s) | (a.y << (32u - s)), u32(i32(a.y) >> s));\n"
    @"}\n"
    @"fn xc_ult64(a: vec2<u32>, b: vec2<u32>) -> bool {\n"
    @"  return a.y < b.y || (a.y == b.y && a.x < b.x);\n"
    @"}\n"
    @"fn xc_slt64(a: vec2<u32>, b: vec2<u32>) -> bool {\n"
    @"  return i32(a.y) < i32(b.y) || (a.y == b.y && a.x < b.x);\n"
    @"}\n"
    @"fn xc_sext64(x: u32) -> vec2<u32> {\n"
    @"  return vec2<u32>(x, select(0u, 0xffffffffu, (x & 0x80000000u) != 0u));\n"
    @"}\n";

// A pointer value's recipe: the buffer or variable it is into, and the
// element index (a WGSL expression), if any.
@interface XTWgRecipe : NSObject
@property(nonatomic, copy) NSString* base;     // b3, g0, f5 …
@property(nonatomic, copy, nullable) NSString* index;   // a u32 variable's name, or nil
@property(nonatomic) XTIRType* pointee;
@property(nonatomic) BOOL words;               // a narrow element of an array<atomic<u32>>
@end

@implementation XTWgRecipe
@end

// One function being printed.
@interface XTWgFunc : NSObject
@property(nonatomic) NSMutableString* vars;
@property(nonatomic) NSMutableString* code;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSString*>* varOf;   // value -> variable
@property(nonatomic) NSMutableDictionary<NSNumber*, XTWgRecipe*>* recipeOf;
@property(nonatomic) NSMutableSet<NSNumber*>* used;
@property(nonatomic, copy, nullable) NSString* retVar;
@property(nonatomic) NSUInteger temps;
@end

@implementation XTWgFunc
@end

@interface XTIRParMSL (WGSLState)
@property(nonatomic) XTWgFunc* wf;
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* wgHelpers;   // callee -> WGSL function name
@property(nonatomic) NSMutableString* wgHelperText;
@property(nonatomic) NSMutableSet<NSString*>* wgWordBufs;                    // buffers of atomic words
@property(nonatomic) NSMutableDictionary<NSNumber*, NSString*>* wgBufName;   // field / -1-global -> buffer name
@end

#import <objc/runtime.h>

@implementation XTIRParMSL (WGSLState)

static char kWf, kWgHelpers, kWgHelperText, kWgWordBufs, kWgBufName;

- (XTWgFunc*)wf { return objc_getAssociatedObject(self, &kWf); }
- (void)setWf:(XTWgFunc*)v { objc_setAssociatedObject(self, &kWf, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableDictionary*)wgHelpers { return objc_getAssociatedObject(self, &kWgHelpers); }
- (void)setWgHelpers:(NSMutableDictionary*)v { objc_setAssociatedObject(self, &kWgHelpers, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableString*)wgHelperText { return objc_getAssociatedObject(self, &kWgHelperText); }
- (void)setWgHelperText:(NSMutableString*)v { objc_setAssociatedObject(self, &kWgHelperText, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableSet*)wgWordBufs { return objc_getAssociatedObject(self, &kWgWordBufs); }
- (void)setWgWordBufs:(NSMutableSet*)v { objc_setAssociatedObject(self, &kWgWordBufs, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableDictionary*)wgBufName { return objc_getAssociatedObject(self, &kWgBufName); }
- (void)setWgBufName:(NSMutableDictionary*)v { objc_setAssociatedObject(self, &kWgBufName, v, OBJC_ASSOCIATION_RETAIN); }

@end

@implementation XTIRParMSL (WGSL)

// ── values ──────────────────────────────────────────────────────────────────

- (void)wgLine:(NSString*)s
    {
    [self.wf.code appendFormat:@"      %@\n", s];
    }

// A fresh `let` holding expr, so it is computed once: its name.
- (NSString*)wgLet:(NSString*)expr
    {
    NSString* n = [NSString stringWithFormat:@"t%lu", (unsigned long)self.wf.temps++];
    [self wgLine:[NSString stringWithFormat:@"let %@ = %@;", n, expr]];
    return n;
    }

- (void)wgSet:(XTIRInsn*)i to:(NSString*)expr
    {
    [self wgLine:[NSString stringWithFormat:@"%@ = %@;", self.wf.varOf[@(i.result.valueId)], expr]];
    }

// A u32 holding a narrow value, wrapped to type t's form (masked for unsigned,
// sign-extended for signed); anything else unchanged.
- (NSString*)wgCanon:(NSString*)v type:(XTIRType*)t
    {
    uint32_t bits = wgNarrowBits(t);
    if (!bits)
        return v;
    if (t.kind == XTIRTypeKindU8 || t.kind == XTIRTypeKindU16)
        return [NSString stringWithFormat:@"((%@) & 0x%xu)", v, (1u << bits) - 1];
    return [NSString stringWithFormat:@"u32(i32((%@) << %uu) >> %uu)", v, 32 - bits, 32 - bits];
    }

- (NSString*)wgU32Lit:(uint32_t)v
    {
    return [NSString stringWithFormat:@"%uu", v];
    }

// An operand's value as a WGSL expression, as type `want` for an immediate; nil when it cannot be.
- (nullable NSString*)wgValue:(XTIROperand*)op type:(nullable XTIRType*)want
    {
    switch (op.kind)
        {
        case XTIROperandKindUse:
            return self.wf.varOf[@(op.valueId)];
        case XTIROperandKindImmI:
            {
            if (!want)
                return nil;
            if (want.kind == XTIRTypeKindBool)
                return op.intValue ? @"true" : @"false";
            if (wgIsFloat(want) || !wgType(want))
                return nil;
            int64_t iv = op.intValue;
            if (wgWide(want))
                return [NSString stringWithFormat:@"vec2<u32>(%uu, %uu)", (uint32_t)(uint64_t)iv,
                                                  (uint32_t)((uint64_t)iv >> 32)];
            uint32_t nb = wgNarrowBits(want);
            if (nb)
                {
                uint64_t mask = (1ull << nb) - 1;
                iv = (int64_t)((uint64_t)iv & mask);
                if (wgSigned(want) && (iv >> (nb - 1)) & 1)
                    iv = iv - (int64_t)(1ull << nb);
                }
            return [self wgU32Lit:(uint32_t)iv];
            }
        case XTIROperandKindImmF:
            {
            if (want.kind != XTIRTypeKindF32)
                return nil;
            uint64_t raw = op.floatRawBytes;
            double d;
            memcpy(&d, &raw, sizeof d);
            float f = (float)d;
            uint32_t bits;
            memcpy(&bits, &f, sizeof bits);
            return [NSString stringWithFormat:@"bitcast<f32>(%uu)", bits];
            }
        default:
            return nil;
        }
    }

// ── instructions ────────────────────────────────────────────────────────────

- (BOOL)wgBinary:(XTIRInsn*)i
    {
    XTIRType* t = i.result.type;
    NSString* a = [self wgValue:i.operands[0] type:t];
    NSString* b = [self wgValue:i.operands[1] type:t];
    if (!a || !b || !wgType(t))
        return NO;
    if (wgWide(t))
        {
        // A shift's count may be 32-bit: its low word either way.
        XTIRType* ct = i.operands[1].kind == XTIROperandKindUse ? [self typeOf:i.operands[1].valueId] : t;
        NSString* cnt = wgWide(ct) ? [NSString stringWithFormat:@"%@.x", b] : b;
        if (!wgWide(ct) && i.operands[1].kind == XTIROperandKindUse)
            b = [self wgValue:i.operands[1] type:ct];
        NSString* e = nil;
        switch (i.opcode)
            {
            case XTIROpAdd: e = [NSString stringWithFormat:@"xc_add64(%@, %@)", a, b]; break;
            case XTIROpSub: e = [NSString stringWithFormat:@"xc_sub64(%@, %@)", a, b]; break;
            case XTIROpMul: e = [NSString stringWithFormat:@"xc_mul64(%@, %@)", a, b]; break;
            case XTIROpAnd: e = [NSString stringWithFormat:@"(%@ & %@)", a, b]; break;
            case XTIROpOr: e = [NSString stringWithFormat:@"(%@ | %@)", a, b]; break;
            case XTIROpXor: e = [NSString stringWithFormat:@"(%@ ^ %@)", a, b]; break;
            case XTIROpShl: e = [NSString stringWithFormat:@"xc_shl64(%@, %@)", a, cnt]; break;
            case XTIROpLShr: e = [NSString stringWithFormat:@"xc_lshr64(%@, %@)", a, cnt]; break;
            case XTIROpAShr: e = [NSString stringWithFormat:@"xc_ashr64(%@, %@)", a, cnt]; break;
            default:
                [self because:@"it divides 64-bit integers, which its WebGPU version cannot do yet"];
                return NO;
            }
        [self wgSet:i to:e];
        return YES;
        }
    if (t.kind == XTIRTypeKindF32)
        {
        NSString* op = nil;
        switch (i.opcode)
            {
            case XTIROpFAdd: op = @"+"; break;
            case XTIROpFSub: op = @"-"; break;
            case XTIROpFMul: op = @"*"; break;
            case XTIROpFDiv:
                if (!self.fast)
                    {
                    [self because:@"it divides floats, which a WebGPU device does not round exactly, and the "
                                  @"block's goal is accuracy"];
                    return NO;
                    }
                op = @"/";
                break;
            default: return NO;
            }
        [self wgSet:i to:[NSString stringWithFormat:@"(%@ %@ %@)", a, op, b]];
        return YES;
        }
    if (t.kind == XTIRTypeKindBool)
        {
        NSString* op = i.opcode == XTIROpAnd ? @"&" : i.opcode == XTIROpOr ? @"|" : i.opcode == XTIROpXor ? @"!=" : nil;
        if (!op)
            return NO;
        [self wgSet:i to:[NSString stringWithFormat:@"(%@ %@ %@)", a, op, b]];
        return YES;
        }
    // A narrow operand is held in its own type's form; an operation of the
    // other signedness rereads its bits that way first.
    uint32_t nb = wgNarrowBits(t);
    BOOL wantsUnsigned = i.opcode == XTIROpUDiv || i.opcode == XTIROpURem || i.opcode == XTIROpLShr;
    BOOL wantsSigned = i.opcode == XTIROpSDiv || i.opcode == XTIROpSRem || i.opcode == XTIROpAShr;
    if (nb)
        {
        XTIRType* as = nil;
        if (wantsUnsigned && wgSigned(t))
            as = nb == 8 ? [XTIRType u8Type] : [XTIRType u16Type];
        else if (wantsSigned && !wgSigned(t))
            as = nb == 8 ? [XTIRType i8Type] : [XTIRType i16Type];
        if (as)
            {
            a = [self wgCanon:a type:as];
            if (i.opcode != XTIROpLShr && i.opcode != XTIROpAShr)
                b = [self wgCanon:b type:as];
            }
        }
    NSString* e = nil;
    switch (i.opcode)
        {
        case XTIROpAdd: e = [NSString stringWithFormat:@"(%@ + %@)", a, b]; break;
        case XTIROpSub: e = [NSString stringWithFormat:@"(%@ - %@)", a, b]; break;
        case XTIROpMul: e = [NSString stringWithFormat:@"(%@ * %@)", a, b]; break;
        case XTIROpUDiv: e = [NSString stringWithFormat:@"(%@ / %@)", a, b]; break;
        case XTIROpURem: e = [NSString stringWithFormat:@"(%@ %% %@)", a, b]; break;
        case XTIROpSDiv: e = [NSString stringWithFormat:@"u32(i32(%@) / i32(%@))", a, b]; break;
        case XTIROpSRem: e = [NSString stringWithFormat:@"u32(i32(%@) %% i32(%@))", a, b]; break;
        case XTIROpAnd: e = [NSString stringWithFormat:@"(%@ & %@)", a, b]; break;
        case XTIROpOr: e = [NSString stringWithFormat:@"(%@ | %@)", a, b]; break;
        case XTIROpXor: e = [NSString stringWithFormat:@"(%@ ^ %@)", a, b]; break;
        case XTIROpShl: e = [NSString stringWithFormat:@"(%@ << (%@ & 31u))", a, b]; break;
        case XTIROpLShr: e = [NSString stringWithFormat:@"(%@ >> (%@ & 31u))", a, b]; break;
        case XTIROpAShr: e = [NSString stringWithFormat:@"u32(i32(%@) >> (%@ & 31u))", a, b]; break;
        default: return NO;
        }
    [self wgSet:i to:[self wgCanon:e type:t]];
    return YES;
    }

- (BOOL)wgCompare:(XTIRInsn*)i
    {
    XTIRType* t = [self typeOf:i.operands[0].kind == XTIROperandKindUse ? i.operands[0].valueId
                                                                        : i.operands[1].valueId];
    if (!t)
        return NO;
    NSString* a = [self wgValue:i.operands[0] type:t];
    NSString* b = [self wgValue:i.operands[1] type:t];
    if (!a || !b)
        return NO;
    NSString* e = nil;
    if (i.opcode == XTIROpFCmp)
        {
        static NSString* const fops[] = { @"==", @"!=", @"<", @">", @"<=", @">=" };
        if (i.predicate > XTIRFCmpOGE || t.kind != XTIRTypeKindF32)
            return NO;
        e = [NSString stringWithFormat:@"(%@ %@ %@)", a, fops[i.predicate], b];
        }
    else if (wgWide(t))
        {
        switch (i.predicate)
            {
            case XTIRICmpEQ: e = [NSString stringWithFormat:@"all(%@ == %@)", a, b]; break;
            case XTIRICmpNE: e = [NSString stringWithFormat:@"any(%@ != %@)", a, b]; break;
            case XTIRICmpSLT: e = [NSString stringWithFormat:@"xc_slt64(%@, %@)", a, b]; break;
            case XTIRICmpSGT: e = [NSString stringWithFormat:@"xc_slt64(%@, %@)", b, a]; break;
            case XTIRICmpSLE: e = [NSString stringWithFormat:@"!xc_slt64(%@, %@)", b, a]; break;
            case XTIRICmpSGE: e = [NSString stringWithFormat:@"!xc_slt64(%@, %@)", a, b]; break;
            case XTIRICmpULT: e = [NSString stringWithFormat:@"xc_ult64(%@, %@)", a, b]; break;
            case XTIRICmpUGT: e = [NSString stringWithFormat:@"xc_ult64(%@, %@)", b, a]; break;
            case XTIRICmpULE: e = [NSString stringWithFormat:@"!xc_ult64(%@, %@)", b, a]; break;
            case XTIRICmpUGE: e = [NSString stringWithFormat:@"!xc_ult64(%@, %@)", a, b]; break;
            default: return NO;
            }
        }
    else if (t.kind == XTIRTypeKindBool)
        {
        if (i.predicate == XTIRICmpEQ)
            e = [NSString stringWithFormat:@"(%@ == %@)", a, b];
        else if (i.predicate == XTIRICmpNE)
            e = [NSString stringWithFormat:@"(%@ != %@)", a, b];
        else
            return NO;
        }
    else
        {
        static NSString* const iops[] = { @"==", @"!=", @"<", @">", @"<=", @">=", @"<", @">", @"<=", @">=" };
        if (i.predicate > XTIRICmpUGE)
            return NO;
        BOOL s = i.predicate >= XTIRICmpSLT && i.predicate <= XTIRICmpSGE;
        e = s ? [NSString stringWithFormat:@"(i32(%@) %@ i32(%@))", a, iops[i.predicate], b]
              : [NSString stringWithFormat:@"(%@ %@ %@)", a, iops[i.predicate], b];
        }
    [self wgSet:i to:e];
    return YES;
    }

- (BOOL)wgConvert:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    XTIRType* st = i.operands[0].kind == XTIROperandKindUse ? [self typeOf:i.operands[0].valueId] : rt;
    NSString* a = [self wgValue:i.operands[0] type:st];
    if (!a || !wgType(rt) || !wgType(st))
        return NO;
    NSString* v = nil;
    if (st.kind == XTIRTypeKindBool && rt.kind != XTIRTypeKindBool)
        {
        if (wgIsFloat(rt))
            return NO;
        v = wgWide(rt) ? [NSString stringWithFormat:@"vec2<u32>(select(0u, 1u, %@), 0u)", a]
                       : [NSString stringWithFormat:@"select(0u, 1u, %@)", a];
        }
    else if (rt.kind == XTIRTypeKindBool)
        {
        if (st.kind == XTIRTypeKindBool)
            v = a;
        else if (wgIsFloat(st))
            return NO;
        else
            v = wgWide(st) ? [NSString stringWithFormat:@"any(%@ != vec2<u32>(0u, 0u))", a]
                           : [NSString stringWithFormat:@"(%@ != 0u)", a];
        }
    else if (wgIsFloat(st) || wgIsFloat(rt))
        {
        if (wgWide(st) || wgWide(rt))
            {
            [self because:@"it converts between floats and 64-bit integers, which its WebGPU version cannot "
                          @"do yet"];
            return NO;
            }
        switch (i.opcode)
            {
            case XTIROpCopy:
            case XTIROpSIToFp: case XTIROpUIToFp: case XTIROpFpToSI: case XTIROpFpToUI:
                {
                if (wgIsFloat(st) && wgIsFloat(rt))
                    v = a;
                else if (wgIsFloat(rt))
                    {
                    BOOL s = i.opcode == XTIROpSIToFp || (i.opcode == XTIROpCopy && wgSigned(st));
                    v = s ? [NSString stringWithFormat:@"f32(i32(%@))", a] : [NSString stringWithFormat:@"f32(%@)", a];
                    }
                else
                    {
                    BOOL s = i.opcode == XTIROpFpToSI || (i.opcode == XTIROpCopy && wgSigned(rt));
                    v = [self wgCanon:s ? [NSString stringWithFormat:@"u32(i32(%@))", a]
                                        : [NSString stringWithFormat:@"u32(%@)", a]
                                 type:rt];
                    }
                break;
                }
            default:
                return NO;
            }
        }
    else
        {
        // Integers: the source with the extension the opcode asks for, at the
        // result's width, then wrapped to a narrow result.
        switch (i.opcode)
            {
            case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc: case XTIROpCopy:
                {
                uint32_t sb = wgNarrowBits(st);
                BOOL extSigned = i.opcode == XTIROpSExt || (i.opcode != XTIROpZExt && wgSigned(st));
                NSString* x = a;
                if (sb && extSigned != wgSigned(st))
                    {
                    XTIRType* as = extSigned ? (sb == 8 ? [XTIRType i8Type] : [XTIRType i16Type])
                                             : (sb == 8 ? [XTIRType u8Type] : [XTIRType u16Type]);
                    x = [self wgCanon:x type:as];
                    }
                if (wgWide(st) && !wgWide(rt))
                    x = [NSString stringWithFormat:@"%@.x", x];
                else if (!wgWide(st) && wgWide(rt))
                    x = extSigned ? [NSString stringWithFormat:@"xc_sext64(%@)", x]
                                  : [NSString stringWithFormat:@"vec2<u32>(%@, 0u)", x];
                v = [self wgCanon:x type:rt];
                break;
                }
            default:
                return NO;
            }
        }
    [self wgSet:i to:v];
    return YES;
    }

- (BOOL)wgIsMaths:(NSString*)callee
    {
    NSString* m = wgBareName(callee);
    return [@[ @"sqrt", @"sin", @"cos", @"exp", @"ln", @"log", @"pow", @"floor", @"fma", @"abs", @"fabs", @"min",
               @"max" ] containsObject:m];
    }

// A maths call's WGSL built-in, or nil when it has none here (or none that
// is exact, for an accuracy block). Integer min/max/abs are on i32 or u32.
- (nullable NSString*)wgMaths:(NSString*)callee type:(XTIRType*)t args:(NSArray<NSString*>*)args
    {
    NSString* m = wgBareName(callee);
    BOOL f = t.kind == XTIRTypeKindF32;
    if (!f && (wgWide(t) || !wgType(t) || t.kind == XTIRTypeKindBool))
        return nil;
    NSString* j = [args componentsJoinedByString:@", "];
    BOOL s = !f && wgSigned(t);
    NSString* (^sgn)(NSString*) = ^NSString*(NSString* fn) {
      NSMutableArray* ia = [NSMutableArray array];
      for (NSString* x in args)
          [ia addObject:[NSString stringWithFormat:@"i32(%@)", x]];
      return [self wgCanon:[NSString stringWithFormat:@"u32(%@(%@))", fn, [ia componentsJoinedByString:@", "]] type:t];
    };
    if ([m isEqualToString:@"floor"])
        return f ? [NSString stringWithFormat:@"floor(%@)", j] : nil;
    if ([m isEqualToString:@"abs"] || [m isEqualToString:@"fabs"])
        return f ? [NSString stringWithFormat:@"abs(%@)", j] : s ? sgn(@"abs") : nil;
    if ([m isEqualToString:@"min"])
        return f ? [NSString stringWithFormat:@"min(%@)", j] : s ? sgn(@"min") : [NSString stringWithFormat:@"min(%@)", j];
    if ([m isEqualToString:@"max"])
        return f ? [NSString stringWithFormat:@"max(%@)", j] : s ? sgn(@"max") : [NSString stringWithFormat:@"max(%@)", j];
    if (!self.fast || !f)
        return nil;
    if ([m isEqualToString:@"sqrt"]) return [NSString stringWithFormat:@"sqrt(%@)", j];
    if ([m isEqualToString:@"sin"]) return [NSString stringWithFormat:@"sin(%@)", j];
    if ([m isEqualToString:@"cos"]) return [NSString stringWithFormat:@"cos(%@)", j];
    if ([m isEqualToString:@"exp"]) return [NSString stringWithFormat:@"exp(%@)", j];
    if ([m isEqualToString:@"ln"] || [m isEqualToString:@"log"]) return [NSString stringWithFormat:@"log(%@)", j];
    if ([m isEqualToString:@"pow"]) return [NSString stringWithFormat:@"pow(%@)", j];
    if ([m isEqualToString:@"fma"]) return [NSString stringWithFormat:@"fma(%@)", j];
    return nil;
    }

- (BOOL)wgCall:(XTIRInsn*)i
    {
    XTIRSymbol* sym = [self.module symbolForId:i.operands[0].symbolId];
    NSString* callee = sym.name;
    if ([callee isEqualToString:@"_xtc_sinit_run"] || [callee hasSuffix:@"$init"])
        return YES;
    XTIRType* rt = i.result.type;
    BOOL isVoid = !rt || rt.kind == XTIRTypeKindMemory;
    NSMutableArray<NSString*>* args = [NSMutableArray array];
    for (NSUInteger k = 1; k < i.operands.count; k++)
        {
        XTIROperand* o = i.operands[k];
        if (o.kind == XTIROperandKindUse && [self typeOf:o.valueId].kind == XTIRTypeKindMemory)
            continue;
        XTIRType* at = o.kind == XTIROperandKindUse ? [self typeOf:o.valueId] : rt;
        NSString* v = [self wgValue:o type:at];
        if (!v)
            return NO;
        [args addObject:v];
        }
    if ([self wgIsMaths:callee])
        {
        if (isVoid || !args.count)
            return NO;
        NSString* e = [self wgMaths:callee type:rt args:args];
        if (!e)
            {
            [self because:[NSString stringWithFormat:@"it calls %@, which a WebGPU device has only in an "
                                                     @"approximate form, and the block's goal is accuracy",
                                                     wgShownName(callee)]];
            return NO;
            }
        [self wgSet:i to:e];
        return YES;
        }
    // A function of the program: printed once, as a WGSL function.
    NSString* name = self.wgHelpers[callee];
    if (!name)
        {
        XTIRFunction* target = nil;
        for (XTIRFunction* g in self.module.functions)
            if ([g.name isEqualToString:callee])
                target = g;
        if (!target)
            return NO;
        XTIRParMSL* h = [XTIRParMSL new];
        h.module = self.module;
        h.fn = target;
        h.helperMode = YES;
        h.fast = self.fast;
        h.wgHelpers = self.wgHelpers;
        h.wgHelperText = self.wgHelperText;
        name = [NSString stringWithFormat:@"h%lu", (unsigned long)self.wgHelpers.count];
        self.wgHelpers[callee] = name;
        if (![h wgHelperNamed:name])
            {
            [self.wgHelpers removeObjectForKey:callee];
            [self because:[self callFailed:callee helper:h]];
            return NO;
            }
        }
    NSString* call = [NSString stringWithFormat:@"%@(%@)", name, [args componentsJoinedByString:@", "]];
    if (isVoid)
        [self wgLine:[call stringByAppendingString:@";"]];
    else
        [self wgSet:i to:call];
    return YES;
    }

// The u32 index and bit shift of a narrow element in its word, as lets.
- (BOOL)wgWord:(XTWgRecipe*)r word:(NSString* _Nonnull* _Nonnull)word shift:(NSString* _Nonnull* _Nonnull)shift
    {
    uint32_t n = wgNarrowBytes(r.pointee);
    if (!n || !r.index)
        return NO;
    *word = [self wgLet:[NSString stringWithFormat:@"%@ >> %uu", r.index, n == 1 ? 2 : 1]];
    *shift = [self wgLet:[NSString stringWithFormat:@"(%@ & %uu) << %uu", r.index, n == 1 ? 3 : 1, n == 1 ? 3 : 4]];
    return YES;
    }

- (nullable NSString*)wgNarrowFrom:(NSString*)word shift:(NSString*)shift type:(XTIRType*)t
    {
    NSString* v = [NSString stringWithFormat:@"(%@ >> %@)", word, shift];
    if (t.kind == XTIRTypeKindBool)
        return [NSString stringWithFormat:@"((%@ & 0xffu) != 0u)", v];
    if (wgSigned(t))
        return [self wgCanon:v type:t];
    return [NSString stringWithFormat:@"(%@ & 0x%xu)", v, (1u << wgNarrowBits(t)) - 1];
    }

- (nullable NSString*)wgAccess:(XTWgRecipe*)r
    {
    if (!r.index)
        return [r.base hasPrefix:@"f"] ? r.base : [NSString stringWithFormat:@"%@[0]", r.base];
    return [NSString stringWithFormat:@"%@[%@]", r.base, r.index];
    }

- (BOOL)wgStatement:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    if (i.result && rt.kind != XTIRTypeKindMemory && ![self.wf.used containsObject:@(i.result.valueId)] &&
        i.opcode != XTIROpCall && i.opcode != XTIROpStore)
        return YES;
    switch (i.opcode)
        {
        case XTIROpConst:
            {
            NSString* v = [self wgValue:i.operands[0] type:rt];
            if (!v)
                return NO;
            [self wgSet:i to:v];
            return YES;
            }
        case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpUDiv: case XTIROpSDiv:
        case XTIROpURem: case XTIROpSRem: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
        case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
        case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv:
            return [self wgBinary:i];
        case XTIROpNot:
            {
            NSString* a = [self wgValue:i.operands[0] type:rt];
            if (!a)
                return NO;
            [self wgSet:i to:rt.kind == XTIRTypeKindBool ? [NSString stringWithFormat:@"!%@", a]
                                                         : [self wgCanon:[NSString stringWithFormat:@"~%@", a] type:rt]];
            return YES;
            }
        case XTIROpNeg:
        case XTIROpFNeg:
            {
            NSString* a = [self wgValue:i.operands[0] type:rt];
            if (!a)
                return NO;
            if (rt.kind == XTIRTypeKindF32)
                [self wgSet:i to:[NSString stringWithFormat:@"-%@", a]];
            else if (wgWide(rt))
                [self wgSet:i to:[NSString stringWithFormat:@"xc_sub64(vec2<u32>(0u, 0u), %@)", a]];
            else
                [self wgSet:i to:[self wgCanon:[NSString stringWithFormat:@"(0u - %@)", a] type:rt]];
            return YES;
            }
        case XTIROpFSqrt:
            {
            if (!self.fast)
                {
                [self because:@"it takes a square root, which a WebGPU device does not round exactly, and the "
                              @"block's goal is accuracy"];
                return NO;
                }
            NSString* a = [self wgValue:i.operands[0] type:rt];
            if (!a || rt.kind != XTIRTypeKindF32)
                return NO;
            [self wgSet:i to:[NSString stringWithFormat:@"sqrt(%@)", a]];
            return YES;
            }
        case XTIROpICmp:
        case XTIROpFCmp:
            return [self wgCompare:i];
        case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc: case XTIROpSIToFp: case XTIROpUIToFp:
        case XTIROpFpToSI: case XTIROpFpToUI: case XTIROpCopy:
            return [self wgConvert:i];
        case XTIROpSelect:
            {
            NSString* c = [self wgValue:i.operands[0] type:nil];
            NSString* a = [self wgValue:i.operands[1] type:rt];
            NSString* b = [self wgValue:i.operands[2] type:rt];
            if (!c || !a || !b)
                return NO;
            [self wgSet:i to:[NSString stringWithFormat:@"select(%@, %@, %@)", b, a, c]];
            return YES;
            }
        case XTIROpFieldAddr:
            {
            NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:i.result.valueId]];
            if (k < 0)
                return NO;   // a field of a struct element: not in this cut
            if (self.objLayout.fields[(NSUInteger)k].type.kind == XTIRTypeKindPtr)
                return YES;   // a captured array's slot: only ever loaded, as the buffer
            XTWgRecipe* r = [XTWgRecipe new];
            r.base = [NSString stringWithFormat:@"f%ld", (long)k];
            r.pointee = self.objLayout.fields[(NSUInteger)k].type;
            self.wf.recipeOf[@(i.result.valueId)] = r;
            return YES;
            }
        case XTIROpElementAddr:
            {
            XTWgRecipe* b = i.operands[0].kind == XTIROperandKindUse ? self.wf.recipeOf[@(i.operands[0].valueId)] : nil;
            if (!b || !rt.pointeeType || [b.base hasPrefix:@"f"])
                return NO;   // an element of a field of the object: not in this cut
            XTIRType* it = i.operands[1].kind == XTIROperandKindUse ? [self typeOf:i.operands[1].valueId]
                                                                    : [XTIRType i64Type];
            NSString* idx = [self wgValue:i.operands[1] type:it];
            if (!idx || wgIsFloat(it) || it.kind == XTIRTypeKindBool || !wgType(it))
                return NO;
            // An element index is a u32: a buffer has fewer than 2^32 elements.
            if (wgWide(it))
                idx = [NSString stringWithFormat:@"%@.x", idx];
            if (b.index)
                idx = [NSString stringWithFormat:@"(%@ + %@)", b.index, idx];
            // In a function variable: the pointer may be used in another block.
            NSString* e = [@"e" stringByAppendingString:[[self name:i.result.valueId] substringFromIndex:1]];
            [self.wf.vars appendFormat:@"  var %@: u32;\n", e];
            [self wgLine:[NSString stringWithFormat:@"%@ = %@;", e, idx]];
            XTWgRecipe* r = [XTWgRecipe new];
            r.base = b.base;
            r.words = b.words;
            r.pointee = rt.pointeeType;
            r.index = e;
            self.wf.recipeOf[@(i.result.valueId)] = r;
            return YES;
            }
        case XTIROpBitcast:
            {
            if (rt.kind == XTIRTypeKindPtr)
                {
                XTWgRecipe* b = i.operands[0].kind == XTIROperandKindUse
                                    ? self.wf.recipeOf[@(i.operands[0].valueId)] : nil;
                if (!b || b.pointee.byteWidth != rt.pointeeType.byteWidth ||
                    ![wgType(b.pointee) isEqualToString:wgType(rt.pointeeType) ?: @""])
                    return NO;
                self.wf.recipeOf[@(i.result.valueId)] = b;
                return YES;
                }
            XTIRType* st = i.operands[0].kind == XTIROperandKindUse ? [self typeOf:i.operands[0].valueId] : rt;
            NSString* a = [self wgValue:i.operands[0] type:st];
            if (!a || st.byteWidth != rt.byteWidth || !wgType(rt) || !wgType(st))
                return NO;
            if ([wgType(st) isEqualToString:wgType(rt)])
                [self wgSet:i to:[self wgCanon:a type:rt]];   // a narrow result in its own form
            else if (st.byteWidth == 4)
                [self wgSet:i to:[NSString stringWithFormat:@"bitcast<%@>(%@)", wgType(rt), a]];
            else
                return NO;
            return YES;
            }
        case XTIROpLoad:
            {
            NSNumber* buf = self.bufferOf[@(i.result.valueId)];
            if (buf)
                {
                XTWgRecipe* r = [XTWgRecipe new];
                r.base = self.wgBufName[buf];
                r.pointee = rt.pointeeType;
                r.words = [self.wgWordBufs containsObject:r.base];
                self.wf.recipeOf[@(i.result.valueId)] = r;
                return YES;
                }
            if (rt.kind == XTIRTypeKindPtr)
                return NO;
            if ([self.sinitOf[@(i.operands[0].valueId)] boolValue])
                {
                [self wgSet:i to:[self wgValue:[XTIROperand immIWithType:rt value:2] type:rt]];
                return YES;
                }
            XTWgRecipe* r = self.wf.recipeOf[@(i.operands[0].valueId)];
            if (!r || !wgType(rt) || ![wgType(r.pointee) isEqualToString:wgType(rt)])
                return NO;
            if (r.words)
                {
                NSString* w = nil;
                NSString* sh = nil;
                if (![self wgWord:r word:&w shift:&sh])
                    return NO;
                NSString* word = [self wgLet:[NSString stringWithFormat:@"atomicLoad(&%@[%@])", r.base, w]];
                [self wgSet:i to:[self wgNarrowFrom:word shift:sh type:r.pointee]];
                return YES;
                }
            [self wgSet:i to:[self wgAccess:r]];
            return YES;
            }
        case XTIROpStore:
            {
            if (i.operands[0].kind != XTIROperandKindUse)
                return NO;
            XTWgRecipe* r = self.wf.recipeOf[@(i.operands[0].valueId)];
            if (!r)
                return NO;
            NSString* v = [self wgValue:i.operands[1] type:r.pointee];
            if (!v)
                return NO;
            if (r.words)
                {
                // Clear the element's bits in its word, then set them: two
                // atomic updates, so a neighbour writing the other bytes of the
                // word at the same time keeps its bytes.
                NSString* w = nil;
                NSString* sh = nil;
                if (![self wgWord:r word:&w shift:&sh])
                    return NO;
                uint32_t mask = wgNarrowBytes(r.pointee) == 1 ? 0xff : 0xffff;
                NSString* bits = r.pointee.kind == XTIRTypeKindBool ? [NSString stringWithFormat:@"select(0u, 1u, %@)", v]
                                                                    : [NSString stringWithFormat:@"(%@ & 0x%xu)", v, mask];
                [self wgLine:[NSString stringWithFormat:@"atomicAnd(&%@[%@], ~(0x%xu << %@));", r.base, w, mask, sh]];
                [self wgLine:[NSString stringWithFormat:@"atomicOr(&%@[%@], %@ << %@);", r.base, w, bits, sh]];
                return YES;
                }
            [self wgLine:[NSString stringWithFormat:@"%@ = %@;", [self wgAccess:r], v]];
            return YES;
            }
        case XTIROpCall:
            return [self wgCall:i];
        case XTIROpAddrOf:
            {
            if (self.sinitOf[@(i.result.valueId)])
                return YES;
            NSString* g = self.globalOf[@(i.result.valueId)];
            if (!g)
                return NO;
            XTWgRecipe* r = [XTWgRecipe new];
            r.base = self.wgBufName[@(-1 - (NSInteger)[self.globals indexOfObject:g])];
            r.pointee = rt.pointeeType;
            r.words = [self.wgWordBufs containsObject:r.base];
            self.wf.recipeOf[@(i.result.valueId)] = r;
            return YES;
            }
        case XTIROpDbgValue:
            return YES;
        default:
            return NO;
        }
    }

// ── control flow: the dispatch loop ─────────────────────────────────────────

// The phi copies for the edge from -> target, as a parallel copy: every
// incoming value into a let first, then the stores; each conditional on `cond`
// (nil: always), keeping the variable's old value when it does not hold.
- (BOOL)wgEdgeFrom:(XTIRBlock*)from to:(XTIRBlock*)target cond:(nullable NSString*)cond whenTrue:(BOOL)whenTrue
              lets:(NSMutableArray<NSString*>*)lets dsts:(NSMutableArray<NSString*>*)dsts
    {
    for (XTIRInsn* phi in target.phiNodes)
        {
        if (!phi.result || phi.result.type.kind == XTIRTypeKindMemory)
            continue;
        if (phi.result.type.kind == XTIRTypeKindPtr)
            return NO;   // a phi of pointers: not in this cut
        XTIROperand* in = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].blockRef == from)
                in = phi.operands[k + 1];
        if (!in)
            return NO;
        NSString* v = [self wgValue:in type:phi.result.type];
        NSString* dst = self.wf.varOf[@(phi.result.valueId)];
        if (!v)
            return NO;
        if (!dst)
            continue;
        if (cond)
            v = whenTrue ? [NSString stringWithFormat:@"select(%@, %@, %@)", dst, v, cond]
                         : [NSString stringWithFormat:@"select(%@, %@, %@)", v, dst, cond];
        [lets addObject:[self wgLet:v]];
        [dsts addObject:dst];
        }
    return YES;
    }

- (void)wgStores:(NSArray<NSString*>*)lets dsts:(NSArray<NSString*>*)dsts
    {
    for (NSUInteger k = 0; k < lets.count; k++)
        [self wgLine:[NSString stringWithFormat:@"%@ = %@;", dsts[k], lets[k]]];
    }

// The function's blocks as `loop { switch pc { … } }`, run while `guard`
// (nil: always) holds.
- (BOOL)wgDispatchGuard:(nullable NSString*)guard
    {
    XTWgFunc* f = self.wf;
    [f.code appendString:@"  var pc: u32 = 0u;\n"];
    [f.code appendFormat:@"  loop {\n    if (pc == %uu%@) { break; }\n    switch pc {\n", kWgExit,
                         guard ? [NSString stringWithFormat:@" || !(%@)", guard] : @""];
    for (NSUInteger k = 0; k < self.fn.blocks.count; k++)
        {
        XTIRBlock* b = self.fn.blocks[k];
        [f.code appendFormat:@"    case %luu: {\n", (unsigned long)k];
        for (XTIRInsn* i in b.instructions)
            if (![self wgStatement:i])
                {
                [self because:[self whyFor:i ptx:YES]];
                return NO;
                }
        XTIRInsn* t = b.terminator;
        NSMutableArray<NSString*>* lets = [NSMutableArray array];
        NSMutableArray<NSString*>* dsts = [NSMutableArray array];
        switch (t.opcode)
            {
            case XTIROpBranch:
                if (![self wgEdgeFrom:b to:t.operands[0].blockRef cond:nil whenTrue:YES lets:lets dsts:dsts])
                    return NO;
                [self wgStores:lets dsts:dsts];
                [self wgLine:[NSString stringWithFormat:@"pc = %@u;", self.blockIndex[t.operands[0].blockRef.name]]];
                break;
            case XTIROpCondBranch:
                {
                NSString* c = [self wgValue:t.operands[0] type:nil];
                if (!c)
                    return NO;
                c = [self wgLet:c];
                XTIRBlock* yes = t.operands[1].blockRef;
                XTIRBlock* no = t.operands[2].blockRef;
                if (yes == no)
                    {
                    if (![self wgEdgeFrom:b to:yes cond:nil whenTrue:YES lets:lets dsts:dsts])
                        return NO;
                    }
                else if (![self wgEdgeFrom:b to:yes cond:c whenTrue:YES lets:lets dsts:dsts] ||
                         ![self wgEdgeFrom:b to:no cond:c whenTrue:NO lets:lets dsts:dsts])
                    return NO;
                [self wgStores:lets dsts:dsts];
                [self wgLine:[NSString stringWithFormat:@"pc = select(%@u, %@u, %@);", self.blockIndex[no.name],
                                                        self.blockIndex[yes.name], c]];
                break;
                }
            case XTIROpReturn:
                {
                XTIROperand* rv = t.operands.count ? t.operands[0] : nil;
                XTIRType* rvt = !rv ? nil : rv.kind == XTIROperandKindUse ? [self typeOf:rv.valueId] : self.fn.returnType;
                if (self.helperMode && rvt && rvt.kind != XTIRTypeKindMemory)
                    {
                    NSString* v = [self wgValue:rv type:rvt];
                    if (!v || !f.retVar)
                        return NO;
                    [self wgLine:[NSString stringWithFormat:@"%@ = %@;", f.retVar, v]];
                    }
                [self wgLine:[NSString stringWithFormat:@"pc = %uu;", kWgExit]];
                break;
                }
            default:
                return NO;
            }
        [f.code appendString:@"    }\n"];
        }
    [f.code appendFormat:@"    default: { pc = %uu; }\n    }\n  }\n", kWgExit];
    return YES;
    }

// A variable for every SSA value that is read and is not a pointer or the
// memory token; a type this cut cannot hold fails.
- (BOOL)wgDeclareValues
    {
    // Values are named by their order in the walk, as the Metal printer names
    // them (name:), not by id: the port numbers its values differently.
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
    NSMutableSet<NSNumber*>* used = [NSMutableSet set];
    for (XTIRBlock* b in self.fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
        [all addObjectsFromArray:b.instructions];
        if (b.terminator)
            [all addObject:b.terminator];
        for (XTIRInsn* i in all)
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindUse)
                    [used addObject:@(o.valueId)];
        }
    self.wf.used = used;
    for (XTIRBlock* b in self.fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
        [all addObjectsFromArray:b.instructions];
        for (XTIRInsn* i in all)
            {
            if (!i.result)
                continue;
            XTIRType* t = i.result.type;
            if (t.kind == XTIRTypeKindMemory || t.kind == XTIRTypeKindPtr || ![used containsObject:@(i.result.valueId)])
                continue;
            NSString* ty = wgType(t);
            if (!ty)
                {
                [self because:t.kind == XTIRTypeKindF64 ? @"it uses a double, which WebGPU does not have"
                                                         : @"it uses a value its WebGPU version cannot hold"];
                return NO;
                }
            NSString* n = [self name:i.result.valueId];
            self.wf.varOf[@(i.result.valueId)] = n;
            [self.wf.vars appendFormat:@"  var %@: %@;\n", n, ty];
            }
        }
    return YES;
    }

- (XTWgFunc*)wgNewFunc
    {
    XTWgFunc* f = [XTWgFunc new];
    f.vars = [NSMutableString string];
    f.code = [NSMutableString string];
    f.varOf = [NSMutableDictionary dictionary];
    f.recipeOf = [NSMutableDictionary dictionary];
    return f;
    }

- (void)wgResetAnalysis
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

// A helper the kernel calls, printed into wgHelperText as `fn name(…)`.
- (BOOL)wgHelperNamed:(NSString*)name
    {
    [self wgResetAnalysis];
    if (![self analyse])
        return NO;
    NSUInteger bi = 0;
    for (XTIRBlock* b in self.fn.blocks)
        self.blockIndex[b.name] = @(bi++);
    XTIRType* rt = self.fn.returnType;
    BOOL isVoid = !rt || rt.kind == XTIRTypeKindVoid || rt.kind == XTIRTypeKindMemory;
    NSString* ret = isVoid ? nil : wgType(rt);
    if (!isVoid && !ret)
        return NO;
    self.wf = [self wgNewFunc];
    NSMutableArray<NSString*>* params = [NSMutableArray array];
    for (NSUInteger k = 0; k + 1 < self.fn.paramTypes.count; k++)
        {
        NSString* t = wgType(self.fn.paramTypes[k]);
        if (!t)
            return NO;
        [params addObject:[NSString stringWithFormat:@"p%lu: %@", (unsigned long)k, t]];
        // Parameter n is value n, read as the parameter itself (never written).
        self.wf.varOf[@(k)] = [NSString stringWithFormat:@"p%lu", (unsigned long)k];
        }
    if (![self wgDeclareValues])
        return NO;
    if (!isVoid)
        {
        self.wf.retVar = @"ret";
        [self.wf.vars appendFormat:@"  var ret: %@;\n", ret];
        }
    if (![self wgDispatchGuard:nil])
        return NO;
    [self.wgHelperText appendFormat:@"fn %@(%@)%@ {\n%@%@%@}\n", name, [params componentsJoinedByString:@", "],
                                    isVoid ? @"" : [NSString stringWithFormat:@" -> %@", ret], self.wf.vars,
                                    self.wf.code, isVoid ? @"" : @"  return ret;\n"];
    return YES;
    }

// A field of the object, read from its bytes (binding 0, array<u32>) at byte
// offset `off`: a WGSL expression of the field's type, or nil.
- (nullable NSString*)wgFieldFrom:(uint32_t)off type:(XTIRType*)t
    {
    uint32_t w = off >> 2;
    if (wgNarrowBytes(t))
        {
        NSString* word = [NSString stringWithFormat:@"args[%uu]", w];
        return [self wgNarrowFrom:word shift:[self wgU32Lit:(off & 3) * 8] type:t];
        }
    if (off & 3)
        return nil;
    switch (t.kind)
        {
        case XTIRTypeKindI32: case XTIRTypeKindU32: return [NSString stringWithFormat:@"args[%uu]", w];
        case XTIRTypeKindF32: return [NSString stringWithFormat:@"bitcast<f32>(args[%uu])", w];
        case XTIRTypeKindI64: case XTIRTypeKindU64:
            return [NSString stringWithFormat:@"vec2<u32>(args[%uu], args[%uu])", w, w + 1];
        default: return nil;
        }
    }

- (nullable NSString*)wgPrint
    {
    [self wgResetAnalysis];
    XTIRType* selfT = self.fn.paramTypes.count ? self.fn.paramTypes[0] : nil;
    self.objLayout = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    NSArray<XTIRLayoutField*>* fl = self.objLayout.fields;
    if (!self.objLayout || fl.count < 3 || fl[1].type.kind != XTIRTypeKindI64 || fl[2].type.kind != XTIRTypeKindI64)
        return nil;
    if (![self analyse])
        return nil;
    NSUInteger bi = 0;
    for (XTIRBlock* b in self.fn.blocks)
        self.blockIndex[b.name] = @(bi++);
    self.wgHelpers = [NSMutableDictionary dictionary];
    self.wgHelperText = [NSMutableString string];
    self.wgWordBufs = [NSMutableSet set];
    self.wgBufName = [NSMutableDictionary dictionary];

    // The object's fields the kernel uses (other than captured arrays): lo,
    // hi, and every `FieldAddr self, #k`, in field order, as kernel variables.
    NSMutableIndexSet* used = [NSMutableIndexSet indexSetWithIndex:1];
    [used addIndex:2];
    for (XTIRBlock* b in self.fn.blocks)
        for (XTIRInsn* i in b.instructions)
            if (i.opcode == XTIROpFieldAddr && i.result)
                {
                NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:i.result.valueId]];
                if (k >= 0 && fl[(NSUInteger)k].type.kind != XTIRTypeKindPtr)
                    [used addIndex:(NSUInteger)k];
                }
    self.wf = [self wgNewFunc];
    NSMutableString* fieldInit = [NSMutableString string];
    __block BOOL bad = NO;
    [used enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        NSString* ty = wgType(fl[k].type);
        NSString* from = ty ? [self wgFieldFrom:fl[k].byteOffset type:fl[k].type] : nil;
        if (!from)
            {
            [self because:fl[k].type.kind == XTIRTypeKindF64 ? @"it uses a double, which WebGPU does not have"
                                                              : @"it uses a captured value its WebGPU version cannot hold"];
            bad = YES;
            *stop = YES;
            return;
            }
        [self.wf.vars appendFormat:@"  var f%lu: %@;\n", (unsigned long)k, ty];
        [fieldInit appendFormat:@"  f%lu = %@;\n", (unsigned long)k, from];
    }];
    if (bad)
        return nil;

    // Bindings: the object (0), the span (1), then buffers in the header's order.
    NSMutableString* meta = [NSMutableString stringWithFormat:@"// xcpar size=%u lo=%u hi=%u", self.objLayout.size,
                                                              fl[1].byteOffset, fl[2].byteOffset];
    NSMutableString* decls = [NSMutableString string];
    [decls appendString:@"@group(0) @binding(0) var<storage, read> args: array<u32>;\n"];
    [decls appendString:@"@group(0) @binding(1) var<storage, read> span: array<vec2<u32>, 3>;\n"];
    __block uint32_t binding = 2;
    NSString* (^declare)(NSString*, XTIRType*) = ^NSString*(NSString* name, XTIRType* et) {
      NSString* t = wgType(et);
      if (!t || et.kind == XTIRTypeKindF64)
          return nil;
      BOOL narrow = wgNarrowBytes(et) != 0;
      [decls appendFormat:@"@group(0) @binding(%u) var<storage, read_write> %@: array<%@>;\n", binding++, name,
                          narrow ? @"atomic<u32>" : t];
      if (narrow)
          [self.wgWordBufs addObject:name];
      return name;
    };
    [self.bufferFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        XTIRType* et = fl[k].type.pointeeType;
        NSString* n = declare([NSString stringWithFormat:@"b%lu", (unsigned long)k], et);
        if (!n)
            {
            [self because:et.kind == XTIRTypeKindF64 ? @"it uses an array of doubles, which WebGPU does not have"
                                                      : @"it uses an array of values its WebGPU version cannot hold"];
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" buf=%u:%lu:%u", fl[k].byteOffset, (unsigned long)(k - 3), et.byteWidth];
        self.wgBufName[@(k)] = n;
    }];
    if (bad)
        return nil;
    for (NSUInteger gi = 0; gi < self.globals.count; gi++)
        {
        XTIRSymbol* g = [self.module symbolForName:self.globals[gi]];
        XTIRType* gt = g.globalType;
        XTIRType* et = gt.kind == XTIRTypeKindAgg ? gt.layout.fields.firstObject.type : gt;
        NSString* n = declare([NSString stringWithFormat:@"g%lu", (unsigned long)gi], et);
        if (!n)
            {
            [self because:[NSString stringWithFormat:@"it uses %@, which its WebGPU version cannot hold",
                                                     wgShownName(g.name)]];
            return nil;
            }
        [meta appendFormat:@" glob=%@:%u", self.globals[gi], et.byteWidth];
        self.wgBufName[@(-1 - (NSInteger)gi)] = n;
        }
    NSMutableArray<NSString*>* reds = [NSMutableArray array];
    [self.reductionFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        XTIRType* t = fl[k].type;
        if (!wgType(t) || wgNarrowBytes(t) || ![used containsIndex:k])
            {
            [self because:@"it reduces an 8- or 16-bit value or a bool, which its WebGPU version cannot yet"];
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" red=%u:%u", fl[k].byteOffset, t.byteWidth];
        NSString* n = [NSString stringWithFormat:@"r%lu", (unsigned long)k];
        [decls appendFormat:@"@group(0) @binding(%u) var<storage, read_write> %@: array<%@>;\n", binding++, n, wgType(t)];
        [reds addObject:[NSString stringWithFormat:@"%@[tid] = f%lu;", n, (unsigned long)k]];
    }];
    if (bad)
        return nil;

    // The kernel: the thread's lo and hi, the run loop, its partials.
    if (![self wgDeclareValues])
        return nil;
    NSMutableString* body = [NSMutableString string];
    [body appendString:fieldInit];
    // Past 65535 workgroups the dispatch is two-dimensional (WebGPU's limit
    // per dimension): rows of 65535 groups of 64.
    [body appendString:@"  let tid = gid.x + gid.y * 4194240u;\n"];
    [body appendString:@"  let lo = xc_add64(span[0], xc_mul64(vec2<u32>(tid, 0u), span[2]));\n"];
    [body appendString:@"  let end = xc_add64(lo, span[2]);\n"];
    [body appendString:@"  let hi = select(span[1], end, xc_slt64(end, span[1]));\n"];
    [body appendString:@"  f1 = lo;\n  f2 = hi;\n"];
    if (![self wgDispatchGuard:@"xc_slt64(lo, hi)"])
        return nil;
    [body appendString:self.wf.code];
    if (reds.count)
        [body appendFormat:@"  if (xc_slt64(lo, span[1])) {\n    %@\n  }\n", [reds componentsJoinedByString:@"\n    "]];
    if (self.why)
        return nil;

    if (self.fast)
        [meta appendString:@" wgsl fast"];
    else
        [meta appendString:@" wgsl"];
    NSMutableString* out = [NSMutableString stringWithFormat:@"%@\n", meta];
    [out appendString:decls];
    [out appendString:kWg64];
    [out appendString:self.wgHelperText];
    [out appendFormat:@"@compute @workgroup_size(64)\nfn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n%@%@}\n",
                      self.wf.vars, body];
    return out;
    }

+ (nullable NSString*)wgslForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                why:(NSString* _Nullable* _Nullable)why
    {
    XTIRParMSL* p = [XTIRParMSL new];
    p.module = module;
    p.fn = run;
    p.fast = fast;
    NSString* out = [p wgPrint];
    if (!out && why)
        *why = p.why;
    return out;
    }

@end
