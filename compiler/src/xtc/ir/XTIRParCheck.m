#import "XTIRParCheck.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRSymbol.h"
#import "XTDeclNodes.h"
#import "XTDiagnosticEngine.h"
#import "XTIRParMSL.h"

// What a kernel may call outside the program: the static-init once (the host
// has run it before any block starts), the bounds checks of a -fbounds-check
// build, block copies, and the maths every GPU has natively.
static NSSet<NSString*>* allowedExternals(void)
    {
    static NSSet<NSString*>* s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"_xtc_sinit_run", @"_xt_check_bounds", @"_xt_check_bounds_n",
            @"memcpy", @"memmove", @"memset",
            @"sqrt", @"sqrtf", @"sin", @"sinf", @"cos", @"cosf", @"exp", @"expf",
            @"log", @"logf", @"pow", @"powf", @"floor", @"floorf", @"fma", @"fmaf",
            @"fabs", @"fabsf", @"abs",
            @"_xm_sqrt", @"_xm_sqrtf", @"_xm_sin", @"_xm_sinf", @"_xm_cos", @"_xm_cosf",
            @"_xm_exp", @"_xm_expf", @"_xm_ln", @"_xm_lnf", @"_xm_pow", @"_xm_powf"
        ]];
    });
    return s;
    }

// The maths intrinsics (par-blocks.md §2), as Math's methods: allowed by name
// without looking inside, because each target implements them its own way (in
// assembly on the 6502 and the 68000) and a GPU has every one natively.
static BOOL isMathIntrinsic(NSString* irName)
    {
    if (![irName hasPrefix:@"Math$"])
        return NO;
    NSString* m = [irName substringFromIndex:5];
    NSRange r = [m rangeOfString:@"__"];
    if (r.location != NSNotFound)
        m = [m substringToIndex:r.location];
    static NSSet<NSString*>* ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = [NSSet setWithArray:@[ @"sqrt", @"sin", @"cos", @"exp", @"ln", @"pow", @"min", @"max",
                                    @"abs", @"floor", @"fma" ]];
    });
    return [ok containsObject:m];
    }

// `Stdio$printf` reads as `Stdio.printf`, and an overload's `__double` tail goes.
static NSString* shownName(NSString* irName)
    {
    NSRange r = [irName rangeOfString:@"__"];
    NSString* s = (r.location != NSNotFound && r.location > 0) ? [irName substringToIndex:r.location] : irName;
    return [s stringByReplacingOccurrencesOfString:@"$" withString:@"."];
    }

@interface XTIRParCheck ()
@property(nonatomic) XTIRModule* module;
@property(nonatomic) NSMutableDictionary<NSString*, XTIRFunction*>* fnByName;
@property(nonatomic) NSMutableSet<NSString*>* onStack;
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* verdict; // fn -> reason, @"" = clean
@end

@implementation XTIRParCheck

static BOOL gEmitsMetal = NO;
static BOOL gEmitsPTX = NO;

+ (void)setEmitsMetal:(BOOL)on
    {
    gEmitsMetal = on;
    }

+ (void)setEmitsPTX:(BOOL)on
    {
    gEmitsPTX = on;
    }

// Each block's gpuSource() returns a placeholder literal, `__XC_PAR_MSL_<n>__`;
// give it the kernel's source for the target's GPU (Metal on macOS, PTX for
// NVIDIA on Windows), or "" when the block stays on the CPU.
+ (void)fillSourcesIn:(XTIRModule*)module
    {
    for (XTIRFunction* f in module.functions)
        {
        if (![f.name hasPrefix:@"ParImpl$"] || ![f.name hasSuffix:@"$run"])
            continue;
        NSString* n = [f.name substringWithRange:NSMakeRange(8, f.name.length - 12)];
        NSData* plain = [[NSString stringWithFormat:@"__XC_PAR_MSL_%@__", n] dataUsingEncoding:NSUTF8StringEncoding];
        NSData* fastTag = [[NSString stringWithFormat:@"__XC_PAR_FAST_%@__", n] dataUsingEncoding:NSUTF8StringEncoding];
        // Which placeholder the block has says whether its goal is speed.
        NSData* tag = plain;
        for (XTIRSymbol* sym in module.symbols)
            {
            NSData* b = sym.stringBytes;
            if (sym.kind == XTIRSymbolKindStringLit && b.length >= fastTag.length &&
                memcmp(b.bytes, fastTag.bytes, fastTag.length) == 0)
                tag = fastTag;
            }
        BOOL fast = tag == fastTag;
        NSString* msl = gEmitsMetal ? ([XTIRParMSL sourceForKernel:f module:module fast:fast] ?: @"")
                      : gEmitsPTX   ? ([XTIRParMSL ptxForKernel:f module:module fast:fast] ?: @"")
                                    : @"";
        for (XTIRSymbol* sym in module.symbols)
            {
            NSData* b = sym.stringBytes;
            if (sym.kind != XTIRSymbolKindStringLit || b.length < tag.length ||
                memcmp(b.bytes, tag.bytes, tag.length) != 0)
                continue;
            NSMutableData* nb = [[msl dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            if (b.length > tag.length) // keep the terminator the literal had
                [nb appendBytes:(const uint8_t*)b.bytes + tag.length length:b.length - tag.length];
            [sym setValue:nb forKey:@"stringBytes"];
            }
        }
    }

+ (BOOL)checkModule:(XTIRModule*)module
         classDecls:(NSDictionary<NSString*, XTClassDeclNode*>*)classDecls
        diagnostics:(XTDiagnosticEngine*)diag
    {
    XTIRParCheck* c = [XTIRParCheck new];
    c.module = module;
    c.fnByName = [NSMutableDictionary dictionary];
    c.onStack = [NSMutableSet set];
    c.verdict = [NSMutableDictionary dictionary];
    for (XTIRFunction* f in module.functions)
        c.fnByName[f.name] = f;

    BOOL ok = YES;
    for (XTIRFunction* f in module.functions)
        {
        if (![f.name hasPrefix:@"ParImpl$"] || ![f.name hasSuffix:@"$run"])
            continue;
        NSString* cls = [f.name substringToIndex:f.name.length - 4];
        NSString* why = nil;
        // A captured class instance, String, Array, Map or block is an owned
        // ivar of the block's class, so its dealloc releases it.
        XTIRFunction* dealloc = c.fnByName[[cls stringByAppendingString:@"$dealloc"]];
        if (dealloc && [c releasesSomething:dealloc])
            why = @"captures an ARC'd value (a class instance, String, Array, Map or block); "
                  @"capture plain values, structs and sized arrays";
        if (!why)
            {
            NSString* r = [c reasonFor:f];
            if (r.length)
                why = r;
            }
        XTClassDeclNode* decl = classDecls[cls];
        if (!why)
            {
            // §4: the work items must not touch each other's data.
            NSString* scatter = nil;
            NSString* dep = [c dependenceIn:f ivarNames:[c ivarNamesOf:decl in:classDecls] scatter:&scatter];
            if (!dep)
                {
                if (scatter)
                    [diag emitWarning:[NSString stringWithFormat:@"a 'par' block writes %@, so the compiler "
                                                                 @"cannot prove two work items never write the "
                                                                 @"same element; if they can, the result depends "
                                                                 @"on which runs last", scatter]
                             category:XTWarnParScatter
                                   at:decl.location];
                continue;
                }
            ok = NO;
            [diag emitError:[NSString stringWithFormat:@"a 'par' block's work items must be independent, "
                                                       @"but this one %@", dep]
                         at:decl.location];
            continue;
            }
        ok = NO;
        NSString* msg = [NSString stringWithFormat:@"a 'par' block must be able to run on a GPU, "
                                                   @"but this one %@", why];
        [diag emitError:msg at:decl.location];
        }
    if (ok)
        [self fillSourcesIn:module];
    return ok;
    }

// The block class's ivars in field order (its parents' first), so field #k of
// the object is name k-1: field 0 is the object header.
- (NSArray<NSString*>*)ivarNamesOf:(XTClassDeclNode*)decl
                                in:(NSDictionary<NSString*, XTClassDeclNode*>*)classDecls
    {
    NSMutableArray<XTClassDeclNode*>* chain = [NSMutableArray array];
    for (XTClassDeclNode* d = decl; d; d = d.parentName ? classDecls[d.parentName] : nil)
        [chain insertObject:d atIndex:0];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (XTClassDeclNode* d in chain)
        for (XTVariableDeclNode* v in d.ivars)
            [names addObject:v.varName];
    return names;
    }

// A buffer access's address, `ElementAddr base, index`, split into the buffer
// (a captured array is a pointer ivar of the block's object; a global array is
// its symbol) and the index as k*i + c in the work item's index i.
typedef struct
    {
    BOOL affine;
    int64_t k, c;
    } XTParIndex;

- (XTParIndex)indexOf:(XTIROperand*)op iv:(XTIRValueId)iv defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def depth:(int)depth
    {
    XTParIndex no = { NO, 0, 0 };
    if (depth > 32)
        return no;
    if (op.kind == XTIROperandKindImmI)
        return (XTParIndex){ YES, 0, op.intValue };
    if (op.kind != XTIROperandKindUse)
        return no;
    if (op.valueId == iv)
        return (XTParIndex){ YES, 1, 0 };
    XTIRInsn* d = def[@(op.valueId)];
    if (!d)
        return no;
    switch (d.opcode)
        {
        case XTIROpConst:
            return d.operands.count && d.operands[0].kind == XTIROperandKindImmI
                       ? (XTParIndex){ YES, 0, d.operands[0].intValue }
                       : no;
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
        case XTIROpCopy:
            return d.operands.count ? [self indexOf:d.operands[0] iv:iv defs:def depth:depth + 1] : no;
        case XTIROpAdd:
        case XTIROpSub:
        case XTIROpMul:
            {
            if (d.operands.count < 2)
                return no;
            XTParIndex a = [self indexOf:d.operands[0] iv:iv defs:def depth:depth + 1];
            XTParIndex b = [self indexOf:d.operands[1] iv:iv defs:def depth:depth + 1];
            if (!a.affine || !b.affine)
                return no;
            if (d.opcode == XTIROpAdd)
                return (XTParIndex){ YES, a.k + b.k, a.c + b.c };
            if (d.opcode == XTIROpSub)
                return (XTParIndex){ YES, a.k - b.k, a.c - b.c };
            if (a.k == 0)
                return (XTParIndex){ YES, a.c * b.k, a.c * b.c };
            if (b.k == 0)
                return (XTParIndex){ YES, b.c * a.k, b.c * a.c };
            return no;
            }
        default:
            return no;
        }
    }

static NSString* shownIndex(XTParIndex x)
    {
    if (!x.affine)
        return @"an index computed from data";
    NSMutableString* s = [NSMutableString string];
    if (x.k == 1)
        [s appendString:@"i"];
    else if (x.k != 0)
        [s appendFormat:@"%lld*i", (long long)x.k];
    if (x.k == 0)
        [s appendFormat:@"%lld", (long long)x.c];
    else if (x.c > 0)
        [s appendFormat:@" + %lld", (long long)x.c];
    else if (x.c < 0)
        [s appendFormat:@" - %lld", (long long)-x.c];
    return [NSString stringWithFormat:@"[%@]", s];
    }

// The buffer an address indexes into, by name, or nil when it is not one.
- (nullable NSString*)bufferOf:(XTIROperand*)base self:(XTIRValueId)selfId ivars:(NSArray<NSString*>*)ivars
                          defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def
    {
    if (base.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = def[@(base.valueId)];
    if (d.opcode == XTIROpAddrOf && d.operands.count && d.operands[0].kind == XTIROperandKindSym)
        {
        XTIRSymbol* s = [self.module symbolForId:d.operands[0].symbolId];
        return s.kind == XTIRSymbolKindDataGlobal ? s.name : nil;
        }
    if (d.opcode != XTIROpLoad || !d.operands.count || d.operands[0].kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* fa = def[@(d.operands[0].valueId)];
    if (fa.opcode != XTIROpFieldAddr || fa.operands.count < 2 || fa.operands[0].kind != XTIROperandKindUse ||
        fa.operands[0].valueId != selfId || fa.operands[1].kind != XTIROperandKindImmI)
        return nil;
    int64_t k = fa.operands[1].intValue;
    return (k >= 1 && (NSUInteger)k <= ivars.count) ? ivars[(NSUInteger)k - 1] : nil;
    }

// §4: a read of a buffer the block also writes must be at the element this
// work item writes. `b[i] = b[i - 1] + …` reads another item's result: that
// is a scan, not a par. Returns the complaint, or nil.
- (nullable NSString*)dependenceIn:(XTIRFunction*)f
                          ivarNames:(NSArray<NSString*>*)ivars
                            scatter:(NSString* _Nullable* _Nonnull)scatter
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* def = [NSMutableDictionary dictionary];
    XTIRValueId iv = 0;
    BOOL haveIV = NO;
    for (XTIRBlock* b in f.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            {
            if (!i.result)
                continue;
            def[@(i.result.valueId)] = i;
            if (!haveIV)
                {
                iv = i.result.valueId; // the outer loop's counter: the first phi
                haveIV = YES;
                }
            }
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                def[@(i.result.valueId)] = i;
        }
    if (!haveIV || f.paramTypes.count == 0)
        return nil;
    XTIRValueId selfId = (XTIRValueId)0; // parameter n is value n; self is the first
    NSMutableDictionary<NSString*, NSMutableArray<NSValue*>*>* writes = [NSMutableDictionary dictionary];
    NSMutableArray<NSArray*>* reads = [NSMutableArray array]; // [buffer, NSValue(index)]
    for (XTIRBlock* b in f.blocks)
        {
        for (XTIRInsn* i in b.instructions)
            {
            BOOL isStore = (i.opcode == XTIROpStore || i.opcode == XTIROpStoreVolatile);
            BOOL isLoad = (i.opcode == XTIROpLoad || i.opcode == XTIROpLoadVolatile);
            if ((!isStore && !isLoad) || !i.operands.count || i.operands[0].kind != XTIROperandKindUse)
                continue;
            XTIRInsn* ea = def[@(i.operands[0].valueId)];
            if (ea.opcode != XTIROpElementAddr || ea.operands.count < 2)
                continue;
            NSString* buf = [self bufferOf:ea.operands[0] self:selfId ivars:ivars defs:def];
            if (!buf)
                continue;
            XTParIndex x = [self indexOf:ea.operands[1] iv:iv defs:def depth:0];
            NSValue* xv = [NSValue valueWithBytes:&x objCType:@encode(XTParIndex)];
            // §4: a write the shapes above do not cover (a scatter, or every
            // item writing one element) is legal but unprovable: a warning,
            // the first one per block.
            if (isStore && !*scatter && (!x.affine || x.k == 0))
                *scatter = x.affine
                               ? [NSString stringWithFormat:@"'%@%@' from every work item", shownName(buf), shownIndex(x)]
                               : [NSString stringWithFormat:@"'%@' at an index computed from data", shownName(buf)];
            if (isStore)
                {
                if (!writes[buf])
                    writes[buf] = [NSMutableArray array];
                [writes[buf] addObject:xv];
                }
            else
                [reads addObject:@[ buf, xv ]];
            }
        }
    for (NSArray* r in reads)
        {
        NSArray<NSValue*>* ws = writes[r[0]];
        if (!ws.count)
            continue;
        XTParIndex rx;
        [(NSValue*)r[1] getValue:&rx];
        XTParIndex wx = { NO, 0, 0 };
        BOOL same = NO;
        for (NSValue* wv in ws)
            {
            [wv getValue:&wx];
            if (rx.affine && wx.affine && rx.k == wx.k && rx.c == wx.c)
                same = YES;
            }
        if (same)
            continue;
        [ws[0] getValue:&wx];
        NSString* name = shownName(r[0]);
        return [NSString stringWithFormat:@"reads %@%@ while writing %@%@, so an item would read another "
                                          @"item's result; that is a scan, not a par",
                                          name, shownIndex(rx), name, shownIndex(wx)];
        }
    return nil;
    }

- (BOOL)releasesSomething:(XTIRFunction*)f
    {
    for (XTIRBlock* b in f.blocks)
        for (XTIRInsn* i in b.instructions)
            if (i.opcode == XTIROpRelease)
                return YES;
    return NO;
    }

// The first rule `f` breaks, directly or through a call, or @"".
- (NSString*)reasonFor:(XTIRFunction*)f
    {
    NSString* known = self.verdict[f.name];
    if (known)
        return known;
    [self.onStack addObject:f.name];
    NSString* why = [self scan:f];
    [self.onStack removeObject:f.name];
    self.verdict[f.name] = why;
    return why;
    }

- (NSString*)scan:(XTIRFunction*)f
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* def = [NSMutableDictionary dictionary];
    for (XTIRBlock* b in f.blocks)
        {
        for (XTIRInsn* i in b.phiNodes)
            if (i.result)
                def[@(i.result.valueId)] = i;
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                def[@(i.result.valueId)] = i;
        }
    for (XTIRBlock* b in f.blocks)
        {
        for (XTIRInsn* i in b.instructions)
            {
            switch (i.opcode)
                {
                case XTIROpRetain:
                case XTIROpRelease:
                case XTIROpAutorelease:
                case XTIROpWeakLoad:
                case XTIROpWeakRegister:
                case XTIROpWeakUnregister:
                    return @"uses an ARC'd value (a class instance, String, Array, Map or block)";
                case XTIROpCallIndirect:
                case XTIROpCallBankedIndirect:
                case XTIROpVTblDispatch:
                case XTIROpVTblLoad:
                case XTIROpProtoDispatch:
                case XTIROpProtoLoad:
                    return @"makes a dynamic call (a virtual or protocol call, a function pointer or a callback)";
                case XTIROpVaStart:
                case XTIROpVaArg:
                    return @"uses varargs";
                case XTIROpAsm:
                    return @"contains inline assembly";
                case XTIROpStore:
                case XTIROpStoreVolatile:
                case XTIROpAggStore:
                    {
                    NSString* g = [self globalWrittenBy:i defs:def];
                    // A class's static-init guard (inlined where there are no
                    // threads) is the host's business: it has run before any
                    // block starts.
                    if (g && ![g hasPrefix:@"__sinit_"])
                        return [NSString stringWithFormat:@"writes the global '%@' (a global can be "
                                                          @"read, and a global array written element by element)",
                                                          shownName(g)];
                    break;
                    }
                case XTIROpCall:
                case XTIROpCallBanked:
                case XTIROpCallCloaked:
                    {
                    if (i.operands.count == 0 || i.operands[0].kind != XTIROperandKindSym)
                        return @"makes a dynamic call (a virtual or protocol call, a function pointer or a callback)";
                    XTIRSymbol* sym = [self.module symbolForId:i.operands[0].symbolId];
                    NSString* name = sym.name;
                    if ([name isEqualToString:@"_xtc_alloc"] || [name hasPrefix:@"_xtc_new"])
                        return @"allocates on the heap ('new')";
                    if (isMathIntrinsic(name))
                        break;
                    // A class's static initialiser, behind its `__sinit_` guard:
                    // the host has run it before any block starts.
                    if ([name hasSuffix:@"$init"] &&
                        [self.module symbolForName:[@"__sinit_" stringByAppendingString:
                                                       [name substringToIndex:name.length - 5]]])
                        break;
                    XTIRFunction* callee = self.fnByName[name];
                    if (!callee)
                        {
                        if ([allowedExternals() containsObject:name])
                            break;
                        return [NSString stringWithFormat:@"calls '%@', which is outside the program "
                                                          @"and cannot run on a GPU", shownName(name)];
                        }
                    if ([self.onStack containsObject:name])
                        return [NSString stringWithFormat:@"calls '%@' recursively; a GPU has no call "
                                                          @"stack for recursion", shownName(name)];
                    NSString* r = [self reasonFor:callee];
                    if (r.length)
                        return [NSString stringWithFormat:@"calls '%@', which %@", shownName(name), r];
                    break;
                    }
                default:
                    break;
                }
            }
        }
    return @"";
    }

// The global a store writes, when its address is the global itself or a field
// of it. An element of a global ARRAY is a buffer write, which is allowed.
- (nullable NSString*)globalWrittenBy:(XTIRInsn*)store defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def
    {
    if (store.operands.count == 0 || store.operands[0].kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = def[@(store.operands[0].valueId)];
    for (int hops = 0; d && hops < 64; hops++)
        {
        if (d.opcode == XTIROpAddrOf)
            {
            if (d.operands.count && d.operands[0].kind == XTIROperandKindSym)
                {
                XTIRSymbol* s = [self.module symbolForId:d.operands[0].symbolId];
                if (s.kind == XTIRSymbolKindDataGlobal)
                    return s.name;
                }
            return nil;
            }
        if (d.opcode != XTIROpFieldAddr && d.opcode != XTIROpBitcast)
            return nil;
        if (d.operands.count == 0 || d.operands[0].kind != XTIROperandKindUse)
            return nil;
        d = def[@(d.operands[0].valueId)];
        }
    return nil;
    }

@end
