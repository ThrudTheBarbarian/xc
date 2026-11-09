#import "XTIRParCheck.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
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
#import "XTIROptStaticInitGuard.h"
#import "XTIROptSqrtIntrinsic.h"
#import "XTIROptBlockMerge.h"
#import "XTIROptLoopRotate.h"
#import "XTIROptLoopUnrollVarTrip.h"

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
            @"_xtc_sinit_run", @"_xt_check_bounds", @"_xt_check_bounds_n", @"_xt_check_object",
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
    // A capture renamed for the block's own names (`__par_lo`) is shown as
    // the source spells it.
    if ([irName hasPrefix:@"__par_"] && irName.length > 6)
        irName = [irName substringFromIndex:6];
    NSRange r = [irName rangeOfString:@"__"];
    NSString* s = (r.location != NSNotFound && r.location > 0) ? [irName substringToIndex:r.location] : irName;
    return [s stringByReplacingOccurrencesOfString:@"$" withString:@"."];
    }

// A data global the block's kernel would name (glob=) that the block's
// gpuGlobal() cannot locate, or nil. That method knows only the globals the
// body names itself; one a helper uses arrives with the helper once the
// kernel's optimiser inlines it, and the run then refused the kernel ("a
// global the block cannot locate") with no warning at compile time.
// Compared as the run compares: the IR name against the method's string
// literals. The method is in the program's module (`module`); the kernel may
// be in the kernels' copy (`runModule`), which holds only what they need.
static NSString* _Nullable unlocatedGlobal(XTIRFunction* run, XTIRModule* runModule, XTIRModule* module, NSString* cls)
    {
    XTIRFunction* lookup = nil;
    NSString* want = [cls stringByAppendingString:@"$gpuGlobal"];
    for (XTIRFunction* g in module.functions)
        if ([g.name isEqualToString:want])
            lookup = g;
    if (!lookup)
        return nil;
    NSMutableSet<NSString*>* known = [NSMutableSet set];
    for (XTIRBlock* bb in lookup.blocks)
        for (XTIRInsn* i in bb.instructions)
            for (XTIROperand* op in i.operands)
                {
                XTIRSymbol* s = op.kind == XTIROperandKindSym ? [module symbolForId:op.symbolId] : nil;
                if (s.kind != XTIRSymbolKindStringLit)
                    continue;
                NSString* t = [[NSString alloc] initWithData:s.stringBytes ?: [NSData data] encoding:NSUTF8StringEncoding];
                while ([t hasSuffix:@"\0"])
                    t = [t substringToIndex:t.length - 1];
                if (t)
                    [known addObject:t];
                }
    for (XTIRBlock* bb in run.blocks)
        for (XTIRInsn* i in bb.instructions)
            {
            if (i.opcode != XTIROpAddrOf || !i.operands.count || i.operands[0].kind != XTIROperandKindSym)
                continue;
            XTIRSymbol* g = [runModule symbolForId:i.operands[0].symbolId];
            if (g.kind != XTIRSymbolKindDataGlobal || [g.name hasPrefix:@"__sinit_"] || [g.name hasPrefix:@"__sdata_"] ||
                [g.name hasSuffix:@"$init"])
                continue;
            if (![known containsObject:g.name])
                return g.name;
            }
    return nil;
    }

@interface XTIRParCheck ()
@property(nonatomic) XTIRModule* module;
@property(nonatomic) NSMutableDictionary<NSString*, XTIRFunction*>* fnByName;
@property(nonatomic) NSMutableSet<NSString*>* onStack;
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* verdict; // fn -> reason, @"" = clean
@end

// A grid's constant width and height for the block being checked (its
// placeholder's `gw=`/`gh=` words), read by readGridWords: below.
// An integer operand's value: an immediate, or a Const through any width
// changes. -1 when it is not one. As the port's parConstOperand.
static int64_t parConstOperand(XTIROperand* o, NSDictionary<NSNumber*, XTIRInsn*>* defs)
    {
    for (int depth = 0; depth < 8; depth++)
        {
        if (o.kind == XTIROperandKindImmI)
            return o.intValue;
        if (o.kind != XTIROperandKindUse)
            return -1;
        XTIRInsn* d = defs[@(o.valueId)];
        if (!d || d.operands.count != 1)
            return -1;
        if (d.opcode != XTIROpConst && d.opcode != XTIROpZExt && d.opcode != XTIROpSExt && d.opcode != XTIROpTrunc)
            return -1;
        o = d.operands[0];
        }
    return -1;
    }

// Every use of value `old` in fn becomes `to`.
static void parRewriteUses(XTIRFunction* fn, XTIRValueId old, XTIROperand* to)
    {
    void (^fix)(XTIRInsn*) = ^(XTIRInsn* n) {
      BOOL hit = NO;
      NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
      for (XTIROperand* o in n.operands)
          {
          BOOL use = o.kind == XTIROperandKindUse && o.valueId == old;
          hit = hit || use;
          [ops addObject:use ? to : o];
          }
      if (hit)
          [n replaceOperands:ops];
    };
    for (XTIRBlock* b in fn.blocks)
        {
        for (XTIRInsn* n in b.phiNodes)
            fix(n);
        for (XTIRInsn* n in b.instructions)
            fix(n);
        if (b.terminator)
            fix(b.terminator);
        }
    }

// Each `Par.kept(n)` the parser put at a lifted loop's site becomes the
// answer: true where block n stays a block, false where par-check demoted it,
// so the branch not taken is dead code and goes. The call's memory result is
// its memory input. As the port's parResolveKept.
static void parResolveKept(XTIRModule* module, NSSet<NSString*>* serial)
    {
    for (XTIRFunction* fn in module.functions)
        {
        NSMutableDictionary<NSNumber*, XTIRInsn*>* defs = nil;
        for (XTIRBlock* b in fn.blocks)
            for (NSUInteger i = 0; i < b.instructions.count; i++)
                {
                XTIRInsn* c = b.instructions[i];
                if (c.opcode != XTIROpCall || c.operands.count != 3 || c.operands[0].kind != XTIROperandKindSym)
                    continue;
                if (![[module symbolForId:c.operands[0].symbolId].name isEqualToString:@"Par$kept"])
                    continue;
                if (!defs)
                    {
                    defs = [NSMutableDictionary dictionary];
                    for (XTIRBlock* db in fn.blocks)
                        for (XTIRInsn* d in db.instructions)
                            if (d.result)
                                defs[@(d.result.valueId)] = d;
                    }
                int64_t n = parConstOperand(c.operands[1], defs);
                if (n < 0)
                    continue;
                BOOL keep = ![serial containsObject:[NSString stringWithFormat:@"ParImpl$%lld", n]];
                XTIRInsn* k = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                        result:c.result
                                                      operands:@[ [XTIROperand immIWithType:[XTIRType boolType] value:keep ? 1 : 0] ]
                                                        dbgLoc:c.dbgLoc];
                b.instructions[i] = k;
                if (c.result)
                    defs[@(c.result.valueId)] = k;
                if (c.memoryResult)
                    parRewriteUses(fn, c.memoryResult.valueId, c.operands[2]);
                }
        }
    }

static int64_t gParGridW = 0;
static int64_t gParGridH = 0;

/****************************************************************************\
|* Several trips of a GPU kernel's `while` per exit test (2026-11-01). A GPU
|* runs a group of lanes in step, and a loop whose lanes leave at different
|* trips (mandelbrot's escape test) pays for its per-lane control on every
|* trip: on the Pi 5's V3D some 25 of 33 instruction slots a trip. Here the
|* body is followed by trips-1 more trips, each the test and the body over
|* the values so far, a lane whose test fails keeping its values by a select:
|* the loop then tests once per `trips` trips and every lane ends with exactly
|* the values the plain loop gives it. Only a loop of one test block (phis and
|* pure work) and one body block, with no memory access or call in either: a
|* lane that has left still runs the copies. The kernel copy only; the CPU's
|* code is not touched. XTGPU_ESC_TRIPS=<n> sets the trips (1: off). As the
|* port's gpuEscapeTrips.
\****************************************************************************/
@interface XTIROptGpuEscapeTrips : NSObject <XTIROptPass>
@property(nonatomic) NSInteger trips;
// The functions whose loops it changed: a block's variant kernel is carried
// only when its run function is one of them.
@property(nonatomic, readonly) NSMutableSet<NSString*>* changed;
@end


@implementation XTIROptGpuEscapeTrips

- (instancetype)init
    {
    if ((self = [super init]))
        _changed = [NSMutableSet set];
    return self;
    }

- (NSString*)passName
    {
    return @"gpu-escape-trips";
    }

- (NSInteger)minOptLevel
    {
    return 0;
    }

static BOOL escTripsPure(XTIRInsn* i)
    {
    if (i.memoryResult)
        return NO;
    switch (i.opcode)
        {
    case XTIROpConst: case XTIROpCopy: case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpNeg:
    case XTIROpAnd: case XTIROpOr: case XTIROpXor: case XTIROpNot: case XTIROpShl: case XTIROpLShr:
    case XTIROpAShr: case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFNeg: case XTIROpICmp:
    case XTIROpFCmp: case XTIROpSelect: case XTIROpSExt: case XTIROpZExt: case XTIROpTrunc: case XTIROpBitcast:
    case XTIROpFpToSI: case XTIROpFpToUI: case XTIROpSIToFp: case XTIROpUIToFp: case XTIROpFpExt: case XTIROpFpTrunc:
        return YES;
    default:
        return NO;
        }
    }

static XTIROperand* escTripsMap(XTIROperand* o, NSDictionary<NSNumber*, NSNumber*>* m)
    {
    if (o.kind != XTIROperandKindUse)
        return o;
    NSNumber* n = m[@(o.valueId)];
    return n ? [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue] : o;
    }

static XTIRValue* escTripsVal(XTIRFunction* fn, XTIRType* t, XTIRBlock* b)
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                 type:t
                                              defSite:[[XTIRDefSite alloc] initWithBlock:b insnIndex:b.instructions.count]];
    [fn registerValue:v];
    return v;
    }

static void escTripsClone(XTIRInsn* i, XTIRBlock* B, XTIRFunction* fn, NSMutableDictionary<NSNumber*, NSNumber*>* m)
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
    for (XTIROperand* o in i.operands)
        [ops addObject:escTripsMap(o, m)];
    XTIRValue* r = i.result ? escTripsVal(fn, i.result.type, B) : nil;
    XTIRInsn* c = XTIROpCarriesPredicate(i.opcode)
                      ? [[XTIRInsn alloc] initWithOpcode:i.opcode result:r operands:ops predicate:i.predicate dbgLoc:i.dbgLoc]
                      : [[XTIRInsn alloc] initWithOpcode:i.opcode result:r operands:ops dbgLoc:i.dbgLoc];
    [B.instructions addObject:c];
    if (i.result)
        m[@(i.result.valueId)] = @(r.valueId);
    }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    NSInteger trips = self.trips;
    if (trips < 2)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        for (XTIRBlock* H in fn.blocks)
            {
            XTIRInsn* t = H.terminator;
            if (H.phiNodes.count == 0 || !t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
                continue;
            XTIRBlock* B = nil;
            for (NSUInteger k = 1; k <= 2; k++)
                {
                XTIRBlock* c = t.operands[k].blockRef;
                if (c && c != H && c.phiNodes.count == 0 && c.terminator && c.terminator.opcode == XTIROpBranch
                    && c.terminator.operands.count >= 1 && c.terminator.operands[0].blockRef == H)
                    B = c;
                }
            if (!B || t.operands[1].blockRef == t.operands[2].blockRef)
                continue;
            // B has H alone before it, and H is entered from one block besides B.
            NSUInteger toB = 0;
            for (XTIRBlock* b in fn.blocks)
                for (XTIROperand* o in b.terminator.operands)
                    if (o.kind == XTIROperandKindBlock && o.blockRef == B)
                        toB++;
            BOOL ok = toB == 1 && H.instructions.count + B.instructions.count <= 64;
            NSMutableArray<XTIROperand*>* back = [NSMutableArray array];
            for (XTIRInsn* p in H.phiNodes)
                {
                if (!ok)
                    break;
                if (!p.result || p.operands.count != 4 || p.result.type.kind == XTIRTypeKindMemory
                    || p.result.type.kind == XTIRTypeKindPtr)
                    {
                    ok = NO;
                    break;
                    }
                XTIROperand* bv = p.operands[0].blockRef == B ? p.operands[1] : p.operands[2].blockRef == B ? p.operands[3] : nil;
                if (!bv)
                    ok = NO;
                else
                    [back addObject:bv];
                }
            for (XTIRInsn* i in H.instructions)
                if (!escTripsPure(i))
                    ok = NO;
            for (XTIRInsn* i in B.instructions)
                if (!escTripsPure(i))
                    ok = NO;
            if (!ok || t.operands[0].kind != XTIROperandKindUse)
                continue;
            BOOL stayOnTrue = t.operands[1].blockRef == B;
            NSMutableArray<XTIROperand*>* cur = [back mutableCopy];
            NSArray<XTIRInsn*>* hIns = [H.instructions copy];
            NSArray<XTIRInsn*>* bIns = [B.instructions copy];
            for (NSInteger j = 1; j < trips; j++)
                {
                NSMutableDictionary<NSNumber*, NSNumber*>* m = [NSMutableDictionary dictionary];
                for (NSUInteger q = 0; q < H.phiNodes.count; q++)
                    if (cur[q].kind == XTIROperandKindUse)
                        m[@(H.phiNodes[q].result.valueId)] = @(cur[q].valueId);
                    // A constant on the back edge: the phi is that constant now.
                NSMutableDictionary<NSNumber*, XTIROperand*>* imm = [NSMutableDictionary dictionary];
                for (NSUInteger q = 0; q < H.phiNodes.count; q++)
                    if (cur[q].kind != XTIROperandKindUse)
                        imm[@(H.phiNodes[q].result.valueId)] = cur[q];
                if (imm.count)
                    break;
                for (XTIRInsn* i in hIns)
                    escTripsClone(i, B, fn, m);
                for (XTIRInsn* i in bIns)
                    escTripsClone(i, B, fn, m);
                XTIROperand* cond = escTripsMap(t.operands[0], m);
                for (NSUInteger q = 0; q < H.phiNodes.count; q++)
                    {
                    XTIROperand* nv = escTripsMap(back[q], m);
                    XTIROperand* yes = stayOnTrue ? nv : cur[q];
                    XTIROperand* no = stayOnTrue ? cur[q] : nv;
                    XTIRValue* r = escTripsVal(fn, H.phiNodes[q].result.type, B);
                    [B.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpSelect result:r
                                                                      operands:@[ cond, yes, no ] dbgLoc:nil]];
                    cur[q] = [XTIROperand useWithValueId:r.valueId];
                    }
                }
            for (NSUInteger q = 0; q < H.phiNodes.count; q++)
                {
                XTIRInsn* p = H.phiNodes[q];
                NSMutableArray<XTIROperand*>* ops = [p.operands mutableCopy];
                ops[p.operands[0].blockRef == B ? 1 : 3] = cur[q];
                [p replaceOperands:ops];
                }
            [_changed addObject:fn.name];
            }
    return YES;
    }

@end

/****************************************************************************\
|* Arrays of structs in a kernel copy (a global's, or a captured pointer's),
|* as the arrays of words they are in memory, so the printers hold them as any
|* array of numbers. The word is the struct's one number type when its fields
|* are all that type, packed; else a 32-bit word (16- or 8-bit when no field
|* is wider). Element i starts at word i * (size / word), and a field at byte
|* offset o is read from word o / word: a field of the word's width
|* reinterpreted, a narrower one shifted out of its word (and written back
|* into it with the bytes around it kept), an 8-byte one as two 32-bit words.
|* The host's layout is kept as it is, padding and nested structs included.
|* An array whose element or field addresses are used any other way stays as
|* it is, and the kernel declines it. As the port's parWordStructs, which
|* makes the same instructions in the same order.
\****************************************************************************/

// A number a struct's field may hold in a kernel's words.
static BOOL pwLeaf(XTIRType* t)
    {
    switch (t.kind)
        {
    case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindI16: case XTIRTypeKindU16:
    case XTIRTypeKindI32: case XTIRTypeKindU32: case XTIRTypeKindI64: case XTIRTypeKindU64:
    case XTIRTypeKindF32: case XTIRTypeKindF64: case XTIRTypeKindBool:
        return YES;
    default:
        return NO;
        }
    }

static uint32_t pwWidth(XTIRType* t)
    {
    switch (t.kind)
        {
    case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindBool: return 1;
    case XTIRTypeKindI16: case XTIRTypeKindU16: return 2;
    case XTIRTypeKindI32: case XTIRTypeKindU32: case XTIRTypeKindF32: return 4;
    default: return 8;
        }
    }

static BOOL pwSame(XTIRType* a, XTIRType* b)
    {
    return a.kind == b.kind && pwLeaf(a);
    }

// A struct type whose fields are all one number type, packed: that type (U32
// for a struct of mixed 4-byte numbers), else nil. As the port's parFlatField.
static XTIRType* _Nullable pwFlatField(XTIRType* t)
    {
    XTIRLayout* l = t.kind == XTIRTypeKindAgg ? t.layout : nil;
    if (!l || !l.fieldCount)
        return nil;
    XTIRType* ft = [l fieldTypeAt:0];
    uint32_t w = pwWidth(ft);
    if (!pwLeaf(ft) || ft.kind == XTIRTypeKindF64 || l.size != w * l.fieldCount)
        return nil;
    BOOL mixed = NO;
    for (NSUInteger k = 0; k < l.fieldCount; k++)
        {
        XTIRType* fk = [l fieldTypeAt:k];
        if ([l fieldOffsetAt:k] != w * k)
            return nil;
        if (!pwSame(fk, ft))
            {
            if (w != 4 || pwWidth(fk) != 4 || !pwLeaf(fk) || fk.kind == XTIRTypeKindF64 || fk.kind == XTIRTypeKindBool)
                return nil;
            mixed = YES;
            }
        }
    if (mixed)
        return ft.kind == XTIRTypeKindBool ? nil : [XTIRType u32Type];
    return ft;
    }

// The widest number in t (a number, or a struct or array of them), 0 when it
// holds anything else.
static uint32_t pwLeafWidth(XTIRType* t, unsigned depth)
    {
    if (!t || depth > 8)
        return 0;
    if (pwLeaf(t))
        return pwWidth(t);
    XTIRLayout* l = t.kind == XTIRTypeKindAgg ? t.layout : nil;
    if (!l || !l.fieldCount)
        return 0;
    if (l.isArray)
        return pwLeafWidth(l.elementType, depth + 1);
    uint32_t mw = 0;
    for (NSUInteger k = 0; k < l.fieldCount; k++)
        {
        uint32_t w = pwLeafWidth([l fieldTypeAt:k], depth + 1);
        if (!w)
            return 0;
        if (w > mw)
            mw = w;
        }
    return mw;
    }

XTIRType* _Nullable XTParWordOf(XTIRType* _Nullable t)
    {
    if (!t)
        return nil;
    XTIRType* fe = pwFlatField(t);
    if (fe)
        return fe;
    XTIRLayout* l = t.kind == XTIRTypeKindAgg ? t.layout : nil;
    if (!l || l.isArray || !l.fieldCount)
        return nil;
    uint32_t mw = pwLeafWidth(t, 0);
    if (!mw)
        return nil;
    uint32_t w = mw > 4 ? 4 : mw;
    if (l.size % w)
        return nil;
    return w == 4 ? [XTIRType u32Type] : w == 2 ? [XTIRType u16Type] : [XTIRType u8Type];
    }

// Whether a word of type wt holds a field of type t at byte offset off.
static BOOL pwHolds(XTIRType* wt, XTIRType* t, uint32_t off)
    {
    if (!pwLeaf(t))
        return NO;
    uint32_t w = pwWidth(t);
    uint32_t ww = pwWidth(wt);
    if (off % w)
        return NO;
    if (w <= ww)
        return off % ww + w <= ww;
    return w == 8 && ww == 4;
    }

static XTIRType* pwPtr(XTIRType* p, XTIRType* to)
    {
    return [XTIRType ptrToType:to window:p.windowId];
    }

static XTIRValue* pwNew(XTIRFunction* fn, XTIRType* t, XTIRBlock* b)
    {
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                 type:t
                                              defSite:[[XTIRDefSite alloc] initWithBlock:b insnIndex:b.instructions.count]];
    [fn registerValue:v];
    return v;
    }

// The same value with another type.
static XTIRValue* pwRetyped(XTIRFunction* fn, XTIRValue* v, XTIRType* t)
    {
    XTIRValue* n = [[XTIRValue alloc] initWithValueId:v.valueId type:t defSite:v.defSite];
    fn.values[@(v.valueId)] = n;
    return n;
    }

static XTIRInsn* pwOp(XTIROpcode op, XTIRValue* _Nullable res, NSArray<XTIROperand*>* ops)
    {
    return [[XTIRInsn alloc] initWithOpcode:op result:res operands:ops dbgLoc:nil];
    }

// insn with another result (and the same operands, unless ops is given).
static XTIRInsn* pwRebuilt(XTIRInsn* i, XTIRValue* _Nullable res, NSArray<XTIROperand*>* _Nullable ops)
    {
    NSArray<XTIROperand*>* o = ops ?: i.operands;
    XTIRInsn* n = XTIROpCarriesPredicate(i.opcode)
                      ? [[XTIRInsn alloc] initWithOpcode:i.opcode result:res operands:o predicate:i.predicate dbgLoc:i.dbgLoc]
                      : [[XTIRInsn alloc] initWithOpcode:i.opcode result:res operands:o dbgLoc:i.dbgLoc];
    n.memoryResult = i.memoryResult;
    return n;
    }

static XTIROperand* pwUse(XTIRValue* v)
    {
    return [XTIROperand useWithValueId:v.valueId];
    }

static XTIROperand* pwImm(int64_t v, XTIRType* t)
    {
    return [XTIROperand immIWithType:t value:v];
    }

// A stored value as a value of type t: a constant gets its own Const before
// instructions[*at].
static XTIROperand* pwValue(XTIRFunction* fn, XTIRBlock* bb, NSUInteger* at, XTIROperand* v, XTIRType* t)
    {
    if (v.kind == XTIROperandKindUse)
        return v;
    XTIRValue* c = pwNew(fn, t, bb);
    [bb.instructions insertObject:pwOp(XTIROpConst, c, @[ v ]) atIndex:*at];
    *at = *at + 1;
    return pwUse(c);
    }

// A load or store at instructions[i] of a field of type t, `off` bytes into
// the element at `root`, through words of type wt: the instructions that do it
// in words. The index after them.
static NSUInteger pwAccess(XTIRFunction* fn, XTIRBlock* bb, NSUInteger i, XTIRInsn* ip, XTIRType* t, uint32_t off,
                           XTIRType* wt, XTIRValueId root)
    {
    uint32_t w = pwWidth(t);
    uint32_t ww = pwWidth(wt);
    BOOL load = ip.opcode == XTIROpLoad;
    XTIRType* u32 = [XTIRType u32Type];
    XTIRType* u64 = [XTIRType u64Type];
    XTIRType* mem = [XTIRType memoryType];
    if (w == ww && t.kind != XTIRTypeKindBool)
        {
        if (pwSame(t, wt))
            return i + 1;
        if (load)
            {
            XTIRValue* orig = ip.result;
            XTIRValue* word = pwNew(fn, wt, bb);
            bb.instructions[i] = pwRebuilt(ip, word, nil);
            [bb.instructions insertObject:pwOp(XTIROpBitcast, orig, @[ pwUse(word) ]) atIndex:i + 1];
            return i + 2;
            }
        XTIROperand* v = pwValue(fn, bb, &i, ip.operands[1], t);
        XTIRValue* word = pwNew(fn, wt, bb);
        [bb.instructions insertObject:pwOp(XTIROpBitcast, word, @[ v ]) atIndex:i];
        NSMutableArray<XTIROperand*>* ops = [ip.operands mutableCopy];
        ops[1] = pwUse(word);
        [ip replaceOperands:ops];
        return i + 2;
        }
    XTIROperand* addr = ip.operands[0];
    XTIROperand* memIn = ip.operands[load ? 1 : 2];
    if (w == 8)
        {
        // Two 32-bit words, the low one first.
        XTIRValue* a2 = pwNew(fn, pwPtr([fn valueForId:addr.valueId].type, u32), bb);
        [bb.instructions insertObject:pwOp(XTIROpElementAddr, a2, @[ [XTIROperand useWithValueId:root], pwImm(off / 4 + 1, u32) ])
                              atIndex:i];
        i++;
        XTIRValue* m1 = pwNew(fn, mem, bb);
        if (load)
            {
            XTIRValue* orig = ip.result;
            XTIRValue* lo = pwNew(fn, u32, bb);
            XTIRInsn* l1 = pwOp(XTIROpLoad, lo, @[ addr, memIn ]);
            l1.memoryResult = m1;
            [bb.instructions insertObject:l1 atIndex:i];
            i++;
            XTIRValue* hi = pwNew(fn, u32, bb);
            bb.instructions[i] = pwRebuilt(ip, hi, @[ pwUse(a2), pwUse(m1) ]);
            i++;
            XTIRValue* zl = pwNew(fn, u64, bb);
            XTIRValue* zh = pwNew(fn, u64, bb);
            XTIRValue* sh = pwNew(fn, u64, bb);
            XTIRValue* both = t.kind == XTIRTypeKindU64 ? orig : pwNew(fn, u64, bb);
            [bb.instructions insertObject:pwOp(XTIROpZExt, zl, @[ pwUse(lo) ]) atIndex:i];
            [bb.instructions insertObject:pwOp(XTIROpZExt, zh, @[ pwUse(hi) ]) atIndex:i + 1];
            [bb.instructions insertObject:pwOp(XTIROpShl, sh, @[ pwUse(zh), pwImm(32, u64) ]) atIndex:i + 2];
            [bb.instructions insertObject:pwOp(XTIROpOr, both, @[ pwUse(zl), pwUse(sh) ]) atIndex:i + 3];
            i += 4;
            if (both != orig)
                {
                [bb.instructions insertObject:pwOp(XTIROpBitcast, orig, @[ pwUse(both) ]) atIndex:i];
                i++;
                }
            return i;
            }
        XTIROperand* v = pwValue(fn, bb, &i, ip.operands[1], t);
        if (t.kind != XTIRTypeKindU64)
            {
            XTIRValue* u = pwNew(fn, u64, bb);
            [bb.instructions insertObject:pwOp(XTIROpBitcast, u, @[ v ]) atIndex:i];
            i++;
            v = pwUse(u);
            }
        XTIRValue* lo = pwNew(fn, u32, bb);
        XTIRValue* s = pwNew(fn, u64, bb);
        XTIRValue* hi = pwNew(fn, u32, bb);
        [bb.instructions insertObject:pwOp(XTIROpTrunc, lo, @[ v ]) atIndex:i];
        [bb.instructions insertObject:pwOp(XTIROpLShr, s, @[ v, pwImm(32, u64) ]) atIndex:i + 1];
        [bb.instructions insertObject:pwOp(XTIROpTrunc, hi, @[ pwUse(s) ]) atIndex:i + 2];
        i += 3;
        XTIRInsn* s1 = pwOp(XTIROpStore, nil, @[ addr, pwUse(lo), memIn ]);
        s1.memoryResult = m1;
        [bb.instructions insertObject:s1 atIndex:i];
        i++;
        [ip replaceOperands:@[ pwUse(a2), pwUse(hi), pwUse(m1) ]];
        return i + 1;
        }
    // A narrower field: its bits in the word.
    uint32_t shift = (off % ww) * 8;
    int64_t mask = ((int64_t)1 << (w * 8)) - 1;
    if (load)
        {
        XTIRValue* orig = ip.result;
        XTIRValue* word = pwNew(fn, wt, bb);
        bb.instructions[i] = pwRebuilt(ip, word, nil);
        i++;
        XTIROperand* x = pwUse(word);
        if (shift)
            {
            XTIRValue* sv = pwNew(fn, wt, bb);
            [bb.instructions insertObject:pwOp(XTIROpLShr, sv, @[ x, pwImm(shift, wt) ]) atIndex:i];
            i++;
            x = pwUse(sv);
            }
        if (t.kind == XTIRTypeKindBool)
            {
            XTIRValue* bv = pwNew(fn, wt, bb);
            [bb.instructions insertObject:pwOp(XTIROpAnd, bv, @[ x, pwImm(mask, wt) ]) atIndex:i];
            [bb.instructions insertObject:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp result:orig
                                                                  operands:@[ pwUse(bv), pwImm(0, wt) ]
                                                                 predicate:XTIRICmpNE dbgLoc:nil]
                                  atIndex:i + 1];
            return i + 2;
            }
        [bb.instructions insertObject:pwOp(XTIROpTrunc, orig, @[ x ]) atIndex:i];
        return i + 1;
        }
    // Written back into its word with the other bytes kept.
    XTIROperand* v = pwValue(fn, bb, &i, ip.operands[1], t);
    XTIRValue* m1 = pwNew(fn, mem, bb);
    XTIRValue* old = pwNew(fn, wt, bb);
    XTIRInsn* l1 = pwOp(XTIROpLoad, old, @[ addr, memIn ]);
    l1.memoryResult = m1;
    XTIRValue* z = pwNew(fn, wt, bb);
    XTIRValue* zm = pwNew(fn, wt, bb);
    XTIRValue* kept = pwNew(fn, wt, bb);
    XTIRValue* nw = pwNew(fn, wt, bb);
    [bb.instructions insertObject:l1 atIndex:i];
    [bb.instructions insertObject:pwOp(XTIROpZExt, z, @[ v ]) atIndex:i + 1];
    [bb.instructions insertObject:pwOp(XTIROpAnd, zm, @[ pwUse(z), pwImm(mask, wt) ]) atIndex:i + 2];
    i += 3;
    XTIROperand* bits = pwUse(zm);
    if (shift)
        {
        XTIRValue* sv = pwNew(fn, wt, bb);
        [bb.instructions insertObject:pwOp(XTIROpShl, sv, @[ bits, pwImm(shift, wt) ]) atIndex:i];
        i++;
        bits = pwUse(sv);
        }
    int64_t wmask = ww == 4 ? (int64_t)0xFFFFFFFF : ((int64_t)1 << (ww * 8)) - 1;
    [bb.instructions insertObject:pwOp(XTIROpAnd, kept, @[ pwUse(old), pwImm(wmask ^ (mask << shift), wt) ]) atIndex:i];
    [bb.instructions insertObject:pwOp(XTIROpOr, nw, @[ pwUse(kept), bits ]) atIndex:i + 1];
    i += 2;
    [ip replaceOperands:@[ ip.operands[0], pwUse(nw), pwUse(m1) ]];
    return i + 1;
    }

static NSArray<XTIRInsn*>* pwAll(XTIRBlock* bb)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
    [all addObjectsFromArray:bb.instructions];
    if (bb.terminator)
        [all addObject:bb.terminator];
    return all;
    }

// `FieldAddr self, #k`'s k, else -1.
static int64_t pwSelfField(XTIRInsn* _Nullable fa, XTIRValueId selfId)
    {
    if (!fa || fa.opcode != XTIROpFieldAddr || fa.operands.count != 2 || fa.operands[0].kind != XTIROperandKindUse
        || fa.operands[0].valueId != selfId || fa.operands[1].kind != XTIROperandKindImmI)
        return -1;
    return fa.operands[1].intValue;
    }

void XTParWordStructs(XTIRFunction* f)
    {
    if (!f.paramTypes.count)
        return;
    // The block's object is parameter 0, value 0.
    XTIRValueId selfId = 0;
    if (![f valueForId:selfId])
        return;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* def = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in f.blocks)
        for (XTIRInsn* ip in bb.instructions)
            if (ip.result)
                def[@(ip.result.valueId)] = ip;
    // The arrays: a global's address, or a captured pointer loaded from the
    // block's object, whose element is a struct with a word.
    NSMutableDictionary<NSNumber*, NSString*>* baseOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, XTIRType*>* sty = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*>* bad = [NSMutableSet set];
    NSMutableArray<NSString*>* keys = [NSMutableArray array];
    for (XTIRBlock* bb in f.blocks)
        for (XTIRInsn* ip in bb.instructions)
            {
            if (!ip.result || !ip.operands.count || ip.result.type.kind != XTIRTypeKindPtr)
                continue;
            XTIRType* st = ip.result.type.pointeeType;
            XTIRLayout* sl = st.kind == XTIRTypeKindAgg ? st.layout : nil;
            if (!sl || sl.isArray || !XTParWordOf(st))
                continue;
            XTIROperand* o0 = ip.operands[0];
            NSString* key = nil;
            if (ip.opcode == XTIROpAddrOf && ip.operands.count == 1 && o0.kind == XTIROperandKindSym)
                key = [NSString stringWithFormat:@"g%u", (unsigned)o0.symbolId];
            else if (ip.opcode == XTIROpLoad && o0.kind == XTIROperandKindUse)
                {
                int64_t k = pwSelfField(def[@(o0.valueId)], selfId);
                if (k >= 0)
                    key = [NSString stringWithFormat:@"b%lld", (long long)k];
                }
            if (!key)
                continue;
            if (!sty[key])
                {
                sty[key] = st;
                [keys addObject:key];
                }
            else if (sty[key].layout != st.layout)
                [bad addObject:key];
            baseOf[@(ip.result.valueId)] = key;
            }
    if (!keys.count)
        return;
    // The addresses into them: an element's (the root), and a field's or a
    // nested field's, each at a byte offset from its element.
    NSMutableDictionary<NSNumber*, NSString*>* cKey = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* cOff = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRType*>* cTy = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* cRoot = [NSMutableDictionary dictionary];
    for (int pass = 0; pass < 4; pass++)
        for (XTIRBlock* bb in f.blocks)
            for (XTIRInsn* ip in bb.instructions)
                {
                if (!ip.result || ip.operands.count != 2)
                    continue;
                NSNumber* rk = @(ip.result.valueId);
                if (cKey[rk])
                    continue;
                XTIROperand* o0 = ip.operands[0];
                XTIROperand* o1 = ip.operands[1];
                if (o0.kind != XTIROperandKindUse)
                    continue;
                NSNumber* vk = @(o0.valueId);
                NSString* bk = baseOf[vk];
                if (bk)
                    {
                    if (ip.opcode == XTIROpElementAddr)
                        {
                        cKey[rk] = bk;
                        cOff[rk] = @0;
                        cTy[rk] = sty[bk];
                        cRoot[rk] = rk;
                        }
                    continue;
                    }
                NSString* ck = cKey[vk];
                if (!ck || o1.kind != XTIROperandKindImmI || o1.intValue < 0)
                    continue;
                XTIRType* vt = cTy[vk];
                XTIRLayout* l = vt.kind == XTIRTypeKindAgg ? vt.layout : nil;
                uint32_t off = cOff[vk].unsignedIntValue;
                BOOL isRoot = [cRoot[vk] isEqualToNumber:vk];
                BOOL field = ip.opcode == XTIROpFieldAddr && l && !l.isArray;
                BOOL inner = ip.opcode == XTIROpElementAddr && l && l.isArray && !isRoot;
                if ((!field && !inner) || o1.intValue >= (int64_t)l.fieldCount)
                    continue;
                cKey[rk] = ck;
                cOff[rk] = @(off + [l fieldOffsetAt:(NSUInteger)o1.intValue]);
                cTy[rk] = [l fieldTypeAt:(NSUInteger)o1.intValue];
                cRoot[rk] = cRoot[vk];
                }
    // Every use of them must be one of those, or a load or store of a field
    // the word holds; a field of the word's own type is a pointer to a word
    // and may be used as any.
    for (XTIRBlock* bb in f.blocks)
        for (XTIRInsn* ip in pwAll(bb))
            {
            BOOL resIn = ip.result && cKey[@(ip.result.valueId)];
            for (NSUInteger k = 0; k < ip.operands.count; k++)
                {
                XTIROperand* o = ip.operands[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                NSNumber* vk = @(o.valueId);
                NSString* bk = baseOf[vk];
                NSString* ck = cKey[vk];
                if (bk)
                    {
                    if (!(k == 0 && resIn && ip.opcode == XTIROpElementAddr))
                        [bad addObject:bk];
                    continue;
                    }
                if (!ck)
                    continue;
                if (k == 0 && resIn)
                    continue;
                XTIRType* t = cTy[vk];
                XTIRType* wt = XTParWordOf(sty[ck]);
                BOOL root = [cRoot[vk] isEqualToNumber:vk];
                if (!root && pwSame(t, wt) && cOff[vk].unsignedIntValue % pwWidth(wt) == 0)
                    continue;
                BOOL access = k == 0 && !root && (ip.opcode == XTIROpLoad || (ip.opcode == XTIROpStore && ip.operands.count >= 2));
                if (!access || !pwHolds(wt, t, cOff[vk].unsignedIntValue))
                    [bad addObject:ck];
                }
            }
    // The captured pointers: their field in the object must be loaded only,
    // so the object's layout can say it points to words.
    for (XTIRBlock* bb in f.blocks)
        for (XTIRInsn* ip in pwAll(bb))
            for (NSUInteger k = 0; k < ip.operands.count; k++)
                {
                XTIROperand* o = ip.operands[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                int64_t fk = pwSelfField(def[@(o.valueId)], selfId);
                if (fk < 0)
                    continue;
                NSString* key = [NSString stringWithFormat:@"b%lld", (long long)fk];
                if (!sty[key])
                    continue;
                BOOL isBase = ip.result && baseOf[@(ip.result.valueId)];
                if (!(k == 0 && ip.opcode == XTIROpLoad && isBase))
                    [bad addObject:key];
                }
    BOOL any = NO;
    for (NSString* key in keys)
        if (![bad containsObject:key])
            any = YES;
    if (!any)
        return;
    // The rewrite.
    NSMutableDictionary<NSNumber*, XTIRType*>* fieldRetyped = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in f.blocks)
        {
        NSUInteger i = 0;
        while (i < bb.instructions.count)
            {
            XTIRInsn* ip = bb.instructions[i];
            XTIRValue* r = ip.result;
            XTIROperand* o0 = ip.operands.count ? ip.operands[0] : nil;
            NSNumber* rk = r ? @(r.valueId) : nil;
            NSString* bk = rk ? baseOf[rk] : nil;
            NSString* ck = rk ? cKey[rk] : nil;
            NSNumber* ak = o0 && o0.kind == XTIROperandKindUse ? @(o0.valueId) : nil;
            NSString* lk = ak ? cKey[ak] : nil;
            if (lk && ![bad containsObject:lk] && (ip.opcode == XTIROpLoad || ip.opcode == XTIROpStore))
                {
                i = pwAccess(f, bb, i, ip, cTy[ak], cOff[ak].unsignedIntValue, XTParWordOf(sty[lk]),
                             (XTIRValueId)cRoot[ak].unsignedLongLongValue);
                continue;
                }
            if (bk && ![bad containsObject:bk])
                {
                XTIRType* wt = XTParWordOf(sty[bk]);
                XTIRType* pt = pwPtr(r.type, wt);
                bb.instructions[i] = pwRebuilt(ip, pwRetyped(f, r, pt), nil);
                if (ip.opcode == XTIROpLoad)
                    {
                    // Its field in the object points to words now.
                    XTIRInsn* fa = def[ak];
                    XTIRValue* fr = pwRetyped(f, fa.result, pwPtr(fa.result.type, pt));
                    XTIRBlock* fb = nil;
                    NSUInteger fi = NSNotFound;
                    for (XTIRBlock* b2 in f.blocks)
                        {
                        NSUInteger q = [b2.instructions indexOfObjectIdenticalTo:fa];
                        if (q != NSNotFound)
                            {
                            fb = b2;
                            fi = q;
                            }
                        }
                    XTIRInsn* nfa = pwRebuilt(fa, fr, nil);
                    if (fb)
                        fb.instructions[fi] = nfa;
                    def[ak] = nfa;
                    fieldRetyped[@(fa.operands[1].intValue)] = pt;
                    }
                i++;
                continue;
                }
            if (!ck || [bad containsObject:ck])
                {
                i++;
                continue;
                }
            XTIRType* wt = XTParWordOf(sty[ck]);
            XTIRType* pt = pwPtr(r.type, wt);
            XTIRValueId root = (XTIRValueId)cRoot[rk].unsignedLongLongValue;
            if (root == r.valueId)
                {
                // [i] of the struct: [i * (size / word)] of the word.
                uint32_t n = sty[ck].layout.size / pwWidth(wt);
                XTIROperand* io = ip.operands[1];
                XTIROperand* scaled = nil;
                if (io.kind == XTIROperandKindImmI)
                    scaled = pwImm(io.intValue * (int64_t)n, io.type);
                else if (io.kind == XTIROperandKindUse)
                    {
                    XTIRType* it = [f valueForId:io.valueId].type;
                    XTIRValue* mv = pwNew(f, it, bb);
                    [bb.instructions insertObject:pwOp(XTIROpMul, mv, @[ pwUse([f valueForId:io.valueId]), pwImm(n, it) ])
                                          atIndex:i];
                    i++;
                    scaled = pwUse(mv);
                    }
                bb.instructions[i] = pwRebuilt(ip, pwRetyped(f, r, pt), scaled ? @[ ip.operands[0], scaled ] : nil);
                }
            else
                {
                // A field: the word it starts in.
                uint32_t off = cOff[rk].unsignedIntValue;
                bb.instructions[i] = pwOp(XTIROpElementAddr, pwRetyped(f, r, pt),
                                          @[ [XTIROperand useWithValueId:root], pwImm(off / pwWidth(wt), [XTIRType u32Type]) ]);
                }
            i++;
            }
        }
    // The object's layout, in this copy: each captured pointer's field points
    // to words.
    if (!fieldRetyped.count)
        return;
    XTIRType* selfT = f.paramTypes[0];
    XTIRLayout* ol = selfT.kind == XTIRTypeKindPtr && selfT.pointeeType.kind == XTIRTypeKindAgg ? selfT.pointeeType.layout : nil;
    if (!ol)
        return;
    NSMutableArray<XTIRLayoutField*>* fields = [NSMutableArray array];
    for (NSUInteger k = 0; k < ol.fieldCount; k++)
        [fields addObject:[[XTIRLayoutField alloc] initWithOffset:[ol fieldOffsetAt:k]
                                                             type:fieldRetyped[@(k)] ?: [ol fieldTypeAt:k]]];
    XTIRLayout* nl = [[XTIRLayout alloc] initWithSize:ol.size alignment:1 fields:fields];
    XTIRType* nt = pwPtr(selfT, [XTIRType aggWithLayout:nl]);
    [f setParamType:nt atIndex:0];
    pwRetyped(f, [f valueForId:selfId], nt);
    }

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
                                  printed:(NSString* _Nullable* _Nullable)printedIO
                                    trips:(NSInteger)trips
                                  changed:(NSSet<NSString*>* _Nullable* _Nullable)changed
    {
    // Nothing to render without a block: the round trip prints and reparses
    // the whole module, and a program with a 64M-element global took two
    // minutes and 23 GB in it for no kernel at all.
    BOOL any = NO;
    for (XTIRFunction* f in module.functions)
        if ([f.name hasPrefix:@"ParImpl$"] && [f.name hasSuffix:@"$run"])
            {
            any = YES;
            break;
            }
    if (!any)
        return nil;
    // The module printed once: a second copy (the variant's) is a parse only.
    BOOL again = printedIO && *printedIO;
    NSString* printed = again ? *printedIO : [XTIRPrinter stringFromModule:module];
    XTIRModule* copy = [XTIRParser moduleFromString:printed sharingLayoutsOf:module error:NULL];
    if (!copy || (!again && ![[XTIRPrinter stringFromModule:copy] isEqualToString:printed]))
        return nil;
    if (printedIO)
        *printedIO = printed;
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
    // A sqrt call becomes the pure FSqrt first, as the main pipeline does
    // before it inlines: a call writes memory as far as LICM knows, so a
    // kernel calling Math.sqrt kept every load in its loops (nbody's px[i]
    // reloaded per inner iteration on the GPU, issue #7).
    XTIROptSqrtIntrinsic* sqrtIn = [XTIROptSqrtIntrinsic new];
    sqrtIn.profile = prof;
    [p addPass:sqrtIn];
    XTIROptInline* inl = [XTIROptInline new];
    inl.profile = prof;
    [p addPass:inl];
    // An inlined Math.sqrt brings its class's init guard into the loop, a call
    // that kept every load there and the body two blocks. A kernel never runs
    // an initialiser (the printers skip those calls), so every guard folds.
    XTIROptStaticInitGuard* sig = [XTIROptStaticInitGuard new];
    sig.profile = prof;
    sig.foldAll = YES;
    [p addPass:sig];
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
    // The variant's copy only: several trips of an escape loop per exit test.
    XTIROptGpuEscapeTrips* esc = nil;
    if (trips >= 2)
        {
        esc = [XTIROptGpuEscapeTrips new];
        esc.trips = trips;
        [p addPass:esc];
        }
    // A counted inner loop whose constant trip is a whole number of groups of
    // four runs as four copies per back edge (issue #7): no copy needs a
    // guard, and a GPU pays for guards more than for the back edge they save.
    // Before the rotate, whose shape it does not take.
    XTIROptLoopUnrollVarTrip* unr = [XTIROptLoopUnrollVarTrip new];
    unr.profile = prof;
    unr.exactOnly = YES;
    [p addPass:unr];
    // The copies are a chain of blocks; one block again, so the rotate below
    // takes the loop.
    [p addPass:[XTIROptBlockMerge new]];
    XTIROptLoopRotate* rot = [XTIROptLoopRotate new];
    rot.profile = prof;
    [p addPass:rot];
    [p addPass:[XTIROptDeadCode new]];
    if (![p runOnModule:copy errors:NULL])
        return nil;
    if (changed)
        *changed = esc ? [esc.changed copy] : [NSSet set];
    return copy;
    }

+ (void)fillSourcesIn:(XTIRModule*)module
              classDecls:(NSDictionary<NSString*, XTClassDeclNode*>*)classDecls
             diagnostics:(XTDiagnosticEngine*)diag
                  serial:(NSSet<NSString*>*)serial
    {
    NSString* printedModule = nil;
    XTIRModule* kmod = [self kernelModuleFrom:module printed:&printedModule trips:0 changed:NULL];
    NSMutableDictionary<NSString*, XTIRFunction*>* kfns = [NSMutableDictionary dictionary];
    for (XTIRFunction* g in kmod.functions)
        kfns[g.name] = g;
    // A second kernel per form, carried beside the plain one, for a block whose
    // escape loop runs several trips per exit test (XTIROptGpuEscapeTrips):
    // the runtime picks one per device (ParDevice.variantFor), since it helps
    // one GPU and hurts another (gpu-kernel-variants.md). XTGPU_ESC_TRIPS=<n>
    // sets the trips, 0 or 1 for none. Not for a module whose printed text is
    // past 64 MB: the copy is a parse of it.
    NSInteger vtrips = 8;
    const char* et = getenv("XTGPU_ESC_TRIPS");
    if (et && *et)
        vtrips = atoi(et);
    NSSet<NSString*>* vchanged = nil;
    XTIRModule* kvmod = nil;
    if (kmod && vtrips >= 2 && printedModule.length <= (NSUInteger)64 << 20)
        kvmod = [self kernelModuleFrom:module printed:&printedModule trips:vtrips changed:&vchanged];
    NSMutableDictionary<NSString*, XTIRFunction*>* kvfns = [NSMutableDictionary dictionary];
    for (XTIRFunction* g in kvmod.functions)
        if ([vchanged containsObject:g.name])
            kvfns[g.name] = g;
    for (XTIRFunction* f in module.functions)
        {
        if (![f.name hasPrefix:@"ParImpl$"] || ![f.name hasSuffix:@"$run"])
            continue;
        // Each printer tries the optimised kernel first and the plain one if
        // that declines, so the optimiser never costs a block its GPU path.
        XTIRFunction* kf = kfns[f.name];
        // Its arrays of structs as arrays of words, in the copies the kernels
        // are printed from (XTParWordStructs).
        if (kf)
            XTParWordStructs(kf);
        if (kvfns[f.name])
            XTParWordStructs(kvfns[f.name]);
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
        NSMutableIndexSet* constFields = [NSMutableIndexSet indexSet];
        gParGridW = 0;
        gParGridH = 0;
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
                // `c<field>`: a :constant capture (par-blocks.md §3, storage hints).
                if (pair.length > 1 && [pair hasPrefix:@"c"] && [pair rangeOfString:@"="].location == NSNotFound)
                    {
                    [constFields addIndex:(NSUInteger)[pair substringFromIndex:1].integerValue];
                    continue;
                    }
                // `gw=<n>` / `gh=<n>`: a grid's constant width and height.
                if ([pair hasPrefix:@"gw="]) { gParGridW = [pair substringFromIndex:3].longLongValue; continue; }
                if ([pair hasPrefix:@"gh="]) { gParGridH = [pair substringFromIndex:3].longLongValue; continue; }
                NSRange eq = [pair rangeOfString:@"="];
                if (eq.location == NSNotFound || eq.location == 0)
                    continue;
                redOps[@([pair substringToIndex:eq.location].integerValue)] = [pair substringFromIndex:eq.location + 1];
                }
            }
        [XTIRParMSL setConstantFields:constFields];
        // The buffers' footprints, as words on the header line every printer
        // writes (step 1 of par-tiles-and-devices.md).
        XTIRParCheck* fc = [XTIRParCheck new];
        fc.module = module;
        // The helpers by name, so the cost words count a called helper's
        // work as the port's do (without them a `mix` with a loop read as 3
        // ops and no loop).
        fc.fnByName = [NSMutableDictionary dictionary];
        for (XTIRFunction* hf in module.functions)
            fc.fnByName[hf.name] = hf;
        NSString* fcls = [f.name substringToIndex:f.name.length - 4];
        // The optimised kernel can name a global the block cannot locate (a
        // helper's, inlined): the plain one then speaks for the block, and
        // its helper says why it stays on the CPU.
        if (kf && unlocatedGlobal(kf, kmod, module, fcls))
            kf = nil;
        NSString* meta = [[[fc footprintWordsIn:f ivarNames:[fc ivarNamesOf:classDecls[fcls] in:classDecls]]
                            stringByAppendingString:[fc costWordsIn:f]]
                            stringByAppendingString:[[fc guardWordsIn:f guards:gParGuards[fcls]]
                                                        stringByAppendingString:[fc mergeWordsIn:f redOps:redOps fast:fast]]];
        [XTIRParMSL setExtraMeta:meta];
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
        // A global its run could not locate: no form at all, and that reason.
        NSString* lost = serialBlock ? nil : unlocatedGlobal(f, module, module, fcls);
        if (lost)
            mslWhy = ptxWhy = wgslWhy = spvWhy = [@"it uses the global " stringByAppendingString:shownName(lost)];
        BOOL noForms = serialBlock || lost;
        NSString* msl = gEmitsMetal && !noForms ? metalOf(&mslWhy) : nil;
        NSString* ptx = gEmitsPTX && !noForms ? ptxOf(&ptxWhy) : nil;
        NSString* wgsl = gEmitsWGSL && !noForms ? wgslOf(&wgslWhy) : nil;
        NSData* spv = gEmitsSPIRV && !noForms ? spirvOf(&spvWhy) : nil;
        // The variant of each form there is (`trips=<n>` on its header line),
        // from the copy whose escape loop runs several trips per exit test, for
        // the runtime to choose (gpu-kernel-variants.md). Only where the plain
        // form exists and the variant's printer takes the kernel too.
        XTIRFunction* kvf = noForms ? nil : kvfns[f.name];
        NSString *vmsl = nil, *vptx = nil, *vwgsl = nil;
        NSData* vspv = nil;
        if (kvf)
            {
            [XTIRParMSL setExtraMeta:[meta stringByAppendingFormat:@" trips=%ld", (long)vtrips]];
            if (msl)
                vmsl = [XTIRParMSL sourceForKernel:kvf module:kvmod fast:fast redOps:redOps why:NULL];
            if (ptx)
                vptx = [XTIRParMSL ptxForKernel:kvf module:kvmod fast:fast redOps:redOps why:NULL];
            if (wgsl)
                vwgsl = [XTIRParMSL wgslForKernel:kvf module:kvmod fast:fast redOps:redOps why:NULL];
            if (spv)
                vspv = [XTIRParMSL spirvForKernel:kvf module:kvmod fast:fast redOps:redOps why:NULL];
            [XTIRParMSL setExtraMeta:meta];
            }
        NSMutableData* all = [NSMutableData data];
        if (serialBlock)
            [all appendData:[@"// xcpar serial\n" dataUsingEncoding:NSUTF8StringEncoding]];
        uint8_t zero = 0;
        // The plain forms' text, then the variants', then the SPIR-V modules
        // in the same order: a runtime that knows no variant stops at the first
        // module it finds, the plain one.
        for (NSString* text in @[ msl ?: @"", ptx ?: @"", wgsl ?: @"", vmsl ?: @"", vptx ?: @"", vwgsl ?: @"" ])
            {
            if (!text.length)
                continue;
            while (all.length % 4)
                [all appendBytes:&zero length:1];
            [all appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
            [all appendBytes:&zero length:1];
            }
        for (NSData* mod in @[ spv ?: [NSData data], vspv ?: [NSData data] ])
            {
            if (!mod.length)
                continue;
            while (all.length % 4)
                [all appendBytes:&zero length:1];
            [all appendData:mod];
            }
        // A block the run must check (guard= words) and no form to carry the
        // check runs serially: its threads could otherwise meet.
        if (!all.length && gParGuards[fcls].count)
            [all appendData:[@"// xcpar serial\n" dataUsingEncoding:NSUTF8StringEncoding]];
        if (all.length)
            kernel = all;
        else
            {
            // The first form's reason, of those the target has: Vulkan's before
            // CUDA's, so a Linux build that carries both (2026-10-28) still says
            // what Vulkan could not do. As the port.
            why = nil;
            if (gEmitsMetal) why = mslWhy;
            if (!why && gEmitsSPIRV) why = spvWhy;
            if (!why && gEmitsPTX) why = ptxWhy;
            if (!why && gEmitsWGSL) why = wgslWhy;
            }
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
            // A loop the compiler lifted by itself says so only under
            // -Wpar-auto: a plain program is not told about a block it never
            // wrote. Mirrored in the port.
            BOOL lifted = [self isAutoBlock:module number:[cls substringFromIndex:8]];
            [diag emitWarning:[NSString stringWithFormat:lifted ? @"this loop runs on the CPU only (--par-style), because %@"
                                                                : @"this 'par' block runs on the CPU only, because %@",
                                                         why ?: @"its GPU version cannot express something it uses yet"]
                     category:lifted ? XTWarnParAuto : XTWarnParGpu
                           at:classDecls[cls].location];
            // No form to run, but the run still checks the block's arrays
            // against each other (ParDevice.bufferOverlap): two captured
            // pointers that are one block, one written, make it a scan, and it
            // must run serially. The check reads the buffers from the header
            // line, so a block with no form gets that line alone, `// xcpar
            // cpu`, with every captured pointer to numbers. Empty, an aliased
            // block ran in parallel and gave wrong answers on any target
            // without a GPU form for it.
            NSMutableString* hdr = [NSMutableString stringWithString:@"// xcpar cpu"];
            XTIRType* selfT = f.paramTypes.count ? f.paramTypes[0] : nil;
            NSArray<XTIRLayoutField*>* fl = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout.fields : nil;
            for (NSUInteger k = 3; k < fl.count; k++)
                {
                XTIRType* t = fl[k].type;
                XTIRType* e = t.kind == XTIRTypeKindPtr ? t.pointeeType : nil;
                if (!e || e.kind == XTIRTypeKindAgg || e.kind == XTIRTypeKindPtr || e.kind == XTIRTypeKindVec
                    || e.kind == XTIRTypeKindVoid || e.byteWidth == 0)
                    continue;
                [hdr appendFormat:@" buf=%u:%lu:%u", fl[k].byteOffset, (unsigned long)(k - 3), e.byteWidth];
                }
            [hdr appendString:@"\n"];
            kernel = [hdr dataUsingEncoding:NSUTF8StringEncoding];
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
    gParGuards = [NSMutableDictionary dictionary];
    // The auto blocks (--par-style=auto made them from plain loops) par-check would
    // refuse: demoted to a serial run instead, with a warning (par-auto).
    NSMutableSet<NSString*>* serial = [NSMutableSet set];
    for (XTIRFunction* f in module.functions)
        {
        if (![f.name hasPrefix:@"ParImpl$"] || ![f.name hasSuffix:@"$run"])
            continue;
        NSString* cls = [f.name substringToIndex:f.name.length - 4];
        BOOL isAuto = [self isAutoBlock:module number:[cls substringFromIndex:8]];
        [self readGridWords:module number:[cls substringFromIndex:8]];
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
            NSMutableArray<NSString*>* guards = [NSMutableArray array];
            NSString* dep = [c dependenceIn:f ivarNames:[c ivarNamesOf:decl in:classDecls] scatter:&scatter guards:guards];
            // A loop the compiler lifted by itself is a block only when its
            // items are PROVED apart: a write the shapes do not cover (every
            // item writing one element, or an index from data) keeps it serial.
            // A written block's scatter stays a warning, the developer's call.
            // for (r) { for (i) c[i] = … } wrote all of c from every r at once.
            if (!dep && isAuto && scatter)
                dep = [NSString stringWithFormat:@"writes %@, and two of them could write the same element", scatter];
            if (!dep && guards.count)
                gParGuards[cls] = guards;
            if (!dep)
                {
                if (scatter)
                    [diag emitWarning:[NSString stringWithFormat:@"a 'par' block writes %@, so the compiler "
                                                                 @"cannot prove two work items never write the "
                                                                 @"same element; if they can, the result depends "
                                                                 @"on which runs last", scatter]
                             category:XTWarnParScatter
                                   at:decl.location];
                // -Wpar-auto says what was wrapped as well as what was demoted.
                if (isAuto)
                    [diag emitWarning:@"this loop became a 'par' block (--par-style)"
                             category:XTWarnParAuto
                                   at:decl.location];
                continue;
                }
            if (isAuto)
                {
                [serial addObject:cls];
                [diag emitWarning:[NSString stringWithFormat:@"this loop runs serially, not as a 'par' block (--par-style): "
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
            [diag emitWarning:[NSString stringWithFormat:@"this loop runs serially, not as a 'par' block (--par-style): "
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
        {
        parResolveKept(module, serial);
        [self fillSourcesIn:module classDecls:classDecls diagnostics:diag serial:serial];
        }
    return ok;
    }

// The grid's constant width and height for block <n>, from its placeholder's
// `gw=`/`gh=` words (0 when absent): set for the dependence test, which runs
// before the printers' pass reads the words again.
+ (void)readGridWords:(XTIRModule*)module number:(NSString*)n
    {
    gParGridW = 0;
    gParGridH = 0;
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
        NSUInteger end = b.length;
        while (end > tag.length && ((const uint8_t*)b.bytes)[end - 1] == 0)
            end--;
        NSString* rest = end > tag.length ? [[NSString alloc] initWithBytes:(const char*)b.bytes + tag.length
                                                                      length:end - tag.length
                                                                    encoding:NSUTF8StringEncoding] : @"";
        for (NSString* pair in [rest componentsSeparatedByString:@";"])
            {
            if ([pair hasPrefix:@"gw="]) gParGridW = [pair substringFromIndex:3].longLongValue;
            if ([pair hasPrefix:@"gh="]) gParGridH = [pair substringFromIndex:3].longLongValue;
            }
        return;
        }
    }

// Whether block <n> (its class ParImpl$<n>) is one --par-style=auto made from a
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

// Per block class: the runtime checks par-check left it (parGuardFor), as
// "slot:m:d0:k" strings, for its header's guard= words.
static NSMutableDictionary<NSString*, NSArray<NSString*>*>* gParGuards = nil;

// An index with up to two symbolic terms besides i: k*i + c + m*v + m2*v2,
// where v and v2 are captured integers of the block (fields `slot` and
// `slot2` of its object). `a[i + off]` is such a form; the plain test above
// cannot say whether it meets `a[i]`, but the run can, once it knows off.
// The terms are kept in field order. Mirrored in the port.
typedef struct
    {
    BOOL affine;
    int64_t k, c;
    NSInteger slot;   // the field, or -1 when there is no symbolic term
    int64_t m;
    NSInteger slot2;  // a second field, valid when m2 != 0
    int64_t m2;
    } XTParSym;

// The same symbolic terms: the two indexes differ by a constant only.
static BOOL parSameTerms(XTParSym a, XTParSym b)
    {
    BOOL first = (a.slot < 0 && b.slot < 0) || (a.slot == b.slot && a.m == b.m);
    BOOL second = (a.m2 == 0 && b.m2 == 0) || (a.slot2 == b.slot2 && a.m2 == b.m2);
    return first && second;
    }

static BOOL parIntKind(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindI16: case XTIRTypeKindU16:
        case XTIRTypeKindI32: case XTIRTypeKindU32: case XTIRTypeKindI64: case XTIRTypeKindU64:
            return YES;
        default:
            return NO;
        }
    }


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

- (XTParSym)symIndexOf:(XTIROperand*)op iv:(XTIRValueId)iv self:(XTIRValueId)selfId
                  defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def depth:(int)depth
    {
    XTParSym no = { NO, 0, 0, -1, 0 };
    if (depth > 32)
        return no;
    if (op.kind == XTIROperandKindImmI)
        return (XTParSym){ YES, 0, op.intValue, -1, 0 };
    if (op.kind != XTIROperandKindUse)
        return no;
    if (op.valueId == iv)
        return (XTParSym){ YES, 1, 0, -1, 0 };
    XTIRInsn* d = def[@(op.valueId)];
    if (!d || !d.operands.count)
        return no;
    switch (d.opcode)
        {
        case XTIROpConst:
            return d.operands[0].kind == XTIROperandKindImmI ? (XTParSym){ YES, 0, d.operands[0].intValue, -1, 0 } : no;
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
        case XTIROpCopy:
            return [self symIndexOf:d.operands[0] iv:iv self:selfId defs:def depth:depth + 1];
        case XTIROpLoad:
            {
            // A captured integer: a load of one of the block object's fields.
            if (d.operands[0].kind != XTIROperandKindUse || !d.result || !parIntKind(d.result.type))
                return no;
            XTIRInsn* fa = def[@(d.operands[0].valueId)];
            if (fa.opcode != XTIROpFieldAddr || fa.operands.count < 2 || fa.operands[0].kind != XTIROperandKindUse ||
                fa.operands[0].valueId != selfId || fa.operands[1].kind != XTIROperandKindImmI || fa.operands[1].intValue < 3)
                return no;
            return (XTParSym){ YES, 0, 0, (NSInteger)fa.operands[1].intValue, 1 };
            }
        case XTIROpAdd:
        case XTIROpSub:
        case XTIROpMul:
            {
            if (d.operands.count < 2)
                return no;
            XTParSym a = [self symIndexOf:d.operands[0] iv:iv self:selfId defs:def depth:depth + 1];
            XTParSym b = [self symIndexOf:d.operands[1] iv:iv self:selfId defs:def depth:depth + 1];
            if (!a.affine || !b.affine)
                return no;
            XTParSym r = no;
            r.affine = YES;
            if (d.opcode == XTIROpMul)
                {
                // Only by a constant: k*i times v is not a form.
                BOOL aConst = a.k == 0 && a.slot < 0;
                BOOL bConst = b.k == 0 && b.slot < 0;
                if (!aConst && !bConst)
                    return no;
                XTParSym s = aConst ? b : a;
                int64_t f = aConst ? a.c : b.c;
                r = (XTParSym){ YES, s.k * f, s.c * f, s.slot, s.m * f, s.slot2, s.m2 * f };
                }
            else
                {
                // The terms of both sides, merged by field: two at most.
                int64_t sign = d.opcode == XTIROpSub ? -1 : 1;
                NSInteger sl[4];
                int64_t mm[4];
                int n = 0;
                NSInteger tsl[4] = { a.slot, a.slot2, b.slot, b.slot2 };
                int64_t tm[4] = { a.slot >= 0 ? a.m : 0, a.m2, sign * (b.slot >= 0 ? b.m : 0), sign * b.m2 };
                for (int t = 0; t < 4; t++)
                    {
                    if (tm[t] == 0)
                        continue;
                    int at = -1;
                    for (int q = 0; q < n; q++)
                        if (sl[q] == tsl[t])
                            at = q;
                    if (at < 0)
                        {
                        sl[n] = tsl[t];
                        mm[n] = 0;
                        at = n++;
                        }
                    mm[at] += tm[t];
                    }
                int kept = 0;
                for (int q = 0; q < n; q++)
                    if (mm[q] != 0)
                        {
                        sl[kept] = sl[q];
                        mm[kept] = mm[q];
                        kept++;
                        }
                if (kept > 2)
                    return no;
                if (kept == 2 && sl[1] < sl[0])
                    {
                    NSInteger ts = sl[0]; sl[0] = sl[1]; sl[1] = ts;
                    int64_t tv = mm[0]; mm[0] = mm[1]; mm[1] = tv;
                    }
                r.k = a.k + sign * b.k;
                r.c = a.c + sign * b.c;
                r.slot = kept > 0 ? sl[0] : -1;
                r.m = kept > 0 ? mm[0] : 0;
                r.slot2 = kept > 1 ? sl[1] : 0;
                r.m2 = kept > 1 ? mm[1] : 0;
                }
            if (r.m == 0)
                r.slot = -1;
            return r;
            }
        default:
            return no;
        }
    }

// A `par :grid` block's index as a polynomial over its point and size: the
// atoms are i (the flat index), W and H (the par$w and par$h ivars), x (i % W),
// q (i / W), y ((i / W) % H) and z (i / (W*H)); a monomial is its atoms sorted
// and joined by '.', "" the constant. nil when the index is anything else. A
// captured integer (another field of the block's object, as symIndexOf: takes
// it) is the atom "#<field>", and only ever times a constant, so
// `o[plane + par.y * par.width + par.x]` is the loop form's `o[plane + i]`.
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
            if (k >= 3 && d.result && parIntKind(d.result.type))
                return [@{[NSString stringWithFormat:@"#%lld", (long long)k] : @1} mutableCopy];
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
                // A captured integer only times a constant.
                BOOL (^hasCap)(NSDictionary*) = ^BOOL(NSDictionary* p) {
                  for (NSString* m in p)
                      if ([m hasPrefix:@"#"])
                          return YES;
                  return NO;
                };
                BOOL (^isConst)(NSDictionary*) = ^BOOL(NSDictionary* p) {
                  return p.count == 0 || (p.count == 1 && p[@""] != nil);
                };
                if ((hasCap(a) && !isConst(b)) || (hasCap(b) && !isConst(a)))
                    return nil;
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

// A grid's width and height when the block's placeholder says they are
// constants (`gw=`, `gh=`): `640 * y + x` is then the point's flat index as
// `W * y + x` with the captured width is, so the term is renamed before the
// forms are matched. Mirrored in the port.
static void parRenameConstantGrid(NSMutableDictionary<NSString*, NSNumber*>* p, BOOL threeD)
    {
    if (gParGridW <= 0)
        return;
    for (NSArray<NSString*>* m in @[ @[ @"y", @"W.y" ], @[ @"q", @"W.q" ] ])
        {
        int64_t c = [p[m[0]] longLongValue];
        if (c != 0 && c % gParGridW == 0)
            {
            p[m[1]] = @([p[m[1]] longLongValue] + c / gParGridW);
            [p removeObjectForKey:m[0]];
            }
        }
    int64_t cz = [p[@"z"] longLongValue];
    if (threeD && gParGridH > 0 && cz != 0 && cz % (gParGridW * gParGridH) == 0)
        {
        p[@"H.W.z"] = @([p[@"H.W.z"] longLongValue] + cz / (gParGridW * gParGridH));
        [p removeObjectForKey:@"z"];
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
    // A captured integer in it: not k*i + c (gridSymIndexOf: takes it).
    for (NSString* m in p)
        if ([m hasPrefix:@"#"])
            return no;
    int64_t c = [p[@""] longLongValue];
    [p removeObjectForKey:@""];
    BOOL threeD = [ivars containsObject:@"par$d"];
    parRenameConstantGrid(p, threeD);
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

// The grid index with up to two captured integers in it, as symIndexOf: gives
// the loop form's: k*i + c + m*field (+ m2*field2), the fields in order. Not
// affine when the rest is not k times a form of the flat index.
- (XTParSym)gridSymIndexOf:(XTIROperand*)op iv:(XTIRValueId)iv self:(XTIRValueId)selfId
                     ivars:(NSArray<NSString*>*)ivars defs:(NSDictionary<NSNumber*, XTIRInsn*>*)def
    {
    XTParSym no = { NO, 0, 0, -1, 0 };
    if (![ivars containsObject:@"par$w"])
        return no;
    NSMutableDictionary<NSString*, NSNumber*>* p = [self gridPoly:op iv:iv self:selfId ivars:ivars defs:def depth:0];
    if (!p)
        return no;
    NSMutableArray<NSNumber*>* slots = [NSMutableArray array];
    for (NSString* m in p.allKeys)
        if ([m hasPrefix:@"#"])
            {
            [slots addObject:@([m substringFromIndex:1].longLongValue)];
            }
    if (slots.count == 0 || slots.count > 2)
        return no;
    [slots sortUsingSelector:@selector(compare:)];
    int64_t m1 = [p[[NSString stringWithFormat:@"#%lld", slots[0].longLongValue]] longLongValue];
    int64_t m2 = slots.count > 1 ? [p[[NSString stringWithFormat:@"#%lld", slots[1].longLongValue]] longLongValue] : 0;
    for (NSNumber* sl in slots)
        [p removeObjectForKey:[NSString stringWithFormat:@"#%lld", sl.longLongValue]];
    int64_t c = [p[@""] longLongValue];
    [p removeObjectForKey:@""];
    BOOL threeD = [ivars containsObject:@"par$d"];
    parRenameConstantGrid(p, threeD);
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
            return (XTParSym){ YES, k, c, (NSInteger)slots[0].longLongValue, m1,
                               slots.count > 1 ? (NSInteger)slots[1].longLongValue : 0, m2 };
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

// Whether a read at r and a write at w (symbolic forms) can be settled by the
// run: the same stride k != 0 both sides and one captured integer between
// them. Then items i1 != i2 meet iff k*(i1 - i2) == d, where d = d0 + m*v is
// the write's offset less the read's, so the run checks d == 0, or d not a
// multiple of k, or |d| >= |k|*n. Writes the guard as "slot:m:d0:k".
static BOOL parGuardFor(XTParSym r, XTParSym w, NSString* _Nullable* _Nonnull guard)
    {
    if (!r.affine || !w.affine || r.k != w.k || r.k == 0 || r.m2 != 0 || w.m2 != 0)
        return NO;
    if (r.slot >= 0 && w.slot >= 0 && r.slot != w.slot)
        return NO;
    NSInteger slot = w.slot >= 0 ? w.slot : r.slot;
    int64_t m = (w.slot >= 0 ? w.m : 0) - (r.slot >= 0 ? r.m : 0);
    if (slot < 0 || m == 0)
        return NO;
    *guard = [NSString stringWithFormat:@"%ld:%lld:%lld:%lld", (long)slot, (long long)m, (long long)(w.c - r.c), (long long)r.k];
    return YES;
    }

// The general form, where parGuardFor cannot settle a pair (unequal strides,
// or a captured integer on each side): the run checks that the elements the
// tile's items write and the elements they read are two disjoint ranges —
// each index is affine in i, so its range over [lo, hi) runs between its
// values at lo and hi - 1 — or, with one stride, the parGuardFor test.
// Writes "x:<kw>:<cw>:<slotw>:<mw>:<kr>:<cr>:<slotr>:<mr>", slot -1 (m 0)
// where a side has no captured integer, and, where a side has a second,
// ":<slotw2>:<mw2>:<slotr2>:<mr2>" after it.
static BOOL parIntervalGuardFor(XTParSym r, XTParSym w, NSString* _Nullable* _Nonnull guard)
    {
    if (!r.affine || !w.affine || (r.k == 0 && w.k == 0))
        return NO;
    // One stride and no captured integer: the static test has decided (a
    // scan stays a scan, reported where it is written).
    if (r.k == w.k && r.slot < 0 && w.slot < 0)
        return NO;
    // …nor where both sides carry the same captured integers, which cancel
    // (the caller has decided that pair statically).
    if (r.k == w.k && parSameTerms(r, w))
        return NO;
    NSString* g = [NSString stringWithFormat:@"x:%lld:%lld:%ld:%lld:%lld:%lld:%ld:%lld",
                                             (long long)w.k, (long long)w.c, (long)(w.slot >= 0 ? w.slot : -1),
                                             (long long)(w.slot >= 0 ? w.m : 0), (long long)r.k, (long long)r.c,
                                             (long)(r.slot >= 0 ? r.slot : -1), (long long)(r.slot >= 0 ? r.m : 0)];
    if (r.m2 != 0 || w.m2 != 0)
        g = [g stringByAppendingFormat:@":%ld:%lld:%ld:%lld", (long)(w.m2 != 0 ? w.slot2 : -1), (long long)w.m2,
                                       (long)(r.m2 != 0 ? r.slot2 : -1), (long long)r.m2];
    *guard = g;
    return YES;
    }

static NSString* shownIndex(XTParIndex x)
    {
    if (!x.affine)
        return @" at an index computed from data";
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
// The guards as header words, `guard=<offset>:<bytes>:<m>:<d0>:<k>`: the
// captured integer v at <offset> in the block's object (<bytes> wide,
// signed), and the run is parallel only when d = d0 + m*v is 0, or not a
// multiple of k, or |d| >= |k|*n (ParDevice.guardsHold).
- (NSString*)guardWordsIn:(XTIRFunction*)f guards:(nullable NSArray<NSString*>*)guards
    {
    if (!guards.count)
        return @"";
    XTIRType* selfT = f.paramTypes.count ? f.paramTypes[0] : nil;
    XTIRLayout* lay = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    NSMutableString* words = [NSMutableString string];
    for (NSString* g in guards)
        {
        NSArray<NSString*>* p = [g componentsSeparatedByString:@":"];
        // `guardx=<kw>:<cw>:<offw>:<bytesw>:<mw>:<kr>:<cr>:<offr>:<bytesr>:<mr>`,
        // offset -1 (bytes 0) for a side with no captured integer.
        if ([p[0] isEqualToString:@"x"] && (p.count == 9 || p.count == 13))
            {
            NSString* (^side)(NSString*, NSString*, NSString*, NSString*) =
                ^NSString*(NSString* k, NSString* c, NSString* sl, NSString* m) {
                  NSInteger q = sl.integerValue;
                  if (!lay || q < 0 || (NSUInteger)q >= lay.fieldCount)
                      return [NSString stringWithFormat:@"%@:%@:-1:0:0", k, c];
                  return [NSString stringWithFormat:@"%@:%@:%u:%u:%@", k, c, [lay fieldOffsetAt:(NSUInteger)q],
                                                    [lay fieldTypeAt:(NSUInteger)q].byteWidth, m];
                };
            [words appendFormat:@" guardx=%@:%@", side(p[1], p[2], p[3], p[4]), side(p[5], p[6], p[7], p[8])];
            // A second captured integer a side: offset:bytes:m, after both.
            if (p.count == 13)
                {
                NSString* (^term)(NSString*, NSString*) = ^NSString*(NSString* sl, NSString* m) {
                  NSInteger q = sl.integerValue;
                  if (!lay || q < 0 || (NSUInteger)q >= lay.fieldCount)
                      return @"-1:0:0";
                  return [NSString stringWithFormat:@"%u:%u:%@", [lay fieldOffsetAt:(NSUInteger)q],
                                                    [lay fieldTypeAt:(NSUInteger)q].byteWidth, m];
                };
                [words appendFormat:@":%@:%@", term(p[9], p[10]), term(p[11], p[12])];
                }
            continue;
            }
        NSInteger slot = p[0].integerValue;
        if (!lay || slot < 0 || (NSUInteger)slot >= lay.fieldCount)
            continue;
        [words appendFormat:@" guard=%u:%u:%@:%@:%@", [lay fieldOffsetAt:(NSUInteger)slot],
                            [lay fieldTypeAt:(NSUInteger)slot].byteWidth, p[1], p[2], p[3]];
        }
    return words;
    }

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

// ` merge=<n>,…` (or nothing; n counts the red= words from 0): the
// reductions a node may fold before
// the coordinator does, because the order cannot change the bits — integer
// + * & | ^, min and max always; float + and * only under :goal(speed);
// float min and max always. In field order. The coordinator folds every
// tile's partial itself today; the word is there for a daemon that merges.
- (NSString*)mergeWordsIn:(XTIRFunction*)f redOps:(nullable NSDictionary<NSNumber*, NSString*>*)redOps fast:(BOOL)fast
    {
    XTIRType* selfT = f.paramTypes.count ? f.paramTypes[0] : nil;
    XTIRLayout* lay = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    if (!lay || redOps.count == 0)
        return @"";
    NSMutableArray<NSString*>* ok = [NSMutableArray array];
    NSUInteger ord = 0;
    for (NSNumber* k in [redOps.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        if (k.unsignedIntegerValue >= lay.fieldCount)
            continue;
        NSUInteger at = ord++;
        XTIRType* t = lay.fields[k.unsignedIntegerValue].type;
        BOOL isFloat = t.kind == XTIRTypeKindF32 || t.kind == XTIRTypeKindF64;
        NSString* op = redOps[k];
        BOOL m = [op isEqualToString:@"min"] || [op isEqualToString:@"max"];
        if (!isFloat)
            m = m || [op isEqualToString:@"+"] || [op isEqualToString:@"*"] || [op isEqualToString:@"&"] ||
                [op isEqualToString:@"|"] || [op isEqualToString:@"^"];
        else if (fast)
            m = m || [op isEqualToString:@"+"] || [op isEqualToString:@"*"];
        if (m)
            [ok addObject:[NSString stringWithFormat:@"%lu", (unsigned long)at]];
        }
    return ok.count ? [@" merge=" stringByAppendingString:[ok componentsJoinedByString:@","]] : @"";
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
    return [self dependenceIn:f ivarNames:ivars scatter:scatter guards:nil];
    }

// The same, collecting into `guards` the pairs the run can settle (a captured
// integer in the offset, parGuardFor) rather than calling them dependent; a
// nil `guards` keeps the plain test.
- (nullable NSString*)dependenceIn:(XTIRFunction*)f
                          ivarNames:(NSArray<NSString*>*)ivars
                            scatter:(NSString* _Nullable* _Nonnull)scatter
                             guards:(nullable NSMutableArray<NSString*>*)guards
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
            XTParSym sx = { NO, 0, 0, -1, 0 };
            if (guards)
                sx = x.affine ? (XTParSym){ YES, x.k, x.c, -1, 0 }
                              : [self symIndexOf:ea.operands[1] iv:iv self:selfId defs:def depth:0];
            // …and in a grid, the point's flat index plus captured integers.
            if (guards && !sx.affine)
                sx = [self gridSymIndexOf:ea.operands[1] iv:iv self:selfId ivars:ivars defs:def];
            NSValue* sv = [NSValue valueWithBytes:&sx objCType:@encode(XTParSym)];
            // A symbolic write with stride k != 0 is no scatter: items write
            // distinct elements, and the guard settles it against the reads.
            BOOL symStrided = sx.affine && sx.k != 0;
            // §4: a write the shapes above do not cover (a scatter, or every
            // item writing one element) is legal but unprovable: a warning,
            // the first one per block.
            if (isStore && !*scatter && !symStrided && (!x.affine || x.k == 0))
                *scatter = x.affine
                               ? [NSString stringWithFormat:@"'%@%@' from every work item", shownName(buf), shownIndex(x)]
                               : [NSString stringWithFormat:@"'%@' at an index computed from data", shownName(buf)];
            if (isStore)
                {
                if (!writes[buf])
                    writes[buf] = [NSMutableArray array];
                [writes[buf] addObject:@[ xv, sv ]];
                }
            else
                [reads addObject:@[ buf, xv, sv ]];
            }
        }
    for (NSArray* r in reads)
        {
        NSArray<NSArray*>* ws = writes[r[0]];
        if (!ws.count)
            continue;
        XTParIndex rx;
        [(NSValue*)r[1] getValue:&rx];
        XTParSym rs;
        [(NSValue*)r[2] getValue:&rs];
        XTParIndex wx = { NO, 0, 0 };
        BOOL dependent = NO;
        for (NSArray* wp in ws)
            {
            [(NSValue*)wp[0] getValue:&wx];
            if (!parDependent(rx, wx))
                continue;
            XTParSym wsx;
            [(NSValue*)wp[1] getValue:&wsx];
            // The same captured integers on both sides: they differ by a
            // constant, which the plain test settles (a[i + off] read and
            // written by the same item meets no other).
            if (guards && rs.affine && wsx.affine && parSameTerms(rs, wsx)
                && !parDependent((XTParIndex){ YES, rs.k, rs.c }, (XTParIndex){ YES, wsx.k, wsx.c }))
                continue;
            NSString* g = nil;
            if (guards && (parGuardFor(rs, wsx, &g) || parIntervalGuardFor(rs, wsx, &g)))
                {
                if (![guards containsObject:g])
                    [guards addObject:g];
                continue;
                }
            dependent = YES;
            }
        if (!dependent)
            continue;
        [(NSValue*)ws[0][0] getValue:&wx];
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
                    if ([name isEqualToString:@"_xtc_alloc"] || [name isEqualToString:@"_xtc_alloc_object"] || [name hasPrefix:@"_xtc_new"])
                        return @"allocates on the heap ('new')";
                    if (isMathIntrinsic(name))
                        break;
                    // A class's static initialiser, behind its `__sinit_` guard:
                    // the host has run it before any block starts.
                    if ([name hasSuffix:@"$init"] &&
                        [self.module symbolForName:[@"__sinit_" stringByAppendingString:
                                                       [name substringToIndex:name.length - 5]]])
                        break;
                    // A subscript check is allowed by name: outside the program in
                    // a -fbounds-check build, Checked.xc's own body (which writes
                    // to stderr) under -fbounds-check=light.
                    if ([name hasPrefix:@"_xt_check_"] && [allowedExternals() containsObject:name])
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
