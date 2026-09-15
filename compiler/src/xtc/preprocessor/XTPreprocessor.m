#import "XTPreprocessor.h"
#import "XTMacroDefinition.h"

/****************************************************************************\
|* Per-#if-block state for the conditional-compilation stack. Three
|* values suffice:
|*   active — true when lines inside this block should be emitted
|*   taken  — true once any branch (#if / #elif / #else) in this
|*            chain has been entered; suppresses later branches
|*   parentActive — the enclosing block's active state, captured
|*            on push so #elif / #else can re-evaluate against it
|*            without walking the stack.
\****************************************************************************/
@interface XTIfFrame : NSObject
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL taken;
@property(nonatomic) BOOL parentActive;
@end
@implementation XTIfFrame
@end

@interface XTPreprocessor ()
@property(nonatomic) XTDiagnosticEngine* diagnostics;
@property(nonatomic) NSMutableDictionary<NSString*, XTMacroDefinition*>* macros;
/****************************************************************************\
|* Set of macro names currently being expanded (blue-painting / cycle detection).
\****************************************************************************/
@property(nonatomic) NSMutableSet<NSString*>* expandingMacros;
/****************************************************************************\
|* Set of absolute file paths already imported via #import (included at most once).
\****************************************************************************/
@property(nonatomic) NSMutableSet<NSString*>* importedFiles;
@property(nonatomic) NSMutableSet<NSString*>* mutablePreludeFiles;
@property(nonatomic) BOOL inPrelude;
/****************************************************************************\
|* The `#package` in force — the host import namespace for subsequent extern
|* declarations (wasm-target.md §6). Saved/restored across file boundaries
|* by handleInclude:. nil = the default package.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* currentPackage;
/****************************************************************************\
|* Stack of #if / #ifdef / #ifndef frames currently open. Empty means
|* unconditionally active.
\****************************************************************************/
@property(nonatomic) NSMutableArray<XTIfFrame*>* ifStack;
/****************************************************************************\
|* Mutable backing for the readonly `metadataImports`, plus a dedup set
|* (#import is once-only).
\****************************************************************************/
@property(nonatomic) NSMutableArray<NSString*>* mutableMetadataImports;
@property(nonatomic) NSMutableSet<NSString*>* metadataImportSet;
/****************************************************************************\
|* Recursion depth of preprocessSource: (0 = the top-level file). Used to
|* register the ENTRY file in importedFiles, so an import cycle that leads
|* back to it (Object.xc → String.xc → CharacterSet.xc → Object.xc) hits the
|* once-only check instead of re-including the file mid-cycle — which defined
|* every class in it twice and crashed lowering (append-after-terminator).
\****************************************************************************/
@property(nonatomic) NSUInteger sourceDepth;
@end

@implementation XTPreprocessor

/****************************************************************************\
|* Initialise the preprocessor with a diagnostic engine for error reporting.
|* @param diagnostics  The shared diagnostic engine.
|* @return  A configured preprocessor instance with no macros defined.
\****************************************************************************/
- (instancetype)initWithDiagnostics:(XTDiagnosticEngine*)diagnostics
    {
    self = [super init];
    if (self)
        {
        _diagnostics = diagnostics;
        _macros = [NSMutableDictionary dictionary];
        _expandingMacros = [NSMutableSet set];
        _importedFiles = [NSMutableSet set];
        _mutablePreludeFiles = [NSMutableSet set];
        _ifStack = [NSMutableArray array];
        _includePaths = @[];
        _libraryPaths = @[];
        _mutableMetadataImports = [NSMutableArray array];
        _metadataImportSet = [NSMutableSet set];
        }
    return self;
    }

- (NSSet<NSString*>*)preludeFiles
    {
    return _mutablePreludeFiles;
    }

- (NSArray<NSString*>*)metadataImports
    {
    return [_mutableMetadataImports copy];
    }

/****************************************************************************\
|* Plain `-[init]` forwards to `initWithDiagnostics:nil`. Without this,
|* callers that construct via `[[XTPreprocessor alloc] init]` inherit
|* `-[NSObject init]`, which leaves every ivar nil — including
|* `_importedFiles`. A nil NSMutableSet silently swallows addObject:
|* and reports containsObject:→NO, so the #import-once machinery is
|* dead and a self-referential include (e.g. a user's `sort.xc` plus
|* `#import "Sort.xc"` on a case-insensitive filesystem) loops until
|* the stack blows. The driver's format-scan pass was one such caller.
\****************************************************************************/
- (instancetype)init
    {
    return [self initWithDiagnostics:nil];
    }

/****************************************************************************\
|* Pre-define a macro from the command line (equivalent to -D name[=value]).
|* @param name   The macro name to define.
|* @param value  The macro body, or nil (defaults to "1").
\****************************************************************************/
- (void)defineMacro:(NSString*)name value:(nullable NSString*)value
    {
    NSString* body = value ?: @"1";
    XTMacroDefinition* def = [[XTMacroDefinition alloc] initWithName:name
                                                          parameters:nil
                                                                body:body];
    _macros[name] = def;
    }

/****************************************************************************\
|* Preprocess a source file and return the expanded text.
|* @param path      Path to the source file to preprocess.
|* @param outError  On failure, receives an NSError describing the problem.
|* @return  The preprocessed source text, or nil on fatal error.
\****************************************************************************/
- (nullable NSString*)preprocessFile:(NSString*)path error:(NSError**)outError
    {
    NSError* readError = nil;
    NSString* source = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:&readError];
    if (!source)
        {
        if (outError)
            *outError = readError;
        return nil;
        }
    return [self preprocessSource:source filename:path];
    }

/****************************************************************************\
|* Strip `//` line comments and `/ * * /` block comments from `src`,
|* preserving line count (block comments are replaced with spaces and
|* internal newlines are kept) so #line directives still line up. The
|* pass is aware of `"..."` string and `'..'` character literals so a
|* `"// not a comment"` string is left untouched.
\****************************************************************************/
- (NSString*)stripComments:(NSString*)src filename:(NSString*)filename
    {
    NSMutableString* out = [NSMutableString stringWithCapacity:src.length];
    NSUInteger i = 0;
    NSUInteger n = src.length;
    BOOL inBlock = NO;
    BOOL inString = NO;
    BOOL inChar = NO;
    // Comments do NOT nest — the FIRST `*/` closes, as in C. Both ways of
    // getting that wrong used to be silent here, and this is the pass that
    // decides: a `/*` inside the comment was blanked like any other text, so
    // the author's intended closer ended the comment early and their remaining
    // prose reached the parser as CODE (the error then points at English); and
    // an unterminated comment simply ran to end-of-input, silently swallowing
    // the rest of the file.
    NSUInteger line = 1, blockOpenLine = 1;
    BOOL warnedNested = NO;
    while (i < n)
        {
        unichar c = [src characterAtIndex:i];
        unichar next = (i + 1 < n) ? [src characterAtIndex:i + 1] : 0;

        if (inBlock)
            {
            if (c == '*' && next == '/')
                {
                [out appendString:@"  "];
                i += 2;
                inBlock = NO;
                }
            else
                {
                if (!warnedNested && c == '/' && next == '*')
                    {
                    // Once per comment: a run of them is one mistake.
                    [_diagnostics emitWarning:@"'/*' within a block comment — comments "
                                              @"do not nest, so the first '*/' ends it"
                                     category:XTWarnComment
                                           at:[XTSourceLocation locationWithFilename:filename
                                                                                line:line
                                                                              column:1]];
                    warnedNested = YES;
                    }
                // Preserve newlines so line numbering is unaffected;
                // replace everything else with a space.
                if (c == '\n')
                    line++;
                [out appendFormat:@"%C", (unichar)((c == '\n') ? c : ' ')];
                i++;
                }
            continue;
            }

        if (inString)
            {
            [out appendFormat:@"%C", c];
            if (c == '\\' && i + 1 < n)
                {
                [out appendFormat:@"%C", next];
                i += 2;
                continue;
                }
            if (c == '"')
                inString = NO;
            i++;
            continue;
            }

        if (inChar)
            {
            [out appendFormat:@"%C", c];
            if (c == '\\' && i + 1 < n)
                {
                [out appendFormat:@"%C", next];
                i += 2;
                continue;
                }
            if (c == '\'')
                inChar = NO;
            i++;
            continue;
            }

        if (c == '/' && next == '/')
            {
            // Line comment — skip to end of line, but keep the newline
            while (i < n && [src characterAtIndex:i] != '\n')
                i++;
            continue;
            }
        if (c == '/' && next == '*')
            {
            inBlock = YES;
            blockOpenLine = line;
            warnedNested = NO;
            [out appendString:@"  "];
            i += 2;
            continue;
            }
        if (c == '"')
            {
            inString = YES;
            [out appendFormat:@"%C", c];
            i++;
            continue;
            }
        if (c == '\'')
            {
            inChar = YES;
            [out appendFormat:@"%C", c];
            i++;
            continue;
            }

        if (c == '\n')
            line++;
        [out appendFormat:@"%C", c];
        i++;
        }
    if (inBlock)
        [_diagnostics emitError:@"unterminated block comment — no closing '*/'"
                             at:[XTSourceLocation locationWithFilename:filename
                                                                  line:blockOpenLine
                                                                column:1]];
    return out;
    }

/****************************************************************************\
|* Preprocess source text (already loaded) with the given filename for
|* diagnostics. Strips comments, joins continuation lines, processes
|* directives, and expands macros.
|* @param source    The raw source text.
|* @param filename  The filename for #line directives and diagnostics.
|* @return  The fully preprocessed source text.
\****************************************************************************/
- (NSString*)preprocessSource:(NSString*)source filename:(NSString*)filename
    {
    // Snapshot the if-stack depth at entry. `preprocessSource:` is
    // re-entrant (handleInclude recursively calls it for #import /
    // #include), and a parent file's open `#if` legitimately spans
    // an included file when the `#import` itself sits inside the
    // conditional (`#if HAS_ATFMT ... #import "Object.xc" ... #endif`).
    // The end-of-source "unterminated #if" check must compare against
    // this entry depth — not zero — so an inactive parent's open frame
    // doesn't get attributed to the included file (which is fully
    // balanced on its own).
    NSUInteger entryIfDepth = _ifStack.count;
    // The top-level file joins the once-only set under the same absolute
    // identity handleInclude uses, so a cycle back to it is a no-op. Depth
    // guards it: included files are already registered by handleInclude,
    // and a plain #include must stay re-includable.
    if (_sourceDepth == 0 && filename.length)
        {
        NSString* absPath = filename.isAbsolutePath ? filename
                                                    : [[[NSFileManager defaultManager] currentDirectoryPath]
                                                          stringByAppendingPathComponent:filename];
        [_importedFiles addObject:[absPath stringByStandardizingPath]];
        }
    _sourceDepth++;
    // Strip C/C++ style comments BEFORE any directive or macro
    // processing, so things like `// #import <Math.xc>` or
    // `/* #define FOO 1 */` actually get commented out instead of
    // being interpreted. The lexer also strips comments later, but
    // by then the preprocessor has already acted on them.
    source = [self stripComments:source filename:filename];

    // Join continuation lines: a trailing '\' merges the next line.
    // Track the original line number for each joined line.
    NSArray<NSString*>* rawLines = [source componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    NSMutableArray<NSNumber*>* lineOrigins = [NSMutableArray array]; // original line number for each entry
    NSMutableString* pending = nil;
    NSUInteger origLine = 0;
    NSUInteger pendingStartLine = 0;
    for (NSString* rawLine in rawLines)
        {
        origLine++;
        NSString* stripped = [rawLine stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
        if ([stripped hasSuffix:@"\\"])
            {
            NSString* withoutSlash = [stripped substringToIndex:stripped.length - 1];
            if (pending)
                {
                [pending appendString:withoutSlash];
                }
            else
                {
                pending = [NSMutableString stringWithString:withoutSlash];
                pendingStartLine = origLine;
                }
            }
        else
            {
            if (pending)
                {
                [pending appendString:rawLine];
                [lines addObject:[pending copy]];
                [lineOrigins addObject:@(pendingStartLine)];
                pending = nil;
                }
            else
                {
                [lines addObject:rawLine];
                [lineOrigins addObject:@(origLine)];
                }
            }
        }
    if (pending)
        {
        [lines addObject:[pending copy]];
        [lineOrigins addObject:@(pendingStartLine)];
        }

    NSMutableString* output = [NSMutableString string];

    // Emit initial #line directive
    [output appendFormat:@"#line 1 \"%@\"\n", filename];
    NSUInteger lastEmittedLine = 1;
    NSString* lastEmittedFile = filename;

    // Implicit platform prelude: import the platform's system-dependent header
    // (e.g. Platform.xc → `#import <user32>`) BEFORE the main source, then reset
    // #line to the main file so the user's line numbers are unaffected.
    if (_platformPrelude.length)
        {
        // Save/restore, not set/clear: preprocessSource is re-entrant and a
        // nested call's prelude block (a once-only no-op) must not clear the
        // flag while the OUTER prelude is still expanding.
        BOOL savedInPrelude = _inPrelude;
        _inPrelude = YES;
        [self processDirective:[NSString stringWithFormat:@"#import \"%@\"", _platformPrelude]
                      filename:filename
                    lineNumber:1
                        output:output];
        _inPrelude = savedInPrelude;
        [output appendFormat:@"#line 1 \"%@\"\n", filename];
        }

    for (NSUInteger i = 0; i < lines.count; i++)
        {
        NSString* rawLine = lines[i];
        NSUInteger thisOrigLine = [lineOrigins[i] unsignedIntegerValue];

        NSString* line = [rawLine stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];

        BOOL currentlyActive = [self conditionalActive];

        if ([line hasPrefix:@"#"])
            {
            // Conditional directives always need to run — they mutate
            // the if-stack and change what counts as "active" from
            // this point on. Everything else is skipped while we're
            // inside a non-active branch.
            BOOL isConditional = [self isConditionalDirective:line];
            if (currentlyActive || isConditional)
                {
                [self processDirective:line
                              filename:filename
                            lineNumber:thisOrigLine
                                output:output];
                }
            else
                {
                [output appendString:@"\n"];
                }
            NSUInteger nextOrigLine = (i + 1 < lineOrigins.count) ? [lineOrigins[i + 1] unsignedIntegerValue] : thisOrigLine + 1;
            [output appendFormat:@"#line %lu \"%@\"\n", (unsigned long)nextOrigLine, filename];
            lastEmittedLine = nextOrigLine;
            lastEmittedFile = filename;
            }
        else if (!currentlyActive)
            {
            // Inside an inactive conditional branch — emit a blank
            // line so downstream line numbering stays consistent.
            [output appendString:@"\n"];
            lastEmittedLine = thisOrigLine + 1;
            }
        else
            {
            // Emit #line if the original line number is out of sync
            if (thisOrigLine != lastEmittedLine || ![lastEmittedFile isEqualToString:filename])
                {
                [output appendFormat:@"#line %lu \"%@\"\n", (unsigned long)thisOrigLine, filename];
                lastEmittedFile = filename;
                }
            // Expand macros in the line
            NSString* expanded = [self expandMacrosInText:rawLine
                                                 filename:filename
                                               lineNumber:thisOrigLine];
            [output appendString:expanded];
            [output appendString:@"\n"];
            lastEmittedLine = thisOrigLine + 1;
            }
        }
    if (_ifStack.count > entryIfDepth)
        {
        [_diagnostics emitError:@"unterminated #if / #ifdef block"
                             at:[XTSourceLocation locationWithFilename:filename line:lines.count column:1]];
        }
    _sourceDepth--;
    return output;
    }

/****************************************************************************\
|* True when lines at the current point in the file should be emitted:
|* outside any #if, or inside one whose top frame is active.
\****************************************************************************/
- (BOOL)conditionalActive
    {
    if (_ifStack.count == 0)
        return YES;
    return _ifStack.lastObject.active;
    }

/****************************************************************************\
|* True if `line` starts with any of #if / #ifdef / #ifndef / #elif /
|* #else / #endif. These directives are always processed — the rest
|* get skipped while we're inside a non-active branch.
\****************************************************************************/
- (BOOL)isConditionalDirective:(NSString*)line
    {
    NSString* body = [[line substringFromIndex:1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([body isEqualToString:@"else"] || [body isEqualToString:@"endif"])
        return YES;
    static NSArray<NSString*>* prefixes = nil;
    if (!prefixes)
        prefixes = @[ @"if ", @"if(", @"ifdef ", @"ifndef ",
                      @"elif ", @"elif(", @"else ", @"endif " ];
    for (NSString* p in prefixes)
        {
        if ([body hasPrefix:p])
            return YES;
        }
    // Edge cases: `#if` with nothing after (invalid but still a
    // conditional); `#ifdef` / `#ifndef` with no name.
    if ([body isEqualToString:@"if"] || [body isEqualToString:@"ifdef"] ||
        [body isEqualToString:@"ifndef"] || [body isEqualToString:@"elif"])
        return YES;
    return NO;
    }

#pragma mark - Conditional Compilation

- (BOOL)isIdentChar:(unichar)c
    {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '_';
    }

- (void)pushIfWithCondition:(BOOL)cond location:(XTSourceLocation*)loc
    {
    BOOL parentActive = (_ifStack.count == 0) ? YES : _ifStack.lastObject.active;
    XTIfFrame* f = [[XTIfFrame alloc] init];
    f.parentActive = parentActive;
    f.active = parentActive && cond;
    f.taken = f.active;
    [_ifStack addObject:f];
    }

- (void)applyElifWithExpr:(NSString*)expr location:(XTSourceLocation*)loc
    {
    if (_ifStack.count == 0)
        {
        [_diagnostics emitError:@"#elif without matching #if" at:loc];
        return;
        }
    XTIfFrame* f = _ifStack.lastObject;
    if (!f.parentActive || f.taken)
        {
        f.active = NO;
        return;
        }
    int64_t v = [self evaluateIfExpression:expr location:loc];
    f.active = (v != 0);
    f.taken = f.active;
    }

- (void)applyElseAtLocation:(XTSourceLocation*)loc
    {
    if (_ifStack.count == 0)
        {
        [_diagnostics emitError:@"#else without matching #if" at:loc];
        return;
        }
    XTIfFrame* f = _ifStack.lastObject;
    if (!f.parentActive || f.taken)
        {
        f.active = NO;
        return;
        }
    f.active = YES;
    f.taken = YES;
    }

/****************************************************************************\
|* Evaluate a `#if` / `#elif` condition. Expands macros in the text
|* (except the immediate argument of `defined`), then runs a mini
|* integer expression parser. Returns 0 on syntax error and emits
|* a diagnostic — that maps to "branch not taken" which is the
|* safest behaviour when a condition is malformed.
|*
|* Supported grammar (C-like precedence):
|*   primary    ::= integer | `(` expr `)` | `defined` NAME
|*                | `defined(` NAME `)` | identifier (→ macro value or 0)
|*   unary      ::= `!` unary | `-` unary | `+` unary | `~` unary | primary
|*   *, /, %    | +, -  | <<, >>  | <, >, <=, >=  | ==, !=
|*   &  | ^  | |  | &&  | ||
\****************************************************************************/
- (int64_t)evaluateIfExpression:(NSString*)expr location:(XTSourceLocation*)loc
    {
    // Process `defined` first (before macro expansion), so its
    // argument isn't substituted away.
    NSString* e = [self resolveDefinedIn:expr];
    // Expand remaining identifiers. Any identifier that isn't a
    // macro name resolves to 0, per C preprocessor semantics.
    e = [self expandMacrosInText:e filename:loc.filename lineNumber:loc.line];
    e = [self substituteUndefinedIdentifiersIn:e];

    const char* cstr = e.UTF8String;
    NSUInteger len = strlen(cstr);
    NSUInteger pos = 0;
    int64_t v = [self parseExprC:cstr len:len pos:&pos location:loc];
    // Skip trailing whitespace.
    while (pos < len && (cstr[pos] == ' ' || cstr[pos] == '\t'))
        pos++;
    if (pos < len)
        {
        [_diagnostics emitError:[NSString stringWithFormat:@"trailing tokens in #if expression: '%s'", cstr + pos]
                             at:loc];
        }
    return v;
    }

/****************************************************************************\
|* Replace every `defined X` and `defined(X)` in the text with `0` or
|* `1` before macro expansion.
\****************************************************************************/
- (NSString*)resolveDefinedIn:(NSString*)expr
    {
    NSMutableString* out = [NSMutableString string];
    NSUInteger i = 0;
    NSUInteger len = expr.length;
    while (i < len)
        {
        unichar c = [expr characterAtIndex:i];
        if (c == 'd' && i + 7 <= len &&
            [[expr substringWithRange:NSMakeRange(i, 7)] isEqualToString:@"defined"] &&
            (i == 0 || ![self isIdentChar:[expr characterAtIndex:i - 1]]) &&
            (i + 7 >= len || ![self isIdentChar:[expr characterAtIndex:i + 7]]))
            {
            i += 7;
            while (i < len && ([expr characterAtIndex:i] == ' ' || [expr characterAtIndex:i] == '\t'))
                i++;
            BOOL paren = (i < len && [expr characterAtIndex:i] == '(');
            if (paren)
                {
                i++;
                while (i < len && ([expr characterAtIndex:i] == ' ' || [expr characterAtIndex:i] == '\t'))
                    i++;
                }
            NSMutableString* name = [NSMutableString string];
            while (i < len && [self isIdentChar:[expr characterAtIndex:i]])
                {
                [name appendFormat:@"%C", [expr characterAtIndex:i]];
                i++;
                }
            if (paren)
                {
                while (i < len && ([expr characterAtIndex:i] == ' ' || [expr characterAtIndex:i] == '\t'))
                    i++;
                if (i < len && [expr characterAtIndex:i] == ')')
                    i++;
                }
            [out appendString:(_macros[name] ? @"1" : @"0")];
            continue;
            }
        [out appendFormat:@"%C", c];
        i++;
        }
    return out;
    }

/****************************************************************************\
|* Replace any remaining identifier in `expr` with `0`. Called after
|* macro expansion — anything still symbolic must be an undefined
|* name, which C treats as 0 in a #if.
\****************************************************************************/
- (NSString*)substituteUndefinedIdentifiersIn:(NSString*)expr
    {
    NSMutableString* out = [NSMutableString string];
    NSUInteger i = 0;
    NSUInteger len = expr.length;
    while (i < len)
        {
        unichar c = [expr characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_')
            {
            while (i < len && [self isIdentChar:[expr characterAtIndex:i]])
                i++;
            [out appendString:@"0"];
            }
        else
            {
            [out appendFormat:@"%C", c];
            i++;
            }
        }
    return out;
    }

// Recursive-descent expression parser. Each level handles its
// own precedence and delegates to the next. Whitespace is skipped
// at the start of each level.
- (void)skipSpaces:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)posPtr
    {
    while (*posPtr < len && (s[*posPtr] == ' ' || s[*posPtr] == '\t'))
        (*posPtr)++;
    }

- (int64_t)parseExprC:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseLogicalAnd:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp + 1 < len && s[*pp] == '|' && s[*pp + 1] == '|')
        {
        *pp += 2;
        int64_t b = [self parseLogicalAnd:s len:len pos:pp location:loc];
        a = (a || b) ? 1 : 0;
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseLogicalAnd:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseBitOr:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp + 1 < len && s[*pp] == '&' && s[*pp + 1] == '&')
        {
        *pp += 2;
        int64_t b = [self parseBitOr:s len:len pos:pp location:loc];
        a = (a && b) ? 1 : 0;
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseBitOr:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseBitXor:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp < len && s[*pp] == '|' && (*pp + 1 >= len || s[*pp + 1] != '|'))
        {
        (*pp)++;
        int64_t b = [self parseBitXor:s len:len pos:pp location:loc];
        a |= b;
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseBitXor:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseBitAnd:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp < len && s[*pp] == '^')
        {
        (*pp)++;
        int64_t b = [self parseBitAnd:s len:len pos:pp location:loc];
        a ^= b;
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseBitAnd:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseEquality:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp < len && s[*pp] == '&' && (*pp + 1 >= len || s[*pp + 1] != '&'))
        {
        (*pp)++;
        int64_t b = [self parseEquality:s len:len pos:pp location:loc];
        a &= b;
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseEquality:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseRelational:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp + 1 < len && (s[*pp] == '=' || s[*pp] == '!') && s[*pp + 1] == '=')
        {
        char op = s[*pp];
        *pp += 2;
        int64_t b = [self parseRelational:s len:len pos:pp location:loc];
        a = (op == '=') ? (a == b ? 1 : 0) : (a != b ? 1 : 0);
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseRelational:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseShift:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp < len && (s[*pp] == '<' || s[*pp] == '>'))
        {
        char op = s[*pp];
        BOOL eq = (*pp + 1 < len && s[*pp + 1] == '=');
        // `<<` / `>>` are shift operators — don't consume them here.
        if (*pp + 1 < len && s[*pp + 1] == op)
            break;
        (*pp)++;
        if (eq)
            (*pp)++;
        int64_t b = [self parseShift:s len:len pos:pp location:loc];
        if (op == '<')
            a = eq ? (a <= b ? 1 : 0) : (a < b ? 1 : 0);
        else
            a = eq ? (a >= b ? 1 : 0) : (a > b ? 1 : 0);
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseShift:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseAdditive:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp + 1 < len && (s[*pp] == '<' || s[*pp] == '>') && s[*pp + 1] == s[*pp])
        {
        char op = s[*pp];
        *pp += 2;
        int64_t b = [self parseAdditive:s len:len pos:pp location:loc];
        a = (op == '<') ? (a << b) : (a >> b);
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseAdditive:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseMultiplicative:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp < len && (s[*pp] == '+' || s[*pp] == '-'))
        {
        char op = s[*pp];
        (*pp)++;
        int64_t b = [self parseMultiplicative:s len:len pos:pp location:loc];
        a = (op == '+') ? (a + b) : (a - b);
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseMultiplicative:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    int64_t a = [self parseUnary:s len:len pos:pp location:loc];
    [self skipSpaces:s len:len pos:pp];
    while (*pp < len && (s[*pp] == '*' || s[*pp] == '/' || s[*pp] == '%'))
        {
        char op = s[*pp];
        (*pp)++;
        int64_t b = [self parseUnary:s len:len pos:pp location:loc];
        if ((op == '/' || op == '%') && b == 0)
            {
            [_diagnostics emitError:@"division by zero in #if expression" at:loc];
            a = 0;
            }
        else if (op == '*')
            a *= b;
        else if (op == '/')
            a /= b;
        else
            a %= b;
        [self skipSpaces:s len:len pos:pp];
        }
    return a;
    }

- (int64_t)parseUnary:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    [self skipSpaces:s len:len pos:pp];
    if (*pp < len)
        {
        char c = s[*pp];
        if (c == '!')
            {
            (*pp)++;
            int64_t v = [self parseUnary:s len:len pos:pp location:loc];
            return v ? 0 : 1;
            }
        if (c == '-')
            {
            (*pp)++;
            return -[self parseUnary:s len:len pos:pp location:loc];
            }
        if (c == '+')
            {
            (*pp)++;
            return [self parseUnary:s len:len pos:pp location:loc];
            }
        if (c == '~')
            {
            (*pp)++;
            return ~[self parseUnary:s len:len pos:pp location:loc];
            }
        }
    return [self parsePrimary:s len:len pos:pp location:loc];
    }

- (int64_t)parsePrimary:(const char*)s len:(NSUInteger)len pos:(NSUInteger*)pp location:(XTSourceLocation*)loc
    {
    [self skipSpaces:s len:len pos:pp];
    if (*pp >= len)
        {
        [_diagnostics emitError:@"unexpected end of #if expression" at:loc];
        return 0;
        }
    char c = s[*pp];
    if (c == '(')
        {
        (*pp)++;
        int64_t v = [self parseExprC:s len:len pos:pp location:loc];
        [self skipSpaces:s len:len pos:pp];
        if (*pp < len && s[*pp] == ')')
            (*pp)++;
        else
            [_diagnostics emitError:@"missing ')' in #if expression" at:loc];
        return v;
        }
    if (c >= '0' && c <= '9')
        {
        int64_t v = 0;
        int base = 10;
        if (c == '0' && *pp + 1 < len && (s[*pp + 1] == 'x' || s[*pp + 1] == 'X'))
            {
            base = 16;
            *pp += 2;
            }
        while (*pp < len)
            {
            char d = s[*pp];
            int digit;
            if (d >= '0' && d <= '9')
                digit = d - '0';
            else if (base == 16 && d >= 'A' && d <= 'F')
                digit = 10 + (d - 'A');
            else if (base == 16 && d >= 'a' && d <= 'f')
                digit = 10 + (d - 'a');
            else
                break;
            v = v * base + digit;
            (*pp)++;
            }
        return v;
        }
    if (c == '$')
        {
        // $hex — xtc-style hex literal.
        (*pp)++;
        int64_t v = 0;
        while (*pp < len)
            {
            char d = s[*pp];
            int digit;
            if (d >= '0' && d <= '9')
                digit = d - '0';
            else if (d >= 'A' && d <= 'F')
                digit = 10 + (d - 'A');
            else if (d >= 'a' && d <= 'f')
                digit = 10 + (d - 'a');
            else
                break;
            v = v * 16 + digit;
            (*pp)++;
            }
        return v;
        }
    // Any leftover identifier was already replaced with 0 by
    // substituteUndefinedIdentifiersIn:, so reaching here with a
    // letter means a lexing glitch.
    [_diagnostics emitError:[NSString stringWithFormat:@"unexpected character '%c' in #if expression", c]
                         at:loc];
    (*pp)++;
    return 0;
    }

#pragma mark - Directive Handling

/****************************************************************************\
|* Process a single preprocessor directive line (e.g. #include, #define).
|* @param line        The directive line (starting with #).
|* @param filename    The current source filename for diagnostics.
|* @param lineNumber  The 1-based line number in the source file.
|* @param output      The mutable output string to append expanded content to.
\****************************************************************************/
- (void)processDirective:(NSString*)line
                filename:(NSString*)filename
              lineNumber:(NSUInteger)lineNumber
                  output:(NSMutableString*)output
    {
    XTSourceLocation* loc = [XTSourceLocation locationWithFilename:filename
                                                              line:lineNumber
                                                            column:1];

    // Strip leading # and whitespace
    NSString* content = [[line substringFromIndex:1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([content hasPrefix:@"import"])
        {
        [self handleInclude:content location:loc output:output onceOnly:YES];
        }
    else if ([content hasPrefix:@"include"])
        {
        [self handleInclude:content location:loc output:output onceOnly:NO];
        }
    else if ([content hasPrefix:@"use"] &&
             (content.length == 3 ||
              [self isIdentChar:[content characterAtIndex:3]] == NO))
        {
        // `#use Klass` is sugar for `#import <Klass>` followed by
        // `use Klass;` — imports the class (SOURCE `Klass.xc` or a
        // BINARY `libKlass` with a `.xtc.iface`, whichever the resolver
        // finds; the `use` promotion works identically either way, since
        // it binds by class name from the type table) and promotes its
        // static methods into the bare-call lookup space. Standalone
        // `use Klass;` (no leading `#`) only does the promotion; it's the
        // right form for a class already imported elsewhere.
        NSString* rest = [[content substringFromIndex:3]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        // Remember the bracket form (angle = system/library search order,
        // quote/bare = current-source-first) so the synthesised #import
        // preserves the user's intent, then reduce to the bare class name.
        BOOL wasAngle = ([rest hasPrefix:@"<"] && [rest hasSuffix:@">"]);
        if (([rest hasPrefix:@"\""] && [rest hasSuffix:@"\""]) || wasAngle)
            {
            rest = [rest substringWithRange:NSMakeRange(1, rest.length - 2)];
            }
        if ([rest hasSuffix:@".xc"] || [rest hasSuffix:@".xt"])
            {
            rest = [rest substringToIndex:rest.length - 3];
            }
        if (rest.length == 0)
            {
            [_diagnostics emitError:@"#use requires a class name" at:loc];
            return;
            }
        // Issue the equivalent #import. The bare name lets handleInclude
        // resolve source (`Klass.xc`) or binary (`libKlass`) per what it
        // finds; the bracket form is preserved for search order.
        NSString* synthImport = wasAngle
                                    ? [NSString stringWithFormat:@"import <%@>", rest]
                                    : [NSString stringWithFormat:@"import \"%@\"", rest];
        [self handleInclude:synthImport
                   location:loc
                     output:output
                   onceOnly:YES];
        // Then emit the `use Klass;` line so the parser sees the
        // promotion. The trailing newline preserves the
        // line-numbering invariants the rest of the preprocessor
        // depends on (the synthetic line consumes one input line).
        [output appendFormat:@"use %@;\n", rest];
        }
    else if ([content hasPrefix:@"package"] &&
             (content.length == 7 ||
              [self isIdentChar:[content characterAtIndex:7]] == NO))
        {
        // `#package <env>` — the host import namespace for subsequent
        // bodyless (imported) declarations (wasm-target.md §6). A STATE
        // directive like #pragma pack: it holds until changed, and
        // handleInclude saves/restores it across file boundaries. It
        // performs NO lookup — nothing to silently degrade — and it is a
        // HARD ERROR on targets with no notion of a host package (it only
        // ever appears in per-platform files, so portable source cannot
        // trip it, and a silent no-op costs a day later).
        if (![_targetArchName isEqualToString:@"wasm32"])
            {
            [_diagnostics emitError:@"#package names a host import namespace, "
                                    @"which this target does not have (wasm32 only)"
                                 at:loc];
            return;
            }
        NSString* rest = [[content substringFromIndex:7]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        if (([rest hasPrefix:@"<"] && [rest hasSuffix:@">"]) ||
            ([rest hasPrefix:@"\""] && [rest hasSuffix:@"\""]))
            {
            rest = [rest substringWithRange:NSMakeRange(1, rest.length - 2)];
            }
        if (rest.length == 0)
            {
            [_diagnostics emitError:@"#package requires a namespace name" at:loc];
            return;
            }
        _currentPackage = rest;
        // The parser-level state line; consumes the directive's input line,
        // preserving the line-numbering invariants (the #use pattern).
        [output appendFormat:@"package %@;\n", rest];
        }
    else if ([content hasPrefix:@"define"])
        {
        [self handleDefine:content location:loc];
        }
    else if ([content hasPrefix:@"undef"])
        {
        [self handleUndef:content location:loc];
        }
    else if ([content hasPrefix:@"warning"])
        {
        NSString* msg = [[content substringFromIndex:7]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [_diagnostics emitWarning:(msg.length ? msg : @"#warning") at:loc];
        }
    else if ([content hasPrefix:@"error"])
        {
        NSString* msg = [[content substringFromIndex:5]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [_diagnostics emitError:(msg.length ? msg : @"#error") at:loc];
        }
    else if ([content hasPrefix:@"ifdef"] && (content.length == 5 || ![self isIdentChar:[content characterAtIndex:5]]))
        {
        NSString* rest = [[content substringFromIndex:5]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [self pushIfWithCondition:(_macros[rest] != nil) location:loc];
        [output appendString:@"\n"];
        }
    else if ([content hasPrefix:@"ifndef"] && (content.length == 6 || ![self isIdentChar:[content characterAtIndex:6]]))
        {
        NSString* rest = [[content substringFromIndex:6]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [self pushIfWithCondition:(_macros[rest] == nil) location:loc];
        [output appendString:@"\n"];
        }
    else if ([content hasPrefix:@"if"] && (content.length == 2 || ![self isIdentChar:[content characterAtIndex:2]]))
        {
        NSString* expr = [[content substringFromIndex:2]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        int64_t v = [self evaluateIfExpression:expr location:loc];
        [self pushIfWithCondition:(v != 0) location:loc];
        [output appendString:@"\n"];
        }
    else if ([content hasPrefix:@"elif"] && (content.length == 4 || ![self isIdentChar:[content characterAtIndex:4]]))
        {
        NSString* expr = [[content substringFromIndex:4]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [self applyElifWithExpr:expr location:loc];
        [output appendString:@"\n"];
        }
    else if ([content isEqualToString:@"else"] || [content hasPrefix:@"else "])
        {
        [self applyElseAtLocation:loc];
        [output appendString:@"\n"];
        }
    else if ([content isEqualToString:@"endif"] || [content hasPrefix:@"endif "])
        {
        if (_ifStack.count == 0)
            {
            [_diagnostics emitError:@"#endif without matching #if" at:loc];
            }
        else
            {
            [_ifStack removeLastObject];
            }
        [output appendString:@"\n"];
        }
    else
        {
        [_diagnostics emitWarning:[NSString stringWithFormat:@"Unknown preprocessor directive: #%@", content]
                         category:XTWarnUnknownPragma
                               at:loc];
        [output appendString:@"\n"];
        }
    }

/****************************************************************************\
|* Case-sensitive existence check for a file path. Reads the parent
|* directory and looks for an entry whose name matches the
|* last-path-component byte-for-byte. Necessary on macOS because
|* HFS+/APFS are case-preserving-but-insensitive — a plain
|* `fileExistsAtPath:@"/foo/Sort.xc"` returns YES even when the file
|* is actually named `/foo/sort.xc`.
\****************************************************************************/
static BOOL fileExistsCaseSensitive(NSFileManager* fm, NSString* path)
    {
    NSString* parent = [path stringByDeletingLastPathComponent];
    NSString* name = [path lastPathComponent];
    if (parent.length == 0 || name.length == 0)
        return NO;
    NSError* err = nil;
    NSArray<NSString*>* entries =
        [fm contentsOfDirectoryAtPath:parent
                                error:&err];
    if (!entries)
        return NO;
    for (NSString* entry in entries)
        {
        if ([entry isEqualToString:name])
            return YES;
        }
    return NO;
    }

/****************************************************************************\
|* Probe an ordered list of directories for the first existing library
|* candidate (case-sensitive). Returns the found path, or nil.
\****************************************************************************/
- (nullable NSString*)probeLibDirs:(NSArray<NSString*>*)dirs
                        candidates:(NSArray<NSString*>*)candidates
                                fm:(NSFileManager*)fm
    {
    for (NSString* dir in dirs)
        {
        for (NSString* cand in candidates)
            {
            NSString* p = [dir stringByAppendingPathComponent:cand];
            if (fileExistsCaseSensitive(fm, p))
                return p;
            }
        }
    return nil;
    }

/****************************************************************************\
|* Handle a #include or #import directive. Searches include paths,
|* reads the file, and recursively preprocesses it into the output.
|* @param content   The directive content after the leading #.
|* @param loc       The source location of the directive.
|* @param output    The mutable output string to append included content to.
|* @param onceOnly  YES for #import (include-once semantics), NO for #include.
\****************************************************************************/
- (void)handleInclude:(NSString*)content
             location:(XTSourceLocation*)loc
               output:(NSMutableString*)output
             onceOnly:(BOOL)onceOnly
    {
    // Strip the directive keyword ("include" or "import") to get the filename part
    NSString* rest = content;
    if ([rest hasPrefix:@"import"])
        {
        rest = [rest substringFromIndex:6];
        }
    else if ([rest hasPrefix:@"include"])
        {
        rest = [rest substringFromIndex:7];
        }
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // Quote form chooses the search order (classic C semantics):
    //   "file" — look next to the current source first, then the
    //            system / -I directories.
    //   <file> — system / -I directories only; the current source's
    //            directory is NOT searched. This is the right form
    //            for library headers when you don't want a file in
    //            the caller's project to accidentally shadow the
    //            library's version.
    NSString* filename = nil;
    BOOL isSystemForm = NO;
    if ([rest hasPrefix:@"<"] && [rest hasSuffix:@">"])
        {
        filename = [rest substringWithRange:NSMakeRange(1, rest.length - 2)];
        isSystemForm = YES;
        }
    else if ([rest hasPrefix:@"\""] && [rest hasSuffix:@"\""])
        {
        filename = [rest substringWithRange:NSMakeRange(1, rest.length - 2)];
        }
    else
        {
        [_diagnostics emitError:@"Malformed #include/#import directive" at:loc];
        return;
        }

    // Build the search-path list per quote form. On cloaking-capable
    // targets each path's `cloaked/` subdir is preferred — a library
    // author can drop `support/<plat>/lib/cloaked/Stdio.xc` next to
    // the canonical `Stdio.xc` and the xe build picks the variant
    // automatically. Non-cloaked targets just walk the root files.
    NSString* foundPath = nil;
    NSMutableArray<NSString*>* searchPaths = [NSMutableArray array];
    if (!isSystemForm)
        {
        NSString* currentDir = [loc.filename stringByDeletingLastPathComponent];
        // …EXCEPT when the importing file is itself a library file — one that
        // already lives in a search directory. Then its own directory gets no
        // head start, and the import resolves through the normal library order:
        // the PLATFORM's lib dir first, then generic.
        //
        // That distinction is what lets one library serve every target. The
        // Foundation containers exist twice — a 32-bit `generic/lib` build and
        // an 8/16-bit `xt6502/lib` one — while everything with no width in it
        // (Object, Comparable, Sort, the Foundation umbrella) exists ONCE, in
        // generic/lib. With same-directory-first, generic/lib/Object.xc's
        // `#import "String.xc"` would resolve to its own neighbour — generic's
        // 32-bit String — even in a 6502 build, dragging a second definition of
        // String and Hashable in alongside the platform's own. Two definitions
        // of one class, and the lowering falls over.
        //
        // Resolving library imports through the search order instead means
        // Object.xc picks up whichever String the TARGET provides, so only the
        // files that genuinely differ per platform need duplicating.
        //
        // A user's own source is unaffected: its directory is not a search
        // path, so it still gets the classic sibling-first behaviour.
        BOOL currentIsLibraryDir = NO;
        NSString* curStd = [currentDir stringByStandardizingPath];
        for (NSString* dir in _includePaths)
            {
            if ([[dir stringByStandardizingPath] isEqualToString:curStd])
                {
                currentIsLibraryDir = YES;
                break;
                }
            }
        if (!currentIsLibraryDir)
            [searchPaths addObject:currentDir];
        }
    [searchPaths addObjectsFromArray:_includePaths];

    // Case-sensitive existence test. NSFileManager fileExistsAtPath:
    // delegates to the filesystem, which on macOS HFS+/APFS is
    // case-preserving but case-insensitive — so `#import "Sort.xc"`
    // would happily match a sibling file literally named `sort.xc`
    // and load that instead (classic collision: user writes
    // `sort.xc` in their project, the preprocessor silently
    // imports their own source as the "Sort library"). Listing the
    // directory and checking for an exact-case entry forces the
    // filename to match byte-for-byte.
    NSFileManager* fm = [NSFileManager defaultManager];
    // A bare module name (no extension) also tries `<name>.xc`, so `#import <X>`
    // (and `#use X`) resolve a source class X.xc as well as a binary libX — the
    // bracket still only chose search order; source-vs-binary is by what's found.
    //
    // `.xt` is the OLD extension, and it is still honoured two ways: a bare
    // name falls back to `<name>.xt`, and an explicit `#import "Stdio.xt"`
    // that does not exist retries as `Stdio.xc`. The second one is what
    // actually matters — an unconverted tree (../atari, anyone's existing
    // sources) names the LIBRARY files it imports, and those have been
    // renamed underneath it. Drop both once nothing depends on them.
    BOOL bareName = ([filename rangeOfString:@"."].location == NSNotFound);
    NSString* renamed = [filename hasSuffix:@".xt"]
                            ? [[filename substringToIndex:filename.length - 3] stringByAppendingString:@".xc"]
                            : nil;
    for (NSString* dir in searchPaths)
        {
        NSString* candidate = [dir stringByAppendingPathComponent:filename];
        if (fileExistsCaseSensitive(fm, candidate))
            {
            foundPath = candidate;
            break;
            }
        if (renamed)
            {
            NSString* rc = [dir stringByAppendingPathComponent:renamed];
            if (fileExistsCaseSensitive(fm, rc))
                {
                foundPath = rc;
                break;
                }
            }
        if (bareName)
            {
            NSString* xcCandidate = [candidate stringByAppendingPathExtension:@"xc"];
            if (fileExistsCaseSensitive(fm, xcCandidate))
                {
                foundPath = xcCandidate;
                break;
                }
            NSString* xtCandidate = [candidate stringByAppendingPathExtension:@"xt"];
            if (fileExistsCaseSensitive(fm, xtCandidate))
                {
                foundPath = xtCandidate;
                break;
                }
            }
        }

    // Not a source file — try a shared-library metadata import. Per the
    // library-imports design, the bracket only chose system-vs-local; the
    // dispatch (library vs source module) is by what the resolver FINDS.
    // `<GEM>` → `libGEM.so` (the -lGEM convention: lib prefix + .so suffix,
    // stem verbatim). A hit is recorded — not textually included — and the
    // driver reads its `.dynsym` ∩ DWARF to synthesise typed declarations.
    if (!foundPath && (_libraryPaths.count > 0 || _thirdPartyRoots.count > 0))
        {
        // Target-preferred order (`.dylib` first on a macOS host, `.so` on
        // Linux) so a stale sibling of the wrong object format never wins.
        NSArray<NSString*>* exts = _sharedLibExtensions.count
                                       ? _sharedLibExtensions
                                       : @[ @"so", @"dylib" ];
        // `<vendor/X>` is the QUALIFIED third-party form: it names the vendor
        // directly and skips the -L tiers entirely — its job is disambiguating
        // a bare name two vendors both provide. Only meaningful once the
        // source probe above has failed, so `<sub/File.xc>`-style source
        // imports are unaffected.
        NSString* libStem = filename;
        NSString* vendorQual = nil;
        NSRange slash = [filename rangeOfString:@"/"];
        if (isSystemForm && slash.location != NSNotFound && _thirdPartyRoots.count > 0)
            {
            vendorQual = [filename substringToIndex:slash.location];
            libStem = [filename substringFromIndex:slash.location + 1];
            }
        NSMutableArray<NSString*>* libCandidates = [NSMutableArray array];
        for (NSString* ext in exts)
            [libCandidates addObject:[NSString stringWithFormat:@"lib%@.%@", libStem, ext]];
        [libCandidates addObject:libStem]; // already a lib name?
        // A BARE interface, as `xcc -c` leaves beside its object. Same role as
        // the `.xtc.iface` section inside a built library — it is the module's
        // header — so `#import <ShapeMod>` finds ShapeMod.xtc.iface on a -L path
        // and type-checks against it without the module's source or a .so.
        // Listed LAST so a real library still wins when both exist.
        // private:docs/Design/separate-compilation.md stage 3.
        [libCandidates addObject:[NSString stringWithFormat:@"%@.xtc.iface", libStem]];

        // Probe tiers: explicit -L dirs, then the third-party tree, then the
        // appended defaults (the vendored sysroot) — so an explicit -L wins
        // over /opt/xcc/3p, and 3p wins over a possibly-stale sysroot copy.
        NSUInteger nExplicit = MIN(_explicitLibraryPathCount, _libraryPaths.count);
        NSString* hit = vendorQual ? nil
                                   : [self probeLibDirs:[_libraryPaths subarrayWithRange:
                                                                           NSMakeRange(0, nExplicit)]
                                             candidates:libCandidates
                                                     fm:fm];
        NSString* vendorXcDir = nil;
        if (!hit && _thirdPartyRoots.count > 0 && _targetArchName.length)
            {
            // One vendor = one subtree: <root>/<vendor>/<arch>/lib<X>.so, with
            // the arch-NEUTRAL contract sources once at <vendor>/xc/. A bare
            // name matching MORE THAN ONE vendor is a hard error naming the
            // candidates — never an ordering accident.
            NSMutableArray<NSString*>* hits = [NSMutableArray array];
            NSMutableArray<NSString*>* hitVendors = [NSMutableArray array];
            for (NSString* root in _thirdPartyRoots)
                {
                NSArray<NSString*>* vendors = vendorQual ? @[ vendorQual ]
                                                         : ([fm contentsOfDirectoryAtPath:root error:NULL] ?: @[]);
                for (NSString* vendor in vendors)
                    {
                    NSString* archDir = [[root stringByAppendingPathComponent:vendor]
                        stringByAppendingPathComponent:_targetArchName];
                    NSString* p = [self probeLibDirs:@[ archDir ]
                                          candidates:libCandidates
                                                  fm:fm];
                    if (p)
                        {
                        [hits addObject:p];
                        [hitVendors addObject:vendor];
                        }
                    }
                }
            if (hits.count > 1)
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"'%@' matches a library from more than one third-party vendor "
                                                      @"(%@) — qualify it, e.g. #import <%@/%@>",
                                                      libStem, [hitVendors componentsJoinedByString:@", "],
                                                      hitVendors.firstObject, libStem]
                                     at:loc];
                return;
                }
            if (hits.count == 1)
                {
                hit = hits.firstObject;
                // The vendor's contract sources join the QUOTED-import path
                // for the rest of the TRANSLATION UNIT — appended after every
                // existing search dir, so they can never shadow the standard
                // library, and TU-wide so a contract file's own quoted
                // imports (XGAbi.xc's `#import "XGVersion.xc"`) resolve too.
                NSString* xc = [[[hit stringByDeletingLastPathComponent] // <arch>
                    stringByDeletingLastPathComponent]                   // <vendor>
                    stringByAppendingPathComponent:@"xc"];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:xc isDirectory:&isDir] && isDir)
                    vendorXcDir = xc;
                }
            }
        if (!hit && !vendorQual && _libraryPaths.count > nExplicit)
            {
            hit = [self probeLibDirs:[_libraryPaths subarrayWithRange:
                                                        NSMakeRange(nExplicit, _libraryPaths.count - nExplicit)]
                          candidates:libCandidates
                                  fm:fm];
            }
        if (hit)
            {
            NSString* abs = [hit stringByStandardizingPath];
            // #import is once-only
            if (![_metadataImportSet containsObject:abs])
                {
                [_metadataImportSet addObject:abs];
                [_mutableMetadataImports addObject:abs];
                }
            if (vendorXcDir && ![_includePaths containsObject:vendorXcDir])
                self.includePaths = [_includePaths arrayByAddingObject:vendorXcDir];
            return; // metadata import: emit no text into the stream
            }
        if (vendorQual)
            {
            [_diagnostics emitError:[NSString stringWithFormat:
                                                  @"no third-party library '%@' from vendor '%@' for this target "
                                                  @"(looked for <3p>/%@/%@/lib%@.*)",
                                                  libStem, vendorQual, vendorQual, _targetArchName ?: @"?", libStem]
                                 at:loc];
            return;
            }
        }

    if (!foundPath)
        {
        // List every directory that was tried, so the failure is
        // self-diagnosing — debugging a missing include on a fresh
        // install or an alien platform (e.g. Windows with quoted
        // XTC_HOME) is otherwise pure guesswork. Empty path lists
        // mean the driver didn't pass any include dirs in, which
        // is itself the bug to fix.
        NSMutableString* detail = [NSMutableString string];
        if (searchPaths.count == 0)
            {
            [detail appendString:@" (no include directories configured — "
                                 @"check XTC_HOME / -H / -I)"];
            }
        else
            {
            [detail appendString:@" (searched: "];
            for (NSUInteger pi = 0; pi < searchPaths.count; pi++)
                {
                if (pi > 0)
                    [detail appendString:@", "];
                [detail appendFormat:@"'%@'", searchPaths[pi]];
                }
            [detail appendString:@")"];
            }
        [_diagnostics emitError:[NSString stringWithFormat:@"Cannot find include file '%@'%@", filename, detail]
                             at:loc];
        return;
        }

    // Resolve to absolute path for reliable duplicate detection.
    // stringByStandardizingPath leaves a RELATIVE path relative, and the
    // top-level file (registered in preprocessFile:) may arrive either way —
    // anchor both sides at the cwd so the cycle check compares one identity.
    NSString* absPath = foundPath.isAbsolutePath ? foundPath
                                                 : [[[NSFileManager defaultManager] currentDirectoryPath]
                                                       stringByAppendingPathComponent:foundPath];
    absPath = [absPath stringByStandardizingPath];

    // For #import: skip if already imported
    if (onceOnly && [_importedFiles containsObject:absPath])
        {
        return;
        }
    if (onceOnly)
        {
        [_importedFiles addObject:absPath];
        }
    if (_inPrelude)
        [_mutablePreludeFiles addObject:absPath];

    NSError* err = nil;
    NSString* includedSource = [NSString stringWithContentsOfFile:foundPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:&err];
    if (!includedSource)
        {
        [_diagnostics emitError:[NSString stringWithFormat:@"Cannot read include file '%@'", foundPath]
                             at:loc];
        return;
        }

    // Register the included source with the diagnostic engine for error display
    [_diagnostics registerSource:includedSource forFile:foundPath];

    // `#package` state SAVES AND RESTORES across the file boundary
    // (wasm-target.md §6 rule 2): a header #imported mid-file must not leak
    // its package into everything after it — the same shape as the #line
    // resync below. The restore line re-arms the parser's state; `__none`
    // clears it.
    NSString* savedPackage = _currentPackage;
    NSString* expanded = [self preprocessSource:includedSource filename:foundPath];
    [output appendString:expanded];
    if (savedPackage != _currentPackage && ![savedPackage isEqualToString:_currentPackage])
        {
        [output appendFormat:@"package %@;\n", savedPackage ?: @"__none"];
        _currentPackage = savedPackage;
        }
    }

/****************************************************************************\
|* Handle a #define directive. Parses the macro name, optional parameter
|* list (including varargs), and body, then registers the definition.
|* @param content  The directive content after "#define".
|* @param loc      The source location for diagnostic reporting.
\****************************************************************************/
- (void)handleDefine:(NSString*)content location:(XTSourceLocation*)loc
    {
    // #define NAME or #define NAME body or #define NAME(params) body
    NSString* rest = [[content substringFromIndex:6]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (rest.length == 0)
        {
        [_diagnostics emitError:@"#define requires a name" at:loc];
        return;
        }

    // Parse macro name (up to whitespace or '(')
    NSUInteger idx = 0;
    while (idx < rest.length)
        {
        unichar ch = [rest characterAtIndex:idx];
        if (isalnum(ch) || ch == '_')
            idx++;
        else
            break;
        }
    NSString* name = [rest substringToIndex:idx];
    NSString* remainder = [rest substringFromIndex:idx];

    NSArray<NSString*>* params = nil;
    NSString* body = @"";

    if ([remainder hasPrefix:@"("])
        {
        // Function-like macro: parse parameter list up to matching ')'
        NSUInteger closeIdx = [remainder rangeOfString:@")"].location;
        if (closeIdx == NSNotFound)
            {
            [_diagnostics emitError:@"Unterminated macro parameter list" at:loc];
            return;
            }
        NSString* paramStr = [remainder substringWithRange:NSMakeRange(1, closeIdx - 1)];
        if (paramStr.length == 0)
            {
            params = @[];
            }
        else
            {
            NSArray<NSString*>* rawParams = [paramStr componentsSeparatedByString:@","];
            NSMutableArray<NSString*>* trimmed = [NSMutableArray array];
            for (NSString* p in rawParams)
                {
                [trimmed addObject:[p stringByTrimmingCharactersInSet:
                                           [NSCharacterSet whitespaceCharacterSet]]];
                }
            params = trimmed;
            }
        body = [[remainder substringFromIndex:closeIdx + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    else
        {
        body = [remainder stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

    // Strip trailing // comments from the macro body
    NSRange commentRange = [body rangeOfString:@"//"];
    if (commentRange.location != NSNotFound)
        {
        body = [[body substringToIndex:commentRange.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

    XTMacroDefinition* def = [[XTMacroDefinition alloc] initWithName:name
                                                          parameters:params
                                                                body:body];
    _macros[name] = def;
    }

/****************************************************************************\
|* Handle a #undef directive. Removes the named macro from the table.
|* @param content  The directive content after "#undef".
|* @param loc      The source location (unused, reserved for diagnostics).
\****************************************************************************/
- (void)handleUndef:(NSString*)content location:(XTSourceLocation*)loc
    {
    (void)loc;
    NSString* name = [[content substringFromIndex:5]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [_macros removeObjectForKey:name];
    }

#pragma mark - Macro Expansion

/****************************************************************************\
|* Expand all macro references in a line of text. Uses blue-painting
|* (the expandingMacros set) to prevent infinite recursion on
|* self-referential macros.
|* @param text        The input text to scan for macro identifiers.
|* @param filename    The current filename for nested expansion diagnostics.
|* @param lineNumber  The current line number for diagnostics.
|* @return  The text with all macros expanded.
\****************************************************************************/
- (NSString*)expandMacrosInText:(NSString*)text
                       filename:(NSString*)filename
                     lineNumber:(NSUInteger)lineNumber
    {
    // Simple token-by-token scan looking for identifiers that are macro names
    NSMutableString* result = [NSMutableString string];
    NSUInteger pos = 0;
    NSUInteger len = text.length;

    while (pos < len)
        {
        unichar ch = [text characterAtIndex:pos];

        // Skip string literals unchanged
        if (ch == '"')
            {
            [result appendFormat:@"%C", ch];
            pos++;
            while (pos < len)
                {
                unichar c = [text characterAtIndex:pos];
                if (c == '\\' && pos + 1 < len)
                    {
                    [result appendFormat:@"%C%C", c, [text characterAtIndex:pos + 1]];
                    pos += 2;
                    }
                else
                    {
                    [result appendFormat:@"%C", c];
                    pos++;
                    if (c == '"')
                        break;
                    }
                }
            continue;
            }

        // Skip char literals unchanged
        if (ch == '\'')
            {
            [result appendFormat:@"%C", ch];
            pos++;
            while (pos < len)
                {
                unichar c = [text characterAtIndex:pos];
                if (c == '\\' && pos + 1 < len)
                    {
                    [result appendFormat:@"%C%C", c, [text characterAtIndex:pos + 1]];
                    pos += 2;
                    }
                else
                    {
                    [result appendFormat:@"%C", c];
                    pos++;
                    if (c == '\'')
                        break;
                    }
                }
            continue;
            }

        // Identifier?
        if (isalpha(ch) || ch == '_')
            {
            NSMutableString* ident = [NSMutableString string];
            while (pos < len)
                {
                unichar c = [text characterAtIndex:pos];
                if (isalnum(c) || c == '_')
                    {
                    [ident appendFormat:@"%C", c];
                    pos++;
                    }
                else
                    break;
                }

            XTMacroDefinition* macro = _macros[ident];
            if (macro && ![_expandingMacros containsObject:ident])
                {
                if (macro.isFunctionLike)
                    {
                    // Try to find argument list
                    NSUInteger savedPos = pos;
                    // Skip whitespace
                    while (pos < len && ([text characterAtIndex:pos] == ' ' ||
                                         [text characterAtIndex:pos] == '\t'))
                        pos++;
                    if (pos < len && [text characterAtIndex:pos] == '(')
                        {
                        pos++; // skip (
                        NSArray<NSString*>* args = [self parseCallArgs:text pos:&pos len:len];
                        NSString* expanded = [self expandFunctionMacro:macro
                                                              withArgs:args
                                                              filename:filename
                                                            lineNumber:lineNumber];
                        [result appendString:expanded];
                        }
                    else
                        {
                        // No argument list; emit as-is
                        pos = savedPos;
                        [result appendString:ident];
                        }
                    }
                else
                    {
                    // Object-like macro. It takes no arguments, but its body may
                    // still paste tokens (`#define J a##b`), so it goes through
                    // the same substituter with empty maps.
                    [_expandingMacros addObject:ident];
                    NSString* pasted = [self substituteInBody:macro.body
                                                      rawArgs:@{}
                                                 expandedArgs:@{}];
                    NSString* expanded = [self expandMacrosInText:pasted
                                                         filename:filename
                                                       lineNumber:lineNumber];
                    [_expandingMacros removeObject:ident];
                    [result appendString:expanded];
                    }
                }
            else
                {
                [result appendString:ident];
                }
            continue;
            }

        [result appendFormat:@"%C", ch];
        pos++;
        }

    return result;
    }

/****************************************************************************\
|* Parse a parenthesised, comma-separated argument list for a function-like
|* macro invocation. Handles nested parentheses.
|* @param text    The full source text being scanned.
|* @param posPtr  On entry, points past the opening '('; on exit, past ')'.
|* @param len     The length of `text`.
|* @return  An array of trimmed argument strings.
\****************************************************************************/
- (NSArray<NSString*>*)parseCallArgs:(NSString*)text pos:(NSUInteger*)posPtr len:(NSUInteger)len
    {
    NSMutableArray<NSString*>* args = [NSMutableArray array];
    NSMutableString* current = [NSMutableString string];
    NSInteger depth = 1;
    NSUInteger pos = *posPtr;

    while (pos < len && depth > 0)
        {
        unichar ch = [text characterAtIndex:pos];

        // A string or character literal passes through whole — a comma or a
        // parenthesis inside one must not be read as argument structure.
        if (ch == '"' || ch == '\'')
            {
            unichar quote = ch;
            [current appendFormat:@"%C", ch];
            pos++;
            while (pos < len)
                {
                unichar c = [text characterAtIndex:pos];
                if (c == '\\' && pos + 1 < len)
                    {
                    [current appendFormat:@"%C%C", c, [text characterAtIndex:pos + 1]];
                    pos += 2;
                    continue;
                    }
                [current appendFormat:@"%C", c];
                pos++;
                if (c == quote)
                    break;
                }
            continue;
            }

        if (ch == '(')
            {
            depth++;
            [current appendFormat:@"%C", ch];
            pos++;
            }
        else if (ch == ')')
            {
            depth--;
            if (depth == 0)
                {
                pos++;
                break;
                }
            [current appendFormat:@"%C", ch];
            pos++;
            }
        else if (ch == ',' && depth == 1)
            {
            [args addObject:[current stringByTrimmingCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]]];
            current = [NSMutableString string];
            pos++;
            }
        else
            {
            [current appendFormat:@"%C", ch];
            pos++;
            }
        }
    NSString* last = [current stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (last.length > 0 || args.count > 0)
        {
        [args addObject:last];
        }

    *posPtr = pos;
    return args;
    }

/****************************************************************************\
|* Expand a function-like macro by substituting arguments into its body
|* and recursively expanding the result. Handles both fixed params
|* and varargs (__VA_ARGS__).
|* @param macro       The macro definition to expand.
|* @param args        The actual argument values at the call site.
|* @param filename    The current filename for nested diagnostics.
|* @param lineNumber  The current line number for diagnostics.
|* @return  The fully expanded text.
\****************************************************************************/
- (NSString*)expandFunctionMacro:(XTMacroDefinition*)macro
                        withArgs:(NSArray<NSString*>*)args
                        filename:(NSString*)filename
                      lineNumber:(NSUInteger)lineNumber
    {
    // Build the param → argument maps. Each parameter has TWO values: the raw
    // spelling, which is what `#` and `##` operate on, and the macro-expanded
    // spelling, which is what an ordinary substitution uses. That split is what
    // makes the two-level CAT(a,b) → CAT2(a,b) → a##b idiom resolve its
    // arguments before pasting them.
    //
    // Arguments are expanded BEFORE this macro is painted blue, so a macro may
    // legitimately appear in its own argument list.
    NSMutableDictionary<NSString*, NSString*>* rawArgs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* expandedArgs = [NSMutableDictionary dictionary];

    NSArray<NSString*>* params = macro.parameters;
    if (macro.isVarArgs)
        {
        params = [params subarrayWithRange:NSMakeRange(0, params.count - 1)];
        }
    for (NSUInteger i = 0; i < params.count; i++)
        {
        NSString* raw = (i < args.count) ? args[i] : @"";
        rawArgs[params[i]] = raw;
        expandedArgs[params[i]] = [self expandMacrosInText:raw
                                                  filename:filename
                                                lineNumber:lineNumber];
        }
    if (macro.isVarArgs)
        {
        NSString* vaRaw = @"";
        if (args.count > params.count)
            {
            vaRaw = [[args subarrayWithRange:NSMakeRange(params.count, args.count - params.count)]
                componentsJoinedByString:@", "];
            }
        rawArgs[@"__VA_ARGS__"] = vaRaw;
        expandedArgs[@"__VA_ARGS__"] = [self expandMacrosInText:vaRaw
                                                       filename:filename
                                                     lineNumber:lineNumber];
        }

    [_expandingMacros addObject:macro.name];
    NSString* substituted = [self substituteInBody:macro.body
                                           rawArgs:rawArgs
                                      expandedArgs:expandedArgs];
    NSString* expanded = [self expandMacrosInText:substituted
                                         filename:filename
                                       lineNumber:lineNumber];
    [_expandingMacros removeObject:macro.name];
    return expanded;
    }

/****************************************************************************\
|* Is this token a run of whitespace?
\****************************************************************************/
static BOOL isSpaceToken(NSString* tok)
    {
    return tok.length > 0 && ([tok characterAtIndex:0] == ' ' || [tok characterAtIndex:0] == '\t');
    }

/****************************************************************************\
|* Split a macro body into preprocessing tokens.
|*
|* Substitution MUST be token-aware: a plain textual replace of the parameter
|* name rewrites the parameter's letters wherever they occur, so a body
|* mentioning `abs_val` with a parameter named `a` came out as `<arg>bs_val`,
|* and a parameter named in a string literal was silently replaced inside it.
|*
|* Whitespace runs are emitted as tokens of their own so the body's spacing
|* survives; string and character literals come through whole.
|* @param body  The macro body text.
|* @return  The token list, in order.
\****************************************************************************/
- (NSArray<NSString*>*)tokenizeMacroBody:(NSString*)body
    {
    NSMutableArray<NSString*>* toks = [NSMutableArray array];
    NSUInteger pos = 0, len = body.length;

    while (pos < len)
        {
        unichar ch = [body characterAtIndex:pos];

        if (ch == ' ' || ch == '\t')
            {
            NSUInteger start = pos;
            while (pos < len)
                {
                unichar c = [body characterAtIndex:pos];
                if (c != ' ' && c != '\t')
                    break;
                pos++;
                }
            [toks addObject:[body substringWithRange:NSMakeRange(start, pos - start)]];
            continue;
            }

        if (ch == '"' || ch == '\'')
            {
            unichar quote = ch;
            NSUInteger start = pos++;
            while (pos < len)
                {
                unichar c = [body characterAtIndex:pos];
                if (c == '\\' && pos + 1 < len)
                    {
                    pos += 2;
                    continue;
                    }
                pos++;
                if (c == quote)
                    break;
                }
            [toks addObject:[body substringWithRange:NSMakeRange(start, pos - start)]];
            continue;
            }

        if (isalpha(ch) || ch == '_')
            {
            NSUInteger start = pos;
            while (pos < len)
                {
                unichar c = [body characterAtIndex:pos];
                if (!isalnum(c) && c != '_')
                    break;
                pos++;
                }
            [toks addObject:[body substringWithRange:NSMakeRange(start, pos - start)]];
            continue;
            }

        if (ch == '#')
            {
            if (pos + 1 < len && [body characterAtIndex:pos + 1] == '#')
                {
                [toks addObject:@"##"];
                pos += 2;
                }
            else
                {
                [toks addObject:@"#"];
                pos++;
                }
            continue;
            }

        [toks addObject:[body substringWithRange:NSMakeRange(pos, 1)]];
        pos++;
        }
    return toks;
    }

/****************************************************************************\
|* Turn an argument's raw spelling into a string literal, for `#param`.
\****************************************************************************/
- (NSString*)stringizeArgument:(NSString*)arg
    {
    NSMutableString* out = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < arg.length; i++)
        {
        unichar c = [arg characterAtIndex:i];
        if (c == '"' || c == '\\')
            [out appendFormat:@"\\%C", c];
        else
            [out appendFormat:@"%C", c];
        }
    [out appendString:@"\""];
    return out;
    }

/****************************************************************************\
|* Substitute arguments into a macro body, honouring `#` (stringize) and
|* `##` (token paste).
|*
|* An ordinary parameter reference substitutes its macro-EXPANDED argument; an
|* operand of `#` or `##` substitutes the RAW one, which is what lets
|*
|*     #define CAT2(a,b)  a##b
|*     #define CAT(a,b)    CAT2(a,b)
|*
|* paste already-expanded values: the outer CAT expands its arguments normally,
|* and only the inner CAT2 suppresses expansion to do the paste.
|*
|* GNU's `, ## __VA_ARGS__` comma-swallow is supported: an empty variadic tail
|* removes the preceding comma.
|*
|* Object-like macros pass empty maps and are simply pasted.
|* @param body          The macro body text.
|* @param rawArgs       param → argument as written at the call site.
|* @param expandedArgs  param → that argument, macro-expanded.
|* @return  The body with arguments substituted and #/## applied.
\****************************************************************************/
- (NSString*)substituteInBody:(NSString*)body
                      rawArgs:(NSDictionary<NSString*, NSString*>*)rawArgs
                 expandedArgs:(NSDictionary<NSString*, NSString*>*)expandedArgs
    {
    NSArray<NSString*>* toks = [self tokenizeMacroBody:body];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    NSUInteger i = 0, n = toks.count;
    BOOL pendingPaste = NO;

    // Index of the next token that isn't whitespace, or n.
    NSUInteger (^nextReal)(NSUInteger) = ^NSUInteger(NSUInteger from) {
      NSUInteger j = from;
      while (j < n && isSpaceToken(toks[j]))
          j++;
      return j;
    };

    while (i < n)
        {
        NSString* tok = toks[i];

        if (isSpaceToken(tok))
            {
            // Whitespace adjacent to `##` is not part of the pasted spelling.
            NSUInteger j = nextReal(i);
            if (pendingPaste || (j < n && [toks[j] isEqualToString:@"##"]))
                {
                i++;
                continue;
                }
            [out addObject:tok];
            i++;
            continue;
            }

        if ([tok isEqualToString:@"##"])
            {
            pendingPaste = YES;
            i = nextReal(i + 1);
            continue;
            }

        NSString* piece = nil;
        BOOL rhsIsVaArgs = NO;

        if ([tok isEqualToString:@"#"] && rawArgs.count > 0)
            {
            NSUInteger j = nextReal(i + 1);
            NSString* operand = (j < n) ? toks[j] : nil;
            if (operand && rawArgs[operand])
                {
                piece = [self stringizeArgument:rawArgs[operand]];
                i = j + 1;
                }
            }

        if (!piece)
            {
            NSString* raw = rawArgs[tok];
            if (raw)
                {
                NSUInteger j = nextReal(i + 1);
                BOOL nextIsPaste = (j < n && [toks[j] isEqualToString:@"##"]);
                piece = (pendingPaste || nextIsPaste) ? raw : expandedArgs[tok];
                rhsIsVaArgs = [tok isEqualToString:@"__VA_ARGS__"];
                }
            else
                {
                piece = tok;
                }
            i++;
            }

        if (pendingPaste)
            {
            while (out.count > 0 && isSpaceToken(out.lastObject))
                [out removeLastObject];

            // `, ## __VA_ARGS__` with no variadic arguments: drop the comma.
            if (piece.length == 0 && rhsIsVaArgs &&
                out.count > 0 && [out.lastObject isEqualToString:@","])
                {
                [out removeLastObject];
                }
            else if (out.count > 0)
                {
                out[out.count - 1] = [out.lastObject stringByAppendingString:piece];
                }
            else if (piece.length > 0)
                {
                [out addObject:piece];
                }
            pendingPaste = NO;
            }
        else
            {
            [out addObject:piece];
            }
        }

    return [out componentsJoinedByString:@""];
    }

@end
