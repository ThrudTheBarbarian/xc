/****************************************************************************\
|* XAAssembler+Private.h
\****************************************************************************/
#import "XAAssembler.h"
#import "XA6502.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XALineType) {
    XALineEmpty,
    XALineLabel,
    XALineInstruction,
    XALineDirectiveOrg,
    XALineDirectiveByte,
    XALineDirectiveWord,
    XALineDirectiveLong,
    XALineDirectiveString,
    XALineDirectiveMacro,
    XALineDirectiveEndMacro,
    XALineDirectiveInclude,
    // .code_regions $start-$end, $start-$end, … — declares the
    // ordered list of ranges where the assembler may place code.
    // Pass 1 starts emission in the first region (the current .org
    // normally targets it) and advances to the next region at the
    // first `.spill_point` that otherwise wouldn't fit. Purely a
    // sizing hint; emits no bytes.
    XALineDirectiveCodeRegions,
    // .spill_point — marks a safe boundary where the assembler may
    // auto-insert a new .org into the next code region if the next
    // chunk of code wouldn't fit in the current one. Emitted by the
    // xtc codegen between top-level functions, classes, and methods.
    XALineDirectiveSpillPoint,
    // Stage 4: .cloaked_segment <addr> — starts a library-bank
    // section at <addr> (typically $4000). Bytes parsed between this
    // directive and the matching .cloaked_segment_end go into a
    // segment marked isCloaked so writeBankedXEX brackets it with
    // PORTB=$30/$20 INITAD stubs. The effect is that the library
    // image loads directly into the bank window with banking off,
    // no memcpy, and then normal bank 0 mapping resumes before
    // RUNAD. .cloaked_segment acts as an `.org <addr>` for the
    // assembler's PC; .cloaked_segment_end returns to wherever the
    // PC was before.
    XALineDirectiveCloakedBegin,
    XALineDirectiveCloakedEnd,
    // .shadow_ranges $start-$end, $start-$end, … — address ranges that
    // overlap RAM-under-ROM. The OS XEX loader can't write to these
    // (it runs from ROM and can't disable ROM mid-load), so writeXEX /
    // writeBankedXEX split any segment overlapping a shadow range and
    // routes the overlapping bytes through a plain-RAM staging area
    // declared by `.shadow_stage`. Emits no bytes.
    XALineDirectiveShadowRanges,
    // .shadow_stage $XXXX — plain-RAM staging address for shadow-range
    // payload. xta packs all shadow-overlapping bytes into a single
    // staging segment loaded here, followed by an INITAD copy stub
    // that toggles PORTB bit 0 off, copies stage → target, and
    // restores ROM. Emits no bytes.
    XALineDirectiveShadowStage,
    // .space <N> — reserve N uninitialised bytes (fill with zero).
    // Emitted by the xtc codegen for global-variable declarations.
    // Advances PC by N so subsequent labels don't overlap.
    XALineDirectiveSpace,
    // .bank <identifier> — content from here until the next .org/.bank
    // belongs to the named bank (task #121). The assembler maps each
    // identifier to a physical bank number (allocated after the codegen's
    // encounter-order user banks, so no numeric clashes), places the
    // region at the bank window, and rewrites any JSR/JMP to a label
    // defined in the region — from outside it — into the _xcall
    // trampoline. Routines so banked must use a clobber-safe ABI (the
    // $B0-$BF ZP convention): the rewrite + _xcall clobber A.
    XALineDirectiveBank,
    XALineAssignment,
    XALineMacroInvocation,
};

@interface XAParsedLine : NSObject
@property(nonatomic) XALineType type;
@property(nonatomic, nullable) NSString* label;
@property(nonatomic) BOOL labelIsLocal; // starts with >
@property(nonatomic, nullable) NSString* mnemonic;
@property(nonatomic, nullable) NSString* operand;
@property(nonatomic) XAAddressingMode addressingMode;
@property(nonatomic) NSUInteger byteSize;
@property(nonatomic) NSUInteger sourceLine;
@property(nonatomic, nullable) NSString* rawText;
@property(nonatomic) BOOL isLongbrInverse;
// For directives
@property(nonatomic, nullable) NSArray<NSString*>* dataValues;
// For macros
@property(nonatomic, nullable) NSString* macroName;
@property(nonatomic, nullable) NSArray<NSString*>* macroParams;
// For assignments
@property(nonatomic, nullable) NSString* assignName;
@property(nonatomic, nullable) NSString* assignValue;
@end

// ── Macro definition ─────────────────────────────────────────────────
@interface XAMacro : NSObject
@property(nonatomic) NSString* macroName;
@property(nonatomic) NSArray<NSString*>* paramNames;
@property(nonatomic) NSMutableArray<NSString*>* bodyLines;
@end

@interface XAAssembler ()
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* symbols;
@property(nonatomic) NSMutableDictionary<NSString*, XAMacro*>* macros;
@property(nonatomic) NSMutableArray<NSString*>* mutableErrors;
@property(nonatomic) NSMutableArray<NSString*>* mutableWarnings;
@property(nonatomic) NSMutableArray<XAParsedLine*>* parsedLines;
@property(nonatomic) uint16_t pc;
@property(nonatomic) XA6502* cpu;
@property(nonatomic) NSUInteger longBranchCounter;
// For listing
@property(nonatomic) NSMutableArray<NSString*>* listingLines;
// Local label scoping: most recent non-local label
@property(nonatomic, nullable) NSString* lastGlobalLabel;
// Labels that shadow a Z80-style hex literal — warn once per name.
@property(nonatomic) NSMutableSet<NSString*>* ambiguousHexLabelsWarned;
// The line pass 2 is emitting, or nil outside pass 2. Every label is known by
// then, so a name the evaluator cannot resolve is undefined for good.
@property(nonatomic, nullable) XAParsedLine* evalLine;
@property(nonatomic, nullable) NSMutableSet<NSString*>* undefinedReported;
@property(nonatomic) BOOL evalUndefined; // the last pass-2 evaluate met an undefined name
// Code-region spillover: ordered list of (start, end) pairs parsed
// from the last .code_regions directive. The assembler starts in
// region 0 (whichever contains the active .org) and auto-advances
// at spill points when the next chunk would overflow. nil until
// the codegen emits a .code_regions line.
@property(nonatomic, nullable) NSArray<NSArray<NSNumber*>*>* codeRegions;
@property(nonatomic) NSUInteger currentRegionIndex;
// Shadow-range staging: parsed from `.shadow_ranges` and `.shadow_stage`
// directives emitted by the codegen. nil / 0 disables staging — segments
// overlapping shadow ranges then load directly (which only works on
// platforms with C64-style transparent write-through under ROM, not
// on real Atari).
@property(nonatomic, nullable) NSArray<NSArray<NSNumber*>*>* shadowRanges;
@property(nonatomic) uint16_t shadowStageBase;
// Named-bank machinery (task #121, `.bank <id>` directive).
//   bankIds   — identifier → allocated physical bank number. Allocation
//               continues past the codegen's encounter-order user banks
//               (counted as `.org`s into the bank window) so a `.bank`
//               region never collides with a user-function bank.
//   labelBank — label → bank number, for every label DEFINED inside a
//               `.bank` region. The cross-bank rewrite keys off this:
//               a JSR/JMP to such a label from a different bank becomes
//               the _xcall trampoline. Labels in plain `.org` user banks
//               are absent (the codegen stages those calls itself).
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* bankIds;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* labelBank;
@end

NS_ASSUME_NONNULL_END

#import "XAAssembler+Pass2.h"
#import "XAAssembler+Output.h"
