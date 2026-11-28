#import "XTIROptPackNative.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRSupport.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSymbol.h"
#import "XTIROptTargetProfile.h"

// What a FloatPack call does, and to which pack.
typedef NS_ENUM(NSInteger, XTPackCallKind) {
    XTPackCallNone,
    XTPackCallUnpack,  // _xt_fpk_unpack: pack -> f32
    XTPackCallFromF32, // _xt_fpk_pack_f32
    XTPackCallFromF64, // _xt_fpk_pack_f64
    XTPackCallFromI32,
    XTPackCallFromU32,
    XTPackCallFromI64,
    XTPackCallFromU64,
};

// The two packs with a native form: f16 (e5m10) and bf16 (e8m7).
typedef NS_ENUM(NSInteger, XTPackNativeType) {
    XTPackNativeNone,
    XTPackNativeF16,
    XTPackNativeBF16,
};

@interface XTIROptPackNative ()
@property(nonatomic, strong) XTIRFunction* fn;
@property(nonatomic, strong) XTIRModule* mod;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf;
// The forms the function being rewritten may take: the profile's, or a
// dispatch clone's level's (F16C, FEAT_FP16 arithmetic).
@property(nonatomic) BOOL hw;
@property(nonatomic) BOOL arith;
@end

@implementation XTIROptPackNative

- (NSString*)passName
    {
    return @"pack-native";
    }

// At every level: the back ends' differentials compare -O0 code, and the
// conversions are the same whichever level built them.
- (NSInteger)minOptLevel
    {
    return 0;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.packF16Hardware && !prof.packBF16Inline && !prof.packF8Inline)
        return YES;
    self.mod = mod;
    NSArray<XTIRFunction*>* fns = [mod.functions copy];
    NSMutableDictionary<NSString*, XTIRFunction*>* byName = [NSMutableDictionary dictionary];
    for (XTIRFunction* fn in fns)
        byName[fn.name] = fn;
    NSMutableArray<XTIRFunction*>* drop = [NSMutableArray array];
    for (XTIRFunction* fn in fns)
        {
        [self runOnFunction:fn profile:prof];
        // An fp16 clone with no half operation is its base's code: it goes,
        // and the base keeps its one version. Asked of the result, not of
        // this run, so that IR this pass already rewrote (post-opt IR handed
        // back to the pipeline) keeps its clones.
        if ([fn.simdLevel isEqualToString:@"fp16"])
            {
            XTIRFunction* base = byName[fn.simdBaseName];
            if (base && hasHalfOp(fn))
                base.simdDispatch = YES;
            else
                [drop addObject:fn];
            }
        }
    [mod.functions removeObjectsInArray:drop];
    return YES;
    }

// A half-precision operation or comparison, scalar or in lanes: what FEAT_FP16
// adds.
static BOOL hasHalfOp(XTIRFunction* fn)
    {
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* x in bb.instructions)
            {
            XTIROpcode op = x.opcode;
            // The vectoriser's f16 lane operations (P1).
            if (op == XTIROpVHAdd || op == XTIROpVHSub || op == XTIROpVHMul || op == XTIROpVHDiv || op == XTIROpVHSqrt)
                return YES;
            if ((op == XTIROpFAdd || op == XTIROpFSub || op == XTIROpFMul || op == XTIROpFDiv || op == XTIROpFSqrt)
                && x.result && x.result.type.kind == XTIRTypeKindU16)
                return YES;
            if (op == XTIROpFCmp && x.operands.count && x.operands[0].kind == XTIROperandKindUse
                && fn.values[@(x.operands[0].valueId)].type.kind == XTIRTypeKindU16)
                return YES;
            }
    return NO;
    }

+ (BOOL)functionHasHalfCall:(XTIRFunction*)fn module:(XTIRModule*)mod
    {
    XTIROptPackNative* p = [[XTIROptPackNative alloc] init];
    p.mod = mod;
    p.fn = fn;
    p.defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                p.defOf[@(i.result.valueId)] = i;
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* n in bb.instructions)
            {
            XTPackNativeType pk;
            XTPackCallKind k = [p kindOf:n pack:&pk];
            if (pk == XTPackNativeF16 && k != XTPackCallNone && k != XTPackCallFromF64)
                return YES;
            }
    return NO;
    }

#pragma mark - Recognising the calls

// An operand's integer constant: an immediate, or a Use of a Const.
- (BOOL)constOf:(XTIROperand*)op value:(int64_t*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        *out = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = self.defOf[@(op.valueId)];
    if (!d || d.opcode != XTIROpConst || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindImmI)
        return NO;
    *out = d.operands[0].intValue;
    return YES;
    }

// A direct call of one of FloatPack's conversions for f16 or bf16, as
// [callee, value, e, m, mem] with the value a Use; the pack in *pack.
- (XTPackCallKind)kindOf:(XTIRInsn*)n pack:(XTPackNativeType*)pack
    {
    *pack = XTPackNativeNone;
    if (n.opcode != XTIROpCall || !n.result || n.operands.count != 5)
        return XTPackCallNone;
    XTIROperand* c = n.operands[0];
    if (c.kind != XTIROperandKindSym)
        return XTPackCallNone;
    XTIRSymbol* sym = [self.mod symbolForId:c.symbolId];
    NSString* nm = sym.name;
    if (![nm hasPrefix:@"_xt_fpk_"])
        return XTPackCallNone;
    XTPackCallKind k = XTPackCallNone;
    if ([nm isEqualToString:@"_xt_fpk_unpack"])
        k = XTPackCallUnpack;
    else if ([nm isEqualToString:@"_xt_fpk_pack_f32"])
        k = XTPackCallFromF32;
    else if ([nm isEqualToString:@"_xt_fpk_pack_f64"])
        k = XTPackCallFromF64;
    else if ([nm isEqualToString:@"_xt_fpk_pack_i32"])
        k = XTPackCallFromI32;
    else if ([nm isEqualToString:@"_xt_fpk_pack_u32"])
        k = XTPackCallFromU32;
    else if ([nm isEqualToString:@"_xt_fpk_pack_i64"])
        k = XTPackCallFromI64;
    else if ([nm isEqualToString:@"_xt_fpk_pack_u64"])
        k = XTPackCallFromU64;
    if (k == XTPackCallNone || n.operands[1].kind != XTIROperandKindUse)
        return XTPackCallNone;
    int64_t e = 0, m = 0;
    if (![self constOf:n.operands[2] value:&e] || ![self constOf:n.operands[3] value:&m])
        return XTPackCallNone;
    if (e == 5 && m == 10)
        *pack = XTPackNativeF16;
    else if (e == 8 && m == 7)
        *pack = XTPackNativeBF16;
    else
        return XTPackCallNone;
    return k;
    }

// A direct call of FloatPack's widening of a pack of at most 8 bits
// (`_xt_fpk_unpack` [callee, value, e, m, mem], `_xt_fpk_unpackk` [callee,
// value, e, m, k, mem]) with constant widths and word: the pack's (e, m, k) in
// out[0..2], the special-value bits of k alone (8 and 16 change only the
// narrowing).
- (BOOL)tableCall:(XTIRInsn*)n pack:(int64_t*)out
    {
    if (n.opcode != XTIROpCall || !n.result || n.operands.count < 5)
        return NO;
    XTIROperand* c = n.operands[0];
    if (c.kind != XTIROperandKindSym)
        return NO;
    NSString* nm = [self.mod symbolForId:c.symbolId].name;
    BOOL kinds = [nm isEqualToString:@"_xt_fpk_unpackk"];
    if (!kinds && ![nm isEqualToString:@"_xt_fpk_unpack"])
        return NO;
    if (n.operands.count != (kinds ? 6u : 5u) || n.operands[1].kind != XTIROperandKindUse)
        return NO;
    int64_t e = 0, m = 0, k = 0;
    if (![self constOf:n.operands[2] value:&e] || ![self constOf:n.operands[3] value:&m])
        return NO;
    if (kinds && ![self constOf:n.operands[4] value:&k])
        return NO;
    k = k & 7;
    if ((k & 4) == 0 && (e < 2 || m < 1 || e + m > 7 || (k & 3) == 3))
        return NO;
    out[0] = e;
    out[1] = m;
    out[2] = k;
    return YES;
    }

// A direct call of FloatPack's narrowing from f32 to a signed pack of at most
// 8 bits (`_xt_fpk_pack_f32` [callee, value, e, m, mem], `_xt_fpk_pack_f32k`
// [callee, value, e, m, k, mem]) with constant widths and a word of the kind
// alone (the compiler's own conversions; the explicit ones that pass 8 or 16,
// and ue8m0, keep their calls): (e, m, kind) in out[0..2].
- (BOOL)narrowCall:(XTIRInsn*)n pack:(int64_t*)out
    {
    if (n.opcode != XTIROpCall || !n.result || n.operands.count < 5)
        return NO;
    XTIROperand* c = n.operands[0];
    if (c.kind != XTIROperandKindSym)
        return NO;
    NSString* nm = [self.mod symbolForId:c.symbolId].name;
    BOOL kinds = [nm isEqualToString:@"_xt_fpk_pack_f32k"];
    if (!kinds && ![nm isEqualToString:@"_xt_fpk_pack_f32"])
        return NO;
    if (n.operands.count != (kinds ? 6u : 5u) || n.operands[1].kind != XTIROperandKindUse)
        return NO;
    int64_t e = 0, m = 0, k = 0;
    if (![self constOf:n.operands[2] value:&e] || ![self constOf:n.operands[3] value:&m])
        return NO;
    if (kinds && ![self constOf:n.operands[4] value:&k])
        return NO;
    if (k < 0 || k > 2 || e < 2 || m < 1 || e + m > 7)
        return NO;
    out[0] = e;
    out[1] = m;
    out[2] = k;
    return YES;
    }

// The f32 bits of pattern h of pack (e, m, k): FloatPackKinds'
// `_xt_fpk_unpackk`, step for step, which for k = 0 and at most 6 exponent
// bits is FloatPack's `_xt_fpk_unpack`.
static uint32_t tableBits(uint32_t h, uint32_t e, uint32_t m, uint32_t k)
    {
    uint32_t one = 1;
    uint32_t x = h;
    uint32_t bits = 0;
    if ((k & 4) != 0)
        {
        uint32_t ue = x & 0xFF;
        if (ue == 0xFF)
            bits = 0x7FC00000;
        else if (ue == 0)
            bits = 0x00400000;
        else
            bits = ue << 23;
        return bits;
        }
    uint32_t sign = (x >> (e + m)) & one;
    uint32_t emax = (one << e) - one;
    uint32_t mmax = (one << m) - one;
    uint32_t ex = (x >> m) & emax;
    uint32_t mant = x & mmax;
    uint32_t sh = 23 - m;
    int32_t bias = (int32_t)((one << (e - one)) - one);
    uint32_t kind = k & 3;
    if (ex == emax && kind == 0)
        bits = 0x7F800000 | (mant << sh);
    else if (ex == emax && kind == 1 && mant == mmax)
        bits = 0x7FC00000;
    else if (ex == 0)
        {
        if (mant != 0)
            {
            int32_t unb = 1 - bias;
            while ((mant & (one << m)) == 0)
                {
                mant = mant << 1;
                unb = unb - 1;
                }
            bits = ((uint32_t)(unb + 127) << 23) | ((mant & mmax) << sh);
            }
        }
    else
        bits = ((uint32_t)((int32_t)ex - bias + 127) << 23) | (mant << sh);
    return bits | (sign << 31);
    }

// The module's table for pack (e, m, k), made at its first use: a string
// literal (module-local in every back end, so two objects' tables never
// meet) of the pack's 2^(1+e+m) values, 256 for ue8m0, as little-endian f32
// bits, on a 4-byte boundary (align4). Named by the pack, so each module has
// one per pack: _xt_fpk_tab_e4m3_finite, _xt_fpk_tab_e5m2_ieee,
// _xt_fpk_tab_ue8m0, _xt_fpk_tab_e2m1_none.
- (XTIRSymbolId)tableFor:(const int64_t*)pk
    {
    uint32_t e = (uint32_t)pk[0], m = (uint32_t)pk[1], k = (uint32_t)pk[2];
    NSString* nm;
    if (k & 4)
        nm = @"_xt_fpk_tab_ue8m0";
    else
        {
        NSArray<NSString*>* kindNames = @[ @"ieee", @"finite", @"none" ];
        nm = [NSString stringWithFormat:@"_xt_fpk_tab_e%um%u_%@", e, m, kindNames[k & 3]];
        }
    for (NSUInteger i = 0; i < self.mod.symbols.count; i++)
        if ([self.mod.symbols[i].name isEqualToString:nm])
            return (XTIRSymbolId)i;
    uint32_t count = (k & 4) ? 256 : 1u << (1 + e + m);
    NSMutableData* bytes = [NSMutableData dataWithCapacity:count * 4];
    for (uint32_t h = 0; h < count; h++)
        {
        uint32_t b = tableBits(h, e, m, k);
        uint8_t le[4] = { (uint8_t)b, (uint8_t)(b >> 8), (uint8_t)(b >> 16), (uint8_t)(b >> 24) };
        [bytes appendBytes:le length:4];
        }
    XTIRSymbol* sym = [XTIRSymbol stringLitWithName:nm bytes:bytes];
    sym.attributes = @{@"align4" : @YES, @"banked" : @NO, @"cloaked" : @NO};
    return [self.mod addSymbol:sym];
    }

#pragma mark - Building

- (XTIRValue*)newValue:(XTIRType*)t block:(XTIRBlock*)bb at:(NSUInteger)at
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[self.fn allocateValueId]
                                                 type:t
                                              defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:at]];
    [self.fn registerValue:v];
    return v;
    }

// Appends `op` to *list, with result `res` (a fresh value of type t when res
// is nil); returns the result.
- (XTIRValue*)emit:(XTIROpcode)op
              type:(XTIRType*)t
               res:(nullable XTIRValue*)res
          operands:(NSArray<XTIROperand*>*)ops
         predicate:(uint8_t)pred
              into:(NSMutableArray<XTIRInsn*>*)list
             block:(XTIRBlock*)bb
                at:(NSUInteger)at
               dbg:(nullable XTIRDbgLoc*)dbg
    {
    XTIRValue* r = res ?: [self newValue:t block:bb at:at + list.count];
    XTIRInsn* n;
    if (XTIROpCarriesPredicate(op))
        n = [[XTIRInsn alloc] initWithOpcode:op result:r operands:ops predicate:pred dbgLoc:dbg];
    else
        n = [[XTIRInsn alloc] initWithOpcode:op result:r operands:ops dbgLoc:dbg];
    [list addObject:n];
    self.defOf[@(r.valueId)] = n;
    return r;
    }

// A u32 immediate: every back end takes one as the right operand of the
// integer arithmetic, bitwise, shift and compare operations.
static XTIROperand* imm(int64_t v)
    {
    return [XTIROperand immIWithType:[XTIRType u32Type] value:v];
    }

static XTIROperand* use(XTIRValue* v)
    {
    return [XTIROperand useWithValueId:v.valueId];
    }

#pragma mark - The pass

- (void)runOnFunction:(XTIRFunction*)fn profile:(XTIROptTargetProfile*)prof
    {
    self.fn = fn;
    self.defOf = [NSMutableDictionary dictionary];
    NSString* lvl = fn.simdLevel;
    self.hw = prof.packF16Hardware || [lvl isEqualToString:@"avx2"] || [lvl isEqualToString:@"avx512"];
    self.arith = prof.packF16Arith || [lvl isEqualToString:@"fp16"];
    BOOL any = NO;
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                self.defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* i in bb.instructions)
            {
            if (i.result)
                self.defOf[@(i.result.valueId)] = i;
            if (i.opcode == XTIROpCall)
                any = YES;
            }
        }
    if (!any)
        return;

    // Every call this pass may rewrite, and for an f16 unpack the half it
    // reads (unpackSrc).
    NSMutableDictionary<NSNumber*, XTIROperand*>* unpackSrc = [NSMutableDictionary dictionary];
    BOOL found = NO;
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* n in bb.instructions)
            {
            int64_t tp[3];
            if (prof.packF8Inline && ([self tableCall:n pack:tp] || [self narrowCall:n pack:tp]))
                found = YES;
            XTPackNativeType pk;
            XTPackCallKind k = [self kindOf:n pack:&pk];
            if (k == XTPackCallNone)
                continue;
            found = YES;
            if (k == XTPackCallUnpack && pk == XTPackNativeF16 && self.hw)
                unpackSrc[@(n.result.valueId)] = n.operands[1];
            }
    if (!found)
        return;

    NSCountedSet<NSNumber*>* uses = [self usesIn:fn];
    // Instructions whose results may have no use left once the calls are
    // rewritten: the e/m constants, the f32 operations a half operation
    // replaces, the conversions nothing reads any more.
    NSMutableArray<NSNumber*>* maybeDead = [NSMutableArray array];
    NSMutableArray<XTIRValue*>* f16Widened = [NSMutableArray array];
    NSMutableArray<NSNumber*>* memFrom = [NSMutableArray array];
    NSMutableArray<NSNumber*>* memTo = [NSMutableArray array];

    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* out = [NSMutableArray arrayWithCapacity:bb.instructions.count];
        for (XTIRInsn* n in bb.instructions)
            {
            int64_t tp[3];
            if (prof.packF8Inline && [self tableCall:n pack:tp])
                {
                [self tableLoad:n pack:tp into:out block:bb dead:maybeDead];
                continue;
                }
            if (prof.packF8Inline && [self narrowCall:n pack:tp])
                {
                [self narrow:n pack:tp into:out block:bb dead:maybeDead];
                XTIROperand* memIn = n.operands.lastObject;
                if (n.memoryResult && memIn.kind == XTIROperandKindUse)
                    {
                    [memFrom addObject:@(n.memoryResult.valueId)];
                    [memTo addObject:@(memIn.valueId)];
                    }
                continue;
                }
            XTPackNativeType pk;
            XTPackCallKind k = [self kindOf:n pack:&pk];
            BOOL rewrite = (pk == XTPackNativeBF16 && prof.packBF16Inline
                            && (k == XTPackCallUnpack || k == XTPackCallFromF32))
                        || (pk == XTPackNativeF16 && self.hw
                            && (k != XTPackCallFromF64 || prof.packF16FromF64));
            if (!rewrite)
                {
                // A comparison of two widened halves compares the halves.
                if (self.arith && n.opcode == XTIROpFCmp && n.operands.count == 2
                    && n.operands[0].kind == XTIROperandKindUse && n.operands[1].kind == XTIROperandKindUse)
                    {
                    XTIROperand* a = unpackSrc[@(n.operands[0].valueId)];
                    XTIROperand* b = unpackSrc[@(n.operands[1].valueId)];
                    if (a && b)
                        {
                        [maybeDead addObject:@(n.operands[0].valueId)];
                        [maybeDead addObject:@(n.operands[1].valueId)];
                        [out addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpFCmp
                                                                 result:n.result
                                                               operands:@[ a, b ]
                                                              predicate:n.predicate
                                                                 dbgLoc:n.dbgLoc]];
                        continue;
                        }
                    }
                [out addObject:n];
                continue;
                }
            NSUInteger at = out.count;
            XTIRDbgLoc* dbg = n.dbgLoc;
            XTIROperand* src = n.operands[1];
            XTIRValue* res = n.result;
            for (NSUInteger j = 2; j < 4; j++)
                if (n.operands[j].kind == XTIROperandKindUse)
                    [maybeDead addObject:@(n.operands[j].valueId)];
            if (pk == XTPackNativeBF16 && k == XTPackCallUnpack)
                {
                // The pattern is the top half of the f32.
                XTIRValue* z = [self emit:XTIROpZExt type:[XTIRType u32Type] res:nil operands:@[ src ]
                                predicate:0 into:out block:bb at:at dbg:dbg];
                XTIROperand* c16 = imm(16);
                XTIRValue* s = [self emit:XTIROpShl type:[XTIRType u32Type] res:nil operands:@[ use(z), c16 ]
                                predicate:0 into:out block:bb at:at dbg:dbg];
                [self emit:XTIROpBitcast type:[XTIRType f32Type] res:res operands:@[ use(s) ]
                 predicate:0 into:out block:bb at:at dbg:dbg];
                }
            else if (pk == XTPackNativeBF16)
                {
                // Round to nearest even on the bits; a NaN keeps its sign and
                // top payload and is made quiet.
                XTIRType* u = [XTIRType u32Type];
                XTIRValue* x = [self emit:XTIROpBitcast type:u res:nil operands:@[ src ]
                                predicate:0 into:out block:bb at:at dbg:dbg];
                XTIROperand* c16 = imm(16);
                XTIRValue* hi = [self emit:XTIROpLShr type:u res:nil operands:@[ use(x), c16 ]
                                 predicate:0 into:out block:bb at:at dbg:dbg];
                XTIROperand* c1 = imm(1);
                XTIRValue* lsb = [self emit:XTIROpAnd type:u res:nil operands:@[ use(hi), c1 ]
                                  predicate:0 into:out block:bb at:at dbg:dbg];
                XTIROperand* cr = imm(0x7FFF);
                XTIRValue* t1 = [self emit:XTIROpAdd type:u res:nil operands:@[ use(x), cr ]
                                 predicate:0 into:out block:bb at:at dbg:dbg];
                XTIRValue* t2 = [self emit:XTIROpAdd type:u res:nil operands:@[ use(t1), use(lsb) ]
                                 predicate:0 into:out block:bb at:at dbg:dbg];
                XTIRValue* rne = [self emit:XTIROpLShr type:u res:nil operands:@[ use(t2), c16 ]
                                  predicate:0 into:out block:bb at:at dbg:dbg];
                XTIROperand* cm = imm(0x7FFFFFFF);
                XTIRValue* mag = [self emit:XTIROpAnd type:u res:nil operands:@[ use(x), cm ]
                                  predicate:0 into:out block:bb at:at dbg:dbg];
                XTIROperand* ci = imm(0x7F800000);
                XTIRValue* isNan = [self emit:XTIROpICmp type:[XTIRType boolType] res:nil operands:@[ use(mag), ci ]
                                    predicate:XTIRICmpUGT into:out block:bb at:at dbg:dbg];
                XTIROperand* cq = imm(0x40);
                XTIRValue* q = [self emit:XTIROpOr type:u res:nil operands:@[ use(hi), cq ]
                                predicate:0 into:out block:bb at:at dbg:dbg];
                XTIRValue* sel = [self emit:XTIROpSelect type:u res:nil operands:@[ use(isNan), use(q), use(rne) ]
                                  predicate:0 into:out block:bb at:at dbg:dbg];
                [self emit:XTIROpTrunc type:[XTIRType u16Type] res:res operands:@[ use(sel) ]
                 predicate:0 into:out block:bb at:at dbg:dbg];
                }
            else if (k == XTPackCallUnpack)
                {
                [self emit:XTIROpFpExt type:[XTIRType f32Type] res:res operands:@[ src ]
                 predicate:0 into:out block:bb at:at dbg:dbg];
                [f16Widened addObject:res];
                }
            else if (k == XTPackCallFromF32)
                {
                // A half operation where the f32 one is of two widened halves
                // (or one, for sqrt), read by this rounding alone.
                XTIRInsn* d = self.defOf[@(src.valueId)];
                BOOL fused = NO;
                if (self.arith && d && [uses countForObject:@(src.valueId)] == 1)
                    {
                    XTIROpcode op = d.opcode;
                    BOOL bin = op == XTIROpFAdd || op == XTIROpFSub || op == XTIROpFMul || op == XTIROpFDiv;
                    NSUInteger arity = bin ? 2 : op == XTIROpFSqrt ? 1 : 0;
                    if (arity && d.operands.count == arity && d.result.type.kind == XTIRTypeKindF32)
                        {
                        NSMutableArray<XTIROperand*>* hs = [NSMutableArray array];
                        for (XTIROperand* o in d.operands)
                            {
                            XTIROperand* h = o.kind == XTIROperandKindUse ? unpackSrc[@(o.valueId)] : nil;
                            if (!h)
                                break;
                            [hs addObject:h];
                            }
                        if (hs.count == arity)
                            {
                            [self emit:op type:[XTIRType u16Type] res:res operands:hs
                             predicate:0 into:out block:bb at:at dbg:dbg];
                            [maybeDead addObject:@(src.valueId)];
                            fused = YES;
                            }
                        }
                    }
                if (!fused)
                    [self emit:XTIROpFpTrunc type:[XTIRType u16Type] res:res operands:@[ src ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
                }
            else if (k == XTPackCallFromF64)
                {
                [self emit:XTIROpFpTrunc type:[XTIRType u16Type] res:res operands:@[ src ]
                 predicate:0 into:out block:bb at:at dbg:dbg];
                }
            else
                {
                // An integer: its f32 is exact, or past f16's range so that
                // either way the half is an infinity.
                BOOL sgn = k == XTPackCallFromI32 || k == XTPackCallFromI64;
                XTIRValue* f = [self emit:sgn ? XTIROpSIToFp : XTIROpUIToFp type:[XTIRType f32Type] res:nil
                                 operands:@[ src ] predicate:0 into:out block:bb at:at dbg:dbg];
                [self emit:XTIROpFpTrunc type:[XTIRType u16Type] res:res operands:@[ use(f) ]
                 predicate:0 into:out block:bb at:at dbg:dbg];
                }
            // The routines are pure: their memory token is their input's.
            if (n.memoryResult)
                {
                XTIROperand* memIn = n.operands.lastObject;
                if (memIn.kind == XTIROperandKindUse)
                    {
                    [memFrom addObject:@(n.memoryResult.valueId)];
                    [memTo addObject:@(memIn.valueId)];
                    }
                }
            }
        [bb.instructions setArray:out];
        }
    // In order, so a token forwarded to one that is itself forwarded later
    // ends at the first input.
    for (NSUInteger j = 0; j < memFrom.count; j++)
        {
        XTIRValueId to = (XTIRValueId)memTo[j].unsignedLongLongValue;
        for (NSUInteger q = 0; q < j; q++)
            if ((XTIRValueId)memFrom[q].unsignedLongLongValue == to)
                to = (XTIRValueId)memTo[q].unsignedLongLongValue;
        memTo[j] = @(to);
        [self forwardMemIn:fn from:(XTIRValueId)memFrom[j].unsignedLongLongValue to:to];
        }

    uses = [self usesIn:fn];
    [self removeDead:maybeDead uses:uses];
    for (XTIRValue* v in f16Widened)
        if ([uses countForObject:@(v.valueId)] > 0 && ![self quietIsInvisible:v profile:prof])
            [self keepSignalling:v];
    }

// An 8- or 4-bit pack widened by a load from its table: the index `ZExt
// U32` of the pattern (of the byte, when the pattern is a widened byte) and
// `And mask` unless that is a byte and the table has 256 entries or the byte
// is already masked to the table, `AddrOf` the table, `ElementAddr`, `Load
// F32`. The table holds the routine's own results, so the load is the call's
// bit for bit. The load takes the call's memory token and gives its result.
- (void)tableLoad:(XTIRInsn*)n
             pack:(const int64_t*)pk
             into:(NSMutableArray<XTIRInsn*>*)out
            block:(XTIRBlock*)bb
             dead:(NSMutableArray<NSNumber*>*)maybeDead
    {
    NSUInteger at = out.count;
    XTIRDbgLoc* dbg = n.dbgLoc;
    XTIROperand* src = n.operands[1];
    for (NSUInteger j = 2; j + 1 < n.operands.count; j++)
        if (n.operands[j].kind == XTIROperandKindUse)
            [maybeDead addObject:@(n.operands[j].valueId)];
    uint32_t count = (pk[2] & 4) ? 256 : 1u << (1 + pk[0] + pk[1]);
    // A pattern widened from a byte is indexed by the byte (the U16 widening
    // then has no use left).
    BOOL inRange = NO;
    XTIROperand* narrow = src;
    XTIRInsn* d = self.defOf[@(src.valueId)];
    if (d && d.opcode == XTIROpZExt && d.operands.count == 1 && d.operands[0].kind == XTIROperandKindUse
        && self.fn.values[@(d.operands[0].valueId)].type.kind == XTIRTypeKindU8)
        {
        XTIRInsn* w = self.defOf[@(d.operands[0].valueId)];
        int64_t c = 0;
        narrow = d.operands[0];
        [maybeDead addObject:@(src.valueId)];
        if (count == 256)
            inRange = YES;
        else if (w && w.opcode == XTIROpAnd && w.operands.count == 2 && [self constOf:w.operands[1] value:&c]
                 && c >= 0 && (c & ~(int64_t)(count - 1)) == 0)
            inRange = YES;
        }
    XTIRValue* z = [self emit:XTIROpZExt type:[XTIRType u32Type] res:nil operands:@[ narrow ]
                    predicate:0 into:out block:bb at:at dbg:dbg];
    XTIROperand* idx = use(z);
    if (!inRange)
        {
        XTIRValue* a = [self emit:XTIROpAnd type:[XTIRType u32Type] res:nil operands:@[ use(z), imm(count - 1) ]
                        predicate:0 into:out block:bb at:at dbg:dbg];
        idx = use(a);
        }
    XTIRSymbolId sid = [self tableFor:pk];
    XTIRType* fp = [XTIRType ptrToType:[XTIRType f32Type] window:0];
    XTIRValue* base = [self emit:XTIROpAddrOf type:fp res:nil operands:@[ [XTIROperand symWithSymbolId:sid] ]
                       predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* ea = [self emit:XTIROpElementAddr type:fp res:nil operands:@[ use(base), idx ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    [self emit:XTIROpLoad type:[XTIRType f32Type] res:n.result operands:@[ use(ea), n.operands.lastObject ]
     predicate:0 into:out block:bb at:at dbg:dbg];
    out.lastObject.memoryResult = n.memoryResult;
    }

// f32 to a signed pack of at most 8 bits, as FloatPack's rounding gives it,
// without a branch. With a = |x| (bits): below the pack's smallest normal,
// the f32 sum a + 2^(1-bias-m+23) rounds a to the pack's subnormal spacing
// (round to nearest even, the hardware's mode), and its bits less the
// constant's are the pattern (the smallest normal when it rounds up); above,
// the bits rounded to m mantissa bits on the integer, `(a + 2^(s-1) - 1 +
// lsb) >> s`, rebiased. Then the kind's saturation (ieee: the infinity, which
// an infinity reaches too; finite: the largest finite value; none: all ones),
// the sign, and a NaN: ieee keeps the sign and top payload bits, made quiet;
// finite gives the all-ones pattern of its sign; none gives +0. Checked
// against the routines over every f32 for each pack.
- (void)narrow:(XTIRInsn*)n
          pack:(const int64_t*)pk
          into:(NSMutableArray<XTIRInsn*>*)out
         block:(XTIRBlock*)bb
          dead:(NSMutableArray<NSNumber*>*)maybeDead
    {
    NSUInteger at = out.count;
    XTIRDbgLoc* dbg = n.dbgLoc;
    XTIROperand* src = n.operands[1];
    for (NSUInteger j = 2; j + 1 < n.operands.count; j++)
        if (n.operands[j].kind == XTIROperandKindUse)
            [maybeDead addObject:@(n.operands[j].valueId)];
    uint32_t e = (uint32_t)pk[0], m = (uint32_t)pk[1], kind = (uint32_t)pk[2];
    uint32_t bias = (1u << (e - 1)) - 1, sh = 23 - m;
    uint32_t all = (1u << (e + m)) - 1, inf = ((1u << e) - 1) << m, mmax = (1u << m) - 1;
    uint32_t lim = kind == 0 ? inf : kind == 1 ? all - 1 : all;
    uint32_t magic = (127 + 24 - bias - m) << 23;
    XTIRType* u = [XTIRType u32Type];
    XTIRType* b = [XTIRType boolType];
    XTIRValue* x = [self emit:XTIROpBitcast type:u res:nil operands:@[ src ] predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* a = [self emit:XTIROpAnd type:u res:nil operands:@[ use(x), imm(0x7FFFFFFF) ]
                    predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* fa = [self emit:XTIROpBitcast type:[XTIRType f32Type] res:nil operands:@[ use(a) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    uint64_t md = (uint64_t)(1023 + 24 - bias - m) << 52;
    XTIRValue* c = [self emit:XTIROpConst type:[XTIRType f32Type] res:nil
                     operands:@[ [XTIROperand immFWithType:[XTIRType f32Type] rawBytes:md] ]
                    predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* fs = [self emit:XTIROpFAdd type:[XTIRType f32Type] res:nil operands:@[ use(fa), use(c) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* sb = [self emit:XTIROpBitcast type:u res:nil operands:@[ use(fs) ] predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* sub = [self emit:XTIROpSub type:u res:nil operands:@[ use(sb), imm(magic) ]
                      predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* hi = [self emit:XTIROpLShr type:u res:nil operands:@[ use(a), imm(sh) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* lsb = [self emit:XTIROpAnd type:u res:nil operands:@[ use(hi), imm(1) ]
                      predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* t1 = [self emit:XTIROpAdd type:u res:nil operands:@[ use(a), imm((1u << (sh - 1)) - 1) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* t2 = [self emit:XTIROpAdd type:u res:nil operands:@[ use(t1), use(lsb) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* t3 = [self emit:XTIROpLShr type:u res:nil operands:@[ use(t2), imm(sh) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* nrm = [self emit:XTIROpSub type:u res:nil operands:@[ use(t3), imm((127 - bias) << m) ]
                      predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* isSub = [self emit:XTIROpICmp type:b res:nil operands:@[ use(a), imm((128 - bias) << 23) ]
                        predicate:XTIRICmpULT into:out block:bb at:at dbg:dbg];
    XTIRValue* q = [self emit:XTIROpSelect type:u res:nil operands:@[ use(isSub), use(sub), use(nrm) ]
                    predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* big = [self emit:XTIROpICmp type:b res:nil operands:@[ use(q), imm(lim) ]
                      predicate:XTIRICmpUGT into:out block:bb at:at dbg:dbg];
    XTIRValue* cl = [self emit:XTIROpConst type:u res:nil operands:@[ imm(lim) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* q2 = [self emit:XTIROpSelect type:u res:nil operands:@[ use(big), use(cl), use(q) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* sg = [self emit:XTIROpLShr type:u res:nil operands:@[ use(x), imm(31) ]
                     predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* sgs = [self emit:XTIROpShl type:u res:nil operands:@[ use(sg), imm(e + m) ]
                      predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* r = [self emit:XTIROpOr type:u res:nil operands:@[ use(sgs), use(q2) ]
                    predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* isNan = [self emit:XTIROpICmp type:b res:nil operands:@[ use(a), imm(0x7F800000) ]
                        predicate:XTIRICmpUGT into:out block:bb at:at dbg:dbg];
    XTIRValue* nanv;
    if (kind == 0)
        {
        XTIRValue* top = [self emit:XTIROpAnd type:u res:nil operands:@[ use(hi), imm(mmax) ]
                          predicate:0 into:out block:bb at:at dbg:dbg];
        XTIRValue* qn = [self emit:XTIROpOr type:u res:nil operands:@[ use(top), imm(inf | (1u << (m - 1))) ]
                         predicate:0 into:out block:bb at:at dbg:dbg];
        nanv = [self emit:XTIROpOr type:u res:nil operands:@[ use(sgs), use(qn) ]
                predicate:0 into:out block:bb at:at dbg:dbg];
        }
    else if (kind == 1)
        nanv = [self emit:XTIROpOr type:u res:nil operands:@[ use(sgs), imm(all) ]
                predicate:0 into:out block:bb at:at dbg:dbg];
    else
        nanv = [self emit:XTIROpConst type:u res:nil operands:@[ imm(0) ]
                predicate:0 into:out block:bb at:at dbg:dbg];
    XTIRValue* sel = [self emit:XTIROpSelect type:u res:nil operands:@[ use(isNan), use(nanv), use(r) ]
                      predicate:0 into:out block:bb at:at dbg:dbg];
    [self emit:XTIROpTrunc type:[XTIRType u16Type] res:n.result operands:@[ use(sel) ]
     predicate:0 into:out block:bb at:at dbg:dbg];
    }

#pragma mark - Uses

- (NSCountedSet<NSNumber*>*)usesIn:(XTIRFunction*)fn
    {
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* n in all)
            for (XTIROperand* o in n.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
        }
    return uses;
    }

// Drops the listed values' definitions that nothing uses any more, and then
// theirs, as long as they are pure.
- (void)removeDead:(NSMutableArray<NSNumber*>*)work uses:(NSCountedSet<NSNumber*>*)uses
    {
    NSMutableSet<NSNumber*>* gone = [NSMutableSet set];
    while (work.count > 0)
        {
        NSNumber* v = work.lastObject;
        [work removeLastObject];
        if ([gone containsObject:v] || [uses countForObject:v] > 0)
            continue;
        XTIRInsn* d = self.defOf[v];
        if (!d || d.memoryResult)
            continue;
        XTIROpcode op = d.opcode;
        if (!(op == XTIROpConst || op == XTIROpFpExt || op == XTIROpZExt || op == XTIROpFAdd || op == XTIROpFSub
              || op == XTIROpFMul || op == XTIROpFDiv || op == XTIROpFSqrt))
            continue;
        for (XTIRBlock* bb in self.fn.blocks)
            {
            NSUInteger i = [bb.instructions indexOfObjectIdenticalTo:d];
            if (i == NSNotFound)
                continue;
            [bb.instructions removeObjectAtIndex:i];
            break;
            }
        [gone addObject:v];
        for (XTIROperand* o in d.operands)
            if (o.kind == XTIROperandKindUse)
                {
                [uses removeObject:@(o.valueId)];
                [work addObject:@(o.valueId)];
                }
        }
    }

// Can no use of the widened half v tell a quiet NaN from a signalling one?
// A comparison, a conversion (to f64, to an integer, back to a pack: each
// quiets or ignores the payload's top bit), a FloatPack call and the square
// root cannot; nor can an f32 operation on a target whose arithmetic picks
// between two NaN operands by position alone (x86-64), where arm64 prefers a
// signalling one.
- (BOOL)quietIsInvisible:(XTIRValue*)v profile:(XTIROptTargetProfile*)prof
    {
    for (XTIRBlock* bb in self.fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            for (XTIROperand* o in p.operands)
                if (o.kind == XTIROperandKindUse && o.valueId == v.valueId)
                    return NO;
        XTIRInsn* t = bb.terminator;
        if (t)
            for (XTIROperand* o in t.operands)
                if (o.kind == XTIROperandKindUse && o.valueId == v.valueId)
                    return NO;
        for (XTIRInsn* n in bb.instructions)
            {
            BOOL reads = NO;
            for (XTIROperand* o in n.operands)
                if (o.kind == XTIROperandKindUse && o.valueId == v.valueId)
                    reads = YES;
            if (!reads)
                continue;
            XTIROpcode op = n.opcode;
            if (op == XTIROpFCmp || op == XTIROpFpExt || op == XTIROpFpTrunc || op == XTIROpFpToSI
                || op == XTIROpFpToUI || op == XTIROpFSqrt)
                continue;
            if ((op == XTIROpFAdd || op == XTIROpFSub || op == XTIROpFMul || op == XTIROpFDiv)
                && !prof.packNaNPrecedence)
                continue;
            if (op == XTIROpCall && n.operands.count > 0 && n.operands[0].kind == XTIROperandKindSym
                && [[self.mod symbolForId:n.operands[0].symbolId].name hasPrefix:@"_xt_fpk_"])
                {
                // The half itself, never the memory token.
                BOOL asArg = NO;
                for (NSUInteger j = 1; j + 1 < n.operands.count; j++)
                    if (n.operands[j].kind == XTIROperandKindUse && n.operands[j].valueId == v.valueId)
                        asArg = YES;
                if (asArg)
                    continue;
                }
            return NO;
            }
        }
    return YES;
    }

// FloatPack widens a signalling NaN to a signalling f32 where the hardware
// makes it quiet: clear the quiet bit again for exactly the halves
// 0x7C01..0x7DFF of either sign. The widening takes a new value and the last
// instruction of the fix-up takes v, so every use sees the fixed f32.
- (void)keepSignalling:(XTIRValue*)v
    {
    XTIRInsn* w = self.defOf[@(v.valueId)];
    for (XTIRBlock* bb in self.fn.blocks)
        {
        NSUInteger i = [bb.instructions indexOfObjectIdenticalTo:w];
        if (i == NSNotFound)
            continue;
        XTIRDbgLoc* dbg = w.dbgLoc;
        XTIRType* u = [XTIRType u32Type];
        NSMutableArray<XTIRInsn*>* fix = [NSMutableArray array];
        XTIRValue* t = [self emit:XTIROpFpExt type:[XTIRType f32Type] res:nil operands:w.operands
                        predicate:0 into:fix block:bb at:i dbg:dbg];
        XTIRValue* z = [self emit:XTIROpZExt type:u res:nil operands:@[ w.operands[0] ]
                        predicate:0 into:fix block:bb at:i dbg:dbg];
        XTIROperand* cm = imm(0x7FFF);
        XTIRValue* mag = [self emit:XTIROpAnd type:u res:nil operands:@[ use(z), cm ]
                          predicate:0 into:fix block:bb at:i dbg:dbg];
        XTIROperand* cs = imm(0x7C01);
        XTIRValue* d = [self emit:XTIROpSub type:u res:nil operands:@[ use(mag), cs ]
                        predicate:0 into:fix block:bb at:i dbg:dbg];
        XTIROperand* cn = imm(0x1FF);
        XTIRValue* sig = [self emit:XTIROpICmp type:[XTIRType boolType] res:nil operands:@[ use(d), cn ]
                          predicate:XTIRICmpULT into:fix block:bb at:i dbg:dbg];
        XTIRValue* b = [self emit:XTIROpBitcast type:u res:nil operands:@[ use(t) ]
                        predicate:0 into:fix block:bb at:i dbg:dbg];
        XTIROperand* cq = imm(0xFFBFFFFF);
        XTIRValue* cl = [self emit:XTIROpAnd type:u res:nil operands:@[ use(b), cq ]
                         predicate:0 into:fix block:bb at:i dbg:dbg];
        XTIRValue* sel = [self emit:XTIROpSelect type:u res:nil operands:@[ use(sig), use(cl), use(b) ]
                          predicate:0 into:fix block:bb at:i dbg:dbg];
        [self emit:XTIROpBitcast type:[XTIRType f32Type] res:v operands:@[ use(sel) ]
         predicate:0 into:fix block:bb at:i dbg:dbg];
        [bb.instructions replaceObjectsInRange:NSMakeRange(i, 1) withObjectsFromArray:fix];
        return;
        }
    }

#pragma mark - Memory tokens

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
            {
            if (nt.result)
                self.defOf[@(nt.result.valueId)] = nt;
            list[i] = nt;
            }
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
    else if (XTIROpCarriesPredicate(insn.opcode))
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
