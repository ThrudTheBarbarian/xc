#import "XTLinkerScriptParser.h"
#import "XTCloakedRegion.h"

#include <errno.h>
#include <stdlib.h>

static NSString* const kLnkErrorDomain = @"XTLinkerScript";

#pragma mark — Value parsers

static BOOL parseHexOrDecimal(NSString* s, uint16_t* out)
    {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([s hasPrefix:@"$"])
        {
        unsigned int v;
        NSScanner* sc = [NSScanner scannerWithString:[s substringFromIndex:1]];
        if (![sc scanHexInt:&v] || !sc.isAtEnd)
            return NO;
        *out = (uint16_t)v;
        return YES;
        }
    NSScanner* sc = [NSScanner scannerWithString:s];
    int v;
    if (![sc scanInt:&v] || !sc.isAtEnd)
        return NO;
    *out = (uint16_t)v;
    return YES;
    }

/****************************************************************************\
|* Like parseHexOrDecimal but for byte counts that may exceed 16 bits —
|* region spans (e.g. `$200000` for 2 MB), heap sizes, etc. Accepts the
|* same `$hex` / decimal grammar.
\****************************************************************************/
static BOOL parseLongLongAddr(NSString* s, uint64_t* out)
    {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    const char* cstr;
    int base;
    if ([s hasPrefix:@"$"])
        {
        cstr = [[s substringFromIndex:1] UTF8String];
        base = 16;
        }
    else
        {
        cstr = [s UTF8String];
        base = 10;
        }
    if (!cstr || *cstr == '\0')
        return NO;
    char* end = NULL;
    errno = 0;
    unsigned long long v = strtoull(cstr, &end, base);
    if (errno != 0 || end == cstr || (end && *end != '\0'))
        return NO;
    *out = v;
    return YES;
    }

/****************************************************************************\
|* Parse `$XXXX-$YYYY` into start/end.
\****************************************************************************/
static BOOL parseRange(NSString* s, uint16_t* outStart, uint16_t* outEnd)
    {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // Find the dash between two $hex addresses. Scan for the pattern
    // "$hex-$hex" to disambiguate from a negative number.
    NSRegularExpression* re =
        [NSRegularExpression regularExpressionWithPattern:
                                 @"(\\$[0-9A-Fa-f]+)\\s*-\\s*(\\$[0-9A-Fa-f]+)"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult* m = [re firstMatchInString:s
                                             options:0
                                               range:NSMakeRange(0, s.length)];
    if (!m || m.numberOfRanges < 3)
        return NO;
    NSString* startStr = [s substringWithRange:[m rangeAtIndex:1]];
    NSString* endStr = [s substringWithRange:[m rangeAtIndex:2]];
    return parseHexOrDecimal(startStr, outStart) &&
           parseHexOrDecimal(endStr, outEnd);
    }

/****************************************************************************\
|* Parse a comma-separated list of ranges.
\****************************************************************************/
static NSArray<NSArray<NSNumber*>*>* parseRangeList(NSString* s)
    {
    NSMutableArray* result = [NSMutableArray array];
    for (NSString* part in [s componentsSeparatedByString:@","])
        {
        uint16_t start, end;
        if (parseRange(part, &start, &end))
            {
            [result addObject:@[ @(start), @(end) ]];
            }
        }
    return result;
    }

/****************************************************************************\
|* Parse `$XXXX` (full byte, mask=$FF) or `$XXXX:$MM` (bitmask).
\****************************************************************************/
static BOOL parseRegisterSpec(NSString* s, uint16_t* outAddr, uint8_t* outMask)
    {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray<NSString*>* parts = [s componentsSeparatedByString:@":"];
    if (parts.count == 1)
        {
        *outMask = 0xFF;
        return parseHexOrDecimal(parts[0], outAddr);
        }
    if (parts.count == 2)
        {
        uint16_t mask;
        if (!parseHexOrDecimal(parts[0], outAddr))
            return NO;
        if (!parseHexOrDecimal(parts[1], &mask))
            return NO;
        *outMask = (uint8_t)mask;
        return YES;
        }
    return NO;
    }

/****************************************************************************\
|* Parse a comma-separated list of register specs.
\****************************************************************************/
static NSArray<NSArray<NSNumber*>*>* parseRegisterSpecList(NSString* s)
    {
    NSMutableArray* result = [NSMutableArray array];
    for (NSString* part in [s componentsSeparatedByString:@","])
        {
        uint16_t addr;
        uint8_t mask;
        if (parseRegisterSpec(part, &addr, &mask))
            {
            [result addObject:@[ @(addr), @(mask) ]];
            }
        }
    return result;
    }

#pragma mark — Section handlers

static void handleZP(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"sp"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.zpSPStart = s;
            model.zpSPEnd = e;
            }
        }
    else if ([key isEqualToString:@"tmp"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.zpTmpStart = s;
            model.zpTmpEnd = e;
            }
        }
    else if ([key isEqualToString:@"hp"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.zpHPStart = s;
            model.zpHPEnd = e;
            }
        }
    else if ([key isEqualToString:@"arc-scratch"] ||
             [key isEqualToString:@"arcscratch"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.zpArcScratchStart = s;
            model.zpArcScratchEnd = e;
            }
        }
    else if ([key isEqualToString:@"vars"])
        {
        model.zpVarsRanges = parseRangeList(value);
        }
    else if ([key isEqualToString:@"runtime"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.zpRuntimeStart = s;
            model.zpRuntimeEnd = e;
            }
        }
    else if ([key isEqualToString:@"bankreg"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.zpBankRegStart = s;
            model.zpBankRegEnd = e;
            }
        }
    }

static void handleMemory(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"main"])
        {
        model.mainRegionRanges = parseRangeList(value);
        }
    else if ([key isEqualToString:@"system"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.systemStart = s;
            model.systemEnd = e;
            }
        }
    else if ([key isEqualToString:@"screen"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.screenStart = s;
            model.screenEnd = e;
            }
        }
    }

/****************************************************************************\
|* Recompute the legacy bankWindow* / bankRegisters view from the
|* split fields when hasSplitBanking is on. The legacy view spans
|* both halves (codeWindowStart..dataWindowEnd) and lists both
|* selectors, so consumers that only read the legacy fields still
|* get a coherent "full bank window" picture.
\****************************************************************************/
static void syncSplitToLegacy(XTMemoryModel* model)
    {
    if (!model.hasSplitBanking)
        return;
    if (model.codeWindowStart)
        model.bankWindowStart = model.codeWindowStart;
    if (model.dataWindowEnd)
        model.bankWindowEnd = model.dataWindowEnd;
    if (model.codeBankReg && model.dataBankReg)
        {
        model.bankRegisters = @[
            @[ @(model.codeBankReg), @(0xFF) ],
            @[ @(model.dataBankReg), @(0xFF) ],
        ];
        }
    }

// Generic banking-region convention: `<name>-window = $lo-$hi` and
// `<name>-reg = $addr`. `code` and `data` are the well-known regions
// (mapped to the legacy code/data window + register fields); any other
// name is preserved in extraBankRegions so targets can declare more than
// two windows without new parser keys.
static void setExtraBankField(XTMemoryModel* model, NSString* name,
                              NSString* field, uint16_t value)
    {
    if (!model.extraBankRegions)
        model.extraBankRegions = [NSMutableDictionary dictionary];
    NSMutableDictionary* r = model.extraBankRegions[name];
    if (!r)
        {
        r = [NSMutableDictionary dictionary];
        model.extraBankRegions[name] = r;
        }
    r[field] = @(value);
    }

static void handleBanking(XTMemoryModel* model, NSString* key, NSString* value)
    {
    model.hasBanking = YES;
    if ([key hasSuffix:@"-window"])
        {
        NSString* name = [key substringToIndex:key.length - 7]; // strip "-window"
        uint16_t s, e;
        if (!parseRange(value, &s, &e))
            return;
        uint16_t pageLen = (uint16_t)(e - s + 1);
        if ([name isEqualToString:@"code"])
            {
            model.bankWindowStart = s;
            model.bankWindowEnd = e;
            model.bankPageSize = pageLen; // page size = window length
            }
        else if ([name isEqualToString:@"data"])
            {
            model.dataWindowStart = s;
            model.dataWindowEnd = e;
            model.dataPageSize = pageLen;
            }
        else
            {
            setExtraBankField(model, name, @"windowStart", s);
            setExtraBankField(model, name, @"windowEnd", e);
            }
        return;
        }
    if ([key hasSuffix:@"-reg"])
        {
        NSString* name = [key substringToIndex:key.length - 4]; // strip "-reg"
        uint16_t v;
        if (!parseHexOrDecimal(value, &v))
            return;
        if ([name isEqualToString:@"code"])
            model.codeBankReg = v;
        else if ([name isEqualToString:@"data"])
            model.dataBankReg = v;
        else
            setExtraBankField(model, name, @"reg", v);
        return;
        }
    if ([key isEqualToString:@"window"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.bankWindowStart = s;
            model.bankWindowEnd = e;
            // A bank window holds exactly one page, so the page size IS the
            // window length — derive it rather than make the layout repeat
            // it. An explicit `pageSize` (below) still overrides if a layout
            // ever needs a window larger than one page.
            model.bankPageSize = (uint16_t)(e - s + 1);
            }
        }
    else if ([key isEqualToString:@"pagesize"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.bankPageSize = v;
        }
    else if ([key isEqualToString:@"registers"])
        {
        model.bankRegisters = parseRegisterSpecList(value);
        // Plain 8-bit selectors (mask $FF) name the code/data bank
        // registers directly — first = code, second = data. This lets a
        // single-window layout relocate the selectors (e.g. $D5C0/$D5C1
        // on xt) without the codeReg/dataReg keys, which would flag
        // split banking. Masked entries (e.g. xe's PORTB `$D301:0c`) are
        // left to the PORTB path and don't set these.
        NSArray<NSArray<NSNumber*>*>* regs = model.bankRegisters;
        if (regs.count >= 1 && [regs[0][1] unsignedCharValue] == 0xFF)
            {
            model.codeBankReg = [regs[0][0] unsignedShortValue];
            }
        if (regs.count >= 2 && [regs[1][1] unsignedCharValue] == 0xFF)
            {
            model.dataBankReg = [regs[1][0] unsignedShortValue];
            }
        }
    else if ([key isEqualToString:@"codewindow"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.hasSplitBanking = YES;
            model.codeWindowStart = s;
            model.codeWindowEnd = e;
            syncSplitToLegacy(model);
            }
        }
    else if ([key isEqualToString:@"datawindow"])
        {
        // Declares the data-bank aperture (xt: $A000-$CFFF via $D5C1).
        // Unlike codeWindow/codeReg this does NOT enable static
        // split-bank placement — on xt the data window is a RUNTIME
        // aperture (the banked heap), not a statically-packed segment
        // pool, so leaving hasSplitBanking off keeps the legacy code
        // bankWindow (set by `window`) intact. Static split-banking, if
        // ever needed, is enabled by codeWindow/codeReg/dataReg.
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.dataWindowStart = s;
            model.dataWindowEnd = e;
            // Page size = window length (one page per window); derived, not
            // declared. An explicit `dataPageSize` still overrides.
            model.dataPageSize = (uint16_t)(e - s + 1);
            }
        }
    else if ([key isEqualToString:@"datapagesize"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.dataPageSize = v;
        }
    else if ([key isEqualToString:@"codereg"])
        {
        // Names the code-window bank-select register. A plain declaration
        // — it does NOT, by itself, turn on static split-bank placement
        // (that is the codeWindow path). Lets each window own its register
        // (xt: codeReg = $D5C0, dataReg = $D5C1) without the `registers`
        // form lumping both under one window.
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.codeBankReg = v;
        }
    else if ([key isEqualToString:@"datareg"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.dataBankReg = v;
        }
    else if ([key isEqualToString:@"coderegion"] ||
             [key isEqualToString:@"coderegionspan"])
        {
        // Optional explicit region span for the code bank. Defaults to
        // pageSize × 256 when absent. Region values can exceed 16 bits
        // (e.g. $200000 = 2 MB) so we always use the long-long scanner.
        uint64_t u = 0;
        if (parseLongLongAddr(value, &u))
            model.codeRegionSpan = u;
        }
    else if ([key isEqualToString:@"dataregion"] ||
             [key isEqualToString:@"dataregionspan"])
        {
        uint64_t u = 0;
        if (parseLongLongAddr(value, &u))
            model.dataRegionSpan = u;
        }
    else if ([key isEqualToString:@"regcwindow"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.hasRegionCBanking = YES;
            model.regCWindowStart = s;
            model.regCWindowEnd = e;
            }
        }
    else if ([key isEqualToString:@"regcpagesize"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            {
            model.hasRegionCBanking = YES;
            model.regCPageSize = v;
            }
        }
    else if ([key isEqualToString:@"regcreg"])
        {
        // Either `$84` (8-bit selector) or `$84-$85` (16-bit pair).
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.hasRegionCBanking = YES;
            model.regCBankRegLo = s;
            model.regCBankRegHi = e;
            }
        else
            {
            uint16_t v;
            if (parseHexOrDecimal(value, &v))
                {
                model.hasRegionCBanking = YES;
                model.regCBankRegLo = v;
                model.regCBankRegHi = 0;
                }
            }
        }
    else if ([key isEqualToString:@"regcregion"] ||
             [key isEqualToString:@"regcregionspan"])
        {
        uint64_t u = 0;
        if (parseLongLongAddr(value, &u))
            {
            model.hasRegionCBanking = YES;
            model.regCRegionSpan = u;
            }
        }
    }

/****************************************************************************\
|* [cloaked] keys land in a pending XTCloakedRegion, committed to
|* model.cloakedRegions when the next section opens (or at EOF). Each
|* [cloaked] block in the layout becomes one or more regions:
|*
|*   range = $XXXX-$YYYY    address range in the bank window
|*   bank  = none|<N>       -1 (banking off) or a single numbered bank
|*   bank  = <N>-<M>        inclusive range; expands to M-N+1 regions,
|*                          one per bank, at commit time. `id` MUST
|*                          include a `<n>` placeholder — replaced
|*                          with the bank index for each expanded
|*                          region (e.g. `id = ext<n>` with bank = 4-12
|*                          → regions ext4, ext5, …, ext12). Pool
|*                          form for layouts with many code banks.
|*   id    = <name>         user-facing identifier for `:cloaked(<name>)`
|*
|* Legacy form (just `range = ...`) defaults to bank=none, id=lib.
\****************************************************************************/
static void handleCloaked(XTCloakedRegion* region, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"range"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            region.start = s;
            region.end = e;
            }
        }
    else if ([key isEqualToString:@"bank"])
        {
        NSString* v = [value stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
        if ([v.lowercaseString isEqualToString:@"none"])
            {
            region.bankIndex = -1;
            region.bankIndexEnd = -1;
            }
        else
            {
            // Range form: `bank = N-M` (commit-time expansion).
            NSRange dash = [v rangeOfString:@"-"];
            if (dash.location != NSNotFound)
                {
                NSString* lo = [v substringToIndex:dash.location];
                NSString* hi = [v substringFromIndex:dash.location + 1];
                uint16_t loIdx, hiIdx;
                if (parseHexOrDecimal(lo, &loIdx) &&
                    parseHexOrDecimal(hi, &hiIdx) &&
                    hiIdx >= loIdx)
                    {
                    region.bankIndex = (int)loIdx;
                    region.bankIndexEnd = (int)hiIdx;
                    }
                }
            else
                {
                uint16_t idx;
                if (parseHexOrDecimal(v, &idx))
                    {
                    region.bankIndex = (int)idx;
                    region.bankIndexEnd = (int)idx;
                    }
                }
            }
        }
    else if ([key isEqualToString:@"id"])
        {
        region.regionId = [value stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
        }
    }

/****************************************************************************\
|* Expand a pending [cloaked] block into one or more concrete
|* XTCloakedRegion objects. Single-bank pendings pass through; range
|* pendings produce one region per bank, with the `<n>` placeholder
|* in the id template substituted with the bank index.
|*
|* Returns nil and sets `*outErr` on validation failure (range without
|* placeholder, malformed range, etc).
\****************************************************************************/
static NSArray<XTCloakedRegion*>* expandPendingCloaked(XTCloakedRegion* pending,
                                                       NSString* path,
                                                       NSError** outErr)
    {
    if (pending.bankIndexEnd <= pending.bankIndex)
        {
        // Single-bank or banking-off — no expansion needed. Reject
        // bare `<n>` in the id (a placeholder requires a range).
        if ([pending.regionId containsString:@"<n>"])
            {
            if (outErr)
                {
                *outErr = [NSError errorWithDomain:@"XTLinkerScript"
                                              code:3
                                          userInfo:@{NSLocalizedDescriptionKey :
                                                         [NSString stringWithFormat:
                                                                       @"%@: [cloaked] id '%@' contains '<n>' but bank "
                                                                       @"is not a range — placeholder is only valid "
                                                                       @"with `bank = N-M`",
                                                                       path, pending.regionId]}];
                }
            return nil;
            }
        return @[ pending ];
        }
    // Range form: `<n>` placeholder is mandatory in the id, so each
    // expanded region gets a unique name.
    if (![pending.regionId containsString:@"<n>"])
        {
        if (outErr)
            {
            *outErr = [NSError errorWithDomain:@"XTLinkerScript"
                                          code:4
                                      userInfo:@{NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:
                                                                   @"%@: [cloaked] bank = %d-%d (range) needs '<n>' "
                                                                   @"placeholder in id (e.g. `id = ext<n>`); "
                                                                   @"got '%@'",
                                                                   path, pending.bankIndex, pending.bankIndexEnd,
                                                                   pending.regionId]}];
            }
        return nil;
        }
    NSMutableArray<XTCloakedRegion*>* expanded = [NSMutableArray array];
    for (int b = pending.bankIndex; b <= pending.bankIndexEnd; b++)
        {
        NSString* bankStr = [NSString stringWithFormat:@"%d", b];
        NSString* expandedId = [pending.regionId
            stringByReplacingOccurrencesOfString:@"<n>"
                                      withString:bankStr];
        [expanded addObject:[XTCloakedRegion regionWithStart:pending.start
                                                         end:pending.end
                                                   bankIndex:b
                                                    regionId:expandedId]];
        }
    return expanded;
    }

/****************************************************************************\
|* [weak] — retired. The weak-reference side table is gone: weak slots are
|* now threaded onto an intrusive list whose head lives in the object's heap
|* header, so there is no capacity to configure. `entries = N` is still
|* accepted and ignored, so existing .lnk layouts keep parsing.
\****************************************************************************/
static void handleWeak(XTMemoryModel* model, NSString* key, NSString* value)
    {
    (void)model;
    (void)key;
    (void)value;
    }

static void handleShadow(XTMemoryModel* model, NSString* key, NSString* value)
    {
    model.hasShadow = YES;
    if ([key isEqualToString:@"register"])
        {
        uint16_t addr;
        uint8_t mask;
        if (parseRegisterSpec(value, &addr, &mask))
            {
            model.shadowRegAddr = addr;
            model.shadowRegMask = mask;
            }
        }
    else if ([key isEqualToString:@"trampoline"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.trampolineStart = s;
            model.trampolineEnd = e;
            }
        }
    else if ([key isEqualToString:@"nmientry"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.nmiEntry = v;
        }
    else if ([key isEqualToString:@"irqentry"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.irqEntry = v;
        }
    else if ([key isEqualToString:@"ranges"])
        {
        // Address ranges of `main` that overlap shadow RAM. Used by
        // codegen to honour the :shadow placement annotation.
        model.shadowRanges = parseRangeList(value);
        }
    else if ([key isEqualToString:@"stage"])
        {
        // Plain-RAM staging address for compiled bytes that target the
        // shadow ranges. The OS XEX loader can't write to RAM-under-ROM,
        // so xta loads them here and copies into place via INITAD.
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.shadowStage = v;
        }
    }

static void handleStack(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"base"])
        {
        model.stackBase = [value stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
        }
    else if ([key isEqualToString:@"grows"])
        {
        NSString* dir = [[value stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        model.stackGrowsUp = [dir isEqualToString:@"up"];
        }
    else if ([key isEqualToString:@"bank"])
        {
        // Banked-stack target: `bank = <N>` puts the xtc software stack
        // in bank N of the bank window. Bank 0 is the canonical choice
        // on xe (see doc/xe-redesign.md) so stack pushes keep the
        // single-cycle direct `(sp),Y` form when the window defaults
        // to showing bank 0.
        NSString* trimmed = [value stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
        uint16_t v;
        if (parseHexOrDecimal(trimmed, &v))
            {
            model.stackBank = v;
            model.stackBankSet = YES;
            }
        }
    else if ([key isEqualToString:@"range"])
        {
        // Explicit address range for the stack memory. Used alongside
        // `bank` on banked-stack targets — the codegen emits
        // `stack_low = <range start>` so SP initialisation lands at
        // the bank window's base, and the end of the range caps the
        // stack's growth in the opposite direction from `grows`.
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.stackRangeStart = s;
            model.stackRangeEnd = e;
            model.stackRangeSet = YES;
            }
        }
    }

static void handleHeap(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"top"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.heapTop = v;
        }
    else if ([key isEqualToString:@"low"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.heapLow = v;
        }
    else if ([key isEqualToString:@"range"])
        {
        uint16_t s, e;
        if (parseRange(value, &s, &e))
            {
            model.heapLow = s;
            model.heapTop = e;
            }
        }
    else if ([key isEqualToString:@"bank"])
        {
        // Banked-heap target: `bank = <N>` says "bank N of the bank
        // window is the heap". `bank = <N>-<M>` reserves N through M
        // inclusive as a multi-bank heap pool. Codegen + startup use
        // this to select the first heap bank at boot, the packer
        // skips every reserved bank so no class / :banked function
        // lands there, and the allocator walks all reserved banks
        // looking for a fit.
        NSString* trimmed = [value stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
        // `bank = true` → on-demand banked heap: claim data banks from the
        // shared bitmap as needed, growing from bank 1 up to the data
        // window's last page ($FF for the 8-bit $D5C1 selector). No fixed
        // reservation; an application uses as much heap as it needs without
        // editing the layout.
        NSString* lc = trimmed.lowercaseString;
        if ([lc isEqualToString:@"true"] || [lc isEqualToString:@"on"] ||
            [lc isEqualToString:@"dynamic"])
            {
            model.heapBankDynamic = YES;
            model.heapBank = 1;
            model.heapBankEnd = 0xFF; // 8-bit data selector max page
            return;
            }
        NSRange dash = [trimmed rangeOfString:@"-"];
        if (dash.location != NSNotFound)
            {
            NSString* lo = [trimmed substringToIndex:dash.location];
            NSString* hi = [trimmed substringFromIndex:dash.location + 1];
            uint16_t loV, hiV;
            if (parseHexOrDecimal(lo, &loV) && parseHexOrDecimal(hi, &hiV))
                {
                model.heapBank = loV;
                model.heapBankEnd = hiV;
                }
            }
        else
            {
            uint16_t v;
            if (parseHexOrDecimal(trimmed, &v))
                {
                model.heapBank = v;
                model.heapBankEnd = v;
                }
            }
        }
    else if ([key isEqualToString:@"grows"])
        {
        NSString* dir = [[value stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        model.heapGrowsDown = [dir isEqualToString:@"down"];
        }
    else if ([key isEqualToString:@"pointer-width"])
        {
        // Heap-pointer storage width in bytes. 2 (default) is the
        // legacy implicit-bank-is-heap_bank_first layout — locals
        // store lo/hi only and member access reads the bank from a
        // global constant. 3 makes each Heap pointer carry its own
        // bank byte at slot+2, the same layout `banked:T@` already
        // uses, so multi-bank heaps work and inline:method() can
        // recover the receiver's bank at the call site.
        uint16_t v;
        if (parseHexOrDecimal(value, &v) && (v == 2 || v == 3))
            {
            model.heapPointerWidth = v;
            }
        }
    else if ([key isEqualToString:@"regcbank"])
        {
        // Region-C heap fallover banks. Same `N-M` / `N` syntax as
        // `bank`. Allocator walks the data-pool first then falls
        // through here on per-bank OOM. Bank ids stored in slot+2
        // of banked pointers get bit 7 set to mark region C; the
        // 7-bit slot caps usable banks at 127 (= 508 KB region-C
        // heap on 4 KB pages).
        NSString* trimmed = [value stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
        NSRange dash = [trimmed rangeOfString:@"-"];
        if (dash.location != NSNotFound)
            {
            NSString* lo = [trimmed substringToIndex:dash.location];
            NSString* hi = [trimmed substringFromIndex:dash.location + 1];
            uint16_t loV, hiV;
            if (parseHexOrDecimal(lo, &loV) && parseHexOrDecimal(hi, &hiV))
                {
                model.regCHeapBank = loV;
                model.regCHeapBankEnd = hiV;
                }
            }
        else
            {
            uint16_t v;
            if (parseHexOrDecimal(trimmed, &v))
                {
                model.regCHeapBank = v;
                model.regCHeapBankEnd = v;
                }
            }
        }
    }

static void handleEntry(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"address"])
        {
        uint16_t v;
        if (parseHexOrDecimal(value, &v))
            model.entryAddress = v;
        }
    }

static void handleStartup(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"file"])
        {
        model.startupFile = [value stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
        }
    }

static void handleBuffers(XTMemoryModel* model, NSString* key, NSString* value)
    {
    uint16_t s, e;
    if (parseRange(value, &s, &e))
        {
        NSMutableDictionary* bufs = model.buffers
                                        ? [model.buffers mutableCopy]
                                        : [NSMutableDictionary dictionary];
        bufs[key] = @[ @(s), @(e) ];
        model.buffers = bufs;
        }
    }

static void handleOutput(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"format"])
        {
        model.outputFormat = [value stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceCharacterSet]];
        }
    }

static void handleSymbols(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"file"])
        {
        model.symbolsFile = [value stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
        }
    }

static void handleLibrary(XTMemoryModel* model, NSString* key, NSString* value)
    {
    if ([key isEqualToString:@"path"])
        {
        model.libPath = [value stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
        }
    }

#pragma mark — Main parser

@implementation XTLinkerScriptParser

/****************************************************************************\
|* Parse a .lnk linker-script file and populate an XTMemoryModel.
|* Handles #include directives recursively, processes [section] blocks,
|* and derives backward-compat fields automatically.
|* @param path   Absolute or relative path to the .lnk file.
|* @param error  On failure, receives an NSError with filename and line info.
|* @return  A populated memory model, or nil on parse error.
\****************************************************************************/
+ (nullable XTMemoryModel*)parseFile:(NSString*)path
                               error:(NSError* _Nullable*)error
    {
    NSString* contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:error];
    if (!contents)
        return nil;

    XTMemoryModel* model = [[XTMemoryModel alloc] init];
    model.loadedFromLinkerScript = YES;
    model.lnkPath = path;

    // Process #include directives first: scan for lines starting
    // with `#include "file"` and recursively parse them. The
    // included model's values are loaded first; the current file's
    // values override on conflict (last-writer-wins per key).
    NSString* baseDir = [path stringByDeletingLastPathComponent];
    NSArray<NSString*>* rawLines = [contents componentsSeparatedByString:@"\n"];
    for (NSString* rawLine in rawLines)
        {
        NSString* trimmed = [rawLine stringByTrimmingCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"#include"])
            {
            NSRange q1 = [trimmed rangeOfString:@"\""];
            NSRange q2 = [trimmed rangeOfString:@"\""
                                        options:NSBackwardsSearch];
            if (q1.location != NSNotFound && q2.location != q1.location)
                {
                NSString* incName = [trimmed substringWithRange:
                                                 NSMakeRange(q1.location + 1,
                                                             q2.location - q1.location - 1)];
                NSString* incPath = [baseDir stringByAppendingPathComponent:incName];
                NSFileManager* fm = [NSFileManager defaultManager];
                // Sibling-layouts fallback: if the include name doesn't
                // resolve next to the including file, try the platform's
                // canonical layouts/ directory. Lets internal/-stashed
                // layouts (e.g. xt-heap kept around for spill_overflow)
                // still `#include "xt.lnk"` without spelling the
                // relative `../layouts/` path.
                if (![fm fileExistsAtPath:incPath])
                    {
                    NSString* parentDir = [baseDir stringByDeletingLastPathComponent];
                    NSString* siblingPath = [[parentDir stringByAppendingPathComponent:@"layouts"]
                        stringByAppendingPathComponent:incName];
                    if ([fm fileExistsAtPath:siblingPath])
                        incPath = siblingPath;
                    }
                NSError* incErr = nil;
                XTMemoryModel* base = [XTLinkerScriptParser parseFile:incPath
                                                                error:&incErr];
                if (!base)
                    {
                    if (error)
                        *error = incErr;
                    return nil;
                    }
                // Copy base model's values into our model as defaults.
                [model mergeDefaultsFrom:base];
                }
            }
        }

    NSString* currentSection = nil;
    // Track which sections have been fully overridden by the current
    // file. [stack] is all-or-nothing: a local `[stack]` block resets
    // the inherited values before processing its own keys, so a
    // layout that #includes a parent with bank-stack semantics but
    // declares its own [stack] (e.g. xe-heap #includes xe but
    // relocates the stack to main RAM) gets a clean slate rather
    // than a partial-override mix. Other sections stay partial-
    // override — users commonly want to inherit most of [zp] /
    // [memory] / [heap] and change one key.
    BOOL stackResetDone = NO;

    // Per-section accumulator for [cloaked]. Each [cloaked] block
    // produces one XTCloakedRegion, committed at the next section
    // header (or EOF). Defaults match the legacy single-region form:
    // bank=none (banking off), id=lib.
    XTCloakedRegion* pendingCloaked = nil;
    NSMutableArray<XTCloakedRegion*>* cloakedAccum = [NSMutableArray array];

    for (NSUInteger lineNum = 0; lineNum < rawLines.count; lineNum++)
        {
        NSString* line = rawLines[lineNum];

        // Skip #include directives (already processed above).
        NSString* trimCheck = [line stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceCharacterSet]];
        if ([trimCheck hasPrefix:@"#include"])
            continue;

        // Strip comments: everything from `#` to end-of-line.
        NSRange hashRange = [line rangeOfString:@"#"];
        if (hashRange.location != NSNotFound)
            {
            line = [line substringToIndex:hashRange.location];
            }
        line = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0)
            continue;

        // Section header: [name]
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"])
            {
            // Commit the previous [cloaked] block (if any) before
            // moving on. Done at every section transition so each
            // block becomes one or more regions in declaration order
            // (one for `bank = N`, M-N+1 for `bank = N-M`).
            if (pendingCloaked)
                {
                NSError* expandErr = nil;
                NSArray<XTCloakedRegion*>* expanded =
                    expandPendingCloaked(pendingCloaked, path, &expandErr);
                if (!expanded)
                    {
                    if (error)
                        *error = expandErr;
                    return nil;
                    }
                [cloakedAccum addObjectsFromArray:expanded];
                pendingCloaked = nil;
                }
            currentSection = [[line substringWithRange:
                                        NSMakeRange(1, line.length - 2)] lowercaseString];
            // First local [stack] header resets inherited stack
            // fields — see the stackResetDone declaration above.
            if ([currentSection isEqualToString:@"stack"] && !stackResetDone)
                {
                [model resetStackFields];
                stackResetDone = YES;
                }
            // Open a fresh cloaked region with the legacy defaults.
            // bank=none and id=lib match how the historical single-
            // [cloaked] form was interpreted.
            if ([currentSection isEqualToString:@"cloaked"])
                {
                pendingCloaked = [XTCloakedRegion regionWithStart:0
                                                              end:0
                                                        bankIndex:-1
                                                         regionId:@"lib"];
                }
            continue;
            }

        // Key = value
        NSRange eqRange = [line rangeOfString:@"="];
        if (eqRange.location == NSNotFound)
            {
            if (error)
                {
                *error = [NSError errorWithDomain:kLnkErrorDomain
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey :
                                                        [NSString stringWithFormat:@"%@:%lu: expected 'key = value'",
                                                                                   path, (unsigned long)(lineNum + 1)]}];
                }
            return nil;
            }

        NSString* key = [[line substringToIndex:eqRange.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString* value = [[line substringFromIndex:eqRange.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        key = key.lowercaseString;

        if (!currentSection)
            {
            if (error)
                {
                *error = [NSError errorWithDomain:kLnkErrorDomain
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey :
                                                        [NSString stringWithFormat:@"%@:%lu: key '%@' outside any section",
                                                                                   path, (unsigned long)(lineNum + 1), key]}];
                }
            return nil;
            }

        if ([currentSection isEqualToString:@"zp"])
            handleZP(model, key, value);
        else if ([currentSection isEqualToString:@"memory"])
            handleMemory(model, key, value);
        else if ([currentSection isEqualToString:@"banking"])
            handleBanking(model, key, value);
        else if ([currentSection isEqualToString:@"shadow"])
            handleShadow(model, key, value);
        else if ([currentSection isEqualToString:@"cloaked"])
            handleCloaked(pendingCloaked, key, value);
        else if ([currentSection isEqualToString:@"weak"])
            handleWeak(model, key, value);
        else if ([currentSection isEqualToString:@"stack"])
            handleStack(model, key, value);
        else if ([currentSection isEqualToString:@"heap"])
            handleHeap(model, key, value);
        else if ([currentSection isEqualToString:@"entry"])
            handleEntry(model, key, value);
        else if ([currentSection isEqualToString:@"startup"])
            handleStartup(model, key, value);
        else if ([currentSection isEqualToString:@"buffers"])
            handleBuffers(model, key, value);
        else if ([currentSection isEqualToString:@"output"])
            handleOutput(model, key, value);
        else if ([currentSection isEqualToString:@"symbols"])
            handleSymbols(model, key, value);
        else if ([currentSection isEqualToString:@"library"])
            handleLibrary(model, key, value);
        }

    // Commit any trailing [cloaked] block (the file ends without
    // another section header to trigger the in-loop commit).
    if (pendingCloaked)
        {
        NSError* expandErr = nil;
        NSArray<XTCloakedRegion*>* expanded =
            expandPendingCloaked(pendingCloaked, path, &expandErr);
        if (!expanded)
            {
            if (error)
                *error = expandErr;
            return nil;
            }
        [cloakedAccum addObjectsFromArray:expanded];
        pendingCloaked = nil;
        }
    if (cloakedAccum.count > 0)
        {
        // Order is preserved: first declared region is the preferred
        // pack target for `:cloaked` decls without an explicit id.
        // Validate id uniqueness across the whole accumulated set —
        // a duplicate would make `:cloaked(<id>)` ambiguous and the
        // codegen pre-scan would just take the first match silently.
        NSMutableSet<NSString*>* seenIds = [NSMutableSet set];
        for (XTCloakedRegion* r in cloakedAccum)
            {
            if ([seenIds containsObject:r.regionId])
                {
                if (error)
                    {
                    *error = [NSError errorWithDomain:@"XTLinkerScript"
                                                 code:5
                                             userInfo:@{NSLocalizedDescriptionKey :
                                                            [NSString stringWithFormat:
                                                                          @"%@: duplicate [cloaked] id '%@' "
                                                                          @"(check for overlapping `bank = N-M` "
                                                                          @"ranges or repeated `id = ` lines)",
                                                                          path, r.regionId]}];
                    }
                return nil;
                }
            [seenIds addObject:r.regionId];
            }
        model.cloakedRegions = [cloakedAccum copy];
        }

    // Set the model name from the .lnk filename (e.g. "c64" from
    // "c64.lnk") so downstream code can identify the platform.
    if (!model.name)
        {
        model.name = [[path lastPathComponent] stringByDeletingPathExtension];
        }

    // Default platform symbols file when the layout didn't declare
    // one. xta picks up names like CIOV / ICCOM / PORTB from the
    // platform's .sym, so the asm-block authors don't need to
    // hardcode hex addresses for OS / hardware vectors. Layouts
    // can override via `[symbols] file = ...`.
    if (!model.symbolsFile)
        {
        NSString* plat = model.platform.length > 0 ? model.platform : nil;
        if (!plat)
            {
            // Infer from path: support/<platform>/layouts/foo.lnk.
            NSArray<NSString*>* parts = [path pathComponents];
            for (NSUInteger i = 0; i + 1 < parts.count; i++)
                {
                if ([parts[i + 1] isEqualToString:@"layouts"])
                    {
                    plat = parts[i];
                    break;
                    }
                }
            }
        if ([plat isEqualToString:@"atari"] || [plat isEqualToString:@"6502"] || [plat isEqualToString:@"xt6502"])
            {
            // The 6502 (Atari xl/xe) and xt6502 platforms share the Atari
            // hardware symbol set (CIOV, PORTB, …); a copy of atari.sym lives
            // in each platform's symbols/ dir.
            model.symbolsFile = @"atari.sym";
            }
        else if ([plat isEqualToString:@"commodore"])
            {
            model.symbolsFile = @"c64.sym";
            }
        }

    // Derive backward-compat fields from the parsed data so
    // downstream code that checks `kind` / `isBanked` / `portBMask`
    // keeps working unchanged.
    [model deriveBackwardCompatFields];

    return model;
    }

@end
