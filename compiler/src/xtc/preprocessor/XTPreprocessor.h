#import <Foundation/Foundation.h>
#import "XTDiagnosticEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTPreprocessor : NSObject

/****************************************************************************\
|* Search paths for #include <file>
\****************************************************************************/
@property(nonatomic) NSArray<NSString*>* includePaths;

/****************************************************************************\
|* Search paths for shared-library metadata imports. When `#import <GEM>`
|* (or `"GEM"`) does not resolve to a source file, the preprocessor probes
|* these directories for `libGEM.so` (the -lGEM convention). A hit is a
|* METADATA import — not textually included; instead the resolved `.so`
|* path is recorded in `metadataImports` for the driver to read via DWARF.
\****************************************************************************/
@property(nonatomic) NSArray<NSString*>* libraryPaths;

/****************************************************************************\
|* Ordered shared-library filename extensions for a `<Lib>` metadata import,
|* most-preferred first (e.g. `@[@"dylib", @"so"]` on a macOS/arm64 host,
|* `@[@"so"]` on a Linux target). The driver sets this per target so a stale
|* sibling of the wrong format never wins. Defaults to `.so` then `.dylib`.
\****************************************************************************/
@property(nonatomic) NSArray<NSString*>* sharedLibExtensions;

/****************************************************************************\
|* Third-party library roots (`/opt/xcc/3p`; XCC_3P overrides). Each holds
|* `<vendor>/<arch>/lib<X>.so` plus arch-neutral contract sources in
|* `<vendor>/xc/`. The bare-name library probe consults these BETWEEN the
|* explicit -L dirs and the appended defaults (sysroot); `<vendor/X>` is the
|* qualified form. A hit appends the vendor's `xc/` to `includePaths` for
|* the REST of the translation unit, so a contract file's own quoted
|* imports resolve too. private:docs/Design/third-party-libraries.md.
\****************************************************************************/
@property(nonatomic) NSArray<NSString*>* thirdPartyRoots;

/****************************************************************************\
|* The target arch subdirectory name inside a vendor dir (`arm64`, `arm9`,
|* `x86_64`, `win64`, `atarist`, …) — the same spelling `-A` uses.
\****************************************************************************/
@property(nonatomic, nullable) NSString* targetArchName;

/****************************************************************************\
|* How many leading entries of `libraryPaths` are EXPLICIT -L dirs. The
|* probe runs: explicit -L → third-party roots → the remaining (default)
|* dirs, so a stale sysroot copy cannot shadow a 3p deployment while an
|* explicit -L still wins over everything.
\****************************************************************************/
@property(nonatomic) NSUInteger explicitLibraryPathCount;

/****************************************************************************\
|* A platform prelude imported implicitly before the main source (e.g.
|* `"Platform.xc"`), resolved through the include paths like any quoted
|* `#import`. It carries the system-dependent parts (win64: `#import
|* <user32>`, …) so user source stays platform-agnostic. Processed after the
|* initial `#line`, then line numbering resets to the main file, so it does
|* not shift the user's line numbers. nil = no prelude.
\****************************************************************************/
@property(nonatomic, nullable) NSString* platformPrelude;

// Every file the implicit platform prelude pulled in (standardized absolute
// paths). The interface serializer excludes declarations that originate here:
// the ambient surface is EVERY unit's, so a module's .xtc.iface must not
// re-export it — a consumer's own prelude then collides with the metadata
// (task #36: mod-shape's iface carried Object…Url and use-plain's prelude
// redeclared protocol Comparable against it).
@property(nonatomic, readonly) NSSet<NSString*>* preludeFiles;

/****************************************************************************\
|* Resolved `.so` paths gathered from library-metadata `#import`s, in first-
|* seen order and de-duplicated (`#import` is include-once). The driver
|* consumes these after preprocessing to synthesise typed declarations.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* metadataImports;

- (instancetype)initWithDiagnostics:(nullable XTDiagnosticEngine*)diagnostics NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Pre-define a macro from the command line (equivalent to -D name[=value]).
\****************************************************************************/
- (void)defineMacro:(NSString*)name value:(nullable NSString*)value;

/****************************************************************************\
|* Preprocess a source file and return the expanded text.
|* Returns nil and emits diagnostics on fatal error.
\****************************************************************************/
- (nullable NSString*)preprocessFile:(NSString*)path error:(NSError**)outError;

/****************************************************************************\
|* Preprocess source text (already loaded) with the given filename for diagnostics.
\****************************************************************************/
- (NSString*)preprocessSource:(NSString*)source filename:(NSString*)filename;

@end

NS_ASSUME_NONNULL_END
