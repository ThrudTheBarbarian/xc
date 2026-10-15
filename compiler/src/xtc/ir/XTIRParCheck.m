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
#import "XTIRPrinter.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptTargetProfile.h"
#import "XTIROptInline.h"
#import "XTIROptRedundantLoadCSE.h"
#import "XTIROptIfConvert.h"
#import "XTIROptJumpThread.h"
#import "XTIROptDeadCode.h"
#import "XTIROptStrengthReduce.h"
#import "XTIROptConstOperandFold.h"
#import "XTIROptLICM.h"
#import "XTIROptBlockMerge.h"
#import "XTIROptLoopRotate.h"

@interface XTIROptPipeline (ParKernels)
- (instancetype)initAtLevel:(NSInteger)level;
@end
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
static BOOL gEmitsSPIRV = NO;
static BOOL gEmitsWGSL = NO;

+ (void)setEmitsMetal:(BOOL)on
    {
    gEmitsMetal = on;
    }

+ (void)setEmitsPTX:(BOOL)on
    {
    gEmitsPTX = on;
    }

+ (void)setEmitsWGSL:(BOOL)on
    {
    gEmitsWGSL = on;
    }

+ (void)setEmitsSPIRV:(BOOL)on
    {
    gEmitsSPIRV = on;
    }

// Each block's gpuSource() returns a placeholder literal, `__XC_PAR_MSL_<n>__`;
// give it the kernel's source for the target's GPU (Metal on macOS, PTX for
// NVIDIA on Windows), or "" when the block stays on the CPU.
/****************************************************************************\
|* The kernels as the optimiser leaves them (bug 645). A kernel is printed in
|* the front end, before the code generator's optimiser runs, so it got none
|* of it: mandelbrot's escape test computed x*x and y*y twice an iteration.
|* This is a copy of the module, by the IR's own print-and-parse round trip
|* (as XTIROptSimdClone takes its clones), cut down to the run functions and
|* what they call, with the passes that suit a kernel run over it: inlining,
|* CSE, if-conversion, jump threading, strength reduction, constant folding,
|* LICM, block merging, rotation and dead code. No vectorising, cloning or
|* unrolling. The module itself, and so the CPU path, is not touched. nil when
|* the round trip is not exact or a pass fails: the kernels print as before.
\****************************************************************************/
+ (nullable XTIRModule*)kernelModuleFrom:(XTIRModule*)module
    {
    NSString* printed = [XTIRPrinter stringFromModule:module];
    XTIRModule* copy = [XTIRParser moduleFromString:printed sharingLayoutsOf:module error:NULL];
    if (!copy || ![[XTIRPrinter stringFromModule:copy] isEqualToString:printed])
        return nil;
    NSMutableDictionary<NSString*, XTIRFunction*>* byName = [NSMutableDictionary dictionary];
    for (XTIRFunction* f in copy.functions)
        byName[f.name] = f;
    NSMutableArray<XTIRFunction*>* keep = [NSMutableArray array];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    NSMutableArray<XTIRFunction*>* work = [NSMutableArray array];
    for (XTIRFunction* f in copy.functions)
        if ([f.name hasPrefix:@"ParImpl$"] && [f.name hasSuffix:@"$run"])
            {
            [work addObject:f];
            [seen addObject:f.name];
            }
    if (!work.count)
        return nil;
    while (work.count)
        {
        XTIRFunction* f = work.lastObject;
        [work removeLastObject];
        [keep addObject:f];
        for (XTIRBlock* b in f.blocks)
            for (XTIRInsn* i in b.instructions)
                {
                if (i.opcode != XTIROpCall || !i.operands.count || i.operands[0].kind != XTIROperandKindSym)
                    continue;
                NSString* nm = [copy symbolForId:i.operands[0].symbolId].name;
                // Not the standard output library: no kernel calls it, and
                // its functions do not pass the verifier when run alone.
                if (nm && byName[nm] && ![seen containsObject:nm] && ![nm hasPrefix:@"Stdio$"])
                    {
                    [seen addObject:nm];
                    [work addObject:byName[nm]];
                    }
                }
        }
    [copy.functions setArray:keep];
    XTIROptTargetProfile* prof = [XTIRArm64TargetProfile new];
    XTIROptPipeline* p = [[XTIROptPipeline alloc] initAtLevel:3];
    XTIROptInline* inl = [XTIROptInline new];
    inl.profile = prof;
    [p addPass:inl];
    XTIROptRedundantLoadCSE* cse1 = [XTIROptRedundantLoadCSE new];
    cse1.crossBlock = YES;
    [p addPass:cse1];
    XTIROptIfConvert* ifc = [XTIROptIfConvert new];
    ifc.profile = prof;
    [p addPass:ifc];
    [p addPass:[XTIROptJumpThread new]];
    [p addPass:[XTIROptDeadCode new]];
    [p addPass:[XTIROptStrengthReduce new]];
    [p addPass:[XTIROptConstOperandFold new]];
    [p addPass:[XTIROptRedundantLoadCSE new]];
    XTIROptLICM* licm = [XTIROptLICM new];
    licm.profile = prof;
    [p addPass:licm];
    XTIROptRedundantLoadCSE* cse2 = [XTIROptRedundantLoadCSE new];
    cse2.crossBlock = YES;
    cse2.late = YES;
    [p addPass:cse2];
    [p addPass:[XTIROptBlockMerge new]];
    XTIROptLoopRotate* rot = [XTIROptLoopRotate new];
    rot.profile = prof;
    [p addPass:rot];
    [p addPass:[XTIROptDeadCode new]];
    if (![p runOnModule:copy errors:NULL])
        return nil;
    return copy;
    }

+ (void)fillSourcesIn:(XTIRModule*)module
              classDecls:(NSDictionary<NSString*, XTClassDeclNode*>*)classDecls
             diagnostics:(XTDiagnosticEngine*)diag
                  serial:(NSSet<NSString*>*)serial
    {
    XTIRModule* kmod = [self kernelModuleFrom:module];
    NSMutableDictionary<NSString*, XTIRFunction*>* kfns = [NSMutableDictionary dictionary];
    for (XTIRFunction* g in kmod.functions)
        kfns[g.name] = g;
    for (XTIRFunction* f in module.functions)
        {
        if (![f.name hasPrefix:@"ParImpl$"] || ![f.name hasSuffix:@"$run"])
            continue;
        // Each printer tries the optimised kernel first and the plain one if
        // that declines, so the optimiser never costs a block its GPU path.
        XTIRFunction* kf = kfns[f.name];
        NSString* n = [f.name substringWithRange:NSMakeRange(8, f.name.length - 12)];
        NSData* plain = [[NSString stringWithFormat:@"__XC_PAR_MSL_%@__", n] dataUsingEncoding:NSUTF8StringEncoding];
        NSData* fastTag = [[NSString stringWithFormat:@"__XC_PAR_FAST_%@__", n] dataUsingEncoding:NSUTF8StringEncoding];
        // Which placeholder the block has says whether its goal is speed.
        NSData* tag = plain;
        NSData* lit = nil;
        for (XTIRSymbol* sym in module.symbols)
            {
            NSData* b = sym.stringBytes;
            if (sym.kind != XTIRSymbolKindStringLit)
                continue;
            if (b.length >= fastTag.length && memcmp(b.bytes, fastTag.bytes, fastTag.length) == 0)
                {
                tag = fastTag;
                lit = b;
                }
            else if (b.length >= plain.length && memcmp(b.bytes, plain.bytes, plain.length) == 0)
                lit = b;
            }
        BOOL fast = tag == fastTag;
        // The block's reductions, after the tag: `<field>=<op>;` each (bug 645).
        NSMutableDictionary<NSNumber*, NSString*>* redOps = nil;
        NSUInteger litEnd = lit.length;
        while (litEnd > tag.length && ((const uint8_t*)lit.bytes)[litEnd - 1] == 0)
            litEnd--;
        if (litEnd > tag.length)
            {
            NSString* rest = [[NSString alloc] initWithBytes:(const char*)lit.bytes + tag.length
                                                      length:litEnd - tag.length
                                                    encoding:NSUTF8StringEncoding];
            redOps = [NSMutableDictionary dictionary];
            for (NSString* pair in [rest componentsSeparatedByString:@";"])
                {
                NSRange eq = [pair rangeOfString:@"="];
                if (eq.location == NSNotFound || eq.location == 0)
                    continue;
                redOps[@([pair substringToIndex:eq.location].integerValue)] = [pair substringFromIndex:eq.location + 1];
                }
            }
        // The buffers' footprints, as words on the header line every printer
        // writes (step 1 of par-tiles-and-devices.md).
        XTIRParCheck* fc = [XTIRParCheck new];
        fc.module = module;
        NSString* fcls = [f.name substringToIndex:f.name.length - 4];
        [XTIRParMSL setExtraMeta:[[fc footprintWordsIn:f ivarNames:[fc ivarNamesOf:classDecls[fcls] in:classDecls]]
                                   stringByAppendingString:[fc costWordsIn:f]]];
        NSString* (^ptxOf)(NSString* _Nullable* _Nullable) = ^NSString*(NSString* _Nullable* _Nullable w) {
            NSString* t = kf ? [XTIRParMSL ptxForKernel:kf module:kmod fast:fast redOps:redOps why:NULL] : nil;
            return t ?: [XTIRParMSL ptxForKernel:f module:module fast:fast redOps:redOps why:w];
        };
        NSData* (^spirvOf)(NSString* _Nullable* _Nullable) = ^NSData*(NSString* _Nullable* _Nullable w) {
            NSData* d = kf ? [XTIRParMSL spirvForKernel:kf module:kmod fast:fast redOps:redOps why:NULL] : nil;
            return d ?: [XTIRParMSL spirvForKernel:f module:module fast:fast redOps:redOps why:w];
        };
        NSString* (^metalOf)(NSString* _Nullable* _Nullable) = ^NSString*(NSString* _Nullable* _Nullable w) {
            NSString* t = kf ? [XTIRParMSL sourceForKernel:kf module:kmod fast:fast redOps:redOps why:NULL] : nil;
            return t ?: [XTIRParMSL sourceForKernel:f module:module fast:fast redOps:redOps why:w];
        };
        NSString* (^wgslOf)(NSString* _Nullable* _Nullable) = ^NSString*(NSString* _Nullable* _Nullable w) {
            NSString* t = kf ? [XTIRParMSL wgslForKernel:kf module:kmod fast:fast redOps:redOps why:NULL] : nil;
            return t ?: [XTIRParMSL wgslForKernel:f module:module fast:fast redOps:redOps why:w];
        };
        NSString* why = nil;
        NSData* kernel = nil;
        // The forms this target asked for (every one under -fpar-kernels=all,
        // so a worker on another machine finds its own: ParRemote.xc), in a
        // fixed order — the MSL, PTX and WGSL text sections, each ended by a
        // NUL with the next on a 4-byte boundary, and the SPIR-V module last.
        // Each header names its kind (`// xcpar ptx …`), and a runtime finds
        // its section by that (ParDevice.sectionOf). A block with no form at
        // all stays on the CPU, with the first printer's reason.
        NSString* mslWhy = nil;
        NSString* ptxWhy = nil;
        NSString* wgslWhy = nil;
        NSString* spvWhy = nil;
        // A demoted auto block gets the serial marker instead of a kernel:
        // Par.run then runs it on one thread, and no GPU sees it.
        BOOL serialBlock = [serial containsObject:fcls];
        NSString* msl = gEmitsMetal && !serialBlock ? metalOf(&mslWhy) : nil;
        NSString* ptx = gEmitsPTX && !serialBlock ? ptxOf(&ptxWhy) : nil;
        NSString* wgsl = gEmitsWGSL && !serialBlock ? wgslOf(&wgslWhy) : nil;
        NSData* spv = gEmitsSPIRV && !serialBlock ? spirvOf(&spvWhy) : nil;
        NSMutableData* all = [NSMutableData data];
        if (serialBlock)
            [all appendData:[@"// xcpar serial\n" dataUsingEncoding:NSUTF8StringEncoding]];
        uint8_t zero = 0;
        for (NSString* text in @[ msl ?: @"", ptx ?: @"", wgsl ?: @"" ])
            {
            if (!text.length)
                continue;
            while (all.length % 4)
                [all appendBytes:&zero length:1];
            [all appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
            [all appendBytes:&zero length:1];
            }
        if (spv)
            {
            while (all.length % 4)
                [all appendBytes:&zero length:1];
            [all appendData:spv];
            }
        if (all.length)
            kernel = all;
        else
            why = gEmitsMetal ? mslWhy : gEmitsPTX ? ptxWhy : gEmitsSPIRV ? spvWhy : wgslWhy;
        // XC_PAR_SPIRV_DUMP=<dir>: every block's SPIR-V module, on any target,
        // as <dir>/<block>.spv (for spirv-val), or <block>.why when it has none.
        const char* dump = getenv("XC_PAR_SPIRV_DUMP");
        if (dump && *dump)
            {
            NSString* dwhy = nil;
            NSData* d = gEmitsSPIRV ? spv : spirvOf(&dwhy);
            if (gEmitsSPIRV)
                dwhy = spvWhy;
            NSString* base = [[NSString stringWithUTF8String:dump] stringByAppendingPathComponent:n];
            if (d)
                {
                // The module alone: the words after the header line's NUL and padding.
                const uint8_t* b = d.bytes;
                NSUInteger at = 0;
                while (at < d.length && b[at])
                    at++;
                at = (at + 4) & ~(NSUInteger)3;
                [[d subdataWithRange:NSMakeRange(at, d.length - at)] writeToFile:[base stringByAppendingString:@".spv"]
                                                                       atomically:NO];
                }
            else
                [(dwhy ?: @"(no reason)") writeToFile:[base stringByAppendingString:@".why"] atomically:NO
                                             encoding:NSUTF8StringEncoding error:nil];
            }
        if (!kernel)
            {
            // On a target with a GPU, say why this block stays on the CPU.
            NSString* cls = [f.name substringToIndex:f.name.length - 4];
            [diag emitWarning:[NSString stringWithFormat:@"this 'par' block runs on the CPU only, because %@",
                                                         why ?: @"its GPU version cannot express something it uses yet"]
                     category:XTWarnParGpu
                           at:classDecls[cls].location];
            kernel = [NSData data];
            }
        for (XTIRSymbol* sym in module.symbols)
            {
            NSData* b = sym.stringBytes;
            if (sym.kind != XTIRSymbolKindStringLit || b.length < tag.length ||
                memcmp(b.bytes, tag.bytes, tag.length) != 0)
                continue;
            NSMutableData* nb = [kernel mutableCopy];
            // Keep the terminator the literal had — its trailing NULs only:
            // the reductions listed after the tag (bug 645) are not the kernel's.
            NSUInteger z = b.length;
            while (z > tag.length && ((const uint8_t*)b.bytes)[z - 1] == 0)
                z--;
            if (b.length > z)
                [nb appendBytes:(const uint8_t*)b.bytes + z length:b.length - z];
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
    // The auto blocks (--par-auto made them from plain loops) par-check would
    // refuse: demoted to a serial run instead, with a warning (par-auto).
    NSMutableSet<NSString*>* serial = [NSMutableSet set];
    for (XTIRFunction* f in module.functions)
        {
        if (![f.name hasPrefix:@"ParImpl$"] || ![f.name hasSuffix:@"$run"])
            continue;
        NSString* cls = [f.name substringToIndex:f.name.length - 4];
        BOOL isAuto = [self isAutoBlock:module number:[cls substringFromIndex:8]];
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
            if (isAuto)
                {
                [serial addObject:cls];
                [diag emitWarning:[NSString stringWithFormat:@"this loop runs serially, not as a 'par' block (--par-auto): "
                                                             @"its work items are not independent, since it %@", dep]
                         category:XTWarnParAuto
                               at:decl.location];
                continue;
                }
            ok = NO;
            [diag emitError:[NSString stringWithFormat:@"a 'par' block's work items must be independent, "
                                                       @"but this one %@", dep]
                         at:decl.location];
            continue;
            }
        if (isAuto)
            {
            [serial addObject:cls];
            [diag emitWarning:[NSString stringWithFormat:@"this loop runs serially, not as a 'par' block (--par-auto): "
                                                         @"a GPU could not run it, since it %@", why]
                     category:XTWarnParAuto
                           at:decl.location];
            continue;
            }
        ok = NO;
        NSString* msg = [NSString stringWithFormat:@"a 'par' block must be able to run on a GPU, "
                                                   @"but this one %@", why];
        [diag emitError:msg at:decl.location];
        }
    if (ok)
        [self fillSourcesIn:module classDecls:classDecls diagnostics:diag serial:serial];
    return ok;
    }

// Whether block <n> (its class ParImpl$<n>) is one --par-auto made from a
// plain loop: its GPU placeholder literal carries `auto;` after the tag.
+ (BOOL)isAutoBlock:(XTIRModule*)module number:(NSString*)n
    {
    NSData* plain = [[NSString stringWithFormat:@"__XC_PAR_MSL_%@__", n] dataUsingEncoding:NSUTF8StringEncoding];
    NSData* fastTag = [[NSString stringWithFormat:@"__XC_PAR_FAST_%@__", n] dataUsingEncoding:NSUTF8StringEncoding];
    for (XTIRSymbol* sym in module.symbols)
        {
        NSData* b = sym.stringBytes;
        if (sym.kind != XTIRSymbolKindStringLit)
            continue;
        NSData* tag = nil;
        if (b.length >= fastTag.length && memcmp(b.bytes, fastTag.bytes, fastTag.length) == 0)
            tag = fastTag;
        else if (b.length >= plain.length && memcmp(b.bytes, plain.bytes, plain.length) == 0)
            tag = plain;
        if (!tag)
            continue;
        NSString* rest = [[NSString alloc] initWithBytes:(const char*)b.bytes + tag.length
                                                  length:b.length - tag.length
                                                encoding:NSUTF8StringEncoding];
        return [rest hasPrefix:@"auto;"];
        }
    return NO;
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

// A `par :grid` block's index as a polynomial over its point and size: the
// atoms are i (the flat index), W and H (the par$w and par$h ivars), x (i % W),
// q (i / W), y ((i / W) % H) and z (i / (W*H)); a monomial is its atoms sorted
// and joined by '.', "" the constant. nil when the index is anything else.
- (nullable NSMutableDictionary<NSString*, NSNumber*>*)gridPoly:(XTIROperand*)op
                                                             iv:(XTIRValueId)iv
                                                           self:(XTIRValueId)selfId
                                                          ivars:(NSArray<NSString*>*)ivars
                                                           defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def
                                                          depth:(int)depth
    {
    if (depth > 32)
        return nil;
    if (op.kind == XTIROperandKindImmI)
        return [@{@"" : @(op.intValue)} mutableCopy];
    if (op.kind != XTIROperandKindUse)
        return nil;
    if (op.valueId == iv)
        return [@{@"i" : @1} mutableCopy];
    XTIRInsn* d = def[@(op.valueId)];
    if (!d || !d.operands.count)
        return nil;
    NSMutableDictionary<NSString*, NSNumber*>* (^sub)(NSUInteger) = ^NSMutableDictionary<NSString*, NSNumber*>*(NSUInteger k) {
      return k < d.operands.count ? [self gridPoly:d.operands[k] iv:iv self:selfId ivars:ivars defs:def depth:depth + 1]
                                  : nil;
    };
    BOOL (^isAtom)(NSDictionary*, NSString*) = ^BOOL(NSDictionary* p, NSString* a) {
      return p.count == 1 && [p[a] longLongValue] == 1;
    };
    switch (d.opcode)
        {
        case XTIROpConst:
            return d.operands[0].kind == XTIROperandKindImmI ? [@{@"" : @(d.operands[0].intValue)} mutableCopy] : nil;
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
        case XTIROpCopy:
            return sub(0);
        case XTIROpLoad:
            {
            // An ivar of the block's object: the grid's width or height.
            XTIRInsn* fa = d.operands[0].kind == XTIROperandKindUse ? def[@(d.operands[0].valueId)] : nil;
            if (fa.opcode != XTIROpFieldAddr || fa.operands.count < 2 || fa.operands[0].kind != XTIROperandKindUse
                || fa.operands[0].valueId != selfId || fa.operands[1].kind != XTIROperandKindImmI)
                return nil;
            int64_t k = fa.operands[1].intValue;
            NSString* n = (k >= 1 && (NSUInteger)k <= ivars.count) ? ivars[(NSUInteger)k - 1] : nil;
            if ([n isEqualToString:@"par$w"])
                return [@{@"W" : @1} mutableCopy];
            if ([n isEqualToString:@"par$h"])
                return [@{@"H" : @1} mutableCopy];
            return nil;
            }
        case XTIROpURem:
        case XTIROpUDiv:
            {
            NSDictionary* a = sub(0);
            NSDictionary* b = sub(1);
            if (!a || !b)
                return nil;
            if (d.opcode == XTIROpURem && isAtom(a, @"i") && isAtom(b, @"W"))
                return [@{@"x" : @1} mutableCopy];
            if (d.opcode == XTIROpURem && isAtom(a, @"q") && isAtom(b, @"H"))
                return [@{@"y" : @1} mutableCopy];
            if (d.opcode == XTIROpUDiv && isAtom(a, @"i") && isAtom(b, @"W"))
                return [@{@"q" : @1} mutableCopy];
            if (d.opcode == XTIROpUDiv && isAtom(a, @"i") && isAtom(b, @"H.W"))
                return [@{@"z" : @1} mutableCopy];
            return nil;
            }
        case XTIROpAdd:
        case XTIROpSub:
        case XTIROpMul:
            {
            NSDictionary<NSString*, NSNumber*>* a = sub(0);
            NSDictionary<NSString*, NSNumber*>* b = sub(1);
            if (!a || !b)
                return nil;
            NSMutableDictionary<NSString*, NSNumber*>* r = [NSMutableDictionary dictionary];
            if (d.opcode == XTIROpMul)
                {
                for (NSString* ma in a)
                    for (NSString* mb in b)
                        {
                        NSMutableArray* atoms = [NSMutableArray array];
                        if (ma.length)
                            [atoms addObjectsFromArray:[ma componentsSeparatedByString:@"."]];
                        if (mb.length)
                            [atoms addObjectsFromArray:[mb componentsSeparatedByString:@"."]];
                        NSString* m = [[atoms sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"."];
                        r[m] = @([r[m] longLongValue] + [a[ma] longLongValue] * [b[mb] longLongValue]);
                        }
                }
            else
                {
                for (NSString* m in a)
                    r[m] = a[m];
                int64_t sign = d.opcode == XTIROpSub ? -1 : 1;
                for (NSString* m in b)
                    r[m] = @([r[m] longLongValue] + sign * [b[m] longLongValue]);
                }
            for (NSString* m in r.allKeys)
                if ([r[m] longLongValue] == 0 && m.length)
                    [r removeObjectForKey:m];
            return r;
            }
        default:
            return nil;
        }
    }

// The index as k*i + c when its polynomial is k times the flat index of the
// point, plus a constant: i itself, or x + W*q, and x + W*y in a 2-D grid
// (y == q there) or x + W*y + W*H*z in a 3-D one (q == y + H*z). A block with
// a par$d ivar is 3-D.
- (XTParIndex)gridIndexOf:(XTIROperand*)op iv:(XTIRValueId)iv self:(XTIRValueId)selfId
                    ivars:(NSArray<NSString*>*)ivars defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def
    {
    XTParIndex no = { NO, 0, 0 };
    if (![ivars containsObject:@"par$w"])
        return no;
    NSMutableDictionary<NSString*, NSNumber*>* p = [self gridPoly:op iv:iv self:selfId ivars:ivars defs:def depth:0];
    if (!p)
        return no;
    int64_t c = [p[@""] longLongValue];
    [p removeObjectForKey:@""];
    BOOL threeD = [ivars containsObject:@"par$d"];
    NSArray<NSArray<NSString*>*>* forms = threeD ? @[ @[ @"i" ], @[ @"W.q", @"x" ], @[ @"H.W.z", @"W.y", @"x" ] ]
                                                 : @[ @[ @"i" ], @[ @"W.q", @"x" ], @[ @"W.y", @"x" ] ];
    for (NSArray<NSString*>* form in forms)
        {
        if (p.count != form.count)
            continue;
        int64_t k = [p[form[0]] longLongValue];
        BOOL match = k != 0;
        for (NSString* m in form)
            if ([p[m] longLongValue] != k)
                match = NO;
        if (match)
            return (XTParIndex){ YES, k, c };
        }
    return no;
    }

// Whether a read at r and a write at w (k*i + c each) can meet across two
// work items: the same element of the same item (r == w) is fine; otherwise
// k1*i1 + c1 == k2*i2 + c2 has an integer solution iff gcd(k1, k2) divides
// c2 - c1 (the GCD test), so `a[2*i]` written and `a[2*i + 1]` read are
// independent where equal strides with a nonzero offset are not. An index
// that is not affine in i is taken as able to meet anything.
static int64_t parGcd(int64_t a, int64_t b)
    {
    if (a < 0) a = -a;
    if (b < 0) b = -b;
    while (b != 0)
        {
        int64_t t = a % b;
        a = b;
        b = t;
        }
    return a;
    }

static BOOL parDependent(XTParIndex r, XTParIndex w)
    {
    if (!r.affine || !w.affine)
        return YES;
    if (r.k == w.k && r.c == w.c)
        return NO;
    int64_t g = parGcd(r.k, w.k);
    int64_t d = w.c - r.c;
    if (g == 0)
        return NO;
    return d % g == 0;
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

// The work item's index: the phi the loop's guard compares (not simply the
// first phi, which may be a reduction's accumulator). Mirrored in the port.
- (XTIRValueId)inductionVariableOf:(XTIRFunction*)f defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def first:(XTIRValueId)firstPhi
    {
    XTIRValueId iv = firstPhi;
    for (XTIRBlock* b in f.blocks)
        {
        BOOL done = NO;
        for (XTIRInsn* ci in b.instructions)
            {
            if (ci.opcode != XTIROpICmp)
                continue;
            for (XTIROperand* o in ci.operands)
                {
                if (o.kind != XTIROperandKindUse)
                    continue;
                XTIRInsn* dd = def[@(o.valueId)];
                if (dd && dd.opcode == XTIROpPhi)
                    {
                    iv = o.valueId;
                    done = YES;
                    break;
                    }
                }
            if (done)
                break;
            }
        if (done)
            break;
        }
    return iv;
    }

// Each buffer's footprint, for the runtime's header line: the elements work
// item i touches, as `fp=<captured-array>:<k>:<lo>:<hi>` (item i touches
// elements [k*i + lo, k*i + hi)) for a captured array and `gfp=<name>:…` for
// a global, when every access to it is affine in i with the same k. A
// buffer any access indexes from data, or at one element for every item,
// gets no word: the runtime treats it as all of it. A tile of the range can
// then move only its slice of each buffer (par-tiles-and-devices.md step 1).
- (NSString*)footprintWordsIn:(XTIRFunction*)f ivarNames:(NSArray<NSString*>*)ivars
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* def = [NSMutableDictionary dictionary];
    XTIRValueId firstPhi = 0;
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
                firstPhi = i.result.valueId;
                haveIV = YES;
                }
            }
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                def[@(i.result.valueId)] = i;
        }
    if (!haveIV || f.paramTypes.count == 0)
        return @"";
    XTIRValueId iv = [self inductionVariableOf:f defs:def first:firstPhi];
    XTIRValueId selfId = (XTIRValueId)0;
    // Per buffer: k, the lowest and highest c seen, and whether every access
    // was affine with that k.
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* fp = [NSMutableDictionary dictionary];
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
            if (!x.affine)
                x = [self gridIndexOf:ea.operands[1] iv:iv self:selfId ivars:ivars defs:def];
            NSMutableArray<NSNumber*>* e = fp[buf];
            if (!e)
                {
                e = [NSMutableArray arrayWithObjects:@(x.k), @(x.c), @(x.c), @(x.affine && x.k != 0), nil];
                fp[buf] = e;
                [order addObject:buf];
                continue;
                }
            if (!x.affine || x.k == 0 || x.k != e[0].longLongValue)
                e[3] = @NO;
            else
                {
                if (x.c < e[1].longLongValue)
                    e[1] = @(x.c);
                if (x.c > e[2].longLongValue)
                    e[2] = @(x.c);
                }
            }
        }
    NSMutableString* words = [NSMutableString string];
    for (NSString* buf in order)
        {
        NSArray<NSNumber*>* e = fp[buf];
        if (!e[3].boolValue)
            continue;
        NSUInteger at = [ivars indexOfObject:buf];
        // A captured array is ivar 2 + <index> (after lo and hi); a global
        // is named as the glob= word names it.
        if (at != NSNotFound && at >= 2)
            [words appendFormat:@" fp=%lu:%lld:%lld:%lld", (unsigned long)(at - 2), (long long)e[0].longLongValue,
                                (long long)e[1].longLongValue, (long long)(e[2].longLongValue + 1)];
        else if (at == NSNotFound)
            [words appendFormat:@" gfp=%@:%lld:%lld:%lld", buf, (long long)e[0].longLongValue,
                                (long long)e[1].longLongValue, (long long)(e[2].longLongValue + 1)];
        }
    return words;
    }

// The block's per-item cost, for par-auto's static classifier
// (par-auto-parallelisation.md): `ops=<n>` the compute-op count and `loop`
// when the body has an inner loop (a branch back to an earlier block). The
// runtime has bytes-per-item from the footprints, so intensity is ops/byte; a
// `loop` makes the item compute-heavy whatever the straight-line count. Mirrors
// the port's parCostWords exactly — the same IR and the same op set.
static BOOL parIsComputeOp(XTIROpcode op)
    {
    switch (op)
        {
        case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpUDiv:
        case XTIROpSDiv: case XTIROpURem: case XTIROpSRem: case XTIROpShl:
        case XTIROpLShr: case XTIROpAShr: case XTIROpAnd: case XTIROpOr:
        case XTIROpXor: case XTIROpNeg: case XTIROpNot: case XTIROpFAdd:
        case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv: case XTIROpFNeg:
        case XTIROpFSqrt: case XTIROpICmp: case XTIROpFCmp: case XTIROpSelect:
        case XTIROpSIToFp: case XTIROpUIToFp: case XTIROpFpToSI: case XTIROpFpToUI:
        case XTIROpFpExt: case XTIROpFpTrunc:
            return YES;
        default:
            return NO;
        }
    }
// The cost of f and of every function of the program it calls, once each
// (a kernel inlines its helpers, so their work is the item's work): ops
// summed, and `loop` when f has a nested loop (its outer parallel loop is
// one back edge, so a second is a nested one) or any helper has a loop at
// all (a helper has no outer loop of its own). A block whose work sat in a
// called helper counted as a few ops and no loop, and auto kept it off a
// discrete GPU as bandwidth-bound (par_pin_free). Intrinsics and runtime
// calls add nothing. Mirrors the port's parCostOf.
- (void)costOf:(XTIRFunction*)f
       visited:(NSMutableSet<NSString*>*)visited
           ops:(long long*)ops
          loop:(BOOL*)loop
           top:(BOOL)top
    {
    [visited addObject:f.name];
    long long backEdges = 0;
    NSArray<XTIRBlock*>* blocks = f.blocks;
    for (NSUInteger b = 0; b < blocks.count; b++)
        {
        XTIRBlock* bb = blocks[b];
        for (XTIRInsn* i in bb.instructions)
            {
            if (parIsComputeOp(i.opcode))
                (*ops)++;
            if ((i.opcode == XTIROpCall || i.opcode == XTIROpCallBanked || i.opcode == XTIROpCallCloaked) &&
                i.operands.count > 0 && i.operands[0].kind == XTIROperandKindSym)
                {
                XTIRSymbol* sym = [self.module symbolForId:i.operands[0].symbolId];
                XTIRFunction* callee = sym.name ? self.fnByName[sym.name] : nil;
                if (callee && ![visited containsObject:sym.name])
                    [self costOf:callee visited:visited ops:ops loop:loop top:NO];
                }
            }
        XTIRInsn* t = bb.terminator;
        if (t)
            for (XTIROperand* o in t.operands)
                {
                if (o.kind != XTIROperandKindBlock)
                    continue;
                for (NSUInteger j = 0; j < blocks.count; j++)
                    if (blocks[j] == o.blockRef && j <= b)
                        backEdges++;
                }
        }
    if (backEdges >= (top ? 2 : 1))
        *loop = YES;
    }

- (NSString*)costWordsIn:(XTIRFunction*)f
    {
    long long ops = 0;
    BOOL loop = NO;
    [self costOf:f visited:[NSMutableSet set] ops:&ops loop:&loop top:YES];
    NSMutableString* w = [NSMutableString stringWithFormat:@" ops=%lld", ops];
    if (loop)
        [w appendString:@" loop"];
    return w;
    }

// §4: a read of a buffer the block also writes must be at the element this
// work item writes. `b[i] = b[i - 1] + …` reads another item's result: that
// is a scan, not a par. Returns the complaint, or nil.
- (nullable NSString*)dependenceIn:(XTIRFunction*)f
                          ivarNames:(NSArray<NSString*>*)ivars
                            scatter:(NSString* _Nullable* _Nonnull)scatter
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* def = [NSMutableDictionary dictionary];
    XTIRValueId firstPhi = 0;
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
                firstPhi = i.result.valueId;
                haveIV = YES;
                }
            }
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                def[@(i.result.valueId)] = i;
        }
    if (!haveIV || f.paramTypes.count == 0)
        return nil;
    // The induction variable is the phi the loop's GUARD compares, not only
    // the first phi: a reduction's accumulator is a phi too, and a block with
    // reductions lists one of those first, so "the first phi" reads an
    // accumulator and every array the loop indexes looks data-indexed. An ICmp
    // taking a phi is the guard (or a min/max test, but the guard comes first
    // in block order); its phi operand is the iv. Mirrored in the port.
    XTIRValueId iv = [self inductionVariableOf:f defs:def first:firstPhi];
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
            if (!x.affine)
                x = [self gridIndexOf:ea.operands[1] iv:iv self:selfId ivars:ivars defs:def];
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
        BOOL dependent = NO;
        for (NSValue* wv in ws)
            {
            [wv getValue:&wx];
            if (parDependent(rx, wx))
                dependent = YES;
            }
        if (!dependent)
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
