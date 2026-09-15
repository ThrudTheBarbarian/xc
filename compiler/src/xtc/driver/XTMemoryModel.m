#import "XTMemoryModel.h"

@implementation XTMemoryModel

- (instancetype)init {
    if ((self = [super init])) {
        _cloakedRegions = @[];
        // _heapPointerWidth left at 0 ("unset") so MERGE_SCALAR
        // can distinguish the layout-explicit case from the
        // unset-default case. The accessor below normalises
        // unset to 2 — the legacy implicit-heap-bank shape.
    }
    return self;
}

- (NSUInteger)heapPointerWidth {
    return _heapPointerWidth ?: 2;
}

/****************************************************************************\
|* Back-compat shims for the legacy single-cloaked-region API.
|* hasCloakedRegion / cloakedStart / cloakedEnd now read off the first
|* element of cloakedRegions. New code should consult cloakedRegions
|* directly so it can see all declared windows (canonical xe declares
|* one banking-off region today; PR1 wires up an `ext1` numbered-bank
|* region alongside it).
\****************************************************************************/
- (BOOL)hasCloakedRegion {
    return _cloakedRegions.count > 0;
}

- (uint16_t)cloakedStart {
    return _cloakedRegions.firstObject.start;
}

- (uint16_t)cloakedEnd {
    return _cloakedRegions.firstObject.end;
}

/****************************************************************************\
|* Populate .lnk fields for the xl (flat) memory model.
|* Three declared buffers share the Atari workspace $0480-$05FF:
|*   printf     $0480-$04BF  — 64-byte variadic pack buffer. All
|*                             variadic functions share this slot;
|*                             sema's validateVariadicNonReentrance
|*                             guarantees no two live consumers
|*                             overlap, so the single buffer is
|*                             safely reused top-down.
|*   stdio_fmt  $04C0-$04FF  — 64-byte Stdio formatter scratch.
|*                             _printfU16 / _printfU32 / _printfHex*
|*                             / fp2Asc / dp2Asc all write their
|*                             NUL-terminated ATASCII output here;
|*                             the class wrappers then flush byte by
|*                             byte through putChar.
|*   stack      $0500-$05FF  — 256-byte static-frame buffer. Each
|*                             function that qualifies for static-
|*                             frame allocation (no recursion, no
|*                             address-taken callee, no external
|*                             call, no dynamic-JSR asm in its
|*                             transitive reach) gets a fixed slot
|*                             in this buffer and emits its frame
|*                             save / restore as plain LDA/STA
|*                             pairs instead of the xtc-stack push
|*                             loop. Non-eligible functions keep
|*                             the xtc-stack convention.
|* Page 6 ($0600-$06FF) is left unclaimed as overflow headroom.
\****************************************************************************/
static NSDictionary *defaultBuffers(void) {
    return @{ @"printf":    @[@0x0480, @0x04BF],
              @"stdio_fmt": @[@0x04C0, @0x04FF],
              @"stack":     @[@0x0500, @0x05FF] };
}

static void populateXLFields(XTMemoryModel *m) {
    // [zp]
    m.zpSPStart  = 0x82; m.zpSPEnd  = 0x83;
    m.zpTmpStart = 0x84; m.zpTmpEnd = 0x85;
    m.zpHPStart  = 0x86; m.zpHPEnd  = 0x87;
    m.zpVarsRanges = @[@[@0x88, @0xAF], @[@0xC0, @0xFF]];
    m.zpRuntimeStart = 0xB0; m.zpRuntimeEnd = 0xBF;
    // [memory]
    m.mainRegionRanges = @[@[@0x2000, @0x9FFF]];
    // [stack] / [heap]
    m.stackBase = @"after-code";
    m.stackGrowsUp = YES;
    m.heapTop = 0x9FFF;
    m.heapGrowsDown = YES;
    // [entry]
    m.entryAddress = 0x2000;
    // [buffers]
    m.buffers = defaultBuffers();
    // [symbols] — default for the atari platform. Layouts can
    // override via `[symbols] file = ...`. xta resolves the path
    // relative to support/<platform>/symbols/.
    if (!m.symbolsFile) m.symbolsFile = @"atari.sym";
}

/****************************************************************************\
|* Populate .lnk fields for the xt (bank-switched via ZP pair) memory model.
\****************************************************************************/
static void populateXTFields(XTMemoryModel *m) {
    // [zp]
    m.zpSPStart  = 0x89; m.zpSPEnd  = 0x8A;
    m.zpTmpStart = 0x8B; m.zpTmpEnd = 0x8C;
    m.zpHPStart  = 0x8D; m.zpHPEnd  = 0x8E;
    m.zpBankRegStart = 0x82; m.zpBankRegEnd = 0x83;
    m.zpVarsRanges = @[@[@0x8F, @0x9F], @[@0xC0, @0xFF]];
    m.zpRuntimeStart = 0xB0; m.zpRuntimeEnd = 0xBF;
    // [memory]
    m.systemStart = 0x2000; m.systemEnd = 0x3FFF;
    m.mainRegionRanges = @[@[@0xA000, @0xBFFF]];
    m.screenStart = 0x8000; m.screenEnd = 0x9FFF;
    // [banking]
    m.hasBanking = YES;
    m.bankWindowStart = 0x4000; m.bankWindowEnd = 0x7FFF;
    m.bankPageSize = 0x4000;
    m.bankRegisters = @[@[@0x82, @0xFF], @[@0x83, @0xFF]];
    // [stack] / [heap]
    m.stackBase = @"after-system";
    m.stackGrowsUp = YES;
    m.heapTop = 0x3FFF;
    m.heapGrowsDown = YES;
    // [entry]
    m.entryAddress = 0x2000;
    // [buffers]
    m.buffers = defaultBuffers();
}

/****************************************************************************\
|* Populate .lnk fields for an xe (PORTB bank-switched) model.
|* Shares xt's memory layout but uses xl-style ZP.
\****************************************************************************/
static void populateXEFields(XTMemoryModel *m) {
    // ZP is xl-style (no bank registers in ZP)
    populateXLFields(m);
    // Memory layout is xt-style
    m.systemStart = 0x2000; m.systemEnd = 0x3FFF;
    m.mainRegionRanges = @[@[@0xA000, @0xBFFF]];
    m.screenStart = 0x8000; m.screenEnd = 0x9FFF;
    // [banking]
    m.hasBanking = YES;
    m.bankWindowStart = 0x4000; m.bankWindowEnd = 0x7FFF;
    m.bankPageSize = 0x4000;
    m.bankRegisters = @[@[@0xD301, @(m.portBMask)]];
    // [stack] / [heap] — same as xt
    m.stackBase = @"after-system";
    m.stackGrowsUp = YES;
    m.heapTop = 0x3FFF;
    m.heapGrowsDown = YES;
    // [entry]
    m.entryAddress = 0x2000;
}

/****************************************************************************\
|* Convenience factory for the default (xl) memory model.
|* @return  A fully populated xl memory model instance.
\****************************************************************************/
+ (instancetype)defaultModel {
    XTMemoryModel *m = [[XTMemoryModel alloc] init];
    m.kind = XTMemoryModelKindXL;
    m.name = @"xl";
    m.platform = @"6502";
    populateXLFields(m);
    return m;
}

/****************************************************************************\
|* Whether this model uses bank-switched memory (xt or xe).
|* @return  YES for xt and xe models, NO for xl.
\****************************************************************************/
- (BOOL)isBanked {
    return _kind == XTMemoryModelKindXT || _kind == XTMemoryModelKindXE;
}

/****************************************************************************\
|* Number of 16KB bank pages available on the xe model.
|* @return  The bank count derived from sizeKB, or 0 for non-xe models.
\****************************************************************************/
- (NSUInteger)bankCount {
    if (_kind != XTMemoryModelKindXE) return 0;
    if (_sizeKB <= 64) return 0;
    return (_sizeKB - 64) / 16;
}

/****************************************************************************\
|* Table of named xe aliases. Order doesn't matter.
\****************************************************************************/
static const struct {
    const char *alias;
    unsigned sizeKB;
    uint8_t mask;
} kXeAliases[] = {
    { "xe",       128,  0x0C },
    { "rambo192", 192,  0x4C },
    { "rambo256", 256,  0x6C },
    { "rambo320", 320,  0x6C },
    { "rambo576", 576,  0x6E },
    { "rambo1088",1088, 0xEE },
    { "compy320", 320,  0xC6 },
    { "compy576", 576,  0xCE },
};
static const NSUInteger kXeAliasCount = sizeof(kXeAliases) / sizeof(kXeAliases[0]);

/****************************************************************************\
|* Parse `<size>:<mask>` from after the leading `xe:`. Returns YES on
|* success. `mask` is parsed as hex without a `$` or `0x` prefix.
\****************************************************************************/
static BOOL parseXeTriplet(NSString *tail, NSUInteger *outSize, uint8_t *outMask) {
    NSArray<NSString *> *parts = [tail componentsSeparatedByString:@":"];
    if (parts.count != 2) return NO;
    NSScanner *sizeScan = [NSScanner scannerWithString:parts[0]];
    long long sz;
    if (![sizeScan scanLongLong:&sz] || !sizeScan.isAtEnd) return NO;
    if (sz <= 64 || sz > 4096) return NO;

    NSScanner *maskScan = [NSScanner scannerWithString:parts[1]];
    unsigned int mask;
    if (![maskScan scanHexInt:&mask] || !maskScan.isAtEnd) return NO;
    // Disallow mask bits 4 and 5 — bit 5 is the ANTIC/CPU mapping bit
    // (always held set during banked operation) and bit 4 is the
    // master "banking enable" flip (0 = bank window live, 1 = main
    // RAM). If the user put them in the mask, the runtime would
    // trample its own control bits.
    if (mask & 0x30) return NO;
    if (mask == 0) return NO;

    *outSize = (NSUInteger)sz;
    *outMask = (uint8_t)mask;
    return YES;
}

/****************************************************************************\
|* Parse a `-m` argument via the legacy hardcoded path. Accepts
|* `xl`, `xt`, `xe`, `xe:<size>:<mask>` and the named aliases.
|* @param spec  The memory model specifier string.
|* @return  A populated model, or nil (with stderr diagnostic) if malformed.
\****************************************************************************/
+ (nullable instancetype)modelFromSpec:(NSString *)spec {
    if (spec.length == 0) return nil;

    if ([spec isEqualToString:@"xl"]) {
        XTMemoryModel *m = [[XTMemoryModel alloc] init];
        m.kind = XTMemoryModelKindXL;
        m.name = @"xl";
        m.platform = @"6502";
        populateXLFields(m);
        return m;
    }
    if ([spec isEqualToString:@"xt"]) {
        XTMemoryModel *m = [[XTMemoryModel alloc] init];
        m.kind = XTMemoryModelKindXT;
        m.name = @"xt";
        m.platform = @"xt6502";
        populateXTFields(m);
        return m;
    }

    // Named xe aliases.
    for (NSUInteger i = 0; i < kXeAliasCount; i++) {
        if ([spec isEqualToString:@(kXeAliases[i].alias)]) {
            XTMemoryModel *m = [[XTMemoryModel alloc] init];
            m.kind = XTMemoryModelKindXE;
            m.name = spec;
            m.platform = @"6502";
            m.sizeKB = kXeAliases[i].sizeKB;
            m.portBMask = kXeAliases[i].mask;
            populateXEFields(m);
            return m;
        }
    }

    // General `xe:<size>:<mask>` triplet.
    if ([spec hasPrefix:@"xe:"]) {
        NSUInteger size; uint8_t mask;
        if (!parseXeTriplet([spec substringFromIndex:3], &size, &mask)) {
            fprintf(stderr, "xcc: error: malformed memory-model spec '%s' "
                    "(expected xe:<size>:<hex-mask>)\n", spec.UTF8String);
            return nil;
        }
        XTMemoryModel *m = [[XTMemoryModel alloc] init];
        m.kind = XTMemoryModelKindXE;
        m.name = spec;
        m.platform = @"6502";
        m.sizeKB = size;
        m.portBMask = mask;
        populateXEFields(m);
        return m;
    }

    fprintf(stderr, "xcc: error: unknown memory model '%s' "
            "(expected xl, xt, xe, xe:<size>:<mask>, or a named "
            "alias such as rambo192)\n", spec.UTF8String);
    return nil;
}

/****************************************************************************\
|* Generate an ASCII memory-map diagram from the model's fields.
|* @return  A multi-line string suitable for printing to stdout.
\****************************************************************************/
- (NSString *)generateMemoryMapDiagram {
    NSMutableString *d = [NSMutableString string];
    NSString *modelName = _name ?: @"unknown";
    NSString *lnkFile = _lnkPath ? [_lnkPath lastPathComponent] : @"(hardcoded)";

    [d appendFormat:@"# %@ — %@\n#\n", lnkFile, modelName];

    // Collect all named regions into a sorted list of (start, end, label) tuples.
    NSMutableArray<NSDictionary *> *regions = [NSMutableArray array];

    // ZP
    if (_zpSPStart || _zpSPEnd) {
        [regions addObject:@{@"start": @(_zpSPStart), @"end": @(_zpSPEnd), @"label": @"xtc ZP: SP"}];
    }
    if (_zpTmpStart || _zpTmpEnd) {
        [regions addObject:@{@"start": @(_zpTmpStart), @"end": @(_zpTmpEnd), @"label": @"xtc ZP: tmp"}];
    }
    if (_zpHPStart || _zpHPEnd) {
        [regions addObject:@{@"start": @(_zpHPStart), @"end": @(_zpHPEnd), @"label": @"xtc ZP: HP"}];
    }
    if (_zpRuntimeStart || _zpRuntimeEnd) {
        [regions addObject:@{@"start": @(_zpRuntimeStart), @"end": @(_zpRuntimeEnd), @"label": @"runtime params (reserved)"}];
    }
    if (_hasSplitBanking) {
        // xt: render the code- and data-bank selectors on separate lines
        // so the user can see which window each ZP byte selects.
        [regions addObject:@{
            @"start": @(_codeBankReg), @"end": @(_codeBankReg),
            @"label": [NSString stringWithFormat:@"code bank selector ($%04X-$%04X)",
                       _codeWindowStart, _codeWindowEnd]
        }];
        [regions addObject:@{
            @"start": @(_dataBankReg), @"end": @(_dataBankReg),
            @"label": [NSString stringWithFormat:@"data bank selector ($%04X-$%04X)",
                       _dataWindowStart, _dataWindowEnd]
        }];
    } else if (_zpBankRegStart || _zpBankRegEnd) {
        [regions addObject:@{@"start": @(_zpBankRegStart), @"end": @(_zpBankRegEnd), @"label": @"bank-select register"}];
    }
    if (_hasRegionCBanking && _regCBankRegLo) {
        uint16_t lo = _regCBankRegLo;
        uint16_t hi = _regCBankRegHi ? _regCBankRegHi : _regCBankRegLo;
        // Address range $0084-$0085 already signals the 16-bit pair shape;
        // keep the label short enough to fit the 50-char box.
        [regions addObject:@{
            @"start": @(lo), @"end": @(hi),
            @"label": [NSString stringWithFormat:@"region-C bank selector ($%04X-$%04X)",
                       _regCWindowStart, _regCWindowEnd]
        }];
    }
    for (NSArray<NSNumber *> *r in _zpVarsRanges) {
        [regions addObject:@{@"start": r[0], @"end": r[1], @"label": @"xtc ZP: vars"}];
    }

    // Memory regions
    for (NSArray<NSNumber *> *r in _mainRegionRanges) {
        [regions addObject:@{@"start": r[0], @"end": r[1], @"label": @"Main region"}];
    }
    if (_systemStart || _systemEnd) {
        [regions addObject:@{@"start": @(_systemStart), @"end": @(_systemEnd), @"label": @"System region"}];
    }
    if (_screenStart || _screenEnd) {
        [regions addObject:@{@"start": @(_screenStart), @"end": @(_screenEnd), @"label": @"Screen RAM"}];
    }
    if (_hasBanking && _hasSplitBanking) {
        // Split-bank xt: render the two halves as independent regions.
        [regions addObject:@{
            @"start": @(_codeWindowStart), @"end": @(_codeWindowEnd),
            @"label": [NSString stringWithFormat:@"Code bank window (via $%02X)", _codeBankReg]
        }];
        [regions addObject:@{
            @"start": @(_dataWindowStart), @"end": @(_dataWindowEnd),
            @"label": [NSString stringWithFormat:@"Data bank window (via $%02X)", _dataBankReg]
        }];
    }
    if (_hasRegionCBanking) {
        NSString *label;
        if (_regCBankRegHi) {
            label = [NSString stringWithFormat:@"Region C bank window (via $%02X/$%02X)",
                     _regCBankRegLo, _regCBankRegHi];
        } else {
            label = [NSString stringWithFormat:@"Region C bank window (via $%02X)",
                     _regCBankRegLo];
        }
        [regions addObject:@{
            @"start": @(_regCWindowStart), @"end": @(_regCWindowEnd),
            @"label": label
        }];
    }
    if (_hasBanking && !_hasSplitBanking) {
        NSString *bankLabel;
        if (_bankRegisters.count > 0) {
            NSNumber *addr = _bankRegisters[0][0];
            NSNumber *mask = _bankRegisters[0][1];
            if (addr.unsignedIntegerValue > 0xFF) {
                bankLabel = [NSString stringWithFormat:@"Bank window (via $%04X:$%02X)",
                             addr.unsignedIntValue, mask.unsignedCharValue];
            } else {
                bankLabel = [NSString stringWithFormat:@"Bank window (via $%02X)",
                             addr.unsignedCharValue];
            }
        } else {
            bankLabel = @"Bank window";
        }
        [regions addObject:@{@"start": @(_bankWindowStart), @"end": @(_bankWindowEnd), @"label": bankLabel}];
    }
    if (_hasShadow && _trampolineStart) {
        [regions addObject:@{@"start": @(_trampolineStart), @"end": @(_trampolineEnd),
                              @"label": @"NMI/IRQ trampoline stub"}];
    }

    // Sort by start address.
    [regions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];

    // Fixed-width diagram lines.
    NSUInteger boxWidth = 50;
    NSString *top = [NSString stringWithFormat:@"# %C%@%C",
                     (unichar)0x250C,
                     [@"" stringByPaddingToLength:boxWidth withString:@"\u2500" startingAtIndex:0],
                     (unichar)0x2510];
    NSString *sep = [NSString stringWithFormat:@"# %C%@%C",
                     (unichar)0x251C,
                     [@"" stringByPaddingToLength:boxWidth withString:@"\u2500" startingAtIndex:0],
                     (unichar)0x2524];
    NSString *bot = [NSString stringWithFormat:@"# %C%@%C",
                     (unichar)0x2514,
                     [@"" stringByPaddingToLength:boxWidth withString:@"\u2500" startingAtIndex:0],
                     (unichar)0x2518];

    BOOL emittedStackAnnotation = NO;
    [d appendFormat:@"%@\n", top];
    for (NSUInteger i = 0; i < regions.count; i++) {
        NSDictionary *r = regions[i];
        uint16_t start = [r[@"start"] unsignedShortValue];
        uint16_t end   = [r[@"end"] unsignedShortValue];
        NSString *label = r[@"label"];
        NSString *content = [NSString stringWithFormat:@" $%04X-$%04X  %@", start, end, label];
        NSUInteger pad = (content.length < boxWidth) ? boxWidth - content.length : 0;
        [d appendFormat:@"# %C%@%@%C\n",
         (unichar)0x2502,
         content,
         [@"" stringByPaddingToLength:pad withString:@" " startingAtIndex:0],
         (unichar)0x2502];

        // Add stack/heap annotations once (on the system region if
        // present, otherwise on the first main region).
        BOOL isStackHome = !emittedStackAnnotation &&
            ([label hasPrefix:@"System region"] ||
             ([label isEqualToString:@"Main region"] && !_systemStart));
        if (isStackHome) {
            emittedStackAnnotation = YES;
            NSString *stackInfo;
            if ([_stackBase isEqualToString:@"after-code"] || [_stackBase isEqualToString:@"after-system"]) {
                stackInfo = [NSString stringWithFormat:@"   Stack %C (%@)", (unichar)0x2191, _stackBase];
            } else {
                stackInfo = [NSString stringWithFormat:@"   Stack %C (from %@)", (unichar)0x2191, _stackBase ?: @"?"];
            }
            NSUInteger sPad = (stackInfo.length + 1 < boxWidth) ? boxWidth - stackInfo.length - 1 : 0;
            [d appendFormat:@"# %C%@ %@%C\n", (unichar)0x2502, stackInfo,
             [@"" stringByPaddingToLength:sPad withString:@" " startingAtIndex:0],
             (unichar)0x2502];

            NSString *heapInfo = [NSString stringWithFormat:@"   $%04X  Heap %C (grows down)",
                                  _heapTop, (unichar)0x2193];
            NSUInteger hPad = (heapInfo.length + 1 < boxWidth) ? boxWidth - heapInfo.length - 1 : 0;
            [d appendFormat:@"# %C%@ %@%C\n", (unichar)0x2502, heapInfo,
             [@"" stringByPaddingToLength:hPad withString:@" " startingAtIndex:0],
             (unichar)0x2502];
        }

        if (i + 1 < regions.count) [d appendFormat:@"%@\n", sep];
    }
    [d appendFormat:@"%@\n", bot];

    // Summary lines.
    [d appendString:@"#\n"];
    if (_hasBanking) {
        [d appendFormat:@"# Banking: %@.\n", _kind == XTMemoryModelKindXE ? @"PORTB" : @"ZP pair"];
    }
    if (_kind == XTMemoryModelKindXT && !_hasSplitBanking) {
        [d appendString:@"#\n"];
        [d appendString:@"# xt architectural intent: two independent 8 KB bank windows.\n"];
        [d appendString:@"#   $82 selects $4000-$5FFF (code half)\n"];
        [d appendString:@"#   $83 selects $6000-$7FFF (data half)\n"];
        [d appendString:@"# Current implementation uses a single 16 KB window via $82,\n"];
        [d appendString:@"# with $83 pinned to 0. The split is a deferred xt-fast-path\n"];
        [d appendString:@"# optimisation; the codegen, page tracker, simulator, and xta\n"];
        [d appendString:@"# all need updates before code can depend on $83 addressing\n"];
        [d appendString:@"# a different bank than $82.\n"];
    } else if (_hasSplitBanking) {
        uint32_t codeKB = (_codeWindowEnd - _codeWindowStart + 1) / 1024;
        uint32_t dataKB = (_dataWindowEnd - _dataWindowStart + 1) / 1024;
        // Resolve per-window total addressable bytes. Layouts that don't
        // declare codeRegion/dataRegion fall back to the 8-bit-selector
        // upper bound (window-bytes × 256), matching deriveBackwardCompatFields.
        uint64_t codeSpan = _codeRegionSpan
                          ? _codeRegionSpan
                          : (uint64_t)(_codeWindowEnd - _codeWindowStart + 1) * 256;
        uint64_t dataSpan = _dataRegionSpan
                          ? _dataRegionSpan
                          : (uint64_t)(_dataWindowEnd - _dataWindowStart + 1) * 256;
        NSString *(^spanLabel)(uint64_t) = ^NSString *(uint64_t bytes) {
            if (bytes >= (1ULL << 20) && (bytes % (1ULL << 20)) == 0) {
                return [NSString stringWithFormat:@"%llu MB addressable",
                                                  bytes / (1ULL << 20)];
            }
            if (bytes >= (1ULL << 10)) {
                return [NSString stringWithFormat:@"%llu KB addressable",
                                                  bytes / (1ULL << 10)];
            }
            return [NSString stringWithFormat:@"%llu B addressable", bytes];
        };
        [d appendString:@"#\n"];
        [d appendString:@"# xt: independent bank windows.\n"];
        [d appendFormat:@"#   $%02X      selects $%04X-$%04X "
                        @"(%u KB code),    %@\n",
                        _codeBankReg, _codeWindowStart, _codeWindowEnd,
                        codeKB, spanLabel(codeSpan)];
        [d appendFormat:@"#   $%02X      selects $%04X-$%04X "
                        @"(%u KB data),    %@\n",
                        _dataBankReg, _dataWindowStart, _dataWindowEnd,
                        dataKB, spanLabel(dataSpan)];
        if (_hasRegionCBanking) {
            uint32_t regCKB = (_regCWindowEnd - _regCWindowStart + 1) / 1024;
            NSString *regCSpan = _regCRegionSpan
                ? spanLabel(_regCRegionSpan)
                : @"span unset";
            if (_regCBankRegHi) {
                [d appendFormat:@"#   $%02X/$%02X  selects $%04X-$%04X "
                                @"(%u KB regionC), %@\n",
                                _regCBankRegLo, _regCBankRegHi,
                                _regCWindowStart, _regCWindowEnd,
                                regCKB, regCSpan];
                [d appendString:@"#             (16-bit pair, conditionally reserved)\n"];
            } else {
                [d appendFormat:@"#   $%02X      selects $%04X-$%04X "
                                @"(%u KB regionC), %@\n",
                                _regCBankRegLo,
                                _regCWindowStart, _regCWindowEnd,
                                regCKB, regCSpan];
                [d appendString:@"#             (conditionally reserved)\n"];
            }
        }
        if (_hasRegionCBanking && _regCBankRegLo) {
            if (_regCBankRegHi) {
                [d appendFormat:@"# $%02X and $%02X/$%02X are callee-saved; "
                                @"_xcall swaps $%02X only.\n",
                                _dataBankReg, _regCBankRegLo, _regCBankRegHi,
                                _codeBankReg];
            } else {
                [d appendFormat:@"# $%02X and $%02X are callee-saved; "
                                @"_xcall swaps $%02X only.\n",
                                _dataBankReg, _regCBankRegLo, _codeBankReg];
            }
        } else {
            [d appendFormat:@"# $%02X is callee-saved; _xcall swaps $%02X only.\n",
                            _dataBankReg, _codeBankReg];
        }
    }
    if (_hasShadow) {
        [d appendFormat:@"# Shadow mode: $%04X:$%02X.\n", _shadowRegAddr, _shadowRegMask];
    }
    if (_entryAddress) {
        [d appendFormat:@"# Entry: $%04X\n", _entryAddress];
    }

    return d;
}

/****************************************************************************\
|* Copy non-zero / non-nil fields from `base` into `self` as defaults.
|* Fields that `self` has already set are not overwritten. Used for
|* `#include` merging in linker scripts.
|* @param base  The model whose values serve as defaults.
\****************************************************************************/
- (void)mergeDefaultsFrom:(XTMemoryModel *)base {
    // Copy every field from base where self hasn't been set.
    // "Not set" = 0 for scalars, nil for objects.
    #define MERGE_SCALAR(f)  if (!_##f) _##f = base.f
    #define MERGE_OBJ(f)     if (!_##f) _##f = base.f
    #define MERGE_BOOL(f)    if (!_##f) _##f = base.f

    MERGE_SCALAR(zpSPStart);    MERGE_SCALAR(zpSPEnd);
    MERGE_SCALAR(zpTmpStart);   MERGE_SCALAR(zpTmpEnd);
    MERGE_SCALAR(zpHPStart);    MERGE_SCALAR(zpHPEnd);
    MERGE_OBJ(zpVarsRanges);
    MERGE_SCALAR(zpRuntimeStart); MERGE_SCALAR(zpRuntimeEnd);
    MERGE_SCALAR(zpBankRegStart); MERGE_SCALAR(zpBankRegEnd);

    MERGE_OBJ(mainRegionRanges);
    MERGE_SCALAR(systemStart);  MERGE_SCALAR(systemEnd);
    MERGE_SCALAR(screenStart);  MERGE_SCALAR(screenEnd);

    MERGE_BOOL(hasBanking);
    MERGE_SCALAR(bankWindowStart); MERGE_SCALAR(bankWindowEnd);
    MERGE_SCALAR(bankPageSize);
    MERGE_OBJ(bankRegisters);

    // Split-bank fields. Inherit from the base .lnk so that a
    // derived layout (e.g. `xt-heap.lnk #include "xt.lnk"`)
    // keeps the two-window shape instead of regressing to the
    // legacy single-window view during merge.
    MERGE_BOOL(hasSplitBanking);
    MERGE_SCALAR(codeWindowStart); MERGE_SCALAR(codeWindowEnd);
    MERGE_SCALAR(dataWindowStart); MERGE_SCALAR(dataWindowEnd);
    MERGE_SCALAR(codeBankReg);     MERGE_SCALAR(dataBankReg);
    MERGE_SCALAR(codeRegionSpan);  MERGE_SCALAR(dataRegionSpan);

    // Region-C fields. Inherited so xt-heap-regC.lnk (which #includes
    // xt.lnk) picks up the regCWindow / regCReg pair from the parent
    // even when it declares its own [heap] regCBank locally.
    MERGE_BOOL(hasRegionCBanking);
    MERGE_SCALAR(regCWindowStart); MERGE_SCALAR(regCWindowEnd);
    MERGE_SCALAR(regCPageSize);
    MERGE_SCALAR(regCBankRegLo);   MERGE_SCALAR(regCBankRegHi);
    MERGE_SCALAR(regCRegionSpan);

    MERGE_BOOL(hasShadow);
    MERGE_SCALAR(shadowRegAddr); MERGE_SCALAR(shadowRegMask);
    MERGE_SCALAR(trampolineStart); MERGE_SCALAR(trampolineEnd);
    MERGE_SCALAR(nmiEntry);     MERGE_SCALAR(irqEntry);
    MERGE_SCALAR(shadowStage);

    // cloakedRegions is deliberately NOT inherited here. Propagating
    // it from xe.lnk downstream would silently enable cloaking on
    // descendants like xe-heap.lnk whose startup templates don't
    // preload the cloaked library, regressing every non-cloaked
    // fixture that uses Stdio on those targets. Layouts that want
    // cloaking declare [cloaked] directly.

    MERGE_OBJ(stackBase);
    MERGE_BOOL(stackGrowsUp);
    MERGE_SCALAR(stackBank);
    MERGE_BOOL(stackBankSet);
    MERGE_SCALAR(stackRangeStart);
    MERGE_SCALAR(stackRangeEnd);
    MERGE_BOOL(stackRangeSet);
    MERGE_SCALAR(heapTop);
    MERGE_SCALAR(heapLow);
    MERGE_SCALAR(heapBank);
    MERGE_SCALAR(heapBankEnd);
    MERGE_SCALAR(regCHeapBank);
    MERGE_SCALAR(regCHeapBankEnd);
    MERGE_SCALAR(heapPointerWidth);
    MERGE_BOOL(heapGrowsDown);
    MERGE_SCALAR(entryAddress);
    MERGE_OBJ(startupFile);
    MERGE_OBJ(buffers);
    MERGE_OBJ(outputFormat);
    MERGE_OBJ(symbolsFile);
    MERGE_OBJ(libPath);


    #undef MERGE_SCALAR
    #undef MERGE_OBJ
    #undef MERGE_BOOL
}

/****************************************************************************\
|* Clear every [stack]-derived field. The parser calls this the first
|* time a `[stack]` section header appears in the current file, before
|* processing that section's keys — which gives the `[stack]` block
|* "all-or-nothing override" semantics: an inheriting layout that
|* declares its own `[stack]` starts with a clean slate rather than
|* inheriting a partial set from the parent and mixing it with its
|* own keys. Without this, `xe-heap.lnk` (which #includes xe.lnk and
|* overrides only `base` / `grows`) would silently inherit xe's
|* `bank = 0` / `range = $4000-$7FFF` and then force every :banked
|* function through the :main-forcing rule, breaking the banked heap.
\****************************************************************************/
- (void)resetStackFields {
    _stackBase       = nil;
    _stackGrowsUp    = NO;
    _stackBank       = 0;
    _stackBankSet    = NO;
    _stackRangeStart = 0;
    _stackRangeEnd   = 0;
    _stackRangeSet   = NO;
}

/****************************************************************************\
|* Derive `kind`, `portBMask`, `sizeKB` from the .lnk-sourced
|* fields so existing codegen keeps working.
\****************************************************************************/
- (void)deriveBackwardCompatFields {
    // Determine kind from the .lnk content.
    if (!_hasBanking) {
        _kind = XTMemoryModelKindXL;
        if (!_name) _name = @"xl";
    } else if (_bankRegisters.count > 0) {
        // Distinguish xt (independent code + data windows, two
        // discrete registers) from xe (single PORTB-style register
        // with a bit mask) by STRUCTURE, not register address. xt
        // uses `hasSplitBanking` (set by codeReg / dataReg / split
        // window directives); xe uses a single registers entry with
        // a non-$FF mask. Register addresses themselves don't
        // determine the kind — a cart-mapped xt with both regs in
        // $Cxxx still wants the xt codegen / runtime shape.
        BOOL looksXE = !_hasSplitBanking
                    && _bankRegisters.count == 1
                    && [_bankRegisters[0][1] unsignedCharValue] != 0xFF;
        if (looksXE) {
            _kind = XTMemoryModelKindXE;
            if (!_name) _name = @"xe";
            // Derive portBMask from the first register's mask.
            _portBMask = [_bankRegisters[0][1] unsignedCharValue];
            // Derive sizeKB: count mask bits → bank count, ×16 + 64.
            uint8_t mask = _portBMask;
            NSUInteger bits = 0;
            while (mask) { bits += (mask & 1); mask >>= 1; }
            NSUInteger banks = (1u << bits);
            _sizeKB = banks * 16 + 64;
        } else {
            _kind = XTMemoryModelKindXT;
            if (!_name) _name = @"xt";
        }
    } else {
        _kind = XTMemoryModelKindXT;
        if (!_name) _name = @"xt";
    }

    // Build the unified banks[] view from the legacy fields. Layouts
    // that don't use banking get a nil banks array. Split-bank layouts
    // (xt) get one code-typed and one data-typed entry; layouts that
    // also declare region C add a third data-typed entry.
    NSMutableArray<XTBankDescriptor *> *built = [NSMutableArray array];
    if (_hasSplitBanking) {
        XTBankDescriptor *codeBank = [XTBankDescriptor new];
        codeBank.kind         = XTBankKindCode;
        codeBank.windowStart  = _codeWindowStart;
        codeBank.windowEnd    = _codeWindowEnd;
        codeBank.pageSize     = (uint16_t)(_codeWindowEnd - _codeWindowStart + 1);
        codeBank.regAddrLo    = _codeBankReg;
        codeBank.regAddrHi    = 0;  // 8-bit selector
        codeBank.regionSpan   = _codeRegionSpan
                                ? _codeRegionSpan
                                : (uint64_t)codeBank.pageSize * 256;
        [built addObject:codeBank];

        XTBankDescriptor *dataBank = [XTBankDescriptor new];
        dataBank.kind         = XTBankKindData;
        dataBank.windowStart  = _dataWindowStart;
        dataBank.windowEnd    = _dataWindowEnd;
        dataBank.pageSize     = (uint16_t)(_dataWindowEnd - _dataWindowStart + 1);
        dataBank.regAddrLo    = _dataBankReg;
        dataBank.regAddrHi    = 0;
        dataBank.regionSpan   = _dataRegionSpan
                                ? _dataRegionSpan
                                : (uint64_t)dataBank.pageSize * 256;
        [built addObject:dataBank];
    }
    if (_hasRegionCBanking) {
        XTBankDescriptor *regCBank = [XTBankDescriptor new];
        regCBank.kind          = XTBankKindData;
        regCBank.windowStart   = _regCWindowStart;
        regCBank.windowEnd     = _regCWindowEnd;
        regCBank.pageSize      = _regCPageSize;
        regCBank.regAddrLo     = _regCBankRegLo;
        regCBank.regAddrHi     = _regCBankRegHi;     // non-zero → 16-bit pair
        // Default for 16-bit selector is the maximum it can address; for
        // an 8-bit selector it's pageSize × 256. Either way the layout
        // can override.
        if (_regCRegionSpan) {
            regCBank.regionSpan = _regCRegionSpan;
        } else if (_regCBankRegHi) {
            regCBank.regionSpan = (uint64_t)regCBank.pageSize * 65536;
        } else {
            regCBank.regionSpan = (uint64_t)regCBank.pageSize * 256;
        }
        [built addObject:regCBank];
    }
    self.banks = built.count > 0 ? [built copy] : nil;
}

+ (NSString *)formatRegisterOperand:(uint16_t)addr {
    if (addr == 0) return @"";
    if (addr <= 0xFF) return [NSString stringWithFormat:@"$%02X", addr];
    return [NSString stringWithFormat:@"$%04X", addr];
}

- (NSString *)codeBankRegOperand {
    return [XTMemoryModel formatRegisterOperand:self.codeBankReg];
}
- (NSString *)dataBankRegOperand {
    return [XTMemoryModel formatRegisterOperand:self.dataBankReg];
}
- (NSString *)regCBankRegLoOperand {
    return [XTMemoryModel formatRegisterOperand:self.regCBankRegLo];
}
- (NSString *)regCBankRegHiOperand {
    return [XTMemoryModel formatRegisterOperand:self.regCBankRegHi];
}

@end
