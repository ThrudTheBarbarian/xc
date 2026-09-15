// XTIRPrinter.h — text-form renderer for XTIRModule
//
// Output is the IR text format. Per-function value-ids
// are renumbered fresh starting at 0 so diffs do not flap on
// internal id changes; the printer is deterministic — equal modules
// print to byte-identical text.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;

@interface XTIRPrinter : NSObject

+ (NSString*)stringFromModule:(XTIRModule*)mod;

@end

NS_ASSUME_NONNULL_END
