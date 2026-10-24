// XTIRPrinter.h — text-form renderer for XTIRModule
//
// Output is the IR text format. Per-function value-ids
// are renumbered fresh starting at 0 so diffs do not flap on
// internal id changes; the printer is deterministic — equal modules
// print to byte-identical text.
#import <Foundation/Foundation.h>
#import "XTIROpcode.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;
@class XTIRType;

@interface XTIRPrinter : NSObject

+ (NSString*)stringFromModule:(XTIRModule*)mod;

// The IR text name of an opcode (`FieldAddr`), as the printer writes it.
+ (NSString*)mnemonicForOpcode:(XTIROpcode)op;

/// A type as the printer spells it (`Ptr(Agg(70), unbanked)`) — what the
/// xc compiler's back ends read, so a back end matching types by name here
/// matches them the same way.
+ (NSString*)stringFromType:(XTIRType*)t module:(XTIRModule*)mod;

@end

NS_ASSUME_NONNULL_END
