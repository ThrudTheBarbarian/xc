#import <Foundation/Foundation.h>
#import "XTBankDescriptor.h"
#import "XTCloakedRegion.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, XTMemoryModelKind) {
    XTMemoryModelKindXL = 0, // flat 64 KB Atari 8-bit
    XTMemoryModelKindXT,     // bank-switched via $82/$83 ZP pair
    XTMemoryModelKindXE,     // bank-switched via PORTB ($D301) bits
};

/****************************************************************************\
|* Parsed memory-model descriptor. Populated either from a `.lnk`
|* linker-script file or from the legacy `-m <spec>` hardcoded
|* path. Downstream code reads the backward-compat fields (`kind`,
|* `isBanked`, `portBMask`, etc.) which are derived automatically
|* when loaded from a `.lnk`.
\****************************************************************************/
@interface XTMemoryModel : NSObject

// ── Backward-compat fields (derived from .lnk or set directly) ──
@property(nonatomic) XTMemoryModelKind kind;
@property(nonatomic) NSString* name;
@property(nonatomic, nullable) NSString* platform; // "atari", "c64", etc.
@property(nonatomic) NSUInteger sizeKB;
@property(nonatomic) uint8_t portBMask;
@property(nonatomic, readonly) NSUInteger bankCount;
@property(nonatomic, readonly) BOOL isBanked;

/****************************************************************************\
|* .lnk-sourced fields 
|* [zp]
\****************************************************************************/
@property(nonatomic) uint16_t zpSPStart;
@property(nonatomic) uint16_t zpSPEnd;
@property(nonatomic) uint16_t zpTmpStart;
@property(nonatomic) uint16_t zpTmpEnd;
@property(nonatomic) uint16_t zpHPStart;
@property(nonatomic) uint16_t zpHPEnd;
// ARC release-path scratch ([zp] arc-scratch). A dedicated ZP window the
// reference-counting teardown uses for the object + dealloc-descriptor
// pointers that must survive a user dealloc dispatch (which clobbers the
// staging ZP and the var pool). Kept out of zpVarsRanges. 0 if unset.
@property(nonatomic) uint16_t zpArcScratchStart;
@property(nonatomic) uint16_t zpArcScratchEnd;
@property(nonatomic) NSArray<NSArray<NSNumber*>*>* zpVarsRanges;
@property(nonatomic) uint16_t zpRuntimeStart;
@property(nonatomic) uint16_t zpRuntimeEnd;
@property(nonatomic) uint16_t zpBankRegStart;
@property(nonatomic) uint16_t zpBankRegEnd;

// [memory]
@property(nonatomic) NSArray<NSArray<NSNumber*>*>* mainRegionRanges;
@property(nonatomic) uint16_t systemStart;
@property(nonatomic) uint16_t systemEnd;
@property(nonatomic) uint16_t screenStart;
@property(nonatomic) uint16_t screenEnd;

// [banking]
@property(nonatomic) BOOL hasBanking;
@property(nonatomic) uint16_t bankWindowStart;
@property(nonatomic) uint16_t bankWindowEnd;
/****************************************************************************\
|* Test-only code-banking knob (task #60): when YES the xt6502 backend
|* places every non-entry function in its own code bank, regardless of
|* size. Lets a focused golden force two small functions into different
|* banks to exercise the cross-bank `_xcall` path. Production layouts
|* leave this NO (size-driven first-fit packing into 16 KB banks).
\****************************************************************************/
@property(nonatomic) BOOL bankEachUserFunction;
@property(nonatomic) uint16_t bankPageSize;
@property(nonatomic, nullable) NSArray<NSArray<NSNumber*>*>* bankRegisters;

// Generic banking regions ([banking] `<name>-window` / `<name>-reg`).
// `code` and `data` map to the legacy fields below; any other region name
// is preserved here for targets that declare more than two windows. Keyed
// by region name → @{ @"windowStart":@(s), @"windowEnd":@(e), @"reg":@(r) }.
@property(nonatomic, nullable) NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSNumber*>*>* extraBankRegions;

/****************************************************************************\
|* Split-bank (xt Option B) fields. When hasSplitBanking is YES, the
|* bank window is two independent halves: codeWindow selected by
|* codeBankReg, dataWindow selected by dataBankReg. Page size is the
|* 8 KB half-window. The legacy bankWindow* / bankRegisters fields
|* are also populated (covering the full 16 KB window with both
|* registers listed) so non-split-aware code still sees a coherent
|* view.
\****************************************************************************/
@property(nonatomic) BOOL hasSplitBanking;
@property(nonatomic) uint16_t codeWindowStart;
@property(nonatomic) uint16_t codeWindowEnd;
@property(nonatomic) uint16_t dataWindowStart;
@property(nonatomic) uint16_t dataWindowEnd;
// Bytes per data-bank page (the $A000-$CFFF aperture is one 12 KB page
// on xt). Distinct from bankPageSize, which sizes the code window. 0 if
// the layout declares no data window.
@property(nonatomic) uint16_t dataPageSize;
@property(nonatomic) uint16_t codeBankReg;
@property(nonatomic) uint16_t dataBankReg;

/****************************************************************************\
|* Region span (bytes) through each bank register. Optional in the .lnk;
|* defaults to `pageSize × 256` when absent (preserves the legacy assumption
|* of an 8-bit page index per register). Set explicitly to scale a layout
|* to larger off-chip RAM without changing pageSize / window addresses.
\****************************************************************************/
@property(nonatomic) uint64_t codeRegionSpan;
@property(nonatomic) uint64_t dataRegionSpan;

/****************************************************************************\
|* Extended-bank fields (xt region C). When `hasRegionCBanking` is YES,
|* a third bank window selected by an 8-bit or 16-bit register pair sits
|* between the data window and the screen / main regions. Used by
|* xt-extended to expose HyperRAM beyond the 3 MB that $82 (2 MB) and
|* $83 (1 MB) can reach, through a single 4 KB window at $7000-$7FFF,
|* indexed by the $84/$85 register pair. The 16-bit pair lets the same
|* hardware front 5 / 13 / 29 MB of region C on 8 / 16 / 32 MB HyperRAMs
|* — only `regCRegionSpan` changes per layout.
|*
|* `regCBankRegHi == 0` means the extended selector is a single 8-bit byte
|* (page index 0..255 like $82 / $83). Non-zero means the selector is the
|* 16-bit pair { regCBankRegLo, regCBankRegHi } in little-endian order.
\****************************************************************************/
@property(nonatomic) BOOL hasRegionCBanking;
@property(nonatomic) uint16_t regCWindowStart;
@property(nonatomic) uint16_t regCWindowEnd;
@property(nonatomic) uint16_t regCPageSize;
@property(nonatomic) uint16_t regCBankRegLo;
@property(nonatomic) uint16_t regCBankRegHi; // 0 → 8-bit selector
@property(nonatomic) uint64_t regCRegionSpan;

/****************************************************************************\
|* Unified per-bank descriptor view of all bank windows the layout
|* declares (code + data + extended). Auto-built by
|* `deriveBackwardCompatFields` from the legacy fields above; new code
|* (PR1+) consumes this array instead of branching on individual scalars.
|* The legacy fields stay as the parser's write target and remain
|* authoritative — banks[] is a derived view.
\****************************************************************************/
@property(nonatomic, nullable) NSArray<XTBankDescriptor*>* banks;

// [shadow]
@property(nonatomic) BOOL hasShadow;
@property(nonatomic) uint16_t shadowRegAddr;
@property(nonatomic) uint8_t shadowRegMask;
@property(nonatomic) uint16_t trampolineStart;
@property(nonatomic) uint16_t trampolineEnd;
@property(nonatomic) uint16_t nmiEntry;
@property(nonatomic) uint16_t irqEntry;
/****************************************************************************\
|* Address ranges of `main` that overlap shadow RAM (under OS ROM). Used by
|* the codegen to honour the `:shadow` placement annotation: such decls are
|* steered into one of these ranges with an explicit .org. nil on non-shadow
|* targets — `:shadow`-annotated decls then warn and fall through to default.
\****************************************************************************/
@property(nonatomic, nullable) NSArray<NSArray<NSNumber*>*>* shadowRanges;

/****************************************************************************\
|* Plain-RAM staging address for shadow-region segments. The OS XEX loader
|* runs from ROM and cannot disable ROM mid-load, so it cannot write to
|* RAM-under-ROM at shadowRanges. Compiled bytes that would land there are
|* instead loaded to `shadowStage`, then copied into place by an INITAD stub
|* that briefly toggles PORTB bit 0 off. Zero (the default) disables staging.
\****************************************************************************/
@property(nonatomic) uint16_t shadowStage;

// [cloaked]  — :cloaked library code regions for xe-family targets.
//
// Each [cloaked] section in the layout becomes one XTCloakedRegion in
// `cloakedRegions`. A region's `bankIndex` is -1 ("banking off",
// historical PORTB = $30 mode) or a numbered bank in the window
// (xe-family: bits deposited into PORTB). The `regionId` is the name
// `:cloaked(<id>)` annotations refer to.
//
// `hasCloakedRegion`, `cloakedStart`, `cloakedEnd` are derived back-
// compat shims that read from `cloakedRegions[0]`. New code should
// query `cloakedRegions` directly.
//
// xta emits one preload-stub INITAD segment per region: a banking-off
// stub for `bankIndex == -1`, a 5-byte numbered-bank stub
// (`LDA #<portb> / STA $D301 / RTS`) otherwise.
//
// Targets that never saw a [cloaked] section (xl, xt, xe-nobank) keep
// `cloakedRegions` empty — codegen rejects any `:cloaked` placement
// in those layouts via the pre-scan.
@property(nonatomic, copy) NSArray<XTCloakedRegion*>* cloakedRegions;
@property(nonatomic, readonly) BOOL hasCloakedRegion;
@property(nonatomic, readonly) uint16_t cloakedStart;
@property(nonatomic, readonly) uint16_t cloakedEnd;

// [stack]
@property(nonatomic, nullable) NSString* stackBase;
@property(nonatomic) BOOL stackGrowsUp; // YES = up (default), NO = down
/****************************************************************************\
|* Banked-stack target (xe post-redesign): `bank = N` puts the xtc
|* software stack in bank N of the bank window. Codegen + startup
|* keep the bank mapped as the default window state so stack pushes
|* and pops stay a direct `(sp),Y` without a PORTB bracket. Zero is
|* a valid bank id, so `stackBankSet` distinguishes "explicitly
|* requested bank 0" from "stack lives in fixed main-RAM".
\****************************************************************************/
@property(nonatomic) uint16_t stackBank;
@property(nonatomic) BOOL stackBankSet;
/****************************************************************************\
|* Explicit `range = $X-$Y` for the stack memory. Used on banked-
|* stack targets where the stack lives in the bank window: the
|* codegen emits `stack_low = <start>` and bounds the stack at
|* `<end>` in the growth direction. Both zero + stackRangeSet == NO
|* on targets that keep the stack in a named memory region like
|* `after-system`.
\****************************************************************************/
@property(nonatomic) uint16_t stackRangeStart;
@property(nonatomic) uint16_t stackRangeEnd;
@property(nonatomic) BOOL stackRangeSet;

// [heap]
@property(nonatomic) uint16_t heapTop;
@property(nonatomic) uint16_t heapLow;   // 0 = no dedicated heap region (bump)
@property(nonatomic) BOOL heapGrowsDown; // YES = down (default), NO = up
/****************************************************************************\
|* First bank id reserved for the heap when the layout declares a banked-
|* heap target. 0 means "no banked heap" — the layout uses the flat heap
|* region described by heapLow / heapTop instead. Non-zero means the heap
|* physically lives in one or more banks of the bank window, starting
|* with this bank id.
\****************************************************************************/
@property(nonatomic) uint16_t heapBank;
/****************************************************************************\
|* Last (inclusive) bank id reserved for the heap. When heapBank ==
|* heapBankEnd, exactly one bank is reserved (the single-bank case
|* that phase-1 shipped). When heapBankEnd > heapBank, multiple
|* consecutive banks are reserved as a distributed heap pool — the
|* allocator walks them in order until a fit is found, and block
|* pointers carry the bank they were allocated from. Zero is the
|* "no banked heap" sentinel.
\****************************************************************************/
@property(nonatomic) uint16_t heapBankEnd;
/****************************************************************************\
|* On-demand banked heap (`[heap] bank = true`). When YES the heap is not a
|* fixed reservation: it claims data banks from the shared bank bitmap as
|* new()/alloc needs them (lowest-fit, so its banks stay contiguous from
|* heapBank up to a high-water marker) and gives empty top banks back.
|* heapBankEnd is then the MAXIMUM bank id it may grow to (the data
|* window's last page), not a pre-reserved range.
\****************************************************************************/
@property(nonatomic) BOOL heapBankDynamic;
/****************************************************************************\
|* Region-C heap bank range (`[heap] regCBank = N-M`). When non-zero,
|* the allocator falls through to these banks after exhausting the
|* data-pool banks (heapBank..heapBankEnd). Bank ids stored in
|* slot+2 of banked pointers carry bit 7 set to mark "region C",
|* with bits 0-6 as the 1-based bank-within-region (so the cap is
|* 127 banks × 4 KB = 508 KB region-C heap, the option-(a) wire
|* format limit). Zero means "no region-C heap" — the heap stops
|* at heapBankEnd, byte-identical to the pre-region-C layout.
\****************************************************************************/
@property(nonatomic) uint16_t regCHeapBank;
@property(nonatomic) uint16_t regCHeapBankEnd;

/****************************************************************************\
|* Width of a Heap-placement pointer in bytes. Default 2 (the legacy
|* "implicit bank = heap_bank_first" layout: locals store lo/hi only,
|* member access through a pointer reads the bank from a global
|* `heap_bank_first` constant). 3 means each Heap pointer carries its
|* own bank byte at slot+2, matching the long-standing Banked-placement
|* layout — required for multi-bank heaps where allocations can spill
|* past `heap_bank_first` and for inline:method() bracketing on banked-
|* heap targets. Set via `pointer-width = 3` in a layout's [memory]
|* section. Flat-heap targets ignore the flag (their pointers stay
|* 2-byte regardless).
\****************************************************************************/
@property(nonatomic) NSUInteger heapPointerWidth;

// [entry]
@property(nonatomic) uint16_t entryAddress;

// [startup]
@property(nonatomic, nullable) NSString* startupFile;

/****************************************************************************\
|* [buffers] — named address ranges for I/O marshalling buffers.
|* Key = buffer name (e.g. "printf"), value = @[@(start), @(end)].
\****************************************************************************/
@property(nonatomic, nullable) NSDictionary<NSString*, NSArray<NSNumber*>*>* buffers;

// [output]
@property(nonatomic, nullable) NSString* outputFormat; // "xex", "prg", etc.

// [symbols]
@property(nonatomic, nullable) NSString* symbolsFile; // e.g. "c64.sym"

// [library]
@property(nonatomic, nullable) NSString* libPath; // e.g. "c64" → support/lib/c64/

// Metadata
@property(nonatomic) BOOL loadedFromLinkerScript;
@property(nonatomic, nullable) NSString* lnkPath;

/****************************************************************************\
|* Derive `kind`, `portBMask`, `sizeKB` from the .lnk-sourced
|* fields so existing codegen keeps working.
\****************************************************************************/
- (void)deriveBackwardCompatFields;

/****************************************************************************\
|* Copy non-zero / non-nil fields from `base` into `self` as
|* defaults. Fields that `self` has already set are not overwritten.
|* Used for `#include` merging: the included file's values are the
|* defaults, and the includer's values win on conflict.
\****************************************************************************/
- (void)mergeDefaultsFrom:(XTMemoryModel*)base;

/****************************************************************************\
|* Clear every [stack]-derived field. The parser calls this on the
|* first `[stack]` section header in a file that #includes another
|* layout, so a local [stack] block fully overrides the inherited
|* values rather than mixing with them.
\****************************************************************************/
- (void)resetStackFields;

/****************************************************************************\
|* Parse a `-m` argument via the legacy hardcoded path. Accepts
|* `xl`, `xt`, `xe`, `xe:<size>:<mask>` and the named aliases.
|* Returns nil and prints a diagnostic if the spec is malformed.
\****************************************************************************/
+ (nullable instancetype)modelFromSpec:(NSString*)spec;

/****************************************************************************\
|* Convenience factory for the default (xl).
\****************************************************************************/
+ (instancetype)defaultModel;

/****************************************************************************\
|* Generate an ASCII memory-map diagram from the model's fields.
|* Returns a multi-line string suitable for printing to stdout or
|* embedding in a .lnk comment header.
\****************************************************************************/
- (NSString*)generateMemoryMapDiagram;

/****************************************************************************\
|* Format a bank-register address as an asm operand (e.g. "$83" or
|* "$D301"). Returns the zero-page form for addresses ≤ $FF and the
|* absolute form otherwise. Used by codegen and runtime-helper emitters
|* so the bank-register address is layout-driven rather than hardcoded.
\****************************************************************************/
+ (NSString*)formatRegisterOperand:(uint16_t)addr;
- (NSString*)codeBankRegOperand;
- (NSString*)dataBankRegOperand;
- (NSString*)regCBankRegLoOperand;
- (NSString*)regCBankRegHiOperand;

@end

NS_ASSUME_NONNULL_END
