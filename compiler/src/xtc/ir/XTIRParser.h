// XTIRParser.h — text-form parser for XTIRModule
//
// Accepts the IR text format. Forward references are
// allowed (block names within terminators; value names within phi
// operands; symbol names within instructions); they are resolved at
// module-finalise time. Unresolved symbol references are stored
// with an "unresolved" marker so the verifier rejects them via
// invariant §12.8.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;

extern NSString* const XTIRParserErrorDomain;

@interface XTIRParser : NSObject

/// Parse `text` into an XTIRModule. On failure returns nil and
/// (if `error` is non-NULL) populates `error` with a description.
+ (nullable XTIRModule*)moduleFromString:(NSString*)text
                                   error:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
