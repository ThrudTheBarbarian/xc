#import "XTIRParMSL.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

// Where a pointer value points: the thread's copy of the block object, or a
// device buffer (a captured array).
typedef NS_ENUM(uint8_t, XTParSpace) {
    XTParSpaceNone,
    XTParSpaceThread,
    XTParSpaceDevice,
};

@interface XTIRParMSL ()
@property(nonatomic) XTIRModule* module;
@property(nonatomic) XTIRFunction* fn;
@property(nonatomic) XTIRLayout* objLayout;
@property(nonatomic) NSMutableDictionary<NSNumber*, XTIRInsn*>* def;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* space;     // value -> XTParSpace
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* bufferOf;  // value -> field index
@property(nonatomic) NSMutableIndexSet* bufferFields;
@property(nonatomic) NSMutableIndexSet* reductionFields;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* blockIndex;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* ordinal; // value -> its name's number
@property(nonatomic) BOOL failed;
@end

static NSString* scalarName(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: return @"char";
        case XTIRTypeKindU8: return @"uchar";
        case XTIRTypeKindI16: return @"short";
        case XTIRTypeKindU16: return @"ushort";
        case XTIRTypeKindI32: return @"int";
        case XTIRTypeKindU32: return @"uint";
        case XTIRTypeKindI64: return @"long";
        case XTIRTypeKindU64: return @"ulong";
        case XTIRTypeKindF32: return @"float";
        case XTIRTypeKindBool: return @"bool";
        default: return nil; // f64 (refused on Metal, §7), aggregates, vectors
        }
    }

static NSString* signedName(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: return @"char";
        case XTIRTypeKindI16: case XTIRTypeKindU16: return @"short";
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"int";
        case XTIRTypeKindI64: case XTIRTypeKindU64: return @"long";
        default: return scalarName(t);
        }
    }

static NSString* unsignedName(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: return @"uchar";
        case XTIRTypeKindI16: case XTIRTypeKindU16: return @"ushort";
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"uint";
        case XTIRTypeKindI64: case XTIRTypeKindU64: return @"ulong";
        default: return scalarName(t);
        }
    }

@implementation XTIRParMSL

+ (nullable NSString*)sourceForKernel:(XTIRFunction*)run module:(XTIRModule*)module
    {
    XTIRParMSL* p = [XTIRParMSL new];
    p.module = module;
    p.fn = run;
    return [p print];
    }

- (nullable XTIRType*)typeOf:(XTIRValueId)v
    {
    return [self.fn valueForId:v].type;
    }

// Values are named by their order in the walk (each block's phis, then its
// instructions), not by id: the port numbers its values differently, and both
// compilers must print the same kernel.
- (NSString*)name:(XTIRValueId)v
    {
    return [NSString stringWithFormat:@"v%lu", (unsigned long)[self.ordinal[@(v)] unsignedIntegerValue]];
    }

// An operand as an MSL expression.
- (nullable NSString*)expr:(XTIROperand*)op type:(nullable XTIRType*)want
    {
    switch (op.kind)
        {
        case XTIROperandKindUse:
            return [self name:op.valueId];
        case XTIROperandKindImmI:
            {
            NSString* t = want ? scalarName(want) : @"long";
            if (!t)
                return nil;
            if (want.kind == XTIRTypeKindBool)
                return op.intValue ? @"true" : @"false";
            return [NSString stringWithFormat:@"%@(%lldL)", t, (long long)op.intValue];
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
            return [NSString stringWithFormat:@"as_type<float>(0x%08xu)", bits];
            }
        default:
            return nil;
        }
    }

- (nullable NSString*)pointerType:(XTIRType*)t space:(XTParSpace)s
    {
    if (t.kind != XTIRTypeKindPtr)
        return nil;
    NSString* inner = scalarName(t.pointeeType);
    if (!inner)
        return nil;
    return [NSString stringWithFormat:@"%@ %@*", s == XTParSpaceDevice ? @"device" : @"thread", inner];
    }

// The field of the block object an address names, when it is `FieldAddr self, #k`.
- (NSInteger)selfFieldOf:(XTIROperand*)op
    {
    if (op.kind != XTIROperandKindUse)
        return -1;
    XTIRInsn* d = self.def[@(op.valueId)];
    if (d.opcode != XTIROpFieldAddr || d.operands.count < 2 || d.operands[0].kind != XTIROperandKindUse ||
        d.operands[0].valueId != 0 || d.operands[1].kind != XTIROperandKindImmI)
        return -1;
    return (NSInteger)d.operands[1].intValue;
    }

// Classify every pointer value, and find the buffers and the reductions.
- (BOOL)analyse
    {
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            if (i.result)
                self.def[@(i.result.valueId)] = i;
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                self.def[@(i.result.valueId)] = i;
        }
    NSArray<XTIRLayoutField*>* fields = self.objLayout.fields;
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* i in b.instructions)
            {
            XTIRValueId r = i.result ? i.result.valueId : 0;
            switch (i.opcode)
                {
                case XTIROpFieldAddr:
                    {
                    NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:r]];
                    if (k >= 0)
                        {
                        if ((NSUInteger)k >= fields.count)
                            return NO;
                        self.space[@(r)] = @(XTParSpaceThread);
                        }
                    else if (i.operands.count && i.operands[0].kind == XTIROperandKindUse)
                        self.space[@(r)] = self.space[@(i.operands[0].valueId)] ?: @(XTParSpaceNone);
                    break;
                    }
                case XTIROpLoad:
                    {
                    if (i.result.type.kind != XTIRTypeKindPtr)
                        break;
                    // A pointer ivar of the block object: a captured array.
                    NSInteger k = [self selfFieldOf:i.operands[0]];
                    if (k <= 0)
                        return NO; // a pointer read from anywhere else
                    [self.bufferFields addIndex:(NSUInteger)k];
                    self.space[@(r)] = @(XTParSpaceDevice);
                    self.bufferOf[@(r)] = @(k);
                    break;
                    }
                case XTIROpElementAddr:
                case XTIROpBitcast:
                    if (i.result.type.kind == XTIRTypeKindPtr && i.operands.count &&
                        i.operands[0].kind == XTIROperandKindUse)
                        self.space[@(r)] = self.space[@(i.operands[0].valueId)] ?: @(XTParSpaceNone);
                    break;
                case XTIROpStore:
                    {
                    NSInteger k = [self selfFieldOf:i.operands[0]];
                    if (k > 2) // a write to the block object past lo/hi: a reduction
                        [self.reductionFields addIndex:(NSUInteger)k];
                    break;
                    }
                case XTIROpAddrOf:
                    return NO; // a global (or a function's address): not in this cut
                default:
                    break;
                }
            }
        }
    // Every pointer value needs a known space.
    for (NSNumber* v in self.def)
        {
        XTIRInsn* d = self.def[v];
        if (d.result.type.kind == XTIRTypeKindPtr && d.opcode != XTIROpPhi &&
            [self.space[v] unsignedIntegerValue] == XTParSpaceNone)
            return NO;
        }
    return YES;
    }

- (nullable NSString*)declOf:(XTIRValue*)v
    {
    XTIRType* t = v.type;
    if (t.kind == XTIRTypeKindMemory)
        return nil;
    if (t.kind == XTIRTypeKindPtr)
        {
        XTParSpace s = (XTParSpace)[self.space[@(v.valueId)] unsignedIntegerValue];
        NSString* pt = [self pointerType:t space:s == XTParSpaceNone ? XTParSpaceThread : s];
        return pt ? [NSString stringWithFormat:@"    %@ %@ = 0;\n", pt, [self name:v.valueId]] : @"";
        }
    NSString* n = scalarName(t);
    if (!n)
        {
        self.failed = YES;
        return @"";
        }
    return [NSString stringWithFormat:@"    %@ %@ = %@(0);\n", n, [self name:v.valueId], n];
    }

// Assign the phis of `target` for the edge from `from`, as a parallel copy.
- (NSString*)edgeFrom:(XTIRBlock*)from to:(XTIRBlock*)target indent:(NSString*)ind
    {
    NSMutableString* s = [NSMutableString string];
    NSMutableArray<NSString*>* tmps = [NSMutableArray array];
    NSUInteger n = 0;
    for (XTIRInsn* phi in target.phiNodes)
        {
        if (!phi.result || phi.result.type.kind == XTIRTypeKindMemory)
            continue;
        XTIROperand* in = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            if (phi.operands[k].blockRef == from)
                in = phi.operands[k + 1];
        if (!in)
            {
            self.failed = YES;
            return @"";
            }
        NSString* e = [self expr:in type:phi.result.type];
        NSString* d = [self declOf:phi.result];
        if (!e || !d.length)
            {
            self.failed = YES;
            return @"";
            }
        // `    T vN = T(0);` -> `T t<n> = <e>;`
        NSString* ty = [[d stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByString:@" v"][0];
        [s appendFormat:@"%@%@ t%lu = %@;\n", ind, ty, (unsigned long)n, e];
        [tmps addObject:[NSString stringWithFormat:@"%@%@ = t%lu;\n", ind, [self name:phi.result.valueId],
                                                   (unsigned long)n]];
        n++;
        }
    for (NSString* t in tmps)
        [s appendString:t];
    [s appendFormat:@"%@pc = %lu; continue;\n", ind,
                    (unsigned long)[self.blockIndex[target.name] unsignedIntegerValue]];
    return s;
    }

- (nullable NSString*)binary:(XTIRInsn*)i
    {
    XTIRType* t = i.result.type;
    NSString* a = [self expr:i.operands[0] type:t];
    NSString* b = [self expr:i.operands[1] type:t];
    if (!a || !b)
        return nil;
    NSString* n = scalarName(t);
    switch (i.opcode)
        {
        case XTIROpAdd: case XTIROpFAdd: return [NSString stringWithFormat:@"%@(%@ + %@)", n, a, b];
        case XTIROpSub: case XTIROpFSub: return [NSString stringWithFormat:@"%@(%@ - %@)", n, a, b];
        case XTIROpMul: case XTIROpFMul: return [NSString stringWithFormat:@"%@(%@ * %@)", n, a, b];
        case XTIROpFDiv: return [NSString stringWithFormat:@"%@(%@ / %@)", n, a, b];
        case XTIROpUDiv: return [NSString stringWithFormat:@"%@(%@(%@) / %@(%@))", n, unsignedName(t), a, unsignedName(t), b];
        case XTIROpURem: return [NSString stringWithFormat:@"%@(%@(%@) %% %@(%@))", n, unsignedName(t), a, unsignedName(t), b];
        case XTIROpSDiv: return [NSString stringWithFormat:@"%@(%@(%@) / %@(%@))", n, signedName(t), a, signedName(t), b];
        case XTIROpSRem: return [NSString stringWithFormat:@"%@(%@(%@) %% %@(%@))", n, signedName(t), a, signedName(t), b];
        case XTIROpAnd: return [NSString stringWithFormat:@"%@(%@ & %@)", n, a, b];
        case XTIROpOr: return [NSString stringWithFormat:@"%@(%@ | %@)", n, a, b];
        case XTIROpXor: return [NSString stringWithFormat:@"%@(%@ ^ %@)", n, a, b];
        case XTIROpShl: return [NSString stringWithFormat:@"%@(%@ << %@)", n, a, b];
        case XTIROpLShr: return [NSString stringWithFormat:@"%@(%@(%@) >> %@)", n, unsignedName(t), a, b];
        case XTIROpAShr: return [NSString stringWithFormat:@"%@(%@(%@) >> %@)", n, signedName(t), a, b];
        default: return nil;
        }
    }

- (nullable NSString*)compare:(XTIRInsn*)i
    {
    XTIRType* t = [self typeOf:i.operands[0].kind == XTIROperandKindUse ? i.operands[0].valueId
                                                                        : i.operands[1].valueId];
    if (!t)
        return nil;
    NSString* a = [self expr:i.operands[0] type:t];
    NSString* b = [self expr:i.operands[1] type:t];
    if (!a || !b)
        return nil;
    if (i.opcode == XTIROpFCmp)
        {
        static NSString* fops[] = { @"==", @"!=", @"<", @">", @"<=", @">=" };
        if (i.predicate > XTIRFCmpOGE)
            return nil;
        return [NSString stringWithFormat:@"(%@ %@ %@)", a, fops[i.predicate], b];
        }
    static NSString* iops[] = { @"==", @"!=", @"<", @">", @"<=", @">=", @"<", @">", @"<=", @">=" };
    if (i.predicate > XTIRICmpUGE)
        return nil;
    BOOL isSigned = (i.predicate >= XTIRICmpSLT && i.predicate <= XTIRICmpSGE);
    BOOL isUnsigned = (i.predicate >= XTIRICmpULT);
    NSString* cast = isSigned ? signedName(t) : isUnsigned ? unsignedName(t) : nil;
    if (cast && t.kind != XTIRTypeKindBool)
        return [NSString stringWithFormat:@"(%@(%@) %@ %@(%@))", cast, a, iops[i.predicate], cast, b];
    return [NSString stringWithFormat:@"(%@ %@ %@)", a, iops[i.predicate], b];
    }

// The maths intrinsics, by the callee's name, as precise Metal functions (§7).
static NSString* intrinsicFor(NSString* callee)
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
    NSDictionary<NSString*, NSString*>* map = @{
        @"sqrt" : @"precise::sqrt", @"sin" : @"precise::sin", @"cos" : @"precise::cos",
        @"exp" : @"precise::exp", @"ln" : @"precise::log", @"log" : @"precise::log",
        @"pow" : @"precise::pow", @"floor" : @"floor", @"fma" : @"fma", @"abs" : @"abs",
        @"fabs" : @"abs", @"min" : @"min", @"max" : @"max"
    };
    return map[m];
    }

- (nullable NSString*)statement:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    NSString* r = i.result ? [self name:i.result.valueId] : nil;
    switch (i.opcode)
        {
        case XTIROpConst:
            {
            NSString* e = [self expr:i.operands[0] type:rt];
            return e ? [NSString stringWithFormat:@"%@ = %@;", r, e] : nil;
            }
        case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpUDiv: case XTIROpSDiv:
        case XTIROpURem: case XTIROpSRem: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
        case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
        case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv:
            {
            NSString* e = [self binary:i];
            return e ? [NSString stringWithFormat:@"%@ = %@;", r, e] : nil;
            }
        case XTIROpNot:
            {
            NSString* a = [self expr:i.operands[0] type:rt];
            if (!a)
                return nil;
            return rt.kind == XTIRTypeKindBool ? [NSString stringWithFormat:@"%@ = !%@;", r, a]
                                               : [NSString stringWithFormat:@"%@ = %@(~%@);", r, scalarName(rt), a];
            }
        case XTIROpNeg:
        case XTIROpFNeg:
            {
            NSString* a = [self expr:i.operands[0] type:rt];
            return a ? [NSString stringWithFormat:@"%@ = %@(-%@);", r, scalarName(rt), a] : nil;
            }
        case XTIROpFSqrt:
            {
            NSString* a = [self expr:i.operands[0] type:rt];
            return a ? [NSString stringWithFormat:@"%@ = precise::sqrt(%@);", r, a] : nil;
            }
        case XTIROpICmp:
        case XTIROpFCmp:
            {
            NSString* e = [self compare:i];
            return e ? [NSString stringWithFormat:@"%@ = %@;", r, e] : nil;
            }
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
        case XTIROpSIToFp:
        case XTIROpUIToFp:
        case XTIROpFpToSI:
        case XTIROpFpToUI:
        case XTIROpCopy:
            {
            XTIRType* st = i.operands[0].kind == XTIROperandKindUse ? [self typeOf:i.operands[0].valueId] : rt;
            NSString* a = [self expr:i.operands[0] type:st];
            if (!a || !scalarName(rt))
                return nil;
            // Widen through the source's own signedness, as the CPU does.
            if (i.opcode == XTIROpZExt)
                a = [NSString stringWithFormat:@"%@(%@)", unsignedName(st), a];
            else if (i.opcode == XTIROpSExt)
                a = [NSString stringWithFormat:@"%@(%@)", signedName(st), a];
            return [NSString stringWithFormat:@"%@ = %@(%@);", r, scalarName(rt), a];
            }
        case XTIROpSelect:
            {
            NSString* c = [self expr:i.operands[0] type:nil];
            NSString* a = [self expr:i.operands[1] type:rt];
            NSString* b = [self expr:i.operands[2] type:rt];
            return (c && a && b) ? [NSString stringWithFormat:@"%@ = %@ ? %@ : %@;", r, c, a, b] : nil;
            }
        case XTIROpFieldAddr:
            {
            NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:i.result.valueId]];
            // The slot of a captured array: only ever loaded, and that load is
            // the buffer itself, so the slot's address needs no code.
            if (k >= 0 && self.objLayout.fields[(NSUInteger)k].type.kind == XTIRTypeKindPtr)
                return @"";
            XTParSpace s = (XTParSpace)[self.space[@(i.result.valueId)] unsignedIntegerValue];
            NSString* pt = [self pointerType:rt space:s];
            if (!pt)
                return nil;
            if (k >= 0)
                return [NSString stringWithFormat:@"%@ = (%@)(st + %u);", r, pt,
                                                  self.objLayout.fields[(NSUInteger)k].byteOffset];
            // A field of a struct element in a buffer: by its byte offset.
            XTIRType* bt = [self typeOf:i.operands[0].valueId];
            XTIRLayout* l = bt.pointeeType.layout;
            NSInteger f = (NSInteger)i.operands[1].intValue;
            if (!l || f < 0 || (NSUInteger)f >= l.fields.count)
                return nil;
            return [NSString stringWithFormat:@"%@ = (%@)((%@ uchar*)%@ + %u);", r, pt,
                                              s == XTParSpaceDevice ? @"device" : @"thread",
                                              [self name:i.operands[0].valueId], l.fields[(NSUInteger)f].byteOffset];
            }
        case XTIROpElementAddr:
            {
            NSString* idx = [self expr:i.operands[1] type:nil];
            return idx ? [NSString stringWithFormat:@"%@ = %@ + %@;", r, [self name:i.operands[0].valueId], idx] : nil;
            }
        case XTIROpBitcast:
            {
            XTParSpace s = (XTParSpace)[self.space[@(i.result.valueId)] unsignedIntegerValue];
            NSString* pt = rt.kind == XTIRTypeKindPtr ? [self pointerType:rt space:s] : scalarName(rt);
            return pt ? [NSString stringWithFormat:@"%@ = as_type<%@>(%@);", r, pt,
                                                   [self expr:i.operands[0] type:nil]] : nil;
            }
        case XTIROpLoad:
            {
            NSNumber* buf = self.bufferOf[@(i.result.valueId)];
            if (buf)
                return [NSString stringWithFormat:@"%@ = buf_%@;", r, buf];
            if (!scalarName(rt))
                return nil;
            return [NSString stringWithFormat:@"%@ = *%@;", r, [self name:i.operands[0].valueId]];
            }
        case XTIROpStore:
            {
            if (i.operands[0].kind != XTIROperandKindUse)
                return nil;
            XTIRType* pt = [self typeOf:i.operands[0].valueId];
            NSString* v = [self expr:i.operands[1] type:pt.pointeeType];
            return v ? [NSString stringWithFormat:@"*%@ = %@;", [self name:i.operands[0].valueId], v] : nil;
            }
        case XTIROpCall:
            {
            XTIRSymbol* sym = [self.module symbolForId:i.operands[0].symbolId];
            NSString* callee = sym.name;
            // The static-init machinery: the host has run it.
            if ([callee isEqualToString:@"_xtc_sinit_run"] || [callee hasSuffix:@"$init"])
                return @"";
            NSString* fn = intrinsicFor(callee);
            if (!fn || !rt || rt.kind == XTIRTypeKindMemory)
                return nil;
            NSMutableArray<NSString*>* args = [NSMutableArray array];
            for (NSUInteger k = 1; k < i.operands.count; k++)
                {
                XTIROperand* o = i.operands[k];
                if (o.kind == XTIROperandKindUse && [self typeOf:o.valueId].kind == XTIRTypeKindMemory)
                    continue;
                NSString* e = [self expr:o type:rt];
                if (!e)
                    return nil;
                [args addObject:e];
                }
            return [NSString stringWithFormat:@"%@ = %@(%@);", r, fn, [args componentsJoinedByString:@", "]];
            }
        case XTIROpDbgValue:
            return @"";
        default:
            return nil;
        }
    }

- (nullable NSString*)print
    {
    self.def = [NSMutableDictionary dictionary];
    self.space = [NSMutableDictionary dictionary];
    self.bufferOf = [NSMutableDictionary dictionary];
    self.bufferFields = [NSMutableIndexSet indexSet];
    self.reductionFields = [NSMutableIndexSet indexSet];
    self.blockIndex = [NSMutableDictionary dictionary];

    XTIRType* selfT = self.fn.paramTypes.count ? self.fn.paramTypes[0] : nil;
    self.objLayout = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    // lo and hi are ParChunk's two i64 ivars, fields 1 and 2 (field 0 is the vtable).
    if (!self.objLayout || self.objLayout.fields.count < 3 ||
        self.objLayout.fields[1].type.kind != XTIRTypeKindI64 || self.objLayout.fields[2].type.kind != XTIRTypeKindI64)
        return nil;
    if (![self analyse])
        return nil;

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

    NSMutableString* decls = [NSMutableString string];
    NSMutableString* body = [NSMutableString string];
    for (XTIRBlock* b in self.fn.blocks)
        {
        for (XTIRInsn* phi in b.phiNodes)
            if (phi.result && phi.result.type.kind != XTIRTypeKindMemory)
                {
                // A phi of pointers takes its incomings' space.
                if (phi.result.type.kind == XTIRTypeKindPtr)
                    for (NSUInteger k = 1; k < phi.operands.count; k += 2)
                        if (phi.operands[k].kind == XTIROperandKindUse && self.space[@(phi.operands[k].valueId)])
                            self.space[@(phi.result.valueId)] = self.space[@(phi.operands[k].valueId)];
                [decls appendString:[self declOf:phi.result]];
                }
        for (XTIRInsn* i in b.instructions)
            if (i.result && i.result.type.kind != XTIRTypeKindMemory)
                [decls appendString:[self declOf:i.result]];
        }
    if (self.failed)
        return nil;

    for (XTIRBlock* b in self.fn.blocks)
        {
        [body appendFormat:@"        case %lu: {\n", (unsigned long)[self.blockIndex[b.name] unsignedIntegerValue]];
        for (XTIRInsn* i in b.instructions)
            {
            NSString* s = [self statement:i];
            if (!s)
                return nil;
            if (s.length)
                [body appendFormat:@"            %@\n", s];
            }
        XTIRInsn* t = b.terminator;
        switch (t.opcode)
            {
            case XTIROpBranch:
                [body appendString:[self edgeFrom:b to:t.operands[0].blockRef indent:@"            "]];
                break;
            case XTIROpCondBranch:
                {
                NSString* c = [self expr:t.operands[0] type:nil];
                if (!c)
                    return nil;
                [body appendFormat:@"            if (%@) {\n", c];
                [body appendString:[self edgeFrom:b to:t.operands[1].blockRef indent:@"                "]];
                [body appendString:@"            }\n"];
                [body appendString:[self edgeFrom:b to:t.operands[2].blockRef indent:@"            "]];
                break;
                }
            case XTIROpReturn:
                [body appendString:@"            pc = 0xffffffffu; continue;\n"];
                break;
            default:
                return nil;
            }
        [body appendString:@"        }\n"];
        }
    if (self.failed)
        return nil;

    // The header line the runtime reads, and the kernel's parameters.
    NSArray<XTIRLayoutField*>* fl = self.objLayout.fields;
    NSMutableString* meta = [NSMutableString stringWithFormat:@"// xcpar size=%u lo=%u hi=%u", self.objLayout.size,
                                                              fl[1].byteOffset, fl[2].byteOffset];
    NSMutableString* params = [NSMutableString stringWithString:
        @"constant uchar* args [[buffer(0)]], constant long* span [[buffer(1)]]"];
    __block NSUInteger slot = 2;
    __block BOOL bad = NO;
    [self.bufferFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        NSString* et = scalarName(fl[k].type.pointeeType);
        if (!et)
            {
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" buf=%u:%lu:%u", fl[k].byteOffset, (unsigned long)(k - 3), fl[k].type.pointeeType.byteWidth];
        [params appendFormat:@", device %@* buf_%lu [[buffer(%lu)]]", et, (unsigned long)k, (unsigned long)slot++];
    }];
    NSMutableString* tail = [NSMutableString string];
    [self.reductionFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        NSString* et = scalarName(fl[k].type);
        if (!et)
            {
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" red=%u:%u", fl[k].byteOffset, fl[k].type.byteWidth];
        [params appendFormat:@", device %@* red_%lu [[buffer(%lu)]]", et, (unsigned long)k, (unsigned long)slot++];
        [tail appendFormat:@"    red_%lu[tid] = *(thread %@*)(st + %u);\n", (unsigned long)k, et, fl[k].byteOffset];
    }];
    if (bad)
        return nil;

    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"%@\n", meta];
    [out appendString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
    [out appendFormat:@"kernel void par_kernel(%@, uint tid [[thread_position_in_grid]])\n{\n", params];
    [out appendFormat:@"    thread uchar st[%u];\n", self.objLayout.size];
    [out appendFormat:@"    for (uint q = 0; q < %uu; q++) st[q] = args[q];\n", self.objLayout.size];
    [out appendString:@"    long lo = span[0] + long(tid) * span[2];\n"];
    [out appendString:@"    long hi = min(lo + span[2], span[1]);\n"];
    [out appendFormat:@"    *(thread long*)(st + %u) = lo;\n    *(thread long*)(st + %u) = hi;\n",
                      fl[1].byteOffset, fl[2].byteOffset];
    [out appendString:decls];
    [out appendString:@"    uint pc = 0;\n    while (lo < hi && pc != 0xffffffffu) {\n        switch (pc) {\n"];
    [out appendString:body];
    [out appendString:@"        default: pc = 0xffffffffu; continue;\n        }\n    }\n"];
    [out appendString:@"    if (lo >= span[1]) return;\n"];
    [out appendString:tail];
    [out appendString:@"}\n"];
    return out;
    }

@end
