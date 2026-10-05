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
        if (!why)
            continue;
        ok = NO;
        XTClassDeclNode* decl = classDecls[cls];
        NSString* msg = [NSString stringWithFormat:@"a 'par' block must be able to run on a GPU, "
                                                   @"but this one %@", why];
        [diag emitError:msg at:decl.location];
        }
    return ok;
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
