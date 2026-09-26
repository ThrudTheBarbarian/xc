// XT6502Backend.m
#import "XT6502Backend.h"
#import "XTIR.h"
#import "XTIRPrinter.h"
#import "XTDiagnosticEngine.h"
#import "XTSourceLocation.h"
#import "XTFloatEncoding.h"
#import "XTType.h"
#import "XTMemoryModel.h"

// Default ZP var pool when no memory model is supplied: $A0..$FF.
// Matches the historical hard-coded pool so a nil-model call is
// byte-identical to the pre-#55 backend.
static NSArray<NSArray<NSNumber *> *> *defaultZpVarRanges(void) {
    return @[@[@0xA0, @0xFF]];
}

// Software-stack ZP registers (STACK-ABI §11.3). SSP = the software-
// stack pointer (bumped per frame); FP = the current frame pointer
// (`(FP),Y` reaches the frame's locals). On xt this is the ONE and
// ONLY software stack pointer: the old second one — XTC_SP, the asm
// runtime libs' recursion stack — is gone on xt (the libs now push
// those frames on the 4 KB hidden hardware stack via XTC_LIB_HWSTACK,
// see XTCompilerDriver.m / Stdio.xc), so nothing aliases SSP at $8A any
// more. SSP is only live for the rare non-leaf spill frame; most
// functions use the hardware stack + ZP and never touch it.
//   $8A-$8D is free + persistent on the run target (the backend's
// transient staging is $82-$89/$BF/$B0-$B3, the corpus harness uses
// $58/$59/$90-$95, and the test ZP var pool is $A0-$FF). The production
// xt.lnk ZP matches: HP at $8E-$8F, var pool from $90, clear of SSP/FP.
static const uint8_t kSSPLo = 0x8A, kSSPHi = 0x8B;
static const uint8_t kFPLo  = 0x8C, kFPHi  = 0x8D;

// Module-wide options, set by the code generator's driver before
// assemblyFromModule: (the back end is a set of class methods).
static BOOL sDefaultXtcStack = NO;        // --xtc-stack
static NSUInteger sFnMinBanked = 0;       // -Fmb <n>
static NSString *sPlacementReport = nil;  // what -dp prints

static XTSourceLocation *synthLoc(void) {
    return [[XTSourceLocation alloc] initWithFilename:@"<xt6502-backend>" line:0 column:0];
}

#pragma mark - Per-function context

@interface XT6502FnCtx : NSObject
@property (nonatomic) XTIRFunction *fn;
@property (nonatomic) XTIRModule *module;
@property (nonatomic) NSMutableString *out;
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *zpBase;  // valueId → ZP base address
@property (nonatomic) NSArray<NSArray<NSNumber *> *> *zpRanges;             // [[start,end],…] inclusive
@property (nonatomic) NSUInteger zpRangeIndex;                              // active range in zpRanges
@property (nonatomic) NSUInteger nextZp;                                    // next free byte in active range
@property (nonatomic) BOOL zpOverflow;                                     // ran out of ZP var space
// Genuine SP-frame local size in bytes — the `N` in PSH/PLL #N, the
// param-access offset (+N+9), and the §6.1 N+K budget. Per STACK-ABI
// §11.2 this is *not* `frameInfo.pinnedLocalSize`: pinned locals live
// in ZP or spill to main RAM, never on the hidden hardware stack, so
// they must not count toward N. No backend path puts a local on the
// SP frame yet, so this stays 0 today — but PSH, PLL and the param
// offset all read it here so they can never disagree.
@property (nonatomic) NSUInteger spFrameSize;
// valueId → SP-frame byte offset (the value's byte-0 position, +6.. within
// the locals area). Non-address-taken SSA values (scalars AND pointers —
// the latter deref'd in place via (d,SP),Y) live here instead of ZP, which
// is what relieves the ZP-overflow wall (STACK-ABI §11.1). Address-taken /
// pinned values stay in ZP/spill (they need real 16-bit addresses).
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *spFrameBase;
// Running SP displacement below the post-PSH baseline, in bytes. Pushing
// (PHA / arg setup) moves SP down, so an SP-frame slot's offset from the
// *current* SP grows by spDelta; ADD SP / PLA shrink it. Every SP-frame
// operand adds spDelta so accesses mid-push stay correct. Updated only
// through emitPHA/emitPLA/emitAddSP. 0 in settled body code.
@property (nonatomic) NSInteger spDelta;
// valueId → main-RAM spill label, for pinned locals that don't fit ZP
// (STACK-ABI §11.3). AddrOf of such a value yields the 16-bit label
// address instead of a ZP byte.
@property (nonatomic) NSMutableDictionary<NSNumber *, NSString *> *spillLabels;
// Software-stack frame (STACK-ABI §11.3, non-leaf). When a non-leaf
// function has pinned locals that don't fit ZP, they go into a per-
// invocation frame in the model's software-stack region instead of a
// static slot (which would alias across re-entry). `usesSoftStack`
// gates the prologue/epilogue; `frameOffsets` maps valueId → byte
// offset of the local *within the locals area* (the frame's first 2
// bytes hold the caller's FP, so the local's address is FP+2+offset);
// `frameLocalsSize` is the locals-area size (frame reserves 2 + this).
@property (nonatomic) BOOL usesSoftStack;
// The xtc-stack calling convention (`:xtcStack`, or `--xtc-stack` on a
// function without `:hwStack`). The return address and the registers PSH
// would save go into the software-stack frame instead: the prologue pulls the
// return address off the hardware stack, so the hardware frame holds only the
// SP-frame locals (at +1..+N, no guard byte or saved registers) and the
// parameters start at +N+1. The software frame's header grows from the
// caller's FP (2 bytes) to FP, return address, P, A, X and Y (8 bytes).
@property (nonatomic) BOOL xtcStack;
@property (nonatomic) NSUInteger frameLocalsBase;   // 7, or 1 under xtcStack
@property (nonatomic) NSUInteger softFrameHeader;   // 2, or 8 under xtcStack
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *frameOffsets;
@property (nonatomic) NSUInteger frameLocalsSize;
@property (nonatomic) NSUInteger labelCounter;
// ── Code banking (task #60) ───────────────────────────────────────
// Banking is active iff the memory model declares a code-bank window.
// `bankMap` maps a function name → its bank id (1-based) or 0 for an
// unbanked function; `currentBank` is the bank of the function being
// emitted. A direct call stays a `JSR _callee` when the callee is
// unbanked or in the same bank as the caller; otherwise it routes
// through the unbanked `_xcall` trampoline (which saves $82, selects
// the callee's bank, calls, and restores $82). `codeBankReg` is the
// code-bank selector address ($82 on xt). arm64 and flat models
// leave bankingActive NO, so the call path is byte-identical to before.
@property (nonatomic) BOOL bankingActive;
@property (nonatomic) NSUInteger currentBank;
@property (nonatomic) NSDictionary<NSString *, NSNumber *> *bankMap;
@property (nonatomic) uint16_t codeBankReg;
// Caller-save (task #64): per-call set of ZP byte addresses to preserve
// across that call — only the values LIVE ACROSS the call (defined
// before it, used after it), not the whole ZP frame, so call-heavy
// functions don't bloat past the code-region budget. Keyed by the call
// instruction's pointer (@((uintptr_t)insn)); the value is a sorted,
// de-duplicated NSArray<NSNumber *> of byte addresses. Filled once by
// computeCallerSaveSetsForCtx: before block emission (liveness needs the
// final ZP allocation). A call instruction absent from the map (or with
// an empty array) saves nothing.
@property (nonatomic, nullable) NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *callSaveSets;
// :irq / :vbi function attributes (carried from sema via IR symbol
// attributes). :irq → no SP-frame prologue/epilogue, return with RTI
// instead of RTS. :vbi → preserve A/X/Y via PHA/TXA/PHA/TYA/PHA on
// entry and PLA/TAY/PLA/TAX/PLA on exit, then JMP XITVBV ($E462)
// instead of RTS (the ROM chains to the deferred-VBI return). The
// fixture irq_vbi reads back the first instruction byte to verify
// the prologue shape, so getting the leading opcode right matters.
@property (nonatomic) BOOL isIrq;
@property (nonatomic) BOOL isVbi;
// Known-address map (Stage 10a). A Ptr-typed SSA value is in here when
// its address chain (AddrOf → Bitcast → ElementAddr/FieldAddr → …) is
// resolvable at compile time. The Store / Load handlers consult this
// map first and emit direct addressing when present, skipping the
// runtime address computation + indirect-Y of the generic path. Built
// once per function before the emit loop by computeKnownAddrsForCtx:.
//   valueId → XT6502KnownAddr*
@property (nonatomic) NSMutableDictionary<NSNumber *, id> *knownAddrs;
// AddrOf result valueIds whose materialisation can be skipped entirely:
// the value has an AbsSym known address (so every Load/Store through it
// takes the absolute fast path, which never reads the pointer slot) AND
// every use is the pointer operand of a Load/Store. Built by
// computeKnownAddrsForCtx:; consulted by the AddrOf handler to elide the
// dead `LDA #<_sym / #>_sym / #$00` pointer-byte loads the fast path
// would otherwise orphan.
@property (nonatomic) NSMutableSet<NSNumber *> *suppressedAddrOfs;
// Point the allocator at `ranges` (an array of [start,end] pairs) and
// reset the cursor to the first range's start.
- (void)useZpRanges:(NSArray<NSArray<NSNumber *> *> *)ranges;
@end

// Stage 10a — known compile-time address descriptor. For pinned locals
// that end up in ZP, static spill or the soft-stack frame, AddrOf
// + Bitcast + ElementAddr(const) + FieldAddr(const) chains have a
// statically-resolvable address. The Store/Load handlers consult an
// XT6502KnownAddr to decide whether to emit direct addressing (ZP or
// absolute) instead of computing the address at runtime.
typedef NS_ENUM(uint8_t, XT6502KnownAddrKind) {
    XT6502KnownAddrKindNone = 0,
    XT6502KnownAddrKindZP,      // ZP $<zpBase + offset> (single-byte address)
    XT6502KnownAddrKindSpill,   // <spillLabel>+offset    (absolute 16-bit)
    // AbsSym: an AddrOf-of-global-symbol address (+ const field/elem
    // offset), stored as `_<name>` in spillLabel. AddrOf results are
    // always flat bank-0 main-RAM pointers (see the AddrOf handler), so
    // a Load/Store through such a pointer can use direct absolute
    // addressing — exactly equivalent to the generic "set bank 0 +
    // (d,SP),Y windowed deref", but without building the 3-byte pointer,
    // writing __bank_data_reg, or the indirect-Y. This is the only
    // known-addr kind the Load/Store fast path acts on; the ZP/Spill
    // pinned-local kinds were the ones that regressed in the reverted
    // Stage-10a roll-out and stay on the generic path.
    XT6502KnownAddrKindAbsSym,
    // Soft-stack frame ((FP+2+offset+const)) and banked-data addressing
    // are deferred — the in-process indirect-Y path is already correct
    // for those.
};
@interface XT6502KnownAddr : NSObject
@property (nonatomic) XT6502KnownAddrKind kind;
@property (nonatomic) NSUInteger zpBase;            // for ZP
@property (nonatomic, copy, nullable) NSString *spillLabel;  // for Spill
@property (nonatomic) NSUInteger offset;            // added to base
@end
@implementation XT6502KnownAddr
@end
@implementation XT6502FnCtx
- (instancetype)init {
    self = [super init];
    if (self) {
        _zpBase = [NSMutableDictionary dictionary];
        _spFrameBase = [NSMutableDictionary dictionary];
        _spillLabels = [NSMutableDictionary dictionary];
        _frameOffsets = [NSMutableDictionary dictionary];
        _knownAddrs = [NSMutableDictionary dictionary];
        _suppressedAddrOfs = [NSMutableSet set];
        _spFrameSize = 0;
        _spDelta = 0;
        _frameLocalsBase = 7;
        _softFrameHeader = 2;
        [self useZpRanges:defaultZpVarRanges()];
    }
    return self;
}
- (void)useZpRanges:(NSArray<NSArray<NSNumber *> *> *)ranges {
    _zpRanges = (ranges.count > 0) ? ranges : defaultZpVarRanges();
    _zpRangeIndex = 0;
    _nextZp = _zpRanges[0][0].unsignedIntegerValue;
    _zpOverflow = NO;
}
@end

@implementation XT6502Backend

#pragma mark - Type widths

+ (NSUInteger)byteWidthForType:(XTIRType *)t {
    if (!t) return 0;
    switch (t.kind) {
        case XTIRTypeKindI8:
        case XTIRTypeKindU8:
        case XTIRTypeKindBool:  return 1;
        case XTIRTypeKindI16:
        case XTIRTypeKindU16:   return 2;
        case XTIRTypeKindI32:
        case XTIRTypeKindU32:   return 4;
        // 8 even where the ARITHMETIC is not implemented yet. The width is a
        // layout contract — a struct's IR offsets are the front-end widths
        // summed, and the back end reads them with its own — so a disagreement
        // does not surface as "unsupported", it surfaces as a wrong address in
        // optimised code. Unsupported OPERATIONS are rejected per-op instead.
        case XTIRTypeKindI64:
        case XTIRTypeKindU64:   return 8;
        case XTIRTypeKindF32:   return [XTType floatIsIEEE] ? 4 : 5;  // IEEE f32 vs legacy 5-byte
        case XTIRTypeKindF64:   return 8;    // double is 8 bytes (IEEE f64 under MECH)
        case XTIRTypeKindMemory: return 0;   // phantom
        case XTIRTypeKindPtr: {
            // All pointers are uniformly 3 bytes:
            //   [addr-lo, addr-hi, bank-lo]
            // For main-RAM pointers bank-lo is 0. Bank-hi ($84) is
            // eliminated — a single $83 byte selects the data page,
            // and 256 pages are ample for the corpus. This keeps
            // pointer operations uniform: no backend path branches
            // on "is this banked?".
            return 3;
        }
        case XTIRTypeKindAgg:   return t.layout ? t.layout.size : 0;
        default:                return 0;
    }
}

#pragma mark - ZP slot allocation

+ (NSUInteger)allocateSlotsForValue:(XTIRValue *)v ctx:(XT6502FnCtx *)ctx {
    NSUInteger width = [self byteWidthForType:v.type];
    if (width == 0) return 0;     // memory phantom — no slot
    // Walk the ZP var ranges, allocating `width` contiguous bytes
    // within whichever range has room. A multi-byte value never
    // straddles a gap between ranges. When a range can't fit the
    // value, advance to the next range and retry from its start.
    NSArray<NSArray<NSNumber *> *> *ranges = ctx.zpRanges;
    while (ctx.zpRangeIndex < ranges.count) {
        NSUInteger end = ranges[ctx.zpRangeIndex][1].unsignedIntegerValue;
        if (ctx.nextZp + width - 1 <= end) {
            NSUInteger base = ctx.nextZp;
            ctx.nextZp += width;
            ctx.zpBase[@(v.valueId)] = @(base);
            return base;
        }
        ctx.zpRangeIndex++;
        if (ctx.zpRangeIndex < ranges.count) {
            ctx.nextZp = ranges[ctx.zpRangeIndex][0].unsignedIntegerValue;
        }
    }
    // Overflowed every range. Diagnose elsewhere (the §6.1 budget
    // check upstream catches realistic cases); here just return the
    // (clamped) slot without assigning so emission can proceed.
    ctx.zpOverflow = YES;
    return ctx.nextZp;
}

// Try to allocate `width` contiguous ZP bytes for a pinned local.
// Returns the base address and advances the cursor on success; returns
// -1 (cursor unchanged) when no remaining range can hold the value, so
// the caller can spill it to main RAM (STACK-ABI §11.3). Unlike
// allocateSlotsForValue this does *not* set zpOverflow — a pinned local
// not fitting ZP is an expected, recoverable spill, not an error.
+ (NSInteger)tryAllocateZPWidth:(NSUInteger)width ctx:(XT6502FnCtx *)ctx {
    NSArray<NSArray<NSNumber *> *> *ranges = ctx.zpRanges;
    NSUInteger ri = ctx.zpRangeIndex;
    NSUInteger cur = ctx.nextZp;
    while (ri < ranges.count) {
        NSUInteger end = ranges[ri][1].unsignedIntegerValue;
        if (cur + width - 1 <= end) {
            ctx.zpRangeIndex = ri;
            ctx.nextZp = cur + width;
            return (NSInteger)cur;
        }
        ri++;
        if (ri < ranges.count) cur = ranges[ri][0].unsignedIntegerValue;
    }
    return -1;
}

// A function is a "leaf" iff it issues no call of any kind. Leaf
// functions are never re-entered, so their spills can be static
// main-RAM slots (STACK-ABI §11.3). Non-leaf functions need a
// per-invocation software-stack frame — that's task #57.
+ (BOOL)functionIsLeaf:(XTIRFunction *)fn {
    for (XTIRBlock *block in fn.blocks) {
        for (XTIRInsn *insn in block.instructions) {
            switch (insn.opcode) {
                case XTIROpCall:
                case XTIROpCallIndirect:
                case XTIROpVTblDispatch:
                    return NO;
                default: break;
            }
        }
        if (block.terminator) {
            switch (block.terminator.opcode) {
                case XTIROpCall:
                case XTIROpCallIndirect:
                case XTIROpVTblDispatch:
                    return NO;
                default: break;
            }
        }
    }
    return YES;
}

+ (NSInteger)slotForValueId:(XTIRValueId)vid ctx:(XT6502FnCtx *)ctx {
    NSNumber *n = ctx.zpBase[@(vid)];
    return n ? n.integerValue : -1;
}

#pragma mark - Unified value-byte addressing (ZP vs SP frame)

// The xt ISA provides `d,SP` variants of exactly the byte-moving and
// ADC/SBC/CMP instructions the backend uses, so a value living on the SP
// frame is addressed by swapping its operand string from `$<zp>` to
// `+<off>,SP` under the *same* mnemonic. This helper returns that operand
// string for byte `bi` of value `vid`: an SP-frame value yields
// "+<off>,SP" (off = frame offset + bi + spDelta); a ZP value yields
// "$<addr>". nil when the value has no slot. (AND/ORA/EOR and BIT have no
// d,SP form — their SP-frame operands are staged through $BF at the call
// site; this helper is for the d,SP-capable mnemonics + LDA/STA/LDX/LDY.)
+ (nullable NSString *)operandForValueId:(XTIRValueId)vid
                               byteIndex:(NSUInteger)bi
                                     ctx:(XT6502FnCtx *)ctx
{
    NSNumber *sp = ctx.spFrameBase[@(vid)];
    if (sp) {
        NSInteger off = sp.integerValue + (NSInteger)bi + ctx.spDelta;
        return [NSString stringWithFormat:@"+%ld,SP", (long)off];
    }
    NSNumber *zp = ctx.zpBase[@(vid)];
    if (zp) return [NSString stringWithFormat:@"$%02lX", (unsigned long)(zp.integerValue + (NSInteger)bi)];
    return nil;
}

// YES if the value lives on the SP frame (vs ZP / spill / none).
+ (BOOL)valueOnSPFrame:(XTIRValueId)vid ctx:(XT6502FnCtx *)ctx {
    return ctx.spFrameBase[@(vid)] != nil;
}

// Indirect-base operand for a pointer value used with post-indexed Y:
// an SP-frame pointer yields "(+<off>,SP)" → `LDA (+off,SP),Y` ($03/$13),
// a ZP pointer yields "($<zp>)" → `LDA ($zp),Y`. The caller appends ",Y".
// nil when the pointer has no slot.
+ (nullable NSString *)indirectBaseForValueId:(XTIRValueId)vid
                                          ctx:(XT6502FnCtx *)ctx
{
    NSNumber *sp = ctx.spFrameBase[@(vid)];
    if (sp) {
        NSInteger off = sp.integerValue + ctx.spDelta;
        return [NSString stringWithFormat:@"(+%ld,SP)", (long)off];
    }
    NSNumber *zp = ctx.zpBase[@(vid)];
    if (zp) return [NSString stringWithFormat:@"($%02lX)", (unsigned long)zp.integerValue];
    return nil;
}

#pragma mark - SP-tracking emit helpers

// All stack-pointer movement in the body goes through these so spDelta
// (and hence every SP-frame operand offset) stays correct.
+ (void)emitPHA:(XT6502FnCtx *)ctx { [ctx.out appendString:@"    PHA\n"]; ctx.spDelta += 1; }
+ (void)emitPLA:(XT6502FnCtx *)ctx { [ctx.out appendString:@"    PLA\n"]; ctx.spDelta -= 1; }
+ (void)emitAddSP:(NSUInteger)n ctx:(XT6502FnCtx *)ctx {
    [ctx.out appendFormat:@"    ADD SP, #%lu\n", (unsigned long)n];
    ctx.spDelta -= (NSInteger)n;
}

#pragma mark - The xtc-stack calling convention

// Prologue of a function on the xtc-stack convention. Where PSH #N would keep
// the registers and the return address on the hardware stack, this moves them
// into a frame on the software stack:
//   FP+0,+1  caller's FP      FP+2,+3  return address (hi, lo)
//   FP+4     P   FP+5 A   FP+6 X   FP+7 Y      FP+8..  spilled locals
// P, A, X and Y are pushed first so they reach the frame unchanged, then
// pulled with the return address beneath them. The hardware stack then holds
// only the N SP-frame local bytes, allocated with ADD SP, and the arguments
// the caller pushed.
+ (void)emitXtcStackPrologueForCtx:(XT6502FnCtx *)ctx {
    NSMutableString *out = ctx.out;
    [out appendString:@"    ; --- xtc-stack frame push: return address and registers ---\n"];
    [out appendString:@"    PHP\n    PHA\n    TXA\n    PHA\n    TYA\n    PHA\n"];
    [out appendString:@"    LDY #$07\n"];
    // Y, X, A, P, return address lo, return address hi: FP+7 down to FP+2.
    for (NSUInteger k = 0; k < 6; k++) {
        if (k > 0) [out appendString:@"    DEY\n"];
        [out appendString:@"    PLA\n"];
        [out appendFormat:@"    STA ($%02X),Y\n", kSSPLo];
    }
    [out appendString:@"    DEY\n"];
    [out appendFormat:@"    LDA $%02X\n", kFPHi];     // caller FP hi
    [out appendFormat:@"    STA ($%02X),Y\n", kSSPLo];
    [out appendString:@"    DEY\n"];
    [out appendFormat:@"    LDA $%02X\n", kFPLo];     // caller FP lo
    [out appendFormat:@"    STA ($%02X),Y\n", kSSPLo];
    NSUInteger total = ctx.softFrameHeader + ctx.frameLocalsSize;
    [out appendFormat:@"    LDA $%02X\n", kSSPLo];    // FP = SSP
    [out appendFormat:@"    STA $%02X\n", kFPLo];
    [out appendFormat:@"    LDA $%02X\n", kSSPHi];
    [out appendFormat:@"    STA $%02X\n", kFPHi];
    [out appendString:@"    CLC\n"];                  // SSP += total
    [out appendFormat:@"    LDA $%02X\n", kSSPLo];
    [out appendFormat:@"    ADC #$%02X\n", (uint8_t)(total & 0xFF)];
    [out appendFormat:@"    STA $%02X\n", kSSPLo];
    [out appendFormat:@"    LDA $%02X\n", kSSPHi];
    [out appendFormat:@"    ADC #$%02X\n", (uint8_t)((total >> 8) & 0xFF)];
    [out appendFormat:@"    STA $%02X\n", kSSPHi];
    if (ctx.spFrameSize > 0)
        [out appendFormat:@"    ADD SP, #-%lu\n", (unsigned long)ctx.spFrameSize];
}

// The matching epilogue, run after the return value is staged in $B0..: free
// the SP-frame locals, push the return address back and the saved registers
// above it, drop the software frame (SSP = FP, FP = caller's FP), then pull
// Y, X, A and P. The caller of this emits the result and the RTS.
+ (void)emitXtcStackEpilogueForCtx:(XT6502FnCtx *)ctx {
    NSMutableString *out = ctx.out;
    if (ctx.spFrameSize > 0)
        [out appendFormat:@"    ADD SP, #%lu\n", (unsigned long)ctx.spFrameSize];
    [out appendString:@"    ; --- xtc-stack frame pop: return address and registers ---\n"];
    [out appendString:@"    LDY #$02\n"];
    // Return address hi, lo, then P, A, X, Y: FP+2 up to FP+7.
    for (NSUInteger k = 0; k < 6; k++) {
        if (k > 0) [out appendString:@"    INY\n"];
        [out appendFormat:@"    LDA ($%02X),Y\n", kFPLo];
        [out appendString:@"    PHA\n"];
    }
    [out appendFormat:@"    LDA $%02X\n", kFPLo];     // SSP = FP
    [out appendFormat:@"    STA $%02X\n", kSSPLo];
    [out appendFormat:@"    LDA $%02X\n", kFPHi];
    [out appendFormat:@"    STA $%02X\n", kSSPHi];
    [out appendString:@"    LDY #$01\n"];             // FP = caller FP
    [out appendFormat:@"    LDA ($%02X),Y\n", kSSPLo];
    [out appendFormat:@"    STA $%02X\n", kFPHi];
    [out appendString:@"    DEY\n"];
    [out appendFormat:@"    LDA ($%02X),Y\n", kSSPLo];
    [out appendFormat:@"    STA $%02X\n", kFPLo];
    [out appendString:@"    PLA\n    TAY\n    PLA\n    TAX\n    PLA\n    PLP\n"];
}

#pragma mark - Caller-save across calls (task #64)

// Collect the valueIds an instruction USES (Use-kind operands) and
// DEFINES (result + memoryResult) into the given sets.
+ (void)collectInsn:(XTIRInsn *)insn
               uses:(NSMutableSet<NSNumber *> *)uses
               defs:(NSMutableSet<NSNumber *> *)defs {
    for (XTIROperand *op in insn.operands) {
        if (op.kind == XTIROperandKindUse) [uses addObject:@(op.valueId)];
    }
    if (insn.result) [defs addObject:@(insn.result.valueId)];
    if (insn.memoryResult) [defs addObject:@(insn.memoryResult.valueId)];
}

// Map a set of live valueIds to the sorted, de-duplicated set of ZP byte
// addresses they occupy (only values with a ZP slot and a non-zero
// width contribute), excluding `exceptVid` (the call's own result —
// freshly defined, harvested into its slot, never needs preserving).
+ (NSArray<NSNumber *> *)zpBytesForLive:(NSSet<NSNumber *> *)live
                              exceptVid:(NSInteger)exceptVid
                                    ctx:(XT6502FnCtx *)ctx {
    NSMutableIndexSet *bytes = [NSMutableIndexSet indexSet];
    for (NSNumber *vidKey in live) {
        if (exceptVid >= 0 && vidKey.integerValue == exceptVid) continue;
        NSNumber *baseN = ctx.zpBase[vidKey];
        if (!baseN) continue;
        XTIRValue *v = [ctx.fn valueForId:(XTIRValueId)vidKey.unsignedIntegerValue];
        NSUInteger w = v ? [self byteWidthForType:v.type] : 0;
        if (w == 0) continue;
        [bytes addIndexesInRange:NSMakeRange((NSUInteger)baseN.integerValue, w)];
    }
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    [bytes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop; [out addObject:@(idx)];
    }];
    return out;
}

// For each value that is an address formed from another value's storage,
// the values whose storage it may point into: AddrOf %v gives {v}, and an
// address computed from such a value (FieldAddr, ElementAddr, a cast, a
// Select or Phi, integer arithmetic on it) inherits its operands' roots.
// Solved to a fixpoint because a Phi can name a later definition.
+ (NSDictionary<NSNumber *, NSSet<NSNumber *> *> *)addressRootsForFunction:(XTIRFunction *)fn {
    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *roots =
        [NSMutableDictionary dictionary];
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (XTIRBlock *b in fn.blocks) {
            NSMutableArray<XTIRInsn *> *seq = [NSMutableArray array];
            [seq addObjectsFromArray:b.phiNodes];
            [seq addObjectsFromArray:b.instructions];
            for (XTIRInsn *insn in seq) {
                if (!insn.result) continue;
                BOOL isAddrOf = NO;
                switch (insn.opcode) {
                    case XTIROpAddrOf: isAddrOf = YES; break;
                    case XTIROpFieldAddr: case XTIROpElementAddr:
                    case XTIROpBitcast: case XTIROpCopy:
                    case XTIROpIntToPtr: case XTIROpPtrToInt:
                    case XTIROpAdd: case XTIROpSub:
                    case XTIROpSelect: case XTIROpPhi:
                        break;
                    default: continue;
                }
                NSNumber *key = @(insn.result.valueId);
                NSMutableSet<NSNumber *> *mine = roots[key];
                for (XTIROperand *op in insn.operands) {
                    if (op.kind != XTIROperandKindUse) continue;
                    NSMutableSet<NSNumber *> *add = [NSMutableSet set];
                    if (isAddrOf) [add addObject:@(op.valueId)];
                    NSSet<NSNumber *> *inherited = roots[@(op.valueId)];
                    if (inherited) [add unionSet:inherited];
                    if (add.count == 0) continue;
                    if (!mine) { mine = [NSMutableSet set]; roots[key] = mine; }
                    if (![add isSubsetOfSet:mine]) { [mine unionSet:add]; changed = YES; }
                }
            }
        }
    }
    return roots;
}

// Compute, per call instruction, the ZP bytes that must be preserved
// across it = the values LIVE immediately after the call (defined
// before, used after), intersected with the ZP allocation, minus the
// call's own result. Stored in ctx.callSaveSets keyed by the insn
// pointer. A classic backward liveness pass: gen/kill per block, a
// fixpoint for block live-out, then a per-block backward walk recording
// each call's live-after set.
//
// Phi nodes are handled CONSERVATIVELY: each phi's operand values are
// treated as block-level uses (live-in) and its result as a block def.
// That over-approximates a value's live range (it may look live out of
// predecessors it isn't really defined on), which only ever saves a few
// extra slots — never fewer — so it can't reintroduce a clobber.
//
// An address-taken value (a by-value struct param, a pinned local) is read
// through pointers derived from its AddrOf, so its own SSA uses can end at
// the AddrOf while a FieldAddr of it is still read after the call. Its ZP
// home sits in the pool every function shares, so a callee reuses it. A
// live value therefore also keeps alive the values its address derives
// from (see addressRootsForFunction:).
+ (void)computeCallerSaveSetsForCtx:(XT6502FnCtx *)ctx {
    XTIRFunction *fn = ctx.fn;
    ctx.callSaveSets = [NSMutableDictionary dictionary];
    NSArray<XTIRBlock *> *blocks = fn.blocks;
    if (blocks.count == 0) return;

    // gen (upward-exposed uses) and kill (defs) per block.
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *genMap =
        [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *killMap =
        [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock *b in blocks) {
        NSMutableSet<NSNumber *> *gen = [NSMutableSet set];
        NSMutableSet<NSNumber *> *kill = [NSMutableSet set];
        NSMutableArray<XTIRInsn *> *seq = [NSMutableArray array];
        [seq addObjectsFromArray:b.phiNodes];
        [seq addObjectsFromArray:b.instructions];
        if (b.terminator) [seq addObject:b.terminator];
        for (XTIRInsn *insn in seq) {
            NSMutableSet<NSNumber *> *u = [NSMutableSet set];
            NSMutableSet<NSNumber *> *d = [NSMutableSet set];
            [self collectInsn:insn uses:u defs:d];
            for (NSNumber *v in u) if (![kill containsObject:v]) [gen addObject:v];
            [kill unionSet:d];
        }
        [genMap setObject:gen forKey:b];
        [killMap setObject:kill forKey:b];
    }

    // Fixpoint: liveOut(B) = ∪ liveIn(succ); liveIn(B) = gen ∪ (liveOut − kill).
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *liveIn =
        [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *liveOut =
        [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock *b in blocks) {
        [liveIn setObject:[NSMutableSet set] forKey:b];
        [liveOut setObject:[NSMutableSet set] forKey:b];
    }
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (XTIRBlock *b in blocks.reverseObjectEnumerator) {
            NSMutableSet<NSNumber *> *out = [NSMutableSet set];
            XTIRInsn *term = b.terminator;
            if (term) {
                for (XTIROperand *op in term.operands) {
                    if (op.kind == XTIROperandKindBlock && op.blockRef) {
                        NSSet<NSNumber *> *si = [liveIn objectForKey:op.blockRef];
                        if (si) [out unionSet:si];
                    }
                }
            }
            NSMutableSet<NSNumber *> *in = [[genMap objectForKey:b] mutableCopy];
            NSMutableSet<NSNumber *> *outMinusKill = [out mutableCopy];
            [outMinusKill minusSet:[killMap objectForKey:b]];
            [in unionSet:outMinusKill];
            if (![out isEqualToSet:[liveOut objectForKey:b]]
                || ![in isEqualToSet:[liveIn objectForKey:b]]) {
                [liveOut setObject:out forKey:b];
                [liveIn setObject:in forKey:b];
                changed = YES;
            }
        }
    }

    NSDictionary<NSNumber *, NSSet<NSNumber *> *> *roots =
        [self addressRootsForFunction:fn];

    // Per-block backward walk: seed `live` with liveOut(B), step back
    // through terminator + instructions, and at each call record the
    // live-after set (= `live` at that point) as its save set.
    for (XTIRBlock *b in blocks) {
        NSMutableSet<NSNumber *> *live = [[liveOut objectForKey:b] mutableCopy];
        NSMutableArray<XTIRInsn *> *rev = [NSMutableArray array];
        if (b.terminator) [rev addObject:b.terminator];
        for (XTIRInsn *insn in b.instructions.reverseObjectEnumerator) [rev addObject:insn];
        for (XTIRInsn *insn in rev) {
            BOOL isCall = (insn.opcode == XTIROpCall
                           || insn.opcode == XTIROpCallIndirect
                           || insn.opcode == XTIROpVTblDispatch);
            if (isCall) {
                NSInteger rvid = insn.result ? (NSInteger)insn.result.valueId : -1;
                NSMutableSet<NSNumber *> *held = [live mutableCopy];
                for (NSNumber *v in live) {
                    NSSet<NSNumber *> *r = roots[v];
                    if (r) [held unionSet:r];
                }
                NSArray<NSNumber *> *bytes = [self zpBytesForLive:held
                                                        exceptVid:rvid
                                                              ctx:ctx];
                if (bytes.count > 0) {
                    ctx.callSaveSets[@((uintptr_t)insn)] = bytes;
                }
            }
            // Step the live set back across this instruction.
            if (insn.result) [live removeObject:@(insn.result.valueId)];
            if (insn.memoryResult) [live removeObject:@(insn.memoryResult.valueId)];
            for (XTIROperand *op in insn.operands) {
                if (op.kind == XTIROperandKindUse) [live addObject:@(op.valueId)];
            }
        }
    }
}

#pragma mark - SP-frame slot allocation with liveness reuse

// Assign SP-frame byte offsets to the frame-eligible values (non-pinned,
// non-Mem, width>0) with liveness-based reuse: values whose live ranges
// don't overlap share the same frame bytes. Without reuse a large
// function (e.g. Stdio.printStruct, ~380 mostly-short-lived temps) needs
// hundreds of frame bytes and blows the §6.1 119-byte budget; reuse
// compresses N to roughly the peak simultaneous-live footprint. Sets
// ctx.spFrameBase (vid → byte offset) and ctx.spFrameSize (N).
//
// Liveness (gen/kill + fixpoint) → interference (a def interferes with
// everything live across it) → greedy width-aware colouring (lowest
// non-conflicting offset, deterministic value order).
// Point each non-pinned user param's SP-frame slot AT its incoming
// caller-stack offset (§3: params start at +N+10, byte 0 lowest, N =
// ctx.spFrameSize from computeFrameSlotsForCtx). The body then reads the
// param straight from the caller's pushed args, and the prologue's entry
// copy `LDA +off,SP / STA +off,SP` is a self-move that emitParams skips —
// no per-call relocation into a local slot. Pinned/address-taken params
// are left alone (they spill to ZP for a real 16-bit address).
+ (void)placeParamsInPlaceForCtx:(XT6502FnCtx *)ctx
                       pinnedSet:(NSSet<NSNumber *> *)pinnedSet
{
    XTIRFunction *fn = ctx.fn;
    NSUInteger paramCount = fn.paramTypes.count;
    NSUInteger userParams = (paramCount > 0
        && [fn.paramTypes.lastObject kind] == XTIRTypeKindMemory)
        ? paramCount - 1 : paramCount;
    NSUInteger pOff = [self paramBaseForCtx:ctx];
    for (NSUInteger i = 0; i < userParams; i++) {
        NSUInteger w = [self byteWidthForType:fn.paramTypes[i]];
        if (w > 0 && ![pinnedSet containsObject:@((XTIRValueId)i)])
            ctx.spFrameBase[@((XTIRValueId)i)] = @((NSInteger)pOff);
        pOff += w;
    }
}

// SP-relative offset of the first parameter byte once the prologue has run.
// After PSH #N: [guard@+0, regs@+1..+6, locals@+7..+N+6, gap@+N+7,
// ret@+N+8..+N+9, params@+N+10..]. Under the xtc-stack convention the return
// address has been pulled and only the N local bytes were allocated, so the
// parameters follow the locals directly: +N+1.
+ (NSUInteger)paramBaseForCtx:(XT6502FnCtx *)ctx {
    return ctx.xtcStack ? 1 + ctx.spFrameSize : 10 + ctx.spFrameSize;
}

+ (void)computeFrameSlotsForCtx:(XT6502FnCtx *)ctx
                      pinnedSet:(NSSet<NSNumber *> *)pinnedSet
{
    XTIRFunction *fn = ctx.fn;
    NSArray<XTIRBlock *> *blocks = fn.blocks;

    // Frame-eligible values, in deterministic order, with widths.
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSNumber *> *widthOf = [NSMutableDictionary dictionary];
    void (^consider)(XTIRValue *) = ^(XTIRValue *v) {
        if (!v) return;
        NSNumber *k = @(v.valueId);
        if (widthOf[k] || [pinnedSet containsObject:k]) return;
        NSUInteger w = [self byteWidthForType:v.type];
        if (w == 0) return;
        widthOf[k] = @(w);
        [order addObject:k];
    };
    NSUInteger paramCount = fn.paramTypes.count;
    // User params are NOT given fresh local frame slots — they're addressed
    // in place at their incoming caller-stack offsets (assigned by
    // placeParamsInPlaceForCtx: after this returns), so the prologue's
    // per-call entry copy collapses to a self-move and is skipped. Pinned /
    // address-taken params still spill to ZP via the pinnedSet path. (A
    // param's incoming region at +N+10.. is disjoint from the local area
    // +7..+N+6, so leaving params out of the interference graph is safe —
    // no local can ever be coloured onto a param's slot.)
    for (XTIRBlock *block in blocks) {
        for (XTIRInsn *phi in block.phiNodes) consider(phi.result);
        for (XTIRInsn *insn in block.instructions) { consider(insn.result); consider(insn.memoryResult); }
        if (block.terminator) { consider(block.terminator.result); consider(block.terminator.memoryResult); }
    }
    ctx.spFrameSize = 0;
    if (order.count == 0) return;

    // gen/kill per block.
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *genMap = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *killMap = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock *b in blocks) {
        NSMutableSet<NSNumber *> *gen = [NSMutableSet set];
        NSMutableSet<NSNumber *> *kill = [NSMutableSet set];
        NSMutableArray<XTIRInsn *> *seq = [NSMutableArray array];
        [seq addObjectsFromArray:b.phiNodes];
        [seq addObjectsFromArray:b.instructions];
        if (b.terminator) [seq addObject:b.terminator];
        for (XTIRInsn *insn in seq) {
            NSMutableSet<NSNumber *> *u = [NSMutableSet set];
            NSMutableSet<NSNumber *> *d = [NSMutableSet set];
            [self collectInsn:insn uses:u defs:d];
            for (NSNumber *v in u) if (![kill containsObject:v]) [gen addObject:v];
            [kill unionSet:d];
        }
        [genMap setObject:gen forKey:b];
        [killMap setObject:kill forKey:b];
    }
    // Fixpoint for liveOut.
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *liveIn = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable<XTIRBlock *, NSMutableSet<NSNumber *> *> *liveOut = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock *b in blocks) {
        [liveIn setObject:[NSMutableSet set] forKey:b];
        [liveOut setObject:[NSMutableSet set] forKey:b];
    }
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (XTIRBlock *b in blocks.reverseObjectEnumerator) {
            NSMutableSet<NSNumber *> *out = [NSMutableSet set];
            if (b.terminator) {
                for (XTIROperand *op in b.terminator.operands) {
                    if (op.kind == XTIROperandKindBlock && op.blockRef) {
                        NSSet<NSNumber *> *si = [liveIn objectForKey:op.blockRef];
                        if (si) [out unionSet:si];
                    }
                }
            }
            NSMutableSet<NSNumber *> *in = [[genMap objectForKey:b] mutableCopy];
            NSMutableSet<NSNumber *> *outMinusKill = [out mutableCopy];
            [outMinusKill minusSet:[killMap objectForKey:b]];
            [in unionSet:outMinusKill];
            if (![out isEqualToSet:[liveOut objectForKey:b]] || ![in isEqualToSet:[liveIn objectForKey:b]]) {
                [liveOut setObject:out forKey:b];
                [liveIn setObject:in forKey:b];
                changed = YES;
            }
        }
    }

    // Interference: two values interfere iff simultaneously live at some
    // program point. At each point (block exit, then the live-in of every
    // instruction stepping backward) every pair of frame-eligible live
    // values is marked interfering. This is more robust than a
    // def-vs-live-out rule, which misses values that share a point but
    // neither is defined there — e.g. two params (defined together at
    // entry, no def instruction) or two same-block phis.
    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *interf = [NSMutableDictionary dictionary];
    for (NSNumber *k in order) interf[k] = [NSMutableSet set];
    void (^interfereAll)(NSSet<NSNumber *> *) = ^(NSSet<NSNumber *> *liveSet) {
        NSMutableArray<NSNumber *> *fe = [NSMutableArray array];
        for (NSNumber *x in liveSet) if (widthOf[x]) [fe addObject:x];
        for (NSUInteger i = 0; i < fe.count; i++)
            for (NSUInteger j = i + 1; j < fe.count; j++) {
                [interf[fe[i]] addObject:fe[j]];
                [interf[fe[j]] addObject:fe[i]];
            }
    };
    for (XTIRBlock *b in blocks) {
        NSMutableSet<NSNumber *> *live = [[liveOut objectForKey:b] mutableCopy];
        interfereAll(live);
        NSMutableArray<XTIRInsn *> *rev = [NSMutableArray array];
        if (b.terminator) [rev addObject:b.terminator];
        for (XTIRInsn *insn in b.instructions.reverseObjectEnumerator) [rev addObject:insn];
        for (XTIRInsn *phi in b.phiNodes.reverseObjectEnumerator) [rev addObject:phi];
        // A def writes its slot at this program point, so its result
        // interferes with everything live ACROSS the def (= the set live
        // immediately after the instruction). For a normal value the
        // result is itself in that live set, so the interfereAll passes
        // below already capture it; but a DEAD def (result never used)
        // is never added to any live set by SSA liveness, so without this
        // it interferes with nothing and gets coloured onto a slot held
        // by a value live across it (e.g. a dead `Const #0` landing on the
        // __self pointer's slot — its `STA slot` then clobbers self). So
        // connect each result to the current `live` (= def's live-out)
        // before stepping it out.
        void (^connectDef)(XTIRValue *) = ^(XTIRValue *r) {
            if (!r) return;
            NSNumber *rk = @(r.valueId);
            if (!widthOf[rk]) return;
            for (NSNumber *x in live) {
                if ([x isEqual:rk] || !widthOf[x]) continue;
                [interf[rk] addObject:x];
                [interf[x] addObject:rk];
            }
        };
        for (XTIRInsn *insn in rev) {
            connectDef(insn.result);
            connectDef(insn.memoryResult);
            if (insn.result) [live removeObject:@(insn.result.valueId)];
            if (insn.memoryResult) [live removeObject:@(insn.memoryResult.valueId)];
            for (XTIROperand *op in insn.operands)
                if (op.kind == XTIROperandKindUse) [live addObject:@(op.valueId)];
            interfereAll(live);
        }
    }
    // Params are copied into their slots at entry in param order, so two
    // params sharing a slot would have the second copy clobber the first —
    // force all frame-eligible params into distinct slots regardless of
    // liveness. (Non-params are def'd in the body before use, so an
    // entry-time clobber of a shared slot is harmless.)
    NSMutableArray<NSNumber *> *frameParams = [NSMutableArray array];
    for (NSUInteger i = 0; i < paramCount; i++) {
        NSNumber *k = @(i);
        if (widthOf[k]) [frameParams addObject:k];
    }
    for (NSUInteger i = 0; i < frameParams.count; i++)
        for (NSUInteger j = i + 1; j < frameParams.count; j++) {
            [interf[frameParams[i]] addObject:frameParams[j]];
            [interf[frameParams[j]] addObject:frameParams[i]];
        }
    // A successor's phi results are materialised by edge copies emitted at
    // the END of each predecessor — after that block's body but BEFORE its
    // terminator reads the branch condition. So a phi result must not
    // share a slot with anything live at that point: the predecessor's
    // live-out, *and* the terminator's own operands (the branch condition,
    // read after the copies). Standard SSA liveness misses this because
    // the phi result is "defined" at the successor's entry, not here.
    for (XTIRBlock *b in blocks) {
        XTIRInsn *term = b.terminator;
        if (!term) continue;
        NSMutableSet<NSNumber *> *liveAtBranch = [[liveOut objectForKey:b] mutableCopy];
        for (XTIROperand *op in term.operands)
            if (op.kind == XTIROperandKindUse) [liveAtBranch addObject:@(op.valueId)];
        for (XTIROperand *op in term.operands) {
            if (op.kind != XTIROperandKindBlock || !op.blockRef) continue;
            for (XTIRInsn *phi in op.blockRef.phiNodes) {
                if (!phi.result) continue;
                NSNumber *pr = @(phi.result.valueId);
                if (!widthOf[pr]) continue;
                for (NSNumber *x in liveAtBranch) {
                    if ([x isEqual:pr] || !widthOf[x]) continue;
                    [interf[pr] addObject:x];
                    [interf[x] addObject:pr];
                }
            }
        }
    }

    // A multi-byte Load re-reads its pointer (via (d,SP),Y) for every
    // result byte, so writing a result byte into the pointer's own slot
    // would corrupt the next byte's deref. SSA liveness usually has the
    // pointer dying at the Load, so it wouldn't interfere with the result
    // — force them apart explicitly.
    for (XTIRBlock *b in blocks) {
        for (XTIRInsn *insn in b.instructions) {
            if (insn.opcode != XTIROpLoad && insn.opcode != XTIROpLoadVolatile) continue;
            if (!insn.result || insn.operands.count < 1) continue;
            XTIROperand *ptrOp = insn.operands[0];
            if (ptrOp.kind != XTIROperandKindUse) continue;
            NSNumber *rk = @(insn.result.valueId), *pk = @(ptrOp.valueId);
            if (widthOf[rk] && widthOf[pk] && ![rk isEqual:pk]) {
                [interf[rk] addObject:pk];
                [interf[pk] addObject:rk];
            }
        }
    }

    // Multi-byte ops emit a byte loop: write result_b, then read
    // operand_{b+1}. If a ≥2-byte result *partially* overlaps a ≥2-byte
    // operand (e.g. result_lo lands on the operand's hi byte), writing
    // result_lo corrupts the operand byte read on the next iteration.
    // (Exact same-range coalescing is safe — read-before-write per byte —
    // but greedy colouring can't guarantee exactness, so forbid any
    // overlap.) Single-byte results/operands have no cross-byte read, so
    // they're exempt. Net frame-size cost is small: the operands die at
    // the op, freeing their slots for other values.
    for (XTIRBlock *b in blocks) {
        NSMutableArray<XTIRInsn *> *all = [NSMutableArray array];
        [all addObjectsFromArray:b.phiNodes];
        [all addObjectsFromArray:b.instructions];
        if (b.terminator) [all addObject:b.terminator];
        for (XTIRInsn *insn in all) {
            if (!insn.result) continue;
            NSNumber *rk = @(insn.result.valueId);
            if (!widthOf[rk] || widthOf[rk].unsignedIntegerValue < 2) continue;
            for (XTIROperand *op in insn.operands) {
                if (op.kind != XTIROperandKindUse) continue;
                NSNumber *ok = @(op.valueId);
                if (widthOf[ok] && widthOf[ok].unsignedIntegerValue >= 2 && ![ok isEqual:rk]) {
                    [interf[rk] addObject:ok];
                    [interf[ok] addObject:rk];
                }
            }
        }
    }

    // Greedy width-aware colouring: lowest free offset ≥ 7.
    //
    // Frame layout (6502-embellishments §3): SP+0 is the guard byte, the
    // 6 saved-register slots are SP+1..SP+6, and the local area starts at
    // SP+7. (PSH #N allocates N+7 = guard + 6 saved regs + N locals.)
    // Under the xtc-stack convention there is no guard byte and no saved
    // registers on the hardware stack, so the locals start at SP+1.
    NSUInteger base = ctx.frameLocalsBase;
    NSUInteger maxEnd = base;
    for (NSNumber *k in order) {
        NSUInteger w = widthOf[k].unsignedIntegerValue;
        NSMutableArray<NSArray<NSNumber *> *> *occ = [NSMutableArray array];
        for (NSNumber *x in interf[k]) {
            NSNumber *ox = ctx.spFrameBase[x];
            if (!ox) continue;
            NSUInteger oxv = ox.unsignedIntegerValue;
            [occ addObject:@[@(oxv), @(oxv + widthOf[x].unsignedIntegerValue)]];
        }
        [occ sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *bb) {
            return [a[0] compare:bb[0]];
        }];
        NSUInteger o = base;
        for (NSArray<NSNumber *> *r in occ) {
            NSUInteger s = r[0].unsignedIntegerValue, e = r[1].unsignedIntegerValue;
            if (o < e && o + w > s) o = e;   // overlap → bump past this range
        }
        ctx.spFrameBase[k] = @(o);
        if (o + w > maxEnd) maxEnd = o + w;
    }
    ctx.spFrameSize = maxEnd - base;       // N = local bytes (PSH #N immediate)
}

// The per-call ZP byte set (empty if the call has nothing live across it).
+ (NSArray<NSNumber *> *)saveBytesForCall:(XTIRInsn *)insn ctx:(XT6502FnCtx *)ctx {
    if (!ctx.callSaveSets) [self computeCallerSaveSetsForCtx:ctx];
    return ctx.callSaveSets[@((uintptr_t)insn)] ?: @[];
}

// Emit the caller-save push for `insn` (before the args). Each preserved
// ZP byte is read (non-destructively) and PHA'd, ascending; the saved
// bytes sit below the args, so the callee's SP-relative param offsets
// are unchanged.
+ (void)emitCallerSaveFor:(XTIRInsn *)insn ctx:(XT6502FnCtx *)ctx {
    for (NSNumber *addr in [self saveBytesForCall:insn ctx:ctx]) {
        [ctx.out appendFormat:@"    LDA $%02lX\n", (unsigned long)addr.unsignedIntegerValue];
        [self emitPHA:ctx];
    }
}

// Emit the matching caller-restore for `insn` (after the return-value
// harvest), popping the saved bytes descending. The call's result is
// excluded from the save set, so every popped byte is restored — the
// freshly-harvested result slot is never in the set, so it survives.
+ (void)emitCallerRestoreFor:(XTIRInsn *)insn ctx:(XT6502FnCtx *)ctx {
    NSArray<NSNumber *> *bytes = [self saveBytesForCall:insn ctx:ctx];
    for (NSInteger i = (NSInteger)bytes.count - 1; i >= 0; i--) {
        [self emitPLA:ctx];
        [ctx.out appendFormat:@"    STA $%02lX\n",
         (unsigned long)bytes[(NSUInteger)i].unsignedIntegerValue];
    }
}

#pragma mark - Code-bank placement (task #60)

// Estimate the assembled byte size of a rendered function from its
// emitted asm text. Used only by the banked-placement packer to decide
// when a function overflows the unbanked budget / a 16 KB bank — the
// assembler's `.code_regions` and per-bank-size checks are the real
// guard against an underestimate, so this leans conservative (it never
// undercounts a real instruction). One line = one instruction or
// directive; sizes follow the 6502 + xt addressing modes the
// backend emits.
+ (NSUInteger)asmByteSize:(NSString *)asmText {
    NSUInteger total = 0;
    for (NSString *raw in [asmText componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@";"]) continue;
        // Strip a trailing comment.
        NSRange sc = [line rangeOfString:@";"];
        if (sc.location != NSNotFound) {
            line = [[line substringToIndex:sc.location]
                    stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
            if (line.length == 0) continue;
        }
        // Label-only line (ends with ':' and nothing follows) → 0 bytes.
        if ([line hasSuffix:@":"]) continue;
        // A line may be "label: INSN ..." — drop a leading label.
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *afterColon = [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (afterColon.length == 0) continue;
            line = afterColon;
        }
        // Split mnemonic / operand.
        NSRange ws = [line rangeOfCharacterFromSet:
                      [NSCharacterSet whitespaceCharacterSet]];
        NSString *mnem = (ws.location == NSNotFound) ? line
                       : [line substringToIndex:ws.location];
        NSString *operand = (ws.location == NSNotFound) ? @""
            : [[line substringFromIndex:ws.location]
               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *m = mnem.uppercaseString;
        // Data directives.
        if ([m isEqualToString:@".BYTE"]) {
            total += [operand componentsSeparatedByString:@","].count;
            continue;
        }
        if ([m isEqualToString:@".WORD"]) {
            total += 2 * [operand componentsSeparatedByString:@","].count;
            continue;
        }
        if ([m isEqualToString:@".SPACE"]) {
            total += (NSUInteger)strtol(operand.UTF8String, NULL, 0);
            continue;
        }
        if ([m hasPrefix:@"."]) continue;   // other directives → 0
        // Branches are 2 bytes (relative) — but xta rewrites an
        // out-of-range branch into "inverse-branch + JMP" (5 bytes). We
        // can't know which get rewritten without assembling, so count
        // the worst case (5): the placement packer needs an UPPER bound
        // so a function never silently overflows its bank / the unbanked
        // region (the assembler's hard checks are the backstop).
        static NSSet *branches = nil;
        if (!branches) branches = [NSSet setWithArray:@[
            @"BEQ", @"BNE", @"BCC", @"BCS", @"BPL", @"BMI", @"BVC", @"BVS", @"BRA"]];
        if ([branches containsObject:m]) { total += 5; continue; }
        // xt housekeeping ops carrying a #imm → 2 bytes.
        if ([m isEqualToString:@"PSH"] || [m isEqualToString:@"PLL"]
            || [m isEqualToString:@"ADD"]) { total += 2; continue; }
        if (operand.length == 0) { total += 1; continue; }   // implied
        if ([operand hasPrefix:@"#"]) { total += 2; continue; }       // immediate
        if ([operand hasPrefix:@"("]) {                                // indirect
            // ($abs) for JMP = 3; (zp),Y / (zp,X) = 2.
            total += [m isEqualToString:@"JMP"] ? 3 : 2;
            continue;
        }
        if ([operand rangeOfString:@",SP"].location != NSNotFound) {
            total += 2;     // SP-relative (LDA +N,SP etc.)
            continue;
        }
        if ([m isEqualToString:@"JMP"] || [m isEqualToString:@"JSR"]) {
            total += 3; continue;       // absolute target
        }
        // Memory operand: zero-page ($xx, ≤2 hex digits before any ',')
        // is 2 bytes; absolute ($xxxx) or a symbol is 3.
        if ([operand hasPrefix:@"$"]) {
            NSString *base = [operand componentsSeparatedByString:@","].firstObject;
            NSUInteger hexDigits = base.length - 1;   // minus the '$'
            total += (hexDigits <= 2) ? 2 : 3;
            continue;
        }
        // Symbol operand (label) → absolute, 3 bytes.
        total += 3;
    }
    return total;
}

// Count the 6502 instructions in rendered asm text: every line that is not
// blank, a comment, a bare label or a directive. `-Fmb` compares a function's
// count, taken from the first sizing render, against its threshold.
+ (NSUInteger)asmInsnCount:(NSString *)asmText {
    NSUInteger n = 0;
    for (NSString *raw in [asmText componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@";"]) continue;
        NSRange sc = [line rangeOfString:@";"];
        if (sc.location != NSNotFound) {
            line = [[line substringToIndex:sc.location]
                    stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
            if (line.length == 0) continue;
        }
        if ([line hasSuffix:@":"]) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            line = [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (line.length == 0) continue;
        }
        if ([line hasPrefix:@"."]) continue;
        n++;
    }
    return n;
}

// Pad `s` with spaces to `width` bytes (never truncates). The -dp and -du
// reports are laid out in columns this way rather than with printf widths,
// so the text is the same whichever compiler prints it.
static NSString *padRight(NSString *s, NSUInteger width) {
    NSMutableString *m = [s mutableCopy];
    while (m.length < width) [m appendString:@" "];
    return m;
}

static NSString *padLeft(NSString *s, NSUInteger width) {
    NSMutableString *m = [NSMutableString string];
    while (m.length + s.length < width) [m appendString:@" "];
    [m appendString:s];
    return m;
}

// The -dp text. `order` lists the functions in emission order; `where`
// gives each one's placement, `sizes` its estimated bytes and `notes` an
// optional reason in parentheses. `bankSize` is the code window's size, 0
// on an unbanked layout.
+ (NSString *)placementReportFor:(XTMemoryModel *)model
                           order:(NSArray<NSString *> *)order
                           where:(NSDictionary<NSString *, NSString *> *)where
                           sizes:(NSDictionary<NSString *, NSNumber *> *)sizes
                           notes:(NSDictionary<NSString *, NSString *> *)notes
                         bankMap:(nullable NSDictionary<NSString *, NSNumber *> *)bankMap
                        bankSize:(NSUInteger)bankSize {
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"xcc: placement for layout '%@' (sizes are the compiler's estimates, an upper bound):\n",
        model.name ?: @"(unnamed)"];
    NSUInteger mainBytes = 0, bankCount = 0;
    NSMutableDictionary<NSNumber *, NSNumber *> *perBank = [NSMutableDictionary dictionary];
    for (NSString *name in order) {
        NSUInteger sz = sizes[name].unsignedIntegerValue;
        NSUInteger b = bankMap[name].unsignedIntegerValue;
        if (b == 0) {
            mainBytes += sz;
        } else {
            perBank[@(b)] = @(perBank[@(b)].unsignedIntegerValue + sz);
            if (b > bankCount) bankCount = b;
        }
        NSString *note = notes[name];
        [r appendFormat:@"  %@ %@ bytes  %@%@\n",
            padRight(where[name], 8),
            padLeft([NSString stringWithFormat:@"%lu", (unsigned long)sz], 6),
            name, note.length ? [NSString stringWithFormat:@" (%@)", note] : @""];
    }
    [r appendString:@"xcc: bytes used by generated code:\n"];
    [r appendFormat:@"  %@ %@ bytes (the runtime shares this region)\n",
        padRight(@"main", 8),
        padLeft([NSString stringWithFormat:@"%lu", (unsigned long)mainBytes], 6)];
    for (NSUInteger b = 1; b <= bankCount; b++) {
        [r appendFormat:@"  %@ %@ of %lu bytes\n",
            padRight([NSString stringWithFormat:@"bank %lu", (unsigned long)b], 8),
            padLeft([NSString stringWithFormat:@"%lu",
                     (unsigned long)perBank[@(b)].unsignedIntegerValue], 6),
            (unsigned long)bankSize];
    }
    return r;
}

// Bank id of a called symbol: the function's assigned bank, or 0
// (unbanked) for runtime helpers / external symbols not in the map.
+ (NSUInteger)bankForCalleeName:(NSString *)name ctx:(XT6502FnCtx *)ctx {
    NSNumber *b = ctx.bankMap[name];
    return b ? b.unsignedIntegerValue : 0;
}

// Functions that must NOT be code-banked. xtc's OWN indirect-call paths are now
// bank-aware — VTblDispatch (bank-tagged vtable entries) and CallIndirect
// (3-byte banked function pointers, task #65 stage 2: `AddrOf @fn` bakes the
// code bank into byte 2, dispatch routes through __xt_indcall) — so ordinary
// address-taken functions (deallocs, callbacks) may now be banked. But a
// HARDWARE-dispatched handler cannot: the Atari ROM jumps to an :irq/:vbi
// handler via $FFFE / VVBLKI directly — a raw jump with no bank trampoline — so
// the handler's body must live in the unbanked region. Force exactly those.
// (The entry is forced unbanked separately by the placement.)
+ (NSSet<NSString *> *)mustStayUnbankedFunctionsIn:(XTIRModule *)mod {
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (XTIRSymbol *s in mod.symbols) {
        if (s.kind != XTIRSymbolKindFunction || !s.name.length) continue;
        if ([s.attributes[@"irq"] boolValue] || [s.attributes[@"vbi"] boolValue])
            [set addObject:s.name];
    }
    return set;
}

#pragma mark - Operand materialisation

// Emit a `LDA <byte>` for `byteIndex` of the operand, where byteIndex
// = 0 is the LSB. Returns YES on success.
+ (BOOL)loadOperandByte:(XTIROperand *)op
              byteIndex:(NSUInteger)byteIndex
                    ctx:(XT6502FnCtx *)ctx
{
    switch (op.kind) {
        case XTIROperandKindUse: {
            // A value narrower than the byte being requested (e.g. an op whose
            // result is wider than this operand — Neg(U8)->I16) has no slot
            // byte at `byteIndex`; reading it would pull a neighbouring value.
            // Emit the proper extension instead: 0 for unsigned, the sign byte
            // for signed. Carry-preserving (PHP/PLP) so add/sub byte chains
            // that call this between bytes aren't corrupted.
            XTIRValue *v = [ctx.fn valueForId:op.valueId];
            NSUInteger w = v ? [self byteWidthForType:v.type] : 0;
            if (w && byteIndex >= w) {
                if (XTIRTypeKindIsSigned(v.type.kind)) {
                    NSString *msb = [self operandForValueId:op.valueId byteIndex:w - 1 ctx:ctx];
                    [ctx.out appendFormat:@"    PHP\n    LDA %@\n    ASL A\n    LDA #$00\n"
                                          @"    ADC #$FF\n    EOR #$FF\n    PLP\n", msb];
                } else {
                    [ctx.out appendString:@"    LDA #$00\n"];
                }
                return YES;
            }
            NSString *operand = [self operandForValueId:op.valueId byteIndex:byteIndex ctx:ctx];
            if (!operand) return NO;
            [ctx.out appendFormat:@"    LDA %@\n", operand];
            return YES;
        }
        case XTIROperandKindImmI: {
            int64_t v = op.intValue;
            uint8_t b = (uint8_t)((v >> (8 * byteIndex)) & 0xFF);
            [ctx.out appendFormat:@"    LDA #$%02X\n", b];
            return YES;
        }
        case XTIROperandKindImmF: {
            // Float immediate: floatRawBytes holds the abstract IEEE-754 double
            // bits; encode to this target's float layout, then extract the byte.
            NSUInteger fw = op.type ? [self byteWidthForType:op.type] : 4;
            NSData *enc = [self encodeFloatBits:op.floatRawBytes width:fw];
            uint8_t b = (byteIndex < enc.length)
                ? ((const uint8_t *)enc.bytes)[byteIndex] : 0;
            [ctx.out appendFormat:@"    LDA #$%02X\n", b];
            return YES;
        }
        default:
            return NO;
    }
}

// Absolute memory operand for an AbsSym known address at byteIndex —
// `_<name>+<offset+byteIndex>`, collapsing to bare `_<name>` at zero.
+ (NSString *)absSymOperandForKnownAddr:(XT6502KnownAddr *)ka
                              byteIndex:(NSUInteger)byteIndex
{
    NSUInteger disp = ka.offset + byteIndex;
    if (disp == 0) return ka.spillLabel;
    return [NSString stringWithFormat:@"%@+%lu", ka.spillLabel,
            (unsigned long)disp];
}

// Store A into byteIndex of the value's ZP slot.
+ (void)storeAToValueId:(XTIRValueId)vid
              byteIndex:(NSUInteger)byteIndex
                    ctx:(XT6502FnCtx *)ctx
{
    NSString *operand = [self operandForValueId:vid byteIndex:byteIndex ctx:ctx];
    if (!operand) return;
    [ctx.out appendFormat:@"    STA %@\n", operand];
}

// Encode a float constant — given as the IR's abstract IEEE-754 double bits —
// into this target's `width`-byte layout. Under MECH the layout IS IEEE (f32 =
// 4-byte single, f64 = 8-byte double, little-endian); the legacy 5-byte xtc
// softfloat is used only when floatIsIEEE is off.
+ (NSData *)encodeFloatBits:(uint64_t)raw width:(NSUInteger)width {
    double value = 0.0;
    memcpy(&value, &raw, sizeof(value));
    if ([XTType floatIsIEEE]) {
        uint8_t b[8];
        if (width == 8) {
            uint64_t bits; memcpy(&bits, &value, 8);
            for (int i = 0; i < 8; i++) b[i] = (uint8_t)((bits >> (8 * i)) & 0xFF);
            return [NSData dataWithBytes:b length:8];
        }
        float f = (float)value; uint32_t bits; memcpy(&bits, &f, 4);
        for (int i = 0; i < 4; i++) b[i] = (uint8_t)((bits >> (8 * i)) & 0xFF);
        return [NSData dataWithBytes:b length:4];
    }
    return (width == 8) ? [XTFloatEncoding encodeDoubleDouble:value]
                        : [XTFloatEncoding encodeDouble:value];
}

#pragma mark - MECH math coprocessor

// The reusable "emit a MECH program from IR" substrate. The op-word ABI is the
// shared 6502<->A9 contract in the XTOS loader's test/freertos/mathcop.h; the
// xts model lives in src/xts/sim6502.c. Every emitter maps the 8 KB math page
// over $4000-$5FFF ($D5C6.0), marshals operands into the slot file (S0 at
// $4040, S1 at $4048, ...; 8 bytes/slot), writes 3-address op words at $4840,
// rings the doorbell ($D5C7), spins on done ($D5C7.0), reads results, unmaps.
// Banking is unlocked by startup so $D5C6 is live. Per-op map/unmap for now;
// batching (map once, DEF/CALL kernels) is a later phase.
//   MC_T_*: F32=0 F64=1 I32=2 I64=3.  Slot byte address = $4040 + slot*8 + b.

// Marshal `opW` bytes of an operand into slot `slot`, filling the slot up to
// `slotBytes` (= the element size MECH reads) with a sign- or zero-extension.
+ (void)mechStore:(XTIROperand *)op width:(NSUInteger)opW slot:(unsigned)slot
        slotBytes:(NSUInteger)slotBytes signExtend:(BOOL)sx ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    unsigned base = 0x4040 + slot * 8;
    for (NSUInteger b = 0; b < opW; b++) {
        [self loadOperandByte:op byteIndex:b ctx:ctx];
        [o appendFormat:@"    STA $%04X\n", base + (unsigned)b];
    }
    if (slotBytes <= opW) return;
    if (sx) {                                       // sign-extend the MSB across the fill
        NSUInteger lbl = ctx.labelCounter++;
        // LDX #$00 FIRST — it sets N/Z, so the operand load must come after it
        // for BPL to test the operand's sign (not the immediate's).
        [o appendString:@"    LDX #$00\n"];
        [self loadOperandByte:op byteIndex:opW - 1 ctx:ctx];
        [o appendFormat:@"    BPL .Lsx%lu\n    LDX #$FF\n.Lsx%lu:\n    TXA\n",
            (unsigned long)lbl, (unsigned long)lbl];
    } else {
        [o appendString:@"    LDA #$00\n"];
    }
    for (NSUInteger b = opW; b < slotBytes; b++)
        [o appendFormat:@"    STA $%04X\n", base + (unsigned)b];
}

// Emit one op word at program index `idx`: dst = op(src1, src2).
+ (void)mechOpWord:(unsigned)idx b0:(unsigned)b0 s1:(unsigned)s1 s2:(unsigned)s2
               dst:(unsigned)dst ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    unsigned base = 0x4840 + idx * 4;
    [o appendFormat:@"    LDA #$%02X\n    STA $%04X\n", b0 & 0xFF, base];
    [o appendFormat:@"    LDA #$%02X\n    STA $%04X\n", s1 & 0xFF, base + 1];
    [o appendFormat:@"    LDA #$%02X\n    STA $%04X\n", s2 & 0xFF, base + 2];
    [o appendFormat:@"    LDA #$%02X\n    STA $%04X\n", dst & 0xFF, base + 3];
}

+ (void)mechMap:(XT6502FnCtx *)ctx   { [ctx.out appendString:@"    LDA #$01\n    STA $D5C6\n"]; }
+ (void)mechUnmap:(XT6502FnCtx *)ctx { [ctx.out appendString:@"    LDA #$00\n    STA $D5C6\n"]; }

// op_count = `n`, ring the doorbell, spin on done.
+ (void)mechRun:(NSUInteger)n ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    NSUInteger lbl = ctx.labelCounter++;
    [o appendFormat:@"    LDA #$%02X\n    STA $4000\n", (unsigned)(n & 0xFF)];
    [o appendFormat:@"    LDA #$%02X\n    STA $4001\n", (unsigned)((n >> 8) & 0xFF)];
    [o appendString:@"    STA $D5C7\n"];
    [o appendFormat:@".Lmech%lu:\n    LDA $D5C7\n    AND #$01\n    BEQ .Lmech%lu\n",
        (unsigned long)lbl, (unsigned long)lbl];
}

// Read `bytes` from slot `slot` into the result value.
+ (void)mechResult:(XTIRInsn *)insn slot:(unsigned)slot bytes:(NSUInteger)bytes
               ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    unsigned base = 0x4040 + slot * 8;
    for (NSUInteger b = 0; b < bytes; b++) {
        [o appendFormat:@"    LDA $%04X\n", base + (unsigned)b];
        [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
    }
}

// Two-operand op: S2 = op(S0, S1). Serves int arith (mcType I32/I64, opW=4,
// slotBytes 4 or 8 with zero-extend for unsigned) and float arith (mcType
// F32/F64, opW=slotBytes=4/8).
+ (void)emitMechBinop:(XTIRInsn *)insn opWidth:(NSUInteger)opW mcType:(unsigned)mcType
                 mcOp:(unsigned)mcOp slotBytes:(NSUInteger)slotBytes
           signExtend:(BOOL)sx resultBytes:(NSUInteger)rBytes ctx:(XT6502FnCtx *)ctx {
    [self mechMap:ctx];
    [self mechStore:insn.operands[0] width:opW slot:0 slotBytes:slotBytes signExtend:sx ctx:ctx];
    [self mechStore:insn.operands[1] width:opW slot:1 slotBytes:slotBytes signExtend:sx ctx:ctx];
    [self mechOpWord:0 b0:((mcType & 3) << 6) | (mcOp & 0x3F) s1:0 s2:1 dst:2 ctx:ctx];
    [self mechRun:1 ctx:ctx];
    [self mechResult:insn slot:2 bytes:rBytes ctx:ctx];
    [self mechUnmap:ctx];
}

// Unary op: S2 = op(S0). Serves FSqrt/FNeg-via-MECH and (with mcOp==CVT and a
// distinct source type in byte2) all int<->float conversions.
+ (void)emitMechUnary:(XTIRInsn *)insn srcWidth:(NSUInteger)srcW srcType:(unsigned)srcType
              srcBytes:(NSUInteger)srcBytes signExtend:(BOOL)sx dstType:(unsigned)dstType
                 mcOp:(unsigned)mcOp resultBytes:(NSUInteger)rBytes ctx:(XT6502FnCtx *)ctx {
    [self mechMap:ctx];
    [self mechStore:insn.operands[0] width:srcW slot:0 slotBytes:srcBytes signExtend:sx ctx:ctx];
    // For CVT, byte2 (s2) carries the SOURCE element type; other unary ops ignore it.
    unsigned s2 = (mcOp == 0x20 /*MC_OP_CVT*/) ? (srcType & 3) : 0;
    [self mechOpWord:0 b0:((dstType & 3) << 6) | (mcOp & 0x3F) s1:0 s2:s2 dst:2 ctx:ctx];
    [self mechRun:1 ctx:ctx];
    [self mechResult:insn slot:2 bytes:rBytes ctx:ctx];
    [self mechUnmap:ctx];
}

// Leave Z clear when a branch or Select condition is true. A bool is one byte,
// but a pointer or callback tested for null reaches here too, and its low byte
// alone is 0 for a function at $xx00: a pointer tests its two address bytes,
// anything else every byte, ORed together in $BF.
+ (void)loadCondTest:(XTIROperand *)cond ctx:(XT6502FnCtx *)ctx {
    NSUInteger cw = 1;
    if (cond.kind == XTIROperandKindUse) {
        XTIRValue *cv = [ctx.fn valueForId:cond.valueId];
        if (cv) cw = [self byteWidthForType:cv.type];
        if (cv && cv.type.kind == XTIRTypeKindPtr) cw = 2;
    } else if (cond.kind == XTIROperandKindImmI && cond.type) {
        cw = [self byteWidthForType:cond.type];
    }
    if (cw < 2) { [self loadOperandByte:cond byteIndex:0 ctx:ctx]; return; }
    [self loadOperandByte:cond byteIndex:cw - 1 ctx:ctx];
    for (NSUInteger b = cw - 1; b > 0; b--) {
        [ctx.out appendString:@"    STA $BF\n"];
        [self loadOperandByte:cond byteIndex:b - 1 ctx:ctx];
        [ctx.out appendString:@"    ORA $BF\n"];
    }
}

// A u64 with its top bit set is negative to MECH's signed i64. Halve it first,
// keeping the bit shifted out as a sticky low bit so the rounding is unchanged,
// convert, and double the result, which is exact.
+ (void)emitMechU64ToFp:(XTIRInsn *)insn dstType:(unsigned)dstType
            resultBytes:(NSUInteger)dw ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    unsigned long l = (unsigned long)ctx.labelCounter++;
    [self mechMap:ctx];
    [self mechStore:insn.operands[0] width:8 slot:0 slotBytes:8 signExtend:NO ctx:ctx];
    [o appendFormat:@"    LDA $4047\n    BPL .Lu64f%lu_p\n    LSR $4047\n", l];
    for (unsigned b = 7; b > 0; b--)
        [o appendFormat:@"    ROR $%04X\n", 0x4040 + b - 1];
    [o appendFormat:@"    BCC .Lu64f%lu_s\n    LDA $4040\n    ORA #$01\n    STA $4040\n.Lu64f%lu_s:\n", l, l];
    [self mechOpWord:0 b0:((dstType & 3) << 6) | 0x20 s1:0 s2:3 dst:2 ctx:ctx];
    [self mechOpWord:1 b0:((dstType & 3) << 6) | 0x01 s1:2 s2:2 dst:2 ctx:ctx];
    [self mechRun:2 ctx:ctx];
    [o appendFormat:@"    JMP .Lu64f%lu_d\n.Lu64f%lu_p:\n", l, l];
    [self mechOpWord:0 b0:((dstType & 3) << 6) | 0x20 s1:0 s2:3 dst:2 ctx:ctx];
    [self mechRun:1 ctx:ctx];
    [o appendFormat:@".Lu64f%lu_d:\n", l];
    [self mechResult:insn slot:2 bytes:dw ctx:ctx];
    [self mechUnmap:ctx];
}

// MECH CVT, float source, always to i64 so every destination width sees the
// whole truncated value. A narrower destination then keeps it only if it fits,
// and is 0 otherwise, as on every other target.
+ (void)emitMechFpToInt:(XTIRInsn *)insn floatWidth:(NSUInteger)fw intWidth:(NSUInteger)iw
                 signed:(BOOL)sgn ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    unsigned srcType = (fw == 8) ? 1 : 0;
    if (!sgn && iw == 8) { [self emitMechFpToU64:insn floatWidth:fw srcType:srcType ctx:ctx]; return; }
    [self mechMap:ctx];
    [self mechStore:insn.operands[0] width:fw slot:0 slotBytes:fw signExtend:NO ctx:ctx];
    [self mechOpWord:0 b0:(3 << 6) | 0x20 s1:0 s2:srcType dst:2 ctx:ctx];
    [self mechRun:1 ctx:ctx];
    if (iw < 8) {
        unsigned long l = (unsigned long)ctx.labelCounter++;
        [o appendString:@"    LDX #$00\n"];
        if (sgn)
            [o appendFormat:@"    LDA $%04X\n    BPL .Lfi%lu_f\n    LDX #$FF\n.Lfi%lu_f:\n",
                (unsigned)(0x4050 + iw - 1), l, l];
        for (NSUInteger b = iw; b < 8; b++)
            [o appendFormat:@"    CPX $%04X\n    BNE .Lfi%lu_z\n", (unsigned)(0x4050 + b), l];
        [o appendFormat:@"    JMP .Lfi%lu_k\n.Lfi%lu_z:\n    LDA #$00\n", l, l];
        for (NSUInteger b = 0; b < iw; b++)
            [o appendFormat:@"    STA $%04X\n", (unsigned)(0x4050 + b)];
        [o appendFormat:@".Lfi%lu_k:\n", l];
    }
    [self mechResult:insn slot:2 bytes:iw ctx:ctx];
    [self mechUnmap:ctx];
}

// A u64 destination reaches 2^64, past MECH's signed i64. Convert both the
// value and the value less 2^63, and compare it with 2^63 to pick one: the
// second with its top bit set back, or the first, which is 0 when negative.
+ (void)emitMechFpToU64:(XTIRInsn *)insn floatWidth:(NSUInteger)fw srcType:(unsigned)srcType
                    ctx:(XT6502FnCtx *)ctx {
    NSMutableString *o = ctx.out;
    unsigned long l = (unsigned long)ctx.labelCounter++;
    [self mechMap:ctx];
    [self mechStore:insn.operands[0] width:fw slot:0 slotBytes:fw signExtend:NO ctx:ctx];
    // 2^63 in the source's own format, in slot 1.
    for (NSUInteger b = 0; b < fw; b++) {
        unsigned v = 0;
        if (fw == 8 && b == 6) v = 0xE0;
        if (fw == 8 && b == 7) v = 0x43;
        if (fw == 4 && b == 3) v = 0x5F;
        [o appendFormat:@"    LDA #$%02X\n    STA $%04X\n", v, (unsigned)(0x4048 + b)];
    }
    unsigned st = (srcType & 3) << 6;
    [self mechOpWord:0 b0:(3 << 6) | 0x20 s1:0 s2:srcType dst:2 ctx:ctx];
    [self mechOpWord:1 b0:st | 0x02 s1:0 s2:1 dst:3 ctx:ctx];
    [self mechOpWord:2 b0:(3 << 6) | 0x20 s1:3 s2:srcType dst:3 ctx:ctx];
    [self mechOpWord:3 b0:st | 0x0A s1:0 s2:1 dst:4 ctx:ctx];
    [self mechRun:4 ctx:ctx];
    [o appendFormat:@"    LDA $4060\n    CMP #$FF\n    BNE .Lfu%lu_h\n", l];
    [o appendFormat:@"    LDA $4057\n    BPL .Lfu%lu_k\n    LDA #$00\n", l];
    for (unsigned b = 0; b < 8; b++)
        [o appendFormat:@"    STA $%04X\n", 0x4050 + b];
    [o appendFormat:@"    JMP .Lfu%lu_k\n.Lfu%lu_h:\n", l, l];
    for (unsigned b = 0; b < 8; b++) {
        [o appendFormat:@"    LDA $%04X\n", 0x4058 + b];
        if (b == 7) [o appendString:@"    EOR #$80\n"];
        [o appendFormat:@"    STA $%04X\n", 0x4050 + b];
    }
    [o appendFormat:@".Lfu%lu_k:\n", l];
    [self mechResult:insn slot:2 bytes:8 ctx:ctx];
    [self mechUnmap:ctx];
}

#pragma mark - Block labels

+ (NSString *)blockLabelForFn:(XTIRFunction *)fn block:(XTIRBlock *)block {
    return [NSString stringWithFormat:@"_%@__%@", fn.name, block.name ?: @"bb_?"];
}

#pragma mark - Phi-edge copies

+ (void)emitPhiCopiesFrom:(XTIRBlock *)predBlock
                       to:(XTIRBlock *)successor
                      ctx:(XT6502FnCtx *)ctx
{
    // Collect this edge's copies (each phi's dest <- its operand for predBlock).
    NSMutableArray<XTIRValue *> *dests = [NSMutableArray array];
    NSMutableArray<XTIROperand *> *srcs = [NSMutableArray array];
    for (XTIRInsn *phi in successor.phiNodes) {
        if (phi.opcode != XTIROpPhi || !phi.result) continue;
        for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2) {
            XTIROperand *bop = phi.operands[i];
            if (bop.kind == XTIROperandKindBlock && bop.blockRef == predBlock) {
                [dests addObject:phi.result]; [srcs addObject:phi.operands[i + 1]]; break;
            }
        }
    }
    NSUInteger n = dests.count;
    if (n == 0) return;
    // Phi copies are a PARALLEL (simultaneous) assignment: a loop's `v <- c`
    // and `c <- c+1` must both read the OLD c. A naive in-order sequential copy
    // clobbers it (off-by-one). Emit in dependency order — a copy whose dest is
    // not read by any pending copy is safe to do now; a residual cycle is broken
    // by stashing one dest into ZP scratch ($B0+, free at a branch) and reading
    // it there. (No hardware stack: SP-relative slots would shift under it.)
    NSMutableIndexSet *pending = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, n)];
    NSMutableDictionary<NSNumber *, NSNumber *> *redir = [NSMutableDictionary dictionary];
    int scratch = 0xB0;
    while (pending.count) {
        NSInteger pick = -1;
        for (NSUInteger idx = pending.firstIndex; idx != NSNotFound; idx = [pending indexGreaterThanIndex:idx]) {
            XTIRValueId did = dests[idx].valueId; BOOL blocked = NO;
            for (NSUInteger o = pending.firstIndex; o != NSNotFound; o = [pending indexGreaterThanIndex:o]) {
                if (o == idx) continue;
                if (srcs[o].kind == XTIROperandKindUse && srcs[o].valueId == did) { blocked = YES; break; }
            }
            if (!blocked) { pick = (NSInteger)idx; break; }
        }
        if (pick < 0) {                            // cycle: stash one dest, redirect reads
            NSUInteger idx = pending.firstIndex; XTIRValue *d = dests[idx];
            NSUInteger w = [self byteWidthForType:d.type];
            for (NSUInteger b = 0; b < w; b++) {
                NSString *op = [self operandForValueId:d.valueId byteIndex:b ctx:ctx];
                if (op) [ctx.out appendFormat:@"    LDA %@\n    STA $%02X\n", op, scratch + (int)b];
            }
            redir[@(d.valueId)] = @(scratch); scratch += (int)w; pick = (NSInteger)idx;
        }
        NSUInteger idx = (NSUInteger)pick;
        XTIRValue *d = dests[idx]; XTIROperand *s = srcs[idx];
        NSUInteger w = [self byteWidthForType:d.type];
        for (NSUInteger b = 0; b < w; b++) {
            NSNumber *rs = (s.kind == XTIROperandKindUse) ? redir[@(s.valueId)] : nil;
            if (rs) [ctx.out appendFormat:@"    LDA $%02X\n", rs.intValue + (int)b];
            else    [self loadOperandByte:s byteIndex:b ctx:ctx];
            [self storeAToValueId:d.valueId byteIndex:b ctx:ctx];
        }
        [pending removeIndex:idx];
    }
}

#pragma mark - Per-opcode emission

+ (BOOL)emitInsn:(XTIRInsn *)insn
        inBlock:(XTIRBlock *)block
            ctx:(XT6502FnCtx *)ctx
    diagnostics:(XTDiagnosticEngine *)diag
{
    switch (insn.opcode) {

        // ── Const ─────────────────────────────────────────────────
        case XTIROpConst: {
            if (insn.operands.count < 1 || !insn.result) break;
            // Float Const: the IR carries the abstract value as raw
            // IEEE-754 double bits (immF). Encode it into the xtc
            // byte format HERE (the backend owns the layout) and
            // splat the bytes into the result slot.
            if (XTIRTypeKindIsFloating(insn.result.type.kind)) {
                XTIROperand *op = insn.operands[0];
                NSUInteger fw = [self byteWidthForType:insn.result.type];
                NSData *enc = [self encodeFloatBits:op.floatRawBytes width:fw];
                const uint8_t *eb = enc.bytes;
                for (NSUInteger b = 0; b < enc.length; b++) {
                    [ctx.out appendFormat:@"    LDA #$%02X\n", eb[b]];
                    [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
                }
                break;
            }
            NSUInteger width = [self byteWidthForType:insn.result.type];
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Add / Sub (multi-byte, little-endian) ────────────────
        case XTIROpAdd:
        case XTIROpSub: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            [ctx.out appendString:(insn.opcode == XTIROpAdd ? @"    CLC\n" : @"    SEC\n")];
            NSString *opMnem = (insn.opcode == XTIROpAdd) ? @"ADC" : @"SBC";
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                XTIROperand *r = insn.operands[1];
                if (r.kind == XTIROperandKindUse) {
                    // ADC/SBC both have a d,SP form, so the operand swaps
                    // mechanically for an SP-frame RHS.
                    NSString *operand = [self operandForValueId:r.valueId byteIndex:b ctx:ctx];
                    [ctx.out appendFormat:@"    %@ %@\n", opMnem, operand];
                } else if (r.kind == XTIROperandKindImmI) {
                    int64_t v = r.intValue;
                    uint8_t bv = (uint8_t)((v >> (8 * b)) & 0xFF);
                    [ctx.out appendFormat:@"    %@ #$%02X\n", opMnem, bv];
                }
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Bitwise And / Or / Xor (multi-byte) ──────────────────
        case XTIROpAnd:
        case XTIROpOr:
        case XTIROpXor: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            NSString *opMnem = (insn.opcode == XTIROpAnd) ? @"AND"
                              : (insn.opcode == XTIROpOr) ? @"ORA"
                              : @"EOR";
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                XTIROperand *r = insn.operands[1];
                if (r.kind == XTIROperandKindUse) {
                    if ([self valueOnSPFrame:r.valueId ctx:ctx]) {
                        // AND/ORA/EOR have no d,SP form. Stage the RHS byte
                        // through $BF via LDX/STX (preserves A = the LHS),
                        // then combine from $BF.
                        NSString *src = [self operandForValueId:r.valueId byteIndex:b ctx:ctx];
                        [ctx.out appendFormat:@"    LDX %@\n", src];
                        [ctx.out appendString:@"    STX $BF\n"];
                        [ctx.out appendFormat:@"    %@ $BF\n", opMnem];
                    } else {
                        NSInteger rb = [self slotForValueId:r.valueId ctx:ctx];
                        [ctx.out appendFormat:@"    %@ $%02lX\n", opMnem, (unsigned long)(rb + b)];
                    }
                } else if (r.kind == XTIROperandKindImmI) {
                    int64_t v = r.intValue;
                    uint8_t bv = (uint8_t)((v >> (8 * b)) & 0xFF);
                    [ctx.out appendFormat:@"    %@ #$%02X\n", opMnem, bv];
                }
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Not (per-byte EOR #$FF) ───────────────────────────────
        case XTIROpNot: {
            if (insn.operands.count < 1 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendString:@"    EOR #$FF\n"];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Neg (two's complement: invert + add 1) ────────────────
        case XTIROpNeg: {
            if (insn.operands.count < 1 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            // ~x + 1 — done byte-wise with carry.
            [ctx.out appendString:@"    CLC\n"];
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendString:@"    EOR #$FF\n"];
                if (b == 0) {
                    [ctx.out appendString:@"    ADC #$01\n"];
                } else {
                    [ctx.out appendString:@"    ADC #$00\n"];
                }
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Mul / SDiv / UDiv / SRem / URem via runtime helpers ───
        //
        // The 6502 has no native multiply or divide. Runtime
        // routines live under support/xt6502/asm/{u,i}{8,16,32}/
        // (the 6502-arch runtime tree) and take their operands in
        // the $B0-$BF ZP block:
        //   8-bit  : $B0 = a, $B1 = b, result at $B0
        //   16-bit : $B0,$B1 = a, $B2,$B3 = b, result at $B0,$B1
        //   32-bit : $B0..$B3 = a, $B4..$B7 = b, result at $B0..$B3
        //
        // After the JSR, the result block sits at $B0+(0..width-1);
        // copy it into the result slot byte-by-byte. Both the corpus
        // harness and the standard build link the real implementations
        // from the support/xt6502/asm/ tree.
        case XTIROpMul:
        case XTIROpSDiv:
        case XTIROpUDiv:
        case XTIROpSRem:
        case XTIROpURem: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            BOOL isSigned = XTIRTypeKindIsSigned(insn.result.type.kind);
            // Route 32-bit Mul/Div/Mod through the MECH math coprocessor: a
            // 6502 software 32-bit divide is ~2-3k cycles, far past MECH's flat
            // ~23us doorbell floor at every turbo tier, so it is always a win.
            // (MC_T_I32=2, MC_T_I64=3; MC_OP_MUL=0x03, DIV=0x04, REM=0x0B.)
            // MECH integer ops are signed, so unsigned Div/Mod widen to i64.
            if (width == 4) {
                unsigned mcType = 2, mcOp = 0x03; BOOL zx = NO;
                switch (insn.opcode) {
                    case XTIROpMul:  mcType = 2; mcOp = 0x03; break;
                    case XTIROpSDiv: mcType = 2; mcOp = 0x04; break;
                    case XTIROpUDiv: mcType = 3; mcOp = 0x04; zx = YES; break;
                    case XTIROpSRem: mcType = 2; mcOp = 0x0B; break;
                    case XTIROpURem: mcType = 3; mcOp = 0x0B; zx = YES; break;
                    default: break;
                }
                [self emitMechBinop:insn opWidth:4 mcType:mcType mcOp:mcOp
                          slotBytes:(zx ? 8 : 4) signExtend:NO resultBytes:4 ctx:ctx];
                break;
            }
            NSString *opName;
            switch (insn.opcode) {
                case XTIROpMul:  opName = @"Mul"; break;
                case XTIROpSDiv:
                case XTIROpUDiv: opName = @"Div"; break;
                case XTIROpSRem:
                case XTIROpURem: opName = @"Mod"; break;
                default:         opName = @"?"; break;
            }
            NSString *widthTag;
            switch (width) {
                case 1: widthTag = isSigned ? @"i8"  : @"u8";  break;
                case 2: widthTag = isSigned ? @"i16" : @"u16"; break;
                case 4: widthTag = isSigned ? @"i32" : @"u32"; break;
                case 8: widthTag = isSigned ? @"i64" : @"u64"; break;
                default:
                    if (diag) [diag emitError:[NSString stringWithFormat:
                        @"xt6502: %@ at width %lu not yet supported",
                        opName, (unsigned long)width] at:synthLoc()];
                    return NO;
            }
            // Stage operand A into $B0..$B<width-1>.
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            // Stage operand B into $B<width>..$B<2*width-1>.
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[1] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n",
                 0xB0 + (unsigned)(width + b)];
            }
            [ctx.out appendFormat:@"    JSR _%@%@\n", widthTag, opName];
            // Harvest the result from $B0..$B<width-1>.
            for (NSUInteger b = 0; b < width; b++) {
                [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Shl / LShr / AShr via runtime helpers or inline ──────
        //
        // For a constant shift count of 1..N we could inline ASL/LSR
        // chains; for now route through the runtime helper to keep
        // the codegen simple. Operand convention matches Mul/Div:
        //   value in $B0..$B<width-1>, count in $B<width>, result
        //   back at $B0..
        case XTIROpShl:
        case XTIROpLShr:
        case XTIROpAShr:
        case XTIROpRol:
        case XTIROpRor: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            NSString *opName;
            switch (insn.opcode) {
                case XTIROpShl:  opName = @"Shl"; break;
                case XTIROpLShr: opName = @"LShr"; break;
                case XTIROpAShr: opName = @"AShr"; break;
                case XTIROpRol:  opName = @"Rol"; break;
                case XTIROpRor:  opName = @"Ror"; break;
                default:         opName = @"?"; break;
            }
            NSString *widthTag;
            switch (width) {
                case 1: widthTag = @"u8";  break;
                case 2: widthTag = @"u16"; break;
                case 4: widthTag = @"u32"; break;
                case 8: widthTag = @"u64"; break;
                default:
                    if (diag) [diag emitError:[NSString stringWithFormat:
                        @"xt6502: %@ at width %lu not yet supported",
                        opName, (unsigned long)width] at:synthLoc()];
                    return NO;
            }
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            // Shift count is always U8.
            [self loadOperandByte:insn.operands[1] byteIndex:0 ctx:ctx];
            [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)width];
            [ctx.out appendFormat:@"    JSR _%@%@\n", widthTag, opName];
            for (NSUInteger b = 0; b < width; b++) {
                [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── ZExt / SExt / Trunc / Bitcast ─────────────────────────
        case XTIROpZExt: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIROperand *src = insn.operands[0];
            XTIRValue *srcVal = (src.kind == XTIROperandKindUse)
                ? [ctx.fn valueForId:src.valueId] : nil;
            NSUInteger srcW = srcVal ? [self byteWidthForType:srcVal.type] : 1;
            NSUInteger dstW = [self byteWidthForType:insn.result.type];
            // Copy src bytes through, zero-fill the high bytes.
            for (NSUInteger b = 0; b < dstW; b++) {
                if (b < srcW) {
                    [self loadOperandByte:src byteIndex:b ctx:ctx];
                } else {
                    [ctx.out appendString:@"    LDA #$00\n"];
                }
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }
        case XTIROpSExt: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIROperand *src = insn.operands[0];
            XTIRValue *srcVal = (src.kind == XTIROperandKindUse)
                ? [ctx.fn valueForId:src.valueId] : nil;
            NSUInteger srcW = srcVal ? [self byteWidthForType:srcVal.type] : 1;
            NSUInteger dstW = [self byteWidthForType:insn.result.type];

            // Copy src bytes into the low bytes of the dst slot.
            for (NSUInteger b = 0; b < srcW; b++) {
                [self loadOperandByte:src byteIndex:b ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }

            // For the high bytes we need either $00 or $FF replicated,
            // based on the sign bit of the source's MSB. Use BIT
            // <msb-slot> so the N flag is derived from memory IMMEDIATELY
            // before BPL — independent of any A/X/Y/LDX side-effects
            // from surrounding code. Relying on "no clobbering between
            // LDA and BMI" via instruction adjacency is fragile to
            // future codegen changes; BIT makes the dependency explicit.
            if (dstW > srcW && src.kind == XTIROperandKindUse) {
                NSUInteger labelN = ctx.labelCounter++;
                if ([self valueOnSPFrame:src.valueId ctx:ctx]) {
                    // BIT has no d,SP form — stage the MSB through $BF.
                    NSString *msb = [self operandForValueId:src.valueId byteIndex:srcW - 1 ctx:ctx];
                    [ctx.out appendFormat:@"    LDA %@\n", msb];
                    [ctx.out appendString:@"    STA $BF\n"];
                    [ctx.out appendString:@"    LDA #$00\n"];
                    [ctx.out appendString:@"    BIT $BF\n"];
                } else {
                    NSInteger srcBase = [self slotForValueId:src.valueId ctx:ctx];
                    [ctx.out appendString:@"    LDA #$00\n"];
                    [ctx.out appendFormat:@"    BIT $%02lX\n",
                     (unsigned long)(srcBase + srcW - 1)];
                }
                [ctx.out appendFormat:@"    BPL .Lse%lu_done\n", (unsigned long)labelN];
                [ctx.out appendString:@"    LDA #$FF\n"];
                [ctx.out appendFormat:@".Lse%lu_done:\n", (unsigned long)labelN];
                for (NSUInteger b = srcW; b < dstW; b++) {
                    [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
                }
            } else if (dstW > srcW && src.kind == XTIROperandKindImmI) {
                // Constant source: compute the sign-extended high bytes
                // at codegen time. No runtime flag dependency.
                int64_t v = src.intValue;
                BOOL negative = (v & (1LL << (8 * srcW - 1))) != 0;
                uint8_t fill = negative ? 0xFF : 0x00;
                [ctx.out appendFormat:@"    LDA #$%02X\n", fill];
                for (NSUInteger b = srcW; b < dstW; b++) {
                    [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
                }
            }
            break;
        }
        case XTIROpTrunc:
        case XTIROpBitcast: {
            if (insn.operands.count < 1 || !insn.result) break;
            // Bitcast may widen or narrow — determine the source width
            // so bytes beyond it are zero-extended; without this check
            // loadOperandByte reads adjacent stack slots (other live
            // values) for byte indices ≥ srcW (same pattern as IntToPtr).
            NSUInteger dstW = [self byteWidthForType:insn.result.type];
            XTIROperand *srcOp = insn.operands[0];
            NSUInteger srcW = dstW; // fallback: copy all bytes
            if (srcOp.kind == XTIROperandKindUse) {
                XTIRValue *srcVal = [ctx.fn valueForId:srcOp.valueId];
                if (srcVal) srcW = [self byteWidthForType:srcVal.type];
            } else if (srcOp.kind == XTIROperandKindImmI && srcOp.type) {
                srcW = [self byteWidthForType:srcOp.type];
            }
            // When widening a 2-byte pointer to a 3-byte banked pointer,
            // the bank-lo byte should be the heap's implicit bank
            // (heap_bank_first, always 1 on xt) rather than zero, so
            // that subsequent loads/stores through the widened pointer
            // reach the correct data page.  With 3-byte uniform pointers
            // there is no bank-hi byte.  This mirrors the Map/Set/Array
            // inline-asm convention where `LDY #heap_bank_first` supplies
            // the bank for pointer values read from 2-byte storage slots.
            BOOL wideningToBankedPtr = (dstW > srcW && dstW > 2);
            for (NSUInteger b = 0; b < dstW; b++) {
                if (b < srcW) {
                    [self loadOperandByte:srcOp byteIndex:b ctx:ctx];
                } else if (wideningToBankedPtr && b == 2) {
                    // bank-lo: use heap's implicit bank constant.
                    [ctx.out appendString:@"    LDA #heap_bank_first\n"];
                } else {
                    [ctx.out appendString:@"    LDA #$00\n"];
                }
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        case XTIROpSelect: {
            // `result = cond ? trueVal : falseVal` per IR-SPEC §6.
            // Operand layout: [cond, trueVal, falseVal]. Both branches
            // are value sources — no new IR block is introduced. Emit
            // as `LDA cond ; BEQ .Lf ; copy trueVal bytes ; JMP .Le ;
            // .Lf: copy falseVal bytes ; .Le:`. Per-byte copy is
            // width-driven by the result type so 3-byte pointers (the
            // common case for the printf `%e` enum-name lookup chain)
            // copy all three bytes including the bank. Placed AFTER
            // the Trunc+Bitcast fall-through so an accidental
            // fall-through never lands in this block (previous layout
            // had this case mid-fall-through and broke Trunc).
            if (insn.operands.count < 3 || !insn.result) break;
            NSUInteger width = [self byteWidthForType:insn.result.type];
            if (width == 0) width = 1;
            [self loadCondTest:insn.operands[0] ctx:ctx];
            NSUInteger lbl = ctx.labelCounter++;
            [ctx.out appendFormat:@"    BEQ .Lselfalse_%lu\n",
                 (unsigned long)lbl];
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[1] byteIndex:b ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            [ctx.out appendFormat:@"    JMP .Lselend_%lu\n",
                 (unsigned long)lbl];
            [ctx.out appendFormat:@".Lselfalse_%lu:\n",
                 (unsigned long)lbl];
            for (NSUInteger b = 0; b < width; b++) {
                [self loadOperandByte:insn.operands[2] byteIndex:b ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            [ctx.out appendFormat:@".Lselend_%lu:\n", (unsigned long)lbl];
            break;
        }

        // ── ICmp ──────────────────────────────────────────────────
        // Unsigned predicates compare byte-wise high→low. Signed
        // predicates (SLT/SGT/SLE/SGE) reuse the unsigned machinery
        // via the sign-flip identity: signed a<b ⟺ (a^$80…) < (b^$80…)
        // unsigned. Only the most-significant byte's sign bit needs
        // flipping; lower bytes stay unsigned. We then derive the
        // result with the matching unsigned predicate (SLT→ULT, etc).
        case XTIROpICmp: {
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *a = insn.operands[0];
            XTIRValue *aVal = (a.kind == XTIROperandKindUse) ? [ctx.fn valueForId:a.valueId] : nil;
            NSUInteger w = aVal ? [self byteWidthForType:aVal.type] : 1;

            uint8_t effPred = insn.predicate;
            BOOL signedCmp = NO;
            switch (insn.predicate) {
                case XTIRICmpSLT: effPred = XTIRICmpULT; signedCmp = YES; break;
                case XTIRICmpSGT: effPred = XTIRICmpUGT; signedCmp = YES; break;
                case XTIRICmpSLE: effPred = XTIRICmpULE; signedCmp = YES; break;
                case XTIRICmpSGE: effPred = XTIRICmpUGE; signedCmp = YES; break;
                default: break;
            }

            // Multi-byte compare: from high byte to low. Falls
            // through to low-byte CMP if the high bytes are equal.
            // After the final CMP, C = (a >= b) unsigned, Z = (a == b).
            NSUInteger label = ctx.labelCounter++;
            for (NSInteger b = (NSInteger)w - 1; b >= 0; b--) {
                BOOL highByte = (b == (NSInteger)w - 1);
                XTIROperand *r = insn.operands[1];
                if (signedCmp && highByte) {
                    // Sign-flip both high bytes so the unsigned CMP
                    // yields the signed ordering. $BF is free here
                    // (only Mul/float helpers touch $B0-$BF).
                    if (r.kind == XTIROperandKindUse) {
                        NSString *rop = [self operandForValueId:r.valueId byteIndex:(NSUInteger)b ctx:ctx];
                        [ctx.out appendFormat:@"    LDA %@\n", rop];
                        [ctx.out appendString:@"    EOR #$80\n"];
                        [ctx.out appendString:@"    STA $BF\n"];
                        [self loadOperandByte:insn.operands[0] byteIndex:(NSUInteger)b ctx:ctx];
                        [ctx.out appendString:@"    EOR #$80\n"];
                        [ctx.out appendString:@"    CMP $BF\n"];
                    } else if (r.kind == XTIROperandKindImmI) {
                        int64_t v = r.intValue;
                        uint8_t bv = (uint8_t)((v >> (8 * b)) & 0xFF) ^ 0x80;
                        [self loadOperandByte:insn.operands[0] byteIndex:(NSUInteger)b ctx:ctx];
                        [ctx.out appendString:@"    EOR #$80\n"];
                        [ctx.out appendFormat:@"    CMP #$%02X\n", bv];
                    }
                } else {
                    [self loadOperandByte:insn.operands[0] byteIndex:(NSUInteger)b ctx:ctx];
                    if (r.kind == XTIROperandKindUse) {
                        NSString *rop = [self operandForValueId:r.valueId byteIndex:(NSUInteger)b ctx:ctx];
                        [ctx.out appendFormat:@"    CMP %@\n", rop];
                    } else if (r.kind == XTIROperandKindImmI) {
                        int64_t v = r.intValue;
                        uint8_t bv = (uint8_t)((v >> (8 * b)) & 0xFF);
                        [ctx.out appendFormat:@"    CMP #$%02X\n", bv];
                    }
                }
                if (b > 0) {
                    [ctx.out appendFormat:@"    BNE .Licmp%lu_done\n", (unsigned long)label];
                }
            }
            [ctx.out appendFormat:@".Licmp%lu_done:\n", (unsigned long)label];

            // Now derive the Bool result from C and Z.
            //   EQ : Z=1 → 1
            //   NE : Z=0 → 1
            //   ULT: C=0 → 1
            //   UGT: C=1 AND Z=0 → 1
            //   ULE: C=0 OR  Z=1 → 1
            //   UGE: C=1 → 1
            // Derive the Bool result from C and Z.
            // Single-branch predicates: EQ, NE, ULT, UGE — yes when
            // exactly one flag matches.
            // Two-condition predicates: UGT (C=1 AND Z=0), ULE (C=0
            // OR Z=1) — encoded as "start assumed yes, two early-
            // outs to clear, fall through" so the predicate is
            // exact.
            NSUInteger setLbl = ctx.labelCounter++;
            NSString *yesBranch = nil;
            switch (effPred) {
                case XTIRICmpEQ:  yesBranch = @"BEQ"; break;
                case XTIRICmpNE:  yesBranch = @"BNE"; break;
                case XTIRICmpULT: yesBranch = @"BCC"; break;
                case XTIRICmpUGE: yesBranch = @"BCS"; break;
                default: break;
            }
            if (yesBranch) {
                // Branch on the LIVE compare flags BEFORE touching A.
                // `LDA #$00` clears Z, which is fatal for the Z-testing
                // BEQ/BNE (it would make the predicate always/never
                // true). The C-testing BCC/BCS were unaffected — LDA
                // leaves carry alone — which is why ULT/UGE worked but
                // EQ/NE silently always returned true.
                [ctx.out appendFormat:@"    %@ .Licmp%lu_set\n",
                 yesBranch, (unsigned long)setLbl];
                [ctx.out appendFormat:@"    LDA #$00\n"];
                [ctx.out appendFormat:@"    BRA .Licmp%lu_store\n",
                 (unsigned long)setLbl];
                [ctx.out appendFormat:@".Licmp%lu_set:\n",
                 (unsigned long)setLbl];
                [ctx.out appendFormat:@"    LDA #$01\n"];
                [ctx.out appendFormat:@".Licmp%lu_store:\n",
                 (unsigned long)setLbl];
                [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            } else if (effPred == XTIRICmpUGT
                       || effPred == XTIRICmpULE)
            {
                // UGT: yes iff C=1 AND Z=0. Start with A=1 (yes);
                // BCC (a < b) clears to 0; BEQ (a == b) also clears.
                // Fall through with A=1 if both pass.
                // ULE: inverse — yes iff C=0 OR Z=1. Start with
                // A=0; BCC sets to 1; BEQ sets to 1.
                // Branch on the LIVE flags first; 6502 branches don't
                // touch flags, so Z survives the BCC for the following
                // BEQ. Loading A before the branches (as the old code
                // did) cleared Z and broke the a==b (BEQ) case — UGT
                // mis-handled equality and ULE was always true.
                BOOL isUGT = (effPred == XTIRICmpUGT);
                NSString *fallThrough = isUGT ? @"$01" : @"$00";
                NSString *flip        = isUGT ? @"$00" : @"$01";
                // BCC (carry clear → a < b) flips for ULE, holds for UGT.
                [ctx.out appendFormat:@"    BCC .Licmp%lu_flip\n",
                 (unsigned long)setLbl];
                // BEQ (zero set → a == b) flips for both.
                [ctx.out appendFormat:@"    BEQ .Licmp%lu_flip\n",
                 (unsigned long)setLbl];
                // Neither early-out: UGT → 1 (a > b), ULE → 0 (a > b).
                [ctx.out appendFormat:@"    LDA #%@\n", fallThrough];
                [ctx.out appendFormat:@"    BRA .Licmp%lu_store\n",
                 (unsigned long)setLbl];
                [ctx.out appendFormat:@".Licmp%lu_flip:\n",
                 (unsigned long)setLbl];
                // a < b OR a == b: UGT → 0 (not greater), ULE → 1.
                [ctx.out appendFormat:@"    LDA #%@\n", flip];
                [ctx.out appendFormat:@".Licmp%lu_store:\n",
                 (unsigned long)setLbl];
                [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            } else {
                if (diag) {
                    [diag emitError:[NSString stringWithFormat:
                        @"xt6502: ICmp predicate %u not yet supported",
                        (unsigned)insn.predicate] at:synthLoc()];
                }
                return NO;
            }
            break;
        }

        // ── Phi: emitted as predecessor-edge copies, not at the
        //         phi location itself.
        case XTIROpPhi:
            break;

        // ── Call (CallConv::Standard / CallBanked / CallCloaked) ────
        case XTIROpCall:
        case XTIROpCallBanked:
        case XTIROpCallCloaked: {
            if (insn.operands.count < 2) break;
            XTIROperand *callee = insn.operands[0];
            if (callee.kind != XTIROperandKindSym) break;
            XTIRSymbol *sym = [ctx.module symbolForId:callee.symbolId];
            if (!sym) break;

            // Caller-save (task #64): push the ZP slots live across this
            // call below the args so the callee — which reuses the same
            // ZP pool — can't clobber them. Only live-across values are
            // saved (liveness, computed once per function), so call-heavy
            // functions don't bloat past the code budget.
            [self emitCallerSaveFor:insn ctx:ctx];

            // Args = operands[1..count-2]. Push right-to-left, high
            // byte first within each multi-byte arg. (STACK-ABI.md
            // §9 Q2 resolution: little-endian on stack.)
            NSUInteger argCount = insn.operands.count >= 2 ? insn.operands.count - 2 : 0;
            NSUInteger pushedBytes = 0;
            for (NSInteger i = (NSInteger)argCount - 1; i >= 0; i--) {
                XTIROperand *a = insn.operands[(NSUInteger)i + 1];
                NSUInteger argW = 1;
                if (a.kind == XTIROperandKindUse) {
                    XTIRValue *av = [ctx.fn valueForId:a.valueId];
                    if (av) argW = [self byteWidthForType:av.type];
                } else if (a.kind == XTIROperandKindImmI && a.type) {
                    argW = [self byteWidthForType:a.type];
                }
                // Push each byte of the argument from hi to lo. PHA
                // decrements SP (hidden stack pointer), so spDelta must
                // accumulate across bytes — the same relative offset
                // (+N,SP) accesses the next byte down as SP shrinks,
                // because the formula `off = base + bi + spDelta` keeps
                // each load targeting the correct absolute frame slot.
                // (The old reset-before-load pattern was wrong for the
                // xt hidden stack — spDelta must accumulate so that
                // the SP-relative offset grows by 1 for each PHA.)
                {
                    for (NSInteger b = (NSInteger)argW - 1; b >= 0; b--) {
                        [self loadOperandByte:a byteIndex:(NSUInteger)b ctx:ctx];
                        [self emitPHA:ctx];
                        pushedBytes++;
                    }
                }
            }
            // Cross-bank dispatch (task #60). When banking is active and
            // the callee lives in a different code bank than the caller,
            // route through the unbanked `_xcall` trampoline: stage the
            // callee address into `_xcall_vec` and its bank id into
            // `_xc_bank`, then `JSR _xcall`. The trampoline (provided by
            // the startup/harness, unbanked) saves __bank_code_reg, selects
            // the callee's bank, calls it, and restores __bank_code_reg
            // before returning — so the switch never swaps the code page
            // out from under
            // the fetcher (which would derail a banked caller). A callee
            // that is unbanked or in the caller's own bank stays a plain
            // `JSR` (no bank switch needed). Args are already on the
            // hardware stack and survive the switch unchanged.
            NSUInteger calleeBank = [self bankForCalleeName:sym.name ctx:ctx];
            if (ctx.bankingActive && calleeBank != 0
                && calleeBank != ctx.currentBank) {
                [ctx.out appendFormat:@"    LDA #<_%@\n", sym.name];
                [ctx.out appendString:@"    STA _xcall_vec\n"];
                [ctx.out appendFormat:@"    LDA #>_%@\n", sym.name];
                [ctx.out appendString:@"    STA _xcall_vec+1\n"];
                [ctx.out appendFormat:@"    LDA #$%02lX\n",
                 (unsigned long)calleeBank];
                [ctx.out appendString:@"    STA _xc_bank\n"];
                [ctx.out appendString:@"    JSR _xcall\n"];
            } else {
                [ctx.out appendFormat:@"    JSR _%@\n", sym.name];
            }
            // Stash return value per the Return op's convention BEFORE
            // popping args, because ADD SP (xa65 built-in macro) clobbers
            // A and X (it expands to TSX/TXA/CLC/ADC #N/TAX/TXS).
            // Harvesting first keeps byte0 (A) and byte1 (X) intact.
            //   byte 0 → A
            //   byte 1 → X
            //   byte 2 → Y
            if (insn.result) {
                NSUInteger rW = [self byteWidthForType:insn.result.type];
                // Float / double AND by-value aggregate (struct) returns
                // ride the $B0-$B(w-1) mailbox — the callee left the value
                // there (see the Return op); harvest into the result slot.
                // The $B0-$BF window holds up to 16 bytes; a wider struct
                // would need a hidden return-buffer pointer (not yet wired).
                // A 64-bit scalar rides it too: A/X/Y plus $89 carry four
                // bytes and no more, and the mailbox already moves eight for a
                // double. Without this an i64 return compiled at -O3 (the call
                // was inlined away) and failed at -O0, which is the wrong way
                // round for a thing to be discovered.
                BOOL viaMailbox = XTIRTypeKindIsFloating(insn.result.type.kind)
                               || insn.result.type.kind == XTIRTypeKindAgg
                               || rW > 4;
                if (viaMailbox) {
                    if (rW > 16) {
                        if (diag) [diag emitError:[NSString stringWithFormat:
                            @"xt6502: struct return wider than 16 bytes not yet supported (%lu)",
                            (unsigned long)rW] at:synthLoc()];
                        return NO;
                    }
                    for (NSUInteger b = 0; b < rW; b++) {
                        [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                        [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
                    }
                } else {
                    if (rW > 4) {
                        if (diag) [diag emitError:[NSString stringWithFormat:
                            @"xt6502: returns wider than 32 bits not yet supported (%lu)",
                            (unsigned long)rW] at:synthLoc()];
                        return NO;
                    }
                    if (rW >= 1) [self storeAToValueId:insn.result.valueId
                                              byteIndex:0 ctx:ctx];
                    if (rW >= 2) {
                        [ctx.out appendString:@"    TXA\n"];
                        [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                    }
                    if (rW >= 3) {
                        [ctx.out appendString:@"    TYA\n"];
                        [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
                    }
                    // rW >= 4 (u32 return): byte 3 still uses $89 — only
                    // pointer returns are 3-byte now.
                    if (rW >= 4) {
                        [ctx.out appendString:@"    LDA $89\n"];
                        [self storeAToValueId:insn.result.valueId byteIndex:3 ctx:ctx];
                    }
                }
            }
            // Caller cleanup: ADD SP, #pushedBytes (after harvesting the
            // return value — ADD SP clobbers A and X).
            NSUInteger remaining = pushedBytes;
            while (remaining > 0) {
                NSUInteger chunk = remaining > 127 ? 127 : remaining;
                [self emitAddSP:chunk ctx:ctx];
                remaining -= chunk;
            }
            // Caller-restore: pop the saved ZP slots (task #64). The
            // result is excluded from the save set, so its just-harvested
            // slot is untouched.
            [self emitCallerRestoreFor:insn ctx:ctx];
            break;
        }

        // ── Branch / CondBranch ───────────────────────────────────
        // Inter-block unconditional branches use `JMP <label>`
        // rather than `BRA <label>`. BRA is signed-8-bit (±127
        // bytes) on the xt CPU and Stdio's init blocks
        // routinely sit > 130 bytes apart, which is the cause of
        // the "xcc-as: branch out of range" failures the dual-backend
        // sweep surfaces. JMP is 3 bytes + unconditional, no
        // range limit; the size hit is negligible.
        case XTIROpBranch: {
            if (insn.operands.count < 1) break;
            XTIROperand *t = insn.operands[0];
            if (t.kind != XTIROperandKindBlock) break;
            [self emitPhiCopiesFrom:block to:t.blockRef ctx:ctx];
            [ctx.out appendFormat:@"    JMP %@\n", [self blockLabelForFn:ctx.fn block:t.blockRef]];
            break;
        }
        case XTIROpCondBranch: {
            if (insn.operands.count < 3) break;
            XTIROperand *cond = insn.operands[0];
            XTIROperand *t = insn.operands[1];
            XTIROperand *f = insn.operands[2];
            // Load cond byte.
            [self loadOperandByte:cond byteIndex:0 ctx:ctx];
            // Phi copies for both successors run *before* the
            // physical branch. (Since both successors are reachable,
            // we have to do the copies before we know which way the
            // jump goes — and our simple regalloc never aliases a
            // phi-source slot with a phi-result slot, so the copies
            // don't conflict.)
            [self emitPhiCopiesFrom:block to:t.blockRef ctx:ctx];
            [self emitPhiCopiesFrom:block to:f.blockRef ctx:ctx];
            // Re-load cond after the copies (might have been
            // clobbered by intermediate LDA/STA).
            [self loadCondTest:cond ctx:ctx];
            // BEQ <skip-true> ; JMP <true> ; skip-true: ; JMP <false>
            // The BEQ has the same ±127 range limit as BRA, but
            // it now spans only the JMP-true (3 bytes), which is
            // always in range. The JMPs handle the long-distance
            // unconditional cases.
            NSUInteger lbl = ctx.labelCounter++;
            [ctx.out appendFormat:@"    BEQ .Lcbsk_%lu\n", (unsigned long)lbl];
            [ctx.out appendFormat:@"    JMP %@\n",
             [self blockLabelForFn:ctx.fn block:t.blockRef]];
            [ctx.out appendFormat:@".Lcbsk_%lu:\n", (unsigned long)lbl];
            [ctx.out appendFormat:@"    JMP %@\n",
             [self blockLabelForFn:ctx.fn block:f.blockRef]];
            break;
        }

        // ── Return ────────────────────────────────────────────────
        case XTIROpReturn: {
            // The return value lives on the SP frame (params + temps now
            // ride it). PLL both restores the caller's A/X/Y *and*
            // deallocates the frame, so a frame-resident result can be
            // neither read after PLL (frame gone) nor held in a register
            // through it (clobbered). Stage it into the ZP $B0.. mailbox —
            // which PLL leaves untouched, and which is also the float
            // return register — BEFORE the PLL; afterwards move it into the
            // A/X/Y/$89 integer-return registers. An immediate needs no
            // staging.
            //
            // Convention: 1-byte A; 2-byte A=lo,X=hi; 3-byte A,X,Y
            //   (bank-lo in Y); 4-byte A=b0,X=b1,Y=b2,$89=b3; u32
            //   still uses $89 for byte 3; float/double → $B0.. mailbox.
            BOOL hasValue = insn.operands.count > 1;
            XTIROperand *v = hasValue ? insn.operands[0] : nil;
            XTIRValue *rvv = (v && v.kind == XTIROperandKindUse)
                ? [ctx.fn valueForId:v.valueId] : nil;
            NSUInteger rW = rvv ? [self byteWidthForType:rvv.type] : 1;
            BOOL isFloat = (rvv && XTIRTypeKindIsFloating(rvv.type.kind));
            // By-value aggregate (struct) returns ride the $B0.. mailbox
            // exactly like float/double: the staging loop below copies the
            // value there, and (unlike a scalar) we leave it there rather
            // than packing it into A/X/Y/$89. The caller's Call handler
            // harvests it from $B0... $B0-$BF holds up to 16 bytes.
            BOOL isAgg = (rvv && rvv.type.kind == XTIRTypeKindAgg);
            // A scalar wider than the A/X/Y/$89 quartet — i64/u64 — is left in
            // the $B0.. mailbox for the caller to harvest, the same contract
            // float, double and by-value structs already use.
            BOOL isWideScalar = (hasValue && !isFloat && !isAgg && rW > 4);
            if (hasValue && isAgg && rW > 16) {
                if (diag) [diag emitError:[NSString stringWithFormat:
                    @"xt6502: struct return wider than 16 bytes not yet supported (%lu)",
                    (unsigned long)rW] at:synthLoc()];
                return NO;
            }
            // Stage a slot-resident result into $B0.. before frame teardown
            // (spDelta is 0 at a terminator, so the operand is settled).
            if (hasValue && v.kind == XTIROperandKindUse) {
                for (NSUInteger b = 0; b < rW; b++) {
                    NSString *src = [self operandForValueId:v.valueId byteIndex:b ctx:ctx];
                    if (!src) break;
                    [ctx.out appendFormat:@"    LDA %@\n", src];
                    [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
                }
            }
            // PLL #N mirrors the prologue's PSH #N (SP += N+7, incl. the
            // guard byte); otherwise SP is left low and RTS returns to
            // garbage. N is the SP-frame size (STACK-ABI §11.2), shared
            // with the prologue via ctx. :irq / :vbi handlers skipped
            // the PSH (or used PHA-only register saves) — mirror with
            // the matching pops below instead of PLL.
            if (ctx.xtcStack) {
                [self emitXtcStackEpilogueForCtx:ctx];
            } else if (!ctx.isIrq && !ctx.isVbi) {
                [ctx.out appendFormat:@"    PLL #%lu\n",
                 (unsigned long)ctx.spFrameSize];
            }
            // Software-stack frame pop (STACK-ABI §11.3): SSP = FP (drop
            // this frame), FP = the caller FP saved at the frame base.
            // Clobbers A/X/Y but not $B0.., so the staged result survives.
            if (ctx.usesSoftStack && !ctx.xtcStack) {
                [ctx.out appendString:@"    ; --- software-stack frame pop (§11.3) ---\n"];
                [ctx.out appendString:@"    LDY #$00\n"];
                [ctx.out appendFormat:@"    LDA ($%02X),Y\n", kFPLo];   // caller FP lo
                [self emitPHA:ctx];
                [ctx.out appendString:@"    INY\n"];
                [ctx.out appendFormat:@"    LDA ($%02X),Y\n", kFPLo];   // caller FP hi
                [ctx.out appendString:@"    TAX\n"];
                [ctx.out appendFormat:@"    LDA $%02X\n", kFPLo];       // SSP = FP
                [ctx.out appendFormat:@"    STA $%02X\n", kSSPLo];
                [ctx.out appendFormat:@"    LDA $%02X\n", kFPHi];
                [ctx.out appendFormat:@"    STA $%02X\n", kSSPHi];
                [self emitPLA:ctx];                    // FP = caller FP
                [ctx.out appendFormat:@"    STA $%02X\n", kFPLo];
                [ctx.out appendFormat:@"    STX $%02X\n", kFPHi];
            }
            // Materialise the staged / immediate result into registers.
            if (hasValue) {
                if (isFloat || isAgg || isWideScalar) {
                    // Already in the $B0.. mailbox from the staging above.
                } else if (v.kind == XTIROperandKindUse) {
                    // Load $B3 into $89 BEFORE $B0 into A, because
                    // loading $B3 clobbers A (byte0).
                    if (rW >= 4) {
                        [ctx.out appendString:@"    LDA $B3\n"];
                        [ctx.out appendString:@"    STA $89\n"];
                    }
                    if (rW >= 3) [ctx.out appendString:@"    LDY $B2\n"];
                    if (rW >= 2) [ctx.out appendString:@"    LDX $B1\n"];
                    [ctx.out appendString:@"    LDA $B0\n"];
                } else if (v.kind == XTIROperandKindImmI) {
                    int64_t imm = v.intValue;
                    // Load byte 3 into $89 BEFORE byte 0 into A, because
                    // loading byte 3 into A clobbers byte 0.
                    if (rW >= 4) {
                        [ctx.out appendFormat:@"    LDA #$%02X\n",
                         (uint8_t)((imm >> 24) & 0xFF)];
                        [ctx.out appendString:@"    STA $89\n"];
                    }
                    if (rW >= 3) {
                        [ctx.out appendFormat:@"    LDY #$%02X\n",
                         (uint8_t)((imm >> 16) & 0xFF)];
                    }
                    if (rW >= 2) {
                        [ctx.out appendFormat:@"    LDX #$%02X\n",
                         (uint8_t)((imm >> 8) & 0xFF)];
                    }
                    [ctx.out appendFormat:@"    LDA #$%02X\n",
                     (uint8_t)(imm & 0xFF)];
                }
            }
            if (ctx.isIrq) {
                [ctx.out appendString:@"    RTI\n"];
            } else if (ctx.isVbi) {
                [ctx.out appendString:@"    PLA\n"];
                [ctx.out appendString:@"    TAY\n"];
                [ctx.out appendString:@"    PLA\n"];
                [ctx.out appendString:@"    TAX\n"];
                [ctx.out appendString:@"    PLA\n"];
                [ctx.out appendString:@"    JMP $E462\n"];   // XITVBV
            } else {
                [ctx.out appendString:@"    RTS\n"];
            }
            break;
        }
        case XTIROpUnreachable: {
            [ctx.out appendString:@"    BRK\n"];
            break;
        }

        // ── Memory primitives ─────────────────────────────────────
        //
        // Loads and stores go through (zp),Y indirect addressing —
        // the 6502 idiom for "follow a pointer". The pointer's
        // ZP slot pair *is* the indirection; Y selects the byte
        // offset within the pointed-at memory.
        case XTIROpLoad:
        case XTIROpLoadVolatile: {
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *ptrOp = insn.operands[0];
            if (ptrOp.kind != XTIROperandKindUse) break;
            // Fast path — the pointer is a compile-time-known absolute
            // global address (AddrOf @sym [+ const field/elem offset]).
            // AddrOf results are always flat bank-0 main-RAM pointers, so
            // a direct absolute load is exactly equivalent to the generic
            // set-bank-0 + (d,SP),Y windowed deref, minus the 3-byte
            // pointer build, the __bank_data_reg write and the indirect-Y.
            XT6502KnownAddr *lka = ctx.knownAddrs[@(ptrOp.valueId)];
            if (lka && lka.kind == XT6502KnownAddrKindAbsSym) {
                NSUInteger lw = [self byteWidthForType:insn.result.type];
                for (NSUInteger b = 0; b < lw; b++) {
                    [ctx.out appendFormat:@"    LDA %@\n",
                     [self absSymOperandForKnownAddr:lka byteIndex:b]];
                    [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
                }
                break;
            }
            // A stack-resident pointer is deref'd in place with (d,SP),Y
            // ($03); a ZP pointer uses (zp),Y. No push happens in this
            // loop, so the indirect base is stable across the bytes.
            NSString *ind = [self indirectBaseForValueId:ptrOp.valueId ctx:ctx];
            if (!ind) break;
            // Bank-select before dereffing through the $A000-$CFFF data
            // window. A 3-byte pointer carries its data bank in byte 2, so
            // set __bank_data_reg from it — for EVERY 3-byte pointer, not
            // just ones whose IR type still carries the XtCode/XtData
            // window. FieldAddr/ElementAddr into a banked object yields an
            // unbanked-typed pointer that nonetheless addresses the
            // $A000-$CFFF window (e.g. `&map._count`), so keying off the
            // window tag missed it and the read used whatever bank was
            // ambient — wrong once it drifted (private:docs/bugs/007). byte 2 == 0
            // for a genuinely main-RAM pointer, which selects the main-RAM
            // aperture, so this is always correct.
            XTIRValue *ptrVal = [ctx.fn valueForId:ptrOp.valueId];
            if (ctx.bankingActive && ptrVal.type.kind == XTIRTypeKindPtr
                && [self byteWidthForType:ptrVal.type] >= 3) {
                [self loadOperandByte:ptrOp byteIndex:2 ctx:ctx];
                [ctx.out appendString:@"    STA __bank_data_reg\n"];
            }
            NSUInteger w = [self byteWidthForType:insn.result.type];
            for (NSUInteger b = 0; b < w; b++) {
                if (b == 0) {
                    [ctx.out appendString:@"    LDY #$00\n"];
                } else {
                    [ctx.out appendString:@"    INY\n"];
                }
                [ctx.out appendFormat:@"    LDA %@,Y\n", ind];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }
        case XTIROpStore:
        case XTIROpStoreVolatile: {
            if (insn.operands.count < 3) break;
            XTIROperand *ptrOp = insn.operands[0];
            XTIROperand *valOp = insn.operands[1];
            if (ptrOp.kind != XTIROperandKindUse) break;
            // Fast path — store through a compile-time-known absolute
            // global address (AddrOf @sym [+ const offset]). Same
            // equivalence argument as the Load fast path above: AddrOf
            // results are flat bank-0 pointers, so direct absolute
            // addressing matches the generic windowed store exactly.
            XT6502KnownAddr *ska = ctx.knownAddrs[@(ptrOp.valueId)];
            if (ska && ska.kind == XT6502KnownAddrKindAbsSym) {
                NSUInteger sw = 1;
                if (valOp.kind == XTIROperandKindUse) {
                    XTIRValue *vv = [ctx.fn valueForId:valOp.valueId];
                    sw = [self byteWidthForType:vv.type];
                } else if (valOp.kind == XTIROperandKindImmI && valOp.type) {
                    sw = [self byteWidthForType:valOp.type];
                }
                for (NSUInteger b = 0; b < sw; b++) {
                    [self loadOperandByte:valOp byteIndex:b ctx:ctx];
                    [ctx.out appendFormat:@"    STA %@\n",
                     [self absSymOperandForKnownAddr:ska byteIndex:b]];
                }
                break;
            }
            // Stage 10a — the direct-addressing fast path was attempted
            // here but regressed 16 corpus fixtures (struct-/arc-heavy).
            // The analysis pass (computeKnownAddrsForCtx:) is harmless
            // on its own and stays in place so the Store/Load handlers
            // can be re-rolled-out incrementally with a tighter
            // safety envelope. Phase-223+ will wire it in carefully.
            (void)ctx.knownAddrs;
            NSString *ind = [self indirectBaseForValueId:ptrOp.valueId ctx:ctx];
            if (!ind) break;
            // Bank-select before writing through the $A000-$CFFF data
            // window — for EVERY 3-byte pointer, keyed off its byte-2 bank
            // selector rather than the IR window tag. FieldAddr/ElementAddr
            // into a banked object is unbanked-typed yet addresses the
            // window (e.g. `&map._count`), so the window-tag test missed it
            // and the store used the ambient bank — wrong once it drifted
            // (private:docs/bugs/007). byte 2 == 0 selects the main-RAM aperture.
            XTIRValue *storePtrVal = [ctx.fn valueForId:ptrOp.valueId];
            if (ctx.bankingActive && storePtrVal.type.kind == XTIRTypeKindPtr
                && [self byteWidthForType:storePtrVal.type] >= 3) {
                [self loadOperandByte:ptrOp byteIndex:2 ctx:ctx];
                [ctx.out appendString:@"    STA __bank_data_reg\n"];
            }
            // Determine the value width from the operand's value
            // type — for ImmI, use the IR-supplied type field.
            NSUInteger w = 1;
            if (valOp.kind == XTIROperandKindUse) {
                XTIRValue *vv = [ctx.fn valueForId:valOp.valueId];
                w = [self byteWidthForType:vv.type];
            } else if (valOp.kind == XTIROperandKindImmI && valOp.type) {
                w = [self byteWidthForType:valOp.type];
            }
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:valOp byteIndex:b ctx:ctx];
                if (b == 0) {
                    [ctx.out appendString:@"    LDY #$00\n"];
                } else {
                    [ctx.out appendString:@"    INY\n"];
                }
                [ctx.out appendFormat:@"    STA %@,Y\n", ind];
            }
            break;
        }
        case XTIROpAddrOf: {
            // Two operand kinds — symbols (low/high byte extract
            // via xta's `<sym`/`>sym` operators) and pinned-local
            // Uses (the pinned local lives in ZP, so its address
            // is the ZP byte; high byte is always 0).
            if (insn.operands.count < 1 || !insn.result) break;
            // Elide the whole pointer-byte materialisation when this AddrOf
            // @sym is consumed only by absolute-fast-path Load/Stores (set
            // computed in computeKnownAddrsForCtx:). The slot is never read,
            // so the `LDA #<_sym / #>_sym / #$00` loads are pure dead code.
            if ([ctx.suppressedAddrOfs containsObject:@(insn.result.valueId)])
                break;
            XTIROperand *op = insn.operands[0];
            BOOL fnBankWritten = NO;
            if (op.kind == XTIROperandKindSym) {
                XTIRSymbol *sym = [ctx.module symbolForId:op.symbolId];
                if (!sym) break;
                [ctx.out appendFormat:@"    LDA #<_%@\n", sym.name];
                [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                [ctx.out appendFormat:@"    LDA #>_%@\n", sym.name];
                [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                // A FUNCTION pointer carries the function's CODE bank in byte 2
                // (`__dbank_<fn>`, a link-time constant from the placement —
                // the same triple a vtable slot uses), so a later CallIndirect
                // can bank-switch to it via __xt_indcall (task #65 stage 2).
                // A data symbol stays flat bank-0 main RAM (byte 2 = 0, below).
                if (ctx.bankingActive && sym.kind == XTIRSymbolKindFunction
                    && [self byteWidthForType:insn.result.type] > 2) {
                    [ctx.out appendFormat:@"    LDA #__dbank_%@\n", sym.name];
                    [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
                    fnBankWritten = YES;
                }
            } else if (op.kind == XTIROperandKindUse) {
                NSString *spillLabel = ctx.spillLabels[@(op.valueId)];
                NSNumber *frameOff = ctx.frameOffsets[@(op.valueId)];
                if (frameOff) {
                    // Pinned local in the software-stack frame (§11.3,
                    // non-leaf). Address = FP + header + offset (the header
                    // is the saved caller-FP, plus the return address and
                    // registers under the xtc-stack convention). 16-bit add
                    // of the constant to the FP pointer.
                    NSUInteger disp = ctx.softFrameHeader + frameOff.unsignedIntegerValue;
                    [ctx.out appendString:@"    CLC\n"];
                    [ctx.out appendFormat:@"    LDA $%02X\n", kFPLo];
                    [ctx.out appendFormat:@"    ADC #$%02X\n", (uint8_t)(disp & 0xFF)];
                    [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                    [ctx.out appendFormat:@"    LDA $%02X\n", kFPHi];
                    [ctx.out appendFormat:@"    ADC #$%02X\n", (uint8_t)((disp >> 8) & 0xFF)];
                    [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                } else if (spillLabel) {
                    // Pinned local spilled to main RAM (STACK-ABI §11.3).
                    // Its address is the 16-bit spill label.
                    [ctx.out appendFormat:@"    LDA #<%@\n", spillLabel];
                    [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                    [ctx.out appendFormat:@"    LDA #>%@\n", spillLabel];
                    [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                } else {
                    // Pinned local in ZP — its slot is the ZP byte
                    // itself. The pointer is `<zp-base>`, high byte = 0.
                    NSInteger zpBase = [self slotForValueId:op.valueId ctx:ctx];
                    if (zpBase < 0) break;
                    [ctx.out appendFormat:@"    LDA #$%02lX\n", (unsigned long)zpBase];
                    [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                    [ctx.out appendString:@"    LDA #$00\n"];
                    [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                }
            } else {
                if (diag) [diag emitError:[NSString stringWithFormat:
                    @"xt6502: AddrOf operand kind %d not supported",
                    (int)op.kind] at:synthLoc()];
                return NO;
            }
            // All AddrOf results are flat-memory pointers — bank = 0.
            // Emit bank-zero bytes for the pointer's width beyond addr:
            //   - 3-byte uniform pointer → one bank byte (byteIndex 2)
            //   - 4-byte rich pointer   → two bank bytes (byteIndex 2, 3)
            // Unbanked (2-byte) results have no bank bytes.
            NSUInteger pw = [self byteWidthForType:insn.result.type];
            for (NSUInteger bi = 2; bi < pw; bi++) {
                if (bi == 2 && fnBankWritten) continue;   // already wrote the code bank
                [ctx.out appendString:@"    LDA #$00\n"];
                [self storeAToValueId:insn.result.valueId byteIndex:bi ctx:ctx];
            }
            break;
        }
        case XTIROpMemCopy: {
            // Operands: [dst, src, size:ImmI, mem]. Stage dst in
            // $85/$86, src in $87/$88, size in A:X, JSR runtime.
            if (insn.operands.count < 4) break;
            XTIROperand *dst = insn.operands[0];
            XTIROperand *src = insn.operands[1];
            XTIROperand *sz  = insn.operands[2];
            for (NSUInteger b = 0; b < 2; b++) {
                [self loadOperandByte:dst byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x85 + (unsigned)b];
            }
            for (NSUInteger b = 0; b < 2; b++) {
                [self loadOperandByte:src byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x87 + (unsigned)b];
            }
            [self loadOperandByte:sz byteIndex:0 ctx:ctx];
            if (sz.kind == XTIROperandKindImmI && sz.type && [self byteWidthForType:sz.type] >= 2) {
                [ctx.out appendString:@"    TAY\n"];
                [self loadOperandByte:sz byteIndex:1 ctx:ctx];
                [ctx.out appendString:@"    TAX\n"];
                [ctx.out appendString:@"    TYA\n"];
            } else {
                [ctx.out appendString:@"    LDX #$00\n"];
            }
            [ctx.out appendString:@"    JSR __xtc_memcpy\n"];
            break;
        }
        case XTIROpMemSet: {
            // Operands: [dst, byte:U8, size, mem]. Stage dst in
            // $85/$86, byte in Y, size in A:X, JSR runtime.
            if (insn.operands.count < 4) break;
            XTIROperand *dst = insn.operands[0];
            XTIROperand *vop = insn.operands[1];
            XTIROperand *sz  = insn.operands[2];
            for (NSUInteger b = 0; b < 2; b++) {
                [self loadOperandByte:dst byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x85 + (unsigned)b];
            }
            [self loadOperandByte:vop byteIndex:0 ctx:ctx];
            [ctx.out appendString:@"    TAY\n"];
            [self loadOperandByte:sz byteIndex:0 ctx:ctx];
            if (sz.kind == XTIROperandKindImmI && sz.type && [self byteWidthForType:sz.type] >= 2) {
                [self emitPHA:ctx];
                [self loadOperandByte:sz byteIndex:1 ctx:ctx];
                [ctx.out appendString:@"    TAX\n"];
                [self emitPLA:ctx];
            } else {
                [ctx.out appendString:@"    LDX #$00\n"];
            }
            [ctx.out appendString:@"    JSR __xtc_memset\n"];
            break;
        }

        // ── Aggregate / field machinery ───────────────────────────
        case XTIROpAggBuild: {
            // Operands: [field0, field1, ..., fieldN-1].
            // Result: Agg(L) with N fields. Copy each field's bytes
            // into the aggregate result's ZP/SP slots at the field's
            // byte offset.
            if (!insn.result) break;
            XTIRType *aggType = insn.result.type;
            if (aggType.kind != XTIRTypeKindAgg || !aggType.layout) break;
            XTIRLayout *layout = aggType.layout;
            // The result aggregate's slot can ALIAS an operand's slot — most
            // sharply for a multi-return tuple whose result byte-0 local lands
            // on an incoming param (so `return 11, p0` stored field0 over p0
            // before field1 read it). Read EVERY field operand into $B0+ scratch
            // first, then copy scratch -> result, so no store clobbers a
            // not-yet-read operand (the parallel-copy discipline, cf. #402).
            // $B0-$BF is free here (the Return's mailbox load comes later).
            int scratch = 0xB0; int so = 0;
            for (NSUInteger i = 0; i < layout.fields.count && i < insn.operands.count; i++) {
                uint32_t fieldW = [self byteWidthForType:layout.fields[i].type];
                XTIROperand *fieldOp = insn.operands[i];
                if (fieldOp.kind != XTIROperandKindUse) { so += fieldW; continue; }
                for (uint32_t b = 0; b < fieldW; b++) {
                    [self loadOperandByte:fieldOp byteIndex:b ctx:ctx];
                    [ctx.out appendFormat:@"    STA $%02X\n", scratch + so]; so++;
                }
            }
            so = 0;
            for (NSUInteger i = 0; i < layout.fields.count && i < insn.operands.count; i++) {
                uint32_t fieldOff = layout.fields[i].byteOffset;
                uint32_t fieldW = [self byteWidthForType:layout.fields[i].type];
                if (insn.operands[i].kind != XTIROperandKindUse) { so += fieldW; continue; }
                for (uint32_t b = 0; b < fieldW; b++) {
                    [ctx.out appendFormat:@"    LDA $%02X\n", scratch + so]; so++;
                    [self storeAToValueId:insn.result.valueId byteIndex:fieldOff + b ctx:ctx];
                }
            }
            break;
        }
        case XTIROpAggExtract: {
            // Operands: [aggValue:Use, fieldIndex:ImmI].
            // Result: the field value. Copy bytes from the aggregate's
            // ZP/SP slot range into the result's slots.
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *aggOp = insn.operands[0];
            XTIROperand *idxOp = insn.operands[1];
            if (aggOp.kind != XTIROperandKindUse) break;
            XTIRValue *aggVal = [ctx.fn valueForId:aggOp.valueId];
            if (aggVal.type.kind != XTIRTypeKindAgg || !aggVal.type.layout) break;
            NSUInteger fieldIdx = (NSUInteger)idxOp.intValue;
            XTIRLayout *layout = aggVal.type.layout;
            if (fieldIdx >= layout.fields.count) break;
            uint32_t fieldOff = layout.fields[fieldIdx].byteOffset;
            uint32_t fieldW = [self byteWidthForType:layout.fields[fieldIdx].type];
            for (uint32_t b = 0; b < fieldW; b++) {
                NSString *src = [self operandForValueId:aggOp.valueId
                                              byteIndex:fieldOff + b ctx:ctx];
                if (!src) break;
                [ctx.out appendFormat:@"    LDA %@\n", src];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }
        case XTIROpFieldAddr: {
            // Operands: [base:Ptr(Agg(L)), ImmI(field_index)].
            // Compute byteOffset at codegen time, emit a
            // 16-bit add of the constant to the base pointer.
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *baseOp = insn.operands[0];
            XTIROperand *idxOp = insn.operands[1];
            if (baseOp.kind != XTIROperandKindUse) break;
            NSString *baseLo = [self operandForValueId:baseOp.valueId byteIndex:0 ctx:ctx];
            NSString *baseHi = [self operandForValueId:baseOp.valueId byteIndex:1 ctx:ctx];
            if (!baseLo || !baseHi) break;
            uint32_t byteOffset = 0;
            XTIRValue *bv = [ctx.fn valueForId:baseOp.valueId];
            XTIRType *pte = bv.type.pointeeType;
            if (pte && pte.kind == XTIRTypeKindAgg && pte.layout
                && (NSUInteger)idxOp.intValue < pte.layout.fields.count) {
                byteOffset = pte.layout.fields[(NSUInteger)idxOp.intValue].byteOffset;
            }
            uint8_t lo = (uint8_t)(byteOffset & 0xFF);
            uint8_t hi = (uint8_t)((byteOffset >> 8) & 0xFF);
            [ctx.out appendString:@"    CLC\n"];
            [ctx.out appendFormat:@"    LDA %@\n", baseLo];
            [ctx.out appendFormat:@"    ADC #$%02X\n", lo];
            [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            [ctx.out appendFormat:@"    LDA %@\n", baseHi];
            [ctx.out appendFormat:@"    ADC #$%02X\n", hi];
            [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
            // Copy the bank-lo from the base pointer unchanged. With
            // 3-byte uniform pointers there is no bank-hi byte to copy.
            if ([self byteWidthForType:bv.type] > 2) {
                [self loadOperandByte:baseOp byteIndex:2 ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
            }
            break;
        }
        case XTIROpElementAddr: {
            // Operands: [base:Ptr(T), idx]. For sizeof(T) == 1
            // (the common case for byte arrays) we can skip the
            // multiply. Larger element sizes route through a
            // runtime mul helper for now.
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *baseOp = insn.operands[0];
            XTIROperand *idxOp = insn.operands[1];
            if (baseOp.kind != XTIROperandKindUse) break;
            NSString *baseLo = [self operandForValueId:baseOp.valueId byteIndex:0 ctx:ctx];
            NSString *baseHi = [self operandForValueId:baseOp.valueId byteIndex:1 ctx:ctx];
            if (!baseLo || !baseHi) break;
            // Element stride = the backend width of the pointee. Use
            // byteWidthForType:, NOT the IR type's intrinsic byteWidth:
            // the latter is XTIRTypeKindByteWidth(kind), which returns 0
            // for a Ptr pointee (it's window-unaware), so the old
            // `pte.byteWidth ?: 1` silently strided a `pointer@` array at
            // 1 byte instead of 2. That overlapped every slot — only the
            // last write survived intact, so Array.get(last) read right
            // while get(0..n-2) read garbage. byteWidthForType: knows a
            // Ptr is 2 bytes (3 banked) and an Agg is its layout size.
            uint32_t elemSize = 1;
            XTIRValue *bv = [ctx.fn valueForId:baseOp.valueId];
            XTIRType *pte = bv.type.pointeeType;
            if (pte) {
                NSUInteger w = [self byteWidthForType:pte];
                if (w > 0) elemSize = (uint32_t)w;
            }
            if (elemSize > 0xFFFF) {
                // A stride past 16 bits can't be reached through a 2-byte
                // pointer anyway — leave it as an honest gap.
                if (diag) [diag emitError:[NSString stringWithFormat:
                    @"xt6502: ElementAddr with sizeof(elem)=%u not yet supported",
                    (unsigned)elemSize] at:synthLoc()];
                return NO;
            }
            XTIRValue *iv = (idxOp.kind == XTIROperandKindUse) ? [ctx.fn valueForId:idxOp.valueId] : nil;
            NSUInteger iw = iv ? [self byteWidthForType:iv.type] : 1;
            if (elemSize == 1) {
                // base + idx (idx assumed U8/U16 — sign-extend not
                // needed for unsigned indices).
                [ctx.out appendString:@"    CLC\n"];
                [self loadOperandByte:idxOp byteIndex:0 ctx:ctx];
                [ctx.out appendFormat:@"    ADC %@\n", baseLo];
                [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                if (iw >= 2) {
                    [self loadOperandByte:idxOp byteIndex:1 ctx:ctx];
                } else {
                    [ctx.out appendString:@"    LDA #$00\n"];
                }
                [ctx.out appendFormat:@"    ADC %@\n", baseHi];
                [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                // Copy bank-lo from the base pointer unchanged. With
                // 3-byte uniform pointers there is no bank-hi byte.
                if ([self byteWidthForType:bv.type] > 2) {
                    [self loadOperandByte:baseOp byteIndex:2 ctx:ctx];
                    [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
                }
                break;
            }
            // base + idx * elemSize. Stage the (zero-extended) index and
            // the constant stride into the $B0.. helper mailbox, multiply
            // with the same _u16Mul the `*` operator uses, then add the
            // base. Indices are unsigned, so a 16-bit product is right;
            // $B0-$B3 are transient scratch (the base lives in the SP
            // frame / ZP-var pool, never $B0-$BF, so it survives).
            [self loadOperandByte:idxOp byteIndex:0 ctx:ctx];
            [ctx.out appendString:@"    STA $B0\n"];
            if (iw >= 2) {
                [self loadOperandByte:idxOp byteIndex:1 ctx:ctx];
            } else {
                [ctx.out appendString:@"    LDA #$00\n"];
            }
            [ctx.out appendString:@"    STA $B1\n"];
            [ctx.out appendFormat:@"    LDA #$%02X\n    STA $B2\n",
             (unsigned)(elemSize & 0xFF)];
            [ctx.out appendFormat:@"    LDA #$%02X\n    STA $B3\n",
             (unsigned)((elemSize >> 8) & 0xFF)];
            [ctx.out appendString:@"    JSR _u16Mul\n"];
            [ctx.out appendString:@"    CLC\n"];
            [ctx.out appendString:@"    LDA $B0\n"];
            [ctx.out appendFormat:@"    ADC %@\n", baseLo];
            [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            [ctx.out appendString:@"    LDA $B1\n"];
            [ctx.out appendFormat:@"    ADC %@\n", baseHi];
            [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
            // Copy bank-lo from the base pointer unchanged. With 3-byte
            // uniform pointers there is no bank-hi byte to copy.
            if ([self byteWidthForType:bv.type] > 2) {
                [self loadOperandByte:baseOp byteIndex:2 ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
            }
            break;
        }

        // ── IntToPtr / PtrToInt ───────────────────────────────────
        case XTIROpIntToPtr: {
            if (insn.operands.count < 1 || !insn.result) break;
            // IntToPtr widens (e.g. u16→uniform 4-byte ptr). Determine
            // the source width so bytes beyond it are zero-extended;
            // without this check loadOperandByte reads adjacent stack
            // slots (other live values) for byte indices ≥ srcW.
            NSUInteger dstW = [self byteWidthForType:insn.result.type];
            XTIROperand *srcOp = insn.operands[0];
            NSUInteger srcW = dstW; // fallback: copy all bytes
            if (srcOp.kind == XTIROperandKindUse) {
                XTIRValue *srcVal = [ctx.fn valueForId:srcOp.valueId];
                if (srcVal) srcW = [self byteWidthForType:srcVal.type];
            }
            for (NSUInteger b = 0; b < dstW; b++) {
                if (b < srcW) {
                    [self loadOperandByte:srcOp byteIndex:b ctx:ctx];
                } else {
                    [ctx.out appendString:@"    LDA #$00\n"];
                }
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }
        case XTIROpPtrToInt: {
            if (insn.operands.count < 1 || !insn.result) break;
            // PtrToInt narrows (3-byte ptr → u16/u32); just copy what
            // fits, truncating high bytes.
            NSUInteger w = [self byteWidthForType:insn.result.type];
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── ARC ops — JSR to runtime helper, pointer in A/X, bank in Y ─
        case XTIROpRetain:
        case XTIROpRelease:
        case XTIROpAutorelease: {
            if (insn.operands.count < 2) break;
            XTIROperand *ptrOp = insn.operands[0];
            // Load A=lo, X=hi, Y=bank-lo from the pointer. All pointers
            // are uniformly 3 bytes now, so always load the bank byte
            // (bank-lo=0 for main-RAM pointers). No $89.
            // Save lo in $93 (bump-allocator scratch, free since we use
            // the free-list heap at $96/$97) rather than PHA/PLA, because
            // emitPHA increments spDelta and would shift subsequent SP-
            // relative operand offsets by 1 byte — the hi and bank loads
            // below would read from the wrong frame locations.
            [self loadOperandByte:ptrOp byteIndex:0 ctx:ctx];
            [ctx.out appendString:@"    STA $93\n"];    // save lo in $93
            [self loadOperandByte:ptrOp byteIndex:1 ctx:ctx];
            [ctx.out appendString:@"    TAX\n"];        // X = hi
            [self loadOperandByte:ptrOp byteIndex:2 ctx:ctx];
            [ctx.out appendString:@"    TAY\n"];        // Y = bank-lo
            [ctx.out appendString:@"    LDA $93\n"];    // A = lo (restored)
            NSString *helper = (insn.opcode == XTIROpRetain) ? @"__xtc_retain"
                              : @"__xtc_release";  // Autorelease degrades
            [ctx.out appendFormat:@"    JSR %@\n", helper];
            break;
        }

        // ── Weak references — runtime calls ───────────────────────
        case XTIROpWeakRegister: {
            // Operands: [slot, obj, mem]. Stage slot in $85/$86 and obj
            // lo/hi/BANK in $87/$88/$89, then JSR the runtime adapter. The
            // obj bank (byte 2 of the uniform 3-byte pointer) is the
            // side-table key alongside the address, matching _obj_bank when
            // the pointee is later decref'd. Each byte is loaded into A and
            // stored, so loadOperandByte's A/X/Y clobbers don't matter.
            if (insn.operands.count < 3) break;
            for (NSUInteger b = 0; b < 3; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x84 + (unsigned)b];  // slot lo/hi/bank
            }
            for (NSUInteger b = 0; b < 3; b++) {
                [self loadOperandByte:insn.operands[1] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x87 + (unsigned)b];  // obj lo/hi/bank
            }
            [ctx.out appendString:@"    JSR __xtc_weak_register\n"];
            break;
        }
        case XTIROpWeakUnregister: {
            // All three bytes: the slot's BANK is needed as well as its
            // address, because unregister now walks the intrusive links that
            // sit in front of the slot and must map the slot's bank to reach
            // them. (The old side-table only compared main-RAM bytes here.)
            if (insn.operands.count < 2) break;
            for (NSUInteger b = 0; b < 3; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x84 + (unsigned)b];  // slot lo/hi/bank
            }
            [ctx.out appendString:@"    JSR __xtc_weak_unregister\n"];
            break;
        }
        case XTIROpWeakLoad: {
            if (insn.operands.count < 2 || !insn.result) break;
            for (NSUInteger b = 0; b < 2; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0x84 + (unsigned)b];  // slot lo/hi
            }
            [ctx.out appendString:@"    JSR __xtc_weak_load\n"];
            // Return value: A = lo, X = hi, Y = bank-lo. 3-byte uniform
            // pointers have no bank-hi; $89 is only used for u32 returns.
            NSUInteger weakRW = [self byteWidthForType:insn.result.type];
            [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            [ctx.out appendString:@"    TXA\n"];
            if (weakRW >= 2) {
                [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
            }
            if (weakRW >= 3) {
                [ctx.out appendString:@"    TYA\n"];
                [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
            }
            if (weakRW >= 4) {
                [ctx.out appendString:@"    LDA $89\n"];
                [self storeAToValueId:insn.result.valueId byteIndex:3 ctx:ctx];
            }
            break;
        }

        // ── VTable dispatch / indirect call ───────────────────────
        //
        // 6502 has no `JSR (ind)`. The idiom: load the function
        // pointer into the module-level scratch ZP pair `$85/$86`,
        // then `JSR __xt_indjmp`, which is a fixed two-byte
        // trampoline `JMP ($85)`. The callee's RTS returns to the
        // instruction after the JSR. The trampoline label is
        // emitted once per module by `assemblyFromModule:`.
        case XTIROpVTblLoad: {
            // Operands: [receiver, ImmI(slot), mem] -> 3-byte fn pointer.
            // VTblDispatch's vtable read without the call — the code word of
            // `&obj.method`.
            //
            // NOTE the byte orders differ and must be transposed: a vtable
            // SLOT is [bank, addr-lo, addr-hi], while a function-pointer VALUE
            // is [addr-lo, addr-hi, code-bank] (the triple AddrOf @fn builds,
            // and the one CallIndirect expects).
            //
            // A null receiver yields a zero pointer rather than faulting, so
            // `&nullDelegate.m` is falsy instead of a crash. An empty slot is
            // already all-zero in the emitted vtable, so it falls out as a
            // null pointer for free — which is what reports "optional method
            // not implemented".
            if (insn.operands.count < 2 || !insn.result) break;
            XTIROperand *recv = insn.operands[0];
            XTIROperand *slotOp = insn.operands[1];
            if (recv.kind != XTIROperandKindUse
                || slotOp.kind != XTIROperandKindImmI) break;
            int64_t off = slotOp.intValue * 3;
            if (off > 253) {
                if (diag) [diag emitError:[NSString stringWithFormat:
                    @"xt6502: vtable slot %lld exceeds the 85-method 8-bit "
                    @"index limit (slot*3 must fit a byte)", slotOp.intValue]
                                   at:synthLoc()];
                return NO;
            }
            NSString *recvInd = [self indirectBaseForValueId:recv.valueId ctx:ctx];
            if (!recvInd) break;
            NSUInteger resW = [self byteWidthForType:insn.result.type];
            NSUInteger lbl = ctx.labelCounter++;

            // Default the whole result to null.
            [ctx.out appendString:@"    LDA #$00\n"];
            for (NSUInteger b = 0; b < resW; b++)
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];

            // Null receiver → leave it null. Test the two address bytes with
            // LDA + branches rather than LDA/ORA: the receiver may live on the
            // SP frame, and `+n,SP` is a valid addressing mode for LDA/STA but
            // NOT for ORA (xta: "invalid addressing mode for ORA").
            NSString *rLo = [self operandForValueId:recv.valueId byteIndex:0 ctx:ctx];
            NSString *rHi = [self operandForValueId:recv.valueId byteIndex:1 ctx:ctx];
            if (!rLo || !rHi) break;
            [ctx.out appendFormat:@"    LDA %@\n", rLo];
            [ctx.out appendFormat:@"    BNE .Lvtl_go_%lu\n", (unsigned long)lbl];
            [ctx.out appendFormat:@"    LDA %@\n", rHi];
            [ctx.out appendFormat:@"    BEQ .Lvtl_done_%lu\n", (unsigned long)lbl];
            [ctx.out appendFormat:@".Lvtl_go_%lu:\n", (unsigned long)lbl];

            // Bank-select the receiver's bank before reading through it —
            // byte 2 of a 3-byte pointer is the data-bank selector.
            XTIRValue *recvVal = [ctx.fn valueForId:recv.valueId];
            if (recvVal && [self byteWidthForType:recvVal.type] > 2) {
                [self loadOperandByte:recv byteIndex:2 ctx:ctx];
                [ctx.out appendString:@"    STA __bank_data_reg\n"];
            }
            // vtbl ptr = (recv),0 / (recv),1 → $85/$86.
            [ctx.out appendString:@"    LDY #$00\n"];
            [ctx.out appendFormat:@"    LDA %@,Y\n", recvInd];
            [ctx.out appendString:@"    STA $85\n"];
            [ctx.out appendString:@"    INY\n"];
            [ctx.out appendFormat:@"    LDA %@,Y\n", recvInd];
            [ctx.out appendString:@"    STA $86\n"];
            // Slot at vtbl + slot*3: byte0 = bank, byte1 = lo, byte2 = hi.
            [ctx.out appendFormat:@"    LDY #$%02X\n", (uint8_t)off];
            [ctx.out appendString:@"    LDA ($85),Y\n"];        // bank
            if (resW > 2)
                [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
            [ctx.out appendString:@"    INY\n"];
            [ctx.out appendString:@"    LDA ($85),Y\n"];        // addr-lo
            [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            [ctx.out appendString:@"    INY\n"];
            [ctx.out appendString:@"    LDA ($85),Y\n"];        // addr-hi
            [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
            [ctx.out appendFormat:@".Lvtl_done_%lu:\n", (unsigned long)lbl];
            break;
        }
        case XTIROpVTblDispatch:
        case XTIROpCallIndirect: {
            if (insn.operands.count < 2) break;
            // Caller-save (task #64): preserve the ZP slots live across
            // this indirect / vtable call, same as the direct-Call path.
            [self emitCallerSaveFor:insn ctx:ctx];
            XTIROperand *recvOrFn = insn.operands[0];
            BOOL isVtbl = (insn.opcode == XTIROpVTblDispatch);
            NSUInteger firstArgIdx = isVtbl ? 2 : 1;
            // Stage the call arguments onto the hardware stack. The
            // callee reads its first parameter at the LOWEST SP offset
            // (top of stack), so the first parameter must be pushed LAST
            // — the direct-Call path achieves this by pushing the args
            // right-to-left. For a VTblDispatch the receiver is the
            // dispatched method's `self` (the first parameter), so it
            // must likewise be pushed AFTER the explicit args, landing on
            // top. (Pushing it first — below the args — swapped `self`
            // with the args in the callee's frame, so any dispatched
            // method that took explicit arguments read garbage; task #136.)
            NSUInteger pushedBytes = 0;
            // Explicit args, right-to-left, MSB-first within each arg —
            // same convention as the direct-Call path.
            NSUInteger argCount = (insn.operands.count >= firstArgIdx + 1)
                ? insn.operands.count - firstArgIdx - 1 : 0;
            for (NSInteger i = (NSInteger)argCount - 1; i >= 0; i--) {
                XTIROperand *a = insn.operands[firstArgIdx + (NSUInteger)i];
                NSUInteger argW = 1;
                if (a.kind == XTIROperandKindUse) {
                    XTIRValue *av = [ctx.fn valueForId:a.valueId];
                    if (av) argW = [self byteWidthForType:av.type];
                } else if (a.kind == XTIROperandKindImmI && a.type) {
                    argW = [self byteWidthForType:a.type];
                }
                for (NSInteger b = (NSInteger)argW - 1; b >= 0; b--) {
                    [self loadOperandByte:a byteIndex:(NSUInteger)b ctx:ctx];
                    [self emitPHA:ctx];
                    pushedBytes++;
                }
            }
            // VTblDispatch: push the receiver as `self` last (on top).
            if (isVtbl) {
                XTIROperand *recv = insn.operands[0];
                // Get receiver width from the value's type (recv.type is
                // nil for Use operands — resolve from the fn value table).
                NSUInteger recvW = [self byteWidthForType:recv.type];
                if (recvW == 0 && recv.kind == XTIROperandKindUse) {
                    XTIRValue *recvVal = [ctx.fn valueForId:recv.valueId];
                    if (recvVal) recvW = [self byteWidthForType:recvVal.type];
                }
                if (recvW == 0) recvW = 4; // default pointer width
                for (NSInteger b = (NSInteger)recvW - 1; b >= 0; b--) {
                    [self loadOperandByte:recv byteIndex:(NSUInteger)b ctx:ctx];
                    [self emitPHA:ctx];
                    pushedBytes++;
                }
            }
            // For VTblDispatch, follow recv → vtbl ptr → fn ptr
            // (slot * 2 offset within the vtbl). For CallIndirect,
            // recvOrFn already holds the function pointer.
            // Bank-aware dispatch (task #65). When banking is active a
            // vtable slot is 3 bytes — `<bank>,<addr-lo>,<addr-hi>` — so
            // the dispatch stages the bank into _xc_bank and the address
            // into $85/$86 and routes through __xt_indcall (bank 0 → raw
            // indirect; bank N → via _xcall). On the flat path slots are
            // still read 3-wide but the bank byte is ignored (always 0)
            // and we use __xt_indjmp directly.
            BOOL bankAware = ctx.bankingActive;
            if (isVtbl) {
                XTIROperand *slotOp = insn.operands[1];
                if (recvOrFn.kind != XTIROperandKindUse) break;
                // Receiver pointer may live on the SP frame (deref via
                // (d,SP),Y) or ZP. Args are already pushed here, so the
                // (d,SP),Y offset must reflect spDelta — indirectBaseFor
                // handles that.
                NSString *recvInd = [self indirectBaseForValueId:recvOrFn.valueId ctx:ctx];
                if (!recvInd) break;
                int64_t slotIdx = slotOp.intValue;
                int64_t off = slotIdx * 3;
                if (off > 253) {
                    if (diag) [diag emitError:[NSString stringWithFormat:
                        @"xt6502: vtable slot %lld exceeds the 85-method 8-bit "
                        @"index limit (slot*3 must fit a byte)", slotIdx]
                                       at:synthLoc()];
                    return NO;
                }
                // Bank-select the receiver's bank before reading the
                // vtable pointer. With 3-byte pointers, byte 2 is the
                // single-byte data-bank selector (written to $83). No $84.
                XTIRValue *recvOrFnVal = [ctx.fn valueForId:recvOrFn.valueId];
                if (recvOrFnVal && [self byteWidthForType:recvOrFnVal.type] > 2) {
                    [self loadOperandByte:recvOrFn byteIndex:2 ctx:ctx];
                    [ctx.out appendString:@"    STA __bank_data_reg\n"];
                }
                // vtbl ptr = (recv),0 / (recv),1 → $85/$86.
                [ctx.out appendString:@"    LDY #$00\n"];
                [ctx.out appendFormat:@"    LDA %@,Y\n", recvInd];
                [ctx.out appendString:@"    STA $85\n"];
                [ctx.out appendString:@"    INY\n"];
                [ctx.out appendFormat:@"    LDA %@,Y\n", recvInd];
                [ctx.out appendString:@"    STA $86\n"];
                // Slot entry at vtbl + slot*3: byte0 = bank, byte1/2 = addr.
                [ctx.out appendFormat:@"    LDY #$%02X\n", (uint8_t)off];
                [ctx.out appendString:@"    LDA ($85),Y\n"];
                if (bankAware) [ctx.out appendString:@"    STA _xc_bank\n"];
                [ctx.out appendString:@"    INY\n"];
                [ctx.out appendString:@"    LDA ($85),Y\n"];
                [self emitPHA:ctx];           // addr-lo
                [ctx.out appendString:@"    INY\n"];
                [ctx.out appendString:@"    LDA ($85),Y\n"];
                [ctx.out appendString:@"    STA $86\n"];        // addr-hi
                [self emitPLA:ctx];
                [ctx.out appendString:@"    STA $85\n"];        // addr-lo
            } else {
                // CallIndirect: the fn pointer is a 3-byte banked pointer
                // [addr-lo, addr-hi, code-bank] — same width as any pointer,
                // byte 2 being the function's code bank (task #65 stage 2,
                // written by AddrOf @fn). Stage addr → $85/$86, bank →
                // _xc_bank, and route through __xt_indcall (bank 0 → raw
                // indirect; bank N → via the _xcall trampoline).
                if (recvOrFn.kind != XTIROperandKindUse) break;
                // The fn pointer may live on the SP frame; args are already
                // pushed, so operandForValueId folds in spDelta.
                NSString *fpLo = [self operandForValueId:recvOrFn.valueId byteIndex:0 ctx:ctx];
                NSString *fpHi = [self operandForValueId:recvOrFn.valueId byteIndex:1 ctx:ctx];
                if (!fpLo || !fpHi) break;
                NSString *fpBank = [self operandForValueId:recvOrFn.valueId byteIndex:2 ctx:ctx];
                [ctx.out appendFormat:@"    LDA %@\n", fpLo];
                [ctx.out appendString:@"    STA $85\n"];
                [ctx.out appendFormat:@"    LDA %@\n", fpHi];
                [ctx.out appendString:@"    STA $86\n"];
                if (bankAware) {
                    if (fpBank) [ctx.out appendFormat:@"    LDA %@\n", fpBank];
                    else        [ctx.out appendString:@"    LDA #$00\n"];
                    [ctx.out appendString:@"    STA _xc_bank\n"];
                }
            }
            [ctx.out appendFormat:@"    JSR %@\n", bankAware ? @"__xt_indcall" : @"__xt_indjmp"];
            // Caller cleanup + return-value stash, same as Call.
            NSUInteger remaining = pushedBytes;
            while (remaining > 0) {
                NSUInteger chunk = remaining > 127 ? 127 : remaining;
                [self emitAddSP:chunk ctx:ctx];
                remaining -= chunk;
            }
            // Harvest the return value. A wide one (float / aggregate / any
            // scalar past 4 bytes) rides the $B0 MAILBOX, not A/X/Y/$89 — this
            // site used to know only the register form, so an i64 returned
            // through a virtual or protocol call harvested four bytes from the
            // wrong place and left the rest, giving a correct high word and a
            // garbage low one. The direct-call site had the mailbox branch all
            // along; found by the differential fuzzer, and it is the same
            // three-copies-drift as the m68k half of this bug.
            // Guard: tests/fixtures/int64_return_dispatch.xc.
            if (insn.result) {
                NSUInteger rW = [self byteWidthForType:insn.result.type];
                BOOL viaMailbox = XTIRTypeKindIsFloating(insn.result.type.kind)
                               || insn.result.type.kind == XTIRTypeKindAgg
                               || rW > 4;
                if (viaMailbox) {
                    for (NSUInteger b = 0; b < rW && b < 16; b++) {
                        [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                        [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
                    }
                } else {
                if (rW >= 1) [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                if (rW >= 2) {
                    [ctx.out appendString:@"    TXA\n"];
                    [self storeAToValueId:insn.result.valueId byteIndex:1 ctx:ctx];
                }
                if (rW >= 3) {
                    [ctx.out appendString:@"    TYA\n"];
                    [self storeAToValueId:insn.result.valueId byteIndex:2 ctx:ctx];
                }
                if (rW >= 4) {
                    [ctx.out appendString:@"    LDA $89\n"];
                    [self storeAToValueId:insn.result.valueId byteIndex:3 ctx:ctx];
                }
                }
            }
            // Caller-restore (task #64): keep the harvested result intact.
            [self emitCallerRestoreFor:insn ctx:ctx];
            break;
        }

        // ── Class downcast — pass-through until the class-header
        //    byte is allocated by the runtime task.
        case XTIROpClassDowncast:
        case XTIROpClassDowncastFailable: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSUInteger w = [self byteWidthForType:insn.result.type];
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Inline asm — pass the text through verbatim. ──────────
        // The 6502 asm IS the instructions the body wants to run.
        // Pull the text from the constant pool and emit it as-is,
        // indented to match the surrounding generated code.
        case XTIROpAsm: {
            XTIRConstantId cid = NSNotFound;
            for (XTIROperand *op in insn.operands) {
                if (op.kind == XTIROperandKindConstAgg) {
                    cid = op.constantId; break;
                }
            }
            if (cid == NSNotFound) break;
            XTIRConstant *c = [ctx.module constantForId:cid];
            if (!c.stringBytes) break;
            NSString *text = [[NSString alloc] initWithData:c.stringBytes
                                                    encoding:NSUTF8StringEncoding];
            if (!text) break;
            // Resolve `{{XTLOCAL:<vid>}}` tokens (inline-asm references to
            // pinned xtc locals, planted by lowerAsmBlock) to the local's
            // storage: a ZP byte (`$A5`) when it has a slot, else its
            // main-RAM spill label.
            if ([text containsString:@"{{XTLOCAL:"]) {
                NSRegularExpression *re =
                    [NSRegularExpression regularExpressionWithPattern:@"\\{\\{XTLOCAL:(\\d+)\\}\\}"
                                                              options:0 error:NULL];
                NSMutableString *resolved = [text mutableCopy];
                NSArray<NSTextCheckingResult *> *ms =
                    [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
                for (NSTextCheckingResult *m in [ms reverseObjectEnumerator]) {
                    XTIRValueId vid = (XTIRValueId)[[text substringWithRange:[m rangeAtIndex:1]] integerValue];
                    NSInteger slot = [self slotForValueId:vid ctx:ctx];
                    NSString *spill = ctx.spillLabels[@(vid)];
                    NSString *repl = (slot >= 0)
                        ? [NSString stringWithFormat:@"$%02lX", (unsigned long)slot]
                        : (spill ?: @"$00");
                    [resolved replaceCharactersInRange:m.range withString:repl];
                }
                text = resolved;
            }
            // Resolve `{{XTLOCALB:<vid>:<byte>}}` — ONE byte of a pinned
            // local selected by an inline-asm byte-extraction operator
            // (`<` lo / `>` hi / `>>` byte2 / `>>>` byte3). The local's
            // bytes sit consecutively in its ZP slot, so byte k is at
            // `$slot+k`; emitted as a ZP address (not `#`-immediate) so
            // `LDA <val` reads the byte's VALUE (private:docs/bugs/010 #3).
            if ([text containsString:@"{{XTLOCALB:"]) {
                NSRegularExpression *re =
                    [NSRegularExpression regularExpressionWithPattern:@"\\{\\{XTLOCALB:(\\d+):(\\d+)\\}\\}"
                                                              options:0 error:NULL];
                NSMutableString *resolved = [text mutableCopy];
                NSArray<NSTextCheckingResult *> *ms =
                    [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
                for (NSTextCheckingResult *m in [ms reverseObjectEnumerator]) {
                    XTIRValueId vid = (XTIRValueId)[[text substringWithRange:[m rangeAtIndex:1]] integerValue];
                    NSInteger byte = [[text substringWithRange:[m rangeAtIndex:2]] integerValue];
                    NSInteger slot = [self slotForValueId:vid ctx:ctx];
                    NSString *spill = ctx.spillLabels[@(vid)];
                    NSString *repl = (slot >= 0)
                        ? [NSString stringWithFormat:@"$%02lX", (unsigned long)(slot + byte)]
                        : (spill ? [NSString stringWithFormat:@"%@+%ld", spill, (long)byte] : @"$00");
                    [resolved replaceCharactersInRange:m.range withString:repl];
                }
                text = resolved;
            }
            // Resolve `{{XTIVAR:<symId>:<byteOff>}}` tokens (inline-asm
            // references to a static utility class's ivars, planted by
            // lowerAsmBlock) to `_<__sdata_Class>+byteOff` — the same
            // `_`-prefixed symbol form AddrOf emits. Without this the bare
            // ivar name leaks as an undefined symbol → $0000.
            if ([text containsString:@"{{XTIVAR:"]) {
                NSRegularExpression *re =
                    [NSRegularExpression regularExpressionWithPattern:@"\\{\\{XTIVAR:(\\d+):(\\d+)\\}\\}"
                                                              options:0 error:NULL];
                NSMutableString *resolved = [text mutableCopy];
                NSArray<NSTextCheckingResult *> *ms =
                    [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
                for (NSTextCheckingResult *m in [ms reverseObjectEnumerator]) {
                    XTIRSymbolId sid = (XTIRSymbolId)[[text substringWithRange:[m rangeAtIndex:1]] integerValue];
                    unsigned long off = (unsigned long)[[text substringWithRange:[m rangeAtIndex:2]] integerValue];
                    XTIRSymbol *sym = [ctx.module symbolForId:sid];
                    NSString *repl = sym
                        ? [NSString stringWithFormat:@"_%@+%lu", sym.name, off]
                        : @"$00";
                    [resolved replaceCharactersInRange:m.range withString:repl];
                }
                text = resolved;
            }
            [ctx.out appendString:@"    ; inline asm\n"];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                if (line.length == 0) continue;
                [ctx.out appendFormat:@"    %@\n", line];
            }
            break;
        }

        // ── Banking ops — real bank-register writes on xt6502 ─────
        case XTIROpBankSelectFor: {
            // Operands: [ImmI(window), %sel]. Window selects which
            // bank register the selector byte goes to:
            //   xt_code → __bank_code_reg
            //   xt_data → __bank_data_reg (single byte; bank-hi eliminated)
            //   xl_flat / unbanked → no-op
            if (insn.operands.count < 2) break;
            XTIROperand *winOp = insn.operands[0];
            XTIROperand *selOp = insn.operands[1];
            int64_t window = (winOp.kind == XTIROperandKindImmI) ? winOp.intValue : 0;
            if (window == XTIRWindowXtCode) {
                [self loadOperandByte:selOp byteIndex:0 ctx:ctx];
                [ctx.out appendString:@"    STA __bank_code_reg\n"];
            } else if (window == XTIRWindowXtData) {
                // With 3-byte pointers the data selector is a single byte
                // in __bank_data_reg. No high byte — bank-hi is eliminated.
                [self loadOperandByte:selOp byteIndex:0 ctx:ctx];
                [ctx.out appendString:@"    STA __bank_data_reg\n"];
            }
            // Other windows: no bank register on xt6502, skip.
            break;
        }
        case XTIROpBankSave: {
            // Push the code/data bank selectors onto the stack so a callee
            // that wants to switch banks can be safely returned from. With
            // 3-byte pointers there is no bank-hi register.
            [ctx.out appendString:@"    LDA __bank_code_reg\n"];
            [self emitPHA:ctx];
            [ctx.out appendString:@"    LDA __bank_data_reg\n"];
            [self emitPHA:ctx];
            break;
        }
        case XTIROpBankRestore: {
            [self emitPLA:ctx];
            [ctx.out appendString:@"    STA __bank_data_reg\n"];
            [self emitPLA:ctx];
            [ctx.out appendString:@"    STA __bank_code_reg\n"];
            break;
        }

        // ── Float arithmetic via runtime helpers ──────────────────
        //   5-byte float (fp*): op1 $B0-$B4, op2 $B5-$B9, result $B0-$B4
        //   8-byte double (dp*): op1 $B0-$B7, op2 $B8-$BF, result $B0-$B7
        case XTIROpFAdd: case XTIROpFSub:
        case XTIROpFMul: case XTIROpFDiv: {
            if (insn.operands.count < 2 || !insn.result) break;
            NSUInteger w = [self byteWidthForType:insn.result.type];
            // IEEE floats (f32=4, f64=8) go through MECH — the op-word type is
            // F32/F64 and the slot layout is the native little-endian IEEE bits.
            if ([XTType floatIsIEEE]) {
                unsigned mcType = (w == 8) ? 1 : 0;    // F64 : F32
                unsigned mcOp;
                switch (insn.opcode) {
                    case XTIROpFAdd: mcOp = 0x01; break;
                    case XTIROpFSub: mcOp = 0x02; break;
                    case XTIROpFMul: mcOp = 0x03; break;
                    default:         mcOp = 0x04; break;   // FDiv
                }
                [self emitMechBinop:insn opWidth:w mcType:mcType mcOp:mcOp
                          slotBytes:w signExtend:NO resultBytes:w ctx:ctx];
                break;
            }
            NSString *prefix = (w == 5) ? @"fp" : @"dp";
            NSString *opName;
            switch (insn.opcode) {
                case XTIROpFAdd: opName = @"Add"; break;
                case XTIROpFSub: opName = @"Sub"; break;
                case XTIROpFMul: opName = @"Mul"; break;
                default:         opName = @"Div"; break;
            }
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[1] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)(w + b)];
            }
            [ctx.out appendFormat:@"    JSR _%@%@\n", prefix, opName];
            for (NSUInteger b = 0; b < w; b++) {
                [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Float negate — flip the sign bit (byte 0, bit 0) ───────
        case XTIROpFNeg: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSUInteger w = [self byteWidthForType:av ? av.type : insn.result.type];
            // Sign bit: IEEE is bit 7 of the top (MSB) byte; the legacy xtc
            // format kept it in bit 0 of byte 0. Either way a single EOR — no
            // MECH round-trip needed for a negation.
            BOOL ieee = [XTType floatIsIEEE];
            NSUInteger signByte = ieee ? (w - 1) : 0;
            uint8_t signMask = ieee ? 0x80 : 0x01;
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                if (b == signByte) [ctx.out appendFormat:@"    EOR #$%02X\n", signMask];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Float compare via fpCmp/dpCmp ──────────────────────────
        //   A after the call: $00 = eq, $FF = op1<op2, $01 = op1>op2.
        case XTIROpFCmp: {
            if (insn.operands.count < 2 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSUInteger w = [self byteWidthForType:av.type];
            if ([XTType floatIsIEEE]) {
                // MECH CMP writes i32 -1/0/+1 into S2; its low byte is $FF/$00/$01,
                // the same convention the old fpCmp returned in A, so the predicate
                // mapping below is unchanged. Read it into A while the page is
                // mapped, then unmap (which clobbers A is fine — done before).
                unsigned mcType = (w == 8) ? 1 : 0;
                [self mechMap:ctx];
                [self mechStore:insn.operands[0] width:w slot:0 slotBytes:w signExtend:NO ctx:ctx];
                [self mechStore:insn.operands[1] width:w slot:1 slotBytes:w signExtend:NO ctx:ctx];
                [self mechOpWord:0 b0:((mcType & 3) << 6) | 0x0A s1:0 s2:1 dst:2 ctx:ctx];
                [self mechRun:1 ctx:ctx];
                [ctx.out appendString:@"    LDA $4050\n"];   // S2 low byte -> A
                [ctx.out appendString:@"    STA $B0\n"];      // stash across unmap
                [self mechUnmap:ctx];
                [ctx.out appendString:@"    LDA $B0\n"];
                uint8_t cmpK = 0; BOOL wantEq = YES;
                switch (insn.predicate) {
                    case XTIRFCmpOEQ: cmpK = 0x00; wantEq = YES; break;
                    case XTIRFCmpONE: cmpK = 0x00; wantEq = NO;  break;
                    case XTIRFCmpOLT: cmpK = 0xFF; wantEq = YES; break;
                    case XTIRFCmpOGT: cmpK = 0x01; wantEq = YES; break;
                    case XTIRFCmpOLE: cmpK = 0x01; wantEq = NO;  break;
                    case XTIRFCmpOGE: cmpK = 0xFF; wantEq = NO;  break;
                    default: cmpK = 0x00; wantEq = YES; break;
                }
                NSUInteger l = ctx.labelCounter++;
                [ctx.out appendFormat:@"    CMP #$%02X\n", cmpK];
                [ctx.out appendFormat:@"    %@ .Lfcmp%lu_t\n",
                 wantEq ? @"BEQ" : @"BNE", (unsigned long)l];
                [ctx.out appendString:@"    LDA #0\n"];
                [ctx.out appendFormat:@"    JMP .Lfcmp%lu_d\n", (unsigned long)l];
                [ctx.out appendFormat:@".Lfcmp%lu_t:\n    LDA #1\n.Lfcmp%lu_d:\n",
                 (unsigned long)l, (unsigned long)l];
                [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
                break;
            }
            NSString *prefix = (w == 5) ? @"fp" : @"dp";
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            for (NSUInteger b = 0; b < w; b++) {
                [self loadOperandByte:insn.operands[1] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)(w + b)];
            }
            [ctx.out appendFormat:@"    JSR _%@Cmp\n", prefix];
            // Map A ($00 eq / $FF lt / $01 gt) to a Bool per predicate.
            // Each predicate is "A == K -> 1" or "A != K -> 1".
            uint8_t cmpK = 0; BOOL wantEq = YES;
            switch (insn.predicate) {
                case XTIRFCmpOEQ: cmpK = 0x00; wantEq = YES; break;
                case XTIRFCmpONE: cmpK = 0x00; wantEq = NO;  break;
                case XTIRFCmpOLT: cmpK = 0xFF; wantEq = YES; break;
                case XTIRFCmpOGT: cmpK = 0x01; wantEq = YES; break;
                case XTIRFCmpOLE: cmpK = 0x01; wantEq = NO;  break;
                case XTIRFCmpOGE: cmpK = 0xFF; wantEq = NO;  break;
                default: cmpK = 0x00; wantEq = YES; break;
            }
            NSUInteger lbl = ctx.labelCounter++;
            [ctx.out appendFormat:@"    CMP #$%02X\n", cmpK];
            [ctx.out appendFormat:@"    %@ .Lfcmp%lu_t\n",
             wantEq ? @"BEQ" : @"BNE", (unsigned long)lbl];
            [ctx.out appendString:@"    LDA #0\n"];
            [ctx.out appendFormat:@"    JMP .Lfcmp%lu_d\n", (unsigned long)lbl];
            [ctx.out appendFormat:@".Lfcmp%lu_t:\n", (unsigned long)lbl];
            [ctx.out appendString:@"    LDA #1\n"];
            [ctx.out appendFormat:@".Lfcmp%lu_d:\n", (unsigned long)lbl];
            [self storeAToValueId:insn.result.valueId byteIndex:0 ctx:ctx];
            break;
        }

        // ── int → float (SIToFp / UIToFp) ─────────────────────────
        case XTIROpSIToFp: case XTIROpUIToFp: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSUInteger sw = [self byteWidthForType:av.type];
            NSUInteger dw = [self byteWidthForType:insn.result.type];
            if ([XTType floatIsIEEE]) {
                // MECH CVT: source int -> F32/F64. u32 must widen to a
                // non-negative i64 (MECH ints are signed); narrower ints
                // sign- or zero-extend to i32.
                BOOL sgn = (insn.opcode == XTIROpSIToFp);
                unsigned dstType = (dw == 8) ? 1 : 0;
                if (!sgn && sw == 8) {
                    [self emitMechU64ToFp:insn dstType:dstType resultBytes:dw ctx:ctx];
                    break;
                }
                unsigned srcType; NSUInteger srcBytes; BOOL sx;
                if (sw == 8)              { srcType = 3; srcBytes = 8; sx = NO; }
                else if (!sgn && sw == 4) { srcType = 3; srcBytes = 8; sx = NO; }
                else                      { srcType = 2; srcBytes = 4; sx = sgn; }
                [self emitMechUnary:insn srcWidth:sw srcType:srcType srcBytes:srcBytes
                         signExtend:sx dstType:dstType mcOp:0x20 resultBytes:dw ctx:ctx];
                break;
            }
            NSString *signTag = (insn.opcode == XTIROpSIToFp) ? @"i" : @"u";
            NSString *widthTag = (sw == 1) ? @"8" : (sw == 2) ? @"16" : @"32";
            NSString *dstTag = (dw == 5) ? @"ToFp" : @"ToDp";
            for (NSUInteger b = 0; b < sw; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            [ctx.out appendFormat:@"    JSR _%@%@%@\n", signTag, widthTag, dstTag];
            for (NSUInteger b = 0; b < dw; b++) {
                [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── float → int (FpToSI / FpToUI) ──────────────────────────
        //   fpToI32 truncates a 5-byte float to i32. For a double we
        //   first dpToFp down to 5-byte. FpToUI reuses fpToI32 (the
        //   bit pattern matches for in-range non-negative values).
        case XTIROpFpToSI: case XTIROpFpToUI: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSUInteger fw = [self byteWidthForType:av.type];
            NSUInteger iw = [self byteWidthForType:insn.result.type];
            if ([XTType floatIsIEEE]) {
                [self emitMechFpToInt:insn floatWidth:fw intWidth:iw
                               signed:(insn.opcode == XTIROpFpToSI) ctx:ctx];
                break;
            }
            for (NSUInteger b = 0; b < fw; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            if (fw == 8) [ctx.out appendString:@"    JSR _dpToFp\n"];
            [ctx.out appendString:@"    JSR _fpToI32\n"];
            for (NSUInteger b = 0; b < iw; b++) {
                [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── Precision casts (FpExt F32→F64, FpTrunc F64→F32) ───────
        case XTIROpFpExt: case XTIROpFpTrunc: {
            if (insn.operands.count < 1 || !insn.result) break;
            XTIRValue *av = [ctx.fn valueForId:insn.operands[0].valueId];
            NSUInteger sw = [self byteWidthForType:av.type];
            NSUInteger dw = [self byteWidthForType:insn.result.type];
            if ([XTType floatIsIEEE]) {
                // MECH CVT between F32 and F64.
                unsigned srcType = (sw == 8) ? 1 : 0;
                unsigned dstType = (dw == 8) ? 1 : 0;
                [self emitMechUnary:insn srcWidth:sw srcType:srcType srcBytes:sw
                         signExtend:NO dstType:dstType mcOp:0x20 resultBytes:dw ctx:ctx];
                break;
            }
            for (NSUInteger b = 0; b < sw; b++) {
                [self loadOperandByte:insn.operands[0] byteIndex:b ctx:ctx];
                [ctx.out appendFormat:@"    STA $%02X\n", 0xB0 + (unsigned)b];
            }
            [ctx.out appendFormat:@"    JSR _%@\n",
             (insn.opcode == XTIROpFpExt) ? @"fpToDp" : @"dpToFp"];
            for (NSUInteger b = 0; b < dw; b++) {
                [ctx.out appendFormat:@"    LDA $%02X\n", 0xB0 + (unsigned)b];
                [self storeAToValueId:insn.result.valueId byteIndex:b ctx:ctx];
            }
            break;
        }

        // ── float sqrt via MECH (sqrt-intrinsic pass emits FSqrt) ──
        case XTIROpFSqrt: {
            if (insn.operands.count < 1 || !insn.result || ![XTType floatIsIEEE]) break;
            NSUInteger w = [self byteWidthForType:insn.result.type];
            unsigned t = (w == 8) ? 1 : 0;                 // F64 : F32
            [self emitMechUnary:insn srcWidth:w srcType:t srcBytes:w
                     signExtend:NO dstType:t mcOp:0x07 resultBytes:w ctx:ctx];
            break;
        }

        default: {
            if (diag) {
                [diag emitError:[NSString stringWithFormat:
                    @"xt6502: opcode %d not yet supported", (int)insn.opcode] at:synthLoc()];
            }
            return NO;
        }
    }
    return YES;
}

#pragma mark - Function emission

+ (BOOL)emitFunction:(XTIRFunction *)fn
              module:(XTIRModule *)mod
         memoryModel:(nullable XTMemoryModel *)model
          spillDecls:(NSMutableArray<NSArray *> *)spillDecls
        bankingActive:(BOOL)bankingActive
          currentBank:(NSUInteger)currentBank
              bankMap:(nullable NSDictionary<NSString *, NSNumber *> *)bankMap
          codeBankReg:(uint16_t)codeBankReg
                into:(NSMutableString *)out
         diagnostics:(XTDiagnosticEngine *)diag
{
    XT6502FnCtx *ctx = [[XT6502FnCtx alloc] init];
    ctx.fn = fn;
    ctx.module = mod;
    ctx.out = out;
    ctx.bankingActive = bankingActive;
    ctx.currentBank = currentBank;
    ctx.bankMap = bankMap;
    ctx.codeBankReg = codeBankReg;   // from the layout; 0 only when unbanked
    XTIRSymbol *fnSym = [mod symbolForName:fn.name];
    ctx.isIrq = [fnSym.attributes[@"irq"] boolValue];
    ctx.isVbi = [fnSym.attributes[@"vbi"] boolValue];
    // The calling convention: `:xtcStack` / `:hwStack` on the function, else
    // the --xtc-stack default. An interrupt handler keeps its own shape.
    ctx.xtcStack = !ctx.isIrq && !ctx.isVbi
        && ([fnSym.attributes[@"xtcstack"] boolValue]
            || (sDefaultXtcStack && ![fnSym.attributes[@"hwstack"] boolValue]));
    if (ctx.xtcStack) {
        if (!model.stackRangeSet) {
            if (diag) {
                [diag emitError:[NSString stringWithFormat:
                    @"xt6502: function '%@' uses the xtc software stack, but the "
                    @"layout declares no [stack] region", fn.name] at:synthLoc()];
            }
            return NO;
        }
        ctx.frameLocalsBase = 1;
        ctx.softFrameHeader = 8;
        ctx.usesSoftStack = YES;
    }
    // Model-driven ZP var pool. nil / empty falls back to $A0..$FF.
    [ctx useZpRanges:model.zpVarsRanges];
    BOOL isLeaf = [self functionIsLeaf:fn];

    NSUInteger paramCount = fn.paramTypes.count;
    NSUInteger userParams = (paramCount > 0
                             && [fn.paramTypes.lastObject kind] == XTIRTypeKindMemory)
        ? paramCount - 1 : paramCount;

    // Place every non-address-taken, non-Mem SSA value (params + temps) on
    // the SP hardware frame (STACK-ABI §11.1) instead of zero page — this
    // is what relieves the ZP-overflow wall. Pointers ride the frame too;
    // they deref in place via (d,SP),Y. Address-taken / pinned values are
    // *excluded* (they need real 16-bit addresses) and go to ZP/spill
    // below. Frame locals start at +6 (after the 6 saved-register bytes);
    // each value's byte 0 sits at its assigned offset. No liveness reuse
    // yet — N can exceed the §6.1 budget for very large functions, which
    // then bail loudly (a follow-up reuse pass compresses N).
    // A value must stay in addressable storage (ZP/spill, never the SP
    // hidden stack) iff its address is ever formed: either it is a
    // declared pinned local, or it is the operand of an AddrOf. The
    // latter catches address-taken *params* (e.g. a by-value struct
    // param whose members are read via AddrOf+FieldAddr) — those are not
    // in frameInfo.pinnedLocals, since a param's slot was historically
    // its addressability. AddrOf of a frame slot is impossible (the
    // hidden stack has no 16-bit address), so these are excluded below.
    NSMutableSet<NSNumber *> *pinnedSet = [NSMutableSet set];
    for (XTIRPinnedLocal *pl in fn.frameInfo.pinnedLocals) {
        [pinnedSet addObject:@(pl.valueId)];
    }
    for (XTIRBlock *block in fn.blocks) {
        for (XTIRInsn *insn in block.instructions) {
            if (insn.opcode != XTIROpAddrOf) continue;
            for (XTIROperand *op in insn.operands) {
                if (op.kind == XTIROperandKindUse) [pinnedSet addObject:@(op.valueId)];
            }
        }
    }
    // Inline-asm references to xtc locals/params (rewritten by the
    // lowering to {{XTLOCAL:<vid>}}) need ZP-style addressing — `name`,
    // `name+1`, `(name),Y` — which the SP frame can't provide. ZP-pin
    // every value an asm block names so the {{XTLOCAL}} resolution yields
    // a real ZP byte ($XX) instead of $00.
    for (XTIRBlock *block in fn.blocks) {
        for (XTIRInsn *insn in block.instructions) {
            if (insn.opcode != XTIROpAsm) continue;
            for (XTIROperand *op in insn.operands) {
                if (op.kind != XTIROperandKindConstAgg) continue;
                XTIRConstant *c = [mod constantForId:op.constantId];
                NSString *txt = c.stringBytes
                    ? [[NSString alloc] initWithData:c.stringBytes encoding:NSUTF8StringEncoding]
                    : nil;
                if (!txt) continue;
                NSRegularExpression *re = [NSRegularExpression
                    regularExpressionWithPattern:@"\\{\\{XTLOCAL:(\\d+)\\}\\}" options:0 error:NULL];
                for (NSTextCheckingResult *m in [re matchesInString:txt options:0
                                                              range:NSMakeRange(0, txt.length)]) {
                    XTIRValueId vid = (XTIRValueId)[[txt substringWithRange:[m rangeAtIndex:1]] integerValue];
                    [pinnedSet addObject:@(vid)];
                }
            }
        }
    }
    [self computeFrameSlotsForCtx:ctx pinnedSet:pinnedSet];
    [self placeParamsInPlaceForCtx:ctx pinnedSet:pinnedSet];

    // Pinned locals (address-taken scalars, value-typed struct/array
    // locals). They live in addressable storage — never the hidden
    // hardware stack, which LDA/STA/(zp),Y cannot reach
    // (6502-embellishments.md §1). ZP-first; a pinned local that does
    // not fit the remaining ZP spills to main RAM (STACK-ABI §11.3):
    // a leaf gets a static `.space` slot (never re-entered), a non-leaf
    // would need a software-stack frame — task #57, so bail clearly.
    for (XTIRPinnedLocal *pl in fn.frameInfo.pinnedLocals) {
        XTIRValue *pv = [fn valueForId:pl.valueId];
        if (!pv) continue;
        NSUInteger width = [self byteWidthForType:pv.type];
        if (width == 0) continue;
        // The ZP pinned-local pool is shared by every function, so a local
        // whose pointer is dereferenced across calls (a stack-allocated
        // class instance, reached via self) cannot live there: a callee —
        // even a transitively-reached one — reusing the pool would clobber
        // it. Send those straight to the per-invocation software-stack
        // frame / per-function static spill (a stable address the callee
        // can't reuse), skipping ZP entirely.
        NSInteger base = pl.escapesViaPointer
            ? -1 : [self tryAllocateZPWidth:width ctx:ctx];
        if (base >= 0) {
            ctx.zpBase[@(pl.valueId)] = @(base);
            continue;
        }
        // Doesn't fit ZP (or must avoid it) → spill to main RAM.
        if (!isLeaf) {
            // Non-leaf: a static slot would alias across re-entry, so
            // this local goes into a per-invocation software-stack frame
            // (STACK-ABI §11.3). Needs a model-declared software-stack
            // region; without one we can't make a frame.
            if (!model.stackRangeSet) {
                if (diag) {
                    [diag emitError:[NSString stringWithFormat:
                        @"xt6502: function '%@' needs a software-stack frame for a "
                        @"pinned local (%lu bytes) that doesn't fit ZP, but the "
                        @"layout declares no [stack] region (STACK-ABI §11.3)",
                        fn.name, (unsigned long)width] at:synthLoc()];
                }
                return NO;
            }
            ctx.usesSoftStack = YES;
            ctx.frameOffsets[@(pl.valueId)] = @(ctx.frameLocalsSize);
            ctx.frameLocalsSize += width;
            continue;
        }
        NSString *label = [NSString stringWithFormat:@"_spill_%@_%lu",
                           fn.name, (unsigned long)pl.valueId];
        ctx.spillLabels[@(pl.valueId)] = label;
        [spillDecls addObject:@[label, @(width)]];
    }

    // Address-taken values that weren't declared pinned locals (e.g. a
    // by-value struct param read via AddrOf+FieldAddr) still need
    // addressable ZP/spill storage — they were excluded from the SP frame
    // above. Allocate them with the same ZP-first/spill policy, in a
    // deterministic order (params, then block-result definition order).
    NSMutableArray<NSNumber *> *extraAddrTaken = [NSMutableArray array];
    void (^collectExtra)(XTIRValue *) = ^(XTIRValue *v) {
        if (!v) return;
        NSNumber *k = @(v.valueId);
        if (![pinnedSet containsObject:k]) return;
        if (ctx.zpBase[k] || ctx.spillLabels[k] || ctx.frameOffsets[k]) return;
        if ([self byteWidthForType:v.type] == 0) return;
        [extraAddrTaken addObject:k];
    };
    for (NSUInteger i = 0; i < paramCount; i++) collectExtra([fn valueForId:(XTIRValueId)i]);
    for (XTIRBlock *block in fn.blocks) {
        for (XTIRInsn *phi in block.phiNodes) collectExtra(phi.result);
        for (XTIRInsn *insn in block.instructions) collectExtra(insn.result);
        if (block.terminator) collectExtra(block.terminator.result);
    }
    for (NSNumber *vidN in extraAddrTaken) {
        XTIRValue *pv = [fn valueForId:(XTIRValueId)vidN.unsignedIntegerValue];
        NSUInteger width = [self byteWidthForType:pv.type];
        NSInteger base = [self tryAllocateZPWidth:width ctx:ctx];
        if (base >= 0) { ctx.zpBase[vidN] = @(base); continue; }
        if (!isLeaf) {
            if (!model.stackRangeSet) {
                if (diag) [diag emitError:[NSString stringWithFormat:
                    @"xt6502: function '%@' needs a software-stack frame for an "
                    @"address-taken value (%lu bytes) that doesn't fit ZP, but the "
                    @"layout declares no [stack] region (STACK-ABI §11.3)",
                    fn.name, (unsigned long)width] at:synthLoc()];
                return NO;
            }
            ctx.usesSoftStack = YES;
            ctx.frameOffsets[vidN] = @(ctx.frameLocalsSize);
            ctx.frameLocalsSize += width;
            continue;
        }
        NSString *label = [NSString stringWithFormat:@"_spill_%@_%lu",
                           fn.name, (unsigned long)vidN.unsignedIntegerValue];
        ctx.spillLabels[vidN] = label;
        [spillDecls addObject:@[label, @(width)]];
    }

    // (A param / SSA temp that overflows the ZP pool — ctx.zpOverflow —
    // is left as the pre-#56 silent fallback: register pressure for
    // per-invocation temporaries beyond the pool is a separate later
    // task, out of scope for the pinned-local spill landing here.)

    // STACK-ABI §6.1 budget check: N (SP-frame locals, 0 today) + K
    // (param bytes) ≤ 119. Pinned-local size is NOT part of N — those
    // live in ZP / main-RAM spill, not on the SP stack (§11.2). Before
    // #56 this counted pinnedLocalSize and wrongly refused e.g. a 300-
    // byte array that belongs in main RAM.
    NSUInteger K = 0;
    for (NSUInteger i = 0; i < userParams; i++) {
        K += [self byteWidthForType:fn.paramTypes[i]];
    }
    NSUInteger N = ctx.spFrameSize;
    if (N + K > 119) {
        if (diag) {
            [diag emitError:[NSString stringWithFormat:
                @"xt6502: function '%@' SP frame %lu + params %lu = %lu exceeds "
                @"119-byte budget; automatic frame splitting is a future task "
                @"(STACK-ABI §7)",
                fn.name, (unsigned long)N, (unsigned long)K, (unsigned long)(N + K)] at:synthLoc()];
        }
        return NO;
    }

    // Function label.
    [out appendFormat:@"_%@:\n", fn.name];

    // Prologue. Three shapes:
    //   :irq → naked. No PSH; the body's first byte is the first
    //          opcode (test reads byte 0 to verify $A9 for LDA #imm).
    //   :vbi → PHA / TXA / PHA / TYA / PHA. The Atari ROM dispatches
    //          deferred VBIs without saving any registers; the handler
    //          itself preserves A/X/Y, then JMPs XITVBV ($E462) at the
    //          end (instead of RTS) so the ROM chains back to the
    //          interrupted code.
    //   plain → PSH #N saves the 6 registers (+ the SP+0 guard byte)
    //           and allocates N SP-frame local bytes; PLL #N mirrors
    //           it in the epilogue.
    if (ctx.isVbi) {
        [out appendString:@"    PHA\n"];
        [out appendString:@"    TXA\n"];
        [out appendString:@"    PHA\n"];
        [out appendString:@"    TYA\n"];
        [out appendString:@"    PHA\n"];
    } else if (ctx.xtcStack) {
        [self emitXtcStackPrologueForCtx:ctx];
    } else if (!ctx.isIrq) {
        [out appendFormat:@"    PSH #%lu\n", (unsigned long)N];
    }

    // Copy user params from the caller's stack into their frame (or ZP, if
    // address-taken) slots. After PSH #N the frame is [guard@+0, regs@+1..+6,
    // locals@+7..+N+6, gap@+N+7, ret@+N+8..+N+9, params@+N+10..]; so param 0
    // starts at SP-relative offset +N+10 (6502-embellishments §3, with the
    // guard byte). Byte 0 (LSB) is at the lower offset. spDelta is 0 here
    // (no pushes yet), so operandForValueId gives the settled slot operand.
    NSUInteger paramOffset = [self paramBaseForCtx:ctx];

    // The ENTRY function has no caller, so nothing pushed its arguments and
    // those bytes hold whatever the stack happened to contain. `main` is
    // reached by a bare `JSR _xt_main` from the hand-written startup
    // (support/xt6502/runtime/xt6502-harness.asm), which cannot know main's
    // signature — so `i32 main(i32 argc, u8** argv)` read garbage argc with a
    // junk argv (bug 121). Zero them here, where the signature IS known.
    //
    // argc = 0, argv = NULL, matching what bug 116 established for wasm32: a
    // 6502 program has no command line, and a conforming program reads neither
    // when argc is 0. The same defect on a target with no validator to catch
    // it — wasm rejected the module outright, a 6502 just ran with junk.
    //
    // Written ABOVE this frame, into the caller's argument area, which is
    // exactly where a caller would have put them and is unused otherwise.
    if (!ctx.isIrq && !ctx.isVbi && userParams > 0
        && [fn.name isEqualToString:@"main"]) {
        // NOT `fn == entryFunctionOf:` — that falls back to the FIRST function
        // when a module has no `main`, which is every ir-codegen fixture (they
        // are a single callee invoked from a hand-written harness that pushes
        // real arguments). Zeroing there wiped the caller's pushed args and
        // turned add(5,6) into add(0,0). The entry is `main` by name; the
        // `_main` -> `_xt_main` rename happens in the asm TEXT after codegen,
        // so the IR function is still called `main` here.
        NSUInteger z = paramOffset, zEnd = paramOffset;
        for (NSUInteger i = 0; i < userParams; i++)
            zEnd += [self byteWidthForType:fn.paramTypes[i]];
        [out appendString:@"    ; entry: no caller pushed our args — argc=0, argv=NULL (bug 121)\n"];
        [out appendString:@"    LDA #$00\n"];
        for (; z < zEnd; z++)
            [out appendFormat:@"    STA +%lu,SP\n", (unsigned long)z];
    }

    for (NSUInteger i = 0; i < userParams; i++) {
        XTIRType *pty = fn.paramTypes[i];
        NSUInteger w = [self byteWidthForType:pty];
        for (NSUInteger b = 0; b < w; b++) {
            NSString *dest = [self operandForValueId:(XTIRValueId)i byteIndex:b ctx:ctx];
            NSString *src = [NSString stringWithFormat:@"+%lu,SP",
                             (unsigned long)(paramOffset + b)];
            // placeParamsInPlaceForCtx points non-pinned params straight at
            // their incoming offset, so this copy is `LDA x / STA x` — skip.
            if (dest && [dest isEqualToString:src]) continue;
            [out appendFormat:@"    LDA %@\n", src];
            [out appendFormat:@"    STA %@\n", dest ?: @"$00"];
        }
        paramOffset += w;
    }

    // Software-stack frame setup (STACK-ABI §11.3, non-leaf). The frame
    // reserves (2 + frameLocalsSize) bytes at SSP: its first 2 bytes
    // hold the caller's FP, the rest are the spilled locals. Save the
    // caller FP into the frame base, point FP at the new frame, and bump
    // SSP past it. Per-invocation (recursion-safe). Done after the param
    // spill so the SP-relative param offsets above are untouched.
    if (ctx.usesSoftStack && !ctx.xtcStack) {
        if (diag) {
            [diag emitWarning:[NSString stringWithFormat:
                @"xt6502: function '%@' uses a software stack (%lu bytes of "
                @"non-leaf pinned locals don't fit ZP) — STACK-ABI §11.3",
                fn.name, (unsigned long)ctx.frameLocalsSize] at:synthLoc()];
        }
        NSUInteger total = 2 + ctx.frameLocalsSize;
        [out appendString:@"    ; --- software-stack frame push (§11.3) ---\n"];
        [out appendString:@"    LDY #$00\n"];
        [out appendFormat:@"    LDA $%02X\n", kFPLo];     // caller FP lo
        [out appendFormat:@"    STA ($%02X),Y\n", kSSPLo];
        [out appendString:@"    INY\n"];
        [out appendFormat:@"    LDA $%02X\n", kFPHi];     // caller FP hi
        [out appendFormat:@"    STA ($%02X),Y\n", kSSPLo];
        [out appendFormat:@"    LDA $%02X\n", kSSPLo];    // FP = SSP
        [out appendFormat:@"    STA $%02X\n", kFPLo];
        [out appendFormat:@"    LDA $%02X\n", kSSPHi];
        [out appendFormat:@"    STA $%02X\n", kFPHi];
        [out appendString:@"    CLC\n"];                  // SSP += total
        [out appendFormat:@"    LDA $%02X\n", kSSPLo];
        [out appendFormat:@"    ADC #$%02X\n", (uint8_t)(total & 0xFF)];
        [out appendFormat:@"    STA $%02X\n", kSSPLo];
        [out appendFormat:@"    LDA $%02X\n", kSSPHi];
        [out appendFormat:@"    ADC #$%02X\n", (uint8_t)((total >> 8) & 0xFF)];
        [out appendFormat:@"    STA $%02X\n", kSSPHi];
    }

    // Stage 10a — known-compile-time-address analysis. Walk the IR
    // before codegen and build a map of valueId → XT6502KnownAddr for
    // every Ptr SSA value whose address chain is a compile-time
    // constant. The Store / Load handlers consult this map first and
    // emit direct addressing (ZP `STA $XX` or absolute `STA label+N`)
    // instead of computing the address at runtime + indirect-Y.
    [self computeKnownAddrsForCtx:ctx];

    // Emit each block.
    for (XTIRBlock *block in fn.blocks) {
        [out appendFormat:@"%@:\n", [self blockLabelForFn:fn block:block]];
        for (XTIRInsn *phi in block.phiNodes) {
            // No emission at phi location.
            (void)phi;
        }
        for (XTIRInsn *insn in block.instructions) {
            if (![self emitInsn:insn inBlock:block ctx:ctx diagnostics:diag]) return NO;
        }
        if (block.terminator) {
            if (![self emitInsn:block.terminator inBlock:block ctx:ctx diagnostics:diag]) return NO;
        }
    }
    [out appendString:@"\n"];
    return YES;
}

// Stage 10a — compute compile-time-known addresses for Ptr SSA values.
// A value gets an XT6502KnownAddr entry when its def insn is one of:
//   AddrOf <pinned local> — base address (ZP byte or spill label).
//   Bitcast <Ptr value>   — inherits the source's known address.
//   ElementAddr <Ptr value with known addr>, <const-valued index>
//       → offset += constIndex × elemSize (when elemSize is constant)
//   FieldAddr <Ptr value with known addr>, <const offset>
//       → offset += fieldOffset
// Index/offset operands can be either ImmI immediates or Uses of Const
// def insns — the IR-lowering tends to materialise the latter.
// Soft-stack frame locals are deliberately NOT followed (their address
// depends on the runtime FP; the indirect-Y path is already correct).

// Helper: resolve a Use/ImmI operand to its integer value when known
// at compile time. Returns YES if the value was resolved.
+ (BOOL)resolveConstIntForOperand:(XTIROperand *)op
                              fn:(XTIRFunction *)fn
                          outVal:(int64_t *)outVal
                       constMap:(NSDictionary<NSNumber *, NSNumber *> *)constMap
{
    if (op.kind == XTIROperandKindImmI) {
        if (outVal) *outVal = op.intValue;
        return YES;
    }
    if (op.kind == XTIROperandKindUse) {
        NSNumber *v = constMap[@(op.valueId)];
        if (v) { if (outVal) *outVal = v.longLongValue; return YES; }
    }
    return NO;
}

+ (void)computeKnownAddrsForCtx:(XT6502FnCtx *)ctx {
    // First pass — record Const def insns' values for later lookup.
    NSMutableDictionary<NSNumber *, NSNumber *> *constMap = [NSMutableDictionary dictionary];
    for (XTIRBlock *block in ctx.fn.blocks) {
        for (XTIRInsn *insn in block.instructions) {
            if (insn.opcode != XTIROpConst || !insn.result) continue;
            if (insn.operands.count < 1) continue;
            XTIROperand *op = insn.operands[0];
            if (op.kind == XTIROperandKindImmI) {
                constMap[@(insn.result.valueId)] = @(op.intValue);
            }
        }
    }

    for (XTIRBlock *block in ctx.fn.blocks) {
        for (XTIRInsn *insn in block.instructions) {
            if (!insn.result) continue;
            XTIRType *rt = insn.result.type;
            if (rt.kind != XTIRTypeKindPtr) continue;
            XT6502KnownAddr *ka = nil;
            switch (insn.opcode) {
                case XTIROpAddrOf: {
                    if (insn.operands.count < 1) break;
                    XTIROperand *op = insn.operands[0];
                    if (op.kind == XTIROperandKindSym) {
                        // AddrOf of a global symbol — a compile-time
                        // absolute, flat bank-0 address (`_<name>`).
                        XTIRSymbol *sym = [ctx.module symbolForId:op.symbolId];
                        if (!sym) break;
                        ka = [[XT6502KnownAddr alloc] init];
                        ka.kind = XT6502KnownAddrKindAbsSym;
                        ka.spillLabel = [NSString stringWithFormat:@"_%@", sym.name];
                        break;
                    }
                    if (op.kind != XTIROperandKindUse) break;
                    NSNumber *zp = ctx.zpBase[@(op.valueId)];
                    NSString *spill = ctx.spillLabels[@(op.valueId)];
                    if (zp) {
                        ka = [[XT6502KnownAddr alloc] init];
                        ka.kind = XT6502KnownAddrKindZP;
                        ka.zpBase = zp.unsignedIntegerValue;
                    } else if (spill) {
                        ka = [[XT6502KnownAddr alloc] init];
                        ka.kind = XT6502KnownAddrKindSpill;
                        ka.spillLabel = spill;
                    }
                    break;
                }
                case XTIROpBitcast: {
                    if (insn.operands.count < 1) break;
                    XTIROperand *op = insn.operands[0];
                    if (op.kind != XTIROperandKindUse) break;
                    XT6502KnownAddr *src = ctx.knownAddrs[@(op.valueId)];
                    if (src) {
                        ka = [[XT6502KnownAddr alloc] init];
                        ka.kind = src.kind;
                        ka.zpBase = src.zpBase;
                        ka.spillLabel = src.spillLabel;
                        ka.offset = src.offset;
                    }
                    break;
                }
                case XTIROpElementAddr: {
                    if (insn.operands.count < 2) break;
                    XTIROperand *baseOp = insn.operands[0];
                    XTIROperand *idxOp  = insn.operands[1];
                    if (baseOp.kind != XTIROperandKindUse) break;
                    XT6502KnownAddr *base = ctx.knownAddrs[@(baseOp.valueId)];
                    if (!base) break;
                    // AbsSym is consumed only by the direct Load/Store fast
                    // path; do NOT fold element offsets into it. Element/
                    // field chains off a global (e.g. the printf va-buffer
                    // `___xtc_va_buf+N`) stay on the generic indirect path,
                    // which the reverted Stage-10a roll-out showed is the
                    // safe choice for aggregate-offset addressing.
                    if (base.kind == XT6502KnownAddrKindAbsSym) break;
                    int64_t idx = 0;
                    if (![self resolveConstIntForOperand:idxOp fn:ctx.fn
                                                  outVal:&idx constMap:constMap]) break;
                    if (idx < 0) break;
                    // Element stride = backend width of the pointee.
                    XTIRValue *bv = [ctx.fn valueForId:baseOp.valueId];
                    XTIRType *pte = bv.type.pointeeType;
                    NSUInteger elemSize = 1;
                    if (pte) {
                        NSUInteger w = [self byteWidthForType:pte];
                        if (w > 0) elemSize = w;
                    }
                    NSUInteger newOffset = base.offset + (NSUInteger)idx * elemSize;
                    ka = [[XT6502KnownAddr alloc] init];
                    ka.kind = base.kind;
                    ka.zpBase = base.zpBase;
                    ka.spillLabel = base.spillLabel;
                    ka.offset = newOffset;
                    break;
                }
                case XTIROpFieldAddr: {
                    if (insn.operands.count < 2) break;
                    XTIROperand *baseOp = insn.operands[0];
                    XTIROperand *offOp  = insn.operands[1];
                    if (baseOp.kind != XTIROperandKindUse) break;
                    XT6502KnownAddr *base = ctx.knownAddrs[@(baseOp.valueId)];
                    if (!base) break;
                    // See ElementAddr: AbsSym does not fold field offsets.
                    if (base.kind == XT6502KnownAddrKindAbsSym) break;
                    int64_t off = 0;
                    if (![self resolveConstIntForOperand:offOp fn:ctx.fn
                                                  outVal:&off constMap:constMap]) break;
                    if (off < 0) break;
                    ka = [[XT6502KnownAddr alloc] init];
                    ka.kind = base.kind;
                    ka.zpBase = base.zpBase;
                    ka.spillLabel = base.spillLabel;
                    ka.offset = base.offset + (NSUInteger)off;
                    break;
                }
                default:
                    break;
            }
            if (ka) ctx.knownAddrs[@(insn.result.valueId)] = ka;
        }
    }

    // Second pass — find AddrOf @sym values whose materialisation can be
    // elided. A candidate is suppressible iff EVERY use is the pointer
    // operand (index 0) of a Load/Store IN THE SAME BLOCK as the AddrOf —
    // those go through the absolute fast path, which never reads the
    // materialised pointer slot. Three guards keep this provably safe:
    //   * AbsSym only (a direct global address; Bitcast/Element/FieldAddr
    //     chains produce a different result value and are excluded above).
    //   * SCALAR pointee only — an aggregate/pointer pointee (class static
    //     data, struct globals) flows into FieldAddr/VTblDispatch/Call as a
    //     base/receiver, uses whose IR shape this scan may not recognise.
    //   * SAME-BLOCK uses only — a cross-block use (e.g. the static-init
    //     guard `if (!__sinit_X) __sinit_X = 1;`, whose Load and Store sit
    //     in different blocks) keeps the materialisation. The production
    //     round-trip reshapes such cross-block dataflow in ways that made a
    //     global use-scan drop a live pointer (observed: file_basic). Any
    //     other use (Store value operand, Call/Phi, different block)
    //     disqualifies the candidate.
    NSMutableSet<NSNumber *> *candidates = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, NSNumber *> *candBlock =
        [NSMutableDictionary dictionary];
    NSUInteger blockIdx = 0;
    for (XTIRBlock *block in ctx.fn.blocks) {
        for (XTIRInsn *insn in block.instructions) {
            if (insn.opcode != XTIROpAddrOf || !insn.result) continue;
            XT6502KnownAddr *ka = ctx.knownAddrs[@(insn.result.valueId)];
            if (!ka || ka.kind != XT6502KnownAddrKindAbsSym) continue;
            XTIRType *pte = insn.result.type.pointeeType;
            BOOL scalarPointee = pte &&
                (XTIRTypeKindIsInteger(pte.kind) ||
                 pte.kind == XTIRTypeKindBool ||
                 XTIRTypeKindIsFloating(pte.kind));
            if (!scalarPointee) continue;
            [candidates addObject:@(insn.result.valueId)];
            candBlock[@(insn.result.valueId)] = @(blockIdx);
        }
        blockIdx++;
    }
    if (candidates.count > 0) {
        NSMutableSet<NSNumber *> *disqualified = [NSMutableSet set];
        NSUInteger bi = 0;
        for (XTIRBlock *block in ctx.fn.blocks) {
            // Phi operands and the terminator's operands are uses too. Scanning
            // only `instructions` missed both, so an AddrOf feeding a phi was
            // suppressed while the edge copy still read its slot — an
            // uninitialised pointer. `s = "..."; while (c) { ...; s = s + 1; }`
            // printed one character and stopped, because the loop's pointer phi
            // copied a slot the elided AddrOf never wrote.
            NSMutableArray<XTIRInsn *> *scan = [NSMutableArray array];
            [scan addObjectsFromArray:block.phiNodes];
            [scan addObjectsFromArray:block.instructions];
            if (block.terminator) [scan addObject:block.terminator];
            for (XTIRInsn *insn in scan) {
                BOOL isLoadStore =
                    insn.opcode == XTIROpLoad  || insn.opcode == XTIROpLoadVolatile ||
                    insn.opcode == XTIROpStore || insn.opcode == XTIROpStoreVolatile;
                for (NSUInteger k = 0; k < insn.operands.count; k++) {
                    XTIROperand *o = insn.operands[k];
                    if (o.kind != XTIROperandKindUse) continue;
                    NSNumber *vid = @(o.valueId);
                    if (![candidates containsObject:vid]) continue;
                    // Valid use = pointer operand (index 0) of a Load/Store
                    // in the AddrOf's own block.
                    BOOL sameBlock = candBlock[vid].unsignedIntegerValue == bi;
                    if (!(isLoadStore && k == 0 && sameBlock))
                        [disqualified addObject:vid];
                }
            }
            bi++;
        }
        for (NSNumber *vid in candidates)
            if (![disqualified containsObject:vid])
                [ctx.suppressedAddrOfs addObject:vid];
    }
}

#pragma mark - Public

// Emit the module's static data — pinned-local spill slots, data
// globals, string literals, vtables — into `out`. Factored out of
// assemblyFromModule so the banked path can place it in the unbanked
// region (after the `.org` back from the code banks) while the flat
// path keeps the historical trailing position. Output is byte-for-byte
// the same in both paths.
+ (void)emitModuleDataInto:(NSMutableString *)out
                    module:(XTIRModule *)mod
                spillDecls:(NSMutableArray<NSArray *> *)spillDecls
                   bankMap:(nullable NSDictionary<NSString *, NSNumber *> *)bankMap
{
    if (spillDecls.count > 0) {
        [out appendString:@"; Pinned-local spill slots (STACK-ABI §11.3)\n"];
        for (NSArray *d in spillDecls) {
            [out appendFormat:@"%@: .space %lu\n",
                d[0], (unsigned long)[d[1] unsignedIntegerValue]];
        }
    }
    BOOL emittedHeader = NO;
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindDataGlobal) continue;
        if (!sym.globalType) continue;
        NSUInteger size = [self byteWidthForType:sym.globalType];
        if (size == 0) size = 2;
        if (!emittedHeader) {
            [out appendString:@"; Module data\n"];
            emittedHeader = YES;
        }
        BOOL isFloat = XTIRTypeKindIsFloating(sym.globalType.kind);
        if (sym.initialBytes.length > 0) {
            NSData *bytes = sym.initialBytes;
            if (isFloat && bytes.length != size) {
                uint64_t raw = 0;
                [bytes getBytes:&raw length:MIN((NSUInteger)8, bytes.length)];
                bytes = [self encodeFloatBits:raw width:size];
            }
            const uint8_t *p = bytes.bytes;
            NSUInteger len = bytes.length;
            NSMutableString *vals = [NSMutableString string];
            for (NSUInteger i = 0; i < len; i++) {
                if (i > 0) [vals appendString:@","];
                [vals appendFormat:@"$%02X", p[i]];
            }
            for (NSUInteger i = len; i < size; i++) {
                [vals appendString:@",$00"];
            }
            [out appendFormat:@"_%@: .byte %@\n", sym.name, vals];
        } else {
            [out appendFormat:@"_%@: .space %u\n", sym.name, (unsigned)size];
        }
    }
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindStringLit) continue;
        if (!emittedHeader) {
            [out appendString:@"; Module data\n"];
            emittedHeader = YES;
        }
        const uint8_t *p = sym.stringBytes.bytes;
        NSUInteger len = sym.stringBytes.length;
        if (len == 0) {
            [out appendFormat:@"_%@: .byte $00\n", sym.name];
            continue;
        }
        NSMutableString *vals = [NSMutableString string];
        for (NSUInteger i = 0; i < len; i++) {
            if (i > 0) [vals appendString:@","];
            [vals appendFormat:@"$%02X", p[i]];
        }
        [out appendFormat:@"_%@: .byte %@\n", sym.name, vals];
    }
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindVTable) continue;
        if (!emittedHeader) {
            [out appendString:@"; Module data\n"];
            emittedHeader = YES;
        }
        NSArray<NSString *> *entries = sym.vtableEntryNames;
        // Each slot is 3 bytes — `.byte <bank>` then `.word <addr>`
        // (task #65). The bank lets VTblDispatch select $82 before the
        // indirect jump, so vtable-target methods can live in a code
        // bank instead of being pinned to the unbanked region. An
        // unbanked method (or the flat path, bankMap == nil) emits
        // bank 0, which the dispatch treats as a raw indirect jump.
        //
        // ⚠ A vtable SLOT is [bank, addr-lo, addr-hi], but a function-pointer
        // VALUE is [addr-lo, addr-hi, code-bank] (what AddrOf @fn builds and
        // CallIndirect expects). The byte orders are NOT the same. Anything
        // that reads a slot into a fn-pointer value must transpose — VTblLoad
        // (backing `&obj.method`) does; see XTIROpVTblLoad above and
        // private:docs/Design/bound-methods.md.
        if (entries.count == 0) {
            [out appendFormat:@"_%@: .byte $00\n    .word $0000\n", sym.name];
            continue;
        }
        [out appendFormat:@"_%@:\n", sym.name];
        for (NSUInteger i = 0; i < entries.count; i++) {
            NSString *e = entries[i];
            if (!e.length) {
                [out appendString:@"    .byte $00\n    .word $0000\n"];
                continue;
            }
            NSUInteger bank = bankMap[e].unsignedIntegerValue;  // nil → 0
            [out appendFormat:@"    .byte $%02lX\n    .word _%@\n",
             (unsigned long)bank, e];
        }
    }
    // ── Per-class destructor bank constants (task #122) ────────────
    // The corpus ARC allocator stages a 3-byte dealloc descriptor
    // `[bank, addr-lo, addr-hi]` in each class instance so __xtc_release
    // can dispatch the destructor at refcount 0. The address resolves
    // from the `_<Class>$dealloc` symbol, but the CODE BANK is only
    // known here (bankMap). Publishing it as a link-time constant
    // `__dbank_<Class>$dealloc` lets the allocator do
    // `LDA #__dbank_<Class>$dealloc` instead of the old hard-coded #$01
    // (private:docs/bugs/003: wrong once a destructor packs into bank 2+).
    // Emitted for EVERY function (not just `$dealloc`): `AddrOf @fn` now bakes
    // the code bank into byte 2 of the 3-byte function pointer (task #65 stage 2)
    // so a general fn-pointer / dealloc descriptor can bank-switch on dispatch.
    // nil bankMap entry → 0 (the unbanked main region).
    for (XTIRFunction *fn in mod.functions) {
        if (fn.blocks.count == 0) continue;
        NSUInteger bank = bankMap[fn.name].unsignedIntegerValue;  // nil → 0
        [out appendFormat:@"__dbank_%@ = $%02lX\n", fn.name, (unsigned long)bank];
    }
    // Emit aliases for global variables so inline asm references to the
    // source-level name (e.g. `STA r0`) resolve to the underscored label
    // (`_r0`) emitted above, instead of being treated as an undefined
    // symbol (which xta silently resolves to $0000).
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind == XTIRSymbolKindDataGlobal) {
            [out appendFormat:@"%@ = _%@\n", sym.name, sym.name];
        }
    }
}

// The module's entry function (the one the harness/startup JSRs into):
// `main` if present, else the first function with a body — mirroring
// the corpus/golden harness's pickEntryFunction. Banking keeps this
// function unbanked so the entry `JSR` reaches it directly.
+ (nullable XTIRFunction *)entryFunctionOf:(XTIRModule *)mod {
    XTIRFunction *first = nil;
    for (XTIRFunction *fn in mod.functions) {
        BOOL hasBody = fn.blocks.count > 0;
        if (!hasBody) continue;
        if ([fn.name isEqualToString:@"main"]) return fn;
        if (!first) first = fn;
    }
    return first;
}

// Safety net for the frame budget: the per-function N+K check keys off
// spFrameSize, which doesn't capture every emitted slot (a value staged high
// from the $B0 mailbox can sit beyond it). Scan the finished asm for the
// ACTUAL `[+-]N,SP` displacements — the xt's SP-relative mode is signed 8-bit,
// so any |N| > 127 is unassemblable. Catch it here with a clear message rather
// than letting xta reject `STA +128,SP` with a cryptic line error.
+ (BOOL)assertSpOffsetsInRange:(NSString *)asmText diag:(XTDiagnosticEngine *)diag {
    for (NSString *line in [asmText componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@";"] || t.length == 0) continue;          // comment / blank
        NSRange r = [line rangeOfString:@",SP"];
        if (r.location == NSNotFound) continue;
        NSInteger end = (NSInteger)r.location, start = end;
        while (start > 0) {
            unichar c = [line characterAtIndex:start - 1];
            if ((c >= '0' && c <= '9') || c == '+' || c == '-') start--; else break;
        }
        if (start >= end) continue;
        NSString *numStr = [line substringWithRange:NSMakeRange(start, end - start)];
        NSInteger off = [numStr integerValue];
        if (off > 127 || off < -128) {
            if (diag) [diag emitError:[NSString stringWithFormat:
                @"xt6502: SP-relative offset %ld is past the xt's signed-8-bit "
                @"reach (+127/-128) at '%@' — a function's frame is too large; "
                @"split it into smaller functions or reduce its locals/params",
                (long)off, t] at:synthLoc()];
            return NO;
        }
    }
    return YES;
}

+ (void)setDefaultXtcStack:(BOOL)on { sDefaultXtcStack = on; }
+ (void)setFnMinBanked:(NSUInteger)n { sFnMinBanked = n; }
+ (nullable NSString *)lastPlacementReport { return sPlacementReport; }

+ (nullable NSString *)assemblyFromModule:(XTIRModule *)mod
                              memoryModel:(nullable XTMemoryModel *)model
                              diagnostics:(XTDiagnosticEngine *)diag
{
    sPlacementReport = nil;
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"; Generated by XT6502Backend — DO NOT EDIT\n"];

    // ── Code banking (task #60) ───────────────────────────────────
    // Banking is active when the model declares a code-bank window AND
    // an unbanked code region (mainRegionRanges) to overflow from. arm64
    // and the flat test models leave hasBanking NO, so the flat else-
    // branch below is byte-identical to the pre-#60 emission. Computed
    // up front because the `.code_regions` emission below keys off it.
    BOOL banking = model.hasBanking
        && model.bankWindowStart != 0
        && model.mainRegionRanges.count > 0;

    // The code bank-select register comes from the layout — there is no
    // built-in $82 default. A banked layout that doesn't declare it (via
    // `registers = <code>, <data>` or codeReg=) is a hard error, not a
    // silent alias of the historical ZP pair.
    if (banking && model.codeBankReg == 0) {
        if (diag) [diag emitError:@"xt6502: banked layout defines no code "
            @"bank register — declare it in the .lnk (registers = …); there "
            @"is no built-in $82 default" at:synthLoc()];
        return nil;
    }

    // Memory-model-driven placement (task #55). Emit a `.code_regions`
    // declaration covering the model's main RAM region(s). xta's
    // overflow check (XAAssembler pass 1) then fails the build if
    // code+data grows past the last region's end — i.e. into screen
    // RAM (screenStart sits just past mainRegionRanges' end in the
    // layouts the backend targets). This is the screen-overrun guard
    // that keeps placement honest once spill lands on top (#56/#57).
    // The harness keeps its own `.org`/entry (a thin role); the
    // directive is zero-width, so it shifts no addresses and existing
    // goldens stay byte-for-byte identical in placement.
    //
    // BANKED path (task #121): the prepended runtime/harness owns a
    // single unified `.code_regions` that ALSO lists the $2400-$3FFF
    // system region (which the model's mainRegionRanges doesn't), so the
    // runtime stubs and the unbanked generated code form one contiguous
    // auto-spilling block. xta resets its region list on every
    // `.code_regions`, so a second one here would re-split the two
    // blocks and let the multi-KB float/double runtime silently overrun
    // $3FFF into screen RAM. Hence: emit the directive only on the flat
    // path; on the banked path the harness is authoritative.
    if (model.mainRegionRanges.count > 0) {
        [out appendFormat:@"; memory model: %@ (entry $%04X)\n",
            model.name ?: @"(unnamed)", model.entryAddress];
        if (banking) {
            [out appendString:@"; (banked: unified .code_regions provided "
                              @"by the runtime harness — task #121)\n"];
        } else {
            NSMutableString *regions = [NSMutableString string];
            for (NSArray<NSNumber *> *r in model.mainRegionRanges) {
                if (regions.length) [regions appendString:@", "];
                [regions appendFormat:@"$%04lX-$%04lX",
                    (unsigned long)r[0].unsignedIntegerValue,
                    (unsigned long)r[1].unsignedIntegerValue];
            }
            [out appendFormat:@".code_regions %@\n", regions];
        }
    }
    [out appendString:@"\n"];

    // Module-level indirect-call trampoline. VTblDispatch and
    // CallIndirect stage the target in $85/$86 then JSR here; the
    // JMP ($85) fakes a JSR (ind) the 6502 instruction set lacks.
    BOOL needsIndJmp = NO;
    for (XTIRFunction *fn in mod.functions) {
        for (XTIRBlock *blk in fn.blocks) {
            for (XTIRInsn *insn in blk.instructions) {
                if (insn.opcode == XTIROpVTblDispatch
                    || insn.opcode == XTIROpCallIndirect) {
                    needsIndJmp = YES; break;
                }
            }
            if (needsIndJmp) break;
        }
        if (needsIndJmp) break;
    }

    NSMutableArray<NSArray *> *spillDecls = [NSMutableArray array];

    if (banking) {
        uint16_t winStart = model.bankWindowStart;
        NSUInteger bankSize = (NSUInteger)model.bankWindowEnd - winStart + 1;
        // First-fit packing uses a per-function SIZE ESTIMATE (unbanked body
        // + a per-call pad) computed before bank assignment is known, so it
        // can't see which calls become cross-bank trampolines and how much
        // each expands. The estimate runs a few % short on call-heavy banks
        // (e.g. one carrying the whole Stdio library), which previously let a
        // bank pack to ~17.8 KB and overflow the 16 KB window at assemble
        // time. Pack against a budget held a safe margin below the real bank
        // size to absorb that estimation error; the unused tail just spills
        // into the next of the 16 available banks. The single-function-too-
        // big check below still uses the full bankSize.
        NSUInteger packBudget = bankSize > 2048 ? bankSize - 2048 : bankSize;
        uint16_t codeReg = model.codeBankReg;   // guaranteed nonzero (checked above)
        XTIRFunction *entry = [self entryFunctionOf:mod];

        // ── Sizing pass ── render each function with no bank map (all
        // calls direct) to measure its body, then add a conservative
        // per-call pad (cross-bank call sites are wider than a plain
        // JSR). Diagnostics + spill accumulation are suppressed here;
        // the real emission below owns them.
        NSMutableDictionary<NSString *, NSNumber *> *sizes =
            [NSMutableDictionary dictionary];
        // -Fmb: a function of fewer instructions than the threshold stays in
        // main RAM, so a call to it needs no _xcall trampoline. Counted once,
        // from this bank-independent render, so the decision cannot move
        // while the refinement below iterates.
        NSMutableDictionary<NSString *, NSNumber *> *insnCounts =
            [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *keepInMain = [NSMutableSet set];
        for (XTIRFunction *fn in mod.functions) {
            if (fn.blocks.count == 0) continue;
            NSMutableString *tmp = [NSMutableString string];
            NSMutableArray *throwaway = [NSMutableArray array];
            [self emitFunction:fn module:mod memoryModel:model
                    spillDecls:throwaway bankingActive:NO currentBank:0
                       bankMap:nil codeBankReg:codeReg into:tmp diagnostics:nil];
            NSUInteger insns = [self asmInsnCount:tmp];
            insnCounts[fn.name] = @(insns);
            if (sFnMinBanked > 0 && insns < sFnMinBanked) [keepInMain addObject:fn.name];
            NSUInteger calls = 0;
            for (XTIRBlock *blk in fn.blocks) {
                for (XTIRInsn *callInsn in blk.instructions) {
                    if (callInsn.opcode == XTIROpCall) calls++;
                }
            }
            sizes[fn.name] = @([self asmByteSize:tmp] + 16 * calls);
        }

        // ── Placement ── the entry stays unbanked (reached by a direct
        // JSR from the harness). Other functions fill the unbanked code
        // budget first, then overflow into 16 KB banks (first-fit by
        // module order). `bankEachUserFunction` is a test knob that puts
        // every non-entry function in its own bank, so a small program
        // can force two functions into different banks.
        NSUInteger dataBytes = 3;   // __xt_indjmp headroom
        for (XTIRSymbol *sym in mod.symbols) {
            if (sym.kind == XTIRSymbolKindDataGlobal && sym.globalType) {
                NSUInteger s = [self byteWidthForType:sym.globalType];
                dataBytes += s ?: 2;
            } else if (sym.kind == XTIRSymbolKindStringLit) {
                dataBytes += MAX((NSUInteger)1, sym.stringBytes.length);
            } else if (sym.kind == XTIRSymbolKindVTable) {
                dataBytes += MAX((NSUInteger)1, sym.vtableEntryNames.count) * 3;
            }
        }
        NSUInteger unbankedSize = 0;
        for (NSArray<NSNumber *> *r in model.mainRegionRanges) {
            unbankedSize += r[1].unsignedIntegerValue
                          - r[0].unsignedIntegerValue + 1;
        }
        // Budget for ALL unbanked code (entry + any others). The entry's
        // size is charged to unbankedUsed up front (below), so a large
        // entry simply leaves less room for further unbanked functions —
        // they overflow into banks. The margin absorbs the auto-spill
        // JMP bridges between mainRegionRanges plus residual estimate
        // slop; sizes are a conservative upper bound (branches counted
        // at their rewritten worst case), so the real unbanked block
        // never exceeds the region.
        // Placement (task #65): the unbanked region must hold the entry,
        // the must-stay-unbanked functions (CallIndirect targets — vtable
        // targets are now bankable via bank-aware dispatch), the lazily-
        // linked runtime asm helpers (whose size the compiler can't see),
        // and module data. Everything else banks. The old "fill the
        // unbanked budget first" heuristic kept a region's worth of
        // bankable functions unbanked with no room for the helper block,
        // so the largest fixtures overflowed `.code_regions`; banking
        // every non-entry, non-must-unbank function frees that room. It's
        // safe now because banked dispatch lets the methods live in banks
        // and call each other intra-bank (co-located by module order),
        // instead of the cross-bank storm that a force-unbanked dispatch
        // target would create.
        (void)unbankedSize; (void)dataBytes;
        NSSet<NSString *> *mustUnbank = [self mustStayUnbankedFunctionsIn:mod];

        NSMutableDictionary<NSString *, NSNumber *> *bankMap =
            [NSMutableDictionary dictionary];
        NSInteger unbankedUsed = 0;
        NSUInteger bankCount = 0;          // banks allocated so far
        NSUInteger curBankUsed = 0;        // bytes in the current (last) bank
        for (XTIRFunction *fn in mod.functions) {
            if (fn.blocks.count == 0) continue;
            NSUInteger sz = sizes[fn.name].unsignedIntegerValue;
            if (fn == entry || [mustUnbank containsObject:fn.name]
                || [keepInMain containsObject:fn.name]) {
                bankMap[fn.name] = @0;
                unbankedUsed += (NSInteger)sz;
                continue;
            }
            // Bank everything else (first-fit by module order). Start a
            // new bank when the function wouldn't fit the current one (or
            // when the each-fn-per-bank test knob is set).
            if (bankCount == 0 || model.bankEachUserFunction
                || curBankUsed + sz > packBudget) {
                bankCount++;
                curBankUsed = 0;
            }
            bankMap[fn.name] = @(bankCount);
            curBankUsed += sz;
            if (sz > bankSize && diag) {
                [diag emitError:[NSString stringWithFormat:
                    @"xt6502: function '%@' (~%lu bytes) exceeds the %lu-byte "
                    @"code bank — splitting across banks is a follow-up",
                    fn.name, (unsigned long)sz, (unsigned long)bankSize]
                             at:synthLoc()];
                return nil;
            }
        }

        // ── Iterative refinement ───────────────────────────────────
        // The initial pack uses a single-shot size estimate (no bank map,
        // plus a `16 * calls` per-call pad) and a 2 KB safety margin
        // because cross-bank call expansion isn't known until placement
        // is done. That estimate runs short on call-heavy banks (e.g.
        // one carrying the whole Stdio + Object + String library), and
        // the bank could pack to ~17.8 KB before any growth in Object /
        // String code pushed it past 16 KB at assemble time.
        //
        // Iterate to a fixpoint: re-render each function with the CURRENT
        // bank map so cross-bank trampoline expansions land in the size,
        // then re-pack against the full `bankSize` (no safety margin —
        // the measurements are exact). Continue until the bank map stops
        // changing or we hit an iteration cap. Same convergence model
        // xta's `rewriteLongBranches` uses. Once stable, the real
        // emission below can trust the assignment without re-checking.
        // Small residual safety margin — asmByteSize measures the
        // rendered output, but xta's downstream `rewriteLongBranches`
        // can expand a few branches before assembly. 1 KB absorbs that
        // tail without giving back the call-expansion gain.
        NSUInteger refinedBudget = bankSize > 1024 ? bankSize - 1024 : bankSize;
        NSUInteger maxIter = 8;
        for (NSUInteger iter = 0; iter < maxIter; iter++) {
            NSMutableDictionary<NSString *, NSNumber *> *measured =
                [NSMutableDictionary dictionary];
            for (XTIRFunction *fn in mod.functions) {
                if (fn.blocks.count == 0) continue;
                NSMutableString *tmp = [NSMutableString string];
                NSMutableArray *throwaway = [NSMutableArray array];
                NSUInteger fnBank = bankMap[fn.name].unsignedIntegerValue;
                [self emitFunction:fn module:mod memoryModel:model
                        spillDecls:throwaway bankingActive:YES
                       currentBank:fnBank bankMap:bankMap
                       codeBankReg:codeReg into:tmp diagnostics:nil];
                // Same per-call expansion pad the initial sizing pass uses
                // (16 * calls). emitFunction renders cross-bank calls in
                // their COMPACT `JSR _thunk` form; xta's rewriteCrossBankCalls
                // later expands each into a wider trampoline sequence, which
                // asmByteSize can't see. Without this pad a call-heavy bank
                // packs to ~bankSize on paper but assembles past the 16 KB
                // window (observed: float_arith, a ~166-call bank overflowing
                // by ~16×166 bytes after the phase-255 size shift repacked it).
                NSUInteger calls = 0;
                for (XTIRBlock *blk in fn.blocks)
                    for (XTIRInsn *ci in blk.instructions)
                        if (ci.opcode == XTIROpCall) calls++;
                measured[fn.name] = @([self asmByteSize:tmp] + 16 * calls);
            }
            NSMutableDictionary<NSString *, NSNumber *> *newBankMap =
                [NSMutableDictionary dictionary];
            NSUInteger newBankCount = 0;
            NSUInteger newCurUsed = 0;
            BOOL overflowSingle = NO;
            for (XTIRFunction *fn in mod.functions) {
                if (fn.blocks.count == 0) continue;
                NSUInteger sz = measured[fn.name].unsignedIntegerValue;
                if (fn == entry || [mustUnbank containsObject:fn.name]
                    || [keepInMain containsObject:fn.name]) {
                    newBankMap[fn.name] = @0;
                    continue;
                }
                if (sz > bankSize) {
                    if (diag) {
                        [diag emitError:[NSString stringWithFormat:
                            @"xt6502: function '%@' (~%lu bytes) exceeds the "
                            @"%lu-byte code bank — splitting across banks is "
                            @"a follow-up", fn.name, (unsigned long)sz,
                            (unsigned long)bankSize] at:synthLoc()];
                    }
                    overflowSingle = YES;
                    break;
                }
                if (newBankCount == 0 || model.bankEachUserFunction
                    || newCurUsed + sz > refinedBudget) {
                    newBankCount++;
                    newCurUsed = 0;
                }
                newBankMap[fn.name] = @(newBankCount);
                newCurUsed += sz;
            }
            if (overflowSingle) return nil;
            if ([newBankMap isEqual:bankMap]) break;
            bankMap = newBankMap;
        }

        // The refinement re-packs with cross-bank call-expansion sizes,
        // which can need MORE banks than the initial single-shot estimate.
        // The emission loop below iterates 1..bankCount, so bankCount MUST
        // track the FINAL bankMap — otherwise a function the refinement
        // pushed into a bank beyond the stale initial count is never
        // emitted (its label goes undefined → JSR $0000 → crash). Recompute
        // from the map so it is correct however the loop exited.
        bankCount = 0;
        for (NSNumber *b in bankMap.allValues) {
            NSUInteger bv = b.unsignedIntegerValue;
            if (bv > bankCount) bankCount = bv;
        }

        // ── Placement layout (task #121) ───────────────────────────
        // The unbanked generated code + module data must CONTINUE the
        // prepended runtime/harness's region flow (one contiguous
        // `.code_regions $2400-$3FFF, $D800-$FFF9` block owned by the
        // harness) so xta's auto-spill carries the whole unbanked program
        // across the screen ($4000-$5FFF) / bank-window ($6000-$9FFF) /
        // heap ($A000-$CFFF) gaps. A `.org` back to the main region here
        // would reset PC on top of the runtime's auto-spill and let the
        // multi-KB float/double runtime silently overflow into screen RAM.
        // So the emission order is:
        //   1. unbanked generated functions — NO `.org`, continuing flow;
        //   2. module data (spill slots, globals, strings, vtables);
        //   3. the banked `.org $6000` pages, a separate block.
        // Functions are rendered into buffers first so the module-data
        // pass (step 2) sees the COMPLETE spillDecls — accumulated from
        // BOTH the unbanked and the banked functions — before it's emitted
        // between them. __xt_indjmp / __xt_indcall are provided by the
        // harness template unconditionally.
        NSMutableString *unbankedBuf = [NSMutableString string];
        NSMutableString *bankedBuf   = [NSMutableString string];

        // What -dp reports: each function's placement, in emission order,
        // with the size of the text it finally rendered to.
        NSMutableArray<NSString *> *placeOrder = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSString *> *placeWhere = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *placeSize = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *placeNote = [NSMutableDictionary dictionary];

        // Unbanked generated functions (bank 0): the entry + any
        // must-stay-unbanked functions. No `.org` — continue the flow.
        for (XTIRFunction *fn in mod.functions) {
            if (fn.blocks.count == 0) continue;
            if (bankMap[fn.name].unsignedIntegerValue != 0) continue;
            NSUInteger before = unbankedBuf.length;
            if (![self emitFunction:fn module:mod memoryModel:model
                         spillDecls:spillDecls bankingActive:YES
                        currentBank:0 bankMap:bankMap codeBankReg:codeReg
                               into:unbankedBuf diagnostics:diag]) {
                return nil;
            }
            XTIRSymbol *fsym = [mod symbolForName:fn.name];
            BOOL irq = [fsym.attributes[@"irq"] boolValue];
            BOOL vbi = [fsym.attributes[@"vbi"] boolValue];
            [placeOrder addObject:fn.name];
            placeWhere[fn.name] = irq ? @"irq" : vbi ? @"vbi" : @"main";
            placeSize[fn.name] = @([self asmByteSize:
                [unbankedBuf substringFromIndex:before]]);
            if (fn == entry)
                placeNote[fn.name] = @"entry";
            else if (!irq && !vbi && [keepInMain containsObject:fn.name])
                placeNote[fn.name] = [NSString stringWithFormat:@"%lu instructions, under -Fmb %lu",
                    (unsigned long)insnCounts[fn.name].unsignedIntegerValue,
                    (unsigned long)sFnMinBanked];
        }

        // Banked code: each `.org <window>` is one bank (numbered by
        // encounter order = bank id), a separate block from the flow.
        for (NSUInteger b = 1; b <= bankCount; b++) {
            [bankedBuf appendFormat:@"; --- code bank %lu (via $%02X) ---\n",
                (unsigned long)b, codeReg];
            [bankedBuf appendFormat:@"    .org $%04X\n", winStart];
            for (XTIRFunction *fn in mod.functions) {
                if (fn.blocks.count == 0) continue;
                if (bankMap[fn.name].unsignedIntegerValue != b) continue;
                NSUInteger before = bankedBuf.length;
                if (![self emitFunction:fn module:mod memoryModel:model
                             spillDecls:spillDecls bankingActive:YES
                            currentBank:b bankMap:bankMap codeBankReg:codeReg
                                   into:bankedBuf diagnostics:diag]) {
                    return nil;
                }
                [placeOrder addObject:fn.name];
                placeWhere[fn.name] = [NSString stringWithFormat:@"bank %lu", (unsigned long)b];
                placeSize[fn.name] = @([self asmByteSize:
                    [bankedBuf substringFromIndex:before]]);
            }
        }
        sPlacementReport = [self placementReportFor:model order:placeOrder where:placeWhere
                                              sizes:placeSize notes:placeNote
                                            bankMap:bankMap bankSize:bankSize];

        // Stitch in flow order: unbanked code, then module data (now
        // spillDecls is complete), then the separate banked pages.
        [out appendString:@"; --- unbanked code + data (continues the "
                          @"harness region flow — no .org) ---\n"];
        [out appendString:unbankedBuf];
        [self emitModuleDataInto:out module:mod spillDecls:spillDecls bankMap:bankMap];
        [out appendString:bankedBuf];
        if (![self assertSpOffsetsInRange:out diag:diag]) return nil;
        return out;
    }

    // ── Flat path (no banking) — byte-identical to pre-#60. ───────────
    // Emit the indirect-jump trampoline here when the module actually has
    // a VTblDispatch / CallIndirect (needsIndJmp). The banked path's
    // corpus harness defines __xt_indjmp / __xt_indcall itself, but the
    // flat codegen-test harnesses don't — without this, `JSR __xt_indjmp`
    // resolved to an undefined symbol ($0000) and protocol/fn-pointer
    // dispatch jumped to $0000 → BRK. JMP ($85) fakes the `JSR (ind)` the
    // 6502 lacks; the flat path never uses the bank-aware __xt_indcall.
    if (needsIndJmp) {
        [out appendString:@"__xt_indjmp:\n"];
        [out appendString:@"    JMP ($85)\n"];
    }
    NSMutableArray<NSString *> *placeOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *placeWhere = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *placeSize = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *placeNote = [NSMutableDictionary dictionary];
    XTIRFunction *flatEntry = [self entryFunctionOf:mod];
    for (XTIRFunction *fn in mod.functions) {
        NSUInteger before = out.length;
        if (![self emitFunction:fn module:mod memoryModel:model
                     spillDecls:spillDecls bankingActive:NO currentBank:0
                        bankMap:nil codeBankReg:0 into:out diagnostics:diag]) {
            return nil;
        }
        if (fn.blocks.count == 0) continue;
        XTIRSymbol *fsym = [mod symbolForName:fn.name];
        [placeOrder addObject:fn.name];
        placeWhere[fn.name] = [fsym.attributes[@"irq"] boolValue] ? @"irq"
                            : [fsym.attributes[@"vbi"] boolValue] ? @"vbi" : @"main";
        placeSize[fn.name] = @([self asmByteSize:[out substringFromIndex:before]]);
        if (fn == flatEntry) placeNote[fn.name] = @"entry";
    }
    sPlacementReport = [self placementReportFor:model order:placeOrder where:placeWhere
                                          sizes:placeSize notes:placeNote
                                        bankMap:nil bankSize:0];
    [self emitModuleDataInto:out module:mod spillDecls:spillDecls bankMap:nil];
    if (![self assertSpOffsetsInRange:out diag:diag]) return nil;
    return out;
}

@end
