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
    if (!prof.packF16Hardware && !prof.packBF16Inline)
        return YES;
    self.mod = mod;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn profile:prof];
    return YES;
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
            XTPackNativeType pk;
            XTPackCallKind k = [self kindOf:n pack:&pk];
            if (k == XTPackCallNone)
                continue;
            found = YES;
            if (k == XTPackCallUnpack && pk == XTPackNativeF16 && prof.packF16Hardware)
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
            XTPackNativeType pk;
            XTPackCallKind k = [self kindOf:n pack:&pk];
            BOOL rewrite = (pk == XTPackNativeBF16 && prof.packBF16Inline
                            && (k == XTPackCallUnpack || k == XTPackCallFromF32))
                        || (pk == XTPackNativeF16 && prof.packF16Hardware
                            && (k != XTPackCallFromF64 || prof.packF16FromF64));
            if (!rewrite)
                {
                // A comparison of two widened halves compares the halves.
                if (prof.packF16Arith && n.opcode == XTIROpFCmp && n.operands.count == 2
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
                if (prof.packF16Arith && d && [uses countForObject:@(src.valueId)] == 1)
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
        if (!(op == XTIROpConst || op == XTIROpFpExt || op == XTIROpFAdd || op == XTIROpFSub
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
