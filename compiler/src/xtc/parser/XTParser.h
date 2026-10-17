#import <Foundation/Foundation.h>
#import "XTToken.h"
#import "XTASTNode.h"
#import "XTDeclNodes.h"
#import "XTDiagnosticEngine.h"
#import "XTPointerType.h"
#import "XTTypeTable.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTParser : NSObject

/****************************************************************************\
|* Default placement for unannotated `T@` pointers. Banked-heap targets
|* (xt-heap, xe-heap) set this to Banked so `Box@ b = new Box()` lands
|* a 3-byte banked pointer on the LHS, matching the allocator's return
|* type and carrying the bank id picked up by the multi-bank allocator.
|* Flat targets leave it at Main. Only the outermost `@` picks up this
|* default; inner levels of `T@@` stay Main so stacks of pointers still
|* behave sensibly.
\****************************************************************************/
@property(nonatomic) XTPointerPlacement defaultPointerPlacement;

/****************************************************************************\
|* --par-auto: an outermost `for (T i in a..b) { … }` in plain code becomes
|* a `par` block when its shape allows (parAutoFor); par-check later demotes
|* an auto block it would refuse to a serial run.
\****************************************************************************/
@property(nonatomic) BOOL parAuto;
// wasm32: a module's memory is its own, so a protocol's static members are
// calls BETWEEN modules (an export of the provider, an import of everyone
// else) and may pass only numbers, or a buffer and its length.
@property(nonatomic) BOOL webModules;
// The unit's default goal for loops and par blocks without a :goal(…) of
// their own: 0 the built-in (loops accuracy, par blocks speed), 1 speed, 2
// accuracy — from #goal, else -fgoal=. Under an explicit speed, --par-auto
// also wraps float reductions (their sum may reassociate).
@property(nonatomic) NSUInteger goalDefault;
// The files --par-auto leaves alone: the standard library's and the
// prelude's, as the preprocessor names them (XTPreprocessor.libraryFiles).
// The runtime's own loops wrapped in blocks re-entered it.
@property(nonatomic, nullable) NSSet<NSString*>* libraryFiles;

/****************************************************************************\
|* Initialise the parser with a token stream, a type table for resolving
|* user-defined type names, and a diagnostic engine for error reporting.
|* @param tokens       Ordered array of lexer tokens to parse.
|* @param typeTable    Global type registry for resolving type names.
|* @param diagnostics  Diagnostic engine for emitting errors and warnings.
|* @return  A fully initialised parser ready for -parse.
\****************************************************************************/
- (instancetype)initWithTokens:(NSArray<XTToken*>*)tokens
                     typeTable:(XTTypeTable*)typeTable
                   diagnostics:(XTDiagnosticEngine*)diagnostics NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Parse and return the program AST root.
\****************************************************************************/
- (nullable XTProgramNode*)parse;

/****************************************************************************\
|* Pre-scan the token stream and register placeholder types for every class /
|* struct / enum / protocol declared in the unit. parse calls this itself;
|* the driver ALSO calls it before interface imports so metadata that names
|* an ambient type (the platform-prelude surface) resolves to the same
|* placeholder the parse will fill (task #36). Idempotent.
\****************************************************************************/
- (void)prescanForwardTypeDeclarations;

@end

NS_ASSUME_NONNULL_END

#import "XTParser+ExprParser.h"
