#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* A contiguous block of assembled bytes at a given origin address.
\****************************************************************************/
@interface XASegment : NSObject
@property(nonatomic) uint16_t origin;
@property(nonatomic, readonly) NSMutableData* data;
/****************************************************************************\
|* Stage 4: cloaked segments hold :cloaked code in a layout-declared
|* region of the bank window. writeBankedXEX brackets each segment with
|* INITAD stubs that prep PORTB before the segment loads — banking off
|* for `cloakedBankIndex == -1` (library RAM at $4000), banking on with
|* the named bank selected for `cloakedBankIndex >= 0`. Default NO.
\****************************************************************************/
@property(nonatomic) BOOL isCloaked;
/****************************************************************************\
|* Bank index for a cloaked segment. -1 (default) means "banking off"
|* (the historical library-RAM region); >= 0 names a numbered hardware
|* bank in the bank window. Ignored unless `isCloaked` is YES.
\****************************************************************************/
@property(nonatomic) int cloakedBankIndex;
/****************************************************************************\
|* Explicit bank number for a `.bank <id>` segment (task #121): the
|* identifier→bank allocation assigns it, overriding writeBankedXEX's
|* encounter-order counter so the auto cross-bank rewrite (pass 1) and the
|* preload stub agree. -1 (default) = use the encounter-order counter
|* (plain `.org`-window banks, the codegen's user functions).
\****************************************************************************/
@property(nonatomic) NSInteger bankNumber;
/****************************************************************************\
|* Initialise a segment with the given load origin address.
|* @param origin  The 16-bit address where this segment loads.
|* @return  A segment with an empty data buffer.
\****************************************************************************/
- (instancetype)initWithOrigin:(uint16_t)origin;
@end

/****************************************************************************\
|* The xta 6502 assembler. Two-pass: pass 1 collects labels/sizes, pass 2 emits bytes.
\****************************************************************************/
@interface XAAssembler : NSObject

@property(nonatomic) BOOL verbose;
@property(nonatomic) BOOL bankedMode;
/****************************************************************************\
|* PORTB mask for the xe memory model. Zero (default) emits xt-style
|* $82/$83 preload stubs in writeBankedXEX; nonzero emits PORTB-style
|* stubs that write $D301, with bank indices compressed through this
|* mask. The two modes are mutually exclusive.
\****************************************************************************/
@property(nonatomic) uint8_t xeBankMask;
/****************************************************************************\
|* Bank window address range. Segments with origins inside this range
|* are treated as banked when writing a banked XEX.
\****************************************************************************/
@property(nonatomic) uint16_t bankWindowStart;
@property(nonatomic) uint16_t bankWindowEnd;
/****************************************************************************\
|* xt Option B split-bank fields. When hasSplitBanking is YES, banked
|* segments are classified by origin: segments whose .org falls in
|* [dataWindowStart, dataWindowEnd] get a $dataBankReg-only preload /
|* reset pair (one STA to the data selector); segments elsewhere
|* in the bank window keep the existing $codeBankReg-only preload /
|* reset. Collapsed xt leaves hasSplitBanking=NO and the writer
|* emits the legacy joint $82/$83 preload (bank id as a 16-bit
|* pair). The two selectors default to $82 / $83 so an uninitialised
|* split-banking assembler still produces coherent xt stubs.
\****************************************************************************/
@property(nonatomic) BOOL hasSplitBanking;
@property(nonatomic) uint16_t dataWindowStart;
@property(nonatomic) uint16_t dataWindowEnd;
@property(nonatomic) uint16_t codeBankReg; // default 0 → $82 when banked
@property(nonatomic) uint16_t dataBankReg; // default 0 → $83 when banked

/****************************************************************************\
|* Region-C bank window. When `regCWindowStart` is non-zero, segments
|* whose origin falls in [regCWindowStart, regCWindowEnd] are classified
|* as region-C-window and routed through `regCBankRegLo` /
|* `regCBankRegHi` instead of the code/data registers.
|*
|* `regCBankRegHi == 0` declares an 8-bit selector at `regCBankRegLo`
|* (the default 5-byte `LDA #imm / STA reg / RTS` preload stub).
|* `regCBankRegHi != 0` declares a 16-bit register pair — the preload
|* stub grows to 10 bytes (two `LDA / STA` pairs) and the per-pool
|* page counter is uint16 so it can address > 256 pages.
|*
|* Independent counter from code- and data-side pages, so the bank id
|* assignment matches the xtc codegen's per-pool numbering.
\****************************************************************************/
@property(nonatomic) uint16_t regCWindowStart;
@property(nonatomic) uint16_t regCWindowEnd;
@property(nonatomic) uint16_t regCBankRegLo;
@property(nonatomic) uint16_t regCBankRegHi;
/****************************************************************************\
|* Main code region bounds. Used for overflow detection in banked mode.
\****************************************************************************/
@property(nonatomic) uint16_t mainRegionStart;
@property(nonatomic) uint16_t mainRegionEnd;
@property(nonatomic, readonly) NSArray<NSString*>* errors;
@property(nonatomic, readonly) NSArray<NSString*>* warnings;

/****************************************************************************\
|* Include paths for .include directives.
\****************************************************************************/
@property(nonatomic, copy) NSArray<NSString*>* includePaths;

/****************************************************************************\
|* Pre-define a symbol (equivalent to -D).
\****************************************************************************/
- (void)defineSymbol:(NSString*)name value:(NSString*)value;

/****************************************************************************\
|* Assemble source text. Returns an array of XASegment on success, nil on error.
\****************************************************************************/
- (nullable NSArray<XASegment*>*)assembleSource:(NSString*)source
                                       filename:(NSString*)filename;

// writeXEX:entryPoint:toFile:, writeBankedXEX:..., writePRG:... live on
// XAAssembler (Output) — see XAAssembler+Output.h imported via +Private.h.

/****************************************************************************\
|* Path to a .sym file of predefined hardware symbols. When set,
|* replaces the default Atari symbol table. Resolved relative to
|* the support/symbols/ directory. Equivalent to symbolsFiles
|* containing one entry — kept for back-compat with the standalone
|* `xta -s` flag.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* symbolsFile;

/****************************************************************************\
|* List of .sym file paths to load and merge into the platform
|* symbol table. The compiler driver populates this from every
|* .sym it finds under support/<platform>/symbols/ and
|* support/generic/symbols/, so dropping a new `pokey.sym` next
|* to atari.sym is enough to make its symbols visible to xta.
|* When both symbolsFile and symbolsFiles are set, both are
|* merged (later entries override earlier ones on conflict).
\****************************************************************************/
@property(nonatomic, copy, nullable) NSArray<NSString*>* symbolsFiles;

// generateListing lives on XAAssembler (Output) — see header imported below.

@end

NS_ASSUME_NONNULL_END

#import "XAAssembler+Output.h"
