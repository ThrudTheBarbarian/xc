// XTIROptInline.h — function inliner (IR optimisation pass)
//
// Inlines small single-basic-block leaf-ish callees into their call sites.
// The motivating case is the thin library wrappers on the hot path
// (Math.sqrt → Math$sqrt__f → __xm_sqrtf, Math.rand → Math$rand →
// Math$step): collapsing a call level removes per-call prologue/epilogue +
// arg-marshalling and lets the register allocator / CSE work across the
// former call boundary. Runs at -O2+.
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptInline : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
