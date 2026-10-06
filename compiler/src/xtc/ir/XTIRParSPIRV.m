#import "XTIRParMSL_Private.h"
#import "XTIROpcode.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"

// A `par` block's kernel as a SPIR-V module, for Vulkan (par-spirv-wgsl.md):
// the same kernel and the same header line as the Metal and PTX printers,
// from the same analysis, as binary words.
//
// Vulkan's logical addressing cannot reinterpret bytes, so where Metal copies
// the block object into a byte array, this kernel declares the fields it uses
// as a struct (each member at its byte offset), reads it from binding 0 and
// works on a Function-storage copy. Captured arrays, globals and reduction
// partials are storage buffers at bindings 1.., in the header's order; the
// span (lo, hi, per) is push constants.
//
// Control flow is the dispatch loop: one OpLoopMerge loop around an OpSwitch
// on the block number, every SSA value a Function-storage variable, every
// phi a parallel copy on its edge. It is valid structured SPIR-V for any CFG,
// and the drivers' compilers promote the variables to registers.
//
// Pointers are not values in logical addressing: each pointer SSA value is a
// recipe (a base variable and an access chain), resolved at its load or store.
//
// Exactness: Vulkan rounds OpFAdd, OpFSub and OpFMul correctly but not
// OpFDiv or square roots, and has no precise sin, cos, exp, log or pow. A
// block whose goal is accuracy and that uses one stays on the CPU; one whose
// goal is speed takes the GPU's version.
//
// 8- and 16-bit values and bools in memory, exactly, on any Vulkan device (no
// 8/16-bit storage extension), as WGSL has to: an array of them is bound as an
// array of 32-bit words; a load reads its word and shifts and masks; a store
// clears its bits with OpAtomicAnd and sets them with OpAtomicOr on the word,
// because the work item next door may be writing the other bytes of the same
// word, and those updates commute. A captured narrow value is read from the
// 32-bit word of the argument block that holds it.

// SPIR-V opcodes and enumerants used here.
enum
{
    SpvOpExtInstImport = 11, SpvOpExtInst = 12, SpvOpMemoryModel = 14, SpvOpEntryPoint = 15,
    SpvOpExecutionMode = 16, SpvOpCapability = 17, SpvOpTypeVoid = 19, SpvOpTypeBool = 20,
    SpvOpTypeInt = 21, SpvOpTypeFloat = 22, SpvOpTypeVector = 23, SpvOpTypeRuntimeArray = 29,
    SpvOpTypeStruct = 30, SpvOpTypePointer = 32, SpvOpTypeFunction = 33, SpvOpConstantTrue = 41,
    SpvOpConstantFalse = 42, SpvOpConstant = 43, SpvOpFunction = 54, SpvOpFunctionParameter = 55,
    SpvOpFunctionEnd = 56, SpvOpFunctionCall = 57, SpvOpVariable = 59, SpvOpLoad = 61, SpvOpStore = 62,
    SpvOpAccessChain = 65, SpvOpDecorate = 71, SpvOpMemberDecorate = 72, SpvOpCompositeExtract = 81,
    SpvOpConvertFToU = 109, SpvOpConvertFToS = 110, SpvOpConvertSToF = 111, SpvOpConvertUToF = 112,
    SpvOpUConvert = 113, SpvOpSConvert = 114, SpvOpFConvert = 115, SpvOpBitcast = 124,
    SpvOpSNegate = 126, SpvOpFNegate = 127, SpvOpIAdd = 128, SpvOpFAdd = 129, SpvOpISub = 130,
    SpvOpFSub = 131, SpvOpIMul = 132, SpvOpFMul = 133, SpvOpUDiv = 134, SpvOpSDiv = 135, SpvOpFDiv = 136,
    SpvOpUMod = 137, SpvOpSRem = 138, SpvOpLogicalEqual = 164, SpvOpLogicalNotEqual = 165,
    SpvOpLogicalAnd = 167, SpvOpLogicalNot = 168, SpvOpSelect = 169, SpvOpIEqual = 170,
    SpvOpINotEqual = 171, SpvOpUGreaterThan = 172, SpvOpSGreaterThan = 173, SpvOpUGreaterThanEqual = 174,
    SpvOpSGreaterThanEqual = 175, SpvOpULessThan = 176, SpvOpSLessThan = 177, SpvOpULessThanEqual = 178,
    SpvOpSLessThanEqual = 179, SpvOpFOrdEqual = 180, SpvOpFUnordNotEqual = 183, SpvOpFOrdLessThan = 184,
    SpvOpFOrdGreaterThan = 186, SpvOpFOrdLessThanEqual = 188, SpvOpFOrdGreaterThanEqual = 190,
    SpvOpAtomicAnd = 240, SpvOpAtomicOr = 241,
    SpvOpShiftRightLogical = 194, SpvOpShiftRightArithmetic = 195, SpvOpShiftLeftLogical = 196,
    SpvOpBitwiseOr = 197, SpvOpBitwiseXor = 198, SpvOpBitwiseAnd = 199, SpvOpNot = 200,
    SpvOpLoopMerge = 246, SpvOpSelectionMerge = 247, SpvOpLabel = 248, SpvOpBranch = 249,
    SpvOpBranchConditional = 250, SpvOpSwitch = 251, SpvOpReturn = 253, SpvOpReturnValue = 254, SpvOpUnreachable = 255,
};
enum
{
    SpvStorageInput = 1, SpvStoragePushConstant = 9, SpvStorageStorageBuffer = 12, SpvStorageFunction = 7,
    SpvDecBlock = 2, SpvDecArrayStride = 6, SpvDecNonWritable = 24, SpvDecBuiltIn = 11, SpvDecBinding = 33,
    SpvDecDescriptorSet = 34, SpvDecOffset = 35, SpvBuiltInGlobalInvocationId = 28,
    SpvCapShader = 1, SpvCapFloat64 = 10, SpvCapInt64 = 11,
    // GLSL.std.450
    GlslFAbs = 4, GlslSAbs = 5, GlslFloor = 8, GlslSin = 13, GlslCos = 14, GlslPow = 26, GlslExp = 27,
    GlslLog = 28, GlslSqrt = 31, GlslFMin = 37, GlslUMin = 38, GlslSMin = 39, GlslFMax = 40, GlslUMax = 41,
    GlslSMax = 42, GlslFma = 50,
};

static const uint32_t kExit = 0xffffffffu;

// ── the module being built ──────────────────────────────────────────────────

// One SPIR-V module: its sections in the order the format requires, ids, and
// caches so each type and constant is declared once. Everything is appended
// in the order the printer asks, so the port produces the same words.
@interface XTSpvModule : NSObject
@property(nonatomic) uint32_t bound;
@property(nonatomic) NSMutableArray<NSNumber*>* caps;
@property(nonatomic) NSMutableArray<NSNumber*>* head;       // ext imports, memory model, entry, modes
@property(nonatomic) NSMutableArray<NSNumber*>* decos;
@property(nonatomic) NSMutableArray<NSNumber*>* globals;    // types, constants, module variables
@property(nonatomic) NSMutableArray<NSNumber*>* funcs;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* cache;
@property(nonatomic) BOOL usesInt64;
@property(nonatomic) BOOL usesFloat64;
@property(nonatomic) uint32_t glsl;                         // the GLSL.std.450 import, 0 until used
@end

@implementation XTSpvModule

- (instancetype)init
    {
    if ((self = [super init]))
        {
        _bound = 1;
        _caps = [NSMutableArray array];
        _head = [NSMutableArray array];
        _decos = [NSMutableArray array];
        _globals = [NSMutableArray array];
        _funcs = [NSMutableArray array];
        _cache = [NSMutableDictionary dictionary];
        }
    return self;
    }

- (uint32_t)newId
    {
    return _bound++;
    }

static void spvOp(NSMutableArray<NSNumber*>* sec, uint32_t op, NSArray<NSNumber*>* words)
    {
    [sec addObject:@(((uint32_t)(words.count + 1) << 16) | op)];
    [sec addObjectsFromArray:words];
    }

// A string operand: UTF-8, NUL-terminated, padded to a word.
static NSArray<NSNumber*>* spvString(NSString* s)
    {
    NSMutableData* d = [[s dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    NSUInteger pad = 4 - d.length % 4;
    [d increaseLengthBy:pad];
    NSMutableArray<NSNumber*>* w = [NSMutableArray array];
    const uint8_t* b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i += 4)
        [w addObject:@((uint32_t)b[i] | (uint32_t)b[i + 1] << 8 | (uint32_t)b[i + 2] << 16 | (uint32_t)b[i + 3] << 24)];
    return w;
    }

// A cached global declaration: `key` names it; `make` appends it with the id given.
- (uint32_t)cached:(NSString*)key op:(uint32_t)op words:(NSArray<NSNumber*>*)words resultFirst:(BOOL)rf
    {
    NSNumber* have = self.cache[key];
    if (have)
        return have.unsignedIntValue;
    uint32_t i = [self newId];
    NSMutableArray<NSNumber*>* w = [NSMutableArray array];
    if (rf)
        [w addObject:@(i)];
    [w addObjectsFromArray:words];
    spvOp(self.globals, op, w);
    self.cache[key] = @(i);
    return i;
    }

- (uint32_t)typeVoid
    {
    return [self cached:@"void" op:SpvOpTypeVoid words:@[] resultFirst:YES];
    }

- (uint32_t)typeBool
    {
    return [self cached:@"bool" op:SpvOpTypeBool words:@[] resultFirst:YES];
    }

- (uint32_t)typeInt:(uint32_t)w
    {
    if (w == 64)
        self.usesInt64 = YES;
    return [self cached:[NSString stringWithFormat:@"i%u", w] op:SpvOpTypeInt words:@[ @(w), @0 ] resultFirst:YES];
    }

- (uint32_t)typeFloat:(uint32_t)w
    {
    if (w == 64)
        self.usesFloat64 = YES;
    return [self cached:[NSString stringWithFormat:@"f%u", w] op:SpvOpTypeFloat words:@[ @(w) ] resultFirst:YES];
    }

- (uint32_t)pointer:(uint32_t)sc to:(uint32_t)t
    {
    return [self cached:[NSString stringWithFormat:@"p%u_%u", sc, t] op:SpvOpTypePointer
                  words:@[ @(sc), @(t) ] resultFirst:YES];
    }

- (uint32_t)constant:(uint32_t)type bits:(uint64_t)bits wide:(BOOL)wide
    {
    NSString* key = [NSString stringWithFormat:@"c%u_%llu", type, (unsigned long long)bits];
    NSArray* w = wide ? @[ @(type), @0, @((uint32_t)bits), @((uint32_t)(bits >> 32)) ]
                      : @[ @(type), @0, @((uint32_t)bits) ];
    NSNumber* have = self.cache[key];
    if (have)
        return have.unsignedIntValue;
    uint32_t i = [self newId];
    NSMutableArray* ww = [w mutableCopy];
    ww[1] = @(i);
    spvOp(self.globals, SpvOpConstant, ww);
    self.cache[key] = @(i);
    return i;
    }

- (uint32_t)constBool:(BOOL)v
    {
    uint32_t b = [self typeBool];
    NSString* key = v ? @"true" : @"false";
    NSNumber* have = self.cache[key];
    if (have)
        return have.unsignedIntValue;
    uint32_t i = [self newId];
    spvOp(self.globals, v ? SpvOpConstantTrue : SpvOpConstantFalse, @[ @(b), @(i) ]);
    self.cache[key] = @(i);
    return i;
    }

- (uint32_t)u32:(uint32_t)v
    {
    return [self constant:[self typeInt:32] bits:v wide:NO];
    }

- (uint32_t)glslImport
    {
    if (!self.glsl)
        {
        self.glsl = [self newId];
        NSMutableArray* w = [NSMutableArray arrayWithObject:@(self.glsl)];
        [w addObjectsFromArray:spvString(@"GLSL.std.450")];
        // Imports go first in the head section.
        NSMutableArray* sec = [NSMutableArray array];
        spvOp(sec, SpvOpExtInstImport, w);
        [self.head replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:sec];
        }
    return self.glsl;
    }

- (NSData*)words
    {
    NSMutableArray<NSNumber*>* all = [NSMutableArray array];
    [all addObjectsFromArray:@[ @0x07230203u, @0x00010600u, @0u, @(self.bound), @0u ]];
    NSMutableArray* caps = [NSMutableArray array];
    spvOp(caps, SpvOpCapability, @[ @(SpvCapShader) ]);
    if (self.usesInt64)
        spvOp(caps, SpvOpCapability, @[ @(SpvCapInt64) ]);
    if (self.usesFloat64)
        spvOp(caps, SpvOpCapability, @[ @(SpvCapFloat64) ]);
    [all addObjectsFromArray:caps];
    [all addObjectsFromArray:self.head];
    [all addObjectsFromArray:self.decos];
    [all addObjectsFromArray:self.globals];
    [all addObjectsFromArray:self.funcs];
    NSMutableData* d = [NSMutableData dataWithLength:all.count * 4];
    uint8_t* p = d.mutableBytes;
    for (NSUInteger i = 0; i < all.count; i++)
        {
        uint32_t v = all[i].unsignedIntValue;
        p[4 * i] = (uint8_t)v;
        p[4 * i + 1] = (uint8_t)(v >> 8);
        p[4 * i + 2] = (uint8_t)(v >> 16);
        p[4 * i + 3] = (uint8_t)(v >> 24);
        }
    return d;
    }

@end

// ── the printer ─────────────────────────────────────────────────────────────

// Where a pointer value points, as an access chain: a base variable and the
// indexes into it (constant member numbers, then at most one dynamic index,
// held in a variable).
@interface XTSpvRecipe : NSObject
@property(nonatomic) uint32_t base;          // the variable
@property(nonatomic) uint32_t storage;       // its storage class
@property(nonatomic) NSArray<NSNumber*>* members;  // constant ids
@property(nonatomic) uint32_t indexVar;      // a Function variable holding the element index, or 0
@property(nonatomic) uint32_t indexType;     // that index's type id
@property(nonatomic) XTIRType* pointee;
@property(nonatomic) BOOL readOnly;
@property(nonatomic) BOOL words;            // a narrow element of a buffer of 32-bit words
@property(nonatomic) uint32_t wordShift;    // a narrow captured value: its bit offset in its word, + 1 (0: none)
@end

@implementation XTSpvRecipe
@end

// One function being printed (the kernel or a helper).
@interface XTSpvFunc : NSObject
@property(nonatomic) NSMutableArray<NSNumber*>* vars;     // its Function variables, first in the entry block
@property(nonatomic) NSMutableArray<NSNumber*>* code;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* varOf;      // value -> variable
@property(nonatomic) NSMutableDictionary<NSNumber*, XTSpvRecipe*>* recipeOf;  // pointer value -> recipe
@property(nonatomic) uint32_t pcVar;
@property(nonatomic) uint32_t retVar;
@property(nonatomic) uint32_t loopContinue;
@property(nonatomic) NSMutableSet<NSNumber*>* used;        // values some instruction reads
// The structured walk (spvStructured…): a dry run only checks the shape; the
// current block is open (not yet ended by a branch); each loop header's
// continue target and merge; where the kernel's return goes.
@property(nonatomic) BOOL dry;
@property(nonatomic) BOOL open;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* loopCont;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* loopMerge;
@property(nonatomic) uint32_t exitLabel;
@end

@implementation XTSpvFunc
@end

static NSString* spvBareName(NSString* callee)
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

static NSString* spvShownName(NSString* irName)
    {
    NSRange r = [irName rangeOfString:@"__"];
    NSString* s = (r.location != NSNotFound && r.location > 0) ? [irName substringToIndex:r.location] : irName;
    return [s stringByReplacingOccurrencesOfString:@"$" withString:@"."];
    }

static BOOL spvSigned(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI8 || t.kind == XTIRTypeKindI16 || t.kind == XTIRTypeKindI32 ||
           t.kind == XTIRTypeKindI64;
    }

static BOOL spvIsFloat(XTIRType* t)
    {
    return t.kind == XTIRTypeKindF32 || t.kind == XTIRTypeKindF64;
    }

// The width of an 8- or 16-bit type (held in 32 bits); 0 for any other.
// The bytes of a value that memory holds narrower than a 32-bit word: an 8-
// or 16-bit integer, or a bool (one byte). 0 for any other type.
static uint32_t spvNarrowBytes(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindBool: return 1;
        case XTIRTypeKindI16: case XTIRTypeKindU16: return 2;
        default: return 0;
        }
    }

static uint32_t spvNarrowBits(XTIRType* t)
    {
    switch (t.kind)
        {
        case XTIRTypeKindI8: case XTIRTypeKindU8: return 8;
        case XTIRTypeKindI16: case XTIRTypeKindU16: return 16;
        default: return 0;
        }
    }

static BOOL spvNarrowSigned(XTIRType* t)
    {
    return t.kind == XTIRTypeKindI8 || t.kind == XTIRTypeKindI16;
    }

@interface XTIRParMSL (SPIRVState)
@property(nonatomic) XTSpvModule* spv;
@property(nonatomic) XTSpvFunc* sf;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* spvHelpers;   // callee -> function id
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* memberOf;     // object field -> member index
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* narrowShiftOf; // narrow field -> bit offset in its word
@property(nonatomic) NSMutableSet<NSNumber*>* wordBufs;                         // buffer variables of 32-bit words
@property(nonatomic) uint32_t localObj;            // the kernel's Function copy of the object
@property(nonatomic) uint32_t localObjType;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* bufVar;       // field / global index -> variable
@end

#import <objc/runtime.h>

@implementation XTIRParMSL (SPIRVState)

static char kSpv, kSf, kHelpers, kMember, kLocal, kLocalT, kBufVar, kNarrowShift, kWordBufs;

- (NSMutableDictionary*)narrowShiftOf { return objc_getAssociatedObject(self, &kNarrowShift); }
- (void)setNarrowShiftOf:(NSMutableDictionary*)v { objc_setAssociatedObject(self, &kNarrowShift, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableSet*)wordBufs { return objc_getAssociatedObject(self, &kWordBufs); }
- (void)setWordBufs:(NSMutableSet*)v { objc_setAssociatedObject(self, &kWordBufs, v, OBJC_ASSOCIATION_RETAIN); }

- (XTSpvModule*)spv { return objc_getAssociatedObject(self, &kSpv); }
- (void)setSpv:(XTSpvModule*)v { objc_setAssociatedObject(self, &kSpv, v, OBJC_ASSOCIATION_RETAIN); }
- (XTSpvFunc*)sf { return objc_getAssociatedObject(self, &kSf); }
- (void)setSf:(XTSpvFunc*)v { objc_setAssociatedObject(self, &kSf, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableDictionary*)spvHelpers { return objc_getAssociatedObject(self, &kHelpers); }
- (void)setSpvHelpers:(NSMutableDictionary*)v { objc_setAssociatedObject(self, &kHelpers, v, OBJC_ASSOCIATION_RETAIN); }
- (NSMutableDictionary*)memberOf { return objc_getAssociatedObject(self, &kMember); }
- (void)setMemberOf:(NSMutableDictionary*)v { objc_setAssociatedObject(self, &kMember, v, OBJC_ASSOCIATION_RETAIN); }
- (uint32_t)localObj { return [objc_getAssociatedObject(self, &kLocal) unsignedIntValue]; }
- (void)setLocalObj:(uint32_t)v { objc_setAssociatedObject(self, &kLocal, @(v), OBJC_ASSOCIATION_RETAIN); }
- (uint32_t)localObjType { return [objc_getAssociatedObject(self, &kLocalT) unsignedIntValue]; }
- (void)setLocalObjType:(uint32_t)v { objc_setAssociatedObject(self, &kLocalT, @(v), OBJC_ASSOCIATION_RETAIN); }
- (NSMutableDictionary*)bufVar { return objc_getAssociatedObject(self, &kBufVar); }
- (void)setBufVar:(NSMutableDictionary*)v { objc_setAssociatedObject(self, &kBufVar, v, OBJC_ASSOCIATION_RETAIN); }

@end

@implementation XTIRParMSL (SPIRV)

// ── types and values ────────────────────────────────────────────────────────

// A scalar type's id; 0 for a type this cut does not print.
- (uint32_t)spvType:(XTIRType*)t
    {
    switch (t.kind)
        {
        // 8- and 16-bit values live in 32 bits, sign- or zero-extended by
        // their own signedness, wrapped after every operation (spvCanon).
        case XTIRTypeKindI8: case XTIRTypeKindU8: case XTIRTypeKindI16: case XTIRTypeKindU16:
        case XTIRTypeKindI32: case XTIRTypeKindU32: return [self.spv typeInt:32];
        case XTIRTypeKindI64: case XTIRTypeKindU64: return [self.spv typeInt:64];
        case XTIRTypeKindF32: return [self.spv typeFloat:32];
        case XTIRTypeKindF64: return [self.spv typeFloat:64];
        case XTIRTypeKindBool: return [self.spv typeBool];
        default: return 0;
        }
    }

- (void)emit:(uint32_t)op words:(NSArray<NSNumber*>*)w
    {
    spvOp(self.sf.code, op, w);
    }

// A result-producing instruction into the current function: its new id.
- (uint32_t)emit:(uint32_t)op type:(uint32_t)t args:(NSArray<NSNumber*>*)a
    {
    uint32_t r = [self.spv newId];
    NSMutableArray* w = [NSMutableArray arrayWithObjects:@(t), @(r), nil];
    [w addObjectsFromArray:a];
    spvOp(self.sf.code, op, w);
    return r;
    }

// A Function variable of type t (declared at the head of the entry block).
- (uint32_t)localVar:(uint32_t)t
    {
    uint32_t p = [self.spv pointer:SpvStorageFunction to:t];
    uint32_t v = [self.spv newId];
    spvOp(self.sf.vars, SpvOpVariable, @[ @(p), @(v), @(SpvStorageFunction) ]);
    return v;
    }

- (uint32_t)label
    {
    return [self.spv newId];
    }

- (void)place:(uint32_t)label
    {
    [self emit:SpvOpLabel words:@[ @(label) ]];
    }

// A 32-bit value wrapped to narrow type t, in t's form: masked for an
// unsigned type, sign-extended from its top bit for a signed one. Any other
// type: v unchanged.
- (uint32_t)spvCanon:(uint32_t)v type:(XTIRType*)t
    {
    uint32_t bits = spvNarrowBits(t);
    if (!bits)
        return v;
    uint32_t i32 = [self.spv typeInt:32];
    if (!spvNarrowSigned(t))
        return [self emit:SpvOpBitwiseAnd type:i32 args:@[ @(v), @([self.spv u32:(1u << bits) - 1]) ]];
    uint32_t sh = [self.spv u32:32 - bits];
    uint32_t up = [self emit:SpvOpShiftLeftLogical type:i32 args:@[ @(v), @(sh) ]];
    return [self emit:SpvOpShiftRightArithmetic type:i32 args:@[ @(up), @(sh) ]];
    }

// An operand's value (an id), as type `want` for an immediate; 0 when it cannot be.
- (uint32_t)value:(XTIROperand*)op type:(nullable XTIRType*)want
    {
    switch (op.kind)
        {
        case XTIROperandKindUse:
            {
            NSNumber* var = self.sf.varOf[@(op.valueId)];
            XTIRType* t = [self typeOf:op.valueId];
            if (!var)
                {
                // A helper's parameter that was never stored: not reached here,
                // every parameter has a variable.
                return 0;
                }
            return [self emit:SpvOpLoad type:[self spvType:t] args:@[ var ]];
            }
        case XTIROperandKindImmI:
            {
            if (!want)
                return 0;
            if (want.kind == XTIRTypeKindBool)
                return [self.spv constBool:op.intValue != 0];
            uint32_t t = [self spvType:want];
            if (!t || spvIsFloat(want))
                return 0;
            BOOL wide = want.kind == XTIRTypeKindI64 || want.kind == XTIRTypeKindU64;
            int64_t iv = op.intValue;
            uint32_t nb = spvNarrowBits(want);
            if (nb)
                {
                // In the type's 32-bit form.
                uint64_t mask = (1ull << nb) - 1;
                iv = (int64_t)((uint64_t)iv & mask);
                if (spvNarrowSigned(want) && (iv >> (nb - 1)) & 1)
                    iv = iv - (int64_t)(1ull << nb);
                }
            return [self.spv constant:t bits:wide ? (uint64_t)iv : (uint64_t)(uint32_t)iv wide:wide];
            }
        case XTIROperandKindImmF:
            {
            uint64_t raw = op.floatRawBytes;
            if (want.kind == XTIRTypeKindF64)
                return [self.spv constant:[self.spv typeFloat:64] bits:raw wide:YES];
            if (want.kind != XTIRTypeKindF32)
                return 0;
            double d;
            memcpy(&d, &raw, sizeof d);
            float f = (float)d;
            uint32_t bits;
            memcpy(&bits, &f, sizeof bits);
            return [self.spv constant:[self.spv typeFloat:32] bits:bits wide:NO];
            }
        default:
            return 0;
        }
    }

- (void)setResult:(XTIRInsn*)i to:(uint32_t)v
    {
    [self emit:SpvOpStore words:@[ self.sf.varOf[@(i.result.valueId)], @(v) ]];
    }

// The id of a pointer to where `recipe` points (an OpAccessChain, or the base).
- (uint32_t)address:(XTSpvRecipe*)r
    {
    uint32_t et = [self spvType:r.pointee];
    if (!et)
        return 0;
    NSMutableArray* idx = [NSMutableArray arrayWithArray:r.members];
    if (r.indexVar)
        [idx addObject:@([self emit:SpvOpLoad type:r.indexType args:@[ @(r.indexVar) ]])];
    if (!idx.count)
        return r.base;
    NSMutableArray* a = [NSMutableArray arrayWithObject:@(r.base)];
    [a addObjectsFromArray:idx];
    return [self emit:SpvOpAccessChain type:[self.spv pointer:r.storage to:et] args:a];
    }

// A narrow element of a word buffer: a pointer to its 32-bit word, and in
// *shift the bit offset of its bits in that word (a u32 id).
- (uint32_t)wordAddress:(XTSpvRecipe*)r shift:(uint32_t*)shift
    {
    uint32_t u32t = [self.spv typeInt:32];
    uint32_t n = spvNarrowBytes(r.pointee);
    if (!n || !r.indexVar)
        return 0;
    uint32_t idx = [self emit:SpvOpLoad type:r.indexType args:@[ @(r.indexVar) ]];
    if (r.indexType != u32t)
        idx = [self emit:SpvOpUConvert type:u32t args:@[ @(idx) ]];
    uint32_t word = [self emit:SpvOpShiftRightLogical type:u32t args:@[ @(idx), @([self.spv u32:n == 1 ? 2 : 1]) ]];
    uint32_t low = [self emit:SpvOpBitwiseAnd type:u32t args:@[ @(idx), @([self.spv u32:n == 1 ? 3 : 1]) ]];
    *shift = [self emit:SpvOpShiftLeftLogical type:u32t args:@[ @(low), @([self.spv u32:n == 1 ? 3 : 4]) ]];
    NSMutableArray* a = [NSMutableArray arrayWithObject:@(r.base)];
    [a addObjectsFromArray:r.members];
    [a addObject:@(word)];
    return [self emit:SpvOpAccessChain type:[self.spv pointer:r.storage to:u32t] args:a];
    }

// A narrow value from its word: shifted down, then masked (unsigned),
// sign-extended (signed) or compared with 0 (bool), in the value's own form.
- (uint32_t)narrowFrom:(uint32_t)word shift:(uint32_t)shift type:(XTIRType*)t
    {
    uint32_t u32t = [self.spv typeInt:32];
    uint32_t v = [self emit:SpvOpShiftRightLogical type:u32t args:@[ @(word), @(shift) ]];
    if (t.kind == XTIRTypeKindBool)
        {
        uint32_t b = [self emit:SpvOpBitwiseAnd type:u32t args:@[ @(v), @([self.spv u32:0xFF]) ]];
        return [self emit:SpvOpINotEqual type:[self.spv typeBool] args:@[ @(b), @([self.spv u32:0]) ]];
        }
    if (spvNarrowSigned(t))
        return [self spvCanon:v type:t];
    return [self emit:SpvOpBitwiseAnd type:u32t args:@[ @(v), @([self.spv u32:(1u << spvNarrowBits(t)) - 1]) ]];
    }

- (uint32_t)narrowLoad:(XTSpvRecipe*)r
    {
    uint32_t u32t = [self.spv typeInt:32];
    if (r.wordShift)
        {
        // A captured value: its word of the object's copy.
        NSMutableArray* a = [NSMutableArray arrayWithObject:@(r.base)];
        [a addObjectsFromArray:r.members];
        uint32_t p = [self emit:SpvOpAccessChain type:[self.spv pointer:r.storage to:u32t] args:a];
        uint32_t word = [self emit:SpvOpLoad type:u32t args:@[ @(p) ]];
        return [self narrowFrom:word shift:[self.spv u32:r.wordShift - 1] type:r.pointee];
        }
    uint32_t shift = 0;
    uint32_t p = [self wordAddress:r shift:&shift];
    if (!p)
        return 0;
    uint32_t word = [self emit:SpvOpLoad type:u32t args:@[ @(p) ]];
    return [self narrowFrom:word shift:shift type:r.pointee];
    }

// Clear the element's bits in its word, then set them: two atomic updates, so
// that a neighbour writing the other bytes of the word at the same time keeps
// its bytes. Device scope, relaxed: they commute, and nothing is ordered by them.
- (BOOL)narrowStore:(XTSpvRecipe*)r value:(uint32_t)v
    {
    uint32_t u32t = [self.spv typeInt:32];
    uint32_t shift = 0;
    uint32_t p = [self wordAddress:r shift:&shift];
    if (!p)
        return NO;
    uint32_t mask = [self.spv u32:spvNarrowBytes(r.pointee) == 1 ? 0xFF : 0xFFFF];
    uint32_t bits = r.pointee.kind == XTIRTypeKindBool
                        ? [self emit:SpvOpSelect type:u32t args:@[ @(v), @([self.spv u32:1]), @([self.spv u32:0]) ]]
                        : [self emit:SpvOpBitwiseAnd type:u32t args:@[ @(v), @(mask) ]];
    uint32_t keep = [self emit:SpvOpNot type:u32t
                          args:@[ @([self emit:SpvOpShiftLeftLogical type:u32t args:@[ @(mask), @(shift) ]]) ]];
    uint32_t scope = [self.spv u32:1];   // Device
    uint32_t sem = [self.spv u32:0];     // relaxed
    [self emit:SpvOpAtomicAnd type:u32t args:@[ @(p), @(scope), @(sem), @(keep) ]];
    [self emit:SpvOpAtomicOr type:u32t
          args:@[ @(p), @(scope), @(sem), @([self emit:SpvOpShiftLeftLogical type:u32t args:@[ @(bits), @(shift) ]]) ]];
    return YES;
    }

// ── instructions ────────────────────────────────────────────────────────────

- (BOOL)spvBinary:(XTIRInsn*)i
    {
    XTIRType* t = i.result.type;
    uint32_t ty = [self spvType:t];
    uint32_t a = [self value:i.operands[0] type:t];
    uint32_t b = [self value:i.operands[1] type:t];
    if (!ty || !a || !b)
        return NO;
    // A narrow operand is held in its own type's form; an operation of the
    // other signedness rereads its bits that way first.
    uint32_t nb = spvNarrowBits(t);
    if (nb)
        {
        BOOL wantsUnsigned = i.opcode == XTIROpUDiv || i.opcode == XTIROpURem || i.opcode == XTIROpLShr;
        BOOL wantsSigned = i.opcode == XTIROpSDiv || i.opcode == XTIROpSRem || i.opcode == XTIROpAShr;
        XTIRType* as = nil;
        if (wantsUnsigned && spvNarrowSigned(t))
            as = nb == 8 ? [XTIRType u8Type] : [XTIRType u16Type];
        else if (wantsSigned && !spvNarrowSigned(t))
            as = nb == 8 ? [XTIRType i8Type] : [XTIRType i16Type];
        if (as)
            {
            a = [self spvCanon:a type:as];
            if (i.opcode != XTIROpLShr && i.opcode != XTIROpAShr)
                b = [self spvCanon:b type:as];
            }
        }
    uint32_t op;
    switch (i.opcode)
        {
        case XTIROpAdd: op = SpvOpIAdd; break;
        case XTIROpSub: op = SpvOpISub; break;
        case XTIROpMul: op = SpvOpIMul; break;
        case XTIROpUDiv: op = SpvOpUDiv; break;
        case XTIROpSDiv: op = SpvOpSDiv; break;
        case XTIROpURem: op = SpvOpUMod; break;
        case XTIROpSRem: op = SpvOpSRem; break;
        case XTIROpAnd: op = t.kind == XTIRTypeKindBool ? SpvOpLogicalAnd : SpvOpBitwiseAnd; break;
        case XTIROpOr: op = t.kind == XTIRTypeKindBool ? 166 /* OpLogicalOr */ : SpvOpBitwiseOr; break;
        case XTIROpXor: op = t.kind == XTIRTypeKindBool ? SpvOpLogicalNotEqual : SpvOpBitwiseXor; break;
        case XTIROpShl: op = SpvOpShiftLeftLogical; break;
        case XTIROpLShr: op = SpvOpShiftRightLogical; break;
        case XTIROpAShr: op = SpvOpShiftRightArithmetic; break;
        case XTIROpFAdd: op = SpvOpFAdd; break;
        case XTIROpFSub: op = SpvOpFSub; break;
        case XTIROpFMul: op = SpvOpFMul; break;
        case XTIROpFDiv:
            // Vulkan's division is within 2.5 ULP, not correctly rounded.
            if (!self.fast)
                {
                [self because:@"it divides floats, which a Vulkan GPU does not round exactly, and the block's "
                              @"goal is accuracy"];
                return NO;
                }
            op = SpvOpFDiv;
            break;
        default: return NO;
        }
    [self setResult:i to:[self spvCanon:[self emit:op type:ty args:@[ @(a), @(b) ]] type:t]];
    return YES;
    }

- (BOOL)spvCompare:(XTIRInsn*)i
    {
    XTIRType* t = [self typeOf:i.operands[0].kind == XTIROperandKindUse ? i.operands[0].valueId
                                                                        : i.operands[1].valueId];
    if (!t)
        return NO;
    uint32_t a = [self value:i.operands[0] type:t];
    uint32_t b = [self value:i.operands[1] type:t];
    if (!a || !b)
        return NO;
    uint32_t op;
    if (i.opcode == XTIROpFCmp)
        {
        static const uint32_t fops[] = { SpvOpFOrdEqual, SpvOpFUnordNotEqual, SpvOpFOrdLessThan,
                                         SpvOpFOrdGreaterThan, SpvOpFOrdLessThanEqual, SpvOpFOrdGreaterThanEqual };
        if (i.predicate > XTIRFCmpOGE)
            return NO;
        op = fops[i.predicate];
        }
    else
        {
        static const uint32_t iops[] = { SpvOpIEqual, SpvOpINotEqual, SpvOpSLessThan, SpvOpSGreaterThan,
                                         SpvOpSLessThanEqual, SpvOpSGreaterThanEqual, SpvOpULessThan,
                                         SpvOpUGreaterThan, SpvOpULessThanEqual, SpvOpUGreaterThanEqual };
        if (i.predicate > XTIRICmpUGE)
            return NO;
        op = iops[i.predicate];
        if (t.kind == XTIRTypeKindBool)
            {
            if (i.predicate == XTIRICmpEQ)
                op = SpvOpLogicalEqual;
            else if (i.predicate == XTIRICmpNE)
                op = SpvOpLogicalNotEqual;
            else
                return NO;
            }
        }
    [self setResult:i to:[self emit:op type:[self.spv typeBool] args:@[ @(a), @(b) ]]];
    return YES;
    }

- (BOOL)spvConvert:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    XTIRType* st = i.operands[0].kind == XTIROperandKindUse ? [self typeOf:i.operands[0].valueId] : rt;
    uint32_t a = [self value:i.operands[0] type:st];
    uint32_t ty = [self spvType:rt];
    if (!a || !ty || ![self spvType:st])
        return NO;
    BOOL sameWidth = st.byteWidth == rt.byteWidth;
    uint32_t v = 0;
    if (st.kind == XTIRTypeKindBool && rt.kind != XTIRTypeKindBool)
        {
        // true is 1, false 0, in the result's type.
        XTIROperand* one = [XTIROperand immIWithType:rt value:1];
        XTIROperand* zero = [XTIROperand immIWithType:rt value:0];
        if (spvIsFloat(rt))
            return NO;
        v = [self emit:SpvOpSelect type:ty args:@[ @(a), @([self value:one type:rt]), @([self value:zero type:rt]) ]];
        }
    else if (rt.kind == XTIRTypeKindBool)
        {
        if (st.kind == XTIRTypeKindBool)
            v = a;
        else if (spvIsFloat(st))
            return NO;
        else
            v = [self emit:SpvOpINotEqual type:ty
                      args:@[ @(a), @([self value:[XTIROperand immIWithType:st value:0] type:st]) ]];
        }
    else
        {
        // Integers: the source as its 32- or 64-bit value with the
        // extension the opcode asks for, converted to the result's width,
        // then wrapped to a narrow result.
        uint32_t sb = spvNarrowBits(st);
        BOOL sWide = st.kind == XTIRTypeKindI64 || st.kind == XTIRTypeKindU64;
        BOOL rWide = rt.kind == XTIRTypeKindI64 || rt.kind == XTIRTypeKindU64;
        uint32_t i32 = [self.spv typeInt:32];
        switch (i.opcode)
            {
            case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc: case XTIROpCopy:
                {
                if (spvIsFloat(st) || spvIsFloat(rt))
                    {
                    if (i.opcode != XTIROpCopy)
                        return NO;
                    if (spvIsFloat(st) && spvIsFloat(rt))
                        v = sameWidth ? a : [self emit:SpvOpFConvert type:ty args:@[ @(a) ]];
                    else if (spvIsFloat(rt))
                        v = [self emit:spvSigned(st) ? SpvOpConvertSToF : SpvOpConvertUToF type:ty args:@[ @(a) ]];
                    else
                        v = [self spvCanon:[self emit:spvSigned(rt) ? SpvOpConvertFToS : SpvOpConvertFToU type:ty
                                                 args:@[ @(a) ]] type:rt];
                    break;
                    }
                BOOL extSigned = i.opcode == XTIROpSExt || (i.opcode != XTIROpZExt && spvSigned(st));
                uint32_t x = a;
                if (sb && extSigned != spvNarrowSigned(st))
                    {
                    // Reread the narrow bits with the other signedness.
                    XTIRType* as = extSigned ? (sb == 8 ? [XTIRType i8Type] : [XTIRType i16Type])
                                             : (sb == 8 ? [XTIRType u8Type] : [XTIRType u16Type]);
                    x = [self spvCanon:x type:as];
                    }
                if (sWide != rWide)
                    x = [self emit:rWide ? (extSigned ? SpvOpSConvert : SpvOpUConvert) : SpvOpUConvert
                              type:rWide ? [self.spv typeInt:64] : i32 args:@[ @(x) ]];
                v = [self spvCanon:x type:rt];
                break;
                }
            case XTIROpSIToFp: v = [self emit:SpvOpConvertSToF type:ty args:@[ @(a) ]]; break;
            case XTIROpUIToFp: v = [self emit:SpvOpConvertUToF type:ty args:@[ @(a) ]]; break;
            case XTIROpFpToSI: v = [self spvCanon:[self emit:SpvOpConvertFToS type:ty args:@[ @(a) ]] type:rt]; break;
            case XTIROpFpToUI: v = [self spvCanon:[self emit:SpvOpConvertFToU type:ty args:@[ @(a) ]] type:rt]; break;
            default:
                return NO;
            }
        }
    [self setResult:i to:v];
    return YES;
    }

// A maths call by name: its GLSL.std.450 instruction, or 0 when it has none
// here (or none that is exact, for an accuracy block).
- (uint32_t)glslFor:(NSString*)callee type:(XTIRType*)t
    {
    NSString* m = spvBareName(callee);
    BOOL f = spvIsFloat(t);
    if ([m isEqualToString:@"floor"]) return f ? GlslFloor : 0;
    if ([m isEqualToString:@"abs"] || [m isEqualToString:@"fabs"]) return f ? GlslFAbs : spvSigned(t) ? GlslSAbs : 0;
    if ([m isEqualToString:@"min"]) return f ? GlslFMin : spvSigned(t) ? GlslSMin : GlslUMin;
    if ([m isEqualToString:@"max"]) return f ? GlslFMax : spvSigned(t) ? GlslSMax : GlslUMax;
    if (!self.fast)
        return 0;
    // Approximate on Vulkan: a speed block only.
    if ([m isEqualToString:@"sqrt"]) return GlslSqrt;
    if ([m isEqualToString:@"sin"]) return GlslSin;
    if ([m isEqualToString:@"cos"]) return GlslCos;
    if ([m isEqualToString:@"exp"]) return GlslExp;
    if ([m isEqualToString:@"ln"] || [m isEqualToString:@"log"]) return GlslLog;
    if ([m isEqualToString:@"pow"]) return GlslPow;
    if ([m isEqualToString:@"fma"]) return GlslFma;
    return 0;
    }

- (BOOL)spvIsMaths:(NSString*)callee
    {
    NSString* m = spvBareName(callee);
    return [@[ @"sqrt", @"sin", @"cos", @"exp", @"ln", @"log", @"pow", @"floor", @"fma", @"abs", @"fabs", @"min",
               @"max" ] containsObject:m];
    }

- (BOOL)spvCall:(XTIRInsn*)i
    {
    XTIRSymbol* sym = [self.module symbolForId:i.operands[0].symbolId];
    NSString* callee = sym.name;
    if ([callee isEqualToString:@"_xtc_sinit_run"] || [callee hasSuffix:@"$init"])
        return YES;
    XTIRType* rt = i.result.type;
    BOOL isVoid = !rt || rt.kind == XTIRTypeKindMemory;
    NSMutableArray<NSNumber*>* args = [NSMutableArray array];
    NSMutableArray<XTIRType*>* argTypes = [NSMutableArray array];
    for (NSUInteger k = 1; k < i.operands.count; k++)
        {
        XTIROperand* o = i.operands[k];
        if (o.kind == XTIROperandKindUse && [self typeOf:o.valueId].kind == XTIRTypeKindMemory)
            continue;
        XTIRType* at = o.kind == XTIROperandKindUse ? [self typeOf:o.valueId] : rt;
        uint32_t v = [self value:o type:at];
        if (!v)
            return NO;
        [args addObject:@(v)];
        [argTypes addObject:at];
        }
    if ([self spvIsMaths:callee])
        {
        if (isVoid || !args.count)
            return NO;
        uint32_t g = [self glslFor:callee type:rt];
        if (!g)
            {
            [self because:[NSString stringWithFormat:@"it calls %@, which a Vulkan GPU has only in an approximate "
                                                     @"form, and the block's goal is accuracy", spvShownName(callee)]];
            return NO;
            }
        NSMutableArray* a = [NSMutableArray arrayWithObjects:@([self.spv glslImport]), @(g), nil];
        [a addObjectsFromArray:args];
        [self setResult:i to:[self emit:SpvOpExtInst type:[self spvType:rt] args:a]];
        return YES;
        }
    // A function of the program: printed once, as a SPIR-V function.
    NSNumber* fid = self.spvHelpers[callee];
    if (!fid)
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
        h.spv = self.spv;
        h.spvHelpers = self.spvHelpers;
        uint32_t f = [h spvHelper];
        if (!f)
            {
            [self because:[self callFailed:callee helper:h]];
            return NO;
            }
        fid = @(f);
        self.spvHelpers[callee] = fid;
        }
    uint32_t ret = isVoid ? [self.spv typeVoid] : [self spvType:rt];
    if (!ret)
        return NO;
    NSMutableArray* a = [NSMutableArray arrayWithObject:fid];
    [a addObjectsFromArray:args];
    uint32_t r = [self emit:SpvOpFunctionCall type:ret args:a];
    if (!isVoid)
        [self setResult:i to:r];
    return YES;
    }

// A pointer value's recipe from `base` plus one more step.
- (XTSpvRecipe*)recipeFrom:(XTSpvRecipe*)b
    {
    XTSpvRecipe* r = [XTSpvRecipe new];
    r.base = b.base;
    r.storage = b.storage;
    r.members = b.members;
    r.indexVar = b.indexVar;
    r.indexType = b.indexType;
    r.pointee = b.pointee;
    r.readOnly = b.readOnly;
    r.words = b.words;
    r.wordShift = b.wordShift;
    return r;
    }

- (BOOL)spvStatement:(XTIRInsn*)i
    {
    XTIRType* rt = i.result.type;
    // A value nothing reads, from an instruction with no other effect.
    if (i.result && rt.kind != XTIRTypeKindMemory && ![self.sf.used containsObject:@(i.result.valueId)] &&
        i.opcode != XTIROpCall && i.opcode != XTIROpStore)
        return YES;
    switch (i.opcode)
        {
        case XTIROpConst:
            {
            uint32_t v = [self value:i.operands[0] type:rt];
            if (!v)
                return NO;
            [self setResult:i to:v];
            return YES;
            }
        case XTIROpAdd: case XTIROpSub: case XTIROpMul: case XTIROpUDiv: case XTIROpSDiv:
        case XTIROpURem: case XTIROpSRem: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
        case XTIROpShl: case XTIROpLShr: case XTIROpAShr:
        case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv:
            return [self spvBinary:i];
        case XTIROpNot:
            {
            uint32_t a = [self value:i.operands[0] type:rt];
            if (!a)
                return NO;
            [self setResult:i to:[self spvCanon:[self emit:rt.kind == XTIRTypeKindBool ? SpvOpLogicalNot : SpvOpNot
                                                       type:[self spvType:rt] args:@[ @(a) ]] type:rt]];
            return YES;
            }
        case XTIROpNeg:
        case XTIROpFNeg:
            {
            uint32_t a = [self value:i.operands[0] type:rt];
            if (!a)
                return NO;
            [self setResult:i to:[self spvCanon:[self emit:spvIsFloat(rt) ? SpvOpFNegate : SpvOpSNegate
                                                       type:[self spvType:rt] args:@[ @(a) ]] type:rt]];
            return YES;
            }
        case XTIROpFSqrt:
            {
            if (!self.fast)
                {
                [self because:@"it takes a square root, which a Vulkan GPU does not round exactly, and the "
                              @"block's goal is accuracy"];
                return NO;
                }
            uint32_t a = [self value:i.operands[0] type:rt];
            if (!a)
                return NO;
            [self setResult:i to:[self emit:SpvOpExtInst type:[self spvType:rt]
                                       args:@[ @([self.spv glslImport]), @(GlslSqrt), @(a) ]]];
            return YES;
            }
        case XTIROpICmp:
        case XTIROpFCmp:
            return [self spvCompare:i];
        case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc: case XTIROpSIToFp: case XTIROpUIToFp:
        case XTIROpFpToSI: case XTIROpFpToUI: case XTIROpCopy:
            return [self spvConvert:i];
        case XTIROpSelect:
            {
            uint32_t c = [self value:i.operands[0] type:nil];
            uint32_t a = [self value:i.operands[1] type:rt];
            uint32_t b = [self value:i.operands[2] type:rt];
            if (!c || !a || !b)
                return NO;
            [self setResult:i to:[self emit:SpvOpSelect type:[self spvType:rt] args:@[ @(c), @(a), @(b) ]]];
            return YES;
            }
        case XTIROpFieldAddr:
            {
            NSInteger k = [self selfFieldOf:[XTIROperand useWithValueId:i.result.valueId]];
            if (k >= 0)
                {
                // The slot of a captured array: only ever loaded, as the buffer.
                if (self.objLayout.fields[(NSUInteger)k].type.kind == XTIRTypeKindPtr)
                    return YES;
                NSNumber* m = self.memberOf[@(k)];
                if (!m)
                    return NO;
                XTSpvRecipe* r = [XTSpvRecipe new];
                r.base = self.localObj;
                r.storage = SpvStorageFunction;
                r.members = @[ @([self.spv u32:m.unsignedIntValue]) ];
                r.pointee = self.objLayout.fields[(NSUInteger)k].type;
                NSNumber* sh = self.narrowShiftOf[@(k)];
                if (sh)
                    r.wordShift = sh.unsignedIntValue + 1;
                self.sf.recipeOf[@(i.result.valueId)] = r;
                return YES;
                }
            // A field of a struct element: not in this cut.
            return NO;
            }
        case XTIROpElementAddr:
            {
            XTSpvRecipe* b = i.operands[0].kind == XTIROperandKindUse ? self.sf.recipeOf[@(i.operands[0].valueId)]
                                                                      : nil;
            if (!b || !rt.pointeeType)
                return NO;
            XTIRType* it = i.operands[1].kind == XTIROperandKindUse ? [self typeOf:i.operands[1].valueId]
                                                                    : [XTIRType i64Type];
            uint32_t ity = [self spvType:it];
            uint32_t idx = [self value:i.operands[1] type:it];
            if (!ity || !idx || spvIsFloat(it) || it.kind == XTIRTypeKindBool)
                return NO;
            XTSpvRecipe* r = [self recipeFrom:b];
            r.pointee = rt.pointeeType;
            if (b.indexVar)
                {
                // An index on an index: add them (in the first one's type).
                uint32_t prev = [self emit:SpvOpLoad type:b.indexType args:@[ @(b.indexVar) ]];
                if (b.indexType != ity)
                    idx = [self emit:spvSigned(it) ? SpvOpSConvert : SpvOpUConvert type:b.indexType args:@[ @(idx) ]];
                idx = [self emit:SpvOpIAdd type:b.indexType args:@[ @(prev), @(idx) ]];
                ity = b.indexType;
                }
            else if (b.storage == SpvStorageFunction)
                return NO;   // an element of a field of the object: not in this cut
            r.indexVar = [self localVar:ity];
            r.indexType = ity;
            [self emit:SpvOpStore words:@[ @(r.indexVar), @(idx) ]];
            self.sf.recipeOf[@(i.result.valueId)] = r;
            return YES;
            }
        case XTIROpBitcast:
            {
            if (rt.kind == XTIRTypeKindPtr)
                {
                XTSpvRecipe* b = i.operands[0].kind == XTIROperandKindUse
                                     ? self.sf.recipeOf[@(i.operands[0].valueId)] : nil;
                if (!b || b.pointee.byteWidth != rt.pointeeType.byteWidth ||
                    [self spvType:b.pointee] != [self spvType:rt.pointeeType])
                    return NO;
                self.sf.recipeOf[@(i.result.valueId)] = b;
                return YES;
                }
            XTIRType* st = i.operands[0].kind == XTIROperandKindUse ? [self typeOf:i.operands[0].valueId] : rt;
            uint32_t a = [self value:i.operands[0] type:st];
            if (!a || st.byteWidth != rt.byteWidth || ![self spvType:rt])
                return NO;
            // A narrow result is re-wrapped to its own form: (u8) of a negative
            // i8 keeps only the low byte (both live sign- or zero-extended in 32).
            [self setResult:i to:[self spvCanon:[self emit:SpvOpBitcast type:[self spvType:rt] args:@[ @(a) ]] type:rt]];
            return YES;
            }
        case XTIROpLoad:
            {
            NSNumber* buf = self.bufferOf[@(i.result.valueId)];
            if (buf)
                {
                // The captured array itself: its buffer.
                XTSpvRecipe* r = [XTSpvRecipe new];
                r.base = [self.bufVar[buf] unsignedIntValue];
                r.storage = SpvStorageStorageBuffer;
                r.members = @[ @([self.spv u32:0]) ];
                r.pointee = rt.pointeeType;
                r.words = [self.wordBufs containsObject:@(r.base)];
                self.sf.recipeOf[@(i.result.valueId)] = r;
                return YES;
                }
            if (rt.kind == XTIRTypeKindPtr)
                return NO;
            if ([self.sinitOf[@(i.operands[0].valueId)] boolValue])
                {
                [self setResult:i to:[self value:[XTIROperand immIWithType:rt value:2] type:rt]];
                return YES;
                }
            XTSpvRecipe* r = self.sf.recipeOf[@(i.operands[0].valueId)];
            uint32_t ty = [self spvType:rt];
            if (!r || !ty || [self spvType:r.pointee] != ty)
                return NO;
            if (r.words || r.wordShift)
                {
                uint32_t v = [self narrowLoad:r];
                if (!v)
                    return NO;
                [self setResult:i to:v];
                return YES;
                }
            uint32_t p = [self address:r];
            if (!p)
                return NO;
            [self setResult:i to:[self emit:SpvOpLoad type:ty args:@[ @(p) ]]];
            return YES;
            }
        case XTIROpStore:
            {
            if (i.operands[0].kind != XTIROperandKindUse)
                return NO;
            XTSpvRecipe* r = self.sf.recipeOf[@(i.operands[0].valueId)];
            if (!r)
                return NO;
            uint32_t v = [self value:i.operands[1] type:r.pointee];
            if (r.wordShift)
                return NO;   // a captured value: the kernel never writes one
            if (r.words)
                return v && [self narrowStore:r value:v];
            uint32_t p = [self address:r];
            if (!v || !p)
                return NO;
            [self emit:SpvOpStore words:@[ @(p), @(v) ]];
            return YES;
            }
        case XTIROpCall:
            return [self spvCall:i];
        case XTIROpAddrOf:
            {
            if (self.sinitOf[@(i.result.valueId)])
                return YES;
            NSString* g = self.globalOf[@(i.result.valueId)];
            if (!g)
                return NO;
            XTSpvRecipe* r = [XTSpvRecipe new];
            r.base = [self.bufVar[@(-1 - (NSInteger)[self.globals indexOfObject:g])] unsignedIntValue];
            r.storage = SpvStorageStorageBuffer;
            r.members = @[ @([self.spv u32:0]) ];
            r.pointee = rt.pointeeType;
            r.words = [self.wordBufs containsObject:@(r.base)];
            self.sf.recipeOf[@(i.result.valueId)] = r;
            return YES;
            }
        case XTIROpDbgValue:
            return YES;
        default:
            return NO;
        }
    }

// ── control flow: the dispatch loop ─────────────────────────────────────────

// The phi copies for the edge from -> target (each incoming value read
// before any is written, as a parallel copy), then pc; each store is
// conditional on `cond` (an id, or 0 for always): `pick` is the value stored
// when cond holds, the variable's old value otherwise. Straight-line code, so
// a conditional branch needs no construct of its own inside the switch.
- (BOOL)spvEdgeFrom:(XTIRBlock*)from to:(XTIRBlock*)target cond:(uint32_t)cond whenTrue:(BOOL)whenTrue
                vals:(NSMutableArray<NSNumber*>*)vals dsts:(NSMutableArray<NSNumber*>*)dsts
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
        uint32_t v = [self value:in type:phi.result.type];
        if (!v)
            return NO;
        NSNumber* dst = self.sf.varOf[@(phi.result.valueId)];
        if (cond)
            {
            uint32_t ty = [self spvType:phi.result.type];
            uint32_t old = [self emit:SpvOpLoad type:ty args:@[ dst ]];
            v = [self emit:SpvOpSelect type:ty args:whenTrue ? @[ @(cond), @(v), @(old) ] : @[ @(cond), @(old), @(v) ]];
            }
        [vals addObject:@(v)];
        [dsts addObject:dst];
        }
    return YES;
    }

- (void)spvStores:(NSArray<NSNumber*>*)vals dsts:(NSArray<NSNumber*>*)dsts
    {
    for (NSUInteger k = 0; k < vals.count; k++)
        [self emit:SpvOpStore words:@[ dsts[k], vals[k] ]];
    }

- (uint32_t)spvBlockNumber:(XTIRBlock*)b
    {
    return [self.spv u32:[self.blockIndex[b.name] unsignedIntValue]];
    }

// The function's blocks as the dispatch loop, from its entry label onwards
// (the caller has placed the entry label and anything before the loop).
// `exitLabel` is where the loop's merge goes on.
- (BOOL)spvDispatchMerge:(uint32_t)mergeLabel guard:(uint32_t)guard
    {
    XTSpvFunc* f = self.sf;
    uint32_t head = [self label], test = [self label], body = [self label], cont = [self label],
             dflt = [self label];
    f.loopContinue = cont;
    [self emit:SpvOpBranch words:@[ @(head) ]];
    [self place:head];
    [self emit:SpvOpLoopMerge words:@[ @(mergeLabel), @(cont), @0 ]];
    [self emit:SpvOpBranch words:@[ @(test) ]];
    [self place:test];
    uint32_t pc = [self emit:SpvOpLoad type:[self.spv typeInt:32] args:@[ @(f.pcVar) ]];
    uint32_t go = [self emit:SpvOpINotEqual type:[self.spv typeBool] args:@[ @(pc), @([self.spv u32:kExit]) ]];
    if (guard)
        go = [self emit:SpvOpLogicalAnd type:[self.spv typeBool] args:@[ @(go), @(guard) ]];
    [self emit:SpvOpBranchConditional words:@[ @(go), @(body), @(mergeLabel) ]];
    [self place:body];
    NSMutableArray<NSNumber*>* caseLabels = [NSMutableArray array];
    NSMutableArray* sw = [NSMutableArray arrayWithObjects:@(pc), @(dflt), nil];
    for (NSUInteger k = 0; k < self.fn.blocks.count; k++)
        {
        uint32_t l = [self label];
        [caseLabels addObject:@(l)];
        [sw addObject:@((uint32_t)k)];
        [sw addObject:@(l)];
        }
    uint32_t swMerge = [self label];
    [self emit:SpvOpSelectionMerge words:@[ @(swMerge), @0 ]];
    [self emit:SpvOpSwitch words:sw];
    for (NSUInteger k = 0; k < self.fn.blocks.count; k++)
        {
        XTIRBlock* b = self.fn.blocks[k];
        [self place:caseLabels[k].unsignedIntValue];
        for (XTIRInsn* i in b.instructions)
            if (![self spvStatement:i])
                {
                [self because:[self whyFor:i ptx:YES]];
                return NO;
                }
        XTIRInsn* t = b.terminator;
        NSMutableArray<NSNumber*>* vals = [NSMutableArray array];
        NSMutableArray<NSNumber*>* dsts = [NSMutableArray array];
        switch (t.opcode)
            {
            case XTIROpBranch:
                if (![self spvEdgeFrom:b to:t.operands[0].blockRef cond:0 whenTrue:YES vals:vals dsts:dsts])
                    return NO;
                [self spvStores:vals dsts:dsts];
                [self emit:SpvOpStore words:@[ @(f.pcVar), @([self spvBlockNumber:t.operands[0].blockRef]) ]];
                break;
            case XTIROpCondBranch:
                {
                uint32_t c = [self value:t.operands[0] type:nil];
                if (!c)
                    return NO;
                XTIRBlock* yes = t.operands[1].blockRef;
                XTIRBlock* no = t.operands[2].blockRef;
                if (yes == no)
                    {
                    if (![self spvEdgeFrom:b to:yes cond:0 whenTrue:YES vals:vals dsts:dsts])
                        return NO;
                    }
                else if (![self spvEdgeFrom:b to:yes cond:c whenTrue:YES vals:vals dsts:dsts] ||
                         ![self spvEdgeFrom:b to:no cond:c whenTrue:NO vals:vals dsts:dsts])
                    return NO;
                [self spvStores:vals dsts:dsts];
                uint32_t next = [self emit:SpvOpSelect type:[self.spv typeInt:32]
                                      args:@[ @(c), @([self spvBlockNumber:yes]), @([self spvBlockNumber:no]) ]];
                [self emit:SpvOpStore words:@[ @(f.pcVar), @(next) ]];
                break;
                }
            case XTIROpReturn:
                {
                XTIROperand* rv = t.operands.count ? t.operands[0] : nil;
                XTIRType* rvt = !rv ? nil : rv.kind == XTIROperandKindUse ? [self typeOf:rv.valueId] : self.fn.returnType;
                if (self.helperMode && rvt && rvt.kind != XTIRTypeKindMemory)
                    {
                    uint32_t v = [self value:rv type:rvt];
                    if (!v || !f.retVar)
                        return NO;
                    [self emit:SpvOpStore words:@[ @(f.retVar), @(v) ]];
                    }
                [self emit:SpvOpStore words:@[ @(f.pcVar), @([self.spv u32:kExit]) ]];
                break;
                }
            default:
                return NO;
            }
        [self emit:SpvOpBranch words:@[ @(swMerge) ]];
        }
    [self place:dflt];
    [self emit:SpvOpStore words:@[ @(f.pcVar), @([self.spv u32:kExit]) ]];
    [self emit:SpvOpBranch words:@[ @(swMerge) ]];
    [self place:swMerge];
    [self emit:SpvOpBranch words:@[ @(cont) ]];
    [self place:cont];
    [self emit:SpvOpBranch words:@[ @(head) ]];
    [self place:mergeLabel];
    return YES;
    }

// ── structured control flow ─────────────────────────────────────────────────
// The Metal printer's plan (planStructure) as SPIR-V constructs: a loop is a
// header with OpLoopMerge, its exit the merge and a continue target that
// branches back; an if is an OpSelectionMerge at its join. A SIMD group's
// threads then reconverge after each, which the dispatch loop never lets
// them do. Values stay in Function variables and phis stay copies on their
// edges, as in the dispatch loop. The walk runs dry first, to learn whether
// the shape fits, and only then emits; a shape that does not keeps the
// dispatch loop. The body sits in a loop that runs once, so the kernel's
// return is a break from anywhere outside its own loops.

- (void)spvBranch:(uint32_t)to
    {
    XTSpvFunc* f = self.sf;
    if (!f.dry)
        [self emit:SpvOpBranch words:@[ @(to) ]];
    f.open = NO;
    }

- (BOOL)spvJumpFrom:(NSUInteger)u to:(NSUInteger)v loop:(NSInteger)h exit:(NSInteger)e follow:(NSInteger)fo
    {
    XTSpvFunc* f = self.sf;
    if (!f.dry)
        {
        NSMutableArray<NSNumber*>* vals = [NSMutableArray array];
        NSMutableArray<NSNumber*>* dsts = [NSMutableArray array];
        if (![self spvEdgeFrom:self.fn.blocks[u] to:self.fn.blocks[v] cond:0 whenTrue:YES vals:vals dsts:dsts])
            return NO;
        [self spvStores:vals dsts:dsts];
        }
    if ((NSInteger)v == h)
        {
        [self spvBranch:f.loopCont[@(h)].unsignedIntValue];
        return YES;
        }
    if ((NSInteger)v == e)
        {
        [self spvBranch:f.loopMerge[@(h)].unsignedIntValue];
        return YES;
        }
    if ((NSInteger)v == fo)
        return YES;
    if (self.loopOf[@(v)])
        return [self spvStructuredLoop:v exit:e follow:fo outerLoop:h];
    if ([self.fwdPreds[v] unsignedIntegerValue] != 1)
        return NO;
    return [self spvStructuredBlock:v loop:h exit:e follow:fo];
    }

- (BOOL)spvStructuredLoop:(NSUInteger)x exit:(NSInteger)oe follow:(NSInteger)of outerLoop:(NSInteger)oh
    {
    XTSpvFunc* f = self.sf;
    if ([self.fwdPreds[x] unsignedIntegerValue] != 1)
        return NO;
    NSUInteger ex = [self.loopExit[@(x)] unsignedIntegerValue];
    if (oh >= 0 && ![self.loopOf[@(oh)] containsIndex:ex] && (NSInteger)ex != oe && (NSInteger)ex != of)
        return NO;
    uint32_t head = 0, body = 0, cont = 0, merge = 0;
    if (!f.dry)
        {
        head = [self label], body = [self label], cont = [self label], merge = [self label];
        f.loopCont[@(x)] = @(cont);
        f.loopMerge[@(x)] = @(merge);
        [self emit:SpvOpBranch words:@[ @(head) ]];
        [self place:head];
        [self emit:SpvOpLoopMerge words:@[ @(merge), @(cont), @0 ]];
        [self emit:SpvOpBranch words:@[ @(body) ]];
        [self place:body];
        }
    f.open = YES;
    if (![self spvStructuredBlock:x loop:(NSInteger)x exit:(NSInteger)ex follow:-1])
        return NO;
    if (f.open)
        [self spvBranch:cont];
    if (!f.dry)
        {
        [self place:cont];
        [self emit:SpvOpBranch words:@[ @(head) ]];
        [self place:merge];
        }
    f.open = YES;
    if ((NSInteger)ex == of)
        return YES;
    if ((NSInteger)ex == oh)
        {
        [self spvBranch:f.loopCont[@(oh)].unsignedIntValue];
        return YES;
        }
    if ((NSInteger)ex == oe)
        {
        [self spvBranch:f.loopMerge[@(oh)].unsignedIntValue];
        return YES;
        }
    if (self.loopOf[@(ex)])
        return NO;
    return [self spvStructuredBlock:ex loop:oh exit:oe follow:of];
    }

- (BOOL)spvStructuredBlock:(NSUInteger)x loop:(NSInteger)h exit:(NSInteger)e follow:(NSInteger)fo
    {
    XTSpvFunc* f = self.sf;
    XTIRBlock* b = self.fn.blocks[x];
    if (!f.dry)
        for (XTIRInsn* i in b.instructions)
            if (![self spvStatement:i])
                {
                [self because:[self whyFor:i ptx:YES]];
                return NO;
                }
    XTIRInsn* t = b.terminator;
    if (t.opcode == XTIROpReturn)
        {
        if (self.helperMode)
            {
            // A function's return may stand anywhere in structured SPIR-V.
            XTIROperand* rv = t.operands.count ? t.operands[0] : nil;
            XTIRType* rvt = !rv ? nil : rv.kind == XTIROperandKindUse ? [self typeOf:rv.valueId] : self.fn.returnType;
            if (!f.dry)
                {
                if (rvt && rvt.kind != XTIRTypeKindMemory)
                    {
                    uint32_t v = [self value:rv type:rvt];
                    if (!v)
                        return NO;
                    [self emit:SpvOpReturnValue words:@[ @(v) ]];
                    }
                else
                    [self emit:SpvOpReturn words:@[]];
                }
            f.open = NO;
            return YES;
            }
        // The kernel's work ends: a break from the loop that runs once,
        // which only works from outside any loop of the kernel's own.
        if (h >= 0)
            return NO;
        [self spvBranch:f.exitLabel];
        return YES;
        }
    if (t.opcode == XTIROpBranch)
        return [self spvJumpFrom:x to:[self indexOf:t.operands[0].blockRef] loop:h exit:e follow:fo];
    if (t.opcode != XTIROpCondBranch)
        return NO;
    // CondBranch: a selection that merges at x's immediate post-dominator.
    NSUInteger n = self.fn.blocks.count;
    NSInteger j = [self.ipdom[x] integerValue];
    if (j < 0)
        return NO;
    NSInteger join = (j == (NSInteger)n) ? fo : j;
    if (join >= 0 && join != h && join != e && join != fo)
        if (h >= 0 && ![self.loopOf[@(h)] containsIndex:(NSUInteger)join])
            return NO;
    uint32_t yes = 0, no = 0, merge = 0;
    if (!f.dry)
        {
        uint32_t c = [self value:t.operands[0] type:nil];
        if (!c)
            return NO;
        yes = [self label], no = [self label], merge = [self label];
        [self emit:SpvOpSelectionMerge words:@[ @(merge), @0 ]];
        [self emit:SpvOpBranchConditional words:@[ @(c), @(yes), @(no) ]];
        [self place:yes];
        }
    f.open = YES;
    if (![self spvJumpFrom:x to:[self indexOf:t.operands[1].blockRef] loop:h exit:e follow:join])
        return NO;
    if (f.open)
        [self spvBranch:merge];
    if (!f.dry)
        [self place:no];
    f.open = YES;
    if (![self spvJumpFrom:x to:[self indexOf:t.operands[2].blockRef] loop:h exit:e follow:join])
        return NO;
    if (f.open)
        [self spvBranch:merge];
    if (!f.dry)
        [self place:merge];
    f.open = YES;
    if (join < 0)
        {
        // Both ways left by a branch: the merge is never reached.
        if (!f.dry)
            [self emit:SpvOpUnreachable words:@[]];
        f.open = NO;
        return YES;
        }
    if (join == fo)
        return YES;
    if (join == h)
        {
        [self spvBranch:f.loopCont[@(h)].unsignedIntValue];
        return YES;
        }
    if (join == e)
        {
        [self spvBranch:f.loopMerge[@(h)].unsignedIntValue];
        return YES;
        }
    if (self.loopOf[@(join)])
        return [self spvStructuredLoop:(NSUInteger)join exit:e follow:fo outerLoop:h];
    return [self spvStructuredBlock:(NSUInteger)join loop:h exit:e follow:fo];
    }

// The walk from the entry block, dry or emitting.
- (BOOL)spvStructuredWalk
    {
    self.sf.open = YES;
    return self.loopOf[@0] ? [self spvStructuredLoop:0 exit:-1 follow:-1 outerLoop:-1]
                           : [self spvStructuredBlock:0 loop:-1 exit:-1 follow:-1];
    }

// The function's blocks, structured where their shape allows, else as the
// dispatch loop; then `mergeLabel` is placed. A guard, if any, must hold for
// the body to run at all.
- (BOOL)spvBodyMerge:(uint32_t)mergeLabel guard:(uint32_t)guard
    {
    XTSpvFunc* f = self.sf;
    f.dry = YES;
    BOOL fits = [self planStructure] && [self spvStructuredWalk];
    f.dry = NO;
    if (!fits)
        return [self spvDispatchMerge:mergeLabel guard:guard];
    f.loopCont = [NSMutableDictionary dictionary];
    f.loopMerge = [NSMutableDictionary dictionary];
    f.exitLabel = mergeLabel;
    uint32_t head = [self label], body = [self label], cont = [self label];
    [self emit:SpvOpBranch words:@[ @(head) ]];
    [self place:head];
    [self emit:SpvOpLoopMerge words:@[ @(mergeLabel), @(cont), @0 ]];
    if (guard)
        [self emit:SpvOpBranchConditional words:@[ @(guard), @(body), @(mergeLabel) ]];
    else
        [self emit:SpvOpBranch words:@[ @(body) ]];
    [self place:body];
    if (![self spvStructuredWalk])
        return NO;
    if (f.open)
        [self emit:SpvOpBranch words:@[ @(mergeLabel) ]];
    [self place:cont];
    [self emit:SpvOpBranch words:@[ @(head) ]];
    [self place:mergeLabel];
    return YES;
    }

// A variable for every SSA value that is read and is not a pointer or the
// memory token; a type this cut cannot hold fails. A value nothing reads (a
// narrowing pass's leftover constant, say) gets none and is not printed.
- (BOOL)spvDeclareValues
    {
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
    self.sf.used = used;
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
            uint32_t ty = [self spvType:t];
            if (!ty)
                {
                [self because:@"it uses a value its Vulkan version cannot hold yet"];
                return NO;
                }
            self.sf.varOf[@(i.result.valueId)] = @([self localVar:ty]);
            }
        }
    return YES;
    }

- (XTSpvFunc*)spvNewFunc
    {
    XTSpvFunc* f = [XTSpvFunc new];
    f.vars = [NSMutableArray array];
    f.code = [NSMutableArray array];
    f.varOf = [NSMutableDictionary dictionary];
    f.recipeOf = [NSMutableDictionary dictionary];
    return f;
    }

// Ends a function: its variables at the head of the entry block (after the
// entry label, which is the code's first instruction).
- (void)spvFinish:(XTSpvFunc*)f into:(NSMutableArray<NSNumber*>*)out
    {
    // code[0..1] is OpLabel entry.
    [out addObjectsFromArray:[f.code subarrayWithRange:NSMakeRange(0, 2)]];
    [out addObjectsFromArray:f.vars];
    [out addObjectsFromArray:[f.code subarrayWithRange:NSMakeRange(2, f.code.count - 2)]];
    }

// ── a helper ────────────────────────────────────────────────────────────────

// This (helper-mode) printer's function as a SPIR-V function of scalars: its id, or 0.
- (uint32_t)spvHelper
    {
    self.def = [NSMutableDictionary dictionary];
    self.space = [NSMutableDictionary dictionary];
    self.bufferOf = [NSMutableDictionary dictionary];
    self.bufferFields = [NSMutableIndexSet indexSet];
    self.reductionFields = [NSMutableIndexSet indexSet];
    self.blockIndex = [NSMutableDictionary dictionary];
    self.globals = [NSMutableArray array];
    self.globalOf = [NSMutableDictionary dictionary];
    if (![self analyse])
        return 0;
    NSUInteger bi = 0;
    for (XTIRBlock* b in self.fn.blocks)
        self.blockIndex[b.name] = @(bi++);
    XTIRType* rt = self.fn.returnType;
    BOOL isVoid = !rt || rt.kind == XTIRTypeKindVoid || rt.kind == XTIRTypeKindMemory;
    uint32_t ret = isVoid ? [self.spv typeVoid] : [self spvType:rt];
    if (!ret)
        return 0;
    NSMutableArray* fnTypeWords = [NSMutableArray arrayWithObject:@(ret)];
    NSMutableArray<NSNumber*>* paramTys = [NSMutableArray array];
    for (NSUInteger k = 0; k + 1 < self.fn.paramTypes.count; k++)
        {
        uint32_t t = [self spvType:self.fn.paramTypes[k]];
        if (!t)
            return 0;
        [paramTys addObject:@(t)];
        [fnTypeWords addObject:@(t)];
        }
    NSString* key = [NSString stringWithFormat:@"fn%@", [fnTypeWords componentsJoinedByString:@"_"]];
    uint32_t fnType = [self.spv cached:key op:SpvOpTypeFunction words:fnTypeWords resultFirst:YES];
    uint32_t fid = [self.spv newId];
    self.sf = [self spvNewFunc];
    NSMutableArray<NSNumber*>* header = [NSMutableArray array];
    spvOp(header, SpvOpFunction, @[ @(ret), @(fid), @0, @(fnType) ]);
    NSMutableArray<NSNumber*>* params = [NSMutableArray array];
    for (NSUInteger k = 0; k < paramTys.count; k++)
        {
        uint32_t p = [self.spv newId];
        spvOp(header, SpvOpFunctionParameter, @[ paramTys[k], @(p) ]);
        [params addObject:@(p)];
        }
    [self place:[self label]];
    // Parameter n is value n: each gets a variable, stored on entry.
    for (NSUInteger k = 0; k < params.count; k++)
        {
        uint32_t v = [self localVar:paramTys[k].unsignedIntValue];
        self.sf.varOf[@(k)] = @(v);
        [self emit:SpvOpStore words:@[ @(v), params[k] ]];
        }
    if (![self spvDeclareValues])
        return 0;
    self.sf.pcVar = [self localVar:[self.spv typeInt:32]];
    [self emit:SpvOpStore words:@[ @(self.sf.pcVar), @([self.spv u32:0]) ]];
    if (!isVoid)
        self.sf.retVar = [self localVar:ret];
    uint32_t merge = [self label];
    if (![self spvBodyMerge:merge guard:0])
        return 0;
    if (isVoid)
        [self emit:SpvOpReturn words:@[]];
    else
        [self emit:SpvOpReturnValue words:@[ @([self emit:SpvOpLoad type:ret args:@[ @(self.sf.retVar) ]]) ]];
    [self emit:SpvOpFunctionEnd words:@[]];
    [self.spv.funcs addObjectsFromArray:header];
    [self spvFinish:self.sf into:self.spv.funcs];
    return fid;
    }

// ── the kernel ──────────────────────────────────────────────────────────────

// A storage buffer of `elem` (runtime array, stride `stride`) at `binding`:
// its variable.
- (uint32_t)spvBuffer:(uint32_t)elem stride:(uint32_t)stride binding:(uint32_t)binding readOnly:(BOOL)ro
    {
    XTSpvModule* m = self.spv;
    uint32_t arr = [m newId];
    spvOp(m.globals, SpvOpTypeRuntimeArray, @[ @(arr), @(elem) ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(arr), @(SpvDecArrayStride), @(stride) ]);
    uint32_t st = [m newId];
    spvOp(m.globals, SpvOpTypeStruct, @[ @(st), @(arr) ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(st), @(SpvDecBlock) ]);
    spvOp(m.decos, SpvOpMemberDecorate, @[ @(st), @0, @(SpvDecOffset), @0 ]);
    if (ro)
        spvOp(m.decos, SpvOpMemberDecorate, @[ @(st), @0, @(SpvDecNonWritable) ]);
    uint32_t v = [m newId];
    spvOp(m.globals, SpvOpVariable, @[ @([m pointer:SpvStorageStorageBuffer to:st]), @(v), @(SpvStorageStorageBuffer) ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(v), @(SpvDecDescriptorSet), @0 ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(v), @(SpvDecBinding), @(binding) ]);
    return v;
    }

- (nullable NSData*)spvPrint
    {
    self.def = [NSMutableDictionary dictionary];
    self.space = [NSMutableDictionary dictionary];
    self.bufferOf = [NSMutableDictionary dictionary];
    self.bufferFields = [NSMutableIndexSet indexSet];
    self.reductionFields = [NSMutableIndexSet indexSet];
    self.blockIndex = [NSMutableDictionary dictionary];
    XTIRType* selfT = self.fn.paramTypes.count ? self.fn.paramTypes[0] : nil;
    self.objLayout = selfT.kind == XTIRTypeKindPtr ? selfT.pointeeType.layout : nil;
    self.globals = [NSMutableArray array];
    self.globalOf = [NSMutableDictionary dictionary];
    NSArray<XTIRLayoutField*>* fl = self.objLayout.fields;
    if (!self.objLayout || fl.count < 3 || fl[1].type.kind != XTIRTypeKindI64 || fl[2].type.kind != XTIRTypeKindI64)
        return nil;
    if (![self analyse])
        return nil;
    NSUInteger bi = 0;
    for (XTIRBlock* b in self.fn.blocks)
        self.blockIndex[b.name] = @(bi++);

    XTSpvModule* m = [XTSpvModule new];
    self.spv = m;
    self.spvHelpers = [NSMutableDictionary dictionary];
    self.bufVar = [NSMutableDictionary dictionary];
    self.memberOf = [NSMutableDictionary dictionary];
    self.narrowShiftOf = [NSMutableDictionary dictionary];
    self.wordBufs = [NSMutableSet set];

    // The object's fields the kernel reads or writes (other than captured
    // arrays): lo, hi, and every `FieldAddr self, #k`, in field order.
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
    __block BOOL bad = NO;
    NSMutableArray<NSNumber*>* memberTypes = [NSMutableArray array];
    NSMutableArray<NSNumber*>* memberOffsets = [NSMutableArray array];
    [used enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        uint32_t t = [self spvType:fl[k].type];
        if (!t)
            {
            [self because:@"it uses a captured value its Vulkan version cannot hold"];
            bad = YES;
            *stop = YES;
            return;
            }
        uint32_t off = fl[k].byteOffset;
        if (spvNarrowBytes(fl[k].type))
            {
            // The 32-bit word that holds it, shared with any other narrow
            // field in the same word (the fields come in offset order).
            self.narrowShiftOf[@(k)] = @((off & 3) * 8);
            off &= ~3u;
            t = [self.spv typeInt:32];
            if (memberOffsets.count && memberOffsets.lastObject.unsignedIntValue == off)
                {
                self.memberOf[@(k)] = @(memberTypes.count - 1);
                return;
                }
            }
        self.memberOf[@(k)] = @(memberTypes.count);
        [memberTypes addObject:@(t)];
        [memberOffsets addObject:@(off)];
    }];
    if (bad)
        return nil;

    // Module head: memory model, entry point (filled later), LocalSize 64.
    // The args struct (binding 0) and the kernel's Function copy.
    uint32_t argsT = [m newId];
    NSMutableArray* sw = [NSMutableArray arrayWithObject:@(argsT)];
    [sw addObjectsFromArray:memberTypes];
    spvOp(m.globals, SpvOpTypeStruct, sw);
    spvOp(m.decos, SpvOpDecorate, @[ @(argsT), @(SpvDecBlock) ]);
    for (uint32_t mi = 0; mi < memberOffsets.count; mi++)
        {
        spvOp(m.decos, SpvOpMemberDecorate, @[ @(argsT), @(mi), @(SpvDecOffset), memberOffsets[mi] ]);
        spvOp(m.decos, SpvOpMemberDecorate, @[ @(argsT), @(mi), @(SpvDecNonWritable) ]);
        }
    uint32_t argsV = [m newId];
    spvOp(m.globals, SpvOpVariable, @[ @([m pointer:SpvStorageStorageBuffer to:argsT]), @(argsV),
                                       @(SpvStorageStorageBuffer) ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(argsV), @(SpvDecDescriptorSet), @0 ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(argsV), @(SpvDecBinding), @0 ]);
    uint32_t localT = [m newId];
    NSMutableArray* lw = [NSMutableArray arrayWithObject:@(localT)];
    [lw addObjectsFromArray:memberTypes];
    spvOp(m.globals, SpvOpTypeStruct, lw);
    self.localObjType = localT;

    // The span: three i64 push constants.
    uint32_t i64t = [m typeInt:64];
    uint32_t spanT = [m newId];
    spvOp(m.globals, SpvOpTypeStruct, @[ @(spanT), @(i64t), @(i64t), @(i64t) ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(spanT), @(SpvDecBlock) ]);
    for (uint32_t k = 0; k < 3; k++)
        spvOp(m.decos, SpvOpMemberDecorate, @[ @(spanT), @(k), @(SpvDecOffset), @(8 * k) ]);
    uint32_t spanV = [m newId];
    spvOp(m.globals, SpvOpVariable, @[ @([m pointer:SpvStoragePushConstant to:spanT]), @(spanV),
                                       @(SpvStoragePushConstant) ]);

    // The thread's index.
    uint32_t u32t = [m typeInt:32];
    uint32_t uvec3 = [m cached:@"uvec3" op:SpvOpTypeVector words:@[ @(u32t), @3 ] resultFirst:YES];
    uint32_t gidV = [m newId];
    spvOp(m.globals, SpvOpVariable, @[ @([m pointer:SpvStorageInput to:uvec3]), @(gidV), @(SpvStorageInput) ]);
    spvOp(m.decos, SpvOpDecorate, @[ @(gidV), @(SpvDecBuiltIn), @(SpvBuiltInGlobalInvocationId) ]);

    // Buffers: captured arrays, globals, reductions, in the header's order.
    NSMutableString* meta = [NSMutableString stringWithFormat:@"// xcpar size=%u lo=%u hi=%u", self.objLayout.size,
                                                              fl[1].byteOffset, fl[2].byteOffset];
    NSMutableArray<NSNumber*>* interface = [NSMutableArray arrayWithObjects:@(gidV), @(argsV), @(spanV), nil];
    __block uint32_t binding = 1;
    [self.bufferFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        XTIRType* et = fl[k].type.pointeeType;
        uint32_t t = [self spvType:et];
        if (!t)
            {
            [self because:@"it uses an array of values its Vulkan version cannot hold"];
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" buf=%u:%lu:%u", fl[k].byteOffset, (unsigned long)(k - 3), et.byteWidth];
        BOOL narrow = spvNarrowBytes(et) != 0;
        uint32_t v = [self spvBuffer:narrow ? [self.spv typeInt:32] : t stride:narrow ? 4 : et.byteWidth
                             binding:binding++ readOnly:NO];
        if (narrow)
            [self.wordBufs addObject:@(v)];
        self.bufVar[@(k)] = @(v);
        [interface addObject:@(v)];
    }];
    if (bad)
        return nil;
    for (NSUInteger gi = 0; gi < self.globals.count; gi++)
        {
        XTIRSymbol* g = [self.module symbolForName:self.globals[gi]];
        XTIRType* gt = g.globalType;
        XTIRType* et = gt.kind == XTIRTypeKindAgg ? gt.layout.fields.firstObject.type : gt;
        uint32_t t = [self spvType:et];
        if (!t)
            {
            [self because:[NSString stringWithFormat:@"it uses %@, which its Vulkan version cannot hold",
                                                     spvShownName(g.name)]];
            return nil;
            }
        [meta appendFormat:@" glob=%@:%u", self.globals[gi], et.byteWidth];
        BOOL narrowG = spvNarrowBytes(et) != 0;
        uint32_t v = [self spvBuffer:narrowG ? [self.spv typeInt:32] : t stride:narrowG ? 4 : et.byteWidth
                             binding:binding++ readOnly:NO];
        if (narrowG)
            [self.wordBufs addObject:@(v)];
        self.bufVar[@(-1 - (NSInteger)gi)] = @(v);
        [interface addObject:@(v)];
        }
    NSMutableArray<NSNumber*>* redVars = [NSMutableArray array];
    [self.reductionFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        uint32_t t = [self spvType:fl[k].type];
        if (!t || spvNarrowBytes(fl[k].type) || !self.memberOf[@(k)])
            {
            [self because:@"it reduces an 8- or 16-bit value or a bool, which its Vulkan version cannot yet"];
            bad = YES;
            *stop = YES;
            return;
            }
        [meta appendFormat:@" red=%u:%u", fl[k].byteOffset, fl[k].type.byteWidth];
        uint32_t v = [self spvBuffer:t stride:fl[k].type.byteWidth binding:binding++ readOnly:NO];
        [redVars addObject:@(v)];
        [interface addObject:@(v)];
    }];
    if (bad)
        return nil;

    // The kernel function.
    uint32_t voidT = [m typeVoid];
    uint32_t fnT = [m cached:[NSString stringWithFormat:@"fn%u", voidT] op:SpvOpTypeFunction words:@[ @(voidT) ]
                 resultFirst:YES];
    uint32_t mainId = [m newId];
    self.sf = [self spvNewFunc];
    NSMutableArray<NSNumber*>* header = [NSMutableArray array];
    spvOp(header, SpvOpFunction, @[ @(voidT), @(mainId), @0, @(fnT) ]);
    [self place:[self label]];
    self.localObj = [self localVar:localT];
    if (![self spvDeclareValues])
        return nil;

    // tid, the span, lo and hi: lo = span.lo + tid * per, hi = min(lo + per, span.hi).
    uint32_t gid = [self emit:SpvOpLoad type:uvec3 args:@[ @(gidV) ]];
    uint32_t tid32 = [self emit:SpvOpCompositeExtract type:u32t args:@[ @(gid), @0 ]];
    uint32_t tid = [self emit:SpvOpUConvert type:i64t args:@[ @(tid32) ]];
    uint32_t pI64 = [m pointer:SpvStoragePushConstant to:i64t];
    uint32_t spanLo = [self emit:SpvOpLoad type:i64t
                            args:@[ @([self emit:SpvOpAccessChain type:pI64 args:@[ @(spanV), @([m u32:0]) ]]) ]];
    uint32_t spanHi = [self emit:SpvOpLoad type:i64t
                            args:@[ @([self emit:SpvOpAccessChain type:pI64 args:@[ @(spanV), @([m u32:1]) ]]) ]];
    uint32_t per = [self emit:SpvOpLoad type:i64t
                         args:@[ @([self emit:SpvOpAccessChain type:pI64 args:@[ @(spanV), @([m u32:2]) ]]) ]];
    uint32_t lo = [self emit:SpvOpIAdd type:i64t args:@[ @(spanLo), @([self emit:SpvOpIMul type:i64t
                                                                            args:@[ @(tid), @(per) ]]) ]];
    uint32_t end = [self emit:SpvOpIAdd type:i64t args:@[ @(lo), @(per) ]];
    uint32_t hi = [self emit:SpvOpSelect type:i64t
                        args:@[ @([self emit:SpvOpSLessThan type:[m typeBool] args:@[ @(end), @(spanHi) ]]), @(end),
                                @(spanHi) ]];
    // Copy the fields in, then set lo and hi.
    for (NSUInteger k = 0; k < memberTypes.count; k++)
        {
        uint32_t mt = memberTypes[k].unsignedIntValue;
        uint32_t src = [self emit:SpvOpAccessChain type:[m pointer:SpvStorageStorageBuffer to:mt]
                             args:@[ @(argsV), @([m u32:(uint32_t)k]) ]];
        uint32_t dst = [self emit:SpvOpAccessChain type:[m pointer:SpvStorageFunction to:mt]
                             args:@[ @(self.localObj), @([m u32:(uint32_t)k]) ]];
        [self emit:SpvOpStore words:@[ @(dst), @([self emit:SpvOpLoad type:mt args:@[ @(src) ]]) ]];
        }
    uint32_t pLocal64 = [m pointer:SpvStorageFunction to:i64t];
    [self emit:SpvOpStore words:@[ @([self emit:SpvOpAccessChain type:pLocal64
                                           args:@[ @(self.localObj), @([m u32:[self.memberOf[@1] unsignedIntValue]]) ]]),
                                   @(lo) ]];
    [self emit:SpvOpStore words:@[ @([self emit:SpvOpAccessChain type:pLocal64
                                           args:@[ @(self.localObj), @([m u32:[self.memberOf[@2] unsignedIntValue]]) ]]),
                                   @(hi) ]];
    // The method's parameter 0 is the object: no variable, every use is a FieldAddr.
    self.sf.pcVar = [self localVar:u32t];
    [self emit:SpvOpStore words:@[ @(self.sf.pcVar), @([m u32:0]) ]];
    uint32_t guard = [self emit:SpvOpSLessThan type:[m typeBool] args:@[ @(lo), @(hi) ]];
    uint32_t merge = [self label];
    if (![self spvBodyMerge:merge guard:guard])
        return nil;
    // Threads past the range write no partials.
    uint32_t inRange = [self emit:SpvOpSLessThan type:[m typeBool] args:@[ @(lo), @(spanHi) ]];
    uint32_t write = [self label], done = [self label];
    [self emit:SpvOpSelectionMerge words:@[ @(done), @0 ]];
    [self emit:SpvOpBranchConditional words:@[ @(inRange), @(write), @(done) ]];
    [self place:write];
    __block NSUInteger ri = 0;
    [self.reductionFields enumerateIndexesUsingBlock:^(NSUInteger k, BOOL* stop) {
        uint32_t mt = [self spvType:fl[k].type];
        uint32_t src = [self emit:SpvOpAccessChain type:[m pointer:SpvStorageFunction to:mt]
                             args:@[ @(self.localObj), @([m u32:[self.memberOf[@(k)] unsignedIntValue]]) ]];
        uint32_t dst = [self emit:SpvOpAccessChain type:[m pointer:SpvStorageStorageBuffer to:mt]
                             args:@[ redVars[ri], @([m u32:0]), @(tid32) ]];
        [self emit:SpvOpStore words:@[ @(dst), @([self emit:SpvOpLoad type:mt args:@[ @(src) ]]) ]];
        ri++;
    }];
    [self emit:SpvOpBranch words:@[ @(done) ]];
    [self place:done];
    [self emit:SpvOpReturn words:@[]];
    [self emit:SpvOpFunctionEnd words:@[]];
    if (self.why)
        return nil;

    // The head, now that the interface is known.
    spvOp(m.head, SpvOpMemoryModel, @[ @0, @1 ]);   // Logical, GLSL450
    NSMutableArray* ep = [NSMutableArray arrayWithObjects:@5, @(mainId), nil];   // GLCompute
    [ep addObjectsFromArray:spvString(@"main")];
    [ep addObjectsFromArray:interface];
    spvOp(m.head, SpvOpEntryPoint, ep);
    spvOp(m.head, SpvOpExecutionMode, @[ @(mainId), @17, @64, @1, @1 ]);   // LocalSize 64 1 1
    // The kernel function goes after its helpers (already in funcs).
    [m.funcs addObjectsFromArray:header];
    [self spvFinish:self.sf into:m.funcs];

    NSData* words = [m words];
    // spirv= before fast: ParDevice.isFast reads the line's last word.
    [meta appendFormat:@" spirv=%lu", (unsigned long)(words.length / 4)];
    if (self.fast)
        [meta appendString:@" fast"];
    [meta appendString:@"\n"];
    NSMutableData* out = [[meta dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    uint8_t zero = 0;
    [out appendBytes:&zero length:1];
    // The words start on a 4-byte boundary within the text.
    while (out.length % 4)
        [out appendBytes:&zero length:1];
    [out appendData:words];
    return out;
    }

+ (nullable NSData*)spirvForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                               why:(NSString* _Nullable* _Nullable)why
    {
    XTIRParMSL* p = [XTIRParMSL new];
    p.module = module;
    p.fn = run;
    p.fast = fast;
    NSData* out = [p spvPrint];
    if (!out && why)
        *why = p.why;
    return out;
    }

@end
