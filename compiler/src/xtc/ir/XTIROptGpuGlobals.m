#import "XTIROptGpuGlobals.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRSupport.h"
#import "XTIRSymbol.h"
#import "XTIRType.h"
#import "XTIRLayout.h"

// The size from which a numeric global array gets pages of its own (rt.c's
// threshold for a heap array), and the page it is aligned to (16 KB covers
// Apple silicon's pages as well as 4 KB ones).
#define GPU_GLOBAL_MIN 65536u
#define GPU_GLOBAL_PAGE 16384u

@implementation XTIROptGpuGlobals

- (NSString*)passName
    {
    return @"gpu-globals";
    }
- (NSInteger)minOptLevel
    {
    return 0;
    }

// A global's bytes when it is an array of a numeric type, else 0.
static uint32_t gpuGlobalBytes(XTIRType* ty)
    {
    if (ty == nil || ty.kind != XTIRTypeKindAgg || ty.layout == nil || !ty.layout.isArray)
        return 0;
    XTIRType* e = ty.layout.elementType;
    if (e == nil || !(XTIRTypeKindIsInteger(e.kind) || XTIRTypeKindIsFloating(e.kind)) || e.kind == XTIRTypeKindBool)
        return 0;
    return ty.layout.size;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    // The result is success, not "changed": nothing to do is a YES.
    BOOL ptr64 = [self.profile isKindOfClass:[XTIRArm64TargetProfile class]] ||
                 [self.profile isKindOfClass:[XTIRX86_64TargetProfile class]];
    // Defined exactly where the par runtime declares it (ParDevice's
    // parGlobals calls it on the registry's first use), once.
    NSString* fnName = @"__xt_gpu_globals";
    if (![mod symbolForName:fnName])
        return YES;
    for (XTIRFunction* f in mod.functions)
        if ([f.name isEqualToString:fnName])
            return YES;
    NSMutableArray<XTIRSymbol*>* regs = [NSMutableArray array];
    for (XTIRSymbol* sym in mod.symbols)
        {
        // An extern one is registered only when its definition was given pages
        // of its own too (the self-hosted C path marks it gpupage).
        // Elsewhere the function is defined, empty, since the runtime calls it.
        if (!ptr64 || sym.kind != XTIRSymbolKindDataGlobal || sym.volatileAccess || sym.taskLocal ||
            (sym.isExternalGlobal && ![sym.attributes[@"gpupage"] boolValue]))
            continue;
        if (gpuGlobalBytes(sym.globalType) < GPU_GLOBAL_MIN)
            continue;
        NSMutableDictionary* a = [sym.attributes mutableCopy] ?: [NSMutableDictionary dictionary];
        a[@"gpupage"] = @YES;
        sym.attributes = a;
        [regs addObject:sym];
        }
    NSString* rn = @"_xtc_simd_register";
    XTIRSymbol* rsym = [mod symbolForName:rn];
    if (!rsym && regs.count > 0)
        {
        rsym = [XTIRSymbol runtimeHelperWithName:rn
                                      clobberSet:[[XTIRClobberSet alloc] initWithClobberedNames:@[]]
                                        mayAlloc:NO
                                        mayThrow:NO];
        rsym.attributes = @{@"cloaked" : @NO, @"banked" : @NO, @"variadic" : @NO};
        [mod addSymbol:rsym];
        }
    XTIRSymbolId rid = rsym ? [mod.symbols indexOfObjectIdenticalTo:rsym] : 0;

    XTIRBlock* b = [[XTIRBlock alloc] init];
    b.name = @"bb_entry";
    XTIRFunction* fn = [[XTIRFunction alloc] initWithName:fnName
                                               returnType:[XTIRType voidType]
                                               paramTypes:@[ [XTIRType memoryType] ]
                                               entryBlock:b];
    XTIRValue* mem = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                   type:[XTIRType memoryType]
                                                defSite:[XTIRDefSite parameterDef]];
    [fn registerValue:mem];
    XTIRType* u8p = [XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked];
    for (XTIRSymbol* sym in regs)
        {
        XTIRSymbolId gid = [mod.symbols indexOfObjectIdenticalTo:sym];
        XTIRValue* a = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:u8p
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:b insnIndex:b.instructions.count]];
        [fn registerValue:a];
        [b.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAddrOf
                                                            result:a
                                                          operands:@[ [XTIROperand symWithSymbolId:gid] ]
                                                            dbgLoc:nil]];
        uint32_t padded = (gpuGlobalBytes(sym.globalType) + GPU_GLOBAL_PAGE - 1) & ~(GPU_GLOBAL_PAGE - 1);
        XTIRInsn* c = [[XTIRInsn alloc] initWithOpcode:XTIROpCall
                                                result:nil
                                              operands:@[ [XTIROperand symWithSymbolId:rid], [XTIROperand useWithValueId:a.valueId],
                                                          [XTIROperand immIWithType:[XTIRType u64Type] value:(int64_t)padded],
                                                          [XTIROperand useWithValueId:mem.valueId] ]
                                              callConv:[XTIRCallConv standard]
                                                dbgLoc:nil];
        mem = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                            type:[XTIRType memoryType]
                                         defSite:[[XTIRDefSite alloc] initWithBlock:b insnIndex:b.instructions.count]];
        [fn registerValue:mem];
        c.memoryResult = mem;
        [b.instructions addObject:c];
        }
    [b setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpReturn
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:mem.valueId] ]
                                               dbgLoc:nil]];
    [mod addFunction:fn];
    return YES;
    }

@end
