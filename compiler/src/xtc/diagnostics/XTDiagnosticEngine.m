#import "XTDiagnosticEngine.h"

/****************************************************************************\
|* Return the kebab-case name for a warning category (e.g. "escape").
|* @param cat  The warning category enum value.
|* @return  The category name string, or empty string for XTWarnNone.
\****************************************************************************/
NSString* XTWarningCategoryName(XTWarningCategory cat)
    {
    switch (cat)
        {
    case XTWarnNone:
        return @"";
    case XTWarnEscape:
        return @"escape";
    case XTWarnClassInit:
        return @"class-init";
    case XTWarnAsmClobbers:
        return @"asm-clobbers";
    case XTWarnUnknownAnnotation:
        return @"unknown-annotation";
    case XTWarnUnknownPragma:
        return @"unknown-pragma";
    case XTWarnPrintfFormat:
        return @"printf-format";
    case XTWarnUnownedBound:
        return @"unowned-bound";
    case XTWarnCloakedTransitive:
        return @"cloaked-transitive";
    case XTWarnUnreachableCatch:
        return @"unreachable-catch";
    case XTWarnComment:
        return @"comment";
    // These three were in the enum and in AllNames but never here, so
    // XTWarningCategoryName() returned "" for them — the same three-place
    // drift the note in AllNames describes, caught from the other side.
    case XTWarnPackedAlign:
        return @"packed-align";
    case XTWarnRangeInitCount:
        return @"range-init-count";
    case XTWarnCovariantReturn:
        return @"covariant-return";
    case XTWarnUnguardedAction:
        return @"unguarded-action";
    case XTWarnToolchainFallback:
        return @"toolchain-fallback";
        }
    return @"";
    }

/****************************************************************************\
|* Look up a warning category by its kebab-case name.
|* @param name  The category name (e.g. "escape").
|* @return  The matching enum value, or XTWarnNone if unrecognised.
\****************************************************************************/
XTWarningCategory XTWarningCategoryFromName(NSString* name)
    {
    if ([name isEqualToString:@"escape"])
        return XTWarnEscape;
    if ([name isEqualToString:@"class-init"])
        return XTWarnClassInit;
    if ([name isEqualToString:@"asm-clobbers"])
        return XTWarnAsmClobbers;
    if ([name isEqualToString:@"unknown-annotation"])
        return XTWarnUnknownAnnotation;
    if ([name isEqualToString:@"unknown-pragma"])
        return XTWarnUnknownPragma;
    if ([name isEqualToString:@"printf-format"])
        return XTWarnPrintfFormat;
    if ([name isEqualToString:@"unowned-bound"])
        return XTWarnUnownedBound;
    if ([name isEqualToString:@"cloaked-transitive"])
        return XTWarnCloakedTransitive;
    if ([name isEqualToString:@"unreachable-catch"])
        return XTWarnUnreachableCatch;
    if ([name isEqualToString:@"comment"])
        return XTWarnComment;
    if ([name isEqualToString:@"packed-align"])
        return XTWarnPackedAlign;
    if ([name isEqualToString:@"range-init-count"])
        return XTWarnRangeInitCount;
    if ([name isEqualToString:@"covariant-return"])
        return XTWarnCovariantReturn;
    if ([name isEqualToString:@"unguarded-action"])
        return XTWarnUnguardedAction;
    if ([name isEqualToString:@"toolchain-fallback"])
        return XTWarnToolchainFallback;
    return XTWarnNone;
    }

/****************************************************************************\
|* Return the list of all known warning category names.
|* @return  An array of kebab-case name strings.
\****************************************************************************/
NSArray<NSString*>* XTWarningCategoryAllNames(void)
    {
    return @[
        @"escape",
        @"class-init",
        @"asm-clobbers",
        @"unknown-annotation",
        @"unknown-pragma",
        @"printf-format",
        @"packed-align",
        @"unowned-bound",
        @"cloaked-transitive",
        // These two had drifted out of the list: the enum, the name mapper and
        // this array are three places that must agree, and only this one is
        // user-visible (it is what `-Wno-<typo>` prints as "known: ...").
        @"unreachable-catch",
        @"comment",
        @"range-init-count",
        @"covariant-return",
        @"toolchain-fallback",
        @"unguarded-action",
    ];
    }

@implementation XTDiagnostic

/****************************************************************************\
|* Initialise a diagnostic record with level, message, and source location.
|* @param level     The severity (note, warning, or error).
|* @param message   The human-readable diagnostic text.
|* @param location  The source location where the diagnostic occurred.
|* @return  An immutable diagnostic record.
\****************************************************************************/
- (instancetype)initWithLevel:(XTDiagnosticLevel)level
                      message:(NSString*)message
                     location:(XTSourceLocation*)location
    {
    self = [super init];
    if (self)
        {
        _level = level;
        _message = [message copy];
        _location = location;
        }
    return self;
    }

@end

@interface XTDiagnosticEngine ()
@property(nonatomic) NSMutableArray<XTDiagnostic*>* mutableDiagnostics;
@property(nonatomic) BOOL fatalFlag;
@property(nonatomic) NSMutableDictionary<NSString*, NSArray<NSString*>*>* sourceLines;
@property(nonatomic) NSMutableIndexSet* suppressedWarnings;
@end

@implementation XTDiagnosticEngine

/****************************************************************************\
|* Initialise an empty diagnostic engine with no stored diagnostics.
|* @return  A fresh diagnostic engine instance.
\****************************************************************************/
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _mutableDiagnostics = [NSMutableArray array];
        _sourceLines = [NSMutableDictionary dictionary];
        _suppressedWarnings = [NSMutableIndexSet indexSet];
        _fatalFlag = NO;
        }
    return self;
    }

/****************************************************************************\
|* Return an immutable snapshot of all stored diagnostics.
|* @return  An array of XTDiagnostic records.
\****************************************************************************/
- (NSArray<XTDiagnostic*>*)diagnostics
    {
    return [_mutableDiagnostics copy];
    }

/****************************************************************************\
|* Whether any error has been emitted since the last clear.
|* @return  YES if at least one error-level diagnostic was recorded.
\****************************************************************************/
- (BOOL)hasFatalError
    {
    return _fatalFlag;
    }

/****************************************************************************\
|* Count of error-level diagnostics stored.
|* @return  The number of errors.
\****************************************************************************/
- (NSUInteger)errorCount
    {
    NSUInteger count = 0;
    for (XTDiagnostic* d in _mutableDiagnostics)
        {
        if (d.level == XTDiagnosticLevelError)
            count++;
        }
    return count;
    }

/****************************************************************************\
|* Count of warning-level diagnostics stored.
|* @return  The number of warnings.
\****************************************************************************/
- (NSUInteger)warningCount
    {
    NSUInteger count = 0;
    for (XTDiagnostic* d in _mutableDiagnostics)
        {
        if (d.level == XTDiagnosticLevelWarning)
            count++;
        }
    return count;
    }

/****************************************************************************\
|* Register source text for a file so diagnostics can show the offending line.
|* @param source    The full source text of the file.
|* @param filename  The file path used to key the source line cache.
\****************************************************************************/
- (void)registerSource:(NSString*)source forFile:(NSString*)filename
    {
    _sourceLines[filename] = [source componentsSeparatedByString:@"\n"];
    }

/****************************************************************************\
|* Emit an informational note diagnostic.
|* @param message   The note text.
|* @param location  The source location to associate with the note.
\****************************************************************************/
- (void)emitNote:(NSString*)message at:(XTSourceLocation*)location
    {
    XTDiagnostic* d = [[XTDiagnostic alloc] initWithLevel:XTDiagnosticLevelNote
                                                  message:message
                                                 location:location];
    [_mutableDiagnostics addObject:d];
    }

/****************************************************************************\
|* Emit a non-categorised warning. Only use this for diagnostics
|* the user cannot suppress (explicit `#warning` directives).
|* @param message   The warning text.
|* @param location  The source location where the warning occurred.
\****************************************************************************/
- (void)emitWarning:(NSString*)message at:(XTSourceLocation*)location
    {
    [self emitWarning:message category:XTWarnNone at:location];
    }

/****************************************************************************\
|* Emit a categorised warning. Dropped silently if the category is
|* in the suppressed set (`-Wno-<name>` on the CLI).
|* @param message   The warning text.
|* @param category  The warning category for suppression filtering.
|* @param location  The source location where the warning occurred.
\****************************************************************************/
- (void)emitWarning:(NSString*)message
           category:(XTWarningCategory)category
                 at:(XTSourceLocation*)location
    {
    if (category != XTWarnNone &&
        [_suppressedWarnings containsIndex:(NSUInteger)category])
        {
        return;
        }
    XTDiagnostic* d = [[XTDiagnostic alloc] initWithLevel:XTDiagnosticLevelWarning
                                                  message:message
                                                 location:location];
    [_mutableDiagnostics addObject:d];
    }

/****************************************************************************\
|* Suppress a warning category. Subsequent categorised warnings in
|* that category are dropped before they're added to the diagnostic list.
|* @param category  The category to suppress (XTWarnNone is ignored).
\****************************************************************************/
- (void)suppressWarningCategory:(XTWarningCategory)category
    {
    if (category != XTWarnNone)
        {
        [_suppressedWarnings addIndex:(NSUInteger)category];
        }
    }

/****************************************************************************\
|* Query whether a warning category has been suppressed by -Wno-<name>.
|* @param category  The category to test (XTWarnNone is never suppressed).
|* @return  YES iff a prior suppressWarningCategory: recorded this one.
\****************************************************************************/
- (BOOL)isWarningCategorySuppressed:(XTWarningCategory)category
    {
    if (category == XTWarnNone)
        return NO;
    return [_suppressedWarnings containsIndex:(NSUInteger)category];
    }

/****************************************************************************\
|* Emit an error diagnostic and set the fatal error flag.
|* @param message   The error text.
|* @param location  The source location where the error occurred.
\****************************************************************************/
- (void)emitError:(NSString*)message at:(XTSourceLocation*)location
    {
    XTDiagnostic* d = [[XTDiagnostic alloc] initWithLevel:XTDiagnosticLevelError
                                                  message:message
                                                 location:location];
    [_mutableDiagnostics addObject:d];
    _fatalFlag = YES;
    }

/****************************************************************************\
|* Emit a fatal error diagnostic. Currently equivalent to emitError:.
|* @param message   The error text.
|* @param location  The source location where the error occurred.
\****************************************************************************/
- (void)emitFatalError:(NSString*)message at:(XTSourceLocation*)location
    {
    [self emitError:message at:location];
    }

/****************************************************************************\
|* Print all diagnostics to stderr in clang style:
|*   filename:line:col: error: message
|*     source line
|*     ~~~^~~~
\****************************************************************************/
- (void)printAll
    {
    for (XTDiagnostic* d in _mutableDiagnostics)
        {
        NSString* levelStr;
        switch (d.level)
            {
        case XTDiagnosticLevelNote:
            levelStr = @"note";
            break;
        case XTDiagnosticLevelWarning:
            levelStr = @"warning";
            break;
        case XTDiagnosticLevelError:
            levelStr = @"error";
            break;
            }

        // ANSI colours: bold white for location, red for error, magenta for warning, cyan for note
        const char* bold = "\033[1m";
        const char* red = "\033[1;31m";
        const char* mag = "\033[1;35m";
        const char* cyan = "\033[1;36m";
        const char* green = "\033[1;32m";
        const char* reset = "\033[0m";
        (void)cyan;
        (void)green;

        const char* levelColor;
        switch (d.level)
            {
        case XTDiagnosticLevelError:
            levelColor = red;
            break;
        case XTDiagnosticLevelWarning:
            levelColor = mag;
            break;
        case XTDiagnosticLevelNote:
            levelColor = cyan;
            break;
            }

        // Line 1: filename:line:col: level: message
        fprintf(stderr, "%s%s:%s %s%s:%s %s\n",
                bold, d.location.description.UTF8String, reset,
                levelColor, levelStr.UTF8String, reset,
                d.message.UTF8String);

        // Line 2: the source line (if available)
        NSArray<NSString*>* lines = _sourceLines[d.location.filename];
        if (lines && d.location.line > 0 && d.location.line <= lines.count)
            {
            NSString* srcLine = lines[d.location.line - 1];
            // Replace tabs with spaces for consistent column alignment
            NSString* displayLine = [srcLine stringByReplacingOccurrencesOfString:@"\t" withString:@"    "];
            fprintf(stderr, " %s\n", displayLine.UTF8String);

            // Line 3: caret indicator
            // Build a string of spaces/tildes up to the column, then a caret
            NSUInteger col = d.location.column;
            if (col > 0)
                col--; // 1-based → 0-based

            // Adjust column for tab expansion
            NSUInteger adjustedCol = 0;
            for (NSUInteger i = 0; i < col && i < srcLine.length; i++)
                {
                if ([srcLine characterAtIndex:i] == '\t')
                    {
                    adjustedCol += 4;
                    }
                else
                    {
                    adjustedCol++;
                    }
                }

            NSMutableString* caret = [NSMutableString stringWithString:@" "];
            for (NSUInteger i = 0; i < adjustedCol; i++)
                {
                [caret appendString:@" "];
                }
            fprintf(stderr, "%s%s^%s\n", green, caret.UTF8String, reset);
            }
        }
    }

/****************************************************************************\
|* Clear all stored diagnostics (used between pipeline stages in tests).
\****************************************************************************/
- (void)clear
    {
    [_mutableDiagnostics removeAllObjects];
    _fatalFlag = NO;
    }

@end
