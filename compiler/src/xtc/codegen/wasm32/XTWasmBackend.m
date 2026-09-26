// XTWasmBackend.m — IR → WAT. The bring-up form from wasm-target.md §2:
// every function is one `loop` wrapping a `br_table` on a $pc local (one arm
// per IR block); every SSA value gets a wasm local of its value type; narrow
// integers live canonicalised in i32 locals (signed types sign-extended,
// unsigned zero-extended — spec §3.1's no-same-width-promotion wrap needs the
// mask, and comparisons/divisions then work directly); aggregates and pinned
// locals live in a linear-memory shadow frame off the mutable global $__sp,
// with a $__stack_low limit check on entry (the shadow stack has no guard
// page — §3). Struct offsets come VERBATIM from the recorded IR layout
// (blewit #5); this backend never re-derives an offset.
//
// Phi edges are PARALLEL copies. On wasm the operand stack makes the
// lost-copy problem (#683) vanish: push every source, then local.set every
// destination in reverse — the stack snapshot IS the parallel read.
//
// Unhandled opcodes emit a placeholder + a stderr note (the arm9 bring-up
// policy: partial programs still assemble). Stage 2 fills the funcref-table
// family (CallIndirect / VTbl* / Proto* / `^`) and ARC.
#import "XTWasmBackend.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIRType.h"
#import "XTIRLayout.h"
#import "XTIRSymbol.h"
#import "XTIROperand.h"
#import "XTIRValue.h"
#import "XTIRConstant.h"

static BOOL sThreadSafeARC = NO;
static NSInteger sThreadSafeARCOverride = -1;
static NSInteger sOptLevel = 0;
// ── Multi-module modes (wasm-target.md §12 #4 / TODO-wasm.md W2) ───────────
// sEmitLib: this module IS a library — dylink-shaped relocatable codegen.
// It imports env.memory / env.__indirect_function_table / the immutable
// placement bases env.__memory_base + env.__table_base (and the app's shared
// shadow-stack globals env.__sp / env.__stack_low), emits ONE data segment at
// (offset (global.get $__memory_base)) with all symbols at RELATIVE offsets,
// its elem segment at (offset (global.get $__table_base)), rebases every
// data-address / funcref-index constant off those globals, emits NO runtime
// (the app's is imported), and exports every defined function plus one
// __addr_<sym> getter per data symbol and __wasm_apply_relocs (which patches
// the vtable words data segments cannot compute, then runs the module inits).
// sLinkLibs: this module is an APP that #imports .wasm libraries — it exports
// its memory/table/runtime/stack globals so the loader can wire each library
// to them, resolves extern data addresses through the library's __addr_
// getters, and gives imported functions referenced by vtables (or taken as
// values) slots in its own funcref table.
static BOOL sEmitLib = NO;
static BOOL sLinkLibs = NO;

// ── Structured-emission plan (one per function, -O1+) ───────────────────────
// The dominator-tree relooper's analysis result: successor lists in
// terminator-operand order, a DFS reverse postorder, immediate dominators
// (Cooper-Harvey-Kennedy over the RPO), natural-loop headers (back-edge
// targets that dominate their source), merge nodes (>= 2 forward in-EDGES —
// edges, not unique predecessors, so a CondBranch with both arms on one
// target counts twice), and each block's dominator-tree children that are
// merge nodes, in RPO order. Every collection is an array walked in a
// defined order — nothing here may enumerate a hash container, because the
// self-hosted twin must reproduce the walk exactly.
@interface XTWasmCFGPlan : NSObject
@property (nonatomic) NSArray<NSArray<NSNumber *> *> *succs;     // per block
@property (nonatomic) NSArray<NSNumber *> *rpoIndex;             // -1 = unreachable
@property (nonatomic) NSArray<NSNumber *> *idom;                 // -1 = none
@property (nonatomic) NSArray<NSNumber *> *loopHeader;           // 0/1
@property (nonatomic) NSArray<NSNumber *> *mergeNode;            // 0/1
@property (nonatomic) NSArray<NSArray<NSNumber *> *> *mergeKids; // per block, RPO order
@end
@implementation XTWasmCFGPlan
@end

// ── Per-function emission state ─────────────────────────────────────────────
@interface XTWasmFnCtx : NSObject
@property (nonatomic) XTIRFunction *fn;
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *pinnedOffset; // valueId → frame off
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *aggSlot;      // valueId → frame off
@property (nonatomic) NSMutableSet<NSNumber *> *declared;                        // valueIds with locals
@property (nonatomic, nullable) NSArray<NSNumber *> *orderedIds;                 // -O1+: surviving ids, ascending
@property (nonatomic) uint32_t frameSize;
@property (nonatomic) BOOL hasSret;
@end
@implementation XTWasmFnCtx
@end

@implementation XTWasmBackend

+ (void)setThreadSafeARCOverride:(NSInteger)mode { sThreadSafeARCOverride = mode; }
+ (BOOL)threadSafeARC { return sThreadSafeARC; }
+ (void)setOptLevel:(NSInteger)level { sOptLevel = level; }
+ (void)setTailCalls:(BOOL)on { sTailCalls = on; }
+ (void)setEmitLib:(BOOL)on { sEmitLib = on; }
+ (void)setLinkLibs:(BOOL)on { sLinkLibs = on; }

#pragma mark - Widths (the type-width invariant's backend side)

// Leaf widths MUST equal the front end's (tests/types/XTTypeWidthInvariantTests).
// Field OFFSETS are never derived from these — they are read verbatim from the
// recorded IR layout (blewit #5); widths size loads/stores/copies only.
+ (NSUInteger)wasmFieldWidth:(XTIRType *)t {
    if (!t) return 0;
    switch (t.kind) {
        case XTIRTypeKindPtr:   return 4;
        case XTIRTypeKindF64:   return 8;
        case XTIRTypeKindF32:   return 4;
        case XTIRTypeKindI32:
        case XTIRTypeKindU32:   return 4;
        case XTIRTypeKindI64:
        case XTIRTypeKindU64:   return 8;
        case XTIRTypeKindI16:
        case XTIRTypeKindU16:   return 2;
        case XTIRTypeKindI8:
        case XTIRTypeKindU8:
        case XTIRTypeKindBool:  return 1;
        case XTIRTypeKindAgg:   return [self wasmAggSize:t.layout];
        default:                return 0;   // Void / Memory
    }
}

+ (NSUInteger)wasmAggSize:(XTIRLayout *)layout {
    if (!layout) return 0;
    NSUInteger total = layout.size;
    for (XTIRLayoutField *f in layout.fields) {
        NSUInteger end = f.byteOffset + [self wasmFieldWidth:f.type];
        if (end > total) total = end;
    }
    return total;
}

// The RECORDED offset — see XTArm64Backend.arm64FieldOffset: for the rule.
+ (NSUInteger)wasmFieldOffset:(XTIRLayout *)layout index:(NSUInteger)idx {
    if (!layout || idx >= layout.fields.count) return [self wasmAggSize:layout];
    return layout.fields[idx].byteOffset;
}

#pragma mark - Type mapping

// A value's wasm VALUE type. Narrow ints, bool and pointers are i32; an
// aggregate value is represented by the i32 ADDRESS of its frame slot.
static NSString *wasmValType(XTIRType *t) {
    if (!t) return @"i32";
    switch (t.kind) {
        case XTIRTypeKindI64:
        case XTIRTypeKindU64: return @"i64";
        case XTIRTypeKindF32: return @"f32";
        case XTIRTypeKindF64: return @"f64";
        case XTIRTypeKindVec: return @"v128";
        default:              return @"i32";
    }
}

// The wasm SIMD shape prefix for a vector's lane type ("i32x4" etc.); nil for
// a lane wasm has no 128-bit shape for (never produced by the vectoriser).
static NSString *wasmLaneShape(XTIRType *lane) {
    if (!lane) return nil;
    switch (lane.kind) {
        case XTIRTypeKindI8:  case XTIRTypeKindU8:  return @"i8x16";
        case XTIRTypeKindI16: case XTIRTypeKindU16: return @"i16x8";
        case XTIRTypeKindI32: case XTIRTypeKindU32: return @"i32x4";
        case XTIRTypeKindF32:                       return @"f32x4";
        default:                                    return nil;
    }
}

static BOOL isMemOrVoid(XTIRType *t) {
    return !t || t.kind == XTIRTypeKindMemory || t.kind == XTIRTypeKindVoid;
}

static BOOL is64(XTIRType *t) {
    return t && (t.kind == XTIRTypeKindI64 || t.kind == XTIRTypeKindU64);
}

// ── Canonicalisation (spec §3.1: u8+u8 wraps) ──────────────────────────────
// Narrow values are kept canonical in their i32 local: sign-extended for
// signed types, zero-extended (masked) for unsigned/bool. Emitted after any
// op whose full-width result can leave the narrow range.
static NSString *canonSuffix(XTIRType *t) {
    if (!t) return nil;
    switch (t.kind) {
        case XTIRTypeKindI8:   return @"    i32.extend8_s\n";
        case XTIRTypeKindI16:  return @"    i32.extend16_s\n";
        case XTIRTypeKindU8:   return @"    i32.const 255\n    i32.and\n";
        case XTIRTypeKindU16:  return @"    i32.const 65535\n    i32.and\n";
        case XTIRTypeKindBool: return @"    i32.const 1\n    i32.and\n";
        default:               return nil;   // full-width / float / ptr
    }
}

#pragma mark - Module emission

// Module-level state, rebuilt per assemblyFromModule: call (file statics so
// the class-method style matches the sibling backends).
static NSMutableDictionary<NSString *, NSNumber *> *sSymAddr;    // name → linear addr
static NSMutableDictionary<NSNumber *, NSNumber *> *sConstAddr;  // constantId → addr
static uint32_t sDataEnd;
static NSMutableArray<NSString *> *sDataSegments;
static NSMutableDictionary<NSString *, NSString *> *sImportSigs; // name → (param…)(result…)
static NSMutableDictionary<NSString *, NSString *> *sImportPkg;  // name → #package namespace
static BOOL sFatalImportError;   // a C-variadic import was called (task #34)

// task #34: a C-variadic import has no single wasm functype — the import's
// type was derived from the FIRST call site, and any call with a different
// arity left operands on the stack (invalid wasm, caught only at
// instantiation). There is also no C library on wasm32 to satisfy the
// import, so the honest answer is a hard error at codegen.
static void wasmRejectVariadicImport(XTIRSymbol *sym) {
    fprintf(stderr, "xcc-cg-wasm32: error: '%s' is a C-variadic import — its "
            "call sites have no single wasm type, and wasm32 has no C library "
            "to satisfy it. Use Stdio.printf, or a fixed-arity #package "
            "import.\n", sym.name.UTF8String);
    sFatalImportError = YES;
}
static NSMutableSet<NSString *> *sDefinedFns;
static NSMutableSet<NSString *> *sTodoNotes;
static XTIRModule *sMod;
// Stage 2: the ONE funcref table. Index 0 is reserved and never populated —
// a null slot reads as false (the respondsTo contract) and TRAPS if called
// (wasm-target.md §4). Every defined function gets an index; a function
// "address" anywhere in the program IS its table index.
static NSMutableDictionary<NSString *, NSNumber *> *sFnTableIndex;
static NSMutableArray<NSString *> *sFnTableOrder;
// call_indirect signatures: sig text "(param i32) (result i32)" → type name.
static NSMutableDictionary<NSString *, NSString *> *sIndirectTypes;
static BOOL sNeedsARC, sNeedsAlloc, sNeedsHeapInfo;
// ── emit-lib state ─────────────────────────────────────────────────────────
// The single relative data image (segment offset = global.get $__memory_base;
// every sSymAddr/sConstAddr value is an offset INTO it), the reloc word list
// (@[wordRel, @"fn"|@"data", value] — applied by __wasm_apply_relocs because
// a data segment cannot compute base+k), and the __addr_ getter list
// (@[name, off] in placement order).
static NSMutableData *sLibImage;
static NSMutableArray<NSArray *> *sLibRelocs;
static NSMutableArray<NSArray *> *sAddrGetters;
// ── link-libs state ────────────────────────────────────────────────────────
// Extern data symbols resolved through an imported __addr_<name> getter
// (name → package, plus a deterministic registration order), and the app
// vtable words that hold a library data address (@[absWordAddr, symName] —
// patched by $__xtc_fixup_imports before the module inits run).
static NSMutableDictionary<NSString *, NSString *> *sExternAddrPkg;
static NSMutableArray<NSString *> *sExternAddrOrder;
static NSMutableArray<NSArray *> *sAppFixups;
// emit-lib: which non-Call runtime entry points the module reaches (Retain/
// Release and the weak family emit direct `call`s, not XTIROpCall insns, so
// the call-site import collector cannot see them).
static BOOL sNeedsWeakReg, sNeedsWeakUnreg;
// ProtoDispatch/ProtoLoad present: the module carries its own $__xtc_itab.
static BOOL sNeedsItab;
// -x-wasm32,return-call: emit tail calls (return_call / return_call_indirect)
// for calls in tail position. Off by default — the instructions are
// standardised and shipped in current engines, but the baseline module stays
// maximally portable unless asked.
static BOOL sTailCalls;
static NSMutableSet<NSString *> *sNewSuffixes;   // _xtc_new_<T> suffixes referenced

// Heap: bump allocation ABOVE the 1 MiB stack region, growing the memory as
// needed. Everything below $__heap_base is data or shadow stack, which is
// what makes the ARC "is this a heap object" guard a single compare.
static const uint32_t kWasmHeapBase = 1u << 20;

// ── Local naming (-O1+): dense rank instead of raw value id ────────────────
// The opt passes allocate value ids for values that later die (an aborted
// narrowing, a DCE'd clone), so raw ids carry GAPS whose exact pattern only
// the original's allocation history knows. The self-hosted twin numbers its
// pass-created values densely after the fact (numberFreshValues), so raw ids
// can never agree above -O0. Both sides therefore name locals by the RANK of
// the value id among the ids that appear in the FINAL body (params included)
// — a set both sides provably share, in an order (ascending id) both sides'
// monotone creation order preserves. At -O0 the map is nil and raw ids keep
// the wasm-diff oracle text byte for byte.
static NSDictionary<NSNumber *, NSNumber *> *sValueRank;  // raw id → local number
static uint32_t vnum(uint32_t vid) {
    NSNumber *r = sValueRank ? sValueRank[@(vid)] : nil;
    return r ? r.unsignedIntValue : vid;
}

static uint32_t alignUp32(uint32_t v, uint32_t a) { return (v + a - 1) & ~(a - 1); }

+ (void)todo:(NSString *)what {
    if ([sTodoNotes containsObject:what]) return;
    [sTodoNotes addObject:what];
    fprintf(stderr, "xcc-cg-wasm32: TODO: %s not lowered yet\n", what.UTF8String);
}

// Escape bytes into a WAT data-segment string literal.
static NSString *watStringLit(NSData *bytes) {
    NSMutableString *s = [NSMutableString string];
    const uint8_t *b = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        uint8_t c = b[i];
        if (c >= 0x20 && c < 0x7F && c != '"' && c != '\\')
            [s appendFormat:@"%c", c];
        else
            [s appendFormat:@"\\%02x", c];
    }
    return s;
}

+ (NSString *)assemblyFromModule:(XTIRModule *)mod {
    sThreadSafeARC = sThreadSafeARCOverride >= 0
        ? (sThreadSafeARCOverride != 0)
        : [mod referencesSymbolNamed:@"_xt_thread_create"];

    sMod = mod;
    sSymAddr = [NSMutableDictionary dictionary];
    sConstAddr = [NSMutableDictionary dictionary];
    sDataSegments = [NSMutableArray array];
    sImportSigs = [NSMutableDictionary dictionary];
    sImportPkg = [NSMutableDictionary dictionary];
    sFatalImportError = NO;
    sDefinedFns = [NSMutableSet set];
    sTodoNotes = [NSMutableSet set];
    sFnTableIndex = [NSMutableDictionary dictionary];
    sFnTableOrder = [NSMutableArray array];
    sIndirectTypes = [NSMutableDictionary dictionary];
    sNewSuffixes = [NSMutableSet set];
    sNeedsARC = sNeedsAlloc = sNeedsHeapInfo = NO;
    sLibImage = sEmitLib ? [NSMutableData data] : nil;
    sLibRelocs = sEmitLib ? [NSMutableArray array] : nil;
    sAddrGetters = sEmitLib ? [NSMutableArray array] : nil;
    sExternAddrPkg = sLinkLibs ? [NSMutableDictionary dictionary] : nil;
    sExternAddrOrder = sLinkLibs ? [NSMutableArray array] : nil;
    sAppFixups = sLinkLibs ? [NSMutableArray array] : nil;
    // sTailCalls is a caller-set mode (like sOptLevel), not per-module state.
    // Data starts ABOVE 0x10000: an instance's word 0 holds EITHER a vtable
    // ADDRESS or a small class id, and the RTTI downcast's discriminator is
    // `< 0x10000` — a vtable placed below 64 KiB would read as a class id
    // (the same guard the ARC runtime uses for the Map/Set sentinels).
    // A LIBRARY's addresses are RELATIVE to __memory_base (the loader places
    // it at ≥ 0x10000 and asserts so), so its own offsets start at 0.
    sDataEnd = sEmitLib ? 0 : 0x10000;

    for (XTIRFunction *fn in mod.functions) [sDefinedFns addObject:fn.name];

    // ── Runtime prescan: which generated helpers does this module need, and
    // which functions go in the funcref table (all defined ones — an index is
    // the function's "address" and vtables/`^`/fn-pointers all use it).
    // App table: index 0 is the reserved null slot. Library table: indices are
    // RELATIVE to __table_base (the app's slot 0 stays the one null), 0-based.
    for (XTIRFunction *fn in mod.functions) {
        NSNumber *idx = @(sFnTableOrder.count + (sEmitLib ? 0 : 1));
        sFnTableIndex[fn.name] = idx;
        [sFnTableOrder addObject:fn.name];
    }
    BOOL needsCount = NO;
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindRuntimeHelper) continue;
        if ([sym.name isEqualToString:@"_xtc_alloc"]) sNeedsAlloc = YES;
        else if ([sym.name isEqualToString:@"_xtc_count"]) { sNeedsAlloc = YES; needsCount = YES; }
        else if ([sym.name hasPrefix:@"_xtc_new_"]) {
            sNeedsAlloc = YES;
            [sNewSuffixes addObject:[sym.name substringFromIndex:@"_xtc_new_".length]];
        }
    }
    // Heap introspection (support/wasm32/lib/Heap.xc declares these as
    // bodyless externs): implemented over the allocator's own state, so
    // Heap.size() reports the REAL free pool, not a hollow constant.
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindFunction) continue;
        if ([sym.name isEqualToString:@"_xtc_heap_free_bytes"]
            || [sym.name isEqualToString:@"_xtc_heap_total_bytes"]
            || [sym.name isEqualToString:@"_xtc_heap_largest"]) {
            sNeedsHeapInfo = YES;
            sNeedsAlloc = YES;   // the helpers read $__heap / $__free
        }
    }
    if (needsCount) [sNewSuffixes addObject:@"__count__"];   // marker, emitted below
    sNeedsWeakReg = sNeedsWeakUnreg = NO;
    sNeedsItab = NO;
    for (XTIRFunction *fn in mod.functions) {
        for (XTIRBlock *b in fn.blocks) {
            for (XTIRInsn *insn in b.instructions) {
                if (insn.opcode == XTIROpRetain || insn.opcode == XTIROpRelease
                    || insn.opcode == XTIROpAutorelease) sNeedsARC = YES;
                else if (insn.opcode == XTIROpWeakRegister) sNeedsWeakReg = YES;
                else if (insn.opcode == XTIROpWeakUnregister) sNeedsWeakUnreg = YES;
                else if (insn.opcode == XTIROpProtoDispatch
                         || insn.opcode == XTIROpProtoLoad) sNeedsItab = YES;
            }
        }
    }
    if (sNeedsARC) sNeedsAlloc = YES;    // dealloc reads the alloc header
    // An app that links libraries carries the ONE runtime for every module
    // (§12 #4 decision 3): emit and export the whole family even when the app
    // itself would not need a piece — a library's env import must find it.
    if (sLinkLibs) {
        sNeedsAlloc = YES;
        sNeedsHeapInfo = YES;
        [sNewSuffixes addObject:@"__count__"];
    }
    if (sEmitLib) {
        // A library defines only its per-type allocator STUBS (they bake this
        // module's table indices / element widths); everything else in the
        // runtime family stays undefined and resolves as an env import wired
        // to the app's exports.
        for (NSString *suffix in sNewSuffixes)
            if (![suffix isEqualToString:@"__count__"])
                [sDefinedFns addObject:[@"_xtc_new_" stringByAppendingString:suffix]];
    } else if (sNeedsAlloc) {
        [sDefinedFns addObject:@"_xtc_alloc"];
        [sDefinedFns addObject:@"_xtc_dealloc"];
        [sDefinedFns addObject:@"_xtc_count"];
        [sDefinedFns addObject:@"_xtc_weak_register"];
        [sDefinedFns addObject:@"_xtc_weak_unregister"];
        [sDefinedFns addObject:@"_xtc_weak_load"];
        if (sNeedsHeapInfo) {
            [sDefinedFns addObject:@"_xtc_heap_free_bytes"];
            [sDefinedFns addObject:@"_xtc_heap_total_bytes"];
            [sDefinedFns addObject:@"_xtc_heap_largest"];
        }
        for (NSString *suffix in sNewSuffixes)
            if (![suffix isEqualToString:@"__count__"])
                [sDefinedFns addObject:[@"_xtc_new_" stringByAppendingString:suffix]];
    }

    // ── Data placement: string literals, globals, vtables, constants ───────
    [self placeDataForModule:mod];

    // ── Imports: every function symbol with no body is a host import from
    // the `env` package (the #package directive refines this later). The
    // signature is derived from the symbol's call sites.
    [self collectImportsForModule:mod];

    // Function bodies are emitted FIRST (into their own buffer) because they
    // discover the call_indirect signatures the module header must declare
    // (and, in the multi-module modes, the on-demand address-getter imports
    // and imported-function table slots).
    NSMutableString *fnsOut = [NSMutableString string];
    for (XTIRFunction *fn in mod.functions)
        [self emitFunction:fn module:mod into:fnsOut];
    if (sNeedsItab) [self emitItabHelperInto:fnsOut];
    if (sEmitLib) [self emitLibStubsInto:fnsOut];
    else if (sNeedsAlloc) [self emitRuntimeInto:fnsOut];
    if (sEmitLib) [self emitLibTailInto:fnsOut module:mod];
    if (sLinkLibs && sAppFixups.count) [self emitAppFixupInto:fnsOut];

    NSMutableString *out = [NSMutableString string];
    if (sEmitLib) {
        // ── Library module header (relocatable, dylink-shaped). The
        // `xtc-lib` marker line carries the two placement numbers the
        // loader's sidecar (.json) needs — xcc-ln-wasm32 reads it.
        [out appendFormat:@";; module %@ — generated by xcc-cg-wasm32 --emit-lib\n",
                          mod.name ?: @"?"];
        [out appendFormat:@";; xtc-lib data=%u table=%lu\n",
                          sDataEnd, (unsigned long)sFnTableOrder.count];
        [out appendString:@"(module\n"];
        [out appendString:@"  (import \"env\" \"memory\" (memory 0))\n"];
        [out appendString:
            @"  (import \"env\" \"__indirect_function_table\" (table 0 funcref))\n"];
        [out appendString:@"  (import \"env\" \"__memory_base\" (global $__memory_base i32))\n"];
        [out appendString:@"  (import \"env\" \"__table_base\" (global $__table_base i32))\n"];
        [out appendString:@"  (import \"env\" \"__sp\" (global $__sp (mut i32)))\n"];
        [out appendString:@"  (import \"env\" \"__stack_low\" (global $__stack_low (mut i32)))\n"];
        for (NSString *name in
             [sImportSigs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [out appendFormat:@"  (import \"%@\" \"%@\" (func $%@ %@))\n",
                              sImportPkg[name] ?: @"env", name, name, sImportSigs[name]];
        }
        if (sFnTableOrder.count) {
            [out appendString:@"  (elem (global.get $__table_base)"];
            for (NSString *name in sFnTableOrder) [out appendFormat:@" $%@", name];
            [out appendString:@")\n"];
        }
        for (NSString *sig in
             [sIndirectTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [out appendFormat:@"  (type $%@ (func %@))\n", sIndirectTypes[sig], sig];
        }
        // The ONE data segment: every symbol at its relative offset inside
        // the payload, placed at __memory_base. Reloc words ride as zero.
        if (sLibImage.length) {
            [sLibImage setLength:sDataEnd];
            [out appendFormat:@"  (data (global.get $__memory_base) \"%@\")\n",
                              watStringLit(sLibImage)];
        }
        [out appendString:fnsOut];
        [out appendString:@")\n"];
        sMod = nil;
        sValueRank = nil;
        return sFatalImportError ? nil : out;
    }

    [out appendFormat:@";; module %@ — generated by xcc-cg-wasm32\n", mod.name ?: @"?"];
    [out appendString:@"(module\n"];
    for (NSString *name in
         [sImportSigs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [out appendFormat:@"  (import \"%@\" \"%@\" (func $%@ %@))\n",
                          sImportPkg[name] ?: @"env", name, name, sImportSigs[name]];
    }
    // 32 pages = 2 MiB: data + the 1 MiB shadow-stack region below
    // kWasmHeapBase, one starter MiB of heap above it; _xtc_alloc grows the
    // memory beyond that.
    [out appendString:@"  (memory (export \"memory\") 32)\n"];
    uint32_t stackTop = kWasmHeapBase;
    uint32_t stackLow = alignUp32(sDataEnd, 16);
    if (sLinkLibs) {
        // The loader wires each library to THIS module's memory, table,
        // stack globals and runtime: export the lot. $__stack_low is mutable
        // here — the loader raises it past the last library's data so the
        // shadow stack cannot silently grow down into library statics.
        [out appendFormat:@"  (global $__sp (export \"__sp\") (mut i32) (i32.const %u))\n",
                          stackTop];
        [out appendFormat:@"  (global $__stack_low (export \"__stack_low\") (mut i32) "
                          @"(i32.const %u))\n", stackLow];
        [out appendFormat:@"  (global $__data_end (export \"__data_end\") i32 "
                          @"(i32.const %u))\n", sDataEnd];
    } else {
        [out appendFormat:@"  (global $__sp (mut i32) (i32.const %u))\n", stackTop];
        [out appendFormat:@"  (global $__stack_low i32 (i32.const %u))\n", stackLow];
    }
    if (sNeedsAlloc) {
        [out appendFormat:@"  (global $__heap (mut i32) (i32.const %u))\n", kWasmHeapBase];
        [out appendString:@"  (global $__free (mut i32) (i32.const 0))\n"];
    }
    // The funcref table (index 0 reserved-null) and the declared functypes
    // every call_indirect site is checked against.
    if (sFnTableOrder.count) {
        if (sLinkLibs)
            [out appendFormat:@"  (table (export \"__indirect_function_table\") "
                              @"%lu funcref)\n",
                              (unsigned long)(sFnTableOrder.count + 1)];
        else
            [out appendFormat:@"  (table %lu funcref)\n",
                              (unsigned long)(sFnTableOrder.count + 1)];
        [out appendString:@"  (elem (i32.const 1)"];
        for (NSString *name in sFnTableOrder) [out appendFormat:@" $%@", name];
        [out appendString:@")\n"];
    }
    for (NSString *sig in
         [sIndirectTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [out appendFormat:@"  (type $%@ (func %@))\n", sIndirectTypes[sig], sig];
    }
    for (NSString *seg in sDataSegments) [out appendString:seg];
    [out appendString:fnsOut];

    // ── The entry export: run the module inits, then main. An app that
    // links libraries first patches its own vtable words that hold library
    // data addresses (the loader has wired the __addr_ getters by the time
    // main is callable).
    XTIRFunction *mainFn = nil;
    for (XTIRFunction *fn in mod.functions)
        if ([fn.name isEqualToString:@"main"]) { mainFn = fn; break; }
    if (mainFn) {
        BOOL mainReturns = !isMemOrVoid(mainFn.returnType)
                        && mainFn.returnType.kind != XTIRTypeKindAgg;
        [out appendFormat:@"  (func (export \"main\") (result i32)\n"];
        if (sLinkLibs && sAppFixups.count)
            [out appendString:@"    call $__xtc_fixup_imports\n"];
        for (NSString *initName in mod.moduleInitFunctionNames)
            [out appendFormat:@"    call $%@\n", initName];
        // One zero per DECLARED parameter of main. This wrapper is exported
        // with no parameters (the generated loader calls `exports.main()`), so
        // whatever main takes has to be supplied here — and it used to supply
        // nothing at all. `i32 main(i32 argc, u8** argv)` therefore emitted
        // `call $main` with an empty stack, and the module was rejected by
        // every host before a single instruction ran:
        //     not enough arguments on the stack for call (need 2, got 0)
        // A one-line program is enough to trigger it, so EVERY wasm32 build
        // whose main takes argc/argv was broken (blewit FINDINGS #18b, which
        // read it as a ten-argument-call limit because that is the shape it
        // was found in).
        //
        // argc = 0 and argv = NULL: a wasm module has no command line, and a
        // conforming program reads neither when argc is 0. Passing a fake
        // non-null argv would let `argv[0]` quietly return garbage instead of
        // trapping.
        for (XTIRType *pt in mainFn.paramTypes) {
            if (isMemOrVoid(pt)) continue;      // the memory token is not a wasm param
            [out appendFormat:@"    %@.const 0\n", wasmValType(pt)];
        }
        [out appendString:@"    call $main\n"];
        if (!mainReturns) [out appendString:@"    i32.const 0\n"];
        else if (is64(mainFn.returnType)) [out appendString:@"    i32.wrap_i64\n"];
        [out appendString:@"  )\n"];
    }
    [out appendString:@")\n"];
    sMod = nil;
    sValueRank = nil;
    return sFatalImportError ? nil : out;
}

#pragma mark - Data placement

// emit-lib: write bytes into the single relative image at `at`.
+ (void)libPlace:(NSData *)bytes at:(uint32_t)at {
    if (sLibImage.length < at + bytes.length)
        [sLibImage setLength:at + bytes.length];
    if (bytes.length)
        [sLibImage replaceBytesInRange:NSMakeRange(at, bytes.length)
                             withBytes:bytes.bytes];
}

// The import signature of a bodyless external's SHELL function — used when
// an imported method is referenced by a vtable entry or taken as a value, so
// no call site exists to derive the signature from.
+ (NSString *)signatureFromShell:(XTIRFunction *)fn {
    NSMutableString *sig = [NSMutableString string];
    if (fn.returnType && fn.returnType.kind == XTIRTypeKindAgg)
        [sig appendString:@"(param i32) "];                     // sret
    for (XTIRType *t in fn.paramTypes) {
        if (isMemOrVoid(t)) continue;
        [sig appendFormat:@"(param %@) ", wasmValType(t)];
    }
    if (fn.returnType && !isMemOrVoid(fn.returnType)
        && fn.returnType.kind != XTIRTypeKindAgg)
        [sig appendFormat:@"(result %@)", wasmValType(fn.returnType)];
    return [sig stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// task #31: the spelled export/import label, when overload mangling renamed
// the symbol — rides as an expname_<name> attribute key (sema guarantees at
// most one extern per spelled name, so first match is the only match).
static NSString *wasmExportNameOf(XTIRSymbol *sym, NSString *fallback) {
    for (NSString *key in sym.attributes)
        if ([key hasPrefix:@"expname_"] && [sym.attributes[key] boolValue])
            return [key substringFromIndex:8];
    return fallback;
}

// link-libs: the package a library-owned symbol rides in (pkg_<X> attribute,
// stamped by the front end when the declaration came out of a `.xtc.iface`).
+ (NSString *)packageOfSymbol:(XTIRSymbol *)sym {
    for (NSString *key in
         [sym.attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([key hasPrefix:@"pkg_"] && [sym.attributes[key] boolValue])
            return [key substringFromIndex:4];
    }
    return @"env";
}

// link-libs: give an IMPORTED function a slot in the app's own funcref table
// (dedup'd), registering its import from the shell signature when no call
// site did. The slot's funcref is the import — calling it forwards through
// the loader's thunk into the library — so a table INDEX for an imported
// function is as good as one for a local function.
+ (uint32_t)ensureImportedFnSlot:(XTIRSymbol *)sym {
    NSNumber *have = sFnTableIndex[sym.name];
    if (have) return have.unsignedIntValue;
    if (!sImportSigs[sym.name]) {
        if ([sym.attributes[@"variadic"] boolValue]
            && [sym.attributes[@"cabi"] boolValue])
            wasmRejectVariadicImport(sym);
        sImportSigs[sym.name] = [self signatureFromShell:sym.function];
        NSString *pkg = [self packageOfSymbol:sym];
        if (![pkg isEqualToString:@"env"]) sImportPkg[sym.name] = pkg;
    }
    uint32_t idx = (uint32_t)(sFnTableOrder.count + 1);         // 0 stays null
    sFnTableIndex[sym.name] = @(idx);
    [sFnTableOrder addObject:sym.name];
    return idx;
}

// link-libs: resolve an extern data symbol through an imported
// `__addr_<name>` getter the library exports; registration is on demand and
// in first-reference order.
+ (void)ensureAddrGetterImport:(XTIRSymbol *)sym {
    NSString *impName = [@"__addr_" stringByAppendingString:sym.name];
    if (sExternAddrPkg[sym.name]) return;
    sExternAddrPkg[sym.name] = [self packageOfSymbol:sym];
    [sExternAddrOrder addObject:sym.name];
    sImportSigs[impName] = @"(result i32)";
    NSString *pkg = sExternAddrPkg[sym.name];
    if (![pkg isEqualToString:@"env"]) sImportPkg[impName] = pkg;
}

+ (void)placeDataForModule:(XTIRModule *)mod {
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind == XTIRSymbolKindStringLit) {
            NSMutableData *bytes = [NSMutableData dataWithData:sym.stringBytes ?: [NSData data]];
            // NUL-terminate (the sibling backends emit .asciz).
            uint8_t nul = 0; [bytes appendBytes:&nul length:1];
            sSymAddr[sym.name] = @(sDataEnd);
            if (sEmitLib) [self libPlace:bytes at:sDataEnd];
            else [sDataSegments addObject:
                [NSString stringWithFormat:@"  (data (i32.const %u) \"%@\") ;; %@\n",
                    sDataEnd, watStringLit(bytes), sym.name]];
            sDataEnd = alignUp32(sDataEnd + (uint32_t)bytes.length, 8);
        } else if (sym.kind == XTIRSymbolKindDataGlobal) {
            if (sym.isExternalGlobal) {
                // A library-owned global: its address arrives at run time
                // through the library's exported __addr_ getter.
                if (sLinkLibs) { [self ensureAddrGetterImport:sym]; continue; }
                [self todo:@"extern data global (multi-module)"]; continue;
            }
            uint32_t size = (uint32_t)[self wasmFieldWidth:sym.globalType] ?: 1;
            sSymAddr[sym.name] = @(sDataEnd);
            NSData *init = sym.initialBytes;
            if (init.length) {
                // A scalar float global carries the abstract value as 8 IEEE
                // double bits; an f32 slot needs them narrowed. Aggregate
                // images are already leaf-width at recorded offsets — with
                // equal widths and little-endian both sides, verbatim.
                if (sym.globalType.kind == XTIRTypeKindF32 && init.length == 8) {
                    double d; memcpy(&d, init.bytes, 8);
                    float f = (float)d;
                    init = [NSData dataWithBytes:&f length:4];
                }
                if (sEmitLib) [self libPlace:init at:sDataEnd];
                else [sDataSegments addObject:
                    [NSString stringWithFormat:@"  (data (i32.const %u) \"%@\") ;; %@\n",
                        sDataEnd, watStringLit(init), sym.name]];
            }
            // Zero-init globals need no segment: linear memory starts zeroed.
            // An EXPORTED global (extern + initialiser, §6) publishes its
            // linear-memory ADDRESS as an immutable wasm global — JS reads
            // and writes the value through the exported memory at it. A
            // LIBRARY's addresses are not constants, so it publishes an
            // __addr_ getter instead (every data global gets one below).
            if (!sEmitLib && [sym.attributes[@"exported"] boolValue])
                [sDataSegments addObject:[NSString stringWithFormat:
                    @"  (global $__exp_%@ (export \"%@\") i32 (i32.const %u))\n",
                    sym.name, sym.name, sSymAddr[sym.name].unsignedIntValue]];
            if (sEmitLib)
                [sAddrGetters addObject:@[sym.name, @(sSymAddr[sym.name].unsignedIntValue)]];
            sDataEnd = alignUp32(sDataEnd + size, 8);
        }
    }
    // ── Vtables: TWO passes, because they cross-reference — a vtable's
    // entry 0 links its PARENT's vtable, entry 1 its conformance itable
    // ($itbl — itself a vtable-kind symbol of (__protoid, $itab) pairs), so
    // every vtable's ADDRESS must exist before any vtable's WORDS encode.
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindVTable) continue;
        if (sym.isExternalGlobal) {
            // An imported class's vtable is DEFINED IN ITS LIBRARY; the app
            // reaches it through the library's __addr_ getter (RTTI compares
            // vtable ADDRESSES, so a local copy would break the downcast).
            if (sLinkLibs) [self ensureAddrGetterImport:sym];
            else [self todo:[NSString stringWithFormat:
                @"extern vtable '%@' (multi-module)", sym.name]];
            continue;
        }
        sSymAddr[sym.name] = @(sDataEnd);
        if (sEmitLib)
            [sAddrGetters addObject:@[sym.name, @(sDataEnd)]];
        NSUInteger n = (sym.vtableEntryNames ?: @[]).count;
        sDataEnd = alignUp32(sDataEnd + (uint32_t)(n * 4), 8);
    }
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindVTable) continue;
        if (sym.isExternalGlobal) continue;
        // One 4-byte word per slot. An entry resolves as, in order:
        //   ""/"_"          → 0 (empty slot: falsy for respondsTo, traps if
        //                       dispatched — the funcref index-0 contract)
        //   __protoid_<n>   → the literal protocol id
        //   a function name → its FUNCREF TABLE INDEX
        //   a data symbol   → its linear-memory ADDRESS (parent vtbl / $itbl
        //                     / $itab references)
        // A library's index/address words cannot be computed by a data
        // segment — they are emitted as ZERO and patched by
        // __wasm_apply_relocs. An app's word naming a LIBRARY symbol takes
        // an imported-function table slot (functions) or a fixup through the
        // __addr_ getter (data) applied before the module inits run.
        NSArray<NSString *> *entries = sym.vtableEntryNames ?: @[];
        NSMutableData *words = [NSMutableData dataWithLength:entries.count * 4];
        uint32_t *w = words.mutableBytes;
        uint32_t base = sSymAddr[sym.name].unsignedIntValue;
        for (NSUInteger i = 0; i < entries.count; i++) {
            NSString *e = entries[i];
            if (e.length == 0 || [e isEqualToString:@"_"]) { w[i] = 0; continue; }
            if ([e hasPrefix:@"__protoid_"]) {
                w[i] = (uint32_t)[e substringFromIndex:@"__protoid_".length].longLongValue;
                continue;
            }
            NSNumber *idx = sFnTableIndex[e];
            if (idx) {
                if (sEmitLib) {
                    w[i] = 0;
                    [sLibRelocs addObject:@[@(base + i * 4), @"fn", idx]];
                } else {
                    w[i] = idx.unsignedIntValue;
                }
                continue;
            }
            NSNumber *addr = sSymAddr[e];
            if (addr) {
                if (sEmitLib) {
                    w[i] = 0;
                    [sLibRelocs addObject:@[@(base + i * 4), @"data", addr]];
                } else {
                    w[i] = addr.unsignedIntValue;
                }
                continue;
            }
            XTIRSymbol *ext = [mod symbolForName:e];
            if (sLinkLibs && ext && ext.kind == XTIRSymbolKindFunction
                && ext.function) {
                w[i] = [self ensureImportedFnSlot:ext];
                continue;
            }
            if (sLinkLibs && ext
                && (ext.kind == XTIRSymbolKindVTable
                    || ext.kind == XTIRSymbolKindDataGlobal)
                && ext.isExternalGlobal) {
                [self ensureAddrGetterImport:ext];
                w[i] = 0;
                [sAppFixups addObject:@[@(base + i * 4), e]];
                continue;
            }
            [self todo:[NSString stringWithFormat:
                @"vtable entry '%@' resolves to neither function nor data", e]];
            w[i] = 0;
        }
        if (sEmitLib) [self libPlace:words at:base];
        else [sDataSegments addObject:
            [NSString stringWithFormat:@"  (data (i32.const %u) \"%@\") ;; %@\n",
                base, watStringLit(words), sym.name]];
    }
    // Constant-pool aggregates (ConstAgg operands) — flattened to bytes at
    // the RECORDED layout offsets; read-only, so the SSA value can alias the
    // pool address directly.
    for (NSUInteger i = 0; i < mod.constants.count; i++) {
        NSData *bytes = [self bytesOfConstant:mod.constants[i]];
        if (!bytes.length) continue;
        sConstAddr[@(i)] = @(sDataEnd);
        if (sEmitLib) [self libPlace:bytes at:sDataEnd];
        else [sDataSegments addObject:
            [NSString stringWithFormat:@"  (data (i32.const %u) \"%@\") ;; const %lu\n",
                sDataEnd, watStringLit(bytes), (unsigned long)i]];
        sDataEnd = alignUp32(sDataEnd + (uint32_t)bytes.length, 8);
    }
}

// Flatten a structured constant into its in-memory image: leaves LE at their
// widths, aggregate elements at the RECORDED field offsets (gaps stay zero).
+ (NSData *)bytesOfConstant:(XTIRConstant *)c {
    if (!c) return [NSData data];
    switch (c.kind) {
        case XTIRConstantKindInt: {
            uint32_t w = c.type ? (c.type.byteWidth ?: 4) : 4;
            uint64_t v = (uint64_t)c.intValue;
            uint8_t b[8];
            for (uint32_t i = 0; i < w && i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
            return [NSData dataWithBytes:b length:MIN(w, 8u)];
        }
        case XTIRConstantKindFloat: {
            uint64_t raw = c.floatRawBytes;
            double d; memcpy(&d, &raw, 8);
            if (c.type && c.type.kind == XTIRTypeKindF32) {
                float f = (float)d;
                return [NSData dataWithBytes:&f length:4];
            }
            return [NSData dataWithBytes:&d length:8];
        }
        case XTIRConstantKindString:
            return c.stringBytes ?: [NSData data];
        case XTIRConstantKindAgg: {
            XTIRLayout *lay = c.type.layout;
            NSMutableData *buf =
                [NSMutableData dataWithLength:[self wasmAggSize:lay]];
            NSUInteger n = MIN(lay.fields.count, c.elements.count);
            for (NSUInteger i = 0; i < n; i++) {
                NSData *fb = [self bytesOfConstant:c.elements[i]];
                NSUInteger off = lay.fields[i].byteOffset;
                if (off + fb.length <= buf.length)
                    [buf replaceBytesInRange:NSMakeRange(off, fb.length)
                                   withBytes:fb.bytes];
            }
            return buf;
        }
    }
    return [NSData data];
}

#pragma mark - Import signatures

+ (NSString *)signatureForCallTo:(XTIRSymbol *)sym insn:(XTIRInsn *)insn fn:(XTIRFunction *)fn {
    NSMutableString *sig = [NSMutableString string];
    for (NSUInteger i = 1; i < insn.operands.count; i++) {
        XTIROperand *op = insn.operands[i];
        XTIRType *t = (op.kind == XTIROperandKindUse)
            ? fn.values[@(op.valueId)].type : op.type;
        if (isMemOrVoid(t)) continue;
        [sig appendFormat:@"(param %@) ", wasmValType(t)];
    }
    if (insn.result && !isMemOrVoid(insn.result.type))
        [sig appendFormat:@"(result %@)", wasmValType(insn.result.type)];
    return [sig stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// The declared functype for an indirect-call site: params from the pushed
// argument value types (sret first when the result is an aggregate), result
// from the instruction's. Interned; the name feeds `call_indirect (type $n)`.
+ (NSString *)indirectTypeForArgs:(NSArray<XTIRType *> *)argTypes
                           result:(XTIRType * _Nullable)resType {
    NSMutableString *sig = [NSMutableString string];
    BOOL sret = resType && resType.kind == XTIRTypeKindAgg;
    if (sret) [sig appendString:@"(param i32) "];
    for (XTIRType *t in argTypes) [sig appendFormat:@"(param %@) ", wasmValType(t)];
    if (resType && !isMemOrVoid(resType) && !sret)
        [sig appendFormat:@"(result %@)", wasmValType(resType)];
    NSString *key = [sig stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    NSString *name = sIndirectTypes[key];
    if (!name) {
        name = [NSString stringWithFormat:@"it%lu", (unsigned long)sIndirectTypes.count];
        sIndirectTypes[key] = name;
    }
    return name;
}

+ (void)collectImportsForModule:(XTIRModule *)mod {
    for (XTIRFunction *fn in mod.functions) {
        for (XTIRBlock *b in fn.blocks) {
            NSMutableArray<XTIRInsn *> *all = [NSMutableArray arrayWithArray:b.instructions];
            if (b.terminator) [all addObject:b.terminator];
            for (XTIRInsn *insn in all) {
                if (insn.opcode != XTIROpCall && insn.opcode != XTIROpCallCloaked
                    && insn.opcode != XTIROpCallBanked) continue;
                if (insn.operands.count < 1
                    || insn.operands[0].kind != XTIROperandKindSym) continue;
                XTIRSymbol *sym = [mod symbolForId:insn.operands[0].symbolId];
                if (!sym || [sDefinedFns containsObject:sym.name]) continue;
                // A bodyless external carries a SHELL XTIRFunction (empty
                // entry, no terminator) on its symbol, so "has a function
                // object" is not the test — "is among the module's defined
                // functions" is. Runtime helpers resolve the same way (host
                // imports) until their wasm-side implementations land.
                if (sym.kind != XTIRSymbolKindFunction
                    && sym.kind != XTIRSymbolKindRuntimeHelper) continue;
                if (!sImportSigs[sym.name]) {
                    if ([sym.attributes[@"variadic"] boolValue]
                        && [sym.attributes[@"cabi"] boolValue])
                        wasmRejectVariadicImport(sym);
                    sImportSigs[sym.name] = [self signatureForCallTo:sym insn:insn fn:fn];
                    // The `#package` binding rides as a pkg_<name> attribute;
                    // default package is "env".
                    for (NSString *key in sym.attributes) {
                        if ([key hasPrefix:@"pkg_"] && [sym.attributes[key] boolValue]) {
                            sImportPkg[sym.name] = [key substringFromIndex:4];
                            break;
                        }
                    }
                }
            }
        }
    }
    // A library reaches the APP's runtime through env imports (decision 3).
    // Retain/Release and the weak family are emitted as direct `call`s by
    // their opcodes (no XTIROpCall to derive from), and the _xtc_new_ stubs
    // call _xtc_alloc — declare those imports here with their fixed shapes.
    if (sEmitLib) {
        if (sNeedsARC) {
            sImportSigs[@"__xtc_retain"] = @"(param i32)";
            sImportSigs[@"__xtc_release"] = @"(param i32)";
        }
        if (sNeedsWeakReg)
            sImportSigs[@"_xtc_weak_register"] = @"(param i32) (param i32)";
        if (sNeedsWeakUnreg)
            sImportSigs[@"_xtc_weak_unregister"] = @"(param i32)";
        if (sNeedsAlloc)
            sImportSigs[@"_xtc_alloc"] = @"(param i32) (param i32) (param i32) (result i32)";
    }
}

#pragma mark - Function emission

+ (void)emitFunction:(XTIRFunction *)fn module:(XTIRModule *)mod into:(NSMutableString *)out {
    XTWasmFnCtx *ctx = [XTWasmFnCtx new];
    ctx.fn = fn;
    ctx.pinnedOffset = [NSMutableDictionary dictionary];
    ctx.aggSlot = [NSMutableDictionary dictionary];
    ctx.declared = [NSMutableSet set];
    ctx.hasSret = fn.returnType && fn.returnType.kind == XTIRTypeKindAgg;

    // ── Local-name map (-O1+): the rank of every value id that appears in
    // the FINAL body (params included), ascending — see sValueRank above.
    // Dead registered values (id gaps) get no local, no slot, no name.
    sValueRank = nil;
    ctx.orderedIds = nil;
    if (sOptLevel >= 1) {
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        for (NSUInteger i = 0; i < fn.paramTypes.count; i++) [seen addObject:@(i)];
        for (XTIRBlock *bb in fn.blocks) {
            NSMutableArray<XTIRInsn *> *all = [NSMutableArray arrayWithArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator) [all addObject:bb.terminator];
            for (XTIRInsn *insn in all) {
                if (insn.result) [seen addObject:@(insn.result.valueId)];
                if (insn.memoryResult) [seen addObject:@(insn.memoryResult.valueId)];
                for (XTIROperand *op in insn.operands)
                    if (op.kind == XTIROperandKindUse) [seen addObject:@(op.valueId)];
            }
        }
        NSArray<NSNumber *> *ordered =
            [seen.allObjects sortedArrayUsingSelector:@selector(compare:)];
        NSMutableDictionary<NSNumber *, NSNumber *> *rank = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < ordered.count; i++) rank[ordered[i]] = @(i);
        sValueRank = rank;
        ctx.orderedIds = ordered;
    }

    // Frame: pinned locals RE-LAID at wasm widths — the IR's own frame
    // accounting gives a POINTER width 0 ("storage is the target's
    // business"), so the recorded pinned byteOffsets overlap at 0 and every
    // backend lays its own frame. (Struct FIELD offsets are the recorded
    // ones — that contract is about types, not frames.) Then one slot per
    // Agg-typed SSA value, 8-aligned.
    uint32_t frame = 0;
    for (XTIRPinnedLocal *pl in fn.frameInfo.pinnedLocals) {
        uint32_t w = (uint32_t)[self wasmFieldWidth:pl.type] ?: 4;
        uint32_t a = w >= 8 ? 8 : (w >= 4 ? 4 : (w >= 2 ? 2 : 1));
        frame = alignUp32(frame, a);
        ctx.pinnedOffset[@(pl.valueId)] = @(frame);
        frame += w;
    }
    frame = alignUp32(frame, 8);
    // -O1+: only ids in the final body get slots (ctx.orderedIds, ascending);
    // -O0: every registered id, exactly as before.
    NSUInteger slotIdCount = ctx.orderedIds ? ctx.orderedIds.count : fn.nextValueId;
    for (NSUInteger si = 0; si < slotIdCount; si++) {
        XTIRValueId vid = ctx.orderedIds
            ? (XTIRValueId)ctx.orderedIds[si].unsignedIntegerValue : (XTIRValueId)si;
        XTIRValue *v = fn.values[@(vid)];
        if (!v || v.type.kind != XTIRTypeKindAgg) continue;
        if (ctx.pinnedOffset[@(vid)]) continue;      // storage already pinned
        if (vid < fn.paramTypes.count) continue;     // params ARRIVE as an
                                                     // address — never clobber
                                                     // it with an empty slot
        ctx.aggSlot[@(vid)] = @(frame);
        frame = alignUp32(frame + (uint32_t)[self wasmAggSize:v.type.layout], 8);
    }
    ctx.frameSize = alignUp32(frame, 16);

    // ── Signature. Wasm params ARE locals 0..n-1, so declare params in
    // value-id order (the memory token, always last, gets no wasm param —
    // it has no representation). An Agg return adds a leading $sret param.
    // `extern`-on-a-definition exports the function under its own name
    // (already a DFE root — §6's load-bearing half).
    XTIRSymbol *fnSym = [mod symbolForName:fn.name];
    // --emit-lib: every defined function IS the public surface — export it
    // by its (mangled) name so the app's package thunks can reach it.
    BOOL exported = sEmitLib || [fnSym.attributes[@"exported"] boolValue];
    [out appendFormat:@"  (func $%@", fn.name];
    if (exported) [out appendFormat:@" (export \"%@\")", wasmExportNameOf(fnSym, fn.name)];
    if (ctx.hasSret) [out appendString:@" (param $sret i32)"];
    NSUInteger nParams = fn.paramTypes.count;
    for (NSUInteger i = 0; i < nParams; i++) {
        XTIRType *pt = fn.paramTypes[i];
        if (pt.kind == XTIRTypeKindMemory) continue;
        [out appendFormat:@" (param $v%lu %@)",
                          (unsigned long)vnum((uint32_t)i), wasmValType(pt)];
        [ctx.declared addObject:@(i)];
    }
    BOOL scalarRet = fn.returnType && !isMemOrVoid(fn.returnType)
                  && fn.returnType.kind != XTIRTypeKindAgg;
    if (scalarRet) [out appendFormat:@" (result %@)", wasmValType(fn.returnType)];
    [out appendString:@"\n"];

    // ── Control-flow mode. -O0 (and any function the plan rejects) keeps
    // the bring-up dispatch loop — the wasm-diff oracle form, byte for byte.
    // -O1+ emits real nested block/loop/if from the dominator tree; $pc
    // exists only in dispatch mode.
    NSArray<XTIRBlock *> *blocks = fn.blocks;
    NSUInteger n = blocks.count;
    NSMutableDictionary<NSValue *, NSNumber *> *blockIndex = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < n; i++)
        blockIndex[[NSValue valueWithNonretainedObject:blocks[i]]] = @(i);
    XTWasmCFGPlan *plan = nil;
    if (sOptLevel >= 1) {
        plan = [self structurePlanForFunction:fn blockIndex:blockIndex];
        if (!plan && n)
            fprintf(stderr, "xcc-cg-wasm32: note: '%s' falls back to the "
                            "dispatch loop (irreducible or unknown terminator)\n",
                    fn.name.UTF8String);
    }

    // ── Locals: $pc (dispatch mode only) + frame pointer + one per
    // remaining value id.
    if (plan) [out appendString:@"    (local $fp i32)\n"];
    else      [out appendString:@"    (local $pc i32) (local $fp i32)\n"];
    NSUInteger declIdCount = ctx.orderedIds ? ctx.orderedIds.count : fn.nextValueId;
    for (NSUInteger di = 0; di < declIdCount; di++) {
        XTIRValueId vid = ctx.orderedIds
            ? (XTIRValueId)ctx.orderedIds[di].unsignedIntegerValue : (XTIRValueId)di;
        if ([ctx.declared containsObject:@(vid)]) continue;
        XTIRValue *v = fn.values[@(vid)];
        if (!v || isMemOrVoid(v.type)) continue;
        // A PINNED local (one whose address is taken) holds its frame ADDRESS,
        // not its value — the prologue below seeds it with `$fp + off`. Its
        // declared type must therefore be i32 whatever the value's type is.
        // Declaring it from the value type was invisible while every pinned
        // local was 32 bits or narrower (i32 either way), but `u64 v; u64@ p =
        // &v;` declared an i64 local and then `local.set` an i32 address into
        // it — a module the engine rejects outright ("local.set[0] expected
        // type i64, found i32.add of type i32"). A pinned f32/f64 was the same
        // shape waiting to happen.
        BOOL holdsAddr = (ctx.pinnedOffset[@(vid)] != nil) || (ctx.aggSlot[@(vid)] != nil);
        [out appendFormat:@"    (local $v%u %@)\n", vnum(vid),
                          holdsAddr ? @"i32" : wasmValType(v.type)];
        [ctx.declared addObject:@(vid)];
    }

    // ── Prologue: push the shadow frame, trap on overflow (§3), ZERO it
    // (ARC enrolment and out-parameters assume fresh locals read nil — a
    // reused stack region hands stale bytes to the first Release otherwise),
    // and seed the address locals for pinned locals and agg slots.
    if (ctx.frameSize) {
        [out appendFormat:@"    global.get $__sp\n    i32.const %u\n    i32.sub\n"
                          @"    local.tee $fp\n    global.get $__stack_low\n"
                          @"    i32.lt_u\n    if\n      unreachable\n    end\n"
                          @"    local.get $fp\n    global.set $__sp\n"
                          @"    local.get $fp\n    i32.const 0\n    i32.const %u\n"
                          @"    memory.fill\n", ctx.frameSize, ctx.frameSize];
    } else {
        [out appendString:@"    global.get $__sp\n    local.set $fp\n"];
    }
    // Ascending value id, NOT dictionary enumeration: CFBasicHash order is
    // deterministic but incidental, and the self-hosted port would have to
    // simulate the hash to match it (it briefly did — fix the ORIGINAL is
    // the rule the earlier ports established).
    for (NSNumber *vid in [ctx.pinnedOffset.allKeys
                              sortedArrayUsingSelector:@selector(compare:)]) {
        if (![ctx.declared containsObject:vid]) continue;
        [out appendFormat:@"    local.get $fp\n    i32.const %u\n    i32.add\n"
                          @"    local.set $v%u\n",
                          ctx.pinnedOffset[vid].unsignedIntValue,
                          vnum(vid.unsignedIntValue)];
    }
    for (NSNumber *vid in [ctx.aggSlot.allKeys
                              sortedArrayUsingSelector:@selector(compare:)]) {
        if (![ctx.declared containsObject:vid]) continue;
        [out appendFormat:@"    local.get $fp\n    i32.const %u\n    i32.add\n"
                          @"    local.set $v%u\n",
                          ctx.aggSlot[vid].unsignedIntValue,
                          vnum(vid.unsignedIntValue)];
    }

    // ── Structured mode: the dominator-tree walk from the entry. Every
    // path ends in return/unreachable/br, so the trailing `unreachable`
    // only satisfies the validator (as it does after the dispatch loop).
    if (plan) {
        [self emitStructuredTree:0 plan:plan fn:fn module:mod ctx:ctx
                      blockIndex:blockIndex out:out];
        [out appendString:@"    unreachable\n  )\n"];
        return;
    }

    // ── The dispatch loop: one block arm per IR block, $pc selects. ───────
    [out appendString:@"    loop $dispatch\n"];
    for (NSUInteger i = n; i > 0; i--)
        [out appendFormat:@"    block $B%lu\n", (unsigned long)(i - 1)];
    [out appendString:@"    local.get $pc\n    br_table"];
    for (NSUInteger i = 0; i < n; i++) [out appendFormat:@" $B%lu", (unsigned long)i];
    [out appendFormat:@" $B%lu\n", (unsigned long)(n - 1)];
    for (NSUInteger i = 0; i < n; i++) {
        [out appendFormat:@"    end ;; $B%lu — %@\n", (unsigned long)i,
                          blocks[i].name ?: @"?"];
        XTIRBlock *b = blocks[i];
        XTIRInsn *tail = [self tailCallableInsn:b fn:fn ctx:ctx];
        for (XTIRInsn *insn in b.instructions) {
            if (insn == tail) continue;   // fused into return_call below
            [self emitInsn:insn fn:fn module:mod ctx:ctx out:out];
        }
        if (tail)
            [self emitTailCall:tail fn:fn module:mod ctx:ctx out:out];
        else
            [self emitTerminator:b.terminator block:b fn:fn module:mod ctx:ctx
                      blockIndex:blockIndex out:out];
    }
    [out appendString:@"    end ;; loop $dispatch\n    unreachable\n  )\n"];
}

// ── Tail calls (-x-wasm32,return-call) ─────────────────────────────────────
// A block whose LAST instruction is a call whose result the terminator
// immediately Returns fuses into `return_call` — the callee replaces this
// frame, so mutual recursion and indirect tails stop growing either stack.
// Constraints, all load-bearing:
//   * frameSize == 0 and no sret — a shadow frame would have to pop BEFORE
//     the call, and any pointer argument into it would then dangle; the
//     interesting tails (scalar mutual recursion) have no frame.
//   * result/return wasm valtypes identical (or both void).
//   * direct Call or CallIndirect only (the banked/cloaked forms collapse to
//     Call on this target before they get here; dispatch forms stay calls).
+ (nullable XTIRInsn *)tailCallableInsn:(XTIRBlock *)b fn:(XTIRFunction *)fn
                                    ctx:(XTWasmFnCtx *)ctx {
    if (!sTailCalls || ctx.frameSize || ctx.hasSret) return nil;
    XTIRInsn *term = b.terminator;
    if (!term || term.opcode != XTIROpReturn) return nil;
    XTIRInsn *last = b.instructions.lastObject;
    if (!last) return nil;
    if (last.opcode != XTIROpCall && last.opcode != XTIROpCallIndirect) return nil;
    NSArray<XTIROperand *> *dops = [self dataOperandsOf:last fn:fn];
    if (last.opcode == XTIROpCall
        && (dops.count < 1 || dops[0].kind != XTIROperandKindSym))
        return nil;
    XTIRValue *res = last.result;
    BOOL callVoid = !res || isMemOrVoid(res.type);
    BOOL fnVoid = !fn.returnType || isMemOrVoid(fn.returnType);
    if (callVoid != fnVoid) return nil;
    if (fnVoid) return last;
    if (res.type.kind == XTIRTypeKindAgg || fn.returnType.kind == XTIRTypeKindAgg)
        return nil;
    // The returned value must BE the call's result…
    XTIROperand *val = term.operands.firstObject;
    if (!val || val.kind != XTIROperandKindUse || val.valueId != res.valueId)
        return nil;
    // …and the wasm valtypes must agree exactly (the engine validates).
    if (![wasmValType(res.type) isEqualToString:wasmValType(fn.returnType)])
        return nil;
    return last;
}

+ (void)emitTailCall:(XTIRInsn *)call fn:(XTIRFunction *)fn
              module:(XTIRModule *)mod ctx:(XTWasmFnCtx *)ctx
                 out:(NSMutableString *)out {
    // dataOperandsOf:, NOT .operands: the raw list carries the memory token,
    // which emitInsn's normal path filters the same way.
    NSArray<XTIROperand *> *ops = [self dataOperandsOf:call fn:fn];
    if (call.opcode == XTIROpCall) {
        XTIRSymbol *callee = [mod symbolForId:ops[0].symbolId];
        for (NSUInteger i = 1; i < ops.count; i++)
            [self pushOperand:ops[i] fn:fn out:out];
        [out appendFormat:@"    return_call $%@\n", callee.name];
        return;
    }
    NSMutableArray<XTIRType *> *argTys = [NSMutableArray array];
    for (NSUInteger i = 1; i < ops.count; i++) {
        XTIROperand *a = ops[i];
        XTIRType *t = (a.kind == XTIROperandKindUse)
            ? fn.values[@(a.valueId)].type : a.type;
        [argTys addObject:t ?: [XTIRType i32Type]];
        [self pushOperand:a fn:fn out:out];
    }
    [self pushOperand:ops[0] fn:fn out:out];
    XTIRType *rt = (call.result && !isMemOrVoid(call.result.type)) ? call.result.type : nil;
    NSString *ty = [self indirectTypeForArgs:argTys result:rt];
    [out appendFormat:@"    return_call_indirect (type $%@)\n", ty];
}

#pragma mark - Operand loading

// Push a branch or select condition as the i32 that `if` and `select` take. An
// i64, f32 or f64 condition is tested against zero in its own type: pushed as
// it was, it made a module that does not validate (bug 293).
+ (void)pushCondition:(XTIROperand *)op fn:(XTIRFunction *)fn out:(NSMutableString *)out {
    [self pushOperand:op fn:fn out:out];
    XTIRType *t = (op.kind == XTIROperandKindUse) ? fn.values[@(op.valueId)].type : op.type;
    NSString *vt = wasmValType(t);
    if ([vt isEqualToString:@"i64"] || [vt isEqualToString:@"f32"] || [vt isEqualToString:@"f64"])
        [out appendFormat:@"    %@.const 0\n    %@.ne\n", vt, vt];
}

// Push one operand onto the wasm stack.
+ (void)pushOperand:(XTIROperand *)op fn:(XTIRFunction *)fn out:(NSMutableString *)out {
    switch (op.kind) {
        case XTIROperandKindUse:
            [out appendFormat:@"    local.get $v%u\n", vnum(op.valueId)];
            return;
        case XTIROperandKindImmI: {
            XTIRType *t = op.type;
            // An INTEGER immediate can carry a FLOAT type — `Const #0:F64` is
            // how a double zero is lowered — and it must become a float
            // constant, or the module is `i32.const 0` into an f64 local:
            // invalid, refused by every runtime at load. 15 fixtures shipped
            // that way (bug 131); the corpus does not run wasm32 on this host
            // and lnwasm-diff compared two writers agreeing on it.
            if (t && t.kind == XTIRTypeKindF64)
                [out appendFormat:@"    f64.const %a\n", (double)op.intValue];
            else if (t && t.kind == XTIRTypeKindF32)
                [out appendFormat:@"    f32.const %a\n", (double)(float)op.intValue];
            else if (is64(t)) [out appendFormat:@"    i64.const %lld\n", (long long)op.intValue];
            else [out appendFormat:@"    i32.const %d\n", (int32_t)op.intValue];
            return;
        }
        case XTIROperandKindImmF: {
            uint64_t raw = op.floatRawBytes;
            double d; memcpy(&d, &raw, 8);
            if (op.type && op.type.kind == XTIRTypeKindF32)
                [out appendFormat:@"    f32.const %a\n", (double)(float)d];
            else
                [out appendFormat:@"    f64.const %a\n", d];
            return;
        }
        case XTIROperandKindSym: {
            XTIRSymbol *sym = [sMod symbolForId:op.symbolId];
            NSNumber *addr = sym ? sSymAddr[sym.name] : nil;
            // A FUNCTION's "address" is its funcref-table index (§4): data
            // pointers and function pointers live in different index spaces.
            NSNumber *fnIdx = sym ? sFnTableIndex[sym.name] : nil;
            if (addr) {
                // A library's data addresses are RELATIVE — rebase off
                // __memory_base at every constant site (decision 2).
                if (sEmitLib)
                    [out appendFormat:@"    global.get $__memory_base\n"
                                      @"    i32.const %u\n    i32.add ;; &%@\n",
                                      addr.unsignedIntValue, sym.name];
                else
                    [out appendFormat:@"    i32.const %u ;; &%@\n",
                                      addr.unsignedIntValue, sym.name];
            } else if (fnIdx) {
                if (sEmitLib)
                    [out appendFormat:@"    global.get $__table_base\n"
                                      @"    i32.const %u\n    i32.add ;; table:%@\n",
                                      fnIdx.unsignedIntValue, sym.name];
                else
                    [out appendFormat:@"    i32.const %u ;; table:%@\n",
                                      fnIdx.unsignedIntValue, sym.name];
            } else if (sLinkLibs && sym && sym.isExternalGlobal
                       && (sym.kind == XTIRSymbolKindVTable
                           || sym.kind == XTIRSymbolKindDataGlobal)) {
                // Library-owned data: its runtime address comes through the
                // library's exported getter (wired before main is callable).
                [XTWasmBackend ensureAddrGetterImport:sym];
                [out appendFormat:@"    call $__addr_%@ ;; &%@ (import)\n",
                                  sym.name, sym.name];
            } else if (sLinkLibs && sym && sym.kind == XTIRSymbolKindFunction
                       && sym.function && ![sDefinedFns containsObject:sym.name]) {
                // An imported function taken as a VALUE gets a slot in the
                // app's own table (the funcref is the import's thunk).
                uint32_t slot = [XTWasmBackend ensureImportedFnSlot:sym];
                [out appendFormat:@"    i32.const %u ;; table:%@ (import)\n",
                                  slot, sym.name];
            } else {
                [XTWasmBackend todo:[NSString stringWithFormat:@"address of symbol '%@'",
                                     sym.name ?: @"?"]];
                [out appendString:@"    i32.const 0\n"];
            }
            return;
        }
        case XTIROperandKindConstAgg: {
            NSNumber *addr = sConstAddr[@(op.constantId)];
            if (sEmitLib)
                [out appendFormat:@"    global.get $__memory_base\n"
                                  @"    i32.const %u\n    i32.add ;; const pool\n",
                                  addr ? addr.unsignedIntValue : 0];
            else
                [out appendFormat:@"    i32.const %u ;; const pool\n",
                                  addr ? addr.unsignedIntValue : 0];
            return;
        }
        default:
            [out appendString:@"    i32.const 0 ;; TODO operand kind\n"];
            return;
    }
}

// Set the instruction's result local from the value on the stack, applying
// the canonical mask for narrow results.
+ (void)setResult:(XTIRValue *)res canon:(BOOL)canon out:(NSMutableString *)out {
    if (!res || isMemOrVoid(res.type)) { [out appendString:@"    drop\n"]; return; }
    if (canon) {
        NSString *c = canonSuffix(res.type);
        if (c) [out appendString:c];
    }
    [out appendFormat:@"    local.set $v%u\n", vnum(res.valueId)];
}

// The wasm type prefix ("i32"/"i64"/"f32"/"f64") governing an operation on
// values of type t.
static NSString *opPrefix(XTIRType *t) { return wasmValType(t); }

// A shift/rotate count must match the operation width; the IR's count is
// often a narrow (u8) value living in an i32 local.
+ (void)widenCount:(XTIROperand *)count toPrefix:(NSString *)p
                fn:(XTIRFunction *)fn out:(NSMutableString *)out {
    if (![p isEqualToString:@"i64"]) return;
    XTIRType *ct = (count.kind == XTIROperandKindUse)
        ? fn.values[@(count.valueId)].type : count.type;
    if (!is64(ct)) [out appendString:@"    i64.extend_i32_u\n"];
}

// Memory-typed operands (the token) are invisible to wasm.
+ (NSArray<XTIROperand *> *)dataOperandsOf:(XTIRInsn *)insn fn:(XTIRFunction *)fn {
    NSMutableArray *r = [NSMutableArray array];
    for (XTIROperand *op in insn.operands) {
        if (op.kind == XTIROperandKindUse) {
            XTIRValue *v = fn.values[@(op.valueId)];
            if (v && v.type.kind == XTIRTypeKindMemory) continue;
        }
        [r addObject:op];
    }
    return r;
}

#pragma mark - Instructions

+ (void)emitInsn:(XTIRInsn *)insn fn:(XTIRFunction *)fn module:(XTIRModule *)mod
             ctx:(XTWasmFnCtx *)ctx out:(NSMutableString *)out {
    NSArray<XTIROperand *> *ops = [self dataOperandsOf:insn fn:fn];
    XTIRValue *res = insn.result;

    switch (insn.opcode) {

    // ── Constants and moves ────────────────────────────────────────────────
    case XTIROpConst:
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self setResult:res canon:YES out:out];
        return;
    case XTIROpCopy:
    case XTIROpBitcast:
    case XTIROpIntToPtr:
    case XTIROpPtrToInt: {
        if (!res || ops.count < 1) return;
        XTIROperand *src = ops[0];
        XTIRType *st = (src.kind == XTIROperandKindUse)
            ? fn.values[@(src.valueId)].type : src.type;
        [self pushOperand:src fn:fn out:out];
        // Same-representation moves are free; cross-representation Bitcast
        // reinterprets bits.
        NSString *from = wasmValType(st), *to = wasmValType(res.type);
        if (![from isEqualToString:to]) {
            if ([from isEqualToString:@"f32"] && [to isEqualToString:@"i32"])
                [out appendString:@"    i32.reinterpret_f32\n"];
            else if ([from isEqualToString:@"i32"] && [to isEqualToString:@"f32"])
                [out appendString:@"    f32.reinterpret_i32\n"];
            else if ([from isEqualToString:@"f64"] && [to isEqualToString:@"i64"])
                [out appendString:@"    i64.reinterpret_f64\n"];
            else if ([from isEqualToString:@"i64"] && [to isEqualToString:@"f64"])
                [out appendString:@"    f64.reinterpret_i64\n"];
            else if ([from isEqualToString:@"i64"] && [to isEqualToString:@"i32"])
                [out appendString:@"    i32.wrap_i64\n"];
            else if ([from isEqualToString:@"i32"] && [to isEqualToString:@"i64"])
                [out appendString:@"    i64.extend_i32_u\n"];
            else
                [XTWasmBackend todo:@"exotic Bitcast"];
        }
        [self setResult:res canon:(insn.opcode != XTIROpCopy) out:out];
        return;
    }

    // ── Integer arithmetic ─────────────────────────────────────────────────
    case XTIROpAdd: case XTIROpSub: case XTIROpMul:
    case XTIROpAnd: case XTIROpOr:  case XTIROpXor: {
        if (!res || ops.count < 2) return;
        static NSDictionary *mn;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ mn = @{ @(XTIROpAdd): @"add", @(XTIROpSub): @"sub",
                                        @(XTIROpMul): @"mul", @(XTIROpAnd): @"and",
                                        @(XTIROpOr): @"or",   @(XTIROpXor): @"xor" }; });
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    %@.%@\n", opPrefix(res.type), mn[@(insn.opcode)]];
        [self setResult:res canon:YES out:out];
        return;
    }
    case XTIROpSDiv: case XTIROpUDiv: case XTIROpSRem: case XTIROpURem: {
        if (!res || ops.count < 2) return;
        NSString *m = insn.opcode == XTIROpSDiv ? @"div_s"
                    : insn.opcode == XTIROpUDiv ? @"div_u"
                    : insn.opcode == XTIROpSRem ? @"rem_s" : @"rem_u";
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        // wasm traps on ÷0 and INT_MIN/−1 — documented divergence (§7).
        [out appendFormat:@"    %@.%@\n", opPrefix(res.type), m];
        [self setResult:res canon:YES out:out];
        return;
    }
    case XTIROpNeg: {
        if (!res || ops.count < 1) return;
        NSString *p = opPrefix(res.type);
        [out appendFormat:@"    %@.const 0\n", p];
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    %@.sub\n", p];
        [self setResult:res canon:YES out:out];
        return;
    }
    case XTIROpNot: {
        if (!res || ops.count < 1) return;
        NSString *p = opPrefix(res.type);
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    %@.const -1\n    %@.xor\n", p, p];
        [self setResult:res canon:YES out:out];
        return;
    }

    // ── Shifts and rotates ─────────────────────────────────────────────────
    case XTIROpShl: case XTIROpLShr: case XTIROpAShr: {
        if (!res || ops.count < 2) return;
        NSString *p = opPrefix(res.type);
        [self pushOperand:ops[0] fn:fn out:out];
        // LShr must not shift canonical SIGN-extension bits back in — mask to
        // the SOURCE's width first, and only when the source is a signed
        // narrow type (unsigned canonicals are already zero-masked; keying
        // this off the RESULT type once turned `(u16)1000 >> 8` with a
        // u8-typed result into `(1000 & 0xFF) >> 8` = 0). AShr WANTS the sign
        // bits; Shl discards them on re-canonicalisation.
        if (insn.opcode == XTIROpLShr) {
            XTIROperand *src = ops[0];
            XTIRType *st = (src.kind == XTIROperandKindUse)
                ? fn.values[@(src.valueId)].type : src.type;
            if (st && st.kind == XTIRTypeKindI8)
                [out appendString:@"    i32.const 255\n    i32.and\n"];
            else if (st && st.kind == XTIRTypeKindI16)
                [out appendString:@"    i32.const 65535\n    i32.and\n"];
        }
        [self pushOperand:ops[1] fn:fn out:out];
        // wasm shift counts must match the operand width; the IR's count is
        // often narrow (u8), which lands in an i32 local.
        [self widenCount:ops[1] toPrefix:p fn:fn out:out];
        [out appendFormat:@"    %@.%@\n", p,
            insn.opcode == XTIROpShl ? @"shl"
          : insn.opcode == XTIROpLShr ? @"shr_u" : @"shr_s"];
        [self setResult:res canon:YES out:out];
        return;
    }
    case XTIROpRol: case XTIROpRor: {
        if (!res || ops.count < 2) return;
        uint32_t w = res.type ? res.type.byteWidth : 4;
        NSString *p = opPrefix(res.type);
        if (w >= 4 || [p isEqualToString:@"i64"]) {
            [self pushOperand:ops[0] fn:fn out:out];
            [self pushOperand:ops[1] fn:fn out:out];
            [self widenCount:ops[1] toPrefix:p fn:fn out:out];
            [out appendFormat:@"    %@.%@\n", p,
                insn.opcode == XTIROpRol ? @"rotl" : @"rotr"];
            [self setResult:res canon:YES out:out];
            return;
        }
        // Narrow rotate: (x << n | masked(x) >> (w·8 − n)), both shift counts
        // taken mod the width.
        uint32_t bits = w * 8, mask = (1u << bits) - 1u;
        BOOL rol = insn.opcode == XTIROpRol;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    i32.const %u\n    i32.and\n", mask];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    i32.const %u\n    i32.rem_u\n    i32.%@\n",
                          bits, rol ? @"shl" : @"shr_u"];
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    i32.const %u\n    i32.and\n", mask];
        [out appendFormat:@"    i32.const %u\n", bits];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    i32.const %u\n    i32.rem_u\n    i32.sub\n"
                          @"    i32.const %u\n    i32.rem_u\n    i32.%@\n    i32.or\n",
                          bits, bits, rol ? @"shr_u" : @"shl"];
        [self setResult:res canon:YES out:out];
        return;
    }

    // ── Casts ─────────────────────────────────────────────────────────────
    case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc: {
        if (!res || ops.count < 1) return;
        XTIROperand *src = ops[0];
        XTIRType *st = (src.kind == XTIROperandKindUse)
            ? fn.values[@(src.valueId)].type : src.type;
        [self pushOperand:src fn:fn out:out];
        BOOL src64 = is64(st), dst64 = is64(res.type);
        if (insn.opcode == XTIROpZExt && st) {
            // The source's canonical form may be sign-extended (i8/i16):
            // ZExt is defined on the VALUE's unsigned bits, so mask first.
            NSString *m = nil;
            if (st.kind == XTIRTypeKindI8)  m = @"    i32.const 255\n    i32.and\n";
            if (st.kind == XTIRTypeKindI16) m = @"    i32.const 65535\n    i32.and\n";
            if (m) [out appendString:m];
        }
        if (src64 && !dst64)      [out appendString:@"    i32.wrap_i64\n"];
        else if (!src64 && dst64) [out appendString:insn.opcode == XTIROpSExt
                                       ? @"    i64.extend_i32_s\n"
                                       : @"    i64.extend_i32_u\n"];
        [self setResult:res canon:YES out:out];
        return;
    }
    case XTIROpFpExt:
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    f64.promote_f32\n"];
        [self setResult:res canon:NO out:out];
        return;
    case XTIROpFpTrunc:
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    f32.demote_f64\n"];
        [self setResult:res canon:NO out:out];
        return;
    case XTIROpSIToFp: case XTIROpUIToFp: {
        if (!res || ops.count < 1) return;
        XTIROperand *src = ops[0];
        XTIRType *st = (src.kind == XTIROperandKindUse)
            ? fn.values[@(src.valueId)].type : src.type;
        [self pushOperand:src fn:fn out:out];
        NSString *fp = wasmValType(res.type);
        NSString *si = is64(st) ? @"i64" : @"i32";
        NSString *sgn = insn.opcode == XTIROpSIToFp ? @"s" : @"u";
        [out appendFormat:@"    %@.convert_%@_%@\n", fp, si, sgn];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpFpToSI: case XTIROpFpToUI: {
        if (!res || ops.count < 1) return;
        XTIROperand *src = ops[0];
        XTIRType *st = (src.kind == XTIROperandKindUse)
            ? fn.values[@(src.valueId)].type : src.type;
        [self pushOperand:src fn:fn out:out];
        NSString *ip = is64(res.type) ? @"i64" : @"i32";
        NSString *fp = (st && st.kind == XTIRTypeKindF32) ? @"f32" : @"f64";
        NSString *sgn = insn.opcode == XTIROpFpToSI ? @"s" : @"u";
        // Saturating: out-of-range clamps instead of trapping — matches the
        // other backends' non-trapping conversions.
        [out appendFormat:@"    %@.trunc_sat_%@_%@\n", ip, fp, sgn];
        [self setResult:res canon:YES out:out];
        return;
    }

    // ── Floating point ─────────────────────────────────────────────────────
    case XTIROpFAdd: case XTIROpFSub: case XTIROpFMul: case XTIROpFDiv: {
        if (!res || ops.count < 2) return;
        NSString *m = insn.opcode == XTIROpFAdd ? @"add"
                    : insn.opcode == XTIROpFSub ? @"sub"
                    : insn.opcode == XTIROpFMul ? @"mul" : @"div";
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    %@.%@\n", opPrefix(res.type), m];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpFNeg:
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    %@.neg\n", opPrefix(res.type)];
        [self setResult:res canon:NO out:out];
        return;
    case XTIROpFSqrt:
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    %@.sqrt\n", opPrefix(res.type)];
        [self setResult:res canon:NO out:out];
        return;

    // ── Compare / select ───────────────────────────────────────────────────
    case XTIROpICmp: {
        if (!res || ops.count < 2) return;
        XTIROperand *a = ops[0];
        XTIRType *at = (a.kind == XTIROperandKindUse)
            ? fn.values[@(a.valueId)].type : a.type;
        static NSString *const preds[] = { @"eq", @"ne", @"lt_s", @"gt_s", @"le_s",
                                           @"ge_s", @"lt_u", @"gt_u", @"le_u", @"ge_u" };
        NSString *p = is64(at) ? @"i64" : @"i32";
        // Unsigned predicates on SIGNED-canonical narrow values need masking;
        // signed predicates on UNSIGNED-canonical values are already right
        // (zero-extension is a valid sign extension for u8/u16 ranges).
        BOOL unsignedPred = insn.predicate >= XTIRICmpULT;
        BOOL narrowSigned = at && (at.kind == XTIRTypeKindI8 || at.kind == XTIRTypeKindI16);
        NSString *mask = at && at.kind == XTIRTypeKindI8
            ? @"    i32.const 255\n    i32.and\n"
            : @"    i32.const 65535\n    i32.and\n";
        [self pushOperand:ops[0] fn:fn out:out];
        if (unsignedPred && narrowSigned) [out appendString:mask];
        [self pushOperand:ops[1] fn:fn out:out];
        if (unsignedPred && narrowSigned) [out appendString:mask];
        [out appendFormat:@"    %@.%@\n", p, preds[insn.predicate]];
        [self setResult:res canon:NO out:out];    // eq/… produce 0/1 already
        return;
    }
    case XTIROpFCmp: {
        if (!res || ops.count < 2) return;
        XTIROperand *a = ops[0];
        XTIRType *at = (a.kind == XTIROperandKindUse)
            ? fn.values[@(a.valueId)].type : a.type;
        static NSString *const preds[] = { @"eq", @"ne", @"lt", @"gt", @"le", @"ge" };
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    %@.%@\n",
            (at && at.kind == XTIRTypeKindF32) ? @"f32" : @"f64", preds[insn.predicate]];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpSelect: {
        if (!res || ops.count < 3) return;
        [self pushOperand:ops[1] fn:fn out:out];
        [self pushOperand:ops[2] fn:fn out:out];
        [self pushCondition:ops[0] fn:fn out:out];
        [out appendString:@"    select\n"];
        [self setResult:res canon:NO out:out];    // both arms canonical already
        return;
    }

    // ── Memory ────────────────────────────────────────────────────────────
    case XTIROpLoad: case XTIROpLoadVolatile: {
        // Operands: [ptr, mem] → result, sized by the result's type.
        if (!res || ops.count < 1) return;
        XTIRType *rt = res.type;
        if (rt.kind == XTIRTypeKindAgg) {
            // Struct load → copy into the value's frame slot (its local
            // already holds the slot address, seeded in the prologue… except
            // the local IS the result here: destination first).
            [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
            [self pushOperand:ops[0] fn:fn out:out];
            [out appendFormat:@"    i32.const %lu\n    memory.copy\n",
                              (unsigned long)[self wasmAggSize:rt.layout]];
            return;
        }
        [self pushOperand:ops[0] fn:fn out:out];
        uint32_t w = rt.byteWidth ?: 4;
        BOOL sgn = XTIRTypeKindIsSigned(rt.kind);
        NSString *p = wasmValType(rt);
        if ([p isEqualToString:@"i32"] || [p isEqualToString:@"i64"]) {
            if (w == 1)      [out appendFormat:@"    %@.load8_%@\n", p, sgn ? @"s" : @"u"];
            else if (w == 2) [out appendFormat:@"    %@.load16_%@\n", p, sgn ? @"s" : @"u"];
            else if (w == 4 && [p isEqualToString:@"i64"])
                             [out appendFormat:@"    i64.load32_%@\n", sgn ? @"s" : @"u"];
            else             [out appendFormat:@"    %@.load\n", p];
        } else {
            [out appendFormat:@"    %@.load\n", p];
        }
        [self setResult:res canon:NO out:out];    // loads produce canonical
        return;
    }
    case XTIROpStore: case XTIROpStoreVolatile: {
        // Operands: [ptr, value, mem], sized by the value's type.
        if (ops.count < 2) return;
        XTIROperand *vop = ops[1];
        XTIRType *vt = (vop.kind == XTIROperandKindUse)
            ? fn.values[@(vop.valueId)].type : vop.type;
        if (vt && vt.kind == XTIRTypeKindAgg) {
            [self pushOperand:ops[0] fn:fn out:out];
            [self pushOperand:vop fn:fn out:out];   // slot address
            [out appendFormat:@"    i32.const %lu\n    memory.copy\n",
                              (unsigned long)[self wasmAggSize:vt.layout]];
            return;
        }
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:vop fn:fn out:out];
        uint32_t w = vt ? (vt.byteWidth ?: 4) : 4;
        NSString *p = wasmValType(vt);
        if ([p isEqualToString:@"i32"] || [p isEqualToString:@"i64"]) {
            if (w == 1)      [out appendFormat:@"    %@.store8\n", p];
            else if (w == 2) [out appendFormat:@"    %@.store16\n", p];
            else if (w == 4 && [p isEqualToString:@"i64"])
                             [out appendString:@"    i64.store32\n"];
            else             [out appendFormat:@"    %@.store\n", p];
        } else {
            [out appendFormat:@"    %@.store\n", p];
        }
        return;
    }
    case XTIROpMemCopy:
        // Operands: [dst, src, size, mem].
        if (ops.count < 3) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [self pushOperand:ops[2] fn:fn out:out];
        [out appendString:@"    memory.copy\n"];
        return;
    case XTIROpMemSet:
        // Operands: [dst, byte, size, mem].
        if (ops.count < 3) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [self pushOperand:ops[2] fn:fn out:out];
        [out appendString:@"    memory.fill\n"];
        return;
    case XTIROpAddrOf: {
        // Operand: Sym (global / literal) or Use of a pinned local, whose
        // local already holds its frame address.
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpFieldAddr: {
        // Operands: [base:Ptr(Agg), ImmI(field index)] → base + RECORDED offset.
        if (!res || ops.count < 2) return;
        XTIROperand *base = ops[0];
        XTIRType *bt = (base.kind == XTIROperandKindUse)
            ? fn.values[@(base.valueId)].type : base.type;
        XTIRLayout *lay = bt.pointeeType.layout;
        NSUInteger off = [self wasmFieldOffset:lay index:(NSUInteger)ops[1].intValue];
        [self pushOperand:base fn:fn out:out];
        if (off) [out appendFormat:@"    i32.const %lu\n    i32.add\n", (unsigned long)off];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpElementAddr: {
        // Operands: [base:Ptr(T), index] → base + index·sizeof(T).
        if (!res || ops.count < 2) return;
        XTIROperand *base = ops[0];
        XTIRType *bt = (base.kind == XTIROperandKindUse)
            ? fn.values[@(base.valueId)].type : base.type;
        NSUInteger es = bt.pointeeType ? ([self wasmFieldWidth:bt.pointeeType] ?: 1) : 1;
        [self pushOperand:base fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        // The index may be a narrow canonical or a 64-bit value; normalise to i32.
        XTIROperand *idx = ops[1];
        XTIRType *it = (idx.kind == XTIROperandKindUse)
            ? fn.values[@(idx.valueId)].type : idx.type;
        if (is64(it)) [out appendString:@"    i32.wrap_i64\n"];
        if (es != 1)
            [out appendFormat:@"    i32.const %lu\n    i32.mul\n", (unsigned long)es];
        [out appendString:@"    i32.add\n"];
        [self setResult:res canon:NO out:out];
        return;
    }

    // ── Aggregates ─────────────────────────────────────────────────────────
    case XTIROpAggBuild: {
        // Operands: one per field; the result's frame slot is the storage.
        if (!res) return;
        XTIRLayout *lay = res.type.layout;
        NSUInteger nf = lay.fields.count;
        for (NSUInteger i = 0; i < nf && i < ops.count; i++) {
            XTIRLayoutField *f = lay.fields[i];
            XTIRType *ft = f.type;
            if (isMemOrVoid(ft)) continue;
            [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
            if (ft.kind == XTIRTypeKindAgg) {
                // Nested aggregate value: copy its bytes into place.
                if (f.byteOffset)
                    [out appendFormat:@"    i32.const %u\n    i32.add\n", f.byteOffset];
                [self pushOperand:ops[i] fn:fn out:out];
                [out appendFormat:@"    i32.const %lu\n    memory.copy\n",
                                  (unsigned long)[self wasmAggSize:ft.layout]];
                continue;
            }
            if (f.byteOffset)
                [out appendFormat:@"    i32.const %u\n    i32.add\n", f.byteOffset];
            [self pushOperand:ops[i] fn:fn out:out];
            uint32_t w = ft.byteWidth ?: 4;
            NSString *p = wasmValType(ft);
            if ([p isEqualToString:@"i32"] || [p isEqualToString:@"i64"]) {
                if (w == 1)      [out appendFormat:@"    %@.store8\n", p];
                else if (w == 2) [out appendFormat:@"    %@.store16\n", p];
                else if (w == 4 && [p isEqualToString:@"i64"])
                                 [out appendString:@"    i64.store32\n"];
                else             [out appendFormat:@"    %@.store\n", p];
            } else               [out appendFormat:@"    %@.store\n", p];
        }
        return;
    }
    case XTIROpAggExtract: {
        // Operands: [agg(Use), ImmI(field index)] → field value.
        if (!res || ops.count < 2) return;
        XTIROperand *agg = ops[0];
        XTIRType *at = (agg.kind == XTIROperandKindUse)
            ? fn.values[@(agg.valueId)].type : agg.type;
        XTIRLayout *lay = at.layout;
        NSUInteger idx = (NSUInteger)ops[1].intValue;
        NSUInteger off = [self wasmFieldOffset:lay index:idx];
        XTIRType *ft = idx < lay.fields.count ? lay.fields[idx].type : nil;
        if (ft && ft.kind == XTIRTypeKindAgg) {
            // Projecting a nested aggregate: copy into the RESULT's slot.
            [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
            [self pushOperand:agg fn:fn out:out];
            if (off) [out appendFormat:@"    i32.const %lu\n    i32.add\n", (unsigned long)off];
            [out appendFormat:@"    i32.const %lu\n    memory.copy\n",
                              (unsigned long)[self wasmAggSize:ft.layout]];
            return;
        }
        [self pushOperand:agg fn:fn out:out];
        if (off) [out appendFormat:@"    i32.const %lu\n    i32.add\n", (unsigned long)off];
        uint32_t w = ft ? (ft.byteWidth ?: 4) : 4;
        BOOL sgn = ft ? XTIRTypeKindIsSigned(ft.kind) : NO;
        NSString *p = wasmValType(ft);
        if ([p isEqualToString:@"i32"] || [p isEqualToString:@"i64"]) {
            if (w == 1)      [out appendFormat:@"    %@.load8_%@\n", p, sgn ? @"s" : @"u"];
            else if (w == 2) [out appendFormat:@"    %@.load16_%@\n", p, sgn ? @"s" : @"u"];
            else if (w == 4 && [p isEqualToString:@"i64"])
                             [out appendFormat:@"    i64.load32_%@\n", sgn ? @"s" : @"u"];
            else             [out appendFormat:@"    %@.load\n", p];
        } else               [out appendFormat:@"    %@.load\n", p];
        [self setResult:res canon:NO out:out];
        return;
    }

    // ── Calls ─────────────────────────────────────────────────────────────
    case XTIROpCall: case XTIROpCallCloaked: case XTIROpCallBanked: {
        // Direct call: [Sym callee, args…, mem]. Banking collapses on a flat
        // target. Aggregate args pass the slot ADDRESS (callee-read-only by
        // SSA construction); an aggregate result goes through a hidden
        // leading sret param pointing at the result value's slot.
        if (ops.count < 1 || ops[0].kind != XTIROperandKindSym) {
            [XTWasmBackend todo:@"call with non-symbol callee"];
            if (res) { [out appendString:@"    i32.const 0\n"]; [self setResult:res canon:NO out:out]; }
            return;
        }
        XTIRSymbol *callee = [mod symbolForId:ops[0].symbolId];
        BOOL sretCall = res && res.type.kind == XTIRTypeKindAgg;
        if (sretCall) [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
        for (NSUInteger i = 1; i < ops.count; i++)
            [self pushOperand:ops[i] fn:fn out:out];
        [out appendFormat:@"    call $%@\n", callee.name];
        if (res && !sretCall && !isMemOrVoid(res.type))
            [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpCallIndirect:
    case XTIROpCallBankedIndirect: {
        // [fnptr(Use), args…, mem]: the fn "pointer" IS a table index; the
        // engine type-checks the call against the declared functype and
        // TRAPS on a null or mismatched slot — a botched dispatch fails
        // loudly instead of jumping to address zero.
        if (ops.count < 1) return;
        BOOL sretCall = res && res.type.kind == XTIRTypeKindAgg;
        if (sretCall) [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
        NSMutableArray<XTIRType *> *argTys = [NSMutableArray array];
        for (NSUInteger i = 1; i < ops.count; i++) {
            XTIROperand *a = ops[i];
            XTIRType *t = (a.kind == XTIROperandKindUse)
                ? fn.values[@(a.valueId)].type : a.type;
            [argTys addObject:t ?: [XTIRType i32Type]];
            [self pushOperand:a fn:fn out:out];
        }
        [self pushOperand:ops[0] fn:fn out:out];
        NSString *ty = [self indirectTypeForArgs:argTys
                                          result:sretCall ? nil : res.type];
        [out appendFormat:@"    call_indirect (type $%@)\n", ty];
        if (res && !sretCall && !isMemOrVoid(res.type))
            [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVTblDispatch: {
        // [recv, ImmI(slot), args…, mem] → recv[0] is the vtable address,
        // vtable[slot] the method's table index; the method's first param is
        // the receiver.
        if (ops.count < 2) return;
        BOOL sretCall = res && res.type.kind == XTIRTypeKindAgg;
        if (sretCall) [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
        NSMutableArray<XTIRType *> *argTys = [NSMutableArray array];
        XTIROperand *recv = ops[0];
        XTIRType *rt = (recv.kind == XTIROperandKindUse)
            ? fn.values[@(recv.valueId)].type : recv.type;
        [argTys addObject:rt ?: [XTIRType i32Type]];
        [self pushOperand:recv fn:fn out:out];
        for (NSUInteger i = 2; i < ops.count; i++) {
            XTIROperand *a = ops[i];
            XTIRType *t = (a.kind == XTIROperandKindUse)
                ? fn.values[@(a.valueId)].type : a.type;
            [argTys addObject:t ?: [XTIRType i32Type]];
            [self pushOperand:a fn:fn out:out];
        }
        [self pushOperand:recv fn:fn out:out];
        [out appendString:@"    i32.load\n"];                 // vtable address
        int64_t slot = ops[1].intValue;
        if (slot) [out appendFormat:@"    i32.const %lld\n    i32.add\n", slot * 4];
        [out appendString:@"    i32.load\n"];                 // table index
        NSString *ty = [self indirectTypeForArgs:argTys
                                          result:sretCall ? nil : res.type];
        [out appendFormat:@"    call_indirect (type $%@)\n", ty];
        if (res && !sretCall && !isMemOrVoid(res.type))
            [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVTblLoad: {
        // [recv, ImmI(slot), mem] → the slot's table index; null receiver or
        // empty slot → 0 (that IS respondsTo — §4/§5).
        if (!res || ops.count < 2) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    local.set $v%u\n", vnum(res.valueId)];   // scratch
        [out appendFormat:@"    local.get $v%u\n    if\n", vnum(res.valueId)];
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    i32.load\n"];
        int64_t slot = ops[1].intValue;
        if (slot) [out appendFormat:@"    i32.const %lld\n    i32.add\n", slot * 4];
        [out appendFormat:@"    i32.load\n    local.set $v%u\n    else\n"
                          @"    i32.const 0\n    local.set $v%u\n    end\n",
                          vnum(res.valueId), vnum(res.valueId)];
        return;
    }
    case XTIROpProtoDispatch: {
        // [recv, ImmI(protoId), ImmI(index), args…, mem]: the callee's table
        // index comes from the receiver's itable ($__xtc_itab, emitted into
        // this module), and the call is the VTblDispatch call_indirect. A
        // class that does not answer to the protocol gives index 0, which
        // traps.
        if (ops.count < 3) return;
        BOOL sretCall = res && res.type.kind == XTIRTypeKindAgg;
        if (sretCall) [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
        NSMutableArray<XTIRType *> *argTys = [NSMutableArray array];
        XTIROperand *recv = ops[0];
        XTIRType *rt = (recv.kind == XTIROperandKindUse)
            ? fn.values[@(recv.valueId)].type : recv.type;
        [argTys addObject:rt ?: [XTIRType i32Type]];
        [self pushOperand:recv fn:fn out:out];
        for (NSUInteger i = 3; i < ops.count; i++) {
            XTIROperand *a = ops[i];
            XTIRType *t = (a.kind == XTIROperandKindUse)
                ? fn.values[@(a.valueId)].type : a.type;
            [argTys addObject:t ?: [XTIRType i32Type]];
            [self pushOperand:a fn:fn out:out];
        }
        [self pushOperand:recv fn:fn out:out];
        [self emitItabLookup:ops out:out];
        NSString *ty = [self indirectTypeForArgs:argTys
                                          result:sretCall ? nil : res.type];
        [out appendFormat:@"    call_indirect (type $%@)\n", ty];
        if (res && !sretCall && !isMemOrVoid(res.type))
            [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpProtoLoad:
        // [recv, ImmI(protoId), ImmI(index), mem] → the table index alone, 0
        // for a null receiver or an unimplemented `optional` (respondsTo).
        if (!res || ops.count < 3) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self emitItabLookup:ops out:out];
        [self setResult:res canon:NO out:out];
        return;

    // ── ARC ────────────────────────────────────────────────────────────────
    case XTIROpRetain:
        if (ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    call $__xtc_retain\n"];
        return;
    case XTIROpRelease: case XTIROpAutorelease:
        // Autorelease degrades to an immediate Release (no pool), like the
        // sibling backends.
        if (ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    call $__xtc_release\n"];
        return;
    case XTIROpWeakRegister:
        // [slot, obj, mem] — link the slot into the object's intrusive chain
        // (weak-refs-intrusive.md; the runtime guards non-objects).
        if (ops.count < 2) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendString:@"    call $_xtc_weak_register\n"];
        return;
    case XTIROpWeakUnregister:
        if (ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    call $_xtc_weak_unregister\n"];
        return;
    case XTIROpWeakLoad:
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    i32.load\n"];    // load(slot) — retain is the lowering's
        [self setResult:res canon:NO out:out];
        return;
    case XTIROpClassDowncast: case XTIROpClassDowncastFailable:
        [XTWasmBackend todo:@"class downcast (stage 2)"];
        if (res && ops.count >= 1) {
            [self pushOperand:ops[0] fn:fn out:out];
            [self setResult:res canon:NO out:out];
        }
        return;

    // ── SIMD (V* from the vectoriser) → wasm v128 ─────────────────────────
    case XTIROpVLoad: {       // operands: [ptr, mem] — load 128 bits
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    v128.load\n"];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVStore: {      // operands: [ptr, vec, mem]
        if (ops.count < 2) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendString:@"    v128.store\n"];
        return;
    }
    case XTIROpVSplat: {      // operands: [scalar] — broadcast to all lanes
        if (!res || ops.count < 1) return;
        NSString *shape = wasmLaneShape(res.type.pointeeType);
        if (!shape) { [XTWasmBackend todo:@"VSplat lane"]; return; }
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    %@.splat\n", shape];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVAdd: case XTIROpVSub: case XTIROpVMul:
    case XTIROpVAnd: case XTIROpVOr:  case XTIROpVXor: {
        if (!res || ops.count < 2) return;
        BOOL bitwise = (insn.opcode == XTIROpVAnd || insn.opcode == XTIROpVOr ||
                        insn.opcode == XTIROpVXor);
        XTIRType *lane = res.type.pointeeType;
        if (insn.opcode == XTIROpVMul && lane && lane.byteWidth == 1) {
            // wasm has no i8x16.mul: widen both to i16x8 (low/high halves),
            // multiply there, and take each 16-bit product's LOW byte back —
            // exact wrapping u8*u8/i8*i8 (low 8 bits are sign-agnostic).
            [self pushOperand:ops[0] fn:fn out:out];
            [out appendString:@"    i16x8.extend_low_i8x16_u\n"];
            [self pushOperand:ops[1] fn:fn out:out];
            [out appendString:@"    i16x8.extend_low_i8x16_u\n    i16x8.mul\n"];
            [self pushOperand:ops[0] fn:fn out:out];
            [out appendString:@"    i16x8.extend_high_i8x16_u\n"];
            [self pushOperand:ops[1] fn:fn out:out];
            [out appendString:@"    i16x8.extend_high_i8x16_u\n    i16x8.mul\n"];
            [out appendString:@"    i8x16.shuffle 0 2 4 6 8 10 12 14"
                              @" 16 18 20 22 24 26 28 30\n"];
            [self setResult:res canon:NO out:out];
            return;
        }
        NSString *shape = bitwise ? nil : wasmLaneShape(lane);
        if (!bitwise && !shape) { [XTWasmBackend todo:@"V-arith lane"]; return; }
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        if (bitwise)
            [out appendFormat:@"    v128.%@\n",
                (insn.opcode == XTIROpVAnd) ? @"and" :
                (insn.opcode == XTIROpVOr)  ? @"or"  : @"xor"];
        else
            [out appendFormat:@"    %@.%@\n", shape,
                (insn.opcode == XTIROpVAdd) ? @"add" :
                (insn.opcode == XTIROpVSub) ? @"sub" : @"mul"];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVMax: case XTIROpVMin: {   // lane-wise max/min (u/s from lane)
        if (!res || ops.count < 2) return;
        XTIRType *lane = res.type.pointeeType;
        NSString *shape = wasmLaneShape(lane);
        if (!shape) { [XTWasmBackend todo:@"VMax/VMin lane"]; return; }
        BOOL flt = lane && XTIRTypeKindIsFloating(lane.kind);
        BOOL sgn = lane && XTIRTypeKindIsSigned(lane.kind);
        NSString *mn = (insn.opcode == XTIROpVMax)
            ? (flt ? @"max" : (sgn ? @"max_s" : @"max_u"))
            : (flt ? @"min" : (sgn ? @"min_s" : @"min_u"));
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    %@.%@\n", shape, mn];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVICmp: {       // lane-wise compare → 0/-1 mask; predicate
        if (!res || ops.count < 2) return;
        NSString *shape = wasmLaneShape(res.type.pointeeType);
        if (!shape) { [XTWasmBackend todo:@"VICmp lane"]; return; }
        static NSString *const vpreds[] = { @"eq", @"ne", @"lt_s", @"gt_s", @"le_s",
                                            @"ge_s", @"lt_u", @"gt_u", @"le_u", @"ge_u" };
        [self pushOperand:ops[0] fn:fn out:out];
        [self pushOperand:ops[1] fn:fn out:out];
        [out appendFormat:@"    %@.%@\n", shape, vpreds[insn.predicate]];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVAddLP: {      // unsigned add-long-pairwise (widen ×2)
        if (!res || ops.count < 1) return;
        XTIROperand *src = ops[0];
        XTIRType *st = (src.kind == XTIROperandKindUse)
            ? fn.values[@(src.valueId)].type : src.type;
        NSUInteger iw = st.pointeeType ? st.pointeeType.byteWidth : 2;
        [self pushOperand:src fn:fn out:out];
        [out appendString:(iw == 1) ? @"    i16x8.extadd_pairwise_i8x16_u\n"
                                    : @"    i32x4.extadd_pairwise_i16x8_u\n"];
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVReduceAdd: {  // scalar <- horizontal add; i32/u32 lanes (.4s)
        // by construction (like arm64's addv path). wasm has no horizontal
        // add — extract the four lanes and chain scalar adds.
        if (!res || ops.count < 1) return;
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendString:@"    i32x4.extract_lane 0\n"];
        for (int k = 1; k <= 3; k++) {
            [self pushOperand:ops[0] fn:fn out:out];
            [out appendFormat:@"    i32x4.extract_lane %d\n    i32.add\n", k];
        }
        [self setResult:res canon:NO out:out];
        return;
    }
    case XTIROpVReduceMax: case XTIROpVReduceMin: {  // horizontal max/min, .4s
        // Seed the result local with lane 0, then fold lanes 1..3 through
        // `select` (each lane is extracted twice — the running value lives in
        // the result local, so no scratch local is needed).
        if (!res || ops.count < 1) return;
        BOOL sgn = XTIRTypeKindIsSigned(res.type.kind);
        NSString *cmp = (insn.opcode == XTIROpVReduceMax)
            ? (sgn ? @"gt_s" : @"gt_u") : (sgn ? @"lt_s" : @"lt_u");
        [self pushOperand:ops[0] fn:fn out:out];
        [out appendFormat:@"    i32x4.extract_lane 0\n    local.set $v%u\n",
                          vnum(res.valueId)];
        for (int k = 1; k <= 3; k++) {
            [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
            [self pushOperand:ops[0] fn:fn out:out];
            [out appendFormat:@"    i32x4.extract_lane %d\n", k];
            [out appendFormat:@"    local.get $v%u\n", vnum(res.valueId)];
            [self pushOperand:ops[0] fn:fn out:out];
            [out appendFormat:@"    i32x4.extract_lane %d\n", k];
            [out appendFormat:@"    i32.%@\n    select\n    local.set $v%u\n",
                              cmp, vnum(res.valueId)];
        }
        return;
    }

    // ── Misc ──────────────────────────────────────────────────────────────
    case XTIROpAsm:
        // No meaningful lowering — ARCH_wasm32-guarded library source is the
        // substitute (the arm64 precedent, wasm-target.md §7). FATAL: this
        // printed and carried on, exit 0, and the module it then wrote had the
        // asm's effect missing and a type error where its value was used —
        // refused by wasm-validate, and by node at load (bug 131's residue).
        fprintf(stderr, "xcc-cg-wasm32: error: inline asm has no wasm lowering "
                        "(guard the source with #if ARCH_wasm32)\n");
        sFatalImportError = YES;
        return;
    case XTIROpBankSave: case XTIROpBankRestore: case XTIROpBankSelectFor:
        NSCAssert(NO, @"banking opcode on the wasm32 target");
        return;
    case XTIROpDbgValue:
        return;
    case XTIROpPhi:
        return;   // handled on predecessor edges
    default:
        [XTWasmBackend todo:[NSString stringWithFormat:@"opcode %d", (int)insn.opcode]];
        if (res && !isMemOrVoid(res.type)) {
            [out appendFormat:@"    %@.const 0\n", wasmValType(res.type)];
            [self setResult:res canon:NO out:out];
        }
        return;
    }
}

#pragma mark - Generated runtime

// The allocator + ARC runtime, generated as wasm. The 38-byte header is the
// SAME contract every hosted backend writes (magic "BOTX"@0, stride u32@4,
// count u32@12, dealloc TABLE INDEX@20, weak head@28, refcount u16@36,
// payload@38 — see _xtc_alloc in src/xtc/main.m and rt-freestanding.c), so
// `.length` header reads and delete[] iteration work unchanged. Bump
// allocation from kWasmHeapBase upward, growing the memory a MiB at a time;
// everything below the base is data/stack, which makes the ARC heap guard a
// single compare. free() is a no-op for now — the coalescing free-list is a
// later stage; memory.grow is real, so programs just grow.
+ (void)emitRuntimeInto:(NSMutableString *)out {
    // Ensure the per-element dealloc functype exists for the loop below.
    NSString *deallocTy = [self indirectTypeForArgs:@[[XTIRType i32Type]] result:nil];
    // link-libs: the app's runtime is the ONE runtime — export the entry
    // points a library imports (alloc / ARC / weak / heap-info) so the
    // loader can wire them through (decision 3).
    NSString *(^X)(NSString *) = ^NSString *(NSString *n) {
        return sLinkLibs ? [NSString stringWithFormat:@" (export \"%@\")", n] : @"";
    };

    // The allocator is a COALESCING FREE-LIST over the bump region: the
    // header's unused word at base+32 records the block's TOTAL size, free
    // blocks carry [size, next] in their first two words on an
    // address-ordered list, allocation is first-fit (splitting when the
    // remainder can hold a minimal block), and _xtc_free merges with both
    // address-neighbours. A REUSED block's payload is ZEROED — heap-new
    // zero-initialises ivars by contract, and the fresh-memory path only
    // got that for free.
    [out appendFormat:@""
    "  (func $_xtc_alloc%@ (param $c i32) (param $s i32) (param $d i32) (result i32)\n"
    "    (local $b i32) (local $p i32) (local $end i32) (local $total i32)\n"
    "    (local $prev i32) (local $cur i32) (local $sz i32) (local $rem i32)\n"
    "    local.get $c\n    local.get $s\n    i32.mul\n    local.set $b\n"
    "    local.get $b\n    i32.const 256\n    i32.lt_u\n"
    "    if\n      i32.const 256\n      local.set $b\n    end\n"
    "    local.get $b\n    i32.const 38\n    i32.add\n"
    "    i32.const 7\n    i32.add\n    i32.const -8\n    i32.and\n    local.set $total\n"
    "    ;; first-fit over the free list\n"
    "    i32.const 0\n    local.set $prev\n"
    "    global.get $__free\n    local.set $cur\n"
    "    block $miss\n    loop $scan\n"
    "    local.get $cur\n    i32.eqz\n    br_if $miss\n"
    "    local.get $cur\n    i32.load\n    local.tee $sz\n"
    "    local.get $total\n    i32.ge_u\n"
    "    if\n"
    "      local.get $sz\n      local.get $total\n      i32.sub\n      local.tee $rem\n"
    "      i32.const 64\n      i32.ge_u\n"
    "      if\n"
    "        ;; split: the remainder becomes a free block after the taken part\n"
    "        local.get $cur\n        local.get $total\n        i32.add\n        local.set $p\n"
    "        local.get $p\n        local.get $rem\n        i32.store\n"
    "        local.get $p\n        local.get $cur\n        i32.const 4\n        i32.add\n"
    "        i32.load\n        i32.store offset=4\n"
    "        local.get $prev\n"
    "        if\n"
    "          local.get $prev\n          local.get $p\n          i32.store offset=4\n"
    "        else\n"
    "          local.get $p\n          global.set $__free\n"
    "        end\n"
    "      else\n"
    "        ;; take the whole block\n"
    "        local.get $sz\n        local.set $total\n"
    "        local.get $prev\n"
    "        if\n"
    "          local.get $prev\n          local.get $cur\n          i32.load offset=4\n"
    "          i32.store offset=4\n"
    "        else\n"
    "          local.get $cur\n          i32.load offset=4\n          global.set $__free\n"
    "        end\n"
    "      end\n"
    "      local.get $cur\n      local.set $p\n"
    "      ;; ZERO the reused payload (fresh memory arrives zeroed; reused must too)\n"
    "      local.get $p\n      i32.const 38\n      i32.add\n"
    "      i32.const 0\n"
    "      local.get $total\n      i32.const 38\n      i32.sub\n"
    "      memory.fill\n"
    "      local.get $p\n      local.get $total\n      local.get $c\n      local.get $s\n"
    "      local.get $d\n      call $__xtc_hdr\n"
    "      local.get $p\n      i32.const 38\n      i32.add\n      return\n"
    "    end\n"
    "    local.get $cur\n    local.set $prev\n"
    "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
    "    br $scan\n    end\n    end\n"
    "    ;; no fit: bump, growing the memory as needed\n"
    "    global.get $__heap\n    local.set $p\n"
    "    local.get $p\n    local.get $total\n    i32.add\n    local.set $end\n"
    "    block $grown\n    loop $g\n"
    "    memory.size\n    i32.const 16\n    i32.shl\n    local.get $end\n    i32.ge_u\n"
    "    br_if $grown\n"
    "    i32.const 16\n    memory.grow\n    i32.const -1\n    i32.eq\n"
    "    if\n      unreachable\n    end\n"
    "    br $g\n    end\n    end\n"
    "    local.get $end\n    global.set $__heap\n"
    "    local.get $p\n    local.get $total\n    local.get $c\n    local.get $s\n"
    "    local.get $d\n    call $__xtc_hdr\n"
    "    local.get $p\n    i32.const 38\n    i32.add\n  )\n"
    "  (func $__xtc_hdr (param $p i32) (param $total i32) (param $c i32)"
    " (param $s i32) (param $d i32)\n"
    "    local.get $p\n    i32.const 1481920322\n    i32.store\n"     // "BOTX"
    "    local.get $p\n    i32.const 4\n    i32.add\n    local.get $s\n    i32.store\n"
    "    local.get $p\n    i32.const 12\n    i32.add\n    local.get $c\n    i32.store\n"
    "    local.get $p\n    i32.const 20\n    i32.add\n    local.get $d\n    i32.store\n"
    "    local.get $p\n    i32.const 28\n    i32.add\n    i32.const 0\n    i32.store\n"
    "    local.get $p\n    i32.const 32\n    i32.add\n    local.get $total\n    i32.store\n"
    "    local.get $p\n    i32.const 36\n    i32.add\n    i32.const 1\n    i32.store16\n  )\n"
    "  (func $_xtc_free (param $blk i32)\n"
    "    (local $sz i32) (local $prev i32) (local $cur i32)\n"
    "    local.get $blk\n    i32.const 32\n    i32.add\n    i32.load\n    local.set $sz\n"
    "    ;; poison the magic so a dangling .length / release reads garbage loudly\n"
    "    local.get $blk\n    i32.const 0\n    i32.store\n"
    "    ;; address-ordered insertion\n"
    "    i32.const 0\n    local.set $prev\n"
    "    global.get $__free\n    local.set $cur\n"
    "    block $found\n    loop $walk\n"
    "    local.get $cur\n    i32.eqz\n    br_if $found\n"
    "    local.get $cur\n    local.get $blk\n    i32.gt_u\n    br_if $found\n"
    "    local.get $cur\n    local.set $prev\n"
    "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
    "    br $walk\n    end\n    end\n"
    "    ;; coalesce forward: blk + sz == cur → absorb cur\n"
    "    local.get $cur\n"
    "    if\n"
    "      local.get $blk\n      local.get $sz\n      i32.add\n"
    "      local.get $cur\n      i32.eq\n"
    "      if\n"
    "        local.get $sz\n        local.get $cur\n        i32.load\n        i32.add\n"
    "        local.set $sz\n"
    "        local.get $cur\n        i32.load offset=4\n        local.set $cur\n"
    "      end\n"
    "    end\n"
    "    ;; coalesce backward: prev + prev.size == blk → absorb into prev\n"
    "    local.get $prev\n"
    "    if\n"
    "      local.get $prev\n      local.get $prev\n      i32.load\n      i32.add\n"
    "      local.get $blk\n      i32.eq\n"
    "      if\n"
    "        local.get $prev\n        local.get $prev\n        i32.load\n"
    "        local.get $sz\n        i32.add\n        i32.store\n"
    "        local.get $prev\n        local.get $cur\n        i32.store offset=4\n"
    "        return\n"
    "      end\n"
    "    end\n"
    "    local.get $blk\n    local.get $sz\n    i32.store\n"
    "    local.get $blk\n    local.get $cur\n    i32.store offset=4\n"
    "    local.get $prev\n"
    "    if\n"
    "      local.get $prev\n      local.get $blk\n      i32.store offset=4\n"
    "    else\n"
    "      local.get $blk\n      global.set $__free\n"
    "    end\n  )\n", X(@"_xtc_alloc")];

    if (sNeedsHeapInfo) {
        // Heap introspection over the allocator's real state. Byte
        // accounting matches the reference Heap API: free/total counts
        // include per-block headers. total = everything above the heap
        // base (grows with memory.grow); free = the untouched bump tail
        // plus every free-list block; largest = the biggest single one
        // of those, capped to u16 range by the caller's API.
        [out appendFormat:@""
        "  (func $_xtc_heap_total_bytes%@ (result i32)\n"
        "    memory.size\n    i32.const 16\n    i32.shl\n"
        "    i32.const %u\n    i32.sub\n  )\n"
        "  (func $_xtc_heap_free_bytes%@ (result i32)\n"
        "    (local $cur i32) (local $sum i32)\n"
        "    memory.size\n    i32.const 16\n    i32.shl\n"
        "    global.get $__heap\n    i32.sub\n    local.set $sum\n"
        "    global.get $__free\n    local.set $cur\n"
        "    block $done\n    loop $walk\n"
        "    local.get $cur\n    i32.eqz\n    br_if $done\n"
        "    local.get $cur\n    i32.load\n    local.get $sum\n    i32.add\n"
        "    local.set $sum\n"
        "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
        "    br $walk\n    end\n    end\n"
        "    local.get $sum\n  )\n"
        "  (func $_xtc_heap_largest%@ (result i32)\n"
        "    (local $cur i32) (local $max i32)\n"
        "    memory.size\n    i32.const 16\n    i32.shl\n"
        "    global.get $__heap\n    i32.sub\n    local.set $max\n"
        "    global.get $__free\n    local.set $cur\n"
        "    block $done\n    loop $walk\n"
        "    local.get $cur\n    i32.eqz\n    br_if $done\n"
        "    local.get $cur\n    i32.load\n    local.get $max\n    i32.gt_u\n"
        "    if\n      local.get $cur\n      i32.load\n      local.set $max\n    end\n"
        "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
        "    br $walk\n    end\n    end\n"
        "    local.get $max\n  )\n",
        X(@"_xtc_heap_total_bytes"), kWasmHeapBase,
        X(@"_xtc_heap_free_bytes"), X(@"_xtc_heap_largest")];
    }

    [out appendFormat:@""
    "  (func $__xtc_retain%@ (param $p i32)\n"
    "    (local $rc i32)\n"
    "    local.get $p\n    i32.const %u\n    i32.lt_u\n"
    "    if\n      return\n    end\n"                                  // null / data / stack
    "    local.get $p\n    i32.const 2\n    i32.sub\n    i32.load16_u\n"
    "    local.tee $rc\n    i32.eqz\n"
    "    if\n      return\n    end\n"                                  // 0 = dying (bug 038)
    "    local.get $p\n    i32.const 2\n    i32.sub\n"
    "    local.get $rc\n    i32.const 1\n    i32.add\n    i32.store16\n  )\n",
    X(@"__xtc_retain"), kWasmHeapBase];

    [out appendFormat:@""
    "  (func $__xtc_release%@ (param $p i32)\n"
    "    (local $rc i32)\n"
    "    local.get $p\n    i32.const %u\n    i32.lt_u\n"
    "    if\n      return\n    end\n"
    "    local.get $p\n    i32.const 2\n    i32.sub\n    i32.load16_u\n"
    "    local.tee $rc\n    i32.eqz\n"
    "    if\n      return\n    end\n"
    "    local.get $p\n    i32.const 2\n    i32.sub\n"
    "    local.get $rc\n    i32.const 1\n    i32.sub\n    i32.store16\n"
    "    local.get $rc\n    i32.const 1\n    i32.eq\n"
    "    if\n"
    "      local.get $p\n      call $_xtc_dealloc\n"
    "    end\n  )\n", X(@"__xtc_release"), kWasmHeapBase];

    // Weak references — the intrusive chain (weak-refs-intrusive.md): the
    // head lives in the header (base+28 = payload−10), a slot's two hidden
    // link words sit immediately before its payload (pprev at slot−8, next
    // at slot−4), and pprev points at the FIELD that points at this slot —
    // the head field or the previous slot's next word — so unlink is O(1)
    // with no head special case. The magic guard makes "is this an object"
    // value-based: a widened `^`'s recv word is a function TABLE INDEX,
    // which fails the heap-range test long before the magic read.
    [out appendFormat:@""
    "  (func $_xtc_weak_unregister%@ (param $s i32)\n"
    "    (local $pp i32) (local $nx i32)\n"
    "    local.get $s\n    i32.const 8\n    i32.sub\n    i32.load\n    local.tee $pp\n"
    "    i32.eqz\n    if\n      return\n    end\n"
    "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.load\n    local.set $nx\n"
    "    local.get $pp\n    local.get $nx\n    i32.store\n"
    "    local.get $nx\n"
    "    if\n"
    "      local.get $nx\n      i32.const 8\n      i32.sub\n      local.get $pp\n      i32.store\n"
    "    end\n"
    "    local.get $s\n    i32.const 8\n    i32.sub\n    i32.const 0\n    i32.store\n"
    "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.const 0\n    i32.store\n  )\n",
    X(@"_xtc_weak_unregister")];
    [out appendFormat:@""
    "  (func $_xtc_weak_register%@ (param $s i32) (param $o i32)\n"
    "    (local $nx i32)\n"
    "    local.get $s\n    call $_xtc_weak_unregister\n"
    "    local.get $o\n    i32.eqz\n    if\n      return\n    end\n"
    "    local.get $o\n    i32.const %u\n    i32.lt_u\n    if\n      return\n    end\n"
    "    local.get $o\n    i32.const 38\n    i32.sub\n    i32.load\n"
    "    i32.const 1481920322\n    i32.ne\n    if\n      return\n    end\n"
    "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.load\n    local.set $nx\n"
    "    local.get $s\n    i32.const 8\n    i32.sub\n"
    "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.store\n"
    "    local.get $s\n    i32.const 4\n    i32.sub\n    local.get $nx\n    i32.store\n"
    "    local.get $nx\n"
    "    if\n"
    "      local.get $nx\n      i32.const 8\n      i32.sub\n"
    "      local.get $s\n      i32.const 4\n      i32.sub\n      i32.store\n"
    "    end\n"
    "    local.get $o\n    i32.const 10\n    i32.sub\n    local.get $s\n    i32.store\n  )\n",
    X(@"_xtc_weak_register"), kWasmHeapBase];
    [out appendString:@""
    "  (func $_xtc_weak_load (param $s i32) (result i32)\n"
    "    local.get $s\n    i32.load\n  )\n"
    "  (func $_xtc_weak_zero_for (param $o i32)\n"
    "    (local $s i32) (local $nx i32)\n"
    "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.load\n    local.set $s\n"
    "    block $done\n    loop $w\n"
    "    local.get $s\n    i32.eqz\n    br_if $done\n"
    "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.load\n    local.set $nx\n"
    "    local.get $s\n    i32.const 0\n    i32.store\n"
    "    local.get $s\n    i32.const 8\n    i32.sub\n    i32.const 0\n    i32.store\n"
    "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.const 0\n    i32.store\n"
    "    local.get $nx\n    local.set $s\n"
    "    br $w\n    end\n    end\n"
    "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.const 0\n    i32.store\n  )\n"];

    // delete obj[] runs the descriptor across EVERY element (the header's
    // count/stride — docs: array-delete-iteration). The refcount is bumped
    // to a sentinel first so a balanced retain/release inside a dealloc body
    // cannot re-dispatch dealloc on the object being freed. Weak slots are
    // zeroed FIRST, so weak back-pointers read nil rather than dangling.
    [out appendFormat:@""
    "  (func $_xtc_dealloc%@ (param $o i32)\n"
    "    (local $base i32) (local $stride i32) (local $count i32) (local $d i32)\n"
    "    (local $q i32) (local $i i32)\n"
    "    local.get $o\n    call $_xtc_weak_zero_for\n"
    "    local.get $o\n    i32.const 38\n    i32.sub\n    local.set $base\n"
    "    local.get $base\n    i32.const 4\n    i32.add\n    i32.load\n    local.set $stride\n"
    "    local.get $base\n    i32.const 12\n    i32.add\n    i32.load\n    local.set $count\n"
    "    local.get $base\n    i32.const 20\n    i32.add\n    i32.load\n    local.set $d\n"
    "    local.get $d\n"
    "    if\n"
    "      local.get $o\n      i32.const 2\n      i32.sub\n"
    "      i32.const 32768\n      i32.store16\n"
    "      local.get $o\n      local.set $q\n"
    "      i32.const 0\n      local.set $i\n"
    "      block $done\n      loop $each\n"
    "      local.get $i\n      local.get $count\n      i32.ge_u\n      br_if $done\n"
    "      local.get $q\n      local.get $d\n      call_indirect (type $%@)\n"
    "      local.get $q\n      local.get $stride\n      i32.add\n      local.set $q\n"
    "      local.get $i\n      i32.const 1\n      i32.add\n      local.set $i\n"
    "      br $each\n      end\n      end\n"
    "    end\n"
    "    local.get $base\n    call $_xtc_free\n  )\n", X(@"_xtc_dealloc"), deallocTy];

    // Primitive-array allocators — _xtc_new_<T>(n) → _xtc_alloc(n, width, 0) —
    // and the per-CLASS allocators: _xtc_new_<C>(count, stride) →
    // _xtc_alloc(count, stride, <table index of C$dealloc, or 0>) — the wasm
    // twin of arm64ClassAllocStubs (the stub exists so the DESCRIPTOR is
    // placed; the first two arguments pass through untouched).
    NSDictionary<NSString *, NSNumber *> *widths = @{
        @"u8": @1, @"i8": @1, @"bool": @1, @"u16": @2, @"i16": @2,
        @"u32": @4, @"i32": @4, @"float": @4, @"pointer": @4, @"string": @4,
        @"u64": @8, @"i64": @8, @"double": @8 };
    // `.length` — a REAL header read (#1083): the element count at base+12,
    // i.e. payload−26; 0 for anything that is not a heap block.
    if ([sNewSuffixes containsObject:@"__count__"]) {
        [out appendFormat:@""
        "  (func $_xtc_count%@ (param $p i32) (result i32)\n"
        "    local.get $p\n    i32.const %u\n    i32.lt_u\n"
        "    if\n      i32.const 0\n      return\n    end\n"
        "    local.get $p\n    i32.const 26\n    i32.sub\n    i32.load\n  )\n",
        X(@"_xtc_count"), kWasmHeapBase];
    }
    for (NSString *suffix in
         [sNewSuffixes.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        if ([suffix isEqualToString:@"__count__"]) continue;
        NSNumber *w = widths[suffix];
        if (w) {
            [out appendFormat:@""
            "  (func $_xtc_new_%@ (param $n i32) (result i32)\n"
            "    local.get $n\n    i32.const %u\n    i32.const 0\n    call $_xtc_alloc\n  )\n",
            suffix, w.unsignedIntValue];
        } else {
            NSNumber *de = sFnTableIndex[[suffix stringByAppendingString:@"$dealloc"]];
            if (!de && sLinkLibs) {
                // `new C[N]` of an IMPORTED class: the dealloc descriptor is
                // the library method's slot in the app's table (its funcref
                // is the import — see ensureImportedFnSlot).
                XTIRSymbol *ext = [sMod symbolForName:
                    [suffix stringByAppendingString:@"$dealloc"]];
                if (ext && ext.kind == XTIRSymbolKindFunction && ext.function)
                    de = @([self ensureImportedFnSlot:ext]);
            }
            [out appendFormat:@""
            "  (func $_xtc_new_%@ (param $c i32) (param $s i32) (result i32)\n"
            "    local.get $c\n    local.get $s\n    i32.const %u\n    call $_xtc_alloc\n  )\n",
            suffix, de ? de.unsignedIntValue : 0];
        }
    }
}

#pragma mark - Library emission (emit-lib / link-libs)

// --emit-lib: ONLY the per-type allocator stubs are defined locally — they
// bake this module's element widths and (rebased) dealloc table indices; the
// allocator itself is the app's, reached through the imported _xtc_alloc.
// With the receiver on the stack, push the protocol id and the method index
// from a ProtoDispatch/ProtoLoad and look the table index up.
+ (void)emitItabLookup:(NSArray<XTIROperand *> *)ops out:(NSMutableString *)out {
    [out appendFormat:@"    i32.const %d\n", (int32_t)ops[1].intValue];
    [out appendFormat:@"    i32.const %d\n", (int32_t)ops[2].intValue];
    [out appendString:@"    call $__xtc_itab\n"];
}

// The itable walk, one private copy per module that dispatches through a
// protocol. Vtable word 1 is the itable: (protoId, &table) pairs ending in a
// zero id, each table the protocol's methods in declaration order. Both follow
// from the protocol alone, so a library and its client agree on them without
// agreeing on vtable slot numbers (bug 266).
+ (void)emitItabHelperInto:(NSMutableString *)out {
    [out appendString:
        @"  (func $__xtc_itab (param $o i32) (param $pid i32) (param $idx i32) (result i32)\n"
        @"    (local $t i32)\n"
        @"    local.get $o\n    i32.eqz\n"
        @"    if\n      i32.const 0\n      return\n    end\n"
        @"    local.get $o\n    i32.load\n    i32.load offset=4\n    local.tee $t\n    i32.eqz\n"
        @"    if\n      i32.const 0\n      return\n    end\n"
        @"    block $miss\n    loop $walk\n"
        @"    local.get $t\n    i32.load\n    local.get $pid\n    i32.eq\n"
        @"    if\n"
        @"      local.get $t\n      i32.load offset=4\n"
        @"      local.get $idx\n      i32.const 2\n      i32.shl\n      i32.add\n"
        @"      i32.load\n      return\n"
        @"    end\n"
        @"    local.get $t\n    i32.load\n    i32.eqz\n    br_if $miss\n"
        @"    local.get $t\n    i32.const 8\n    i32.add\n    local.set $t\n"
        @"    br $walk\n    end\n    end\n"
        @"    i32.const 0\n  )\n"];
}

+ (void)emitLibStubsInto:(NSMutableString *)out {
    NSDictionary<NSString *, NSNumber *> *widths = @{
        @"u8": @1, @"i8": @1, @"bool": @1, @"u16": @2, @"i16": @2,
        @"u32": @4, @"i32": @4, @"float": @4, @"pointer": @4, @"string": @4,
        @"u64": @8, @"i64": @8, @"double": @8 };
    for (NSString *suffix in
         [sNewSuffixes.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        if ([suffix isEqualToString:@"__count__"]) continue;
        NSNumber *w = widths[suffix];
        if (w) {
            [out appendFormat:@""
            "  (func $_xtc_new_%@ (export \"_xtc_new_%@\") (param $n i32) (result i32)\n"
            "    local.get $n\n    i32.const %u\n    i32.const 0\n    call $_xtc_alloc\n  )\n",
            suffix, suffix, w.unsignedIntValue];
        } else {
            // The dealloc descriptor is a TABLE INDEX — in a library that is
            // __table_base + k, a runtime value, which is exactly why the
            // stub (not the caller) computes it.
            NSNumber *de = sFnTableIndex[[suffix stringByAppendingString:@"$dealloc"]];
            [out appendFormat:@""
            "  (func $_xtc_new_%@ (export \"_xtc_new_%@\") (param $c i32) (param $s i32) (result i32)\n"
            "    local.get $c\n    local.get $s\n", suffix, suffix];
            if (de)
                [out appendFormat:@""
                "    global.get $__table_base\n    i32.const %u\n    i32.add\n",
                de.unsignedIntValue];
            else
                [out appendString:@"    i32.const 0\n"];
            [out appendString:@"    call $_xtc_alloc\n  )\n"];
        }
    }
}

// --emit-lib: the module tail — one __addr_<sym> getter per data symbol
// (a library's addresses are not constants, so clients call for them), and
// __wasm_apply_relocs: the loader calls it once after instantiation; it
// patches every vtable word that holds a table index or a data address
// (data segments cannot compute base+k — decision 2's one exception), then
// runs the module inits (a library has no main wrapper to run them from).
+ (void)emitLibTailInto:(NSMutableString *)out module:(XTIRModule *)mod {
    for (NSArray *g in sAddrGetters) {
        [out appendFormat:@""
        "  (func $__addr_%@ (export \"__addr_%@\") (result i32)\n"
        "    global.get $__memory_base\n    i32.const %u\n    i32.add\n  )\n",
        g[0], g[0], [g[1] unsignedIntValue]];
    }
    [out appendString:@"  (func $__wasm_apply_relocs (export \"__wasm_apply_relocs\")\n"];
    for (NSArray *r in sLibRelocs) {
        BOOL isFn = [r[1] isEqualToString:@"fn"];
        [out appendFormat:@""
        "    global.get $__memory_base\n    i32.const %u\n    i32.add\n"
        "    global.get $%@\n    i32.const %u\n    i32.add\n"
        "    i32.store\n",
        [r[0] unsignedIntValue],
        isFn ? @"__table_base" : @"__memory_base",
        [r[2] unsignedIntValue]];
    }
    for (NSString *initName in mod.moduleInitFunctionNames)
        [out appendFormat:@"    call $%@\n", initName];
    [out appendString:@"  )\n"];
}

// link-libs: patch the app's own vtable words that hold LIBRARY data
// addresses (subclass-of-imported-class parent links and the like). Runs
// from the exported main wrapper, before the module inits — the getters are
// wired by then.
+ (void)emitAppFixupInto:(NSMutableString *)out {
    [out appendString:@"  (func $__xtc_fixup_imports\n"];
    for (NSArray *f in sAppFixups) {
        [out appendFormat:@""
        "    i32.const %u\n    call $__addr_%@\n    i32.store\n",
        [f[0] unsignedIntValue], f[1]];
    }
    [out appendString:@"  )\n"];
}

#pragma mark - Phi edges and terminators

// Parallel phi copies for the edge from `pred` to `succ`: push every source,
// then local.set every phi destination in REVERSE. The operand-stack snapshot
// is the parallel read — no dependency ordering, no lost-copy hazard (#683).
// (Aggregate phis hold slot ADDRESSES in their locals, so the same move works;
// the pointed-at bytes are immutable per SSA.)
+ (void)emitPhiCopiesFrom:(XTIRBlock *)pred to:(XTIRBlock *)succ
                       fn:(XTIRFunction *)fn out:(NSMutableString *)out {
    NSMutableArray<XTIRValue *> *dsts = [NSMutableArray array];
    for (XTIRInsn *phi in succ.phiNodes) {
        if (!phi.result || isMemOrVoid(phi.result.type)) continue;
        // Operands are (block, use) pairs.
        for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2) {
            if (phi.operands[i].kind != XTIROperandKindBlock) continue;
            if (phi.operands[i].blockRef != pred) continue;
            [self pushOperand:phi.operands[i + 1] fn:fn out:out];
            [dsts addObject:phi.result];
            break;
        }
    }
    for (XTIRValue *dst in [dsts reverseObjectEnumerator])
        [out appendFormat:@"    local.set $v%u\n", vnum(dst.valueId)];
}

+ (void)emitFramePopInto:(NSMutableString *)out ctx:(XTWasmFnCtx *)ctx {
    if (!ctx.frameSize) return;
    [out appendFormat:@"    local.get $fp\n    i32.const %u\n    i32.add\n"
                      @"    global.set $__sp\n", ctx.frameSize];
}

+ (void)emitTerminator:(XTIRInsn *)term block:(XTIRBlock *)b fn:(XTIRFunction *)fn
                module:(XTIRModule *)mod ctx:(XTWasmFnCtx *)ctx
            blockIndex:(NSDictionary<NSValue *, NSNumber *> *)blockIndex
                   out:(NSMutableString *)out {
    if (!term) { [out appendString:@"    unreachable\n"]; return; }
    NSArray<XTIROperand *> *ops = [self dataOperandsOf:term fn:fn];

    switch (term.opcode) {
    case XTIROpBranch: {
        XTIRBlock *target = ops.firstObject.blockRef;
        [self emitPhiCopiesFrom:b to:target fn:fn out:out];
        NSNumber *idx = blockIndex[[NSValue valueWithNonretainedObject:target]];
        [out appendFormat:@"    i32.const %u\n    local.set $pc\n    br $dispatch\n",
                          idx.unsignedIntValue];
        return;
    }
    case XTIROpCondBranch: {
        // [cond, thenBlock, elseBlock].
        XTIRBlock *thenB = ops.count > 1 ? ops[1].blockRef : nil;
        XTIRBlock *elseB = ops.count > 2 ? ops[2].blockRef : nil;
        NSNumber *ti = blockIndex[[NSValue valueWithNonretainedObject:thenB]];
        NSNumber *ei = blockIndex[[NSValue valueWithNonretainedObject:elseB]];
        [self pushCondition:ops[0] fn:fn out:out];
        [out appendString:@"    if\n"];
        [self emitPhiCopiesFrom:b to:thenB fn:fn out:out];
        [out appendFormat:@"    i32.const %u\n    local.set $pc\n    else\n",
                          ti.unsignedIntValue];
        [self emitPhiCopiesFrom:b to:elseB fn:fn out:out];
        [out appendFormat:@"    i32.const %u\n    local.set $pc\n    end\n"
                          @"    br $dispatch\n", ei.unsignedIntValue];
        return;
    }
    case XTIROpReturn: {
        XTIROperand *val = ops.firstObject;
        if (ctx.hasSret && val) {
            // Copy the returned aggregate into the caller's sret buffer.
            [out appendString:@"    local.get $sret\n"];
            [self pushOperand:val fn:fn out:out];
            XTIRType *vt = (val.kind == XTIROperandKindUse)
                ? fn.values[@(val.valueId)].type : val.type;
            [out appendFormat:@"    i32.const %lu\n    memory.copy\n",
                              (unsigned long)[self wasmAggSize:vt.layout]];
            [self emitFramePopInto:out ctx:ctx];
            [out appendString:@"    return\n"];
            return;
        }
        BOOL scalarRet = fn.returnType && !isMemOrVoid(fn.returnType)
                      && fn.returnType.kind != XTIRTypeKindAgg;
        if (scalarRet && val) {
            [self emitFramePopInto:out ctx:ctx];
            [self pushOperand:val fn:fn out:out];
            [out appendString:@"    return\n"];
        } else {
            [self emitFramePopInto:out ctx:ctx];
            if (scalarRet)
                [out appendFormat:@"    %@.const 0\n    return\n", wasmValType(fn.returnType)];
            else
                [out appendString:@"    return\n"];
        }
        return;
    }
    case XTIROpUnreachable:
        [out appendString:@"    unreachable\n"];
        return;
    default:
        [XTWasmBackend todo:[NSString stringWithFormat:@"terminator %d", (int)term.opcode]];
        [out appendString:@"    unreachable\n"];
        return;
    }
}

#pragma mark - Structured control flow (-O1+)

// DFS postorder from block u, successors visited in terminator-operand
// order — the one order the self-hosted twin can reproduce exactly.
+ (void)structureDFS:(NSUInteger)u
               succs:(NSArray<NSArray<NSNumber *> *> *)succs
             visited:(NSMutableArray<NSNumber *> *)visited
                post:(NSMutableArray<NSNumber *> *)post {
    visited[u] = @1;
    for (NSNumber *s in succs[u])
        if (!visited[s.unsignedIntegerValue].boolValue)
            [self structureDFS:s.unsignedIntegerValue succs:succs
                       visited:visited post:post];
    [post addObject:@(u)];
}

// Does a dominate b?  (b's idom chain; the entry's idom is itself.)
static BOOL wasmDominates(NSArray<NSNumber *> *idom, NSUInteger a, NSUInteger b) {
    for (;;) {
        if (a == b) return YES;
        NSInteger up = idom[b].integerValue;
        if (up < 0 || (NSUInteger)up == b) return NO;
        b = (NSUInteger)up;
    }
}

// Build the structured-emission plan, or nil when this function must keep
// the -O0 dispatch loop: an irreducible CFG (a retreating edge whose target
// does not dominate its source — rare-to-absent, the language has no goto)
// or a terminator the structured walk does not know (Switch/IndirectBranch —
// nothing lowers them today). The fallback is the correctness net, not a
// code path fixtures are expected to hit.
+ (nullable XTWasmCFGPlan *)structurePlanForFunction:(XTIRFunction *)fn
        blockIndex:(NSDictionary<NSValue *, NSNumber *> *)blockIndex {
    NSArray<XTIRBlock *> *blocks = fn.blocks;
    NSUInteger n = blocks.count;
    if (!n) return nil;

    // Successor lists (edge-per-operand: a CondBranch with both arms on one
    // block contributes TWO edges, which is what makes it a merge node below).
    NSMutableArray<NSArray<NSNumber *> *> *succs = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        XTIRInsn *term = blocks[i].terminator;
        NSMutableArray<NSNumber *> *s = [NSMutableArray array];
        if (term) {
            switch (term.opcode) {
            case XTIROpBranch:
            case XTIROpCondBranch:
                for (XTIROperand *op in term.operands) {
                    if (op.kind != XTIROperandKindBlock) continue;
                    NSNumber *idx = blockIndex[[NSValue valueWithNonretainedObject:op.blockRef]];
                    if (!idx) return nil;
                    [s addObject:idx];
                }
                if (term.opcode == XTIROpBranch && s.count != 1) return nil;
                if (term.opcode == XTIROpCondBranch && s.count != 2) return nil;
                break;
            case XTIROpReturn:
            case XTIROpUnreachable:
                break;
            default:
                return nil;
            }
        }
        [succs addObject:s];
    }

    // Reverse postorder from the entry (block 0). Unreachable blocks get
    // rpoIndex -1 and are never emitted in structured mode.
    NSMutableArray<NSNumber *> *visited = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rpoIndex = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) { [visited addObject:@0]; [rpoIndex addObject:@(-1)]; }
    NSMutableArray<NSNumber *> *post = [NSMutableArray array];
    [self structureDFS:0 succs:succs visited:visited post:post];
    NSMutableArray<NSNumber *> *rpo = [NSMutableArray array];   // position → block
    for (NSUInteger i = post.count; i > 0; i--) {
        NSNumber *b = post[i - 1];
        rpoIndex[b.unsignedIntegerValue] = @(rpo.count);
        [rpo addObject:b];
    }

    // Predecessor EDGE lists (reachable sources only), built in block order.
    NSMutableArray<NSMutableArray<NSNumber *> *> *preds = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) [preds addObject:[NSMutableArray array]];
    for (NSUInteger u = 0; u < n; u++) {
        if (rpoIndex[u].integerValue < 0) continue;
        for (NSNumber *v in succs[u]) [preds[v.unsignedIntegerValue] addObject:@(u)];
    }

    // Immediate dominators — the iterative RPO algorithm (Cooper-Harvey-
    // Kennedy), intersect walking idom chains by RPO position.
    NSMutableArray<NSNumber *> *idom = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) [idom addObject:@(-1)];
    idom[0] = @0;
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSUInteger i = 1; i < rpo.count; i++) {
            NSUInteger b = rpo[i].unsignedIntegerValue;
            NSInteger newIdom = -1;
            for (NSNumber *pn in preds[b]) {
                NSUInteger p = pn.unsignedIntegerValue;
                if (idom[p].integerValue < 0) continue;   // not yet reached
                if (newIdom < 0) { newIdom = (NSInteger)p; continue; }
                NSUInteger a = p, c = (NSUInteger)newIdom;
                while (a != c) {
                    while (rpoIndex[a].integerValue > rpoIndex[c].integerValue)
                        a = idom[a].unsignedIntegerValue;
                    while (rpoIndex[c].integerValue > rpoIndex[a].integerValue)
                        c = idom[c].unsignedIntegerValue;
                }
                newIdom = (NSInteger)a;
            }
            if (idom[b].integerValue != newIdom) { idom[b] = @(newIdom); changed = YES; }
        }
    }

    // Retreating edges: natural back edges mark loop headers; one whose
    // target does not dominate its source makes the CFG irreducible.
    NSMutableArray<NSNumber *> *loopHeader = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) [loopHeader addObject:@0];
    for (NSUInteger u = 0; u < n; u++) {
        if (rpoIndex[u].integerValue < 0) continue;
        for (NSNumber *vn in succs[u]) {
            NSUInteger v = vn.unsignedIntegerValue;
            if (rpoIndex[v].integerValue > rpoIndex[u].integerValue) continue;
            if (!wasmDominates(idom, v, u)) return nil;   // irreducible
            loopHeader[v] = @1;
        }
    }

    // Merge nodes: two or more forward in-edges.
    NSMutableArray<NSNumber *> *mergeNode = [NSMutableArray array];
    for (NSUInteger v = 0; v < n; v++) {
        NSUInteger fwd = 0;
        if (rpoIndex[v].integerValue >= 0)
            for (NSNumber *pn in preds[v])
                if (rpoIndex[pn.unsignedIntegerValue].integerValue
                        < rpoIndex[v].integerValue) fwd++;
        [mergeNode addObject:@(fwd >= 2 ? 1 : 0)];
    }

    // Each block's dominator-tree children that are merge nodes, RPO order.
    NSMutableArray<NSMutableArray<NSNumber *> *> *mergeKids = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) [mergeKids addObject:[NSMutableArray array]];
    for (NSUInteger i = 1; i < rpo.count; i++) {
        NSUInteger b = rpo[i].unsignedIntegerValue;
        if (!mergeNode[b].boolValue) continue;
        [mergeKids[idom[b].unsignedIntegerValue] addObject:@(b)];
    }

    XTWasmCFGPlan *plan = [XTWasmCFGPlan new];
    plan.succs = succs;
    plan.rpoIndex = rpoIndex;
    plan.idom = idom;
    plan.loopHeader = loopHeader;
    plan.mergeNode = mergeNode;
    plan.mergeKids = mergeKids;
    return plan;
}

// One structured edge: phi copies (the same parallel-copy scheme as the
// dispatch form), then a `br` up to the loop header (back edge), a `br` out
// to the block that ends where a merge node begins (forward edge), or the
// target inlined in place (its single forward entry IS this edge).
+ (void)emitStructuredBranchTo:(NSUInteger)v from:(NSUInteger)u
                          plan:(XTWasmCFGPlan *)plan fn:(XTIRFunction *)fn
                        module:(XTIRModule *)mod ctx:(XTWasmFnCtx *)ctx
                    blockIndex:(NSDictionary<NSValue *, NSNumber *> *)blockIndex
                           out:(NSMutableString *)out {
    [self emitPhiCopiesFrom:fn.blocks[u] to:fn.blocks[v] fn:fn out:out];
    if (plan.rpoIndex[v].integerValue <= plan.rpoIndex[u].integerValue)
        [out appendFormat:@"    br $L%lu\n", (unsigned long)v];
    else if (plan.mergeNode[v].boolValue)
        [out appendFormat:@"    br $B%lu\n", (unsigned long)v];
    else
        [self emitStructuredTree:v plan:plan fn:fn module:mod ctx:ctx
                      blockIndex:blockIndex out:out];
}

+ (void)emitStructuredTerminator:(nullable XTIRInsn *)term block:(NSUInteger)u
                            plan:(XTWasmCFGPlan *)plan fn:(XTIRFunction *)fn
                          module:(XTIRModule *)mod ctx:(XTWasmFnCtx *)ctx
                      blockIndex:(NSDictionary<NSValue *, NSNumber *> *)blockIndex
                             out:(NSMutableString *)out {
    if (term && term.opcode == XTIROpBranch) {
        NSArray<XTIROperand *> *ops = [self dataOperandsOf:term fn:fn];
        NSNumber *t = blockIndex[[NSValue valueWithNonretainedObject:ops.firstObject.blockRef]];
        [self emitStructuredBranchTo:t.unsignedIntegerValue from:u plan:plan
                                  fn:fn module:mod ctx:ctx blockIndex:blockIndex out:out];
        return;
    }
    if (term && term.opcode == XTIROpCondBranch) {
        NSArray<XTIROperand *> *ops = [self dataOperandsOf:term fn:fn];
        NSNumber *ti = blockIndex[[NSValue valueWithNonretainedObject:ops[1].blockRef]];
        NSNumber *ei = blockIndex[[NSValue valueWithNonretainedObject:ops[2].blockRef]];
        [self pushCondition:ops[0] fn:fn out:out];
        [out appendString:@"    if\n"];
        [self emitStructuredBranchTo:ti.unsignedIntegerValue from:u plan:plan
                                  fn:fn module:mod ctx:ctx blockIndex:blockIndex out:out];
        [out appendString:@"    else\n"];
        [self emitStructuredBranchTo:ei.unsignedIntegerValue from:u plan:plan
                                  fn:fn module:mod ctx:ctx blockIndex:blockIndex out:out];
        [out appendString:@"    end\n"];
        return;
    }
    // Return / Unreachable / nil — the shared path (no $pc involved).
    [self emitTerminator:term block:fn.blocks[u] fn:fn module:mod ctx:ctx
              blockIndex:blockIndex out:out];
}

// The dominator-tree translation ("Beyond Relooper"-shaped): emit X wrapped
// in `loop $L<X>` when it heads one, with one `block $B<kid>` per merge-node
// dominator child — opened outermost for the HIGHEST-RPO child, so each
// block's `end` sits exactly where its merge node's code begins and every
// forward branch to it is a `br` from inside. Non-merge targets are inlined
// at their single forward branch site by emitStructuredBranchTo.
+ (void)emitStructuredTree:(NSUInteger)X plan:(XTWasmCFGPlan *)plan
                        fn:(XTIRFunction *)fn module:(XTIRModule *)mod
                       ctx:(XTWasmFnCtx *)ctx
                blockIndex:(NSDictionary<NSValue *, NSNumber *> *)blockIndex
                       out:(NSMutableString *)out {
    XTIRBlock *b = fn.blocks[X];
    if (plan.loopHeader[X].boolValue)
        [out appendFormat:@"    loop $L%lu ;; %@\n", (unsigned long)X, b.name ?: @"?"];
    NSArray<NSNumber *> *kids = plan.mergeKids[X];
    for (NSUInteger j = kids.count; j > 0; j--)
        [out appendFormat:@"    block $B%lu\n", (unsigned long)kids[j - 1].unsignedIntegerValue];
    if (!plan.loopHeader[X].boolValue)
        [out appendFormat:@"    ;; %@\n", b.name ?: @"?"];
    XTIRInsn *tail = [self tailCallableInsn:b fn:fn ctx:ctx];
    for (XTIRInsn *insn in b.instructions) {
        if (insn == tail) continue;   // fused into return_call below
        [self emitInsn:insn fn:fn module:mod ctx:ctx out:out];
    }
    if (tail)
        [self emitTailCall:tail fn:fn module:mod ctx:ctx out:out];
    else
        [self emitStructuredTerminator:b.terminator block:X plan:plan fn:fn
                                module:mod ctx:ctx blockIndex:blockIndex out:out];
    for (NSUInteger j = 0; j < kids.count; j++) {
        NSUInteger kid = kids[j].unsignedIntegerValue;
        [out appendFormat:@"    end ;; $B%lu — %@\n", (unsigned long)kid,
                          fn.blocks[kid].name ?: @"?"];
        [self emitStructuredTree:kid plan:plan fn:fn module:mod ctx:ctx
                      blockIndex:blockIndex out:out];
    }
    if (plan.loopHeader[X].boolValue)
        [out appendFormat:@"    end ;; $L%lu\n", (unsigned long)X];
}

@end
