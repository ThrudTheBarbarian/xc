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
|* --par-style=auto: an outermost `for (T i in a..b) { … }` in plain code becomes
|* a `par` block when its shape allows (parAutoFor); par-check later demotes
|* an auto block it would refuse to a serial run.
\****************************************************************************/
@property(nonatomic) BOOL parAuto;
/// --par-style=auto found a loop to wrap, but Par.xc was not imported: the driver
/// parses the unit again with the runtime imported.
@property(nonatomic, readonly) BOOL parAutoWantsRuntime;
/// XC_PAR_AUTO_TRACE: a line for each loop --par-style=auto looks at, which the
/// driver prints once the parse is final (parAutoTraceLine). Mirrored in the port.
@property(nonatomic) BOOL parAutoTraceOn;
/// The lines in order; a trace line's `#n` is given here (see the getter).
@property(nonatomic, readonly, nullable) NSMutableArray<NSString*>* parAutoTrace;
// wasm32: a module's memory is its own, so a protocol's static members are
// calls BETWEEN modules (an export of the provider, an import of everyone
// else) and may pass only numbers, or a buffer and its length.
@property(nonatomic) BOOL webModules;
// The unit's default goal for loops and par blocks without a :goal(…) of
// their own: 0 the built-in (loops accuracy, par blocks speed), 1 speed, 2
// accuracy — from #goal, else -fgoal=. Under an explicit speed, --par-style=auto
// also wraps float reductions (their sum may reassociate).
@property(nonatomic) NSUInteger goalDefault;
/// The goal of the loop or block being parsed: 0 none yet, 1 speed, 2 accuracy.
@property(nonatomic) NSUInteger goalNow;
// -fno-par-fuse: adjacent par blocks stay apart (#147).
@property(nonatomic) BOOL parNoFuse;
// --par-style's device for a par block with no :device (1 cpu, 2 gpu), or 0.
@property(nonatomic) NSInteger parDeviceDefault;
// The files --par-style=auto leaves alone: the standard library's and the
// prelude's, as the preprocessor names them (XTPreprocessor.libraryFiles).
// The runtime's own loops wrapped in blocks re-entered it.
@property(nonatomic, nullable) NSSet<NSString*>* libraryFiles;
// Tensor types: `tensor<T, R>` becomes the class name `__tensor_<T>_<R>`
// (fuseTensorTypes). The names the unit uses, in order of first use.
@property(nonatomic, readonly) NSArray<NSString*>* tensorNames;
// Set by the driver once TensorStorage.xc is imported: the parse adds the
// tensor classes to the program. Until then the names are class markers.
@property(nonatomic) BOOL tensorReady;
// The tensor class names the imported interfaces use.
@property(nonatomic, nullable) NSArray<NSString*>* importedTensorNames;
// The kernels of the unit's tensor expressions, one signature each, as sema
// asked for them: the parse writes each one's source after the classes.
@property(nonatomic, nullable) NSArray<NSString*>* tensorKernels;

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

/****************************************************************************\
|* The operators of their own shape that the classes of imported interfaces
|* define (`:operator(self ** o)`), for the parse to read. The driver calls it
|* before -parse with the declarations it reconstructed.
\****************************************************************************/
- (void)addImportedOperatorShapes:(NSArray<XTASTNode*>*)decls;

/****************************************************************************\
|* Protocol names declared outside the tokens this parser reads, so a bare
|* use stamps the protocol constraint as in the unit that declared them. The
|* designable synthesis parses its generated methods with them: without them
|* an outlet's `(P* ?)value` read P as a class and lost its conformance check.
\****************************************************************************/
- (void)addKnownProtocolNames:(NSArray<NSString*>*)names;

@end

// Tensor types (XTParser+Tensors.m).
@interface XTParser (Tensors)
// `tensor<T, R>` becomes the class name `__tensor_<T>_<R>`; the classes join
// the unit once tensorReady is set.
- (void)fuseTensorTypes;
// The class source of a tensor class name, or nil for a name that is not one.
+ (nullable NSString*)tensorClassSource:(NSString*)name;
// …with the views the unit takes: its slice patterns, and the ranks it
// views or reshapes to and broadcasts to.
+ (nullable NSString*)tensorClassSource:(NSString*)name
                               patterns:(NSArray<NSString*>*)patterns
                             shapeRanks:(NSIndexSet*)shapeRanks
                             bcastRanks:(NSIndexSet*)bcastRanks;
// A tensor expression's kernel (XTParser+TensorKernels.m): its function's
// name, the tensor classes it uses, and its source, from its signature.
+ (NSString*)tensorKernelName:(NSString*)sig;
+ (NSArray<NSString*>*)tensorKernelClasses:(NSString*)sig;
+ (NSString*)tensorKernelSource:(NSString*)sig;
@end

NS_ASSUME_NONNULL_END

#import "XTParser+ExprParser.h"
