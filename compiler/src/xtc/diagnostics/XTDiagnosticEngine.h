#import <Foundation/Foundation.h>
#import "XTSourceLocation.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XTDiagnosticLevel) {
    XTDiagnosticLevelNote,
    XTDiagnosticLevelWarning,
    XTDiagnosticLevelError,
};

/****************************************************************************\
|* Warning categories. Each suppressible warning tags itself with
|* one of these so the user can silence a class of diagnostic via
|* `-Wno-<category>` on the command line. `XTWarnNone` is the
|* opt-out used by warnings that must always fire (e.g. explicit
|* `#warning` directives, which reflect user intent).
\****************************************************************************/
typedef NS_ENUM(NSInteger, XTWarningCategory) {
    XTWarnNone,              // non-suppressible
    XTWarnEscape,            // -Wno-escape
    XTWarnClassInit,         // -Wno-class-init
    XTWarnAsmClobbers,       // -Wno-asm-clobbers
    XTWarnUnknownAnnotation, // -Wno-unknown-annotation
    XTWarnUnknownPragma,     // -Wno-unknown-pragma
    XTWarnPrintfFormat,      // -Wno-printf-format
    XTWarnUnownedBound,      // -Wno-unowned-bound — an `unowned:` bound method
                             // (`^`) bound to an ARC object's method: the
                             // author asserted the receiver outlives the
                             // field, and if that's wrong NOTHING can catch
                             // it (`if (h)` tests the code word, which stays
                             // valid). Use `weak:` unless the lifetime is
                             // genuinely guaranteed.
    XTWarnCloakedTransitive, // -Wno-cloaked-transitive — stage 4c: downgrade
                             // transitive :cloaked errors to warnings so
                             // programs that silently worked pre-4c can
                             // still build while their authors refactor.
    XTWarnUnreachableCatch,  // -Wno-unreachable-catch — a `catch` arm shadowed
                             // by an earlier, broader one. Appended: inserting
                             // mid-enum renumbers the rest.
    XTWarnPackedAlign,       // -Wno-packed-align — a `:packed` struct field at
                             // an offset a strict-alignment target (m68k, arm9
                             // 64-bit pairs) may fault on when accessed whole.
    XTWarnComment,           // -Wno-comment — a `/*` inside a block comment.
                             // Comments do NOT nest, so the first `*/` closes
                             // and the rest is parsed as code; the error that
                             // follows points at prose and reads as nonsense.
    XTWarnCovariantReturn,   // -Wno-covariant-return — a method declares the
                             // return type it INHERITED where it could
                             // declare its own. Legal, but it discards what
                             // it knows, and an inherited `Object*` on a
                             // class used with a type argument is read as
                             // that class's element type (private:docs/bugs/051,055).
    XTWarnRangeInitCount,    // -Wno-range-init-count — a range initialiser
                             // that does not fill its array. The tail
                             // zero-fills either way, as a short `{ … }` list
                             // does; this says the counts disagree, because
                             // `u8 a[10] = 0..9;` looks exact and is not
                             // (`..` excludes its end). Appended: inserting
                             // mid-enum renumbers the rest.
    XTWarnUnguardedAction,   // -Wno-unguarded-action — a `^` called without
                             // having been tested since its last assignment.
                             // A stored `^` never retains its receiver and
                             // goes falsy when the receiver dies (bound-
                             // methods.md §6), so `if (f) f()` is the
                             // contract exactly as it is for a null function
                             // pointer. Calling unguarded dispatches through
                             // a nulled receiver.
    XTWarnToolchainFallback, // -Wno-toolchain-fallback — the build was
                             // completed by the SYSTEM toolchain (clang,
                             // mingw) instead of the in-house one. Loud by
                             // default and deliberately so: a quiet fallback
                             // hid a dead win64 linker for two weeks (#1083
                             // regenerated the runtime for the wrong target,
                             // and every build still "succeeded"). Suppress
                             // it only when falling back ON PURPOSE.
};

/****************************************************************************\
|* String ↔ category conversion for CLI parsing and error messages.
\****************************************************************************/
/****************************************************************************\
|* Return the kebab-case name for a warning category (e.g. "escape").
|* @param cat  The warning category enum value.
|* @return  The category name string, or empty string for XTWarnNone.
\****************************************************************************/
NSString* XTWarningCategoryName(XTWarningCategory cat);
/****************************************************************************\
|* Look up a warning category by its kebab-case name.
|* @param name  The category name (e.g. "escape").
|* @return  The matching enum value, or XTWarnNone if unrecognised.
\****************************************************************************/
XTWarningCategory XTWarningCategoryFromName(NSString* name);
/****************************************************************************\
|* Return the list of all known warning category names.
|* @return  An array of kebab-case name strings.
\****************************************************************************/
NSArray<NSString*>* XTWarningCategoryAllNames(void);

@interface XTDiagnostic : NSObject

@property(nonatomic, readonly) XTDiagnosticLevel level;
@property(nonatomic, readonly) NSString* message;
@property(nonatomic, readonly) XTSourceLocation* location;

/****************************************************************************\
|* Initialise a diagnostic record with level, message, and source location.
|* @param level     The severity (note, warning, or error).
|* @param message   The human-readable diagnostic text.
|* @param location  The source location where the diagnostic occurred.
|* @return  An immutable diagnostic record.
\****************************************************************************/
- (instancetype)initWithLevel:(XTDiagnosticLevel)level
                      message:(NSString*)message
                     location:(XTSourceLocation*)location NS_DESIGNATED_INITIALIZER;

@end

@interface XTDiagnosticEngine : NSObject

@property(nonatomic, readonly) NSArray<XTDiagnostic*>* diagnostics;
@property(nonatomic, readonly) BOOL hasFatalError;
@property(nonatomic, readonly) NSUInteger errorCount;
@property(nonatomic, readonly) NSUInteger warningCount;

/****************************************************************************\
|* Register source text for a file so diagnostics can show the offending line.
\****************************************************************************/
- (void)registerSource:(NSString*)source forFile:(NSString*)filename;

/****************************************************************************\
|* Emit an informational note diagnostic.
|* @param message   The note text.
|* @param location  The source location to associate with the note.
\****************************************************************************/
- (void)emitNote:(NSString*)message at:(XTSourceLocation*)location;
/****************************************************************************\
|* Emit a non-categorised warning. Only use this for diagnostics
|* the user cannot suppress (explicit `#warning` directives).
\****************************************************************************/
- (void)emitWarning:(NSString*)message at:(XTSourceLocation*)location;
/****************************************************************************\
|* Emit a categorised warning. Dropped silently if the category is
|* in the suppressed set (`-Wno-<name>` on the CLI).
\****************************************************************************/
- (void)emitWarning:(NSString*)message
           category:(XTWarningCategory)category
                 at:(XTSourceLocation*)location;
/****************************************************************************\
|* Emit an error diagnostic and set the fatal error flag.
|* @param message   The error text.
|* @param location  The source location where the error occurred.
\****************************************************************************/
- (void)emitError:(NSString*)message at:(XTSourceLocation*)location;
/****************************************************************************\
|* Emit a fatal error diagnostic. Currently equivalent to emitError:.
|* @param message   The error text.
|* @param location  The source location where the error occurred.
\****************************************************************************/
- (void)emitFatalError:(NSString*)message at:(XTSourceLocation*)location;

/****************************************************************************\
|* Suppress a warning category. Subsequent categorised warnings in
|* that category are dropped before they're added to the diagnostic
|* list (so they don't count against `warningCount`).
\****************************************************************************/
- (void)suppressWarningCategory:(XTWarningCategory)category;

/****************************************************************************\
|* Query whether a warning category is currently suppressed. Used by sema
|* Pass C (:cloaked transitive-safety validator) to decide whether to
|* emit the stage-4c diagnostic as an error (default) or as a warning
|* (when -Wno-cloaked-transitive is in effect) — the flag is a
|* migration escape hatch, not a silencer.
\****************************************************************************/
- (BOOL)isWarningCategorySuppressed:(XTWarningCategory)category;

/****************************************************************************\
|* Print all diagnostics to stderr in clang style:
|*   filename:line:col: error: message
|*     source line
|*     ~~~^~~~
\****************************************************************************/
- (void)printAll;

/****************************************************************************\
|* Clear all stored diagnostics (used between pipeline stages in tests).
\****************************************************************************/
- (void)clear;

@end

NS_ASSUME_NONNULL_END
