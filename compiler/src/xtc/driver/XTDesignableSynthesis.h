// XTDesignableSynthesis — uxkit/026, XG-NIB §4: the designable surface.
//
// A class with an `outlet` field or an `:action` method auto-conforms to the
// binding protocol and has its setOutlet / wireAction bodies written for it.
//
// It lives in its own class rather than inside XTCompilerDriver because THREE
// callers run a front end: the driver, the corpus sweep (which reimplements the
// pipeline in-process), and the self-hosted port. A pass that only one of them
// calls is one the others silently get wrong — the sweep reported "Panel does
// not conform to UXDesignable" for a fixture the driver compiled and ran, which
// is what surfaced this. The port keeps the same split (selfhost/driver/
// Designable.xc) for the same reason.
#import <Foundation/Foundation.h>
#import "XTASTNode.h"
#import "XTDeclNodes.h"
#import "XTTypeTable.h"
#import "XTDiagnosticEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTDesignableSynthesis : NSObject
// Returns `ast` with the synthesised methods transplanted in, or `ast`
// unchanged when the module declares no designable class. Errors (a missing
// protocol, a malformed `:action`) go to `diagnostics`; the caller checks its
// error count, exactly as it would after any other stage.
+ (XTProgramNode*)run:(XTProgramNode*)ast
            typeTable:(XTTypeTable*)tt
                arm64:(BOOL)arm64
          diagnostics:(XTDiagnosticEngine*)diagnostics;
@end

NS_ASSUME_NONNULL_END
