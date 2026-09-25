#import "XAAssembler+Private.h"

// ── Atari memory map predefined symbols ──────────────────────────────
static NSDictionary<NSString*, NSNumber*>* XAAtariMemoryMap(void)
    {
    static NSDictionary* map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      map = @{
          // Page 0: OS and hardware
          @"LINZBS" : @(0x00),
          @"CASINI" : @(0x02),
          @"RAMLO" : @(0x04),
          @"TRAMSZ" : @(0x06),
          @"TSTDAT" : @(0x07),
          @"WARMST" : @(0x08),
          @"BOOTQ" : @(0x09),
          @"DOSVEC" : @(0x0A),
          @"DOSINI" : @(0x0C),
          @"APPMHI" : @(0x0E),
          @"POKMSK" : @(0x10),
          @"BRKKEY" : @(0x11),
          @"RTCLOK" : @(0x12),
          @"BUFADR" : @(0x15),
          @"ICCOMT" : @(0x17),
          @"DTEFIL" : @(0x1A),
          @"ICCMD" : @(0x1B),
          @"DTEFLI" : @(0x1C),
          @"LBUFF" : @(0x1D),
          @"SSKCTL" : @(0x4E),
          @"VDSLST" : @(0x200),
          @"VPRCED" : @(0x202),
          @"VINTER" : @(0x204),
          @"VBREAK" : @(0x206),
          @"VKEYBD" : @(0x208),
          @"VSERIN" : @(0x20A),
          @"VSEROC" : @(0x20C),
          @"VTIMR1" : @(0x210),
          @"VTIMR2" : @(0x212),
          @"VTIMR4" : @(0x214),
          @"VIMIRQ" : @(0x216),
          @"CDTMV1" : @(0x218),
          @"CDTMV2" : @(0x21A),
          @"CDTMV3" : @(0x21C),
          @"CDTMV4" : @(0x21E),
          @"CDTMV5" : @(0x220),
          // Display
          @"SDMCTL" : @(0x22F),
          @"SDLSTL" : @(0x230),
          @"SDLSTH" : @(0x231),
          @"LPENH" : @(0x234),
          @"LPENV" : @(0x235),
          @"TXTROW" : @(0x290),
          @"TXTCOL" : @(0x291),
          @"DINDEX" : @(0x57),
          @"SAVMSC" : @(0x58),
          @"OLDROW" : @(0x5A),
          @"OLDCOL" : @(0x5B),
          @"OLDCHR" : @(0x5D),
          @"OLDADR" : @(0x5E),
          @"ROWCRS" : @(0x54),
          @"COLCRS" : @(0x55),
          @"LMARGN" : @(0x52),
          @"RMARGN" : @(0x53),
          @"LOGCOL" : @(0x63),
          @"ATACHR" : @(0x2FB),
          @"CH" : @(0x2FC),
          @"FILDAT" : @(0x2FD),
          @"DSPFLG" : @(0x2FE),
          @"SSFLAG" : @(0x2FF),
          // Colors
          @"PCOLR0" : @(0x2C0),
          @"PCOLR1" : @(0x2C1),
          @"PCOLR2" : @(0x2C2),
          @"PCOLR3" : @(0x2C3),
          @"COLOR0" : @(0x2C4),
          @"COLOR1" : @(0x2C5),
          @"COLOR2" : @(0x2C6),
          @"COLOR3" : @(0x2C7),
          @"COLOR4" : @(0x2C8),
          @"COLPF0" : @(0xD016),
          @"COLPF1" : @(0xD017),
          @"COLPF2" : @(0xD018),
          @"COLPF3" : @(0xD019),
          @"COLBK" : @(0xD01A),
          @"COLPM0" : @(0xD012),
          @"COLPM1" : @(0xD013),
          @"COLPM2" : @(0xD014),
          @"COLPM3" : @(0xD015),
          // GTIA
          @"HPOSP0" : @(0xD000),
          @"HPOSP1" : @(0xD001),
          @"HPOSP2" : @(0xD002),
          @"HPOSP3" : @(0xD003),
          @"HPOSM0" : @(0xD004),
          @"HPOSM1" : @(0xD005),
          @"HPOSM2" : @(0xD006),
          @"HPOSM3" : @(0xD007),
          @"SIZEP0" : @(0xD008),
          @"SIZEP1" : @(0xD009),
          @"SIZEP2" : @(0xD00A),
          @"SIZEP3" : @(0xD00B),
          @"SIZEM" : @(0xD00C),
          @"GRAFP0" : @(0xD00D),
          @"GRAFP1" : @(0xD00E),
          @"GRAFP2" : @(0xD00F),
          @"GRAFP3" : @(0xD010),
          @"GRAFM" : @(0xD011),
          @"GRACTL" : @(0xD01D),
          @"HITCLR" : @(0xD01E),
          @"CONSOL" : @(0xD01F),
          @"PRIOR" : @(0xD01B),
          // POKEY
          @"AUDF1" : @(0xD200),
          @"AUDC1" : @(0xD201),
          @"AUDF2" : @(0xD202),
          @"AUDC2" : @(0xD203),
          @"AUDF3" : @(0xD204),
          @"AUDC3" : @(0xD205),
          @"AUDF4" : @(0xD206),
          @"AUDC4" : @(0xD207),
          @"AUDCTL" : @(0xD208),
          @"STIMER" : @(0xD209),
          @"SKREST" : @(0xD20A),
          @"POTGO" : @(0xD20B),
          @"SEROUT" : @(0xD20D),
          @"IRQEN" : @(0xD20E),
          @"SKCTL" : @(0xD20F),
          @"SERIN" : @(0xD20D),
          @"IRQST" : @(0xD20E),
          @"SKSTAT" : @(0xD20F),
          @"KBCODE" : @(0xD209),
          @"RANDOM" : @(0xD20A),
          // ANTIC
          @"DMACTL" : @(0xD400),
          @"CHACTL" : @(0xD401),
          @"DLISTL" : @(0xD402),
          @"DLISTH" : @(0xD403),
          @"HSCROL" : @(0xD404),
          @"VSCROL" : @(0xD405),
          @"PMBASE" : @(0xD407),
          @"CHBASE" : @(0xD409),
          @"WSYNC" : @(0xD40A),
          @"VCOUNT" : @(0xD40B),
          @"PENH" : @(0xD40C),
          @"PENV" : @(0xD40D),
          @"NMIEN" : @(0xD40E),
          @"NMIST" : @(0xD40F),
          @"NMIRES" : @(0xD40F),
          // PIA
          @"PORTA" : @(0xD300),
          @"PORTB" : @(0xD301),
          @"PACTL" : @(0xD302),
          @"PBCTL" : @(0xD303),
          // OS vectors
          @"RUNAD" : @(0x02E0),
          @"INITAD" : @(0x02E2),
          // Character set
          @"CHBAS" : @(0x2F4),
          @"ATRACT" : @(0x4D),
          // Misc
          @"FR0" : @(0xD4),
          @"FR1" : @(0xE0),
          @"CIX" : @(0xF2),
          @"INBUFF" : @(0xF3),
          @"FLPTR" : @(0xFC),
      };
    });
    return map;
    }

// ── Parsed line types ────────────────────────────────────────────────
// XALineType, XAParsedLine, XAMacro moved to XAAssembler+Private.h
@implementation XAParsedLine
@end

@implementation XAMacro
@end

// ── XASegment ────────────────────────────────────────────────────────
@implementation XASegment
/****************************************************************************\
|* Initialise a segment with the given load origin address.
|* @param origin  The 16-bit address where this segment loads.
|* @return  A segment with an empty data buffer.
\****************************************************************************/
- (instancetype)initWithOrigin:(uint16_t)origin
    {
    self = [super init];
    if (self)
        {
        _origin = origin;
        _data = [NSMutableData data];
        _cloakedBankIndex = -1;
        _bankNumber = -1;
        }
    return self;
    }
@end

// Inverse branch mapping for long-branch rewriting
static NSDictionary<NSString*, NSString*>* XAInverseBranch(void)
    {
    static NSDictionary* map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      map = @{
          @"BCC" : @"BCS",
          @"BCS" : @"BCC",
          @"BEQ" : @"BNE",
          @"BNE" : @"BEQ",
          @"BMI" : @"BPL",
          @"BPL" : @"BMI",
          @"BVC" : @"BVS",
          @"BVS" : @"BVC",
      };
    });
    return map;
    }

// ── XAAssembler ──────────────────────────────────────────────────────

@implementation XAAssembler
    {
    NSDictionary<NSString*, NSNumber*>* _platformSymbols;
    BOOL _finalRegionOverflowReported;
    // Stage 4: suppress .code_regions overflow checks while emitting
    // inside a `.cloaked_segment ... .cloaked_segment_end` bracket.
    // The cloaked segment lives at $4000-$7FFF, which is NOT in the
    // `.code_regions` list (those cover main-RAM code windows only),
    // so the first cloaked instruction would otherwise trip the
    // "exceeds last region" check against the preceding region's end.
    BOOL _inCloakedSegment;
    // YES while _pc sits inside one of the declared `.code_regions`.
    // Set in syncCurrentRegionToPC after every .org / cloaked-begin /
    // .code_regions directive. The .code_regions overflow checks
    // gate on this so that bank-page emission (`.org $4000` after
    // .cloaked_segment_end) and shadow-region emission don't trip
    // the check just because the previous main-region cursor was
    // already at the last region.
    BOOL _pcInsideMainRegion;
    // -D definitions, laid over the platform symbols at every pass.
    NSMutableDictionary<NSString*, NSNumber*>* _predefinedSymbols;
    }

/****************************************************************************\
|* Load symbols from a .sym file. Format: `NAME = $XXXX` per line,
|* `;` comments, blank lines ignored.
\****************************************************************************/
- (NSDictionary<NSString*, NSNumber*>*)loadSymbolsFromFile:(NSString*)path
    {
    NSError* err;
    NSString* contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&err];
    if (!contents)
        return @{};
    NSMutableDictionary* syms = [NSMutableDictionary dictionary];
    for (NSString* rawLine in [contents componentsSeparatedByString:@"\n"])
        {
        NSString* line = rawLine;
        NSRange semi = [line rangeOfString:@";"];
        if (semi.location != NSNotFound)
            line = [line substringToIndex:semi.location];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0)
            continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound)
            continue;
        NSString* name = [[line substringToIndex:eq.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString* val = [[line substringFromIndex:eq.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([val hasPrefix:@"$"])
            {
            unsigned int v;
            NSScanner* sc = [NSScanner scannerWithString:[val substringFromIndex:1]];
            if ([sc scanHexInt:&v])
                syms[name] = @(v);
            }
        }
    return syms;
    }

/****************************************************************************\
|* Return the platform symbol table. Built once on first access by
|* merging every entry in `symbolsFiles` (in order — later wins on
|* duplicate names) and then `symbolsFile` if it's set and not
|* already covered. Falls back to the built-in Atari memory map
|* only when nothing loaded — handy for unit tests that never set
|* a path. Production paths always go through the driver, which
|* populates `symbolsFiles` from support/<plat>/symbols/*.sym +
|* support/generic/symbols/*.sym.
\****************************************************************************/
- (NSDictionary<NSString*, NSNumber*>*)platformSymbols
    {
    if (!_platformSymbols)
        {
        NSMutableDictionary* merged = [NSMutableDictionary dictionary];
        for (NSString* path in (_symbolsFiles ?: @[]))
            {
            if (path.length == 0)
                continue;
            [merged addEntriesFromDictionary:[self loadSymbolsFromFile:path]];
            }
        if (_symbolsFile && _symbolsFile.length > 0 &&
            ![(_symbolsFiles ?: @[]) containsObject:_symbolsFile])
            {
            [merged addEntriesFromDictionary:[self loadSymbolsFromFile:_symbolsFile]];
            }
        if (merged.count == 0)
            {
            _platformSymbols = XAAtariMemoryMap();
            }
        else
            {
            _platformSymbols = merged;
            }
        }
    return _platformSymbols;
    }

/****************************************************************************\
|* Initialise the assembler with empty symbol/macro tables and default state.
|* @return  A fresh assembler instance ready for assembleSource:filename:.
\****************************************************************************/
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _symbols = [NSMutableDictionary dictionary];
        _macros = [NSMutableDictionary dictionary];
        _mutableErrors = [NSMutableArray array];
        _mutableWarnings = [NSMutableArray array];
        _ambiguousHexLabelsWarned = [NSMutableSet set];
        _parsedLines = [NSMutableArray array];
        _listingLines = [NSMutableArray array];
        _predefinedSymbols = [NSMutableDictionary dictionary];
        _includePaths = @[];
        _pc = 0;
        _cpu = [XA6502 sharedInstance];
        }
    return self;
    }

/****************************************************************************\
|* Return an immutable copy of the accumulated error messages.
|* @return  An array of error strings from the last assembly.
\****************************************************************************/
- (NSArray<NSString*>*)errors
    {
    return [_mutableErrors copy];
    }
/****************************************************************************\
|* Return an immutable copy of the accumulated warning messages.
|* @return  An array of warning strings from the last assembly.
\****************************************************************************/
- (NSArray<NSString*>*)warnings
    {
    return [_mutableWarnings copy];
    }

/****************************************************************************\
|* Pre-define a symbol (equivalent to -D on the command line).
|* @param name   The symbol name.
|* @param value  The value expression string (evaluated immediately).
\****************************************************************************/
- (void)defineSymbol:(NSString*)name value:(NSString*)value
    {
    // Kept apart from _symbols, which every pass rebuilds from the platform
    // table: a -D stored there was gone before pass 1 looked at it.
    _predefinedSymbols[name] = @([self evaluateExpression:value]);
    }

#pragma mark - Main Entry Point

/****************************************************************************\
|* Assemble source text into segments. Preprocesses includes/macros, runs
|* iterative pass-1/long-branch-rewrite cycles until stable, then emits
|* bytes in pass 2.
|* @param source    The assembly source text.
|* @param filename  The filename for error reporting and .include resolution.
|* @return  An array of XASegment on success, nil on error.
\****************************************************************************/
- (nullable NSArray<XASegment*>*)assembleSource:(NSString*)source
                                       filename:(NSString*)filename
    {
    // Expand includes and macros, then parse all lines
    NSMutableArray<NSString*>* sourceLines =
        [NSMutableArray arrayWithArray:[self preprocessSource:source filename:filename]];

    // Iterative assembly: pass 1, then size-changing rewrites (cross-bank
    // call staging, then long-branch fixups), re-pass until stable.
    // Only ONE rewriter mutates the source list per iteration (each edits
    // by source-line index off the same pass-1 snapshot, so running two in
    // one pass would invalidate the second's indices). Cross-bank goes
    // first and is idempotent (it leaves no `JSR <banked-label>`), so it
    // fully resolves in one pass before long branches settle. Cap raised
    // to absorb the extra cross-bank pass.
    for (int iteration = 0; iteration < 8; iteration++)
        {
        // Reset symbols to predefined map only (pass 1 will re-populate labels)
        _symbols = [NSMutableDictionary dictionaryWithDictionary:[self platformSymbols]];
        // Bank-select registers as named symbols, so generated code and the
        // hand-written runtime asm reference `__bank_code_reg` /
        // `__bank_data_reg` rather than a hard-coded address. Sourced ONLY
        // from the layout's codeBankReg/dataBankReg (e.g. $D5C0/$D5C1 on xt).
        // There is deliberately NO default: if a banked program references
        // one of these and the layout didn't declare it, the symbol stays
        // undefined and pass 1 fails with a hard "undefined symbol" error
        // rather than silently aliasing the historical $82/$83 ZP pair.
        // Predefined here (before pass 1) so the operand value is known when
        // the assembler picks zero-page vs absolute addressing.
        if (self.codeBankReg)
            _symbols[@"__bank_code_reg"] = @(self.codeBankReg);
        if (self.dataBankReg)
            _symbols[@"__bank_data_reg"] = @(self.dataBankReg);
        [_symbols addEntriesFromDictionary:_predefinedSymbols];
        [_mutableErrors removeAllObjects];
        _finalRegionOverflowReported = NO;
        [_mutableWarnings removeAllObjects];
        [_ambiguousHexLabelsWarned removeAllObjects];

        // Pass 1: collect labels and compute sizes
        [self pass1:sourceLines filename:filename];
        if (_mutableErrors.count > 0)
            return nil;

        // Cross-bank call rewriting (task #121) — runs to completion in
        // one pass, then re-pass1 so addresses reflect the staging.
        NSUInteger xbank = [self rewriteCrossBankCalls:sourceLines];
        if (xbank > 0)
            {
            if (_verbose)
                {
                [_mutableWarnings addObject:[NSString stringWithFormat:
                                                          @"iteration %d: staged %lu cross-bank call%s",
                                                          iteration + 1, (unsigned long)xbank, xbank == 1 ? "" : "s"]];
                }
            continue;
            }

        // Check for long branches and rewrite them
        NSUInteger rewrites = [self rewriteLongBranches:sourceLines];
        if (rewrites == 0)
            break; // stable — no more long branches

        if (_verbose)
            {
            [_mutableWarnings addObject:[NSString stringWithFormat:
                                                      @"iteration %d: rewrote %lu long branch%s",
                                                      iteration + 1, (unsigned long)rewrites, rewrites == 1 ? "" : "es"]];
            }
        }

    if (_mutableErrors.count > 0)
        return nil;

    // Pass 2: resolve expressions and emit bytes
    NSArray<XASegment*>* segments = [self pass2];
    if (_mutableErrors.count > 0)
        return nil;

    return segments;
    }

#pragma mark - Preprocessing (includes, macros)

/****************************************************************************\
|* Preprocess assembly source: collect macro definitions, expand .include
|* directives, and expand macro invocations.
|* @param source    The raw assembly source text.
|* @param filename  The filename for .include path resolution.
|* @return  An array of preprocessed source lines.
\****************************************************************************/
- (NSArray<NSString*>*)preprocessSource:(NSString*)source filename:(NSString*)filename
    {
    NSArray<NSString*>* rawLines = [source componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString*>* result = [NSMutableArray array];

    // First pass: collect macro definitions
    BOOL inMacro = NO;
    XAMacro* currentMacro = nil;

    for (NSString* rawLine in rawLines)
        {
        NSString* line = [self stripComment:rawLine];
        NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if (inMacro)
            {
            // Check for end of macro (next .macro or a non-indented label)
            if ([trimmed.lowercaseString hasPrefix:@".macro "] ||
                (trimmed.length > 0 && !([trimmed hasPrefix:@" "] || [trimmed hasPrefix:@"\t"]) &&
                 ![rawLine hasPrefix:@" "] && ![rawLine hasPrefix:@"\t"]))
                {
                inMacro = NO;
                // Fall through to process this line normally
                }
            else
                {
                [currentMacro.bodyLines addObject:rawLine];
                continue;
                }
            }

        if ([trimmed.lowercaseString hasPrefix:@".macro "])
            {
            NSString* rest = [trimmed substringFromIndex:7];
            rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            // Parse: name param1, param2, ...
            NSArray<NSString*>* parts = [rest componentsSeparatedByCharactersInSet:
                                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (parts.count > 0)
                {
                currentMacro = [[XAMacro alloc] init];
                currentMacro.macroName = parts[0];
                currentMacro.bodyLines = [NSMutableArray array];
                if (parts.count > 1)
                    {
                    NSString* paramStr = [[rest substringFromIndex:parts[0].length]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSMutableArray* params = [NSMutableArray array];
                    for (NSString* p in [paramStr componentsSeparatedByString:@","])
                        {
                        NSString* t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (t.length > 0)
                            [params addObject:t];
                        }
                    currentMacro.paramNames = params;
                    }
                else
                    {
                    currentMacro.paramNames = @[];
                    }
                _macros[currentMacro.macroName] = currentMacro;
                inMacro = YES;
                }
            continue;
            }

        // Handle .include
        if ([trimmed.lowercaseString hasPrefix:@".include "])
            {
            NSString* incFile = [[trimmed substringFromIndex:9]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // Strip quotes
            if ([incFile hasPrefix:@"\""] && [incFile hasSuffix:@"\""])
                {
                incFile = [incFile substringWithRange:NSMakeRange(1, incFile.length - 2)];
                }
            else if ([incFile hasPrefix:@"<"] && [incFile hasSuffix:@">"])
                {
                incFile = [incFile substringWithRange:NSMakeRange(1, incFile.length - 2)];
                }
            NSString* content = [self readIncludeFile:incFile relativeTo:filename];
            if (content)
                {
                NSArray<NSString*>* incLines = [self preprocessSource:content filename:incFile];
                [result addObjectsFromArray:incLines];
                }
            continue;
            }

        [result addObject:rawLine];
        }

    // Second pass: expand macro invocations
    NSMutableArray<NSString*>* expanded = [NSMutableArray array];
    for (NSString* rawLine in result)
        {
        NSString* line = [self stripComment:rawLine];
        NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // Check if first word (after optional label:) is a macro name
        NSString* possibleMacro = nil;
        NSString* macroArgs = nil;

        // Check if the line contains a macro invocation after a label
        // Don't split labels here — that's handled by parseLine
        NSString* afterLabel = trimmed;
        BOOL hadLabel = NO;
        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location != NSNotFound && colonRange.location < 20)
            {
            NSString* before = [trimmed substringToIndex:colonRange.location];
            if ([self isValidIdentifier:[before stringByTrimmingCharactersInSet:
                                                    [NSCharacterSet whitespaceCharacterSet]]])
                {
                afterLabel = [[trimmed substringFromIndex:colonRange.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                hadLabel = YES;
                }
            }

        // Check if afterLabel is a macro invocation
        NSArray<NSString*>* words = [afterLabel componentsSeparatedByCharactersInSet:
                                                    [NSCharacterSet whitespaceCharacterSet]];
        if (words.count > 0)
            possibleMacro = words[0];
        if (possibleMacro.length > 0 && _macros[possibleMacro])
            {
            // Emit the label line separately, then the expanded macro
            if (hadLabel)
                {
                [expanded addObject:[trimmed substringToIndex:colonRange.location + 1]];
                }
            macroArgs = afterLabel.length > possibleMacro.length ? [[afterLabel substringFromIndex:possibleMacro.length]
                                                                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                                                                 : @"";
            NSArray<NSString*>* expandedLines = [self expandMacro:possibleMacro withArgs:macroArgs];
            [expanded addObjectsFromArray:expandedLines];
            }
        else
            {
            // Not a macro — pass the whole line through unchanged
            [expanded addObject:rawLine];
            }
        }

    return expanded;
    }

/****************************************************************************\
|* Expand a macro invocation by substituting comma-separated arguments
|* into the macro's body lines.
|* @param macroName  The name of the macro to expand.
|* @param argsStr    The comma-separated argument string (may be empty).
|* @return  An array of expanded source lines.
\****************************************************************************/
- (NSArray<NSString*>*)expandMacro:(NSString*)macroName withArgs:(NSString*)argsStr
    {
    XAMacro* macro = _macros[macroName];
    if (!macro)
        return @[];

    NSMutableArray<NSString*>* argValues = [NSMutableArray array];
    if (argsStr.length > 0)
        {
        for (NSString* a in [argsStr componentsSeparatedByString:@","])
            {
            [argValues addObject:[a stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            }
        }

    NSMutableArray<NSString*>* result = [NSMutableArray array];
    for (NSString* bodyLine in macro.bodyLines)
        {
        NSMutableString* line = [NSMutableString stringWithString:bodyLine];
        for (NSUInteger i = 0; i < macro.paramNames.count && i < argValues.count; i++)
            {
            [line replaceOccurrencesOfString:macro.paramNames[i]
                                  withString:argValues[i]
                                     options:NSLiteralSearch
                                       range:NSMakeRange(0, line.length)];
            }
        [result addObject:line];
        }
    return result;
    }

/****************************************************************************\
|* Read an include file by searching the current directory and include paths.
|* @param filename     The filename from the .include directive.
|* @param currentFile  The file containing the .include, for relative resolution.
|* @return  The file contents, or nil (with an error added) if not found.
\****************************************************************************/
- (nullable NSString*)readIncludeFile:(NSString*)filename relativeTo:(NSString*)currentFile
    {
    NSString* dir = [currentFile stringByDeletingLastPathComponent];
    NSMutableArray<NSString*>* searchPaths = [NSMutableArray arrayWithObject:dir];
    [searchPaths addObjectsFromArray:_includePaths];

    for (NSString* path in searchPaths)
        {
        NSString* full = [path stringByAppendingPathComponent:filename];
        NSString* content = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
        if (content)
            return content;
        }
    [_mutableErrors addObject:[NSString stringWithFormat:@"Cannot find include file '%@'", filename]];
    return nil;
    }

/****************************************************************************\
|* Strip assembly-style comments (everything from `;` to end-of-line,
|* excluding semicolons inside string literals).
|* @param line  The raw source line.
|* @return  The line with the comment portion removed.
\****************************************************************************/
- (NSString*)stripComment:(NSString*)line
    {
    // Remove everything from first ';' (outside of strings)
    BOOL inString = NO;
    for (NSUInteger i = 0; i < line.length; i++)
        {
        unichar ch = [line characterAtIndex:i];
        if (ch == '"')
            inString = !inString;
        if (ch == ';' && !inString)
            return [line substringToIndex:i];
        }
    return line;
    }

#pragma mark - Line Parsing

/****************************************************************************\
|* Parse a single source line into an XAParsedLine structure, identifying
|* labels, directives, instructions, and assignments.
|* @param rawLine  The raw source line text.
|* @param lineNum  The 1-based line number for error reporting.
|* @return  A parsed line descriptor.
\****************************************************************************/
- (XAParsedLine*)parseLine:(NSString*)rawLine lineNumber:(NSUInteger)lineNum
    {
    XAParsedLine* pl = [[XAParsedLine alloc] init];
    pl.sourceLine = lineNum;
    pl.rawText = rawLine;
    pl.type = XALineEmpty;

    NSString* line = [self stripComment:rawLine];
    NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length == 0)
        return pl;

    // Check for label (identifier followed by ':')
    NSRange colonRange = [trimmed rangeOfString:@":"];
    NSString* afterLabel = trimmed;
    if (colonRange.location != NSNotFound)
        {
        NSString* before = [trimmed substringToIndex:colonRange.location];
        before = [before stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (before.length > 0 && [self isValidIdentifier:before])
            {
            if ([before hasPrefix:@">"])
                {
                pl.label = [before substringFromIndex:1];
                pl.labelIsLocal = YES;
                }
            else if ([before hasPrefix:@"."])
                {
                pl.label = before; // keep the dot — will be scoped later
                pl.labelIsLocal = YES;
                }
            else
                {
                pl.label = before;
                pl.labelIsLocal = NO;
                }
            afterLabel = [[trimmed substringFromIndex:colonRange.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }

    if (afterLabel.length == 0)
        {
        if (pl.label)
            pl.type = XALineLabel;
        return pl;
        }

    // Check for variable assignment: name = value
    NSRange eqRange = [afterLabel rangeOfString:@"="];
    if (eqRange.location != NSNotFound && eqRange.location > 0)
        {
        NSString* lhs = [[afterLabel substringToIndex:eqRange.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString* rhs = [[afterLabel substringFromIndex:eqRange.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // Make sure lhs is not a comparison like BEQ, and rhs exists
        if ([self isValidIdentifier:lhs] && rhs.length > 0 && ![_cpu isValidMnemonic:lhs])
            {
            pl.type = XALineAssignment;
            pl.assignName = lhs;
            pl.assignValue = rhs;
            return pl;
            }
        }

    // Check for directives
    if ([afterLabel.lowercaseString hasPrefix:@".org "])
        {
        pl.type = XALineDirectiveOrg;
        pl.operand = [[afterLabel substringFromIndex:4]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".bank "])
        {
        // .bank <identifier> — open a named banked region (task #121).
        // The operand is a symbolic id; the assembler maps it to a
        // physical bank number. Zero-width (sets PC to the bank window).
        pl.type = XALineDirectiveBank;
        pl.operand = [[afterLabel substringFromIndex:6]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        pl.byteSize = 0;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".code_regions "])
        {
        pl.type = XALineDirectiveCodeRegions;
        pl.operand = [[afterLabel substringFromIndex:14]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".shadow_ranges "])
        {
        pl.type = XALineDirectiveShadowRanges;
        pl.operand = [[afterLabel substringFromIndex:15]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".shadow_stage "])
        {
        pl.type = XALineDirectiveShadowStage;
        pl.operand = [[afterLabel substringFromIndex:14]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".spill_point"])
        {
        pl.type = XALineDirectiveSpillPoint;
        pl.byteSize = 0;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".cloaked_segment_end"])
        {
        pl.type = XALineDirectiveCloakedEnd;
        pl.byteSize = 0;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".cloaked_segment"])
        {
        pl.type = XALineDirectiveCloakedBegin;
        pl.operand = [[afterLabel substringFromIndex:16]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        pl.byteSize = 0;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".byte "])
        {
        pl.type = XALineDirectiveByte;
        pl.dataValues = [self parseDataList:[afterLabel substringFromIndex:5]];
        pl.byteSize = pl.dataValues.count;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".word "])
        {
        pl.type = XALineDirectiveWord;
        pl.dataValues = [self parseDataList:[afterLabel substringFromIndex:5]];
        pl.byteSize = pl.dataValues.count * 2;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".long "])
        {
        pl.type = XALineDirectiveLong;
        pl.dataValues = [self parseDataList:[afterLabel substringFromIndex:5]];
        pl.byteSize = pl.dataValues.count * 4;
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".string "])
        {
        pl.type = XALineDirectiveString;
        NSString* strVal = [[afterLabel substringFromIndex:7]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([strVal hasPrefix:@"\""] && [strVal hasSuffix:@"\""])
            {
            strVal = [strVal substringWithRange:NSMakeRange(1, strVal.length - 2)];
            }
        pl.operand = strVal;
        pl.byteSize = strVal.length + 1; // +1 for null terminator
        return pl;
        }
    if ([afterLabel.lowercaseString hasPrefix:@".space "])
        {
        pl.type = XALineDirectiveSpace;
        pl.operand = [[afterLabel substringFromIndex:6]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        pl.byteSize = (NSUInteger)[self evaluateExpression:pl.operand];
        return pl;
        }

    // Must be an instruction
    NSArray<NSString*>* parts = [afterLabel componentsSeparatedByCharactersInSet:
                                                [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString*>* nonEmpty = [NSMutableArray array];
    for (NSString* p in parts)
        {
        if (p.length > 0)
            [nonEmpty addObject:p];
        }

    if (nonEmpty.count == 0)
        return pl;

    // Compound splitting already handled by splitCompoundLine
    [self parseInstructionInto:pl fromString:[nonEmpty componentsJoinedByString:@" "] lineNum:lineNum];
    return pl;
    }

/****************************************************************************\
|* Parse an instruction string (mnemonic + operand) and populate the
|* parsed line's mnemonic, addressing mode, operand, and byte size fields.
|* @param pl       The parsed line to populate.
|* @param str      The instruction text (e.g. "LDA #$42").
|* @param lineNum  The line number for error reporting.
\****************************************************************************/
- (void)parseInstructionInto:(XAParsedLine*)pl fromString:(NSString*)str lineNum:(NSUInteger)lineNum
    {
    NSArray<NSString*>* parts = [str componentsSeparatedByCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString*>* nonEmpty = [NSMutableArray array];
    for (NSString* p in parts)
        {
        if (p.length > 0)
            [nonEmpty addObject:p];
        }
    if (nonEmpty.count == 0)
        return;

    NSString* mnemonic = [nonEmpty[0] uppercaseString];
    if (![_cpu isValidMnemonic:mnemonic])
        {
        // Could be a macro invocation — skip silently (handled in preprocessing)
        return;
        }

    pl.type = XALineInstruction;
    pl.mnemonic = mnemonic;

    if (nonEmpty.count == 1)
        {
        // Implied mode — or accumulator mode for the four shift/rotate
        // mnemonics where a bare opcode means "operate on A".
        NSString* upper = mnemonic.uppercaseString;
        if ([upper isEqualToString:@"ASL"] || [upper isEqualToString:@"LSR"] || [upper isEqualToString:@"ROL"] || [upper isEqualToString:@"ROR"])
            {
            pl.addressingMode = XAModeAccumulator;
            }
        else
            {
            pl.addressingMode = XAModeImplied;
            }
        pl.byteSize = 1;
        return;
        }

    NSString* operand = [[nonEmpty subarrayWithRange:NSMakeRange(1, nonEmpty.count - 1)]
        componentsJoinedByString:@" "];
    operand = [operand stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // Remove any trailing comma-separated components on the same line (compound: TXA : PHA)
    pl.operand = operand;

    // Detect addressing mode from operand syntax
    pl.addressingMode = [self detectAddressingMode:operand isBranch:[_cpu isBranchMnemonic:mnemonic]];
    pl.byteSize = XAByteSizeForMode(pl.addressingMode);

    // Accumulator mode check: "ASL A" etc
    if ([operand.uppercaseString isEqualToString:@"A"])
        {
        pl.addressingMode = XAModeAccumulator;
        pl.byteSize = 1;
        pl.operand = nil;
        }

    // If the mnemonic doesn't support the detected ZP form, promote
    // to the corresponding absolute form at parse time. Pass 2 has
    // a matching fallback, but it runs AFTER pass 1 has already
    // stamped label addresses using the wrong (short) byteSize —
    // so labels past the instruction end up one byte too low and
    // branch offsets miss by one. The classic case is `LDA $95,Y`:
    // detectAddressingMode sees `$95` ≤ $FF and picks ZP,Y (2
    // bytes), but there's no LDA zp,Y opcode on the 6502 — only
    // LDX/STX have that mode. Pass 2 promotes to abs,Y (3 bytes)
    // and rewrites byteSize, but by then the damage is done.
    // Normalising here keeps pass 1 and pass 2 in lockstep.
    if (pl.addressingMode == XAModeZeroPage &&
        [_cpu opcodeForMnemonic:mnemonic
                           mode:XAModeZeroPage] < 0 &&
        [_cpu opcodeForMnemonic:mnemonic
                           mode:XAModeAbsolute] >= 0)
        {
        pl.addressingMode = XAModeAbsolute;
        pl.byteSize = 3;
        }
    else if (pl.addressingMode == XAModeZeroPageX &&
             [_cpu opcodeForMnemonic:mnemonic
                                mode:XAModeZeroPageX] < 0 &&
             [_cpu opcodeForMnemonic:mnemonic
                                mode:XAModeAbsoluteX] >= 0)
        {
        pl.addressingMode = XAModeAbsoluteX;
        pl.byteSize = 3;
        }
    else if (pl.addressingMode == XAModeZeroPageY &&
             [_cpu opcodeForMnemonic:mnemonic
                                mode:XAModeZeroPageY] < 0 &&
             [_cpu opcodeForMnemonic:mnemonic
                                mode:XAModeAbsoluteY] >= 0)
        {
        pl.addressingMode = XAModeAbsoluteY;
        pl.byteSize = 3;
        }
    }

/****************************************************************************\
|* Detect the 6502 addressing mode from an operand string's syntax.
|* Handles #immediate, ($nn),Y, ($nn,X), ($nnnn), value,X/Y, and
|* distinguishes zero-page vs absolute by evaluating the operand value.
|* @param operand   The operand text to analyse.
|* @param isBranch  YES if the instruction is a branch (forces relative mode).
|* @return  The detected addressing mode.
\****************************************************************************/
- (XAAddressingMode)detectAddressingMode:(NSString*)operand isBranch:(BOOL)isBranch
    {
    if (isBranch)
        return XAModeRelative;

    NSString* op = [operand stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // Normalize: strip spaces around commas (e.g. "$0602 , Y" → "$0602,Y")
    while ([op rangeOfString:@" ,"].location != NSNotFound)
        op = [op stringByReplacingOccurrencesOfString:@" ," withString:@","];
    while ([op rangeOfString:@", "].location != NSNotFound)
        op = [op stringByReplacingOccurrencesOfString:@", " withString:@","];
    NSString* opUpper = op.uppercaseString;

    // xt CPU additions (docs/6502/6502-embellishments.md §§2-3).
    // Stack-indirect / indexed (§2b) — checked before the generic
    // `),Y` / `,X` forms below, which would otherwise capture them.
    // Deref a stacked pointer: `(+5,SP),Y`.
    if ([op hasPrefix:@"("] && [opUpper hasSuffix:@",SP),Y"])
        return XAModeSPIndirectIndexedY;
    // Indexed in-frame access: `+5,SP,X`.
    if ([opUpper hasSuffix:@",SP,X"])
        return XAModeSPIndexedX;
    // SP-relative load/store/arith: operand ends with `,SP` — e.g.
    // `+5,SP`, `-1,SP`, `+(N+9),SP`.
    if ([opUpper hasSuffix:@",SP"])
        return XAModeSPRelative;
    // Stack adjustment: `ADD SP, #imm` — operand starts with `SP,`.
    if ([opUpper hasPrefix:@"SP,"])
        return XAModeStackAdjust;

    // Immediate: #value
    if ([op hasPrefix:@"#"])
        return XAModeImmediate;

    // Indirect indexed: ($nn),Y
    if ([op hasPrefix:@"("] && [opUpper hasSuffix:@"),Y"])
        return XAModeIndirectIndexedY;

    // Indexed indirect: ($nn,X)
    if ([op hasPrefix:@"("] && [opUpper hasSuffix:@",X)"])
        return XAModeIndexedIndirectX;

    // Indirect: ($nnnn)
    if ([op hasPrefix:@"("] && [op hasSuffix:@")"])
        return XAModeIndirect;

    // Absolute/ZP,X: value,X
    if ([opUpper hasSuffix:@",X"])
        {
        // Determine ZP vs Absolute based on value (if resolvable)
        NSString* val = [op substringToIndex:op.length - 2];
        int64_t v = [self tryEvaluate:val];
        if (v >= 0 && v <= 0xFF)
            return XAModeZeroPageX;
        return XAModeAbsoluteX;
        }

    // Absolute/ZP,Y: value,Y
    if ([opUpper hasSuffix:@",Y"])
        {
        NSString* val = [op substringToIndex:op.length - 2];
        int64_t v = [self tryEvaluate:val];
        if (v >= 0 && v <= 0xFF)
            return XAModeZeroPageY;
        return XAModeAbsoluteY;
        }

    // ZP vs Absolute: depends on value size
    int64_t val = [self tryEvaluate:op];
    if (val >= 0 && val <= 0xFF)
        return XAModeZeroPage;
    return XAModeAbsolute;
    }

#pragma mark - Pass 1: Collect Labels and Sizes

/****************************************************************************\
|* Pass 1: collect labels and compute sizes. Runs in two sub-phases so
|* that `.spill_point` directives can look ahead across subsequent
|* parsed lines to decide whether the next chunk of code fits in the
|* current region — if not, the spill point is rewritten in-place as
|* a synthetic `.org` targeting the next region declared by
|* `.code_regions`.
|* @param sourceLines  The preprocessed source lines.
|* @param filename     The source filename for error messages.
\****************************************************************************/
- (void)pass1:(NSArray<NSString*>*)sourceLines filename:(NSString*)filename
    {
    [_parsedLines removeAllObjects];
    _pc = 0;
    _lastGlobalLabel = nil;
    _codeRegions = nil;
    _currentRegionIndex = 0;
    _pcInsideMainRegion = NO;
    _inCloakedSegment = NO;
    _finalRegionOverflowReported = NO;
    // Named-bank state (task #121) — rebuilt every pass1 so the
    // identifier→bank allocation and label→bank map track the current
    // (possibly rewrite-mutated) line list.
    _bankIds = [NSMutableDictionary dictionary];
    _labelBank = [NSMutableDictionary dictionary];

    // ── Sub-phase 1a: parse + scope-resolve every source line ──
    // Build a flat parsedLines list without touching _pc or _symbols,
    // so the spill-point look-ahead below can compute chunk sizes
    // from pl.byteSize without stepping through future source lines
    // a second time. Label scoping uses _lastGlobalLabel which is
    // purely a name-resolution concern, independent of PC.
    for (NSUInteger i = 0; i < sourceLines.count; i++)
        {
        NSString* rawLine = sourceLines[i];
        NSString* line = [self stripComment:rawLine];
        NSArray<NSString*>* compounds = [self splitCompoundLine:line];
        // Detect the long-branch rewriter's inverse-branch marker on
        // the original (un-stripped) line. parseLine sets rawText to
        // the comment-stripped `part`, which loses the `; longbr` tag —
        // so the auto-spill safety check below has to read this flag
        // off the parsedLine instead of grepping rawText.
        BOOL lineIsLongbrInverse = [rawLine containsString:@"; longbr"];

        for (NSString* part in compounds)
            {
            XAParsedLine* pl = [self parseLine:part lineNumber:i + 1];
            if (!pl)
                continue;
            if (lineIsLongbrInverse)
                pl.isLongbrInverse = YES;

            // Scope dot-prefixed local labels: .foo → lastGlobal.foo.
            // Internal long-branch skip labels (`_xlb_N`) must NOT become
            // the new lastGlobalLabel — otherwise any subsequent dotted
            // labels in the same routine get scoped to `_xlb_N` instead
            // of the enclosing routine.
            if (pl.label)
                {
                if ([pl.label hasPrefix:@"."] && _lastGlobalLabel)
                    {
                    pl.label = [NSString stringWithFormat:@"%@%@", _lastGlobalLabel, pl.label];
                    }
                else if (!pl.labelIsLocal && ![pl.label hasPrefix:@"_xlb_"])
                    {
                    _lastGlobalLabel = pl.label;
                    }
                }
            if (pl.operand)
                {
                pl.operand = [self scopeLocalLabelsInOperand:pl.operand];
                }

            [_parsedLines addObject:pl];
            }
        }

    // ── Sub-phase 1b: track PC, record labels, plan spills ──
    // Named-bank tracking (task #121): bankWindowSegSeen counts banked-
    // window segment starts in encounter order (`.org` into the window =
    // a codegen user bank; `.bank <id>` = a named runtime bank). A new
    // `.bank` id is allocated the next number, so it lands AFTER the
    // user banks (no clash). curDirectiveBank is the bank of the active
    // `.bank` region (0 = unbanked or a plain `.org`), used to tag each
    // label defined inside the region.
    NSUInteger bankWindowSegSeen = 0;
    NSUInteger curDirectiveBank = 0;
    BOOL haveBankWindow = (self.bankWindowStart != 0 || self.bankWindowEnd != 0);
    for (NSUInteger idx = 0; idx < _parsedLines.count; idx++)
        {
        XAParsedLine* pl = _parsedLines[idx];

        // Auto-spill: if the upcoming instruction or data directive
        // would push _pc past the end of the current code region and
        // there's a next region to fall into, synthesise a
        // `JMP <next-region-start>` plus a `.org <next-region-start>`
        // BEFORE processing this line so control flow is preserved
        // across the region gap. Only safe to insert when the
        // preceding instruction was an unconditional control transfer
        // (JMP / RTS / RTI) — otherwise a forward short branch before
        // this point might target a label past the bridge within ±127
        // bytes, and the 3-byte bridge + ~region-gap displacement
        // would push that target out of the branch's reach.
        // Final-region overflow: no next region to spill into, but the
        // current instruction would push PC past the region end. Emit
        // a clear error instead of silently wrapping and producing
        // corrupt bytes.
        if (_codeRegions &&
            !_inCloakedSegment &&
            _pcInsideMainRegion &&
            _currentRegionIndex + 1 >= _codeRegions.count &&
            (pl.type == XALineInstruction ||
             pl.type == XALineDirectiveByte ||
             pl.type == XALineDirectiveWord ||
             pl.type == XALineDirectiveLong ||
             pl.type == XALineDirectiveString ||
             pl.type == XALineDirectiveSpace) &&
            pl.byteSize > 0)
            {
            uint16_t finalEnd = (uint16_t)[_codeRegions[_currentRegionIndex][1]
                unsignedIntegerValue];
            if ((NSUInteger)_pc + pl.byteSize > (NSUInteger)finalEnd + 1 &&
                !_finalRegionOverflowReported)
                {
                [_mutableErrors addObject:[NSString stringWithFormat:
                                                        @"%@:%lu: program exceeds the declared .code_regions "
                                                        @"(last region ends at $%04X, tried to emit past it at PC $%04X). "
                                                        @"Reduce code size or add a larger region to the layout.",
                                                        filename, (unsigned long)pl.sourceLine, finalEnd, _pc]];
                _finalRegionOverflowReported = YES;
                }
            }
        if (_codeRegions &&
            !_inCloakedSegment &&
            _pcInsideMainRegion &&
            _currentRegionIndex + 1 < _codeRegions.count &&
            (pl.type == XALineInstruction ||
             pl.type == XALineDirectiveByte ||
             pl.type == XALineDirectiveWord ||
             pl.type == XALineDirectiveLong ||
             pl.type == XALineDirectiveString ||
             pl.type == XALineDirectiveSpace) &&
            pl.byteSize > 0)
            {
            uint16_t regionEnd = (uint16_t)[_codeRegions[_currentRegionIndex][1]
                unsignedIntegerValue];
            NSUInteger tail = (NSUInteger)_pc + pl.byteSize;
            NSUInteger limit = (NSUInteger)regionEnd + 1;
            // A `.space` is an uninitialised reservation (spill slots,
            // static data, buffers) — it's never executed, so it can
            // spill with a plain `.org` (no JMP bridge, hence no risk of
            // the "region too full for the bridge" failure). Without this
            // `.space` was excluded from the spill check entirely, so a
            // module-data `.space` straddling a non-final region boundary
            // silently overran into the next region (task #121: it pushed
            // the unbanked block past $3FFF into screen RAM).
            BOOL lineIsSpace = (pl.type == XALineDirectiveSpace);
            BOOL prevIsUnconditionalTransfer = NO;
            // Skip auto-spill when the previous line is part of a
            // long-branch rewriter pattern — its `; longbr` inverse
            // branch targets an `_xlb_N:` label three bytes ahead
            // (right after the JMP below). Bridging between them
            // shifts the label across the region gap and pass2 errors
            // out with branch-out-of-range. The rewriter can only
            // nest another rewrite here via its own iteration, not
            // mid-auto-spill.
            BOOL prevIsLongbrInverse = NO;
            if (idx > 0)
                {
                XAParsedLine* prev = _parsedLines[idx - 1];
                if (prev.type == XALineInstruction &&
                    ([prev.mnemonic isEqualToString:@"JMP"] ||
                     [prev.mnemonic isEqualToString:@"RTS"] ||
                     [prev.mnemonic isEqualToString:@"RTI"]))
                    {
                    prevIsUnconditionalTransfer = YES;
                    }
                if (prev.isLongbrInverse)
                    {
                    prevIsLongbrInverse = YES;
                    }
                }
            // Use a 6-byte runway (not just 3): it leaves room for
            // both a JMP bridge AND a short-branch-plus-longbr-JMP
            // pattern, so the rewriter's inverse-branch + JMP + skip
            // label trio stays together.
            if (tail > limit - 10 && (prevIsUnconditionalTransfer || lineIsSpace))
                {
                // Bridge is safe here — no fall-through from the
                // preceding instruction (transfer), or the overflowing
                // line is a never-executed `.space` reservation. Emit
                // just a `.org <next>` (no JMP needed).
                NSUInteger nextIdx = _currentRegionIndex + 1;
                uint16_t nextStart = (uint16_t)[_codeRegions[nextIdx][0] unsignedIntegerValue];
                XAParsedLine* org = [[XAParsedLine alloc] init];
                org.type = XALineDirectiveOrg;
                org.operand = [NSString stringWithFormat:@"$%04X", nextStart];
                org.rawText = [NSString stringWithFormat:@"    .org $%04X ; auto-spill",
                                                         nextStart];
                org.sourceLine = pl.sourceLine;
                [_parsedLines insertObject:org atIndex:idx];
                pl = _parsedLines[idx];
                }
            else if (tail > limit - 10 && !prevIsLongbrInverse)
                {
                // Fall-through from a non-terminator — emit the
                // 3-byte JMP bridge. May push a nearby forward
                // branch's target out of range; rewriteLongBranches
                // will handle that on the next iteration.
                if ((NSUInteger)_pc + 3 > (NSUInteger)regionEnd + 1)
                    {
                    [_mutableErrors addObject:[NSString stringWithFormat:
                                                            @"%@:%lu: region $%04X-$%04X too full for auto-spill JMP bridge at PC $%04X",
                                                            filename, (unsigned long)pl.sourceLine,
                                                            (unsigned)[_codeRegions[_currentRegionIndex][0] unsignedIntegerValue],
                                                            regionEnd, _pc]];
                    }
                else
                    {
                    NSUInteger nextIdx = _currentRegionIndex + 1;
                    uint16_t nextStart = (uint16_t)[_codeRegions[nextIdx][0] unsignedIntegerValue];
                    XAParsedLine* jmp = [[XAParsedLine alloc] init];
                    jmp.type = XALineInstruction;
                    jmp.mnemonic = @"JMP";
                    jmp.operand = [NSString stringWithFormat:@"$%04X", nextStart];
                    jmp.addressingMode = XAModeAbsolute;
                    jmp.rawText = [NSString stringWithFormat:@"    JMP $%04X ; auto-spill",
                                                             nextStart];
                    jmp.sourceLine = pl.sourceLine;
                    jmp.byteSize = 3;
                    XAParsedLine* org = [[XAParsedLine alloc] init];
                    org.type = XALineDirectiveOrg;
                    org.operand = [NSString stringWithFormat:@"$%04X", nextStart];
                    org.rawText = [NSString stringWithFormat:@"    .org $%04X ; auto-spill",
                                                             nextStart];
                    org.sourceLine = pl.sourceLine;
                    [_parsedLines insertObject:jmp atIndex:idx];
                    [_parsedLines insertObject:org atIndex:idx + 1];
                    pl = _parsedLines[idx];
                    }
                }
            }

        // Record label at the current PC before processing the line's
        // own effect on PC (same ordering as the original pass 1).
        if (pl.label)
            {
            if (!pl.labelIsLocal && _symbols[pl.label] && ![[[self platformSymbols] allKeys] containsObject:pl.label])
                {
                [_mutableErrors addObject:[NSString stringWithFormat:@"%@:%lu: duplicate label '%@'",
                                                                     filename, (unsigned long)pl.sourceLine, pl.label]];
                }
            _symbols[pl.label] = @(_pc);
            // Tag labels defined inside a `.bank` region with that bank,
            // so the cross-bank rewrite can route external JSR/JMP to
            // them through the trampoline (task #121).
            if (curDirectiveBank != 0)
                {
                _labelBank[pl.label] = @(curDirectiveBank);
                }
            }

        switch (pl.type)
            {
        case XALineDirectiveOrg:
            _pc = (uint16_t)[self evaluateExpression:pl.operand];
            [self syncCurrentRegionToPC];
            // A plain `.org` into the bank window is a codegen user
            // bank — count it (so a later `.bank` id allocates a
            // non-clashing number) but DON'T tag its labels (the
            // codegen stages those cross-bank calls itself).
            if (haveBankWindow && _pc >= self.bankWindowStart && _pc <= self.bankWindowEnd)
                {
                bankWindowSegSeen++;
                }
            curDirectiveBank = 0;
            break;
        case XALineDirectiveBank:
            {
            // Allocate (or reuse) the identifier's physical bank
            // number, continuing past the user banks seen so far.
            NSString* bankId = pl.operand ?: @"";
            NSNumber* assigned = _bankIds[bankId];
            if (!assigned)
                {
                bankWindowSegSeen++;
                assigned = @(bankWindowSegSeen);
                _bankIds[bankId] = assigned;
                }
            // Publish `__bank_<id>` so the harness's unbanked thunks can
            // stage the bank number into _xc_bank (task #121) without
            // knowing the allocation up front.
            _symbols[[NSString stringWithFormat:@"__bank_%@", bankId]] = assigned;
            curDirectiveBank = assigned.unsignedIntegerValue;
            _pc = self.bankWindowStart;
            [self syncCurrentRegionToPC];
            break;
            }
        case XALineDirectiveCloakedBegin:
            {
            // Operand: `<addr> [<bank>]` where <bank> is the
            // literal `none` or a decimal bank index. Only the
            // address matters in pass 1 (sizing); pass 2 parses
            // the bank token and stores it on the segment. Bare
            // tokens (no `=`) keep the directive from being
            // grabbed by the assignment-line detector.
            NSArray<NSString*>* parts =
                [(pl.operand ?: @"") componentsSeparatedByCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]];
            NSString* addrExpr = nil;
            for (NSString* p in parts)
                {
                if (p.length == 0)
                    continue;
                if (!addrExpr)
                    {
                    addrExpr = p;
                    break;
                    }
                }
            _pc = (uint16_t)[self evaluateExpression:addrExpr ?: @""];
            [self syncCurrentRegionToPC];
            _inCloakedSegment = YES;
            break;
            }
        case XALineDirectiveCloakedEnd:
            // Pass 1: clear the cloaked flag so the region-
            // overflow check resumes for any subsequent main-
            // RAM content. The XASegment boundary itself is
            // enforced in pass 2 by forcing a fresh segment at
            // the next line.
            _inCloakedSegment = NO;
            break;
        case XALineDirectiveCodeRegions:
            _codeRegions = [self parseRegionList:pl.operand
                                        filename:filename
                                            line:pl.sourceLine];
            [self syncCurrentRegionToPC];
            break;
        case XALineDirectiveShadowRanges:
            _shadowRanges = [self parseRegionList:pl.operand
                                         filename:filename
                                             line:pl.sourceLine];
            break;
        case XALineDirectiveShadowStage:
            {
            int64_t v = [self evaluateExpression:pl.operand];
            if (v < 0 || v > 0xFFFF)
                {
                [_mutableErrors addObject:[NSString stringWithFormat:
                                                        @"%@:%lu: invalid .shadow_stage address '%@'",
                                                        filename, (unsigned long)pl.sourceLine, pl.operand]];
                }
            else
                {
                _shadowStageBase = (uint16_t)v;
                }
            break;
            }
        case XALineDirectiveSpillPoint:
            [self handleSpillPointAt:idx
                            filename:filename];
            // handleSpillPointAt may rewrite pl's type to .org and
            // update _pc. If so, re-handle it as an org below.
            if (pl.type == XALineDirectiveOrg)
                {
                // PC is already set by handleSpillPointAt; nothing
                // more to do here (_pc == target region start).
                }
            break;
        case XALineInstruction:
            _pc += pl.byteSize;
            break;
        case XALineDirectiveByte:
        case XALineDirectiveWord:
        case XALineDirectiveLong:
        case XALineDirectiveString:
        case XALineDirectiveSpace:
            _pc += pl.byteSize;
            break;
        case XALineAssignment:
            _symbols[pl.assignName] = @([self evaluateExpression:pl.assignValue]);
            // Propagate bank membership through a simple alias
            // (`_fpAdd = fpAdd`): the codegen calls runtime helpers
            // by their `_`-prefixed alias, so the alias must inherit
            // the banked target's bank for the cross-bank rewrite to
            // fire on `JSR _fpAdd` (task #121). Only a bare-identifier
            // RHS that names a banked label propagates.
            if (pl.assignName && pl.assignValue)
                {
                NSString* rhs = [pl.assignValue stringByTrimmingCharactersInSet:
                                                    [NSCharacterSet whitespaceCharacterSet]];
                NSNumber* rhsBank = _labelBank[rhs];
                if (rhsBank)
                    _labelBank[pl.assignName] = rhsBank;
                }
            break;
        default:
            break;
            }
        }

    // Re-evaluate assignments after all labels have been seen. The
    // first-pass sweep processes lines top-to-bottom, so an equate
    // like `stack_top = stack_low + $200` resolves to 0 when
    // encountered before the `stack_low:` label a few KB further
    // down. Walk the parsed-line list again now that every label
    // is in `_symbols` and refresh any assignment whose RHS was
    // forward-referenced. Capped iteration count ensures we
    // terminate even if two equates reference each other.
    //
    // We can detect "needed a second look" by checking whether the
    // assignment's current value changes when re-evaluated against
    // the complete symbol table.
    for (int epoch = 0; epoch < 4; epoch++)
        {
        BOOL changed = NO;
        for (XAParsedLine* pl in _parsedLines)
            {
            if (pl.type != XALineAssignment)
                continue;
            int64_t newVal = [self evaluateExpression:pl.assignValue];
            NSNumber* cur = _symbols[pl.assignName];
            if (!cur || cur.longLongValue != newVal)
                {
                _symbols[pl.assignName] = @(newVal);
                changed = YES;
                }
            }
        if (!changed)
            break;
        }

    // Drop any diagnostics emitted while symbols were still
    // incomplete if they've now resolved successfully — spurious
    // "undefined symbol, using 0" warnings from forward-referenced
    // equates are gone as soon as the second pass finds them.
    if (_mutableWarnings.count > 0)
        {
        NSMutableArray<NSString*>* kept = [NSMutableArray array];
        for (NSString* w in _mutableWarnings)
            {
            BOOL drop = NO;
            NSRange r = [w rangeOfString:@"undefined symbol '"];
            if (r.location != NSNotFound)
                {
                NSUInteger start = r.location + r.length;
                NSRange end = [w rangeOfString:@"'"
                                       options:0
                                         range:NSMakeRange(start, w.length - start)];
                if (end.location != NSNotFound)
                    {
                    NSString* sym = [w substringWithRange:
                                           NSMakeRange(start, end.location - start)];
                    if (_symbols[sym] != nil)
                        drop = YES;
                    }
                }
            if (!drop)
                [kept addObject:w];
            }
        [_mutableWarnings setArray:kept];
        }
    }

#pragma mark - Code-region spillover

/****************************************************************************\
|* Parse the `.code_regions` operand string into a list of (start, end)
|* pairs. Expected format: "$XXXX-$YYYY, $XXXX-$YYYY, …" (addresses are
|* hex with a leading `$`). Returns nil on malformed input, with errors
|* appended to the diagnostics list.
\****************************************************************************/
- (nullable NSArray<NSArray<NSNumber*>*>*)parseRegionList:(NSString*)operand
                                                 filename:(NSString*)filename
                                                     line:(NSUInteger)lineNumber
    {
    if (!operand || operand.length == 0)
        return nil;
    NSArray<NSString*>* parts = [operand componentsSeparatedByString:@","];
    NSMutableArray<NSArray<NSNumber*>*>* ranges = [NSMutableArray array];
    for (NSString* p in parts)
        {
        NSString* trimmed = [p stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0)
            continue;
        NSRange dash = [trimmed rangeOfString:@"-"];
        if (dash.location == NSNotFound)
            {
            [_mutableErrors addObject:[NSString stringWithFormat:
                                                    @"%@:%lu: malformed .code_regions entry '%@' (expected $START-$END)",
                                                    filename, (unsigned long)lineNumber, trimmed]];
            return nil;
            }
        NSString* startStr = [[trimmed substringToIndex:dash.location]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        NSString* endStr = [[trimmed substringFromIndex:dash.location + 1]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        int64_t startVal = [self evaluateExpression:startStr];
        int64_t endVal = [self evaluateExpression:endStr];
        if (startVal < 0 || endVal < 0 || endVal < startVal)
            {
            [_mutableErrors addObject:[NSString stringWithFormat:
                                                    @"%@:%lu: invalid .code_regions range '%@'",
                                                    filename, (unsigned long)lineNumber, trimmed]];
            return nil;
            }
        [ranges addObject:@[ @((uint16_t)startVal), @((uint16_t)endVal) ]];
        }
    return ranges;
    }

/****************************************************************************\
|* Align _currentRegionIndex with _pc. Called after .org and
|* .code_regions directives so subsequent spill checks know which
|* region the assembler is actively filling.
\****************************************************************************/
- (void)syncCurrentRegionToPC
    {
    _pcInsideMainRegion = NO;
    if (!_codeRegions)
        return;
    for (NSUInteger i = 0; i < _codeRegions.count; i++)
        {
        uint16_t start = (uint16_t)[_codeRegions[i][0] unsignedIntegerValue];
        uint16_t end = (uint16_t)[_codeRegions[i][1] unsignedIntegerValue];
        if (_pc >= start && _pc <= end)
            {
            _currentRegionIndex = i;
            _pcInsideMainRegion = YES;
            return;
            }
        }
    // PC falls outside every declared region — bank-page `.org $4000`,
    // shadow-region `.org`, or a buffer the codegen didn't list. Leave
    // _currentRegionIndex where it was so a subsequent .org back into
    // main code doesn't reset the auto-spill cursor; the
    // _pcInsideMainRegion flag (now NO) is what gates overflow checks.
    }

/****************************************************************************\
|* Handle a `.spill_point` encountered at index `idx` in _parsedLines.
|* Sums the conservative byte size of the chunk starting at idx+1 and
|* ending at the next spill point, .org, or end of the parsed stream.
|* If the chunk wouldn't fit in the current code region and a next
|* region is available, rewrite the parsed line as a synthetic `.org`
|* targeting that region's start and advance _pc to match.
\****************************************************************************/
- (void)handleSpillPointAt:(NSUInteger)idx
                  filename:(NSString*)filename
    {
    if (!_codeRegions)
        return;
    if (_currentRegionIndex + 1 >= _codeRegions.count)
        return;

    uint16_t regionEnd = (uint16_t)[_codeRegions[_currentRegionIndex][1]
        unsignedIntegerValue];
    NSUInteger chunkSize = 0;
    for (NSUInteger j = idx + 1; j < _parsedLines.count; j++)
        {
        XAParsedLine* peek = _parsedLines[j];
        if (peek.type == XALineDirectiveSpillPoint)
            break;
        if (peek.type == XALineDirectiveOrg)
            break;
        chunkSize += peek.byteSize;
        // Early-out once the chunk clearly overflows — no need to keep
        // counting for a multi-KB worst-case chunk.
        if ((NSUInteger)_pc + chunkSize > (NSUInteger)regionEnd + 1)
            break;
        }
    if ((NSUInteger)_pc + chunkSize <= (NSUInteger)regionEnd + 1)
        return;

    // Spill: rewrite the parsed line as a synthetic .org so pass 2
    // starts a fresh segment at the next region's base.
    NSUInteger nextIdx = _currentRegionIndex + 1;
    uint16_t nextStart = (uint16_t)[_codeRegions[nextIdx][0] unsignedIntegerValue];
    XAParsedLine* pl = _parsedLines[idx];
    pl.type = XALineDirectiveOrg;
    pl.operand = [NSString stringWithFormat:@"$%04X", nextStart];
    _pc = nextStart;
    _currentRegionIndex = nextIdx;
    }

#pragma mark - Long Branch Rewriting

/****************************************************************************\
|* Scan parsed lines for branch instructions that exceed ±127 bytes.
|* For each one, replace the source line with:
|*   inverseBranch >_longbr_NNN
|*   JMP originalTarget
|*   >_longbr_NNN:
|* Returns the number of rewrites performed.
\****************************************************************************/
- (NSUInteger)rewriteLongBranches:(NSMutableArray<NSString*>*)sourceLines
    {
    // Build a PC map for each parsedLine
    NSMutableArray<NSNumber*>* pcMap = [NSMutableArray array];
    uint16_t pc = 0;
    for (XAParsedLine* pl in _parsedLines)
        {
        [pcMap addObject:@(pc)];
        if (pl.type == XALineDirectiveOrg)
            {
            pc = (uint16_t)[self evaluateExpression:pl.operand];
            }
        else if (pl.type == XALineDirectiveBank)
            {
            // A `.bank` region loads at the bank window (task #121) — set
            // PC so branch offsets inside the banked runtime are computed
            // correctly; otherwise a real long branch there is mis-judged
            // in-range and slips through to a pass-2 out-of-range error.
            pc = self.bankWindowStart;
            }
        else
            {
            pc += pl.byteSize;
            }
        }

    // Collect the source line indices that need rewriting.
    // Use a set to avoid double-rewriting the same line.
    NSMutableDictionary<NSNumber*, NSArray*>* replacements = [NSMutableDictionary dictionary];

    for (NSUInteger i = 0; i < _parsedLines.count; i++)
        {
        XAParsedLine* pl = _parsedLines[i];
        if (pl.type != XALineInstruction)
            continue;
        if (![_cpu isBranchMnemonic:pl.mnemonic])
            continue;

        NSString* targetExpr = pl.operand;
        if (!targetExpr)
            continue;
        int64_t target = [self evaluateExpression:targetExpr];
        uint16_t branchPC = [pcMap[i] unsignedShortValue];
        int64_t offset = target - (branchPC + 2);
        // 6502 PC addition wraps at 16 bits: a branch at $FFFE with
        // target $0003 has real offset +3, not -65533.  Mask to 16
        // bits and sign-extend to get the CPU's view of the offset.
        int64_t wrappedOffset = offset & 0xFFFF;
        if (wrappedOffset >= 0x8000)
            wrappedOffset -= 0x10000;
        if (wrappedOffset >= -128 && wrappedOffset <= 127)
            continue;

        NSUInteger srcLine = pl.sourceLine - 1;
        if (srcLine >= sourceLines.count)
            continue;
        if (replacements[@(srcLine)])
            continue;

        // BRA is unconditional, so an out-of-range one rewrites straight
        // to `JMP target` — no inverse-branch-over-JMP dance needed. The
        // auto-spill across `.code_regions` (e.g. $2400-$3FFF → $D800)
        // can push a BRA's target ~40 KB away; without this the BRA slips
        // through to a pass-2 out-of-range error (task #122 — the corpus
        // harness emits BRAs that straddle the region gap once ARC code
        // shifts the layout).
        if ([pl.mnemonic isEqualToString:@"BRA"])
            {
            replacements[@(srcLine)] = @[
                [NSString stringWithFormat:@"    JMP %@", targetExpr],
            ];
            continue;
            }

        NSString* inverse = XAInverseBranch()[pl.mnemonic];
        if (!inverse)
            continue;

        // A line marked `; longbr` has already been rewritten once.
        // If the rewritten inverse branch is STILL out of range —
        // typically because an auto-spill JMP bridge got inserted
        // between the inverse branch and its `_xlb_N` skip label —
        // fall through and rewrite the inverse branch itself. That
        // nests another (inverse-inverse = original-direction) short
        // branch over a fresh JMP to the distant `_xlb_N`. Without
        // this the outer iteration loop gives up and pass2 reports
        // a branch-out-of-range at the original line.

        NSString* skipLabel = [NSString stringWithFormat:@"_xlb_%lu",
                                                         (unsigned long)_longBranchCounter++];

        replacements[@(srcLine)] = @[
            [NSString stringWithFormat:@"    %@ %@ ; longbr", inverse, skipLabel],
            [NSString stringWithFormat:@"    JMP %@", targetExpr],
            [NSString stringWithFormat:@"%@:", skipLabel],
        ];
        }

    if (replacements.count == 0)
        return 0;

    // Apply in reverse order so indices stay valid
    NSArray<NSNumber*>* indices = [[replacements allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber* idx in [indices reverseObjectEnumerator])
        {
        NSUInteger lineIdx = idx.unsignedIntegerValue;
        NSArray<NSString*>* newLines = replacements[idx];
        [sourceLines replaceObjectAtIndex:lineIdx withObject:newLines[0]];
        for (NSUInteger j = 1; j < newLines.count; j++)
            {
            [sourceLines insertObject:newLines[j] atIndex:lineIdx + j];
            }
        }

    return replacements.count;
    }

/****************************************************************************\
|* Auto cross-bank call rewriting (task #121). A `JSR`/`JMP` to a BARE label
|* defined inside a `.bank <id>` region, made from a DIFFERENT bank (another
|* bank, a plain `.org` user bank, or unbanked main), is retargeted onto the
|* matching unbanked thunk: `JSR fpAdd` → `JSR _fpAdd`. The thunk (emitted by
|* the harness, one per banked entry) does the `_xcall` trampoline staging —
|* selecting the bank, calling, restoring — so the call site stays a single
|* 3-byte JSR/JMP. That size-preserving swap is the whole point: inlining the
|* ~18-byte staging at every call site would inflate the codegen's banked
|* user functions past their 16 KB budget (gfx8 fixtures hit exactly that).
|* The codegen already calls the runtime by its `_<name>` form, which IS the
|* thunk, so only the bare-name inline-asm calls need this rewrite. Calls
|* WITHIN the same `.bank` region stay plain (intra-bank, direct). Sound only
|* for the $B0-$BF clobber-safe ABI (the trampoline clobbers A). Mirrors
|* `rewriteLongBranches`: edits the raw source lines; caller re-runs pass 1.
\****************************************************************************/
- (NSUInteger)rewriteCrossBankCalls:(NSMutableArray<NSString*>*)sourceLines
    {
    if (_bankIds.count == 0 || _labelBank.count == 0)
        return 0;

    // Per source line, the cross-bank calls to retarget, each as
    // @[mnemonic, operand]. A single source line can hold several
    // colon-separated statements (inline asm emits e.g.
    // `LDA #<s : STA $B5 : ... : JSR asc2fp`), possibly more than one
    // cross-bank call — so collect them all rather than keying one
    // replacement per line.
    NSMutableDictionary<NSNumber*, NSMutableArray<NSArray<NSString*>*>*>* byLine =
        [NSMutableDictionary dictionary];
    NSCharacterSet* ws = [NSCharacterSet whitespaceCharacterSet];
    NSUInteger curBank = 0; // active `.bank` region's number (0 = none)

    for (NSUInteger i = 0; i < _parsedLines.count; i++)
        {
        XAParsedLine* pl = _parsedLines[i];
        // Track the call-site's bank. Only a `.bank` region sets a
        // non-zero bank; a plain `.org` (user bank or main) resets to 0,
        // which still differs from any runtime bank so its calls rewrite.
        if (pl.type == XALineDirectiveBank)
            {
            NSNumber* b = _bankIds[pl.operand ?: @""];
            curBank = b ? b.unsignedIntegerValue : 0;
            continue;
            }
        if (pl.type == XALineDirectiveOrg)
            {
            curBank = 0;
            continue;
            }
        if (pl.type != XALineInstruction)
            continue;
        if (![pl.mnemonic isEqualToString:@"JSR"] &&
            ![pl.mnemonic isEqualToString:@"JMP"])
            continue;
        if (!pl.operand)
            continue;
        NSString* op = [pl.operand stringByTrimmingCharactersInSet:ws];
        NSNumber* targetBank = _labelBank[op];
        if (!targetBank)
            continue; // not a banked label
        if (targetBank.unsignedIntegerValue == curBank)
            continue; // intra-bank

        NSUInteger srcLine = pl.sourceLine - 1;
        if (srcLine >= sourceLines.count)
            continue;
        NSMutableArray<NSArray<NSString*>*>* calls = byLine[@(srcLine)];
        if (!calls)
            {
            calls = [NSMutableArray array];
            byLine[@(srcLine)] = calls;
            }
        [calls addObject:@[ pl.mnemonic, op ]];
        }

    if (byLine.count == 0)
        return 0;

    // Retarget each cross-bank call onto its unbanked thunk `_<op>`
    // (size-preserving), rewriting ONLY the matching `JSR/JMP <op>`
    // statement and leaving every other colon-separated statement on the
    // line untouched. Replacing the whole line (the old behaviour) dropped
    // any preceding statements — e.g. the `STA $B5/$B6` pointer staging
    // ahead of `JSR asc2fp` — so the callee ran with a garbage operand.
    NSUInteger rewritten = 0;
    for (NSNumber* idx in byLine)
        {
        NSArray<NSArray<NSString*>*>* calls = byLine[idx];
        NSString* line = sourceLines[idx.unsignedIntegerValue];
        NSArray<NSString*>* stmts = [line componentsSeparatedByString:@":"];
        NSMutableArray<NSString*>* out = [NSMutableArray array];
        NSCharacterSet* opEnd =
            [NSCharacterSet characterSetWithCharactersInString:@" \t;"];
        for (NSString* stmt in stmts)
            {
            NSString* t = [stmt stringByTrimmingCharactersInSet:ws];
            NSString* replacement = nil;
            for (NSArray<NSString*>* mo in calls)
                {
                NSString *mn = mo[0], *op = mo[1];
                NSString* prefix = [mn stringByAppendingString:@" "];
                if (![t hasPrefix:prefix])
                    continue;
                // The operand is the first token after the mnemonic; stop at
                // whitespace or a `;` comment so a trailing comment / extra
                // spacing doesn't defeat the match (an unmatched cross-bank
                // JSR would stay a direct jump into an unmapped bank → crash).
                NSString* rest = [[t substringFromIndex:prefix.length]
                    stringByTrimmingCharactersInSet:ws];
                NSRange cut = [rest rangeOfCharacterFromSet:opEnd];
                NSString* tok = (cut.location == NSNotFound)
                                    ? rest
                                    : [rest substringToIndex:cut.location];
                if ([tok isEqualToString:op])
                    {
                    replacement = [NSString stringWithFormat:@" %@ _%@", mn, op];
                    break;
                    }
                }
            if (replacement)
                {
                [out addObject:replacement];
                rewritten++;
                }
            else
                {
                [out addObject:stmt];
                }
            }
        sourceLines[idx.unsignedIntegerValue] =
            [out componentsJoinedByString:@":"];
        }
    return rewritten;
    }

// Methods moved to XAAssembler+Pass2.m / .h
// Methods moved to XAAssembler+Output.m / .h
@end
