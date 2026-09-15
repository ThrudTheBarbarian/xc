#import "XTLexer.h"
#import "XTFloatEncoding.h"

@interface XTLexer ()
@property (nonatomic) NSString *source;
@property (nonatomic) NSString *filename;
@property (nonatomic) XTDiagnosticEngine *diagnostics;
@property (nonatomic) NSUInteger pos;
@property (nonatomic) NSUInteger line;
@property (nonatomic) NSUInteger col;
@property (nonatomic) NSMutableArray<XTToken *> *tokens;
@end

static NSDictionary<NSString *, NSNumber *> *sKeywordMap = nil;

@implementation XTLexer

+ (void)initialize {
    if (self == [XTLexer class]) {
        sKeywordMap = @{
            @"if":       @(XTTokenIf),
            @"else":     @(XTTokenElse),
            @"while":    @(XTTokenWhile),
            @"for":      @(XTTokenFor),
            @"in":       @(XTTokenIn),
            @"return":   @(XTTokenReturn),
            @"break":    @(XTTokenBreak),
            @"continue": @(XTTokenContinue),
            @"goto":     @(XTTokenGoto),
            @"defer":    @(XTTokenDefer),
            @"throws":   @(XTTokenThrows),
            @"throw":    @(XTTokenThrow),
            @"try":      @(XTTokenTry),
            @"catch":    @(XTTokenCatch),
            @"struct":   @(XTTokenStruct),
            @"typedef":  @(XTTokenTypedef),
            @"enum":     @(XTTokenEnum),
            @"class":    @(XTTokenClass),
            @"protocol": @(XTTokenProtocol),
            @"optional": @(XTTokenOptional),
            @"final":    @(XTTokenFinal),
            @"new":      @(XTTokenNew),
            @"delete":   @(XTTokenDelete),
            @"retain":   @(XTTokenRetain),
            @"release":  @(XTTokenRelease),
            @"auto":     @(XTTokenAuto),
            @"volatile": @(XTTokenVolatile),
            @"static":   @(XTTokenStatic),
            @"extern":   @(XTTokenExtern),
            @"register": @(XTTokenRegister),
            @"global":   @(XTTokenGlobal),
            @"inline":   @(XTTokenInline),
            @"asm":      @(XTTokenAsm),
            @"sizeof":   @(XTTokenSizeof),
            @"use":      @(XTTokenUse),
            @"i8":       @(XTTokenI8),
            @"u8":       @(XTTokenU8),
            @"i16":      @(XTTokenI16),
            @"u16":      @(XTTokenU16),
            @"i32":      @(XTTokenI32),
            @"u32":      @(XTTokenU32),
            @"i64":      @(XTTokenI64),
            @"u64":      @(XTTokenU64),
            @"bool":     @(XTTokenBool),
            @"float":    @(XTTokenFloat),
            @"double":   @(XTTokenDouble),
            @"void":     @(XTTokenVoid),
            @"pointer":  @(XTTokenPointer),
            @"string":   @(XTTokenString),
            @"true":     @(XTTokenTrue),
            @"false":    @(XTTokenFalse),
            @"switch":   @(XTTokenSwitch),
            @"case":     @(XTTokenCase),
            @"default":  @(XTTokenDefault),
        };
    }
}

/****************************************************************************\
|* Designated initialiser for the lexer.
|* @param source       The full source text to tokenise.
|* @param filename     The filename used in source-location tracking.
|* @param diagnostics  The diagnostic engine for reporting errors.
|* @return A new lexer ready to tokenise.
\****************************************************************************/
- (instancetype)initWithSource:(NSString *)source
                      filename:(NSString *)filename
                    diagnostics:(XTDiagnosticEngine *)diagnostics {
    self = [super init];
    if (self) {
        _source = source;
        _filename = filename;
        _diagnostics = diagnostics;
        _pos = 0;
        _line = 1;
        _col = 1;
        _tokens = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Character Access

/****************************************************************************\
|* Return the character at the current position, or 0 if at end of source.
|* @return The current character.
\****************************************************************************/
- (unichar)currentChar {
    if (_pos >= _source.length) return 0;
    return [_source characterAtIndex:_pos];
}

/****************************************************************************\
|* Peek ahead by the given offset without advancing the position.
|* @param offset  Number of characters ahead to peek.
|* @return The character at pos+offset, or 0 if past end of source.
\****************************************************************************/
- (unichar)peekChar:(NSUInteger)offset {
    NSUInteger idx = _pos + offset;
    if (idx >= _source.length) return 0;
    return [_source characterAtIndex:idx];
}

/****************************************************************************\
|* Advance the position by one character, updating line and column tracking.
\****************************************************************************/
- (void)advance {
    if (_pos < _source.length) {
        unichar ch = [_source characterAtIndex:_pos];
        _pos++;
        if (ch == '\n') {
            _line++;
            _col = 1;
        } else {
            _col++;
        }
    }
}

/****************************************************************************\
|* Build a source location for the current position.
|* @return A new XTSourceLocation at the current file, line, and column.
\****************************************************************************/
- (XTSourceLocation *)currentLocation {
    return [XTSourceLocation locationWithFilename:_filename line:_line column:_col];
}

#pragma mark - Tokenise

/****************************************************************************\
|* Tokenise the entire source and return the token array (including a final
|* EOF token). Handles #line directives from the preprocessor.
|* @return An immutable array of tokens.
\****************************************************************************/
- (NSArray<XTToken *> *)tokenise {
    while (_pos < _source.length) {
        [self skipWhitespaceAndComments];
        if (_pos >= _source.length) break;
        // Handle #line directives from the preprocessor
        if ([self currentChar] == '#' && [self matchLineDirective]) continue;
        [self scanToken];
    }

    XTSourceLocation *eofLoc = [self currentLocation];
    [_tokens addObject:[XTToken tokenWithType:XTTokenEOF value:@"" location:eofLoc]];
    return [_tokens copy];
}

/****************************************************************************\
|* Check for and consume a #line N "filename" directive, updating the lexer's
|* source tracking state. Returns YES if a directive was consumed.
\****************************************************************************/
- (BOOL)matchLineDirective {
    // Must be at '#' with "line" following
    if (_pos + 5 >= _source.length) return NO;
    NSString *peek = [_source substringWithRange:NSMakeRange(_pos, MIN(6, _source.length - _pos))];
    if (![peek hasPrefix:@"#line "]) return NO;

    // Consume the entire line
    NSUInteger start = _pos;
    while (_pos < _source.length && [_source characterAtIndex:_pos] != '\n') {
        _pos++;
    }
    if (_pos < _source.length) _pos++; // consume the newline

    NSString *directive = [_source substringWithRange:NSMakeRange(start, _pos - start)];
    directive = [directive stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Parse: #line N "filename"
    NSString *rest = [[directive substringFromIndex:5]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // Extract line number
    NSMutableString *numStr = [NSMutableString string];
    NSUInteger idx = 0;
    while (idx < rest.length && [rest characterAtIndex:idx] >= '0' && [rest characterAtIndex:idx] <= '9') {
        [numStr appendFormat:@"%C", [rest characterAtIndex:idx]];
        idx++;
    }
    if (numStr.length > 0) {
        _line = (NSUInteger)[numStr integerValue];
    }

    // Extract filename (optional, in quotes)
    NSString *afterNum = [[rest substringFromIndex:idx]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([afterNum hasPrefix:@"\""] && [afterNum hasSuffix:@"\""]) {
        _filename = [afterNum substringWithRange:NSMakeRange(1, afterNum.length - 2)];
    }

    _col = 1;
    return YES;
}

/****************************************************************************\
|* Skip whitespace, line comments (//), and block comments.
\****************************************************************************/
- (void)skipWhitespaceAndComments {
    while (_pos < _source.length) {
        unichar ch = [self currentChar];
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
            [self advance];
        } else if (ch == '/' && [self peekChar:1] == '/') {
            // Line comment
            while (_pos < _source.length && [self currentChar] != '\n') {
                [self advance];
            }
        } else if (ch == '/' && [self peekChar:1] == '*') {
            // Block comment. Comments do NOT nest — the FIRST `*/` closes,
            // exactly as in C — and both ways of getting that wrong used to be
            // silent:
            //
            //   * a `/*` inside the comment reads as ordinary text, so the
            //     author's intended closer ends it early and the rest of their
            //     prose is parsed as CODE. The error then points at English
            //     ("Expected type in declaration") and reads as nonsense.
            //   * an unterminated comment ran to end-of-input and the file
            //     compiled, silently swallowing everything after it.
            //
            // Both are now diagnosed, at the position of the offending `/*`.
            XTSourceLocation *openLoc = [self currentLocation];
            [self advance]; [self advance]; // skip /*
            BOOL closed = NO, warnedNested = NO;
            while (_pos < _source.length) {
                if ([self currentChar] == '*' && [self peekChar:1] == '/') {
                    [self advance]; [self advance];
                    closed = YES;
                    break;
                }
                if (!warnedNested && [self currentChar] == '/' && [self peekChar:1] == '*') {
                    // Once per comment: a run of them is one mistake.
                    [_diagnostics emitWarning:@"'/*' within a block comment — comments "
                                              @"do not nest, so the first '*/' ends it"
                                     category:XTWarnComment
                                           at:[self currentLocation]];
                    warnedNested = YES;
                }
                [self advance];
            }
            if (!closed)
                [_diagnostics emitError:@"unterminated block comment — no closing '*/'"
                                     at:openLoc];
        } else {
            break;
        }
    }
}

/****************************************************************************\
|* Scan a single token from the current position and append it to the
|* token array. Dispatches to the appropriate literal/keyword/operator scanner.
\****************************************************************************/
- (void)scanToken {
    XTSourceLocation *loc = [self currentLocation];
    unichar ch = [self currentChar];

    // String literal
    if (ch == '"') {
        [self scanStringLiteral:loc];
        return;
    }

    // Character literal — only when the lookahead actually matches a
    // valid `'x'` or `'\x'` shape. Otherwise fall through and let
    // scanOperatorOrPunct emit a bare apostrophe token. The blanket
    // "consume on sight" used to choke on English apostrophes that
    // appeared inside inline-asm 6502 comments — e.g. `; Negative:
    // two's-complement negate the value` — because the lexer eagerly
    // started a char-literal scan, walked to the end of the line,
    // and bailed with "Expected closing ' in character literal".
    // Now the lexer requires either:
    //   ' <single non-backslash char> '            (e.g. 'a', '+', '0')
    //   ' \ <single char> '                        (e.g. '\n', '\0', '\\', '\'')
    // and anything else (a stray apostrophe in prose) becomes a
    // pass-through punctuation token, which the asm-block reconstructor
    // happily concatenates back into the line text.
    if (ch == '\'') {
        unichar p1 = [self peekChar:1];
        unichar p2 = [self peekChar:2];
        unichar p3 = [self peekChar:3];
        BOOL isEscape = (p1 == '\\' && p3 == '\'');
        // Hex escapes are longer: '\xNN' closes at 5, '\uNNNN' at 7.
        if (p1 == '\\' && p2 == 'x') isEscape = ([self peekChar:5] == '\'');
        if (p1 == '\\' && p2 == 'u') isEscape = ([self peekChar:7] == '\'');
        BOOL isSimple = (p1 != '\\' && p1 != '\0' && p2 == '\'');
        if (isEscape || isSimple) {
            [self scanCharLiteral:loc];
            return;
        }
        // Not a valid char literal — fall through to scanOperatorOrPunct.
    }

    // Numeric literal: decimal, hex ($ or 0x), binary (%)
    if (ch == '$') {
        [self scanHexLiteral:loc prefixLength:1 display:@"$"];
        return;
    }
    // `0x` / `0X` as an alias for `$`. Checked before the plain-digit path so
    // `0xFF` does not lex as the decimal 0 followed by an identifier. Nothing
    // else can start `0x`, so there is no ambiguity to resolve.
    if (ch == '0' && ([self peekChar:1] == 'x' || [self peekChar:1] == 'X')
        && isxdigit([self peekChar:2])) {
        [self scanHexLiteral:loc prefixLength:2 display:@"0x"];
        return;
    }
    if (ch == '%' && ([self peekChar:1] == '0' || [self peekChar:1] == '1')) {
        [self scanBinLiteral:loc];
        return;
    }
    if (isdigit(ch)) {
        [self scanNumericLiteral:loc];
        return;
    }

    // Identifier or keyword
    if (isalpha(ch) || ch == '_') {
        [self scanIdentifierOrKeyword:loc];
        return;
    }

    // Operators and punctuation
    [self scanOperatorOrPunct:loc];
}

#pragma mark - String Literal

/****************************************************************************\
|* Read exactly `n` hex digits at the cursor for a \x / \u / \U escape.
|* Returns the value, or -1 (with a diagnostic) on a short / non-hex run.
\****************************************************************************/
- (int64_t)readHexEscapeDigits:(NSUInteger)n kind:(char)kind at:(XTSourceLocation *)loc {
    int64_t v = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [self currentChar];
        int d = -1;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = 10 + (c - 'a');
        else if (c >= 'A' && c <= 'F') d = 10 + (c - 'A');
        if (d < 0) {
            [_diagnostics emitError:[NSString stringWithFormat:
                @"\\%c escape wants exactly %lu hex digits", kind, (unsigned long)n] at:loc];
            return -1;
        }
        v = (v << 4) | d;
        [self advance];
    }
    return v;
}

/****************************************************************************\
|* Append code point `cp` to `buf`, validating range. \x is capped at 7F:
|* above that a C programmer means a RAW byte, and a raw byte above 7F in a
|* UTF-8 string is either half a character (write the character with \u) or
|* deliberate binary (build it with appendByte) — both better said than
|* silently re-encoded.
\****************************************************************************/
- (void)appendEscapeCodePoint:(int64_t)cp kind:(char)kind to:(NSMutableString *)buf
                           at:(XTSourceLocation *)loc {
    if (cp < 0) return;                               // diagnostic already out
    if (kind == 'x' && cp > 0x7F) {
        [_diagnostics emitError:@"\\x above 7F would be a bare byte inside a "
            @"UTF-8 string — write the character with \\u00NN, or build raw "
            @"bytes with appendByte" at:loc];
        return;
    }
    if ((cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF) {
        [_diagnostics emitError:[NSString stringWithFormat:
            @"\\%c names U+%04llX, which is not a Unicode scalar value",
            kind, (long long)cp] at:loc];
        return;
    }
    if (cp <= 0xFFFF) {
        [buf appendFormat:@"%C", (unichar)cp];
    } else {
        int64_t v = cp - 0x10000;
        [buf appendFormat:@"%C%C", (unichar)(0xD800 + (v >> 10)),
                                   (unichar)(0xDC00 + (v & 0x3FF))];
    }
}

/****************************************************************************\
|* Scan a double-quoted string literal, resolving escape sequences.
|* @param loc  Source location of the opening quote.
\****************************************************************************/
- (void)scanStringLiteral:(XTSourceLocation *)loc {
    [self advance]; // skip opening "
    NSMutableString *buf = [NSMutableString string];
    while (_pos < _source.length) {
        unichar ch = [self currentChar];
        if (ch == '"') {
            [self advance];
            break;
        }
        if (ch == '\n') {
            [_diagnostics emitError:@"Unterminated string literal" at:loc];
            break;
        }
        if (ch == '\\') {
            [self advance];
            unichar esc = [self currentChar];
            [self advance];
            switch (esc) {
                case 'n':  [buf appendString:@"\n"]; break;
                case 't':  [buf appendString:@"\t"]; break;
                case 'r':  [buf appendString:@"\r"]; break;
                case '0':  [buf appendFormat:@"%C", (unichar)0]; break;
                case '\\': [buf appendString:@"\\"]; break;
                case '"':  [buf appendString:@"\""]; break;
                case '\'': [buf appendString:@"'"]; break;
                // Hex escapes (0.4): \xNN is an ASCII byte (00..7F — above
                // that is an error, see appendEscapeCodePoint:), \uNNNN and
                // \UNNNNNNNN are Unicode code points, encoded as UTF-8 when
                // the literal's bytes are materialised.
                case 'x':
                    [self appendEscapeCodePoint:[self readHexEscapeDigits:2 kind:'x' at:loc]
                                           kind:'x' to:buf at:loc];
                    break;
                case 'u':
                    [self appendEscapeCodePoint:[self readHexEscapeDigits:4 kind:'u' at:loc]
                                           kind:'u' to:buf at:loc];
                    break;
                case 'U':
                    [self appendEscapeCodePoint:[self readHexEscapeDigits:8 kind:'U' at:loc]
                                           kind:'U' to:buf at:loc];
                    break;
                default:
                    [buf appendFormat:@"\\%C", esc];
                    break;
            }
        } else {
            [buf appendFormat:@"%C", ch];
            [self advance];
        }
    }
    [_tokens addObject:[XTToken tokenWithType:XTTokenStringLiteral value:buf location:loc]];
}

#pragma mark - Char Literal

/****************************************************************************\
|* Scan a single-quoted character literal ('x' or '\x').
|* @param loc  Source location of the opening quote.
\****************************************************************************/
- (void)scanCharLiteral:(XTSourceLocation *)loc {
    [self advance]; // skip '
    uint8_t value = 0;
    unichar ch = [self currentChar];
    if (ch == '\\') {
        [self advance];
        unichar esc = [self currentChar];
        [self advance];
        switch (esc) {
            case 'n':  value = '\n'; break;
            case 't':  value = '\t'; break;
            case 'r':  value = '\r'; break;
            case '0':  value = 0;    break;
            case '\\': value = '\\'; break;
            case '\'': value = '\''; break;
            // Hex escapes (0.4). A char literal IS a u8, so \x keeps its
            // ASCII cap and \u must fit a byte — '\u00E9' is the Latin-1
            // byte E9, not a UTF-8 sequence.
            case 'x': {
                int64_t v = [self readHexEscapeDigits:2 kind:'x' at:loc];
                if (v > 0x7F) {
                    [_diagnostics emitError:@"\\x above 7F would be a bare "
                        @"byte inside a UTF-8 string — write the character "
                        @"with \\u00NN, or build raw bytes with appendByte" at:loc];
                    v = 0;
                }
                if (v >= 0) value = (uint8_t)v;
                break;
            }
            case 'u': {
                int64_t v = [self readHexEscapeDigits:4 kind:'u' at:loc];
                if (v > 0xFF) {
                    [_diagnostics emitError:@"\\u in a char literal must fit "
                        @"a u8 (00..FF)" at:loc];
                    v = 0;
                }
                if (v >= 0) value = (uint8_t)v;
                break;
            }
            default:   value = (uint8_t)esc; break;
        }
    } else {
        value = (uint8_t)ch;
        [self advance];
    }
    if ([self currentChar] != '\'') {
        [_diagnostics emitError:@"Expected closing ' in character literal" at:loc];
    } else {
        [self advance];
    }
    NSString *strVal = [NSString stringWithFormat:@"%d", value];
    XTToken *tok = [[XTToken alloc] initWithType:XTTokenCharLiteral
                                           value:strVal
                                        intValue:(int64_t)value
                                        location:loc];
    [_tokens addObject:tok];
}

#pragma mark - Numeric Literals

/****************************************************************************\
|* Scan a hex literal ($XX...) and emit an integer token.
|* @param loc  Source location of the '$' prefix.
\****************************************************************************/
- (void)scanHexLiteral:(XTSourceLocation *)loc
          prefixLength:(NSUInteger)prefixLength
               display:(NSString *)displayPrefix {
    for (NSUInteger i = 0; i < prefixLength; i++) [self advance];  // skip $ / 0x
    NSMutableString *raw = [NSMutableString string];
    while (_pos < _source.length) {
        unichar ch = [self currentChar];
        if (ch == '_') { [self advance]; continue; }
        if (isxdigit(ch)) { [raw appendFormat:@"%C", ch]; [self advance]; }
        else break;
    }
    if (raw.length == 0) {
        [_diagnostics emitError:[NSString stringWithFormat:@"Expected hex digits after %@",
                                                           displayPrefix] at:loc];
        return;
    }
    int64_t val = (int64_t)strtoull(raw.UTF8String, NULL, 16);
    // The token keeps the spelling as WRITTEN, so a `--dump-tokens` of `0xFF`
    // says `0xFF` rather than silently reporting `$FF`.
    NSString *disp = [NSString stringWithFormat:@"%@%@", displayPrefix, raw];
    XTToken *tok = [[XTToken alloc] initWithType:XTTokenIntLiteral value:disp intValue:val location:loc];
    [_tokens addObject:tok];
}

/****************************************************************************\
|* Scan a binary literal (%01...) and emit an integer token.
|* @param loc  Source location of the '%' prefix.
\****************************************************************************/
- (void)scanBinLiteral:(XTSourceLocation *)loc {
    [self advance]; // skip %
    NSMutableString *raw = [NSMutableString string];
    while (_pos < _source.length) {
        unichar ch = [self currentChar];
        if (ch == '_') { [self advance]; continue; }
        if (ch == '0' || ch == '1') { [raw appendFormat:@"%C", ch]; [self advance]; }
        else break;
    }
    if (raw.length == 0) {
        [_diagnostics emitError:@"Expected binary digits after %" at:loc];
        return;
    }
    int64_t val = (int64_t)strtoull(raw.UTF8String, NULL, 2);
    NSString *disp = [NSString stringWithFormat:@"%%%@", raw];
    XTToken *tok = [[XTToken alloc] initWithType:XTTokenIntLiteral value:disp intValue:val location:loc];
    [_tokens addObject:tok];
}

/****************************************************************************\
|* Scan a decimal integer or float literal. A float literal is converted at
|* lex time and carried as IEEE-754 bytes — 4 for a single, or 8 when a
|* trailing `d` / `D` suffix makes it a double.
|* @param loc  Source location of the first digit.
\****************************************************************************/
- (void)scanNumericLiteral:(XTSourceLocation *)loc {
    NSMutableString *raw = [NSMutableString string];
    BOOL isFloat = NO;

    while (_pos < _source.length) {
        unichar ch = [self currentChar];
        if (ch == '_') { [self advance]; continue; }
        if (isdigit(ch)) { [raw appendFormat:@"%C", ch]; [self advance]; }
        else if (ch == '.' && !isFloat && isdigit([self peekChar:1])) {
            isFloat = YES;
            [raw appendFormat:@"%C", ch];
            [self advance];
        } else if ((ch == 'e' || ch == 'E') && isFloat) {
            [raw appendFormat:@"%C", ch]; [self advance];
            if ([self currentChar] == '+' || [self currentChar] == '-') {
                [raw appendFormat:@"%C", [self currentChar]]; [self advance];
            }
        } else {
            break;
        }
    }

    BOOL isDouble = NO;
    if ([self currentChar] == 'd' || [self currentChar] == 'D') {
        // `d`/`D` suffix upgrades to the 8-byte double format. Implies float
        // even without a decimal point (e.g. `1d`).
        isDouble = YES;
        isFloat = YES;
        [self advance];
    }

    if (isFloat) {
        double dVal = [raw doubleValue];
        // IEEE bytes, not xtc's 5/8-byte softfloat encoding. Every backend
        // emits IEEE now, so the old format was a lossy detour between two
        // IEEE endpoints: it rounds to a 48-bit mantissa for a `d` literal,
        // and the lowering decoded it straight back to a double.
        NSData *floatData = [XTFloatEncoding ieeeDataForDouble:dVal
                                                         width:(isDouble ? 8 : 4)];
        XTToken *tok = [[XTToken alloc] initWithType:XTTokenFloatLiteral
                                               value:raw
                                           floatData:floatData
                                            location:loc];
        [_tokens addObject:tok];
    } else {
        int64_t val = (int64_t)strtoull(raw.UTF8String, NULL, 10);
        XTToken *tok = [[XTToken alloc] initWithType:XTTokenIntLiteral
                                               value:raw
                                            intValue:val
                                            location:loc];
        [_tokens addObject:tok];
    }
}

#pragma mark - Identifier / Keyword

/****************************************************************************\
|* Scan an identifier or keyword. Looks up the word in the keyword map to
|* decide whether to emit a keyword token or an identifier token.
|* @param loc  Source location of the first character.
\****************************************************************************/
- (void)scanIdentifierOrKeyword:(XTSourceLocation *)loc {
    NSMutableString *buf = [NSMutableString string];
    while (_pos < _source.length) {
        unichar ch = [self currentChar];
        if (isalnum(ch) || ch == '_') {
            [buf appendFormat:@"%C", ch];
            [self advance];
        } else {
            break;
        }
    }

    NSNumber *kwType = sKeywordMap[buf];
    if (kwType) {
        XTToken *tok = [XTToken tokenWithType:(XTTokenType)kwType.integerValue
                                        value:buf
                                     location:loc];
        [_tokens addObject:tok];
    } else {
        XTToken *tok = [XTToken tokenWithType:XTTokenIdentifier value:buf location:loc];
        [_tokens addObject:tok];
    }
}

#pragma mark - Operators and Punctuation

/****************************************************************************\
|* Scan an operator or punctuation character (including multi-character
|* operators like <<, >>=, etc.) and emit the appropriate token.
|* @param loc  Source location of the first character.
\****************************************************************************/
- (void)scanOperatorOrPunct:(XTSourceLocation *)loc {
    unichar ch = [self currentChar];
    unichar ch2 = [self peekChar:1];
    unichar ch3 = [self peekChar:2];
    unichar ch4 = [self peekChar:3];

#define EMIT(t, str) do { [self advance]; [_tokens addObject:[XTToken tokenWithType:(t) value:(str) location:loc]]; return; } while(0)
#define EMIT2(t, str) do { [self advance]; [self advance]; [_tokens addObject:[XTToken tokenWithType:(t) value:(str) location:loc]]; return; } while(0)
#define EMIT3(t, str) do { [self advance]; [self advance]; [self advance]; [_tokens addObject:[XTToken tokenWithType:(t) value:(str) location:loc]]; return; } while(0)
#define EMIT4(t, str) do { [self advance]; [self advance]; [self advance]; [self advance]; [_tokens addObject:[XTToken tokenWithType:(t) value:(str) location:loc]]; return; } while(0)

    switch (ch) {
        case '(':
            EMIT(XTTokenLParen, @"(");
        case ')':
            EMIT(XTTokenRParen, @")");
        case '{': EMIT(XTTokenLBrace, @"{");
        case '}': EMIT(XTTokenRBrace, @"}");
        case '[': EMIT(XTTokenLBracket, @"[");
        case ']': EMIT(XTTokenRBracket, @"]");
        case ';': EMIT(XTTokenSemicolon, @";");
        case ',': EMIT(XTTokenComma, @",");
        case '?': EMIT(XTTokenQuestion, @"?");
        case '~': EMIT(XTTokenTilde, @"~");
        case '@': EMIT(XTTokenAt, @"@");

        case ':':
            if (ch2 == '>') {
                if (ch3 == '=') EMIT3(XTTokenRorAssign, @":>=");
                EMIT2(XTTokenRotateRight, @":>");
            }
            EMIT(XTTokenColon, @":");

        case '+':
            if (ch2 == '+') EMIT2(XTTokenPlusPlus, @"++");
            if (ch2 == '=') EMIT2(XTTokenPlusAssign, @"+=");
            EMIT(XTTokenPlus, @"+");

        case '-':
            if (ch2 == '-') EMIT2(XTTokenMinusMinus, @"--");
            if (ch2 == '>') EMIT2(XTTokenArrow, @"->");
            if (ch2 == '=') EMIT2(XTTokenMinusAssign, @"-=");
            EMIT(XTTokenMinus, @"-");

        case '*':
            if (ch2 == '=') EMIT2(XTTokenStarAssign, @"*=");
            EMIT(XTTokenStar, @"*");

        case '/':
            if (ch2 == '=') EMIT2(XTTokenSlashAssign, @"/=");
            EMIT(XTTokenSlash, @"/");

        case '%':
            if (ch2 == '=') EMIT2(XTTokenPercentAssign, @"%=");
            EMIT(XTTokenPercent, @"%");

        case '&':
            if (ch2 == '&') EMIT2(XTTokenLogicalAnd, @"&&");
            if (ch2 == '=') EMIT2(XTTokenAmpAssign, @"&=");
            EMIT(XTTokenAmpersand, @"&");

        case '|':
            if (ch2 == '|') EMIT2(XTTokenLogicalOr, @"||");
            if (ch2 == '=') EMIT2(XTTokenPipeAssign, @"|=");
            EMIT(XTTokenPipe, @"|");

        case '^':
            if (ch2 == '=') EMIT2(XTTokenCaretAssign, @"^=");
            EMIT(XTTokenCaret, @"^");

        case '!':
            if (ch2 == '=') EMIT2(XTTokenNotEqual, @"!=");
            EMIT(XTTokenBang, @"!");

        case '=':
            if (ch2 == '=') EMIT2(XTTokenEqual, @"==");
            EMIT(XTTokenAssign, @"=");

        case '<':
            if (ch2 == '<') {
                if (ch3 == '=') EMIT3(XTTokenShlAssign, @"<<=");
                EMIT2(XTTokenShiftLeft, @"<<");
            }
            if (ch2 == ':') {
                if (ch3 == '=') EMIT3(XTTokenRolAssign, @"<:=");
                EMIT2(XTTokenRotateLeft, @"<:");
            }
            if (ch2 == '=') EMIT2(XTTokenLessEq, @"<=");
            EMIT(XTTokenLess, @"<");

        case '>':
            if (ch2 == '>' && ch3 == '>' && ch4 == '>') {
                // Note: >>> is 3 chars; this is never 4.
                // Check for >>>
            }
            if (ch2 == '>' && ch3 == '>') EMIT3(XTTokenByte3, @">>>");
            if (ch2 == '>') {
                if (ch3 == '=') EMIT3(XTTokenShrAssign, @">>=");
                EMIT2(XTTokenShiftRight, @">>");
            }
            if (ch2 == '=') EMIT2(XTTokenGreaterEq, @">=");
            EMIT(XTTokenGreater, @">");

        case '.':
            if (ch2 == '.' && ch3 == '.') EMIT3(XTTokenEllipsis, @"...");
            if (ch2 == '.') EMIT2(XTTokenDotDot, @"..");
            EMIT(XTTokenDot, @".");

        case '#':
            // 6502 immediate-mode prefix — emit as identifier-like token
            EMIT(XTTokenIdentifier, @"#");

        case '\'':
            // Apostrophe that wasn't consumed by the char-literal
            // path at the top of scanToken — emit as a pass-through
            // identifier token so it survives asm-block reconstruction
            // (where it's typically inside an English-language `;`
            // comment) without raising "Unexpected character".
            EMIT(XTTokenIdentifier, @"'");

        default: {
            NSString *msg = [NSString stringWithFormat:@"Unexpected character '%C'", ch];
            [_diagnostics emitError:msg at:loc];
            [self advance];
            break;
        }
    }

#undef EMIT
#undef EMIT2
#undef EMIT3
#undef EMIT4
}

@end
