#import <Foundation/Foundation.h>
#import "XTCommandLineOptions.h"
#import "XTDiagnosticEngine.h"

@class XTIRModule;

NS_ASSUME_NONNULL_BEGIN

@class XTProgramNode;

@interface XTCompilerDriver : NSObject

@property (nonatomic, readonly) XTCommandLineOptions *options;
@property (nonatomic, readonly) XTDiagnosticEngine *diagnostics;

/****************************************************************************\
|* Shared-library `.so` paths whose symbols the just-compiled source
|* actually references (via `#import <lib>`). The dispatcher links against
|* these so the ELF records DT_NEEDED (from each .so's DT_SONAME) and the
|* loader resolves the imports. Populated by compileFrontendForFile:; empty
|* when nothing was imported. xtc-fe writes it to a `<output>.needs` sidecar
|* for the dispatcher to consume across the process boundary.
\****************************************************************************/
@property (nonatomic, readonly) NSArray<NSString *> *neededLibraryPaths;

/****************************************************************************\
|* The analysed program (post-sema AST). Exposed so xtc-fe can serialise the
|* public declarations into a binary library's `.xtc.iface` section under
|* --emit-lib. Populated by compileFrontendForFile:.
\****************************************************************************/
@property (nonatomic, readonly, nullable) XTProgramNode *analyzedProgram;

// The implicit prelude's file set (see XTPreprocessor.preludeFiles) — the
// interface serializer excludes declarations that originate there.
@property (nonatomic, readonly, nullable) NSSet<NSString *> *preludeFiles;
/****************************************************************************\
|* The vtable slot indices this build committed to — serialised into the
|* library's interface under --emit-lib so a client adopts them rather than
|* renumbering from 0 (which dispatched through the wrong slot entirely).
\****************************************************************************/
@property (nonatomic, readonly, nullable) NSArray<NSString *> *cLibraryImports;
@property (nonatomic, readonly, nullable) NSDictionary *protocolSlots;
@property (nonatomic, readonly, nullable) NSDictionary *virtualMethodSlots;

/****************************************************************************\
|* Initialise the compiler driver with parsed command-line options.
|* @param options  The parsed command-line options.
|* @return  A configured compiler driver ready to compile.
\****************************************************************************/
- (instancetype)initWithOptions:(XTCommandLineOptions *)options NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Run the IR frontend (preprocess → lex → parse → sema → IR-lower →
|* verify) on a single source file and return the resulting IR module.
|* Used by xtc-fe and the in-process backend pipeline both. Returns nil
|* on any frontend error (errors are printed via the diagnostic engine).
\****************************************************************************/
- (nullable XTIRModule *)compileFrontendForFile:(NSString *)inputFile;

/****************************************************************************\
|* Print the C interface this target auto-imports (the libc the driver finds
|* on the library search path) as xtc declarations, sorted by name.
|*
|* The self-hosted front end has no DWARF reader, so it reads the same
|* declarations out of a bundled stub — and the stub is GENERATED from this,
|* the way selfhost/lexer/TokenType.xc is generated from XTTokenType.h. A
|* hand-written stub would drift from the real libc silently.
\****************************************************************************/
- (int)dumpCInterfaceDeclarations;

@end

NS_ASSUME_NONNULL_END
