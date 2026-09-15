#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* One bank-window descriptor — a region of the 6502 address space
|* selected by a hardware bank-select register, indexing into a
|* larger off-chip RAM region (HyperRAM on xt, page-flopped Atari
|* extension RAM on xe / rambo*, etc.).
|*
|* `banks` on XTMemoryModel is an array of these. Built either:
|*   - automatically from the legacy codeWindow* / dataWindow* /
|*     codeBankReg / dataBankReg / bankPageSize fields by
|*     `deriveBackwardCompatFields` (one entry per code/data half), or
|*   - explicitly from a layout's [banking.code], [banking.data],
|*     [banking.regC], … sub-sections (or regC* keys in the flat
|*     [banking] section).
|*
|* The `regAddrHi == 0` case represents an 8-bit selector (the
|* normal case for `$82` / `$83` / xe PORTB). Non-zero `regAddrHi`
|* means the bank index is a 16-bit value with low byte at
|* `regAddrLo` and high byte at `regAddrHi` — used by xt's
|* region C (`$84`/`$85` pair).
\****************************************************************************/

typedef NS_ENUM(NSUInteger, XTBankKind) {
    XTBankKindCode = 0,
    XTBankKindData = 1,
};

@interface XTBankDescriptor : NSObject
@property(nonatomic) XTBankKind kind;
@property(nonatomic) uint16_t windowStart;
@property(nonatomic) uint16_t windowEnd; // inclusive
@property(nonatomic) uint16_t pageSize;  // bytes per page (e.g. $2000 / $1000)
@property(nonatomic) uint8_t regAddrLo;  // ZP byte holding the low byte of the selector
@property(nonatomic) uint8_t regAddrHi;  // ZP byte holding the high byte; 0 → 8-bit selector
/****************************************************************************\
|* Total addressable bytes through this register. For an 8-bit selector
|* the upper bound is `pageSize × 256`; for a 16-bit selector it can be
|* up to `pageSize × 65536`. Layouts declare this explicitly so the
|* same codegen scales as off-chip RAM grows (xt's $84/$85 pair sweeps
|* 4 MB at 8 MB HyperRAM, 12 MB at 16 MB, 28 MB at 32 MB, just by
|* changing the layout's region= value).
\****************************************************************************/
@property(nonatomic) uint64_t regionSpan;

/****************************************************************************\
|* YES iff the selector is a 16-bit register pair (regAddrHi != 0).
\****************************************************************************/
@property(nonatomic, readonly) BOOL is16Bit;

/****************************************************************************\
|* Number of pages addressable through this register's regionSpan.
|* `regionSpan / pageSize`, rounded down. 0 if regionSpan or pageSize
|* is unset.
\****************************************************************************/
@property(nonatomic, readonly) NSUInteger pageCount;

@end

NS_ASSUME_NONNULL_END
