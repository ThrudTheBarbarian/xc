// XTIRVerifier.h — read-only structural verification of XTIRModule.
//
// Enforces the eleven mandatory invariants from IR-SPEC §12. The two
// --paranoid invariants are deferred until the optimiser begins to
// exercise them. Each rejected invariant produces one diagnostic
// string starting with "§12.N: ..." where N is the invariant
// number. The verifier collects all errors before returning; it
// never bails on the first one.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;

@interface XTIRVerifier : NSObject

/// Verify `mod`. Returns YES if all 11 mandatory invariants hold.
/// On NO, populates `errors` with one or more "§12.N: …" strings.
+ (BOOL)verifyModule:(XTIRModule*)mod
              errors:(NSArray<NSString*>* _Nullable* _Nullable)errors;

@end

NS_ASSUME_NONNULL_END
