#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Default lowering for the abstract VaStart / VaArg ops: expand them to the
// shared `__xtc_va_buf` pack-buffer access (cursor load → slot load → advance),
// reproducing exactly what the front end used to emit inline. This is the
// 6502/m68k path (and the arm64 path until it grows a native reader); the arm9
// backend intercepts the ops before this and lowers them to a native AAPCS
// va_list. Runs at every -O level (the ops MUST be gone before the backend).
@class XTIROptTargetProfile;

@interface XTIROptVaArgExpand : NSObject <XTIROptPass>
// When the profile uses native varargs (arm9), the pass is a no-op — the backend
// lowers VaStart/VaArg to an AAPCS va_list instead of the pack buffer.
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
