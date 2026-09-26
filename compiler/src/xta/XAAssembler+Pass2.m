/****************************************************************************\
|* XAAssembler+Pass2.m
\****************************************************************************/
#import "XAAssembler+Private.h"

@implementation XAAssembler (Pass2)

#pragma mark - Pass 2: Emit Bytes

/****************************************************************************\
|* Pass 2: resolve all expressions and emit bytes into segments. Walks
|* the parsedLines array from pass 1 and produces the final binary data.
|* @return  An array of XASegment objects containing the assembled bytes.
\****************************************************************************/
- (NSArray<XASegment*>*)pass2
    {
    self.undefinedReported = [NSMutableSet set];
    NSArray<XASegment*>* segments = [self pass2Lines];
    self.evalLine = nil;
    return segments;
    }

- (NSArray<XASegment*>*)pass2Lines
    {
    NSMutableArray<XASegment*>* segments = [NSMutableArray array];
    XASegment* currentSeg = nil;
    self.pc = 0;

    for (XAParsedLine* pl in self.parsedLines)
        {
        self.evalLine = pl;
        switch (pl.type)
            {
        case XALineDirectiveOrg:
            {
            uint16_t newPc = (uint16_t)[self evaluateExpression:pl.operand];
            // A small forward .org within the same region
            // (typical case: the banked target packs sumS1
            // at $6000, sumS2 at $6100, sumS3 at $6200, …
            // into one bank page) pads with zeros and keeps
            // the current segment going. Without this, each
            // function became its own XEX segment and the
            // writer handed every one a fresh bank number,
            // so calls to sumS2..N landed on the page that
            // held sumS1.
            // A large forward jump (e.g. the transition from
            // non-banked main at $2000-$33xx to the banked
            // window at $6000) MUST start a new segment —
            // padding across would collapse both regions
            // into one XEX load and the banked area would
            // then go through the main-segment path instead
            // of the large-class loader. The 8KB (a full
            // bank) threshold is a pragmatic pick: function-
            // packing gaps are tens of bytes, zone changes
            // are always multi-KB.
            // Intra-function padding gaps are typically
            // tens of bytes, at most a few hundred for
            // page alignment. Region transitions (non-
            // banked $2000 → banked $6000, main → heap,
            // etc.) are always multi-KB. A 256-byte
            // threshold cleanly separates the two cases.
            const uint16_t PAD_THRESHOLD = 0x100;
            BOOL forward = currentSeg && newPc >= self.pc;
            // A spill-rewritten .org crosses from one declared
            // code region into the next (e.g. $BFxx → $C000
            // when the layout has `.code_regions $A000-$BFFF,
            // $C000-$CFFF, …`). The addresses are a handful of
            // bytes apart so the PAD_THRESHOLD branch above
            // would otherwise zero-pad across the gap and keep
            // both regions in a single XEX segment — which then
            // trips the main-region overflow check even though
            // the layout has room, because the hardware won't
            // load the merged segment past the first region's
            // end. Force a segment break when .org moves from
            // one self.codeRegions entry to a later one.
            BOOL crossesRegion = NO;
            if (forward && self.codeRegions.count > 1 && currentSeg)
                {
                uint16_t curPc = self.pc;
                NSUInteger curIdx = NSNotFound, newIdx = NSNotFound;
                for (NSUInteger i = 0; i < self.codeRegions.count; i++)
                    {
                    uint16_t rs = (uint16_t)[self.codeRegions[i][0] unsignedIntegerValue];
                    uint16_t re = (uint16_t)[self.codeRegions[i][1] unsignedIntegerValue];
                    if (curPc >= rs && curPc <= re)
                        curIdx = i;
                    if (newPc >= rs && newPc <= re)
                        newIdx = i;
                    }
                if (curIdx != NSNotFound && newIdx != NSNotFound && newIdx > curIdx)
                    {
                    crossesRegion = YES;
                    }
                }
            // Two consecutive `.org $6000` with no bytes
            // between them represent two distinct bank
            // slots. The banked codegen emits one anchor
            // per bank page, and the optimiser's DCE can
            // leave empty anchors behind when every function
            // on a page gets inlined away — at -O3, for
            // example, all of add3/sub/doubleIt get inlined
            // into main and the page-$02 anchor is preserved
            // by the optimiser's `.org` carve-out but its
            // contents vanish. If we merged the empty slot
            // with the next slot's anchor, writeBankedXEX
            // would hand the NEXT class a lower bank number
            // than its callers encoded — JSRs would swap in
            // an empty bank and hit BRK. Start a fresh
            // segment whenever the current segment is empty
            // and we're .org'ing to the same address, so the
            // empty bank slot survives as a placeholder and
            // the writer still assigns it a bankPage.
            BOOL sameAddrEmptySeg = currentSeg &&
                                    newPc == currentSeg.origin &&
                                    currentSeg.data.length == 0;
            if (forward && (newPc - self.pc) < PAD_THRESHOLD && !sameAddrEmptySeg && !crossesRegion)
                {
                uint8_t zero = 0;
                while (self.pc < newPc)
                    {
                    [currentSeg.data appendBytes:&zero length:1];
                    self.pc++;
                    }
                }
            else
                {
                self.pc = newPc;
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            break;
            }
        case XALineDirectiveCloakedBegin:
            {
            // Start a fresh segment at the given origin and mark
            // it cloaked so writeBankedXEX brackets it with the
            // matching PORTB-prep INITAD stub. The operand has
            // the form `<addr> [<bank>]` where <bank> is the
            // literal `none` (banking-off region) or a decimal
            // bank index. Missing token defaults to `none` for
            // back-compat with the original single-region form.
            NSArray<NSString*>* parts =
                [(pl.operand ?: @"") componentsSeparatedByCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]];
            NSString* addrExpr = nil;
            NSString* bankTok = nil;
            for (NSString* p in parts)
                {
                if (p.length == 0)
                    continue;
                if (!addrExpr)
                    {
                    addrExpr = p;
                    }
                else if (!bankTok)
                    {
                    bankTok = p;
                    break;
                    }
                }
            int bankIndex = -1;
            if (bankTok &&
                ![bankTok.lowercaseString isEqualToString:@"none"])
                {
                bankIndex = (int)[self evaluateExpression:bankTok];
                }
            self.pc = (uint16_t)[self evaluateExpression:addrExpr ?: @""];
            currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
            currentSeg.isCloaked = YES;
            currentSeg.cloakedBankIndex = bankIndex;
            [segments addObject:currentSeg];
            break;
            }
        case XALineDirectiveCloakedEnd:
            {
            // End the cloaked segment — the next emission starts a
            // new segment automatically (whatever directive follows
            // will allocate one on demand).
            currentSeg = nil;
            break;
            }
        case XALineDirectiveBank:
            {
            // Open a named banked region (task #121): start a fresh
            // segment at the bank window with the identifier's
            // pre-allocated physical bank number (from pass 1's
            // `_bankIds` map). writeBankedXEX uses that number for
            // the preload stub, matching the cross-bank rewrite's
            // staging.
            self.pc = self.bankWindowStart;
            currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
            NSNumber* bn = self.bankIds[pl.operand ?: @""];
            currentSeg.bankNumber = bn ? (NSInteger)bn.unsignedIntegerValue : -1;
            [segments addObject:currentSeg];
            break;
            }
        case XALineLabel:
        case XALineAssignment:
        case XALineEmpty:
            break;
        case XALineInstruction:
            {
            if (!currentSeg)
                {
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            [self emitInstruction:pl into:currentSeg];
            self.pc += pl.byteSize;
            break;
            }
        case XALineDirectiveByte:
            {
            if (!currentSeg)
                {
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            for (NSString* val in pl.dataValues)
                {
                uint8_t b = (uint8_t)[self evaluateExpression:val];
                [currentSeg.data appendBytes:&b length:1];
                }
            self.pc += pl.byteSize;
            break;
            }
        case XALineDirectiveWord:
            {
            if (!currentSeg)
                {
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            for (NSString* val in pl.dataValues)
                {
                uint16_t w = (uint16_t)[self evaluateExpression:val];
                uint8_t lo = w & 0xFF, hi = (w >> 8) & 0xFF;
                [currentSeg.data appendBytes:&lo length:1];
                [currentSeg.data appendBytes:&hi length:1];
                }
            self.pc += pl.byteSize;
            break;
            }
        case XALineDirectiveLong:
            {
            if (!currentSeg)
                {
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            for (NSString* val in pl.dataValues)
                {
                uint32_t l = (uint32_t)[self evaluateExpression:val];
                for (int b = 0; b < 4; b++)
                    {
                    uint8_t byte = (l >> (b * 8)) & 0xFF;
                    [currentSeg.data appendBytes:&byte length:1];
                    }
                }
            self.pc += pl.byteSize;
            break;
            }
        case XALineDirectiveString:
            {
            if (!currentSeg)
                {
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            const char* str = pl.operand.UTF8String;
            [currentSeg.data appendBytes:str length:strlen(str)];
            uint8_t nul = 0;
            [currentSeg.data appendBytes:&nul length:1];
            self.pc += pl.byteSize;
            break;
            }
        case XALineDirectiveSpace:
            {
            if (!currentSeg)
                {
                currentSeg = [[XASegment alloc] initWithOrigin:self.pc];
                [segments addObject:currentSeg];
                }
            NSUInteger count = pl.byteSize;
            uint8_t zero = 0;
            for (NSUInteger i = 0; i < count; i++)
                {
                [currentSeg.data appendBytes:&zero length:1];
                }
            self.pc += count;
            break;
            }
        default:
            break;
            }
        }

    return segments;
    }

/****************************************************************************\
|* Emit a single instruction's bytes into a segment. Resolves the operand
|* expression, handles ZP-to-absolute fallback, and computes relative
|* branch offsets.
|* @param pl   The parsed instruction line.
|* @param seg  The target segment to append bytes to.
\****************************************************************************/
- (void)emitInstruction:(XAParsedLine*)pl into:(XASegment*)seg
    {
    NSInteger opcode = [self.cpu opcodeForMnemonic:pl.mnemonic mode:pl.addressingMode];

    // If ZP mode fails, try Absolute as fallback
    if (opcode < 0 && pl.addressingMode == XAModeZeroPage)
        {
        pl.addressingMode = XAModeAbsolute;
        pl.byteSize = 3;
        opcode = [self.cpu opcodeForMnemonic:pl.mnemonic mode:pl.addressingMode];
        }
    if (opcode < 0 && pl.addressingMode == XAModeZeroPageX)
        {
        pl.addressingMode = XAModeAbsoluteX;
        pl.byteSize = 3;
        opcode = [self.cpu opcodeForMnemonic:pl.mnemonic mode:pl.addressingMode];
        }
    if (opcode < 0 && pl.addressingMode == XAModeZeroPageY)
        {
        pl.addressingMode = XAModeAbsoluteY;
        pl.byteSize = 3;
        opcode = [self.cpu opcodeForMnemonic:pl.mnemonic mode:pl.addressingMode];
        }

    if (opcode < 0)
        {
        [self.mutableErrors addObject:[NSString stringWithFormat:@"line %lu: invalid addressing mode for %@",
                                                                 (unsigned long)pl.sourceLine, pl.mnemonic]];
        return;
        }

    uint8_t op = (uint8_t)opcode;
    [seg.data appendBytes:&op length:1];

    if (pl.byteSize == 1)
        return;

    // Resolve operand
    NSString* exprStr = [self extractExpression:pl.operand mode:pl.addressingMode];
    self.evalUndefined = NO;
    int64_t value = [self evaluateExpression:exprStr];

    // Internal-error tripwire: a memory-addressed instruction whose
    // operand is a symbolic identifier (LDA foo, STA bar, JSR baz,
    // …) but resolves to $0000 is almost always the compiler having
    // generated a reference to a symbol it forgot to define — e.g.
    // the class-method param-spill bug where `Stdio.printStr("s")`
    // emitted `LDA s` against an undefined `s` and the assembler
    // silently resolved it to zero, so the method read a pointer
    // from $0000 and walked into zero-page garbage. Warn so the
    // next time some ZP slot goes missing the build makes noise
    // instead of producing a binary that "almost" works.
    // Only flag symbolic operands — numeric-literal zeros like
    // `LDA $00` (legitimate zero-page scratch) or branch targets
    // that happen to fall at offset 0 shouldn't trigger. An
    // operand is considered symbolic if it contains at least one
    // identifier character.
    // An undefined symbol is already an error; the tripwire is for a symbol
    // that IS defined, as 0.
    if (value == 0 && !self.evalUndefined)
        {
        BOOL isMemAddressed =
            pl.addressingMode == XAModeZeroPage ||
            pl.addressingMode == XAModeZeroPageX ||
            pl.addressingMode == XAModeZeroPageY ||
            pl.addressingMode == XAModeAbsolute ||
            pl.addressingMode == XAModeAbsoluteX ||
            pl.addressingMode == XAModeAbsoluteY ||
            pl.addressingMode == XAModeIndirect;
        if (isMemAddressed)
            {
            BOOL hasIdent = NO;
            NSCharacterSet* letters = [NSCharacterSet letterCharacterSet];
            for (NSUInteger i = 0; i < exprStr.length; i++)
                {
                unichar c = [exprStr characterAtIndex:i];
                if ([letters characterIsMember:c] || c == '_')
                    {
                    hasIdent = YES;
                    break;
                    }
                }
            if (hasIdent)
                {
                [self.mutableWarnings addObject:[NSString stringWithFormat:
                                                              @"line %lu: %@ %@ resolves to $0000 — probable undefined symbol "
                                                              @"(compiler internal error?)",
                                                              (unsigned long)pl.sourceLine, pl.mnemonic, exprStr]];
                }
            }
        }

    if (pl.addressingMode == XAModeRelative)
        {
        // Compute relative offset: target - (PC + 2).
        // 6502 PC addition wraps at 16 bits — mask and sign-extend so
        // that a branch at $FFFE → $0003 is recognised as offset +3
        // rather than -65533 and not spuriously flagged out of range.
        int64_t offset = value - (self.pc + 2);
        int64_t wrappedOffset = offset & 0xFFFF;
        if (wrappedOffset >= 0x8000)
            wrappedOffset -= 0x10000;
        if (wrappedOffset < -128 || wrappedOffset > 127)
            {
            [self.mutableErrors addObject:[NSString stringWithFormat:@"line %lu: branch out of range (%lld) — %@ %@ at $%04X → $%04llX",
                                                                     (unsigned long)pl.sourceLine, (long long)offset,
                                                                     pl.mnemonic, pl.operand, self.pc, (long long)value]];
            }
        uint8_t b = (uint8_t)(offset & 0xFF);
        [seg.data appendBytes:&b length:1];
        }
    else if (pl.addressingMode == XAModeSPRelative || pl.addressingMode == XAModeStackAdjust || pl.addressingMode == XAModeSPIndirectIndexedY || pl.addressingMode == XAModeSPIndexedX)
        {
        // Signed 8-bit immediate. SP-relative offset d ∈ [−128, +127]
        // (docs/6502/6502-embellishments.md §2); ADD SP, #imm and the
        // §2b stack-indirect/indexed modes use the same encoding.
        // Out-of-range is a hard error — silent truncation would
        // produce mis-targeted stack accesses.
        if (value < -128 || value > 127)
            {
            [self.mutableErrors addObject:[NSString stringWithFormat:
                                                        @"line %lu: %@ %@ — signed-8-bit %@ out of range (%lld); "
                                                        @"xt SP-relative addressing only reaches ±128 bytes",
                                                        (unsigned long)pl.sourceLine, pl.mnemonic, pl.operand,
                                                        pl.addressingMode == XAModeSPRelative ? @"offset" : @"stack adjustment",
                                                        (long long)value]];
            }
        uint8_t b = (uint8_t)(value & 0xFF);
        [seg.data appendBytes:&b length:1];
        }
    else if (pl.byteSize == 2 && pl.addressingMode == XAModeImmediate && ([pl.mnemonic isEqualToString:@"PSH"] || [pl.mnemonic isEqualToString:@"PLL"]))
        {
        // PSH/PLL #N take an UNSIGNED 8-bit immediate. Out-of-range
        // is a hard error (silent truncation would mis-size the
        // prologue's frame allocation).
        if (value < 0 || value > 255)
            {
            [self.mutableErrors addObject:[NSString stringWithFormat:
                                                        @"line %lu: %@ #%lld — immediate out of range (0..255); "
                                                        @"larger frames must chain PSH/PLL pairs (see STACK-ABI.md §6.1)",
                                                        (unsigned long)pl.sourceLine, pl.mnemonic, (long long)value]];
            }
        uint8_t b = (uint8_t)(value & 0xFF);
        [seg.data appendBytes:&b length:1];
        }
    else if (pl.byteSize == 2)
        {
        // Indirect-indexed-Y / indexed-indirect-X resolve through a
        // ZP pointer; an operand outside $00-$FF means the symbol the
        // user named lives in main memory (data section spill, label
        // in code etc.) and we'd silently truncate to its low byte.
        // The 6502 then forms an indirect address from whatever
        // happens to be at that ZP location — almost certainly
        // garbage at runtime. Warn (don't error) because these emits
        // sometimes show up in dead-code paths the optimiser kept
        // around: e.g. a Gfx8.plot inline-asm body the codegen spilled
        // because line()'s frame was already huge, but line()'s
        // executed path goes through a different inline expansion so
        // the spilled body never fires. Erroring there would break
        // 30+ existing fixtures whose passing builds happen to never
        // execute the bad bytes. The warning still surfaces the
        // problem — symptom prior to surfacing it: foundation
        // `Gfx8.plot`'s `LDA (_g8p_ptr),Y` silently truncated
        // `_g8p_ptr` (= $A659 after spill) to $59, plot then
        // dereferenced through random ZP — silent until something
        // (e.g. hoisting oval to Gfx, exposing plot to virtual
        // dispatch) made the path live.
        if ((pl.addressingMode == XAModeIndirectIndexedY ||
             pl.addressingMode == XAModeIndexedIndirectX) &&
            (value < 0 || value > 0xFF))
            {
            [self.mutableWarnings addObject:[NSString stringWithFormat:
                                                          @"line %lu: %@ %@ — indirect-indexed addressing requires "
                                                          @"a zero-page operand (got $%04llX). The symbol resolves "
                                                          @"to main memory (data-section spill?); the runtime read "
                                                          @"will go through ZP $%02llX which holds unrelated bytes. "
                                                          @"Likely a codegen-side ZP-pressure issue; if this code "
                                                          @"path executes the program will misbehave.",
                                                          (unsigned long)pl.sourceLine, pl.mnemonic, pl.operand,
                                                          (long long)value, (long long)(value & 0xFF)]];
            }
        uint8_t b = (uint8_t)(value & 0xFF);
        [seg.data appendBytes:&b length:1];
        }
    else if (pl.byteSize == 3)
        {
        uint8_t lo = (uint8_t)(value & 0xFF);
        uint8_t hi = (uint8_t)((value >> 8) & 0xFF);
        [seg.data appendBytes:&lo length:1];
        [seg.data appendBytes:&hi length:1];
        }
    }

/****************************************************************************\
|* Extract the numeric expression from an operand string, stripping addressing mode syntax.
\****************************************************************************/
- (NSString*)extractExpression:(NSString*)operand mode:(XAAddressingMode)mode
    {
    if (!operand)
        return @"0";
    NSString* op = [operand stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    switch (mode)
        {
    case XAModeImmediate:
        return [op substringFromIndex:1]; // strip '#'
    case XAModeIndexedIndirectX:
        {
        // ($nn,X) → strip ( and ,X)
        NSString* inner = [op substringWithRange:NSMakeRange(1, op.length - 4)];
        return [inner stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    case XAModeIndirectIndexedY:
        {
        // ($nn),Y → strip ( and ),Y
        NSRange paren = [op rangeOfString:@")"];
        NSString* inner = [op substringWithRange:NSMakeRange(1, paren.location - 1)];
        return [inner stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    case XAModeIndirect:
        {
        // ($nnnn) → strip parens
        return [[op substringWithRange:NSMakeRange(1, op.length - 2)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    case XAModeZeroPageX:
    case XAModeAbsoluteX:
        return [[op substringToIndex:op.length - 2]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    case XAModeZeroPageY:
    case XAModeAbsoluteY:
        return [[op substringToIndex:op.length - 2]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    case XAModeSPRelative:
        {
        // Strip the trailing `,SP` (case-insensitive — the suffix
        // check at detectAddressingMode time ensures it's
        // present). What remains is a signed-offset expression
        // (e.g. "+5", "-1", "+(N+9)"). The expression evaluator's
        // add/sub split only fires when the operator is at index
        // > 0, so we prefix `0` to coerce leading sign tokens
        // into a normal binary form: "+5" → "0+5", "-1" → "0-1",
        // "+(N+9)" → "0+(N+9)".
        // Locate the `,SP` end-marker from the rightmost end so a
        // trailing-whitespace or trailing-comma form still works.
        NSRange spRange = [op rangeOfString:@",SP" options:(NSCaseInsensitiveSearch | NSBackwardsSearch)];
        NSString* inner = (spRange.location == NSNotFound)
                              ? op
                              : [op substringToIndex:spRange.location];
        inner = [inner stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return [@"0" stringByAppendingString:inner];
        }
    case XAModeStackAdjust:
        {
        // Strip the leading `SP,` prefix and the optional `#`
        // marker on the immediate. Same "prefix 0" trick to let
        // the evaluator parse "-12" as "0-12".
        NSString* after = [op substringFromIndex:3];
        after = [after stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([after hasPrefix:@"#"])
            after = [after substringFromIndex:1];
        return [@"0" stringByAppendingString:after];
        }
    case XAModeSPIndirectIndexedY:
        {
        // (offset,SP),Y → strip the leading `(` and the trailing
        // `,SP),Y`; what remains is the signed-offset expression
        // (same `0`-prefix coercion as XAModeSPRelative).
        NSRange spRange = [op rangeOfString:@",SP" options:(NSCaseInsensitiveSearch | NSBackwardsSearch)];
        NSString* inner = (spRange.location == NSNotFound || op.length < 1)
                              ? op
                              : [op substringWithRange:NSMakeRange(1, spRange.location - 1)];
        inner = [inner stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return [@"0" stringByAppendingString:inner];
        }
    case XAModeSPIndexedX:
        {
        // offset,SP,X → strip the trailing `,SP,X`.
        NSRange spRange = [op rangeOfString:@",SP" options:(NSCaseInsensitiveSearch | NSBackwardsSearch)];
        NSString* inner = (spRange.location == NSNotFound)
                              ? op
                              : [op substringToIndex:spRange.location];
        inner = [inner stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return [@"0" stringByAppendingString:inner];
        }
    default:
        return op;
        }
    }

/****************************************************************************\
|* Expand dot-prefixed local label references in an operand using the current scope.
\****************************************************************************/
- (NSString*)scopeLocalLabelsInOperand:(NSString*)operand
    {
    if (!self.lastGlobalLabel)
        return operand;
    if (!operand)
        return operand;
    // Quick check: does it contain a dot-prefixed identifier?
    if ([operand rangeOfString:@"."].location == NSNotFound)
        return operand;
    // Replace occurrences of .identifier with lastGlobal.identifier, but
    // only when the dot is not already preceded by an identifier
    // character — otherwise we'd re-scope an already-scoped operand like
    // "fpAdd.fa_ret_a" (produced by rewriteLongBranches) into
    // "fpAddfpAdd.fa_ret_a".
    NSMutableString* result = [NSMutableString stringWithString:operand];
    NSRegularExpression* regex = [NSRegularExpression
        regularExpressionWithPattern:@"(?<![a-zA-Z0-9_])\\.[a-zA-Z_][a-zA-Z0-9_]*"
                             options:0
                               error:nil];
    // Process matches in reverse to preserve indices
    NSArray<NSTextCheckingResult*>* matches = [regex matchesInString:operand
                                                             options:0
                                                               range:NSMakeRange(0, operand.length)];
    for (NSTextCheckingResult* match in [matches reverseObjectEnumerator])
        {
        NSString* localRef = [operand substringWithRange:match.range];
        // Don't scope .byte, .word, .org etc. (assembler directives)
        NSString* afterDot = [localRef substringFromIndex:1];
        if ([afterDot isEqualToString:@"byte"] || [afterDot isEqualToString:@"word"] ||
            [afterDot isEqualToString:@"org"] || [afterDot isEqualToString:@"dbyte"] ||
            [afterDot isEqualToString:@"end"])
            continue;
        NSString* scoped = [NSString stringWithFormat:@"%@%@", self.lastGlobalLabel, localRef];
        [result replaceCharactersInRange:match.range withString:scoped];
        }
    return result;
    }

#pragma mark - Expression Evaluation

/****************************************************************************\
|* Evaluate an expression string to a 64-bit integer. Supports $hex, %bin,
|* Z80-style hex (NNNNh), decimal, low/high byte extraction, arithmetic,
|* and symbol lookup.
|* @param expr  The expression string to evaluate.
|* @return  The computed value, or 0 for undefined symbols (with a warning).
\****************************************************************************/
- (int64_t)evaluateExpression:(NSString*)expr
    {
    if (!expr)
        return 0;
    NSString* e = [expr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (e.length == 0)
        return 0;

    // Handle < (low byte) and > (high byte) prefix operators
    if ([e hasPrefix:@"<"])
        {
        return [self evaluateExpression:[e substringFromIndex:1]] & 0xFF;
        }
    if ([e hasPrefix:@">"])
        {
        return ([self evaluateExpression:[e substringFromIndex:1]] >> 8) & 0xFF;
        }

    // Handle simple arithmetic: try to split on +, -, *, /
    // Find the last +/- at the top level (not inside parens)
    NSInteger parenDepth = 0;
    NSInteger lastAddSub = -1;
    NSInteger lastMulDiv = -1;
    for (NSInteger i = (NSInteger)e.length - 1; i >= 0; i--)
        {
        unichar ch = [e characterAtIndex:(NSUInteger)i];
        if (ch == ')')
            parenDepth++;
        else if (ch == '(')
            parenDepth--;
        else if (parenDepth == 0)
            {
            if ((ch == '+' || ch == '-') && i > 0)
                {
                lastAddSub = i;
                break;
                }
            if ((ch == '*' || ch == '/') && i > 0 && lastMulDiv < 0)
                {
                lastMulDiv = i;
                }
            }
        }
    if (lastAddSub > 0)
        {
        int64_t left = [self evaluateExpression:[e substringToIndex:(NSUInteger)lastAddSub]];
        unichar op = [e characterAtIndex:(NSUInteger)lastAddSub];
        int64_t right = [self evaluateExpression:[e substringFromIndex:(NSUInteger)lastAddSub + 1]];
        return (op == '+') ? left + right : left - right;
        }
    if (lastMulDiv > 0)
        {
        int64_t left = [self evaluateExpression:[e substringToIndex:(NSUInteger)lastMulDiv]];
        unichar op = [e characterAtIndex:(NSUInteger)lastMulDiv];
        int64_t right = [self evaluateExpression:[e substringFromIndex:(NSUInteger)lastMulDiv + 1]];
        return (op == '*') ? left * right : (right != 0 ? left / right : 0);
        }

    // Parenthesized expression
    if ([e hasPrefix:@"("] && [e hasSuffix:@")"])
        {
        return [self evaluateExpression:[e substringWithRange:NSMakeRange(1, e.length - 2)]];
        }

    // Literal numbers
    if ([e hasPrefix:@"$"])
        {
        return (int64_t)strtoull([e substringFromIndex:1].UTF8String, NULL, 16);
        }
    if ([e hasPrefix:@"%"])
        {
        return (int64_t)strtoull([e substringFromIndex:1].UTF8String, NULL, 2);
        }
    // Z80-style hex suffix: `NNNNh` / `NNNNH`. A defined symbol
    // always wins over the suffix interpretation so pathological
    // labels like `0abch` or `12fh` (digit-first, all-hex, trailing
    // h — indistinguishable from Z80 literals by any heuristic)
    // resolve to the label when one exists. The first-char-is-digit
    // guard below still protects `fa_finish`/`abch`/`.abch` even if
    // they aren't defined yet (e.g. forward references during pass 1).
    if (self.symbols[e])
        {
        if (([e hasSuffix:@"h"] || [e hasSuffix:@"H"]) && e.length > 1 && [e characterAtIndex:0] >= '0' && [e characterAtIndex:0] <= '9')
            {
            BOOL allHex = YES;
            for (NSUInteger i = 0; i < e.length - 1; i++)
                {
                unichar c = [e characterAtIndex:i];
                BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
                if (!isHex)
                    {
                    allHex = NO;
                    break;
                    }
                }
            if (allHex && ![self.ambiguousHexLabelsWarned containsObject:e])
                {
                [self.ambiguousHexLabelsWarned addObject:e];
                [self.mutableWarnings addObject:[NSString stringWithFormat:
                                                              @"label '%@' is ambiguous with Z80-style hex literal; "
                                                              @"resolving to the label — rename it or use $%@ to "
                                                              @"silence this warning",
                                                              e, [e substringToIndex:e.length - 1]]];
                }
            }
        return self.symbols[e].longLongValue;
        }
    if (([e hasSuffix:@"h"] || [e hasSuffix:@"H"]) && e.length > 1)
        {
        unichar first = [e characterAtIndex:0];
        if (first >= '0' && first <= '9')
            {
            BOOL allHex = YES;
            for (NSUInteger i = 0; i < e.length - 1; i++)
                {
                unichar c = [e characterAtIndex:i];
                BOOL isHex =
                    (c >= '0' && c <= '9') ||
                    (c >= 'a' && c <= 'f') ||
                    (c >= 'A' && c <= 'F');
                if (!isHex)
                    {
                    allHex = NO;
                    break;
                    }
                }
            if (allHex)
                {
                return (int64_t)strtoull([e substringToIndex:e.length - 1].UTF8String, NULL, 16);
                }
            }
        }
    // Decimal literal: every character must be a digit. The old code
    // just checked the first char, which made `12h_skip` evaluate to
    // 12 decimal (strtoll stops at the `h`). Now a leading digit
    // followed by any non-digit character falls through to symbol
    // lookup instead.
    if ([e characterAtIndex:0] >= '0' && [e characterAtIndex:0] <= '9')
        {
        BOOL allDigits = YES;
        for (NSUInteger i = 0; i < e.length; i++)
            {
            unichar c = [e characterAtIndex:i];
            if (c < '0' || c > '9')
                {
                allDigits = NO;
                break;
                }
            }
        if (allDigits)
            {
            return (int64_t)strtoll(e.UTF8String, NULL, 10);
            }
        }

    // Symbol lookup
    NSNumber* sym = self.symbols[e];
    if (sym)
        return sym.longLongValue;

    // Try case-insensitive
    for (NSString* key in self.symbols)
        {
        if ([key caseInsensitiveCompare:e] == NSOrderedSame)
            return self.symbols[key].longLongValue;
        }

    // In pass 2 an undefined name is an error. It used to be a warning and
    // the value 0, so a call to a function that was declared and never
    // defined assembled to `JSR $0000` and the program jumped to zero page.
    if (self.evalLine)
        {
        self.evalUndefined = YES;
        if (![self.undefinedReported containsObject:e])
            {
            [self.undefinedReported addObject:e];
            NSString* raw = self.evalLine.rawText
                                ? [self.evalLine.rawText stringByTrimmingCharactersInSet:
                                                             [NSCharacterSet whitespaceCharacterSet]]
                                : e;
            [self.mutableErrors addObject:[NSString stringWithFormat:@"line %lu: undefined symbol '%@' in '%@'",
                                                                     (unsigned long)self.evalLine.sourceLine, e, raw]];
            }
        return 0;
        }
    [self.mutableWarnings addObject:[NSString stringWithFormat:@"undefined symbol '%@', using 0", e]];
    return 0;
    }

/****************************************************************************\
|* Try to evaluate; returns -1 if unresolvable (for pass-1 ZP detection).
\****************************************************************************/
- (int64_t)tryEvaluate:(NSString*)expr
    {
    if (!expr)
        return -1;
    NSString* e = [expr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([e hasPrefix:@"$"])
        return (int64_t)strtoull([e substringFromIndex:1].UTF8String, NULL, 16);
    if ([e hasPrefix:@"%"])
        return (int64_t)strtoull([e substringFromIndex:1].UTF8String, NULL, 2);
    // Same all-digits guard as evaluateExpression — a token like
    // `12h_skip` must fall through to symbol lookup, not be parsed
    // as 12 decimal.
    if (e.length > 0 && [e characterAtIndex:0] >= '0' && [e characterAtIndex:0] <= '9')
        {
        BOOL allDigits = YES;
        for (NSUInteger i = 0; i < e.length; i++)
            {
            unichar c = [e characterAtIndex:i];
            if (c < '0' || c > '9')
                {
                allDigits = NO;
                break;
                }
            }
        if (allDigits)
            {
            return (int64_t)strtoll(e.UTF8String, NULL, 10);
            }
        }
    NSNumber* sym = self.symbols[e];
    if (sym)
        return sym.longLongValue;
    return 0x100; // Unknown — assume not zero page
    }

#pragma mark - Helpers

/****************************************************************************\
|* Check whether a string is a valid assembler identifier (label name).
|* Accepts names starting with a letter, underscore, or dot; also local
|* labels starting with '>'.
|* @param str  The string to test.
|* @return  YES if the string is a valid identifier.
\****************************************************************************/
- (BOOL)isValidIdentifier:(NSString*)str
    {
    if (str.length == 0)
        return NO;
    unichar first = [str characterAtIndex:0];
    if (first == '>')
        return str.length > 1; // local label
    return isalpha(first) || first == '_' || first == '.';
    }

/****************************************************************************\
|* Parse a comma-separated list of data values from a .byte/.word directive.
|* @param str  The value list string (e.g. "$01, $02, $03").
|* @return  An array of trimmed value expression strings.
\****************************************************************************/
- (NSArray<NSString*>*)parseDataList:(NSString*)str
    {
    NSMutableArray<NSString*>* result = [NSMutableArray array];
    for (NSString* item in [str componentsSeparatedByString:@","])
        {
        NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0)
            [result addObject:trimmed];
        }
    return result;
    }

/****************************************************************************\
|* Split a source line on the compound instruction separator " : " into
|* individual instruction parts. Label colons have no surrounding spaces
|* and are preserved intact.
|* @param line  The raw source line.
|* @return  An array of one or more instruction strings.
\****************************************************************************/
- (NSArray<NSString*>*)splitCompoundLine:(NSString*)line
    {
    // Split on " : " (space-colon-space) which is the compound instruction separator
    // produced by the xtc codegen (e.g. "TXA : PHA"). Label colons (e.g. "_fn_main:")
    // do NOT have spaces around them, so they are preserved intact.
    if (![line containsString:@" : "])
        return @[ line ];

    NSArray<NSString*>* parts = [line componentsSeparatedByString:@" : "];
    NSMutableArray<NSString*>* result = [NSMutableArray array];
    for (NSString* p in parts)
        {
        NSString* t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length > 0)
            [result addObject:t];
        }
    return result.count > 0 ? result : @[ line ];
    }

@end
