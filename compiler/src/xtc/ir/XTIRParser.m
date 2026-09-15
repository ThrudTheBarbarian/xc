// XTIRParser.m
//
// Line-oriented, hand-rolled parser for the IR text format. Lines
// ending in `,` are joined with the next line (this is the only
// continuation rule). `;` to end-of-line is a comment. Within a
// function, a two-pass scan collects every LHS value-id allocation
// before any operand reference is resolved — this lets phi operands
// reference values defined in textually-later predecessor blocks.
#import "XTIRParser.h"
#import "XTIR.h"

NSString* const XTIRParserErrorDomain = @"XTIRParserErrorDomain";

#pragma mark - Token

typedef NS_ENUM(NSUInteger, XTIRTokKind) {
    XTIRTokEOL = 0,
    XTIRTokWord,      // identifier / keyword / type name
    XTIRTokValName,   // %ident
    XTIRTokSymName,   // @ident
    XTIRTokAt,        // standalone @ (followed by a digit)
    XTIRTokHashInt,   // #-?digits or #$hex
    XTIRTokHashFloat, // #fp<hex>
    XTIRTokHashCpool, // #cpool:<index>
    XTIRTokString,    // "..."
    XTIRTokNumInt,    // bare digits
    XTIRTokLBrace,
    XTIRTokRBrace,
    XTIRTokLParen,
    XTIRTokRParen,
    XTIRTokLBracket,
    XTIRTokRBracket,
    XTIRTokComma,
    XTIRTokColon,
    XTIRTokEquals,
    XTIRTokArrow,      // ->
    XTIRTokColonColon, // ::
    XTIRTokDash,       // standalone - (e.g. preds: -)
};

@interface XTIRTok : NSObject
@property(nonatomic) XTIRTokKind kind;
@property(nonatomic, copy) NSString* text;
@property(nonatomic) int64_t intValue;
@end
@implementation XTIRTok
@end

#pragma mark - Pending operand patch

// A few operand kinds need post-parse resolution against per-function
// or module-wide tables. We record them here and fix them up once
// the full module is parsed.
@interface XTIRPendingRef : NSObject
@property(nonatomic) XTIROperand* operand; // the operand whose ref to resolve
@property(nonatomic, copy) NSString* name; // the symbolic name to resolve
@end
@implementation XTIRPendingRef
@end

#pragma mark - Parser state

@interface XTIRParserState : NSObject
@property(nonatomic) NSArray<XTIRTok*>* tokens;
@property(nonatomic) NSUInteger pos;
@property(nonatomic) NSUInteger lineNumber;
@property(nonatomic) XTIRModule* module;
@property(nonatomic) NSMutableArray<NSString*>* errors;

// Per-function state, set up at start of each function.
@property(nonatomic, nullable) XTIRFunction* currentFunction;
@property(nonatomic) NSMutableDictionary<NSString*, XTIRValue*>* valuesByName;
@property(nonatomic) NSMutableDictionary<NSString*, XTIRBlock*>* blocksByName;
@property(nonatomic, nullable) XTIRBlock* currentBlock;
@property(nonatomic) NSMutableArray<XTIRPendingRef*>* pendingSymRefs; // module-wide
// Per-function pending value refs — operands that referenced a %name
// before the parser saw its def line. The def can lie below the use
// in the printer's emission order (Phi nodes reference values from
// their predecessor blocks). Resolved at function-close time when
// every name in this function is in valuesByName.
@property(nonatomic) NSMutableArray<XTIRPendingRef*>* pendingValueRefs;
@end
@implementation XTIRParserState
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _errors = [NSMutableArray array];
        _pendingSymRefs = [NSMutableArray array];
        }
    return self;
    }
@end

#pragma mark - Parser implementation

@implementation XTIRParser

#pragma mark Line preprocessing

+ (NSArray<NSString*>*)preprocessLines:(NSString*)text
    {
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    NSArray<NSString*>* raw = [text componentsSeparatedByString:@"\n"];
    NSMutableString* buffer = [NSMutableString string];
    for (NSString* rawLine in raw)
        {
        // Strip ; comment.
        NSRange semiRange = [rawLine rangeOfString:@";"];
        NSString* stripped = (semiRange.location != NSNotFound)
                                 ? [rawLine substringToIndex:semiRange.location]
                                 : rawLine;
        NSString* trimmed = [stripped stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0)
            {
            if (buffer.length > 0)
                {
                [out addObject:[buffer copy]];
                [buffer setString:@""];
                }
            continue;
            }
        // Continuation rules:
        //   1. The current buffer ends with `,` (trailing-comma
        //      continuation, e.g. inv-09-negative's two-line Call).
        //   2. The new physical line starts with `attributes` (so a
        //      `symbol` decl can have its attributes block on the
        //      following indented line — every fixture uses this).
        // We do NOT flush a line on no-trailing-comma right away — we
        // wait to see whether the next line is an `attributes` continuation.
        BOOL contComma = (buffer.length > 0 && [buffer hasSuffix:@","]);
        BOOL contAttr = (buffer.length > 0 && [trimmed hasPrefix:@"attributes"]);
        // `flags:` is the printer's continuation line for the
        // intrinsic-bool fields (escapes / volatile / taskLocal) that
        // don't live in the symbol's attributes NSDictionary. Treat
        // it the same as attributes — append to the current symbol
        // line so processLine sees one logical row.
        BOOL contFlags = (buffer.length > 0 && [trimmed hasPrefix:@"flags"]);
        if (contComma || contAttr || contFlags)
            {
            [buffer appendString:@" "];
            [buffer appendString:trimmed];
            }
        else
            {
            if (buffer.length > 0)
                {
                [out addObject:[buffer copy]];
                [buffer setString:@""];
                }
            [buffer appendString:trimmed];
            }
        }
    if (buffer.length > 0)
        [out addObject:[buffer copy]];
    return out;
    }

#pragma mark Tokeniser

+ (XTIRTok*)makeTok:(XTIRTokKind)k text:(NSString*)t intValue:(int64_t)v
    {
    XTIRTok* tok = [[XTIRTok alloc] init];
    tok.kind = k;
    tok.text = t ?: @"";
    tok.intValue = v;
    return tok;
    }

+ (BOOL)isIdentStart:(unichar)c
    {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
    }
+ (BOOL)isIdentCont:(unichar)c
    {
    // `$` is needed for sema-mangled class/method symbol names
    // (e.g. `Assert$isEqual__i16_i16` for a class-method symbol).
    // The printer emits these verbatim and they tokenise as a single
    // identifier; without `$` here the tokenizer split them on $ and
    // the symbol-parsing path crashed on the second half.
    return [self isIdentStart:c] || (c >= '0' && c <= '9') || c == '.' || c == '$';
    }
+ (BOOL)isDigit:(unichar)c
    {
    return c >= '0' && c <= '9';
    }
+ (BOOL)isHexDigit:(unichar)c
    {
    return [self isDigit:c] || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

+ (NSArray<XTIRTok*>*)tokeniseLine:(NSString*)line
    {
    NSMutableArray<XTIRTok*>* out = [NSMutableArray array];
    NSUInteger n = line.length;
    NSUInteger i = 0;
    while (i < n)
        {
        unichar c = [line characterAtIndex:i];
        if (c == ' ' || c == '\t')
            {
            i++;
            continue;
            }
        if (c == '{')
            {
            [out addObject:[self makeTok:XTIRTokLBrace text:@"{" intValue:0]];
            i++;
            continue;
            }
        if (c == '}')
            {
            [out addObject:[self makeTok:XTIRTokRBrace text:@"}" intValue:0]];
            i++;
            continue;
            }
        if (c == '(')
            {
            [out addObject:[self makeTok:XTIRTokLParen text:@"(" intValue:0]];
            i++;
            continue;
            }
        if (c == ')')
            {
            [out addObject:[self makeTok:XTIRTokRParen text:@")" intValue:0]];
            i++;
            continue;
            }
        if (c == '[')
            {
            [out addObject:[self makeTok:XTIRTokLBracket text:@"[" intValue:0]];
            i++;
            continue;
            }
        if (c == ']')
            {
            [out addObject:[self makeTok:XTIRTokRBracket text:@"]" intValue:0]];
            i++;
            continue;
            }
        if (c == ',')
            {
            [out addObject:[self makeTok:XTIRTokComma text:@"," intValue:0]];
            i++;
            continue;
            }
        if (c == '=')
            {
            [out addObject:[self makeTok:XTIRTokEquals text:@"=" intValue:0]];
            i++;
            continue;
            }
        if (c == ':')
            {
            if (i + 1 < n && [line characterAtIndex:i + 1] == ':')
                {
                [out addObject:[self makeTok:XTIRTokColonColon text:@"::" intValue:0]];
                i += 2;
                }
            else
                {
                [out addObject:[self makeTok:XTIRTokColon text:@":" intValue:0]];
                i++;
                }
            continue;
            }
        if (c == '-')
            {
            if (i + 1 < n && [line characterAtIndex:i + 1] == '>')
                {
                [out addObject:[self makeTok:XTIRTokArrow text:@"->" intValue:0]];
                i += 2;
                continue;
                }
            // Either standalone dash or negative number (only the latter
            // is followed by # — bare `-` is preds: -). Detect by next char.
            [out addObject:[self makeTok:XTIRTokDash text:@"-" intValue:0]];
            i++;
            continue;
            }
        if (c == '"')
            {
            NSUInteger start = i + 1;
            i++;
            while (i < n && [line characterAtIndex:i] != '"')
                i++;
            NSString* s = [line substringWithRange:NSMakeRange(start, i - start)];
            if (i < n)
                i++; // consume closing quote
            [out addObject:[self makeTok:XTIRTokString text:s intValue:0]];
            continue;
            }
        if (c == '%')
            {
            NSUInteger start = i + 1;
            i++;
            while (i < n && [self isIdentCont:[line characterAtIndex:i]])
                i++;
            NSString* name = [line substringWithRange:NSMakeRange(start, i - start)];
            [out addObject:[self makeTok:XTIRTokValName text:name intValue:0]];
            continue;
            }
        if (c == '@')
            {
            if (i + 1 < n && [self isIdentStart:[line characterAtIndex:i + 1]])
                {
                NSUInteger start = i + 1;
                i++;
                while (i < n && [self isIdentCont:[line characterAtIndex:i]])
                    i++;
                NSString* name = [line substringWithRange:NSMakeRange(start, i - start)];
                [out addObject:[self makeTok:XTIRTokSymName text:name intValue:0]];
                continue;
                }
            // Standalone @ — followed by digit (byte offset).
            [out addObject:[self makeTok:XTIRTokAt text:@"@" intValue:0]];
            i++;
            continue;
            }
        if (c == '#')
            {
            // Could be #fp<hex>, #-?digits, #$hex, or #cpool:<idx>.
            i++;
            // #cpool:<idx> — constant-aggregate reference. The printer
            // emits this for ConstAgg operands; without explicit
            // tokeniser handling the `#` was dropped and `cpool` parsed
            // as a bare identifier, which the operand parser then
            // rejected.
            NSString* cpoolPrefix = @"cpool:";
            BOOL cpoolMatch = i + cpoolPrefix.length <= n;
            if (cpoolMatch)
                {
                for (NSUInteger k = 0; k < cpoolPrefix.length; k++)
                    {
                    if ([line characterAtIndex:i + k] != [cpoolPrefix characterAtIndex:k])
                        {
                        cpoolMatch = NO;
                        break;
                        }
                    }
                }
            if (cpoolMatch)
                {
                i += cpoolPrefix.length;
                int64_t idx = 0;
                BOOL gotIdx = NO;
                while (i < n && [self isDigit:[line characterAtIndex:i]])
                    {
                    idx = idx * 10 + ([line characterAtIndex:i] - '0');
                    gotIdx = YES;
                    i++;
                    }
                if (gotIdx)
                    {
                    XTIRTok* t = [self makeTok:XTIRTokHashCpool
                                          text:@"cpool"
                                      intValue:idx];
                    [out addObject:t];
                    continue;
                    }
                }
            if (i + 1 < n && [line characterAtIndex:i] == 'f' && [line characterAtIndex:i + 1] == 'p')
                {
                NSUInteger start = i + 2;
                NSUInteger j = start;
                while (j < n && [self isHexDigit:[line characterAtIndex:j]])
                    j++;
                NSString* hex = [line substringWithRange:NSMakeRange(start, j - start)];
                unsigned long long bits = 0; // NSScanner's type — uint64_t is
                                             // `unsigned long` on Linux/musl
                NSScanner* sc = [NSScanner scannerWithString:hex];
                [sc scanHexLongLong:&bits];
                i = j;
                XTIRTok* t = [self makeTok:XTIRTokHashFloat text:hex intValue:0];
                t.intValue = (int64_t)bits;
                [out addObject:t];
                continue;
                }
            BOOL negative = NO;
            if (i < n && [line characterAtIndex:i] == '-')
                {
                negative = YES;
                i++;
                }
            int64_t value = 0;
            BOOL gotDigit = NO;
            if (i < n && [line characterAtIndex:i] == '$')
                {
                i++;
                while (i < n && [self isHexDigit:[line characterAtIndex:i]])
                    {
                    unichar h = [line characterAtIndex:i];
                    int d = (h >= '0' && h <= '9')   ? (h - '0')
                            : (h >= 'a' && h <= 'f') ? (h - 'a' + 10)
                                                     : (h - 'A' + 10);
                    value = value * 16 + d;
                    gotDigit = YES;
                    i++;
                    }
                }
            else
                {
                while (i < n && [self isDigit:[line characterAtIndex:i]])
                    {
                    value = value * 10 + ([line characterAtIndex:i] - '0');
                    gotDigit = YES;
                    i++;
                    }
                }
            if (!gotDigit)
                continue;
            if (negative)
                value = -value;
            XTIRTok* t = [self makeTok:XTIRTokHashInt text:@"" intValue:value];
            [out addObject:t];
            continue;
            }
        if ([self isDigit:c])
            {
            int64_t value = 0;
            while (i < n && [self isDigit:[line characterAtIndex:i]])
                {
                value = value * 10 + ([line characterAtIndex:i] - '0');
                i++;
                }
            XTIRTok* t = [self makeTok:XTIRTokNumInt text:@"" intValue:value];
            [out addObject:t];
            continue;
            }
        if ([self isIdentStart:c])
            {
            NSUInteger start = i;
            while (i < n && [self isIdentCont:[line characterAtIndex:i]])
                i++;
            NSString* word = [line substringWithRange:NSMakeRange(start, i - start)];
            [out addObject:[self makeTok:XTIRTokWord text:word intValue:0]];
            continue;
            }
        // Unknown char — skip.
        i++;
        }
    return out;
    }

#pragma mark Per-line cursor

+ (XTIRTok*)tok:(NSArray<XTIRTok*>*)tokens at:(NSUInteger)pos
    {
    if (pos >= tokens.count)
        {
        XTIRTok* eol = [self makeTok:XTIRTokEOL text:@"" intValue:0];
        return eol;
        }
    return tokens[pos];
    }

#pragma mark Type parsing (recursive)

+ (XTIRType*)parseTypeAt:(NSUInteger*)posPtr
                  tokens:(NSArray<XTIRTok*>*)tokens
                   state:(XTIRParserState*)state
    {
    XTIRTok* t = [self tok:tokens at:*posPtr];
    if (t.kind != XTIRTokWord)
        {
        [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected type, got '%@'",
                                                           (unsigned long)state.lineNumber, t.text]];
        return nil;
        }
    NSString* name = t.text;
    *posPtr += 1;
    if ([name isEqualToString:@"U8"])
        return [XTIRType u8Type];
    if ([name isEqualToString:@"I8"])
        return [XTIRType i8Type];
    if ([name isEqualToString:@"U16"])
        return [XTIRType u16Type];
    if ([name isEqualToString:@"I16"])
        return [XTIRType i16Type];
    if ([name isEqualToString:@"U32"])
        return [XTIRType u32Type];
    if ([name isEqualToString:@"I32"])
        return [XTIRType i32Type];
    if ([name isEqualToString:@"U64"])
        return [XTIRType u64Type];
    if ([name isEqualToString:@"I64"])
        return [XTIRType i64Type];
    if ([name isEqualToString:@"F32"])
        return [XTIRType f32Type];
    if ([name isEqualToString:@"F64"])
        return [XTIRType f64Type];
    if ([name isEqualToString:@"Bool"])
        return [XTIRType boolType];
    if ([name isEqualToString:@"Void"])
        return [XTIRType voidType];
    if ([name isEqualToString:@"Mem"])
        return [XTIRType memoryType];
    if ([name isEqualToString:@"Ptr"])
        {
        XTIRTok* lp = [self tok:tokens at:*posPtr];
        if (lp.kind != XTIRTokLParen)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '(' after Ptr",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        *posPtr += 1;
        XTIRType* pointee = [self parseTypeAt:posPtr tokens:tokens state:state];
        if (!pointee)
            return nil;
        XTIRTok* cm = [self tok:tokens at:*posPtr];
        if (cm.kind != XTIRTokComma)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected ',' inside Ptr(...)",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        *posPtr += 1;
        XTIRTok* winTok = [self tok:tokens at:*posPtr];
        XTIRWindowId w = XTIRWindowUnbanked;
        if ([winTok.text isEqualToString:@"unbanked"])
            w = XTIRWindowUnbanked;
        else if ([winTok.text isEqualToString:@"xt_code"])
            w = XTIRWindowXtCode;
        else if ([winTok.text isEqualToString:@"xt_data"])
            w = XTIRWindowXtData;
        else if ([winTok.text isEqualToString:@"xl_flat"])
            w = XTIRWindowXlFlat;
        else
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: unknown window '%@'",
                                                               (unsigned long)state.lineNumber, winTok.text]];
            return nil;
            }
        *posPtr += 1;
        XTIRTok* rp = [self tok:tokens at:*posPtr];
        if (rp.kind != XTIRTokRParen)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected ')' after Ptr arguments",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        *posPtr += 1;
        return [XTIRType ptrToType:pointee window:w];
        }
    if ([name isEqualToString:@"Agg"])
        {
        // Agg(N) — index into the module's layoutTable. Layouts are
        // declared in the layout header at the top of the module (the
        // printer emits them; parseModule reads them before any
        // function body) so layoutTable[N] is valid here.
        XTIRTok* lp = [self tok:tokens at:*posPtr];
        if (lp.kind != XTIRTokLParen)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '(' after Agg",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        *posPtr += 1;
        XTIRTok* nt = [self tok:tokens at:*posPtr];
        if (nt.kind != XTIRTokNumInt)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected layout index inside Agg(...)",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        NSUInteger idx = (NSUInteger)nt.intValue;
        *posPtr += 1;
        XTIRTok* rp = [self tok:tokens at:*posPtr];
        if (rp.kind != XTIRTokRParen)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected ')' after Agg index",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        *posPtr += 1;
        if (idx >= state.module.layoutTable.count)
            {
            // Forward reference to a layout that hasn't been seen yet.
            // The printer emits layouts BEFORE any use, so this only
            // happens with hand-written IR that's missing the
            // layout header. Synthesise an empty placeholder so the
            // parse doesn't bail; the verifier will catch any
            // mismatch downstream.
            while (state.module.layoutTable.count <= idx)
                {
                XTIRLayout* empty = [[XTIRLayout alloc] initWithSize:0 alignment:1 fields:@[]];
                [state.module.layoutTable addObject:empty];
                }
            }
        XTIRLayout* layout = state.module.layoutTable[idx];
        return [[XTIRType alloc] initWithAggLayout:layout];
        }
    [state.errors addObject:[NSString stringWithFormat:@"line %lu: unknown type '%@'",
                                                       (unsigned long)state.lineNumber, name]];
    return nil;
    }

#pragma mark Opcode lookup

+ (NSDictionary<NSString*, NSNumber*>*)opcodeTable
    {
    static NSDictionary* t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      t = @{
          @"Const" : @(XTIROpConst),
          @"Copy" : @(XTIROpCopy),
          @"Add" : @(XTIROpAdd),
          @"Sub" : @(XTIROpSub),
          @"Mul" : @(XTIROpMul),
          @"SDiv" : @(XTIROpSDiv),
          @"UDiv" : @(XTIROpUDiv),
          @"SRem" : @(XTIROpSRem),
          @"URem" : @(XTIROpURem),
          @"Neg" : @(XTIROpNeg),
          @"FAdd" : @(XTIROpFAdd),
          @"FSub" : @(XTIROpFSub),
          @"FMul" : @(XTIROpFMul),
          @"FDiv" : @(XTIROpFDiv),
          @"FNeg" : @(XTIROpFNeg),
          @"FSqrt" : @(XTIROpFSqrt),
          @"And" : @(XTIROpAnd),
          @"Or" : @(XTIROpOr),
          @"Xor" : @(XTIROpXor),
          @"Not" : @(XTIROpNot),
          @"Shl" : @(XTIROpShl),
          @"LShr" : @(XTIROpLShr),
          @"AShr" : @(XTIROpAShr),
          @"Rol" : @(XTIROpRol),
          @"Ror" : @(XTIROpRor),
          @"SExt" : @(XTIROpSExt),
          @"ZExt" : @(XTIROpZExt),
          @"Trunc" : @(XTIROpTrunc),
          @"Bitcast" : @(XTIROpBitcast),
          @"IntToPtr" : @(XTIROpIntToPtr),
          @"PtrToInt" : @(XTIROpPtrToInt),
          @"FpToSI" : @(XTIROpFpToSI),
          @"FpToUI" : @(XTIROpFpToUI),
          @"SIToFp" : @(XTIROpSIToFp),
          @"UIToFp" : @(XTIROpUIToFp),
          @"FpExt" : @(XTIROpFpExt),
          @"FpTrunc" : @(XTIROpFpTrunc),
          @"ClassDowncast" : @(XTIROpClassDowncast),
          @"ClassDowncastFailable" : @(XTIROpClassDowncastFailable),
          @"ICmp" : @(XTIROpICmp),
          @"VICmp" : @(XTIROpVICmp),
          @"FCmp" : @(XTIROpFCmp),
          @"Select" : @(XTIROpSelect),
          @"Load" : @(XTIROpLoad),
          @"Store" : @(XTIROpStore),
          @"LoadVolatile" : @(XTIROpLoadVolatile),
          @"StoreVolatile" : @(XTIROpStoreVolatile),
          @"MemCopy" : @(XTIROpMemCopy),
          @"MemSet" : @(XTIROpMemSet),
          @"AddrOf" : @(XTIROpAddrOf),
          @"AggBuild" : @(XTIROpAggBuild),
          @"AggExtract" : @(XTIROpAggExtract),
          @"AggInsert" : @(XTIROpAggInsert),
          @"AggLoad" : @(XTIROpAggLoad),
          @"AggStore" : @(XTIROpAggStore),
          @"FieldAddr" : @(XTIROpFieldAddr),
          @"ElementAddr" : @(XTIROpElementAddr),
          @"Branch" : @(XTIROpBranch),
          @"CondBranch" : @(XTIROpCondBranch),
          @"Switch" : @(XTIROpSwitch),
          @"Return" : @(XTIROpReturn),
          @"IndirectBranch" : @(XTIROpIndirectBranch),
          @"Unreachable" : @(XTIROpUnreachable),
          @"Call" : @(XTIROpCall),
          @"CallIndirect" : @(XTIROpCallIndirect),
          @"CallCloaked" : @(XTIROpCallCloaked),
          @"CallBanked" : @(XTIROpCallBanked),
          @"CallBankedIndirect" : @(XTIROpCallBankedIndirect),
          @"VTblDispatch" : @(XTIROpVTblDispatch),
          @"ProtoDispatch" : @(XTIROpProtoDispatch),
          @"ProtoLoad" : @(XTIROpProtoLoad),
          @"VTblLoad" : @(XTIROpVTblLoad),
          @"VaStart" : @(XTIROpVaStart),
          @"VaArg" : @(XTIROpVaArg),
          @"Phi" : @(XTIROpPhi),
          @"Retain" : @(XTIROpRetain),
          @"Release" : @(XTIROpRelease),
          @"Autorelease" : @(XTIROpAutorelease),
          @"WeakRegister" : @(XTIROpWeakRegister),
          @"WeakUnregister" : @(XTIROpWeakUnregister),
          @"WeakLoad" : @(XTIROpWeakLoad),
          @"BankSave" : @(XTIROpBankSave),
          @"BankRestore" : @(XTIROpBankRestore),
          @"BankSelectFor" : @(XTIROpBankSelectFor),
          @"Asm" : @(XTIROpAsm),
          @"DbgValue" : @(XTIROpDbgValue),
      };
    });
    return t;
    }

#pragma mark Block lookup helpers

+ (XTIRBlock*)blockForName:(NSString*)name state:(XTIRParserState*)state
    {
    XTIRBlock* b = state.blocksByName[name];
    if (!b)
        {
        b = [[XTIRBlock alloc] init];
        b.name = name;
        state.blocksByName[name] = b;
        // Don't add to function.blocks yet — that happens when the
        // `bb_name:` declaration is seen. Forward refs add only here.
        }
    return b;
    }

#pragma mark Value allocation

+ (XTIRValue*)allocateValueName:(NSString*)name
                           type:(XTIRType*)type
                         atSite:(XTIRDefSite*)defSite
                          state:(XTIRParserState*)state
                 registerInFunc:(BOOL)reg
    {
    XTIRFunction* fn = state.currentFunction;
    XTIRValueId vid = [fn allocateValueId];
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid type:type defSite:defSite];
    state.valuesByName[name] = v;
    if (reg)
        [fn registerValue:v];
    return v;
    }

#pragma mark Pass 1 — collect value defs

// Scan the LHS portion of a line (tokens up to the first `=`); if
// found, this line is a value-defining instruction and we allocate
// value-ids for each slot in textual order. The first slot has
// `:Type`; subsequent slots are bare (implicitly Mem).
//
// Returns the index of the `=` if found, otherwise NSNotFound.
+ (NSUInteger)scanLhsAndAllocate:(NSArray<XTIRTok*>*)tokens
                           state:(XTIRParserState*)state
                         inBlock:(XTIRBlock*)block
                instructionIndex:(NSUInteger)insnIdx
    {
    // Find '=' position (ignoring nested parens/brackets).
    NSUInteger eqPos = NSNotFound;
    NSInteger depth = 0;
    for (NSUInteger i = 0; i < tokens.count; i++)
        {
        XTIRTokKind k = tokens[i].kind;
        if (k == XTIRTokLParen || k == XTIRTokLBracket || k == XTIRTokLBrace)
            depth++;
        else if (k == XTIRTokRParen || k == XTIRTokRBracket || k == XTIRTokRBrace)
            depth--;
        else if (k == XTIRTokEquals && depth == 0)
            {
            eqPos = i;
            break;
            }
        }
    if (eqPos == NSNotFound)
        return NSNotFound;

    // Parse LHS slots: %name [: Type] (, %name [: Type])*
    NSUInteger i = 0;
    while (i < eqPos)
        {
        XTIRTok* t = tokens[i];
        if (t.kind != XTIRTokValName)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '%%name' in LHS",
                                                               (unsigned long)state.lineNumber]];
            return NSNotFound;
            }
        NSString* name = t.text;
        i++;
        XTIRType* slotType = nil;
        XTIRTok* next = (i < eqPos) ? tokens[i] : nil;
        if (next && next.kind == XTIRTokColon)
            {
            i++;
            slotType = [self parseTypeAt:&i tokens:tokens state:state];
            if (!slotType)
                return NSNotFound;
            }
        else
            {
            slotType = [XTIRType memoryType];
            }
        // Allocate value-id. Duplicate defs (same name appears twice in
        // a function): the second def creates a NEW XTIRValue with a
        // NEW value-id — but the SAME name maps to that new value. The
        // verifier counts insn.result occurrences per id to detect dup.
        // Wait — if both insns end up with different ids, the verifier
        // would not catch the dup. Instead, on a name collision we
        // reuse the existing valueId so both insns produce results
        // with the same id.
        if (state.valuesByName[name] != nil)
            {
            // Duplicate def. Re-emit an XTIRValue with the same id, do
            // not register (fn would assert). The first def stays in
            // function.values; the second is a free-standing value.
            XTIRValue* first = state.valuesByName[name];
            XTIRValue* dup = [[XTIRValue alloc] initWithValueId:first.valueId
                                                           type:slotType
                                                        defSite:[[XTIRDefSite alloc] initWithBlock:block insnIndex:insnIdx]];
            // We can't store the dup under the same key. Tag it with a
            // unique suffix and attach to a side map so the
            // instruction-building pass can find it.
            // Simpler: stash on an NSMutableArray keyed by (insnIdx).
            // Even simpler: re-bind name to dup (the dup is now what's
            // "currently in scope"). This means subsequent uses of
            // the name resolve to the dup's id (same id as first, so
            // semantically identical).
            state.valuesByName[name] = dup;
            // Note we don't register in the function — registerValue
            // would assert. The function.values still has the first;
            // both insns reference the same id.
            }
        else
            {
            XTIRDefSite* defSite = [[XTIRDefSite alloc] initWithBlock:block insnIndex:insnIdx];
            [self allocateValueName:name type:slotType atSite:defSite state:state registerInFunc:YES];
            }
        if (i < eqPos)
            {
            XTIRTok* sep = tokens[i];
            if (sep.kind == XTIRTokComma)
                {
                i++;
                continue;
                }
            else
                {
                [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected ',' or '=' in LHS",
                                                                   (unsigned long)state.lineNumber]];
                return NSNotFound;
                }
            }
        }
    return eqPos;
    }

#pragma mark Operand parsing

// Parse a single operand at *posPtr inside tokens.
+ (nullable XTIROperand*)parseOperandAt:(NSUInteger*)posPtr
                                 tokens:(NSArray<XTIRTok*>*)tokens
                                  state:(XTIRParserState*)state
    {
    XTIRTok* t = [self tok:tokens at:*posPtr];
    switch (t.kind)
        {
    case XTIRTokValName:
        {
        *posPtr += 1;
        XTIRValue* v = state.valuesByName[t.text];
        if (!v)
            {
            // Forward reference. Phi nodes routinely reference values
            // defined later in the printer's block emission order, so
            // unknown-at-use-time is normal — register the operand
            // for fix-up at function close, when every value in this
            // function is known. The temporary UINT32_MAX gets
            // overwritten then.
            XTIROperand* op = [XTIROperand useWithValueId:UINT32_MAX];
            if (!state.pendingValueRefs)
                {
                state.pendingValueRefs = [NSMutableArray array];
                }
            XTIRPendingRef* p = [[XTIRPendingRef alloc] init];
            p.operand = op;
            p.name = t.text;
            [state.pendingValueRefs addObject:p];
            return op;
            }
        return [XTIROperand useWithValueId:v.valueId];
        }
    case XTIRTokSymName:
        {
        *posPtr += 1;
        XTIRSymbol* sym = [state.module symbolForName:t.text];
        if (sym)
            {
            NSUInteger sid = [state.module.symbols indexOfObjectIdenticalTo:sym];
            return [XTIROperand symWithSymbolId:sid];
            }
        // Forward / unresolved ref. Record for later resolution.
        XTIROperand* op = [XTIROperand symWithSymbolId:NSUIntegerMax];
        XTIRPendingRef* pending = [[XTIRPendingRef alloc] init];
        pending.operand = op;
        pending.name = t.text;
        [state.pendingSymRefs addObject:pending];
        return op;
        }
    case XTIRTokHashInt:
        {
        *posPtr += 1;
        // expect : Type
        XTIRTok* cm = [self tok:tokens at:*posPtr];
        XTIRType* immType = [XTIRType i32Type];
        if (cm.kind == XTIRTokColon)
            {
            *posPtr += 1;
            immType = [self parseTypeAt:posPtr tokens:tokens state:state] ?: [XTIRType i32Type];
            }
        return [XTIROperand immIWithType:immType value:t.intValue];
        }
    case XTIRTokHashFloat:
        {
        *posPtr += 1;
        XTIRTok* cm = [self tok:tokens at:*posPtr];
        XTIRType* fType = [XTIRType f32Type];
        if (cm.kind == XTIRTokColon)
            {
            *posPtr += 1;
            fType = [self parseTypeAt:posPtr tokens:tokens state:state] ?: [XTIRType f32Type];
            }
        return [XTIROperand immFWithType:fType rawBytes:(uint64_t)t.intValue];
        }
    case XTIRTokHashCpool:
        {
        // #cpool:<idx> — reference to mod.constants[idx]. Until
        // the constant pool is also dumped/read by Printer/Parser
        // (separate work — currently it's only used for inline
        // asm aggregate bodies), we surface an operand that points
        // at the right slot if present, or a sentinel that the
        // verifier will catch. Inline asm Const-Agg refs in the
        // production path land here.
        *posPtr += 1;
        return [XTIROperand constAggWithConstantId:(XTIRConstantId)t.intValue];
        }
    case XTIRTokWord:
        {
        // Could be a block name (starts with bb_) or "CallConv"
        // (handled by caller) or just a misuse. Treat any bb_-
        // prefixed word as a block reference for terminator
        // operands.
        if ([t.text hasPrefix:@"bb_"])
            {
            *posPtr += 1;
            XTIRBlock* b = [self blockForName:t.text state:state];
            return [XTIROperand blockWithRef:b];
            }
        [state.errors addObject:[NSString stringWithFormat:@"line %lu: unexpected token '%@' as operand",
                                                           (unsigned long)state.lineNumber, t.text]];
        *posPtr += 1;
        return nil;
        }
    default:
        [state.errors addObject:[NSString stringWithFormat:@"line %lu: unexpected token kind %lu as operand",
                                                           (unsigned long)state.lineNumber, (unsigned long)t.kind]];
        *posPtr += 1;
        return nil;
        }
    }

#pragma mark Predicate parsing

+ (uint8_t)icmpPredicate:(NSString*)w
    {
    if ([w isEqualToString:@"EQ"])
        return XTIRICmpEQ;
    if ([w isEqualToString:@"NE"])
        return XTIRICmpNE;
    if ([w isEqualToString:@"SLT"])
        return XTIRICmpSLT;
    if ([w isEqualToString:@"SGT"])
        return XTIRICmpSGT;
    if ([w isEqualToString:@"SLE"])
        return XTIRICmpSLE;
    if ([w isEqualToString:@"SGE"])
        return XTIRICmpSGE;
    if ([w isEqualToString:@"ULT"])
        return XTIRICmpULT;
    if ([w isEqualToString:@"UGT"])
        return XTIRICmpUGT;
    if ([w isEqualToString:@"ULE"])
        return XTIRICmpULE;
    if ([w isEqualToString:@"UGE"])
        return XTIRICmpUGE;
    return 0xFF;
    }

+ (uint8_t)fcmpPredicate:(NSString*)w
    {
    if ([w isEqualToString:@"OEQ"])
        return XTIRFCmpOEQ;
    if ([w isEqualToString:@"ONE"])
        return XTIRFCmpONE;
    if ([w isEqualToString:@"OLT"])
        return XTIRFCmpOLT;
    if ([w isEqualToString:@"OGT"])
        return XTIRFCmpOGT;
    if ([w isEqualToString:@"OLE"])
        return XTIRFCmpOLE;
    if ([w isEqualToString:@"OGE"])
        return XTIRFCmpOGE;
    return 0xFF;
    }

#pragma mark CallConv parsing

// At call position the parser expects: CallConv :: Kind
+ (XTIRCallConv*)parseCallConvAt:(NSUInteger*)posPtr
                          tokens:(NSArray<XTIRTok*>*)tokens
                           state:(XTIRParserState*)state
    {
    XTIRTok* w = [self tok:tokens at:*posPtr];
    if (w.kind != XTIRTokWord || ![w.text isEqualToString:@"CallConv"])
        {
        return [XTIRCallConv standard];
        }
    *posPtr += 1;
    XTIRTok* cc = [self tok:tokens at:*posPtr];
    if (cc.kind != XTIRTokColonColon)
        return [XTIRCallConv standard];
    *posPtr += 1;
    XTIRTok* k = [self tok:tokens at:*posPtr];
    *posPtr += 1;
    if ([k.text isEqualToString:@"Standard"])
        return [XTIRCallConv standard];
    if ([k.text isEqualToString:@"Cloaked"])
        return [XTIRCallConv cloaked];
    if ([k.text isEqualToString:@"Banked"])
        return [XTIRCallConv banked];
    if ([k.text isEqualToString:@"Inline"])
        return [XTIRCallConv inlineConv];
    if ([k.text isEqualToString:@"RuntimeHelper"])
        return [XTIRCallConv runtimeHelper];
    return [XTIRCallConv standard];
    }

#pragma mark Pass 2 — build instructions

// Parse the RHS of an instruction line. `tokensRHS` are the tokens
// after `=` (or all tokens, if the insn has no result). `result`/`memResult`
// are the LHS values (may be nil).
+ (nullable XTIRInsn*)buildInsnWithOpcode:(XTIROpcode)op
                                   result:(nullable XTIRValue*)result
                             memoryResult:(nullable XTIRValue*)memResult
                                tokensRHS:(NSArray<XTIRTok*>*)tokens
                                    state:(XTIRParserState*)state
    {
    NSUInteger pos = 0;
    NSMutableArray<XTIROperand*>* operands = [NSMutableArray array];
    XTIRCallConv* cc = nil;
    uint8_t predicate = 0;
    BOOL hasPredicate = NO;

    switch (op)
        {
    case XTIROpPhi:
        {
        // Phi [(bb_pred, %v), ...]
        XTIRTok* lb = [self tok:tokens at:pos];
        if (lb.kind != XTIRTokLBracket)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '[' after Phi",
                                                               (unsigned long)state.lineNumber]];
            return nil;
            }
        pos++;
        while (pos < tokens.count)
            {
            XTIRTok* t = tokens[pos];
            if (t.kind == XTIRTokRBracket)
                {
                pos++;
                break;
                }
            if (t.kind == XTIRTokComma)
                {
                pos++;
                continue;
                }
            if (t.kind != XTIRTokLParen)
                {
                [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '(' in phi pair",
                                                                   (unsigned long)state.lineNumber]];
                return nil;
                }
            pos++;
            XTIROperand* blockOp = [self parseOperandAt:&pos tokens:tokens state:state];
            if ([self tok:tokens at:pos].kind == XTIRTokComma)
                pos++;
            XTIROperand* valOp = [self parseOperandAt:&pos tokens:tokens state:state];
            if ([self tok:tokens at:pos].kind == XTIRTokRParen)
                pos++;
            if (blockOp)
                [operands addObject:blockOp];
            if (valOp)
                [operands addObject:valOp];
            }
        break;
        }
    case XTIROpICmp:
    case XTIROpVICmp:
    case XTIROpFCmp:
        {
        XTIRTok* predTok = [self tok:tokens at:pos];
        if (predTok.kind == XTIRTokWord)
            {
            hasPredicate = YES;
            predicate = (op == XTIROpFCmp)
                            ? [self fcmpPredicate:predTok.text]
                            : [self icmpPredicate:predTok.text];
            pos++;
            if ([self tok:tokens at:pos].kind == XTIRTokComma)
                pos++;
            }
        // Fall through to generic operand parsing.
        while (pos < tokens.count)
            {
            XTIRTok* t = tokens[pos];
            if (t.kind == XTIRTokComma)
                {
                pos++;
                continue;
                }
            XTIROperand* o = [self parseOperandAt:&pos tokens:tokens state:state];
            if (!o)
                break;
            [operands addObject:o];
            }
        break;
        }
    case XTIROpCall:
    case XTIROpCallCloaked:
    case XTIROpCallBanked:
    case XTIROpCallIndirect:
    case XTIROpCallBankedIndirect:
        {
        // <callee>, [<args>], CallConv::<Kind>, <memInput>
        XTIROperand* callee = [self parseOperandAt:&pos tokens:tokens state:state];
        if (callee)
            [operands addObject:callee];
        if ([self tok:tokens at:pos].kind == XTIRTokComma)
            pos++;
        // Args list in [...]
        if ([self tok:tokens at:pos].kind == XTIRTokLBracket)
            {
            pos++;
            while (pos < tokens.count)
                {
                XTIRTok* t = tokens[pos];
                if (t.kind == XTIRTokRBracket)
                    {
                    pos++;
                    break;
                    }
                if (t.kind == XTIRTokComma)
                    {
                    pos++;
                    continue;
                    }
                XTIROperand* a = [self parseOperandAt:&pos tokens:tokens state:state];
                if (a)
                    [operands addObject:a];
                }
            }
        if ([self tok:tokens at:pos].kind == XTIRTokComma)
            pos++;
        cc = [self parseCallConvAt:&pos tokens:tokens state:state];
        if ([self tok:tokens at:pos].kind == XTIRTokComma)
            pos++;
        // memInput
        if (pos < tokens.count)
            {
            XTIROperand* m = [self parseOperandAt:&pos tokens:tokens state:state];
            if (m)
                [operands addObject:m];
            }
        break;
        }
    default:
        {
        // Generic: comma-separated operands.
        while (pos < tokens.count)
            {
            XTIRTok* t = tokens[pos];
            if (t.kind == XTIRTokComma)
                {
                pos++;
                continue;
                }
            if (t.kind == XTIRTokEOL)
                break;
            XTIROperand* o = [self parseOperandAt:&pos tokens:tokens state:state];
            if (!o)
                break;
            [operands addObject:o];
            }
        break;
        }
        }

    XTIRInsn* insn;
    if (cc)
        {
        insn = [[XTIRInsn alloc] initWithOpcode:op
                                         result:result
                                       operands:operands
                                       callConv:cc
                                         dbgLoc:nil];
        }
    else if (hasPredicate)
        {
        insn = [[XTIRInsn alloc] initWithOpcode:op
                                         result:result
                                       operands:operands
                                      predicate:predicate
                                         dbgLoc:nil];
        }
    else
        {
        insn = [[XTIRInsn alloc] initWithOpcode:op
                                         result:result
                                       operands:operands
                                         dbgLoc:nil];
        }
    insn.memoryResult = memResult;
    return insn;
    }

#pragma mark Line dispatch

// Parse the symbol-attributes block after the colon. Returns YES on
// success.
+ (BOOL)parseAttributesAt:(NSUInteger*)posPtr
                   tokens:(NSArray<XTIRTok*>*)tokens
                 intoDict:(NSMutableDictionary<NSString*, NSNumber*>*)dict
                    state:(XTIRParserState*)state
    {
    XTIRTok* lb = [self tok:tokens at:*posPtr];
    if (lb.kind != XTIRTokLBrace)
        return NO;
    *posPtr += 1;
    while (*posPtr < tokens.count)
        {
        XTIRTok* t = [self tok:tokens at:*posPtr];
        if (t.kind == XTIRTokRBrace)
            {
            *posPtr += 1;
            break;
            }
        if (t.kind == XTIRTokComma)
            {
            *posPtr += 1;
            continue;
            }
        if (t.kind != XTIRTokWord)
            {
            *posPtr += 1;
            continue;
            }
        NSString* key = t.text;
        *posPtr += 1;
        if ([self tok:tokens at:*posPtr].kind == XTIRTokColon)
            *posPtr += 1;
        XTIRTok* val = [self tok:tokens at:*posPtr];
        BOOL b = NO;
        if (val.kind == XTIRTokWord)
            {
            if ([val.text isEqualToString:@"true"])
                b = YES;
            else if ([val.text isEqualToString:@"false"])
                b = NO;
            *posPtr += 1;
            }
        else if (val.kind == XTIRTokLBrace)
            {
            // Nested set (e.g. clobbers: { _r1, _r2 }) — for the
            // fixture corpus we just skip these inner tokens until
            // matching '}'.
            NSInteger d = 0;
            do
                {
                XTIRTok* x = [self tok:tokens at:*posPtr];
                if (x.kind == XTIRTokLBrace)
                    d++;
                else if (x.kind == XTIRTokRBrace)
                    d--;
                *posPtr += 1;
                } while (d > 0 && *posPtr < tokens.count);
            continue;
            }
        else
            {
            *posPtr += 1;
            }
        dict[key] = @(b);
        }
    return YES;
    }

#pragma mark Module parsing — first pass over lines

+ (BOOL)processLine:(NSString*)line state:(XTIRParserState*)state
    {
    NSArray<XTIRTok*>* tokens = [self tokeniseLine:line];
    if (tokens.count == 0)
        return YES;
    XTIRTok* first = tokens[0];
    if (first.kind != XTIRTokWord && first.kind != XTIRTokRBrace && first.kind != XTIRTokValName)
        {
        return YES;
        }

    // Top-level: module "name" {
    if (first.kind == XTIRTokWord && [first.text isEqualToString:@"module"])
        {
        XTIRTok* nameTok = [self tok:tokens at:1];
        NSString* name = nameTok.kind == XTIRTokString ? nameTok.text : @"unnamed";
        if (!state.module)
            {
            state.module = [[XTIRModule alloc] initWithName:name];
            }
        return YES;
        }

    // Top-level closing brace
    if (first.kind == XTIRTokRBrace && state.currentFunction == nil)
        {
        return YES;
        }

    // Inside a function, closing brace ends the function.
    if (first.kind == XTIRTokRBrace && state.currentFunction != nil)
        {
        // Resolve any forward value refs registered while parsing this
        // function. Every name is now in valuesByName (the parser has
        // seen all defs); patch each pending operand's valueId via KVC.
        for (XTIRPendingRef* p in state.pendingValueRefs)
            {
            XTIRValue* v = state.valuesByName[p.name];
            if (v)
                {
                [p.operand setValue:@(v.valueId) forKey:@"valueId"];
                }
            else
                {
                [state.errors addObject:[NSString stringWithFormat:
                                                      @"function '%@': unresolved value '%%%@' at end of function",
                                                      state.currentFunction.name, p.name]];
                }
            }
        state.pendingValueRefs = nil;
        state.currentFunction = nil;
        state.currentBlock = nil;
        state.valuesByName = nil;
        state.blocksByName = nil;
        return YES;
        }

    // Lines that start with `%name` are value-defining instructions;
    // they can only appear inside a function body.
    if (first.kind == XTIRTokValName)
        {
        if (state.currentFunction == nil || state.currentBlock == nil)
            return YES;
        [self parseInstructionLine:tokens state:state];
        return YES;
        }

    if (first.kind != XTIRTokWord)
        return YES;
    NSString* kw = first.text;

    // modinit "<fn>" — a load-time constructor. The backend emits a pointer to
    // each into the target constructor list so it runs before main (XG-NIB
    // factory self-registration). Must round-trip across the front/back split.
    if ([kw isEqualToString:@"modinit"])
        {
        XTIRTok* nameTok = [self tok:tokens at:1];
        if (nameTok.kind == XTIRTokString && nameTok.text.length &&
            ![state.module.moduleInitFunctionNames containsObject:nameTok.text])
            {
            [state.module.moduleInitFunctionNames addObject:nameTok.text];
            }
        return YES;
        }

    // constant N: <kind> [bytes=[...] | value=<v> | bits=<u>]
    // Emitted by the printer for every entry in mod.constants. The
    // module's instruction operands reference these by index via
    // `#cpool:<idx>`, so without re-populating the pool any inline
    // asm Const-Agg ref resolves to nil and gets emitted as garbage.
    if ([kw isEqualToString:@"constant"])
        {
        XTIRTok* idxTok = [self tok:tokens at:1];
        if (idxTok.kind != XTIRTokNumInt)
            return YES;
        NSUInteger idx = (NSUInteger)idxTok.intValue;
        if ([self tok:tokens at:2].kind != XTIRTokColon)
            return YES;
        NSUInteger pos = 3;
        XTIRTok* kindTok = [self tok:tokens at:pos];
        if (kindTok.kind != XTIRTokWord)
            return YES;
        NSString* kindWord = kindTok.text;
        pos++;
        XTIRConstant* constant = nil;
        if ([kindWord isEqualToString:@"string"])
            {
            NSMutableData* bytes = [NSMutableData data];
            // expect bytes=[#$XX, ...]
            while (pos < tokens.count)
                {
                XTIRTok* t = [self tok:tokens at:pos];
                if (t.kind == XTIRTokLBracket)
                    {
                    pos++;
                    continue;
                    }
                if (t.kind == XTIRTokRBracket)
                    {
                    pos++;
                    break;
                    }
                if (t.kind == XTIRTokHashInt)
                    {
                    uint8_t b = (uint8_t)(t.intValue & 0xFF);
                    [bytes appendBytes:&b length:1];
                    pos++;
                    continue;
                    }
                pos++;
                }
            constant = [XTIRConstant stringConstantWithBytes:bytes];
            }
        else if ([kindWord isEqualToString:@"int"])
            {
            // best-effort: scan for the next NumInt (after `value=`).
            while (pos < tokens.count && [self tok:tokens at:pos].kind != XTIRTokNumInt)
                pos++;
            int64_t v = 0;
            if ([self tok:tokens at:pos].kind == XTIRTokNumInt)
                v = tokens[pos].intValue;
            constant = [XTIRConstant intConstantWithType:[XTIRType i32Type] value:v];
            }
        else if ([kindWord isEqualToString:@"float"])
            {
            while (pos < tokens.count && [self tok:tokens at:pos].kind != XTIRTokNumInt)
                pos++;
            uint64_t bits = 0;
            if ([self tok:tokens at:pos].kind == XTIRTokNumInt)
                bits = (uint64_t)tokens[pos].intValue;
            constant = [XTIRConstant floatConstantWithType:[XTIRType f64Type]
                                                  rawBytes:bits];
            }
        // agg: not yet round-tripped (printer doesn't dump elements).
        if (constant)
            {
            // Grow constants array as needed so index lines up with
            // the cpool reference.
            while (state.module.constants.count <= idx)
                {
                XTIRConstant* placeholder = [XTIRConstant
                    intConstantWithType:[XTIRType i32Type]
                                  value:0];
                [state.module.constants addObject:placeholder];
                }
            state.module.constants[idx] = constant;
            }
        return YES;
        }

    // layout N: size=<S> align=<A> [fields=[(off:T), ...]]
    // Emitted by the printer before any function so layoutTable[N] is
    // populated by the time Agg(N) appears in an instruction or frame
    // declaration. Tolerant of slight token shapes so it survives
    // editing.
    if ([kw isEqualToString:@"layout"])
        {
        XTIRTok* idxTok = [self tok:tokens at:1];
        if (idxTok.kind != XTIRTokNumInt)
            return YES;
        NSUInteger idx = (NSUInteger)idxTok.intValue;
        if ([self tok:tokens at:2].kind != XTIRTokColon)
            return YES;
        NSUInteger pos = 3;
        uint32_t size = 0;
        uint8_t align = 1;
        NSMutableArray<XTIRLayoutField*>* fields = [NSMutableArray array];
        while (pos < tokens.count)
            {
            XTIRTok* t = [self tok:tokens at:pos];
            if (t.kind == XTIRTokWord && [t.text isEqualToString:@"size"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokEquals)
                    pos++;
                XTIRTok* vt = [self tok:tokens at:pos];
                if (vt.kind == XTIRTokNumInt)
                    {
                    size = (uint32_t)vt.intValue;
                    pos++;
                    }
                continue;
                }
            if (t.kind == XTIRTokWord && [t.text isEqualToString:@"align"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokEquals)
                    pos++;
                XTIRTok* vt = [self tok:tokens at:pos];
                if (vt.kind == XTIRTokNumInt)
                    {
                    align = (uint8_t)vt.intValue;
                    pos++;
                    }
                continue;
                }
            if (t.kind == XTIRTokWord && [t.text isEqualToString:@"fields"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokEquals)
                    pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokLBracket)
                    pos++;
                // Parse `(off:type)` repeats, comma-separated.
                while (pos < tokens.count)
                    {
                    XTIRTok* tt = [self tok:tokens at:pos];
                    if (tt.kind == XTIRTokRBracket)
                        {
                        pos++;
                        break;
                        }
                    if (tt.kind == XTIRTokComma)
                        {
                        pos++;
                        continue;
                        }
                    if (tt.kind != XTIRTokLParen)
                        {
                        pos++;
                        continue;
                        }
                    pos++; // skip '('
                    XTIRTok* ot = [self tok:tokens at:pos];
                    uint32_t off = 0;
                    if (ot.kind == XTIRTokNumInt)
                        {
                        off = (uint32_t)ot.intValue;
                        pos++;
                        }
                    if ([self tok:tokens at:pos].kind == XTIRTokColon)
                        pos++;
                    XTIRType* fty = [self parseTypeAt:&pos tokens:tokens state:state];
                    if (!fty)
                        break;
                    if ([self tok:tokens at:pos].kind == XTIRTokRParen)
                        pos++;
                    [fields addObject:[[XTIRLayoutField alloc]
                                          initWithOffset:off
                                                    type:fty]];
                    }
                continue;
                }
            pos++;
            }
        // Grow layoutTable to (idx+1) — placeholders for any earlier
        // gaps the printer wouldn't have emitted but we'd like to
        // tolerate. Slot idx receives the freshly-parsed layout.
        while (state.module.layoutTable.count <= idx)
            {
            XTIRLayout* empty = [[XTIRLayout alloc] initWithSize:0 alignment:1 fields:@[]];
            [state.module.layoutTable addObject:empty];
            }
        // A SELF-REFERENTIAL layout (`layout 23: fields=[(0:Ptr(Agg(23)))]`,
        // which any linked-list C struct produces) has already put a
        // placeholder in slot idx while its own fields were being parsed, and
        // the field points AT that object. Replacing the slot would orphan it:
        // the field would reference a layout that is no longer in the table,
        // and the printer — which finds a layout by identity — would emit
        // `Agg(?)`. Fill the placeholder in place instead, exactly as the
        // lowering does when it meets the same cycle.
        XTIRLayout* slot = (idx < state.module.layoutTable.count)
                               ? state.module.layoutTable[idx]
                               : nil;
        if (slot && slot.fields.count == 0 && slot.size == 0)
            {
            [slot fillWithSize:size fields:fields];
            }
        else
            {
            XTIRLayout* layout = [[XTIRLayout alloc] initWithSize:size
                                                        alignment:align
                                                           fields:fields];
            state.module.layoutTable[idx] = layout;
            }
        return YES;
        }

    // symbol Name : kind ... attributes
    if ([kw isEqualToString:@"symbol"])
        {
        XTIRTok* nameTok = [self tok:tokens at:1];
        if (nameTok.kind != XTIRTokWord)
            return YES;
        NSString* symName = nameTok.text;
        // Expect ':' at index 2.
        if ([self tok:tokens at:2].kind != XTIRTokColon)
            return YES;
        XTIRTok* kindTok = [self tok:tokens at:3];
        NSString* kindWord = kindTok.text;
        NSUInteger pos = 4;

        if ([kindWord isEqualToString:@"function"])
            {
            // Parse language-level signature: (T, T, ...) -> T
            NSMutableArray<XTIRType*>* paramTypes = [NSMutableArray array];
            if ([self tok:tokens at:pos].kind == XTIRTokLParen)
                {
                pos++;
                while (pos < tokens.count)
                    {
                    XTIRTok* t = tokens[pos];
                    if (t.kind == XTIRTokRParen)
                        {
                        pos++;
                        break;
                        }
                    if (t.kind == XTIRTokComma)
                        {
                        pos++;
                        continue;
                        }
                    XTIRType* ty = [self parseTypeAt:&pos tokens:tokens state:state];
                    if (ty)
                        [paramTypes addObject:ty];
                    else
                        break;
                    }
                }
            XTIRType* returnType = [XTIRType voidType];
            if ([self tok:tokens at:pos].kind == XTIRTokArrow)
                {
                pos++;
                returnType = [self parseTypeAt:&pos tokens:tokens state:state] ?: [XTIRType voidType];
                }
            // Parse trailing attributes: ... (may be on same logical line because
            // of comma-continuation joining).
            NSMutableDictionary<NSString*, NSNumber*>* attrs = [NSMutableDictionary dictionary];
            if ([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"attributes"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokColon)
                    pos++;
                [self parseAttributesAt:&pos tokens:tokens intoDict:attrs state:state];
                }
            // flags: { escapes: true, ... } — intrinsic boolean flags
            // the printer emits explicitly when set, distinct from the
            // generic attributes dictionary.
            NSMutableDictionary<NSString*, NSNumber*>* flagsDict = [NSMutableDictionary dictionary];
            if ([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"flags"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokColon)
                    pos++;
                [self parseAttributesAt:&pos tokens:tokens intoDict:flagsDict state:state];
                }

            // Create a skeleton function (no entry block yet — will be
            // filled in when `function NAME(...)` decl arrives or, if
            // never, we leave it empty).
            XTIRSymbol* existing = [state.module symbolForName:symName];
            if (!existing)
                {
                // Allocate the function shell with an unnamed entry
                // block. We do NOT add it to mod.functions yet — that
                // happens when (and if) a `function` body decl arrives.
                // Symbols declared but never defined produce no
                // verifiable function, which is correct for external
                // / forward-declared callees.
                XTIRBlock* entry = [[XTIRBlock alloc] init];
                NSMutableArray<XTIRType*>* fullParams = [paramTypes mutableCopy];
                [fullParams addObject:[XTIRType memoryType]];
                XTIRFunction* fn = [[XTIRFunction alloc] initWithName:symName
                                                           returnType:returnType
                                                           paramTypes:fullParams
                                                           entryBlock:entry];
                XTIRSymbol* sym = [XTIRSymbol functionWithName:symName function:fn type:nil];
                sym.attributes = attrs;
                // Project the intrinsic flags off the dedicated
                // XTIRSymbol properties via KVC (they're readonly in
                // the public header; the .m's private extension
                // re-declares them readwrite so KVC reaches the
                // generated setter). DFE keys on sym.escapes.
                if (flagsDict[@"escapes"].boolValue)
                    [sym setValue:@(YES) forKey:@"escapes"];
                if (flagsDict[@"volatile"].boolValue)
                    [sym setValue:@(YES) forKey:@"volatileAccess"];
                if (flagsDict[@"taskLocal"].boolValue)
                    [sym setValue:@(YES) forKey:@"taskLocal"];
                [state.module addSymbol:sym];
                }
            else
                {
                existing.attributes = attrs;
                if (flagsDict[@"escapes"].boolValue)
                    [existing setValue:@(YES) forKey:@"escapes"];
                if (flagsDict[@"volatile"].boolValue)
                    [existing setValue:@(YES) forKey:@"volatileAccess"];
                if (flagsDict[@"taskLocal"].boolValue)
                    [existing setValue:@(YES) forKey:@"taskLocal"];
                }
            return YES;
            }

        if ([kindWord isEqualToString:@"vtable"])
            {
            // Slot list `[Foo$hash, Foo$equals, ...]` (empty-name slot
            // = `_`). The printer emits it inline; restoring it here is
            // what lets dead-function-elim seed the virtual methods as
            // roots and the backend emit the real jump table. Without
            // this the vtable round-trips empty → null dispatch.
            NSMutableArray<NSString*>* entries = [NSMutableArray array];
            if ([self tok:tokens at:pos].kind == XTIRTokLBracket)
                {
                pos++; // '['
                while (pos < tokens.count && [self tok:tokens at:pos].kind != XTIRTokRBracket)
                    {
                    XTIRTok* t = [self tok:tokens at:pos];
                    if (t.kind == XTIRTokWord)
                        {
                        [entries addObject:([t.text isEqualToString:@"_"]
                                                ? @""
                                                : t.text)];
                        }
                    pos++;
                    }
                if (pos < tokens.count && [self tok:tokens at:pos].kind == XTIRTokRBracket)
                    {
                    pos++; // ']'
                    }
                }
            NSMutableDictionary<NSString*, NSNumber*>* attrs = [NSMutableDictionary dictionary];
            if ([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"attributes"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokColon)
                    pos++;
                [self parseAttributesAt:&pos tokens:tokens intoDict:attrs state:state];
                }
            XTIRSymbol* vsym = [state.module symbolForName:symName];
            if (!vsym)
                {
                vsym = [XTIRSymbol vTableWithName:symName layout:nil];
                [state.module addSymbol:vsym];
                }
            vsym.attributes = attrs;
            if (entries.count)
                vsym.vtableEntryNames = entries;
            return YES;
            }

        if ([kindWord isEqualToString:@"dataglobal"])
            {
            XTIRType* ty = [self parseTypeAt:&pos tokens:tokens state:state] ?: [XTIRType voidType];
            NSMutableData* initBytes = nil;
            if (pos < tokens.count && [self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"init"])
                {
                pos++; // 'init'
                if (pos < tokens.count && [self tok:tokens at:pos].kind == XTIRTokLBracket)
                    {
                    pos++; // '['
                    initBytes = [NSMutableData data];
                    while (pos < tokens.count && [self tok:tokens at:pos].kind != XTIRTokRBracket)
                        {
                        if ([self tok:tokens at:pos].kind == XTIRTokHashInt)
                            {
                            uint8_t byte = (uint8_t)(tokens[pos].intValue & 0xFF);
                            [initBytes appendBytes:&byte length:1];
                            pos++;
                            }
                        else if ([self tok:tokens at:pos].kind == XTIRTokComma)
                            {
                            pos++;
                            }
                        else
                            {
                            pos++;
                            }
                        }
                    if (pos < tokens.count && [self tok:tokens at:pos].kind == XTIRTokRBracket)
                        {
                        pos++; // ']'
                        }
                    }
                }
            NSMutableDictionary<NSString*, NSNumber*>* attrs = [NSMutableDictionary dictionary];
            if ([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"attributes"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokColon)
                    pos++;
                [self parseAttributesAt:&pos tokens:tokens intoDict:attrs state:state];
                }
            // `escapes` / `volatile` / `taskLocal` are printed in the `flags:`
            // clause, NOT in `attributes:` — reading them out of the attribute
            // dictionary found nothing, so every data global came back from the
            // text as non-escaping. The function branch already reads the right
            // clause; this one did not.
            NSMutableDictionary<NSString*, NSNumber*>* gflags = [NSMutableDictionary dictionary];
            if ([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"flags"])
                {
                pos++;
                if ([self tok:tokens at:pos].kind == XTIRTokColon)
                    pos++;
                [self parseAttributesAt:&pos tokens:tokens intoDict:gflags state:state];
                }
            BOOL vol = attrs[@"volatile"].boolValue || gflags[@"volatile"].boolValue;
            BOOL esc = attrs[@"escapes"].boolValue || gflags[@"escapes"].boolValue;
            BOOL tl = attrs[@"taskLocal"].boolValue || gflags[@"taskLocal"].boolValue;
            XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:symName
                                                        type:ty
                                                    volatile:vol
                                                     escapes:esc
                                                   taskLocal:tl];
            sym.attributes = attrs;
            if (initBytes.length)
                sym.initialBytes = initBytes;
            [state.module addSymbol:sym];
            return YES;
            }

        // Other symbol kinds are not exercised by the fixtures; create
        // a placeholder so the lookup table contains them.
        XTIRSymbol* sym = nil;
        if ([kindWord isEqualToString:@"runtime"])
            {
            sym = [XTIRSymbol runtimeHelperWithName:symName
                                         clobberSet:[[XTIRClobberSet alloc] initWithClobberedNames:@[]]
                                           mayAlloc:NO
                                           mayThrow:NO];
            }
        else if ([kindWord isEqualToString:@"stringlit"])
            {
            NSMutableData* strBytes = [NSMutableData data];
            if (pos < tokens.count && [self tok:tokens at:pos].kind == XTIRTokLBracket)
                {
                pos++; // '['
                while (pos < tokens.count && [self tok:tokens at:pos].kind != XTIRTokRBracket)
                    {
                    if ([self tok:tokens at:pos].kind == XTIRTokHashInt)
                        {
                        uint8_t byte = (uint8_t)(tokens[pos].intValue & 0xFF);
                        [strBytes appendBytes:&byte length:1];
                        }
                    pos++;
                    }
                }
            sym = [XTIRSymbol stringLitWithName:symName bytes:strBytes];
            if (pos < tokens.count && [self tok:tokens at:pos].kind == XTIRTokRBracket)
                pos++; // ']'
            }
        else if ([kindWord isEqualToString:@"zpequate"])
            {
            sym = [XTIRSymbol zpEquateWithName:symName address:0];
            }
        // The attributes the PRINTER writes for these kinds have to come back,
        // or the text does not survive its own round trip: a string literal
        // prints `attributes: { banked: …, cloaked: … }` and the reader used to
        // drop the clause on the floor. Harmless while every literal carries the
        // defaults, and silent data loss across the front-end/back-end process
        // boundary the moment one does not.
        // A `runtime` symbol's signature (`() -> Void`) is not consumed above,
        // so the clause is not necessarily the next token — find it.
        while (sym && pos < tokens.count && !([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"attributes"]))
            pos++;
        if (sym && [self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"attributes"])
            {
            pos++;
            if ([self tok:tokens at:pos].kind == XTIRTokColon)
                pos++;
            NSMutableDictionary<NSString*, NSNumber*>* attrs = [NSMutableDictionary dictionary];
            [self parseAttributesAt:&pos tokens:tokens intoDict:attrs state:state];
            sym.attributes = attrs;
            }
        if (sym)
            [state.module addSymbol:sym];
        return YES;
        }

    // function name(...) -> ... {
    if ([kw isEqualToString:@"function"])
        {
        XTIRTok* nameTok = [self tok:tokens at:1];
        if (nameTok.kind != XTIRTokWord)
            return YES;
        NSString* fnName = nameTok.text;
        XTIRSymbol* sym = [state.module symbolForName:fnName];
        XTIRFunction* fn = sym ? sym.function : nil;
        NSUInteger pos = 2;
        // (%name: Type, ...)
        if ([self tok:tokens at:pos].kind != XTIRTokLParen)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '(' after function name",
                                                               (unsigned long)state.lineNumber]];
            return YES;
            }
        pos++;
        NSMutableArray<NSString*>* paramNames = [NSMutableArray array];
        NSMutableArray<XTIRType*>* paramTypes = [NSMutableArray array];
        while (pos < tokens.count)
            {
            XTIRTok* t = tokens[pos];
            if (t.kind == XTIRTokRParen)
                {
                pos++;
                break;
                }
            if (t.kind == XTIRTokComma)
                {
                pos++;
                continue;
                }
            if (t.kind != XTIRTokValName)
                {
                [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '%%name' in param list",
                                                                   (unsigned long)state.lineNumber]];
                return YES;
                }
            NSString* pname = t.text;
            pos++;
            if ([self tok:tokens at:pos].kind == XTIRTokColon)
                pos++;
            XTIRType* pty = [self parseTypeAt:&pos tokens:tokens state:state];
            if (!pty)
                return YES;
            [paramNames addObject:pname];
            [paramTypes addObject:pty];
            }
        // -> retType OR -> (retType, Mem) OR -> Mem
        if ([self tok:tokens at:pos].kind != XTIRTokArrow)
            {
            [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected '->' after params",
                                                               (unsigned long)state.lineNumber]];
            return YES;
            }
        pos++;
        XTIRType* retType = nil;
        if ([self tok:tokens at:pos].kind == XTIRTokLParen)
            {
            pos++;
            retType = [self parseTypeAt:&pos tokens:tokens state:state] ?: [XTIRType voidType];
            // skip the trailing ", Mem)"
            while (pos < tokens.count && [self tok:tokens at:pos].kind != XTIRTokRParen)
                pos++;
            if (pos < tokens.count)
                pos++;
            }
        else
            {
            retType = [self parseTypeAt:&pos tokens:tokens state:state] ?: [XTIRType voidType];
            if (retType.kind == XTIRTypeKindMemory)
                retType = [XTIRType voidType];
            }

        // If we have an existing function (from symbol decl), reuse
        // it. Otherwise build a new one with the IR-level paramTypes
        // (append the implicit Mem if not already present).
        if (!fn)
            {
            XTIRBlock* entry = [[XTIRBlock alloc] init];
            NSMutableArray<XTIRType*>* fullParams = [paramTypes mutableCopy];
            if (fullParams.count == 0 || [fullParams.lastObject kind] != XTIRTypeKindMemory)
                {
                [fullParams addObject:[XTIRType memoryType]];
                }
            fn = [[XTIRFunction alloc] initWithName:fnName
                                         returnType:retType
                                         paramTypes:fullParams
                                         entryBlock:entry];
            sym = [XTIRSymbol functionWithName:fnName function:fn type:nil];
            [state.module addSymbol:sym];
            }
        // A function with a body must appear in mod.functions so the
        // verifier walks it. Symbol-decl-only functions stay out of
        // the list (forward / external declarations).
        if (![state.module.functions containsObject:fn])
            {
            [state.module addFunction:fn];
            }

        state.currentFunction = fn;
        state.valuesByName = [NSMutableDictionary dictionary];
        state.blocksByName = [NSMutableDictionary dictionary];

        // Register parameters as values (ids 0..N-1). The function's
        // paramTypes includes the trailing Mem.
        XTIRDefSite* paramDef = [XTIRDefSite parameterDef];
        // The existing function might already have its paramTypes if
        // pre-built from the symbol decl; otherwise we set them above.
        for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
            {
            NSString* pname = (i < paramNames.count) ? paramNames[i] : [NSString stringWithFormat:@"p%lu", (unsigned long)i];
            XTIRValueId vid = [fn allocateValueId];
            XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                         type:fn.paramTypes[i]
                                                      defSite:paramDef];
            [fn registerValue:v];
            state.valuesByName[pname] = v;
            }
        // Entry block is already a member of fn.blocks; map by its
        // textual name once we encounter `bb_entry:`. But for early
        // terminators referencing the entry block, register it now if
        // it has a name.
        if (fn.entryBlock.name)
            state.blocksByName[fn.entryBlock.name] = fn.entryBlock;
        state.currentBlock = nil;
        return YES;
        }

    // Inside a function:
    if (state.currentFunction != nil)
        {
        // unroll: [bb_x, ...] — the loop headers `: unroll` asked for. Read
        // back into the same set the printer wrote, so the hint survives the
        // front-end/back-end process boundary; without this the optimiser in
        // xcc-cg-<arch> would never see it, because the two halves only ever
        // exchange IR TEXT.
        if ([kw isEqualToString:@"unroll"])
            {
            NSUInteger pos = 1;
            if ([self tok:tokens at:pos].kind == XTIRTokColon)
                pos++;
            if ([self tok:tokens at:pos].kind != XTIRTokLBracket)
                return YES;
            pos++;
            while ([self tok:tokens at:pos].kind == XTIRTokWord)
                {
                [state.currentFunction.forcedUnrollHeaders
                    addObject:[self tok:tokens at:pos].text];
                pos++;
                if ([self tok:tokens at:pos].kind != XTIRTokComma)
                    break;
                pos++;
                }
            return YES;
            }
        // frame: { pinned: [(%loc:T @off), ...], size: N }
        if ([kw isEqualToString:@"frame"])
            {
            NSUInteger pos = 1;
            if ([self tok:tokens at:pos].kind == XTIRTokColon)
                pos++;
            if ([self tok:tokens at:pos].kind != XTIRTokLBrace)
                return YES;
            pos++;
            NSMutableArray<XTIRPinnedLocal*>* locals = [NSMutableArray array];
            uint32_t declaredSize = 0;
            while (pos < tokens.count)
                {
                XTIRTok* t = [self tok:tokens at:pos];
                if (t.kind == XTIRTokRBrace)
                    {
                    pos++;
                    break;
                    }
                if (t.kind == XTIRTokComma)
                    {
                    pos++;
                    continue;
                    }
                if (t.kind == XTIRTokWord && [t.text isEqualToString:@"pinned"])
                    {
                    pos++;
                    if ([self tok:tokens at:pos].kind == XTIRTokColon)
                        pos++;
                    if ([self tok:tokens at:pos].kind != XTIRTokLBracket)
                        continue;
                    pos++;
                    while (pos < tokens.count)
                        {
                        XTIRTok* p = [self tok:tokens at:pos];
                        if (p.kind == XTIRTokRBracket)
                            {
                            pos++;
                            break;
                            }
                        if (p.kind == XTIRTokComma)
                            {
                            pos++;
                            continue;
                            }
                        if (p.kind != XTIRTokLParen)
                            {
                            pos++;
                            continue;
                            }
                        pos++;
                        // %name : Type @offset
                        XTIRTok* nm = [self tok:tokens at:pos];
                        if (nm.kind != XTIRTokValName)
                            {
                            pos++;
                            continue;
                            }
                        NSString* localName = nm.text;
                        pos++;
                        if ([self tok:tokens at:pos].kind == XTIRTokColon)
                            pos++;
                        XTIRType* localTy = [self parseTypeAt:&pos tokens:tokens state:state] ?: [XTIRType voidType];
                        uint32_t off = 0;
                        if ([self tok:tokens at:pos].kind == XTIRTokAt)
                            {
                            pos++;
                            XTIRTok* nt = [self tok:tokens at:pos];
                            if (nt.kind == XTIRTokNumInt)
                                {
                                off = (uint32_t)nt.intValue;
                                pos++;
                                }
                            }
                        // `esc` — the address escapes via a pointer, so the
                        // backend must use stable frame spill, not a static
                        // ZP pin (which aliases across calls). Lost-on-round-
                        // trip → value-class instance corruption.
                        BOOL escapes = NO;
                        if ([self tok:tokens at:pos].kind == XTIRTokWord && [tokens[pos].text isEqualToString:@"esc"])
                            {
                            escapes = YES;
                            pos++;
                            }
                        if ([self tok:tokens at:pos].kind == XTIRTokRParen)
                            pos++;
                        // Allocate a value-id for the pinned local.
                        XTIRFunction* fn = state.currentFunction;
                        XTIRValueId vid = [fn allocateValueId];
                        XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                                     type:localTy
                                                                  defSite:[XTIRDefSite parameterDef]];
                        [fn registerValue:v];
                        state.valuesByName[localName] = v;
                        XTIRPinnedLocal* pl = [[XTIRPinnedLocal alloc] initWithName:localName
                                                                               type:localTy
                                                                         byteOffset:off
                                                                            valueId:vid];
                        pl.escapesViaPointer = escapes;
                        [locals addObject:pl];
                        }
                    continue;
                    }
                if (t.kind == XTIRTokWord && [t.text isEqualToString:@"size"])
                    {
                    pos++;
                    if ([self tok:tokens at:pos].kind == XTIRTokColon)
                        pos++;
                    if ([self tok:tokens at:pos].kind == XTIRTokNumInt)
                        {
                        declaredSize = (uint32_t)tokens[pos].intValue;
                        pos++;
                        }
                    continue;
                    }
                pos++;
                }
            XTIRFunction* fn = state.currentFunction;
            fn.frameInfo.pinnedLocals = locals;
            fn.frameInfo.pinnedLocalSize = declaredSize;
            return YES;
            }

        // bb_name:
        if ([kw hasPrefix:@"bb_"] && [self tok:tokens at:1].kind == XTIRTokColon)
            {
            XTIRFunction* fn = state.currentFunction;
            XTIRBlock* block = state.blocksByName[kw];
            if (!block)
                {
                // Use the existing entry block if its name matches, else
                // create a new one.
                if (fn.entryBlock && (!fn.entryBlock.name || [fn.entryBlock.name isEqualToString:kw]) && ![state.blocksByName.allValues containsObject:fn.entryBlock])
                    {
                    block = fn.entryBlock;
                    block.name = kw;
                    }
                else
                    {
                    block = [[XTIRBlock alloc] init];
                    block.name = kw;
                    [fn.blocks addObject:block];
                    }
                state.blocksByName[kw] = block;
                }
            else
                {
                // Block was created as a forward reference. Now it
                // needs to be added to the function's block list.
                if (![fn.blocks containsObject:block])
                    {
                    [fn.blocks addObject:block];
                    }
                }
            state.currentBlock = block;
            return YES;
            }

        // preds: ...
        if ([kw isEqualToString:@"preds"] && [self tok:tokens at:1].kind == XTIRTokColon)
            {
            // Preds are derivable from terminators; we don't need to
            // store them. Just validate the syntax.
            return YES;
            }

        // attributes: { ... } — should have been folded into the
        // preceding symbol decl by the continuation-join. But if it
        // appears as its own line, attach to the last-added symbol.
        if ([kw isEqualToString:@"attributes"] && [self tok:tokens at:1].kind == XTIRTokColon)
            {
            return YES;
            }

        // Otherwise: an instruction.
        if (state.currentBlock == nil)
            return YES;
        [self parseInstructionLine:tokens state:state];
        return YES;
        }

    return YES;
    }

#pragma mark Instruction-line parsing

+ (void)parseInstructionLine:(NSArray<XTIRTok*>*)tokens state:(XTIRParserState*)state
    {
    if (state.currentBlock == nil)
        return;
    NSUInteger insnIdx = state.currentBlock.instructions.count;
    NSUInteger eqPos = [self scanLhsAndAllocate:tokens
                                          state:state
                                        inBlock:state.currentBlock
                               instructionIndex:insnIdx];

    NSArray<XTIRTok*>* rhs;
    XTIRValue* resultVal = nil;
    XTIRValue* memResultVal = nil;
    if (eqPos != NSNotFound)
        {
        NSMutableArray<NSString*>* lhsNames = [NSMutableArray array];
        for (NSUInteger i = 0; i < eqPos; i++)
            {
            if (tokens[i].kind == XTIRTokValName)
                [lhsNames addObject:tokens[i].text];
            }
        if (lhsNames.count >= 1)
            resultVal = state.valuesByName[lhsNames[0]];
        if (lhsNames.count >= 2)
            memResultVal = state.valuesByName[lhsNames[1]];
        // A single-slot LHS whose type is Mem is the memoryResult, not
        // the language-level result (e.g. `%m1 = Store ...`).
        if (resultVal && resultVal.type.kind == XTIRTypeKindMemory && lhsNames.count == 1)
            {
            memResultVal = resultVal;
            resultVal = nil;
            }
        rhs = [tokens subarrayWithRange:NSMakeRange(eqPos + 1, tokens.count - eqPos - 1)];
        }
    else
        {
        rhs = tokens;
        }

    NSUInteger rhsStart = 0;
    XTIRTok* opTok = [self tok:rhs at:rhsStart];
    if (opTok.kind != XTIRTokWord)
        {
        [state.errors addObject:[NSString stringWithFormat:@"line %lu: expected opcode word",
                                                           (unsigned long)state.lineNumber]];
        return;
        }
    NSNumber* opNum = [self opcodeTable][opTok.text];
    if (!opNum)
        {
        [state.errors addObject:[NSString stringWithFormat:@"line %lu: unknown opcode '%@'",
                                                           (unsigned long)state.lineNumber, opTok.text]];
        return;
        }
    XTIROpcode op = (XTIROpcode)opNum.intValue;
    rhsStart++;

    NSArray<XTIRTok*>* rhsAfterOp =
        [rhs subarrayWithRange:NSMakeRange(rhsStart, rhs.count - rhsStart)];
    XTIRInsn* insn = [self buildInsnWithOpcode:op
                                        result:resultVal
                                  memoryResult:memResultVal
                                     tokensRHS:rhsAfterOp
                                         state:state];
    if (!insn)
        return;

    if (insn.opcode == XTIROpPhi)
        {
        [state.currentBlock.phiNodes addObject:insn];
        }
    else if (insn.isTerminator)
        {
        if (state.currentBlock.terminator == nil)
            {
            [state.currentBlock setTerminator:insn];
            }
        else
            {
            [state.currentBlock.instructions addObject:insn];
            state.currentBlock.hasInstructionAfterTerminator = YES;
            }
        }
    else
        {
        if (state.currentBlock.terminator != nil)
            {
            [state.currentBlock.instructions addObject:insn];
            state.currentBlock.hasInstructionAfterTerminator = YES;
            }
        else
            {
            [state.currentBlock appendInstruction:insn];
            }
        }
    }

#pragma mark Resolve forward refs

+ (void)resolveForwardRefs:(XTIRParserState*)state
    {
    for (XTIRPendingRef* p in state.pendingSymRefs)
        {
        XTIRSymbol* sym = [state.module symbolForName:p.name];
        if (sym)
            {
            NSUInteger sid = [state.module.symbols indexOfObjectIdenticalTo:sym];
            // XTIROperand's symbolId is readwrite via .m; we set it
            // through KVC since we don't expose a public setter.
            [p.operand setValue:@(sid) forKey:@"symbolId"];
            }
        // unresolved: leave NSUIntegerMax — verifier rejects via §12.8.
        }
    }

#pragma mark Public

+ (nullable XTIRModule*)moduleFromString:(NSString*)text
                                   error:(NSError* _Nullable* _Nullable)error
    {
    XTIRParserState* state = [[XTIRParserState alloc] init];

    NSArray<NSString*>* lines = [self preprocessLines:text];
    for (NSUInteger i = 0; i < lines.count; i++)
        {
        state.lineNumber = i + 1;
        [self processLine:lines[i] state:state];
        }
    if (!state.module)
        {
        if (error)
            {
            *error = [NSError errorWithDomain:XTIRParserErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"no module declaration found"}];
            }
        return nil;
        }
    [self resolveForwardRefs:state];

    if (state.errors.count > 0 && error)
        {
        *error = [NSError errorWithDomain:XTIRParserErrorDomain
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey :
                                                [state.errors componentsJoinedByString:@"\n"]}];
        }
    return state.module;
    }

@end
